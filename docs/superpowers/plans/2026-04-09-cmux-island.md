# cmux Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the MVP of a notch-anchored Dynamic Island overlay inside `cmux.app` that lists active AI-agent sessions detected from `cmux set-status` entries and lets the user click a row to jump to the corresponding workspace + panel.

**Architecture:** New in-process module at `Sources/Island/` behind an `IslandStateProvider` seam. Pure-data projection (`IslandStateStore`) subscribes to `TabManager.tabs` and each `Workspace.statusEntries` + `TerminalNotificationStore`, then feeds a SwiftUI `IslandRootView` hosted in an `NSPanel` above the menu bar. Opt-in via a new `island.enabled` setting mirrored in `~/.config/cmux/settings.json` through the existing `CmuxSettingsFileStore`. Jump routing reuses `TabManager.selectWorkspace` + `Workspace.focusPanel`.

**Tech Stack:** Swift 5.9+, SwiftUI, Combine, AppKit (`NSPanel`, `NSHostingView`), `XCTest`, cmux's existing `CmuxSettingsFileStore` settings pipeline.

**Reference spec:** [`docs/superpowers/specs/2026-04-09-cmux-island-design.md`](../specs/2026-04-09-cmux-island-design.md)

**Reference source (Apache 2.0 port):** [`farouqaldori/claude-island`](https://github.com/farouqaldori/claude-island) — only `NotchShape.swift`, `NotchWindow.swift` mechanics, and the NSPanel configuration get ported. Hook infrastructure, session monitor, and socket server are **not** ported.

---

## Deviations from the spec

Two minor deviations discovered during project exploration — both fine to apply silently, but documented here so the executor knows:

1. **Settings integration file.** The spec §7.1 says "`CmuxConfig.swift` gains an `IslandConfigSection`". The correct integration point is actually `Sources/KeyboardShortcutSettingsFileStore.swift` — `CmuxConfig.swift` reads `cmux.json` (custom commands), while `CmuxSettingsFileStore` (inside `KeyboardShortcutSettingsFileStore.swift`) reads `~/.config/cmux/settings.json`. Use the latter.
2. **Test directory structure.** The spec §8.1 writes `cmuxTests/Island/`. The existing `cmuxTests/` directory is flat (no subdirectories). Place test files flat under `cmuxTests/` with `Island` prefixed filenames (e.g., `cmuxTests/IslandSessionPhaseTests.swift`).

---

## File Structure

**New files under `Sources/Island/`:**

| File | Responsibility |
|---|---|
| `IslandSettings.swift` | Static `UserDefaults` key + default for `island.enabled`; matches the existing `*Settings` struct pattern (`NotificationBadgeSettings`, `CursorIntegrationSettings`, etc.). |
| `IslandSession.swift` | Value types: `IslandAgentKind`, `IslandSessionPhase`, `IslandSession`, plus `IslandSessionPhase.from(rawValue:)`, `IslandSession.phaseRank`, and the sort comparator. No UI, no Combine. |
| `IslandStateProvider.swift` | Downstream interface (what the view observes) + upstream `IslandStateSource` protocol (what the store subscribes to). Plus `InMemoryIslandStateSource` used by tests and the debug-window inject path. |
| `IslandStateStore.swift` | Concrete `IslandStateProvider` built from an `IslandStateSource`; performs the Workspace → `[IslandSession]` projection, dedup, sort, visibility derivation. Includes `TabManagerIslandStateSource` that wraps the live `TabManager`. |
| `IslandFocusSink.swift` | Protocol describing the four things `IslandJumpRouter` needs to do: activate app, select workspace by id, focus panel by id, collapse the island. Plus `TabManagerIslandFocusSink` — the production implementation that calls the real `TabManager` / `Workspace` APIs. |
| `IslandJumpRouter.swift` | Small router that translates `jump(to: IslandSession)` into a fixed sequence of `IslandFocusSink` calls. Logs and collapses on error. |
| `NotchShape.swift` | SwiftUI `Shape` with inward-top/outward-bottom quadratic corners. Port of `farouqaldori/claude-island`'s `NotchShape.swift` (Apache 2.0, keep the original license header comment). |
| `NotchPanel.swift` | `NSPanel` subclass configured as a non-activating, click-through, all-spaces floating panel above the menu bar. Port of `farouqaldori/claude-island`'s `NotchWindow.swift` (Apache 2.0, keep the license header). |
| `IslandRootView.swift` | SwiftUI view with closed-pill + expanded-list states, spring animations, click-to-expand, click-outside-to-close. Observes `IslandStateProvider.sessions`. |
| `IslandWindowController.swift` | `NSWindowController` that owns one `NotchPanel`, wires an `IslandRootView` into it via `NSHostingView`, positions on the notch screen, and `orderFront`/`orderOut`s based on `sessions.isEmpty`. |

**Files modified:**

| File | What changes |
|---|---|
| `Sources/KeyboardShortcutSettingsFileStore.swift` | Add `"island.enabled"` to `supportedSettingsJSONPaths`; add `parseIslandSection(…)`; add dispatch for it in the root parser. |
| `Sources/AppDelegate.swift` | Own an optional `IslandWindowController` and a `Cancellable`; observe `@AppStorage("island.enabled")` and create/destroy the controller. |
| `Sources/cmuxApp.swift` | Add `SettingsSectionHeader` + `SettingsCard` for "Island" inside `SettingsView`. Add `Button("Island Controller…")` to the Debug Windows menu. Add the `IslandControllerDebugWindowController` NSWindowController near the other debug window singletons. |
| `Resources/Localizable.xcstrings` | Add all `island.*` keys (English + Japanese). |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Register each new Swift file in the Sources group, PBXFileReference, PBXBuildFile, and PBXSourcesBuildPhase. |
| `CHANGELOG.md` | Add a line under the unreleased section. |

**Files created under `cmuxTests/`:**

| File | Contains |
|---|---|
| `cmuxTests/IslandSessionPhaseTests.swift` | Tests for `IslandSessionPhase.from(rawValue:)`. |
| `cmuxTests/IslandSessionSortTests.swift` | Tests for the sort comparator. |
| `cmuxTests/IslandStateStoreTests.swift` | Tests for `IslandStateStore` projection + visibility using `InMemoryIslandStateSource`. |
| `cmuxTests/IslandJumpRouterTests.swift` | Tests for `IslandJumpRouter` using a spy `IslandFocusSink`. |
| `cmuxTests/IslandSettingsFileStoreTests.swift` | Round-trip test: `island.enabled` in `settings.json` → `UserDefaults` → read-back. |

---

## Task 1: Wire `island.enabled` into the settings file store (no UI yet)

**Why first:** Everything else keys off of `island.enabled`. Getting the settings-file parser, the whitelist, and the `UserDefaults` key in place up front means every later task can just read `@AppStorage(IslandSettings.enabledKey)` without retrofitting.

**Files:**
- Create: `Sources/Island/IslandSettings.swift`
- Modify: `Sources/KeyboardShortcutSettingsFileStore.swift`
- Create: `cmuxTests/IslandSettingsFileStoreTests.swift`

- [ ] **Step 1: Create `IslandSettings.swift`**

```swift
// Sources/Island/IslandSettings.swift

import Foundation

/// Preference keys and defaults for the cmux Island module.
///
/// Matches the existing `*Settings` struct pattern in cmux (see
/// `NotificationBadgeSettings`, `CursorIntegrationSettings`, etc.).
enum IslandSettings {
    /// UserDefaults / @AppStorage key for the island enable toggle.
    static let enabledKey: String = "island.enabled"

    /// Default is OFF per the MVP design.
    static let defaultEnabled: Bool = false
}
```

- [ ] **Step 2: Write the failing round-trip test**

```swift
// cmuxTests/IslandSettingsFileStoreTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Verifies that writing `island.enabled` into a settings.json snapshot
/// results in the parser setting the `IslandSettings.enabledKey` managed
/// default — so editing the file is equivalent to flipping the UI toggle.
final class IslandSettingsFileStoreTests: XCTestCase {

    private func snapshot(from json: String) throws -> ResolvedSettingsSnapshot {
        // CmuxSettingsFileStore exposes a parser entry point via the
        // resolveSnapshot(from:sourcePath:) helper defined next to
        // parseRootObject. This test uses the same harness that the
        // existing KeyboardShortcutSettingsFileStore tests use.
        return try CmuxSettingsFileStore.testResolveSnapshot(jsonString: json)
    }

    func testIslandEnabledTrueIsWrittenToManagedDefaults() throws {
        let json = """
        {
          "island": { "enabled": true }
        }
        """
        let snap = try snapshot(from: json)
        XCTAssertEqual(
            snap.managedUserDefaults[IslandSettings.enabledKey],
            .bool(true)
        )
    }

    func testIslandEnabledFalseIsWrittenToManagedDefaults() throws {
        let json = """
        {
          "island": { "enabled": false }
        }
        """
        let snap = try snapshot(from: json)
        XCTAssertEqual(
            snap.managedUserDefaults[IslandSettings.enabledKey],
            .bool(false)
        )
    }

    func testIslandSectionMissingLeavesManagedDefaultsEmpty() throws {
        let json = "{}"
        let snap = try snapshot(from: json)
        XCTAssertNil(snap.managedUserDefaults[IslandSettings.enabledKey])
    }

    func testIslandEnabledPathIsWhitelisted() {
        XCTAssertTrue(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("island.enabled")
        )
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `xcodebuild -scheme cmux-unit -only-testing:cmuxTests/IslandSettingsFileStoreTests test 2>&1 | tail -30`

(Per CLAUDE.md "Testing policy": **do not run tests locally** on regular development flow; however, this step is only to verify the *compile-and-fail* point. If `xcodebuild` is too heavy locally, verify by running the tests in CI via `gh workflow run test-e2e.yml` or by compiling-only: `xcodebuild -scheme cmux-unit build 2>&1 | tail -30` and confirming the compiler points at `island.enabled`, `parseIslandSection`, `IslandSettings` not defined.)

Expected: FAIL — `CmuxSettingsFileStore.testResolveSnapshot(jsonString:)` / `supportedSettingsJSONPaths` lookup returns nothing for `island.enabled`, and `IslandSettings.enabledKey` may not yet be visible to tests because `Island/IslandSettings.swift` isn't in the Xcode target yet (resolved by Task 20).

- [ ] **Step 4: Add the parser + whitelist entry**

Open `Sources/KeyboardShortcutSettingsFileStore.swift` and make three edits.

**Edit A** — add the JSON path to the whitelist. Find the `supportedSettingsJSONPaths` set (around line 27–92) and add `"island.enabled",` in alphabetical position (right after `"customCommands.trustedDirectories",`):

```swift
        "customCommands.trustedDirectories",
        "island.enabled",
        "browser.defaultSearchEngine",
```

Wait — `browser` comes before `customCommands` alphabetically, and `island` comes after both. The correct insertion is after the last `customCommands.*` entry and before the first `browser.*` entry is wrong alphabetically; the existing list is grouped by section name, not strictly alphabetical. Insert `"island.enabled",` in its own line **between the `customCommands` group and the `browser` group** (which matches the existing grouping style).

**Edit B** — add a dispatch call in the root parser. Find the block around line 350–378 that calls `parseAppSection`, `parseNotificationsSection`, …, `parseShortcutsSection`. After the `customCommandsSection` branch and before `browserSection`, add:

```swift
        if let islandSection = root["island"] as? [String: Any] {
            parseIslandSection(islandSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
```

**Edit C** — add the new `parseIslandSection(…)` method next to the other `parse*Section` methods (any location in the same file is fine; group with the other small parsers):

```swift
    private func parseIslandSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["enabled"]) {
            snapshot.managedUserDefaults[IslandSettings.enabledKey] = .bool(value)
        }
    }
```

- [ ] **Step 5: Expose a test entry point (only if one doesn't already exist)**

`CmuxSettingsFileStore` likely has an internal `parseRootObject` that's not testable directly. Add a DEBUG-only static helper at the end of the class so the test can drive the parser without touching disk. Place this inside `final class CmuxSettingsFileStore`:

```swift
#if DEBUG
    static func testResolveSnapshot(jsonString: String, sourcePath: String = "test.json") throws -> ResolvedSettingsSnapshot {
        guard let data = jsonString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CmuxSettingsFileStoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]
            )
        }
        return CmuxSettingsFileStore().parseRootObject(root, sourcePath: sourcePath)
    }
