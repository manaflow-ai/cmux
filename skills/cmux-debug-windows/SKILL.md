---
name: cmux-debug-windows
description: Manage cmux debug windows and related debug menu wiring for Sidebar Debug, Background Debug, and Menu Bar Extra Debug. Use this when the user asks to open/tune these debug controls, add or adjust Debug menu entries, or capture/copy a combined debug config snapshot.
---

# cmux Debug Windows

Keep this workflow focused on existing debug windows and menu entries. Do not add a new utility/debug control window unless the user asks explicitly.

## Workflow

1. Verify debug menu wiring in `Sources/cmuxApp.swift` under `CommandMenu("Debug")`.
   - Menu path in app: `Debug` → `Debug Windows` → window entry.
   - The `Debug` menu only exists in DEBUG builds (`./scripts/reload.sh --tag ...`).
   - Release builds (`reloadp.sh`, `reloads.sh`) do not show this menu.
2. Keep these actions available in `Menu("Debug Windows")`:
- `Sidebar Debug…`
- `Background Debug…`
- `Menu Bar Extra Debug…`
- `Open All Debug Windows`
3. Reuse existing per-window copy buttons (`Copy Config`) in each debug window before adding new UI.
4. For one combined payload, run:
```bash
skills/cmux-debug-windows/scripts/debug_windows_snapshot.sh --copy
```
5. After code edits, run build + tagged reload:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
./scripts/reload.sh --tag <tag>
```

## Key Files

- `Sources/cmuxApp.swift`: Debug menu entries and debug window controllers/views.
- `Sources/AppDelegate.swift`: Menu bar extra debug settings payload and defaults keys.

## Script

- `scripts/debug_windows_snapshot.sh`

Purpose:
- Reads current debug-related defaults values.
- Prints one combined snapshot for sidebar/background/menu bar extra.
- Optionally copies it to clipboard.

Examples:
```bash
skills/cmux-debug-windows/scripts/debug_windows_snapshot.sh
skills/cmux-debug-windows/scripts/debug_windows_snapshot.sh --copy
skills/cmux-debug-windows/scripts/debug_windows_snapshot.sh --domain <bundle-id> --copy
```
