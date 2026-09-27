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
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onComplete: () -> Unit,
    ) {
        synchronized(jobs) {
            if (jobs.containsKey(launchId)) return
        }
        val job = scope.launch {
            val dest = File(tempDir(), "$launchId.bin")
            runCatching { dest.delete() }
            try {
                val builder = Request.Builder().url(sourceUrl).get()
                headers.forEach { (k, v) ->
                    val key = k.trim()
                    val value = v.trim()
                    if (key.isNotEmpty() && value.isNotEmpty() && !key.equals("Range", ignoreCase = true)) {
                        runCatching { builder.header(key, value) }
                    }
                }
                val call = client.newCall(builder.build())
                synchronized(jobs) {
                    if (!jobs.containsKey(launchId)) {
                        runCatching { call.cancel() }
                        return@launch
                    }
                    calls[launchId] = call
                }
                onProgress(0L, null)
                call.execute().use { response ->
                    if (!response.isSuccessful) error("http ${response.code}")
                    val total = response.header("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
                    val body = checkNotNull(response.body)
                    var downloaded = 0L
                    dest.outputStream().use { out ->
                        body.byteStream().use { input ->
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
                }
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
            // Register before any early-exit check inside the coroutine.
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

    private fun tempDir(): File {
        val base = appContext?.cacheDir ?: File(System.getProperty("java.io.tmpdir") ?: ".")
        return File(base, "nuvio_temp_playback")
    }
}
