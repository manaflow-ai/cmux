# cmux-tui user request board

Snapshot: 2026-08-25. Evidence comes from local Codex and Claude session
records. A request stays open until its user-visible behavior has a focused
test or a recorded dogfood result.

| Request | Evidence | Acceptance | State |
| --- | --- | --- | --- |
| Remove stale surface references from `uvx cmux` attach output. | `~/.codex/history.jsonl`, session `019ffdb7-825e-7f81-87b2-2cc81b9e43c7` | Preserve the active surface ID while filtering, publish one revisioned catalog/tree snapshot, then prove attach, switch, reconnect, active removal, and empty-pane behavior use live surface IDs only. | Open, [#10743](https://github.com/manaflow-ai/cmux/pull/10743) needs follow-up |
| Put cmux-tui in the base snapshot. Do not require freestyle PTYs. | `~/.codex/history.jsonl`, session `01a0132d-85cd-7031-94e5-728512bf833a` | Build the base image, install the pinned TUI binary, launch it from the documented command, and verify upgrade and rollback. | Open, infrastructure |
| Simplify relay onboarding commands for Codex and opencode. | `~/.codex/history.jsonl`, session `019fe97c-493a-7172-967e-c24fe087b763` | One copyable command must refresh credentials for both clients, report safe errors, and never print tokens. | Open, product design |
| Define relay as a token provider for GPU and employee organizations. | Same relay onboarding session | Document trust boundaries, tenant ownership, rotation, revocation, and audit events before implementation. | Open, security design |
| Provide encrypted Codex account onboarding through relay/chatmux. | `~/.codex/history.jsonl`, session `019ffd81-0445-7111-93d5-14d1404c548e` | Prove encrypted upload, Azure Postgres persistence, Durable Object outbound verification, cache invalidation, and round-robin selection with failure recovery. | Open, security review |
| Remove replaceable sleeps and runtime clocks from PTY and relay paths. | `~/.codex/history.jsonl`, PR references 9647 and 9682 | Replace timing guesses with signals or injected clocks; add cancellation and timeout tests. | Open |
| Preserve prompt and output order during rapid remote resize. | Claude transcripts `ses_256686860ffejWnBv90WeuMlsR.jsonl` and siblings | Exercise `session.resize -> TIOCSWINSZ -> PTY output` under rapid changes and prove no prompt disappearance or stale size. | Open, behavior proof needed |
| Make attach-or-create idempotent. | UX simplification audit wave 45 | Repeating the command focuses the existing session, and only creates when no matching session exists. | Proposed |
| Add resume-last and direct in-session switching. | UX simplification audit wave 45 | One action restores the last session or switches by stable name without an intermediate menu. | Proposed |
| Use stable human-readable session names with owner and branch metadata. | UX simplification audit wave 45 | Names remain stable across reconnect and disambiguate collisions without hiding machine IDs. | Proposed |
| Add read-only observe mode and bounded reconnect. | UX simplification audit wave 45 | Observe mode cannot write PTY input; reconnect stops at a documented deadline and reports the next action. | Proposed |
| Keep CLI, palette, shortcut, and context-menu actions on one path. | Existing architecture decision in `TECH-DEBT-BOARD.md` | Each entry point invokes the same action and has one behavior test. | In progress |
| Preview sidebar targets before committing selection. | `~/.codex/sessions/2026/08/25/rollout-2026-08-25T03-02-37-01a0385f-30fe-7920-9019-35bbe25039d8.jsonl`, session `01a0385f-30fe-7920-9019-35bbe25039d8` | H/J/K/L or hover previews without committing; Esc restores prior selection; Enter and preview clicks share one focus/selection action. | Open, behavior proof needed |
| Fresh-start topology must be deterministic. | `~/.codex/sessions/2026/08/14/rollout-2026-08-14T15-18-20-01a0025a-cd4e-7100-b313-d1a1bf98a50a.jsonl`, session `01a0025a-cd4e-7100-b313-d1a1bf98a50a` | After a clean daemon start, exactly one session, workspace, screen, and terminal exist; attach/reconnect preserves identity. | Open, dogfood needed |
| Two-rail cloud TUI information architecture. | Sessions `01a0025a-cd4e-7100-b313-d1a1bf98a50a` and `01a0132d-85cd-7031-94e5-728512bf833a` | Machine rail lists local and remote hosts with New VM; workspace rail follows selected machine; reorder persists; cross-device attach works. | Open, product and security design |
| Cross-platform standalone TUI boundary. | `~/.codex/sessions/2026/08/14/rollout-2026-08-14T22-01-23-01a003cb-cc3f-7d82-940f-2eda42c167f7.jsonl`, session `01a003cb-cc3f-7d82-940f-2eda42c167f7` | Core TUI and daemon build and run without the macOS app, with attach/create/session operations on a supported non-macOS target. | Open, platform proof needed |
| Terminal color parity. | Same session `01a003cb-cc3f-7d82-940f-2eda42c167f7` | Compare ANSI palette, truecolor, default colors, OSC overrides, and reconnect against the reference without washed output. | Partial, behavior proof needed |
| Familiar server lifecycle CLI. | `~/.codex/sessions/2026/08/06/rollout-2026-08-06T16-54-11-019fd97f-ab5e-7f12-8f58-7edbf78530f6.jsonl`, session `019fd97f-ab5e-7f12-8f58-7edbf78530f6` | `server start/status/stop/attach` works, help exposes it, stop is idempotent and scoped, and old routes explain compatibility. | Partial, behavior proof needed |

## Wave-48 pattern notes

Official [Tokio channels](https://tokio.rs/tokio/tutorial/channels),
[`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/),
[`select!`](https://docs.rs/tokio/latest/tokio/macro.select.html),
[Ratatui `Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html),
and [Crossterm events](https://docs.rs/crossterm/latest/crossterm/event/enum.Event.html)
support one state-owner task for typed actions, immutable revisioned snapshots
for derived UI state, and sequenced resize claims. They do not support using a
latest-value watcher for ordered PTY bytes or protocol events. Cancellation must
close admission, stop I/O, release ownership, and join or reap children.

## Current simplification rule

Remove a prompt, duplicate state, or separate command when the same intent can
be expressed by one typed action with a stable result. Keep an extra step only
when it protects authorization, destructive-action safety, or protocol
compatibility. Record that reason beside the action.

## Evidence limits

Session records show intent, not completion. Paths above identify evidence
without copying unrelated private transcript content. The technical-debt board
and changelog record code changes, exact commits, hosted checks, and revert
commands.
