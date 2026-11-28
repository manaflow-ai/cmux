# 2026-11-27-tip-daemon-superseded-defers

On CMUX_TUI_TREE_TIP_SUITE in path_route's two same-tree probes (`Probe the same-tree cmux-tui` and `... after
the marker`) in `.github/workflows/cmux-next.yml`, read by `scripts/cmux-next/pin-cmux-tui.sh probe`.

Leo, 2026-11-25: "and the whole equilibirum between skipping ci aka ripping it down to 0 vs just keeping it as
is and going in to find where we can trim out vacuously true stuff and analyze the most genuinely compile/build
break catching". A tip daemon suite is feat-cmux-next's daemon-test verdict for one exact commit. When a newer
push cancelled that commit's cmux-tui artifacts run, the probe read `superseded` and daemon tests skipped, which
is right for a push run (the newer push tests the newer tree) and wrong for the tip suite, which nothing else
replaces: from 2026-11-26 21:54Z to 2026-11-27 05:23Z 14 tip daemon suites gave 3 daemon-test verdicts. With
the variable set the probe reads `deferred` instead, so the tip_suite wait marker waits for the tree's next
publish and `cmux_next_tree_notify.py` dispatches the same-tree run. Push runs are unchanged.
Tests: scripts/cmux-next/tests/pin-cmux-tui-probe.test.sh ("tip suite, publisher cancelled by a newer push").
