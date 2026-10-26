//! Part of `Hub`; see `hub/mod.rs`. A peer's purge that its session list,
//! read before the purge, must not undo.

#[cfg(test)]
mod tests {
    use crate::hub::Hub;
    use crate::peer::{Peer, PeerNotice};
    use serde_json::{Value, json};
    use std::sync::Arc;

    fn hub() -> Arc<Hub> {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    /// Registers a new instance of peer `name`, as `add_peer` or a reconnect does.
    fn register(hub: &Hub, name: &str) -> u64 {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let p = Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), p.clone());
        p.generation
    }

    fn row(id: &str) -> Value {
        json!({"sessionId": id, "name": format!("lane-{id}"), "status": "idle", "turnCount": 1, "updatedAt": 5})
    }

    fn list(ids: &[&str]) -> PeerNotice {
        PeerNotice::Sessions(ids.iter().map(|id| row(id)).collect())
    }

    fn changed(id: &str, kind: &str) -> PeerNotice {
        let session = if kind == "purged" { json!({"sessionId": id}) } else { row(id) };
        PeerNotice::SessionChanged { session, kind: kind.to_owned(), seq: 2 }
    }

    /// The bare ids of peer `peer`'s rows, sorted.
    fn rows(hub: &Hub, peer: &str) -> Vec<String> {
        let mut ids: Vec<String> = hub
            .remote_sessions
            .lock()
            .unwrap()
            .values()
            .filter(|r| r.peer == peer)
            .map(|r| r.receipt.mux_session_id.clone())
            .collect();
        ids.sort();
        ids
    }

    /// The peer read its list for `_acpmux/watch`, then purged `x` and wrote the purge's
    /// notice before the reply: the list that comes after the purge does not put `x` back.
    #[test]
    fn a_list_read_before_a_purge_does_not_bring_the_purged_session_back() {
        let hub = hub();
        let generation = register(&hub, "builder");
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        // The link drops; the next one's purge of `x` comes before its list.
        hub.apply_peer_notice("builder", generation, PeerNotice::Disconnected("reset".into()));
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        assert_eq!(rows(&hub, "builder"), ["y"]);
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["y"], "the older list put the purged session back");
        // On a first link too, with no row of `x` before its purge.
        let hub = self::hub();
        let generation = register(&hub, "builder");
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["y"]);
    }

    /// A session the peer made again under the purged id after the purge said so before the
    /// list: the list keeps it.
    #[test]
    fn a_session_made_again_after_its_purge_stays_listed() {
        let hub = hub();
        let generation = register(&hub, "builder");
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        hub.apply_peer_notice("builder", generation, changed("x", "created"));
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["x", "y"]);
    }

    /// A purge holds only until the list it came before: a later list, the next link's list,
    /// and another instance's list each list what they list.
    #[test]
    fn a_purge_hides_nothing_from_a_later_list() {
        let hub = hub();
        let generation = register(&hub, "builder");
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        hub.apply_peer_notice("builder", generation, list(&["y"]));
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["x", "y"], "a list after the one the purge came before");

        // A purge on a link that ends: the next link's list was read after it, so an `x` in it
        // was made again before that link watched, and no notice of it comes.
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        hub.apply_peer_notice("builder", generation, PeerNotice::Disconnected("reset".into()));
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["x", "y"], "the next link's list");

        // A reconnect or another machine under the name is a new instance.
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        let next = register(&hub, "builder");
        hub.apply_peer_notice("builder", next, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["x", "y"], "another instance's list");
    }
}