#endif
```

If `parseRootObject` has a different name in the current file, use that name instead. If `parseRootObject` is `private`, change it to `fileprivate` or `internal` for DEBUG builds only via `#if DEBUG internal #else private #endif`. The simplest fix: duplicate the parser body inline inside `testResolveSnapshot`.

- [ ] **Step 6: Re-run the tests to verify they pass**

Build via CI or `xcodebuild -scheme cmux-unit build` to confirm the module compiles. (Tests themselves run in CI per CLAUDE.md — do not run them locally.) Expected: compiles cleanly, no references to missing symbols.

- [ ] **Step 7: Commit**

```bash
git add Sources/Island/IslandSettings.swift \
        Sources/KeyboardShortcutSettingsFileStore.swift \
        cmuxTests/IslandSettingsFileStoreTests.swift
git commit -m "$(cat <<'EOF'
Add island.enabled setting key and settings.json parser (#2590)

Introduces IslandSettings.enabledKey as the single source of truth for
the cmux Island opt-in toggle, and teaches CmuxSettingsFileStore to
read an "island" section from ~/.config/cmux/settings.json. Tests cover
the round-trip parser path and the path whitelist.

First commit of the cmux Island MVP. Spec:
docs/superpowers/specs/2026-04-09-cmux-island-design.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Core value types (`IslandAgentKind`, `IslandSessionPhase`, `IslandSession`)

**Files:**
- Create: `Sources/Island/IslandSession.swift`
- Create: `cmuxTests/IslandSessionPhaseTests.swift`

- [ ] **Step 1: Write the failing phase normalization test**

```swift
// cmuxTests/IslandSessionPhaseTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class IslandSessionPhaseTests: XCTestCase {

    func testRunningSynonyms() {
        let inputs = ["running", "Running", "RUNNING",
                      "running_tool", "processing", "starting", " running "]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .running,
                "Expected .running for \(input)"
            )
        }
    }

    func testIdleSynonyms() {
        let inputs = ["idle", "Idle", "IDLE", "", "  ", "ready"]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .idle,
                "Expected .idle for \(input)"
            )
        }
    }

    func testWaitingSynonyms() {
        let inputs = ["waiting", "waiting_for_input", "needs_input", "needsinput", "NeedsInput"]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .waiting,
                "Expected .waiting for \(input)"
            )
        }
    }

    func testErrorSynonyms() {
        let inputs = ["error", "Error", "failed", "Failure"]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .error,
                "Expected .error for \(input)"
            )
        }
    }

    func testUnknownFallsThrough() {
        for input in ["compacting", "queued", "💤", "hello world"] {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .unknown,
                "Expected .unknown for \(input)"
            )
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Build only: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: compile error — `IslandSessionPhase` unknown.

- [ ] **Step 3: Create `IslandSession.swift` with all value types**

```swift
// Sources/Island/IslandSession.swift

import Foundation
import SwiftUI

/// Known AI-agent kinds the cmux Island monitors.
///
/// A terminal panel counts as an active island session iff its
/// `Workspace.statusEntries` contains at least one entry whose key equals
/// one of these raw values. Agent hooks in `docs/notifications.md` already
/// use these keys.
enum IslandAgentKind: String, CaseIterable, Hashable, Sendable {
    case claudeCode = "claude_code"
    case codex      = "codex"
    case copilotCli = "copilot_cli"
    case openCode   = "opencode"
    case geminiCli  = "gemini_cli"
    case cursor     = "cursor"
    case amp        = "amp"
    case droid      = "droid"

    /// Human-readable name shown in the expanded island row.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .copilotCli: return "Copilot CLI"
        case .openCode:   return "OpenCode"
        case .geminiCli:  return "Gemini CLI"
        case .cursor:     return "Cursor"
        case .amp:        return "Amp"
        case .droid:      return "Droid"
        }
    }

    /// Single-character monogram used in the 20pt row chip.
    var monogram: String {
        switch self {
        case .claudeCode: return "C"
        case .codex:      return "X"
        case .copilotCli: return "G"
        case .openCode:   return "O"
        case .geminiCli:  return "V"
        case .cursor:     return "U"
        case .amp:        return "A"
        case .droid:      return "D"
        }
    }

    /// Stable brand-ish color for the row chip and collapsed-pill legend.
    var color: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.02)  // Claude orange
        case .codex:      return Color(red: 0.23, green: 0.51, blue: 0.96)  // Codex blue
        case .copilotCli: return Color(red: 0.55, green: 0.36, blue: 0.96)  // Copilot purple
        case .openCode:   return Color(red: 0.20, green: 0.72, blue: 0.45)  // OpenCode green
        case .geminiCli:  return Color(red: 0.40, green: 0.66, blue: 0.95)  // Gemini light blue
        case .cursor:     return Color(red: 0.90, green: 0.90, blue: 0.90)  // Cursor gray
        case .amp:        return Color(red: 0.90, green: 0.26, blue: 0.36)  // Amp red
        case .droid:      return Color(red: 0.99, green: 0.81, blue: 0.24)  // Droid yellow
        }
    }
}

/// Normalized session phase. Free-form `cmux set-status` values are mapped
/// into this small closed set via `IslandSessionPhase.from(rawValue:)`.
enum IslandSessionPhase: String, Hashable, Sendable {
    case running
    case idle
    case waiting
    case error
    case unknown

    /// Sort precedence for the island list: lower comes first.
    /// Running beats waiting beats error beats idle beats unknown.
    var rank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .error:   return 2
        case .idle:    return 3
        case .unknown: return 4
        }
    }

    /// Case-insensitive, trim-tolerant lookup from a free-form status value.
    static func from(rawValue: String) -> IslandSessionPhase {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "running", "running_tool", "processing", "starting":
            return .running
        case "", "idle", "ready":
            return .idle
        case "waiting", "waiting_for_input", "needs_input", "needsinput":
            return .waiting
        case "error", "failed", "failure":
            return .error
        default:
            return .unknown
        }
    }
}

/// One row in the cmux Island. Immutable value type; a fresh instance is
/// emitted whenever the upstream state changes.
struct IslandSession: Identifiable, Equatable, Sendable {
    /// Stable identity equal to `panelId` — a single panel hosts at most one
    /// session in MVP scope.
    let id: UUID
    let workspaceId: UUID
    let panelId: UUID
    let agentKind: IslandAgentKind
    let phase: IslandSessionPhase
    let workspaceTitle: String
    let panelTitle: String
    let lastActivity: Date
    let unreadCount: Int
    /// Original free-form status value kept for debug/tooltip inspection.
    let rawStatusValue: String
}

extension IslandSession {
    /// Standard sort comparator. Running first, recent first on ties.
    static func < (lhs: IslandSession, rhs: IslandSession) -> Bool {
        if lhs.phase.rank != rhs.phase.rank {
            return lhs.phase.rank < rhs.phase.rank
        }
        return lhs.lastActivity > rhs.lastActivity
    }
}
```

- [ ] **Step 4: Build to verify phase tests pass**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly. (Test execution deferred to CI.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Island/IslandSession.swift cmuxTests/IslandSessionPhaseTests.swift
git commit -m "$(cat <<'EOF'
Add IslandAgentKind, IslandSessionPhase, IslandSession value types (#2590)

Core data types for the cmux Island MVP. Phase normalization is
table-driven and table-tested; sort comparator + rank prepared for the
upcoming store.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Sort-order tests

**Files:**
- Create: `cmuxTests/IslandSessionSortTests.swift`

- [ ] **Step 1: Write the sort tests**

```swift
// cmuxTests/IslandSessionSortTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class IslandSessionSortTests: XCTestCase {

    private func make(
        phase: IslandSessionPhase,
        lastActivity: Date = Date(timeIntervalSince1970: 0)
    ) -> IslandSession {
        IslandSession(
            id: UUID(),
            workspaceId: UUID(),
            panelId: UUID(),
            agentKind: .claudeCode,
            phase: phase,
            workspaceTitle: "w",
            panelTitle: "p",
            lastActivity: lastActivity,
            unreadCount: 0,
            rawStatusValue: "x"
        )
    }

    func testPhasePrecedence() {
        let unknown = make(phase: .unknown)
        let idle    = make(phase: .idle)
        let error   = make(phase: .error)
        let waiting = make(phase: .waiting)
        let running = make(phase: .running)

        let sorted = [unknown, idle, error, waiting, running].sorted(by: <)
        XCTAssertEqual(sorted.map(\.phase), [.running, .waiting, .error, .idle, .unknown])
    }

    func testRecentActivityBreaksTies() {
        let older  = make(phase: .running, lastActivity: Date(timeIntervalSince1970: 100))
        let newer  = make(phase: .running, lastActivity: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(newer < older, "Newer running session should come first")
    }

    func testTiesBetweenDifferentPhasesStillRespectPhaseRank() {
        let runningOld = make(phase: .running, lastActivity: Date(timeIntervalSince1970: 100))
        let waitingNew = make(phase: .waiting, lastActivity: Date(timeIntervalSince1970: 999))
        XCTAssertTrue(runningOld < waitingNew, "Phase rank beats recency across different phases")
    }
}
```

- [ ] **Step 2: Verify it builds (already implemented in Task 2)**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly. The comparator from Task 2 already satisfies the asserts.

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/IslandSessionSortTests.swift
git commit -m "$(cat <<'EOF'
Add IslandSession sort comparator tests (#2590)

Pins the sort order (running → waiting → error → idle → unknown,
tie-break by most recent activity) against regressions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `IslandStateProvider` protocol + `InMemoryIslandStateSource`

**Files:**
- Create: `Sources/Island/IslandStateProvider.swift`

- [ ] **Step 1: Create the protocol file**

```swift
// Sources/Island/IslandStateProvider.swift

import Combine
import Foundation

/// Downstream interface the island SwiftUI view depends on.
///
/// The view observes `sessionsPublisher` and re-renders whenever it emits.
/// Keeping the view's only dependency on this protocol is what lets the
/// production store be swapped for an in-memory fake (tests + debug menu)
/// or a future `SocketIslandStateProvider` (Phase 3 companion app).
protocol IslandStateProvider: AnyObject {
    /// Emits the current flat, sorted list of active agent sessions.
    /// Empty list means the island should be hidden.
    var sessionsPublisher: AnyPublisher<[IslandSession], Never> { get }

    /// Snapshot of the most recent emission, for callers that need a pull
    /// API alongside the publisher.
    var currentSessions: [IslandSession] { get }
}

// MARK: - Upstream source (the store's input)

/// Upstream interface. The store subscribes to a single "tick" publisher
/// that fires whenever any of (workspace list, per-workspace status entries,
/// per-panel notifications) change, and the store pulls a fresh snapshot.
///
/// This is deliberately narrower than `TabManager` so the store is testable
/// with an in-memory fake that doesn't need Workspace/TabManager at all.
protocol IslandStateSource: AnyObject {
    /// Fires whenever anything relevant to the projection changes.
    var changes: AnyPublisher<Void, Never> { get }

    /// Pull a fresh `[IslandSession]` snapshot. Must be callable on the
    /// main actor — sources that read AppKit state should hop internally.
    @MainActor
    func makeSnapshot() -> [IslandSession]
}

// MARK: - In-memory source for tests and debug injection

final class InMemoryIslandStateSource: IslandStateSource {
    private let subject = PassthroughSubject<Void, Never>()

    @MainActor
    private(set) var sessions: [IslandSession] = [] {
        didSet { subject.send(()) }
    }

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    @MainActor
    func makeSnapshot() -> [IslandSession] { sessions }

    @MainActor
    func set(_ sessions: [IslandSession]) {
        self.sessions = sessions
    }

    @MainActor
    func add(_ session: IslandSession) {
        sessions.append(session)
    }

    @MainActor
    func clear() {
        sessions.removeAll()
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Island/IslandStateProvider.swift
git commit -m "$(cat <<'EOF'
Add IslandStateProvider + IslandStateSource protocols (#2590)

Defines the two protocols that bound the island's read path:
IslandStateProvider is what the view observes; IslandStateSource is
what the store subscribes to. Includes InMemoryIslandStateSource for
tests and the debug-menu inject path.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `IslandStateStore` with projection + tests (using the in-memory source)

**Files:**
- Create: `Sources/Island/IslandStateStore.swift`
- Create: `cmuxTests/IslandStateStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// cmuxTests/IslandStateStoreTests.swift

import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class IslandStateStoreTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    private func makeSession(
        phase: IslandSessionPhase = .running,
        kind: IslandAgentKind = .claudeCode,
        lastActivity: Date = Date(timeIntervalSince1970: 100),
        unread: Int = 0
    ) -> IslandSession {
        IslandSession(
            id: UUID(),
            workspaceId: UUID(),
            panelId: UUID(),
            agentKind: kind,
            phase: phase,
            workspaceTitle: "ws",
            panelTitle: "p",
            lastActivity: lastActivity,
            unreadCount: unread,
            rawStatusValue: phase.rawValue
        )
    }

    func testEmptySourceEmitsEmptyList() {
        let source = InMemoryIslandStateSource()
        let store = IslandStateStore(source: source)
        XCTAssertEqual(store.currentSessions, [])
    }

    func testSingleSessionIsEmitted() {
        let source = InMemoryIslandStateSource()
        let store = IslandStateStore(source: source)

        var received: [[IslandSession]] = []
        let exp = expectation(description: "emit once")
        exp.expectedFulfillmentCount = 1

        store.sessionsPublisher
            .dropFirst()  // skip initial empty
            .sink { sessions in
                received.append(sessions)
                exp.fulfill()
            }
            .store(in: &cancellables)

        let s = makeSession()
        source.set([s])

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received.last?.count, 1)
        XCTAssertEqual(received.last?.first?.id, s.id)
    }

    func testSortOrderRunningBeforeIdle() {
        let source = InMemoryIslandStateSource()
        let store = IslandStateStore(source: source)
        let idle    = makeSession(phase: .idle)
        let running = makeSession(phase: .running)
        source.set([idle, running])

        let snapshot = store.currentSessions
        XCTAssertEqual(snapshot.map(\.phase), [.running, .idle])
    }

    func testClearingSourceEmitsEmpty() {
        let source = InMemoryIslandStateSource()
        source.set([makeSession()])
        let store = IslandStateStore(source: source)
        XCTAssertEqual(store.currentSessions.count, 1)
        source.clear()
        XCTAssertEqual(store.currentSessions, [])
    }
}
```

- [ ] **Step 2: Run the build to confirm the tests don't compile yet**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: compile error — `IslandStateStore` unknown.

- [ ] **Step 3: Create the store**

```swift
// Sources/Island/IslandStateStore.swift

import Combine
import Foundation

/// Concrete `IslandStateProvider` that projects an `IslandStateSource` into
/// a sorted, debounced `[IslandSession]` publisher the view observes.
///
/// The store itself does no model reading — all data comes via the source,
/// which is either the production `TabManagerIslandStateSource` (this file)
/// or a test/debug fake.
@MainActor
final class IslandStateStore: IslandStateProvider, ObservableObject {

    private let source: IslandStateSource
    private let subject: CurrentValueSubject<[IslandSession], Never>
    private var cancellable: AnyCancellable?

    init(source: IslandStateSource) {
        self.source = source
        let initial = source.makeSnapshot().sorted(by: <)
        self.subject = CurrentValueSubject(initial)

        // Debounce 50ms so back-to-back set-status/notify bursts coalesce.
        self.cancellable = source.changes
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let snapshot = self.source.makeSnapshot().sorted(by: <)
                self.subject.send(snapshot)
            }
    }

    var sessionsPublisher: AnyPublisher<[IslandSession], Never> {
        subject.eraseToAnyPublisher()
    }

    var currentSessions: [IslandSession] {
        subject.value
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 5: Note about the debounce and the tests**

The 50ms debounce means the "emit once" test could be flaky if expectations run too fast. Update the test to allow up to 2 seconds timeout (already `1.0` — bump to `2.0` if CI flakes appear). Do not remove the debounce — it's a production requirement.

If the CI test flakes, adjust the `wait(for:timeout:)` in `testSingleSessionIsEmitted` to `2.0` only as a follow-up, not now.

- [ ] **Step 6: Commit**

```bash
git add Sources/Island/IslandStateStore.swift cmuxTests/IslandStateStoreTests.swift
git commit -m "$(cat <<'EOF'
Add IslandStateStore with source-driven projection (#2590)

Debounced Combine pipeline that resorts and republishes the session
list whenever the upstream IslandStateSource ticks. Tests exercise
projection, sort order, and empty-state transitions via
InMemoryIslandStateSource.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `TabManagerIslandStateSource` — the production source

**Why this task:** Task 5 proved the projection/sort logic. Now we connect it to real cmux state. Kept separate because the Combine wiring here is fiddly (nested `@Published` subscriptions) and does not benefit from a test — it's a pure adapter.

**Files:**
- Modify: `Sources/Island/IslandStateStore.swift`

- [ ] **Step 1: Append the production source to the store file**

Add this class **at the bottom** of `Sources/Island/IslandStateStore.swift` (below `IslandStateStore`):

```swift
// MARK: - Production source wrapping TabManager

/// Production `IslandStateSource` that subscribes to every `Workspace`
/// inside a `TabManager` and emits `changes` whenever any relevant state
/// updates. Reads `TerminalNotificationStore.shared` for unread counts.
///
/// Deliberately isolated in one file so the `Sources/Island/` module has
/// exactly one symbol that imports cmux core types.
@MainActor
final class TabManagerIslandStateSource: IslandStateSource {

    private let tabManager: TabManager
    private let subject = PassthroughSubject<Void, Never>()
    private var tabsCancellable: AnyCancellable?
    private var perWorkspaceCancellables: [UUID: Set<AnyCancellable>] = [:]
    private var notificationCancellable: AnyCancellable?

    init(tabManager: TabManager) {
        self.tabManager = tabManager

        // 1. Any change to the tabs array → rebuild per-workspace subscriptions
        //    and fire a change tick.
        tabsCancellable = tabManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                self?.resubscribe(to: tabs)
                self?.subject.send(())
            }

        // 2. Notifications (unread counts) tick.
        notificationCancellable = TerminalNotificationStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.subject.send(())
            }
    }

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    @MainActor
    func makeSnapshot() -> [IslandSession] {
        var out: [IslandSession] = []
        let knownKeys = Set(IslandAgentKind.allCases.map(\.rawValue))
        let store = TerminalNotificationStore.shared

        for workspace in tabManager.tabs {
            // Group status entries by panelId (status entries can target a
            // specific panel via their `tab=` option; fall back to the
            // workspace's focused panel if none given — MVP accepts a soft
            // fallback since the existing set-status CLI already binds
            // entries to the workspace on write).
            let matching = workspace.statusEntries.filter { knownKeys.contains($0.key) }
            guard !matching.isEmpty else { continue }

            // Pick the winner per §5.2: highest numeric priority, ties
            // broken by most recent timestamp.
            let winner = matching.values
                .sorted { lhs, rhs in
                    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                    return lhs.timestamp > rhs.timestamp
                }
                .first!

            guard let kind = IslandAgentKind(rawValue: winner.key) else { continue }

            // Session binds to workspace's currently focused panel, or the
            // first panel if none is focused. This is good enough for MVP;
            // panel-specific set-status --tab resolution is Phase 2.
            guard let panelId = workspace.focusedPanelId
                ?? workspace.panels.keys.first else { continue }

            let workspaceTitle = workspace.customTitle ?? workspace.title
            let panelTitle = workspace.panelCustomTitles[panelId]
                ?? workspace.panelTitles[panelId]
                ?? workspace.panels[panelId]?.displayTitle
                ?? "panel"

            // Unread count per panel — ask the store; default 0 on unknown panels.
            let unread = store.unreadCount(forPanelId: panelId)

            out.append(
                IslandSession(
                    id: panelId,
                    workspaceId: workspace.id,
                    panelId: panelId,
                    agentKind: kind,
                    phase: IslandSessionPhase.from(rawValue: winner.value),
                    workspaceTitle: workspaceTitle,
                    panelTitle: panelTitle,
                    lastActivity: winner.timestamp,
                    unreadCount: unread,
                    rawStatusValue: winner.value
                )
            )
        }
        return out
    }

    // MARK: - Private

    private func resubscribe(to tabs: [Workspace]) {
        let presentIds = Set(tabs.map(\.id))

        // Drop observers for removed workspaces.
        let removed = Set(perWorkspaceCancellables.keys).subtracting(presentIds)
        for id in removed { perWorkspaceCancellables.removeValue(forKey: id) }

        // Add observers for new workspaces.
        for tab in tabs where perWorkspaceCancellables[tab.id] == nil {
            var bag = Set<AnyCancellable>()

            tab.$statusEntries
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$panelTitles
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            tab.$panels
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.subject.send(()) }
                .store(in: &bag)

            perWorkspaceCancellables[tab.id] = bag
        }
    }
}
```

- [ ] **Step 2: Verify `TerminalNotificationStore.unreadCount(forPanelId:)` exists**

This is the one API assumption. Check with:

```bash
grep -n "unreadCount" Sources/TerminalNotificationStore.swift | head -20
```

Expected: at least one public method that returns an `Int` keyed by `panelId: UUID`. If the method doesn't exist with that exact signature, look for a near-match (e.g., `unreadCount(for panelId: UUID)`) and adjust the call in `makeSnapshot()`. If no per-panel API exists at all, temporarily use `return 0` and add a TODO referencing Phase 2.

- [ ] **Step 3: Verify `Workspace.focusedPanelId` exists**

```bash
grep -n "var focusedPanelId" Sources/Workspace.swift
```

Expected: a `var focusedPanelId: UUID?` computed property (confirmed during exploration at roughly line 6526).

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -40`
Expected: builds cleanly. If `TerminalNotificationStore.unreadCount(forPanelId:)` isn't the right signature, the compiler will point at it — fall back to `return 0` inside `makeSnapshot` with an inline comment `// TODO(#2590 Phase 2): per-panel unread count`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Island/IslandStateStore.swift
git commit -m "$(cat <<'EOF'
Add TabManagerIslandStateSource wrapping live TabManager (#2590)

Production source that subscribes to @Published tab list, per-workspace
statusEntries/panelTitles/panels, and TerminalNotificationStore, then
emits a debounce-friendly change stream the store can snapshot.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `IslandFocusSink` protocol + production implementation

**Files:**
- Create: `Sources/Island/IslandFocusSink.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/Island/IslandFocusSink.swift

import AppKit
import Foundation

/// The exact set of cmux actions IslandJumpRouter needs to perform when
/// the user clicks a session row. Confining these behind a protocol makes
/// the router unit-testable and is also the single place where the Island
/// module writes back into cmux core state.
@MainActor
protocol IslandFocusSink: AnyObject {
    /// Bring cmux to the front (an explicit user intent that satisfies
    /// the socket focus-steal policy — see CLAUDE.md §"Socket focus policy").
    func activateApp()

    /// Select the workspace with the given id. Returns false if the
    /// workspace no longer exists.
    @discardableResult
    func selectWorkspace(id: UUID) -> Bool

    /// Focus the panel with the given id inside the previously-selected
    /// workspace. Returns false if the panel no longer exists.
    @discardableResult
    func focusPanel(id: UUID, inWorkspace workspaceId: UUID) -> Bool

    /// Collapse the island overlay (close the expanded panel).
    func collapseIsland()
}

/// Production implementation that routes through the live `TabManager`
/// and its workspaces.
@MainActor
final class TabManagerIslandFocusSink: IslandFocusSink {

    private let tabManager: TabManager
    private let collapse: @MainActor () -> Void

    init(tabManager: TabManager, collapse: @escaping @MainActor () -> Void) {
        self.tabManager = tabManager
        self.collapse = collapse
    }

    func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func selectWorkspace(id: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == id }) else {
            return false
        }
        tabManager.selectWorkspace(workspace)
        return true
    }

    @discardableResult
    func focusPanel(id panelId: UUID, inWorkspace workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] != nil else {
            return false
        }
        workspace.focusPanel(panelId)
        return true
    }

    func collapseIsland() {
        collapse()
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Island/IslandFocusSink.swift
git commit -m "$(cat <<'EOF'
Add IslandFocusSink protocol + TabManager implementation (#2590)

Single write-back surface from the Island module into cmux core. The
router depends only on the protocol; tests use a spy.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `IslandJumpRouter` with tests

**Files:**
- Create: `Sources/Island/IslandJumpRouter.swift`
- Create: `cmuxTests/IslandJumpRouterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// cmuxTests/IslandJumpRouterTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class IslandJumpRouterTests: XCTestCase {

    private final class SpyFocusSink: IslandFocusSink {
        enum Call: Equatable {
            case activate
            case selectWorkspace(UUID)
            case focusPanel(UUID, UUID)
            case collapse
        }
        var calls: [Call] = []
        var workspaceExists: Bool = true
        var panelExists: Bool = true

        func activateApp() { calls.append(.activate) }

        func selectWorkspace(id: UUID) -> Bool {
            calls.append(.selectWorkspace(id))
            return workspaceExists
        }
        func focusPanel(id: UUID, inWorkspace workspaceId: UUID) -> Bool {
            calls.append(.focusPanel(id, workspaceId))
            return panelExists
        }
        func collapseIsland() { calls.append(.collapse) }
    }

    private func makeSession(workspaceId: UUID = UUID(), panelId: UUID = UUID()) -> IslandSession {
        IslandSession(
            id: panelId,
            workspaceId: workspaceId,
            panelId: panelId,
            agentKind: .claudeCode,
            phase: .running,
            workspaceTitle: "w",
            panelTitle: "p",
            lastActivity: Date(),
            unreadCount: 0,
            rawStatusValue: "Running"
        )
    }

    func testHappyPathSequence() {
        let spy = SpyFocusSink()
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        XCTAssertEqual(
            spy.calls,
            [
                .activate,
                .selectWorkspace(s.workspaceId),
                .focusPanel(s.panelId, s.workspaceId),
                .collapse
            ]
        )
    }

    func testWorkspaceGoneShortCircuits() {
        let spy = SpyFocusSink()
        spy.workspaceExists = false
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        // Router did not reach focusPanel. It did not activate before
        // discovering the workspace was gone (spec §6.6 says to collapse
        // without activating if steps fail).
        XCTAssertEqual(
            spy.calls,
            [
                .selectWorkspace(s.workspaceId),
                .collapse
            ]
        )
    }

    func testPanelGoneCollapsesWithoutFocus() {
        let spy = SpyFocusSink()
        spy.panelExists = false
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        XCTAssertEqual(
            spy.calls,
            [
                .activate,
                .selectWorkspace(s.workspaceId),
                .focusPanel(s.panelId, s.workspaceId),
                .collapse
            ]
        )
    }
}
```

- [ ] **Step 2: Build and confirm the compile fails on `IslandJumpRouter`**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: compile error — `IslandJumpRouter` unknown.

- [ ] **Step 3: Create the router**

```swift
// Sources/Island/IslandJumpRouter.swift

