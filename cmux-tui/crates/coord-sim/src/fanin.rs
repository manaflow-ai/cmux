//! `coord-sim fanin`: many acpmux hosts, one controller, N live sessions attached through it.
//!
//! Goal sessions-2000-attached: 2,000 live sessions spread over many VMs (GCP lane VMs and
//! Freestyle VMs), all steerable from ONE controller (Leo's app on one Mac, which reaches each
//! VM's acpmux). This simulates the fleet on one Linux machine with the real daemon on both
//! sides, and measures what the controller pays per session.
//!
//! ## How the controller side really works (read 2026-11-19, cmux-tui/crates/acpmux)
//!
//! - The app never talks to another machine itself. It is a client of its own Mac's acpmux
//!   daemon over the unix socket (JSON-RPC lines; `initialize`, then `_acpmux/person_prove` for
//!   allow-type actions only, `hub/person.rs`). Everything remote goes through that daemon.
//! - A remote machine is a **peer**: `peers` in the controller's `config.json`, one
//!   `PeerConfig` each (`src/config/peer.rs`): `url` (`ws://`, `wss://` or `ssh://`), `token`
//!   (the peer's WebSocket token), `peerToken` (`src/server/peer_auth.rs`: the peer's
//!   `<home>/run/peer.token`; only honored from a loopback address, so a real remote peer is
//!   reached through `ssh -W`, the cmux link's `acpmux` service, WireGuard, or the hub relay:
//!   `src/peer_carriers.rs`, `src/peer_paths.rs`, `src/peer_hub.rs`, `src/wireguard.rs`;
//!   tailnet ingress is `src/server/tailnet_ingress.rs` + `src/hub/tailnet_controller.rs` over
//!   `crates/cmux-tailnet`). `acpmux host enroll` (Add Machine) and fleet tools write these.
//! - The controller daemon is an ACP client of each peer (`src/peer.rs`): one link per peer, with
//!   reconnect/backoff (`src/peer_link.rs`). It mirrors the peer's session list (v1 list tee, or
//!   the v2 `listStream` mirror `src/peer_dialer.rs` + `src/peer_mirror.rs` into the
//!   `acpmux_core` index), and shows each remote session as `<peer>/<name>`. Every request for a
//!   peer session (`session/prompt`, `_acpmux/attach`, ...) is forwarded on that peer's link, and
//!   the peer's notifications are relayed to the local clients that attached.
//! - The fleet listing the app reads is `_acpmux/sessions` / `_acpmux/watch` on the controller:
//!   paged by `limit` + `cursor` -> `nextCursor` (`src/server/list_reply.rs`,
//!   `src/hub/page_first.rs`, `src/hub/session_pages.rs`), an unpaged read bounded by its page's
//!   bytes (`src/hub/list_guard.rs`). Peer rows sort among local ones from the mirror; row
//!   changes reach clients as `_acpmux/session_changed`, and a client that falls behind the hub's
//!   broadcast gets `_acpmux/lagged`.
//! - `acpmux send HOST/NAME` between machines with no peer link goes through the send relay
//!   (`src/cli/send_relay.rs`, `sendRelay` in config; on lane VMs the broker), not through peers.
//! - `~/.acpmux/hosts` is NOT the peer list: it is the agent-host records of this daemon's own
//!   sessions (`src/agent_host/mod.rs` `hosts_dir`), one process per session that outlives the
//!   daemon (`ACPMUX_AGENT_HOSTS=0` turns hosts off; then the agent is the daemon's child).
//! - The closest prior measurement is `tests/god_daemon.rs`: real daemon, peers as in-process hubs
//!   served over WebSocket behind a proxy. This module uses real daemons on both sides instead.
//!
//! ## What one ramp does (`fanin/fleet.rs`, `fanin/ramp.rs`)
//!
//! H host daemons (own `ACPMUX_HOME`, socket, WebSocket port and peer token; optionally behind a
//! latency-adding TCP proxy), N sessions spread over them, each run by the stand-in agent
//! `coord-sim fanin agent` (`fanin/agent.rs`), and one controller daemon whose `peers` are the H
//! hosts. coord-sim is the app: one unix-socket client of the controller, attached to all N.
//! Churn: every session emits one update every `1/rate` s (the same per-session rate at every N),
//! optionally 10x for `--burst-s` at the end of the window.
//!
//! Measured per N: attach (every session through the controller, and one chat repeatedly during
//! the window), the fleet listing (whole and paged), fan-out (one prompt to all N: controller send
//! to agent receipt), fan-in (agent emit to controller-visible), controller CPU and RSS (per
//! session, ratio vs the first N), host daemon RSS, lost and duplicated events. Raw samples go to
//! `RUN_DIR/n<N>/` as `run.json`, `events.ndjson`, `ops.ndjson`, `proc.ndjson` (the format
//! `coord-sim report` reads, see metrics.rs) and `fanin-table.json` (schema fanin-table.v1);
//! `RUN_DIR/fanin-summary.json` holds every table and the ratios.
//!
//!   coord-sim fanin --hosts H --sessions N --rate X --out RUN_DIR [--ramps 50,200,2000]
//!       [--acpmux BIN] [--window-s 300] [--settle-s 10] [--latency-ms 0] [--burst-s 0]
//!       [--fanout-rounds 3] [--max-n N] [--wall-clock-cap S] [--agent-hosts]
//!   coord-sim fanin teardown --out RUN_DIR      stop everything a run's state files name
//!   coord-sim fanin agent                       the stand-in ACP agent (the daemons start it)

mod agent;
mod fleet;
mod proc;
mod ramp;
mod rpc;
mod stats;

pub fn run(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("agent") => agent::run(),
        Some("teardown") => {
            let out = crate::flag(args, "--out")
                .ok_or("usage: coord-sim fanin teardown --out RUN_DIR")?;
            fleet::teardown_dir(std::path::Path::new(out))
        }
        _ => ramp::run(args),
    }
}
