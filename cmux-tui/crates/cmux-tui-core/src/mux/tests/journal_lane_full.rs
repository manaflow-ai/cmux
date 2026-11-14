//! A full terminal journal lane never stops a terminal (port of main #39865).
//!
//! A resize journals its accepted geometry while it holds the terminal's
//! geometry and parser locks. A wait for room in the terminal lane there has
//! no time limit, and the writer that makes room can wait behind a request
//! thread that needs the same geometry lock (the request holds the registry,
//! the registry connection and the state lock, then reads the terminal's
//! size). Those three threads then wait on each other for ever. So a
//! terminal-lane record is offered and never waited for: a refused record
//! leaves one `terminal.output.gap` marker (reason `journal_queue_full`)
//! ahead of the terminal's next record.

use super::*;
use std::sync::mpsc::sync_channel;

/// `JOURNAL_TERMINAL_QUEUE_CAPACITY` (journal_ingress.rs).
const TERMINAL_LANE_CAPACITY: u16 = 1024;

fn persistent_mux(name: &str) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-lane-full-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).unwrap();
    (mux, root)
}

/// A barrier through the terminal lane. One attempt has the short test
/// durability wait; a loaded machine can need more than one for a full lane.
fn flush_terminal_lane(mux: &Mux) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while let Err(error) = mux.flush_terminal_journal() {
        assert!(Instant::now() < deadline, "the terminal lane never drained: {error:#}");
    }
}

/// Every `terminal.resized` and `terminal.output.gap` record, in journal
/// order: (kind, payload).
fn geometry_and_gap_records(mux: &Mux) -> Vec<(String, Value)> {
    let mut found = Vec::new();
    let mut after = 0;
    loop {
        let page = mux.session_journal_after(after, 1024).unwrap();
        let Some(last) = page.records.last() else { break };
        after = last.sequence;
        found.extend(
            page.records
                .into_iter()
                .filter(|record| {
                    matches!(record.kind.as_str(), "terminal.resized" | "terminal.output.gap")
                })
                .map(|record| (record.kind, record.payload)),
        );
    }
    found
}

