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
    let mut again = Store::new(disk::root(dir.path()), Arc::default());
    list(&mut again, &[("m2", 8)]);
    assert!(again.scan());
    assert!(again.copies.is_empty(), "{:?}", again.copies.keys().collect::<Vec<_>>());
    assert!(!file(dir.path(), "m2").exists() && !file(dir.path(), "m3").exists());
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
