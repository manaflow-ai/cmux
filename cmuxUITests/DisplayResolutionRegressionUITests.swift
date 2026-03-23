import XCTest
import Foundation

final class DisplayResolutionRegressionUITests: XCTestCase {
    private let defaultDisplayHarnessManifestPath = "/tmp/cmux-ui-test-display-harness.json"
    private var launchTag = ""
    private var diagnosticsPath = ""
    private var displayReadyPath = ""
    private var displayIDPath = ""
    private var displayStartPath = ""
    private var displayDonePath = ""
    private var helperBinaryPath = ""
    private var helperLogPath = ""
    private var appProcess: Process?
    private var helperProcess: Process?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        let tempPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-display-\(token)")
            .path
        launchTag = "ui-tests-display-resolution-\(token.prefix(8))"
        diagnosticsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-display-churn-\(token).json")
            .path
        displayReadyPath = "\(tempPrefix).ready"
        displayIDPath = "\(tempPrefix).id"
        displayStartPath = "\(tempPrefix).start"
        displayDonePath = "\(tempPrefix).done"
        helperBinaryPath = "\(tempPrefix)-helper"
        helperLogPath = "\(tempPrefix)-helper.log"

        removeTestArtifacts()
    }

    override func tearDown() {
        terminateAppProcess()
        helperProcess?.terminate()
        helperProcess?.waitUntilExit()
        helperProcess = nil
        removeTestArtifacts()
        super.tearDown()
    }

    private let prelaunchManifestPath = "/tmp/cmux-ui-test-prelaunch.json"

    func testRapidDisplayResolutionChangesKeepTerminalResponsive() throws {
        // On CI, the app is pre-launched from the shell (outside the XCTest
        // runner's sandbox) so it can write to /tmp/ and activate properly.
        // The CI step writes a manifest with the diagnostics path.
        let prelaunch = loadPrelaunchManifest()
        if let diagPath = prelaunch?.diagnosticsPath, !diagPath.isEmpty {
            diagnosticsPath = diagPath
        }

        try prepareDisplayHarnessIfNeeded()

        XCTAssertTrue(waitForFile(atPath: displayReadyPath, timeout: 12.0), "Expected display harness ready file at \(displayReadyPath)")
        guard let targetDisplayID = readTrimmedFile(atPath: displayIDPath), !targetDisplayID.isEmpty else {
            XCTFail("Missing target display ID at \(displayIDPath)")
            return
        }

        if prelaunch == nil {
            try launchAppProcess(targetDisplayID: targetDisplayID)
        }

        XCTAssertTrue(
            waitForTargetDisplayMove(targetDisplayID: targetDisplayID, timeout: 12.0),
            "Expected app window to move to display \(targetDisplayID). diagnostics=\(loadDiagnostics() ?? [:]) app=\(launchedAppDiagnostics())"
        )

        guard let baselineStats = waitForRenderStats(timeout: 8.0) else {
            XCTFail("Missing initial render stats. diagnostics=\(loadDiagnostics() ?? [:])")
            return
        }
        let baselinePresentCount = baselineStats.presentCount
        var maxPresentCount = baselinePresentCount
        var maxDiagnosticsUpdatedAt = baselineStats.diagnosticsUpdatedAt
        var lastStats = baselineStats

        // When pre-launched from CI, the display helper uses --start-delay-ms
        // instead of a start signal file (sandbox prevents writing to /tmp/).
        // displayStartPath is empty when the harness manifest omits startPath.
        if prelaunch == nil && !displayStartPath.isEmpty {
            do {
                try Data("start\n".utf8).write(to: URL(fileURLWithPath: displayStartPath), options: .atomic)
            } catch {
                XCTFail("Expected start signal file to be created at \(displayStartPath): \(error)")
                return
            }
        }

        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if let stats = loadRenderStats() {
                lastStats = stats
                maxPresentCount = max(maxPresentCount, stats.presentCount)
                maxDiagnosticsUpdatedAt = max(maxDiagnosticsUpdatedAt, stats.diagnosticsUpdatedAt)
            }

            let doneMarker = readTrimmedFile(atPath: displayDonePath)
            if doneMarker == "done" && maxPresentCount >= baselinePresentCount + 8 {
                break
            }
            if let doneMarker, doneMarker.hasPrefix("error:") {
                XCTFail("Display churn helper failed: \(doneMarker). log=\(readTrimmedFile(atPath: helperLogPath) ?? "<missing>")")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertEqual(
            readTrimmedFile(atPath: displayDonePath),
            "done",
            "Expected display churn to finish. helperLog=\(readTrimmedFile(atPath: helperLogPath) ?? "<missing>")"
        )

        guard let finalStats = waitForRenderStats(timeout: 6.0) else {
            XCTFail("Expected render stats after display churn. diagnostics=\(loadDiagnostics() ?? [:])")
            return
        }

        maxPresentCount = max(maxPresentCount, finalStats.presentCount)
        maxDiagnosticsUpdatedAt = max(maxDiagnosticsUpdatedAt, finalStats.diagnosticsUpdatedAt)

        XCTAssertGreaterThanOrEqual(
            maxPresentCount - baselinePresentCount,
            8,
            "Expected terminal presents to keep advancing during display churn. baseline=\(baselineStats) last=\(lastStats) final=\(finalStats)"
        )
        XCTAssertGreaterThan(
            maxDiagnosticsUpdatedAt,
            baselineStats.diagnosticsUpdatedAt,
            "Expected render diagnostics to keep updating during display churn. baseline=\(baselineStats) final=\(finalStats)"
        )
    }

    private func prepareDisplayHarnessIfNeeded() throws {
        let env = ProcessInfo.processInfo.environment
        if let helperBinaryPath = loadPrebuiltHelperBinaryPath(env) {
            self.helperBinaryPath = helperBinaryPath
            try launchDisplayHelper()
            return
        }
        if let externalHarness = loadExternalHarnessFromEnvironment(env) ?? loadExternalHarnessFromManifest(env) {
            if let helperBinaryPath = externalHarness.helperBinaryPath, !helperBinaryPath.isEmpty {
                self.helperBinaryPath = helperBinaryPath
                try launchDisplayHelper()
                return
            }
            guard let readyPath = externalHarness.readyPath, !readyPath.isEmpty,
                  let displayIDPath = externalHarness.displayIDPath, !displayIDPath.isEmpty,
                  let donePath = externalHarness.donePath, !donePath.isEmpty else {
                throw NSError(domain: "DisplayResolutionRegressionUITests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Incomplete external display harness configuration"
                ])
            }
            displayReadyPath = readyPath
            self.displayIDPath = displayIDPath
            // startPath is optional — CI uses --start-delay-ms instead of a start
            // signal file because the XCTest sandbox can't write to /tmp/.
            if let startPath = externalHarness.startPath, !startPath.isEmpty {
                displayStartPath = startPath
            } else {
                displayStartPath = ""
            }
            displayDonePath = donePath
            if let logPath = externalHarness.logPath, !logPath.isEmpty {
                helperLogPath = logPath
            }
            return
        }

        try buildDisplayHelper()
        try launchDisplayHelper()
    }

    private func loadPrebuiltHelperBinaryPath(_ env: [String: String]) -> String? {
        guard let helperBinaryPath = env["CMUX_UI_TEST_DISPLAY_HELPER_BINARY_PATH"],
              !helperBinaryPath.isEmpty else {
            return nil
        }
        return helperBinaryPath
    }

    private func loadExternalHarnessFromEnvironment(_ env: [String: String]) -> ExternalDisplayHarness? {
        guard let readyPath = env["CMUX_UI_TEST_DISPLAY_READY_PATH"], !readyPath.isEmpty,
              let displayIDPath = env["CMUX_UI_TEST_DISPLAY_ID_PATH"], !displayIDPath.isEmpty,
              let donePath = env["CMUX_UI_TEST_DISPLAY_DONE_PATH"], !donePath.isEmpty else {
            return nil
        }

        return ExternalDisplayHarness(
            readyPath: readyPath,
            displayIDPath: displayIDPath,
            startPath: env["CMUX_UI_TEST_DISPLAY_START_PATH"],
            donePath: donePath,
            logPath: env["CMUX_UI_TEST_DISPLAY_LOG_PATH"],
            helperBinaryPath: nil
        )
    }

    private func loadExternalHarnessFromManifest(_ env: [String: String]) -> ExternalDisplayHarness? {
        let manifestPath = env["CMUX_UI_TEST_DISPLAY_HARNESS_MANIFEST_PATH"] ?? defaultDisplayHarnessManifestPath
        let manifestURL = URL(fileURLWithPath: manifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ExternalDisplayHarness.self, from: data)
    }

    private func buildDisplayHelper() throws {
        let sourceURL = repoRootURL.appendingPathComponent("scripts/create-virtual-display.m")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        proc.arguments = [
            "-framework", "Foundation",
            "-framework", "CoreGraphics",
            "-o", helperBinaryPath,
            sourceURL.path,
        ]

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to build display helper: \(stderr)"
            ])
        }
    }

    private func launchDisplayHelper() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperBinaryPath)
        proc.arguments = [
            "--modes", "1920x1080,1728x1117,1600x900,1440x810",
            "--ready-path", displayReadyPath,
            "--display-id-path", displayIDPath,
            "--start-path", displayStartPath,
            "--done-path", displayDonePath,
            "--iterations", "40",
            "--interval-ms", "40",
        ]

        let logHandle = FileHandle(forWritingAtPath: helperLogPath) ?? {
            FileManager.default.createFile(atPath: helperLogPath, contents: nil)
            return FileHandle(forWritingAtPath: helperLogPath)
        }()
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        helperProcess = proc
    }

    // Launch the app binary directly via Process. XCUIApplication.launch() blocks
    // for 60s on headless CI trying to foreground-activate. NSWorkspace.openApplication
    // causes the app to die immediately on headless runners. Process works because
    // it doesn't need WindowServer activation.
    //
    // The child process inherits the test runner's sandbox, so all temp file paths
    // (diagnostics, etc.) must use FileManager.default.temporaryDirectory (which
    // resolves to the sandbox container's tmp) instead of hardcoded /tmp/.
    private func launchAppProcess(targetDisplayID: String) throws {
        let binaryPath = try resolveAppBinaryPath()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        // Don't set proc.environment — inherit the test runner's full environment
        // so the child gets the same sandbox context and system state. Just add our
        // test-specific vars on top.
        var env = ProcessInfo.processInfo.environment
        for (key, value) in launchEnvironment(targetDisplayID: targetDisplayID) {
            env[key] = value
        }
        proc.environment = env

        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-app-\(launchTag).log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        appProcess = proc

        if !waitForAppLaunchDiagnostics(timeout: 15.0) {
            let isAlive = proc.isRunning
            let appLog = (try? String(contentsOfFile: logPath, encoding: .utf8))
                .map { String($0.suffix(2000)) } ?? "<empty>"
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "App failed to write launch diagnostics. alive=\(isAlive) diagnostics=\(loadDiagnostics() ?? [:]) diagPath=\(diagnosticsPath) appLog=[\(appLog)]"
            ])
        }
    }

    private func resolveAppBinaryPath() throws -> String {
        // UI test bundle is at:
        //   .../Build/Products/Debug/cmuxUITests-Runner.app/Contents/PlugIns/cmuxUITests.xctest
        // The app binary is at:
        //   .../Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV
        let testBundle = Bundle(for: Self.self)
        let productsDir = testBundle.bundleURL
            .deletingLastPathComponent()  // -> .../Contents/PlugIns
            .deletingLastPathComponent()  // -> .../Contents
            .deletingLastPathComponent()  // -> .../cmuxUITests-Runner.app
            .deletingLastPathComponent()  // -> .../Debug
        let binaryPath = productsDir
            .appendingPathComponent("cmux DEV.app")
            .appendingPathComponent("Contents/MacOS/cmux DEV")
            .path
        if FileManager.default.fileExists(atPath: binaryPath) {
            return binaryPath
        }

        throw NSError(domain: "DisplayResolutionRegressionUITests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "App binary not found at \(binaryPath). testBundle=\(testBundle.bundleURL.path)"
        ])
    }

    private func launchEnvironment(targetDisplayID: String) -> [String: String] {
        [
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_UI_TEST_DIAGNOSTICS_PATH": diagnosticsPath,
            "CMUX_UI_TEST_DISPLAY_RENDER_STATS": "1",
            "CMUX_UI_TEST_TARGET_DISPLAY_ID": targetDisplayID,
            "CMUX_TAG": launchTag,
        ]
    }

    private func terminateAppProcess() {
        guard let proc = appProcess else { return }
        defer { appProcess = nil }

        if !proc.isRunning { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(5.0)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if proc.isRunning {
            proc.interrupt()
        }
    }

    private func launchedAppDiagnostics() -> String {
        guard let proc = appProcess else { return "not-launched" }
        return "pid=\(proc.processIdentifier) running=\(proc.isRunning)"
    }

    private func waitForAppLaunchDiagnostics(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            guard let pid = diagnostics["pid"], !pid.isEmpty else { return false }
            guard let stage = diagnostics["stage"], !stage.isEmpty else { return false }
            return true
        }
    }

    private func waitForTargetDisplayMove(targetDisplayID: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            return diagnostics["targetDisplayMoveSucceeded"] == "1" &&
                diagnostics["windowScreenDisplayIDs"]?.contains(targetDisplayID) == true
        }
    }

    private func waitForRenderStats(timeout: TimeInterval) -> RenderStats? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stats = loadRenderStats() {
                return stats
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return loadRenderStats()
    }

    private func loadRenderStats() -> RenderStats? {
        guard let diagnostics = loadDiagnostics() else { return nil }
        return RenderStats(diagnostics: diagnostics)
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func waitForCondition(timeout: TimeInterval, pollInterval: TimeInterval = 0.15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            FileManager.default.fileExists(atPath: path)
        }
    }

    private func readTrimmedFile(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func removeTestArtifacts() {
        for path in [
            diagnosticsPath,
            displayReadyPath,
            displayIDPath,
            displayStartPath,
            displayDonePath,
            helperBinaryPath,
            helperLogPath,
        ] {
            guard !path.isEmpty else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private struct RenderStats: CustomStringConvertible {
        let panelId: String
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
        let diagnosticsUpdatedAt: Double

        init?(diagnostics: [String: String]) {
            guard diagnostics["renderStatsAvailable"] == "1",
                  let panelId = diagnostics["renderPanelId"], !panelId.isEmpty,
                  let drawCount = Int(diagnostics["renderDrawCount"] ?? ""),
                  let presentCount = Int(diagnostics["renderPresentCount"] ?? ""),
                  let lastPresentTime = Double(diagnostics["renderLastPresentTime"] ?? ""),
                  let diagnosticsUpdatedAt = Double(diagnostics["renderDiagnosticsUpdatedAt"] ?? "") else {
                return nil
            }

            self.panelId = panelId
            self.drawCount = drawCount
            self.presentCount = presentCount
            self.lastPresentTime = lastPresentTime
            self.windowVisible = diagnostics["renderWindowVisible"] == "1"
            self.appIsActive = diagnostics["renderAppIsActive"] == "1"
            self.desiredFocus = diagnostics["renderDesiredFocus"] == "1"
            self.isFirstResponder = diagnostics["renderIsFirstResponder"] == "1"
            self.diagnosticsUpdatedAt = diagnosticsUpdatedAt
        }

        var description: String {
            "panel=\(panelId) draw=\(drawCount) present=\(presentCount) lastPresent=\(String(format: "%.3f", lastPresentTime)) visible=\(windowVisible) active=\(appIsActive) desiredFocus=\(desiredFocus) firstResponder=\(isFirstResponder) updatedAt=\(String(format: "%.3f", diagnosticsUpdatedAt))"
        }
    }

    private struct ExternalDisplayHarness: Decodable {
        let readyPath: String?
        let displayIDPath: String?
        let startPath: String?
        let donePath: String?
        let logPath: String?
        let helperBinaryPath: String?
    }

    private struct PrelaunchManifest: Decodable {
        let diagnosticsPath: String?
    }

    private func loadPrelaunchManifest() -> PrelaunchManifest? {
        let url = URL(fileURLWithPath: prelaunchManifestPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PrelaunchManifest.self, from: data)
    }
}
