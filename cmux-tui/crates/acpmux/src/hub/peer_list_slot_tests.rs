//! A peer's whole lists while its shard is busy (cmux#56153): the newest replaces the ones
//! waiting, so a churning peer holds one list here, not one per flap.
use super::*;
use crate::peer::{Peer, PeerNotice};
use std::time::Duration;

fn list(name: &str) -> PeerNotice {
    PeerNotice::sessions_from_values(vec![
        json!({"sessionId":"live", "name":name, "status":"ready"}),
        json!({"sessionId":"done", "name":"done", "status":"closed"}),
    ])
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_busy_shard_applies_only_the_newest_of_a_peers_waiting_lists() {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let peer = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    hub.peers.lock().unwrap().insert(peer.name.clone(), peer.clone());
    hub.apply_peer_notice(&peer.name, peer.generation, list("start"));
    let mut events = hub.events.subscribe();
    let held_before = hub.peer_lists_waiting.held_count();

    // The shard is busy: the rows' writer lock is held, so the first list waits on it while
    // forty more of the same peer come in behind it, as under churn.
    const LISTS: usize = 40;
    let fence = hub.remote_sessions.fence();
    for n in 0..LISTS {
        let notice = list(&format!("v{n}"));
        hub.peer_notices.send((peer.name.clone(), peer.generation, notice)).await.unwrap();
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while hub.peer_lists_waiting.held_count() - held_before < LISTS as u64 {
        assert!(tokio::time::Instant::now() < deadline, "the notice loop never took the lists");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert!(
        hub.peer_lists_waiting.waiting() <= 1,
        "a peer's lists waiting for its shard: one at most, the newest"
    );
    drop(fence);

    // A barrier: once Connected settled, every notice before it was applied.
    let mut settled = peer.settled();
    let seen = *settled.borrow();
    hub.peer_notices
        .send((peer.name.clone(), peer.generation, PeerNotice::Connected))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n > seen))
        .await
        .expect("the notices settle")
        .unwrap();

    let last = format!("v{}", LISTS - 1);
    assert_eq!(
        hub.resolve_remote("live").unwrap().2["name"],
        last.as_str(),
        "the newest list's rows"
    );
    let mut applied = 0;
    while let Ok(event) = events.try_recv() {
        applied += usize::from(event.session_id == "live");
    }
    // The one the shard took before the lists piled up, and the newest: on the old queue all 40.
    assert!(
        applied <= 2,
        "the shard applied {applied} of {LISTS} lists; superseded ones go unapplied"
    );
    assert_eq!(hub.peer_lists_waiting.waiting(), 0);
}
