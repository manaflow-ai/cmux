use super::*;

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test]
async fn a_lease_takes_only_a_loopback_or_tls_url() {
    let hub = hub();
    let cfg = crate::config::Config::default();
    for url in ["ws://10.0.0.5:4000", "ssh://me@host", "http://127.0.0.1:1", "ws://example.com"] {
        let e = hub.lease_peer("vm", url, "t".into(), None, false, &cfg).unwrap_err();
        assert!(e.message.contains("loopback"), "{url}: {}", e.message);
    }
    assert!(hub.lease_peer("vm", "ws://127.0.0.1:1", "t".into(), None, false, &cfg).is_ok());
    assert!(hub.lease_peer("vm2", "wss://example.com", "t".into(), None, false, &cfg).is_ok());
}

#[tokio::test]
async fn a_lease_never_takes_a_saved_peers_name() {
    let hub = hub();
    let mut cfg = crate::config::Config::default();
    cfg.peers.insert(
        "box".into(),
        crate::config::PeerConfig {
            link_host: None,
            wireguard: None,
            url: "ssh://box".into(),
            token: None,
            peer_token: None,
            vm_boundary: false,
            github_broker: false,
        },
    );
    let e = hub.lease_peer("box", "ws://127.0.0.1:1", "t".into(), None, false, &cfg).unwrap_err();
    assert!(e.message.contains("saved peer"), "{}", e.message);
}

#[tokio::test]
async fn ending_an_old_lease_leaves_its_renewal_running() {
    let hub = hub();
    let cfg = crate::config::Config::default();
    let (old, _) = hub.lease_peer("vm", "ws://127.0.0.1:1", "t".into(), None, false, &cfg).unwrap();
    let (new, _) = hub.lease_peer("vm", "ws://127.0.0.1:2", "t".into(), None, false, &cfg).unwrap();
    hub.end_peer_lease(&old);
    assert!(hub.is_leased("vm"));
    assert_eq!(hub.peers().len(), 1);
    assert_eq!(hub.peers()[0]["url"], "ws://127.0.0.1:2");
    assert_eq!(hub.peers()[0]["leased"], true);
    hub.end_peer_lease(&new);
    assert!(!hub.is_leased("vm"));
    assert!(hub.peers().is_empty());
    // Idempotent.
    hub.end_peer_lease(&new);
}

/// Leasing and listing peers at once never deadlock: `peers()` reads the
/// leases before it locks the peers, the order `lease_peer` takes them in.
/// Plain threads, so a deadlock fails the test instead of hanging it.
#[test]
fn leasing_while_listing_peers_never_deadlocks() {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let hub = {
        let _entered = runtime.enter();
        hub()
    };
    let (done, finished) = std::sync::mpsc::channel();
    {
        let (hub, done) = (hub.clone(), done.clone());
        std::thread::spawn(move || {
            for _ in 0..2_000 {
                let _ = hub.peers();
            }
            let _ = done.send(());
        });
    }
    {
        let handle = runtime.handle().clone();
        std::thread::spawn(move || {
            let _entered = handle.enter();
            let cfg = crate::config::Config::default();
            for _ in 0..2_000 {
                let (lease, _) = hub
                    .lease_peer("vm", "ws://127.0.0.1:1", "t".into(), None, false, &cfg)
                    .unwrap();
                hub.end_peer_lease(&lease);
            }
            let _ = done.send(());
        });
    }
    for _ in 0..2 {
        finished
            .recv_timeout(std::time::Duration::from_secs(60))
            .expect("leasing and listing peers deadlocked");
    }
}

/// A saved peer added under a leased name ends the lease and drops the
/// leased machine's rows.
#[tokio::test]
async fn a_saved_peer_takes_a_leased_name_over_and_drops_its_rows() {
    let hub = hub();
    let cfg = crate::config::Config::default();
    let (lease, _) =
        hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, false, &cfg).unwrap();
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
    hub.apply_peer_notice(
        "vm",
        lease.generation,
        crate::peer::PeerNotice::sessions_from_values(vec![row]),
    );
    hub.add_peer("vm", "ws://127.0.0.1:8", None, None, false).await.unwrap();
    assert!(!hub.is_leased("vm"));
    assert!(hub.remote_sessions().is_empty(), "{:?}", hub.remote_sessions());
    assert_eq!(hub.peers()[0]["url"], "ws://127.0.0.1:8");
    // The old lease's end leaves the saved peer alone.
    hub.end_peer_lease(&lease);
    assert_eq!(hub.peers().len(), 1);
}

