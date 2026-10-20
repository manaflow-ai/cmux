# cmux-tui API compatibility: parity with Rex (msg 2785)

Rex's design: every API change is a rule on a JSON pointer; for each message
the rules between two versions compile lazily into a trie keyed by path
tokens; a forward-only streaming JSON editor copies every value whose key
matches no trie subtree; equal chains are interned so a broadcast is
translated once per distinct chain; a 10,000-revision chain upgrades a 20 KB
body in about 35 us.

## 1. How cmux versions its protocols today (audit, 2026-10-19)

| Protocol | Version today | On mismatch | Unknown data |
|---|---|---|---|
| Daemon raw protocol (app-daemon.sock, NDJSON `{id, cmd, ...}`) | `protocol: 12` in `identify` (`cmux-tui-core/src/server.rs` `PROTOCOL_VERSION`), capability strings since then | The server never negotiates. Clients decide | 41 `deny_unknown_fields` in cmux-tui-core |
| Swift app (`CmuxNextDaemon/Connection/DaemonHandshake.swift`) | requires `protocolVersion == 12` exactly | `unsupportedProtocol` | events have `.unknown` |
| iOS `CmuxMobileSSH` | `>= 11` | refuses | - |
| Rust CLI / remote session (`crates/cmux-tui/src/session/remote.rs`) | `== 12` exactly | refuses | - |
| Generated SDKs (rust, go, python, ts, java, cpp, zig) | `MUX_PROTOCOL_VERSION = 12`, per-command `since` | `ProtocolVersion` / `MissingCapability` errors | lenient, `Event::Unknown` |
| Resource API v2 (`cmux.protocol/2`) | its own name | - | hand-written models: 34 `deny_unknown_fields` |
| acpmux host link | `PROTOCOL_MIN/MAX = 1/1` range | `HostFrame::Incompatible` | JSON-RPC values pass through |
| chatmux-relay | `relayProtocolVersion` 6, verbs gated by version | per verb | vendored schema |
| cmux-cloud-wire (`cmux.wire/1`) | envelope name | - | `serde(default)` everywhere, `Unknown(String)` variants (best of the lot) |
| cmux-tui-machine-protocol | `1`, exact | refuses | - |

What has broken across versions:
- Every protocol bump (7 -> 12) touched about 40 binding, fixture and manifest files, and each one locked out every older client, because clients check `==`.
- `864abe367e4`: exact-match checks rejected compatible journal versions.
- `39bbfd857e1`: an old Cloud VM daemon on protocol 12 with only 28 capabilities answered new commands with "unknown variant". It had the same number but a different surface. Capability strings hide drift instead of translating it.
- `9cf8012849c`: the inventory grew to 208 commands under the same v12.
- Rename/remove/retype has no path at all: the only tool is "add a capability and keep both shapes forever" (for example `conversation_tabs_wire.rs`, which downgrades conversation tabs to browser tabs by hand).

## 2. Gap to Rex, and what landed

| Rex | cmux before | cmux now (`crates/cmux-api-compat`) |
|---|---|---|
| Rule per change on an RFC 6901 pointer | none | `Change`: rename, move, add, remove, retype, rename_value, fill; `*` wildcard for arrays and maps; each has an exact inverse |
| Versioned schema, revision in hello | `protocol` number only, no negotiation | `spec/api-compat.json` (base 12). `identify` sends `api_revision` and `min_api_revision`. `set-client-info {api_revision}` declares the client's revision |
| Lazy trie per message, no N^2 build | - | `Compat::program(kind, from, to)` folds the chain into one trie on first use and caches it. A 10k rename chain collapses to 4 nodes |
| Forward-only streaming editor with raw fast-path copy | - | `stream.rs`: values off the trie are copied as bytes, without parsing. Only retypes and cross-parent moves parse their subtree |
| Equal chains interned, broadcast once per chain | - | interned by step list (`Arc::ptr_eq`). `Compat::broadcast` translates 1,000 peers on 4 revisions in 4 rewrites |
| Both directions | - | the newer side translates both ways (`handshake::negotiate`). Old client + new daemon: the daemon translates. New client + old daemon: the client translates |
| ~35 us, 10k chain, 20 KB | - | see the bench numbers in the report (`tests/rex_parity_bench.rs` on the fleet) |
| (implicit) every change has a rule | `check-sdk-schema.py` checks drift only | `api-compat-check` (CI job `api-compat` in `cmux-tui-spec.yml`, plus a cargo test): a breaking diff of `sdk-schema.json` against `spec/api-compat.surface.json` without a rule fails. Additive diffs only require a snapshot refresh |

