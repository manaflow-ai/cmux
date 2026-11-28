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

## What it does

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

The journal-forwarder conformance harness may set
`CHATMUX_RELAY_E2E_BACKEND` to its local stub origin. The relay accepts this
override only when it is an explicit `http://` origin on `127.0.0.1`,
`localhost`, or `::1`, and only for an exact enrollment backend origin. Empty,
remote, HTTPS, and mismatched values are ignored. The production backend
allowlist remains active with or without the override.

## Port plan (slices)

Each slice is gated on the JS relay's behavior; the chatmux e2e conformance
harness is the cross-language gate (see below). The Rust crate is the
implementation used by the new machine-relay packaging. The Node relay in
chatmux remains the rollback implementation until hosted conformance and a
release have completed.

1. **Config + pairing + presence (THIS SLICE, done)** — config file
   handling (`~/.config/chatmux-relay/config.json`, 0600), URL + `--code`
   pairing ceremonies, hello/heartbeat/reconnect, trust policy incl. the
   YOLO receipt, managed enrollment (0600 check, shred after read,
   `managedSessionToken` kept in memory), `--allow-root` persistence,
   `--status`.
2. **PTY bridge (DONE)** — `pty.rs` ports `bin/pty.mjs`: the shell
   fallback with a bounded scrollback ring and the 0.0.10 MULTI-VIEWER
   fan-out (any number of attachments per session; `session_limit` only
   for the process-wide `MAX_PTYS` cap), the cmux-tui whole-session viewer
   path, the W86 raw single-terminal control-socket path, `surface_list`,
   the buffered-output cap, and the no-empty-frame rule.
   `packages/relay/test/pty.test.mjs` behaviors are mirrored in
   `pty.rs::tests`. Real PTY allocation is `pty_deps.rs` (cmux-pty +
   pipe-mode degradation); the control socket is `control.rs`.
3. **Exec verbs + trust gates (DONE)** — `actions.rs` ports
   `bin/actions.mjs`: exec/read/write/ls/grep/find with the 60k output
   bound, 2 MB read cap, `--allow-root` + server-echoed path scoping,
   lexical + canonical (realpath) double pass, O_NOFOLLOW opens, scrubbed
   env, hard process-group timeouts, the v5 process-credential runtime,
   and the reconciled-trust gate (observe = read-only verbs only).
   Slices 2 and 3, plus the v6 pane verbs, are included; the advertised
   dialect is **6**.
4. **Wire-v6 pane verbs + preview proxy (DONE)** — fs/git/watch verbs and
   the chobitsu-injecting preview proxy. These verbs have no JS
   implementation; they are Rust-first by decision.
5. **Autostart (DONE)** — launchd, systemd, and Windows Task Scheduler
   install/uninstall (`--autostart` / `--uninstall`) use the platform binary.
   Autostart requires a durable executable path. The npm launcher refuses
   `--autostart` when `npx` resolved the relay from its disposable `_npx`
   cache; install `cmux-relay` globally or in a persistent project first.

### Intentional divergences from the JS relay (still open)

- The advertised relay protocol is **v6**. PTY and exec remain capability
  gated at v4 and v3; workspace/watch/preview use v6.
- `--code` prints the `chatmux://pair` link without the terminal QR
  graphic (QR rendering comes with a later slice; the link carries the
  same payload).
- PTY frame dispatch is serialized on one task per connection, so a slow
  `pty_open` (daemon spawn, up to 5s) delays a following frame for a
  DIFFERENT pty. Acceptable for typical one-open-at-a-time use; revisit
  if concurrent opens become common.

## Wire contract and the vendored protocol

The wire truth is chatmux `packages/protocol/src/relay.ts`, emitted to
`generated/schema/relay-client.schema.json`. The generated serde types for
the workspace/v6 data plane are vendored in `src/relay_wire.rs`.

After a chatmux protocol change:

1. In chatmux: `cd packages/protocol && bun run generate`.
2. Copy `packages/protocol/generated/rust/relay_wire.rs` (generated,
   do not edit) into this crate as `src/relay_wire.rs`.
3. Keep `src/wire.rs` only for the pairing/presence compatibility frames
   and tolerant parse helpers until those frames are also generated.
4. Record the chatmux commit sha of the vendored file in the copy header.

Regenerate + re-copy is part of any chatmux protocol change that touches
the relay group (cross-repo step; documented in both repos).

## Conformance harness (chatmux repo)

The cross-language gate lives in chatmux `apps/backend`:

- `test/e2e-relay.ts` — `--code` pairing + presence + heartbeats.
- `test/e2e-pair-url.ts` — URL approval flow, deny path, rate limit.
- `test/e2e-terminal-pty.ts`, `scripts/terminal-dev-server.ts` — PTY
  (slice 2 gate).

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
- The `cmux-relay` wrapper's bin shim resolves the platform package from its
  optional dependency and launches the native binary with the same arguments.
- Do not use `npx cmux-relay --autostart`: `npx` may place the binary in a
  disposable `_npx` cache. Use `npm install --global cmux-relay` (or install
  it in a persistent project) and then run `cmux-relay --autostart`. The
  launcher and the native binary both refuse an ephemeral `_npx` path.
The release workflows build the machine binary and platform packages for
darwin-arm64, darwin-x64, linux-arm64, linux-x64, and win32-x64. The package
name remains `cmux-relay`; the sibling circuit-relay binary and artifacts use
separate lanes. Publish only after hosted conformance passes. Keep
`packages/relay` as the rollback path until the image update is released.

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
