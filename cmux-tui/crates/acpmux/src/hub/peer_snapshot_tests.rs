//! `peer_snapshot.rs`: the store's bounds, a full disk, refused removals, a restart, and a
//! directory that does not read; then which copy may grow: generations, joins, links, lags
//! (the files: `disk_tests.rs`). The tests drive the store's thread body directly; `keep` puts a
//! copy in place for the tests of what is done with it.

use super::*;

const PEER: &str = "huge-blue";

fn rec(mux: &str, seq: u64) -> Value {
    json!({"sessionId": mux, "seq": seq, "at": seq, "dir": "in", "kind": "agent_message_chunk",
           "msg": {"text": format!("line {seq}")}})
}

fn key(mux: &str) -> Key {
    (PEER.to_owned(), mux.to_owned())
}

fn store_at(dir: &Path) -> Store {
    let mut store = Store::new(disk::root(dir), Arc::default(), Arc::default());
    store.scan();
    store
}

/// Keeps `range` of `mux` as a run its copy covers, starting the copy when there is none.
fn keep(store: &mut Store, mux: &str, range: std::ops::RangeInclusive<u64>) {
    let key = key(mux);
    if !store.load(&key) {
        let head = Head {
            peer: PEER.into(),
            session_id: mux.into(),
            generation: Some(7),
            first_seq: *range.start(),
            ..Head::default()
        };
        let mut copy = Kept::new(head, 0);
        copy.records = Some(BTreeMap::new());
        store.insert(key.clone(), copy);
    }
    let h = &mut store.copies.get_mut(&key).unwrap().head;
    (h.first_seq, h.last_seq) = (h.first_seq.min(*range.start()), h.last_seq.max(*range.end()));
    h.from_start = h.first_seq <= 1;
    store.add(&key, range.map(|s| rec(mux, s)).collect());
}

/// The seqs `mux`'s copy holds, read in from its file if need be.
fn seqs(store: &mut Store, mux: &str) -> Vec<u64> {
    if !store.load(&key(mux)) {
        return vec![];
    }
    store.copies[&key(mux)].records.as_ref().map_or(vec![], |r| r.keys().copied().collect())
}

fn file(dir: &Path, mux: &str) -> PathBuf {
    disk::path(&disk::root(dir), &key(mux)).unwrap()
}

#[test]
fn a_copy_survives_a_restart_and_keeps_each_seq_once() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m1", 1..=10);
    keep(&mut store, "m1", 5..=13);
    store.write_due(None, When::Last);
    let text = std::fs::read_to_string(file(dir.path(), "m1")).unwrap();
    assert_eq!(text.lines().count(), 1 + 13, "a head line and each record once");
    let mut again = store_at(dir.path());
    assert_eq!(seqs(&mut again, "m1"), (1..=13).collect::<Vec<_>>());
    assert!(again.copies[&key("m1")].head.from_start);
}

#[test]
fn a_record_past_the_session_bound_alone_goes_and_the_copy_covers_what_follows() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m1", 1..=1);
    let mut huge = rec("m1", 2);
    huge["msg"]["text"] = json!("x".repeat(SESSION_BYTES as usize));
    store.add(&key("m1"), vec![huge, rec("m1", 3)]);
    assert_eq!(seqs(&mut store, "m1"), vec![3]);
    let head = &store.copies[&key("m1")].head;
    assert_eq!((head.first_seq, head.from_start), (3, false));
}

#[test]
fn copies_stay_within_their_bounds_and_the_least_recently_used_goes() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m0", 1..=(SESSION_EVENTS as u64 + 15));
    let kept = seqs(&mut store, "m0");
    assert_eq!((kept.len(), kept.last()), (SESSION_EVENTS, Some(&(SESSION_EVENTS as u64 + 15))));
    assert!(!store.copies[&key("m0")].head.from_start, "its first records went");
    let names: Vec<String> = (1..12).map(|i| format!("m{i}")).collect();
    for m in &names {
        keep(&mut store, m, 1..=SESSION_EVENTS as u64);
        store.write_due(None, When::Last);
        assert!(store.memory <= MEMORY_BYTES, "{} past the memory bound", store.memory);
        assert!(store.disk_with(None, 0) <= TOTAL_BYTES);
    }
    assert!(!file(dir.path(), "m0").exists(), "the least recently used went");
    assert!(file(dir.path(), "m11").exists());
    // A copy unloaded from memory reads back from its file.
    let unloaded = store.copies.iter().find(|(_, c)| c.records.is_none() && c.disk > 0);
    let unloaded = unloaded.map(|(k, _)| k.1.clone()).expect("a written copy was unloaded");
    assert_eq!(seqs(&mut store, &unloaded).len(), SESSION_EVENTS);
}

