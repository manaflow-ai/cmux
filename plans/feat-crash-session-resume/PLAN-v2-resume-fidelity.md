# fix: Agent-first crash/update recovery — trustworthy window↔session binding + self-recovery breadcrumb

**Target repo:** cmux (`manaflow-ai/cmux`)
**Branch:** `feat/crash-session-resume` (builds on v1 units U1–U8 already committed)
**Grounded against:** three live force-quit / "can you resume?" tests on 2026-06-24 (this session) + v1 codebase recon. File references favor path + symbol over line numbers.
**Plan type:** fix · **Depth:** Deep · **Created:** 2026-06-24

This is the **v2 follow-up** to `PLAN.md`. v1 built detection, settings, breadcrumb builder, planner, coordinator, offer, and update-preservation (53 unit tests, all green). Live testing showed v1 solved the wrong half. This plan re-centers on the real defect with an **agent-first** approach that is deliberately distinct from other parallel-agent IDEs (see Differentiation & Non-Goals). U-IDs continue from v1 (which used U1–U8); this plan owns **U9–U14**.

---

## Summary

Three live "what was going on in this window, can you resume?" tests all failed the same way:

1. A window labeled **"Fix order-to-go CLI"** was actually a *fresh* window in the wrong cwd; the real ordertogo work was a different session.
2. A window resumed with **only a SessionStart summary** — no transcript — and reconstructed a `/last30days` run it wasn't sure was its own.
3. A window confidently presented the **x-money-research** session as "what this window was doing" — a session it had no way of knowing was its own. It grepped every transcript and picked the most plausible one.

The root cause is not detection, the offer, or the breadcrumb: **cmux has no trustworthy binding from a restored window to its actual agent session/transcript.** Names get mis-attributed; restored agents come up fresh (cmux builds `claude --resume <id>` but it does not reliably rehydrate the transcript); and when asked to recover, the agent — which is genuinely *excellent* at forensic reconstruction from on-disk transcripts — has no anchor for *which* transcript is its own, so it guesses, and is often wrong.

This plan: (1) makes the window↔session binding **durable and verifiable** (plain correctness); (2) leans into cmux's distinctive strength — **agent-first self-recovery**, handing the agent *its own verified transcript* plus the human breadcrumb so the agent reconstructs and continues; (3) when the binding can't be verified, the agent is told **honestly** and does *bounded* recovery for this cwd (never a silent wrong-guess, never a session-browser); (4) fixes the mis-attributed name anchor; (5) keeps the v1 crash + "Update & reload all windows" framing; (6) re-validates live with a hard acceptance bar — a window recovers **its own** work.

---

## Differentiation & Non-Goals

cmux's recovery is **agent-first**: it equips the agent to reconstruct and continue its own work, gated on crash/update, anchored on the window name and the verified transcript. This is intentionally different from the session-management approach other parallel-agent IDEs take.

**Non-goals (explicitly not building):**
- **No session-search-and-resume browser.** cmux does not add a UI to search across past agent sessions and pick one to relaunch. Recovery is per-window and agent-driven.
- **No hibernation/idle-stop-and-relaunch feature.** This plan is about *crash and intentional-update* recovery, not idle lifecycle management.
- **No mechanical "relaunch provider session with the same flags" as the headline.** cmux already auto-resumes; the differentiated value here is the *agent-first breadcrumb reconstruction* layered on top, not the relaunch itself.

The trustworthy binding (U9/U10) is ordinary correctness every tool needs — it is not a borrowed concept. The differentiated surface is the breadcrumb-driven, agent-led recovery (U11/U12) and the crash/update framing (v1 U5/U8).

---

## Problem Frame

**Two layers of memory, and the binding between them is broken:**

- **The window summary/name** — cmux's auto-generated sidebar label. cmux has this, but it is mis-attributed across restores (Example 1).
- **The agent transcript** — the real context, on disk at `~/.claude/projects/<slug>/<sessionId>.jsonl` for Claude (Codex via the session index). Rehydrated only by `claude --resume <correct-id>`; in practice the restored window comes up fresh + a SessionStart summary (Examples 2, 3).

