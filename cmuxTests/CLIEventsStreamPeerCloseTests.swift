import XCTest
import Darwin
import Foundation

/// #12756: macOS rejects SO_RCVTIMEO with EINVAL once the peer has closed the
/// socket. `cmux events` must still deliver the frames that arrived before
/// the close instead of exiting with "Failed to configure socket receive
/// timeout (Invalid argument, errno 22)".
final class CLIEventsStreamPeerCloseTests: XCTestCase {
    func testEventsDeliversFramesBufferedBeforePeerClose() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        let socketPath = makeCodexHookSocketPath("events-close")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let served = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { served.signal() }
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Answer a password handshake if the runner has one configured,
            // then wait for the events.stream request line.
            while true {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    guard line.hasPrefix("auth ") else { break }
                    _ = "OK\n".withCString { Darwin.write(clientFD, $0, strlen($0)) }
                    continue
                }
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                pending.append(buffer, count: count)
            }
            // Replay a backlog, then close right away, like a server that
            // ends the connection after handing off to live streaming.
            let frames = [
                #"{"type":"ack","latest_seq":2}"#,
                #"{"type":"event","seq":1,"name":"test.one"}"#,
                #"{"type":"event","seq":2,"name":"test.two"}"#,
            ].joined(separator: "\n") + "\n"
            _ = frames.withCString { Darwin.write(clientFD, $0, strlen($0)) }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = CLINotifyProcessIntegrationRegressionTests.runProcess(
            executablePath: cliPath,
            arguments: ["events", "--no-ack", "--no-heartbeats", "--limit", "2"],
            environment: environment,
            timeout: 10
        )
        XCTAssertEqual(served.wait(timeout: .now() + 5), .success)

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stderr.contains("receive timeout"), result.stderr)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, result.stdout)
        XCTAssertTrue(lines.first?.contains("test.one") == true, result.stdout)
        XCTAssertTrue(lines.last?.contains("test.two") == true, result.stdout)
    }
}
