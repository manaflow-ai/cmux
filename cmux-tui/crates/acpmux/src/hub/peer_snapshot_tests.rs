//! `peer_snapshot.rs`: the store's bounds, a full disk, refused removals, a restart, and a
//! directory that does not read; then which copy may grow: generations, joins, links, lags;
//! purges, removed peers and the queue's losses; the hub's taps (the files: `disk_tests.rs`). The tests drive the store's thread body directly; `keep` puts a
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
    let mut store = Store::new(disk::root(dir), Arc::default());
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
    // Older than any copy after it, whatever the clock's resolution.
    store.copies.get_mut(&key("m0")).unwrap().used = 0;
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
    // A flush writes what was not tried yet; a failed write keeps its backoff.
    store.write = refuse;
    keep(&mut store, "m1", 5..=5);
    store.write_due(None, When::Pending);
    assert_eq!(store.copies[&key("m1")].failures, 1, "tried at once");
    let later = Instant::now() + RETRY_MAX;
    let c = store.copies.get_mut(&key("m1")).unwrap();
    c.due = Some(later);
    let retry = c.retry;
    store.write_due(None, When::Pending);
    let c = &store.copies[&key("m1")];
    assert_eq!((c.due, c.retry, c.failures), (Some(later), retry, 1), "not before its retry");
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
    assert!(store.own <= KEPT_TOTAL && store.copies.len() < 100, "{}", store.copies.len());
}

#[test]
fn copies_a_late_scan_finds_stay_within_their_bound_and_written_ones_go_first() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    let empty = || std::ops::RangeInclusive::new(1, 0);
    for i in 0..40 {
        keep(&mut store, &format!("old{i}"), empty());
        store.write_due(None, When::Last);
    }
    assert!(store.own <= KEPT_TOTAL && store.copies.len() == 40);
    // The next run cannot read the disk at first and keeps new copies meanwhile; nothing it
    // writes works.
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    again.write = refuse;
    for i in 0..30 {
        keep(&mut again, &format!("new{i}"), empty());
    }
    assert!(again.scan());
    assert!(again.own <= KEPT_TOTAL, "{} past {KEPT_TOTAL}", again.own);
    assert_eq!((0..30).filter(|i| again.copies.contains_key(&key(&format!("new{i}")))).count(), 30);
}

#[test]
fn a_copy_a_late_scan_finds_goes_before_any_copy_not_written_yet() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    let empty = || std::ops::RangeInclusive::new(1, 0);
    // A longer id than any below: it costs at least what each of them does.
    keep(&mut store, "written-earlier", empty());
    store.write_due(None, When::Last);
    let cost = store.copies[&key("written-earlier")].own;
    // The next run, before its disk reads, keeps unwritten copies until the written one no
    // longer fits beside them.
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    again.write = refuse;
    let mut n = 0;
    while again.own + cost <= KEPT_TOTAL {
        keep(&mut again, &format!("n{n}"), empty());
        n += 1;
    }
    assert!(again.scan());
    assert!(!again.copies.contains_key(&key("written-earlier")), "the written copy goes");
    assert!(!file(dir.path(), "written-earlier").exists());
    let kept = (0..n).filter(|i| again.copies.contains_key(&key(&format!("n{i}")))).count();
    assert_eq!(kept, n, "every unwritten copy stays");
}

#[test]
fn the_disk_bound_evicts_written_copies_before_one_not_written_yet() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    for m in ["old", "clean"] {
        keep(&mut store, m, 1..=SESSION_EVENTS as u64);
        store.write_due(None, When::Last);
    }
    // Older than any copy after it ("old" older still), whatever the clock's resolution.
    store.copies.get_mut(&key("clean")).unwrap().used = 1;
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
        // A capture meanwhile, past its write's time, wakes the thread no earlier.
        store.copies.get_mut(&key("m1")).unwrap().due = Some(Instant::now());
        keep(&mut store, "m1", 3..=3);
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
    let mut store = Store::new(disk::root(linked.path()), Arc::default());
    assert!(!store.scan() && elsewhere.join("keep.txt").exists());
}

