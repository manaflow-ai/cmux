# Bare-key chord leaders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users configure a bare-key (no-modifier) chord prefix in `~/.config/cmux/settings.json` (e.g. `` ` `` as a tmux-style leader), bind it to existing pane actions, and double-tap the leader to send a literal character to the focused terminal.

**Architecture:** Two surgical changes to `Sources/AppDelegate.swift`:
1. Loosen the early-return guard in `handleCustomShortcut` so bare-key keyDown events can reach the chord-arming logic when at least one configured shortcut has a bare-key chord prefix.
2. At the fall-through tail of `handleCustomShortcut`, when a bare-key chord prefix is currently armed and the next event matches that same prefix key with no modifiers (and no configured chord binding matched), send the prefix character to the focused Ghostty surface and consume the event.

**Tech stack:** Swift, AppKit (`NSEvent` local monitor, `NSWindow` first responder), Ghostty C API via `TerminalSurface.sendText(_:)`. Tests use `XCTestCase` with the existing `AppDelegateShortcutRoutingTests` patterns (`withTemporaryShortcut`, `makeKeyDownEvent`, `debugHandleCustomShortcut`).

---

## Spec → impl deltas (read first)

While preparing this plan I verified that:

- `StoredShortcut.parseConfig(strokes:)` (`Sources/KeyboardShortcutSettings.swift:2123`) and `ShortcutStroke.parseConfig(_:)` (`Sources/KeyboardShortcutSettings.swift:1991`) already accept bare-key chord strokes with no per-position modifier requirement. The named token `backtick`/`grave`/`` ` `` is recognized at line 2080–2081. **No parser change needed.**
- `web/data/cmux-settings.schema.json` `shortcutBinding` definition is just `type: string` per stroke with no modifier-pattern constraint. **No schema change needed.**
- The shortcut recorder UI at `KeyboardShortcutSettings.swift:2280–2602` does **not** expose chord-mode entry. Per `Sources/cmuxApp.swift:6973` ("Add tmux-style multi-step shortcuts in settings.json"), chord shortcuts are configured **only** through the settings file. The `bareKeyNotAllowed` rejection at `KeyboardShortcutSettings.swift:1336–1340` only fires for single-stroke recording in the UI, which we deliberately keep. **No recorder change needed.**
- The runtime matcher (`StoredShortcut.matches(event:)` and `matchConfiguredShortcut`) does not gate on modifiers, so it already supports bare-key prefixes once they get through the early-return guard.

The **single missing gate** that makes bare-key chord leaders fail today is at `Sources/AppDelegate.swift:10591`:

```swift
if normalizedFlags.isEmpty && activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
    return false
}
```

When the user presses `` ` `` (no modifiers) and no chord is currently armed, this short-circuits before `armConfiguredShortcutChordIfNeeded` (line 10605) ever runs. Task 2 narrows that guard.

---

## File map

- **Modify:** `Sources/AppDelegate.swift`
  - Around line 10591: relax the bare-key early-return guard.
  - Around line 11190 (just before `return false` at the end of `handleCustomShortcut`): add the implicit double-tap-leader handler.
  - New private helper `hasConfiguredBareKeyChordPrefix()` near other configured-shortcut helpers (e.g. after `configuredShortcutChordActions` near line 12069).
  - New private helper `sendLiteralChordPrefixToFocusedSurface(prefix:event:)` near `focusedTerminalShortcutContext` at line 5279.
- **Modify:** `cmuxTests/AppDelegateShortcutRoutingTests.swift`
  - Add five tests near the existing chord tests (after `testChordedShortcutMismatchDoesNotConsumeSecondKey` at line 620).
- **Modify:** `web/app/[locale]/docs/keyboard-shortcuts/page.tsx` and the configuration page that documents `settings.json` chord syntax — add a short subsection on bare-key leaders and the implicit double-tap-to-literal behavior.

No files created, no schema files modified.

---

## Branch + worktree