fn refuse(_: &Path, _: &[u8]) -> anyhow::Result<()> {
    Err(std::io::Error::from_raw_os_error(libc::ENOSPC).into())
}

#[test]
fn a_full_disk_keeps_the_records_and_writes_them_once_it_can() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    store.write = refuse;
    keep(&mut store, "m1", 1..=4);
    store.write_due(None, When::Last);
    let retry = store.copies[&key("m1")].retry;
    store.write_due(None, When::Last);
    assert!(store.copies[&key("m1")].retry > retry, "the retry backs off");
    assert!(store.wake.is_some() && !file(dir.path(), "m1").exists());
    store.write = crate::config::write_atomic;
    std::thread::sleep(Duration::from_millis(200));
    store.write_due(None, When::Due);
    assert!(file(dir.path(), "m1").exists() && store.copies[&key("m1")].due.is_none());
    // A flush tries again only what is due: a failed write keeps its backoff.
    store.write = refuse;
    keep(&mut store, "m1", 5..=5);
    store.write_due(None, When::Pending);
    let (due, retry) = (store.copies[&key("m1")].due, store.copies[&key("m1")].retry);
    store.write_due(None, When::Pending);
    assert!(
        due.is_some()
            && store.copies[&key("m1")].due == due
            && store.copies[&key("m1")].retry == retry
    );
    // Unwritten copies past the memory bound go, never past it; empty ones count too.
    for i in 0..8 {
        keep(&mut store, &format!("w{i}"), 1..=SESSION_EVENTS as u64);
        store.write_due(None, When::Last);
        assert!(store.memory <= MEMORY_BYTES);
    }
    for i in 0..1000 {
        keep(&mut store, &format!("e{i}"), std::ops::RangeInclusive::new(1, 0));
        store.write_due(None, When::Last);
    }
    assert!(store.memory <= MEMORY_BYTES && store.copies.len() < 200, "{}", store.copies.len());
}

#[test]
fn the_disk_bound_evicts_written_copies_before_one_not_written_yet() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    for m in ["old", "clean"] {
        keep(&mut store, m, 1..=SESSION_EVENTS as u64);
        store.write_due(None, When::Last);
    }
    // "old": the least recently used, with a write that failed and waits its retry.
    keep(&mut store, "old", 41..=41);
    let c = store.copies.get_mut(&key("old")).unwrap();
    (c.used, c.failures, c.due) = (0, 1, Some(Instant::now() + RETRY_MAX));
    for i in 0..12 {
        keep(&mut store, &format!("n{i}"), 1..=SESSION_EVENTS as u64);
        store.write_due(None, When::Pending);
        if !file(dir.path(), "clean").exists() {
            break;
        }
    }
    assert!(!file(dir.path(), "clean").exists(), "the written copy went");
    assert!(store.copies.contains_key(&key("old")), "the older unwritten one stays");
}

