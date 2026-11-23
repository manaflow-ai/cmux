# cmux-next code rules

Moved here from the root CLAUDE.md on 2026-11-19 (docs audit); the root keeps a one-line pointer.

The pre-push gate (`scripts/cmux-next/prepush-gate.py`) and CI enforce most of these.

## Rules the gate checks

- No blocking calls on the main thread: use the async or background API
  (`openInBackground`/`revealInBackground`, async reads, an injected `Clock`), not
  `Thread.sleep`, `.wait()`, `readDataToEndOfFile()`, `waitUntilExit()` or `NSWorkspace.shared.open`.
- No `try!`: throw or handle a typed error.
- Fonts come from `TypeScale` or `Typography`, never a literal size.
- Every animation goes through a category motion gate (`Motion.<category>.animate(...)` and
  friends) that obeys the master switch, the category switch, `ui.animationSpeed` and Reduce
  Motion; code works with no animation at all. No raw `NSAnimationContext`, `withAnimation`,
  `.animation(...)`, `CABasicAnimation` or `animator()` outside a gate, and no bypass of web
  `WebTheme`'s `data-cmux-motion`; a reviewed exception says `// motion: allow <how>`.
  `check-motion.sh` enforces it; categories and a new area's steps:
  [motion-DESIGN.md](../../plans/cmux-next/motion-DESIGN.md).
- Dialogs use the standard key-hint components (`CmuxDialogSpec`, `CmuxDialogActionButton`,
  `ThemedBezelButton.keyHint`, web `ui/DialogButton`), never `NSAlert`, `.alert` or `.confirmationDialog`.
- A held button changes only its background fill: never its weight (no bold on press), font, size, scale,
  offset, opacity or icon, on macOS, iOS and web. Use the shared looks (`ChromeHover`,
  `.buttonStyle(.cmuxPressFill)` on macOS and iOS, web `.ui-btn`), never SwiftUI `.plain`/`.borderless`/`.link`
  (they dim the label). `check-pressed-state.py` enforces it; rule and exceptions:
  [design/pressed-state.md](../../design/pressed-state.md) (Lawrence 2026-11-15).
- An escape comment (`// concurrency-allow:`, `// crash-allow:`, `dialog-keys-exempt:`)
  needs a reason that proves the code is safe; it is not a way to pass the gate.
- Never change a Ghostty-default shortcut without the user's explicit OK. Ghostty's split keys
  (Cmd-Opt-arrows focus a pane, Cmd-D / Cmd-Shift-D split, Ctrl-Cmd-arrows resize,
  Cmd-Shift-Return zoom) are reserved in `schemas/keybindings/ghostty-reserved-keys.json`;
  no other action may take one, in any pane. `GhosttyReservedKeysTests` and the gate's
  "Ghostty-default keys" check enforce it, and `CMUX_NEXT_CHECKS_SKIP_REASON` does not skip
  it: only a `Ghostty-defaults-OK: <the user's words>` commit trailer does. (2f3e1f95983 made
  Cmd-Opt-Left / Right sidebar keys; Lawrence 2026-10-20: "ensure this never happens again".)

- A new or rewritten action handler is `registry.bindEffect(id, effect:)` returning an
  `ActionEffect`; never await in a handler, start its remote work yourself, or do disk I/O, a
  waiting lock or a whole-session walk on its turn (< 10 ms to the commit; guardrail
  `action-wait`). Effect kinds and monitors: [zero-latency.md](../../plans/cmux-next/zero-latency.md),
  "Native actions: the budget contract".

## Before you touch hot paths

- Use the patterns in [PATTERNS.md](../../plans/cmux-next/PATTERNS.md) (composition root, seam adapters, targeted
  observation, instant create, main-thread budget, off-main frames, daemon request path) and meet
  [REVIEW-STANDARD.md](../../plans/cmux-next/REVIEW-STANDARD.md): root-cause fixes, no hacks, no partial fixes. Review
  landed work with the repo workflow `.claude/workflows/cmux-next-deep-review.js`.
- A measurement lands as a registered bench in `scripts/bench/benches/` (`scripts/bench/cmux-bench list`), or extends
  one, never as a one-off script; perf PRs cite `cmux-bench compare` output ([scripts/bench/README.md](../../scripts/bench/README.md)).
- Budget: every action reaches its committed frame in < 10 ms p95; motion runs at full refresh, 0 drops.
  Measure on the fleet yourself, light and STRESS ([perf-lead.md](../../plans/cmux-next/perf-lead.md)), before and after.
