# cmux TUI PR intent and merge board

Current snapshot: 2026-08-27T15:12:37Z. This board is pinned to
`origin/main` at [`08b43d87d1426c11aa879b37f79db9aeffed187d`](https://github.com/manaflow-ai/cmux/commit/08b43d87d1426c11aa879b37f79db9aeffed187d),
committed 2026-08-27T07:27:51-07:00 with subject
`Bound app event enqueue and wake blocked producers`. The working branch
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
[#10959](https://github.com/manaflow-ai/cmux/pull/10959),
[#10973](https://github.com/manaflow-ai/cmux/pull/10973), and
[#10929](https://github.com/manaflow-ai/cmux/pull/10929), and
[#10974](https://github.com/manaflow-ai/cmux/pull/10974). The latest merge adds
bounded event enqueue and producer wake-up after the bounded relay lifecycle,
response-send, startup, redraw, frame-area, diagnostics, draw/paint, Sentry,
and Escape tail. Source
heads, authors, merge times, and merge
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
| [#10973](https://github.com/manaflow-ai/cmux/pull/10973) | Lawrence Chen | `ed9497e9f00fdbb12ff7b412468d6ef9db8635b6` | 2026-08-27 13:26:49 | `d5ad6eb41426d0ab1b612f3b3fa7321365a6cb66` |
| [#10929](https://github.com/manaflow-ai/cmux/pull/10929) | Lawrence Chen | `8ba9a3869c83e1f1f1b83e1781d484490e2aea40` | 2026-08-27 13:56:43 | `31a74487e1f824b450eaf0c2b43f0d77fe51563c` |
| [#10974](https://github.com/manaflow-ai/cmux/pull/10974) | Lawrence Chen | `255c329337417ede7eb06cfcc18d62db17dc56bf` | 2026-08-27 14:27:51 | `08b43d87d1426c11aa879b37f79db9aeffed187d` |

## Current open-PR inventory

This bounded inventory was re-queried for the 2026-08-27T15:12:37Z snapshot.
Hosted checks and review states can change; these rows are not merge approval.

| PR | Author | Base | Exact head | Current gate |
| --- | --- | --- | --- | --- |
| [#10966](https://github.com/manaflow-ai/cmux/pull/10966) | Lawrence Chen | `main` | `0b2d3fc6f866bcb5986daf6660db36a29b3ac7e9` | CLEAN; all observed hosted checks pass, including seven-language live conformance. |
| [#10975](https://github.com/manaflow-ai/cmux/pull/10975) | Lawrence Chen | `main` | `9720c41a6e26b2c7ad2c8b6aef0471e16454ee7d` | UNSTABLE; seven-language live conformance is pending; other listed checks pass. |
| [#10976](https://github.com/manaflow-ai/cmux/pull/10976) | Lawrence Chen | `main` | `9590631123d0e5fdbef5bc5b067bd228e7871ec4` | CLEAN; visible checks pass, exact-head review remains required. |
| [#10891](https://github.com/manaflow-ai/cmux/pull/10891) | Lawrence Chen | `main` | `49d6310eb15fd785839a023ccc0c4e0a407438db` | UNSTABLE; `ci-status`, `linux-preflight`, `tests`, and `workflow-guard-tests` fail; other listed checks and CodeRabbit pass; two accepted P2 fixes remain pending. |
| [#10612](https://github.com/manaflow-ai/cmux/pull/10612) | Lawrence Chen | `main` | `dd8cea6d13a7a19c81a821c88a4d23b5b5c92570` | UNSTABLE; seven-language live conformance failed; canonical after documentation fix. |

Disposition audit: still-open superseded, close [#10743](https://github.com/manaflow-ai/cmux/pull/10743),
[#10744](https://github.com/manaflow-ai/cmux/pull/10744), and
[#10750](https://github.com/manaflow-ai/cmux/pull/10750). Keep
[#10513](https://github.com/manaflow-ai/cmux/pull/10513) blocked and
[#10612](https://github.com/manaflow-ai/cmux/pull/10612) canonical after its
documentation fix. [#10800](https://github.com/manaflow-ai/cmux/pull/10800) and
[#10812](https://github.com/manaflow-ai/cmux/pull/10812) are superseded by merged
[#10887](https://github.com/manaflow-ai/cmux/pull/10887); residual cloud hardening
remains open.

Closed superseded PRs in this snapshot:

| PR | Author | Head at close | Closed at (UTC) | Disposition |
| --- | --- | --- | --- | --- |
| [#10736](https://github.com/manaflow-ai/cmux/pull/10736) | lawrencecchen | `2fed9d4c6d0d548ee20751afedb2d53b4598b09c` | 2026-08-27 14:35:16 | Closed without merge; preview intent remains unproven. |
| [#10946](https://github.com/manaflow-ai/cmux/pull/10946) | lawrencecchen | `e062c7f5130be5e9641a07f6120b0f9cfdb8de24` | 2026-08-27 14:35:19 | Closed without merge; superseded preview follow-up. |
| [#10800](https://github.com/manaflow-ai/cmux/pull/10800) | lawrencecchen | `fd4730a71cc3c7ac60cb333cb15bc092d6fa4f4d` | 2026-08-27 14:37:19 | Closed without merge; cloud design superseded by [#10887](https://github.com/manaflow-ai/cmux/pull/10887). |
| [#10812](https://github.com/manaflow-ai/cmux/pull/10812) | austinywang | `a44314f6e9eaf42925dc1d6c9dfb0a20b021b4a1` | 2026-08-27 14:37:21 | Closed without merge; cloud projection superseded by [#10887](https://github.com/manaflow-ai/cmux/pull/10887). |
| [#10252](https://github.com/manaflow-ai/cmux/pull/10252) | lawrencecchen | `000c30e730a6e6b1cbb34f752cdd2bf320e74f38` | 2026-08-27 14:37:51 | Closed without merge; stale Windows benchmark thread. |
| [#10882](https://github.com/manaflow-ai/cmux/pull/10882) | ninjin0802 | `d69d150c11738f8165fe7538d282620b9ede9a45` | 2026-08-27 14:49:06 | Closed without merge; diagnostics work superseded by merged changes. |
| [#10213](https://github.com/manaflow-ai/cmux/pull/10213) | lawrencecchen | `911ee5304feba9b816fd59806c75bb41ca8db00c` | 2026-08-27 14:49:08 | Closed without merge; redraw intent remains subject to behavior proof. |
| [#10201](https://github.com/manaflow-ai/cmux/pull/10201) | lawrencecchen | `a398cd63bbcd87e6131a6b9f5e4cf04110dc196f` | 2026-08-27 14:49:11 | Closed without merge; resize blank-space intent remains unmet. |

## Current audit additions

| Area | Evidence and current state | Required proof or next action |
| --- | --- | --- |
| Completion subscription | Completion-subscription design note recorded in the 2026-08-27 audit. | Open; subscribe before work and prove one typed result, cancellation, timeout, and duplicate delivery. |
| Cross-platform startup benchmark | Session archaeology dated 2026-08-09. | Open; owner unassigned. Measure event-based cold, warm, restore, incompatible, and headless startup on macOS, Linux, and Windows. |
| PTY and layout ownership | Session archaeology and [#9903](https://github.com/manaflow-ai/cmux/pull/9903). | Open; owner unassigned. Decouple PTY resources from layout views and prove multi-view attachment without duplicate readers. |
| [#9903](https://github.com/manaflow-ai/cmux/pull/9903) dependency order | Audit against [#8378](https://github.com/manaflow-ai/cmux/pull/8378), [#9785](https://github.com/manaflow-ai/cmux/pull/9785), [#9647](https://github.com/manaflow-ai/cmux/pull/9647), [#9682](https://github.com/manaflow-ai/cmux/pull/9682), [#9846](https://github.com/manaflow-ai/cmux/pull/9846), [#9933](https://github.com/manaflow-ai/cmux/pull/9933), and [#9806](https://github.com/manaflow-ai/cmux/pull/9806). | Open; owner unassigned. Publish a dependency graph and bottom-up landing order. |
| Claude resize and alternate-screen scroll | Claude report at `~/.claude/history.jsonl:90798` says wheel input reaches Claude Code as arrow keys. Current path is `cmux-tui/crates/cmux-tui/src/app.rs:23053-23099`; crossterm classifies scroll and Ghostty receives wheel events when tracking is enabled, while the fallback emits arrows. Resize blank-space behavior remains unproven after closed [#10201](https://github.com/manaflow-ai/cmux/pull/10201). | Open and unmet. Preserve the resize invariant, define configurable scroll policy and modifier override, and add behavior proof. |
| Wave65 bounded enqueue audit | Merged [#10974](https://github.com/manaflow-ai/cmux/pull/10974), source `255c3293`, merge `08b43d87`; hosted run [`33080531391`](https://github.com/manaflow-ai/cmux/actions/runs/33080531391) passed. | Merged code is recorded; repeat enqueue, cancellation, and producer wake-up proof on the pinned head. |

The bounded open-PR inventory retained below was captured before the d65 merge.
It retains exact heads, check rollups, GitHub state, and classifications without
pretending they are current. Run a fresh `gh pr view` and checks query before
acting on any row.

The retained session receipt supports at least 263 named substantive turns,
including five named turns from the preceding audit. This refresh adds named
rows but no unverified session count. The figure is a verifiable lower bound,
not a total session count, and no 10,000-session claim is made.

Dependent open intents require separate review: [#10742](https://github.com/manaflow-ai/cmux/pull/10742) (`befdff972f563f851ef27e38bbbb115269b4769a`, manual I/O). Its open state is not acceptance evidence. Closed [#10736](https://github.com/manaflow-ai/cmux/pull/10736) and superseded [#10812](https://github.com/manaflow-ai/cmux/pull/10812) are tracked only in the disposition note above.

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
