# Codex Agent Detection Plan

Status: IMPLEMENTED + live-verified (macOS/daemon side). Owner: Aziz. Last
updated: 2026-06-22. Branch `feat-codex-detection`, PR #6655.

Done: `cmux-codex-wrapper` (PATH shim, Claude-parity per-invocation `[hooks]`
injection via `--enable hooks --dangerously-bypass-hook-trust -c hooks.<event>=...`),
codex PATH-shim install sibling to the claude shim, and `WorkstreamEvent` /
`feed.push` surface/transcript metadata. Two preflight-caught bugs fixed:
phantom `fallback-*` duplicate (removed the wrapper-fired empty-stdin launch
signal) and unbound-surface on live session-start. Live debug-socket proof: a
real `codex exec` produced one surface-bound Codex session lifecycle.

## Problem

Codex agents were not reliably detected by cmux's hook/feed path. Empirical root
cause on a real machine (Aziz's, 2026-06-22):

- cmux's Codex hooks (`~/.codex/hooks.json`) are NOT installed.
- Codex has a single legacy `notify` slot, and it is taken by Computer Use:
  `notify = [".../SkyComputerUseClient", "turn-ended"]`. cmux's notify-based
  events cannot fire.
- The 13 "codex" entries in `~/.cmuxterm/codex-hook-sessions.json` are stale,
  not live-updating.

Why Claude works, for contrast: Claude Code has a `SessionStart` hook. cmux's
`cmux-claude-wrapper` is a PATH shim that injects cmux's hooks per-invocation
(`--settings`) and execs the real claude, so `SessionStart` fires the instant a
claude session starts. Transparent, per-launch, nothing written to `~/.claude`,
works for hand-typed `claude`.

## Principle

cmux owns the terminal environment, so it can mediate any agent the user launches
in its terminal, per-invocation, without touching global config. Detection must
depend only on what cmux controls — the wrapper, the injected env, the pid it
parents — never on the agent cooperating. This is the same primitive that makes
Claude reliable, generalized to Codex.

## Design: PATH-shim wrapper that emits its own session-start

A `cmux-codex-wrapper`, mirroring `cmux-claude-wrapper`:

1. cmux prepends a shim dir to `PATH` when it spawns its terminal shells (the
   same mechanism Claude already uses). Typing `codex` resolves to the shim, not
   the real binary.
2. Before exec'ing the real codex, the wrapper emits the launch signal itself:
   `cmux hooks codex session-start` carrying `CMUX_SURFACE_ID`, the cwd, and its
   child pid. THIS is the reliable detection signal, and it needs nothing from
   Codex — the wrapper, which cmux controls, is the source. (More robust than the
   Claude path, where the signal comes from Claude's own hook.)
3. The wrapper execs the real codex (resolved by skipping the shim on `PATH`).
4. Outside cmux (no `CMUX_SURFACE_ID` / socket), the wrapper no-ops and execs the
   real codex, so it is invisible to non-cmux usage.

Session lifecycle, with NO Codex hooks required:

- Presence + terminal binding: from the wrapper's session-start (surface + pid,
  deterministic).
- Transcript: resolve the Codex rollout JSONL the pid is writing, anchored to the
  pid (the process's open file descriptors, or a launch-time-bounded match
  confirmed against the pid). This is an identity, NOT the deleted "newest jsonl
  by mtime in the cwd" guess. Then tail it.
- State (working / idle): derived from the transcript tail. A rollout transcript
  parser needs to be rebuilt; the previous `CodexTranscriptParser` was removed
  with the mobile chat pipeline.
- ended: the Slice-B `DispatchSourceProcess(.exit)` watcher on the pid.
- Codex's own hooks: optional enhancement for finer / faster state, never a
  requirement.

## The `notify` coexistence wrinkle

This is the only Codex-specific complication, and it is bounded, not fundamental.
Codex has one legacy `notify` slot, frequently already taken (Computer Use). If we
want Codex's own notify events too, do NOT clobber it. Options, simplest first:

- Skip `notify` entirely and rely on transcript-derived state. If the rollout
  covers the states we need, the wrapper's session-start + transcript tail +
  process-exit are sufficient and `notify` is unnecessary.
- Chain: read the user's existing `notify` from `config.toml`; cmux's injected
  notify handler forwards to the original after handling. Decorator pattern,
  preserves Computer Use.
- Use Codex's newer multi-hook system if the current CLI accepts a per-invocation
  config override that adds a hook alongside existing ones (no chaining needed).

## Reliability assessment (honest)

Super reliable:
- Detection of any Codex that cmux launches OR the user types in a cmux terminal.
  Anchored to the wrapper-emitted session-start (surface + pid cmux owns).
- `ended`, via the process-exit watcher.

Bounded edges, acceptable under the no-unreliable-fallback stance (Claude has the
identical limits):
- Deliberate bypass is not caught: absolute path (`/usr/local/bin/codex`), an
  alias/function that skips the shim, `env -i`, a PATH reset, or Codex over ssh on
  a host cmux does not own. Not surfacing a truly-unmediated agent is correct
  behavior, not a bug.
- Fine-grained `needsInput` (Codex paused on an approval/answer) is
  transcript-paced without Codex's own hooks. Reliable IF the rollout records
  approval/needs-input events; coarse if it does not.

## Open questions to verify before building

1. Does a `cmux-claude-wrapper`-style PATH shim already exist, and where is the
   shim dir injected into terminal `PATH`? (Reuse the same machinery for codex.)
2. Does the Codex rollout JSONL expose approval / needs-input events, for reliable
   `needsInput` without Codex hooks?
3. The current Codex CLI per-invocation config surface (`-c` overrides; multi-hook
   support), to decide notify-chaining vs. skip vs. multi-hook.
4. Does cmux's existing Codex launch path (`codex-teams` /
   `upsertCodexSessionStartIfFresh`) emit the same hook/feed metadata as the
   wrapper path?

## Implementation steps

1. Verify the four open questions above.
2. Add `cmux-codex-wrapper` to the same shim dir + PATH injection Claude uses.
3. Wrapper emits `cmux hooks codex session-start` (surface / pid / cwd) before
   exec, and no-ops cleanly outside cmux.
4. pid-anchored Codex transcript resolution (open-fd / launch-bounded), replacing
   any reliance on session-id-from-hook for the typed case.
5. Rebuild rollout parsing that yields working / idle (/ needsInput) from the
   transcript tail (the previous parser was removed with the mobile chat
   pipeline).
6. `notify` coexistence: skip, chain, or multi-hook per Q3.
7. Build + dogfood: type `codex` in a cmux terminal, confirm hook/feed metadata
   is emitted, lifecycle state tracks, and Computer Use's `notify` still
   fires.
