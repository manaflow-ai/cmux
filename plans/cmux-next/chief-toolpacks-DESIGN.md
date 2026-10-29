# Chief tool packs: one layer for CLIs, skills and sign-ins

Status: design and v2, 2026-10-24. Branch `feat-cmux-next`. The one design for what a Chief gets
beyond its built-in tools: CLIs, sign-ins, skills and MCP servers. It merges
[chief-github-DESIGN.md](chief-github-DESIGN.md) (GitHub is the first pack; the Worker section
there still holds), chief-skills-mcp-DESIGN.md (folded in whole: sections 4, 6a and appendix A) and
the Chief side of [mcp.md](mcp.md) (section 6b; mcp.md stays the contract of `cmux mcp serve`).
[chief-tools-DESIGN.md](chief-tools-DESIGN.md) keeps the built-in send/stop/sleep tools.

User (Lawrence, 2026-10-24, second ask): packs cover Chief skills and MCP servers too, not only
CLIs and sign-ins. A pack folder holds any mix of CLI tools with auth and injection, skills, and MCP
servers; the core writes each Chief's MCP config from the packs that are on, with the same
managed-versus-user rules as skills.

User (Lawrence, 2026-10-24): GitHub should not be its own Rust module. Make a general layer so
every Chief, the Cloud Chief included, gets a default set of CLIs, skills and tools that is not
coupled to Rust.

## 1. Why

`optchat-chief/src/github.rs` (814 lines, a607) held, for one service: a secret store (keychain
or a 0600 file), an OAuth device-code login with a 3 h fresh-code window, a token paste, a
fallback to the Mac's own `gh` login, a status check against the service's API, and a `gh` shim
plus a git credential helper written onto the turn's PATH. Every one of those is generic. The
next service (Vercel, Sentry, Linear, Cloudflare, npm) would have copied all 814 lines.

## 2. The split

| Layer | What | Where |
|---|---|---|
| Core (Rust, generic, once) | named secret store; device-code and paste login; status check over HTTP; per-call PATH wrappers that put a secret into an env var or a git credential; status, logout, share, health, install | `Native/OptChat/optchat-chief/src/toolpacks.rs` |
| Pack (data, per service) | any mix of: the tool to install, how to sign in (method + params), where the secret goes (env vars, git host), how to check who it is, a health command; skills; MCP servers | `toolpacks/NAME/pack.toml`, `toolpacks/NAME/SKILL.md`, `toolpacks/NAME/skills/*/SKILL.md` |
| Alias (Rust, thin) | `optchat-chief github ...` = `optchat-chief pack ... github` (old verbs `pat`, `mac` kept) | `src/github.rs` |

No pack needs Rust. A pack that only teaches a CLI (cmux, browser) is a pack.toml with no `auth`
plus its SKILL.md.

## 3. pack.toml