#[test]
fn a_head_past_its_bound_is_not_written_and_a_flush_waits_in_the_queue_once() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m1", 1..=2);
    // Its row grows past what a head may hold: it goes at once, before any write, and costs
    // nothing more. One just under the bound with the rest of its head past it goes too.
    for title in [HEAD_BYTES as usize, HEAD_BYTES as usize - 64] {
        keep(&mut store, "m1", 1..=2);
        store.copies.get_mut(&key("m1")).unwrap().head.summary =
            json!({"title": "x".repeat(title)});
        store.charge(&key("m1"));
        assert!(store.copies.is_empty() && store.own == 0 && store.memory == 0);
    }
    store.write_due(None, When::Last);
    assert!(!file(dir.path(), "m1").exists());
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    for _ in 0..1000 {
        snaps.flush(Some(PEER));
    }
    assert!(snaps.queued.load(Ordering::Acquire) <= OP_BYTES, "one flush of a peer waits at most");
    snaps.flush_now();
}

/// The thread's end of the queue, held here: nothing is taken until the test says.
fn hold(snaps: &PeerSnapshots) -> mpsc::Receiver<Queued> {
    let (tx, rx) = mpsc::channel();
    let handle = std::thread::spawn(|| {});
    *snaps.tx.lock().unwrap() = Some(Thread { tx, handle });
    rx
}

#[test]
fn ops_a_thread_never_took_give_back_their_room_and_go_before_the_next_threads() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    // A flush waits in the queue, once.
    let rx = hold(&snaps);
    snaps.flush(Some(PEER));
    snaps.flush(Some(PEER));
    assert_eq!(snaps.queued.load(Ordering::Acquire), OP_BYTES);
    // The thread ends without taking it (a panic): its room comes back, and it is kept for the
    // thread started after it, which takes it before anything it is sent.
    drop(rx);
    assert_eq!(snaps.queued.load(Ordering::Acquire), 0);
    assert_eq!(snaps.untaken.lock().unwrap().len(), 1);
    snaps.flush_now();
    assert!(snaps.untaken.lock().unwrap().is_empty() && snaps.dropped().flushes.is_empty());
    assert!(snaps.ended.lock().unwrap().is_none(), "the thread before was joined");
    snaps.flush(Some(PEER));
    snaps.flush_now();
    assert!(snaps.dropped().flushes.is_empty());
    assert_eq!(snaps.queued.load(Ordering::Acquire), 0);
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
    // A list read before 8 was named, taken late, takes nothing back: 8 stays listed and kept,
    // and a page asked on its row is not kept.
    list(&mut store, &[("m1", 7)]);
    assert_eq!(store.current(&key("m1")), Some(8));
    put(&mut store, "m1", attach(7, 1, false, recs(1..=5)));
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
    // A lag of a link nothing came on yet makes the link before it too late as well.
    put(&mut store, "m1", attach(7, 3, false, recs(6..=9)));
    store.take(Op::Lagged { peer: PEER.into(), link: (1, 4) });
    live(&mut store, "m1", 3, 10);
    assert_eq!(seqs(&mut store, "m1").last(), Some(&9));
}

#[test]
fn what_the_store_keeps_of_listings_is_bounded() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    // Listed with none by a peer whose full list came: no entry, and no copy.
    let none = vec![("m1".to_owned(), None), ("m2".to_owned(), None)];
    store.take(Op::Listed { peer: PEER.into(), rows: none, full: false });
    assert!(store.listed.is_empty());
    // Nor an id no file can have.
    list_one(&mut store, &"x".repeat(200), 7);
    assert!(store.listed.is_empty());
    // Past the bound, a session listed keeps no copy: its page is not taken.
    let rows = (0..LISTED_KEYS).map(|i| (format!("x{i}"), Some(7))).collect();
    store.take(Op::Listed { peer: PEER.into(), rows, full: false });
    list_one(&mut store, "m1", 7);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
    assert_eq!(store.listed.len(), LISTED_KEYS);
    assert!(!store.copies.contains_key(&key("m1")));
    // A full list makes room again.
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2]);
}

