package com.nuvio.app.features.player

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.net.HttpURLConnection
import java.net.URI

internal actual object TempPlaybackCachePlatform {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val jobs = mutableMapOf<Long, Job>()
    private val connections = mutableMapOf<Long, HttpURLConnection>()

    actual fun startMirror(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String>,
        startPositionMs: Long,
        durationMs: Long,
        onProgress: (downloadedBytes: Long, totalBytes: Long?, startBytes: Long) -> Unit,
        onComplete: () -> Unit,
    ) {
        synchronized(jobs) {
            if (jobs.containsKey(launchId)) return
        }
        val job = scope.launch {
            val dest = tailFile(launchId)
            runCatching { dest.delete() }
            var connection: HttpURLConnection? = null
            try {
                // 1. Learn total size so the resume offset maps to the playhead.
                val total = probeTotalBytes(sourceUrl, headers, launchId)
                // 2. Map playback position to a byte offset (0 when unknown).
                val startByte = if (total != null && total > 0L && durationMs > 0L && startPositionMs > 0L) {
                    ((startPositionMs.toDouble() / durationMs.toDouble()) * total.toDouble())
                        .toLong().coerceIn(0L, total)
                } else {
                    0L
                }
                // 3. Download (ranged when possible) while reporting true totals.
                connection = openConnection(sourceUrl, headers, launchId, rangeStart = startByte, headCap = 0L)
                    ?: return@launch
                downloadBody(connection, dest, launchId, launchId, startByte, 0L, isHead = false, onProgress)
                onComplete()
            } catch (_: Throwable) {
                runCatching { dest.delete() }
            } finally {
                runCatching { connection?.disconnect() }
                synchronized(jobs) {
                    jobs.remove(launchId)
                    connections.remove(launchId)
                }
            }
        }
        synchronized(jobs) {
            if (jobs.containsKey(launchId)) {
                job.cancel()
                return
            }
            jobs[launchId] = job
        }
    }

    actual fun fetchHead(
        launchId: Long,
        sourceUrl: String,
        headers: Map<String, String>,
        headBytes: Long,
        onProgress: (headDownloadedBytes: Long) -> Unit,
        onComplete: () -> Unit,
    ) {
        if (headBytes <= 0L) return
        val key = headJobKey(launchId)
        synchronized(jobs) {
            if (jobs.containsKey(key)) return
        }
        val job = scope.launch {
            val dest = headFile(launchId)
            runCatching { dest.delete() }
            var connection: HttpURLConnection? = null
            try {
                connection = openConnection(sourceUrl, headers, key, rangeStart = 0L, headCap = headBytes)
                    ?: return@launch
                downloadBody(
                    connection, dest, key, launchId, 0L, headBytes, isHead = true,
                    onProgress = { downloaded, _, _ -> onProgress(downloaded) },
                )
                onComplete()
            } catch (_: Throwable) {
                runCatching { dest.delete() }
            } finally {
                runCatching { connection?.disconnect() }
                synchronized(jobs) {
                    jobs.remove(key)
                    connections.remove(key)
                }
            }
        }
        synchronized(jobs) {
            if (jobs.containsKey(key)) {
                job.cancel()
                return
            }
            jobs[key] = job
        }
    }

    actual fun cancelAndDelete(launchId: Long) {
        val key = headJobKey(launchId)
        synchronized(jobs) {
            jobs.remove(launchId)?.cancel()
            jobs.remove(key)?.cancel()
            connections.remove(launchId)?.let { runCatching { it.disconnect() } }
            connections.remove(key)?.let { runCatching { it.disconnect() } }
        }
        runCatching { tailFile(launchId).delete() }
        runCatching { headFile(launchId).delete() }
        runCatching { legacyFile(launchId).delete() }
    }

    actual fun deleteAllTemp() {
        synchronized(jobs) {
            jobs.values.toList().forEach { runCatching { it.cancel() } }
            jobs.clear()
            connections.values.toList().forEach { runCatching { it.disconnect() } }
            connections.clear()
        }
        runCatching {
            tempDir().listFiles()
                ?.filter { it.isFile && it.name.endsWith(".bin") }
                ?.forEach { runCatching { it.delete() } }
        }
    }

    actual fun freeSpaceBytes(): Long =
        runCatching { tempDir().usableSpace }.getOrDefault(Long.MAX_VALUE)

    private fun headJobKey(launchId: Long): Long = Long.MIN_VALUE xor launchId

    private fun openConnection(
        sourceUrl: String,
        headers: Map<String, String>,
        launchId: Long,
        rangeStart: Long?,
        headCap: Long,
    ): HttpURLConnection? {
        val opened = (URI(sourceUrl).toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 60_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            headers.forEach { (k, v) ->
                val key = k.trim()
                val value = v.trim()
                if (key.isNotEmpty() && value.isNotEmpty() && !key.equals("Range", ignoreCase = true)) {
                    runCatching { setRequestProperty(key, value) }
                }
            }
            runCatching { setRequestProperty("Accept-Encoding", "identity") }
            if (rangeStart != null && rangeStart > 0L) {
                runCatching { setRequestProperty("Range", "bytes=$rangeStart-") }
            } else if (headCap > 0L) {
                runCatching { setRequestProperty("Range", "bytes=0-${headCap - 1}") }
            }
        }
        synchronized(jobs) {
            if (!jobs.containsKey(launchId)) {
                runCatching { opened.disconnect() }
                return null
            }
            connections[launchId] = opened
        }
        return opened
    }

    private fun downloadBody(
        connection: HttpURLConnection,
        dest: File,
        launchId: Long,
        realLaunchId: Long,
        startByte: Long,
        headCap: Long,
        isHead: Boolean,
        onProgress: (Long, Long?, Long) -> Unit,
    ) {
        val code = connection.responseCode
        if (code != 200 && code != 206) error("http $code")
        val effectiveStart: Long
        val trueTotal: Long?
        if (code == 206 && !isHead && startByte > 0L) {
            effectiveStart = startByte
            trueTotal = parseContentRangeTotal(connection.getHeaderField("Content-Range"))
                ?: connection.getHeaderField("Content-Length")?.toLongOrNull()
                    ?.takeIf { it > 0L }?.let { effectiveStart + it }
        } else {
            // Server ignored Range (or none requested): body starts at byte 0.
            // A capped head fetch keeps only the requested prefix.
            effectiveStart = 0L
            trueTotal = if (isHead && headCap > 0L) {
                maxOf(
                    headCap,
                    connection.getHeaderField("Content-Length")?.toLongOrNull() ?: 0L,
                ).takeIf { it > 0L }
            } else {
                connection.getHeaderField("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
            }
        }
        var downloaded = 0L
        var sinceSpaceCheck = 0L
        onProgress(0L, trueTotal, effectiveStart)
        connection.inputStream.use { input ->
            dest.outputStream().use { out ->
                val buf = ByteArray(256 * 1024)
                while (true) {
                    if (isHead && headCap > 0L && downloaded >= headCap) break
                    var n = input.read(buf)
                    if (n < 0) break
                    if (isHead && headCap > 0L) {
                        n = minOf(n.toLong(), headCap - downloaded).toInt()
                    }
                    out.write(buf, 0, n)
                    downloaded += n
                    onProgress(downloaded, trueTotal, effectiveStart)
                    if (!isHead) {
                        sinceSpaceCheck += n
                        if (sinceSpaceCheck >= TempPlaybackCache.SPACE_CHECK_INTERVAL_BYTES) {
                            sinceSpaceCheck = 0L
                            if (!enforceSpacePolicy(realLaunchId)) return
                        }
                    }
                }
                out.flush()
            }
        }
    }

    /**
     * Returns false when the download must stop growing. Watched history is
     * evicted first; the unwatched forward part is always kept.
     */
    private fun enforceSpacePolicy(realLaunchId: Long): Boolean {
        if (freeSpaceBytes() >= TempPlaybackCache.LOW_SPACE_STOP_BYTES) return true
        runCatching { headFile(realLaunchId).delete() }
        return freeSpaceBytes() >= TempPlaybackCache.LOW_SPACE_STOP_BYTES
    }

    private fun probeTotalBytes(sourceUrl: String, headers: Map<String, String>, launchId: Long): Long? {
        var probe: HttpURLConnection? = null
        try {
            probe = (URI(sourceUrl).toURL().openConnection() as HttpURLConnection).apply {
                requestMethod = "HEAD"
                connectTimeout = 30_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                headers.forEach { (k, v) ->
                    val key = k.trim()
                    val value = v.trim()
                    if (key.isNotEmpty() && value.isNotEmpty() && !key.equals("Range", ignoreCase = true)) {
                        runCatching { setRequestProperty(key, value) }
                    }
                }
            }
            synchronized(jobs) {
                if (!jobs.containsKey(launchId)) {
                    runCatching { probe?.disconnect() }
                    return null
                }
            }
            probe.connect()
            if (probe.responseCode !in 200..299) return null
            return probe.getHeaderField("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
        } catch (_: Throwable) {
            return null
        } finally {
            runCatching { probe?.disconnect() }
        }
    }

    private fun parseContentRangeTotal(headerValue: String?): Long? {
        val value = headerValue?.trim().orEmpty()
        if (value.isBlank()) return null
        val slashIndex = value.lastIndexOf('/')
        if (slashIndex == -1 || slashIndex == value.lastIndex) return null
        val totalPart = value.substring(slashIndex + 1).trim()
        if (totalPart == "*") return null
        return totalPart.toLongOrNull()?.takeIf { it > 0L }
    }

    private fun tempDir(): File =
        File(System.getProperty("java.io.tmpdir") ?: ".", "nuvio_temp_playback").apply { mkdirs() }

    private fun tailFile(launchId: Long): File = File(tempDir(), "$launchId.tail.bin")

    private fun headFile(launchId: Long): File = File(tempDir(), "$launchId.head.bin")

    private fun legacyFile(launchId: Long): File = File(tempDir(), "$launchId.bin")
}
