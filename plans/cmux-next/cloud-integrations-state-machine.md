# Cloud integrations: the state machines

Status: written 2026-11-21 from the code on `feat-cmux-next` and cmux-platform `main` (1c739cd1), while
dogfooding the Cloud integrations end to end. Leo, 2026-11-21: "the f***ing stateful state machines in order to
fully properly deal with cloud, like having that mapped out ... do you want to be able to like do it without the
GitHub account linked? Maybe, maybe not."

Four flows: connect GitHub (the App install), repositories, MCP, and Cloud chat start. Each section has the
states as stored today, the transitions with the code that makes them, the failure edges, and where the client
collapses states that need different fixes. Section 5 says what Cloud means with no GitHub linked. Section 6 lists
the breaks found and their fixes.

Paths: `api/` is `backend/apps/api/src/`, `mac/` is `Packages/macOS/CmuxNext/Sources/`, `platform/` is
cmux-platform `src/`.

## 0. Principle

The product is a machine plus an agent. GitHub is a capability the agent sometimes needs, not an identity and not
a precondition. Ask for authority only at the operation that needs it, naming the repository and the reason. A
Cloud chat start never waits on GitHub.

## 1. GitHub connection (per team)

### States (server, `Connection.status`)

| State | Meaning | Exits |
|---|---|---|
| (none) | No connection row for the team. `GET /v1/integrations/github/status` answers `connection: null` | `integration.connect` → pending |
| `pending` | Connect answered an install or authorize URL with a signed state (ES256, 15 min, `integrations/state.ts`) | complete → active; 30 min → expired (`connection-do.ts` alarm); `setup_action=request` (a non-owner asked an org owner) → throws `state_invalid`, stays pending until expired |
| `active` | Installation id sealed; repos recorded (default scope) | `installation.deleted` → needs_reauth("uninstalled"); `installation.suspend` → needs_reauth(suspended); mint 401/404 → needs_reauth (relink); disconnect → revoked |
| `needs_reauth` | Linked, but GitHub no longer honors it | unsuspend / `new_permissions_accepted` (suspended only) → active; a new Connect makes a **new** connection (reinstall gives a new installation id); the old row leaves only by an explicit revoke |
| `error` | Server-side failure | retry |
| `revoked` | Disconnected; its tokens revoked at GitHub | terminal |
| `expired` | Pending past 30 min | forgotten after 24 h |

Policy (`domains/connections.ts`): `github.scope` is `linking_user_repos` (default: the repos the linking user could
reach at link time, `integrations/providers.ts` complete) or `installation`; plus `require_org_admin`,
`repo_allowlist`, `allow_workflows`. At most 50 non-revoked connections per team.

### Webhooks (`POST /v1/hooks/github`, `ingress/provider-hook.ts` → `connection-do.ts` `githubInstallationEvent`)

| Event | Effect |
|---|---|
| `installation.deleted` | needs_reauth "the GitHub App was uninstalled" |
| `installation.suspend` | active → needs_reauth (suspended) |
| `installation.unsuspend`, `installation.new_permissions_accepted` (not suspended) | scopes synced; suspended → active |
| `installation_repositories.removed` | repos leave the recorded list |
| `installation_repositories.added` | **ignored** before this change (see 6.1) |
| `github_app_authorization` (user revoked the App) | ignored: the next mint's 401 finds it |

A missed webhook is found lazily, on the next mint or listing.

### Client states (what the Mac should model)

Two axes, not one boolean:

- Connection: `unknown` (not read, or the read failed) · `not_configured` (this deployment has no App: hide
  Connect) · `unlinked` · `linking` (pending, browser open) · `linked` · `needs_reauth(suspended | uninstalled |
  revoked | permissions_pending)` · `error`.