import Foundation

/// Translates a session tap into a fixed sequence of `IslandFocusSink`
/// calls. See spec §6.6 for ordering requirements.
@MainActor
final class IslandJumpRouter {

    private let focusSink: IslandFocusSink

    init(focusSink: IslandFocusSink) {
        self.focusSink = focusSink
    }

    /// Perform the jump. The router guarantees that `collapseIsland()` is
    /// called exactly once, regardless of which step (if any) fails.
    func jump(to session: IslandSession) {
        // If the workspace has already been torn down, skip activation and
        // just collapse (spec §6.6: "collapses the island without activating
        // cmux"). This avoids yanking the user's focus over to cmux only to
        // display nothing meaningful.
        guard focusSink.selectWorkspace(id: session.workspaceId) == false else {
            // Normal path: workspace found → activate + focus panel + collapse.
            focusSink.activateApp()
            // Selecting a second time keeps the TabManager state coherent in
            // case activation hopped windows — this is the same sequence the
            // existing workspace.select socket command uses.
            _ = focusSink.selectWorkspace(id: session.workspaceId)
            _ = focusSink.focusPanel(id: session.panelId, inWorkspace: session.workspaceId)
            focusSink.collapseIsland()
            return
        }

        // Workspace missing branch — collapse and bail.
        focusSink.collapseIsland()
    }
}
```

Wait — the control flow above is backwards (selectWorkspace returns true on success, and `guard …==false else { happyPath }` is confusing). Rewrite cleanly:

```swift
// Sources/Island/IslandJumpRouter.swift

