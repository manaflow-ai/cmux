import Darwin
import Foundation
import XCTest

final class CMUXOpenCommandTests: XCTestCase {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    final class AsyncValueBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            let value = self.value
            lock.unlock()
            return value
        }
    }

}
