# Getting started with cmux-next

What cmux-next is, how to install it, and how to update it.

cmux-next is the rewrite of cmux: a Swift app shell, a Rust core, and web views for chat, diffs, Markdown, and Settings. It runs your terminals, browsers, and coding agents in one window, with Chief on the Home screen.

> cmux-next is in preview. It changes every day. This page is built from the main branch, so it may be ahead of the build you run.

## Paste this into your agent

Copy this into Claude Code, Codex or any coding agent on your Mac. It installs cmux NEXT DEV, signs you in, makes a Cloud machine if you have none, and starts an agent there on the folder you are in. It stops only for what you must do yourself: the browser sign-ins and the card that allows a paid machine.

```text
Set up cmux NEXT on this Mac and get me working in cmux Cloud. If ~/Applications/cmux NEXT DEV.app is missing, download https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh to /tmp, run it with bash, then open the app. Run every cmux command below with the CLI inside that app, "$HOME/Applications/cmux NEXT DEV.app/Contents/Resources/bin/cmux", not another cmux on PATH. Run `cmux setup local` and `cmux setup harness`, and start any sign-in they name. Run `cmux cloud diagnostics`; if I am signed out, run `cmux login` and tell me to finish it in the browser. Run `cmux cloud list-machines`; if I have none, run `cmux setup cloud-machine` and tell me which card to click (it costs money every hour it runs). Then run `cmux cloud start-session --target machine:<id> --agent claude --from-folder .` with that machine's id from the list (or the one you just made), and give me the chat it opens. A chat I already have moves over with `cmux cloud move` and comes back with `cmux cloud bring-back`. If a step fails, show me its error and the command to retry; never guess. Tell me only what I must do myself.
```

Already have cmux? Run cmux setup list in a cmux terminal: it lists every setup task, each with a prompt to paste.

## Install

Two builds exist. Pick one.

- cmux NEXT DEV runs beside classic cmux. It updates after each green push to feat-cmux-next.
- nightly-next takes the place of classic cmux NIGHTLY (same bundle id and socket). It updates through Sparkle about every 30 to 60 minutes. Apple Silicon only.

## Install cmux NEXT DEV

```bash
curl -fsSL -o /tmp/update-dev-daily.sh \
  https://raw.githubusercontent.com/manaflow-ai/cmux/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh
bash /tmp/update-dev-daily.sh
```

The script downloads the build, checks its SHA-256 and bundle id, and installs ~/Applications/cmux NEXT DEV.app. Run the same command to update. If you have the newest build, it says so and does nothing.

## Install nightly-next

```bash
gh release download nightly-next -R manaflow-ai/cmux -p '*macos-arm64*.dmg'
```

Open the DMG and drag the app to Applications. The app updates itself from then on.

## Coming from classic cmux

The first launch brings over the last saved classic session once: workspaces, groups, panes, tabs, and Claude Code or Codex chats. Classic's files are only read. To run it again, use the command palette item Import Workspaces from Classic cmux, or run:

```bash
cmux workspace import-classic
```

## First steps

- Press Cmd+Shift+P for the command palette. Every action in the app is there, with its shortcut.
- Open Home and ask Chief for what you want in plain words.
- Press Cmd+, for Settings. Every setting is also a key in ~/.config/cmux/cmux-next.json.
- Run cmux --help in a cmux terminal. The CLI can do everything the palette can.

## Next

- [Start here](start.md)
- [Home and Chief](home-and-chief.md)
- [Workspaces, panes, tabs, and groups](workspaces.md)
- [Command palette](command-palette.md)
- [CLI and MCP reference](cli.md)
- [How cmux NEXT fits together](architecture.md)
