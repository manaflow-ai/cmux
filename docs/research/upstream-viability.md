# Upstream Viability Assessment

## Can crux's scheduler features be upstreamed to cmux?

**Short answer**: Yes, moderate effort, requires coordination.

## What Makes It Viable

### Mostly new files (low conflict risk)

5 of 13 files are brand new:
- `Sources/Scheduler/ScheduledTask.swift`
- `Sources/Scheduler/SchedulerPersistence.swift`
- `Sources/Scheduler/SchedulerEngine.swift`
- `Sources/Scheduler/SchedulerPage.swift`
- `Sources/TerminalController+Scheduler.swift`

These can be submitted as a self-contained feature PR with no merge conflicts.

### Existing file changes are surgical additions

| File | Change Type | Conflict Risk |
|------|-------------|---------------|
| `SidebarSelection` enum | +1 case | Low — append |
| `SessionSidebarSelection` | +1 case + 2 switch branches | Low — append |
| `AppDelegate` | +3 lines (fingerprint, debug, env) | Low — additions near existing |
| `cmuxApp` | +1 `.environmentObject()` | Low — append to chain |
| `ContentView` | +1 ZStack entry + sidebar button | Medium — near frequently-changed area |
| `TerminalController` | +10 case statements (or extension file) | Low if using extension file |
| `CLI/cmux.swift` | +1 case in dispatcher | Low — append |

### Browser kill-switch is independently upstreamable

4 guard clauses + 1 UserDefaults registration. Addresses a legitimate security concern. Good candidate for a standalone PR to build rapport with maintainer.

## What Makes It Painful

### ContentView.swift (9k lines) changes frequently

Upstream cmux commits touch this file almost daily (sidebar polish, shortcut hints, drag/drop). The ZStack entry and sidebar button additions will conflict with upstream changes near those insertion points. Requires regular rebasing.

### TerminalController.swift has a growing switch statement

Every new cmux feature adds cases to the v2 command switch. Using `TerminalController+Scheduler.swift` as an extension minimizes the diff in the main file to just 10 `case` lines.

### AGPL license

cmux is AGPL-3.0. Contributing code means it's under AGPL. Standard CLA territory — either assign copyright or confirm AGPL licensing.

### Ghostty `surfaceConfig.command` is novel

cmux has never used this field. Maintainer may want additional safety checks, error handling, or feature flags before merging. Most likely point of review friction.

### Git worktree isolation is opinionated

Auto-creating worktrees is a workflow choice. Make it opt-in (already planned as default OFF) to reduce friction.

## Recommended Upstream Strategy

1. **PR 1: Browser kill-switch** (standalone, small, addresses real concern)
2. **PR 2: Scheduler feature** (5 new files + surgical diffs, using extension file)
3. **PR 3+: Bonus features** (worktree isolation, cost tracking, task chaining) as follow-ups

## Merge Conflict Forecast

If implementation takes 2-3 weeks and upstream has 20-30 commits:
- 2-4 minor conflicts in `ContentView.swift` (near ZStack and sidebar button)
- 1-2 conflicts in `TerminalController.swift` (near v2 switch)
- All trivially resolvable ("add my new case near their new case")
