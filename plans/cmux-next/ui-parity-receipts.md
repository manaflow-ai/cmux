# UI parity receipts

Receipts tie an interaction change to its source commit, repeatable scenario, and the evidence that
actually covers it. A missing visual or latency measurement is recorded as untested rather than
implied by a passing unit test.

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
