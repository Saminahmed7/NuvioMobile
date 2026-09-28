import Foundation
import Network
import ComposeApp

// MARK: - Samin loopback playback cache
//
// The player loads http://127.0.0.1:<port>/s/<key>/file instead of the
// remote URL. Bytes flow internet -> app Caches -> player, so replays
// inside cached ranges are instant and short outages are survivable.
// Watched data is evicted first under storage pressure; everything is
// deleted when the player closes (stopSession) or on cold start.
// MP4 progressive only for now (Range-based); HLS keeps direct playback.
//
// All session state lives on `queue`; Kotlin entry points hop onto it.

private let saminProxyChunkBytes: Int64 = 32 * 1024 * 1024
private let saminProxyLowSpaceBytes: Int64 = 500 * 1024 * 1024
private let saminProxyMaxRanges = 24
private let saminProxyMaxUnsentBytes = 32 * 1024 * 1024
private let saminProxyResumeUnsentBytes = 8 * 1024 * 1024

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
}

final class LocalCacheProxyCreator: NSObject, NuvioCacheProxyBridgeCreator {
    func createBridge() -> any NuvioCacheProxyBridge {
        return LocalCacheProxyBridgeImpl()
    }
}

enum NuvioCacheProxyRegistration {
    static func register() {
        NuvioCacheProxyBridgeFactory.shared.registerFactory(creator: LocalCacheProxyCreator())
        // Warm the loopback listener off the main thread so the first
        // playback never waits for a bind.
        LocalCacheProxyServer.shared.warmup()
    }
}

// MARK: - Server

final class LocalCacheProxyServer {
    static let shared = LocalCacheProxyServer()

