# Snippets Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A right-sidebar tool named Snippets that lists every `type: "text"` action from the loaded cmux config, filters as you type, and pastes the chosen snippet into the focused terminal through the existing trust gate.

**Architecture:** Search logic lives in the Foundation-only `CmuxTextActions` package (pure, unit-tested). An `ObservableObject` store in the app adapts `CmuxConfigStore` to that search and holds the keyboard selection. A SwiftUI view mounts in the right sidebar as a new `RightSidebarMode` case, using the shared `SidebarSearchFieldView` chrome and an AppKit focus-host view (same pattern as the Dock tool) so the focus coordinator can hand keyboard focus to it and take it back.

**Tech Stack:** Swift 6 language mode, SwiftUI + AppKit (macOS 14+), Swift Testing for new tests, XCTest only where an existing XCTest file is touched. Xcode project wiring through `scripts/wire-app-sources.py` and `scripts/sync-test-wiring`.

**Spec:** `docs/superpowers/specs/2026-10-15-snippets-sidebar-design.md`

## Global Constraints

- Branch: `fork/snippets` in `/Users/tzgambo/Developer/cmux` (already stacked on the maintainer's #12871 head plus the context-menu commits). Never push to `feat/text-snippet-actions`.
- Git identity for every commit: `tommyz4 <4148433+tommyz4@users.noreply.github.com>` (already the repo default; verify with `git config user.email`). No attribution trailers.
- **File-length budget** (`scripts/swift_file_length_budget.py`): a new Swift file must be ≤ 500 lines; an existing Swift file may not end up longer than `max(500, its line count at the merge-base with origin/main)`. Files touched here that are already over 500 and therefore must stay line-neutral: `Sources/RightSidebarPanelView.swift` (673), `Sources/MainWindowFocusController.swift` (865), `Sources/KeyboardShortcutSettings.swift` (2605), `Sources/CmuxConfig.swift` (3873), `cmuxTests/ShortcutAndCommandPaletteTests.swift` (2244). Each task names its offsets. Run `python3 scripts/swift_file_length_budget.py` before every commit.
- App-linked code stays Swift 6.0 compatible: no trailing commas in parameter or argument lists, no `nonisolated` on type declarations.
- Every user-facing string is `String(localized: "key", defaultValue: "English")` and gets all nine locales (`en, ja, de, fr, ar, es, zh-Hant, zh-Hans, ko`) in `Resources/Localizable.xcstrings`; validate with `python3 scripts/localization_catalog.py check`.
- Build/test command for app suites (replace the `-only-testing` list per task):
  ```bash
  cd /Users/tzgambo/Developer/cmux && export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH" && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project cmux.xcodeproj -scheme cmux-unit \
    -configuration Debug -destination platform=macOS \
    -derivedDataPath /private/tmp/claude-502/-Users-tzgambo-Developer-valanceV2-cmux/c8842e9c-2f91-4cc6-a4ca-b76085054919/scratchpad/dd-rebase \
    CODE_SIGNING_ALLOWED=NO -only-testing:cmuxTests/<Suite> test 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|✘|✔ Suite|Test run with' | sort -u
  ```
  Package tests: `cd Packages/macOS/CmuxTextActions && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Never run bare `xcodebuild` against the user's running cmux; never touch `/Applications/cmux.app`. Dogfood only in the tagged build (`scripts/reload.sh --tag snippets --prod-auth`).

---

### Task 1: Snippet search in the package

**Files:**
- Modify: `Packages/macOS/CmuxTextActions/Sources/CmuxTextActions/CmuxSnippetMenuModel.swift:4-16` (add `keywords`)
- Create: `Packages/macOS/CmuxTextActions/Sources/CmuxTextActions/CmuxSnippetSearch.swift`
- Test: `Packages/macOS/CmuxTextActions/Tests/CmuxTextActionsTests/CmuxSnippetSearchTests.swift`

**Interfaces:**
- Consumes: `CmuxSnippetMenuEntry(actionID:title:category:payload:)`, `CmuxTextActionPayload(text:submit:)`.
- Produces: `CmuxSnippetMenuEntry.keywords: [String]` (init parameter `keywords: [String] = []`, placed after `category`); `public enum CmuxSnippetSearch { public static func filter(_ entries: [CmuxSnippetMenuEntry], query: String) -> [CmuxSnippetMenuEntry] }`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/macOS/CmuxTextActions/Tests/CmuxTextActionsTests/CmuxSnippetSearchTests.swift`:

```swift
import Foundation
import Testing

@testable import CmuxTextActions

/// Flat search behind the Snippets sidebar: field coverage, AND over terms,
/// ranking tiers, and folding.
struct CmuxSnippetSearchTests {
    private func entry(
        _ id: String,
        title: String,
        category: String? = nil,
        keywords: [String] = [],
        text: String
    ) throws -> CmuxSnippetMenuEntry {
        CmuxSnippetMenuEntry(
            actionID: id,
            title: title,
            category: category,
            keywords: keywords,
            payload: try #require(CmuxTextActionPayload(text: text, submit: false))
        )
    }

    private func fixtures() throws -> [CmuxSnippetMenuEntry] {
        [
            try entry("b", title: "Beta", category: "Ops", keywords: ["restart"], text: "kubectl rollout restart"),
            try entry("a", title: "Alpha", text: "echo alpha"),
            try entry("c", title: "Café", category: "SQL", keywords: ["db"], text: "select 1"),
            try entry("d", title: "Delta", text: "something with Beta inside"),
        ]
    }

    @Test func emptyQueryReturnsEverythingInTitleOrder() throws {
        let results = CmuxSnippetSearch.filter(try fixtures(), query: "   ")
        #expect(results.map(\.actionID) == ["a", "b", "c", "d"])
    }

    @Test func termMatchesTitleCategoryKeywordsAndText() throws {
        let all = try fixtures()
        #expect(CmuxSnippetSearch.filter(all, query: "alpha").map(\.actionID) == ["a"])
        #expect(CmuxSnippetSearch.filter(all, query: "sql").map(\.actionID) == ["c"])
        #expect(CmuxSnippetSearch.filter(all, query: "restart").map(\.actionID) == ["b"])
        #expect(CmuxSnippetSearch.filter(all, query: "rollout").map(\.actionID) == ["b"])
    }

    @Test func everyTermMustMatchSomewhere() throws {
        let all = try fixtures()
        #expect(CmuxSnippetSearch.filter(all, query: "beta ops").map(\.actionID) == ["b"])
        #expect(CmuxSnippetSearch.filter(all, query: "beta nowhere").isEmpty)
    }

    @Test func titleMatchesRankAboveKeywordAndTextMatches() throws {
        // "beta" is Beta's title and appears only in Delta's text.
        let results = CmuxSnippetSearch.filter(try fixtures(), query: "beta")
        #expect(results.map(\.actionID) == ["b", "d"])
        // Keyword/category tier sits between title and text.
        let mixed = [
            try entry("t", title: "zzz", text: "ops here"),
            try entry("k", title: "yyy", keywords: ["ops"], text: "none"),
            try entry("n", title: "ops first", text: "none"),
        ]
        #expect(CmuxSnippetSearch.filter(mixed, query: "ops").map(\.actionID) == ["n", "k", "t"])
    }

    @Test func matchingIgnoresCaseAndDiacritics() throws {
        let all = try fixtures()
        #expect(CmuxSnippetSearch.filter(all, query: "CAFE").map(\.actionID) == ["c"])
        #expect(CmuxSnippetSearch.filter(all, query: "ALPHA").map(\.actionID) == ["a"])
    }

    @Test func noMatchReturnsEmptyAndEntryWithoutKeywordsStillDecodesFromOldInit() throws {
        let legacy = CmuxSnippetMenuEntry(
            actionID: "x", title: "X", category: nil,
            payload: try #require(CmuxTextActionPayload(text: "x", submit: false))
        )
        #expect(legacy.keywords.isEmpty)
        #expect(CmuxSnippetSearch.filter([legacy], query: "zzz").isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Users/tzgambo/Developer/cmux/Packages/macOS/CmuxTextActions && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CmuxSnippetSearchTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'CmuxSnippetSearch' in scope` and `extra argument 'keywords'`.

- [ ] **Step 3: Add `keywords` to the entry**

In `CmuxSnippetMenuModel.swift` replace the `CmuxSnippetMenuEntry` struct (lines 4-16) with:

```swift
/// One `type: "text"` action as the Snippets context menu and sidebar see it.
public struct CmuxSnippetMenuEntry: Sendable, Hashable {
    public var actionID: String
    public var title: String
    public var category: String?
    /// Palette keywords from the action definition; searched by the sidebar.
    public var keywords: [String]
    public var payload: CmuxTextActionPayload

    public init(
        actionID: String,
        title: String,
        category: String?,
        keywords: [String] = [],
        payload: CmuxTextActionPayload
    ) {
        self.actionID = actionID
        self.title = title
        self.category = category
        self.keywords = keywords
        self.payload = payload
    }
}
```

- [ ] **Step 4: Write the search**

Create `Packages/macOS/CmuxTextActions/Sources/CmuxTextActions/CmuxSnippetSearch.swift`:

```swift
import Foundation

/// Flat, ranked search over snippet entries for the Snippets sidebar.
///
/// The query is split on whitespace into terms. An entry matches when every
/// term is found, case- and diacritic-insensitively, in its title, category,
/// a keyword, or the text. Results are ranked by the weakest term: entries
/// whose terms all hit the title come first, then category or keyword hits,
/// then text-only hits; ties keep title order (then action id).
public enum CmuxSnippetSearch {
    public static func filter(
        _ entries: [CmuxSnippetMenuEntry],
        query: String
    ) -> [CmuxSnippetMenuEntry] {
        let ordered = entries.sorted(by: titleOrder)
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return ordered }

        var ranked: [(rank: Int, index: Int, entry: CmuxSnippetMenuEntry)] = []
        for (index, entry) in ordered.enumerated() {
            guard let rank = rank(of: entry, terms: terms) else { continue }
            ranked.append((rank, index, entry))
        }
        return ranked
            .sorted { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.index < rhs.index
            }
            .map(\.entry)
    }

    /// 0 = every term hits the title, 1 = weakest term hits category or a
    /// keyword, 2 = weakest term hits only the text, nil = some term misses.
    private static func rank(of entry: CmuxSnippetMenuEntry, terms: [String]) -> Int? {
        var worst = 0
        for term in terms {
            if contains(entry.title, term) {
                continue
            }
            if contains(entry.category ?? "", term) || entry.keywords.contains(where: { contains($0, term) }) {
                worst = max(worst, 1)
            } else if contains(entry.payload.text, term) {
                worst = max(worst, 2)
            } else {
                return nil
            }
        }
        return worst
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func titleOrder(_ lhs: CmuxSnippetMenuEntry, _ rhs: CmuxSnippetMenuEntry) -> Bool {
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.actionID < rhs.actionID
        }
    }
}
```

- [ ] **Step 5: Run all package tests to verify they pass**

Run: `cd /Users/tzgambo/Developer/cmux/Packages/macOS/CmuxTextActions && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E '✘|Test run|error:'`
Expected: `Test run with 24 tests in 3 suites passed` (18 existing + 6 new), no `✘`.

- [ ] **Step 6: Commit**

```bash
cd /Users/tzgambo/Developer/cmux && python3 scripts/swift_file_length_budget.py && \
git add Packages/macOS/CmuxTextActions && \
git commit -m "feat(snippets): ranked flat search over snippet entries

CmuxSnippetSearch.filter matches every whitespace-separated term against
title, category, keywords, and text (case- and diacritic-insensitive) and
ranks by the weakest term: title hits first, then category/keyword, then
text, ties in title order. CmuxSnippetMenuEntry gains keywords with a
defaulted init parameter so the context-menu callers compile unchanged."
```

---

### Task 2: Sidebar store in the app

**Files:**
- Modify: `Sources/CmuxConfig.swift:3010-3020` (`snippetMenuEntries()` passes keywords; line-neutral)
- Create: `Sources/SnippetsSidebarStore.swift`
- Test: `cmuxTests/SnippetsSidebarStoreTests.swift`

**Interfaces:**
- Consumes: `CmuxConfigStore(globalConfigPath:localConfigPath:startFileWatchers:)`, `.loadAll()`, `@Published configRevision: UInt64`, `snippetMenuEntries() -> [CmuxSnippetMenuEntry]`, `CmuxResolvedConfigAction.keywords: [String]`, `CmuxSnippetSearch.filter`.
- Produces: `@MainActor final class SnippetsSidebarStore: ObservableObject` with `@Published var query: String`, `@Published private(set) var entries: [CmuxSnippetMenuEntry]`, `@Published private(set) var results: [CmuxSnippetMenuEntry]`, `@Published private(set) var selectedActionID: String?`, `var selectedEntry: CmuxSnippetMenuEntry?`, `func attach(configStore: CmuxConfigStore)`, `func detach()`, `func select(actionID: String)`, `func moveSelection(by delta: Int)`.

- [ ] **Step 1: Write the failing tests**

Create `cmuxTests/SnippetsSidebarStoreTests.swift`:

```swift
import Foundation
import Testing
import CmuxTextActions

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Snippets sidebar store: loads text actions from a config store,
/// filters through CmuxSnippetSearch, keeps the keyboard selection valid.
@MainActor
struct SnippetsSidebarStoreTests {
    private func makeConfigStore(_ json: String) throws -> (store: CmuxConfigStore, url: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-snippets-sidebar-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("cmux.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(globalConfigPath: url.path, localConfigPath: nil, startFileWatchers: false)
        store.loadAll()
        return (store, url, { try? FileManager.default.removeItem(at: root) })
    }

    private let config = """
    {
      "actions": {
        "run-tests": { "type": "command", "title": "Run Tests", "command": "npm test" },
        "fixup": { "type": "text", "category": "Git", "title": "Fixup", "keywords": ["amend"], "text": "git commit --fixup HEAD" },
        "review": { "type": "text", "title": "Review Prompt", "text": "review this" }
      }
    }
    """

    @Test func attachLoadsOnlyTextActionsWithKeywordsAndSelectsTheTop() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        #expect(store.entries.map(\.actionID).sorted() == ["fixup", "review"])
        #expect(store.entries.first { $0.actionID == "fixup" }?.keywords == ["amend"])
        #expect(store.results.map(\.title) == ["Fixup", "Review Prompt"])
        #expect(store.selectedActionID == "fixup")
    }

    @Test func queryFiltersResultsAndClampsSelection() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        store.select(actionID: "review")
        #expect(store.selectedActionID == "review")
        store.query = "amend"
        #expect(store.results.map(\.actionID) == ["fixup"])
        #expect(store.selectedActionID == "fixup")
        store.query = "nothing-matches"
        #expect(store.results.isEmpty)
        #expect(store.selectedActionID == nil)
        #expect(store.selectedEntry == nil)
    }

    @Test func moveSelectionStaysInsideResults() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        store.moveSelection(by: -1)
        #expect(store.selectedActionID == "fixup")
        store.moveSelection(by: 1)
        #expect(store.selectedActionID == "review")
        store.moveSelection(by: 5)
        #expect(store.selectedActionID == "review")
        #expect(store.selectedEntry?.title == "Review Prompt")
    }

    @Test func configReloadRefreshesEntriesAndDetachStopsObserving() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        try """
        { "actions": { "only": { "type": "text", "title": "Only", "text": "uptime" } } }
        """.write(to: made.url, atomically: true, encoding: .utf8)
        made.store.loadAll()
        #expect(store.entries.map(\.actionID) == ["only"])
        #expect(store.selectedActionID == "only")

        store.detach()
        try config.write(to: made.url, atomically: true, encoding: .utf8)
        made.store.loadAll()
        #expect(store.entries.map(\.actionID) == ["only"], "a detached store no longer follows reloads")
    }
}
```

- [ ] **Step 2: Wire the test file and verify it fails to compile**

Run: `cd /Users/tzgambo/Developer/cmux && scripts/sync-test-wiring && ./scripts/lint-pbxproj-test-wiring.sh | tail -1`
Expected: wiring ok. Then run the build command from Global Constraints with `-only-testing:cmuxTests/SnippetsSidebarStoreTests`.
Expected: `error: cannot find 'SnippetsSidebarStore' in scope`.

- [ ] **Step 3: Pass keywords from the config store (line-neutral edit)**

In `Sources/CmuxConfig.swift` inside `snippetMenuEntries()` (around line 3013), replace

```swift
                category: action.category,
                payload: payload
```

with

```swift
                category: action.category, keywords: action.keywords,
                payload: payload
```

(The file is over budget, so the two lines stay two lines.)

- [ ] **Step 4: Write the store**

Create `Sources/SnippetsSidebarStore.swift`:

```swift
import Combine
import CmuxTextActions
import Foundation

/// State behind the Snippets sidebar: the loaded text actions, the live
/// query, the ranked results, and the keyboard selection. Owned by the
/// sidebar view; attached to the window's `CmuxConfigStore` while visible.
@MainActor
final class SnippetsSidebarStore: ObservableObject {
    @Published private(set) var entries: [CmuxSnippetMenuEntry] = []
    @Published private(set) var results: [CmuxSnippetMenuEntry] = []
    @Published private(set) var selectedActionID: String?
    @Published var query: String = "" {
        didSet { refreshResults() }
    }

    private var revisionObservation: AnyCancellable?

    var selectedEntry: CmuxSnippetMenuEntry? {
        guard let selectedActionID else { return nil }
        return results.first { $0.actionID == selectedActionID }
    }

    /// Loads the entries now and again on every config revision until
    /// `detach()`; the store never retains the config store.
    func attach(configStore: CmuxConfigStore) {
        reload(from: configStore)
        revisionObservation = configStore.$configRevision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak configStore] _ in
                guard let self, let configStore else { return }
                self.reload(from: configStore)
            }
    }

    func detach() {
        revisionObservation = nil
    }

    func select(actionID: String) {
        guard results.contains(where: { $0.actionID == actionID }) else { return }
        selectedActionID = actionID
    }

    /// Moves the selection by `delta` rows, clamped to the results.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else {
            selectedActionID = nil
            return
        }
        let current = results.firstIndex { $0.actionID == selectedActionID } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedActionID = results[next].actionID
    }

    private func reload(from configStore: CmuxConfigStore) {
        entries = configStore.snippetMenuEntries()
        refreshResults()
    }

    /// Recomputes the ranked results and keeps the selection on a visible
    /// row, falling back to the top result.
    private func refreshResults() {
        results = CmuxSnippetSearch.filter(entries, query: query)
        if let selectedActionID, results.contains(where: { $0.actionID == selectedActionID }) {
            return
        }
        selectedActionID = results.first?.actionID
    }
}
```

- [ ] **Step 5: Wire the source file and run the suite**

Run: `cd /Users/tzgambo/Developer/cmux && python3 scripts/wire-app-sources.py && python3 scripts/wire-app-sources.py --check && ./scripts/check-pbxproj.sh | tail -1`
Expected: the new file is added to the `cmux` target; checks pass.

Run the build command with `-only-testing:cmuxTests/SnippetsSidebarStoreTests -only-testing:cmuxTests/CmuxTextActionConfigTests`.
Expected: `TEST SUCCEEDED`, both suites `✔`.

- [ ] **Step 6: Commit**

```bash
cd /Users/tzgambo/Developer/cmux && python3 scripts/swift_file_length_budget.py && \
git add Sources/SnippetsSidebarStore.swift Sources/CmuxConfig.swift cmux.xcodeproj/project.pbxproj cmuxTests/SnippetsSidebarStoreTests.swift && \
git commit -m "feat(snippets): sidebar store that filters text actions and tracks a selection

SnippetsSidebarStore attaches to a CmuxConfigStore, reloads its text
actions on every config revision, runs CmuxSnippetSearch over the live
query, and keeps the keyboard selection on a visible row (top result as
the fallback). snippetMenuEntries now carries the action keywords."
```

---

### Task 3: Register the Snippets mode, its shortcut, and its focus plumbing

**Files:**
- Modify: `Sources/RightSidebarMode.swift:4-50`
- Modify: `Sources/RightSidebarMode+Availability.swift` (the `isAvailable(feedEnabled:machinesEnabled:devicesEnabled:)` switch, around lines 93-110)
- Modify: `Sources/KeyboardShortcutSettings.swift:120, :279, :489-500` (line-neutral or shrinking)
- Modify: `Sources/KeyboardShortcutSettings+ActionVisibility.swift:5-10`
- Modify: `Sources/KeyboardShortcutActionContext.swift:236-238, :261-262`
- Modify: `Sources/AppDelegate+DockShortcutRouting.swift:110-115`
- Modify: `Sources/RightSidebarToolPanel.swift:86-93, :126-131, :149-155` (three switches)
- Modify: `Sources/MainWindowFocusController.swift` (line-neutral; see offsets)
- Create: `Sources/SnippetsKeyboardFocusView.swift`
- Modify: `Resources/Localizable.xcstrings` (two keys)
- Test: `cmuxTests/SnippetsSidebarModeTests.swift`

**Interfaces:**
- Produces: `RightSidebarMode.snippets` (rawValue `"snippets"`, label key `rightSidebar.mode.snippets`, symbol `text.badge.plus`, `shortcutAction == .switchRightSidebarToSnippets`, not a pane mode, always available, listed after `.machines` so existing positional digits do not move); `KeyboardShortcutSettings.Action.switchRightSidebarToSnippets`; `final class SnippetsKeyboardFocusView: NSView` with `var focusSearchField: (() -> Bool)?`, `var ownsResponder: ((NSResponder) -> Bool)?`, `func focusFirstItemFromCoordinator()`, `func focusHostFromCoordinator() -> Bool`, `func ownsKeyboardFocus(_:) -> Bool`, `func registerWithKeyboardFocusCoordinatorIfNeeded()`; `MainWindowFocusController.registerSnippetsHost(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `cmuxTests/SnippetsSidebarModeTests.swift`:

```swift
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Snippets tool is an ordinary right-sidebar mode: always available,
/// hideable through the tab preferences, with its own switch action.
@MainActor
struct SnippetsSidebarModeTests {
    private func makeDefaults() -> UserDefaults {
        let name = "SnippetsSidebarModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func modeIdentity() {
        #expect(RightSidebarMode.snippets.rawValue == "snippets")
        #expect(RightSidebarMode.snippets.symbolName == "text.badge.plus")
        #expect(RightSidebarMode.snippets.shortcutAction == .switchRightSidebarToSnippets)
        #expect(!RightSidebarMode.snippets.canOpenAsPane)
        #expect(RightSidebarMode.snippets.label == "Snippets")
        #expect(KeyboardShortcutSettings.Action.switchRightSidebarToSnippets.label == "Show Sidebar Snippets")
    }

    @Test func alwaysAvailableAndListedAfterCloud() throws {
        #expect(RightSidebarMode.snippets.isAvailable(feedEnabled: false, machinesEnabled: false, devicesEnabled: false))
        let modes = RightSidebarMode.availableModes(feedEnabled: true, machinesEnabled: true)
        let cloud = try #require(modes.firstIndex(of: .machines))
        #expect(modes.firstIndex(of: .snippets) == cloud + 1)
    }

    @Test func hiddenTabDropsOutOfPositionalDigits() {
        let defaults = makeDefaults()
        #expect(RightSidebarMode.visibleModes(defaults: defaults).contains(.snippets))
        RightSidebarTabPreferences.setHidden(true, for: .snippets, defaults: defaults)
        #expect(!RightSidebarMode.visibleModes(defaults: defaults).contains(.snippets))
        #expect(RightSidebarMode.positionalDigit(for: .snippets, defaults: defaults) == nil)
    }

    @Test func switchActionIsPrivateAndRoutedLikeTheOtherModeSwitches() {
        let action = KeyboardShortcutSettings.Action.switchRightSidebarToSnippets
        #expect(!action.isPublicShortcutAction)
        #expect(action.hasPriorityShortcutRouting == KeyboardShortcutSettings.Action.switchRightSidebarToMachines.hasPriorityShortcutRouting)
    }
}
```

Before writing step 2, confirm the `RightSidebarTabPreferences.setHidden` signature with `grep -n 'func setHidden' Sources/RightSidebarTabPreferences.swift` and adjust the call (the plan assumes `setHidden(_ hidden: Bool, for mode: RightSidebarMode, defaults: UserDefaults)`); likewise `hasPriorityShortcutRouting` is in `Sources/KeyboardShortcutActionContext.swift:233`.

- [ ] **Step 2: Wire the test and verify it fails**

Run: `cd /Users/tzgambo/Developer/cmux && scripts/sync-test-wiring`, then the build command with `-only-testing:cmuxTests/SnippetsSidebarModeTests`.
Expected: `error: type 'RightSidebarMode' has no member 'snippets'`.

- [ ] **Step 3: Add the mode**

In `Sources/RightSidebarMode.swift`, add the case after `case machines` and a line in each of the three switches, mirroring `.machines`:

```swift
    case machines
    case snippets
```
```swift
        case .machines: return String(localized: "rightSidebar.mode.machines", defaultValue: "Cloud")
        case .snippets: return String(localized: "rightSidebar.mode.snippets", defaultValue: "Snippets")
```
```swift
        case .machines: return "cloud"
        case .snippets: return "text.badge.plus"
```
```swift
        case .machines: return .switchRightSidebarToMachines
        case .snippets: return .switchRightSidebarToSnippets
```

In `Sources/RightSidebarMode+Availability.swift`, find the `func isAvailable(feedEnabled:machinesEnabled:devicesEnabled:)` switch (around line 93) and add:

```swift
        case .snippets:
            return true
```

- [ ] **Step 4: Add the shortcut action (line-neutral in the 2605-line file)**

In `Sources/KeyboardShortcutSettings.swift`:

1. After `case switchRightSidebarToMachines` (line 120) add `case switchRightSidebarToSnippets`.
2. After the Machines label line (279) add:
   ```swift
            case .switchRightSidebarToSnippets: return String(localized: "shortcut.switchRightSidebarToSnippets.label", defaultValue: "Show Sidebar Snippets")
   ```
3. Replace the twelve lines of the six positional-default cases (489-500, from `case .switchRightSidebarToFiles:` through `return KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .machines)`) with:
   ```swift
            case .switchRightSidebarToFiles, .switchRightSidebarToFind, .switchRightSidebarToSessions,
                 .switchRightSidebarToFeed, .switchRightSidebarToDock, .switchRightSidebarToMachines,
                 .switchRightSidebarToSnippets:
                return KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(
                    for: RightSidebarMode.allCases.first { $0.shortcutAction == self } ?? .files
                )
   ```
   Net change: +2 −6 = the file shrinks by 4 lines. Then build once; the compiler lists any other exhaustive `switch` over `Action` that needs the new case (expected: none beyond those above, because the other sites use `default:`). If one appears, add `.switchRightSidebarToSnippets` beside `.switchRightSidebarToMachines` on the same line.

In `Sources/KeyboardShortcutSettings+ActionVisibility.swift`, `Sources/KeyboardShortcutActionContext.swift` (both lists, lines 236-238 and 261-262) and `Sources/AppDelegate+DockShortcutRouting.swift` (line 115), add `.switchRightSidebarToSnippets` directly after `.switchRightSidebarToMachines` in each list (these files are under 500 lines).

- [ ] **Step 5: Teach the tool panel and the focus controller about the mode**

`Sources/RightSidebarToolPanel.swift` (391 lines): in the three `switch mode` statements (`syncWorkspaceRoot`, `focus`, `ownedFocusIntent`) change each `case .feed, .dock, .machines, .customSidebar:` to `case .feed, .dock, .machines, .snippets, .customSidebar:`.

Create `Sources/SnippetsKeyboardFocusView.swift` (modeled on `DockKeyboardFocusView` in `Sources/DockPanelView.swift:267-292`):

```swift
import AppKit

