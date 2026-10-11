# UI parity receipts

Receipts tie an interaction change to its source commit, repeatable scenario, and the evidence that
actually covers it. A missing visual or latency measurement is recorded as untested rather than
implied by a passing unit test.

## Agent CLI health notice gallery

- **Source:** cmux `fix/cmux-next-harness-health-gallery` at `b40b176a95dc`; PR #19464.
- **Scenario:** render the real `HarnessHealthNotice` for a signed-out CLI, an outdated CLI, a
  dismissed notice, and an update that requires elevation. The scripted plays invoke Log In,
  Update, and Not Now through the shipped buttons and verify the terminal command handoff or
  dismissal state.
- **Environment:** component gallery at 360 / 560 / 760 px pane widths, with the normal gallery
  theme matrix still to run on hosted Chromium and WebKit.
- **Evidence:** `webviews/test/gallery-coverage.test.ts` (6 passing checks),
  `webviews/src/agent-session/acpmux/HarnessHealthNotice.test.tsx` (4 passing tests, 16
  expectations), `bun run typecheck`, changed-file lint, and `bun run gallery:build` pass locally.
- **Latency:** the entry declares a 250 ms settle budget for local action feedback; no hosted
  action-to-settle measurement is available yet.
- **Untested:** the hosted matrix, real terminal-tab launch, and native Settings handoff for
  elevated updates remain pending.

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
