import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Swift Testing coverage for the `rc` release channel, kept next to the suites
/// it extends so the RC cases run under the same traits as their nightly twins.
extension AuthEnvironmentTests {
    @Test("rc bundle uses the cmux-rc callback scheme")
    func rcBundleUsesRCCallbackScheme() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.rc",
                isDebugBuild: false
            ) == "cmux-rc"
        )
    }
}

extension MobileHostIdentityTests {
    @Test func instanceTagUsesRCChannelAndSlug() {
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.rc"
        ) == "rc")
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.rc.candidate1"
        ) == "candidate1")
    }
}

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testThemesSetRCOverridePathIsReadableByRCAppConfigResolution() throws {
        try assertThemesSetOverridePathIsReadableByChannelApp(channel: "rc")
    }

    /// `channel` is the socket/bundle infix shared by the release lanes: `cmux-<channel>-<slug>.sock`
    /// maps to `com.cmuxterm.app.<channel>.<slug>`. The nightly twin in
    /// `CMUXCLIErrorOutputRegressionTests.swift` calls this with `"nightly"`.
    func assertThemesSetOverridePathIsReadableByChannelApp(channel: String) throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-\(channel)-path-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        // The reload target comes from the socket file name before CMUX_BUNDLE_ID is even
        // consulted: `cmux-nightly-<slug>.sock` becomes `com.cmuxterm.app.nightly.<slug>`.
        // So scoping the identifier means scoping the socket name it is read from, and both
        // take the same hex-only suffix — a raw UUID's dashes would turn into dots in the
        // identifier. Scoping matters because the reload goes out machine-wide: on the
        // plain nightly socket name this test told a real nightly build to re-read its
        // config, and two runs at once shared one identifier.
        let uniqueSuffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let socketPath = "/tmp/cmux-\(channel)-\(uniqueSuffix).sock"
        let bundleIdentifier = "com.cmuxterm.app.\(channel).\(uniqueSuffix)"
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)

        // Parsed from stdout alone. This is the check that used to break when a stray
        // diagnostic line from the runtime shared the pipe with the payload.
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            result.diagnostics
        )
        let configPath = try XCTUnwrap(payload["config_path"] as? String, result.diagnostics)
        XCTAssertEqual(payload["reload_target_bundle_id"] as? String, bundleIdentifier)

        let appSupportDirectory = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let expectedConfigURL = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        XCTAssertEqual(configPath, expectedConfigURL.path)

        let appReadablePaths = GhosttyApp.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        ).map(\.path)
        XCTAssertEqual(appReadablePaths, [expectedConfigURL.path])
    }
}
