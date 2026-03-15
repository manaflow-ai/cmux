# Atlas-Inspired Browser Architecture Plan

Last updated: March 13, 2026

This document proposes how to replicate the core Atlas architecture pattern in cmux.

Inputs:
- OpenAI engineering post: `https://openai.com/index/building-chatgpt-atlas/`
- Static inspection of `/Applications/ChatGPT Atlas.app`

Where this document goes beyond direct evidence, it is called out as inference.

## Reverse-engineered Atlas shape

### Direct evidence

From the OpenAI post:
- Atlas is split into an **OWL Client** and an **OWL Host**.
- The client is the native SwiftUI/AppKit app.
- The host is Chromium's browser process, running outside the main app process.
- The two sides communicate over **Mojo**.
- The public client-side concepts are `Session`, `Profile`, `WebView`, `WebContentRenderer`, and `LayerHost/Client`.
- Rendering crosses the process boundary by exporting Chromium compositing state into the native app.
- Input is translated in the native client, forwarded to the host, and sometimes returned to the client when the page does not consume it.
- Agent mode uses isolated ephemeral storage partitions instead of sharing the normal profile.

From the local `ChatGPT Atlas.app` bundle:
- The main app bundle is `com.openai.atlas`.
- The main app links `Aura.framework`, `OwlBridge.framework`, `Sparkle.framework`, `Sentry.framework`, and other native frameworks.
- The app contains a nested support app at `Contents/Support/ChatGPT Atlas.app`.
- That nested app has bundle id `com.openai.atlas.web`, `LSUIElement = 1`, and version `146.0.7680.31`, which strongly suggests a hidden Chromium host bundle.
- `OwlBridge.framework` contains strings like `OWL_HOST_PATH`, `Terminating existing Owl host`, `owl/bridge/connector`, and many `mojo` references.
- `Aura.framework` contains symbols referencing `Mojom.Owl.WindowBridgeHost`, `BridgedWindowController`, `AgentComputerUseEnvironment`, `NavigationSidebarController`, and permission prompt plumbing.
- The bundle ships `AuraXPCService` plus LaunchAgents for Mach services like `com.openai.atlas.agent-xpc`.

### Inference

Atlas appears to have three distinct planes:

1. A native UI shell process.
2. A browser engine host process.
3. A separate agent/computer-use service plane.

The article only names OWL client and OWL host directly. The extra XPC service and agent-related symbols strongly suggest the third plane.

## Current cmux baseline

cmux already has several pieces that match the Atlas shape at the shell level:

- A native SwiftUI/AppKit shell with custom workspace, pane, and surface management.
- A portal system that keeps AppKit-backed content stable across workspace and split churn.
- A handle-based v2 JSON socket API intended for LLM agents.

cmux differs in one critical place today:

- Browser surfaces are still same-process `WKWebView` instances. `BrowserPanel` explicitly creates a `WKWebViewConfiguration`, shares a `WKProcessPool`, and uses the default `WKWebsiteDataStore`.
- The browser portal code moves and reattaches `WKWebView` instances inside the main app process.

That means cmux already has the right shell and automation boundary, but not the Atlas-style browser runtime boundary.

## Recommendation

Replicate the Atlas architecture pattern, not Atlas's exact implementation details.

For cmux that means:

1. Keep the existing SwiftUI/AppKit shell as the single source of truth for windows, workspaces, panes, surfaces, omnibar, notifications, and agent-facing socket APIs.
2. Move the browser runtime behind a separate host boundary.
3. Add a thin client bridge layer in the app so `BrowserPanel` stops owning `WKWebView` directly.
4. Keep the existing v2 socket API as the public automation surface.

Do not treat `WKWebView` as the final out-of-process solution. It is fine as a migration adapter, but it is the wrong long-term foundation for an Atlas-style split. Public WebKit APIs keep the embedding view in the app process and do not give cmux the same restart, composition, or engine-isolation properties that Atlas is built around.

## Proposed cmux architecture

### 1. Shell process: `cmux.app`

Own:
- window lifecycle
- workspace and pane tree
- sidebar, omnibar, notifications, command palette
- agent-facing socket API
- terminal surfaces and Ghostty integration
- focus policy and shortcut routing

Do not own:
- browser engine lifecycle
- browser profile storage internals
- page rendering pipeline
- renderer-directed automation execution

### 2. Bridge framework: `cmuxBrowserBridge`

Create a transport-agnostic client library with Swift-first APIs that map closely to the Atlas concepts:

- `BrowserRuntimeSession`
- `BrowserProfile`
- `BrowserSurface`
- `BrowserRenderer`
- `BrowserLayerEndpoint`
- `BrowserPermissionBroker`
- `BrowserDownloadBroker`

This bridge becomes the only thing `BrowserPanel` talks to.

### 3. Host process: `cmux Web Host`

Create a hidden helper app or XPC-hosted process that owns:

- browser engine startup and shutdown
- profile and cookie stores
- tab and page objects
- renderer state
- screenshots, DOM snapshotting, script evaluation, and network instrumentation
- crash recovery for the browser engine without taking down the shell

### 4. Optional agent service: `cmux-agentd`

If cmux wants Atlas-style computer use, isolate it again:

- accessibility and OS-level automation
- screenshot and capture policy
- per-task ephemeral agent contexts
- high-risk permissions and audit logging

This is optional for the first browser split, but it matches the Atlas direction and prevents the shell from becoming the privileged dumping ground.

## Backend strategy

Use two backends behind the same bridge.

### Backend A: local compatibility adapter

