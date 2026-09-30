import Foundation
import Network
import ComposeApp

// MARK: - Samin loopback playback cache
//
// The player loads http://127.0.0.1:<port>/s/<key>/file instead of the
// remote URL. Bytes flow internet -> app Caches -> player, so replays
// inside cached ranges are instant and short outages are survivable.
//
// High-Speed Architecture:
// 1. Single continuous upstream stream per seek point: downloads at full
//    line speed (matching Safari) directly to disk chunk files.
// 2. Client loopback reads directly from disk/buffer without blocking
//    or competing with upstream fetch.
// 3. Forward caching caches from current playhead to end of file first.
// 4. Backward caching runs sequentially only after forward caching reaches
//    EOF and free device storage is >= 500 MB.
// 5. Watched data behind the playhead is evicted only under storage pressure.
// 6. Ephemeral: everything is deleted when playback closes (stopSession).

private let saminProxyChunkBytes: Int64 = 8 * 1024 * 1024 // 8 MB chunks
private let saminProxyLowSpaceBytes: Int64 = 500 * 1024 * 1024 // 500 MB
private let saminProxyMaxRanges = 32
private let saminProxyPieceBytes: Int = 512 * 1024 // 512 KB socket send slices

final class LocalCacheProxyBridgeImpl: NSObject, NuvioCacheProxyBridge {
    func startSession(sessionKey: String, sourceUrl: String, headersJson: String?) -> String {
        return LocalCacheProxyServer.shared.startSession(
            key: sessionKey,
            sourceUrl: sourceUrl,
            headers: LocalCacheProxyServer.parseHeadersJson(headersJson)
        )
    }

    func stopSession(sessionKey: String) {
        LocalCacheProxyServer.shared.stopSession(key: sessionKey)
    }

    func stopAllSessions() {
        LocalCacheProxyServer.shared.stopAllSessions()
    }

    func setPlayhead(sessionKey: String, positionMs: Int64, durationMs: Int64) {
        LocalCacheProxyServer.shared.setPlayhead(key: sessionKey, positionMs: positionMs, durationMs: durationMs)
    }

    func cachedRangesJson(sessionKey: String) -> String {
        return LocalCacheProxyServer.shared.cachedRangesJson(key: sessionKey)
    }

    func cacheStatsJson(sessionKey: String) -> String {
        return LocalCacheProxyServer.shared.cacheStatsJson(key: sessionKey)
    }
}

final class LocalCacheProxyCreator: NSObject, NuvioCacheProxyBridgeCreator {
    func createBridge() -> any NuvioCacheProxyBridge {
        return LocalCacheProxyBridgeImpl()
    }
}

enum NuvioCacheProxyRegistration {
    static func register() {
        NuvioCacheProxyBridgeFactory.shared.registerFactory(creator: LocalCacheProxyCreator())
        LocalCacheProxyServer.shared.warmup()
    }
}

// MARK: - Server

final class LocalCacheProxyServer {
    static let shared = LocalCacheProxyServer()

    fileprivate let queue = DispatchQueue(label: "nuvio-cache-proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sessions: [String: ProxySession] = [:]
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]

    static func parseHeadersJson(_ json: String?) -> [String: String] {
        guard
            let json,
            !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = json.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        var out: [String: String] = [:]
        raw.forEach { key, value in
            guard let s = value as? String else { return }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, !v.isEmpty else { return }
            guard k.caseInsensitiveCompare("Range") != .orderedSame else { return }
            out[k] = v
        }
        return out
    }

    func warmup() {
        queue.async { [weak self] in self?.ensureListener() }
    }

