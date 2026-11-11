//! What peer rows cost the daemon as they grow. A Mac linked to 43 peers that list 8,044 rows
//! sat at 77-105% of a core (cosmic-gray, 2026-11-02): each `_acpmux/resolve` (every lifecycle
//! command names its session through it) copied and sorted every row, and each streamed record
//! of a peer's session (`session/update`, `_acpmux/event`), `session_changed` and ask check walked
//! every peer's rows to find its own. A notice reads only its own peer's rows, and a resolve
//! copies only the rows its query could name.

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
    let rows = large.remote_sessions.read();
    assert_eq!(rows.values().filter(|r| r.peer == peer.name).count(), ROWS);
}

/// One full list: what each `_acpmux/resolve` built before, and its fallbacks again.
fn full_list_cost(hub: &Hub) -> Duration {
    let started = Instant::now();
    std::hint::black_box(hub.all_session_summaries());
    started.elapsed()
}

/// Resolves of the kinds lifecycle commands send: an exact peer name, a host-qualified name, a
/// prefix, a short name and a miss.
fn resolves_cost(hub: &Hub) -> Duration {
    let started = Instant::now();
    for query in ["peer-49/lane-7", "lane-12", "peer-3/lane-39", "lane-39", "nobody-here"] {
        let _ = std::hint::black_box(hub.locate(query, false, true));
    }
    started.elapsed()
}

#[test]
#[ignore = "lane-2-shaped synthetic benchmark"]
fn lane2_update_resend_bench() {
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    const STEADY_PEERS: usize = 18;
    const STEADY_ROWS: usize = 3_000;
    const RESEND_ROWS: usize = 1_860;
    const STEADY_NOTICES: usize = 8;
    let dir = std::env::temp_dir().join(format!("acpmux-l2-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    #[cfg(unix)]
    std::fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o1777)).unwrap();
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let mut peers = Vec::new();
    for n in 0..=STEADY_PEERS {
        let name = format!("peer-{n}");
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let rows = if n == 0 { RESEND_ROWS } else { STEADY_ROWS };
        hub.apply_peer_notice(
            &name,
            peer.generation,
            PeerNotice::Sessions((0..rows).map(row).collect()),
        );
        peers.push(peer);
    }
    for peer in &peers {
        peer.cache_saved_at.store(0, Ordering::SeqCst);
    }
    hub.cache_test_writes.store(0, Ordering::SeqCst);
    let mut events = hub.events.subscribe();
    let start = Arc::new(std::sync::Barrier::new(STEADY_PEERS + 2));
    let done = Arc::new(AtomicBool::new(false));
    let max_reader_us = Arc::new(AtomicU64::new(0));
    let reader_samples = Arc::new(AtomicU64::new(0));
    let max_lease_us = Arc::new(AtomicU64::new(0));
    let reader_hub = hub.clone();
    let reader_start = start.clone();
    let reader_done = done.clone();
    let reader_max = max_reader_us.clone();
    let reader_count = reader_samples.clone();
    let lease_max = max_lease_us.clone();
    let reader = std::thread::spawn(move || {
        reader_start.wait();
        while !reader_done.load(Ordering::Acquire) {
            let t = Instant::now();
            std::hint::black_box(reader_hub.remote_sessions());
            reader_max.fetch_max(t.elapsed().as_micros() as u64, Ordering::Relaxed);
            let t = Instant::now();
            drop(reader_hub.peer_leases.lock().unwrap());
            lease_max.fetch_max(t.elapsed().as_micros() as u64, Ordering::Relaxed);
            reader_count.fetch_add(1, Ordering::Relaxed);
        }
    });
    let mut steady = Vec::new();
    for (n, peer) in peers.iter().enumerate().skip(1) {
        let hub = hub.clone();
        let peer = peer.clone();
        let start = start.clone();
        steady.push(std::thread::spawn(move || {
            start.wait();
            for i in 0..STEADY_NOTICES {
                let mut changed = row(i % STEADY_ROWS);
                changed["updatedAt"] = json!(100 + i);
                hub.apply_peer_notice(
                    &peer.name,
                    peer.generation,
                    PeerNotice::SessionChanged {
                        session: changed,
                        kind: "status".into(),
                        seq: n as u64,
                    },
                );
            }
        }));
    }
    let churn_hub = hub.clone();
    let churn_peer = peers[0].clone();
    let churn_start = start.clone();
    let churn = std::thread::spawn(move || {
        churn_start.wait();
        let mut list: Vec<Value> = (0..RESEND_ROWS).map(row).collect();
        for (i, row) in list.iter_mut().enumerate().take(5) {
            row["updatedAt"] = json!(900 + i);
        }
        let t = Instant::now();
        churn_hub.apply_peer_notice(
            &churn_peer.name,
            churn_peer.generation,
            PeerNotice::Sessions(list),
        );
        t.elapsed()
    });
    let resend_cost = churn.join().unwrap();
    for worker in steady {
        worker.join().unwrap();
    }
    done.store(true, Ordering::Release);
    reader.join().unwrap();
    let mut event_count = 0u64;
    while events.try_recv().is_ok() {
        event_count += 1;
    }
    eprintln!(
        "lane2-update-bench peers={} steady_rows={} resend_rows={} steady_notices={} resend_us={:.0} reader_samples={} reader_max_us={} peer_leases_max_us={} events={} writes={} rows={} linux_synthetic=true",
        STEADY_PEERS,
        STEADY_ROWS,
        RESEND_ROWS,
        STEADY_NOTICES,
        resend_cost.as_secs_f64() * 1e6,
        reader_samples.load(Ordering::Relaxed),
        max_reader_us.load(Ordering::Relaxed),
        max_lease_us.load(Ordering::Relaxed),
        event_count,
        hub.cache_test_writes.load(Ordering::Relaxed),
        hub.remote_sessions().len()
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_resolve_among_thousands_of_peer_rows_copies_only_those_it_could_name() {
    let (hub, _peers) = linked(50, 160);
    assert_eq!(hub.remote_sessions().len(), 8_000);
    let full = full_list_cost(&hub).min(full_list_cost(&hub));
    let resolves = resolves_cost(&hub).min(resolves_cost(&hub));
    eprintln!(
        "locate-cost rows=8000 full_list_us={:.0} five_resolves_us={:.0}",
        full.as_secs_f64() * 1e6,
        resolves.as_secs_f64() * 1e6,
    );
    // Before, each of the five built at least one full list (a miss four): about eight in all.
    assert!(resolves < full * 2, "five resolves {resolves:?}, one full list {full:?}");
}

#[test]
fn a_resolve_still_finds_what_it_named_among_peers() {
    let (hub, _peers) = linked(3, 40);
    let found = |q: &str| {
        let reply = hub.locate(q, false, true).unwrap();
        let mut names: Vec<String> = reply["matches"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["name"].as_str().unwrap().to_owned())
            .collect();
        names.sort();
        names
    };
    // An exact qualified name, a bare name on every peer, a host-qualified prefix, a short
    // name, and a peer's own session id.
    assert_eq!(found("peer-1/lane-7"), ["peer-1/lane-7"]);
    assert_eq!(found("lane-7"), ["peer-0/lane-7", "peer-1/lane-7", "peer-2/lane-7"]);
    assert_eq!(found("peer-2/lane-3"), ["peer-2/lane-3"]);
    assert_eq!(found("peer-2/lane-1").len(), 1, "an exact name before its prefixes");
    assert_eq!(found("s5").len(), 3);
    let miss = hub.locate("lane-9999", false, true).unwrap_err();
    assert_eq!(miss.code, -32002);
}
