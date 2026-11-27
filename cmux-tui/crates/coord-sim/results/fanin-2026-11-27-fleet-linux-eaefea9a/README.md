# fanin ramp 50/200/2000 at feat-cmux-next eaefea9a (fleet-linux)

This is the first valid ramp since cmux#56640 made the controller dial hosts on demand. cmux#60107 (merged at 640eeab4) made the harness dial each host before it attaches. The run at 7d8af523 (job fb0d41cfe26529dbc82672d9) was invalid: no host ever connected and 1,933 of 2,000 attaches failed.

Run: `cmux-ci test --route fleet --setup rust --timeout 7200 -- bash cmux-tui/crates/coord-sim/src/fanin/ci.sh`

The summary is in `fanin-summary.json` next to this file, which is added when the run finishes. The goal is `sessions_scale.ratio_max` ≤ 1.2x (cmuxterm-hq goals/sessions-2000-attached.md).
