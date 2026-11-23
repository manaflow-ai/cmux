# Omnibox preloading: what Enter loads is already loading

Chrome makes Enter in the omnibox feel instant by preloading the match it predicts while the
person types. cmux's omnibar is native (`OmnibarReducer`), so Chrome's own omnibox code never
ran; since fork API 33 the omnibar drives Chrome's same machinery through the fork.

## What Chrome does (Chromium 157.0.8103.66)

Paths are in chromium/src at that tag.

- **Every keystroke.** `ChromeOmniboxClient::OnTextChanged`
  (`chrome/browser/ui/omnibox/chrome_omnibox_client.cc`) registers the result's URLs for the typed
  text (`AutocompleteActionPredictor::RegisterTransitionalMatches`), asks
  `RecommendAction(user_text, current_match)` and then calls `DoPrerender` or `DoPreconnect`.
- **Confidence.** `chrome/browser/predictors/autocomplete_action_predictor.cc`: confidence =
  hits / (hits + misses) for (lower-cased typed text, URL), 0 below 3 hits
  (`kMinimumNumberOfHits`). Prerender at >= 0.5 (`prerender_dui_confidence_cutoff`), preconnect at
  >= 0.3 (`preconnect_dui_confidence_cutoff`). Search matches never prerender (SearchPrefetchService
  owns them). Database "Network Action Predictor", at most 2000 rows (lowest confidence dropped
  first), rows for URLs not visited in 14 days dropped, strings <= 1024.
- **Learning.** `OnOmniboxOpenedUrl`: the opened URL gets a hit, every other registered URL a
  miss; nothing is learned when the popup was closed or for Paste and Go. `OnRevert` (Escape)
  counts every registered URL as a miss.
- **Prerender.** `DoPrerender` skips the tab's own URL and tabs with DevTools attached, then
  `AutocompleteActionPredictor::StartPrerendering` ->
  `PrerenderManager::StartPrerenderDirectUrlInput` (`chrome/browser/preloading/prerender/prerender_manager.cc`):
  one direct-URL-input prerender per tab (a new URL cancels the old one), transition
  TYPED | FROM_ADDRESS_BAR. Enter's navigation activates it only when its transition is the same
  (`content/browser/preloading/prerender/prerender_host.cc`, the transition check).
- **Preconnect.** `DoPreconnect` -> `LoadingPredictor::PrepareForPageLoad(HintOrigin::OMNIBOX)`:
  1 socket, credentials allowed, same-site network key; the same origin again only after 10 s
  (60 s for a DNS-only preresolve); an unused socket closes after 60 s.
- **Limits** (all enforced inside Chromium, so they hold in cmux too): the "Preload pages" setting
  (none blocks everything), Battery Saver and Data Saver, critical memory pressure, at most 2
  embedder prerenders per tab, a hidden embedder prerender ends after 19 s, an embedder
  prerender that redirects cross-site is cancelled; requests carry `Sec-Purpose: prefetch;prerender`.
- **Focus and hover.** No network preload on focus. Desktop Chrome does not preload on a row's
  hover or mouse-down (that path is Android-only); New Tab Page tiles preconnect after 100 ms hover.

## What Safari and WebKit do

- WebKit exposes `-[WKWebView _preconnectToServer:]` (SPI, `WKWebViewPrivate.h`) ->
  `WebPageProxy::preconnectTo` -> `NetworkProcess::preconnectTo` (10 s timeout).
- WebKit preconnects to a link's host when it is clicked (`HTMLAnchorElement.cpp`) and supports
  speculation-rules prefetch, not prerender (`SpeculationRules.cpp`).
- Safari's "Preload Top Hit in the background" (Settings > Search) starts loading the top hit from
  bookmarks and history before Return. Safari is closed source: that it loads the page in a hidden
  web view and swaps it in is an inference, and its thresholds are not public.

## What cmux does

- `OmnibarController` sends `OmnibarPreloadRequest` (typed text, the matches with the one Enter
  loads first) after every step that changes them, and the end of the edit
  (`OmnibarPreloadRequest.ending`) before the commit loads the page.
- `CEFTab+OmniboxPreload` passes them to the fork (`cmux_omnibox_preload_text_changed`,
  `cmux_omnibox_preload_opened`, manaflow-ai/cef `libcef/browser/cmux/cmux_omnibox_preload.cc`),
  which runs Chrome's code above unchanged, with the profile's own predictor database.
- CEF disables Prerender2 (CEF issue #3664). The fork allows embedder-triggered prerender after
  `cmux_set_omnibox_prerender(1)` (cmux sets it at startup); speculation rules stay off. A
  prerendered page's frames are not the tab's and send no load, address or error events until Enter
  activates it.
- Never preloaded: agent-driven tabs, tabs of a remote machine's store, keyword sessions, Switch to
  Tab and calculator rows, non-http(s) URLs.
- Older forks (API < 33) do nothing.

## Measurement

The fork's embedder tests (`tests/cmux_embedder/cmux_embedder_preload157.inc`, cases
`preload157-omnibox` and `preload157-net`) measure Enter -> first contentful paint in Chromium
with the same `CefFrame::LoadURL` call cmux makes, cold and prerendered. Run them on the GUI
worker with `scripts/cef/test-embedder-step.sh <package> <sources> <fork ref> preload157-omnibox preload157-net`.

### Results (2026-11-15, cef-157.0.0-cmux.51 arm64, fork b1cef88, tests 07ddaa65)

Enter -> first contentful paint, shared slots on fleet capture minis (cmux21, cmuxs-mac-mini-3):

| Case | Cold | Preconnect only | Prerendered |
| --- | --- | --- | --- |
| Local server, 600 ms response | 645.7 ms | - | 49.6 ms |
| Public sites, median of 8 (example.com, Wikipedia, HN, iana.org; round 0 is warm-up) | 137.3 / 125.4 ms | 99.1 ms | 68.3 ms (8/8 activated) |

Preconnect saves about a fifth (the connection setup); prerender halves a warm site and removes the
server time of a slow one (a cold Wikipedia load: 513.5 ms -> 78.6 ms). A page restored from the
back/forward cache and the next page after an activation both still run script and send console
messages (checked in `preload157-omnibox`).
