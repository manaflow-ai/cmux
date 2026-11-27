# Omnibar suggestions (R110 design, proposal)

Status: proposal from the browser power-user lead, 2026-10-04. Not built.
Lawrence (R110): "for omnibar, support search suggestions + history
suggestions, think from first principles the best way for us to handle all
edge cases and be extremely fast + customizable".

## What exists today

- `OmnibarReducer` (pure) owns keys, inline completion, popup selection,
  Shift-Delete, Escape. It asks for rows with `.query(generation, text)` and
  drops stale generations. Keep it.
- `OmniboxSuggestionEngine.suggestions(for:)` awaits every provider in
  sequence, then sorts. A slow provider blocks all rows. There is no remote
  search provider wired (`SearchSuggestionProvider` exists, no source).
- History: per-profile JSON `BrowserHistory` in the app, scanned linearly
  per keystroke (`HistorySuggestionProvider`, `BrowserHistoryRanker`).
  Bookmarks come in through `extraSuggestionProviders`.

## Ownership

- Visits are owned by the daemon's history store (React UIs lead, H3:
  daemon visits). The omnibar never writes history truth. Shift-Delete
  sends a typed op (`history.delete_url {profile, url}`, idempotency key) to
  the owner; the row leaves the popup at once as a pending intent and the
  index drops it on the owner's echo.
- The client keeps a read-only projection: an in-memory index per browser
  profile, built from a snapshot and kept current by the owner's
  `history-changed` events. Incognito has its own in-memory index and is
  never written to the daemon.
- Settings are owned by the config layer (`cmux.json`).

## Pipeline (one generation per keystroke)

1. Phase A, local, synchronous on a dedicated actor (never the main
   thread), budget 8 ms p99 including merge:
   what-you-typed row, quick history index, open tabs, bookmarks,
   calculator/unit conversion (optional), extension keywords.
   Inline autocomplete comes only from phase A.
2. Phase B, asynchronous, merged as results arrive:
   remote search suggestions (engine suggest endpoint), deep history
   (daemon full-text query over all visits, for matches outside the quick
   index). Each request is cancelled when the generation changes; remote
   fetches start after 40 ms without a keystroke (debounce) and time out
   after 800 ms.
3. Merge rule (no reflow jumps): the popup never moves a row that is on
   screen above or at the highlighted row. Phase B rows fill free slots
   below the local rows in rank order; when the popup is full, a phase B
   row replaces only the lowest-ranked row below the highlight. The card
   keeps the larger of its old and new height within one generation
   chain, so a late result never shrinks it under the pointer.

Why a client index and not a daemon query per keystroke: a socket round
trip plus JSON is 1-3 ms idle and much more under daemon load, and the
popup must answer during load. Chrome uses the same split
(HistoryQuickProvider in memory, HistoryURLProvider for the deep pass).

## Quick history index

- Rows: one per URL (not per visit): url, title, visit_count, typed_count,
  last_visit, a host-and-path token list and a title word list. Only
  "significant" URLs: typed_count > 0, or visit_count >= 2, or visited in
  the last 72 hours; cap 20,000 rows per profile (oldest low-score rows
  leave first). About 3-6 MB per 20,000 rows.
- Structure: a sorted array of (token, row) pairs per field, so a prefix
  lookup is two binary searches; multi-token input intersects the row sets
  of the rarest token first. No trie allocation churn, cheap to rebuild
  from a snapshot on a background actor.
- Score (deterministic, pure, property-tested):
  `match * 1.0 + typedBoost + log2(visit_count) * 40 + recency + brevity`
  where match is 600 host-prefix, 450 URL-prefix, 300 title word start,
  150 substring (the current `BrowserHistoryRanker` tiers), typedBoost is
  200 when typed_count > 0, recency is `120 * exp(-ageDays / 14)`.
  Ties break by provider order, then by URL text, so equal input always
  gives equal output.