#[test]
fn a_restart_drops_what_is_not_a_copy_and_cuts_one_past_its_bound() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let root = disk::root(dir.path());
    let head = |mux: &str| Head {
        peer: PEER.into(),
        session_id: mux.into(),
        from_start: true,
        ..Head::default()
    };
    let big: BTreeMap<u64, Value> =
        (1..=(SESSION_EVENTS as u64 + 5)).map(|s| (s, rec("m1", s))).collect();
    disk::write(crate::config::write_atomic, &root, &key("m1"), &disk::encode(&head("m1"), &big))
        .unwrap();
    // Another session's copy under m2's name, and a leftover temporary file.
    disk::write(crate::config::write_atomic, &root, &key("m2"), &disk::encode(&head("m9"), &big))
        .unwrap();
    let tmp = file(dir.path(), "m1").with_extension("tmp-1-1");
    std::fs::write(&tmp, b"x").unwrap();
    // A peer whose only file is not a copy: its directory goes with it.
    let gone = ("gone".to_owned(), "x".to_owned());
    disk::write(crate::config::write_atomic, &root, &gone, &disk::encode(&head("m9"), &big))
        .unwrap();
    let mut store = store_at(dir.path());
    assert!(!file(dir.path(), "m2").exists() && !tmp.exists());
    assert!(!disk::peer_dir(&root, "gone").unwrap().exists());
    assert_eq!(seqs(&mut store, "m1").len(), SESSION_EVENTS);
    store.write_due(None, When::Last);
    let text = std::fs::read_to_string(file(dir.path(), "m1")).unwrap();
    assert_eq!(text.lines().count(), 1 + SESSION_EVENTS, "written back within its bound");
}

/// Runs `f` with `dir` read-only, so removals in it are refused; None when it cannot be.
fn read_only<T>(dir: &Path, f: impl FnOnce() -> T) -> Option<T> {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: getuid has no preconditions.
    if unsafe { libc::getuid() } == 0 {
        return None; // root removes anyway
    }
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o500)).unwrap();
    let out = f();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    Some(out)
}

#[test]
fn a_refused_removal_stays_counted_and_holds_up_writes_past_the_total() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    for i in 0..9 {
        keep(&mut store, &format!("m{i}"), 1..=SESSION_EVENTS as u64);
        store.write_due(None, When::Last);
    }
    let peer_dir = disk::peer_dir(&disk::root(dir.path()), PEER).unwrap();
    let other = ("other".to_owned(), "n".to_owned());
    let held = read_only(&peer_dir, || {
        for i in 0..9 {
            store.remove(&key(&format!("m{i}")));
        }
        // A copy near its own bound: no room beside what the refused removals hold.
        let head = Head { peer: "other".into(), session_id: "n".into(), ..Head::default() };
        let mut copy = Kept::new(head, 0);
        copy.records = Some(BTreeMap::new());
        store.insert(other.clone(), copy);
        let big =
            |seq: u64| json!({"sessionId": "n", "seq": seq, "msg": {"text": "x".repeat(400)}});
        store.add(&other, (1..=SESSION_EVENTS as u64).map(big).collect());
        store.write_due(None, When::Last);
        (store.dead.values().sum::<u64>(), store.copies[&other].disk)
    });
    let Some((dead, written)) = held else { return };
    assert!(dead > TOTAL_BYTES / 2, "the refused removals stay counted: {dead}");
    assert_eq!(written, 0, "no room while the refused removals hold the total");
    store.write_due(None, When::Last);
    assert!(store.dead.is_empty() && store.copies[&other].disk > 0, "tried again once allowed");
    assert!(!peer_dir.exists(), "the emptied directory goes too");
}

#[test]
fn a_directory_that_does_not_read_or_is_a_symlink_holds_up_every_write() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let root = disk::root(dir.path());
    crate::config::private_state_dir(&root).unwrap();
    let held = read_only(&root, || {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
        let mut store = store_at(dir.path());
        keep(&mut store, "m1", 1..=2);
        store.write_due(None, When::Last);
        store
    });
    if let Some(mut store) = held {
        assert!(store.copies[&key("m1")].due.is_some(), "not written while the disk is unknown");
        // Only the scan's retry wakes the thread meanwhile, at its backoff: never a spin.
        assert_eq!(store.wake, store.scan_retry.map(|(at, _)| at));
        store.write_due(None, When::Last);
        assert!(store.scanned && file(dir.path(), "m1").exists());
    }
    // A symlinked directory is never read or emptied.
    let linked = cmux_unix_socket::short_test_dir("acpmux-ps");
    let elsewhere = linked.path().join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    std::fs::write(elsewhere.join("keep.txt"), b"not ours").unwrap();
    std::os::unix::fs::symlink(&elsewhere, disk::root(linked.path())).unwrap();
    let mut store = Store::new(disk::root(linked.path()), Arc::default(), Arc::default());
    assert!(!store.scan() && elsewhere.join("keep.txt").exists());
}