The defect is the **missing trustworthy edge** between a restored window/panel and its session id + transcript path. Without it: `--resume` targets the wrong/no session; the name labels the wrong work; and forensic recovery (a real strength — the agent found the right files, cwd, and stall point when it had an anchor, Example 1) degrades to confident guessing when it has none (Example 3).

The user's framing is the spec: *"each of these windows knows how to resume? I doubt it. It knows what each window was before?"* cmux must know, per window, **which session is yours**, and prove it before acting — and where it can't prove it, say so rather than guess.

**Who is affected:** cmux users recovering many agent windows after a crash or an update relaunch. A confident wrong recovery (Example 3) is worse than an honest "I couldn't verify this window's session — here's what I can reconstruct for this folder."

---

## Requirements

- **R12** — cmux persists a durable, per-window/per-panel binding to its agent session: session id, transcript path (when knowable), agent kind, cwd, and originating workspace/panel identity — written when the session is established (agent-hook) and survived across relaunch.
- **R13** — On restore, the binding is **verified** before use: the session id resolves to a real on-disk transcript whose recorded cwd/workspace matches this window. A binding that fails verification is treated as *unverified*, never silently trusted.
- **R14** — When the binding verifies, resume that exact session and proceed to the breadcrumb. When it does **not** verify, the agent is given an **honest, bounded** recovery prompt scoped to this window's cwd (what cmux can and cannot confirm) — it never silently presents a guessed session as fact, and cmux does not add a cross-session search/picker UI.
- **R15** — The breadcrumb / "pick up where we left off" nudge fires only after a verified binding, and hands the agent the specific verified transcript + window summary so it reconstructs from the right source. Suppressed for unverified/fresh windows (no confident nudge to a context-less agent).
- **R16** — The restored window's name reflects its **verified** work; an unverified window does not wear another session's name.
- **R17** — Two delivery surfaces share one path (decision "Both"): silent auto-resume + breadcrumb on a verified binding by default; an opt-in crash offer (v1 U5) for users who want to be asked. Neither is a session-search browser.
- **R18** — Re-validation acceptance bar: after a force-quit, a restored window recovers **its own** prior work (continues the specific task, or correctly identifies it from the verified transcript) — demonstrably not a guessed/mis-attributed session, and not a filesystem meander.

---

## Key Technical Decisions

**KTD9 — Make the window↔session binding durable and per-panel (the root fix).** Persist, per panel, the agent session id + transcript path + cwd + originating workspace/panel id at session-establish time (the Claude `SessionStart` hook → `cmux hooks claude session-start` in `CLI/cmux.swift` already captures session metadata; extend it to record the transcript path and assert workspace/panel identity), and reload it on restore. *Rationale:* every downstream failure (wrong name, fresh agent, guessing) traces to this missing edge. *Alternative rejected:* keep inferring the mapping heuristically at restore — that is what mis-attributes (Examples 1, 3). *Coordinate with #6631* (agent-session source-of-truth), which is consolidating this mapping — extend its store, don't fork one.

**KTD10 — Verify before trusting.** On restore, confirm the bound session id resolves to a real transcript (`~/.claude/projects/<slug>/<id>.jsonl`; Codex via `Sources/SessionIndexStore.swift`) AND the transcript's recorded cwd/workspace matches this window. Only a passing binding is "verified." *Rationale:* R13; the live failures were all unverified trust. *Reuse:* extends v1's fidelity gate with transcript-existence + cwd-match checks.

**KTD11 — Agent-first recovery, not a session browser (the differentiated surface).** When verified, hand the agent the breadcrumb + its own transcript and let it continue. When unverified, give the agent an **honest, cwd-scoped** prompt — "I couldn't verify this window's prior session; based on this folder, here's what I can see — reconstruct only if confident, otherwise ask" — so the *agent* does bounded recovery rather than cmux silently guessing or surfacing a cross-session picker. *Rationale:* R14; leans on the proven agent strength (Example 1) while killing the confident-wrong failure (Example 3); stays distinct from search-and-resume tooling. *Alternative rejected:* a session-search/picker UI (a non-goal; competitor-adjacent and not agent-first).

