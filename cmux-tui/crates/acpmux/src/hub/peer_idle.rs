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
#[path = "peer_idle_tests.rs"]
mod tests;
