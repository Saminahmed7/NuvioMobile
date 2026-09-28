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
import platform.Foundation.NSLock
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

private val jobsLock = NSLock()

private inline fun <T> locked(block: () -> T): T {
    jobsLock.lock()
    try {
        return block()
    } finally {
        jobsLock.unlock()
    }
}

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
        startPositionMs: Long,
        durationMs: Long,
        onProgress: (downloadedBytes: Long, totalBytes: Long?, startBytes: Long) -> Unit,
        onComplete: () -> Unit,
    ) {
        locked {
            if (jobs.containsKey(launchId)) return
        }
        val job = scope.launch {
            val dir = tempDir()
            val dest = "$dir/$launchId.bin"
            // Fresh mirror per playback; stale file from a crashed session is removed.
            removeIfExists(dest)
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
                // Silent: playback already runs from remote URL; mirror is best-effort.
                removeIfExists(dest)
            } finally {
                locked {
                    jobs.remove(launchId)
                    tasks.remove(launchId)?.let { runCatching { it.cancel() } }
                    sessions.remove(launchId)?.let { runCatching { it.invalidateAndCancel() } }
                }
            }
        }
        locked {
            jobs[launchId] = job
        }
    }

    actual fun cancelAndDelete(launchId: Long) {
        locked {
            jobs.remove(launchId)?.cancel()
            tasks.remove(launchId)?.let { runCatching { it.cancel() } }
            sessions.remove(launchId)?.let { runCatching { it.invalidateAndCancel() } }
        }
        removeIfExists("${tempDir()}/$launchId.bin")
    }

    actual fun deleteAllTemp() {
        locked {
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

    private fun baseRequest(sourceUrl: String, headers: Map<String, String>): NSMutableURLRequest {
        val url = NSURL(string = sourceUrl)
        val request = NSMutableURLRequest(
            uRL = url,
            cachePolicy = NSURLRequestReloadIgnoringLocalCacheData,
            timeoutInterval = TEMP_REQUEST_TIMEOUT,
        )
        headers.forEach { (k, v) ->
            val key = k.trim()
            val value = v.trim()
            if (key.isNotEmpty() && value.isNotEmpty() && !key.equals("Range", ignoreCase = true)) {
                request.setValue(value, forHTTPHeaderField = key)
            }
        }
        return request
    }

    private fun newSession(): NSURLSessionConfiguration =
        NSURLSessionConfiguration.defaultSessionConfiguration().apply {
            timeoutIntervalForRequest = TEMP_REQUEST_TIMEOUT
            timeoutIntervalForResource = TEMP_RESOURCE_TIMEOUT
            waitsForConnectivity = true
            allowsCellularAccess = true
            allowsExpensiveNetworkAccess = true
            allowsConstrainedNetworkAccess = true
        }

    private suspend fun probeTotalBytes(
        sourceUrl: String,
        headers: Map<String, String>,
        launchId: Long,
    ): Long? {
        val request = baseRequest(sourceUrl, headers)
        request.setHTTPMethod("HEAD")
        val delegate = TempHeadDelegate()
        val session = NSURLSession.sessionWithConfiguration(
            configuration = newSession(),
            delegate = delegate,
            delegateQueue = NSOperationQueue().apply { maxConcurrentOperationCount = 1 },
        )
        locked {
            if (!jobs.containsKey(launchId)) {
                session.invalidateAndCancel()
                throw CancellationException()
            }
            sessions[launchId] = session
        }
        val task = session.dataTaskWithRequest(request)
        locked {
            if (!jobs.containsKey(launchId)) {
                session.invalidateAndCancel()
                throw CancellationException()
            }
            tasks[launchId] = task
        }
        task.resume()
        try {
            return delegate.await()
        } finally {
            session.finishTasksAndInvalidate()
        }
    }

    private suspend fun downloadToFile(
        sourceUrl: String,
        headers: Map<String, String>,
        dest: String,
        launchId: Long,
        startByte: Long,
        onProgress: (Long, Long?, Long) -> Unit,
    ) {
        val request = baseRequest(sourceUrl, headers)
        request.setHTTPMethod("GET")
        val ranged = startByte > 0L
        if (ranged) {
            request.setValue("bytes=$startByte-", forHTTPHeaderField = "Range")
        }
        val delegate = TempMirrorDelegate(dest, startByte, onProgress)
        val session = NSURLSession.sessionWithConfiguration(
            configuration = newSession(),
            delegate = delegate,
            delegateQueue = NSOperationQueue().apply { maxConcurrentOperationCount = 1 },
        )
        locked {
            if (!jobs.containsKey(launchId)) {
                session.invalidateAndCancel()
                throw CancellationException()
            }
            sessions[launchId] = session
        }
        val task = session.dataTaskWithRequest(request)
        locked {
            if (!jobs.containsKey(launchId)) {
                session.invalidateAndCancel()
                throw CancellationException()
            }
            tasks[launchId] = task
        }
        onProgress(0L, null, 0L)
        task.resume()
        try {
            delegate.await()
        } finally {
            session.finishTasksAndInvalidate()
        }
    }
}

@OptIn(ExperimentalForeignApi::class)
private class TempHeadDelegate : NSObject(), NSURLSessionDataDelegateProtocol {
    private val done = CompletableDeferred<Long?>()
    private var total: Long? = null

    suspend fun await(): Long? = done.await()

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveResponse: NSURLResponse,
        completionHandler: (Long) -> Unit,
    ) {
        val http = didReceiveResponse as? NSHTTPURLResponse
        val code = http?.statusCode?.toInt() ?: 0
        total = if (code in 200..299) {
            http?.valueForHTTPHeaderField("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
        } else {
            null
        }
        // Headers only; refuse the body.
        completionHandler(0L)
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        didCompleteWithError: platform.Foundation.NSError?,
    ) {
        if (didCompleteWithError != null) {
            done.complete(null)
        } else {
            done.complete(total)
        }
    }
}

@OptIn(ExperimentalForeignApi::class)
private class TempMirrorDelegate(
    private val dest: String,
    private val requestedStartByte: Long,
    private val onProgress: (Long, Long?, Long) -> Unit,
) : NSObject(), NSURLSessionDataDelegateProtocol {
    private val done = CompletableDeferred<Unit>()
    private var file: CPointer<FILE>? = null
    private var downloaded = 0L
    private var total: Long? = null
    private var effectiveStartByte = 0L
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
        if (code == 206 && requestedStartByte > 0L) {
            effectiveStartByte = requestedStartByte
            total = parseContentRangeTotal(http?.valueForHTTPHeaderField("Content-Range"))
                ?: http?.valueForHTTPHeaderField("Content-Length")?.toLongOrNull()
                    ?.takeIf { it > 0L }?.let { effectiveStartByte + it }
        } else if (code in 200..299) {
            // Server ignored Range (or none requested): full body from byte 0.
            effectiveStartByte = 0L
            total = http?.valueForHTTPHeaderField("Content-Length")?.toLongOrNull()?.takeIf { it > 0L }
        } else {
            failed = IllegalStateException("http $code")
            completionHandler(0L)
            return
        }
        file = fopen(dest, "wb")
        if (file == null) {
            failed = IllegalStateException("open temp file failed")
        }
        onProgress(0L, total, effectiveStartByte)
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
        onProgress(downloaded, total, effectiveStartByte)
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

private fun parseContentRangeTotal(headerValue: String?): Long? {
    val value = headerValue?.trim().orEmpty()
    if (value.isBlank()) return null
    val slashIndex = value.lastIndexOf('/')
    if (slashIndex == -1 || slashIndex == value.lastIndex) return null
    val totalPart = value.substring(slashIndex + 1).trim()
    if (totalPart == "*") return null
    return totalPart.toLongOrNull()?.takeIf { it > 0L }
}
