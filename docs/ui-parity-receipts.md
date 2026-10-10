# UI parity receipts

This ledger records the source heads and review surfaces for the current gallery parity batch. The
source heads below are the exact remote PR heads observed on 2026-10-10. A local test or gallery
build proves the fixture and source checks ran; it is not a hosted visual capture. Known public
GitHub artifact bundles are linked below where available. An artifact proves that a hosted job
uploaded files, not that every play passed; stale-head captures and reported play failures are
called out explicitly. Missing or stale current-head captures remain pending.

| PR | Source head | Gallery entry and variants | Viewport widths (narrow / normal / wide) | Hosted matrix |
| --- | --- | --- | --- | --- |
| [#19001](https://github.com/manaflow-ai/cmux/pull/19001) | `cb177e1649d6a5db0219c8fc03eefcff1f5c4472` | `agent-pane.file-search`: `idle`, `matches`, `pick`, `no-results`, `truncated`, `outside-repository`, `escape` | 360 / 520 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064049394#artifacts); current head |
| [#19007](https://github.com/manaflow-ai/cmux/pull/19007) | `2598c7615c4ddb9b4f1312020b7b9b6ffa433d66` | `agent-pane.question-card`: `pending-single`, `multi-preview`, `submit`, `four-tabs`, `other-typing`, `answered-remote`, `cancelled`, `escape`, `skip` | 360 / 540 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064057465#artifacts); current head |
| [#19011](https://github.com/manaflow-ai/cmux/pull/19011) | `6e2ce01dca54c23efc7a951b2ad32f831ed39df7` | `agent-pane.permission-panel`: `pending`, `expanded`, `allow-once`, `collecting`, `receipt`, `allowance`, `error`, `uncertain` | 360 / 540 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38063939758#artifacts); current head; 1 play failure reported |
| [#19021](https://github.com/manaflow-ai/cmux/pull/19021) | `cfb567dffb26a77ff15f08a61cca75e50b36b699` | `agent-pane.diff-panel`: `last-turn`, `toolbar`, `tree-selection`, `open-file-error`, `escape`, `loading`, `error`, `empty`, `loaded-scope` | 520 / 860 / 1180 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38063526286#artifacts); current head; 6 play failures reported |
| [#19034](https://github.com/manaflow-ai/cmux/pull/19034) | `46283bd7fd044bebff58d00b6821d2b6321db681` | `agent-pane.home-lists`: `baseline`, `empty`, `cap-filter`, `click`, `keyboard` | 360 / 560 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38055198502#artifacts); current head |
| [#19048](https://github.com/manaflow-ai/cmux/pull/19048) | `de454fbf7836e4815be50cd3087a1788dc944544` | Gallery report code; no component entry | N/A; report-only fixture | Prior-head [artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38054995451#artifacts) at `59ca884c4b09caf8d19ea4fa170c554a244d71ad`; current head pending |
| [#19052](https://github.com/manaflow-ai/cmux/pull/19052) | `3edb5f8ee4ff9bab3f30c5c7ab7ff7d1075b54f1` | `agent-pane.checkpoint-review`: `create-selection`, `keyboard-selection`, `partial-receipt`, `copy-replacement`, `retained` | 360 / 520 / 720 px | Prior-head [artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38055851655#artifacts) at `f9dbff74c2c5a41a1d01a61f348a6f5bfa555ad5`; current head pending |
| [#19053](https://github.com/manaflow-ai/cmux/pull/19053) | `098e2b022775c8ba190b9afe8c8b3b01fc305dad` | `agent-pane.handoff-review-message`: `draft`, `edit`, `checkpoint-gating`, `memory-disclosure`, `validation-error`, `error`, `starting`, `started` | 440 / 680 / 820 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064076695#artifacts); current head |
| [#19055](https://github.com/manaflow-ai/cmux/pull/19055) | `b3a1695660341c932bc49d40d627b22f707ad908` | `agent-pane.shell-rows`: `running`, `stop-receipt`, `collapsed`, `expanded`, `expand-output`, `succeeded`, `failed`, `stopped`, `keyboard-open`, `moved` | 390 / 640 / 860 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064083786#artifacts); current head |
| [#19058](https://github.com/manaflow-ai/cmux/pull/19058) | `9d208eaa7ca8eba7c4fcd08819bfb2e1c6e5e336` | `agent-pane.folder-choice`: `offered`, `keyboard`, `error` | 360 / 560 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38058201464#artifacts); current head |
| [#19061](https://github.com/manaflow-ai/cmux/pull/19061) | `ef891faf92b5c644d2acd4238581495f95742359` | Gallery report code stacked on #19048; no component entry | N/A; report-only fixture | Pending; no current-head artifact recorded |
| [#19072](https://github.com/manaflow-ai/cmux/pull/19072) | `b1cac282d993e445176d5ba4ba52ce5b0dc5c37f` | Gallery browse shell stale-variant recovery (`BrowseView` / `browseModel`); no component entry | N/A; shell-browse behavior | Pending; no hosted capture ID recorded |
| [#19078](https://github.com/manaflow-ai/cmux/pull/19078) | `37e5c15b021ab1edd15aa58793e774e0ac18db23` | `agent-pane.context-ring`: `unknown-usage`, `known-usage` | 360 / 520 / 720 px | [Published gallery artifact](https://github.com/manaflow-ai/cmux/actions/runs/38072393427#artifacts); ContextRing plays pass, WebKit reports warnings only; broader composer matrix reports 10 pre-existing play failures |

The component entries use the following interaction receipts and checks:

- **#19001, File search:** the matches play types `Composer` and checks the highlighted
  `aria-activedescendant`, ArrowDown movement, and result count; pick presses Enter and records
  the second result; no-results, truncated, outside-repository, and Escape plays cover empty,
  service-limit, repository-error, and dismissal states. The entry checks zero anchor movement,
  zero layout shift, a 33 ms long-frame limit, and a 250 ms settle budget. The PR reports
  focused typecheck, gallery-coverage test (6 passed; 55 entries, 531 variants), formatter
  check, 7-case manifest, gallery build, and diff check as passing locally.
- **#19007, Agent question card:** the multi-preview play moves the roving row and checks its
  preview; submit toggles two number-key choices and presses Enter; four-tabs switches prompts;
  other-typing preserves the inline answer; Escape hands focus back to the composer; Skip
  records dismissal. Static variants cover pending single, remote answered, and cancelled asks.
  The entry checks a 33 ms long-frame limit and a 350 ms settle budget. The PR reports focused
  typecheck, gallery-coverage test (6 passed; 55 entries, 533 variants), formatter check, 9-case
  manifest, gallery build, and diff check as passing locally.
- **#19011, Permission panel:** the expanded play opens command details; allow-once records the
  decision; receipt opens the resolved group; allowance exercises Revoke; error exercises
  Refresh; uncertain exercises Check and retry. Static variants cover pending and collecting
  groups. The entry checks a 33 ms long-frame limit and a 300 ms settle budget. The PR reports
  focused typecheck, gallery-coverage test (6 passed; 55 entries, 532 variants), formatter
  check, 8-case manifest, gallery build, and diff check as passing locally.
- **#19021, Changes diff panel:** the toolbar play toggles tree visibility, wrapping, and split
  layout; tree-selection reveals a selected file; open-file-error keeps the host refusal
  visible; Escape closes the reader; loading, error, empty, and loaded-scope exercise async git
  states and branch metadata. The entry uses 520 / 860 / 1180 px pane widths and declares no
  explicit `checks` block or settle budget. The PR reports formatter, typecheck,
  gallery-coverage test, 27-case narrow/normal/wide manifest, dry-run runner, gallery build, and
  diff check as passing locally.
- **#19034, Home session lists:** the click play activates `Polish the sidebar`; the keyboard play
  focuses `Fix the checkout page`, presses Enter, then focuses `Investigate the build cache` and
  presses Space. The entry requires zero anchor movement, zero layout shift, a 33 ms long-frame
  limit, and a 250 ms settle budget. The PR reports its HomeLists unit test, gallery coverage,
  typecheck, lint, gallery build, and diff check as passing.
- **#19052, Checkpoint review:** the create play checks `src/agent.test.ts`, clicks Create, and
  waits for the checkpoint reference. The keyboard play focuses that checkbox, presses Space,
  clicks Create, and waits for the same receipt. The copy-replacement play clicks Copy reference,
  waits for checkpoint B, and confirms the button returns. There is no explicit `checks` block and
  no `settleMaxMs` budget in this entry; hosted latency remains unmeasured. The PR reports gallery
  coverage, environment, pane-English, typecheck, lint, and gallery build checks as passing.
- **#19053, Handoff review message:** the edit play types context, opens the memory disclosure,
  and types a memory reference. Checkpoint gating types the checkpoint, confirms the checkbox,
  focuses Continue, and presses Enter. Memory disclosure opens the same details element; validation
  focuses Continue and presses Enter to expose the overlong-reference alert. The entry checks zero
  anchor movement, at most 0.05 layout shift, a 33 ms long-frame limit, and a 500 ms settle budget.
  The PR reports gallery coverage/environment, typecheck, lint, gallery build, and diff check as
  passing.
- **#19055, Shell transcript rows:** the Stop play clicks Stop; Open in terminal is exercised by
  both click and Enter; Expand output clicks Show all output and waits for Show less. Static
  variants cover running, succeeded, failed, stopped, collapsed, expanded, and MoveRow states. The
  entry checks zero anchor movement, a 33 ms long-frame limit, and a 250 ms settle budget. Its
  focused static-render test and gallery coverage, typecheck, lint, gallery build, and diff checks
  pass locally.
- **#19058, Folder choice notice:** the offered play clicks Choose Folder; the keyboard play
  focuses the same control and presses Enter; the error variant keeps the retry action visible.
  The entry checks zero anchor movement, zero layout shift, a 33 ms long-frame limit, and a 250 ms
  settle budget. The PR reports its folder contract test, gallery coverage/environment/pane-English,
  typecheck, lint, gallery build, and diff check as passing.

- **#19078, Context usage ring:** the unknown-usage play invokes the stable automation opener and verifies that no empty 0% popover appears; the known-usage play invokes the same opener and verifies the anchored details surface. Chromium passes at both states and widths. WebKit emits frame-time warnings only. The published matrix also reports unrelated existing composer failures for attachment layout shifts, queued/reasoning waits, model-menu shifts, mode-switch shift, and a missing thread-minimap tick; those remain explicit follow-up work rather than being attributed to ContextRing.

The report-only PRs have synthetic, local comparison evidence rather than a viewport matrix:

- **#19048** adds `settleMs` to displayed step metrics and shows a base line when the base/head
  values differ. Its focused fixture compares identical 60 x 40 images with 80 ms base and 140 ms
  head settle values; the 15-test matrix comparison suite passed. This does not measure a real UI
  interaction.
- **#19061** keeps an unchanged screenshot with a settle regression visible under `Latency changed`
  instead of the folded unchanged list. Its focused fixture uses the same synthetic 60 x 40 image,
  80 ms base, and 140 ms head values; the 16-test comparison suite passed. This is also not a
  hosted UI measurement.

The pending matrix work must capture each playable variant at every listed width, preserve the
base/head pair for report-only cases, and attach the resulting artifact or capture ID here. Until
then, the settle budgets above are declared responsiveness thresholds, not observed latency
measurements.
