# A whole look as an add-on

A look for cmux NEXT (the colors, the chat's type and prompt bubble, the sidebar's rows and hover
card) can be written entirely outside cmux, as one folder you install and remove in one step. This
page shows how, with the two looks in [`examples/looks`](../../examples/looks) as the worked example,
and lists what a look cannot change yet.

## The four parts

A look is a [setup](../../examples/looks/studio/cmux-setup.json) (`cmux-setup.json`) that carries:

| Part | File | What it sets | Reloads |
| --- | --- | --- | --- |
| Color | `themes/NAME.json`, picked by `appearance.themeFile` | the terminal and app colors, the sidebar and chat surfaces, borders, glass, density ([theme-recipes.md](theme-recipes.md)) | on save |
| Type and spacing | `settings` in `cmux-setup.json` | `agentPane.display.font.*`, `agentPane.display.width`, `sidebar.density`, `sidebar.workspaceRow.*` and any other key `cmux settings list` shows as agent-settable | on save |
| The chat's paint | `agent-pane/theme.css` | only the tokens of `cmux.agentPane.style/1` ([below](#the-chat-stylesheet-cmuxagentpanestyle1)), on `:root` | on save |
| The sidebar | `customize/cmux-app.json` and `customize/main.js` | the hover card (`cmux.hovercard/1`) and row decorations (`cmux.sidebar.rows/1`), [sidebar-customization.md](sidebar-customization.md) | on save |

Install one from its repo with `cmux setup install HOST/OWNER/REPO[/PATH][@REF]` (a look in this repo: `github.com/manaflow-ai/cmux/examples/looks/studio@feat-cmux-next`), take it off with `cmux setup remove ID`. It is
one library layer: your own settings stay, and removing it puts back exactly what was there.

## The chat stylesheet: `cmux.agentPane.style/1`

`agent-pane/theme.css` is applied after the chat's own stylesheets. Class names are not public and
change often, so a look sets only these custom properties, on `:root`
([`schemas/agent-pane/style-tokens.json`](../../schemas/agent-pane/style-tokens.json) is the source):

| Token | What it paints |
| --- | --- |
| `--cv-text`, `--cv-text-muted`, `--cv-text-dim` | body, secondary and quietest transcript text |
| `--cv-link`, `--agent-link` | links in replies, and in the rest of the pane |
| `--cv-card-fill`, `--cv-card-ring` | cards in the transcript (tool output, code, edited files) and their hairline |
| `--cv-user-bubble-tint`, `--cv-user-bubble-edge` | the prompt bubble's glass tint and its hairline |
| `--cv-user-bubble-radius` | the prompt bubble's corner |

```css
:root {
  --cv-user-bubble-tint: color-mix(in srgb, var(--agent-text) 8%, transparent);
  --cv-user-bubble-edge: color-mix(in srgb, var(--agent-text) 22%, transparent);
  --cv-user-bubble-radius: 8px;
}
```

A token's color is built from the theme's own colors, never written out: `var(--agent-text)`,
`--agent-muted`, `--agent-soft`, `--agent-accent`, `--agent-page-bg` and the others the contract's
`reads` lists, mixed with `color-mix()` and `transparent`. cmux sets them for the appearance the
window shows, so one stylesheet reads in light and in dark. A fixed color (`#93c5fd`, `rgb(...)`,
`red`) is right in one appearance and unreadable in the other, and the check refuses it. Give the
look its own colors in the theme file instead: `"appearance.theme": "light:A,dark:B"` with
`"appearance.themeEdits": { "A/background": "#...", "B/background": "#..." }` for each side.

Every token is paint: it never changes a box, so a look applied, saved again or switched never moves
the transcript. Type, width and spacing are settings instead, because the chat estimates row heights
from them before it draws; a stylesheet that set a font size would make rows jump as they are
measured.

The theme colors (`--agent-text`, `--agent-accent`, `--agent-border` and the rest the host derives
from your theme) are set on the page by cmux itself, so a stylesheet cannot override them. Set those
with the theme file's `colors` and `appearance.surfaces.agentPane`.

## What keeps this true

- `cmux-customize` `tests/example_looks.rs` installs every look in `examples/looks` on a fresh machine
  with the same reader `cmux setup install` uses, and fails on any dropped key or problem.
- webviews `bun run check:look-addons` fails when a look styles a class or sets anything outside the
  contract, when a contract token stops working from `:root`, and when a built-in look has no add-on
  twin listed in `examples/looks/looks.json`.
- webviews `bun run check:look-addons` also refuses a fixed color in a look's stylesheet.
- webviews `test/browser/look-addons.test.ts` sends each look to the real chat through the host's own
  path, checks every token lands, and fails if applying, reloading or switching looks moves any box.
  It also draws each look on its own theme colors in light and in dark and fails when any text token
  (body, muted, dim, links, code, the prompt) reads under 4.5:1 on what it sits on (WCAG 2.2 1.4.3).
  A theme file takes the window too (`"appearance.appTheme": "followTerminal"`): without it, a person's
  own App Theme keeps the window, sidebar and pages in its colors.
  When a built-in preset exists, it also compares the add-on's capture with the built-in one.

## Not yet possible from outside

| Part of a look | Why | Where it is going |
| --- | --- | --- |
| The composer's look (Claude or Codex style) | kept in page storage, which a setup cannot set; the composer has no paint tokens | a setting in #43272 or #45843 |
| One switch for a whole transcript preset | no `agentPane.display.transcriptLook` yet | in progress |
| The prompt bubble's width | the height estimate assumes 70%, so a stylesheet width would shift rows | needs a setting the estimate reads |
| Which facts go on which row line | `sidebar.workspaceRow.lines` validates but is not drawn | #42244 |
| Row decorations from an installed look without replacing your own `customize/` | only the `local/customize` app may decorate rows, and a look's `customize/` files replace yours | needs per-look decoration layers |
| The chat's theme colors from `agent-pane/theme.css` | the host sets them inline | the theme file is the place for them |
