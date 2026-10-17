# Agent CLIs (`cmux/agents`)

One place for the agent CLIs on every machine you use: this Mac, your cmux servers and the team VM. For each CLI it shows the installed version, the latest version, how it was installed, and its sign-ins as non-secret labels ("Work · Max · Signed in"). Update, Install and Sign In are one tap each: the app asks cmux, and cmux runs the CLI's own command in a new terminal you can see. The app never runs a command, never reads a credential file and never sees a token or an email.

Status: prototype on today's app runtime (preview harness and bun FakeHost). The data and actions are proposed ops (below), so in a cmux without them the app says which op is missing. Manifest v2: `cmux-app.v2.json` and `catalog/`; the proposed host ops the app calls are in `proposed/host-catalog.json`, not in its catalog.

## Contributions

| Kind | Id | What |
| --- | --- | --- |
| Sidebar section | `agents` | The CLIs on this machine, one native row each: status glyph, version line, an "Update" or "Sign In" badge. Tap opens the pane at that CLI; the context menu has Update, Sign In… and Open Agent CLIs. "N more you can install" opens the pane. |
| Pane kind | `agentHub` | The hub (three designs, below). Toolbar: summary ("5 updates · 2 need sign-in") and Check for Updates. |
| Commands | `openAgents`, `checkForUpdates` (palette, section menu), `cycleVariant` (palette, DEV/NIGHTLY) | |

The CLIs it knows by name are in `src/model/providers.ts`: Claude Code, Codex, OpenCode, Pi, Chief, Gemini CLI, Amp, Copilot CLI and Cursor Agent, each with its executable names, install hints per platform, and whether it has a sign-in of its own (Chief uses the cmux account). The owner may report other CLIs; they render with the owner's name. Install hints use the selected owner's `platform.os` (the legacy `os` field when absent). Unknown or unsupported platforms offer no install command or Install action; they never default to this Mac. Only an explicitly complete inventory establishes that an unreported CLI is "Not installed". Partial caches show unknown cells and an incomplete-inventory summary. An unverified launcher uses `installed: null`; it stays visible without install/update actions. No account observations means unknown sign-in, not signed out.

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

The existing `machine.list` record now carries a small non-secret `platform` object (`os`, `arch`) and a `capabilities` list. The local daemon reports `terminal`, `workspace` and `agent_session`; agent CLI versions, install paths and account labels remain the session host's responsibility. Remote owners can add capabilities without changing the agent app's machine discovery flow.

The native app now serves `agent_cli.list` through its verified provider channel for callers granted `agent_cli:read`. It selects an existing admitted route by the public machine ID (the local route when omitted), requires the daemon's `agent-inventory-owner-v1` check, and returns `{machine, cached:true, complete:false, clis}`. The cached owner identifies families from checked executable/package evidence; unclassified profiles are omitted. Conflicting versions and sign-in evidence stay unknown, accounts remain empty and updates report `updatable:false`. Route removal, replacement or policy revocation during a read discards its result. Unknown or unavailable machines never fall back to this Mac. Live `check_latest:true`, execution and watch operations remain unsupported. The app requests `machine.list {catalog:true}` to discover existing admitted Cloud/SSH/server routes. The paired-server conversations-only relay still has no inventory authority; actual Cloud/SSH network journeys remain unverified.

The app separately negotiates `agent-cli-app-provider-v1` before registering the new provider family. An older daemon receives only the existing families, preserving CodeRouter and action operations.

Inventory refreshes stay with the selected public machine ID. A mismatched or missing owner echo is refused; an older discovery/read cannot overwrite a newer owner read, and removal retires pending reads and clears that machine's observations, jobs and selection. A failed discovery does not fall back to this Mac. Only `operation.unsupported` retains the legacy anonymous local route; local Accounts fallback requires a currently discovered local route. These client checks do not replace owner-side admission. The client subscribes to the read-scoped `agent_cli.changed` invalidation and ignores its payload. It re-discovers the current catalog and re-reads admitted owners with `check_latest` absent; one invalidation batch runs at a time, and changes during it retain one follow-up. Event payloads cannot supply observations, select a machine, run a command or finish a job. The production verified-app provider now connects readable demand to admitted native owner watches, with captured control stamps and conditional lease cleanup. The current native admission protocol passes 62 inventory cases; current-native app composition still awaits artifact publication. This prototype is unbundled, and live registry checks, account labels and visible jobs remain open.

