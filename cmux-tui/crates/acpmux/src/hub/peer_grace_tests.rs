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
    let (hub, peer, rows) = fixture();
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
    hub.peer_notices
        .send((peer.name.clone(), peer.generation, PeerNotice::Sessions(rows)))
        .await
        .unwrap();
    send(&hub, &peer, PeerNotice::Connected).await;
    assert_eq!(events.try_recv().unwrap().session_id, "live");
    assert!(events.try_recv().is_err(), "only the live row changed on reconnect");
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

#[tokio::test(start_paused = true)]
async fn peer_loop_never_consumes_the_daemons_pending_shutdown() {
    // No yield after construction: the notice loop has not registered a waiter
    // when shutdown is broadcast. The stored permit belongs to the daemon.
    let (hub, peer, _) = fixture();
    hub.peer_notices
        .send((peer.name.clone(), peer.generation, PeerNotice::Disconnected("reset".into())))
        .await
        .unwrap();
    hub.stop_idle_reaper();
    hub.shutdown.notify_waiters();
    hub.shutdown.notify_one();
    tokio::task::yield_now().await;
    tokio::time::timeout(Duration::from_secs(1), hub.shutdown.notified())
        .await
        .expect("peer loop stole the main daemon's shutdown permit");
}

fn disk_fixture() -> (Arc<Hub>, Arc<Peer>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pg");
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config, store);
    let peer = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    hub.peers.lock().unwrap().insert(peer.name.clone(), peer.clone());
    let rows = vec![json!({"sessionId":"live", "name":"live", "status":"ready"})];
    hub.apply_peer_notice(&peer.name, peer.generation, PeerNotice::Sessions(rows));
    // Within the save throttle of the list's save: not written yet.
    hub.apply_peer_notice(
        &peer.name,
        peer.generation,
        PeerNotice::SessionChanged {
            session: json!({"sessionId":"live", "name":"renamed", "status":"ready"}),
            kind: "status".into(),
            seq: 1,
        },
    );
    (hub, peer, dir)
}

fn saved_rows(dir: &cmux_unix_socket::TestDir) -> String {
    std::fs::read_to_string(dir.path().join("peers/remote.json")).unwrap()
}

#[tokio::test(start_paused = true)]
async fn drop_saves_throttled_row_changes_before_grace_ends() {
    // A daemon that stops inside the grace window still has, on disk, the row
    // change whose save was throttled before the drop.
    let (hub, peer, dir) = disk_fixture();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    hub.stop_idle_reaper();
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::task::yield_now().await;
    let saved = saved_rows(&dir);
    assert!(saved.contains("renamed"), "{saved}");
}

#[tokio::test(start_paused = true)]
async fn an_outages_first_drop_saves_even_after_the_link_counted_more_attempts() {
    // The loop reads a queued drop notice after the link may have failed its
    // next attempt too. The outage's first notice still saves.
    let (hub, peer, dir) = disk_fixture();
    peer.count_failed_attempt();
    peer.count_failed_attempt();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    hub.stop_idle_reaper();
    let saved = saved_rows(&dir);
    assert!(saved.contains("renamed"), "{saved}");
}

#[tokio::test(start_paused = true)]
async fn a_retry_that_refreshes_a_row_then_fails_starts_a_new_outage() {
    // After the grace ran out, a retry may deliver a row change before its
    // list and then fail. That row goes unreachable again, and its change is saved.
    let (hub, peer, dir) = disk_fixture();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::task::yield_now().await;
    assert_eq!(hub.resolve_remote("live").unwrap().2["status"], "unreachable");
    let refreshed = json!({"sessionId":"live", "name":"live", "status":"ready", "turnCount":7});
    hub.peer_notices
        .send((
            peer.name.clone(),
            peer.generation,
            PeerNotice::SessionChanged { session: refreshed, kind: "status".into(), seq: 2 },
        ))
        .await
        .unwrap();
    send(&hub, &peer, PeerNotice::Disconnected("retry failed".into())).await;
    assert_eq!(hub.resolve_remote("live").unwrap().2["status"], "ready");
    assert!(saved_rows(&dir).contains("\"turnCount\":7"), "{}", saved_rows(&dir));
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::task::yield_now().await;
    assert_eq!(hub.resolve_remote("live").unwrap().2["status"], "unreachable");
}

#[tokio::test(start_paused = true)]
async fn an_ended_outage_belongs_to_its_peer_instance() {
    // Past its deadline an outage is the instance's own state, so removing or
    // replacing the peer leaves nothing behind in the notice loop.
    let (hub, peer, _) = fixture();
    send(&hub, &peer, PeerNotice::Disconnected("reset".into())).await;
    tokio::time::advance(Duration::from_secs(11)).await;
    tokio::task::yield_now().await;
    assert!(peer.outage_ended.load(std::sync::atomic::Ordering::SeqCst));
    let replacement = Peer::new("remote", "ws://127.0.0.1:1", None, None, hub.peer_notices.clone());
    assert!(!replacement.outage_ended.load(std::sync::atomic::Ordering::SeqCst));
    send(&hub, &peer, PeerNotice::Connected).await;
    assert!(!peer.outage_ended.load(std::sync::atomic::Ordering::SeqCst), "a ready link ends it");
}
