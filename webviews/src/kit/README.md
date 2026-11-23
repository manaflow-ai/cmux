# kit: the UI base for customizations

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
| `PopoverButton`, `Popover`       | A button that opens a popover under it; `ui/Popover` for any other anchor.                                                                                                               |
| `Field`, `Input`                 | A labelled field with a hint or an error; `ui/Input` alone.                                                                                                                              |
| `Pill`                           | A capsule: `neutral`, `accent`, `success`, `attention`, `danger`; `sm` 20, `md` 24.                                                                                                      |
| `Avatar`                         | A picture or initials on a neutral tile; people round, agents square.                                                                                                                    |
| `Icon`, `StatusGlyph`, `Spinner` | cmux's icon pack, the static status marks, the working spinner.                                                                                                                          |
| Tokens                           | `color("muted")`, `space("2")`, `control("row")`, `icon("16")`, `radius("md")`, `text("caption")`, `motion("quick")`: `var()`s of the one generated token list.                          |
| `SessionList`, `MinimalSessions` | A session list styled by the sidebar's theme-file keys (`sessionLook`); `MinimalSessions` is cmux#45143's minimal look.                                                                  |

Rules for pages built on the kit:

- Color comes from the theme. Use the tokens or the `--cmux-*` variables, never a literal color.
- Don't restyle `.kit-*` or `.ui-*` classes. If a page needs a variant, add it here.
- Visible text comes from the caller, in the page's language. The kit holds no strings.

Gallery: `kit.primitives` (`kit.gallery.tsx`) shows every piece in a light and a dark panel, and
the session looks.