fn list_one(store: &mut Store, mux: &str, g: u64) {
    let rows = vec![(mux.to_owned(), Some(g))];
    store.take(Op::Listed { peer: PEER.into(), rows, full: false });
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
    // But the peer was seen that far: a page from it back below 9 is a peer gone back.
    assert_eq!(store.copies[&key("m2")].head.host_last_seq, 9);
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
fn an_empty_journal_starts_an_empty_copy_and_a_page_out_of_bounds_is_not_one() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    // A session with nothing in it yet: its first live record joins.
    let mut empty = attach(7, 1, false, vec![]);
    (empty.through, empty.host_last_seq) = (Some(0), Some(0));
    put(&mut store, "m1", empty);
    assert!(store.copies.contains_key(&key("m1")));
    live(&mut store, "m1", 1, 1);
    assert_eq!(seqs(&mut store, "m1"), vec![1]);
    // A record whose seq is out of bounds makes the page not one.
    let odd = json!({"sessionId": "m1", "seq": u64::MAX, "kind": "k"});
    put(&mut store, "m1", events(7, 1, 1, vec![rec("m1", 2), odd]));
    assert_eq!(seqs(&mut store, "m1"), vec![1]);
    // A row past what a head holds is not kept, nor the copy it came with.
    let mut big = events(7, 1, 1, recs(2..=2));
    big.row = Some(json!({"sessionId": "m1", "title": "x".repeat(HEAD_BYTES as usize)}));
    put(&mut store, "m1", big);
    assert!(!store.copies.contains_key(&key("m1")));
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

/// What `mux`'s file holds: its head and its seqs.
fn on_disk(path: &Path, mux: &str) -> Option<(Head, Vec<u64>)> {
    let read = disk::read(path, &(PEER.to_owned(), mux.to_owned())).unwrap();
    read.map(|(head, records)| (head, records.into_keys().collect()))
}

#[test]
fn a_purged_generation_stays_purged_until_the_peer_lists_without_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    store.write_due(None, When::Last);
    store.take(Op::Gone { key: key("m1"), generation: Some(7) });
    assert!(!file(dir.path(), "m1").exists());
    // A list sent before the purge names 7 again: still purged.
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    assert!(seqs(&mut store, "m1").is_empty());
    // The session recreated as 8 is kept.
    list(&mut store, &[("m1", 8)]);
    put(&mut store, "m1", attach(8, 1, false, recs(1..=2)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2]);
    // A purge with no generation bars every one until a full list leaves the session out.
    store.take(Op::Gone { key: key("m1"), generation: None });
    list(&mut store, &[("m1", 9)]);
    put(&mut store, "m1", attach(9, 1, false, recs(1..=2)));
    assert!(seqs(&mut store, "m1").is_empty());
    list(&mut store, &[]);
    assert!(store.barred.is_empty());
    list(&mut store, &[("m1", 9)]);
    put(&mut store, "m1", attach(9, 1, false, recs(1..=2)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2]);
}

#[test]
fn what_was_purged_or_unlisted_before_the_disk_read_is_applied_to_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7), ("m2", 7), ("m3", 7)]);
    for m in ["m1", "m2", "m3"] {
        put(&mut store, m, attach(7, 1, false, recs(1..=2)));
    }
    store.write_due(None, When::Last);
    // The next run cannot read the disk at first; meanwhile m1 is purged, m2 recreated, and a
    // full list leaves m3 out.
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    again.take(Op::Gone { key: key("m1"), generation: Some(7) });
    list(&mut again, &[("m2", 8)]);
    assert!(again.scan());
    assert!(again.copies.is_empty(), "{:?}", again.copies.keys().collect::<Vec<_>>());
    for m in ["m1", "m2", "m3"] {
        assert!(!file(dir.path(), m).exists());
    }

    // Every op of m4's peer, and of another peer, lost before the disk reads: what an earlier run
    // kept of them goes too, so no copy comes back past what it missed.
    let mut store = store_at(dir.path());
    list(&mut store, &[("m4", 7)]);
    put(&mut store, "m4", attach(7, 1, false, recs(1..=2)));
    let rows = vec![("n".to_owned(), Some(7))];
    store.take(Op::Listed { peer: "other".into(), rows, full: true });
    let page = attach(7, 1, false, vec![json!({"sessionId": "n", "seq": 1, "kind": "k"})]);
    store.take(Op::Page { key: ("other".into(), "n".into()), page });
    store.write_due(None, When::Last);
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    again.take(Op::LostPeer(PEER.into()));
    again.take(Op::LostPeer("other".into()));
    assert!(again.scan());
    assert!(again.copies.is_empty(), "{:?}", again.copies.keys().collect::<Vec<_>>());
}

#[test]
fn a_late_purge_of_an_older_generation_leaves_the_newer_copy() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 8)]);
    put(&mut store, "m1", attach(8, 1, false, recs(1..=2)));
    store.take(Op::Gone { key: key("m1"), generation: Some(7) });
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2]);
    put(&mut store, "m1", events(8, 1, 2, recs(3..=3)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3], "8 is still the listed generation");
    store.take(Op::Gone { key: key("m1"), generation: Some(8) });
    assert!(seqs(&mut store, "m1").is_empty());
}

