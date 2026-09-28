package com.nuvio.app.features.player

import com.nuvio.app.core.ui.NuvioToastController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Samin temp playback cache.
 *
 * Plays instantly from the remote URL (good for slow connections) while a
 * background mirror writes the same bytes to the app Caches directory.
 * The temp files are deleted when the player closes (see disposeRouteResources
 * for PlayerRoute + PlayerDestination DisposableEffect).
 *
 * Position-aware: the mirror starts at the current playback position
 * (not byte 0), so on a slow link bandwidth serves what is about to be
 * watched instead of the beginning of a large file. Once the forward part
 * is fully cached, the backward part (before the playhead) is fetched too —
 * but only when free storage comfortably fits it. If storage runs low,
 * the watched (backward) file is evicted first and the unwatched (forward)
 * part is kept. Only progressive http(s) files are mirrored. HLS (.m3u8),
 * DASH (.mpd), torrents and magnet links are skipped.
 */
data class TempCacheStatus(
    val launchId: Long,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long? = null,
    val startBytes: Long = 0L,
    val headDownloadedBytes: Long = 0L,
    val headComplete: Boolean = false,
    val isComplete: Boolean = false,
) {
    /** Fraction of the file where the forward saved region starts. */
    val startFraction: Float?
        get() {
            val total = totalBytes?.takeIf { it > 0L } ?: return null
            if (startBytes <= 0L) return 0f
            return (startBytes.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        }

    /** Fraction of the file saved up to (end of the forward saved region). */
    val endFraction: Float?
        get() {
            val total = totalBytes?.takeIf { it > 0L } ?: return null
            val end = startBytes + downloadedBytes
            if (end <= 0L) return null
            return (end.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        }

    /** Fraction of the file covered by the backward saved region. */
    val headEndFraction: Float?
        get() {
            val total = totalBytes?.takeIf { it > 0L } ?: return null
            if (headDownloadedBytes <= 0L) return null
            return (headDownloadedBytes.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        }
}

object TempPlaybackCache {
    // Keep this much free while mirroring; below it the mirror stops growing.
    const val LOW_SPACE_STOP_BYTES = 300L * 1024L * 1024L
    // Backward fetch starts only when free space fits it plus this margin.
    const val HEAD_SPACE_MARGIN_BYTES = 500L * 1024L * 1024L
    // How often (downloaded bytes) free space is re-checked mid-download.
    const val SPACE_CHECK_INTERVAL_BYTES = 32L * 1024L * 1024L

    private val _status = MutableStateFlow<Map<Long, TempCacheStatus>>(emptyMap())
    val status: StateFlow<Map<Long, TempCacheStatus>> = _status.asStateFlow()
    // Touched from the main thread (Compose effects / navigation dispose).
    private val started = mutableSetOf<Long>()
    private val tailDone = mutableSetOf<Long>()

    fun shouldMirror(url: String?): Boolean {
        val normalized = url?.trim().orEmpty()
        if (normalized.isBlank()) return false
        if (normalized.startsWith("file:", ignoreCase = true)) return false
        if (normalized.startsWith("torrent:", ignoreCase = true)) return false
        if (normalized.startsWith("magnet:", ignoreCase = true)) return false
        val lower = normalized.lowercase()
        if (lower.endsWith(".m3u8") || lower.contains(".m3u8?")) return false
        if (lower.endsWith(".mpd") || lower.contains(".mpd?")) return false
        if (lower.endsWith(".torrent") || lower.contains(".torrent?")) return false
        return lower.startsWith("http://") || lower.startsWith("https://")
    }

    fun statusFor(launchId: Long): TempCacheStatus? = _status.value[launchId]

    fun start(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String> = emptyMap(),
        startPositionMs: Long = 0L,
        durationMs: Long = 0L,
    ) {
        if (!shouldMirror(sourceUrl)) return
        if (!started.add(launchId)) return
        // Samin debug proof-of-life: visible the moment the mirror begins.
        NuvioToastController.show("Temp save on")
        _status.update { current ->
            if (current.containsKey(launchId)) current
            else current + (launchId to TempCacheStatus(launchId = launchId))
        }
        // Platform download runs on its own thread/session; callbacks hop back here.
        TempPlaybackCachePlatform.startMirror(
            launchId = launchId,
            sourceUrl = sourceUrl,
            headers = headers,
            startPositionMs = startPositionMs.coerceAtLeast(0L),
            durationMs = durationMs.coerceAtLeast(0L),
            onProgress = { downloaded, total, startBytes ->
                _status.update { current ->
                    val prev = current[launchId] ?: TempCacheStatus(launchId = launchId)
                    current + (launchId to prev.copy(
                        downloadedBytes = downloaded.coerceAtLeast(0L),
                        totalBytes = total?.takeIf { it > 0L },
                        startBytes = startBytes.coerceAtLeast(0L),
                    ))
                }
            },
            onComplete = {
                _status.update { current ->
                    val prev = current[launchId] ?: TempCacheStatus(launchId = launchId)
                    current + (launchId to prev.copy(isComplete = true))
                }
                val done = _status.value[launchId]
                val mb = ((done?.startBytes ?: 0L) + (done?.downloadedBytes ?: 0L)) / (1024L * 1024L)
                // Samin debug proof-of-life: visible when the forward save ends.
                NuvioToastController.show("Temp saved ${mb} MB")
                if (tailDone.add(launchId)) {
                    maybeFetchHead(launchId, sourceUrl, headers)
                }
            },
        )
    }

    private fun maybeFetchHead(launchId: Long, sourceUrl: String, headers: Map<String, String>) {
        val snapshot = _status.value[launchId] ?: return
        val behind = snapshot.startBytes
        if (behind <= 0L || snapshot.headComplete) return
        val free = runCatching { TempPlaybackCachePlatform.freeSpaceBytes() }.getOrNull() ?: return
        if (free < behind + HEAD_SPACE_MARGIN_BYTES) return
        TempPlaybackCachePlatform.fetchHead(
            launchId = launchId,
            sourceUrl = sourceUrl,
            headers = headers,
            headBytes = behind,
            onProgress = { headDownloaded ->
                _status.update { current ->
                    val prev = current[launchId] ?: return@update current
                    current + (launchId to prev.copy(
                        headDownloadedBytes = headDownloaded.coerceAtLeast(0L),
                    ))
                }
            },
            onComplete = {
                _status.update { current ->
                    val prev = current[launchId] ?: return@update current
                    current + (launchId to prev.copy(headComplete = true))
                }
            },
        )
    }

    fun cancelAndDelete(launchId: Long) {
        started.remove(launchId)
        tailDone.remove(launchId)
        runCatching { TempPlaybackCachePlatform.cancelAndDelete(launchId) }
        _status.update { current -> current - launchId }
    }

    fun sweepOnColdStart() {
        // Only call at app cold start when no playback is active.
        started.clear()
        tailDone.clear()
        runCatching { TempPlaybackCachePlatform.deleteAllTemp() }
        _status.value = emptyMap()
    }
}

/**
 * Platform mirror. Files live under the app Caches directory
 * (never Documents: no iCloud backup, OS may reclaim if needed):
 * `<launchId>.tail.bin` (playhead forward) and `<launchId>.head.bin`
 * (before the playhead, fetched only after the tail completes and only
 * when storage comfortably fits).
 *
 * Implementations first probe total size, map startPositionMs/durationMs to
 * a byte offset, then download with a Range request from there. Servers
 * without Range support fall back to a full download from byte 0
 * (reported startBytes = 0). While downloading, free space is re-checked;
 * below [TempPlaybackCache.LOW_SPACE_STOP_BYTES] the watched head file is
 * evicted first and the download stops growing (already saved bytes kept).
 */
internal expect object TempPlaybackCachePlatform {
    fun startMirror(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String>,
        startPositionMs: Long,
        durationMs: Long,
        onProgress: (downloadedBytes: Long, totalBytes: Long?, startBytes: Long) -> Unit,
        onComplete: () -> Unit,
    )

    fun fetchHead(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String>,
        headBytes: Long,
        onProgress: (headDownloadedBytes: Long) -> Unit,
        onComplete: () -> Unit,
    )

    fun cancelAndDelete(launchId: Long)

    fun deleteAllTemp()

    fun freeSpaceBytes(): Long
}
