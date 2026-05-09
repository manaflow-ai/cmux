# zero-native cmux prototype

This is a standalone prototype for a cmux-style workbench built on
`vercel-labs/zero-native`.

The prototype keeps the terminal boundary native: the window is an AppKit split
owned by the Zero Native host, with a native Ghostty host slot beside a Chromium
CEF browser view. Chromium owns browser content only.

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

This is an experiment, not part of the shipping cmux app target. The next hard
step is replacing the native placeholder slot with a live Ghostty `NSView`
created through `ghostty_surface_new`.
