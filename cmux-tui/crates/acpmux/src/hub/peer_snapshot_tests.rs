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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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
#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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
    let mut store = Store::new(disk::root(linked.path()), Arc::default(), Arc::default());
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
    // On the link that paged it, a page that raced a live record changes nothing.
    live(&mut store, "m1", 1, 12);
    let mut raced = attach(7, 1, true, recs(9..=11));
    raced.host_last_seq = Some(11);
    put(&mut store, "m1", raced);
    assert_eq!(seqs(&mut store, "m1"), (5..=12).collect::<Vec<_>>());
    // On another link, a peer behind the copy (an older disk) leaves it: the copy holds every
    // record past where the peer is, and goes back to it (`restore.rs`).
    put(&mut store, "m1", attach(7, 2, true, recs(8..=9)));
    assert_eq!(seqs(&mut store, "m1"), (5..=12).collect::<Vec<_>>());
    let (ahead, _) = store.ahead(PEER, vec![("m1".into(), 7, 9)]).unwrap();
    let back: Vec<u64> = ahead[0].3.iter().filter_map(seq_of).collect();
    assert_eq!((ahead.len(), ahead[0].2, back), (1, 9, vec![10, 11, 12]));
    // The peer refused them (another history): the copy goes, and its next page starts one.
    store.take(Op::Restored { key: key("m1"), link: (1, 2), generation: 7, last: None });
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

/// Review of #37284 at 8b5f3063, F1: a disk that does not read yet, and a copy ahead whose file
/// does not read, are "maybe ahead", never "none ahead"; the copy stays for a later read. Under
/// 8b5f3063's rules both answered no copy ahead, and the gate let prompts take the seqs of the
/// newer history still on disk.
#[cfg(unix)]
#[test]
fn a_disk_or_a_copy_that_does_not_read_is_never_none_ahead() {
    use std::os::unix::fs::PermissionsExt;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m1", 1..=5);
    store.write_due(None, When::Last);
    let rows = || vec![("m1".to_owned(), 7, 2)];
    let root = disk::root(dir.path());
    // A restart whose disk does not read: what the earlier run kept is not in the store yet.
    let unscanned = read_only(&root, || {
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
        let mut again = Store::new(root.clone(), Arc::default(), Arc::default());
        let now = again.ahead(PEER, rows()).map(|(a, _)| a.len());
        crate::hub::journal_restore::OLD_RULES
            .with(|r| r.set(crate::hub::journal_restore::AT_8B5F));
        let before = again.ahead(PEER, rows()).map(|(a, _)| a.len());
        crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
        (now, before)
    });
    if let Some((now, before)) = unscanned {
        assert_eq!(now, None, "a disk not read is maybe ahead");
        assert_eq!(before, Some(0), "8b5f3063 answered none ahead");
    }
    // A restart whose copy's file does not read (an I/O error): the disk does not read yet, and
    // the file stays; once it reads, the copy goes back.
    let path = file(dir.path(), "m1");
    let mode =
        |m: u32| std::fs::set_permissions(&path, std::fs::Permissions::from_mode(m)).unwrap();
    // SAFETY: getuid has no preconditions.
    let root_user = unsafe { libc::getuid() } == 0;
    let mut again = Store::new(root.clone(), Arc::default(), Arc::default());
    mode(0o000);
    if !root_user {
        assert!(again.ahead(PEER, rows()).is_none(), "a head not read is a disk not read");
        assert!(!again.scanned && path.exists(), "and its file stays");
    }
    mode(0o600);
    let (ahead, _) = again.ahead(PEER, rows()).expect("read once its file reads");
    let back: Vec<u64> = ahead[0].3.iter().filter_map(seq_of).collect();
    assert_eq!(back, vec![3, 4, 5]);
    // Read in, its head only, then its records do not read: maybe ahead, and the copy stays.
    let mut again = store_at(dir.path());
    assert!(again.copies[&key("m1")].records.is_none());
    mode(0o000);
    if !root_user {
        assert!(again.ahead(PEER, rows()).is_none(), "a copy not read is maybe ahead");
        assert!(again.copies.contains_key(&key("m1")) && path.exists(), "and it stays");
    }
    mode(0o600);
    assert_eq!(again.ahead(PEER, rows()).map(|(a, _)| a[0].3.len()), Some(3));
    // A copy that is cut is not its records however often it is read: it goes, and that is known.
    let mut cut = Store::new(root.clone(), Arc::default(), Arc::default());
    let text = std::fs::read(&path).unwrap();
    std::fs::write(&path, &text[..text.len() - 2]).unwrap();
    assert_eq!(cut.ahead(PEER, rows()).map(|(a, _)| a.len()), Some(0));
    assert!(!cut.copies.contains_key(&key("m1")));
    // Under 8b5f3063's rules a copy whose file did not read went, answered as none ahead.
    let mut old = store_at(dir.path());
    keep(&mut old, "m1", 1..=5);
    old.write_due(None, When::Last);
    let mut again = store_at(dir.path());
    mode(0o000);
    if !root_user {
        crate::hub::journal_restore::OLD_RULES
            .with(|r| r.set(crate::hub::journal_restore::AT_8B5F));
        assert_eq!(again.ahead(PEER, rows()).map(|(a, _)| a.len()), Some(0));
        crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
        assert!(!again.copies.contains_key(&key("m1")));
    }
}

/// Review of #37284 at c4a1c13b, F1: a page that comes while a copy's file does not read leaves
/// the copy as it is, unread, rather than removing it and starting again from the page; once the
/// file reads, its records past where the peer's journal ends go back. Under c4a1c13b's rules
/// the page's read removed it, and the newer records were lost.
#[cfg(unix)]
#[test]
fn a_page_while_a_copy_does_not_read_leaves_the_copy() {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: getuid has no preconditions.
    if unsafe { libc::getuid() } == 0 {
        return; // root reads anyway
    }
    for rules in [crate::hub::journal_restore::AT_C4A1, 0] {
        let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
        let mut store = store_at(dir.path());
        keep(&mut store, "m1", 1..=5);
        store.write_due(None, When::Last);
        // A restart: the copy is read in by its head only.
        let mut again = store_at(dir.path());
        list(&mut again, &[("m1", 7)]);
        let path = file(dir.path(), "m1");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
        crate::hub::journal_restore::OLD_RULES.with(|r| r.set(rules));
        // The peer on an older disk, on a new link: its journal ends at 2.
        put(&mut again, "m1", attach(7, 2, true, recs(1..=2)));
        crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
        // Under c4a1c13b's rules the page removed the copy and its file.
        assert_eq!(path.exists(), rules == 0, "the copy's file stays only under the rules of now");
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        let back = again
            .ahead(PEER, vec![("m1".to_owned(), 7, 2)])
            .map(|(a, _)| a.first().map_or(vec![], |a| a.3.iter().filter_map(seq_of).collect()));
        if rules == 0 {
            assert_eq!(back, Some(vec![3, 4, 5]), "the copy stayed and goes back whole");
        } else {
            assert_eq!(back, Some(vec![]), "c4a1c13b started again from the older page");
        }
    }
}

