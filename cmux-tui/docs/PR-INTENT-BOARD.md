# cmux TUI PR intent and merge board

## Wave 90 live reconciliation

Snapshot: 2026-08-28T10:00:00Z. Main: `eae7f14c2dc1a3afb83d98ed0ad9e97fab3d6689`. Merged #10990 `2608c8ca279f26c188723e95f31e6ac287439423` -> `fa77ad23364aa12993644b357b425513d61ca632`, #11056 `433e1f5ec237476077e7a50eceeb1c39547fc0ff` -> `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`, and #11072 `7cf4ed0b96fb1bc22b2a2823dc81d3164ebbd60d` -> `253df2472973a5654e1a3d7fee13764a177c7a79`. Open heads: #11024 `af704da816ae03268c0b9e8f52125aead38c0fe2`, #11025 `3fa7ca2bfa328cd4a7efde9d9ddc220e1e1a2ec0`, #11028 `5597886950825ea955c6335b63aee5d3dc405a40`, #11055 `b55c52708c159651d49674361a1c37d004b63402`, #11013 `153da71049bedd0be81490330ffbc8f83e0f924b`, #10994 `f184e4afbc94eaf451844dfb9cf6ece8b78dd0da`. Deferred blockers remain #11002, #11068, #11078, #11063, and #10401. Session count remains unknown.

## Wave 85 current state: main `0ab1edc814b7aaae23e458a3b73e34adfcd60438`

Snapshot: 2026-08-28T09:47:54Z.

