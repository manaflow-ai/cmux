# zero-native cmux prototype

This is a standalone prototype for a cmux-style workbench built on
`vercel-labs/zero-native`.

The prototype keeps the terminal boundary native: the window is an AppKit split
owned by the Zero Native host, with a live Ghostty `NSView` surface beside a
Chromium CEF browser view. Chromium owns browser content only.

The Ghostty side loads the normal Ghostty config files plus cmux's App Support
config fallback (`com.cmuxterm.app/config.ghostty` or `config`). The Chromium
side has buttons for an internal DevTools pane and a separate DevTools window.
Both are normal CEF browser views backed by CEF remote debugging, so they can
stay open independently.

## Run

Requires Zig 0.16 or newer.

```bash
./scripts/setup.sh
zig build run
```

Use `-Dweb-engine=system` to compare against WKWebView. Chromium is the default.
`setup.sh` applies the local CEF startup and native shell patches before
installing the CEF runtime. The verified path is `zig build run`; packaging the
Chromium build as a cmd-clickable `.app` still needs Zero Native helper bundle
work.

## Test

```bash
zig build test -Dplatform=null -Dzero-native-path=/tmp/zero-native
```

Pass `-Dzero-native-path=<path>` if your Zero Native checkout is elsewhere.

## Scope

This is an experiment, not part of the shipping cmux app target. The current
path runs a live Ghostty surface through `ghostty_surface_new` in the native
AppKit host while CEF is mounted only into the browser pane.
