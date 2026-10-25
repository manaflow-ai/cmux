# GitHub sign-in for every Chief

Status: design and v1, 2026-10-24. Branch `feat-cmux-next`.
Superseded for the local Chief by [chief-toolpacks-DESIGN.md](chief-toolpacks-DESIGN.md): section 4 is now
the GitHub tool pack (`optchat-chief/toolpacks/github/pack.toml`) over `toolpacks.rs`; the verbs, keychain
service and files below are unchanged. Section 3 (the Worker) still holds.
User (Lawrence, 2026-10-23): GitHub sign-in is a default onboarding step for every Chief, not one.
Default is the gh device flow, shown as a tappable card in chat (works from the iPhone), polled where
it survives the turn, the token kept per Chief in a secret store and given to the Chief's `gh` and
`git` on every turn. Also: a fine-grained PAT paste, a GitHub App installation token, reuse of the
Mac's own `gh` login, sign-out and rotate, and the status (who, scopes, expiry) in Chief settings and
a CLI verb.

Why now: cloud agents could not push (a600, a601, a603: "Invalid username or token", and the VM
token had no `workflow` scope), and every Cloud Chief shared one Worker secret,
`CHIEF_CC_GITHUB_TOKEN`, which is one person's token for all Chiefs.

## 1. What exists (2026-10-24)

| Chief | Where gh gets its login | Per Chief? |
|---|---|---|
| Cloud Chief, Claude Code route | `backend/apps/api/src/chief-brain-cc/turn.ts` passes `env.CHIEF_CC_GITHUB_TOKEN` as the turn's `github_token`; `Native/OptChat/chief-turn/src/bin/chief-turn-runner.rs` writes it as `~/.config/gh/hosts.yml` plus a git credential helper | no: one Worker secret |
| Local Chief (`optchat-chief host` on the Mac) | the Mac's own `gh` login (keychain), inherited by the turn's tools | no: the person's |
| Brain host on a Linux box | whatever `gh` login that box has | no |

## 2. The model

One GitHub login per Chief, with one of five kinds:

| Kind | How it is made | Expires | Refresh |
|---|---|---|---|
| `device` (default) | OAuth device flow with the GitHub CLI's public client id, scopes `repo read:org gist workflow` | no (until revoked) | none needed |
| `pat` | the person pastes a fine-grained (or classic) token | the token's own expiry (`github-authentication-token-expiration`) | paste a new one (rotate) |
| `app` | GitHub App id + private key + installation id | the installation token: 1 h | the Worker mints a new one before each turn when the cached one has under 10 min left |
| `mac` | the Mac's `gh auth token`, copied once | as the Mac's | `mac` again |
| none | | | |

Default picked: the GitHub CLI's OAuth app (client id `178c6fc778ccc68e1d6a`, public, the one
`gh auth login --web` uses), so the person sees "GitHub CLI" on the device page, exactly what
`gh auth login --web` shows. A cmux OAuth app of our own is a later swap of one constant (it needs
an org admin to register it). `workflow` is in the default scopes because pushes that touch
`.github/workflows` fail without it (a600).

The status, never the token, is what settings and the CLI show:

```json
{"signed_in": true, "kind": "device", "login": "lawrence", "scopes": ["gist","read:org","repo","workflow"],
 "expires_at": null, "set_at": 1761300000000, "checked_at": 1761300000000,
 "pending": {"user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device", "expires_at": 1761300900000}}
```

`pending` is there while a device sign-in waits for the person.

## 3. Cloud Chief (Worker)

`backend/apps/api/src/chief-brain-cc/github.ts`.

- **Store.** One brain object per Chief named `<agent>/github` (the same pattern as `<agent>/tools`
  and `<agent>/sandboxes`), table `cc_github`. The token, the device code and an App's private key
  are sealed with `integrations/crypto.ts` (AES-256-GCM data key wrapped by `INTEGRATIONS_KEK`, AAD
  bound to `chief-github|<agent>|github|<generation>`). A deployment without `INTEGRATIONS_KEK`
  refuses to store one (fails closed) and keeps the old secret.
- **Device flow that survives the turn.** `login` asks `https://github.com/login/device/code`, keeps
  the sealed device code and schedules a `gh-poll` job on the object (Lifecycle jobs survive
  eviction). The job polls `https://github.com/login/oauth/access_token` at GitHub's interval (plus
  5 s on `slow_down`) until the person approves, denies or the code expires (15 min). On success it
  checks the token with `GET https://api.github.com/user`, records login and scopes, and stores it.
  No turn machine has to stay up.
- **The card.** `login` answers with the code and the page. The Chief posts them as one message:
  the code in backticks (one tap copies it on iPhone) and `https://github.com/login/device` on its
  own line, which the app's link preview shows as a card. Tap, paste, approve: the poll does the rest.
- **Every turn.** `turn.ts` asks `<agent>/github` for the turn's token (`ccGithubToken`): the
  Chief's own login, a fresh App installation token when that is the kind, else the old
  `CHIEF_CC_GITHUB_TOKEN` (so nothing breaks before a Chief signs in). The turn runner writes it
  where it always has (`gh` hosts file, git credential helper); no snapshot change.
