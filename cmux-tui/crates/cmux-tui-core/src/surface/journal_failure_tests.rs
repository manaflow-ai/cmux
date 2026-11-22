//! A journal store failure is involuntary: a terminal reader that meets it
//! stops its own capture and must not take the user or app shutdown path.
//! That path begins a session shutdown, and a shell that dies by signal after
//! that mark is recorded as session_shutdown, which disables its respawn.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::{Mux, Surface, SurfaceOptions};

#[test]
fn terminal_journal_store_failure_does_not_request_the_daemon_shutdown() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-failure-no-shutdown-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = Mux::open_persistent("journal-failure-no-shutdown", SurfaceOptions::default(), &root)
        .unwrap();
    let database_path = std::fs::read_dir(&root)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("workspace-registry.sqlite3"))
        .find(|path| path.is_file())
        .expect("persistent journal database");
    let injector = rusqlite::Connection::open(database_path).unwrap();
    injector
        .execute_batch(
            "CREATE TRIGGER reject_all_terminal_output
             BEFORE INSERT ON session_journal
             WHEN NEW.kind = 'terminal.output'
             BEGIN
               SELECT RAISE(ABORT, 'injected store failure');
             END;",
        )
        .unwrap();
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().expect("terminal surface");

    // The first chunk fails the writer for good (a store error).
    pty.journal_output_if_open(pty.journal_target().expect("journal target"), b"first".to_vec());
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.flush_terminal_journal().is_ok() {
        assert!(Instant::now() < deadline, "the store failure never reached the writer");
        std::thread::sleep(Duration::from_millis(50));
    }
    // The next chunk meets the failed ingress.
    pty.journal_output_if_open(pty.journal_target().expect("journal target"), b"second".to_vec());

    assert!(
        !mux.daemon_shutdown_requested(),
        "an involuntary journal failure must not request the daemon (session) shutdown"
    );
    drop(surface);
    drop(injector);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
