# Zero to going

> Leo, 2026-11-22: "i want all these to just be super accessible and usable, from human to agent to what we expect on our end."

One table: for each way the [Start page](https://cmux.com/docs/nightly/next/start) offers to get from nothing to a
working agent on cmux Cloud, how many steps it takes (commands, waits, and things only the person can do) and how
long the Cloud part takes on staging. One harness makes it, so the worst level can be fixed and measured again with
the same tool.

- Script: `scripts/cmux-next/zero-to-going.ts`
- Workflow: `.github/workflows/zero-to-going.yml` (`Zero to going (staging)`), on a pull request that changes either
  file and by hand (workflow_dispatch). It writes the table to the job summary and uploads `zero-to-going.json` and
  `summary.md` as the `zero-to-going` artifact. It reports numbers; it never fails a pull request on a threshold.

## Run it

```bash
bun scripts/cmux-next/zero-to-going.ts --documented --out /tmp/zg          # counted steps only, no network
bun scripts/cmux-next/zero-to-going.ts --backend staging --out /tmp/zg     # plus the Cloud part timed
gh workflow run zero-to-going.yml --ref feat-cmux-next                     # the same, in CI on staging
```

The timed run needs the agent test account (`CMUX_DOGFOOD_STACK_EMAIL`, `CMUX_DOGFOOD_STACK_PASSWORD`, or
`--credentials FILE`). Without it the script prints the counted table and exits 0. It makes one machine, named
`zero to going auto TAG`, and deletes it at the end; `--cleanup-tag TAG` deletes what a killed run left.

## What the columns mean

The step kinds are the ones `vm-hassle.ts` counts:

- **command**: one command typed, by the person or by the agent or Chief working for them.
- **wait**: a command repeated until it says so (`cmux whoami` until it names the account), or waiting for the
  machine and its reply.
- **physical**: only the person can do it, outside the terminal: a browser sign-in, a click in the app, a card,
  the phone.

**steps** counts every step on the page, the conditional ones included (the worst case a person meets).
**by the person** counts the steps the person does or types. **conditional** counts the steps that apply only
sometimes (not installed, signed out, refused). **fewest steps** is the best case: the app installed and running,
already signed in, nothing refused. **Cloud part, s** is the sum of the level's timed steps on staging, without
the person's think time.

## What is measured, counted, or not measurable here

The agent, CLI and Chief levels all get their first reply from
`cmux chat --on vm --harness claude --prompt '...' --wait --json`. That command talks to a running cmux app through
its socket, so CI (no Mac, no app) cannot run it. The timed run walks the Cloud routes behind it instead, as the
agent test account, with the helpers in `cloud-journey.ts` that `vm-hassle.ts` also uses:

| timed route | stands in for | what it times |
|---|---|---|
| `signIn` | `cmux login` once the browser part is done | password sign-in and `user.ensure` (the browser itself is the person's, not timed) |
| `chat` | `cmux chat --on vm --harness claude ... --wait` | create a machine, wait until it runs and takes an exec, start a Claude agent session there, send the prompt, wait for the first reply |
| `send` | Chief's `cmux chat send SESSION_ID '...' --wait` | one more turn on the same session |

| level | measured on staging | counted from the page only | not measurable here, and why |
|---|---|---|---|
| Point an agent at one URL | `signIn` + `chat` | all 15 steps | the install script, opening the app, `cmux setup local`/`harness`, the `cmux whoami` waits and the browser sign-in need a Mac and a person |
| In the app | nothing | all 8 steps | every step is a click in the Mac app or a browser; no headless route drives File > New Cloud Chat. The Cloud part is likely close to `chat` but the page does not say which route the app takes, so no number is borrowed |
| From the CLI | `signIn` + `chat` | all 6 steps | the install and app launch, the browser sign-in; `cmux whoami` needs the app's socket |
| Through Chief | `signIn` + `chat` + `send` | all 15 steps | Chief runs inside the Mac app; the paste, the yes to a cost, the connect link and the browser need a person |
| From your phone | nothing | all 9 steps | the iPhone app, its beta install and pairing need a Mac and an iPhone |

The `chat` route creates a fresh machine with `cloud.machine.create`. The CLI may get a warm spare instead, so the
real command can be faster than this number; the CLI's own path is timed only once a runner has the app.

## First numbers

Counted from the Start page (draft, manaflow-ai/cmux#51171, unchanged through its head f25c96a) on 2026-11-22:

| level | steps | command | wait | physical | by the person | conditional | fewest steps |
|---|---:|---:|---:|---:|---:|---:|---:|
| Point an agent at one URL | 15 | 9 | 2 | 4 | 4 | 9 | 6 |
| In the app | 8 | 0 | 1 | 7 | 8 | 3 | 5 |
| From the CLI | 6 | 3 | 0 | 3 | 6 | 2 | 4 |
| Through Chief | 15 | 7 | 1 | 7 | 7 | 11 | 4 |
| From your phone | 9 | 2 | 0 | 7 | 7 | 3 | 6 |

Cloud part on staging, the newcomer path (no Claude login), three runs on this pull request (2026-11-23):

| timed route | run 45087298817 | run 45096444143 | run 45098441768 |
|---|---:|---:|---:|
| `signIn` | 1.7 s | 1.3 s | 0.9 s |
| `chat`: machine running, from the create | 9.5 s | 5.0 s | 4.0 s |
| `chat`: first exec, from the create | 15.4 s | 6.0 s | 5.4 s |
| `chat`: Claude agent session started | 2.9 s more | 4.3 s | 3.8 s |
| `chat`: first reply | refused | refused | refused |
| `send` | not run | not run | not run |

The refusal each time: "Claude is not signed in here. This Cloud machine's Claude has no model route". So the
newcomer has no first-reply number yet: a fresh account's machine has no Claude login and no model route. A real
person gets the same refusal: it is the "refused for a model connection" branch every level counts.

The Claude login path, run 45098441768: sign-in 1.2 s, then the agent session started with the login and took the
prompt, and Claude answered "You've hit your weekly limit" (the login this repository's runs share is used up until
2026-11-25 03:00 UTC). So this path has no first-reply time and no token count yet either: the run read the
machine's transcripts and found no model message with usage. Run 45096444143 stopped earlier on this path, asking
for a session before the machine's agent daemon listened; the script now asks again until it does.

The workflow measures two paths, each on its own machine with its own rows:

| path | `--model` | what it is |
|---|---|---|
| newcomer | `none` (the default) | a fresh account, no Claude login on the machine. Today the row is the refusal's text. |
| the person's Claude login | `real` | the person has signed in to Claude on the machine: the login goes to the agent as its launch credential, as the Cloud journey's production run does. |

After the refusal the newcomer has 3 more steps before a reply, 1 of them the person's (the agent level's own
refused-start steps): do the one card or Settings page the refusal names, run `cmux cloud diagnostics` when the
refusal does not say what is wrong, run the same chat command again. The Claude login run also writes the model
tokens its two turns used, by model, read from Claude Code's transcripts on the machine: tokens, not money. The
script also takes `--model stub` by hand (the Cloud part without model latency); its rows say "stubbed model" and
are never the headline.

The workflow can be started by hand (workflow_dispatch) only once this file is on `feat-cmux-next`; on its pull
request it runs on each change to the script or the workflow. It reads the agent test account from the
`cmux-next-vm-image-dev` environment, the pair `cloud-journey-pr.yml` reads on pull requests.

## What counting the page found

- **From your phone** never reaches a working agent: it pairs the iPhone with the Mac and stops. No step starts or
  opens a Cloud chat from the phone, and the page does not say where the beta invite comes from.
- **From the CLI** and **Through Chief** start "in any terminal inside cmux" and "open Home", but the app install
  is only a pointer to Getting started; the agent level is the only one that installs it.
- **From the CLI** says nothing about a refused start (a Cloud plan, a model connection, GitHub); the agent and
  Chief levels do. It also lists `cmux whoami` without saying to wait for the browser sign-in to finish.
- **Through Chief** has the most conditional steps (11 of 15): the model-connection branch alone adds three, with
  two different link flows for Claude and Codex.

## Keep it true

The steps live in `LEVELS` in the script, written by hand from the Start page
(`web/data/next-docs/pages.ts`, slug `start`). Change both together.
