See plans/cmux-next/coordination/INDEX.md for the generated coordination ledger.

### ALL-CHATS-ON-DEVICE S8 — Swift chat settings

Config owns `agents.chats.enabled` (true), `agents.chats.discovery` (true), and
`agents.chats.roots` ([]). All three refuse agent writes with `privacy`.
Unlike ordinary managed preferences, roots are additive (managed rows stay locked;
user roots remain editable), and enforced booleans may only force off. Team and MDM
root layers are deduplicated, with provenance retained separately from the user file.

The app initializes the local AcpmuxEnvironment socket, then sends line JSON-RPC
`_acpmux/chat_settings` with `{enabled, discovery, roots, managedRoots}`. `roots` is
only the user's validated absolute paths; `managedRoots` is only validated managed
paths. The result must contain `applied: true`. Settings observation and socket vnode
events drive updates; an older daemon's -32601 gets one debug log. No polling.
The new schema validation domain `chat_roots` needs the Rust config validator to use
its protected-folder check (including home and symlinks), not generic folder-list
validation. No Rust files are changed in this lane.

Canonical artifact regeneration runs on the fleet, in Packages/macOS/CmuxNext:
`CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter SettingsSchemaExportTests` and
`CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests`.
Then `node webviews/scripts/pages/gen-strings.mjs settings` and
`scripts/cmux-next/build-pages-web.sh` from the repository root rebuild the page.
