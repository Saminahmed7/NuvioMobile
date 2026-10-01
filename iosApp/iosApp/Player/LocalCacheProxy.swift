import Foundation
import UIKit
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

private let saminProxyChunkBytes: Int64 = 16 * 1024 * 1024 // 16 MB chunks
private let saminProxyLowSpaceBytes: Int64 = 500 * 1024 * 1024 // 500 MB
private let saminProxyMaxRanges = 32
private let saminProxyPieceBytes: Int = 512 * 1024 // 512 KB socket send slices
private let saminProxyMinResumeBytes: Int64 = 512 * 1024 // 512 KB prebuffer lead
private let saminProxySegmentBytes: Int64 = 64 * 1024 * 1024 // 64 MB bounded upstream segment

final class LocalCacheProxyLog {
    static let shared = LocalCacheProxyLog()
    private var entries: [String] = []
    private let lock = NSLock()
    private let maxEntries = 150

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        lock.lock()
        if entries.count >= maxEntries {
            entries.removeFirst()
        }
        entries.append(line)
        lock.unlock()
        #if DEBUG
        print("[CacheProxy] \(line)")
        #endif
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}

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

    func diagnosticReport(sessionKey: String) -> String {
        return LocalCacheProxyServer.shared.diagnosticReport(key: sessionKey)
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
    private let preferredPorts: [UInt16] = [19842, 19843, 19844, 19845, 19846, 19847, 19848, 19849]
    private var preferredPortIndex = 0
    private var activeBoundPort: UInt16 = 19842

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillEnterForeground()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillEnterForeground()
        }
    }

    private func handleWillEnterForeground() {
        queue.async { [weak self] in
            guard let self else { return }
            LocalCacheProxyLog.shared.log("Server: Foreground notification received. Ensuring listener on port \(self.activeBoundPort)...")
            self.ensureListener()
        }
    }

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

    private func makeTcpParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        return params
    }

    @discardableResult
    func ensureListener() -> Bool {
        if listener != nil, port != 0 { return true }

        // If we have active sessions, we MUST stay on activeBoundPort (e.g. 19842)
        // so MPV's active stream URLs never get broken.
        if !sessions.isEmpty && activeBoundPort != 0 {
            if let wirePort = NWEndpoint.Port(rawValue: activeBoundPort),
               let created = try? NWListener(using: makeTcpParameters(), on: wirePort) {
                setupListener(created, port: activeBoundPort)
                LocalCacheProxyLog.shared.log("Server: Re-bound listener to active session port \(activeBoundPort)")
                return true
            }
        }

        // Try preferred ports in sequence
        while preferredPortIndex < preferredPorts.count {
            let portToTry = preferredPorts[preferredPortIndex]
            preferredPortIndex += 1
            guard let wirePort = NWEndpoint.Port(rawValue: portToTry),
                  let created = try? NWListener(using: makeTcpParameters(), on: wirePort) else { continue }
            setupListener(created, port: portToTry)
            activeBoundPort = portToTry
            LocalCacheProxyLog.shared.log("Server: Bound listener to preferred port \(portToTry)")
            return true
        }

        // Fallback: let OS assign ephemeral port
        guard let wirePort = NWEndpoint.Port(rawValue: 0),
              let created = try? NWListener(using: makeTcpParameters(), on: wirePort) else { return false }
        setupListener(created, port: 0)
        return true
    }

    private func setupListener(_ created: NWListener, port: UInt16) {
        self.listener = created
        self.port = port
        created.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleListenerState(state, listener: created) }
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        created.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            self.port = listener.port?.rawValue ?? self.activeBoundPort
            self.activeBoundPort = self.port
            LocalCacheProxyLog.shared.log("Server: Listener ready on port \(self.port)")
        case .failed(let error):
            LocalCacheProxyLog.shared.log("Server: Listener failed (\(error.localizedDescription))")
            resetListener(failedListener: listener)
        case .cancelled:
            LocalCacheProxyLog.shared.log("Server: Listener cancelled")
            resetListener(failedListener: listener)
        default:
            break
        }
    }

    private func resetListener(failedListener: NWListener) {
        if self.listener === failedListener {
            self.listener = nil
            self.port = 0
            if self.sessions.isEmpty {
                self.preferredPortIndex = 0
            }
            // Auto-recreate listener after 0.2s pause
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.ensureListener()
            }
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
            var removedAny = false
            // 1. Exact key match
            if let session = sessions.removeValue(forKey: key) {
                session.invalidate()
                removedAny = true
            }
            // 2. Prefix match (e.g. key="p1", session="p1_1" or key="p1_1", session="p1")
            let prefix = key.contains("_") ? (key.components(separatedBy: "_").first ?? key) : key
            let matchingKeys = sessions.keys.filter { $0 == prefix || $0.hasPrefix("\(prefix)_") }
            for k in matchingKeys {
                if let s = sessions.removeValue(forKey: k) {
                    s.invalidate()
                    removedAny = true
                }
            }
            // 3. Clean matching directories on disk
            let base = cacheBaseDir()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
                for name in contents where name == key || name == prefix || name.hasPrefix("\(prefix)_") {
                    let dir = base.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dir)
                    LocalCacheProxyLog.shared.log("Server: Deleted directory from disk: \(name)")
                }
            }
            LocalCacheProxyLog.shared.log("Server: stopSession('\(key)') done (removedAny=\(removedAny), remainingSessions=\(sessions.count))")
        }
    }

    func stopAllSessions() {
        queue.sync {
            sessions.values.forEach { $0.invalidate() }
            sessions.removeAll()
            let base = cacheBaseDir()
            if FileManager.default.fileExists(atPath: base.path) {
                try? FileManager.default.removeItem(at: base)
            }
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            LocalCacheProxyLog.shared.log("Server: stopAllSessions() completed, base directory cleared.")
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

    func diagnosticReport(key: String) -> String {
        queue.sync {
            var lines: [String] = []
            lines.append("=== NUVIO PLAYBACK & CACHE DIAGNOSTIC REPORT ===")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            lines.append("Generated at: \(formatter.string(from: Date()))")
            lines.append("iOS: \(UIDevice.current.systemVersion) | Device: \(UIDevice.current.model)")
            lines.append("Free disk space: \(freeSpaceBytes() / 1024 / 1024) MB")
            lines.append("Server active: \(listener != nil), port: \(port)")
            lines.append("Active session count: \(sessions.count)")

            let targetSession = sessions[key] ?? sessions.values.first
            if let s = targetSession {
                lines.append("\n--- Session: [\(s.key)] ---")
                lines.append("Host: \(URL(string: s.sourceUrl)?.host ?? "unknown")")
                let sizeStr = s.totalSize.map { "\($0) bytes (\(String(format: "%.1f", Double($0) / 1024.0 / 1024.0)) MB)" } ?? "unknown"
                lines.append("Total Size: \(sizeStr)")
                lines.append("Cached: \(s.cachedChunks.count) chunks (\(String(format: "%.1f", Double(s.totalCachedBytes()) / 1024.0 / 1024.0)) MB)")
                lines.append("Speed: \(s.currentSpeed() / 1024) KB/s")
                let playheadStr = s.playheadMs.map { "\($0.0 / 1000)s / \($0.1 / 1000)s" } ?? "none"
                lines.append("Playhead: \(playheadStr)")
                if let fd = s.forwardDownloader {
                    lines.append("Forward Downloader: active, start=\(fd.startByte) (\(fd.startByte / 1024 / 1024) MB), offset=\(fd.streamOffset) (\(fd.streamOffset / 1024 / 1024) MB), finished=\(fd.isFinished)")
                } else {
                    lines.append("Forward Downloader: none / idle")
                }
                if let bd = s.backwardDownloader {
                    lines.append("Backward Downloader: active on chunk \(bd.chunkIndex)")
                }
                if let pd = s.probeDownloader {
                    lines.append("Probe Downloader: active on chunk \(pd.chunkIndex)")
                }
                lines.append("Active Client Connections: \(s.activeConnections.count)")
                for (_, conn) in s.activeConnections {
                    lines.append("  * conn offset=\(conn.streamOffset), end=\(conn.streamEnd), waiting=\(conn.isWaitingForData), waitingChunk=\(conn.waitingChunkIndex)")
                }
            } else {
                lines.append("\nNo active session found matching '\(key)'.")
            }

            let logEntries = LocalCacheProxyLog.shared.snapshot()
            lines.append("\n--- Event Log (Last \(logEntries.count) events) ---")
            lines.append(contentsOf: logEntries)
            lines.append("=== END REPORT ===")
            return lines.joined(separator: "\n")
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

    fileprivate(set) var forwardDownloader: ForwardDownloader?
    fileprivate(set) var backwardDownloader: BackwardDownloader?
    fileprivate(set) var probeDownloader: BackwardDownloader?
    fileprivate(set) var activeConnections: [ObjectIdentifier: ProxyConnection] = [:]
    private var headWaiters: [ProxyConnection] = []
    private var lastForwardDownloaderStartTime: TimeInterval = 0

    private(set) var activeChunkWriters: [Int64: String] = [:]

    init(key: String, sourceUrl: String, headers: [String: String], baseDir: URL, server: LocalCacheProxyServer) {
        self.key = key
        self.sourceUrl = sourceUrl
        self.headers = headers
        self.dir = baseDir
        self.server = server
        if FileManager.default.fileExists(atPath: baseDir.path) {
            try? FileManager.default.removeItem(at: baseDir)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        probeTotalSizeIfNeeded()
    }

    func claimChunkWrite(chunkIndex: Int64, owner: String) -> Bool {
        if let currentOwner = activeChunkWriters[chunkIndex] {
            if currentOwner == owner { return true }
            return false
        }
        activeChunkWriters[chunkIndex] = owner
        return true
    }

    func releaseChunkWrite(chunkIndex: Int64, owner: String? = nil) {
        if let owner = owner {
            if activeChunkWriters[chunkIndex] == owner {
                activeChunkWriters.removeValue(forKey: chunkIndex)
            }
        } else {
            activeChunkWriters.removeValue(forKey: chunkIndex)
        }
    }

    func isChunkBeingWritten(_ chunkIndex: Int64) -> Bool {
        activeChunkWriters[chunkIndex] != nil
    }

    func invalidate() {
        valid = false
        activeChunkWriters.removeAll()
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

        let targetDir = dir
        let sessionKey = key
        do {
            try FileManager.default.removeItem(at: targetDir)
            LocalCacheProxyLog.shared.log("Session [\(sessionKey)]: Removed directory \(targetDir.lastPathComponent)")
        } catch {
            LocalCacheProxyLog.shared.log("Session [\(sessionKey)]: Could not remove dir immediately (\(error.localizedDescription)); scheduling retry in 0.5s...")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                try? FileManager.default.removeItem(at: targetDir)
            }
        }
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

        // Start caching from a second before where the stream starts/requests.
        // In LocalCacheProxy, 1 chunk = 8 MB, which corresponds to ~2-4 seconds of video.
        let effectiveStartByte = max(0, startByte - saminProxyChunkBytes)
        let chunkIdx = effectiveStartByte / saminProxyChunkBytes
        let targetStartByte = chunkIdx * saminProxyChunkBytes

        // If totalSize is not known yet, check if existing downloader covers the target
        guard let total = totalSize, total > 0 else {
            if let fd = forwardDownloader, !fd.isFinished {
                if fd.streamOffset >= targetStartByte {
                    return
                }
                if (targetStartByte - fd.streamOffset) <= 32 * 1024 * 1024 {
                    return
                }
                LocalCacheProxyLog.shared.log("Session [\(key)]: Cancelling initial FD (streamOffset=\(fd.streamOffset), target=\(targetStartByte))")
                forwardDownloader?.cancel()
                forwardDownloader = nil
            }
            startNewForwardDownloader(targetStartByte: targetStartByte, reason: "initial/unknown totalSize")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let recentStart = (now - lastForwardDownloaderStartTime) < 2.0

        // 1. Check if all chunks from chunkIdx to EOF are already cached
        let totalChunks = (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes
        var allCachedForward = true
        for c in chunkIdx..<totalChunks {
            if !cachedChunks.contains(c) {
                allCachedForward = false
                break
            }
        }
        if allCachedForward {
            LocalCacheProxyLog.shared.log("Session [\(key)]: All forward chunks \(chunkIdx)..<\(totalChunks) cached! Completing.")
            forwardDownloader?.cancel()
            forwardDownloader = nil
            onForwardCompleted(startByte: targetStartByte)
            return
        }

        // 2. If forward downloader is already downloading this region forward, let it run at line rate
        if let fd = forwardDownloader, !fd.isFinished {
            if fd.startByte <= targetStartByte && fd.streamOffset >= targetStartByte {
                return
            }
            if fd.streamOffset < targetStartByte && (targetStartByte - fd.streamOffset) <= 32 * 1024 * 1024 {
                return
            }
            if recentStart && abs(targetStartByte - fd.startByte) <= 64 * 1024 * 1024 {
                LocalCacheProxyLog.shared.log("Session [\(key)]: FD running from \(fd.startByte), nearby probe chunk=\(chunkIdx)")
                fetchProbeChunk(chunkIndex: chunkIdx)
                return
            }
        }

        // 3. If requested range is a probe near the end of file (e.g. moov/cues atom)
        // and forwardDownloader is actively running near the beginning/playhead:
        if (total - startByte) <= 16 * 1024 * 1024,
           let fd = forwardDownloader, !fd.isFinished, fd.streamOffset < (total - 32 * 1024 * 1024) {
            if probeDownloader == nil {
                LocalCacheProxyLog.shared.log("Session [\(key)]: End-of-file probe at \(startByte); using probe chunk \(startByte / saminProxyChunkBytes)")
            }
            fetchProbeChunk(chunkIndex: startByte / saminProxyChunkBytes)
            return
        }

        // 3.5 If requested range is Chunk 0 (container header) and forwardDownloader is actively running at a forward seek position:
        if chunkIdx == 0 && !cachedChunks.contains(0),
           let fd = forwardDownloader, !fd.isFinished, fd.startByte > (32 * 1024 * 1024) {
            if probeDownloader == nil {
                LocalCacheProxyLog.shared.log("Session [\(key)]: Container header probe at chunk 0 while FD is running at \(fd.startByte); using probe chunk 0")
            }
            fetchProbeChunk(chunkIndex: 0)
            return
        }

        // 4. New seek point / reposition: cancel existing downloaders so 100% bandwidth serves the current play position
        LocalCacheProxyLog.shared.log("Session [\(key)]: Repositioning download to \(startByte) (targetChunk=\(chunkIdx), targetByte=\(targetStartByte))")
        forwardDownloader?.cancel()
        forwardDownloader = nil
        backwardDownloader?.cancel()
        backwardDownloader = nil

        startNewForwardDownloader(targetStartByte: targetStartByte, reason: "seek to \(startByte)")
    }

    private func startNewForwardDownloader(targetStartByte: Int64, reason: String) {
        lastForwardDownloaderStartTime = ProcessInfo.processInfo.systemUptime
        let fd = ForwardDownloader(session: self, startByte: targetStartByte)
        self.forwardDownloader = fd
        fd.start()
        LocalCacheProxyLog.shared.log("Session [\(key)]: Started FD at \(targetStartByte) (\(reason))")
    }

    func fetchProbeChunk(chunkIndex: Int64) {
        guard valid, probeDownloader == nil, !cachedChunks.contains(chunkIndex) else { return }
        if !claimChunkWrite(chunkIndex: chunkIndex, owner: "probe") {
            LocalCacheProxyLog.shared.log("Session [\(key)]: Chunk \(chunkIndex) already being written by another downloader, skipping probe")
            return
        }
        LocalCacheProxyLog.shared.log("Session [\(key)]: Starting probe download for chunk \(chunkIndex)")
        let pd = BackwardDownloader(session: self, chunkIndex: chunkIndex)
        self.probeDownloader = pd
        pd.start()
    }

    func notifyClientWaiting(chunkIndex: Int64) {
        forwardDownloader?.onClientWaiting(chunkIndex: chunkIndex)
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
            if !cachedChunks.contains(idx) && claimChunkWrite(chunkIndex: idx, owner: "backward") {
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
            releaseChunkWrite(chunkIndex: chunkIndex, owner: "backward")
        }
        if probeDownloader?.chunkIndex == chunkIndex {
            probeDownloader = nil
            releaseChunkWrite(chunkIndex: chunkIndex, owner: "probe")
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

// MARK: - Forward Downloader (Continuous High-Speed Stream to Disk)

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
    private var retryCount = 0
    private let maxRetries = 10

    // Watchdog
    private var lastByteUptime: TimeInterval = 0
    private var watchdogTimer: DispatchSourceTimer?

    init(session: ProxySession, startByte: Int64) {
        self.session = session
        self.startByte = startByte
        self.streamOffset = startByte
    }

    func start() {
        startWatchdog()
        startStream(from: startByte)
    }

    private func startStream(from offset: Int64) {
        guard session.valid, !isCancelled, !isFinished, let url = URL(string: session.sourceUrl) else {
            finish(failed: true)
            return
        }

        // If chunks starting at offset are already cached, advance to first uncached byte
        var effectiveOffset = offset
        let startChunk = offset / saminProxyChunkBytes
        var checkChunk = startChunk
        while session.cachedChunks.contains(checkChunk) {
            checkChunk += 1
            effectiveOffset = checkChunk * saminProxyChunkBytes
        }
        if let written = session.bytesWrittenByChunk[checkChunk], written > 0 {
            effectiveOffset = (checkChunk * saminProxyChunkBytes) + written
        }

        if let total = session.totalSize, total > 0, effectiveOffset >= total {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: All forward chunks cached (effectiveOffset=\(effectiveOffset), total=\(total))")
            finish(failed: false)
            return
        }

        self.streamOffset = effectiveOffset
        lastByteUptime = ProcessInfo.processInfo.systemUptime

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
        request.setValue("bytes=\(effectiveOffset)-", forHTTPHeaderField: "Range")

        LocalCacheProxyLog.shared.log("FD [\(startByte)]: Opening continuous stream with Range: bytes=\(effectiveOffset)-")

        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
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
        stopWatchdog()
        task?.cancel()
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        cleanupFileHandle()
        if currentChunkIndex >= 0 {
            session.releaseChunkWrite(chunkIndex: currentChunkIndex, owner: "forward")
            currentChunkIndex = -1
        }
    }

    private func cleanupFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        fileHandleChunk = -1
    }

    func onClientWaiting(chunkIndex: Int64) {
        guard session.valid, !isCancelled, !isFinished, chunkIndex >= 0 else { return }
        if session.cachedChunks.contains(chunkIndex) { return }

        // If probeDownloader is actively handling this chunk, let it proceed
        if session.isChunkBeingWritten(chunkIndex) && currentChunkIndex != chunkIndex {
            return
        }

        // Distant EOF probe chunks should be routed to probeDownloader
        if let total = session.totalSize {
            let eofChunk = (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes - 1
            if chunkIndex >= eofChunk - 2 && (chunkIndex - (startByte / saminProxyChunkBytes)) > 6 {
                session.fetchProbeChunk(chunkIndex: chunkIndex)
                return
            }
        }

        // If the continuous stream is actively downloading this chunk, check for stalls
        if currentChunkIndex == chunkIndex {
            let now = ProcessInfo.processInfo.systemUptime
            let idle = now - lastByteUptime
            if idle >= 3.0 {
                LocalCacheProxyLog.shared.log("FD [\(startByte)]: Client waiting on chunk \(chunkIndex) and idle \(String(format: "%.1f", idle))s -> reconnecting continuous stream")
                reconnect(reason: "client waiting & idle")
            }
        }
    }

    private func reconnect(reason: String) {
        guard !isCancelled, !isFinished, session.valid else { return }
        LocalCacheProxyLog.shared.log("FD [\(startByte)]: Reconnecting from \(streamOffset) (reason: \(reason))...")
        task?.cancel()
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        cleanupFileHandle()
        if currentChunkIndex >= 0 {
            session.releaseChunkWrite(chunkIndex: currentChunkIndex, owner: "forward")
            currentChunkIndex = -1
        }
        startStream(from: streamOffset)
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: session.server.queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func checkWatchdog() {
        guard !isCancelled, !isFinished, session.valid, task != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let idle = now - lastByteUptime

        let clientIsWaiting = session.activeConnections.values.contains { $0.isWaitingForData }
        let threshold = clientIsWaiting ? 4.0 : 20.0

        if idle >= threshold {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: Watchdog stall (idle=\(String(format: "%.1f", idle))s, clientWaiting=\(clientIsWaiting)). Reconnecting from \(streamOffset)...")
            reconnect(reason: "watchdog idle stall")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled, self.session.valid else {
                completionHandler(.cancel)
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }

            let code = http.statusCode
            if code == 206 || code == 200 {
                var lowered: [String: String] = [:]
                http.allHeaderFields.forEach { k, v in
                    if let ks = k as? String, let vs = v as? String {
                        lowered[ks.lowercased()] = vs
                    }
                }
                if self.session.totalSize == nil || self.session.totalSize == 0 {
                    if let cr = lowered["content-range"], let total = ProxyConnectionTotal.parse(cr) {
                        self.session.totalSize = total
                        LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Discovered totalSize=\(total) from Content-Range")
                    } else if let cl = lowered["content-length"], let len = Int64(cl), len > 0 {
                        let total = self.streamOffset + len
                        self.session.totalSize = total
                        LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Discovered totalSize=\(total) from Content-Length")
                    }
                }

                if code == 200 && self.streamOffset > 0 {
                    LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Server returned HTTP 200 (ignored Range). Resetting offset to 0.")
                    self.streamOffset = 0
                }

                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: HTTP \(code) for continuous stream from \(self.streamOffset)")
                completionHandler(.allow)
            } else {
                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: HTTP error \(code)")
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, !data.isEmpty else { return }
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled, self.session.valid else { return }
            self.processIncoming(data: data)
        }
    }

    private func processIncoming(data: Data) {
        session.recordBytesReceived(data.count)
        lastByteUptime = ProcessInfo.processInfo.systemUptime

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

            if let total = session.totalSize, total > 0, streamOffset >= total {
                LocalCacheProxyLog.shared.log("FD [\(startByte)]: Reached EOF at byte \(streamOffset)")
                finish(failed: false)
                return
            }
        }
    }

    private func writePiece(chunkIndex: Int64, offset: Int64, piece: Data) {
        currentChunkIndex = chunkIndex

        if fileHandle == nil || fileHandleChunk != chunkIndex {
            if fileHandleChunk >= 0 && fileHandleChunk != chunkIndex {
                session.releaseChunkWrite(chunkIndex: fileHandleChunk, owner: "forward")
            }
            cleanupFileHandle()

            guard session.claimChunkWrite(chunkIndex: chunkIndex, owner: "forward") else {
                LocalCacheProxyLog.shared.log("FD [\(startByte)]: Chunk \(chunkIndex) claimed by another downloader, skipping")
                return
            }

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
            if offset == 0 && (session.bytesWrittenByChunk[chunkIndex] ?? 0) == 0 {
                try? h.truncate(atOffset: 0)
            }
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: piece)
            let totalWritten = offset + Int64(piece.count)
            session.bytesWrittenByChunk[chunkIndex] = totalWritten

            let expectedSize: Int64
            if let total = session.totalSize, total > 0 {
                let cStart = chunkIndex * saminProxyChunkBytes
                let cEnd = min(cStart + saminProxyChunkBytes - 1, total - 1)
                expectedSize = cEnd - cStart + 1
            } else {
                expectedSize = saminProxyChunkBytes
            }

            if totalWritten >= expectedSize {
                session.markCached(chunkIndex)
                cleanupFileHandle()
                session.releaseChunkWrite(chunkIndex: chunkIndex, owner: "forward")
                LocalCacheProxyLog.shared.log("FD [\(startByte)]: Cached chunk \(chunkIndex) (totalCached=\(session.cachedChunks.count))")
            }
            session.notifyDataAvailable(chunkIndex: chunkIndex)
        } catch {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: File write error on chunk \(chunkIndex): \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }

            if let error {
                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Disconnect error: '\(error.localizedDescription)' at offset \(self.streamOffset)")
                if self.retryCount < self.maxRetries && self.session.valid {
                    self.retryCount += 1
                    LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Auto-retrying (\(self.retryCount)/\(self.maxRetries)) from \(self.streamOffset)...")
                    self.cleanupFileHandle()
                    if self.currentChunkIndex >= 0 {
                        self.session.releaseChunkWrite(chunkIndex: self.currentChunkIndex, owner: "forward")
                        self.currentChunkIndex = -1
                    }
                    self.urlSession?.invalidateAndCancel()
                    self.task = nil
                    self.urlSession = nil
                    self.session.server.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, !self.isCancelled, self.session.valid else { return }
                        self.startStream(from: self.streamOffset)
                    }
                    return
                }
            }

            // Normal completion / EOF
            if let total = self.session.totalSize, total > 0, self.streamOffset >= total {
                self.finish(failed: false)
            } else if self.session.valid && self.retryCount < self.maxRetries {
                // Connection ended prematurely without error (server closed Keep-Alive stream)
                self.retryCount += 1
                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Stream closed cleanly by server at \(self.streamOffset), auto-resuming from \(self.streamOffset)...")
                self.cleanupFileHandle()
                if self.currentChunkIndex >= 0 {
                    self.session.releaseChunkWrite(chunkIndex: self.currentChunkIndex, owner: "forward")
                    self.currentChunkIndex = -1
                }
                self.urlSession?.invalidateAndCancel()
                self.task = nil
                self.urlSession = nil
                self.startStream(from: self.streamOffset)
            } else {
                self.finish(failed: error != nil)
            }
        }
    }

    private func finish(failed: Bool) {
        guard !isFinished else { return }
        isFinished = true
        stopWatchdog()
        cleanupFileHandle()
        if currentChunkIndex >= 0 {
            session.releaseChunkWrite(chunkIndex: currentChunkIndex, owner: "forward")
            currentChunkIndex = -1
        }
        urlSession?.invalidateAndCancel()
        urlSession = nil

        if !failed {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: Continuous forward download finished successfully at EOF")
            session.onForwardCompleted(startByte: startByte)
        } else {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: Continuous download failed permanently")
            session.forwardDownloader = nil
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
              let url = URL(string: session.sourceUrl) else {
            session.onBackwardChunkCompleted(chunkIndex: chunkIndex, success: false)
            return
        }

        let startByte = chunkIndex * saminProxyChunkBytes
        let endByte = min(startByte + saminProxyChunkBytes - 1, total - 1)
        guard endByte >= startByte else {
            session.onBackwardChunkCompleted(chunkIndex: chunkIndex, success: false)
            return
        }

        expectedBytes = endByte - startByte + 1

        let fileUrl = session.chunkURL(chunkIndex)
        var existingBytes: Int64 = session.bytesWrittenByChunk[chunkIndex] ?? 0
        if existingBytes == 0, let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
           let fileSize = attrs[.size] as? Int64, fileSize > 0, fileSize <= expectedBytes {
            existingBytes = fileSize
            session.bytesWrittenByChunk[chunkIndex] = existingBytes
        }

        if existingBytes >= expectedBytes {
            session.markCached(chunkIndex)
            session.notifyDataAvailable(chunkIndex: chunkIndex)
            session.onBackwardChunkCompleted(chunkIndex: chunkIndex, success: true)
            return
        }

        if !FileManager.default.fileExists(atPath: fileUrl.path) {
            FileManager.default.createFile(atPath: fileUrl.path, contents: nil)
            existingBytes = 0
            session.bytesWrittenByChunk[chunkIndex] = 0
        }

        guard let h = try? FileHandle(forUpdating: fileUrl) else {
            session.onBackwardChunkCompleted(chunkIndex: chunkIndex, success: false)
            return
        }

        if existingBytes > 0 {
            do {
                try h.seek(toOffset: UInt64(existingBytes))
            } catch {
                try? h.truncate(atOffset: 0)
                existingBytes = 0
                session.bytesWrittenByChunk[chunkIndex] = 0
            }
        } else {
            try? h.truncate(atOffset: 0)
            existingBytes = 0
            session.bytesWrittenByChunk[chunkIndex] = 0
        }

        self.fileHandle = h
        self.receivedBytes = existingBytes

        let requestStart = startByte + existingBytes
        let requestEnd = endByte

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
        request.setValue("bytes=\(requestStart)-\(requestEnd)", forHTTPHeaderField: "Range")

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
        session.releaseChunkWrite(chunkIndex: chunkIndex)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 200 {
            // Server ignored range, sent full chunk from 0
            if let h = fileHandle {
                try? h.truncate(atOffset: 0)
                try? h.seek(toOffset: 0)
            }
            receivedBytes = 0
            self.session.bytesWrittenByChunk[chunkIndex] = 0
            completionHandler(.allow)
        } else if http.statusCode == 206 {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, !data.isEmpty, let h = fileHandle else { return }
        do {
            try h.seek(toOffset: UInt64(receivedBytes))
            try h.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            self.session.server.queue.async { [weak self] in
                guard let self, !self.isCancelled else { return }
                self.session.recordBytesReceived(data.count)
                self.session.bytesWrittenByChunk[self.chunkIndex] = self.receivedBytes
                self.session.notifyDataAvailable(chunkIndex: self.chunkIndex)
            }
        } catch { }
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
    fileprivate(set) var streamOffset: Int64 = 0
    fileprivate(set) var streamEnd: Int64 = 0

    // Waiting for live data from forward downloader
    fileprivate(set) var isWaitingForData = false
    fileprivate(set) var waitingChunkIndex: Int64 = -1

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

        LocalCacheProxyLog.shared.log("Client [\(sessionKey)]: \(request.method) range=\(request.headers["range"] ?? "all") (start=\(start), end=\(requestedEnd?.description ?? "EOF"))")

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
            let bytesAhead = available - chunkOffset
            let forwardActive = session.forwardDownloader != nil && !(session.forwardDownloader?.isFinished ?? false)
            let isAtStreamEnd = (streamOffset + bytesAhead > streamEnd) || (session.totalSize != nil && streamOffset + bytesAhead >= session.totalSize!)

            // Pre-buffering margin (shock absorber):
            // If the connection was waiting for live data, avoid leaking tiny 16KB starved packets to MPV.
            // Hold back until at least saminProxyMinResumeBytes (512 KB) are buffered ahead,
            // unless the chunk is fully cached, forward downloading is finished, or we're at EOF.
            if isWaitingForData && forwardActive && bytesAhead < saminProxyMinResumeBytes && !session.cachedChunks.contains(chunkIdx) && !isAtStreamEnd {
                return
            }

            isWaitingForData = false
            waitingChunkIndex = -1

            let pieceLen = min(available - chunkOffset, Int64(saminProxyPieceBytes), streamEnd - streamOffset + 1)
            guard pieceLen > 0 else {
                close()
                return
            }

            guard let data = readChunkData(session: session, chunkIndex: chunkIdx, offset: chunkOffset, count: Int(pieceLen)), !data.isEmpty else {
                isWaitingForData = true
                waitingChunkIndex = chunkIdx
                session.notifyClientWaiting(chunkIndex: chunkIdx)
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
            if !isWaitingForData {
                LocalCacheProxyLog.shared.log("Client [\(sessionKey)]: Waiting for data at chunk \(chunkIdx) (offset=\(streamOffset), available=\(available))")
            }
            isWaitingForData = true
            waitingChunkIndex = chunkIdx
            session.ensureForwardDownloading(from: streamOffset)
            session.notifyClientWaiting(chunkIndex: chunkIdx)
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
            if let data = try handle.read(upToCount: count), !data.isEmpty {
                return data
            }
            // FileHandle may have cached a stale EOF if writer recently appended.
            // Reopen a fresh handle and try reading once more.
            try? handle.close()
            readHandle = nil
            let url = session.chunkURL(chunkIndex)
            guard let freshHandle = try? FileHandle(forReadingFrom: url) else { return nil }
            readHandle = (chunkIndex, freshHandle)
            try freshHandle.seek(toOffset: UInt64(offset))
            if let freshData = try freshHandle.read(upToCount: count), !freshData.isEmpty {
                return freshData
            }
            return nil
        } catch {
            try? readHandle?.handle.close()
            readHandle = nil
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
