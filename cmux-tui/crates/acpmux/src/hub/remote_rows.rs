//! Part of `Hub`; see `hub/mod.rs`. The rows peers list (`Hub::remote_sessions`), with their
//! `(mux.parent, mux.handle)` tags indexed by every write, so an approval card names a peer's
//! child by reading only the rows of that pair (`permissions/display.rs`), never all of them.
//! Each peer's rows are indexed too, by row key and by the peer's own session id, so a peer's
//! notice (a streamed record, a `session_changed`, an ask check, a cache save) reads only that
//! peer's rows, never every peer's: a Mac linked to peers listing thousands of sessions spent a
//! core walking them for each record (cosmic-gray, 2026-11-02).
//! The keys a lookup names a row by (`Hub::resolve_remote`: its name, its name without the
//! `PEER/` the row carries, a prefix of its key or of its peer's session id, its short name) are
//! indexed too, so a key that is not a row's exact key (a bare session id, as the app's chat
//! pages send) reads the rows it names, never all of them: a Mac linked to ~30 peers listing
//! 12,000 sessions held a core in that walk (2026-11-10).
//! Reads go through `Deref` (on a snapshot `Hub::remote_sessions.read()` hands out, or a writer's
//! copy); every write goes through the methods here, which keep the indexes.
//! The maps are persistent (`imbl`), the lookup indexes too: a clone shares every node with its
//! original and costs the same at 12 rows or 12,000, and a write copies only the path to what it
//! changes. That is what lets the table be published as a snapshot each reader holds as long as
//! it likes (`remote_table.rs`) while a writer changes a copy.

use super::*;

/// A persistent map: `clone` is O(1), its nodes shared until one side writes.
type PMap<K, V> = imbl::HashMap<K, V>;
/// A persistent sorted set, likewise.
type PSet<A> = imbl::OrdSet<A>;

#[derive(Clone, Default)]
pub(crate) struct RemoteRows {
    rows: PMap<String, Arc<RemoteSession>>,
    by_pair: PMap<(String, String), PSet<String>>,
    /// Each peer's rows: their peer's own session id (`receipt.mux_session_id`) to their keys.
    by_peer: PMap<String, PMap<String, PSet<String>>>,
    /// The lookup indexes (`named`, `short_named`); see the header.
    names: Names,
    /// Writes so far: a shared session list is rebuilt after one (`list_guard.rs`).
    pub(crate) writes: u64,
    /// The summary each row had before a dropped link marked it stale
    /// ([`Self::mark_peer_stale`]): a follow of the peer's list after the link is back sends only
    /// the rows that changed (`row_log.rs`), so the rest are put back as they were. Any other
    /// write of the row drops it.
    stale_from: PMap<String, Arc<RemoteSession>>,
}

impl std::ops::Deref for RemoteRows {
    type Target = PMap<String, Arc<RemoteSession>>;
    fn deref(&self) -> &Self::Target {
        &self.rows
    }
}

impl RemoteRows {
    pub(crate) fn insert(&mut self, key: String, row: RemoteSession) {
        self.insert_shared(key, Arc::new(row));
    }

    /// Inserts a row its writer shares too (a peer's list announces the rows it changed).
    pub(crate) fn insert_shared(&mut self, key: String, row: Arc<RemoteSession>) {
        self.take(&key);
        self.writes += 1;
        if let Some(pair) = row.summary.pair() {
            self.by_pair.entry(pair).or_default().insert(key.clone());
        }
        let peer = self.by_peer.entry(row.peer.clone()).or_default();
        peer.entry(row.receipt.mux_session_id.clone()).or_default().insert(key.clone());
        self.names.add(&key, &row);
        self.rows.insert(key, row);
    }

    pub(crate) fn remove(&mut self, key: &str) -> Option<RemoteSession> {
        self.take(key).map(Arc::unwrap_or_clone)
    }

