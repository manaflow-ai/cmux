# UI parity receipts

Receipts tie an interaction change to its source commit, repeatable scenario, and the evidence that
actually covers it. A missing visual or latency measurement is recorded as untested rather than
implied by a passing unit test.

## Model picker fixed height per opening

- **Source:** cmux `op-next-polish-sweep` at `9090e1915c62`; PR #19414.
- **Scenario:** open the model picker, filter the catalog or expand Older models, and reopen it
  after dismissal. The content-sized dialog measures once after becoming visible, keeps that height
  for the opening, and measures fresh on the next opening.
- **Before evidence:** the paired gallery artifact for the earlier head recorded branch-only
  layout shifts in `agent-pane.composer/model-menu-starred` at 400 px Chromium (CLS `.7948` and
  `.1930` across themes) and `model-menu-keyboard` at 760 px Chromium (CLS `.0403`); the base
  passed those cases. The shared 400 px ArrowDown case was already baseline-red (`.0411`) and
  worsened on the earlier head (`.2292`), so it remains a shared follow-up rather than a new-only
  failure.
- **After evidence:** `webviews/test/model-picker-height.test.tsx` is red at `f0cf89c57712`
  before the implementation, green at `cbe935e6ddb8`, and now covers both filtering stability and
  reset-on-reopen. `bun run typecheck`, changed-file lint, `bun run gallery:build`, and the gallery
  play harness tests pass locally.
- **Latency:** no input-latency claim; the gallery's layout-shift checks are geometry evidence.
- **Untested:** the hosted after-matrix still needs Chromium/WebKit screenshots and repeat renders
  at the affected widths before the visual regression can be called cleared.

## Composer file-drag lifecycle

- **Source:** cmux `fix/cmux-next-composer-drag-lifecycle` at `1bc2eb5a0460`; PR #19220.
- **Scenario:** dispatch nested file `dragenter`/`dragleave` events, then leave through a window
  blur or complete a file drop. The drop affordance stays active until the matching leave and
  resets on blur, `dragend`, or `drop`; a drop delivers the files once and prevents page navigation.
- **Environment:** deterministic jsdom document and window; no theme or viewport applies because
  this lane changes event lifecycle state rather than geometry.
- **Evidence:** `webviews/test/composer-attachments.test.ts` (2 passing lifecycle tests), plus
  `bun run typecheck` and `bun run lint` on the exact source.
- **Latency:** not measured. The change removes a stale-state path and does not claim input or
  render latency improvement.
- **Untested:** native Chromium/WebKit drag event ordering, real filesystem drops, and the visual
  narrow-width attachment treatment remain covered by hosted browser/gallery lanes.
