# GitHub auth inside cmux Cloud machines

Status: design and v1, 2026-10-27. Branch `feat-cmux-next`.
Ask (Lawrence, 2026-10-27): the Mac's `gh` login does not reach a Cloud workspace. Copying
`gh auth token` to the machine works but puts a long-lived, account-wide token on a VM. Build the
proper path: a GitHub App, short-lived repo-scoped installation tokens minted server-side, and a
credential helper so `git` and `gh` on the machine just work.

## 1. What already exists (checked 2026-10-27)

Most of the path is built. It does not reach a person, for three reasons (section 2).

| Piece | Where | State |
|---|---|---|
| GitHub Apps | `cmux-app` (production, App id 5160807, named "cmux app"; it was `cmux-cloud` until 2026-11-25), `cmux-cloud-staging` (staging, 5160799); the Worker secrets hold each one's client id, client secret and key (see [The App's name](#the-apps-name)) | exist. No new App is needed. |
| Team connection (install the App, link it to a cmux team) | `backend/apps/api/src/integrations/providers.ts` (`github`), dashboard `integrations/` | built |
| Token endpoint `POST /v1/integrations/github/token` | `backend/apps/api/src/integrations/github-token-route.ts`, `github-tokens.ts` (Leo, #25044) | built. One repo, the asked permissions only, sealed per-principal ledger in ConnectionDO, reused while 15 min remain, revoked at GitHub on install revoke or machine delete, audited, rate-limited. A `vm` install speaks only for its own live machine (vmGate). |
| Machine agent minter | `cmux-tui/crates/cmux-host/src/cloud/github.rs`, `github_minter.rs` (#25039) | built. Socket `/run/cmux-vm-agent/agent.sock` (root:cmux 0660). The machine bearer never leaves the agent. |
| `cmux github credential` (git helper), `cmux github gh`, `cmux github setup` | `cmux-tui/crates/cmux-host/src/github_cli.rs` (#25076, #25077) | built. Opt-in: nothing runs `setup`. `gh` needs the `cmux github gh` prefix. |
| `cloud new-machine --repo` clone step | `Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Bootstrap/CloudMachineRepo.swift` | uses `cmux github credential` for the clone when the agent socket exists |
| Set Up GitHub on This Machine | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/CloudGitHubSetup.swift` | gh device flow on the machine: a long-lived OAuth token in the machine's `~/.config/gh/hosts.yml`. This is the path this design replaces as the default. |
| Chief GitHub logins | `plans/cmux-next/chief-github-DESIGN.md` (a607) | per-Chief logins; separate from Cloud machines |
| Leo's cloud auth PRs #26148 #26211 #26212 #26170 | Codex/Claude auth recovery and the Codex refresh broker | agent model auth, not GitHub; no overlap |

Live state (probed 2026-10-27 with the dogfood and staging e2e accounts, `GET /v1/integrations/github/status`):

| Env | App configured | A team connection | Cloud machines boot from |
|---|---|---|---|
| development (`cmux-api-development`) | no | n/a | `cmuxnp-dev-vmimg-ci-40270232246-1` |
| staging (`cloud-api-staging.cmux.dev`) | yes, `cmux-cloud-staging` | none for the e2e team | no `CLOUD_FREESTYLE_SNAPSHOT` in wrangler.jsonc |
| production | `cmux-app` (Worker secrets) | not probed | no `CLOUD_FREESTYLE_SNAPSHOT` in wrangler.jsonc |


## The App's name

Leo renamed the production App on 2026-11-25 ("I'll go with cmux app then"): "cmux Cloud" (`cmux-cloud`) became
"cmux app" (`cmux-app`, https://github.com/apps/cmux-app). A rename keeps the App id, client id, keys, client
secrets and every installation, so no connection moves and nothing mints from another key. It changes the slug, so the
install URL (`github.com/apps/<slug>/installations/new`) and the bot login (`cmux-app[bot]`). The old slug was taken
again the same day by a different, empty App (5927057, also "cmux Cloud") that reserves the name: an install URL built
from a stale `GITHUB_APP_SLUG` sends a person to that App, not ours.

So cmux-api reads the slug from GitHub (`GET /app` with the App's JWT, `providers.ts` `githubAppSlug`, cached an hour)
and keeps `GITHUB_APP_SLUG` only as the fallback; everything downstream (macOS, the Rust CLI, cmux-platform's
connector) builds install URLs from the status answer's `app_slug`. Nothing builds a URL from a display name.

What is configuration, per Worker (`cmux-api`, `cmux-api-staging`, `cmux-api-development`): `GITHUB_APP_CLIENT_ID`
(also the JWT issuer), `GITHUB_APP_CLIENT_SECRET` (the OAuth leg: user authorization during install and
`login/oauth/authorize`), `GITHUB_APP_PRIVATE_KEY` (PKCS#8), `GITHUB_WEBHOOK_SECRET`, and `GITHUB_APP_SLUG` (fallback).
Switching a deployment to another App is these five secrets; the old App's connections then stop minting, since an
installation belongs to one App.

The App's settings that only its owner's settings page changes (no API): the callback URL, which must be the
console's `/integrations/callback` (`https://console.cmux.dev/integrations/callback` for production), with
"Request user authorization (OAuth) during installation" on; and the webhook events
(`bun backend/apps/api/scripts/github-app-drift.ts --live` names any that are missing). The webhook URL and secret are
API-settable (`PATCH /app/hook/config`); production's points at `https://cloud-api.cmux.dev/v1/hooks/github`.

## 2. Why it does not work today

1. **The image predates the minter.** `images/cmux-vm/inputs.lock.json` pins cmux-tui
   `c2bab662bc8` (2026-10-21). The minter (#25039) and `cmux github` (#25076, #25077) landed
   2026-10-24. Every Cloud machine runs a `cmux` with neither: the agent ignores `github_token`
   lines and `cmux github` is an unknown verb.
2. **Nothing wires git or gh.** Even with a new binary, git uses the helper only after a person
   runs `cmux github setup`, and plain `gh` (what people and agents type) has no token. Agents do
   not know the `cmux github gh` prefix.
3. **No env has both halves.** Staging has the App but boots no Cloud machine; development boots
   machines but has no App.

## 3. Design

Principle: the machine holds no GitHub secret at rest. A token exists only in the memory of the
one git or gh process that asked, lives at most 1 hour, names one repository and the least
permissions the operation needs, and is minted by the API under the team's policy. The person's
own choices (a `GH_TOKEN`, their own `gh auth login`, their own git helper) always win.

### 3.1 git: a system credential helper (image)

The image writes `/etc/cmux/gitconfig` and includes it from `/etc/gitconfig`:

```ini
[credential "https://github.com"]
	helper = !/opt/cmux/current/bin/cmux github credential
	useHttpPath = true
```

- System scope, so a person's `--global` config adds helpers after it, and `gh auth setup-git`
  (which writes an empty `helper =` first) replaces it: the person's choice wins.
- git asks a helper only after a 401, so public clones never mint.
- `credential get` already infers read vs write from the git ancestor's argv, falls back from
  write to read on `policy.denied`, and prints nothing when it has no answer (git goes on to the
  next helper or its prompt).

### 3.2 gh: a PATH shim (image) and `cmux github gh --auto` (cmux)

`gh` has no credential-helper hook, so the image puts `/opt/cmux/github/bin/gh` first on PATH
(the host unit's `PATH`, so every terminal and agent the machine starts, and the login profile).
The shim is three lines: when the agent socket and the cmux binary exist it runs
`CMUX_GITHUB_GH_REAL=/opt/cmux/current/bin/gh cmux github gh --auto -- "$@"`, else the real gh.

`--auto` decides, in this order (pure function `gh_auto_route`, unit-tested):

| Case | What runs |
|---|---|
| `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` or `GITHUB_ENTERPRISE_TOKEN` set | the real gh, untouched |
| the person has their own gh login (`github.com:` in gh's `hosts.yml`) | the real gh, untouched |
| no arguments, or `auth`, `config`, `help`, `version`, `completion`, `alias`, `extension`, `--version`, `--help`, `-h` | the real gh, untouched |
| no repo (no `-R`, no `GH_REPO`, not in a GitHub checkout), a non-github.com URL or host | the real gh with no token, and one stderr line that says how to get one |
| otherwise | the real gh with `GH_TOKEN` for that one repo |

Permissions: reads (`view`, `list`, `status`, `diff`, `checks`, `watch`, `download`, `browse`,
`search`, and `gh api` with no method other than GET and no fields) ask the read set. Every other
command asks the write set (contents, pull requests, issues write; checks, actions, statuses,
metadata read), then the read set when the team policy refuses write. `workflows: write` stays
opt-in (`CMUX_GITHUB_WORKFLOWS=1`), as for git.

A refusal from the API (no connection, policy, rate limit) does not block gh: it runs without a
token and gh says what it says, after one line from cmux with the API's reason.

### 3.3 Connecting a team (person, once)

A team admin installs the cmux GitHub App on their GitHub account or org and picks repositories:
`https://github.com/apps/<slug>/installations/new` (production: `cmux-app`) through the existing integrations connect
flow (the state parameter links it to the team). After that every machine of the team mints for
those repositories. The Mac app's Set Up GitHub on This Machine should check
`GET /v1/integrations/github/status` and offer this connect step instead of the device flow
(follow-up, section 5).

### 3.4 Refresh, revoke, audit

Nothing to refresh on the machine: each git or gh run asks again, and the API reuses a cached
token while 15 minutes remain, so a long session never holds an expired token and no daemon keeps
one. Revoke and audit are the endpoint's (machine delete or install revoke deletes every token at
GitHub; each mint is an audit record with the machine, repo, permissions and token id).

### 3.5 Rejected

- Copy the Mac's `gh auth token` to the machine: long-lived, every repo and org the person can
  reach, at rest on the VM, and outlives the machine.
- Device flow on the machine (today's Set Up GitHub): same token shape, made on the machine.
- Inject `GH_TOKEN` into the terminal environment at create: it expires in an hour and every
  process (and every agent transcript of `env`) would see it.
- A long-running refresher that rewrites `hosts.yml`: a token at rest, and a race at expiry.

## 4. Rollout (staging first)

1. Land 3.1, 3.2 (this change) on `feat-cmux-next`.
2. Wait for the cmux-tui artifacts build of that commit on files.cmux.com, pin it
   (`bun images/cmux-vm/pin-cmux-tui.ts --commit <sha> --write`), bake (`cloud-vm-image-bake.yml`),
   smoke, promote to dev.
3. Give the development Worker a GitHub App (the staging App's id and key, or a dev App), or give
   staging a Freestyle snapshot, so one env has both halves. Credential step: the person.
   Chosen 2026-11-17: a dev App, `cmux-cloud-dev`, created from a manifest, with development
   connects finishing on the staging console (`docs/cmux-next/cloud-dev-github-app.md`).
4. Connect a test team to the App; on a fresh machine: `git clone` a private repo, `git push` a
   branch, `gh pr list`, `gh pr create`; check the audit records and that no file under the work
   home or `/etc` holds a token.
5. Promote to staging, then production, with the normal image promote.

## 5. Follow-ups

- Set Up GitHub on This Machine: App connection first (status, then the connect page), device
  flow only when the person asks.
- Machines updated in place (`cmux host update`) keep their old `/etc/gitconfig`: the Cloud agent
  could write 3.1 at start. New machines get it from the image.
- `workflows: write` on demand for gh (today an env var).
