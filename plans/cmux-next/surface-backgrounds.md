# Per-surface background overrides (Lawrence R55)

Status: BUILT (lane 20 v3). R48 (one background everywhere by default)
stays the default: see windows.md, "Pane fill and cards". The row shape
below is the one the Settings lead and the coordinator agreed; it replaces
the first proposal (one object per surface, theme token names).

## Rule

Every surface shows the window's one backdrop by default (material, tint,
`background-opacity`, `background-blur`). A user may override one surface.
An override is a color with its own opacity; it is painted by the same
owner that paints the default today, from one resolver, never by a view
on its own.

## Schema rows (cmux.json)

24 leaf rows, `appearance.surfaces.<surface>.color` and
`appearance.surfaces.<surface>.opacity`, for `sidebar`, `tabBar`,
`terminal`, `agentPane`, `settings`, `newTabPage`, `home`,
`browserChrome`, `docks`, `diff`, `markdown`, `editor` (`SettingsSchema+Surfaces.swift`). An absent key
is the default. Section appearance, group `settings.group.surfaces`
("Surfaces"), titles `settings.appearance.surfaces.<surface>.color|opacity`,
agent-settable, not kept on Reset All.

- `color`: kind `color` (`#RRGGBB[AA]`), default null, label
  `settings.default.sameAsWindow` ("Same as window"). No theme token names.
- `opacity`: kind `number`, 0...1 step 0.05, unit fraction, default null,
  label `settings.default.windowOpacity` ("Window opacity": follows
  `appearance.backgroundOpacity`).

The CLI, MCP and palette need no new code:
`cmux settings set appearance.surfaces.sidebar.opacity 0.9`.

## Mechanism

- `SurfaceKind` and `SurfaceBackgrounds` (CmuxNextDesign) hold the
  overrides; `CmuxConfigSnapshot.surfaceBackgrounds` parses them
  (diagnostics for bad values, unknown surfaces and fields).
  `TerminalThemeSetting` sets them on `ThemeScope.app`
  (`setSurfaceBackgrounds`), which repaints every scope, so owners update
  live in their theme hooks.
- One resolver, `SurfaceBackgrounds.fill(for:tokens:)`: nil without an
  override (the owner keeps its R48 paint). With a color: that color at the
  override's opacity (else the window's) times its own alpha, painted over
  the window's backdrop. With only an opacity: the theme background at the
  alpha that makes the surface cover the backdrop exactly that much. The
  window's tint is under every surface, so a surface can be more opaque
  than the window, never less (an opacity at or below the window's paints
  nothing). `Palette.surfaceOverride(_:)`, `Palette.fill(for:default:)` and
  `Palette.opaqueFill(for:base:)` are the only readers.
- Owners: sidebar (`SidebarContainerView` clip layer), tab bar
  (`PaneContentView` paints its strip), terminal (`TerminalHostView`; the
  surfaces then draw a transparent default background in every window,
  `GhosttyRuntimeSurfacePolicy`), agent pane and new tab page
  (`WebTheme(surface:)` paints the document root once; the bridge's page
  colors are clear so nothing stacks), Settings (`SettingsPaneHostingView`),
  Home (`HomeThemePalette`), browser chrome (`BrowserChromeView` toolbar),
  docks (docked column panes, `PaneHostView.isDocked`, and the overlay
  backdrop's opaque fill), diff viewer (its host passes
  `WebTheme(surface: .diff)`; the viewer reads `--cmux-surface-background`,
  webviews/src/backdrop.ts, so it has its own override, not its host's),
  markdown and code editor pages (their hosts pass `surface: .markdown` and
  `surface: .editor`, diff-host S6 and S7).

## Limits

- A surface can not be more see-through than the window (see above).
- Docks: in an opaque window a docked pane's content paints the window
  color over the dock fill, so the override shows only where the pane is
  clear (its tab strip, a see-through window).
- The Settings window (not the page tab) keeps the window's backdrop.
- Terminal with Ghostty `background-opacity-cells = true`: the surfaces keep
  their opaque default background in an opaque window (a forced 0 would
  erase explicit cell colors), so the terminal override does not show there.
- Opacity-only terminal override at or below the window opacity: the
  terminal draws transparent and the pane's surface color shows, which can
  differ from a terminal-scope theme's own background.
- Web pages: WebKit's under-page (overscroll) area stays clear, so in an
  opaque window it shows the window color, not the override.

## Tests

- Schema: round trip, invalid color and opacity diagnostics, retired keys.
- Resolver: every `SurfaceKind` x {no override, color, opacity} at window
  opacity 1.0/0.8/0.5.
- Live: `background-match-e2e.py --overrides` sets each override and checks
  the overridden region alone changed.

- Diff viewer: cmux-next has no native host for the diff viewer yet
  (BrowserHandlers marks the diff actions unavailable). The row, the
  resolver and `WebTheme(surface: .diff)` are ready; the host that lands
  must pass `surface: .diff`.

## Decisions

1. Sidebar default: null, the same as the window (R48). The old inset step
   is only a user choice (`appearance.surfaces.sidebar.color`).
2. Key name `appearance.surfaces` (agreed).
