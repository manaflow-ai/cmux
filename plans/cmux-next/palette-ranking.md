# Palette ranking (Cmd-Shift-P)

Status: design and landing log, bead cx-9ce.27, 2026-10-08. Lawrence: "cmd shift p search needs to be better. idk how, but it doesnt feel good today, in terms of the stuff it surfaces for me/ordering." Binding inputs: layer-ownership.md, palette-scopes.md (scopes, `palette.query`), cmux-next-spec `spec/keybindings-and-palette.md` section 2 (recents, pins, hidden, aliases; K1 to K5).

## 1. What the root palette is today

The root page (`PaletteController+Pages.swift` `commandsPage()`) has these providers: catalog actions (846 palette-offered, `RegistryPaletteProvider`, keywords = descriptor keywords + the action id), workspaces, tabs, settings rows, app rows, and scope rows (typing only). Workspaces, tabs, settings and apps appear only when the user types. There are no file, chat, bookmark or history rows in the root.

Ranking runs once, in `webviews/src/palette/ranker.ts`, through JavaScriptCore (`PaletteRankerBridge`), for the app, the web palette and the headless `palette.query` socket verb (agents, scripts). Score = per-token fuzzy score over title (weight 100), keywords (80), subtitle (65), accessory (50), plus a phrase bonus, minus a length penalty, plus `rankBias`, plus a frecency boost (at most 60), plus 500 when the title is the whole query, minus 1000 when the row is disabled.

Usage history (`FrecencyStore`: +1 per use, half-life 3 days, 500 keys) is recorded only for rows run from the palette, and persists in UserDefaults of the app bundle.

## 2. Why it does not feel good (findings)

1. Category sections bury the second-best row. While typing, rows stay grouped by their section, and sections are ordered by their best row. All matches of the winning category come before the best row of the next one, so for "split" every weak Panes match comes before "Split Browser Right". The catalog has 13 categories, so this happens for most queries.
2. Scattered subsequence matches compete with real matches. A token may match letters anywhere in the title or in the joined keyword string, so short queries ("sr", "nt", "theme") pull in unrelated rows with a small score difference.
3. The keyword field contains the action id (`newTab` is the id of "New Workspace", `palette.*` prefixes 200 ids), so "new tab" and "pal" match ids, not what the user reads.
4. No typo tolerance: "spilt", "sttings", "clsoe tab" return nothing useful.
5. Usage history is lost on every dogfood build: UserDefaults is per bundle id, and every tag has its own bundle id. Lawrence's 35 dogfood builds hold 35 separate short histories (largest: New Column 31 uses, New Agent Chat 15, Open Debug Settings 7). A fresh tag starts with no Recent section.
6. The empty query shows Recent (only when history exists) and then all 846 actions in category order (Window first). Without history the first rows are New Window, Close Window, Zoom, not what a new user needs.
7. Usage is per row, never per query: picking "New Agent Chat" for "new" ten times does not make "new" prefer it over a better text match.
8. Shortcuts and menus do not record usage (`recordUse(of:)` has no callers).

## 3. Eval set (measured, not guessed)

- Fixture: `webviews/test/fixtures/palette-eval/root-entries.json`, the exact ranker input of a tagged build's root page, written by `debug.palette.entries` (DEBUG socket verb) through `scripts/cmux-next/palette-eval-live.py`. `overlay.json` adds the workspace and tab rows a real session has (fresh builds have one workspace), in the providers' shape.
- Cases: `cases.json`, 111 queries with expected rows (any listed id is correct; the first is the best): exact titles, partial words, concepts and synonyms, acronyms, typos, workspaces and tabs, Lawrence's real usage profile (aggregated read-only from the frecency keys of his dogfood builds; action ids only), and the empty query.
- Metrics: top-1 rate, top-3 rate and MRR over the rows in display order (sections flattened as shown). `bun scripts/palette-eval.ts` prints the report and every miss; `--live FILE` scores rows a real build returned through `palette.query`. `webviews/test/palette-eval.test.ts` fails when a metric drops below the recorded floor, so every ranking change reports before and after numbers.

## 4. Research summary

- VS Code quick open and command palette: `fuzzyScore` rewards contiguous runs and matches at word starts and camelCase humps, and the first character more; the command palette puts "recently used" commands first for an empty query and boosts them while typing; a match must start at a word boundary for short queries.
- Sublime Text / fzf / Zed: one match-quality score; the best result list is flat, never grouped by category while typing.
- Raycast and Alfred: frecency per item plus per-query learning ("you picked X for `ne`"), user aliases, and favorites (pins) shown in the empty view; Alfred's knowledge is keyed by the typed prefix.
- Chrome omnibox: match class first (exact, prefix of a word, substring), then usage; a "top hit" row before the grouped results; groups are capped.
- Arc command bar: a flat ranked list, recents first when empty.

## 5. Design

One scorer, match class first (`matchTier` in ranker.ts; 1000 points per unit, so nothing else crosses a class):

