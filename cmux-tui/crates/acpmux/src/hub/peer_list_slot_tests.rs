//! Whole lists cross a link's backlog, the ingress, and a shard on the way to the rows.
use super::*;
use crate::peer::{Peer, PeerNotice};
use futures_util::FutureExt as _;
use std::sync::atomic::Ordering::SeqCst;
use std::time::Duration;

#[tokio::test]
async fn a_busy_shard_applies_only_the_newest_of_a_peers_waiting_lists() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let peer = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    peer.coalesce_lists();
    hub.peers.lock().unwrap().insert(peer.name.clone(), peer.clone());
    peer.connected.store(true, SeqCst);
    let mut settled = peer.settled();
    let seen = *settled.borrow();
    let send = |notice| {
        peer.queue_notice_for_test(notice)
            .now_or_never()
            .expect("room in the link backlog")
            .expect("hub receiving");
    };

    // No yield on a current-thread runtime. The hub and its shard cannot drain until the
    // producer has filled the 4096-entry ingress and started using its own backlog.
    const LISTS: usize = 6000;
    let mut rows = Vec::with_capacity(LISTS);
    for n in 0..LISTS {
        let row: Arc<str> =
            Arc::from(format!(r#"{{"sessionId":"live","name":"v{n}","status":"ready"}}"#));
        rows.push(Arc::downgrade(&row));
        send(PeerNotice::Sessions(vec![row]));
        if n == 0 {
            // A skipped list still owns its Listed. The next link's patch needs that missing
            // baseline, so its Listed must not wake deliveries or declare a missing name final.
            send(PeerNotice::Listed);
            peer.link_ended();
            send(PeerNotice::SessionsPatch { rows: vec![], gone: vec!["live".into()] });
            send(PeerNotice::Listed);
        }
    }
    send(PeerNotice::Listed);
    send(PeerNotice::Restarting); // settle after the last Listed, without a Connected wake
    assert_eq!(hub.peer_notices.capacity(), 0, "the ingress is full");
    assert_eq!(rows.iter().filter(|r| r.strong_count() > 0).count(), 1);
    assert!(rows.last().unwrap().strong_count() > 0, "the newest payload survives");

    tokio::time::timeout(Duration::from_secs(30), settled.wait_for(|n| *n > seen))
        .await
        .expect("the shard drains")
        .unwrap();
    assert_eq!(hub.resolve_remote("live").unwrap().2["name"], "remote/v5999");
    assert_eq!(hub.outbox.peer_ready_count(&peer.name), 1, "only the applied list wakes sends");
    assert!(peer.rows_current());
    assert!(hub.no_session_is_final("remote/missing"));
}
