import XCTest
import Foundation

extension CLINotifyProcessIntegrationRegressionTests {
    struct DrainedProcessOutput {
        let stdout: String
        let stderr: String
    }

    final class ProcessOutputDrainer: @unchecked Sendable {
        private final class Buffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func set(_ data: Data) {
                lock.lock()
                self.data = data
                lock.unlock()
            }

            func stringValue() -> String {
                lock.lock()
                let value = data
                lock.unlock()
                return String(data: value, encoding: .utf8) ?? ""
            }
        }

        private let stdoutBuffer = Buffer()
        private let stderrBuffer = Buffer()
        private let stdoutRead = DispatchSemaphore(value: 0)
        private let stderrRead = DispatchSemaphore(value: 0)

        init(stdoutPipe: Pipe, stderrPipe: Pipe) {
            DispatchQueue.global(qos: .userInitiated).async {
                self.stdoutBuffer.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                self.stdoutRead.signal()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.stderrBuffer.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                self.stderrRead.signal()
            }
        }

        func output(timeout: TimeInterval) -> DrainedProcessOutput {
            _ = stdoutRead.wait(timeout: .now() + timeout)
            _ = stderrRead.wait(timeout: .now() + timeout)
            return DrainedProcessOutput(stdout: stdoutBuffer.stringValue(), stderr: stderrBuffer.stringValue())
        }
    }

    func assertSSHPTYAttachUsesComposedSessionID(
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(script.contains("--session-id \"$cmux_ssh_pty_session_id\""), script, file: file, line: line)
        XCTAssertTrue(script.contains("--attachment-id \"$cmux_ssh_pty_surface_id\""), script, file: file, line: line)
        XCTAssertFalse(script.contains("--session-id \"$cmux_ssh_pty_surface_id\""), script, file: file, line: line)
    }
}
