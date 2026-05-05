import XCTest
import AppKit
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalControllerDetachedSocketClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testCmuxOnlyRejectsDetachedExternalClient() throws {
        let socketPath = makeSocketPath("cmux-detached")
        let tabManager = TabManager()

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .cmuxOnly
        )
        try waitForSocket(at: socketPath)

        let result = try runDetachedExternalPing(to: socketPath)
        XCTAssertNotEqual(result.response, "PONG")
        XCTAssertTrue(
            result.response.isEmpty ||
                result.response.localizedCaseInsensitiveContains("access denied") ||
                result.response.localizedCaseInsensitiveContains("error"),
            "Expected detached external client to be rejected in cmuxOnly mode, got: \(result.response)"
        )
    }

    func testDefaultSocketModeAllowsDetachedExternalClient() throws {
        let socketPath = makeSocketPath("default-detached")
        let tabManager = TabManager()

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: SocketControlSettings.defaultMode
        )
        try waitForSocket(at: socketPath)

        let result = try runDetachedExternalPing(to: socketPath)
        XCTAssertEqual(
            result.response,
            "PONG",
            "Expected detached external client to succeed with the default socket mode, exit=\(result.exitCode), output=\(result.response)"
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdet-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private func runDetachedExternalPing(
        to socketPath: String,
        timeout: TimeInterval = 5.0
    ) throws -> (response: String, exitCode: Int32) {
        let fileManager = FileManager.default
        let nohupPath = "/usr/bin/nohup"
        let netcatPath = "/usr/bin/nc"

        guard fileManager.isExecutableFile(atPath: nohupPath) else {
            throw XCTSkip("Detached-client test requires \(nohupPath)")
        }
        guard fileManager.isExecutableFile(atPath: netcatPath) else {
            throw XCTSkip("Detached-client test requires \(netcatPath)")
        }

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-detached-client-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let scriptURL = tempRoot.appendingPathComponent("launch-detached.sh", isDirectory: false)
        let outputURL = tempRoot.appendingPathComponent("output.txt", isDirectory: false)
        let statusURL = tempRoot.appendingPathComponent("status.txt", isDirectory: false)

        let script = """
        #!/bin/sh
        set -eu

        SOCKET_PATH="$1"
        OUTPUT_PATH="$2"
        STATUS_PATH="$3"

        "\(nohupPath)" /bin/sh -c '
          sleep 0.5
          printf "ping\\n" | "\(netcatPath)" -U "$1" > "$2" 2>&1
          printf "%s\\n" "$?" > "$3"
        ' _ "$SOCKET_PATH" "$OUTPUT_PATH" "$STATUS_PATH" >/dev/null 2>&1 &
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = scriptURL
        process.arguments = [socketPath, outputURL.path, statusURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Detached launcher failed")

        try waitForFile(at: statusURL, timeout: timeout)

        let exitCodeString = try String(contentsOf: statusURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return (
            response: output.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: Int32(exitCodeString) ?? -1
        )
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: url.path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
        }
        XCTFail("Timed out waiting for file at \(url.path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }
}
