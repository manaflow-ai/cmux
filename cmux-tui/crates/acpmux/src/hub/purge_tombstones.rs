//! Part of `Hub`; see `hub/mod.rs`. A peer's purge that its session list,
//! read before the purge, must not undo.
//!
//! A peer answers `_acpmux/watch` with a list it read before it answered,
//! while its watch already sends `session_changed` notices from another task
//! (`server/requests.rs` `MUX_WATCH`, `server/mod.rs` `deliver`): a session
//! purged after the list was read can have its purge written to the link
//! before the reply. The hub takes notices in the order the link gives them
//! (`peer.rs` `serve`), so the purge removes the row and the older list puts
//! it back. Every peer in the fleet answers this way, older daemons too, so
//! this daemon decides it: a purge it took on the link before that link's
//! list is a tombstone the list cannot revive.
//!
//! What can never be hidden: only a purge that comes before its link's list
//! is kept, and only until that list, so none outlives the list. A link that
//! ends with no list (`Disconnected`; the next link's list is read after the
//! purge, so a row in it was made again) drops its tombstones, and any other
//! notice of that session lifts its tombstone. A session made again under the
//! purged id after the peer started watching sends such a notice on this link
//! (`server/change_kind.rs`), so the list loses only rows the peer no longer
//! has, or one that notice puts back. A lag (`_acpmux/lagged`) changes
//! nothing here: the list is still older than the purge, and a dropped notice
//! leaves a row out of date on base too.
//!
//! Every change happens under the rows lock once the notice's instance was
//! found current (`Hub::is_current`), so a removed or replaced peer's late
//! notice never leaves an entry behind (`Hub::purge_peer_rows` forgets it).

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

/// Per peer, its current instance's link: whether that link's list came, and
/// the sessions it purged before. One entry per peer name, gone with the peer.
/// Lock order: `Hub::remote_sessions`, then this.
#[derive(Default)]
pub(crate) struct PurgeTombstones(Mutex<HashMap<String, Link>>);

struct Link {
    /// `Peer::generation`.
    generation: u64,
    listed: bool,
    purged: HashSet<String>,
}

impl PurgeTombstones {
    /// Runs `f` on instance `generation`'s link of peer `peer`. Generations only
    /// grow: a newer instance starts over, an older one's is never touched.
    fn with<T>(&self, peer: &str, generation: u64, f: impl FnOnce(&mut Link) -> T) -> Option<T> {
        let fresh = || Link { generation, listed: false, purged: HashSet::new() };
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let link = map.entry(peer.to_owned()).or_insert_with(fresh);
        if link.generation < generation {
            *link = fresh();
        }
        (link.generation == generation).then(|| f(link))
    }

    /// Instance `generation` of peer `peer` purged session `id`: its link's
    /// list, if it has not come yet, leaves `id` out.
    pub(super) fn purged(&self, peer: &str, generation: u64, id: &str) {
        self.with(peer, generation, |link| {
            if !link.listed {
                link.purged.insert(id.to_owned());
            }
        });
    }

    /// Any other notice of session `id`: the peer has it now.
    pub(super) fn changed(&self, peer: &str, generation: u64, id: &str) {
        self.with(peer, generation, |link| link.purged.remove(id));
    }

    /// The link ended: the next one's list is read after every purge so far.
    pub(super) fn link_ended(&self, peer: &str, generation: u64) {
        self.with(peer, generation, |link| {
            link.listed = false;
            link.purged.clear();
        });
    }

    /// The link's list is applied now: the sessions to leave out of it. None
    /// are kept after it.
    pub(super) fn take(&self, peer: &str, generation: u64) -> HashSet<String> {
        self.with(peer, generation, |link| {
            link.listed = true;
            std::mem::take(&mut link.purged)
        })
        .unwrap_or_default()
    }

    /// Peer `peer` left (`Hub::purge_peer_rows`).
    pub(super) fn forget(&self, peer: &str) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).remove(peer);
    }
}

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

        // A purge after the link's list is not kept: no older list comes on that link.
        hub.apply_peer_notice("builder", generation, list(&["y"]));
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        assert!(hub.purge_tombstones.0.lock().unwrap()["builder"].purged.is_empty());
        hub.apply_peer_notice("builder", generation, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["x", "y"], "a list after a purge that followed one");

        // A reconnect or another machine under the name is a new instance: the old one's
        // purge before its list holds for its list only.
        hub.apply_peer_notice("builder", generation, PeerNotice::Disconnected("reset".into()));
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        assert!(hub.purge_tombstones.0.lock().unwrap()["builder"].purged.contains("x"));
        let next = register(&hub, "builder");
        hub.apply_peer_notice("builder", next, list(&["x", "y"]));
        assert_eq!(rows(&hub, "builder"), ["x", "y"], "another instance's list");
    }

    /// A removed peer's purge that was queued before its removal keeps nothing.
    #[test]
    fn a_removed_peers_late_purge_keeps_nothing() {
        let hub = hub();
        let generation = register(&hub, "builder");
        hub.apply_peer_notice("builder", generation, changed("x", "purged"));
        hub.peers.lock().unwrap().remove("builder");
        hub.purge_peer_rows("builder");
        hub.apply_peer_notice("builder", generation, changed("z", "purged"));
        assert!(hub.purge_tombstones.0.lock().unwrap().is_empty());
    }
}
