# cmux-mobile-relay

Cloudflare Worker + one `HostRelay` Durable Object per host device. Replaces
the iroh transport for cmux mobile: the host (Mac) keeps one outbound
WebSocket to its own object, each phone keeps one WebSocket to the object of
the host it is attached to, and the object relays opaque per-session data
frames between them. It stores nothing durable except a session counter;
terminal replay lives in the host's ring buffers.

Wire contract: `src/protocol.ts` (Effect Schema, single source of truth).
`bun run generate` emits the checked-in Swift copy
(`Packages/Shared/CmuxRelayTransport/.../Generated/RelayProtocolGenerated.swift`);
`bun run generate:check` gates drift in CI.

Auth: the endpoint presents its OWN Stack access token on the WebSocket
upgrade (`x-cmux-stack-access`); the worker verifies it against the Stack API
(client access type, public project configuration only, short per-isolate
verdict cache) and derives the object id from the VERIFIED user id
(`v2:<userId>:<hostDeviceId>`), so isolation is by construction and no web-app
call exists anywhere on the connect path. The host additionally admits each
client session end to end (`mobile.session.admit`, the session's first frame)
before serving it. Long sessions extend in-band with `refresh` (a current
access token, re-verified by the object); the session deadline caps at 1 h
past the last verified token.

## Operations

```bash
bun install
bun run check            # generate:check + typecheck + tests + deploy dry-run
bun run dev              # local wrangler dev
```

No secrets exist: `[vars]` carries only the Stack project's PUBLIC client
configuration (project id + publishable client key; every shipped app embeds
the same values). `wrangler.toml` binds the prod Stack project and
`wrangler.dev.toml` the dev project, so dev and prod accounts can never mix.

Deploys run from `.github/workflows/mobile-relay.yml` (workflow_dispatch,
`target: prod|dev`). Production serves `mr.cmux.dev` (custom domain from
`wrangler.toml`); dev serves the `cmux-mobile-relay-dev` workers.dev URL.
This worker is intentionally independent of `cmux-presence` and
`cmux-remote-relay`: separate name, domain, secrets, and migration lineage.

## Local relay latency

`bun tools/measure-local-do.ts` opens one host socket and one client socket on
the same computer. It reports connection time, both forwarding directions, and
the echo round trip. It excludes iOS input, PTY work, and terminal rendering.

For the local emulator (a local Stack mock stands in for token verification;
the worker code is unchanged, only STACK_API_URL points at the mock):

```bash
bun tools/local-stack-mock.ts &
npx wrangler dev --config wrangler.dev.toml --local --port 8787 \
  --var STACK_API_URL:http://127.0.0.1:8899
RELAY_URL=ws://127.0.0.1:8787/v1/connect \
STACK_ACCESS=any-token \
bun tools/measure-local-do.ts
```

Against the deployed dev worker, set STACK_ACCESS to a real dev-project
access token instead.