#[test]
fn a_late_purge_of_an_older_generation_keeps_a_newer_copy_on_disk_and_a_late_listing_leaves_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 8)]);
    put(&mut store, "m1", attach(8, 1, false, recs(1..=2)));
    store.write_due(None, When::Last);
    // The next run lists 8, then is told of a purge of 7, before it can read the disk: generation
    // 8 there stays.
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    list(&mut again, &[("m1", 8)]);
    again.take(Op::Gone { key: key("m1"), generation: Some(7) });
    assert!(again.scan());
    assert_eq!(seqs(&mut again, "m1"), vec![1, 2]);
    // A list sent before the purge, naming 7, takes nothing and leaves 8 listed and kept.
    list(&mut again, &[("m1", 7)]);
    assert_eq!(again.listed.get(&key("m1")), Some(&Some(8)));
    put(&mut again, "m1", events(8, 1, 2, recs(3..=3)));
    assert_eq!(seqs(&mut again, "m1"), vec![1, 2, 3]);
}

#[test]
fn a_purge_told_again_without_its_generation_still_lets_the_recreated_session_back() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 42)]);
    put(&mut store, "m1", attach(42, 1, false, recs(1..=2)));
    // The hub's own purge names 42; the peer's notice of it comes once the row is gone.
    store.take(Op::Gone { key: key("m1"), generation: Some(42) });
    store.take(Op::Gone { key: key("m1"), generation: None });
    assert_eq!(store.barred.get(&key("m1")), Some(&Some(42)));
    list(&mut store, &[("m1", 43)]);
    put(&mut store, "m1", attach(43, 1, false, recs(1..=2)));
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2]);
    // Purges of sessions churned through stay within their bound.
    for i in 0..3 * BARRED_KEYS {
        store.take(Op::Gone { key: key(&format!("x{i}")), generation: Some(1) });
    }
    assert!(store.barred.len() <= BARRED_KEYS);
    // Before the disk reads, a bar that goes takes everything an earlier run kept with it.
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    for i in 0..=BARRED_KEYS {
        again.take(Op::Gone { key: key(&format!("x{i}")), generation: Some(1) });
    }
    assert!(again.unread_all);
}

#[test]
fn a_removed_peer_added_again_keeps_its_new_copies() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
    store.write_due(None, When::Last);
    store.take(Op::ForgetPeer(PEER.into()));
    assert!(!file(dir.path(), "m1").exists());
    list(&mut store, &[("m1", 9)]);
    store.take(Op::Page {
        key: key("m1"),
        page: Page { link: (2, 0), ..attach(9, 0, false, recs(1..=3)) },
    });
    store.write_due(None, When::Last);
    store.sweep();
    assert!(file(dir.path(), "m1").exists());
}

#[test]
fn captures_that_fall_behind_drop_the_copy_instead_of_leaving_a_hole() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    snaps.listed(PEER, vec![("m1".into(), Some(7))], true);
    snaps.page((PEER, "m1"), attach(7, 1, false, recs(1..=3)));
    snaps.flush_now();
    snaps.queued.fetch_add(QUEUED_BYTES, Ordering::AcqRel);
    snaps.record((PEER, "m1"), (1, 1), rec("m1", 4));
    snaps.queued.fetch_sub(QUEUED_BYTES, Ordering::AcqRel);
    snaps.record((PEER, "m1"), (1, 1), rec("m1", 5));
    snaps.flush_now();
    assert_eq!(on_disk(&disk::path(&disk::root(dir.path()), &key("m1")).unwrap(), "m1"), None);
    assert!(snaps.dropped().peers.is_empty());
}

#[test]
fn nothing_of_a_peer_is_queued_while_its_loss_waits() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    // The thread's end of the queue, held here: nothing is taken.
    let rx = hold(&snaps);
    snaps.queued.store(QUEUED_BYTES, Ordering::Release);
    snaps.gone(PEER, "m1", Some(7));
    snaps.queued.store(0, Ordering::Release);
    // Room again, but the loss stands for these: a list from before the purge, a page, a purge.
    snaps.listed(PEER, vec![("m1".into(), Some(7))], true);
    snaps.page((PEER, "m1"), attach(7, 1, false, recs(1..=2)));
    snaps.gone(PEER, "m1", Some(7));
    snaps.listed("other", vec![], true);
    // A removal of the peer lost too is kept with the loss.
    snaps.forget_peer(PEER);
    let mut ops: Vec<Op> = rx.try_iter().filter_map(Queued::take).collect();
    assert_eq!(ops.len(), 2);
    assert!(matches!(&ops[0], Op::LostPeer(p) if p == PEER));
    assert!(matches!(&ops[1], Op::Listed { peer, .. } if peer == "other"));
    let mut store = Store::new(disk::root(dir.path()), snaps.dropped.clone());
    store.scan();
    store.barred.insert(key("m1"), None);
    store.links.insert(PEER.into(), (1, 1));
    store.take(ops.remove(0));
    assert!(store.barred.is_empty() && store.links.is_empty() && snaps.dropped().peers.is_empty());
}

