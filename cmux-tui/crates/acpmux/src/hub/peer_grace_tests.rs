use super::*;
use crate::peer::{Peer, PeerNotice};
use std::time::Duration;

fn fixture() -> (Arc<Hub>, Arc<Peer>, Vec<Value>) {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let peer = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    hub.peers.lock().unwrap().insert(peer.name.clone(), peer.clone());
    let rows = vec![
        json!({"sessionId":"live", "name":"live", "status":"ready"}),
        json!({"sessionId":"done", "name":"done", "status":"closed"}),
    ];
    hub.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Sessions(rows.clone()));
    (hub, peer, rows)
}

async fn send(hub: &Hub, peer: &Peer, notice: PeerNotice) {
    let mut settled = peer.settled();
    hub.peer_notices.send((peer.name.clone(), peer.generation, notice)).await.unwrap();
    settled.changed().await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn short_peer_flap_keeps_rows_and_emits_no_status_events() {
    let (hub, peer, rows) = fixture();
    let mut events = hub.events.subscribe();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    tokio::time::advance(Duration::from_secs(9)).await;
    assert_eq!(hub.resolve_remote("live").unwrap().2["status"], "ready");
    hub.peer_notices
        .send((peer.name.clone(), peer.generation, PeerNotice::Sessions(rows)))
        .await
        .unwrap();
    send(&hub, &peer, PeerNotice::Connected).await;
    tokio::time::advance(Duration::from_secs(2)).await;
    tokio::task::yield_now().await;
    assert!(events.try_recv().is_err(), "a short flap must emit zero row events");
    assert_eq!(hub.resolve_remote("done").unwrap().2["status"], "closed");
}

#[tokio::test(start_paused = true)]
async fn persistent_drop_marks_only_live_rows_and_retries_do_not_extend_grace() {
    let (hub, peer, _) = fixture();
    let mut events = hub.events.subscribe();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    tokio::time::advance(Duration::from_secs(6)).await;
    send(&hub, &peer, PeerNotice::Disconnected("retry failed".into())).await;
    tokio::time::advance(Duration::from_secs(5)).await;
    tokio::task::yield_now().await;
    assert_eq!(hub.resolve_remote("live").unwrap().2["status"], "unreachable");
    assert_eq!(hub.resolve_remote("done").unwrap().2["status"], "closed");
    assert_eq!(events.try_recv().unwrap().session_id, "live");
    assert!(events.try_recv().is_err(), "closed rows must never be announced on a drop");
}

#[tokio::test(start_paused = true)]
async fn replaced_peer_ignores_old_drop_deadline() {
    let (hub, peer, rows) = fixture();
    let mut events = hub.events.subscribe();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    let replacement = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    hub.peers.lock().unwrap().insert(peer.name.clone(), replacement.clone());
    hub.apply_peer_notice(&peer.name, replacement.generation, PeerNotice::Sessions(rows));
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::task::yield_now().await;
    assert_eq!(hub.resolve_remote("live").unwrap().2["status"], "ready");
    assert!(events.try_recv().is_err());
}
