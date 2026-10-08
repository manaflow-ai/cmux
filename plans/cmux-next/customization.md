# Customization: one standard, every viewer surface

Status: plan, phase 1 (inventory and standard), 2026-10-04, at `feat-cmux-next` 76a7656ce61. Lawrence:
"think from first principles everything a user might want to customize about the stuff we're
working on, and make sure it is all customizable". No code changes in this phase.

Coordinator rules folded in (2026-10-04): the settings schema belongs to the Settings lead; the React
Settings page belongs to the React UIs lead (R82); grouping and an "advanced" tier are coordinator
decisions; every setting reaches the palette through the R93 settings mechanism; R92: no cmux key
duplicates a Ghostty key, and pages that follow the terminal read the Ghostty-derived theme; backdrops
use only R48/R55 `appearance.surfaces.*`; bare-key bindings only in a focused read-only page context
that owns them, never while a text field has focus.

Path prefixes: `S/` = `Packages/macOS/CmuxNext/Sources/`, `W/` = `webviews/src/`. `r89:` = the
uncommitted picker work in `worktrees/feat-cmux-next-r89-picker` (line numbers can move). `R80:` =
branch `feat-cmux-next-browser-toolbar` at b24416d714d. "config dir" = the directory of
`~/.config/cmux/cmux-next.json` (`S/CmuxNextSettings/CmuxConfigFile.swift:18-29`; the live file is
`cmux-next.json`, seeded once from `cmux.json`).

## 1. How cmux-next customizes today

| Mechanism | Where (file:line) | Reaches pages? |
| --- | --- | --- |
| Settings schema: `SettingDescriptor {path, section, group, title, help, kind, default, keywords}` | `S/CmuxNextSettings/Schema/SettingDescriptor.swift:6-78`; registry `SettingsSchema.all` `Schema/SettingsSchema.swift:10-12` | No viewer keys exist. About 122 keys: `appearance` 42 (24 are `surfaces`), `notifications` 18, `layout` 17, `browser` 7, others small |
| Live reload | `ConfigFileWatcher.swift:3-43` -> `SettingsController.swift:79-88,212-273` -> `SettingsApplier.swift:30-104` | Only through `WebTheme` (below) |
| Schema export | `Schema/SettingsSchemaExport.swift:3-113` -> `schemas/settings/settings-schema.json` (stale: 121 rows, no `layout.paneSeparation`) | The React Settings page imports it (`W/pages/settings/schema.ts:3`) |
| Owner move | Writer moves to the daemon config actor (`plans/cmux-next/settings-react.md` section 1) | Ops `settings.schema/list/get/snapshot/set/reset`, event `settings-changed` |
| Settings UI | Native groups `S/CmuxNextSettingsWindow/SettingsWindowModel.swift:152-165`; rows by kind `Views/SettingRowView.swift:63`; search `SettingsSearchIndex.swift:54-56`; the only tier gate is `appearance.experimentalControls` (`ExperimentalAppearanceSetting.swift:1-4`) | React page planned (settings-react.md section 4) |
| MDM | Domain `com.manaflow.cmux` `Managed/ManagedPreferences.swift:10-32`; team layer `TeamDevicePolicy.swift`; guard `ManagedKeyGuard.swift`; docs generated to `docs/mdm/*` | Managed rows read-only |
| Palette (R93 mechanism) | Scope `,` `S/CmuxNextPalette/Scopes/PaletteScopeCatalog.swift:36-38`; `SettingsPaletteProvider.swift:22-40`; source exposes toggles only (`PaletteSettingsSource.swift:17-20`) | "Set Setting..." for every kind is planned (`settings-surfaces.md`, "Value pickers") |
| Keybindings | Defaults `defaultShortcut:` on `ActionDescriptor` in `S/CmuxNextActions/Catalog/*`; user `shortcuts.bindings.<id>` (`CmuxConfigSnapshot.swift:48-53,316-349`, `SettingsApplier.swift:70-135`); `keybindings.json` loader exists but is unused (`KeyBindingLayers.swift:1-16`); editor page `W/pages/keybindings`, provider `KeybindingsPageProvider.swift:6-30` (`set` answers unsupported) | Page commands via `cmux.page.command` (`S/CmuxNextPages/PageDescriptor.swift:87-97`). There is no `KeyboardShortcutSettings` type in cmux-next |
| Bare keys in pages | Diff j/k/G/Ctrl-D... are registry actions with `diffViewerFocused` (`S/CmuxNextActions/Catalog/BrowserActionCatalog.swift:307-365`) mapped to page commands (`S/CmuxNextPages/PageDescriptor+Viewers.swift:3-39`) | Rule: `plans/cmux-next/keybindings.md` 4.2 |
| Backdrop R48 + R55 | `appearance.surfaces.<kind>.{color,opacity}` `S/CmuxNextSettings/SurfaceBackgroundSetting.swift:13-74`; kinds `S/CmuxNextDesign/Windows/SurfaceBackgrounds.swift:7-23` (`diff` exists; no `markdown`, `fileViewer`, `picker`) | `--cmux-surface-background` via `WebTheme.swift:30-46` |
| Look push | `window.cmuxTheme.apply({variables, colorScheme})` + DOM event `cmux-theme` (`S/CmuxNextDesign/Windows/WebTheme.swift:50-88`, `S/CmuxNextPages/PageWebView.swift:230-258`); consumed `W/backdrop.ts:106` | A script, not a protocol stream; no font or accent variables |
| App fonts | `terminal.fontFamily`, `terminal.fontSize` (`Schema/SettingsSchema+Terminal.swift:8-18`; R92 migrates them to `ghostty.font-*`); UI size `appearance.metrics.chromeFontSize` (`DesignSettings.swift:14,114`) | Pages hard-code 13px system font (`W/pages/shared/pageBase.css:25`) |
| Per-surface theme.css | Agent pane: `<config dir>/agent-pane/theme.css` (`S/CmuxNextAgentPane/AgentPaneCustomization.swift:25,55-61`, watcher `S/CmuxNextApp/AgentPaneCustomizationWatcher.swift:5-34`). Markdown: `<config dir>/markdown/theme.css` designed (`W/pages/markdown/settings.ts:238-246`) but served only by the dev server (`webviews/dev-server/markdownHost.ts:264-274`) | Agent pane live; markdown dev only |
| Renderer extension | Agent pane `registry.js`: `window.cmuxAcpmuxRegistry.register(kind, renderer, {measure})` (`W/agent-session/acpmux/App.tsx:129-136,1172-1185`) | Runs in the page's main world with the native bridge; no sandbox |
| Diff languages folder | `<config dir>/diff/languages/*.language.json`, `*.tmLanguage.json`, `overrides.json` (`W/diff-languages/pack.ts:1-24`, `host.ts:1-34`) | Dev server only (`webviews/dev-server/diffLanguages.ts:13-18`) |
| Pane protocol | Namespaces `cmux` + `com.example.hello` (`cmux-tui/crates/cmux-pane-protocol/src/catalog.rs:11-27`); third-party app ids reserve a reverse-DNS namespace (`src/router/mod.rs:130-163,236-298`); interface drafts `cmux.diff.source/1`, `cmux.viewer/1`, `cmux.diff.renderer/1`, `cmux.opener/1` | Router is not in the daemon (`plans/cmux-next/react-pages.md:35`); page ids hard-coded (`S/CmuxNextPages/PageID.swift:12-15`, `S/CmuxNextApp/Pages/PageFactory.swift:12-41`) |

Two facts shape everything below. First, neither the diff page nor the markdown page has a cmux-next
host yet (`S/CmuxNextApp/Handlers/BrowserHandlers.swift:144-149`; diff-host.md S4/S6), so every
"payload" or "cmux.json section" knob of those pages works only in the dev server. Second, page web
views use a non-persistent data store (`S/CmuxNextPages/PageWebView.swift:126`), so the diff viewer's
`localStorage` fallback loses every preference on cmux-next.

## 2. The standard

Every surface follows these seven rules. A surface is done when each item in its table is reachable
through one of them.

1. **Settings keys in the schema, one group per surface**: `diff.*`, `markdown.*`, `picker.*`,
   `browser.toolbar.*`, `fileViewer.*`, `agentPane.*`, plus three shared groups for values that
   several surfaces must agree on: `files.*` (associations, editor, open-in), `viewers.*` (recents,
   link policy) and two `appearance.*` keys (`appearance.syntaxTheme`, `appearance.fileIcons`). Keys
   are behavior and layout choices a user can name. Each is a `SettingDescriptor` (Settings lead),
   exported to `settings-schema.json`, written only by the config actor, reachable from the palette
   through R93, and carries `agent_settable`. A toolbar toggle in a page writes the key with
   `settings.set`; it never writes page-local storage.
2. **Pages get settings live through the page host**: `<ns>.config` returns the page's settings
   subset at open (the keys under the prefixes its descriptor declares), and one generic stream
   `cmux.page.look` delivers `{revision, variables, settings, themeCSS}` on every change. It replaces
   `window.cmuxTheme.apply` and per-page look streams (`cmux.markdown.look`). Pages that follow the
   terminal (code font, ANSI palette, selection, syntax "terminal" theme) take those values from the
   Ghostty-derived theme in `variables` (R92). There is never a second cmux key for them.
