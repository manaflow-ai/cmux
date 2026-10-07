import UIKit

/// Runs one piece of work under `UIApplication.beginBackgroundTask`, so a
/// banner action keeps running after iOS would suspend the app. When the
/// budget runs out the work is cancelled and the task ends at once (iOS
/// kills an app that overstays it).
@MainActor
public struct BackgroundTaskBudget {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public func run<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value {
        let task = Task { await work() }
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            task.cancel()
            MainActor.assumeIsolated { token.end() }
        }
        let value = await task.value
        token.end()
        return value
    }
}

/// Ends a background task exactly once (expiry and completion can race).
@MainActor
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
