# Notification rings: one read rule (2026-10-31)

Lawrence (Chief message 19307): "notifications/notification rings are super buggy i click a terminal that
has notif and it doesnt dismiss it… we need to go through all edge cases and think from first principles
and fix it the proper way".

## Model

- The daemon that holds a tab owns its notifications and their unread marker (`TabModel.notification`).
  The app's only local copy is `readingNotification`, the read it sent and has not yet seen echoed.
- `TabModel.hasUnread` is the single fact. Every indicator derives from it, or from the two other
  owner-held marks that `showsUnread` adds (Mark as Unread, an agent's tab-attention request):
  pane ring (`attentionMarks` / `unreadRing`), tab dot, sidebar row dot and count, the screen bar, Home's
  unread, the Dock badge (`DaemonStore.unreadBadge`). No indicator keeps its own "dismissed" state except
  Dismiss Highlight (hide rings, keep dots), which is an explicit verb.
- A read is one event: `NotificationCenterService.interacted(trigger, tab:)`. The trigger is a click in
  the pane, a key typed into it, an open (banner, Jump to Unread), a look (the pane is the shown focus of
  the key window while cmux is active, `viewedTabs`), or the timeout. `NotificationPolicy` decides from
  `notifications.dismissal` (default `focus`: any of them except timeout). The read goes to the tab's
  own daemon (`ack-tab-notifications`) and shows at once (`expectNotificationRead`).

## Root cause of the report

`interacted` read only tabs on this Mac's daemon. A tab on any other machine (a remote group's SSH
machine, a Cloud machine) only hid an agent's attention ring: its unread notification kept its ring,
tab dot and row dot through every click, key, open and look, and the viewed-tab rule never saw it
(`viewedTabs` filtered to this Mac's store). Only the explicit verbs (Mark Read) reached its daemon.
Fix: reads route to `machines.daemon(forTab:)` (by identity, never by id: a forked machine reuses tab
ids), `viewedTabs` takes each window's own daemon store, and Mark as Unread clears on its own daemon.
A remote daemon without notification-ack-v1 is not sent a read (it would refuse it and the ring would
flash back); the log says so.

A second, smaller split: a click read the window's selection for the pane while the ring is drawn for
the strip's shown tab (`shownTab(of:)`). The click now reads the strip's shown tab first.

The user's own settings were checked: `~/.config/cmux/cmux-next.json` has `notifications.dismissal =
focus` (the Oct 19 `keystroke` value lives only in the classic `cmux.json` and a backup).

## Edge cases (tests)

| Case | Rule | Test |
| --- | --- | --- |
| Click in an unfocused pane | reads that pane only | `UnreadRingClickReadTests.aClickInAPaneReadsThatPaneOnly` |
| Click on the sidebar / titlebar | reads nothing | `aClickOutsideThePanesReadsNothing` |
| Click on an already focused pane | reads it (click trigger) | `UnreadRingDismissTests` |
| Strip press that drags a tab or pane | ring moves with it | `aStripPressThatDragsReadsNothing` |
| Split panes, same notification ids elsewhere | reads only the pane clicked | `aClickInAPaneReadsThatPaneOnly` |
| Background window / app inactive | no look until key and active; a click reads | `viewedTabs`, `AppServicesKeyWindowSourceTests` |
| Hidden tab (not shown in its pane) | no ring; its dot stays until it is shown | `attentionMarks` (shown tab only) |
| Workspace switch | the newly shown focus is a look | `followViewedProgramStatus` |
| Arrives while viewed | read at once under `focus` | `UnreadRingDismissTests` |
| Several notifications on a tab | one read reads the tab; a newer one rings again | `TabModel.hasUnread` |
| Remote (SSH, Cloud) click / key / open | reads on its own daemon, never this Mac's same-id tab | `NotificationRingEdgeCaseTests` |
| Remote look (key window, active) | viewed | `NotificationRingEdgeCaseTests.aViewedRemoteTerminalIsViewed` |
| Remote daemon without ack | nothing sent, logged | `aRemoteDaemonWithoutAckKeepsItsMarkAndSaysWhy` |
| Dismissal policy | same on every machine | `thePolicyIsTheSameOnEveryMachine` |
| Agent chat turn ended | rings on this Mac's chats only | `AgentTurnRingTests` |
| Restore after relaunch | the daemon keeps unread; the first read clears | daemon-owned marker |

Not changed: the Dock badge counts this Mac's daemon and Home only (a shared Cloud machine's unread is
not this person's badge).
