# Chromium host notes

The verified AWS host is `cmux-aws-mac` at Chromium checkout `~/chromium/src`.
The production source of truth is now the full Chromium fork
`https://github.com/manaflow-ai/chromium-src` on branch `feat/owl-fresh-host`,
commit `7523a3a72320b403d509860f8ffaec9ac20d150e`, based on Chromium
`0bd9366db7`.

`chromium-patches/aws-m1-ultra-verified-owl-host.patch` is retained as a
reviewable checkpoint patch and clean-apply fallback. The companion manifest
`chromium-patches/aws-m1-ultra-verified-owl-host.json` records the fork repo,
fork branch, fork commit, base commit, patch SHA-256, patch line count, ninja
targets, and required build outputs. `Scripts/check-chromium-patch.sh --mode
applied` verifies the AWS checkout is either the clean fork commit or the legacy
base plus exact patch, and has the expected build products.
`Scripts/check-chromium-patch.sh --mode fork-remote` verifies the recorded fork
branch still points at the recorded commit.
`Scripts/check-chromium-patch.sh --mode clean-apply` verifies the patch applies
cleanly to the recorded base in a temporary shared clone.
`Scripts/checkout-chromium-fork.sh` fetches and checks out the recorded fork
commit in an existing Chromium checkout. `Scripts/apply-chromium-patch.sh`
still applies the recorded patch to a clean checkout at the recorded base.

Keep the manifest fork commit pinned until there is a release artifact pipeline
for the Chromium runtime. The focused GUI runner keeps the Chromium source check
enabled by default through `OWL_CHROMIUM_PATCH_CHECK=1`.

The Swift verifier expects a Chromium build with:

- `fresh_owl/owl_fresh_mojo_runtime.*`, exposing typed runtime symbols that
  launch Content Shell through Mojo, bind `OwlFreshSession`, and then bind child
  remotes for profile, web view, input, surface tree, and native surfaces before
  returning `OwlFreshClient` events into Swift callbacks.
- `content/shell/browser/owl_fresh_host_mac.mm`, implementing the host-side
  Mojo service, input forwarding, capture diagnostics, and compositor context
  publication.
- `ui/accelerated_widget_mac/owl_fresh_context.*`, storing the latest
  browser-process portal `CAContext` id for the shell host to publish.
- `ui/accelerated_widget_mac/display_ca_layer_tree.*`, presenting Chromium's
  compositor `CAContext` inside that browser-process portal.

The portal is important. Publishing the GPU-process context id directly produced
blank Swift `CALayerHost` windows. The passing path publishes a browser-process
portal context id, hosts Chromium's compositor `CAContext` inside that portal,
then Swift hosts the portal id in `CALayerHost`.

`Mojo/OwlFresh.mojom` is the Swift-side source of truth for `OwlFreshClient`,
`OwlFreshSession`, and the child `OwlFreshProfile`, `OwlFreshWebView`,
`OwlFreshInput`, `OwlFreshSurfaceTreeHost`, and `OwlFreshNativeSurfaceHost`
surfaces. `OwlMojoBindingsGenerator` emits
`Sources/OwlMojoBindingsGenerated/OwlFresh.generated.swift`. `OwlBrowserCore`
owns the Swift runtime protocol, typed C-ABI symbol-table bridge, direct linked
runtime entry point, session events, generated pending-handle bind graph, and
typed browser commands before calling typed runtime symbols. The verifier imports
`OwlBrowserCore`, owns the dynamic-library adapter for the current AWS Chromium
build, and owns AppKit hosting, screenshots, fixtures, and artifact reporting.
The old generic `interface + method + JSON` invoke bridge is not used.

The verified gate now includes input. `run-layer-host-verifier-gui.sh` can run
the real Chromium compositor input fixtures with `OWL_LAYER_HOST_INPUT_CHECK=1`;
the passing output shows `OWL_INPUT_READY` turning into `OWL_INPUT_CLICKED`,
then proves form input by typing `hello owl`, checking a checkbox, clicking
submit, and asserting the post-input DOM state through Mojo. It also verifies
Command, Option, Control, and Shift modifier delivery while a text input is
focused. Mouse events use Chromium's routed input path so controls activate
normally. The gate still rejects DevTools and remote debugging paths.
The scroll fixture now requires Chromium to land on a specific numbered content
row, and the text fixture verifies caret editing plus Shift-Arrow selection
replacement in one rendered page.

The lifecycle fixture now detaches and reattaches the primary Swift
`CALayerHost`, hides and resurfaces the Swift host window, then samples the
viewport edge colors to reject blank host gaps. The scale fixture verifies the
Mojo surface scale is applied to the hosted layer's `contentsScale` and then
uses the same edge-coverage sampling path.

The recovery fixture starts a real Content Shell session, captures its hosted
`CAContext` through Swift `CALayerHost`, sends `SIGKILL` to that host, requires a
Mojo disconnect event, then starts a fresh session and captures the same fixture
again. This is a host restart gate, not just a process cleanup check.

The current content shell host has real native menu surface coverage for
`<select>` popups and right-click context menus, plus real file picker surface
selection and cancellation coverage. It does not yet claim real coverage for
permission prompts, authentication prompts, extension bubbles, or macOS color
chooser. Those need browser delegate plumbing into the Mojo surface tree.
Extension bubbles and macOS color chooser are Chrome-browser surfaces rather
than surfaces exposed by this content shell path.

The AWS build used for the current screenshots was rebuilt with:

```bash
cd ~/chromium/src
third_party/ninja/ninja -C out/Release content_shell owl_fresh_mojo_runtime
```
