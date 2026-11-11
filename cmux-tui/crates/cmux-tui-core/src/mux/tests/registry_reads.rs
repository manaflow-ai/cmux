//! Point reads that need no registry lock (#27698 lock work, design step 1).
//! On an 80-agent load the registry lock is held about 78 % of the time;
//! a read that queues behind it waits for writes it does not depend on.

use std::collections::BTreeSet;
use std::sync::Mutex;

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};

use super::*;

fn persistent_mux(name: &str) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-registry-reads-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).unwrap();
    (mux, root)
}

/// `identify` and every `list-workspaces` reply read the terminal registry
/// revision (`frontend_projection.rs:9`, 151,415 registry acquisitions in
/// 9 Austin's-day runs, mean hold 1.7 ms). It is one committed value: the
/// read must not wait for the registry lock that a write holds.
#[test]
fn the_terminal_revision_read_does_not_wait_for_the_registry_lock() {
    let (mux, root) = persistent_mux("terminal-revision");
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let expected = mux.terminal_registry_revision().unwrap();

    let held = mux.workspace_registry.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = mux.clone();
    std::thread::spawn(move || {
        let _ = tx.send(reader.terminal_registry_revision().ok());
    });
    let read = rx.recv_timeout(Duration::from_secs(5));
    drop(held);
    assert_eq!(
        read.ok(),
        Some(Some(expected)),
        "the terminal revision read waited for the held registry lock"
    );
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// A terminal's durable edge (a command, a prompt, a program status record's
/// state or kind) republishes that one terminal with one commit; an OSC 9;4
/// progress or a repeated report commits nothing (`terminal_live.rs`). The
/// commit read the whole session topology (every screen, pane,
/// tab and browser) under the registry lock to find the terminal's own
/// tabs (`terminal_progress.rs:18`: 9.6 % of the registry hold time on
/// Austin's day, mean 5.4 ms, max 2 s).
#[test]
fn a_progress_report_reads_only_its_own_terminals_tabs() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    for _ in 0..3 {
        mux.new_workspace(None, Some((80, 24))).unwrap();
    }
    let revision_before = mux.with_state(|state| state.resource_revision);
    let read = Arc::new(Mutex::new(BTreeSet::<String>::new()));
    let sink = read.clone();
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            if let AuthAction::Read { table_name, .. } = context.action {
                sink.lock().unwrap().insert(table_name.to_owned());
            }
            Authorization::Allow
        }))
        .unwrap();
    let published = mux.publish_terminal_progress(&surface, "terminal.progress.test");
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    published.unwrap();
    assert!(
        mux.with_state(|state| state.resource_revision) > revision_before,
        "the progress report published a revision (the terminal is live and running)"
    );

    // The commit itself (any resource patch, even an empty one) looks up
    // rows of screens, panes and workspaces; only a whole-topology load
    // reads the side tables of every screen. Those mark the full read.
    let read = read.lock().unwrap().clone();
    for table in [
        "resource_screen_rows",
        "resource_column_docks",
        "resource_lone_docks",
        "resource_parked_splits",
    ] {
        assert!(
            !read.contains(table),
            "a progress report loaded the whole topology ({table}): {read:?}"
        );
    }
}

/// The read-only connection reads the last committed state. While a writer
/// has an open transaction that changed the revision, a read returns the
/// committed value, never the uncommitted one, and it does not wait for the
/// transaction (SQLite WAL: a reader sees the snapshot at its start and is
/// never blocked by the writer). After the commit it returns the new value.
#[test]
fn a_committed_read_during_an_open_write_transaction_sees_only_committed_data() {
    let (mux, root) = persistent_mux("read-during-write");
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let committed = mux.terminal_registry_revision().unwrap();

    let connection = mux.registry_connection.get();
    let transaction = connection.unchecked_transaction().unwrap();
    transaction
        .execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [(committed + 1000).to_string()],
        )
        .unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = mux.clone();
    std::thread::spawn(move || {
        let _ = tx.send(
            reader
                .registry_connection
                .read_committed(crate::workspace_registry::current_terminal_revision),
        );
    });
    let during = rx.recv_timeout(Duration::from_secs(5));
    transaction.commit().unwrap();
    drop(connection);

    let during = during.expect("a committed read waited for the open write transaction");
    assert_eq!(
        during.map(Result::unwrap),
        Some(committed),
        "a committed read returned uncommitted data or no reader exists"
    );
    assert_eq!(mux.terminal_registry_revision().unwrap(), committed + 1000, "the commit is read");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// TUL-F7 (TYPING UNDER LOAD, STATUS 6453): under L6 a terminal's