#[test]
fn an_empty_page_from_a_peer_gone_back_keeps_the_copy_until_the_peer_takes_it_back() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    // A VM resumed from before its first record: an empty attach on a new link, `lastSeq` 0.
    // The copy stays: it holds every record the peer lost, which go back to it.
    let mut empty = attach(7, 2, false, vec![]);
    empty.host_last_seq = Some(0);
    put(&mut store, "m1", empty);
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3]);
    assert_eq!(store.ahead(PEER, vec![("m1".into(), 7, 0)]).unwrap().0[0].3.len(), 3);
    // Taken back, the peer's journal ends where the copy does, and its pages join it.
    store.take(Op::Restored { key: key("m1"), link: (1, 2), generation: 7, last: Some(3) });
    put(&mut store, "m1", attach(7, 2, true, recs(4..=5)));
    assert_eq!(seqs(&mut store, "m1"), (1..=5).collect::<Vec<_>>());
    // A peer that refuses them is another history: the copy goes, and its pages start one.
    let mut empty = attach(7, 3, false, vec![]);
    empty.host_last_seq = Some(0);
    put(&mut store, "m1", empty);
    // A refusal on the link before, or of another generation, proves nothing of this one: the
    // copy stays (review of #37284 at af36583c, F1).
    store.take(Op::Restored { key: key("m1"), link: (1, 2), generation: 7, last: None });
    store.take(Op::Restored { key: key("m1"), link: (1, 3), generation: 6, last: None });
    assert_eq!(seqs(&mut store, "m1"), (1..=5).collect::<Vec<_>>());
    store.take(Op::Restored { key: key("m1"), link: (1, 3), generation: 7, last: None });
    assert!(seqs(&mut store, "m1").is_empty());
    put(&mut store, "m1", attach(7, 3, true, recs(4..=5)));
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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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
    let mut store = Store::new(disk::root(dir.path()), snaps.dropped.clone(), Arc::default());
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
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
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

#[tokio::test]
async fn a_capture_after_peer_remove_cannot_recreate_a_snapshot() {
    use crate::peer::PeerNotice;

    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, PEER);
    hub.apply_peer_notice(
        PEER,
        peer.generation,
        PeerNotice::Sessions(vec![json!({
            "sessionId": "m1", "name": "lane", "status": "running", "createdAt": 42,
            "updatedAt": 5
        })]),
    );
    let hook = crate::hub::peers::PeerNoticeProjectionHook::new();
    *hub.peer_notice_projection_hook.lock().unwrap() = Some(hook.clone());
    let capturing = {
        let hub = hub.clone();
        let generation = peer.generation;
        std::thread::spawn(move || {
            hub.capture_peer_page(
                (PEER, generation, 0, Some(42)),
                ("m1", true),
                &json!({"limit": 400, "kinds": ["transcript"]}),
                &json!({"events": recs(1..=1), "hasMore": false, "lastSeq": 1}),
            );
        })
    };
    hook.wait_reached();
    hub.remove_peer(PEER).await.unwrap();
    hook.release();
    capturing.join().unwrap();
    hub.peer_snapshots.flush_now();
    assert!(!disk::path(&disk::root(&snapshot_home(&hub)), &key("m1")).unwrap().exists());
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

/// A record of prompt `prompt`'s life, of `kind`.
fn life(mux: &str, seq: u64, kind: &str, prompt: &str) -> Value {
    json!({"sessionId": mux, "seq": seq, "at": seq, "dir": "mux", "kind": kind,
           "msg": {"promptId": prompt, "turnId": format!("t-{prompt}")}})
}

/// Review of #37284 at 0c98c292, F1 and F2: a write reports only the records it put on disk (not
/// one the copy's bound cut before it); the delivery holds them as its proof past the copy's
/// bound, the captures' queue overflowing and the disk's eviction, and a restore gives them back;
/// a proof whose life the copy did not see whole gives back nothing that would run again; only
/// a later link that shows them held releases it.
#[test]
fn a_proof_outlives_the_copy_and_goes_back_whole_or_not_at_all() {
    use crate::hub::open_delivery as od;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let told: Arc<StdMutex<Vec<Vec<Value>>>> = Arc::default();
    let hook: Written = {
        let told = told.clone();
        Arc::new(move |_, _, _, records| {
            told.lock().unwrap().push(records);
            true
        })
    };
    let mut store =
        Store::new(disk::root(dir.path()), Arc::default(), Arc::new(StdMutex::new(Some(hook))));
    store.scan();
    let outbox = crate::hub::outbox::Outbox::default();
    let now = crate::store::now_ms();
    let delivery = |id: &str, prompt: &str| -> crate::hub::outbox::Delivery {
        serde_json::from_value(json!({
            "id": id, "target": format!("{PEER}/m1"),
            "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": prompt}}},
            "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
            "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
        }))
        .unwrap()
    };
    outbox.add(delivery("d1", "p1"));
    outbox.add(delivery("d2", "p2"));
    keep(&mut store, "m1", 1..=3);
    store.add(&key("m1"), vec![life("m1", 4, "queued", "p1")]);
    store.write_due(None, When::Last);
    // p2 runs, and a turn writes past the copy's bound before the next write.
    store.add(&key("m1"), vec![life("m1", 5, "user_message", "p2")]);
    keep(&mut store, "m1", 6..=(6 + SESSION_EVENTS as u64));
    store.write_due(None, When::Last);
    let told = std::mem::take(&mut *told.lock().unwrap());
    let seqs_told: Vec<u64> = told.iter().flatten().filter_map(seq_of).collect();
    assert_eq!(seqs_told, vec![4], "only what a write put on disk is told");
    for records in &told {
        od::take_written(&outbox, (PEER, "m1", 7), records, (1, 1));
    }
    let proof = |id: &str| outbox.get(id).and_then(|d| d.proof);
    assert!(proof("d2").is_none(), "a record cut before its write proves nothing");
    assert_eq!(proof("d1").map(|p| p.records.len()), Some(1));
    assert!(!seqs(&mut store, "m1").contains(&4), "the copy's bound cut it");

    // The machine comes back on a disk that ends at 3. The bound cut p2's record before a write
    // reported it (review at 91b1343d, F1): the copy saw every record only from past it, so
    // whether p1 left its queue meanwhile is not known, and nothing of p1 goes back.
    let rows = vec![("m1".to_owned(), 7, 3)];
    let (ahead, since) = store.ahead(PEER, rows.clone()).unwrap();
    assert_eq!(since["m1"], (7, 6));
    let proofs = od::proofs_past(&outbox, PEER, &rows, &since);
    assert!(proofs.is_empty());
    let (back, _) = restore::with_proofs(ahead, proofs, &rows);
    assert!(back[0].3.first().and_then(seq_of) > Some(5), "p1's proof went back");

    // The captures' queue overflowed: the copy went, so whether p1 left its queue since is not
    // known: nothing of it goes back (it would run again), and it stays open.
    store.take(Op::LostPeer(PEER.into()));
    let (_, since) = store.ahead(PEER, rows.clone()).unwrap();
    assert!(od::proofs_past(&outbox, PEER, &rows, &since).is_empty());
    // Its removal from the queue came in its proof before: then all of it goes back.
    od::take_written(&outbox, (PEER, "m1", 7), &[life("m1", 9, "queue_removed", "p1")], (1, 1));
    let back = od::proofs_past(&outbox, PEER, &rows, &since);
    let back: Vec<u64> = back["m1"].iter().flatten().filter_map(seq_of).collect();
    assert_eq!(back, vec![4, 9]);

    // Released only by a later link whose journal holds it, of its generation.
    let d1 = outbox.get("d1").unwrap();
    let ends = |g: u64, last: u64| HashMap::from([("m1".to_owned(), (g, last))]);
    assert_eq!(od::step(&d1, now, (1, 2), &ends(7, 3)), od::Step::Wait);
    assert_eq!(od::step(&d1, now, (1, 1), &ends(7, 9)), od::Step::Wait);
    assert_eq!(od::step(&d1, now, (1, 2), &ends(7, 9)), od::Step::Check);
    assert_eq!(od::checked(Some(true)), od::Step::Release);
    assert_eq!(od::checked(Some(false)), od::Step::Lost);
    assert_eq!(od::step(&d1, now, (1, 2), &ends(8, 9)), od::Step::Stale);
    let lapsed = now + crate::hub::outbox::OPEN_ON_PEER_FOR_MS;
    assert_eq!(od::step(&d1, lapsed, (1, 2), &ends(7, 9)), od::Step::Lapse);
    assert_eq!(od::step(&outbox.get("d2").unwrap(), now, (1, 2), &ends(7, 9)), od::Step::Again);
}

