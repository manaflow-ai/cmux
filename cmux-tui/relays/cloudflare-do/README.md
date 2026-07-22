# cmux Cloudflare Durable Object relay

This standalone Rust workspace implements the shared cmux relay v2 contract on Cloudflare Durable Objects. `RelaySlot` owns one daemon control connection and reusable client allocation connections. Each physical lane gets a separate `RelayCircuit`, which owns exactly one daemon socket and one client socket. The relay forwards opaque binary records and cannot inspect workspace traffic.

Both classes use `State::accept_websocket_with_tags`. Socket attachments contain the role, slot, circuit, lane, generation, join-ticket expiry, idle deadline, and handshake phase needed after hibernation. Durable storage holds the bounded per-slot circuit ledger and a circuit's active-release record.

## Routes

Slots should contain at least 128 bits of entropy. Other route values are URL-safe opaque identifiers.

| Route | Purpose |
| --- | --- |
| `GET /healthz` | Health check. |
| `WS /v1/slots/{slot}/control` | Daemon registration and control channel. |
| `WS /v1/slots/{slot}/connect` | Reusable client allocation channel. |
| `WS /v1/circuits/{circuit}` | One daemon or client physical lane. |

Every WebSocket upgrade requires `Authorization: Bearer <ticket>`. Slot control upgrades use the Register ticket, slot connection upgrades use the Connect ticket, and circuit upgrades use that role's Join ticket. The stateless edge Worker verifies the HMAC, expiry, permission, role, and requested slot or circuit before resolving a Durable Object ID. Invalid or cross-scope tickets therefore cannot materialize objects for random names. The Durable Object verifies the same ticket again in the first relay control message.

The daemon sends `RelayControl::Register` first. A client sends one `RelayControl::Connect` per lane on its allocation socket. The slot mints separate, route-bound join tickets and sends `Allocated { circuit, lane, generation, join_ticket }` to the client and `Incoming { circuit, lane, generation, join_ticket }` to the daemon. Each endpoint opens the circuit URL and sends `Join` with the same circuit, lane, generation, its assigned role, and its role-specific ticket. The circuit sends `Ready` with the bound route after both roles match.

Ready circuits accept binary messages up to `MAX_WIRE_FRAME_BYTES`. Text control messages are limited to 4 KiB. A slot accepts at most eight sockets, including at most four pending protocol handshakes, six client control sockets, and one pending daemon replacement. A circuit accepts four sockets, at most two of which may still be pending. Each slot's durable ledger permits 16 pending allocations, 32 total pending plus active circuits, and 64 allocations per minute. A circuit must promote its ledger entry to active before either peer receives `Ready`. Active entries use 15-minute reconciliation leases renewed every five minutes. Close, error, idle, and failed-renewal paths close the circuit and release the entry, with a circuit-local durable release record and alarm retry if the slot callback fails.

Protocol handshakes expire after 15 seconds. Daemon controls require activity within 45 seconds, client allocation controls expire after five idle minutes, joined peers retain the Join ticket deadline until paired, and Ready circuits expire after ten idle minutes. Durable Object alarms scan hibernation attachments, close expired sockets, prune pending allocations, and retry failed active releases. Binary traffic refreshes the circuit activity deadline without a Durable Storage write on the keystroke path.

Cloudflare must select a Durable Object before upgrading a WebSocket. A client adapter therefore derives the three URL forms above from its relay base URL, adds the admission ticket as an Authorization header, and then sends the same ticket in the shared control message. This URL resolution and edge admission step are provider routing only. All WebSocket messages use the same `cmux-remote-protocol` types as the native relay.

The browser `WebSocket` constructor cannot set an Authorization header. A future browser-direct client needs a same-origin secure cookie or a short-lived admission capability carried in an agreed WebSocket subprotocol. Native Rust and mobile HTTP/WebSocket stacks can set the header directly.

## Relay tickets

Configure the shared HMAC key with at least 32 bytes:

```sh
npx wrangler secret put CMUX_RELAY_TICKET_KEY
```

`CMUX_RELAY_TICKET_ISSUER` identifies this relay deployment and defaults to `cmux-relay` in `wrangler.toml`. A control plane that mints provider tickets must use the same issuer and key.

Tickets use `v2.<base64url-json>.<base64url-hmac>`. The JSON is the shared `RelayTicketClaims` type. The HMAC-SHA256 input is `RelayTicketClaims::signing_payload()`, which canonically binds version, issuer, permission, role, slot, optional circuit, optional lane, optional generation, and expiry.

Provider tickets have one permission:

- `Register` requires daemon role and slot scope.
- `Connect` requires client role and slot scope. It may also restrict lane and generation.

The slot verifies the provider ticket for every operation. It then mints distinct daemon and client `Join` tickets with a maximum 30-second lifetime. Each join ticket binds role, slot, circuit, lane, and generation. Join-ticket expiry limits circuit establishment and does not terminate an established data socket.

Relay tickets authorize provider use and limit abuse. cmux device enrollment, revocation, workspace authority, and traffic encryption remain end to end above the relay.

## Deploy and connect

The Worker and `cmux-relay` ticket command use the same HMAC bytes and default issuer, `cmux-relay`. From the cmux-tui repository root, create one key and an opaque 128-bit slot:

```sh
RELAY_KEY="$(openssl rand -base64 48)"
SLOT="$(openssl rand -hex 16)"
cargo build -p cmux-relay -p cmux-tui
```

Authenticate Wrangler with `npx wrangler login` or `CLOUDFLARE_API_TOKEN`. Then install dependencies, store the key as a Worker secret, and deploy:

```sh
cd relays/cloudflare-do
npm ci
cargo install worker-build --version 0.8.5 --locked
printf '%s' "$RELAY_KEY" | npx wrangler secret put CMUX_RELAY_TICKET_KEY
npm run build
npx wrangler deploy
cd ../..
```

Wrangler prints an HTTPS hostname such as `cmux-remote-relay.<account>.workers.dev`. Convert only its scheme for the cmux provider route:

```sh
RELAY_ROUTE='relay+do://cmux-remote-relay.<account>.workers.dev'
REGISTER_TICKET="$(CMUX_RELAY_HMAC_SECRET="$RELAY_KEY" \
  target/debug/cmux-relay ticket --permission register --slot "$SLOT")"
CONNECT_TICKET="$(CMUX_RELAY_HMAC_SECRET="$RELAY_KEY" \
  target/debug/cmux-relay ticket --permission connect --slot "$SLOT")"
RELAY_STATE="${XDG_RUNTIME_DIR:-$HOME/.cache}/cmux-relay-dev"
mkdir -p "$RELAY_STATE"
chmod 700 "$RELAY_STATE"
printf '%s' "$RELAY_ROUTE" > "$RELAY_STATE/route"
printf '%s' "$SLOT" > "$RELAY_STATE/slot"
printf '%s' "$REGISTER_TICKET" > "$RELAY_STATE/register.ticket"
printf '%s' "$CONNECT_TICKET" > "$RELAY_STATE/connect.ticket"
chmod 600 "$RELAY_STATE"/*
```

Keep `RELAY_KEY` only in the provisioning shell. Start the foreground daemon in a dedicated terminal using the owner-only files:

```sh
RELAY_STATE="${XDG_RUNTIME_DIR:-$HOME/.cache}/cmux-relay-dev"
target/debug/cmux-tui daemon --session dev \
  --relay "$(cat "$RELAY_STATE/route")" \
  --relay-slot "$(cat "$RELAY_STATE/slot")" \
  --relay-ticket-file "$RELAY_STATE/register.ticket"
```

For first enrollment, create an invitation that carries a short-lived Connect ticket:

```sh
RELAY_STATE="${XDG_RUNTIME_DIR:-$HOME/.cache}/cmux-relay-dev"
target/debug/cmux-tui enroll create --session dev \
  --relay-route "$(cat "$RELAY_STATE/route")" \
  --relay-slot "$(cat "$RELAY_STATE/slot")" \
  --relay-ticket-file "$RELAY_STATE/connect.ticket"
```

On the client, connect with the returned URI. In another owner terminal, inspect and approve the pending device:

```sh
cmux-tui connect 'cmux://enroll/...' --device-name macbook
cmux-tui enroll pending --session dev
cmux-tui enroll approve <invitation-id> --session dev
```

In the provisioning shell, mint a fresh scoped Connect ticket and deliver only that ticket to the enrolled client through a secure channel:

```sh
RELAY_STATE="${XDG_RUNTIME_DIR:-$HOME/.cache}/cmux-relay-dev"
SLOT="$(cat "$RELAY_STATE/slot")"
CONNECT_TICKET="$(CMUX_RELAY_HMAC_SECRET="$RELAY_KEY" \
  target/debug/cmux-relay ticket --permission connect --slot "$SLOT")"
```

On the client, use the public route, slot, and delivered ticket:

```sh
cmux-tui connect 'relay+do://cmux-remote-relay.<account>.workers.dev' \
  --relay-slot '<slot>' \
  --relay-ticket '<fresh-connect-ticket>'
```

The ticket command defaults to a five-minute lifetime. Production daemons and clients should use `--relay-ticket-file` or `--relay-ticket-command` so a control plane can refresh credentials before provider reconnection. Protect `RELAY_KEY`, unset it after ticket provisioning, and never copy it to a client. Clients receive scoped Connect tickets only.

## Build and development

Install the pinned Rust build helper and JavaScript dependency, then run Wrangler:

```sh
cargo install worker-build --version 0.8.5 --locked
npm install
npm run dev
```

Run host-side protocol, ticket, hibernation attachment, and route-binding tests with:

```sh
cargo test
cargo clippy --all-targets -- -D warnings
```

Build the Worker with:

```sh
npm run build
```

The build disables worker-build's experimental in-process panic recovery. A Rust panic therefore
fails the Worker instance, while circuit quotas and release retries remain recoverable from Durable
Storage. The pinned npm override keeps Wrangler's local `sharp` dependency on its patched release.

`wrangler.toml` creates SQLite-backed `RelaySlot` and `RelayCircuit` classes. WebSocket attachments remain the live transport state. Small storage records enforce circuit quotas and make release retries survive hibernation or object restarts.

Cloudflare provides one alarm per Durable Object. The worker schedules the earliest attachment or allocation deadline and reschedules after each scan. Cloudflare documents that alarms can run up to roughly one minute late during maintenance or failover, so these deadlines are hard admission bounds with best-effort close timing rather than real-time timers.
