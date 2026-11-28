# Agent CLIs (`cmux/agents`)

One place for the agent CLIs on every machine you use: this Mac, your cmux servers and the team VM. For each CLI it shows the installed version, the latest version, how it was installed, and its sign-ins as non-secret labels ("Work · Max · Signed in"). Update, Install and Sign In are one tap each: the app asks cmux, and cmux runs the CLI's own command in a new terminal you can see. The app never runs a command, never reads a credential file and never sees a token or an email.

Status: prototype on today's app runtime (preview harness and bun FakeHost). The data and actions are proposed ops (below), so in a cmux without them the app says which op is missing. Manifest v2: `cmux-app.v2.json` and `catalog/`; the proposed host ops the app calls are in `proposed/host-catalog.json`, not in its catalog.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| Sidebar section | `agents` | The CLIs on this machine, one native row each: status glyph, version line, an "Update" or "Sign In" badge. Tap opens the pane at that CLI; the context menu has Update, Sign In… and Open Agent CLIs. "N more you can install" opens the pane. |
| Pane kind | `agentHub` | The hub (three designs, below). Toolbar: summary ("5 updates · 2 need sign-in") and Check for Updates. |
| Commands | `openAgents`, `checkForUpdates` (palette, section menu), `cycleVariant` (palette, DEV/NIGHTLY) | |

The CLIs it knows by name are in `src/model/providers.ts`: Claude Code, Codex, OpenCode, Pi, Chief, Gemini CLI, Amp, Copilot CLI and Cursor Agent, each with its executable names, install hints per platform, and whether it has a sign-in of its own (Chief uses the cmux account). The owner may report other CLIs; they render with the owner's name. CLIs in the table that a machine does not report are "Not installed" with their install hints.

## Scopes

| Scope | Why |
| --- | --- |
| `machine:read` | list this Mac, cmux servers and the team VM |
| `agent_cli:read` | versions, install method and sign-in state; labels only |
| `agent_cli:execute` (optional) | ask cmux to run an update, install or login command in a visible terminal, from a tap only (origin user) |
| `actions:run` (optional) | fall back to the existing `accounts.reauthenticate` action on this Mac while `agent_cli.sign_in` does not exist |

## Variants (DEV/NIGHTLY setting `variant`, palette "Next Agent CLIs Variant")

| Variant | Design |
| --- | --- |
| `byCli` (recommended) | one block per CLI with the largest pending update as a badge; a line per machine (version, action) with that machine's accounts under it; "Not on team-vm" with the install hint |
| `byMachine` | one section per machine, a row per CLI with version, accounts and the action; missing CLIs folded under "Not installed (n)" |
| `matrix` | CLI by machine grid of versions with a status glyph per cell; the selected cell's details, actions, accounts and hints below |

Recommendation: `byCli`. The questions people ask are per CLI ("is Codex current everywhere", "which Claude Code sign-in does the VM use"), and Update and Sign In belong to one CLI on one machine, which is exactly one line. Strongest objection: with many machines each block grows by two lines per machine, so an offline server or a machine-wide problem is spread over every block; `byMachine` shows that at a glance, and `matrix` is the only one that stays one screen tall.

## Proposed operations

Owner recommendation: the session host on each machine (a small "agent environment" module next to terminals and documents). It is already on every machine (Mac, cmux server, team VM, Linux), it already opens visible terminals with origin user, and V3 makes it the document host for files on that machine, which `cmux/skills` and `cmux/memory` also need. The Swift detector in `CmuxNextCodeRouter/Detection` (presence only, Mac only) is the model for the sign-in part; it moves into the session host or is ported to it. Alternative: a per-machine app server (`server.instances: "machine"`), rejected for now because three first-party apps would need one shared owner and v2 has no shared server. The operation-catalog form is `proposed/host-catalog.json`.

