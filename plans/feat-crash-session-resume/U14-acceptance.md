# U14 — Live re-validation acceptance (R18)

Harness: `scripts/crash-recovery-e2e.sh` (tag-bound; refuses to act on the main app).

The acceptance bar (R18): **a restored window recovers its own work** — a verified
binding resumes its exact session and the breadcrumb names the verified
transcript; a binding that cannot be verified yields the honest, cwd-scoped
recovery prompt (no confident wrong guess, no filesystem meander, no session
picker). This is validated by a live run, not unit tests (U14 execution note).

## Safe procedure

All commands operate ONLY on the tagged, bundle-isolated build
(`com.cmuxterm.app.debug.<tag>`), never the user's main cmux. `forcequit` kills
only PIDs whose executable path is under this tag's DerivedData Debug dir.

```bash
TAG=feat-crash-session-resume
# 1. Build + launch the isolated tagged app
scripts/crash-recovery-e2e.sh --tag "$TAG" build
scripts/crash-recovery-e2e.sh --tag "$TAG" launch

# 2. In the tagged app: open >=2 agent windows, give each a DISTINCT known task
#    in a DISTINCT cwd, and let each agent run far enough to record a session
#    (so the SessionStart hook fires and writes a binding).

# 3. Confirm the bindings were captured (U9 coverage check)
scripts/crash-recovery-e2e.sh --tag "$TAG" bindings
#    -> note "with sessionId: N" vs total panels. N should equal the number of
#       agent panels. A shortfall is the U9 hook-coverage defect (see below).

# 4. Simulate a crash and restore
scripts/crash-recovery-e2e.sh --tag "$TAG" relaunch

# 5. Acceptance checks
scripts/crash-recovery-e2e.sh --tag "$TAG" verify
```

## Acceptance checklist (paste results here per run)

- [ ] Verified binding window resumed ITS OWN session; breadcrumb named the
      verified transcript path.
- [ ] Unverified binding window showed the honest cwd-scoped prompt (names no
      session, says reconstruct-only-if-confident-else-ask) — not a wrong guess.
- [ ] Two agent windows each recovered their own session (no cross-bleed).
- [ ] Restored names reflect verified work; no window wears another session's name.
- [ ] Guard: `forcequit` never resolved a main-app PID (`guard-selftest` passes).

## Empirical items this live loop must pin (carried from the plan's Open Questions)

These are the defects the unit-tested brain (U10/U11/U12) cannot prove on its
own; the live loop is where they get fixed and verified:

1. **U9 hook coverage.** In the pre-crash 20-window snapshot only ~3 panels had a
   session id. The `transcriptPath`/`sessionId` fields are already persisted by
   the SessionStart hook (`ClaudeHookSessionRecord` in `CLI/cmux.swift`), so the
   defect is *coverage*: the hook does not fire/record for every agent pane.
   Use `bindings` after step 2 to measure the shortfall, then investigate why the
   hook fails on some panes (install coverage, timing, or per-pane env —
   `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` resolution). Panels with no captured
   session correctly fall to U11's honest recovery.

2. **`--resume` rehydration (Examples 2/3).** Confirm whether a verified
   `claude --resume <id>` actually rehydrates the transcript in a restored
   window, or comes up fresh. If it comes up fresh, U12's transcript-anchored
   breadcrumb is the fallback that still works (it names the file to read).

3. **U13 name revert.** `customTitleSource` already round-trips (`.auto` never
   clobbers `.user`), yet live windows reverted to "Claude Code". Find where the
   `.auto` summary is dropped on restore (snapshot save vs. re-apply vs. hook
   re-run) and fix it so a verified window keeps its real name and an unverified
   one shows a neutral name.

4. **Workspace verification adapter (U11 wiring).** The coordinator's
   `recover()` path is in place and unit-tested via a fake surface; the real
   `Workspace` conformance must override the verification facts
   (`transcriptExistsAtWindowCwd` / `transcriptExistsElsewhere` / `resumeCwd` /
   `resumeTranscriptPath`) with the on-disk transcript lookup and call
   `recover()` from the silent restore path. Until that override lands, the
   conservative protocol defaults route every restore to honest recovery (safe:
   never a wrong resume). This live loop is where the override is validated.
