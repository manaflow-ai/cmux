# The model catalog follows the public feed, and reads the live models backend first

Landed in ef3e54313f7e (feat-cmux-next). User 2026-11-19: "gemini neon didn't automatically appear
in model picker for us".

What changed in acpmux:

- `catalog/fetch.rs`: `HttpsFetcher` tries `CATALOG_URL` (now
  `https://cloud-api.cmux.dev/v1/models/catalog`, the live models backend) and then
  `FALLBACK_CATALOG_URL` (`https://cmux.com/api/models/v1`, which answered 404 in production) in
  order; the first answer wins. A dev build's https `ACPMUX_CATALOG_URL` is still the only URL.
- `catalog/feed.rs` (new): the daemon reads the public model feed (models.dev) itself, with
  If-None-Match (a 304 has no body; a change is about 0.7 MB gzip, at most 16 MiB on the wire and
  48 MiB decoded). The body is parsed in `spawn_blocking`, and only the models of the providers
  the catalog's `feed` rules name are kept. `overlay` adds the models the rules select and the
  copy in use lacks, newest first, and never changes a row the catalog lists.
- `catalog/mod.rs`: `State` keeps `base` (the fetched, stored or bundled copy) and `catalog` (base
  plus the overlay, minus disabled rows). `refresh` fetches both and announces one
  `catalog.changed`; `REFRESH_EVERY` is 1 h (was 6 h). The summary has `feedAt`; a refresh reply
  has `feedError` when the feed read failed.
- `catalog/schema.rs`: optional `runsAnyModel` and `feed` on a harness; status `disabled`. A
  disabled row leaves the catalog in use after the overlay (`feed::drop_disabled`), its id goes to
  `CatalogHarness::disabled` (never on the wire), and a disabled `defaultModel` is cleared.
- `hub/models_view.rs`: a `runsAnyModel` harness (Gemini CLI) gets every catalog model, not only
  the ones its fixed ACP menu names; the ones newer than its whole menu lead `topModels`. A
  disabled id is dropped from every harness's list, also when the agent reports it.
- `daemon.rs`: `attach_feed(FeedFetcher)` next to the catalog attach, only when the daemon
  fetches the catalog.

Cost: one conditional GET per hour per source; no request path takes a lock across I/O (logs run
with the state unlocked, `log_lock_tests.rs`). Tests: `catalog/feed_tests.rs`, the
`picker_models_tests` in `models_view.rs`, `tests/catalog_rpc.rs`.