/// The step a later link takes for a delivery of an attachment prompt whose proof holds only
/// its `user_message` (its hidden context, no turn started yet), under `rules`; then once its
/// turn started.
fn steps_of_an_accepted_attachment_prompt(
    rules: u8,
) -> (crate::hub::open_delivery::Step, crate::hub::open_delivery::Step) {
    use crate::hub::open_delivery as od;
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(rules));
    let outbox = crate::hub::outbox::Outbox::default();
    let now = crate::store::now_ms();
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": "p1"}}},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    outbox.add(d);
    let mut accepted = life("m1", 4, "user_message", "p1");
    accepted["msg"]["text"] = json!("see the notes");
    accepted["msg"]["hiddenContext"] = json!("the notes' text, read from the attachment");
    od::take_written(&outbox, (PEER, "m1", 7), &[accepted], (1, 1));
    let ends = HashMap::from([("m1".to_owned(), (7, 9))]);
    let accepted_only = od::step(&outbox.get("d1").unwrap(), now, (1, 2), &ends);
    od::take_written(&outbox, (PEER, "m1", 7), &[life("m1", 5, "turn_started", "p1")], (1, 1));
    let started = od::step(&outbox.get("d1").unwrap(), now, (1, 2), &ends);
    // A started turn's continuation never carries the hidden context: proven at its end.
    if rules == 0 {
        assert_eq!(started, od::Step::Again, "a started turn without its hidden context");
        od::take_written(&outbox, (PEER, "m1", 7), &[life("m1", 6, "turn_result", "p1")], (1, 1));
    }
    let ended = od::step(&outbox.get("d1").unwrap(), now, (1, 2), &ends);
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    (accepted_only, ended)
}

/// Review of #37284 at 07f76930, F2: a machine that holds only an attachment prompt's
/// `user_message` (its hidden context is never logged, so it cannot rebuild it) and died before
/// its turn started does not prove the prompt: the delivery is sent again (a resend runs an
/// unstarted prompt) and keeps its attachments, until a proof a machine runs it again from (its
/// turn started, its `queued` record, its end). Under 07f76930's rules a later link checked it,
/// and its release dropped the prompt and its files.
#[test]
fn an_accepted_attachment_prompt_whose_turn_never_started_is_delivered_again() {
    use crate::hub::open_delivery as od;
    let old = steps_of_an_accepted_attachment_prompt(crate::hub::journal_restore::AT_07F7);
    assert_eq!(old.0, od::Step::Check, "07f76930 went on to release it");
    let now = steps_of_an_accepted_attachment_prompt(0);
    assert_eq!(now, (od::Step::Again, od::Step::Check));
    // A text prompt's `user_message` rebuilds it, and an image's with the image's bytes; a
    // digest's, an attachment's, a document's, or an image's without its bytes not.
    let none = std::collections::HashSet::new();
    let i1 = std::collections::HashSet::from(["i1".to_owned()]);
    let text = json!([{"kind": "user_message", "msg": {"promptId": "p", "text": "hi"}}]);
    assert!(od::rerunnable(text.as_array().unwrap(), &none));
    let image = json!({"promptId": "p", "text": "hi", "images": [{"id": "i1"}],
                       "inlineParts": [{"kind": "image", "id": "i1"}]});
    assert!(od::rerunnable(&[json!({"kind": "user_message", "msg": image})], &i1));
    for msg in [
        json!({"promptId": "p", "text": "hi", "hiddenContext": "x"}),
        image,
        json!({"promptId": "p", "inlineParts": [{"kind": "document", "name": "a.pdf"}]}),
        json!({"promptId": "p", "text": "hi", "_meta": {"provenance": {"kind": "agent_digest"}}}),
    ] {
        let records = [json!({"kind": "user_message", "msg": msg})];
        assert!(!od::rerunnable(&records, &none), "{msg}");
    }
}