- Agents may add CI gates, perf-gate rows and budgets, CI jobs, steps and tests (Aziz 2026-11-18 lifted the
  2026-10-23 "no new CI" rule; comments that cite it describe why older checks stayed local). Lawrence's separate
  perf decision still stands: a perf run never blocks or slows a push, a pull request merge or a nightly; it runs on
  the perf cron (`scripts/cmux-next/perf-cron.py`, [perf-lead.md](../../plans/cmux-next/perf-lead.md) F9). CI is
  in addition to your own run, never instead of it: each fix still gets a regression test that fails without it,
  you run it yourself on the fleet (cmux-ci, nx-remote) before and after the fix, and the commit says the result.
  Keep pull request CI fast: a check that takes more than about 10 minutes runs behind a path filter, on a
  schedule or on dispatch, not on every pull request.
- `// perf-hot: <budget> <path-id>` marks a per-frame, per-key or per-switch function; the pre-push hook names
  its bench ([perf-hot-benches.json](../../scripts/cmux-next/perf-hot-benches.json)). Mark new hot paths the same way.
- Read [OWNERS.md](../../plans/cmux-next/OWNERS.md) before you change an owned area, and tell the owner.
- Threads: [threading-model.md](../../plans/cmux-next/threading-model.md) says what each thread owns, may block on, its QoS and bound; the main thread never blocks (Debug detector, `allowBlocking` only for a listed reason).
- Copy Chrome's performance model (Lawrence 2026-10-24): before you design a fast path, find how
  Chromium does the same job and do that, or write in the commit why cmux differs. The main thread
  never blocks; input and changes coalesce to one frame per display refresh and animations are
  interruptible; measure input-to-frame as distributions, not means; hidden pages are discarded
  by Memory Saver rules and renderers shared per site; work runs by priority, and throttling is
  only for work the person cannot see, never the fix for a slow visible action.
- Go past Chrome where cmux is scripted: automation never competes with the person. Scripted
  changes use the same action pipeline at O(changed items); hidden workspaces update the model
  only; bursts coalesce to one model update and at most one frame per window; the person's input
  always goes first and the socket server works off the main thread.
  Full text of both rules: [PATTERNS.md](../../plans/cmux-next/PATTERNS.md#chrome-performance-model-lawrence-2026-10-24).
- The hook's guardrails refuse new debt in added lines (`scripts/cmux-next/guardrails.py --list`). When the
  hook warns that its installed copy is not origin/feat-cmux-next's, run `scripts/install-git-hooks.sh` from a
  checkout at origin/feat-cmux-next. The hooks are per clone: every worktree of it, main-based ones too, runs them.

## Crash classes

Each class of nightly crash has one guard. Do not work around it; fix the code.
- Unrecognized selector (a `super` call the framework class does not answer, a selector Chromium sends to
  NSApp): `scripts/cmux-next/check-objc-selectors.py` and `ObjCSelectorRuntimeTests` (runtime walk).
- AppKit off the main thread: suites run under Xcode's Main Thread Checker
  (`scripts/ci/run_swift_test_bundle.py`, `CMUX_MAIN_THREAD_CHECKER`, `MainThreadCheckerLoadedTests`).
- Stale AppKit index (-1 rows and columns): CmuxNextCompat's `clickedRowIfValid`, `selectedRowIfValid`,
  `clickedItemIfValid`, `item(ifValidRow:inColumn:)`; guardrails rule `appkit-index`.
- Undo into replaced text: set text from code only through `replaceAllTextUndoably(_:)` (CmuxNextDesign)
  in a view with `allowsUndo = true`; guardrails rule `undo-text-write`.
- Traps (`!`, `as!`, index, `fatalError`): `scripts/cmux-next/crash_ratchet.py`, whose baseline only goes down.
- Memory corruption and data races: run the suites of risky code under `CMUX_SWIFT_SANITIZE=address` or
  `thread` (`cmux-ci run --env CMUX_SWIFT_SANITIZE=...`); malloc zone changes: `malloc-zone-race/run.sh corrupt`.
- A crash that hangs: `CrashDeadline` (10 s) and the out-of-process `CrashWatcher` (15 s) end the app.

## Swift namespace convention

Public and package types in package source must expose an instance surface or
be scoped onto the owning type; caseless namespace enums and all-static public
or package types are lint violations. Run
`./scripts/lint-ios-package-conventions.sh --namespace-fix` before committing.
When installed with `scripts/install-git-hooks.sh --namespace-fix`, the
pre-push hook runs the fixer and stops so changed files can be reviewed,
staged, and committed. CI keeps the non-mutating lint as the backstop.

Post-edit and pre-commit hooks run the same fixer and format edited files the way CI checks
them, touching only those files ([hooks and lints](../../skills/cmux-dev-workflow/references/hooks-and-lints.md)).
