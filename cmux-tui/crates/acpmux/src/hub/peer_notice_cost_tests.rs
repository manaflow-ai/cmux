//! What one peer notice costs as other peers' rows grow. Every streamed record of a peer's
//! session (`session/update`, `_acpmux/event`), each `session_changed` and each ask check finds
//! its row; with a walk over every peer's rows, a Mac linked to peers listing thousands of
//! sessions spent a core in the notice loop (cosmic-gray, 2026-11-02: 77-105% CPU, ~1,700 rows
//! from one peer). A notice reads only its own peer's rows, so its cost holds as the others grow.

use super::*;
use crate::peer::{Peer, PeerNotice};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The notices each measured round applies.
const NOTICES: usize = 2_000;

fn setup() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap())
}

fn row(session: usize) -> Value {
    json!({
        "sessionId": format!("s{session}"),
        "name": format!("lane-{session}"),
        "status": "running",
        "createdAt": 1,
        "updatedAt": 1,
        "cwd": "/home/agent/Projects/checkouts/repo/lane--some-branch-name",
        "title": "A title long enough to look like a real one",
    })
}

/// A hub linked to `peers` peers of `rows` rows each, and the first peer's name and generation.
fn linked(peers: usize, rows: usize) -> (Arc<Hub>, Vec<Arc<Peer>>) {
    let hub = setup();
    let mut linked = Vec::new();
    for n in 0..peers {
        let name = format!("peer-{n}");
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..rows).map(row).collect();
        hub.apply_peer_notice(&name, peer.generation, PeerNotice::Sessions(list));
        linked.push(peer);
    }
    (hub, linked)
}

/// The time `NOTICES` notices of the last peer take: streamed records, row changes and ask checks.
fn notices_cost(hub: &Hub, peer: &Peer, rows: usize) -> Duration {
    let started = Instant::now();
    for n in 0..NOTICES {
        let id = format!("s{}", n % rows);
        let update = json!({
            "sessionId": id,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x"}},
            "_meta": {"acpmux": {"seq": n + 1, "at": 1}},
        });
        hub.apply_peer_notice(
            &peer.name,
            peer.generation,
            PeerNotice::Notification {
                method: crate::rpc::method::SESSION_UPDATE.into(),
                params: update,
                link: 0,
            },
        );
        if n % 4 == 0 {
            let mut changed = row(n % rows);
            changed["updatedAt"] = json!(n + 2);
            hub.apply_peer_notice(
                &peer.name,
                peer.generation,
                PeerNotice::SessionChanged { session: changed, kind: "status".into(), seq: 0 },
            );
        }
        assert!(!hub.peer_ask_counts(&peer.name, &id, &json!({"personInstance": "nobody"})));
    }
    started.elapsed()
}

#[test]
fn a_peer_notice_costs_the_same_however_many_rows_other_peers_list() {
    const ROWS: usize = 400;
    let (small, small_peers) = linked(1, ROWS);
    let (large, large_peers) = linked(50, ROWS);
    assert_eq!(large.remote_sessions().len(), 50 * ROWS);
    // Each measured twice, the faster kept: a scheduler hiccup does not fail it.
    let measure =
        |hub: &Hub, peer: &Peer| notices_cost(hub, peer, ROWS).min(notices_cost(hub, peer, ROWS));
    let alone = measure(&small, small_peers.last().unwrap());
    let among = measure(&large, large_peers.last().unwrap());
    eprintln!(
        "peer-notice-cost notices={NOTICES} rows_alone={ROWS} rows_among={} alone_us_per_notice={:.1} among_us_per_notice={:.1}",
        50 * ROWS,
        alone.as_secs_f64() * 1e6 / NOTICES as f64,
        among.as_secs_f64() * 1e6 / NOTICES as f64,
    );
    // A walk over every row costs about 50 times as much among 50 peers; a read of the
    // peer's own rows costs the same, within noise.
    assert!(among < alone * 4, "among 50 peers {among:?}, alone {alone:?}");
    // The rows the notices changed are still the peer's, once each.
    let peer = large_peers.last().unwrap();
    let rows = large.remote_sessions.lock().unwrap();
    assert_eq!(rows.values().filter(|r| r.peer == peer.name).count(), ROWS);
}
