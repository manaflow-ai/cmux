//! The registry connection as a checked scope: a thread that disallows
//! blocking records its registry reads at the caller (`cmux_threads::blocking`),
//! a re-entry is not checked again, and a connection-lock wait over the budget
//! is recorded with the holder's thread name (`cmux_threads::lock_waits`).
//! Panic mode is process-wide: tests/registry_blocking_panic.rs.

use std::sync::mpsc::channel;
use std::time::Duration;

use cmux_threads::blocking::{BlockingKind, BlockingMode, disallow_blocking, set_mode, snapshot};

use crate::WorkspaceRegistry;

fn registry(name: &str) -> WorkspaceRegistry {
    WorkspaceRegistry::in_memory(name).expect("registry")
}

fn sqlite_count_at(line: u32) -> u64 {
    snapshot()
        .site(file!(), line)
        .filter(|site| site.kinds.contains(BlockingKind::Sqlite))
        .map_or(0, |site| site.count)
}

fn on_thread<R: Send + 'static>(
    name: &str,
    disallow: bool,
    f: impl FnOnce() -> R + Send + 'static,
) -> R {
    set_mode(BlockingMode::Record);
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            if disallow {
                disallow_blocking();
            }
            f()
        })
        .expect("spawn")
        .join()
        .expect("test thread")
}

#[test]
fn a_disallowed_registry_read_records_one_sqlite_site_at_its_caller() {
    let registry = registry("blocking-disallowed-read");
    let line = on_thread("mux-conn-blocking-test", true, move || {
        let line = line!() + 1;
        registry.terminal_revision().expect("terminal revision");
        line
    });
    assert_eq!(sqlite_count_at(line), 1);
}

#[test]
fn an_allowed_registry_read_records_nothing() {
    let registry = registry("blocking-allowed-read");
    let line = on_thread("registry-allowed-test", false, move || {
        let line = line!() + 1;
        registry.terminal_revision().expect("terminal revision");
        line
    });
    assert_eq!(sqlite_count_at(line), 0);
}

#[test]
fn a_reentry_is_not_checked_again() {
    let registry = registry("blocking-reentry");
    let (pin_line, read_line) = on_thread("mux-conn-reentry-test", true, move || {
        let pin_line = line!() + 1;
        let pin = registry.connection.pin();
        let read_line = line!() + 1;
        registry.terminal_revision().expect("terminal revision under the pin");
        drop(pin);
        (pin_line, read_line)
    });
    assert_eq!(sqlite_count_at(pin_line), 1);
    assert_eq!(sqlite_count_at(read_line), 0, "a re-entry cannot block on the lock");
}

#[test]
fn a_long_connection_lock_wait_names_the_holder() {
    const WAITER: &str = "registry-lock-waiter-test";
    let registry = registry("blocking-lock-wait");
    let connection = std::sync::Arc::clone(&registry.connection);
    let (held_tx, held_rx) = channel();
    let holder = std::thread::Builder::new()
        .name("registry-lock-holder-test".into())
        .spawn(move || {
            let pin = connection.pin();
            held_tx.send(()).expect("held");
            std::thread::sleep(Duration::from_millis(20));
            drop(pin);
        })
        .expect("spawn holder");
    held_rx.recv().expect("the holder pinned the connection");
    let connection = std::sync::Arc::clone(&registry.connection);
    let line = on_thread(WAITER, false, move || {
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
    assert!(wait.waited >= cmux_threads::LOCK_WAIT_BUDGET, "{wait:?}");
    assert_eq!((wait.file, wait.line), (file!(), line), "the read's caller");
}
