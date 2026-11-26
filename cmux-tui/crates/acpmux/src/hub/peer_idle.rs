//! The hub's side of a peer that costs nothing until used (`peer_demand.rs`): which saved chats
//! dial their peer at start, and what a link that closed unused leaves behind.

use super::*;

/// Whether a saved row is a chat that was working or waiting on a person when this daemon last
/// saw it (`indicator`, `hub/views.rs`): its peer is read ahead at start, not left undialed.
pub(super) fn live(summary: &Value) -> bool {
    matches!(summary.get("indicator").and_then(Value::as_str), Some("working" | "input"))
}

/// One route index for a shared outbox snapshot and the remote names it resolved against. Only
/// short and former names can be shadowed by local sessions, so check those on their peer alone.
#[derive(Default)]
pub(super) struct PendingRoutes {
    targets: Option<Arc<outbox::PendingTargets>>,
    route_changes: u64,
    #[cfg(test)]
    routes_checked: usize,
    direct: HashSet<String>,
    shadowable: HashMap<String, Vec<(String, peers::RemoteName)>>,
}

impl PendingRoutes {
    fn update(&mut self, targets: &Arc<outbox::PendingTargets>, rows: &remote_rows::RemoteRows) {
        if self.route_changes == rows.route_changes
            && self.targets.as_ref().is_some_and(|old| Arc::ptr_eq(old, targets))
        {
            return;
        }
        self.direct.clear();
        self.shadowable.clear();
        #[cfg(test)]
        {
            self.routes_checked += targets.targets.len();
        }
        for key in &targets.targets {
            if let Some((row, name)) = peers::remote_match(rows, key) {
                match name {
                    peers::RemoteName::Direct => {
                        self.direct.insert(row.peer.clone());
                    }
                    name => self
                        .shadowable
                        .entry(row.peer.clone())
                        .or_default()
                        .push((key.clone(), name)),
                }
            }
        }
        self.targets = Some(Arc::clone(targets));
        self.route_changes = rows.route_changes;
    }
}

impl Hub {
    /// Whether `peer`'s quiet link is still in use, so it stays open past the idle bound
    /// (`peer_demand.rs` `Keeper`): a connection attached to one of its chats (an open chat), or
    /// a delivery for one of its chats not settled yet. Asked on the link's tick only once it is
    /// otherwise due to close.
    pub(crate) fn keeps_peer(&self, peer: &crate::peer::Peer) -> bool {
        let router = self.fanout_router();
        if peer.attached_chats().iter().any(|id| router.hears(id)) {
            return true;
        }
        let Some(targets) = self.outbox.pending_targets() else { return true };
        if targets.pins.contains(&peer.name) {
            return true;
        }
        if targets.targets.is_empty() || self.peer(&peer.name).is_none() {
            return false;
        }
        // A concurrent check is already indexing: keep this link for one more tick.
        let Ok(mut routes) = self.pending_peer_routes.try_lock() else { return true };
        routes.update(&targets, &self.remote_sessions.read());
        routes.direct.contains(&peer.name)
            || routes
                .shadowable
                .get(&peer.name)
                .is_some_and(|names| names.iter().any(|(key, name)| name.available(self, key)))
    }

    /// Peer `peer`'s link closed because nothing used it (`PeerNotice::Idle`). Its chats stay
    /// listed as last known, as at start before a dial (`peer_cache.rs` `mark_stale`); it is no
    /// outage: no drop is noted, no grace runs, and the cache keeps no outage for it. Channels
    /// that rode the link end for their local side, as at any end of a link.
    pub(super) fn peer_went_idle(&self, peer: &str, generation: u64) {
        crate::server::channels::link_lost(self, peer, generation);
        let Some(current) = self.peer(peer).filter(|p| p.generation == generation) else {
            return;
        };
        {
            let _rows = self.remote_sessions.fence();
            current.rows_ready.store(false, std::sync::atomic::Ordering::SeqCst);
            current.purge_tombstones.link_ended();
        }
        self.peer_snapshots.flush(Some(peer));
        self.mark_peer_unreachable(peer, generation);
    }
}