/// A leased peer's sessions are listed but never saved as last-known
/// rows (`peer_cache.rs`), and they leave with the lease.
#[tokio::test]
async fn a_leased_peer_leaves_no_session_cache_and_its_rows_go_with_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pl");
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let (lease, _) =
        hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, false, &cfg).unwrap();
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
    hub.apply_peer_notice(
        "vm",
        lease.generation,
        crate::peer::PeerNotice::sessions_from_values(vec![row]),
    );
    assert_eq!(hub.remote_sessions().len(), 1);
    assert!(!dir.path().join("peers/vm.json").exists(), "a lease saved its sessions");
    hub.end_peer_lease(&lease);
    assert!(hub.remote_sessions().is_empty());
}

/// A notice of a peer instance that was replaced or removed after
/// `peer_notice_loop` checked it (the loop does not hold the lock its
/// rows are guarded by) adds no rows and saves no session cache: not
/// after a saved peer took a leased name over, not after the lease
/// ended, and not after `peer_remove`.
#[tokio::test]
async fn a_replaced_instances_late_notice_adds_no_rows_and_saves_no_cache() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-pl");
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "updatedAt": 5});
    let changed =
        || PeerNotice::SessionChanged { session: row.clone(), kind: "status".into(), seq: 1 };
    let assert_clean = |path: &str| {
        assert!(hub.remote_sessions().is_empty(), "{path}: {:?}", hub.remote_sessions());
        let cache = dir.path().join("peers");
        let saved: Vec<_> = std::fs::read_dir(&cache)
            .map(|d| d.flatten().map(|e| e.file_name()).collect())
            .unwrap_or_default();
        assert!(saved.is_empty(), "{path}: a stale notice saved {saved:?}");
    };

    // A saved peer takes the leased name over.
    let (lease, _) =
        hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, false, &cfg).unwrap();
    hub.add_peer("vm", "ws://127.0.0.1:8", None, None, false).await.unwrap();
    hub.apply_peer_notice(
        "vm",
        lease.generation,
        PeerNotice::sessions_from_values(vec![row.clone()]),
    );
    hub.apply_peer_notice("vm", lease.generation, changed());
    assert_clean("saved peer took over");

    // The lease ended.
    let (lease, _) =
        hub.lease_peer("vm2", "ws://127.0.0.1:9", "t".into(), None, false, &cfg).unwrap();
    hub.end_peer_lease(&lease);
    hub.apply_peer_notice(
        "vm2",
        lease.generation,
        PeerNotice::sessions_from_values(vec![row.clone()]),
    );
    hub.apply_peer_notice("vm2", lease.generation, changed());
    assert_clean("lease ended");

    // A saved peer was removed.
    hub.add_peer("box", "ws://127.0.0.1:7", None, None, false).await.unwrap();
    let generation = hub.peer_by_name("box").unwrap().generation;
    hub.remove_peer("box").await.unwrap();
    hub.apply_peer_notice("box", generation, PeerNotice::sessions_from_values(vec![row.clone()]));
    hub.apply_peer_notice("box", generation, changed());
    assert_clean("peer removed");
}

/// `peer_remove` of a leased name is refused and leaves config.json
/// alone: a lease is never written to config, and the connection that
/// holds it ends it.
#[tokio::test]
async fn removing_a_leased_peer_is_refused_and_never_touches_config() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pl");
    let path = dir.path().join("config.json");
    // Not the form `Config::save` writes, so any save shows.
    std::fs::write(&path, "{}").unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    cfg.path = Some(path.clone());
    let store = crate::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let (lease, _) =
        hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, false, &cfg).unwrap();
    let e = hub.remove_peer("vm").await.unwrap_err();
    assert!(e.message.contains("leased"), "{}", e.message);
    assert!(
        !hub.peer_cache_writers.lock().unwrap().contains_key("vm"),
        "a refused leased removal leaked its cache writer"
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{}", "peer_remove saved config");
    assert!(hub.is_leased("vm"));
    assert_eq!(hub.peers().len(), 1, "{:?}", hub.peers());
    // The lease still ends with its connection.
    hub.end_peer_lease(&lease);
    assert!(hub.peers().is_empty());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{}");
}
