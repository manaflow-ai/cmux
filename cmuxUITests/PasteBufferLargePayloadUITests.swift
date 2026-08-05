import Darwin
import Foundation
import XCTest

final class PasteBufferLargePayloadUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""
    private var appLogPath = ""
    private var appLogHandle: FileHandle?
    private var appProcess: Process?

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
        try? appLogHandle?.close()
        appLogHandle = nil
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
        print("App process and control socket ready: pid=\(process.processIdentifier)")

        let cliPath = try XCTUnwrap(
            bundledCLIPath(),
            "Expected the built app to contain Contents/Resources/bin/cmux"
        )
        let bufferName = "issue-5138-\(UUID().uuidString)"
        let expectedMarkers = (1...80).map { String(format: "MARK%04d", $0) }
        let payload = expectedMarkers.map { "\($0) \(String(repeating: "x", count: 48))" }
            .joined(separator: "\n") + "\n"
        XCTAssertEqual(payload.utf8.count, 4_640)

        let create = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: [
                "workspace", "create",
                "--name", "paste-buffer-regression",
                "--cwd", "/tmp",
                "--command", "cat; exec /bin/sleep 60",
                "--focus", "true",
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

        let readinessMarker = "PASTE_BUFFER_READY_\(UUID().uuidString)"
        let readinessSend = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["send", "--workspace", workspace, "--", readinessMarker + "\n"]
        )
        XCTAssertEqual(
            readinessSend.status,
            0,
            "\(readinessSend.diagnostic) \(appProcessDiagnostics()) log=[\(tailOfAppLog())]"
        )
        let readinessScreen = waitForScreenMarker(
            readinessMarker,
            cliPath: cliPath,
            socketPath: socketPath,
            workspace: workspace
        )
        XCTAssertTrue(
            readinessScreen.contains(readinessMarker),
            "Expected the focused cat workspace to echo its readiness marker"
        )

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

    private func waitForScreenMarker(
        _ marker: String,
        cliPath: String,
        socketPath: String,
        workspace: String,
        timeout: TimeInterval = 12.0
    ) -> String {
        var captured = ""
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let readScreen = runCLI(
                cliPath: cliPath,
                socketPath: socketPath,
                arguments: ["read-screen", "--workspace", workspace, "--scrollback"]
            )
            XCTAssertEqual(readScreen.status, 0, readScreen.diagnostic)
            captured = readScreen.stdout
            if captured.contains(marker) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return captured
    }

    private func launchAppProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveAppBinaryPath())
        process.arguments = [
            "-socketControlMode", "allowAll",
            "-NSAppSleepDisabled", "YES",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_UI_TEST_PROCESS"] = "1"
        environment["CMUX_UI_TEST_MODE"] = "1"
        environment["CMUX_SOCKET_ENABLE"] = "1"
        environment["CMUX_SOCKET_MODE"] = "allowAll"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        environment["CMUX_TAG"] = launchTag
        process.environment = environment

        _ = FileManager.default.createFile(atPath: appLogPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: appLogPath))
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw error
        }
        appLogHandle = logHandle
        appProcess = process
        return process
    }

    private func resolveAppBinaryPath() throws -> String {
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
            productsDirectory
                .appendingPathComponent("\(productName).app")
                .appendingPathComponent("Contents/MacOS/\(productName)")
                .path
        }
        if let binaryPath = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return binaryPath
        }
        throw NSError(
            domain: "PasteBufferLargePayloadUITests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "App binary not found at \(candidates.joined(separator: " or ")). testBundle=\(testBundle.bundleURL.path)"
            ]
        )
    }

    private func terminateAppProcess() {
        guard let process = appProcess else { return }
        defer { appProcess = nil }
        guard process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func appProcessDiagnostics() -> String {
        guard let process = appProcess else { return "app=not-launched" }
        let status = process.isRunning ? "running" : String(process.terminationStatus)
        return "appPid=\(process.processIdentifier) appRunning=\(process.isRunning) appStatus=\(status)"
    }

    private func tailOfAppLog(maximumLength: Int = 20_000) -> String {
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