#[test]
fn a_head_past_its_bound_is_not_written_and_a_flush_waits_in_the_queue_once() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m1", 1..=2);
    store.copies.get_mut(&key("m1")).unwrap().head.summary =
        json!({"title": "x".repeat(HEAD_BYTES as usize)});
    store.write_due(None, When::Last);
    assert!(!file(dir.path(), "m1").exists() && store.copies.is_empty());
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    for _ in 0..1000 {
        snaps.flush(Some(PEER));
    }
    assert!(snaps.queued.load(Ordering::Acquire) <= OP_BYTES, "one flush of a peer waits at most");
    snaps.flush_now();
}

fn recs(range: std::ops::RangeInclusive<u64>) -> Vec<Value> {
    range.map(|s| rec("m1", s)).collect()
}

fn list(store: &mut Store, rows: &[(&str, u64)]) {
    let rows = rows.iter().map(|(m, g)| ((*m).to_owned(), Some(*g))).collect();
    store.take(Op::Listed { peer: PEER.into(), rows, full: true });
}

/// An attach page of generation `g` on `link`: the newest records, `more` before them.
fn attach(g: u64, link: u64, more: bool, records: Vec<Value>) -> Page {
    let last = records.iter().filter_map(seq_of).max();
    Page {
        link: (1, link),
        asked: Some(g),
        generation: Some(g),
        has_more: more,
        host_last_seq: last,
        records,
        ..Page::default()
    }
}

/// An events page after `after`, asked while the row named `g`.
fn events(g: u64, link: u64, after: u64, records: Vec<Value>) -> Page {
    let last = records.iter().filter_map(seq_of).max();
    Page {
        link: (1, link),
        asked: Some(g),
        after: Some(after),
        host_last_seq: last,
        records,
        ..Page::default()
    }
}

/// `record` as one of session `mux`'s.
fn of(mux: &str, mut record: Value) -> Value {
    record["sessionId"] = json!(mux);
    record
}

fn put(store: &mut Store, mux: &str, mut page: Page) {
    page.records = page.records.into_iter().map(|r| of(mux, r)).collect();
    store.take(Op::Page { key: key(mux), page });
}

fn live(store: &mut Store, mux: &str, link: u64, seq: u64) {
    store.take(Op::Record { key: key(mux), link: (1, link), record: rec(mux, seq) });
}

fn whole(store: &Store, mux: &str) -> bool {
    store.copies[&key(mux)].head.from_start
}

#[test]
fn only_the_listed_generation_starts_or_grows_a_copy() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    // Not listed: nothing is kept.
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    assert!(seqs(&mut store, "m1").is_empty());
    list(&mut store, &[("m1", 7)]);
    // A page naming no generation (events) never starts a copy, nor does one asked of another.
    put(&mut store, "m1", events(7, 1, 0, recs(1..=3)));
    let mut stale = attach(7, 1, false, recs(1..=3));
    stale.asked = Some(6);
    put(&mut store, "m1", stale);
    assert!(seqs(&mut store, "m1").is_empty());
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3]);

    // The session is recreated (generation 8): the list drops the copy, and a slow page of
    // generation 7, or an events page asked while 7 was listed, never lands in 8's place.
    list(&mut store, &[("m1", 8)]);
    assert!(seqs(&mut store, "m1").is_empty());
    put(&mut store, "m1", attach(7, 1, false, recs(1..=5)));
    put(&mut store, "m1", events(7, 1, 3, recs(4..=5)));
    assert!(seqs(&mut store, "m1").is_empty());
    put(&mut store, "m1", attach(8, 1, false, recs(1..=2)));
    put(&mut store, "m1", events(7, 1, 2, recs(3..=4)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2]);
    // A row with no generation keeps no copy.
    store.take(Op::Listed { peer: PEER.into(), rows: vec![("m1".into(), None)], full: false });
    assert!(seqs(&mut store, "m1").is_empty());
}

