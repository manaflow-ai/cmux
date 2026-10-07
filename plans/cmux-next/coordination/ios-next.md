# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A1 shell (branch feat-cmux-next-ios-a1-shell): CmuxiOSFeatureKit seams + mocks (FeedSource, WorkspaceSource, TaskComposerSink, HostsStore, DeviceRegistry, FileTransfer, BrowserStreamSource), CmuxiOSShell root tabs (Home, Feed, Workspaces, Compose, Hosts, Settings; iPad sidebar on iOS 18), flags, DEV mock/real switch, placeholder screens en+ja. Lanes plug in via `AppContainer.realFactories` and `ShellContent.controller(for:)`. Parity gaps: a1-shell.md 1.20. Tagged build nxa1 blocked (fleet, disk).
- 2026-10-06 A2 ghostty (branch `feat-cmux-next-ios-a2-ghostty`, local only: GitHub push auth broken):
  `TerminalByteSource` in `Packages/Shared/CmuxTerminalRenderCore` is the seam C1 (`.host`) and C9
  (`.local`) implement; `TerminalSession` + `GhosttyTerminalView` render it (selection, links, scroll,
  Dynamic Type, theme, 120 Hz gestures); `TerminalBenchViewController` replays flood/htop/vim/corpus
  with signposted frame timing. Design: plans/cmux-next/ios-next/a2-ghostty.md. Tagged build `nxa2`
  blocked (no fleet manifest on this host, controller iOS builds need a pushed ref).
- 2026-10-06 A0 rpc (branch feat-cmux-next-ios-a0-rpc): `cmux.mobile/1` wire. Design ios-next/a0-rpc.md; catalog, JSON Schemas and fixtures in schemas/mobile-rpc/; Swift `Packages/Shared/CmuxMobileWire` (module CmuxMobileWire); TS `@cmux/protocol` (`mobile-wire.ts`, `mobile-wire-binary.ts`, `mobile-wire-catalog.ts`). Control frames are cmux.wire/1 plus `hello`/`hello.ok`, `read`/`read.result`, `signal`, `channel.*`; stream records reuse the u32 channel/u64 seq/u8 flags header. B1 must add `hello`, `read`, `signal` and HostDO op forwarding to the DO gateway.
