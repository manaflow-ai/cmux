# Instrument 0.1.0: the UI base for customizations

Instrument is cmux's web component kit, at version `0.1.0` (`INSTRUMENT_VERSION` in `version.ts`; every
version is in `CHANGELOG.md`). 0.1.0 is the look the app draws today: every piece is the app's own
component or a thin one over the app's own classes, so nothing here looks new.

In cmux webviews, import the components from `kit/index.ts`. They follow the active theme, density
and design scale, and provide the app’s menus, popovers and focus behavior. For an installed
sidebar customization or extension, use the [scene API for that host](#which-kit-do-i-use).

The installed CLI includes the web component registry. Run `cmux customize components show Row`
to see its props, or `cmux customize components test Button '{"size":"sm","variant":"subtle"}'`
to check prop names before writing a view. Run `cmux customize tokens test 8 --as spacing` to
look up a value on the design scale. The same queries are available through the
`customize_components` and `customize_tokens` MCP tools.

Import from `kit/index.ts` only; the files behind it may move. Every export is ready, experimental or
deprecated, with the promises in [ui/STATUS.md](../ui/STATUS.md).

| Piece                            | What it is                                                                                                                                                                                    |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Row`                            | One list row: leading mark, title, optional second line, trailing column. With `onSelect` the whole row is the open target. `compact` 28, `comfortable` 32.                                   |
| `List`                           | Rows under an optional section title, with an empty state. An empty list with no `empty` renders nothing.                                                                                     |
| `Button`                         | `ui/Button`: `ghost`, `subtle`, `solid`; `sm`, `md`, `lg`; `icon`; `danger`.                                                                                                                  |
| `Glass`                          | A region on cmux's glass at a level: `chrome`, `popover` (default), `menu`, `chip`. Paint only, so adding it moves nothing; a customize scene node's `.glass(level)` is the native twin.      |
| `GlassMenu`                      | A menu from data (`items`: icon, shortcut, danger, separator) on the one floating material, with `ui/Menu`'s press-drag-release.                                                              |
| `Tooltip`, `TooltipProvider`     | `ui/Tooltip`: the compact hover tip (label, detail line, shortcut keycap); the provider gives a page AppKit's hover delay and warm group.                                                     |
| `Menu` and its rows              | `ui/Menu`: `Menu`, `MenuButton`, `MenuPopup`, `MenuItem`, `MenuCheckboxItem`, `MenuRadioGroup`, `MenuRadioItem`, `MenuGroup`, `MenuSeparator`, `Submenu`.                                     |
| `Card`                           | `ui/Tooltip`'s `AnchoredCard` under a shorter name: the glass hover card (a link's, a pull request's), anchored to an element the caller holds, opened and closed by the caller.              |
| `Panel`                          | `ui/surface/Surface` under another name: the one surface every card, sheet and ask card draws, with its slots `Panel.Header`, `.Body`, `.Inset`, `.Actions`, `.Trailing`, `.Action`, `.Keys`. |
| Motion                           | `motion(step)`, `MOTION` and `EASE_STANDARD` for CSS; `motionToken`, `warmMotionTokens` to read a resolved token; `motionMode`, `springEasing` for how much may move now.                     |
| `PopoverButton`, `Popover`       | A button that opens a popover under it; `ui/Popover` for any other anchor.                                                                                                                    |
| `Field`, `Input`                 | A labelled field with a hint or an error; `ui/Input` alone.                                                                                                                                   |
| `Pill`                           | A capsule: `neutral`, `accent`, `success`, `attention`, `danger`; `xs` 16, `sm` 20, `md` 24.                                                                                                  |
| `Avatar`                         | A picture or initials on a neutral tile; people round, agents square.                                                                                                                         |
| `Icon`, `StatusGlyph`, `Spinner` | cmux's icon pack, the static status marks, the working spinner.                                                                                                                               |
| Tokens                           | `color("muted")`, `space("2")`, `control("row")`, `icon("16")`, `radius("md")`, `text("caption")`, `motion("quick")`: `var()`s of the one generated token list.                               |
| `SessionList`, `MinimalSessions` | A session list styled by the sidebar's theme-file keys (`sessionLook`); `MinimalSessions` is cmux#45143's minimal look.                                                                       |

## Props

These tables cover common props from the component definitions (`Row.tsx`, `List.tsx`, `ui/Tooltip.tsx`, `ui/Menu.tsx`,
`ui/surface/Surface.tsx`, `ui/Button.tsx`, `agent-session/acpmux/icons/Icon.tsx`). For host-specific options see [Variants for scene parity](#variants-for-scene-parity).

`Row`

| Prop           | Type                         | Default     | What it does                                                                |
| -------------- | ---------------------------- | ----------- | --------------------------------------------------------------------------- |
| `title`        | node, required               |             | The row's text.                                                             |
| `subtitle`     | node                         |             | A second line in the secondary color.                                       |
| `leading`      | node                         |             | The leading column: an `Icon`, a `StatusGlyph`, a `Spinner` or an `Avatar`. |
| `trailing`     | node                         |             | Always-visible content such as a `Pill` or a count.                         |
| `hoverActions` | node                         |             | Secondary controls shown on hover or keyboard focus, and always on touch.   |
| `selected`     | boolean                      | `false`     | The selection fill and `aria-current`.                                      |
| `density`      | `"compact"`, `"comfortable"` | `"compact"` | 28 or 32 tall.                                                              |
| `label`        | string                       |             | What assistive tech reads for the whole row.                                |
| `onSelect`     | `() => void`                 |             | Makes the whole row one button; without it the row is static.               |

`List`

| Prop       | Type   | What it does                                                                              |
| ---------- | ------ | ----------------------------------------------------------------------------------------- |
| `title`    | node   | The section title above the rows; it also names the list.                                 |
| `label`    | string | The accessible name when there is no visible title.                                       |
| `empty`    | node   | Shown in place of the rows when there are none. Without it an empty list renders nothing. |
| `children` | `Row`s | The rows.                                                                                 |

`Tooltip`

| Prop       | Type                  | Default    | What it does                                                                                 |
| ---------- | --------------------- | ---------- | -------------------------------------------------------------------------------------------- |
| `label`    | node, required        |            | The tip's text.                                                                              |
| `detail`   | node                  |            | A dimmer second line.                                                                        |
| `shortcut` | string                |            | A keycap after the label (`"⌘T"`).                                                           |
| `side`     | `"top"`, `"bottom"`   | `"bottom"` | Where it sits; it flips at the edge.                                                         |
| `anchor`   | string (a selector)   |            | An element inside the control the tip sits at, when the control is wider than what it names. |
| `disabled` | boolean               |            | Shows nothing while set; the control stays mounted.                                          |
| `children` | one element, required |            | The control it describes.                                                                    |

`MenuItem`

| Prop       | Type              | What it does                                                                                               |
| ---------- | ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `children` | node, required    | The row's title.                                                                                           |
| `subtitle` | node              | A quieter second line under the title.                                                                     |
| `shortcut` | node              | The shortcut at the trailing edge.                                                                         |
| `disabled` | boolean           | The row cannot be chosen.                                                                                  |
| `reason`   | string            | Why a disabled row is disabled, one line under its label; drawn only under the menu-row-states experiment. |
| `onSelect` | `(event) => void` | Runs when the row is chosen.                                                                               |

`Panel` (`Surface`)

| Prop        | Values                                                                                                          | What it does                                                                    |
| ----------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `role`      | `"ask"`, `"card"`, `"popover"`, `"menu"`, `"hoverCard"`, `"tooltip"`, `"toast"`, `"sheet"`, `"pill"` (required) | Which surface it is; the role picks its material (window, floating or content). |
| `tone`      | `"neutral"`, `"attention"`, `"danger"`                                                                          | Changes ink only (the header's icon).                                           |
| `as`        | `"div"` (default), `"fieldset"`, `"section"`, `"article"`, `"aside"`, `"form"`, `"pre"`, `"p"`                  | The one element it renders.                                                     |
| `hostGlass` | `"popover"`, `"menu"`, `"chip"`                                                                                 | A floating surface the app draws its glass under.                               |

Slots: `Panel.Header` (`icon`, `trailing`, `titleId`, children the title), `Panel.Body`,
`Panel.Inset` (`mono`, `scroll`), `Panel.Actions`, `Panel.Trailing` (the primary group of an actions
row), `Panel.Action` (`kind`: `"primary"` or `"secondary"`, the default; it is a `Button` at `md`) and
`Panel.Keys` (the keycap hint after an action's label).

`role` is the surface's name, not an ARIA role, and `<Panel role="card">` trips oxlint's
`jsx-a11y(aria-role)` rule ("`card` is an invalid aria role"); `webviews` denies warnings, so the check
fails. The prop keeps its name; put the comment the repo already uses on the line above:
`{/* oxlint-disable-next-line jsx-a11y/aria-role -- the Panel (Surface) role, not an ARIA role */}`.

`Button`

| Prop      | Values                                                                | Default    |
| --------- | --------------------------------------------------------------------- | ---------- |
| `variant` | `"ghost"`, `"subtle"`, `"solid"`                                      | `"subtle"` |
| `size`    | `"sm"` 24, `"md"` 28, `"lg"` 32                                       | `"md"`     |
| `icon`    | boolean: square, icon-only; give it an `aria-label`                   | `false`    |
| `danger`  | boolean: the danger role for its text (ghost, subtle) or fill (solid) | `false`    |

`Icon`

| Prop       | Type    | Default | What it does                                                                      |
| ---------- | ------- | ------- | --------------------------------------------------------------------------------- |
| `name`     | string  |         | An icon name from the pack (below).                                               |
| `size`     | number  | `16`    | Width and height in px; never under 12. The scale is 12, 14, 16, 20.              |
| `selected` | boolean | `false` | Draws the Solid form.                                                             |
| `row`      | boolean | `false` | Crops the grid margin so the icon sits on a label line.                           |
| `fit`      | boolean | `false` | With `row`, centres the glyph's ink in one shared box (a column of mixed glyphs). |
| `title`    | string  |         | Makes it an image with that name; without it the icon is decorative.              |
| `color`    | string  |         | Replaces the text color.                                                          |

Icon names are the keys of `icons` in
[`agent-session/acpmux/icons/cmuxIcons.json`](../agent-session/acpmux/icons/cmuxIcons.json) (dotted, as
`terminal`, `action.edit`, `action.pin`, `file.text`); `iconCatalog.json` beside it lists each with its
meaning. Both are generated by `scripts/icons/build_pack.py` from `design/icons/source/`. An unknown
name logs a warning and draws the pack's `icon.missing`.

## Examples

```tsx
import {
  Button, Card, Icon, Menu, MenuButton, MenuItem, MenuPopup, Panel, Pill, Row, Glass, Tooltip, TooltipProvider,
  EASE_STANDARD, motion, motionMode,
} from "../kit";

<Button variant="solid" onClick={save}>Save</Button>

<Card anchor={linkElement} ariaLabel={title}>{preview}</Card>

<Pill tone="success" size="sm">Merged</Pill>

<TooltipProvider>
  <Tooltip label={forkLabel} detail={forkDetail} shortcut="⌘D">
    <Button size="sm">{forkWord}</Button>
  </Tooltip>
</TooltipProvider>

<Menu>
  <MenuButton label={actionsLabel}>{actionsWord}</MenuButton>
  <MenuPopup label={actionsLabel}>
    <MenuItem shortcut="⌘R" onSelect={rename}>{renameWord}</MenuItem>
  </MenuPopup>
</Menu>

<Row title={name} subtitle={branch} leading={<Icon name="terminal" size={16} row />} onSelect={open} />

{/* oxlint-disable-next-line jsx-a11y/aria-role -- Panel uses role to choose its surface */}
<Panel role="card">
  <Panel.Header icon={<Icon name="terminal" size={16} />}>{title}</Panel.Header>
  <Panel.Body>{detail}</Panel.Body>
  <Panel.Actions><Panel.Action kind="primary" onClick={allow}>{allowWord}</Panel.Action></Panel.Actions>
</Panel>

<Glass level="popover">{content}</Glass>

const fade = { transition: `opacity ${motion("micro")} ${EASE_STANDARD}` };
const moves = motionMode(document, node) === "full";
```

Rules for pages built on the kit:

- Color comes from the theme. Use the tokens or the `--cmux-*` variables, never a literal color.
- Don't restyle `.kit-*` or `.ui-*` classes. If a page needs a variant, add it here.
- Visible text comes from the caller, in the page's language. The kit holds no strings.
- Use `space()` for spacing that follows page density. For existing fixed-pixel layouts, run `python3 webviews/scripts/pages/migrate-ds-spacing.py --write` from the repository root. It uses the fixed Instrument scale for margins, padding and gaps. Declarations with off-scale values and custom-property fallbacks keep their original geometry. Run with `--check` to list whether any eligible declarations remain.
- Raw values (a pixel size, a hex colour, a duration) still compile outside the closed directories, but
  they are discouraged: use a token, and if no token fits, ask for one here.

## Variants for scene parity

Each is off unless asked for; without it a piece renders the markup it always did (`variants.test.tsx`).
They let a host that keeps its own sheet (the customize scene renderer) draw with the kit at its
current values. Gallery: `kit.primitives` `scene-parity`.

| Piece    | Prop or name                         | What it does                                                                                                                                                                                                                                        |
| -------- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Button` | `bare`                               | Only the caller's `className`: no `ui-button ui-btn`, no `data-variant`/`data-size`. Base UI's behavior stays.                                                                                                                                      |
| `Row`    | `ref`                                | The row element: the `button` with `onSelect`, else the static `div`.                                                                                                                                                                               |
| `Row`    | any other attribute or handler       | Goes onto the row element (`draggable`, `onDragStart`, `data-*`). `onSelect` stays the click; `label` wins `aria-label`.                                                                                                                            |
| `Row`    | `subtitleSize`                       | `caption` (default) or `detail` (`--text-detail`), the scene's second line.                                                                                                                                                                         |
| `Row`    | `--kit-row-selected-fill`            | Set on the row (its own class) to give the selection the host's fill; unset, `--ds-color-selection`.                                                                                                                                                |
| `Pill`   | `size="xs"`                          | The scene badge: min-height `--grid-icon-box` (16), padding `--grid-base`, `--text-detail`, neutral fill `currentColor` 14%.                                                                                                                        |
| `Pill`   | `--kit-pill-radius`                  | xs only: the corner; default `--ds-radius-full`, and any class of the host's sets it.                                                                                                                                                               |
| Tokens   | `grid(name)`, `GRID`                 | The layout grid's `--grid-*` (base, half-step, gap, glyph, icon-box, pill, pill-inset, row, and comfortables), at the current interface scale. The `space()` steps also respond to page density in Settings and on pages using `data-page-density`. |
| Tokens   | `--ds-radius-full`, `radius("full")` | 999px: a capsule at any height. Tailwind's own `rounded-full` is left as it is.                                                                                                                                                                     |

## Gallery

`kit.primitives` (`kit.gallery.tsx`, "Kit: UI base for customizations" under UI primitives) shows every
piece in a light and a dark panel (`primitives`, and `pieces` for Tooltip, Menu, Card, Panel and
motion), and the session looks. To open it, from `webviews`: `bun run gallery:dev`, then
`http://127.0.0.1:4210/gallery/` and pick the entry, or
`http://127.0.0.1:4210/gallery/frame.html?entry=kit.primitives` for the entry alone. Other ways to see
it (a static build, the live tailnet gallery) are in
[`gallery/ENTRIES.md`](../gallery/ENTRIES.md#seeing-it).

To capture the controls, surfaces, motion presets and open cards in both themes, run this from
`webviews/` in a checkout with the gallery’s Playwright browser installed:

```sh
CMUX_CAPTURE_BUILD=1 bun scripts/gallery/capture-states.mjs scripts/gallery/kit.capture.json /tmp/cmux-kit-gallery
```

## Related

- Glass: [`docs/cmux-next/glass.md`](../../../docs/cmux-next/glass.md), the levels and how `Glass` and a
  customize scene node's `.glass(level)` match.
- Icons: [`agent-session/acpmux/icons/README.md`](../agent-session/acpmux/icons/README.md).

### Swift counterpart

Native surfaces use the same Instrument roles and tokens through `CmuxNextDesign`:
`CardSurfaceView` is the shared card glass, `CardMaterial` resolves a theme's card fill and rim,
and `HoverCardStyle.shared` supplies the card's padding, spacing, radius, type and ink. A caller
supplies content through `HoverCardBody` and registers its `HoverCardSource` with the shared
`HoverCardCoordinator`.

```swift
let style = HoverCardStyle.shared
let body = HoverCardBody(view: preview, placement: .below, themeAnchor: anchor,
                         cornerRadius: style.cornerRadius) {}
coordinator.presentOwned(targetID, body: body, anchor: targetFrame, parent: window, ended: {})
```

The app-owned `HoverCardPanel` remains the coordinator's renderer. Customizations provide a body
and read the shared style instead of creating another floating panel or choosing a new material.

### Which kit do I use

Choose the API for the host that will render the view:

- Instrument (this): React, for web code inside this repo's `webviews/` (pages, panes, the gallery).
  It is imported by relative path (`../kit`); it is not published as a package.
- The scene globals (`VStack`, `Row`, `Panel`, `Button`, `EmptyState`, ...) for
  `customize/main.js` in the active cmux configuration folder:
  [`skills/cmux-customization/SKILL.md`](../../../skills/cmux-customization/SKILL.md), "Make a view".
- `cmux-extension-sdk`, for extensions (`cmux ext new`): its scene DSL and widget helpers,
  [`cmux-tui/crates/cmux-extension-sdk/README.md`](../../../cmux-tui/crates/cmux-extension-sdk/README.md).

In a scene, the constructors and modifiers compose directly. This view uses the renderer’s
standard panel, row, button, menu, glass material and motion preset:

```js
Panel({ title: "Focus" }, [
  Row({ title: "Focus timer", subtitle: "Ready" }),
  Button("Start", start).help("Start the timer"),
  Menu("Presets", [Button("20 minutes", () => setMinutes(20))]),
])
  .glass("chrome")
  .animation("smooth");
```

Use `Badge(text, tone)` for a scene status mark and `.help(text)` for a text tip. The web
gallery also shows an anchored hover card, pill sizes, and a tooltip with detail and a
shortcut. Those options are available on the web components.

From an extension folder, run `cmux ext dev --once --json`. The `scene` field shows what
rendered. The `design` findings flag raw hex colors and spacing or type sizes outside the
folder’s design scale. These warnings let the view render while you compare it with the gallery.

For a local view, `cmux customize status` reports literal hex colors passed directly to scene
modifiers such as `.foregroundColor("#666666")`. Use a theme color such as `"secondary"` to
follow the active appearance. A draft with a literal color can still be applied.

Start with the [focus timer example](../../../skills/cmux-customization/references/local-app-views.md#template-a-focus-timer).
Use the gallery above as a visual reference. A prompt for an agent:

> Build a sidebar focus timer from the scene globals in the focus timer example. Start at 20 minutes
> and offer 10, 20 and 40 minute presets. Use the existing Panel, Row and Button styles and theme
> tones. Match the light and dark gallery examples. Show the countdown after Start and the reset
> after Stop.