#[test]
fn a_page_continues_a_copy_only_where_it_joins_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, true, recs(5..=8)));
    // An attach page whose oldest record leaves a gap after the copy replaces it.
    put(&mut store, "m1", attach(7, 1, true, recs(12..=14)));
    assert_eq!(seqs(&mut store, "m1"), vec![12, 13, 14]);
    // An events page after a seq the copy has not reached drops it (it cannot start one).
    put(&mut store, "m1", events(7, 1, 20, recs(21..=22)));
    assert!(seqs(&mut store, "m1").is_empty());
    put(&mut store, "m1", attach(7, 1, true, recs(5..=8)));
    put(&mut store, "m1", events(7, 1, 8, recs(9..=10)));
    put(&mut store, "m1", attach(7, 1, true, recs(9..=11)));
    assert_eq!(seqs(&mut store, "m1"), (5..=11).collect::<Vec<_>>());
    // On another link, a peer behind the copy (an older disk) replaces it; on the link that
    // paged it, a page that raced a live record does not.
    live(&mut store, "m1", 1, 12);
    let mut raced = attach(7, 1, true, recs(9..=11));
    raced.host_last_seq = Some(11);
    put(&mut store, "m1", raced);
    assert_eq!(seqs(&mut store, "m1"), (5..=12).collect::<Vec<_>>());
    put(&mut store, "m1", attach(7, 2, true, recs(8..=9)));
    assert_eq!(seqs(&mut store, "m1"), vec![8, 9]);
}

#[test]
fn a_live_record_needs_a_page_on_its_link_and_none_is_taken_after_a_lag() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    live(&mut store, "m1", 1, 1);
    assert!(seqs(&mut store, "m1").is_empty(), "no copy, no record");
    put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
    live(&mut store, "m1", 1, 3);
    // One past a seq the copy never saw would leave a hole.
    live(&mut store, "m1", 1, 5);
    // A record of a link no page joined the copy on; after it, the old link is too late.
    live(&mut store, "m1", 2, 4);
    live(&mut store, "m1", 1, 4);
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3]);
    put(&mut store, "m1", attach(7, 2, true, recs(3..=6)));
    live(&mut store, "m1", 2, 7);
    assert_eq!(seqs(&mut store, "m1"), (1..=7).collect::<Vec<_>>());
    // A lag of an older link, taken late, leaves the copy on the newer one.
    store.take(Op::Lagged { peer: PEER.into(), link: (1, 1) });
    live(&mut store, "m1", 2, 8);
    store.take(Op::Lagged { peer: PEER.into(), link: (1, 2) });
    live(&mut store, "m1", 2, 9);
    assert_eq!(seqs(&mut store, "m1").last(), Some(&8), "none after a lag until a page");
    // A page of the old link, taken late, does not come back either.
    put(&mut store, "m1", attach(7, 1, false, recs(1..=10)));
    assert_eq!(seqs(&mut store, "m1").last(), Some(&8));
}

#[test]
fn a_peer_behind_what_the_copy_saw_replaces_it_and_older_history_is_left_out() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    // A forward page holds 1..=5 of a peer at 1000.
    let mut first = events(7, 1, 0, recs(1..=5));
    (first.has_more, first.host_last_seq) = (true, Some(1000));
    // ...which an attach has to start: an events page alone never does.
    put(&mut store, "m1", attach(7, 1, true, recs(3..=5)));
    put(&mut store, "m1", first);
    assert_eq!(seqs(&mut store, "m1"), (1..=5).collect::<Vec<_>>());
    // The VM came back on an older disk (at 200) on a new link: not this copy's journal.
    let mut after = events(7, 2, 5, recs(6..=8));
    after.host_last_seq = Some(200);
    put(&mut store, "m1", after);
    assert!(seqs(&mut store, "m1").is_empty());
    // Older history that does not reach the copy is left out, never joined across the gap.
    put(&mut store, "m1", attach(7, 2, true, recs(901..=910)));
    put(&mut store, "m1", events(7, 2, 0, recs(1..=5)));
    assert_eq!(seqs(&mut store, "m1"), (901..=910).collect::<Vec<_>>());
    assert!(!store.copies[&key("m1")].head.from_start);
}

