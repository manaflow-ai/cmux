# Debug Event Log

The debug event log is the preferred shared destination for temporary and durable DEBUG-only probes.

## Destination

Tagged builds write tag-specific logs:

- untagged Debug app: `/tmp/cmux-debug.log`
- tagged Debug app: `/tmp/cmux-debug-<tag>.log`

`reload.sh` writes the current path to `/tmp/cmux-last-debug-log-path`, so the most robust tail command is:

```bash
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"
```

Use this instead of guessing whether the current run is tagged.

## Shape

The package implementation lives in `Packages/macOS/CMUXDebugLog/Sources/CMUXDebugLog/DebugEventLog.swift`, and the app shim lives in `Sources/App/DebugLogging.swift`.

Call sites use:

```swift
#if DEBUG
cmuxDebugLog("focus.panel ...")
#endif
```

Every call site must be guarded by `#if DEBUG` / `#endif`. The implementation and shim are DEBUG-only, so unguarded call sites break non-Debug builds.

## When to add probes

Add probes during a dogfood debug loop when they help answer a concrete question:

- Which event path fired?
- Which panel or pane had focus?
- Which split/tab/drop transition occurred?
- Did a stale view or responder receive an event?
- Did a path fire on every keypress?

Do not add broad instrumentation just because a file is nearby. Remove temporary probes before merge unless they are low-volume and clearly useful for future debugging.

## Naming

Prefer stable event prefixes:

- `focus.panel`
- `focus.bonsplit`
- `focus.firstResponder`
- `focus.moveFocus`
- `tab.select`
- `tab.close`
- `tab.dragStart`
- `tab.drop`
- `pane.focus`
- `pane.drop`
- `divider.dragStart`

Put dynamic details after the prefix. This makes `rg`, `tail`, and log filtering practical.

## Ring buffer

The debug logger has a 500-entry ring buffer. `CMUXDebugLog.DebugEventLog.shared.dump()` writes the full buffer to file. Use this when the interesting event occurred before you started tailing.
