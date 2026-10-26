//! `peer_snapshot.rs`: the store's bounds, a full disk, refused removals, a restart, and a
//! directory that does not read (the files: `disk_tests.rs`). The tests drive the store's thread
//! body directly; `keep` stands for what starts or grows a copy, which comes next.

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
