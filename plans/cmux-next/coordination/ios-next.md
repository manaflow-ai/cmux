# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A1 shell (branch feat-cmux-next-ios-a1-shell): CmuxiOSFeatureKit seams + mocks (FeedSource, WorkspaceSource, TaskComposerSink, HostsStore, DeviceRegistry, FileTransfer, BrowserStreamSource), CmuxiOSShell root tabs (Home, Feed, Workspaces, Compose, Hosts, Settings; iPad sidebar on iOS 18), flags, DEV mock/real switch, placeholder screens en+ja. Lanes plug in via `AppContainer.realFactories` and `ShellContent.controller(for:)`. Parity gaps: a1-shell.md 1.20. Tagged build nxa1 blocked (fleet, disk).
