# Pivot — position this branch as the recovery layer on top of #6741 + #6631

**Date:** 2026-06-24 · **Trigger:** maintainers are actively shipping the binding
fixes this branch's v2 plan assumed it would build. CEO Austin Wang publicly
confirmed 0.64.17 "should fix the auto-resume issues." Branch is current with
upstream (base `v0.64.16-356-g`, MARKETING_VERSION 0.64.17).

The branch is re-scoped from "fix the window↔session binding" to "the agent-first
**recovery decision layer** that sits on top of the maintainers' binding work."

## Division of labor (the boundary)

| Concern | Owner | Notes |
|---|---|---|
| Claude auto-resume binding **cwd-correctness** (`claude --resume` finds the transcript) | **PR #6741** (open) | Adds shared `ClaudeResumeWorkingDirectory.verifiedWorkingDirectory(...)` + `ClaudeProjectDirEncoding` in `CMUXAgentLaunch`: recovers the launch cwd from the transcript's top-level `cwd` and accepts it only when it re-encodes to the transcript's project dir (no lossy decode). Touches `CLI/cmux.swift`, `Sources/RestorableAgentSession.swift`. |
| Authoritative per-session **tracking store** (versioned records, deterministic `ended`, off-main parsing) | **PR #6631** (open) | Single source of truth for "does this terminal have an agent session." Mostly iOS GUI, but the registry chokepoint is the SoT to extend, not fork. |
| **Recovery decision on top of a correct binding** | **THIS BRANCH** | Verify-trust gate, agent-first honest recovery, transcript-anchored breadcrumb, restored-name fidelity. Neither PR builds these. |

## What this branch keeps (no overlap with #6741/#6631)

All committed, unit-tested, purely additive (new `Sources/CrashRecovery/` files only):

- **U10 `ResumeFidelityGate`** — the trust decision *on top of* a binding: is it
  safe to drive `--resume` + the breadcrumb, or fall to honest recovery? Reframed:
  it does NOT re-derive the cwd (that's #6741). It consumes the resolved facts and
  decides verified vs. unverified.
- **U11 `RecoveryRouter` + `recover()` seam** — agent-first: verified → resume +
  anchored breadcrumb; unverified → honest cwd-scoped prompt (no guess, no picker).
  Neither PR adds a recovery prompt.
- **U12 transcript-anchored breadcrumb** — once #6741 makes `--resume` rehydrate,
  the breadcrumb names the verified transcript so reconstruction is bounded.
- **U13 `RestoredNameResolver`** — window-name fidelity on restore (`.user` kept,
  `.auto` only if verified, else neutral). Orthogonal to both PRs.
- **U14 harness** — `scripts/crash-recovery-e2e.sh`, tag-bound, main-app-PID guard.

## What this branch DROPS (now owned upstream)

- **U9 "fix the binding / hook cwd-correctness"** → owned by #6741 (cwd) and #6631
  (session tracking). This branch no longer tries to fix where the binding points
  or whether the hook fired. The gate simply treats a missing/untrustworthy
  binding as unverified → honest recovery (already implemented). The
  `WindowSessionBindingTests` stay as a *consumption* contract (a panel's facts
  are its own), not a binding-capture fix.
- **Re-deriving the resume cwd / a hand-rolled transcript-existence FS check** →
  the live adapter must consume #6741's `ClaudeResumeWorkingDirectory`
  /`ClaudeProjectDirEncoding` instead.

## Live wiring, after #6741 + #6631 land

1. Rebase onto merged #6741 + #6631.
2. Real `Workspace` overrides the `ResumableWorkspaceSurface` verification facts:
   - `transcriptExistsAtWindowCwd` / `transcriptExistsElsewhere` ← compute via
     #6741's `ClaudeResumeWorkingDirectory.verifiedWorkingDirectory(...)` /
     `ClaudeProjectDirEncoding` (matches a candidate cwd to the transcript's
     project dir), NOT a bespoke FS walk.
   - `resumeTranscriptPath` ← the hook payload's `transcript_path` (already
     persisted on `ClaudeHookSessionRecord`).
   - Session id ← the **bare** id from #6631's session record, not the resume
     command string (see U14-acceptance.md adapter must-dos).
3. Call `coordinator.recover()` from the silent restore path (`Workspace.swift`
   ~1249) so a verified binding resumes + breadcrumbs and an unverified one gets
   honest recovery.
4. Run `scripts/crash-recovery-e2e.sh` to validate R18.

Until then the conservative protocol defaults route every real restore to honest
recovery (safe: never a wrong resume), so nothing regresses while the upstream
PRs settle.

## Coordination

Keep the differentiation discipline: this is agent-first, crash/update-gated
recovery — not session-search/hibernation (see the plan's Differentiation &
Non-Goals; never name competitor IDEs in shipped artifacts). Coordinate with the
#6741/#6631 authors before landing so the layer composes with the final APIs.