/// progress reports (OSC 9;4 from the TUI panes, 8,964 in 187 s) held the
/// session lock across their registry commit: 18 s of session lock hold,
/// max 198 ms. A progress report reads the session only for its terminal's
/// runtime; a key's session lookup must not wait for its registry write.
#[test]
fn a_progress_report_frees_the_session_lock_while_it_writes_the_registry() {
    use std::sync::mpsc::sync_channel;
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (entered, entered_receiver) = sync_channel::<()>(1);
    let (release, release_receiver) = sync_channel::<()>(1);
    let release_receiver = Mutex::new(release_receiver);
    mux.set_state_commit_after_apply_hook_for_test(Some(Arc::new(move || {
        entered.send(()).unwrap();
        let _ = release_receiver.lock().unwrap().recv_timeout(Duration::from_secs(10));
    })));
    let publishing = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.publish_terminal_progress(&surface, "terminal.progress.test")
                .map_err(|error| error.to_string())
        })
    };
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    let (looked_up, looked_up_receiver) = sync_channel::<()>(1);
    let key = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.with_state(|state| state.surfaces.len());
            looked_up.send(()).unwrap();
        })
    };
    let waited = looked_up_receiver.recv_timeout(Duration::from_secs(2));
    release.send(()).unwrap();
    let published = publishing.join().unwrap();
    key.join().unwrap();
    mux.set_state_commit_after_apply_hook_for_test(None);
    assert!(waited.is_ok(), "a key's session lookup waited for a progress report's registry write");
    published.unwrap();
}

/// #32408: a progress report published with the registry connection still pinned. Its last step,
/// `publish_resource_event`, publishes every terminal's pending working directory, which takes the
/// workspace registry: a connection -> registry acquisition, against the order registry -> connection.
/// On a 512-workspace classic upgrade a shell's progress report held the connection waiting for the
/// registry while the app's window-record commit held the registry waiting for the connection: the
/// daemon stopped answering (fleet step e8529d2ce806772390e184ec). Here a second terminal has a
/// directory pending when the first one's progress publishes: the directory publish must run with no
/// registry connection held (debug builds check the lock order and panic otherwise).
#[test]
fn a_progress_report_publishes_pending_directories_after_it_releases_the_connection() {
    let mux = test_mux();
    let reporting = mux.new_workspace(None, Some((80, 24))).unwrap();
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    other.set_test_pwd(Some(format!("file://localhost{}", std::env::temp_dir().display())));
    let published = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mux.publish_terminal_progress(&reporting, "terminal.progress.test")
                    .map_err(|error| error.to_string())
            }))
            .map_err(|panic| {
                panic
                    .downcast_ref::<String>()
                    .cloned()
                    .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                    .unwrap_or_default()
            })
        })
        .join()
        .unwrap()
    };
    let published = published.unwrap_or_else(|panic| {
        panic!("the progress report's directory publish broke the lock order: {panic}")
    });
    published.unwrap();
    assert!(
        !mux.registry_connection.is_held_by_current_thread(),
        "the progress report left the registry connection held"
    );
}

