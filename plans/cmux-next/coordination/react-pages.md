# Lane: react-pages

## Active streams
- History and App Store as React pages with a Rust backend (React UIs lead, R62 UI-STACK). Design: plans/cmux-next/react-pages.md. Pages live in `webviews/src/pages/<page>/`; `webviews/src/pages/shared/pageClient.ts` is the only transport file (pane-protocol envelope over the `cmuxPage` WebKit bridge until the daemon router lands). Touches: webviews dev server (`/history/` route), CmuxNextHistory xcstrings (page strings source), `cmux-history` crate (H2), daemon `history.*` ops (H3, main window), app platform `cmux.apps.*` ops (theirs).

## Landed
- 2026-10-04 d8431616164 cmux-tui: cmux-history crate (H2): HistoryEntry wire model, HistoryQuery (icu_normalizer NFKD fold: case, marks, width), agent and command journal folds, HiddenHistory merge (reads the Swift `history.hidden` document), per-profile SQLite VisitStore; shared fixtures in `cmux-tui/crates/cmux-history/tests/fixtures/`; 63 tests on a Testbox (React UIs lead)
- 2026-10-04 (this commit) webviews: History page H1 on a mock provider (`/history/?mock` in the webviews dev server), `pageClient.ts`, page string generator `webviews/scripts/pages/gen-strings.mjs` (+`--check`), new key `page.disconnected` in CmuxNextHistory xcstrings. Not in the shipped bundle yet (H1b adds the host) (React UIs lead)
