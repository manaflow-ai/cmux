//! A peer that drops and comes back over and over holds no more memory after N cycles than
//! after a few: the hub's per-peer state (rows, outage bookkeeping, tombstones, the event ring,
//! the caches) is bounded by the peers and their rows, never by how often they reconnected.
//!
//! 2026-11-26: a developer Mac's daemon (3.9 GB RSS, 10.9 h up) had applied 16,600 `Disconnected`
//! notices against 1,816 `Connected` and dialed 26,490 links; a lane VM's (4.1 GB) far
//! fewer. This measures the flap path alone, on one thread, with the test allocator: the bytes
//! still held after `WARM` cycles and after `WARM + CYCLES`, so the table and the caches cancel
//! out and only what grows per cycle is left.

use crate::hub::Hub;
use crate::peer::{Peer, PeerNotice};
use std::sync::Arc;

const PEERS: usize = 8;
const ROWS: usize = 40;
const WARM: usize = 20;

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn list(peer: &str) -> PeerNotice {
    PeerNotice::sessions_from_values(
        (0..ROWS).map(|i| crate::god_fixture::peer_row(peer, i, 75)).collect(),
    )
}

/// One outage and its return, in the order a link sends them: the drop, then the list,
/// `Listed` and `Connected`; the grace's end marks the rows stale in between.
fn flap(hub: &Hub, peers: &[(String, u64)], cycle: usize) {
    for (name, generation) in peers {
        hub.apply_peer_notice(name, *generation, PeerNotice::Disconnected(format!("flap {cycle}")));
        hub.mark_peer_unreachable(name, *generation);
        hub.apply_peer_notice(name, *generation, list(name));
        hub.apply_peer_notice(name, *generation, PeerNotice::Listed);
        hub.apply_peer_notice(name, *generation, PeerNotice::Connected);
    }
}

/// The bytes this thread holds after `cycles` flaps of every peer, over where it started.
fn held_after(cycles: usize) -> usize {
    use crate::hub::peer_snapshot::{thread_peak_bytes, thread_peak_take};
    thread_local! { static HELD: std::cell::Cell<usize> = const { std::cell::Cell::new(0) }; }
    let ((), _) = thread_peak_bytes(|| {
        // Built outside the runtime, a hub saves its peer caches inline (`Hub::save_peer_cache`)
        // instead of on a thread of its own per save: a spawn's closure and handle are allocated
        // here and freed on that thread, which this thread's count never sees go (190 bytes a
        // list, all of this test's "growth" before, 2026-11-26).
        let hub = hub();
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            // A connection that reads nothing: the event ring keeps what it is bounded to.
            let reader = hub.subscribe();
            let mut peers = Vec::new();
            for p in 0..PEERS {
                let name = format!("flap-{p}");
                let (tx, _rx) = tokio::sync::mpsc::channel(8);
                let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
                hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
                hub.apply_peer_notice(&name, peer.generation, list(&name));
                hub.apply_peer_notice(&name, peer.generation, PeerNotice::Connected);
                peers.push((name, peer.generation));
            }
            for cycle in 0..cycles {
                flap(&hub, &peers, cycle);
                tokio::task::yield_now().await;
            }
            for _ in 0..64 {
                tokio::task::yield_now().await;
            }
            // Twice: the first answer is the most held since the start, the second what is held
            // now.
            let _ = thread_peak_take();
            HELD.set(thread_peak_take().unwrap_or(0));
            drop(reader);
        });
        drop(hub);
        drop(runtime);
    });
    HELD.get()
}

#[cfg(target_os = "linux")]
#[test]
fn a_peer_that_reconnects_over_and_over_holds_flat_memory() {
    let cycles: usize =
        std::env::var("ACPMUX_FLAP_CYCLES").ok().and_then(|v| v.parse().ok()).unwrap_or(400);
    // A first pass fills what the process keeps once (statics, compiled patterns, the store's
    // pools), which this thread or another test's may build: either way it is not per cycle.
    let _ = held_after(WARM);
    let warm = held_after(WARM);
    let long = held_after(WARM + cycles);
    let per_cycle = long.saturating_sub(warm) / cycles;
    println!(
        "peer-flap-memory peers={PEERS} rows={ROWS} warm_cycles={WARM} held={warm} \
         cycles={} held={long} per_cycle={per_cycle}",
        WARM + cycles
    );
    // A cycle of every peer applies PEERS * 4 notices; past warm-up none of them may keep a byte
    // per cycle beyond allocator noise (a cycle's row text alone is ~PEERS * ROWS * 2.5 kB).
    assert!(
        per_cycle < 1024,
        "{per_cycle} bytes held per reconnect cycle of {PEERS} peers: something keeps per-cycle state"
    );
}
