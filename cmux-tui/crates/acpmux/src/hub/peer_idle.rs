//! The hub's side of a peer that costs nothing until used (`peer_demand.rs`): which saved chats
//! dial their peer at start, and what a link that closed unused leaves behind.

use super::*;

/// Whether a saved row is a chat that was working or waiting on a person when this daemon last
/// saw it (`indicator`, `hub/views.rs`): its peer is read ahead at start, not left undialed.
pub(super) fn live(summary: &Value) -> bool {
    matches!(summary.get("indicator").and_then(Value::as_str), Some("working" | "input"))
}

impl Hub {
    /// Peer `peer`'s link closed because nothing used it (`PeerNotice::Idle`). Its chats stay
    /// listed as last known, as at start before a dial (`peer_cache.rs` `mark_stale`); it is no
    /// outage: no drop is noted, no grace runs, and the cache keeps no outage for it. Channels
    /// that rode the link end for their local side, as at any end of a link.
    pub(super) fn peer_went_idle(&self, peer: &str, generation: u64) {
        crate::server::channels::link_lost(self, peer, generation);
        let Some(current) = self.peer(peer).filter(|p| p.generation == generation) else {
            return;
        };
        current.rows_ready.store(false, std::sync::atomic::Ordering::SeqCst);
        self.peer_snapshots.flush(Some(peer));
        self.mark_peer_unreachable(peer, generation);
    }
}

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

    #[test]
    fn only_a_working_or_asking_chat_reads_its_peer_ahead() {
        assert!(live(&json!({"indicator": "working"})));
        assert!(live(&json!({"indicator": "input"})));
        for idle in [json!({"indicator": "done"}), json!({"indicator": null}), json!({})] {
            assert!(!live(&idle), "{idle}");
        }
    }
}
