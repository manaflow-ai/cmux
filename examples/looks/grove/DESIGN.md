# Grove: design notes

Grove is a themed nature look for cmux NEXT: a forest you work in. By day it is ink on unbleached
paper with frosted morning air in the sidebar; by night it is a deep fern dark under a moonlit
wood. Everything is set through public surfaces only ([look-addons.md](../../../docs/cmux-next/look-addons.md)).

## References

| Reference | What Grove takes from it |
| --- | --- |
| A forest-palette editor theme built for long sessions (green-led, warm, never pure black or white) | The idea of soft grounds: Grove's paper is `#f4f0e4`, not white, and its night is `#151c16`, a green-black, not black. Lightness steps between ground, card and bubble stay small. |
| A retro earth-tone editor theme with softened saturation | The terminal's sixteen colors are earth pigments muted the same way: red ochre, moss, yellow ochre, slate, heather, lichen teal. |
| A woodblock-print editor theme whose light variant reads as ink on paper | Light mode as ink on unbleached paper: a warm ground and a desaturated green-brown ink (`#2b3326`), never `#000`. |
| An outdoor clothing brand's editorial stories | A serif for reading over calm, quiet chrome, so the landscape carries the mood. Grove sets the chat's replies in a book serif and the UI around them in a humanist sans. |
| A mountain-gear brand's catalog | One muted accent and generous space; imagery sits around content, never under body text. Grove keeps the painting to the sidebar's glass and the edges of the window; the chat sits on near-solid paper. |
| Natural pigments: green earth (terre verte), umber, yellow ochre | Green earth's grey-olive is the moss accent (`#4a6a2c` day, `#a7c080` night); umber pushed toward green is the ink; yellow ochre is the cursor (`#a26d23` / `#d6a85c`). |
| Photographs of cypress-leaved plait moss, greenshield lichen on bark, Douglas-fir bark, and forests in fog | Moss for the accent; lichen's pale grey-green for the selection and the prompt bubble (`#dfe4cb`, `#dfe6cc`); bark for the card rings and muted text; fog for the sidebar's frosted glass: a light veil over a darker scene that loses detail and keeps color. |
| Two paintings from cmux's own art catalog: Van Gogh's *Wheat Field with Cypresses* (light tone) and Friedrich's *Forest Interior by Moonlight* (dark, bundled) | The wallpaper, one per appearance (`appearance.background: "appearance"`). Both are public domain and ship in cmux's catalog, so the look carries no image of its own. |

Design-reference captures read: a glassy browser sidebar that keeps its glass when the content
changes, and cmux captures where heavy translucency under the chat and composer hurt legibility.
That is why Grove puts glass in the sidebar and the hover card header only.

## Decisions

### Hierarchy

1. **The transcript** is the object: serif replies at 15 px, 1.65 line height, a 740 px column
   (about 70 characters a line), on paper at 0.97 opacity, so the painting never reaches body text.
2. **The prompt** is a lichen-washed bubble with an 18 px corner (the composer step of the radius
   scale), a faint hairline, ink text.
3. **The sidebar** is the frosted layer: the window's glass at 0.84 over the painting, the theme's
   ink on it, comfortable density, icons and branch shown, one regular weight for every row.
4. **Status** is the arc (a turning ring) in rows and the window, never a pulse; a needs-you state
   keeps its own mark.

### Color (both appearances)

| Role | Light ("morning") | Dark ("night forest") |
| --- | --- | --- |
| Ground (`background`) | `#f4f0e4` unbleached paper | `#151c16` night fern |
| Ink (`foreground`, `--cv-text`) | `#2b3326` green umber | `#dfd9c6` fog paper |
| Secondary (`--cv-text-muted`) | `#4b5442` bark | `#adb39f` lichen grey |
| Quietest (`--cv-text-dim`) | `#5c6352` | `#959b87` |
| Accent (`accent`) | `#4a6a2c` moss | `#a7c080` new moss |
| Link (`--cv-link`, `--agent-link`) | `#3f6a33` | `#b5cf8f` |
| Selection | `#dfe4cb` lichen | `#2b3a2c` |
| Cursor | `#a26d23` yellow ochre | `#d6a85c` |
| Card fill / ring | `#ebe6d6` at 0.9 / `#c4bea4` at 0.75 | `#1d261e` at 0.92 / `#3e4e3c` at 0.7 |
| Prompt bubble tint / edge | `#dfe6cc` at 0.85 / `#bac6a0` at 0.6 | `#2a3828` at 0.8 / `#4e6246` at 0.55 |

How light and dark are expressed: a theme file is one file for both appearances.
`appearance.theme` names a light and a dark terminal theme (`light:Builtin Light,dark:Builtin Dark`)
and cmux follows the system appearance between them; `appearance.appTheme: followTerminal` makes
cmux's own surfaces follow too. A theme file's `colors` block would paint both sides the same, so
Grove sets each side by name in `appearance.themeEdits` (`Builtin Light/background`, ...). Surface
overrides carry only an opacity, never a color, so each surface takes its appearance's ground. The
chat's stylesheet names no color: each token in its one `:root` rule mixes the theme's `--agent-text`
and `--agent-accent` (as `bun run check:look-addons` requires), so each appearance takes its own
side and the table's text, link, card and bubble rows are the tones those mixes were fitted to.

### Type

