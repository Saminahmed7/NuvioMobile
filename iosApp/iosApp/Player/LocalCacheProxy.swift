import Foundation
import UIKit
import Network
import Darwin
import ComposeApp

// MARK: - Sleep-aware clock

/// Monotonic seconds that keep advancing while the device is asleep.
///
/// `ProcessInfo.systemUptime` is backed by `mach_absolute_time()`, which freezes
/// during device sleep (screen lock). Measuring stream idleness with it made a
/// stream killed by screen-lock look brand new the moment the app woke, so the
/// proxy logged "stream healthy; leaving it alone" and never reconnected —
/// playback stayed dead until the whole app was relaunched. `mach_continuous_time()`
/// keeps counting across sleep, so a wake after lock genuinely reads as idle.
private let saminTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func saminNow() -> TimeInterval {
    let denom = saminTimebase.denom == 0 ? 1 : saminTimebase.denom
    let nanos = Double(mach_continuous_time()) * Double(saminTimebase.numer) / Double(denom)
    return nanos / 1_000_000_000
}

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

// Visible to MediaIndex.swift (same module): session chunk file layout.
let saminProxyChunkBytes: Int64 = 2 * 1024 * 1024 // 2 MB chunks
private let saminProxyLowSpaceBytes: Int64 = 300 * 1024 * 1024 // 300 MB (aligned with Kotlin LOW_SPACE_STOP_BYTES)
private let saminProxyMaxRanges = 32
private let saminProxyPieceBytes: Int = 256 * 1024 // 256 KB socket send slices
private let saminProxyMinResumeBytes: Int64 = 0 // Intentionally 0 (no hold-back) to avoid 20 s seek stall; was 512 KB prebuffer lead but caused seek latency on slow links
// A client request this far ahead of the write head is treated as a one-off
// probe (index/moov atom) rather than sequential playback, so it is served by a
// dedicated range fetch instead of dragging the prefetcher forward.
private let saminProxyAheadWindowBytes: Int64 = 32 * 1024 * 1024
// The prefetcher only jumps forward when the playhead lands this far beyond it
// (a genuine seek). Smaller gaps are served by the running stream.
private let saminProxyForwardSeekBytes: Int64 = 64 * 1024 * 1024
// Max concurrent short-lived range fetches for client-requested chunks.
private let saminProxyMaxChunkFetchers = 3
// The prefetcher jumps back to the playhead when it lands this far behind the
// write head AND at least saminProxyBackwardGapChunks uncached chunks follow it.
private let saminProxyBackwardSeekBytes: Int64 = 32 * 1024 * 1024
private let saminProxyBackwardGapChunks: Int64 = 8 // 16 MB with 2 MB chunks

// MARK: HLS segment cache (Samin, handoff "Option A")
//
// An HLS session caches each media segment as its own file under the session
// directory. The playlist is fetched once, parsed, and every segment / key /
// init-map URI is rewritten to a loopback path, so mpv pulls each segment
// through the proxy and replays are served from disk. Not supported (falls
// back to byte-stream pass-through): live events, EXT-X-BYTERANGE, parsed
// playlists with no variants/segments, and DASH manifests.
private let saminHlsSegmentFetchers = 3
private let saminHlsPrefetchSegments = 8
private let saminHlsMaxPlaylistBytes = 4 * 1024 * 1024

final class LocalCacheProxyLog {
    static let shared = LocalCacheProxyLog()
    private var entries: [String] = []
    private let lock = NSLock()
    private let maxEntries = 150

    func log(_ message: String) {
        append("[\(timestamp())] \(message)")
        // Mirrored into the playback trace so player and proxy events can be
        // read back on one timeline (see PlaybackTrace).
        PlaybackTrace.shared.add(source: "proxy", message)
        #if DEBUG
        print("[CacheProxy] [\(timestamp())] \(message)")
        #endif
    }

