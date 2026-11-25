# API versions: the compatibility promise

This covers the cmux-tui daemon socket protocol (the raw mux protocol that the
`cmux` CLI, the apps and the SDKs speak). Agents call it from scripts and
prompts that nobody revisits, so a change that silently breaks an old client
hurts them more than it hurts a person at a keyboard.

## The promise

1. **No breaking change ships without a new dated version.** Renaming,
   moving, retyping or removing a field, or changing a value's meaning, is a
   breaking change. It ships only as a new revision in
   [`api-compat.json`](api-compat.json) with a `date`, and with rules that
   translate between it and the version before. Adding an optional field, a
   command, an event or a capability is not breaking; clients must ignore
   fields they do not know.
2. **Every dated version is served for at least 12 months after the version
   that replaced it.** `base_date` in `api-compat.json` (the oldest version
   served) may move forward only to a version that was replaced 12 months
   ago or more.
3. **A client that pins nothing sees no change from this.** It is served as
   before.

`api-compat-check` (CI, `cmux-tui-spec.yml`) fails a change to the protocol
surface that breaks a peer without a compat rule.

## Pinning a version

A client pins the version it was written against, a `YYYY-MM-DD` date, in
`set-client-info`:

```json
{"id":1,"cmd":"set-client-info","name":"my-agent","api_version":"2026-11-24"}
{"id":1,"ok":true,"data":{"api_version":"2026-11-24","api_revision":12}}
```

- The daemon serves the newest version dated on or before the pin and
  answers with the version it served (`api_version`) and its revision number.
  A pin later than this daemon knows gets the daemon's newest version; the
  answer names it.
- From then on the daemon translates both ways on that connection: requests
  are upgraded to the current shape before they are read, replies and events
  are downgraded to the pinned shape before they are sent
  (`crates/cmux-tui-core/src/server/api_revision_wire.rs`).
- A pin older than the oldest version served is refused with the client's
  update command. A malformed date is refused.
- `identify {"revisions": true}` reports `api_version` (newest) and
  `min_api_version` (oldest served).

The numbered `api_revision` field stays; the date is a name for it. Sending
both is allowed when they name the same revision.

## Versions

| Version | Revision | What changed |
| --- | --- | --- |
| `2026-11-24` | 12 | The first dated version: the protocol as of this promise. |

## Adding a version

Add a revision to `api-compat.json` with the next `rev`, today's `date`
(later than the one before) and one rule per break (`rename`, `move`, `add`,
`remove`, `retype`, `rename_value`, `fill`; result paths sit under `/data`).
Then run, from `cmux-tui/`:

```text
cargo run -p cmux-api-compat --bin api-compat-check --locked -- --write
```

and add the row above.

## What it costs

`cargo bench -p cmux-api-compat --bench version_pin` (a 1.8 KB
`list-clients` reply, a 24-version history): a client that pins nothing or
pins the current version pays one atomic load per reply (about 30 ns). A
client pinned one version back pays about 8 us median per changed reply
(peek, program lookup, streaming rewrite), on the order of serializing the
reply (about 2.4 us). Resolving a pin is under 1 us, once per connection.

## The cloud HTTP API

The cmux VM API Worker (`workers/cmux-vm`, `vm.cmux.dev`) makes the same
promise over HTTP. A client sends `Cmux-Api-Version: 2026-11-24`; the Worker
serves the newest version dated on or before it, translates the request up
and the JSON reply down, and answers with the version served in the same
header. A malformed pin, or one older than the base date, gets 400
`UnsupportedApiVersion` naming the oldest and newest dates. A request with no
header is served exactly as before. The table is `API_VERSIONS` in
`workers/cmux-vm/src/api-version.ts` (rename, add and remove, keyed by
`request:` or `response:` and the route); its base date is 2026-11-24.
`bun scripts/bench-api-version.ts` there measures it: about 0.5 us per
unpinned or current-pinned request, about 9 us per reply one version back,
and about 40 ns to resolve a pin a client has sent before.

## Not covered yet

Resource API v2 (`cmux.protocol/2`), terminal byte streams,
`session.events` stream items and the broker tools.
