# Neko: license evidence and art rounds

Leo asked for optional neko icons and clarified: “well i guess it's a future hill climbing thing...
but we just want the GOOD ones”. No candidate in this change is enabled as an app theme. The reserved
`neko` identifier and gallery are plumbing for the next round, not a claim that the theme is finished.

## Taste evidence

The earlier attempts were read from their actual repositories. These are observations from code and
history, **not quotations of Leo's earlier prompts**:

- Ourchival at `f37fc53c2f78`: `apps/web/app/CatIcon.tsx` describes “Small, decorative companions to
  text labels. No font or image requests.” Its 24-unit, 1.5-stroke drawings keep recognizable noun
  silhouettes and use small warm-colored ear/tail accents. `BrandMark.tsx` uses the complete cat
  mascot separately, at 56px.
- Idlesse at `4f8556cba5a1`: `Sources/Harness/HomeWindowController.swift` says “A dedicated small-size
  mark keeps the cat legible in the footer.” Its 17pt `cat.fill` sits in a dedicated brand control.
  Commit `879a6214a8100fb77777797bf983456081f0501d` reverts the richer app-icon redesigns (#169/#170).
  The reverted `scripts/generate-icon.swift` combined a wallpaper window, cat silhouette and glint.
- Inference: preserve action recognition and small-size clarity; use restrained, noun-specific cues.
  A good mascot does not automatically make a good copy/retry/speak glyph.

The private reference `chatgpt/live/transcript-worked-for-branch-menu` shows a restrained monochrome
action row with consistent visual weight. It was inspected privately; private captures are not copied
into this public repository.

## Round 1

Gallery: `agent-pane.neko-icon-family`, `{noto,fluent,lucide,authored}-{light,dark}`.
Capture harness: `scripts/gallery-matrix/neko.ts`, actual device scale factors 1 and 2, 16 CSS px action
samples. Every variant includes default shared tokens and the actual transcript components. The latter
are identified separately until the shared icon pass migrates them; this gallery does not claim to
have changed the real action row.

Coverage counts **neko-specific semantic drawings**, not ordinary default fallbacks. Required sample:
copy, retry, speak, bookmark, pin, more (6); working spinner (1); success/error (2).
Spinner/status counts identify shared fallbacks, not a requirement to decorate status or error marks.
The icon spec keeps those marks semantic. A working mark must remain a true spinner.

| Candidate | Actions | Spinner | Status | Visual fit | Action recognition | Release decision |
| --- | ---: | ---: | ---: | --- | --- | --- |
| Noto Emoji cat | 0/6 | 0/1 | 0/2 | 2/6 (0, 2, 0) | N/A | Gallery only |
| Fluent Emoji flat cat | 0/6 | 0/1 | 0/2 | 1/6 (0, 1, 0) | N/A | Gallery only |
| Lucide cat | 0/6 | 0/1 | 0/2 | 4/6 (1, 2, 1) | N/A | Gallery only |
| cmux Cat + copy/pin fill-ins | 2/6 | 0/1 | 0/2 | 3/6 (1, 2, 0) | 2/2 | Gallery only |

The previous draft's numeric taste ratings were not backed by reviewed 1x/2x captures and are withdrawn.
A visual round rates stroke/size consistency, light/dark contrast, and the restrained cat treatment
above (0–2 each, /6 total). Action recognition is separate (0–2), or N/A when no action artwork exists.
Coverage is also separate; a high visual score for a cat mascot cannot supply missing semantic actions.

All 16 captures from [run 41780806887](https://github.com/manaflow-ai/cmux/actions/runs/41780806887)
at `7f35260a7a7a7691090fa1e8bb74684ddecf1e76` were inspected at their native device scale.
The scores above are subjective comparison judgments, not measured usability results. Tuple order is
stroke/size consistency, contrast, restrained cat treatment. The authored score applies
only to its two changed action drawings, not the unchanged fallbacks.

- Noto reads clearly as a cat in both themes, but its filled colored face is much heavier than the
  adjacent utility glyphs. It communicates none of the required actions.
- Fluent's full-body cat has tiny legs and pale details at 16px, particularly on light backgrounds.
  The silhouette is a mascot, not an action. Increasing device scale does not fix the mismatch.
- Lucide is the closest licensed starting point: clean monochrome geometry in both themes. Its
  face still has more visual mass than the default row and cannot substitute for semantic actions.
- The authored copy/pin retain recognizable action shapes, but the purple ear strokes look like
  small ticks at 1x and added noise at 2x. Repeating ears is weaker than Ourchival's noun-specific
  treatment. They fail the small-size clarity inferred from Idlesse.

**Round decision:** release none. Preserve the default icons and hide the reserved setting. Next art
round should explore monochrome, noun-specific cues integrated into the existing copy/retry/speak
silhouettes at 16px, using Lucide as a restraint reference rather than transplanting its cat head.
Keep More and status marks shared. The working mark remains a true spinner throughout. A second
independent visual reader inspected all 16 captures and agreed that no candidate improves on the
default row; its critique prompted the separate action-recognition and visual-fit scores above.

## License survey

`neko-candidates/manifest.json` pins upstream commits, exact source paths, byte counts and SHA-256
hashes. The actual upstream license files accompany the three representative gallery assets. The
full relevant license texts are also in the generated third-party notices.

| Set | License scope verified | Coverage and suitability |
| --- | --- | --- |
| Noto Emoji | `2D/svg/LICENSE`: Apache-2.0, Google copyright. The repository's font OFL is not the SVG license. | Cat expressions/silhouettes; no copy/retry/speak/bookmark/more or working spinner family. |
| Fluent Emoji | Root `LICENSE`: MIT, Microsoft copyright. | Cat expressions and full-color artwork; no coherent semantic action set. |
| Lucide | Root `LICENSE`: ISC; listed Feather-derived icons additionally carry MIT. `cat` is ISC. | Broad ordinary action, status and loader coverage; only a generic cat glyph, no neko action variants. |
| Existing cmux Cat | First-party authored SVGs in `design/icons/source/`. | 36 eligible noun accents plus two experimental action fill-ins. Status/privacy variants excluded. |
| oneko.js / sprite lineage | `adryd325/oneko.js` at `5281d057c4ea9bd4f6f997ee96ba30491aed16c0`, root `LICENSE`: MIT-style, Copyright 2022 adryd. | Ships `oneko.gif` and JS, no vector action set. The repository does not establish the inherited sprite lineage; not vendored. |
| Fluent System Icons | `microsoft/fluentui-system-icons` at `9bfae3d782fda4c8764f2128cec4d0dda160b283`, root `LICENSE`: MIT, Copyright 2020 Microsoft. | Broad standard action/status family; no coherent neko semantic-action family. Not vendored. |
| Tabler Icons | `tabler/tabler-icons` at `ed177a085b652fe04ec4f37ced867c94621e7840`, root `LICENSE`: MIT, Copyright 2020–2026 Paweł Kuna. | `icons/outline/cat.svg` plus broad standard action/status glyphs; no neko action variants. Not vendored. |

The first-party fill-ins are recorded in `scripts/icons/build_pack.py` and generated into
`nekoCandidate.json`, imported only by the gallery. They are not derived from the surveyed third-party
sets. `neko-candidates/NOTICE.md` records the representative artwork and modifications.
