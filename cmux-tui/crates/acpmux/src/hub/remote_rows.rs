//! Part of `Hub`; see `hub/mod.rs`. The rows peers list (`Hub::remote_sessions`), with their
//! `(mux.parent, mux.handle)` tags indexed by every write, so an approval card names a peer's
//! child by reading only the rows of that pair (`permissions/display.rs`), never all of them.
//! Each peer's rows are indexed too, by row key and by the peer's own session id, so a peer's
//! notice (a streamed record, a `session_changed`, an ask check, a cache save) reads only that
//! peer's rows, never every peer's: a Mac linked to peers listing thousands of sessions spent a
//! core walking them for each record (cosmic-gray, 2026-11-02).
//! Reads go through `Deref` (on a snapshot `Hub::remote_sessions.read()` hands out, or a writer's
//! copy); every write goes through the methods here, which keep the indexes.
//! The maps are persistent (`imbl`): a clone shares every node with its original and costs the
//! same at 12 rows or 12,000, and a write copies only the path to what it changes. That is what
//! lets the table be published as a snapshot each reader holds as long as it likes
//! (`remote_table.rs`) while a writer changes a copy.

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
    /// Writes so far: a shared session list is rebuilt after one (`list_guard.rs`).
    pub(crate) writes: u64,
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
        self.rows.insert(key, Arc::new(row));
    }

    pub(crate) fn remove(&mut self, key: &str) -> Option<RemoteSession> {
        self.take(key).map(Arc::unwrap_or_clone)
    }

    // A write replaces the row; a reader keeps the version its snapshot holds until it ends.
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
}
