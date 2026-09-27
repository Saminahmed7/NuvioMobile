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
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onComplete: () -> Unit,
    ) {
        synchronized(jobs) {
            if (jobs.containsKey(launchId)) return
        }
        val job = scope.launch {
            val dest = File(tempDir(), "$launchId.bin")
            runCatching { dest.delete() }
            var connection: HttpURLConnection? = null
            try {
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
                }
                synchronized(jobs) {
                    if (!jobs.containsKey(launchId)) {
                        runCatching { opened.disconnect() }
                        return@launch
                    }
                    connections[launchId] = opened
                }
                connection = opened
                opened.connect()
                val code = opened.responseCode
                if (code !in 200..299) error("http $code")
                val total = opened.getHeaderField("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
                var downloaded = 0L
                onProgress(0L, total)
                opened.inputStream.use { input ->
                    dest.outputStream().use { out ->
                        val buf = ByteArray(256 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            downloaded += n
                            onProgress(downloaded, total)
                        }
                        out.flush()
                    }
                }
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

    actual fun cancelAndDelete(launchId: Long) {
        synchronized(jobs) {
            jobs.remove(launchId)?.cancel()
            connections.remove(launchId)?.let { runCatching { it.disconnect() } }
        }
        runCatching { File(tempDir(), "$launchId.bin").delete() }
    }

    actual fun deleteAllTemp() {
        synchronized(jobs) {
            jobs.values.toList().forEach { runCatching { it.cancel() } }
            jobs.clear()
            connections.values.toList().forEach { runCatching { it.disconnect() } }
            connections.clear()
        }
        runCatching {
            tempDir().listFiles()?.forEach { runCatching { it.delete() } }
        }
    }

    private fun tempDir(): File =
        File(System.getProperty("java.io.tmpdir") ?: ".", "nuvio_temp_playback").apply { mkdirs() }
}
