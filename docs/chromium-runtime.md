# OWL Chromium runtime (experimental)

cmux can embed a Chromium engine — the "OWL Chromium runtime" — as an experimental alternative to the WebKit-based browser. The runtime is built by [manaflow-ai/chromium](https://github.com/manaflow-ai/chromium) from the pinned [manaflow-ai/chromium-src](https://github.com/manaflow-ai/chromium-src) fork and published as GitHub releases.

## What a runtime is

One extracted release archive:

- `Content Shell.app` (+ GPU/Renderer helper apps) — the browser processes, one launched per session
- `libowl_fresh_mojo_runtime.dylib` — the embedder library cmux `dlopen`s (never links)
- `owl-runtime-manifest.json` — source repo/ref/commit and CI run metadata

The dylib exposes the C API from `fresh_owl/owl_fresh_mojo_runtime.h` (vendored in `Packages/macOS/CmuxChromium/Sources/COwlFreshRuntime/include/`). It launches Content Shell out-of-process, drives it over Mojo IPC, and reports the GPU compositor's `CAContext` ID so cmux can composite web content zero-copy through a `CALayerHost`.

## Install a runtime

```bash
scripts/fetch-chromium-runtime.sh            # newest owl-chromium-* release
scripts/fetch-chromium-runtime.sh <tag>      # specific release tag
```

Runtimes install under `~/Library/Application Support/cmux/chromium-runtime/<tag>/`; cmux uses the most recently modified valid runtime. To use a local build instead, set `CMUX_CHROMIUM_RUNTIME_DIR` to a directory with the layout above.

## Try it

Set `browser.engine` to `chromium` (Settings → Browser → Browser Engine, or `"browser": { "engine": "chromium" }` in `cmux.json`; default `webkit`) to render newly created cmux browser surfaces with the embedded Chromium engine instead of WebKit. Existing surfaces keep the engine they were created with; see [`docs/configuration.md`](./configuration.md#browserengine).

**File → New Chromium Browser Window (Experimental)** (all build configurations) also opens a standalone window with an omnibar (back/forward/reload run through JavaScript history APIs — the wire protocol has no native history calls yet), a loading indicator, and a DevTools toggle.

## Integration shape

`Packages/macOS/CmuxChromium` owns the engine domain:

- `ChromiumRuntimeLocator` / `ChromiumRuntimeBundle` / `ChromiumRuntimeManifest` — find and validate installed runtimes
- `ChromiumRuntime` — dlopens the dylib and pins the runtime thread (the OWL API is thread-affine; all calls and event delivery happen on the thread that ran `owl_fresh_mojo_global_init`)
- `ChromiumSession` — one Content Shell process: navigation, input, JavaScript, DevTools, capture, plus an `AsyncStream` of events
- `ChromiumWebView` — AppKit view hosting the `CALayerHost` and forwarding NSEvents as Blink input
- `ChromiumBrowserModel` — `@Observable` projection of URL/title/loading/compositor state

The runtime cannot be unloaded once started; cmux keeps a single `ChromiumRuntime` per process. Known limitations: no native back/forward/stop signal (buttons stay enabled and route through JS history shims), and key input uses a best-effort Windows key-code translation.

## Status

The `browser.engine` setting has shipped. Working end-to-end on Chromium surfaces: browsing/navigation (omnibar, back/forward/reload via JS shims, URL/title mirroring), native `<select>` dropdown menus, native file-upload pickers, screenshots (toolbar button + `cmux browser screenshot` automation, via the OWL capture API), and DevTools toggling. Runtime-missing and mid-session crash both fall back gracefully (new surfaces open as WebKit with a notification; a live surface shows a disconnected banner with Reload-to-restart).

Not yet supported on Chromium surfaces: downloads, find-in-page (⌘F shows an "unsupported" notification on Chromium surfaces), `window.open`/popups, PDF rendering, passkeys, SSL interstitial prompts, media/camera-permission reporting, and persistent per-profile cookie storage (each Chromium session currently gets a fresh scratch user-data directory, so cookies do not survive reload/restart or share cmux's WebKit profile system).