    /// Event-log only: for hot-path waits that fire per socket slice. These
    /// would otherwise flood the playback trace (hundreds/sec) and evict the
    /// useful history, leaving the report with seconds of context.
    func logEventOnly(_ message: String) {
        append("[\(timestamp())] \(message)")
        #if DEBUG
        print("[CacheProxy] [\(timestamp())] \(message)")
        #endif
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func append(_ line: String) {
        lock.lock()
        if entries.count >= maxEntries {
            entries.removeFirst()
        }
        entries.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

}

/// Samin: on-device playback trace.
///
/// A bounded, timestamped ring buffer that interleaves the player's own
/// decisions, libmpv's log, the cache proxy's events and a 2s state sample, so
/// a failure that only shows up on device can be read back afterwards instead
/// of guessed at from a screenshot. It rides along in the diagnostics report,
/// which the player can copy to the clipboard.
///
/// Entries arrive from the mpv event queue, the main queue and the proxy queue,
/// so every access is behind a lock. In-memory only: no file, no UI.
final class PlaybackTrace {
    static let shared = PlaybackTrace()

    // Bounded by lines and characters: the report is rendered in one Compose
    // Text and pasted by hand, so a long steady-state run and a chatty burst
    // both have to stay small. The newest lines are kept.
    private static let maxEntries = 1200
    private static let maxCharacters = 96 * 1024
    // Cadence of the "how is the stream doing" sample line.
    private static let sampleInterval: TimeInterval = 2.0

    private let lock = NSLock()
    private var entries: [String] = []
    private var characters = 0
    private var lastSampleUptime: TimeInterval = 0

    func add(source: String, _ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(source): \(message)"
        lock.lock()
        entries.append(line)
        characters += line.count
        while entries.count > Self.maxEntries || (characters > Self.maxCharacters && entries.count > 1) {
            characters -= entries.removeFirst().count
        }
        lock.unlock()
    }

    /// True at most once per sampleInterval, so Kotlin's 250ms state poll turns
    /// into a steady timeline without a timer of its own.
    func sampleIsDue() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if lastSampleUptime > 0, now - lastSampleUptime < Self.sampleInterval {
            return false
        }
        lastSampleUptime = now
        return true
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
        characters = 0
        lastSampleUptime = 0
    }

    /// Host and path, with the query summarised: the report already treats a
    /// query as an auth token, and the host is what says which CDN answered.
    static func describe(url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else {
            return "<unparseable string, \(url.count) chars>"
        }
        let query = parsed.query.map { "?<\($0.count) chars redacted>" } ?? ""
        return "\(parsed.scheme ?? "?")://\(host)\(parsed.path)\(query)"
    }

    /// Header names, plus the value of the headers that decide hotlink gates
    /// (the question this trace exists to answer). Authorization and cookies
    /// stay out.
    static func describe(headers: [String: String]) -> String {
        guard !headers.isEmpty else { return "none" }
        let gated: Set<String> = ["referer", "origin"]
        return headers.keys.sorted().map { key -> String in
            guard gated.contains(key.lowercased()), let value = headers[key] else { return key }
            return "\(key)=\(value)"
        }.joined(separator: ", ")
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

    func setPlayhead(sessionKey: String, positionMs: Int64, durationMs: Int64, streamPos: Int64, isPlaying: Bool) {
        // isPlaying is intentionally unused: the forward download keeps running
        // while paused so the user can let a slow stream buffer ahead.
        LocalCacheProxyServer.shared.setPlayhead(
            key: sessionKey,
            positionMs: positionMs,
            durationMs: durationMs,
            streamPos: streamPos > 0 ? streamPos : nil
        )
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
    // fileprivate: the HLS layer builds loopback URLs from it.
    fileprivate var port: UInt16 = 0
    private var sessions: [String: ProxySession] = [:]
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    // The loopback port is fixed for the whole app process lifetime. MPV holds
    // the URL http://127.0.0.1:<port>/s/<key>/file open while a stream plays,
    // so rotating the port (or letting it drift) strands live requests on an
    // address nothing serves and surfaces as "Connection refused".
    private var activeBoundPort: UInt16 = 19842
    // True only once the listener reported .ready. `NWListener(using:on:)` does
    // not throw when a port is unavailable — the failure arrives later as
    // .failed — so creating a listener is not proof that anything is listening.
    private var listenerReady = false
    // True between tearing an old listener down and binding its replacement:
    // the fixed port is briefly unbound, so no other caller may start another
    // bind while the old socket is still being released.
    private var rebuildInProgress = false
    // Set when the app really left the foreground (screen lock, app switch).
    private var wentToBackground = false
    // Guards one-time registration of the background notification observer.
    private var foregroundObserverRegistered = false

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
            let fromBackground = self.wentToBackground
            self.wentToBackground = false
            LocalCacheProxyLog.shared.log("Server: Foreground notification received (fromBackground=\(fromBackground)). Ensuring listener on port \(self.activeBoundPort)...")
            // A listener that reports .ready is NOT proof the port is served:
            // iOS reclaims the listening socket when the app is suspended
            // (screen lock) and NWListener does not always notice, so the first
            // request after re-entry hits a closed port ("Connection refused").
            // Returning from a real background therefore rebuilds the socket on
            // the same fixed port, keeping MPV's already-held URL valid.
            let listenerComingUp: Bool
            if let state = self.listener?.state {
                switch state {
                case .setup, .waiting:
                    listenerComingUp = true
                default:
                    listenerComingUp = false
                }
            } else {
                listenerComingUp = false
            }
            // willEnterForeground and didBecomeActive fire back-to-back, so only
            // rebuild once: skip while the fresh bind from the first notification
            // is still coming up.
            if fromBackground || (!listenerComingUp && (self.listener == nil || self.listener?.state != .ready || !self.listenerReady)) {
                // Returning from a suspension the socket may really be gone (iOS
                // reclaims it while NWListener still reports .ready), but tearing
                // down a still-serving listener would unbind the fixed port under
                // any session mpv is already playing. Probe first, rebuild only
                // when the port is genuinely not accepting.
                self.rebuildListenerIfNotServing(reason: "foreground")
            }
            for session in self.sessions.values {
                session.handleForegroundWake()
            }
        }
    }

    /// Tears the listener down and recreates it on the fixed port. Used when the
    /// bound socket may have died underneath us (return from background, or a
    /// probe that found the port refusing connections).
    private func forceRebuildListener() {
        // willEnterForeground + didBecomeActive fire back-to-back, and the
        // player's recovery can race a background rebind: tearing down twice
        // would leave the fixed port unbindable for even longer.
        guard !rebuildInProgress else { return }
        listenerReady = false
        port = 0
        guard let old = listener else {
            ensureListener()
            return
        }
        listener = nil
        rebuildInProgress = true
        // `cancel()` releases the fixed port asynchronously. Binding the
        // replacement before the kernel drops the old socket fails with
        // EADDRINUSE, which costs an extra 0.2 s rebind cycle — and every
        // moment the port is unbound is a "Connection refused" for the player.
        // Wait for the real .cancelled callback (this handler runs on `queue`),
        // with a short timer as a safety net.
        let rebind: () -> Void = { [weak self] in
            guard let self, self.rebuildInProgress else { return }
            self.rebuildInProgress = false
            self.ensureListener()
        }
        old.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                rebind()
            default:
                break
            }
        }
        old.cancel()
        queue.asyncAfter(deadline: .now() + 0.15) { rebind() }
    }

    /// Recovery entry point for the player: a request to the loopback URL just
    /// failed, so make sure the port is really being served before the player
    /// retries. A verified-healthy listener is left ALONE: cancelling it would
    /// briefly unbind the fixed port under every live session and turn the
    /// player's next retry into "Connection refused" — the exact first-load
    /// failure this used to produce. Only a dead/stale port is rebuilt, and
    /// waitUntilVerifiedReady then gates the player's retry on the fresh bind
    /// actually accepting (the port never changes, so MPV's URL stays valid).
    func recoverListener() {
        queue.async { [weak self] in self?.rebuildListenerIfNotServing(reason: "recoverListener") }
    }

    /// On `queue`: verify the fixed port really accepts connections and rebuild
    /// the listener only when it does not. A verified-healthy listener is left
    /// ALONE — cancelling it would unbind the fixed port under every live
    /// session and turn the player's next retry into "Connection refused", the
    /// exact first-load failure this used to produce. The probe runs off `queue`
    /// (and off the caller's thread) because it blocks for up to 0.8 s and the
    /// queue also carries live segment traffic.
    private func rebuildListenerIfNotServing(reason: String) {
        guard listenerReady, port != 0, listener?.state == .ready else {
            // Nothing worth preserving: recreate the socket straight away rather
            // than probe a port we already know is gone.
            LocalCacheProxyLog.shared.log("Server: \(reason) - no ready listener; rebuilding on \(activeBoundPort)")
            forceRebuildListener()
            return
        }
        let probedPort = port
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let healthy = self.probeAccepting(port: probedPort, timeout: 0.4)
                || self.probeAccepting(port: probedPort, timeout: 0.4)
            self.queue.async {
                // The listener can change while we probe, so re-validate the
                // verdict before acting on it.
                if healthy, self.listenerReady, self.port == probedPort, self.listener?.state == .ready {
                    LocalCacheProxyLog.shared.log("Server: \(reason) - port \(probedPort) verified healthy; leaving listener alone")
                    return
                }
                LocalCacheProxyLog.shared.log("Server: \(reason) - port \(probedPort) not accepting; rebuilding on \(self.activeBoundPort)")
                self.forceRebuildListener()
            }
        }
    }

    /// Blocks the calling thread until the loopback port provably accepts
    /// connections (or the timeout elapses). The server rebinds on its own
    /// while we poll (resetListener), so no teardown happens here. Player
    /// recovery paths wait on this instead of a blind fixed delay that could
    /// fire while a rebuilt listener was still binding.
    func waitUntilVerifiedReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isPortVerifiedHealthy() { return true }
            if Date() >= deadline { return false }
            // Nudge the server: if the listener is missing (cancelled and not
            // yet rebound) this recreates it now instead of leaving us to spin
            // until resetListener's delayed retry fires. It never touches a live
            // or still-binding listener, and it runs on the queue, not here.
            _ = queue.sync { ensureListener() }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func isPortVerifiedHealthy() -> Bool {
        let snapshot = queue.sync { () -> (ready: Bool, port: UInt16) in
            (self.listenerReady, self.port)
        }
        guard snapshot.ready, snapshot.port != 0 else { return false }
        return probeAccepting(port: snapshot.port, timeout: 0.4)
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

    /// Registers the didEnterBackground observer exactly once. When the app
    /// suspends (screen lock) iOS can reclaim the listening socket while the
    /// in-process NWListener still reports .ready; knowing the app really left
    /// the foreground lets us rebuild the socket on return.
    private func ensureForegroundObserver() {
        guard !foregroundObserverRegistered else { return }
        foregroundObserverRegistered = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.wentToBackground = true }
        }
    }

    func warmup() {
        ensureForegroundObserver()
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

    /// Returns true only when the listener is really bound and accepting.
    /// An unavailable port surfaces asynchronously as `.failed`, so returning
    /// true right after creating the listener handed the player a localhost URL
    /// that nothing was serving — a first-load failure it could never recover
    /// from without relaunching the app. Callers now wait for `.ready`, and
    /// give up (falling back to the remote URL) if it never arrives.
    @discardableResult
    func ensureListener() -> Bool {
        if listenerReady, let current = listener, current.state == .ready, port != 0 { return true }

        // A rebuild is mid-flight: the old socket is still being released, so
        // binding here would collide with it and fail with EADDRINUSE. The
        // pending rebind performs the bind; callers just wait for it.
        if rebuildInProgress { return false }

        // A listener that is still coming up must be left alone: cancelling it
        // to create another would restart the bind on every caller (the
        // willEnterForeground + didBecomeActive pair fires back-to-back).
        if let current = listener {
            switch current.state {
            case .setup, .waiting:
                return false
            default:
                break
            }
        }

        listener?.cancel()
        listener = nil
        listenerReady = false
        port = 0

        guard let wirePort = NWEndpoint.Port(rawValue: activeBoundPort),
              let created = try? NWListener(using: makeTcpParameters(), on: wirePort) else {
            LocalCacheProxyLog.shared.log("Server: Failed to create listener on fixed port \(activeBoundPort)")
            return false
        }
        setupListener(created, port: activeBoundPort)
        LocalCacheProxyLog.shared.log("Server: Bound listener to fixed port \(activeBoundPort) (waiting for ready)")
        return false
    }

    /// Synchronously checks that something is really accepting connections on
    /// the loopback port. NWListener can report `.ready` while the kernel socket
    /// was reclaimed (common after screen lock), and that stale state is exactly
    /// what produced "Connection refused" for the player. A real connect here is
    /// cheap and lets us rebind before the URL is handed out.
    private func probeAccepting(timeout: TimeInterval = 0.75) -> Bool {
        let snapshotPort = queue.sync { self.port }
        guard snapshotPort != 0 else { return false }
        return probeAccepting(port: snapshotPort, timeout: timeout)
    }

    /// Probes a specific port without reading server state, so it can run on
    /// any thread with a snapshot port (the wrapper above does the queue.sync).
    private func probeAccepting(port snapshotPort: UInt16, timeout: TimeInterval) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: snapshotPort) else { return false }
        let probeQueue = DispatchQueue(label: "nuvio-cache-proxy-probe")
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        var accepted = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                accepted = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            return false
        }
        connection.cancel()
        return accepted
    }

    private func setupListener(_ created: NWListener, port: UInt16) {
        self.listener = created
        self.port = port
        self.listenerReady = false
        created.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleListenerState(state, listener: created) }
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        created.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        // A listener we replaced can still report .ready a moment later; acting on
        // it would mark the server ready on the old (or not yet bound) port.
        if case .ready = state, self.listener !== listener {
            LocalCacheProxyLog.shared.log("Server: Ignoring stale listener .ready on port \(listener.port?.rawValue ?? 0)")
            return
        }
        switch state {
        case .ready:
            self.port = listener.port?.rawValue ?? self.activeBoundPort
            self.activeBoundPort = self.port
            self.listenerReady = true
            LocalCacheProxyLog.shared.log("Server: Listener ready on fixed port \(self.port)")
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
            self.listenerReady = false
            self.port = 0
            // The port is fixed for the process lifetime (MPV holds the URL), so
            // retry the SAME port instead of rotating away from it.
            // `allowLocalEndpointReuse` lets the rebind succeed as soon as the
            // old socket is released, which is normally immediate.
            LocalCacheProxyLog.shared.log("Server: Listener lost on fixed port \(activeBoundPort); rebinding in 0.2s")
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.ensureListener()
            }
        }
    }

    func startSession(key: String, sourceUrl: String, headers: [String: String]) -> String {
        var rebuildAttempts = 0
        for _ in 0..<50 {
            let ready = queue.sync { ensureListener() }
            if ready {
                // .ready does not guarantee the OS still serves the port (iOS
                // reclaims the socket during suspension), so prove it with a real
                // loopback connect before handing the URL to the player.
                // Double probe before tearing anything down: a single probe can
                // time out spuriously on a busy first launch, and forceRebuild
                // briefly unbinds the port — stranding any session mpv is
                // already playing (the URL never changes, only the socket).
                if probeAccepting() || probeAccepting() {
                    var url = ""
                    queue.sync {
                        guard listenerReady, port != 0 else { return }
                        // Samin: DASH manifests are explicitly not cached
                        // (byte-range init segments are unsupported); park
                        // them on a pass-through session so the URL handed
                        // to mpv at least resolves instead of 404ing.
                        let wantsHls = LocalCacheProxyServer.isHlsPlaylistUrl(sourceUrl)
                        let wantsPassThrough = sourceUrl.lowercased().contains(".mpd")
                        let kind: ProxySessionKind = wantsHls ? .hls : (wantsPassThrough ? .passThrough : .progressive)
                        if let existing = sessions[key] {
                            // Same session key (same launchId) — update upstream URL
                            // without wiping the cache directory. This handles debrid
                            // re-resolve / stream re-select for the same episode.
                            existing.updateSourceUrl(sourceUrl, headers)
                        } else if kind == .hls {
                            sessions[key] = ProxySession(
                                key: key,
                                sourceUrl: sourceUrl,
                                headers: headers,
                                baseDir: cacheBaseDir().appendingPathComponent(key, isDirectory: true),
                                server: self,
                                kind: .hls
                            )
                        } else {
                            sessions[key] = ProxySession(
                                key: key,
                                sourceUrl: sourceUrl,
                                headers: headers,
                                baseDir: cacheBaseDir().appendingPathComponent(key, isDirectory: true),
                                server: self,
                                kind: kind
                            )
                        }
                        url = "http://127.0.0.1:\(port)/s/\(key)/\(kind == .hls ? "playlist" : "file")"
                    }
                    if !url.isEmpty { return url }
                } else if rebuildAttempts < 3 {
                    rebuildAttempts += 1
                    LocalCacheProxyLog.shared.log("Server: Port \(activeBoundPort) reports ready but refuses connections; rebuilding listener (attempt \(rebuildAttempts))")
                    queue.sync { forceRebuildListener() }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // No live loopback port: the caller falls back to the remote URL, so
        // playback still starts (just without the on-disk cache) instead of
        // hanging on a dead localhost address.
        LocalCacheProxyLog.shared.log("Server: startSession('\\(key)') aborted - listener never became ready; using direct URL")
        return ""
    }

    /// True for URLs that identify an HTTP Live Streaming media or master
    /// playlist. Checked on the raw upstream URL handed to startSession.
    static func isHlsPlaylistUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        return lower.hasSuffix(".m3u8") || lower.contains(".m3u8?")
    }

    func stopSession(key: String) {
        queue.sync {
            var removedAny = false
            // 1. Exact key match
            if let session = sessions.removeValue(forKey: key) {
                session.invalidate()
                removedAny = true
            }
            // 2. Same-launchId family only (e.g. key="p1" vs session="p1_1", or
            // key="p1_1" vs session="p1"): never tear down an unrelated session.
            let matchingKeys = sessions.keys.filter { k in
                k != key && (k.hasPrefix("\(key)_") || key.hasPrefix("\(k)_"))
            }
            for k in matchingKeys {
                if let s = sessions.removeValue(forKey: k) {
                    s.invalidate()
                    removedAny = true
                }
            }
            // 3. Clean matching directories on disk
            let base = cacheBaseDir()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
                for name in contents where name == key || name.hasPrefix("\(key)_") {
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

    func setPlayhead(key: String, positionMs: Int64, durationMs: Int64, streamPos: Int64? = nil) {
        queue.sync {
            sessions[key]?.playheadMs = (positionMs, durationMs)
            if let streamPos, streamPos > 0 {
                sessions[key]?.playheadStreamPos = streamPos
            }
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
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            lines.append("App: Nuvio Samin \(appVersion) (\(appBuild))")
            lines.append("iOS: \(UIDevice.current.systemVersion) | Device: \(UIDevice.current.model)")
            lines.append("Free disk space: \(freeSpaceBytes() / 1024 / 1024) MB (low-space threshold: \(saminProxyLowSpaceBytes / 1024 / 1024) MB)")
            lines.append("Server active: \(listener != nil), port: \(port)")
            lines.append("Active session count: \(sessions.count)")

            let targetSession = sessions[key] ?? sessions.values.first
            if let s = targetSession {
                lines.append("\n--- Session: [\(s.key)] ---")
                lines.append("Session kind: \(s.kind == .hls ? "HLS segment cache" : (s.kind == .passThrough ? "pass-through (unsupported manifest)" : "progressive byte cache"))")
                if s.kind == .hls || s.kind == .passThrough {
                    // Samin: HLS sessions report their own state; the byte-model
                    // fields (HEAD probe, chunks, forward downloader) do not apply.
                    if let hls = s.hls {
                        lines.append(contentsOf: hls.diagnosticLines())
                    } else {
                        lines.append("HLS state: unavailable (session not constructed for HLS)")
                    }
                    let playheadStr = s.playheadMs.map { "\($0.0 / 1000)s / \($0.1 / 1000)s" } ?? "none"
                    lines.append("Playhead: \(playheadStr)")
                    lines.append("What to compare: a healthy HLS session shows the fetched playlist, cached segments vs total, and the prefetch front. 'playlist failed' means the segment cache is inactive and mpv is effectively streaming pass-through.")
                } else if let url = URL(string: s.sourceUrl) {
                    let ext = url.pathExtension.isEmpty ? "(no extension)" : ".\(url.pathExtension)"
                    let queryInfo = url.query.map { "query=\($0.count) chars (auth token redacted)" } ?? "no query"
                    lines.append("Host: \(url.host ?? "unknown") | Type: \(ext) | URL len: \(s.sourceUrl.count) | \(queryInfo)")
                } else {
                    lines.append("Source URL: unparseable (\(s.sourceUrl.count) chars)")
                }
                lines.append("Upstream headers held by proxy: \(s.headerNames.isEmpty ? "none" : s.headerNames.joined(separator: ", "))")
                lines.append("HEAD probe: HTTP \(s.headStatusCode.map { String($0) } ?? "no response") | Content-Length: \(s.headContentLength.map { "\($0) (\($0 / 1024 / 1024) MB)" } ?? "missing")")
                lines.append("Last upstream GET: HTTP \(s.lastUpstreamStatus.map { String($0) } ?? "none yet") | Accept-Ranges: \(s.upstreamAcceptRanges ?? "unknown")")
                if s.headStatusCode != nil && s.headContentLength == nil && s.totalSize == nil {
                    lines.append("NOTE: upstream gave no size (typical for debrid/CDN links on very large files). Ranges and duration mapping are estimated until the first GET response arrives.")
                }
                if s.lastUpstreamStatus == 200 {
                    lines.append("NOTE: upstream returned HTTP 200 to a Range request (Range ignored). Proxy restarts from byte 0; seeks on huge files will be slow.")
                }
                let sizeStr = s.totalSize.map { "\($0) bytes (\(String(format: "%.1f", Double($0) / 1024.0 / 1024.0)) MB, \(s.totalChunks()) x 2 MB chunks)" } ?? "unknown"
                lines.append("Total Size: \(sizeStr)")
                lines.append("Cached: \(s.cachedChunks.count) full chunks + \(s.bytesWrittenByChunk.count) partial (\(String(format: "%.1f", Double(s.totalCachedBytes()) / 1024.0 / 1024.0)) MB logical, \(s.cacheDirBytes() / 1024 / 1024) MB on disk, \(String(format: "%.1f", s.percentComplete()))%)")
                if let idx = s.mediaIndex {
                    lines.append("Timeline index: EXACT (\(idx.source), \(idx.points.count) points, \(String(format: "%.0f", idx.durationSec))s) — grey bar maps bytes exactly")
                } else {
                    lines.append("Timeline index: estimated (\(s.rateSampleCount()) anchor samples) — grey bar is interpolated until the file's index (cues/moov) is cached")
                }
                lines.append("Evicted (watched, low space): \(s.evictedChunksCount) chunks | Write errors: \(s.writeErrorCount)\(s.lastWriteError.map { " (last: \($0))" } ?? "")")
                lines.append("Speed: \(s.currentSpeed() / 1024) KB/s")
                if s.isRateLimited {
                    let remaining = s.rateLimitedUntil.map { max(0, Int($0.timeIntervalSinceNow)) } ?? 0
                    lines.append("RATE LIMITED by upstream (\(s.lastRateLimitMessage ?? "")): retrying in ~\(remaining)s with no reconnects until then. If the count keeps climbing, the host is throttling this IP — pause a minute before retrying.")
                }
                let playheadStr = s.playheadMs.map { "\($0.0 / 1000)s / \($0.1 / 1000)s" } ?? "none (open player, wait 5s, reopen report)"
                lines.append("Playhead: \(playheadStr)")
                if let fd = s.forwardDownloader {
                    let elapsed = saminNow() - fd.startedUptime
                    lines.append("Forward Downloader: active, start=\(fd.startByte) (\(fd.startByte / 1024 / 1024) MB), offset=\(fd.streamOffset) (\(fd.streamOffset / 1024 / 1024) MB), received=\(fd.totalBytesReceived / 1024 / 1024) MB in \(String(format: "%.0f", elapsed))s, retries=\(fd.retryCount), reconnects=\(s.forwardReconnects), finished=\(fd.isFinished)\(fd.lastErrorMessage.map { ", lastError='\($0)'" } ?? "")")
                    // Samin: the stall signature from slow-link resumes — the
                    // prefetcher filling an unwatched prefix while playback
                    // waits gigabytes ahead on one-off chunk fetches. Surfaced
                    // here so the report explains itself.
                    let gapBytes = s.cacheAnchorByte - fd.streamOffset
                    if !fd.isFinished, gapBytes > 128 * 1024 * 1024 {
                        lines.append("NOTE: forward downloader is \(gapBytes / 1024 / 1024) MB behind the playhead (anchor=\(s.cacheAnchorByte / 1024 / 1024) MB). Bandwidth is filling an unwatched prefix while playback starves on one-off chunk fetches — the prefetcher should jump to the playhead.")
                    }
                } else {
                    lines.append("Forward Downloader: none / idle")
                }
                if !s.chunkFetchers.isEmpty {
                    let chunks = s.chunkFetchers.keys.sorted().map(String.init).joined(separator: ", ")
                    lines.append("Dedicated chunk fetches: \(s.chunkFetchers.count) active (chunks \(chunks))")
                }
                lines.append("MPV client range requests: \(s.clientRangeRequests)\(s.lastClientRange.map { " (last: \($0))" } ?? "")")
                lines.append("Active Client Connections: \(s.activeConnections.count)")
                for (_, conn) in s.activeConnections {
                    lines.append("  * conn offset=\(conn.streamOffset), end=\(conn.streamEnd), waiting=\(conn.isWaitingForData), waitingChunk=\(conn.waitingChunkIndex)")
                }
                lines.append("What to compare: if Total Size is 'unknown' or Last GET is 200 while a ~1 GB file shows 206 + known size, the host is not serving ranges for the big file. If Write errors > 0 or Free disk < file size, the device ran out of room (3 GB needs 3 GB free). If reconnects climb with timeout/reset errors, the upstream drops long connections.")
            } else {
                lines.append("\nNo active session found matching '\(key)'. Open the player first, wait a few seconds, then reopen this report.")
            }

            let logEntries = LocalCacheProxyLog.shared.snapshot()
            let collapsedLog = Self.collapseWaitLines(logEntries)
            lines.append("\n--- Event Log (Last \(collapsedLog.count) shown, \(logEntries.count) stored) ---")
            lines.append(contentsOf: collapsedLog)

            // Samin: unified player + proxy timeline. Source tags: "player" is
            // a decision made by MPVPlayerBridge, "mpv/<prefix>" is libmpv's own
            // log, "proxy" mirrors the event log above, "sample" is the 2s
            // playback state line. Only the tail is shown: the full ring holds
            // 1200 lines, but pasting thousands of lines by hand is what made
            // the report unreadable.
            let trace = PlaybackTrace.shared.snapshot()
            if !trace.isEmpty {
                let tail = Array(trace.suffix(250))
                let skipped = trace.count - tail.count
                if skipped > 0 {
                    lines.append("\n--- Playback Trace (last \(tail.count) of \(trace.count) lines, oldest first) ---")
                } else {
                    lines.append("\n--- Playback Trace (last \(tail.count) lines, oldest first) ---")
                }
                lines.append(contentsOf: tail)
            }
            lines.append("=== END REPORT ===")
            return lines.joined(separator: "\n")
        }
    }

    /// Collapses runs of hot-path wait lines ("Waiting for data…", "Still
    /// waiting…") into one summary per run, so a starved minute does not paste
    /// as hundreds of near-identical lines. Old reports that predate wait
    /// throttling still collapse here.
    private static func collapseWaitLines(_ entries: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(entries.count)
        var runCount = 0
        var runFirst: String?
        var runLast: String?
        func flush() {
            guard runCount > 0 else { return }
            if runCount == 1, let single = runLast {
                out.append(single)
            } else if let first = runFirst, let last = runLast {
                out.append("\(first)  …[\(runCount - 1) similar wait lines collapsed]…  \(last)")
            }
            runCount = 0
            runFirst = nil
            runLast = nil
        }
        for line in entries {
            if line.contains("Waiting for data at chunk") || line.contains("Still waiting at chunk") {
                runCount += 1
                if runFirst == nil { runFirst = line }
                runLast = line
            } else {
                flush()
                out.append(line)
            }
        }
        flush()
        return out
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
    var sourceUrl: String
    var headers: [String: String]
    let dir: URL
    unowned let server: LocalCacheProxyServer
    /// Samin: what kind of stream this session serves. Determines whether the
    /// byte-chunk machinery (progressive), the HLS segment machinery, or plain
    /// pass-through is used.
    let kind: ProxySessionKind
    /// Samin: HLS segment cache state. nil for non-HLS sessions.
    var hls: HLSStreamState?

    var totalSize: Int64?
    var contentType: String?
    var playheadMs: (Int64, Int64)? {
        didSet {
            onPlayheadUpdated()
        }
    }
    var playheadStreamPos: Int64?
/// Byte anchor the forward prefetcher should follow. The playhead bar is
    /// drawn in time, but the cache only knows bytes; without an anchor the
    /// forward write head starts at the seek/reconnect anchor and leaps ahead
    /// of the live playhead, leaving the visible bar ahead of the cached
    /// window and forcing one-off fetches instead of sequential streaming.
    /// Updated on every playhead report and each time the prefetcher is
    /// repositioned, so the cached window tracks the actual playback position
    /// and the bar no longer leads the cached bytes.
    var cacheAnchorByte: Int64 {
      guard valid else { return 0 }
      if let streamPos = playheadStreamPos, streamPos > 0 {
        return streamPos
      }
      guard let (pos, dur) = playheadMs, dur > 0, let total = totalSize, total > 0 else {
        return 0
      }
      if let index = mediaIndex {
        return index.byte(forSeconds: Double(pos) / 1000.0)
      }
      return max(0, min(total, Int64((Double(pos) / Double(dur)) * Double(total))))
    }
    var valid = true
    private(set) var cachedChunks: Set<Int64> = []
    var bytesWrittenByChunk: [Int64: Int64] = [:]

    fileprivate(set) var forwardDownloader: ForwardDownloader?
    // Short-lived range fetches for chunks the prefetcher is not about to reach
    // (behind its write head, or far-ahead index probes). They never disturb the
    // forward stream, which is what stopped the old reposition ping-pong.
    private(set) var chunkFetchers: [Int64: BackwardDownloader] = [:]
    fileprivate(set) var activeConnections: [ObjectIdentifier: ProxyConnection] = [:]
    private var headWaiters: [ProxyConnection] = []
    private var lastForwardDownloaderStartTime: TimeInterval = 0

    private(set) var activeChunkWriters: [Int64: String] = [:]

    // Diagnostic state (all touched on the server queue).
    var headStatusCode: Int?
    var headContentLength: Int64?
    var lastUpstreamStatus: Int?
    var upstreamAcceptRanges: String?
    var evictedChunksCount = 0
    var writeErrorCount = 0
    var lastWriteError: String?
    var forwardReconnects = 0
    var clientRangeRequests = 0
    var lastClientRange: String?
    var headerNames: [String]

    // Rate-limit backoff (HTTP 429/503 from throttling upstreams such as
    // Cloudflare Workers). While set, no new upstream connections are opened;
    // waiting clients stay parked and a single timer resumes the stream.
    var rateLimitedUntil: Date?
    var consecutiveRateLimits = 0
    var lastRateLimitMessage: String?
    var lastForegroundWakeUptime: TimeInterval = 0

    // Timeline mapping. The played bar is drawn in *time* (position/duration),
    // but the cache only knows *byte* offsets; on a VBR file the two drift, so
    // a raw byte fraction lands ahead of the playhead and leaves a visible gap.
    // First choice is the exact container index (MediaIndex.swift: MKV cues /
    // MP4 sample tables read from the file itself). While its bytes are still
    // downloading, we fall back to anchored (timeFraction, byteFraction) pairs
    // taken whenever the player reports a new position, mapping saved byte
    // ranges into time before drawing them.
    private var rateSamples: [(t: Double, b: Double)] = []
    private var pendingSeekByte: (byte: Int64, at: TimeInterval)?
    // Exact index state (see MediaIndex.swift). Built once the index bytes are
    // on disk; index chunks are prefetched on demand so resumed streams do not
    // wait for the forward downloader to reach the end of the file.
    var mediaIndex: MediaIndexTable?
    private var mediaIndexDone = false
    private var mediaIndexCachedCount = -1
    private var mediaIndexTailChunk: Int64 = -1

    var isRateLimited: Bool {
        if let until = rateLimitedUntil { return Date() < until }
        return false
    }

    func noteRateLimit(retryAfter seconds: TimeInterval) {
        consecutiveRateLimits += 1
        rateLimitedUntil = Date().addingTimeInterval(seconds)
        lastRateLimitMessage = "HTTP 429/503 x\(consecutiveRateLimits), retry in \(Int(seconds))s"
    }

    func clearRateLimit() {
        consecutiveRateLimits = 0
        rateLimitedUntil = nil
    }

    init(key: String, sourceUrl: String, headers: [String: String], baseDir: URL, server: LocalCacheProxyServer, kind: ProxySessionKind = .progressive) {
        self.key = key
        self.sourceUrl = sourceUrl
        self.headers = headers
        self.headerNames = Array(headers.keys).sorted()
        self.dir = baseDir
        self.server = server
        self.kind = kind
        if FileManager.default.fileExists(atPath: baseDir.path) {
            try? FileManager.default.removeItem(at: baseDir)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        if kind == .hls {
            hls = HLSStreamState(session: self)
        } else {
            hls = nil
        }
        // The byte-model HEAD probe is meaningless for a playlist (its
        // Content-Length is the text size) and would pollute diagnostics.
        if kind != .hls && kind != .passThrough {
            probeTotalSizeIfNeeded()
        }
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
        chunkFetchers.values.forEach { $0.cancel() }
        chunkFetchers.removeAll()
        hls?.shutdown()
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

    /// Update the upstream source URL/headers for the same session (e.g. debrid re-resolve).
    /// Preserves the on-disk cache directory and cached chunks. Restarts the forward
    /// downloader if the upstream URL actually changed.
    func updateSourceUrl(_ newSourceUrl: String, _ newHeaders: [String: String]) {
        guard newSourceUrl != sourceUrl || newHeaders != headers else { return }
        let oldSourceUrl = sourceUrl
        sourceUrl = newSourceUrl
        headers = newHeaders
        headerNames = Array(newHeaders.keys).sorted()
        LocalCacheProxyLog.shared.log("Session [\(key)]: Updated upstream URL \(oldSourceUrl) -> \(newSourceUrl)")
        // Samin: hand the new upstream to the HLS pipeline (same URL pattern as
        // experiments over these trailers). hls may be nil when the failure is
        // surfaced as .passThrough before state construction.
        if let hls = hls {
            hls.setUpstream(newSourceUrl, newHeaders)
        }
        // If a forward downloader is running and the upstream changed, restart it
        // so subsequent range requests go to the new URL. The cached chunks stay valid
        // because debrid re-resolves point to the same file bytes.
        if let fd = forwardDownloader, !fd.isFinished {
            fd.cancel()
            forwardDownloader = nil
            startNewForwardDownloader(targetStartByte: fd.streamOffset, reason: "upstream URL changed")
        }
    }

    var playheadByte: Int64? {
        if let streamPos = playheadStreamPos, streamPos > 0 {
            return streamPos
        }
        guard let (pos, dur) = playheadMs, dur > 0, let total = totalSize, total > 0 else { return nil }
        if let index = mediaIndex {
            return index.byte(forSeconds: Double(pos) / 1000.0)
        }
        return max(0, min(total, Int64((Double(pos) / Double(dur)) * Double(total))))
    }

    /// Adaptive lookahead window: for high-bitrate files (e.g. 4K remuxes),
    /// scale up from 32 MB to up to 128 MB (roughly 30s of buffer) so MPV's
    /// natural sequential readahead doesn't trigger one-off chunk fetchers.
    var aheadWindowBytes: Int64 {
        if let total = totalSize, total > 0, let (_, dur) = playheadMs, dur > 10_000 {
            let bytesPerSec = Double(total) / (Double(dur) / 1000.0)
            let adaptive = Int64(bytesPerSec * 30.0)
            return max(saminProxyAheadWindowBytes, min(128 * 1024 * 1024, adaptive))
        }
        return saminProxyAheadWindowBytes
    }

    func chunkURL(_ index: Int64) -> URL {
        dir.appendingPathComponent("c\(index).bin")
    }

    func markCached(_ index: Int64) {
        cachedChunks.insert(index)
        bytesWrittenByChunk.removeValue(forKey: index)
        notifyDataAvailable(chunkIndex: index)
        nudgeWaitingClients()
        maybeBuildMediaIndex()
    }

    /// Tries to build the exact byte->time index (MediaIndex.swift) once its
    /// bytes are on disk. Retries only when the cache actually grew; asks the
    /// chunk-fetcher pool for the specific index chunks (header/cues/moov) so
    /// resumed streams get an exact bar within seconds instead of when the
    /// forward downloader finally reaches the end of the file.
    func maybeBuildMediaIndex() {
        guard valid, !mediaIndexDone, mediaIndex == nil else { return }
        guard kind == .progressive else { return }
        guard let total = totalSize, total > 0 else { return }
        let cachedCount = cachedChunks.count
        let maxChunk = cachedChunks.max() ?? -1
        if cachedCount == mediaIndexCachedCount && maxChunk <= mediaIndexTailChunk { return }
        switch MediaIndexBuilder.build(dir: dir, chunkBytes: saminProxyChunkBytes, totalSize: total) {
        case .ready(let table):
            mediaIndex = table
            mediaIndexDone = true
            LocalCacheProxyLog.shared.log("Session [\(key)]: Timeline index exact (\(table.source), \(table.points.count) points) — grey bar now maps bytes exactly")
        case .needChunks(let idxs):
            mediaIndexCachedCount = cachedCount
            mediaIndexTailChunk = maxChunk
            var room = saminProxyMaxChunkFetchers - chunkFetchers.count
            for idx in idxs {
                guard room > 0 else { break }
                if !cachedChunks.contains(idx), chunkFetchers[idx] == nil {
                    ensureChunkFetcher(chunkIndex: idx)
                    room -= 1
                }
            }
        case .needMoreData:
            mediaIndexCachedCount = cachedCount
            mediaIndexTailChunk = maxChunk
        case .unsupported(let why):
            mediaIndexDone = true
            LocalCacheProxyLog.shared.log("Session [\(key)]: No exact timeline index (\(why)) — grey bar stays estimated")
        }
    }

    func rateSampleCount() -> Int { rateSamples.count }

    /// Re-pumps any client parked on a chunk that is not the one just completed,
    /// so a freed fetch-pool slot (or a newly cached chunk) is picked up instead
    /// of leaving the client waiting forever.
    func nudgeWaitingClients() {
        for conn in activeConnections.values where conn.isWaitingForData {
            conn.onDataAvailable(chunkIndex: conn.waitingChunkIndex)
        }
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
        connection.startHeadersWaitTimer()
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

    func handleForegroundWake() {
        guard valid else { return }
        let now = saminNow()
        if now - lastForegroundWakeUptime < 2.0 {
            // willEnterForeground + didBecomeActive fire back-to-back on every
            // app return (screenshot, app switch); handle only the first.
            return
        }
        lastForegroundWakeUptime = now
        if isRateLimited {
            LocalCacheProxyLog.shared.log("Session [\(key)]: Foreground wake during rate-limit backoff; leaving stream alone")
            return
        }
        guard let fd = forwardDownloader, !fd.isFinished else {
            // Nothing is streaming forward (the download died while suspended, or it
            // finished before the playhead). If a client is parked waiting for a
            // chunk, restart from there — otherwise it stays hung until a relaunch.
            if let waiting = activeConnections.values.first(where: { $0.isWaitingForData && $0.waitingChunkIndex >= 0 }) {
                LocalCacheProxyLog.shared.log("Session [\(key)]: Foreground wake with no active forward stream -> restarting from waiting chunk \(waiting.waitingChunkIndex)")
                ensureForwardDownloading(from: waiting.waitingChunkIndex * saminProxyChunkBytes)
            }
            return
        }
        let idle = now - fd.lastByteUptime
        if idle > 4.0 {
            LocalCacheProxyLog.shared.log("Session [\(key)]: Foreground wake with stalled stream (idle=\(String(format: "%.1f", idle))s) -> reconnecting...")
            fd.handleForegroundWake()
        } else {
            LocalCacheProxyLog.shared.log("Session [\(key)]: Foreground wake, stream healthy (idle=\(String(format: "%.1f", idle))s); leaving it alone")
        }
    }

    /// Serves a client request for [startByte]. The forward prefetcher follows
    /// sequential reads and the live playhead; requests behind its write head,
    /// or far-ahead one-off probes, are handed to a dedicated range fetch.
    /// A prefetcher parked gigabytes behind live playback is jumped forward
    /// (see below) instead of starving playback on one-off 2 MB fetches.
    func ensureForwardDownloading(from startByte: Int64) {
        guard valid else { return }

        let chunkIdx = startByte / saminProxyChunkBytes
        let chunkOffset = startByte % saminProxyChunkBytes

        // 1. Already on disk (full, or written past this point).
        if chunkOffset < bytesAvailable(for: chunkIdx) || cachedChunks.contains(chunkIdx) {
            return
        }

        // 2. Never open new upstream connections while rate-limited.
        if isRateLimited {
            return
        }

        if let fd = forwardDownloader, !fd.isFinished {
            let ahead = startByte - fd.streamOffset        // Sequential read just ahead of the write head: let the running
        // stream reach it.
        if ahead >= 0 && ahead <= aheadWindowBytes {
          return
        }
        // Anchor the window head to the live playhead so a fresh stream /
        // reconnect does not sit behind the visible bar. If the anchor is
        // right at the write head, do not reposition the stream; let it
        // continue streaming forward from where it is.
        if cacheAnchorByte >= fd.streamOffset &&
           cacheAnchorByte - fd.streamOffset <= saminProxyAheadWindowBytes {
          return
        }

        // Playback far ahead of a prefetcher that is still filling an
        // unwatched prefix: the session's first client request is usually the
        // container header/moov probe at byte 0, which parks the FD at 0
        // while real playback resumes gigabytes ahead. Playhead pushes are
        // throttled (and freeze entirely while buffering, since the position
        // stops moving), so the playhead-driven reposition below never fires
        // and playback starves on one-off 2 MB fetches that share throttled
        // upstream bandwidth with the useless prefix — 1 s play / 3 s buffer.
        // Jump the continuous stream to live playback instead. Both the
        // request AND the anchor must be far ahead so a lone far-ahead index
        // probe can never drag the stream away from real playback.
        if startByte - fd.streamOffset > saminProxyForwardSeekBytes &&
           cacheAnchorByte - fd.streamOffset > saminProxyForwardSeekBytes &&
           saminNow() - lastForwardDownloaderStartTime > 3.0 {
            // Start at the earlier of request/anchor: the anchor is a
            // time-ratio estimate on VBR files and can sit ahead of the bytes
            // mpv actually needs, which would strand the waiting chunk behind
            // the new write head.
            let targetByte = min(startByte, cacheAnchorByte)
            let target = (targetByte / saminProxyChunkBytes) * saminProxyChunkBytes
            LocalCacheProxyLog.shared.log("Session [\(key)]: Playback \(((startByte - fd.streamOffset) / 1024 / 1024)) MB ahead of prefetcher (offset=\(fd.streamOffset / 1024 / 1024) MB, anchor=\(cacheAnchorByte / 1024 / 1024) MB) -> jumping prefetcher to \(target / 1024 / 1024) MB")
            cancelAllChunkFetchers()
            fd.cancel()
            forwardDownloader = nil
            startNewForwardDownloader(targetStartByte: target, reason: "playback ahead at \(startByte)")
            return
        }

        // Backward seek: playback is far behind the prefetcher in an uncached region.
        // The forward downloader is filling the far future while playback starves on
        // one-off 2 MB chunk fetches. Jump the prefetcher back to the live read head.
        if fd.streamOffset - startByte > saminProxyBackwardSeekBytes &&
           !cachedChunks.contains(chunkIdx) &&
           saminNow() - lastForwardDownloaderStartTime > 2.0 {
            let phChunk = chunkIdx
            let totalChunks = totalSize.map { ($0 + saminProxyChunkBytes - 1) / saminProxyChunkBytes } ?? Int64.max
            var gap: Int64 = 0
            while gap < saminProxyBackwardGapChunks,
                  phChunk + gap < totalChunks,
                  !cachedChunks.contains(phChunk + gap) {
                gap += 1
            }
            if gap >= 2 {
                let target = phChunk * saminProxyChunkBytes
                LocalCacheProxyLog.shared.log("Session [\(key)]: Playback \(((fd.streamOffset - startByte) / 1024 / 1024)) MB behind prefetcher (offset=\(fd.streamOffset / 1024 / 1024) MB, target=\(target / 1024 / 1024) MB, gap=\(gap)) -> jumping prefetcher backward to chunk \(phChunk)")
                cancelAllChunkFetchers()
                fd.cancel()
                forwardDownloader = nil
                startNewForwardDownloader(targetStartByte: target, reason: "playback behind at \(startByte)")
                return
            }
        }

        // Single missing chunk (evicted or short gap): fetch this chunk on its own
        // without touching the main forward stream.
        ensureChunkFetcher(chunkIndex: chunkIdx)
        return
        }

        // 3. No live prefetcher.
        if let fd = forwardDownloader, fd.isFinished, startByte >= fd.startByte {
            // The finished stream already covered this region; it is missing only
            // because it was evicted — refetch just this chunk.
            ensureChunkFetcher(chunkIndex: chunkIdx)
        } else {
            // Initial load, recovery after a failed stream, or a region the
            // finished stream never covered: (re)start the prefetcher here.
            // Cancel any in-flight chunk fetchers to avoid chunk conflicts.
            cancelAllChunkFetchers()
            startNewForwardDownloader(targetStartByte: chunkIdx * saminProxyChunkBytes, reason: "client request at \(startByte)")
        }
    }

    private func startNewForwardDownloader(targetStartByte: Int64, reason: String) {
        lastForwardDownloaderStartTime = saminNow()
        // Remember where this (re)position points so the next playhead report
        // can anchor the byte<->time mapping for the saved bar.
        pendingSeekByte = (byte: targetStartByte, at: saminNow())
        let fd = ForwardDownloader(session: self, startByte: targetStartByte)
        self.forwardDownloader = fd
        fd.start()
        LocalCacheProxyLog.shared.log("Session [\(key)]: Started FD at \(targetStartByte) (\(reason))")
    }

    /// Starts a short-lived range fetch for one chunk if one is not already in
    /// flight and the pool has room. Used for chunks the prefetcher will not
    /// reach soon, so playback never waits on a repositioned stream.
    func ensureChunkFetcher(chunkIndex: Int64) {
        guard valid, !isRateLimited, chunkIndex >= 0 else { return }
        if cachedChunks.contains(chunkIndex) { return }
        if chunkFetchers[chunkIndex] != nil { return }
        if chunkFetchers.count >= saminProxyMaxChunkFetchers { return }
        // Don't compete with the prefetcher for the chunk it is writing right now.
        if let fd = forwardDownloader, !fd.isFinished, fd.currentChunkIndex == chunkIndex {
            return
        }
        if !claimChunkWrite(chunkIndex: chunkIndex, owner: "fetch") {
            return
        }
        let bd = BackwardDownloader(session: self, chunkIndex: chunkIndex)
        chunkFetchers[chunkIndex] = bd
        LocalCacheProxyLog.shared.log("Session [\(key)]: Dedicated fetch for chunk \(chunkIndex) (pool=\(chunkFetchers.count))")
        bd.start()
    }

    /// Cancel all in-flight chunk fetchers. Called when the forward prefetcher
    /// is repositioned to avoid chunk conflicts and redundant downloads.
    func cancelAllChunkFetchers() {
        for (_, fetcher) in chunkFetchers {
            fetcher.cancel()
        }
        chunkFetchers.removeAll()
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

    /// Fills gaps the prefetcher skipped (seeked past) or never reached, nearest
    /// the playhead first, up to the fetch-pool limit. Runs only after the
    /// forward stream is done so it cannot compete with sequential playback.
    func startBackwardDownloadIfNeeded() {
        guard valid, !isRateLimited else { return }
        guard server.freeSpaceBytes() >= saminProxyLowSpaceBytes else { return }
        guard let total = totalSize, total > 0 else { return }
        guard forwardDownloader == nil || forwardDownloader?.isFinished == true else { return }

        let totalChunks = (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes
        let playheadChunk = playheadByte.map { $0 / saminProxyChunkBytes } ?? 0
        // Nearest-behind-playhead first (most likely to be re-watched), then the rest.
        var ordered: [Int64] = []
        if playheadChunk > 0 {
            ordered += stride(from: playheadChunk - 1, through: 0, by: -1)
        }
        if playheadChunk < totalChunks {
            ordered += stride(from: playheadChunk, to: totalChunks, by: 1)
        }
        for idx in ordered {
            if chunkFetchers.count >= saminProxyMaxChunkFetchers { break }
            if cachedChunks.contains(idx) { continue }
            ensureChunkFetcher(chunkIndex: idx)
        }
    }

    func onBackwardChunkCompleted(chunkIndex: Int64, success: Bool) {
        if chunkFetchers.removeValue(forKey: chunkIndex) != nil {
            releaseChunkWrite(chunkIndex: chunkIndex, owner: "fetch")
        }
        // A freed pool slot may let a parked client start its own fetch now.
        nudgeWaitingClients()
        guard valid else { return }
        if success, forwardDownloader == nil || forwardDownloader?.isFinished == true {
            startBackwardDownloadIfNeeded()
        }
    }

    /// Makes room for one more chunk. Only strictly watched (behind-playhead)
    /// chunks are evicted when storage is low (< 300 MB).
    /// Pinning Rules:
    /// - Chunk 0 (container header / track metadata) is NEVER evicted.
    /// - Final 8 chunks / 16 MB before EOF (Matroska seekhead / cues) are NEVER evicted.
    /// - Rewind safety buffer (4 chunks / 8 MB behind playhead) is protected unless critical.
    /// Forward unwatched chunks are NEVER evicted.
    func makeRoomForChunk(excluding: Int64) -> Bool {
        guard server.freeSpaceBytes() < saminProxyLowSpaceBytes else { return true }
        let playheadChunk = playheadByte.map { $0 / saminProxyChunkBytes } ?? 0
        let totalChunks = totalSize.map { ($0 + saminProxyChunkBytes - 1) / saminProxyChunkBytes } ?? Int64.max
        let eofProtectedStart = max(1, totalChunks - 8)
        let rewindProtectedStart = max(1, playheadChunk - 4)

        // Tier 1: Older watched chunks far behind the playhead (excluding Chunk 0 and rewind buffer)
        let tier1Victims = cachedChunks.filter {
            $0 != excluding && $0 > 0 && $0 < rewindProtectedStart && $0 < eofProtectedStart
        }.sorted()

        for victim in tier1Victims {
            removeChunk(victim)
            if server.freeSpaceBytes() >= saminProxyLowSpaceBytes { return true }
        }

        // Tier 2: If still under severe pressure, evict the rewind buffer (between rewindProtectedStart ..< playheadChunk)
        let tier2Victims = cachedChunks.filter {
            $0 != excluding && $0 > 0 && $0 < playheadChunk && $0 < eofProtectedStart
        }.sorted()

        for victim in tier2Victims {
            removeChunk(victim)
            if server.freeSpaceBytes() >= saminProxyLowSpaceBytes { return true }
        }

        return server.freeSpaceBytes() >= saminProxyLowSpaceBytes
    }

    private func removeChunk(_ index: Int64) {
        cachedChunks.remove(index)
        bytesWrittenByChunk.removeValue(forKey: index)
        try? FileManager.default.removeItem(at: chunkURL(index))
        evictedChunksCount += 1
    }

    private    func onPlayheadUpdated() {
        guard valid else { return }
        // Samin: the byte-stream machinery has no meaning for HLS sessions.
        guard kind != .hls, kind != .passThrough else {
            hls?.playheadUpdated()
            return
        }
        recordPlayheadSample()
        maybeRepositionForward()
        // Evict watched chunks behind the playhead if storage is currently tight
        _ = makeRoomForChunk(excluding: -1)
        if let fd = forwardDownloader, fd.isPausedForLowSpace, server.freeSpaceBytes() >= saminProxyLowSpaceBytes {
            fd.resumeFromLowSpace()
        }
    }

    /// Moves the prefetcher to the playhead after a genuine seek so bandwidth
    /// goes where playback actually is:
    /// - forward: playhead lands far beyond the write head;
    /// - backward: playhead lands far behind it in an uncached region (the
    ///   stream would otherwise keep filling the far future while playback
    ///   crawls through one-off 2 MB chunk fetches).
    private func maybeRepositionForward() {
        guard let ph = playheadByte, let fd = forwardDownloader, !fd.isFinished else { return }
        guard !isRateLimited else { return }

        // If an active client is waiting for data or reading at an earlier byte,
        // clamp to that client's streamOffset so the prefetcher never leaps ahead
        // of MPV's active read head on VBR files.
        var effectivePh = ph
        for conn in activeConnections.values {
            if conn.streamOffset > 0 && conn.streamOffset < effectivePh {
                effectivePh = conn.streamOffset
            }
        }

        if effectivePh > fd.streamOffset + saminProxyForwardSeekBytes {
            let target = (effectivePh / saminProxyChunkBytes) * saminProxyChunkBytes
            LocalCacheProxyLog.shared.log("Session [\(key)]: Forward seek -> moving prefetcher \(fd.streamOffset) -> \(target)")
            fd.cancel()
            forwardDownloader = nil
            startNewForwardDownloader(targetStartByte: target, reason: "forward seek")
            return
        }

        // Backward: trust MPV's real read position, parsed container cues, or
        // active client socket offsets, and debounce after a restart.
        let hasReliablePosition = playheadStreamPos != nil || mediaIndex != nil || activeConnections.values.contains(where: { $0.streamOffset > 0 })
        guard hasReliablePosition,
              effectivePh + saminProxyBackwardSeekBytes < fd.streamOffset,
              saminNow() - lastForwardDownloaderStartTime > 2.0 else { return }

        let phChunk = effectivePh / saminProxyChunkBytes
        let totalChunks = totalSize.map { ($0 + saminProxyChunkBytes - 1) / saminProxyChunkBytes } ?? Int64.max
        var gap: Int64 = 0
        while gap < saminProxyBackwardGapChunks,
              phChunk + gap < totalChunks,
              !cachedChunks.contains(phChunk + gap) {
            gap += 1
        }
        // Only jump if there is an uncached gap of at least 2 chunks.
        guard gap >= 2 else { return }

        let target = phChunk * saminProxyChunkBytes
        LocalCacheProxyLog.shared.log("Session [\(key)]: Backward seek -> moving prefetcher \(fd.streamOffset) -> \(target)")
        cancelAllChunkFetchers()
        fd.cancel()
        forwardDownloader = nil
        startNewForwardDownloader(targetStartByte: target, reason: "backward seek")
    }

    /// Pairs a fresh playhead (time) with the byte MPV actually reports
    /// (stream-pos), so the timeline can convert byte fractions to time
    /// exactly instead of estimating from the duration ratio.
    func recordPlayheadSample() {
        guard let total = totalSize, total > 0,
              let (pos, dur) = playheadMs, dur > 0 else { return }
        let t = Double(pos) / Double(dur)
        // Prefer the real byte position; fall back to the seek anchor.
        let b: Double
        if let streamPos = playheadStreamPos, streamPos > 0 {
            b = Double(streamPos) / Double(total)
        } else if let pending = pendingSeekByte, saminNow() - pending.at < 3.0 {
            b = Double(pending.byte) / Double(total)
        } else {
            return
        }
        pendingSeekByte = nil
        guard t.isFinite, b.isFinite else { return }
        noteRateSample(t: t, b: b)
    }

    private func noteRateSample(t: Double, b: Double) {
        guard t.isFinite, b.isFinite else { return }
        let tt = min(max(t, 0.0), 1.0)
        let bb = min(max(b, 0.0), 1.0)
        if let last = rateSamples.last, abs(last.t - tt) < 0.002, abs(last.b - bb) < 0.002 { return }
        rateSamples.append((t: tt, b: bb))
        if rateSamples.count > 200 { rateSamples.removeFirst(rateSamples.count - 200) }
        rateSamples.sort { $0.t < $1.t }
        // Keep byte strictly increasing with time; drop anomalies (e.g. an
        // index/moov probe at byte 0) that would skew the interpolation.
        var monotonic: [(t: Double, b: Double)] = []
        for s in rateSamples {
            if let last = monotonic.last, s.b < last.b { continue }
            monotonic.append(s)
        }
        rateSamples = monotonic
    }

    /// Maps a byte fraction to a timeline (time) fraction. Prefers the exact
    /// container index when built; falls back to the observed anchor
    /// interpolation, then to the raw byte fraction when nothing was sampled.
    func byteFractionToTime(_ b: Double) -> Double {
        let bb = min(max(b, 0.0), 1.0)
        if let index = mediaIndex, let total = totalSize, total > 0 {
            return index.fraction(forByte: Int64(bb * Double(total)), totalSize: total)
        }
        guard let anchor = rateSamples.first else { return bb }
        if rateSamples.count == 1 {
            return min(max(bb + (anchor.t - anchor.b), 0.0), 1.0)
        }
        var loIndex: Int?
        var hiIndex: Int?
        for (i, s) in rateSamples.enumerated() {
            if s.b <= bb { loIndex = i }
            if s.b >= bb { hiIndex = i; break }
        }
        if let li = loIndex, let hi = hiIndex, hi > li {
            let l = rateSamples[li]
            let h = rateSamples[hi]
            let f = (bb - l.b) / (h.b - l.b)
            return min(max(l.t + f * (h.t - l.t), 0.0), 1.0)
        }
        if let li = loIndex {
            let l = rateSamples[li]
            if li - 1 >= 0, rateSamples[li - 1].b < l.b {
                let p = rateSamples[li - 1]
                let slope = (l.t - p.t) / (l.b - p.b)
                return min(max(l.t + (bb - l.b) * slope, 0.0), 1.0)
            }
            return min(max(bb + (l.t - l.b), 0.0), 1.0)
        }
        if let hi = hiIndex {
            let h = rateSamples[hi]
            if hi + 1 < rateSamples.count, rateSamples[hi + 1].b > h.b {
                let n = rateSamples[hi + 1]
                let slope = (n.t - h.t) / (n.b - h.b)
                return min(max(h.t + (bb - h.b) * slope, 0.0), 1.0)
            }
            return min(max(bb + (h.t - h.b), 0.0), 1.0)
        }
        return bb
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
            let http = response as? HTTPURLResponse
            let code = http?.statusCode
            let total = http
                .flatMap { $0.value(forHTTPHeaderField: "Content-Length") }
                .flatMap(Int64.init)
            let type = http?.value(forHTTPHeaderField: "Content-Type")
            let acceptRanges = http?.value(forHTTPHeaderField: "Accept-Ranges")
            self.server.queue.async { [weak self] in
                guard let self, self.valid else { return }
                if let code { self.headStatusCode = code }
                if let acceptRanges { self.upstreamAcceptRanges = acceptRanges }
                if let total, total > 0 {
                    self.headContentLength = total
                }
                if let total, total > 0, self.totalSize == nil {
                    self.totalSize = total
                    if let type, self.contentType == nil {
                        self.contentType = type
                    }
                    self.notifyHeadersAvailable()
                    self.maybeBuildMediaIndex()
                } else if self.totalSize == nil {
                    // HEAD gave no usable size (common on debrid/CDN links for
                    // very large files): still wake waiting clients so the
                    // failure is visible in the diagnostic report instead of
                    // hanging silently.
                    LocalCacheProxyLog.shared.log("Session [\(self.key)]: HEAD probe returned HTTP \(code.map { String($0) } ?? "none") with no Content-Length")
                }
                completion?()
            }
        }.resume()
    }

    func cachedRangesJson() -> String {
        // Samin: HLS reports time-domain spans computed from its segment table.
        if kind == .hls || kind == .passThrough {
            return hls?.cachedTimeRangesJson() ?? "[]"
        }
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

        // Report in the same (time) domain as the played bar so the saved
        // stretch abuts the playhead instead of drifting ahead of it on VBR.
        let parts = merged.prefix(saminProxyMaxRanges).map { s, e in
            let t0 = byteFractionToTime(Double(s) / Double(total))
            let t1 = byteFractionToTime(Double(e) / Double(total))
            return "[\(min(t0, t1)),\(max(t0, t1))]"
        }
        return "[\(parts.joined(separator: ","))]"
    }

    private var speedBytesAccumulator: Int64 = 0
    private var lastSpeedCheckUptime: TimeInterval = saminNow()
    private var lastDataReceivedUptime: TimeInterval = 0
    private(set) var currentSpeedBps: Int64 = 0

    func recordBytesReceived(_ count: Int) {
        let now = saminNow()
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
        let now = saminNow()
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

    /// Actual bytes on disk for this session (sums chunk files; cheap enough on demand).
    func cacheDirBytes() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        for name in names {
            let path = dir.appendingPathComponent(name).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    /// Total number of 2 MB chunks the file needs (0 when size unknown).
    func totalChunks() -> Int64 {
        guard let total = totalSize, total > 0 else { return 0 }
        return (total + saminProxyChunkBytes - 1) / saminProxyChunkBytes
    }

    func percentComplete() -> Double {
        guard let total = totalSize, total > 0 else { return 0 }
        return min(1.0, Double(totalCachedBytes()) / Double(total)) * 100.0
    }

    func cacheStatsJson() -> String {
        // Samin: the legacy byte-format needs totalBytes, which HLS playlists
        // never have; the segment layer reports its own shape instead.
        if kind == .hls || kind == .passThrough {
            return hls?.statsJson() ?? "{\"speedBps\":0,\"cachedBytes\":0,\"totalBytes\":0,\"isComplete\":false,\"ranges\":[]}" 
        }
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
    private(set) var isPausedForLowSpace = false

    private var task: URLSessionDataTask?
    private var urlSession: URLSession?
    private var fileHandle: FileHandle?
    private var fileHandleChunk: Int64 = -1
    private var isCancelled = false
    private(set) var retryCount = 0
    private(set) var totalBytesReceived: Int64 = 0
    private(set) var lastErrorMessage: String?
    private(set) var startedUptime: TimeInterval = saminNow()
    private let maxRetries = 10

    // Watchdog
    private(set) var lastByteUptime: TimeInterval = 0
    private var watchdogTimer: DispatchSourceTimer?
    private var receivedBytesInCurrentTask = false
    private var lastReconnectUptime: TimeInterval = 0

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

        var effectiveOffset = offset
        let chunkIdx = offset / saminProxyChunkBytes
        let chunkOffset = offset % saminProxyChunkBytes
        let available = session.bytesAvailable(for: chunkIdx)
        if chunkOffset < available {
            effectiveOffset = (chunkIdx * saminProxyChunkBytes) + available
        }
        // Skip the whole run of already-cached chunks from here, so the stream
        // never re-downloads (and truncates) data that is already on disk.
        while effectiveOffset % saminProxyChunkBytes == 0,
              session.cachedChunks.contains(effectiveOffset / saminProxyChunkBytes) {
            effectiveOffset += saminProxyChunkBytes
        }

        if let total = session.totalSize, total > 0, effectiveOffset >= total {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: All forward chunks cached (effectiveOffset=\(effectiveOffset), total=\(total))")
            finish(failed: false)
            return
        }

        self.streamOffset = effectiveOffset
        lastByteUptime = saminNow()
        receivedBytesInCurrentTask = false

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
        receivedBytesInCurrentTask = false
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

    func handleForegroundWake() {
        guard !isCancelled, !isFinished, session.valid else { return }
        LocalCacheProxyLog.shared.log("FD [\(startByte)]: Foreground wake -> reconnecting continuous stream from \(streamOffset)...")
        reconnect(reason: "foreground wake")
    }

    func pauseForLowSpace() {
        guard !isCancelled, !isFinished, !isPausedForLowSpace else { return }
        isPausedForLowSpace = true
        task?.cancel()
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        cleanupFileHandle()
        if currentChunkIndex >= 0 {
            session.releaseChunkWrite(chunkIndex: currentChunkIndex, owner: "forward")
            currentChunkIndex = -1
        }
        stopWatchdog()
    }

    func resumeFromLowSpace() {
        guard !isCancelled, !isFinished, isPausedForLowSpace else { return }
        isPausedForLowSpace = false
        LocalCacheProxyLog.shared.log("FD [\(startByte)]: Disk space restored, resuming forward download from \(streamOffset)...")
        startWatchdog()
        startStream(from: streamOffset)
    }

    func onClientWaiting(chunkIndex: Int64) {
        guard session.valid, !isCancelled, !isFinished, chunkIndex >= 0 else { return }
        if session.cachedChunks.contains(chunkIndex) { return }
        if session.isRateLimited { return } // stay parked; backoff timer resumes

        // A chunk this stream is not writing is served by a dedicated fetch
        // (started by ensureForwardDownloading); only a stall on OUR chunk
        // warrants a reconnect.
        guard currentChunkIndex == chunkIndex else { return }

        let idle = saminNow() - lastByteUptime
        let threshold: TimeInterval = receivedBytesInCurrentTask ? 15.0 : 25.0
        if idle >= threshold {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: Client waiting on chunk \(chunkIndex) and idle \(String(format: "%.1f", idle))s -> reconnecting continuous stream")
            reconnect(reason: "client waiting & idle")
        }
    }

    private func reconnect(reason: String) {
        guard !isCancelled, !isFinished, session.valid else { return }
        guard !session.isRateLimited else { return } // backoff timer owns the retry
        let now = saminNow()
        // Prevent reconnect storms: enforce at least 6s cooldown between reconnects
        guard now - lastReconnectUptime >= 6.0 else { return }
        lastReconnectUptime = now

        session.forwardReconnects += 1
        LocalCacheProxyLog.shared.log("FD [\(startByte)]: Reconnecting from \(streamOffset) (reason: \(reason))...")
        task?.cancel()
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        receivedBytesInCurrentTask = false
        cleanupFileHandle()
        if currentChunkIndex >= 0 {
            session.releaseChunkWrite(chunkIndex: currentChunkIndex, owner: "forward")
            currentChunkIndex = -1
        }
        startStream(from: streamOffset)
    }

    /// Re-opens the stream past a run of cached chunks starting at [offset].
    /// startStream() advances over the whole cached run itself.
    private func skipCachedRun(from offset: Int64) {
        guard !isCancelled, !isFinished, session.valid else { return }
        LocalCacheProxyLog.shared.log("FD [\(startByte)]: Chunk \(offset / saminProxyChunkBytes) already cached -> skipping cached run")
        task?.cancel()
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        receivedBytesInCurrentTask = false
        cleanupFileHandle()
        if currentChunkIndex >= 0 {
            session.releaseChunkWrite(chunkIndex: currentChunkIndex, owner: "forward")
            currentChunkIndex = -1
        }
        streamOffset = offset
        startStream(from: offset)
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
        guard !session.isRateLimited else { return } // backoff timer owns the retry
        let now = saminNow()
        let idle = now - lastByteUptime

        let clientIsWaiting = session.activeConnections.values.contains { $0.isWaitingForData }
        let threshold: TimeInterval
        if !receivedBytesInCurrentTask {
            // Handshake / TLS / TTFB phase: allow time for remote worker/origin to deliver first byte
            threshold = 25.0
        } else if clientIsWaiting {
            // Active playback waiting: allow TCP packet jitter and CDN buffer flushes to recover
            // without resetting TCP CWND, while still recovering if the socket actually died.
            threshold = 15.0
        } else {
            // Prefetching ahead of playhead: match request timeout
            threshold = 30.0
        }

        if idle >= threshold {
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: Watchdog stall (idle=\(String(format: "%.1f", idle))s, clientWaiting=\(clientIsWaiting), receivedBytes=\(receivedBytesInCurrentTask)). Reconnecting from \(streamOffset)...")
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
            self.session.lastUpstreamStatus = code
            if let ar = http.value(forHTTPHeaderField: "Accept-Ranges") {
                self.session.upstreamAcceptRanges = ar
            }
            if code == 206 || code == 200 {
                self.session.clearRateLimit()
                var lowered: [String: String] = [:]
                http.allHeaderFields.forEach { k, v in
                    if let ks = k as? String, let vs = v as? String {
                        lowered[ks.lowercased()] = vs
                    }
                }
                if self.session.contentType == nil, let type = lowered["content-type"] {
                    self.session.contentType = type
                }
                // Only used when the HEAD probe never produced a size (common on
                // debrid/CDN links) — without this, clients parked in headWaiters
                // would never be woken and the player would hang on first load.
                var discoveredSize: Int64?
                if self.session.totalSize == nil || self.session.totalSize == 0 {
                    if let cr = lowered["content-range"], let total = ProxyConnectionTotal.parse(cr) {
                        discoveredSize = total
                        LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Discovered totalSize=\(total) from Content-Range")
                    } else if let cl = lowered["content-length"], let len = Int64(cl), len > 0 {
                        // HTTP 200 means the body really starts at byte 0, so
                        // Content-Length is the whole file. Only a 206 body starts at
                        // streamOffset. Adding the offset on a 200 inflates totalSize
                        // and skews every cached range drawn on the timeline.
                        discoveredSize = (code == 200) ? len : self.streamOffset + len
                        LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Discovered totalSize=\(discoveredSize ?? 0) from Content-Length (HTTP \(code))")
                    }
                }
                if let discoveredSize {
                    self.session.totalSize = discoveredSize
                    self.session.maybeBuildMediaIndex()
                }

                if code == 200 && self.streamOffset > 0 {
                    LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Server returned HTTP 200 (ignored Range). Resetting offset to 0.")
                    self.streamOffset = 0
                }

                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: HTTP \(code) for continuous stream from \(self.streamOffset)")
                completionHandler(.allow)
                // Wake parked clients only after this task is allowed to run, so the
                // pump can't cancel the downloader from inside its own callback.
                if discoveredSize != nil {
                    self.session.notifyHeadersAvailable()
                }
            } else if code == 429 || code == 503 {
                // Upstream is throttling us (typical for Cloudflare Worker
                // stream proxies on long sessions). Reconnecting immediately
                // just extends the ban: back off, park the clients, and let a
                // single timer resume the stream.
                let retryHeader = ProxyRetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After"))
                let backoff: TimeInterval
                if let retryHeader {
                    backoff = min(max(retryHeader, 5), 300)
                } else {
                    backoff = min(15 * pow(2.0, Double(min(self.session.consecutiveRateLimits, 4))), 300)
                }
                self.session.noteRateLimit(retryAfter: backoff)
                self.lastErrorMessage = "rate limited (HTTP \(code)), retrying in \(Int(backoff))s"
                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Upstream rate limit HTTP \(code). Backing off \(Int(backoff))s (consecutive=\(self.session.consecutiveRateLimits)). No reconnects until backoff expires.")
                self.task = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.cleanupFileHandle()
                if self.currentChunkIndex >= 0 {
                    self.session.releaseChunkWrite(chunkIndex: self.currentChunkIndex, owner: "forward")
                    self.currentChunkIndex = -1
                }
                self.session.server.queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
                    guard let self, !self.isCancelled, !self.isFinished, self.session.valid else { return }
                    guard !self.session.isRateLimited else { return } // superseded by a newer backoff
                    if self.isFinished {
                        self.session.startBackwardDownloadIfNeeded()
                        return
                    }
                    LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: Rate-limit backoff expired, resuming from \(self.streamOffset)...")
                    self.startStream(from: self.streamOffset)
                }
                completionHandler(.cancel)
            } else {
                self.lastErrorMessage = "HTTP \(code)"
                LocalCacheProxyLog.shared.log("FD [\(self.startByte)]: HTTP error \(code)")
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled, !data.isEmpty else { return }
        self.session.server.queue.async { [weak self] in
            // Ignore bytes from a superseded request (reconnect / cached-run
            // skip): they belong to a different offset than streamOffset now.
            guard let self, !self.isCancelled, self.session.valid, dataTask === self.task else { return }
            self.processIncoming(data: data)
        }
    }

    private func processIncoming(data: Data) {
        session.recordBytesReceived(data.count)
        totalBytesReceived += Int64(data.count)
        lastByteUptime = saminNow()
        receivedBytesInCurrentTask = true

        var cursor = streamOffset
        var remaining = data

        while !remaining.isEmpty {
            let chunkIdx = cursor / saminProxyChunkBytes
            let chunkOffset = cursor % saminProxyChunkBytes

            // Entering a chunk that is already complete on disk: jump past the
            // cached run instead of truncating and re-downloading it.
            if chunkOffset == 0, session.cachedChunks.contains(chunkIdx) {
                skipCachedRun(from: cursor)
                return
            }

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
            guard session.makeRoomForChunk(excluding: chunkIndex) else {
                LocalCacheProxyLog.shared.log("FD [\(startByte)]: Low storage with no more watched chunks -> pausing forward download")
                pauseForLowSpace()
                return
            }
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
            let msg = "chunk \(chunkIndex): \(error.localizedDescription) (free=\(session.server.freeSpaceBytes() / 1024 / 1024) MB)"
            session.writeErrorCount += 1
            session.lastWriteError = msg
            lastErrorMessage = "write failed \(msg)"
            LocalCacheProxyLog.shared.log("FD [\(startByte)]: File write error on \(msg)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.session.server.queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }

            if let error {
                self.lastErrorMessage = error.localizedDescription
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
        receivedBytesInCurrentTask = false

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
           let fileSize = (attrs[.size] as? NSNumber)?.int64Value, fileSize > 0, fileSize <= expectedBytes {
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
        self.session.lastUpstreamStatus = http.statusCode
        if http.statusCode == 206 {
            completionHandler(.allow)
        } else {
            // A dedicated fetch needs an exact range. HTTP 200 means the server
            // ignored Range and is sending the whole file from byte 0, which we
            // cannot place into a mid-file chunk — fail it rather than write
            // wrong bytes; the forward stream handles such hosts.
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
    // Throttle for the hot-path wait log: the pump flips waiting->sending on
    // every ~1 KB socket slice while starved, which used to emit hundreds of
    // log lines per second and drown the report. At most one line per chunk
    // per interval; the report collapses the rest into a summary.
    private var lastWaitLogChunk: Int64 = -1
    private var lastWaitLogUptime: TimeInterval = 0
    private var waitLogCountForChunk: Int = 0

    // Pending parameters while waiting for initial HEAD/GET headers
    private var pendingStart: Int64 = 0
    private var pendingEnd: Int64?
    private var pendingRanged = false
    // Timer to fail parked clients if upstream never sends headers
    private var headersWaitTimer: DispatchSourceTimer?

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
        guard parts.count >= 3, parts[0] == "s",
              let session = server.session(for: parts[1]) else {
            respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        self.sessionKey = parts[1]
        session.attachConnection(self)

        // Samin: HLS sessions serve their own subpaths (rewritten playlist,
        // segments, keys, init maps). They never enter the byte-chunk machinery
        // below, which assumes one seekable upstream file.
        if session.kind == .hls {
            guard request.method == "GET" else {
                respondNow(status: 405, headers: [("Content-Length", "0")], body: nil)
                return
            }
            let subpath = parts[2...].joined(separator: "/")
            session.hls?.serve(subpath: subpath, connection: self)
            return
        }

        guard parts.count == 3, parts[2] == "file" else {
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

        let start = range?.start ?? 0
        let requestedEnd = range?.end

        session.clientRangeRequests += 1
        session.lastClientRange = request.headers["range"] ?? "full file"
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
        cancelHeadersWaitTimer()
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

    func startHeadersWaitTimer(timeout: TimeInterval = 15.0) {
        cancelHeadersWaitTimer()
        let timer = DispatchSource.makeTimerSource(queue: server.queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            LocalCacheProxyLog.shared.log("Client [\(sessionKey)]: Headers wait timed out after \(timeout)s -> failing")
            self.onDownloadFailed()
        }
        timer.resume()
        headersWaitTimer = timer
    }

    private func cancelHeadersWaitTimer() {
        headersWaitTimer?.cancel()
        headersWaitTimer = nil
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
            // Hold back until at least saminProxyMinResumeBytes are buffered ahead
            // (currently 0 to avoid 20 s seek stall; was 512 KB prebuffer lead),
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
            // Reached current downloaded boundary; wait for the downloaders.
            // Throttled: while starved this fires per ~1 KB socket slice, so
            // log at most one line per chunk per 2 s (event log only, never
            // the playback trace) and let the report collapse the rest.
            let now = saminNow()
            if chunkIdx != lastWaitLogChunk {
                lastWaitLogChunk = chunkIdx
                waitLogCountForChunk = 0
                lastWaitLogUptime = now
                LocalCacheProxyLog.shared.logEventOnly("Client [\(sessionKey)]: Waiting for data at chunk \(chunkIdx) (offset=\(streamOffset), available=\(available))")
            } else if !isWaitingForData || now - lastWaitLogUptime >= 2.0 {
                waitLogCountForChunk += 1
                lastWaitLogUptime = now
                LocalCacheProxyLog.shared.logEventOnly("Client [\(sessionKey)]: Still waiting at chunk \(chunkIdx) x\(waitLogCountForChunk) (offset=\(streamOffset), available=\(available))")
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
        // The byte-model HEAD makes no promise mpv can use on a playlist.
        if session.kind == .hls {
            respondNow(status: 200, headers: [("Content-Type", "application/vnd.apple.mpegurl"), ("Content-Length", "0"), ("Connection", "close")], body: nil)
            return
        }
        if session.kind == .passThrough {
            respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
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

    /// Samin: also used by the HLS segment layer to answer waiter connections
    /// with a complete one-shot response (no byte pump involved).
    fileprivate func respondNow(status: Int, headers: [(String, String)], body: Data?) {
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
        cancelHeadersWaitTimer()
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

/// Samin: what a proxy session serves.
enum ProxySessionKind {
    /// One seekable upstream file: 2 MB chunk disk cache (the original design).
    case progressive
    /// HLS playlist: segment-level disk cache with playlist rewriting.
    case hls
    /// Known-unsupported (e.g. DASH .mpd): endpoints respond 404 and playback
    /// is expected to use the direct URL instead.
    case passThrough
}

// MARK: - Samin HLS playlist model
//
// Dependency-free playlist parsing (no AVFoundation): handles media and
// master playlists, AES-128/SAMPLE-AES keys, EXT-X-MAP init sections and
// discontinuities. Everything the segment cache cannot faithfully rewrite
// (BYTERANGE addressing, live windows, unknown structure) is reported as
// unsupported so playback falls back to a redirect to the upstream playlist.

struct HLSMediaSegment {
    let url: URL
    let start: Double
    let duration: Double
    let disco: Int
}

struct HLSKey {
    let uri: URL
    let iv: String?
}

struct HLSPlaylist {
    let segments: [HLSMediaSegment]
    let keys: [Int: HLSKey]
    let maps: [Int: HLSKey]
    let totalDuration: Double
}

enum HLSPlaylistParser {
    static let maxSupportedVersion = 7

    enum ParseOutcome {
        case media(HLSPlaylist)
        case master(URL)
        case unsupported(String)
    }

    static func parse(_ text: String, base: URL) -> ParseOutcome {
        if text.contains("#EXT-X-BYTERANGE") {
            return .unsupported("EXT-X-BYTERANGE addressing")
        }
        var reader = LineScanner(text: text)
        var variants: [(uri: URL, bandwidth: Double)] = []
        var segments: [HLSMediaSegment] = []
        var keys: [Int: HLSKey] = [:]
        var maps: [Int: HLSKey] = [:]
        var activeKey: HLSKey?
        var activeMap: HLSKey?
        var pendingDuration: Double?
        var pendingDisco = 0
        var disco = 0
        var timeline = 0.0
        var sawHeader = false
        var sawEndlist = false

        while let raw = reader.next() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTM3U") {
                    sawHeader = true
                } else if line.hasPrefix("#EXT-X-ENDLIST") {
                    sawEndlist = true
                } else if line.hasPrefix("#EXT-X-VERSION:") {
                    let value = line.dropFirst("#EXT-X-VERSION:".count).trimmingCharacters(in: .whitespaces)
                    if let v = Int(value), v > maxSupportedVersion {
                        return .unsupported("protocol version \(v)")
                    }
                } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    let bandwidth = attribute(line, "BANDWIDTH").flatMap(Double.init) ?? 0
                    var uriLine = reader.next()
                    while let candidate = uriLine,
                          candidate.hasPrefix("#") || candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                        uriLine = reader.next()
                    }
                    guard let variantLine = uriLine,
                          let uri = URL(string: variantLine.trimmingCharacters(in: .whitespaces), relativeTo: base) else {
                        return .unsupported("malformed master playlist")
                    }
                    variants.append((uri, bandwidth))
                } else if line.hasPrefix("#EXTINF:") {
                    let value = line.dropFirst("#EXTINF:".count)
                    let head = value.split(separator: ",", maxSplits: 1).first ?? Substring("")
                    guard let seconds = Double(head.trimmingCharacters(in: .whitespaces)), seconds > 0 else {
                        return .unsupported("EXTINF without a duration")
                    }
                    pendingDuration = seconds
                } else if line == "#EXT-X-DISCONTINUITY" {
                    pendingDisco = disco
                    disco += 1
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    let method = attribute(line, "METHOD")?.uppercased()
                    if method == "NONE" {
                        activeKey = nil
                    } else if method == "AES-128" || method == "SAMPLE-AES" {
                        guard let uriString = attribute(line, "URI"),
                              let uri = URL(string: uriString, relativeTo: base) else {
                            return .unsupported("EXT-X-KEY without a URI")
                        }
                        activeKey = HLSKey(uri: uri, iv: attribute(line, "IV"))
                    } else if method != nil {
                        return .unsupported("EXT-X-KEY method \(method ?? "?")")
                    }
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    guard attribute(line, "BYTERANGE") == nil,
                          let uriString = attribute(line, "URI"),
                          let uri = URL(string: uriString, relativeTo: base) else {
                        return .unsupported("EXT-X-MAP with BYTERANGE or no URI")
                    }
                    activeMap = HLSKey(uri: uri, iv: attribute(line, "IV"))
                }
                continue
            }
            // A plain URI line: the pending segment when one is open.
            if let duration = pendingDuration, let url = URL(string: line, relativeTo: base) {
                let index = segments.count
                segments.append(HLSMediaSegment(url: url, start: timeline, duration: duration, disco: pendingDisco))
                if let key = activeKey { keys[index] = key }
                if let map = activeMap { maps[index] = map }
                timeline += duration
            }
            pendingDuration = nil
            pendingDisco = 0
        }

        if !variants.isEmpty {
            let best = variants.max { $0.bandwidth < $1.bandwidth } ?? variants[0]
            return .master(best.uri)
        }
        guard sawHeader, sawEndlist, !segments.isEmpty else {
            if sawHeader && !sawEndlist {
                return .unsupported("live playlist (no EXT-X-ENDLIST)")
            }
            return .unsupported("no recognizable segments")
        }
        return .media(HLSPlaylist(segments: segments, keys: keys, maps: maps, totalDuration: timeline))
    }

    static func attribute(_ line: String, _ name: String) -> String? {
        guard let range = line.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        var value = String(line[range.upperBound...])
        if value.hasPrefix("\"") {
            guard let end = value.dropFirst().firstIndex(of: "\"") else { return nil }
            value = String(value[value.index(after: value.startIndex)..<end])
        } else {
            value = String(value.prefix { $0 != "," })
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct LineScanner {
    private var lines: [Substring]
    private var index = 0

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    mutating func next() -> String? {
        guard index < lines.count else { return nil }
        defer { index += 1 }
        var line = String(lines[index])
        while line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}

// MARK: - Samin HLS segment cache engine

/// Per-session state for HLS (.m3u8) streams: fetches and parses the media
/// playlist, rewrites every segment/key/init URI to a loopback path backed by
/// the on-disk segment cache, prefetches segments ahead of the playhead, and
/// reports cached timeline spans in the same JSON shapes the progressive cache
/// uses (so the grey bar, badge and diagnostics work unchanged). Playlists it
/// cannot cache are answered with a redirect to the upstream playlist, which
/// keeps playback working exactly as before this layer existed.
final class HLSStreamState {
    private unowned let session: ProxySession

    private struct SegmentRef {
        let index: Int
        let url: URL
        let start: Double
        let duration: Double
        let disco: Int
    }

    // All state below is confined to session.server.queue.
    private var upstreamHeaders: [String: String]
    private var upstreamPlaylistUrl: URL?
    private var segments: [SegmentRef] = []
    private var keysBySegment: [Int: HLSKey] = [:]
    private var mapsBySegment: [Int: HLSKey] = [:]
    private var totalDuration: Double = 0
    private var cachedSegments: Set<Int> = []
    private var cachedBytesTotal: Int64 = 0
    private var activeFetches: [Int: String] = [:]
    private var segmentWaiters: [Int: [ProxyConnection]] = [:]
    private var smallWaiters: [(name: String, isMap: Bool, connection: ProxyConnection)] = []
    private var inFlightSmall: Set<String> = []
    private var playlistWaiters: [ProxyConnection] = []
    private var inFlightPlaylistFetch = false
    private var playlistFetchedOnce = false
    private var playheadSeconds: Double = 0
    private var passthroughReason: String?
    private var evictedSegments = 0
    private var lastPlaylistStatus: Int?
    private var lastPlaylistError: String?
    private var bestVariantUrl: URL?
    private var speedBytesAccumulator: Int64 = 0
    private var lastSpeedUpdateUptime: TimeInterval = saminNow()
    private var currentSpeedBps: Int64 = 0
    private var segmentWatchdog: DispatchSourceTimer?

    init(session: ProxySession) {
        self.session = session
        self.upstreamHeaders = HLSStreamState.headersWithDefaultReferer(session.headers, for: session.sourceUrl)
        self.upstreamPlaylistUrl = URL(string: session.sourceUrl)
        LocalCacheProxyLog.shared.log("HLS [\(session.key)]: segment-cache session created for \(URL(string: session.sourceUrl)?.host ?? "?")")
        ensurePlaylist()
    }

    func shutdown() {
        segmentWatchdog?.cancel()
        segmentWatchdog = nil
    }

    /// Hotlink-gated CDNs reject a request that carries no Referer at all: the
    /// HiAnime `hls.dramahot.top` family answers 403 for every Referer except
    /// its own origin (verified on a live episode: absent, a page referer, an
    /// unrelated subdomain and the loopback URL all 403; the playlist origin
    /// 200s for the playlist and for the segments). Extractors normally supply
    /// that header, and their value always wins here; when they do not, fall
    /// back to the playlist origin so our playlist/segment/key fetches are not
    /// rejected outright.
    private static func headersWithDefaultReferer(_ headers: [String: String], for sourceUrl: String) -> [String: String] {
        if headers.keys.contains(where: { $0.caseInsensitiveCompare("Referer") == .orderedSame }) {
            return headers
        }
        guard let url = URL(string: sourceUrl), let scheme = url.scheme, let host = url.host else {
            return headers
        }
        var out = headers
        out["Referer"] = "\(scheme)://\(host)/"
        return out
    }

    /// New upstream for the same session key (debrid re-resolve). Runs on the
    /// server queue; also gives a previously-unsupported playlist one more
    /// chance with the new URL before falling back to the redirect.
    func setUpstream(_ sourceUrl: String, _ headers: [String: String]) {
        session.server.queue.async { [weak self] in
            guard let self, self.session.valid else { return }
            self.upstreamHeaders = HLSStreamState.headersWithDefaultReferer(headers, for: sourceUrl)
            self.upstreamPlaylistUrl = URL(string: sourceUrl)
            self.playlistFetchedOnce = false
            self.bestVariantUrl = nil
            self.passthroughReason = nil
            self.ensurePlaylist(force: true)
        }
    }

    // MARK: Serving

    /// Entry point for every rewritten loopback request
    /// (/s/<key>/playlist.m3u8, /s/<key>/seg/<i>, /s/<key>/key/<i>,
    /// /s/<key>/map/<i>). Always called on the server queue.
    func serve(subpath: String, connection: ProxyConnection) {
        session.server.queue.async { [weak self] in
            guard let self, self.session.valid else {
                connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
                return
            }
            let parts = subpath.split(separator: "/").map(String.init)
            let first = parts.first ?? ""
            if first == "playlist" || first.hasPrefix("playlist.") {
                self.requestPlaylist(connection: connection)
            } else if first == "seg", parts.count == 2, let index = Int(parts[1]) {
                self.serveSegment(index: index, connection: connection)
            } else if first == "key", parts.count == 2, let index = Int(parts[1]) {
                self.serveKeyOrMap(index: index, isMap: false, connection: connection)
            } else if first == "map", parts.count == 2, let index = Int(parts[1]) {
                self.serveKeyOrMap(index: index, isMap: true, connection: connection)
            } else {
                connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            }
        }
    }

    private func requestPlaylist(connection: ProxyConnection) {
        if let reason = passthroughReason, let upstream = upstreamPlaylistUrl {
            LocalCacheProxyLog.shared.log("HLS [\(session.key)]: redirecting player to upstream playlist (segment cache inactive: \(reason))")
            connection.respondNow(status: 302, headers: [("Location", upstream.absoluteString), ("Content-Length", "0")], body: nil)
            return
        }
        if segments.isEmpty && passthroughReason == nil {
            // First request can beat the initial playlist fetch; park until it
            // resolves instead of failing the load.
            playlistWaiters.append(connection)
            ensurePlaylist { [weak self] in self?.flushPlaylistWaiters() }
            return
        }
        ensurePlaylist { [weak self] in self?.servePlaylist(connection: connection) }
    }

    private func flushPlaylistWaiters() {
        let waiters = playlistWaiters
        playlistWaiters.removeAll()
        for connection in waiters {
            servePlaylist(connection: connection)
        }
    }

    private func servePlaylist(connection: ProxyConnection) {
        if passthroughReason != nil {
            if let upstream = upstreamPlaylistUrl {
                connection.respondNow(status: 302, headers: [("Location", upstream.absoluteString), ("Content-Length", "0")], body: nil)
            } else {
                connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            }
            return
        }
        guard !segments.isEmpty else {
            connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        let port = session.server.port
        let maxDuration = segments.map { $0.duration }.max() ?? 0.0
        var text = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        text += "#EXT-X-TARGETDURATION:\(Int(ceil(maxDuration)))\n"
        text += "#EXT-X-MEDIA-SEQUENCE:0\n"
        var emittedMap = false
        var emittedKey = false
        var lastKeyUri: String? = nil
        for seg in segments {
            let eraStart = seg.index == 0 || segments[seg.index - 1].disco != seg.disco
            if eraStart && seg.disco > 0 {
                text += "#EXT-X-DISCONTINUITY\n"
                emittedMap = false
                emittedKey = false
                lastKeyUri = nil
            }
            let currentKey = keysBySegment[seg.index]
            let currentKeyUri = currentKey?.uri.absoluteString
            if !emittedKey || currentKeyUri != lastKeyUri {
                if let key = currentKey {
                    text += "#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:\(port)/s/\(session.key)/key/\(seg.index)\""
                    if let iv = key.iv { text += ",IV=\(iv)" }
                    text += "\n"
                } else {
                    text += "#EXT-X-KEY:METHOD=NONE\n"
                }
                emittedKey = true
                lastKeyUri = currentKeyUri
            }
            if let _ = mapsBySegment[seg.index], !emittedMap {
                text += "#EXT-X-MAP:URI=\"http://127.0.0.1:\(port)/s/\(session.key)/map/\(seg.index)\"\n"
                emittedMap = true
            }
            text += "#EXTINF:\(String(format: "%.3f", seg.duration)),\n"
            text += "http://127.0.0.1:\(port)/s/\(session.key)/seg/\(seg.index)\n"
        }
        text += "#EXT-X-ENDLIST\n"
        connection.respondNow(
            status: 200,
            headers: [
                ("Content-Type", "application/vnd.apple.mpegurl"),
                ("Content-Length", "\(text.utf8.count)"),
                ("Cache-Control", "no-store"),
                ("Connection", "close"),
            ],
            body: Data(text.utf8)
        )
        LocalCacheProxyLog.shared.log("HLS [\(session.key)]: served rewritten playlist (\(segments.count) segments, \(String(format: "%.0f", totalDuration))s)")
    }

    private func serveSegment(index: Int, connection: ProxyConnection) {
        guard index >= 0, index < segments.count else {
            connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        if cachedSegments.contains(index) {
            serveSegmentFromDisk(index: index, connection: connection)
            return
        }
        if passthroughReason != nil {
            connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        // Park the connection; the fetch (or the watchdog) resolves it.
        segmentWaiters[index, default: []].append(connection)
        scheduleSegmentWatchdogIfNeeded()
        let behind = index - currentSegmentIndex()
        ensureSegmentFetch(index: index, reason: behind <= 0 ? "playback" : "prefetch+\(behind)")
    }

    private func serveSegmentFromDisk(index: Int, connection: ProxyConnection) {
        let url = session.dir.appendingPathComponent("seg_\(index).bin")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            cachedSegments.remove(index)
            connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        connection.respondNow(
            status: 200,
            headers: [
                ("Content-Type", "application/octet-stream"),
                ("Content-Length", "\(data.count)"),
                ("Connection", "close"),
            ],
            body: data
        )
    }

    // MARK: Fetches

    private func ensureSegmentFetch(index: Int, reason: String) {
        guard passthroughReason == nil else { return }
        guard index >= 0, index < segments.count else { return }
        if cachedSegments.contains(index) { return }
        if activeFetches[index] != nil { return }
        guard activeFetches.count < saminHlsSegmentFetchers else { return }
        activeFetches[index] = reason
        let seg = segments[index]
        let request = Self.makeRequest(url: seg.url, headers: upstreamHeaders)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = (error == nil && status == 200) ? data : nil
            self?.session.server.queue.async { [weak self] in
                guard let self, self.session.valid else { return }
                self.activeFetches.removeValue(forKey: index)
                if let payload, !payload.isEmpty {
                    do {
                        try payload.write(to: self.session.dir.appendingPathComponent("seg_\(index).bin"), options: .atomic)
                        self.cachedSegments.insert(index)
                        self.cachedBytesTotal += Int64(payload.count)
                        self.recordBytes(Int64(payload.count))
                        self.resolveSegmentWaiters(index: index, success: true)
                        self.prefetchAhead()
                    } catch {
                        LocalCacheProxyLog.shared.log("HLS [\(self.session.key)]: segment \(index) write failed: \(error.localizedDescription)")
                        self.resolveSegmentWaiters(index: index, success: false)
                    }
                } else {
                    LocalCacheProxyLog.shared.log("HLS [\(self.session.key)]: segment \(index) fetch failed (HTTP \(status)) \(error?.localizedDescription ?? "")")
                    self.resolveSegmentWaiters(index: index, success: false)
                }
            }
        }.resume()
        LocalCacheProxyLog.shared.log("HLS [\(session.key)]: fetching segment \(index) (\(reason), pool=\(activeFetches.count))")
    }

    private func resolveSegmentWaiters(index: Int, success: Bool) {
        let waiters = segmentWaiters.removeValue(forKey: index) ?? []
        for connection in waiters {
            if success {
                serveSegmentFromDisk(index: index, connection: connection)
            } else {
                connection.respondNow(status: 502, headers: [("Content-Length", "0")], body: nil)
            }
        }
    }

    /// Re-kicks fetches for parked connections so a transient failure or a
    /// fetch that died while suspended cannot strand playback.
    private func scheduleSegmentWatchdogIfNeeded() {
        guard segmentWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: session.server.queue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.session.valid else { return }
            for index in self.segmentWaiters.keys.sorted() where !(self.segmentWaiters[index]?.isEmpty ?? true) {
                if self.cachedSegments.contains(index) {
                    self.resolveSegmentWaiters(index: index, success: true)
                } else if self.activeFetches[index] == nil, self.passthroughReason == nil {
                    self.ensureSegmentFetch(index: index, reason: "waiter retry")
                }
            }
        }
        timer.resume()
        segmentWatchdog = timer
    }

    private func serveKeyOrMap(index: Int, isMap: Bool, connection: ProxyConnection) {
        guard let upstream = isMap ? mapsBySegment[index]?.uri : keysBySegment[index]?.uri else {
            connection.respondNow(status: 404, headers: [("Content-Length", "0")], body: nil)
            return
        }
        let name = isMap ? "map_\(index).bin" : "key_\(index).bin"
        let fileUrl = session.dir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: fileUrl), !data.isEmpty {
            connection.respondNow(status: 200, headers: [("Content-Type", isMap ? "video/mp4" : "application/octet-stream"), ("Content-Length", "\(data.count)"), ("Connection", "close")], body: data)
            return
        }
        smallWaiters.append((name, isMap, connection))
        ensureSmallResource(name: name, upstream: upstream, isMap: isMap)
    }

    private func ensureSmallResource(name: String, upstream: URL, isMap: Bool) {
        guard !inFlightSmall.contains(name) else { return }
        inFlightSmall.insert(name)
        let request = Self.makeRequest(url: upstream, headers: upstreamHeaders)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = (error == nil && status == 200) ? data : nil
            self?.session.server.queue.async { [weak self] in
                guard let self, self.session.valid else { return }
                self.inFlightSmall.remove(name)
                let waiters = self.smallWaiters.filter { $0.name == name }
                self.smallWaiters.removeAll { $0.name == name }
                if let payload, !payload.isEmpty {
                    try? payload.write(to: self.session.dir.appendingPathComponent(name), options: .atomic)
                    self.cachedBytesTotal += Int64(payload.count)
                    self.recordBytes(Int64(payload.count))
                    for waiter in waiters {
                        waiter.connection.respondNow(status: 200, headers: [("Content-Type", isMap ? "video/mp4" : "application/octet-stream"), ("Content-Length", "\(payload.count)"), ("Connection", "close")], body: payload)
                    }
                    LocalCacheProxyLog.shared.log("HLS [\(self.session.key)]: cached \(isMap ? "map" : "key") \(name) (\(payload.count) B, waiters=\(waiters.count))")
                } else {
                    LocalCacheProxyLog.shared.log("HLS [\(self.session.key)]: \(isMap ? "map" : "key") \(name) fetch failed (HTTP \(status)) \(error?.localizedDescription ?? "")")
                    for waiter in waiters {
                        waiter.connection.respondNow(status: 502, headers: [("Content-Length", "0")], body: nil)
                    }
                }
            }
        }.resume()
    }

    // MARK: Playlist fetch / parse

    private func ensurePlaylist(force: Bool = false, completion: (() -> Void)? = nil) {
        if passthroughReason != nil {
            completion?()
            return
        }
        if !force && playlistFetchedOnce {
            completion?()
            return
        }
        if inFlightPlaylistFetch {
            completion?()
            return
        }
        guard let base = upstreamPlaylistUrl else {
            completion?()
            return
        }
        inFlightPlaylistFetch = true
        var request = Self.makeRequest(url: base, headers: upstreamHeaders)
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = (error == nil && status == 200) ? data : nil
            let errText = error?.localizedDescription
            self?.session.server.queue.async { [weak self] in
                guard let self, self.session.valid else { return }
                self.inFlightPlaylistFetch = false
                self.playlistFetchedOnce = true
                self.lastPlaylistStatus = status
                self.lastPlaylistError = errText
                guard let payload, !payload.isEmpty, payload.count <= saminHlsMaxPlaylistBytes else {
                    // A failed playlist fetch would park playback on /playlist
                    // forever. Degrade like an unsupported playlist instead:
                    // waiters get a 302 to the upstream playlist, which is
                    // exactly pre-feature behavior (mpv still buffers via its
                    // own demuxer cache on the direct URL).
                    LocalCacheProxyLog.shared.log("HLS [\(self.session.key)]: playlist fetch failed (HTTP \(status)); falling back to upstream redirect \(errText ?? "")")
                    self.enterPassthrough("playlist fetch failed (HTTP \(status))")
                    completion?()
                    return
                }
                self.applyPlaylistData(payload, base: base, completion: completion)
            }
        }.resume()
    }

    private func applyPlaylistData(_ data: Data, base: URL, completion: (() -> Void)? = nil) {
        guard let text = String(data: data, encoding: .utf8) else {
            enterPassthrough("playlist is not UTF-8 text")
            completion?()
            return
        }
        switch HLSPlaylistParser.parse(text, base: base) {
        case .media(let playlist):
            var refs: [SegmentRef] = []
            refs.reserveCapacity(playlist.segments.count)
            for (i, seg) in playlist.segments.enumerated() {
                refs.append(SegmentRef(index: i, url: seg.url, start: seg.start, duration: seg.duration, disco: seg.disco))
            }
            segments = refs
            keysBySegment = playlist.keys
            mapsBySegment = playlist.maps
            totalDuration = playlist.totalDuration
            cachedSegments = cachedSegments.intersection(Set(refs.indices))
            LocalCacheProxyLog.shared.log("HLS [\(session.key)]: parsed media playlist (\(refs.count) segments, \(String(format: "%.0f", totalDuration))s, keys=\(playlist.keys.count), maps=\(playlist.maps.count))")
            prefetchAhead()
            completion?()
        case .master(let variantUrl):
            guard bestVariantUrl != variantUrl else {
                enterPassthrough("master playlist does not lead to a media playlist")
                completion?()
                return
            }
            bestVariantUrl = variantUrl
            upstreamPlaylistUrl = variantUrl
            LocalCacheProxyLog.shared.log("HLS [\(session.key)]: master playlist -> chasing variant \(variantUrl.lastPathComponent)")
            // Defer the completion until the chased variant resolves. Flushing parked
            // /playlist waiters here (while segments is still empty for a master) would
            // hit servePlaylist's empty-segments guard and return an empty 404, which mpv
            // reports as "Failed to open .../playlist".
            ensurePlaylist(force: true, completion: completion)
        case .unsupported(let why):
            enterPassthrough(why)
            completion?()
        }
    }

    private func enterPassthrough(_ why: String) {
        guard passthroughReason == nil else { return }
        passthroughReason = why
        segments = []
        keysBySegment = [:]
        mapsBySegment = [:]
        LocalCacheProxyLog.shared.log("HLS [\(session.key)]: segment cache inactive (\(why)) - playlist requests redirect to upstream")
        flushPlaylistWaiters()
    }

    // MARK: Playhead + prefetch

    func playheadUpdated() {
        guard passthroughReason == nil, !segments.isEmpty, totalDuration > 0 else { return }
        guard let (posMs, durMs) = session.playheadMs, durMs > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(posMs) / Double(durMs)))
        playheadSeconds = fraction * totalDuration
        prefetchAhead()
    }

    private func currentSegmentIndex() -> Int {
        guard !segments.isEmpty else { return 0 }
        for seg in segments where playheadSeconds < seg.start + seg.duration {
            return seg.index
        }
        return segments[segments.count - 1].index
    }

    private func prefetchAhead() {
        guard passthroughReason == nil, !segments.isEmpty else { return }
        let current = currentSegmentIndex()
        evictWatchedIfNeeded(current: current)
        let last = min(segments.count - 1, current + saminHlsPrefetchSegments)
        for index in current...last {
            ensureSegmentFetch(index: index, reason: index == current ? "playhead" : "prefetch+\(index - current)")
        }
    }

    /// Only watched segments well behind the playhead are evicted, and only
    /// under the same low-space threshold the progressive cache uses.
    private func evictWatchedIfNeeded(current: Int) {
        guard session.server.freeSpaceBytes() < saminProxyLowSpaceBytes else { return }
        let keepBehind = 6
        for seg in segments where seg.index < current - keepBehind {
            guard cachedSegments.contains(seg.index) else { continue }
            let url = session.dir.appendingPathComponent("seg_\(seg.index).bin")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                cachedBytesTotal = max(0, cachedBytesTotal - size)
            }
            try? FileManager.default.removeItem(at: url)
            cachedSegments.remove(seg.index)
            evictedSegments += 1
        }
    }

    // MARK: Reporting

    func cachedTimeRangesJson() -> String {
        guard passthroughReason == nil, !segments.isEmpty, totalDuration > 0 else { return "[]" }
        var spans: [(Double, Double)] = []
        for seg in segments where cachedSegments.contains(seg.index) {
            let s = min(1.0, max(0.0, seg.start / totalDuration))
            let e = min(1.0, max(0.0, (seg.start + seg.duration) / totalDuration))
            if e > s { spans.append((s, e)) }
        }
        guard !spans.isEmpty else { return "[]" }
        spans.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for span in spans {
            if let last = merged.last, last.1 >= span.0 - 0.0005 {
                merged[merged.count - 1] = (last.0, max(last.1, span.1))
            } else {
                merged.append(span)
            }
        }
        let parts = merged.prefix(32).map { "[\($0.0),\($0.1)]" }
        return "[\(parts.joined(separator: ","))]"
    }

    func statsJson() -> String {
        let total = segments.count
        let cached = cachedSegments.count
        let complete = passthroughReason == nil && total > 0 && cached >= total
        let ranges = cachedTimeRangesJson()
        return "{\"speedBps\":\(currentSpeedBps),\"cachedBytes\":\(cachedBytesTotal),\"totalBytes\":0,\"isComplete\":\(complete),\"ranges\":\(ranges)}"
    }

    func diagnosticLines() -> [String] {
        var lines: [String] = []
        let host = upstreamPlaylistUrl?.host ?? "unknown"
        let status = lastPlaylistStatus.map(String.init) ?? "none"
        lines.append("HLS playlist: \(host) (HTTP \(status))\(lastPlaylistError.map { " \($0)" } ?? "")")
        if let reason = passthroughReason {
            lines.append("HLS caching INACTIVE - pass-through redirect: \(reason)")
            return lines
        }
        lines.append("HLS segments: \(cachedSegments.count)/\(segments.count) cached, \(String(format: "%.0f", totalDuration))s total, \(cachedBytesTotal / 1024 / 1024) MB on disk, evicted=\(evictedSegments)")
        if !activeFetches.isEmpty {
            let keys = activeFetches.keys.sorted().map(String.init).joined(separator: ",")
            lines.append("HLS fetches in flight: \(activeFetches.count) (segments \(keys))")
        } else {
            lines.append("HLS fetches in flight: 0")
        }
        let parkedCount = segmentWaiters.values.reduce(0) { $0 + $1.count }
        lines.append("HLS playhead: segment \(currentSegmentIndex()) (\(String(format: "%.0f", playheadSeconds))s), parked: segments=\(parkedCount), playlist=\(playlistWaiters.count), small=\(smallWaiters.count)")
        if let variant = bestVariantUrl {
            lines.append("HLS master variant: \(variant.lastPathComponent)")
        }
        return lines
    }

    // MARK: Helpers

    private func recordBytes(_ count: Int64) {
        let now = saminNow()
        speedBytesAccumulator += count
        let elapsed = now - lastSpeedUpdateUptime
        if elapsed >= 0.5 {
            currentSpeedBps = Int64(Double(speedBytesAccumulator) / elapsed)
            speedBytesAccumulator = 0
            lastSpeedUpdateUptime = now
        }
    }

    private static func makeRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

enum ProxyRetryAfter {
    /// Parses a Retry-After header: delta-seconds or an HTTP-date.
    static func parse(_ header: String?) -> TimeInterval? {
        guard let h = header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if let secs = Double(h), secs >= 0 {
            return secs
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: h) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