**KTD12 — Point forensic recovery at the verified transcript.** When `--resume` can't fully rehydrate, the breadcrumb names the **specific** verified transcript path and asks the agent to reconstruct from *that file* — not "go find what you were doing." *Rationale:* converts Examples 2/3's open-ended search into a bounded, correct one; turns the agent's strength into a reliable path.

**KTD13 — Breadcrumb is gated and anchored, secondary to the binding.** The nudge fires only post-verification and names the verified work (summary + transcript). For unverified windows it does not fire. *Rationale:* R15; nudging a fresh agent produces confident garbage.

**KTD14 — Fix the name anchor.** Persist the `.auto` summary with its binding and re-apply it only to the verified window; an unverified window shows a neutral name, never another session's. Never overwrite a user-set (`.user`) title. *Rationale:* R16; Example 1's mis-attribution.

**KTD15 — Two surfaces, one path (decision "Both").** Default silent auto-resume+breadcrumb on a verified binding; opt-in crash offer (v1 U5) for users who want to be asked. Both route through one coordinator (v1 `WorkspaceResumeCoordinator`); neither is a session-search browser. *Rationale:* R17; cmux-shared-behavior.

---

## High-Level Technical Design

The corrected restore decision — binding first, honest when unsure, never a silent guess:

```mermaid
flowchart TD
    A[Relaunch after unclean shutdown / update] --> B[Restore windows/panels]
    B --> C[Load persisted window↔session binding  U9]
    C --> D{Binding present\nfor this panel?}
    D -- yes --> V{Verify: transcript exists\n+ cwd/workspace match  U10}
    D -- no --> H[Honest cwd-scoped recovery prompt\n(agent-first, bounded)  U11]
    V -- passes --> R[Resume correct session\nclaude --resume <id>  U11]
    V -- fails --> H
    R --> BC[Breadcrumb anchored on\nverified summary + transcript path  U12/U13]
    BC --> DONE[Window recovers ITS OWN work\n(acceptance R18)]
    H --> AGENT[Agent reconstructs only if confident,\nelse asks — no silent guess, no picker]
```

Two-layer memory and the binding that connects them:

```mermaid
flowchart LR
    Win[Restored window/panel] -->|durable binding U9| Sess[session id + transcript path + cwd]
    Sess -->|verify U10| OK[verified: resume + breadcrumb here]
    Sess -->|unverified| Honest[agent-first honest recovery U11\n(not a guess, not a browser)]
    Win --> Name[summary/name — only if verified U13/U14]
```

---

## Implementation Units

### U9. Durable window↔session binding
- **Goal:** Persist and restore a trustworthy per-panel binding to the agent session (id, transcript path, cwd, workspace/panel identity).
- **Requirements:** R12.
- **Dependencies:** v1 U1–U8.
- **Files:** `CLI/cmux.swift` (the `session-start` hook handler — extend the recorded record with transcript path + asserted workspace/panel id); `Sources/RestorableAgentSession.swift` (`SessionRestorableAgentSnapshot`, hook session record); `Sources/SessionIndexStore.swift` (session index keys); `cmuxTests/WindowSessionBindingTests.swift` (new).
- **Approach:** At session-establish (agent hook), capture the transcript path alongside the existing sessionId/cwd/workspace/panel and persist it so restore looks up "this panel's session" deterministically rather than inferring. On restore, load the binding per restored panel. Prefer extending #6631's store over a parallel one. **Concrete root cause to fix (live evidence):** in a real 20-window pre-crash snapshot, only 3 windows had a session ID captured — the rest were `[no agent]` because the `SessionStart` hook never recorded a session ID for that pane ("hooks setup not fully active across all panes"). So U9 must make hook capture reliable for *every* agent pane (investigate why the hook fails to fire/record on some panes — install coverage, timing, or per-pane env), not just persist what's already captured. Windows with no captured session fall to U11's cwd+timestamp recovery.
- **Patterns to follow:** existing hook record (`RestorableAgentHookSessionRecord`) and `publishAgentSurfaceResumeBinding` in `CLI/cmux.swift`; `SessionIndexStore` keying.
- **Test scenarios:**
  - A session established in panel P records a binding with the correct sessionId, cwd, and panel identity. `Covers R12.`
  - Binding round-trips across persist→reload.
  - Two concurrent agent panels record distinct, non-crossed bindings (anti-Example-1).
  - A panel with no agent records no binding.
