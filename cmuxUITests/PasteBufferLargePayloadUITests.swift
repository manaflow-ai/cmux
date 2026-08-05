import AppKit
import Darwin
import Foundation
import XCTest

final class PasteBufferLargePayloadUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""
    private var appLogPath = ""
    private var appProcess: Process?
    private var appBundleURL: URL?
    private var appBundleIdentifier = ""
    private var runningApplication: NSRunningApplication?
    private var preexistingApplicationPIDs = Set<pid_t>()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let token = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        socketPath = temporaryDirectory
            .appendingPathComponent("p-\(token.prefix(8)).sock")
            .path
        launchTag = "ui-tests-paste-buffer-\(token.prefix(8))"
        appLogPath = temporaryDirectory
            .appendingPathComponent("cmux-paste-buffer-\(token).log")
            .path
        removeTestArtifacts()
    }

    override func tearDown() {
        terminateAppProcess()
        removeTestArtifacts()
        super.tearDown()
    }

    func testLargeMultilinePasteBufferPreservesEveryMarkerInOrder() throws {
        print("Paste-buffer regression host: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let process = try launchAppProcess()
        XCTAssertTrue(
            process.isRunning,
            "Expected cmux to stay running. \(appProcessDiagnostics()) log=[\(tailOfAppLog())]"
        )
        let socketReady = waitForControlSocketReady(
            socketPath: socketPath,
            listenerBindTimeout: 30.0,
            pingTimeout: 12.0,
            pingReturnsPong: {
                self.controlSocketCommandViaNetcat("ping", socketPath: self.socketPath) == "PONG"
            }
        )
        XCTAssertTrue(
            socketReady,
            "Expected a responsive control socket at \(socketPath). \(appProcessDiagnostics()) log=[\(tailOfAppLog())]"
        )
        let launchedApplication = waitForLaunchedApplication(timeout: 5.0)
        XCTAssertNotNil(
            launchedApplication,
            "Expected to resolve the LaunchServices app process. \(appProcessDiagnostics()) log=[\(tailOfAppLog())]"
        )
        print(
            "App process and control socket ready: launcherPid=\(process.processIdentifier) "
                + "appPid=\(launchedApplication?.processIdentifier ?? -1)"
        )

        let cliPath = try XCTUnwrap(
            bundledCLIPath(),
            "Expected the built app to contain Contents/Resources/bin/cmux"
        )
        let bufferName = "issue-5138-\(UUID().uuidString)"
        let expectedMarkers = (1...80).map { String(format: "MARK%04d", $0) }
        let payload = expectedMarkers.map { "\($0) \(String(repeating: "x", count: 48))" }
            .joined(separator: "\n")
        XCTAssertEqual(payload.utf8.count, 4_639)

        let create = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [
                "workspace", "create",
                "--name", "paste-buffer-regression",
                "--cwd", "/tmp",
                "--command", "cat",
                "--focus", "false",
            ]
        )
        XCTAssertEqual(create.status, 0, create.diagnostic)
        let workspace = try XCTUnwrap(
            create.stdout.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first(where: { $0.hasPrefix("workspace:") }),
            "Expected workspace.create to return a workspace ref. \(create.diagnostic)"
        )
        print("Cat workspace created: \(workspace)")

        let setBuffer = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["set-buffer", "--name", bufferName, "--", payload]
        )
        XCTAssertEqual(setBuffer.status, 0, setBuffer.diagnostic)

        let pasteBuffer = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [
                "paste-buffer", "--name", bufferName,
                "--workspace", workspace,
            ]
        )
        XCTAssertEqual(
            pasteBuffer.status,
            0,
            "\(pasteBuffer.diagnostic) \(appProcessDiagnostics()) log=[\(tailOfAppLog())]"
        )
        print("Paste-buffer commands succeeded: set-buffer=0 paste-buffer=0")

        var captured = ""
        let deadline = Date().addingTimeInterval(12.0)
        repeat {
            let readScreen = runCLI(
                cliPath: cliPath,
                socketPath: socketPath,
                arguments: ["read-screen", "--workspace", workspace, "--scrollback"]
            )
            XCTAssertEqual(readScreen.status, 0, readScreen.diagnostic)
            captured = readScreen.stdout
            if captured.contains("MARK0080") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        let actualMarkers = try orderedDistinctMarkers(in: captured)
        XCTAssertEqual(
            actualMarkers,
            expectedMarkers,
            markerFailureMessage(expected: expectedMarkers, actual: actualMarkers)
        )
    }

    private func launchAppProcess() throws -> Process {
        let bundleURL = try resolveAppBundleURL()
        let bundleIdentifier = try XCTUnwrap(
            Bundle(url: bundleURL)?.bundleIdentifier,
            "Expected the built app bundle to have an identifier"
        )
        appBundleURL = bundleURL
        appBundleIdentifier = bundleIdentifier
        preexistingApplicationPIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .map(\.processIdentifier)
        )

        _ = FileManager.default.createFile(atPath: appLogPath, contents: nil)

        var launchEnvironment = [
            "CMUX_UI_TEST_PROCESS": "1",
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_SOCKET_ENABLE": "1",
            "CMUX_SOCKET_MODE": "allowAll",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            "CMUX_TAG": launchTag,
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            launchEnvironment["PATH"] = path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", "-g", "-W",
            "--stdout", appLogPath,
            "--stderr", appLogPath,
        ] + launchEnvironment.sorted(by: { $0.key < $1.key }).flatMap { key, value in
            ["--env", "\(key)=\(value)"]
        } + [
            bundleURL.path,
            "--args",
            "-socketControlMode", "allowAll",
            "-NSAppSleepDisabled", "YES",
            "-cmuxUITestLaunchTag", launchTag,
        ]
        try process.run()
        appProcess = process
        return process
    }

    private func resolveAppBundleURL() throws -> URL {
        let testBundle = Bundle(for: Self.self)
        let productsDirectory = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = productsDirectory.lastPathComponent.lowercased()
        let productNames = configuration.contains("release")
            ? ["cmux", "cmux DEV"]
            : ["cmux DEV", "cmux"]
        let candidates = productNames.map { productName in
            productsDirectory.appendingPathComponent("\(productName).app")
        }
        if let bundleURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return bundleURL
        }
        throw NSError(
            domain: "PasteBufferLargePayloadUITests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "App bundle not found at \(candidates.map(\.path).joined(separator: " or ")). testBundle=\(testBundle.bundleURL.path)"
            ]
        )
    }

    private func waitForLaunchedApplication(timeout: TimeInterval) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: appBundleIdentifier)
                .first(where: { !preexistingApplicationPIDs.contains($0.processIdentifier) }) {
                runningApplication = application
                return application
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return nil
    }

    private func terminateAppProcess() {
        let application = runningApplication ?? waitForLaunchedApplication(timeout: 1.0)
        if let application, !application.isTerminated {
            application.terminate()
            let deadline = Date().addingTimeInterval(5.0)
            while !application.isTerminated && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if !application.isTerminated {
                application.forceTerminate()
            }
        }
        runningApplication = nil

        if let process = appProcess, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        appProcess = nil
    }

    private func appProcessDiagnostics() -> String {
        let launcherDescription: String
        if let process = appProcess {
            let status = process.isRunning ? "running" : String(process.terminationStatus)
            launcherDescription = "launcherPid=\(process.processIdentifier) launcherStatus=\(status)"
        } else {
            launcherDescription = "launcher=not-launched"
        }
        let applicationDescription = runningApplication.map {
            "appPid=\($0.processIdentifier) appTerminated=\($0.isTerminated)"
        } ?? "app=unresolved"
        return "\(launcherDescription) \(applicationDescription) bundle=\(appBundleURL?.path ?? "nil")"
    }

    private func tailOfAppLog(maximumLength: Int = 4_000) -> String {
        guard let contents = try? String(contentsOfFile: appLogPath, encoding: .utf8) else {
            return "<missing>"
        }
        return String(contents.suffix(maximumLength))
    }

    private func runCLI(
        cliPath: String,
        socketPath: String,
        arguments: [String]
    ) -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--socket", socketPath] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "12"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CLIResult(
                status: -1,
                stdout: "",
                stderr: "Failed to run \(cliPath): \(error.localizedDescription)"
            )
        }

        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func bundledCLIPath() -> String? {
        var productDirectories: [String] = []
        let environment = ProcessInfo.processInfo.environment
        if let builtProducts = environment["BUILT_PRODUCTS_DIR"], !builtProducts.isEmpty {
            productDirectories.append(builtProducts)
        }
        if let testHost = environment["TEST_HOST"], !testHost.isEmpty {
            var productsURL = URL(fileURLWithPath: testHost)
            for _ in 0..<4 {
                productsURL.deleteLastPathComponent()
            }
            productDirectories.append(productsURL.path)
        }
        for bundleURL in [Bundle.main.bundleURL, Bundle(for: Self.self).bundleURL] {
            let components = bundleURL.standardizedFileURL.path.split(separator: "/")
            guard let products = components.firstIndex(of: "Products"), products + 1 < components.count else {
                continue
            }
            productDirectories.append("/" + components.prefix(products + 2).joined(separator: "/"))
        }

        var candidates: [String] = []
        for directory in Self.orderedDistinct(productDirectories) {
            candidates.append("\(directory)/cmux DEV.app/Contents/Resources/bin/cmux")
            candidates.append("\(directory)/cmux.app/Contents/Resources/bin/cmux")
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                for entry in entries.sorted() where entry.hasSuffix(".app") {
                    candidates.append("\(directory)/\(entry)/Contents/Resources/bin/cmux")
                }
            }
        }
        return Self.orderedDistinct(candidates).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func orderedDistinctMarkers(in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"MARK[0-9]{4}"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        return Self.orderedDistinct(matches)
    }

    private func markerFailureMessage(expected: [String], actual: [String]) -> String {
        let actualSet = Set(actual)
        let missing = expected.filter { !actualSet.contains($0) }
        return "Expected all 80 markers in order; missing=\(missing) actual=\(actual)"
    }

    private func removeTestArtifacts() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: appLogPath)
    }

    private static func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var diagnostic: String {
            "status=\(status) stdout=\(stdout.debugDescription) stderr=\(stderr.debugDescription)"
        }
    }
}
