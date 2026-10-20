# Markdown viewer: Obsidian parity

The cmux-next Markdown page (`webviews/src/pages/markdown/`) against Obsidian's Live Preview and
Reading view. User request 2026-10-19 (table highlighting, column resizing, "every kind of Markdown
intricacy that Obsidian has", table borders in transparency mode).

Status: **done** (works, tested), **partial**, **gap** (not built). "Before" is the state on
feat-cmux-next before this work.

## Tables

| Behavior (Obsidian) | Before | Now | Test |
| --- | --- | --- | --- |
| Drag across cells selects whole cells with one even fill | gap: no fill, stray native text highlight | done | markdown-table-obsidian (Chromium, WebKit) |
| Shift-click extends the cell selection | partial (no fill) | done | markdown-table-obsidian |
| Shift-arrows across cells | partial (no fill) | done (prosemirror-tables + new fill) | — |
| Cmd-A: cell text, then whole table, then document | gap | done | markdown-table-keys |
| Escape drops a cell selection | gap | done | markdown-table-keys |
| Copy cells as Markdown table (+ HTML for spreadsheets) | gap (copied loose text) | done | markdown-table-keys |
| Cut cells empties them, keeps the table | gap | done | — |
| Paste a grid into cells | done (prosemirror-tables) | done | — |
| Tab / Shift-Tab between cells | done | done | markdown-table-keys |
| Tab past the last cell adds a row | gap | done | markdown-table-keys |
| Return moves down a row; in the last row adds a row | gap: Return left the table | done | markdown-table-keys |
| Column alignment kept on new rows | gap | done | markdown-table-keys |
| Column resize: drag a handle on the column edge | gap | done | markdown-table-obsidian |
| Column widths persist | gap | done (per file, view setting, never written to the file: GFM has no widths) | markdown-table-obsidian, markdown-table-keys |
| Double-click handle fits the column | gap | done | markdown-table-obsidian |
| Add/delete/move row or column from a menu | gap | gap (commands exist in Milkdown, no menu yet) | — |
| Set alignment from a menu | gap | gap | — |
| Wide table scrolls sideways in its own box | done (a88 era) | done | markdown-wide-table-scroll |
| Borders one color with translucent separators (transparency mode) | gap: crossings darker (double alpha), header fill tinted its border | done (each border pixel painted once) | markdown-table-obsidian (pixel test) |

## Syntax

| Obsidian syntax | Before | Now | Test |
| --- | --- | --- | --- |
| `==highlight==` | gap (literal) | done, markers hide off-caret | markdown-obsidian-syntax |
| `%%comment%%` | gap | done (drawn faint; Reading-view hiding: gap) | markdown-obsidian-syntax |
| `#tag`, `#nested/tag` | gap | done (not `#123`) | markdown-obsidian-syntax |
| `[[note]]`, `[[note#heading\|alias]]` | gap; an edit wrote `\[\[` | done; Cmd-click opens `note.md#heading`; kept as typed on edit | markdown-obsidian-syntax |
| `![[image.png\|300]]` image embed | gap | done | — |
| `![[note]]` note embed (transclusion) | gap | gap (drawn as a link) | — |
| `[[note#^block]]` block refs, `^id` | gap | gap | — |
| Callouts `> [!type] Title`, all types and aliases | partial (plain quote) | done, colored per type, default title | markdown-obsidian-syntax |
| Foldable callouts `[!type]-` / `+` | gap | done (chevron toggles) | markdown-obsidian-syntax |
| `$inline$` and `$$block$$` math (KaTeX) | gap (literal) | done, source on caret | markdown-obsidian-syntax |
| Mermaid | done (Ondine, Mermaid fallback) | done | markdown-mermaid-ondine |
| Footnotes `[^1]` | done | done | — |
| Inline footnotes `^[text]` | gap | gap | — |
| Task lists `- [ ]`, `- [x]` | done | done | — |
| Custom task statuses `- [/]`, `- [-]`, `- [>]` | gap | gap | — |
| Strikethrough `~~x~~` | done | done | — |
| Frontmatter / properties | done (folded raw block) | done (Properties table editor: gap) | — |
| HTML blocks | done (preview) | done | — |
| Images `![alt\|300](src)`, `\|300x200` | gap | done | markdown-obsidian-syntax |
| Code blocks: highlight, language label | done | done | — |
| Code block copy button | gap | gap | — |
| Horizontal rules, escapes, nested lists | done | done | — |
| Folding headings and lists | gap | gap | — |
| Live Preview marker hiding for `**`, `_`, `` ` ``, links | n/a (rich editor hides them always) | same | — |

## Counts

- Done in this pass: 22 behaviors (tables 15, syntax 7 groups incl. callout folding, math, image sizes).
- Already done before: 13.
- Left (gap or partial): 11 — table row/column menu, alignment menu, note embeds, block refs, inline
  footnotes, custom task statuses, Properties editor, code copy button, heading/list folding,
  Reading-view comment hiding, `%%` multi-paragraph comments.

## Notes

- Column widths are a view setting in `localStorage` (`cmux.markdown.columnWidths:<path>`), so a
  resize never marks the file edited. Obsidian also does not write widths into Markdown.
- Callout default titles are the type word as typed (English, like Obsidian), not a UI string.
- Screenshots: `screenshots/` (table drag + resize handle over a translucent grid on a gradient;
  Obsidian syntax), WebKit and Chromium, light and dark color scheme.
