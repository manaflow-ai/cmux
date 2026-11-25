# Claude Code notification levels

Show banners for permission requests, badges for questions, and turn task-complete alerts off.

The settings and allowed levels come from Claude Code 6.28899.6, `app.asar`,
`index.chunk-CknhaMei.js`, bytes 294195–294880. The profile selects the levels in the last column.

| Original event | cmux setting | Choices | Profile |
| --- | --- | --- | --- |
| `permission_request_notifications` | `notifications.delivery.permissionRequest` | `off`, `badge`, `banner` | `banner` |
| `question_notifications` | `notifications.delivery.question` | `off`, `badge`, `banner` | `badge` |
| `task_complete_notifications` | `notifications.delivery.taskComplete` | `off`, `banner` | `off` |

All three cmux settings default to `banner` before applying this profile.

From the checkout, preview and keep the profile with these commands.

```sh
cmux customize use ./examples/looks/claude-code/notification-levels/cmux-setup.json
cmux customize apply
```

In Settings → Notifications → Delivery by Event, choose Off, Badge, or Banner for
permission requests and questions. Task Complete offers Off or Banner.
Banner delivery still respects quiet hours, muted workspaces, and focus rules.
