# chatmux-relay

Rust port of the chatmux machine relay — the outbound-only client a paired
personal machine or a provisioned sandbox runs to stay reachable as a
chatmux target. It replaces the Node CLI in the chatmux repo
(`packages/relay`, npm `cmux-relay`) behind the same wire, the same config
file, and the same npm install name.

This crate is NOT `cmux-relay` (the sibling crate in this workspace): that
is the self-hosted encrypted-circuit relay server, a different product. The
npm distribution of THIS crate keeps the `cmux-relay` package name because
production sandbox images and the pairing docs install it by that name.

## What it does (target state)

- Pairing ceremony against the chatmux Worker (`POST /v2/pairing/start` +
  the pairing WebSocket): x25519 key fingerprint, cute-code SAS, URL
  approval flow and the `--code` QR/SAS fallback.
- Persistent presence: `hello` negotiation, heartbeats, and reconnect with
  jittered backoff on `wss <backend>/v2/relays/{deviceId}/socket`.
- Local trust authority (observe / supervised / autonomous with the
  owner-at-keyboard YOLO receipt) — the machine's config always wins over
  the server row.
- Managed sandbox mode (`--managed --enrollment-file <path>`): one-shot
  0600 enrollment file, shredded after read, exchanged for a runtime-only
  session token.
- Exec verbs (exec/read/write/ls/grep/find) with trust gates and
  `--allow-root` path scoping.
- PTY bridge to cmux-tui control sockets and fallback `$SHELL` sessions,
  multi-viewer fan-out (relay wire v4/v5).
- Wire-v6 pane data-plane verbs (fs_tree/fs_read/fs_write CAS/fs_search/
  git_status/git_diff/fs_watch) and the chobitsu preview proxy.

One binary serves both paired human machines and sandboxes. Job sessions
keep launching through the `cmux` CLI daemon; the relay attaches to them
over the shared control socket (`cmux-terminal-client`).

## Port plan (slices)

Each slice is gated on the JS relay's behavior; the chatmux e2e conformance
harness is the cross-language gate (see below). The JS relay is deleted at
cutover — pre-launch, no legacy.

1. **Config + pairing + presence (THIS SLICE, done)** — config file
   handling (`~/.config/chatmux-relay/config.json`, 0600), URL + `--code`
   pairing ceremonies, hello/heartbeat/reconnect, trust policy incl. the
   YOLO receipt, managed enrollment (0600 check, shred after read,
   `managedSessionToken` kept in memory), `--allow-root` persistence,
   `--status`.
2. **PTY bridge** — port `bin/pty.mjs` incl. the 0.0.10 MULTI-VIEWER
   fan-out (any number of attachments per session/surface; `session_limit`
   only for the process-wide PTY cap). `packages/relay/test/pty.test.mjs`
   pins the behavior. Raise the advertised dialect to 4.
3. **Exec verbs + trust gates** — port `bin/actions.mjs` (path scoping,
   caps, timeouts). Raise the advertised dialect to 5.
4. **Wire-v6 pane verbs + preview proxy** — fs/git/watch verbs and the
   chobitsu-injecting preview proxy (chatmux pane-primitives program;
   these verbs have NO JS implementation — Rust-first by decision).
5. **Autostart** — launchd/systemd/schtasks install (`--autostart` /
   `--uninstall`), replacing the npm runtime-install machinery with the
   platform binary path.

### Intentional slice-1 divergences from the JS relay

- The advertised relay protocol is **v2** (`wire::ADVERTISED_PROTOCOL_VERSION`)
  until the verb slices land, so the Worker's designed old-relay degrade
  applies instead of half-implemented verbs. The JS relay advertises v5.
  DIALECT: the workspace slice implements the full v6 verb set but does
  NOT bump the advertised dialect — the PTY + exec slices (dialect 4/5)
  land in parallel, and whichever slice merges LAST raises the advertised
  dialect to 6 once e2e-relay + e2e-terminal-pty + e2e-workspace are all
  green on the combined head. Harness runs meanwhile use the existing
  `CHATMUX_RELAY_PROTOCOL=6` env override. Workspace frames that arrive
  are always answered (typed refusal for unknown ops, never a socket
  close); exec/PTY frames keep the slice-1 refusals.
- `--code` prints the `chatmux://pair` link without the terminal QR
  graphic (QR rendering comes with a later slice; the link carries the
  same payload).
- `--autostart` / `--uninstall` exit 1 with a pointer to the npm build
  (slice 5).

## Wire contract and the vendored protocol

The wire truth is chatmux `packages/protocol/src/relay.ts`, emitted to
`generated/schema/relay-client.schema.json`. A Rust serde emitter is being
added to the chatmux protocol codegen (alongside the existing Swift and
Kotlin targets) together with the wire-v6 pane verbs.