#[test]
fn past_its_bound_what_went_before_the_disk_read_takes_every_earlier_copy() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
    store.write_due(None, When::Last);
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    for i in 0..=UNREAD_KEYS {
        again.remove(&key(&format!("x{i}")));
        again.take(Op::LostPeer(format!("p{i}")));
    }
    assert_eq!((again.unread.len(), again.forgotten.len()), (UNREAD_KEYS, UNREAD_KEYS));
    assert!(again.scan());
    assert!(again.copies.is_empty() && !file(dir.path(), "m1").exists());
}

#[test]
fn a_capture_the_thread_never_took_is_a_loss_and_a_thread_that_ended_starts_again() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    snaps.listed(PEER, vec![("m1".into(), Some(7))], true);
    snaps.page((PEER, "m1"), attach(7, 1, false, recs(1..=3)));
    snaps.flush_now();
    // The thread ends (a panic) with the record in its queue: the record is not taken, so the copy
    // goes instead of growing past a hole, and the next op starts a thread again.
    let rx = hold(&snaps);
    snaps.record((PEER, "m1"), (1, 1), rec("m1", 4));
    drop(rx);
    snaps.flush_now();
    assert!(snaps.dropped().peers.is_empty() && snaps.dropped().unsent.is_empty());
    assert_eq!(on_disk(&disk::path(&disk::root(dir.path()), &key("m1")).unwrap(), "m1"), None);
    assert_eq!(snaps.queued.load(Ordering::Acquire), 0);
}

#[test]
fn a_loss_not_sent_yet_goes_with_the_next_op_or_flush_of_any_peer() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    let unsent = |p: &str| {
        let mut dropped = snaps.dropped();
        dropped.peers.insert(p.to_owned(), false);
        dropped.unsent.insert(p.to_owned());
    };
    // The thread's end of the queue, held here.
    let rx = hold(&snaps);
    unsent("a");
    snaps.listed("other", vec![], true);
    unsent("b");
    snaps.flush(None);
    let ops: Vec<Op> = rx.try_iter().filter_map(Queued::take).collect();
    assert!(matches!(&ops[0], Op::Listed { peer, .. } if peer == "other"));
    assert!(matches!(&ops[1], Op::LostPeer(p) if p == "a"));
    assert!(matches!(&ops[2], Op::LostPeer(p) if p == "b"));
    assert!(matches!(&ops[3], Op::Flush { peer: None, .. }));
    assert!(snaps.dropped().unsent.is_empty());
    {
        // Taken, as the thread does.
        let mut dropped = snaps.dropped();
        dropped.peers.clear();
        dropped.flushes.clear();
    }
    // The thread ends (a panic) with a page of "d" and a flush in its queue: the page goes as a
    // loss of its peer, sent with the next op, and the flush is no longer counted as queued.
    snaps.page(("d", "m1"), attach(7, 1, false, recs(1..=2)));
    snaps.flush(None);
    drop(rx);
    assert_eq!(snaps.untaken.lock().unwrap().len(), 2);
    snaps.flush_now();
    assert!(snaps.untaken.lock().unwrap().is_empty() && snaps.dropped().flushes.is_empty());
    assert!(snaps.dropped().peers.is_empty() && snaps.dropped().unsent.is_empty());
    assert_eq!(snaps.queued.load(Ordering::Acquire), 0);
}

#[test]
fn a_purge_of_an_id_no_file_can_have_bars_nothing() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    let long = "x".repeat(200);
    list(&mut store, &[(long.as_str(), 7)]);
    store.take(Op::Gone { key: key(&long), generation: Some(7) });
    assert!(store.barred.is_empty() && store.listed.is_empty());
}

#[test]
fn flushes_and_losses_wait_in_the_queue_once_and_captures_reserve_their_room() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    for _ in 0..1000 {
        snaps.flush(Some(PEER));
    }
    assert!(snaps.queued.load(Ordering::Acquire) <= OP_BYTES, "one flush of a peer waits at most");
    assert!(snaps.reserve(QUEUED_BYTES / 2));
    assert!(!snaps.reserve(QUEUED_BYTES), "past the bound, nothing is counted");
    snaps.queued.fetch_sub(QUEUED_BYTES / 2, Ordering::AcqRel);
}