- **Verification:** Unit tests green; on restore each panel resolves to its own session id, not a neighbor's.

### U10. Binding verification gate
- **Goal:** Confirm a binding points at a real transcript whose cwd/workspace matches this window before trusting it.
- **Requirements:** R13.
- **Dependencies:** U9.
- **Files:** `Sources/CrashRecovery/ResumeFidelityGate.swift` (new); reads transcript locations (`~/.claude/projects/<slug>/<id>.jsonl`, Codex via `Sources/SessionIndexStore.swift`); `cmuxTests/ResumeFidelityGateTests.swift` (new).
- **Approach:** Verify (a) sessionId non-empty + resumeCommand constructable, (b) transcript exists for that id, (c) the transcript's recorded cwd/workspace matches this window, (d) agent kind supported (Claude/Codex v1). Return a typed reason on failure (`.noBinding`, `.transcriptMissing`, `.cwdMismatch`, `.unsupportedAgent`). Pure decision over a small input struct; filesystem/index lookups are a thin adapter.
- **Patterns to follow:** v1 `WorkspaceResumePlanner` (pure decision + thin glue); v1 `SkipReason`.
- **Test scenarios:**
  - Verified binding (transcript exists, cwd matches) → proven.
  - Binding id with no transcript on disk → `.transcriptMissing`, unverified. `Covers R13.`
  - Transcript exists but cwd/workspace mismatches → `.cwdMismatch` (anti-Example-3).
  - Unsupported agent → `.unsupportedAgent`.
- **Verification:** Unit matrix green; live, a fresh/mis-mapped window fails verification.

### U11. Agent-first recovery routing (verified resume vs honest bounded recovery)
- **Goal:** Route a verified binding to resume+breadcrumb; route an unverified one to an honest, cwd-scoped agent recovery prompt — never a silent guess, never a session-search UI.
- **Requirements:** R14, R17.
- **Dependencies:** U9, U10; v1 U4 (coordinator), U5 (offer).
- **Files:** `Sources/CrashRecovery/RecoveryRouter.swift` (new — decide verified-resume vs honest-recovery); `Sources/CrashRecovery/ResumeBreadcrumbBuilder.swift` (extend for the honest/unverified variant); `Sources/Workspace.swift` (auto-resume launch path); `Sources/CrashRecovery/CrashRecoveryOffer.swift` (v1 offer stays a yes/no, not a picker); `cmuxTests/RecoveryRouterTests.swift` (new).
- **Approach:** Verified → relaunch `claude --resume <id>` (existing same-flag construction) + breadcrumb (U12). Unverified → deliver an honest prompt scoped to this window's cwd: state what's unconfirmed, let the agent reconstruct *only if confident* from what's visibly in this folder, else ask the user. No cross-session enumeration/picker. The default silent path only auto-resumes a verified binding; the opt-in offer is a yes/no, not a browser.
- **Patterns to follow:** v1 offer presenter and coordinator; the agent's own bounded forensic recovery (Example 1) as the target shape.
- **Test scenarios:**
  - Verified binding → resumes that exact session + breadcrumb, no prompt-to-reconstruct. `Covers R14.`
  - Unverified → honest cwd-scoped recovery prompt emitted; contains no fabricated session claim.
  - Default silent path never auto-resumes an unverified binding.
  - Offer surface remains yes/no (no session list). `Covers R17.`
- **Verification:** Unit tests green; live, a clean binding auto-resumes; an ambiguous one yields an honest prompt, not a wrong guess.

