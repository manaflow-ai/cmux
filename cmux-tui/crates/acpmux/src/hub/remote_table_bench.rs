//! What a peer notice costs while another thread reads every peer row (cmux#40935's class): a
//! Mac linked to ~30 peers listing 12,000 sessions answered lookups that walked every row under
//! the one lock each peer notice needs, so a notice waited out a whole walk. Here 30 peers of 400
//! rows; one thread walks the rows as lookups do (`Hub::remote_matches`, `Hub::resolve_remote`
//! by a short name, `Hub::remote_names_containing`) for as long as the last peer's 2,000
//! `session_changed` notices take, each notice timed; then the same notices with no reader.
//! Manual:
//! `cargo test -p acpmux --lib remote_table_bench -- --ignored --nocapture --test-threads=1`.

use super::*;
use crate::peer::{Peer, PeerNotice};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

const PEERS: usize = 30;
const PER_PEER: usize = 400;
const NOTICES: usize = 2_000;

fn row(p: usize, s: usize, updated: usize) -> Value {
    json!({
        "sessionId": format!("01a1c7f2-{p:04}-{s:05}"),
        "name": format!("coord/lane-{s}"),
        "status": "idle",
        "turnCount": 1,
        "createdAt": 1,
        "updatedAt": updated,
        "cwd": "/home/agent/Projects/checkouts/repo/lane--some-branch-name",
        "title": "A title long enough to look like a real one",
    })
}

/// A hub linked to 30 peers of 400 rows each (12,000), and the peers.
fn linked() -> (Arc<Hub>, Vec<Arc<Peer>>) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub =
        Hub::new(cfg.clone(), crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap());
    let mut peers = Vec::new();
    for p in 0..PEERS {
        let name = format!("peer-{p:02}");
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..PER_PEER).map(|s| row(p, s, s + 1)).collect();
        hub.apply_peer_notice(&name, peer.generation, PeerNotice::Sessions(list));
        peers.push(peer);
    }
    assert_eq!(hub.remote_sessions().len(), PEERS * PER_PEER);
    (hub, peers)
}

/// Latency percentiles of one round.
struct Round {
    p50: Duration,
    p99: Duration,
    max: Duration,
    reads: u64,
}

/// The last peer's `NOTICES` `session_changed` notices, each timed; with `busy`, one thread walks
/// the rows the whole time. `round` keeps each round's `updatedAt` new, so every notice writes.
fn notices_round(hub: &Arc<Hub>, peer: &Peer, busy: bool, round: usize) -> Round {
    let stop = Arc::new(AtomicBool::new(false));
    let reads = Arc::new(AtomicU64::new(0));
    let started = Arc::new(std::sync::Barrier::new(2));
    let reader = busy.then(|| {
        let (hub, stop, reads, started) =
            (hub.clone(), stop.clone(), reads.clone(), started.clone());
        std::thread::spawn(move || {
            started.wait();
            while !stop.load(Ordering::Acquire) {
                // Each a walk over all 12,000 rows, as a lookup by a short name or a bare id
                // made before cmux#40935's indexes.
                std::hint::black_box(hub.remote_matches("lane-39"));
                std::hint::black_box(hub.resolve_remote("lane-39"));
                std::hint::black_box(hub.remote_names_containing("lane-39"));
                reads.fetch_add(1, Ordering::Relaxed);
            }
        })
    });
    if busy {
        started.wait();
        // Let the reader get into its walk before the first notice.
        std::thread::sleep(Duration::from_millis(5));
    }
    let p = PEERS - 1;
    let mut took = Vec::with_capacity(NOTICES);
    for n in 0..NOTICES {
        let session = row(p, n % PER_PEER, 10_000 + round * NOTICES + n);
        let t = Instant::now();
        hub.apply_peer_notice(
            &peer.name,
            peer.generation,
            PeerNotice::SessionChanged { session, kind: "status".into(), seq: 0 },
        );
        took.push(t.elapsed());
    }
    stop.store(true, Ordering::Release);
    if let Some(reader) = reader {
        reader.join().unwrap();
    }
    took.sort();
    let at = |q: f64| took[((took.len() as f64 * q) as usize).min(took.len() - 1)];
    Round {
        p50: at(0.50),
        p99: at(0.99),
        max: *took.last().unwrap(),
        reads: reads.load(Ordering::Relaxed),
    }
}

fn print(label: &str, r: &Round) {
    eprintln!(
        "remote-table-bench rows={} notices={NOTICES} reader={label} p50_us={} p99_us={} max_us={} reader_walks={}",
        PEERS * PER_PEER,
        r.p50.as_micros(),
        r.p99.as_micros(),
        r.max.as_micros(),
        r.reads,
    );
}

#[test]
#[ignore = "bench"]
fn remote_table_bench() {
    let (hub, peers) = linked();
    let peer = peers.last().unwrap();
    // Warm once, unmeasured.
    notices_round(&hub, peer, false, 0);
    let busy = notices_round(&hub, peer, true, 1);
    let idle = notices_round(&hub, peer, false, 2);
    print("busy", &busy);
    print("idle", &idle);
}
