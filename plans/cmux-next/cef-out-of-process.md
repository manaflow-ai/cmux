# Design study: the CEF browser process outside the app

Status: study only (coordinator decision, 2026-10-04). Owner: the crash lead
until a lane takes it. Context: plans/cmux-next/crash-elimination.md.

## Problem

CEF's browser process is the cmux app process. Renderer, GPU and utility
crashes are contained (child processes), but any CHECK, NOTREACHED, DCHECK
(builds before cmux.17), out-of-memory abort or memory-safety fault in the
browser process ends cmux: every window, terminal view and agent pane. The
2026-10-04 NIGHTLY crash was one such case: a page reached a DCHECK in the
WebAuthn browser code. cmux.17 removes DCHECKs; CHECKs stay on by design.

Goal: a browser-process failure ends only the browser, cmux keeps running,
and pages come back with a reload.

## Options

| Option | How | Cost |
| --- | --- | --- |
| A. Helper app with windowless (off-screen) CEF | A `cmux Browser` helper app runs CefInitialize with windowless rendering; `OnAcceleratedPaint` hands IOSurfaces to cmux over XPC (IOSurface mach ports); cmux shows them in a CALayer per pane; input goes back over XPC (`SendMouseEvent`, `SendKeyEvent`, `ImeSetComposition`) | Windowless mode is Alloy style only: no Chrome-style tab strip model, so the extension system (chrome.tabs/windows, popups, permission bubbles, the cmux fork's tabbed windows) does not work; IME, drag and drop, context menus, select popups, tooltips and accessibility must be rebuilt by hand; frame latency of one IPC hop |
| B. Helper app with Chrome style + remote layer hosting | The helper keeps Chrome style and its Views widgets; cmux hosts each widget's CALayer tree with a CALayerHost (the CARemoteLayer path Chromium's GPU process uses); events go to the helper through a forwarding view | CALayerHost is private API (App Store and notarization risk, Apple can change it); key window, focus, first responder and menus cross two processes; child windows (popups, bubbles, DevTools) need their own hosting; accessibility needs an AX remote element bridge (NSAccessibilityRemoteUIElement, also private) |
| C. Helper app owns its own top-level windows | The helper shows Chromium windows over cmux's panes (no parenting across processes on macOS) and follows pane geometry | Window ordering, Spaces, full screen, Stage Manager and clicks between apps break; this is the class of bug the cmux fork's child-window work removed |
| D. Keep in-process, harden | DCHECKs off (cmux.17), embedder tests for every reachable CHECK we find, crash reports with symbols, a restart that restores pages (exists: run marker, safe mode) | A browser-process CHECK still ends cmux, but restart is fast and pages come back |

## Costs to check before choosing A or B

- Input and IME: dead keys, marked text, the input source switcher, key
  equivalents that Chromium and cmux both want (`KeyRouter`).
- Accessibility: VoiceOver must reach page content (WebArea) in the pane.
- DevTools: docked DevTools is a second CEF browser in the same helper.
- Passkeys and WebAuthn UI: the platform authenticator sheet attaches to a
  window; it must attach to the cmux window, not a hidden helper window.
- Extensions: popups and permission prompts (Chrome style only today).
- Password manager, autofill, file pickers, print, downloads: all show UI.
- Performance: one more process (memory), IOSurface or layer-tree hop per
  frame, startup (CefInitialize moves off the app's launch path, a gain).

## Recommendation for the study lane

1. Measure first: how many browser-process aborts reach users (crash
   pipeline in crash-elimination.md section 4) after cmux.17.
2. Prototype B on cmux-lawrence-2 with one pane: layer hosting, mouse,
   keyboard, IME, VoiceOver on one page; report each cost with numbers.
3. Keep D as the default until B passes every check above.
