# cmux-next UI parity reference inventory

This is the map for parity work. It separates the code that defines behavior from the references that
show what the behavior should feel like, so a screenshot or a copied mock cannot become a second
implementation by accident.

## Authorities

| Question | Source of truth | Evidence and use |
| --- | --- | --- |
| What ships in the web UI? | `webviews/src/` on `feat-cmux-next` | Real React components, page bridges, shared tokens, and their tests. |
| What does a gallery entry mean? | `webviews/src/gallery/format.ts`, `registry.ts`, and `ENTRIES.md` | One typed fixture format, real component/page hosts, named variants, scripted plays, and experiments. |
| What does the native cmux-next surface mean? | `Packages/macOS/CmuxNext/**` and the matching native gallery registrations | Native behavior and the shared fixture identity. The web gallery must not invent a parallel native model. |
| How do we compare arms and measure interaction feel? | `webviews/src/gallery/shell/CompareView.tsx`, `compare.ts`, `play.ts`, and `scripts/gallery-matrix/` | Lock-step replay, screenshot strips, layout-shift/long-frame signals, and action-to-settle measurements. |
| Which implementation is ready to inspect? | `cmux-gallery` previews and matrix runs | A built branch preview or a published matrix run is the reviewable artifact, not a local screenshot with unknown code. |

## Reference repositories

### `manaflow-ai/cmux-app-screenshots`

Local checkout: `/Users/leoli/Projects/cmux-app-screenshots`.

This is the visual archive. Its `gallery/media/` captures and `references/` folders contain historical
cmux, Codex, Claude, ChatGPT, T3, and Zeron references. Use them to name a concrete mismatch and to
build a before/after capture. They do not define current behavior, spacing tokens, or accessibility.
The repository's current `main` tip is `939ab21` (the checkout may contain local archival changes;
inspect its worktree before using a file as evidence).

### `manaflow-ai/cmux-gallery`

Local checkout: `/Users/leoli/Projects/cmux-gallery`.

This is the hosting and measurement surface for the real gallery in cmux. It owns preview routing,
build retention, matrix indexes, screenshot comparison, and latency-result joins. The
`measure/matrix-before-after` branch currently carries the repeatable matrix comparison tooling.
The gallery source itself remains in the cmux repository, so UI changes belong in cmux and are served
through a branch preview or matrix run here.

Side-by-side parity images belong in the gallery when they represent an experiment or an implementation
comparison: use a typed `experiment` with named arms and lock-step replay. Keep one-off historical
reference images in `cmux-app-screenshots` and link them from the entry or its review note.

### `manaflow-ai/messageslab`

Remote source: <https://github.com/manaflow-ai/messageslab> (current remote tip observed as
`3a84159`). There is no local checkout under `/Users/leoli/Projects` at this time.

Treat this as a message/transcript interaction reference and API/design source. Copy no markup or
state model into cmux without mapping it to the cmux pane bridge and gallery fixture contract first.

### `teamleaderleo/idlesse`

Local checkout: `/Users/leoli/Projects/idlesse`.

This is a reference for a media-library contact sheet: dense visual scanning, static/image-sequence
previews, variant selection, and deliberate before/after evidence. Relevant notes live under
`docs/library-visual-review.md`, `docs/library.md`, `docs/scene-preview.md`, and
`docs/performance-2026-09-08.md`. Its Swift/media implementation is not a cmux dependency.

## Current parity lanes

1. **Overlays and focus**: shared Base UI menus, portal stacking, keyboard navigation, focus restoration,
   and async clipboard behavior. Evidence: focused interaction tests plus a gallery keyboard play.
2. **Composer and transcript**: picker hierarchy, drag/select behavior, tool-run density, changed-file
   cards, and reduced-motion behavior. Evidence: real pane fixtures, gallery variants, and matrix
   action-settle rows.
3. **Gallery scanning**: Browse is a contact sheet over real stages. It must support title/surface
   filtering, static versus motion filtering, and controlled variant cycling without changing the
   URL identity of the opened entry. Evidence: `gallery-browse.test.ts` and the narrow-shell layout
   lane.
4. **Reference-grade comparison**: when a mismatch is visual or temporal, add a typed experiment arm
   or a named fixture variant, then publish a matrix before/after run. Do not make a screenshot-only
   claim about latency.

## Evidence rule

A parity claim is complete only when the implementation path, a reproducible gallery entry or play,
and a measured or visual artifact all point at the same variant and commit. Historical screenshots are
inputs to a decision; the branch preview and matrix receipt are the verification.