- **The Chief's verb.** `chief-github` in every turn machine (`.local/bin/chief-github`, shipped like
  `chief-tools`): `status`, `login`, `wait`, `pat [FILE|-]`, `app APP_ID INSTALLATION_ID KEY_FILE`,
  `mac` (runs `mac -- gh auth token` and stores it as kind `mac`), `logout`. It is
  POST 127.0.0.1:4018/vm `{action: github_*}`, which chief-turn-runner already forwards to the
  Worker with the turn's token. `wait` returns the token once signed in and writes it into this
  machine's gh login, so the same turn can push.
- **Onboarding.** The turn's system addendum carries one GitHub line: "signed in as X (kind,
  scopes, expiry)" or "not signed in: run `chief-github login` and post the card". Every Chief sees
  it on its first turn, so sign-in is offered once, by default, with no setting.
- **Settings.** `GET /v1/chiefs/<agent>/github` (the owner): the status. `POST` the owner:
  `{action: "login" | "pat" | "app" | "mac" | "logout"}` with the same fields, so Chief settings
  (Mac and iPhone) can show and change it without a turn.
- **Sign-out and rotate.** `logout` forgets the token, pending flow and App key. The device token is
  not revoked at GitHub (that needs the OAuth app's secret): the answer names
  https://github.com/settings/applications to revoke it. Rotate is `login` (or `pat`) again: the
  new token replaces the old, the generation goes up, the old seal can no longer be opened.

Never: the token in a log, an error, a run step, a reply or the memory; a token file in a repo;
another Chief's object (the object name comes from the running turn's own agent).

## 3a. A fresh code until approved, and a self-wake (user, 2026-10-24)

- A device code lasts about 15 minutes. When one ends unapproved, a new one is made at once
  (the Worker: on the next poll or status read, `renewIfExpired`; the local poller: `next_step`
  Renew), for 3 hours from the first code; then the sign-in ends with a last error.
- The Chief wakes itself when the code ends and posts the new card. The local Chief already
  had a self-wake (`sleep(seconds, note)`, a "[wake] note" turn). The Cloud Chief's Claude Code
  route had none: `chief-wake SECONDS "note" | list | clear` (`chief-brain-cc/wake.ts`) keeps a
  timer on the conversation's brain as a Lifecycle job; at its time "[wake] note" is queued in
  the conversation's inbox and starts a turn. `chief-github login` sets it for the code's end.
- The built-in skill `github-signin` (`Native/OptChat/optchat-chief/skills/github-signin/SKILL.md`,
  shipped to every Chief's shared skills) says how: post the card, set the timer, on wake post
  the new code or say signed in, stop after 3 hours; and the granular options.

## 4. Local Chief (`optchat-chief`)

`Native/OptChat/optchat-chief/src/github.rs`, verb `optchat-chief github status|login|wait|pat|mac|logout [--json]`.

- **Default is the Mac's login.** Nothing to do when `gh auth status` is signed in: status says
  `kind: mac` (who, scopes from `gh api user -i`).
- **Own login.** `login` runs the same device flow (ureq), prints the card and starts a detached
  `optchat-chief github wait` that keeps polling after the turn ends and stores the token. `pat`
  reads a token from a file or stdin.
- **Store.** macOS: the login keychain, generic password service `cmux.chief.github`, account the
  Chief home's id (`paths::home_id`), written through `security -i` on stdin so the token never is
  an argument. Elsewhere (a Linux brain host): `$MUX_HOME/optchat/secrets/github.json`, mode 0600,
  outside any repository. The status (no token) is `$MUX_HOME/optchat/github.json`.
- **Every turn.** The turn's env puts `$MUX_HOME/optchat/bin` first on PATH, where a `gh` shim
  reads the Chief's own token on every call (`optchat-chief github token`) and runs the real `gh`
  with `GH_TOKEN`, or runs it untouched when the Chief has none. Git uses `gh auth git-credential`
  through `GIT_CONFIG_*` env, so both follow a rotate at once with no host restart.
  Default picked: the turn's git helper list for github.com is reset to that one helper, which
  falls back to the Mac's `gh auth git-credential` when the Chief has no token of its own (a
  person whose git uses another helper for github.com would see the Chief use gh's login instead).
- `mac` forgets the Chief's own token (it goes back to the Mac's login); `logout` does the same and
  says where to revoke the token. `token` prints the Chief's own token for the shim, else exits 1.

## 5. Tests (failing first)

- `backend/apps/api/test/chief-github.test.ts`: device flow start, poll pending then success
  through the object's job; status shows login/scopes and never the token; the next turn machine
  gets the Chief's own token instead of the Worker secret; another Chief gets nothing of it; PAT
  validated against `/user` (bad token 400); App installation token minted and re-minted when
  stale; logout; no `INTEGRATIONS_KEK` fails closed.
- `Native/OptChat/optchat-chief/src/github.rs` unit tests: status parsing (scopes header, expiry
  header), the card text, the shim text, file store mode 0600.

## 6. Later

- Swift Chief settings row (Mac `CmuxNextChiefSettings`, iPhone) reading `GET .../github`.
- A cmux OAuth app instead of the GitHub CLI's.
- One login shared by a person's Chiefs (opt-in).
