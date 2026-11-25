# Gel: design notes

Gel is the soft, gooey look built on cmux's flush corner: tonal surfaces from one seed color, large
soft corners, filled containers instead of outlines, glass where a layer floats, and corners that meet
like two drops of water. This page records what it is built from, what each source gave it, and the
decisions, so a later change keeps it one system rather than a recolor.

## References

Each reference is described by what it is; the named list with links is kept with the team's
private design references.

| # | Reference | What Gel takes from it |
| --- | --- | --- |
| R1 | A tonal design system's color spec: color roles (surface, container, on-surface, primary) laid on tonal palettes in a perceptual hue-chroma-tone space | Every color is a role at a tone, never a hand-picked hex. Text is the on-surface role, quiet text the on-surface-variant role, links and marks the primary role |
| R2 | That system's color science and its open reference library | The palette is generated, not drawn: one seed, the library's default tonal scheme, contrast level 0 (`#2f8fa3` below) |
| R3 | A mobile OS's wallpaper-derived palettes: one source color picked from the wallpaper, every surface tinted toward it | Even the neutrals carry the seed's hue at low chroma, so no gray reads as "unthemed primer". Gel uses a fixed seed because cmux has no wallpaper-to-seed setting yet |
| R4 | The same system's shape scale (4, 8, 12, 16, 20, 28) | Large soft corners for the prompt bubble (14, between the medium and large steps), small for chips (8); the content card keeps the flush corner's own radius |
| R5 | The same system's motion tokens: decelerate on enter, short durations, motion that follows the finger | Gel adds no motion of its own; it keeps cmux's gated motion (below), whose curves already follow this rule |
| R6 | Shipped app 1: the OS's messaging app, whose bubbles are filled tonal containers with no outline | The prompt bubble is the secondary-container tone with no edge, and replies sit on the page with no box |
| R7 | Shipped app 2: the OS's own settings and launcher, where every group is a container one tone step off the page | Cards in the transcript are the surface-container tone one step off the page, again with no ring; sidebar sections draw as cards |
| R8 | A phone's status island, whose shapes merge and split like drops | The surface-tension motion: the flush corner's goo fillets, and the tab hover card that grows out of its tab |
| R9 | The platform's glass (Liquid Glass on macOS 26, vibrancy before it) | Glass only where a layer floats: the window frame and sidebar, the hover card, its state chip. Never under reading text |
| R10 | cmux's own design references: glass cards whose text bled through, doubled glass rims, a gray popover called "paint primer", the four glass levels, hover cards that show in their first frame | The chat stays opaque; one edge treatment per surface (a tone step, never a rim plus a line); every neutral is tinted; glass by level, never a hand-set blur; no fade or rise on hover cards |

## The palette

Seed `#2f8fa3` (sea glass), the reference library's default tonal scheme, light and dark.

