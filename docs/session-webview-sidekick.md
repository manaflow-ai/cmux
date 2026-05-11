# Per-Session WebView Sidekick — design

Tracking issue: manaflow-ai/cmux#3866

## Phases
- **P1 (this PR)** — scaffold:
  - `SidekickState` model (URL, isOpen, splitRatio, orientation, pinnedURLs) +
    `SidekickURLDetector` (regex extractor for terminal-stream URLs) +
    notifications (`.cmuxSidekickURLDetected`, `.cmuxSidekickToggle`).
  - `SidekickWebViewContainer` (SwiftUI) wrapping `WKWebView` with
    minimal chrome (URL field + close).
  - Not yet wired; no behavior change.
- **P2 — wire-up**:
  - Extend `TerminalPanel` with `var sidekick: SidekickState = .default`.
  - Persist it in the same place panel state already serializes (search
    `TerminalPanel.swift` for the `Codable` snapshot path).
  - In `TerminalPanelView`, wrap body in `HSplitView` when
    `panel.sidekick.isOpen`:
    ```swift
    HSplitView {
        existingTerminalView
        SidekickWebViewContainer(state: $panel.sidekick,
                                 panelID: panel.id)
            .frame(minWidth: 220)
    }
    ```
  - Add `⌥⌘B` shortcut routed via `.cmuxSidekickToggle`.
- **P3 — URL auto-detect**:
  - Hook `TerminalSurface` write path (`GhosttyTerminalView.swift`) to
    feed each text chunk through `SidekickURLDetector.extract`.
  - For each URL emit `.cmuxSidekickURLDetected` with the panel ID.
  - When sidekick is closed: show a transient toast ("Open in sidekick?")
    instead of auto-loading.
- **P4 — detach & polish**:
  - "Detach" action promotes sidekick URL to a full `BrowserPanel` via
    `bonsplitController.addPane()`; then `state.isOpen = false`.
  - Persist sidekick state per workspace snapshot.
  - Optional: hand-off page text to `SearchIndex` (issue #3865) so
    sidekick contents become globally searchable.

## Non-goals
Not a tab browser (one URL per sidekick — for tabs use `BrowserPanel`).
No bookmarks UI, no extensions. Ephemeral data store by default.
