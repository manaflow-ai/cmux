# Debug Event Log

Paths, prefixes, and the tail command are in [../SKILL.md](../SKILL.md). This covers when to add a probe.

## Call site shape

```swift
#if DEBUG
cmuxDebugLog("focus.panel ...")
#endif
```

The package implementation and app shim are DEBUG-only, so an unguarded call site breaks non-Debug builds.

## When to add probes

Add a probe during a dogfood debug loop when it answers a concrete question: which event path fired, which panel or pane had focus, which split/tab/drop transition occurred, whether a stale view or responder received an event, whether a path fires on every keypress.

Do not instrument a file just because it is nearby. Remove temporary probes before merge unless they are low-volume and clearly useful later.

## Naming

Use a stable event prefix (see the list in the skill) and put dynamic details after it, so `rg`, `tail`, and log filtering stay practical.

## Recovering missed events

The 500-entry ring buffer holds history from before you started tailing. `CMUXDebugLog.DebugEventLog.shared.dump()` flushes it to file.
