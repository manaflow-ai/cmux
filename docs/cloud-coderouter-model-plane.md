# cmux Cloud × coderouter: the model-access plane

Design doc for [#11276](https://github.com/manaflow-ai/cmux/issues/11276):
integrate coderouter into cmux cloud so a VM provisioned through cmux comes up
with agent model access already routed — zero per-VM logins, implementation
hidden from the user. This doc answers the issue's open design questions,
records the architecture the repo already shipped, and lays out the
incremental plan. The first slice (Claude Code routing, the one agent that was
still unwired) lands with this doc.

## The architecture in one pass

The hosted coderouter control and data planes are this web app
(`web/services/coderouter/**`, `web/app/v1/**`, `web/app/api/coderouter/**`).
Provider subscriptions (ChatGPT Pro, Claude Max, OpenCode) live server-side in
the envelope-encrypted vault (`coderouter_credentials`, AES-256-GCM data keys
wrapped by KMS), keyed by Stack team. Machines never hold provider
credentials; they hold one **route token**.

```
cmux vm new (CLI → Mac app → POST /api/vm, Stack auth)
  └─ mintVmModelPlaneEnvBestEffort            web/services/coderouter/vmModelPlane.ts
       └─ issueRouteToken(team, user, "vm")   crt_… 30-day token, sha256-stored
  └─ provider create(envs):
       OPENAI_BASE_URL     = <origin>/v1
       OPENAI_API_KEY      = crt_…
       CMUX_CODEROUTER_URL = <origin>

VM boot / every shell: /etc/cmux/agent-config.sh
  ├─ persists the env 0600 at ~/.config/cmux/model-plane.env (survives resurrect)
  ├─ codex    → ~/.codex/config.toml       (custom provider, env_key auth)
  ├─ claude   → ANTHROPIC_BASE_URL=$CMUX_CODEROUTER_URL,
  │             ANTHROPIC_AUTH_TOKEN=$OPENAI_API_KEY (derived, never persisted),
  │             ~/.claude.json onboarding skip (write-once, token-free)
  ├─ pi       → ~/.pi/agent/models.json    (token rides a header env-reference)
  └─ opencode → fetched config, token swapped for {env:OPENAI_API_KEY}

Agent traffic (route token as bearer):
  codex/pi  → POST <origin>/v1/responses      → chatgpt.com backend
  claude    → POST <origin>/v1/messages       → api.anthropic.com  (this PR)
  opencode  → <origin>/api/coderouter/opencode/proxy/…
Each plane: authenticate route token → pick a team account (sticky per
session) → decrypt under a refresh lease → forward → rotate on 401, cool down
and fail over on 429.
```

## Answers to the open design questions

### 1. How does the coderouter session/token get onto a cloud VM securely?

**A per-machine, team-scoped route token minted at create time, passed as
provider create-env, persisted 0600 on the machine's durable home volume.**
Not the user's Stack session, not provider OAuth material, not the user's own
CLI route token.

- The token (`crt_…`, 32 random bytes, label `"vm"`) is stored server-side
  only as a sha256 hash with a 30-day expiry
  (`web/services/coderouter/repository.ts`). It grants exactly one thing:
  model traffic for the team it was minted for. It cannot list, add, or remove
  accounts (those endpoints require a full Stack session).
- Provider credentials never leave the vault. The "bounded refresh leases"
  stay entirely server-side: refresh claims a per-account lease, calls the
  provider outside any transaction, and commits the new revision with a
  compare-and-swap. The VM sees none of this — a rotated upstream credential
  needs no machine-side change because the machine only ever holds the route
  token.
- Fail-closed revocation: billing lapse, account removal, or explicit revoke
  deletes the hash server-side and every in-flight machine gets 401 on its
  next request (the e2e test in `web/tests/coderouter-vm-claude-e2e.test.ts`
  proves the cut-off).
- Minting is best-effort by design: a coderouter outage or entitlement block
  ships an unwired machine, never a failed create
  (`CMUX_VM_CODEROUTER_ENV_ENABLED=0` is the kill switch).

Rejected alternative: handing the VM a Stack refresh token (or seeding a `cr`
`config.json`) would put an account-plane credential on rentable compute and
make revocation scope the whole user, not the machine.

### 2. Does cmux-tui speak to coderouter.dev, or does the Mac app broker?

**Neither.** The split is:

- **Agents on the VM speak to the serving origin directly** with the route
  token — plain HTTPS to `/v1/*`. No local daemon, no `cr` binary required on
  the machine, no Mac in the hot path (a phone-initiated VM works the same).
- **The web control plane is the broker**: it mints at `POST /api/vm`,
  and owns rotation/revocation. The Mac app's only involvement is being the
  authenticated caller of `POST /api/vm`.
- **cmux-tui stays credential-ignorant.** It multiplexes terminals; shells it
  spawns inherit the model-plane env through the profile chain. Its
  `spawn-process` RPC (required `env` map, env values deliberately excluded
  from catalog output) is the reserved hook for *per-session* credential
  injection later, without the image or daemon learning what coderouter is.
- The `cr` CLI's advertised `cmux-broker-v1` auth mode (see
  `cr capabilities --json`) remains the hook for the *local Mac* case — cmux
  brokering a route session into a locally-run `cr` — and is out of scope for
  the VM plane, which needs no `cr` at all.

