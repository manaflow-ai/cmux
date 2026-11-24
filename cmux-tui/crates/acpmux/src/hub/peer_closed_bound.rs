//! Part of `Hub`; see `hub/mod.rs`. How many of a peer's closed chats this daemon keeps: the
//! [`CLOSED_KEPT`] newest a peer lists (by `updatedAt`), every live one, and none older.
//!
//! A peer lists its whole history, closed chats included, and this daemon kept every row each
//! peer listed for as long as the peer did. On huge-blue (2026-11-19), linked to 25 peers, that
//! was 10,948 rows, 10,163 of them closed (8,477 untouched for over a week) and 10,923 of them
//! other machines': every list, each peer's relist and cache save, and each list page walked and
//! copied history that grows with every chat the fleet ever closed (the daemon held 11 to 15 GB
//! resident, and its paged list took 2.5 to 3 s). Leo: "Root-fix anything slow, stalling,
//! uncached or growing." Kept this way, a peer costs its live chats and [`CLOSED_KEPT`] more,
//! whatever its age.
//!
//! The bound is applied wherever a peer's rows come in: its whole list (`PeerNotice::Sessions`,
//! a follow's patch too), a row that closes (`PeerNotice::SessionChanged`), and the rows saved
//! from before a restart (`peer_cache.rs`). A row past it goes as a purge does (watchers hear it
//! went); the chat itself stays on its machine, which still lists it and answers for it there.

use super::*;
use std::collections::HashSet;

/// Closed chats kept for each peer, its newest; a live chat is always kept.
pub(crate) const CLOSED_KEPT: usize = if cfg!(test) { 4 } else { 64 };

/// What the bound reads of a row.
pub(super) struct Closed<K> {
    pub(super) key: K,
    pub(super) closed: bool,
    pub(super) updated: u64,
}

/// The keys of the closed rows past the [`CLOSED_KEPT`] newest (by `updatedAt`, then key, so a
/// tie is cut the same way each time).
pub(super) fn past_bound<K: Ord + Clone + std::hash::Hash>(
    rows: impl IntoIterator<Item = Closed<K>>,
) -> HashSet<K> {
    let mut closed: Vec<(u64, K)> =
        rows.into_iter().filter(|r| r.closed).map(|r| (r.updated, r.key)).collect();
    if closed.len() <= CLOSED_KEPT {
        return HashSet::new();
    }
    closed.sort_unstable_by(|a, b| b.cmp(a));
    closed.split_off(CLOSED_KEPT).into_iter().map(|(_, key)| key).collect()
}

/// A row's status and `updatedAt`, read from its text without building it.
#[derive(serde::Deserialize)]
struct Stamp {
    #[serde(default)]
    status: Option<String>,
    #[serde(rename = "updatedAt", default)]
    updated_at: Option<u64>,
}

/// The indexes of `list`'s rows (each a row's text, as a peer lists it) past the bound.
pub(super) fn listed_past_bound(list: &[Arc<str>]) -> HashSet<usize> {
    past_bound(list.iter().enumerate().map(|(key, text)| {
        let stamp = serde_json::from_str::<Stamp>(text).ok();
        let stamp = stamp.as_ref();
        Closed {
            key,
            closed: stamp.and_then(|s| s.status.as_deref()) == Some("closed"),
            updated: stamp.and_then(|s| s.updated_at).unwrap_or_default(),
        }
    }))
}

/// The summaries of `rows` (saved ones, `peer_cache.rs`) past the bound, by index.
pub(super) fn summaries_past_bound(rows: &[Value]) -> HashSet<usize> {
    past_bound(rows.iter().enumerate().map(|(key, row)| Closed {
        key,
        closed: row.get("status").and_then(Value::as_str) == Some("closed"),
        updated: row.get("updatedAt").and_then(Value::as_u64).unwrap_or_default(),
    }))
}

impl Hub {
    /// Applies a peer's notice (`peers.rs` `apply_peer_notice_rows`). When a follow's patch or a
    /// changed row takes one of the peer's closed rows out from under the bound (a purge, or a
    /// closed chat that runs again), a closed row this daemon left out may now be among the
    /// newest [`CLOSED_KEPT`]. A later follow rebuilds the list from the rows held here and
    /// cannot bring it back, so the peer's list position is dropped and its next link reads the
    /// whole list, which the bound picks from again.
    pub(super) fn apply_peer_notice(
        &self,
        peer: &str,
        generation: u64,
        notice: crate::peer::PeerNotice,
    ) {
        use crate::peer::PeerNotice;
        // A changed row can take a closed row away only when the row held for it is closed (it
        // is purged or runs again); a live or new one cannot, so the count, a walk over every
        // row of the peer, is skipped for those: nearly every change during a busy turn.
        let watched = match &notice {
            PeerNotice::SessionsPatch { .. } => true,
            PeerNotice::SessionChanged { session, .. } => {
                session.get("sessionId").and_then(Value::as_str).is_some_and(|mux| {
                    self.remote_sessions
                        .read()
                        .find_mux(peer, mux)
                        .is_some_and(|(_, row)| row.summary.closed())
                })
            }
            _ => false,
        };
        let before = watched.then(|| self.held_closed_peer_rows(peer));
        self.apply_peer_notice_rows(peer, generation, notice);
        let Some(before) = before else { return };
        if before >= CLOSED_KEPT
            && self.held_closed_peer_rows(peer) < CLOSED_KEPT
            && let Some(current) = self.peer(peer).filter(|p| p.generation == generation)
        {
            current.forget_list_cursor();
        }
    }

    /// How many of peer `peer`'s rows held here are closed.
    fn held_closed_peer_rows(&self, peer: &str) -> usize {
        self.remote_sessions.read().of_peer(peer).filter(|(_, row)| row.summary.closed()).count()
    }

    /// Drops peer `peer`'s closed rows past the bound, while `generation` is the instance
    /// registered under that name, and tells watchers they went. Called when one of its rows
    /// closes: that is the only change that can add a closed row, so the bound holds between
    /// whole lists too.
    pub(super) fn trim_closed_peer_rows(&self, peer: &str, generation: u64) {
        let gone = {
            let peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
            let Some(current) = peers.get(peer).filter(|p| p.generation == generation).cloned()
            else {
                return;
            };
            let mut map = self.remote_sessions.write();
            let past = past_bound(map.of_peer(peer).map(|(key, row)| Closed {
                key: key.clone(),
                closed: row.summary.closed(),
                updated: row.summary.updated_ms(),
            }));
            if past.is_empty() {
                return;
            }
            let gone: Vec<Value> =
                past.iter().filter_map(|key| map.take(key)).map(|r| r.summary.value()).collect();
            current.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
            gone
        };
        self.save_peer_cache(peer, generation, false);
        for summary in gone {
            self.announce_remote(peer, summary, "purged");
        }
    }
}

#[cfg(test)]
#[path = "peer_closed_bound_tests.rs"]
mod tests;
