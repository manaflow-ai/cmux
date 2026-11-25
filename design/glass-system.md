# One glass system

Leo, 2026-11-19, on how we do glass across the app: we should look at where we use glass and where
we don't, and do it properly; it is fine in most places but weak in some.

This page is the rule for glass in cmux NEXT, the numbers each level takes, and the audit of every
surface that draws glass or chooses not to. The numbers live in one place,
`schemas/design-scale/design-scale.json` (`glass`, `glassSaturation`, `glassEdge`, `glassUnderlay`,
`transientMaterial`). `webviews/scripts/pages/gen-design-scale.mjs` writes them into the
`--ds-glass-*` block of `webviews/src/pages/shared/desktop.css`; Swift reads the same numbers
(`TransientMaterial.swift`, `GlassMenuMaterial.swift`, `TooltipSurface.swift`), and
`webviews/test/floating-material-sync.test.ts`, `webviews/test/tooltip-surface.test.ts` and
`scripts/cmux-next/check-surface-roles.py` fail when a copy drifts.

Related pages: [surface-materials.md](surface-materials.md) decides which kind a surface is (native,
host glass, page glass); [transient-material.md](transient-material.md) owns the shared native
material. This page owns the levels and their numbers.

These rules are the default look. Settings > Appearance > Previous Glass Look
(`appearance.previousGlass`, off by default) folds them away: the App sends `glassLevels: "previous"`
with the web theme, every page sets `data-glass-levels="previous"` on `<html>`, and glass.css
(PREVIOUS GLASS) draws the numbers from before this page (the Before column below, one tint for light
and dark, no lit top edge, content cards as chrome glass, the page's own secondary ink).
`webviews/test/previous-glass.test.ts` checks them against the gallery's `now` arm. When cmux#46104
lands, its Liquid Glass off (`data-glass="off"`) turns every web glass solid, as Reduce Transparency
does. Native glass (the window, sidebar, native menus, the native tooltip) is not changed by this page.

## The rules

1. **Native where native.** The window, the sidebar and the titlebar are the App's own glass
   (`WindowMaterialView`, `GlassPanelView`). A web page over them draws text only: no tint and no
   `backdrop-filter`. A page's `backdrop-filter` cannot see native glass under a see-through web
   view (the page root is a backdrop root), so a web tint there is glass on glass.
2. **Web glass is for floating things.** Menus, popovers, hover cards, tooltips, and the composer
   while it floats. Cards, rows and bubbles in the content layer get a near-solid surface, not
   glass: `.ui-glass.ui-glass-content`, the content tint (`glassContent`, 88% / 86%) with no `backdrop-filter`
   (they scroll, rule 7) and the hairline ring alone. Never opaque (the glass rule's 90% cap); off
   and Reduce Transparency draw the opaque surface as for every `.ui-glass`.
3. **Five levels, one saturation (1.6), light and dark apart.** Dark glass reads denser at the same
   alpha, so a level runs a few points clearer in dark where the legibility floor (rule 5) allows: the
   menu does; the chrome and the popover hold the light side's tint.
4. **One edge.** The host's hairline ring (`--glass-edge`, the card rim; transparent with borders
   off) plus one lit hairline on top (`--cmux-tone-light` at 60% light, 24% dark). No second
   border. The specular sheen belongs to the one hero surface, the composer (`.ui-glass-material`).
5. **Legibility floor.** Primary text keeps 4.5:1 and secondary 3:1 against the glass laid over
   pure black and pure white. If a level fails at its tint, the tint goes up for that level; the
   text never gets thinner. The tooltip already works this way (`TooltipSurface.tintAlpha`).
   Secondary text on glass is one ink: the theme's text at `--ds-glass-ink-secondary` (68% light,
   68% dark, `glassInk` in the design scale) over the glass, which every glass surface's secondary
   tokens (`--cmux-text-secondary`, `--cmux-text-tertiary`, `--agent-muted`, `--page-text-2/3`,
   the composer placeholder and dim words, and a field's own placeholder) read inside `.ui-glass`.
   The page's secondary ink is fitted to an opaque page, so under dark glass on a white page it fell
   to 1.6-2.8:1 (the audit, cmux#48174); an alpha of the text moves with what the glass lets through.
   A status word on glass (red, amber, green, merged purple, the unread blue: `--agent-status-*`,
   `--agent-danger`, `--agent-warning` and the needs-you mark, the diff marks,
   `--ds-color-danger/attention/success`) is one ink too: the design scale's `glassInk.status` share
   of its hue (65% light, 55% dark), the rest the theme's text, so "Checks failed" on a dark hover
   card over a white page keeps 3:1 (it was 2.2:1) and "Needs input" on a light one over black keeps
   it (it was 1.9:1). A solid destructive button keeps the hue (`--glass-hue-danger`). A link
   (`--agent-link`) and a diff count (`--acpmux-add/del`) mix the same way (a PR card's blue link
   was 1.5:1 under dark glass on a white page, cmux#48217). A tooltip's tint is fitted to its text
   at 4.5:1, so inks dimmer than the text get less room there: a status word in a tooltip keeps
   `glassInk.chipStatus` (35%) of its hue, and the shortcut's keycap hint is the text at
   `glassInk.keycap` (84%), not the secondary ink (it was 2.6:1). The thread minimap's hover card
   (`.acpmux-minimap__card`) is a glass level on its own class and reads the same inks.
6. **See-through pages.** Where the page can blur itself under a surface (`seeThroughBlur.ts`,
   `data-glass-over`), it does, and the surface lays no underlay. Where it cannot, the underlay is
   40% in light and 57% in dark, so a menu (80% over 40%, or dark's clearer 72% over 57%) covers 88%
   of the text under it in both, not 93%; at 40% the dark menu covered 83% and the chat read through
   the Model menu (hq#13923).
7. **Perf budget.** At most two backdrop-filtered surfaces on screen at once, together under about
   a quarter of the window. Never animate a blur radius (animate opacity and transform). No
   `backdrop-filter` on anything that scrolls with content. No `will-change` on a glass parent (it
   becomes a backdrop root and cuts the blur).
8. **Bars over scrolling content** extend the blurred layer past the bar and mask it, or use a
   short variable blur at the scroll edge.
9. **Fallbacks.** Reduce Transparency and Liquid Glass off draw the opaque surface and its hairline.
   Increase Contrast on macOS 26 turns Reduce Transparency on, so the same path covers it.

## One material per surface (2026-11-21)

Leo: "our shitty multi layer glass + web view. we need to properly do that once and for all." Every
floating web surface (menu, popover, combobox, tooltip, hover card and hover preview, toast, dialog,
floating composer) draws exactly one material.

- **R1.** Either the App's host glass (`data-host-glass`; the page lays no fill, tint, rim or
  shadow) or the page's one `.ui-glass` with its level tokens. Never both, never neither.
- **R2.** On a surface the App draws, the only `backdrop-filter` left is the tint-free in-place blur
  of the page's own pixels under it (`seeThroughBlur.ts`, `data-glass-over`). No fill.
- **R3.** Nothing outside `.ui-glass` declares its own `backdrop-filter` with a translucent fill. A
  blur that is no surface's material (a masked scroll edge, a scrim) says so on its rule:
  `/* one-material-allow: <reason> */`. That list only shrinks.
- **R4.** The composer and its pickers are one family: the same blur, edge and shadow tokens as
  the popups (the transient material: 80% light / 72% dark, 32px, `--elevation-2`), and text on
  it keeps 4.5:1. One departure: the composer's tint base stays `--acpmux-composer-solid` (Leo's
  lift) rather than `--glass-surface`.
- **R5.** No glass inside glass: nothing inside a floating surface is itself a material. Controls
  on glass are plain controls.
- **R6.** One stroke, from the theme: a floating surface's edge is the theme's edge token
  (`--glass-edge`), never a literal colour, never a border plus a ring.

Who decides: glass.css's HOST GLASS rule clears the page's material, and `hostGlass.ts` decides what
the App is told. They read the same attributes, so they agree:

| State of a marked surface | Who draws | Page fill / blur |
| --- | --- | --- |
| Not seen yet (no `data-host-glass-drawn`, host glass on) | nobody, for one frame | hidden (`filter: opacity(0)`) |
| `drawn="1"`, not a cover, or a cover with `data-glass-over` | the App | none / none (only the in-place blur under it) |
| `drawn="1"`, a cover with nothing blurred in place | the page | `.ui-glass` (the App is not told: cmux#49499) |
| `drawn="1"` over the composer (`data-glass-keeps-underlay`) | the page | `.ui-glass` (the App is not told: cmux#49499) |
| `drawn="0"`: past the 50 ms deadline, an older App, past `HOST_GLASS_MAX` | the page | `.ui-glass` |
| Closing (`data-ending-style`) | the page | `.ui-glass`, fading with its content |
| WebKit without `data-host-glass-engines="all"`, an opaque page, the lens | the page | `.ui-glass` |
| Reduce Transparency | the page | the opaque surface, no blur |

Until cmux#49499 lands, the two "the App is not told" rows still get App glass under the page's
(the double glass that PR removes).

Checks, all in `bun run check:one-material` (in `check:pieces` and CI's web lint list):

- `webviews/scripts/check-one-material.ts` (R1 to R3; `test/one-material.test.ts`). Allowed blurs
  outside `.ui-glass`, each with a `one-material-allow:` reason: pinned at 25 (`ALLOWED_MAX`), counted
  per line. They are: the diff viewer's own film (`styles.css`, `acpmux/styles.css`,
  `pierre-options.ts`); modal scrims (file search, both lightboxes); sticky veils over scrolling rows
  (sidebar project headers, transcript header, the tab row, the notes chip row, the outputs edge
  fade); the tooltip and hint fallback paint in `pages/shared/desktop.css` for a page without
  glass.css; a `.ui-glass` tip's arrow; the composer strip and the Updated card (the composer's
  material, one surface); the token sheet's specimen.
- `webviews/scripts/check-no-nested-glass.ts` (R5; `test/no-nested-glass.test.ts`). One allowed:
  the DiffToolbar submenu (`NESTED_ALLOWED_MAX = 1`).
- `webviews/scripts/check-one-stroke.ts` (R6, web; `test/one-stroke.test.ts`) and the `[hard-edge]`
  rule of `scripts/cmux-next/check-overlay-glass.py` (R6, native). No allowances
  (`EDGE_ALLOWED_MAX = 0`); in-flow edges (not floating surfaces) are listed there with reasons.
- `webviews/test/one-material-browser.test.ts` mounts each floating primitive (menu, popover,
  tooltip, hover card, notice, dialog, the rail's preview card, the link hover card) in Chromium and
  reads its computed fill, blur, rim and anything nested in every state above, light and dark.

Census (2026-11-21):

| Surface | Before | After |
| --- | --- | --- |
| Rail preview card (`PreviewCard.tsx`) | private 72% fill and blur, unmarked | `.ui-glass` transient, host popover |
| Link hover card's Open \| chevron (`linkCard.css`) | framed capsule on the card's glass | no frame, one hairline between the halves |
| Composer's active chip (`composerV2.css`) | its own shadow on the composer | plain |
| New Tab widget previews (`AddWidgetGallery.tsx`) | `.ui-glass` inside the gallery | plain card fill |
| DiffToolbar submenu | glass in a menu | allowed (1) |
| Paste-loading chips (`PASTE_LOADING_CLASS`) | glass in the composer | kept: Leo asked for them to be glass |
| Tab hover preview's edge (native `HoverCardPanel`) | the system's dark outline | the theme's edge, one device pixel |

The tab hover preview's black border: `HoverCardPanel.swift` makes
`Glass.makeOverlayPanel(tone: .neutralGlass(.transient))`, whose `.appKitRegular` variant does not
draw a rim (`OverlayGlassVariant.swift`), so `OverlaySurface.installRim` skipped it and
NSGlassEffectView's own dark outline showed. `ThemeEdgeView` now lays the theme's edge there; with
Borders set to none it is clear.

## The levels

`color-mix` percentages of `--glass-surface` (the theme surface). Before is the base of this page's
PR (cmux#46104's head); after is what ships with it.

| Level | Used by | Before | After (light / dark) | Backdrop before | Backdrop after |
| --- | --- | --- | --- | --- | --- |
| chrome | bars and panes docked on the page where no native glass is under it | 60% | 62% / 62% | `blur(20px) saturate(1.4)` | `blur(20px) saturate(1.6)` |
| popover | glass in the page that floats but is not a popup: composer, Session Info, running tray, side tabs, viewers | 70% (50% over art) | 72% / 72% (50% over art) | `blur(24px) saturate(1.25)` | `blur(24px) saturate(1.6)` |
| menu | every popup and hover card (`--ds-glass-menu-*`, `--ds-transient-web-*`) | 78% | 80% / 72% | `blur(32px) saturate(1.6)` | unchanged |
| chip | tooltips, the find pill, chips | host contrast-fitted, floor 60% | unchanged | `blur(24px) saturate(1.6)` | unchanged |
| scrim | behind sheets and dialogs | native `Scrim` (`--cmux-scrim`) | unchanged | none | none |
| composer material | the one hero surface | the popover tint | the popover tint | `blur(24px) saturate(1.8)` | `blur(24px) saturate(1.6)` |
| see-through underlay | floating glass in a see-through page that cannot blur itself | 70% (93% cover under a menu) | 40% / 57% (88% in both) | | |
| edge | every plain glass | hairline ring | hairline ring plus lit top hairline (60% / 24%) | | |

The chrome's dark tint is 62%, not 55%: at 55% the chrome bar's title fell to 3.8:1 over a white page
in dark (and the onboarding import cards, on the chrome level, to 3.5:1), so by rule 5 the tint went
up to the light side's. The popover's dark tint is 72%, not the research note's 64%: at 64% the composer's prompt fell under
4.5:1 over a white page in the dark theme (`webviews/test/composer-glass.test.ts`), and at 70% the
prompt's code (the editor's 8% text fill under inline code and a code block) read 4.48:1 there
(the audit, cmux#48174), so by rule 5 the tint went up to the light side's and the text stayed: 4.67:1.

Not changed, on purpose:
- **chip** keeps the native tooltip's numbers (24 px, a 60% floor that the host raises until text
  keeps 4.5:1 over black and white). Its floor of 75% / 68% from the research note would change the
  native tooltip, which is not behind the Liquid Glass setting; that goes in its own PR.
- **lens** (40%, `blur(6px) saturate(1.3)`) and **fisheye** (50%, `blur(2.5px) saturate(1.15)`) are
  opt-in modes, not levels; they keep their own frost.
- **Surface roles** (card 45/42%, group 20/6%, toast 55/42%, sheet 62/48%) are native-first numbers
  (`schemas/surface-roles`, `SurfaceRole.swift`); moving them changes native cards with Liquid
  Glass off, so they are a follow-up.

## The gallery

`ui.glass-system` (`webviews/src/ui/glass/GlassSystem.gallery.tsx`) draws chrome, popover, menu,
a hover card and a tooltip on their real classes over a page of text, in the frame's theme and
background. Variants: `glass` (Liquid Glass on), `glass-off` and `reduce-transparency`. The
candidates are arms of `webviews/scripts/gallery/capture-states.mjs` (CSS that resets the tokens):
`now` (the numbers before), `rulebook` (ships), `denser` and `clearer`.

## Audit

Every surface that draws glass or chooses not to, from a full read of `webviews/src` and
`Packages/macOS/CmuxNext/Sources` at cmux#46104's head. N is native, W is web. "Level" is what the
surface takes after this change.

### Window chrome

| Surface | N/W | Today | Rule | Fix |
| --- | --- | --- | --- | --- |
| Window backdrop: sidebar, titlebar, panes (`WindowMaterialView`, `WindowBackdrop`) | N | `GlassPanelView` regular or clear; opaque under Reduce Transparency | 1: native | none |
| Secondary windows' backdrop (`WindowSurfaceView`) | N | same as the window | 1 | none |
| Per-pane art layer (`PaneContentView+Backdrop`) | N | `WindowMaterialView` translucent, art and tint | 1 | none |
| Sidebar ground (`SidebarStyle`) | N | clear over the window glass, optional dim | 1 | none |
| Sidebar stuck header veil (`SidebarStuckVeilView`) | N | `NSVisualEffectView` `.sidebar` within-window, tone at 90% | 1, 8 | none |
| Sidebar group headers and panes (`GroupGlassPaint`) | N | painted veil, group role 20% / 6% | 2: near-solid in content | follow-up (native role) |
| Sidebar Update Ready, notice, tip, Now Playing cards; App health chip (`CardSurfaceView`) | N | card role 45% / 42% veil and rim | 2 | follow-up (native role) |
| Sidebar Updated card (`SidebarUpdatedCardHost` + `updateSurfaces.css`) | N+W | untinted native glass, the page paints the composer tint (70% / 50%) and rim over it | 1: glass on glass | follow-up: drop the page tint over the native glass (needs a Mac capture) |
| Sidebar web cards (`updateSurfaces.css`) | W | `--glass-surface` at 42%, no blur, over the window glass | 1, 2 | follow-up, with the card role |
| Sidebar chats strip (`sidebar-chats`) | W | transparent page over the native sidebar | 1: text only | none (already right) |
| Settings sidebar shade (`settings/look.css`) | W | spread shadow of `--cmux-sidebar-surface` over a clear sidebar | 1 | none (a shade, not glass) |
| Tab strip glass (`TabStripView`) | N | `makePanel` chrome, only the Demo uses it | 1 | none |
| Dock column backdrop (`DockBackdropView`) | N | rim plus opaque fill | 2 | none |
| Browser omnibar (`OmnibarGlass`) | N | glass only if the user picks it (default off) | 1 | none |
| Home sidebar filter and search circles | N | untinted `GlassPanelView` | 1 | none |
| Settings jump bar (`settings/layout.css`) | W | popup surface at 92% plus the chrome blur | 8 | none (near-solid bar over scrolling text) |
| Settings scroll-edge fade | W | progressive blur 1/2/4/8 px | 8 | none (a fade, allowlisted) |
| Agent header solo-tab band (`header.css`) | W | `blur(6px)` masked band | 8 | none (a fade) |
| Diff file bars, files panel (`styles.css`, `diffTokens.css`) | W | text at 5% plus `blur(20px)`, no saturation | 3 | none (allowlisted bar blur; kept as Lucas decided) |
| Home messages header (`transcript.css`) | W | surface at 72% plus the chrome blur | 3 | chrome blur now 1.6; tint left (sticky bar over text) |
| Updated card note chips (sticky) | W | composer tint, 24 px | 3 | blur now 1.6 through the level |

### Floating, web

| Surface | Today | Rule | Fix |
| --- | --- | --- | --- |
| Shared Menu, ContextMenu, Combobox, Popover (`ui/Menu.tsx`, `ContextMenu.tsx`, `Combobox.tsx`, `Popover.tsx`) | menu 78%, 32 px, 1.6; host glass veil 40% | menu | 80% / 72%; 88% cover in see-through pages |
| Diff toolbar menus, branch base picker | menu | menu | same |
| Slash, mention and emoji menus; model picker; + menu; New Tab suggestions; agents list; steer queue | menu | menu | same |
| Context ring card (`contextCard.css`) | menu | menu | same |
| Page row menu (`PageMenu.tsx`, `pageBase.css`) | `--ds-glass-menu-*` 78% | menu | 80% / 72% |
| Hover cards: link preview, PR card, cmux link card, session hover, Home link (`AnchoredCard`) | menu, page blurs the chat in place | menu | 80% / 72% |
| Chat header tool preview (`HeaderToolPreview.tsx`) | solid elevated surface, no blur (the one solid hover preview left) | menu | the shared hover card (`.ui-card.ui-glass`), 80% / 72%, 32 px; `test/hover-glass-browser.test.ts` reads every hover surface's computed backdrop-filter |
| Feature tip (`featureTip.css`) | menu; accent look 62%, veil look 45% / 22% | menu | menu part follows; private looks stay (opt-in looks) |
| Keybindings recorder | menu over a 92% underlay (the text floor) | 5 | none: a recorder over rows keeps its floor |
| Tooltips, title tooltips, toolbar hints (`Tooltip.tsx`, `titleTooltips.ts`) | host contrast-fitted tint, 32 px, 1.6 | chip, 5 | none (already the rule) |
| Chief usage chart tooltip | tooltip tint | chip | none |
| Find pill (`findPill.css`) | tooltip tint, material backdrop 24 px, 1.8 | chip, 3 | saturation now 1.6 |
| Dialogs: share, delete chat, add account, connect Claude, add project, machines, cloud sheets, models sheet, form dialog, activity viewer (`.ui-dialog.ui-glass`) | transient veil 55% / 42%, 32 px, 1.6 | sheet role | none here (native-shared role, follow-up) |
| Notice, transient error card, cookie import toast | toast veil 55% / 42%, chrome blur | toast role | chrome blur now 1.6 |
| History cookie backups sheet; icon picker pills | bare `.ui-glass` chrome | chrome | 62% / 62%, 1.6 |
| Agent composer card (`composerStates.css`) | popover tint 70% / 50%, 24 px 1.25 (1.8 over art), specular rim, docked: no underlay | popover, hero | 72% / 70%, one saturation |
| Composer strip, queued prompts band, goal strip, pending asks, hat questions, running tray, tray tuck | the composer's stack tint | popover | follow the composer |
| New Tab composer box; legacy new-tab box | popover 70%, 24 px | popover | 72%, 1.6 |
| Session Info (`sessionInfo.css`) | popover 70% / 50%, host glass, page blurs in place | popover | 72%, 1.6 |
| Session Info outputs edges | surface at 58/82/90% with 5/8/12 px | 8 | none (a fade) |
| Summary popover | chrome via `.ui-glass-floats`, page blurs in place | popover | chrome numbers now 62% / 62%, 1.6; level name is a follow-up |
| Workflow side tab; thread minimap card; image viewer; chat gallery | popover 70%, 24 px | popover | 72%, 1.6 |
| PDF viewer, paste view, tool visual card | chrome plus 70% underlay | popover | 62% / 62% over 40% underlay |
| Jump to latest, jump up, since-divider pill, needs-you pill | page background at a private 72% (clear over art), fisheye lens | popover | the popover level (72%) and its blur (the since pill took the chrome blur); the fisheye stays its own mode |
| Selection reply pill | surface at 90%, `blur(6px) saturate(1.4)` | chip, 5 | saturation now the one 1.6; 90% kept (its contrast test) |
| Chief dock rail and cards | text 7-8% over surface at a private 64%, chrome blur | popover | the popover level (72%) and its blur, no text wash, the one edge, the glass's secondary ink |
| Changelog lightbox, Home channels lightbox | surface at 60% / 72% plus chrome blur | scrim | follow-up: the scrim level |
| Files sidebar scrim | 38% black plus `blur(2px)` | scrim | none (allowlisted softening) |
| Diff hunk pill, Stage-all bar | text at 4% plus 20 px blur, underlay | chip | follow-up |

### Floating, native

All on `Glass.makeSurface`, `makeMenuPanel` (menu level plus the theme's veil: 40%, raised in 2% steps to
at most 90% until the theme's primary text reads at 4.5:1 and its secondary at 3:1 over the glass on the
window, on white and on black, rule 5; `GlassMenuMaterial.veil(for:)`) or the neutral transient material.
Icon buttons on that glass (`OverflowButton`, `PlusButton`, `TitlebarBandButton`) fit their glyphs to it
(`NSView.glassInk`), not to the opaque page: they read 1.35-2.84:1 there (NativeControlContrastAuditTests).
SwiftUI on a menu panel is hosted in `ThemedHostingView`: it finds the panel in the view tree as it moves, and its
content's foreground, `.cmuxSecondary` and `.cmuxTertiary` are the theme's text fit to that glass (as
`NSView.buttonGround`), before the first draw (SwiftUI's own `.secondary` is the primary at a lower opacity: 2.00:1). Text, a toggle's label and a button's label that set no ink take them, and a `cmuxPressFill`
button knows the glass; in a plain host it finds the panel itself (`MenuGlassProbeView`), a frame late.
check-overlay-glass.py (`menu-hosting`) refuses a plain `NSHostingView` in a file that builds a menu panel. A web menu's own glass follows the same veil: WebTheme sends `--cmux-menu-clear`
(`GlassMenuMaterial.webClear`), and glass.css lays the menu tint at 100% - (100% - its level tint) × it
(test/menu-glass-veil.test.ts); on the App's glass a web menu is the native panel already. Group editor, tab group editor, palette and its actions menu and
shortcut recorder, `GlassMenu`, web popup host and declarative popups, native tooltip, shortcut hint
chip, hover card panel and rows, native find pill, dialog card, toasts, agent cursor tag
(`.hudWindow`), notifications panel, Downloads, Host Pressure, icon picker, native Session Info
panel, agent-pane host glass under web popups, act-as-me card, permission panel, Quick Composer,
Chief pet bubble, rail and reply, which-key overlay, dictation preview, browser prompt bar, page
unresponsive, link status, cookie import, page info, Extensions menu, verification suggestion,
bookmark edit, Home sheets and pills, Chief settings, update sheet, Share cmux, share invite, cookie
consent, helper drag, add device, remote view surfaces, screen-share approval banner, sidebar
overlay card, drag lift, drop overlays, pane zoom indicator, tab and link drag ghosts, Chief panel.
Before macOS 26 the fallback is `NSVisualEffectView` `.popover` (`.hudWindow` for clear).

### Glass in the content layer

Rule 2 says none of these should be glass. Each is a follow-up of its own, since each changes a
look people see daily:

- User prompt bubble and its edit box (`conversation.css`): text at 10-14%, no blur. Already
  near-solid; no change.
- Table tools pill: text at 8%. No change.
- Reply media glass, play glyphs, video tiles (bare `.ui-glass`): over media, where glass is the
  rule's exception (controls over rich media). No change.
- Now `.ui-glass-content` (near-solid, no blur): permission ask card (`PermissionCard.tsx`), turn
  error card arm (`TurnRows.tsx`), Settings Chief and Chief Pet cards (`ChiefsCard.tsx`,
  `ChiefPetCard.tsx`), changelog media figures (`ReleaseParts.tsx`), cloud progress card
  (`CloudProgressPage.tsx`).
- Onboarding import list and options: the surface at a private 62% with the popover blur, now the
  chrome level (62% / 62%, its 20 px blur). It sits over the wallpaper, not over text, so it stays
  glass; off and Reduce Transparency still turn it solid.
- Left as they are: paste-loading tile, saved environment panel, cloud start sheet arm and the New
  Tab stage hover card (they float or their placement varies), the compare switch and clips (controls
  over media), App scene panel (a native card veil), Chief web's guest composer (a composer).

### Web tint over native glass

1. Sidebar Updated card: the page paints the composer tint and rim over the App's untinted glass
   (`SidebarUpdatedCardHost.swift`, `updateSurfaces.css` `.wn-card.wn-updated`). The fix is native
   (tint the `GlassPanelView`, then drop the page's tint), and it needs a Mac capture: handed off.
2. Agent-pane host glass: the page lays the 40% veil on the App's glass under menus and hover
   cards (`--host-glass-fill`). This is the one deliberate veil (gallery `ui.menu-material`,
   `host-veil`), kept.
3. See-through pages: every web glass lays its tint over the window material, and floating glass
   adds the underlay. This change lowers the underlay to 40% (rule 6).
4. Settings sidebar shade and sidebar web cards: see Window chrome.

## Checks

- `webviews/scripts/check-glass-levels.ts`: every web blur names a level.
- `webviews/scripts/check-glass-never-opaque.ts`: no glass is opaque outside Reduce Transparency.
- `webviews/scripts/check-one-material.ts`, `check-no-nested-glass.ts`, `check-one-stroke.ts`: one
  material per surface, no glass in glass, one stroke (above).
- `gen-design-scale.mjs` refuses a level whose saturation is not the one saturation, a dark tint
  denser than its light one, an underlay over 50%, and a menu level out of step with the transient
  material.
- `webviews/test/glass-levels.test.ts`, `floating-material-sync.test.ts`, `tooltip-surface.test.ts`,
  `chromium-glass-underlay.test.ts`, `see-through-blur.test.ts`, `glass-material.test.ts`.
