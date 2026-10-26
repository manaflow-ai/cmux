//! `peer_snapshot.rs`: bounds and eviction, a full disk (ENOSPC), a recreated or restored
//! session, dedupe by seq, and a peer that is down (the files themselves: `disk_tests.rs`).

use super::disk::{SEGMENT_EVENTS, read_segment};
use super::*;
use std::collections::BTreeSet;
use std::sync::atomic::{AtomicU32, Ordering};

fn rec(seq: u64) -> Value {
    json!({"sessionId": "m1", "seq": seq, "at": seq, "dir": "in", "kind": "agent_message_chunk",
           "msg": {"text": format!("line {seq}")}})
}

fn recs(range: std::ops::RangeInclusive<u64>) -> Vec<Value> {
    range.map(rec).collect()
}

/// A page (`host` set) or, with None, live records; `at` is (epoch, generation).
fn put(
    store: &PeerSnapshots,
    mux: &str,
    at: (u64, u64),
    host: Option<u64>,
    start: bool,
    r: &[Value],
) {
    let (epoch, generation) = (at.0, Some(at.1));
    let c = Capture {
        epoch,
        generation,
        host_last_seq: host,
        from_start: start,
        row: None,
        records: r,
    };
    store.capture("huge-blue", mux, c);
}

fn key(mux: &str) -> Key {
    ("huge-blue".to_owned(), mux.to_owned())
}

/// The seqs kept for `mux`, on disk and in memory.
fn kept(store: &PeerSnapshots, mux: &str) -> Vec<u64> {
    let state = lock(&store.0.state);
    let Some(snap) = state.sessions.get(&key(mux)) else { return vec![] };
    let mut seqs: BTreeSet<u64> = snap.pending.keys().copied().collect();
    for seg in &snap.segments {
        seqs.extend(read_segment(&seg.path).unwrap().0.iter().filter_map(seq_of));
    }
    seqs.into_iter().collect()
}

fn files(dir: &Path) -> Vec<String> {
    let names = std::fs::read_dir(dir).into_iter().flatten().flatten();
    let names: BTreeSet<String> = names.filter_map(|e| e.file_name().into_string().ok()).collect();
    names.into_iter().collect()
}

fn store_at(dir: &Path) -> PeerSnapshots {
    PeerSnapshots::open(Some(dir.to_owned()))
}

fn json_at(path: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

#[test]
fn a_copy_survives_a_restart_and_keeps_each_seq_once() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    put(&store, "m1", (1, 7), Some(10), true, &recs(1..=10));
    // The same page again and a live record it already holds: nothing twice.
    put(&store, "m1", (1, 7), Some(12), false, &recs(5..=12));
    put(&store, "m1", (1, 7), None, false, &[rec(12)]);
    assert_eq!(kept(&store, "m1"), (1..=12).collect::<Vec<_>>());
    let session = dir.path().join("huge-blue/m1");
    let segs: Vec<String> = files(&session).into_iter().filter(|n| n.starts_with("seg-")).collect();
    let read = |n: &String| std::fs::read_to_string(session.join(n)).unwrap().lines().count();
    let lines: usize = segs.iter().map(read).sum();
    assert_eq!(
        (lines, segs.len()),
        (12, 2),
        "each record once; the first segment sealed at {SEGMENT_EVENTS}"
    );

    // A new daemon on the same home reads it back, and dedupes against it.
    let again = store_at(dir.path());
    // A live record on a link no page has checked is not kept; after a page it is.
    put(&again, "m1", (1, 7), None, false, &[rec(14)]);
    put(&again, "m1", (1, 7), Some(13), false, &recs(11..=13));
    put(&again, "m1", (1, 7), None, false, &[rec(14)]);
    assert_eq!(kept(&again, "m1"), (1..=14).collect::<Vec<_>>());
    let meta = json_at(&session.join("meta.json"));
    assert_eq!((meta["lastSeq"].as_u64(), meta["generation"].as_u64()), (Some(14), Some(7)));
    assert_eq!(meta["fromStart"], true);
}

