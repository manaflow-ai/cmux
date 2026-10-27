//! `_acpmux/status_changed`: a host chip follows a peer with no sessions (which announces no
//! session change) and a removed lease, and marks fold into one notification per read.

use super::*;
use crate::peer::PeerNotice;
use tokio::sync::watch::Receiver;

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Whether a mark came since the last read, and reads it. Every step of these tests is
/// synchronous on the current-thread runtime, so the peer's own connect task never runs
/// in between and adds no mark of its own.
fn marked(changes: &mut Receiver<u64>) -> bool {
    let marked = changes.has_changed().unwrap();
    changes.borrow_and_update();
    marked
}

#[tokio::test]
async fn a_peer_with_no_sessions_marks_status_when_it_connects_and_when_it_drops() {
    let hub = hub();
    let mut changes = hub.subscribe_status_changes();
    let cfg = crate::config::Config::default();
    let (lease, _) = hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, &cfg).unwrap();
    assert!(marked(&mut changes), "a new host is not marked");
    assert!(!marked(&mut changes));

    hub.apply_peer_notice("vm", lease.generation, PeerNotice::Connected);
    assert!(marked(&mut changes), "a connect with no sessions is not marked");
    assert!(
        hub.remote_sessions().is_empty(),
        "the peer has sessions: no longer the case under test"
    );

    hub.apply_peer_notice("vm", lease.generation, PeerNotice::Disconnected("gone".into()));
    assert!(marked(&mut changes), "a drop with no sessions is not marked");

    hub.end_peer_lease(&lease);
    assert!(marked(&mut changes), "a lease that ended is not marked");
}

#[tokio::test]
async fn adding_and_removing_a_saved_peer_marks_status() {
    let hub = hub();
    let mut changes = hub.subscribe_status_changes();
    hub.add_peer("box", "ws://127.0.0.1:7", None, None, false).await.unwrap();
    assert!(marked(&mut changes), "an added host is not marked");
    hub.remove_peer("box").await.unwrap();
    assert!(marked(&mut changes), "a removed host is not marked");
}

/// A served watching connection gets one `_acpmux/status_changed` for marks made before it
/// read them, and one more for a later mark. Paused time: each settle ends only once the
/// connection's tasks are idle.
#[tokio::test(start_paused = true)]
async fn a_watcher_gets_one_notification_for_marks_made_together() {
    let hub = hub();
    let (in_tx, in_rx) = tokio::sync::mpsc::channel::<String>(4);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<String>(64);
    let served = tokio::spawn(crate::server::serve_connection(hub.clone(), in_rx, out_tx));
    let watch = r#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/watch","params":{"enabled":true}}"#;
    in_tx.send(watch.to_owned()).await.unwrap();
    out_rx.recv().await.expect("the watch reply");

    let status_changes = |out_rx: &mut tokio::sync::mpsc::Receiver<String>| {
        let mut n = 0;
        while let Ok(line) = out_rx.try_recv() {
            n += usize::from(line.contains(crate::rpc::method::MUX_STATUS_CHANGED));
        }
        n
    };
    let settle = || tokio::time::sleep(std::time::Duration::from_millis(200));

    hub.status_changed();
    hub.status_changed();
    hub.status_changed();
    settle().await;
    assert_eq!(status_changes(&mut out_rx), 1, "marks made together are not one notification");

    hub.status_changed();
    settle().await;
    assert_eq!(status_changes(&mut out_rx), 1, "a later mark is not its own notification");

    drop(in_tx);
    served.await.unwrap();
}
