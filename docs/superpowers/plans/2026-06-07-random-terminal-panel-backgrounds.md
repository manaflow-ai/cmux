# Random Terminal Panel Backgrounds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Workspace Colors setting that assigns each terminal panel a stable, full-host-layer random background color.

**Architecture:** Store a terminal-panel-local background hex on `TerminalSurface` and in `SessionTerminalPanelSnapshot`. Generate it from the existing workspace palette only when `workspaceColors.randomizeTerminalPanelBackgrounds` is enabled, then resolve it below explicit OSC 11 but above the default Ghostty background in `GhosttyNSView.applySurfaceBackground()`.

**Tech Stack:** Swift, SwiftUI, AppKit, UserDefaults-backed settings, JSON schema, XCTest, Xcode project file wiring.

---

## Files

- Modify `Sources/TabManager.swift`: add `RandomTerminalPanelBackgroundSettings` next to workspace color settings.
- Modify `Sources/KeyboardShortcutSettingsFileStore.swift`: parse `workspaceColors.randomizeTerminalPanelBackgrounds`.
- Modify `Sources/KeyboardShortcutSettingsFileStore+Template.swift`: include the default setting in generated `cmux.json`.
- Modify `Sources/CmuxSettingsJSONPathSupport.swift`: allow the managed config path.
- Modify `web/data/cmux.schema.json`: document and validate the config key.
- Modify `Sources/Windowing/WindowAppearanceSnapshot.swift`: let the fill plan distinguish explicit OSC 11 from randomized fallback.
- Modify `Sources/GhosttyTerminalView.swift`: add randomized panel background state and use it for host-layer background resolution.
- Modify `Sources/Panels/TerminalPanel.swift`: expose the surface background assignment through the panel wrapper.
- Modify `Sources/SessionPersistence.swift`: persist `randomizedPanelBackgroundHex`.
- Modify `Sources/Workspace.swift`: assign colors for new terminal panels, restore persisted colors, and include colors in session snapshots.
- Modify `Sources/cmuxApp.swift`: add the toggle under Workspace Colors.
- Modify `Sources/SettingsNavigation.swift` and `Sources/SettingsSearchAliases.swift`: add search anchor/path support.
- Modify `Resources/Localizable.xcstrings`: add English-localized strings for the new UI/search labels.
- Modify existing wired tests:
  - `cmuxTests/KeyboardShortcutSettingsFileStoreStartupTests.swift`
  - `cmuxTests/WindowAppearanceSnapshotTests.swift`
  - `cmuxTests/SessionPersistenceTests.swift`

## Task 1: Settings Parsing

**Files:**
- Test: `cmuxTests/KeyboardShortcutSettingsFileStoreStartupTests.swift`
- Modify: `Sources/TabManager.swift`
- Modify: `Sources/KeyboardShortcutSettingsFileStore.swift`
- Modify: `Sources/KeyboardShortcutSettingsFileStore+Template.swift`
- Modify: `Sources/CmuxSettingsJSONPathSupport.swift`
- Modify: `web/data/cmux.schema.json`

- [ ] **Step 1: Write the failing settings tests**

Add tests that prove default-off and config parsing:

```swift
func testRandomTerminalPanelBackgroundsDefaultOff() {
    let suiteName = "RandomTerminalPanelBackgrounds.Default.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.removeObject(forKey: RandomTerminalPanelBackgroundSettings.enabledKey)

    XCTAssertFalse(RandomTerminalPanelBackgroundSettings.isEnabled(defaults: defaults))
}

func testSettingsFileParsesRandomTerminalPanelBackgroundsEvenWhenPaletteIsPresent() throws {
    let key = RandomTerminalPanelBackgroundSettings.enabledKey
    try preservingDefaults(keys: [key, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: importedManagedDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "randomizeTerminalPanelBackgrounds": true,
                "colors": {
                  "Red": "#C0392B"
                }
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertTrue(defaults.bool(forKey: key))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/KeyboardShortcutSettingsFileStoreStartupTests/testRandomTerminalPanelBackgroundsDefaultOff -only-testing:cmuxTests/KeyboardShortcutSettingsFileStoreStartupTests/testSettingsFileParsesRandomTerminalPanelBackgroundsEvenWhenPaletteIsPresent
```

