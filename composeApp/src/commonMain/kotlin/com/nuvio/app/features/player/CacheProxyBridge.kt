package com.nuvio.app.features.player

/**
 * Bridge to the platform-local playback cache proxy (iOS only for now).
 *
 * The platform runs a loopback HTTP server. [startSession] registers an
 * upstream URL and returns a localhost URL for the player to load instead
 * of the remote URL. The server fetches upstream on demand, caches bytes
 * to the app Caches directory, serves cached bytes from disk (instant
 * replays, offline survival inside cached ranges), evicts watched data
 * first under storage pressure, and drops everything when [stopSession]
 * runs on player close.
 *
 * Swift implements this and registers a factory at app startup (same
 * pattern as NuvioPlayerBridge). Other platforms have no implementation:
 * [NuvioCacheProxyBridgeFactory.create] returns null there and playback
 * transparently uses the remote URL plus the legacy background mirror.
 */
interface NuvioCacheProxyBridge {
    fun startSession(sessionKey: String, sourceUrl: String, headersJson: String?): String
    fun stopSession(sessionKey: String)
    fun stopAllSessions()
    fun setPlayhead(sessionKey: String, positionMs: Long, durationMs: Long)
    fun cachedRangesJson(sessionKey: String): String
    fun cacheStatsJson(sessionKey: String): String = "{}"
}

object NuvioCacheProxyBridgeFactory {
    private var factoryRef: NuvioCacheProxyBridgeCreator? = null

    fun registerFactory(creator: NuvioCacheProxyBridgeCreator) {
        this.factoryRef = creator
    }

    fun create(): NuvioCacheProxyBridge? = factoryRef?.createBridge()

    val isRegistered: Boolean get() = factoryRef != null
}

interface NuvioCacheProxyBridgeCreator {
    fun createBridge(): NuvioCacheProxyBridge
}