/// Keyboard-focus host for the Snippets sidebar. The focus coordinator
/// hands the tool focus through this view: "first item" means the search
/// field; the host itself is the fallback responder. Ownership checks let
/// the coordinator treat the search field as sidebar focus so terminal focus
/// is restored correctly when the sidebar hides.
final class SnippetsKeyboardFocusView: NSView {
    var focusSearchField: (() -> Bool)?
    var ownsResponder: ((NSResponder) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerSnippetsHost(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        return ownsResponder?(responder) == true
    }

    func focusFirstItemFromCoordinator() {
        _ = focusSearchField?()
    }

    func focusHostFromCoordinator() -> Bool {
        focusSearchField?() == true || window?.makeFirstResponder(self) == true
    }
}
```

`Sources/MainWindowFocusController.swift` (865 lines, must not grow). Make these edits, then apply the offsets below:

1. After `private weak var dockHost: DockKeyboardFocusView?` (near line 40) add `private weak var snippetsHost: SnippetsKeyboardFocusView?`.
2. After `registerDockHost` (line 142-145) add:
   ```swift
    func registerSnippetsHost(_ host: SnippetsKeyboardFocusView) {
        snippetsHost = host
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .snippets)
    }
   ```
3. In `ownsRightSidebarFocus` (line 227) add before `return false`:
   ```swift
        if snippetsHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
   ```
4. In `rightSidebarModeOwning` add before `return nil`:
   ```swift
        if snippetsHost?.ownsKeyboardFocus(responder) == true {
            return .snippets
        }
   ```
5. In `rightSidebarFocusTarget` (line 741) replace the separate `.feed` and `.dock` cases with one:
   ```swift
        case .feed, .dock, .snippets:
            return focusFirstItem ? .firstItem : .host
   ```
6. In `focusRightSidebarEndpoint` (line 759) add after the `.dock` branch:
   ```swift
        case .snippets:
            if target == .firstItem {
                snippetsHost?.focusFirstItemFromCoordinator()
            }
            return snippetsHost?.focusHostFromCoordinator() == true
   ```

Offsets (the edits above add 15 lines and remove 2): rewrite the two accessors of `RightSidebarFocusState` (lines 29-45) as switch expressions on one line each, which removes about 12 lines:
```swift
        var mode: RightSidebarMode? {
            switch self { case .inactive: nil; case .requested(let r): r.mode; case .focused(let m, _): m }
        }
        var request: RightSidebarFocusRequest? {
            if case .requested(let request) = self { return request }
            return nil
        }