| Role | Light | Dark | Where it goes |
| --- | --- | --- | --- |
| surface | `#f5fafc` | `#0f1416` | the terminal and app background (`Builtin Light/Dark` background), the chat |
| surface container | `#e9eff1` | `#1b2122` | `--cv-card-fill` |
| secondary container | `#cee7ee` | `#334a50` | `--cv-user-bubble-tint` (the prompt bubble) |
| primary container | `#a9edff` | `#004e5b` | the selection |
| primary | `#006879` | `#84d2e6` | the accent, cursor, `--cv-link`, `--agent-link` |
| on surface | `#171c1e` | `#dee3e5` | the foreground, `--cv-text` |
| on surface variant | `#3f484b` | `#bfc8cb` | `--cv-text-muted` |
| neutral variant tone 42 / 62 | `#5c6567` | `#8e979a` | `--cv-text-dim` (the scheme's outline role measured 4.25:1 on the light surface, below 4.5, so dim text takes the next tone down) |

## Decisions

1. **One seed, two appearances, one file.** The theme file names a light/dark pair
   (`light:Builtin Light,dark:Builtin Dark`) and gives each its own tones through
   `appearance.themeEdits`, so the app follows the system appearance with no second file. The chat
   stylesheet holds no color of its own: each token mixes the theme's `--agent-text` and
   `--agent-accent` (as `bun run check:look-addons` requires), so it takes the theme's tone in each
   appearance and follows the person's theme edits. The mixes were fitted to the tones in the
   table above; muted and dim text land within a few hundredths of the contrasts the table's tones give.
2. **Hierarchy: position, tone, weight, then color.**
   - Primary: what the agent said, on the opaque surface at 16:1 (light) and 14:1 (dark).
   - Current object: the selected tab, drawn in the content card's own color and flowing into it
     (the flush corner). It is the look's one bold shape.
   - Supporting: the sidebar on the window's glass, names in medium weight, the circular arc in the
     primary tone while work runs.
   - Optional: the hover card, a headline, a state chip on chip glass, the task, and place chips.
3. **No hairlines.** `appearance.borders: none`, `--cv-card-ring` and `--cv-user-bubble-edge`
   transparent. Surfaces part by one tone step (surface to container) and the title area by
   `appearance.titleAreaTone: subtleTone`. One edge treatment per surface.
4. **Glass where layers float, opaque where you read.** The window and sidebar are the system
   material under the surface tone at 88% (`appearance.backgroundBlur: glass`,
   `appearance.backgroundOpacity: 0.88`, `appearance.sidebarSurface: same`); the chat is opaque
   (`appearance.surfaces.agentPane.opacity: 1`). 88% is the least that keeps the primary tone at
   4.5:1 or more on the light glass over a black backdrop (table below). The hover card is the
   App's popover glass; its state chip is chip glass (`.glass("chip")`, guarded for older apps);
   its place chips are filled tonal containers, so the two kinds of chip read apart.
5. **Shape.** The prompt bubble 14 pt at the chat's text scale (20 and 16 both made a one-line prompt read as a capsule in review), chips 8 pt, the content card the flush corner's own radius.
   No capsule controls. Corners never change a box (`--cv-user-bubble-radius` is paint).
6. **Type and density.** Roboto in the chat (bundled with cmux) at 14 pt with a 1.6 line height and
   a 760 pt column; the sidebar and app at comfortable density, which also keeps the flush corner on
   (compact density turns it back into a pill). Unfocused panes' tabs tone down by tone
   (`focus.inactiveTabStyle: tonal`), not by fading.
7. **Motion: surface tension, from cmux's own gated motion only.**
   - The goo: `appearance.cornerFlush: flush-goo` draws the selected tab meeting the card
     through concave fillets, the way two drops merge. The setup sets it.
   - A tab's hover card grows out of its tab on the settle spring (the default entrance).
   - A sidebar hover card shows in the frame it opens in, with no fade or rise.
   - Gel sets no motion key: every animation runs through cmux's motion gates and obeys
     `ui.animationSpeed`, the category switches and Reduce Motion, and the frame with no animation
     is the same look. Nothing in the look moves a box.

## What a setup could not set

| Wanted | Key | Why not | Today |
| --- | --- | --- | --- |
| A seed taken from the wallpaper | none | cmux derives no palette from a picture | a fixed seed |
| A larger content-card radius | `layout.paneCornerRadius` | Setting it turns the flush corner's default off (it draws only over stock pane chrome) | the flush corner's radius |
| The custom hover card on first hover | none | A workspace's hover card opens collapsed (its tabs only); the `cmux.hovercard/1` card draws after Show details | hover a row, then Show details |

**Gel needs the goo.** It is designed with `flush-goo` on, and the setup carries
`"appearance.cornerFlush": "flush-goo"` (the setting #46367 added), so it installs with everything else.

**Open: the goo against an opaque chat.** The folder tab, and its fillets, paint what the window
paints: clear over a see-through window, so the tab shows the same glass as the content below it.
Gel's window is glass (`appearance.backgroundOpacity: 0.88`) but its chat is opaque
(`appearance.surfaces.agentPane.opacity: 1`), so on a chat tab the tab shows glass while the card
under it is the opaque tone, and the tab reads as a separate pill with no visible fillets (first
capture, 2026-11-18). Two ways to close it, each giving up something this design chose:

- the whole window opaque (`appearance.backgroundOpacity: 1`): tab and card match and the goo
  shows, but the sidebar loses its glass;
- the chat on the window's glass (drop `agentPane.opacity`): the goo shows, but the chat is no
  longer the opaque reading surface its contrast numbers assume.

To be decided from real captures of both.

## Contrast

WCAG 2 ratios, from `contrast.py` beside the look's staging folder (text needs 4.5:1, marks 3:1).
Glass rows put the surface tone at 88% over a pure black and a pure white backdrop, the two worst
cases; the blur only averages a real backdrop toward the middle.

| Pair | Light | Dark | Needs |
| --- | --- | --- | --- |
| `--cv-text` on the chat | 16.35 | 14.33 | 4.5 |
| `--cv-text-muted` on the chat | 8.91 | 10.90 | 4.5 |
| `--cv-text-dim` on the chat | 5.68 | 6.22 | 4.5 |
| `--cv-link` on the chat | 6.13 | 10.90 | 4.5 |
| `--cv-text` on a card | 14.81 | 12.60 | 4.5 |
| `--cv-text-muted` on a card | 8.07 | 9.59 | 4.5 |
| `--cv-text-dim` on a card | 5.15 | 5.47 | 4.5 |
| `--cv-link` on a card | 5.55 | 9.59 | 4.5 |
| `--cv-text` on the prompt bubble | 13.34 | 7.26 | 4.5 |
| `--cv-link` on the prompt bubble | 5.00 | 5.52 | 4.5 |
| The scheme's outline role as text (not used) | 4.25 | 5.84 | 4.5 |
| Accent as a mark on the chat | 6.13 | 10.90 | 3.0 |
| Sidebar glass over black: text | 12.46 | 14.58 | 4.5 |
| Sidebar glass over black: secondary text | 6.79 | 11.09 | 4.5 |
| Sidebar glass over black: accent | 4.67 | 11.09 | 4.5 |
| Sidebar glass over white: text | 16.48 | 10.30 | 4.5 |
| Sidebar glass over white: secondary text | 8.98 | 7.83 | 4.5 |
| Sidebar glass over white: accent | 6.18 | 7.83 | 4.5 |

The hover card's text uses the theme's semantic tokens on the App's popover glass, which the App
holds to its own contrast floor; Gel writes no hex color there.

## Visual review

Reviewed by the visual-review procedure against the references above, on the chat captures the
look-addons browser test draws (`webviews/test/browser/look-addons.test.ts`, headless Chromium on
Linux, light and dark; the test passes: every token lands, and applying, reloading and switching
the look moves no box).

1. Fixed: the prompt corner. At 20 and then 16 a one-line prompt read as a capsule, which the
   house rules reserve for circular marks; it is 14 now and reads as a soft rounded container.
2. Pass: the prompt bubble takes its own tone in each appearance (its tint mixes the theme's text and
   accent, so it follows the appearance), with no edge, on the tonal step the references show.
3. Pass: no hairline on the prompt or on cards; text, muted and dim text read at the contrasts above.
4. Open, evidence: the gallery draws the chat on the gallery's own page color, not the theme file,
   so the page tone, the sidebar glass, the flush-goo tab and the hover card are not in these
   images. A capture in the real macOS app is still owed.

Verdict: FIX (evidence) until a real-app capture shows the chrome; no open design fix in the
captured surfaces.
