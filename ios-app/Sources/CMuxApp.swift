import SwiftUI
import Sentry

@main
struct CMuxApp: App {
    init() {
        SentrySDK.start { options in
            options.dsn = "https://834d19a3077c4adbff534dca1e93de4f@o4507547940749312.ingest.us.sentry.io/4510604800491520"
            options.debug = false

            #if DEBUG
            options.environment = "development"
            #elseif BETA
            options.environment = "beta"
            #else
            options.environment = "production"
            #endif

            options.enableTracing = true
            options.tracesSampleRate = 1.0
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
