//! What a lookup of a peer's chat by a key that is not its row key costs (`Hub::resolve_remote`):
//! a bare session id, as the app's chat pages send one for every read of a peer's chat, at
//! 1,200, 3,000 and 12,000 rows (30 peers). On a Mac (2026-11-10) ~30 peers listed 12,000
//! sessions and these lookups, each a walk of every row under the lock every peer record waits
//! on, held about a core. Manual:
//! `cargo test -p acpmux --lib resolve_cost -- --ignored --nocapture --test-threads=1`.

use super::*;
use crate::peer::{Peer, PeerNotice};
use std::time::Instant;

const PEERS: usize = 30;
const LOOKUPS: usize = 2_000;

fn hub_of(per_peer: usize) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    for p in 0..PEERS {
        let name = format!("peer-{p:02}");
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let rows = (0..per_peer)
            .map(|s| {
                json!({"sessionId": format!("01a1c7f2-{p:04}-{s:05}"), "name": format!("coord/lane-{s}"),
                       "status": "idle", "turnCount": 1, "createdAt": 1, "updatedAt": s + 1})
            })
            .collect();
        hub.apply_peer_notice(&name, peer.generation, PeerNotice::sessions_from_values(rows));
    }
    hub
}

#[test]
#[ignore = "manual lookup cost measurement"]
fn resolve_cost_bare_id() {
    for per_peer in [40, 100, 400] {
        let hub = hub_of(per_peer);
        let n = hub.remote_sessions.read().len();
        assert_eq!(n, PEERS * per_peer);
        let started = Instant::now();
        for i in 0..LOOKUPS {
            let key = format!("01a1c7f2-{:04}-{:05}", i % PEERS, i % per_peer);
            assert!(hub.resolve_remote(&key).is_some(), "{key}");
        }
        let per = started.elapsed().as_secs_f64() * 1e6 / LOOKUPS as f64;
        eprintln!("RESOLVE-COST bare_id rows={n} per_lookup_us={per:.1}");
    }
}
