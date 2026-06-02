# OWL render fixture

This verifier is the first visual gate for the OWL effort. It launches a Chromium host executable on macOS, renders deterministic HTML fixtures, writes PNG artifacts, and checks pixel colors in the captured images.

`OwlLayerHostVerifier` is the current first architecture gate. Swift creates an `OwlBrowserRuntime` from `OwlBrowserCore`, launches Content Shell through Mojo, waits for Chromium to publish a browser-process portal `CAContext` id over Mojo, hosts that id in a native `CALayerHost`, screenshots the Swift-owned host window, and checks the pixels. `OwlBrowserCore` is no longer shaped around `dlopen`: it has a reusable `OwlBrowserRuntime` protocol, an `OwlCBrowserRuntime` implementation that consumes typed C-ABI symbols, and an `OwlLinkedBrowserRuntime` entry point for app builds that link Chromium runtime symbols directly. The dynamic-library loader now lives only in the verifier executable as a compatibility adapter for the current AWS Chromium build. Swift host requests go through generated transport and pipe binding types from `Mojo/OwlFresh.mojom`: `OwlFreshSession` owns lifetime and client binding, while `OwlFreshProfile`, `OwlFreshWebView`, `OwlFreshInput`, `OwlFreshSurfaceTreeHost`, and `OwlFreshNativeSurfaceHost` own their respective browser surfaces. The verifier no longer uses the old generic `interface + method + JSON` invoke bridge. Generated `MojoPipeBindings` now forward typed pending-handle bind calls for `SetClient` and `Bind*`, then forward typed runtime calls such as resize, key input, surface capture, and popup acceptance. `Scripts/run-layer-host-fixture-verifier-gui.sh` uses a Chromium-owned layer fixture context to prove the Mojo plus native display plumbing. `Scripts/run-layer-host-verifier-gui.sh` uses the real Chromium compositor portal and runs a deterministic canvas fixture plus `https://example.com/` by default. Set `OWL_LAYER_HOST_INPUT_CHECK=1` to also verify real mouse/key input changes web content from `OWL_INPUT_READY` to `OWL_INPUT_CLICKED`, type into a form field, check a checkbox, click submit, verify Command, Option, Control, and Shift modifier key delivery, scroll to a specific numbered content row with a Mojo wheel event, exercise text editing plus selection replacement semantics, and publish native popup surfaces through the Mojo surface tree. Set `OWL_LAYER_HOST_RESIZE_CHECK=1` to verify resize-small and resize-roundtrip by resizing both Chromium web contents and the Swift `CALayerHost` window.

## Current status

The real compositor path is Mojo plus Chromium-owned `CAContext` plus Swift `CALayerHost`. It does not use Unix sockets or remote debugging. The current Swift shape has an `OwlBrowserCore` library for the runtime protocol, C-ABI symbol-table bridge, direct linked-symbol runtime entry point, session events, generated bind graph ownership, and typed browser commands; `OwlLayerHostVerifier` is now a client that owns the dynamic-library compatibility adapter, AppKit hosting, screenshots, fixture orchestration, and artifact reporting. The current Chromium source of truth is the full fork `https://github.com/manaflow-ai/chromium-src` at branch `feat/owl-fresh-host`, commit `7523a3a72320b403d509860f8ffaec9ac20d150e`. The retained checkpoint patch adds `fresh-owl-hosted-frame-pump`, a scoped Owl switch that maps hosted surfaces into Chromium's existing renderer, root compositor, and GPU frame-pump settings without passing the broad `--disable-frame-rate-limit` command-line switch.

The current visual gates are intentionally small but behavioral: example.com, deterministic canvas, click, form typing, modifier keys, resize-small, resize-roundtrip, `CALayerHost` detach/reattach, host-window hide/show, surface scale propagation into hosted layers, crash/restart recovery, scroll, text-edit selection replacement, widget controls, a browser-default `<select>` with no select CSS, collapsed `<select>` popup publication, right-click context menu publication, and live Google search-box typing. `Scripts/run-layer-host-focused-suites-gui.sh` is the default broad gate: it first verifies the checked-out Chromium tree matches `chromium-patches/aws-m1-ultra-verified-owl-host.json`, then splits the checks into focused render, input, resize, lifecycle, scale, recovery, scroll-text, widgets, and Google batches, writes one artifact directory per suite, and emits a screenshot checklist at `artifacts/layer-host-focused-gui-latest/focused-suites.txt`. The old full all-target run is still useful as a stress test, but it is not the default pass/fail gate because it is flaky after many sequential sessions.

## Next gates

1. Split the fork commit into smaller production commits by subsystem: Mojo runtime, content shell host, LayerHost portal, input/native surfaces, DevTools.
2. Build release artifacts from the fork commit and make the local dogfood app link those artifacts through `OwlLinkedBrowserRuntime`.
3. Promote the focused-suite runner to CI on the AWS Mac so each suite reports its own summary and visual artifact bundle.
4. Add real browser-surface coverage for permission prompts, authentication prompts, and other separate native or `RenderWidgetHostView` surfaces by wiring those browser surfaces into the Mojo surface tree. Do not represent those as ordinary HTML fixtures.
5. Add Chrome-browser-only coverage, including extension bubbles and macOS color chooser, when the host moves beyond content shell. The current content shell path does not expose those as real macOS browser delegate surfaces.
6. Add lifecycle coverage for device scale changes across displays and cross-display moves.
7. Continue moving verifier-only behavior out of `OwlBrowserCore`, keeping screenshots, pixels, and fixture HTML in the verifier while the library owns reusable browser sessions.

