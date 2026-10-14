# Terminal and tabs: round 3 designer review (in progress)

Build under review: `origin/feat-cnx-ios` at `6187529c` (terminal round 3:
`c5f1aa8e`, `1e0ef84a`, `bb3f60e6`).

## Checklist

- [x] R2-1: layout fixed (PTY 53x24 -> 53x41 on q, history above prompt); FAIL on "pull-down scrolls": with keyboard up at bottom a downward drag above the keyboard does nothing (M6 pin), `01`, `02`, `v1`, `v2`
- [ ] R2-2 Paste of a copied file attaches via upload (source + tests)
- [ ] R2-3 no black frame on keyboard hide
- [ ] R2-4 key bar whole keys at rest, trailing gap
- [ ] R2-5 relaunch frame handoff (U5 documented)
- [ ] R2-6 composer-edge fade only while scrolled under
- [ ] R2-7 Files and Links fragments, duplicates, chip spacing
- [ ] SPEC spot checks (B1, B2, M3, M4, P1, P5, M8/U3, P6/U1)
- [x] Rig run from fresh_install: 9/9 + 8/8 pass (091552, 091909)
- [ ] Mock (layout only)
