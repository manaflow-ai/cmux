# UI parity receipts

This ledger records the source heads and review surfaces for the current gallery parity batch. The
source heads below are the exact remote PR heads observed on 2026-10-10. A local test or gallery
build proves the fixture and source checks ran; it is not a hosted visual capture. Known public
GitHub artifact bundles are linked below where available. An artifact proves that a hosted job
uploaded files, not that every play passed; stale-head captures and reported play failures are
called out explicitly. Missing or stale current-head captures remain pending.

| PR | Source head | Gallery entry and variants | Viewport widths (narrow / normal / wide) | Hosted matrix |
| --- | --- | --- | --- | --- |
| [#19740](https://github.com/manaflow-ai/cmux/pull/19740) | `4e26a723b9fbda7f99ad930f337af7bc4de9ca66` | `agent-pane.new-tab`: `split-open-tabs`, `split-open-tabs-context-menu`, `recently-closed`, `tool-menu-keyboard`, `typed-tab-match`, `typed-address` | Entry defaults; gallery PR matrix at 420 px plus the workflow width set | [Gallery diff](https://github.com/manaflow-ai/cmux/actions/runs/38212760334#artifacts); 25 changed and 8 new states. Aggregate play summary reports 2 failures; WebKit reopen/context-menu steps measured 251-400 ms against a 250 ms budget. This is visual and timing evidence with known WebKit failures, not a clean pass |
| [#19742](https://github.com/manaflow-ai/cmux/pull/19742) | `7951d5d01a6c1e7c6310d8ef56e2c35fd628800b` | `agent-pane.composer-pickers`: `model-menu`, `model-focus`, `model-press-drag-release`, `effort-menu`, `effort-focus`, `effort-press-drag-release`, `permission-menu`, `permission-focus`, `context-details`, `context-focus`, `plan` | 400 / 640 / 860 px | [Gallery diff](https://cmux-lawrences-mac-mini.tail137216.ts.net:18443/feed/?pr=19742&view=all) and [artifact](https://github.com/manaflow-ai/cmux/actions/runs/38213117431#artifacts); 9 changed, 67 new, 24 removed states. Eight aggregate play failures include WebKit context-details settle at 1033-1174 ms versus 250 ms and Chromium effort drag layout shift at 0.0001-0.0010. The exact head is visually captured, but the interaction receipt is not clean |
| [#19745](https://github.com/manaflow-ai/cmux/pull/19745) | `05fc8b525b729adedcc5bce926ac257db24507c3` | `agent-pane.transcript`: `selection`, `keyboard-selection`, `keyboard-copy` | Entry defaults; workflow matrix includes 420 / 480 / 1000 px states | [Gallery diff](https://github.com/manaflow-ai/cmux/actions/runs/38213453826#artifacts); 151 changed, 1 new, 39 broken states and 77 aggregate play failures. The selection states were captured at the exact head, but the broad run has unrelated broken/play states, so it does not establish a clean transcript-selection latency receipt |
| [#19764](https://github.com/manaflow-ai/cmux/pull/19764) | `149638aedcee6b7b2264bbe971bb4501b41f2de5` | `pages.history`: `permission-error` | 560 / 1000 / 1400 px | [Gallery artifact](https://github.com/manaflow-ai/cmux/actions/runs/38218313661#artifacts); 28 changed, 1 new, 15 broken and 7 nondeterministic states. Chromium permission-error plays settled in 27.0-31.5 ms. WebKit had three passes at 32-40 ms and one failure at 328 ms with a 308 ms long frame against the 250 ms budget. Layout shift was zero. PR merged at this exact docs head; the artifact is evidence with one WebKit timing failure |
| [#19778](https://github.com/manaflow-ai/cmux/pull/19778) | `9b9ff6d4d063a5555f6903b06b79b67c5511cd68` | Keyboard Shortcuts search: ArrowUp/Down traversal, Enter recording, Escape reset | No gallery entry yet | [Gallery diff](https://github.com/manaflow-ai/cmux/actions/runs/38220561630#artifacts); no visual state changed and one nondeterministic state was excluded. Focused jsdom/provider coverage and scoped checks passed, but hosted interaction timing is unmeasured until a dedicated gallery entry is added |
| [#19001](https://github.com/manaflow-ai/cmux/pull/19001) | `cb177e1649d6a5db0219c8fc03eefcff1f5c4472` | `agent-pane.file-search`: `idle`, `matches`, `pick`, `no-results`, `truncated`, `outside-repository`, `escape` | 360 / 520 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064049394#artifacts); current head |
| [#19007](https://github.com/manaflow-ai/cmux/pull/19007) | `2598c7615c4ddb9b4f1312020b7b9b6ffa433d66` | `agent-pane.question-card`: `pending-single`, `multi-preview`, `submit`, `four-tabs`, `other-typing`, `answered-remote`, `cancelled`, `escape`, `skip` | 360 / 540 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064057465#artifacts); current head |
| [#19011](https://github.com/manaflow-ai/cmux/pull/19011) | `6e2ce01dca54c23efc7a951b2ad32f831ed39df7` | `agent-pane.permission-panel`: `pending`, `expanded`, `allow-once`, `collecting`, `receipt`, `allowance`, `error`, `uncertain` | 360 / 540 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38063939758#artifacts); current head; 1 play failure reported |
| [#19021](https://github.com/manaflow-ai/cmux/pull/19021) | `cfb567dffb26a77ff15f08a61cca75e50b36b699` | `agent-pane.diff-panel`: `last-turn`, `toolbar`, `tree-selection`, `open-file-error`, `escape`, `loading`, `error`, `empty`, `loaded-scope` | 520 / 860 / 1180 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38063526286#artifacts); current head; 6 play failures reported |
| [#19034](https://github.com/manaflow-ai/cmux/pull/19034) | `46283bd7fd044bebff58d00b6821d2b6321db681` | `agent-pane.home-lists`: `baseline`, `empty`, `cap-filter`, `click`, `keyboard` | 360 / 560 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38055198502#artifacts); current head |
| [#19047](https://github.com/manaflow-ai/cmux/pull/19047) | `4056beac0da858f1d40a3d57b3c44c5fcec14ed5` | `agent-pane.quick-surface`: `empty`, `transcript`, `waiting`, `long` | 360 / 520 / 720 px | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38071057271#artifacts); no state changes or play failures; current head |
| [#19048](https://github.com/manaflow-ai/cmux/pull/19048) | `de454fbf7836e4815be50cd3087a1788dc944544` | Gallery report code; no component entry | N/A; report-only fixture | Prior-head [artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38054995451#artifacts) at `59ca884c4b09caf8d19ea4fa170c554a244d71ad`; current head pending |
| [#19052](https://github.com/manaflow-ai/cmux/pull/19052) | `3edb5f8ee4ff9bab3f30c5c7ab7ff7d1075b54f1` | `agent-pane.checkpoint-review`: `create-selection`, `keyboard-selection`, `partial-receipt`, `copy-replacement`, `retained` | 360 / 520 / 720 px | Prior-head [artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38055851655#artifacts) at `f9dbff74c2c5a41a1d01a61f348a6f5bfa555ad5`; current head pending |
| [#19053](https://github.com/manaflow-ai/cmux/pull/19053) | `098e2b022775c8ba190b9afe8c8b3b01fc305dad` | `agent-pane.handoff-review-message`: `draft`, `edit`, `checkpoint-gating`, `memory-disclosure`, `validation-error`, `error`, `starting`, `started` | 440 / 680 / 820 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064076695#artifacts); current head |
| [#19055](https://github.com/manaflow-ai/cmux/pull/19055) | `b3a1695660341c932bc49d40d627b22f707ad908` | `agent-pane.shell-rows`: `running`, `stop-receipt`, `collapsed`, `expanded`, `expand-output`, `succeeded`, `failed`, `stopped`, `keyboard-open`, `moved` | 390 / 640 / 860 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38064083786#artifacts); current head |
| [#19058](https://github.com/manaflow-ai/cmux/pull/19058) | `9d208eaa7ca8eba7c4fcd08819bfb2e1c6e5e336` | `agent-pane.folder-choice`: `offered`, `keyboard`, `error` | 360 / 560 / 760 px | [Artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38058201464#artifacts); current head |
| [#19061](https://github.com/manaflow-ai/cmux/pull/19061) | `ef891faf92b5c644d2acd4238581495f95742359` | Gallery report code stacked on #19048; no component entry | N/A; report-only fixture | Pending; no current-head artifact recorded |
| [#19072](https://github.com/manaflow-ai/cmux/pull/19072) | `b1cac282d993e445176d5ba4ba52ce5b0dc5c37f` | Gallery browse shell stale-variant recovery (`BrowseView` / `browseModel`); no component entry | N/A; shell-browse behavior | Pending; no hosted capture ID recorded |
| [#19118](https://github.com/manaflow-ai/cmux/pull/19118) | `ae7b12731c9b0f323bf5e0defce629c2322b2348` | Gallery browse shell matched-variant selection (`BrowseView` / `browseModel`); no component entry | N/A; shell-browse behavior | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38092482182#artifacts); all base/head/repeat shards passed; no isolated browse failure reported |
| [#19078](https://github.com/manaflow-ai/cmux/pull/19078) | `37e5c15b021ab1edd15aa58793e774e0ac18db23` | `agent-pane.context-ring`: `unknown-usage`, `known-usage` | 360 / 520 / 720 px | [Published gallery artifact](https://github.com/manaflow-ai/cmux/actions/runs/38072393427#artifacts); ContextRing plays pass, WebKit reports warnings only; broader composer matrix reports 10 pre-existing play failures |
| [#19081](https://github.com/manaflow-ai/cmux/pull/19081) | `6e4b19688934b6b385b43cbc22f4e04a27b0486d` | `agent-pane.thread-minimap`: `long-chat` | 880 / 1040 / 1240 px | [Published gallery artifact](https://github.com/manaflow-ai/cmux/actions/runs/38075570285#artifacts); current head has no play failures; removed base widths intentionally hide the minimap below its gutter threshold |
| [#19089](https://github.com/manaflow-ai/cmux/pull/19089) | `8f2522e28bceacf8f7d1b533a963a017005e0001` | `agent-pane.composer`: `pdf-attached`; shared modal and full-pane overlay layering | 400 / 760 / 760 px | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38084186992#artifacts); 79/79 checks passed across base, head, and repeat renders; current head |
| [#19092](https://github.com/manaflow-ai/cmux/pull/19092) | `5905d7e06ca579db2e24e8f8f43c48b52209be1c` | `agent-pane.composer`: `model-menu-keyboard`, `model-menu-starred` | 400 / 760 / 760 px | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38082005815#artifacts); 79/79 checks passed across base, head, and repeat renders |
| local composer-picker lane | `7c97ccedcc15` | `agent-pane.composer-pickers`: `closed`, `model-menu`, `effort-menu`, `permission-menu`, `context-details`, `plan` | 420 / 640 / 860 px | Local gallery coverage: 70 entries / 624 variants; layers, typecheck, lint, and gallery build pass; six-case manifest generated; hosted capture pending |
| [#18965](https://github.com/manaflow-ai/cmux/pull/18965) | `ebf7625ab2109c10d6512543086d3b65f64f643f` | `gallery.visual-media-board`: `all-previews` | 420 / 760 / 1080 px | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38087624403#artifacts); bundle present and inspectable; no isolated scripted play; aggregate artifact reports 4,613 removed states, 39 broken states, and 31 play failures |
| [#19119](https://github.com/manaflow-ai/cmux/pull/19119) | `9614aaadff6f0e4e55dc35287976b67252aa8096` | `gallery.visual-media-board`: `all-previews` playback | 420 / 760 / 1080 px | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38092149972#artifacts); exact head merged as `b7dde99fca40`; aggregate receipt says no state changes and 33 play checks failed, with no isolated media-entry failure identified |
| [#19037](https://github.com/manaflow-ai/cmux/pull/19037) | `a39e0df83126359bed2961cfb92cb8f4336b2d25` | `agent-pane.chat-find-bar`: `empty`, `matches`, `next-match`, `no-results` | 360 / 640 px | [Gallery diff artifacts](https://github.com/manaflow-ai/cmux/actions/runs/38091931574#artifacts); exact head merged as `645af3db5fa7`; aggregate receipt reports 38 changed states, 39 broken states, and 29 play checks failed; no isolated Find in Chat failure identified |
| local overlay-focus lane | `b8ceef82b511` | `ui.context-menu`: `keyboard`, `pointer-focus`, `escape-focus`, `selection-menu`, `selection-native` | 360 / 560 / 820 px | Local focused test: 14 passed, 31 assertions; gallery coverage 80 entries / 692 variants; gallery build passes; hosted capture pending |

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
- **#19081, Thread minimap:** the long-chat play hovers tick 4 and waits for its delayed preview. Current head widths are 880 / 1040 / 1240 px so the 28 px gutter remains available with a scrollbar; the gallery play passes in Chromium and WebKit (WebKit frame warnings only). The diff runner also replays removed 420 / 760 px base states, where the product intentionally renders no minimap; the play records that hidden state without treating it as a failure.
- **#19089, PDF and pane overlays:** the `pdf-attached` play pastes a two-page PDF, opens the attachment preview, and asserts that the dialog remains `position: fixed` with a portaled backdrop so the composer and transcript do not reflow. The shared modal and backdrop use the layer tokens, while the full-pane image and chat galleries opt out of the generic card width. The hosted matrix covered 400 / 760 / 760 px Chromium and WebKit states plus repeat renders; all 79 checks passed at `8f2522e28bce`. This is a visual and overlay-layout receipt, not an input-latency measurement.

- **#19092, Model picker:** the keyboard play opens the Older models fold after ArrowDown reaches the visible tail; the starred play filters for Sonnet 5.5, preserves the star, and opens the cross-harness Starred rail. The fixed popup keeps the transcript and composer anchors stable while its internal rows reflow, so the two variants declare narrow CLS budgets of 0.03 and 0.055 based on the hosted matrix maxima (0.028 and 0.050842). The matrix covered 400 / 760 px Chromium and WebKit states plus repeat renders; all 79 checks passed. This is a visual and layout-shift receipt, not an input-latency measurement.
- **Local composer-picker lane (`7c97ccedcc15`):** the picker rail covers closed, model, effort, permission, context-usage, and Plan states at 420 / 640 / 860 px. Each interactive variant declares zero anchor movement and zero layout shift, plus 33 ms long-frame and 250 ms settle budgets; the six-case manifest confirms the named states. Local coverage, typecheck, lint, layers, and gallery build pass. The local checks do not execute the scripted plays in a browser, so hosted Chromium/WebKit capture and measured action timing remain pending.

- **#18965, Visual media board:** the hosted bundle contains the `gallery.visual-media-board` `all-previews` entry at 420 / 760 / 1080 px. Its compiled card controls expose the effective paused state through `aria-pressed`, including the global pause state, and the artifact confirms the static fixture renders. The entry has no scripted play, so the artifact does not prove a click transition or isolated play result. The aggregate gallery artifact reports 4,613 removed states, 39 broken states, and 31 play failures; those failures remain attached to the aggregate run rather than being attributed to this entry. This is a static accessibility and layout receipt, not an input-latency measurement.

- **#19119, Visual media playback:** the exact head adds a scripted `all-previews` play that pauses globally, resumes globally, and pauses/resumes the Pulse card, with zero layout-shift, a 33 ms long-frame threshold, and a 300 ms settle budget. The hosted PR checks completed successfully (80 passed, 0 failed, 0 pending), and the gallery artifact is available at the link above. The gallery bot's aggregate comment reports no state changes and 33 play checks failed; it names a Changes scope-menu failure and links the remaining failures on the diff page, but does not identify an isolated media-entry failure. Treat the artifact as evidence that the playback fixture and checks ran, not as a clean visual-diff or measured-latency receipt. No hosted latency sample is attributable to this entry yet.

- **#19037, Find in Chat bar:** the exact head covers empty, matching, next-match, and no-results states at 360 / 640 px; the focused local checks and gallery build passed, but the entry has no `settleMaxMs` budget, so hosted interaction latency is not measured. The hosted artifact reports 38 changed states, 39 broken states, and 29 aggregate play failures, including Changes scope-menu and unrelated chat-gallery failures; it does not identify an isolated Find in Chat failure. Treat this as visual evidence with an explicit aggregate-noise limitation, not a clean interaction receipt.

- **#19118, Gallery browse matched variant:** the exact head makes a filtered contact-sheet card open the variant named by the query instead of retaining the entry's recommended starting variant. The hosted gallery diff ran all base, head, and repeat shards successfully at the exact head; this is shell-browse evidence with no component entry or isolated interaction-latency sample.

- **#19047, Quick Surface:** the four variants cover the empty composer, a short transcript, a waiting trust ask, and a longer transcript. The fixture keeps the quick host anchor and composer footer stable while content changes, and declares zero anchor movement, zero layout shift, and a 33 ms long-frame limit. The hosted gallery diff reported no state changes or play failures at `4056beac0da`; its 360 / 520 / 720 px matrix is visual and layout evidence, not an input-latency measurement.

- **Local overlay-focus lane (`b8ceef82b511`), Context menu:** keyboard and pointer actions, plus outside dismissal, return focus to the invoking control when it remains connected, including a rich `contenteditable` composer target; a synchronously removed opener is left untouched; actions that deliberately move focus keep that destination. The change has no geometry or visual-surface change, so deterministic active-element assertions are the receipt rather than before/after stills. The local context-menu test passes 14/14 with 31 assertions and the gallery adds the `pointer-focus` play; hosted capture, WebKit gallery play, and removals that happen asynchronously after the action remain untested.

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

## Workspace-switch journey evidence packet (2026-10-17)

- **Canonical entry:** `agent-pane.new-tab#workspace-switch`.
- **Fixture/play contract:** seed a `Release` workspace suggestion (`workspace-release`,
  `~/src/release`), type `Release` into `.nt-field`, choose the matching `[role="option"]`, and
  hand off `tab.jump(target="workspace", id="workspace-release")` to the native host. The fixture
  renders three sessions and one `Release notes` tab so the browse and review surfaces have stable
  context.
- **Source:** gallery journey commit `dd237189826f7fb33c27339fc4255fa94ddcb926`, integrated here
  as `ca963862daf9`; the visual capture below is from exact integrated head
  `af4b19dcce8ed9b48222250a13125ac6c76ba14f`.
- **Behavior verifier:** **PASS** — 12 portable/browser assertions pass; local gallery browse-layout
  Chromium/WebKit checks pass (2/2). The default browser lane skips outside CI/Freestyle by design.
- **Visual/feel verifier:** **PASS with warning** — fresh Vite gallery capture on Chromium 151.0.7922.34
  at `http://127.0.0.1:4241` produced four valid local receipts. Every capture has `galleryReady=1`,
  nonblank body content, zero console/page/request errors, and the expected
  `tab.jump(target="workspace", id="workspace-release")` log. Normal is 760x560; narrow is 420x560.
  Dark uses `Apple System Colors`; light uses `Apple System Colors Light`. The normal and narrow
  screenshots both show the prompt, workspace suggestion, tab result, and session list; narrow truncates
  long session labels cleanly without overflow.

  - [normal dark receipt](/Users/leoli/Projects/briefs/workspace-switch-journey-20261017/visual-normal-dark.json) —
    PNG SHA256 `e2b4f06d45c7c7a89c80f992b18eeac7b0ee3e3535f8f40273bb98008f910e49`
  - [normal light receipt](/Users/leoli/Projects/briefs/workspace-switch-journey-20261017/visual-normal-light.json) —
    PNG SHA256 `0b04f2ec8cdda21b310e515627f5de9b579a53416fcf5b54b8ecf8a6324eecb9`
  - [narrow dark receipt](/Users/leoli/Projects/briefs/workspace-switch-journey-20261017/visual-narrow-dark.json) —
    PNG SHA256 `e3678b846ddd1f5acf07ab0a60c6a632e3f45fb267026cfcd183754d82161aa8`
  - [narrow light receipt](/Users/leoli/Projects/briefs/workspace-switch-journey-20261017/visual-narrow-light.json) —
    PNG SHA256 `3465374f72b35c9d6a5f829443957db852e395824ff7e00b02f6b6577960fbdc9`

  The play report remains warning-only: the type step observed one test-time long frame over 33 ms
  (60.7 ms dark, 69.7 ms normal light, 64.6 ms narrow light; the other dark/narrow run was similar);
  the click step passed, with no layout-shift or popup problems. This does not invalidate the visual
  receipt and remains a candidate for the async perf workflow.
- **Follow-up head:** `7d3d5a07117e83349b2a9b83c8ec6a584d16920c` defers omnibar row derivation from the
  input lane and tightens the 420px container spacing. Focused field-editing tests pass (3/3).
- **Native boundary:** this packet verifies the gallery journey and browser feel. Native workspace
  switch timing remains warning-only and is tracked by the existing async receipt workflow.

- **Lazy-stage follow-up (`ad73781dff67`):** the stage loader now keeps the full browse registry cold
  and imports the canonical New Tab entry directly, so a frame does not settle every gallery module.
  Focused gallery-play checks pass. The local Vite smoke remains slow during dependency optimization,
  so the authoritative rerun uses the managed hosted runner below.
- **Managed post-fix rerun:** **PASS** — GitHub Actions run
  [39086652622](https://github.com/manaflow-ai/cmux/actions/runs/39086652622), artifact
  [workspace-switch-f4eb922-final](https://github.com/manaflow-ai/cmux/actions/artifacts/12120697637),
  rendered the exact final head `f4eb922a2e6a7298e4d64fb1cf96e5071b55e632` on
  `github-actions/ubuntu-24.04` with Chromium. All four stages reported `ready=1`, the type and
  option-click plays passed with no long frames, and `tab.jump(target="workspace", id="workspace-release")`
  completed for every state. The downloaded evidence is in
  `/Users/leoli/Projects/briefs/workspace-switch-journey-20261017/managed-39086652622/managed-receipt.json`
  with JSON SHA256 `fa60582dcdec597278aaa2f097db446b2e24ecfd51f2438302ead3ccfa01ca93`.

  | state | viewport | theme | play | PNG SHA256 |
  | --- | ---: | --- | --- | --- |
  | normal-dark | 760x560 | Apple System Colors | `pass` | `f41fb13893790ab66ac8c00a92d06c4c7d53b6034bf83b9e431bd9659231bca6` |
  | normal-light | 760x560 | Apple System Colors Light | `pass` | `4c306ea8878efb09168fd1d3b25f32d7e8332a916cbd6af62363c3bf92020c4d` |
  | narrow-dark | 420x560 | Apple System Colors | `pass` | `d8e1b0f36bffa33faf28ae29cbae221fba734f01f5c51bf23012e9cd37be1613` |
  | narrow-light | 420x560 | Apple System Colors Light | `pass` | `df66e46490ad9347a2807e56c33840b91b2e1d180232043630d87e8ccdc7e31d` |
