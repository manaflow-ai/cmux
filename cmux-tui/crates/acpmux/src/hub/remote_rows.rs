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
/// A persistent sorted map, used where prefix lookup needs ordered keys.
type POrdMap<K, V> = imbl::OrdMap<K, V>;
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
    /// Changes that can alter name or prefix lookup, including whether a candidate is closed.
    pub(super) route_changes: u64,
    /// The summary each row had before a dropped link marked it stale
    /// ([`Self::mark_peer_stale`]): a follow of the peer's list after the link is back sends only
    /// the rows that changed (`row_log.rs`), so the rest are put back as they were. Any other
    /// write of the row drops it.
    stale_from: PMap<String, Arc<RemoteSession>>,
    /// Every row's key in list order (newest first, ties by session id, then by peer, as
    /// `page_first.rs` sorts), the closed rows apart: a page reads its own rows from here and a
    /// live list (`excludeStatus: [closed]`) reads no closed row, never a sort of every row.
    open_order: PSet<ListPlace>,
    closed_order: PSet<ListPlace>,
    /// How many rows each peer lists, kept by every write: `_acpmux/status` reads it per peer,
    /// not per row.
    per_peer: PMap<String, usize>,
    /// Every row's key by its byte-page key (`session_pages::page_key_of`, fixed by its id and
    /// peer): a byte page of the whole list (`_acpmux/sessions` with no `limit`) reads its own
    /// rows from here, not a hash and a sort of every row.
    by_page_key: PSet<(u128, Box<str>)>,
}

/// A row's place in list order: newest first, then its session id, then its peer (none first),
/// then its key (two rows alike in all three stay apart).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct ListPlace {
    at: std::cmp::Reverse<u64>,
    id: Box<str>,
    peer: Option<Box<str>>,
    key: Box<str>,
}

impl ListPlace {
    fn of(key: &str, row: &RemoteSession) -> Self {
        Self {
            at: std::cmp::Reverse(row.summary.updated_ms()),
            id: row.summary.session_id().unwrap_or("").into(),
            peer: row.summary.peer().map(Box::from),
            key: key.into(),
        }
    }