#[test]
fn a_resize_returns_while_the_terminal_journal_lane_is_full() {
    let (mux, root) = persistent_mux("resize");
    // No coalesced checkpoint in this test: the lane's records are its subject.
    let teardown = mux.begin_terminal_teardown();
    let surface =
        Surface::spawn_for_test(mux.next_id(), SurfaceOptions::default(), Arc::downgrade(&mux))
            .unwrap();
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    mux.install_journal_before_commit_for_test(entered, release_receiver);

    // The record of the first resize takes the writer into its commit, where
    // the hook holds it: the writer drains nothing more until the release.
    assert!(surface.resize(81, 24).unwrap());
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();

    let resizing = surface.clone();
    let (done, done_receiver) = sync_channel(1);
    let resizer = std::thread::spawn(move || {
        for index in 0..TERMINAL_LANE_CAPACITY + 256 {
            resizing.resize(82 + index % 2, 24).unwrap();
        }
        let _ = done.send(());
    });
    let returned = done_receiver.recv_timeout(Duration::from_secs(10)).is_ok();
    // Release on both outcomes, so a resize that waits for room ends and
    // frees the terminal's locks before the assertion.
    release.send(()).unwrap();
    resizer.join().unwrap();
    assert!(
        returned,
        "a resize waited for room in the full terminal journal lane while it held the \
         terminal's geometry and parser locks: with a writer that cannot drain, the terminal \
         and each request that reads its size stop for ever"
    );

    flush_terminal_lane(&mux);
    // The lane has room again: the terminal's next record follows the marker
    // for what the lane refused.
    assert!(surface.resize(132, 43).unwrap());
    flush_terminal_lane(&mux);
    let records = geometry_and_gap_records(&mux);
    let gap = records.iter().position(|(kind, payload)| {
        kind == "terminal.output.gap" && payload["reason"] == "journal_queue_full"
    });
    let last_resize = records.iter().rposition(|(kind, _)| kind == "terminal.resized");
    assert!(
        gap.is_some(),
        "the journal must say that the full lane refused geometry records: {:?}",
        records.iter().filter(|(kind, _)| kind == "terminal.output.gap").collect::<Vec<_>>()
    );
    assert!(gap < last_resize, "the marker goes ahead of the terminal's next record");
    let (_, payload) = &records[last_resize.unwrap()];
    assert_eq!(
        (payload["cols"].as_u64(), payload["rows"].as_u64()),
        (Some(132), Some(43)),
        "the geometry accepted after the lane drained is journaled"
    );
    assert!(
        records.iter().filter(|(kind, _)| kind == "terminal.resized").count()
            < usize::from(TERMINAL_LANE_CAPACITY) + 256,
        "the lane holds at most its capacity: the rest was refused, not waited for"
    );

    drop(teardown);
    drop(surface);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// JOURNAL STALL DESIGN (iv): the store rejects a geometry change every time, so the writer drops
/// it. Memory and disk must agree afterwards: the journal says a record is missing (a
/// `journal_commit_failed` marker ahead of the terminal's next record) and the next checkpoint
/// states the terminal's geometry from memory, the size the terminal really has.
#[test]
fn a_dropped_resize_leaves_a_marker_and_the_next_checkpoint_has_the_live_size() {
    let (mux, root) = persistent_mux("dropped-resize");
    // A workspace's terminal: the session snapshot (and so the checkpoint) names it. No coalesced
    // checkpoint runs meanwhile; the test takes its own.
    let surface = mux.new_workspace(None, None).unwrap();
    let teardown = mux.begin_terminal_teardown();
    flush_terminal_lane(&mux);
    let database = std::fs::read_dir(&root)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("workspace-registry.sqlite3"))
        .find(|path| path.is_file())
        .expect("persistent journal database");
    let injector = rusqlite::Connection::open(database).unwrap();
    injector
        .execute_batch(
            "CREATE TRIGGER reject_test_resize BEFORE INSERT ON session_journal
                 WHEN NEW.kind = 'terminal.resized'
                 BEGIN SELECT RAISE(ABORT, 'injected resize failure'); END;",
        )
        .unwrap();
    assert!(surface.resize(101, 31).unwrap());
    // The barrier behind the rejected record is answered once the writer dropped it.
    mux.flush_terminal_journal().expect("the barrier behind a dropped resize");
    injector.execute_batch("DROP TRIGGER reject_test_resize;").unwrap();

    let checkpoint = mux.create_journal_checkpoint("test", "after-dropped-resize").unwrap();
    // A checkpoint keeps no replay blob (journal_checkpoint.rs): its session snapshot states each
    // terminal's size, read from the live surface.
    let captured = checkpoint.checkpoint.state["session_snapshot"]["terminals"]
        .as_array()
        .expect("the checkpoint names its terminals")
        .iter()
        .map(|terminal| (terminal["cols"].as_u64(), terminal["rows"].as_u64()))
        .collect::<Vec<_>>();
    assert_eq!(captured, [(Some(101), Some(31))], "the checkpoint has the terminal's live size");

    assert!(surface.resize(102, 32).unwrap());
    flush_terminal_lane(&mux);
    let records = geometry_and_gap_records(&mux);
    let marker = records.iter().position(|(kind, payload)| {
        kind == "terminal.output.gap" && payload["reason"] == "journal_commit_failed"
    });
    let next = records.iter().rposition(|(kind, payload)| {
        kind == "terminal.resized" && payload["cols"].as_u64() == Some(102)
    });
    assert!(marker.is_some(), "the journal says a record was dropped: {records:?}");
    assert!(marker < next, "the marker goes ahead of the terminal's next record: {records:?}");
    assert!(
        !records.iter().any(|(kind, payload)| {
            kind == "terminal.resized" && payload["cols"].as_u64() == Some(101)
        }),
        "the rejected resize was not committed"
    );
    drop(injector);
    drop(teardown);
    drop(surface);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// JOURNAL STALL DESIGN (5): while one journal commit is stalled (held inside its transaction, past
/// its deadline), the terminal's input and output do not wait for it. The writer holds only the
/// registry connection lock; terminal input and output take neither that lock nor the writer.
#[test]
fn a_stalled_journal_commit_does_not_block_terminal_input_or_output() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-stall-io-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let options =
        SurfaceOptions { command: Some(vec!["/bin/cat".into()]), ..SurfaceOptions::default() };
    let mux = Mux::open_persistent("journal-stall-io", options, &root).unwrap();
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, None).unwrap();
    flush_terminal_lane(&mux);
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    mux.install_journal_before_commit_for_test(entered, release_receiver);
    // A geometry record takes the writer into its commit, where the hook holds it.
    assert!(surface.resize(90, 30).unwrap());
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    while events.try_recv().is_ok() {}

    surface.write_bytes(b"typed while the journal is stalled\n").unwrap();
    let mut echoed = false;
    while let Ok(event) = events.recv_timeout(Duration::from_secs(10)) {
        if matches!(event, MuxEvent::SurfaceOutput(id) if id == surface.id) {
            echoed = true;
            break;
        }
    }
    release.send(()).unwrap();
    assert!(echoed, "terminal input or output waited for the stalled journal commit");
    flush_terminal_lane(&mux);
    drop(surface);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}