import Foundation

/// Translates a session tap into a fixed sequence of `IslandFocusSink`
/// calls. See spec §6.6 for ordering requirements.
@MainActor
final class IslandJumpRouter {

    private let focusSink: IslandFocusSink

    init(focusSink: IslandFocusSink) {
        self.focusSink = focusSink
    }

    /// Perform the jump. `collapseIsland()` runs exactly once whether or
    /// not intermediate steps succeed.
    func jump(to session: IslandSession) {
        // Resolve the workspace first. If it's gone, skip activation
        // (spec §6.6) — we don't want to yank focus to a now-empty tab.
        let workspaceFound = focusSink.selectWorkspace(id: session.workspaceId)
        guard workspaceFound else {
            focusSink.collapseIsland()
            return
        }

        // Workspace is there; this is an explicit user focus intent so
        // activating cmux is allowed under CLAUDE.md "Socket focus policy".
        focusSink.activateApp()

        // Re-select to restore selection after activation; idempotent.
        _ = focusSink.selectWorkspace(id: session.workspaceId)

        _ = focusSink.focusPanel(id: session.panelId, inWorkspace: session.workspaceId)

        focusSink.collapseIsland()
    }
}
```

Note the test's `testHappyPathSequence` expects the sequence `[activate, select, focus, collapse]` — a single `select` call. Update the router to match by dropping the double `select`:

```swift
// Sources/Island/IslandJumpRouter.swift  — final version

