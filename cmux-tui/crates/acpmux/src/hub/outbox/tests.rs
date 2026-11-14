use super::*;

fn delivery(n: usize) -> Delivery {
    let now = crate::store::now_ms();
    Delivery {
        id: format!("d-{n}"),
        target: "lane".into(),
        request: json!({"sessionId": "lane", "_meta": {"acpmux": {"promptId": format!("p-{n}")}}}),
        caller: None,
        unproven_caller: None,
        not_terminal: false,
        state: State::Queued,
        attempts: 0,
        never_sent: false,
        relay_post: None,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    }
}

/// An open delivery past [`OPEN_ON_PEER_FOR_MS`] is not dropped: it fails, saying why, and
/// its sender's status names the reason.
#[test]
fn an_open_delivery_past_its_bound_fails_visibly() {
    let outbox = Outbox::default();
    let mut d = delivery(1);
    (d.state, d.open_on_peer) = (State::Delivered, true);
    d.created_at -= OPEN_ON_PEER_FOR_MS;
    outbox.add(d).unwrap();
    outbox.add(delivery(2)).unwrap();
    outbox.update("d-2", |d| d.attempts += 1);
    let lapsed = outbox.get("d-1").expect("an open delivery past its bound went unseen");
    assert_eq!((lapsed.state, lapsed.open_on_peer), (State::Failed, false));
    assert_eq!(lapsed.status()["reason"], "open_lapsed");
    assert!(outbox.open_on_peers().is_empty());
}

#[test]
fn list_is_newest_first_by_sender_without_bookkeeping() {
    let outbox = Outbox::default();
    for n in 0..4 {
        let mut d = delivery(n);
        d.created_at = n as u64;
        d.caller = Some(if n % 2 == 0 { "s-even" } else { "s-odd" }.into());
        outbox.add(d).unwrap();
    }
    let mut intent = delivery(9);
    intent.request["_meta"]["acpmux"]["forwardProjection"] = json!({"text": "x"});
    intent.state = State::Held;
    outbox.add(intent).unwrap();
    let ids = |(v, _): (Vec<Delivery>, usize)| v.into_iter().map(|d| d.id).collect::<Vec<_>>();
    assert_eq!(ids(outbox.list(None, 10)), ["d-3", "d-2", "d-1", "d-0"]);
    assert_eq!(ids(outbox.list(Some("s-even"), 10)), ["d-2", "d-0"]);
    assert_eq!(ids(outbox.list(None, 1)), ["d-3"]);
    // A waiting one is never cut for a newer settled one, and the count is of all of them.
    for n in 1..4 {
        outbox.update(&format!("d-{n}"), |d| d.state = State::Delivered);
    }
    assert_eq!(outbox.list(None, 1).1, 1);
    assert_eq!(ids(outbox.list(None, 1)), ["d-0"]);
}

#[test]
fn forward_intents_do_not_alias_other_senders_targets_or_queued_deliveries() {
    let outbox = Outbox::default();
    outbox.add(delivery(1)).unwrap();
    let mut intent = delivery(1);
    intent.id = "intent-1".into();
    intent.caller = Some("sender".into());
    intent.request["_meta"]["acpmux"]["forwardProjection"] = json!({"text": "hello"});
    assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-1");
    intent.id = "unused-retry-id".into();
    assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-1");
    intent.target = "another-target".into();
    intent.id = "intent-2".into();
    assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-2");
    intent.caller = Some("another-sender".into());
    intent.id = "intent-3".into();
    assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-3");
    // A `send_queue` retry of the same prompt id is another message: its own intent, so a
    // restart reads the receiver's journal for the retry's delivery id too.
    intent.request["_meta"]["acpmux"]["forwardProjection"]["messageId"] = json!("delivery-1");
    intent.id = "intent-4".into();
    assert_eq!(outbox.remember_forward(intent.clone()).unwrap().id, "intent-4");
    intent.id = "unused-retry-id".into();
    assert_eq!(outbox.remember_forward(intent).unwrap().id, "intent-4");
    assert_eq!(outbox.add(delivery(1)).unwrap().id, "d-1");
}

