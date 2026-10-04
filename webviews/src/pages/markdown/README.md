# Markdown editor page

The cmux-next markdown page (`cmux-page://cmux.markdown/`, entry `webviews/markdown-page.html`) opens a markdown file as an editor: rich text (Milkdown, ProseMirror with remark) by default, with a source mode. Dev: `bun run dev`, then `/markdown?file=<path>`.

## Saving never rewrites what you did not edit

A save is a minimal-change write (`sourceMap.ts`). The editor keeps each top-level block's exact source; a block the user did not change is written back byte for byte, and only edited blocks go through the serializer. Front matter, link definitions and HTML blocks are raw blocks kept verbatim; reference links stay references when their paragraph is edited. `test/markdown-roundtrip.test.ts` loads a corpus of real repo files into the real editor and fails on any change without an edit. Stock Milkdown serialization kept 2 of the 35 real files.

## Host contract

`host.ts` lists the ops and streams the native host (diff-host.md S6) implements: `cmux.markdown.config`, `cmux.markdown.save {path, text, baseHash}` (refused with `cmux.markdown.conflict` on a hash mismatch), `cmux.markdown.load`, `cmux.markdown.openLink`, `cmux.markdown.resolveLinks`, `cmux.markdown.listFiles`, the page commands `save`, `back`, `forward` and `link`, the streams `cmux.markdown.changes` and `cmux.markdown.look`, the `save` page command (Cmd-S), and same-origin resources for images (`assetBase`, the file's folder only) and the diagram libraries (`libBase`: `mermaid.js`, `vega.js`). The page runs under the strict PageCSP: Vega uses `vega-interpreter`, code highlighting the Shiki JavaScript engine.

## Links

A plain click on a link places the caret; Cmd-click follows it (the cursor turns into a pointer while Cmd is held), and in a read-only file a click follows. Hovering shows a card with the full URL or the resolved path, how the link opens, and "Not found" for a relative target that does not exist (also marked with a wavy underline). Where a followed link goes (`linkRouter.ts`):

| Link                           | Goes to                                                                                                                                                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `#heading`                     | Scrolls smoothly to the heading in this file. Anchors are GitHub slugs, `-1`, `-2` for repeated headings.                                                                                                                             |
| `other.md`, `other.md#heading` | Opens in this page, then scrolls to the heading. The page keeps a link history: the `back` and `forward` page commands (Cmd-[ and Cmd-]) and the toolbar arrows. Pending edits are saved first; a file whose edits do not save stays. |
| Another relative file          | The file viewer (`openLink` kind `file`, with the resolved path).                                                                                                                                                                     |
| `http(s)://`                   | A cmux browser tab (`openLink` kind `external`).                                                                                                                                                                                      |
| `mailto:`, `tel:`              | The system handler (`openLink` kind `mail`).                                                                                                                                                                                          |
| Footnote reference             | Its definition; the definition's label jumps back.                                                                                                                                                                                    |

Reference links and autolinks resolve the same way. Relative targets are checked through `cmux.markdown.resolveLinks`, batched per tick and cached per file.

Editing: the `link` page command (Cmd-K) opens a link field on the selection or the link at the caret, completing `#headings` of this file and workspace paths (`cmux.markdown.listFiles`); Enter applies, Escape cancels, an empty URL removes the link. Pasting one URL over a selection links it; pasting a URL alone inserts an autolink. A reference link keeps its reference when its text or URL changes: a new URL rewrites its definition (and every link using it), and a shortcut `[text]` whose text changes is written as `[new text][label]`. Only the edited blocks change in the file.

## Customizing the look

Every look value is a `--cmux-md-*` CSS custom property with a default (`settings.ts` `MARKDOWN_STYLE_DEFAULTS`, the same defaults in `styles.css`). Three layers apply in order, later wins:

1. the defaults;
2. the `markdown` section of `cmux.json`, which the host passes in the page config and re-sends on the `cmux.markdown.look` stream when it changes;
3. the user stylesheet `<cmux.json dir>/markdown/theme.css` (`~/.config/cmux/markdown/theme.css`; `CMUX_NEXT_CONFIG_FILE` moves it), the same pattern as the agent pane's `agent-pane/theme.css`. It can set any `--cmux-md-*` property or style anything else.

Changes apply in place, without a reload. Fonts follow the app by default: the body uses the system UI font, as every page does, and code uses the terminal font the host sends in `appearance` (the diff viewer's `--cmux-diff-code-font-family`).

### Settings keys

Lengths given as numbers are pixels (`em` where noted); strings are CSS values. A color is a CSS color or `{"light": ..., "dark": ...}`.

| Key                            | Default                            | Sets                                                                                                              |
| ------------------------------ | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `markdown.defaultMode`         | `"rich"`                           | The mode a file opens in: `"rich"` or `"source"`.                                                                 |
| `markdown.toolbar`             | `true`                             | Show the toolbar (file, save status, mode switch).                                                                |
| `markdown.font.family`         | system UI font                     | `--cmux-md-font-family`                                                                                           |
| `markdown.font.size`           | `16`                               | `--cmux-md-font-size`                                                                                             |
| `markdown.font.weight`         | `400`                              | `--cmux-md-font-weight`                                                                                           |
| `markdown.font.lineHeight`     | `1.6`                              | `--cmux-md-line-height`                                                                                           |
| `markdown.headings.family`     | the body font                      | `--cmux-md-heading-font-family`                                                                                   |
| `markdown.headings.weight`     | `600`                              | `--cmux-md-heading-weight`                                                                                        |
| `markdown.headings.lineHeight` | `1.25`                             | `--cmux-md-heading-line-height`                                                                                   |
| `markdown.headings.scale`      | none                               | h5 is 1em, each level up `scale` times larger (h1 `scale^4`), h6 `1/scale`.                                       |
| `markdown.headings.sizes`      | `[2, 1.5, 1.25, 1.1, 1, 0.9]` (em) | `--cmux-md-h1-size` … `--cmux-md-h6-size`; wins over `scale`.                                                     |
| `markdown.headings.color`      | the text color                     | `--cmux-md-heading-color`                                                                                         |
| `markdown.code.family`         | the terminal font                  | `--cmux-md-code-font-family`                                                                                      |
| `markdown.code.inlineSize`     | `0.88` (em)                        | `--cmux-md-code-inline-size`                                                                                      |
| `markdown.code.blockSize`      | `14`                               | `--cmux-md-code-block-size`                                                                                       |
| `markdown.code.lineHeight`     | `1.55`                             | `--cmux-md-code-line-height`                                                                                      |
| `markdown.code.background`     | text at 5%                         | `--cmux-md-code-background`                                                                                       |
| `markdown.code.theme`          | `"terminal"`                       | Code colors: `"terminal"` (the terminal palette, as the diff viewer), a Shiki theme name, or `{"light", "dark"}`. |
| `markdown.layout.maxWidth`     | `"72ch"`                           | `--cmux-md-content-width`                                                                                         |
| `markdown.layout.padding`      | `32`                               | `--cmux-md-page-padding`                                                                                          |
| `markdown.spacing.paragraph`   | `"1em"`                            | `--cmux-md-paragraph-spacing`                                                                                     |
| `markdown.spacing.list`        | `"0.25em"`                         | `--cmux-md-list-spacing`                                                                                          |
| `markdown.spacing.listIndent`  | `"1.8em"`                          | `--cmux-md-list-indent`                                                                                           |
| `markdown.colors.text`         | the page text color                | `--cmux-md-text-color`                                                                                            |
| `markdown.colors.link`         | `#0b63c7` / `#6cb0ff`              | `--cmux-md-link-color`                                                                                            |
| `markdown.colors.quote`        | the secondary text color           | `--cmux-md-quote-color`                                                                                           |
| `markdown.colors.quoteBorder`  | the separator color                | `--cmux-md-quote-border` (3px solid)                                                                              |
| `markdown.colors.tableBorder`  | the separator color                | `--cmux-md-table-border` (1px solid)                                                                              |
| `markdown.colors.tableHeader`  | the code background                | `--cmux-md-table-header-background`                                                                               |
| `markdown.colors.selection`    | the link color at 28%              | `--cmux-md-selection-color`                                                                                       |
| `markdown.colors.caret`        | the text color                     | `--cmux-md-caret-color`                                                                                           |
| `markdown.colors.taskChecked`  | the link color                     | `--cmux-md-task-checked-color`                                                                                    |

Properties without a settings key (theme.css only): `--cmux-md-muted-color`, `--cmux-md-faint-color`, `--cmux-md-border-color`, `--cmux-md-heading-rule`, `--cmux-md-code-radius`, `--cmux-md-footnote-size`, `--cmux-md-superscript-size`, `--cmux-md-ui-font-size`, `--cmux-md-toolbar-font-size`, `--cmux-md-accent-background`, `--cmux-md-banner-background`, `--cmux-md-error-color`, `--cmux-md-link-broken-color`, `--cmux-md-popover-background`, `--cmux-md-popover-shadow`, `--cmux-md-popover-font-size`.

Example `cmux.json`:

```jsonc
{
  "markdown": {
    "font": { "family": "\"Iowan Old Style\", Georgia, serif", "size": 17 },
    "headings": { "family": "-apple-system, sans-serif", "scale": 1.2 },
    "code": { "theme": { "light": "github-light", "dark": "github-dark" } },
    "layout": { "maxWidth": "68ch" },
    "colors": { "link": { "light": "#0a5", "dark": "#5d9" } },
  },
}
```
