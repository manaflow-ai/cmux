# Organizer: local branch census

The first Organizer experiment is `cmux board --json` (also `cmux acp board --json`).
It is read-only and off by default, behind the existing **Settings > Experimental > Labs >
Show Preview Features** switch, `labs.previewFeatures`. That switch also enables the existing
preview surfaces; this experiment does not change its default or those surfaces.

With the switch off, the command returns `experiment_disabled` before connecting to a daemon.
With it on, the command reads the running local daemon and prints JSON. It does not start a
daemon or an agent. Turning the same switch off disables the next read; there is no service,
timer, persisted board, or separate state to remove.

## JSON contract (version 1)

- `scope` is `local`: sessions from other machines never appear.
- `observedAt` and `staleAfterMs` are milliseconds. The initial stale interval is six hours.
- `columns` contains `claimed` and `stale`. No issue inbox, review, or landed state is inferred.
- `cards` are keyed by the exact folder and checked-out branch. Two sessions on that pair
  share one card; the same branch name in different folders does not join. The card's `id` is
  the JSON-encoded tuple `["branch", cwd, branch]`, stable across reads.
- A card includes its sessions' ids, names, harnesses, statuses and activity times. It contains
  no prompt, transcript, or model summary. Closed, archived, side-question, and branchless
  sessions are excluded.
- A card is stale only when every attached session has a known activity time and the latest
  is at least six hours old. Waiting sessions age from `inputSince`; running sessions use their
  latest record. Other sessions use the last turn's end, an interrupted turn's start, or creation.
  Idle maintenance records do not refresh the card. Future times and missing activity do not
  prove staleness.

The list is read on demand through the existing bounded session-list transport, with a paged
fallback for older daemons. The read is a census, not a transactional snapshot: activity can
change while pages arrive. Sorting makes an unchanged input deterministic. Memory and work
scale with the local sessions returned; nothing runs between invocations.

## First-slice boundary

This provides the design's agent lookup before a PR exists. A visual board, people/team views,
repository identity across worktrees, issue/PR joins, claiming, and LLM summaries remain later
slices. This experiment makes no new sharing or team-visibility policy. The design names no
numeric before/after performance target; six hours is an experiment threshold, not a measured
improvement.

Design: [Organizer](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/plans/cmux-next/organizer.md).

## Verification

On Linux, run `cargo test -p acpmux --lib organizer_board` from `cmux-tui` through `cmux-ci`.
The fixtures cover the default-off gate, both settings encodings, grouping and deterministic
ordering, stale boundaries, multiple claimants, maintenance timestamps, unknown/future activity,
and exclusion of remote or hidden sessions. CLI routing accepts `cmux board --json`,
`cmux --json board`, and `cmux help board`.
