# C15 `search`: universal search on the phone

Status: lane C15 of PLAN.md, 2026-10-06. Branch `feat-cmux-next-ios-c15-search` off
`feat-cmux-next-ios` (A1, C5, C6, C9, C11, C16 merged there). Binding: PLAN.md section 4,
OWNERSHIP-PRINCIPLES.md, a1-shell.md (1.7 Search tab, 2.3 seams), c5-workspaces.md (list rows,
`WorkspacesFeature.open(hostID:workspaceID:)`), c6-feed.md (`FeedSource`, `FeedNavigator`),
c9-ssh.md (`HostsStore`), c16-platform.md (`ShellRoute`, `ShellRouter`), c1-terminal-rpc.md
(`terminal.history`). Desktop references: tab-search.md (ranking weights, recency), palette-scopes.md
(snapshot sources ranked by the host).

## 1. Ownership

Search owns no domain state. Every result is a value projection of a mirror another lane owns, read
through the seam that lane already exposes:

| Corpus | Owner (mirror) | Read through |
| --- | --- | --- |
| workspaces and tabs on every Mac | each Mac's workspace store (C5 mirror) | `WorkspaceSource.updates()` |
| feed items | `FeedDO` (C6 mirror) | `FeedSource.updates()` |
| hosts (paired Macs, SSH, direct) | B6 registry, C9 host store | `HostsStore.updates()` |
| settings pages, actions | compiled into the app | static catalog |
| terminal scrollback | the Mac session host | `terminal.history` (seam only, section 7) |

| Client state | Where |
| --- | --- |
| query, highlighted row, scroll | the search screen, in memory, never persisted |
| recent searches (last 8 committed queries) | `UserDefaults` on this device, never synced |

No new server index, no new wire message. A provider maps each snapshot to `SearchItem`s with
pre-normalized text (once per owner change, off the main actor), and keeps only the newest mapping.
Subscriptions exist only while the search screen is visible (subscribe in `viewWillAppear`, cancel
in `viewDidDisappear`), so the Feed socket and workspace channels are not held open by search in
the background and idle CPU stays 0%.

## 2. Modules

| Module | Owns | Imports |
| --- | --- | --- |
| `CmuxiOSSearchCore` | `SearchText` (normalized units, word starts), `SearchMatcher`, `SearchRanker`, `SearchItem`, `SearchDestination`, `SearchProvider` and the four providers, `SearchCatalog` (actions, settings), `RecentSearchesStore`, `SearchSession` (debounced query on an injected clock), `TerminalScrollbackSearch` seam | Foundation, FeatureKit |
| `CmuxiOSSearch` | `SearchFeature` (entry point), `SearchViewController` (UIKit list), cells, keyboard commands, VoiceOver announcements | UIKit, SearchCore, FeatureKit, Design |

The shell never imports either: `ShellContent(screens:)` gets the Search tab root from the
composition root, as C5, C6 and C9 do. `CmuxiOSApp` implements `SearchOpening` over the router and
the feature entry points.

## 3. Matching and ranking

Normalization per character (so match ranges map back to the original text for highlighting): case
fold, diacritic fold, width fold, hiragana to katakana. Word starts: index 0, after a non-alphanumeric
character (space, `-`, `_`, `/`, `.`, `:`), lower-to-upper case changes, and letter/digit changes.

Tiers for one query token against one field (higher always wins; the number inside a tier breaks ties):

| Tier | Score | Example (`dep`) |
| --- | --- | --- |
| exact | 1000 | `dep` |
| prefix | 800 to 899, shorter field first | `deploy api` |
| word start | 600 to 699, earlier first | `api deploy` |
| initials | 500 to 599 (`nt` against `New Task`) | |
| substring | 400 to 499, earlier first | `undeployed` |
| subsequence | 100 to 399, tighter span first | `d_e_bug p` |

Fields carry a weight (title 100, keywords 85, tab title 80, machine and agent 60, preview and body
55) and whether subsequence is allowed (off for long text such as feed bodies and preview lines, so
4 KiB of Markdown never fuzzes into noise). A multi-word query matches when every token matches some
field; the item score is the mean of the tokens' best weighted scores, or the whole query as one
token when that is higher. Small boosts: an open feed request that needs input (+40), unread (+10).

Results group by category (Actions, Workspaces, Tabs, Feed, Hosts, Settings). Groups are ordered by
their best score (ties by that fixed order), rows by score, then title, then id. Each group shows at
most 6 rows. An empty query shows recent searches and the actions.

## 4. Screens and entry points

- Search tab (`ShellTab.search`, flag `searchTab`, on in DEBUG like the other feature tabs). On iOS
  18 it is a `UISearchTab`, so the system places it as the search role (HIG: Tab bars, Search
  fields); on iOS 17 a regular tab. Reachable in one tap from every tab.
- Cmd-K on a hardware keyboard from any tab: selects the Search tab and focuses the field (presents
  search modally when the tab is hidden). Discoverable in the Cmd-hold overlay.