    fileprivate let queue = DispatchQueue(label: "nuvio-cache-proxy")
    private lazy var delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 4
        return q
    }()

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
        // NOTE: NWListener(using:on:) only takes a port (all interfaces).
        // Loopback-only is enforced per-connection in accept() below, so no
        // local-network prompt and no LAN exposure.
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
        // Binding is asynchronous, so poll briefly for the port. The warmup
        // at registration means this is normally ready immediately.
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
        // The listener binds all interfaces (API limitation); only serve
        // loopback peers so nothing on the LAN can reach this server.
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

    fileprivate func makeDelegateQueue() -> OperationQueue {
        delegateQueue
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
    /// Set false when the session is torn down; in-flight fetches stop
    /// instead of recreating deleted files.
    var valid = true
    private(set) var cachedChunks: Set<Int64> = []
    var inFlightChunks: Set<Int64> = []
    private var servedOrder: [Int64] = []
    private var pinnedChunks: Set<Int64> = []
    private var prefetcher: SessionChunkPrefetcher?

    init(key: String, sourceUrl: String, headers: [String: String], baseDir: URL, server: LocalCacheProxyServer) {
        self.key = key
        self.sourceUrl = sourceUrl
        self.headers = headers
        self.dir = baseDir
        self.server = server
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.prefetcher = SessionChunkPrefetcher(session: self)
        probeTotalSizeIfNeeded()
    }

    func invalidate() {
        valid = false
        prefetcher?.cancel()
        prefetcher = nil
        try? FileManager.default.removeItem(at: dir)
    }

    var playheadByte: Int64? {
        guard let (pos, dur) = playheadMs, dur > 0, let total = totalSize, total > 0 else { return nil }
        return max(0, min(total, Int64((Double(pos) / Double(dur)) * Double(total))))
    }

    func chunkURL(_ index: Int64) -> URL {
        dir.appendingPathComponent("c\(index).bin")
    }

    func markServed(_ index: Int64) {
        servedOrder.removeAll(where: { $0 == index })
        servedOrder.append(index)
        if servedOrder.count > 4096 {
            servedOrder.removeFirst(servedOrder.count - 4096)
        }
    }

    func markCached(_ index: Int64) {
        cachedChunks.insert(index)
    }

    func pin(_ indices: [Int64]) {
        indices.forEach { pinnedChunks.insert($0) }
    }

    func unpin(_ indices: [Int64]) {
        indices.forEach { pinnedChunks.remove($0) }
    }

    /// Makes room for one more chunk. Only watched (strictly behind-playhead)
    /// chunks are evicted, and only when storage is actually below the safety threshold.
    /// Unwatched forward chunks are NEVER evicted.
    func makeRoomForChunk(excluding: Int64) -> Bool {
        guard server.freeSpaceBytes() < saminProxyLowSpaceBytes else { return true }
        let playheadChunk = playheadByte.map { $0 / saminProxyChunkBytes } ?? 0
        // Strictly evict chunks behind the playhead (already watched).
        let backwardWatched = cachedChunks.filter { $0 != excluding && $0 < playheadChunk && !pinnedChunks.contains($0) }.sorted()
        for victim in backwardWatched {
            removeChunk(victim)
            if server.freeSpaceBytes() >= saminProxyLowSpaceBytes { return true }
        }
        return server.freeSpaceBytes() >= saminProxyLowSpaceBytes
    }

    private func removeChunk(_ index: Int64) {
        cachedChunks.remove(index)
        inFlightChunks.remove(index)
        servedOrder.removeAll(where: { $0 == index })
        try? FileManager.default.removeItem(at: chunkURL(index))
    }

    private func onPlayheadUpdated() {
        guard valid else { return }
        let playheadChunk = playheadByte.map { $0 / saminProxyChunkBytes } ?? 0
        if let p = prefetcher, p.isRunning, p.chunkIndex < playheadChunk {
            // User sought ahead; cancel any backward fill so forward prefetch takes priority.
            p.cancel()
        }
        triggerPrefetch()
    }

    func probeTotalSizeIfNeeded() {
        guard totalSize == nil, let url = URL(string: sourceUrl) else { return }
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
            if let total, total > 0 {
                self.server.queue.async { [weak self] in
                    guard let self, self.valid else { return }
                    if self.totalSize == nil {
                        self.totalSize = total
                        if let type, self.contentType == nil {
                            self.contentType = type
                        }
                        self.triggerPrefetch()
                    }
                }
            }
        }.resume()
    }

    /// Prefetches the video into disk cache:
    /// 1. Entire forward span from playhead to end of file is cached first.
    /// 2. Backward span (before playhead) is cached only after forward finishes and storage has plenty of room.
    func triggerPrefetch() {
        guard valid, let total = totalSize, total > 0 else { return }
        guard let prefetcher = prefetcher, !prefetcher.isRunning else { return }

        let totalChunks = (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes
        let playheadChunk = playheadByte.map { $0 / saminProxyChunkBytes } ?? 0

        var targetChunk: Int64? = nil
        // 1. Forward chunks from playhead to end
        for idx in playheadChunk..<totalChunks {
            if !cachedChunks.contains(idx) && !inFlightChunks.contains(idx) {
                targetChunk = idx
                break
            }
        }

        // 2. Backward chunks from 0 to playhead, ONLY IF storage has plenty of space
        if targetChunk == nil {
            if server.freeSpaceBytes() >= saminProxyLowSpaceBytes {
                for idx in 0..<playheadChunk {
                    if !cachedChunks.contains(idx) && !inFlightChunks.contains(idx) {
                        targetChunk = idx
                        break
                    }
                }
            }
        }

        guard let chunkToFetch = targetChunk else { return }
        // Ensure space before fetching (evicts backward watched chunks if storage is low)
        guard makeRoomForChunk(excluding: chunkToFetch) else { return }

        let startByte = chunkToFetch * saminProxyChunkBytes
        let endByte = min(startByte + saminProxyChunkBytes - 1, total - 1)
        guard endByte >= startByte else { return }
        prefetcher.fetch(chunkIndex: chunkToFetch, startByte: startByte, endByte: endByte)
    }

    func cachedRangesJson() -> String {
        guard let total = totalSize, total > 0 else { return "[]" }
        let sorted = cachedChunks.sorted()
        var ranges: [(Int64, Int64)] = []
        for idx in sorted {
            let start = idx * saminProxyChunkBytes
            let end = min(start + saminProxyChunkBytes, total)
            if let last = ranges.last, last.1 >= start {
                ranges[ranges.count - 1] = (last.0, max(last.1, end))
            } else {
                ranges.append((start, end))
            }
        }
        let parts = ranges.prefix(saminProxyMaxRanges).map { s, e in
            "[\(Double(s) / Double(total)),\(Double(e) / Double(total))]"
        }
        return "[\(parts.joined(separator: ","))]"
    }
}

// MARK: - Dedicated Chunk Prefetcher

