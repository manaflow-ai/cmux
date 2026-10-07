# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A1 shell (branch feat-cmux-next-ios-a1-shell): CmuxiOSFeatureKit seams + mocks (FeedSource, WorkspaceSource, TaskComposerSink, HostsStore, DeviceRegistry, FileTransfer, BrowserStreamSource), CmuxiOSShell root tabs (Home, Feed, Workspaces, Compose, Hosts, Settings; iPad sidebar on iOS 18), flags, DEV mock/real switch, placeholder screens en+ja. Lanes plug in via `AppContainer.realFactories` and `ShellContent.controller(for:)`. Parity gaps: a1-shell.md 1.20. Tagged build nxa1 blocked (fleet, disk).
- 2026-10-06 C6 feed (branch feat-cmux-next-ios-c6-feed, design ios-next/c6-feed.md): `FeedSource` seam now follows FeedDO's item model (permission with scopes, question, choice, plan approval, confirm, done, read-only Mac-only kinds) with `perform(FeedIntent, key:)`; `CmuxiOSFeedModel` (FeedStore: mirror + intent log, filters, grouping), `CmuxiOSFeedCloud` (CloudFeedSource on `/v1/wire/feed`, gap -> snapshot.request, decided-key settle and same-key resend on reconnect), `CmuxiOSFeed` (UIKit Feed tab) replacing the shell placeholder; registered in `AppContainer.realFactories.feed`. CmuxiOSApp compiles for the iOS simulator; tagged build nxc6 blocked (dev backend VM SSH timeout, no fleet manifest, 18 GiB free < 40).
