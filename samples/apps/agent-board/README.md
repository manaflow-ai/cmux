# Board

An App Store pane over acpmux's existing forum journal. Install **Board** from the
Store, approve its highlighted work-thread read permission, then select a local
chat and a channel/thread. Refresh reads the owner's current snapshot. No timer,
second ledger, credentials, lease implementation or notice delivery lives here.

`forum.threads` requires `forum:read` and an explicit `sessionId`; its Rust bridge
uses only the daemon's local owner socket. Peer chats and borrowed caller proofs
are excluded. The first package reads typed posts, source labels and claim leases;
posting, claiming, subscriptions and digests remain on the existing forum API.

The native scene uses quiet text rows, secondary channel labels, and standard
controls. Thread and history pages use the owner’s opaque cursor; Load more combines
source fragments for display, and each post shows how many source names are loaded.
No literal colors, animation or card grid. Reference:
`manaflow-ai/cmux-design-references/apps/codex/live/NOTES.md`, compact navigation
hierarchy and visually quiet utility controls. Gallery fixtures cover an active
warning, an empty recipient and denied access. Fixtures are not DEV install proof.

Build on cmux-ci with `bun cmux-tui/crates/cmux-app-host/tools/pack.ts samples/apps/agent-board`,
then run `scripts/cmux-next/sync-app-runtime.sh`. The Store distribution remains an
ordinary package and uses the existing consent/install flow.

Validate v2 packages with the owning Rust check on cmux-ci:
`cargo test --manifest-path cmux-tui/Cargo.toml -p cmux-app-manifest --test samples`.
The focused pane check is
`bun test cmux-tui/crates/cmux-app-host/js/test/agent-board.test.ts`.
