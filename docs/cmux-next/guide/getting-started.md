# Getting started with cmux-next

What cmux-next is, how to install it, and how to update it.

cmux-next is the rewrite of cmux: a Swift app shell, a Rust core, and web views for chat, diffs, Markdown, and Settings. It runs your terminals, browsers, and coding agents in one window, with Chief on the Home screen.

> cmux-next is in preview. It changes every day. This page is built from the main branch, so it may be ahead of the build you run.

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

- [Home and Chief](home-and-chief.md)
- [Workspaces, panes, tabs, and groups](workspaces.md)
- [Command palette](command-palette.md)
- [CLI and MCP reference](cli.md)
- [How cmux NEXT fits together](architecture.md)
