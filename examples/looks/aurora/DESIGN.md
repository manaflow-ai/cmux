# Aurora: design notes

The glass-forward look. The window's chrome (titlebar, tab strip, sidebar) is the Mac's own clear
glass over your desktop; the chat is the content layer and stays nearly solid; a cool northern-lights
accent, teal at its base and violet at its upper edge, shows in only a few places. Light and dark
are both designed, and the look reads with Reduce Transparency on.

## The job

A person runs several agent chats and glances at the sidebar to see which needs them. The look must
make that glance faster, not prettier at its expense: the active chat's text reads first, the
sidebar's names second, status third. Glass earns its place by separating the functional layer
(navigation, tabs, the hover card) from the content, and by letting the desktop's color into the
chrome so the window sits in its place on the screen.

## References

| Reference | What Aurora takes |
| --- | --- |
| The platform's materials guidelines and the macOS 26 Liquid Glass material | Glass belongs to the functional layer that floats over content, never to the content itself. Chrome takes the wallpaper's hue. Corners grow rounder and concentric. Color is used sparingly so the content brings the color. Under Reduce Transparency every surface must still read. |
| A spatial OS's floating windows | Legibility on glass comes from a darkening tint behind bright text, one hairline rim, no heavy shadow, and hover feedback in paint only. |
| A launcher app's translucent panel and its chat view | Plain list rows, muted group labels and one accent for the current item. The accent never fills a large area. |
| A browser whose sidebar takes each space's color | Identity can live in the sidebar's color (here the group colors run through an aurora gradient) while the rows stay quiet. |
| A desktop agent app over a vivid wallpaper | The layer split Aurora uses: a pale translucent sidebar beside a solid content pane. |
| Aurora photographs and the aurora's emission lines | The palette is physical: atomic oxygen's 557.7 nm green-teal low in the curtain, the blue-violet of ionized nitrogen at its upper fringe, a blue-black polar night and snow. |
| cmux's own glass captures and rulings | Heavy translucency behind text was judged hard to read and a too-glassy composer too much; floating cards that went opaque were judged wrong the other way. So: chrome glassy, content near solid, floating cards on glass. |

## Decisions

### Material and hierarchy

