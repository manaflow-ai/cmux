# Markdown editor page

The cmux-next markdown page (`cmux-page://cmux.markdown/`, entry `webviews/markdown-page.html`) opens a markdown file as an editor: rich text (Milkdown, ProseMirror with remark) by default, with a source mode. Dev: `bun run dev`, then `/markdown?file=<path>`.

## Saving never rewrites what you did not edit

A save is a minimal-change write (`sourceMap.ts`). The editor keeps each top-level block's exact source; a block the user did not change is written back byte for byte, and only edited blocks go through the serializer. Front matter, link definitions and HTML blocks are raw blocks kept verbatim; reference links stay references when their paragraph is edited. Stock Milkdown serialization kept 2 of the 35 real files.

## Host contract

`host.ts` lists the ops and streams the native host (diff-host.md S6) implements: `cmux.markdown.config`, `cmux.markdown.save {path, text, baseHash}` (refused with `cmux.markdown.conflict` on a hash mismatch), `cmux.markdown.open` (also for followed links), `cmux.markdown.openLink`, `cmux.markdown.resolveLinks`, `cmux.markdown.listFiles`, the page commands `save`, `back`, `forward`, `link` and `goToTop` (scrolls to the top), the streams `cmux.markdown.changes` and `cmux.markdown.look`, the `save` page command (Cmd-S), and same-origin resources for images (`assetBase`, the file's folder only) and the diagram libraries (`libBase`: `ondine.js`, `mermaid.js`, `vega.js`; Mermaid source always draws with Ondine; Mermaid only as the automatic fallback for a source Ondine refuses, no flag or setting). The page runs under the strict PageCSP plus `'wasm-unsafe-eval'` for Ondine: Vega uses `vega-interpreter`, code highlighting the Shiki JavaScript engine.

## Editable everywhere

Every markdown file opens editable, whoever opened it (Open File..., `cmux open`, an agent, a link) and in any workspace, Home included. The host sends `readOnly` with a `readOnlyReason` only for a real reason, and the page names it: `encoding` (not UTF-8), `binary`, `permission` (the file is not writable) or `transcript` (a chat transcript the host opens read only). A change on disk reloads the page when it has no unsaved edits and raises the conflict banner when it has.

## Text size

Cmd-= (also Cmd-Shift-=, Cmd-+) and Cmd-- are the app key dispatcher's `zoomIn` and `zoomOut` page commands: one pixel per step, 8 to 40, in rich and source mode. Cmd-0 (`zoomReset`) goes back to the default, `markdown.font.size` (Settings > Appearance > Markdown Viewer > Default Font Size, 16 when unset). The page applies the size as `--cmux-md-zoom` (size over the default) on the body and code sizes (`fontZoom.ts`); a viewer keeps its size across a page reload, and a viewer at the default follows a new default.

## Links

A plain click on a link places the caret and shows the **link bubble** under it (Google Docs' model, `linkEditing.ts` `LinkBubble`, `linkOverlays.tsx`); so does the caret entering a link from the keyboard. Hovering a link shows nothing. The bubble shows the full URL or the resolved path (the URL itself opens the link), how the link opens, "Not found" for a relative target that does not exist (also marked with a wavy underline), and Copy link, Edit and Remove. It never takes the focus: typing goes on in the editor, and Escape hides it until the caret leaves that link. Cmd-click and Option-Return follow the link at the caret (the cursor turns into a pointer while Cmd is held); in a read-only file a click follows. Where a followed link goes (`linkRouter.ts`):

Where a followed link goes (`linkRouter.ts`):

| Link                           | Goes to                                                                                                                                                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `#heading`                     | Scrolls smoothly to the heading in this file. Anchors are GitHub slugs, `-1`, `-2` for repeated headings.                                                                                                                             |
| `other.md`, `other.md#heading` | Opens in this page, then scrolls to the heading. The page keeps a link history: the `back` and `forward` page commands (Cmd-[ and Cmd-]) and the toolbar arrows. Pending edits are saved first; a file whose edits do not save stays. |
| Another relative file          | The file viewer (`openLink` kind `file`, with the resolved path).                                                                                                                                                                     |
| `http(s)://`                   | A cmux browser tab (`openLink` kind `external`).                                                                                                                                                                                      |
| `mailto:`, `tel:`              | The system handler (`openLink` kind `mail`).                                                                                                                                                                                          |
| Footnote reference             | Its definition; the definition's label jumps back.                                                                                                                                                                                    |

Reference links and autolinks resolve the same way. Relative targets are checked through `cmux.markdown.resolveLinks`, batched per tick and cached per file.

Editing: the bubble's Edit and the `link` page command (Cmd-K) open the link form on the link at the caret or the selection: a Text field and a URL field (completing `#headings` of this file and workspace paths, `cmux.markdown.listFiles`), Apply and Remove. Return applies, Escape cancels, an empty URL removes the link, an empty text uses the URL; with no selection Cmd-K inserts a new link. Remove (in the bubble or the form) unlinks and keeps the text. Pasting one URL over a selection links it; pasting a URL alone inserts an autolink. Typing a bare `http(s)://` or `www.` URL and then a space or Return links it (GFM's rules: trailing punctuation stays out); Cmd-Z right after takes the link back. Each link keeps its spelling when its paragraph is edited: `[text](url)` inline, `<url>` as `<url>`, a bare URL as a bare URL while its text is the URL. A reference link keeps its reference when its text or URL changes: a new URL rewrites its definition (and every link using it), and a shortcut `[text]` whose text changes is written as `[new text][label]`. Only the edited blocks change in the file.

## Reading Settings

The toolbar's **Aa** button opens the Reading Settings popover (`ReadingSettings.tsx`): text width (see below), font size, font (System, Serif, Mono), line height, paragraph spacing, code size, wide tables (Scroll or Wrap) and theme (App, Light, Dark), and Reset to Defaults. Each row is one `markdown.*` key below (`settings.ts` `MARKDOWN_READING`), also a row in Settings > Appearance > Markdown Viewer and a key in `cmux.json`. A change shows at once and goes through `cmux.markdown.setPreference {key, value}` (value null resets the key), the one settings write path, 250 ms after the last change of a slider drag; every open viewer follows the new look. A new font size is the default size (`markdown.font.size`), so the viewer drops its own Cmd-= / Cmd-- size.

### Text width

The width row works like a dimension field in a design tool, not a slider: type `120`, `120ch`, `1600pt` (a point is a CSS pixel here, converted with the body font's character width) or simple arithmetic (`72*2`, `(100 + 60) / 2`), then Return or leave the field; Escape puts the value back. Up and Down step by 1 character, Shift by 10, and so do the small stepper arrows; dragging the **Text Width** label sideways scrubs the value (2 px a character, Shift for 10). The menu beside it holds the presets, as Word's page margins do: Narrow (56), Comfortable (72, the default), Wide (100), Extra Wide (160), Ultra Wide (300) and Full Width, plus Custom when the width is none of them. The range is 30 to 1000 characters (about 8,800 pt at 16 pt text), so an ultrawide monitor can have a very wide column that still keeps margins; an out-of-range value takes the nearest end and the field shows it. Full width is its own key (`markdown.layout.fullWidth`), never the top of the range. On a pane wider than the width the column stays centered; on a narrower pane it fits the pane.

The width is in characters, not points, so the line length stays the same when the text size or font changes (Cmd-= / Cmd--, the font preset); the field shows the width in points under it for reference.

## Wide tables and code

A table wider than the column scrolls sideways in its own box (the editor's `.tableWrapper`), as a long code line does in its block: trackpad swipes, Shift-wheel and the scrollbar move that box, `overscroll-behavior-x: contain` keeps the swipe from reaching the page at either end, and a vertical wheel over it scrolls the page. The page itself scrolls only up and down. `markdown.tables: "wrap"` fits tables to the column instead.

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
| `markdown.tables`              | `"scroll"`                         | Wide tables: `"scroll"` sideways in their own box, or `"wrap"` to the column.                                     |
| `markdown.theme`               | `"app"`                            | The page's colors: `"app"`, or always `"light"` or `"dark"`.                                                      |
| `markdown.font.preset`         | `"system"`                         | The body font when `font.family` is unset: `"system"`, `"serif"` or `"mono"` (the code font).                     |
| `markdown.font.family`         | system UI font                     | `--cmux-md-font-family`                                                                                           |
| `markdown.font.size`           | `16`                               | `--cmux-md-font-size`; the default text size (Settings row; Cmd-0 returns to it)                                  |
| `markdown.font.weight`         | `400`                              | `--cmux-md-font-weight`                                                                                           |
| `markdown.font.lineHeight`     | `1.6`                              | `--cmux-md-line-height`                                                                                           |
| `markdown.headings.family`     | the body font                      | `--cmux-md-heading-font-family`                                                                                   |
| `markdown.headings.weight`     | `600`                              | `--cmux-md-heading-weight`                                                                                        |
| `markdown.headings.lineHeight` | `1.25`                             | `--cmux-md-heading-line-height`                                                                                   |
| `markdown.headings.scale`      | none                               | h5 is 1em, each level up `scale` times larger (h1 `scale^4`), h6 `1/scale`.                                       |
| `markdown.headings.sizes`      | `[2, 1.5, 1.25, 1.1, 1, 0.9]` (em) | `--cmux-md-h1-size` … `--cmux-md-h6-size`; wins over `scale`.                                                     |
| `markdown.headings.color`      | the text color                     | `--cmux-md-heading-color`                                                                                         |
| `markdown.code.family`         | the terminal font                  | `--cmux-md-code-font-family`                                                                                      |
| `markdown.code.scale`          | `0.875`                            | Code (blocks and inline) as a share of the text size (0.6 to 1.25), as GitHub's 85%: `--cmux-md-code-scale`.      |
| `markdown.code.inlineSize`     | `code.scale` (em)                  | `--cmux-md-code-inline-size`                                                                                      |
| `markdown.code.blockSize`      | text size × `code.scale`           | `--cmux-md-code-block-size`; a fixed size in pixels that wins over `scale` for blocks (not a Settings row).       |
| `markdown.code.lineHeight`     | `1.55`                             | `--cmux-md-code-line-height`                                                                                      |
| `markdown.code.background`     | text at 5%                         | `--cmux-md-code-background`                                                                                       |
| `markdown.code.theme`          | `"terminal"`                       | Code colors: `"terminal"` (the terminal palette, as the diff viewer), a Shiki theme name, or `{"light", "dark"}`. |
| `markdown.layout.width`        | `72`                               | The text width in characters (30 to 1000, centered on a wider pane); wins over `maxWidth`.                        |
| `markdown.layout.fullWidth`    | `false`                            | Text fills the pane; wins over `width` and `maxWidth`.                                                            |
| `markdown.layout.maxWidth`     | `"72ch"`                           | `--cmux-md-content-width`                                                                                         |
| `markdown.layout.padding`      | `32`                               | `--cmux-md-page-padding`                                                                                          |
| `markdown.spacing.paragraph`   | `1` (em)                           | `--cmux-md-paragraph-spacing`; a number is in em (it scales with the text), a string is a CSS length.             |
| `markdown.spacing.list`        | `"0.25em"`                         | `--cmux-md-list-spacing`                                                                                          |
| `markdown.spacing.listIndent`  | `"1.8em"`                          | `--cmux-md-list-indent`                                                                                           |
| `markdown.colors.text`         | the page text color                | `--cmux-md-text-color`                                                                                            |
| `markdown.colors.link`         | the theme accent                   | `--cmux-md-link-color`                                                                                            |
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
