# Sidebar Folder Drag-and-Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dragging a Finder folder onto the Cmux sidebar opens it as a new workspace tab whose terminal working directory is that folder.

**Architecture:** The window-level `FileDropOverlayView` already captures every Finder file-URL drag across the whole window (a sidebar-embedded drop view would never receive the drag). So the feature extends that overlay: a sidebar hit-region registry (mirroring the existing `MinimalModeTitlebarControlHitRegionRegistry`) tells the overlay when a drop point is over the sidebar; a pure directory filter enforces folders-only; and on a folder drop the overlay calls the existing `TabManager.addWorkspace(workingDirectory:)` (the same call the command-palette "Open Folder" uses) once per folder.

**Tech Stack:** Swift, AppKit, SwiftUI, Swift Testing. Build via Xcode 26 + `./scripts/reload.sh`. Terminal rendering via libghostty (GhosttyKit.xcframework, built with Zig).

## Global Constraints

- Repo: `/Users/wasimjalali/Desktop/cmux-fork`, branch `feat/sidebar-folder-drop`.
- Never commit to `main`. Conventional commits (`feat:`/`test:`/`docs:`). Co-author trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Folders only. A file dropped over the sidebar is rejected and does nothing (it must NOT fall through to terminal path-insertion).
- Each dropped folder opens one workspace tab. The window overlay owns file-URL drops; do not add a sidebar-embedded file-URL drop view (it would be dead code).
- Canonical new-workspace call: `TabManager.addWorkspace(workingDirectory: <absolute path>)` — `@MainActor`, returns `Workspace`.
- File-URL reading: `PasteboardFileURLReader.fileURLs(from: sender.draggingPasteboard) -> [URL]`.
- Do not touch the sidebar's existing internal reorder/tab drags (different pasteboard types).
- Voice for any user-facing string: no em dashes, contractions, short sentences.
- Tests run under Xcode: `xcodebuild -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/<Suite> test`. The pure-logic suites do not need the app running.

---

### Task 1: Establish a green baseline build

Confirm the untouched fork builds and launches before writing any feature code. No baseline, no way to tell a feature bug from a setup bug.

**Files:** none (environment only).

