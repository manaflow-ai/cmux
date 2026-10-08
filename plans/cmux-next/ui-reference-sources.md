# cmux-next UI reference sources

This is the source map for parity work on the cmux-next web UI. Keep the implementation and its
evidence in the source that owns it; use the other repositories as references or delivery tooling.

## Source map

| Source | Canonical contents | Use it for | Do not use it for |
| --- | --- | --- | --- |
| [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux) | Production React components under `webviews/src`, gallery fixtures under `webviews/src/gallery`, gallery tests under `webviews/test`, and the matrix runner under `scripts/gallery-matrix` | UI behavior, accessibility, keyboard and pointer interaction, visual diffs, filmstrips, layout-shift and long-frame checks, settled-latency measurements | Treating a hosted screenshot as proof that a branch is currently deployed |
| [`manaflow-ai/messageslab`](https://github.com/manaflow-ai/messageslab) | Messages-style interaction prototypes, canonical conversation fixture, motion spring fits, and frame/benchmark tools | Conversation density, transcript hierarchy, selection and send motion, scroll and virtualization feel, reference interaction vocabulary | Copying a prototype implementation into cmux without checking the cmux state and host contracts |
| [`teamleaderleo/idlesse`](https://github.com/teamleaderleo/idlesse) | Native Library and Studio media browsing, still/video/scene preview, thumbnail and framing behavior, and media pipeline fixtures | Static-versus-motion preview treatment, gallery/contact-sheet affordances, media fit/fill choices, and long-lived preview feel | Treating a native media surface as a cmux webview implementation or as proof of cmux behavior |
| [`manaflow-ai/cmux-gallery`](https://github.com/manaflow-ai/cmux-gallery) | Preview router, branch build queue, static hosting, matrix index and deployment scripts | Serving a pushed branch, linking a repeatable preview, finding the build or matrix artifact for a commit | UI source: it explicitly consumes `webviews/src/gallery` from cmux |
| [`manaflow-ai/cmux-app-screenshots`](https://github.com/manaflow-ai/cmux-app-screenshots) | Native cmux captures, reference briefs and Computer Use evidence | Native app chrome, tab/sidebar spacing, titlebar and cross-surface visual references | Treating a native capture as a webview interaction test |

## Evidence order for a UI change

1. Start with the production component and its existing unit or interaction tests in `cmux`.
2. Add or update a gallery entry when the behavior is visual or gesture-driven. The fixture should
   use the real component and reducer, not a second mock implementation.
3. Run the gallery matrix at merge-base, head and a repeat head render. Use filmstrips for motion,
   and record settled latency for actions where responsiveness is part of the requirement.
4. Use `messageslab` to compare transcript and composer feel, and `cmux-app-screenshots` to compare
   native chrome. These are reference evidence, not substitutes for the cmux gallery result.
5. Publish a branch preview through `cmux-gallery` only after the branch is pushed. Record the exact
   commit and preview path with the review artifact.

## Current high-value parity surfaces

- Composer controls and model picker: production behavior in `webviews/src/agent-session/acpmux`;
  the keyboard specimen belongs in `composer.gallery.ts` and should cover focus, Escape, arrow
  navigation, selection and settled latency.
- Transcript and selection: compare `messageslab/shared` fixtures and motion notes against the
  real transcript entries, then prove selection, copy, hover and long-message behavior in gallery
  fixtures.
- Overlays and menus: use the shared Base UI primitives in `webviews/src/ui`, with gallery play
  steps for open, keyboard navigation, press-drag and Escape/focus return.
- Tabs and navigation: use native captures for spacing and close affordances, and cmux gallery
  entries for keyboard order, focus return and narrow-pane behavior.

## Review invariant

Every parity claim should name the implementation commit, the gallery entry or test that exercises
it, and the reference source used for the comparison. A hosted preview or a screenshot without an
exact commit is a pointer, not evidence.
