package com.nuvio.app.features.downloads

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.download_failed
import nuvio.composeapp.generated.resources.downloads_error_finalize_file_failed
import nuvio.composeapp.generated.resources.downloads_error_open_partial_file_failed
import nuvio.composeapp.generated.resources.downloads_error_partial_file_not_open
import nuvio.composeapp.generated.resources.downloads_error_write_partial_file_failed
import nuvio.composeapp.generated.resources.network_request_failed_http
import org.jetbrains.compose.resources.getString
import platform.Foundation.NSError
import platform.Foundation.NSDate
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSHomeDirectory
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
import platform.UIKit.UIApplication
import platform.Foundation.timeIntervalSince1970
import platform.darwin.NSObject
import platform.posix.FILE
import platform.posix.fclose
import platform.posix.fflush
import platform.posix.fopen
import platform.posix.fread
import platform.posix.fwrite

private const val DOWNLOAD_REQUEST_TIMEOUT_SECONDS = 60.0
private const val DOWNLOAD_RESOURCE_TIMEOUT_SECONDS = 24.0 * 60.0 * 60.0
private const val PROGRESS_MIN_INTERVAL_SECONDS = 0.5
private const val PROGRESS_MIN_BYTE_DELTA = 512L * 1024L
private const val DOWNLOAD_CHUNK_SIZE = 16L * 1024L * 1024L
private const val DOWNLOAD_MAX_WORKERS = 2

private val backgroundSessionCompletionHandlers = mutableMapOf<String, () -> Unit>()

fun handleDownloadsBackgroundEvents(
    identifier: String,
    completionHandler: () -> Unit,
) {
    backgroundSessionCompletionHandlers[identifier] = completionHandler
}

fun pauseDownloadsForAppBackground() {
    DownloadsRepository.pauseActiveDownloads()
}

private inline fun <T> NSLock.withLock(block: () -> T): T {
    lock()
    try {
        return block()
    } finally {
        unlock()
    }
}

