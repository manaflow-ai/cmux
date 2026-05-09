# zero-native cmux prototype

This is a standalone prototype for a cmux-style workbench built on
`vercel-labs/zero-native`.

The prototype keeps the terminal boundary native: terminal panes are modeled as
Ghostty host slots backed by the Ghostty C API contract from `../../ghostty`.
Browser panes run inside the Zero Native Chromium/CEF backend.

## Run

Requires Zig 0.16 or newer.

```bash
./scripts/setup.sh
zig build run
```

Use `-Dweb-engine=system` to compare against WKWebView. Chromium is the default.

## Test

```bash
zig build test -Dplatform=null -Dzero-native-path=/tmp/zero-native
```

Pass `-Dzero-native-path=<path>` if your Zero Native checkout is elsewhere.

## Scope

This is an experiment, not part of the shipping cmux app target. The next hard
step is adding native pane slots to Zero Native's AppKit host so a live
Ghostty `NSView` can be mounted beside CEF browser views in the same window.