`OwlLayerHostSelfTest` is the smallest local rendering gate. Direct mode draws deterministic red, green, blue, and text layers into a normal Swift layer-backed `NSWindow`, proving the window capture environment. Layer-host mode creates a private `CAContext` in Swift, draws the same layers into it, hosts that context in the same Swift `CALayerHost` window path, screenshots the window, and checks the pixels. This isolates whether `CAContext` plus `CALayerHost` plus screenshot capture works before involving Chromium.

On the AWS Mac, visual LayerHost checks must run from the logged-in Aqua bootstrap, not as direct SSH children. SSH-launched windows show up in `CGWindowList`, but WindowServer can return black screenshots. Use `Scripts/run-layer-host-self-test-gui.sh` for the direct plus same-process `CAContext` gates, `Scripts/run-layer-host-fixture-verifier-gui.sh` for the Chromium-owned fixture gate, and `Scripts/run-layer-host-verifier-gui.sh` for the real Chromium compositor gate.

Run on the AWS M1 Ultra host:

For the native Swift display-path gate:

```bash
cd ~/cmux-owl-render-fixture
./Scripts/run-layer-host-self-test-gui.sh
```

Artifacts are written to `artifacts/layer-host-self-test-gui-latest/`.

For the Chromium-owned fixture gate:

```bash
cd ~/cmux-owl-render-fixture
./Scripts/run-layer-host-fixture-verifier-gui.sh
```

Artifacts are written to `artifacts/layer-host-fixture-gui-latest/`.

For the real Chromium compositor gate:

```bash
cd ~/cmux-owl-render-fixture
./Scripts/run-layer-host-verifier-gui.sh
```

Artifacts are written to `artifacts/layer-host-gui-latest/`.

For the real Chromium compositor plus input gate:

```bash
cd ~/cmux-owl-render-fixture
OWL_LAYER_HOST_INPUT_CHECK=1 ./Scripts/run-layer-host-verifier-gui.sh
```

The input run writes before/after PNG pairs for the click, form, modifier,
resize-small, resize-roundtrip, scroll, and text-edit fixtures. With
`OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1`, it also writes post-input Mojo
surface captures and DOM-state JSON for each input fixture. Set
`OWL_LAYER_HOST_ONLY_TARGETS=scroll-fixture,text-edit-fixture` to run a smaller
visual batch; every run writes `generated-transport-report.html` plus
per-capture generated transport trace JSON.

For the focused broad gate:

```bash
cd ~/cmux-owl-render-fixture
./Scripts/run-layer-host-focused-suites-gui.sh
```

The focused runner executes eight separate GUI-launched batches by default:

- `render`: example.com plus deterministic canvas
- `input`: click, text input, form submit, and modifier keys
- `resize`: resize-small and resize-roundtrip
- `lifecycle`: detach/reattach the primary `CALayerHost`, hide/show the Swift host window, then verify edge coverage
- `scale`: verify Chromium surface scale is applied to hosted `CALayerHost` contents scale, then verify edge coverage
- `recovery`: crash the active Content Shell host, observe Mojo disconnect, then start a new session and verify a fresh Swift-hosted `CALayerHost` screenshot
- `file-picker`: native file picker surface publication, file selection, cancellation, and DOM state verification
- `scroll-text`: wheel scrolling and text-edit selection replacement

It also has two optional real-world or widget suites:

- `widgets`: browser-default `<select>` selection, styled fixture `<select>` selection, right-click `contextmenu` delivery, and color input click/focus coverage
- `google`: visit Google and type into the live search box

The `widgets` suite is intentionally deterministic. It verifies that widget-shaped DOM controls receive Mojo-routed input through the hosted Chromium surface, and that native popup-shaped UI is represented as typed Mojo surface-tree entries. The plain-native-select target keeps the `<select>` and its `<option>` elements unstyled, opens the native menu surface, captures it, accepts an item through Mojo, and verifies the DOM state plus cleanup pixels. The native-popup target also opens a right-click context menu, captures that menu surface, and cancels it through Mojo.

Run a smaller subset by naming suites:

```bash
./Scripts/run-layer-host-focused-suites-gui.sh resize lifecycle scale recovery scroll-text widgets google
```

Set `OWL_CHROMIUM_PATCH_CHECK=0` only when intentionally running against a local experimental Chromium checkout. Normal AWS verification should leave the patch check enabled.

Generate or check Swift bindings from the Mojo source:

```bash
./Scripts/generate-mojo-bindings.sh generate
./Scripts/generate-mojo-bindings.sh check
```

The check mode writes an HTML report showing the parsed Mojo declarations, the
generated Swift surface, and the source checksum.
