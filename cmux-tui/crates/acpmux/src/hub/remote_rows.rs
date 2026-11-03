//! Part of `Hub`; see `hub/mod.rs`. The rows peers list (`Hub::remote_sessions`), with their
//! `(mux.parent, mux.handle)` tags indexed by every write, so an approval card names a peer's
//! child by reading only the rows of that pair (`permissions/display.rs`), never all of them.
//! Each peer's rows are indexed too, by row key and by the peer's own session id, so a peer's
//! notice (a streamed record, a `session_changed`, an ask check, a cache save) reads only that
//! peer's rows, never every peer's: a Mac linked to peers listing thousands of sessions spent a
//! core walking them for each record (cosmic-gray, 2026-11-02).
//! Reads go through `Deref`; every write goes through the methods here, which keep the indexes.

use super::*;

#[derive(Default)]
pub(crate) struct RemoteRows {
    rows: HashMap<String, Arc<RemoteSession>>,
    by_pair: HashMap<(String, String), std::collections::BTreeSet<String>>,
    /// Each peer's rows: their peer's own session id (`receipt.mux_session_id`) to their keys.
    by_peer: HashMap<String, HashMap<String, std::collections::BTreeSet<String>>>,
    /// Writes so far: a shared session list is rebuilt after one (`list_guard.rs`).
    pub(crate) writes: u64,
}

impl std::ops::Deref for RemoteRows {
    type Target = HashMap<String, Arc<RemoteSession>>;
    fn deref(&self) -> &Self::Target {
        &self.rows
    }
}

impl RemoteRows {
    pub(crate) fn insert(&mut self, key: String, row: RemoteSession) {
        self.take(&key);
        self.writes += 1;
        if let Some(pair) = pair_of(&row.summary) {
            self.by_pair.entry(pair).or_default().insert(key.clone());
        }
        let peer = self.by_peer.entry(row.peer.clone()).or_default();
        peer.entry(row.receipt.mux_session_id.clone()).or_default().insert(key.clone());
        self.rows.insert(key, Arc::new(row));
    }

    pub(crate) fn remove(&mut self, key: &str) -> Option<RemoteSession> {
        self.take(key).map(Arc::unwrap_or_clone)
    }

    // Readers capture Arc handles under the mutex, then serialize outside it. A write
    // replaces the row; readers retain the captured version until their build ends.
    pub(crate) fn take(&mut self, key: &str) -> Option<Arc<RemoteSession>> {
        let row = self.rows.remove(key)?;
        self.writes += 1;
        if let Some(pair) = pair_of(&row.summary)
            && let Some(keys) = self.by_pair.get_mut(&pair)
        {
            keys.remove(key);
            if keys.is_empty() {
                self.by_pair.remove(&pair);
            }
        }
        if let Some(peer) = self.by_peer.get_mut(&row.peer) {
            if let Some(keys) = peer.get_mut(&row.receipt.mux_session_id) {
                keys.remove(key);
                if keys.is_empty() {
                    peer.remove(&row.receipt.mux_session_id);
                }
            }
            if peer.is_empty() {
                self.by_peer.remove(&row.peer);
            }
        }
        Some(row)
    }

    #[cfg(test)]
    pub(crate) fn retain(&mut self, mut keep: impl FnMut(&String, &RemoteSession) -> bool) {
        let gone: Vec<String> =
            self.rows.iter().filter(|(k, r)| !keep(k, r)).map(|(k, _)| k.clone()).collect();
        for key in gone {
            self.take(&key);
        }
    }

    /// Marks `peer`'s rows stale (`peer_cache::mark_stale`): the summaries that changed. Each row
    /// is taken out and put back through `insert`, so the index follows whatever the mark touched.
    /// There is no other way to change a row in place.
    pub(crate) fn mark_peer_stale(&mut self, peer: &str, last_seen: Option<u64>) -> Vec<Value> {
        let keys: Vec<String> = self
            .of_peer(peer)
            .filter(|(_, r)| {
                let status = r.summary.get("status").and_then(Value::as_str);
                status != Some("closed")
                    && (status != Some("unreachable")
                        || r.summary.get("stale").and_then(Value::as_bool) != Some(true)
                        || r.summary.get("lastSeen").unwrap_or(&Value::Null) != &json!(last_seen))
            })
            .map(|(k, _)| k.clone())
            .collect();
        let mut changed = Vec::new();
        for key in keys {
            let Some(mut row) = self.remove(&key) else { continue };
            if super::peer_cache::mark_stale(&mut row.summary, last_seen) {
                changed.push(row.summary.clone());
            }
            self.insert(key, row);
        }
        changed
    }

