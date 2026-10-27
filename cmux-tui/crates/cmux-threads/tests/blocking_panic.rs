//! Panic mode is process-wide, so it gets its own test binary.

use cmux_threads::blocking::{BlockingMode, mode, set_mode, snapshot};
use cmux_threads::{checked, disallow_blocking};

/// Release never panics: `Panic` reads back as `Record` and a violation is
/// only recorded.
#[cfg(not(debug_assertions))]
#[test]
fn release_treats_panic_mode_as_record() {
    set_mode(BlockingMode::Panic);
    assert_eq!(mode(), BlockingMode::Record);
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let line = std::thread::Builder::new()
        .name("mux-conn-test".into())
        .spawn(move || {
            disallow_blocking();
            let line = line!() + 1;
            let bytes = checked::fs::read(&manifest).expect("read");
            assert!(!bytes.is_empty());
            line
        })
        .expect("spawn")
        .join()
        .expect("a disallowed read does not panic in Release");
    assert_eq!(snapshot().site(file!(), line).map(|site| site.count), Some(1));
}

#[cfg(debug_assertions)]
#[test]
fn panic_mode_reads_back_in_debug() {
    set_mode(BlockingMode::Panic);
    assert_eq!(mode(), BlockingMode::Panic);
}

#[cfg(debug_assertions)]
#[test]
fn disallowed_checked_read_panics_with_the_caller_location() {
    set_mode(BlockingMode::Panic);
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let (line_tx, line_rx) = std::sync::mpsc::channel();
    let result = std::thread::Builder::new()
        .name("mux-conn-test".into())
        .spawn(move || {
            disallow_blocking();
            line_tx.send(line!() + 1).expect("send line");
            let _ = checked::fs::read(&manifest);
        })
        .expect("spawn")
        .join();
    let line = line_rx.recv().expect("line");
    let payload = result.expect_err("the checked read panics");
    let message = payload.downcast_ref::<String>().cloned().unwrap_or_default();
    assert!(message.contains(&format!("{}:{line}:", file!())), "{message}");
    assert!(message.contains("(fs)"), "{message}");
    assert!(message.contains("'mux-conn-test'"), "{message}");
    assert_eq!(snapshot().site(file!(), line).map(|site| site.count), Some(1));
}

#[test]
fn ordinary_thread_never_panics() {
    set_mode(BlockingMode::Panic);
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
    let line = line!() + 1;
    let bytes = checked::fs::read(&manifest).expect("read");
    assert!(!bytes.is_empty());
    assert_eq!(snapshot().site(file!(), line), None);
}

/// A contended lock on a thread that disallows blocking panics at the
/// caller before it waits: no guard is held, so the lock is not poisoned.
#[cfg(debug_assertions)]
#[test]
fn a_contended_lock_on_a_disallowed_thread_panics_before_the_wait() {
    use std::sync::{Arc, Mutex};
    set_mode(BlockingMode::Panic);
    let shared = Arc::new((Mutex::new(7), cmux_threads::LockHolder::default()));
    let held = shared.0.lock().expect("lock");
    let (line_tx, line_rx) = std::sync::mpsc::channel();
    let waiter = Arc::clone(&shared);
    let result = std::thread::Builder::new()
        .name("mux-conn-lock-test".into())
        .spawn(move || {
            disallow_blocking();
            line_tx.send(line!() + 1).expect("send line");
            let site = std::panic::Location::caller();
            drop(waiter.1.lock_mutex("test.panic", site, &waiter.0));
        })
        .expect("spawn")
        .join();
    drop(held);
    let payload = result.expect_err("the contended lock panics");
    let message = payload.downcast_ref::<String>().cloned().unwrap_or_default();
    let line = line_rx.recv().expect("line");
    assert!(message.contains(&format!("{}:{line}:", file!())), "{message}");
    assert!(message.contains("(lock-wait)"), "{message}");
    assert_eq!(*shared.0.lock().expect("the lock is not poisoned"), 7);
    assert_eq!(shared.1.waiting(), 0);
}
