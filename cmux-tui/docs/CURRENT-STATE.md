# cmux-tui current state

Snapshot: 2026-08-28T09:04:37Z.

## Main

Current `origin/main` is `1e09970237f21686b8c0e6853b51a89819623803`.

Recent merged TUI work:

- [#11072](https://github.com/manaflow-ai/cmux/pull/11072), Lawrence Chen, shutdown cleanup, source `7cf4ed0b96fb1bc22b2a2823dc81d3164ebbd60d`, merge `253df2472973a5654e1a3d7fee13764a177c7a79`.
- [#11056](https://github.com/manaflow-ai/cmux/pull/11056), Lawrence Chen, one-pass retained-tab reindexing, source `433e1f5ec237476077e7a50eceeb1c39547fc0ff`, merge `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`.
- [#11069](https://github.com/manaflow-ai/cmux/pull/11069), Lawrence Chen, Cloud-tree interaction and drag gating, source `d9646e350bcd5db20458899ff66f4a19df9d0a14`, merge `f756735566a2ce16bad450a8ab592fef2a40d9c4`.
- [#11041](https://github.com/manaflow-ai/cmux/pull/11041), Lawrence Chen, paste repro harnesses and analyzer audit, merge `305519d149c1ca61d4be4838e18b0a59f8e69b2a`.
- [#11000](https://github.com/manaflow-ai/cmux/pull/11000), Lawrence Chen, surface-exit index, merge `8910e6360e3b1d8b05b875cbe44e1901e8c7fc60`.
- [#11044](https://github.com/manaflow-ai/cmux/pull/11044), Lawrence Chen, wire-name contract, merge `c33d38ab80166e7ca525d197faf93d1f918f55f2`.
- [#11045](https://github.com/manaflow-ai/cmux/pull/11045), Lawrence Chen, localized transport loss, merge `8d71d72e6de027074828d7d81443b1f8ec825283`.

## Gates in progress

- [#11024](https://github.com/manaflow-ai/cmux/pull/11024), head `7593d643fac436a01ad5044dcba180989702b4c3`, is open and mergeable on `main` at `1e09970237f21686b8c0e6853b51a89819623803`, with checks unstable. Exact review and focused restart, stale-hook, and public-projection tests remain required.
- [#11025](https://github.com/manaflow-ai/cmux/pull/11025), head `35c18d226635b90c18376f2ce441eb295c10af45`, is open and mergeable on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`, with checks unstable. Exact review and focused pointer-routing tests remain required.
- [#11028](https://github.com/manaflow-ai/cmux/pull/11028), head `5ca760526fed25225b135f99b238a9a0fd7ac7e9`, is open and mergeable on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`, with checks unstable. Exact review and the hosted Unicode conformance test remain required.
- [#10990](https://github.com/manaflow-ai/cmux/pull/10990), head `2608c8ca279f26c188723e95f31e6ac287439423`, is open and mergeable on `main` at `1e09970237f21686b8c0e6853b51a89819623803`, with checks unstable. Exact review and the hosted privacy test remain required.
- [#11055](https://github.com/manaflow-ai/cmux/pull/11055), head `d64c71274695c17b7acb96b144c1acacf0a66c2b`, is open and mergeable on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`, with checks unstable. Run the dirty-surface hosted test.

## Blocked or deliberately deferred

- [#11002](https://github.com/manaflow-ai/cmux/pull/11002), head `8da5643df4d89ecf4b3a0abad5809241c57e6b1d`, is open, mergeable, and clean on stale base `c582b8d74ab82e404f18b14ad4e97f2d4cc04fa9`; it needs a durable hook cursor, atomic projection/tombstone writes, bounded replay, and restart tests.
- [#11068](https://github.com/manaflow-ai/cmux/pull/11068), head `b3eca00fd03dd76763bd5273066df2779c236abc`, is open, mergeable, and clean on stale base `ed19cfa5cb88d6e0fae683bbe4a733bd4e2d062c`; it has unresolved identity, retention, snapshot, ordering, and agent-parity findings.
- [#11013](https://github.com/manaflow-ai/cmux/pull/11013), head `5f4083e33374416f1a6290bbd495319ce97f5199`, is open, mergeable, and clean on stale base `f8eb151b589892f0e9dea96e5735c6afaea20d9f`; it still has raw CDP error paths outside the ACK overflow patch.
- [#11078](https://github.com/manaflow-ai/cmux/pull/11078), head `46fe5348e2631769c4e9482e1127ad0c75a8dbff`, is conflicting and dirty on stacked base `5f4083e33374416f1a6290bbd495319ce97f5199`. Use its clean commit only after retargeting.
- [#10994](https://github.com/manaflow-ai/cmux/pull/10994), head `0a06846c8dbbf4fefa231cb31c3e9d833f6fe427`, is open, mergeable, and clean on stale base `8a7b4b5c4a7ad4af2851303b27bd17327d15d7d8`; it requires a fresh exact-head gate.
- [#10401](https://github.com/manaflow-ai/cmux/pull/10401), head `46590bacaed87fba46d4ceb5cdacadcafad07833`, is conflicting and dirty on stale base `2c6fd70ecceeed63fdb549882737c6563fb3f52d`; it still lacks drag-into-terminal behavior.
- [#11063](https://github.com/manaflow-ai/cmux/pull/11063), head `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6`, is open, mergeable, and clean on stale base `ba64d22c81aa716f79fedb95bc758fc8f7b7c29b`; it is a round-1 flat Harbor panel, not the requested hierarchical tree.

## Revert pointers

For these single-parent squash merges, create a reviewable revert branch and run the focused checks before merging:

```text
git revert <merge-sha>
```

The merge SHAs are recorded in `TECH-DEBT-CHANGELOG.md`. Revert dependent changes together when a wire contract or index consumer depends on the earlier merge.

## Simplification rules

Use one lifecycle source of truth, one shared action for every entry point, bounded replay instead of full journal scans, and private internal markers that are removed at every public projection boundary.

## Session accounting

The strict number of productive subagent sessions is not auditable from the available receipts, so it is recorded as `unknown`. Audit basis: 2026-08-28, `/Users/lawrence/.codex/history.jsonl`, `/Users/lawrence/.codex/thread_history_1.sqlite`, `/Users/lawrence/.claude/history.jsonl`, and archived Codex receipts. Method: match TUI-related entries, deduplicate by session, and retain only substantive productive sessions, yielding a conservative lower bound of 50; the historical ledger retains at least 258 named substantive turns. Neither is a total, and no 10,000-session claim is made.

This file links the durable boards and log: `PR-INTENT-BOARD.md`, `USER-INTENT-BOARD.md`, `USER-REQUEST-BOARD.md`, `TECH-DEBT-BOARD.md`, and `TECH-DEBT-CHANGELOG.md`.