- `cmux://search?q=<text>` (`ShellRoute.search(query:)`, additive to C16).
- Pull-down on other tabs is not built: each tab owns its scroll view and refresh gesture, and a
  shell-level pull would fight them. The search tab plus Cmd-K covers "reachable from every tab".
- Screen: `UISearchController` in the navigation bar, compositional list (diffable by result id,
  reconfigure on change, no animation under Reduce Motion), section headers with `.header` traits,
  matched characters in semibold, SF Symbol per kind, status glyph for workspaces, "Needs input" for
  feed requests. `UIContentUnavailableConfiguration.search()` when nothing matches.
- Keyboard: Up/Down move the highlighted row across groups (priority over the text field), Return
  opens it (the first result when none is highlighted), Escape clears then dismisses a modal search.
- VoiceOver: each row is one element "title, subtitle, category"; a result count announcement after
  the results settle, only while VoiceOver runs and only when the count changes.
- Debounce: 80 ms on an injected `Clock`, one cancellable task; ranking runs off the main actor and
  a stale generation is dropped. No `asyncAfter`, no polling.

## 5. Opening a result

`SearchDestination` (Core) is handled by `SearchOpening` (App):

| Destination | Opens through |
| --- | --- |
| workspace / tab | `ShellRouter.open(.workspace(host:workspace:surface:))`; the root now calls `WorkspacesFeature.open(hostID:workspaceID:)` instead of only selecting the tab |
| feed item | `ShellRouter.open(.feed(item:))` (FeedNavigator) |
| paired Mac | `.workspaces` |
| SSH host | Hosts tab, then `SSHFeature.openHost(_:)` (new public entry, opens its terminal or editor) |
| direct host | `.hosts` |
| settings page | `.settings`, then `ShellSettingsModel.openedPage` (new, drives a `navigationDestination`); Diagnostics and What's New use their routes |
| new task | `.compose` |
| pair a Mac | QR scanner sheet (`QRScannerView`), the link goes to the router (B6 grammar) |
| add SSH host | Hosts tab, then `SSHFeature.presentAddHost()` (new public entry) |

Opening a result records the query as a recent search.

## 6. Gaps found

- The workspace mirror has no cwd. The wire carries cwd only on `workspace.create` and per attached
  terminal (`terminal.title`). Search matches title, tab titles, preview lines, group, URL, agent and
  machine; a cwd field on `WorkspaceSurface` (A0 `Tab.cwd`, served by B5) would add it with one line
  in `WorkspaceSearchProvider`.
- `.workspace` routes open the workspace detail; the surface id is not yet focused (C5 has no
  surface push entry).

## 7. Terminal scrollback search (seam, not built)

`TerminalScrollbackSearch.search(_ query:, in: TerminalSearchTarget, limit:)` returns
`[ScrollbackMatch]` (line text, line offset from the bottom). The real implementation would page
`terminal.history {before, max_bytes}` from C1's attach, strip escapes, match with `SearchMatcher`
(substring tier only), and stop at a byte budget (256 KiB). Not built: cmux-tui answers
`terminal.history` with `proto.unsupported` today (c1-terminal-rpc.md), so it would ship dead.
`UnavailableTerminalScrollbackSearch` throws `.unsupported`. D1 owns in-terminal find UI later.

## 8. Tests

Swift Testing in `CmuxiOSSearchCoreTests`: normalization (case, diacritics, width, kana), word starts
(separators, camel case, digits), every tier and the tier order, ranges, multi-token, field weights
and the subsequence switch, ranking order and grouping, per-group cap, boosts, providers mapping
(workspaces and tabs, feed, hosts), recent searches (dedupe, cap, order, clear), session debounce on a
test clock. They run with `swift test` on macOS through a scratch package that links the same
sources, and compile for the simulator.

## 9. Status (2026-10-06)

Done: `CmuxiOSSearchCore` and `CmuxiOSSearch` as above, the Search tab (`searchTab` flag, DEBUG on,
`UISearchTab` on iOS 18), Cmd-K (`ShellRootController.onSearchCommand`, skipped while the selected
screen hides the tab bar so terminals keep Cmd-K), `cmux://search?q=`, `SSHFeature.openHost` and
`presentAddHost`, `ShellSettingsModel.openedPage`, and `.workspace` routes now opening the workspace
detail. 38 Swift Testing tests in `CmuxiOSSearchCoreTests` pass on macOS through a scratch package;
`CmuxiOSApp`, `CmuxiOSSearchCoreTests`, `CmuxiOSPlatformTests` (new search route cases) and
`CmuxiOSShellTests` compile for `arm64-apple-ios17.0-simulator` with SwiftPM.

Unverified: everything visual (no simulator run), VoiceOver and Dynamic Type, hardware-keyboard
arrows over the focused search field, Cmd-K with no first responder after a field resigns (the
shell becomes first responder only on appear), and the `CmuxiOSPlatformTests` route cases at run
time. Tagged build `nxc15` not attempted (known blockers: no fleet manifest on this Mac, dev backend
VM unreachable, 14 GiB free).
