# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A2 ghostty (branch `feat-cmux-next-ios-a2-ghostty`, local only: GitHub push auth broken):
  `TerminalByteSource` in `Packages/Shared/CmuxTerminalRenderCore` is the seam C1 (`.host`) and C9
  (`.local`) implement; `TerminalSession` + `GhosttyTerminalView` render it (selection, links, scroll,
  Dynamic Type, theme, 120 Hz gestures); `TerminalBenchViewController` replays flood/htop/vim/corpus
  with signposted frame timing. Design: plans/cmux-next/ios-next/a2-ghostty.md. Tagged build `nxa2`
  blocked (no fleet manifest on this host, controller iOS builds need a pushed ref).