import Foundation

/// Translates a session tap into a fixed sequence of `IslandFocusSink`
/// calls. See spec §6.6 for ordering requirements.
@MainActor
final class IslandJumpRouter {

    private let focusSink: IslandFocusSink

    init(focusSink: IslandFocusSink) {
        self.focusSink = focusSink
    }

    /// Perform the jump. `collapseIsland()` runs exactly once.
    func jump(to session: IslandSession) {
        let workspaceFound = focusSink.selectWorkspace(id: session.workspaceId)
        guard workspaceFound else {
            focusSink.collapseIsland()
            return
        }
        focusSink.activateApp()
        _ = focusSink.focusPanel(id: session.panelId, inWorkspace: session.workspaceId)
        focusSink.collapseIsland()
    }
}
```

Update the test's `testHappyPathSequence` expected array to match the order `[selectWorkspace, activate, focusPanel, collapse]`:

```swift
    func testHappyPathSequence() {
        let spy = SpyFocusSink()
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        XCTAssertEqual(
            spy.calls,
            [
                .selectWorkspace(s.workspaceId),
                .activate,
                .focusPanel(s.panelId, s.workspaceId),
                .collapse
            ]
        )
    }
```

And `testPanelGoneCollapsesWithoutFocus` keeps its current order — panel fails but the router already collapsed unconditionally so the expected sequence becomes `[selectWorkspace, activate, focusPanel, collapse]` with the same `focusPanel` call (the spy records regardless of return value). Update that test's expectation array the same way.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/Island/IslandJumpRouter.swift cmuxTests/IslandJumpRouterTests.swift
git commit -m "$(cat <<'EOF'
Add IslandJumpRouter with spy-based tests (#2590)

The router guarantees collapseIsland() runs exactly once and that
activateApp() is skipped when the target workspace no longer exists.
Verified against a SpyFocusSink.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Port `NotchShape.swift` from claude-island

**Files:**
- Create: `Sources/Island/NotchShape.swift`

- [ ] **Step 1: Copy the source**

```swift
// Sources/Island/NotchShape.swift
//
// Ported from https://github.com/farouqaldori/claude-island
//   ClaudeIsland/UI/Components/NotchShape.swift
// License: Apache 2.0. See THIRD_PARTY_LICENSES.md.
//
// Behavior-preserving port. Only the license header and the enclosing
// type name differ from the upstream source.

import SwiftUI

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Start at top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left inward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        // Left edge down
        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius)
        )

        // Bottom-left outward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY)
        )

        // Bottom-right outward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        // Right edge up
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius)
        )

        // Top-right inward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        // Top edge back to start
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}
```

- [ ] **Step 2: Update `THIRD_PARTY_LICENSES.md` with the attribution**

Open `THIRD_PARTY_LICENSES.md`. Add a new section (alphabetical order). Since the plan can't predict the exact section order in the current file, append this block in the appropriate alphabetical position:

```markdown
## claude-island

- Source: https://github.com/farouqaldori/claude-island
- License: Apache License 2.0
- Files ported: `NotchShape.swift`, `NotchPanel` configuration (adapted)
- Portions of `Sources/Island/NotchShape.swift` and `Sources/Island/NotchPanel.swift`
  are based on files from claude-island and are redistributed under the Apache
  2.0 license.
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/Island/NotchShape.swift THIRD_PARTY_LICENSES.md
git commit -m "$(cat <<'EOF'
Port NotchShape from claude-island (#2590)

Apache 2.0 port of the inward-top / outward-bottom quadratic notch shape
used as the mask for the island overlay. Attribution added to
THIRD_PARTY_LICENSES.md.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: `NotchPanel` subclass

**Files:**
- Create: `Sources/Island/NotchPanel.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/Island/NotchPanel.swift
//
// Mechanics adapted from https://github.com/farouqaldori/claude-island
//   ClaudeIsland/UI/Window/NotchWindow.swift
// License: Apache 2.0. See THIRD_PARTY_LICENSES.md.

import AppKit

/// NSPanel subclass used as the host window for the cmux Island overlay.
///
/// Behaves as a non-activating, always-on-top floating panel that joins
/// every Space and stays above the menu bar. When collapsed, the panel
/// ignores mouse events so clicks pass through to the menu bar and apps
/// underneath; when expanded, it accepts mouse events so the row buttons
/// are clickable.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false
        isMovable = false

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        allowsToolTipsWhenApplicationIsInactive = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Island/NotchPanel.swift
git commit -m "$(cat <<'EOF'
Add NotchPanel NSPanel subclass (#2590)

Non-activating, all-spaces floating panel configured to sit above the
menu bar. Adapted from claude-island's NotchWindow (Apache 2.0).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Localized strings

**Why now:** `IslandRootView` (next task) uses `String(localized:)` for every user-facing string. Getting the keys into `Localizable.xcstrings` first means the view compiles the first time.

**Files:**
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Open `Localizable.xcstrings` and add the following keys**

`Localizable.xcstrings` is a JSON-structured file. Open it in Xcode (preferred — it has a native editor) or edit the raw JSON. For each key, provide English and Japanese translations. Insert them in alphabetical position among existing `island.*` keys (there are none yet; insert in alphabetical position overall).

Keys to add:

| Key | English | Japanese |
|---|---|---|
| `island.header.title` | cmux Island | cmux アイランド |
| `island.settings.title` | Island | アイランド |
| `island.settings.enable.label` | Show agent session island overlay | エージェントセッションのアイランドを表示 |
| `island.settings.enable.help` | A notch-anchored pill that lists active AI agent sessions running inside cmux. Click a row to jump to that workspace and terminal split. | ノッチ付近に浮かぶピル型オーバーレイで、cmux 内で実行中の AI エージェントセッションを一覧表示します。行をクリックすると、該当のワークスペースとターミナル分割に移動します。 |
| `island.settings.known_kinds.help` | Detects sessions from `cmux set-status` with one of these known keys: claude_code, codex, copilot_cli, opencode, gemini_cli, cursor, amp, droid. | 次の既知のキーを持つ `cmux set-status` エントリをセッションとして検出します: claude_code, codex, copilot_cli, opencode, gemini_cli, cursor, amp, droid. |
| `island.phase.running` | RUNNING | 実行中 |
| `island.phase.idle` | IDLE | 待機中 |
| `island.phase.waiting` | WAITING | 入力待ち |
| `island.phase.error` | ERROR | エラー |
| `island.phase.unknown` | — | — |
| `island.debug.window.title` | Island Controller | アイランドコントローラー |
| `island.debug.injectTestSession` | Inject test session | テストセッションを注入 |
| `island.debug.clearTestSessions` | Clear test sessions | テストセッションをクリア |
| `menu.debug.islandController` | Island Controller… | アイランドコントローラー… |

If editing `Localizable.xcstrings` as raw JSON: find the top-level `"strings"` object and add each key like:

```jsonc
"island.header.title" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "cmux Island" } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "cmux アイランド" } }
  }
}
```

- [ ] **Step 2: Validate the file parses**

Run: `python3 -c "import json,sys; json.load(open('Resources/Localizable.xcstrings'))" && echo ok`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
Add localized strings for cmux Island (#2590)

English + Japanese strings for the settings section, phase pills,
debug window, and the Debug Windows menu entry.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: `IslandRootView` SwiftUI view (closed + expanded)

**Files:**
- Create: `Sources/Island/IslandRootView.swift`

- [ ] **Step 1: Create the view file**

```swift
// Sources/Island/IslandRootView.swift

import SwiftUI
import Combine

