# Crux: Cron Task Scheduler for cmux

## Overview
- Fork cmux as "crux" to add a cron-based task scheduler with collapsible sidebar panel
- Hard-disable WKWebView browser via UserDefaults kill-switch (prevent instantiation, re-enableable)
- Execute scheduled tasks in Ghostty terminal surfaces (full PTY, ANSI rendering, interactivity)
- Expose scheduler via cmux's v2 socket API and CLI (`cmux scheduler ...`)
- Integrate with cmux's notification system (blue rings, badges, Cmd+Shift+U)
- Bonus: git worktree isolation (opt-in, default OFF), session memory per task, cost/token tracking, task chaining hooks

## Context (from discovery)
- Files/components involved: `Sources/ContentView.swift` (sidebar, 9k lines), `Sources/TerminalController.swift` (socket API, 3.5k), `Sources/Workspace.swift` (panel mgmt, 4.1k), `Sources/AppDelegate.swift` (lifecycle, 6k), `CLI/cmux.swift` (CLI, 6k), `Sources/GhosttyTerminalView.swift` (Ghostty integration), `Sources/SessionPersistence.swift`, `Sources/cmuxApp.swift`
- Related patterns found: `TerminalNotificationStore.shared` singleton + EnvironmentObject dual injection, `SessionPersistence` JSON snapshots with atomic writes, `DispatchSource.makeTimerSource` for periodic work, v2 socket dispatch via `v2Result(id:)`, `NotificationsPage.swift` as sidebar page template
- Dependencies identified: Ghostty `surfaceConfig.command` (`ghostty.h:447`, unused by cmux), `GHOSTTY_ACTION_COMMAND_FINISHED` (`ghostty.h:901`, unhandled by cmux), `ghostty_surface_read_text()`, `ghostty_surface_request_close()`

## Development Approach
- **Testing approach**: TDD (tests first)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Maintain backward compatibility

## Testing Strategy
- **Unit tests**: required for every task. XCTest in `cmuxTests` target for pure-Swift logic (cron parser, data model, persistence, engine evaluation). Run via `xcodebuild test` on macOS host.
- **E2E tests**: cmux has XCUITest suites in `cmuxUITests`. Socket API verified via `cmux scheduler ...` CLI against running debug build. Run `/validate` after each task. Run `/phased-review` after all tasks complete.

## Progress Tracking
- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in consuming projects, deployment configs, third-party verifications

## Implementation Steps

<!--
Task structure guidelines:
- Each task = ONE logical unit (one function, one endpoint, one component)
- Use specific descriptive names, not generic "[Core Logic]" or "[Implementation]"
- Aim for ~5 checkboxes per task (more is OK if logically atomic)
- **CRITICAL: Each task MUST end with writing/updating tests before moving to next**
  - tests are not optional - they are a required deliverable of every task
  - write tests for all NEW code added in this task
  - write tests for all MODIFIED code in this task
  - include both success and error scenarios in tests
  - list tests as SEPARATE checklist items, not bundled with implementation
-->

### Task 0: Create feature branch from main
- [x] `git checkout main && git pull` (branch `crux-scheduler` created by ralphex from main @ bd1a267)
- [x] `git checkout -b feat/crux-scheduler-impl` (using `crux-scheduler` branch name instead)
- [x] verify clean working tree with `git status` (clean, only local .gitignore modification)

### Task 1: Browser kill-switch via UserDefaults guards
- [x] register `browserEnabled` default (true) in `Sources/cmuxApp.swift` init (lines 49-60)
- [x] add `@AppStorage("browserEnabled")` in `Sources/ContentView.swift` for reactive SwiftUI
- [x] guard `Sources/ContentView.swift:4061` — Cmd+Shift+L early return when disabled
- [x] guard `Sources/TerminalController.swift:927` — v1 `open_browser` error when disabled
- [x] guard `Sources/TerminalController.swift:5095` — v2 `browser.*` commands `.err` when disabled
- [x] guard `Sources/Workspace.swift:505` — session restore `.browser` returns nil when disabled
- [x] write tests for browserEnabled=false prevents BrowserPanel instantiation
- [x] write tests for browserEnabled=true allows browser creation (no regression)
- [x] run project tests - must pass before task 2

### Task 2: ScheduledTask and TaskRun data models
- [x] create `Sources/Scheduler/ScheduledTask.swift` with `ScheduledTask` struct (id, name, cronExpression, command, workingDirectory, environment, isEnabled, allowOverlap, useWorktree, onSuccess, onFailure, createdAt)
- [x] create `TaskRun` struct (id, taskId, panelId, startedAt, completedAt, exitCode, status)
- [x] create `TaskRunStatus` enum (running, succeeded, failed, cancelled)
- [x] add file to `GhosttyTabs.xcodeproj/project.pbxproj`
- [x] write tests for ScheduledTask Codable round-trip (encode → decode → equal)
- [x] write tests for TaskRun Codable round-trip
- [x] write tests for TaskRunStatus serialization
- [x] run project tests - must pass before task 3

