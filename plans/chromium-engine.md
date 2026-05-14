# Chromium engine spike: scope, architecture, milestones

Branch: `feat-chromium-engine`. Long-lived. Driven across many sessions; no single session completes this.

## Goal

Replace cmux's `WKWebView`-based browser surface (`Sources/Panels/BrowserPanel.swift`, `Sources/Panels/CmuxWebView.swift`, friends) with a Chromium-derived engine shipped as a private framework inside the cmux app bundle. Match the architecture used by Arc and Dia. **No CEF.**

End state, condensed:

- `Contents/Frameworks/CmuxCore.framework` ships a custom-branded build of Chromium's content layer (the same `ChromeMain` entrypoint Dia uses).
- Four helper apps under `CmuxCore.framework/Versions/A/Helpers/`: `cmux Browser Helper.app`, `cmux Browser Helper (Renderer).app`, `cmux Browser Helper (GPU).app`, `cmux Browser Helper (Alerts).app`. Bundle ID prefix `ai.manaflow.cmux.browser.helper*`.
- `Sources/Panels/CmuxWebView.swift` is rewritten on top of a thin Swift/Obj-C++ binding layer in a new local SwiftPM target (`Packages/CmuxBrowserEngine`) that wraps `CmuxCore`'s embedding API. Public surface stays close to the current `WKWebView` shape so the rest of `BrowserPanel.swift` keeps working with minimal diff.
- Rendering goes on screen via `CALayerHost` bound to a `CAContext` `contextId` published by the GPU helper, exactly as confirmed in Dia/Arc. IOSurface carries pixels across the process boundary.

## Why this is hard, stated up front

A reasonable estimate from public information: Arc/Dia's engine team is multiple senior browser engineers, working for years on top of Chromium 100+. We are one human plus AI agents. The path from "fetched chromium" to "ships in cmux" is not one session of work and not one month of sessions. The plan below is structured so each session produces durable, committed progress, with the build host carrying long-running build artifacts between sessions.

Concrete cost knobs:

- **Time**: 5–10 calendar months at full focus for a small team; this project will run slower with one human in the loop.
- **Compute**: `cmux-aws-mac` EC2 Mac dedicated host at roughly $1.50–1.80/hour. Already running 24/7 (24-hour minimum allocation, dedicated host model), so marginal cost of using it is effectively the per-hour rate continuing. Running for 5 months ≈ $5,500. Stopping it during off-weeks doesn't help because of the 24-hour minimum charge on each re-allocation.
- **Maintenance after v1**: upstream Chromium ships a new milestone every ~4 weeks; security rolls between them. A long-lived fork without a dedicated rebase rotation diverges fast and ships unpatched CVEs. We need either a near-clean tracking branch or a documented "every release cycle, rebase or accept the security debt" policy.
- **Distribution size**: cmux app bundle grows from ~100 MB to ~600 MB. The user-facing implication is auto-update bandwidth and disk usage.

If any of these costs change the answer, stop here and revisit.

## Architecture

Mirror Dia's structure exactly (verified by reverse-engineering `/Applications/Dia.app`):

```
cmux.app/
├── Contents/MacOS/cmux                 (existing Swift host, links CmuxCore)
└── Contents/Frameworks/
    └── CmuxCore.framework/             (Chromium content layer, ~450 MB)
        └── Versions/A/
            ├── CmuxCore                (exports _ChromeMain, _CmuxCoreInit, etc.)
            ├── Helpers/
            │   ├── cmux Browser Helper.app                (utility process)
            │   ├── cmux Browser Helper (Renderer).app     (Blink + V8)
            │   ├── cmux Browser Helper (GPU).app          (Viz, ANGLE, CAContext publisher)
            │   └── cmux Browser Helper (Alerts).app       (notifications)
            ├── Libraries/
            │   ├── libEGL.dylib                           (ANGLE)
            │   ├── libGLESv2.dylib                        (ANGLE)
            │   └── libvk_swiftshader.dylib                (SwiftShader fallback)
            └── Resources/
                ├── MEIPreload/, PrivacySandboxAttestations/, IwaKeyDistribution/
                ├── Localizable strings (en, ja for cmux's current locales)
                └── snapshot_blob.bin, v8_context_snapshot.bin, resources.pak, *.pak
```