/// A queued send's prompt id is a key for one message to one target, as the target's own
/// prompt ledger keys it (`Hub::prompt_with`): the same prompt id to another target is a
/// message of its own and is delivered too. Before, `add` answered it with the first
/// message's delivery (`delivered`, to the first target), and the second never went.
#[test]
fn a_queued_send_with_a_reused_prompt_id_to_another_target_is_its_own() {
    let outbox = Outbox::default();
    let first = delivery(1);
    assert_eq!(outbox.add(first.clone()).unwrap().id, "d-1");
    // The same message again (a CLI retry): the first delivery.
    let mut again = first.clone();
    again.id = "retry".into();
    assert_eq!(outbox.add(again).unwrap().id, "d-1");
    // The same prompt id to another target: its own delivery.
    let mut other = first.clone();
    other.id = "d-2".into();
    other.target = "other".into();
    other.request["sessionId"] = json!("other");
    assert_eq!(outbox.add(other.clone()).unwrap().id, "d-2");
    other.id = "retry-2".into();
    assert_eq!(outbox.add(other).unwrap().id, "d-2");
    assert_eq!(outbox.unsettled(), 2);
}

#[test]
fn provisional_duplicate_does_not_consume_acceptance_hooks() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let accepts = PeerAccepts::default();
    let seen = std::sync::Arc::new(AtomicUsize::new(0));
    let provisional = std::sync::Arc::new(AtomicUsize::new(0));
    for _ in 0..2 {
        let provisional = provisional.clone();
        let seen = seen.clone();
        accepts.wait(
            "peer",
            "target",
            "p1",
            Box::new(move |_| {
                seen.fetch_add(1, Ordering::SeqCst);
            }),
            std::sync::Arc::new(move |_| {
                provisional.fetch_add(1, Ordering::SeqCst);
            }),
        );
    }
    accepts.accepted(
        "peer",
        &json!({"sessionId": "target", "promptId": "p1", "duplicate": true, "turnId": null}),
    );
    assert_eq!(seen.load(Ordering::SeqCst), 0);
    assert_eq!(provisional.load(Ordering::SeqCst), 2);
    accepts.accepted("peer", &json!({"sessionId": "target", "promptId": "p1", "turnId": "t1"}));
    assert_eq!(seen.load(Ordering::SeqCst), 2);

    // A retry registered after the original acknowledgement still hears its
    // provisional acknowledgement while the original turn remains busy.
    let seen_late = seen.clone();
    let provisional_late = provisional.clone();
    let token = accepts.wait(
        "peer",
        "target",
        "p1",
        Box::new(move |_| {
            seen_late.fetch_add(1, Ordering::SeqCst);
        }),
        std::sync::Arc::new(move |_| {
            provisional_late.fetch_add(1, Ordering::SeqCst);
        }),
    );
    accepts.accepted(
        "peer",
        &json!({"sessionId": "target", "promptId": "p1", "duplicate": true, "turnId": null}),
    );
    assert_eq!(provisional.load(Ordering::SeqCst), 3);
    assert_eq!(seen.load(Ordering::SeqCst), 2);
    accepts.forget("peer", "target", "p1", token);
    assert!(accepts.hooks.lock().unwrap().is_empty());
}

#[test]
fn peer_acceptance_is_scoped_to_its_target_session() {
    let accepts = PeerAccepts::default();
    let seen = std::sync::Arc::new(StdMutex::new(Vec::new()));
    for target in ["a", "b"] {
        let seen = seen.clone();
        accepts.wait(
            "peer",
            target,
            "same-prompt",
            Box::new(move |_| {
                seen.lock().unwrap().push(target);
            }),
            std::sync::Arc::new(|_| {}),
        );
    }
    accepts
        .accepted("peer", &json!({"sessionId": "a", "promptId": "same-prompt", "turnId": "t-a"}));
    assert_eq!(*seen.lock().unwrap(), vec!["a"]);
    // An unrelated peer also cannot consume the second target's hook.
    accepts.accepted(
        "other-peer",
        &json!({"sessionId": "b", "promptId": "same-prompt", "turnId": "t-b"}),
    );
    assert_eq!(*seen.lock().unwrap(), vec!["a"]);
    accepts
        .accepted("peer", &json!({"sessionId": "b", "promptId": "same-prompt", "turnId": "t-b"}));
    assert_eq!(*seen.lock().unwrap(), vec!["a", "b"]);
}