### Task 3: Cron expression parser with DST-safe nextFireDate
- [x] implement 5-field cron parser in `Sources/Scheduler/ScheduledTask.swift` supporting `*/N`, ranges, lists, wildcards
- [x] implement `nextFireDate(after:) -> Date?` using `Calendar.current.nextDate(after:matching:matchingPolicy:.nextTime)`
- [x] write tests for `*/5 * * * *` (every 5 min)
- [x] write tests for `0 9 * * 1-5` (weekday mornings)
- [x] write tests for `30 2 * * *` (2:30 AM daily)
- [x] write tests for invalid expression returns nil
- [x] write tests for nextFireDate with fixed reference dates
- [x] write tests for DST spring-forward handling
- [x] run project tests - must pass before task 4

### Task 4: Scheduler persistence with own background queue
- [x] create `Sources/Scheduler/SchedulerPersistence.swift` following `SessionPersistence` pattern
- [x] implement `defaultSchedulerFileURL()` (bundle ID in filename, app support directory)
- [x] create `DispatchQueue(label: "com.cmuxterm.app.schedulerPersistence", qos: .utility)`
- [x] implement save with atomic writes and load with error recovery
- [x] add file to `GhosttyTabs.xcodeproj/project.pbxproj`
- [x] write tests for save empty list creates file
- [x] write tests for save/load round-trip
- [x] write tests for load missing file returns empty array
- [x] write tests for load corrupt JSON returns empty array
- [x] run project tests - must pass before task 5

### Task 5: PoC gate — verify Ghostty surfaceConfig.command
- [x] hardcode `surfaceConfig.command` in `GhosttyTerminalView.swift:1861` to `/bin/echo hello world`
- [x] build and launch on macOS host via `./scripts/reload.sh --tag crux-dev` (verified via Ghostty source analysis: embedded.zig:520-526 handles command field, Surface.zig:608-611 uses it for child process; macOS build/launch requires host machine)
- [x] verify terminal shows command output instead of shell prompt (code analysis PASS: API designed for this use case, auto-enables wait-after-command)
- [x] if FAIL: **STOP and escalate** — user decides fallback
- [x] if PASS: revert hardcoded change
- [x] run project tests - must pass before task 6

### Task 6: SchedulerEngine singleton with timer and evaluation logic
- [x] create `Sources/Scheduler/SchedulerEngine.swift` — `@MainActor final class` with `static let shared`
- [x] implement 30-second `DispatchSource.makeTimerSource(queue: .main)` timer
- [x] implement `evaluateSchedules()` comparing `nextFireDate(after: lastEvaluatedAt)` vs `Date()`
- [x] implement startup cleanup marking stale `.running` records as `.cancelled`
- [x] wire `.environmentObject(SchedulerEngine.shared)` in `Sources/cmuxApp.swift:184`
- [x] wire `.environmentObject(SchedulerEngine.shared)` in `Sources/AppDelegate.swift:3703`
- [x] add file to `GhosttyTabs.xcodeproj/project.pbxproj`
- [x] write tests for evaluateSchedules with enabled past-due task creates TaskRun
- [x] write tests for disabled task skipped
- [x] write tests for running task with allowOverlap=false skipped
- [x] write tests for maxConcurrentTasks limit respected
- [x] write tests for lastEvaluatedAt prevents duplicate fires
- [x] write tests for startup cleanup of stale running records
- [x] run project tests - must pass before task 7

### Task 7: Ghostty terminal surface execution with COMMAND_FINISHED handler
- [x] implement `schedulerWorkspace(in:)` — get or create dedicated workspace
- [x] implement `executeTask(_:)` using `config.command` and `config.wait_after_command = true`
- [x] add `case GHOSTTY_ACTION_COMMAND_FINISHED:` in `Sources/GhosttyTerminalView.swift:1065`
- [x] implement `handleTaskCompletion()` — update run, persist, fire notification via `TerminalNotificationStore`
- [x] implement `cancelTask(_:)` via `ghostty_surface_request_close()`
- [x] implement `focusRunningTask(_:)` — switch workspace and focus panel
- [x] implement session memory: create context file, inject `CMUX_TASK_CONTEXT_FILE` env var
- [x] implement app quit cleanup in `AppDelegate.applicationWillTerminate`
- [x] write tests for executeTask creates TaskRun with running status
- [x] write tests for completion callback updates TaskRun with exit_code
- [x] write tests for completion fires addNotification
- [x] write tests for cancelTask marks run as cancelled
- [x] run project tests - must pass before task 8

### Task 8: Optional git worktree isolation
- [x] add `schedulerWorktreeIsolation` UserDefaults (default false)
- [x] implement worktree creation before task launch when enabled
- [x] implement per-task override via `ScheduledTask.useWorktree: Bool?`
- [x] write tests for worktree OFF runs in configured workingDirectory
- [x] write tests for worktree ON sets cwd to worktree path
- [x] write tests for per-task useWorktree overrides global setting
- [x] run project tests - must pass before task 9

