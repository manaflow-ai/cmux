# cmux-tui current state

Snapshot: 2026-08-28T07:43:00Z.

## Main

Current `origin/main` is `305519d149c1ca61d4be4838e18b0a59f8e69b2a`.

Recent merged TUI work:

- [#11072](https://github.com/manaflow-ai/cmux/pull/11072), Lawrence Chen, shutdown cleanup, merge `253df2472973a5654e1a3d7fee13764a177c7a79`.
- [#11041](https://github.com/manaflow-ai/cmux/pull/11041), Lawrence Chen, paste repro harnesses and analyzer audit, merge `305519d149c1ca61d4be4838e18b0a59f8e69b2a`.
- [#11000](https://github.com/manaflow-ai/cmux/pull/11000), Lawrence Chen, surface-exit index, merge `8910e6360e3b1d8b05b875cbe44e1901e8c7fc60`.
- [#11044](https://github.com/manaflow-ai/cmux/pull/11044), Lawrence Chen, wire-name contract, merge `c33d38ab80166e7ca525d197faf93d1f918f55f2`.
- [#11045](https://github.com/manaflow-ai/cmux/pull/11045), Lawrence Chen, localized transport loss, merge `8d71d72e6de027074828d7d81443b1f8ec825283`.

## Gates in progress

- [#11024](https://github.com/manaflow-ai/cmux/pull/11024), head `d3bb50772cdca64586304e5afcfec5f3a222fe1a`. The branch is rebased on this main. Exact local review and the focused hosted test are required before merge.
- [#11056](https://github.com/manaflow-ai/cmux/pull/11056), current head is rebase-dependent. Its one-pass retain change needs exact review and the hosted `retain_not_retired` test.
- [#11055](https://github.com/manaflow-ai/cmux/pull/11055), head `eea8a5c16f45de1417599d626b00c1f5fae83c39`. Rebase and run the dirty-surface hosted test.
- [#10990](https://github.com/manaflow-ai/cmux/pull/10990), head `69241f5f7a044bc797cf579b84c5fb546b4601db`. Exact review and the hosted privacy test are pending.

## Blocked or deliberately deferred

- [#11002](https://github.com/manaflow-ai/cmux/pull/11002) needs a durable hook cursor, atomic projection/tombstone writes, bounded replay, and restart tests.
- [#11068](https://github.com/manaflow-ai/cmux/pull/11068) is a large stack on the reducer and has unresolved identity, retention, snapshot, ordering, and agent-parity findings.
- [#11013](https://github.com/manaflow-ai/cmux/pull/11013) still has raw CDP error paths outside the ACK overflow patch.
- [#11078](https://github.com/manaflow-ai/cmux/pull/11078) is conflicting because it is stacked on #11013. Use its clean commit only after retargeting.
- [#10994](https://github.com/manaflow-ai/cmux/pull/10994), [#11025](https://github.com/manaflow-ai/cmux/pull/11025), and [#11028](https://github.com/manaflow-ai/cmux/pull/11028) have stale bases and require fresh exact-head gates.
- [#10401](https://github.com/manaflow-ai/cmux/pull/10401) is conflicting and still lacks drag-into-terminal behavior.
- [#11063](https://github.com/manaflow-ai/cmux/pull/11063) is a round-1 flat Harbor panel, not the requested hierarchical tree.

## Revert pointers

For a merged PR, create a reviewable revert branch and run the focused checks before merging:

```text
git revert -m 1 <merge-sha>
```

The merge SHAs are recorded in `TECH-DEBT-CHANGELOG.md`. Revert dependent changes together when a wire contract or index consumer depends on the earlier merge.

## Simplification rules

Use one lifecycle source of truth, one shared action for every entry point, bounded replay instead of full journal scans, and private internal markers that are removed at every public projection boundary.

## Session accounting

The strict number of productive subagent sessions is not auditable from the available receipts, so it is recorded as `unknown`. The older 258 named-turn figure is a lower bound, not a total. No 10,000-session claim is made.

This file links the durable boards and log: `PR-INTENT-BOARD.md`, `USER-INTENT-BOARD.md`, `USER-REQUEST-BOARD.md`, `TECH-DEBT-BOARD.md`, and `TECH-DEBT-CHANGELOG.md`.
