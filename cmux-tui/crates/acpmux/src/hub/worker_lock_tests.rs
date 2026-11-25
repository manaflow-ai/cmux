//! `status` answers while a slow writer holds a lock that request tasks take: a chat's append
//! lock, the outbox's book (`crate::worker_lock`; Leo's daemon, 2026-11-22).

use super::*;
use serde_json::json;
use std::time::{Duration, Instant};

/// How long `status` takes on this machine with nothing held, warm: the budget is on top of it.
async fn status_alone(hub: &Arc<Hub>) -> Duration {
    hub.status().await;
    let started = Instant::now();
    hub.status().await;
    started.elapsed()
}

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The slow-disk seam: a writer that holds the append lock for 2 s, as a log write did on
/// Leo's swapping Mac. Eight appends queue behind it on a two-worker runtime; `status` (what
/// `ls` and every pane's connect wait on) must still answer in under 500 ms. Before this
/// lock, both workers parked in the appends' waits and `status` took the whole 2 s.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn status_answers_while_a_slow_writer_holds_a_chats_append_lock() {
    let hub = test_hub();
    let session = hub
        .new_session(NewRequest {
            harness: Some("fake".into()),
            name: Some("slow-writer".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let alone = status_alone(&hub).await;
    let (held_tx, held_rx) = std::sync::mpsc::channel();
    let writer = std::thread::spawn({
        let session = session.clone();
        move || {
            let _held = session.append_lock.lock().unwrap();
            held_tx.send(()).unwrap();
            std::thread::sleep(Duration::from_secs(2));
        }
    });
    held_rx.recv_timeout(Duration::from_secs(10)).expect("the slow holder never took the lock");
    let appends: Vec<_> = (0..8)
        .map(|i| {
            let (hub, session) = (hub.clone(), session.clone());
            tokio::spawn(async move {
                hub.append_quiet(&session, "mux", "note", json!({ "i": i }));
            })
        })
        .collect();
    // Let the appends reach the lock and wait on it.
    tokio::time::sleep(Duration::from_millis(100)).await;
    let started = Instant::now();
    let status = tokio::spawn({
        let hub = hub.clone();
        async move { hub.status().await }
    });
    let status = tokio::time::timeout(Duration::from_secs(5), status).await.unwrap().unwrap();
    let took = started.elapsed();
    assert!(
        took < alone + Duration::from_millis(500),
        "status took {took:?} behind a slow writer ({alone:?} alone)"
    );
    assert_eq!(status["sessions"], json!(1), "{status}");
    for append in appends {
        tokio::time::timeout(Duration::from_secs(5), append).await.unwrap().unwrap();
    }
    writer.join().unwrap();
}

/// Leo's daemon's lock: a writer holds the outbox's book for 2 s while eight deliveries' tasks
/// wait on it on a two-worker runtime. `status` (which counts the unsettled deliveries) must
/// answer in under 500 ms. Before, both workers parked in `Outbox::get` and `status` waited on
/// the book itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn status_answers_while_a_slow_writer_holds_the_outbox() {
    let hub = test_hub();
    let alone = status_alone(&hub).await;
    let (held_tx, held_rx) = std::sync::mpsc::channel();
    let writer = std::thread::spawn({
        let hub = hub.clone();
        move || hub.outbox.hold_book_for_then(Duration::from_secs(2), || held_tx.send(()).unwrap())
    });
    held_rx.recv_timeout(Duration::from_secs(10)).expect("the slow holder never took the lock");
    let deliveries: Vec<_> = (0..8)
        .map(|i| {
            let hub = hub.clone();
            tokio::spawn(async move { hub.outbox.get(&format!("d{i}")) })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let started = Instant::now();
    let status = tokio::spawn({
        let hub = hub.clone();
        async move { hub.status().await }
    });
    let status = tokio::time::timeout(Duration::from_secs(5), status).await.unwrap().unwrap();
    let took = started.elapsed();
    assert!(
        took < alone + Duration::from_millis(500),
        "status took {took:?} behind the outbox's writer ({alone:?} alone)"
    );
    assert_eq!(status["outboxPending"], json!(0), "{status}");
    for delivery in deliveries {
        let got = tokio::time::timeout(Duration::from_secs(5), delivery).await.unwrap().unwrap();
        assert!(got.is_none());
    }
    writer.join().unwrap();
}
