import XCTest
import Foundation
import AppKit

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
    private var launchedRunningApp: NSRunningApplication?
    private var helperProcess: Process?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        let tempPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-display-\(token)")
            .path
        launchTag = "ui-tests-display-resolution-\(token.prefix(8))"
        diagnosticsPath = "/tmp/cmux-ui-test-display-churn-\(token).json"
        displayReadyPath = "\(tempPrefix).ready"
        displayIDPath = "\(tempPrefix).id"
        displayStartPath = "\(tempPrefix).start"
        displayDonePath = "\(tempPrefix).done"
        helperBinaryPath = "\(tempPrefix)-helper"
        helperLogPath = "\(tempPrefix)-helper.log"

        removeTestArtifacts()
    }

    override func tearDown() {
        terminateLaunchedAppIfNeeded()
        helperProcess?.terminate()
        helperProcess?.waitUntilExit()
        helperProcess = nil
        removeTestArtifacts()
        super.tearDown()
    }

    func testRapidDisplayResolutionChangesKeepTerminalResponsive() throws {
        try prepareDisplayHarnessIfNeeded()

        XCTAssertTrue(waitForFile(atPath: displayReadyPath, timeout: 12.0), "Expected display harness ready file at \(displayReadyPath)")
        guard let targetDisplayID = readTrimmedFile(atPath: displayIDPath), !targetDisplayID.isEmpty else {
            XCTFail("Missing target display ID at \(displayIDPath)")
            return
        }

        try launchAppProcess(targetDisplayID: targetDisplayID)
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

        do {
            try Data("start\n".utf8).write(to: URL(fileURLWithPath: displayStartPath), options: .atomic)
        } catch {
            XCTFail("Expected start signal file to be created at \(displayStartPath): \(error)")
            return
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
                  let startPath = externalHarness.startPath, !startPath.isEmpty,
                  let donePath = externalHarness.donePath, !donePath.isEmpty else {
                throw NSError(domain: "DisplayResolutionRegressionUITests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Incomplete external display harness configuration"
                ])
            }
            displayReadyPath = readyPath
            self.displayIDPath = displayIDPath
            displayStartPath = startPath
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
              let startPath = env["CMUX_UI_TEST_DISPLAY_START_PATH"], !startPath.isEmpty,
              let donePath = env["CMUX_UI_TEST_DISPLAY_DONE_PATH"], !donePath.isEmpty else {
            return nil
        }

        return ExternalDisplayHarness(
            readyPath: readyPath,
            displayIDPath: displayIDPath,
            startPath: startPath,
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

    // Launch the app via NSWorkspace instead of XCUIApplication to avoid
    // the 60-second foreground activation timeout that kills UI tests on
    // headless CI runners. NSWorkspace.openApplication passes environment
    // variables through OpenConfiguration and returns immediately.
    private func launchAppProcess(targetDisplayID: String) throws {
        let appBundlePath = try resolveAppBundlePath()
        let appURL = URL(fileURLWithPath: appBundlePath)

        let config = NSWorkspace.OpenConfiguration()
        config.environment = launchEnvironment(targetDisplayID: targetDisplayID)
        config.activates = true

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        var runningApp: NSRunningApplication?

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            runningApp = app
            launchError = error
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 30.0)
        if waitResult == .timedOut {
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "NSWorkspace.openApplication timed out after 30s for \(appBundlePath)"
            ])
        }

        if let error = launchError {
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "NSWorkspace.openApplication failed: \(error.localizedDescription) path=\(appBundlePath)"
            ])
        }

        launchedRunningApp = runningApp

        if !waitForAppLaunchDiagnostics(timeout: 15.0) {
            let isAlive = launchedRunningApp?.isTerminated == false
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "App failed to write launch diagnostics. alive=\(isAlive) diagnostics=\(loadDiagnostics() ?? [:])"
            ])
        }
    }

    private func resolveAppBundlePath() throws -> String {
        // UI test bundle is at:
        //   .../Build/Products/Debug/cmuxUITests-Runner.app/Contents/PlugIns/cmuxUITests.xctest
        // The app is at:
        //   .../Build/Products/Debug/cmux DEV.app
        let testBundle = Bundle(for: Self.self)
        let productsDir = testBundle.bundleURL
            .deletingLastPathComponent()  // -> .../Contents/PlugIns
            .deletingLastPathComponent()  // -> .../Contents
            .deletingLastPathComponent()  // -> .../cmuxUITests-Runner.app
            .deletingLastPathComponent()  // -> .../Debug
        let appPath = productsDir.appendingPathComponent("cmux DEV.app").path
        if FileManager.default.fileExists(atPath: appPath) {
            return appPath
        }

        throw NSError(domain: "DisplayResolutionRegressionUITests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "App bundle not found at \(appPath). testBundle=\(testBundle.bundleURL.path)"
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

    private func terminateLaunchedAppIfNeeded() {
        guard let app = launchedRunningApp else { return }
        defer { launchedRunningApp = nil }

        if app.isTerminated { return }
        app.terminate()
        let deadline = Date().addingTimeInterval(5.0)
        while !app.isTerminated && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !app.isTerminated {
            app.forceTerminate()
        }
    }

    private func launchedAppDiagnostics() -> String {
        guard let app = launchedRunningApp else { return "not-launched" }
        return "pid=\(app.processIdentifier) terminated=\(app.isTerminated)"
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
}