/// A delivery of an image prompt whose turn started at once (no `queued` record: its
/// `user_message` names the image by id), proven by those records, under `rules`: its step on a
/// later link, and the images a restore of its session brings back.
fn an_image_prompt_started_at_once(rules: u8) -> (crate::hub::open_delivery::Step, Vec<Value>) {
    use crate::hub::open_delivery as od;
    use base64::Engine as _;
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(rules));
    let outbox = crate::hub::outbox::Outbox::default();
    let now = crate::store::now_ms();
    let bytes = b"\x89PNG\r\n\x1a\n the screenshot".to_vec();
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let id = crate::attach::sha256(&bytes);
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": "p1"}},
                    "prompt": [{"type": "text", "text": "what is this"},
                               {"type": "image", "mimeType": "image/png", "data": data}]},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    outbox.add(d);
    let mut accepted = life("m1", 4, "user_message", "p1");
    accepted["msg"]["text"] = json!("what is this");
    accepted["msg"]["images"] = json!([{"id": id, "mimeType": "image/png"}]);
    let started = life("m1", 5, "turn_started", "p1");
    od::take_written(&outbox, (PEER, "m1", 7), &[accepted, started], (1, 1));
    let ends = HashMap::from([("m1".to_owned(), (7, 9))]);
    let step = od::step(&outbox.get("d1").unwrap(), now, (1, 2), &ends);
    let back = restore::restore_files(&outbox, (PEER, "m1", 7));
    let images = back.into_iter().filter(|f| f.get("image") == Some(&json!(id))).collect();
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    (step, images)
}

/// Review of #37284 at a088585e, F2: an image prompt whose turn started at once, before its
/// machine went back to an older disk, is given back with its image's bytes, which the machine
/// writes where it keeps a prompt's images (`journal_restore.rs`), and its delivery goes only
/// once a later link shows them held (`proof_held`), so the cut turn's continuation carries
/// the image. Under a088585e's rules the restore brought no image and the continuation went
/// without it.
#[test]
fn an_image_prompt_started_at_once_goes_back_with_its_image() {
    use crate::hub::open_delivery as od;
    let (step, images) = an_image_prompt_started_at_once(crate::hub::journal_restore::AT_A088);
    assert_eq!(step, od::Step::Check);
    assert!(images.is_empty(), "a088585e brought its image back");
    let (step, images) = an_image_prompt_started_at_once(0);
    assert_eq!(step, od::Step::Check);
    assert_eq!(images.len(), 1, "its image goes back with it");
}

/// What goes back to a machine on a disk that ends at 3 from a proof of p1's `queued` (seq 4),
/// once its removal (seq 5) came and the copy's bound cut it before a write reported it; under
/// the rules of 91b1343d when `rules_of_91b`.
fn back_after_a_cut_removal(rules_of_91b: bool) -> Vec<u64> {
    use crate::hub::open_delivery as od;
    crate::hub::journal_restore::OLD_RULES
        .with(|r| r.set(if rules_of_91b { crate::hub::journal_restore::AT_91B } else { 0 }));
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let told: Arc<StdMutex<Vec<Vec<Value>>>> = Arc::default();
    let hook: Written = {
        let told = told.clone();
        Arc::new(move |_, _, _, records| {
            told.lock().unwrap().push(records);
            true
        })
    };
    let mut store =
        Store::new(disk::root(dir.path()), Arc::default(), Arc::new(StdMutex::new(Some(hook))));
    store.scan();
    let outbox = crate::hub::outbox::Outbox::default();
    let now = crate::store::now_ms();
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": "p1"}}},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    outbox.add(d);
    keep(&mut store, "m1", 1..=3);
    store.add(&key("m1"), vec![life("m1", 4, "queued", "p1")]);
    store.write_due(None, When::Last);
    // p1 is taken off the queue, and a turn writes past the copy's bound before the next write.
    store.add(&key("m1"), vec![life("m1", 5, "queue_removed", "p1")]);
    keep(&mut store, "m1", 6..=(6 + SESSION_EVENTS as u64));
    store.write_due(None, When::Last);
    for records in std::mem::take(&mut *told.lock().unwrap()) {
        od::take_written(&outbox, (PEER, "m1", 7), &records, (1, 1));
    }
    let rows = vec![("m1".to_owned(), 7, 3)];
    let (_, since) = store.ahead(PEER, rows.clone()).unwrap();
    let back = od::proofs_past(&outbox, PEER, &rows, &since);
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    back.get("m1").map_or(vec![], |r| r.iter().flatten().filter_map(seq_of).collect())
}

/// Review of #37284 at 91b1343d, F1: a record of a prompt's life the bound cuts before a write
/// reported it moves where the copy saw every record from past it, so the proof that needed it
/// is not whole and nothing of it goes back. Under 91b1343d's rules the `queued` record went
/// back without its removal, and the canceled prompt ran.
#[test]
fn a_removal_the_bound_cut_before_its_write_keeps_its_prompt_from_going_back() {
    assert_eq!(back_after_a_cut_removal(true), vec![4], "91b1343d gave back the canceled prompt");
    assert!(back_after_a_cut_removal(false).is_empty());
}

/// Review of #37284 at 91b1343d, F5: a copy and its proofs past what one restore takes are not
/// restored, and their session comes back held (its prompts held, its deliveries open), never
/// dropped as clear. Under 91b1343d's rules it went with nothing held.
#[test]
fn a_restore_past_what_one_takes_stays_held() {
    let max = crate::hub::journal_restore::MAX_RECORDS as u64;
    let rows = vec![("m1".to_owned(), 7, 0), ("m2".to_owned(), 7, 0)];
    let ahead =
        || vec![("m1".to_owned(), 7, 0, recs(1..=max - 10)), ("m2".to_owned(), 7, 0, recs(1..=3))];
    let proofs = || HashMap::from([("m1".to_owned(), vec![recs(max - 9..=max + 20)])]);
    let (back, held) = restore::with_proofs(ahead(), proofs(), &rows);
    assert_eq!(back.iter().map(|a| a.0.as_str()).collect::<Vec<_>>(), vec!["m2"]);
    assert_eq!(held, HashSet::from(["m1".to_owned()]));
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(crate::hub::journal_restore::AT_91B));
    let (back, held) = restore::with_proofs(ahead(), proofs(), &rows);
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    assert_eq!(back.len(), 1);
    assert!(held.is_empty(), "91b1343d dropped it and held nothing");
}

/// The move simulation, round 9 (seed 1092): a proof of another history than the copy (its
/// machine came back on a disk where the prompt's record is the same, and wrote other records
/// where its end was) goes back whole or not at all: never its `queued` record without its end.
#[test]
fn a_proof_of_another_history_than_the_copy_goes_back_not_at_all() {
    let rows = vec![("m1".to_owned(), 7, 34)];
    let copy = vec![("m1".to_owned(), 7, 34, recs(42..=56))];
    let proof = vec![
        life("m1", 35, "queued", "p0"),
        life("m1", 53, "user_message", "p0"),
        life("m1", 55, "turn_result", "p0"),
    ];
    let (back, _) =
        restore::with_proofs(copy.clone(), HashMap::from([("m1".to_owned(), vec![proof])]), &rows);
    let seqs: Vec<u64> = back[0].3.iter().filter_map(seq_of).collect();
    assert_eq!(seqs, (42..=56).collect::<Vec<_>>(), "a part of the proof went back");
    // One that fits goes back with the copy.
    let proof = vec![life("m1", 35, "queued", "p0"), life("m1", 40, "queue_removed", "p0")];
    let (back, _) =
        restore::with_proofs(copy, HashMap::from([("m1".to_owned(), vec![proof])]), &rows);
    assert_eq!(back[0].3.iter().filter_map(seq_of).take(2).collect::<Vec<_>>(), vec![35, 40]);
}

