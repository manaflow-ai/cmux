# cmux-mobile-relay

Cloudflare Worker + one `HostRelay` Durable Object per host device. Replaces
the iroh transport for cmux mobile: the host (Mac) keeps one outbound
WebSocket to its own object, each phone keeps one WebSocket to the object of
the host it is attached to, and the object relays opaque per-session data
frames between them. It stores nothing durable except a session counter;
terminal replay lives in the host's ring buffers.

Wire contract: `src/protocol.ts` (Effect Schema, single source of truth).
`bun run generate` emits the checked-in copies for the web app
(`web/services/mobileRelay/generated/`) and Swift
(`Packages/Shared/CmuxRelayTransport/.../Generated/RelayProtocolGenerated.swift`);
`bun run generate:check` gates drift in CI.

Auth: the web app mints 5-minute HMAC tickets at `POST /api/mobile-relay/ticket`
after Stack auth + device-registry ownership checks. The worker verifies the
ticket and derives the object id from the verified claims
(`v1:<userId>:<hostDeviceId>`), so isolation is by construction. Long sessions
extend in-band with `refresh` (re-verified by the object); the session
deadline caps at 12 h past the last accepted ticket.

## Operations

```bash
bun install
bun run check            # generate:check + typecheck + tests + deploy dry-run
bun run dev              # local wrangler dev
```

Secrets (provision once per environment; never in `[vars]`):

```bash
wrangler secret put MOBILE_RELAY_TICKET_SECRET                             # prod
wrangler secret put MOBILE_RELAY_TICKET_SECRET --config wrangler.dev.toml # dev
```

The secret is an opaque string of at least 32 characters, shared only with
the web app (`CMUX_MOBILE_RELAY_TICKET_SECRET` there). Dev and prod must not
share a secret.

Deploys run from `.github/workflows/mobile-relay.yml` (workflow_dispatch,
`target: prod|dev`). Production serves `mr.cmux.dev` (custom domain from
`wrangler.toml`); dev serves the `cmux-mobile-relay-dev` workers.dev URL.
This worker is intentionally independent of `cmux-presence` and
`cmux-remote-relay`: separate name, domain, secrets, and migration lineage.