    /// The first place of a row no newer than `at`.
    fn from(at: u64) -> Self {
        Self { at: std::cmp::Reverse(at), id: "".into(), peer: None, key: "".into() }
    }
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
        // The usual change (a turn, a status) keeps every index key: replace the row alone, not
        // a take and re-add that path-copies every index twice.
        if let Some(old) = self.rows.get_mut(&key)
            && Self::same_index(old, &row)
        {
            self.route_changes += u64::from(old.summary.closed() != row.summary.closed());
            *old = row;
            self.stale_from.remove(&key);
            self.writes += 2;
            return;
        }
        self.take(&key);
        self.writes += 1;
        self.route_changes += 1;
        if let Some(pair) = row.summary.pair() {
            self.by_pair.entry(pair).or_default().insert(key.clone());
        }
        *self.per_peer.entry(row.peer.clone()).or_default() += 1;
        self.by_page_key.insert((page_key(&row), key.as_str().into()));
        let peer = self.by_peer.entry(row.peer.clone()).or_default();
        peer.entry(row.receipt.mux_session_id.clone()).or_default().insert(key.clone());
        self.names.add(&key, &row);
        let place = ListPlace::of(&key, &row);
        if row.summary.closed() {
            self.closed_order.insert(place);
        } else {
            self.open_order.insert(place);
        }
        self.rows.insert(key, row);
    }

    /// Whether two rows file under the same index keys (`Names::entries`, `by_pair`, `by_peer`,
    /// the list order's `ListPlace` and open or closed set, `by_page_key`).
    fn same_index(a: &RemoteSession, b: &RemoteSession) -> bool {
        a.peer == b.peer
            && a.receipt.mux_session_id == b.receipt.mux_session_id
            && a.summary.updated_ms() == b.summary.updated_ms()
            && a.summary.closed() == b.summary.closed()
            && a.summary.session_id() == b.summary.session_id()
            && a.summary.peer() == b.summary.peer()
            && a.summary.name() == b.summary.name()
            && a.summary.alias() == b.summary.alias()
            && a.summary.former_names() == b.summary.former_names()
            && a.summary.same_pair(&b.summary)
    }

    pub(crate) fn remove(&mut self, key: &str) -> Option<RemoteSession> {
        self.take(key).map(Arc::unwrap_or_clone)
    }

    // A write replaces the row; a reader keeps the version its snapshot holds until it ends.
    pub(crate) fn take(&mut self, key: &str) -> Option<Arc<RemoteSession>> {
        let row = self.rows.remove(key)?;
        self.stale_from.remove(key);
        self.writes += 1;
        self.route_changes += 1;
        self.names.remove(key, &row);
        let place = ListPlace::of(key, &row);
        if row.summary.closed() {
            self.closed_order.remove(&place);
        } else {
            self.open_order.remove(&place);
        }
        if let Some(pair) = row.summary.pair()
            && let Some(keys) = self.by_pair.get_mut(&pair)
        {
            keys.remove(key);
            if keys.is_empty() {
                self.by_pair.remove(&pair);
            }
        }
        self.by_page_key.remove(&(page_key(&row), key.into()));
        if let Some(count) = self.per_peer.get_mut(&row.peer) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.per_peer.remove(&row.peer);
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
    /// There is no other way to change a row in place. Each summary shares the text the row had
    /// before the mark, the mark kept apart (`PeerRow::stale_announced`), so it copies no row.
    pub(crate) fn mark_peer_stale(&mut self, peer: &str, last_seen: Option<u64>) -> Vec<PeerRow> {
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
            let before = row.summary.clone();
            let mut row = Arc::unwrap_or_clone(row);
            if row.summary.mark_stale(last_seen) {
                changed.push(PeerRow::stale_announced(&before, &row.summary, last_seen));
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

    /// Peer `peer`'s rows a dropped link marked stale, each as it was before, with its key.
    pub(crate) fn stale_of_peer<'a>(
        &'a self,
        peer: &str,
    ) -> impl Iterator<Item = (&'a String, &'a Arc<RemoteSession>)> + 'a {
        self.of_peer(peer).filter_map(|(key, _)| self.stale_from.get(key).map(|live| (key, live)))
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

    /// The rows in list order from the first no newer than `from` (the top when None), the
    /// closed ones too unless `open_only`: each read costs the rows it takes, never a walk or a
    /// sort of every row.
    pub(crate) fn in_order<'a>(
        &'a self,
        from: Option<u64>,
        open_only: bool,
    ) -> impl Iterator<Item = &'a Arc<RemoteSession>> + 'a {
        let start = ListPlace::from(from.unwrap_or(u64::MAX));
        let range = |set: &'a PSet<ListPlace>| set.range(start.clone()..);
        let open = range(&self.open_order).peekable();
        let closed = (!open_only).then(|| range(&self.closed_order)).into_iter().flatten();
        Merged { a: open, b: closed.peekable() }.filter_map(|place| self.rows.get(&*place.key))
    }

    /// The rows in byte-page key order from the first with a key past `after` (every row when
    /// None), each with its key: a byte page costs the rows it takes.
    pub(crate) fn by_page_key<'a>(
        &'a self,
        after: Option<u128>,
    ) -> impl Iterator<Item = (u128, &'a Arc<RemoteSession>)> + 'a {
        let start = after.map_or(0, |after| after.saturating_add(1));
        let past_max = after == Some(u128::MAX);
        self.by_page_key
            .range((start, Box::<str>::from(""))..)
            .filter(move |_| !past_max)
            .filter_map(|(hash, key)| self.rows.get(&**key).map(|row| (*hash, row)))
    }

    /// How many rows are closed, counted as they are written.
    pub(crate) fn closed_count(&self) -> usize {
        self.closed_order.len()
    }

    /// How many rows each peer lists: one read per peer, counted as rows are written.
    pub(crate) fn peer_counts(&self) -> HashMap<String, usize> {
        self.per_peer.iter().map(|(peer, count)| (peer.clone(), *count)).collect()
    }

    /// Only the rows that actually had this former name.
    pub(super) fn formerly_named(
        &self,
        name: &str,
    ) -> impl Iterator<Item = (&String, &Arc<RemoteSession>)> {
        self.names
            .by_former
            .get(name)
            .into_iter()
            .flatten()
            .filter_map(|key| Some((key, self.rows.get(key)?)))
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
        keys.extend(n.by_alias.get(key).into_iter().flatten());
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
        keys.extend(
            n.by_alias
                .range::<_, str>((std::ops::Bound::Included(key), std::ops::Bound::Unbounded))
                .take_while(|(alias, _)| alias.starts_with(key))
                .flat_map(|(_, rows)| rows.iter()),
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

/// `row`'s byte-page key, as a whole list's byte pages order it.
fn page_key(row: &RemoteSession) -> u128 {
    super::session_pages::page_key_of(row.summary.session_id().unwrap_or(""), row.summary.peer())
}

/// Two iterators in ascending order, merged into one.
struct Merged<A: Iterator, B: Iterator<Item = A::Item>> {
    a: std::iter::Peekable<A>,
    b: std::iter::Peekable<B>,
}

impl<T: Ord, A: Iterator<Item = T>, B: Iterator<Item = T>> Iterator for Merged<A, B> {
    type Item = T;
    fn next(&mut self) -> Option<T> {
        match (self.a.peek(), self.b.peek()) {
            (Some(a), Some(b)) if b < a => self.b.next(),
            (Some(_), _) => self.a.next(),
            (None, _) => self.b.next(),
        }
    }
}

/// The lookup indexes of [`RemoteRows`]: each row's key under its name, its name without
/// `PEER/`, its name's last segment (names with a `/` only: a short name is a later segment),
/// and in sorted sets its key and its peer's session id, for prefixes.
#[derive(Clone, Default)]
struct Names {
    by_name: PMap<String, PSet<String>>,
    by_bare_name: PMap<String, PSet<String>>,
    by_alias: POrdMap<String, PSet<String>>,
    by_former: PMap<String, PSet<String>>,
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
        for name in row.summary.former_names() {
            self.by_former.entry(name.to_string()).or_default().insert(key.to_owned());
        }
        if let Some(alias) = row.summary.alias() {
            self.by_alias.entry(alias.to_owned()).or_default().insert(key.to_owned());
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
        for name in row.summary.former_names() {
            if let Some(keys) = self.by_former.get_mut(&**name) {
                keys.remove(key);
                if keys.is_empty() {
                    self.by_former.remove(&**name);
                }
            }
        }
        if let Some(alias) = row.summary.alias()
            && let Some(keys) = self.by_alias.get_mut(alias)
        {
            keys.remove(key);
            if keys.is_empty() {
                self.by_alias.remove(alias);
            }
        }
        self.keys.remove(key);
        self.muxes.remove(&(row.receipt.mux_session_id.clone(), key.to_owned()));
    }

    #[cfg(test)]
    fn is_empty(&self) -> bool {
        self.by_name.is_empty()
            && self.by_bare_name.is_empty()
            && self.by_alias.is_empty()
            && self.by_former.is_empty()
            && self.by_last_segment.is_empty()
            && self.keys.is_empty()
            && self.muxes.is_empty()
    }
}

#[cfg(test)]
#[path = "remote_rows_tests.rs"]
mod tests;