`agentPane.display.font.preset: serif` (the macOS book serif, with old-style and Georgia fallbacks)
for the transcript, and `agentPane.display.font.ui: source-sans` (a humanist sans cmux bundles) for
the chat's UI. A serif for reading and a humanist sans for controls is the pairing an editorial
outdoor page uses. Both are settings, so the transcript's height estimate reads them and nothing jumps.

### Shape

Soft and organic, inside the shared scale: `layout.paneCornerRadius: 12` (cards, 12 to 14), the
bubble's 18 px corner (composer), the hover card header at 8 (popup). `appearance.chromeStyle:
two-tone` gives one curved main card beside a soft sidebar shade, so the paper sits on the glass
like a page on moss. No extra borders: one edge treatment per surface.

### Glass and wallpaper

- `appearance.background: appearance` with `backgroundLight: van-gogh-wheat-field-cypresses` and
  `backgroundDark: friedrich-forest-moonlight`. A setup carries text files only, so the look cannot
  ship an image; both are catalog ids cmux knows (the dark one is bundled; the light one is fetched
  from cmux's art store on first use).
- `appearance.backgroundOpacity: 0.84` and `appearance.backgroundBlur: frosted`: the frosted
  morning air. The sidebar has no surface override, so it shows the window's glass; the chat
  (0.97) and terminals (0.95) are near-solid.
- `appearance.wallpaperTint: true`: the glass takes the painting's colors, so the sidebar reads
  green by day and blue-black by night.
- The hover card's header sits on the App's own `chip` glass through `.glass("chip")`, guarded for
  a cmux without it (paint only; nothing moves).
- `appearance.glassTransparency` stays at its default: the painting already shows through the
  window's 0.84 tint, and the contrast table below is computed for that tint; more see-through glass
  would need the worst case measured again.

### Motion

Calm and slow, and paint only (layout contract in look-addons.md):

- `ui.animationSpeed: normal` (the default is fast): the app's own animations at their standard
  durations.
- `appearance.colorTransition.duration: 320`, `curve: easeInOut`, `colorSpace: oklab`: a light to
  dark switch reads as one even dusk instead of a cut (inside the 300 to 400 ms "large" band, since
  it recolors the whole window; still short enough that a switch never waits on it).
- `appearance.statusIndicator.style: arc`: a turning ring for work in progress; no breathing or
  pulsing dot. Reduce Motion and the motion switches still apply unchanged.
- No stylesheet token or setting here moves a box.

## Contrast (WCAG 2.x), both appearances

Checked with a small script against each token's surface, including the translucent worst cases:
the chat at 0.97 and the sidebar glass at 0.84 over the darkest and lightest pixel of each painting
(black `#000000`; `#fffff2` by day, `#fdfffa` by night) and over each painting's mid tone. Targets:
4.5:1 for text, 3:1 for the accent as a non-text mark.

| Token | Surface | Light | Dark |
| --- | --- | --- | --- |
| ink | ground | 11.49 | 12.30 |
| ink | chat, worst painting pixel | 10.76 | 11.40 |
| ink | sidebar glass, worst painting pixel | 7.96 | 7.50 |
| ink | card fill | 10.51 | 11.06 |
| ink | prompt bubble | 10.26 | 9.29 |
| ink | selection | 10.03 | 8.53 |
| muted | ground | 6.97 | 8.04 |
| muted | chat, worst | 6.53 | 7.45 |
| muted | sidebar glass, worst | 4.82 | 4.90 |
| muted | card fill | 6.37 | 7.23 |
| dim | ground | 5.48 | 6.05 |
| dim | chat, worst | 5.14 | 5.61 |
| dim | card fill | 5.02 | 5.44 |
| link | ground | 5.55 | 10.16 |
| link | chat, worst | 5.20 | 9.41 |
| link | card fill | 5.08 | 9.14 |
| accent (non-text) | ground | 5.44 | 8.68 |
| accent (non-text) | sidebar glass, worst | 3.77 | 5.29 |

Terminal colors 1 to 6 and 9 to 14 on the ground: light 4.63 to 5.50, dark 5.89 to 10.59 (0, 7, 8
and 15 are the conventional near-ground and near-ink slots). Every text token passes 4.5:1 in both
appearances, and the theme file's contrast guard has nothing to correct.

## What a setup could not set

The corner is no longer on this list: `appearance.cornerFlush` (#46367) is a setting. Grove leaves it
at the person's own value.

- An image of its own: a setup holds text files; the wallpaper is a catalog id instead.

- The sidebar hover card: on the current app a `cmux.hovercard/1` card draws only after the
  built-in card's Show details is clicked (the collapsed card shows tabs only). Grove's card shows
  there; capture it by hovering a row, then clicking Show details.

## Visual review

Verdict, 2026-11-18: **FIX (evidence)**, under the visual-review procedure. There is no real-app
capture of Grove yet. The Mac capture of this commit built (fleet job ce420ca3a8f21afb8b6f71f6),
but its display step waited behind 15 older jobs for over 50 minutes and was cancelled. The browser
look-addons lane did not run on the Linux pool because it had no system Chrome. So the one finding is:

1. Evidence: capture Grove in the real app, light and dark, with the sidebar, an agent chat with a
   real transcript, and the hover card after Show details, and judge the taste criteria (moss accent
   weight, how much painting shows through the 0.84 sidebar glass, serif against the humanist sans)
   from those captures.

The static checks below pass: the contrast table above, `check:look-addons`, and the setup install
test.
