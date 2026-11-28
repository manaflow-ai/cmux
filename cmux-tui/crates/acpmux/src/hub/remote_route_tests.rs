//! A lookup that only routes to a peer's chat (`Hub::remote_route`) parses no row: a prompt's
//! forward asks it several times (compose wake, the remote guard, the cross-host audit's host),
//! and each `Hub::resolve_remote` rebuilt the whole row's text (tools included) and parsed it.
//! Manual cost: `cargo test -p acpmux --lib remote_route_cost -- --ignored --nocapture`.

use super::*;
use crate::hub::peer_row::VALUE_PARSES;
use crate::peer::{Peer, PeerNotice};
use std::time::Instant;

fn hub_with_row() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".into(), peer.clone());
    // A row as a busy chat lists it: a few dozen tools, as a host's coding agent carries.
    let tools: Vec<Value> = (0..40)
        .map(|i| json!({"name": format!("tool_{i}"), "description": "x".repeat(200)}))
        .collect();
    let row = json!({"sessionId": "01a1c7f2-0000-00001", "name": "coord/lane-1", "status": "idle",
                     "turnCount": 1, "createdAt": 1, "updatedAt": 2, "tools": tools});
    hub.apply_peer_notice("box", peer.generation, PeerNotice::sessions_from_values(vec![row]));
    hub
}

fn parses() -> u64 {
    VALUE_PARSES.with(|n| n.get())
}

#[test]
fn remote_route_parses_no_row() {
    let hub = hub_with_row();
    for key in ["01a1c7f2-0000-00001", "box/coord/lane-1", "coord/lane-1"] {
        let before = parses();
        let (peer, id) = hub.remote_route(key).unwrap_or_else(|| panic!("{key}"));
        assert_eq!((peer.name.as_str(), id.as_str()), ("box", "01a1c7f2-0000-00001"));
        assert_eq!(parses() - before, 0, "{key}: remote_route parsed the row");
        // Same answer as the parsing lookup, which still parses once.
        let (p2, id2, row) = hub.resolve_remote(key).unwrap();
        assert_eq!((p2.name.as_str(), id2.as_str()), ("box", "01a1c7f2-0000-00001"));
        // The parsed row carries the name a list shows it under: its host first.
        assert_eq!(row["name"], "box/coord/lane-1");
        assert_eq!(parses() - before, 1, "{key}: resolve_remote parses once");
    }
    let before = parses();
    assert!(hub.remote_route("nope").is_none());
    assert!(hub.resolve_remote("nope").is_none());
    assert_eq!(parses(), before);
}

#[test]
#[ignore = "manual lookup cost measurement"]
fn remote_route_cost() {
    let hub = hub_with_row();
    const N: usize = 20_000;
    let key = "01a1c7f2-0000-00001";
    let t = Instant::now();
    for _ in 0..N {
        std::hint::black_box(hub.resolve_remote(key));
    }
    let parse_us = t.elapsed().as_secs_f64() * 1e6 / N as f64;
    let t = Instant::now();
    for _ in 0..N {
        std::hint::black_box(hub.remote_route(key));
    }
    let route_us = t.elapsed().as_secs_f64() * 1e6 / N as f64;
    eprintln!("REMOTE-ROUTE-COST resolve_remote_us={parse_us:.2} remote_route_us={route_us:.2}");
}
