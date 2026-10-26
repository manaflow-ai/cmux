//! `peer_snapshot.rs`: which copy may grow (generations, purges, joins, links), the bounds, a
//! full disk, refused removals, a restart, and the hub's taps (the files: `disk_tests.rs`).
//! Most tests drive the store's thread body (`Store::take`) directly, in order.

use super::*;

const PEER: &str = "huge-blue";

fn rec(seq: u64) -> Value {
    json!({"sessionId": "m1", "seq": seq, "at": seq, "dir": "in", "kind": "agent_message_chunk",
           "msg": {"text": format!("line {seq}")}})
}

fn recs(range: std::ops::RangeInclusive<u64>) -> Vec<Value> {
    range.map(rec).collect()
}

fn key(mux: &str) -> Key {
    (PEER.to_owned(), mux.to_owned())
}

fn store_at(dir: &Path) -> Store {
    let mut store = Store::new(disk::root(dir), Arc::default(), Arc::default());
    store.scan();
    store
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
    store.take(Op::Record { key: key(mux), link: (1, link), record: of(mux, rec(seq)) });
}

/// The seqs `mux`'s copy holds, read in from its file if need be.
fn seqs(store: &mut Store, mux: &str) -> Vec<u64> {
    if !store.load(&key(mux)) {
        return vec![];
    }
    let records = store.copies[&key(mux)].records.as_ref();
    records.map_or(vec![], |r| r.keys().copied().collect())
}

/// Whether `mux`'s copy holds the chat from its first record.
fn whole(store: &Store, mux: &str) -> bool {
    store.copies[&key(mux)].head.from_start
}

/// What `mux`'s file holds: its head and its seqs.
fn on_disk(path: &Path, mux: &str) -> Option<(Head, Vec<u64>)> {
    let read = disk::read(path, &(PEER.to_owned(), mux.to_owned())).unwrap();
    read.map(|(head, records)| (head, records.into_keys().collect()))
}

fn file(dir: &Path, mux: &str) -> PathBuf {
    disk::path(&disk::root(dir), &key(mux)).unwrap()
}

#[test]
fn a_copy_survives_a_restart_and_keeps_each_seq_once() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=10)));
    put(&mut store, "m1", events(7, 1, 4, recs(5..=12)));
    live(&mut store, "m1", 1, 12);
    live(&mut store, "m1", 1, 13);
    store.write_due(None, true);
    let text = std::fs::read_to_string(file(dir.path(), "m1")).unwrap();
    assert_eq!(text.lines().count(), 1 + 13, "a head line and each record once");

    let mut again = store_at(dir.path());
    assert_eq!(seqs(&mut again, "m1"), (1..=13).collect::<Vec<_>>());
    assert_eq!(again.copies[&key("m1")].head.generation, Some(7));
    assert!(whole(&again, "m1"), "the copy holds the chat from its first record");
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
fn a_purged_generation_stays_purged_until_the_peer_lists_without_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    store.write_due(None, true);
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
    store.take(Op::Lagged(PEER.into()));
    live(&mut store, "m1", 2, 8);
    assert_eq!(seqs(&mut store, "m1").last(), Some(&7), "none after a lag until a page");
    // A page of the old link, taken late, does not come back either.
    put(&mut store, "m1", attach(7, 1, false, recs(1..=9)));
    assert_eq!(seqs(&mut store, "m1").last(), Some(&7));
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
fn a_record_past_the_session_bound_alone_goes_and_the_copy_covers_what_follows() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    let huge = json!({"seq": 2, "kind": "tool_call_update", "msg": {"text": "x".repeat(SESSION_BYTES as usize)}});
    put(&mut store, "m1", attach(7, 1, false, vec![rec(1), huge, rec(3)]));
    assert_eq!(seqs(&mut store, "m1"), vec![3]);
    let head = &store.copies[&key("m1")].head;
    assert_eq!((head.first_seq, head.last_seq, head.from_start), (3, 3, false));
    store.write_due(None, true);
    assert!(store.copies[&key("m1")].disk <= 2 * SESSION_BYTES);
}

