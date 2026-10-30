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

    let read = read.lock().unwrap().clone();
    for table in ["resource_screens", "resource_panes", "resource_workspaces"] {
        assert!(!read.contains(table), "a progress report read {table}: {read:?}");
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

/// A tool call that completes while its agent is working changes no
/// projection (about half of an agent's hooks). Its ingress still took the
/// workspace registry lock twice after the journal commit: to clear its
/// retry row (`journal.rs:613`, 5.5 % of the registry hold on Austin's
/// day) and to read the journal tail for the roster fold
/// (`agent_roster_fold.rs:253`, 3 %). Neither needs the registry: the
/// retry row is keyed by the hook's own receipt, and the tail is committed
/// data. Such a hook must complete while another thread holds the registry.
#[test]
fn a_hook_that_changes_no_projection_takes_no_registry_lock() {
    let session = "hook-no-registry";
    let root = std::env::temp_dir()
        .join(format!("cmux-hook-no-registry-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("hook-no-registry"));
    append_journal_hook(&mux, &terminal_id, "UserPromptSubmit", Some("hook-no-registry"));

    let held = mux.workspace_registry.lock().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let hooking = mux.clone();
    let terminal = terminal_id.clone();
    std::thread::spawn(move || {
        append_journal_hook(&hooking, &terminal, "PostToolUse", Some("hook-no-registry"));
        let _ = tx.send(());
    });
    let done = rx.recv_timeout(Duration::from_secs(5));
    drop(held);
    assert!(done.is_ok(), "a hook that changes no projection waited for the registry lock");
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}

/// The live roster fold reads the committed journal tail without the
/// registry lock (1e). Another agent event commits between the fold's read
/// and its apply (forced at the fold's test seam). The fold must neither
/// skip nor repeat a record: after every fold, the roster equals a fresh
/// replay of the whole journal.
#[test]
fn a_live_roster_fold_with_an_interleaved_append_equals_a_fresh_replay() {
    interleaved_fold_equals_replay("fold-interleave", 0);
}

/// The same with one record per tail page: the fold spans several pages,
/// the interleaved append commits between two page reads, and a page edge
/// must neither skip nor repeat a record (the fold stops at its own
/// committed sequence, not at the newer one).
#[test]
fn a_roster_fold_over_several_pages_with_an_append_between_pages_equals_a_fresh_replay() {
    interleaved_fold_equals_replay("fold-pages", 1);
}

fn interleaved_fold_equals_replay(session: &str, page: usize) {
    use crate::journal_reducers::{AgentRoster, RosterEvent};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    let root = std::env::temp_dir()
        .join(format!("cmux-fold-interleave-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let first = mux.new_workspace(None, None).unwrap();
    let second = mux.new_workspace(None, None).unwrap();
    let first_id = first.terminal_public_id().cloned().unwrap();
    let second_id = second.terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &first_id, "SessionStart", Some("fold-a"));
    append_journal_hook(&mux, &second_id, "SessionStart", Some("fold-b"));

    let records_of = |terminal: &TerminalPublicId| -> i64 {
        let pattern = format!("%{}%", terminal.as_str());
        mux.registry_connection
            .read_committed(|connection| {
                Ok(connection.query_row(
                    "SELECT COUNT(*) FROM session_journal WHERE subjects_json LIKE ?1",
                    [pattern.as_str()],
                    |row| row.get::<_, i64>(0),
                )?)
            })
            .expect("a persistent registry has a reader")
            .unwrap()
    };
    mux.agent_roster_fold_page.store(page, Ordering::Relaxed);
    let fired = Arc::new(AtomicBool::new(false));
    let page_reads = Arc::new(AtomicUsize::new(0));
    let (spawned_tx, spawned_rx) = std::sync::mpsc::channel();
    {
        let fired = fired.clone();
        let page_reads = page_reads.clone();
        let hook_mux = Arc::downgrade(&mux);
        let second_id = second_id.clone();
        *mux.agent_roster_fold_after_read.lock().unwrap() = Some(Arc::new(move || {
            page_reads.fetch_add(1, Ordering::SeqCst);
            if fired.swap(true, Ordering::SeqCst) {
                return;
            }
            let Some(mux) = hook_mux.upgrade() else { return };
            // Commit another agent's event now, between this fold's read and
            // its apply; wait (on the journal commit signal) until it is
            // committed.
            let pattern = format!("%{}%", second_id.as_str());
            let count = || -> i64 {
                mux.registry_connection
                    .read_committed(|connection| {
                        Ok(connection.query_row(
                            "SELECT COUNT(*) FROM session_journal WHERE subjects_json LIKE ?1",
                            [pattern.as_str()],
                            |row| row.get::<_, i64>(0),
                        )?)
                    })
                    .unwrap()
                    .unwrap()
            };
            let before = count();
            let appending = mux.clone();
            let terminal = second_id.clone();
            let thread = std::thread::spawn(move || {
                append_journal_hook(&appending, &terminal, "UserPromptSubmit", Some("fold-b"));
            });
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut epoch = mux.journal_event_epoch.lock().unwrap();
            while count() == before {
                let left = deadline.saturating_duration_since(Instant::now());
                assert!(!left.is_zero(), "the interleaved append never committed");
                epoch = mux.journal_event_changed.wait_timeout(epoch, left).unwrap().0;
            }
            drop(epoch);
            let _ = spawned_tx.send(thread);
        }));
    }

    // A backlog the next agent fold must consume: workspace renames commit
    // public journal records that no agent event folds until then.
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    for name in ["one", "two", "three"] {
        assert!(mux.rename_workspace(workspace, name.into()));
    }
    let before_second = records_of(&second_id);
    page_reads.store(0, Ordering::SeqCst);
    append_journal_hook(&mux, &first_id, "UserPromptSubmit", Some("fold-a"));
    assert!(fired.load(Ordering::SeqCst), "the live fold reached its seam");
    if page == 1 {
        assert!(
            page_reads.load(Ordering::SeqCst) >= 3,
            "the fold read fewer than 3 one-record pages: {}",
            page_reads.load(Ordering::SeqCst)
        );
    }
    spawned_rx.recv_timeout(Duration::from_secs(10)).unwrap().join().unwrap();
    assert!(records_of(&second_id) > before_second, "the interleaved event is committed");
    *mux.agent_roster_fold_after_read.lock().unwrap() = None;
    mux.catch_up_agent_roster();

    let head = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    let mut fresh = AgentRoster::default();
    let mut cursor = 0;
    while cursor < head {
        let (records, reached) = mux
            .workspace_registry
            .lock()
            .unwrap()
            .session_journal_without_output_after(cursor, head, 512)
            .unwrap();
        for record in &records {
            fresh.apply(&RosterEvent::from_record(record));
        }
        if reached <= cursor {
            break;
        }
        cursor = reached;
    }
    let live = mux.agent_roster.lock().unwrap();
    assert_eq!(live.cursor, head, "the live roster folded through the journal head");
    assert_eq!(
        live.roster.snapshot(),
        fresh.snapshot(),
        "the live fold skipped or repeated a record"
    );
    drop(live);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
