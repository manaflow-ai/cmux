//! What one peer's paths did, read out: the paths and link counters of `_acpmux/peers`
//! (`peer_paths.rs`, `peer_path_stats.rs`) and the last-known-good entry kept on disk
//! (`peer_last_good.rs`).

use crate::peer::Peer;

impl Peer {
    /// `paths` of `_acpmux/peers`: every path's health and round trip (the live link's
    /// carrier is `carrier`, from `peer_carrier.rs`).
    pub(crate) fn paths_view(&self) -> serde_json::Value {
        self.with_paths(|paths| paths.view(crate::store::now_ms()))
    }

    /// `linkStats` of `_acpmux/peers`: this link's path counters (`peer_path_stats.rs`).
    pub(crate) fn link_stats_view(&self) -> serde_json::Value {
        self.with_paths(|paths| paths.stats_view(crate::store::now_ms()))
    }

    /// Remember the path the link is ready on, for the next run.
    pub(in crate::peer) fn note_ready_path(&self) {
        let (Some(via), Some(book)) = (self.serving(), self.last_good.get()) else { return };
        let endpoints = crate::peer_last_good::Endpoints {
            url: Some(crate::peer::lift_query_token(&self.url).0),
            link: self.link_host.get().cloned(),
            wireguard: self.wireguard_route().map(|(_, address)| address.to_string()),
        };
        let entry = self.with_paths(|paths| {
            crate::peer_last_good::Entry::of(paths, via, endpoints, crate::store::now_ms())
        });
        book.record(&self.name, entry);
    }
}
