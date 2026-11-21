//! The launch snapshot's byte budget. Each write is the whole file, and a
//! tab's notification or program status changes every few seconds in a busy
//! session: a 3.5 MB snapshot was written 7 times in 15 minutes, 23.5 MiB,
//! 12% of what the daemon wrote (2026-11-12). The writer now waits after a
//! write in proportion to the bytes it wrote, and a clean stop writes what
//! that wait held back.

use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

fn workspace_name(path: &Path) -> Option<String> {
    let snapshot: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    snapshot["tree"]["workspaces"][0]["name"].as_str().map(str::to_string)
}

fn wait_for(what: &str, accept: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !accept() {
        assert!(Instant::now() < deadline, "{what} never happened");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_large_launch_snapshot_is_rewritten_within_its_byte_budget() {
    let root = std::env::temp_dir().join(format!(
        "cmux-launch-snapshot-budget-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("launch-snapshot-budget", SurfaceOptions::default(), &root).unwrap();
    // 200 KB of window state stands in for the tree of a large session.
    run(
        &mux,
        json!({"cmd":"put-frontend-projection","frontend":"cmux-next","scope":"personal",
               "subject_key":"windows","schema_version":1,
               "projection":{"pad":"x".repeat(200_000)},
               "origin":"test","mutation_id":"budget-pad"}),
    );
    mux.create_empty_workspace(Some("budget".into()), None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    // 50 KB a second: a write of this snapshot buys the next one 4 s later.
    let rate: u64 = 50_000;
    let writer = start_launch_snapshot_writer_with(
        &mux,
        LaunchSnapshotTiming {
            settle: Duration::from_millis(20),
            max_delay: Duration::from_millis(100),
            max_bytes_per_second: rate,
        },
    )
    .unwrap()
    .unwrap();
    let path = writer.path().to_path_buf();
    wait_for("the first write", || writer.bytes_written() > 0);
    let size = std::fs::metadata(&path).unwrap().len();
    assert!(size >= 200_000, "the snapshot holds the window state: {size} bytes");

    // A change every 50 ms for 1.5 s, as a tab that reports its state does.
    let before = writer.bytes_written();
    let started = Instant::now();
    for index in 0..30 {
        mux.rename_workspace(workspace, format!("budget-{index}"));
        std::thread::sleep(Duration::from_millis(50));
    }
    let written = writer.bytes_written() - before;
    // The budget of the time that passed, and one whole write of slack.
    let budget = rate * (started.elapsed().as_secs() + 1) + size;
    assert!(
        written <= budget,
        "30 changes in {:?} wrote {written} bytes of a {size} byte snapshot (budget {budget} at \
         {rate} bytes a second): one whole file per change",
        started.elapsed()
    );

    // The last change still reaches the file once the budget allows it.
    wait_for("the write of the last change", || {
        workspace_name(&path).as_deref() == Some("budget-29")
    });
    // That write spent the budget again: a change now waits, and a clean stop writes it.
    mux.rename_workspace(workspace, "budget-final".to_string());
    writer.stop();
    assert_eq!(
        workspace_name(&path).as_deref(),
        Some("budget-final"),
        "a clean stop left the last change out of the snapshot"
    );

    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}
