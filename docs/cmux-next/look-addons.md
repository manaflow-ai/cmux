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
| The chat's paint | `agent-pane/theme.css` | only the tokens of `cmux.agentPane.style/1` ([below](#the-chat-stylesheet-cmuxagentpanestyle1)), on `:root` | on save |
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
| `--cv-card-fill`, `--cv-card-ring` | every card in the transcript (tool output, code, edited files) and its hairline; unset, each card keeps its own strength |
| `--cv-activity-text` | tool rows, Worked for and other agents' messages (the secondary reading level) |
| `--cv-heading-text` | headings in replies; unset, the body text |
| `--cv-code-fill`, `--cv-code-radius` | inline code's fill and corner (a fenced block is a card) |
| `--cv-card-radius` | every transcript card's corner; unset, each keeps its own |
| `--cv-user-bubble-tint`, `--cv-user-bubble-edge` | the prompt bubble's glass tint and its hairline |
| `--cv-user-bubble-radius` | the prompt bubble's corner |
| `--cv-reply-fill`, `--cv-reply-ring`, `--cv-reply-radius`, `--cv-reply-padding` | the agent's reply as a card: its fill, hairline, corner and room around the text; unset, no card |
| `--cv-hover-duration`, `--cv-hover-ease` | how an icon button's fill and ink, and a tool row's words, change under the pointer; unset, at once |
| `--cv-popover-fill`, `--cv-popover-ring`, `--cv-popover-radius` | the pane's menus, pickers and popovers: their fill over the frost, hairline and corner |
| `--cv-popover-row-selected` | a menu's or picker's highlighted row (pointer or keys) |
| `--cv-code-comment`, `--cv-code-string`, `--cv-code-constant`, `--cv-code-keyword`, `--cv-code-function`, `--cv-code-type` | highlighted code (code blocks, edits, commands); unset, each keeps its terminal palette slot |

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

The reply card keeps that promise too. Its fill is the reply's own row, and `--cv-reply-padding` is
that fill spread outward past the row, with the ring on its outer edge, so the text stays where it
is. Keep the room within the gap between rows (12 px or less), or the card reaches under the row
next to it. `--cv-hover-duration` runs only when motion is on: Reduce Motion, cmux motion off or
reduced, and `ui.animationSpeed` off keep the hover instant whatever the look sets. There is no
press scale: a held button changes only its fill ([design/pressed-state.md](../../design/pressed-state.md)).
Reduce Transparency, Lens and Spectrum keep their own popup fill over `--cv-popover-fill`, and
`appearance.borders: none` and Increase Contrast keep their own popup edge over `--cv-popover-ring`.

```css
:root {
  --cv-reply-fill: color-mix(in srgb, var(--agent-text) 4%, transparent);
  --cv-reply-ring: color-mix(in srgb, var(--agent-text) 14%, transparent);
  --cv-reply-radius: 10px;
  --cv-reply-padding: 10px;
  --cv-hover-duration: 120ms;
  --cv-popover-radius: 12px;
  --cv-popover-row-selected: color-mix(in srgb, var(--agent-accent) 28%, transparent);
  --cv-code-keyword: var(--agent-accent);
}
```

The theme colors (`--agent-text`, `--agent-accent`, `--agent-border` and the rest the host derives
from your theme) are set on the page by cmux itself, so a stylesheet cannot override them. Set those
with the theme file's `colors` and `appearance.surfaces.agentPane`.

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
  the add-on's capture with the built-in one. The chat-pane tokens (reply card, hover timing, popovers,
  code colors) are held the same way on the gallery's `look-tokens-code` state, and the hover timing
  is checked to stay instant under reduced motion.

## Not yet possible from outside

| Part of a look | Why | Where it is going |
| --- | --- | --- |
| The composer's look (Claude or Codex style) | kept in page storage, which a setup cannot set; the composer has no paint tokens | a setting in #43272 or #45843 |
| One switch for a whole transcript preset | no `agentPane.display.transcriptLook` yet | in progress |
| The prompt bubble's width | the height estimate assumes 70%, so a stylesheet width would shift rows | needs a setting the estimate reads |
| Which facts go on which row line | `sidebar.workspaceRow.lines` validates but is not drawn | #42244 |
| Row decorations from an installed look without replacing your own `customize/` | only the `local/customize` app may decorate rows, and a look's `customize/` files replace yours | needs per-look decoration layers |
| The chat's theme colors from `agent-pane/theme.css` | the host sets them inline | the theme file is the place for them |
| A speaker label over the agent's reply ("Claude", "Codex") | the reply draws no label of its own (the row names its speaker to screen readers only), so there is nothing to paint; adding one is new UI that the height estimate would have to count | a follow-up: a label the pane draws, with its own paint tokens |
| Pressing a button smaller | a held button changes only its fill, everywhere (design/pressed-state.md) | not planned |
