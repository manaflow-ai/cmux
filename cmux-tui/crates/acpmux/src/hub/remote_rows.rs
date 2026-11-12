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
    stale_from: PMap<String, Arc<Value>>,
}

impl std::ops::Deref for RemoteRows {
    type Target = PMap<String, Arc<RemoteSession>>;
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
        self.names.add(&key, &row);
        self.rows.insert(key, Arc::new(row));
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
            let live = self.stale_from.get(&key).cloned();
            let Some(mut row) = self.remove(&key) else { continue };
            let live = live.unwrap_or_else(|| Arc::new(row.summary.clone()));
            if super::peer_cache::mark_stale(&mut row.summary, last_seen) {
                changed.push(row.summary.clone());
            }
            self.insert(key.clone(), row);
            self.stale_from.insert(key, live);
        }
        changed
    }

    /// Peer `peer`'s rows as the peer last listed them: a row a dropped link marked stale, as it
    /// was before.
    pub(crate) fn live_of_peer<'a>(&'a self, peer: &str) -> impl Iterator<Item = &'a Value> + 'a {
        self.of_peer(peer).map(|(key, row)| self.stale_from.get(key).map_or(&row.summary, |v| v))
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
        let name = row.summary.get("name").and_then(Value::as_str).unwrap_or("");
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
        assert!(rows.names.is_empty(), "no name entry is left behind");
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

    /// One step of the model check below.
    #[derive(Debug, Clone)]
    enum Op {
        /// A row of peer `.0`'s session `.1`, with status `.2` and, maybe, pair tags `.3`.
        Insert(u8, u8, u8, Option<(u8, u8)>),
        Take(u8, u8),
        TakePeer(u8),
        MarkStale(u8, Option<u8>),
        /// Keep a clone of the table as it is now: it must never change after.
        Snapshot,
    }

    const PEERS: u8 = 4;
    const MUXES: u8 = 6;
    const PAIRS: u8 = 3;
    const STATUSES: [&str; 4] = ["running", "idle", "closed", "unreachable"];

    fn op() -> impl proptest::strategy::Strategy<Value = Op> {
        use proptest::prelude::*;
        let pair = proptest::option::of((0..PAIRS, 0..PAIRS));
        prop_oneof![
            6 => (0..PEERS, 0..MUXES, 0..STATUSES.len() as u8, pair)
                .prop_map(|(p, m, s, t)| Op::Insert(p, m, s, t)),
            3 => (0..PEERS, 0..MUXES).prop_map(|(p, m)| Op::Take(p, m)),
            1 => (0..PEERS).prop_map(Op::TakePeer),
            2 => (0..PEERS, proptest::option::of(0..3u8)).prop_map(|(p, s)| Op::MarkStale(p, s)),
            1 => Just(Op::Snapshot),
        ]
    }

    fn peer_of(p: u8) -> String {
        format!("peer-{p}")
    }

    fn pair_of_ix((parent, handle): (u8, u8)) -> (String, String) {
        (format!("parent-{parent}"), format!("h{handle}"))
    }

    type Model = std::collections::HashMap<String, RemoteSession>;

    /// The model's answer to every index the table keeps, read the slow way: a walk of every row.
    fn agrees(rows: &RemoteRows, model: &Model) -> Result<(), String> {
        let fail = |what: String| Err(what);
        if rows.len() != model.len() {
            return fail(format!("len {} != model {}", rows.len(), model.len()));
        }
        for (key, row) in model {
            let Some(got) = rows.get(key) else { return fail(format!("missing {key}")) };
            if got.summary != row.summary || got.peer != row.peer {
                return fail(format!("row {key} differs"));
            }
        }
        let mut counts: HashMap<String, usize> = HashMap::new();
        for row in model.values() {
            *counts.entry(row.peer.clone()).or_default() += 1;
        }
        if rows.peer_counts() != counts {
            return fail(format!("peer_counts {:?} != model {counts:?}", rows.peer_counts()));
        }
        for p in 0..PEERS {
            let peer = peer_of(p);
            let mut want: Vec<&String> =
                model.iter().filter(|(_, r)| r.peer == peer).map(|(k, _)| k).collect();
            want.sort();
            let mut got: Vec<&String> = rows.of_peer(&peer).map(|(k, _)| k).collect();
            got.sort();
            if got != want {
                return fail(format!("of_peer({peer}) {got:?} != model {want:?}"));
            }
            if rows.has_peer(&peer) == want.is_empty() {
                return fail(format!("has_peer({peer})"));
            }
            for m in 0..MUXES {
                let mux = format!("s{m}");
                let want = model
                    .iter()
                    .find(|(_, r)| r.peer == peer && r.receipt.mux_session_id == mux)
                    .map(|(k, _)| k.clone());
                let got = rows.find_mux(&peer, &mux).map(|(k, _)| k.clone());
                if got != want {
                    return fail(format!("find_mux({peer}, {mux}) {got:?} != model {want:?}"));
                }
            }
        }
        for parent in 0..PAIRS {
            for handle in 0..PAIRS {
                let pair = pair_of_ix((parent, handle));
                let mut want: Vec<String> = model
                    .values()
                    .filter(|r| super::pair_of(&r.summary).as_ref() == Some(&pair))
                    .map(|r| r.receipt.qualified_id())
                    .collect();
                want.sort();
                let mut got: Vec<String> =
                    rows.with_pair(&pair).map(|r| r.receipt.qualified_id()).collect();
                got.sort();
                if got != want {
                    return fail(format!("with_pair({pair:?}) {got:?} != model {want:?}"));
                }
            }
        }
        let pairs = model
            .values()
            .filter_map(|r| super::pair_of(&r.summary))
            .collect::<std::collections::HashSet<_>>();
        if rows.pairs() != pairs.len() {
            return fail(format!("pairs {} != model {}", rows.pairs(), pairs.len()));
        }
        Ok(())
    }

    /// Applies `op` to the table and the model alike.
    fn apply(rows: &mut RemoteRows, model: &mut Model, op: &Op) -> Result<(), String> {
        match *op {
            Op::Insert(p, m, s, pair) => {
                let (key, mut r) = row(&peer_of(p), &format!("s{m}"), STATUSES[s as usize]);
                if let Some(pair) = pair {
                    let (parent, handle) = pair_of_ix(pair);
                    r.summary["tags"] = json!({"mux.parent": parent, "mux.handle": handle});
                }
                model.insert(key.clone(), r.clone());
                rows.insert(key, r);
            }
            Op::Take(p, m) => {
                let key = format!("{}/s{m}", peer_of(p));
                let got = rows.take(&key).map(|r| r.summary.clone());
                let want = model.remove(&key).map(|r| r.summary);
                if got != want {
                    return Err(format!("take({key}) {got:?} != model {want:?}"));
                }
            }
            Op::TakePeer(p) => {
                let peer = peer_of(p);
                let mut got: Vec<String> =
                    rows.take_peer(&peer).into_iter().map(|(k, _)| k).collect();
                let mut want: Vec<String> =
                    model.iter().filter(|(_, r)| r.peer == peer).map(|(k, _)| k.clone()).collect();
                model.retain(|_, r| r.peer != peer);
                got.sort();
                want.sort();
                if got != want {
                    return Err(format!("take_peer({peer}) {got:?} != model {want:?}"));
                }
            }
            Op::MarkStale(p, seen) => {
                let peer = peer_of(p);
                let seen = seen.map(u64::from);
                let mut got: Vec<Value> = rows.mark_peer_stale(&peer, seen);
                let mut want: Vec<Value> = Vec::new();
                for r in model.values_mut().filter(|r| r.peer == peer) {
                    if super::super::peer_cache::mark_stale(&mut r.summary, seen) {
                        want.push(r.summary.clone());
                    }
                }
                let by_id = |v: &Value| v["sessionId"].as_str().unwrap_or_default().to_owned();
                got.sort_by_key(by_id);
                want.sort_by_key(by_id);
                if got != want {
                    return Err(format!("mark_peer_stale({peer}) {got:?} != model {want:?}"));
                }
            }
            Op::Snapshot => {}
        }
        Ok(())
    }

    proptest::proptest! {
        #![proptest_config(proptest::prelude::ProptestConfig { cases: 256, ..Default::default() })]

        /// Every index (`of_peer`, `find_mux`, `peer_counts`, `with_pair`) answers what a walk
        /// of a plain map of the same rows answers, after every write; and a clone taken at any
        /// point (a published snapshot) keeps answering what the table held then, whatever is
        /// written after: the persistent maps share nodes, never changes.
        #[test]
        fn the_indexes_agree_with_a_plain_map_and_clones_never_move(
            ops in proptest::collection::vec(op(), 1..120),
        ) {
            let (mut rows, mut model) = (RemoteRows::default(), Model::new());
            let mut kept: Vec<(RemoteRows, Model)> = Vec::new();
            for op in &ops {
                if let Op::Snapshot = op {
                    kept.push((rows.clone(), model.clone()));
                }
                apply(&mut rows, &mut model, op).map_err(proptest::test_runner::TestCaseError::fail)?;
                agrees(&rows, &model)
                    .map_err(|e| proptest::test_runner::TestCaseError::fail(format!("after {op:?}: {e}")))?;
            }
            for (n, (snapshot, then)) in kept.iter().enumerate() {
                agrees(snapshot, then)
                    .map_err(|e| proptest::test_runner::TestCaseError::fail(format!("snapshot {n}: {e}")))?;
            }
        }
    }

    /// A row as a peer lists it: `name` already carries `PEER/` (`Hub::remote_summary`).
    fn named_row(peer: &str, mux: &str, name: &str) -> (String, RemoteSession) {
        let receipt = SessionReceipt::new(peer, mux, None, 0);
        let summary = json!({"sessionId": mux, "peer": peer, "status": "running", "name": name});
        (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary, receipt })
    }

    /// Every key, through the indexes, finds exactly the rows a walk over all of them finds,
    /// through every write.
    #[test]
    fn the_indexes_find_what_a_walk_finds() {
        use super::super::peers::{names_remote, remote_segment};
        let mut rows = RemoteRows::default();
        let rows_of = [
            ("a", "0a1b-1", "a/lane"),
            ("a", "0a1b-2", "a/coord/lane"),
            ("b", "0a1c-1", "b/coord/lane"),
            ("b", "0a1c-2", "b/0a1b-1"),
            ("c", "x", "c"),
            ("c", "y", "c/"),
            ("c", "z", "other/name"),
        ];
        for (peer, mux, name) in rows_of {
            let (key, r) = named_row(peer, mux, name);
            rows.insert(key, r);
        }
        let keys = [
            "",
            "a",
            "a/",
            "a/0",
            "a/0a1b-1",
            "0a1b-1",
            "0a1",
            "0a1b",
            "lane",
            "coord/lane",
            "a/lane",
            "a/coord/lane",
            "b/lane",
            "b/coord/lane",
            "coord",
            "b/0a1b-1",
            "c",
            "c/",
            "c/x",
            "x",
            "name",
            "other/name",
            "c/name",
            "c/other/name",
            "missing",
            "/lane",
        ];
        let check = |rows: &RemoteRows| {
            for key in keys {
                let mut walked: Vec<&String> = rows
                    .iter()
                    .filter(|(id, r)| names_remote(id, r, key))
                    .map(|(k, _)| k)
                    .collect();
                let mut found: Vec<&String> = rows
                    .named(key)
                    .into_iter()
                    .filter(|(id, r)| names_remote(id, r, key))
                    .map(|(k, _)| k)
                    .collect();
                walked.sort();
                found.sort();
                assert_eq!(found, walked, "names {key:?}");
                let mut walked: Vec<&String> =
                    rows.iter().filter(|(_, r)| remote_segment(r, key)).map(|(k, _)| k).collect();
                let mut found: Vec<&String> = rows
                    .short_named(key)
                    .into_iter()
                    .filter(|(_, r)| remote_segment(r, key))
                    .map(|(k, _)| k)
                    .collect();
                walked.sort();
                found.sort();
                assert_eq!(found, walked, "short name {key:?}");
            }
        };
        check(&rows);
        // A renamed row is found by its new name only.
        let (key, r) = named_row("a", "0a1b-1", "a/renamed/lane");
        rows.insert(key, r);
        check(&rows);
        rows.take("b/0a1c-1");
        check(&rows);
        rows.take_peer("c");
        check(&rows);
        rows.take_peer("a");
        rows.take_peer("b");
        assert!(rows.names.is_empty(), "no name entry is left behind");
    }

    /// The cost guard: a bare session id, the key an app chat page sends for a peer's chat,
    /// reads the one row it names out of 12,000 (30 peers of 400), not all of them.
    #[test]
    fn a_bare_id_reads_only_its_own_row_at_12000_rows() {
        let mut rows = RemoteRows::default();
        for p in 0..30 {
            for s in 0..400 {
                let peer = format!("peer-{p}");
                let (key, r) = named_row(
                    &peer,
                    &format!("01a1c7f2-{p:04}-{s:04}"),
                    &format!("{peer}/coord/lane-{s}"),
                );
                rows.insert(key, r);
            }
        }
        assert_eq!(rows.len(), 12_000);
        assert_eq!(rows.named("01a1c7f2-0007-0123").len(), 1);
        assert_eq!(rows.named("01a1c7f2-0007-9999").len(), 0, "a miss reads no row");
        assert_eq!(rows.named("peer-7/coord/lane-5").len(), 1);
        assert_eq!(rows.short_named("lane-5").len(), 30, "one per peer with that short name");
        assert_eq!(rows.short_named("missing").len(), 0);
    }
}
