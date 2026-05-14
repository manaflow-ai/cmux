# Chromium engine — per-session handoff ledger

Read this first when starting any session on `feat-chromium-engine`. Append a new entry at the bottom of "Session log" before exiting. The "Next steps" block at the top is authoritative; update it when you finish a step.

## Next steps (always current)

- [ ] Get plan PR reviewed and approved (or at least eyes on it) so cost/scope is acknowledged.
- [ ] On `cmux-aws-mac`: rename `disk3s4` to `Chromium` and document the remount procedure (`diskutil mount /dev/disk3s4`, target `/Volumes/Chromium`). Add to `scripts/` if cmuxterm-hq's `scripts/` is the right home, or to a build-host-local doc.
- [ ] Install `depot_tools` on the persistent volume at `<persistent>/depot_tools`. Export `PATH` in `~/.zshrc`.
- [ ] Kick off `fetch chromium` in a `Bash run_in_background` with a Monitor armed for `.gclient_entries` appearance and process exit. Expect 4–12 hours.
- [ ] After fetch: pick a Chromium release branch to track (recommend latest stable when work starts; record the commit SHA in this doc).
- [ ] First clean `chrome` build (target: full release build under 3 hours on M1 Ultra).

## Active milestone

**P0 — Build host and toolchain.** All P1+ items are blocked on P0.

## Build host state

- Host: `cmux-aws-mac` (M1 Ultra, 20 cores, 128 GB RAM, macOS 15.7.4, Xcode 26.3).
- Persistent volume: `disk3s4`, 994 GB total / 972 GB free, currently mounted at `/private/tmp/tmp-mount-TOmSsz`.
- Risk: that mount point is a non-standard path; the volume is persistent but the mount may not auto-recreate after reboot. Confirm `diskutil mount disk3s4` works on a reboot before relying on it.
- depot_tools: not installed yet.
- Chromium checkout: not started.

## Open blockers

None as of session 0.

## Open PRs

- Draft PR (to be opened in session 0): plan-only, `feat-chromium-engine` → `main`.

## Useful commands

- Re-enter worktree: `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-chromium-engine`
- SSH to build host: `ssh cmux-aws-mac`
- Check build-host disk: `ssh cmux-aws-mac 'df -h /private/tmp/tmp-mount-TOmSsz'`
- Read this ledger: `cat plans/chromium-engine-handoff.md`

## Session log

### Session 0 — 2026-05-14

- Verified `cmux-aws-mac` reachable, specs (M1 Ultra, 128 GB, Xcode 26.3).
- Identified persistent storage candidate (`disk3s4`, 972 GB free).
- Created worktree `feat-chromium-engine` off `origin/main` at `791318f5a`.
- Drafted `plans/chromium-engine.md` (this directory) with architecture, milestones, cost, risk register.
- Drafted this handoff ledger.
- **Did not** install depot_tools, **did not** fetch Chromium. Decision: wait for plan PR review before spending fetch hours.
- Next session: see "Next steps" above.
