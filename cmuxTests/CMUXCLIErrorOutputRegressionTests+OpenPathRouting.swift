import CmuxSocketControl
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Path-argument open routing
extension CMUXCLIErrorOutputRegressionTests {
    func testDotPathOpenBypassesProtectedSocketForExternalCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-external-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        let openEnvLogURL = root.appendingPathComponent("open-env.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-external-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SOCKET"] = "/tmp/cmux-stale-\(UUID().uuidString.prefix(8)).sock"
        environment["CMUX_SOCKET_PASSWORD"] = "stale-password"
        environment["CMUX_SOCKET_ENABLE"] = "0"
        environment["CMUX_SOCKET_MODE"] = "off"
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        environment["CMUX_WORKSPACE_ID"] = "workspace:stale"
        environment["CMUX_PANEL_ID"] = "panel:stale"
        environment["CMUX_SURFACE_ID"] = "surface:stale"
        environment["CMUX_TAB_ID"] = "tab:stale"
        environment["CMUX_TAG"] = "keepme"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path
        environment["CMUX_TEST_OPEN_ENV_LOG"] = openEnvLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["."],
            environment: environment,
            currentDirectoryURL: workingDirectory,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertEqual(responder.receivedRequests, [])

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.first, "-a")
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
        XCTAssertTrue(openArguments.dropFirst().first?.hasSuffix(".app") == true, openArguments.joined(separator: " "))

        let openEnvironment = try readFakeOpenEnvironment(from: openEnvLogURL)
        for strippedKey in [
            "CMUX_ALLOW_SOCKET_OVERRIDE",
            "CMUX_SOCKET",
            "CMUX_SOCKET_ENABLE",
            "CMUX_SOCKET_MODE",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_SOCKET_PATH",
            "CMUX_PANEL_ID",
            "CMUX_SURFACE_ID",
            "CMUX_TAB_ID",
            "CMUX_WORKSPACE_ID",
        ] {
            XCTAssertFalse(
                openEnvironment.contains { $0.hasPrefix("\(strippedKey)=") },
                "\(strippedKey) leaked to LaunchServices open environment: \(openEnvironment)"
            )
        }
        XCTAssertTrue(openEnvironment.contains("CMUX_TAG=keepme"), openEnvironment.joined(separator: "\n"))
    }

    func testBareRelativeDirectoryPathOpenBypassesProtectedSocketForExternalCLI() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-bare-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-bare-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["project"],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertEqual(responder.receivedRequests, [])

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
    }

    func testKnownCommandStillUsesSocketWhenMatchingBareRelativePathExists() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-command-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ping", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-command-path-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "PONG")
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "PONG")
        XCTAssertEqual(responder.receivedRequests, ["ping"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLogURL.path))
    }

    func testCaseVariantBareRelativeDirectoryPathOpenBypassesProtectedSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-case-path-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-case-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: "ERROR: Access denied — only processes started inside cmux can connect"
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["Docs"],
            environment: environment,
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertEqual(responder.receivedRequests, [])

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertEqual(openArguments.last, workingDirectory.standardizedFileURL.path)
    }

    func testExplicitSocketPathOpenUsesRequestedSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-explicit-open-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeOpenURL = root.appendingPathComponent("open", isDirectory: false)
        let openLogURL = root.appendingPathComponent("open-args.txt", isDirectory: false)
        try fakeOpenScript().write(to: fakeOpenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenURL.path)

        let socketPath = "/tmp/cmux-explicit-open-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"workspace_ref":"workspace:explicit"}}"#
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = fakeOpenURL.path
        environment["CMUX_TEST_OPEN_LOG"] = openLogURL.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "."],
            environment: environment,
            currentDirectoryURL: workingDirectory,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK workspace:explicit")

        let request = try XCTUnwrap(responder.receivedRequests.first)
        let requestData = try XCTUnwrap(request.data(using: .utf8))
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
        )
        XCTAssertEqual(requestObject["method"] as? String, "workspace.create")
        let params = try XCTUnwrap(requestObject["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, workingDirectory.standardizedFileURL.path)

        let openArguments = try readFakeOpenArguments(from: openLogURL)
        XCTAssertFalse(openArguments.contains(workingDirectory.standardizedFileURL.path), openArguments.joined(separator: " "))
    }

}
