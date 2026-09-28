package com.nuvio.app.features.player

import com.nuvio.app.core.ui.NuvioToastController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** One saved span on the timeline, as fractions of the file. */
data class TempCacheRange(
    val start: Float,
    val end: Float,
)

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
    val ranges: List<TempCacheRange> = emptyList(),
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
    private val proxied = mutableSetOf<Long>()

    /** True when this playback runs through the loopback proxy (iOS). */
    fun isProxied(launchId: Long): Boolean = proxied.contains(launchId)

    /**
     * Returns the URL the player should load. On platforms with a cache
     * proxy this starts a session and returns a localhost URL, so the
     * player reads from the on-disk cache; everywhere else (or when the
     * proxy is unavailable) it returns the remote URL unchanged and the
     * legacy background mirror is used instead.
     */
    fun resolvePlayUrl(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String> = emptyMap(),
    ): String = resolveProxiedSource(launchId, sourceUrl, headers).first

    /**
     * Same as [resolvePlayUrl] but also returns the headers the player
     * itself should use (empty for localhost: the proxy holds the real
     * upstream headers). Use this everywhere activeSourceUrl is assigned
     * from a remote stream, otherwise the proxy is silently bypassed.
     */
    fun resolveProxiedSource(
        launchId: Long?,
        sourceUrl: String,
        headers: Map<String, String> = emptyMap(),
    ): Pair<String, Map<String, String>> {
        if (launchId == null || !shouldMirror(sourceUrl)) return sourceUrl to headers
        val bridge = NuvioCacheProxyBridgeFactory.create() ?: return sourceUrl to headers
        val key = sessionKey(launchId)
        // Replace any previous session for this playback (e.g. stream switch
        // or debrid re-resolve) so its files never leak until close.
        runCatching { bridge.stopSession(key) }
        val local = runCatching {
            bridge.startSession(key, sourceUrl, encodeHeaders(headers))
        }.getOrNull().orEmpty()
        if (local.isBlank()) return sourceUrl to headers
        proxied.add(launchId)
        _status.update { current ->
            if (current.containsKey(launchId)) current
            else current + (launchId to TempCacheStatus(launchId = launchId))
        }
        return local to emptyMap()
    }

    fun pushPlayhead(launchId: Long, positionMs: Long, durationMs: Long) {
        if (!isProxied(launchId)) return
        runCatching {
            NuvioCacheProxyBridgeFactory.create()
                ?.setPlayhead(sessionKey(launchId), positionMs, durationMs)
        }
    }

    fun refreshRanges(launchId: Long) {
        if (!isProxied(launchId)) return
        val json = runCatching {
            NuvioCacheProxyBridgeFactory.create()?.cachedRangesJson(sessionKey(launchId))
        }.getOrNull().orEmpty()
        val ranges = parseRangesJson(json)
        _status.update { current ->
            val prev = current[launchId] ?: return@update current
            current + (launchId to prev.copy(ranges = ranges))
        }
    }

    private fun sessionKey(launchId: Long): String = "p$launchId"

    private fun encodeHeaders(headers: Map<String, String>): String? {
        val sanitized = headers.mapNotNull { (k, v) ->
            val key = k.trim()
            val value = v.trim()
            if (key.isBlank() || value.isBlank() || key.equals("Range", ignoreCase = true)) null
            else key to value
        }.toMap()
        if (sanitized.isEmpty()) return null
        return runCatching { Json.encodeToString(sanitized) }.getOrNull()
    }

    internal fun parseRangesJson(json: String): List<TempCacheRange> {
        val trimmed = json.trim()
        if (trimmed.isEmpty() || trimmed == "[]") return emptyList()
        return runCatching {
            trimmed.removePrefix("[").removeSuffix("]")
                .split("],[")
                .mapNotNull { pair ->
                    val parts = pair.replace("[", "").replace("]", "").split(",")
                    if (parts.size != 2) return@mapNotNull null
                    val start = parts[0].trim().toFloatOrNull() ?: return@mapNotNull null
                    val end = parts[1].trim().toFloatOrNull() ?: return@mapNotNull null
                    if (end <= start) return@mapNotNull null
                    TempCacheRange(
                        start = start.coerceIn(0f, 1f),
                        end = end.coerceIn(0f, 1f),
                    )
                }
                .take(32)
        }.getOrDefault(emptyList())
    }

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
                    val cleanTotal = total?.takeIf { it > 0L }
                    val cleanStart = startBytes.coerceAtLeast(0L)
                    val cleanDownloaded = downloaded.coerceAtLeast(0L)
                    current + (launchId to prev.copy(
                        downloadedBytes = cleanDownloaded,
                        totalBytes = cleanTotal,
                        startBytes = cleanStart,
                        ranges = singleRange(cleanStart, cleanDownloaded, cleanTotal),
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

    private fun singleRange(startBytes: Long, downloadedBytes: Long, totalBytes: Long?): List<TempCacheRange> {
        val total = totalBytes?.takeIf { it > 0L } ?: return emptyList()
        val end = startBytes + downloadedBytes
        if (end <= 0L) return emptyList()
        val start = (startBytes.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        val finish = (end.toFloat() / total.toFloat()).coerceIn(0f, 1f)
        if (finish <= start) return emptyList()
        return listOf(TempCacheRange(start, finish))
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
        proxied.remove(launchId)
        runCatching {
            NuvioCacheProxyBridgeFactory.create()?.stopSession(sessionKey(launchId))
        }
        runCatching { TempPlaybackCachePlatform.cancelAndDelete(launchId) }
        _status.update { current -> current - launchId }
    }

    fun sweepOnColdStart() {
        // Only call at app cold start when no playback is active.
        started.clear()
        tailDone.clear()
        val keys = proxied.toList()
        proxied.clear()
        keys.forEach { key ->
            runCatching {
                NuvioCacheProxyBridgeFactory.create()?.stopSession(sessionKey(key))
            }
        }
        runCatching {
            NuvioCacheProxyBridgeFactory.create()?.stopAllSessions()
        }
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