3. **One CSS custom property namespace per surface**, `--cmux-<surface>-*` (`--cmux-diff-*`,
   `--cmux-md-*`, `--cmux-picker-*`, `--cmux-file-*`, `--agent-*`), on top of the shared
   `--cmux-*` page tokens from `WebTheme`. The custom properties are the public, documented,
   versioned styling API; class names are not. Fine-grained look (individual colors, radii, spacing,
   weights) lives here, not in settings keys. Settings that change looks (density, font size) are
   applied by setting these properties, so a stylesheet always wins.
4. **One user stylesheet per surface**: `<config dir>/<surface>/theme.css` (`diff`, `markdown`,
   `picker` (web picker only), `fileViewer`, `agent-pane`), loaded by one generic watcher in the page
   host, delivered in `cmux.page.look.themeCSS`, injected as the last `<style>` and replaced live.
   Native surfaces (browser toolbar, native palette) have no stylesheet; they use settings and design
   tokens only.
5. **Renderers through one registry pattern, sandboxed**: `<config dir>/<surface>/renderers/*.js`
   register renderers for named slots (agent pane row kinds, markdown fenced-code languages, diff rich
   previews, file viewer types). They run in a sandboxed, opaque-origin iframe with
   `connect-src 'none'`, receive serialized slot data and return a declarative node tree
   (allowlisted elements, attributes and named actions) that the page renders. They never get the
   native bridge. The agent pane's main-world `registry.js` stays only as an explicit opt-in
   (`agentPane.registry.trust = "page"`, default `"sandboxed"`), owned by the ACP UI lead.
6. **Keys only through the dispatcher and the action catalog**: every page action is a catalog
   action with a context and is rebindable in `shortcuts.bindings` (later `keybindings.json`).
   Pages handle only plain navigation and typing (keybindings.md 4.2). Bare keys (no Command or
   Control) bind only under a read-only page context that owns them (`diffViewerFocused`,
   `markdownReadOnlyFocused`, `filePreviewFocused`, `agentChangesFocused`), never while a text field
   has focus.
7. **Extensions through pane protocol namespaces**: third-party diff sources, viewers, renderers and
   openers implement the `cmux.diff.source/1`, `cmux.viewer/1`, `cmux.diff.renderer/1`,
   `cmux.opener/1` interfaces in their own namespace; `files.associations` values and the diff
   source menu accept provider ids. A third-party page gets the same config, look stream and user
   stylesheet (`<config dir>/apps/<app id>/theme.css`) as a first-party page.


### Why this and not the alternatives

