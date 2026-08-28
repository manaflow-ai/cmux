# cmux-tui aggregate change log

## Wave 85, current main `1e09970237f21686b8c0e6853b51a89819623803`

Snapshot: 2026-08-28T09:23:20Z.

| Change | Result | Revert pointer |
| --- | --- | --- |
| [#11072](https://github.com/manaflow-ai/cmux/pull/11072), source `7cf4ed0b96fb1bc22b2a2823dc81d3164ebbd60d`, merge `253df2472973a5654e1a3d7fee13764a177c7a79` | cmux-tui runtime shutdown now uses one cleanup path with preserved teardown order. | `git revert 253df2472973a5654e1a3d7fee13764a177c7a79` after checking dependent shutdown changes. |
| [#11069](https://github.com/manaflow-ai/cmux/pull/11069), source `d9646e350bcd5db20458899ff66f4a19df9d0a14`, merge `f756735566a2ce16bad450a8ab592fef2a40d9c4` | Cloud-tree right-click verbs, confirmations, workspace double-click behavior, drag gating, and visual polish are on main. | `git revert f756735566a2ce16bad450a8ab592fef2a40d9c4` after checking dependent cloud-tree changes. |
| [#11056](https://github.com/manaflow-ai/cmux/pull/11056), source `433e1f5ec237476077e7a50eceeb1c39547fc0ff`, merge `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` | Retained-tab reindexing now avoids the second scan while preserving duplicate-ID and clamp behavior. | `git revert 102aa3d63086bf0617a6b5a34d5cb2465f2a74a7` after checking dependent projection changes. |
| [#10988](https://github.com/manaflow-ai/cmux/pull/10988), source `e12ce402fc760a9d51dceee2faba1331f59855cd`, merge `e7584a4c4a25b2e4fe400b67ab19b7c7ec3a5f11` | Fixed synchronization waits were removed and timeout scaling was corrected. | `git revert e7584a4c4a25b2e4fe400b67ab19b7c7ec3a5f11` |
| [#10987](https://github.com/manaflow-ai/cmux/pull/10987), source `4cbf023af8e4552fa0f6aa95755ea7d7a0336798`, merge `7da4c0f6ce14e5ddf71e90f05dc67d29980fda69` | Intent and technical-debt boards were refreshed through #10985. | `git revert 7da4c0f6ce14e5ddf71e90f05dc67d29980fda69` |

Open gates: [#11024](https://github.com/manaflow-ai/cmux/pull/11024) `44df14444fce5420570cc9b54eaf0a9cdfeba5c2` is open and mergeable on `main` at `1e09970237f21686b8c0e6853b51a89819623803`, with checks pending. [#11025](https://github.com/manaflow-ai/cmux/pull/11025) `685c924e866113d1457e89a2bd9469e5fb219e6a`, [#11028](https://github.com/manaflow-ai/cmux/pull/11028) `5ca760526fed25225b135f99b238a9a0fd7ac7e9`, and [#11055](https://github.com/manaflow-ai/cmux/pull/11055) `85ce43a3bf9cdbe56b86fd2d069ec886915001d5` are open and mergeable, with #11025 and #11055 based on `main` at `1e09970237f21686b8c0e6853b51a89819623803` and #11028 on stale base `102aa3d63086bf0617a6b5a34d5cb2465f2a74a7`; checks are pending. [#10990](https://github.com/manaflow-ai/cmux/pull/10990) `2608c8ca279f26c188723e95f31e6ac287439423` is open and mergeable on `main` at `1e09970237f21686b8c0e6853b51a89819623803`, with checks pending. Blocked or deferred work remains in [#11002](https://github.com/manaflow-ai/cmux/pull/11002), [#11068](https://github.com/manaflow-ai/cmux/pull/11068), [#11013](https://github.com/manaflow-ai/cmux/pull/11013), stacked [#11078](https://github.com/manaflow-ai/cmux/pull/11078), round-1 [#11063](https://github.com/manaflow-ai/cmux/pull/11063), and conflicting [#10401](https://github.com/manaflow-ai/cmux/pull/10401). #10994 is now open and mergeable on `main` at `1e09970237f21686b8c0e6853b51a89819623803` at head `f334fdc95394f952d8f30690f5c0560286e03ad2`.

Session accounting remains honest: confirmed turns `0`; strict total `unknown`. The five documented owner workstreams are the practical evidence floor. The audit retains a conservative lower bound of 50 and a historical ledger of at least 258 named substantive turns. Neither is a total, and no 10,000-session claim is made.

## Wave 84, current main `305519d149c1ca61d4be4838e18b0a59f8e69b2a`

Snapshot: 2026-08-28T07:43:00Z.

| Change | Result | Revert pointer |
| --- | --- | --- |
| [#11072](https://github.com/manaflow-ai/cmux/pull/11072), `253df2472973a5654e1a3d7fee13764a177c7a79` | Runtime shutdown cleanup is deduplicated with preserved teardown order. | `git revert 253df2472973a5654e1a3d7fee13764a177c7a79` after checking dependent shutdown changes. |
| [#11041](https://github.com/manaflow-ai/cmux/pull/11041), `305519d149c1ca61d4be4838e18b0a59f8e69b2a` | Paste repro harnesses and analyzer audit are on main. | `git revert 305519d149c1ca61d4be4838e18b0a59f8e69b2a` only if the test infrastructure must be removed. |
| [#11000](https://github.com/manaflow-ai/cmux/pull/11000), `8910e6360e3b1d8b05b875cbe44e1901e8c7fc60` | Surface-exit indexing avoids repeated scans and repairs stale indexes. | `git revert 8910e6360e3b1d8b05b875cbe44e1901e8c7fc60` with the index consumers reviewed. |
| [#11044](https://github.com/manaflow-ai/cmux/pull/11044), `c33d38ab80166e7ca525d197faf93d1f918f55f2` | Resource operation wire names use one contract. | `git revert c33d38ab80166e7ca525d197faf93d1f918f55f2` only with protocol compatibility checks. |
| [#11045](https://github.com/manaflow-ai/cmux/pull/11045), `8d71d72e6de027074828d7d81443b1f8ec825283` | Remote transport loss is explicit and localized. | `git revert 8d71d72e6de027074828d7d81443b1f8ec825283` with client behavior checks. |

Open work remains gated by exact current heads in `PR-INTENT-BOARD.md`. Session accounting is honest: strict count `unknown`, older named-turn lower bound 258, no 10,000-session evidence.

## Wave 83, exact state at main `989293cdb9058500f51d6c9b8e4f3795e67997ce`

Snapshot: 2026-08-28T06:56:33Z. Current merged references:

| Merged PR | Author | Source head | Merge SHA | Debt disposition |
| --- | --- | --- | --- | --- |
| [#11066](https://github.com/manaflow-ai/cmux/pull/11066) | Abdulaziz Albahar | `553f1a471d8451eb695d4a6e414d68eaba550c6d` | `8a7b4b5c4a7ad4af2851303b27bd17327d15d7d8` | Namespaced state directory reaches the macOS build; unrelated to the four new TUI follow-ups. |
| [#11000](https://github.com/manaflow-ai/cmux/pull/11000) | Lawrence Chen | `d83a0ec65f3fa5d064fa342a6d13c519696cba0e` | `8910e6360e3b1d8b05b875cbe44e1901e8c7fc60` | Cached surface exits now use an index; this is the current direct-TUI baseline. |
| [#11018](https://github.com/manaflow-ai/cmux/pull/11018) | Abdulaziz Albahar | `070fd65f127cb3cd00f8efebf3adbcb99c39f5b8` | `ed19cfa5cb88d6e0fae683bbe4a733bd4e2d062c` | iOS unread badge spacing; no closure for TUI intent rows. |
| [#10838](https://github.com/manaflow-ai/cmux/pull/10838) | Austin Wang | `0afec52b7c248445b08d337e766d71cfa612b9fc` | `c1e7f094cea7b1a1dbe21b48bc43e01c41b2d1c4` | Codex completion notification timing; no closure for the parity or security rows. |
| [#10326](https://github.com/manaflow-ai/cmux/pull/10326) | Austin Wang | `a1826532091fed085768dcf5c0469f2423fa1a84` | `989293cdb9058500f51d6c9b8e4f3795e67997ce` | Sidebar reftable metadata fix; latest main tip, not a TUI intent closure. |

New evidence rows:

| Debt | Evidence | Disposition and next proof |
| --- | --- | --- |
| Harbor filesystem-tree redesign is still a follow-up. | Claude `~/.claude/history.jsonl:91032`, session `9a24a8c7-e7e4-4385-9742-aa20f8475b66`; [#11063](https://github.com/manaflow-ai/cmux/pull/11063), Lawrence Chen, head `bd5d47b03facb3e20eff1b8aba8d697f1f96c9d6`, open and mergeable. | Keep #11063 marked round 1. Create a separate redesign row for the host, tool, session, workspace, window/tab, terminal tree, drag-out, cloud manual I/O, and no nested TUI rendering. |
| Herdr/Codex parity is not complete. | Claude `~/.claude/history.jsonl:91027,91029`, session `e5f4a11b-ca0c-4d74-8520-debf0fe5671b`; [#11068](https://github.com/manaflow-ai/cmux/pull/11068), Lawrence Chen, head `04380edc86d1f5033b71341ddc97cb4738c26e4f`, open; GitHub mergeability changed during the audit, and checks and review remain pending. CodeRabbit review at 2026-08-28T06:14:55Z reports eight actionable comments, including fail-closed identity, lowercase-region reuse, live-terminal `HashSet`, monotonic snapshots, maintained attention order, and Grok/Qwen rules. | Keep open until those findings and the remaining seen-bit, wait-for-state, manifest refresh, filter, visible-blocker, wrapper identity, Windows, and OSC gaps have exact-head tests. |
| Post-audit cmux-TUI security sweep is in progress. | Codex `~/.codex/history.jsonl:18868-18869`, session `01a04659-67b5-7e73-af85-20019325aae6`; transcript `~/.codex/sessions/2026/08/27/rollout-2026-08-27T20-10-59-01a04659-67b5-7e73-af85-20019325aae6.jsonl`. Latest plain status at 2026-08-28T06:14:43Z reports screening of post-audit TUI PRs; no final result or PR link exists. | Do not mark complete. Publish exact findings, fixes, reviewed heads, and required checks with secret-safe evidence. |
| #10401 drag-into-terminal remains open debt. | [#10401](https://github.com/manaflow-ai/cmux/pull/10401), Lawrence Chen, head `46590bacaed87fba46d4ceb5cdacadcafad07833`, open and conflicting; its body lists UTType, `.draggable`, and terminal drop routing as follow-up. Claude `~/.claude/history.jsonl:90390,90392,21824,21911` records the request and failed drops. | Keep the gap visible. Rebase the follow-up, implement one shared drag payload and drop action, preserve cwd and resume metadata, and prove no text insertion. |

Session accounting remains honest: strict auditable turns are `unknown`. The retained 258 named-turn figure is an older lower bound, and these receipts do not establish a total. Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/), [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/), and Ratatui [`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html) remain the primary state and render references.

## Wave 82, exact state at main `2c6fd70ecceeed63fdb549882737c6563fb3f52d`

Receipt paths: Codex `~/.codex/sessions/2026/08/27/` JSONL receipts; Claude
`~/.claude/history.jsonl` with session metadata under `~/.claude/sessions/`.

| Merged PR | Author | Source head | Merge SHA | Debt disposition |
| --- | --- | --- | --- | --- |
| [#11022](https://github.com/manaflow-ai/cmux/pull/11022) | Abdulaziz Albahar | `eaf542ca7b34607d621a48367dbd2958915b0296` | `2c6fd70ecceeed63fdb549882737c6563fb3f52d` | iOS Computer-sheet visibility fix; unrelated to the six open TUI intents. |
| [#11045](https://github.com/manaflow-ai/cmux/pull/11045) | Lawrence Chen | `118ae063aba8736d7c16d9b3a3cd5c6ee5dfcb2c` | `8d71d72e6de027074828d7d81443b1f8ec825283` | Remote transport loss now surfaces instead of an empty-session fallback. |
| [#11039](https://github.com/manaflow-ai/cmux/pull/11039) | Lawrence Chen | `d3f97bfcd8e848abf3c527b1683f5eed8c719fea` | `c1151eaf7addbb49bdcf40c053abe059fcef2db5` | Markdown and diff viewer find action merged. |
| [#11044](https://github.com/manaflow-ai/cmux/pull/11044) | Lawrence Chen | `a2df7e8a629c20b583d04812e070356fdcd2c562` | `c33d38ab80166e7ca525d197faf93d1f918f55f2` | Resource-operation wire names centralized. |
| [#11012](https://github.com/manaflow-ai/cmux/pull/11012) | Lawrence Chen | `8d118f410fa32fbff94b34e3317719015c56d3b4` | `d0b3b737a26f6afa6565b6c0160a31700abe6e21` | Unchanged projection subtitles avoid cloning. |
| [#11047](https://github.com/manaflow-ai/cmux/pull/11047) | Abdulaziz Albahar | `73199b36436843c7a420cf86027cf363ee9e36db` | `aa7c9221ac576d01e033a23f9f3f46b9afec22cb` | Namespaced relay transport state and cache permissions. |
| [#11021](https://github.com/manaflow-ai/cmux/pull/11021) | Lawrence Chen | `f59f21a7f34992d481667ffb87cbcc9dbfc0e8fa` | `2c6035573e5edab568da035e99c713acecfc1d70` | Machines panel cloud-agent launcher merged. |

Six intent deltas remain open. [#11005](https://github.com/manaflow-ai/cmux/pull/11005),
Lawrence Chen, head `8c3bb260504f50b622158b5ce884f573ddf1c6f5`, only splits iOS
queue and actor-hop time. [#10963](https://github.com/manaflow-ai/cmux/pull/10963),
Lawrence Chen, head `ba65199cf505729eddc27373b9497b9573bc9f97`, selects direct
Stack-header and first-frame admission but still needs auth and cleanup proof.
[#10999](https://github.com/manaflow-ai/cmux/pull/10999), Abdulaziz Albahar,
head `20fef437ec377559c7669d257d999bb48228150e`, is conflicting while topology
ownership is unresolved. [#10828](https://github.com/manaflow-ai/cmux/pull/10828),
Lawrence Chen, head `a5d3ff37abe933373237813325c84870df7242cd`, is conflicting
while the external-session catalog contract is undefined. [#10966](https://github.com/manaflow-ai/cmux/pull/10966),
Lawrence Chen, head `3885306fb27853a60732dbbbf79fe44d172f2949`, is conflicting
for the agent-roster follow-up. [#10321](https://github.com/manaflow-ai/cmux/pull/10321),
Lawrence Chen, head `c0501c00a3462ac48ce01ead37ff019628e23617`, is conflicting
for cloud-only manual I/O and reconnect behavior.

The strict session count is `unknown`. The retained 258 named-turn figure is an
older lower bound, and the new Codex/Claude receipts do not provide a complete
session denominator. Tokio [`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/),
Tokio [`broadcast`](https://docs.rs/tokio/latest/tokio/sync/broadcast/), Ratatui
[`Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html), and
SQLite [`WAL`](https://www.sqlite.org/wal.html) remain the primary design references.

## Wave 81, exact state at main `6964584c030eec3e46c81545ff9e3c49ff1730ca`

| Change | Evidence | Exact revert |
| --- | --- | --- |
| [#11019](https://github.com/manaflow-ai/cmux/pull/11019) stops terminal-content admission from swallowing cmux-owned context-menu presses. | Merge `cc47a9152ba7366e84a614d41904c0a69ec422e9`; exact hosted and local review evidence recorded before merge. | `git revert cc47a9152ba7366e84a614d41904c0a69ec422e9` |
| [#11026](https://github.com/manaflow-ai/cmux/pull/11026) replays retained notices without a temporary vector and tests ordered replay. | Merge `c582b8d74ab82e404f18b14ad4e97f2d4cc04fa9`; exact hosted run `33139611745` passed and local review was clean. | `git revert c582b8d74ab82e404f18b14ad4e97f2d4cc04fa9` |
| [#11044](https://github.com/manaflow-ai/cmux/pull/11044) centralizes resource-operation wire names. | Open PR, head `f4873d0671221c06f886f40cbf81ed9bfe36620d`; exhaustive 125-name fixture and serde references. | `git revert <merge-sha-after-merge>` |

The Unicode glyph work in [#11028](https://github.com/manaflow-ai/cmux/pull/11028)
is rebased at head `7d63c066e8091866b34e63046035914e77519880` and has a clean
exact local review. Hosted run [33140789572](https://github.com/manaflow-ai/cmux/actions/runs/33140789572)
is the current evidence and must finish against that exact head before merge.
The branch contains tests only, so no runtime build or deeplink is claimed.

Residual risk: main is receiving unrelated merges during this wave. A clean
review is invalid if the PR head or target SHA changes during the run.

## Current reconciliation: main `e27710a23149d9412665ef786b688797006b2730`

Current merged delta: #10995, source `a156463ea61f00bc9e67e16e27ed3f38d3329417`, merge `e27710a23149d9412665ef786b688797006b2730`; rollback `git revert e27710a23149d9412665ef786b688797006b2730`. Strict confirmed turns: `0`; total: `unknown`.

Audit basis: 2026-08-27T19:39:39Z. The current merged cmux-tui log is
[#10984](https://github.com/manaflow-ai/cmux/pull/10984) `e9543607420f7b3b3284ac4c71ea21918dea692e`,
[#10975](https://github.com/manaflow-ai/cmux/pull/10975) `46958aa58d171a01af7a5b1f06164f18d8639612`,
[#10986](https://github.com/manaflow-ai/cmux/pull/10986) `b5023a455618dd3d4885da2605e162b0bdb67790`,
[#10982](https://github.com/manaflow-ai/cmux/pull/10982) `642a65b1512d0d61aaef88290f90ef3408bbee74`,
[#10985](https://github.com/manaflow-ai/cmux/pull/10985) `2b61ecafceb4b1c008b6f07345270615a0fb4286`, and
[#10612](https://github.com/manaflow-ai/cmux/pull/10612) `af31628f7b0b2f6c34e184049254fa2fe91f285d`.

The strict auditable session-turn count is `unknown` (not zero), because the
latest evidence has no durable session identifiers. The practical ledger
floor is five documented substantive owner workstreams. The branch proxy is
96 TUI references and 78 substantive non-merge commits, not a turn count.
Unresolved Claude IDs are `1787650444261`, `1787650724161` (state ownership,
manual I/O, reconnect), `1787722163382`, `1787723964393` (remove Go daemon,
direct tunnels), `1787733887926`, `1787780735531` (machine terminals, VNC,
attach, parity), `1787794506089` (cloud tree), `1787823710241` (sidebar split),
`1787825896700` (wheel arrows), and `1787826030510` (completion subscriptions).
No transcript proves completion.

## 2026-08-27 historical refresh at main `2b61ecafceb4b1c008b6f07345270615a0fb4286`

Docs-only snapshot at 2026-08-27T18:44:45Z. No runtime build or test ran.
Merged [#10982](https://github.com/manaflow-ai/cmux/pull/10982), Lawrence Chen,
source `1e0c3eefaf43e733c967131199361d587f56a34b`, merge
`642a65b1512d0d61aaef88290f90ef3408bbee74`, [run 33100547866](https://github.com/manaflow-ai/cmux/actions/runs/33100547866)
passed. Rollback: `git revert 642a65b1512d0d61aaef88290f90ef3408bbee74`.
Merged [#10985](https://github.com/manaflow-ai/cmux/pull/10985), Lawrence Chen,
source `f32d788d1cb503fb7cddf50e70fc40d0e067ec4e`, merge
`2b61ecafceb4b1c008b6f07345270615a0fb4286`, [run 33103012053](https://github.com/manaflow-ai/cmux/actions/runs/33103012053)
and [SDK run 33103010095](https://github.com/manaflow-ai/cmux/actions/runs/33103010095)
passed. Rollback: `git revert 2b61ecafceb4b1c008b6f07345270615a0fb4286`.

Live gates: [#10966](https://github.com/manaflow-ai/cmux/pull/10966) head
`dda134e95835a415d6cce062e896367ad30c3a94`, runs
[#33104657912](https://github.com/manaflow-ai/cmux/actions/runs/33104657912) and
[#33104745426](https://github.com/manaflow-ai/cmux/actions/runs/33104745426)
in progress, five CodeRabbit comment-only reviews; [#10969](https://github.com/manaflow-ai/cmux/pull/10969)
head `0a89a140738c68d105ddd7d1cf5bbcb1e713bb02`, runs
[#33104519612](https://github.com/manaflow-ai/cmux/actions/runs/33104519612) and
[#33104514655](https://github.com/manaflow-ai/cmux/actions/runs/33104514655)
in progress, one CodeRabbit comment-only review; [#10612](https://github.com/manaflow-ai/cmux/pull/10612)
head `ddc15ed4d7fc737cf86e9bd4bf2adc8bd1ebf5fa`, successful runs
[#33103112353](https://github.com/manaflow-ai/cmux/actions/runs/33103112353) and
[#33103077154](https://github.com/manaflow-ai/cmux/actions/runs/33103077154),
comment-only Greptile, Codex connector, and CodeRabbit reviews, stale base;
[#10891](https://github.com/manaflow-ai/cmux/pull/10891) head
`e16aa8c35bbb1fafa7b3cb1340f872754c66d6a7`, queued
[#33104968098](https://github.com/manaflow-ai/cmux/actions/runs/33104968098),
in-progress [#33104965438](https://github.com/manaflow-ai/cmux/actions/runs/33104965438),
earlier-head CodeRabbit comments only.

Closed without merge: [#9806](https://github.com/manaflow-ai/cmux/pull/9806),
[#9813](https://github.com/manaflow-ai/cmux/pull/9813),
[#10136](https://github.com/manaflow-ai/cmux/pull/10136),
[#10413](https://github.com/manaflow-ai/cmux/pull/10413),
[#10237](https://github.com/manaflow-ai/cmux/pull/10237),
[#10267](https://github.com/manaflow-ai/cmux/pull/10267), and
[#10746](https://github.com/manaflow-ai/cmux/pull/10746). Their exact heads are,
in order, `406529665e5494ca559acab47079d8e7fb274386`,
`3b8d500aa23cfe9a7fbbe4a1dbdcf1be19902c61`,
`0786b6b37e5a397c1acc15b14be4a89f4363117b`,
`891544e0ab1f1ab277213b984e7f53078374fb63`,
`187dffe3e181fd6a85f99dc3fec2244c4fbe6fff`,
`7c8e4130737cf15f81086603364b587b13c05f40`, and
`9fa4c1497719f3c205ce6d402b3ce338d7fd5504`. No rollback applies because
none reached main. Issues [#10881](https://github.com/manaflow-ai/cmux/issues/10881)
and [#10394](https://github.com/manaflow-ai/cmux/issues/10394) closed after
[#10954](https://github.com/manaflow-ai/cmux/pull/10954). Browser
[#335](https://github.com/manaflow-ai/cmux/pull/335) resolved at merge
`5697f71fc6956729524a76a5f17d5611c3ff485b`; rollback:
`git revert 5697f71fc6956729524a76a5f17d5611c3ff485b`.

No new session scan ran. Retained evidence supports at least 258 named
substantive turns, a lower bound only. No 10,000-session claim is made.

Historical snapshot: 2026-08-27T13:05:00Z. The audited source was pinned to
`origin/main` at [`87f31977237cbcbbf8b7f492718685d612fbb9b0`](https://github.com/manaflow-ai/cmux/commit/87f31977237cbcbbf8b7f492718685d612fbb9b0),
committed 2026-08-27T05:49:57-07:00 with subject
`Integrate Escape passthrough fix from PR #9810 (#10959)`. This documentation-only
refresh keeps the prior `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` and
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshots below as historical
records. The session receipt and lower-bound ledger are retained from the prior
audit; no new session scan was performed.

## Current main tail (2026-08-27, main `87f31977237cbcbbf8b7f492718685d612fbb9b0`)

Each row includes the merged PR, author, merge SHA, change, and exact rollback
command. The commits are single-parent squash merges, so no `-m` option is
needed. [#10936](https://github.com/manaflow-ai/cmux/pull/10936) fails unknown
workspace RPC responses and retires canceled request IDs without hanging.
The retained session receipt supports at least 258 named substantive turns. This
is a verifiable lower bound, not a total session count, and no 10,000-session
claim is made.

| PR | Author | Merge SHA | Change | Rollback |
| --- | --- | --- | --- | --- |
| [#10941](https://github.com/manaflow-ai/cmux/pull/10941) | Lawrence Chen | [`6641abe023f3ab175fd910b547316fc00bf523ee`](https://github.com/manaflow-ai/cmux/commit/6641abe023f3ab175fd910b547316fc00bf523ee) | Accept unknown remote capability names with a forward-compatible enum fallback. | `git revert 6641abe023f3ab175fd910b547316fc00bf523ee` |
| [#10940](https://github.com/manaflow-ai/cmux/pull/10940) | Lawrence Chen | [`e6895d94d8fba491e823e3550dda6727cdd87d33`](https://github.com/manaflow-ai/cmux/commit/e6895d94d8fba491e823e3550dda6727cdd87d33) | Define remote ChatGPT auth-refresh ownership and lifecycle in docs. | `git revert e6895d94d8fba491e823e3550dda6727cdd87d33` |
| [#10938](https://github.com/manaflow-ai/cmux/pull/10938) | Lawrence Chen | [`d0f1d94c431cd41947133f7d9406968ee70a7fc7`](https://github.com/manaflow-ai/cmux/commit/d0f1d94c431cd41947133f7d9406968ee70a7fc7) | Use reverse indexes for cmux-tui surface teardown lookups. | `git revert d0f1d94c431cd41947133f7d9406968ee70a7fc7` |
| [#10935](https://github.com/manaflow-ai/cmux/pull/10935) | Lawrence Chen | [`502ed87921f4ea933e30cfe8e5bb5aed0b4dad50`](https://github.com/manaflow-ai/cmux/commit/502ed87921f4ea933e30cfe8e5bb5aed0b4dad50) | Secure detached daemon logs and startup locks with ownership and no-follow checks. | `git revert 502ed87921f4ea933e30cfe8e5bb5aed0b4dad50` |
| [#10932](https://github.com/manaflow-ai/cmux/pull/10932) | Lawrence Chen | [`6e67b662c649096b7133eaace8059cd4420a6ba6`](https://github.com/manaflow-ai/cmux/commit/6e67b662c649096b7133eaace8059cd4420a6ba6) | Validate pairing config through opened descriptors without symlink races. | `git revert 6e67b662c649096b7133eaace8059cd4420a6ba6` |
| [#10937](https://github.com/manaflow-ai/cmux/pull/10937) | Lawrence Chen | [`41f17d77e00ed6ae8b022833301b979d82ee95e3`](https://github.com/manaflow-ai/cmux/commit/41f17d77e00ed6ae8b022833301b979d82ee95e3) | Preserve the first remote-reader termination reason and distinguish EOF from read failure. | `git revert 41f17d77e00ed6ae8b022833301b979d82ee95e3` |
| [#10939](https://github.com/manaflow-ai/cmux/pull/10939) | Lawrence Chen | [`26fb89ceba985e908f50502e1666c77b8d7f8ead`](https://github.com/manaflow-ai/cmux/commit/26fb89ceba985e908f50502e1666c77b8d7f8ead) | Align relay upload ingress and egress frame budgets with Unix limits. | `git revert 26fb89ceba985e908f50502e1666c77b8d7f8ead` |
| [#10934](https://github.com/manaflow-ai/cmux/pull/10934) | Lawrence Chen | [`f73fd08c161445b309f6d8d37374d85de58725df`](https://github.com/manaflow-ai/cmux/commit/f73fd08c161445b309f6d8d37374d85de58725df) | Use canonical noun-first resource commands in public TUI docs. | `git revert f73fd08c161445b309f6d8d37374d85de58725df` |
| [#10949](https://github.com/manaflow-ai/cmux/pull/10949) | Lawrence Chen | [`b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87`](https://github.com/manaflow-ai/cmux/commit/b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87) | Localize browser-control failures at the UI boundary. | `git revert b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87` |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095) | Bound Git child cleanup with an explicit cancellation deadline and reap path. | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | [`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff) | Zeroize oversized remote session frames before returning the size-limit error. | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |
| [#10936](https://github.com/manaflow-ai/cmux/pull/10936) | Lawrence Chen | [`d65d6e6ccacf1d7300316451ce2830f05f889e14`](https://github.com/manaflow-ai/cmux/commit/d65d6e6ccacf1d7300316451ce2830f05f889e14) | Fail unknown workspace RPC responses and retire canceled request IDs safely. | `git revert d65d6e6ccacf1d7300316451ce2830f05f889e14` |
| [#10954](https://github.com/manaflow-ai/cmux/pull/10954) | Lawrence Chen | [`a293eba98d6f4fafa4add823327c44deef8371ef`](https://github.com/manaflow-ai/cmux/commit/a293eba98d6f4fafa4add823327c44deef8371ef) | Route advisory graphics diagnostics away from the status channel. | `git revert a293eba98d6f4fafa4add823327c44deef8371ef` |
| [#10958](https://github.com/manaflow-ai/cmux/pull/10958) | Lawrence Chen | [`9cf920bb6b7a87bae3af721a0f98c989c45b9c4b`](https://github.com/manaflow-ai/cmux/commit/9cf920bb6b7a87bae3af721a0f98c989c45b9c4b) | Own TUI layout from the rendered frame area. | `git revert 9cf920bb6b7a87bae3af721a0f98c989c45b9c4b` |
| [#10962](https://github.com/manaflow-ai/cmux/pull/10962) | Lawrence Chen | [`ef5e7434927d89996e2cd29b429823b8a716a08e`](https://github.com/manaflow-ai/cmux/commit/ef5e7434927d89996e2cd29b429823b8a716a08e) | Apply immediate redraws after visible input changes. | `git revert ef5e7434927d89996e2cd29b429823b8a716a08e` |
| [#10951](https://github.com/manaflow-ai/cmux/pull/10951) | Lawrence Chen | [`de3902db48d2924c227b5acb26cbe1d89fe03cc0`](https://github.com/manaflow-ai/cmux/commit/de3902db48d2924c227b5acb26cbe1d89fe03cc0) | Share startup option scanning across TUI entry points. | `git revert de3902db48d2924c227b5acb26cbe1d89fe03cc0` |
| [#10970](https://github.com/manaflow-ai/cmux/pull/10970) | Lawrence Chen | [`aa8ca45e0b3a140678c4a6ae588e201cb421ac50`](https://github.com/manaflow-ai/cmux/commit/aa8ca45e0b3a140678c4a6ae588e201cb421ac50) | Share the draw and paint render path. | `git revert aa8ca45e0b3a140678c4a6ae588e201cb421ac50` |
| [#10972](https://github.com/manaflow-ai/cmux/pull/10972) | Lawrence Chen | [`2f95b8760005047ff470afe4a00fd33783e4cf93`](https://github.com/manaflow-ai/cmux/commit/2f95b8760005047ff470afe4a00fd33783e4cf93) | Defer and flush Sentry sends before serverless freeze. | `git revert 2f95b8760005047ff470afe4a00fd33783e4cf93` |
| [#10959](https://github.com/manaflow-ai/cmux/pull/10959) | Lawrence Chen | [`87f31977237cbcbbf8b7f492718685d612fbb9b0`](https://github.com/manaflow-ai/cmux/commit/87f31977237cbcbbf8b7f492718685d612fbb9b0) | Integrate Escape passthrough from #9810. | `git revert 87f31977237cbcbbf8b7f492718685d612fbb9b0` |

The prior `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` snapshot was captured at
2026-08-27T09:54:48Z after [#10950](https://github.com/manaflow-ai/cmux/pull/10950).
Its exact tail, rollback rows, session evidence, and older `99bdc...` history are
retained below under historical headings.

## Historical snapshot retained: main `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`

The following section preserves the prior current layer. It is not current
evidence.

Historical snapshot: 2026-08-27T09:54:48Z. The audited source was pinned to
`origin/main` at [`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff),
committed 2026-08-27T02:31:38-07:00 with subject
`fix(tui): zeroize oversized remote frames (#10950)`. This documentation-only
refresh keeps the full prior `99bdc375e98eb9abddd3f54289bc16ef876e8095`
snapshot below. The session receipt and lower-bound ledger are retained from
that audit; no new session scan was performed.

## Historical main tail (2026-08-27, main `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`)

Each row includes the merged PR, author, merge SHA, change, and exact rollback
command. The commits are single-parent squash merges, so no `-m` option is
needed. [#10950](https://github.com/manaflow-ai/cmux/pull/10950) zeroizes the
oversized remote session message before returning the size-limit error.

| PR | Author | Merge SHA | Change | Rollback |
| --- | --- | --- | --- | --- |
| [#10941](https://github.com/manaflow-ai/cmux/pull/10941) | Lawrence Chen | [`6641abe023f3ab175fd910b547316fc00bf523ee`](https://github.com/manaflow-ai/cmux/commit/6641abe023f3ab175fd910b547316fc00bf523ee) | Accept unknown remote capability names with a forward-compatible enum fallback. | `git revert 6641abe023f3ab175fd910b547316fc00bf523ee` |
| [#10940](https://github.com/manaflow-ai/cmux/pull/10940) | Lawrence Chen | [`e6895d94d8fba491e823e3550dda6727cdd87d33`](https://github.com/manaflow-ai/cmux/commit/e6895d94d8fba491e823e3550dda6727cdd87d33) | Define remote ChatGPT auth-refresh ownership and lifecycle in docs. | `git revert e6895d94d8fba491e823e3550dda6727cdd87d33` |
| [#10938](https://github.com/manaflow-ai/cmux/pull/10938) | Lawrence Chen | [`d0f1d94c431cd41947133f7d9406968ee70a7fc7`](https://github.com/manaflow-ai/cmux/commit/d0f1d94c431cd41947133f7d9406968ee70a7fc7) | Use reverse indexes for cmux-tui surface teardown lookups. | `git revert d0f1d94c431cd41947133f7d9406968ee70a7fc7` |
| [#10935](https://github.com/manaflow-ai/cmux/pull/10935) | Lawrence Chen | [`502ed87921f4ea933e30cfe8e5bb5aed0b4dad50`](https://github.com/manaflow-ai/cmux/commit/502ed87921f4ea933e30cfe8e5bb5aed0b4dad50) | Secure detached daemon logs and startup locks with ownership and no-follow checks. | `git revert 502ed87921f4ea933e30cfe8e5bb5aed0b4dad50` |
| [#10932](https://github.com/manaflow-ai/cmux/pull/10932) | Lawrence Chen | [`6e67b662c649096b7133eaace8059cd4420a6ba6`](https://github.com/manaflow-ai/cmux/commit/6e67b662c649096b7133eaace8059cd4420a6ba6) | Validate pairing config through opened descriptors without symlink races. | `git revert 6e67b662c649096b7133eaace8059cd4420a6ba6` |
| [#10937](https://github.com/manaflow-ai/cmux/pull/10937) | Lawrence Chen | [`41f17d77e00ed6ae8b022833301b979d82ee95e3`](https://github.com/manaflow-ai/cmux/commit/41f17d77e00ed6ae8b022833301b979d82ee95e3) | Preserve the first remote-reader termination reason and distinguish EOF from read failure. | `git revert 41f17d77e00ed6ae8b022833301b979d82ee95e3` |
| [#10939](https://github.com/manaflow-ai/cmux/pull/10939) | Lawrence Chen | [`26fb89ceba985e908f50502e1666c77b8d7f8ead`](https://github.com/manaflow-ai/cmux/commit/26fb89ceba985e908f50502e1666c77b8d7f8ead) | Align relay upload ingress and egress frame budgets with Unix limits. | `git revert 26fb89ceba985e908f50502e1666c77b8d7f8ead` |
| [#10934](https://github.com/manaflow-ai/cmux/pull/10934) | Lawrence Chen | [`f73fd08c161445b309f6d8d37374d85de58725df`](https://github.com/manaflow-ai/cmux/commit/f73fd08c161445b309f6d8d37374d85de58725df) | Use canonical noun-first resource commands in public TUI docs. | `git revert f73fd08c161445b309f6d8d37374d85de58725df` |
| [#10949](https://github.com/manaflow-ai/cmux/pull/10949) | Lawrence Chen | [`b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87`](https://github.com/manaflow-ai/cmux/commit/b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87) | Localize browser-control failures at the UI boundary. | `git revert b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87` |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095) | Bound Git child cleanup with an explicit cancellation deadline and reap path. | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | [`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff) | Zeroize oversized remote session frames before returning the size-limit error. | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |

The prior snapshot at `99bdc375e98eb9abddd3f54289bc16ef876e8095` was captured
at 2026-08-27T09:25:01Z after [#10944](https://github.com/manaflow-ai/cmux/pull/10944).
Its exact tail, rollback rows, session evidence, and older history are retained
below under the historical heading.

## Historical snapshot retained: main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The following section preserves the prior board state. It is not current
evidence.

Historical snapshot: 2026-08-27T09:25:01Z. The audited source was pinned to
`origin/main` at [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095),
committed 2026-08-27T02:13:58-07:00. This changelog puts the current main tail
first and retained prior snapshots below as historical records. Each current
row includes the merged PR, author, merge SHA, change, and an exact rollback
command. The nine requested PRs and the subsequent [#10944](https://github.com/manaflow-ai/cmux/pull/10944)
merge were authored by Lawrence Chen and are single-parent commits, so no `-m`
option is needed.

## Historical main tail (2026-08-27, main `99bdc375e98eb9abddd3f54289bc16ef876e8095`)

| PR | Author | Merge SHA | Change | Rollback |
| --- | --- | --- | --- | --- |
| [#10941](https://github.com/manaflow-ai/cmux/pull/10941) | Lawrence Chen | [`6641abe023f3ab175fd910b547316fc00bf523ee`](https://github.com/manaflow-ai/cmux/commit/6641abe023f3ab175fd910b547316fc00bf523ee) | Accept unknown remote capability names with a forward-compatible enum fallback. | `git revert 6641abe023f3ab175fd910b547316fc00bf523ee` |
| [#10940](https://github.com/manaflow-ai/cmux/pull/10940) | Lawrence Chen | [`e6895d94d8fba491e823e3550dda6727cdd87d33`](https://github.com/manaflow-ai/cmux/commit/e6895d94d8fba491e823e3550dda6727cdd87d33) | Define remote ChatGPT auth-refresh ownership and lifecycle in docs. | `git revert e6895d94d8fba491e823e3550dda6727cdd87d33` |
| [#10938](https://github.com/manaflow-ai/cmux/pull/10938) | Lawrence Chen | [`d0f1d94c431cd41947133f7d9406968ee70a7fc7`](https://github.com/manaflow-ai/cmux/commit/d0f1d94c431cd41947133f7d9406968ee70a7fc7) | Use reverse indexes for cmux-tui surface teardown lookups. | `git revert d0f1d94c431cd41947133f7d9406968ee70a7fc7` |
| [#10935](https://github.com/manaflow-ai/cmux/pull/10935) | Lawrence Chen | [`502ed87921f4ea933e30cfe8e5bb5aed0b4dad50`](https://github.com/manaflow-ai/cmux/commit/502ed87921f4ea933e30cfe8e5bb5aed0b4dad50) | Secure detached daemon logs and startup locks with ownership and no-follow checks. | `git revert 502ed87921f4ea933e30cfe8e5bb5aed0b4dad50` |
| [#10932](https://github.com/manaflow-ai/cmux/pull/10932) | Lawrence Chen | [`6e67b662c649096b7133eaace8059cd4420a6ba6`](https://github.com/manaflow-ai/cmux/commit/6e67b662c649096b7133eaace8059cd4420a6ba6) | Validate pairing config through opened descriptors without symlink races. | `git revert 6e67b662c649096b7133eaace8059cd4420a6ba6` |
| [#10937](https://github.com/manaflow-ai/cmux/pull/10937) | Lawrence Chen | [`41f17d77e00ed6ae8b022833301b979d82ee95e3`](https://github.com/manaflow-ai/cmux/commit/41f17d77e00ed6ae8b022833301b979d82ee95e3) | Preserve the first remote-reader termination reason and distinguish EOF from read failure. | `git revert 41f17d77e00ed6ae8b022833301b979d82ee95e3` |
| [#10939](https://github.com/manaflow-ai/cmux/pull/10939) | Lawrence Chen | [`26fb89ceba985e908f50502e1666c77b8d7f8ead`](https://github.com/manaflow-ai/cmux/commit/26fb89ceba985e908f50502e1666c77b8d7f8ead) | Align relay upload ingress and egress frame budgets with Unix limits. | `git revert 26fb89ceba985e908f50502e1666c77b8d7f8ead` |
| [#10934](https://github.com/manaflow-ai/cmux/pull/10934) | Lawrence Chen | [`f73fd08c161445b309f6d8d37374d85de58725df`](https://github.com/manaflow-ai/cmux/commit/f73fd08c161445b309f6d8d37374d85de58725df) | Use canonical noun-first resource commands in public TUI docs. | `git revert f73fd08c161445b309f6d8d37374d85de58725df` |
| [#10949](https://github.com/manaflow-ai/cmux/pull/10949) | Lawrence Chen | [`b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87`](https://github.com/manaflow-ai/cmux/commit/b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87) | Localize browser-control failures at the UI boundary. | `git revert b151e7eebcf4d33ae0b5f09e3f5b8c9dc3072c87` |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095) | Bound Git child cleanup with an explicit cancellation deadline and reap path. | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |

## Session scan receipt and lower-bound ledger

The full local scan found 90,787 parsed JSON records and 81,149 unique Claude
session IDs in `~/.claude/history.jsonl`, plus 18,833 records and 2,332 unique
Codex session IDs in `~/.codex/history.jsonl`. The current tail receipt is 174
Claude records and 42 IDs from line 90614 onward, with 26 records and 12 IDs
matching selected TUI terms. Codex line 18787 onward has 47 records and 17 IDs,
with two records and two IDs matching the narrow TUI terms. These counts are
scan coverage, not substantive-turn counts.

The current board records at least 256 substantive turns. Local audit commit
`a6b54c6b0e469c72d527c5b9f7c165ed49bfa03d` (not on this main snapshot) records
one additional named documentation turn, and this changelog update adds one
more named audit turn. The verifiable lower-bound ledger is therefore at least
258 named substantive turns when those retained receipts are included. Empty,
duplicate, self-counting, secret-bearing, and unrelated records are excluded.
This is a lower bound, not a total session count, and makes no 10,000-session
claim.

The 2026-08-27 intent delta is recorded in
[`USER-INTENT-BOARD.md`](USER-INTENT-BOARD.md) and the bounded current PR set is
recorded in [`PR-INTENT-BOARD.md`](PR-INTENT-BOARD.md). No current user-intent
row is marked complete solely because one of these PRs merged.

## Historical exact-head tail (2026-08-25)

These commits are the source changes after the previous documentation snapshot.
Revert each commit separately unless a revert note says otherwise.

| Commit | Change | Revert |
| --- | --- | --- |
| [`75ddb6fbe8`](https://github.com/manaflow-ai/cmux/commit/75ddb6fbe84fb37ee8bcc75d0d96c39ec782e3e9) | Gate stale PTY overflow errors on the attachment generation and add a replacement-generation regression test. | `git revert 75ddb6fbe84fb37ee8bcc75d0d96c39ec782e3e9` |
| [`ca12249636`](https://github.com/manaflow-ai/cmux/commit/ca1224963693698eaf9a800a3fa79e81fbe86311) | Kill and await the Git child when the `git diff` stdout pipe is unexpectedly absent. | `git revert ca1224963693698eaf9a800a3fa79e81fbe86311` |
| [`ba16a6745e`](https://github.com/manaflow-ai/cmux/commit/ba16a6745e1c6791c92e44c36bd24495a75de820) | Clarify that the Kitty quota worker applies target limits after a timed-out update recovers. | `git revert ba16a6745e1c6791c92e44c36bd24495a75de820` |
| [`95fd2196df`](https://github.com/manaflow-ai/cmux/commit/95fd2196df6618d0f5ba97f26e3a2196cbc0b9b0) | Assert that a timeout-admitted terminal keeps applied Kitty limits disabled before recovery. | `git revert 95fd2196df6618d0f5ba97f26e3a2196cbc0b9b0` |
| [`31857f0c4c`](https://github.com/manaflow-ai/cmux/commit/31857f0c4c1cd52617688aa7465832fa66122f6a) | Admit terminal creation after a Kitty quota timeout with graphics disabled instead of returning an error. | `git revert 31857f0c4c1cd52617688aa7465832fa66122f6a` |
| [`2597d7720d`](https://github.com/manaflow-ai/cmux/commit/2597d7720d9e5394c2cb7e1e0ac139adb6aa5ce5) | Add regression coverage for timeout admission and later quota recovery. | `git revert 2597d7720d9e5394c2cb7e1e0ac139adb6aa5ce5` |
| [`42e97c05c6`](https://github.com/manaflow-ai/cmux/commit/42e97c05c6fd15f8e62bbcaf3e96be4388edb7d2) | Assert the typed `selector.not_found` error code. | `git revert 42e97c05c6fd15f8e62bbcaf3e96be4388edb7d2` |
| [`663317e431`](https://github.com/manaflow-ai/cmux/commit/663317e43161916d4965cc412fc68589846b6360) | Use a valid public session ID in the selector fixture. | `git revert 663317e43161916d4965cc412fc68589846b6360` |

Focused hosted evidence for this tail is run
[`32851303914`](https://github.com/manaflow-ai/cmux/actions/runs/32851303914).

Wave-48 review found follow-up risks that are intentionally not hidden by the
two fixes above: filesystem-watch replacement frames lack a generation fence,
Git child cleanup lacks a cancellation deadline and strict descendant reap,
and `run_spec` drops its child after signalling the process group. PR
[#10743](https://github.com/manaflow-ai/cmux/pull/10743) also needs active-surface
identity mapping and atomic catalog/tree publication. PR
[#10681](https://github.com/manaflow-ai/cmux/pull/10681) needs wrapped-editor and
quoted-path behavior coverage. These are open follow-up work, not merge claims.

Follow-up implementations are open for review in
[#10744](https://github.com/manaflow-ai/cmux/pull/10744), generation-gated watch
replacement at `45f208fb98`, and
[#10745](https://github.com/manaflow-ai/cmux/pull/10745), Unix Git process-group
cleanup at `ee8f3d00ea`. Neither is part of the aggregate until exact-head
review and hosted checks pass.

[#10747](https://github.com/manaflow-ai/cmux/pull/10747) attempted to preserve
active surface identity, but exact review found that it drops valid server tabs
when the local attachment mirror is empty. It is a rejected follow-up until the
authoritative server tree and lazy attachment contract are preserved.

[#10746](https://github.com/manaflow-ai/cmux/pull/10746) adds a detached
`waitpid` thread to `run_spec`. Exact review rejected it for PID/PGID reuse and
unbounded thread risks; the existing in-owner timeout supervisor remains the
safer implementation.

## Final aggregate tail

| Commit | Change | Revert |
| --- | --- | --- |
| [`31fc5df2b4`](https://github.com/manaflow-ai/cmux/commit/31fc5df2b4) | Merge current `main` at `bd985bddcd`, including the release-candidate npm version validator and test. | `git revert -m 1 31fc5df2b4`; retain the current-main package fix when rebasing. |
| [`f398f6d103`](https://github.com/manaflow-ai/cmux/commit/f398f6d103) | Match the protocol summary to the actual `pty_error` envelope and verified `terminal_gone` lookup rule. | `git revert f398f6d103`; restore the prior summary only with a matching wire change. |
| [`8cfe70f5e9`](https://github.com/manaflow-ai/cmux/commit/8cfe70f5e9) | Serialize typed relay error codes from the generated enum and test every typed variant. | `git revert 8cfe70f5e9` |
| [`79182c532c`](https://github.com/manaflow-ai/cmux/commit/79182c532c) | Return `failed` for unavailable or malformed workspace listings; reserve `terminal_gone` for a valid missing-resource result. | `git revert 79182c532c` |
| [`2c7fb75887`](https://github.com/manaflow-ai/cmux/commit/2c7fb75887) | Create upload PID markers with noclobber and stop signaling numeric marker PIDs during recovery. | `git revert 2c7fb75887`; this restores the PID-reuse hazard. |
| [`b0bfbd29cd`](https://github.com/manaflow-ai/cmux/commit/b0bfbd29cd) | Clarify that upload PID markers are for stale-file detection, not process identity. | `git revert b0bfbd29cd` |
| [`ad4ab3f6e5`](https://github.com/manaflow-ai/cmux/commit/ad4ab3f6e5cde50406393f13220478ef45f4f660), [`d998f308a6`](https://github.com/manaflow-ai/cmux/commit/d998f308a6) | Add and then correct the PTY lifecycle documentation so it matches the implemented wire fields and codes. | Revert both documentation commits together. |
| [`14abca2963`](https://github.com/manaflow-ai/cmux/commit/14abca2963) | Normal merge of the current `main` tip `835d046fed`. | `git revert -m 1 14abca2963` |
| [`52c7ca4735`](https://github.com/manaflow-ai/cmux/commit/52c7ca4735) | Normalize standalone C1 DCS, SOS, and PM introducers while preserving UTF-8 continuation bytes. | `git revert 52c7ca4735` |
| [`2c73791935`](https://github.com/manaflow-ai/cmux/commit/2c73791935) | Drain relay `git diff` stderr to completion while retaining a bounded diagnostic prefix. | `git revert 2c73791935` |
| [`8196bb8300`](https://github.com/manaflow-ai/cmux/commit/8196bb8300) | Make stream cancellation CAS-based and retryable after failed serialization or writes. | `git revert 8196bb8300` |
| [`551134c765`](https://github.com/manaflow-ai/cmux/commit/551134c765), [`909f4907e8`](https://github.com/manaflow-ai/cmux/commit/909f4907e8), [`d39cba3843`](https://github.com/manaflow-ai/cmux/commit/d39cba3843) | Use a private exclusive SSH staging directory, then clean it after probe and atomic move. | `git revert 551134c765 909f4907e8 d39cba3843` |
| [`9ae4173935`](https://github.com/manaflow-ai/cmux/commit/9ae4173935) | Add behavior tests for selector depth, required targets, and name/public-ID resolution. | `git revert 9ae4173935` |
| [`526b5b611d`](https://github.com/manaflow-ai/cmux/commit/526b5b611d) | Revalidate hosted workflow identity and require release dispatch acknowledgement. | `git revert 526b5b611d` |
| [`387b4185f2`](https://github.com/manaflow-ai/cmux/commit/387b4185f2) | Keep presentation flags out of forwarded CLI payloads after the first positional command argument. | `git revert 387b4185f2` |
| [`67cce86d41`](https://github.com/manaflow-ai/cmux/commit/67cce86d41) | Mark historical board sections and the current exact snapshot. | `git revert 67cce86d41` |

## Current merge tail

| Commit | Change | Revert |
| --- | --- | --- |
| [`0560bae72c`](https://github.com/manaflow-ai/cmux/commit/0560bae72c17ccf2da139fdf44f1907523fc82cc) | Merge current `main` and preserve aggregate hardening while taking the current package workflow and generated SDK updates. | `git revert -m 1 0560bae72c` |
| [`77b51e368a`](https://github.com/manaflow-ai/cmux/commit/77b51e368a41de79995adc6842a66f0834c7a9e9) | Release the opening mutex while waiting for the prior PTY delivery gate, then recheck cancellation before replacement insertion. | `git revert 77b51e368a` |
| [`3b75312375`](https://github.com/manaflow-ai/cmux/commit/3b75312375)`, [`f457826a34`](https://github.com/manaflow-ai/cmux/commit/f457826a34)`, [`03d19a5e13`](https://github.com/manaflow-ai/cmux/commit/03d19a5e13) | Serialize PTY callback delivery, close, and replacement insertion by attachment gate. | `git revert 3b75312375 f457826a34 03d19a5e13 77b51e368a` |
| [`1c79fcfbd9`](https://github.com/manaflow-ai/cmux/commit/1c79fcfbd9) | Add a stale-callback reopen regression test. | `git revert 1c79fcfbd9` |
| [`ae2fa91709`](https://github.com/manaflow-ai/cmux/commit/ae2fa91709) | Continue a bounded legacy socket scan when one directory entry has unreadable metadata. | `git revert ae2fa91709` |
| [`702a0dcbc1`](https://github.com/manaflow-ai/cmux/commit/702a0dcbc1)`, [`4a50dd64b2`](https://github.com/manaflow-ai/cmux/commit/4a50dd64b2) | Reject invalid Go write counts and preserve dispatch after partial writes or write errors. | `git revert 702a0dcbc1 4a50dd64b2` |
| [`3e85c7dd05`](https://github.com/manaflow-ai/cmux/commit/3e85c7dd05) | Cover Java path traversal rejection without narrowing the shared cross-language session-name contract. | `git revert 3e85c7dd05` |
| [`7fdcfa583a`](https://github.com/manaflow-ai/cmux/commit/7fdcfa583a3b708b523a08dfcbfac3b57ffbc627) | Merge the web auth-cache determinism fix into `main` before the TUI merge. | Do not revert from this branch; it is already on `main`. |

| [`de082a2cf3`](https://github.com/manaflow-ai/cmux/commit/de082a2cf390b59acd36fb11b13fa4c22f9a55df) | Merge current `main` at `f78182c0a1`, including PyPI project-description metadata and its contract test. | `git revert -m 1 de082a2cf3`; retain the metadata fix when rebasing the aggregate. |
| [`774b42eaaf`](https://github.com/manaflow-ai/cmux/commit/774b42eaaf) | Stop broad remote-daemon cleanup from killing concurrent writers; reclaim only dead upload markers. | `git revert 774b42eaaf`; live writers remain untouched, while PID reuse can delay stale cleanup. |
| [`4fffdfc128`](https://github.com/manaflow-ai/cmux/commit/4fffdfc1280c56c05fc77af3b1ad71cc1fc2e07c) | Use an exclusive payload descriptor, keep the owner PID marker, scope failed-writer termination, and cover shell quoting and concurrent uploads. | `git revert 4fffdfc128`; same-UID pathname races after hashing remain outside portable shell guarantees. |

| [`bdff60c67d`](https://github.com/manaflow-ai/cmux/commit/bdff60c67d8c30cd5d00890f569d22e5cc65fcc1) | Include the current `main` journal-forwarder wire-identity fix. | Revert the aggregate merge as one unit if required. |
| [`375daeb96e`](https://github.com/manaflow-ai/cmux/commit/375daeb96e229559532c534412276ee4bf19ba6f) | Remove stale PTY close races, make SSH staging ownership explicit, fix trait-object coercions, and remove an unused reader import. | `git revert 375daeb96e`; hosted Rust proof remains required. |
| [`c4f1b62518`](https://github.com/manaflow-ai/cmux/commit/c4f1b62518edd3bf70c76923451bda77857944e1) | Bound shell viewer delivery by bytes and events, clear overflowed backlog, and emit one explicit overflow error. | `git revert c4f1b62518`; reconnect after overflow. |
| [`951db83c35`](https://github.com/manaflow-ai/cmux/commit/951db83c3545f9ad4fce67f420f6998d1832ba02) | Merge current `main` while preserving aggregate TUI hardening and the dedicated relay publish lane. | `git revert -m 1 951db83c35`. |
| [`28becbddaf`](https://github.com/manaflow-ai/cmux/commit/28becbddaf) | Use no-clobber descriptor creation for staged binaries and document the terminal overflow close contract. | `git revert 28becbddaf`; same-user pathname `chmod` remains a documented residual. |
| [`676ea97842`](https://github.com/manaflow-ai/cmux/commit/676ea97842) | Reject option-like remote binary paths, add `--` boundaries, and simplify the Rust global output flag match. | `git revert 676ea97842`. |
| [`ea326c45bb`](https://github.com/manaflow-ai/cmux/commit/ea326c45bb7d8ceb3d0a29a5239af0144c0444c4) | Clarify create/attach versus headless ownership in the getting-started guide and CLI specification. | `git revert ea326c45bb`. |

Focused checks for this tail: `cargo fmt --check`, actionlint, Bash syntax, 67 package/security/installer Python tests, 109 Python binding tests plus 421 subtests, Go tests, Java checks, generated-binding checks, C++ unit/package tests, and Swift parser syntax. Rust behavior and hosted lifecycle proof remain required on the pushed exact head.

## New tail since `c599fa778e506574bddf12393d4a9bb91c4772e5`

Exact-head additions: `e83f02532a0d7f41ba5c4befc294b948c35ab190` refuses Windows workspace reads; `164ebca49c32bd61e876ade399a0cc36c28ce281` and `0ab5cc7212bd3b92fa03b7c8f260496c0e642192` add the Rust 1.91 MSRV gate; `096ef9a1b8b30fe6f38de9bf656c1f33c577c9c5` tests the refusal; and `48ddd759dcfc2601ce761b076b42c9baf1f48725` preserves the custom stream factory with legacy fallback. Hosted verification and exact-head review remain pending. Revert each with `git revert <full-sha>`, keeping the Windows fix and test coupled.

The current tail adds bounded CLI text validation, symlink-safe relay configuration, invalid-writer-count tests, bounded relay file/list actions, PTY close-race and upgrade-task cleanup, sanitized lifecycle diagnostics, concurrent stderr caps, Windows-safe config replacement, localized recovery diagnostics, cursor-control parsing, lifecycle-name validation, launcher signal propagation, and invalid socket-path compatibility coverage. Revert individual commits with `git revert <sha>`; revert coupled behavior and tests together for `dcd68c3801`, `04b5819876`, and `a9eaf022aa`.

Earlier aggregate rows retained for history:

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`efbe0bcceb`](https://github.com/manaflow-ai/cmux/commit/efbe0bcceb) | Reject invalid relay configuration before use. | Focused Rust checks are hosted-only; malformed-config callers now fail closed. | `git revert efbe0bcceb` |
| [`836ec27806`](https://github.com/manaflow-ai/cmux/commit/836ec27806) | Bound websocket ingress before allocation. | Hosted Rust verification required; oversized frames are rejected. | `git revert 836ec27806` |
| [`a44378f1d8`](https://github.com/manaflow-ai/cmux/commit/a44378f1d8) | Cap and validate persisted relay configuration. | Diff and static checks; migration risk for over-capacity stored config. | `git revert a44378f1d8` |
| [`7a1816acf6`](https://github.com/manaflow-ai/cmux/commit/7a1816acf6) | Bound relay PTY input frames. | Hosted relay tests required; excess input is rejected. | `git revert 7a1816acf6` |
| [`d1277ff2b5`](https://github.com/manaflow-ai/cmux/commit/d1277ff2b5) | Fail closed on mandatory relay queue overflow. | Hosted behavior proof required; clients must handle explicit closure. | `git revert d1277ff2b5` |
| [`70ac436947`](https://github.com/manaflow-ai/cmux/commit/70ac436947) | Bound preview-proxy websocket queues. | Hosted integration coverage required; slow consumers can be disconnected. | `git revert 70ac436947` |
| [`30419a1ad9`](https://github.com/manaflow-ai/cmux/commit/30419a1ad9) | Bound remote stream chunk queues. | Hosted integration coverage required; queue pressure is now visible as failure. | `git revert 30419a1ad9` |
| [`33c5804900`](https://github.com/manaflow-ai/cmux/commit/33c5804900) | Bound websocket writes and cancel replaced peers. | Hosted relay checks required; replacement closes the old peer. | `git revert 33c5804900` |
| [`80d5a5393c`](https://github.com/manaflow-ai/cmux/commit/80d5a5393cc5654d00d254adc9c9b78c4e1573df) | Validate relay frame protocol bounds at the aggregate tip. | Static checks only in this snapshot; hosted exact-head run remains required. | `git revert 80d5a5393c` |

Known residuals: no claim is made for local Rust test execution, full end-to-end relay coverage, journal/WAL latency, deterministic shutdown of every admitted task, or complete cloud-TUI acceptance. These remain open until an exact pushed SHA has hosted evidence.

Historical snapshot note: this early section recorded at least 190 turns. The current audited lower bound is at least 205 substantive agent turns. The requested 10,000-session target was not reached, and no empty sessions were created to inflate the count.

## Tail after `ace9e5f57f`

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`0917e9918f`](https://github.com/manaflow-ai/cmux/commit/0917e9918fbf56267c978d8e05d857f11204a693) | Accept standard `--socket=`, `--session=`, and `--machine=` forms, while retaining separated values and rejecting empty inline values. | `cargo fmt --check` and CLI behavior tests are present. Hosted Rust CLI coverage remains required; nested command options intentionally keep their existing grammar. | `git revert 0917e9918fbf56267c978d8e05d857f11204a693` |
| [`cfb0684e75`](https://github.com/manaflow-ai/cmux/commit/cfb0684e75) | Apply formatter output to the inline global-option parser. | Formatting-only; no behavior change. | `git revert cfb0684e75` |
| [`46b5d0c044`](https://github.com/manaflow-ai/cmux/commit/46b5d0c044) | Add a durable user-intent board with local-session evidence and explicit acceptance gaps. | Documentation-only. The board records a multilingual emoji fixture request and search limitations. | `git revert 46b5d0c044` |

## Exact-head autoreview fixes after `cfb0684e75`

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`23c90f2f48`](https://github.com/manaflow-ai/cmux/commit/23c90f2f48) | Remove duplicate CDP request IDs before re-adding them to the pending-order deque. | Focused unit test; the deque is capped and each update is O(n) within 512 entries. | `git revert 23c90f2f48` |
| [`ad0830d63d`](https://github.com/manaflow-ai/cmux/commit/ad0830d63d) | Limit injected HTML collection to 8 MiB and 30 seconds. | Focused oversized-response test; hosted relay test remains required. The timeout uses Tokio's clock. | `git revert ad0830d63d` |
| [`f0056da912`](https://github.com/manaflow-ai/cmux/commit/f0056da912) | Use the explicit legacy-fallback API in the Rust SDK fallback test. | Source contract now matches the legacy-only socket fixture; hosted Rust SDK test remains required. | `git revert f0056da912` |
| [`192c67a2f4`](https://github.com/manaflow-ai/cmux/commit/192c67a2f4) and [`f5ae9729d6`](https://github.com/manaflow-ai/cmux/commit/f5ae9729d6) | Probe raw `/tmp` only after a preferred socket path does not fit, and cover runtime-path precedence in Go and TypeScript. | Go tests pass; TypeScript package build is unavailable in this checkout because `tsc` is not installed. Hosted SDK checks remain required. | `git revert 192c67a2f4 f5ae9729d6` |
| [`40120911dc`](https://github.com/manaflow-ai/cmux/commit/40120911dc) and [`2b0e717d63`](https://github.com/manaflow-ai/cmux/commit/2b0e717d63) | Propagate cancellation of a shared Python cleanup task without retry spin, while preserving caller cancellation. | Python suite: 107 passed, 421 subtests. | `git revert 40120911dc 2b0e717d63` |
| [`946d7b5a21`](https://github.com/manaflow-ai/cmux/commit/946d7b5a21) | Cap preview listeners at 32 target ports with LRU eviction and awaited task cleanup. | Focused async test and diff/format checks; hosted relay test remains required. Eviction can close an active preview after the cap. | `git revert 946d7b5a21` |
| [`4a23b30a82`](https://github.com/manaflow-ai/cmux/commit/4a23b30a82), [`ff04cd9ea3`](https://github.com/manaflow-ai/cmux/commit/ff04cd9ea3), and [`cb52a7910e`](https://github.com/manaflow-ai/cmux/commit/cb52a7910e) | Terminate Windows exec process trees with a Job Object, kill-on-close, bounded final wait, and Tokio's `raw_handle` API. | Windows source path follows existing repository Job Object code; hosted Windows compile/runtime proof remains required. | `git revert 4a23b30a82 ff04cd9ea3 cb52a7910e` |

## Cross-platform hardening after `2b0e717d63`

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`5087c74c44`](https://github.com/manaflow-ai/cmux/commit/5087c74c44) | Preserve Windows drive prefixes while creating safe relay parent directories, parse allowed-root environment values with the platform separator, remove the stale Rust derived-config constructor, and allow Zig deferred cleanup variables. | `cargo fmt` and diff checks pass; hosted Windows, Rust SDK, and Zig checks remain required. | `git revert 5087c74c44` |
| [`516fa5791e`](https://github.com/manaflow-ai/cmux/commit/516fa5791e) | Remove unused Rust fallback state and apply clippy's let-chain form in the resource client. | Formatter and source checks pass; hosted Rust clippy remains required. | `git revert 516fa5791e` |
| [`681971deb5`](https://github.com/manaflow-ai/cmux/commit/681971deb5) | Return a stable 502 message for oversized injected HTML bodies. | Focused oversized-response assertion; hosted relay behavior remains required. | `git revert 681971deb5` |
| [`35be8f8c8a`](https://github.com/manaflow-ai/cmux/commit/35be8f8c8a3868631d27dfa0b8009dace5b70f4c) | Record the normal merge of concurrent review history without replacing the corrected aggregate tree. | Merge metadata only. The remote-side commits are retained in ancestry; this tree contains their safe semantic fixes or stricter replacements. | `git revert -m 1 35be8f8c8a3868631d27dfa0b8009dace5b70f4c` |

## Final accepted tail from `b61f1bada6` to `e8df21eed2`

The table is exhaustive for the 49-commit inclusive tail. Revert commands use
full object IDs. A merge uses `-m 1` and must be reviewed against the parent
chosen by the integration owner. “Hosted” means the focused test or check must
run on the hosted builder; this documentation worktree makes no local Rust
test claim.

| Commit | Change | Tests / residual risk | Exact revert |
| --- | --- | --- | --- |
| [`b61f1bada6498ee9d6549f4550f9a062f327f22c`](https://github.com/manaflow-ai/cmux/commit/b61f1bada6498ee9d6549f4550f9a062f327f22c) | Apply hosted relay rustfmt. | Formatter-only; rerun hosted compile after further edits. | `git revert b61f1bada6498ee9d6549f4550f9a062f327f22c` |
| [`74c2d71c7ea58949a744e1545f49c72329d0e53e`](https://github.com/manaflow-ai/cmux/commit/74c2d71c7ea58949a744e1545f49c72329d0e53e) | Add publish-workflow security validation. | `tests/test_tui_publish_workflow_security.py`; hosted workflow remains required. | `git revert 74c2d71c7ea58949a744e1545f49c72329d0e53e` |
| [`1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0`](https://github.com/manaflow-ai/cmux/commit/1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0) | Expose the session port to agents. | Hosted Rust behavior test required; port ownership remains a product contract. | `git revert 1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0` |
| [`1956d7f440add80ba35e585d83697d9dae44d3e2`](https://github.com/manaflow-ai/cmux/commit/1956d7f440add80ba35e585d83697d9dae44d3e2) | Define relay cleanup cancellation contract. | Docs-only, `git diff --check`; runtime implementation remains separate. | `git revert 1956d7f440add80ba35e585d83697d9dae44d3e2` |
| [`51294051938830a1e3d3013a256d851ad4cfa1d3`](https://github.com/manaflow-ai/cmux/commit/51294051938830a1e3d3013a256d851ad4cfa1d3) | Remove the redundant initial build step from TUI setup. | Docs-only, `git diff --check`; users still need the canonical build path. | `git revert 51294051938830a1e3d3013a256d851ad4cfa1d3` |
| [`8af5331e27b832eb517bb5c1892391348b5cb6e9`](https://github.com/manaflow-ai/cmux/commit/8af5331e27b832eb517bb5c1892391348b5cb6e9) | Route runtime diagnostics through the client log. | Hosted TUI runtime check required; raw-terminal ownership and log backpressure remain risks. | `git revert 8af5331e27b832eb517bb5c1892391348b5cb6e9` |
| [`409e9dc1620d47489313752f6cae4b5987d7b274`](https://github.com/manaflow-ai/cmux/commit/409e9dc1620d47489313752f6cae4b5987d7b274) | Add headerless sidebar rails and `+` action rows. | Hosted Rust/UI compile and focused behavior checks required; full visual parity remains open. | `git revert 409e9dc1620d47489313752f6cae4b5987d7b274` |
| [`2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278`](https://github.com/manaflow-ai/cmux/commit/2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278) | Define the cross-language socket-discovery contract. | Docs-only, `git diff --check`; every binding still needs exact-contract tests. | `git revert 2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278` |
| [`91b991496de2667a22e65176a8f11f715e6c089b`](https://github.com/manaflow-ai/cmux/commit/91b991496de2667a22e65176a8f11f715e6c089b) | Reject empty explicit socket paths. | TypeScript Unix-transport test added; hosted cross-language path checks remain required. | `git revert 91b991496de2667a22e65176a8f11f715e6c089b` |
| [`02d1ad45eee31f5d06bad8721b27109eda9c5b6c`](https://github.com/manaflow-ai/cmux/commit/02d1ad45eee31f5d06bad8721b27109eda9c5b6c) | Group terminal-client stream-supervisor state. | Hosted Rust compile/tests required; lifecycle ordering is not proven by refactoring alone. | `git revert 02d1ad45eee31f5d06bad8721b27109eda9c5b6c` |
| [`8cacdf3a375316469672e0e7994eb27190da2318`](https://github.com/manaflow-ai/cmux/commit/8cacdf3a375316469672e0e7994eb27190da2318) | Apply hosted rustfmt to the terminal client. | Formatter-only; `cargo fmt --check` hosted. | `git revert 8cacdf3a375316469672e0e7994eb27190da2318` |
| [`723f2079b3a23536f0deb0d953ed6732f60fa339`](https://github.com/manaflow-ai/cmux/commit/723f2079b3a23536f0deb0d953ed6732f60fa339) | Merge `origin/main` into the relay-tech-debt branch. | Merge integration only; exact-head Rust, SDK, and behavior checks required. | `git revert -m 1 723f2079b3a23536f0deb0d953ed6732f60fa339` |
| [`bf117369edd4fefba01d70de301df7ca9f32f73d`](https://github.com/manaflow-ai/cmux/commit/bf117369edd4fefba01d70de301df7ca9f32f73d) | Fix the macOS autostart clippy warning. | Hosted `cargo clippy`; no behavioral coverage added. | `git revert bf117369edd4fefba01d70de301df7ca9f32f73d` |
| [`ab5e7eb837ce9f11763d7863587acf6edda39042`](https://github.com/manaflow-ai/cmux/commit/ab5e7eb837ce9f11763d7863587acf6edda39042) | Resolve hosted clippy and test imports. | Hosted clippy and focused Rust tests; compile confidence is hosted-only. | `git revert ab5e7eb837ce9f11763d7863587acf6edda39042` |
| [`82ad9c3e555856a34a49617b7302e49a9c78d672`](https://github.com/manaflow-ai/cmux/commit/82ad9c3e555856a34a49617b7302e49a9c78d672) | Apply hosted rustfmt layout to TUI app code. | Formatter-only; hosted compile remains required. | `git revert 82ad9c3e555856a34a49617b7302e49a9c78d672` |
| [`39ba818933857c1d00f5d742349497938091888d`](https://github.com/manaflow-ai/cmux/commit/39ba818933857c1d00f5d742349497938091888d) | Record the relay formatting tail in the board. | Docs-only, `git diff --check`; no runtime claim. | `git revert 39ba818933857c1d00f5d742349497938091888d` |
| [`c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8`](https://github.com/manaflow-ai/cmux/commit/c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8) | Share socket text-send handling for heartbeat and outbound frames. | Hosted relay tests required; producer cancellation and reconnect ordering remain open. | `git revert c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8` |
| [`4d9681833950f454c27060f62d800897ab2488ee`](https://github.com/manaflow-ai/cmux/commit/4d9681833950f454c27060f62d800897ab2488ee) | Bound heartbeat intervals to the Node timer limit. | Boundary tests and hosted cross-language timer checks required; reconnect liveness remains open. | `git revert 4d9681833950f454c27060f62d800897ab2488ee` |
| [`ba8f2941a6b3b32ce73c295605bec86fa1cdc010`](https://github.com/manaflow-ai/cmux/commit/ba8f2941a6b3b32ce73c295605bec86fa1cdc010) | Clean fairness gauge and pending-byte accounting on failed sends. | Hosted relay fairness/disconnect tests required; starvation proof remains open. | `git revert ba8f2941a6b3b32ce73c295605bec86fa1cdc010` |
| [`4325b759694e57af819fd4075045431086717e02`](https://github.com/manaflow-ai/cmux/commit/4325b759694e57af819fd4075045431086717e02) | Service critical relay traffic in bounded bursts. | Hosted relay fairness tests required; queue ownership across retry and shutdown remains open. | `git revert 4325b759694e57af819fd4075045431086717e02` |
| [`2e33e1a07b5a25bccb93fb9e191539127163ab7e`](https://github.com/manaflow-ai/cmux/commit/2e33e1a07b5a25bccb93fb9e191539127163ab7e) | Release shell-start reservation after cap rejection. | Hosted PTY admission test required; process-group cleanup remains open. | `git revert 2e33e1a07b5a25bccb93fb9e191539127163ab7e` |
| [`05c0b30277f5ab9c22516b17a285756e0edbde32`](https://github.com/manaflow-ai/cmux/commit/05c0b30277f5ab9c22516b17a285756e0edbde32) | Merge the relay-tech-debt integration into `aggregate-final`. | Merge only; exact-head Rust, SDK, relay, and UI checks are required. | `git revert -m 1 05c0b30277f5ab9c22516b17a285756e0edbde32` |
| [`ddda4d5e9f9adbf9488e46c4b0e462d262d057ae`](https://github.com/manaflow-ai/cmux/commit/ddda4d5e9f9adbf9488e46c4b0e462d262d057ae) | Record the Wave 23 merge tail. | Docs-only, `git diff --check`; no runtime proof. | `git revert ddda4d5e9f9adbf9488e46c4b0e462d262d057ae` |
| [`f36f57d56ffe90f3ec0cee1069c40b52622f9468`](https://github.com/manaflow-ai/cmux/commit/f36f57d56ffe90f3ec0cee1069c40b52622f9468) | Fix the Java Unix-transport accept test race. | Focused Java UnixTransport test; hosted Java run remains required. | `git revert f36f57d56ffe90f3ec0cee1069c40b52622f9468` |
| [`41c5e637a587c2a7db84d0ddfcb2083894cedb73`](https://github.com/manaflow-ai/cmux/commit/41c5e637a587c2a7db84d0ddfcb2083894cedb73) | Clean up a watch before installing its handle. | Hosted relay watch tests required; disconnect cancellation and filesystem TOCTOU remain open. | `git revert 41c5e637a587c2a7db84d0ddfcb2083894cedb73` |
| [`97dbc18bfd0d83f4abfbe247024fb105f27a411d`](https://github.com/manaflow-ai/cmux/commit/97dbc18bfd0d83f4abfbe247024fb105f27a411d) | Signal raw PTY backlog overflow. | Hosted PTY overflow tests required; raw attach loss semantics remain incomplete. | `git revert 97dbc18bfd0d83f4abfbe247024fb105f27a411d` |
| [`e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a`](https://github.com/manaflow-ai/cmux/commit/e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a) | Bound Git workspace paths and status output. | Hosted relay workspace tests required; synchronous filesystem work and TOCTOU remain risks. | `git revert e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a` |
| [`df28816dba899e11296775a98182a583f431be88`](https://github.com/manaflow-ai/cmux/commit/df28816dba899e11296775a98182a583f431be88) | Correct Rust MSRV component installation syntax. | Workflow YAML/static validation and hosted MSRV job required. | `git revert df28816dba899e11296775a98182a583f431be88` |
| [`bcf0bb643b1031010deab5fa40040d31f2fc94f1`](https://github.com/manaflow-ai/cmux/commit/bcf0bb643b1031010deab5fa40040d31f2fc94f1) | Fix the Zig `Client.connect` resolved type. | Hosted Zig compile/tests required; cross-SDK socket parity remains open. | `git revert bcf0bb643b1031010deab5fa40040d31f2fc94f1` |
| [`8b61aede0bf33318d1bf9f5e04d19bab5256e88b`](https://github.com/manaflow-ai/cmux/commit/8b61aede0bf33318d1bf9f5e04d19bab5256e88b) | Close the Java Unix transport on EOF. | Focused Java transport test; hosted interruption and reconnect checks remain required. | `git revert 8b61aede0bf33318d1bf9f5e04d19bab5256e88b` |
| [`57b8bbeba9c5d44385e1530682c9299ca3db0db6`](https://github.com/manaflow-ai/cmux/commit/57b8bbeba9c5d44385e1530682c9299ca3db0db6) | Satisfy full-workspace clippy. | Hosted `cargo clippy`; no new behavior proof. | `git revert 57b8bbeba9c5d44385e1530682c9299ca3db0db6` |
| [`d85629e39e82e5560818af811bf0f35a255686ce`](https://github.com/manaflow-ai/cmux/commit/d85629e39e82e5560818af811bf0f35a255686ce) | Pass rustup components as separate workflow flags. | Workflow static check and hosted workflow run required. | `git revert d85629e39e82e5560818af811bf0f35a255686ce` |
| [`051d8c17b2a117414245c71c6e02ffb40214554d`](https://github.com/manaflow-ai/cmux/commit/051d8c17b2a117414245c71c6e02ffb40214554d) | Fix Zig connect allocation unwind. | Hosted Zig tests required; allocator failure coverage remains narrow. | `git revert 051d8c17b2a117414245c71c6e02ffb40214554d` |
| [`dfdcf8729466104544fda5a73d337f648b44346c`](https://github.com/manaflow-ai/cmux/commit/dfdcf8729466104544fda5a73d337f648b44346c) | Reject invalid Go transport write counts. | Go socket test added; hosted Go package and protocol checks remain required. | `git revert dfdcf8729466104544fda5a73d337f648b44346c` |
| [`d372eb573dad43bd127a29d9f1b64b1216bf68fa`](https://github.com/manaflow-ai/cmux/commit/d372eb573dad43bd127a29d9f1b64b1216bf68fa) | Close replaced C++ UnixTransport sockets on move assignment. | Hosted C++ transport tests required; move/EOF parity remains cross-SDK risk. | `git revert d372eb573dad43bd127a29d9f1b64b1216bf68fa` |
| [`6d364cf1718ba6fd60556304c411c0af146b2ba1`](https://github.com/manaflow-ai/cmux/commit/6d364cf1718ba6fd60556304c411c0af146b2ba1) | Pin socket runtime fallback order in TypeScript. | TypeScript fallback-order test added; hosted SDK matrix remains required. | `git revert 6d364cf1718ba6fd60556304c411c0af146b2ba1` |
| [`175243036f6a2625d4b9f469b142d6eee2ba40ad`](https://github.com/manaflow-ai/cmux/commit/175243036f6a2625d4b9f469b142d6eee2ba40ad) | Ignore non-contract temporary variables. | Hosted TypeScript tests required; legacy environment ambiguity remains. | `git revert 175243036f6a2625d4b9f469b142d6eee2ba40ad` |
| [`77520f11b8e30aef0bf7750e237b828c1661f644`](https://github.com/manaflow-ai/cmux/commit/77520f11b8e30aef0bf7750e237b828c1661f644) | Suppress TypeScript errors after transport close. | Unix-transport tests added; hosted close/reconnect and callback ordering remain required. | `git revert 77520f11b8e30aef0bf7750e237b828c1661f644` |
| [`5fe58262de2321833f1ee6a69c7391e494976eaf`](https://github.com/manaflow-ai/cmux/commit/5fe58262de2321833f1ee6a69c7391e494976eaf) | Centralize CLI boolean-flag metadata. | Hosted Rust CLI parser tests required; generated help/config parity remains open. | `git revert 5fe58262de2321833f1ee6a69c7391e494976eaf` |
| [`b94e6fd14b9d847bfdc272d90a2827f0781581db`](https://github.com/manaflow-ai/cmux/commit/b94e6fd14b9d847bfdc272d90a2827f0781581db) | Document connection-progress capability. | Docs/spec diff check; runtime capability negotiation remains unproven. | `git revert b94e6fd14b9d847bfdc272d90a2827f0781581db` |
| [`db18624a11397629d8219e4530516fa7009e5526`](https://github.com/manaflow-ai/cmux/commit/db18624a11397629d8219e4530516fa7009e5526) | Await the relay cleanup task after abort. | Hosted relay shutdown test required; all admitted-task ownership is not complete. | `git revert db18624a11397629d8219e4530516fa7009e5526` |
| [`9d0d631694852ec75eb33a1e15c2be44abcafb55`](https://github.com/manaflow-ai/cmux/commit/9d0d631694852ec75eb33a1e15c2be44abcafb55) | Test Python async-close cancellation joining. | `bindings/python/tests/test_resource_api.py`; hosted Python run required. | `git revert 9d0d631694852ec75eb33a1e15c2be44abcafb55` |
| [`b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068`](https://github.com/manaflow-ai/cmux/commit/b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068) | Bound the relay PTY backlog protocol. | Hosted relay PTY tests required; complete-frame admission and raw attach loss signaling remain separate. | `git revert b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068` |
| [`47082c21d40db9c956404e1483984dc8ef510c72`](https://github.com/manaflow-ai/cmux/commit/47082c21d40db9c956404e1483984dc8ef510c72) | Return an explicit relay PTY backlog overflow error. | Hosted PTY overflow behavior required; clients must handle closure and retry. | `git revert 47082c21d40db9c956404e1483984dc8ef510c72` |
| [`0a6a7e2e918e006299d4074197c7966b7d1dc3c6`](https://github.com/manaflow-ai/cmux/commit/0a6a7e2e918e006299d4074197c7966b7d1dc3c6) | Disconnect preview peers on queue saturation. | Hosted preview-proxy saturation test required; one-second flush and loss reporting remain open. | `git revert 0a6a7e2e918e006299d4074197c7966b7d1dc3c6` |
| [`8113a59bd5f5f8443e13277c7f45a096b07c0771`](https://github.com/manaflow-ai/cmux/commit/8113a59bd5f5f8443e13277c7f45a096b07c0771) | Centralize remote invocation classification. | Hosted Rust CLI tests required; non-Unix parity follows in the next commit. | `git revert 8113a59bd5f5f8443e13277c7f45a096b07c0771` |
| [`a6a900a96942f2e61570346f542ea4c7bd69712d`](https://github.com/manaflow-ai/cmux/commit/a6a900a96942f2e61570346f542ea4c7bd69712d) | Reuse invocation classification on non-Unix. | Hosted cross-platform compile/test required; platform-specific CLI behavior remains open. | `git revert a6a900a96942f2e61570346f542ea4c7bd69712d` |
| [`4b12ef9e070558bd3caa50fe8f6407319231863e`](https://github.com/manaflow-ai/cmux/commit/4b12ef9e070558bd3caa50fe8f6407319231863e) | Place connection-progress capability in the summary. | Docs/spec diff check; capability runtime remains unverified. | `git revert 4b12ef9e070558bd3caa50fe8f6407319231863e` |
| [`e8df21eed2866eba03b2548e790ba8a5a887b5da`](https://github.com/manaflow-ai/cmux/commit/e8df21eed2866eba03b2548e790ba8a5a887b5da) | Apply rustfmt to the preview saturation guard. | Formatter-only; hosted exact-head compile and relay tests remain required. | `git revert e8df21eed2866eba03b2548e790ba8a5a887b5da` |

## Final accepted tail from `e8df21eed2` to `ace9e5f57f`

This table records every commit after the previous documented tip. Revert
commands use full object IDs. “Hosted” means the focused check must run on the
hosted builder; this documentation worktree makes no local Rust test claim.

| Commit | Change | Tests / residual risk | Exact revert |
| --- | --- | --- | --- |
| [`c906a2ff62b73968b32d00e48072f5afe15d5351`](https://github.com/manaflow-ai/cmux/commit/c906a2ff62b73968b32d00e48072f5afe15d5351) | Reap the relay child process on every credential failure. | Hosted remote-provider failure test required; process-group and descendant cleanup remain open. | `git revert c906a2ff62b73968b32d00e48072f5afe15d5351` |
| [`fb3ac754c5d55869f968289e3906e3b6b6b0872e`](https://github.com/manaflow-ai/cmux/commit/fb3ac754c5d55869f968289e3906e3b6b6b0872e) | Own the journal-writer lifecycle in the TUI core. | Hosted journal/mux shutdown tests required; reducer ownership and restart recovery remain open. | `git revert fb3ac754c5d55869f968289e3906e3b6b6b0872e` |
| [`42b776a327c17386d131ef1b1f8a382b02683954`](https://github.com/manaflow-ai/cmux/commit/42b776a327c17386d131ef1b1f8a382b02683954) | Record the Wave 24 SDK and overflow tail in the board. | Docs-only, `git diff --check`; no runtime proof. | `git revert 42b776a327c17386d131ef1b1f8a382b02683954` |
| [`cef7c71460f72444e874f7c9f26100e9259874c1`](https://github.com/manaflow-ai/cmux/commit/cef7c71460f72444e874f7c9f26100e9259874c1) | Record the aggregate changelog at the prior tip. | Docs-only, `git diff --check`; superseded by this final-tip update. | `git revert cef7c71460f72444e874f7c9f26100e9259874c1` |
| [`ab2b944ab81a2ebf09a0c595b185344665f9c74f`](https://github.com/manaflow-ai/cmux/commit/ab2b944ab81a2ebf09a0c595b185344665f9c74f) | Hand journal-writer self-join back to the owner. | Hosted journal shutdown test required; cross-owner cancellation ordering remains open. | `git revert ab2b944ab81a2ebf09a0c595b185344665f9c74f` |
| [`5f6bf91e760c1feb97671aa19f800e3e4f80674d`](https://github.com/manaflow-ai/cmux/commit/5f6bf91e760c1feb97671aa19f800e3e4f80674d) | Use bindable legacy fallback sessions in the Rust SDK. | Hosted Rust SDK socket tests required; legacy path and long-name compatibility remain open. | `git revert 5f6bf91e760c1feb97671aa19f800e3e4f80674d` |
| [`8523b8f7151bdb032d011cb512a32e878fc813da`](https://github.com/manaflow-ai/cmux/commit/8523b8f7151bdb032d011cb512a32e878fc813da) | Name the Zig resolved connection result consistently. | Hosted Zig compile/tests required; cross-SDK result-shape parity remains open. | `git revert 8523b8f7151bdb032d011cb512a32e878fc813da` |
| [`5f8860398ee30e255f37cc5e8633159fb0058aa1`](https://github.com/manaflow-ai/cmux/commit/5f8860398ee30e255f37cc5e8633159fb0058aa1) | Coordinate journal finalization across ingress and mux. | Hosted journal finalization/restart tests required; append ownership and idempotency remain open. | `git revert 5f8860398ee30e255f37cc5e8633159fb0058aa1` |
| [`09190e6da92b60a60000913b9cbf9931ea4b94c7`](https://github.com/manaflow-ai/cmux/commit/09190e6da92b60a60000913b9cbf9931ea4b94c7) | Apply hosted formatting to journal finalization. | Formatter-only; hosted journal compile remains required. | `git revert 09190e6da92b60a60000913b9cbf9931ea4b94c7` |
| [`782fba0f2abe4f41c74a060caffa36a9c3efc73d`](https://github.com/manaflow-ai/cmux/commit/782fba0f2abe4f41c74a060caffa36a9c3efc73d) | Create missing parent directories for explicit sockets. | Hosted server socket tests required; permissions and symlink/TOCTOU policy remain open. | `git revert 782fba0f2abe4f41c74a060caffa36a9c3efc73d` |
| [`f5fdf26ccd8f931623adabe711b898b47665d722`](https://github.com/manaflow-ai/cmux/commit/f5fdf26ccd8f931623adabe711b898b47665d722) | Clean Unix sockets synchronously when the remote server drops. | Hosted remote drop/cleanup tests required; crash recovery and cross-platform parity remain open. | `git revert f5fdf26ccd8f931623adabe711b898b47665d722` |
| [`80fd1621fa8dfa5b25b5767f9711c8afa15e5b65`](https://github.com/manaflow-ai/cmux/commit/80fd1621fa8dfa5b25b5767f9711c8afa15e5b65) | Retain the socket lease until the listener task drops. | Hosted listener lifecycle tests required; abandoned-task cleanup remains open. | `git revert 80fd1621fa8dfa5b25b5767f9711c8afa15e5b65` |
| [`c8ec5be775352f54acb0707abc13efa6e4be163b`](https://github.com/manaflow-ai/cmux/commit/c8ec5be775352f54acb0707abc13efa6e4be163b) | Construct hashed fallback endpoints safely in Rust SDK clients. | Hosted Rust SDK fallback tests required; cross-language long-path parity remains open. | `git revert c8ec5be775352f54acb0707abc13efa6e4be163b` |
| [`44a2f0513465da2e81c484319f2e44827a0491d8`](https://github.com/manaflow-ai/cmux/commit/44a2f0513465da2e81c484319f2e44827a0491d8) | Apply hosted Rust formatting to SDK fallback changes. | Formatter-only; hosted SDK compile remains required. | `git revert 44a2f0513465da2e81c484319f2e44827a0491d8` |
| [`11c309d7013a5be96a9bc0d00a44f7b75e850399`](https://github.com/manaflow-ai/cmux/commit/11c309d7013a5be96a9bc0d00a44f7b75e850399) | Preserve executable mode for relay and cmux npm launchers. | Package artifact mode/smoke checks required; registry-install and platform matrix remain open. | `git revert 11c309d7013a5be96a9bc0d00a44f7b75e850399` |
| [`c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a`](https://github.com/manaflow-ai/cmux/commit/c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a) | Add coverage for 8-bit C1 cursor controls. | Focused cursor-provenance test; hosted TUI parser suite remains required. | `git revert c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a` |
| [`ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6`](https://github.com/manaflow-ai/cmux/commit/ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6) | Parse 8-bit C1 cursor controls in the TUI session parser. | Focused cursor-provenance test from the prior commit; hosted parser and compatibility tests remain required. | `git revert ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6` |

## User-session intent audit

The following intents were mined from local `~/.codex` and `~/.claude` session
records and remain acceptance requirements. A code commit or documentation
entry is not completion evidence unless the stated behavior is exercised.

| Intent | Evidence | Current status |
| --- | --- | --- |
| One canonical session with stable device/session IDs across macOS and iPhone. | `/Users/lawrence/.codex/history.jsonl`, `/Users/lawrence/.claude/history.jsonl` | Open. No multi-device catalog and reorder proof. |
| PTY ownership survives cmux or renderer restart, with one worker per workspace. | `/Users/lawrence/.codex/sessions/2026/07/16/` rollout record | Open. No restart, duplicate-reader, or startup-order proof. |
| Versioned TUI IPC carries input, resize, focus, sequence, launch, and restart state with measured isolation. | Same 2026-07-16 rollout record | Open. No valid renderer/PTY performance result. |
| Stale panes and surfaces self-heal without duplicate viewers or orphan PTYs. | Local history and rollout records | Open. Reconnect and stale-host behavior need bounded tests. |
| Journal-first persistence restores projections, receipts, PTY intent, and host reboot outcomes. | `/Users/lawrence/.codex/history.jsonl`, `/Users/lawrence/.claude/history.jsonl` | Open. Snapshots and process restarts are not restore proof. |
| npm/PyPI packages install offline and pass executable smoke checks on supported targets. | `.github/workflows/cmux-tui-build-package.yml`, `tests/test_tui_npm_package_artifact.py` | Partial. Hosted publish and registry-install proof remain open. |
| One authenticated socket/WebSocket/Iroh contract supports ordered events, bounded frames, reconnect, and close. | Local history and socket contract docs | Open. Cross-transport exact-head tests remain required. |
| Remote attach and Iroh discovery preserve PTY ownership, latency, reconnect, and cleanup. | Local history and Iroh preflight records | Open. Existing preflight did not establish a live host/socket. |
| Cloud snapshots package tools only, never serve as live PTY persistence or restart guarantees. | Local cloud-session records | Explicit no-go. Provider restore semantics and secret boundaries remain unproven. |
| Semantic colors, cursor, font, graphics, and theme-query behavior match Ghostty across platforms. | Local history and [PR #10612](https://github.com/manaflow-ai/cmux/pull/10612) | Open. `theme.chrome=auto` documentation/runtime mismatch remains. |

## Residual risks and verification boundary

- Queue count and byte caps do not yet prove producer cancellation, permit
  release, or ownership across disconnect, retry, and shutdown.
- PTY admission bounds complete frames, but raw attach backlog loss still lacks
  a complete rejection or loss signal and late output after close needs a
  contract.
- Synchronous filesystem work and canonicalization can block request paths;
  validation and later use retain a parent-directory TOCTOU window.
- Relative PTY cwd migration needs an absolute or home-relative contract, and
  Iroh teardown can wait through a long pre-auth timeout.
- The 25-file integration merge needs exact-head Rust, SDK, relay, and UI
  checks. No local Rust compile or end-to-end hosted result is claimed here.
- Journal finalization and self-join handoff now have explicit owners, but
  restart recovery, abort races, and durable outcome receipts still need an
  end-to-end hosted test.
- Explicit socket parent creation, synchronous unlink, and lease retention
  improve cleanup, but permissions, symlink/TOCTOU behavior, crash recovery,
  and abandoned listener tasks remain open.
- The npm executable-mode fix and C1 cursor parser tests cover narrow artifact
  and parser paths only. Registry installation, platform parity, and complete
  terminal escape compatibility remain unverified.

Session ledger honesty: the board's lower bound is at least 205 substantive
agent turns, including audits, research, session mining, fixes, reviews, and
merge gates. It is not an exact session-file count. The requested 10,000-session
goal was not reached. Empty or duplicate turns were not created to inflate it.

# Latest wave: exact-head review follow-ups

| Commit | Change | Verification / residual risk | Exact revert |
| --- | --- | --- | --- |
| `57b598c863714e1d074231f7ed8a9c0222963139` | Restore Go's canonical temporary-socket fallback. | Go fallback contract checks; hosted Go matrix remains required. | `git revert 57b598c863714e1d074231f7ed8a9c0222963139` |
| `5abb5e0a6088fd4a16e764fd063f4b72bcfde9e3` | Expose the exact C++ parent include and add the CMake include path. | C++ configure/build check required; package consumers remain unverified. | `git revert 5abb5e0a6088fd4a16e764fd063f4b72bcfde9e3` |
| `ed634f53afa5367749584f9c0dc2d3ba5b96b964` | Bound Rust workspace reads and hashes. | Hosted Rust SDK check required; limits may reject unusually large workspaces. | `git revert ed634f53afa5367749584f9c0dc2d3ba5b96b964` |
| `ab75ec0fdd6c3a649e1d938e92d6d852cd7eb2a3` | Stop the watcher after outbound sink failure. | Hosted relay shutdown check required; producer cancellation remains separate. | `git revert ab75ec0fdd6c3a649e1d938e92d6d852cd7eb2a3` |
| `5218c11559b56e902a713e68024dd954a0a15e8c`, `527626f6311a2b99cf51c682048af2509169943f` | Borrow owned cleanup tasks and own the shell-start waiter and manager clone. | Hosted preview and process-cleanup checks required. | `git revert 527626f6311a2b99cf51c682048af2509169943f 5218c11559b56e902a713e68024dd954a0a15e8c` |

## Current exact-head tail

| Commit | Change | Exact revert |
| --- | --- | --- |
| `84f5a54428c2d61d4768aeda0f14afcf5678436e` | Record the prior wave review and fix ledger. | `git revert 84f5a54428c2d61d4768aeda0f14afcf5678436e` |
| `d4c17024fc567f1bff2877da049a8493908e4287` | Merge the relay tech-debt branch into the aggregate. | `git revert -m 1 d4c17024fc567f1bff2877da049a8493908e4287` |
| `e41620873cc1f6bfeca672b7d9ec4b6f7dbd460e` | Declare the Windows job-object dependency. | `git revert e41620873cc1f6bfeca672b7d9ec4b6f7dbd460e` |
| `2d55654d2be47dfa62ee2266a0b6b6412af106b8` | Record the Windows dependency in the lockfile. | `git revert 2d55654d2be47dfa62ee2266a0b6b6412af106b8` |
| `96d8f406a1288e644a40d3b950ea544d9898f3d8` | Expose path validation and classify configuration errors. | `git revert 96d8f406a1288e644a40d3b950ea544d9898f3d8` |
| `67fbafa3d67b223bb79b9bdd7cfd2bac1e406b72` | Remove unused shell cwd state. | `git revert 67fbafa3d67b223bb79b9bdd7cfd2bac1e406b72` |
| `2bffa3dcc83808f66718a84bad05e3384e6ca313` | Tighten watch registry API and conditions. | `git revert 2bffa3dcc83808f66718a84bad05e3384e6ca313` |
| `954d80df6ac54ff767e9d56a4caaad83e02c48bd` | Resolve workspace clippy diagnostics. | `git revert 954d80df6ac54ff767e9d56a4caaad83e02c48bd` |
| `4538c10aa528a6c4c0435fba238d1a9573acbb82` | Resolve preview proxy clippy diagnostics. | `git revert 4538c10aa528a6c4c0435fba238d1a9573acbb82` |
| `925d1e7a54573e3fceea193207a53200fca4c5a1` | Preserve preview ping payload ownership. | `git revert 925d1e7a54573e3fceea193207a53200fca4c5a1` |
| `ea4348b827ef7fc55cc8bc0775b8c8ae4c8f753e` | Remove an unused shell cwd test binding. | `git revert ea4348b827ef7fc55cc8bc0775b8c8ae4c8f753e` |
| `f7471b21e6a4a0e5cac745e78202d4470b87abb5` | Merge the latest relay tech-debt history into the aggregate. | `git revert -m 1 f7471b21e6a4a0e5cac745e78202d4470b87abb5` |
| `52fbf8153ff2c4a1e518ea8e0b792c25c6439964` | Merge the pushed remote relay history while retaining the reviewed aggregate tree. | `git revert -m 1 52fbf8153ff2c4a1e518ea8e0b792c25c6439964` |
| `08ac5efcc55c10b6055448538b72390fe0ffec52` | Record the current exact tip, review result, and revert ledger. | `git revert 08ac5efcc55c10b6055448538b72390fe0ffec52` |
| `769a8eb5c0a95c2fbcc024127bc3d2e435dfce02` | Refresh the aggregate head, branch-count, and PR-board metadata. | `git revert 769a8eb5c0a95c2fbcc024127bc3d2e435dfce02` |

The exact-head autoreview was clean for in-scope changes. It reported two
out-of-scope remote-tmux findings, which were intentionally ignored: they do
not affect cmux-tui protocol, SDK, relay, or preview ownership in this wave.

# Historical exact-state correction (2026-08-24)

The exact documentation tip is `df419568b0490c794ec1230244936f70bf2e118f`.
The branch is 556 commits ahead of `origin/main`. The substantive-turn lower
bound is at least 205.

# Historical post-correction exact tail (2026-08-24)

The previous aggregate tip was `c599fa778e506574bddf12393d4a9bb91c4772e5`,
583 commits ahead of `origin/main`. The current code tip is
`17413db11cc0ebb7b0b5c254447cede3faaad0cf`, 585 commits ahead before this
documentation update.

| Commit | Change | Exact revert |
| --- | --- | --- |
| `4c74c0f22d0931d8f51029f5b12c3a2008324b03` | Bound Go SDK close cleanup by context. | `git revert 4c74c0f22d0931d8f51029f5b12c3a2008324b03` |
| `462a66fbf3b8b64e2bf3bf078bcbd68b1261428a` | Reject directory paths as C++ hashed sockets. | `git revert 462a66fbf3b8b64e2bf3bf078bcbd68b1261428a` |
| `af758848e0c7d120ef54b955553f35c5d9391416` | Pin BSD Unix socket capacities in Go tests. | `git revert af758848e0c7d120ef54b955553f35c5d9391416` |
| `f8220a4ba73012654e311fb217952c0c495421eb` | Use BSD Unix socket path limits in Go. | `git revert f8220a4ba73012654e311fb217952c0c495421eb` |
| `d50300c260851c9dd5e5ead975c74504914cc501` | Gate relay platform-specific imports. | `git revert d50300c260851c9dd5e5ead975c74504914cc501` |
| `79e46a998b8c9456293356274d13b84d763ab3b5` | Bound relay output drain after forced timeout. | `git revert 79e46a998b8c9456293356274d13b84d763ab3b5` |
| `0e1ab67f1abe66bbdd04dbf21bdef80bcd34ba37` | Collapse the Rust legacy socket fallback condition. | `git revert 0e1ab67f1abe66bbdd04dbf21bdef80bcd34ba37` |
| `b0d35b3396a217d468275e50c91e79e4e65cba0c` | Merge the latest relay tech-debt history. | `git revert -m 1 b0d35b3396a217d468275e50c91e79e4e65cba0c` |
| `9d5ee3819e80e1ea5745f16a55367c130db1a760` | Use the imported JSON value type in TUI session code. | Hosted Rust formatting and package checks remain required. | `git revert 9d5ee3819e80e1ea5745f16a55367c130db1a760` |
| `fcb5d410784f31fa34249e1c39e6213cc4140360` | Collapse the inline global-option parser condition. | Hosted Rust clippy confirms the let-chain on the exact head. | `git revert fcb5d410784f31fa34249e1c39e6213cc4140360` |
| `d3374b01b800cab1f13a62148804e84a3ddd26fb` | Apply hosted rustfmt to TUI session code. | Formatter-only; hosted compile remains required. | `git revert d3374b01b800cab1f13a62148804e84a3ddd26fb` |
| `8200e92d9c8181a113600f9e55e540f2761dc864` | Merge the latest remote TUI fixes into the aggregate. | Remote ancestry is preserved with the reviewed aggregate tree. | `git revert -m 1 8200e92d9c8181a113600f9e55e540f2761dc864` |
| `99d8911076450e3dd0be58faf5aab1228968a7f3` | Reap completed preview connection tasks before accepting more requests. | Tokio JoinSet cleanup is nonblocking; active tasks still join on shutdown. | `git revert 99d8911076450e3dd0be58faf5aab1228968a7f3` |
| `8ca169c9e8761fa360d33966a46d25fe11c36e43` | Reap completed relay action and PTY tasks during a live connection. | Unexpected task failure ends the session for safe reconnect; shutdown still awaits all tasks. | `git revert 8ca169c9e8761fa360d33966a46d25fe11c36e43` |
| `1dea79f1ac19a2f7c45a1b813c69039bff17dd19` | Bound unknown frame-type diagnostics to 64 recent names. | Diagnostic retention is bounded; repeated evictions can log a type again. | `git revert 1dea79f1ac19a2f7c45a1b813c69039bff17dd19` |
| `c599fa778e506574bddf12393d4a9bb91c4772e5` | Apply hosted rustfmt to task-reaping changes. | Formatter-only; hosted relay behavior remains required. | `git revert c599fa778e506574bddf12393d4a9bb91c4772e5` |
| `17413db11cc0ebb7b0b5c254447cede3faaad0cf` | Bound preview task reaping to 32 completions per event-loop turn. | Preserves listener and shutdown fairness under instant connection churn. | `git revert 17413db11cc0ebb7b0b5c254447cede3faaad0cf` |

# Current wave: protocol and I/O lifecycle corrections

The exact local source tip for this wave is `e4f527bc00af27346b0e628f76f907ef34531d82`.
The branch is 808 commits ahead of `origin/main`. Hosted checks must use the
pushed exact SHA. No local Rust build or test claim is made.

| Commit | Change | Verification / residual risk | Exact revert |
| --- | --- | --- | --- |
| `29145d800c822b45575cd00aba0628d62ba2ac48` | Sync the vendored relay wire contract with chatmux protocol v7 and gate typed PTY operational errors by negotiated version. | Official chatmux source audit and static review completed. Exact-head hosted protocol, relay, and SDK checks remain required. | `git revert 29145d800c822b45575cd00aba0628d62ba2ac48` |
| `cd76c82e3d3045af898e7dfc65c9fba46c2c7a4f` | Classify relay output-cap overflow as `overflow` at v7 and preserve safe downgrade messages for older workers. | Focused compatibility tests added. Hosted exact-head relay tests remain required. | `git revert cd76c82e3d3045af898e7dfc65c9fba46c2c7a4f` |
| `2f3e4783857f5936e3559fcedcf1c4663090045a` | Add cancellation regression coverage for pre-write rejection and partial Unix-socket writes. | Static formatting and diff checks pass. Hosted Rust stream tests remain required. | `git revert 2f3e4783857f5936e3559fcedcf1c4663090045a` |
| `ec074f4b536bd318ff932e315b087c1e157e8db3` | Retire a cancellation send after any write error so a partial frame cannot be retried. | Uses `ready -> sending -> retired`; official Tokio cancellation guidance supports the invariant. Hosted Rust stream tests remain required. | `git revert ec074f4b536bd318ff932e315b087c1e157e8db3` |
| `c4e842cc55e01a355331b6ea7e4c1ced31d90041` | Drain `git diff` stderr continuously, retain a bounded prefix, abort on cancellation, and bound inherited-descriptor drain time. | Duplex regression test added. Hosted workspace tests remain required. | `git revert c4e842cc55e01a355331b6ea7e4c1ced31d90041` |
| `e4f527bc00af27346b0e628f76f907ef34531d82` | Reuse bounded stderr ownership for `git status`, including read-error cleanup and retention-cap coverage. | Static formatting and diff checks pass. Hosted workspace tests must prove no pipe backpressure. | `git revert e4f527bc00af27346b0e628f76f907ef34531d82` |
| `USER-REQUEST-BOARD.md` | Record session-mined unfinished requests and the simplification rule. | Documentation only. Session evidence is intent, not completion proof. | Revert the documentation commit containing this file. |

Official pattern references used for the I/O decisions:

- [Tokio `AsyncWriteExt`](https://docs.rs/tokio/latest/src/tokio/io/util/async_write_ext.rs.html), `write_all` is not cancellation-safe.
- [Tokio `JoinHandle`](https://docs.rs/tokio/latest/tokio/task/struct.JoinHandle.html), dropping detaches and aborting must be awaited.
- [Tokio process](https://docs.rs/tokio/latest/tokio/process/struct.Command.html), child cleanup and inherited descriptors need explicit ownership.
- [Rust `Write`](https://doc.rust-lang.org/std/io/trait.Write.html), partial writes require explicit progress handling.
