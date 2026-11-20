# Recording cmux's GitHub main path (staging)

Leo (2026-11-19): "the GitHub thing in relation to cloud ... The connect with GitHub or whatever, the various ways that
people will want to use it. Having all those paths be proper."

Leo (2026-11-20): "those steps, we ought to be able to make it more repeatable. a la ci. all these things. they will
be useful for testing out onboarding flows and interaction flows".

The main path: a new user connects GitHub, then opens a PR from a Cloud chat. It runs two ways.

## Flows in CI (Linux, headless)

A flow is one JSON file in `scripts/cmux-next/flows/`: steps, what each reads back, and what each needs. It runs
through `scripts/cmux-next/cloud-flows.ts`, which hosts every step as a `cloud-journey.ts` step (the same
PASS/FAIL/SKIP log, `journey.json`, `summary.md`); the whole Cloud journey is one step kind (`journey`). Browser steps
(GitHub's sign-in, the App install, the repository pick, the PR page) run in headless Chromium (Playwright, the
repository's pin in `scripts/gallery-matrix`), which records `flow.webm`, and each browser step leaves a screenshot.

```sh
gh workflow run cloud-chat-proof.yml -R manaflow-ai/cmux --ref feat-cmux-next -f flow=github-connect
gh workflow run cloud-chat-proof.yml -R manaflow-ai/cmux --ref feat-cmux-next -f flow=cloud-first-chat
```

The artifact is `flow-<name>`. By hand: `bun scripts/cmux-next/cloud-flows.ts --flow FILE --backend staging --out DIR`;
`--check` lists the steps and which can run with the environment as it is.

| Flow | Steps | Needs |
|---|---|---|
| `github-connect.json` | the App's install page signed out; sign in; staging's App config; the App public; the test org's old connection revoked; Connect GitHub (`integration.connect`, as the app); GitHub sign-in (password, TOTP); install on the org, only `pr-target`; the completion link finished (`integration.complete`, as the app); connection active and the repo listed; a Cloud chat on the repo opens a PR (the journey's "GitHub by the agent (live)"); the PR page; cleanup: the App uninstalled | staging account; GitHub test user from "GitHub sign-in" on; Claude login for the chat |
| `cloud-first-chat.json` | cmux's home page; sign in, a new Cloud machine, a chat and its reply (model stub), the machine deleted | staging account |

A step whose secrets are absent is skipped with the reason ("needs GitHub test user: secrets absent
(CMUX_GITHUB_TEST_LOGIN, ...)"), so are the later steps that need them, and the run passes with skips. The App
public check (`warn_without: github-test-user`) runs anyway and, while the test user is absent, records its failure as
a skip that keeps the reason. A new flow is a new file (and an option of the workflow's `flow` input); a new kind of
step is one function in `KINDS` in `cloud-flows.ts`.

No schedule yet: scheduled workflows run only from `main`, whose `cloud-chat-proof-nightly-dispatch.yml` dispatches
this workflow and opens an issue on a red. A nightly flow is one more leg there (a `main` change).

## The app on macOS (`flow: github-pr-app`)

The same path through the real app's UI: a tagged DEV build on a fleet macOS runner (never a person's Mac, never a
running NIGHTLY):

```sh
gh workflow run cloud-chat-proof.yml -R manaflow-ai/cmux --ref feat-cmux-next -f flow=github-pr-app -f build=tagged
```

The run's artifact `github-main-path` holds `github-main-path.mp4` (the main window, 1 frame a second; `frames/` when
the runner has no ffmpeg), `steps.json` and `summary.md` (seconds, clicks and fields typed per step). The summary is
also on the run page.

Pieces:

- `scripts/cmux-next/cloud-github-config-check.py`: job `github-config`, before any Mac is taken.
- `scripts/cmux-next/cloud-github-main-path.py`: the six steps below, in `proof-staging`'s step "GitHub main path
  recording".
- `.github/workflows/cloud-chat-proof.yml`, input `flow: github-pr-app`. Manual dispatch only: no schedule, no gate, no
  required check.

## Before the first run

| What | Where | Read back by |
|---|---|---|
| The staging GitHub App `cmux-cloud-staging` is public | GitHub, the App's settings > Advanced > Make public | `https://api.github.com/apps/cmux-cloud-staging` answers 200 (config check `app_public`) |
| The staging API uses that App | cmux-platform staging environment | `GET /v1/integrations/github/status` says `configured: true`, `app_slug: "cmux-cloud-staging"` (config check `api_status`) |
| A team-owned GitHub test user with TOTP 2FA, owner of org `cmux-cloud-test-org`, which has repo `pr-target` (with a README.md) | GitHub | step 3 |
| `CMUX_GITHUB_TEST_LOGIN`, `CMUX_GITHUB_TEST_PASSWORD`, `CMUX_GITHUB_TEST_TOTP_SEED` (the base32 seed GitHub shows as "setup key") | environment `cmux-next-cloud-journey`, sealed ([ci-sealed-secrets.md](../ci-sealed-secrets.md)) | the script refuses to start without them, naming the missing ones |
| The staging capture account | `cmux-next-cloud-journey` as `CMUX_STAGING_STACK_EMAIL/PASSWORD` (cloud-capture-provision.yml target `journey`) | step 1 |

Today (2026-11-20) `https://api.github.com/apps/cmux-cloud-staging` answers 404, so `github-config` fails with "the
App is private or the slug is wrong". Until the GitHub secrets exist, the Mac job runs a dry run of steps 1-2 and then
fails with "dry run only".

## The click path

Expected times are for the scripted run; a person reading each page takes about twice as long. "Clicks" counts what
a person clicks; the script's own count is in `summary.md`.