@OptIn(ExperimentalForeignApi::class)
internal actual object DownloadsPlatformDownloader {
    actual fun start(
        request: DownloadPlatformRequest,
        onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
        onSuccess: (localFileUri: String, totalBytes: Long?) -> Unit,
        onFailure: (message: String) -> Unit,
        onPaused: () -> Unit,
    ): DownloadsTaskHandle {
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.Default)
        val handle = IosDownloadsTaskHandle(job)

        scope.launch {
            val downloadsDirectory = downloadsDirectoryPath()
            val destinationPath = "$downloadsDirectory/${request.destinationFileName}"
            val tempPath = "$downloadsDirectory/${request.destinationFileName}.part"
            val partsDir = "$downloadsDirectory/${request.destinationFileName}.parts"

            try {
                DownloadSubtitles.prepare(request.item, NSURL.fileURLWithPath(destinationPath).absoluteString!!)

                // Check if a legacy single-stream download was already in progress
                val hasLegacyPartial = (fileSizeOrNull(tempPath) ?: 0L) > 0L && !NSFileManager.defaultManager.fileExistsAtPath(partsDir)

                // 1. Probe the source to determine total size and Range support
                val probe = probeStream(request, handle)

                if (probe.supportsRange && probe.totalBytes != null && probe.totalBytes > 0L && !hasLegacyPartial) {
                    performMultiWorkerDownload(
                        request = request,
                        totalBytes = probe.totalBytes,
                        tempPath = tempPath,
                        destinationPath = destinationPath,
                        partsDir = partsDir,
                        handle = handle,
                        onProgress = onProgress,
                        onSuccess = onSuccess,
                    )
                    return@launch
                }

                // Fallback to single stream download if Range is not supported or resuming legacy partial
                var resumeFromBytes = fileSizeOrNull(tempPath)?.coerceAtLeast(0L) ?: 0L

                var attemptedRangeRequest = resumeFromBytes > 0L
                var result = performDownloadRequest(
                    request = request,
                    rangeStart = if (attemptedRangeRequest) resumeFromBytes else null,
                    resumeFromBytes = resumeFromBytes,
                    tempPath = tempPath,
                    handle = handle,
                    onProgress = onProgress,
                )

                if (attemptedRangeRequest && result.statusCode == 416) {
                    removePathIfExists(tempPath)
                    resumeFromBytes = 0L
                    attemptedRangeRequest = false
                    result = performDownloadRequest(
                        request = request,
                        rangeStart = null,
                        resumeFromBytes = 0L,
                        tempPath = tempPath,
                        handle = handle,
                        onProgress = onProgress,
                    )
                }

                if (result.statusCode !in 200..299) {
                    error(runBlocking { getString(Res.string.network_request_failed_http, result.statusCode) })
                }

                val isPartialResume = attemptedRangeRequest && result.statusCode == 206 && resumeFromBytes > 0L
                val startingBytes = if (isPartialResume) resumeFromBytes else 0L
                val totalBytes = resolveTotalBytes(
                    startingBytes = startingBytes,
                    isPartialResume = isPartialResume,
                    contentRangeHeader = result.contentRange,
                    contentLength = result.contentLength,
                )

                removePathIfExists(destinationPath)
                val moved = NSFileManager.defaultManager.moveItemAtPath(
                    srcPath = tempPath,
                    toPath = destinationPath,
                    error = null,
                )
                if (!moved) {
                    error(runBlocking { getString(Res.string.downloads_error_finalize_file_failed) })
                }

                val localFileUri = NSURL.fileURLWithPath(destinationPath).absoluteString ?: "file://$destinationPath"
                val finalSize = fileSizeOrNull(destinationPath)
                onSuccess(localFileUri, totalBytes ?: finalSize)
            } catch (_: CancellationException) {
                handle.cancelNativeTask()
            } catch (error: Throwable) {
                onFailure(error.message ?: runBlocking { getString(Res.string.download_failed) })
            }
        }

        return handle
    }

    actual fun restoreItem(item: DownloadItem): DownloadItem {
        val pausedItem = if (item.status == DownloadStatus.Downloading) {
            item.copy(status = DownloadStatus.Paused, errorMessage = null)
        } else {
            item
        }
        val downloadsDirectory = downloadsDirectoryPath()
        val destinationPath = "$downloadsDirectory/${item.fileName}"
        val partsDir = "$destinationPath.parts"
        if (NSFileManager.defaultManager.fileExistsAtPath(partsDir)) {
            val contents = NSFileManager.defaultManager.contentsOfDirectoryAtPath(partsDir, null)
            if (contents != null) {
                var totalPartsSize = 0L
                for (itemObj in contents) {
                    val sName = itemObj as? String ?: continue
                    if (sName.startsWith("chunk_") && !sName.endsWith(".tmp")) {
                        totalPartsSize += fileSizeOrNull("$partsDir/$sName") ?: 0L
                    }
                }
                if (totalPartsSize > 0L) {
                    return pausedItem.copy(
                        downloadedBytes = totalPartsSize,
                        totalBytes = pausedItem.totalBytes,
                    )
                }
            }
        }
        return pausedItem
    }

    actual fun removeFile(localFileUri: String?): Boolean {
        if (localFileUri.isNullOrBlank()) return false
        val path = localFileUri.toLocalPath() ?: return false
        removePathIfExists("$path.parts")
        removePathIfExists("$path.part")
        if (NSFileManager.defaultManager.fileExistsAtPath(path)) {
            return removePathIfExists(path)
        }

        val fileName = path.substringAfterLast('/').takeIf { it.isNotBlank() } ?: return false
        val dest = "${downloadsDirectoryPath()}/$fileName"
        removePathIfExists("$dest.parts")
        removePathIfExists("$dest.part")
        return removePathIfExists(dest)
    }

    actual fun removePartialFile(destinationFileName: String): Boolean {
        val destinationPath = "${downloadsDirectoryPath()}/$destinationFileName"
        DownloadSubtitleStorage(NSURL.fileURLWithPath(destinationPath).absoluteString!!).remove()
        removePathIfExists("$destinationPath.parts")
        return removePathIfExists("$destinationPath.part")
    }

    actual fun resolveLocalFileUri(localFileUri: String?, destinationFileName: String): String? {
        localFileUri?.toLocalPath()
            ?.takeIf { NSFileManager.defaultManager.fileExistsAtPath(it) }
            ?.let { path ->
                return NSURL.fileURLWithPath(path).absoluteString ?: "file://$path"
            }

        val fileName = destinationFileName.trim().takeIf { it.isNotBlank() }
            ?: localFileUri?.toLocalPath()?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
            ?: return null
        val currentPath = "${downloadsDirectoryPath()}/$fileName"
        return if (NSFileManager.defaultManager.fileExistsAtPath(currentPath)) {
            NSURL.fileURLWithPath(currentPath).absoluteString ?: "file://$currentPath"
        } else {
            null
        }
    }

    actual fun openDownloadsDirectory(): Boolean {
        val url = NSURL.fileURLWithPath(downloadsDirectoryPath())
        UIApplication.sharedApplication.openURL(
            url = url,
            options = emptyMap<Any?, Any>(),
            completionHandler = null,
        )
        return true
    }
}