#[test]
fn a_session_keeps_its_newest_records_within_its_bound_in_a_few_segments() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    for start in (1..=200).step_by(10) {
        put(&store, "m1", (1, 1), None, start == 1, &recs(start..=start + 9));
    }
    assert_eq!(kept(&store, "m1"), (161..=200).collect::<Vec<_>>(), "the newest {SESSION_EVENTS}");
    let segs = files(&dir.path().join("huge-blue/m1"));
    assert_eq!(segs.iter().filter(|n| n.starts_with("seg-")).count(), 4, "{segs:?}");
    assert!(!lock(&store.0.state).sessions[&key("m1")].meta.from_start, "older ones went");
}

#[test]
fn older_history_paged_in_later_goes_before_the_newest_records() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    put(&store, "m1", (1, 1), Some(400), false, &recs(361..=400));
    // The reader scrolls back: older pages land in later segments.
    put(&store, "m1", (1, 1), Some(400), false, &recs(331..=360));
    put(&store, "m1", (1, 1), Some(400), false, &recs(301..=330));
    let got = kept(&store, "m1");
    assert!(got.ends_with(&(361..=400).collect::<Vec<_>>()), "the newest stay: {got:?}");
    assert!(got.len() <= SESSION_EVENTS + SEGMENT_EVENTS, "{}", got.len());
}

#[test]
fn all_sessions_stay_within_the_total_and_the_least_recently_captured_goes() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    let big = |seq: u64| json!({"seq": seq, "kind": "k", "msg": {"t": "x".repeat(4000)}});
    for (i, id) in ["a1", "a2", "a3", "a4"].iter().enumerate() {
        put(&store, id, (1, 1), None, false, &[big(1), big(2), big(3)]);
        lock(&store.0.state).sessions.get_mut(&key(id)).unwrap().meta.captured_at = i as u64 + 1;
    }
    assert_eq!(files(&dir.path().join("huge-blue")), ["a2", "a3", "a4"], "the oldest capture went");
    let total: u64 = lock(&store.0.state).sessions.values().map(Snap::disk_bytes).sum();
    assert!(total <= TOTAL_BYTES, "{total}");
}