Expected: FAIL because `RandomTerminalPanelBackgroundSettings` does not exist.

- [ ] **Step 3: Implement minimal settings plumbing**

Add:

```swift
enum RandomTerminalPanelBackgroundSettings {
    static let enabledKey = "workspaceColors.randomizeTerminalPanelBackgrounds"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}
```

Parse the JSON key before the `workspaceColors.colors` early return:

```swift
if let value = jsonBool(section["randomizeTerminalPanelBackgrounds"]) {
    snapshot.managedUserDefaults[RandomTerminalPanelBackgroundSettings.enabledKey] = .bool(value)
}
```

Add the same key to the template, path allowlist, and schema.

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command. Expected: PASS.

## Task 2: Background Priority And Color Model

**Files:**
- Test: `cmuxTests/WindowAppearanceSnapshotTests.swift`
- Modify: `Sources/Windowing/WindowAppearanceSnapshot.swift`
- Modify: `Sources/GhosttyTerminalView.swift`

- [ ] **Step 1: Write failing priority tests**

Add tests proving explicit OSC 11 wins, randomized fallback paints host layer, and default remains shared:

```swift
func testRandomizedPanelBackgroundUsesSurfaceHostFillWhenNoOSCOverrideExists() {
    let plan = TerminalSurfaceBackgroundFillPlan.resolve(
        renderingMode: .windowHostBackdrop,
        explicitSurfaceBackgroundColor: nil,
        randomizedPanelBackgroundColor: NSColor(hex: "#123456")!,
        defaultBackgroundColor: NSColor(hex: "#272822")!,
        backgroundOpacity: 1.0,
        sharesWindowBackdrop: true,
        usesBonsplitPaneBackdrop: false
    )

    XCTAssertEqual(plan.owner, .surfaceHostLayer)
    XCTAssertEqual(plan.hostLayerColor.hexString(includeAlpha: true), "#123456FF")
    XCTAssertTrue(plan.clearsSharedWindowBackdrop)
    XCTAssertEqual(plan.logSource, "randomizedPanelBackground")
}

func testOSCOverrideWinsOverRandomizedPanelBackground() {
    let plan = TerminalSurfaceBackgroundFillPlan.resolve(
        renderingMode: .windowHostBackdrop,
        explicitSurfaceBackgroundColor: NSColor(hex: "#ABCDEF")!,
        randomizedPanelBackgroundColor: NSColor(hex: "#123456")!,
        defaultBackgroundColor: NSColor(hex: "#272822")!,
        backgroundOpacity: 1.0,
        sharesWindowBackdrop: true,
        usesBonsplitPaneBackdrop: false
    )

    XCTAssertEqual(plan.owner, .surfaceHostLayer)
    XCTAssertEqual(plan.hostLayerColor.hexString(includeAlpha: true), "#ABCDEFFF")
    XCTAssertEqual(plan.logSource, "surfaceOverride")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/WindowAppearanceSnapshotTests/testRandomizedPanelBackgroundUsesSurfaceHostFillWhenNoOSCOverrideExists -only-testing:cmuxTests/WindowAppearanceSnapshotTests/testOSCOverrideWinsOverRandomizedPanelBackground
```

Expected: FAIL because the new resolver signature and `logSource` field do not exist.

- [ ] **Step 3: Implement minimal priority model**

Change `TerminalSurfaceBackgroundFillPlan.resolve` to accept `explicitSurfaceBackgroundColor` and `randomizedPanelBackgroundColor`, compute `effectiveSurfaceBackgroundColor = explicitSurfaceBackgroundColor ?? randomizedPanelBackgroundColor`, and store `logSource`.