final class SessionChunkPrefetcher: NSObject, URLSessionDataDelegate {
    unowned let session: ProxySession
    private static let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private var urlSession: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private(set) var chunkIndex: Int64 = -1
    private var expectedBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var writeBuffer = Data()

    init(session: ProxySession) {
        self.session = session
        super.init()
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 4
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: SessionChunkPrefetcher.prefetchQueue)
    }

    func cancel() {
        task?.cancel()
        task = nil
        cleanup()
    }

    var isRunning: Bool {
        task != nil
    }

    func fetch(chunkIndex: Int64, startByte: Int64, endByte: Int64) {
        cancel()
        guard session.valid, let url = URL(string: session.sourceUrl) else { return }

        let fileUrl = session.chunkURL(chunkIndex)
        if !FileManager.default.fileExists(atPath: fileUrl.path) {
            FileManager.default.createFile(atPath: fileUrl.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileUrl) else { return }
        try? h.truncate(atOffset: 0)

        self.chunkIndex = chunkIndex
        self.handle = h
        self.expectedBytes = endByte - startByte + 1
        self.receivedBytes = 0
        self.writeBuffer.removeAll(keepingCapacity: true)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        session.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(startByte)-\(endByte)", forHTTPHeaderField: "Range")

        session.inFlightChunks.insert(chunkIndex)
        let t = urlSession?.dataTask(with: request)
        self.task = t
        t?.resume()
    }

    private func flushBuffer() {
        guard !writeBuffer.isEmpty, let h = handle else { return }
        let dataToFlush = writeBuffer
        writeBuffer.removeAll(keepingCapacity: true)
        try? h.write(contentsOf: dataToFlush)
    }

    private func cleanup() {
        flushBuffer()
        writeBuffer.removeAll(keepingCapacity: false)
        if chunkIndex >= 0 {
            session.inFlightChunks.remove(chunkIndex)
        }
        try? handle?.close()
        handle = nil
        chunkIndex = -1
        expectedBytes = 0
        receivedBytes = 0
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (http.statusCode == 200 || http.statusCode == 206) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty, handle != nil else { return }
        writeBuffer.append(data)
        receivedBytes += Int64(data.count)
        if writeBuffer.count >= 512 * 1024 {
            flushBuffer()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finishedChunk = chunkIndex
        let success = (error == nil) && (receivedBytes >= expectedBytes)
        cleanup()
        self.task = nil
        self.session.server.queue.async { [weak self] in
            guard let self, self.session.valid else { return }
            if success && finishedChunk >= 0 {
                self.session.markCached(finishedChunk)
            }
            self.session.triggerPrefetch()
        }
    }
}

// MARK: - Connection (one HTTP request, streamed)

final class ProxyConnection {
    private unowned let server: LocalCacheProxyServer
    private let connection: NWConnection
    private var buffer = Data()
    private var fetch: UpstreamFetch?
    private var closed = false

    // Streaming send state.
    private var sendQueue: [Data] = []
    private var sending = false
    private var unsentBytes = 0
    private var headersSent = false
    private var upstreamDone = false
    private var upstreamFailed = false

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
                self.abort()
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
        // Fully cached spans are served from disk with no upstream traffic:
        // this is what makes replays instant and outages survivable.
        if let total = session.totalSize, total > 0 {
            let start = range?.start ?? 0
            let end = min(range?.end ?? (total - 1), total - 1)
            if end >= start {
                if isSpanCached(session, start: start, end: end) {
                    serveFromDisk(session: session, start: start, end: end, ranged: hasRangeHeader)
                    return
                }
                let fetch = UpstreamFetch(
                    session: session,
                    range: ProxyRange(start: start, end: end),
                    owner: self
                )
                self.fetch = fetch
                fetch.start()
                return
            }
        }
        let fetch = UpstreamFetch(session: session, range: range, owner: self)
        self.fetch = fetch
        fetch.start()
    }

    private func isSpanCached(_ session: ProxySession, start: Int64, end: Int64) -> Bool {
        guard end >= start else { return false }
        var idx = start / saminProxyChunkBytes
        let last = end / saminProxyChunkBytes
        while idx <= last {
            if !session.cachedChunks.contains(idx) { return false }
            idx += 1
        }
        return true
    }

    private func serveFromDisk(session: ProxySession, start: Int64, end: Int64, ranged: Bool) {
        var headers: [(String, String)] = [
            ("Content-Type", session.contentType ?? "application/octet-stream"),
            ("Accept-Ranges", "bytes"),
            ("Connection", "close"),
        ]
        let status: Int
        if ranged {
            status = 206
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(session.totalSize ?? (end + 1))"))
            headers.append(("Content-Length", "\(end - start + 1)"))
        } else {
            status = 200
            headers.append(("Content-Length", "\(end - start + 1)"))
        }
        // Pin the span so eviction can't pull these files mid-response.
        var idx = start / saminProxyChunkBytes
        var pinned: [Int64] = []
        while idx <= end / saminProxyChunkBytes {
            pinned.append(idx)
            idx += 1
        }
        session.pin(pinned)
        pinnedSpan = (session, pinned)
        diskCursor = DiskCursor(sessionKey: session.key, index: start / saminProxyChunkBytes, offset: start, end: end)
        diskServing = true
        fetchDidRespond(status: status, headers: headers)
    }

    private func handleHead(_ session: ProxySession) {
        if let total = session.totalSize {
            respondNow(status: 200, headers: headHeaders(session: session, total: total), body: nil)
            return
        }
        guard let url = URL(string: session.sourceUrl) else {
            respondNow(status: 502, headers: [("Content-Length", "0")], body: nil)
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "HEAD"
        session.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            self.server.queue.async { [weak self] in
                guard let self, !self.closed else { return }
                let total = (response as? HTTPURLResponse)
                    .flatMap { $0.value(forHTTPHeaderField: "Content-Length") }
                    .flatMap(Int64.init)
                if let total, total > 0 {
                    session.totalSize = total
                    self.respondNow(status: 200, headers: self.headHeaders(session: session, total: total), body: nil)
                } else {
                    self.respondNow(status: 502, headers: [("Content-Length", "0")], body: nil)
                }
            }
        }.resume()
    }

    private func headHeaders(session: ProxySession, total: Int64) -> [(String, String)] {
        [
            ("Content-Type", session.contentType ?? "application/octet-stream"),
            ("Content-Length", "\(total)"),
            ("Accept-Ranges", "bytes"),
            ("Connection", "close"),
        ]
    }

    // MARK: - Upstream callbacks (all on the server queue)

    fileprivate func fetchDidRespond(status: Int, headers: [(String, String)]) {
        guard !closed, !headersSent else { return }
        headersSent = true
        var text = "HTTP/1.1 \(status) \(ProxyConnection.reason(status))\r\n"
        headers.forEach { text += "\($0): \($1)\r\n" }
        text += "\r\n"
        enqueue(Data(text.utf8))
    }

    fileprivate func fetchDidReceive(_ data: Data) {
        guard !closed, headersSent, !data.isEmpty else { return }
        enqueue(data)
    }

    fileprivate func fetchDidFinish(failed: Bool) {
        upstreamFailed = failed
        upstreamDone = true
        if failed && !headersSent {
            headersSent = true
            respondNow(status: 502, headers: [("Content-Length", "0")], body: nil)
            return
        }
        // Mid-stream failure after headers: just end the body (MPV treats
        // it like a dropped connection and retries per its own logic).
        pump()
    }

    private func enqueue(_ data: Data) {
        sendQueue.append(data)
        unsentBytes += data.count
        pump()
    }

    private func pump() {
        // Refill from a disk stream while the queue is shallow, so large
        // disk responses stream at socket pace with bounded RAM.
        while diskCursor != nil && sendQueue.count < 4 && !closed {
            guard let piece = readDiskPiece() else { break }
            if piece.isEmpty { break }
            sendQueue.append(piece)
            unsentBytes += piece.count
        }
        if diskCursor == nil && diskServing {
            diskServing = false
            upstreamDone = true
        }
        guard !sending else { return }
        guard !sendQueue.isEmpty else {
            if upstreamDone { close() }
            return
        }
        sending = true
        let chunk = sendQueue.removeFirst()
        unsentBytes -= chunk.count
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.sending = false
            self.pump()
        })
    }

    private func respondNow(status: Int, headers: [(String, String)], body: Data?) {
        var text = "HTTP/1.1 \(status) \(ProxyConnection.reason(status))\r\n"
        headers.forEach { text += "\($0): \($1)\r\n" }
        text += "\r\n"
        var payload = Data(text.utf8)
        if let body { payload.append(body) }
        headersSent = true
        upstreamDone = true
        enqueue(payload)
    }

    private func abort() {
        closed = true
        fetch?.cancel()
        fetch = nil
        sendQueue.removeAll()
        diskCursor = nil
        releasePinnedSpan()
        server.removeConnection(self)
        connection.cancel()
    }

    private func close() {
        closed = true
        fetch?.cancel()
        fetch = nil
        sendQueue.removeAll()
        diskCursor = nil
        releasePinnedSpan()
        server.removeConnection(self)
        connection.cancel()
    }

    // MARK: - Disk streaming

    private struct DiskCursor {
        let sessionKey: String
        var index: Int64
        var offset: Int64
        let end: Int64
    }

    private var diskCursor: DiskCursor?
    private var diskServing = false
    private var pinnedSpan: (ProxySession, [Int64])?

    /// Reads the next piece (up to 1MB) of the pinned disk span.
    private func readDiskPiece() -> Data? {
        guard var cursor = diskCursor,
              let session = server.session(for: cursor.sessionKey),
              cursor.offset <= cursor.end else {
            diskCursor = nil
            return nil
        }
        let url = session.chunkURL(cursor.index)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            diskCursor = nil
            return nil
        }
        defer { try? handle.close() }
        // Chunk files start at byte 0; convert the absolute offset.
        let fileOffset = cursor.offset - cursor.index * saminProxyChunkBytes
        guard fileOffset >= 0,
              (try? handle.seek(toOffset: UInt64(fileOffset))) != nil,
              let data = try? handle.read(upToCount: 1024 * 1024),
              !data.isEmpty else {
            diskCursor = nil
            return nil
        }
        cursor.offset += Int64(data.count)
        if cursor.offset > cursor.end {
            diskCursor = nil
        } else {
            if cursor.offset % saminProxyChunkBytes == 0 {
                cursor.index += 1
            }
            diskCursor = cursor
        }
        return data
    }

    private func releasePinnedSpan() {
        if let (session, indices) = pinnedSpan {
            session.unpin(indices)
        }
        pinnedSpan = nil
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
    let end: Int64? // nil = to end

    static func parse(_ header: String?, total: Int64?) -> ProxyRange? {
        guard let header else {
            return ProxyRange(start: 0, end: total.map { $0 - 1 })
        }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil } // no multipart
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

// MARK: - Upstream fetch (streams response -> client slices + chunk files)

final class UpstreamFetch: NSObject, URLSessionDataDelegate {
    private let session: ProxySession
    private let range: ProxyRange?
    private weak var owner: ProxyConnection?
    private var task: URLSessionDataTask?
    private var urlSession: URLSession?
    private var fileHandles: [Int64: FileHandle] = [:]
    private var streamOffset: Int64 = -1 // absolute file offset of the next byte
    private var lastMarkedChunk: Int64 = -1
    private var finished = false

    init(session: ProxySession, range: ProxyRange?, owner: ProxyConnection) {
        self.session = session
        self.range = range
        self.owner = owner
    }

    func start() {
        guard let url = URL(string: session.sourceUrl) else {
            finish(failed: true)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        session.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        // Byte-exact cache: never accept transformed encodings.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range {
            if let end = range.end {
                request.setValue("bytes=\(range.start)-\(end)", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(range.start)-", forHTTPHeaderField: "Range")
            }
        }
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.waitsForConnectivity = true
        let urlSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: session.server.makeDelegateQueue()
        )
        self.urlSession = urlSession
        let task = urlSession.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        urlSession?.invalidateAndCancel()
    }

    func setSuspended(_ suspended: Bool) {
        guard !finished else { return }
        if suspended {
            task?.suspend()
        } else {
            task?.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(failed: true)
            completionHandler(.cancel)
            return
        }
        let code = http.statusCode
        guard code == 200 || code == 206 else {
            finish(failed: true)
            completionHandler(.cancel)
            return
        }
        var lowered: [String: String] = [:]
        (http.allHeaderFields as? [String: String])?.forEach { k, v in
            lowered[k.lowercased()] = v
        }
        if self.session.totalSize == nil {
            if code == 206, let cr = lowered["content-range"], let total = ProxyConnectionTotal.parse(cr) {
                self.session.totalSize = total
                self.session.triggerPrefetch()
            } else if let len = lowered["content-length"].flatMap(Int64.init), len > 0 {
                self.session.totalSize = (code == 206 ? (self.range?.start ?? 0) : 0) + len
                self.session.triggerPrefetch()
            }
        }
        if self.session.contentType == nil,
           let type = lowered["content-type"], !type.isEmpty {
            self.session.contentType = type
        }
        // Answer the player NOW so playback starts while bytes stream in.
        // An upstream 206 always gets a 206 reply (MPV asked for a range);
        // lengths are included whenever known, otherwise the body is
        // close-delimited.
        let total = self.session.totalSize
        let start = range?.start ?? 0
        let end: Int64? = range?.end ?? total.map { $0 - 1 }
        var headers: [(String, String)] = [
            ("Content-Type", self.session.contentType ?? "application/octet-stream"),
            ("Accept-Ranges", "bytes"),
            ("Connection", "close"),
        ]
        let status: Int
        if range != nil {
            status = 206
            let totalToken = total.map(String.init) ?? "*"
            if let end, end >= start {
                headers.append(("Content-Range", "bytes \(start)-\(end)/\(totalToken)"))
                headers.append(("Content-Length", "\(end - start + 1)"))
            }
        } else if let total {
            status = 200
            headers.append(("Content-Length", "\(total)"))
        } else {
            status = 200 // unknown length: close-delimited body
        }
        owner?.fetchDidRespond(status: status, headers: headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        guard self.session.valid else {
            finish(failed: true)
            return
        }
        if streamOffset < 0 {
            // First bytes: absolute offset = requested start (a 200 after a
            // Range request means the full body from 0).
            var start = range?.start ?? 0
            if let http = dataTask.response as? HTTPURLResponse,
               http.statusCode == 200 {
                start = 0
            }
            streamOffset = start
        }
        writeThrough(offset: streamOffset, data: data)
        streamOffset += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(failed: error != nil)
    }

    // MARK: - Cache + forward

    private var chunkBytesWritten: [Int64: Int64] = [:]

    private func writeThrough(offset: Int64, data: Data) {
        var cursor = offset
        var remaining = data
        var out: [Data] = []
        while !remaining.isEmpty {
            let idx = cursor / saminProxyChunkBytes
            let chunkOff = cursor % saminProxyChunkBytes
            let room = saminProxyChunkBytes - chunkOff
            let take = min(Int64(remaining.count), room)
            let piece = remaining.prefix(Int(take))
            if session.cachedChunks.contains(idx) || cachePiece(index: idx, offset: chunkOff, data: piece) {
                out.append(Data(piece))
            } else {
                // Storage pressure and nothing safe to evict: still forward
                // these bytes to the player, just don't keep them.
                out.append(Data(piece))
            }
            if idx != lastMarkedChunk {
                lastMarkedChunk = idx
                session.markServed(idx)
            }
            cursor += take
            remaining = remaining.dropFirst(Int(take))
        }
        // Forward in arrival order (single piece or a chunk-boundary pair).
        out.forEach { owner?.fetchDidReceive($0) }
    }

    /// Returns true when the piece is (now) cached.
    private func cachePiece(index: Int64, offset: Int64, data: Data) -> Bool {
        if !session.cachedChunks.contains(index) {
            guard session.makeRoomForChunk(excluding: index) else { return false }
            let url = session.chunkURL(index)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            session.inFlightChunks.insert(index)
        }
        guard let handle = openHandle(index) else { return false }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            let written = (chunkBytesWritten[index] ?? 0) + Int64(data.count)
            chunkBytesWritten[index] = written
            if let total = session.totalSize {
                let startByte = index * saminProxyChunkBytes
                let endByte = min(startByte + saminProxyChunkBytes - 1, total - 1)
                let expected = endByte - startByte + 1
                if written >= expected {
                    session.markCached(index)
                    session.inFlightChunks.remove(index)
                    session.triggerPrefetch()
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func openHandle(_ index: Int64) -> FileHandle? {
        if let h = fileHandles[index] { return h }
        guard let h = try? FileHandle(forUpdating: session.chunkURL(index)) else { return nil }
        fileHandles[index] = h
        return h
    }

    private func finish(failed: Bool) {
        guard !finished else { return }
        finished = true
        fileHandles.values.forEach { try? $0.close() }
        fileHandles.removeAll()
        urlSession?.finishTasksAndInvalidate()
        owner?.fetchDidFinish(failed: failed)
        session.triggerPrefetch()
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