- Repository, only when linked: `granted` · `not_granted` (fix: the installation's configure page, not Connect) ·
  `unknown`.

Today `mac/CmuxNextCloud/API/CloudGitHubApp.swift:21-40` maps every status but `active` to `notConnected`, and a
policy refusal (`allowed: false`) to `unknown`. Collapsed edges:

1. `pending`, `needs_reauth`, `error`, `revoked`, `expired` all read "Connect GitHub". A suspended install is told
   to connect when its fix is one click on GitHub.
2. A failed status read and `connection: null` look different (`unknown` vs `notConnected`), which is right; keep it.
3. `404 integration.not_found` means no connection, an unusable selected connection, or (production) the closed
   machine-token route (6.3). The platform turns all three into one message.
4. A completion the API refuses (`.refused`, `.noAnswer`, `CloudGitHubCompletion.swift:83-85`) shows nothing; the
   person returns from GitHub to the same Connect button (6.4).

### Transitions with their failure edges

```
unlinked --connect--> linking --callback ok--> linked
linking --state expired (15 min) / pending expired (30 min)--> unlinked   [client today: silent]
linking --setup_action=request (non-owner)--> linking until expired      [client today: silent]
linking --completion refused--> unlinked                                   [client today: silent]
linked --installation.deleted--> needs_reauth(uninstalled) --connect (reinstall)--> linked (new row; old row stays)
linked --suspend--> needs_reauth(suspended) --unsuspend--> linked
linked --mint 401/404--> needs_reauth (relink)
linked --disconnect--> unlinked (revoked)
any --status read fails--> unknown (never unlinked)
```

## 2. Repositories

Listing: `GET /v1/integrations/github/repos?team=` (`integrations/github-token-route.ts`, up to 10 upstream pages,
100 repos per answer) → `githubRepos` (`integrations/github-tokens.ts:281`) lists only active connections and
keeps only repos `githubRepoAllowed` passes (`domains/connections.ts:61`). Platform: `GET
/v1/connectors/github/repos` (`platform/server/connectors/GitHub.ts:401`). Client: `CloudGitHubPicker`
(`mac/CmuxNextCloud/API/CloudGitHubRepos.swift:229`).

Clone: the client asks `POST /v1/integrations/github/token` for a one-repo `contents:read` token
(`CloudGitHubCloneToken.swift`), or on a derived environment the platform mints a 5 min token and passes it on
stdin (`platform/server/environments/RepoToken.ts`). On the machine, git asks the system credential helper
(`cmux github credential`) only after a 401, and `gh` goes through the PATH shim (`cloud-github-auth-DESIGN.md`).

Per repo: `granted` → token; denials `owner_not_connected`, `connection_other_owner`, `repo_not_granted`,
`repo_not_allowed`, `permissions_not_granted`, `workflows_not_allowed` (`github-tokens.ts:148-236`); rate limit (burst
60, then 1/s) is a wait, never Connect (#48290).

Failure edges:
- A repo added to the installation later is `not_granted` under the default scope until a relink, and nothing
  prompts the relink (6.1).
- With one connection active and another broken, the listing silently leaves the broken one's repos out
  (`github-tokens.ts:294` answers 409 only when none is active).
- The platform drops a 403's `reason` and `configure_url` (`platform/server/connectors/GitHub.ts:111-116`), so
  "grant this repo here" never reaches the person on that path.

## 3. MCP

Two independent systems:

- Per-chat MCP on the machine: the acpmux daemon writes each session's MCP config (`cmux-tui/crates/acpmux/src/
  agent_tools.rs`) and serves the `cmux` server and its own tool servers over a loopback gateway
  (`mcp_gateway.rs`). Connection record states (`plans/cmux-next/mcp-connect-DESIGN.md` §2): `Pending ·
  NeedsSignIn · Connected · NeedsReapproval · Failed(reason) · Revoked`. Only the person answers a connect card.
  On teleport to a Cloud machine a record arrives `NeedsSignIn` (§7).
- Hosted MCP servers (platform `server/mcp-servers/*`, OAuth in `server/mcp-oauth/*`): server status `ready ·
  changed · unreachable · needs_auth` (`Servers.ts:523`); call errors `needs_auth`, `access_revoked`,
  `cursor_stale`, `rate_limited` (`server/Mcp.ts:102`).
- The GitHub MCP on a machine (`acpmux github-mcp`) uses the same minted tokens as git and gh, so it inherits
  section 1's states exactly.

Edges: a non-GitHub MCP server's `needs_auth` is its own and is never gated on GitHub. The GitHub MCP with no link
should answer a typed "needs GitHub" tool result, not a bare error.

## 4. Cloud chat start

```
requesting (token, team) -> creating (POST machine; claim a warm spare or provision)
  -> machine: provisioning -> starting -> running        (CloudMachineStatus, platform protocol)
  -> link: idle -> starting -> up                        (CloudLinkPhase)
  -> agent-session-start over the carrier -> first reply
failure edges: create failed(text) · link failed(text) (the daemon retries) · machine failed
              · claim missed (falls back to provision) · agent start failed · no reply
pause: running -> pausing -> paused -> (resume) starting -> running;  delete: deleting
```

Derived environments (repo setup; platform `server/environments/Model.ts`): record `building · ready · failed`,
steps `pending · running · done · failed · skipped`. `needs_github` gets one immediate retry, others a cooldown.
The surface is on in development and staging only (`CLOUD_ENVIRONMENTS_ENABLED`); production has it off.

GitHub sits on none of these edges. A repo pick adds one step after `running` (clone), whose failure is a repo
state from section 2, never a start failure.

## 5. No GitHub linked: what it means

| Surface | Behavior |
|---|---|
| Start a Cloud chat | Works fully; nothing on the start path reads GitHub |
| Repo picker | Offers a public URL and "no repo", plus one Connect row; never a generic not-found |
| Public clone | Works, anonymously (git asks the helper only after a 401) |
| Private clone | Asks to connect at the 401, naming the repo; the clone retries after linking |
| Push, PR | Asks at the first push; the agent keeps committing locally, nothing lost |
| GitHub MCP | Public reads work; authenticated tools answer a typed "needs GitHub" result |
| Other MCP servers | Independent of GitHub |
| The agent's `gh` | The shim runs gh with no token and prints one line on how to connect (`cloud-github-auth-DESIGN.md` §3.2) |

Your own credential: kept. The App cannot cover an org where the person is not an admin, so "Set Up GitHub on This
Machine" (device flow) stays as "use my own GitHub login on this machine". Per repo, the App token wins where the App
covers the repo (one repo, at most 1 h, never at rest); the person's own login serves the rest; the person's explicit
`GH_TOKEN` or own gh login always wins (§3.2's existing order).

## 6. Breaks found, and their fixes

1. **Added repositories never reach the connection.** Add a repo on the installation's configure page ("Add more
   repositories"), come back: the picker does not list it and mints refuse `repo_not_granted`, until a relink nothing
   prompts. Fix: record the linking user's GitHub id at link; on `installation_repositories.added` whose `sender` is
   that same user, join the added repos (adding a repo to an installation needs admin on it, so the sender reaching
   it is proven). Any other sender keeps today's behavior. The link-time boundary is unchanged.
2. **Derive's Connect is not a pure read.** `RepoToken.ts:178` runs `integration.connect` for each `needs_github`
   failure, adding a pending row toward the cap of 50. Development and staging only (production has derive off).
   Fix: return a connect intent; make the row when the person clicks.
3. **Production machine-token is closed.** `github-token-route.ts:96` answers 404 outside development and staging,
   and the platform reads a 404 as `needs_github`. Latent: production has derived environments off. Enabling them
   in production must open this route first, or every linked person is told to connect.
4. **A refused completion is silent.** `CloudGitHubCompletion.handle` drops `gitHubComplete`'s answer. Fix: keep the
   last answer on `CloudGitHubChanges` and show "The link expired; connect again" (or the API's reason) where
   Connect is.
5. **`needs_reauth` reads as "Connect".** Map the server's status and detail to the client states of section 1, each
   with its own words and fix URL.
6. **Webhook fan-out stops at one failure.** `provider-hook.ts:35-39` awaits each team's ingest in turn without a
   per-link catch. GitHub's redelivery recovers it (ingest is idempotent by delivery id).

7. **A running app days older than the installed one answers for it.** On Leo's account (2026-11-21, air-blue)
   `cmux chat --on vm:new --harness claude --no-folder --wait` was refused in 393 ms with a login-consent message
   the code dropped on 11-17 (#40159). The installed NIGHTLY (4487759453601) has no such refusal and its probe
   passes; the running NIGHTLY process had started 11-16 and never relaunched after the update. Not a Cloud bug:
   nothing tells the person or the CLI that the running build is older than the installed one. Fix: the app offers
   "Restart to update" when its bundle on disk is newer, and the CLI warns when the app it reaches is another build.
8. **The cmux MCP was never offered to agents until asked.** `cmux setup mcp` reported `needs_user` with
   `agents.cmuxMcp: "ask"` on the same account. Fixed: `agents.cmuxMcp` is now on by default and only `off` turns
   it off, so agents started in cmux get cmux's tools with no question.

Measured on the same account, no GitHub link: `GET /v1/integrations/github/status` answers `connection: null`
(the unlinked state of section 1); `GET /v1/integrations/github/repos` answers 404 `integration.not_found` in
283 ms, which the picker must show as the Connect row of section 5, never as an error. Screenshots and video of the
GUI flows wait on air-blue's screen being unlocked.

Fixes merged or open are listed with their PRs in this file's PR and its follow-ups.
