# iOS persisted formats: what each stores, what another build does on read, the next bump

Leo: "well clearly we need to be able to support the multiple versions as it goes".

Four version constants on the phone, registered in `formats.toml`. Each `migrate` entry has fixtures here, one
per version an older build wrote, and a Swift test that loads every fixture through the real reader, both as this
build and as a stand-in for a newer build's file (the fixture's `newer_build_sql`, or extra keys).

| Format | Policy | Fixtures | Test |
|---|---|---|---|
| `MobilePairedMacStore#currentSchemaVersion` (12) | migrate | `mobile-paired-mac-store/v1, v11, v12` | `pairedMacStoreFixturesLoad` (CmuxMobilePairedMacTests) |
| `ConversationHistoryDatabase#schemaVersion` (1) | migrate | `conversation-history-database/v1` | `conversationHistoryFixturesLoad` (CmuxConversationCoreTests) |
| `DiagnosticReport#currentSchemaVersion` (1) | migrate | `diagnostic-report/v1` | `diagnosticReportFixturesLoad` (CMUXMobileCoreTests) |
| `DiagnosticReport#currentHumanReadableFormatVersion` (2) | rebuild | none | none: not stored |

## Paired Macs (`paired-macs.sqlite3`, SQLite `user_version`)

**Stores:** every Mac the phone paired with, per owner scope (`owner_key` = Stack user, team and instance tag
joined by U+001F). Each Mac has a name, customizations, the active flag, connection method and direct addresses
(JSON). It also has its routes (`mac_routes.endpoint_json` holds the whole `CmxAttachRoute` JSON), Tailscale
grants (v8+), and route tombstones (`mac_route_removals`, v12: endpoint-only JSON with sorted keys; `*` removes
a whole kind).

**Older file, newer build:** `runMigrations` steps it from its version to 12, one transaction per step. The
v1 fixture covers the whole chain: device ids are canonicalized (v7), and a Tailscale route becomes a migration
grant (v8). The v11 fixture covers adding the tombstone table.

**Newer file, older build (downgrade):** the store keeps `user_version` as it is, reads columns by name (an
added column is ignored), and skips a route row it cannot decode (a new kind or endpoint shape). The Mac list
reads in full.

**Data loss found and fixed in this change:** when the older build saved a Mac's routes again (on every
`upsert`, and on the route-authority paths), it ran `DELETE FROM mac_routes WHERE mac_device_id = ? AND
owner_key = ?`. That deleted the rows only the newer build could read, so after an upgrade back, those routes
were gone. Every replace now calls `deleteReadableRoutes`, which deletes only the rows this build decodes and
keeps the rest. The fixture test proves it: it rewrites the routes of the Mac that has a `quic` route in a
newer-build file, then checks that the `quic` row, the newer column's values and `user_version` all survive.

**Remaining caveat:** a route that a later build rejects (for example, after tightening validation) stays
stored but hidden until the person forgets the Mac or pairs it again.

## Conversation history (`history-<account hash>.sqlite`, SQLite `user_version`)

**Stores:** one account's Chief conversation history. Message bodies are `JSONEncoder` output of
`ConversationMessage` in a BLOB, keyed by conversation and id and ordered by seq. Per conversation it keeps the
info (title, participants, list state), my participant id, and the synced range. It also keeps deleted-for-me
marks, which a later sync never brings back.

**Older file, newer build:** v1 is the only version so far. The fixture includes a message written before
`tables` existed; `@ConversationEmptyWhenMissing` reads it as `[]`.

**Newer file, older build:** `migrate()` returns early when `user_version` is newer, so the file is left as
it is. The reads select columns by name.

**Risk (no loss today):** a body that fails to decode is skipped silently. A new non-optional
`ConversationMessage` field would therefore hide every stored message from an older build, and an older build
would also hide every message written before the field existed. A new field must be optional or carry a
default when missing.

## Diagnostic report (`DiagnosticReportArchive` JSON file, `schemaVersion` key)

**Stores:** the previous process's connection diagnostics: role, anchors, build stamp, and up to 4096 events
with numeric codes. It is at most 1 MiB, and the person sends it in a bug report.

**Older file, newer build:** read as is. `schemaVersion` is not checked, and the fixture is the exact archive
file.

**Newer file, older build:** unknown keys are ignored (the test adds one and raises `schemaVersion`). An
unknown `DiagnosticEventCode`, though, fails the whole decode, and `load()` returns nil. That loses one
snapshot of diagnostics, not work, so it is accepted as is.

`currentHumanReadableFormatVersion` is the version of the plain-language text in an export. Nothing reads it
back, so its policy is `rebuild`.

## The next bump

1. **Add only.** Add new columns (nullable or with a `DEFAULT`), tables, JSON keys (optional in Swift) and enum
   cases. Never rename or drop. Write the downgrade behavior here before the bump.
2. **Rewrite only what the build reads.** A write that replaces rows (like routes) deletes only the rows this
   build decodes.
3. **Bump the constant and add `v<N+1>.json`**, made the way the new build writes. Never edit or delete an older
   fixture, except below a raised `floor` in `formats.toml`, and say why in the PR. If the new build adds what an
   older build must survive, add it to the newest fixture's `newer_build_sql`.
4. **Run `python3 scripts/ci/persisted_formats.py`**, then the package's Swift tests on the fleet
   (`cmux-ci compile-check --package NAME`, or the PR's Linux package job).
5. **A change to fixtures alone does not start the Swift Linux job** (its path filter covers package sources).
   Run the package job by hand, or touch the test.