private class IosDownloadsTaskHandle(
    private val job: Job,
) : DownloadsTaskHandle {
    private val lock = NSLock()
    private val tasks = mutableSetOf<NSURLSessionTask>()
    private val sessions = mutableSetOf<NSURLSession>()

    fun attach(task: NSURLSessionTask, session: NSURLSession) {
        lock.withLock {
            tasks.add(task)
            sessions.add(session)
        }
    }

    fun detach(task: NSURLSessionTask) {
        lock.withLock {
            tasks.remove(task)
        }
    }

    override fun cancel() {
        cancelNativeTask()
        job.cancel()
    }

    fun cancelNativeTask() {
        lock.withLock {
            tasks.forEach { runCatching { it.cancel() } }
            sessions.forEach { runCatching { it.invalidateAndCancel() } }
            tasks.clear()
            sessions.clear()
        }
    }
}

private data class StreamProbeResult(
    val supportsRange: Boolean,
    val totalBytes: Long?,
    val statusCode: Int,
)

@OptIn(ExperimentalForeignApi::class)
private suspend fun probeStream(
    request: DownloadPlatformRequest,
    handle: IosDownloadsTaskHandle,
): StreamProbeResult {
    return try {
        val url = NSURL(string = request.sourceUrl) ?: return StreamProbeResult(false, null, 0)
        val nativeRequest = NSMutableURLRequest(
            uRL = url,
            cachePolicy = NSURLRequestReloadIgnoringLocalCacheData,
            timeoutInterval = 15.0,
        ).apply {
            setHTTPMethod("GET")
            setAllowsCellularAccess(true)
            setAllowsExpensiveNetworkAccess(true)
            setAllowsConstrainedNetworkAccess(true)
            request.sourceHeaders.forEach { (key, value) ->
                setValue(value, forHTTPHeaderField = key)
            }
            val hasUserAgent = request.sourceHeaders.keys.any { it.equals("User-Agent", ignoreCase = true) }
            if (!hasUserAgent) {
                setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                    forHTTPHeaderField = "User-Agent"
                )
            }
            setValue("identity", forHTTPHeaderField = "Accept-Encoding")
            setValue("bytes=0-0", forHTTPHeaderField = "Range")
        }

        val deferred = CompletableDeferred<StreamProbeResult>()
        val config = NSURLSessionConfiguration.defaultSessionConfiguration().apply {
            timeoutIntervalForRequest = 15.0
            timeoutIntervalForResource = 30.0
            setURLCache(null)
        }

        val delegate = object : NSObject(), NSURLSessionDataDelegateProtocol {
            override fun URLSession(
                session: NSURLSession,
                dataTask: NSURLSessionDataTask,
                didReceiveResponse: NSURLResponse,
                completionHandler: (Long) -> Unit,
            ) {
                val httpResponse = didReceiveResponse as? NSHTTPURLResponse
                val code = httpResponse?.statusCode?.toInt() ?: 200
                val cr = httpResponse?.valueForHTTPHeaderField("Content-Range")
                val total = parseContentRangeTotal(cr)
                    ?: httpResponse?.valueForHTTPHeaderField("Content-Length")?.toLongOrNull()
                val supportsRange = (code == 206 && cr != null && total != null && total > 0L)
                deferred.complete(StreamProbeResult(supportsRange = supportsRange, totalBytes = total, statusCode = code))
                completionHandler(0L) // Cancel remaining body transfer
            }

            override fun URLSession(
                session: NSURLSession,
                task: NSURLSessionTask,
                didCompleteWithError: NSError?,
            ) {
                if (!deferred.isCompleted) {
                    if (didCompleteWithError != null) {
                        deferred.complete(StreamProbeResult(supportsRange = false, totalBytes = null, statusCode = 0))
                    } else {
                        deferred.complete(StreamProbeResult(supportsRange = false, totalBytes = null, statusCode = 200))
                    }
                }
            }
        }

        val session = NSURLSession.sessionWithConfiguration(
            config,
            delegate,
            NSOperationQueue().apply { maxConcurrentOperationCount = 1 }
        )
        val task = session.dataTaskWithRequest(nativeRequest)
        handle.attach(task, session)
        task.resume()

        try {
            deferred.await()
        } finally {
            handle.detach(task)
            session.finishTasksAndInvalidate()
        }
    } catch (_: Throwable) {
        StreamProbeResult(supportsRange = false, totalBytes = null, statusCode = 0)
    }
}