```
Then run `python3 scripts/swift_file_length_budget.py`; if the file is still over its 865-line budget, join the multi-line `dlog(` string concatenations inside `#if DEBUG` blocks in `focusRightSidebar(mode:target:terminalYieldReason:)` onto single lines until it passes (no behavior change).

- [ ] **Step 6: Localize the two strings**

Run this once (adds `rightSidebar.mode.snippets` and `shortcut.switchRightSidebarToSnippets.label` with all nine locales):

```bash
cd /Users/tzgambo/Developer/cmux && python3 - <<'EOF'
import json
p = "Resources/Localizable.xcstrings"
d = json.load(open(p, encoding="utf-8"))
def put(key, values):
    d["strings"][key] = {"extractionState": "manual", "localizations": {
        loc: {"stringUnit": {"state": "translated", "value": v}} for loc, v in values.items()}}
put("rightSidebar.mode.snippets", {"en": "Snippets", "ja": "スニペット", "de": "Snippets", "fr": "Snippets",
    "ar": "المقتطفات", "es": "Fragmentos", "zh-Hant": "程式碼片段", "zh-Hans": "代码片段", "ko": "스니펫"})
put("shortcut.switchRightSidebarToSnippets.label", {"en": "Show Sidebar Snippets",
    "ja": "サイドバーのスニペットを表示", "de": "Seitenleiste: Snippets anzeigen",
    "fr": "Afficher les snippets de la barre latérale", "ar": "إظهار مقتطفات الشريط الجانبي",
    "es": "Mostrar fragmentos de la barra lateral", "zh-Hant": "顯示側邊欄程式碼片段",
    "zh-Hans": "显示侧边栏代码片段", "ko": "사이드바 스니펫 표시"})
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(p, "a", encoding="utf-8").write("\n")
EOF
python3 scripts/lint-xcstrings.py && python3 scripts/localization_catalog.py check
```

Expected: both checks pass. If `lint-xcstrings.py` complains about key ordering or formatting, run the repo's formatter it names and re-check.

- [ ] **Step 7: Build, run the mode tests and the existing sidebar tests**

Run `python3 scripts/wire-app-sources.py && python3 scripts/wire-app-sources.py --check`, then the build command with
`-only-testing:cmuxTests/SnippetsSidebarModeTests -only-testing:cmuxTests/RightSidebarModeShortcutHintTests -only-testing:cmuxTests/RightSidebarTabCustomizationTests -only-testing:cmuxTests/RightSidebarCommandPaletteTests -only-testing:cmuxTests/DevicesSidebarModeTests`.
Expected: `TEST SUCCEEDED`. If an existing test enumerates every mode and now fails on the extra entry, fix its expectation in place (`cmuxTests/ShortcutAndCommandPaletteTests.swift` may not grow; edit existing lines only, e.g. append `.switchRightSidebarToSnippets,` to an existing list line). Machines keeps ctrl+6 because Snippets is listed after it.

- [ ] **Step 8: Commit**

```bash
cd /Users/tzgambo/Developer/cmux && python3 scripts/swift_file_length_budget.py && \
git add Sources/RightSidebarMode.swift Sources/RightSidebarMode+Availability.swift Sources/KeyboardShortcutSettings.swift \
  Sources/KeyboardShortcutSettings+ActionVisibility.swift Sources/KeyboardShortcutActionContext.swift \
  Sources/AppDelegate+DockShortcutRouting.swift Sources/RightSidebarToolPanel.swift Sources/MainWindowFocusController.swift \
  Sources/SnippetsKeyboardFocusView.swift Resources/Localizable.xcstrings cmux.xcodeproj/project.pbxproj \
  cmuxTests/SnippetsSidebarModeTests.swift cmuxTests/ShortcutAndCommandPaletteTests.swift && \
git commit -m "feat(snippets): register the Snippets right-sidebar mode and its switch shortcut

A new RightSidebarMode after Cloud (so existing ctrl+digit defaults keep
their positions), always available, hideable and reorderable through the
existing Sidebar tabs preferences. switchRightSidebarToSnippets joins the
private mode-switch actions with the positional default; the six positional
cases collapse into one lookup. The focus coordinator gets a Snippets host
whose first item is the search field, mirroring the Dock host."
```

---

### Task 4: The sidebar view and delivery

**Files:**
- Create: `Sources/SnippetsSidebarView.swift`
- Create: `Sources/SnippetsSidebarRow.swift`
- Create: `Sources/SnippetsSidebarFocusBridge.swift`
- Modify: `Sources/RightSidebarPanelView.swift:431-482` (`contentForMode`; line-neutral)
- Modify: `Resources/Localizable.xcstrings` (four keys)

**Interfaces:**
- Consumes: `SnippetsSidebarStore`, `SnippetsKeyboardFocusView`, `SidebarSearchFieldView(text:placeholder:accessibilityIdentifier:onSubmit:onCommandSubmit:)`, `SidebarSearchField.visibleHeight/.leadingPadding/.topPadding`, `RightSidebarChromeMetrics.headerTrailingPadding/.barVerticalPadding`, `RightSidebarKeyboardNavigation.moveDelta(for:)/.isPlainSlash(_:)`, `CmuxConfigStore.resolvedAction(id:)`, `CmuxConfigExecutor.deliverTextActionIfAuthorized(...)`, `CmuxConfigExecutor.deliver(_:to:)`, `TabManager.selectedWorkspace?.focusedTerminalInputTarget()?.panel`, `AppDelegate.shared?.keyboardFocusCoordinator(for:)?.restoreFocusedPanelFocusFromRightSidebarIfNeeded()`.
- Produces: `struct SnippetsSidebarView: View` with `init(tabManager: TabManager)`.

- [ ] **Step 1: Localize the view strings**

```bash
cd /Users/tzgambo/Developer/cmux && python3 - <<'EOF'
import json
p = "Resources/Localizable.xcstrings"
d = json.load(open(p, encoding="utf-8"))
def put(key, values):
    d["strings"][key] = {"extractionState": "manual", "localizations": {
        loc: {"stringUnit": {"state": "translated", "value": v}} for loc, v in values.items()}}
put("snippetsSidebar.searchPlaceholder", {"en": "Search snippets…", "ja": "スニペットを検索…", "de": "Snippets durchsuchen…",
    "fr": "Rechercher des snippets…", "ar": "البحث في المقتطفات…", "es": "Buscar fragmentos…",
    "zh-Hant": "搜尋程式碼片段…", "zh-Hans": "搜索代码片段…", "ko": "스니펫 검색…"})
put("snippetsSidebar.empty.title", {"en": "No snippets configured", "ja": "スニペットが設定されていません",
    "de": "Keine Snippets konfiguriert", "fr": "Aucun snippet configuré", "ar": "لا توجد مقتطفات مُعدّة",
    "es": "No hay fragmentos configurados", "zh-Hant": "尚未設定程式碼片段", "zh-Hans": "尚未配置代码片段",
    "ko": "설정된 스니펫이 없습니다"})
put("snippetsSidebar.empty.hint", {"en": "Add a type \"text\" action to cmux.json.",
    "ja": "cmux.json に type \"text\" のアクションを追加してください。",
    "de": "Fügen Sie cmux.json eine Aktion vom Typ \"text\" hinzu.",
    "fr": "Ajoutez une action de type \"text\" à cmux.json.", "ar": "أضف إجراءً من النوع \"text\" إلى cmux.json.",
    "es": "Añade una acción de tipo \"text\" a cmux.json.", "zh-Hant": "在 cmux.json 中新增 type 為 \"text\" 的動作。",
    "zh-Hans": "在 cmux.json 中添加 type 为 \"text\" 的动作。", "ko": "cmux.json에 type \"text\" 동작을 추가하세요."})
put("snippetsSidebar.noMatches", {"en": "No matches", "ja": "一致する項目がありません", "de": "Keine Treffer",
    "fr": "Aucun résultat", "ar": "لا توجد نتائج مطابقة", "es": "Sin coincidencias", "zh-Hant": "沒有相符項目",
    "zh-Hans": "没有匹配项", "ko": "일치하는 항목 없음"})
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
open(p, "a", encoding="utf-8").write("\n")
EOF
python3 scripts/lint-xcstrings.py && python3 scripts/localization_catalog.py check
```

- [ ] **Step 2: Write the row view**

Create `Sources/SnippetsSidebarRow.swift`:

```swift
import CmuxTextActions
import SwiftUI

/// One snippet in the sidebar list: title, optional category tag, and the
/// first line of the text. Click selects and delivers.
struct SnippetsSidebarRow: View {
    let entry: CmuxSnippetMenuEntry
    let isSelected: Bool
    let onActivate: () -> Void

    private var preview: String {
        entry.payload.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .cmuxFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                    if let category = entry.category {
                        Text(category)
                            .cmuxFont(size: 9, weight: .medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.16)))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(preview)
                    .cmuxFont(size: 11, design: .monospaced)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, RightSidebarChromeMetrics.contentIconLeadingPadding)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SnippetsSidebarRow-\(entry.actionID)")
    }
}
```

If `cmuxFont(size:weight:)` or `cmuxFont(size:design:)` do not exist with those labels, check `grep -rn 'func cmuxFont' Sources | head` and use the available overloads (the Vault rows in `Sources/SessionIndexView.swift` use `.cmuxFont(size: 10, weight: .semibold)` and `.cmuxFont(size:design:)`).

- [ ] **Step 3: Write the focus bridge**

Create `Sources/SnippetsSidebarFocusBridge.swift`:

```swift
import AppKit
import SwiftUI

/// Hosts the Snippets keyboard-focus view inside SwiftUI and owns the local
/// key monitor that drives the list while the search field or the host has
/// focus: Up/Down, j/k and Ctrl+N/P move, Return activates, Escape returns
/// focus to the terminal, and "/" on the host focuses the search field.
struct SnippetsSidebarFocusBridge: NSViewRepresentable {
    static let searchFieldIdentifier = "SnippetsSidebarSearchField"

    let onMove: (Int) -> Void
    let onActivate: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> SnippetsKeyboardFocusView {
        let view = SnippetsKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ view: SnippetsKeyboardFocusView, context: Context) {
        context.coordinator.parent = self
        view.focusSearchField = { Self.focusSearchField(in: view.window) }
        view.ownsResponder = { responder in Self.responderIsSearchField(responder, in: view.window) }
        view.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func searchField(in window: NSWindow?) -> SidebarSearchField? {
        guard let root = window?.contentView else { return nil }
        return firstSearchField(in: root)
    }

    private static func firstSearchField(in view: NSView) -> SidebarSearchField? {
        if let field = view as? SidebarSearchField,
           field.accessibilityIdentifier() == searchFieldIdentifier {
            return field
        }
        for subview in view.subviews {
            if let found = firstSearchField(in: subview) { return found }
        }
        return nil
    }

    static func focusSearchField(in window: NSWindow?) -> Bool {
        guard let window, let field = searchField(in: window) else { return false }
        return window.makeFirstResponder(field)
    }

    static func responderIsSearchField(_ responder: NSResponder, in window: NSWindow?) -> Bool {
        guard let field = searchField(in: window) else { return false }
        if responder === field { return true }
        if let textView = responder as? NSTextView, textView.delegate === field { return true }
        return false
    }

    @MainActor
    final class Coordinator {
        var parent: SnippetsSidebarFocusBridge
        private var monitor: Any?

        init(parent: SnippetsSidebarFocusBridge) { self.parent = parent }

        func install(on host: SnippetsKeyboardFocusView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak host] event in
                guard let self, let host, let window = host.window, window.isKeyWindow,
                      let responder = window.firstResponder, host.ownsKeyboardFocus(responder) else {
                    return event
                }
                if event.keyCode == 53 { // Escape
                    self.parent.onEscape()
                    return nil
                }
                if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
                    self.parent.onActivate()
                    return nil
                }
                if responder === host, RightSidebarKeyboardNavigation.isPlainSlash(event) {
                    _ = SnippetsSidebarFocusBridge.focusSearchField(in: window)
                    return nil
                }
                // j/k only steer the list while the host (not the text field) is first responder.
                let isTextEntry = responder !== host
                if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event),
                   !(isTextEntry && (event.keyCode == 38 || event.keyCode == 40)) {
                    self.parent.onMove(delta)
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
```

- [ ] **Step 4: Write the sidebar view**

Create `Sources/SnippetsSidebarView.swift`:

```swift
import AppKit
import CmuxTextActions
import SwiftUI

/// Right-sidebar Snippets tool: a search field over every `type: "text"`
/// action and a flat, ranked list. Selecting a row pastes the snippet into
/// the focused terminal through the project-trust gate.
struct SnippetsSidebarView: View {
    @ObservedObject var tabManager: TabManager
    @EnvironmentObject private var cmuxConfigStore: CmuxConfigStore
    @StateObject private var store = SnippetsSidebarStore()
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    private var searchFieldHeight: CGFloat {
        _ = globalFontPercent
        return SidebarSearchField.visibleHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        .background(
            SnippetsSidebarFocusBridge(
                onMove: { store.moveSelection(by: $0) },
                onActivate: activateSelection,
                onEscape: returnFocusToTerminal
            )
            .frame(width: 1, height: 1)
        )
        .onAppear { store.attach(configStore: cmuxConfigStore) }
        .onDisappear { store.detach() }
    }

    private var searchBar: some View {
        SidebarSearchFieldView(
            text: $store.query,
            placeholder: String(localized: "snippetsSidebar.searchPlaceholder", defaultValue: "Search snippets…"),
            accessibilityIdentifier: SnippetsSidebarFocusBridge.searchFieldIdentifier,
            onSubmit: activateSelection,
            onCommandSubmit: activateSelection
        )
        .frame(height: searchFieldHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .titlebarInteractiveControl()
        .padding(.leading, SidebarSearchField.leadingPadding)
        .padding(.trailing, RightSidebarChromeMetrics.headerTrailingPadding)
        .padding(.top, SidebarSearchField.topPadding)
        .padding(.bottom, RightSidebarChromeMetrics.barVerticalPadding)
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            emptyState(
                title: String(localized: "snippetsSidebar.empty.title", defaultValue: "No snippets configured"),
                detail: String(localized: "snippetsSidebar.empty.hint", defaultValue: "Add a type \"text\" action to cmux.json.")
            )
        } else if store.results.isEmpty {
            emptyState(title: String(localized: "snippetsSidebar.noMatches", defaultValue: "No matches"), detail: nil)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.results, id: \.actionID) { entry in
                            SnippetsSidebarRow(
                                entry: entry,
                                isSelected: entry.actionID == store.selectedActionID,
                                onActivate: {
                                    store.select(actionID: entry.actionID)
                                    deliver(entry)
                                }
                            )
                            .id(entry.actionID)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: store.selectedActionID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func emptyState(title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .cmuxFont(size: 12, weight: .medium)
                .foregroundColor(.secondary)
            if let detail {
                Text(detail)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activateSelection() {
        guard let entry = store.selectedEntry else {
            NSSound.beep()
            return
        }
        deliver(entry)
    }

    /// Same gate and delivery as the palette and the context menu: the
    /// workspace's focused terminal input target stays valid while the
    /// sidebar holds key focus. A refused paste beeps and keeps the sidebar.
    private func deliver(_ entry: CmuxSnippetMenuEntry) {
        guard let action = cmuxConfigStore.resolvedAction(id: entry.actionID),
              let payload = action.action.textPayload,
              let panel = tabManager.selectedWorkspace?.focusedTerminalInputTarget()?.panel else {
            NSSound.beep()
            return
        }
        let window = NSApp.keyWindow
        let delivered = CmuxConfigExecutor.deliverTextActionIfAuthorized(
            payload,
            confirm: action.confirm ?? false,
            actionID: action.id,
            configSourcePath: action.actionSourcePath,
            globalConfigPath: cmuxConfigStore.globalConfigPath,
            displayTitle: action.title,
            icon: action.icon,
            iconSourcePath: action.iconSourcePath,
            presentingWindow: window
        ) {
            guard CmuxConfigExecutor.deliver(payload, to: panel) else {
                NSSound.beep()
                return false
            }
            return true
        }
        if delivered {
            returnFocusToTerminal()
        }
    }

    private func returnFocusToTerminal() {
        guard let window = NSApp.keyWindow,
              let coordinator = AppDelegate.shared?.keyboardFocusCoordinator(for: window) else { return }
        _ = coordinator.restoreFocusedPanelFocusFromRightSidebarIfNeeded()
    }
}
```

Check two names before building: `grep -n 'globalConfigPath' Sources/CmuxConfig.swift | head -3` (the store property used by the context menu is `store.globalConfigPath`), and `grep -n 'func keyboardFocusCoordinator(for' Sources/AppDelegate*.swift`. Use the exact spellings found.

- [ ] **Step 5: Mount the view (line-neutral edit to the 673-line panel view)**

In `Sources/RightSidebarPanelView.swift` `contentForMode`, replace

```swift
            case .feed:
                FeedPanelView(
                    chromeBackgroundColor: windowAppearance.resolvedChromeBackgroundColor
                )
```

with

```swift
            case .feed:
                FeedPanelView(chromeBackgroundColor: windowAppearance.resolvedChromeBackgroundColor)
            case .snippets:
                SnippetsSidebarView(tabManager: tabManager)
```

(−3 +2: the file shrinks by one line.)

- [ ] **Step 6: Wire, build, and run every text-action suite**

Run: `cd /Users/tzgambo/Developer/cmux && python3 scripts/wire-app-sources.py && python3 scripts/wire-app-sources.py --check && python3 scripts/swift_file_length_budget.py`, then the build command with
`-only-testing:cmuxTests/SnippetsSidebarStoreTests -only-testing:cmuxTests/SnippetsSidebarModeTests -only-testing:cmuxTests/CmuxTextActionConfigTests -only-testing:cmuxTests/CmuxTextActionTrustGateTests`.
Expected: `BUILD SUCCEEDED`, `TEST SUCCEEDED`. Fix any compile error at the named site (Swift 6 strict concurrency will flag non-`@MainActor` closures touching the store; the bridge's `Coordinator` is `@MainActor`, and `NSEvent.addLocalMonitorForEvents` handlers run on the main thread, so wrap the body in `MainActor.assumeIsolated { ... }` if the compiler requires it).

- [ ] **Step 7: Commit**

```bash
cd /Users/tzgambo/Developer/cmux && \
git add Sources/SnippetsSidebarView.swift Sources/SnippetsSidebarRow.swift Sources/SnippetsSidebarFocusBridge.swift \
  Sources/RightSidebarPanelView.swift Resources/Localizable.xcstrings cmux.xcodeproj/project.pbxproj && \
git commit -m "feat(snippets): searchable Snippets tool in the right sidebar

A search field over every type \"text\" action and a flat, ranked list
with title, category tag, and a one-line preview. Up/Down, j/k, Ctrl+N/P
move, Return pastes the selected row (top result while typing), Escape
hands focus back to the terminal, and \"/\" on the host focuses search.
Delivery goes through deliverTextActionIfAuthorized to the workspace's
focused terminal input target, exactly like the palette; a refused paste
beeps and keeps the sidebar."
```

---

### Task 5: Verify, dogfood, document

**Files:**
- Modify: `skills/cmux-customization/references/examples.md` (the "Prompt Snippets" section's closing paragraph)
- Modify: `docs/superpowers/plans/2026-10-15-snippets-sidebar.md` (tick boxes as you go)

- [ ] **Step 1: Static sweep and localization audit**

Run: `cd /Users/tzgambo/Developer/cmux && python3 scripts/verify-local.py 2>&1 | tail -3 && python3 scripts/localization_catalog.py check`
Expected: `PASSED: N/N selected checks ran` and the localization check clean.

- [ ] **Step 2: Full build of the two new suites plus the four existing sidebar suites**

Run the build command with
`-only-testing:cmuxTests/SnippetsSidebarStoreTests -only-testing:cmuxTests/SnippetsSidebarModeTests -only-testing:cmuxTests/RightSidebarModeShortcutHintTests -only-testing:cmuxTests/RightSidebarTabCustomizationTests -only-testing:cmuxTests/RightSidebarCommandPaletteTests -only-testing:cmuxTests/DevicesSidebarModeTests`.
Expected: `TEST SUCCEEDED`.

- [ ] **Step 3: Dogfood in the tagged build**

```bash
cd /Users/tzgambo/Developer/cmux && export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH" && \
unset CMUX_SOCKET_PATH CMUX_SOCKET && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/reload.sh --tag snippets --prod-auth 2>&1 | tail -4
open -n "$HOME/Library/Developer/Xcode/DerivedData/cmux-snippets/Build/Products/Debug/cmux DEV snippets.app"
```

Then, in the `cmux DEV snippets` app (never the user's `/Applications/cmux.app`):
1. ⌘⌥B shows the right sidebar; a **Snippets** tab is present after Cloud. Click it: the list shows the user's text actions with category tags, sorted by title.
2. Press the Snippets tab's ctrl+digit (the number shown in Settings > Sidebar tabs): the search field gets focus. Type `sql`: only SQL-category or sql-titled rows remain, the first is highlighted.
3. Press Down twice, then Return: the third row's text appears in the terminal line editor without running; focus is back in the terminal.
4. Press ctrl+digit again, press Escape: focus returns to the terminal, nothing pasted.
5. Settings > Sidebar tabs: toggle Snippets off; the tab disappears and the digits shift. Toggle it back on.
6. Run `CMUX_TAG=snippets scripts/cmux-debug-cli.sh reload-config` after editing a snippet title in `~/.config/cmux/cmux.json`: the list updates without restarting.

Record each outcome in the commit message of step 5 (pass/fail per item). A failure in 2–4 is a focus-coordinator issue: check `rightSidebarModeOwning` and the bridge's `ownsResponder` before anything else.

- [ ] **Step 4: Document the tool**

In `skills/cmux-customization/references/examples.md`, in the "Prompt Snippets" section, append this sentence to the paragraph that begins "Both entries appear in Cmd+Shift+P":

```
The right sidebar's **Snippets** tool (show it from Settings > Sidebar tabs) lists them with a search field; typing filters by title, category, keywords, and text, and Return pastes the highlighted snippet.
```

- [ ] **Step 5: Commit**

```bash
cd /Users/tzgambo/Developer/cmux && git add skills/cmux-customization/references/examples.md docs/superpowers/plans/2026-10-15-snippets-sidebar.md && \
git commit -m "docs(snippets): describe the Snippets sidebar tool

Dogfood in the tagged snippets build: <list the six checks from the plan with pass/fail>."
```