| Op | Params | Result | Owner | Risk | Scope | Events | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `agent_cli.list` | `{machine?, check_latest?}` | `{machine, cached?, complete, clis: [{cli, name?, installed: boolean\|null, version, latest: {version, checked_at}, install_method, updatable, path_label?, auth_status?, accounts: [{account: acct_…, label, plan?, status}]}]}` | session host of that machine | read | `agent_cli:read` | `agent_cli.changed` (invalidation) | `agent.list` is running agents, not installed CLIs |
| `agent_cli.update` | `{machine?, cli}` | `{job, terminal}` | session host | execute, origin user, gesture | `agent_cli:execute` | owner job receipt (pending) | `workspace.run` would make the app choose and spell the command; the owner picks the command for the detected install method |
| `agent_cli.install` | `{machine?, cli, method}` | `{job, terminal}` | session host | execute, origin user, gesture | `agent_cli:execute` | owner job receipt (pending) | same; the method is one of the provider table's hints, never free text |
| `agent_cli.sign_in` | `{machine?, cli, account?}` | `{job, terminal}` | session host | execute, origin user, gesture | `agent_cli:execute` | owner job receipt (pending) | `accounts.reauthenticate` exists only on this Mac and only for providers CodeRouter links |
| `app.pane.open` | `{kind}` | `{pane}` | shell | mutate-own, gesture | `workspace:write` | | open this app's pane from the section |

Rules for the owner: `complete: true` is an explicit claim of an exhaustive installed-CLI inventory; absent, malformed or false completeness stays partial. A cached harness/profile view is partial even when it has rows. Preserve unknown installation evidence with `installed: null`, and do not infer a CLI family from a configured profile id. `auth_status` may carry presence-only `signed_in`, `missing`, `expired` or `unknown` evidence without inventing an account. Accounts carry an opaque `acct_…` and a non-secret `label` (user-set, or the organization or plan name, or "Account 1"); never the email the CLI's config holds (the Swift detector's `identity` is an email today, so it must be mapped). Live latest-version checks need a future explicit owner operation using the registry for the install method (npm, Homebrew or the CLI's release feed). Cache invalidations and reads never initiate registry requests. Updates run in a visible terminal with origin user and the gesture token; a CLI installed by an unknown method reports `updatable: false` and the app says "Update it the way you installed it".

The existing Rust harness-health updater binds npm updates to the detected installation's absolute prefix and retains the detected package, including forks. Separate prefixes remain separate batch targets. An unknown prefix, an older cached npm plan without a bound target, or a plan for a different package cannot run; a fresh health check must supply its target. Existing elevation refusal remains in force. This shared updater foundation does not enable the proposed Agents execution operations or provide their visible-terminal job receipts.

All action surfaces share one pending request per machine and CLI. A second Update, Install or Sign In tap sends no operation while that request or job is active. The request captures its admission before the host call; machine removal retires it, and a late success or refusal cannot settle a later request after re-admission. Ordinary catalog rediscovery preserves an active request. The legacy local Accounts hop retains the same request until its answer. These client checks do not authorize execution or establish job completion; the selected owner must still admit the operation and provide its job receipt.

## Platform gaps (most important first)

1. Cached CLI inventory has a native machine owner and app adapter; exhaustive discovery, live version checks, account labels, visible jobs and the sibling `skill.*`, `mcp_server.*` and `memory.*` capabilities still need their owner paths.
2. `machine.list` returns only the local owner by default; this app opts in to the admitted catalog. Native/app composition is tested over an isolated Unix server carrier, while live Cloud/SSH transport and private-provider adoption remain unverified.
3. No account label owner: sign-ins have no opaque handle (`acct_…`) and no user-editable non-secret label; the native detector exposes an email.
4. `accounts.reauthenticate` takes no machine and covers only CodeRouter providers.
5. `agent_cli:read` is recognized for `agent_cli.list`; execution operations and owner job receipts remain unimplemented; the production invalidation bridge is wired and its new admission protocol still needs composed validation.
6. Scene: no table or grid (the matrix uses fixed-width texts), no ScrollView (long lists clip in the sidebar), no button prominence (Update looks like every other button), no copy-to-clipboard for an install hint.
7. Catalog fragments have no field that binds an op to a JS export; the sketch uses `export`.
8. Palette commands carry no gesture token, so "Update" cannot be a palette command with a CLI argument.
9. `x-cmux-devOnly`, `app.settings.set`, app l10n (`strings/*.json` are bundled into `dist/main.js`) are not honored by every host yet.

## Layout and checks

`src/model/` (provider table, version parsing and semver precedence, entries and evidence rules, proposed host-run job state machine), `src/store.ts` (machines, entries, jobs; `agent_cli.changed` invalidations and owner re-reads, no polling), `src/actions.ts` (gesture-carrying asks), `src/views/` (section, variants, shared parts), `src/l10n.ts` + `strings/`. No third-party code.

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/agents
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/agents
bun test first-party-apps/agents/test
```

`preview/*.json` are preview-harness fixtures (invented machines, versions and labels); `preview/make-fixtures.ts` regenerates them.