@OptIn(ExperimentalForeignApi::class)
private class WorkerChunkDelegate : NSObject(), NSURLSessionDataDelegateProtocol {
    private var currentDeferred: CompletableDeferred<Unit>? = null
    private var currentFile: CPointer<FILE>? = null
    private var expectedBytes: Long = 0L
    private var receivedBytes: Long = 0L
    private var onProgress: ((Long) -> Unit)? = null
    private var fileError: Throwable? = null

    fun prepareForChunk(
        expectedBytes: Long,
        tempPath: String,
        onProgress: (Long) -> Unit,
    ): CompletableDeferred<Unit> {
        val deferred = CompletableDeferred<Unit>()
        this.currentDeferred = deferred
        this.expectedBytes = expectedBytes
        this.receivedBytes = 0L
        this.onProgress = onProgress
        this.fileError = null

        val f = fopen(tempPath, "wb")
        if (f == null) {
            val err = IllegalStateException("Failed to open chunk temp file $tempPath")
            this.fileError = err
            deferred.completeExceptionally(err)
        } else {
            this.currentFile = f
        }
        return deferred
    }

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveResponse: NSURLResponse,
        completionHandler: (Long) -> Unit,
    ) {
        val http = didReceiveResponse as? NSHTTPURLResponse
        val code = http?.statusCode?.toInt() ?: 200
        if (code !in 200..299) {
            fileError = IllegalStateException("HTTP $code")
            completionHandler(0L) // Cancel
            return
        }
        completionHandler(1L) // Allow
    }

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveData: NSData,
    ) {
        if (fileError != null) return
        val f = currentFile ?: return
        val len = didReceiveData.length.toLong()
        val wrote = fwrite(didReceiveData.bytes, 1.convert(), len.convert(), f).toLong()
        if (wrote != len) {
            fileError = IllegalStateException("Failed to write chunk data")
            return
        }
        receivedBytes += len
        onProgress?.invoke(receivedBytes)
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        didCompleteWithError: NSError?,
    ) {
        closeFile()
        val d = currentDeferred ?: return
        if (didCompleteWithError != null) {
            val isCancelled = (didCompleteWithError.code == -999L)
            if (isCancelled) {
                d.completeExceptionally(CancellationException(didCompleteWithError.localizedDescription))
            } else {
                d.completeExceptionally(IllegalStateException(didCompleteWithError.localizedDescription))
            }
            return
        }
        val err = fileError
        if (err != null) {
            d.completeExceptionally(err)
            return
        }
        if (receivedBytes < expectedBytes) {
            d.completeExceptionally(IllegalStateException("Incomplete chunk data ($receivedBytes < $expectedBytes)"))
            return
        }
        d.complete(Unit)
    }

    fun closeFile() {
        currentFile?.let { f ->
            fflush(f)
            fclose(f)
        }
        currentFile = null
    }
}

@OptIn(ExperimentalForeignApi::class)
private class IosDownloadWorker(
    val workerId: Int,
    val request: DownloadPlatformRequest,
    val handle: IosDownloadsTaskHandle,
) {
    private val delegate = WorkerChunkDelegate()
    val session: NSURLSession

    init {
        val config = NSURLSessionConfiguration.defaultSessionConfiguration().apply {
            timeoutIntervalForRequest = DOWNLOAD_REQUEST_TIMEOUT_SECONDS
            timeoutIntervalForResource = DOWNLOAD_RESOURCE_TIMEOUT_SECONDS
            waitsForConnectivity = true
            allowsCellularAccess = true
            allowsExpensiveNetworkAccess = true
            allowsConstrainedNetworkAccess = true
            setHTTPMaximumConnectionsPerHost(4L)
            setURLCache(null)
        }
        val queue = NSOperationQueue().apply {
            maxConcurrentOperationCount = 1
        }
        session = NSURLSession.sessionWithConfiguration(config, delegate, queue)
    }

    suspend fun downloadChunk(
        startByte: Long,
        endByte: Long,
        expectedBytes: Long,
        tempChunkPath: String,
        onChunkProgress: (Long) -> Unit,
    ) {
        val url = NSURL(string = request.sourceUrl) ?: error("Invalid source URL")
        val nativeRequest = NSMutableURLRequest(
            uRL = url,
            cachePolicy = NSURLRequestReloadIgnoringLocalCacheData,
            timeoutInterval = DOWNLOAD_REQUEST_TIMEOUT_SECONDS,
        ).apply {
            setHTTPMethod("GET")
            setAllowsCellularAccess(true)
            setAllowsExpensiveNetworkAccess(true)
            setAllowsConstrainedNetworkAccess(true)
            request.sourceHeaders.forEach { (key, value) ->
                setValue(value, forHTTPHeaderField = key)
            }
            val hasUserAgent = request.sourceHeaders.keys.any { it.equals("User-Agent", ignoreCase = true) }
            if (!hasUserAgent) {
                setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                    forHTTPHeaderField = "User-Agent"
                )
            }
            setValue("identity", forHTTPHeaderField = "Accept-Encoding")
            setValue("bytes=$startByte-$endByte", forHTTPHeaderField = "Range")
        }

        val deferred = delegate.prepareForChunk(expectedBytes, tempChunkPath, onChunkProgress)
        val task = session.dataTaskWithRequest(nativeRequest)
        handle.attach(task, session)
        task.resume()

        try {
            deferred.await()
        } finally {
            handle.detach(task)
            delegate.closeFile()
        }
    }

    fun close() {
        session.finishTasksAndInvalidate()
    }
}