Process model is stock Chromium: browser process = the Swift `cmux` binary, helpers spawned via `posix_spawn` of the helper bundle's `Browser Helper` shim (~170 KB; dlopens the framework, calls `ChromeMain` with the right `--type=` flag).

### Embedding API

A Swift host needs a stable, narrow surface. Two layers:

1. **C++/Obj-C++ binding inside Chromium** (`//cmux/embedder/`, added as an upstream patch): exports a C ABI of view, navigation, JS-bridge, profile, cookie, download, and find-in-page operations on top of `content::WebContents`. This is the equivalent of CEF's C API but Cmux-owned, smaller, and only covers what BrowserPanel needs. Lives in the Chromium fork.
2. **Swift wrapper in `Packages/CmuxBrowserEngine`**: Swift types that mirror today's `WKWebView`/`WKWebViewConfiguration`/`WKUserContentController`/`WKNavigationDelegate` API shapes (`CmuxBrowserView`, `CmuxBrowserConfiguration`, `CmuxUserContentController`, `CmuxNavigationDelegate`). One-to-one mapping where possible, intentional translation where Chromium and WebKit differ. Lives in cmuxterm-hq / cmux repo.

`Sources/Panels/CmuxWebView.swift` keeps its name and its current consumers, but stops subclassing `WKWebView` and starts subclassing or wrapping `CmuxBrowserView`. The diff to `BrowserPanel.swift` should be small if the wrapper API stays close enough; gaps get filled by adding to the wrapper, not by changing every callsite.

### Rendering integration (CALayerHost, no `drawRect`)

This is the part we already know works because Dia does it. The GPU helper builds a `CARendererLayerTree` of `CALayer`s backed by `IOSurface`s, publishes the tree via `+[CAContext contextWithCGSConnection:options:]`, and IPCs the resulting `contextId` to the browser process. The Swift host hosts each `WebContents` inside an `NSView` that owns a `CALayerHost` whose `contextId` is set to the value received over Mojo. AppKit composites; the browser process never touches the page pixels. This is private API (SPI), like Chrome/Arc/Dia use, and is fine for Developer ID-signed apps outside the Mac App Store.

Input routing stays AppKit: a `RenderWidgetHostViewCocoa`-style `NSView` subclass conforming to `NSTextInputClient` is the first responder; mouse, key, IME, scroll, and gestures are forwarded over Mojo to the renderer process. cmux's `BrowserPanel` first-responder code and `BrowserPaneNavigationKeybindUITests` keep working because the public Swift surface stays the same.

## Milestones

Each milestone is a sequence of PRs, not a single PR. Each PR is mergeable on its own. Naming convention: branches `chromium/<phase>-<slug>`, PRs prefixed `[cmux-chromium]`.

### P0 — Build host and toolchain (target: 1–2 weeks elapsed)

- [ ] Persistent volume layout on `cmux-aws-mac` (use `disk3s4`, 972 GB free, rename for clarity). Document remount procedure for the OS-update reset risk.
- [ ] Install `depot_tools` on the persistent volume.
- [ ] `fetch chromium` (4–12 hours, ~100 GB).
- [ ] First clean release `chrome` build to validate Xcode + toolchain.
- [ ] Wire build status notifications back into cmuxterm-hq via a `scripts/chromium-build.sh` that knows about Monitor signals.

### P1 — Custom framework target (2–4 weeks elapsed)

- [ ] Add a GN build target `//cmux:CmuxCore_framework` that produces `CmuxCore.framework` instead of `Chromium.app`. Strip browser UI; keep content/, components needed, ANGLE, V8, blink.
- [ ] Custom branding: bundle IDs `ai.manaflow.cmux.browser.helper*`, plist `CFBundleName = cmux Helper`, version string set to Chromium upstream + `.cmux.N`.
- [ ] Build all four helper apps with the cmux bundle ID prefix.
- [ ] Codesign with Developer ID Application identity, embed `embedded.provisionprofile`, notarize via `notarytool`. Helpers and framework signed before the host app.
- [ ] Smoke test: `CmuxCore` loads in a minimal Swift host that calls `ChromeMain` with `--type=` flags and shuts down cleanly.

### P2 — Embedding API (3–6 weeks elapsed)