- [ ] **Step 0: Create a worktree branch for the work**

```bash
cd /Users/robinjoseph/code/personal/cmux
git worktree add -b bare-key-chord-leaders ../../.worktrees/cmux-bare-key-chord-leaders main
cd ../../.worktrees/cmux-bare-key-chord-leaders
```

All subsequent paths in this plan are relative to the worktree root.

---

## Task 1: Failing test — bare-key prefix is dropped today

**Files:**
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift` (append after line 620)

This task locks in the current broken behavior as a red test, so the fix in Task 2 has something concrete to flip green. Per the project's regression-test commit policy, this commit must land *before* the fix.

- [ ] **Step 1: Write the failing test**

Append this to `cmuxTests/AppDelegateShortcutRoutingTests.swift`, inside `final class AppDelegateShortcutRoutingTests: XCTestCase`:

```swift
func testBareKeyChordPrefixArmsAndSplitsOnSecondKey() {
    guard let appDelegate = AppDelegate.shared else {
        XCTFail("Expected AppDelegate.shared")
        return
    }

    let windowId = appDelegate.createMainWindow()
    defer { closeWindow(withId: windowId) }

    guard let window = window(withId: windowId),
          let manager = appDelegate.tabManagerFor(windowId: windowId) else {
        XCTFail("Expected test window and manager")
        return
    }

    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    // Bind splitRight to ` then d (bare-key leader).
    let shortcut = StoredShortcut(
        key: "`",
        command: false,
        shift: false,
        option: false,
        control: false,
        chordKey: "d"
    )

    withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
        guard let prefixEvent = makeKeyDownEvent(
            key: "`",
            modifiers: [],
            keyCode: 50,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct backtick prefix event")
            return
        }

        guard let actionEvent = makeKeyDownEvent(
            key: "d",
            modifiers: [],
            keyCode: 2,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct d action event")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: prefixEvent),
            "Bare-key chord prefix must be consumed so the terminal does not receive `"
        )
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: actionEvent),
            "Second stroke after a bare-key chord prefix must dispatch the bound action"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
    _ = manager  // keep manager retained for the duration of the test
}
```

The keyCode `50` is the standard mac virtual keycode for the `` ` `` key (`kVK_ANSI_Grave`); keyCode `2` is `d`.

- [ ] **Step 2: Run the test and verify it fails today**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordPrefixArmsAndSplitsOnSecondKey
```

Expected: **FAIL** on the first XCTAssertTrue ("Bare-key chord prefix must be consumed…") because `handleCustomShortcut` returns false for the bare-key event at `Sources/AppDelegate.swift:10591`.

- [ ] **Step 3: Commit the failing test**

```bash
git add cmuxTests/AppDelegateShortcutRoutingTests.swift
git commit -m "Add failing test for bare-key chord leaders"
```

This commit intentionally goes red. The fix lands in Task 2 as a separate commit per the project's regression-test commit policy.

---

## Task 2: Allow bare-key chord prefixes through the early-return guard

**Files:**
- Modify: `Sources/AppDelegate.swift:10591` (the early-return guard) and add helper `hasConfiguredBareKeyChordPrefix()`.

- [ ] **Step 1: Add the helper method**

Insert this method into `extension AppDelegate` near the other configured-shortcut helpers (place it immediately above `private func armConfiguredShortcutChordIfNeeded` at line 12069):

```swift
/// True iff at least one configured shortcut has a chord whose first stroke has no modifiers.
/// Used by `handleCustomShortcut` to know whether bare-key keyDown events still need to be
/// considered for chord arming, instead of being short-circuited as non-shortcut input.
private func hasConfiguredBareKeyChordPrefix() -> Bool {
    // `preferredRegisteredMainWindowContext` has `preferredWindow: NSWindow? = nil`,
    // so we can call it with no argument here. `handleCustomShortcut` itself uses
    // `preferredMainWindowContextForShortcutRouting(event:)` at line 10602, but that
    // helper requires a real NSEvent. For this guard we just need a stable snapshot
    // of currently-configured shortcuts, so the registered-context source is fine.
    let context = preferredRegisteredMainWindowContext()
    let configuredShortcuts = configuredCmuxShortcutActions(for: context)
        .compactMap(\.shortcut)
    let builtInShortcuts = configuredShortcutChordActions.map {
        KeyboardShortcutSettings.shortcut(for: $0)
    }
    for shortcut in builtInShortcuts + configuredShortcuts {
        guard shortcut.hasChord else { continue }
        if shortcut.firstStroke.modifierFlags.isEmpty {
            return true
        }
    }
    return false
}
```

- [ ] **Step 2: Loosen the early-return guard**

Edit `Sources/AppDelegate.swift:10591` from:

```swift
        if normalizedFlags.isEmpty && activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            return false
        }
