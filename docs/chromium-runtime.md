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

Debug builds only: **Debug → Debug Windows → Chromium Browser (Experimental)…** opens a window with an omnibar (back/forward/reload run through JavaScript history APIs — the wire protocol has no native history calls yet), a loading indicator, and a DevTools toggle.

## Integration shape

`Packages/macOS/CmuxChromium` owns the engine domain:

- `ChromiumRuntimeLocator` / `ChromiumRuntimeBundle` / `ChromiumRuntimeManifest` — find and validate installed runtimes
- `ChromiumRuntime` — dlopens the dylib and pins the runtime thread (the OWL API is thread-affine; all calls and event delivery happen on the thread that ran `owl_fresh_mojo_global_init`)
- `ChromiumSession` — one Content Shell process: navigation, input, JavaScript, DevTools, capture, plus an `AsyncStream` of events
- `ChromiumWebView` — AppKit view hosting the `CALayerHost` and forwarding NSEvents as Blink input
- `ChromiumBrowserModel` — `@Observable` projection of URL/title/loading/compositor state

The runtime cannot be unloaded once started; cmux keeps a single `ChromiumRuntime` per process. Known limitations: no native back/forward/stop, no popup-menu/file-picker surface hosting yet (the protocol exposes them; the view does not consume surface-tree events), and key input uses a best-effort Windows key-code translation.