#[cfg(test)]
#[path = "peer_idle_fixture_tests.rs"]
mod fixture;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use crate::peer::test_dial;

    /// A daemon starting with 130 saved peers dials none of them, but the one whose chat was
    /// working when it stopped: that chat is read ahead. (A Mac's daemon started after a crash on
    /// 2026-11-24 dialed all its 130 within seconds.)
    #[tokio::test]
    async fn a_daemon_start_dials_only_the_peer_whose_chat_was_working() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-peer-on-use");
        let peers_dir = dir.path().join("peers");
        std::fs::create_dir_all(&peers_dir).unwrap();
        let row = |id: &str, host: &str, indicator: &str| {
            json!({
                "sessionId": id, "name": id, "status": "running", "indicator": indicator,
                "updatedAt": 5,
                "sessionReceipt": {"hostId": host, "muxSessionId": id, "agentSessionId": null,
                    "generation": 1},
            })
        };
        for (name, indicator) in [("m7", "working"), ("m8", "done")] {
            let saved =
                json!({"lastSeen": 7, "sessions": [row(&format!("{name}-chat"), name, indicator)]});
            std::fs::write(
                peers_dir.join(format!("{name}.json")),
                serde_json::to_vec(&saved).unwrap(),
            )
            .unwrap();
        }
        let mut config = Config::default();
        config.store.mode = StoreMode::Local;
        for i in 0..130 {
            let url = json!({"url": format!("ws://127.0.0.1:9/m{i}")});
            config.peers.insert(format!("m{i}"), serde_json::from_value(url).unwrap());
        }
        let store = crate::store::open(&config.store, dir.path()).unwrap();
        let hub =
            Hub::build(config, store, crate::mailbox::Mailbox::memory(), false, false, None, false);
        test_dial::refuse_all();
        hub.start_saved_peers().await;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        // Its dial fails at once here and it redials while wanted, so count peers, not dials.
        assert!(!test_dial::attempts().is_empty(), "the working chat's peer dials");
        let dialed: Vec<String> = (0..130)
            .map(|i| format!("m{i}"))
            .filter(|name| hub.peer_by_name(name).is_some_and(|p| !p.idle_parked()))
            .collect();
        assert_eq!(dialed, ["m7"], "every other peer waits to be used");
        // Its rows are listed as last known meanwhile.
        let rows = hub.remote_sessions();
        assert!(rows.iter().any(|r| r["sessionId"] == "m8-chat" && r["stale"] == true), "{rows:?}");
        test_dial::clear();
        hub.begin_shutdown();
    }

    /// A quiet link stays while a connection is attached to one of its chats or a delivery for
    /// it is not settled; with neither, nothing keeps it (`Hub::keeps_peer`).
    #[tokio::test]
    async fn an_attached_client_or_a_pending_delivery_keeps_a_peer_and_neither_does_not() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-peer-kept");
        let mut config = Config::default();
        config.store.mode = StoreMode::Local;
        let store = crate::store::open(&config.store, dir.path()).unwrap();
        let hub = Hub::new(config, store);
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        let peer = crate::peer::Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        assert!(!hub.keeps_peer(&peer), "nothing open, nothing pending");

        // A client opens one of its chats, and closes it again.
        peer.mark_attached("chat-1");
        assert!(!hub.keeps_peer(&peer), "a mark alone outlives its client: no one listens");
        let router = hub.fanout_router();
        let inbox = router.inbox();
        router.attach(&inbox, "chat-1");
        assert!(hub.keeps_peer(&peer), "an open chat keeps its link");
        router.forget(&inbox);
        assert!(!hub.keeps_peer(&peer), "the chat closed");

        // A delivery for it waits, then settles.
        hub.outbox.add(delivery()).unwrap();
        assert!(hub.keeps_peer(&peer), "a pending delivery keeps its link");
        hub.outbox.update("d1", |d| d.state = crate::hub::outbox::State::Failed);
        assert!(!hub.keeps_peer(&peer), "a settled one does not");
        hub.begin_shutdown();
    }

    fn delivery() -> crate::hub::outbox::Delivery {
        crate::hub::outbox::Delivery {
            id: "d1".into(),
            target: "box/chat-1".into(),
            request: json!({"sessionId": "box/chat-1", "_meta": {"acpmux": {"promptId": "p"}}}),
            caller: None,
            unproven_caller: None,
            not_terminal: false,
            state: crate::hub::outbox::State::Queued,
            attempts: 0,
            never_sent: true,
            resends: 0,
            resent_at: 0,
            relay_post: None,
            open_on_peer: false,
            pin: Some(crate::hub::outbox::Pin {
                peer: "box".into(),
                session: "chat-1".into(),
                generation: 1,
                link: (1, 1),
            }),
            proof: None,
            error: None,
            accepted: None,
            created_at: 1,
            updated_at: 1,
        }
    }

    #[tokio::test]
    async fn a_thousand_quiet_peers_share_one_pass_over_a_thousand_pending_routes() {
        let hub = former_names::tests::hub();
        let dir = cmux_unix_socket::short_test_dir("acpmux-pending-routes");
        let path = dir.path().join("outbox.json");
        let mut deliveries = std::collections::BTreeMap::new();
        let mut peers = Vec::new();
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        let mut rows = Vec::new();
        for i in 0..1000 {
            let host = format!("m{i}");
            let id = format!("chat-{i}");
            let peer = crate::peer::Peer::new(&host, "ws://127.0.0.1:9", None, None, tx.clone());
            hub.peers.lock().unwrap().insert(host.clone(), Arc::clone(&peer));
            peers.push(peer);
            let receipt = crate::session_identity::SessionReceipt::new(&host, &id, None, 1);
            let route = receipt.qualified_id();
            rows.push((
                route.clone(),
                RemoteSession {
                    peer: host,
                    receipt,
                    summary: json!({"name": id, "status": "idle"}).into(),
                },
            ));
            let mut d = delivery();
            d.id = id;
            d.target = route;
            d.pin = None;
            deliveries.insert(d.id.clone(), d);
        }
        {
            let mut saved = hub.remote_sessions.write();
            for (key, row) in rows {
                saved.insert(key, row);
            }
        }
        std::fs::write(&path, serde_json::to_vec(&deliveries).unwrap()).unwrap();
        assert_eq!(hub.outbox.open(&path).len(), 1000);
        for _ in 0..2 {
            assert!(peers.iter().all(|peer| hub.keeps_peer(peer)));
        }
        assert_eq!(hub.pending_peer_routes.lock().unwrap().routes_checked, 1000);
        // A changed remote candidate, with no delivery change, invalidates the membership.
        let gone = deliveries["chat-0"].target.clone();
        hub.remote_sessions.write().remove(&gone);
        assert!(!hub.keeps_peer(&peers[0]));
        assert!(hub.keeps_peer(&peers[1]));
        assert_eq!(hub.pending_peer_routes.lock().unwrap().routes_checked, 2000);
        hub.begin_shutdown();
    }

    #[tokio::test]
    async fn a_pending_former_name_follows_renames_and_local_shadowing_without_a_new_delivery() {
        let hub = former_names::tests::hub();
        let (tx, _rx) = tokio::sync::mpsc::channel(1);
        let peer = crate::peer::Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(peer.name.clone(), Arc::clone(&peer));
        let mut d = delivery();
        d.target = "old".into();
        d.pin = None;
        hub.outbox.add(d).unwrap();
        let rename = |former: &[&str]| {
            hub.remote_sessions.write().insert(
                "box/chat".into(),
                RemoteSession {
                    peer: "box".into(),
                    receipt: crate::session_identity::SessionReceipt::new("box", "chat", None, 1),
                    summary: json!({"name":"current", "status":"idle", "formerNames": former})
                        .into(),
                },
            );
        };
        rename(&[]);
        assert!(!hub.keeps_peer(&peer));
        rename(&["old"]);
        assert!(hub.keeps_peer(&peer));
        rename(&["different"]);
        assert!(!hub.keeps_peer(&peer));
        rename(&["old"]);
        assert!(hub.keeps_peer(&peer));
        let checked = hub.pending_peer_routes.lock().unwrap().routes_checked;
        former_names::tests::chat(&hub, "local-id", "old");
        assert!(!hub.keeps_peer(&peer));
        assert_eq!(hub.pending_peer_routes.lock().unwrap().routes_checked, checked);
        hub.begin_shutdown();
    }

    #[test]
    fn only_a_working_or_asking_chat_reads_its_peer_ahead() {
        assert!(live(&json!({"indicator": "working"})));
        assert!(live(&json!({"indicator": "input"})));
        for idle in [json!({"indicator": "done"}), json!({"indicator": null}), json!({})] {
            assert!(!live(&idle), "{idle}");
        }
    }
}