#[test]
fn a_catch_up_that_finds_nothing_new_joins_its_link_and_a_lag_leaves_late_pages_late() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    // A reconnect (link 2) whose catch-up after 3 holds all there is and nothing new: it covers
    // no seq, but the copy now continues on link 2.
    let mut caught = events(7, 2, 3, vec![]);
    (caught.through, caught.host_last_seq) = (Some(3), Some(3));
    put(&mut store, "m1", caught);
    live(&mut store, "m1", 2, 4);
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3, 4]);
    // A lag of link 2 stops its records until a page, but link 2 still joined the copy: a page of
    // it that read `lastSeq` 3 before record 4 came is only late, not a peer gone back.
    store.take(Op::Lagged { peer: PEER.into(), link: (1, 2) });
    live(&mut store, "m1", 2, 5);
    let mut late = events(7, 2, 2, recs(3..=3));
    late.host_last_seq = Some(3);
    put(&mut store, "m1", late);
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3, 4]);
}

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// The daemon home the hub keeps its snapshots in (beside its peer caches).
fn snapshot_home(hub: &Hub) -> PathBuf {
    hub.store.peer_cache_dir().unwrap().parent().unwrap().to_owned()
}

fn add_idle_peer(hub: &Hub, name: &str) -> Arc<crate::peer::Peer> {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
    peer
}

#[test]
fn the_hub_keeps_a_down_peers_records_and_pages_and_purges_drop_them() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let path = |mux: &str| disk::path(&disk::root(&home), &key(mux)).unwrap();
    let peer = add_idle_peer(&hub, PEER);
    let row = json!({"sessionId": "m1", "name": "lane", "status": "running", "createdAt": 42,
                     "updatedAt": 5, "retry": {"attempt": 1, "of": 3, "nextAt": 99}});
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::Sessions(vec![row]));
    let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
    let on = |link: u64| (PEER, peer.generation, link, hub.listed_generation(PEER, "m1"));
    let notice = |seq: u64, link: u64| {
        let params = json!({"sessionId": "m1", "seq": seq, "at": seq, "dir": "mux", "kind": "prompt", "msg": {}});
        PeerNotice::Notification { method: method::MUX_EVENT.into(), params, link }
    };
    hub.capture_peer_page(
        on(0),
        ("m1", false),
        &json!({"limit": 400, "kinds": ["transcript"]}),
        &page,
    );
    // Older history, and a page of some kinds that leaves the transcript out, are not kept.
    hub.capture_peer_page(on(0), ("m1", false), &json!({"beforeSeq": 1}), &page);
    hub.capture_peer_page(on(0), ("m1", false), &json!({"kinds": ["prompt"]}), &page);
    hub.capture_peer_page(on(0), ("m1", false), &json!({"kinds": "prompt"}), &page);
    for seq in 3..=4 {
        hub.apply_peer_notice(PEER, peer.generation, notice(seq, 0));
    }
    // The link ends: what was read on it and handled late is not kept.
    peer.link_ended();
    hub.apply_peer_notice(PEER, peer.generation, notice(5, 0));
    let late = json!({"events": recs(5..=6), "hasMore": false, "lastSeq": 6});
    hub.capture_peer_page(on(0), ("m1", true), &json!({"afterSeq": 4}), &late);
    hub.apply_peer_notice(
        PEER,
        peer.generation,
        PeerNotice::Disconnected("connect timed out".into()),
    );
    hub.peer_snapshots.flush_now();
    let (head, seqs) = on_disk(&path("m1"), "m1").expect("m1's copy was written");
    assert_eq!(seqs, vec![1, 2, 3, 4]);
    assert_eq!((head.generation, head.summary["stale"].clone()), (Some(42), json!(true)));
    assert!(head.summary.get("retry").is_none(), "no countdown from a peer that is down: {head:?}");

    // A purge on the peer drops it, and a page of it afterwards is not kept.
    let purged = PeerNotice::SessionChanged {
        session: json!({"sessionId": "m1"}),
        kind: "purged".into(),
        seq: 5,
    };
    hub.apply_peer_notice(PEER, peer.generation, purged);
    hub.capture_peer_page(
        (PEER, peer.generation, peer.link_epoch(), Some(42)),
        ("m1", false),
        &json!({}),
        &page,
    );
    hub.peer_snapshots.flush_now();
    assert!(!path("m1").exists());
    // A recreated session (a changed row) replaces its copy; removing the peer drops them all.
    let m2 = |created: u64| json!({"sessionId": "m2", "name": "two", "status": "idle", "createdAt": created, "updatedAt": 5});
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::Sessions(vec![m2(42)]));
    let link = peer.link_epoch();
    let events: Vec<Value> = recs(1..=2).into_iter().map(|r| of("m2", r)).collect();
    let page =
        json!({"session": {"createdAt": 42}, "events": events, "hasMore": false, "lastSeq": 2});
    hub.capture_peer_page(
        (PEER, peer.generation, link, Some(42)),
        ("m2", false),
        &json!({}),
        &page,
    );
    hub.peer_snapshots.flush_now();
    assert!(path("m2").exists());
    let changed = PeerNotice::SessionChanged { session: m2(43), kind: "created".into(), seq: 6 };
    hub.apply_peer_notice(PEER, peer.generation, changed);
    hub.peer_snapshots.flush_now();
    assert!(!path("m2").exists());
    hub.forget_peer_cache(PEER);
    hub.peer_snapshots.flush_now();
    assert!(!disk::peer_dir(&disk::root(&home), PEER).unwrap().exists());
}

