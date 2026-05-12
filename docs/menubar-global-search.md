# Global Cross-Window Search — design (titlebar inline, smart)

Tracking issue: manaflow-ai/cmux#3865

## Placement (revised)

**Inline search field in the titlebar accessory, directly to the left
of the `+` new-workspace button.** Same `TitlebarControls` host that
already lives at window top-left
(`Sources/Update/UpdateTitlebarAccessory.swift`, attached at
`.layoutAttribute = .left`, line 1939). Earlier menubar
(`NSStatusItem`) plan dropped — inline is one click closer, per-window,
and shares focus with the rest of the titlebar controls.

`MenubarSearchPopover` retained for opt-in system-menubar fallback.

## Smart stack (local-only, zero external deps)

Per-keystroke pipeline:

1. **Scope-prefix parse** — `t:` terminal · `b:` browser · `m:`
   markdown · `w:` window-title. Filters before recall.
2. **SQLite FTS5** — `SearchIndex` lex recall (BM25 + snippet).
3. **SmartRanker** — BM25 (inverted) + recency hook + Thompson
   click-history prior per `(kind, panel)`, persisted to
   `~/Library/Application Support/cmux/search-clicks.json`.
4. **Focus bridge** — accepted hit posts `.cmuxJumpToSearchHit`;
   `AppDelegate` forwards to the existing
   `FeedCoordinator.focus(workspaceId:surfaceId:)` pathway so the user
   lands directly in the matching window / workspace / panel.

Keyboard:
- `↑` / `↓` step through hits.
- `↵` accepts (focus + record reward).
- `⌘1..9` direct-jump to the N-th hit.
- `Esc` dismisses.

No network. No daemon. No telemetry. Index lives in the user's app
support directory; deletable at any time. A future opt-in semantic
backend (Synapse / sqlite-vec / Core ML embeddings) can plug in
behind `SearchIndex` without touching the UI.

## Phases

- **P1 (this PR)** — scaffold:
  - `SearchIndex` (FTS5 actor)
  - `SynapseBridge` (Unix-socket client, graceful no-op on miss)
  - `SmartRanker` (BM25 + recency + Thompson click-history)
  - `TitlebarSearchField` (inline SwiftUI field, popover results)
  - `MenubarSearchPopover` (opt-in fallback)
  - `GlobalSearchHotkey` (default `⌥⌘F` → focus the inline field)
- **P2** — wire-up:
  - Add new files to `GhosttyTabs.xcodeproj` (Sources group).
  - In `Sources/Update/UpdateTitlebarAccessory.swift`, inside
    `TitlebarControls` body, just *before* the `TitlebarControlButton`
    whose icon is `"plus"` (around line 582), insert:
    ```swift
    TitlebarSearchField(index: AppDelegate.shared?.searchIndex)
        .frame(width: 220)
    ```
  - In `AppDelegate`, lazily create the shared index:
    ```swift
    let url = URL.applicationSupportDirectory
        .appending(path: "cmux/search.db")
    self.searchIndex = try? SearchIndex(url: url)
    GlobalSearchHotkey.shared.install()
    ```
  - Observe `.cmuxJumpToSearchHit` in the workspace controller; resolve
    hit → focus window/workspace/panel; reuse `SurfaceSearchOverlay` /
    `BrowserSearchOverlay` to highlight in place.
- **P3** — capture sources:
  - **Browser**: debounced `didFinish` in `CmuxWebView` runs
    `document.body.innerText`; feeds both `SearchIndex.upsert` and
    `SynapseBridge.put` (semantic embed daemon-side).
  - **Markdown**: hook the save path in `MarkdownPanel`.
  - **Terminal**: minimal C shim in `vendor/ghostty` exposing
    `ghostty_surface_subscribe_text(surface, callback, userdata)`
    emitting committed lines. Until then degraded via search-overlay
    state.
- **P4** — polish:
  - Scope prefixes (`t:`, `b:`, `m:` for terminal/browser/markdown).
  - `⌘1..9` direct-jump to top-N hits.
  - Per-workspace toggle (current vs. all windows).

## Storage
`~/Library/Application Support/cmux/search.db` — SQLite + FTS5,
`unicode61 remove_diacritics 2` tokenizer, `snippet()` + `bm25()` in
the query path. Synapse keeps its own store under `~/.synapse/`.

## Localization
All visible strings go through `String(localized:)` — placeholder key
`titlebar.search.placeholder`, English + Japanese pending in
`Resources/Localizable.xcstrings` at P2 wire-up.

## Non-goals
No cloud sync. No cross-machine search. No regex builder UI.
