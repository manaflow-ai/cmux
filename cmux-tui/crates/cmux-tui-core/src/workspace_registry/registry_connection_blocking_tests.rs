//! The registry connection as a checked scope: a thread that disallows
//! blocking records its registry reads at the caller (`cmux_threads::blocking`),
//! a re-entry is not checked again, and a connection-lock wait over the budget
//! is recorded with the holder's thread name (`cmux_threads::lock_waits`).
//! Panic mode is process-wide: tests/registry_blocking_panic.rs.
//!
//! The `sqlite` notes are counted in a recording request scope of the test
//! thread's own, so no other thread can add to them; the process-wide site
//! table is checked only for the `sqlite` kind.

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_threads::blocking::{BlockingKind, BlockingMode, disallow_blocking, set_mode, snapshot};

use crate::WorkspaceRegistry;
use crate::request_path::{
    BlockingKind as NoteKind, RequestPathMode, RequestPathScope, RequestPathStats,
};

fn registry(name: &str) -> WorkspaceRegistry {
    WorkspaceRegistry::in_memory(name).expect("registry")
}

/// The `sqlite` notes the scope recorded at `line` of this file.
fn sqlite_notes_at(stats: &RequestPathStats, line: u32) -> usize {
    stats
        .sites()
        .iter()
        .filter(|noted| {
            noted.kind == NoteKind::Sqlite
                && noted.site.file() == file!()
                && noted.site.line() == line
        })
        .count()
}

/// Whether the blocking detector recorded a `sqlite` violation at `line`.
fn sqlite_violation_at(line: u32) -> bool {
    snapshot().site(file!(), line).is_some_and(|site| site.kinds.contains(BlockingKind::Sqlite))
}

/// Runs `f` on a thread named `name`, in a recording request scope, and
/// returns what it returns with that scope's stats.
fn on_thread<R: Send + 'static>(
    name: &str,
    disallow: bool,
    f: impl FnOnce() -> R + Send + 'static,
) -> (R, Arc<RequestPathStats>) {
    set_mode(BlockingMode::Record);
    let stats = RequestPathStats::new(RequestPathMode::RECORD);
    let scope_stats = Arc::clone(&stats);
    let result = std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            if disallow {
                disallow_blocking();
            }
            let _scope = RequestPathScope::enter(&scope_stats);
            f()
        })
        .expect("spawn")
        .join()
        .expect("test thread");
    (result, stats)
}

#[test]
fn a_disallowed_registry_read_records_one_sqlite_site_at_its_caller() {
    let registry = registry("blocking-disallowed-read");
    let (line, stats) = on_thread("mux-conn-blocking-test", true, move || {
        let line = line!() + 1;
        registry.terminal_revision().expect("terminal revision");
        line
    });
    assert_eq!(sqlite_notes_at(&stats, line), 1);
    assert!(sqlite_violation_at(line));
}

#[test]
fn an_allowed_registry_read_records_nothing() {
    let registry = registry("blocking-allowed-read");
    let (line, stats) = on_thread("registry-allowed-test", false, move || {
        let line = line!() + 1;
        registry.terminal_revision().expect("terminal revision");
        line
    });
    assert_eq!(sqlite_notes_at(&stats, line), 1, "counted on the request path");
    assert_eq!(snapshot().site(file!(), line), None, "no violation where blocking is allowed");
}

#[test]
fn a_reentry_is_not_checked_again() {
    let registry = registry("blocking-reentry");
    let ((pin_line, read_line), stats) = on_thread("mux-conn-reentry-test", true, move || {
        let pin_line = line!() + 1;
        let pin = registry.connection.pin();
        let read_line = line!() + 1;
        registry.terminal_revision().expect("terminal revision under the pin");
        drop(pin);
        (pin_line, read_line)
    });
    assert_eq!(sqlite_notes_at(&stats, pin_line), 1);
    assert!(sqlite_violation_at(pin_line));
    assert_eq!(sqlite_notes_at(&stats, read_line), 0, "a re-entry cannot block on the lock");
    assert_eq!(snapshot().site(file!(), read_line), None);
}

#[test]
fn a_long_connection_lock_wait_names_the_holder() {
    const WAITER: &str = "registry-lock-waiter-test";
    const HOLD: Duration = Duration::from_millis(20);
    cmux_threads::set_holder_tracking(true);
    let registry = registry("blocking-lock-wait");
    let connection = Arc::clone(&registry.connection);
    let (held_tx, held_rx) = channel();
    let holder = std::thread::Builder::new()
        .name("registry-lock-holder-test".into())
        .spawn(move || {
            let pin = connection.pin();
            held_tx.send(()).expect("held");
            // Until the waiter's try failed, then long enough to record.
            while connection.lock_waiting() == 0 {
                std::thread::yield_now();
            }
            std::thread::sleep(HOLD);
            drop(pin);
        })
        .expect("spawn holder");
    held_rx.recv().expect("the holder pinned the connection");
    let connection = Arc::clone(&registry.connection);
    let (line, _) = on_thread(WAITER, false, move || {
        let line = line!() + 1;
        registry.terminal_revision().expect("terminal revision");
        line
    });
    holder.join().expect("holder");
    assert_eq!(connection.last_holder().as_deref(), Some(WAITER));
    let waits = cmux_threads::lock_waits();
    let wait = waits
        .recent
        .iter()
        .find(|wait| wait.waiter == WAITER)
        .expect("the wait behind the pin is recorded");
    assert_eq!(wait.lock, "registry.connection");
    assert_eq!(wait.holder.as_deref(), Some("registry-lock-holder-test"));
    assert!(wait.waited >= HOLD, "{wait:?}");
    assert_eq!((wait.file, wait.line), (file!(), line), "the read's caller");
}