    @discardableResult
    private func ensureListener() -> Bool {
        if listener != nil, port != 0 { return true }
        guard let wirePort = NWEndpoint.Port(rawValue: 0),
              let created = try? NWListener(using: .tcp, on: wirePort) else { return false }
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleListenerState(state, listener: created) }
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        created.start(queue: queue)
        return true
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
        case .failed, .cancelled:
            if self.listener === listener {
                self.listener = nil
                port = 0
            }
        default:
            break
        }
    }

    func startSession(key: String, sourceUrl: String, headers: [String: String]) -> String {
        for _ in 0..<50 {
            var url = ""
            queue.sync {
                guard ensureListener(), port != 0 else { return }
                sessions[key] = ProxySession(
                    key: key,
                    sourceUrl: sourceUrl,
                    headers: headers,
                    baseDir: cacheBaseDir().appendingPathComponent(key, isDirectory: true),
                    server: self
                )
                url = "http://127.0.0.1:\(port)/s/\(key)/file"
            }
            if !url.isEmpty { return url }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return ""
    }

    func stopSession(key: String) {
        queue.sync {
            if let session = sessions.removeValue(forKey: key) {
                session.invalidate()
            }
        }
    }

    func stopAllSessions() {
        queue.sync {
            sessions.values.forEach { $0.invalidate() }
            sessions.removeAll()
            try? FileManager.default.removeItem(at: cacheBaseDir())
        }
    }

    func setPlayhead(key: String, positionMs: Int64, durationMs: Int64) {
        queue.sync {
            sessions[key]?.playheadMs = (positionMs, durationMs)
        }
    }

    func cachedRangesJson(key: String) -> String {
        queue.sync {
            sessions[key]?.cachedRangesJson() ?? "[]"
        }
    }

    func cacheStatsJson(key: String) -> String {
        queue.sync {
            sessions[key]?.cacheStatsJson() ?? "{}"
        }
    }

    fileprivate func addConnection(_ handler: ProxyConnection) {
        connections[ObjectIdentifier(handler)] = handler
    }

    fileprivate func removeConnection(_ handler: ProxyConnection) {
        connections.removeValue(forKey: ObjectIdentifier(handler))
    }

    fileprivate func cacheBaseDir() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("nuvio_proxy", isDirectory: true)
    }

    fileprivate func freeSpaceBytes() -> Int64 {
        let dir = cacheBaseDir()
        if let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = vals.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        if let vals = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let cap = vals.volumeAvailableCapacity {
            return Int64(cap)
        }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return Int64.max
        }
        return free.int64Value
    }

    private func accept(_ connection: NWConnection) {
        if case .hostPort(let host, _) = connection.endpoint {
            let peer = "\(host)"
            if peer != "127.0.0.1" && peer != "::1" {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        ProxyConnection(server: self, connection: connection).begin()
    }

    fileprivate func session(for key: String) -> ProxySession? {
        sessions[key]
    }
}

// MARK: - Session (cached byte ranges of one upstream file)

final class ProxySession {
    let key: String
    let sourceUrl: String
    let headers: [String: String]
    let dir: URL
    unowned let server: LocalCacheProxyServer

    var totalSize: Int64?
    var contentType: String?
    var playheadMs: (Int64, Int64)? {
        didSet {
            onPlayheadUpdated()
        }
    }
    var valid = true
    private(set) var cachedChunks: Set<Int64> = []
    var bytesWrittenByChunk: [Int64: Int64] = [:]

    private var forwardDownloader: ForwardDownloader?
    private var backwardDownloader: BackwardDownloader?
    private var probeDownloader: BackwardDownloader?
    private var activeConnections: [ObjectIdentifier: ProxyConnection] = [:]
    private var headWaiters: [ProxyConnection] = []

    init(key: String, sourceUrl: String, headers: [String: String], baseDir: URL, server: LocalCacheProxyServer) {
        self.key = key
        self.sourceUrl = sourceUrl
        self.headers = headers
        self.dir = baseDir
        self.server = server
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        probeTotalSizeIfNeeded()
    }

    func invalidate() {
        valid = false
        forwardDownloader?.cancel()
        forwardDownloader = nil
        backwardDownloader?.cancel()
        backwardDownloader = nil
        probeDownloader?.cancel()
        probeDownloader = nil
        headWaiters.removeAll()
        let conns = Array(activeConnections.values)
        activeConnections.removeAll()
        conns.forEach { $0.forceClose() }
        try? FileManager.default.removeItem(at: dir)
    }

    var playheadByte: Int64? {
        guard let (pos, dur) = playheadMs, dur > 0, let total = totalSize, total > 0 else { return nil }
        return max(0, min(total, Int64((Double(pos) / Double(dur)) * Double(total))))
    }

    func chunkURL(_ index: Int64) -> URL {
        dir.appendingPathComponent("c\(index).bin")
    }

    func markCached(_ index: Int64) {
        cachedChunks.insert(index)
        bytesWrittenByChunk.removeValue(forKey: index)
    }

    func bytesAvailable(for chunkIndex: Int64) -> Int64 {
        if cachedChunks.contains(chunkIndex) {
            if let total = totalSize {
                let cStart = chunkIndex * saminProxyChunkBytes
                let cEnd = min(cStart + saminProxyChunkBytes - 1, total - 1)
                return max(0, cEnd - cStart + 1)
            }
            return saminProxyChunkBytes
        }
        return bytesWrittenByChunk[chunkIndex] ?? 0
    }

    func attachConnection(_ connection: ProxyConnection) {
        activeConnections[ObjectIdentifier(connection)] = connection
    }

    func detachConnection(_ connection: ProxyConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        headWaiters.removeAll(where: { $0 === connection })
    }

    func waitForHeaders(connection: ProxyConnection) {
        headWaiters.append(connection)
    }

    func notifyHeadersAvailable() {
        let waiters = headWaiters
        headWaiters.removeAll()
        waiters.forEach { $0.onHeadersAvailable() }
    }

    func notifyDataAvailable(chunkIndex: Int64) {
        activeConnections.values.forEach { $0.onDataAvailable(chunkIndex: chunkIndex) }
    }

    func notifyDownloadFailed() {
        activeConnections.values.forEach { $0.onDownloadFailed() }
    }

    /// Ensures a forward download stream is actively running from the requested byte offset.
    func ensureForwardDownloading(from startByte: Int64) {
        guard valid else { return }

        let chunkIdx = startByte / saminProxyChunkBytes

        // If totalSize is not known yet, start from alignedStart
        guard let total = totalSize, total > 0 else {
            let alignedStart = chunkIdx * saminProxyChunkBytes
            if forwardDownloader == nil {
                let fd = ForwardDownloader(session: self, startByte: alignedStart)
                self.forwardDownloader = fd
                fd.start()
            }
            return
        }

        // 1. If requested range is a probe near the end of file (e.g. moov atom)
        // and forwardDownloader is actively running near the beginning/playhead:
        if (total - startByte) <= 4 * 1024 * 1024,
           let fd = forwardDownloader, !fd.isFinished, fd.streamOffset < (total - 32 * 1024 * 1024) {
            fetchProbeChunk(chunkIndex: chunkIdx)
            return
        }

        // Find the first uncached chunk at or after chunkIdx
        let totalChunks = (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes
        var targetChunk = chunkIdx
        while targetChunk < totalChunks && cachedChunks.contains(targetChunk) {
            targetChunk += 1
        }

        if targetChunk >= totalChunks {
            // Everything forward from startByte to EOF is fully cached!
            forwardDownloader?.cancel()
            forwardDownloader = nil
            onForwardCompleted(startByte: startByte)
            return
        }

        let targetStartByte = targetChunk * saminProxyChunkBytes

        // 2. If forward downloader is already downloading this region forward, let it run at line rate
        if let fd = forwardDownloader, !fd.isFinished {
            if fd.startByte <= targetStartByte && fd.streamOffset >= targetStartByte {
                // Downloader has already passed or is currently streaming ahead of this chunk
                return
            }
            // If downloader is within 16 MB behind where bytes are needed,
            // let it keep running! It will reach this chunk in a couple seconds without reconnect penalty.
            if fd.streamOffset < targetStartByte && (targetStartByte - fd.streamOffset) <= 16 * 1024 * 1024 {
                return
            }
        }

        // 3. New seek point / reposition: cancel existing downloaders so 100% bandwidth serves the current play position
        forwardDownloader?.cancel()
        forwardDownloader = nil
        backwardDownloader?.cancel()
        backwardDownloader = nil

        let fd = ForwardDownloader(session: self, startByte: targetStartByte)
        self.forwardDownloader = fd
        fd.start()
    }

    func fetchProbeChunk(chunkIndex: Int64) {
        guard valid, probeDownloader == nil, !cachedChunks.contains(chunkIndex) else { return }
        let pd = BackwardDownloader(session: self, chunkIndex: chunkIndex)
        self.probeDownloader = pd
        pd.start()
    }

    func onForwardCompleted(startByte: Int64) {
        guard valid, let total = totalSize, total > 0 else { return }
        // When forward caching reaches EOF, check if storage has room for backward caching (>= 500 MB)
        guard server.freeSpaceBytes() >= saminProxyLowSpaceBytes else { return }
        startBackwardDownloadIfNeeded()
    }

    func startBackwardDownloadIfNeeded() {
        guard valid, let total = totalSize, total > 0 else { return }
        guard server.freeSpaceBytes() >= saminProxyLowSpaceBytes else { return }
        guard backwardDownloader == nil else { return }

        let totalChunks = (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes
        for idx in 0..<totalChunks {
            if !cachedChunks.contains(idx) {
                let bd = BackwardDownloader(session: self, chunkIndex: idx)
                self.backwardDownloader = bd
                bd.start()
                return
            }
        }
    }

    func onBackwardChunkCompleted(chunkIndex: Int64, success: Bool) {
        if backwardDownloader?.chunkIndex == chunkIndex {
            backwardDownloader = nil
        }
        if probeDownloader?.chunkIndex == chunkIndex {
            probeDownloader = nil
        }
        guard valid, success else { return }
        guard server.freeSpaceBytes() >= saminProxyLowSpaceBytes else { return }
        if forwardDownloader == nil || forwardDownloader?.isFinished == true {
            startBackwardDownloadIfNeeded()
        }
    }

    /// Makes room for one more chunk. Only strictly watched (behind-playhead)
    /// chunks are evicted when storage is low (< 500 MB). Forward unwatched chunks are NEVER evicted.
    func makeRoomForChunk(excluding: Int64) -> Bool {
        guard server.freeSpaceBytes() < saminProxyLowSpaceBytes else { return true }
        let playheadChunk = playheadByte.map { $0 / saminProxyChunkBytes } ?? 0
        let backwardWatched = cachedChunks.filter { $0 != excluding && $0 < playheadChunk }.sorted()
        for victim in backwardWatched {
            removeChunk(victim)
            if server.freeSpaceBytes() >= saminProxyLowSpaceBytes { return true }
        }
        return server.freeSpaceBytes() >= saminProxyLowSpaceBytes
    }

    private func removeChunk(_ index: Int64) {
        cachedChunks.remove(index)
        bytesWrittenByChunk.removeValue(forKey: index)
        try? FileManager.default.removeItem(at: chunkURL(index))
    }

    private func onPlayheadUpdated() {
        guard valid else { return }
        // Evict watched chunks behind the playhead if storage is currently tight
        _ = makeRoomForChunk(excluding: -1)
    }

    func probeTotalSizeIfNeeded(completion: (() -> Void)? = nil) {
        guard totalSize == nil, let url = URL(string: sourceUrl) else {
            completion?()
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "HEAD"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let total = (response as? HTTPURLResponse)
                .flatMap { $0.value(forHTTPHeaderField: "Content-Length") }
                .flatMap(Int64.init)
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            self.server.queue.async { [weak self] in
                guard let self, self.valid else { return }
                if let total, total > 0, self.totalSize == nil {
                    self.totalSize = total
                    if let type, self.contentType == nil {
                        self.contentType = type
                    }
                    self.notifyHeadersAvailable()
                }
                completion?()
            }
        }.resume()
    }

    func cachedRangesJson() -> String {
        guard let total = totalSize, total > 0 else { return "[]" }
        var rawRanges: [(Int64, Int64)] = []
        for idx in cachedChunks {
            let start = idx * saminProxyChunkBytes
            let end = min(start + saminProxyChunkBytes, total)
            rawRanges.append((start, end))
        }
        // Include partial progress of currently writing chunks
        for (idx, written) in bytesWrittenByChunk {
            if written > 0 && !cachedChunks.contains(idx) {
                let start = idx * saminProxyChunkBytes
                let end = min(start + written, total)
                rawRanges.append((start, end))
            }
        }
        guard !rawRanges.isEmpty else { return "[]" }
        rawRanges.sort { $0.0 < $1.0 }

        var merged: [(Int64, Int64)] = []
        for r in rawRanges {
            if let last = merged.last, last.1 >= r.0 {
                merged[merged.count - 1] = (last.0, max(last.1, r.1))
            } else {
                merged.append(r)
            }
        }

        let parts = merged.prefix(saminProxyMaxRanges).map { s, e in
            "[\(Double(s) / Double(total)),\(Double(e) / Double(total))]"
        }
        return "[\(parts.joined(separator: ","))]"
    }

    private var speedBytesAccumulator: Int64 = 0
    private var lastSpeedCheckUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastDataReceivedUptime: TimeInterval = 0
    private(set) var currentSpeedBps: Int64 = 0

    func recordBytesReceived(_ count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lastDataReceivedUptime = now
        speedBytesAccumulator += Int64(count)
        let elapsed = now - lastSpeedCheckUptime
        if elapsed >= 0.5 {
            currentSpeedBps = Int64(Double(speedBytesAccumulator) / elapsed)
            speedBytesAccumulator = 0
            lastSpeedCheckUptime = now
        }
    }

    func currentSpeed() -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDataReceivedUptime > 2.0 {
            return 0
        }
        return currentSpeedBps
    }

    func totalCachedBytes() -> Int64 {
        var total: Int64 = 0
        if let fileTotal = totalSize, fileTotal > 0 {
            for idx in cachedChunks {
                let cStart = idx * saminProxyChunkBytes
                let cEnd = min(cStart + saminProxyChunkBytes - 1, fileTotal - 1)
                total += max(0, cEnd - cStart + 1)
            }
        } else {
            total += Int64(cachedChunks.count) * saminProxyChunkBytes
        }
        for (idx, written) in bytesWrittenByChunk {
            if !cachedChunks.contains(idx) {
                total += written
            }
        }
        if let fileTotal = totalSize, total > fileTotal {
            total = fileTotal
        }
        return total
    }

    func cacheStatsJson() -> String {
        let speed = currentSpeed()
        let cached = totalCachedBytes()
        let total = totalSize ?? 0
        let totalChunks = (total > 0) ? (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes : 0
        let isComplete = (total > 0 && totalChunks > 0 && cachedChunks.count >= totalChunks)
        let ranges = cachedRangesJson()
        return "{\"speedBps\":\(speed),\"cachedBytes\":\(cached),\"totalBytes\":\(total),\"isComplete\":\(isComplete),\"ranges\":\(ranges)}"
    }
}

// MARK: - Forward Downloader (Single High-Speed Stream)

final class ForwardDownloader: NSObject, URLSessionDataDelegate {
    unowned let session: ProxySession
    let startByte: Int64
    private(set) var streamOffset: Int64
    private(set) var currentChunkIndex: Int64 = -1
    private(set) var isFinished = false

    private var task: URLSessionDataTask?
    private var urlSession: URLSession?
    private var fileHandle: FileHandle?
    private var fileHandleChunk: Int64 = -1
    private var isCancelled = false

    init(session: ProxySession, startByte: Int64) {
        self.session = session
        self.startByte = startByte
        self.streamOffset = startByte
    }

    func start() {
        guard session.valid, let url = URL(string: session.sourceUrl) else {
            finish(failed: true)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.networkServiceType = .default
        session.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(startByte)-", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.waitsForConnectivity = true
        config.networkServiceType = .default
        config.httpMaximumConnectionsPerHost = 6

        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.urlSession = s
        let t = s.dataTask(with: request)
        self.task = t
        t.resume()
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
        urlSession?.invalidateAndCancel()
        cleanupFileHandle()
    }

    private func cleanupFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        fileHandleChunk = -1
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isCancelled, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let code = http.statusCode
        guard code == 200 || code == 206 else {
            completionHandler(.cancel)
            finish(failed: true)
            return
        }

        var lowered: [String: String] = [:]
        (http.allHeaderFields as? [String: String])?.forEach { k, v in
            lowered[k.lowercased()] = v
        }

        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled, self.session.valid else { return }
            if self.session.totalSize == nil {
                if code == 206, let cr = lowered["content-range"], let total = ProxyConnectionTotal.parse(cr) {
                    self.session.totalSize = total
                } else if let len = lowered["content-length"].flatMap(Int64.init), len > 0 {
                    self.session.totalSize = (code == 206 ? self.startByte : 0) + len
                }
            }
            if self.session.contentType == nil, let type = lowered["content-type"], !type.isEmpty {
                self.session.contentType = type
            }
            self.session.notifyHeadersAvailable()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, !data.isEmpty else { return }
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled, self.session.valid else { return }
            self.processIncoming(data: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.finish(failed: error != nil)
        }
    }

    private func processIncoming(data: Data) {
        session.recordBytesReceived(data.count)
        var cursor = streamOffset
        var remaining = data

        while !remaining.isEmpty {
            let chunkIdx = cursor / saminProxyChunkBytes
            let chunkOffset = cursor % saminProxyChunkBytes
            let roomInChunk = saminProxyChunkBytes - chunkOffset
            let take = min(Int64(remaining.count), roomInChunk)
            let piece = remaining.prefix(Int(take))

            writePiece(chunkIndex: chunkIdx, offset: chunkOffset, piece: piece)

            cursor += take
            streamOffset += take
            remaining = remaining.dropFirst(Int(take))
        }
    }

    private func writePiece(chunkIndex: Int64, offset: Int64, piece: Data) {
        currentChunkIndex = chunkIndex

        if fileHandle == nil || fileHandleChunk != chunkIndex {
            cleanupFileHandle()
            let fileUrl = session.chunkURL(chunkIndex)
            if !FileManager.default.fileExists(atPath: fileUrl.path) {
                FileManager.default.createFile(atPath: fileUrl.path, contents: nil)
            }
            fileHandle = try? FileHandle(forUpdating: fileUrl)
            fileHandleChunk = chunkIndex
            _ = session.makeRoomForChunk(excluding: chunkIndex)
        }

        guard let h = fileHandle else { return }
        do {
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: piece)
            let totalWritten = offset + Int64(piece.count)
            session.bytesWrittenByChunk[chunkIndex] = totalWritten

            let expectedSize: Int64
            if let total = session.totalSize {
                let cStart = chunkIndex * saminProxyChunkBytes
                let cEnd = min(cStart + saminProxyChunkBytes - 1, total - 1)
                expectedSize = cEnd - cStart + 1
            } else {
                expectedSize = saminProxyChunkBytes
            }

            if totalWritten >= expectedSize {
                session.markCached(chunkIndex)
            }
            session.notifyDataAvailable(chunkIndex: chunkIndex)
        } catch {
            // Write error
        }
    }

    private func finish(failed: Bool) {
        guard !isFinished else { return }
        isFinished = true
        cleanupFileHandle()

        if !failed {
            // Check if current final chunk is complete
            if currentChunkIndex >= 0, let total = session.totalSize {
                let written = session.bytesWrittenByChunk[currentChunkIndex] ?? 0
                let cStart = currentChunkIndex * saminProxyChunkBytes
                let cEnd = min(cStart + saminProxyChunkBytes - 1, total - 1)
                if written >= (cEnd - cStart + 1) {
                    session.markCached(currentChunkIndex)
                }
            }
            session.onForwardCompleted(startByte: startByte)
        } else {
            session.notifyDownloadFailed()
        }
    }
}

// MARK: - Backward Downloader (Runs only after Forward caching completes)

final class BackwardDownloader: NSObject, URLSessionDataDelegate {
    unowned let session: ProxySession
    let chunkIndex: Int64
    private var task: URLSessionDataTask?
    private var urlSession: URLSession?
    private var fileHandle: FileHandle?
    private var expectedBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var isCancelled = false

    init(session: ProxySession, chunkIndex: Int64) {
        self.session = session
        self.chunkIndex = chunkIndex
    }

    func start() {
        guard session.valid, let total = session.totalSize, total > 0,
              let url = URL(string: session.sourceUrl) else { return }

        let startByte = chunkIndex * saminProxyChunkBytes
        let endByte = min(startByte + saminProxyChunkBytes - 1, total - 1)
        guard endByte >= startByte else { return }

        expectedBytes = endByte - startByte + 1
        receivedBytes = 0

        let fileUrl = session.chunkURL(chunkIndex)
        if !FileManager.default.fileExists(atPath: fileUrl.path) {
            FileManager.default.createFile(atPath: fileUrl.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileUrl) else { return }
        try? h.truncate(atOffset: 0)
        self.fileHandle = h

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.networkServiceType = .default
        session.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        config.networkServiceType = .default
        config.httpMaximumConnectionsPerHost = 6

        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.urlSession = s
        let t = s.dataTask(with: request)
        self.task = t
        t.resume()
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
        urlSession?.invalidateAndCancel()
        try? fileHandle?.close()
        fileHandle = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 206) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, !data.isEmpty, let h = fileHandle else { return }
        try? h.write(contentsOf: data)
        receivedBytes += Int64(data.count)
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.session.recordBytesReceived(data.count)
            self.session.bytesWrittenByChunk[self.chunkIndex] = self.receivedBytes
            self.session.notifyDataAvailable(chunkIndex: self.chunkIndex)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle?.close()
        fileHandle = nil
        let success = (error == nil && receivedBytes >= expectedBytes && !isCancelled)
        self.session.server.queue.async { [weak self] in
            guard let self, self.session.valid, !self.isCancelled else { return }
            if success {
                self.session.markCached(self.chunkIndex)
            }
            self.session.onBackwardChunkCompleted(chunkIndex: self.chunkIndex, success: success)
        }
    }
}

// MARK: - Connection (Streams from disk/buffer directly to loopback client)

final class ProxyConnection {
    private unowned let server: LocalCacheProxyServer
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false
    private var sessionKey = ""

    // Streaming state
    private var headersSent = false
    private var sending = false
    private var streamOffset: Int64 = 0
    private var streamEnd: Int64 = 0

    // Waiting for live data from forward downloader
    private var isWaitingForData = false
    private var waitingChunkIndex: Int64 = -1

    // Pending parameters while waiting for initial HEAD/GET headers
    private var pendingStart: Int64 = 0
    private var pendingEnd: Int64?
    private var pendingRanged = false

    // Cached reading file handle
    private var readHandle: (chunkIndex: Int64, handle: FileHandle)?

    init(server: LocalCacheProxyServer, connection: NWConnection) {
        self.server = server
        self.connection = connection
    }

    func begin() {
        server.addConnection(self)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.close()
            default:
                break
            }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil || data == nil {
                self.close()
                return
            }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 65536 {
                self.close()
                return
            }
            if let request = ProxyRequest.parse(self.buffer) {
                self.handle(request)
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ request: ProxyRequest) {
        guard request.method == "GET" || request.method == "HEAD" else {
            respondNow(status: 405, headers: [("Content-Length", "0")], body: nil)
            return
        }
        let parts = request.target.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[0] == "s", parts[2] == "file",
              let session = server.session(for: parts[1]) else {
            respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        self.sessionKey = parts[1]
        session.attachConnection(self)

        if request.method == "HEAD" {
            handleHead(session)
            return
        }

        let hasRangeHeader = request.headers["range"] != nil
        let range = ProxyRange.parse(request.headers["range"], total: session.totalSize)
        if hasRangeHeader && range == nil {
            respondNow(status: 416, headers: [("Content-Length", "0")], body: nil)
            return
        }
        if let total = session.totalSize, let range, range.start >= total {
            respondNow(status: 416, headers: [("Content-Length", "0")], body: nil)
            return
        }

        let start = range?.start ?? 0
        let requestedEnd = range?.end

        if let total = session.totalSize, total > 0 {
            let end = min(requestedEnd ?? (total - 1), total - 1)
            if end >= start {
                self.streamOffset = start
                self.streamEnd = end
                sendStreamingHeaders(session: session, start: start, end: end, ranged: hasRangeHeader)
                session.ensureForwardDownloading(from: start)
                pump()
                return
            }
        }

        // Wait for first response headers from upstream
        self.pendingStart = start
        self.pendingEnd = requestedEnd
        self.pendingRanged = hasRangeHeader
        session.waitForHeaders(connection: self)
        session.ensureForwardDownloading(from: start)
    }

    func onHeadersAvailable() {
        guard !closed, !headersSent, let session = server.session(for: sessionKey) else { return }
        let start = pendingStart
        let total = session.totalSize ?? (pendingEnd.map { $0 + 1 } ?? Int64.max)
        let end = min(pendingEnd ?? (total - 1), total - 1)
        guard end >= start else {
            respondNow(status: 416, headers: [("Content-Length", "0")], body: nil)
            return
        }
        self.streamOffset = start
        self.streamEnd = end
        sendStreamingHeaders(session: session, start: start, end: end, ranged: pendingRanged)
        pump()
    }

    func onDataAvailable(chunkIndex: Int64) {
        guard !closed, headersSent else { return }
        if isWaitingForData && (waitingChunkIndex == -1 || waitingChunkIndex == chunkIndex) {
            pump()
        }
    }

    func onDownloadFailed() {
        guard !closed else { return }
        if isWaitingForData {
            close()
        }
    }

    private func sendStreamingHeaders(session: ProxySession, start: Int64, end: Int64, ranged: Bool) {
        guard !headersSent else { return }
        headersSent = true
        var headers: [(String, String)] = [
            ("Content-Type", session.contentType ?? "application/octet-stream"),
            ("Accept-Ranges", "bytes"),
            ("Connection", "close")
        ]
        let status: Int
        if ranged {
            status = 206
            let totalToken = session.totalSize.map(String.init) ?? "*"
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(totalToken)"))
            headers.append(("Content-Length", "\(end - start + 1)"))
        } else {
            status = 200
            headers.append(("Content-Length", "\(end - start + 1)"))
        }
        var text = "HTTP/1.1 \(status) \(ProxyConnection.reason(status))\r\n"
        headers.forEach { text += "\($0): \($1)\r\n" }
        text += "\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.server.queue.async { [weak self] in
                guard let self else { return }
                if error != nil {
                    self.close()
                }
            }
        })
    }

    func pump() {
        guard !closed, !sending, headersSent else { return }
        guard streamOffset <= streamEnd else {
            close()
            return
        }
        guard let session = server.session(for: sessionKey) else {
            close()
            return
        }

        let chunkIdx = streamOffset / saminProxyChunkBytes
        let chunkOffset = streamOffset % saminProxyChunkBytes
        let available = session.bytesAvailable(for: chunkIdx)

        if chunkOffset < available {
            isWaitingForData = false
            waitingChunkIndex = -1

            let pieceLen = min(available - chunkOffset, Int64(saminProxyPieceBytes), streamEnd - streamOffset + 1)
            guard pieceLen > 0 else {
                close()
                return
            }

            guard let data = readChunkData(session: session, chunkIndex: chunkIdx, offset: chunkOffset, count: Int(pieceLen)) else {
                isWaitingForData = true
                waitingChunkIndex = chunkIdx
                return
            }

            sending = true
            streamOffset += Int64(data.count)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.server.queue.async { [weak self] in
                    guard let self else { return }
                    self.sending = false
                    if error != nil {
                        self.close()
                    } else {
                        self.pump()
                    }
                }
            })
        } else {
            // Reached current downloaded boundary; wait for forward downloader
            isWaitingForData = true
            waitingChunkIndex = chunkIdx
            session.ensureForwardDownloading(from: streamOffset)
        }
    }

    private func readChunkData(session: ProxySession, chunkIndex: Int64, offset: Int64, count: Int) -> Data? {
        if readHandle?.chunkIndex != chunkIndex {
            try? readHandle?.handle.close()
            readHandle = nil
            let url = session.chunkURL(chunkIndex)
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            readHandle = (chunkIndex, h)
        }
        guard let handle = readHandle?.handle else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    private func handleHead(_ session: ProxySession) {
        if let total = session.totalSize {
            respondNow(status: 200, headers: headHeaders(session: session, total: total), body: nil)
            return
        }
        session.probeTotalSizeIfNeeded { [weak self] in
            guard let self, !self.closed else { return }
            if let total = session.totalSize {
                self.respondNow(status: 200, headers: self.headHeaders(session: session, total: total), body: nil)
            } else {
                self.respondNow(status: 502, headers: [("Content-Length", "0")], body: nil)
            }
        }
    }

    private func headHeaders(session: ProxySession, total: Int64) -> [(String, String)] {
        [
            ("Content-Type", session.contentType ?? "application/octet-stream"),
            ("Content-Length", "\(total)"),
            ("Accept-Ranges", "bytes"),
            ("Connection", "close"),
        ]
    }

    private func respondNow(status: Int, headers: [(String, String)], body: Data?) {
        var text = "HTTP/1.1 \(status) \(ProxyConnection.reason(status))\r\n"
        headers.forEach { text += "\($0): \($1)\r\n" }
        text += "\r\n"
        var payload = Data(text.utf8)
        if let body { payload.append(body) }
        headersSent = true
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.server.queue.async { self?.close() }
        })
    }

    fileprivate func forceClose() {
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        try? readHandle?.handle.close()
        readHandle = nil
        server.session(for: sessionKey)?.detachConnection(self)
        server.removeConnection(self)
        connection.cancel()
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}