```

to:

```swift
        if normalizedFlags.isEmpty && activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            // Without modifiers and without an armed chord, the only way an event
            // can still be a shortcut is if the user configured a bare-key chord
            // leader (e.g. tmux-style ` as a prefix). Skip the early-return only
            // when such a binding actually exists.
            if !hasConfiguredBareKeyChordPrefix() {
                return false
            }
        }
```

- [ ] **Step 3: Verify Task 1's test now passes**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordPrefixArmsAndSplitsOnSecondKey
```

Expected: **PASS**. The bare-key event now reaches `armConfiguredShortcutChordIfNeeded`, which arms the prefix; the second key triggers `splitRight`.

- [ ] **Step 4: Run the existing chord regression suite**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testChordedNewWorkspaceShortcutConsumesPrefixAndTriggersOnSecondKey \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testChordedShortcutMismatchDoesNotConsumeSecondKey \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testConfiguredChordPrefixIsClearedWhenAppResignsActive \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testConfiguredChordPrefixBeatsConflictingSingleStrokeShortcut \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testConfiguredChordPrefixBlocksUnrelatedSingleStrokeShortcutOnSecondKey \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testConfiguredChordDoesNotCrossWindowBoundary \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testShortcutChangeClearsPendingConfiguredChord
```

Expected: all PASS.

- [ ] **Step 5: Commit the fix**

```bash
git add Sources/AppDelegate.swift
git commit -m "Allow bare-key chord prefixes through shortcut routing

The early-return guard in handleCustomShortcut bails on bare-key
events when no chord is armed, which prevents a tmux-style bare-key
leader (e.g. backtick) from ever arming. Narrow the guard to skip
only when no configured shortcut has a bare-key chord prefix.

Fixes the failing testBareKeyChordPrefixArmsAndSplitsOnSecondKey."
```

---

## Task 3: Failing test — bare-key chord mismatch must not consume second key

**Files:**
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift`

Decision Q1=a from the spec: on chord mismatch (second key has no binding), keep the existing behavior — consume only the prefix, let the second key pass through. Lock this in.

- [ ] **Step 1: Write the test**

Append to `AppDelegateShortcutRoutingTests`:

```swift
func testBareKeyChordMismatchDoesNotConsumeSecondKey() {
    guard let appDelegate = AppDelegate.shared else {
        XCTFail("Expected AppDelegate.shared")
        return
    }

    let windowId = appDelegate.createMainWindow()
    defer { closeWindow(withId: windowId) }

    guard let window = window(withId: windowId) else {
        XCTFail("Expected test window")
        return
    }

    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    // ` then d → splitRight, but the user will press ` then q (unbound second).
    let shortcut = StoredShortcut(
        key: "`",
        command: false,
        shift: false,
        option: false,
        control: false,
        chordKey: "d"
    )

    withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
        guard let prefixEvent = makeKeyDownEvent(
            key: "`",
            modifiers: [],
            keyCode: 50,
            windowNumber: window.windowNumber
        ),
        let mismatchedSecondEvent = makeKeyDownEvent(
            key: "q",
            modifiers: [],
            keyCode: 12,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct chord events")
            return
        }