The generated file is VENDORED here as `src/relay_wire.rs` (chatmux
`packages/protocol/generated/rust/relay_wire.rs`, copied verbatim — never
edited, only re-vendored; `#[rustfmt::skip]` on the module declaration
keeps the generated layout as the diff baseline). Vendored from chatmux
commit `271c6efc445fd083165519d20588c2fcbf0eb765` (10 workspace ops). To re-vendor after a
chatmux protocol change:

1. In chatmux: `cd packages/protocol && bun run generate`.
2. Copy `packages/protocol/generated/rust/relay_wire.rs` over
   `src/relay_wire.rs` verbatim and update the sha recorded above.
3. Run the chatmux conformance harness against the rebuilt binary
   (`apps/backend/test/e2e-workspace.ts` with `CHATMUX_E2E_RELAY_BIN`).

`src/wire.rs` still hand-models the slice-1 core frames (hello,
heartbeats, trust) with the tolerant parse; the v6 workspace frames decode
through the vendored types (workspace.rs / watch.rs / preview_proxy.rs).
The remaining hand-modeled structs migrate to the vendored file with the
PTY/exec slices.

## Preview proxy (slice 4, this crate)

`preview_open` starts (or reuses) a reverse proxy of the target dev-server
port per the pinned contract in chatmux pane-primitives-plan.md: chobitsu
script-tag injection into text/html (skip on `x-chatmux-no-inject: 1`),
`GET /__chatmux__/target.js` (vendored chobitsu 1.8.6 + connector, in
`assets/`), `WS /__chatmux__/page` + `WS /__chatmux__/devtools` piping
(latest page connection wins), `GET /__chatmux__/status` with credentialed
CORS (ACAO=origin + ACAC=true), and a bounded console/network ring served
by `preview_console_tail`.

## Conformance harness (chatmux repo)

The cross-language gate lives in chatmux `apps/backend`:

- `test/e2e-relay.ts` — `--code` pairing + presence + heartbeats.
- `test/e2e-pair-url.ts` — URL approval flow, deny path, rate limit.
- `test/e2e-terminal-pty.ts`, `scripts/terminal-dev-server.ts` — PTY
  (slice 2 gate).
- `test/e2e-workspace.ts` — wire-v6 workspace verbs + fs_watch + preview
  shapes (this slice's gate; `CHATMUX_E2E_RELAY_BIN` points it at this
  binary, with `CHATMUX_RELAY_PROTOCOL=6` until the dialect bump — see
  DIALECT below).

Point the harness at this binary with `CHATMUX_RELAY_BIN`:

```sh
# chatmux repo, terminal 1
cd apps/backend && bunx wrangler dev --var CHATMUX_FAKE_AUTH:1 \
  --var DAYTONA_API_KEY:local-e2e-dummy \
  --var DAYTONA_API_URL:https://daytona.invalid/api \
  --var CHATMUX_RELAY_HEARTBEAT_MS:2000

# terminal 2
CHATMUX_RELAY_BIN=/path/to/chatmux-relay bun test/e2e-relay.ts http://localhost:8788
CHATMUX_RELAY_BIN=/path/to/chatmux-relay bun test/e2e-pair-url.ts http://localhost:8788
```

(The `CHATMUX_RELAY_BIN` override lands in chatmux alongside this crate;
without it the harness spawns the JS relay.)

## npm distribution plan

The npm name stays **`cmux-relay`** so sandbox images and the pairing docs
change nothing but the version:

- Platform packages `cmux-relay-<os>-<arch>` (darwin-arm64, darwin-x64,
  linux-x64, linux-arm64, win32-x64) each ship one static binary, wired as
  `optionalDependencies` of `cmux-relay` — the same scheme the `cmux` /
  `cmux-tui` packages use.
- The `cmux-relay` wrapper's bin shim resolves the platform package (env
  override → optionalDependency → PATH fallback) and `exec`s the binary.
- Publish as `0.1.0` from this workspace's release tooling; rebake images
  (bump `CHATMUX_IMAGE_EPOCH`) in the same series that deletes
  `packages/relay` from chatmux.

## Development

Workspace rules apply (`cmux-tui/AGENTS.md`): no local cargo on the
maintainer Mac — push and use `./scripts/verify-cmux-tui-hosted.sh
--filter chatmux_relay` (or `--full` for the merge gate).

```sh
cargo test -p chatmux-relay          # unit tests (hosted or Linux builder)
cargo clippy -p chatmux-relay --all-targets -- -D warnings
```

The unit tests mirror the JS relay's test files (`cli-args.test.mjs`,
`trust-policy.test.mjs`, `managed-enrollment.test.mjs`) plus pinned
cross-implementation vectors for the cute-code fingerprint and Node's
SPKI/base64url/sha256 encodings.