| Merged PR | Author | Source head | Merge SHA | Intent result |
| --- | --- | --- | --- | --- |
| [#11072](https://github.com/manaflow-ai/cmux/pull/11072) | Lawrence Chen | `7cf4ed0b96fb1bc22b2a2823dc81d3164ebbd60d` | `253df2472973a5654e1a3d7fee13764a177c7a79` | cmux-tui runtime shutdown now has one cleanup path with preserved teardown order. |
| [#11069](https://github.com/manaflow-ai/cmux/pull/11069) | Lawrence Chen | `d9646e350bcd5db20458899ff66f4a19df9d0a14` | `f756735566a2ce16bad450a8ab592fef2a40d9c4` | Cloud-tree actions, confirmations, double-click behavior, and drag gating are on main. |
| [#11056](https://github.com/manaflow-ai/cmux/pull/11056) | Lawrence Chen | `433e1f5ec237476077e7a50eceeb1c39547fc0ff` | `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` | Retained-tab reindexing now uses one pass and preserves duplicate-ID and clamp behavior. |
| [#10988](https://github.com/manaflow-ai/cmux/pull/10988) | Lawrence Chen | `e12ce402fc760a9d51dceee2faba1331f59855cd` | `e7584a4c4a25b2e4fe400b67ab19b7c7ec3a5f11` | Fixed synchronization waits were removed and timeout scaling was corrected. |
| [#10987](https://github.com/manaflow-ai/cmux/pull/10987) | Lawrence Chen | `4cbf023af8e4552fa0f6aa95755ea7d7a0336798` | `7da4c0f6ce14e5ddf71e90f05dc67d29980fda69` | Intent and technical-debt boards were refreshed through #10985. |

| Open gate | Author | Exact head and state | Required next action |
| --- | --- | --- | --- |
| [#11024](https://github.com/manaflow-ai/cmux/pull/11024) | Lawrence Chen | `9dcf978bda0ed1675f88d20e76198ebc1033c986`, open on base `fa77ad23364aa12993644b357b425513d61ca632` | Finish exact review and focused restart, stale-hook, and public-projection tests. |
| [#11025](https://github.com/manaflow-ai/cmux/pull/11025) | Lawrence Chen | `685c924e866113d1457e89a2bd9469e5fb219e6a`, open on base `1e09970237f21686b8c0e6853b51a89819623803` | Finish exact review and focused pointer-routing tests. |
| [#11028](https://github.com/manaflow-ai/cmux/pull/11028) | Lawrence Chen | `5ca760526fed25225b135f99b238a9a0fd7ac7e9`, open on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` | Finish exact review and hosted Unicode conformance. |
| [#10990](https://github.com/manaflow-ai/cmux/pull/10990) | Lawrence Chen | `2608c8ca279f26c188723e95f31e6ac287439423`, merged at `fa77ad23364aa12993644b357b425513d61ca632` | Retain the merged privacy and durability evidence. |
| [#11055](https://github.com/manaflow-ai/cmux/pull/11055) | Lawrence Chen | `8f2287a00a490a6e00d09140cccb69a75f58e2e4`, open on base `fa77ad23364aa12993644b357b425513d61ca632` | Run the dirty-surface hosted test. |

Blocked or deferred: [#11002](https://github.com/manaflow-ai/cmux/pull/11002) and [#11068](https://github.com/manaflow-ai/cmux/pull/11068) are open, mergeable, and clean on stale bases `c582b8d74ab82e404f18b14ad4e97f2d4cc04fa9` and `ed19cfa5cb88d6e0fae683bbe4a733bd4e2d062c`; they need the reducer ownership and parity findings resolved. [#11013](https://github.com/manaflow-ai/cmux/pull/11013) is open, mergeable, and clean on stale base `f8eb151b589892f0e9dea96e5735c6afaea20d9` and has incomplete CDP privacy coverage. Stacked [#11078](https://github.com/manaflow-ai/cmux/pull/11078), head `46fe5348e2631769c4e9482e1127ad0c75a8dbff`, is conflicting on base `5f4083e33374416f1a6290bbd495319ce97f5199`. [#10994](https://github.com/manaflow-ai/cmux/pull/10994), head `f334fdc95394f952d8f30690f5c0560286e03ad2`, is open and mergeable on `main` at `1e09970237f21686b8c0e6853b51a89819623803`. [#11063](https://github.com/manaflow-ai/cmux/pull/11063), head `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6`, is open, mergeable, and clean on stale base `ba64d22c81aa716f79fedb95bc758fc8f7b7c29b`, and is round 1 only. [#10401](https://github.com/manaflow-ai/cmux/pull/10401), head `46590bacaed87fba46d4ceb5cdacadcafad07833`, is conflicting and dirty on stale base `2c6fd70ecceeed63fdb549882737c6563fb3f52d` and still lacks drag-into-terminal behavior.

Strict session accounting: confirmed turns `0`; total `unknown`. The five documented owner workstreams are the practical evidence floor. The audit retains a conservative lower bound of 50 and a historical ledger of at least 258 named substantive turns. Neither is a total, and no 10,000-session claim is made.

## Wave 84 current state: main `305519d149c1ca61d4be4838e18b0a59f8e69b2a`

Snapshot: 2026-08-28T07:43:00Z. Merged TUI work includes [#11072](https://github.com/manaflow-ai/cmux/pull/11072) by Lawrence Chen (`253df2472973a5654e1a3d7fee13764a177c7a79`), [#11041](https://github.com/manaflow-ai/cmux/pull/11041) by Lawrence Chen (`305519d149c1ca61d4be4838e18b0a59f8e69b2a`), [#11000](https://github.com/manaflow-ai/cmux/pull/11000) by Lawrence Chen (`8910e6360e3b1d8b05b875cbe44e1901e8c7fc60`), [#11045](https://github.com/manaflow-ai/cmux/pull/11045) by Lawrence Chen (`8d71d72e6de027074828d7d81443b1f8ec825283`), and [#11044](https://github.com/manaflow-ai/cmux/pull/11044) by Lawrence Chen (`c33d38ab80166e7ca525d197faf93d1f918f55f2`).

| Intent | PR and author | Exact head and state | Required next action |
| --- | --- | --- | --- |
| Ordered agent lifecycle and restart-safe suppression | [#11024](https://github.com/manaflow-ai/cmux/pull/11024), Lawrence Chen | `d3bb50772cdca64586304e5afcfec5f3a222fe1a`, open, mergeable, exact review and hosted gate running | Finish exact-head review, then require the focused restart, stale-hook, and public-projection checks before merge. |
| Allocation-free graphics projection | [#11055](https://github.com/manaflow-ai/cmux/pull/11055), Lawrence Chen | `eea8a5c16f45de1417599d626b00c1f5fae83c39`, open, current base rebase pending | Rebase onto current main, review the one-file change, and run the dirty-surface hosted test. |
| One-pass retained sidebar filtering | [#11056](https://github.com/manaflow-ai/cmux/pull/11056), Lawrence Chen | `bd633d481f64baef38de9ca657e57d19543053ee`, open, exact gate in progress | Confirm out-of-range and duplicate-ID behavior in the hosted test, then merge if the exact review is clean. |
| Private config replacement | [#10990](https://github.com/manaflow-ai/cmux/pull/10990), Lawrence Chen | `69241f5f7a044bc797cf579b84c5fb546b4601db`, open, mergeable; hosted gate pending | Complete exact review and verify locale, collision retry, and parent durability behavior. |
| Journal reducer foundation | [#11002](https://github.com/manaflow-ai/cmux/pull/11002), Lawrence Chen | `8da5643df4d89ecf4b3a0abad5809241c57e6b1d`, open, based on an old foundation | Do not merge until the durable cursor, tombstone filtering, crash recovery, and bounded replay design is resolved. |
| Screen-detection parity | [#11068](https://github.com/manaflow-ai/cmux/pull/11068), Lawrence Chen | `b3eca00fd03dd76763bd5273066df2779c236abc`, open, stacked on old reducer; review findings pending | Rebase after the reducer decision, resolve the eight CodeRabbit findings, and add exact parity tests. |
| Bounded CDP outbound queue | [#11013](https://github.com/manaflow-ai/cmux/pull/11013), Lawrence Chen | `5f4083e33374416f1a6290bbd495319ce97f5199`, open, clean but broad privacy work remains | Separate public error text from diagnostics across all raw CDP paths, then run an exact transport test. |
| ACK overflow redaction | [#11078](https://github.com/manaflow-ai/cmux/pull/11078), Lawrence Chen | `46fe5348e2631769c4e9482e1127ad0c75a8dbff`, open, conflicting stacked branch | Retarget or transplant the clean one-line fix onto #11013; do not merge the conflicting stack. |
| Harbor tree and drag interaction | [#11063](https://github.com/manaflow-ai/cmux/pull/11063), Lawrence Chen | `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6`, open, round 1 flat panel | Build a follow-up tree with explicit host/tool/session/workspace/window/terminal ownership, drag payloads, cloud manual I/O, and no nested TUI. |
| Drag agent into terminal | [#10401](https://github.com/manaflow-ai/cmux/pull/10401), Lawrence Chen | `46590bacaed87fba46d4ceb5cdacadcafad07833`, open, conflicting | Rebase the follow-up and prove a dropped session opens the target terminal without text injection. |

Strict session count is `unknown`; the retained 258 named-turn figure is only an older lower bound. No 10,000-session claim is supported.

## Wave 83 follow-up: main `989293cdb9058500f51d6c9b8e4f3795e67997ce`

Snapshot: 2026-08-28T06:56:33Z. Recent merged PRs are [#11066](https://github.com/manaflow-ai/cmux/pull/11066) by Abdulaziz Albahar, source `553f1a471d8451eb695d4a6e414d68eaba550c6d`, merge `8a7b4b5c4a7ad4af2851303b27bd17327d15d7d8`; [#11000](https://github.com/manaflow-ai/cmux/pull/11000) by Lawrence Chen, source `d83a0ec65f3fa5d064fa342a6d13c519696cba0e`, merge `8910e6360e3b1d8b05b875cbe44e1901e8c7fc60`; [#11018](https://github.com/manaflow-ai/cmux/pull/11018) by Abdulaziz Albahar, source `070fd65f127cb3cd00f8efebf3adbcb99c39f5b8`, merge `ed19cfa5cb88d6e0fae683bbe4a733bd4e2d062c`; [#10838](https://github.com/manaflow-ai/cmux/pull/10838) by Austin Wang, source `0afec52b7c248445b08d337e766d71cfa612b9fc`, merge `c1e7f094cea7b1a1dbe21b48bc43e01c41b2d1c4`; and [#10326](https://github.com/manaflow-ai/cmux/pull/10326) by Austin Wang, source `a1826532091fed085768dcf5c0469f2423fa1a84`, merge `989293cdb9058500f51d6c9b8e4f3795e67997ce`.

| Intent | PR and author | Exact head and state | Required next action |
| --- | --- | --- | --- |
| Harbor filesystem-tree redesign | [#11063](https://github.com/manaflow-ai/cmux/pull/11063), Lawrence Chen | `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6` on `feat-tui-manual-io`, open and mergeable; round 1 only | Open a redesign follow-up for the host, tool, session, workspace, window/tab, terminal tree, draggable terminals, cloud manual I/O, and no nested TUI rendering. |
| Herdr/Codex parity | [#11068](https://github.com/manaflow-ai/cmux/pull/11068), Lawrence Chen | `04380edc86d1f5033b71341ddc97cb4738c26e4f`, open; GitHub mergeability changed during the audit, and checks and review are pending; CodeRabbit review at 2026-08-28T06:14:55Z reports eight actionable comments | Resolve fail-closed identity, lowercase-region reuse, `HashSet` retention, monotonic snapshots, maintained attention ordering, Grok priority, Qwen working detection, and the remaining seen-bit, wait-for-state, manifest refresh, filter, visible-blocker, wrapper identity, Windows, and OSC gaps. |
| Post-audit cmux-TUI security sweep | No dedicated PR yet | Codex session `01a04659-67b5-7e73-af85-20019325aae6`; user receipts `~/.codex/history.jsonl:18868-18869`; screening remains in progress, with no final result or PR link | Finish the post-audit review of TUI PRs, publish exact findings and fixes, and attach exact-head checks with secret-safe logs. |
| Drag agents into terminals | [#10401](https://github.com/manaflow-ai/cmux/pull/10401), Lawrence Chen | `46590bacaed87fba46d4ceb5cdacadcafad07833`, open and conflicting | Rebase and implement the follow-up UTType, `.draggable`, and terminal drop route. Preserve working-directory context and reject text insertion when a session is dropped over the terminal. |

Design references: Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/) retains only the newest value, [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/) delivers each value to receivers, and Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html) owns draw and buffer-diff state.

## Current reconciliation: main `2c6fd70ecceeed63fdb549882737c6563fb3f52d`

Snapshot: 2026-08-28T05:18:38Z. Current main includes these recent merges,
with exact source and merge SHAs. Authors are included for each PR.

| Merged PR | Author | Source head | Merge SHA |
| --- | --- | --- | --- |
| [#11022](https://github.com/manaflow-ai/cmux/pull/11022) | Abdulaziz Albahar | `eaf542ca7b34607d621a48367dbd2958915b0296` | `2c6fd70ecceeed63fdb549882737c6563fb3f52d` |
| [#11045](https://github.com/manaflow-ai/cmux/pull/11045) | Lawrence Chen | `118ae063aba8736d7c16d9b3a3cd5c6ee5dfcb2c` | `8d71d72e6de027074828d7d81443b1f8ec825283` |
| [#11039](https://github.com/manaflow-ai/cmux/pull/11039) | Lawrence Chen | `d3f97bfcd8e848abf3c527b1683f5eed8c719fea` | `c1151eaf7addbb49bdcf40c053abe059fcef2db5` |
| [#11044](https://github.com/manaflow-ai/cmux/pull/11044) | Lawrence Chen | `a2df7e8a629c20b583d04812e070356fdcd2c562` | `c33d38ab80166e7ca525d197faf93d1f918f55f2` |
| [#11012](https://github.com/manaflow-ai/cmux/pull/11012) | Lawrence Chen | `8d118f410fa32fbff94b34e3317719015c56d3b4` | `d0b3b737a26f6afa6565b6c0160a31700abe6e21` |
| [#11047](https://github.com/manaflow-ai/cmux/pull/11047) | Abdulaziz Albahar | `73199b36436843c7a420cf86027cf363ee9e36db` | `aa7c9221ac576d01e033a23f9f3f46b9afec22cb` |
| [#11021](https://github.com/manaflow-ai/cmux/pull/11021) | Lawrence Chen | `f59f21a7f34992d481667ffb87cbcc9dbfc0e8fa` | `2c6035573e5edab568da035e99c713acecfc1d70` |
| [#11026](https://github.com/manaflow-ai/cmux/pull/11026) | Lawrence Chen | `cd55ac6e3cda48f0660d1c3a93923b551341464f` | `c582b8d74ab82e404f18b14ad4e97f2d4cc04fa9` |

New intent-to-PR mapping and blockers:

| Intent | PR and author | Exact head and state | Required next action |
| --- | --- | --- | --- |
| Mobile key-to-pixel latency attribution | [#11005](https://github.com/manaflow-ai/cmux/pull/11005), Lawrence Chen | `8c3bb260504f50b622158b5ce884f573ddf1c6f5`, open and mergeable | Add Mac/DO, PTY-write, and pixel-present stamps. |
| Direct Durable Object authentication | [#10963](https://github.com/manaflow-ai/cmux/pull/10963), Lawrence Chen | `ba65199cf505729eddc27373b9497b9573bc9f97`, open and mergeable | Resolve auth-policy, keepalive cancellation, singleton, and cleanup findings before merge. |
| Live topology authority | [#10999](https://github.com/manaflow-ai/cmux/pull/10999), Abdulaziz Albahar | `20fef437ec377559c7669d257d999bb48228150e`, open and conflicting | Rebase, then reconcile DO facts with the local daemon/journal owner. |
| Unified external-session catalog | [#10828](https://github.com/manaflow-ai/cmux/pull/10828), Lawrence Chen | `a5d3ff37abe933373237813325c84870df7242cd`, open and conflicting | Define stable local/SSH source IDs and manual-I/O attach lifecycle. |
| Agent-roster follow-up | [#10966](https://github.com/manaflow-ai/cmux/pull/10966), Lawrence Chen | `3885306fb27853a60732dbbbf79fe44d172f2949`, open and conflicting | Rebase and cover Claude, Codex, and Herdr exit and attention events. |
| Cloud manual-I/O policy | [#10321](https://github.com/manaflow-ai/cmux/pull/10321), Lawrence Chen | `c0501c00a3462ac48ce01ead37ff019628e23617`, open and conflicting | Keep manual I/O cloud-only, add reconnect/error states, and leave local creation unchanged. |

Design references: Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/)
retains only the newest value, Tokio [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/)
delivers each value to receivers, and Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html)
owns draw and buffer-diff passes. SQLite [`WAL`](https://www.sqlite.org/wal.html)
requires same-host shared memory and still permits one writer at a time.

## Current reconciliation: main `6964584c030eec3e46c81545ff9e3c49ff1730ca`

Snapshot: 2026-08-28T04:10:00Z. Recent merged intent is recorded with author,
merge SHA, and rollback in `TECH-DEBT-BOARD.md`: [#11019](https://github.com/manaflow-ai/cmux/pull/11019),
[#11026](https://github.com/manaflow-ai/cmux/pull/11026), [#11036](https://github.com/manaflow-ai/cmux/pull/11036),
[#11030](https://github.com/manaflow-ai/cmux/pull/11030), [#11034](https://github.com/manaflow-ai/cmux/pull/11034),
and [#10948](https://github.com/manaflow-ai/cmux/pull/10948). Current direct TUI
intent remains open in [#10969](https://github.com/manaflow-ai/cmux/pull/10969),
[#10990](https://github.com/manaflow-ai/cmux/pull/10990), [#10994](https://github.com/manaflow-ai/cmux/pull/10994),
[#11000](https://github.com/manaflow-ai/cmux/pull/11000), [#11013](https://github.com/manaflow-ai/cmux/pull/11013),
[#11024](https://github.com/manaflow-ai/cmux/pull/11024), [#11025](https://github.com/manaflow-ai/cmux/pull/11025),
[#11028](https://github.com/manaflow-ai/cmux/pull/11028), [#11041](https://github.com/manaflow-ai/cmux/pull/11041),
and [#11044](https://github.com/manaflow-ai/cmux/pull/11044). Heads and checks
are intentionally not copied here because they expire on every rebase.

The session-mined user-request rows remain acceptance criteria, not completion
claims. In particular, PTY ownership/restart recovery, canonical multi-device
sessions, resize blank-space removal, remote attach parity, alternate-screen
wheel behavior, and Claude completion subscriptions remain open unless a later
row cites behavior evidence. Strict session count is `unknown`; no 10,000 count
is claimed.

## Current reconciliation: main `e27710a23149d9412665ef786b688797006b2730`

Audit basis: 2026-08-28T01:15:00Z. Main includes merged #10995, source `a156463ea61f00bc9e67e16e27ed3f38d3329417`, merge `e27710a23149d9412665ef786b688797006b2730`. Live direct-TUI open heads: #10990 `9b2a78bf2021308fb311dd87f76da9825ee732eb`, #11000 `4ac679e7088096b80f4f792f987dc8197dc401b1`, #11013 `492f121cce5c6d1d72e7e7514d645a77c949b6ef`, #11024 `5f433c2fad7c3d755bbdcc618fa2c0c08cf88fdc`, #11025 `c05536313caf91a84e9f1e4065693a1b263ca4c3`, and #11026 `9160518271afc399f471569f6e3e288254511966`. Issue #11027 remains open. Strict confirmed turns: `0`; total: `unknown`.

Audit basis: 2026-08-27T19:39:39Z. Main currently includes the following
cmux-tui merge log: [#10984](https://github.com/manaflow-ai/cmux/pull/10984)
`e9543607420f7b3b3284ac4c71ea21918dea692e`, [#10975](https://github.com/manaflow-ai/cmux/pull/10975)
`46958aa58d171a01af7a5b1f06164f18d8639612`, [#10986](https://github.com/manaflow-ai/cmux/pull/10986)
`b5023a455618dd3d4885da2605e162b0bdb67790`, [#10982](https://github.com/manaflow-ai/cmux/pull/10982)
`642a65b1512d0d61aaef88290f90ef3408bbee74`, [#10985](https://github.com/manaflow-ai/cmux/pull/10985)
`2b61ecafceb4b1c008b6f07345270615a0fb4286`, and [#10612](https://github.com/manaflow-ai/cmux/pull/10612)
`af31628f7b0b2f6c34e184049254fa2fe91f285d`. The working branch remains documentation only.

The latest session reconciliation found no durable session identifiers for a
strict turn count, so the strict auditable count is `unknown` (not zero). It
found five documented substantive owner workstreams. A branch proxy
has 96 TUI references and 78 substantive non-merge commits; this is not a turn
count. Unresolved Claude history intent IDs are `1787650444261` and
`1787650724161` (state ownership, manual I/O, reconnect), `1787722163382` and
`1787723964393` (remove the Go daemon, use direct TUI I/O and tunnels),
`1787733887926` and `1787780735531` (machine terminals, VNC screens, attach,
event parity), `1787794506089` (cloud tree per machine), `1787823710241`
(top/bottom sidebar split), `1787825896700` (alternate-screen wheel arrows),
and `1787826030510` (Claude completion subscriptions). No transcript proves
these intents complete.

## Historical refresh: main `2b61ecafceb4b1c008b6f07345270615a0fb4286`

Snapshot: 2026-08-27T18:44:45Z. This docs-only refresh pins the exact main
baseline [`2b61ecafceb4b1c008b6f07345270615a0fb4286`](https://github.com/manaflow-ai/cmux/commit/2b61ecafceb4b1c008b6f07345270615a0fb4286).
No Rust, Zig, runtime build, or runtime test ran.

| Merged PR | Author | Source head | Merge SHA | Exact run | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10982](https://github.com/manaflow-ai/cmux/pull/10982) | Lawrence Chen | `1e0c3eefaf43e733c967131199361d587f56a34b` | `642a65b1512d0d61aaef88290f90ef3408bbee74` | [33100547866](https://github.com/manaflow-ai/cmux/actions/runs/33100547866) passed; CodeRabbit comment-only | `git revert 642a65b1512d0d61aaef88290f90ef3408bbee74` |
| [#10985](https://github.com/manaflow-ai/cmux/pull/10985) | Lawrence Chen | `f32d788d1cb503fb7cddf50e70fc40d0e067ec4e` | `2b61ecafceb4b1c008b6f07345270615a0fb4286` | [33103012053](https://github.com/manaflow-ai/cmux/actions/runs/33103012053) and [33103010095](https://github.com/manaflow-ai/cmux/actions/runs/33103010095) passed; CodeRabbit comment-only | `git revert 2b61ecafceb4b1c008b6f07345270615a0fb4286` |

| Live PR | Exact head | Current runs | Review and gate |
| --- | --- | --- | --- |
| [#10966](https://github.com/manaflow-ai/cmux/pull/10966), Lawrence Chen | `dda134e95835a415d6cce062e896367ad30c3a94` on `2b61ecafceb4b1c008b6f07345270615a0fb4286` | [33104657912](https://github.com/manaflow-ai/cmux/actions/runs/33104657912), [33104745426](https://github.com/manaflow-ai/cmux/actions/runs/33104745426), in progress | Mergeable; five CodeRabbit comment-only reviews, no approval |
| [#10969](https://github.com/manaflow-ai/cmux/pull/10969), Lawrence Chen | `0a89a140738c68d105ddd7d1cf5bbcb1e713bb02` on `2b61ecafceb4b1c008b6f07345270615a0fb4286` | [33104519612](https://github.com/manaflow-ai/cmux/actions/runs/33104519612), [33104514655](https://github.com/manaflow-ai/cmux/actions/runs/33104514655), in progress | Mergeable; one CodeRabbit comment-only review, no approval |
| [#10612](https://github.com/manaflow-ai/cmux/pull/10612), Lawrence Chen | `ddc15ed4d7fc737cf86e9bd4bf2adc8bd1ebf5fa` on stale `642a65b1512d0d61aaef88290f90ef3408bbee74` | [33103112353](https://github.com/manaflow-ai/cmux/actions/runs/33103112353), [33103077154](https://github.com/manaflow-ai/cmux/actions/runs/33103077154), passed | Greptile, Codex connector, and CodeRabbit comment-only reviews; rebase and rerun |
| [#10891](https://github.com/manaflow-ai/cmux/pull/10891), Lawrence Chen | `e16aa8c35bbb1fafa7b3cb1340f872754c66d6a7` on stale `642a65b1512d0d61aaef88290f90ef3408bbee74` | [33104968098](https://github.com/manaflow-ai/cmux/actions/runs/33104968098) queued; [33104965438](https://github.com/manaflow-ai/cmux/actions/runs/33104965438) in progress | Mergeability unknown; five CodeRabbit reviews apply to earlier heads |

Closed without merge: [#9806](https://github.com/manaflow-ai/cmux/pull/9806)
`406529665e5494ca559acab47079d8e7fb274386`, [#9813](https://github.com/manaflow-ai/cmux/pull/9813)
`3b8d500aa23cfe9a7fbbe4a1dbdcf1be19902c61`, [#10136](https://github.com/manaflow-ai/cmux/pull/10136)
`0786b6b37e5a397c1acc15b14be4a89f4363117b`, [#10413](https://github.com/manaflow-ai/cmux/pull/10413)
`891544e0ab1f1ab277213b984e7f53078374fb63`, [#10237](https://github.com/manaflow-ai/cmux/pull/10237)
`187dffe3e181fd6a85f99dc3fec2244c4fbe6fff`, [#10267](https://github.com/manaflow-ai/cmux/pull/10267)
`7c8e4130737cf15f81086603364b587b13c05f40`, and [#10746](https://github.com/manaflow-ai/cmux/pull/10746)
`9fa4c1497719f3c205ce6d402b3ce338d7fd5504`. They did not change main, so no
rollback applies. Their replacements are #10134, #10259, #10521, #10263,
#10268, and merged [#10985](https://github.com/manaflow-ai/cmux/pull/10985).

Issues [#10881](https://github.com/manaflow-ai/cmux/issues/10881) and
[#10394](https://github.com/manaflow-ai/cmux/issues/10394) closed as completed
after merged [#10954](https://github.com/manaflow-ai/cmux/pull/10954). Browser
[#335](https://github.com/manaflow-ai/cmux/pull/335) is resolved by merge
`5697f71fc6956729524a76a5f17d5611c3ff485b`; rollback:
`git revert 5697f71fc6956729524a76a5f17d5611c3ff485b`.

No new session scan ran. The retained receipt proves at least 258 named
substantive turns, a lower bound rather than a total. No 10,000-session claim
is made. Later code merges require one final refresh.

Historical snapshot: 2026-08-27T13:05:00Z. This board was pinned to
`origin/main` at [`87f31977237cbcbbf8b7f492718685d612fbb9b0`](https://github.com/manaflow-ai/cmux/commit/87f31977237cbcbbf8b7f492718685d612fbb9b0),
committed 2026-08-27T05:49:57-07:00 with subject
`Integrate Escape passthrough fix from PR #9810 (#10959)`. The working branch
contains documentation only. The prior `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`
snapshot, captured at 2026-08-27T09:54:48Z, and the earlier
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshot are retained below as
historical evidence. Open-PR heads and check rollups in those inventories must
be re-queried before a merge decision.

The current main tail includes [#10936](https://github.com/manaflow-ai/cmux/pull/10936),
[#10944](https://github.com/manaflow-ai/cmux/pull/10944), and
[#10950](https://github.com/manaflow-ai/cmux/pull/10950), plus merged
[#10954](https://github.com/manaflow-ai/cmux/pull/10954),
[#10958](https://github.com/manaflow-ai/cmux/pull/10958),
[#10962](https://github.com/manaflow-ai/cmux/pull/10962), and
[#10951](https://github.com/manaflow-ai/cmux/pull/10951), and
[#10972](https://github.com/manaflow-ai/cmux/pull/10972), and
[#10959](https://github.com/manaflow-ai/cmux/pull/10959). The latest merge adds
Escape passthrough after the startup, redraw, frame-area, diagnostics, and
draw/paint render-path tail. Source heads, authors, merge times, and merge
commits are recorded below.
Individual rollback commands are in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).

| PR | Author | Source head | Merged at (UTC) | Merge SHA |
| --- | --- | --- | --- | --- |
| [#10941](https://github.com/manaflow-ai/cmux/pull/10941) | Lawrence Chen | `122a4ff210c50dea21e12846c276849047b16357` | 2026-08-27 07:14:20 | `6641abe023f3ab175fd910b547316fc00bf523ee` |
| [#10940](https://github.com/manaflow-ai/cmux/pull/10940) | Lawrence Chen | `ab2e3d314285d0512280821711b518fae14c2557` | 2026-08-27 07:21:34 | `e6895d94d8fba491e823e3550dda6727cdd87d33` |
| [#10938](https://github.com/manaflow-ai/cmux/pull/10938) | Lawrence Chen | `e9162bfbf4bdbabcd68ffa4461011262229740fe` | 2026-08-27 07:22:50 | `d0f1d94c431cd41947133f7d9406968ee70a7fc7` |
| [#10935](https://github.com/manaflow-ai/cmux/pull/10935) | Lawrence Chen | `f6e9d9e9353c629fa42ff44b65a1074972384b3b` | 2026-08-27 07:37:37 | `502ed87921f4ea933e30cfe8e5bb5aed0b4dad50` |
| [#10932](https://github.com/manaflow-ai/cmux/pull/10932) | Lawrence Chen | `79d5bda289b5ff5e87e8714fd6f3f69f7e7e88fb` | 2026-08-27 07:38:07 | `6e67b662c649096b7133eaace8059cd4420a6ba6` |
| [#10937](https://github.com/manaflow-ai/cmux/pull/10937) | Lawrence Chen | `da0239d03a3398556c496cffeb9ee393aff7ffaa` | 2026-08-27 08:01:23 | `41f17d77e00ed6ae8b022833301b979d82ee95e3` |
| [#10939](https://github.com/manaflow-ai/cmux/pull/10939) | Lawrence Chen | `63805ab765f88419b5c87a63068c79e05948506e` | 2026-08-27 08:06:35 | `26fb89ceba985e908f50502e1666c77b8d7f8ead` |
| [#10934](https://github.com/manaflow-ai/cmux/pull/10934) | Lawrence Chen | `04ab7444e49b05dc3d34dc129ff716780b807354` | 2026-08-27 08:17:49 | `f73fd08c161445b309f6d8d37374d85de58725df` |
| [#10949](https://github.com/manaflow-ai/cmux/pull/10949) | Lawrence Chen | `634f34535681d01a9c51369eee5da21e3f57c3a5` | 2026-08-27 08:34:35 | `b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87` |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |
| [#10936](https://github.com/manaflow-ai/cmux/pull/10936) | Lawrence Chen | `0f6bc912500c630921a6a74d86c09d5817e56278` | 2026-08-27 09:58:58 | `d65d6e6ccacf1d7300316451ce2830f05f889e14` |
| [#10954](https://github.com/manaflow-ai/cmux/pull/10954) | Lawrence Chen | `cc1edc896dbf321da26e26e10fb71e5fbb22e57c` | 2026-08-27 11:23:26 | `a293eba98d6f4fafa4add823327c44deef8371ef` |
| [#10958](https://github.com/manaflow-ai/cmux/pull/10958) | Lawrence Chen | `c6de8f16b6390038225f87474f603b0ea157506e` | 2026-08-27 10:22:03 | `9cf920bb6b7a87bae3af721a0f98c989c45b9c4b` |
| [#10962](https://github.com/manaflow-ai/cmux/pull/10962) | Lawrence Chen | `ff719b6dc4e9f05358d0c77b7f49a9db021f72e7` | 2026-08-27 10:41:51 | `ef5e7434927d89996e2cd29b429823b8a716a08e` |
| [#10951](https://github.com/manaflow-ai/cmux/pull/10951) | Lawrence Chen | `978655f95b56351c9d554d2bdd1be9ad6ec2c551` | 2026-08-27 12:04:42 | `de3902db48d2924c227b5acb26cbe1d89fe03cc0` |
| [#10970](https://github.com/manaflow-ai/cmux/pull/10970) | Lawrence Chen | `561ddccdc9da7d6389d90940f73e9ea30205fa26` | 2026-08-27 12:25:26 | `aa8ca45e0b3a140678c4a6ae588e201cb421ac50` |
| [#10972](https://github.com/manaflow-ai/cmux/pull/10972) | Lawrence Chen | `d41cac100d2488c41cbabff7c236166186b9deb4` | 2026-08-27 12:22:32 | `2f95b8760005047ff470afe4a00fd33783e4cf93` |
| [#10959](https://github.com/manaflow-ai/cmux/pull/10959) | Lawrence Chen | `8f74239c78a81352d69e8fe5512a688b0a9d7b7e` | 2026-08-27 12:49:58 | `87f31977237cbcbbf8b7f492718685d612fbb9b0` |

The bounded open-PR inventory retained below was captured before the d65 merge.
It retains exact heads, check rollups, GitHub state, and classifications without
pretending they are current. Run a fresh `gh pr view` and checks query before
acting on any row.

The retained session receipt supports at least 258 named substantive turns.
This is a verifiable lower bound, not a total session count, and no
10,000-session claim is made.

Dependent open intents require separate review: [#10736](https://github.com/manaflow-ai/cmux/pull/10736) (`2fed9d4c6d0d548ee20751afedb2d53b4598b09c`, sidebar preview), [#10742](https://github.com/manaflow-ai/cmux/pull/10742) (`befdff972f563f851ef27e38bbbb115269b4769a`, manual I/O), and [#10812](https://github.com/manaflow-ai/cmux/pull/10812) (`a44314f6e9eaf42925dc1d6c9dfb0a20b021b4a1`, remote daemon). Their open state is not acceptance evidence.

Cloud resource projection [#10812](https://github.com/manaflow-ai/cmux/pull/10812) is superseded by merged [#10887](https://github.com/manaflow-ai/cmux/pull/10887). Packaging duplicate [#10886](https://github.com/manaflow-ai/cmux/pull/10886) remains open and is superseded pending [#10891](https://github.com/manaflow-ai/cmux/pull/10891); re-query both before closing either.

## Historical snapshot retained: main `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`

The following section preserves the prior current layer captured at
2026-08-27T09:54:48Z. It is not current evidence.

Historical snapshot: 2026-08-27T09:54:48Z. This board was pinned to
`origin/main` at [`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff),
committed 2026-08-27T02:31:38-07:00 with subject
`fix(tui): zeroize oversized remote frames (#10950)`. The working branch
contains documentation only. The prior `99bdc375e98eb9abddd3f54289bc16ef876e8095`
snapshot, captured at 2026-08-27T09:25:01Z after [#10944](https://github.com/manaflow-ai/cmux/pull/10944),
is retained below as historical evidence. Its open-PR heads and check rollups
must be re-queried before a merge decision.

The nine requested PRs, [#10944](https://github.com/manaflow-ai/cmux/pull/10944),
and [#10950](https://github.com/manaflow-ai/cmux/pull/10950) are in this exact
main snapshot. The latest merge zeroizes oversized remote session frames before
disconnect. Source heads, authors, merge times, and merge commits are recorded
below. Individual rollback commands are in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).

| PR | Author | Source head | Merged at (UTC) | Merge SHA |
| --- | --- | --- | --- | --- |
| [#10941](https://github.com/manaflow-ai/cmux/pull/10941) | Lawrence Chen | `122a4ff210c50dea21e12846c276849047b16357` | 2026-08-27 07:14:20 | `6641abe023f3ab175fd910b547316fc00bf523ee` |
| [#10940](https://github.com/manaflow-ai/cmux/pull/10940) | Lawrence Chen | `ab2e3d314285d0512280821711b518fae14c2557` | 2026-08-27 07:21:34 | `e6895d94d8fba491e823e3550dda6727cdd87d33` |
| [#10938](https://github.com/manaflow-ai/cmux/pull/10938) | Lawrence Chen | `e9162bfbf4bdbabcd68ffa4461011262229740fe` | 2026-08-27 07:22:50 | `d0f1d94c431cd41947133f7d9406968ee70a7fc7` |
| [#10935](https://github.com/manaflow-ai/cmux/pull/10935) | Lawrence Chen | `f6e9d9e9353c629fa42ff44b65a1074972384b3b` | 2026-08-27 07:37:37 | `502ed87921f4ea933e30cfe8e5bb5aed0b4dad50` |
| [#10932](https://github.com/manaflow-ai/cmux/pull/10932) | Lawrence Chen | `79d5bda289b5ff5e87e8714fd6f3f69f7e7e88fb` | 2026-08-27 07:38:07 | `6e67b662c649096b7133eaace8059cd4420a6ba6` |
| [#10937](https://github.com/manaflow-ai/cmux/pull/10937) | Lawrence Chen | `da0239d03a3398556c496cffeb9ee393aff7ffaa` | 2026-08-27 08:01:23 | `41f17d77e00ed6ae8b022833301b979d82ee95e3` |
| [#10939](https://github.com/manaflow-ai/cmux/pull/10939) | Lawrence Chen | `63805ab765f88419b5c87a63068c79e05948506e` | 2026-08-27 08:06:35 | `26fb89ceba985e908f50502e1666c77b8d7f8ead` |
| [#10934](https://github.com/manaflow-ai/cmux/pull/10934) | Lawrence Chen | `04ab7444e49b05dc3d34dc129ff716780b807354` | 2026-08-27 08:17:49 | `f73fd08c161445b309f6d8d37374d85de58725df` |
| [#10949](https://github.com/manaflow-ai/cmux/pull/10949) | Lawrence Chen | `634f34535681d01a9c51369eee5da21e3f57c3a5` | 2026-08-27 08:34:35 | `b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87` |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |

The bounded open-PR inventory from the prior snapshot remains below under
`Historical live PR state (99bd snapshot)`. It retains exact heads, check
rollups, GitHub state, and classifications without pretending they are current.
Run a fresh `gh pr view` and checks query before acting on any row.

## Historical snapshot retained: main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The following section preserves the prior board state captured at
2026-08-27T09:25:01Z. It is not current evidence.

Historical snapshot: 2026-08-27T09:25:01Z. This board was pinned to
`origin/main` at [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095),
committed 2026-08-27T02:13:58-07:00 with subject
`fix(relay): bound Git child cleanup (#10944)`. The
working branch contained documentation only. Older sections remain below as
dated history and are not live evidence.

The nine requested PRs, plus the subsequent [#10944](https://github.com/manaflow-ai/cmux/pull/10944)
merge, are in this exact main snapshot. Their source heads, authors, merge
times, and merge commits are recorded in the table below;
the same commits and individual rollback commands are in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md). A merged PR is evidence that
the change reached main, not evidence that every user-intent row is complete.

| PR | Author | Source head | Merged at (UTC) | Merge SHA |
| --- | --- | --- | --- | --- |
| [#10941](https://github.com/manaflow-ai/cmux/pull/10941) | Lawrence Chen | `122a4ff210c50dea21e12846c276849047b16357` | 2026-08-27 07:14:20 | `6641abe023f3ab175fd910b547316fc00bf523ee` |
| [#10940](https://github.com/manaflow-ai/cmux/pull/10940) | Lawrence Chen | `ab2e3d314285d0512280821711b518fae14c2557` | 2026-08-27 07:21:34 | `e6895d94d8fba491e823e3550dda6727cdd87d33` |
| [#10938](https://github.com/manaflow-ai/cmux/pull/10938) | Lawrence Chen | `e9162bfbf4bdbabcd68ffa4461011262229740fe` | 2026-08-27 07:22:50 | `d0f1d94c431cd41947133f7d9406968ee70a7fc7` |
| [#10935](https://github.com/manaflow-ai/cmux/pull/10935) | Lawrence Chen | `f6e9d9e9353c629fa42ff44b65a1074972384b3b` | 2026-08-27 07:37:37 | `502ed87921f4ea933e30cfe8e5bb5aed0b4dad50` |
| [#10932](https://github.com/manaflow-ai/cmux/pull/10932) | Lawrence Chen | `79d5bda289b5ff5e87e8714fd6f3f69f7e7e88fb` | 2026-08-27 07:38:07 | `6e67b662c649096b7133eaace8059cd4420a6ba6` |
| [#10937](https://github.com/manaflow-ai/cmux/pull/10937) | Lawrence Chen | `da0239d03a3398556c496cffeb9ee393aff7ffaa` | 2026-08-27 08:01:23 | `41f17d77e00ed6ae8b022833301b979d82ee95e3` |
| [#10939](https://github.com/manaflow-ai/cmux/pull/10939) | Lawrence Chen | `63805ab765f88419b5c87a63068c79e05948506e` | 2026-08-27 08:06:35 | `26fb89ceba985e908f50502e1666c77b8d7f8ead` |
| [#10934](https://github.com/manaflow-ai/cmux/pull/10934) | Lawrence Chen | `04ab7444e49b05dc3d34dc129ff716780b807354` | 2026-08-27 08:17:49 | `f73fd08c161445b309f6d8d37374d85de58725df` |
| [#10949](https://github.com/manaflow-ai/cmux/pull/10949) | Lawrence Chen | `634f34535681d01a9c51369eee5da21e3f57c3a5` | 2026-08-27 08:34:35 | `b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87` |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` |

The broad command `gh pr list --repo manaflow-ai/cmux --state open
--search 'cmux-tui' --limit 1000 --json number` returned 232 open title/body
matches at the snapshot time. That query is intentionally broad and does not
prove a PR changes a `cmux-tui/` path. The live table below is a bounded,
reproducible active set of TUI, relay, packaging, recovery, and directly
related follow-ups. Each row gives the exact head returned by `gh pr view`, a
rollup count (`S/F/P/T` means successful, failed, pending, total entries),
mergeability, and a disposition. It is not a claim that the other 232 rows are
safe to merge or irrelevant.

## Historical live PR state (99bd snapshot, 2026-08-27)

| PR | Author | Exact head | Checks at snapshot | GitHub state | Classification |
| --- | --- | --- | --- | --- | --- |
| [#10951](https://github.com/manaflow-ai/cmux/pull/10951) | Lawrence Chen | `a80b9e6e667491a9b0b49a22cd3bb54dac4a5e97` | 21/0/1/24 | mergeable, CLEAN | Candidate; exact-head review required. |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 21/0/1/24 | mergeable, CLEAN | Candidate; one hosted check remains pending. |
| [#10946](https://github.com/manaflow-ai/cmux/pull/10946) | Lawrence Chen | `e062c7f5130be5e9641a07f6120b0f9cfdb8de24` | 21/0/1/25 | mergeable, CLEAN | Preview follow-up candidate; review required. |
| [#10936](https://github.com/manaflow-ai/cmux/pull/10936) | Lawrence Chen | `563b18e7be5cb3d65fe02fdbe42712dc3272e304` | 21/0/1/24 | mergeable, CLEAN | Candidate; exact-head RPC review required. |
| [#10929](https://github.com/manaflow-ai/cmux/pull/10929) | Lawrence Chen | `0d4f84c69174a7a7a30a5d306283b59db82c5184` | 21/0/1/24 | mergeable, UNSTABLE | Re-land candidate; one hosted check remains pending. |
| [#10891](https://github.com/manaflow-ai/cmux/pull/10891) | Lawrence Chen | `c5e6141198525119f11478949d70163dfa793bb7` | 12/5/1/28 | mergeable, UNSTABLE | Blocked by five failed checks and one pending check; rework first. |
| [#10886](https://github.com/manaflow-ai/cmux/pull/10886) | Lawrence Chen | `8c83105dffeb234e4f4563cb6ac1670a0fa5e5f4` | 3/2/1/14 | mergeable, UNSTABLE | Docs candidate; checks incomplete and failing. |
| [#10882](https://github.com/manaflow-ai/cmux/pull/10882) | ninjin0802 | `d69d150c11738f8165fe7538d282620b9ede9a45` | 2/0/1/6 | mergeable, UNSTABLE | Diagnostic candidate; exact-head review required. |
| [#10736](https://github.com/manaflow-ai/cmux/pull/10736) | Lawrence Chen | `2fed9d4c6d0d548ee20751afedb2d53b4598b09c` | 22/0/1/25 | mergeable, CLEAN | Independent UI candidate; review and behavior proof required. |
| [#10743](https://github.com/manaflow-ai/cmux/pull/10743) | Lawrence Chen | `470252914f76bd3124d38a5e19c61c9716cd1fb3` | 22/0/1/28 | conflicting, DIRTY | Stale-surface follow-up; rebase and rework. |
| [#10747](https://github.com/manaflow-ai/cmux/pull/10747) | Lawrence Chen | `35ef21fa3b41f528709b2c932468737aa6475369` | 22/0/1/26 | mergeable, CLEAN | Rework required; prior review found catalog-loss risk. |
| [#10744](https://github.com/manaflow-ai/cmux/pull/10744) | Lawrence Chen | `45f208fb98d6b647d28818f3c96314c20b997897` | 22/0/1/26 | mergeable, CLEAN | Generation-gate candidate; exact review required. |
| [#10745](https://github.com/manaflow-ai/cmux/pull/10745) | Lawrence Chen | `8b08588991917f37bd30eabcf80adc7b9a337f3d` | 21/1/1/27 | conflicting, DIRTY | Blocked by a failed conformance check and conflict. |
| [#10746](https://github.com/manaflow-ai/cmux/pull/10746) | Lawrence Chen | `9fa4c1497719f3c205ce6d402b3ce338d7fd5504` | 22/0/1/27 | mergeable, CLEAN | Rework required; detached-reaper risks remain. |
| [#10748](https://github.com/manaflow-ai/cmux/pull/10748) | Lawrence Chen | `646f58844cdafda97627bf08fce41b30d6258900` | 4/0/1/10 | conflicting, DIRTY | Stale recovery-test branch; rebase before review. |
| [#10681](https://github.com/manaflow-ai/cmux/pull/10681) | Austin Wang | `c1d5b7c126a0b5f2266dbe290148c97edcaf7dbd` | 4/0/1/9 | mergeable, CLEAN | Independent editor-lifecycle candidate; behavior proof required. |
| [#10607](https://github.com/manaflow-ai/cmux/pull/10607) | Lawrence Chen | `126d772a131ce71f245ae56c3048aa99f3607d17` | 21/0/1/25 | conflicting, DIRTY | Identity-preflight follow-up; rebase. |
| [#10609](https://github.com/manaflow-ai/cmux/pull/10609) | Lawrence Chen | `bdcbb8c8049eb552a0d646cdce78d58d294b7b82` | 21/0/1/28 | conflicting, DIRTY | Overlaps the merged sequence; superseded pending unique-work review. |
| [#10537](https://github.com/manaflow-ai/cmux/pull/10537) | dkta0 | `5432799b46fa4ba3967497c7ad2ade440228264e` | 3/0/1/7 | conflicting, DIRTY | Independent host-color candidate; rebase. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | `a840d018b798cad68cec4b5fdeb13242668da730` | 21/0/1/26 | conflicting, DIRTY | Journal-restore dependency; rebase and lifecycle proof. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | `55caae646e40d9b665714e001ba84ec427631f52` | 2/0/1/7 | conflicting, DIRTY | Host-death dependency; rebase and hosted proof. |
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | `076d648a2c03e6b1b4226dd4ae7c5286e1f98f16` | 21/0/1/25 | conflicting, DIRTY | Scoped-attach security follow-up; rebase and review. |
| [#10413](https://github.com/manaflow-ai/cmux/pull/10413) | Lawrence Chen | `891544e0ab1f1ab277213b984e7f53078374fb63` | 20/1/1/25 | conflicting, DIRTY | Journal-topology dependency; failed check and rebase required. |
| [#10213](https://github.com/manaflow-ai/cmux/pull/10213) | Lawrence Chen | `911ee5304feba9b816fd59806c75bb41ca8db00c` | 21/0/1/25 | mergeable, CLEAN | Redraw candidate; exact-head review required. |

`CLEAN` and `UNSTABLE` are GitHub merge-state labels, not acceptance claims.
The rollup includes required checks and reviewer/inventory entries, so a green
count alone does not replace exact-head review or behavior evidence. Re-run the
metadata query before making a merge decision because heads and checks can move.

Session-mined unfinished requests and the simplification backlog are in
[`USER-REQUEST-BOARD.md`](USER-REQUEST-BOARD.md). They remain open until a
behavior test or dogfood result proves completion.

Rollback commands, residual risk, and the session-scan receipt are maintained
in [`TECH-DEBT-BOARD.md`](TECH-DEBT-BOARD.md) and
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).

## Historical live PR state (2026-08-25)

This table is authoritative. Older tables below preserve historical snapshots.

| PR | Author | State and head on 2026-08-25 | Decision |
| --- | --- | --- | --- |
| [#10708](https://github.com/manaflow-ai/cmux/pull/10708) | Lawrence Chen | Open, source head `75ddb6fbe8`; exact-head hosted checks and local autoreview are pending. | Run focused and full exact-head hosted checks, run local autoreview, then merge. |
| [#10736](https://github.com/manaflow-ai/cmux/pull/10736) | Lawrence Chen | Open, head `2fed9d4c6d0d548ee20751afedb2d53b4598b09c`, mergeable, all listed checks pass. Prior preview and localization findings are addressed; local autoreview needs a clean engine run. | Keep separate from #10708, run local autoreview, then merge if exact gates stay green. |
| [#10734](https://github.com/manaflow-ai/cmux/pull/10734) | Lawrence Chen | Open, head `64ae7f91f0`; exact review found a compile error in `owner_spawn_failed`, dropped startup options, and GitHub reports seven-language conformance failure. | Do not merge. Fix P0/P1 findings and rerun exact-head checks. |
| [#10743](https://github.com/manaflow-ai/cmux/pull/10743) | Lawrence Chen | Open, head `470252914f`, stale-surface follow-up. Active identity and publication-race findings remain. | Rework, rebase after [#10708](https://github.com/manaflow-ai/cmux/pull/10708), then rerun exact-head checks. |
| [#10747](https://github.com/manaflow-ai/cmux/pull/10747) | Lawrence Chen | Open, head `35ef21fa3b`, follow-up to #10743. Review found it removes valid lazy/unattached server tabs and still lacks atomic pair publication. | Do not merge. Rework against authoritative server state and add refresh-level tests. |
| [#10744](https://github.com/manaflow-ai/cmux/pull/10744) | Lawrence Chen | Open, head `45f208fb98`, watch replacement generation gate. | Review exact head and integrate only after hosted proof. |
| [#10745](https://github.com/manaflow-ai/cmux/pull/10745) | Lawrence Chen | Open, head `ee8f3d00ea`, Git process-group cleanup. | Review Unix and Windows cleanup, then integrate only after hosted proof. |
| [#10746](https://github.com/manaflow-ai/cmux/pull/10746) | Lawrence Chen | Open, head `9fa4c14977`, run_spec detached waitpid reaper. Review found PID/PGID reuse and unbounded detached-thread risks. | Do not merge. Prefer the existing owned timeout supervisor and add cancellation/reap behavior tests. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Merged as `7ddd04f2c1879cb38868292987aae1f1dfa2b139`. | Already merged. |
| [#10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Merged as `1956d7f440add80ba35e585d83697d9dae44d3e2`. | Already merged. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Open, conflicting, unchanged head `67b7e6814f8355235e3930a6f3360a58dc0ba3c0`; superseded. | Close after [#10708](https://github.com/manaflow-ai/cmux/pull/10708) merges, after rechecking the head. |
| [#10609](https://github.com/manaflow-ai/cmux/pull/10609) | Lawrence Chen | Open, conflicting, unchanged head `bdcbb8c8049eb552a0d646cdce78d58d294b7b82`; superseded. | Close after [#10708](https://github.com/manaflow-ai/cmux/pull/10708) merges, after rechecking the head. |

## Aggregate

| PR | Author | Intent | Decision |
| --- | --- | --- | --- |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Umbrella relay, SDK, TUI lifecycle, protocol, and tech-debt integration. | This branch supersedes the overlapping slices. Merge only after exact-head hosted checks and local autoreview pass. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Earlier relay tech-debt wave. | Superseded by #10603. It remains open; do not merge. Its Rust SDK MSRV, Rust consumer, and Rust package checks failed in run `32644656010`. |
| [#10571](https://github.com/manaflow-ai/cmux/pull/10571) | Lawrence Chen | Earlier chatmux-relay slices 2 and 3. | Closed as superseded by #10603. |

## Dependency chains that are not safe to merge blindly

| PR | Author | Intent and required order |
| --- | --- | --- |
| [#10413](https://github.com/manaflow-ai/cmux/pull/10413) | Lawrence Chen | Journal topology restore. Merge only after an exact rebase and hosted checks. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Journal restore apply v1, dependent on #10413. Rebase after the base lands, then prove lifecycle, atomic exit state, replay performance, and metadata privacy. |
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Scoped attach passthrough. It is conflicting and its diagnostic PTY tap has blocking-I/O and process-group risks. Rebase and remove or repair the tap before merge. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Host and daemon death reporting. It depends on #10428 and needs a rebase plus focused hosted tests. |
| [#10253](https://github.com/manaflow-ai/cmux/pull/10253), [#10267](https://github.com/manaflow-ai/cmux/pull/10267), [#10268](https://github.com/manaflow-ai/cmux/pull/10268), [#10269](https://github.com/manaflow-ai/cmux/pull/10269) | Lawrence Chen | Release and wheel verification stack. Merge bottom-up only after each exact head passes. |
| [#10261](https://github.com/manaflow-ai/cmux/pull/10261), [#10262](https://github.com/manaflow-ai/cmux/pull/10262), [#10264](https://github.com/manaflow-ai/cmux/pull/10264), [#10265](https://github.com/manaflow-ai/cmux/pull/10265) | Lawrence Chen | SDK integration stack. Merge bottom-up, then rerun all language consumers. |

## Independent candidates

These PRs were mergeable or near-ready in the audit, but they are not part of
the aggregate branch. Merge them separately only after checking the current
head and overlap with #10603.

[#10681](https://github.com/manaflow-ai/cmux/pull/10681), Austin Wang, is
independent and has wrapper, quoting, and Emacs-mode fixes at `ff7685ddcd`.
The existing `env -S "nvim --clean"` detector path still needs a parser fix;
then it needs hosted Swift proof and exact-head autoreview.

- [#10607](https://github.com/manaflow-ai/cmux/pull/10607), Lawrence Chen, identity and protocol preflight.
- [#10537](https://github.com/manaflow-ai/cmux/pull/10537), dkta0, client-local host colors.
- [#10318](https://github.com/manaflow-ai/cmux/pull/10318), Lawrence Chen, pane-context New-column action.
- [#10302](https://github.com/manaflow-ai/cmux/pull/10302), Lawrence Chen, multiple machine providers.
- [#10271](https://github.com/manaflow-ai/cmux/pull/10271), Lawrence Chen, explicit skipped-TUI coverage.
- [#10249](https://github.com/manaflow-ai/cmux/pull/10249), Lawrence Chen, SDK session validation.
- [#10239](https://github.com/manaflow-ai/cmux/pull/10239), Lawrence Chen, unsafe session-name rejection.

## Defer or rebase

- [#10321](https://github.com/manaflow-ai/cmux/pull/10321), Lawrence Chen, cloud TUI. Large and conflicting, so it needs a product and security review.
- [#10270](https://github.com/manaflow-ai/cmux/pull/10270), Lawrence Chen, long socket hashing. Checks passed but the branch conflicts and overlaps #10249.
- [#10243](https://github.com/manaflow-ai/cmux/pull/10243), Lawrence Chen, release orchestration. Conflicting and outside this aggregate's safe scope.
- [#10136](https://github.com/manaflow-ai/cmux/pull/10136), Lawrence Chen, journal restore. Use the current recut [#10259](https://github.com/manaflow-ai/cmux/pull/10259) instead.
- [#10214](https://github.com/manaflow-ai/cmux/pull/10214), Lawrence Chen, Windows launch. Functionally superseded by [#10266](https://github.com/manaflow-ai/cmux/pull/10266).
- [#9515](https://github.com/manaflow-ai/cmux/pull/9515), Abdulaziz Albahar, Iroh transport. Experimental and requires an independent protocol/security review.
- [#9524](https://github.com/manaflow-ai/cmux/pull/9524), Abdulaziz Albahar, Iroh transport follow-up. Same defer rule.
- [#9593](https://github.com/manaflow-ai/cmux/pull/9593), Abdulaziz Albahar, Iroh transport stack. Same defer rule.

## Audit limits

The search used GitHub TUI title/body filters plus known dependency links. It
can miss work that never says TUI or cmux in its title or body. The board does
not close or merge unrelated experimental work. A PR with a green old check is
not current-head evidence; conflicting branches require a rebase first.
