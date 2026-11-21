# Claude Code notification levels

Keep finished turns in the app while requests for input and errors use your current notification settings. The profile follows the default event selection for Claude Code projects. [Claude Code project notifications](https://code.claude.com/docs/en/claude-projects#see-what-needs-you-in-overview)

From the checkout, preview and keep the profile with these commands.

```sh
cmux customize use ./examples/looks/claude-code/notification-levels/cmux-setup.json
cmux customize apply
```

In Settings → Notifications → Delivery by Event, each event can follow your current settings, show an otherwise eligible banner without sound, or stay in the app. Quiet hours, muted workspaces, and focus rules still apply. In-app notifications keep their usual unread and dismissal behavior.
