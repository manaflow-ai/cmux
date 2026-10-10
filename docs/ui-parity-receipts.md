# UI parity receipts

This ledger records the source heads and review surfaces for the current gallery parity batch. The
source heads below are the exact remote PR heads observed on 2026-10-10. A local test or gallery
build proves the fixture and source checks ran; it is not a hosted visual capture. No Freestyle or
hosted gallery matrix artifact was available for these PRs when this ledger was written, so every
matrix row is explicitly marked pending.

| PR | Source head | Gallery entry and variants | Viewport widths (narrow / normal / wide) | Hosted matrix |
| --- | --- | --- | --- | --- |
| [#19034](https://github.com/manaflow-ai/cmux/pull/19034) | `46283bd7fd044bebff58d00b6821d2b6321db681` | `agent-pane.home-lists`: `baseline`, `empty`, `cap-filter`, `click`, `keyboard` | 360 / 560 / 760 px | Pending; no capture ID recorded |
| [#19048](https://github.com/manaflow-ai/cmux/pull/19048) | `59ca884c4b09caf8d19ea4fa170c554a244d71ad` | Gallery report code; no component entry | N/A; report-only fixture | Pending; no capture ID recorded |
| [#19052](https://github.com/manaflow-ai/cmux/pull/19052) | `f9dbff74c2c5a41a1d01a61f348a6f5bfa555ad5` | `agent-pane.checkpoint-review`: `create-selection`, `keyboard-selection`, `partial-receipt`, `copy-replacement`, `retained` | 360 / 520 / 720 px | Pending; no capture ID recorded |
| [#19053](https://github.com/manaflow-ai/cmux/pull/19053) | `58c83b3ae2a5d8ffc2dcfe45a887964b23a471db` | `agent-pane.handoff-review-message`: `draft`, `edit`, `checkpoint-gating`, `memory-disclosure`, `validation-error`, `error`, `starting`, `started` | 440 / 680 / 820 px | Pending; no capture ID recorded |
| [#19055](https://github.com/manaflow-ai/cmux/pull/19055) | `e2a49a45820336132e3053f20a92cc6f1275e1cf` | `agent-pane.shell-rows`: `running`, `stop-receipt`, `collapsed`, `expanded`, `expand-output`, `succeeded`, `failed`, `stopped`, `keyboard-open`, `moved` | 390 / 640 / 860 px | Pending; no capture ID recorded |
| [#19058](https://github.com/manaflow-ai/cmux/pull/19058) | `9d208eaa7ca8eba7c4fcd08819bfb2e1c6e5e336` | `agent-pane.folder-choice`: `offered`, `keyboard`, `error` | 360 / 560 / 760 px | Pending; no capture ID recorded |
| [#19061](https://github.com/manaflow-ai/cmux/pull/19061) | `ef891faf92b5c644d2acd4238581495f95742359` | Gallery report code stacked on #19048; no component entry | N/A; report-only fixture | Pending; no capture ID recorded |

The component entries use the following interaction receipts and checks:

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
