use super::super::*;
use super::*;
use crate::session_identity::SessionReceipt;
use std::sync::mpsc;
use std::time::Duration;

fn row(peer: &str, mux: &str) -> (String, RemoteSession) {
    let receipt = SessionReceipt::new(peer, mux, None, 0);
    let summary = json!({"sessionId": mux, "peer": peer, "status": "running"});
    (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary: summary.into(), receipt })
}

fn table_of(peers: usize, per_peer: usize) -> RemoteTable {
    let table = RemoteTable::default();
    {
        let mut rows = table.write();
        for p in 0..peers {
            for s in 0..per_peer {
                let (key, r) = row(&format!("peer-{p}"), &format!("s{s}"));
                rows.insert(key, r);
            }
        }
    }
    table
}

/// cmux#40935's class: a reader in the middle of a walk over 12,000 rows, as long as it
/// likes, never holds up a write. Under the old mutex the write below waited forever.
#[test]
fn a_slow_reader_never_stalls_a_writer() {
    let table = Arc::new(table_of(30, 400));
    let (started_tx, started) = mpsc::channel();
    let (release, release_rx) = mpsc::channel::<()>();
    let reader = {
        let table = table.clone();
        std::thread::spawn(move || {
            let rows = table.read();
            started_tx.send(()).unwrap();
            // Still "walking" until released.
            release_rx.recv().unwrap();
            rows.len()
        })
    };
    started
        .recv_timeout(std::time::Duration::from_secs(30))
        .expect("the reader never started its walk");
    let (done_tx, done) = mpsc::channel();
    let writer = {
        let table = table.clone();
        std::thread::spawn(move || {
            let (key, r) = row("peer-new", "s0");
            table.write().insert(key, r);
            done_tx.send(()).unwrap();
        })
    };
    let finished = done.recv_timeout(Duration::from_secs(5));
    // Released either way, so a failure reports instead of hanging.
    release.send(()).unwrap();
    assert!(finished.is_ok(), "a write waited behind a reader holding a snapshot");
    writer.join().unwrap();
    assert_eq!(reader.join().unwrap(), 12_000, "the reader kept the version it loaded");
    assert_eq!(table.read().len(), 12_001, "the write is published");
}

/// Writers take turns, each starting from the one before's table: none is lost.
#[test]
fn writers_serialize_and_publish_in_order() {
    let table = Arc::new(RemoteTable::default());
    let writers: Vec<_> = ["a", "b"]
        .into_iter()
        .map(|peer| {
            let table = table.clone();
            std::thread::spawn(move || {
                for s in 0..1_000 {
                    let (key, r) = row(peer, &format!("s{s}"));
                    table.write().insert(key, r);
                }
            })
        })
        .collect();
    for w in writers {
        w.join().unwrap();
    }
    let rows = table.read();
    assert_eq!(rows.len(), 2_000);
    assert_eq!(rows.writes, 2_000);
    assert_eq!(rows.peer_counts().get("a"), Some(&1_000));
}

/// A fence waits for a writer in flight and holds the next one off; `settled` sees every
/// write that published before it.
#[test]
fn a_fence_orders_against_writers() {
    let table = Arc::new(table_of(1, 1));
    let fence = table.fence();
    assert!(table.try_write().is_none(), "a fence keeps writers out");
    let writer = {
        let table = table.clone();
        std::thread::spawn(move || {
            let (key, r) = row("peer-1", "s0");
            table.write().insert(key, r);
        })
    };
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(table.read().len(), 1, "no write lands while the fence is held");
    drop(fence);
    writer.join().unwrap();
    assert_eq!(table.settled().len(), 2);
    assert!(table.try_write().is_some());
}