| Op | Params | Result | Owner | Risk | Scope | Events | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `agent_cli.list` | `{machine?, check_latest?}` | `{machine, clis: [{cli, name?, installed, version, latest: {version, checked_at}, install_method, updatable, path_label?, accounts: [{account: acct_…, label, plan?, status}]}]}` | session host of that machine | read | `agent_cli:read` | `agent_cli.watch` | nothing lists CLIs per machine; `agent.list` is running agents, not installed CLIs |
| `agent_cli.update` | `{machine?, cli}` | `{job, terminal}` | session host | execute, origin user, gesture | `agent_cli:execute` | `agent_cli.watch` (job end) | `workspace.run` would make the app choose and spell the command; the owner picks the command for the detected install method |
| `agent_cli.install` | `{machine?, cli, method}` | `{job, terminal}` | session host | execute, origin user, gesture | `agent_cli:execute` | `agent_cli.watch` | same; the method is one of the provider table's hints, never free text |
| `agent_cli.sign_in` | `{machine?, cli, account?}` | `{job, terminal}` | session host | execute, origin user, gesture | `agent_cli:execute` | `agent_cli.watch` | `accounts.reauthenticate` exists only on this Mac and only for providers CodeRouter links |
| `agent_cli.watch` (stream) | `{machine?}` | `{machine, cli, entry?, removed?, job?: {job, ok, exit_code?, error?}}` | session host | read | `agent_cli:read` | | typed stream instead of polling `list` |
| `app.pane.open` | `{kind}` | `{pane}` | shell | mutate-own, gesture | `workspace:write` | | open this app's pane from the section |

Rules for the owner: accounts carry an opaque `acct_…` and a non-secret `label` (user-set, or the organization or plan name, or "Account 1"); never the email the CLI's config holds (the Swift detector's `identity` is an email today, so it must be mapped). Latest versions come from the registry that matches the install method (npm, Homebrew, the CLI's own release feed), cached per machine, refreshed only on `check_latest` or when a watcher is visible. Updates run in a visible terminal with origin user and the gesture token; a CLI installed by an unknown method reports `updatable: false` and the app says "Update it the way you installed it".

## Platform gaps (most important first)

1. No per-machine owner for agent environment data: `agent_cli.*` (and `skill.*`, `mcp_server.*`, `memory.*` for the sibling apps) need one owner on every machine; v2 has no shared server for several apps and no host capability family for it.
2. `machine.list` returns only `origin: "local"`; cmux servers and the team VM are not listed with an `os`, so the app cannot tell Linux from macOS for install hints.
3. No account label owner: sign-ins have no opaque handle (`acct_…`) and no user-editable non-secret label; the native detector exposes an email.
4. `accounts.reauthenticate` takes no machine and covers only CodeRouter providers.
5. The scope grammar does not know `agent_cli:*` (validator warning `scope.unknown`).
6. Scene: no table or grid (the matrix uses fixed-width texts), no ScrollView (long lists clip in the sidebar), no button prominence (Update looks like every other button), no copy-to-clipboard for an install hint.
7. Catalog fragments have no field that binds an op to a JS export; the sketch uses `export`.
8. Palette commands carry no gesture token, so "Update" cannot be a palette command with a CLI argument.
9. `x-cmux-devOnly`, `app.settings.set`, app l10n (`strings/*.json` are bundled into `dist/main.js`) are not honored by every host yet.

## Layout and checks

`src/model/` (provider table, version parsing and semver precedence, entries and watch merge, host-run job state machine), `src/store.ts` (machines, entries, jobs; `agent_cli.watch`, no polling), `src/actions.ts` (gesture-carrying asks), `src/views/` (section, variants, shared parts), `src/l10n.ts` + `strings/`. No third-party code.

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/agents
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/agents
bun test first-party-apps/agents/test
```

`preview/*.json` are preview-harness fixtures (invented machines, versions and labels); `preview/make-fixtures.ts` regenerates them.