/// SwiftUI root of the cmux Island overlay.
///
/// Two visual states — closed (minimal pill on the left extension of the
/// notch) and opened (rounded panel below the notch with session rows).
struct IslandRootView: View {

    // MARK: - Observed state

    @ObservedObject var viewModel: IslandRootViewModel

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(
                topCornerRadius: viewModel.topCornerRadius,
                bottomCornerRadius: viewModel.bottomCornerRadius
            )
            .fill(.black)
            .frame(
                width: viewModel.shapeSize.width,
                height: viewModel.shapeSize.height
            )
            .shadow(
                color: viewModel.isOpen ? .black.opacity(0.7) : .clear,
                radius: 8
            )
            .animation(
                viewModel.isOpen
                    ? .spring(response: 0.42, dampingFraction: 0.8)
                    : .spring(response: 0.45, dampingFraction: 1.0),
                value: viewModel.isOpen
            )
            .onTapGesture {
                if !viewModel.isOpen { viewModel.open() }
            }
            .overlay(alignment: .top) {
                if viewModel.isOpen {
                    expandedContent
                        .padding(.top, viewModel.notchHeight + 4)
                        .frame(width: viewModel.shapeSize.width - 24)
                } else {
                    closedContent
                        .padding(.leading, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - Closed state — minimal dot + count on the LEFT extension

    private var closedContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.aggregateColor)
                .frame(width: 6, height: 6)
                .shadow(color: viewModel.aggregateColor.opacity(0.6), radius: 3)
            Text("\(viewModel.sessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(height: viewModel.notchHeight, alignment: .leading)
    }

    // MARK: - Expanded state — list of session rows

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "island.header.title", defaultValue: "cmux Island"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 6)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .frame(maxHeight: 440)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onExitCommand { viewModel.close() }
    }