Wrap the current `WKWebView` implementation so cmux can land the new interfaces without changing behavior.

Purpose:
- preserve current product behavior
- let `BrowserPanelView` and portal code stay mostly intact
- make the shell-side API stable before introducing another engine

### Backend B: remote host backend

Build the real Atlas-style path behind a feature flag.

Recommended target:
- Chromium or CEF in a dedicated host bundle

Reason:
- It matches the Atlas architecture directly.
- It gives cmux a real browser-process boundary.
- It makes agent automation, screenshots, and compositor routing much easier to control centrally.

Not recommended as the final target:
- a hidden helper containing `WKWebView`

Reason:
- it does not buy the full separation that Atlas gets
- it is likely to be fragile around rendering and input ownership
- it still leaves cmux constrained by WebKit embedding assumptions

## Rendering plan

cmux already has the right shell-side abstraction shape because browser content is portal-hosted and can be swapped across workspace and pane containers.

The remote host path should:

1. Export one render surface per browser surface.
2. Attach that surface into the existing browser portal host.
3. Keep geometry, scale factor, focus state, and visibility synchronized from shell to host.
4. Handle popup widgets and permission UI explicitly, either by:
   - native shell replacements, or
   - remote hosted overlays with a dedicated layer bridge

The key design rule is that the shell owns layout, and the host owns pixels.

## Input plan

Follow the Atlas rule exactly:

1. The shell receives native `NSEvent`s.
2. The shell translates them into browser input messages.
3. The host routes them into the renderer.
4. If the page does not consume an event, the shell gets an explicit bounce-back signal and can apply cmux shortcuts or pane/workspace navigation.

This is especially important because cmux already has complex first-responder and shortcut rules for browser surfaces.

## Profile and isolation plan

Adopt three profile classes:

1. `default`
   - persistent user browsing profile
2. `workspace-scoped`
   - optional, for users who want browser state partitioned by workspace
3. `ephemeral-agent`
   - memory-only, destroyed at end of the task or surface lifetime

`ephemeral-agent` is the Atlas-equivalent feature that matters most for cmux's agent workflows.

## Public automation plan

Do not expose the internal host transport directly.

Keep the current cmux public contract:
- v2 JSON socket methods
- stable `window_id`, `workspace_id`, `pane_id`, `surface_id`

Internally map:
- `surface_id` -> host browser surface id
- cmux browser methods -> bridge calls -> host IPC

That preserves the current agent/browser work and avoids leaking engine-specific concepts to users.

## Rollout phases

### Phase 0: interface extraction

Deliverables:
- `cmuxBrowserBridge` protocols and models
- `BrowserPanel` no longer constructs or reaches into `WKWebView` directly outside the local adapter

Exit criteria:
- zero user-visible change
- current browser still runs on the local adapter

### Phase 1: shell cleanup

Deliverables:
- separate shell responsibilities from engine responsibilities
- move navigation, page state, input routing, permission decisions, and downloads behind bridge interfaces

Exit criteria:
- `BrowserPanelView` and portal code depend only on bridge-facing state

### Phase 2: host bootstrap

Deliverables:
- `cmux Web Host` helper bundle
- on-demand launch, health checks, crash detection, restart logic
- minimal IPC for create surface, destroy surface, navigate, focus, resize

Exit criteria:
- one remote browser surface can load a page under a feature flag

### Phase 3: remote rendering

Deliverables:
- render surface export from host
- shell-side portal attachment
- resize and scale synchronization
- hidden and background surface handling

Exit criteria:
- workspace switching and split churn work without blank frames or stuck layers

### Phase 4: remote input

Deliverables:
- shell-side event translation
- unhandled-event bounce-back
- text input, pointer input, wheel, IME, and modifier handling

Exit criteria:
- browser shortcuts and cmux shortcuts both behave correctly under focus changes

### Phase 5: browser feature parity

Deliverables:
- history, downloads, permission prompts, popups, devtools, snapshots, screenshots, script eval
- current v2 browser APIs routed through the host

Exit criteria:
- agent-browser parity doc no longer depends on in-process `WKWebView`

### Phase 6: agent isolation

Deliverables:
- ephemeral agent profiles
- optional `cmux-agentd`
- audit logging and policy checks for privileged automation

Exit criteria:
- multiple isolated agent sessions can run without sharing cookies or storage

### Phase 7: default rollout

Deliverables:
- feature flag rollout
- crash telemetry and performance telemetry
- migration path for old sessions and browser state

Exit criteria:
- remote backend is stable enough to become default

## Risks

1. Chromium integration cost is real.
   cmux would be taking on a large dependency, a heavier build story, and a new security/update surface.

2. `WKWebView` is not a real long-term substitute for this architecture.
   Using it as a bridge backend is fine. Using it as the remote host target is probably a dead end.

3. Cross-process rendering on macOS is the hardest technical seam.
   The rollout has to prove resize, focus, popups, and crash recovery before broader migration.

4. Agent security gets worse if it lands in the shell.
   If cmux adds computer-use features, a separate privileged service is the safer boundary.

## Suggested first implementation slice

Build only enough to prove the architecture:

1. Introduce `cmuxBrowserBridge`.
2. Put the existing `WKWebView` browser behind the local adapter.
3. Create a stub `cmux Web Host` that can launch, answer health checks, and own a fake remote surface.
4. Teach the portal system to swap between local and remote render endpoints under a feature flag.

If that slice lands cleanly, cmux will have the hard architectural seam in place. After that, the engine choice and deeper browser migration become incremental work instead of a flag day rewrite.
