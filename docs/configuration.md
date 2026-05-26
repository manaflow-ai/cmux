# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

## `app.confirmQuit`

Controls when cmux asks before quitting:

- `always`: show the quit confirmation on Cmd+Q or app quit.
- `dirty-only`: show it only when a workspace has a terminal or panel that reports close confirmation is needed.
- `never`: quit immediately.

Default: `always` for stable and nightly builds. DEV builds always behave as `never`, regardless of the file setting, so tagged development builds can be replaced without a full-screen quit dialog.

The older boolean `app.warnBeforeQuit` still works as a fallback when `app.confirmQuit` is not set. `true` maps to `always`; `false` maps to `never`.

## Ghostty sidebar theme keys

cmux also reads cmux-specific sidebar color keys from Ghostty config files and theme files. Values use Ghostty-style hex colors, and can use `light:<hex>,dark:<hex>` pairs where noted.

- `sidebar-background`: sidebar material tint color. Supports light/dark pairs.
- `sidebar-tint-opacity`: sidebar tint opacity, clamped from `0` to `1`.
- `sidebar-selection-background`: selected workspace background. Supports light/dark pairs.
- `sidebar-selection-foreground`: selected workspace text color. Supports light/dark pairs.
- `sidebar-foreground`: default workspace title color. Supports light/dark pairs.
- `sidebar-muted-foreground`: secondary workspace detail color. Supports light/dark pairs.
- `sidebar-border-color`: sidebar divider and selected-row border color. Supports light/dark pairs.
- `sidebar-accent-color`: accent color for progress, drop indicators, and default unread badges. Supports light/dark pairs.
- `sidebar-notification-badge-background`: unread badge background. Supports light/dark pairs.

`sidebar-notification-badge-color` is accepted as an alias for `sidebar-notification-badge-background`.
