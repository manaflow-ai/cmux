# Menubar Global Cross-Window Search — design

Tracking issue: manaflow-ai/cmux#3865

## Phases
- **P1 (this PR)** — scaffold: `SearchIndex` (FTS5), `MenubarSearchPopover` (SwiftUI palette), `GlobalSearchHotkey` (⌥⌘F). Not yet wired into Xcode project; no behavior change.
- **P2** — wire-up:
  - Add the three new files to `GhosttyTabs.xcodeproj` (Sources group).
  - In `AppDelegate.applicationDidFinishLaunching`, after `statusItem` is built (around the existing menubar setup), call:
    ```swift
    let url = URL.applicationSupportDirectory
        .appending(path: "cmux/search.db")
    let index = try SearchIndex(url: url)
    MenubarSearchPopover.shared.attach(to: statusItem.button, index: index)
    GlobalSearchHotkey.shared.install()
    ```
  - Observe `.cmuxJumpToSearchHit` in the workspace controller; resolve hit → focus window/workspace/panel; re-use `SurfaceSearchOverlay` / `BrowserSearchOverlay` to highlight in-place.
- **P3** — capture sources:
  - **Browser**: in `CmuxWebView` add a debounced `didFinish` handler that runs `document.body.innerText` and feeds `SearchIndex.upsert(..., kind: .browser, anchor: webView.url?.absoluteString ?? "")`.
  - **Markdown**: hook the existing save path in `MarkdownPanel`.
  - **Terminal**: needs a minimal C shim in `vendor/ghostty` exposing `ghostty_surface_subscribe_text(surface, callback, userdata)` emitting committed lines. Until then, we accumulate via search-overlay state as a degraded mode.
- **P4** — ranking polish (BM25 already on; add recency-weighted boost, panel-scope filter, fuzzy fallback).

## Storage
`~/Library/Application Support/cmux/search.db` — SQLite + FTS5, unicode61 + diacritic-fold tokenizer, snippet+bm25 used in query path.

## Memory caps
Retain at most ~200 KB scrollback per terminal panel; evict oldest chunks per (panel_id) on insert. (Cap configurable in P4.)

## Non-goals
No cloud sync. No cross-machine search. No regex builder UI.
