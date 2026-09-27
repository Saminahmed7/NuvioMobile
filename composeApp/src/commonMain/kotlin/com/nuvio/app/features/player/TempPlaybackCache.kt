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
 * Only progressive http(s) files are mirrored. HLS (.m3u8), DASH (.mpd),
 * torrents and magnet links are skipped.
 */
data class TempCacheStatus(
    val launchId: Long,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long? = null,
    val isComplete: Boolean = false,
)

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

    fun start(launchId: Long, sourceUrl: String, headers: Map<String, String> = emptyMap()) {
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
            onProgress = { downloaded, total ->
                _status.update { current ->
                    val prev = current[launchId] ?: TempCacheStatus(launchId = launchId)
                    current + (launchId to prev.copy(
                        downloadedBytes = downloaded.coerceAtLeast(0L),
                        totalBytes = total?.takeIf { it > 0L },
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
 */
expect object TempPlaybackCachePlatform {
    fun startMirror(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String>,
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onComplete: () -> Unit,
    )

    fun cancelAndDelete(launchId: Long)

    fun deleteAllTemp()
}