#if DEBUG
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: prefixEvent),
            "Bare-key chord prefix should arm and consume the prefix event"
        )
        XCTAssertFalse(
            appDelegate.debugHandleCustomShortcut(event: mismatchedSecondEvent),
            "Mismatched second stroke after a bare-key chord prefix must NOT be consumed"
        )
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
}
```

- [ ] **Step 2: Run the test**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordMismatchDoesNotConsumeSecondKey
```

Expected: **PASS** without any further code change. (Mismatch behavior is unchanged from PR #2528 because we did not touch the chord-second-stroke matching loop.)

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/AppDelegateShortcutRoutingTests.swift
git commit -m "Lock in chord-mismatch passthrough for bare-key leaders"
```

---

## Task 4: Failing test — double-tap leader sends a literal to the focused terminal

**Files:**
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift`

We need a way to assert "the focused Ghostty surface received text X". Search for existing tests that do this; if none exist, the cleanest path is a debug seam.

- [ ] **Step 1: Decide on the test seam**

Search for an existing helper:

```bash
grep -n "sendText\|sentText\|textRecorded\|TextSentTo" cmuxTests/*.swift
```

Two outcomes:

- **Outcome A — a recorder helper exists.** Reuse it. Skip to Step 2.
- **Outcome B — no recorder.** Add the smallest possible test seam to `Sources/GhosttyTerminalView.swift`. In the `TerminalSurface` class (the type that owns `func sendText(_ text: String)` at line 5235), add a debug-only shim that records the most recent send so a test can read it back. Place this inside an existing `#if DEBUG` region in `TerminalSurface`:

  ```swift
  #if DEBUG
  /// Test-only: most recent text passed to `sendText`. Set in `sendText` before any
  /// I/O happens, so a unit test can assert "the literal leader was forwarded here"
  /// without running a real Ghostty surface.
  static var debugLastSendTextRecorder: ((String) -> Void)?
  #endif
  ```

  Then at the **top** of `func sendText(_ text: String)` (line 5235), add:

  ```swift
  #if DEBUG
  Self.debugLastSendTextRecorder?(text)
  #endif
  ```

  This is a minimal seam, gated to DEBUG, with no production effect.

- [ ] **Step 2: Write the test**

Append to `AppDelegateShortcutRoutingTests`. This version assumes Outcome B (the new debug recorder); adjust the recording mechanism if Outcome A is used.

```swift
func testBareKeyChordDoubleTapSendsLiteralToFocusedTerminal() {
    guard let appDelegate = AppDelegate.shared else {
        XCTFail("Expected AppDelegate.shared")
        return
    }

    let windowId = appDelegate.createMainWindow()
    defer { closeWindow(withId: windowId) }

    guard let window = window(withId: windowId) else {
        XCTFail("Expected test window")
        return
    }

    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    // Bind ` then d so a bare-key leader is configured.
    let shortcut = StoredShortcut(
        key: "`",
        command: false,
        shift: false,
        option: false,
        control: false,
        chordKey: "d"
    )

#if DEBUG
    var captured: [String] = []
    let previousRecorder = TerminalSurface.debugLastSendTextRecorder
    TerminalSurface.debugLastSendTextRecorder = { text in
        captured.append(text)
    }
    defer { TerminalSurface.debugLastSendTextRecorder = previousRecorder }
#endif

    withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
        guard let prefixEvent = makeKeyDownEvent(
            key: "`",
            modifiers: [],
            keyCode: 50,
            windowNumber: window.windowNumber
        ),
        let secondPrefixEvent = makeKeyDownEvent(
            key: "`",
            modifiers: [],
            keyCode: 50,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct backtick events")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: secondPrefixEvent),
            "Double-tap of a bare-key leader must be consumed and forwarded as a literal"
        )
        XCTAssertEqual(captured, ["`"], "Exactly one literal backtick should be sent to the focused surface")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordDoubleTapSendsLiteralToFocusedTerminal
```

Expected: **FAIL** — the second `` ` `` is not consumed (returns false) and `captured` is empty, because we have not implemented the double-tap-to-literal handler yet.

- [ ] **Step 4: Commit the failing test (and the test seam if added in Step 1)**

```bash
git add cmuxTests/AppDelegateShortcutRoutingTests.swift Sources/GhosttyTerminalView.swift
git commit -m "Add failing test for bare-key chord double-tap literal"
```

---

## Task 5: Implement implicit double-tap-to-literal

**Files:**
- Modify: `Sources/AppDelegate.swift` — add the helper near `focusedTerminalShortcutContext` (line 5279) and the dispatch at the tail of `handleCustomShortcut` (line 11190).

- [ ] **Step 1: Add the literal-send helper**

Insert this method into `extension AppDelegate` near `focusedTerminalShortcutContext` (around `Sources/AppDelegate.swift:5279`):

```swift
/// Sends the literal character of a bare-key chord prefix to the focused Ghostty
/// surface. Used by the implicit double-tap-leader behavior so a user with a
/// bare-key leader can still type the literal character by pressing it twice.
///
/// Returns `true` iff a focused terminal surface was found and `sendText` was
/// invoked. If no terminal is focused, returns `false` so the caller can decide
/// whether to consume the event.
private func sendLiteralChordPrefixToFocusedSurface(
    prefix: ShortcutStroke,
    event: NSEvent
) -> Bool {
    let preferredWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    let responder = preferredWindow?.firstResponder
        ?? NSApp.keyWindow?.firstResponder
        ?? NSApp.mainWindow?.firstResponder
    guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
          let surface = ghosttyView.terminalSurface else {
        return false
    }
    surface.sendText(prefix.key)
    return true
}
```

- [ ] **Step 2: Wire the implicit double-tap dispatch into `handleCustomShortcut`**

Edit the tail of `handleCustomShortcut` at `Sources/AppDelegate.swift:11190`. Replace:

```swift
        if matchConfiguredShortcut(event: event, action: .reopenClosedBrowserPanel) {
            _ = tabManager?.reopenMostRecentlyClosedBrowserPanel()
            return true
        }

        return false
    }
```

with:

```swift
        if matchConfiguredShortcut(event: event, action: .reopenClosedBrowserPanel) {
            _ = tabManager?.reopenMostRecentlyClosedBrowserPanel()
            return true
        }

        // Implicit `<leader><leader>` → send literal leader to focused terminal.
        // Only fires when the armed chord prefix has no modifiers and the second
        // event is the same bare key with no modifiers, AND no configured chord
        // binding above matched. This gives bare-key leader users a free
        // tmux-style send-prefix without any settings.json wiring; an explicit
        // user binding for `<prefix><prefix>` always wins because the configured
        // chord match loop above runs first.
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent,
           prefix.modifierFlags.isEmpty,
           normalizedFlags.isEmpty,
           matchShortcutStroke(event: event, stroke: prefix),
           sendLiteralChordPrefixToFocusedSurface(prefix: prefix, event: event) {
            return true
        }

        return false
    }
```

The `matchShortcutStroke(event:stroke:)` call at this site reuses the existing matcher, so dvorak/non-Latin layouts keep working — no special-casing.

- [ ] **Step 3: Run the double-tap test and verify it passes**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordDoubleTapSendsLiteralToFocusedTerminal
```

Expected: **PASS** — the second `` ` `` is consumed and one literal `` ` `` is forwarded to the focused surface.

- [ ] **Step 4: Run all tests touched by this plan**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordPrefixArmsAndSplitsOnSecondKey \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordMismatchDoesNotConsumeSecondKey \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordDoubleTapSendsLiteralToFocusedTerminal \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testChordedNewWorkspaceShortcutConsumesPrefixAndTriggersOnSecondKey \
  -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testChordedShortcutMismatchDoesNotConsumeSecondKey
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppDelegate.swift
git commit -m "Add implicit double-tap-leader → literal for bare-key chord prefixes

When a bare-key chord prefix is armed and the user presses the same
key again with no modifiers and no configured chord binding matched,
forward the prefix character to the focused Ghostty surface. This
matches tmux's default send-prefix behavior, requires no
configuration, and lets users with a bare-key leader still type the
literal character by double-tapping."
```

---

## Task 6: Failing test — explicit `<prefix><prefix>` binding wins over implicit literal

**Files:**
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift`

- [ ] **Step 1: Write the test**

Append to `AppDelegateShortcutRoutingTests`:

```swift
func testBareKeyChordDoubleTapWithExplicitBindingFiresActionInsteadOfLiteral() {
    guard let appDelegate = AppDelegate.shared else {
        XCTFail("Expected AppDelegate.shared")
        return
    }

    let windowId = appDelegate.createMainWindow()
    defer { closeWindow(withId: windowId) }

    guard let window = window(withId: windowId),
          let manager = appDelegate.tabManagerFor(windowId: windowId) else {
        XCTFail("Expected test window and manager")
        return
    }

    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    // Bind splitRight to ` then `. (explicit double-tap binding)
    let shortcut = StoredShortcut(
        key: "`",
        command: false,
        shift: false,
        option: false,
        control: false,
        chordKey: "`"
    )

#if DEBUG
    var captured: [String] = []
    let previousRecorder = TerminalSurface.debugLastSendTextRecorder
    TerminalSurface.debugLastSendTextRecorder = { text in captured.append(text) }
    defer { TerminalSurface.debugLastSendTextRecorder = previousRecorder }
#endif

    let initialCount = manager.tabs.count

    withTemporaryShortcut(action: .splitRight, shortcut: shortcut) {
        guard let prefixEvent = makeKeyDownEvent(
            key: "`",
            modifiers: [],
            keyCode: 50,
            windowNumber: window.windowNumber
        ),
        let secondEvent = makeKeyDownEvent(
            key: "`",
            modifiers: [],
            keyCode: 50,
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct backtick events")
            return
        }

#if DEBUG
        XCTAssertTrue(appDelegate.debugHandleCustomShortcut(event: prefixEvent))
        XCTAssertTrue(
            appDelegate.debugHandleCustomShortcut(event: secondEvent),
            "Configured `+` chord must dispatch the action"
        )
        XCTAssertEqual(captured, [], "Explicit binding must suppress the implicit literal-send")
#else
        XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
    }
    _ = initialCount  // implicit asserts above are sufficient; no tab-count check here because splitRight depends on a focused terminal which the test window may not have.
}
```

- [ ] **Step 2: Run the test**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testBareKeyChordDoubleTapWithExplicitBindingFiresActionInsteadOfLiteral
```

Expected: **PASS** without any further change. The configured chord match loop runs before the implicit-literal handler, so an explicit binding wins. If this fails, the implicit-literal handler in Task 5 is positioned incorrectly; move it strictly after the last `matchConfiguredShortcut(...)` call.

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/AppDelegateShortcutRoutingTests.swift
git commit -m "Lock in explicit double-tap binding precedence over implicit literal"
```

---

## Task 7: Settings file decoding test for bare-key chord shortcuts

**Files:**
- Test: `cmuxTests/AppDelegateShortcutRoutingTests.swift` (or wherever `testSettingsFileChordDispatchesNewWorkspaceShortcut` lives — `cmuxTests/AppDelegateShortcutRoutingTests.swift:218`).

- [ ] **Step 1: Write the test**

Model after `testSettingsFileChordDispatchesNewWorkspaceShortcut`. Append:

```swift
func testSettingsFileBareKeyChordDispatchesSplitRight() throws {
    guard let appDelegate = AppDelegate.shared else {
        XCTFail("Expected AppDelegate.shared")
        return
    }

    let windowId = appDelegate.createMainWindow()
    defer { closeWindow(withId: windowId) }

    guard let window = window(withId: windowId) else {
        XCTFail("Expected test window")
        return
    }

    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let settingsFileURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
    try """
    {
      "shortcuts": {
        "splitRight": ["`", "d"]
      }
    }
    """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

    // Reuse whatever existing helper the matching test uses to point the file
    // store at this URL (e.g. KeyboardShortcutSettingsFileStore.shared.reload(...)
    // or a test seam). Mirror the body of testSettingsFileChordDispatchesNewWorkspaceShortcut
    // exactly here for the file-store wiring; the only differences are the action
    // (.splitRight) and the bare-key first stroke.

    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

    guard let prefixEvent = makeKeyDownEvent(
        key: "`",
        modifiers: [],
        keyCode: 50,
        windowNumber: window.windowNumber
    ),
    let actionEvent = makeKeyDownEvent(
        key: "d",
        modifiers: [],
        keyCode: 2,
        windowNumber: window.windowNumber
    ) else {
        XCTFail("Failed to construct chord events")
        return
    }

#if DEBUG
    XCTAssertTrue(
        appDelegate.debugHandleCustomShortcut(event: prefixEvent),
        "Bare-key chord prefix configured via settings.json must arm"
    )
    XCTAssertTrue(
        appDelegate.debugHandleCustomShortcut(event: actionEvent),
        "Second stroke must dispatch the splitRight action"
    )
#else
    XCTFail("debugHandleCustomShortcut is only available in DEBUG")
#endif
}
```

The "Mirror the body of testSettingsFileChordDispatchesNewWorkspaceShortcut" comment is **not a placeholder for the engineer to skip** — re-read that test (`AppDelegateShortcutRoutingTests.swift:218`) and copy its file-store wiring verbatim, swapping the action id and the chord strokes. The wiring is several lines long and changes if the test infrastructure evolves; copying the live source is more reliable than embedding a snapshot here that can drift.

- [ ] **Step 2: Run**

```bash
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-bare-key-chord \
  test -only-testing:cmuxTests/AppDelegateShortcutRoutingTests/testSettingsFileBareKeyChordDispatchesSplitRight
```

Expected: **PASS**. (The parser already accepts bare-key strokes; the runtime now arms them; both fixed in Task 2.)

- [ ] **Step 3: Commit**

```bash
git add cmuxTests/AppDelegateShortcutRoutingTests.swift
git commit -m "Test bare-key chord configured via settings.json"
```

---

## Task 8: Documentation updates

**Files:**
- Modify: `web/app/[locale]/docs/keyboard-shortcuts/page.tsx`
- Modify: `web/app/[locale]/docs/configuration/page.tsx` (the page that documents `settings.json` — pick the one with the existing chord example, e.g. `["ctrl+b", "c"]`).

- [ ] **Step 1: Locate the existing chord docs**

```bash
grep -n 'ctrl+b\|chord\|tmux' web/app/\[locale\]/docs/configuration/page.tsx web/app/\[locale\]/docs/keyboard-shortcuts/page.tsx
```

Add a short subsection wherever chord syntax is currently documented. Concrete copy:

> **Bare-key leaders.** A chord's first stroke can be a key without modifiers — e.g. `["` `","d"]` binds `` ` `` then `d`. While a bare-key leader is armed, the leader key is consumed instead of being typed into the focused terminal. Press the leader key twice in a row (with no other binding for `<leader><leader>`) to send a literal copy of it to the focused terminal — the same trick tmux uses by default. Bind a different action to `<leader><leader>` if you'd rather override that.

The same wording should be added to both pages if both currently document chord syntax. If only one does, only update that one.

- [ ] **Step 2: Verify pages render locally**

```bash
cd web
bun dev
```

Open the relevant docs page in a browser and confirm the new subsection renders. (Per project policy, do NOT run e2e tests locally.)

- [ ] **Step 3: Commit**

```bash
git add web/app/\[locale\]/docs/keyboard-shortcuts/page.tsx web/app/\[locale\]/docs/configuration/page.tsx
git commit -m "Document bare-key chord leaders and double-tap-to-literal"
```

---

## Task 9: Smoke test in a tagged Debug build

**Files:**
- None (manual verification step).

- [ ] **Step 1: Build a tagged Debug app**

```bash
./scripts/reload.sh --tag bare-key-chord-leaders
```

This prints an `App path:` line.

- [ ] **Step 2: Configure a bare-key leader in the tagged settings file**

The script also writes the tagged Debug socket. Edit `~/.config/cmux/settings.json` (or the tagged equivalent if the script uses a different path — read the `reload.sh` output) and add:

```jsonc
{
  "shortcuts": {
    "splitRight": ["`", "d"],
    "splitDown":  ["`", "-"],
    "focusLeft":  ["`", "h"],
    "focusRight": ["`", "l"],
    "focusUp":    ["`", "k"],
    "focusDown":  ["`", "j"],
    "toggleSplitZoom": ["`", "z"]
  }
}
```

- [ ] **Step 3: Open the tagged app via the cmd-clickable link**

Construct the `file://` URL from the `App path:` line per the project's reload-output convention and click it. In the running app:

