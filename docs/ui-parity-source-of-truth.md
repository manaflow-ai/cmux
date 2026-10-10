# Web UI parity source of truth

This inventory separates normative behavior from visual evidence. A screenshot or gallery tile is evidence of a state; it does not by itself define the component contract.

## Authority map

| Surface | Normative source | Evidence source | Use | Known gap |
| --- | --- | --- | --- | --- |
| cmux-next web components | [`webviews/src/gallery`](../webviews/src/gallery) including [`ENTRIES.md`](../webviews/src/gallery/ENTRIES.md) | [`cmux-app-screenshots/captures/manifest.json`](https://github.com/manaflow-ai/cmux-app-screenshots/blob/main/captures/manifest.json) and the cmux gallery | Implementation, accessibility, and interaction contracts live in cmux; captures prove what shipped | The gallery spans branches and dates, so every comparison must record the exact commit or artifact |
| Composer, pickers, overlays | the focused gallery fixtures | [`captures/scenes/2026-10-05/manifest.json`](https://github.com/manaflow-ai/cmux-app-screenshots/blob/main/captures/scenes/2026-10-05/manifest.json) composer tiles and cmux gallery renders | Use focused tests for keyboard/focus/state behavior, then use a capture for geometry and visual review | Existing captures do not cover every narrow-width or interrupted-overlay state |
| Transcript and tool rows | the gallery fixtures for message and tool rows | cmux-app-screenshots transcript scenes; gallery fixtures for message/tool states | Treat the gallery fixture as the contract; compare captures for density, disclosure, selection, and motion | Some interaction semantics are only represented by smoke tests, not frame-by-frame captures |
| Navigation, sidebar, tabs | the current sidebar/navigation sources | `cmux-app-screenshots` sidebar/showcase scenes | Use current product captures for geometry and focus order; preserve Chrome-like tab affordances | Showcase captures are snapshots, not a complete keyboard or resize matrix |
| Real Messages interaction semantics | `manaflow-ai/messageslab/catalyst/` and its shared `MODEL.md`, `THREADS.md`, `shared/conversation.json`, and `motion/springs.json` | `messageslab/references/real-messages/interactions/` timelines, stills, and AX/input scripts | Reference for chat/transcript motion, selection, long-press, context menu, swipe reply, thread blur, and tapback behavior | Private recordings and some full frame sets remain outside the repository; repository stills are partial |
| Visual capture and validation process | `docs/ghostty-web-parity.md` in cmux for T0/T1/T2 parity and deterministic capture/diff rules | `cmux-app-screenshots` manifests and scene receipts | Reuse the evidence model: exact source ref, viewport, capture method, frame timing, and before/after artifact | The in-repo methodology was written for terminal rendering and needs web interaction scenarios added |
| Gallery hosting and branch previews | cmux repo `webviews/src/gallery` | `manaflow-ai/cmux-gallery` (`/live`, `/wt`, `/dev`, `/latest`, `/matrix/<run>`) | Use cmux-gallery to serve and index renders; do not put component decisions there | Tailnet URLs and served builds are time-sensitive; record the source commit and build ID |
| Visual review workflow analogue | The cmux capture manifests and gallery receipts | `teamleaderleo/idlesse/docs/library-visual-review.md` | Reuse its discipline: normal and narrow widths, grid/list/sidebar/selection states, screenshot plus interaction smoke check, and explicit untested cases | Idlesse is an art library, not a cmux UI authority |

## Reference repositories

- [messageslab](https://github.com/manaflow-ai/messageslab), main observed at `88a68797cdd6997caaf0e23ceed76ac9e739b04f`. Its Catalyst implementation is the current Messages oracle; the real-Messages interaction set documents observed behavior and capture conditions.
- [cmux-app-screenshots](https://github.com/manaflow-ai/cmux-app-screenshots), main observed at `a5a418d7c0c2dd345b486315eb49a9c235f59ffc`. Its manifests identify capture method, viewport, frame timing, source, and validated stills. The `cmux-next-showcase` set is product evidence, not a component spec.
- [cmux-gallery](https://github.com/manaflow-ai/cmux-gallery), local checkout observed at `258a5df5931673d4f4a821bab258b02b3f9a8f73`. It hosts and indexes builds and matrix runs. The component source of truth remains the cmux repository.
- [idlesse](https://github.com/teamleaderleo/idlesse), local checkout observed at `609331d42abcea45ff4933d1ea99b5b66089ac9a`. Use only its visual-review evidence process; do not copy its product decisions into cmux.

## Required receipt for a parity change

Every parity lane should leave one durable receipt containing:

1. The source commit and reference artifact or capture IDs.
2. The scenario, viewport, theme, and input sequence.
3. Before and after stills or a deterministic diff, when geometry or appearance changes.
4. Focused interaction and accessibility checks for keyboard, pointer, and overlay dismissal.
5. Any latency or frame metric, labeled as measured and tied to the capture engine. Do not call a layout or long-frame metric input latency.
6. Explicit untested states, especially narrow widths, interrupted async work, and stale branch previews.

When sources disagree, preserve both receipts and resolve the disagreement in a gallery play check or design note. Do not silently promote a gallery snapshot to a normative rule.
