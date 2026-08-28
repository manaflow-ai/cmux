# cmux-tui user-intent board

## Wave 85 current state: main `0ab1edc814b7aaae23e458a3b73e34adfcd60438`

Snapshot: 2026-08-28T09:47:54Z.

| User intent | Current proof | Remaining work |
| --- | --- | --- |
| cmux-tui shutdown has one cleanup owner | [#11072](https://github.com/manaflow-ai/cmux/pull/11072) merged from `7cf4ed0b96fb1bc22b2a2823dc81d3164ebbd60d` as `253df2472973a5654e1a3d7fee13764a177c7a79` | Keep dependent lifecycle teardown covered by focused checks. |
| Cloud tree controls are direct and safe | [#11069](https://github.com/manaflow-ai/cmux/pull/11069) merged from `d9646e350bcd5db20458899ff66f4a19df9d0a14` as `f756735566a2ce16bad450a8ab592fef2a40d9c4` | Harbor still needs the requested host/tool/session/workspace/window/terminal tree, manual I/O, reconnect, and no-nested-TUI proof. |
| Retained-tab filtering avoids a second scan | [#11056](https://github.com/manaflow-ai/cmux/pull/11056) merged from `433e1f5ec237476077e7a50eceeb1c39547fc0ff` as `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` | Keep behavior coverage for duplicate IDs and out-of-range active tabs. |
| Agent lifecycle and projection input remain exact | [#11024](https://github.com/manaflow-ai/cmux/pull/11024) is open at `9dcf978bda0ed1675f88d20e76198ebc1033c986` on base `fa77ad23364aa12993644b357b425513d61ca632`; [#11025](https://github.com/manaflow-ai/cmux/pull/11025) is open at `685c924e866113d1457e89a2bd9469e5fb219e6a` on base `1e09970237f21686b8c0e6853b51a89819623803` | Run exact-head restart, stale-hook, tombstone, public-projection, and pointer-routing tests. |
| Unicode rendering and private config writes are covered | [#11028](https://github.com/manaflow-ai/cmux/pull/11028) is open at `5ca760526fed25225b135f99b238a9a0fd7ac7e9` on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`; [#10990](https://github.com/manaflow-ai/cmux/pull/10990) merged at `fa77ad23364aa12993644b357b425513d61ca632` from `2608c8ca279f26c188723e95f31e6ac287439423` | Finish hosted Unicode checks and retain the merged privacy evidence. |
| TUI allocation reduction continues | [#11055](https://github.com/manaflow-ai/cmux/pull/11055) is open at `8f2287a00a490a6e00d09140cccb69a75f58e2e4` on base `fa77ad23364aa12993644b357b425513d61ca632` | Run the dirty-surface hosted test. |
| Reducer, CDP, and drag parity remain blocked or deferred | [#11002](https://github.com/manaflow-ai/cmux/pull/11002), [#11068](https://github.com/manaflow-ai/cmux/pull/11068), and [#11013](https://github.com/manaflow-ai/cmux/pull/11013) are open, mergeable, and clean on stale bases; stacked [#11078](https://github.com/manaflow-ai/cmux/pull/11078) and [#10401](https://github.com/manaflow-ai/cmux/pull/10401) are conflicting and dirty; [#11063](https://github.com/manaflow-ai/cmux/pull/11063) is open, mergeable, and clean on a stale base | Resolve old-base and stacked branches, then prove durable identity, safe diagnostics, the Harbor hierarchy, cloud manual I/O, and drag without text insertion. |

Strict session accounting: confirmed turns `0`; total `unknown`. The five documented owner workstreams are the practical evidence floor. The audit retains a conservative lower bound of 50 and a historical ledger of at least 258 named substantive turns. Neither is a total, and no 10,000-session claim is made.

## Wave 84 current state: main `305519d149c1ca61d4be4838e18b0a59f8e69b2a`

Snapshot: 2026-08-28T07:43:00Z.

| User intent | Current proof | Remaining work |
| --- | --- | --- |
| Agent status stays ordered across restart and end | [#11024](https://github.com/manaflow-ai/cmux/pull/11024) at `d3bb50772cdca64586304e5afcfec5f3a222fe1a` | Finish exact review and hosted restart/late-event checks. |
| TUI does less allocation and scanning | [#11055](https://github.com/manaflow-ai/cmux/pull/11055), [#11056](https://github.com/manaflow-ai/cmux/pull/11056) | Rebase current heads and accept only behavior-preserving focused tests. |
| Config writes do not expose replacement contents | [#10990](https://github.com/manaflow-ai/cmux/pull/10990) | Complete exact review and hosted privacy checks. |
| Agent roster detects real tools and screens | [#11002](https://github.com/manaflow-ai/cmux/pull/11002), [#11068](https://github.com/manaflow-ai/cmux/pull/11068) | Resolve durable replay and parity findings before integration. |
| Browser transport errors are safe for users | [#11013](https://github.com/manaflow-ai/cmux/pull/11013), [#11078](https://github.com/manaflow-ai/cmux/pull/11078) | Cover every raw CDP error path and retarget the redaction patch. |
| Harbor shows a useful hierarchy and supports direct interaction | [#11063](https://github.com/manaflow-ai/cmux/pull/11063) is round 1 only | Ship the tree/drag/manual-I/O follow-up without a nested TUI. |

The source receipts are retained in the older sections below. Strict session count is `unknown`; no 10,000-session result is claimed.

## Wave 83 follow-up: main `989293cdb9058500f51d6c9b8e4f3795e67997ce`

Snapshot: 2026-08-28T06:56:33Z. Main now includes [#11066](https://github.com/manaflow-ai/cmux/pull/11066) (`8a7b4b5c4a7ad4af2851303b27bd17327d15d7d8`), [#11000](https://github.com/manaflow-ai/cmux/pull/11000) (`8910e6360e3b1d8b05b875cbe44e1901e8c7fc60`), [#11018](https://github.com/manaflow-ai/cmux/pull/11018) (`ed19cfa5cb88d6e0fae683bbe4a733bd4e2d062c`), [#10838](https://github.com/manaflow-ai/cmux/pull/10838) (`c1e7f094cea7b1a1dbe21b48bc43e01c41b2d1c4`), and [#10326](https://github.com/manaflow-ai/cmux/pull/10326) (`989293cdb9058500f51d6c9b8e4f3795e67997ce`). Strict session count remains `unknown`; the retained 258 named-turn figure is an older lower bound.

| Intent | Source receipt | Current status and acceptance proof |
| --- | --- | --- |
| Harbor filesystem-tree redesign | Claude `~/.claude/history.jsonl:91032`, session `9a24a8c7-e7e4-4385-9742-aa20f8475b66`; [#11063](https://github.com/manaflow-ai/cmux/pull/11063), Lawrence Chen, head `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6`, base `feat-tui-manual-io`, open and mergeable. | Replace the flat round-1 panel with a host, tool, session, workspace, window/tab, and terminal tree. Support draggable terminals and cloud manual I/O through remote API or control-mode equivalents. Do not render a nested TUI. No redesign PR or completion receipt exists; local control-mode probing works and raw/echo repair is in progress. |
| Herdr/Codex parity remains partial | Claude `~/.claude/history.jsonl:91027,91029`, session `e5f4a11b-ca0c-4d74-8520-debf0fe5671b`; [#11068](https://github.com/manaflow-ai/cmux/pull/11068), Lawrence Chen, head `04380edc86d1f5033b71341ddc97cb4738c26e4f`, open; GitHub mergeability changed during the audit, and checks and review remain pending. | CodeRabbit's 2026-08-28T06:14:55Z review has eight actionable comments: fail-closed identity, lowercase-region reuse, `HashSet` retention, monotonic snapshot writes, maintained attention ordering, and Grok/Qwen rules. Seen-bit, wait-for-state, manifest refresh, filters, visible-blocker, wrapper identity, Windows, and OSC gaps still need proof. |
| Post-audit cmux-TUI security sweep | Codex `~/.codex/history.jsonl:18868-18869`, session `01a04659-67b5-7e73-af85-20019325aae6`; transcript `~/.codex/sessions/2026/08/27/rollout-2026-08-27T20-10-59-01a04659-67b5-7e73-af85-20019325aae6.jsonl`. | The user requested review of TUI PRs landed after prior security audits. Latest plain status at 2026-08-28T06:14:43Z says screening is in progress. No final result or PR link exists. Acceptance is an exact-head finding and fix report with secret-safe logs. |
| Drag agents into terminals remains a #10401 gap | [#10401](https://github.com/manaflow-ai/cmux/pull/10401), Lawrence Chen, head `46590bacaed87fba46d4ceb5cdacadcafad07833`, open and conflicting; Claude `~/.claude/history.jsonl:90390,90392,21824,21911`. | The PR body leaves drag-into-terminal as follow-up work requiring a UTType, `.draggable`, and terminal drop route. Acceptance is a shared payload and drop action that opens the intended session, preserves working-directory context, and does not insert text into the terminal. |

Primary pattern references: Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/) for latest-state projections, [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/) for lifecycle delivery, and Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html) for one render owner.

## Post-snapshot intent refresh: main `2c6fd70ecceeed63fdb549882737c6563fb3f52d`

These six rows come from direct Codex and Claude asks after the prior audit.
They record intent and required proof. Strict session count remains `unknown`.

Current TUI merge refs include [#11045](https://github.com/manaflow-ai/cmux/pull/11045)
(`8d71d72e6de027074828d7d81443b1f8ec825283`), [#11044](https://github.com/manaflow-ai/cmux/pull/11044)
(`c33d38ab80166e7ca525d197faf93d1f918f55f2`), [#11012](https://github.com/manaflow-ai/cmux/pull/11012)
(`d0b3b737a26f6afa6565b6c0160a31700abe6e21`), and [#11022](https://github.com/manaflow-ai/cmux/pull/11022)
(`2c6fd70ecceeed63fdb549882737c6563fb3f52d`).

Receipt paths: Codex `~/.codex/sessions/2026/08/27/` JSONL receipts; Claude
`~/.claude/history.jsonl` with session metadata under `~/.claude/sessions/`.

| Intent | Source receipt | Current status and acceptance proof |
| --- | --- | --- |
| Mobile key-to-pixel latency attribution | Codex session `01a04503-e63d-7691-837d-374c1b3956ff`, messages `msg_01a0450d-9045-7f41-ae21-d654c0f83bf1` and `msg_01a04511-6393-7122-8574-8b0aaa634851` | [#11005](https://github.com/manaflow-ai/cmux/pull/11005), Lawrence Chen, head `8c3bb260504f50b622158b5ce884f573ddf1c6f5`, splits iOS queue and actor-hop time. Add Mac/DO receive, PTY write, and pixel-present stamps before claiming end-to-end attribution. |
| Direct Durable Object authentication | Codex message `msg_01a0450b-46a2-7730-bace-69d26779b735` | [#10963](https://github.com/manaflow-ai/cmux/pull/10963), Lawrence Chen, head `ba65199cf505729eddc27373b9497b9573bc9f97`, uses a Stack header and first-frame admission, with no ticket endpoint. Prove token scope, expiry, endpoint policy, and cleanup on the deployed worker. |
| Live topology authority | Codex session `01a0469f-ab5e-7d70-9e3d-ecc866f7ebcb`, messages `msg_01a046a0-8791-7121-bc05-6441203c0a69` and `msg_01a046a8-c55e-7a41-8a8f-76080aa7acbc` | The local daemon and journal should own live PTY/workspace state. Cloud storage should provide registry and presence only. Prove revisioned deltas, gap refetch, and one owner for each live fact. |
| Unified external-session catalog | Claude session `9a24a8c7-e7e4-4385-9742-aa20f8475b66`, history timestamp `1787889382854` | The requested right sidebar covers cmux TUI, tmux, zellij, zmx, Herdr, and manually added SSH remotes, with drag-to-attach through manual I/O. Prove stable IDs, capabilities, attach/detach, and stale-entry removal. |
| Agent-roster follow-up | Claude session `e5f4a11b-ca0c-4d74-8520-debf0fe5671b`, history timestamps `1787870057639`, `1787887503164`, `1787888225974`, and `1787892110942` | [#10966](https://github.com/manaflow-ai/cmux/pull/10966), Lawrence Chen, head `3885306fb27853a60732dbbbf79fe44d172f2949`, is conflicting. Cover Claude, Codex, and Herdr lifecycle events, exit removal, names, and unread ordering; Codex follow-up is [#11040](https://github.com/manaflow-ai/cmux/issues/11040). |
| Cloud manual-I/O policy | Claude session `ef53c5e7-cb83-48ba-9e50-0e918307c79e`, history timestamps `1787891295602` and `1787892694385` | [#10321](https://github.com/manaflow-ai/cmux/pull/10321), Lawrence Chen, head `c0501c00a3462ac48ce01ead37ff019628e23617`, is conflicting. Use manual I/O for cloud cmux TUI attachments, keep local creation unchanged, and prove reconnect and user-visible error states. |

Primary pattern references: Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/) for latest-state projections, [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/) for lifecycle deltas, Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html) for a single render owner, and SQLite [`WAL`](https://www.sqlite.org/wal.html) for same-host reader/writer constraints.

## Current reconciliation: main `e27710a23149d9412665ef786b688797006b2730`

Main includes merged #10995 (source `a156463ea61f00bc9e67e16e27ed3f38d3329417`, merge `e27710a23149d9412665ef786b688797006b2730`). Live direct-TUI open rows: #10990, #11000, #11013, #11024, #11025, and #11026. Issue #11027 remains open. Strict confirmed turns: `0`; total: `unknown`.

Audit basis: 2026-08-27T19:39:39Z. Main's current cmux-tui merge log is
[#10984](https://github.com/manaflow-ai/cmux/pull/10984) `e9543607420f7b3b3284ac4c71ea21918dea692e`,
[#10975](https://github.com/manaflow-ai/cmux/pull/10975) `46958aa58d171a01af7a5b1f06164f18d8639612`,
[#10986](https://github.com/manaflow-ai/cmux/pull/10986) `b5023a455618dd3d4885da2605e162b0bdb67790`,
[#10982](https://github.com/manaflow-ai/cmux/pull/10982) `642a65b1512d0d61aaef88290f90ef3408bbee74`,
[#10985](https://github.com/manaflow-ai/cmux/pull/10985) `2b61ecafceb4b1c008b6f07345270615a0fb4286`, and
[#10612](https://github.com/manaflow-ai/cmux/pull/10612) `af31628f7b0b2f6c34e184049254fa2fe91f285d`.

The latest reconciliation records strict auditable turns as `unknown` (not
zero), because durable session identifiers are absent. It records five practical
documented substantive owner workstreams. The branch proxy has 96 TUI
references and 78 substantive non-merge commits, which is not a turn count.
Unresolved Claude history IDs: `1787650444261`, `1787650724161` (state
ownership, manual I/O, reconnect); `1787722163382`, `1787723964393` (remove Go
daemon, direct tunnels); `1787733887926`, `1787780735531` (machine terminals,
VNC, attach, parity); `1787794506089` (cloud tree); `1787823710241` (sidebar
split); `1787825896700` (wheel arrows); `1787826030510` (completion
subscriptions). No completion evidence was found.

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

Current intent gates: [#10966](https://github.com/manaflow-ai/cmux/pull/10966)
head `dda134e95835a415d6cce062e896367ad30c3a94`, runs
[#33104657912](https://github.com/manaflow-ai/cmux/actions/runs/33104657912) and
[#33104745426](https://github.com/manaflow-ai/cmux/actions/runs/33104745426)
in progress, five CodeRabbit comments; [#10969](https://github.com/manaflow-ai/cmux/pull/10969)
head `0a89a140738c68d105ddd7d1cf5bbcb1e713bb02`, runs
[#33104519612](https://github.com/manaflow-ai/cmux/actions/runs/33104519612) and
[#33104514655](https://github.com/manaflow-ai/cmux/actions/runs/33104514655)
in progress, one CodeRabbit comment; [#10612](https://github.com/manaflow-ai/cmux/pull/10612)
head `ddc15ed4d7fc737cf86e9bd4bf2adc8bd1ebf5fa`, successful runs
[#33103112353](https://github.com/manaflow-ai/cmux/actions/runs/33103112353) and
[#33103077154](https://github.com/manaflow-ai/cmux/actions/runs/33103077154),
comment-only reviews and stale base; [#10891](https://github.com/manaflow-ai/cmux/pull/10891)
head `e16aa8c35bbb1fafa7b3cb1340f872754c66d6a7`, queued
[#33104968098](https://github.com/manaflow-ai/cmux/actions/runs/33104968098) and
in-progress [#33104965438](https://github.com/manaflow-ai/cmux/actions/runs/33104965438),
earlier-head CodeRabbit comments. None is ready here.

Closed without merge: [#9806](https://github.com/manaflow-ai/cmux/pull/9806),
[#9813](https://github.com/manaflow-ai/cmux/pull/9813),
[#10136](https://github.com/manaflow-ai/cmux/pull/10136),
[#10413](https://github.com/manaflow-ai/cmux/pull/10413),
[#10237](https://github.com/manaflow-ai/cmux/pull/10237),
[#10267](https://github.com/manaflow-ai/cmux/pull/10267), and
[#10746](https://github.com/manaflow-ai/cmux/pull/10746); no rollback applies.
Issues [#10881](https://github.com/manaflow-ai/cmux/issues/10881) and
[#10394](https://github.com/manaflow-ai/cmux/issues/10394) closed after merged
[#10954](https://github.com/manaflow-ai/cmux/pull/10954). Browser
[#335](https://github.com/manaflow-ai/cmux/pull/335) resolved at merge
`5697f71fc6956729524a76a5f17d5611c3ff485b`; rollback:
`git revert 5697f71fc6956729524a76a5f17d5611c3ff485b`.

No new session scan ran. Retained evidence supports at least 258 named
substantive turns, not a total and not a 10,000-session claim. Later code
merges require a final refresh.

Historical audit snapshot: 2026-08-27T13:05:00Z. The source baseline was
`origin/main` at [`87f31977237cbcbbf8b7f492718685d612fbb9b0`](https://github.com/manaflow-ai/cmux/commit/87f31977237cbcbbf8b7f492718685d612fbb9b0),
committed 2026-08-27T05:49:57-07:00 with subject
`Integrate Escape passthrough fix from PR #9810 (#10959)`. The prior
`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` and earlier
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshots are retained below as
historical evidence. No new session scan was run, so the existing scan receipt
and honest lower-bound ledger remain unchanged.

The current main tail includes [#10936](https://github.com/manaflow-ai/cmux/pull/10936),
[#10944](https://github.com/manaflow-ai/cmux/pull/10944), and
[#10950](https://github.com/manaflow-ai/cmux/pull/10950), [#10951](https://github.com/manaflow-ai/cmux/pull/10951), [#10954](https://github.com/manaflow-ai/cmux/pull/10954), [#10958](https://github.com/manaflow-ai/cmux/pull/10958), [#10962](https://github.com/manaflow-ai/cmux/pull/10962), [#10970](https://github.com/manaflow-ai/cmux/pull/10970), and [#10959](https://github.com/manaflow-ai/cmux/pull/10959). Their exact source
heads, authors, merge times, merge SHAs, and rollback commands are recorded in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).
The current ancestry also contains [#10972](https://github.com/manaflow-ai/cmux/pull/10972).

The retained session receipt supports at least 258 named substantive turns.
This is a verifiable lower bound, not a total session count, and no
10,000-session claim is made.

The scroll audit confirms alternate-screen wheel behavior is intentional: crossterm
classifies wheel events as scroll, cmux forwards Ghostty wheel events when mouse
tracking is enabled, and otherwise emits three arrow sequences. A configurable
policy and modifier override remain open; changing the default may break TUIs
that rely on arrows. Evidence: `cmux-tui/src/app.rs` `handle_scroll_with_admission`
and the crossterm `MouseEventKind` and Ghostty terminal configuration references.

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

The following intent delta and status labels preserve the prior snapshot
captured at 2026-08-27T09:54:48Z. They are historical evidence, not a claim
that the same rows were rescanned.

Historical audit snapshot: 2026-08-27T09:54:48Z. The source baseline was
`origin/main` at [`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff),
committed 2026-08-27T02:31:38-07:00 with subject
`fix(tui): zeroize oversized remote frames (#10950)`. The previous
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshot, captured at
2026-08-27T09:25:01Z, is retained below as historical evidence. No new session
scan was run for this metadata refresh, so the existing scan receipt and honest
lower-bound ledger remain unchanged.

The current main tail includes [#10944](https://github.com/manaflow-ai/cmux/pull/10944)
and [#10950](https://github.com/manaflow-ai/cmux/pull/10950). Their exact source
heads, authors, merge times, merge SHAs, and rollback commands are recorded in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |

## Historical snapshot retained: main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The following intent delta and status labels preserve the prior snapshot. They
are historical evidence, not a claim that the same rows were rescanned.

Historical audit snapshot: 2026-08-27T09:25:01Z. The source baseline was
`origin/main` at [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095).
This document records explicit user requests found in local session history. A
merged code change does not close a row without behavior evidence. The prior
aggregate tip and all older status labels remain historical below. For code
changes, open PR dispositions, and rollback commands, see
[`TECH-DEBT-BOARD.md`](TECH-DEBT-BOARD.md) and
[`PR-INTENT-BOARD.md`](PR-INTENT-BOARD.md).

The historical main tail included merged PRs [#10941](https://github.com/manaflow-ai/cmux/pull/10941),
[#10940](https://github.com/manaflow-ai/cmux/pull/10940),
[#10938](https://github.com/manaflow-ai/cmux/pull/10938),
[#10935](https://github.com/manaflow-ai/cmux/pull/10935),
[#10932](https://github.com/manaflow-ai/cmux/pull/10932),
[#10937](https://github.com/manaflow-ai/cmux/pull/10937),
[#10939](https://github.com/manaflow-ai/cmux/pull/10939),
[#10934](https://github.com/manaflow-ai/cmux/pull/10934), and
[#10949](https://github.com/manaflow-ai/cmux/pull/10949). The subsequent
[#10944](https://github.com/manaflow-ai/cmux/pull/10944) merge also reached the
baseline. Their merge SHAs and
individual revert commands are recorded in the changelog. None of these merges
proves full restore, cloud lifecycle, direct-I/O ownership, or end-to-end
transport acceptance.

## Historical 2026-08-27 intent-audit delta at main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The tail scan covered 174 parsed Claude records across 42 session IDs from
`~/.claude/history.jsonl:90614-end`; 26 records across 12 IDs matched the
TUI/relay/PTY/journal/surface terms. It covered 47 parsed Codex records across
17 session IDs from `~/.codex/history.jsonl:18787-end`; two records across two
IDs matched the narrow TUI terms. These are scan receipts, not a count of
substantive requests. Credentials, secret values, emails, pasted payloads,
encrypted inter-agent content, and unrelated records were excluded.

New explicit intent clusters remain open:

- Account-scoped Iroh discovery must authenticate and pair at the relay before
  dialing. The requested policy rejects endpoint-ID probing and hidden fallback,
  and keeps the chosen Tailscale TCP or Iroh transport explicit. Evidence:
  `~/.claude/history.jsonl:90614-90626,90736-90745,90751,90756-90758,90772-90774,90779`.
- A compact machine rail should own a per-machine catalog of terminals, VNC
  screens, and remote workspaces. Agents need authoritative open/closed state,
  live mirror, and close semantics. Evidence:
  `~/.claude/history.jsonl:90630-90631,90664-90673,90734-90735,90763,90777`.
- Ghostty parity work must keep direct manual I/O and tunnel ownership in
  cmux-tui, with parser/rendering behavior compared against Ghostty and no
  unrequested startup privacy prompts. Evidence:
  `~/.claude/history.jsonl:90634,90639-90641,90657,90761`.
- Restore and performance work must classify failed restore, bound CPU and
  latency, and prevent a frozen leader or client. Evidence:
  `~/.claude/history.jsonl:90660-90670,90697-90699`.
- Every authorized thread should inspect or use every permitted sandbox under
  respectful ownership; strict conversation binding is not the requested
  policy. Evidence: `~/.claude/history.jsonl:90780-90781`.

| ID | New explicit ask and evidence | Status at historical `origin/main` `99bdc375e9` | Acceptance test |
| --- | --- | --- | --- |
| UI-26 | Account-scoped discovery and relay-side pairing before Iroh dialing; no endpoint probing or implicit transport fallback. Evidence: `~/.claude/history.jsonl:90614-90626,90736-90745`. | Open. | Pair two authorized accounts, reject unauthenticated discovery and endpoint probing, and record the selected transport and bounded reconnect result. |
| UI-27 | Per-machine catalog with terminals, VNC screens, and remote workspaces as resources or pointers; agent-visible open/closed state. Evidence: `~/.claude/history.jsonl:90630-90631,90664-90673,90734-90735`. | Open. | Add two machines, open and close resources from separate clients, and prove one revisioned catalog, live mirror, and no stale resource after reconnect. |
| UI-28 | Cloud resource topology needs New terminal, workspace, and display controls plus explicit close semantics across many remote screens. Evidence: `~/.claude/history.jsonl:90763,90777` and `~/.codex/history.jsonl:18795-18812`. | Open. | Create multiple remote workspaces and screens, close one, reopen the app, and verify stable IDs, ownership, and bounded list/attach latency. |
| UI-29 | Keep direct Ghostty-compatible I/O, tunnel, parser, and rendering ownership in cmux-tui. Evidence: `~/.claude/history.jsonl:90634,90639-90641,90657,90761`. | Open. | Compare raw I/O, ANSI/OSC rendering, cursor behavior, and reconnect against Ghostty without a frontend parser or background shim. |
| UI-30 | Sandbox access should follow authenticated capability and respectful ownership, not strict conversation binding. Evidence: `~/.claude/history.jsonl:90780-90781`. | Open. | Enumerate an allowlisted sandbox capability, attach from two authorized threads, reject arbitrary targets, and prove independent PTY/session ownership. |
| UI-31 | Restore failure, CPU, and latency must be visible and bounded without freezing a leader or client. Evidence: `~/.claude/history.jsonl:90660-90670,90697-90699`. | Open. | Interrupt restore and sustained output, report one actionable outcome, and assert bounded CPU, latency, and cancellation with no frozen client. |

## Historical 2026-08-25 intent-audit delta

The session audit found no new independent product row, but it added concrete
acceptance evidence for existing rows:

- `~/.claude/history.jsonl:90357` records fresh `uvx cmux` failures because the
  `machine-provider` executable is missing. This keeps UI-06 open.
- `~/.codex/history.jsonl:18517-18518` and the same-day Claude records report a
  missing pane surface reference. This keeps UI-13 open and is a fresh-package
  repro requirement.
- Repeated resize and peer-death reports require proof that one client's
  resize or exit cannot kill another client. This strengthens UI-03 and UI-15.
- The user explicitly requests Ghostty manual-I/O ownership, reconnect state,
  and remote-process recovery, and rejects attach-command workarounds. This
  strengthens UI-01, UI-02, UI-04, and UI-07.
- A new interaction acceptance asks for left-sidebar `hjkl` preview, `Esc`
  return, and `Enter` focus. This strengthens UI-22.
- Fresh-install checks must stop any old daemon before testing `uvx cmux`, and
  standalone cross-platform runs must not require `bun install` or provider
  PTYs. These are constraints on UI-05 and UI-06, not completion evidence.

The audit also found that detached-owner commit `01bbc358e2` is not an ancestor
of this branch, so its create-or-attach behavior is not documented as current.

## Status key

- **Open**: no acceptance evidence at the audit base.
- **Partial**: an implementation slice exists, but the requested behavior is
  not proven end to end.
- **Implemented, proof open**: the aggregate records a matching code change;
  hosted or runtime proof is still required.
- **No-go**: the request contains a constraint that the current aggregate does
  not satisfy, so completion must not be inferred.

## Deduplicated requests

| ID | Explicit ask and evidence | Status at historical tip `31fc5df2b4` | Acceptance test |
| --- | --- | --- | --- |
| UI-01 | Make every cmux terminal use a separate cmux-tui owner, keep the CLI path coherent, preserve terminals across Swift restart, and define the Swift layout projection. Evidence: `~/.claude/history.jsonl:89411,89422-89442`, 2026-08-19T03:49:41Z to 04:29:21Z UTC; follow-up `~/.claude/history.jsonl:89568`, 2026-08-20T02:57:08Z UTC. | Partial. The aggregate has relay/TUI integration, but the technical-debt board says manual-IO replacement, full restore, and layout ownership remain open. | Start a terminal, quit and reopen the Swift shell, and prove the same PTY, scrollback, cwd, and session ID remain. Exercise the CLI and a right-sidebar projection without creating a second owner. |
| UI-02 | Use journal-first recovery for both a normal cmux restart and a host reboot, with explicit recovery intent and outcome. Evidence: `~/.claude/history.jsonl:89427,89568`, 2026-08-19T04:04:18Z and 2026-08-20T02:57:08Z UTC; `~/.codex/history.jsonl:17612-17614`, 2026-08-07T07:58:12Z to 08:00:03Z UTC. | Open. The aggregate explicitly says reboot checkpoints, full agent restore, and policy-controlled resume are not implemented. | Run clean mux restart with a live host, then host-crash/reboot simulation. The first preserves the live PTY; the second classifies the session interrupted and records one journaled recovery intent and outcome. No secrets or live capabilities enter the journal. |
| UI-03 | Decouple PTYs from layout so one terminal can appear in multiple workspaces and future clients. Evidence: `~/.claude/history.jsonl:89020-89021`, 2026-08-10T04:30:32Z UTC; `~/.codex/history.jsonl:15084`, 2026-07-17T08:05:35Z UTC. | Open. The board still lists PTY ownership and one-worker-per-workspace as an architecture request. | Attach two projections to one terminal, resize and close either projection, and prove one PTY owner, ordered output, no duplicate readers, and no orphan after both detach. |
| UI-04 | Attach to a remote cmux-tui from the machine rail or SSH, and retain per-machine and per-window focus. Evidence: `~/.claude/history.jsonl:87449`, 2026-07-08T05:46:37Z UTC; the related remote-attach request is listed in `TECH-DEBT-BOARD.md` with the 2026-08-04 Codex rollout. | Open. Secure host add/edit, authenticated attach, reconnect, and focus ownership remain acceptance gaps. | Add a host without exposing credentials, attach one remote terminal, reconnect after transport loss, and verify focus state is isolated per machine and cmux window. |
| UI-05 | Build cloud VMs from snapshots containing cmux-tui and common tools, use a two-sidebar machine/workspace layout, and do not use a provider PTY. Evidence: `~/.claude/history.jsonl:87599`, 2026-07-08T21:20:50Z UTC; `89270,89295,89297-89298,89302`, 2026-08-18T04:17:14Z to 06:47:42Z UTC; `~/.codex/history.jsonl:18599-18618`, 2026-08-18T05:44:25Z to 06:37:21Z UTC. | No-go. The aggregate says Cloud TUI and Durable Objects lifecycle are not complete; a snapshot is not proof of live PTY persistence. | Create fresh Daytona, E2B, and Freestyle instances. Verify cmux-tui is present in the base image, owns the PTY, starts with the requested machine/workspace columns, and reports separate snapshot and resume timings. |
| UI-06 | Publish cmux-tui and its SDK so `npx cmux` and `uvx cmux` work, including the Linux binary. Evidence: `~/.claude/history.jsonl:87544`, 2026-07-08T19:50:47Z UTC; `89415`, 2026-08-19T03:53:08Z UTC; the package request is also recorded in `TECH-DEBT-BOARD.md`. | Partial. Packaging and artifact guards exist, but registry-install and executable smoke proof remain open. | Build the exact npm package and six version-matched wheels, install offline on Linux x64 and arm64, verify `RECORD` and executable mode, then run `cmux --help` and an attach/input/resize/reconnect smoke. |
| UI-07 | Expose a stable socket and WebSocket API for custom cmux-tui frontends and the future Swift app. Evidence: `~/.claude/history.jsonl:87839`, 2026-07-10T07:13:46Z UTC. | Partial. Socket contract and fallback hardening landed in the aggregate; cross-transport behavior and custom-client proof remain open. | Use one client for Unix, SSH, WebSocket, and Iroh paths. Subscribe before snapshot, replay ordered events, attach a surface, reconnect, and close with bounded frames and one authenticated workspace contract. |
| UI-08 | Connect a single terminal in cmux-tui through cmux-relay instead of embedding the full TUI screen. Evidence: `~/.claude/history.jsonl:88949`, 2026-08-09T01:49:06Z UTC; `89946`, 2026-08-21T06:16:29Z UTC. | Partial. Single-terminal resources and relay cleanup have code slices, but duplicate-resource and reconnect acceptance is still open. | Attach one existing terminal twice, verify one resource identity and preserved cwd/focus, reconnect after relay loss, then close without an orphan or full-TUI chrome. |
| UI-09 | Stream agent events from cmux-tui to a Durable Object so Pi can subscribe and query history, with no polling and machine identity on each event. Evidence: `~/.claude/history.jsonl:88780`, 2026-08-06T07:35:18Z UTC; `89982,89995`, 2026-08-21T08:25:41Z to 08:46:13Z UTC. | Open. The aggregate explicitly says Durable Objects integration is not implemented. | Emit monotonic event IDs with authenticated machine/session identity, reconnect from a cursor without loss or duplication, bound replay, and reject secrets or live capabilities. Verify event delivery without polling. |
| UI-10 | Make cmux-tui transport work over Iroh for the iOS app. Evidence: `~/.claude/history.jsonl:88576`, 2026-07-30T09:07:25Z UTC; related discovery questions in `~/.codex/history.jsonl:16276-16280`, 2026-07-29T03:33:42Z to 03:45:40Z UTC. | Open. Iroh result delivery has bounds, but authenticated discovery, reconnect, and end-to-end iOS attach are not proven. | Pair two authenticated devices, discover without hidden polling, attach the same session, interrupt the link, reconnect from a cursor, and verify cleanup and focus ownership. |
| UI-11 | Match Ghostty colors and cursor settings, and prove the difference with raw screenshots. Evidence: `~/.claude/history.jsonl:89543,89548-89550`, 2026-08-19T10:55:56Z to 11:01:47Z UTC; `~/.codex/history.jsonl:18402-18403`, 2026-08-15T01:48:02Z UTC. | Partial. Color protocol work exists, but the board records unresolved semantic-color parity and no end-to-end screenshot proof. | Render identical ANSI, OSC, theme-query, and cursor cases in Ghostty and cmux-tui on light and dark backgrounds. Compare screenshots or pixels, including line-cursor configuration, and cover 256-color output. |
| UI-12 | Start a fresh cmux-tui with one session, one workspace, one screen, and one terminal, then support multiple columns for machines and workspaces. Evidence: `~/.codex/history.jsonl:18409`, 2026-08-15T02:57:08Z UTC; `18599-18618`, 2026-08-18T05:44:25Z to 06:37:21Z UTC. | Open. The requested initial-state and cloud multi-column behavior has no complete acceptance evidence. | Launch from a clean state and assert the exact 1/1/1/1 topology. Add a second machine and workspace column, reorder it, reopen the app, and verify stable IDs without duplicate sessions. |
| UI-13 | Prevent stale pane or surface references and self-heal instead of emitting “missing surface” errors. Evidence: `~/.claude/history.jsonl:89203,89205`, 2026-08-17T23:12:13Z to 23:19:18Z UTC. | Open. The aggregate records stale-reference and catalog-refresh work as an open intent. | Delete or replace a surface while an old client holds its reference. The client refreshes the authoritative catalog, closes the dead viewer, and reattaches once with an actionable bounded error if the host is gone. |
| UI-14 | Make cmux-tui usable as an ecosystem with zellij/tmux-level customization and agent launch support. Evidence: `~/.claude/history.jsonl:89374`, 2026-08-19T03:17:21Z UTC; `88261-88262`, 2026-07-27T03:25:20Z to 03:32:03Z UTC. | Open. This is a product backlog, not a completed aggregate behavior. | Define versioned extension and configuration boundaries, launch Codex, Claude, OpenCode, and Pi in separate sessions, and prove that custom layouts and hooks cannot bypass auth or PTY ownership. |
| UI-15 | Keep terminal output responsive under load and avoid TUI freezes. Evidence: `~/.claude/history.jsonl:89921`, 2026-08-21T05:28:16Z UTC; the aggregate board's backpressure and queue blockers apply. | Partial. Queue and frame bounds landed, but sustained-output and disconnect behavior still require hosted proof. | Drive sustained output and resize while attaching multiple clients. Assert bounded memory, fair input, no frozen btop or dropped accepted bytes, explicit overload, and deterministic shutdown. |
| UI-16 | Eliminate persistent blank space after Claude Code TUI resize or split. Evidence: `~/.claude/transcripts/ses_2a8f488aa0ffekX6csDX94egh16.jsonl:1`, 2026-04-04T05:50:49Z UTC; follow-up `ses_2a8f48aa0ffekX6csDX94egh16.jsonl:1`, 2026-04-04T05:51:01Z UTC. | Open. The request reports repeated failures after six attempted fixes; no aggregate closure is recorded. | Reproduce window drag and Cmd-D split with Claude Code TUI, capture grid, scroll-view document height, offset, and frame on every resize, and prove no blank rows across repeated transitions. |
| UI-17 | Map a freshly spawned Codex TUI session to its exact cmux surface, including two same-cwd launches under 10 ms, then restore it after reopen. Evidence: `~/.claude/transcripts/ses_25cee6607ffebXFO2sT2wguI3w.jsonl:1`, 2026-04-19T00:09:01Z UTC. | Open. The transcript states that TUI mode does not expose the ID on stdout; no exact ownership proof is recorded. | Launch two same-cwd sessions less than 10 ms apart, record each durable session ID before surface association, kill and reopen cmux, and assert each session resumes only in its original surface. |
| UI-18 | Add a multilingual and emoji glyph-rendering fixture for the Star Wars failure. Evidence: `~/.codex/transcription-history.jsonl:3`, record `ccc037fb-aff5-4bb0-909b-0979d129ee41`. | Open. No runnable corpus or cell-width/screenshot assertion is recorded. | Render broad multilingual and emoji input in the TUI, capture cell widths and pixels, and assert stable glyph placement across resize and redraw. |
| UI-19 | Keep the cmux-relay and cmux-tui boundary narrow while deciding where machine event monitoring belongs. Evidence: `~/.claude/history.jsonl:90021`, 2026-08-21T09:50:13Z UTC; the request explicitly raises attack-surface risk. | Open. No documented threat model or ownership decision records which event, alarm, and monitoring capabilities belong in relay versus TUI. | Write the capability boundary and threat model. Prove that untrusted machine events cannot gain TUI control-plane or PTY authority, and that relay authentication and authorization remain enforced. |
| UI-20 | Support diffs.com and trees.software-style editing and tree workflows in the cmux ecosystem, while deciding what belongs in snapshots, cmux-tui, or cmux-relay. Evidence: `~/.claude/history.jsonl:90028`, 2026-08-21T10:08:43Z UTC; related cmux-tui ownership question at `90036`. | Open. This is a broad product request with no scoped feature contract, snapshot inventory, or security review. | Define a smallest feature slice and ownership matrix first. Reject arbitrary snapshot software and relay capabilities until trust boundaries, package provenance, and PTY ownership are specified and tested. |
| UI-21 | Provide secure `tui-use` tools for Pi and codemode to talk to only the sandboxes returned by the list-sandbox capability, using cmux-tui instead of tmux and reusing cmux journal hooks where appropriate. Evidence: `~/.codex/history.jsonl:18183`, 2026-08-12T07:50:27Z UTC (embedded session transcript request). | Open. No scoped tool contract, sandbox capability binding, cmux-tui transport proof, or journal-hook readiness evidence is recorded. | Enumerate sandboxes through an authenticated capability, bind each tool call to an allowlisted sandbox and cmux-tui session, reject arbitrary targets and tmux fallbacks, and prove Pi and codemode attach/input/exit behavior plus journal hook privacy and reconnect semantics. |
| UI-22 | Fix terminal resize, show an empty/action screen instead of forcing a new conversation when opening an empty space, clarify libghostty-web/Atlas renderer use and direct cmux-tui connectivity, and support left-sidebar `hjkl` preview with `Esc` return and `Enter` focus. Evidence: `~/.codex/sessions/2026/08/24/rollout-2026-08-24T15-02-29-01a035cb-e2ca-7c42-9fb0-421942de9005.jsonl`, 2026-08-24T22:02:35.904Z UTC; `~/.codex/history.jsonl:18749`, 2026-08-24 UTC. | Open. No end-to-end resize proof, empty-space state contract, renderer ownership statement, direct transport proof, or keyboard-preview proof is recorded. | Resize both directions repeatedly, open an empty space and verify only the intended actions or existing content, exercise `hjkl` preview, `Esc`, and `Enter`, then document and test the renderer and cmux-tui transport path. |
| UI-23 | Let Chatmux spawn isolated sandboxes and start Claude Code or Codex inside cmux-tui, with lifecycle hooks, stop detection, and provider authentication. Evidence: `~/.claude/history.jsonl:90216`, 2026-08-24T22:13:18Z UTC. | Open. No sandbox-to-session binding, agent launch contract, stop hook, or Bedrock/CodeRouter authentication proof is recorded. | Create two isolated sandboxes, launch Claude Code and Codex with their approved providers, observe start/stop events, and prove each TUI session maps to its sandbox without cross-target access or orphan processes. |
| UI-24 | Give products built on cmux-tui their own isolated TUI sessions, and evaluate rebuilding Firstmate on the cmux-tui primitives. Evidence: `~/.claude/history.jsonl:90220`, 2026-08-24T22:19:40Z UTC. | Open. No product-session namespace, isolation policy, or Firstmate feasibility scope is documented. | Launch two product sessions with independent IDs, layouts, PTYs, and auth capabilities. Write a bounded Firstmate feasibility slice and reject any design that shares a PTY owner or bypasses the cmux-tui control boundary. |

## Aggregate residuals that affect these asks

UI-25: workflow selector and CLI workflow controls must share one stable action path, preserve provider/workflow identity, and report unavailable selectors. This remains open pending interactive-selector and CLI behavior proof.

The linked technical-debt board is authoritative for implementation status. At
this audit base it records no local Rust compile or test evidence, incomplete
generic relay child cancellation and reaping, no Durable Objects integration,
open manual-IO and full-restore work, and open Cloud TUI acceptance. These
residuals prevent a green source diff from being treated as user-visible proof.

## Audit method and limitations

- I searched only targeted records in `~/.claude/history.jsonl`, selected
  `~/.claude/transcripts/*.jsonl`, `~/.codex/history.jsonl`, and selected dated
  Codex rollout files. Patterns were limited to `cmux-tui`, `cmux tui`, `TUI`,
  `PTY`, `journal`, `snapshot`, `relay`, `surface`, and related request terms.
- Repeated prompts were grouped by requested outcome. A row is not evidence
  that the user accepted an implementation.
- Timestamps are UTC. History files can receive new records after this audit;
  line numbers and statuses can therefore become stale.
- Encrypted inter-agent payloads, tool output, credentials, secret-file
  contents, and unrelated repositories were excluded. The board records only
  paths, timestamps, and short summaries.
- This is a narrow intent audit, not an exhaustive search of every session.
  Requests phrased without the selected terms, requests hidden in transferred
  context, and requests in capped candidate lists may be missing.