Keep old call sites compiling by updating them to pass `explicitSurfaceBackgroundColor: backgroundColor` and `randomizedPanelBackgroundColor: randomizedPanelBackgroundColor`.

- [ ] **Step 4: Run tests to verify pass**

Run the same `xcodebuild test` command. Expected: PASS.

## Task 3: Terminal Assignment And Persistence

**Files:**
- Test: `cmuxTests/SessionPersistenceTests.swift`
- Modify: `Sources/SessionPersistence.swift`
- Modify: `Sources/GhosttyTerminalView.swift`
- Modify: `Sources/Panels/TerminalPanel.swift`
- Modify: `Sources/Workspace.swift`

- [ ] **Step 1: Write failing persistence tests**

Add tests proving terminal snapshots persist random colors and browser panels do not:

```swift
@MainActor
func testWorkspaceSessionSnapshotPersistsRandomizedTerminalPanelBackground() throws {
    let workspace = Workspace()
    let panelId = try XCTUnwrap(workspace.focusedPanelId)
    let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
    terminalPanel.randomizedPanelBackgroundHex = "#123456"

    let snapshot = workspace.sessionSnapshot(includeScrollback: false)
    let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })

    XCTAssertEqual(panelSnapshot.terminal?.randomizedPanelBackgroundHex, "#123456")
}

@MainActor
func testWorkspaceSessionRestoreAppliesRandomizedTerminalPanelBackground() throws {
    let panelId = UUID()
    let panel = SessionPanelSnapshot(
        id: panelId,
        type: .terminal,
        title: "Terminal",
        customTitle: nil,
        directory: nil,
        isPinned: false,
        isManuallyUnread: false,
        listeningPorts: [],
        ttyName: nil,
        terminal: SessionTerminalPanelSnapshot(randomizedPanelBackgroundHex: "#654321"),
        browser: nil,
        markdown: nil,
        filePreview: nil,
        rightSidebarTool: nil
    )
    let snapshot = SessionWorkspaceSnapshot(
        processTitle: "Terminal",
        customTitle: nil,
        customDescription: nil,
        customColor: nil,
        isPinned: false,
        terminalScrollBarHidden: nil,
        currentDirectory: "/tmp",
        focusedPanelId: panelId,
        layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)),
        panels: [panel],
        statusEntries: [],
        logEntries: [],
        progress: nil,
        gitBranch: nil
    )

    let restored = Workspace()
    restored.restoreSessionSnapshot(snapshot)
    let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: panelId))

    XCTAssertEqual(restoredPanel.randomizedPanelBackgroundHex, "#654321")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/SessionPersistenceTests/testWorkspaceSessionSnapshotPersistsRandomizedTerminalPanelBackground -only-testing:cmuxTests/SessionPersistenceTests/testWorkspaceSessionRestoreAppliesRandomizedTerminalPanelBackground
```

Expected: FAIL because the snapshot and panel properties do not exist.

- [ ] **Step 3: Implement persistence**

Add `randomizedPanelBackgroundHex` to `SessionTerminalPanelSnapshot`, `TerminalSurface`, and `TerminalPanel`. Normalize with `WorkspaceTabColorSettings.normalizedHex`.

In `Workspace.sessionSnapshot`, pass `terminalPanel.randomizedPanelBackgroundHex`.

In terminal session restore, set `terminalPanel.randomizedPanelBackgroundHex = snapshot.terminal?.randomizedPanelBackgroundHex`.

- [ ] **Step 4: Run tests to verify pass**

Run the same `xcodebuild test` command. Expected: PASS.

## Task 4: Random Color Assignment

**Files:**
- Test: `cmuxTests/SessionPersistenceTests.swift`
- Modify: `Sources/TabManager.swift`
- Modify: `Sources/Workspace.swift`

- [ ] **Step 1: Write failing assignment test**

Add a test that enables the setting with a test suite and calls a helper directly:

