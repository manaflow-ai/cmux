# Atlas-Informed Chromium Migration Plan

Last updated: February 22, 2026  
Task source: https://openai.com/index/building-chatgpt-atlas/

## What We Can Infer From Atlas (Reverse-Engineered)

This section is an inference from the published Atlas engineering post dated February 17, 2026.

1. Atlas keeps browser control local to the user machine while models/orchestration run remotely.
2. A local process named OWL acts as a privileged bridge between cloud agent logic and local browser actions.
3. The bridge transmits high-level browser actions and state (not full unrestricted machine control).
4. Accessibility-tree snapshots and visual context are central to how the remote model understands page state.
5. The architecture is explicitly multi-process and security-boundary aware (agent logic, browser runtime, local host bridge).
6. MCP is used as the tool protocol layer for browser actions.

## Current cmux Browser Architecture (WKWebView)

Today, cmux is tightly coupled to `WKWebView` across runtime, UI hosting, and automation APIs:

1. Runtime and navigation are implemented directly in `Sources/Panels/BrowserPanel.swift`.
2. Input/menu/download behaviors are implemented in a `WKWebView` subclass in `Sources/Panels/CmuxWebView.swift`.
3. Reparenting/visibility and DevTools-preserving view orchestration happen in:
- `Sources/Panels/BrowserPanelView.swift`
- `Sources/BrowserWindowPortal.swift`
4. V2 browser automation methods in `Sources/TerminalController.swift` call `WKWebView` APIs directly for:
- JavaScript execution
- cookie store access (`WKHTTPCookieStore`)
- screenshots and focus checks
- user script injection (`WKUserScript`)
5. Several browser parity methods are intentionally `not_supported` because WKWebView lacks CDP-level controls (viewport emulation, route/unroute, tracing, screencast, raw input injection).

## Migration Goal

Keep cmux UX (embedded tabbed browser in panes/splits) and existing v2 API surface, while swapping the underlying browser engine to Chromium and unlocking current `not_supported` method families.

## Recommended Target Architecture

### 1) Introduce an engine-agnostic seam first

Create a runtime abstraction so cmux no longer depends on `WKWebView` outside one adapter.

Suggested primitives:

1. `BrowserEngine` enum: `webkit`, `chromium`.
2. `BrowserRuntime` protocol (navigation, history, focus, scripting, snapshot, cookies/storage, downloads, menu hooks, lifecycle).
3. `BrowserAutomationBackend` protocol for TerminalController operations (eval/wait/find/cookies/storage/network controls).

Initial adapter:

1. `WebKitBrowserRuntime` wraps current `WKWebView` behavior.

Future adapter:

1. `ChromiumBrowserRuntime` wraps Chromium embedding backend.

### 2) Chromium backend choice

Use a two-step rollout:

1. **Step A (fastest path): in-process Chromium embedding via CEF** to preserve existing NSView-based hosting and portal behavior.
2. **Step B (Atlas-style hardening): optional out-of-process Chromium host** after parity is stable.

Why this order:

1. Existing cmux portal logic assumes attachable/reparentable `NSView` surfaces.
2. Jumping straight to out-of-process rendering would require a new surface streaming/compositing path and is materially larger in scope.

Relevant Chromium embedding references:

1. CEF API docs index: https://cef-builds.spotifycdn.com/docs/141.0/
2. Windowless embedding entry point (`CefWindowInfo::SetAsWindowless`): https://cef-builds.spotifycdn.com/docs/141.0/classCefWindowInfo.html
3. Render handler callbacks used for off-screen integration (`CefRenderHandler`): https://cef-builds.spotifycdn.com/docs/141.0/classCefRenderHandler.html

## Concrete Change Plan

### Phase 0: Safety net and inventory

1. Freeze baseline behavior with current tests:
- `tests_v2/test_browser_api_comprehensive.py`
- `tests_v2/test_browser_api_extended_families.py`
- `tests_v2/test_browser_api_unsupported_matrix.py`
2. Add one new migration guard test that asserts engine-specific capability behavior (WK vs Chromium) through `system.capabilities`.

### Phase 1: Refactor seam (no behavior change)

1. Extract runtime interfaces and move direct `WKWebView` usage behind adapters.
2. Update:
- `Sources/Panels/BrowserPanel.swift` to depend on `BrowserRuntime`.
- `Sources/Panels/BrowserPanelView.swift` to attach `runtime.view` instead of `panel.webView`.
- `Sources/BrowserWindowPortal.swift` to operate on a generic browser host view reference.
- `Sources/TerminalController.swift` browser methods to call `BrowserAutomationBackend`.
3. Keep default engine = `webkit`.

