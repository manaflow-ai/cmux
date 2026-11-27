# 2026-11-24-compile-status-down-superseded

Above `if tip_moved; then` in compile-status's results-service-down branch in `.github/workflows/cmux-next.yml`.

A feat-cmux-next push the preflight found superseded runs compile-status with `FALLBACK` false, and the overflow
compile takes only pull request heads, so a results service down (two probes 30 s apart, note-82) posted
`[no-verdict] No compile verdict: ...` and failed the job. 2026-11-24 14:50:07-14:51:04Z a short outage (HTTP 000)
failed this job on five such pushes (runs 45418126100, 45417851496, 45415706123, 45415677478, 45415444543), each a
base red on NOW. Now that branch reads the branch head once (tip_moved, note-554) before failing: a head that moved on
posts `[no-verdict] [superseded] Results service down ...` (still no verdict to base_red_excuse.py) and ends green,
because the newer tip's check (with its Mac fallback) covers the commit. A head that has not moved, that cannot be
read, or a run with the gate off fails as before. Undo: vars.CMUX_NEXT_SUPERSEDED_COMPILE_GATE = '0'.
