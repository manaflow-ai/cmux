# Terminal and tabs: round 4 designer review (in progress)

Fresh designer, 2026-10-14. Build under review: `origin/feat-cnx-ios` at `ddc58d86`.

## Checklist

- [ ] R3-1 pull-down with keyboard up, plain shell (scrolls above keyboard; drag into keyboard dismisses on prompt)
- [ ] R3-1 pull-down with keyboard up, after a TUI
- [ ] R3-2 no black frame keyboard show/hide over `top`; judge ~1.5 s old 24 rows after hide
- [ ] R3-3 Files and Links: no wrapped fragments incl. scrollback
- [ ] R3-4 relaunch handoff cut (no blend), stale cursor block
- [ ] R3-5 key bar spacing after swipe (no end hole)
- [x] R1-0 relaunch restore: rig PASS (restored 1.5 s, attached 3.3 s)
- [x] Rig steps: 100712 8/9 (last_tab_restore FAIL: rig queries suffix 'e2e-t2' but card label is now 'e2e-t2, tab'; manual check PASS), 100918 9/10 (same) -> 17/19, 18/19 counting manual
- [ ] Onboarding "Connect your Mac" Continue tap investigation
