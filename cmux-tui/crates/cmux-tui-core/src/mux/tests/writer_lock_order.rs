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