/// A delivery of prompt `prompt` to `m1` (generation 7), open on its peer, pinned at link (1, 1).
fn open_delivery(id: &str, prompt: &str, blocks: Value) -> crate::hub::outbox::Delivery {
    let now = crate::store::now_ms();
    serde_json::from_value(json!({
        "id": id, "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "prompt": blocks,
                    "_meta": {"acpmux": {"promptId": prompt}}},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap()
}

fn set_rules(rules: u8) {
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(rules));
}

/// The files a proven delivery with a non-image attachment gives back, under `rules`.
fn files_of_a_proven_attachment(rules: u8) -> Vec<(std::path::PathBuf, Vec<u8>)> {
    use crate::hub::open_delivery as od;
    use base64::Engine as _;
    set_rules(rules);
    let outbox = crate::hub::outbox::Outbox::default();
    let data = base64::engine::general_purpose::STANDARD.encode(b"the notes");
    let attachment = json!([{"type": "resource", "resource": {"uri": "attachment:notes.txt", "blob": data},
                             "_meta": {"acpmux": {"attachment": {"name": "notes.txt"}}}}]);
    outbox.add(open_delivery("d1", "p1", attachment));
    let queued = json!({"sessionId": "m1", "seq": 4, "at": 4, "dir": "mux", "kind": "queued",
        "msg": {"promptId": "p1", "turnId": "t-p1", "prompt": [
            {"type": "resource_link", "uri": "file:///up/m1/019a/notes.txt", "name": "notes.txt"}]}});
    od::take_written(&outbox, (PEER, "m1", 7), &[queued], (1, 1));
    let files = od::proof_files(&outbox.get("d1").unwrap());
    set_rules(0);
    files
}

/// Review of #37284 at 4dcbe192, F4: a proven delivery keeps its non-image attachment's bytes,
/// and names the path its machine saved it at: a restore writes it back there. Under 4dcbe192's
/// rules the bytes went at the proof, and the restored prompt named a file its disk lacked.
#[test]
fn a_proven_delivery_keeps_the_files_its_prompt_was_saved_as() {
    assert!(files_of_a_proven_attachment(crate::hub::journal_restore::AT_4DCB).is_empty());
    let files = files_of_a_proven_attachment(0);
    assert_eq!(files, vec![("/up/m1/019a/notes.txt".into(), b"the notes".to_vec())]);
}

/// A proof of p1's `queued` (seq 4) and a Stop's `queue_paused` holding it (seq 5), the hold cut
/// by the copy's bound before a write reported it: the proof's records, and where the copy saw
/// every record from.
fn stop_then_bound(rules: u8) -> (Vec<u64>, u64) {
    use crate::hub::open_delivery as od;
    set_rules(rules);
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let told: Arc<StdMutex<Vec<Vec<Value>>>> = Arc::default();
    let hook: Written = {
        let told = told.clone();
        Arc::new(move |_, _, _, records| {
            told.lock().unwrap().push(records);
            true
        })
    };
    let mut store =
        Store::new(disk::root(dir.path()), Arc::default(), Arc::new(StdMutex::new(Some(hook))));
    store.scan();
    let outbox = crate::hub::outbox::Outbox::default();
    outbox.add(open_delivery("d1", "p1", json!([])));
    keep(&mut store, "m1", 1..=3);
    let paused = json!({"sessionId": "m1", "seq": 5, "at": 5, "dir": "mux", "kind": "queue_paused",
                        "msg": {"held": ["p1"], "reason": "stop"}});
    store.add(&key("m1"), vec![life("m1", 4, "queued", "p1")]);
    store.write_due(None, When::Last);
    store.add(&key("m1"), vec![paused.clone()]);
    store.write_due(None, When::Last);
    for records in std::mem::take(&mut *told.lock().unwrap()) {
        od::take_written(&outbox, (PEER, "m1", 7), &records, (1, 1));
    }
    let proof: Vec<u64> =
        outbox.get("d1").unwrap().proof.unwrap().records.iter().filter_map(seq_of).collect();
    // Another Stop's hold, cut by the bound before its write.
    let mut again = paused;
    again["seq"] = json!(6);
    store.add(&key("m1"), vec![again]);
    keep(&mut store, "m1", 7..=(7 + SESSION_EVENTS as u64));
    let since = store.copies[&key("m1")].head.since;
    set_rules(0);
    (proof, since)
}

/// Review of #37284 at 4dcbe192, F5: a proof takes the queue's records that hold or free its
/// prompt (a Stop's `queue_paused` names it in `held`), and the copy's bound cutting one before a
/// write moves where the copy saw every record from past it. Under 4dcbe192's rules the proof
/// went back without the hold, and the stopped prompt ran.
#[test]
fn a_proof_keeps_the_stop_that_held_its_prompt() {
    let (proof, since) = stop_then_bound(crate::hub::journal_restore::AT_4DCB);
    assert_eq!(proof, vec![4], "4dcbe192 took the hold");
    assert!(since < 7, "4dcbe192 moved since");
    let (proof, since) = stop_then_bound(0);
    assert_eq!(proof, vec![4, 5]);
    assert_eq!(since, 7);
}

/// Review of #37284 at 4dcbe192, F6: a proof the owner kept across its own restart is checked on
/// the next link, whatever its numbers (they start again at each start). Under 4dcbe192's rules
/// it waited for a link numbered past its own, which might never come, and lapsed as lost.
#[test]
fn a_proof_from_an_earlier_start_is_checked_on_the_next_link() {
    use crate::hub::open_delivery as od;
    let mut d = open_delivery("d1", "p1", json!([]));
    d.pin.as_mut().unwrap().link = (7, 9);
    od::take_proof(&mut d, &[life("m1", 4, "queued", "p1")], (7, 9));
    od::INCARNATION.with(|i| *i.borrow_mut() = Some("a later start".into()));
    let ends = HashMap::from([("m1".to_owned(), (7, 9))]);
    let now = crate::store::now_ms();
    set_rules(crate::hub::journal_restore::AT_4DCB);
    let before = od::step(&d, now, (1, 1), &ends);
    set_rules(0);
    let after = od::step(&d, now, (1, 1), &ends);
    od::INCARNATION.with(|i| *i.borrow_mut() = None);
    assert_eq!(before, od::Step::Wait, "4dcbe192 checked it");
    assert_eq!(after, od::Step::Check);
}

/// A delivery's proof of p1's `queued` (seq 4) on disk; then the outbox's save of its removal
/// (seq 5) fails; then a turn writes past the copy's bound, which cuts the removal; then the
/// owner starts again on that disk, and the machine is back on a disk that ends at 3: whether a
/// restore would give p1's `queued` back (it would run again, though it was removed).
fn a_proof_whose_save_failed(rules: u8) -> bool {
    use crate::hub::open_delivery as od;
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(rules));
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let outbox = Arc::new(crate::hub::outbox::Outbox::default());
    let saves = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let hook: Written = {
        let (outbox, saves) = (outbox.clone(), saves.clone());
        Arc::new(move |_, _, link, records| {
            od::take_written(&outbox, (PEER, "m1", 7), &records, link);
            saves.load(std::sync::atomic::Ordering::SeqCst)
                || crate::hub::journal_restore::rules_of_a088()
        })
    };
    let now = crate::store::now_ms();
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": "p1"}}},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    // The proof as the outbox's file holds it: only what a save that worked wrote.
    let on_disk = crate::hub::outbox::Outbox::default();
    on_disk.add(d.clone());
    outbox.add(d);
    {
        let hook = Arc::new(StdMutex::new(Some(hook)));
        let mut store = Store::new(disk::root(dir.path()), Arc::default(), hook);
        store.scan();
        keep(&mut store, "m1", 1..=3);
        store.add(&key("m1"), vec![life("m1", 4, "queued", "p1")]);
        store.write_due(None, When::Last);
        od::take_written(&on_disk, (PEER, "m1", 7), &[life("m1", 4, "queued", "p1")], (1, 1));
        saves.store(false, std::sync::atomic::Ordering::SeqCst);
        store.add(&key("m1"), vec![life("m1", 5, "queue_removed", "p1")]);
        store.write_due(None, When::Last);
        saves.store(true, std::sync::atomic::Ordering::SeqCst);
        keep(&mut store, "m1", 6..=(6 + SESSION_EVENTS as u64));
        store.write_due(None, When::Last);
    }
    // The owner starts again: its copies from disk, its outbox from its file.
    let mut store = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
    store.scan();
    let rows = vec![("m1".to_owned(), 7, 3)];
    let (_, since) = store.ahead(PEER, rows.clone()).unwrap();
    let back = od::proofs_past(&on_disk, PEER, &rows, &since);
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    !back.is_empty()
}