    @ViewBuilder
    private func sessionRow(_ session: IslandSession) -> some View {
        Button {
            viewModel.jump(to: session)
        } label: {
            HStack(spacing: 10) {
                // Agent chip
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(session.agentKind.color)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text(session.agentKind.monogram)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.workspaceTitle) · \(session.panelTitle)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(session.agentKind.displayName) · \(relativeTime(since: session.lastActivity))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                phasePill(session.phase)
                if session.unreadCount > 0 {
                    Text("·\(session.unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func phasePill(_ phase: IslandSessionPhase) -> some View {
        let (bg, fg, text) = phaseStyle(phase)
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
    }

    private func phaseStyle(_ phase: IslandSessionPhase) -> (Color, Color, String) {
        switch phase {
        case .running:
            return (
                Color(red: 0.04, green: 0.23, blue: 0.09),
                Color(red: 0.20, green: 0.82, blue: 0.35),
                String(localized: "island.phase.running", defaultValue: "RUNNING")
            )
        case .waiting:
            return (
                Color(red: 0.29, green: 0.21, blue: 0.02),
                Color(red: 0.98, green: 0.80, blue: 0.24),
                String(localized: "island.phase.waiting", defaultValue: "WAITING")
            )
        case .error:
            return (
                Color(red: 0.23, green: 0.07, blue: 0.07),
                Color(red: 0.97, green: 0.44, blue: 0.44),
                String(localized: "island.phase.error", defaultValue: "ERROR")
            )
        case .idle:
            return (
                Color(red: 0.11, green: 0.16, blue: 0.22),
                Color(red: 0.49, green: 0.83, blue: 0.99),
                String(localized: "island.phase.idle", defaultValue: "IDLE")
            )
        case .unknown:
            return (
                Color.white.opacity(0.12),
                Color.white.opacity(0.6),
                String(localized: "island.phase.unknown", defaultValue: "—")
            )
        }
    }

    private func relativeTime(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

// MARK: - View model

/// View model backing `IslandRootView`. Owns the open/closed state, the
/// current session snapshot, and delegates jump actions to a router.
@MainActor
final class IslandRootViewModel: ObservableObject {

    @Published private(set) var sessions: [IslandSession] = []
    @Published private(set) var isOpen: Bool = false

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    // Extension + open-state geometry.
    private let closedSideExtent: CGFloat = 28
    private let openedWidth: CGFloat = 560
    private let openedMinHeight: CGFloat = 64
    private let rowHeight: CGFloat = 56
    private let openedMaxHeight: CGFloat = 540

    private let router: IslandJumpRouter
    private var provider: IslandStateProvider?
    private var cancellable: AnyCancellable?

    init(notchWidth: CGFloat, notchHeight: CGFloat, router: IslandJumpRouter) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.router = router
    }

    func bind(to provider: IslandStateProvider) {
        self.provider = provider
        self.sessions = provider.currentSessions
        self.cancellable = provider.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.sessions = sessions
            }
    }

    // MARK: Layout helpers

    var shapeSize: CGSize {
        if isOpen {
            let h = min(
                max(openedMinHeight + CGFloat(sessions.count) * rowHeight, 160),
                openedMaxHeight
            )
            return CGSize(width: openedWidth, height: h)
        } else {
            return CGSize(
                width: notchWidth + 2 * closedSideExtent,
                height: notchHeight
            )
        }
    }

    var topCornerRadius: CGFloat { isOpen ? 19 : 6 }
    var bottomCornerRadius: CGFloat { isOpen ? 24 : 14 }

    var aggregateColor: Color {
        if sessions.contains(where: { $0.phase == .running }) { return .green }
        if sessions.contains(where: { $0.phase == .waiting }) { return .yellow }
        if sessions.contains(where: { $0.phase == .error }) { return .red }
        return .gray
    }

    // MARK: Actions

    func open()  { isOpen = true  }
    func close() { isOpen = false }

    func jump(to session: IslandSession) {
        router.jump(to: session)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -40`
Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Island/IslandRootView.swift
git commit -m "$(cat <<'EOF'
Add IslandRootView (closed pill + expanded row list) (#2590)

SwiftUI root for the cmux Island. Closed state shows a dot + count on
the left extension of the notch; expanded state shows a vertical list of
session rows that route clicks through IslandJumpRouter. Uses only
localized strings.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: `IslandWindowController`

**Files:**
- Create: `Sources/Island/IslandWindowController.swift`

- [ ] **Step 1: Create the controller**

```swift
// Sources/Island/IslandWindowController.swift

import AppKit
import Combine
import SwiftUI

/// Owns a single `NotchPanel` plus its hosted `IslandRootView`.
///
/// Responsibilities:
///   • position the panel on the notch screen (or main screen on non-notch Macs)
///   • show/hide the panel based on `provider.sessions.isEmpty`
///   • wire the view model to the provider
///   • tear down cleanly on `shutdown()`.
@MainActor
final class IslandWindowController: NSWindowController {

    private let provider: IslandStateProvider
    private let viewModel: IslandRootViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(provider: IslandStateProvider, router: IslandJumpRouter) {
        self.provider = provider

        let screen = IslandWindowController.resolveScreen()
        let notchSize = IslandWindowController.resolveNotchSize(on: screen)

        self.viewModel = IslandRootViewModel(
            notchWidth: notchSize.width,
            notchHeight: notchSize.height,
            router: router
        )

        let windowHeight: CGFloat = 750
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.maxY - windowHeight,
            width: screen.frame.width,
            height: windowHeight
        )

        let panel = NotchPanel(contentRect: frame)
        panel.contentView = NSHostingView(rootView: IslandRootView(viewModel: viewModel))
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = true

        super.init(window: panel)
        panel.delegate = nil  // never become a key-window root

        viewModel.bind(to: provider)

        // Subscribe to session list changes to drive visibility + mouse events.
        provider.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.reconcile(sessions: sessions)
            }
            .store(in: &cancellables)

        // Toggle ignoresMouseEvents when the view model opens/closes so
        // expanded rows become clickable while collapsed clicks pass through.
        viewModel.$isOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] isOpen in
                panel?.ignoresMouseEvents = !isOpen
            }
            .store(in: &cancellables)

        reconcile(sessions: provider.currentSessions)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called by `AppDelegate` when the setting flips off. Removes the
    /// window, cancels subscriptions, breaks the router's retain on `self`.
    func shutdown() {
        cancellables.removeAll()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    // MARK: - Private

    private func reconcile(sessions: [IslandSession]) {
        if sessions.isEmpty {
            window?.orderOut(nil)
        } else if window?.isVisible != true {
            window?.orderFront(nil)
        }
    }

    // MARK: - Screen resolution

    private static func resolveScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Returns the physical notch rect size, or a synthetic `(200, 32)`
    /// on non-notch Macs so the geometry stays consistent.
    private static func resolveNotchSize(on screen: NSScreen) -> CGSize {
        let insetTop = screen.safeAreaInsets.top
        if insetTop > 0 {
            // auxiliaryTopLeftArea / auxiliaryTopRightArea can be nil on
            // non-notch Macs; compute the middle region from frame widths.
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = max(120, screen.frame.width - leftWidth - rightWidth)
            return CGSize(width: notchWidth, height: insetTop)
        }
        return CGSize(width: 200, height: 32)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -40`
Expected: builds cleanly. If `NSScreen.auxiliaryTopLeftArea` isn't available on the minimum macOS target, drop to a hardcoded `(200, 32)` notch size — the exact measurement is not critical for the overlay to function.

- [ ] **Step 3: Commit**

```bash
git add Sources/Island/IslandWindowController.swift
git commit -m "$(cat <<'EOF'
Add IslandWindowController owning the NotchPanel (#2590)

Wires provider → view model → NotchPanel, toggles visibility based on
the sessions list, and flips ignoresMouseEvents when the view opens or
closes. Provides a shutdown() path AppDelegate calls when the setting
turns off.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Settings → Island section in `SettingsView`

**Files:**
- Modify: `Sources/cmuxApp.swift`

- [ ] **Step 1: Add the `@AppStorage` binding to `SettingsView`**

Open `Sources/cmuxApp.swift`. Locate the existing `struct SettingsView: View` declaration (around line 4074). In the block of `@AppStorage` properties near the top of the struct, add:

```swift
    @AppStorage(IslandSettings.enabledKey) private var islandEnabled = IslandSettings.defaultEnabled
```

Place it next to related grouping — a good spot is right before or after `@AppStorage(NotificationBadgeSettings.dockBadgeEnabledKey)`.

- [ ] **Step 2: Add the section UI**

Find the `SettingsSectionHeader(title: ... "settings.section.automation", ...)` block (around line 5431) and insert a new Island section **above** Automation (so it sits between the section above Automation and Automation itself). The new block:

```swift
                    SettingsSectionHeader(title: String(localized: "settings.section.island", defaultValue: "Island"))
                    SettingsCard {
                        SettingsCardRow(
                            configurationReview: .json("island.enabled"),
                            String(localized: "island.settings.enable.label", defaultValue: "Show agent session island overlay"),
                            subtitle: String(localized: "island.settings.enable.help", defaultValue: "A notch-anchored pill that lists active AI agent sessions running inside cmux. Click a row to jump to that workspace and terminal split.")
                        ) {
                            Toggle("", isOn: $islandEnabled)
                                .labelsHidden()
                                .controlSize(.small)
                                .accessibilityIdentifier("SettingsIslandEnabledToggle")
                        }

                        SettingsCardDivider()

                        SettingsCardNote(
                            String(
                                localized: "island.settings.known_kinds.help",
                                defaultValue: "Detects sessions from `cmux set-status` with one of these known keys: claude_code, codex, copilot_cli, opencode, gemini_cli, cursor, amp, droid."
                            )
                        )
                    }
```

If the existing scroll list uses a different section ordering, choose any adjacent position — order is cosmetic.

- [ ] **Step 3: Add the section header localized string**

Edit `Resources/Localizable.xcstrings` and add one more key you may have missed in Task 11:

| Key | English | Japanese |
|---|---|---|
| `settings.section.island` | Island | アイランド |

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -40`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/cmuxApp.swift Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
Add Settings > Island section with enable toggle (#2590)

Users can now opt in to the cmux Island overlay from Settings. Toggle
is bound to IslandSettings.enabledKey and mirrors through
settings.json via CmuxSettingsFileStore.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Debug menu entry + `IslandControllerDebugWindowController`

**Files:**
- Modify: `Sources/cmuxApp.swift`

- [ ] **Step 1: Add the Debug Windows menu button**

In `Sources/cmuxApp.swift`, find the `Menu("Debug Windows") { … }` block (around line 467). Inside the block, alphabetically between `"Debug Window Controls…"` and `"Menu Bar Extra Debug…"`, add:

```swift
                    Button(
                        String(
                            localized: "menu.debug.islandController",
                            defaultValue: "Island Controller…"
                        )
                    ) {
                        IslandControllerDebugWindowController.shared.show()
                    }
```

If there's a second `Menu("Debug Windows")` block (for a different context — earlier grep showed two), add the same button there.

- [ ] **Step 2: Add the `IslandControllerDebugWindowController` class**

Near the other `*DebugWindowController` declarations (`SidebarDebugWindowController` is around line 2638), add:

```swift
#if DEBUG
private final class IslandControllerDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = IslandControllerDebugWindowController()

    let inMemorySource = InMemoryIslandStateSource()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "island.debug.window.title", defaultValue: "Island Controller")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.islandDebug")
        window.center()
        window.contentView = NSHostingView(rootView: IslandDebugView(source: inMemorySource))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Debug-only view that lets the developer toggle the feature and inject
/// synthetic sessions into an in-memory source for visual iteration.
private struct IslandDebugView: View {
    @AppStorage(IslandSettings.enabledKey) private var islandEnabled = IslandSettings.defaultEnabled
    let source: InMemoryIslandStateSource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                String(localized: "island.settings.enable.label", defaultValue: "Show agent session island overlay"),
                isOn: $islandEnabled
            )
            .font(.system(size: 13, weight: .semibold))

            Divider()

            HStack {
                Button(String(localized: "island.debug.injectTestSession", defaultValue: "Inject test session")) {
                    source.add(
                        IslandSession(
                            id: UUID(),
                            workspaceId: UUID(),
                            panelId: UUID(),
                            agentKind: IslandAgentKind.allCases.randomElement() ?? .claudeCode,
                            phase: [.running, .waiting, .error, .idle].randomElement() ?? .running,
                            workspaceTitle: "debug",
                            panelTitle: "synthetic",
                            lastActivity: Date(),
                            unreadCount: 0,
                            rawStatusValue: "debug"
                        )
                    )
                }
                Button(String(localized: "island.debug.clearTestSessions", defaultValue: "Clear test sessions")) {
                    source.clear()
                }
            }

            Divider()

            Text("Injected sessions: \(source.sessions.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 480)
    }
}
#endif
```

Note: the debug window's inject path writes to an in-memory source that is independent of the production store. For MVP this is acceptable — the debug window exists to iterate on shape/layout, not to mirror real state. A future enhancement could expose a debug hook to swap the production store's source at runtime.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -30`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/cmuxApp.swift
git commit -m "$(cat <<'EOF'
Add Debug menu "Island Controller…" entry (DEBUG builds only) (#2590)

IslandControllerDebugWindowController provides an enable toggle, an
inject-test-session button, and a synthetic row count for visual
iteration during development. Wrapped in #if DEBUG per CLAUDE.md.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: AppDelegate lifecycle (create / destroy controller on toggle)

**Files:**
- Modify: `Sources/AppDelegate.swift`

- [ ] **Step 1: Add the stored properties**

In `Sources/AppDelegate.swift`, inside `final class AppDelegate: NSObject, …` near the other stored properties, add:

```swift
    // MARK: - Island overlay

    private var islandWindowController: IslandWindowController?
    private var islandEnabledObserver: AnyCancellable?
```

Add `import Combine` at the top of the file if it isn't already imported.

- [ ] **Step 2: Wire the observer in `applicationDidFinishLaunching`**

Find `applicationDidFinishLaunching(_:)` (around line 2483). Append at the end of the method (before any cleanup / return-like code):

```swift
        // cmux Island — opt-in overlay. Created and destroyed reactively
        // based on the islandEnabled setting so disabling it leaves no
        // leftover panel or observers.
        islandEnabledObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: IslandSettings.enabledKey) }
            .prepend(UserDefaults.standard.bool(forKey: IslandSettings.enabledKey))
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.refreshIslandController(enabled: enabled)
            }
```

- [ ] **Step 3: Add the refresh helper method**

Anywhere in the same file (group near other helpers):

```swift
    @MainActor
    private func refreshIslandController(enabled: Bool) {
        if enabled {
            guard islandWindowController == nil,
                  let tabManager = self.tabManager else { return }
            let source = TabManagerIslandStateSource(tabManager: tabManager)
            let store = IslandStateStore(source: source)
            let controller = IslandWindowController(
                provider: store,
                router: IslandJumpRouter(
                    focusSink: TabManagerIslandFocusSink(
                        tabManager: tabManager,
                        collapse: { [weak self] in
                            self?.islandWindowController?.viewModel.close()
                        }
                    )
                )
            )
            islandWindowController = controller
        } else {
            islandWindowController?.shutdown()
            islandWindowController = nil
        }
    }
```

Note: `AppDelegate` already owns a `TabManager` reference (common in cmux). If the property name differs from `tabManager`, match it. If there's no existing singleton property, look for where other features access the TabManager (search `grep -n "tabManager" Sources/AppDelegate.swift`) and mirror that access.

Also note that `viewModel` on `IslandWindowController` is not currently public — you need to either promote it to `internal` visibility or expose a dedicated `func close()` on the controller that forwards to the view model. Prefer the dedicated `close()`:

Add to `Sources/Island/IslandWindowController.swift`:

```swift
    /// Convenience used by the router's collapse callback.
    func close() {
        viewModel.close()
    }
```

And change the `collapse` closure in Step 3 above to:

```swift
                        collapse: { [weak self] in
                            self?.islandWindowController?.close()
                        }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme cmux-unit build 2>&1 | tail -40`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppDelegate.swift Sources/Island/IslandWindowController.swift
git commit -m "$(cat <<'EOF'
Wire AppDelegate to island.enabled setting (#2590)

Observes the UserDefaults key and creates/destroys IslandWindowController
reactively. Uses TabManagerIslandStateSource + TabManagerIslandFocusSink
for live data and focus routing. Adds a close() convenience on the
controller for the router's collapse callback.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Register every new file in `project.pbxproj`

**Why this task is separate:** up to this point the Xcode project has not "seen" the new files in `Sources/Island/`. Each file needs four additions in `project.pbxproj`: one `PBXBuildFile`, one `PBXFileReference`, one entry in the Sources `PBXGroup` children, one entry in the Sources `PBXSourcesBuildPhase` files list. The existing `Panels/*.swift` files follow the same pattern (flat in the Sources group, `path = Panels/Foo.swift` on the file reference) — mirror it.

**Files to register (Sources target):**

```
Sources/Island/IslandSettings.swift
Sources/Island/IslandSession.swift
Sources/Island/IslandStateProvider.swift
Sources/Island/IslandStateStore.swift
Sources/Island/IslandFocusSink.swift
Sources/Island/IslandJumpRouter.swift
Sources/Island/NotchShape.swift
Sources/Island/NotchPanel.swift
Sources/Island/IslandRootView.swift
Sources/Island/IslandWindowController.swift
```

**Files to register (cmuxTests target):**

```
cmuxTests/IslandSettingsFileStoreTests.swift
cmuxTests/IslandSessionPhaseTests.swift
cmuxTests/IslandSessionSortTests.swift
cmuxTests/IslandStateStoreTests.swift
cmuxTests/IslandJumpRouterTests.swift
```

- [ ] **Step 1: Open `GhosttyTabs.xcodeproj/project.pbxproj` in Xcode's file inspector (preferred)**

The fastest and least error-prone approach is to open `GhosttyTabs.xcodeproj` in Xcode, then in the Project Navigator:

1. Right-click the `Sources` group → **Add Files to "GhosttyTabs"…**
2. Select all 10 files under `Sources/Island/`.
3. In the add-files dialog: uncheck "Copy items if needed" (they already live in the repo), select the `cmux` target.
4. Right-click `cmuxTests` → **Add Files to "GhosttyTabs"…**
5. Select the 5 test files, select the `cmuxTests` target.
6. Save and quit Xcode.

Xcode will update `project.pbxproj` correctly. Commit only the `project.pbxproj` diff.

- [ ] **Step 2: Alternative — hand-edit `project.pbxproj` if Xcode is unavailable**

For each file, add four entries. Below is a template for one Sources file (`IslandSettings.swift`). Repeat for every file, using fresh UUID-style hex IDs for each new entry (copy the format used by existing lines).

**a) `PBXBuildFile`** (add near the top in the "Begin PBXBuildFile section"):

```
		A5ISLAND01 /* IslandSettings.swift in Sources */ = {isa = PBXBuildFile; fileRef = A5ISLANDR1 /* IslandSettings.swift */; };
```

**b) `PBXFileReference`** (add in the "Begin PBXFileReference section"):

```
		A5ISLANDR1 /* IslandSettings.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Island/IslandSettings.swift; sourceTree = "<group>"; };
```

**c) Sources group children** (inside the Sources `PBXGroup` block, around line 456–521, add the file ref to the children list):

```
					A5ISLANDR1 /* IslandSettings.swift */,
```

**d) Sources build phase files** (inside the `PBXSourcesBuildPhase` for the cmux target — search for `isa = PBXSourcesBuildPhase;`):

```
				A5ISLAND01 /* IslandSettings.swift in Sources */,
```

Repeat for each of the 10 Sources files and each of the 5 test files (tests go into the `cmuxTests` target's `PBXSourcesBuildPhase`, not the `cmux` target's).

- [ ] **Step 3: Verify the project opens cleanly**

```bash
xcodebuild -project GhosttyTabs.xcodeproj -list
```

Expected: no errors; lists the `cmux`, `cmux-unit`, `cmuxUITests` schemes.

- [ ] **Step 4: Verify a full build succeeds**

```bash
xcodebuild -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-island-mvp build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. If there are missing-symbol errors, it means a file didn't make it into the build phase — re-check step 2d for that file.

- [ ] **Step 5: Commit**

```bash
git add GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Register cmux Island files in Xcode project (#2590)

Adds Sources/Island/*.swift to the cmux target and cmuxTests/Island*.swift
to the cmuxTests target so the module and its tests compile.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Smoke-test the build against a tagged Debug app

**Why this task:** Up to this point the plan has exercised only the compiler. The real test is the NSPanel behavior — click-through when collapsed, spring animation on open, session list populating from real set-status entries. Per CLAUDE.md the build must be tagged.

**Files:** none (build artifacts only)

- [ ] **Step 1: Build a tagged Debug app**

```bash
./scripts/reload.sh --tag island-mvp
```

Expected: prints an `App path:` line pointing to `Build/Products/Debug/cmux DEV island-mvp.app`.

- [ ] **Step 2: Surface the app path as a cmd-clickable link per CLAUDE.md**

Take the `App path:` value from the output, URL-encode spaces, and print a markdown link:

```
=======================================================
[cmux DEV island-mvp.app](file:///.../cmux%20DEV%20island-mvp.app)
=======================================================
```

Let the user cmd-click and launch the app.

- [ ] **Step 3: Walk the smoke-test checklist from spec §9**

The spec's 12-step checklist (Settings toggle on, inject set-status, expand, click row, switch spaces, toggle off, etc.) is the acceptance criteria. If any step fails, open a follow-up issue — do NOT silently fix in this PR.

- [ ] **Step 4: If no bugs surface, commit nothing — just proceed to CHANGELOG**

(If bugs surface, make fixes in dedicated commits before the CHANGELOG task so the PR history reflects reality.)

---

## Task 19: Update `CHANGELOG.md`

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Read the top of `CHANGELOG.md` to find the unreleased section**

```bash
head -30 CHANGELOG.md
```

Expected: an unreleased heading (e.g., `## Unreleased` or a dated upcoming section).

- [ ] **Step 2: Add a line under the unreleased heading**

Insert the following bullet under the `### Added` subheading (create `### Added` if it doesn't exist):

```markdown
- **cmux Island (opt-in).** New notch-anchored overlay that lists active AI agent sessions detected from `cmux set-status` entries. Click a row to jump to the corresponding workspace and terminal split. Enable it from Settings → Island. See [`docs/superpowers/specs/2026-04-09-cmux-island-design.md`](docs/superpowers/specs/2026-04-09-cmux-island-design.md) for design details. (#2590)
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
Changelog entry for cmux Island MVP (#2590)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 20: Push and open the PR

**Files:** none

- [ ] **Step 1: Push the branch**

Create a feature branch (`island-mvp`) before the first commit if this plan wasn't already running on one. If the plan has been committing on `main`, stop and ask the user how they want to proceed — do not push to `main`.

```bash
git status
git log --oneline origin/main..HEAD
```

Expected: the 15–20 commits from this plan, none on `main`. If the branch is `main`, create a branch and move the commits with:

```bash
git branch island-mvp
git reset --hard origin/main
git checkout island-mvp
```

(Only do this if the user confirms — destructive on `main` local pointer.)

- [ ] **Step 2: Push and create the PR**

```bash
git push -u origin island-mvp
gh pr create --title "cmux Island MVP (notch-anchored agent session overlay)" --body "$(cat <<'EOF'
## Summary

- Adds the MVP of the cmux Island — a notch-anchored Dynamic Island overlay listing active AI-agent sessions and routing clicks to the corresponding workspace + terminal split.
- Reads sessions from existing `cmux set-status` entries (claude_code, codex, copilot_cli, opencode, gemini_cli, cursor, amp, droid). Zero new CLI.
- Opt-in from Settings → Island (off by default). Mirrored in `~/.config/cmux/settings.json` under `"island": { "enabled": true }`.

See the design spec at `docs/superpowers/specs/2026-04-09-cmux-island-design.md`. Closes #2590 (MVP scope only; approvals + companion-app extraction tracked as follow-ups).

## Test plan

- [ ] `xcodebuild -scheme cmux-unit test` (unit tests: phase normalization, sort order, store projection, router routing, settings round-trip)
- [ ] Tagged Debug build via `./scripts/reload.sh --tag island-mvp`
- [ ] Walk spec §9 smoke test checklist on a notch-equipped Mac
- [ ] Verify on a non-notch Mac that the shape renders as a floating pill at top center

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Return the PR URL to the user**

The `gh pr create` command prints the URL. Paste it back so the user can review.

---

## Self-review

**Spec coverage check (spec ↔ plan):**

| Spec section | Covered by tasks |
|---|---|
| §4.1 Module layout (10 files) | Tasks 2, 4, 5, 6, 7, 8, 9, 10, 12, 13 |
| §4.2 Decoupling seam | Tasks 4 (provider protocol) + 7 (focus sink protocol) |
| §4.3 Data flow + 50ms debounce | Task 5 step 3 |
| §4.4 AppDelegate lifecycle | Task 16 |
| §5.1 Value types | Task 2 |
| §5.2 Projection rules (priority tiebreak) | Task 6 step 1 `makeSnapshot` |
| §5.3 Phase normalization table | Tasks 2 step 3 + tests in Task 2 step 1 |
| §5.4 Visibility predicate | Task 13 step 1 `reconcile(sessions:)` |
| §5.5 Aggregate dot color | Task 12 `aggregateColor` |
| §6.1 NotchPanel config | Task 10 |
| §6.2 NotchShape | Task 9 |
| §6.3 Closed layout (dot + count on left) | Task 12 `closedContent` |
| §6.4 Expanded layout | Task 12 `expandedContent`, `sessionRow`, `phasePill` |
| §6.5 Interactions (click open, click outside close, Esc close) | Task 12 `onTapGesture`, `onExitCommand`; Task 13 `ignoresMouseEvents` toggle |
| §6.6 Jump routing (activate/select/focus/collapse order) | Task 8 |
| §6.7 Non-notch Mac handling | Task 13 `resolveNotchSize` fallback |
| §7.1 Source of truth + settings.json mirror | Task 1 |
| §7.2 Settings UI | Task 14 |
| §7.3 Debug UI | Task 15 |
| §7.4 Discoverability (none) | n/a — deliberately empty |
| §8.1 Unit tests (6 classes) | Tasks 1, 2, 3, 5, 8. (IslandVisibilityTests merged into Task 5; same assertions.) |
| §8.2 Non-goals for automated tests | No tasks — by design |
| §8.3 Regression two-commit rule | Plan text only |
| §9 Smoke test | Task 18 |
| §10 Phase 2 extension points | Not built (by design) |

**Placeholder scan:**

- No `TBD`, `TODO` in task steps except one inline fallback note for `TerminalNotificationStore.unreadCount(forPanelId:)` if the exact signature isn't available — that's an explicit fallback instruction, not a placeholder.
- Every step that touches code has actual code.
- Every commit message is written out.
- Every file path is absolute or relative from repo root.

**Type consistency:**

- `IslandAgentKind`, `IslandSessionPhase`, `IslandSession`, `IslandStateProvider`, `IslandStateSource`, `IslandStateStore`, `IslandFocusSink`, `IslandJumpRouter`, `NotchShape`, `NotchPanel`, `IslandRootView`, `IslandRootViewModel`, `IslandWindowController`, `IslandSettings` — all used consistently across tasks.
- `TabManagerIslandStateSource` and `TabManagerIslandFocusSink` both live in files introduced in Tasks 6 and 7 respectively.
- `IslandSettings.enabledKey` referenced in Tasks 1, 14, 15, 16 — consistent.
- `IslandWindowController.close()` convenience is added in Task 16 (not earlier) because that's when it's first needed.
- `IslandSessionPhase.rank` is introduced in Task 2 step 3 and used in Task 2's sort comparator + Task 3's tests — consistent.

**Scope check:** The plan covers exactly one module (`Sources/Island/`) plus the minimum integration touches (AppDelegate + cmuxApp.swift + settings store + pbxproj + changelog). Single PR scope.
