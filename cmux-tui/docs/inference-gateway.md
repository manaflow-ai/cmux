# cmux inference gateway

`cmux inference gateway` is the only place your subscription login lives. Your Cloud machines hold a
placeholder key. Their edge sends each model call to the Cloud service, and the service sends it down
the one WebSocket your gateway holds. The gateway answers from your own subscription proxy, which is
the only thing that refreshes the login. The gateway dials out, so it needs no inbound port.

There are two gateway scopes:

- **Personal** (`--personal`): serves every machine you created, in every team. A chat you share
  with teammates spends your login, because you own the session.
- **Team** (the default): serves the team's machines when the team is in gateway mode. A team
  admin can also store a team key; that key goes first for everyone (see Routes below).

cmux does not pick or start a proxy for you. Run your own CLIProxyAPI (or any compatible router)
next to the gateway and pass its URL with `--upstream`.

## Routes

A Cloud machine's call takes the first route that applies. The route it took comes back in the
answer's `x-cmux-inference-route` header.

| Route | When |
| --- | --- |
| `team_key` | The team has a shared key for the agent. A shared Codex sign-in is skipped, because it needs a refresh. |
| `owner_key` | The machine's owner stored their own provider API key |
| `owner_gateway` | The owner turned on their personal gateway |
| `team_gateway` | Otherwise, the team's gateway |

If no gateway is online, the call fails after 15 s with `inference.gateway_offline`.

## Commands (all take `--json`)

```bash
cmux inference gateway --personal --upstream http://127.0.0.1:8317    # serve (stays running)
cmux inference gateway mode gateway --personal --json                  # turn your own gateway on
cmux inference gateway status --personal --json
cmux inference gateway mode gateway --gateway-machine vm_... --json     # team gateway on a team machine
cmux inference route --machine vm_... --agent claude --json             # which route that machine uses now
```

## On a Freestyle VM (a tiny machine per person or per team)

1. Create the machine as usual, then sign your proxy in on it (CLIProxyAPI's own login flow).
2. For a team gateway, run `cmux inference setup --machine <chat vm> --gateway-machine <gateway vm>
   --upstream http://127.0.0.1:8317`. Setup names the machine and starts the gateway with the
   machine's own token (`/run/cmux-inference-gateway/token`). It then checks one real call and
   undoes everything if that call fails.
3. For a personal gateway machine, name it with
   `cmux inference gateway mode gateway --personal --gateway-machine <vm>`. Then start
   `cmux inference gateway --personal --upstream http://127.0.0.1:8317 --token-file
   /run/cmux-inference-gateway/token` on it.

## On your own Mac mini

1. Sign in to the cmux app, then start your proxy (for example `cli-proxy-api`, listening on 8317).
2. `cmux inference gateway mode gateway --personal`
3. Run `cmux inference gateway --personal --upstream http://127.0.0.1:8317` under `launchd` (a
   LaunchAgent with `KeepAlive`). The gateway reads its token with `cmux auth token` on every
   connect.
4. If the Mac sleeps, its socket goes silent, and calls fail with `inference.gateway_offline` until
   it wakes. Turn sleep off on a gateway Mac.

## On an SR2 box

1. Run your proxy there. Plain http is accepted only to loopback or a private network such as a
   tailnet. A key file (`--upstream-key-file`) is sent only over https or to loopback.
2. Give the gateway a cmux token. On a headless box, use `--token-command` with a command that
   prints a fresh access token, or use `--token-file`. The token is read again on every connect.
3. Run `cmux inference gateway --personal --upstream URL ...` under `systemd` with `Restart=always`.

## Two gateways, restarts, and sign-in checks

- Only one gateway serves a scope at a time. When a second one connects, it takes all new calls.
  The first finishes the streams it was serving, then closes with `replaced` and exits. A gateway
  that goes silent is dropped after 45 s, and its open calls end with `inference.gateway_gone`.
- Every 10 minutes the service closes the socket after its calls finish, and the gateway reconnects
  at once with a fresh token. This is how a revoked sign-in loses access.
- A network drop reconnects with backoff (1 s up to 30 s). An in-flight call fails, and the agent
  retries it, so a call is never answered twice.
