# Open in editor

Open Session Info on a local thread. Under **Open in**, choose an application. The setup passes the thread’s working folder to the installed desktop app as a single path argument, including when its name contains spaces. Finder reveals the folder in its own window. The launcher runs in a new terminal tab in that thread’s workspace.

The source places its application menu in the sidebar thread’s context menu. The customization uses Session Info, which supplies the thread ID. It offers the three listed apps on macOS. An unavailable editor reports its launch error in the launcher tab. Remote checkouts require a local copy before a local desktop editor can open them.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/chatgpt/open-in-editor@feat-cmux-next
```

[Source app screenshot showing the thread menu](https://github.com/manaflow-ai/cmux-design-references/blob/3d0278494adbf4d67517f168aecf8add198c4bcd/apps/codex/live/sidebar-session-context-menu-open-in.png)

To preview from this folder, run `cmux customize use ./preview.json`. Run `cmux customize apply` to keep it or `cmux customize discard` to return to the applied setup.
