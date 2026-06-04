# Architecture Review

Reviewed: 2026-03-10

This review is for the current Ubuntu MVP implementation only.
It focuses on architecture, state ownership, integration boundaries, and release risk.

## Executive Summary

The current direction is correct.

- `cmux` owns attention flow, workspace state, unread routing, and terminal widget identity.
- `ghostty-gtk` owns GTK adaptation: GL context, viewport, resize propagation, IME, focus, scroll, and input forwarding.
- `ghostty` core owns renderer policy and PTY/render lifecycle.

The most important design conclusion from this round is:

> The resize freeze was not a `cmux` layout bug. It was an embedded renderer policy bug in Ghostty.

That matters because it validates the current layer boundaries. We should keep the fix in the renderer layer, not paper over it in the GTK host.

## System Boundaries

```mermaid
flowchart LR
    Socket["Socket server\n(tokio thread)"]
    Shared["SharedState\nArc<Mutex<TabManager>>\nArc<Mutex<NotificationStore>>"]
    UI["GTK main thread\nAppState + window"]
    Cache["terminal_cache\nGhosttyGlSurface by panel_id"]
    Surface["ghostty-gtk\nGhosttyGlSurface"]
    Core["libghostty embedded runtime"]
    PTY["PTY / shell / agent TUI"]

    Socket --> Shared
    Shared -->|UiEvent::Refresh / SendInput| UI
    UI --> Cache
    Cache --> Surface
    Surface -->|FFI: key, text, resize, focus, draw| Core
    Core --> PTY
    PTY --> Core
    Core -->|wakeup / render actions| UI
```

## Attention Loop

```mermaid
sequenceDiagram
    participant Agent as Codex / Claude Code
    participant Socket as cmux socket API
    participant Model as SharedState
    participant UI as GTK UI
    participant User as Operator

    Agent->>Socket: notification.create / workspace.set_status
    Socket->>Model: update workspace attention state
    Socket->>UI: UiEvent::Refresh
    UI->>UI: refresh sidebar context
    User->>UI: select unread / Ctrl+Shift+U
    UI->>Model: select latest unread workspace
    UI->>UI: focus attention panel
```

This is the correct MVP core.

The product value is not "many terminal tabs."
The product value is "notice -> identify -> jump" under multi-agent load.

## Resize Root Cause

```mermaid
flowchart TD
    A["GTK resize"] --> B["ghostty_surface_set_size(...)"]
    B --> C["Renderer sees new surface size"]
    C --> D{"embedded runtime\nuses stale-frame guard?"}
    D -->|yes| E["presentLastTarget()"]
    E --> F["terminal body looks frozen\nwhile UI keeps repainting"]
    D -->|no| G["rebuild cells / draw fresh frame"]
    G --> H["terminal follows resize correctly"]
```

The actual fix lives in [generic.zig](../../ghostty/src/renderer/generic.zig).

That is the right layer for the fix because the behavior is a renderer presentation policy, not a GTK event-dispatch problem.

## What Is Architecturally Sound

### 1. Terminal widget caching belongs in `cmux`

`cmux` now preserves terminal widget identity by `panel_id` in [app.rs](../cmux/src/app.rs).

That is the correct ownership model:

- workspace/panel identity is a `cmux` concern
- surface reuse policy is a `cmux` concern
- `ghostty` should not know about workspace switching

The cache also prevents state loss across sidebar refreshes and workspace switches.

### 2. GTK adaptation belongs in `ghostty-gtk`

The following are correctly implemented in [surface.rs](../ghostty-gtk/src/surface.rs):

- explicit desktop GL 4.3 context creation
- `glViewport(...)` before draw
- size and content-scale propagation on resize
- IME preedit/commit integration
- focus handoff and resize-time focus recovery
- scroll direction normalization
- click-to-focus

All of those are host integration concerns, so `ghostty-gtk` is the right place for them.

### 3. Renderer policy belongs in `ghostty`