- [ ] **Step 1: Accept the Xcode license and first-launch (needs the user's password)**

Wasim runs these (sudo prompts for password; not automatable here):
```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```
Expected: no error. `xcodebuild -checkFirstLaunchStatus; echo $?` prints `0`.

- [ ] **Step 2: Install Zig**

```bash
brew install zig && zig version
```
Expected: a version prints (Homebrew now works because the license is accepted).

- [ ] **Step 3: Initialize submodules**

```bash
cd ~/Desktop/cmux-fork && git submodule update --init --recursive
```
Expected: `ghostty`, `homebrew-cmux`, `vendor/bonsplit` populated.

- [ ] **Step 4: Run setup (builds GhosttyKit.xcframework via Zig)**

```bash
cd ~/Desktop/cmux-fork && ./scripts/setup.sh
```
Expected: completes without error; `GhosttyKit.xcframework` produced. If Zig complains about a version mismatch, check `ghostty`'s required Zig and install that exact version instead (`brew install zig@<version>` or via `mise`); note the resolved version in `progress.md`.

- [ ] **Step 5: Build and launch the Debug app**

```bash
cd ~/Desktop/cmux-fork && ./scripts/reload.sh --tag dragdrop --launch
```
Expected: prints a `.app` path and launches `cmux DEV.app`. It opens a terminal window with a sidebar. This is the baseline.

- [ ] **Step 6: Commit nothing (baseline is environment state)**

No commit. Record in `progress.md` that the baseline build succeeded and the resolved Zig version.

---

### Task 2: `DirectoryDropFilter` (pure, folders-only rule)

**Files:**
- Create: `Sources/DirectoryDropFilter.swift`
- Test: `cmuxTests/DirectoryDropFilterTests.swift`

**Interfaces:**
- Produces: `enum DirectoryDropFilter` with
  `static func directories(among urls: [URL], isDirectory: (URL) -> Bool = DirectoryDropFilter.fileSystemIsDirectory) -> [URL]`
  and `static func fileSystemIsDirectory(_ url: URL) -> Bool`.

- [ ] **Step 1: Write the failing test**

`cmuxTests/DirectoryDropFilterTests.swift`:
```swift
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("DirectoryDropFilter")
struct DirectoryDropFilterTests {
    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    @Test func keepsOnlyDirectories() {
        let urls = [url("/a"), url("/b/file.txt"), url("/c")]
        let dirs: Set<String> = ["/a", "/c"]
        let result = DirectoryDropFilter.directories(among: urls) { dirs.contains($0.path) }
        #expect(result.map(\.path) == ["/a", "/c"])
    }

    @Test func emptyWhenNoDirectories() {
        let urls = [url("/x/file.txt"), url("/y/img.png")]
        let result = DirectoryDropFilter.directories(among: urls) { _ in false }
        #expect(result.isEmpty)
    }

    @Test func dedupesByPathPreservingOrder() {
        let urls = [url("/a"), url("/a"), url("/b")]
        let result = DirectoryDropFilter.directories(among: urls) { _ in true }
        #expect(result.map(\.path) == ["/a", "/b"])
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd ~/Desktop/cmux-fork && xcodebuild -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/DirectoryDropFilter test 2>&1 | tail -20
```
Expected: FAIL to compile ("cannot find 'DirectoryDropFilter' in scope").

- [ ] **Step 3: Write the implementation**

`Sources/DirectoryDropFilter.swift`:
```swift
import Foundation

/// Filters dragged URLs down to existing directories. Pure and injectable so the
/// folders-only rule is unit-testable with no filesystem access.
enum DirectoryDropFilter {
    static func directories(
        among urls: [URL],
        isDirectory: (URL) -> Bool = DirectoryDropFilter.fileSystemIsDirectory
    ) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let path = url.path
            if seen.contains(path) { continue }
            if !isDirectory(url) { continue }
            seen.insert(path)
            result.append(url)
        }
        return result
    }

    static func fileSystemIsDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd ~/Desktop/cmux-fork && xcodebuild -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/DirectoryDropFilter test 2>&1 | tail -20
```
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/cmux-fork
git add Sources/DirectoryDropFilter.swift cmuxTests/DirectoryDropFilterTests.swift
git commit -m "feat: add DirectoryDropFilter for folders-only drop rule

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `SidebarDropRegionRegistry` (window-coordinate region lookup)

**Files:**
- Create: `Sources/SidebarDropRegionRegistry.swift`
- Test: `cmuxTests/SidebarDropRegionRegistryTests.swift`

**Interfaces:**
- Produces: `@MainActor enum SidebarDropRegionRegistry` with
  `static func register(_ view: NSView)`, `static func unregister(_ view: NSView)`,
  `static func containsWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> Bool`.
- Pattern reference: `Sources/WindowDragHandleView.swift:443` (`MinimalModeTitlebarControlHitRegionRegistry`).

- [ ] **Step 1: Write the failing test**

`cmuxTests/SidebarDropRegionRegistryTests.swift`:
```swift
import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("SidebarDropRegionRegistry")
struct SidebarDropRegionRegistryTests {
    @Test func detectsPointInsideRegisteredProbe() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        window.contentView?.addSubview(probe)
        SidebarDropRegionRegistry.register(probe)
        defer { SidebarDropRegionRegistry.unregister(probe) }

        let inside = probe.convert(NSPoint(x: 50, y: 150), to: nil)
        let outside = probe.convert(NSPoint(x: 300, y: 150), to: nil)
        #expect(SidebarDropRegionRegistry.containsWindowPoint(inside, in: window))
        #expect(!SidebarDropRegionRegistry.containsWindowPoint(outside, in: window))
    }

    @Test func unregisteredProbeIsNotDetected() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        window.contentView?.addSubview(probe)
        let inside = probe.convert(NSPoint(x: 50, y: 150), to: nil)
        #expect(!SidebarDropRegionRegistry.containsWindowPoint(inside, in: window))
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd ~/Desktop/cmux-fork && xcodebuild -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/SidebarDropRegionRegistry test 2>&1 | tail -20
```
Expected: FAIL to compile ("cannot find 'SidebarDropRegionRegistry'").

- [ ] **Step 3: Write the implementation**

`Sources/SidebarDropRegionRegistry.swift`:
```swift
import AppKit

/// Tracks the sidebar's on-screen region in window coordinates so the window-level
/// file-drop overlay can tell when a Finder drop point is over the sidebar. Mirrors
/// MinimalModeTitlebarControlHitRegionRegistry (WindowDragHandleView.swift).
@MainActor
enum SidebarDropRegionRegistry {
    private final class WeakBox {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var probes: [ObjectIdentifier: WeakBox] = [:]

    static func register(_ view: NSView) {
        probes[ObjectIdentifier(view)] = WeakBox(view)
    }

    static func unregister(_ view: NSView) {
        probes.removeValue(forKey: ObjectIdentifier(view))
    }

    static func containsWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        for (_, box) in probes {
            guard let view = box.view,
                  view.window === window,
                  !view.isHidden,
                  view.alphaValue > 0 else { continue }
            let frameInWindow = view.convert(view.bounds, to: nil)
            if frameInWindow.contains(windowPoint) { return true }
        }
        return false
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

```bash
cd ~/Desktop/cmux-fork && xcodebuild -scheme cmux -destination 'platform=macOS' -only-testing:cmuxTests/SidebarDropRegionRegistry test 2>&1 | tail -20
```
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/cmux-fork
git add Sources/SidebarDropRegionRegistry.swift cmuxTests/SidebarDropRegionRegistryTests.swift
git commit -m "feat: add SidebarDropRegionRegistry for sidebar hit region

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `SidebarDropRegionProbe` and mount it in the sidebar

**Files:**
- Create: `Sources/SidebarDropRegionProbe.swift`
- Modify: `Sources/ContentView.swift` (the sidebar container carrying `.frame(width: sidebarWidth)`, around line 1658; confirm by reading `sidebarView`/`sidebarPanelContainer`, lines 1641-1660 and 1832-1849)

**Interfaces:**
- Consumes: `SidebarDropRegionRegistry.register/unregister` (Task 3).
- Produces: `struct SidebarDropRegionProbe: NSViewRepresentable`.

- [ ] **Step 1: Write the probe**

`Sources/SidebarDropRegionProbe.swift`:
```swift
import AppKit
import SwiftUI

/// A transparent, non-interactive NSView that spans the sidebar and registers itself
/// with SidebarDropRegionRegistry while it is in a window. Mounted as a background of
/// the sidebar container, so its frame is the sidebar region and tracks width,
/// visibility and resize automatically.
struct SidebarDropRegionProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                SidebarDropRegionRegistry.register(self)
            } else {
                SidebarDropRegionRegistry.unregister(self)
            }
        }

        // Never intercept clicks or drags; this view exists only to report its frame.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
