# Viewer customization matrix

Identify the surface first, then use only the settings or command documented for
that surface. `schemas/settings/settings-schema.json` (its `rows`) is the
authority for cmux-next JSON paths; `web/data/cmux.schema.json` and
`cmux-settings list-supported` describe classic cmux. A viewer name that does not
appear in the schema is not a license to add a guessed `templates.<viewer>` object.

| Viewer | What to customize | Supported path or surface | Read back |
|---|---|---|---|
| `terminal` | Font, theme, cursor, scrollback, rendering | `~/.config/ghostty/config`; `terminal.fontFamily`, `terminal.fontSize`, `appearance.theme` and `appearance.surfaces.terminal.*` override it in cmux settings | `cmux settings get <key>` |
| `browser` | Search engine, link routing, omnibar, toolbar, hibernation, passwords | `browser.*` (for example `browser.defaultEngine`, `browser.links.*`, `browser.omnibar.*`, `browser.toolbar.*`); profiles, navigation, devtools and per-page state use the browser UI or the cmux-browser skill | `cmux settings get <key>` |
| `markdown` | Surface color and opacity | `appearance.surfaces.markdown.color`, `appearance.surfaces.markdown.opacity`; no prose font, size or width setting exists in cmux-next | `cmux settings get <key>` |
| `diff` | Layout, word wrap, line numbers, word diffs, colors, hide white space | `diff.layout` (`split` or `unified`), `diff.wordWrap`, `diff.lineNumbers`, `diff.wordDiffs`, `diff.colors`, `diff.expandUnchanged`, `diff.hideWhitespace` (default `false`; git sources only), `appearance.surfaces.diff.*` | `cmux settings get <key>` |
| `filePreview` | Which editor opens text files | `files.textEditor` (user-only); `cmux open <path>` shows a file in the page that fits it | `cmux settings get files.textEditor` |
| `rightSidebarTool` | Which tool is shown and tab order | the app's sidebar UI; no settings key | none |
| `html` | Local HTML content and browser chrome | Open local `.html` in a browser tab (`cmux tab create browser --url file:///…`) and edit the HTML/CSS for page content | none |
| `notes` | Project-scoped notes rendering | No `notes.*` or `templates.notes` setting is shipped | Do not write an unknown key |

The current schema exposes only the knobs listed above. Markdown fonts, theme,
line-height, syntax highlighting and image behavior, plus file-preview backend
selection, size limits and video autoplay, do not have cmux settings yet. Viewer navigation shortcuts
are schema-backed under `shortcuts.bindings.diffViewer*` (for example `diffViewerNextHunk`) and are shared by
the Markdown and diff viewers; see the [shortcut action reference](../../cmux-settings/references/shortcut-actions.md)
and [keyboard shortcut skill](../../cmux-keyboard-shortcuts/SKILL.md) before
changing them. Explain the remaining boundary and point to the schema or the
templates follow-up instead of inventing a path.

## Safe workflow

1. Map the user's words to one row. If the request names a knob that is not in
   that row, inspect the schema before editing.
2. Change schema-backed paths with `cmux settings set <key> <value>`; it
   validates values for known keys. A key with `agent_settable: false` is
   refused with `setting_user_only`; leave it to the person. Edit Ghostty config only when the matrix
   names it as the owner.
3. Read back the exact setting with `cmux settings get <key>`.

## Examples

```bash
cmux settings set diff.layout split
cmux settings set diff.wordWrap true
cmux settings set terminal.fontSize 14
cmux settings set appearance.surfaces.markdown.opacity 0.9
```

The shared templates proposal in [#4516](https://github.com/manaflow-ai/cmux/issues/4516)
and its implementation PR [#14749](https://github.com/manaflow-ai/cmux/pull/14749)
may add per-viewer CSS or layout overrides later. Once those schema-backed keys
land, add the new viewer paths to this matrix; until then, fail closed on
unknown viewer names and knob names.
