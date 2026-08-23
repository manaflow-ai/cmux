# cmux-tui technical-debt board

Audit base: `origin/main` at `17466308a52cb53e417e07085f108800efedd267`.
Audit wave: implementation wave 1. Source audit: nine recorded TUI sessions
(rounds 1-9, 2026-08-19 through 2026-08-21) plus the cmux-devboxes checklist.

## Architecture decision

Use Ghostty manual-IO for daemon-backed surfaces. The app will own one direct
byte pump (daemon replay, live output, raw input, resize, and close status)
instead of spawning `cmux-tui attach` inside a nested PTY. Keep the daemon as
the durable owner of terminal and layout state. Migrate in this order:
`--pipe-io` proof, pump-owned resize/close, native `cmux.protocol/2` client,
then removal of the exec-attach bridge. This records the user request from
round 9B; no manual-IO proof exists yet.

## Completed request chains

| Request | Evidence | Status |
| --- | --- | --- |
| Tier-A daemon attach and quit/reopen survival | [PR 10408](https://github.com/manaflow-ai/cmux/pull/10408) | First pass complete. Known cuts: launchd supervision, first-tab/split coverage, cwd/env, orphan cleanup. |
| Journal topology survives terminal exit | [PR 10413](https://github.com/manaflow-ai/cmux/pull/10413) | Complete for exit preservation. Checkpoints and agent launch specs remain open. |
| Scoped attach mouse/cursor correctness | [PR 10428](https://github.com/manaflow-ai/cmux/pull/10428) | Complete through replay, reattach, and CI XCUITest. Focus forwarding and OSC 52 remain pre-existing gaps. |
| Checkpoint capture race | [PR 10501](https://github.com/manaflow-ai/cmux/pull/10501) | Complete for bounded, non-destructive capture. Journal growth/GC is still open. |
| Terminal close and liveness reporting | [PR 10513](https://github.com/manaflow-ai/cmux/pull/10513) | Complete for tested host loss and daemon loss paths. Exact round-7 trigger remains unproven. |
| Spec-only plan | [PR 10388](https://github.com/manaflow-ai/cmux/pull/10388) | Closed by direction. Specs must land with implementation. |

## Open requests and acceptance work

| Request | Acceptance gap | State |
| --- | --- | --- |
| Manual-IO transport | `--pipe-io` PoC must render live output, accept typing/mouse, replay on relaunch, and prove one reply authority. | Next implementation slice. |
| Daemon lifecycle | launchd user supervision and detached update handoff with host version compatibility. | Open. |
| Durable restore | Full journal restore, terminal checkpoints, reboot scrollback, agent `--resume` and hibernation. | Open or partial. |
| State ownership | Daemon window resources, dock/panel resource types, WebKit placeholders, typed frontend projections. | Open or partial. |
| Cloud TUI | Build/auth/create/resume/enroll/attach, machine rail, provider-neutral status, lifecycle operations, reconnect, packaging, version rollback, accessibility. | Checklist remains unchecked in `plans/cmux-devboxes.md` (not copied into this worktree). |
| Backpressure | Bound journal/WAL work and terminal-output admission so a multi-second stall cannot wedge btop. | Open blocker. |

## Change log and revert guidance

- `PR 10408`: app bridge, quit policy, close semantics, config isolation, and
  TERM propagation. Revert its app commits together if removing the spike;
  keep daemon journal changes only with an explicit owner.
- `PR 10428`: replay mouse-wire-format and scoped attach fixes. Revert the
  serialization and client encoder as one unit; otherwise reattach can regress
  to urxvt encoding.
- `PR 10501`: checkpoint snapshot locking and quiet failure handling. Revert
  only with a replacement bounded-capture design; the old path disconnected
  healthy hosts.
- `PR 10513`: liveness sweep, reconnect give-up notices, and client exit
  reasons. Revert as one chain, then restore the prior exit-state contract.
- Manual-IO work: each slice must have a red behavior test before the fix and
  a hosted green run before removing bridge code. Revert by disabling the flag
  and retaining the existing bridge until the next slice is ready.

## Explicit blockers

1. No manual-IO implementation or end-to-end proof exists yet.
2. Journal size and WAL checkpoint latency can still create terminal-output
   admission stalls; prevention is not claimed.
3. launchd supervision, reboot checkpoints, and full agent restore are not
   implemented.
4. Cloud TUI acceptance remains a product-sized backlog, not a completed
   cmux-tui change.

