use super::*;
use crate::session_identity::SessionReceipt;

fn row(peer: &str, mux: &str, status: &str) -> (String, RemoteSession) {
    let receipt = SessionReceipt::new(peer, mux, None, 0);
    let summary = json!({"sessionId": mux, "peer": peer, "status": status});
    (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary: summary.into(), receipt })
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
    assert_eq!(rows.find_mux("a", "s1").unwrap().1.summary.status(), Some("ready"));

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
    assert_eq!(rows.find_mux("b", "s1").unwrap().1.summary.status(), Some("running"));
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
                .filter(|r| r.summary.pair().as_ref() == Some(&pair))
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
    let pairs =
        model.values().filter_map(|r| r.summary.pair()).collect::<std::collections::HashSet<_>>();
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
                let mut summary = r.summary.value();
                summary["tags"] = json!({"mux.parent": parent, "mux.handle": handle});
                r.summary = summary.into();
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
            let mut got: Vec<String> = rows.take_peer(&peer).into_iter().map(|(k, _)| k).collect();
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
                let mut summary = r.summary.value();
                if super::super::peer_cache::mark_stale(&mut summary, seen) {
                    want.push(summary.clone());
                    r.summary = summary.into();
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
    (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary: summary.into(), receipt })
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
            let mut walked: Vec<&String> =
                rows.iter().filter(|(id, r)| names_remote(id, r, key)).map(|(k, _)| k).collect();
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