### Phase 2: Chromium runtime MVP (feature parity with current WK path)

1. Implement `ChromiumBrowserRuntime` with embedded Chromium view.
2. Support parity-critical commands first:
- open/navigate/back/forward/reload
- snapshot/screenshot
- eval/wait/find/focus
- cookies/storage state save/load
3. Keep unsupported matrix unchanged until implementations are real.

### Phase 3: Replace WK-only gaps with Chromium-backed implementations

Implement currently `not_supported` families in `TerminalController` when Chromium engine is active:

1. `browser.viewport.set`
2. `browser.geolocation.set`
3. `browser.offline.set`
4. `browser.trace.start` and `browser.trace.stop`
5. `browser.network.route` and `browser.network.unroute`
6. `browser.network.requests`
7. `browser.screencast.start` and `browser.screencast.stop`
8. `browser.input_mouse`
9. `browser.input_keyboard`
10. `browser.input_touch`

Then update `tests_v2/test_browser_api_unsupported_matrix.py` so expectations are engine-conditional.

### Phase 4: Optional Atlas-style process isolation

1. Move Chromium runtime into `cmux-browser-host` subprocess.
2. Replace in-process calls with local IPC (Unix domain socket).
3. Keep high-level action contracts unchanged in cmux core.
4. Add explicit permission gates for sensitive operations.

## File-Level Impact

Primary files to refactor:

1. `Sources/Panels/BrowserPanel.swift`
2. `Sources/Panels/BrowserPanelView.swift`
3. `Sources/Panels/CmuxWebView.swift`
4. `Sources/BrowserWindowPortal.swift`
5. `Sources/TerminalController.swift`
6. `Sources/Workspace.swift`
7. `tests_v2/test_browser_api_unsupported_matrix.py`
8. `docs/agent-browser-port-spec.md`

Build/release pipeline work expected if Chromium is bundled:

1. `.github/workflows/ci.yml`
2. `.github/workflows/nightly.yml`
3. `.github/workflows/release.yml`
4. `scripts/setup.sh`

## Risk Register

1. Binary size and notarization complexity will increase significantly.
2. Pane/split reparenting regressions are likely at first due to current WebKit-specific portal assumptions.
3. DevTools behavior and focus ownership may diverge from current WK workaround paths.
4. Automation flakiness may increase during mixed-engine period.

Mitigations:

1. Keep engine flag-gated (`webkit` default) until parity suite passes on Chromium path.
2. Ship Chromium behind explicit opt-in setting first.
3. Preserve a fallback runtime path for at least one release cycle.
4. Add engine-tagged telemetry to compare crash rates and command failure rates.

## Success Criteria

1. All P0/P1 browser API tests pass in Chromium mode.
2. `tests_v2/test_browser_api_unsupported_matrix.py` has zero false `not_supported` entries for commands Chromium can support.
3. No regressions in split/tab focus behavior and browser reparenting.
4. WKWebView path remains available until Chromium crash/error rates are acceptable.

## Suggested Order Of Execution

1. Land runtime abstraction with no engine change.
2. Land Chromium MVP behind feature flag.
3. Gradually enable previously unsupported automation families.
4. Evaluate whether Atlas-style out-of-process host is worth the added complexity after parity is proven.

## MVP Status (February 22, 2026)

Implemented in this branch:

1. Engine selection primitives are now in place:
- `BrowserEngine` (`webkit`, `chromium`)
- `BrowserEngineSettings` (`UserDefaults` key + `CMUX_BROWSER_ENGINE` override)
- explicit requested vs resolved engine behavior
2. `BrowserPanel` now uses a runtime seam:
- `BrowserRuntime` protocol
- `WebKitBrowserRuntime` adapter
- `BrowserRuntimeFactory` with Chromium-request fallback to WebKit
3. `BrowserPanel` now exposes both:
- `requestedBrowserEngine` (user intent)
- `browserEngine` (effective runtime)
4. `system.capabilities` now includes engine metadata:
- `browser.engine`
- `browser.requested_engine`
- `browser.engine_fallback_active`
5. `not_supported` responses now include engine context:
- message uses the effective engine name
- error `data.browser_engine` is included for machine-readable assertions
6. Regression coverage added for:
- engine selection and fallback logic in Swift unit tests
- capabilities browser engine metadata shape
- engine-tagged `not_supported` contract in v2 parity matrix tests

Still intentionally out of scope for this MVP:

1. No embedded Chromium runtime yet (`ChromiumBrowserRuntime` remains future work).
2. Unsupported API families remain unsupported until Chromium-backed implementations are real.
3. `BrowserPanelView`/`BrowserWindowPortal` are still effectively WK-hosted, now behind seam scaffolding.
