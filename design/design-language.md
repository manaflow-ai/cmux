# cmux NEXT design language

Leo, 2026-11-22: "what's our design language?"

**In one line:** cmux NEXT is a native macOS 26 app. Native chrome is the system's glass. Web pages
draw plain translucency (a tint plus a blur) only on things that float. Everything sits on a 4 px
grid with five corner radii and two shadow levels, and every number lives in one file.

This page is the entry point. It decides nothing new: each rule below links the page that owns it.

## The rules, and where each one lives

| Rule | Owner |
|---|---|
| Which surfaces are native glass, host glass or page glass | [surface-materials.md](surface-materials.md), enforced by `scripts/cmux-next/check-surface-materials.py` |
| The five glass levels, one edge, the legibility floor, the perf budget | [glass-system.md](glass-system.md) |
| The shared native material for menus, toasts and popovers | [transient-material.md](transient-material.md), [transient-material-chat.md](transient-material-chat.md) |
| Every number: spacing, radii, control sizes, icons, glass, elevation, colors | `schemas/design-scale/design-scale.json`, written into `--ds-*` CSS by `webviews/scripts/pages/gen-design-scale.mjs` and read by the Swift materials |
| Icons | [icons/SPEC.md](icons/SPEC.md), one registry for native and web |
| Pressed and hover states | [pressed-state.md](pressed-state.md) |
| The room between a label and its chevron (menu triggers, picker chips, row folds) | [disclosure-chevron.md](disclosure-chevron.md), measured by `webviews/test/disclosure-chevron-gap.test.ts` |
| Chat rows, the composer, motion | [chat-row-anatomy.md](chat-row-anatomy.md), [chat-surfaces.md](chat-surfaces.md), [chat-fold-motion.md](chat-fold-motion.md) |

## The numbers that set the look (from `design-scale.json`)

- **Grid:** 4 px base, scaled by the interface scale.
- **Radii:**
  - sm 4 for row highlights;
  - md 6 for fields and chips;
  - lg 8 for popups and small cards;
  - xl 12 for cards and the composer;
  - 2xl 16 for code blocks.
  - Buttons take the tab's corner (`--cmux-button-radius`, 8).
  - Two named exceptions are still to move to 12 after a gallery comparison: the card at 14 and the composer at 18.
- **Elevation:**
  - level 1 (0 1px 2px) for rows and cards;
  - level 2 (0 2px 6px) for popovers, menus, the palette, the composer and sheets.
- **Glass:** five levels, one saturation (1.6), one hairline edge plus one lit top hairline. Primary text keeps 4.5:1 and secondary text 3:1 over pure black and pure white.

## Open questions

- **The toast's shape.** Leo, 2026-11-22: "the toast is this awkward pill glass. im not sure if it
  should be that rounded." A toast is a popup, so by the scale above it takes lg (8), not a
  full pill. The fix is another lane's; this page records the rule it should meet.
- **The surface checklist.** Not every surface has been graded against the system design rules yet.
  The checklist and its passes live in the team's design notes.
- **Themes.** A theme overrides these numbers and never changes them. Themes ship as recipes in
  `cmux-tui/crates/cmux-customize-recipes`. Broad redesign themes in other design languages are
  in progress, each with a gallery of the sidebar, composer, toast and splits.