The stale-frame guard change in [generic.zig](../../ghostty/src/renderer/generic.zig) is principled.

The old behavior was reasonable for native host runtimes that prefer avoiding blank flashes during synchronous resize redraws.
It is not reasonable for the embedded runtime, where the host is already tightly driving resize and redraw.

The embedded runtime should not inherit native-host presentation heuristics blindly.

## Findings

### P1: Push risk because the required resize fix is not on upstream `ghostty` main yet

As of 2026-03-10, this branch depends on the root `ghostty` submodule being pinned to a commit from `fork/draft/linux-embedded-host-support`, not `origin/main`.

That means the verified resize fix is still not self-contained in an upstream-reviewable Ghostty base.

Impact:

- pushing only the `cmux-linux` PR does not fully reproduce the working behavior
- review becomes misleading if the Ghostty dependency is not called out explicitly

Recommendation:

- do not hide this dependency
- split the Ghostty renderer fix into its own branch/PR if it is not already isolated
- make the `cmux-linux` PR explicitly depend on that Ghostty change

### P2: UI event delivery still uses 33ms polling

[window.rs](../cmux/src/ui/window.rs) still uses:

- `std::sync::mpsc`
- `try_recv()`
- `glib::timeout_add_local(Duration::from_millis(33), ...)`

This is acceptable for MVP because the product value is already visible.
It is still architectural debt:

- avoidable idle polling
- avoidable latency
- extra glue around the GTK main loop

Recommendation:

- move to `glib::MainContext::channel()` or `gio`-native socket integration later

### P2: Focus recovery is intentionally heuristic

[surface.rs](../ghostty-gtk/src/surface.rs) uses delayed focus disarm and delayed resize-time focus restore.

This was a practical fix for GTK resize/focus churn and it works.
It is still policy, not a guaranteed GTK invariant.

Risk:

- future toolbar/sidebar interactions may expose over-eager focus return

Recommendation:

- acceptable for MVP
- keep an eye on explicit focus ownership once more non-terminal controls are added

### P3: Distribution story is still development-grade

[build.rs](../ghostty-sys/build.rs) now builds and links Ghostty for local development, but packaging is not final.

Open questions remain:

- dynamic library search path
- bundling of `libghostty`
- reproducible install layout

This is not blocking the MVP review, but it is not release-finished.

## Recommended Branch Strategy

Because this work spans `cmux-linux` and external `ghostty`, the branch strategy should make that explicit.

```mermaid
flowchart TD
    Base["main / upstream base"]
    CmuxPR["cmux-linux PR branch\nreviewable branch"]
    Dev["cmux-linux dev branch\nunsafe / iterative work"]
    GhosttyDev["ghostty dev branch\nembedded renderer fixes"]
    GhosttyPR["ghostty PR branch"]

    Base --> CmuxPR
    CmuxPR --> Dev
    Base --> GhosttyDev
    GhosttyDev --> GhosttyPR
    Dev -->|cherry-pick stable commits| CmuxPR
```

Recommended workflow:

1. keep `#828` as the clean review branch
2. create a separate `cmux-linux` dev branch for ongoing experiments
3. create a separate Ghostty branch for embedded renderer changes
4. cherry-pick only stable commits back to the review branch
5. link the `cmux-linux` PR to the Ghostty PR explicitly

## Review Conclusion

The current MVP architecture is directionally correct.

The key positive result is that the layers are finally telling the truth:

- `cmux` handles attention and workspace semantics
- `ghostty-gtk` handles GTK adaptation
- `ghostty` handles rendering policy

The main release risk is not bad architecture inside `cmux`.
The main release risk is cross-repo coupling: a required runtime fix currently lives in Ghostty, outside the PR branch that would be reviewed first.

## Push Recommendation

Do not push the current `cmux-linux` branch as if it were self-contained.

Push plan:

1. split the Ghostty embedded resize fix into its own branch
2. keep the `cmux-linux` PR branch review-clean
3. mention the cross-repo dependency in the PR description
4. only then push the PR branch