The daemon wiring is in `cmux-tui-core/src/server/api_revision_wire.rs`:
- Request lines from an older client are upgraded before any parse.
- Responses (`response:<cmd>`, matched by `id`) and events (`event:<name>`) are downgraded as the last outbound projection.
- Native and newer clients cost one atomic load per message.

## 3. Actionables

Done (on `feat-cmux-next`):
1. `cmux-api-compat` crate: rules, lazy trie, streaming rewriter, interning, broadcast, negotiation.
2. Property tests: streaming equals the rule-by-rule reference on random docs and random chains in both directions. Upgrade then downgrade round-trips. Garbage input never panics.
3. Rex-shape bench: 4 pathological 10k-revision scenarios on a ~20 KB body, plus broadcast.
4. Daemon: revision in `identify` and `set-client-info`, request upgrade, response and event downgrade.
5. CI guard and surface snapshot (641 message kinds, 4,500+ members).

Next (in priority order):
1. **Clients send their revision.** The Swift app (`DaemonHandshake.swift`), the Rust CLI (`session/remote.rs`, `local_owner.rs`) and the generated SDKs must send `api_revision` in `set-client-info`. They must also replace `protocol == 12` with "`api_revision` within `[min_api_revision, ours]`, otherwise translate as the newer side". Until then every client counts as revision 12, which is correct today because no revision exists yet.
2. **Freeze `protocol` at 12.** From now on, ship breaking changes as compat revisions. A `protocol` bump still locks out every old client.
3. **New-client side translation.** When the client is newer than the daemon, the client must translate. Embed the same `api-compat.json` in the Rust client (bindings/rust: `Compat` plus `Negotiated::outgoing/incoming`). For Swift, either use an FFI to the crate (like `cmux-layout-reducer-ffi`) or route through the daemon client crate.
4. **Cover the other daemon lanes.** Resource API v2 lines (`cmux.protocol/2`), `session.events` stream items and journal replay do not pass through `send_control` yet. Apply the same projection to `project_conversation_tab_item`'s call sites.
5. **Broadcast fan-out in the daemon.** Events are serialized per connection (`cmd_subscribe.rs`). Cache the translated bytes per (event, chain) with `Compat::broadcast` once more than one client is old.
6. **Retire hand-written downgrades.** Re-express `conversation_tabs_wire.rs` (conversation tab -> browser tab) as rename_value/remove rules where the shapes allow it.
7. **Same system for acpmux, chatmux-relay and cloud-wire.** Each one gets an `api-compat.json`, and `Compat` replaces its per-verb version gates.
8. **Streaming cross-parent moves.** Today a move between different parents parses the subtree at the common ancestor. Rex's editor never parses. Add a capture-and-emit pass for moves whose destination closes after the source.
9. **Measure-script allowlist.** `scripts/measure/api-compat-bench.sh` exists, but the HQ controller does not allowlist it yet (`build-fleet/cmd/controller/ci_step.go`). Until it does, the bench runs as the `api_compat_bench` fleet test.
10. **Linux skew matrix.** `cmux-next-skew-matrix.yml` (CLI N against daemon N±1) is dispatch-only. Run it on every push with old builds pinned from nightly, so compat rules get exercised by real old binaries.