    /// Peer `peer`'s rows with their keys, reading no other peer's.
    pub(crate) fn of_peer<'a>(
        &'a self,
        peer: &str,
    ) -> impl Iterator<Item = (&'a String, &'a Arc<RemoteSession>)> + 'a {
        self.by_peer
            .get(peer)
            .into_iter()
            .flat_map(HashMap::values)
            .flatten()
            .filter_map(|key| self.rows.get_key_value(key))
    }

    /// Whether peer `peer` lists any row.
    pub(crate) fn has_peer(&self, peer: &str) -> bool {
        self.by_peer.contains_key(peer)
    }

    /// The key and row of peer `peer`'s own session `mux` (its `receipt.mux_session_id`).
    pub(crate) fn find_mux(&self, peer: &str, mux: &str) -> Option<(&String, &Arc<RemoteSession>)> {
        let keys = self.by_peer.get(peer)?.get(mux)?;
        keys.iter().find_map(|key| self.rows.get_key_value(key))
    }

    /// Removes peer `peer`'s rows, answering them with their keys.
    pub(crate) fn take_peer(&mut self, peer: &str) -> Vec<(String, Arc<RemoteSession>)> {
        let keys: Vec<String> = self.of_peer(peer).map(|(key, _)| key.clone()).collect();
        keys.into_iter().filter_map(|key| self.take(&key).map(|row| (key, row))).collect()
    }

    /// How many rows each peer lists.
    pub(crate) fn peer_counts(&self) -> HashMap<String, usize> {
        self.by_peer
            .iter()
            .map(|(peer, ids)| (peer.clone(), ids.values().map(|keys| keys.len()).sum()))
            .collect()
    }

    /// The rows tagged with `pair`.
    pub(crate) fn with_pair(
        &self,
        pair: &(String, String),
    ) -> impl Iterator<Item = &RemoteSession> {
        self.by_pair
            .get(pair)
            .into_iter()
            .flatten()
            .filter_map(|key| self.rows.get(key).map(Arc::as_ref))
    }

    /// How many pairs the index holds.
    #[cfg(test)]
    pub(crate) fn pairs(&self) -> usize {
        self.by_pair.len()
    }
}

/// A row's `(mux.parent, mux.handle)` tags, as its summary lists them.
fn pair_of(summary: &Value) -> Option<(String, String)> {
    let tags = summary.get("tags")?;
    let tag = |key: &str| {
        tags.get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_owned)
    };
    Some((tag("mux.parent")?, tag("mux.handle")?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_identity::SessionReceipt;

    fn row(peer: &str, mux: &str, status: &str) -> (String, RemoteSession) {
        let receipt = SessionReceipt::new(peer, mux, None, 0);
        let summary = json!({"sessionId": mux, "peer": peer, "status": status});
        (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary, receipt })
    }

    fn keys_of(rows: &RemoteRows, peer: &str) -> Vec<String> {
        let mut keys: Vec<String> = rows.of_peer(peer).map(|(key, _)| key.clone()).collect();
        keys.sort();
        keys
    }

    #[test]
    fn the_peer_index_follows_every_write() {
        let mut rows = RemoteRows::default();
        for (peer, mux) in [("a", "s1"), ("a", "s2"), ("b", "s1")] {
            let (key, r) = row(peer, mux, "running");
            rows.insert(key, r);
        }
        assert_eq!(keys_of(&rows, "a"), ["a/s1", "a/s2"]);
        assert_eq!(keys_of(&rows, "b"), ["b/s1"]);
        assert_eq!(rows.find_mux("b", "s1").map(|(k, _)| k.as_str()), Some("b/s1"));
        assert!(rows.find_mux("b", "s2").is_none());
        assert!(rows.find_mux("c", "s1").is_none());
        assert_eq!(rows.peer_counts(), HashMap::from([("a".into(), 2), ("b".into(), 1)]));

        // A row put back under its key replaces it once.
        let (key, r) = row("a", "s1", "ready");
        rows.insert(key, r);
        assert_eq!(keys_of(&rows, "a"), ["a/s1", "a/s2"]);
        assert_eq!(rows.find_mux("a", "s1").unwrap().1.summary["status"], "ready");

        rows.take("a/s1");
        assert!(rows.find_mux("a", "s1").is_none());
        assert_eq!(keys_of(&rows, "a"), ["a/s2"]);

        rows.retain(|_, r| r.peer != "b");
        assert!(!rows.has_peer("b"));
        assert!(rows.find_mux("b", "s1").is_none());

        let stale = rows.mark_peer_stale("a", Some(5));
        assert_eq!(stale.len(), 1);
        assert_eq!(keys_of(&rows, "a"), ["a/s2"]);

        let taken = rows.take_peer("a");
        assert_eq!(taken.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), ["a/s2"]);
        assert!(rows.is_empty());
        assert!(rows.by_peer.is_empty(), "no empty entry is left behind");
    }

    #[test]
    fn marking_one_peer_stale_leaves_the_others_rows() {
        let mut rows = RemoteRows::default();
        for (peer, mux) in [("a", "s1"), ("b", "s1")] {
            let (key, r) = row(peer, mux, "running");
            rows.insert(key, r);
        }
        assert_eq!(rows.mark_peer_stale("a", None).len(), 1);
        assert_eq!(rows.find_mux("b", "s1").unwrap().1.summary["status"], "running");
    }
}