- Inline autocomplete: the top phase A row only when its match is a host
  prefix on a label boundary ("git" -> "github.com/") and the URL was typed
  at least once or visited at least 4 times. Never from a search or remote
  row. Never when the caret is not at the end or the user just deleted.

## Sources, rows and actions

| Source | Row kind | Enter does |
| --- | --- | --- |
| What you typed | navigate or search | loads the URL or the search |
| History | history | loads the URL |
| Open tabs | switchToTab ("Switch to Tab") | reveals that tab (`AppServices.revealTab`); Shift-Enter loads it here instead |
| Bookmarks | bookmark | loads the URL |
| Remote search | search | searches for the suggestion |
| Calculator | answer | copies the result (Enter), never navigates |
| Extension keyword | keyword | existing `chrome.omnibox` path |

Cmd-Return and the other dispositions (P1) apply to every row that loads a
URL.

## Settings (`cmux.json`, Settings > Browser > Address Bar)

- `browser.omnibar.sources`: ordered list of enabled sources, default
  `["history", "tabs", "bookmarks", "search"]` (`"calculator"` opt-in).
- `browser.omnibar.maxRows`: default 8 (3...15).
- `browser.omnibar.remoteSuggestions`: default true; always off in
  incognito and for input that looks like a URL, a file path, an IP or a
  localhost host (no leaking of private URLs to the search engine).
- `browser.omnibar.inlineAutocomplete`: default true.
- `browser.searchEngine`: `google`, `duckduckgo`, `kagi`, `bing`,
  `brave`, or `{ "name", "search": "...%s...", "suggest": "...%s..." }`.
  Per browser profile override.
- Debug Settings tunables: debounce ms, remote timeout, index cap.

## Edge cases

- Multi-line paste: newlines become spaces; Paste and Go keeps the joined
  text. A pasted URL with surrounding spaces is trimmed.
- IDN: show Unicode for display only when the host is not a mixed-script
  spoof (Chromium IDN policy); compare and dedupe on the punycode form.
- File paths (`/Users/...`, `~/...`, `file://`): navigate to the file URL;
  no remote suggestions.
- `localhost`, `127.0.0.1:3000`, `host:port`, `[::1]`: URL, never a search.
- Single intranet word (`router`, `nas`): search by default; when history
  has `http://router/`, the history row ranks first and inline-completes.
- Typos of known hosts (`githbu.com`): no auto-correction; a history row
  for the close host (edit distance 1 on the registrable domain) is offered
  below what-you-typed.
- `javascript:` typed or pasted: refused (navigate row disabled, search
  row offered). `data:` top-level loads refused, as Chrome does.
- Very long input (> 2,048 characters): no index lookup, no remote fetch;
  only the what-you-typed row.
- Text with a space and a dot (`hello.world foo`): search.
- Uppercase scheme or host: normalized for matching, shown as typed.

## Keyboard

Unchanged from the reducer: Up/Down and Ctrl-N/Ctrl-P move rows, Tab moves
to the next row (or starts an extension keyword), Right/End accept the
inline completion, Backspace removes it, Shift-Delete removes a history
row, Escape steps back. Ctrl-J/Ctrl-K are not added by default: Ctrl-K is
the field's kill-line; the keybindings lead (R85) owns list navigation
keys, so any extra list key goes through that dispatcher.

## Verification

- Pure tests: scorer, merge rule (no on-screen row above the highlight
  moves, property test over random phase A/B arrival orders), URL/search
  classification table for every edge case above.
- Benchmark test on the fleet: 20,000-row index, 2,000 random prefixes,
  p99 phase A under 8 ms; fails the gate above budget.
- GUI proof on cmux-lawrence-2: type-ahead recording, remote rows arriving
  without reflow.

## Order of work

1. Engine split into phase A/B with the merge rule (no new sources).
2. Quick history index over the existing per-profile history, then switch
   its feed to the daemon visit store when H3 lands (coordinate through
   the coordinator).
3. Remote search suggestions with engine settings and privacy rules.
4. Open tabs ("Switch to Tab") and bookmarks rows.
5. Calculator (opt-in).