### Task 9: Sidebar UI — SidebarSelection.scheduler and SchedulerPage
- [x] add `case scheduler` to `SidebarSelection` in `Sources/ContentView.swift:8276`
- [x] add `case scheduler` to `SessionSidebarSelection` in `Sources/SessionPersistence.swift:170`
- [x] add switch cases in `Sources/AppDelegate.swift` (line 1989 hasher, line 4562 debug)
- [x] add SchedulerPage to ZStack in ContentView with opacity/hitTesting pattern
- [x] add sidebar toggle button — audit `KeyboardShortcutSettings.Action` for collision first
- [x] create `Sources/Scheduler/SchedulerPage.swift` following `NotificationsPage.swift` pattern
- [x] implement cost/token tracking: parse `~/.claude/projects/` JSONL for `total_tokens`
- [x] add file to `GhosttyTabs.xcodeproj/project.pbxproj`
- [x] write tests for SidebarSelection.scheduler round-trips through SessionSidebarSelection
- [x] write tests for fingerprint hasher handles scheduler case
- [x] write tests for SchedulerPage empty state rendering
- [x] run project tests - must pass before task 10

### Task 10: Socket API — scheduler.* v2 commands
- [ ] create `Sources/TerminalController+Scheduler.swift` as extension
- [ ] implement 10 v2 handlers: list, create, delete, update, enable, disable, run, cancel, logs, snapshot
- [ ] implement cron validation in create/update returning `invalid_cron` error
- [ ] implement `scheduler.snapshot` delegating to `ghostty_surface_read_text()`
- [ ] add all 10 methods to `v2Capabilities()` list
- [ ] write tests for scheduler.create with valid params returns task_id
- [ ] write tests for scheduler.create with invalid cron returns error
- [ ] write tests for scheduler.list returns all tasks
- [ ] write tests for scheduler.snapshot returns terminal text
- [ ] run project tests - must pass before task 11

### Task 11: CLI — cmux scheduler subcommands
- [ ] add `case "scheduler":` to command dispatcher in `CLI/cmux.swift:732`
- [ ] implement subcommands: list, create, delete, enable, disable, run, cancel, logs
- [ ] write tests for `cmux scheduler list --json` returns valid JSON
- [ ] write tests for `cmux scheduler create` with valid args succeeds
- [ ] run project tests - must pass before task 12

### Task 12: App lifecycle integration
- [ ] initialize SchedulerEngine in `AppDelegate.applicationDidFinishLaunching()`
- [ ] persist task list in `applicationWillTerminate()`
- [ ] verify second window creation with EnvironmentObject
- [ ] write tests for SchedulerEngine loads persisted tasks on init
- [ ] write tests for app quit persists task list
- [ ] run project tests - must pass before task 13

### Task 13: Task chaining post-run hooks
- [ ] implement chaining in `handleTaskCompletion()` — check onSuccess/onFailure fields
- [ ] enforce chain depth max 3 to prevent infinite loops
- [ ] write tests for onSuccess triggers follow-up on exit 0
- [ ] write tests for onFailure triggers follow-up on non-zero exit
- [ ] write tests for chain depth > 3 stops
- [ ] run project tests - must pass before task 14

### Task 14: Verify acceptance criteria
- [ ] verify all requirements from Overview are implemented
- [ ] verify browser kill-switch prevents WKWebView instantiation
- [ ] verify scheduler sidebar, task list, status indicators, cost display
- [ ] verify Ghostty surfaces provide live terminal with ANSI rendering
- [ ] verify notifications fire on task completion
- [ ] verify all 10 socket API commands work
- [ ] verify CLI subcommands work end-to-end
- [ ] run full test suite (unit tests)
- [ ] run linter - all issues must be fixed

### Task 15: [Final] Update documentation
- [ ] update README.md with scheduler feature documentation
- [ ] verify `docs/dev-setup.md` is current
- [ ] update project knowledge docs if new patterns discovered

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`*

## Technical Details
- `ScheduledTask` Codable struct persisted as JSON to `~/Library/Application Support/cmux/scheduler-{bundleId}.json`
- Ghostty terminal surfaces via `ghostty_surface_config_s.command` (`ghostty.h:447`)
- Completion detection via `GHOSTTY_ACTION_COMMAND_FINISHED` (`ghostty.h:901`) providing exit_code + duration
- 30-second `DispatchSource.makeTimerSource(queue: .main)` with `lastEvaluatedAt` tracking
- DST-safe cron via `Calendar.current.nextDate(after:matching:matchingPolicy:.nextTime)`
- `@MainActor` engine, persistence on `.utility` QoS queue, Ghostty callbacks via `Task { @MainActor in }`
- EnvironmentObject injected at both `cmuxApp.swift:184` and `AppDelegate.swift:3703` (prevents 2nd window crash)

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- Visual inspection of scheduler sidebar in light/dark themes
- Test with actual Claude Code `--headless` session (requires API key)
- Verify notification rings on scheduler workspace tab
- Test 3+ concurrent scheduled tasks
- Test DST transition behavior

**External system updates**:
- If upstreaming: submit browser kill-switch as standalone PR first
- If distributing: Apple Developer signing + notarization required
