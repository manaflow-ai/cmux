//! Lock order of the session journal writer against request threads.
//!
//! Lock order: workspace registry -> registry connection -> state. The
//! journal writer takes only the connection lock, so terminal output keeps
//! committing while a request thread holds the registry, and a writer commit
//! (with its fsync) never holds the registry or state lock.

use super::*;
use std::sync::mpsc::sync_channel;

fn persistent_mux(name: &str) -> (Arc<Mux>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cmux-writer-lock-order-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent(name, SurfaceOptions::default(), &root).unwrap();
    (mux, root)
}

fn terminal_outputs(mux: &Mux) -> Vec<Vec<u8>> {
    mux.session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "terminal.output")
        .filter_map(|record| record.terminal_output.map(|bytes| bytes.to_vec()))
        .collect()
}

#[test]
fn terminal_output_commits_while_a_request_thread_holds_the_workspace_registry() {
    let (mux, root) = persistent_mux("registry-held");
    let locked_mux = mux.clone();
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    let holder = std::thread::spawn(move || {
        locked_mux.hold_workspace_registry_for_test(entered, release_receiver);
    });
    entered_receiver.recv().unwrap();

    let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 41)).unwrap());
    mux.journal_terminal_output(
        terminal_id,
        Arc::from("registry-held-generation"),
        b"output while a request holds the registry".to_vec(),
    );
    let flushing_mux = mux.clone();
    let (flushed, flushed_receiver) = sync_channel(1);
    let flusher = std::thread::spawn(move || {
        flushed.send(flushing_mux.flush_terminal_journal().map_err(|e| e.to_string())).unwrap();
    });
    let flush = flushed_receiver.recv_timeout(Duration::from_secs(10));
    release.send(()).unwrap();
    holder.join().unwrap();
    flusher.join().unwrap();

    assert!(
        matches!(flush, Ok(Ok(()))),
        "terminal output must become durable while a request thread holds the workspace \
         registry (the journal writer must not take the registry lock): {flush:?}"
    );
    assert!(
        terminal_outputs(&mux)
            .iter()
            .any(|bytes| &bytes[..] == b"output while a request holds the registry"),
        "the flushed output must be in the journal"
    );
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_journal_writer_commit_holds_neither_the_registry_nor_the_state_lock() {
    let (mux, root) = persistent_mux("writer-paused");
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    mux.install_journal_before_commit_for_test(entered, release_receiver);

    let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 42)).unwrap());
    mux.journal_terminal_output(
        terminal_id,
        Arc::from("writer-paused-generation"),
        b"output in a paused writer commit".to_vec(),
    );
    // The writer is now inside its batch transaction, before the commit
    // (the fsync point), holding whatever locks a commit holds.
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    let registry_free = mux.workspace_registry.try_lock().is_ok();
    let state_free = mux.state.try_lock().is_ok();
    let connection_held = mux.registry_connection.try_get().is_none();
    release.send(()).unwrap();
    mux.flush_terminal_journal().unwrap();

    assert!(
        registry_free,
        "a journal writer commit must not hold the workspace registry lock: registry users \
         that do not need the database wait behind every terminal output batch otherwise"
    );
    assert!(state_free, "a journal writer commit must not hold the state lock");
    assert!(connection_held, "a journal writer commit holds the registry connection lock");
    assert!(
        terminal_outputs(&mux)
            .iter()
            .any(|bytes| &bytes[..] == b"output in a paused writer commit"),
        "the paused batch must commit after release"
    );
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn a_request_waiting_behind_a_writer_commit_does_not_hold_state() {
    let (mux, root) = persistent_mux("pinned-state");
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    mux.install_journal_before_commit_for_test(entered, release_receiver);
    let terminal_id = Arc::new(TerminalPublicId::parse(format!("term_{:032x}", 43)).unwrap());
    mux.journal_terminal_output(
        terminal_id,
        Arc::from("pinned-state-generation"),
        b"output that pauses the writer".to_vec(),
    );
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();

    // A projection flow takes registry, then the connection, then state; its
    // database read waits for the paused writer commit.
    let projecting_mux = mux.clone();
    let projector = std::thread::spawn(move || {
        projecting_mux
            .with_resource_projection(|registry, _state| registry.session_journal_head())
            .unwrap()
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.workspace_registry.try_lock().is_ok() {
        assert!(Instant::now() < deadline, "the projection flow never took the registry");
        std::thread::yield_now();
    }
    // One free probe is enough: the pinned flow never takes state while it
    // waits, while an unpinned flow would hold state for the whole wait.
    let mut state_free = false;
    for _ in 0..20 {
        state_free |= mux.state.try_lock().is_ok();
        std::thread::sleep(Duration::from_millis(10));
    }
    release.send(()).unwrap();
    projector.join().unwrap();
    mux.flush_terminal_journal().unwrap();

    assert!(
        state_free,
        "a request flow that waits behind a writer commit must not hold the state lock \
         (lock order: registry -> connection -> state)"
    );
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A late answer to an indeterminate registry commit is settled by the next
/// request that pins state (cx-g1fa.3). Settling ran publish_resource_event
/// under the registry and state, and that publication locks state again to
/// publish pending terminal directories: a self-deadlock in release builds
/// (std's mutex) and a lock-rank panic in debug. The pin must return.
#[test]
fn settling_a_late_registry_receipt_does_not_relock_state() {
    let mux = test_mux();
    let (answer, pending) = crate::journal_ingress::PendingRegistryReceipt::for_test();
    let settled = Arc::new(AtomicBool::new(false));
    let settled_by = settled.clone();
    mux.workspace_registry.lock().unwrap().connection.hold_unsettled_for_test(
        pending,
        Some(Box::new(move |_state, _receipt| {
            settled_by.store(true, Ordering::SeqCst);
        })),
    );
    answer
        .send(Ok(crate::workspace_registry::RegistryReceipt::Terminal(
            crate::workspace_registry::TerminalRegistryCommit {
                revision: 1,
                result: serde_json::json!({}),
                replayed: false,
            },
        )))
        .unwrap();

    let (done, finished) = std::sync::mpsc::channel();
    let pinning = mux;
    std::thread::spawn(move || {
        let registry = pinning.workspace_registry.lock().unwrap();
        let state = pinning.lock_state_pinned(&registry).unwrap();
        drop(state);
        drop(registry);
        let _ = done.send(());
    });
    assert_eq!(
        finished.recv_timeout(Duration::from_secs(5)),
        Ok(()),
        "pinning state to settle a late receipt deadlocked or panicked"
    );
    assert!(settled.load(Ordering::SeqCst), "the owed state update ran");
}

/// A rename's registry commit rides the journal writer batch. The request
/// held the mux state lock across that receipt wait (up to the 30 s durable
/// wait), so every state reader (list-workspaces, identify, terminal I/O
/// placement) queued behind the disk. State must be free while it waits.
#[test]
fn a_rename_waiting_for_its_writer_receipt_does_not_hold_state() {
    let (mux, root) = persistent_mux("rename-receipt");
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    mux.flush_terminal_journal().unwrap();
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    mux.install_journal_before_commit_for_test(entered, release_receiver);

    let renaming_mux = mux.clone();
    let renamer = std::thread::spawn(move || {
        renaming_mux.rename_workspace_at_revision(workspace, "renamed under load".into(), None)
    });
    // The writer is paused inside a batch, and the rename (registry held)
    // waits for the receipt of the batch that carries it.
    entered_receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.workspace_registry.try_lock().is_ok() {
        assert!(Instant::now() < deadline, "the rename never took the registry");
        std::thread::yield_now();
    }
    std::thread::sleep(Duration::from_millis(50));
    let old_name = mux.with_state(|state| state.workspaces[0].name.clone());
    let mut state_free = false;
    let mut names_seen_while_waiting = Vec::new();
    for _ in 0..20 {
        if let Ok(state) = mux.state.try_lock() {
            state_free = true;
            names_seen_while_waiting.push(state.workspaces[0].name.clone());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!renamer.is_finished(), "the rename replied before its commit was durable");
    release.send(()).unwrap();
    let renamed = renamer.join().unwrap();
    // Other readers may see the old name only while the rename waits for
    // durability; the rename's own reply comes after the new name is in
    // state, so a caller that renames and then lists sees the new name.
    assert!(
        names_seen_while_waiting.iter().all(|name| *name == old_name),
        "readers saw a name the journal had not made durable: {names_seen_while_waiting:?}"
    );

    assert!(
        state_free,
        "a request that waits for its journal writer receipt must not hold the state lock"
    );
    assert!(renamed.unwrap().is_some(), "the rename committed");
    assert_eq!(
        mux.with_state(|state| state.workspaces[0].name.clone()),
        "renamed under load",
        "the committed name is in state after the receipt"
    );
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A request that finds an earlier commit still unanswered waits for its
/// answer before it builds on it (cx-g1fa.3). It waited with the registry
/// connection pinned: the journal writer needs that connection to commit
/// and answer, so the wait could only run out (2 s) and fail the request.
/// The connection must stay free while a request waits for that answer.
#[test]
fn waiting_for_an_earlier_indeterminate_commit_leaves_the_connection_free() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let (answer, pending) = crate::journal_ingress::PendingRegistryReceipt::for_test();
    mux.workspace_registry.lock().unwrap().connection.hold_unsettled_for_test(pending, None);

    let renaming_mux = mux.clone();
    let renamer = std::thread::spawn(move || {
        renaming_mux.rename_workspace_at_revision(workspace, "after the late answer".into(), None)
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.workspace_registry.try_lock().is_ok() {
        assert!(Instant::now() < deadline, "the rename never took the registry");
        std::thread::yield_now();
    }
    // The rename is now waiting for the unanswered commit (2 s bound).
    std::thread::sleep(Duration::from_millis(100));
    let mut connection_free = true;
    for _ in 0..20 {
        connection_free &= mux.registry_connection.try_get().is_some();
        std::thread::sleep(Duration::from_millis(10));
    }
    answer
        .send(Ok(crate::workspace_registry::RegistryReceipt::Terminal(
            crate::workspace_registry::TerminalRegistryCommit {
                revision: 1,
                result: serde_json::json!({}),
                replayed: false,
            },
        )))
        .unwrap();
    let renamed = renamer.join().unwrap();

    assert!(
        connection_free,
        "a request waiting for an earlier commit's answer must not hold the registry \
         connection: the journal writer needs it to answer"
    );
    assert!(renamed.unwrap().is_some(), "the rename committed after the late answer");
}

/// A pinned request settles the late answers that arrived when it pinned.
/// An answer that arrives after that settle (the writer drops the
/// connection, then sends its receipts) is not in the request's state: a
/// prepare that builds on it would write over the late commit (a late
/// rename is lost). The pinned prepare must refuse; the next pin settles it.
#[test]
fn a_pinned_prepare_refuses_a_commit_that_landed_after_its_settle() {
    let mux = test_mux();
    let registry = mux.workspace_registry.lock().unwrap();
    let (answer, pending) = crate::journal_ingress::PendingRegistryReceipt::for_test();
    registry.connection.hold_unsettled_for_test(pending, None);
    let state = mux.lock_state_pinned(&registry).unwrap();
    answer
        .send(Ok(crate::workspace_registry::RegistryReceipt::Terminal(
            crate::workspace_registry::TerminalRegistryCommit {
                revision: 1,
                result: serde_json::json!({}),
                replayed: false,
            },
        )))
        .unwrap();
    let refused = registry.connection.drain_unsettled();
    drop(state);
    assert!(refused.is_err(), "a pinned prepare built on a commit its state does not hold");

    let state = mux.lock_state_pinned(&registry).unwrap();
    let settled = registry.connection.drain_unsettled();
    drop(state);
    drop(registry);
    assert!(settled.is_ok(), "the next pin settles the late answer: {settled:?}");
}
