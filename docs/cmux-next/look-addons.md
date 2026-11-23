# A whole look as an add-on

A look for cmux NEXT (the colors, the chat's type and prompt bubble, the sidebar's rows and hover
card) can be written entirely outside cmux, as one folder you install and remove in one step. This
page shows how, with the two looks [Studio](https://github.com/manaflow-ai/cmux-studio-look) and [Paper](https://github.com/manaflow-ai/cmux-paper-look) as the worked example,
and lists what a look cannot change yet.

## The four parts

A look is a [setup](../../examples/looks/studio/cmux-setup.json) (`cmux-setup.json`) that carries:

| Part | File | What it sets | Reloads |
| --- | --- | --- | --- |
| Color | `themes/NAME.json`, picked by `appearance.themeFile` | the terminal and app colors, the sidebar and chat surfaces, borders, glass, density ([theme-recipes.md](theme-recipes.md)) | on save |
| Type and spacing | `settings` in `cmux-setup.json` | `agentPane.display.font.*`, `agentPane.display.width`, `sidebar.density`, `sidebar.workspaceRow.*` and any other key `cmux settings list` shows as agent-settable | on save |
| The chat's paint | `agent-pane/theme.css` | a shared look: only the tokens of `cmux.agentPane.style/1` ([below](#the-chat-stylesheet-cmuxagentpanestyle1)), on `:root`; your own: [any CSS](#your-own-stylesheet-any-css-loading-nothing) | on save |
| The sidebar | `customize/cmux-app.json` and `customize/main.js` | the hover card (`cmux.hovercard/1`) and row decorations (`cmux.sidebar.rows/1`), [sidebar-customization.md](sidebar-customization.md) | on save |

Install one from its repo with `cmux setup install HOST/OWNER/REPO[/PATH][@REF]` (a look is a small repo of its own, like dotfiles: `cmux setup install github.com/manaflow-ai/cmux-studio-look`), take it off with `cmux setup remove ID`. It is
one library layer: your own settings stay, and removing it puts back exactly what was there.

## The chat stylesheet: `cmux.agentPane.style/1`

`agent-pane/theme.css` is applied after the chat's own stylesheets. Class names are not public and
change often, so a look sets only these custom properties, on `:root`
([`schemas/agent-pane/style-tokens.json`](../../schemas/agent-pane/style-tokens.json) is the source):

| Token | What it paints |
| --- | --- |
| `--cv-text`, `--cv-text-muted`, `--cv-text-dim` | body, secondary and quietest transcript text |
| `--cv-link`, `--agent-link` | links in replies, and in the rest of the pane |
| `--cv-card-fill`, `--cv-card-ring` | the card level and its hairline: tool output, edit, error and permission cards, plans, the subagent card (code blocks keep their own fill); unset, the theme's text at 4% and 10% |
| `--cv-user-bubble-tint`, `--cv-user-bubble-edge` | the prompt bubble's glass tint and its hairline |
| `--cv-user-bubble-radius` | the prompt bubble's corner |
| `--cv-code-edge-fade` | how far a long code line fades at the card's right edge while more lies past; unset, a hard edge |

```css
:root {
  --cv-user-bubble-tint: color-mix(in srgb, var(--agent-text) 12%, transparent);
  --cv-user-bubble-edge: color-mix(in srgb, var(--agent-text) 18%, transparent);
  --cv-user-bubble-radius: 8px;
  --cv-card-fill: color-mix(in srgb, var(--agent-accent) 7%, transparent);
}
```

Make every color from the theme's own (`var(--agent-text)`, `var(--agent-accent)`, `var(--agent-page-bg)`,
mixed with `color-mix()`), never a literal: the person may run the look's stylesheet over a light
theme or a dark one, and a literal is right for one of them only. Studio 1.0.0's `rgb(39 39 42 /
0.72)` bubble put black text on mid-grey (2.9:1) over a light theme, and Paper 1.0.0's beige put
white text on it (1.4:1) over a dark one. Literal colors belong in the theme file.

Every token is paint: it never changes a box, so a look applied, saved again or switched never moves
the transcript. Type, width and spacing are settings instead, because the chat estimates row heights
from them before it draws; a stylesheet that set a font size would make rows jump as they are
measured.

The theme colors (`--agent-text`, `--agent-accent`, `--agent-border` and the rest the host derives
from your theme) are set on the page by cmux itself, so a stylesheet cannot override them. Set those
with the theme file's `colors` and `appearance.surfaces.agentPane`.

## Your own stylesheet: any CSS, loading nothing

Your own `agent-pane/theme.css` (and `markdown/theme.css`, `editor/theme.css`) takes any CSS, any
selector, applied after the surface's built-in styles and kept last in the page, so it wins at equal
specificity. Class names still change between releases, so a look you share keeps to the tokens
above; your own file may style anything.

What it may not do is load something by address (`cmux.stylesheetGuard/1`,
[`schemas/agent-pane/stylesheet-guard.json`](../../schemas/agent-pane/stylesheet-guard.json)): no
`@import`, no `url()` other than a `data:` URL, no `image-set()` or `src()`, and no backslash escape
that could spell one. Comments are no way around it. The chat refuses such a sheet whole and keeps the
last good one on screen (its `<style id="acpmux-user-theme">` carries `data-refused` with the reason),
and `cmux customize validate` names the file and the reason before you apply. Inline an image as a
`data:` URL instead.

## What keeps this true

- `cmux-customize` `tests/example_looks.rs` installs every look in `examples/looks` on a fresh machine
  with the same reader `cmux setup install` uses, and fails on any dropped key or problem.
- webviews `bun run check:look-addons` fails when a look styles a class or sets anything outside the
  contract, when it sets a color token to a literal color instead of one made from the theme's, when
  a contract token stops working from `:root`, and when a built-in look has no add-on twin listed in
  `examples/looks/looks.json`.
- webviews `test/browser/look-addons.test.ts` sends each look to the real chat through the host's own
  path, checks every token lands, and fails if applying, reloading or switching looks moves any box.
  It also holds every drawn line of text to WCAG AA contrast (4.5:1, 3:1 for large text) over the
  fills under it, in a light theme and a dark one: a look may not take a line under the minimum, nor
  lower one the plain chat already draws under it. When a built-in preset exists, it also compares
  the add-on's capture with the built-in one.

## Not yet possible from outside

| Part of a look | Why | Where it is going |
| --- | --- | --- |
| The composer's look (Claude or Codex style) | kept in page storage, which a setup cannot set; the composer has no paint tokens | a setting in #43272 or #45843 |
| One switch for a whole transcript preset | no `agentPane.display.transcriptLook` yet | in progress |
| The prompt bubble's width | the height estimate assumes 70%, so a stylesheet width would shift rows | needs a setting the estimate reads |
| Which facts go on which row line | `sidebar.workspaceRow.lines` validates but is not drawn | #42244 |
| Row decorations from an installed look without replacing your own `customize/` | only the `local/customize` app may decorate rows, and a look's `customize/` files replace yours | needs per-look decoration layers |
| The chat's theme colors from `agent-pane/theme.css` | the host sets them inline | the theme file is the place for them |