#[test]
fn an_empty_page_from_a_peer_gone_back_drops_the_copy() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    // A VM resumed from before its first record: an empty attach on a new link, `lastSeq` 0.
    let mut empty = attach(7, 2, false, vec![]);
    empty.host_last_seq = Some(0);
    put(&mut store, "m1", empty);
    assert!(seqs(&mut store, "m1").is_empty());
    // Its new journal never joins the old one.
    put(&mut store, "m1", attach(7, 2, true, recs(4..=5)));
    assert_eq!(seqs(&mut store, "m1"), vec![4, 5]);
}

#[test]
fn a_page_covers_past_its_last_record_only_as_far_as_the_peer_says_it_holds() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7), ("m2", 7)]);
    // A peer that does not say (an older daemon reads its `lastSeq` after the page, so seq 3 may
    // have come between them): the page covers its own records, and 3 is never claimed.
    let mut page = attach(7, 1, false, recs(1..=2));
    page.host_last_seq = Some(3);
    put(&mut store, "m1", page);
    assert_eq!(store.copies[&key("m1")].head.last_seq, 2);
    live(&mut store, "m1", 1, 4);
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2], "4 does not join past 3");
    live(&mut store, "m1", 1, 3);
    live(&mut store, "m1", 1, 4);
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3, 4]);
    // One that says (`pageThrough`, its `lastSeq` read before the page) covers to it: what it
    // left out up to there is of kinds not asked for, and the next live record joins.
    let mut page = attach(7, 1, false, vec![rec("m2", 1), rec("m2", 2)]);
    page.through = Some(5);
    put(&mut store, "m2", page);
    live(&mut store, "m2", 1, 6);
    assert_eq!(seqs(&mut store, "m2"), vec![1, 2, 6]);
    assert_eq!(store.copies[&key("m2")].head.last_seq, 6);
    // A watermark past what a seq can be is not a page.
    let mut odd = events(7, 1, 6, vec![rec("m2", 7)]);
    odd.through = Some(u64::MAX);
    put(&mut store, "m2", odd);
    assert_eq!(store.copies[&key("m2")].head.last_seq, 6);
    // A forward page cut by its limit covers only its records, whatever the peer says.
    let mut cut = events(7, 1, 6, vec![rec("m2", 7)]);
    (cut.has_more, cut.through) = (true, Some(9));
    put(&mut store, "m2", cut);
    assert_eq!(store.copies[&key("m2")].head.last_seq, 7);
}

#[test]
fn a_record_of_another_session_is_never_kept_as_this_ones() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    let mut page = attach(7, 1, false, recs(1..=3));
    page.records[1] = of("m2", rec("m1", 2));
    store.take(Op::Page { key: key("m1"), page });
    assert!(seqs(&mut store, "m1").is_empty(), "a page holding another session's record");
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    store.take(Op::Record { key: key("m1"), link: (1, 1), record: of("m2", rec("m1", 4)) });
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3]);
}

#[test]
fn what_was_unlisted_before_the_disk_read_is_applied_to_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m2", 7), ("m3", 7)]);
    for m in ["m2", "m3"] {
        put(&mut store, m, attach(7, 1, false, recs(1..=2)));
    }
    store.write_due(None, When::Last);
    // The next run cannot read the disk at first; meanwhile m2 is recreated and a full list
    // leaves m3 out.
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
    list(&mut again, &[("m2", 8)]);
    assert!(again.scan());
    assert!(again.copies.is_empty(), "{:?}", again.copies.keys().collect::<Vec<_>>());
    assert!(!file(dir.path(), "m2").exists() && !file(dir.path(), "m3").exists());
}

#[test]
fn a_name_too_long_for_a_file_is_never_kept() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    // An id with no file name is never kept: it could not be written.
    let long = "x".repeat(200);
    list(&mut store, &[(long.as_str(), 7)]);
    put(&mut store, &long, attach(7, 1, false, recs(1..=2)));
    assert!(!store.copies.contains_key(&key(&long)));
}