#[test]
fn a_full_disk_leaves_no_segment_keeps_the_records_and_writes_them_later() {
    static FAILS: AtomicU32 = AtomicU32::new(1);
    fn full_disk(path: &Path, bytes: &[u8]) -> Result<()> {
        if FAILS.load(Ordering::SeqCst) > 0 {
            FAILS.fetch_sub(1, Ordering::SeqCst);
            // As `write_atomic` leaves it: no temporary file, nothing renamed.
            return Err(anyhow::Error::new(std::io::Error::from_raw_os_error(libc::ENOSPC))
                .context(format!("write {}", path.display())));
        }
        crate::config::write_atomic(path, bytes)
    }
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = PeerSnapshots::with_writer(Some(dir.path().to_owned()), full_disk);
    put(&store, "m1", (1, 1), None, false, &recs(1..=5));
    let session = dir.path().join("huge-blue/m1");
    assert!(files(&session).iter().all(|n| !n.starts_with("seg-")), "{:?}", files(&session));
    assert_eq!(kept(&store, "m1"), vec![1, 2, 3, 4, 5], "kept in memory");
    store.flush_now(Some("huge-blue"));
    assert_eq!(files(&session), ["meta.json", "seg-0.ndjson"]);
    let again = store_at(dir.path());
    put(&again, "m1", (1, 1), None, false, &[]);
    assert_eq!(kept(&again, "m1"), vec![1, 2, 3, 4, 5]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_background_write_is_tried_again_until_it_lands() {
    static CALLS: AtomicU32 = AtomicU32::new(0);
    fn flaky(path: &Path, bytes: &[u8]) -> Result<()> {
        if CALLS.fetch_add(1, Ordering::SeqCst) < 3 {
            return Err(anyhow::Error::new(std::io::Error::from_raw_os_error(libc::ENOSPC)));
        }
        crate::config::write_atomic(path, bytes)
    }
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = PeerSnapshots::with_writer(Some(dir.path().to_owned()), flaky);
    put(&store, "m1", (1, 1), None, false, &recs(1..=3));
    let seg = dir.path().join("huge-blue/m1/seg-0.ndjson");
    // The 10 ms flush delay, then retries 10, 20 and 40 ms apart.
    for _ in 0..300 {
        if seg.is_file() && !lock(&store.0.state).sessions[&key("m1")].scheduled {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(seg.is_file());
    assert!(CALLS.load(Ordering::SeqCst) >= 5, "three failures, then the segment and meta");
    let state = lock(&store.0.state);
    let snap = &state.sessions[&key("m1")];
    assert!(snap.pending.is_empty() && !snap.scheduled && snap.failures == 0);
}

#[test]
fn a_batch_larger_than_a_segment_is_split_and_the_session_stays_within_its_bound() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    put(&store, "m1", (1, 1), Some(35), false, &recs(1..=35));
    let session = dir.path().join("huge-blue/m1");
    let segs: Vec<String> = files(&session).into_iter().filter(|n| n.starts_with("seg-")).collect();
    assert_eq!(segs.len(), 4, "{segs:?}");
    for n in &segs {
        let len = std::fs::metadata(session.join(n)).unwrap().len();
        assert!(len <= SEGMENT_BYTES, "{n}: {len}");
    }
    assert_eq!(kept(&store, "m1"), (1..=35).collect::<Vec<_>>());
}

#[test]
fn after_a_restart_a_page_behind_the_copy_replaces_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    put(&store, "m1", (1, 7), Some(20), false, &recs(1..=20));
    // A new daemon, on its first link, hears a journal that ends before the copy does.
    let again = store_at(dir.path());
    put(&again, "m1", (1, 7), Some(3), false, &recs(1..=3));
    assert_eq!(kept(&again, "m1"), vec![1, 2, 3]);
}

#[test]
fn unwritten_records_stay_within_their_bound_while_the_disk_is_full() {
    fn full(_: &Path, _: &[u8]) -> Result<()> {
        Err(anyhow::Error::new(std::io::Error::from_raw_os_error(libc::ENOSPC)))
    }
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = PeerSnapshots::with_writer(Some(dir.path().to_owned()), full);
    let big = |seq: u64| json!({"seq": seq, "kind": "k", "msg": {"t": "x".repeat(3000)}});
    for id in ["b1", "b2", "b3", "b4", "b5"] {
        put(&store, id, (1, 1), None, false, &(1..=4).map(big).collect::<Vec<_>>());
    }
    let state = lock(&store.0.state);
    let pending: u64 = state.sessions.values().map(|s| s.pending_bytes).sum();
    assert!(pending <= PENDING_BYTES, "{pending}");
    assert_eq!(pending, state.pending_bytes);
}

#[test]
fn a_recreated_or_restored_session_replaces_the_copy_instead_of_merging() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = store_at(dir.path());
    put(&store, "m1", (1, 7), Some(10), false, &recs(1..=10));
    // Another generation: the peer recreated the session.
    put(&store, "m1", (1, 9), Some(2), true, &recs(1..=2));
    assert_eq!(kept(&store, "m1"), vec![1, 2]);
    put(&store, "m1", (1, 9), Some(20), false, &recs(3..=20));
    // On one link, a page naming an older lastSeq raced a live record: kept.
    put(&store, "m1", (1, 9), Some(4), false, &recs(3..=4));
    assert_eq!(kept(&store, "m1"), (1..=20).collect::<Vec<_>>());
    // After a reconnect it is a journal behind the copy (a VM back on an older disk), even when
    // a live record on the new link came first: that one is not kept.
    put(&store, "m1", (2, 9), None, false, &[rec(21)]);
    assert_eq!(kept(&store, "m1"), (1..=20).collect::<Vec<_>>());
    put(&store, "m1", (2, 9), Some(4), false, &recs(3..=4));
    assert_eq!(kept(&store, "m1"), vec![3, 4]);
    // A page with nothing to keep leaves no copy.
    put(&store, "m2", (2, 9), Some(0), true, &[]);
    assert!(!lock(&store.0.state).sessions.contains_key(&key("m2")));
}

#[test]
fn a_retry_after_a_failed_meta_write_adds_nothing_twice_and_a_big_record_opens_a_segment() {
    static FAILS: AtomicU32 = AtomicU32::new(1);
    fn meta_fails(path: &Path, bytes: &[u8]) -> Result<()> {
        if path.ends_with("meta.json") && FAILS.fetch_sub(1, Ordering::SeqCst) == 1 {
            return Err(anyhow::Error::new(std::io::Error::from_raw_os_error(libc::ENOSPC)));
        }
        crate::config::write_atomic(path, bytes)
    }
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let store = PeerSnapshots::with_writer(Some(dir.path().to_owned()), meta_fails);
    put(&store, "m1", (1, 1), Some(3), false, &recs(1..=3));
    store.flush_now(None);
    let session = dir.path().join("huge-blue/m1");
    let lines = std::fs::read_to_string(session.join("seg-0.ndjson")).unwrap().lines().count();
    assert_eq!((lines, kept(&store, "m1")), (3, vec![1, 2, 3]), "each record once");
    assert_eq!(json_at(&session.join("meta.json"))["lastSeq"], 3);
    // A record that does not fit what the open segment has left starts the next one.
    let big =
        json!({"seq": 4, "kind": "k", "msg": {"t": "x".repeat(SEGMENT_BYTES as usize - 200)}});
    put(&store, "m1", (1, 1), None, false, &[big]);
    for n in files(&session).iter().filter(|n| n.starts_with("seg-")) {
        assert!(std::fs::metadata(session.join(n)).unwrap().len() <= SEGMENT_BYTES, "{n}");
    }
    assert_eq!(files(&session), ["meta.json", "seg-0.ndjson", "seg-1.ndjson"]);
}

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
    peer
}

