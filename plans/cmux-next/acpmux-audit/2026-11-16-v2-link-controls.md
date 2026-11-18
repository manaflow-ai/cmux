# v2 row 8c: opt-in controls sideband

Leo: "even if a chat is long, there should be no percievable difference".

`linkControls` advertises `_acpmux/controls` only to an authenticated owner peer with v2 peers
installed. `server/controls.rs` pages pending asks from the owner, then commits their keyed change
stream. `peer_controls.rs` applies snapshots before changes and reopens after an explicit resync.
The existing watch remains on; no client crate changes.

The 256 KiB reservation covers snapshot replies, staged changes, outbound queue, pump and transport.
An overrun ends the control stream with a counted resync (`gauges.queues.controlsResyncs`), retaining
room for the terminal line. A single ask larger than a page is explicitly refused. Closed session
rows are never walked or projected to build the ask pages. The receiver uses the existing peer
membership/run validation; broker readiness is bound to the current link's matching live reply.

Detector: the Rust `controls_` tests exercise feature gating, strict request shapes, page bounds,
nonce/run/label projection, queue reservations through transport consumption and a real link's
resync/reopen with the watch kept. Static prepush and formatting checks passed on the initial
implementation; hosted execution is required before readiness. This is an additive migration cut,
not the later watch-removal cut.