- [ ] `//cmux/embedder/cmux_browser_view.{h,mm}` exports a C ABI. Initial surface: create/destroy view, load URL, can/go back/forward, reload, evaluate JS, attach script message handler, set delegate (navigation start/finish/fail, decidePolicyForNavigation, didReceiveAuthChallenge).
- [ ] CALayerHost-backed `NSView` returned to the embedder by an `(NSView *)hostView` accessor.
- [ ] Swift wrapper package `Packages/CmuxBrowserEngine`: `CmuxBrowserView`, `CmuxBrowserConfiguration`, `CmuxUserContentController`, `CmuxNavigationDelegate`, `CmuxUIDelegate`. API shape mirrors `WKWebView` modulo intentional translations.
- [ ] Unit tests on the Swift wrapper using an in-process fake (`CmuxCoreTestStub`) that simulates the C ABI without spawning helpers — fast and reliable for CI.

### P3 — Swap `WKWebView` → `CmuxBrowserEngine` in cmux (4–8 weeks elapsed)

Per-callsite swap, file by file, behind a feature flag (`UserDefaults.standard.bool(forKey: "cmux.browser.engine.chromium")`). Allows rollback per build.

- [ ] `Sources/Panels/CmuxWebView.swift` — engine swap, primary site.
- [ ] `Sources/Panels/BrowserPanel.swift` — config plumbing, delegate fanout, omnibar.
- [ ] `Sources/Panels/BrowserPanelView.swift` — find-in-page (`BrowserFindJavaScript.swift` → Chromium find API).
- [ ] `Sources/Panels/BrowserPopupWindowController.swift` — `WKUIDelegate.createWebViewWith` → `CmuxUIDelegate.createNewBrowserView`.
- [ ] `Sources/Panels/BrowserWebAuthnSupport.swift` — Chromium's WebAuthn already covers this; migrate from `ASAuthorizationController` bridge.
- [ ] `Sources/Panels/MarkdownPanelView.swift`, `MarkdownWebRenderer.swift`, `ReactGrab.swift` — secondary surfaces, keep on WKWebView initially or migrate as time allows.
- [ ] Drag/drop: `BrowserPaneDropTargetView.swift`, `FileDropOverlayView.swift` — `WKWebView` drag handlers re-wired through `CmuxBrowserView`.

XCUITests in `cmuxUITests/Browser*UITests.swift` are the canary. All must pass under both feature flag values during transition.

### P4 — Feature parity + Chromium-only wins (8–16 weeks elapsed)

What WKWebView doesn't do that we get for free with Chromium:

- [ ] Chrome extensions (`chrome.runtime`, MV3). Ship a curated allow-list initially; consider Web Store as a follow-up.
- [ ] DevTools (`chrome://inspect`-style remote debugger).
- [ ] PDF viewer using Chromium's built-in.
- [ ] Better video codecs (VP9, AV1) and DRM (Widevine, conditional on licensing).
- [ ] WebGPU.
- [ ] Better autofill (Chrome's address/password autofill is much stronger than `ASAuthorizationController` flows).

Things we explicitly do **not** turn on at first: Chrome Sync (account model is wrong), Privacy Sandbox ad APIs (we're not an ad network), reporting endpoints that phone home to Google.

### P5 — Productionization (4–8 weeks elapsed)

- [ ] Crash reporting wired through Sentry (`Frameworks/Sentry.framework` already in app bundle); replace Chromium's Crashpad upload endpoint with our own collector.
- [ ] Sparkle update channel handles the larger app bundle; verify delta updates work.
- [ ] Localization for the engine surface: en, ja (cmux's current locales).
- [ ] CI: GitHub Actions workflow that pulls the latest `CmuxCore.framework` artifact from `cmux-aws-mac` (uploaded after each successful build) and bakes it into the macOS app, so cmuxterm-hq builds don't need a Chromium tree.
- [ ] Security review checklist: site isolation enabled, sandbox seatbelt profiles applied, network service in its own process, V8 sandbox on.

## Build host plan

| Item | Decision |
|---|---|
| Host | `cmux-aws-mac` (M1 Ultra, 20 cores, 128 GB RAM, Xcode 26.3, macOS 15.7.4) |
| Persistent volume | `disk3s4` (994 GB, 972 GB free) — currently auto-mounted at `/private/tmp/tmp-mount-TOmSsz`. Rename volume to `Chromium`, document `diskutil mount /dev/disk3s4` as the remount step after reboot. |
| Checkout path | `/private/tmp/tmp-mount-TOmSsz/chromium` (or `/Volumes/Chromium/chromium` after rename) |
| depot_tools | `<persistent_volume>/depot_tools`, exported in `~/.zshrc` |
| Goma / RBE | Not available to us. Local builds only. Plan around full-build times of 60–120 minutes on M1 Ultra. |
| Build artifact handoff | After a green build, `tar` the framework to S3 (or scp to `cmux-macmini` Tailscale host) so cmuxterm-hq sessions can fetch without rebuilding. |

OS-update risk: if Apple ships a macOS update, `disk3s4` might be reformatted (it's nominally a system update volume). Mitigation: keep the Chromium checkout reproducible (depot_tools-managed) and accept that a re-fetch costs ~12 hours if it gets nuked. After a successful first build, snapshot the framework artifact off-host.

## Cross-session continuity (the "/loop" replacement)

`/loop` lives only inside a single session. This project lives across hundreds. The durable substrate is:

1. **This worktree** (`worktrees/feat-chromium-engine`) — branch `feat-chromium-engine` on the cmux remote. All in-cmuxterm-hq work commits here.
2. **The Chromium fork** — separate repo `manaflow-ai/cmux-chromium` (not yet created), tracking a Chromium release branch + cmux patches.
3. **The build host state** — `<persistent_volume>/chromium` checkout, plus `out/cmux_release` build directory. Surviving reboots, surviving sessions, surviving humans logging out.
4. **`plans/chromium-engine-handoff.md`** — the per-session state ledger (next file written).

A "new session" workflow:

1. User opens cmuxterm-hq, says `continue chromium engine work, see plans/chromium-engine-handoff.md`.
2. Agent reads the handoff doc, picks up the "Next steps" block, runs.
3. Agent commits work to `feat-chromium-engine`, updates the handoff ledger, opens or comments on the active PR, and exits.

`/schedule` is appropriate for *scheduled checks* on top of this (e.g. "every hour, run a smoke build on `cmux-aws-mac` and post results"). It is not a substitute for human-initiated work sessions; the agent has no way to make independent product decisions between sessions.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Chromium upstream changes a critical internal API we patched | High over months | Hours of rebase pain per release | Keep the cmux patch set as small as possible; prefer downstream wrappers over inline upstream edits |
| `cmux-aws-mac` disk gets reset by macOS update | Medium | 12 hours of re-fetch + rebuild | Snapshot framework artifacts off-host after every green build; document remount procedure |
| Embedding API doesn't actually match WKWebView's behavior subtly (caret position in editable fields, IME, drag selection) | High | Bug long-tail through P3 + P4 | Behavior parity tests under both flag values in XCUITests; canary period with the flag default off |
| Notarization fails on the new helper bundles (entitlements, hardened runtime) | Medium | Days of signing debugging | Steal Chrome's entitlements verbatim, adjust bundle IDs only |
| WebAuthn / Sign in with Apple / Passkeys break under Chromium | Medium | User-visible regression | Keep WKWebView fallback for auth-only flows during P3 |
| App bundle size from 100 MB → 600 MB regresses install/update bandwidth | Certain | User pain | Sparkle delta updates; consider on-demand engine download for new installs |
| Sandbox profile differences cause file access regressions vs WKWebView | Medium | Bug bucket | Mirror Chrome's seatbelt profiles; cmux-specific extensions go through a documented allow-list |
| User changes their mind and wants this shipped in 1 month | Medium | Quality cliff | Have a milestone-1 demo (P3 smoke: google.com renders in a cmux pane) so they can see incremental progress and abort earlier with smaller sunk cost |

## Self-verification plan

The user asked for "take screenshots and view them yourself to self-verify." That works once we have an engine producing pixels. Until then, self-verification is build success + unit tests + XCUITest pass. Screenshot-based verification starts at the end of P2 (smoke build of a `CmuxBrowserView` rendering a static page) and is mandatory for every PR after that, captured via `cmux-browser` skill's screenshot command and committed to the PR as evidence.

## What this session produced

This session is **session 0**. Output:

1. Branch `feat-chromium-engine` (this worktree).
2. `plans/chromium-engine.md` (this file).
3. `plans/chromium-engine-handoff.md` (state ledger, next file).
4. Draft PR on `manaflow-ai/cmux` with this plan as the body.

This session **did not** kick off the Chromium fetch on `cmux-aws-mac`. That's a session-1 decision once the plan + cost estimate is approved here.