- Press `` ` `` then `d` → terminal should split right.
- Press `` ` `` then `j` / `k` / `h` / `l` → focus moves between panes.
- Press `` ` `` then `z` → focused pane zooms.
- Press `` ` `` `` ` `` → a single literal `` ` `` should appear in the focused terminal's shell prompt.
- Press `` ` `` then `q` (no binding) → no `` ` `` appears, only `q` is typed (current chord-mismatch behavior, preserved).

If anything misbehaves, capture the output of `tail -100 "$(cat /tmp/cmux-last-debug-log-path)"` and address before merging.

---

## Task 10: Open the PR

- [ ] **Step 1: Push and open**

```bash
git push -u origin bare-key-chord-leaders
gh pr create --title "Support bare-key chord leaders (tmux-style backtick)" --body "$(cat <<'EOF'
## Summary
- Allow bare-key (no-modifier) chord prefixes configured via settings.json — unblocks tmux-style leaders like \`\`.
- Implicit double-tap-leader → forward literal to the focused terminal, so users can still type the leader character. An explicit binding for \`<leader><leader>\` overrides this.
- No recorder UI changes (chords are settings.json-only, per #2528).

## Test plan
- [x] cmuxTests/AppDelegateShortcutRoutingTests bare-key chord arming, mismatch passthrough, double-tap literal, explicit-binding precedence, settings.json decode
- [x] Existing chord regression suite (testChordedNewWorkspaceShortcutConsumesPrefixAndTriggersOnSecondKey, testChordedShortcutMismatchDoesNotConsumeSecondKey, etc.)
- [x] Manual smoke in a tagged Debug build with \`{"shortcuts":{"splitRight":["\`","d"], …}}\`

## Notes
Spec: docs/superpowers/specs/2026-04-29-bare-key-chord-leader-design.md
Plan: docs/superpowers/plans/2026-04-29-bare-key-chord-leader.md
EOF
)"
```

The PR commit history will show the failing-test → fix → green pattern required by the project's regression-test commit policy.

---

## Out of scope (follow-ups)

- **Pane resize actions** (`resizeLeft/Right/Up/Down`). Add as a separate spec/plan; the user explicitly deferred them.
- **Bare-key chord recording in the in-app recorder UI.** Today chords are settings-file-only; if we ever want to record them in the UI, we'd need a "record chord" affordance and a way to opt the first stroke out of `bareKeyNotAllowed`. Not blocking.
- **Send-leader-prefix as an explicit bindable action.** The implicit double-tap covers the user's stated need. If someone later wants e.g. `<leader>;` to send `` ` ``, add a `sendLeaderLiteral` action at that point.
