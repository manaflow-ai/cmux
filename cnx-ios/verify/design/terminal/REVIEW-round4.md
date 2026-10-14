# Terminal and tabs: round 4 designer review (in progress)

Fresh designer, 2026-10-14. Build under review: `origin/feat-cnx-ios` at `ddc58d86`.

## Checklist

- [x] R3-1 plain shell: PASS (01, v1): 250 pt pull 59-80 -> 33-57 -> 5-29; drag into keyboard dismissed, prompt on composer
- [x] R3-1 after top: PASS (02): prompt above composer after q; one pull reaches rows 1-24
- [x] R3-2: FAIL (03, 04, v2): hide #1 black 29.33-29.57 s; show #2 black 44.97-45.17 s; hide #2 and show #1 clean
- [x] R3-3: shell scrollback PASS (06): wrapped /private/tmp/... and /tmp/...txt in scrollback listed whole, no pieces; NEW R4-3 minor: TUI (top) rows joined into fake paths 'cnx-r4-wrappePID', 's/private/tmp/cnx-r4'
- [ ] R3-4 relaunch handoff cut (no blend), stale cursor block
- [ ] R3-5 key bar spacing after swipe (no end hole)
- [x] R1-0 relaunch restore: rig PASS (restored 1.5 s, attached 3.3 s)
- [x] Rig steps: 100712 8/9 (last_tab_restore FAIL: rig queries suffix 'e2e-t2' but card label is now 'e2e-t2, tab'; manual check PASS), 100918 9/10 (same) -> 17/19, 18/19 counting manual
- [ ] Onboarding "Connect your Mac" Continue tap investigation
