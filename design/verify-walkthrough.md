# Verify walkthrough

The proof under an agent's answer that the UI it built works: the browser REPL's `verifyFlow`
clicks through the flow (open, click, type, expect) in a background tab, takes one screenshot per
step and prints a `cmux.walkthrough` line. The chat reads that line from the turn's last such call
and draws it under the answer, before any next-step card.

References: `claude/web/merge-status` (cmux-design-references): a list of checks, each with a
green check, a red cross or a dash for skipped, and a count.

## Anatomy

- **Head**, one 28px line, a button that folds the strip: a green check and "Checked in the
  browser · 4/4 passed", or a red mark and "Failed at step 3 · 2/4 passed", or "No dev server
  answered"; then the page's address, muted (`localhost:5173/settings`); then the fold chevron.
- **Strip**, open by default: one 128 x 80 shot per step in a row that scrolls sideways, each
  over its mark (check, cross, or a dash when skipped) and its line, at most two lines. A failed
  step's shot has a red ring and its reason under its line; skipped steps are dimmed and have no
  shot. A click on a shot opens the image viewer.
- **No dev server**: the reason sits over the strip in red ("Start it (bg_start) and run
  verifyFlow again."), and the open step has no shot.

## Rules

- Every shot holds its 128 x 80 box before and after its image loads: no layout jump.
- The fold opens and closes like every transcript fold (`useAnchoredCollapse`), and snaps with
  Reduce Motion.
- Cost: the turn reads its rows once when it ends; a call is looked at only when its output holds
  `cmux.walkthrough`. A 12-step limit keeps the strip's height fixed.
- The strip claims only what ran: `passed` draws green only when every step shown passed.

## Gallery

`agent-pane.verify-walkthrough`: `passed`, `failed-expectation`, `no-dev-server`, `long-flow`,
narrow and normal widths.
