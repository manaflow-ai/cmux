# Customization showcase: whole-window setups

Leo, 2026-11-16: "but you guys probably need to be doing a hell of a lot more meaningful
customizations than this? we know you can change colours. im saying the big stuff."

Each setup here changes the shape of cmux, not its colors: where the sidebar sits and what it
lists, what a New Tab is, how panes tile, how a chat reads. Each one is a single profile file:
layout settings plus views of its own (a `local/customize` app), previewed live on your window
before you keep it.

| Setup | What changes | Its own views |
| --- | --- | --- |
| [`cockpit`](cockpit.json) | Every New Tab is mission control. The sidebar gets the session tree, Priority View and expanded rows. A docked Chief goes to the right, and Session Info pushes the chat aside. | A New Tab page (counts of chats that need you, chats at work, workspaces and PRs; launchers; Needs You, your PRs, your workspaces) and a Needs You section on top of the sidebar |
| [`tiling`](tiling.json) | A scrolling tiling window manager. New terminals and browsers split into panes of their own, side-by-side panes scroll sideways instead of shrinking, and columns keep no extra rows. New columns are half the window wide. Focus follows the mouse, links open in a new column, and panes sit on cards in the Blocks window style. The sidebar is a rail: point at it to see the numbered rows and the status bar. | Numbered workspace rows (1 to 9, like a tiling desktop's tags) and a status bar at the bottom of the sidebar: panes, tabs, agents at work, the time |
| [`right-handed`](right-handed.json) | The window, mirrored. The sidebar is on the right with the window buttons over the tab bar, and the spaces sit on top. The prompt rail and Session Info chip move to the chat's right, and a docked Chief goes to the left. | A shorter, right-aligned hover card: what waits on you, the agent, the branch, the PR |
| [`focus`](focus.json) | One thing at a time. The chat reads as messages, with no minimap, running tray or Session Info chip. The sidebar is a rail whose bands hide until you point at it. There are no hover cards, pane borders or column rows, and nothing moves (`ui.calm: still`). | A New Tab page with one question, what you are working on, and a timed session with buttons for a chat or a terminal. It remembers the task and today's count once `storage:local` is on |
| [`ide`](ide.json) | An editor's shape. Tabs sit vertically beside the panes, every new terminal is a split, and links and files open beside the code. Projects are grouped by folder and the window is compact. Chats open their tool output and show the full minimap. | An Explorer section: the workspace you are in, each pane as a group with its tabs, and New Terminal, Browser, Split Right and Split Down |

## Try one

```sh
cmux customize use examples/customize-showcase/tiling.json
```

The window changes at once; nothing is kept yet. Then:

```sh
cmux customize apply      # keep it
cmux customize discard    # put your setup back
```

After an apply, `cmux customize rollback` goes back one generation. A setup's views need the
scopes their manifest lists. The reads are granted at install. A click that needs more, such as
focusing a workspace or running an action, says which scope to turn on in Settings > Apps.

One setup at a time: each one brings its own `local/customize` app, so using a second one
replaces the first one's views. Your own `customize/` folder is replaced too while the preview
runs, and `discard` brings it back.

## Change one

Each folder holds the source: `profile.json` (the name, the description and the settings) and
the files the setup writes under `~/.config/cmux` (`customize/cmux-app.json`,
`customize/main.js`). Edit them, then rebuild the bundles:

```sh
python3 examples/customize-showcase/bundle.py
```

`cargo test -p cmux-customize --test showcase` checks that every bundle matches its folder and
previews on a fresh machine with nothing to fix. The views use only the kit in
[local-app-views.md](../../skills/cmux-customization/references/local-app-views.md#matching-the-app),
so they follow every theme.
