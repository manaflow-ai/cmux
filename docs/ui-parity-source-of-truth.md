# Web UI parity source of truth

This inventory separates normative behavior from visual evidence. A screenshot or gallery tile is evidence of a state; it does not by itself define the component contract.

## Authority map

| Surface | Normative source | Evidence source | Use | Known gap |
| --- | --- | --- | --- | --- |
| cmux-next web components | [`webviews/src/gallery`](../webviews/src/gallery) and the component tests beside each surface, including [`ENTRIES.md`](../webviews/src/gallery/ENTRIES.md) | [`cmux-app-screenshots/captures/manifest.json`](https://github.com/manaflow-ai/cmux-app-screenshots/blob/main/captures/manifest.json) and the cmux gallery | Implementation, accessibility, and interaction contracts live in cmux; captures prove what shipped | The gallery spans branches and dates, so every comparison must record the exact commit or artifact |
| Composer, pickers, overlays | [`composer.test.tsx`](../webviews/src/agent-session/acpmux/composer.test.tsx), [`composerPickers.test.tsx`](../webviews/src/agent-session/acpmux/composerPickers.test.tsx), and the focused gallery fixtures | [`captures/scenes/2026-10-05/manifest.json`](https://github.com/manaflow-ai/cmux-app-screenshots/blob/main/captures/scenes/2026-10-05/manifest.json) composer tiles and cmux gallery renders | Use focused tests for keyboard/focus/state behavior, then use a capture for geometry and visual review | Existing captures do not cover every narrow-width or interrupted-overlay state |
| Transcript and tool rows | [`transcript.test.tsx`](../webviews/src/agent-session/acpmux/transcript.test.tsx), [`conversation/motion.test.ts`](../webviews/src/agent-session/acpmux/conversation/motion.test.ts), and row tests | cmux-app-screenshots transcript scenes; gallery fixtures for message/tool states | Treat the component test and fixture as the contract; compare captures for density, disclosure, selection, and motion | Some interaction semantics are only represented by smoke tests, not frame-by-frame captures |
| Navigation, sidebar, tabs | [`SessionSidebar.test.tsx`](../webviews/src/agent-session/acpmux/SessionSidebar.test.tsx) and the current sidebar/navigation sources | `cmux-app-screenshots` sidebar/showcase scenes | Use current product captures for geometry and focus order; preserve Chrome-like tab affordances | Showcase captures are snapshots, not a complete keyboard or resize matrix |
| Real Messages interaction semantics | `manaflow-ai/messageslab/catalyst/` and its shared `MODEL.md`, `THREADS.md`, `shared/conversation.json`, and `motion/springs.json` | `messageslab/references/real-messages/interactions/` timelines, stills, and AX/input scripts | Reference for chat/transcript motion, selection, long-press, context menu, swipe reply, thread blur, and tapback behavior | Private recordings and some full frame sets remain outside the repository; repository stills are partial |
| Visual capture and validation process | `docs/ghostty-web-parity.md` in cmux for T0/T1/T2 parity and deterministic capture/diff rules | `cmux-app-screenshots` manifests and scene receipts | Reuse the evidence model: exact source ref, viewport, capture method, frame timing, and before/after artifact | The in-repo methodology was written for terminal rendering and needs web interaction scenarios added |
| Gallery hosting and branch previews | cmux repo `webviews/src/gallery` | `manaflow-ai/cmux-gallery` (`/live`, `/wt`, `/dev`, `/latest`, `/matrix/<run>`) | Use cmux-gallery to serve and index renders; do not put component decisions there | Tailnet URLs and served builds are time-sensitive; record the source commit and build ID |
| Visual review workflow analogue | The cmux capture manifests and gallery receipts | `teamleaderleo/idlesse/docs/library-visual-review.md` | Reuse its discipline: normal and narrow widths, grid/list/sidebar/selection states, screenshot plus interaction smoke check, and explicit untested cases | Idlesse is an art library, not a cmux UI authority |

## Reference repositories

- [messageslab](https://github.com/manaflow-ai/messageslab), main observed at `3a84159b4f33413741f3cc7170130820ae638bab`. Its Catalyst implementation is the current Messages oracle; the real-Messages interaction set documents observed behavior and capture conditions.
- [cmux-app-screenshots](https://github.com/manaflow-ai/cmux-app-screenshots), main observed at `939ab21acf35b53d4619bf289fd9456ad5eac858`. Its manifests identify capture method, viewport, frame timing, source, and validated stills. The `cmux-next-showcase` set is product evidence, not a component spec.
- [cmux-gallery](https://github.com/manaflow-ai/cmux-gallery), main observed at `fa445a60e9c478da51a82f1a375b83801c0c9dab`; the local matrix worktree is `measure/matrix-before-after` at `3fe4939257c0e530afc56543db9597417b7aee95`. It hosts and indexes builds and matrix runs. The component source of truth remains the cmux repository.
- [idlesse](https://github.com/teamleaderleo/idlesse), main observed at `c8d2b04d3852aad60ceaf8e1dbbfbdf0fbcb28b7`. Use only its visual-review evidence process; do not copy its product decisions into cmux.

## Required receipt for a parity change

Every parity lane should leave one durable receipt containing:

1. The source commit and reference artifact or capture IDs.
2. The scenario, viewport, theme, and input sequence.
3. Before and after stills or a deterministic diff, when geometry or appearance changes.
4. Focused interaction and accessibility checks for keyboard, pointer, and overlay dismissal.
5. Any latency or frame metric, labeled as measured and tied to the capture engine. Do not call a layout or long-frame metric input latency.
6. Explicit untested states, especially narrow widths, interrupted async work, and stale branch previews.

When sources disagree, preserve both receipts and resolve the disagreement in a component test or design note. Do not silently promote a gallery snapshot to a normative rule.
