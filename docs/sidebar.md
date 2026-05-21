# Sidebar

cmux has two workspace list styles:

- `recents`: compact Codex/Claude-style rows sorted by recent activity.
- `classic`: full cmux rows with descriptions, PRs, logs, ports, progress, and custom metadata.

Set the style in `~/.config/cmux/cmux.json`:

```json
{
  "sidebar": {
    "style": "recents"
  }
}
```

The recents glyph mapping is:

| Glyph | Meaning | cmux state |
| --- | --- | --- |
| Filled yellow dot | Active or needs attention | unread notification, running command, progress, agent status, remote connecting/reconnecting/error |
| Green branch | Branch or review state | pull request metadata or git branch metadata |
| Purple file | File or doc target | markdown or file preview surface |
| Open circle | Idle | no attention, branch, review, file, or doc state |

The Settings window exposes the same value under Sidebar > Sidebar Style.