    // A write replaces the row; a reader keeps the version its snapshot holds until it ends.
    pub(crate) fn take(&mut self, key: &str) -> Option<Arc<RemoteSession>> {
        let row = self.rows.remove(key)?;
        self.stale_from.remove(key);
        self.writes += 1;
        self.names.remove(key, &row);
        if let Some(pair) = row.summary.pair()
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
                let status = r.summary.status();
                status != Some("closed")
                    && (status != Some("unreachable")
                        || !r.summary.stale()
                        || r.summary.last_seen() != last_seen)
            })
            .map(|(k, _)| k.clone())
            .collect();
        let mut changed = Vec::new();
        for key in keys {
            let live = self.stale_from.get(&key).cloned();
            let Some(row) = self.take(&key) else { continue };
            let live = live.unwrap_or_else(|| Arc::clone(&row));
            let mut row = Arc::unwrap_or_clone(row);
            if row.summary.mark_stale(last_seen) {
                changed.push(row.summary.value());
            }
            self.insert(key.clone(), row);
            self.stale_from.insert(key, live);
        }
        changed
    }

    /// Peer `peer`'s rows as the peer last listed them: a row a dropped link marked stale, as it
    /// was before.
    pub(crate) fn live_of_peer<'a>(
        &'a self,
        peer: &str,
    ) -> impl Iterator<Item = &'a RemoteSession> + 'a {
        self.of_peer(peer).map(|(key, row)| &**self.stale_from.get(key).unwrap_or(row))
    }

    /// Peer `peer`'s rows with their keys, reading no other peer's.
    pub(crate) fn of_peer<'a>(
        &'a self,
        peer: &str,
    ) -> impl Iterator<Item = (&'a String, &'a Arc<RemoteSession>)> + 'a {
        self.by_peer
            .get(peer)
            .into_iter()
            .flat_map(PMap::values)
            .flat_map(PSet::iter)
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

    /// The row a peer last listed for `mux`, restoring the pre-stale copy when
    /// the current row only reflects a dropped link.
    pub(crate) fn find_live_mux(&self, peer: &str, mux: &str) -> Option<&RemoteSession> {
        let (key, row) = self.find_mux(peer, mux)?;
        Some(self.stale_from.get(key).map_or(&**row, |live| &**live))
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
            .flat_map(PSet::iter)
            .filter_map(|key| self.rows.get(key).map(Arc::as_ref))
    }

    /// The rows `key` names by their name, their name without `PEER/`, or a prefix of their key
    /// or of their peer's session id ([`super::peers::names_remote`]), reading only those rows.
    pub(crate) fn named<'a>(&'a self, key: &str) -> Vec<(&'a String, &'a Arc<RemoteSession>)> {
        let n = &self.names;
        let mut keys: std::collections::BTreeSet<&String> = std::collections::BTreeSet::new();
        keys.extend(n.by_name.get(key).into_iter().flatten());
        keys.extend(n.by_bare_name.get(key).into_iter().flatten());
        keys.extend(
            n.keys
                .range::<_, str>((std::ops::Bound::Included(key), std::ops::Bound::Unbounded))
                .take_while(|k| k.starts_with(key)),
        );
        keys.extend(
            n.muxes
                .range::<_, (String, String)>((key.to_owned(), String::new())..)
                .take_while(|(mux, _)| mux.starts_with(key))
                .map(|(_, k)| k),
        );
        keys.into_iter().filter_map(|k| self.rows.get_key_value(k.as_str())).collect()
    }

    /// The rows whose name ends in `key`'s last segment: every row `key` can be the short name
    /// of ([`super::peers::remote_segment`] decides which are).
    pub(crate) fn short_named<'a>(
        &'a self,
        key: &str,
    ) -> Vec<(&'a String, &'a Arc<RemoteSession>)> {
        let last = key.rsplit('/').next().unwrap_or(key);
        self.names
            .by_last_segment
            .get(last)
            .into_iter()
            .flatten()
            .filter_map(|k| self.rows.get_key_value(k.as_str()))
            .collect()
    }

    /// How many pairs the index holds.
    #[cfg(test)]
    pub(crate) fn pairs(&self) -> usize {
        self.by_pair.len()
    }
}

/// The lookup indexes of [`RemoteRows`]: each row's key under its name, its name without
/// `PEER/`, its name's last segment (names with a `/` only: a short name is a later segment),
/// and in sorted sets its key and its peer's session id, for prefixes.
#[derive(Clone, Default)]
struct Names {
    by_name: PMap<String, PSet<String>>,
    by_bare_name: PMap<String, PSet<String>>,
    by_last_segment: PMap<String, PSet<String>>,
    keys: PSet<String>,
    muxes: PSet<(String, String)>,
}

impl Names {
    /// `row`'s entries: (index, value) for each map it is listed in.
    fn entries(row: &RemoteSession) -> [(u8, Option<String>); 3] {
        let name = row.summary.name().unwrap_or("");
        let bare = name.strip_prefix(row.peer.as_str()).and_then(|rest| rest.strip_prefix('/'));
        let last = name.rsplit_once('/').map(|(_, last)| last);
        [(0, Some(name.to_owned())), (1, bare.map(str::to_owned)), (2, last.map(str::to_owned))]
    }

    fn map(&mut self, which: u8) -> &mut PMap<String, PSet<String>> {
        match which {
            0 => &mut self.by_name,
            1 => &mut self.by_bare_name,
            _ => &mut self.by_last_segment,
        }
    }

    fn add(&mut self, key: &str, row: &RemoteSession) {
        for (which, value) in Self::entries(row) {
            if let Some(value) = value {
                self.map(which).entry(value).or_default().insert(key.to_owned());
            }
        }
        self.keys.insert(key.to_owned());
        self.muxes.insert((row.receipt.mux_session_id.clone(), key.to_owned()));
    }

    fn remove(&mut self, key: &str, row: &RemoteSession) {
        for (which, value) in Self::entries(row) {
            let Some(value) = value else { continue };
            let map = self.map(which);
            if let Some(keys) = map.get_mut(&value) {
                keys.remove(key);
                if keys.is_empty() {
                    map.remove(&value);
                }
            }
        }
        self.keys.remove(key);
        self.muxes.remove(&(row.receipt.mux_session_id.clone(), key.to_owned()));
    }

    #[cfg(test)]
    fn is_empty(&self) -> bool {
        self.by_name.is_empty()
            && self.by_bare_name.is_empty()
            && self.by_last_segment.is_empty()
            && self.keys.is_empty()
            && self.muxes.is_empty()
    }
}

#[cfg(test)]
mod tests;