| Alternative | Why not |
| --- | --- |
| Page-local preferences (`localStorage`, `viewerPrefs.get/set` as in `W/viewer-prefs.ts:5-67`) | Lost on cmux-next (non-persistent store), invisible to CLI, MCP, palette, MDM and sync, and a second writer for the same choice |
| One JSON file per surface (`agent-pane/layout.json`) | No schema, no validation, no Settings UI, no palette, no managed guard; silent failures (agent pane today accepts only `dictation.autoSend`) |
| Everything in theme.css | CSS cannot express behavior (autosave, default source), and a stylesheet is unreadable to the Settings UI |
| Every color and size as a settings key | Hundreds of keys that each duplicate a CSS property; Settings UI quality collapses; R92 already moves terminal-derived values out of cmux.json |
| VS Code-style "contributes.configuration" from extensions now | Correct end state, but needs the router in the daemon; rule 7 reserves the namespace (`apps.<id>.*`) without building it now |
| Main-world renderer scripts (today's `registry.js`) | A theme download becomes code with the native bridge (git, file open, browser open); not acceptable as a default |

### Strongest objection: settings sprawl and Settings UI quality

The objection: seven surfaces times dozens of knobs gives hundreds of keys, a Settings window nobody
can scan, and a schema that is expensive to keep translated and tested.

Handling:
- **Budget.** A key exists only for a behavior or layout choice that a user would name in a
  sentence ("show the files panel on the left"). Colors, radii, weights, spacing and per-element
  font sizes are CSS custom properties (rule 3). This plan proposes about 75 new keys across all
  surfaces, not 300. The markdown dev section today has about 40 keys (`W/pages/markdown/settings.ts:154-218`);
  its color and code-font keys move to custom properties.
- **Tiers.** Descriptors gain `tier: basic | advanced` (coordinator decision). The Settings page
  shows basic rows; advanced rows sit behind one disclosure per group; search, the palette and the
  CLI always see every row. Thresholds (`diff.autoCollapse.*`), write-back style
  (`markdown.format.*`) and limits are advanced.
- **Grouping.** One "Viewers" section with one group per surface (Diff, Markdown, File Viewer,
  Picker), plus Browser > Toolbar and Agent Pane groups (coordinator decides the section).
- **Search first and edit in place** as settings-react.md section 4 specifies, so the count of
  rows does not change how fast a user finds one.
- **Shared keys instead of copies.** `files.*`, `viewers.*`, `appearance.syntaxTheme` and
  `appearance.fileIcons` replace per-surface duplicates.
- **Parity test.** The schema-iterating test in settings-surfaces.md fails when a key lacks a
  palette editor, CLI round trip, MCP decision or a page consumer.

Second objection: theme.css is an unstable API. Handled: only `--cmux-<surface>-*` properties are
documented and versioned; a renamed property keeps its old name as an alias for one release.

Third objection: a sandboxed iframe renderer is slower and less capable than main-world React.
Handled: renderers are for content slots (a fenced block, a row, a preview), not for the page
frame; the measured cost is one `postMessage` round trip per slot render, batched per frame.

## 3. Inventory per surface

Columns: **Now** = current state with file:line. **St** = `cfg` (configurable and works on
cmux-next), `dev` (configurable only through the dev server or an unsent payload), `hard`
(hard-coded), `none` (does not exist), `bug`. **Target** = settings key `name: type = default`, or
the mechanism. **Live** = must apply without reopening. **Owner**: `S` this session (viewer lane),
`SL` Settings lead (schema), `RU` React UIs lead, `K` keys lead, `BR` browser lead, `ACP` ACP UI
lead, `C` coordinator decision. Every new key also needs a descriptor from SL; the owner column names
who implements the consumer.

### 3.1 Diff viewer

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | appearance | Page background color, opacity | `appearance.surfaces.diff.*` `S/CmuxNextSettings/Schema/SettingsSchema+Surfaces.swift:52-54` | cfg | keep (R55) | yes | - |
| D2 | appearance | Solid header and panel backdrop | computed `W/backdrop.ts:59-94` | hard | keep derived; `--cmux-diff-solid-bg` overridable in theme.css | yes | S |
| D3 | appearance | Terminal theme as diff theme | payload `W/appearance.ts:12-25`, fallback `:38-58`; converted `W/pierre-options.ts:207-250` | dev | Ghostty-derived theme in `cmux.page.look` (R92) | yes | S |
| D4 | appearance | Syntax theme | fixed ANSI-slot mapping `W/pierre-options.ts:256-331` | hard | `appearance.syntaxTheme: string \| {light,dark} = "terminal"` (Shiki name), shared | yes | S, SL |
| D5 | appearance | Light or dark | `themeType: "system"` `W/pierre-options.ts:37` | hard | follow the app appearance in `look.colorScheme`; no key | yes | S |
| D6 | appearance | Minimum syntax contrast | `3` `W/syntax-colors.ts:47` | hard | keep (accessibility floor) | - | - |
| D7 | appearance | Addition and deletion colors | palette slots, fallbacks `W/appearance.ts:107-110` | hard | `--cmux-diff-addition`, `--cmux-diff-deletion` | yes | S |
| D8 | appearance | Line and word background strength | 34% / 30% `W/pierre-options.ts:73-76` | hard | `--cmux-diff-line-bg-mix`, `--cmux-diff-word-bg-mix` | yes | S |
| D9 | appearance | Accent color | `#0a84ff`/`#7ab7ff` `W/styles.css:26` | hard | system accent as `--cmux-accent` in WebTheme | yes | S |
| D10 | appearance | Selection color | Ghostty `selection-background` via payload `W/appearance.ts:111-112` | dev | Ghostty-derived (R92) | yes | S |
| D11 | appearance | Code font family | payload, default `"Menlo"` `W/appearance.ts:77,155-157` | dev | Ghostty `font-family` via look (R92); override only `--cmux-diff-code-font-family` | yes (today at open only, `W/surfaces/diffSurface.tsx:66`) | S |
| D12 | appearance | Code font size | payload, default 10px `W/appearance.ts:78,114` | dev | Ghostty `font-size` via look (R92), plus page zoom commands | yes | S |
| D13 | appearance | Code line height (row density) | payload, default 20px `W/appearance.ts:79,115` | dev | derived from `appearance.density`; `--cmux-diff-line-height` | yes | S |
| D14 | appearance | UI font family | system-ui `W/styles.css:15` | hard | `--cmux-ui-font-family` from WebTheme | yes | S |
| D15 | appearance | UI font size | 12px/16px `W/styles.css:16-17` (also 11px, 13px literals `:501,1053`) | hard | follow `appearance.metrics.chromeFontSize` as `--cmux-ui-font-size` | yes | S |
| D16 | appearance | File header height | 32 `W/pierre-options.ts:18`, CSS var `:88` not read by the virtualizer | hard | from density; virtualizer reads the computed property | yes | S |
| D17 | appearance | File tree row height | 22 `W/App.tsx:3171` | hard | from density, `--cmux-diff-tree-row-height` | yes | S |
| D18 | appearance | File icon set | `"complete"` `W/file-icons.tsx:10` | hard | `appearance.fileIcons: "complete" \| "minimal" \| "none" = "complete"`, shared | yes | S, SL |
| D19 | appearance | Floating pill style | `W/styles.css:1854-1876` | hard | `--cmux-diff-pill-*` | yes | S |
| D20 | layout | Files panel side | right `W/styles.css:690,709-713` | hard | `diff.filesPanel.position: "left" \| "right" = "right"` | yes | S |
| D21 | layout | Files panel width | 252, drag-resizable, not saved `W/App.tsx:237,2079-2087` | hard | `diff.filesPanel.width: number 180-520 = 252`, written on drag end | yes | S |
| D22 | layout | Files panel shown at open | always `true` `W/App.tsx:238` | hard | `diff.filesPanel.visible: bool = true` (toolbar toggle writes it) | yes | S |
| D23 | layout | Narrow breakpoint | 520px `W/styles.css:949-981` | hard | keep | - | - |
| D24 | layout | Pill position | bottom-right `W/styles.css:1846-1853` | hard | `diff.toolbar.position: "bottomRight" \| "bottomLeft" \| "topRight" \| "hidden" = "bottomRight"` | yes | S |
| D25 | layout | Pill buttons and order | fixed `W/toolbar-model.ts:296-320` | hard | `diff.toolbar.buttons: id list = [options, find, refresh, wrap, expand, layout, files]`; hidden ones stay in the overflow menu | yes | S, SL (list kind) |
| D26 | layout | Sticky file headers | `true` `W/pierre-options.ts:34` | hard | `diff.stickyHeaders: bool = true` (advanced) | yes | S |
| D27 | behavior | Default source | last recent else `"branch"` `W/viewer-empty/DiffEmptyState.tsx:97` | hard | `diff.defaultSource: "last" \| "uncommitted" \| "staged" \| "unstaged" \| "branch" = "last"` | no | S |
| D28 | behavior | Default branch base | sidecar `status.base` `Native/DiffSidecar/src/server.rs:760-773`; per-repo memory in a ref `W/App.tsx:547` | hard | per-repo remembered base in the host store; `diff.defaultBase: string = ""` (auto) | no | S |
| D29 | behavior | Split or unified | toggle, pref `layout` `W/viewer-prefs.ts:29`, default unified `W/App.tsx:1221`; lost on cmux-next `S/CmuxNextPages/PageWebView.swift:126` | dev | `diff.layout: "unified" \| "split" \| "auto" = "unified"` | yes | S |
| D30 | behavior | Word wrap | pref `wordWrap` `W/viewer-prefs.ts:35` | dev | `diff.wordWrap: bool = false` | yes | S |
| D31 | behavior | Word-level diffs | pref `wordDiffs` `W/App.tsx:252` | dev | `diff.wordDiffs: bool = false` | yes | S |
| D32 | behavior | Line numbers | pref `lineNumbers` `W/App.tsx:250` | dev | `diff.lineNumbers: bool = true` | yes | S |
| D33 | behavior | Add/remove backgrounds | pref `showBackgrounds` `W/App.tsx:251` | dev | `diff.backgrounds: bool = true` | yes | S |
| D34 | behavior | Change indicators | pref `diffIndicators` `W/App.tsx:248` | dev | `diff.indicators: "bars" \| "classic" \| "none" = "bars"` | yes | S |
| D35 | behavior | Expand unchanged (full files) | menu row unavailable `W/toolbar-model.ts:233-238` | none | `diff.expandUnchanged: bool = false` (needs full-file host) | yes | S |
| D36 | behavior | Ignore whitespace | menu row unavailable `W/toolbar-model.ts:255-260`; no `-w` `server.rs:791-798` | none | `diff.ignoreWhitespace: "none" \| "trailing" \| "all" = "none"` | yes | S |
| D37 | behavior | Context lines | git default (no `-U`) `server.rs:791-798` | hard | `diff.contextLines: number 0-100 \| null = null` (null = git `diff.context`) | yes | S |
| D38 | behavior | External diff drivers | `--no-ext-diff` `server.rs:795` | hard | keep (runs arbitrary programs) | - | - |
| D39 | behavior | Large-diff auto-collapse | 2000 lines / 400 KiB `W/deferred-diffs.ts:11-12` | hard | `diff.autoCollapse.maxLines: number = 2000`, `diff.autoCollapse.maxBytes: number = 409600` (advanced) | yes | S |
| D40 | behavior | Generated files collapsed | `.gitattributes` + lockfile list `W/deferred-diffs.ts:3-26` | hard | `diff.autoCollapse.generated: bool = true`, `diff.autoCollapse.paths: glob list = []` | yes | S |
| D41 | behavior | Per-file collapse memory | per repo `W/collapsed-files.ts:8-23`, via bridge | dev | host store (state, not a setting) | - | S |
| D42 | behavior | Viewed marks | native only `W/viewed-files.ts:9-14`; session-only on cmux-next | none | host store per (repo, source) (diff-host S5) | - | S |
| D43 | behavior | Hide viewed files | filter not saved `W/file-filter.ts:21-23` | hard | `diff.hideViewed: bool = false` | yes | S |
| D44 | behavior | Auto refresh | manual only `W/App.tsx:941-954` | none | `diff.autoRefresh: "off" \| "onFocus" \| "live" = "onFocus"` | yes | S |
| D45 | behavior | Motion (panel springs, hunk scroll) | `W/files-panel-motion.ts:32-35`, smooth `W/App.tsx:866-868`; OS reduce motion only `W/App.tsx:2949` | hard | follow `ui.animationSpeed` and Reduce Motion via look | yes | S |
| D46 | behavior | Open file in editor | none | none | action `diffViewer.openInEditor` using `files.editor` | - | S, K |
| D47 | behavior | External link open | `window.open` `W/App.tsx:1664` | hard | through `viewers.links.webTarget` | yes | S |
| D48 | input | j, k, Ctrl-D, Ctrl-U, Ctrl-N, Ctrl-P, Shift-G, `/` | catalog actions `S/CmuxNextActions/Catalog/BrowserActionCatalog.swift:307-365` | cfg | keep under `diffViewerFocused` | yes | - |
| D49 | input | `g g`, `] f`, `[ f` | label only, no binding `BrowserActionCatalog.swift:358,372,379` | none | default bare sequences under `diffViewerFocused` (dispatcher sequences of bare keys in owning contexts) | yes | K |
| D50 | input | Toggle viewed, collapse, expand file | page commands exist `S/CmuxNextPages/PageDescriptor+Viewers.swift:18-22`, no action | none | catalog actions, bare defaults `v`, `x`, `o` | yes | K, S |
| D51 | input | Find next and previous | Cmd-G handled in page `W/find/useFindKeyboard.ts:25-49` | hard | shared catalog `find.next/previous` delivered as page commands | yes | K, S |
| D52 | input | Page command delivery | page uses classic `window.__cmuxPerformDiffViewerNavigationAction` only `W/App.tsx:2982-3028` | bug | subscribe to `cmux.page.command` (`W/pages/shared/pageStreams.ts`) | yes | S |
| D53 | content | User grammars | `<config dir>/diff/languages/` `W/diff-languages/pack.ts:1-13`; dev only | dev | one shared `<config dir>/languages/` served by the page host for diff, markdown, file viewer | yes | S |
| D54 | content | Extension to language overrides | `overrides.json` `W/diff-languages/pack.ts:9`; built-ins `W/diff-language.ts:6-28` | dev | same folder | yes | S |
| D55 | content | User stylesheet | none | none | `<config dir>/diff/theme.css` (rule 4) | yes | S |
| D56 | content | Diff sources | kinds fixed `W/diff/generated/protocol.ts:29`; host `sourceOptions` `W/toolbar-model.ts:44-53` | hard | `cmux.diff.source/1` providers listed in the source menu | yes | S |
| D57 | content | Rich previews (images, notebooks) | stubs `W/toolbar-model.ts:261-267` | none | `cmux.diff.renderer/1` + renderer registry (rule 5) | yes | S |
| D58 | privacy | Recents | recorded on every open, no off switch (diff-host.md, empty state) | hard | `viewers.recents.enabled: bool = true` + action "Clear Recents" | yes | S |
| D59 | privacy | Comments | per repo `W/comments/bridge.ts:72-85` | cfg | keep | - | - |
| D60 | scope | Per-repo settings | none | none | repo layer for `diff.defaultBase`, `diff.contextLines`, `diff.ignoreWhitespace`, `diff.autoCollapse.paths` (C decision; global first) | no | C |

Bare keys the diff viewer wants (context `diffViewerFocused`, read-only): `j k` line, `n p` and
`Ctrl-N Ctrl-P` hunk, `] f [ f` file, `g g`, `Shift-G`, `Ctrl-D Ctrl-U`, `/` find, `v` viewed,
`x` collapse, `o` open in editor, `s` split/unified, `w` wrap. Never while the find field, comment
box or jump-to-file field has focus.

### 3.2 Markdown editor and viewer

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M1 | appearance | Body font family | `markdown.font.family` `W/pages/markdown/settings.ts:154`, default system `:12` | dev | `markdown.font.family: font_family = system` | yes | S |
| M2 | appearance | Body size, weight, line height | `:155-157`, 16px/400/1.6 `:13-15` | dev | `markdown.font.size: number = 16`, `.lineHeight: number = 1.6`; weight to `--cmux-md-font-weight` | yes | S |
| M3 | appearance | Headings family, weight, color | `:158-161` | dev | `--cmux-md-heading-*` (theme.css) | yes | S |
| M4 | appearance | Heading scale | `:170-177`, defaults `:25-30` | dev | `markdown.headings.scale: number 1-3 = 2` | yes | S |
| M5 | appearance | Code font family | `markdown.code.family` `:178`, default terminal font `:31` | dev | R92: Ghostty font via look; drop the key; override `--cmux-md-code-font-family` | yes | S |
| M6 | appearance | Code sizes, line height, background | `:179-182` | dev | `--cmux-md-code-*` | yes | S |
| M7 | appearance | Syntax theme | `markdown.code.theme` `:209-218`, `W/pages/markdown/highlight.ts:37-54`; unknown names fall back silently | dev | `appearance.syntaxTheme` (shared, D4), with a diagnostic for unknown names | yes | S |
| M8 | appearance | Colors (text, link, quote, borders, table, selection, caret, task) | `markdown.colors.*` `:188-198`; link default `:42` | dev | `--cmux-md-color-*` (theme.css); remove the keys | yes | S |
| M9 | appearance | Page background | `--cmux-surface-background` of `internalPage` `W/pages/shared/pageBase.css:18` | cfg | new SurfaceKind `markdown` -> `appearance.surfaces.markdown.*` (R55) | yes | SL, S |
| M10 | appearance | Toolbar and UI font size | 13px / 12px `settings.ts:52-53` | hard | follow `appearance.metrics.chromeFontSize` | yes | S |
| M11 | appearance | Custom web fonts | blocked, `font-src 'self' data:` `S/CmuxNextPages/PageCSP.swift:28` | hard | `<config dir>/fonts/` served as a page dynamic resource | yes | S |
| M12 | appearance | Toolbar icons | glyphs `‹ ›` `W/pages/markdown/MarkdownPage.tsx:62,72` | hard | shared page icon set | - | S |
| M13 | appearance | Task checkbox look | `W/pages/markdown/styles.css:321-331` | hard | `--cmux-md-task-*` | yes | S |
| M14 | appearance | Mermaid theme | follows OS scheme `W/pages/markdown/diagrams.ts:60-62` | hard | `markdown.diagrams.theme: "auto" \| "default" \| "dark" \| "neutral" \| "forest" = "auto"` | yes | S |
| M15 | appearance | Vega colors | `#888 #444 #ccc #ddd` `diagrams.ts:106-111` | hard | derive from `--cmux-md-*` | yes | S |
| M16 | layout | Max content width | `markdown.layout.maxWidth` `settings.ts:183`, 72ch | dev | `markdown.layout.maxWidth: string = "72ch"` | yes | S |
| M17 | layout | Padding, paragraph and list spacing | `settings.ts:184-187` | dev | `--cmux-md-padding`, `--cmux-md-spacing-*` | yes | S |
| M18 | layout | Toolbar shown | `markdown.toolbar` `settings.ts:205` | dev | `markdown.toolbar.visible: bool = true` | yes | S |
| M19 | layout | Toolbar contents | fixed `MarkdownPage.tsx:51-99` | hard | `markdown.toolbar.buttons: id list = [history, name, status, mode]` | yes | S |
| M20 | layout | Outline (TOC) | none | none | `markdown.outline: "hidden" \| "left" \| "right" = "hidden"` | yes | S |
| M21 | layout | Split source and preview | none, one mode at a time `MarkdownPage.tsx:46,115-124` | none | `markdown.defaultMode` adds `"split"` | yes | S |
| M22 | behavior | Default mode | `markdown.defaultMode` `settings.ts:203-206`, at open only `W/pages/markdown/store.ts:162` | dev | `markdown.defaultMode: "rich" \| "source" \| "split" = "rich"` | no | S |
| M23 | behavior | Autosave and delay | always on, 800 ms `store.ts:70`; on hide `W/pages/markdown/main.tsx:160-163` | hard | `markdown.autosave: "off" \| "afterDelay" \| "onBlur" = "afterDelay"`, `markdown.autosaveDelay: number 100-10000 = 800` | yes | S |
| M24 | behavior | Spellcheck | rich on `W/pages/markdown/editor.ts:216`, source off `MarkdownPage.tsx:144` | hard | `markdown.spellcheck: "off" \| "prose" \| "all" = "prose"` | yes | S |
| M25 | behavior | Code block wrap | never `styles.css:393-394` | hard | `markdown.code.wrap: bool = false` | yes | S |
| M26 | behavior | Tab size (source) | 4 `styles.css:221` | hard | `markdown.tabSize: number 1-8 = 4` | yes | S |
| M27 | behavior | Write-back style | `-` bullets, `_` emphasis `editor.ts:203-212` | hard | `markdown.format.bullet: "-" \| "*" \| "+" = "-"`, `markdown.format.emphasis: "_" \| "*" = "_"` (advanced) | no | S |
| M28 | behavior | Smart quotes | none (`editor.ts:229-240`) | none | `markdown.smartQuotes: bool = false` | yes | S |
| M29 | behavior | Link-follow modifier | Cmd `editor.ts:221,260`, `linkEditing.ts:161-174` | hard | `markdown.links.followModifier: "cmd" \| "alt" \| "none" = "cmd"` | yes | S |
| M30 | behavior | Web link target | cmux browser tab `W/pages/markdown/linkRouter.ts:34-47` | hard | `viewers.links.webTarget: "cmuxBrowser" \| "system" = "cmuxBrowser"` (shared) | yes | S, BR |
| M31 | behavior | Front matter | folded `editor.ts:675-676` | hard | `markdown.frontMatter: "folded" \| "expanded" \| "hidden" = "folded"` | yes | S |
| M32 | behavior | Math | none, `<math>` dropped `W/pages/markdown/htmlPreview.ts:91` | none | `markdown.math: bool = true` (KaTeX) | yes | S |
| M33 | behavior | Diagrams | always on `editor.ts:81`, 300 ms debounce `:629` | hard | `markdown.diagrams.enabled: bool = true` | yes | S |
| M34 | behavior | Reduced motion | scroll-to-anchor only `editor.ts:302-303` | hard | follow `ui.animationSpeed` and Reduce Motion | yes | S |
| M35 | input | Cmd-S save, Cmd-K link | page listens `main.tsx:151-156`, router drops them `S/CmuxNextPages/PageDescriptor.swift:97`, `S/CmuxNextPages/PageRouter.swift:142` | bug | catalog actions `markdown.save`, `markdown.insertLink`; descriptor lists the commands | yes | S, K |
| M36 | input | Zoom Cmd-= Cmd-- Cmd-0 | actions `BrowserActionCatalog.swift:80,87,94`; page has no handler | bug | page handles zoom via `--cmux-md-zoom` | yes | S |
| M37 | input | Formatting shortcuts | Milkdown defaults `editor.ts:229-230` | hard | catalog actions (bold, italic, code, heading 1-6, list) under `markdownEditorFocused` | yes | K, S |
| M38 | input | Link popover keys | `linkEditing.ts:413-425` | hard | keep (text field focus) | - | - |
| M39 | content | Plugins and renderers | fixed `editor.ts:229-241` | hard | renderer registry slot `markdown.fence.<lang>` (rule 5) | yes | S |
| M40 | content | User stylesheet | `<config dir>/markdown/theme.css` `settings.ts:238-246` | dev | rule 4 via the generic loader | yes | S |
| M41 | content | File types | `.md .markdown .mdx .mdown .mkd` `W/pages/markdown/links.ts:17`, `W/viewer-empty/ops.ts:152` | hard | `files.associations` (shared, P29) | yes | S |
| M42 | privacy | Remote images | blocked `img-src 'self' data:` `PageCSP.swift:28` | hard | `markdown.remoteImages: "block" \| "allow" = "block"` (allow fetches through the host, no CSP widening) | yes | S |
| M43 | privacy | Relative images | file's folder only `W/pages/markdown/host.ts:113-116` | hard | keep | - | - |
| M44 | privacy | Raw HTML sanitization | allowlist `htmlPreview.ts:4-109` | hard | keep (safety) | - | - |
| M45 | privacy | Link schemes | http(s), mailto, tel, relative `links.ts:35`; `file://` inert | hard | keep; `file://` opens through `files.associations` | - | S |
| M46 | scope | Per-file or per-repo | one global section `W/pages/markdown/README.md:32-36` | none | global only (no demand found) | - | - |

Bare keys the markdown page wants: only in a read-only file or rich view without a caret
(`markdownReadOnlyFocused`): `j k`, `g g`, `Shift-G`, `/`, `[ [` `] ]` (previous and next heading).
None in edit mode.

### 3.3 Viewer empty screens

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | appearance | Typography | 13px/1.45, 17px title `W/viewer-empty/styles.css:31,51`; native file viewer 17/13/11/12 `r89:S/CmuxNextApp/FileViewer/FileViewerEmptyView.swift:29-36,99-103` | hard | follow `appearance.metrics.chromeFontSize` (web) and design typography tokens (native) | yes | S |
| E2 | appearance | Colors | `--ve-*` on `--cmux-*`, error literals `styles.css:8-17` | hard | `--cmux-empty-*`; the host surface's theme.css applies before ready (today looks apply only when ready, `W/pages/markdown/settings.ts:275`) | yes | S |
| E3 | appearance | Icons | inline SVG `W/viewer-empty/icons.tsx:5-16` | hard | shared page icon set | - | S |
| E4 | layout | Column width and top padding | `min(460px,100%)`, `max(40px,13vh)` `styles.css:28,46` | hard | `--cmux-empty-width`, `--cmux-empty-top` | yes | S |
| E5 | behavior | Recent count | web unbounded `W/viewer-empty/EmptyState.tsx:91-175`; native 8 `r89:.../FileViewerPageService.swift:21`; store 20 `r89:.../Viewers/ViewerRecents.swift:39` | hard | `viewers.recents.limit: number 0-50 = 8` (0 hides the list) | yes | S |
| E6 | privacy | Recents on, clear | none | none | `viewers.recents.enabled` (D58) + "Clear Recents" | yes | S |
| E7 | behavior | Diff source step order | fixed `W/viewer-empty/DiffEmptyState.tsx:29` | hard | `diff.defaultSource` first | yes | S |
| E8 | behavior | Drop target | markdown types only `MarkdownEmptyState.tsx:74-77` | hard | types from `files.associations` | yes | S |
| E9 | content | Title, subtitle, primary action | localized `MarkdownEmptyState.tsx:84-98` | hard | keep | - | - |

### 3.4 Folder and file picker (r89, uncommitted)

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1 | behavior | Show hidden files | only with a `.` query `r89:S/CmuxNextPalette/FolderPicker/FolderListing.swift:17`, `PaletteRanker.swift:51-53` | hard | `picker.showHidden: bool = false` | yes | S |
| P2 | input | Toggle hidden | none | none | action `picker.toggleHidden`, default Cmd-Shift-. | yes | K, S |
| P3 | behavior | Respect .gitignore | none, every entry listed `FolderListing.swift:67-82` | none | `picker.respectGitignore: bool = true` | yes | S |
| P4 | behavior | Exclude globs | none (privacy skips only `r89:.../PickerPrivacy.swift:38`) | none | `picker.exclude: glob list = [".DS_Store"]` | yes | S |
| P5 | behavior | Show all files by default | per call, not remembered `r89:.../PickerSession+Items.swift:20-28` | hard | `picker.showAllFiles: bool = false` | yes | S |
| P6 | behavior | Start folder | pane cwd else home `r89:S/CmuxNextApp/Viewers/ViewerService.swift:40-49` | hard | `picker.startFolder: "paneCwd" \| "repoRoot" \| "home" \| "last" = "paneCwd"` | no | S |
| P7 | behavior | Favorite folders | fixed `~`, `/` jumps `r89:.../FolderPickerState.swift:164-173` | hard | `picker.favorites: path list = []` | yes | S |
| P8 | behavior | Recents count | 20 `r89:.../ViewerRecents.swift:39` | hard | `viewers.recents.limit` (shared, E5) | yes | S |
| P9 | behavior | Recents only at start folder | code and comment disagree `r89:.../FolderPickerRows.swift:60-75` vs `FolderPickerState.swift:119` | bug | fix to the comment | - | S |
| P10 | behavior | Sort order | folders first, Finder order `FolderListing.swift:83-90` | hard | `picker.sort: "name" \| "modified" \| "kind" = "name"`, `picker.foldersFirst: bool = true` | yes | S |
| P11 | behavior | Fuzzy weights | `S/CmuxNextActions/FuzzyMatcher.swift:14-26` | hard | keep (shared palette, not user-meaningful) | - | - |
| P12 | behavior | Frecency | off, `frecencyKey: nil` `PickerSession+Items.swift:63` | hard | on for files (no key) | - | S |
| P13 | behavior | Result limits | `rowLimit 400` `PaletteRanker.swift:40-42`, page 2000 `FolderPickerState.swift:128` | hard | keep | - | - |
| P14 | layout | Visible rows | 10 `S/CmuxNextPalette/PaletteLayout.swift:9` | hard | `palette.visibleRows: number 6-20 = 10` (palette-wide) | yes | S, SL |
| P15 | layout | Width, row height | tunables `S/CmuxNextDesign/Tunables/MetricTunables.swift:65-70` via `appearance.density` | cfg | keep | yes | - |
| P16 | layout | Position | top, 1/6 of window `PaletteController.swift:342-355` | hard | keep | - | - |
| P17 | layout | Preview pane | none | none | `picker.preview: "off" \| "right" = "off"` (Quick Look thumbnail) | yes | S |
| P18 | appearance | Icons | one generic file symbol `PickerSession+Items.swift:54-55` | hard | per-type icons from `appearance.fileIcons` | yes | S |
| P19 | input | Next, previous | `commandPaletteNext/Previous` Ctrl-N/P `WindowActionCatalog.swift:129-137` | cfg | keep | yes | - |
| P20 | input | Enter folder, go up, Home, End, Return | keycodes `PaletteKeyMap.swift:29-35`, `PaletteModel+Keys.swift` | hard | keep palette-owned (text field focus; no bare-key bindings) | - | - |
| P21 | input | Mark (Cmd-Return) | `PaletteKeyMap.swift:31` | hard | catalog action `picker.mark`, chord rebindable | yes | K, S |
| P22 | input | Path completion | none, Tab enters the row `FolderPickerState.swift:164-167` | none | Tab completes the typed path segment, enters when unique (behavior) | - | S |
| P23 | input | Open in split | none; `where` is `tab`/`editor` `CatalogArgument.swift:205-207` | none | `where: "split"`, action `picker.openInSplit` Cmd-Shift-Return | yes | K, S |
| P24 | input | Reveal in Finder | none | none | action `picker.reveal`, chord rebindable | yes | K, S |
| P25 | behavior | Default open-in | `where: "tab"` `ViewerService.swift:84`, `AgentHandlers.swift:174` | hard | `files.openIn: "viewer" \| "editor" \| "system" = "viewer"` | yes | S, SL |
| P26 | content | File-type association | `S/CmuxNextAgentPane/AgentPaneFileOpen.swift:33-55` | hard | `files.associations: map glob -> "viewer" \| "markdown" \| "diff" \| "editor" \| "system" \| provider id = {}` | yes | S, SL (map kind) |
| P27 | content | External editor | default app for `.sourceCode` `AgentPaneFileOpen.swift:53-55` | hard | `files.editor: string = ""` (app name, bundle id or path; empty = system default) | yes | S, SL |
| P28 | input | Entry-point shortcuts | `ViewerActionCatalog.swift:14-44` (r89) | cfg | keep | yes | - |

### 3.5 Browser toolbar buttons (R80)

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | layout | Which buttons show | fixed enum `R80:S/CmuxNextBrowser/UI/BrowserToolbarButton.swift:7-13` | hard | `browser.toolbar.buttons: id list = [designMode, profile, theme, devTools]`; More always last | yes | BR |
| B2 | layout | Order | `allCases` `BrowserToolbarButtonsView.swift:36-42` | hard | list order | yes | BR |
| B3 | layout | Collapse priority | levels `BrowserToolbarButton.swift:20-26` | hard | the end of the list collapses first | yes | BR |
| B4 | layout | Hide all buttons | none | none | `browser.toolbar.buttons: []` | yes | BR |
| B5 | content | Custom buttons (any action) | none; tab bar has `ui.surfaceTabBar.buttons` `S/CmuxNextSettings/SurfaceTabBarParser.swift:24-27` | none | list accepts catalog action ids and custom `actions` ids (reuse that parser) | yes | BR |
| B6 | layout | Toolbar and omnibar position | `R80:.../BrowserChromeView.swift:201-207` | hard | keep (browser lead) | - | BR |
| B7 | appearance | Icons | `BrowserToolbarPolicy.swift:14-29`; DevTools `wrench.and.screwdriver` vs catalog `hammer` `BrowserActionCatalog.swift:102` | bug | take the symbol from the catalog action | - | BR |
| B8 | appearance | Profile icon | generic `person.crop.circle` `BrowserToolbarPolicy.swift:18` | hard | show the active profile's icon | yes | BR |
| B9 | appearance | Size, symbol size | density `R80:.../OmnibarStyle.swift:17-27` | cfg | keep (`appearance.density`) | yes | - |
| B10 | appearance | Corner radius | 8 `OmnibarStyle.swift:26` | hard | design token | - | BR |
| B11 | appearance | Active state | `selectionFill` `ChromeButtons.swift:77-78`; doc says accent `BrowserToolbarButton.swift:38` | bug | settle on one, doc and code agree | - | BR |
| B12 | input | Tooltip shortcuts | only design mode and DevTools `BrowserToolbarPolicy.swift:11` | hard | every button shows its bound shortcut | yes | BR |
| B13 | input | Theme bindable | `surfaces: [.contextMenu]` `BrowserActionCatalog.swift:251-255` | hard | add `.keyboard`, `.palette` | yes | BR, K |
| B14 | input | Design mode in palette | keyboard and menu only `BrowserActionCatalog.swift:131-135` | hard | add `.palette` | yes | BR |
| B15 | input | DevTools, design mode, profile, More keys | catalog `BrowserActionCatalog.swift:99-135`, `BrowserToolbarActionCatalog.swift:14-29` | cfg | keep | yes | - |
| B16 | behavior | More menu contents | `R80:S/CmuxNextApp/Handlers/BrowserToolbarHandlers.swift:127-146` | hard | hidden and collapsed buttons first, then fixed items | yes | BR |
| B17 | behavior | Color scheme per site | in memory `BrowserPageModes.swift:13` | hard | per-site in `SiteSettingsRegistry` (`SiteSettingsRegistry.swift:3-10`) | yes | BR |
| B18 | behavior | Zoom per site | none | none | per-site in `SiteSettingsRegistry` | yes | BR |

No bare keys: web content owns plain keys in a browser tab.

### 3.6 Native file viewer (filePreview)

There is no file viewer surface on cmux-next (`S/CmuxNextApp/MiscHandlerStrings.swift:12`); a
file opens as a browser tab on `file://` (`S/CmuxNextApp/Handlers/AgentHandlers.swift:168-190`). r89
adds only the empty view. Targets assume a `cmux.fileViewer` page on the shared page host.

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | content | The surface | none `MiscHandlerStrings.swift:12`; Save and Wrap unavailable `BrowserHandlers.swift:141` | none | `cmux.fileViewer` page (diff-host plan) | - | S |
| F2 | input | `filePreviewFocused` context | declared `S/CmuxNextActions/ActionContext.swift:26`, never set `S/CmuxNextApp/Focus/FocusEffectApplier.swift:361-364` | bug | set by the page host | yes | S, K |
| F3 | appearance | Code font and size | WebKit default | hard | Ghostty font via look (R92), page zoom | yes | S |
| F4 | appearance | Syntax theme | none | none | `appearance.syntaxTheme` (shared) | yes | S |
| F5 | appearance | Background | browser chrome surface | hard | new SurfaceKind `fileViewer` (R55) | yes | SL, S |
| F6 | appearance | User stylesheet | none | none | `<config dir>/fileViewer/theme.css` | yes | S |
| F7 | behavior | Line numbers | none | none | `fileViewer.lineNumbers: bool = true` | yes | S |
| F8 | behavior | Word wrap | Opt-Z declared, unavailable `BrowserActionCatalog.swift:264-269` | none | `fileViewer.wordWrap: bool = false` | yes | S |
| F9 | behavior | Image background | WebKit image document | hard | `fileViewer.imageBackground: "checkerboard" \| "theme" \| "black" \| "white" = "checkerboard"` | yes | S |
| F10 | behavior | Image fit | WebKit | hard | `fileViewer.imageFit: "fit" \| "actual" = "fit"` | yes | S |
| F11 | behavior | Size limit | none, whole file loads | none | `fileViewer.maxBytes: number = 10485760`, then "Open Anyway" | yes | S |
| F12 | behavior | Binary files | refused `AgentPaneFileOpen.swift:43-49` | hard | `fileViewer.binary: "refuse" \| "hex" \| "quickLook" = "quickLook"` | yes | S |
| F13 | behavior | Reload on change | none `S/CmuxNextBrowser/WebKit/WebKitTab+Navigations.swift:30-33` | none | `fileViewer.reloadOnChange: bool = true` | yes | S |
| F14 | content | Which files open here | `AgentPaneFileOpen.swift:33-50` | hard | `files.associations` (P26) | yes | S |
| F15 | content | Open in editor, Open With | `AgentPaneFileOpen.swift:53-55`, `OpenInHandlers.swift:9-38` (gated on F2) | hard | `files.editor` (P27) | yes | S |
| F16 | content | User grammars | none | none | shared `<config dir>/languages/` (D53) | yes | S |

Bare keys the file viewer wants (`filePreviewFocused`, read-only): `j k`, `g g`, `Shift-G`,
`Ctrl-D Ctrl-U`, `/`, `n` `Shift-N` (next and previous match), `w` wrap. None while the find field has
focus.

### 3.7 Pane protocol and pages (extension points)

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| X1 | extension | Router in the daemon | crate only, no caller (`react-pages.md:35`) | none | daemon hosts the router (pane-protocol.md first slice) | - | S |
| X2 | extension | Namespace list | hard-coded `catalog.rs:11-27` | hard | from installed app ids (`router/mod.rs:236-298`) | yes | S |
| X3 | extension | Page list | `S/CmuxNextPages/PageID.swift:12-15`, `S/CmuxNextApp/Pages/PageFactory.swift:12-41` | hard | manifest-driven (`PageManifest`, `src/router/ops.rs:184-226`) | yes | S |
| X4 | extension | Third-party page loading | `appPage` test-only `PageID.swift:62-72` | none | production loader for installed app pages | - | S |
| X5 | extension | Look stream | script `WebTheme.swift:50-88` | hard | `cmux.page.look` stream for every page (rule 2) | yes | S |
| X6 | extension | Page config | `documentAttributes` `S/CmuxNextPages/PageWebView.swift:74-83`; per-page `<ns>.config` ops unserved | dev | descriptor declares settings prefixes; host serves `<ns>.config` from the settings snapshot | yes | S, SL |
| X7 | extension | Page commands and keys | fixed per descriptor `PageDescriptor.swift:97` | hard | manifest declares commands and contexts; catalog actions generated; bare keys only for read-only contexts | yes | K, S |
| X8 | extension | Custom diff source | interface draft `catalog.rs:29-44`, `cmux-tui/crates/cmux-app-host/interfaces/cmux.diff.source/1.json` | none | diff page consumes `cmux.diff.source/1` | yes | S |
| X9 | extension | Custom viewer and renderer | drafts `cmux.viewer/1`, `cmux.diff.renderer/1` | none | implementers listed in `files.associations` and diff rich preview | yes | S |
| X10 | extension | Opener (types, schemes) | draft `cmux.opener/1` | none | `files.associations` values accept provider ids | yes | S |
| X11 | extension | User stylesheet for any page | agent pane only | none | generic loader; third-party `<config dir>/apps/<id>/theme.css` | yes | S |
| X12 | extension | Settings from third parties | none | none | `apps.<id>.*` reserved; manifest `contributes.settings` later | - | C |
| X13 | safety | CSP widening | first party only `PageDescriptor.swift:49-50`, `PageCSP.swift:17-29` | cfg | keep; third parties get grants, never CSP edits | - | - |

### 3.8 Agent pane (owner: ACP UI lead; inventoried here, not planned here)

| ID | Group | Item | Now | St | Target | Live | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | appearance | Colors | terminal theme `S/CmuxNextAgentPane/AgentPaneTheme.swift:14-58` -> `--agent-*` `W/agent-session/shared/theme.ts:3-25`; theme.css | cfg | keep; move to `cmux.page.look` | yes | ACP |
| A2 | appearance | Background | `appearance.surfaces.agentPane` `AgentPaneTheme.swift:63-69` | cfg | keep (R55) | yes | - |
| A3 | appearance | Transcript font | `--cv-font` system-ui 14px/22.75 `W/agent-session/conversation/conversation.css:28-32`; height estimate assumes it `acpmux/model.ts:147-148` | hard | `--agent-font-*` honored by measurement | yes | ACP |
| A4 | appearance | Mono font | `--agent-host-editor-font-family`, never set `W/agent-session/shared/styles.css:12,232` | bug | Ghostty font via look (R92) | yes | ACP |
| A5 | appearance | Composer font | 15px/22px `acpmux/styles.css:23` | hard | `--agent-composer-font-*` | yes | ACP |
| A6 | layout | Column width, density | `--cv-column: 720px` `conversation.css:30,60`; spacing `styles.css:1` | hard | `agentPane.columnWidth: number = 720`; density from `appearance.density` | yes | ACP |
| A7 | appearance | Agent marks | brand by default, `mono` unreachable `shared/AgentMark.tsx:8-15` | hard | `agentPane.agentMarks: "brand" \| "mono" = "brand"` | yes | ACP |
| A8 | behavior | Tool calls collapsed | all start closed `App.tsx:838`, `ToolRow.tsx:36`, `ToolGroupRow.tsx:30` | hard | `agentPane.toolCalls: "collapsed" \| "expanded" \| "lastExpanded" = "collapsed"` | yes | ACP |
| A9 | behavior | Edited files shown | 3 `App.tsx:302,409-418` | hard | keep | - | - |
| A10 | behavior | Diff in messages | unified, bars `conversation/EditDiff.tsx:24-30` | hard | follow `diff.layout`, `diff.indicators` | yes | ACP |
| A11 | behavior | Changes view split, wrap, tree | localStorage `DiffPanel.tsx:28-30,91-93` (lost: non-persistent store) | dev | `diff.*` keys (shared with D29-D34) | yes | ACP |
| A12 | input | Send key | Enter sends, Shift-Enter newline `Composer.tsx:300-303` | hard | `agentPane.sendKey: "enter" \| "cmdEnter" = "enter"` | yes | ACP |
| A13 | input | Plan mode key | Shift-Tab `shared/keyboard.ts:19-21` | hard | catalog action under `agentComposerFocused` | yes | ACP, K |
| A14 | input | Pane shortcuts, Search chats, permission chords | registry `AgentPaneShortcuts.swift:10-31`, `AgentActionCatalog.swift:56-68` | cfg | keep | yes | - |
| A15 | input | Permission bare keys y, a, n | answer while the prompt keeps focus `PermissionCard.tsx:8-10` | bug | violates the bare-key rule; bind only when the permission card has focus (`agentPermissionFocused`) | yes | ACP, K |
| A16 | input | Changes view j, k, n, p | handled in the page `acpmux/changes/useDiffKeys.ts:31-35` | hard | catalog actions under `agentChangesFocused` | yes | ACP, K |
| A17 | behavior | Auto-scroll | `App.tsx:705-724` | hard | keep | - | - |
| A18 | behavior | Streaming reveal | 120 ms, 120 chars/s `streamReveal.ts:16,20`; instant under Reduce Motion `:56` | hard | follow `ui.animationSpeed` | yes | ACP |
| A19 | behavior | Timestamps | gap 1 h `conversation/timestamps.ts:12,29-30` | hard | `agentPane.timestamps: "gaps" \| "always" \| "never" = "gaps"` | yes | ACP |
| A20 | behavior | Thinking display | shimmering literal "Thinking" `conversation/Thinking.tsx:3-9` | hard | `agentPane.thinking: "label" \| "text" \| "hidden" = "label"`; localize the label | yes | ACP |
| A21 | layout | Session sidebar | auto at 640px, toggle not saved `App.tsx:800,1043` | hard | `agentPane.sidebar: "auto" \| "shown" \| "hidden" = "auto"` | yes | ACP |
| A22 | behavior | Default agent | acpmux `default_harness` `cmux-tui/crates/acpmux/src/config.rs:399-400,606-608`; pane passes nil `AgentPaneSeed.swift:19-20` | hard | `agentPane.defaultAgent: string = ""` | no | ACP |
| A23 | behavior | Dictation auto-send | `layout.json` `dictation.autoSend` `acpmux/dictation.ts:23-28` | cfg | `agentPane.dictation.autoSend: bool = false`; retire `layout.json` | yes | ACP |
| A24 | behavior | Sounds, notifications on finish | none (unread flag `acpmux/direct.ts:660`) | none | `notifications.sources.agent.*` (exists) | yes | ACP |
| A25 | content | User stylesheet | `<config dir>/agent-pane/theme.css` `AgentPaneCustomization.swift:25,55-61` | cfg | generic loader (rule 4); report CSS errors | yes | ACP, S |
| A26 | content | Renderers | `registry.js` main world `App.tsx:1172-1185`, `pageHost.ts:87-95` | cfg | sandboxed registry (rule 5); main world only with `agentPane.registry.trust = "page"` | yes | ACP |
| A27 | content | layout.json | one key; `configure()` ignores its argument `App.tsx:1182-1184`; errors silent | bug | replace with `agentPane.*` keys | yes | ACP |

## 4. Counts

| Surface | Items | cfg | dev | hard | none | bug |
| --- | --- | --- | --- | --- | --- | --- |
| Diff viewer | 60 | 3 | 14 | 32 | 10 | 1 |
| Markdown | 46 | 1 | 13 | 25 | 5 | 2 |
| Empty screens | 9 | 0 | 0 | 8 | 1 | 0 |
| Picker | 28 | 3 | 0 | 17 | 7 | 1 |
| Browser toolbar | 18 | 2 | 0 | 11 | 3 | 2 |
| File viewer | 16 | 0 | 0 | 7 | 8 | 1 |
| Pane protocol | 13 | 1 | 1 | 4 | 7 | 0 |
| Agent pane (ACP) | 27 | 6 | 1 | 16 | 1 | 3 |
| Total | 217 | 16 | 29 | 120 | 42 | 10 |

## 5. Top 10 gaps a user hits first

1. Diff viewer preferences (layout, wrap, line numbers) reset on every open on cmux-next: they live
   in a non-persistent web store (D29-D34, `PageWebView.swift:126`).
2. Diff files panel is always on the right, always shown and always 252px (D20-D22).
3. Markdown Cmd-S and Cmd-K do nothing: the router drops the commands (M35).
4. Markdown autosave cannot be turned off or slowed (M23).
5. No ignore-whitespace, context lines or expand-unchanged in the diff (D35-D37).
6. No way to choose which app or viewer opens a file type, or which editor "open in editor" uses (P25-P27).
7. Diff and file viewer code font does not follow the terminal font live, and the diff UI text is
   fixed at 12px regardless of `appearance.metrics.chromeFontSize` (D11, D15).
8. Picker shows every file (no `.gitignore`, no excludes) and hides dotfiles with no toggle (P1-P4).
9. Browser toolbar buttons cannot be hidden, reordered or extended (B1-B5).
10. Markdown remote images are always blocked and web links always open in the cmux browser (M42, M30).

## 6. Slice plan, by owner, in landing order

Each slice names its owner. Red test first where behavior changes (repo rule). Key descriptors in
every slice come from SL slice 1 or a follow-up SL descriptor PR; consumers do not add keys
themselves.

### Coordinator (decisions, first)

- C1 Section and grouping: one "Viewers" section (Diff, Markdown, File Viewer, Picker groups),
  Browser > Toolbar, Agent Pane group. C2 `tier: basic | advanced` on descriptors. C3 repo-scope
  layer (D60) deferred or accepted. C4 drop the markdown color and code-font keys in favor of
  custom properties (M5, M8). C5 registry trust default `sandboxed` for the agent pane (A26).

### Settings lead (schema)

- SL1 Descriptors for `diff.*`, `markdown.*`, `picker.*`, `fileViewer.*`, `files.*`, `viewers.*`,
  `appearance.syntaxTheme`, `appearance.fileIcons`, `palette.visibleRows`; SurfaceKinds `markdown`,
  `fileViewer` (R55). New kinds `id_list` (ordered ids from a domain) and `glob_map`. Agent policy
  per key. Files: `S/CmuxNextSettings/Schema/SettingsSchema+Viewers.swift` (new),
  `Schema/SettingsSchema.swift`, `Schema/SettingDescriptor.swift`,
  `Schema/SettingsSchema+AgentPolicy.swift`, `S/CmuxNextDesign/Windows/SurfaceBackgrounds.swift`,
  `SurfaceBackgroundSetting.swift`, `Localizable.xcstrings`, `schemas/settings/settings-schema.json`
  (regenerated; also fixes the stale `layout.paneSeparation` row).
- SL2 Prefix-filtered snapshot for pages (`settings.snapshot {prefixes}` or a client-side filter of
  the snapshot) and `settings-changed` carrying keys, so the page host forwards only relevant
  changes. Files: config actor (`cmux-config` crate), `S/CmuxNextSettings/SettingsController.swift`.
- SL3 R93 palette editors for every kind (today toggles only, `S/CmuxNextPalette/PaletteSettingsSource.swift:17-20`),
  including `id_list` (reorder) and `glob_map`. Files: `S/CmuxNextPalette/SettingsPaletteProvider.swift`,
  `PaletteSettingsSource.swift`, `PaletteController+Pages.swift`.

### This session (viewer lane)

- S1 Page look stream and config: `cmux.page.look {revision, variables, settings, themeCSS}`,
  WebTheme adds `--cmux-ui-font-family`, `--cmux-ui-font-size`, `--cmux-accent`, Ghostty code font
  and palette (R92); `<ns>.config` served from SL2. Files: `S/CmuxNextPages/PageDescriptor.swift`
  (settings prefixes), `PageWebView.swift`, `PageRouter.swift`, `PageLook.swift` (new),
  `S/CmuxNextDesign/Windows/WebTheme.swift`, `W/pages/shared/pageStreams.ts`,
  `W/pages/shared/pageLook.ts` (new), `W/pages/shared/pageBase.css`.
- S2 Generic user stylesheet and languages loader: one watcher for `<config dir>/<surface>/theme.css`
  and `<config dir>/languages/`, delivered in the look stream. Files: `S/CmuxNextPages/PageUserFiles.swift`
  (new), generalize `S/CmuxNextApp/AgentPaneCustomizationWatcher.swift`, `W/pages/shared/userTheme.ts`
  (new), `W/diff-languages/host.ts`.
- S3 Diff page on settings: subscribe to `cmux.page.command` (D52); preferences become `diff.*`
  keys written with `settings.set` (D29-D34, D43); `--cmux-diff-*` properties (D7-D19); files
  panel and pill keys (D20-D25); live fonts (D11-D15). Files: `W/App.tsx`, `W/viewer-prefs.ts`
  (replaced), `W/toolbar-model.ts`, `W/styles.css`, `W/pierre-options.ts`, `W/appearance.ts`,
  `W/surfaces/diffSurface.tsx`, `W/file-icons.tsx`, `W/files-panel-motion.ts`.
- S4 Diff behavior in the sidecar: ignore whitespace, context lines, full files, auto refresh,
  auto-collapse keys (D35-D40, D44). Files: `Native/DiffSidecar/src/server.rs`,
  `W/deferred-diffs.ts`, `W/diff/generated/protocol.ts`, the diff host (diff-host.md S4).
- S5 Markdown on settings: host serves `markdown.*`; Cmd-S, Cmd-K, zoom (M35-M36); autosave,
  spellcheck, wrap, tab size, front matter, link modifier, diagrams, math, remote images
  (M14-M34, M42); outline and split (M20-M21). Files: `S/CmuxNextPages/PageDescriptor+Viewers.swift`,
  `PageCSP.swift`, `W/pages/markdown/{settings.ts,store.ts,editor.ts,main.tsx,MarkdownPage.tsx,linkRouter.ts,linkEditing.ts,diagrams.ts,styles.css,README.md}`.
- S6 Shared file routing: `files.associations`, `files.editor`, `files.openIn`,
  `viewers.links.webTarget`, `viewers.recents.*`. Files: `S/CmuxNextAgentPane/AgentPaneFileOpen.swift`,
  `S/CmuxNextApp/Handlers/AgentHandlers.swift`, `r89:S/CmuxNextApp/Viewers/{ViewerService.swift,ViewerRecents.swift}`,
  `S/CmuxNextActions/CatalogArgument.swift` (`where: split`).
- S7 Picker keys and actions (P1-P10, P12, P14, P17-P18, P21-P24), after r89 lands. Files:
  `r89:S/CmuxNextPalette/FolderPicker/{FolderListing.swift,FolderPickerRows.swift,FolderPickerState.swift,PickerSession.swift,PickerSession+Items.swift}`,
  `S/CmuxNextPalette/PaletteLayout.swift`, `r89:S/CmuxNextActions/Catalog/ViewerActionCatalog.swift`.
- S8 File viewer page (F1-F16): `cmux.fileViewer` page, sets `filePreviewFocused`. Files:
  `S/CmuxNextPages/PageDescriptor+Viewers.swift`, `PageID.swift`, `S/CmuxNextApp/Pages/PageFactory.swift`,
  `S/CmuxNextApp/Focus/FocusEffectApplier.swift`, `W/pages/file-viewer/` (new),
  `r89:S/CmuxNextApp/FileViewer/*`.
- S9 Empty screens follow the look and recents keys (E1-E8). Files: `W/viewer-empty/{styles.css,EmptyState.tsx,DiffEmptyState.tsx,MarkdownEmptyState.tsx,icons.tsx}`,
  `r89:S/CmuxNextApp/FileViewer/FileViewerEmptyView.swift`.
- S10 Sandboxed renderer registry (rule 5): iframe host, node-tree schema, slots
  `markdown.fence.<lang>`, `diff.preview.<type>`, `fileViewer.type.<uti>`. Files:
  `W/pages/shared/rendererRegistry.ts` (new), `W/pages/shared/rendererSandbox.html` (new),
  `S/CmuxNextPages/PageCSP.swift` (`frame-src` for the sandbox only).
- S11 Pane protocol wiring (X1-X11): router in the daemon, manifest-driven pages, `cmux.diff.source/1`
  consumer, opener ids in `files.associations`. Files: `cmux-tui/crates/cmux-pane-protocol/src/{catalog.rs,router/*}`,
  daemon module, `S/CmuxNextPages/{PageID.swift,PageRegistry.swift}`, `S/CmuxNextApp/Pages/PageFactory.swift`.

### Keys lead

- K1 Bare-key sequences (`g g`, `] f`, `[ [`) under read-only page contexts; contexts
  `markdownReadOnlyFocused`, `markdownEditorFocused`, `filePreviewFocused`, `agentChangesFocused`,
  `agentPermissionFocused`; a validation that refuses a bare-key binding whose context can hold
  while a text field has focus. Files: `S/CmuxNextActions/{ActionContext.swift,KeyBindingTable.swift,KeyBindingValidation.swift}`,
  `S/CmuxNextApp/Focus/KeyRouter+Context.swift`, `schemas/keybindings/keybinding-vectors.json`.
- K2 Catalog actions for page-handled keys: diff (D49-D51), markdown (M35, M37), picker
  (P2, P21, P23, P24), find next/previous. Files: `S/CmuxNextActions/Catalog/BrowserActionCatalog.swift`,
  `ViewerActionCatalog.swift`, `S/CmuxNextPages/PageDescriptor+Viewers.swift`.

### Browser lead

- BR1 `browser.toolbar.buttons` (B1-B5, B16) reusing `SurfaceTabBarParser`; tooltips (B12); catalog
  surfaces for theme and design mode (B13-B14); icon from the catalog (B7). Files:
  `R80:S/CmuxNextBrowser/UI/{BrowserToolbarButton.swift,BrowserToolbarButtonsView.swift,BrowserToolbarPolicy.swift,BrowserChromeView+Commands.swift}`,
  `S/CmuxNextSettings/SurfaceTabBarParser.swift`, `S/CmuxNextActions/Catalog/BrowserActionCatalog.swift`.
- BR2 Per-site color scheme and zoom (B17-B18). Files: `S/CmuxNextBrowser/PageInfo/Model/SiteSettingsRegistry.swift`,
  `UI/BrowserPageModes.swift`.

### React UIs lead (R82)

- RU1 Settings page renders the Viewers section and groups, the advanced disclosure (C2), editors
  for `id_list` (drag to reorder, with the hidden items listed) and `glob_map` (table). Files:
  `W/pages/settings/*`.
- RU2 "Open theme.css" and "Reveal languages folder" section actions per surface group.

### ACP UI lead (agent pane)

- ACP1 `agentPane.*` keys replace `layout.json` (A6-A8, A12, A19-A23, A27).
- ACP2 theme.css and look through S1/S2 (A1, A3-A5, A25); measurement honors font properties (A3).
- ACP3 Sandboxed registry with the `trust` opt-in (A26), on S10.
- ACP4 Bare-key fixes (A15-A16) with K1.
Files: `S/CmuxNextAgentPane/{AgentPaneCustomization.swift,AgentPaneTheme.swift}`,
`S/CmuxNextApp/AgentPaneCustomizationWatcher.swift`, `W/agent-session/acpmux/{App.tsx,pageHost.ts,dictation.ts,changes/useDiffKeys.ts}`,
`W/agent-session/conversation/*`, `W/agent-session/acpmux/README.md`.

Landing order across owners: C1-C5 -> SL1 -> S1, S2, SL2 -> S3, S5, K1, K2 -> SL3, RU1 -> S4, S6,
S7, S9 -> S8, BR1, BR2, ACP1-ACP4 -> S10 -> S11, RU2.

## 7. Decisions flagged

- `appearance.syntaxTheme` and `appearance.fileIcons` are shared keys, not per-surface keys. A user
  who wants a different syntax theme in markdown than in the diff cannot have it; the trade-off buys
  one place to change it.
- The markdown dev section's color and code-font keys are removed in favor of custom properties
  (sprawl budget and R92). That breaks no shipped user: the section never had a cmux-next host.
- Bare-key bindings require dispatcher support for bare sequences in owning contexts (K1). Until
  K1 lands, `g g` and `] f` stay unbound (today's state).
- The renderer sandbox costs one message round trip per slot render. Main-world renderers stay
  possible only with an explicit trust setting.
- Per-repo settings are deferred to the coordinator (D60); nothing in this plan needs them to ship.