### 3. Where does org scoping live?

**Per-machine token, scoped to the creating user's billing team; the team is
the coderouter org.** `POST /api/vm` resolves the caller's billing team
(`X-Cmux-Team-Id` + Stack membership + entitlements) and mints the machine's
token for exactly that team. The machine routes over that team's account pool
for its whole life; there is no machine-side org switch. Changing org = new
machine (or a follow-up re-mint verb), which keeps the fail-closed property:
`cr org switch` semantics (only persist scope after the server issues an
org-scoped token) hold trivially because scope is fixed at mint. Workspaces
and sessions inside the machine inherit the machine's team; a per-workspace
override is deliberately not modeled until something needs it.

### 4. How does this compose with PR #11061 (cloud tree agent parity)?

By file-level and layer-level disjointness. #11061 owns the tree UI and verb
surface (`Sources/Cloud/*`, `CLI/CMUXCLI+VMTui.swift`,
`Sources/Surfaces/CmuxTuiSurfaceProviders.swift`, `skills/cmux-cloud-vm/*`,
`docs/cli-contract.md`, plus the `capabilities` field on `GET /api/vm`). This
issue owns the plane behind it: `web/services/coderouter/**`, `web/app/v1/**`,
the baked images, and the DB migration. This PR touches **no Swift and none of
the PR #11061 files** — the only shared file is `web/app/api/vm/route.ts`, which
this PR does not modify (the mint call predates both).

Sequencing for the visible bits: folding `cr usage`-style quota into the
machine rows extends `GET /api/vm` (a `modelPlane` block next to #11061's
`capabilities`) and `MachineSnapshot` *after* #11061 lands — server data is
already available via `accountsWithUsage`, now Claude-inclusive. Two stale
doc/skill passages saying "set up CodeRouter on the machine yourself"
(`skills/cmux-cloud-vm/SKILL.md`, `docs/cloud-cmux-tui-daemon.md`) are inside
the PR #11061 diff; correcting them is deferred to that branch or a trailing
PR to avoid a needless conflict.

## What ships in this slice