### U12. Forensic-recovery breadcrumb pointed at the verified transcript
- **Goal:** Hand the agent its specific verified transcript and ask it to reconstruct from that file — bounded, not open-ended.
- **Requirements:** R15.
- **Dependencies:** U10, U11; v1 U3 (breadcrumb builder).
- **Files:** `Sources/CrashRecovery/ResumeBreadcrumbBuilder.swift` (extend to take a verified transcript path/anchor); `cmuxTests/ResumeBreadcrumbAnchorTests.swift` (extend v1 builder tests).
- **Approach:** Breadcrumb references the verified summary AND, when available, the exact transcript path: "We were working on '<verified summary>' — your prior transcript is at <path>; review it and continue." Suppressed when unverified (R15). Reuses v1 sanitization (single-line, safe injection).
- **Patterns to follow:** v1 breadcrumb builder + sanitizer; Example 1's bounded recovery as the target.
- **Test scenarios:**
  - Verified binding with transcript path → breadcrumb names summary + path, single-line, sanitized.
  - Verified binding, no path → summary-only nudge.
  - Unverified → no breadcrumb produced. `Covers R15.`
  - Hostile/empty summary → safe fallback (reuse v1 sanitizer tests).
- **Verification:** Unit tests green; live, the resumed agent reconstructs from the named transcript.

### U13. Name-anchor fidelity on restore
- **Goal:** The restored window's name reflects its verified work; an unverified window does not inherit another session's name.
- **Requirements:** R16.
- **Dependencies:** U9, U10.
- **Files:** the auto-title persistence/restore path (`Sources/Workspace.swift` `customTitle`/`CustomTitleSource.auto` save+restore; the auto-name hook in `CLI/cmux.swift` / session index); `cmuxTests/RestoredWorkspaceNameFidelityTests.swift` (new).
- **Approach:** Persist the `.auto` summary with its binding; re-apply only to the verified window; investigate and fix where the summary reverts to "Claude Code" on restore; an unverified window shows a neutral name. Never overwrite a `.user` title.
- **Patterns to follow:** `CustomTitleSource` provenance rules (auto must not clobber user).
- **Test scenarios:**
  - Verified window keeps its real summary across restore (round-trip). `Covers R16.`
  - Unverified window does not display another session's summary (anti-Example-1).
  - User-set title preserved.