```swift
func testRandomTerminalPanelBackgroundAssignmentUsesPaletteDeterministically() {
    let suiteName = "RandomTerminalPanelBackgroundSettings.Assign.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: RandomTerminalPanelBackgroundSettings.enabledKey)
    defaults.set(["Red": "#C0392B", "Blue": "#1565C0"], forKey: WorkspaceTabColorSettings.paletteKey)

    let color = RandomTerminalPanelBackgroundSettings.assignedHex(
        surfaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        existingHex: nil,
        defaults: defaults
    )

    XCTAssertNotNil(color)
    XCTAssertTrue(["#C0392B", "#1565C0"].contains(color!))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/SessionPersistenceTests/testRandomTerminalPanelBackgroundAssignmentUsesPaletteDeterministically
```

Expected: FAIL because `assignedHex` does not exist.

- [ ] **Step 3: Implement assignment helper and call it**

Add `assignedHex(surfaceId:existingHex:defaults:)` that returns existing normalized hex first, nil when disabled, and otherwise chooses from `WorkspaceTabColorSettings.palette(defaults:)` by stable UUID hash.

Call it from `Workspace.configureNewTerminalPanel(_:)` only when the panel has no persisted color.

- [ ] **Step 4: Run tests to verify pass**

Run the same `xcodebuild test` command. Expected: PASS.

## Task 5: UI, Search, Localization

**Files:**
- Modify: `Sources/cmuxApp.swift`
- Modify: `Sources/SettingsNavigation.swift`
- Modify: `Sources/SettingsSearchAliases.swift`
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Add UI strings and settings search entries**

Add English localization keys:

```text
settings.workspaceColors.terminalPanelBackgrounds
settings.workspaceColors.randomizeTerminalPanelBackgrounds
settings.workspaceColors.randomizeTerminalPanelBackgrounds.help
settings.search.alias.setting.workspaceColors.randomPanelBackgrounds
```

- [ ] **Step 2: Add toggle UI**

Add an `@AppStorage(RandomTerminalPanelBackgroundSettings.enabledKey)` Bool and a `GroupBox` under Workspace Colors:

```swift
GroupBox(String(localized: "settings.workspaceColors.terminalPanelBackgrounds", defaultValue: "Terminal Panel Backgrounds")) {
    VStack(alignment: .leading, spacing: 8) {
        Toggle(String(localized: "settings.workspaceColors.randomizeTerminalPanelBackgrounds", defaultValue: "Randomize Terminal Panel Backgrounds"), isOn: $randomizeTerminalPanelBackgrounds)
        Text(String(localized: "settings.workspaceColors.randomizeTerminalPanelBackgrounds.help", defaultValue: "Assign a stable palette color to each terminal panel. Explicit terminal background changes still take priority."))
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding(.top, 2)
}
.settingsSearchAnchor(SettingsSearchIndex.settingID(for: .workspaceColors, idSuffix: "random-panel-backgrounds"))
```

- [ ] **Step 3: Validate localization JSON**

Run:

```bash
python3 -m json.tool Resources/Localizable.xcstrings >/tmp/cmux-localizable-check.json
```

Expected: command exits 0.

## Task 6: Verification

**Files:**
- All touched files.

- [ ] **Step 1: Run targeted tests**

Run:

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/KeyboardShortcutSettingsFileStoreStartupTests -only-testing:cmuxTests/WindowAppearanceSnapshotTests -only-testing:cmuxTests/SessionPersistenceTests
```

Expected: PASS.

- [ ] **Step 2: Run build with tagged Debug app**

Run:

```bash
./scripts/reload.sh --tag random-panel-bg
```

Expected: build succeeds and prints an `App path:` line. Do not launch the user's production cmux.

- [ ] **Step 3: Run lightweight diff checks**

Run:

```bash
git diff --check
python3 -m json.tool Resources/Localizable.xcstrings >/tmp/cmux-localizable-check.json
git status --short
```

Expected: no whitespace errors, localization JSON parses, and only feature-related files are changed.
