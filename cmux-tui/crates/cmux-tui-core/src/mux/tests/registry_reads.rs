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

/// A terminal's progress report (OSC 9;4, program status) republishes that
/// one terminal. It read the whole session topology (every screen, pane,
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