/// Review of #37284 at a088585e, F3: a copy counts its records as told to their proofs only once
/// the outbox is on disk. When its save fails, the copy writes that it vouches for its records
/// only past them (`since`), in the same write, so a proof that missed a later record of its
/// prompt is never whole, after the owner starts again too, and nothing of it goes back. Under
/// a088585e's rules the copy took them as told, its bound cut the removal unnoticed, and the
/// removed prompt went back to run again.
#[test]
fn a_proof_whose_save_failed_never_gives_back_a_removed_prompt() {
    assert!(a_proof_whose_save_failed(crate::hub::journal_restore::AT_A088), "a088585e kept it");
    assert!(!a_proof_whose_save_failed(0), "the removed prompt went back");
}

/// A record the link is not sent live (`method::MUX_UNSENT`: the turn's own `session/prompt`)
/// lets the copy go on past its seq, so the running turn's records join while it runs; past a
/// record the link lost (a seq it never heard of), nothing joins until a page.
#[test]
fn an_unsent_seq_continues_a_copy_only_next_to_it() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let home = snapshot_home(&hub);
    let peer = add_idle_peer(&hub, PEER);
    let row = json!({"sessionId": "m1", "name": "lane", "status": "running", "createdAt": 42,
                     "updatedAt": 5});
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::Sessions(vec![row]));
    let link = peer.link_epoch();
    let page = json!({"session": {"createdAt": 42}, "events": recs(1..=2), "hasMore": false,
                      "lastSeq": 2});
    hub.capture_peer_page(
        (PEER, peer.generation, link, Some(42)),
        ("m1", false),
        &json!({}),
        &page,
    );
    let record = |seq: u64| {
        let params = json!({"sessionId": "m1", "seq": seq, "at": seq, "dir": "mux", "kind": "prompt", "msg": {}});
        PeerNotice::Notification { method: method::MUX_EVENT.into(), params, link }
    };
    let unsent = |seq: u64| PeerNotice::Notification {
        method: method::MUX_UNSENT.into(),
        params: json!({"sessionId": "m1", "seq": seq}),
        link,
    };
    for notice in [record(3), unsent(4), record(5), unsent(7), record(8)] {
        hub.apply_peer_notice(PEER, peer.generation, notice);
    }
    hub.peer_snapshots.flush_now();
    let path = disk::path(&disk::root(&home), &key("m1")).unwrap();
    let (head, seqs) = on_disk(&path, "m1").expect("m1's copy was written");
    assert_eq!(seqs, vec![1, 2, 3, 5], "6 never came: 7 and 8 do not join");
    assert_eq!(head.last_seq, 5);
}

/// A delivery of a prompt of `blocks` to `m1`, proven by its `queued` record, which links to a
/// saved file for each inline attachment and names each image by id, as a machine's would.
fn proven_with(blocks: Vec<Value>) -> crate::hub::outbox::Delivery {
    use crate::hub::open_delivery as od;
    let outbox = crate::hub::outbox::Outbox::default();
    let now = crate::store::now_ms();
    let links: Vec<Value> = crate::attach::saved_names(&blocks)
        .into_iter()
        .map(|(_, name)| {
            let path = format!("/state/uploads/m1/019a-saved/{name}");
            json!({"type": "resource_link", "uri": format!("file://{path}"), "name": name})
        })
        .collect();
    let images: Vec<Value> = crate::hub::prompt_images::image_bytes(&blocks)
        .into_iter()
        .map(|(id, _)| json!({"id": id, "mimeType": "image/png"}))
        .collect();
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": "p1"}},
                    "prompt": blocks},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    outbox.add(d);
    let mut queued = life("m1", 4, "queued", "p1");
    queued["msg"]["prompt"] = json!(links);
    queued["msg"]["images"] = json!(images);
    od::take_written(&outbox, (PEER, "m1", 7), &[queued], (1, 1));
    outbox.get("d1").unwrap()
}

