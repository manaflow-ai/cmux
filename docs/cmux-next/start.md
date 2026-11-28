# Start here

From nothing to a working agent on cmux Cloud, five ways: in the app, from the CLI, by pointing an agent at one URL, through Chief, and from your phone.

<!-- Generated from web/data/next-docs/pages.ts by `bun web/scripts/export-next-start.ts`. Edit pages.ts, not this file. -->

> If you are an agent and a person pointed you at this page: do the steps under "If you are an agent" below, in order, on their Mac.

This page takes you from nothing to an agent that works for you on a cmux Cloud machine. Pick the way in that fits you. Each one ends at the same place: a chat that replies, on a machine that keeps going after you close the lid.

> cmux-next is in preview. The app needs a Mac today. A Cloud machine costs money while it runs and stops costing when you pause or delete it; Plans and credits says how billing works.

## Choose your way in

- New to cmux or agents: use In the app. Home and Chief explain each step and show the one card you need when something is missing.
- Comfortable in a terminal: use From the CLI. The commands are short, repeatable, and print a session_id you can use from another terminal.
- Have an agent working for you already: use Point an agent at this page. The Markdown copy gives it the same sequence without requiring a person to translate the UI.
- Starting away from your desk: set up the Mac first, then use From your phone. Pairing is the only phone setup; the working check is a message sent from the iPhone and answered in the same chat.
- Building a team or an integration: start with Cloud machines, Machines, and MCP. They explain machine state, repeatable repository setup, and the protocol surfaces behind the app.

## Know when you are ready

You are set up when the same Cloud chat has a session_id, its first reply, and a second reply after you send more work. Save that session_id; it is the handle you use to return from the CLI, Chief, or your phone.

## Point an agent at this page

The shortest way in. Paste this one line into Claude Code, Codex or any coding agent on your Mac, opened on the folder you want to work on. The link is this page as plain Markdown, in the cmux repository, so any agent can read it without signing in. The agent reads it and does the rest. It stops only for what you must do yourself: the browser sign-ins and the card that allows a paid machine.

```text
Set me up with cmux Cloud: https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/docs/cmux-next/start.md (follow its "If you are an agent" steps on this Mac, and tell me only what I must do myself)
```

## If you are an agent

A person asked you to set up cmux and cmux Cloud for them. Do these steps in order, on their Mac, in the folder they started you in.

1. Install. If ~/Applications/cmux NEXT DEV.app is missing, run `curl -fsSL -o /tmp/update-dev-daily.sh https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh` and then `bash /tmp/update-dev-daily.sh`. Run `open "$HOME/Applications/cmux NEXT DEV.app"`. Run every cmux command below with the CLI inside that app, "$HOME/Applications/cmux NEXT DEV.app/Contents/Resources/bin/cmux", not another cmux on PATH. Repeat `cmux whoami` every few seconds, for up to a minute, until it answers: then the app is up.
2. Set up this Mac. Run `cmux setup local` and `cmux setup harness`. Each prints what it found. If one names a sign-in only the person can do, tell them which and go on.
3. Sign in. If `cmux whoami` shows no account, run `cmux login` and tell the person to finish it in the browser. Repeat `cmux whoami` every 10 seconds, for up to 5 minutes, until it names their account.
4. Start an agent on a Cloud machine. Tell the person first that a Cloud machine costs money while it runs. Then run `cmux chat --on vm --harness claude --prompt 'Say hello in one sentence.' --wait --json` in the folder they started you in. It prepares a machine, waits for the first reply and prints it with the chat's session_id.
5. If the start is refused, it names what is missing: a Cloud plan, a model connection or GitHub. Tell the person the one card or Settings page it names, wait for them to say it is done, and run the same command again. `cmux cloud diagnostics` says what is wrong when the refusal does not.
6. Show it works. Give the person the reply text and the session_id, and tell them how many seconds each step took. More work goes to the same chat with `cmux chat send SESSION_ID '...' --wait`.
7. Say how to stop paying. `cmux cloud list-machines` lists their machines; `cmux vm pause NAME` pauses one and `cmux vm rm NAME --yes` deletes it.