#[test]
fn a_down_peers_records_and_forwarded_pages_are_kept_and_purges_drop_them() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, "huge-blue");
    let row = json!({"sessionId": "m1", "name": "lane", "status": "running", "createdAt": 42,
                     "updatedAt": 5, "retry": {"attempt": 1, "of": 3, "nextAt": 99}});
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![row]));
    let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
    hub.capture_peer_page("huge-blue", "m1", &json!({"limit": 400}), &page);
    for seq in 3..=4 {
        let params = json!({"sessionId": "m1", "seq": seq, "at": seq, "dir": "mux", "kind": "prompt", "msg": {}});
        let notice = PeerNotice::Notification { method: method::MUX_EVENT.into(), params };
        hub.apply_peer_notice("huge-blue", peer.generation, notice);
    }
    let notice = PeerNotice::Disconnected("connect timed out".into());
    hub.apply_peer_notice("huge-blue", peer.generation, notice);
    assert_eq!(kept(&hub.peer_snapshots, "m1"), vec![1, 2, 3, 4]);
    let meta = json_at(&dir.path().join("peers/huge-blue/m1/meta.json"));
    assert_eq!(meta["generation"], 42);
    assert_eq!(meta["summary"]["stale"], true);
    assert!(
        meta["summary"].get("retry").is_none(),
        "no countdown from a peer that is down: {meta}"
    );

    // A purge on the peer drops it; removing the peer drops all of its copies.
    let purged = json!({"sessionId": "m1"});
    let notice = PeerNotice::SessionChanged { session: purged, kind: "purged".into(), seq: 5 };
    hub.apply_peer_notice("huge-blue", peer.generation, notice);
    assert!(!dir.path().join("peers/huge-blue/m1").exists());
    // A page of a session it no longer lists is not kept; one it lists is.
    hub.capture_peer_page("huge-blue", "m1", &json!({}), &page);
    assert!(!dir.path().join("peers/huge-blue/m1").exists(), "purged stays purged");
    let m2 = json!({"sessionId": "m2", "name": "two", "status": "idle", "createdAt": 42, "updatedAt": 5});
    hub.apply_peer_notice("huge-blue", peer.generation, PeerNotice::Sessions(vec![m2]));
    hub.capture_peer_page("huge-blue", "m2", &json!({}), &page);
    assert!(dir.path().join("peers/huge-blue/m2").exists());
    hub.forget_peer_cache("huge-blue");
    assert!(!dir.path().join("peers/huge-blue").exists());
}