/// Review of #37284 at 77f91e5a, F1: every kind of block a prompt can carry (each one
/// `attach::blocks_for` makes, and what a sender and the daemon add) is named by
/// `open_delivery::part`, and a proven delivery of a prompt of it alone needs it of a machine
/// unless its records carry it. A new kind of block fails here until a rule names it.
#[test]
fn every_block_a_prompt_can_carry_is_named_by_what_a_move_needs() {
    use crate::hub::open_delivery as od;
    use base64::Engine as _;
    let png = base64::engine::general_purpose::STANDARD.encode(b"\x89PNG\r\n\x1a\n a picture");
    let resolved = "/state/uploads/m1/019a0000-0000-7000-8000-000000000002/big.log";
    let mut blocks = crate::attach::every_block_kind();
    blocks.extend([
        json!({"type": "text", "text": "see these"}),
        json!({"type": "text", "text": "<cmux-attachments-context>\n- big.log\n</cmux-attachments-context>",
               "_meta": {"acpmux": {"context": true}}}),
        json!({"type": "resource_link", "uri": "https://example.com/a", "name": "a"}),
        json!({"type": "resource", "resource": {"uri": "file:///a.txt", "text": "the text"}}),
        json!({"type": "image", "mimeType": "image/png", "data": png}),
        json!({"type": "resource_link", "uri": format!("file://{resolved}"), "name": "big.log",
               "_meta": {"acpmux": {"uploadPath": resolved}}}),
    ]);
    for block in &blocks {
        let part = od::part(block);
        assert_ne!(part, od::Part::Unknown, "no rule names {block}");
        let needs = od::proof_needs(&proven_with(vec![block.clone()]));
        assert_eq!(
            part == od::Part::Carried,
            needs == od::Needs::default(),
            "{part:?} {block}: {needs:?}"
        );
    }
    // An audio block, or an upload's link that names no upload, is named as none of them: its
    // prompt is delivered again whole, never taken as held.
    for block in [
        json!({"type": "audio", "mimeType": "audio/wav", "data": png}),
        json!({"type": "resource_link", "uri": "acpmux-upload:019a", "name": "x"}),
    ] {
        assert_eq!(od::part(&block), od::Part::Unknown, "{block}");
        assert!(od::proof_needs(&proven_with(vec![block])).unknown);
    }
}

/// Review of #37284 at 77f91e5a, F1: a prompt of an upload named by reference (a file past one
/// message, `attach::blocks_for`), proven by its `queued` record, goes only once its machine
/// shows it holds the upload, which no restore can bring back (its bytes are only there). At
/// 77f91e5a nothing was asked, so a fresh machine without the upload took the delivery as held
/// and refused the prompt at its turn (`upload.missing`).
#[test]
fn an_upload_prompt_goes_only_once_its_machine_holds_the_upload() {
    use crate::hub::open_delivery as od;
    let upload = crate::attach::every_block_kind()
        .into_iter()
        .find(|b| b["type"] == "resource_link")
        .unwrap();
    let id = upload["_meta"]["acpmux"]["upload"]["uploadId"].clone();
    let d = proven_with(vec![json!({"type": "text", "text": "the log"}), upload]);
    assert_eq!(od::held_ask(&d, (false, false, true)), None, "77f91e5a asked nothing");
    let ask = od::held_ask(&d, (false, false, false)).expect("the upload is asked for");
    assert_eq!(ask["uploads"], json!([{"uploadId": id, "fileName": "big.log"}]));
    assert_eq!(ask["sessionId"], "m1");
    assert!(od::proof_files(&d).is_empty() && od::proof_images(&d).is_empty());
}

/// Review of #37284 at 8b5f3063, F2: a peer whose journal ends with what its own recovery wrote
/// names where that began (`recoveredAfter`). A copy past that point goes back from there,
/// though it ends at or before the peer's `lastSeq`; one that ends at or before it has nothing to
/// give back, and holds nothing. Under 8b5f3063's rules the row named `lastSeq` alone, and the
/// copy that ended there was not ahead.
#[test]
fn a_copy_goes_back_from_where_the_peers_own_recovery_began() {
    use crate::hub::open_delivery as od;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    keep(&mut store, "m1", 1..=12);
    keep(&mut store, "m2", 1..=9);
    // Both journals end at 12, the last three records their own recovery's.
    let summary = json!({"sessionId": "m1", "createdAt": 7, "lastSeq": 12, "recoveredAfter": 9});
    let row = |mux: &str, old: bool| restore::row_of(mux, &summary, old).unwrap();
    assert_eq!(row("m1", true), (("m1".to_owned(), 7, 12), 12), "8b5f3063 compared with lastSeq");
    let (ahead, _) = store.ahead(PEER, vec![row("m1", true).0]).unwrap();
    assert!(ahead.is_empty(), "8b5f3063 found the copy ahead");
    assert_eq!(row("m1", false), (("m1".to_owned(), 7, 9), 12));
    let rows = vec![row("m1", false).0, row("m2", false).0];
    let (ahead, since) = store.ahead(PEER, rows.clone()).unwrap();
    let outbox = crate::hub::outbox::Outbox::default();
    let proofs = od::proofs_past(&outbox, PEER, &rows, &since);
    let (back, held) = restore::with_proofs(ahead, proofs, &rows);
    assert_eq!(back.len(), 1, "only the copy past the recovery's start goes back");
    let given: Vec<u64> = back[0].3.iter().filter_map(seq_of).collect();
    assert_eq!((back[0].0.as_str(), back[0].2, given), ("m1", 9, vec![10, 11, 12]));
    assert!(held.is_empty(), "a copy within the recovery held its session");
    // A row with no recovery, or one at its end, is compared with `lastSeq`.
    let plain = json!({"createdAt": 7, "lastSeq": 12, "recoveredAfter": 40});
    assert_eq!(restore::row_of("m1", &plain, false).unwrap().0.2, 12);
    // A page of that machine on a new link, before its restore: its recovery's records past 9
    // never join the copy over the copy's own, which go back (8b5f3063 compared `lastSeq`
    // alone, and they joined).
    list(&mut store, &[("m1", 7)]);
    let recovery = || {
        let mut page = attach(7, 2, true, recs(10..=12));
        for r in &mut page.records {
            r["msg"]["text"] = json!("the machine's own recovery");
        }
        page.row = Some(summary.clone());
        page
    };
    let text = |store: &mut Store| {
        store.load(&key("m1"));
        let records = store.copies[&key("m1")].records.as_ref().unwrap();
        records[&11]["msg"]["text"].clone()
    };
    put(&mut store, "m1", recovery());
    assert_eq!(seqs(&mut store, "m1"), (1..=12).collect::<Vec<_>>());
    assert_eq!(text(&mut store), json!("line 11"), "the copy keeps its own records");
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(crate::hub::journal_restore::AT_8B5F));
    assert!(store.copies[&key("m1")].head.last_seq >= recovery().seen().unwrap());
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
}

