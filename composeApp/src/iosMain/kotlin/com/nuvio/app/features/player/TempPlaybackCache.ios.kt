package com.nuvio.app.features.player

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.convert
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSHomeDirectory
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSURL
import platform.Foundation.NSURLRequestReloadIgnoringLocalCacheData
import platform.Foundation.NSURLResponse
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.NSURLSessionDataDelegateProtocol
import platform.Foundation.NSURLSessionDataTask
import platform.Foundation.NSURLSessionTask
import platform.Foundation.setHTTPMethod
import platform.Foundation.setValue
import platform.darwin.NSObject
import platform.posix.fclose
import platform.posix.fflush
import platform.posix.fopen
import platform.posix.fwrite
import platform.posix.FILE
import kotlinx.cinterop.CPointer

private const val TEMP_REQUEST_TIMEOUT = 60.0
private const val TEMP_RESOURCE_TIMEOUT = 24.0 * 60.0 * 60.0

@OptIn(ExperimentalForeignApi::class)
internal actual object TempPlaybackCachePlatform {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val jobs = mutableMapOf<Long, Job>()
    private val tasks = mutableMapOf<Long, NSURLSessionTask>()
    private val sessions = mutableMapOf<Long, NSURLSession>()

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
            val dir = tempDir()
            val dest = "$dir/$launchId.bin"
            // Fresh mirror per playback; stale file from a crashed session is removed.
            removeIfExists(dest)
            try {
                downloadToFile(sourceUrl, headers, dest, launchId, onProgress)
                onComplete()
            } catch (_: Throwable) {
                // Silent: playback already runs from remote URL; mirror is best-effort.
                removeIfExists(dest)
            } finally {
                synchronized(jobs) {
                    jobs.remove(launchId)
                    tasks.remove(launchId)?.let { runCatching { it.cancel() } }
                    sessions.remove(launchId)?.let { runCatching { it.invalidateAndCancel() } }
                }
            }
        }
        synchronized(jobs) {
            jobs[launchId] = job
        }
    }

    actual fun cancelAndDelete(launchId: Long) {
        synchronized(jobs) {
            jobs.remove(launchId)?.cancel()
            tasks.remove(launchId)?.let { runCatching { it.cancel() } }
            sessions.remove(launchId)?.let { runCatching { it.invalidateAndCancel() } }
        }
        removeIfExists("${tempDir()}/$launchId.bin")
    }

    actual fun deleteAllTemp() {
        synchronized(jobs) {
            jobs.values.toList().forEach { runCatching { it.cancel() } }
            jobs.clear()
            tasks.values.toList().forEach { runCatching { it.cancel() } }
            tasks.clear()
            sessions.values.toList().forEach { runCatching { it.invalidateAndCancel() } }
            sessions.clear()
        }
        val dir = tempDir()
        val names = NSFileManager.defaultManager.contentsOfDirectoryAtPath(dir, null) as? List<*>
        names?.forEach {
            val name = it as? String ?: return@forEach
            removeIfExists("$dir/$name")
        }
    }

    private fun tempDir(): String {
        val path = "${NSHomeDirectory().trimEnd('/')}/Library/Caches/nuvio_temp_playback"
        NSFileManager.defaultManager.createDirectoryAtPath(path, true, null, null)
        return path
    }

    private fun removeIfExists(path: String) {
        if (NSFileManager.defaultManager.fileExistsAtPath(path)) {
            NSFileManager.defaultManager.removeItemAtPath(path, null)
        }
    }

    private suspend fun downloadToFile(
        sourceUrl: String,
        headers: Map<String, String>,
        dest: String,
        launchId: Long,
        onProgress: (Long, Long?) -> Unit,
    ) {
        val url = NSURL(string = sourceUrl)
        val request = NSMutableURLRequest(
            uRL = url,
            cachePolicy = NSURLRequestReloadIgnoringLocalCacheData,
            timeoutInterval = TEMP_REQUEST_TIMEOUT,
        )
        request.setHTTPMethod("GET")
        headers.forEach { (k, v) ->
            val key = k.trim()
            val value = v.trim()
            if (key.isNotEmpty() && value.isNotEmpty() && !key.equals("Range", ignoreCase = true)) {
                request.setValue(value, forHTTPHeaderField = key)
            }
        }
        val delegate = TempMirrorDelegate(dest, onProgress)
        val config = NSURLSessionConfiguration.defaultSessionConfiguration().apply {
            timeoutIntervalForRequest = TEMP_REQUEST_TIMEOUT
            timeoutIntervalForResource = TEMP_RESOURCE_TIMEOUT
            waitsForConnectivity = true
            allowsCellularAccess = true
            allowsExpensiveNetworkAccess = true
            allowsConstrainedNetworkAccess = true
        }
        val session = NSURLSession.sessionWithConfiguration(
            configuration = config,
            delegate = delegate,
            delegateQueue = NSOperationQueue().apply { maxConcurrentOperationCount = 1 },
        )
        synchronized(jobs) {
            // Only track if still wanted; otherwise abort immediately.
            if (!jobs.containsKey(launchId)) {
                session.invalidateAndCancel()
                throw CancellationException()
            }
            sessions[launchId] = session
        }
        val task = session.dataTaskWithRequest(request)
        synchronized(jobs) {
            if (!jobs.containsKey(launchId)) {
                session.invalidateAndCancel()
                throw CancellationException()
            }
            tasks[launchId] = task
        }
        onProgress(0L, null)
        task.resume()
        try {
            delegate.await()
        } finally {
            session.finishTasksAndInvalidate()
        }
    }
}

@OptIn(ExperimentalForeignApi::class)
private class TempMirrorDelegate(
    private val dest: String,
    private val onProgress: (Long, Long?) -> Unit,
) : NSObject(), NSURLSessionDataDelegateProtocol {
    private val done = CompletableDeferred<Unit>()
    private var file: CPointer<FILE>? = null
    private var downloaded = 0L
    private var total: Long? = null
    private var failed: Throwable? = null

    suspend fun await() = done.await()

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveResponse: NSURLResponse,
        completionHandler: (Long) -> Unit,
    ) {
        val http = didReceiveResponse as? NSHTTPURLResponse
        val code = http?.statusCode?.toInt() ?: 200
        if (code !in 200..299) {
            failed = IllegalStateException("http $code")
            completionHandler(0L)
            return
        }
        total = http?.valueForHTTPHeaderField("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
        file = fopen(dest, "wb")
        if (file == null) {
            failed = IllegalStateException("open temp file failed")
        }
        onProgress(0L, total)
        completionHandler(1L)
    }

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveData: NSData,
    ) {
        val out = file ?: run {
            failed = IllegalStateException("temp file not open")
            return
        }
        val n = didReceiveData.length.toLong()
        val wrote = fwrite(didReceiveData.bytes, 1.convert(), n.convert(), out).toLong()
        if (wrote != n) {
            failed = IllegalStateException("write temp file failed")
            return
        }
        fflush(out)
        downloaded += n
        onProgress(downloaded, total)
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        didCompleteWithError: platform.Foundation.NSError?,
    ) {
        file?.let { fflush(it); fclose(it) }
        file = null
        if (didCompleteWithError != null) {
            done.completeExceptionally(IllegalStateException(didCompleteWithError.localizedDescription))
            return
        }
        failed?.let { done.completeExceptionally(it); return }
        done.complete(Unit)
    }
}
