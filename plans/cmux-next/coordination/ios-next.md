# Lane: ios-next

Plan and graph: plans/cmux-next/ios-next/PLAN.md.

## Active streams
- 2026-10-06 wave 0: A0 rpc, A1 shell, A2 ghostty, A3 link.

## Landed
- 2026-10-06 A3 link (branch feat-cmux-next-ios-a3-link): `Packages/Shared/CmuxLink` (CmuxLink seam, LinkSession, LinkHost, PathSelector, LinkFrame codec with golden vectors) and `CmuxLinkTesting` (loopback and lossy/roam simulator carriers, ManualClock, LinkConformanceSuite for B2/B3/B4 and the relay). Design: plans/cmux-next/ios-next/a3-link.md; Rust boundary for B5 in its section 10.
