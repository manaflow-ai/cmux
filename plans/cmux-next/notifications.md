# cmux next: notifications

Status: implemented 2026-09-30 (app side). Code: `CmuxNextApp/Notifications/`
(`NotificationPolicy` pure rules, `NotificationCenterService`, `DesktopNotifier`),
settings in `CmuxNextSettings/Notification*.swift`, the ring in
`CmuxNextLayout/Views/PaneOverlayView.swift`. User request: "ensure cmux notify works (and
colors/thickness/blink can be customized). how it can be dismissed too should be
customizable. default should be keystroke, not just focus."

## Ownership

The cmux-tui daemon owns every notification (the ledger) and each tab's unread marker
(architecture.md section 1). The app never keeps a second unread flag. It reacts to the
daemon's `notification` event and to marker changes, and it clears a marker only by
`ack-tab-notifications` when a rule below says the user read it.

## Producers

| Source | Path | Tag |
| --- | --- | --- |
| `cmux notify`, `notification.create*` | compat create -> daemon `notify` on the target surface | `cli` |
| OSC 9, OSC 777, OSC 99 (Ghostty `desktop_notification`) | `TerminalHostDelegate` -> daemon `notify` on that terminal's tab | `terminal` |
| Agent hooks: `agent_journal_append` with `attention.notification`, `feed.push` attention events | compat -> daemon `notify` on the surface | `agent` |
| Anything else the daemon posts | daemon | `agent` |

The tag is app-side (`notifications.sources.<tag>` settings); the daemon has no source
field. A notification whose event reaches the app before its `notify` reply is treated as
`agent`.

Gap: OSC sequences are parsed by the app's Ghostty surface, so only terminals the app
shows (selected tabs of on-screen panes and the keep-alive band) produce them. A program
in a hidden tab needs the daemon to parse OSC 9/777/99 itself (cmux-tui
`terminal_metadata.rs` keeps only OSC 9;4 progress today).

## Arrival (`NotificationPolicy.decide`)

1. Typed into this pane within `suppressWhileTypingSeconds` (0 = off): read at once,
   nothing shows.
2. Dismissal `focus` and the pane is viewed (focused pane of the key window, cmux
   active): read at once.
3. Muted workspace: no ring, banner or sound; the unread marker stays.
4. Quiet hours: no banner or sound.
5. Banner per `desktop`: `unlessFocused` (default) skips a viewed pane; `always`;
   `whenInactive`; `never`. A source can turn banners off.
6. Sound unless viewed, quiet or muted: `default` rides on the banner (Focus and the
   per-app sound setting apply); a system sound name or a file path plays itself.
7. Dismissal `timeout`: a one-shot `DemandTimer` reads it after `timeoutSeconds`.

## Dismissal (`NotificationPolicy.clears`)

| `notifications.dismissal` | Clears on |
| --- | --- |
| `keystroke` (default) | a key typed into the pane (not an app chord), opening it |
| `focus` | focus (key window, cmux active), click, key, opening it |
| `click` | a mouse-down in the pane, a key, opening it |
| `explicit` | opening it (Jump to Latest Unread, Open Notification, banner click) |
| `timeout` | the deadline, opening it |
| `never` | only the dismiss verbs |

The dismiss verbs always clear: Mark Read (tab), Mark Workspace as Read, Mark All
Notifications as Read, Dismiss Notification, `cmux clear-notifications`,
`notification.clear` / `dismiss` / `mark_read`. Reading a tab withdraws its banners.
Per source: `notifications.sources.<cli|terminal|agent>.dismissal`.

## Visuals

The attention ring is drawn by the layout overlay (no layout shift, above Chromium page
windows): `notifications.attention.{style: none | steady | pulse | blink, color (default:
theme attention yellow), width, blinkCount, duration (pulse seconds), persist,
showOnTab, showOnSidebar}`. The animation restarts for each new notification and ends
(nothing loops while idle); Reduce Motion fades once; animations off shows it steady.
Per-source ring color: `notifications.sources.<source>.color`. The Dock tile shows the
unread count (`notifications.dockBadge`).

## Verbs

Every verb is a registry action (palette, CLI, bindable, menus): Jump to Latest Unread
(Cmd-Shift-U), Toggle Unread, Mark Oldest Unread and Jump Next, Mark All Notifications as
Read, Open / Copy / Dismiss Notification, Mute or Unmute Workspace Notifications (also the
sidebar row menu; `notifications.mutedWorkspaces`), Toggle Notification Banners, and one
action per dismissal mode (`notifications.dismissal.<mode>`). Settings actions apply at
once and write cmux.json. cmux-next has no Settings window yet.

## Verification

`debug.notifications` reports unread tabs with their source, each window's attention
marks, banners asked for, the arrival and dismissal log, and the live preferences;
`{"action": "click", "surface": N}` runs the banner click path. Unit tests:
`NotificationPolicyTests`, `NotificationSettingsTests`, `CompatJournalNotificationTests`,
`FocusRingNoShiftTests` (attention ring on and off, no frame change).