@OptIn(ExperimentalForeignApi::class)
private suspend fun performMultiWorkerDownload(
    request: DownloadPlatformRequest,
    totalBytes: Long,
    tempPath: String,
    destinationPath: String,
    partsDir: String,
    handle: IosDownloadsTaskHandle,
    onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
    onSuccess: (localFileUri: String, totalBytes: Long?) -> Unit,
) {
    val totalChunks = (totalBytes + DOWNLOAD_CHUNK_SIZE - 1L) / DOWNLOAD_CHUNK_SIZE

    NSFileManager.defaultManager.createDirectoryAtPath(
        path = partsDir,
        withIntermediateDirectories = true,
        attributes = null,
        error = null,
    )

    fun expectedSizeForChunk(chunkIndex: Long): Long {
        val start = chunkIndex * DOWNLOAD_CHUNK_SIZE
        val end = minOf(start + DOWNLOAD_CHUNK_SIZE - 1L, totalBytes - 1L)
        return end - start + 1L
    }

    // 1. Scan existing chunks for resume
    val completedChunks = mutableSetOf<Long>()
    for (c in 0L until totalChunks) {
        val chunkPath = "$partsDir/chunk_$c"
        val expected = expectedSizeForChunk(c)
        val actual = fileSizeOrNull(chunkPath)
        if (actual == expected) {
            completedChunks.add(c)
        } else if (actual != null) {
            removePathIfExists(chunkPath)
        }
    }

    val queueLock = NSLock()
    var completedBytes = completedChunks.sumOf { expectedSizeForChunk(it) }
    val inFlightBytes = mutableMapOf<Long, Long>()
    var lastProgressTimestamp = 0.0
    var lastProgressBytes = -1L

    fun reportProgressSafe() {
        val now = NSDate().timeIntervalSince1970
        val currentDownloaded = queueLock.withLock {
            completedBytes + inFlightBytes.values.sum()
        }

        val byteDelta = currentDownloaded - lastProgressBytes
        val timeDelta = now - lastProgressTimestamp
        val isAtEnd = currentDownloaded >= totalBytes

        if (lastProgressBytes >= 0L && !isAtEnd && byteDelta < PROGRESS_MIN_BYTE_DELTA && timeDelta < PROGRESS_MIN_INTERVAL_SECONDS) {
            return
        }
        lastProgressBytes = currentDownloaded
        lastProgressTimestamp = now
        onProgress(currentDownloaded, totalBytes)
    }

    reportProgressSafe()

    // 2. Download missing chunks with 4 workers in parallel
    val remainingChunks = (0L until totalChunks).filter { it !in completedChunks }.toMutableList()

    if (remainingChunks.isNotEmpty()) {
        val workerCount = minOf(DOWNLOAD_MAX_WORKERS, remainingChunks.size)
        val workers = (1..workerCount).map { id ->
            IosDownloadWorker(workerId = id, request = request, handle = handle)
        }

        try {
            coroutineScope {
                workers.forEach { worker ->
                    launch {
                        while (isActive) {
                            val chunkIndex = queueLock.withLock {
                                if (remainingChunks.isEmpty()) null else remainingChunks.removeAt(0)
                            } ?: break

                            val chunkStart = chunkIndex * DOWNLOAD_CHUNK_SIZE
                            val chunkEnd = minOf(chunkStart + DOWNLOAD_CHUNK_SIZE - 1L, totalBytes - 1L)
                            val expected = chunkEnd - chunkStart + 1L
                            val chunkPath = "$partsDir/chunk_$chunkIndex"
                            val tempChunkPath = "$chunkPath.tmp"

                            var success = false
                            var lastError: Throwable? = null

                            for (attempt in 1..4) {
                                if (!isActive) break
                                removePathIfExists(tempChunkPath)
                                try {
                                    worker.downloadChunk(
                                        startByte = chunkStart,
                                        endByte = chunkEnd,
                                        expectedBytes = expected,
                                        tempChunkPath = tempChunkPath,
                                        onChunkProgress = { bytesSoFar ->
                                            queueLock.withLock {
                                                inFlightBytes[chunkIndex] = bytesSoFar
                                            }
                                            reportProgressSafe()
                                        }
                                    )

                                    val written = fileSizeOrNull(tempChunkPath)
                                    if (written == expected) {
                                        removePathIfExists(chunkPath)
                                        val moved = NSFileManager.defaultManager.moveItemAtPath(tempChunkPath, chunkPath, null)
                                        if (moved) {
                                            success = true
                                            break
                                        }
                                    }
                                } catch (e: CancellationException) {
                                    removePathIfExists(tempChunkPath)
                                    throw e
                                } catch (e: Throwable) {
                                    lastError = e
                                    removePathIfExists(tempChunkPath)
                                    delay(300L * attempt)
                                }
                            }

                            if (!success) {
                                queueLock.withLock {
                                    inFlightBytes.remove(chunkIndex)
                                }
                                throw (lastError ?: IllegalStateException("Failed downloading chunk $chunkIndex"))
                            }

                            queueLock.withLock {
                                completedChunks.add(chunkIndex)
                                inFlightBytes.remove(chunkIndex)
                                completedBytes += expected
                            }
                            reportProgressSafe()
                        }
                    }
                }
            }
        } finally {
            workers.forEach { it.close() }
        }
    }

    // 3. Assemble chunks into tempPath
    removePathIfExists(tempPath)
    val finalFile = fopen(tempPath, "wb") ?: error("Failed to create assembled file at $tempPath")
    try {
        val copyBuffer = ByteArray(512 * 1024)
        copyBuffer.usePinned { pinned ->
            for (c in 0L until totalChunks) {
                val chunkPath = "$partsDir/chunk_$c"
                val chunkFile = fopen(chunkPath, "rb") ?: error("Failed to open chunk $c for assembly")
                try {
                    while (true) {
                        val read = fread(pinned.addressOf(0), 1.convert(), copyBuffer.size.convert(), chunkFile).toLong()
                        if (read <= 0L) break
                        val wrote = fwrite(pinned.addressOf(0), 1.convert(), read.convert(), finalFile).toLong()
                        if (wrote != read) error("Failed writing to assembly file for chunk $c")
                    }
                } finally {
                    fclose(chunkFile)
                    removePathIfExists(chunkPath)
                }
            }
        }
    } finally {
        fclose(finalFile)
    }
    removePathIfExists(partsDir)

    // 4. Move assembled file to final destination
    removePathIfExists(destinationPath)
    val moved = NSFileManager.defaultManager.moveItemAtPath(tempPath, destinationPath, null)
    if (!moved) {
        error("Failed to move assembled file to $destinationPath")
    }

    val finalSize = fileSizeOrNull(destinationPath) ?: totalBytes
    val localUri = NSURL.fileURLWithPath(destinationPath).absoluteString ?: "file://$destinationPath"
    onSuccess(localUri, finalSize)
}

