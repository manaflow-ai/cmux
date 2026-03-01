# cmux Architecture Reference

Quick-reference for navigating the cmux codebase during crux development.

## File Map (by size, descending)

| File | Lines | Role |
|------|-------|------|
| `Sources/ContentView.swift` | 9,000 | Sidebar UI, workspace rendering, drag/drop, SidebarSelection enum (line 8276) |
| `CLI/cmux.swift` | 6,000 | CLI binary — command parsing, socket client, all `cmux <cmd>` subcommands |
| `Sources/AppDelegate.swift` | 6,000 | App lifecycle, window management, keyboard monitors, session autosave timer |
| `Sources/Workspace.swift` | 4,200 | Panel management, bonsplit layout, sidebar metadata, terminal/browser creation |
| `Sources/TerminalController.swift` | 3,500 | Unix socket server, v1+v2 command dispatch, 60+ handlers |
| `Sources/TabManager.swift` | 3,500 | Per-window workspace list, selection, reordering, session snapshots |
| `Sources/GhosttyTerminalView.swift` | 2,800+ | Ghostty surface creation, action callbacks, rendering integration |

## Key Patterns

### Singleton + EnvironmentObject (dual injection)

Used by `TerminalNotificationStore`. The scheduler must follow this pattern:

```swift
// 1. Singleton for non-SwiftUI access (socket handlers)
@MainActor final class SchedulerEngine: ObservableObject {
    static let shared = SchedulerEngine()
}

// 2. EnvironmentObject for SwiftUI views — inject at BOTH sites:
// cmuxApp.swift:184
ContentView(...).environmentObject(SchedulerEngine.shared)

// AppDelegate.swift:3703 (openNewWindow)
ContentView(...).environmentObject(SchedulerEngine.shared)
// Missing the second site crashes any 2nd window
```

### v2 Socket Command Dispatch

All v2 commands follow this pattern in `TerminalController.swift`:

```swift
// In processV2Command() switch (~line 1035):
case "scheduler.create":
    return v2Result(id: id, self.v2SchedulerCreate(params: params))

// Handler:
private func v2SchedulerCreate(params: [String: Any]) -> V2CallResult {
    guard let name = v2String(params, "name") else {
        return .err(code: "invalid_params", message: "Missing name", data: nil)
    }
    var result: [String: Any]?
    v2MainSync {
        // UI/model mutations on main thread
        result = [...]
    }
    return .ok(result ?? [:])
}
```

Key helpers: `v2MainSync {}`, `v2ResolveTabManager(params:)`, `v2FocusAllowed()`, `v2String(params, key)`, `v2Ref(kind:uuid:)`.

### Session Persistence

JSON snapshots saved to `~/Library/Application Support/cmux/session-{bundleId}.json`:

```swift
// Path resolution (SessionPersistence.swift:400-411):
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dir = appSupport.appendingPathComponent("cmux")
let file = dir.appendingPathComponent("session-\(safeBundleId).json")

// Atomic write:
try data.write(to: fileURL, options: .atomic)

// Background queue (AppDelegate.swift:1068):
let queue = DispatchQueue(label: "com.cmuxterm.app.sessionPersistence", qos: .utility)
```

### Timer Patterns

Session autosave (AppDelegate.swift:1853):
```swift
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
timer.setEventHandler { [weak self] in self?.tick() }
timer.resume()
```

### SidebarSelection Exhaustive Switches

Adding `.scheduler` requires changes at these locations (compiler will enforce):

| Location | File:Line | What |
|----------|-----------|------|
| Enum definition | `ContentView.swift:8276` | Add case |
| Session persistence | `SessionPersistence.swift:170-190` | Add to `SessionSidebarSelection` + both conversion switches |
| Fingerprint hasher | `AppDelegate.swift:1989` | `case .scheduler: hasher.combine(2)` |
| Debug test writer | `AppDelegate.swift:4562` | `case .scheduler: return "scheduler"` |
| Session snapshot builder | `AppDelegate.swift:2174` | Already uses `SessionSidebarSelection(selection:)` — covered by the persistence change |

## Ghostty C API (Key Functions)

From `ghostty.h`:

| Function/Type | Line | Purpose |
|---------------|------|---------|
| `ghostty_surface_config_s` | 440-453 | Surface configuration struct |
| `.command` field | 447 | Command to run instead of default shell (**unused by cmux**) |
| `.wait_after_command` | 451 | Keep terminal alive after command exits |
| `.working_directory` | 446 | Initial working directory |
| `.env_vars` / `.env_var_count` | 448-449 | Environment variable injection |
| `ghostty_surface_new()` | 1056 | Create surface (requires valid NSView) |
| `ghostty_surface_free()` | 1058 | Destroy surface |
| `ghostty_surface_request_close()` | 1097 | Request graceful close |
| `ghostty_surface_read_text()` | 1112 | Read terminal content by region |
| `GHOSTTY_ACTION_COMMAND_FINISHED` | 901 | Callback with exit_code (int16) + duration (uint64 ns) |
| `GHOSTTY_ACTION_SHOW_CHILD_EXITED` | — | Callback when child process exits (cmux handles this at GhosttyTerminalView.swift:1065) |
| `ghostty_action_command_finished_s` | 813-818 | Struct: `exit_code: int16, duration: uint64` |

## Browser Kill-Switch Guard Points

4 locations, verified by agent audit:

| Guard | File:Line | Entry Path |
|-------|-----------|------------|
| Cmd+Shift+L shortcut | `ContentView.swift:4061` | User keyboard |
| v1 `open_browser` | `TerminalController.swift:927` | Socket/CLI |
| v2 `browser.*` | `TerminalController.swift:5095` | Socket/CLI |
| Session restore `.browser` | `Workspace.swift:505` | App launch |

All 12 files that reference WebKit:
`BrowserPanel.swift`, `BrowserPanelView.swift`, `CmuxWebView.swift`, `ContentView.swift`, `BrowserWindowPortal.swift`, `TerminalController.swift`, `AppDelegate.swift`, + 5 test files.

Only the 4 guard points need changes. WebKit framework is implicitly linked via AppKit (no explicit framework reference in project.pbxproj).