| tier | match |
| --- | --- |
| 12 | the whole title is the query |
| 11 | a scope row whose keyword is the whole query ("settings" enters the settings scope) |
| 10 | the title starts with the query in whole words ("split" for Split Right); or the query is the whole action id |
| 9 | every token is a whole title word ("chat" for New Agent Chat) |
| 8 | the title starts with the query, the last word cut ("brows") |
| 7 | every token starts a title word |
| 6 | acronym: the query starts the title's word initials ("sr", "nac"; camelCase humps count) |
| 4 | every token is a title substring or starts a keyword word; or an id-shaped query (a dot or a capital) starts the action id |
| 3 | typo: every token matches strictly or is one edit (insert, delete, substitute, adjacent swap) from a title word or its start; 3-letter tokens allow only a swap. Looked for only when the strict pass finds fewer than 3 rows at tier 4 or better |
| 2 | fuzzy: every token matches in order from a title word start, or is a keyword, subtitle or accessory substring |

Letters scattered without a word-start anchor no longer match. The action id is no longer a keyword (it matched ordinary words: `newTab` is the id of New Workspace, 80 ids start with `palette.`); it is a separate field that only the whole id or an id-shaped start matches. Setting rows (`PaletteItem.isDemoted`) drop 3 units, so a setting ties a command one match class weaker, and inside a tier a command always comes before a setting (ten settings are titled "Color"; "color" now starts with Set Workspace Color…). Trade-off: "theme" now starts with Use Theme Color for Pane Borders, the Theme setting comes after the theme commands.

Score = tier x 1000 + quality (the existing contiguity and word-start score, a phrase bonus, a whole-initials bonus, minus a length penalty; 0..880; whole-title rows get the maximum so the provider order breaks their ties) + `rankBias` + the frecency boost (at most 60) + the learned pick boost (5.2, next step). Order: enabled rows first, then the tier, then commands before demoted rows, then the score; equal scores prefer a row with a shortcut (Split Right over Split Up; no score boost), then the provider order.

### 5.1 Sections while typing

While typing, the root (`PalettePageSpec.mergesSectionsWhenTyping`) shows one untitled list, best first; rows keep their icon, subtitle and accessory, so the kind stays visible. Before, a section ordered by its best row put all its weak rows above the next section's best row (the 211 setting rows buried New Browser Tab for "browser"). The empty query keeps the category sections. Other pages keep their sections.

### 5.2 Usage and learned picks

- Learned picks: when the user runs a row for a query, the store records (normalized query prefix, row) for each prefix of length 1 to 4 of the query. A later query whose prefix has picks boosts those rows, enough to beat one tier, never a whole-title match. This is Alfred's knowledge and the VS Code recently-used boost in one rule.
- Empty query: Pinned (cmux.json, later), Recent (8, any row kind, not only actions), then Suggested (a fixed list of first-use commands, shown only while Recent has fewer than 8 rows), then the categories.

### 5.3 Ownership

- The scorer is a product rule and lives once, in `webviews/src/palette/ranker.ts`, which the app (JavaScriptCore), the web palette and `palette.query` (app, CLI, agents, scripts) all call. The candidate rows are assembled by the Swift app from the catalog data file, the daemon mirror (workspaces, tabs), the settings schema and apps, so the ranker sits with that assembly. Moving it into the daemon would mean sending every candidate row to the daemon per keystroke; not worth it while the candidates are app-side.
- Duplicate to remove: `CmuxNextActions/FuzzyMatcher` still scores the Help menu search in Swift (`ActionRegistry+Menus.swift`) and the unused `FuzzyCorpus` in `PaletteSearchIndex.swift`. They move to the shared ranker (follow-up).
- Usage history and learned picks are durable per-user state. Owner target: the daemon store (one writer, synced later, the same for every build tag), with `palette.usage.record` / `palette.usage.get` ops; the app keeps a read mirror. That is a CORE-window change (protocol and store), landed separately with a token. Until then `FrecencyStore` stays the single writer in the app (one store, one persistence object, no view writes it), and the per-tag loss stays a known gap.
- Pins, hidden rows and aliases are user settings (cmux.json, the config actor), FREEZE settings paths, landed with a token in a later step.

## 6. Landings

Eval: `bun scripts/palette-eval.ts` in webviews (fixture), and the same cases against a live tagged build (`--live`). The "before" row is the ranker at the fork point on the original dump.

| step | what | top-1 | top-3 | MRR |
| --- | --- | --- | --- | --- |
| before | ranker at origin/feat-cmux-next a00a8aebc2ac, original dump | 59.1% | 69.1% | 0.650 |
| 1 | eval set, fixture, live runner, `debug.palette.entries` (red commit with the step-2 floors: 60.0% / 69.1% / 0.651 on the reshaped fixture) | | | |
| 2 | match tiers, id field, typo tier, setting demotion, shortcut bonus, one list while typing | 65.5% | 80.0% | 0.753 |
| 2b | commands win same-tier ties with settings (demotion 3), a shortcut only breaks exact ties | 68.2% | 80.0% | 0.757 |
| 3 | learned picks per query prefix, Recent of any row kind, Suggested (catalog field, FREEZE token) | | | |
| 4 | usage store in the daemon (CORE token) | | | |
| 5 | pins, hidden, aliases in cmux.json (settings token) | | | |

Remaining misses after step 2 are mostly usage (Lawrence's "col", "screen": the catalog's color and width variants share the first word) and intent words ("browser" wants New Browser Tab, "notifications" wants Show Notifications); step 3 targets them. Swift palette benchmark (2000 rows, JavaScriptCore): 7.8 ms per query at fdac71e8.
