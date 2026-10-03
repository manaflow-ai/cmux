# Lane: misc

## Active streams



## Landed



- 2026-10-02 (this push) agent pane borders contract, part 2: under `data-borders="none"` the task checkbox loses its ring and shows as the check fill (`:root[data-borders="none"] .cv-checkbox`), and the changes view's scope pill and toolbar ring is a variable, `--acpmux-pill-edge` (transparent under none). Content rules stay under none on purpose (Lawrence, 2026-10-02): the "Worked for" divider and Markdown rule (`--cv-rule`), table rules, the quote bar (borders agent)
- 2026-10-01 (this push) themes: default terminal theme = Ghostty's Apple System Colors / Apple System Colors Light (`GhosttyRuntime.defaultThemeSpec`, loaded before the user's Ghostty files; their theme or colors win), live light/dark on every surface (ghostty_surface_set_color_scheme), reloadConfig keeps the applied variant, `debug.appearance` (DEBUG, app-only appearance override), `scripts/cmux-next/default-theme-e2e.py`; onboarding agent told to preselect "Apple System (follows appearance)" (themes agent)



- 2026-10-03 (this commit) coderouter: machine credentials (VM-bound route token, chatmux token, crk_ key) get no account rights; resolveCoderouterControlContext refuses them (403 machine_token_cannot_manage_accounts); plans/cmux-next/coderouter.md and web/services/coderouter/README.md updated (Lawrence item 8) (app platform lead)