// MARK: - HTTP Request & Range Helpers

struct ProxyRequest {
    let method: String
    let target: String
    let headers: [String: String]

    static func parse(_ data: Data) -> ProxyRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else {
            return nil
        }
        let head = String(text[..<headerEnd.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return ProxyRequest(method: String(requestLine[0]).uppercased(), target: String(requestLine[1]), headers: headers)
    }
}

struct ProxyRange {
    let start: Int64
    let end: Int64?

    static func parse(_ header: String?, total: Int64?) -> ProxyRange? {
        guard let header else {
            return ProxyRange(start: 0, end: total.map { $0 - 1 })
        }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        if spec.hasPrefix("-"), let suffix = Int64(spec.dropFirst()), suffix > 0 {
            guard let total, total > 0 else { return nil }
            return ProxyRange(start: max(0, total - suffix), end: total - 1)
        }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2, let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)), start >= 0 else {
            return nil
        }
        let endPart = bounds[1].trimmingCharacters(in: .whitespaces)
        if endPart.isEmpty {
            return ProxyRange(start: start, end: total.map { $0 - 1 })
        }
        guard let end = Int64(endPart), end >= start else { return nil }
        return ProxyRange(start: start, end: end)
    }
}

enum ProxyConnectionTotal {
    static func parse(_ header: String) -> Int64? {
        let v = header.trimmingCharacters(in: .whitespaces)
        guard let slash = v.lastIndex(of: "/") else { return nil }
        let total = v[v.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total).flatMap { $0 > 0 ? $0 : nil }
    }
}
