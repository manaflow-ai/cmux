# Lane: misc

## Active streams
- Window system (lane 20): one WindowKind registry + WindowKit.install for every window, one surface background token, one keyboard table per kind (plans/cmux-next/windows.md); then transparency controls in Settings.



## Landed
- 2026-10-03 (this commit) settings: transparency audit (lane 20). Opacity slider + Material menu rows, cmux.json appearance.backgroundOpacity/backgroundBlur over Ghostty background-opacity/background-blur, live apply all present; added WindowBackgroundLiveTests (SettingsController write repaints every open main window: tint alpha, isOpaque, CGS blur radius), Material help + docs/mdm regen. Both keys need agentSettable: true once the catalog lane adds the flag.
- 2026-10-02 (this PR) actions/control: catalog action `palette.open {scope?, query?}` (CLI `palette open`, MCP offered, refused without focus); socket methods `palette.scopes {}` and `palette.query {scope, query?, limit?}` (read-only, headless ranking like the palette). CLI request in nx-worker/cli-requests/palette-scopes.md (lane 11 lead)
- 2026-10-02 (this PR) palette: PaletteModel runs on PaletteNavReducer (navigation, query per level, selection memory and stale-batch handling are the reducer's; the model keeps one PageState per level and runs effects). New: PalettePageSpec.scope, PaletteItem.enters/drills, PaletteSources.scopes (PaletteScopeContribution), PaletteController.show(scope:), Debug Settings palette.scopeChip|scopeEntry|itemActions. Behavior: a page opened by a shortcut (Cmd-Shift-A) sits above the root (Backspace shows the full palette, Esc still closes); Tab enters a keyword scope, a scope row or a drill before it opens the Actions menu; Shift-Tab leaves a scope. Search Tabs is scope `tabs` (lane 11 lead)
- 2026-10-03 3cf3ecdc6c3 + fe8178428ee app: ActionRegistry.keyWindowRoute (KeyWindowRoute run/disabled) asked before availability/confirmation/handler and by menu validation; StandaloneWindowRule (interim, replaced by the window table); debug.window_snapshot renders own windows without Screen Recording (lane 20)



- 2026-10-02 (this push) agent pane borders contract, part 2: under `data-borders="none"` the task checkbox loses its ring and shows as the check fill (`:root[data-borders="none"] .cv-checkbox`), and the changes view's scope pill and toolbar ring is a variable, `--acpmux-pill-edge` (transparent under none). Content rules stay under none on purpose (Lawrence, 2026-10-02): the "Worked for" divider and Markdown rule (`--cv-rule`), table rules, the quote bar (borders agent)
- 2026-10-01 (this push) themes: default terminal theme = Ghostty's Apple System Colors / Apple System Colors Light (`GhosttyRuntime.defaultThemeSpec`, loaded before the user's Ghostty files; their theme or colors win), live light/dark on every surface (ghostty_surface_set_color_scheme), reloadConfig keeps the applied variant, `debug.appearance` (DEBUG, app-only appearance override), `scripts/cmux-next/default-theme-e2e.py`; onboarding agent told to preselect "Apple System (follows appearance)" (themes agent)



- 2026-10-03 (this commit) coderouter: machine credentials (VM-bound route token, chatmux token, crk_ key) get no account rights; resolveCoderouterControlContext refuses them (403 machine_token_cannot_manage_accounts); plans/cmux-next/coderouter.md and web/services/coderouter/README.md updated (Lawrence item 8) (app platform lead)
- 2026-10-03 actions (catalog lane): action-surfaces.json rows carry `palette_section` (id, title_key, title_table, English title, order), generated from ActionCategory (paletteSectionID/Order, titleKey/Table; the palette reads the same) and covered by exportIsFresh. GPUI and cmux-browser take palette sections from this file.
