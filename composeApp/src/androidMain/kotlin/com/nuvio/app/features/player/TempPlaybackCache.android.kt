package com.nuvio.app.features.player

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

internal actual object TempPlaybackCachePlatform {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()
    private var appContext: Context? = null
    private val jobs = mutableMapOf<Long, Job>()
    private val calls = mutableMapOf<Long, Call>()

    fun initialize(context: Context) {
        appContext = context.applicationContext
        runCatching { tempDir().mkdirs() }
    }

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
            val dest = File(tempDir(), "$launchId.bin")
            runCatching { dest.delete() }
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
                downloadToFile(sourceUrl, headers, dest, launchId, startByte, onProgress)
                onComplete()
            } catch (_: Throwable) {
                runCatching { dest.delete() }
            } finally {
                synchronized(jobs) {
                    jobs.remove(launchId)
                    calls.remove(launchId)
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

    actual fun cancelAndDelete(launchId: Long) {
        synchronized(jobs) {
            jobs.remove(launchId)?.cancel()
            calls.remove(launchId)?.let { runCatching { it.cancel() } }
        }
        runCatching { File(tempDir(), "$launchId.bin").delete() }
    }

    actual fun deleteAllTemp() {
        synchronized(jobs) {
            jobs.values.toList().forEach { runCatching { it.cancel() } }
            jobs.clear()
            calls.values.toList().forEach { runCatching { it.cancel() } }
            calls.clear()
        }
        runCatching {
            tempDir().listFiles()?.forEach { runCatching { it.delete() } }
        }
    }

    private fun baseRequest(sourceUrl: String, headers: Map<String, String>): Request.Builder {
        val builder = Request.Builder().url(sourceUrl)
        headers.forEach { (k, v) ->
            val key = k.trim()
            val value = v.trim()
            if (key.isNotEmpty() && value.isNotEmpty() && !key.equals("Range", ignoreCase = true)) {
                runCatching { builder.header(key, value) }
            }
        }
        // Byte-exact caching: never accept a transformed encoding.
        runCatching { builder.header("Accept-Encoding", "identity") }
        return builder
    }

    private fun trackCall(launchId: Long, call: Call): Boolean {
        synchronized(jobs) {
            if (!jobs.containsKey(launchId)) {
                runCatching { call.cancel() }
                return false
            }
            calls[launchId] = call
            return true
        }
    }

    private fun probeTotalBytes(sourceUrl: String, headers: Map<String, String>, launchId: Long): Long? {
        val call = client.newCall(baseRequest(sourceUrl, headers).head().build())
        if (!trackCall(launchId, call)) return null
        call.execute().use { response ->
            if (!response.isSuccessful) return null
            return response.header("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
        }
    }

    private fun downloadToFile(
        sourceUrl: String,
        headers: Map<String, String>,
        dest: File,
        launchId: Long,
        startByte: Long,
        onProgress: (Long, Long?, Long) -> Unit,
    ) {
        val builder = baseRequest(sourceUrl, headers).get()
        if (startByte > 0L) {
            runCatching { builder.header("Range", "bytes=$startByte-") }
        }
        val call = client.newCall(builder.build())
        if (!trackCall(launchId, call)) return
        onProgress(0L, null, 0L)
        call.execute().use { response ->
            val code = response.code
            if (code != 200 && code != 206) error("http $code")
            val effectiveStart: Long
            val total: Long?
            if (code == 206 && startByte > 0L) {
                effectiveStart = startByte
                total = parseContentRangeTotal(response.header("Content-Range"))
                    ?: response.header("Content-Length")?.toLongOrNull()
                        ?.takeIf { it > 0L }?.let { effectiveStart + it }
            } else {
                // Server ignored Range (or none requested): full body from byte 0.
                effectiveStart = 0L
                total = response.header("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
            }
            val body = checkNotNull(response.body)
            var downloaded = 0L
            onProgress(0L, total, effectiveStart)
            dest.outputStream().use { out ->
                body.byteStream().use { input ->
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        downloaded += n
                        onProgress(downloaded, total, effectiveStart)
                    }
                    out.flush()
                }
            }
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

    private fun tempDir(): File {
        val base = appContext?.cacheDir ?: File(System.getProperty("java.io.tmpdir") ?: ".")
        return File(base, "nuvio_temp_playback")
    }
}
