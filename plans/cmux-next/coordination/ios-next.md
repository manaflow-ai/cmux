# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A1 shell (branch feat-cmux-next-ios-a1-shell): CmuxiOSFeatureKit seams + mocks (FeedSource, WorkspaceSource, TaskComposerSink, HostsStore, DeviceRegistry, FileTransfer, BrowserStreamSource), CmuxiOSShell root tabs (Home, Feed, Workspaces, Compose, Hosts, Settings; iPad sidebar on iOS 18), flags, DEV mock/real switch, placeholder screens en+ja. Lanes plug in via `AppContainer.realFactories` and `ShellContent.controller(for:)`. Parity gaps: a1-shell.md 1.20. Tagged build nxa1 blocked (fleet, disk).
- 2026-10-06 C16 platform (branch feat-cmux-next-ios-c16-platform): CmuxiOSPlatform (ShellRoute router with deferred links and the C7 `cmux.route` notification hook, ToastCenter, RemoteConfigSource + flag merge into FeatureFlagStore, DiagnosticLogSink, What's New policy, MacCompatibilityPolicy + MacCapabilitiesSource, demo mode, KeepAwakeControl, BillingStore, mocks), CmuxiOSPlatformUI (toast window, Diagnostics, What's New, Mac update gate, keep-awake and plans stubs), CmuxiOSCrashReporting (Sentry under shared consent, scrubbed, replay off). Slots in AppContainer: remoteConfigFactory (B1), macCapabilitiesFactory and keepAwakeFactory (B5), billingFactory. Deferred sign-in: proposal only (c16-platform.md 9, needs C9). Tagged build nxc16 blocked (dev backend VM, fleet, disk).
