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
- 2026-10-06 C9 ssh (branch `feat-cmux-next-ios-c9-ssh`, local only: GitHub push auth broken):
  `CmuxiOSSSHCore` (`LocalHostsStore` real `HostsStore` with `HostsSyncChannel` seam for B1, ssh_config
  import, known_hosts + TOFU verifier, `SSHTerminalByteSource` `.local` with PTY/window-change/backoff
  reconnect/kernel keepalive) and `CmuxiOSSSH` (Hosts tab, editor, Ed25519/Secure Enclave keys, trust
  alerts, SSH terminal screen). Shell change: `ShellContent(screens:)` injects feature tab roots; FeatureKit
  gains `HostID.added(by:)`; CmuxMobileSSH gains `generateEd25519Key` and `connect(keepalive:)`. 34 tests
  green on macOS; simulator compile green. Design: plans/cmux-next/ios-next/c9-ssh.md. Tagged build `nxc9`
  blocked (dev backend VM unreachable, no fleet manifest, 20 GiB free).