| Layer | Setting | Value | Why |
| --- | --- | --- | --- |
| Window glass | `appearance.backgroundBlur` | `glass` | The native glass (Liquid Glass on macOS 26 and later, the vibrancy material before). |
| | `appearance.background` | `none` | No painting: the glass shows your own desktop, as the system's own windows do. |
| | `appearance.backgroundOpacity` | `0.72` | The lowest tint at which the sidebar's primary text keeps 6.6:1 (dark) and 7.9:1 (light) over the worst desktop, and the host can still keep a distinct secondary ink at 4.5:1 (table below). Lower than this, secondary text has to rise to primary ink and the hierarchy flattens. |
| | `appearance.wallpaperTint` | `true` | The glass leans toward the desktop picture's hue. |
| | `appearance.glassTransparency` | `0` | One knob for see-through (opacity), not two. |
| Sidebar, titlebar, tab strip | `appearance.sidebarSurface` | `same` | No override: the sidebar is the window's glass, the clearest layer. |
| Chat | `appearance.surfaces.agentPane.opacity` | `0.9` | The content layer. 90% keeps a hint of the desktop's color at the edges while body text stays above 12:1 on any desktop. |
| Address bar | `browser.omnibar.glassTint` / `glassTintStrength` | `accent` / `0.12` | A faint teal in the browser's glass, the only tint outside the chat and hover card. |
| Window style | `appearance.chromeStyle` | `flat` | The stock chrome, so the default flush corner draws (the selected tab rises from the content card's edge). |
| Density | `appearance.density`, `sidebar.density` | `comfortable` | Room around glass edges; compact would also turn the flush corner off. |

### Color

One theme file gives both appearances: `appearance.theme` names a light and a dark terminal theme
(`light:Builtin Light,dark:Builtin Dark`), and `appearance.themeEdits` gives each its own colors, so
the whole look follows the Mac's appearance.

| Role | Dark (polar night) | Light (snow) |
| --- | --- | --- |
| Background | `#0a0f1c` | `#f4f7fb` |
| Text | `#e7ecf4` | `#161d2b` |
| Accent (selection, focus, Send, running status) | `#5eead4` teal | `#0b5d55` glacier teal |
| Cursor and ANSI magenta (the violet) | `#c4b5fd` | `#6d28d9` |
| Selection | `#233049` | `#cfe0f2` |

The light accent is deeper than a pure aurora teal on purpose: it must stay a 3:1 mark on the
clearest glass over a black desktop. The 16-color terminal palette is tuned per appearance; every
color but the black and white slots keeps 4.5:1 on its terminal background.

Accent budget, every place it shows: the selection and focus ring and Send (the theme accent), the
hover card's mark for running work, the prompt bubble's teal tint and teal hairline, the address
bar's 12% tint, the cursor, and the sidebar's group colors (the built-in aurora gradient, which only
draws when you make groups). Nothing else is colored.

### Chat paint (`agent-pane/theme.css`)

Every color is made from the theme's own (`--agent-text`, `--agent-accent`), as `bun run
check:look-addons` requires: the theme file sets the accent per appearance, so the 8% tint reads as
pale teal on snow and deep teal on polar night, and the stylesheet follows the person's theme edits.

| Token | Value | Why |
| --- | --- | --- |
| `--cv-user-bubble-tint` | `color-mix(in srgb, var(--agent-accent) 8%, transparent)` | The prompt is the person's voice: the one teal surface in the transcript. |
| `--cv-user-bubble-edge` | `color-mix(in srgb, var(--agent-accent) 38%, transparent)` | A teal hairline, the bubble's one edge treatment. It was the aurora's violet upper edge, which the chat's theme variables cannot make (no violet among `--agent-text`, `--agent-accent`), so the violet now shows in the cursor and the terminal's magenta only. |
| `--cv-user-bubble-radius` | `16px` | Rounder than a card (12 to 14) to follow the glass geometry, short of a capsule. |
| `--cv-card-fill`, `--cv-card-ring` | the text at 4%, the text (with a tenth of the accent) at 13% | A neutral wash and hairline that read in both appearances. |

Body, muted and dim text and links keep the host's colors, which it derives from the theme file per
appearance and holds to 4.5:1. A single link color cannot reach 4.5:1 on both snow and polar night,
so the look does not set one.

### Hover card (`customize/main.js`)

The card already floats on the app's popover glass. Inside it:

1. The title in bold primary ink, with the age in secondary ink on its line.
2. The status on a small chip of chip-level glass (`.glass("chip")`, radius 8, never a capsule):
   an SF Symbol in the status's tone plus the status in words, so color is never the only signal.
   Running work uses the accent, waiting uses warning, failure uses danger, done uses success.
3. What the agent is asking, or else what it is doing, in up to three lines of primary ink.
4. Where it runs (branch, pull request, machine) on one line of secondary ink.

Every color is a theme token, so light, dark and Reduce Transparency follow the theme. The glass is
guarded (`typeof node.glass === "function"`), so an app from before `.glass` draws the chip without
glass instead of failing. Rows keep their defaults: the arc status indicator and your own icons.

### Motion

Aurora adds no motion and sets no motion setting: every token and setting is paint, and none moves a
box (the add-on tests check this). The glass's own transitions (the color crossfade on a light or dark
switch, hover cards fading in, the flush corner's tab change) are the app's, under its motion
switches and Reduce Motion.

## Contrast

Computed by a script that models the app's surfaces: the window tints its glass with the theme
background at 0.72; an opacity-only surface override covers the backdrop by exactly its opacity; the
host's secondary and tertiary inks are derived the way the app derives them (`cmux-theme-tokens`
`inks`: muted toward the background as far as they keep 4.5:1 and 3:1 over the worst see-through
surface). The desktop is taken unblurred and the glass's own luminance adaptation is ignored, so these
are the worst case. Backdrops: black, white, 50% gray, aurora green, deep blue, violet, sunlit snow.

| Appearance | Surface | Token | Min | Reduce Transparency | Gray desktop | Worst (backdrop) |
| --- | --- | --- | --- | --- | --- | --- |
| dark | sidebar + chrome | primary text | 4.5 | 16.12 | 11.34 | 6.57 (white) |
| dark | sidebar + chrome | secondary text | 4.5 | 11.20 | 7.88 | 4.56 (white) |
| dark | sidebar + chrome | tertiary mark | 3.0 | 7.56 | 5.32 | 3.08 (white) |
| dark | sidebar + chrome | accent as a mark | 3.0 | 12.93 | 9.09 | 5.27 (white) |
| dark | chat | primary text | 4.5 | 16.12 | 14.60 | 12.58 (white) |
| dark | chat | secondary text | 4.5 | 11.20 | 10.15 | 8.74 (white) |
| dark | chat | tertiary mark | 3.0 | 7.56 | 6.85 | 5.90 (white) |
| dark | chat | text on prompt bubble | 4.5 | 12.58 | 11.05 | 9.42 (white) |
| dark | chat | secondary on prompt bubble | 4.5 | 8.74 | 7.68 | 6.54 (white) |
| dark | chat | text on card | 4.5 | 14.88 | 13.27 | 11.36 (white) |
| dark | chat | secondary on card | 4.5 | 10.34 | 9.22 | 7.89 (white) |
| dark | chat | accent as a mark | 3.0 | 12.93 | 11.71 | 10.09 (white) |
| dark | Send | glyph on accent | 4.5 | 14.20 | - | 14.20 |
| light | sidebar + chrome | primary text | 4.5 | 15.70 | 11.54 | 7.92 (black) |
| light | sidebar + chrome | secondary text | 4.5 | 9.07 | 6.67 | 4.58 (black) |
| light | sidebar + chrome | tertiary mark | 3.0 | 6.03 | 4.43 | 3.04 (black) |
| light | sidebar + chrome | accent as a mark | 3.0 | 7.21 | 5.30 | 3.64 (black) |
| light | chat | primary text | 4.5 | 15.70 | 14.13 | 12.54 (black) |
| light | chat | secondary text | 4.5 | 9.07 | 8.16 | 7.24 (black) |
| light | chat | tertiary mark | 3.0 | 6.03 | 5.42 | 4.81 (black) |
| light | chat | text on prompt bubble | 4.5 | 14.40 | 13.11 | 11.81 (black) |
| light | chat | secondary on prompt bubble | 4.5 | 8.32 | 7.58 | 6.82 (black) |
| light | chat | text on card | 4.5 | 14.48 | 13.10 | 11.70 (black) |
| light | chat | secondary on card | 4.5 | 8.36 | 7.57 | 6.76 (black) |
| light | chat | accent as a mark | 3.0 | 7.21 | 6.49 | 5.76 (black) |
| light | Send | glyph on accent | 4.5 | 7.75 | - | 7.75 |

Terminal ANSI 1 to 6 and 9 to 14 on the terminal background: lowest 6.91 (dark), 5.36 (light).
The worst backdrop for a dark theme is a white desktop and for a light theme a black one; every token
passes there. The sidebar is the tight row (secondary 4.56 and 4.58), which is why the window's tint
stops at 0.72.

## Reduce Transparency

With Reduce Transparency on (or `ui.reducedBackgrounds`), the app paints every surface in the theme
background, opaque: no glass, no desktop. Aurora then reads as a calm two-tone look, polar night or
snow, with the same accent, and contrast only rises (the Reduce Transparency column above). The hover
card's chip falls back to the chip level's opaque surface. Nothing in the look depends on the desktop
showing through.

## What a setup cannot set

The goo corner is no longer on this list: `appearance.cornerFlush` (#46367) is a setting. Aurora
leaves it at the person's own value, so the default flush corner (no fillets) draws.

- A link color per appearance: the chat stylesheet's tokens are single values (above).
- The composer's look, as for every look (docs/cmux-next/look-addons.md).

## Visual review

Reviewed from real captures on a fleet Mac (macOS 27, cmux NEXT nightly 4424316677601, the look
installed with `cmux setup install` from this folder), over a warm sunset wallpaper. The method was
the visual-review procedure: each still opened at full size and checked against the references and
the criteria above. The captures are light and dark chat, light and dark hover card, Reduce
Transparency in both appearances, and a 36 s video.

Verdict: **FIX**, held by two app-side blockers. The look's own files have no open fix.

| # | Kind | Where | Finding | Action |
| --- | --- | --- | --- | --- |
| 1 | pass | sidebar, tab strip, light and dark | The chrome is clear glass that takes the wallpaper's warmth. Row names, Home and App Store read at a glance on both appearances. The selected row and selected tab carry the only teal. | none |
| 2 | pass | chat, light and dark | The chat reads as the solid content layer. In light, a trace of the wallpaper shows at 90%, but body text, inline code and the code block stay crisp. The teal "New" divider is the one accent in the transcript. | none |
| 3 | pass | Reduce Transparency, both | It becomes opaque polar night or snow with the same teal (selection, divider, update button) and nothing missing. It is calmer, but still Aurora. | none |
| 4 | fix (app) | prompt bubble, nightly | The bubble draws the host's neutral gray, not the teal tint and hairline. The nightly's chat has no `--cv-user-bubble-*` tokens yet; they arrive with the look-add-on change this folder ships with. With that change's chat bundle loaded (`cmux customize use pr:46049`), the bubble is pale teal with its teal hairline, as designed (`aurora-L-chat-pr`, `aurora-D-chat-pr`). | none in the look; lands with the token change |
| 5 | fix (app) | hover card, nightly | The built-in card shows, not Aurora's chip card. The app lists `local/customize` as installed, enabled and not hidden, and shows no "Custom card error". The documentation's own template card does not draw on this nightly either, so this is not Aurora's script. `.glass(level)` is also newer than this nightly, so the chip falls back to its padded shape (the guard). | report to the app; recapture on a nightly with the custom card and `.glass` |
| 6 | taste | built-in hover card | The built-in card on popover glass sits well with the look: bold title, dim model line, no extra color. | none |

What the video shows: the stock look switches to Aurora, the pointer hovers the chat row (the card
fades in), a tab switch goes to Home and back, then dark and light again. Every change is paint
only; nothing in the window moves.