```

- [ ] **Step 2: Mount the probe on the sidebar container**

In `Sources/ContentView.swift`, find the sidebar view that carries `.frame(width: sidebarWidth)` (around line 1658). Add a `.background` with the probe so it matches the sidebar's bounds:
```swift
.frame(width: sidebarWidth)
.background(SidebarDropRegionProbe())
```
Read the surrounding modifiers first and place `.background(SidebarDropRegionProbe())` immediately after the `.frame(width: sidebarWidth)` on that same view. Do not add it to the content pane.

- [ ] **Step 3: Build to confirm it compiles and registers**

```bash
cd ~/Desktop/cmux-fork && ./scripts/reload.sh --tag dragdrop --launch
```
Expected: builds, `cmux DEV.app` launches with the sidebar visible. (Registration is exercised for real in Task 5; this step only confirms the mount compiles and runs.)

- [ ] **Step 4: Commit**

```bash
cd ~/Desktop/cmux-fork
git add Sources/SidebarDropRegionProbe.swift Sources/ContentView.swift
git commit -m "feat: mount sidebar drop-region probe in the sidebar

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Wire folder-drop into `FileDropOverlayView`

**Files:**
- Modify: `Sources/FileDropOverlayView.swift` (declare closure near line 44; add classifier; wire `performDragOperation` ~348-446, `prepareForDragOperation` ~286-346)
- Modify: `Sources/FileDropOverlayViewHitTesting.swift` (`updateDragTarget` ~line 7)
- Modify: `Sources/ContentView.swift` (`configureFileDropOverlay` ~664-671)

