import Darwin
import Dispatch
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BundledCLILinkageTests: XCTestCase {
    deinit {}

    func testAppExecutableForwardsWelcomeToBundledCLI() throws {
        let appExecutableURL = try builtAppExecutableURL()
        let result = try runProcess(
            executableURL: appExecutableURL,
            arguments: ["welcome"],
            environment: ["CMUX_CLI_SENTRY_DISABLED": "1"],
            timeout: 5
        )

        XCTAssertEqual(result.status, 0, result.combinedOutput)
        XCTAssertTrue(result.stdout.contains("Run "), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux --help"), result.stdout)
    }

    func testAppExecutableForwarderKeepsFinderLaunchInApp() {
        let decision = CmuxAppCLIForwarder.decision(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "-psn_0_12345"],
            bundledCLIURL: nil,
            expectedBundledCLIPath: "/Applications/cmux.app/Contents/Resources/bin/cmux"
        )

        XCTAssertEqual(decision, .launchApp)
    }

    func testAppExecutableForwarderKeepsDefaultsLaunchArgumentsInApp() {
        let decision = CmuxAppCLIForwarder.decision(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "-AppleLanguages", "(en)"],
            bundledCLIURL: nil,
            expectedBundledCLIPath: "/Applications/cmux.app/Contents/Resources/bin/cmux"
        )

        XCTAssertEqual(decision, .launchApp)
    }

    func testAppExecutableForwarderRoutesExplicitArgumentsToBundledCLI() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-app-forwarder-tests-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("cmux.app/Contents/Resources/bin/cmux", isDirectory: false)
        try fileManager.createDirectory(at: cliURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: cliURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        defer { try? fileManager.removeItem(at: root) }

        let decision = CmuxAppCLIForwarder.decision(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "welcome"],
            bundledCLIURL: cliURL,
            expectedBundledCLIPath: cliURL.path,
            fileManager: fileManager
        )

        XCTAssertEqual(
            decision,
            .forward(cliURL: cliURL.standardizedFileURL, arguments: [cliURL.standardizedFileURL.path, "welcome"])
        )
    }

    func testAppExecutableForwarderReportsMissingBundledCLIAsCommandNotFound() throws {
        let fileManager = FileManager.default
        let missingURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-missing-cli-\(UUID().uuidString)", isDirectory: false)

        let decision = CmuxAppCLIForwarder.decision(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "welcome"],
            bundledCLIURL: missingURL,
            expectedBundledCLIPath: missingURL.path,
            fileManager: fileManager
        )

        guard case .fail(let message, let exitCode) = decision else {
            XCTFail("Expected missing CLI to fail, got \(decision)")
            return
        }
        XCTAssertEqual(exitCode, 127)
        XCTAssertTrue(message.contains(missingURL.path), message)
    }

    func testAppExecutableForwarderReportsNonExecutableBundledCLIAsCannotExecute() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-app-forwarder-tests-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("cmux.app/Contents/Resources/bin/cmux", isDirectory: false)
        try fileManager.createDirectory(at: cliURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: cliURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cliURL.path)
        defer { try? fileManager.removeItem(at: root) }

        let decision = CmuxAppCLIForwarder.decision(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "welcome"],
            bundledCLIURL: cliURL,
            expectedBundledCLIPath: cliURL.path,
            fileManager: fileManager
        )

        guard case .fail(let message, let exitCode) = decision else {
            XCTFail("Expected non-executable CLI to fail, got \(decision)")
            return
        }
        XCTAssertEqual(exitCode, 126)
        XCTAssertTrue(message.contains(cliURL.path), message)
    }

    func testBundledCLIDoesNotDependOnPrivateRPathFrameworks() throws {
        let cliURL = try bundledCLIURL()
        let linkedLibraries = try linkedLibraries(for: cliURL)
        let privateRPathFrameworks = linkedLibraries.filter {
            $0.hasPrefix("@rpath/") && $0.contains(".framework/")
        }

        XCTAssertEqual(
            privateRPathFrameworks,
            [],
            "The bundled cmux CLI is copied into Contents/Resources/bin as a standalone helper. Private @rpath framework dependencies abort in dyld before CLI code can run."
        )
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private func builtProductsURL() -> URL {
        Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func builtAppBundleURL() throws -> URL {
        let fileManager = FileManager.default
        let productsURL = builtProductsURL()
        let enumerator = fileManager.enumerator(at: productsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "app",
                  fileManager.fileExists(atPath: item.appendingPathComponent("Contents/Resources/bin/cmux").path) else {
                continue
            }
            return item
        }

        throw XCTSkip("cmux app bundle not found in \(productsURL.path)")
    }

    private func builtAppExecutableURL() throws -> URL {
        let appBundleURL = try builtAppBundleURL()
        if let executableURL = Bundle(url: appBundleURL)?.executableURL {
            return executableURL
        }
        throw XCTSkip("Executable not found in \(appBundleURL.path)")
    }

    private func bundledCLIURL() throws -> URL {
        let fileManager = FileManager.default
        let appBundleURL = builtProductsURL()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            XCTFail("Timed out running \(executableURL.path) \(arguments.joined(separator: " "))")
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func linkedLibraries(for executableURL: URL) throws -> [String] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", executableURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "otool failed: \(output)")

        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ")
                    .first
                    .map(String.init)
            }
    }
}
