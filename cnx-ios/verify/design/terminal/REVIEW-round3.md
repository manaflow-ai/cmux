# Terminal and tabs: round 3 designer review (in progress)

Build under review: `origin/feat-cnx-ios` at `6187529c` (terminal round 3:
`c5f1aa8e`, `1e0ef84a`, `bb3f60e6`).

## Checklist

- [x] R2-1: layout fixed (PTY 53x24 -> 53x41 on q, history above prompt); FAIL on "pull-down scrolls": with keyboard up at bottom a downward drag above the keyboard does nothing (M6 pin), `01`, `02`, `v1`, `v2`
- [x] R2-2 PASS (code + unit tests): ComposerPasteRoute .file -> loadFiles (security-scoped, size cap, error message), file:// text never typed
- [x] R2-3 hide PASS (no black frame 1.5-2.7 s, `03`); NEW: keyboard SHOW over top: terminal black except cursor 7.048-7.198 s (~150 ms), `04`, `v3`
- [x] R2-4 rest PASS (tab..↑ whole, ↑ ends 316.7, joystick 323: 6 pt); after swipe settles whole keys, no sliver, but a 19-20 pt hole lead or trail (`05`)
- [ ] R2-5 relaunch frame handoff (U5 documented)
- [x] R2-6 PASS (`06`: at bottom prompt 230 full; scrolled up row 184 170->90)
- [x] R2-7 FAIL: "rivate/tmp/cnx-e2e-091910-sample.md" and "1910.txt" listed (`07`); /tmp == /private/tmp PASS; chips 8.6 pt under Done PASS
- [ ] SPEC spot checks (B1, B2, M3, M4, P1, P5, M8/U3, P6/U1)
- [x] Rig run from fresh_install: 9/9 + 8/8 pass (091552, 091909)
- [ ] Mock (layout only)