/// The step on a later link of a delivery of an attachment prompt (its `user_message` holds a
/// hidden context) whose turn started at once, once the restore that gave its records back to a
/// fresh machine settled that cut turn for a resend to run whole (`turn_result` marked
/// `rerunOnResend`), under `rules`. `queued`: the prompt waited in the queue first (its `queued`
/// record is in the proof too).
fn step_after_a_restore_settled_its_cut_turn(
    rules: u8,
    queued: bool,
) -> crate::hub::open_delivery::Step {
    use crate::hub::open_delivery as od;
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(rules));
    let outbox = crate::hub::outbox::Outbox::default();
    let now = crate::store::now_ms();
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": format!("{PEER}/m1"),
        "request": {"sessionId": format!("{PEER}/m1"), "_meta": {"acpmux": {"promptId": "p1"}}},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    outbox.add(d);
    let mut accepted = life("m1", 4, "user_message", "p1");
    accepted["msg"]["text"] = json!("read the notes");
    accepted["msg"]["hiddenContext"] = json!(true);
    let mut settled = life("m1", 6, "turn_result", "p1");
    settled["msg"]["status"] = json!("failed");
    settled["msg"]["detail"] = json!("outcome_unknown");
    settled["msg"][od::RERUN_ON_RESEND] = json!(true);
    let mut records = vec![accepted, life("m1", 5, "turn_started", "p1"), settled];
    if queued {
        records.insert(0, life("m1", 3, "queued", "p1"));
    }
    od::take_written(&outbox, (PEER, "m1", 7), &records, (1, 1));
    let ends = HashMap::from([("m1".to_owned(), (7, 9))]);
    let step = od::step(&outbox.get("d1").unwrap(), now, (1, 2), &ends);
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    step
}

/// Review of #37284 at 4bce04df, F1, on the owner: the restore's settling of a cut attachment
/// turn (no continuation: one could not carry the attachment) is not the prompt's end, so its
/// delivery is sent again, whole, and the machine runs it (`log_load.rs`
/// `mark_unknown_outcome`). Under 4bce04df's rules that `turn_result` proved it ended: the
/// delivery went on to its check and release, and the attachment never reached the agent.
#[test]
fn a_cut_attachment_turn_a_restore_settled_for_its_resend_is_delivered_again() {
    use crate::hub::open_delivery as od;
    assert_eq!(step_after_a_restore_settled_its_cut_turn(0, false), od::Step::Again);
    let old =
        step_after_a_restore_settled_its_cut_turn(crate::hub::journal_restore::AT_4BCE, false);
    assert_eq!(old, od::Step::Check, "4bce04df took the settling as the prompt's end");
}

/// Review of #37284 at fd33a65b, F1: an attachment prompt that waited in the queue, then started
/// and was cut when its machine went away, is delivered again once a restore settled its cut
/// turn for a resend to run whole: its old `queued` record proves nothing, as the prompt left
/// the queue. Under fd33a65b's rules any `queued` record proved it: the delivery went on to its
/// check and release, and the attachment never reached the agent. A prompt still waiting in the
/// queue is put back whole from its `queued` record, and proven by it.
#[test]
fn a_queued_attachment_prompt_cut_mid_turn_is_delivered_again() {
    use crate::hub::open_delivery as od;
    assert_eq!(step_after_a_restore_settled_its_cut_turn(0, true), od::Step::Again);
    let old = step_after_a_restore_settled_its_cut_turn(crate::hub::journal_restore::AT_FD33, true);
    assert_eq!(old, od::Step::Check, "fd33a65b took its old queued record as proof");
    let none = std::collections::HashSet::new();
    let mut accepted = life("m1", 4, "user_message", "p1");
    accepted["msg"]["hiddenContext"] = json!(true);
    let waiting = [life("m1", 3, "queued", "p1")];
    assert!(od::rerunnable(&waiting, &none), "a prompt still waiting goes back whole");
    let started = [waiting[0].clone(), accepted, life("m1", 5, "turn_started", "p1")];
    assert!(!od::rerunnable(&started, &none), "a started attachment prompt does not");
}

/// Review of #37284 at 4bce04df, F2: a delivery sent to `peer/name` and pinned to the session
/// that name named then is sent again to that session by its id, in its generation, after the
/// session was renamed and another session took the name; never to the name's new holder. Under
/// 4bce04df's rules the resend named `peer/name` again, which now resolves to the other session
/// (another generation: refused as stale for good, the pinned session never reached).
#[test]
fn a_delivery_again_goes_to_its_pinned_session_after_a_rename_and_the_names_reuse() {
    use crate::hub::open_delivery as od;
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let peer = add_idle_peer(&hub, PEER);
    let row = |id: &str, name: &str, created: u64| {
        json!({"sessionId": id, "name": name, "status": "idle", "createdAt": created,
               "updatedAt": 5})
    };
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::Sessions(vec![row("m1", "moved", 7)]));
    let by_name = format!("{PEER}/moved");
    let (_, named, _) = hub.resolve_remote(&by_name).expect("the name resolves");
    assert_eq!(named, "m1");
    let now = crate::store::now_ms();
    let d: crate::hub::outbox::Delivery = serde_json::from_value(json!({
        "id": "d1", "target": by_name,
        "request": {"sessionId": by_name, "prompt": [{"type": "text", "text": "hi"}],
                    "_meta": {"acpmux": {"promptId": "p1"}}},
        "state": "delivered", "openOnPeer": true, "createdAt": now, "updatedAt": now,
        "pin": {"peer": PEER, "session": "m1", "generation": 7, "link": [1, 1]},
    }))
    .unwrap();
    let pin = d.pin.clone().unwrap();
    // The pinned session is renamed, and another session takes its old name.
    hub.apply_peer_notice(
        PEER,
        peer.generation,
        PeerNotice::Sessions(vec![row("m1", "moved-before", 7), row("m2", "moved", 9)]),
    );
    let (_, holder, _) = hub.resolve_remote(&by_name).expect("the name resolves");
    assert_eq!(holder, "m2", "the name is the other session's now");
    let resolved = |request: &Value| {
        let target = request["sessionId"].as_str().unwrap().to_owned();
        let (_, id, summary) = hub.resolve_remote(&target).expect("the resend's target resolves");
        (id, summary["createdAt"].as_u64())
    };
    let again = od::again_request(&d, &pin);
    assert_eq!(again["sessionId"], format!("{PEER}/m1"), "{again}");
    assert_eq!(resolved(&again), ("m1".to_owned(), Some(7)), "the pinned session, its generation");
    assert_eq!(again["_meta"]["acpmux"]["sessionCreatedAt"], 7, "{again}");
    assert_eq!(again["_meta"]["acpmux"]["resend"], true, "{again}");
    assert_eq!(again["_meta"]["acpmux"]["promptId"], "p1", "{again}");
    assert_eq!(again["prompt"], d.request["prompt"], "the whole prompt goes again");
    // 4bce04df's rules: the name again, now the other session's.
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(crate::hub::journal_restore::AT_4BCE));
    let old = od::again_request(&d, &pin);
    crate::hub::journal_restore::OLD_RULES.with(|r| r.set(0));
    assert_eq!(old["sessionId"], by_name.as_str());
    assert_eq!(resolved(&old), ("m2".to_owned(), Some(9)), "4bce04df sent it to the new holder");
}
