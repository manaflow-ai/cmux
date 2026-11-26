# Viewer customization matrix

Identify the surface first, then use only the settings or command documented for
that surface. `cmux-settings list-supported` and
`web/data/cmux.schema.json` are the authority for JSON paths. A viewer name that
does not appear in the schema is not a license to add a guessed
`templates.<viewer>` object.

| Viewer | What to customize | Supported path or surface | Validation and reload |
|---|---|---|---|
| `terminal` | Font, theme, cursor, scrollback, rendering, and terminal keybindings | `~/.config/ghostty/config`; cmux-owned presentation such as the scrollbar and scroll speed uses `terminal.*` | Ghostty config validation; `cmux reload-config` |
| `browser` | Page zoom, theme, search/omnibar behavior, download prompts, navigation routing, and hidden-page memory policy | `browser.*` in `cmux.json`; browser profile import, page navigation, devtools, and per-page state use the browser UI or `cmux browser` | `cmux-settings validate`; `cmux reload-config` |
| `markdown` | Default prose size, prose font, reading-column width, and Cmd-click routing | `markdown.fontSize`, `markdown.fontFamily`, `markdown.maxWidth`, and `app.openMarkdownInCmuxViewer` | `cmux-settings validate`; `cmux reload-config` |
| `diff` | New-viewer layout and one-invocation layout override | `diffViewer.defaultLayout`; `cmux diff --layout unified|split` overrides it for one invocation | `cmux-settings validate`; `cmux reload-config` |
| `filePreview` | Whether a file opens in cmux, whether Markdown uses the rendered viewer, where double-click routes, and text-editor rendering | `app.openSupportedFilesInCmux`, `app.openMarkdownInCmuxViewer`, `app.preferredEditor`, `fileExplorer.doubleClickAction`, and `fileEditor.*`; generic Quick Look media has no additional cmux template knobs | `cmux-settings validate`; `cmux reload-config` |
| `rightSidebarTool` | Which tool is shown, tab order, and Dock commands | `cmux right-sidebar set <mode>`, Settings > Sidebar > right-sidebar tabs, and `.cmux/dock.json` or `~/.config/cmux/dock.json` | `cmux right-sidebar mode`; parse Dock JSON; `cmux reload-config` for JSON changes |
| `html` | Local HTML content and browser chrome | Treat `cmux open` for `.html` as an embedded browser surface; use applicable `browser.*` presentation settings (such as theme and default zoom) and edit the HTML/CSS for page content. Local HTML opening bypasses host routing lists. | `cmux-settings validate` for JSON changes; `cmux reload-config` |
| `notes` | Project-scoped notes rendering | No `notes.*` or `templates.notes` setting is shipped yet. If the notes surface is Markdown, use the `markdown.*` defaults; otherwise wait for its schema section | Do not write an unknown key; re-check the schema when notes customization lands |

The current schema intentionally exposes only the knobs listed above. Markdown
theme, line-height, syntax-highlighter, and anchor/image behavior, plus
file-preview backend selection, fallback policy, size limits, and video
autoplay, do not have dedicated cmux settings yet. Viewer navigation shortcuts
are schema-backed under `shortcuts.bindings.diffViewerScroll*` and are shared by
the Markdown and diff viewers; see the [shortcut action reference](../../cmux-settings/references/shortcut-actions.md)
and [keyboard shortcut skill](../../cmux-keyboard-shortcuts/SKILL.md) before
changing them. Explain the remaining boundary and point to the schema or the
templates follow-up instead of inventing a path.

## Safe workflow

1. Map the user's words to one row. If the request names a knob that is not in
   that row, inspect the schema and the linked docs before editing.
2. Back up the target JSONC file, preserving unrelated `actions`, `ui`,
   `commands`, `vault`, `rightSidebar`, and `notifications` content.
3. Use `cmux-settings set` or `unset` for schema-backed paths. Edit Ghostty or
   Dock files only when the matrix names them as the owner.
4. Validate the complete file. A failed validation must leave the file
   unchanged.
5. Run `cmux reload-config` after a successful change, then read back the exact
   setting or command state.

## Examples

```bash
cmux-settings set markdown.fontSize 16
cmux-settings set browser.defaultZoomLevel 1.25
cmux-settings set fileEditor.wordWrap true
cmux-settings set diffViewer.defaultLayout '"split"'
cmux right-sidebar set dock
cmux right-sidebar mode
cmux reload-config
```

The shared templates proposal in [#4516](https://github.com/manaflow-ai/cmux/issues/4516)
and its implementation PR [#14749](https://github.com/manaflow-ai/cmux/pull/14749)
may add per-viewer CSS or layout overrides later. Once those schema-backed keys
land on `main`, add the new viewer paths to this matrix and
`cmux-settings/references/all-keys.md` together; until then, fail closed on
unknown viewer names and knob names.