#[test]
fn copies_stay_within_their_bounds_and_the_least_recently_used_goes() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    let names: Vec<String> = (0..12).map(|i| format!("m{i}")).collect();
    list(&mut store, &names.iter().map(|m| (m.as_str(), 7)).collect::<Vec<_>>());
    put(&mut store, "m0", attach(7, 1, false, recs(1..=(SESSION_EVENTS as u64 + 15))));
    let kept = seqs(&mut store, "m0");
    assert_eq!(kept.len(), SESSION_EVENTS);
    assert_eq!(kept.last(), Some(&(SESSION_EVENTS as u64 + 15)), "the newest stay");
    assert!(!whole(&store, "m0"), "its first records went");
    for m in &names[1..] {
        put(&mut store, m, attach(7, 1, false, recs(1..=SESSION_EVENTS as u64)));
        store.write_due(None, true);
        assert!(store.memory <= MEMORY_BYTES, "{} past the memory bound", store.memory);
        assert!(store.disk_with(None, 0) <= TOTAL_BYTES);
    }
    assert!(!file(dir.path(), "m0").exists(), "the least recently used went");
    assert!(file(dir.path(), &names[11]).exists());
    let on_disk: u64 =
        disk::scan(&disk::root(dir.path())).unwrap().copies.iter().map(|c| c.2).sum();
    assert!(on_disk <= TOTAL_BYTES);
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
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=4)));
    store.write_due(None, true);
    assert!(!file(dir.path(), "m1").exists());
    let retry = store.copies[&key("m1")].retry;
    store.write_due(None, true);
    assert!(store.copies[&key("m1")].retry > retry, "the retry backs off");
    assert!(store.wake.is_some(), "and is due again");
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3, 4]);
    store.write = crate::config::write_atomic;
    std::thread::sleep(RETRY_MAX.min(Duration::from_millis(200)));
    store.write_due(None, false);
    assert!(file(dir.path(), "m1").exists());
    assert_eq!(store.copies[&key("m1")].due, None);
    // Unwritten copies past the memory bound go, never past it.
    store.write = refuse;
    let names: Vec<String> = (0..8).map(|i| format!("w{i}")).collect();
    list(&mut store, &names.iter().map(|m| (m.as_str(), 7)).collect::<Vec<_>>());
    for m in &names {
        put(&mut store, m, attach(7, 1, false, recs(1..=SESSION_EVENTS as u64)));
        store.write_due(None, true);
        assert!(store.memory <= MEMORY_BYTES);
    }
}

#[test]
fn a_restart_drops_what_is_not_a_copy_and_cuts_one_past_its_bound() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let root = disk::root(dir.path());
    let head = |mux: &str| Head {
        peer: PEER.into(),
        session_id: mux.into(),
        generation: Some(7),
        from_start: true,
        ..Head::default()
    };
    let big: BTreeMap<u64, Value> =
        (1..=(SESSION_EVENTS as u64 + 5)).map(|s| (s, rec(s))).collect();
    disk::write(crate::config::write_atomic, &root, &key("m1"), &disk::encode(&head("m1"), &big))
        .unwrap();
    // Another session's copy under m2's name, and a leftover temporary file.
    disk::write(crate::config::write_atomic, &root, &key("m2"), &disk::encode(&head("m9"), &big))
        .unwrap();
    let tmp = file(dir.path(), "m1").with_extension("tmp-1-1");
    std::fs::write(&tmp, b"x").unwrap();
    let mut store = store_at(dir.path());
    assert!(!file(dir.path(), "m2").exists() && !tmp.exists());
    let kept = seqs(&mut store, "m1");
    assert_eq!(kept.len(), SESSION_EVENTS);
    assert!(!whole(&store, "m1"), "its first records went");
    store.write_due(None, true);
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
    let names: Vec<String> = (0..9).map(|i| format!("m{i}")).collect();
    list(&mut store, &names.iter().map(|m| (m.as_str(), 7)).collect::<Vec<_>>());
    for m in &names {
        put(&mut store, m, attach(7, 1, false, recs(1..=SESSION_EVENTS as u64)));
        store.write_due(None, true);
    }
    let other = ("other".to_owned(), "n".to_owned());
    let rows = vec![("n".to_owned(), Some(7))];
    store.take(Op::Listed { peer: "other".into(), rows, full: true });
    let peer_dir = disk::peer_dir(&disk::root(dir.path()), PEER).unwrap();
    let held = read_only(&peer_dir, || {
        // The peer lists none of them now, but its directory will not let them go.
        list(&mut store, &[]);
        assert!(store.copies.keys().all(|k| k.0 != PEER));
        // A copy near its own bound: no room beside what the refused removals hold.
        let big = |seq: u64| json!({"sessionId": "n", "seq": seq, "kind": "agent_message_chunk", "msg": {"text": "x".repeat(400)}});
        let page = attach(7, 1, false, (1..=SESSION_EVENTS as u64).map(big).collect());
        store.take(Op::Page { key: other.clone(), page });
        store.write_due(None, true);
        (store.dead.values().sum::<u64>(), store.copies[&other].disk)
    });
    let Some((dead, written)) = held else { return };
    assert!(dead > TOTAL_BYTES / 2, "the refused removals stay counted: {dead}");
    assert_eq!(written, 0, "no room while the refused removals hold the total");
    store.write_due(None, true);
    assert!(store.dead.is_empty(), "tried again once the directory allows it");
    assert!(store.copies[&other].disk > 0);
    assert!(!peer_dir.exists(), "the emptied directory of a peer with no copy goes too");
}

