# Chief tool packs: one layer for CLIs, skills and sign-ins

Status: design and v1, 2026-10-24. Branch `feat-cmux-next`. Merges and replaces, as the plan,
[chief-github-DESIGN.md](chief-github-DESIGN.md) (GitHub becomes the first pack),
[chief-skills-mcp-DESIGN.md](chief-skills-mcp-DESIGN.md) (a pack carries its skill) and the tool
surface of [chief-tools-DESIGN.md](chief-tools-DESIGN.md) (send/stop/sleep stay built-in tools;
packs are the shell tools a Chief's turn reaches on PATH). Those docs stay as the record of their
slices.

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
| Pack (data, per service) | the tool to install, how to sign in (method + params), where the secret goes (env vars, git host), how to check who it is, a health command, and a SKILL.md | `toolpacks/NAME/pack.toml` + `toolpacks/NAME/SKILL.md` |
| Alias (Rust, thin) | `optchat-chief github ...` = `optchat-chief pack ... github` (old verbs `pat`, `mac` kept) | `src/github.rs` |

No pack needs Rust. A pack that only teaches a CLI (cmux, browser) is a pack.toml with no `auth`
plus its SKILL.md.

## 3. pack.toml

```toml
name = "vercel"                    # [a-z0-9-], the folder name
title = "Vercel"
description = "Deploys and previews with the vercel CLI"
health = ["vercel", "whoami"]      # run with the secret injected (`chief pack check vercel`)
# enabled = false                  # in a user copy: turn a shipped pack off

[tool]                             # what must be on PATH; `chief pack install NAME` runs one of these
bin = "vercel"
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
```

Every field that reaches a shell (name, bin, env names, git host and args) is checked against a
strict character set at load; a pack that fails is skipped with a warning, never half used.

## 4. Where packs come from (same rule as skills)

1. Shipped in the host binary (`toolpacks::BUILTIN`, `include_str!` of `optchat-chief/toolpacks/`):
   `github`, `cmux`, `browser`, `vercel`. At host start they are written to the shared folder
   `~/.cmux/chief/toolpacks/NAME/` (`$MUX_HOME/../toolpacks`) with `# cmux-managed: true` on the
   first line; the host rewrites a managed file on update and never touches a copy whose marker
   the user removed.
2. Shared by all of the user's Chiefs (an org drops its packs here too): `~/.cmux/chief/toolpacks/`.
3. One Chief's own: `$MUX_HOME/toolpacks/NAME/`. Wins over shared, which wins over shipped.

A pack's SKILL.md is installed as a skill: shipped ones join `skills::BUILTIN` (the GitHub pack's
skill keeps its name `github-signin`); a user pack's folder is linked into the matching skills
folder under its skill name when no skill of that name exists. So the prompt, which names the
skill folders, needs no change and stays byte-identical.

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

## 7. CLI

`optchat-chief pack list | status NAME | login NAME | wait NAME [SECONDS] | paste NAME FILE|- |
share NAME | logout NAME | token NAME | check NAME | install NAME [--json]` (the Chief: `chief pack ...`).
`optchat-chief github status|login|wait|pat|mac|logout|token` stays, word for word, as an alias.

## 8. Cloud Chief

- Brain host on a VM (`optchat-chief host` on Linux, the Rust Cloud Chief route): the same code,
  the same packs, the file store. Nothing extra.
- Worker route (`backend/apps/api/src/chief-brain-cc/`, turns run by `chief-turn-runner`): GitHub
  stays on `github.ts` for this slice. Next: `optchat-chief pack export --json` prints the packs'
  wrappers and SKILL.md files as turn files (`{rel path: text}`), which `turn.ts` already writes
  through `files`; its token source moves from `github_token` to per-pack sealed secrets in the
  `<agent>/github` object, renamed `<agent>/packs`.

## 9. Tests (failing first)

`Native/OptChat/optchat-chief/tests/toolpacks.rs`: shipped packs parse and GitHub's carry a607's
constants; shared overrides shipped and own overrides shared; a managed copy is rewritten and a
user's kept; an unsafe pack is refused; a data-only pack (written by the test, no Rust) gets its
wrapper, its git helper and its git env; the file store is 0600 per pack; the turn directory gets
the `gh` shim and a Vercel wrapper. github.rs's unit tests (headers, card, describe, window) move
to toolpacks.rs and run against the GitHub pack unchanged.

## 10. Later

- `pack export` and the Worker route (section 8).
- Grants: `chief_profile::Grant.packs`, like `tools` (chief-skills-mcp-DESIGN.md "Grants").
- A settings row per pack (status, sign in, sign out) on Mac and iPhone, reading `pack status --json`.
- An MCP server per pack (`[mcp]` table merged into the turn's `.mcp.json`).