**Interfaces:**
- Consumes: `SidebarDropRegionRegistry.containsWindowPoint` (Task 3), `DirectoryDropFilter.directories` (Task 2), `PasteboardFileURLReader.fileURLs(from:)`, `TabManager.addWorkspace(workingDirectory:)`.
- Produces: `FileDropOverlayView.onFoldersDroppedOnSidebar: (([URL]) -> Bool)?` and `FileDropOverlayView.classifySidebarFolderDrop(_:) -> SidebarFolderDropClassification`.

This task is verified manually (drag-and-drop can't be unit-tested here). Read each target function before editing so the insertion points are exact.

- [ ] **Step 1: Declare the classification type and the callback**

In `Sources/FileDropOverlayView.swift`, near the other `onDrop` declaration (line ~44), add:
```swift
var onFoldersDroppedOnSidebar: (([URL]) -> Bool)?
```
At file scope (top level of the same file, outside the class), add:
```swift
enum SidebarFolderDropClassification {
    case openFolders([URL])
    case rejectOverSidebar
    case notSidebar
}
```

- [ ] **Step 2: Add the classifier helper**

In `Sources/FileDropOverlayView.swift`, add a method to `FileDropOverlayView`:
```swift
func classifySidebarFolderDrop(_ sender: any NSDraggingInfo) -> SidebarFolderDropClassification {
    guard let window,
          SidebarDropRegionRegistry.containsWindowPoint(sender.draggingLocation, in: window)
    else { return .notSidebar }

    let urls = PasteboardFileURLReader.fileURLs(from: sender.draggingPasteboard)
    let directories = DirectoryDropFilter.directories(among: urls)
    return directories.isEmpty ? .rejectOverSidebar : .openFolders(directories)
}
```

- [ ] **Step 3: Wire the drop delivery (`performDragOperation`)**

In `Sources/FileDropOverlayView.swift`, inside `performDragOperation` (starts ~line 348), immediately after `shouldCapture` is computed (~line 354) and BEFORE `if shouldRouteFileDropToTextDestination(sender) {` (~line 355), insert:
```swift
switch classifySidebarFolderDrop(sender) {
case .openFolders(let directories):
    return onFoldersDroppedOnSidebar?(directories) ?? false
case .rejectOverSidebar:
    return true
case .notSidebar:
    break
}
```

- [ ] **Step 4: Wire the accept affordance (`updateDragTarget`)**

In `Sources/FileDropOverlayViewHitTesting.swift`, at the very top of `updateDragTarget` (~line 7, before its `shouldCapture` computation), insert:
```swift
switch classifySidebarFolderDrop(sender) {
case .openFolders:
    return .copy
case .rejectOverSidebar:
    return []
case .notSidebar:
    break
}
```
(`draggingEntered`/`draggingUpdated` route through `updateDragTarget`. Confirm by reading; if either overrides directly without calling `updateDragTarget`, add the same switch at the top of that override. Returning `.copy` here is mandatory or AppKit never delivers the drop.)

- [ ] **Step 5: Wire `prepareForDragOperation`**

In `Sources/FileDropOverlayView.swift`, at the top of `prepareForDragOperation` (~line 286), after its `shouldCapture` is computed and before the existing branches, insert:
```swift
switch classifySidebarFolderDrop(sender) {
case .openFolders:
    return true
case .rejectOverSidebar:
    return false
case .notSidebar:
    break
}
```

- [ ] **Step 6: Set the callback in `configureFileDropOverlay`**

In `Sources/ContentView.swift`, inside `configureFileDropOverlay(_:tabManager:)` (~line 664), alongside the existing `overlay.onDrop = ...`, add:
```swift
overlay.onFoldersDroppedOnSidebar = { [weak tabManager] directories in
    MainActor.assumeIsolated {
        guard let tabManager, !directories.isEmpty else { return false }
        for directory in directories {
            tabManager.addWorkspace(workingDirectory: directory.path)
        }
        return true
    }
}
```

- [ ] **Step 7: Build and launch**

```bash
cd ~/Desktop/cmux-fork && ./scripts/reload.sh --tag dragdrop --launch
```
Expected: builds and launches `cmux DEV.app`.

- [ ] **Step 8: Manual verification (the real test)**

In `cmux DEV.app`:
1. Drag a folder from Finder over the sidebar. Expected: copy (green +) cursor appears over the sidebar.
2. Drop it. Expected: a new workspace tab appears and its terminal is in that folder. Confirm with `pwd` in the new tab.
3. Drag a single file (not a folder) over the sidebar. Expected: no-drop cursor, and dropping does nothing (crucially, the path is NOT pasted into any terminal).
4. Drag a folder over the terminal pane (not the sidebar). Expected: unchanged old behavior (path inserted as text).
5. Select two folders in Finder and drop both on the sidebar. Expected: two new tabs, one per folder.

Record the results in `progress.md`.

- [ ] **Step 9: Commit**

```bash
cd ~/Desktop/cmux-fork
git add Sources/FileDropOverlayView.swift Sources/FileDropOverlayViewHitTesting.swift Sources/ContentView.swift
git commit -m "feat: open dropped folder as new workspace from the sidebar

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Full test run, docs, and PR

**Files:**
- Modify: `progress.md` (or create if absent), `README` note if the fork tracks features.

- [ ] **Step 1: Run the full added test suites**

```bash
cd ~/Desktop/cmux-fork && xcodebuild -scheme cmux -destination 'platform=macOS' \
  -only-testing:cmuxTests/DirectoryDropFilter \
  -only-testing:cmuxTests/SidebarDropRegionRegistry test 2>&1 | tail -20
```
Expected: all PASS.

- [ ] **Step 2: Update docs**

Note the feature and how to use it in `progress.md`. Keep the spec (`docs/superpowers/specs/2026-07-11-sidebar-folder-drop-design.md`) in sync if any implementation detail drifted.

- [ ] **Step 3: Push and open the PR against the fork's own main**

```bash
cd ~/Desktop/cmux-fork
git push -u origin feat/sidebar-folder-drop
gh pr create --repo wasimjalali/cmux --base main --head feat/sidebar-folder-drop \
  --title "feat: drag a folder onto the sidebar to open it as a workspace" \
  --body "Drop a Finder folder on the sidebar to open a new workspace tab cd'd into it. Folders only; files over the sidebar are rejected. Implemented in FileDropOverlayView with a sidebar hit-region registry. See docs/superpowers/specs/2026-07-11-sidebar-folder-drop-design.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 4: Let CodeRabbit review, resolve findings, then merge**

Wait for the review to be green and every finding resolved before merging to the fork's `main`.

---

## Self-Review

**Spec coverage:** drop→new tab at folder (Task 5 Step 6), sidebar-only zone (Task 3/4 region + Task 5 classifier), folders-only + reject files (Task 2 + `.rejectOverSidebar`), multiple folders (Task 5 Step 6 loop, verified Step 8.5), no internal-drag interference (only file-URL payloads over the sidebar are claimed; reorder drags use other pasteboard types and are untouched), build/install (Task 1). All covered.

**Placeholder scan:** no TBD/TODO; every code step has full code; commands have expected output. The only "confirm by reading" notes are exact-line anchors the implementer verifies before an edit, not missing content.

**Type consistency:** `DirectoryDropFilter.directories(among:isDirectory:)`, `SidebarDropRegionRegistry.containsWindowPoint(_:in:)`, `SidebarFolderDropClassification` (`.openFolders`/`.rejectOverSidebar`/`.notSidebar`), `onFoldersDroppedOnSidebar: (([URL]) -> Bool)?`, and `TabManager.addWorkspace(workingDirectory:)` are used consistently across Tasks 2-5.
