import Foundation

extension CLINotifyProcessIntegrationRegressionTests {
    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private let notifications = AgentHookTestNotificationPipeline()
        private(set) var commands: [String] = []
        private var commandTimestamps: [TimeInterval] = []

        func append(_ command: String) {
            lock.lock()
            let entries = [command] + notifications.effects(for: command)
            commands.append(contentsOf: entries)
            commandTimestamps.append(contentsOf: entries.map { _ in ProcessInfo.processInfo.systemUptime })
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = commands
            lock.unlock()
            return value
        }

        func timestampedSnapshot() -> [(command: String, timestamp: TimeInterval)] {
            lock.lock()
            let value = zip(commands, commandTimestamps).map {
                (command: $0.0, timestamp: $0.1)
            }
            lock.unlock()
            return value
        }
    }
}
