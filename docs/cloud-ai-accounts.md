# Connect your AI accounts once; every cloud machine uses them

cmux Cloud machines come up with their coding agents already routed through
your team's AI subscriptions. There is nothing to log into on a machine —
`claude`, `codex`, `opencode`, and `pi` work the moment a terminal opens,
provided your team has connected an account for that agent. You connect each
account **once**, from your Mac.

## The one step (Claude)

You are already signed into Claude Code on your Mac. Upload that login to your
team:

```bash
cmux ai-accounts upload claude     # uses ~/.claude/.credentials.json
cmux ai-accounts list
```

That is the whole setup for Claude. The same connect is available from the
coderouter page of the web dashboard. For Codex, connect through the
coderouter CLI instead (`cr add codex`), which stores the account directly in
the vault machines use; `cmux ai-accounts upload codex` connects Codex for
the app only, not for machines (yet). From then on:

- every **new** cloud machine (`cmux vm new`, the sidebar, a Base machine) is
  born with a machine-scoped route token and its agents pre-configured;
- `claude` on any machine talks to cmux, which picks one of the team's Claude
  accounts, keeps the session sticky, refreshes and fails over server-side,
  and streams the answer back;
- removing an account (`cmux ai-accounts remove <id>`) removes it for every
  machine at once.

Nothing on a machine ever holds a provider credential. A machine holds one
revocable token for its team; the accounts live encrypted server-side.

## What "connected" means under the hood

Connecting an account stores it in the team's account store and mirrors the
providers the machine plane serves (Claude today; Codex arrives through
`cr add codex`) into the coderouter vault that machines route through. The
mirror is best-effort and idempotent: re-connecting the same login is a no-op,
and an outage of the vault never fails the connect — the account simply shows
up for machines on the next connect.

## Checking it worked

```bash
cmux ai-accounts list          # your team's connected accounts
cmux vm new                    # a fresh machine…
# …in a terminal on it:
claude -p "hello"              # answers with no login prompt
```

If `claude` on a machine reports "no model-plane credential", the machine was
created before your team connected an account or before the current image was
published; create a new machine. If it reports "no healthy Claude subscription
is currently available", connect an account (above) or check
`cmux ai-accounts list` for a broken one.

## Where things live

- Connect / list / remove: `cmux ai-accounts` (`Sources/Cloud/AIAccountsClient.swift`),
  `POST|GET|DELETE /api/subrouter/accounts` (`web/app/api/subrouter/accounts`).
- Mirror into the machine plane: `web/services/coderouter/accountMirror.ts`.
- Machine token mint at create (including Base machines): `web/services/coderouter/vmModelPlane.ts`.
- On-machine wiring: `web/services/vms/images/*/agent-config.sh`.
- Design and follow-ups: `docs/cloud-coderouter-model-plane.md`.
