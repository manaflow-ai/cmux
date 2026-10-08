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

| Source | Path | `source` |
| --- | --- | --- |
| `cmux notify`, `notification.create*`, the V1 line protocol | compat create -> daemon `notify` on the target surface | `cli` |
| OSC 9, OSC 777, OSC 99 from a program in any terminal | the daemon parses every terminal's output (`terminal_metadata.rs`), shown or hidden, attached or not | `terminal` |
| Agent hooks: daemon-side hook fold; `agent_journal_append` with `attention.notification` and `feed.push` attention events via compat | daemon, or compat -> daemon `notify` | `agent` |
| Any other daemon producer | daemon | `daemon` (app settings: agent) |

The daemon owns the source (`notification-source-v1`): `notify` takes `source`, and
the `notification` event, the tab marker and `list-notifications` carry it (the
durable receipt keeps it in `extra.source`; older receipts derive it from their key).
The app reads it (`NotificationCenterService.source`) and never guesses. The app's
Ghostty surfaces leave `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` unhandled, so a shown
terminal does not post twice. OSC 9 follows Ghostty's `osc9.zig` (ConEmu forms such
as `9;4;` progress are not notifications), and the daemon applies Ghostty's limits
per terminal (one per second, the same text once per five seconds). Ghostty's
`desktop-notifications = false` makes the app read terminal notifications at once.

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

## Panel

Show Feed (`cmux feed show`; Cmd-Shift-I, feed.md FD8) toggles a panel at the top right of
the active window: the daemon ledger (`list-notifications`), newest first, each row with
an unread dot, title, time, source workspace and body. A click opens the source tab and
closes the panel; the row menu runs Open, Copy, Mark Read and Dismiss with the row's id;
Up/Down select, Return opens, Delete dismisses, Esc closes. The header has Mark All Read
and Clear All (`clearAllNotifications`, `cmux notification clear-all`), which removes the
ledger rows and markers through v2 `notification.clear`. The daemon clears by terminal, so
Dismiss removes every notification of the row's terminal (a row without a terminal is only
marked read), and nothing can mark a notification unread. The panel reloads while shown
when a notification arrives or is read.

## Verification

`debug.notifications` reports unread tabs with their source, each window's attention
marks, banners asked for, the arrival and dismissal log, and the live preferences;
`{"action": "click", "surface": N}` runs the banner click path. Unit tests:
`NotificationPolicyTests`, `NotificationSettingsTests`, `NotificationsPanelTests`, `CompatJournalNotificationTests`,
`FocusRingNoShiftTests` (attention ring on and off, no frame change).
