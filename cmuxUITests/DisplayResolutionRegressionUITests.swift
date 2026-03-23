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
    private var appLogPath = ""
    private var launchedAppProcess: Process?
    private var launchedAppBundlePath = ""
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
        appLogPath = "\(tempPrefix)-app.log"

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

    private func launchAppProcess(targetDisplayID: String) throws {
        let executablePath = try resolveAppExecutablePath()
        launchedAppBundlePath = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launchEnvironment(targetDisplayID: targetDisplayID) {
            environment[key] = value
        }
        proc.environment = environment

        let logHandle = FileHandle(forWritingAtPath: appLogPath) ?? {
            FileManager.default.createFile(atPath: appLogPath, contents: nil)
            return FileHandle(forWritingAtPath: appLogPath)
        }()
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        launchedAppProcess = proc

        if !waitForAppLaunchDiagnostics(pid: proc.processIdentifier, timeout: 12.0) {
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "App process failed to write launch diagnostics. pid=\(proc.processIdentifier) log=\(readTrimmedFile(atPath: appLogPath) ?? "<missing>")"
            ])
        }

        reopenAppBundleIfNeeded()
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
        guard let launchedAppProcess else { return }
        defer {
            self.launchedAppProcess = nil
            self.launchedAppBundlePath = ""
        }

        if launchedAppProcess.isRunning {
            launchedAppProcess.terminate()
            launchedAppProcess.waitUntilExit()
        }
    }

    private func launchedAppDiagnostics() -> String {
        guard let launchedAppProcess else { return "not-launched" }
        return "pid=\(launchedAppProcess.processIdentifier) running=\(launchedAppProcess.isRunning) bundle=\(launchedAppBundlePath)"
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

    private func resolveAppExecutablePath() throws -> String {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var productDirectories: [String] = []

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())

        var candidates: [String] = []
        for productsDir in uniquePaths(productDirectories) {
            appendAppExecutableCandidates(fromProductsDirectory: productsDir, to: &candidates)
        }

        for path in uniquePaths(candidates) where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        throw NSError(domain: "DisplayResolutionRegressionUITests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Unable to locate cmux app executable. searched=\(uniquePaths(candidates))"
        ])
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendAppExecutableCandidates(fromProductsDirectory productsDir: String, to candidates: inout [String]) {
        candidates.append("\(productsDir)/cmux DEV.app/Contents/MacOS/cmux DEV")
        candidates.append("\(productsDir)/cmux.app/Contents/MacOS/cmux")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let executableName = (entry as NSString).deletingPathExtension
            let executablePath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(executableName)
                .path
            candidates.append(executablePath)
        }
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    private func waitForAppLaunchDiagnostics(pid: Int32, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            return diagnostics["pid"] == String(pid)
        }
    }

    private func reopenAppBundleIfNeeded() {
        guard !launchedAppBundlePath.isEmpty else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [launchedAppBundlePath]
        try? proc.run()
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
            appLogPath,
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
