# CEFWebView vendoring notes

cmux vendors [brennanMKE/CEFWebView](https://github.com/brennanMKE/CEFWebView) as a starting point for a Chromium-backed browser engine that can replace WKWebView in `Sources/Panels/BrowserPanel.swift` over time.

This file tracks the local divergence from upstream and what remains before CEF actually loads inside cmux.

## What ships in this PR (Phase 1)

- `vendor/CEFWebView/` — vendored copy of the package (no `.git`, no demo `WebView/` app, no `Tests/`).
- `scripts/setup-cefwebview.sh` — idempotent script that downloads or links a CEF binary distribution into `vendor/CEFWebView/CEF/`, builds `libcef_dll_wrapper.a`, and produces `vendor/CEFWebView/Frameworks/`. Reuses a sibling `cef-swift-mvp/third_party/cef/` checkout when present.
- `.gitignore` excludes `vendor/CEFWebView/CEF/`, `Frameworks/`, and `.build/` (hundreds of MB of binaries).

The package builds cleanly via `cd vendor/CEFWebView && swift build` after `scripts/setup-cefwebview.sh` runs.

## Local patches vs upstream

1. `vendor/CEFWebView/Package.swift`
   - `platforms: [.macOS(.v14)]` (was `.v15`) so cmux's `MACOSX_DEPLOYMENT_TARGET = 14.0` matches.
   - Removed the `CEFWebViewTests` test target (the upstream `Tests/` directory isn't vendored).
2. `vendor/CEFWebView/build_cpp.sh`
   - `find -L` so the `CEF/<dist>` symlink to a sibling checkout is followed.

## What's still missing before cmux can load chromium

The `cmux` Xcode target (`GhosttyTabs.xcodeproj`) is not yet wired to CEFWebView. To finish the integration:

1. Add the local Swift package to `GhosttyTabs.xcodeproj`:
   - `XCLocalSwiftPackageReference` with `relativePath = vendor/CEFWebView`
   - `XCSwiftPackageProductDependency` with `productName = CEFWebView`
   - Reference both from the `cmux` target's `packageProductDependencies` and `Frameworks` build phase
2. Build settings on the cmux target:
   - `FRAMEWORK_SEARCH_PATHS = $(SRCROOT)/vendor/CEFWebView/Frameworks`
   - `LIBRARY_SEARCH_PATHS = $(SRCROOT)/vendor/CEFWebView/Frameworks`
   - `LD_RUNPATH_SEARCH_PATHS` includes `@executable_path/../Frameworks`
3. Embed phase: copy `vendor/CEFWebView/Frameworks/Chromium Embedded Framework.framework` into `cmux.app/Contents/Frameworks/` with code-sign-on-copy.
4. Run-script phases (after Embed):
   - Create `cmux Helper.app` and `cmux Helper (Renderer).app` in `Contents/Frameworks/` from `CEFHelper`/`CEFHelperRenderer` SPM products. See CEFWebView's `IMPLEMENTATION_GUIDE.md` for the exact bash.
   - Run `vendor/CEFWebView/fix_cef_framework.sh` to repair symlinks Xcode flattens during embedding.
5. Entitlements: cmux already has `com.apple.security.cs.allow-jit`, `allow-unsigned-executable-memory`, and `disable-library-validation`; helper apps need a matching minimal entitlements file (see `cmux-helper.entitlements`).
6. Swift integration: introduce a `Sources/BrowserEngine/` module that exposes a CEF-backed alternative to `BrowserPanel`'s `WKWebView`, gated behind a Debug menu toggle until parity is reached. The high-risk parity items (profile isolation, WebAuthn bridge, OAuth `window.opener`, SSO/MDM auth challenges) are inventoried in this PR description.

Earlier branches `task-cef-alloy`, `task-owl-chromium`, and `task-raw-chromium` attempted similar swaps with a custom `cef_bridge.cpp` and crashed on right-click teardown / view close. Switching to CEFWebView's package layout with proper multi-process helper apps is intended to address those crash classes.