Cloud VMs already came up with codex, pi, and opencode routed (PRs #10961
and #11099). Claude Code was installed on every image but unwired — no Anthropic
data plane existed. This PR completes the set:

- **`claude` vault provider** (`web/services/coderouter/types.ts`,
  `accounts.ts`, `encryption.ts`): Claude Max OAuth credentials
  (access/refresh token, account id, email, optional subscription type),
  envelope-encrypted like the rest. Added via the existing
  `POST /api/coderouter/accounts` (Stack-session auth).
- **DB migration** `20260831120000_coderouter_claude_provider`: widens the
  three provider CHECK constraints to admit `'claude'`.
- **Claude OAuth refresh** (`refresh.ts`): `platform.claude.com/v1/oauth/token`
  with the first-party client id and `anthropic-beta: oauth-2025-04-20`,
  under the same lease/CAS machinery.
- **Anthropic data plane** (`claudeProxy.ts`, `web/app/v1/messages/route.ts`,
  `web/app/v1/messages/count_tokens/route.ts`): route-token auth, sticky
  sessions keyed on Claude Code's `metadata.user_id`, 401 → forced refresh and
  resend, 429/529 → cooldown and fail-over, `x-api-key` stripped, OAuth beta
  appended, bounded response-header passthrough, usage observation feeding the
  same analytics as the codex plane.
- **Image wiring** (`agent-config.sh` ×2, Dockerfiles, freestyle bake, remote
  verify): every shell derives `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`
  from the persisted model-plane env (set-if-unset, so user overrides win, and
  machines minted before this change gain Claude routing on their next shell
  with no rebake), and seeds the token-free `~/.claude.json` onboarding skip
  write-once. Image epochs bumped.
- **Usage**: `accountsWithUsage` now fans out to Anthropic's OAuth usage
  endpoint for claude accounts, so `cr`/dashboard/machine-row consumers get
  one merged view.

No new UI. No Swift changes. Local (non-cloud) agent launch paths untouched.

## Connect once, every machine works

The user-facing contract is in `docs/cloud-ai-accounts.md`: connect an AI
account once from the Mac (`cmux ai-accounts upload claude`, which reads the
Claude Code login already on the machine, or the dashboard) and every cloud
machine routes over it. That path stores accounts in the hosted Subrouter
store; `web/services/coderouter/accountMirror.ts` mirrors the providers the
machine plane serves (Claude) into the coderouter vault on connect and removes
them on disconnect, best-effort and idempotent, so normal connects keep the two
stores in step (a vault outage is reported and heals on the next connect).
Codex reaches the vault through `cr add codex` today;
mirroring it too is a follow-up (its dedupe key is the ChatGPT account id).

## Incremental plan (follow-ups, in order)

1. **Mint on every machine-creating path.** Done for Base machines (the base
   open/reset route mints the same best-effort env as `cmux vm new`).
   Restores and forks go through provider snapshot/fork APIs that take no
   create-time env and inherit the persisted `model-plane.env` on the home
   volume; giving them a fresh token needs the rotation mechanism in item 2.
   Tracked in #11320.
2. **Token rotation for long-lived machines.** Tokens live 30 days and are
   minted once. Add a re-mint on resume/attach (control plane rewrites the
   persisted `model-plane.env` via the provider exec/fs channel, which the
   Freestyle driver already does at create) so a machine older than a token
   heals itself.
3. **Quota in the cloud tree.** After #11061: a `modelPlane` summary on
   `GET /api/vm` (per-team account health/usage from `accountsWithUsage`)
   rendered in the machine rows.
4. **Claude account onboarding UX.** `cr add claude` in the coderouter repo
   (provider OAuth on the user's machine, upload via the existing accounts
   endpoint) and/or the dashboard add-account flow; the server side accepts
   claude credentials as of this PR. An `anthropic-apikey` provider variant
   can follow the same shape.
5. **Per-session credentials.** Wire the cmux-tui `spawn-process` `env` map
   through the Swift `createTerminal` path (files owned by #11061 today) for
   session-scoped tokens instead of machine-scoped, if/when isolation between
   sessions on one machine matters.
6. **`vm exec` env parity.** Non-login exec paths bypass the profile chain on
   some providers; wrap or source explicitly so `vm exec <id> -- claude -p …`
   sees the model plane.

## Security invariants

- Provider credentials exist in plaintext only inside the request that uses
  them; machines and clients never receive them.
- The only secret on a machine is its route token: team-scoped,
  traffic-only, hash-stored, expiring, individually revocable, and dead the
  moment billing or membership says so.
- Generated files on the machine carry no secrets except the 0600
  `model-plane.env`; every generated config references the token through the
  environment so rotation is a one-file change.
- All planes fail closed on auth and fail open on availability only in the
  direction of "unwired machine", never "wrong team's accounts".

## Testing

- `web/tests/coderouter-claude-proxy.test.ts` — plane behavior (auth, sticky
  keys, refresh-retry, cooldown fail-over, header hygiene).
- `web/tests/coderouter-refresh.test.ts` — Claude OAuth refresh contract.
- `web/tests/coderouter-vault.test.ts` — claude credential parsing.
- `web/tests/vm-devbox-image.test.ts` / `vm-blaxel-image.test.ts` — the real
  `agent-config.sh` executed against throwaway HOMEs: derivation on fresh
  boot, resurrect, and user-override; onboarding seed token-free; Dockerfile
  self-checks pinned.
- `web/tests/coderouter-routing-db-behavior.test.ts` — claude accounts route,
  stick, and stay provider-scoped against real Postgres (proves the
  migration).
- `web/tests/coderouter-vm-claude-e2e.test.ts` — the whole loop against real
  Postgres: mint the create-env exactly as `POST /api/vm` does → run the baked
  `agent-config.sh` → authenticate the derived env on the messages plane →
  assert the upstream bearer/beta → revoke the team and assert the machine is
  cut off. Only KMS and api.anthropic.com are stubbed.

DB-gated lanes run with:

```bash
cd web && bun db:up && bun db:migrate
DATABASE_URL=$(bun db:url | tail -1) CMUX_DB_TEST=1 \
  bun test tests/coderouter-routing-db-behavior.test.ts tests/coderouter-vm-claude-e2e.test.ts
```

Not faked: a live end-to-end call into api.anthropic.com with a real Claude
Max account requires production credentials and is a dogfood step, not CI.