Rules for the agent: never type a password or a payment detail; never buy a plan or click a card that costs money for the person; if a step fails, show its error and the command to retry, and do not guess. `cmux setup list` names every other setup task, each with its own prompt.

## In the app

1. Install cmux NEXT and open it (Getting started has the two builds).
2. Sign in to cmux in Settings > Accounts. The sign-in finishes in your browser.
3. Choose File > New Cloud Chat, or run New Cloud Chat from the command palette (Cmd+Shift+P).
4. Type what you want done and press Return. cmux prepares a machine, shows its progress in the chat, and the agent replies there.

If cmux needs something first (a Cloud plan, a model connection, GitHub), the chat shows a card that names the one thing to do. Do it and the same chat goes on.

## From the CLI

In any terminal inside cmux (install cmux NEXT first: Getting started has the two builds). The first command finishes in your browser; run the second until it prints your account. The third starts a chat on a Cloud machine, waits for its first reply and prints it with the chat's session_id.

```bash
cmux login
cmux whoami
cmux chat --on vm --harness claude --prompt 'Say hello in one sentence.' --wait --json
```

If the start is refused, it names the one thing that is missing: a Cloud plan, a model connection or GitHub. Do that one thing and run the same command again. When the refusal does not say what is wrong, this does:

```bash
cmux cloud diagnostics
```

Send it more work, list your machines, and stop one:

```bash
cmux chat send SESSION_ID 'Now run the tests.' --wait
cmux cloud list-machines
cmux vm pause NAME
```

## Through Chief

Open Home and paste this to Chief, with HARNESS changed to claude or codex. Chief runs each step, shows you the reply, and asks before anything that costs money.

```text
Start me a chat on cmux Cloud and show me it works: run `cmux whoami`; if I am signed out, run `cmux login` and wait while I finish it in the browser. Then run `cmux chat --on vm --harness HARNESS --prompt 'Say hello in one sentence.' --wait --json` (HARNESS is claude or codex) and show me its reply, then `cmux chat send SESSION_ID 'Say it once more, shorter.' --wait` with the answer's session_id. If a start is refused for a model connection, run `cmux cloud connections`: when none of them serves Cloud, open `cmux://settings/cloud/claude` (Settings > Cloud; `/cloud/chatgpt` or `/cloud/api-key` for those), or use `cmux cloud connect chatgpt` (I open its link in a browser on this Mac); not `cmux accounts`, which is CodeRouter. Then start again. If it is refused for a Cloud plan or GitHub, tell me the one card or Settings page that fixes it and run it again once I have. Tell me how long each step took, and that `cmux vm pause NAME` or `cmux vm rm NAME --yes` stops the machine.
```

## From your phone

Open the chats on your Mac from an iPhone, Cloud chats included, and keep them going: read the history, send a message, stop a turn. The phone reaches them through your Mac, so the Mac stays on and signed in. The iPhone app is in beta. Paste this into Chief or any agent chat in cmux on your Mac.

```text
Set up the cmux iPhone app with this Mac and get me to a working agent on it: run `cmux settings get mobile.allowIPhoneConnections` and `cmux cloud open-mobile-pairing` (it opens Settings > Accounts > iPhone). iPhone connections are on by default; if they are off, tell me to turn them on there (only I can). Then tell me to install cmux on my iPhone and sign in there with the same cmux account: this Mac shows up on the phone by itself, and I allow the phone on this Mac when it asks. When I say the phone is paired, run `cmux chat --on vm --harness claude --prompt 'Say hello in one sentence.' --wait --json`, show me its reply, and tell me to open that chat on the phone and send it one message. Then read the chat and show me the agent's answer to what I sent.
```

The phone is working when the message you sent from it gets an answer in that chat.

## Keep going

- Move a chat you already have to Cloud with cmux cloud move, and bring it back with cmux cloud bring-back.
- Run cmux setup list for every setup task: trust a folder, add another machine, connect GitHub, turn on Computer Use.
- Stuck or slow? Run cmux cloud diagnostics, then cmux acp machine status. Read the named machine and next action before retrying.
- Want to see a running service? Open its port in a browser with cmux cloud open-browser, or use the phone for the chat while the Mac keeps the connection.