private data class IosDownloadResult(
    val statusCode: Int,
    val contentRange: String?,
    val contentLength: Long?,
)

@OptIn(ExperimentalForeignApi::class)
private class IosDownloadDelegate(
    private val attemptedRangeRequest: Boolean,
    private val resumeFromBytes: Long,
    private val tempPath: String,
    private val onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
) : NSObject(), NSURLSessionDataDelegateProtocol {
    private val completion = CompletableDeferred<IosDownloadResult>()
    private var result: IosDownloadResult? = null
    private var fileError: Throwable? = null
    private var outputFile: CPointer<FILE>? = null
    private var startingBytesForResponse = 0L
    private var bytesWrittenForResponse = 0L
    private var totalBytesForResponse: Long? = null
    private var lastProgressBytes = -1L
    private var lastProgressTimestampSeconds = 0.0
    private var bytesSinceLastFlush = 0L

    suspend fun awaitCompletion(): IosDownloadResult = completion.await()

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveResponse: NSURLResponse,
        completionHandler: (Long) -> Unit,
    ) {
        val httpResponse = didReceiveResponse as? NSHTTPURLResponse
        val statusCode = httpResponse?.statusCode?.toInt() ?: 200
        val nextResult = IosDownloadResult(
            statusCode = statusCode,
            contentRange = httpResponse?.valueForHTTPHeaderField("Content-Range"),
            contentLength = httpResponse
                ?.valueForHTTPHeaderField("Content-Length")
                ?.toLongOrNull()
                ?.takeIf { it > 0L },
        )
        result = nextResult

        if (statusCode in 200..299) {
            val isPartialResume = attemptedRangeRequest && statusCode == 206 && resumeFromBytes > 0L
            startingBytesForResponse = if (isPartialResume) resumeFromBytes else 0L
            bytesWrittenForResponse = 0L
            totalBytesForResponse = resolveTotalBytes(
                startingBytes = startingBytesForResponse,
                isPartialResume = isPartialResume,
                contentRangeHeader = nextResult.contentRange,
                contentLength = nextResult.contentLength,
            )

            outputFile = fopen(tempPath, if (isPartialResume) "ab" else "wb") ?: run {
                fileError = IllegalStateException(runBlocking { getString(Res.string.downloads_error_open_partial_file_failed) })
                null
            }

            reportProgress(startingBytesForResponse, totalBytesForResponse)
        }

        completionHandler(1L)
    }

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveData: NSData,
    ) {
        if (fileError != null) return

        val file = outputFile ?: run {
            fileError = IllegalStateException(runBlocking { getString(Res.string.downloads_error_partial_file_not_open) })
            return
        }

        val bytesToWrite = didReceiveData.length.toLong()
        val wrote = fwrite(
            didReceiveData.bytes,
            1.convert(),
            bytesToWrite.convert(),
            file,
        ).toLong()
        if (wrote != bytesToWrite) {
            fileError = IllegalStateException(runBlocking { getString(Res.string.downloads_error_write_partial_file_failed) })
            return
        }
        bytesSinceLastFlush += bytesToWrite
        if (bytesSinceLastFlush >= 512L * 1024L) {
            fflush(file)
            bytesSinceLastFlush = 0L
        }

        bytesWrittenForResponse += bytesToWrite
        reportProgress(
            downloadedBytes = startingBytesForResponse + bytesWrittenForResponse,
            totalBytes = totalBytesForResponse,
        )
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        didCompleteWithError: NSError?,
    ) {
        closeOutputFile()

        if (didCompleteWithError != null) {
            completion.completeExceptionally(
                IllegalStateException(didCompleteWithError.localizedDescription),
            )
            return
        }

        val error = fileError
        if (error != null) {
            completion.completeExceptionally(error)
            return
        }

        completion.complete(result ?: task.response.toDownloadResult())
    }

    override fun URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession) {
        val identifier = session.configuration.identifier ?: return
        backgroundSessionCompletionHandlers.remove(identifier)?.invoke()
    }

    private fun closeOutputFile() {
        outputFile?.let { file ->
            fflush(file)
            fclose(file)
        }
        outputFile = null
        bytesSinceLastFlush = 0L
    }

    private fun reportProgress(
        downloadedBytes: Long,
        totalBytes: Long?,
    ) {
        val normalizedDownloadedBytes = downloadedBytes.coerceAtLeast(0L)
        val now = NSDate().timeIntervalSince1970
        val byteDelta = normalizedDownloadedBytes - lastProgressBytes
        val timeDelta = now - lastProgressTimestampSeconds
        val reachedEnd = totalBytes != null && normalizedDownloadedBytes >= totalBytes

        if (
            lastProgressBytes >= 0L &&
            !reachedEnd &&
            byteDelta < PROGRESS_MIN_BYTE_DELTA &&
            timeDelta < PROGRESS_MIN_INTERVAL_SECONDS
        ) {
            return
        }

        lastProgressBytes = normalizedDownloadedBytes
        lastProgressTimestampSeconds = now
        onProgress(normalizedDownloadedBytes, totalBytes)
    }
}

