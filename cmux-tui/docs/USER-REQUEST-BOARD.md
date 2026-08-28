# cmux-tui user request board

## Wave 85 current state: main `0ab1edc814b7aaae23e458a3b73e34adfcd60438`

Snapshot: 2026-08-28T09:47:54Z. The latest merge and gate states are pinned to exact heads.

| Request | Status | Acceptance proof |
| --- | --- | --- |
| Deduplicate cmux-tui shutdown | [#11072](https://github.com/manaflow-ai/cmux/pull/11072) merged, source `7cf4ed0b96fb1bc22b2a2823dc81d3164ebbd60d`, merge `253df2472973a5654e1a3d7fee13764a177c7a79` | One owned shutdown cleanup path is on main; dependent lifecycle changes still need focused checks. |
| Cloud tree interaction | [#11069](https://github.com/manaflow-ai/cmux/pull/11069) merged, source `d9646e350bcd5db20458899ff66f4a19df9d0a14`, merge `f756735566a2ce16bad450a8ab592fef2a40d9c4` | Right-click verbs, confirmations, workspace double-click, and drag gating are on main. Hierarchical Harbor redesign remains open. |
| Remove the second retained-tab scan | [#11056](https://github.com/manaflow-ai/cmux/pull/11056) merged, source `433e1f5ec237476077e7a50eceeb1c39547fc0ff`, merge `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` | One-pass reindexing preserves duplicate surface IDs and clamp behavior. |
| Order hook records and suppress ended agents | [#11024](https://github.com/manaflow-ai/cmux/pull/11024) open, head `9dcf978bda0ed1675f88d20e76198ebc1033c986`, base `fa77ad23364aa12993644b357b425513d61ca632` | Exact review and restart, stale-hook, tombstone, and sanitized-projection tests. |
| Preserve projection rail pointer routing | [#11025](https://github.com/manaflow-ai/cmux/pull/11025) open, head `685c924e866113d1457e89a2bd9469e5fb219e6a`, base `1e09970237f21686b8c0e6853b51a89819623803` | Exact review and focused pointer-routing tests. |
| Add Unicode glyph conformance invariants | [#11028](https://github.com/manaflow-ai/cmux/pull/11028) open, head `5ca760526fed25225b135f99b238a9a0fd7ac7e9`, mergeable on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` | Exact review and hosted Unicode test. |
| Keep config replacement files private | [#10990](https://github.com/manaflow-ai/cmux/pull/10990) merged, head `2608c8ca279f26c188723e95f31e6ac287439423`, merge `fa77ad23364aa12993644b357b425513d61ca632` | Retain the merged privacy and durability evidence. |
| Remove avoidable graphics allocations | [#11055](https://github.com/manaflow-ai/cmux/pull/11055) open, head `8f2287a00a490a6e00d09140cccb69a75f58e2e4`, base `fa77ad23364aa12993644b357b425513d61ca632` | Run the dirty-surface hosted test. |
| Resolve reducer, CDP, Harbor, and drag blockers | [#11002](https://github.com/manaflow-ai/cmux/pull/11002), [#11068](https://github.com/manaflow-ai/cmux/pull/11068), and [#11013](https://github.com/manaflow-ai/cmux/pull/11013) are open, mergeable, and clean on stale bases; stacked [#11078](https://github.com/manaflow-ai/cmux/pull/11078) and [#10401](https://github.com/manaflow-ai/cmux/pull/10401) are conflicting and dirty; [#11063](https://github.com/manaflow-ai/cmux/pull/11063) is open, mergeable, and clean on a stale base | Do not claim completion without exact-head reducer/parity, safe CDP diagnostics, Harbor tree/manual-I/O, and drag-into-terminal behavior proof. |

Strict session accounting: confirmed turns `0`; total `unknown`. The five documented owner workstreams are the practical evidence floor. The audit retains a conservative lower bound of 50 and a historical ledger of at least 258 named substantive turns. Neither is a total, and no 10,000-session claim is made.

## Wave 84 current state: main `305519d149c1ca61d4be4838e18b0a59f8e69b2a`

Snapshot: 2026-08-28T07:43:00Z. This board separates merged fixes from requests that still lack an acceptance proof.

| Request | Status | Acceptance proof |
| --- | --- | --- |
| Order hook records and suppress ended agents | [#11024](https://github.com/manaflow-ai/cmux/pull/11024) open at `d3bb50772cdca64586304e5afcfec5f3a222fe1a` | Restart, stale-hook, tombstone, and sanitized-public-snapshot tests pass on the exact head. |
| Remove avoidable TUI allocations and scans | [#11055](https://github.com/manaflow-ai/cmux/pull/11055), [#11056](https://github.com/manaflow-ai/cmux/pull/11056) open | Focused hosted tests pass after current-main rebases. |
| Keep config replacement files private | [#10990](https://github.com/manaflow-ai/cmux/pull/10990) open | Atomic private staging, collision retry, durability behavior, and English/Japanese strings pass. |
| Make agent detection reliable | [#11002](https://github.com/manaflow-ai/cmux/pull/11002), [#11068](https://github.com/manaflow-ai/cmux/pull/11068) open and stacked | Durable cursor, fail-closed identity, parity matrix, and reconnect tests pass. |
| Keep CDP failures useful but safe | [#11013](https://github.com/manaflow-ai/cmux/pull/11013), [#11078](https://github.com/manaflow-ai/cmux/pull/11078) open | Public wire text has no endpoint/internal queue details; diagnostics remain private. |
| Replace Harbor flat panel with a tree | [#11063](https://github.com/manaflow-ai/cmux/pull/11063) round 1 | Tree ownership, drag, cloud manual I/O, reconnect, and no-nested-TUI proof. |
| Drag an agent into a terminal | [#10401](https://github.com/manaflow-ai/cmux/pull/10401) conflicting | Shared drag payload opens the intended session and never injects text. |

Strict session count remains `unknown`; the older 258 named-turn lower bound is not a total and does not prove 10,000 sessions.

## Wave 83 follow-up: main `989293cdb9058500f51d6c9b8e4f3795e67997ce`

Snapshot: 2026-08-28T06:56:33Z. Current main merges [#11066](https://github.com/manaflow-ai/cmux/pull/11066) by Abdulaziz Albahar (`8a7b4b5c4a7ad4af2851303b27bd17327d15d7d8`), [#11000](https://github.com/manaflow-ai/cmux/pull/11000) by Lawrence Chen (`8910e6360e3b1d8b05b875cbe44e1901e8c7fc60`), [#11018](https://github.com/manaflow-ai/cmux/pull/11018) by Abdulaziz Albahar (`ed19cfa5cb88d6e0fae683bbe4a733bd4e2d062c`), [#10838](https://github.com/manaflow-ai/cmux/pull/10838) by Austin Wang (`c1e7f094cea7b1a1dbe21b48bc43e01c41b2d1c4`), and [#10326](https://github.com/manaflow-ai/cmux/pull/10326) by Austin Wang (`989293cdb9058500f51d6c9b8e4f3795e67997ce`). Strict session count remains `unknown`; 258 named turns is an older lower bound, not a total.

| Intent | Evidence and status | Next proof |
| --- | --- | --- |
| Harbor filesystem-tree redesign | Claude `~/.claude/history.jsonl:91032`, session `9a24a8c7-e7e4-4385-9742-aa20f8475b66`; [#11063](https://github.com/manaflow-ai/cmux/pull/11063), Lawrence Chen, head `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6`, base `feat-tui-manual-io`, open and mergeable. The user rejected the flat panel and requested a host, tool, session, workspace, window/tab, and terminal tree, draggable terminals, cloud manual I/O through remote API or control-mode equivalents, and no nested TUI. This is round 1 only; no redesign PR or completion receipt exists. | Publish the redesign as a follow-up and prove attach, detach, reconnect, raw/echo restoration, and terminal drag behavior without nested TUI rendering. |
| Herdr/Codex parity remains partial | Claude `~/.claude/history.jsonl:91027,91029`, session `e5f4a11b-ca0c-4d74-8520-debf0fe5671b`; [#11068](https://github.com/manaflow-ai/cmux/pull/11068), Lawrence Chen, head `04380edc86d1f5033b71341ddc97cb4738c26e4f`, open; GitHub mergeability changed during the audit, and checks and review remain pending. CodeRabbit submitted eight actionable comments at 2026-08-28T06:14:55Z, covering authoritative identity, lowercase-region reuse, live-terminal `HashSet` retention, monotonic snapshots, maintained attention ordering, and Grok/Qwen rules. Seen-bit, wait-for-state, manifest refresh, filters, visible-blocker, wrapper identity, Windows, and OSC gaps remain. | Fix each review finding, then run an exact-head parity matrix for all supported agents, exits, reconnects, and attention ordering. |
| Post-audit cmux-TUI security sweep | Codex `~/.codex/history.jsonl:18868-18869`, session `01a04659-67b5-7e73-af85-20019325aae6`, transcript `~/.codex/sessions/2026/08/27/rollout-2026-08-27T20-10-59-01a04659-67b5-7e73-af85-20019325aae6.jsonl`; the asks are to check TUI PRs after prior security audits. The latest plain status at 2026-08-28T06:14:43Z says post-audit TUI PR screening is in progress. No final result or PR link exists. | Finish the review, publish exact findings and fixes with exact-head checks, and keep secrets out of logs. |
| Drag agents into terminals remains a #10401 gap | [#10401](https://github.com/manaflow-ai/cmux/pull/10401), Lawrence Chen, head `46590bacaed87fba46d4ceb5cdacadcafad07833`, open and conflicting. Its body keeps drag-into-terminal as a follow-up requiring a UTType, `.draggable`, and terminal drop route. Claude history `~/.claude/history.jsonl:90390,90392` and `21824,21911` asks for this interaction and records failed terminal drops. | Rebase the follow-up, implement one shared drag payload and terminal drop action, preserve working-directory context, and prove a dropped session opens the intended terminal without text insertion. |

Pattern references: Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/) retains only the latest value, [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/) delivers each lifecycle value, and Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html) owns render buffers and cursor state.

## Current reconciliation: main `2c6fd70ecceeed63fdb549882737c6563fb3f52d`

Post-snapshot intent rows (2026-08-28) are evidence-linked below. Main now also
contains [#11022](https://github.com/manaflow-ai/cmux/pull/11022), merge
`2c6fd70ecceeed63fdb549882737c6563fb3f52d`. Strict session count remains
`unknown`; the retained ledger is a lower bound, not a turn count.

Current TUI merge refs also include [#11045](https://github.com/manaflow-ai/cmux/pull/11045)
(`8d71d72e6de027074828d7d81443b1f8ec825283`), [#11044](https://github.com/manaflow-ai/cmux/pull/11044)
(`c33d38ab80166e7ca525d197faf93d1f918f55f2`), [#11012](https://github.com/manaflow-ai/cmux/pull/11012)
(`d0b3b737a26f6afa6565b6c0160a31700abe6e21`), and [#11039](https://github.com/manaflow-ai/cmux/pull/11039)
(`c1151eaf7addbb49bdcf40c053abe059fcef2db5`).

Receipt paths: Codex `~/.codex/sessions/2026/08/27/rollout-2026-08-27T13-57-58-01a04503-e63d-7691-837d-374c1b3956ff.jsonl` and `~/.codex/sessions/2026/08/27/rollout-2026-08-27T21-27-44-01a0469f-ab5e-7d70-9e3d-ecc866f7ebcb.jsonl`; Claude `~/.claude/history.jsonl` with session metadata under `~/.claude/sessions/`.

| Intent | Evidence and status | Next proof |
| --- | --- | --- |
| Attribute iOS key-to-pixel latency. | Codex session `01a04503-e63d-7691-837d-374c1b3956ff`, user messages `msg_01a0450d-9045-7f41-ae21-d654c0f83bf1` and `msg_01a04511-6393-7122-8574-8b0aaa634851`; measured send-to-echo is materially above RPC settlement. [#11005](https://github.com/manaflow-ai/cmux/pull/11005), Lawrence Chen, head `8c3bb260504f50b622158b5ce884f573ddf1c6f5`, adds iOS queue/actor stamps only. | Add Mac/DO receive, PTY-write, and pixel-present stamps, then rerun a fixed sample set. |
| Decide direct Durable Object authentication. | Codex message `msg_01a0450b-46a2-7730-bace-69d26779b735` asked whether the ticket route can be removed securely. [#10963](https://github.com/manaflow-ai/cmux/pull/10963), Lawrence Chen, head `ba65199cf505729eddc27373b9497b9573bc9f97`, chooses direct Stack header plus first-frame session admission and deletes `/api/mobile-relay/ticket`; it remains open. | Verify endpoint auth, first-frame admission, token scope, expiry, and disconnect cleanup on the deployed worker. |
| Make one live topology authority. | Codex session `01a0469f-ab5e-7d70-9e3d-ecc866f7ebcb`, messages `msg_01a046a0-8791-7121-bc05-6441203c0a69` and `msg_01a046a8-c55e-7a41-8a8f-76080aa7acbc`, asks which workspaces and terminals belong to each machine and how state is read today. | Keep the local daemon/journal authoritative for live PTY state; use cloud data for registry and presence, with revisioned deltas and gap refetch. |
| Provide one external-session catalog. | Claude history session `9a24a8c7-e7e4-4385-9742-aa20f8475b66`, history timestamp `1787889382854`, requests a right sidebar catalog for cmux TUI, tmux, zellij, zmx, Herdr, and manually added SSH remotes, with drag-to-attach through manual I/O. | Define stable source IDs and capability states, then prove local and SSH discovery, attach, detach, and stale-entry removal. |
| Complete the agent roster projection. | Claude history session `e5f4a11b-ca0c-4d74-8520-debf0fe5671b`, timestamps `1787870057639`, `1787887503164`, `1787888225974`, and `1787892110942`, requests Claude/Codex/Herdr coverage, exit removal, names, lifecycle events, and unread ordering. [#10966](https://github.com/manaflow-ai/cmux/pull/10966), Lawrence Chen, head `3885306fb27853a60732dbbbf79fe44d172f2949`, is conflicting; Codex coverage also tracks [#11040](https://github.com/manaflow-ai/cmux/issues/11040). | Rebase and test one journal-derived reducer for all supported agents, including exit, reconnect, and attention ordering. |
| Scope cloud manual I/O explicitly. | Claude history session `ef53c5e7-cb83-48ba-9e50-0e918307c79e`, timestamps `1787891295602` and `1787892694385`, asks for manual I/O with reconnect/error handling and says it should apply only to cloud cmux TUI attachments. [#10321](https://github.com/manaflow-ai/cmux/pull/10321), Lawrence Chen, head `c0501c00a3462ac48ce01ead37ff019628e23617`, is conflicting. | Route every cloud attachment through manual I/O, leave local creation unchanged, and add bounded reconnect/error states before merge. |

Pattern references: Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/) keeps the latest state, [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/) distributes lifecycle deltas, and Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html) owns a render pass. SQLite WAL requires one host and one writer, see [`wal.html`](https://www.sqlite.org/wal.html).

## Current reconciliation: main `e27710a23149d9412665ef786b688797006b2730`

Main includes merged #10995 (source `a156463ea61f00bc9e67e16e27ed3f38d3329417`, merge `e27710a23149d9412665ef786b688797006b2730`). Live direct-TUI open rows: #10990, #11000, #11013, #11024, #11025, and #11026. Issue #11027 remains open. Strict confirmed turns: `0`; total: `unknown`.

Audit basis: 2026-08-27T19:39:39Z. Current merged log: [#10984](https://github.com/manaflow-ai/cmux/pull/10984)
`e9543607420f7b3b3284ac4c71ea21918dea692e`, [#10975](https://github.com/manaflow-ai/cmux/pull/10975)
`46958aa58d171a01af7a5b1f06164f18d8639612`, [#10986](https://github.com/manaflow-ai/cmux/pull/10986)
`b5023a455618dd3d4885da2605e162b0bdb67790`, [#10982](https://github.com/manaflow-ai/cmux/pull/10982)
`642a65b1512d0d61aaef88290f90ef3408bbee74`, [#10985](https://github.com/manaflow-ai/cmux/pull/10985)
`2b61ecafceb4b1c008b6f07345270615a0fb4286`, and [#10612](https://github.com/manaflow-ai/cmux/pull/10612)
`af31628f7b0b2f6c34e184049254fa2fe91f285d`. This is a docs-only update.

Strict auditable session turns are `unknown` (not zero), because no durable
session identifiers were found. The practical floor is five documented
substantive owner workstreams. A branch proxy shows 96 TUI references and 78
substantive non-merge commits; it is not a turn count. Unresolved Claude IDs
are `1787650444261`, `1787650724161` (state ownership, manual I/O, reconnect),
`1787722163382`, `1787723964393` (remove Go daemon, direct tunnels),
`1787733887926`, `1787780735531` (machine terminals, VNC, attach, parity),
`1787794506089` (cloud tree), `1787823710241` (sidebar split),
`1787825896700` (wheel arrows), and `1787826030510` (completion subscriptions).
No transcript proves completion.

## Historical refresh: main `2b61ecafceb4b1c008b6f07345270615a0fb4286`

Snapshot: 2026-08-27T18:44:45Z, documentation only. Main includes merged
[#10982](https://github.com/manaflow-ai/cmux/pull/10982), source
`1e0c3eefaf43e733c967131199361d587f56a34b`, merge
`642a65b1512d0d61aaef88290f90ef3408bbee74`, [run 33100547866](https://github.com/manaflow-ai/cmux/actions/runs/33100547866)
passed, and [#10985](https://github.com/manaflow-ai/cmux/pull/10985), source
`f32d788d1cb503fb7cddf50e70fc40d0e067ec4e`, merge
`2b61ecafceb4b1c008b6f07345270615a0fb4286`, [runs 33103012053](https://github.com/manaflow-ai/cmux/actions/runs/33103012053)
and [33103010095](https://github.com/manaflow-ai/cmux/actions/runs/33103010095)
passed. Both have CodeRabbit comment-only reviews. Rollbacks are
`git revert 642a65b1512d0d61aaef88290f90ef3408bbee74` and
`git revert 2b61ecafceb4b1c008b6f07345270615a0fb4286`.

| Current PR | Exact head | Exact runs | Gate and review state |
| --- | --- | --- | --- |
| [#10966](https://github.com/manaflow-ai/cmux/pull/10966), Lawrence Chen | `dda134e95835a415d6cce062e896367ad30c3a94` | [33104657912](https://github.com/manaflow-ai/cmux/actions/runs/33104657912), [33104745426](https://github.com/manaflow-ai/cmux/actions/runs/33104745426), in progress | Mergeable; five CodeRabbit comment-only reviews |
| [#10969](https://github.com/manaflow-ai/cmux/pull/10969), Lawrence Chen | `0a89a140738c68d105ddd7d1cf5bbcb1e713bb02` | [33104519612](https://github.com/manaflow-ai/cmux/actions/runs/33104519612), [33104514655](https://github.com/manaflow-ai/cmux/actions/runs/33104514655), in progress | Mergeable; one CodeRabbit comment-only review |
| [#10612](https://github.com/manaflow-ai/cmux/pull/10612), Lawrence Chen | `ddc15ed4d7fc737cf86e9bd4bf2adc8bd1ebf5fa`, stale base | [33103112353](https://github.com/manaflow-ai/cmux/actions/runs/33103112353), [33103077154](https://github.com/manaflow-ai/cmux/actions/runs/33103077154), passed | Comment-only Greptile, Codex connector, and CodeRabbit reviews; rebase |
| [#10891](https://github.com/manaflow-ai/cmux/pull/10891), Lawrence Chen | `e16aa8c35bbb1fafa7b3cb1340f872754c66d6a7`, stale base | [33104968098](https://github.com/manaflow-ai/cmux/actions/runs/33104968098) queued; [33104965438](https://github.com/manaflow-ai/cmux/actions/runs/33104965438) in progress | Mergeability unknown; earlier-head CodeRabbit comments |

Closed without merge, with no rollback: [#9806](https://github.com/manaflow-ai/cmux/pull/9806),
[#9813](https://github.com/manaflow-ai/cmux/pull/9813),
[#10136](https://github.com/manaflow-ai/cmux/pull/10136),
[#10413](https://github.com/manaflow-ai/cmux/pull/10413),
[#10237](https://github.com/manaflow-ai/cmux/pull/10237),
[#10267](https://github.com/manaflow-ai/cmux/pull/10267), and
[#10746](https://github.com/manaflow-ai/cmux/pull/10746). Exact closed heads in
that order are `406529665e5494ca559acab47079d8e7fb274386`,
`3b8d500aa23cfe9a7fbbe4a1dbdcf1be19902c61`,
`0786b6b37e5a397c1acc15b14be4a89f4363117b`,
`891544e0ab1f1ab277213b984e7f53078374fb63`,
`187dffe3e181fd6a85f99dc3fec2244c4fbe6fff`,
`7c8e4130737cf15f81086603364b587b13c05f40`, and
`9fa4c1497719f3c205ce6d402b3ce338d7fd5504`.

Issues [#10881](https://github.com/manaflow-ai/cmux/issues/10881) and
[#10394](https://github.com/manaflow-ai/cmux/issues/10394) closed after merged
[#10954](https://github.com/manaflow-ai/cmux/pull/10954). Browser
[#335](https://github.com/manaflow-ai/cmux/pull/335) resolved at merge
`5697f71fc6956729524a76a5f17d5611c3ff485b`; rollback:
`git revert 5697f71fc6956729524a76a5f17d5611c3ff485b`.

No new session scan ran. Retained evidence proves at least 258 named
substantive turns, a lower bound only. No 10,000-session claim is made. Later
code merges require a final refresh.

Historical snapshot: 2026-08-27T13:05:00Z, pinned to `origin/main`
[`87f31977237cbcbbf8b7f492718685d612fbb9b0`](https://github.com/manaflow-ai/cmux/commit/87f31977237cbcbbf8b7f492718685d612fbb9b0),
committed 2026-08-27T05:49:57-07:00 with subject
`Integrate Escape passthrough fix from PR #9810 (#10959)`. The prior
`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` and earlier
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshots are retained below.
Metadata-only scan: 587 Codex session files dated after the prior snapshot and
2,505 Codex/Claude files mentioning TUI. No transcript values or secrets were
copied. Open dependent intents remain [#10736](https://github.com/manaflow-ai/cmux/pull/10736) and [#10742](https://github.com/manaflow-ai/cmux/pull/10742). Cloud resource projection [#10812](https://github.com/manaflow-ai/cmux/pull/10812) is superseded by merged [#10887](https://github.com/manaflow-ai/cmux/pull/10887). Packaging duplicate [#10886](https://github.com/manaflow-ai/cmux/pull/10886) remains open and is superseded pending [#10891](https://github.com/manaflow-ai/cmux/pull/10891).

The retained session receipt supports at least 258 named substantive turns.
This is a verifiable lower bound, not a total session count, and no
10,000-session claim is made.

Merged context for the current main tail is recorded here so request status is
not confused with code integration. A merge does not close a request without
behavior evidence.

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |
| [#10936](https://github.com/manaflow-ai/cmux/pull/10936) | Lawrence Chen | `0f6bc912500c630921a6a74d86c09d5817e56278` | 2026-08-27 09:58:58 | `d65d6e6ccacf1d7300316451ce2830f05f889e14` | `git revert d65d6e6ccacf1d7300316451ce2830f05f889e14` |
| [#10951](https://github.com/manaflow-ai/cmux/pull/10951) | Lawrence Chen | `978655f95b56351c9d554d2bdd1be9ad6ec2c551` | 2026-08-27 12:04:42 | `de3902db48d2924c227b5acb26cbe1d89fe03cc0` | `git revert de3902db48d2924c227b5acb26cbe1d89fe03cc0` |
| [#10954](https://github.com/manaflow-ai/cmux/pull/10954) | Lawrence Chen | `cc1edc896dbf321da26e26e10fb71e5fbb22e57c` | 2026-08-27 11:23:26 | `a293eba98d6f4fafa4add823327c44deef8371ef` | `git revert a293eba98d6f4fafa4add823327c44deef8371ef` |
| [#10958](https://github.com/manaflow-ai/cmux/pull/10958) | Lawrence Chen | `c6de8f16b6390038225f87474f603b0ea157506e` | 2026-08-27 10:22:03 | `9cf920bb6b7a87bae3af721a0f98c989c45b9c4b` | `git revert 9cf920bb6b7a87bae3af721a0f98c989c45b9c4b` |
| [#10962](https://github.com/manaflow-ai/cmux/pull/10962) | Lawrence Chen | `ff719b6dc4e9f05358d0c77b7f49a9db021f72e7` | 2026-08-27 10:41:51 | `ef5e7434927d89996e2cd29b429823b8a716a08e` | `git revert ef5e7434927d89996e2cd29b429823b8a716a08e` |
| [#10970](https://github.com/manaflow-ai/cmux/pull/10970) | Lawrence Chen | `561ddccdc9da7d6389d90940f73e9ea30205fa26` | 2026-08-27 12:25:26 | `aa8ca45e0b3a140678c4a6ae588e201cb421ac50` | `git revert aa8ca45e0b3a140678c4a6ae588e201cb421ac50` |
| [#10972](https://github.com/manaflow-ai/cmux/pull/10972) | Lawrence Chen | `d41cac100d2488c41cbabff7c236166186b9deb4` | 2026-08-27 12:22:32 | `2f95b8760005047ff470afe4a00fd33783e4cf93` | `git revert 2f95b8760005047ff470afe4a00fd33783e4cf93` |
| [#10959](https://github.com/manaflow-ai/cmux/pull/10959) | Lawrence Chen | `8f74239c78a81352d69e8fe5512a688b0a9d7b7e` | 2026-08-27 12:49:58 | `87f31977237cbcbbf8b7f492718685d612fbb9b0` | `git revert 87f31977237cbcbbf8b7f492718685d612fbb9b0` |

## Historical snapshot retained: main `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`

The following request rows and scan receipt preserve the prior snapshot
captured at 2026-08-27T09:54:48Z. They are historical evidence, not a fresh
current-session inventory.

Historical snapshot: 2026-08-27T09:54:48Z, pinned to `origin/main`
[`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff),
committed 2026-08-27T02:31:38-07:00 with subject
`fix(tui): zeroize oversized remote frames (#10950)`. The prior
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshot, captured at
2026-08-27T09:25:01Z, is retained below. No new session scan was run, so the
existing evidence and lower-bound ledger remain unchanged.

Merged context for the current main tail is recorded here so request status is
not confused with code integration. A merge does not close a request without
behavior evidence.

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |

## Historical snapshot retained: main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The following request rows and scan receipt preserve the prior snapshot. They
are historical evidence, not a fresh current-session inventory.

Historical snapshot: 2026-08-27T09:25:01Z, pinned to `origin/main`
[`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095).
Evidence comes from local Codex and Claude session records. A request stays
open until its user-visible behavior has a focused test or a recorded dogfood
result. The previous rows are preserved; this section adds only the current
audit delta.

## Historical 2026-08-27 audit additions at main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The scan receipt is 174 parsed Claude records and 42 session IDs from
`~/.claude/history.jsonl:90614-end`, plus 47 parsed Codex records and 17 IDs
from `~/.codex/history.jsonl:18787-end`. Only 26 Claude records and two Codex
records matched the selected TUI terms. Credentials, secret values, emails,
pasted payloads, encrypted inter-agent content, and unrelated records were not
copied into this board.

| Request | Evidence | Acceptance | State |
| --- | --- | --- | --- |
| Authenticate account-scoped discovery before an Iroh dial and keep transport choice explicit. | `~/.claude/history.jsonl:90614-90626,90736-90745,90751,90756-90758,90772-90774,90779` | Pair authorized accounts, reject endpoint probing and unauthenticated discovery, and prove bounded reconnect on the selected transport. | Open, security design |
| Model terminals, VNC screens, and workspaces as per-machine resources with authoritative open/closed state. | `~/.claude/history.jsonl:90630-90631,90664-90673,90734-90735,90763,90777` | Open, close, and reconnect from two clients while preserving one revisioned catalog and stable resource IDs. | Open, product and protocol design |
| Keep direct Ghostty-compatible I/O, parser, tunnel, and rendering ownership in cmux-tui. | `~/.claude/history.jsonl:90634,90639-90641,90657,90761` | Compare raw I/O and ANSI/OSC/cursor rendering against Ghostty without a frontend parser or background shim. | Open, architecture and behavior proof |
| Make sandbox access capability-based and shared by authorized threads without strict conversation binding. | `~/.claude/history.jsonl:90780-90781` | Enumerate an allowlist, reject arbitrary targets, and prove separate PTY/session ownership for two authorized threads. | Open, security design |
| Make restore failure, CPU, and latency visible without freezing a leader or client. | `~/.claude/history.jsonl:90660-90670,90697-90699` | Interrupt restore and sustained output, report one actionable outcome, and assert bounded CPU, latency, and cancellation. | Open, behavior proof |

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