#[test]
fn what_was_purged_or_unlisted_before_the_disk_read_is_applied_to_it() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7), ("m2", 7), ("m3", 7)]);
    for m in ["m1", "m2", "m3"] {
        put(&mut store, m, attach(7, 1, false, recs(1..=2)));
    }
    store.write_due(None, true);
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

    // A capture of m4 lost before the disk reads, and every op of another peer lost then: what
    // an earlier run kept of them goes too, so no copy comes back past what it missed.
    let mut store = store_at(dir.path());
    list(&mut store, &[("m4", 7)]);
    put(&mut store, "m4", attach(7, 1, false, recs(1..=2)));
    let rows = vec![("n".to_owned(), Some(7))];
    store.take(Op::Listed { peer: "other".into(), rows, full: true });
    let page = attach(7, 1, false, vec![json!({"sessionId": "n", "seq": 1, "kind": "k"})]);
    store.take(Op::Page { key: ("other".into(), "n".into()), page });
    store.write_due(None, true);
    let mut again = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
    again.take(Op::Lost(key("m4")));
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
fn a_record_of_another_session_is_never_kept_as_this_ones() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    let mut page = attach(7, 1, false, recs(1..=3));
    page.records[1] = of("m2", rec(2));
    store.take(Op::Page { key: key("m1"), page });
    assert!(seqs(&mut store, "m1").is_empty(), "a page holding another session's record");
    put(&mut store, "m1", attach(7, 1, false, recs(1..=3)));
    store.take(Op::Record { key: key("m1"), link: (1, 1), record: of("m2", rec(4)) });
    assert_eq!(seqs(&mut store, "m1"), vec![1, 2, 3]);
}

#[test]
fn a_file_past_its_bound_is_not_read() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let root = disk::root(dir.path());
    let head =
        Head { peer: PEER.into(), session_id: "m1".into(), generation: Some(7), ..Head::default() };
    let mut bytes = disk::encode(&head, &BTreeMap::new());
    bytes.extend(std::iter::repeat_n(b' ', FILE_BYTES as usize));
    disk::write(crate::config::write_atomic, &root, &key("m1"), &bytes).unwrap();
    // A head with no end within its bound.
    let endless = vec![b'{'; HEAD_BYTES as usize * 2];
    disk::write(crate::config::write_atomic, &root, &key("m2"), &endless).unwrap();
    assert!(disk::read_head(&file(dir.path(), "m2"), &key("m2")).is_err());
    let store = store_at(dir.path());
    assert!(store.copies.is_empty());
    assert!(!file(dir.path(), "m1").exists() && !file(dir.path(), "m2").exists());
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
fn a_removed_peer_added_again_keeps_its_new_copies() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let mut store = store_at(dir.path());
    list(&mut store, &[("m1", 7)]);
    put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
    store.write_due(None, true);
    store.take(Op::ForgetPeer(PEER.into()));
    assert!(!file(dir.path(), "m1").exists());
    list(&mut store, &[("m1", 9)]);
    store.take(Op::Page {
        key: key("m1"),
        page: Page { link: (2, 0), ..attach(9, 0, false, recs(1..=3)) },
    });
    store.write_due(None, true);
    store.sweep();
    assert!(file(dir.path(), "m1").exists());
}

