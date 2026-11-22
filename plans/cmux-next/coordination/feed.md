# Lane: feed

## Active streams
- Feed (notifications and agent requests as one system, plans/cmux-next/feed.md: `feed.*` ops, `FeedDO`, the local feed server `cmux-feed serve`, `CmuxNextFeed`, harness adapters, sign-in/passkey handover, email as a feed source): feed lead (lane 9).

## Landed
- 2026-10-03 feed lane 9: feed.md 9.1 approved by the daemon owner with B1-B7 (capability feed-local-owner-v1, in-process cmux-feed-core, explicit TUI ack); needs a cmux-tui window when built.
- 2026-10-03 feed lane 9: notification mirror (app posts alerting local daemon notifications to FeedDO as notices; 1c9b829aeb2 + privacy fixes) and the shared cmux.json key `feed.mirrorNotifications.{agents, terminal}` (agents on, terminal off by default). Steps 2 and 3 (one writer for unread state, daemon ledger producer-only) are planned in feed.md 9.1 for the daemon owner's review; no daemon change yet.
