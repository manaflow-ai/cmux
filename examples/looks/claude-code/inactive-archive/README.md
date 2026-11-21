# Archive inactive sessions

This profile moves local chats to the archive after seven days of inactivity. Pinned, running, waiting and nested chats stay in place, as do parents with local children, including archived children. Archiving preserves the transcript and worktree. Restoring a chat starts its inactivity period again.

From the repository root, preview and apply the profile with

```sh
cmux customize use examples/looks/claude-code/inactive-archive/cmux-setup.json
cmux customize apply
```

In Settings → General → Chats, **Archive Inactive Chats** offers Never (the app default), 1, 2, 7, 14 and 30 days. Choose Never to stop future automatic archives.

The reference is the “Archive inactive sessions” row in Claude Code settings. [Source capture](https://github.com/manaflow-ai/cmux-design-references/blob/3d0278494adbf4d67517f168aecf8add198c4bcd/apps/claude/live/settings-linked-sessions-worktrees.png)
