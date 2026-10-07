# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A1 shell (branch feat-cmux-next-ios-a1-shell): CmuxiOSFeatureKit seams + mocks (FeedSource, WorkspaceSource, TaskComposerSink, HostsStore, DeviceRegistry, FileTransfer, BrowserStreamSource), CmuxiOSShell root tabs (Home, Feed, Workspaces, Compose, Hosts, Settings; iPad sidebar on iOS 18), flags, DEV mock/real switch, placeholder screens en+ja. Lanes plug in via `AppContainer.realFactories` and `ShellContent.controller(for:)`. Parity gaps: a1-shell.md 1.20. Tagged build nxa1 blocked (fleet, disk).
- 2026-10-06 C10 onboarding (branch feat-cmux-next-ios-c10-onboarding, design `ios-next/c10-onboarding.md`): CmuxiOSOnboardingCore (flow state machine, persisted resume, launch policy with automation bypass, pairing phase projection, SSH entry, hint timer on an injected clock; 22 Swift Testing tests pass on macOS) + CmuxiOSOnboarding (Core Animation welcome vignette, interactive approve/reply pages, embedded kept sign-in, notification/local network/camera priming, Mac install, same-account discovery + QR over `DeviceRegistry`, optional SSH host, celebration; en+ja). Root flow runs it across sign-in; Settings > Replay Welcome Tour; push permission waits for the primer. Pairing, QR scanner and SSH save run on mocks until B6/C9. CmuxiOSApp compiles for the iOS 17 simulator. Tagged build nxc10 blocked: dev backend VM SSH timeout, then no fleet manifest and 17 GiB free (local floor 40).
