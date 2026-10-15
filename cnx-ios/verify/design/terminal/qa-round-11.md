# Terminal QA round 11 (termqa implementer, 2026-10-15 04:20 PT onward)

Input: qa-round-10.md (`b763a1a5`) and VERIFY-round8.md (`origin/feat-cnx-ios-termverify8` `e0789e41`).
`origin/feat-cnx-ios` was already merged (`b763a1a5` = its head). Laptop load 50-140 at the start: no
timing claims.

Code fixes for coordinator items 2, 5, 6, 7a (rendering) and 3, 4, 7b (tabs) run in two sibling
worktrees/branches, `feat-cnx-ios-termqa-render` and `feat-cnx-ios-termqa-tabs`, merged here when done.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| 1. T-LIFE-09/15 fix `60dc5462` on the rig | in progress | |
| 2. One-frame black at Jump to bottom / prune | in progress (render branch) | |
| 3. V5-5 / T-TABS-08 close ends the Mac session | in progress (tabs branch) | |
| 4. T-TABS-01 inactive card stale | in progress (tabs branch) | |
| 5. ~15 s saved-frame hitch | in progress (render branch) | |
| 6. Frame-log `blank` over-reports | in progress (render branch) | |
| 7. Polish: cursor glyph in the saved frame; "WireGuard TURN" label | in progress | |
| 8. Simulator checks (G-14, T-SEL x10, selection colour, clear) | not started | |
| 9. G-17 re-runs (1350-a/b, 1259 real Codex) | not started | |
| 10. V6-5, D10, V2-6, 60-min sessions, D7 | not started | |

## Rig

- Shared rig: `cnx-e2e-604fc689` on mini-2, simulator `cnx-termqa-1` (C906E217…). Shut down and booted
  headless at the start (the verifier's taps had timed out). The verifier's GEN loop in e2e-t2 had
  already ended (`GEN-60000`, prompt).
- Tools: `verify/termqa/q11.py` (the verifier's `v8v.py` wrapper, evidence to `qa11/`, raw video to
  `~/cnx-ios-e2e/termqa-raw/tq11/`; `q11.py install APP` installs a tagged build, launches it with
  `-CnxFrameLog YES` and opens e2e-t2). The verifier's `v8v_*.py` tools are taken as is.
- Phone builds: `~/cnx-ios-e2e/impl11/<sha>/CnxApp.app`, tag tq10 (`dev.cmux.cnx.tq10`), selected with
  `TQ_BUNDLE=dev.cmux.cnx.tq10`.
