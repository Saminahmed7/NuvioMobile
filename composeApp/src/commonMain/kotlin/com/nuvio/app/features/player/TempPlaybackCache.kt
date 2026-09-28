package com.nuvio.app.features.player

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Samin temp playback cache.
 *
 * Plays instantly from the remote URL (good for slow connections) while a
 * background mirror writes the same bytes to the app Caches directory.
 * The temp file is deleted when the player closes (see disposeRouteResources
 * for PlayerRoute + PlayerDestination DisposableEffect).
 *
 * Position-aware: the mirror starts at the current playback position
 * (not byte 0), so on a slow link bandwidth serves what is about to be
 * watched instead of the beginning of a large file. The timeline's gray
 * segment therefore grows forward from the playhead. Only progressive
 * http(s) files are mirrored. HLS (.m3u8), DASH (.mpd), torrents and
 * magnet links are skipped.
 */
data class TempCacheStatus(
    val launchId: Long,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long? = null,
    val startBytes: Long = 0L,
    val isComplete: Boolean = false,
) {
    /** Fraction of the file where the saved region starts. */
    val startFraction: Float?
        get() {
            val total = totalBytes?.takeIf { it > 0L } ?: return null
            if (startBytes <= 0L) return 0f
            return (startBytes.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        }

    /** Fraction of the file saved up to (end of the saved region). */
    val endFraction: Float?
        get() {
            val total = totalBytes?.takeIf { it > 0L } ?: return null
            val end = startBytes + downloadedBytes
            if (end <= 0L) return null
            return (end.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        }
}

object TempPlaybackCache {
    private val _status = MutableStateFlow<Map<Long, TempCacheStatus>>(emptyMap())
    val status: StateFlow<Map<Long, TempCacheStatus>> = _status.asStateFlow()
    // Touched from the main thread (Compose effects / navigation dispose).
    private val started = mutableSetOf<Long>()

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
            },
        )
    }

    fun cancelAndDelete(launchId: Long) {
        started.remove(launchId)
        runCatching { TempPlaybackCachePlatform.cancelAndDelete(launchId) }
        _status.update { current -> current - launchId }
    }

    fun sweepOnColdStart() {
        // Only call at app cold start when no playback is active.
        started.clear()
        runCatching { TempPlaybackCachePlatform.deleteAllTemp() }
        _status.value = emptyMap()
    }
}

/**
 * Platform mirror. Files live under the app Caches directory
 * (never Documents: no iCloud backup, OS may reclaim if needed).
 *
 * Implementations first probe total size, map startPositionMs/durationMs to
 * a byte offset, then download with a Range request from there. Servers
 * without Range support fall back to a full download from byte 0
 * (reported startBytes = 0).
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

    fun cancelAndDelete(launchId: Long)

    fun deleteAllTemp()
}
