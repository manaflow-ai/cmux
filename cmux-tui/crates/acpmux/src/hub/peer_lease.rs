//! Part of `Hub`; see `hub/mod.rs`. A leased peer: a peer that lasts only as
//! long as the unix socket connection that leased it (`_acpmux/peer_lease`).
//!
//! The Cloud link reaches a Cloud VM's acpmux through a local port forward
//! of its remote tunnel (`ws://127.0.0.1:<ephemeral>`), which is gone once
//! the link process ends. A saved peer (`peer_add`) would keep reconnecting
//! to that port after the tunnel closed, and any local process that later
//! bound the port would receive the VM's dashboard and peer tokens. So a
//! lease is never written to config.json, leaves no last-known sessions on
//! disk (`peer_cache.rs`), and stops with its connection
//! (`Conn::end_peer_leases` in `server/mod.rs`).
//!
//! Lock order: `peer_leases`, then `remote_sessions`, then `peers`; never
//! the other way round. A peer leaves the `peers` registry before its rows
//! are dropped, and a notice changes rows only while its instance is still
//! registered (`apply_peer_notice` checks under the rows lock), so a late
//! notice of a replaced or removed peer never adds rows back.

use super::*;

/// One lease a connection holds: the peer it started, by name and
/// generation. Ending it stops that peer only while it is still the one
/// registered under the name (a newer lease or a saved peer took it over
/// otherwise).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerLease {
    pub name: String,
    pub generation: u64,
}

impl Hub {
    /// Lease peer `name` at `url`: a `wss://` URL, or `ws://` to a loopback
    /// host (the only transports that may carry the peer token,
    /// `peer::carries_peer_token`). Refused for the name of a saved peer.
    /// A lease of a name already leased replaces that peer (the caller
    /// renews it with fresh tokens). Returns the lease and the peer's
    /// settled receiver. `vm_boundary`: the caller's own opt-out for this
    /// peer's remote chains (`vm_boundary.rs`), held with the lease only.
    pub fn lease_peer(
        &self,
        name: &str,
        url: &str,
        token: String,
        peer_token: Option<String>,
        vm_boundary: bool,
        saved: &crate::config::Config,
    ) -> Result<(PeerLease, tokio::sync::watch::Receiver<u64>), RpcError> {
        crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
        if !(url.starts_with("ws://") || url.starts_with("wss://"))
            || !crate::peer::carries_peer_token(url)
        {
            return Err(RpcError::invalid_params(
                "a leased peer's url must be wss:// or ws:// to a loopback host",
            ));
        }
        if saved.peers.contains_key(name) {
            return Err(RpcError::invalid_params(format!(
                "{name:?} is a saved peer; a lease takes a name of its own"
            )));
        }
        let pc = crate::config::PeerConfig {
            wireguard: None,
            url: url.to_owned(),
            token: Some(token),
            peer_token,
            vm_boundary,
            // A Cloud VM gets its own GitHub App token; the Mac's login is not lent to it.
            github_broker: false,
        };
        // Held while the peer starts, so none of its notices finds it unleased
        // and saves its sessions (`save_peer_cache`).
        let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        let (generation, settled) = self.spawn_peer(name, &pc, false);
        leases.insert(name.to_owned(), generation);
        drop(leases);
        tracing::info!(peer = %name, "peer leased");
        Ok((PeerLease { name: name.to_owned(), generation }, settled))
    }

    /// End `lease`: stop its peer and drop its rows, unless the name now
    /// belongs to another peer. Idempotent.
    pub fn end_peer_lease(&self, lease: &PeerLease) {
        // Both under the lease lock, the peer first: a notice of the peer
        // finds it leased or gone, never unleased (`save_peer_cache`).
        let peer = {
            let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            let peer = {
                let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
                match peers.get(&lease.name) {
                    Some(p) if p.generation == lease.generation => peers.remove(&lease.name),
                    _ => None,
                }
            };
            if leases.get(&lease.name) == Some(&lease.generation) {
                leases.remove(&lease.name);
            }
            peer
        };
        let Some(peer) = peer else { return };
        peer.stop();
        self.note_peer_removed(&peer);
        self.purge_peer_rows(&lease.name);
        tracing::info!(peer = %lease.name, "peer lease ended");
    }

    /// Whether `name` is a leased peer now.
    pub fn is_leased(&self, name: &str) -> bool {
        self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).contains_key(name)
    }
}

#[cfg(test)]
mod tests {
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
        for url in ["ws://10.0.0.5:4000", "ssh://me@host", "http://127.0.0.1:1", "ws://example.com"]
        {
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
                wireguard: None,
                url: "ssh://box".into(),
                token: None,
                peer_token: None,
                vm_boundary: false,
                github_broker: false,
            },
        );
        let e =
            hub.lease_peer("box", "ws://127.0.0.1:1", "t".into(), None, false, &cfg).unwrap_err();
        assert!(e.message.contains("saved peer"), "{}", e.message);
    }

    #[tokio::test]
    async fn ending_an_old_lease_leaves_its_renewal_running() {
        let hub = hub();
        let cfg = crate::config::Config::default();
        let (old, _) =
            hub.lease_peer("vm", "ws://127.0.0.1:1", "t".into(), None, false, &cfg).unwrap();
        let (new, _) =
            hub.lease_peer("vm", "ws://127.0.0.1:2", "t".into(), None, false, &cfg).unwrap();
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
        hub.apply_peer_notice("vm", lease.generation, crate::peer::PeerNotice::Sessions(vec![row]));
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
        hub.apply_peer_notice("vm", lease.generation, crate::peer::PeerNotice::Sessions(vec![row]));
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
        hub.apply_peer_notice("vm", lease.generation, PeerNotice::Sessions(vec![row.clone()]));
        hub.apply_peer_notice("vm", lease.generation, changed());
        assert_clean("saved peer took over");

        // The lease ended.
        let (lease, _) =
            hub.lease_peer("vm2", "ws://127.0.0.1:9", "t".into(), None, false, &cfg).unwrap();
        hub.end_peer_lease(&lease);
        hub.apply_peer_notice("vm2", lease.generation, PeerNotice::Sessions(vec![row.clone()]));
        hub.apply_peer_notice("vm2", lease.generation, changed());
        assert_clean("lease ended");

        // A saved peer was removed.
        hub.add_peer("box", "ws://127.0.0.1:7", None, None, false).await.unwrap();
        let generation = hub.peer_by_name("box").unwrap().generation;
        hub.remove_peer("box").await.unwrap();
        hub.apply_peer_notice("box", generation, PeerNotice::Sessions(vec![row.clone()]));
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
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{}", "peer_remove saved config");
        assert!(hub.is_leased("vm"));
        assert_eq!(hub.peers().len(), 1, "{:?}", hub.peers());
        // The lease still ends with its connection.
        hub.end_peer_lease(&lease);
        assert!(hub.peers().is_empty());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{}");
    }
}
