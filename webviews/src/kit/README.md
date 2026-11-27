# Instrument 0.1.0: the UI base for customizations

Instrument is cmux's web component kit, at version `0.1.0` (`INSTRUMENT_VERSION` in `version.ts`; every
version is in `CHANGELOG.md`). 0.1.0 is the look the app draws today: every piece is the app's own
component or a thin one over the app's own classes, so nothing here looks new.

The pieces a customization page, a plugin or a web page composes instead of hand-rolled views.
Built from them, a page follows the active theme in light and dark, the density and the design
scale the app uses, and gets the app's menus, popovers and focus behavior.

Import from `kit/index.ts` only; the files behind it may move.

| Piece                            | What it is                                                                                                                                                                               |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Row`                            | One list row: leading mark, title, optional second line, trailing column. With `onSelect` the whole row is the open target. `compact` 28, `comfortable` 32.                              |
| `List`                           | Rows under an optional section title, with an empty state. An empty list with no `empty` renders nothing.                                                                                |
| `Button`                         | `ui/Button`: `ghost`, `subtle`, `solid`; `sm`, `md`, `lg`; `icon`; `danger`.                                                                                                             |
| `Glass`                          | A region on cmux's glass at a level: `chrome`, `popover` (default), `menu`, `chip`. Paint only, so adding it moves nothing; a customize scene node's `.glass(level)` is the native twin. |
| `GlassMenu`                      | A menu from data (`items`: icon, shortcut, danger, separator) on the one floating material, with `ui/Menu`'s press-drag-release.                                                         |
| `Tooltip`, `TooltipProvider`     | `ui/Tooltip`: the compact hover tip (label, detail line, shortcut keycap); the provider gives a page AppKit's hover delay and warm group.                                                |
| `Menu` and its rows              | `ui/Menu`: `Menu`, `MenuButton`, `MenuPopup`, `MenuItem`, `MenuCheckboxItem`, `MenuRadioGroup`, `MenuRadioItem`, `MenuGroup`, `MenuSeparator`, `Submenu`.                                |
| `Card`                           | `ui/Tooltip`'s `AnchoredCard` under a shorter name: the glass hover card (a link's, a pull request's), anchored to an element the caller holds, opened and closed by the caller.         |
| `Panel`                          | `ui/surface/Surface` under another name: the one surface every card, sheet and ask card draws, with its slots `Panel.Header`, `.Body`, `.Inset`, `.Actions`, `.Trailing`, `.Action`.     |
| Motion                           | `motion(step)`, `MOTION` and `EASE_STANDARD` for CSS; `motionToken`, `warmMotionTokens` to read a resolved token; `motionMode`, `springEasing` for how much may move now.                |
| `PopoverButton`, `Popover`       | A button that opens a popover under it; `ui/Popover` for any other anchor.                                                                                                               |
| `Field`, `Input`                 | A labelled field with a hint or an error; `ui/Input` alone.                                                                                                                              |
| `Pill`                           | A capsule: `neutral`, `accent`, `success`, `attention`, `danger`; `sm` 20, `md` 24.                                                                                                      |
| `Avatar`                         | A picture or initials on a neutral tile; people round, agents square.                                                                                                                    |
| `Icon`, `StatusGlyph`, `Spinner` | cmux's icon pack, the static status marks, the working spinner.                                                                                                                          |
| Tokens                           | `color("muted")`, `space("2")`, `control("row")`, `icon("16")`, `radius("md")`, `text("caption")`, `motion("quick")`: `var()`s of the one generated token list.                          |
| `SessionList`, `MinimalSessions` | A session list styled by the sidebar's theme-file keys (`sessionLook`); `MinimalSessions` is cmux#45143's minimal look.                                                                  |

## Examples

```tsx
import {
  Button, Card, Menu, MenuButton, MenuItem, MenuPopup, Panel, Pill, Row, Glass, Tooltip, TooltipProvider,
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
- Raw values (a pixel size, a hex colour, a duration) still compile outside the closed directories, but
  they are discouraged: use a token, and if no token fits, ask for one here.

Gallery: `kit.primitives` (`kit.gallery.tsx`) shows every piece in a light and a dark panel
(`primitives`, and `pieces` for Tooltip, Menu, Card, Panel and motion), and the session looks.