private fun NSURLResponse?.toDownloadResult(): IosDownloadResult {
    val httpResponse = this as? NSHTTPURLResponse
    return IosDownloadResult(
        statusCode = httpResponse?.statusCode?.toInt() ?: 200,
        contentRange = httpResponse?.valueForHTTPHeaderField("Content-Range"),
        contentLength = httpResponse
            ?.valueForHTTPHeaderField("Content-Length")
            ?.toLongOrNull()
            ?.takeIf { it > 0L },
    )
}

@OptIn(ExperimentalForeignApi::class)
private fun downloadsDirectoryPath(): String {
    val root = NSHomeDirectory().trimEnd('/')
    val path = "$root/Documents/nuvio_downloads"
    NSFileManager.defaultManager.createDirectoryAtPath(
        path = path,
        withIntermediateDirectories = true,
        attributes = null,
        error = null,
    )
    return path
}

@OptIn(ExperimentalForeignApi::class)
private fun removePathIfExists(path: String): Boolean {
    if (!NSFileManager.defaultManager.fileExistsAtPath(path)) return true
    return NSFileManager.defaultManager.removeItemAtPath(path, null)
}

@OptIn(ExperimentalForeignApi::class)
private suspend fun performDownloadRequest(
    request: DownloadPlatformRequest,
    rangeStart: Long?,
    resumeFromBytes: Long,
    tempPath: String,
    handle: IosDownloadsTaskHandle,
    onProgress: (downloadedBytes: Long, totalBytes: Long?) -> Unit,
): IosDownloadResult {
    val url = NSURL(string = request.sourceUrl)
    val nativeRequest = NSMutableURLRequest(
        uRL = url,
        cachePolicy = NSURLRequestReloadIgnoringLocalCacheData,
        timeoutInterval = DOWNLOAD_REQUEST_TIMEOUT_SECONDS,
    )
    nativeRequest.setHTTPMethod("GET")
    nativeRequest.setAllowsCellularAccess(true)
    nativeRequest.setAllowsExpensiveNetworkAccess(true)
    nativeRequest.setAllowsConstrainedNetworkAccess(true)
    request.sourceHeaders.forEach { (key, value) ->
        nativeRequest.setValue(value, forHTTPHeaderField = key)
    }
    val hasUserAgent = request.sourceHeaders.keys.any { it.equals("User-Agent", ignoreCase = true) }
    if (!hasUserAgent) {
        nativeRequest.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField = "User-Agent"
        )
    }
    nativeRequest.setValue("identity", forHTTPHeaderField = "Accept-Encoding")
    if (rangeStart != null && rangeStart > 0L) {
        nativeRequest.setValue("bytes=$rangeStart-", forHTTPHeaderField = "Range")
    }

    val delegate = IosDownloadDelegate(
        attemptedRangeRequest = rangeStart != null && rangeStart > 0L,
        resumeFromBytes = resumeFromBytes,
        tempPath = tempPath,
        onProgress = onProgress,
    )
    val configuration = NSURLSessionConfiguration.defaultSessionConfiguration().apply {
        timeoutIntervalForRequest = DOWNLOAD_REQUEST_TIMEOUT_SECONDS
        timeoutIntervalForResource = DOWNLOAD_RESOURCE_TIMEOUT_SECONDS
        waitsForConnectivity = true
        allowsCellularAccess = true
        allowsExpensiveNetworkAccess = true
        allowsConstrainedNetworkAccess = true
        setHTTPShouldUsePipelining(true)
        setHTTPMaximumConnectionsPerHost(6L)
        setURLCache(null)
    }
    val session = NSURLSession.sessionWithConfiguration(
        configuration = configuration,
        delegate = delegate,
        delegateQueue = NSOperationQueue().apply {
            maxConcurrentOperationCount = 1
        },
    )
    val task = session.dataTaskWithRequest(nativeRequest)

    handle.attach(task, session)
    onProgress(resumeFromBytes.coerceAtLeast(0L), null)
    task.resume()

    return try {
        delegate.awaitCompletion()
    } finally {
        handle.detach(task)
        session.finishTasksAndInvalidate()
    }
}

@OptIn(ExperimentalForeignApi::class)
private fun fileSizeOrNull(path: String): Long? {
    val attrs = NSFileManager.defaultManager.attributesOfItemAtPath(path, error = null)
    val value = attrs?.get("NSFileSize")
    return when (value) {
        is Long -> value
        is Number -> value.toLong()
        else -> null
    }
}

private fun String.toLocalPath(): String? {
    val value = trim()
    if (value.startsWith("file:")) {
        return NSURL(string = value).path ?: value.removePrefix("file://")
    }
    return value.takeIf { it.isNotBlank() }
}

private fun resolveTotalBytes(
    startingBytes: Long,
    isPartialResume: Boolean,
    contentRangeHeader: String?,
    contentLength: Long?,
): Long? {
    parseContentRangeTotal(contentRangeHeader)?.let { return it }
    val normalizedLength = contentLength?.takeIf { it > 0L } ?: return null
    return if (isPartialResume && startingBytes > 0L) {
        startingBytes + normalizedLength
    } else {
        normalizedLength
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
