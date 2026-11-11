//! What a peer notice costs while another thread reads every peer row (cmux#40935's class): a
//! Mac linked to ~30 peers listing 12,000 sessions answered lookups that walked every row under
//! the one lock each peer notice needs, so a notice waited out a whole walk. Here 30 peers of 400
//! rows; one thread walks the rows as lookups do (`Hub::remote_matches`, `Hub::resolve_remote`
//! by a short name, `Hub::remote_names_containing`) for as long as the last peer's 2,000
//! `session_changed` notices take, each notice timed; then the same notices with no reader.
//! Manual (the bench and the cost guard, in their own run):
//! `cargo test -p acpmux --lib remote_table_bench -- --ignored --nocapture --test-threads=1`.

use super::*;
use crate::peer::{Peer, PeerNotice};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
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

/// Latency percentiles of one round; with a reader, also its walks'.
struct Round {
    p50: Duration,
    p99: Duration,
    max: Duration,
    reads: u64,
    /// The median of the reader's walks (one lookup, each over every row); zero with no reader.
    walk_p50: Duration,
}

fn at(sorted: &[Duration], q: f64) -> Duration {
    sorted[((sorted.len() as f64 * q) as usize).min(sorted.len() - 1)]
}

/// The last peer's `NOTICES` `session_changed` notices, each timed; with `busy`, one thread walks
/// the rows the whole time, each walk timed. `round` keeps each round's `updatedAt` new, so every
/// notice writes.
fn notices_round(hub: &Hub, peer: &Peer, busy: bool, round: usize) -> Round {
    let stop = AtomicBool::new(false);
    let reads = AtomicU64::new(0);
    let started = std::sync::Barrier::new(2);
    // A scoped thread: the scope joins the reader before it returns, so it never outlives the round.
    let (mut took, mut walks) = std::thread::scope(|scope| {
        let reader = busy.then(|| {
            scope.spawn(|| {
                let mut walks = Vec::new();
                started.wait();
                while !stop.load(Ordering::Acquire) {
                    // Each a walk over all 12,000 rows, as a lookup by a short name or a bare id
                    // made before cmux#40935's indexes.
                    let t = Instant::now();
                    std::hint::black_box(hub.remote_matches("lane-39"));
                    walks.push(t.elapsed());
                    let t = Instant::now();
                    std::hint::black_box(hub.resolve_remote("lane-39"));
                    walks.push(t.elapsed());
                    let t = Instant::now();
                    std::hint::black_box(hub.remote_names_containing("lane-39"));
                    walks.push(t.elapsed());
                    reads.fetch_add(1, Ordering::Relaxed);
                }
                walks
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
        (took, reader.map(|r| r.join().unwrap()).unwrap_or_default())
    });
    took.sort();
    walks.sort();
    Round {
        p50: at(&took, 0.50),
        p99: at(&took, 0.99),
        max: *took.last().unwrap(),
        reads: reads.load(Ordering::Relaxed),
        walk_p50: if walks.is_empty() { Duration::ZERO } else { at(&walks, 0.50) },
    }
}

fn print(label: &str, r: &Round) {
    eprintln!(
        "remote-table-bench rows={} notices={NOTICES} reader={label} p50_us={} p99_us={} max_us={} reader_walks={} walk_p50_us={}",
        PEERS * PER_PEER,
        r.p50.as_micros(),
        r.p99.as_micros(),
        r.max.as_micros(),
        r.reads,
        r.walk_p50.as_micros(),
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

/// A peer notice lands while a reader holds the rows in the middle of a walk, for as long as the
/// reader likes: the notice takes nothing the reader holds. Before the snapshot
/// (`remote_table.rs`) the reader held the one lock each peer notice needs, and the notice below
/// waited until the reader let go. Deterministic: the reader is parked mid-walk until released,
/// and the bound is liveness (a notice takes microseconds), not a timing ratio.
#[test]
fn a_peer_notice_lands_while_a_reader_is_parked_mid_walk() {
    let (hub, peers) = linked();
    // References, so each thread below moves in its own channel end and shares these.
    let (hub, peer) = (&*hub, &**peers.last().unwrap());
    let writes = hub.remote_sessions.read().writes;
    let (parked_tx, parked) = mpsc::channel();
    let (release, release_rx) = mpsc::channel::<()>();
    let (landed_tx, landed) = mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(move || {
            let rows = hub.remote_sessions.read();
            // Half way through a walk over every row, then parked until released.
            let walked = rows.iter().take(PEERS * PER_PEER / 2).count();
            parked_tx.send(walked).unwrap();
            release_rx.recv().unwrap();
            std::hint::black_box(rows.iter().count());
        });
        assert_eq!(parked.recv().unwrap(), PEERS * PER_PEER / 2);
        scope.spawn(move || {
            let session = row(PEERS - 1, 0, 1_000_000);
            hub.apply_peer_notice(
                &peer.name,
                peer.generation,
                PeerNotice::SessionChanged { session, kind: "status".into(), seq: 0 },
            );
            landed_tx.send(()).unwrap();
        });
        let finished = landed.recv_timeout(Duration::from_secs(10));
        // Released either way, so a failure reports instead of hanging.
        release.send(()).unwrap();
        assert!(finished.is_ok(), "a peer notice waited on a reader parked mid-walk");
    });
    assert!(hub.remote_sessions.read().writes > writes, "the notice wrote its row");
}

/// The cost guard, a scaling check: a peer notice while a reader walks every row, in units of
/// the reader's own walk, both timed in the same round, so machine load that slows one slows the
/// other and the ratio holds. Before the snapshot (`remote_table.rs`) each notice waited out the
/// walk in progress (the median notice at least half a walk, often several); with it a notice
/// costs a small fraction of one. The best of three rounds is kept. It is a check for its own
/// run, one test at a time, never among the lib suite's ~5,000 parallel tests, whose load beside
/// it skewed the wall-clock p99 this replaced (cmux-ci run 43048597606). Whoever changes the peer
/// rows' read or write path runs it on the fleet, before and after:
/// `cargo test -p acpmux --lib hub::remote_table_bench::a_notice_costs_a_fraction_of_a_reader_walk -- --ignored --exact --test-threads=1 --nocapture`.
/// The default run keeps the deterministic `a_peer_notice_lands_while_a_reader_is_parked_mid_walk`.
#[test]
#[ignore = "own run, one test at a time: a wall-clock ratio"]
fn a_notice_costs_a_fraction_of_a_reader_walk() {
    let (hub, peers) = linked();
    let peer = peers.last().unwrap();
    notices_round(&hub, peer, false, 0);
    let ratio = (1..=3)
        .map(|round| {
            let r = notices_round(&hub, peer, true, round);
            let ratio = r.p50.as_secs_f64() / r.walk_p50.as_secs_f64().max(1e-9);
            eprintln!(
                "remote-table-guard round={round} notice_p50_us={} walk_p50_us={} reader_walks={} ratio={ratio:.4}",
                r.p50.as_micros(),
                r.walk_p50.as_micros(),
                r.reads,
            );
            ratio
        })
        .fold(f64::INFINITY, f64::min);
    assert!(
        ratio < 0.25,
        "a busy reader held notices up: the median notice took {ratio:.3} of a reader walk"
    );
}