/// CLI-1 / TUL-F7 (STATUS 6838): under the L1 storm a state commit held the
/// registry lock up to 281 ms, and `workspace.list`, `session.ping` and the
/// scoped pane and tab lists read committed rows only but queued behind it.
/// They read the registry's read-only WAL connection: no registry lock, no
/// wait for a writer, and the same values as under the lock.
#[test]
fn list_reads_answer_while_a_writer_holds_the_registry_lock() {
    use std::sync::mpsc::sync_channel;
    let (mux, root) = persistent_mux("lists-read-committed");
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let (pane, workspace) = mux.with_state(|state| {
        let pane = state.pane_of(first.id).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        (
            state.resource_indexes.pane_ids.get(&pane).unwrap().to_string(),
            state.workspaces[workspace].public_id.to_string(),
        )
    });
    let call = |mux: &Arc<Mux>, operation: &str, params: Value| {
        let mut params = params;
        params["machine"] = serde_json::json!("current");
        params["session"] = serde_json::json!("current");
        let envelope = serde_json::json!({"protocol":"cmux.protocol/2","type":"request",
            "id":operation,"operation":operation,"params":params});
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap()
    };
    let reads = [
        ("workspace.list", serde_json::json!({"order": "session"})),
        ("session.ping", serde_json::json!({})),
        ("tab.list", serde_json::json!({"pane": pane})),
        ("pane.list", serde_json::json!({"workspace": workspace})),
    ];
    let expected = reads
        .iter()
        .map(|(operation, params)| call(&mux, operation, params.clone())["result"].clone())
        .collect::<Vec<_>>();

    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.hold_workspace_registry_for_test(entered, release_receiver))
    };
    entered_receiver.recv().unwrap();
    // No writer can commit while the registry lock is held.
    let held_revision = mux
        .registry_connection
        .read_committed(|connection| {
            let value: String = connection.query_row(
                "SELECT value FROM meta WHERE key = 'resource_revision'",
                [],
                |row| row.get(0),
            )?;
            Ok(value.parse::<u64>()?)
        })
        .expect("a file registry has a reader")
        .unwrap();
    let (answered, answered_receiver) = std::sync::mpsc::channel();
    let reader = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            for (operation, params) in reads {
                let response = call(&mux, operation, params);
                answered.send((operation, response)).unwrap();
            }
        })
    };
    let mut during = Vec::new();
    for _ in 0..4 {
        match answered_receiver.recv_timeout(Duration::from_secs(2)) {
            Ok(answer) => during.push(answer),
            Err(_) => break,
        }
    }
    release.send(()).unwrap();
    holder.join().unwrap();
    reader.join().unwrap();
    assert_eq!(during.len(), 4, "a list read waited for the registry lock: answered {during:?}");
    // The shells keep committing (directory, progress) until the hold, so
    // compare what those commits do not change: the listed ids, and the
    // ping's generation; its revision is the one committed at the hold.
    let ids = |value: &Value| {
        value
            .as_array()
            .map(|rows| rows.iter().map(|row| row["id"].clone()).collect::<Vec<_>>())
            .unwrap_or_default()
    };
    for ((operation, response), expected) in during.iter().zip(&expected) {
        assert_eq!(response["ok"], true, "{operation}: {response}");
        if *operation == "session.ping" {
            assert_eq!(
                response["result"]["cursor"]["generation"], expected["cursor"]["generation"],
                "{operation}: {response}"
            );
            assert_eq!(
                response["result"]["cursor"]["revision"].as_str().map(str::to_owned),
                Some(held_revision.to_string()),
                "{operation} read the revision committed at the hold"
            );
        } else {
            assert!(!ids(expected).is_empty(), "{operation} lists rows");
            assert_eq!(ids(&response["result"]), ids(expected), "{operation} listed the same rows");
        }
    }
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// Review of #32326: a progress publish that drops the session lock early
/// must keep the registry connection pinned until its commit, or the
/// journal writer (which takes only the connection) can commit between
/// the publish's registry reads and its commit.
#[test]
fn a_progress_report_keeps_the_registry_connection_until_its_commit() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let held = Arc::new(Mutex::new(None));
    let probe = {
        let mux = Arc::downgrade(&mux);
        let held = held.clone();
        Arc::new(move || {
            let Some(mux) = mux.upgrade() else { return };
            let free = std::thread::scope(|scope| {
                scope.spawn(|| mux.registry_connection.try_get().is_some()).join().unwrap()
            });
            *held.lock().unwrap() = Some(!free);
        })
    };
    mux.set_state_commit_after_apply_hook_for_test(Some(probe));
    let published = mux.publish_terminal_progress(&surface, "terminal.progress.test");
    mux.set_state_commit_after_apply_hook_for_test(None);
    published.unwrap();
    assert_eq!(
        *held.lock().unwrap(),
        Some(true),
        "another thread could take the registry connection between the publish's reads and its commit"
    );
}
