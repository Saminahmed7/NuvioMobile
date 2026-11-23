import SwiftUI
import ComposeApp

@main
struct iOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationLockAppDelegate.self) private var appDelegate

    init() {
        // Register proxy and player bridges before any Kotlin code runs
        NuvioCacheProxyRegistration.register()
        NuvioPlayerRegistration.register()

        // Clear all orphaned cache chunks from crashed or terminated sessions
        LocalCacheProxyServer.shared.stopAllSessions()
        TempPlaybackCache.shared.sweepOnColdStart()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    AppUrlBridgeKt.handleAppUrl(url: url.absoluteString)
                }
        }
    }
}
