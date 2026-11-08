import Foundation

extension ClaudeHookSurfaceResolutionSwiftTests {
    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private let notifications = AgentHookTestNotificationPipeline()
        private var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(contentsOf: [command] + notifications.effects(for: command))
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }
    }
}
