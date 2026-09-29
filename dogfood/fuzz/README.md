# UI fuzzer

`scripts/fuzz` drives a cmux DEV build through random but valid action sequences and checks it after every
step. Actions: splits, pane focus, resize, swap and zoom, tab create, close, move, reorder and drag, divider
drags, workspace create, close, select, reorder, rename and actions, the sidebar, the command palette, terminal
typing bursts and keys, window resize, new window and full screen, browser splits and Settings. Pointer
actions go through cua-driver; everything else through the debug control socket. Its oracles still call
legacy-app `debug.*` methods (`debug.layout` and others) that cmux next does not implement yet.

After each step it looks for a crash (a `.ips` report or the process gone), a hang (the main thread stops
answering `system.identify`, or the app's own hang watchdog fires), fatal or assertion lines in the debug log,
memory that keeps growing, and broken layout: panes that do not tile the window, zero-size or overlapping
pane views, focus on more or fewer than one pane, and the socket's tab model disagreeing with the view tree.
A failure is replayed from a fresh app, delta-minimized to the shortest step list
that still fails the same way, then replayed once more with a frame per step.

The fleet runs it: an idle owned mini with `~/.config/glaeda/idle-fuzz.enabled` fuzzes the newest main build
it kept whenever nothing is left to warm (glaeda-idle-warm), and every CI job preempts it. Findings are filed
as issues with the `[fuzz]` title prefix, deduplicated by a signature marker.

## Commands

Only on a Mac whose console nobody is using. The app starts in a sandboxed home with a bare prompt, so
frames show no user, host or files.

```bash
scripts/fuzz run --app "<path>/cmux DEV.app" --minutes 20 [--seed S] [--focus splits,drag]
scripts/fuzz replay <finding>/repro.json --app "<path>/cmux DEV.app"
scripts/fuzz issue <finding>              # the issue it would file, or the existing one it matches
scripts/fuzz issue <finding> --file       # upload the repro frames and file it
```

A run writes `run.json`, `summary.json` and one `session-NNN/` per app launch: `steps.jsonl`, the last
frames and, for a failure, `finding.json`, `repro.json`, `repro/frames/`, the debug log tail, a sample and
any crash report. To fix a finding, replay its `repro.json` against your build; it passes once the bug is gone.

`scripts/fuzz regressions` replays every repro in `regressions/` against a given app. No CI lane runs it
since the legacy UI test lane was removed.

Steps address panes, tabs and workspaces by position (a fraction of whatever exists), never by id, so any
subsequence of a run still executes. `tests/test_ui_fuzzer_engine.py` covers the parts that need no app.