#[test]
fn a_snapshot_directory_that_is_a_symlink_is_never_read_or_emptied() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let elsewhere = dir.path().join("elsewhere");
    std::fs::create_dir(&elsewhere).unwrap();
    std::fs::write(elsewhere.join("keep.txt"), b"not ours").unwrap();
    std::os::unix::fs::symlink(&elsewhere, disk::root(dir.path())).unwrap();
    let mut store = Store::new(disk::root(dir.path()), Arc::default(), Arc::default());
    assert!(!store.scan());
    assert!(elsewhere.join("keep.txt").exists());
}

#[test]
fn a_directory_that_does_not_read_holds_up_every_write() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let root = disk::root(dir.path());
    crate::config::private_state_dir(&root).unwrap();
    let held = read_only(&root, || {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
        let mut store = store_at(dir.path());
        assert!(!store.scanned);
        list(&mut store, &[("m1", 7)]);
        put(&mut store, "m1", attach(7, 1, false, recs(1..=2)));
        store.write_due(None, true);
        store
    });
    let Some(mut store) = held else { return };
    assert!(store.copies[&key("m1")].due.is_some(), "not written while the directory is unknown");
    store.write_due(None, true);
    assert!(store.scanned && file(dir.path(), "m1").exists());
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
fn the_hub_keeps_a_down_peers_records_and_pages_and_purges_drop_them() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let hub = hub_at(dir.path());
    let peers = hub.store.peer_cache_dir().unwrap();
    let path = |mux: &str| disk::path(&disk::root(&peers), &key(mux)).unwrap();
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
    hub.capture_peer_page(on(0), "m1", &json!({"limit": 400, "kinds": ["transcript"]}), &page);
    // Older history, and a page of some kinds that leaves the transcript out, are not kept.
    hub.capture_peer_page(on(0), "m1", &json!({"beforeSeq": 1}), &page);
    hub.capture_peer_page(on(0), "m1", &json!({"kinds": ["prompt"]}), &page);
    for seq in 3..=4 {
        hub.apply_peer_notice(PEER, peer.generation, notice(seq, 0));
    }
    // The link ends: what was read on it and handled late is not kept.
    peer.link_ended();
    hub.apply_peer_notice(PEER, peer.generation, notice(5, 0));
    let late = json!({"events": recs(5..=6), "hasMore": false, "lastSeq": 6});
    hub.capture_peer_page(on(0), "m1", &json!({"afterSeq": 4}), &late);
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
        "m1",
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
    hub.capture_peer_page((PEER, peer.generation, link, Some(42)), "m2", &json!({}), &page);
    hub.peer_snapshots.flush_now();
    assert!(path("m2").exists());
    let changed = PeerNotice::SessionChanged { session: m2(43), kind: "created".into(), seq: 6 };
    hub.apply_peer_notice(PEER, peer.generation, changed);
    hub.peer_snapshots.flush_now();
    assert!(!path("m2").exists());
    hub.forget_peer_cache(PEER);
    hub.peer_snapshots.flush_now();
    assert!(!disk::peer_dir(&disk::root(&peers), PEER).unwrap().exists());
}

#[test]
fn captures_that_fall_behind_drop_the_copy_instead_of_leaving_a_hole() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    let snaps = PeerSnapshots::open(Some(dir.path().to_owned()));
    snaps.listed(PEER, vec![("m1".into(), Some(7))], true);
    snaps.page((PEER, "m1"), attach(7, 1, false, recs(1..=3)));
    snaps.flush_now();
    snaps.queued.fetch_add(QUEUED_BYTES, Ordering::AcqRel);
    snaps.record((PEER, "m1"), (1, 1), rec(4));
    snaps.queued.fetch_sub(QUEUED_BYTES, Ordering::AcqRel);
    snaps.record((PEER, "m1"), (1, 1), rec(5));
    snaps.flush_now();
    assert_eq!(on_disk(&disk::path(&disk::root(dir.path()), &key("m1")).unwrap(), "m1"), None);
    assert!(snaps.dropped().keys.is_empty());
}
