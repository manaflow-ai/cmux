# Session Recents

Install this setup to add Recents to the sidebar. Click a session to open it. The Sessions menu switches between a nested list, projects and agents. Right-click a row to pin it, then drag it within Pinned to change its position.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/session-recents@feat-cmux-next
cmux setup remove manaflow-ai/session-recents
```

The Archive menu can archive all unpinned recent sessions, archive sessions whose last activity was more than seven days ago, or show archived sessions. Each row also offers Archive or Restore. On a parent, choose “with nested sessions” to include its descendants on the same machine. Archiving keeps the transcript. Removing the setup restores the previous customization and preserves session archive marks.

The setup uses `cmux.section/1`, `chat.list` with archived sessions included, `chat.pin`, `chat.archive`, `agent.openSessionTab`, and the reorderable list. It stores the pin order in the customize app’s local storage. Allow chat writes, local storage and Run actions in Settings → Apps when prompted.
