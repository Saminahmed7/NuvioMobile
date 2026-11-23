package com.nuvio.app.features.player

import com.nuvio.app.core.ui.NuvioToastController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** One saved span on the timeline, as fractions of the play duration. */
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
 * part is kept. Only progressive http(s) files are mirrored; torrents and
 * magnet links are skipped.
 *
 * HLS (.m3u8) plays directly from the remote URL with the extractor's own
 * headers, exactly as it did before the segment cache existed. Routing it
 * through the loopback proxy regressed first-play: hotlink-gated CDNs
 * (HiAnime's hls.dramahot.top answers 403 unless the Referer is exactly its
 * own origin) made the playlist fetch fail, and the 302 fallback then handed
 * MPV an upstream URL it could not fetch, so the load died and the recovery
 * retries surfaced as "Connection refused" on the loopback port. The Swift
 * HLSStreamState segment cache is intact and unreachable; flip
 * [HLS_SEGMENT_PROXY_ENABLED] to route HLS through it again. DASH (.mpd) and
 * unparseable playlists bypass the proxy as well.
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
    val cachedBytes: Long = 0L,
    val downloadSpeedBps: Long = 0L,
) {
    val totalCachedBytes: Long
        get() = if (cachedBytes > 0L) cachedBytes else (downloadedBytes + headDownloadedBytes)

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
    // Samin: send HLS (.m3u8) through the iOS loopback segment cache. Off
    // because proxying HLS broke first play for hotlink-gated CDNs: the proxy
    // fetch 403s when the extractor's Referer is not exactly the playlist's own
    // origin, the HLS layer then degrades to a 302 to the upstream playlist,
    // and MPV - handed no headers for a loopback URL - 403s on that redirect,
    // which the recovery retries report as "Connection refused". With this off
    // HLS plays from the remote URL with the extractor's headers, the
    // behaviour that shipped before the segment cache.
    const val HLS_SEGMENT_PROXY_ENABLED = false

    private val _status = MutableStateFlow<Map<Long, TempCacheStatus>>(emptyMap())
    val status: StateFlow<Map<Long, TempCacheStatus>> = _status.asStateFlow()
    // Touched from the main thread (Compose effects / navigation dispose).
    private val started = mutableSetOf<Long>()
    private val tailDone = mutableSetOf<Long>()
    private val proxied = mutableSetOf<Long>()

    private val activeSessionKeys = mutableMapOf<Long, String>()
    private var sessionCounter = 0L

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
        forceNewSession: Boolean = false,
    ): String = resolveProxiedSource(launchId, sourceUrl, headers, forceNewSession).first

    /**
     * True for HLS media/master playlists (.m3u8). These cannot use the
     * progressive byte-chunk cache; the loopback proxy has a segment-level
     * cache for them, currently bypassed - see [HLS_SEGMENT_PROXY_ENABLED].
     */
    fun isAdaptivePlaylist(url: String?): Boolean {
        val lower = url?.trim()?.lowercase().orEmpty()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false
        return lower.endsWith(".m3u8") || lower.contains(".m3u8?")
    }

    /**
     * What may go through the platform cache proxy (iOS): everything
     * [shouldMirror] accepts (progressive files). HLS is excluded while
     * [HLS_SEGMENT_PROXY_ENABLED] is false, so .m3u8 keeps loading the remote
     * URL directly. DASH (.mpd) stays out too: its init segments are commonly
     * byte-range addressed, which the proxy does not support yet. On platforms
     * without a proxy bridge this gate is irrelevant — [resolveProxiedSource]
     * returns the remote URL unchanged.
     */
    fun shouldProxy(url: String?): Boolean =
        shouldMirror(url) || (HLS_SEGMENT_PROXY_ENABLED && isAdaptivePlaylist(url))

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
        forceNewSession: Boolean = false,
    ): Pair<String, Map<String, String>> {
        if (launchId == null) return sourceUrl to headers
        if (!shouldProxy(sourceUrl)) {
            // Stream cannot be proxied (e.g. HLS or direct). If this launch had an
            // active proxy session, cleanly stop and delete it so previous episode's
            // downloaders and cache files don't linger.
            val oldKey = activeSessionKeys.remove(launchId)
            if (oldKey != null) {
                runCatching { NuvioCacheProxyBridgeFactory.create()?.stopSession(oldKey) }
            }
            proxied.remove(launchId)
            _status.update { current -> current - launchId }
            return sourceUrl to headers
        }
        val bridge = NuvioCacheProxyBridgeFactory.create() ?: return sourceUrl to headers

        val existingKey = activeSessionKeys[launchId]
        if (!forceNewSession && existingKey != null) {
            // Reuse existing session for genuine debrid credential re-resolves of the
            // same stream. The Swift proxy updates upstream URL in-place without deleting cache.
            val local = runCatching {
                bridge.startSession(existingKey, sourceUrl, encodeHeaders(headers))
            }.getOrNull().orEmpty()
            if (local.isNotBlank()) return local to emptyMap()
            // Fall through to create new session if reuse failed
        }

        // New session (forceNewSession = true for next episode / stream switch,
        // different launchId, or reuse failed): tear down old session and disk directory.
        val oldKey = activeSessionKeys.remove(launchId)
        if (oldKey != null) {
            runCatching { bridge.stopSession(oldKey) }
        }
        val key = "p${launchId}_${++sessionCounter}"
        activeSessionKeys[launchId] = key
        val local = runCatching {
            bridge.startSession(key, sourceUrl, encodeHeaders(headers))
        }.getOrNull().orEmpty()
        if (local.isBlank()) return sourceUrl to headers
        proxied.add(launchId)
        _status.update { current ->
            current + (launchId to TempCacheStatus(launchId = launchId))
        }
        return local to emptyMap()
    }

    fun pushPlayhead(
        launchId: Long,
        positionMs: Long,
        durationMs: Long,
        streamPos: Long = 0L,
        isPlaying: Boolean = true,
    ) {
        if (!isProxied(launchId)) return
        val key = activeSessionKeys[launchId] ?: return
        runCatching {
            NuvioCacheProxyBridgeFactory.create()
                ?.setPlayhead(key, positionMs, durationMs, streamPos, isPlaying)
        }
    }

    private fun formatMb(bytes: Long?): String =
        if (bytes == null || bytes < 0L) "unknown" else "${bytes / 1024 / 1024} MB"

    suspend fun getDiagnosticReport(launchId: Long?): String = withContext(Dispatchers.Default) {
        val header = buildString {
            appendLine("--- App-side session context ---")
            appendLine("launchId: ${launchId ?: "none"}")
            if (launchId != null) {
                appendLine("sessionKey: ${activeSessionKeys[launchId] ?: "none"}")
                appendLine("proxied (loopback cache): ${isProxied(launchId)}")
                appendLine("free space: ${formatMb(runCatching { TempPlaybackCachePlatform.freeSpaceBytes() }.getOrNull())} (mirror stops below ${LOW_SPACE_STOP_BYTES / 1024 / 1024} MB)")
                val snapshot = _status.value[launchId]
                if (snapshot != null) {
                    val total = snapshot.totalBytes?.let { "$it (${it / 1024 / 1024} MB)" } ?: "unknown"
                    appendLine("cache status: cached=${snapshot.totalCachedBytes / 1024 / 1024} MB / total=$total, complete=${snapshot.isComplete}, speed=${snapshot.downloadSpeedBps / 1024} KB/s, ranges=${snapshot.ranges.size}")
                } else {
                    appendLine("cache status: none (non-progressive URL such as HLS/DASH/magnet, or session already closed)")
                }
            }
            appendLine()
        }
        val bridge = NuvioCacheProxyBridgeFactory.create()
            ?: return@withContext header + "Local Cache Proxy is not active on this device/platform (Android/desktop use the background mirror; iOS uses the loopback proxy)."
        val key = launchId?.let { activeSessionKeys[it] }
        val report = runCatching {
            bridge.diagnosticReport(key.orEmpty())
        }.getOrNull().orEmpty()
        if (report.isBlank()) return@withContext header + "No diagnostic report returned from cache proxy server."
        header + report
    }

    fun refreshRanges(launchId: Long) {
        if (!isProxied(launchId)) return
        val bridge = NuvioCacheProxyBridgeFactory.create() ?: return
        val key = activeSessionKeys[launchId] ?: return
        val statsJson = runCatching {
            bridge.cacheStatsJson(key)
        }.getOrNull().orEmpty()

        if (statsJson.isNotBlank() && statsJson != "{}") {
            parseStatsAndUpdate(launchId, statsJson)
        } else {
            val json = runCatching {
                bridge.cachedRangesJson(key)
            }.getOrNull().orEmpty()
            val ranges = parseRangesJson(json)
            _status.update { current ->
                val prev = current[launchId] ?: return@update current
                current + (launchId to prev.copy(ranges = ranges))
            }
        }
    }

    private fun parseStatsAndUpdate(launchId: Long, statsJson: String) {
        runCatching {
            val element = Json.parseToJsonElement(statsJson)
            val obj = element as? JsonObject ?: return
            val speed = (obj["speedBps"] as? JsonPrimitive)?.content?.toLongOrNull() ?: 0L
            val cached = (obj["cachedBytes"] as? JsonPrimitive)?.content?.toLongOrNull() ?: 0L
            val total = (obj["totalBytes"] as? JsonPrimitive)?.content?.toLongOrNull()?.takeIf { it > 0L }
            val isComplete = (obj["isComplete"] as? JsonPrimitive)?.content?.toBooleanStrictOrNull() ?: false
            val rangesElement = obj["ranges"]
            val ranges = if (rangesElement != null) parseRangesJson(rangesElement.toString()) else emptyList()

            _status.update { current ->
                val prev = current[launchId] ?: TempCacheStatus(launchId = launchId)
                current + (launchId to prev.copy(
                    cachedBytes = cached,
                    downloadSpeedBps = speed,
                    totalBytes = total ?: prev.totalBytes,
                    isComplete = isComplete,
                    ranges = if (rangesElement != null) ranges else prev.ranges,
                ))
            }
        }
    }

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
                        cachedBytes = cleanDownloaded + prev.headDownloadedBytes,
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
                    val cleanHead = headDownloaded.coerceAtLeast(0L)
                    current + (launchId to prev.copy(
                        headDownloadedBytes = cleanHead,
                        cachedBytes = prev.downloadedBytes + cleanHead,
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
        val key = activeSessionKeys.remove(launchId) ?: "p$launchId"
        runCatching {
            NuvioCacheProxyBridgeFactory.create()?.stopSession(key)
        }
        runCatching { TempPlaybackCachePlatform.cancelAndDelete(launchId) }
        _status.update { current -> current - launchId }
    }

    fun sweepOnColdStart() {
        // Only call at app cold start when no playback is active.
        started.clear()
        tailDone.clear()
        activeSessionKeys.clear()
        proxied.clear()
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