- **Verification:** Unit tests green; live, windows keep (or don't falsely claim) the right name.

### U14. Live re-validation harness + acceptance
- **Goal:** A repeatable, safe test proving a restored window recovers *its own* work — not a guess, not a meander.
- **Requirements:** R18.
- **Dependencies:** U9–U13.
- **Files:** `scripts/crash-recovery-e2e.sh` (new, tag-bound; refuses to act on the main-app PID); acceptance notes under `plans/feat-crash-session-resume/`.
- **Approach:** Script the safe cycle proven this session: tagged `reload.sh` build, launch isolated instance, start a real agent with a known task in a known cwd, confirm the binding records correctly, force-quit ONLY the tagged PID (guard against the main app), relaunch, and assert: (1) the binding verifies to the *same* session, (2) resume targets it, (3) the agent recovers the *specific* task, (4) an intentionally-broken binding yields the honest recovery prompt (no wrong-guess). Document bundle-isolated snapshot + shared-sentinel caveats.
- **Patterns to follow:** this session's live procedure (tagged build isolation, `CMUX_TAG` debug CLI, path-matched `kill -9`, bundle-isolated `session-<bundleid>.json`); cmux `CLAUDE.md` tagged-build rules.
- **Test scenarios:**
  - Clean single crash, correct binding → window recovers its own task; name correct. `Covers R18.`
  - Corrupted/missing binding → honest recovery prompt, no wrong-session guess. `Covers R14, R18.`
  - Two agent windows → each recovers its own session, no cross-bleed. `Covers R12.`
  - Guard: script aborts if the resolved PID is the main app.
- **Verification:** Running the script reproduces the acceptance result; main app never touched.
- **Execution note:** Validated by live run, not unit tests; record evidence (screenshots/transcripts) alongside the plan.

---

## Risks & Dependencies

- **The binding is the whole ballgame (high).** If U9/U10 don't produce a trustworthy, verified edge, everything downstream guesses. *Mitigation:* verification gate with transcript-existence + cwd-match; live two-window anti-cross-bleed test.
- **Overlap with #6631 (high).** The agent-session source-of-truth PR is consolidating this mapping. *Mitigation:* extend its store; rebase on it; coordinate before landing.
- **Differentiation discipline (medium).** Keep the surface agent-first; do not drift into a session-search/hibernation UI. *Mitigation:* Differentiation & Non-Goals section; the offer stays yes/no; unverified path is an agent prompt, not a picker.
- **`--resume` not rehydrating even with the right id (medium).** Live evidence shows restored windows came up fresh despite a constructed `--resume`. *Mitigation:* U14 confirms rehydration end-to-end; if `--resume` is unreliable, U12's transcript-pointed forensic recovery is the fallback that still works.
- **Transcript location assumptions (medium).** Claude `~/.claude/projects/<slug>/<id>.jsonl` and Codex `~/.codex/state_5.sqlite` are external contracts that can drift. *Mitigation:* go through `SessionIndexStore`, not hardcoded paths; degrade to the honest recovery prompt when a transcript can't be located.
- **Confident-wrong is worse than honest-unsure (design constraint).** Never present a guessed session as fact. *Mitigation:* R14/R15 gating; acceptance test checks the broken-binding path is honest.

---

## Open Questions (resolve at implementation)

- Does #6631 already persist the transcript path / window identity, or must U9 add it? Land order with #6631.
- Why does a constructed `claude --resume <id>` come up fresh in restored windows (Examples 2/3)? Id correct-but-unresolved, cwd mismatch, or the `restoredBindingLaunch != nil` branch in `Sources/Workspace.swift` suppressing the `--resume` path? U10/U14 must pin this empirically.
- Exact wording of the honest unverified-recovery prompt so the agent reconstructs only when genuinely confident (avoid both meander and over-caution).
- Where the `.auto` summary is dropped on restore (snapshot save vs re-apply vs hook re-run) — U13's first task.
- Whether the breadcrumb always includes the transcript path or only when `--resume` rehydration is detected as incomplete.

---

## Sources & Research

- **Three live "can you resume?" tests, 2026-06-24 (this session), all on an isolated tagged build (main app never touched):**
  - Example 1 — a window named "Fix order-to-go CLI" was a *fresh* window in `~/Users/mvanhorn`; the real work (`59a03572`, ordertogo CLI fix) lived in a different session/cwd. The agent self-recovered it correctly *once it found the right transcript* (cwd, edited files, U4 stall point) — proving forensic recovery works when anchored.
  - Example 2 — a restored window had "only the SessionStart summary," not the transcript; reconstructed a `/last30days` run it wasn't sure was its own.
  - Example 3 — a window confidently presented the `x-money-research` session (`c5258277`) as "what this window was doing" after grepping all transcripts — a wrong-session guess. Confident-wrong is the core failure mode this plan kills.
- **cmux current-resume mechanism (Explore, this session):** `Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentResumeArgv.swift` constructs `claude --resume <sessionId>`; `Sources/Workspace.swift` `restoredAgentResumeLaunch` issues it via `RestorableAgentSession.resumeStartupCommand`; a `restoredBindingLaunch != nil` branch can suppress the `--resume` path; the `SessionStart` hook (`CLI/cmux.swift`) records session metadata but does not inject the transcript. Net: cmux *attempts* full resume but restored windows empirically come up fresh — the binding/rehydration is unreliable.
- **v1 plan + commits:** `plans/feat-crash-session-resume/PLAN.md`; v1 units U1–U8 on `feat/crash-session-resume` (sentinel, settings, breadcrumb builder, planner, coordinator, offer, update-preservation, restore-forcing), 53 passing unit tests.
- **cmux internals + constraints:** `Sources/SessionIndexStore.swift` (SQLite session index, Codex `state_5.sqlite`), `Sources/RestorableAgentSession.swift` (`SessionRestorableAgentSnapshot`: kind/sessionId/resumeCommand), `Sources/App/WorkspaceRuntimeSettings.swift` (`AgentSessionAutoResumeSettings`, default true). Localization EN+JA, pbxproj test wiring, tagged-build isolation, two-commit red/green per cmux `CLAUDE.md`.

*Competitive note: a parallel-agent IDE in this space offers session-search-and-resume and agent hibernation. This plan deliberately does not replicate those surfaces (see Differentiation & Non-Goals); cmux's recovery is agent-first and crash/update-gated.*