#[test]
fn an_events_page_of_a_session_recreated_meanwhile_is_not_kept() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let peer = add_idle_peer(&hub, PEER);
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "createdAt": 42, "updatedAt": 5});
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::Sessions(vec![row]));
    let on = (PEER, peer.generation, peer.link_epoch(), Some(42));
    let page = |created: u64, to: u64| {
        json!({"events": recs(3..=to), "hasMore": false, "lastSeq": to, "pageThrough": to,
               "createdAt": created})
    };
    let first = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false,
                       "lastSeq": 2, "pageThrough": 2});
    hub.capture_peer_page(on, ("m1", false), &json!({}), &first);
    // Asked while the row named 42, answered by the session recreated as 43 meanwhile.
    hub.capture_peer_page(on, ("m1", true), &json!({"afterSeq": 2}), &page(43, 4));
    hub.capture_peer_page(on, ("m1", true), &json!({"afterSeq": 2}), &page(42, 3));
    hub.peer_snapshots.flush_now();
    let path = disk::path(&disk::root(&home), &key("m1")).unwrap();
    assert_eq!(on_disk(&path, "m1").unwrap().1, vec![1, 2, 3]);
}

#[test]
fn a_purge_through_this_daemon_drops_only_its_peers_generation() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let path = |peer: &str| disk::path(&disk::root(&home), &(peer.into(), "m1".into())).unwrap();
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "createdAt": 42, "updatedAt": 5});
    let mut instances = HashMap::new();
    for name in [PEER, "clone"] {
        let peer = add_idle_peer(&hub, name);
        instances.insert(name, peer.generation);
        hub.apply_peer_notice(name, peer.generation, PeerNotice::Sessions(vec![row.clone()]));
        let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
        let on = (name, peer.generation, peer.link_epoch(), Some(42));
        hub.capture_peer_page(on, ("m1", false), &json!({}), &page);
    }
    hub.peer_snapshots.flush_now();
    assert!(path(PEER).exists() && path("clone").exists());
    // A clone's purge leaves the other machine's chat of the same id.
    hub.forget_remote(("clone", instances["clone"]), "m1", Some(42));
    // A purge asked of an older generation leaves the session recreated since.
    hub.forget_remote((PEER, instances[PEER]), "m1", Some(41));
    // One whose row named no generation leaves a session of one.
    hub.forget_remote((PEER, instances[PEER]), "m1", None);
    // A purge a replaced instance answered leaves the machine registered under the name now.
    hub.forget_remote((PEER, instances[PEER] + 1000), "m1", None);
    hub.peer_snapshots.flush_now();
    assert!(path(PEER).exists() && !path("clone").exists());
    assert!(hub.resolve_remote(&format!("{PEER}/m1")).is_some());
}

