# Non-Native Fullscreen: Investigation Report

**Date:** 2026-04-04  
**Branch:** `fix/background-opacity-fullscreen-restore`  
**Goal:** Match Ghostty's `⌃⌘F` non-native fullscreen behavior in cmux — full display coverage, auto-hiding menu bar and Dock, and clean toggle (enter/exit on repeated keypresses).

---

## Background

cmux uses Ghostty's terminal engine. Ghostty supports `macos-non-native-fullscreen = true` in its config, which enables a fullscreen mode that doesn't switch macOS Spaces, preserving window transparency (`background-opacity`). The original cmux port had a stub implementation that only saved/restored the window frame, leaving the menu bar and Dock visible and breaking ⌃⌘F entirely.

---

## Attempt 1: `savedFrame`-only approach

**Commit:** `ba3cd77a` — feat: add non-native fullscreen to preserve background-opacity transparency

### What was done

Introduced `NonNativeFullscreen.swift` with a simple state machine:

```swift
private var savedFrame: NSRect?
private(set) var isFullScreen: Bool = false

func enter() {
    savedFrame = window.frame
    isFullScreen = true
    window.setFrame(fullscreenFrame(for: screen), display: true, animate: true)
}

func exit() {
    window.setFrame(saved, display: true, animate: true)
    isFullScreen = false
    savedFrame = nil
}
```

`fullscreenFrame` returned `screen.visibleFrame` — the area that excludes the menu bar and Dock.

### Result

The window expanded to fill only the **visible** area. The menu bar and Dock remained visible at all times. Not matching Ghostty's behavior.

---

## Attempt 2: Frame-only simplification

**Commit:** `7c8fb87a` — fix: simplify non-native fullscreen to frame-only approach

### What was done

Cleaned up the implementation but still used `screen.visibleFrame`. No presentation options (`NSApp.presentationOptions`) were set. The menu bar and Dock still showed.

### Result

Same visual outcome. The fundamental problem wasn't the code structure — it was using the wrong frame source.

---

## Root Cause 1: Native fullscreen intercepting ⌃⌘F

### Discovery

When ⌃⌘F was pressed, macOS native fullscreen activated instead of the custom implementation. Added logging and traced the event path.

In `Sources/AppDelegate.swift` at line 9676, there is a **hardcoded** event interceptor predating the keyboard shortcut system:

```swift
if shouldToggleMainWindowFullScreenForCommandControlFShortcut(
    flags: event.modifierFlags,
    chars: chars,
    keyCode: event.keyCode
) {
    guard let targetWindow = mainWindowForShortcutEvent(event) else {
        return false
    }
    targetWindow.toggleFullScreen(nil)  // ← ALWAYS calls native fullscreen
    return true                          // ← returns before custom handler
}
```

The **custom shortcut handler** for `.toggleFullScreen` was at line 9774 — never reached because the hardcoded check above returned `true` first.

Additionally, `disableNativeFullScreenShortcut()` (which removes the ⌃⌘F key equivalent from the macOS "Enter Full Screen" menu item) was ineffective because SwiftUI rebuilds the menu after `applicationDidFinishLaunching`, overwriting the disabled state.

### Fix

Modified the hardcoded handler to delegate to the non-native path when configured:

```swift
let config = GhosttyConfig.load()
if let style = config.macosNonNativeFullscreen.fullscreenStyle {
    nonNativeFullscreen(for: targetWindow, style: style).toggle()
    NotificationCenter.default.post(name: .toggleNonNativeFullScreen, object: targetWindow)
} else {
    targetWindow.toggleFullScreen(nil)
}
```

---

## Root Cause 2: SwiftUI `@State` reset kills the controller

### Discovery

After fixing Root Cause 1, entering fullscreen worked. But pressing ⌃⌘F a second time did nothing (entered fullscreen again instead of exiting).

The `NonNativeFullscreen` controller was stored as:

```swift
@State private var nonNativeFullscreen: NonNativeFullscreen?
```

in `ContentView.swift`. When `enter()` ran, it called:

```swift
window.styleMask.remove(.titled)
window.styleMask.remove(.resizable)
```

This change to the window's `styleMask` triggered SwiftUI to **rebuild the view hierarchy**, which **reset all `@State` variables back to their initial values** — including `nonNativeFullscreen = nil`.

On the second ⌃⌘F press, the notification handler found `nonNativeFullscreen == nil`, created a fresh controller (with no `savedState`), and called `toggle()` → `enter()` again instead of `exit()`.

### Fix

Moved controller ownership out of SwiftUI entirely into `AppDelegate`, using a dictionary keyed by `ObjectIdentifier(window)`:

```swift
private var nonNativeFullscreens: [ObjectIdentifier: NonNativeFullscreen] = [:]

func nonNativeFullscreen(for window: NSWindow, style: NonNativeFullscreen.Style) -> NonNativeFullscreen {
    let key = ObjectIdentifier(window)
    if let existing = nonNativeFullscreens[key] { return existing }
    let controller = NonNativeFullscreen(window: window, style: style)
    nonNativeFullscreens[key] = controller
    // Clean up on window close
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, ...) { ... }
    return controller
}
```

`AppDelegate` is a long-lived `NSObject` — immune to SwiftUI rebuilds. The controller persists for the lifetime of the window.

---

## Final Architecture

```
⌃⌘F keypress
  └─ AppDelegate event monitor (line 9676)
       ├─ GhosttyConfig.load().macosNonNativeFullscreen.fullscreenStyle != nil?
       │    YES → AppDelegate.nonNativeFullscreen(for: window, style:).toggle()
       │           └─ enter(): save SavedState, set presentationOptions, remove styleMask, set screen.frame
       │           └─ exit(): restore presentationOptions, styleMask, frame, toolbar, titlebar accessories
       │         NotificationCenter.post(.toggleNonNativeFullScreen, object: window)
       │           └─ ContentView.onReceive → sync isFullScreen, titlebar, transparency
       └─ NO → window.toggleFullScreen(nil)  (native)
```

### Key design decisions

| Decision | Reason |
|----------|--------|
| `screen.frame` not `screen.visibleFrame` | Must cover menu bar and Dock physically; presentationOptions handles auto-hide |
| `NSApp.presentationOptions.insert(.autoHideDock/.autoHideMenuBar)` | Makes them slide in on hover, matching Ghostty |
| Controller in AppDelegate dict, not `@State` | SwiftUI resets `@State` on `styleMask` change; AppDelegate is stable |
| Notification for UI sync, not direct call | ContentView can't be called directly from AppDelegate; decouples toggle from UI update |
| `SavedState` struct stores full window state | `styleMask`, `toolbar`, `titlebarAccessoryViewControllers` must be restored or window looks broken after exit |

---

## What Was NOT Changed

- `scripts/setup.sh` has an unrelated `-Dversion-string` change from earlier in the session (staged separately, not part of this feature).
- No changes to Ghostty submodule.
- No localization strings added (label keys are declared with `defaultValue:` fallbacks).

---

## Testing

```bash
# Build and launch
./scripts/reload.sh --tag first-run --launch

# Verify
# 1. ⌃⌘F → full display coverage (no menu bar gap, no Dock gap)
# 2. Hover top → menu bar appears
# 3. Hover bottom → Dock appears
# 4. ⌃⌘F again → window returns to original frame/style
# 5. background-opacity in ghostty config → transparency persists in fullscreen
```