```toml
name = "vercel"                    # [a-z0-9-], the folder name
title = "Vercel"
description = "Deploys and previews with the vercel CLI"
health = ["vercel", "whoami"]      # run with the secret injected (`chief pack check vercel`)
# enabled = false                  # shipped off, or a user copy turning a pack off

[tool]                             # what must be on PATH; `chief pack install NAME` runs one of these
bin = "vercel"
# script = "vercel"                # or: the CLI is this file of the pack's folder (gdocs ships its own);
#                                  #   the turn's bin/<bin> runs it, with [inject] env set per call
brew = "vercel-cli"
npm = "vercel"
url = "https://vercel.com/docs/cli"

[auth]                             # absent: no secret, no wrappers
methods = ["paste"]                # "device" and/or "paste"
token_min = 20                     # a token is [A-Za-z0-9_.-], this long, alphanumeric first:
token_max = 255                    #   the only text the keychain command reads on stdin
login_hint = "chief pack login vercel"
tokens_url = "https://vercel.com/account/tokens"

[auth.device]                      # OAuth 2.0 device authorization grant (RFC 8628)
client_id = "..."
code_url = "https://example.com/login/device/code"
token_url = "https://example.com/login/oauth/access_token"
scopes = "a b"
verification_uri = "https://example.com/login/device"
window_minutes = 180               # a fresh code each time one ends, this long

[check]                            # who the token is (GET, Authorization: Bearer)
url = "https://api.vercel.com/v2/user"
login_field = "user.username"      # dotted path in the JSON answer
scopes_header = ""                 # optional
expiry_header = ""                 # optional

[inject]
env = ["VERCEL_TOKEN"]             # set on every call of tool.bin (unless already set)
git_host = ""                      # e.g. "github.com": git asks this pack for that host
git_user = "x-access-token"        # the username git gets with the token
git_via_tool = []                  # instead: git asks `<bin> ARGS...` (gh auth git-credential)

[share]                            # opt-in: with no own login, use the person's login on this host
label = "the Mac's gh"
command = ["gh", "auth", "token", "--hostname", "github.com"]

[[mcp]]                            # any number; a stdio command or a remote url
name = "vercel"                    # [A-Za-z0-9_-], unique, never "optchat"
command = "npx"                    # stdio ...
args = ["-y", "example-vercel-mcp"]  # an example name, not a real package
env = { VERCEL_TOKEN = "secret:vercel", MODE = "read" }   # literal, or a pack's stored secret
tools = ["list_projects"]          # the tools a turn may call; empty: all
enabled = true                     # per server; `chief pack enable vercel/vercel`

[[mcp]]
name = "vercel-remote"
url = "https://mcp.example.com"    # ... or remote (https, or http://127.0.0.1)
bearer = "secret:vercel"           # Authorization: Bearer <secret>
```

Every field that reaches a shell (name, bin, env names, git host and args, server names, secret
names) is checked against a strict character set at load, and a server needs exactly one of
`command` and an https `url`; a pack that fails is skipped with a warning, never half used.

## 4. Where packs come from, and which are on

1. Shipped in the host binary (`toolpacks::BUILTIN`, `include_str!` of `optchat-chief/toolpacks/`):
   `github`, `cmux`, `browser`, `gdocs` on (the default set; gdocs: chief-gdocs-DESIGN.md), `vercel`
   shipped off (the data-only proof). A pack's script (`BUILTIN_SCRIPTS`) is written beside its
   pack.toml, mode 0755. At
   host start they are written to the shared folder `~/.cmux/chief/toolpacks/NAME/`
   (`$MUX_HOME/../toolpacks`) with `# cmux-managed: true` (pack.toml) or `cmux-managed: true`
   (SKILL.md front matter); the host rewrites a managed file on update and never touches a copy whose
   marker the user removed.
2. Shared by all of the user's Chiefs (an org drops its packs here too): `~/.cmux/chief/toolpacks/`.
3. One Chief's own: `$MUX_HOME/toolpacks/NAME/`. Wins over shared, which wins over shipped.
4. On or off: the pack's `enabled` (and each server's), then the Chief's switches in
   `$MUX_HOME/toolpacks.json` (`chief pack enable|disable NAME` or `NAME/SERVER`), which change
   nothing in the pack files, so a managed pack keeps its updates.

`chief pack list` shows every pack, on or off, with its skills and servers.

### 4a. Skills (from chief-skills-mcp-DESIGN.md)

- Format: Claude Code skills, a folder `<name>/SKILL.md` with YAML front matter (`name`,
  `description`) and Markdown steps; Claude Code, Codex and OpenCode harnesses all read it.
- A pack's skills are its `SKILL.md` and every `skills/<name>/SKILL.md`. Each session setup
  (`session_dir::write`, `toolpacks::sync_skills`) links every skill of every pack that is on into
  the Chief's own folder `$MUX_HOME/skills/<name>` and removes the links of packs that are off. A
  real folder of the same name there is the user's and wins; a shipped pack not on disk yet gets its
  SKILL.md under `$MUX_HOME/optchat/pack-skills/` first.