#[test]
fn an_events_page_with_no_cursor_covers_only_what_it_holds() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let peer = add_idle_peer(&hub, PEER);
    let row = json!({"sessionId": "m1", "name": "lane", "status": "idle", "createdAt": 42, "updatedAt": 5});
    hub.apply_peer_notice(PEER, peer.generation, crate::peer::PeerNotice::Sessions(vec![row]));
    let on = (PEER, peer.generation, peer.link_epoch(), Some(42));
    let first = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
    hub.capture_peer_page(on, ("m1", false), &json!({}), &first);
    // `_acpmux/events` with no `afterSeq` pages forward from the first record: 1 to 3 of 10.
    let page = json!({"events": recs(1..=3), "hasMore": true, "lastSeq": 10});
    hub.capture_peer_page(on, ("m1", true), &json!({"limit": 3}), &page);
    hub.peer_snapshots.flush_now();
    let (head, seqs) = on_disk(&disk::path(&disk::root(&home), &key("m1")).unwrap(), "m1").unwrap();
    assert_eq!((head.last_seq, seqs), (3, vec![1, 2, 3]));
    // A page whose peer says how far it holds (`pageThrough`) covers that far; `lastSeq` alone,
    // which an older peer reads after its page, never does.
    let rest = json!({"events": recs(4..=5), "hasMore": false, "lastSeq": 9});
    hub.capture_peer_page(on, ("m1", true), &json!({"afterSeq": 3}), &rest);
    hub.peer_snapshots.flush_now();
    let path = disk::path(&disk::root(&home), &key("m1")).unwrap();
    assert_eq!(on_disk(&path, "m1").unwrap().0.last_seq, 5);
    let told = json!({"events": [], "hasMore": false, "lastSeq": 9, "pageThrough": 7});
    hub.capture_peer_page(
        on,
        ("m1", true),
        &json!({"afterSeq": 5, "kinds": ["transcript"]}),
        &told,
    );
    hub.peer_snapshots.flush_now();
    assert_eq!(on_disk(&path, "m1").unwrap().0.last_seq, 7);
}

#[test]
fn a_listing_under_way_when_a_peer_is_removed_never_lets_its_copies_back() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let path = disk::path(&disk::root(&home), &key("m1")).unwrap();
    let peer = add_idle_peer(&hub, PEER);
    // A listing that found the peer current holds the rows lock; the removal waits for it, so its
    // op comes before the removal's.
    let rows = hub.remote_sessions.lock().unwrap();
    let remover = {
        let hub = hub.clone();
        std::thread::spawn(move || hub.forget_peer_cache(PEER))
    };
    std::thread::sleep(Duration::from_millis(50));
    hub.peer_snapshots.listed(PEER, vec![("m1".into(), Some(42))], true);
    drop(rows);
    remover.join().unwrap();
    // A page asked before the removal, answered after it.
    let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
    hub.capture_peer_page(
        (PEER, peer.generation, peer.link_epoch(), Some(42)),
        ("m1", false),
        &json!({}),
        &page,
    );
    hub.peer_snapshots.flush_now();
    assert!(!path.exists(), "a removed peer's copy came back");
}

#[test]
fn a_capture_of_an_instance_replaced_while_it_was_sent_is_not_kept() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let path = disk::path(&disk::root(&home), &key("m1")).unwrap();
    let old = add_idle_peer(&hub, PEER);
    hub.peer_snapshots.listed(PEER, vec![("m1".into(), Some(42))], true);
    // The replacing instance registers under the rows lock, as `spawn_peer` does, and lists the
    // session; a capture of the old one checks and sends under that lock, so it goes first or not.
    let rows = hub.remote_sessions.lock().unwrap();
    let capture = {
        let hub = hub.clone();
        let on = (PEER, old.generation, old.link_epoch(), Some(42));
        std::thread::spawn(move || {
            let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
            hub.capture_peer_page(on, ("m1", false), &json!({}), &page);
        })
    };
    std::thread::sleep(Duration::from_millis(50));
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let new = crate::peer::Peer::new(PEER, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(PEER.to_owned(), new);
    hub.peer_snapshots.listed(PEER, vec![("m1".into(), Some(42))], true);
    drop(rows);
    capture.join().unwrap();
    hub.peer_snapshots.flush_now();
    assert!(!path.exists(), "the replaced instance's page was kept");
}

#[test]
fn the_hub_keeps_its_snapshots_beside_the_peer_caches_never_among_them() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let peers = hub.store.peer_cache_dir().unwrap();
    // A directory an older build left among the caches is not the store's, and stays as it was.
    std::fs::create_dir_all(peers.join(".snapshots")).unwrap();
    let peer = add_idle_peer(&hub, PEER);
    hub.peer_snapshots.listed(PEER, vec![("m1".into(), Some(42))], true);
    let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false, "lastSeq": 2});
    hub.capture_peer_page(
        (PEER, peer.generation, peer.link_epoch(), Some(42)),
        ("m1", false),
        &json!({}),
        &page,
    );
    hub.peer_snapshots.flush_now();
    assert!(disk::path(&disk::root(&snapshot_home(&hub)), &key("m1")).unwrap().exists());
    // What lists the peer caches sees only what it saved, and the directory it found.
    let listed: Vec<_> =
        std::fs::read_dir(&peers).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(listed, vec![std::ffi::OsString::from(".snapshots")]);
    assert!(std::fs::read_dir(peers.join(".snapshots")).unwrap().next().is_none());
}
