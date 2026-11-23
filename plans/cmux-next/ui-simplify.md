# Drastically simpler cmux-next UI (a1315, 2026-11-20)

Lawrence, 2026-11-20: "i want you to drastically simplify all parts of the UI and take before/after
screenshots of everything you do".

Rules for every cut:

- Remove before hiding; hide behind hover or Option before keeping. A setting that turns a piece of
  chrome back on is fine; a default that shows it is not.
- Never undo something Lawrence or Leo asked for by name in the last weeks (each kept item below
  names the ask). Those stay; everything around them gets cut.
- One owner per area. Areas another agent owns get my cuts as a message, never an edit.
- Each change: before shot, change (red test first when behavior changes), after shot, light and
  dark, fleet or cmux-lawrence-2 only. Small commits on feat-cmux-next.

## Mine (a1315)

| Surface | Cut | Status |
|---|---|---|
| Sidebar footer | Search button off by default (`sidebar.showSearchButton`); search is the palette (Cmd+P) | batch 1 |
| Sidebar bottom card | Daily "Did you know" tip card off by default (`sidebar.cards.tips`); the update card still shows when an update is staged | batch 1 |
| Agent chats | Feature tip callouts off by default (`updates.showFeatureTips`) | batch 1 |
| Every right-click menu | "Customize Menu…" row off by default (`contextMenus.showCustomizeItem`); Settings > Menus keeps it reachable | batch 1 |
| Workspace hover card | Compact by default (`sidebar.hoverCards.layout`): the facts and the last three moments, not a 20-line scrolling history; Stats and History is one setting away | batch 2 |
| Agent chat and pane copy | 45 strings say one thing each: placeholders ("Ask {agent} anything", "Search, URL or !command"), errors ("Nothing to push.", "Not sent: too large. …"), permission and peer titles. UI text budget allowlist 274 → 234 rows | batch 3 |
| Tab strip | Separators kept (Lawrence 2026-11-05 asked for them); tab menu rows kept (Leo's screenshot, 2026-10-23) | kept |
| Composer | Dictation mic stays (Lawrence uses it); context ring stays (asked for). Nothing cut yet | review |
| Empty workspace | Already one wordmark and one title line; nothing to cut | done |
| Settings > Sidebar > Spaces | The Spaces card shows only from the second space on; one space draws no card, and no Show Spaces / position / visibility row, New Space or Set Space Theme… button (a1283's "no trace with one space"); search and the palette keep them | batch 4 |
| Pane "…" and toolbar | Kept visible at rest (user 2026-11-15: "tabbar right side … is missing now"); nothing cut | kept |

## Passed to their owners (sent 2026-11-20)

| Area | Owner | Cuts sent |
|---|---|---|
| Harness updates menu | a1293 | Update All primary at top, per-row Update on hover, no versions or footer, one line when all up to date |
| Slash menu | a1294 | One line per command, description only on the highlighted row, no section headers or hint footer, ~8 rows |
| Groups as folders | a1301 | Folder glyph plus name only; chevron on hover; no group lines; no empty-group text; hover card name and count only |
| Pin | a1302 | No pin glyph at rest; no "Pinned" header; one Pin row in the menu; no drop overlay text |
| App store | a1303 | Hide fully: sidebar, menu bar, palette, New Tab, Settings category, empty-state links |
| Settings (Personalization merge) | a1304 | Help line only where the title is unclear; no group summaries; merge 1-2 row cards; no per-row Reset |
| Chief replaces Home | a1307 | Transcript plus composer only; no header chips or status line; avatars and timestamps only where needed; one-line empty state |
| Onboarding | a1298 | One screen, one button, one sentence; no step dots; installs in the background |
| Bring Your History | a1299 | Remove every advert of it; import under "Import chats…" in Settings and the palette, no source app names |
| First-screen audit | a1311 | Target: one workspace row and the composer; send other cuts to a1315 |
| Omnibar | a1308 | Host only at rest; field icons only with state; suggestions title plus host, ~6 rows |
| Tooltips | a1282 | Name plus shortcut, one line; none on labeled controls or rows |
| Hide Spaces | a1283 | No trace with one space: footer dots, title, menu rows, settings card |
| Button contrast | a1275 | One filled primary per surface; others plain, fill on hover; destructive as red text |
| Traffic lights, padding | a1244 | One titlebar row, equal padding, no extra divider |
| Diff viewer | a1316 | Toolbar: file list, unified/split, More; bulk actions in More; file buttons on header hover |
| Browser More menu | a1317 | At most ~8 top rows, the rest in More Tools; one Customize Toolbar… row; hide rows that do not apply |

## Shots

Fleet captures (`cmux-ci capture SHA --state …`), light and dark, before at the base commit and
after at the landed commit; the report links each pair. cmux-lawrence-2 was offline on 2026-11-20.

## Neighbour reds (2026-11-21)

Three suites failed on feat-cmux-next and on the base too (a1283):

- `SidebarSearchButtonTests`: code. #44449 gave the footer half-point heights, so the button's
  origin rounded up one device pixel above the avatar's line. `placeSearch()` now rounds the
  origin down.
- `MainMenuPlacementTests`: stale test. Set Up cmux… (#46793, Leo 2026-11-18) is the 11th App row.
- `PointerMenuTrimTests`: stale test. Customize… is on the tab and pane right-click menus (#43407).
- `ContextMenuEssentialsTests`: code and stale test. #40159 put Copy Cloud Session Link in every workspace
  and tab Copy folder, where a local target can only refuse it. The app now leaves it out of a local
  target's menu (CloudTeamMenuRowsTests); the Copy folder test names it.
