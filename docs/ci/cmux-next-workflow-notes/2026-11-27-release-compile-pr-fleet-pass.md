# 2026-11-27-release-compile-pr-fleet-pass

Job `release-compile` ("cmux-next Release compile (Xcode 26)"), its `needs:` and `if:`.

Leo: "de facto, im asking for 99% fewer minutes of ci time, period." / "whatever we need to cut, we cut."

A same-repository pull request into feat-cmux-next ran the Mac Release compile whenever `mac_release` was true and
`app-compile-fleet` gave no verdict. With `full-ci` (the label land-judge pulses at the land head) `app-compile-fleet`
is skipped by design, so its verdict is always empty and the Mac compile ran on every such head: 526 Mac compiles,
12,921 runner-min, on 300 PR branches in the 24 h to 2026-11-27 09:46Z (CI v2 timing feed). On those same heads
`compile-status` ("cmux-next fleet Release compile") already reads the build fleet's Release (-Onone) compile of the
exact head sha, p50 11 s; in a 20-head sample it read `pass` on 9.

The feat-cmux-next push run already takes that verdict in place of the Xcode compile
(`release-compile-fast` -> `release-compile-fast-admission`), and land-judge's compile gate reads the same receipt
first. So a PR head whose `compile-status` reads `pass` no longer takes a Mac. Every other state (`fail`, `none`,
`awaiting_land`, the controller still compiling, the results service down and its handoff) runs the Mac compile as
before, and forks keep it.

Undo: repo variable `CMUX_NEXT_PR_FLEET_PASS_SKIPS_MAC` = `0`.