/// Sends from many tasks at once share writes, and the file still holds every one of them
/// when each `add` returns: a restart delivers all of them.
#[test]
fn concurrent_adds_are_all_on_disk_when_they_return() {
    let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("outbox.json");
    let outbox = std::sync::Arc::new(Outbox::default());
    assert!(outbox.open(&path).is_empty());
    let threads: Vec<_> = (0..64)
        .map(|n| {
            let outbox = outbox.clone();
            let path = path.clone();
            std::thread::spawn(move || {
                outbox.add(delivery(n)).unwrap();
                // What a restart would read right now holds this one.
                let saved = read_saved(&path).deliveries;
                assert!(saved.contains_key(&format!("d-{n}")), "d-{n} not on disk");
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    outbox.update("d-3", |d| d.state = State::Delivered);
    let restarted = Outbox::default();
    let pending = restarted.open(&path);
    assert_eq!(pending.len(), 63);
    assert_eq!(restarted.get("d-3").map(|d| d.state), Some(State::Delivered));
    let _ = std::fs::remove_dir_all(&dir);
}

/// An add whose write fails is not kept: the sender is told so, and neither this daemon nor
/// a restart delivers it. Nor does a later write that succeeds bring it back.
#[test]
fn an_add_whose_write_fails_is_not_kept() {
    let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    // A regular file where the folder should be fails the write, also for root.
    let blocked = dir.join("blocked");
    std::fs::write(&blocked, b"block").unwrap();
    let path = blocked.join("outbox.json");
    let outbox = std::sync::Arc::new(Outbox::default());
    outbox.open(&path);
    assert!(outbox.add(delivery(1)).is_err());
    assert!(outbox.get("d-1").is_none(), "a delivery not on disk is still in memory");
    // Adds that share one failed write all fail, the same prompt id again among them.
    let held = outbox.disk.lock().unwrap();
    let adds: Vec<_> = [2, 3, 2]
        .into_iter()
        .enumerate()
        .map(|(n, d)| {
            let outbox = outbox.clone();
            let mut d = delivery(d);
            d.id = format!("d-{n}-again");
            std::thread::spawn(move || outbox.add(d).is_err())
        })
        .collect();
    std::thread::sleep(std::time::Duration::from_millis(50));
    drop(held);
    for add in adds {
        assert!(add.join().unwrap(), "an add that shared a failed write answered as kept");
    }
    assert_eq!(outbox.list(None, 10).0.len(), 0, "a delivery not on disk is still in memory");
    std::fs::remove_file(&blocked).unwrap();
    std::fs::create_dir(&blocked).unwrap();
    outbox.add(delivery(4)).unwrap();
    let restarted = Outbox::default();
    let pending: Vec<_> = restarted.open(&path).into_iter().map(|d| d.id).collect();
    assert_eq!(pending, ["d-4"]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A retry of a prompt whose first add is still writing answers only once the file holds it.
#[test]
fn a_duplicate_add_returns_once_the_first_is_on_disk() {
    let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("outbox.json");
    let outbox = std::sync::Arc::new(Outbox::default());
    outbox.open(&path);
    // Hold the write lock as a slow write would, then add: the delivery is in memory only.
    let held = outbox.disk.lock().unwrap();
    let first = {
        let outbox = outbox.clone();
        std::thread::spawn(move || outbox.add(delivery(1)).unwrap())
    };
    while outbox.get("d-1").is_none() {
        std::thread::yield_now();
    }
    let retry = {
        let outbox = outbox.clone();
        let path = path.clone();
        std::thread::spawn(move || {
            let again = outbox.add(delivery(1)).unwrap();
            (again.id, read_saved(&path).deliveries.contains_key("d-1"))
        })
    };
    std::thread::sleep(std::time::Duration::from_millis(50));
    assert!(!retry.is_finished(), "the retry answered before the first add was on disk");
    drop(held);
    first.join().unwrap();
    assert_eq!(retry.join().unwrap(), ("d-1".to_owned(), true));
    let _ = std::fs::remove_dir_all(&dir);
}

fn temp_outbox() -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("outbox.json");
    (dir, path)
}

/// A delivery the size of an average one in a day's real outbox (5.2 MB for 2,512).
fn sized(n: usize, state: State) -> Delivery {
    let mut d = delivery(n);
    d.request["prompt"] = json!([{"type": "text", "text": "x".repeat(1800)}]);
    d.state = state;
    d
}

/// The bytes each of 2,000 changes writes (a send's life, four changes each) with `kept`
/// delivered deliveries already in the outbox, for each size in `sizes`, after checking every
/// one reads back after a restart and that each change writes under a tenth of what the
/// whole-file rewrite did (the snapshot's size; `kept` 10 aside, whose snapshot is tiny).
fn bytes_per_change(sizes: [usize; 2]) -> [u64; 2] {
    sizes.map(|kept| {
        let (dir, path) = temp_outbox();
        let all: BTreeMap<String, Delivery> =
            (0..kept).map(|n| sized(n, State::Delivered)).map(|d| (d.id.clone(), d)).collect();
        let before = serde_json::to_vec(&all).unwrap().len() as u64;
        std::fs::write(&path, serde_json::to_vec(&all).unwrap()).unwrap();
        let outbox = Outbox::default();
        outbox.open(&path);
        let start = outbox.disk.lock().unwrap().written;
        let changes = 2_000;
        for n in 0..changes / 4 {
            // A send's life: queued, delivering, attempted again, delivered.
            let id = format!("d-{}", kept + n);
            outbox.add(sized(kept + n, State::Queued)).unwrap();
            outbox.update(&id, |d| d.state = State::Delivering);
            outbox.update(&id, |d| d.attempts += 1);
            outbox.update(&id, |d| d.state = State::Delivered);
        }
        let after = (outbox.disk.lock().unwrap().written - start) / changes as u64;
        eprintln!("kept {kept}: before {before} B per change, after {after} B per change");
        // Everything comes back after a restart, from the snapshot and the journal.
        let restarted = Outbox::default();
        assert!(restarted.open(&path).is_empty());
        assert_eq!(restarted.list(None, usize::MAX).0.len(), kept + changes / 4);
        assert_eq!(restarted.get(&format!("d-{kept}")).unwrap().attempts, 1);
        assert!(before > 10 * after || kept == 10);
        let _ = std::fs::remove_dir_all(&dir);
        after
    })
}

/// cmuxterm-hq#8660 (hang-watch `6159015094`): the bytes a change writes do not grow with
/// the deliveries kept. Small is 10 kept, large 2,500 (a day of a busy machine, 5 MB);
/// "before" is what the whole-file rewrite wrote for each change, the snapshot's size. A
/// count of bytes, so it holds at any size: a change that rewrote the file, or compacted it
/// more often as it grew, writes more at 2,500 as it would at 25,000. The full ten days,
/// `a_change_writes_the_same_bytes_with_25000_deliveries_kept`, runs on its own.
#[test]
fn a_change_writes_the_same_bytes_with_ten_or_2500_deliveries_kept() {
    let [small, large] = bytes_per_change([10, 2_500]);
    assert!(large * 10 <= small * 12, "large {large} B per change is over 1.2x small {small} B");
}

/// The same at 25,000 kept (ten days of a busy machine, 52 MB), the size hang-watch saw. A
/// debug build took 86 s alone on an idle 8-core CI runner and ran past nextest's 120 s hang
/// guard beside other work (3 of 3 loaded lib runs), so it is a check for its own run:
/// `cargo test -p acpmux --lib hub::outbox::tests::a_change_writes_the_same_bytes_with_25000_deliveries_kept -- --ignored --exact --test-threads=1 --nocapture`.
/// The default run keeps `a_change_writes_the_same_bytes_with_ten_or_2500_deliveries_kept`.
#[test]
#[ignore = "own run, one test at a time: 52 MB through a debug build, past the hang guard under load"]
fn a_change_writes_the_same_bytes_with_25000_deliveries_kept() {
    let [small, large] = bytes_per_change([10, 25_000]);
    assert!(large * 10 <= small * 12, "large {large} B per change is over 1.2x small {small} B");
}

/// A torn last line (a crash or a full disk mid-append) costs only that line; the rest of the
/// journal is read, and the open folds it into a fresh snapshot.
#[test]
fn a_torn_journal_line_is_skipped_and_the_open_compacts() {
    let (dir, path) = temp_outbox();
    let outbox = Outbox::default();
    outbox.open(&path);
    for n in 0..3 {
        outbox.add(delivery(n)).unwrap();
    }
    outbox.update("d-1", |d| d.state = State::Delivered);
    let journal = journal_path(&path);
    let mut torn = std::fs::read(&journal).unwrap();
    assert!(!torn.is_empty(), "small changes go to the journal");
    torn.extend_from_slice(br#"{"id":"d-9","tar"#);
    std::fs::write(&journal, torn).unwrap();
    let restarted = Outbox::default();
    let pending = restarted.open(&path);
    assert_eq!(pending.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(), ["d-0", "d-2"]);
    assert_eq!(restarted.get("d-1").unwrap().state, State::Delivered);
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(std::fs::read(&journal).unwrap(), header_for(&bytes), "the open compacts");
    let snapshot: BTreeMap<String, Delivery> = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(snapshot.len(), 3, "the snapshot alone holds everything for an older daemon");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A torn tail stays fenced off when the snapshot meant to replace it fails (a full disk):
/// the next change's line starts after a newline and is read after a restart.
#[test]
fn a_torn_tail_and_a_failed_snapshot_lose_no_later_change() {
    let (dir, path) = temp_outbox();
    let outbox = Outbox::default();
    outbox.open(&path);
    outbox.add(delivery(0)).unwrap();
    let journal = journal_path(&path);
    let mut torn = std::fs::read(&journal).unwrap();
    torn.extend_from_slice(br#"{"id":"d-9","tar"#);
    std::fs::write(&journal, torn).unwrap();
    {
        let mut disk = outbox.disk.lock().unwrap();
        disk.torn = true;
        disk.snapshot_next = true;
    }
    // The snapshot fails: a folder that is not empty is in its place.
    std::fs::create_dir_all(path.join("occupied")).unwrap();
    outbox.compact();
    assert!(outbox.disk.lock().unwrap().torn, "the fence outlives a failed snapshot");
    outbox.add(delivery(1)).unwrap();
    std::fs::remove_dir_all(&path).unwrap();
    let restarted = Outbox::default();
    let ids: Vec<String> = restarted.open(&path).into_iter().map(|d| d.id).collect();
    assert_eq!(ids, ["d-0", "d-1"]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A snapshot that cannot be read at open is set aside, so a journal started against no
/// snapshot never sits beside it to be ignored once it reads again.
#[test]
fn an_unreadable_snapshot_is_set_aside() {
    let (dir, path) = temp_outbox();
    std::fs::create_dir_all(path.join("unreadable")).unwrap();
    let outbox = Outbox::default();
    outbox.open(&path);
    outbox.add(delivery(0)).unwrap();
    assert!(path.with_extension("json.unreadable").exists());
    let restarted = Outbox::default();
    assert_eq!(restarted.open(&path).len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A change's lines reach the journal before any snapshot of it: a snapshot that fails (or
/// a crash before the journal is cut) still finds the change in the journal, and since the
/// journal's last line for each id is the snapshot's own state, a replay over a newer
/// snapshot is never older.
#[test]
fn a_change_is_journaled_before_its_snapshot() {
    let (dir, path) = temp_outbox();
    let outbox = Outbox::default();
    outbox.open(&path);
    outbox.add(delivery(0)).unwrap();
    // The snapshot's rename fails: a folder that is not empty is in its place.
    std::fs::create_dir_all(path.join("occupied")).unwrap();
    outbox.disk.lock().unwrap().snapshot_next = true;
    outbox.update("d-0", |d| d.state = State::Delivered);
    // The change is on disk in the journal, so it is saved; the snapshot waits for a later
    // try, not the next change.
    assert_eq!(outbox.disk.lock().unwrap().saved, outbox.book().changes);
    assert!(!outbox.disk.lock().unwrap().snapshot_next);
    let tries = outbox.disk.lock().unwrap().snapshot_retry_at;
    assert!(tries >= COMPACT_FLOOR);
    let journal = String::from_utf8(std::fs::read(journal_path(&path)).unwrap()).unwrap();
    let last: Delivery = serde_json::from_str(journal.lines().last().unwrap()).unwrap();
    assert_eq!(last.state, State::Delivered);
    std::fs::remove_dir_all(&path).unwrap();
    let restarted = Outbox::default();
    assert!(restarted.open(&path).is_empty());
    assert_eq!(restarted.get("d-0").unwrap().state, State::Delivered);
    let _ = std::fs::remove_dir_all(&dir);
}

/// An older daemon reads and rewrites `outbox.json` alone. The journal it left behind names
/// the snapshot before that, so a newer daemon started after it never replays it over the
/// older daemon's newer states: nothing goes back to waiting and is sent again.
#[test]
fn a_journal_beside_another_snapshot_is_not_read() {
    let (dir, path) = temp_outbox();
    let outbox = Outbox::default();
    outbox.open(&path);
    outbox.add(delivery(0)).unwrap();
    outbox.update("d-0", |d| d.state = State::Delivering);
    assert!(!read_saved(&path).deliveries["d-0"].settled());
    // The older daemon: delivers it and rewrites the snapshot, leaving the journal.
    let mut older = read_saved(&path).deliveries;
    older.get_mut("d-0").unwrap().state = State::Delivered;
    std::fs::write(&path, serde_json::to_vec(&older).unwrap()).unwrap();
    let restarted = Outbox::default();
    assert!(restarted.open(&path).is_empty(), "nothing resumes to be sent again");
    assert_eq!(restarted.get("d-0").unwrap().state, State::Delivered);
    // And a change after it starts a journal for this snapshot.
    restarted.add(delivery(1)).unwrap();
    let again = Outbox::default();
    assert_eq!(again.open(&path).len(), 1);
    assert_eq!(again.get("d-0").unwrap().state, State::Delivered);
    let _ = std::fs::remove_dir_all(&dir);
}

/// At shutdown the journal is folded in: `outbox.json` alone then holds every change, for
/// whichever daemon starts next.
#[test]
fn compact_leaves_the_snapshot_holding_everything() {
    let (dir, path) = temp_outbox();
    let outbox = Outbox::default();
    outbox.open(&path);
    outbox.add(delivery(0)).unwrap();
    outbox.update("d-0", |d| d.state = State::Delivered);
    outbox.add(delivery(1)).unwrap();
    outbox.compact();
    let bytes = std::fs::read(&path).unwrap();
    let snapshot: BTreeMap<String, Delivery> = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(snapshot["d-0"].state, State::Delivered);
    assert!(snapshot.contains_key("d-1"));
    assert_eq!(std::fs::read(journal_path(&path)).unwrap(), header_for(&bytes));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A waiting delivery's attachments are kept once beside `outbox.json`, which never holds
/// their bytes; a restart reads them back, and ones nothing names go.
#[test]
fn attachments_are_kept_beside_the_file_and_come_back_after_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-outbox-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("outbox.json");
    let block = crate::attach::block("shot.png", b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR");
    let data = block["data"].as_str().unwrap().to_owned();
    let request = json!({"sessionId": "lane", "prompt": [block],
                             "_meta": {"acpmux": {"promptId": "p1"}}});
    let d = Delivery {
        id: "d1".into(),
        target: "lane".into(),
        request,
        caller: None,
        unproven_caller: None,
        not_terminal: false,
        state: State::Queued,
        attempts: 0,
        never_sent: false,
        relay_post: None,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: None,
        accepted: None,
        created_at: 0,
        updated_at: crate::store::now_ms(),
    };
    let outbox = Outbox::default();
    outbox.open(&path);
    let kept = outbox.attachments_path(&d).unwrap();
    keep_attachments(&kept, &d.request).unwrap();
    let orphan = kept.with_file_name("gone.json");
    std::fs::write(&orphan, b"{}").unwrap();
    outbox.add(d).unwrap();
    let journal = std::fs::read_to_string(journal_path(&path)).unwrap_or_default();
    assert!(read_saved(&path).deliveries.contains_key("d1"));
    assert!(!std::fs::read_to_string(&path).unwrap_or_default().contains(&data));
    assert!(!journal.contains(&data));
    assert_eq!(outbox.get("d1").unwrap().request["prompt"][0]["data"], data);
    let restarted = Outbox::default();
    let pending = restarted.open(&path);
    assert_eq!(pending[0].request["prompt"][0]["data"], data);
    assert!(kept.exists() && !orphan.exists());
    std::fs::remove_dir_all(&dir).unwrap();
}