- Plain skills, outside any pack: shared `~/.cmux/chief/skills/<name>/SKILL.md` (shipped ones,
  `skills::BUILTIN`, written at host start with the same managed rule) and the Chief's own
  `$MUX_HOME/skills/<name>/SKILL.md`, which wins by name. Shipped skills that moved into packs
  (`skills::RETIRED`: github-signin, cmux-cli, browser, vercel) lose their managed shared copy, so a
  Chief whose pack is off does not see them.
- How a Chief finds them: the Chief system prompt (every Chief, `prompt.rs`) names both folders
  and says to read a skill's SKILL.md before doing what its description names. The Claude Code
  `Skill` tool stays denied in turns (its listing would join every turn's uncached prefix), and the
  prompt holds no per-install list, so it stays byte-identical across turns. Codex turns have
  codex's own skill discovery off (`codex_home.rs`) and read the same folders by shell.
- Subagents read the same folders; the user's own `~/.claude/skills` stays theirs.
- Updates: a new cmux build brings new shipped packs and skills; the next host start installs them.
  No network fetch, no auto-update of user files.

## 5. Secrets

- Store per pack and Chief home. macOS: login keychain, generic password, service
  `cmux.chief.NAME`, account `paths::home_id`, written through `security -i` on stdin (never
  argv). Elsewhere (Linux brain host, Cloud Chief VM): `$MUX_HOME/optchat/secrets/NAME.json`,
  0600, in a 0700 folder. Status (never the token): `$MUX_HOME/optchat/NAME.json`.
- GitHub's names are exactly a607's (`cmux.chief.github`, `secrets/github.json`, `github.json`,
  `github-login.log`): an existing sign-in keeps working with no migration.
- Per call, never per turn: a wrapper asks `chief pack token NAME` each time it runs, so a
  sign-in, rotate or logout applies at the next command with no host restart.
- Secrets are per host. A Cloud Chief's VM has its own store; the Mac's keychain is never read
  from another machine. Using the person's own login is only the `[share]` option of a pack
  (shipped on for GitHub, which was a607's default; off for everything else).

## 6. Each turn

`session_dir::write` loads the packs and, for every enabled pack with `[inject]`:

- `bin/<tool.bin>`: drops its own folder from PATH, sets the env vars from `chief pack token NAME`
  when the first one is not already set, then `exec`s the real tool (exit 127 with a clear line
  when the tool is missing). The GitHub pack makes exactly a607's `gh` shim.
- `bin/git-credential-chief-NAME` for a `git_host`: either `exec`s the tool's own helper
  (`git_via_tool`, GitHub: `gh auth git-credential`, which keeps the share fallback) or answers
  `get` with `username=git_user`, `password=<token>`.
- `GIT_CONFIG_COUNT/KEY_n/VALUE_n` in the turn env: for each host the helper list is reset, then
  the pack's helper set.

### 6a. MCP servers

For every pack that is on, each server that is on joins the Chief's session (and its subagents'):

| Harness | Where | Stdio server | Remote server |
|---|---|---|---|
| Claude Code | session `.mcp.json` (`mcpServers`, beside `optchat`) and `enabledMcpjsonServers` in the project settings | `{type: stdio, command, args, env}`; through `bin/chief pack mcp PACK SERVER` when it takes a secret or limits its tools | `{type: http, url}`, with `headersHelper: chief pack mcp-headers PACK SERVER` for a bearer |
| Codex | the turn `CODEX_HOME/config.toml`, `[mcp_servers.NAME]` | `command`, `args`, `env`, `enabled_tools` (codex enforces the list) | `url`; a remote server with a bearer is left out for now (codex reads bearers only from its own env) |

- Secrets: `env = { K = "secret:PACK" }` and `bearer = "secret:PACK"` name a pack whose stored
  token is used. The value is read from the store when the server starts (`pack mcp`) or when Claude
  Code asks for headers (`pack mcp-headers`), never written to `.mcp.json`, config.toml or argv.
- Allowed tools: `pack mcp` sits between the harness and a stdio server: it drops other tools from
  each `tools/list` answer and answers a `tools/call` of another tool with an error. Codex also gets
  `enabled_tools`. A remote server on Claude Code cannot be filtered: it lists all its tools.
- Same names as before win: a pack server never replaces `optchat`; between packs the first by
  name keeps a server name.
- Cost: every listed MCP tool rides in every turn's prompt, so shipped servers are off by default
  (GitHub's remote server: `chief pack enable github/github`). The Chief's `cmux` tools stay with
  acpmux's own `cmux mcp serve` per agent chat (hq-6d, 2026-10-14); the `cmux` and `browser` packs
  carry skills and health checks, no second cmux server.

### 6b. cmux's own MCP server (from mcp.md)

`cmux mcp serve` (Rust `cmux`, `cmux-tui/crates/cmux-tui/src/cli/mcp*`, contract in [mcp.md](mcp.md))
gives any MCP client the cmux CLI's control: off by default (`mcp.enabled` in cmux.json), tools
from the protocol and browser-host catalogs, newline JSON-RPC over stdio. acpmux starts one per agent
chat, which is why no pack adds it again. A person wiring it into their own Claude Code or Codex
follows mcp.md.

## 7. CLI

`optchat-chief pack list | enable|disable NAME[/SERVER] | status NAME | login NAME | wait NAME [SECONDS] |
paste NAME FILE|- | share NAME | logout NAME | token NAME | check NAME | install NAME | mcp PACK SERVER |
mcp-headers PACK SERVER [--json]` (the Chief: `chief pack ...`). A change to packs or switches reaches
a Chief's MCP servers with its next session setup (host start); wrappers and secrets apply at once.
`optchat-chief github status|login|wait|pat|mac|logout|token` stays, word for word, as an alias.

## 8. Cloud Chief

- Brain host on a VM (`optchat-chief host` on Linux, the Rust Cloud Chief route): the same code,
  the same packs, skills and MCP servers, the file store. Nothing extra.
- Worker route (`backend/apps/api/src/chief-brain-cc/`, turns run by `chief-turn-runner`): GitHub
  stays on `github.ts` for this slice. Next: `optchat-chief pack export --json` prints the packs'
  wrappers and SKILL.md files as turn files (`{rel path: text}`), which `turn.ts` already writes
  through `files`; its token source moves from `github_token` to per-pack sealed secrets in the
  `<agent>/github` object, renamed `<agent>/packs`. Its MCP servers go the same way (`.mcp.json` as
  a turn file, secrets through `pack mcp` on the turn machine).

## 9. Tests (failing first)

`Native/OptChat/optchat-chief/tests/toolpacks.rs`: shipped packs parse and GitHub's carry a607's
constants; shared overrides shipped and own overrides shared; a managed copy is rewritten and a
user's kept; an unsafe pack is refused; a data-only pack (written by the test, no Rust) gets its
wrapper, its git helper and its git env; the file store is 0600 per pack; the turn directory gets
the `gh` shim, and a Vercel wrapper once it is enabled.
`tests/toolpack_mcp.rs`: enabling a pack adds its two skills and its stdio and remote servers to a
fresh session, Claude Code's `.mcp.json` and settings and the codex config.toml; disabling removes
them; no secret in any of those files; `pack mcp` passes the secret in env, filters `tools/list` and
refuses a tool off the list; a user's own skill of the same name wins; unsafe servers are refused.
github.rs's unit tests (headers, card, describe, window) move
to toolpacks.rs and run against the GitHub pack unchanged.

## 10. Later

- `pack export` and the Worker route (section 8).
- Grants: `chief_profile::Grant.packs` in the shape of `tools` (a profile may name the packs a Chief
  gets; empty means all), set by the Chief profile UI and `chief chiefs update`.
- A settings row per pack (on/off, status, sign in, sign out) on Mac and iPhone, reading
  `pack list --json` and `pack status --json`.
- Codex remote servers with a bearer (a stdio bridge in `pack mcp`).

## Appendix A. The chief-auth-escalation skill (from chief-skills-mcp-DESIGN.md)

Pieces, all landed together:

- **Subagent tool** `escalate_auth {site, url, reason, kind}` with kind
  `password | passkey | 2fa | oauth`, on the subagent's `optchat` MCP
  server, and `chief escalate-auth KIND SITE URL "why"` for harnesses
  without MCP. The host learns the caller's id from its acpmux session
  (`turn_caller.rs` `subagent_of`), else from `ACPMUX_SESSION_NAME`, and
  takes it only from a known subagent of this Chief.
- **Urgent note.** The brain queues `[aN] needs a sign-in (KIND) on SITE ...`
  at the head of the queue and steers it into a running Chief turn at once
  (`Brain::queue_urgent`); it is not a stuck note and never waits behind
  reports.
- **Chief prompt rule** (every Chief): follow the skill, never read or type
  a password or code, press the passkey or security-key button, post one
  line `Needs you: touch the sensor (SITE)`, watch the tab, `tell` the
  subagent when signed in. The old rule "Sign-ins, payments and passwords
  stay with the user" became "payments and typing passwords or codes stay
  with the user".
- **Subagent prompt rule** (every subagent): never wait on a login tab; call
  `escalate_auth` and go on with work that needs no sign-in.
- **Skill** `chief-auth-escalation`: the steps, the fill rules and the
  limits.

### A. Sites without a passkey-first sign-in

npmjs.com (checked live 2026-10-20) asks for user name and password first
(no `autocomplete=webauthn`), then 2FA, which can be a security key or
Touch ID. So the first step needs the password manager's autofill or the
user's typing; only the 2FA step is one touch. The skill says so and posts
`Needs you: sign in to SITE in the right pane` when no passkey step exists.

### A. WebAuthn in cmux panes (checked live 2026-10-20)

- cmux NIGHTLY (`com.cmuxterm.app.nightly`, the cmux-next app the user
  runs, build 1.0.0-nightly.3939068198101) has
  `com.apple.developer.web-browser.public-key-credential`. In a WebKit pane
  on webauthn.io, `PublicKeyCredential` exists and
  `isUserVerifyingPlatformAuthenticatorAvailable()` is true.
- A WebAuthn request from a tab behind other tabs fails at once: "The
  document is not focused." After `cmux browser <tab> select` the same
  Authenticate click raised no error and stayed pending (the system sheet's
  wait), but the sheet could not be seen from the agent: no system window
  showed in the on-screen window list and screen capture is not permitted
  to agents. So the skill raises the step with a356's `cmux browser right passkey REF`
  (`browser.page.passkey`, plans/cmux-next/agent-browser-passkey-DESIGN.md):
  `triggered` on a shown tab, else a banner whose click reveals the tab and
  starts WebAuthn. The skill never moves focus itself.
- cmux NEXT (`com.cmuxterm.app.nightly.cmux-next`) is signed without the
  entitlement, and `cmux.next-dev.entitlements` lacks it: its WebKit panes
  cannot offer passkeys. Follow-up: add it to that signing (the
  provisioning profile must carry it).
- CEF (Chromium) panes: not checked yet.
- Follow-up test: an app-level UI test that loads a local WebAuthn page in
  a WebKit pane, selects the tab and asserts the request reaches the
  authenticator (not NotAllowedError), on a fleet Mac with a virtual
  authenticator.

### A. Tests

- `optchat-chief/tests/auth_escalation.rs`: the tool list, argument checks,
  the launcher form and both prompt rules.
- `optchat-chief/tests/auth_escalation_brain.rs`: an escalation is steered
  into a running Chief turn; unknown subagents are refused; the caller id
  from the session name; shipped-skill install and the Chief-over-shared
  precedence.
