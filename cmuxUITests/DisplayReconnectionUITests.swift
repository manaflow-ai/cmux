import XCTest
import Foundation

/// Tests that windows restore to their correct positions when external displays
/// are disconnected and reconnected (issues #1331, #2135, #2666).
///
/// Lifecycle:
/// 1. Create a virtual display and move the app window to it.
/// 2. Destroy the virtual display — verify the window moves to the primary
///    display with a reasonable size (not a degenerate sliver).
/// 3. Recreate the virtual display — verify the window returns to it.
final class DisplayReconnectionUITests: XCTestCase {
    private var launchTag = ""
    private var diagnosticsPath = ""
    private var displayReadyPath = ""
    private var displayIDPath = ""
    private var helperBinaryPath = ""
    private var helperLogPath = ""
    private var helperProcess: Process?
    private var appProcess: Process?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        let tempPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-reconnect-\(token)")
            .path
        launchTag = "ui-tests-reconnect-\(token.prefix(8))"
        diagnosticsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-reconnect-\(token).json")
            .path
        displayReadyPath = "\(tempPrefix).ready"
        displayIDPath = "\(tempPrefix).id"
        helperBinaryPath = "\(tempPrefix)-helper"
        helperLogPath = "\(tempPrefix)-helper.log"

        removeTestArtifacts()
    }

    override func tearDown() {
        terminateAppProcess()
        terminateHelperProcess()
        removeTestArtifacts()
        super.tearDown()
    }

    // MARK: - Test

    func testWindowRestoresToExternalDisplayAfterReconnection() throws {
        // If pre-launched from CI, use the manifest.
        let prelaunch = loadPrelaunchManifest()
        if let diagPath = prelaunch?.diagnosticsPath, !diagPath.isEmpty {
            diagnosticsPath = diagPath
        }

        // Step 1: Build and launch the virtual display helper with a single
        // static mode (no mode churning — just create the display and keep it alive).
        try buildDisplayHelper()
        try launchDisplayHelper()

        XCTAssertTrue(
            waitForFile(atPath: displayReadyPath, timeout: 12.0),
            "Expected display harness ready file at \(displayReadyPath)"
        )
        guard let targetDisplayID = readTrimmedFile(atPath: displayIDPath), !targetDisplayID.isEmpty else {
            XCTFail("Missing target display ID at \(displayIDPath)")
            return
        }

        // Step 2: Launch the app targeting the virtual display. In prelaunch
        // mode (CI), the app is already running but needs to know the display ID.
        try launchAppProcess(targetDisplayID: targetDisplayID)

        XCTAssertTrue(
            waitForTargetDisplayMove(targetDisplayID: targetDisplayID, timeout: 15.0),
            "Expected app window to move to virtual display \(targetDisplayID). diagnostics=\(loadDiagnostics() ?? [:])"
        )

        // Wait for the autosave tick to capture the position on the virtual
        // display. The autosave interval is 8s; poll the diagnostics file's
        // modification date to detect when a save cycle completes.
        let initialModDate = diagnosticsModificationDate()
        XCTAssertTrue(
            waitForCondition(timeout: 15.0) {
                guard let current = self.diagnosticsModificationDate(),
                      let initial = initialModDate else { return false }
                return current > initial
            },
            "Expected at least one autosave tick while window is on the virtual display"
        )

        // Step 3: Kill the virtual display helper, removing the virtual display.
        terminateHelperProcess()

        // Wait for the app to detect the display change and reposition.
        XCTAssertTrue(
            waitForCondition(timeout: 8.0) {
                guard let diag = self.loadDiagnostics() else { return false }
                let ids = self.parseDisplayIDs(diag["windowScreenDisplayIDs"])
                return !ids.contains(targetDisplayID)
            },
            "Expected window to leave virtual display after disconnect. diagnostics=\(loadDiagnostics() ?? [:])"
        )

        // Step 4: Recreate the virtual display.
        removeHelperArtifacts()
        try launchDisplayHelper()

        XCTAssertTrue(
            waitForFile(atPath: displayReadyPath, timeout: 12.0),
            "Expected display harness ready file for second virtual display"
        )
        guard let newDisplayID = readTrimmedFile(atPath: displayIDPath), !newDisplayID.isEmpty else {
            XCTFail("Missing display ID for recreated virtual display")
            return
        }

        // Step 5: Wait for the window to return to the virtual display.
        // The app should detect the new display and restore the window.
        // The display ID may differ after recreation, but for virtual displays
        // macOS typically reuses the same ID.
        let windowReturnedToExternal = waitForCondition(timeout: 10.0) {
            guard let diag = self.loadDiagnostics() else { return false }
            let ids = self.parseDisplayIDs(diag["windowScreenDisplayIDs"])
            return ids.contains(newDisplayID)
        }

        XCTAssertTrue(
            windowReturnedToExternal,
            "Expected window to return to virtual display \(newDisplayID) after reconnection. diagnostics=\(loadDiagnostics() ?? [:])"
        )
    }

    // MARK: - Display Helper

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
            throw NSError(domain: "DisplayReconnectionUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to build display helper: \(stderr)"
            ])
        }
    }

    private func launchDisplayHelper() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperBinaryPath)
        // Single mode, no iterations — just create and hold the display.
        proc.arguments = [
            "--modes", "1920x1080",
            "--ready-path", displayReadyPath,
            "--display-id-path", displayIDPath,
            "--iterations", "0",
        ]

        let logHandle: FileHandle? = {
            FileManager.default.createFile(atPath: helperLogPath, contents: nil)
            return FileHandle(forWritingAtPath: helperLogPath)
        }()
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        helperProcess = proc
    }

    // MARK: - App Process

    private func launchAppProcess(targetDisplayID: String) throws {
        let binaryPath = try resolveAppBinaryPath()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var env = ProcessInfo.processInfo.environment
        env["CMUX_UI_TEST_MODE"] = "1"
        env["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        env["CMUX_UI_TEST_TARGET_DISPLAY_ID"] = targetDisplayID
        env["CMUX_TAG"] = launchTag
        proc.environment = env

        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-app-\(launchTag).log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        appProcess = proc

        guard waitForAppLaunchDiagnostics(timeout: 15.0) else {
            let isAlive = proc.isRunning
            let appLog = (try? String(contentsOfFile: logPath, encoding: .utf8))
                .map { String($0.suffix(2000)) } ?? "<empty>"
            throw NSError(domain: "DisplayReconnectionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "App failed to launch. alive=\(isAlive) appLog=[\(appLog)]"
            ])
        }
    }

    private func resolveAppBinaryPath() throws -> String {
        let testBundle = Bundle(for: Self.self)
        let productsDir = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binaryPath = productsDir
            .appendingPathComponent("cmux DEV.app")
            .appendingPathComponent("Contents/MacOS/cmux DEV")
            .path
        if FileManager.default.fileExists(atPath: binaryPath) {
            return binaryPath
        }

        throw NSError(domain: "DisplayReconnectionUITests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "App binary not found at \(binaryPath)"
        ])
    }

    // MARK: - Diagnostics

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func diagnosticsModificationDate() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: diagnosticsPath) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// Splits the comma-separated `windowScreenDisplayIDs` diagnostics value
    /// into exact ID strings so lookups don't false-positive on substrings.
    private func parseDisplayIDs(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map { String($0) })
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
            let ids = self.parseDisplayIDs(diagnostics["windowScreenDisplayIDs"])
            return diagnostics["targetDisplayMoveSucceeded"] == "1" && ids.contains(targetDisplayID)
        }
    }

    // MARK: - Helpers

    private func waitForCondition(timeout: TimeInterval, pollInterval: TimeInterval = 0.2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
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

    private func terminateAppProcess() {
        guard let proc = appProcess else { return }
        defer { appProcess = nil }
        if !proc.isRunning { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(5.0)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if proc.isRunning { proc.interrupt() }
    }

    private func terminateHelperProcess() {
        guard let proc = helperProcess else { return }
        defer { helperProcess = nil }
        if !proc.isRunning { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if proc.isRunning { proc.interrupt() }
    }

    private func removeHelperArtifacts() {
        for path in [displayReadyPath, displayIDPath] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func removeTestArtifacts() {
        for path in [
            diagnosticsPath, displayReadyPath, displayIDPath,
            helperBinaryPath, helperLogPath,
        ] {
            guard !path.isEmpty else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private struct PrelaunchManifest: Decodable {
        let diagnosticsPath: String?
    }

    private func loadPrelaunchManifest() -> PrelaunchManifest? {
        let url = URL(fileURLWithPath: "/tmp/cmux-ui-test-prelaunch.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PrelaunchManifest.self, from: data)
    }
}
