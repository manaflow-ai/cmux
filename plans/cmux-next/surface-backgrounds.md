# Per-surface background overrides (Lawrence R55): proposal

Status: PROPOSAL from lane 20 v2 for the coordinator and the Settings lead.
Nothing here is built yet. R48 (one background everywhere by default) is
built: see windows.md, "Pane fill and cards".

## Rule

Every surface shows the window's one backdrop by default (material, tint,
`background-opacity`, `background-blur`). A user may override one surface.
An override is a color with its own opacity; it is painted by the same
owner that paints the default today, from one resolver, never by a view
on its own.

## Schema rows (cmux.json, `appearance.surfaces.<surface>`)

One object per surface, every field optional; an absent object is the
default (the shared backdrop):

```json
"appearance": {
  "surfaces": {
    "sidebar":     { "color": "#1e1e2e", "opacity": 0.9 },
    "tabBar":      { "color": "#181825" },
    "terminal":    { "opacity": 0.7 },
    "agentPane":   {},
    "settings":    {},
    "newTabPage":  {},
    "home":        {},
    "browserChrome": {},
    "docks":       {}
  }
}
```

- `color`: CSS hex or a theme token name (`surface`, `chrome`, `elevated`);
  default the surface token.
- `opacity`: 0...1; default the window's `appearance.backgroundOpacity`.
- Surfaces: `sidebar`, `tabBar`, `terminal`, `agentPane`, `settings`,
  `newTabPage`, `home`, `browserChrome`, `docks`. (Chromium page content is
  not a surface: a page paints itself.)

Settings UI: Appearance > Surfaces, one row per surface with "Same as
window" (default), a color well and an opacity slider; en + ja + every
check-l10n language. Palette, CLI, MCP and socket get it through the
normal settings path (`app settings set appearance.surfaces.sidebar.color
...`), no new verbs.

## Mechanism

- `SurfaceKind` enum (CmuxNextDesign) and `ThemeTokens.fill(for:
  SurfaceKind) -> ThemeRGB?`: nil means "show the backdrop" (today's
  behavior); a value is painted over the backdrop by the surface's owner.
- Owners: sidebar (WindowSidebarPanelView), tab bar (strip), terminal
  (PaneContentView content host for terminal tabs plus the Ghostty
  default background), agent pane and new tab page (`AgentPaneTheme`
  `pageBackground`), Settings (SettingsStyle/WindowSurfaceView), Home
  (`Palette.paneFill` for Home), browser chrome (BrowserChromeView), docks.
- `Palette.paneFill` becomes `Palette.fill(.surface)`; `cardFill` stays a
  tint over whatever the surface shows.

## Tests

- Schema: round trip, invalid color and opacity diagnostics, retired keys.
- Resolver: every `SurfaceKind` x {no override, color, opacity} at window
  opacity 1.0/0.8/0.5.
- Live: `background-match-e2e.py --overrides` sets each override and checks
  the overridden region alone changed.

## Decisions needed

1. DECISION: the sidebar inset panel (Leo's `stripStep`, 2026-10-03) stays
   a designed step or follows R48? RECOMMEND: make it the `sidebar`
   override's shipped default ("step") so R48 holds for every other surface
   and the user can set "Same as window".
2. DECISION: the key name `appearance.surfaces`. RECOMMEND it: it groups
   with `appearance.backgroundOpacity` and `backgroundBlur`.
