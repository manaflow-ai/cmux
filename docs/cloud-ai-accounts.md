# Connect your AI accounts once; every cloud machine uses them

cmux Cloud machines come up with their coding agents already routed through
your team's AI subscriptions. There is nothing to log into on a machine —
`claude`, `codex`, `opencode`, and `pi` work the moment a terminal opens,
provided your team has connected an account for that agent. The machine also
has the pinned `coderouter`/`cr` CLI and the in-VM `cmux` shim available for
inspection and automation; those commands do not require copying a personal
credential into the VM. You connect each account **once**, from your Mac.

## The one step

Connect the account you already use, from your Mac. Each line is the whole
setup for that kind of account:

| You have | Run on your Mac | Agents it powers on every machine |
|---|---|---|
| Claude Code signed in (Claude Max/Pro) | `cmux ai-accounts upload claude` | `claude`, `opencode` |
| Codex signed in (ChatGPT Plus/Pro) | `cmux ai-accounts upload codex` | `codex`, `pi`, `opencode` |
| An Anthropic API key | `cmux ai-accounts upload anthropic-key --key sk-ant-…` | `claude`, `opencode` |
| An OpenAI API key | `cmux ai-accounts upload openai-key --key sk-…` | `codex`, `pi`, `opencode` |
| An OpenCode Go subscription | `cr add opencode` (coderouter CLI) | `opencode` |

`cmux ai-accounts upload claude` and `… codex` read the login already on your
Mac (`~/.claude/.credentials.json`, `~/.codex/auth.json`); nothing is typed
in. The same connect is available from the AI accounts page of the web
dashboard. `cmux ai-accounts list` shows what your team has. From then on:

- every **new** cloud machine (`cmux vm new`, the sidebar, a Base machine) is
  born with a machine-scoped route token and its agents pre-configured, and
  **existing** machines pick a newly connected account up on their next
  request — nothing to recreate;
- an agent on any machine talks to cmux, which picks one of the team's
  accounts of a kind that agent can use, keeps the session sticky, refreshes
  and fails over server-side, and streams the answer back;
- removing an account (`cmux ai-accounts remove <id>`) removes it for every
  machine at once.

Nothing on a machine ever holds a provider credential. A machine holds one
revocable token for its team; the accounts live encrypted server-side.

## What "connected" means under the hood

Connecting an account stores it in the team's account store and mirrors it
into the coderouter vault that machines route through — every kind: Claude
and ChatGPT logins as OAuth accounts the vault refreshes itself, API keys as
key accounts. The mirror is best-effort and idempotent: re-connecting or
repairing the same login rotates the vault copy, and an outage of the vault
never fails the connect — the account simply shows up for machines on the
next connect.

`opencode` needs no subscription of its own: its config publishes cmux's
Claude and Codex planes as opencode's `anthropic` and `openai` providers
whenever the team has an account those planes can use (an OpenCode Go
account adds its own catalog alongside).

## Checking it worked

```bash
cmux ai-accounts list          # your team's connected accounts
cmux vm new                    # a fresh machine…
# …in a terminal on it:
claude -p "hello"              # answers with no login prompt
  cr capabilities --json       # installed CLI contract (no login required)
  curl -sS -H "authorization: Bearer $OPENAI_API_KEY" "$CMUX_CODEROUTER_URL/v1/status"
```

The last line is what a machine may ask about its own plane: per agent,
whether it will work right now, which account kinds are behind it, and the
one-line Mac command to connect when it will not. It carries no identifiers.

If an agent on a machine reports "no model-plane credential", the machine was
created before the current image was published; create a new machine. If it
reports that no account is connected for your team, run the connect line it
names (above) on your Mac and retry — the machine needs no change.

## Where things live

- Connect / list / remove: `cmux ai-accounts` (`Sources/Cloud/AIAccountsClient.swift`),
  `POST|GET|DELETE /api/subrouter/accounts` (`web/app/api/subrouter/accounts`).
- Mirror into the machine plane: `web/services/coderouter/accountMirror.ts`.
- What a machine can ask: `GET /v1/status` (`web/services/coderouter/planeStatus.ts`).
- opencode's provider list: `web/services/coderouter/opencodeProxy.ts` (`planeProviders`).
- Machine token mint at create (including Base machines): `web/services/coderouter/vmModelPlane.ts`.
- On-machine wiring: `web/services/vms/images/*/agent-config.sh`.
- Design and follow-ups: `docs/cloud-coderouter-model-plane.md`.
