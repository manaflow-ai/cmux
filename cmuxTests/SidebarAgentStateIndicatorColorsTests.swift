import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for the configurable sidebar agent-state indicator colors
/// (`sidebar.stateIndicatorColors`). Splits into two layers:
///   1. Pure render-time recolor logic (`SidebarAgentStateIndicatorColors`).
///   2. The cmux.json -> managed UserDefaults parsing wiring.
final class SidebarAgentStateIndicatorColorsTests: XCTestCase {

    // MARK: Helpers

    private func entry(
        key: String,
        value: String,
        icon: String?,
        color: String?
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: icon, color: color)
    }

    private func runningEntry(key: String = "claude_code") -> SidebarStatusEntry {
        entry(key: key, value: "Running", icon: "bolt.fill", color: "#4C8DFF")
    }

    private func needsInputEntry(key: String = "claude_code") -> SidebarStatusEntry {
        entry(key: key, value: "Needs input", icon: "bell.fill", color: "#4C8DFF")
    }

    private func idleEntry(key: String = "claude_code") -> SidebarStatusEntry {
        entry(key: key, value: "Idle", icon: "pause.circle.fill", color: "#8E8E93")
    }

    // MARK: Pure recolor logic

    func testNoOverridesPreservesExactlyTodaysColors() {
        // Default behavior contract: running + needsInput stay blue, idle stays
        // gray, and the array is returned unchanged (identity).
        let entries = [runningEntry(), needsInputEntry(), idleEntry()]
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            entries,
            runningOverrideHex: nil,
            needsInputOverrideHex: nil,
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored, entries)
        XCTAssertEqual(recolored.map(\.color), ["#4C8DFF", "#4C8DFF", "#8E8E93"])
    }

    func testRunningOverrideRecolorsOnlyRunningPill() {
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [runningEntry(), needsInputEntry(), idleEntry()],
            runningOverrideHex: "#22C55E",
            needsInputOverrideHex: nil,
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored[0].color, "#22C55E")
        XCTAssertEqual(recolored[1].color, "#4C8DFF")
        XCTAssertEqual(recolored[2].color, "#8E8E93")
    }

    func testNeedsInputOverrideDisambiguatesFromRunningDespiteSharedDefaultColor() {
        // running + needsInput share #4C8DFF and are told apart only by icon.
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [runningEntry(), needsInputEntry()],
            runningOverrideHex: nil,
            needsInputOverrideHex: "#F59E0B",
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored[0].color, "#4C8DFF", "Running must not be recolored by a needsInput override")
        XCTAssertEqual(recolored[1].color, "#F59E0B")
    }

    func testIdleOverrideRecolorsIdlePill() {
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [idleEntry()],
            runningOverrideHex: nil,
            needsInputOverrideHex: nil,
            idleOverrideHex: "#64748B"
        )
        XCTAssertEqual(recolored[0].color, "#64748B")
    }

    func testAppliesGenerallyAcrossAgentKeys() {
        // Not just Claude Code: codex, gemini, and any other detected agent use
        // the same built-in signature and must be recolored too.
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [runningEntry(key: "codex"), needsInputEntry(key: "gemini"), runningEntry(key: "omp")],
            runningOverrideHex: "#22C55E",
            needsInputOverrideHex: "#F59E0B",
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored[0].color, "#22C55E")
        XCTAssertEqual(recolored[1].color, "#F59E0B")
        XCTAssertEqual(recolored[2].color, "#22C55E")
    }

    func testCustomSetStatusColorIsPreserved() {
        // A pill the user recolored via `cmux set-status --color` does not match
        // the built-in signature, so the override never clobbers it (the race
        // the feature exists to remove).
        let custom = entry(key: "claude_code", value: "Running", icon: "bolt.fill", color: "#FF00AA")
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [custom],
            runningOverrideHex: "#22C55E",
            needsInputOverrideHex: nil,
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored[0].color, "#FF00AA")
    }

    func testEntryWithoutMatchingIconIsNotRecolored() {
        // Built-in default color but a non-lifecycle icon -> not a built-in pill.
        let other = entry(key: "claude_code", value: "Custom", icon: "star.fill", color: "#4C8DFF")
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [other],
            runningOverrideHex: "#22C55E",
            needsInputOverrideHex: "#F59E0B",
            idleOverrideHex: "#64748B"
        )
        XCTAssertEqual(recolored[0].color, "#4C8DFF")
    }

    func testSfPrefixedIconIsRecognized() {
        let prefixed = entry(key: "claude_code", value: "Running", icon: "sf:bolt.fill", color: "#4C8DFF")
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [prefixed],
            runningOverrideHex: "#22C55E",
            needsInputOverrideHex: nil,
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored[0].color, "#22C55E")
    }

    func testBuiltInColorIsCaseInsensitive() {
        // Detection writes uppercase, but guard against a lowercase write too.
        let lower = entry(key: "claude_code", value: "Running", icon: "bolt.fill", color: "#4c8dff")
        let recolored = SidebarAgentStateIndicatorColors.recolored(
            [lower],
            runningOverrideHex: "#22C55E",
            needsInputOverrideHex: nil,
            idleOverrideHex: nil
        )
        XCTAssertEqual(recolored[0].color, "#22C55E")
    }

    func testBuiltInStateSignatureMapping() {
        XCTAssertEqual(
            SidebarAgentStateIndicatorColors.builtInState(colorHex: "#4C8DFF", icon: "bolt.fill"),
            .running
        )
        XCTAssertEqual(
            SidebarAgentStateIndicatorColors.builtInState(colorHex: "#4C8DFF", icon: "bell.fill"),
            .needsInput
        )
        XCTAssertEqual(
            SidebarAgentStateIndicatorColors.builtInState(colorHex: "#8E8E93", icon: "pause.circle.fill"),
            .idle
        )
        XCTAssertNil(SidebarAgentStateIndicatorColors.builtInState(colorHex: nil, icon: "bolt.fill"))
        XCTAssertNil(SidebarAgentStateIndicatorColors.builtInState(colorHex: "#4C8DFF", icon: nil))
        XCTAssertNil(SidebarAgentStateIndicatorColors.builtInState(colorHex: "#123456", icon: "bolt.fill"))
    }

    // MARK: cmux.json -> managed UserDefaults parsing

    private static let backupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    private var preservedDefaultsKeys: [String] {
        [
            SidebarAgentStateIndicatorColors.runningColorKey,
            SidebarAgentStateIndicatorColors.needsInputColorKey,
            SidebarAgentStateIndicatorColors.idleColorKey,
            Self.backupsDefaultsKey,
            Self.importedManagedDefaultsKey,
        ]
    }

    private func withParsedConfig(_ json: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = preservedDefaultsKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in preservedDefaultsKeys { defaults.removeObject(forKey: key) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-state-indicator-colors-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("cmux.json", isDirectory: false)
        try? json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        try withExtendedLifetime(store) {
            try body(defaults)
        }
    }

    func testConfigPopulatesManagedDefaultsWithNormalizedHex() throws {
        try withParsedConfig(
            """
            {
              "sidebar": {
                "stateIndicatorColors": {
                  "running": "#22c55e",
                  "needsInput": "#f59e0b",
                  "idle": "#64748b"
                }
              }
            }
            """
        ) { defaults in
            XCTAssertEqual(defaults.string(forKey: SidebarAgentStateIndicatorColors.runningColorKey), "#22C55E")
            XCTAssertEqual(defaults.string(forKey: SidebarAgentStateIndicatorColors.needsInputColorKey), "#F59E0B")
            XCTAssertEqual(defaults.string(forKey: SidebarAgentStateIndicatorColors.idleColorKey), "#64748B")
        }
    }

    func testConfigAppliesOnlyProvidedStatesAndIgnoresInvalidHex() throws {
        try withParsedConfig(
            """
            {
              "sidebar": {
                "stateIndicatorColors": {
                  "running": "#22C55E",
                  "needsInput": "not-a-color"
                }
              }
            }
            """
        ) { defaults in
            // A valid sibling still applies even though needsInput is invalid,
            // and the unspecified idle state is left at its default (unset).
            XCTAssertEqual(defaults.string(forKey: SidebarAgentStateIndicatorColors.runningColorKey), "#22C55E")
            XCTAssertNil(defaults.string(forKey: SidebarAgentStateIndicatorColors.needsInputColorKey))
            XCTAssertNil(defaults.string(forKey: SidebarAgentStateIndicatorColors.idleColorKey))
        }
    }

    func testStateIndicatorColorsPathsAreSupported() {
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.stateIndicatorColors.running"))
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.stateIndicatorColors.needsInput"))
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.stateIndicatorColors.idle"))
    }
}