| # | Step | Pages and clicks | Read back by | Expected |
|---|---|---|---|---|
| 1 | Sign in | cmux opens signed in to the staging capture account (the run's credentials file; a person: Sign In, email, password, Continue: 1 click, 2 fields) | `auth.status`: `signed_in`, `cloud_environment: staging` | 10-60 s (app launch) |
| 2 | Connect GitHub | Settings > Accounts > GitHub > **Connect GitHub** (or the new-chat folder menu > **Connect to GitHub**): 1 click. The run calls the same action, `cmux accounts github-connect`. GitHub's install page opens in a cmux browser tab | a new browser tab on `github.com` | 2-5 s |
| 3a | GitHub sign-in | `github.com/login`: Username, Password, **Sign in**: 1 click, 2 fields | the URL leaves `/login` | 3-5 s |
| 3b | Two-factor | `github.com/sessions/two-factor/app`: the 6-digit code from the authenticator (the run computes it from the seed; it submits itself): 1 field | the URL leaves `/sessions/two-factor` | 3-5 s |
| 3c | Pick the account | `github.com/apps/cmux-cloud-staging/installations/new`: **cmux-cloud-test-org**: 1 click | URL `/installations/new/permissions?target_id=...` | 2 s |
| 3d | Pick the repository | **Only select repositories**, **Select repositories**, type `pr-target`, pick **cmux-cloud-test-org/pr-target**, **Install**: 4 clicks, 1 field | the tab leaves github.com (the App's setup URL) | 5-10 s |
| 3e | (if asked) Confirm access | `Confirm access` with the password: 1 click, 1 field | the URL leaves the sudo page | 3 s |
| 3f | (if the App asks for user authorization) | **Authorize cmux-cloud-staging**: 1 click | the URL leaves `/login/oauth/authorize` | 3 s |
| 4 | Back in cmux | GitHub redirects to the console, which sends `<scheme>://integration/complete` to the app; Settings > Accounts shows GitHub connected: 0 clicks | `GET /v1/integrations/github/status` (personal team, then the app's team) `connection.status: active` and `/v1/integrations/github/repos` lists `cmux-cloud-test-org/pr-target` | 5-20 s |
| 5 | Cloud chat on the repo | New chat (**⌘N** / New Agent Chat), folder menu > **cmux-cloud-test-org/pr-target** (`github:cmux-cloud-test-org/pr-target`), run place **Cloud**, type the ask, Return: 3 clicks, 1 field. The ask: a branch `cmux-recording-<tag>`, one README.md line, commit, push, open a PR, reply with its URL | each `debug.agent_pane` call (`palette.newAgentChat`, `pick_folder`, `run_mode cloud`, `compose_send`) answers without an error | 5 s to send; the machine start and the agent's work follow in step 6 |
| 6 | Open the PR | the PR link in the chat's reply: 1 click | the chat (`chat_state`) or GitHub's PR list for the branch names `github.com/cmux-cloud-test-org/pr-target/pull/N`; the tab opens it and the page names the branch | 2-10 min (machine start, clone, the agent's turn) |

The first step that does not read back fails the run with `::error::step '<name>' did not read back: <reason>.
Retry: <hint>`, and the summary keeps every step done before it. The run kills every Cloud machine it made and removes
the cached Claude login, pass or fail. `--close-pr` (script only) closes the PR at the end.

## Between runs

The path is "a new user connects", so a rerun needs both sides disconnected:

1. GitHub: `cmux-cloud-test-org` > Settings > GitHub Apps > cmux-cloud-staging > **Uninstall** (as the test user).
2. cmux: Settings > Accounts > GitHub > **Disconnect** for the staging capture account's team.

When the team is still connected, step 2 fails with "the team is already connected" and says both of these.

## When GitHub asks for more

- **Two-factor page with another method** (SMS, security key, GitHub Mobile): the script looks for the authenticator
  field (`#app_totp`, `#otp`) and fails with "no authenticator code field". Make the authenticator app the test user's
  default 2FA method (GitHub > Settings > Password and authentication > Preferred 2FA method), then rerun.
- **"Verify your device" (`/sessions/verified-device`)**: GitHub emails a code when an account without 2FA, or a
  sign-in GitHub finds unusual, comes from a new device. Every fleet runner is a new device. The script fails at once
  with "GitHub asked to verify a new device". With TOTP 2FA on, GitHub asks for the TOTP code instead, so turning 2FA
  on for the test user is the fix; if it still asks, the code goes to the test user's mailbox, which a later version
  can read (not built: the account does not exist yet).
- **Confirm access (sudo)**: answered with the password (step 3e).
- **A wrong code** (the clock window turned): the script waits for a fresh 30 s window when fewer than 5 s are left, so
  a rerun fixes a rare miss.

## Secrets

The script reads every secret from the environment only, passes none to a child process's environment, and prints
none. The TOTP code is masked (`::add-mask::`) before it is typed, and no frame is captured while it is on screen. The
password reaches the page through `cmux browser <tab> fill`, a command-line argument on the runner (never logged).
`steps.json` and `summary.md` are scrubbed of every secret value and of token shapes before they are written.

## Running it by hand

On a fleet Mac with a tagged build (`scripts/reload.sh --tag T --build-only --keep-app ...`), the dry run needs no
GitHub secret and stops after GitHub's page opens:

```sh
python3 -I scripts/cmux-next/cloud-github-main-path.py --app "$APP" --tag T --credentials-file FILE --out DIR --dry-run
python3 -I scripts/cmux-next/cloud-github-config-check.py --public-only
```
