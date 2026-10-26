//! `CMUX_DAEMON_BLOCKING=panic` at the registry connection: a registry read on
//! a thread that disallows blocking panics at the read's caller, and an
//! ordinary thread's read never does. Panic mode is process-wide, so it gets
//! its own test binary (the record-mode tests are in
//! src/workspace_registry/registry_connection_blocking_tests.rs).

use cmux_threads::blocking::{BlockingKind, BlockingMode, set_mode, snapshot};
use cmux_tui_core::WorkspaceRegistry;

#[cfg(debug_assertions)]
#[test]
fn a_disallowed_registry_read_panics_with_the_caller_location() {
    set_mode(BlockingMode::Panic);
    let registry = WorkspaceRegistry::in_memory("blocking-panic").expect("registry");
    let (line_tx, line_rx) = std::sync::mpsc::channel();
    let result = std::thread::Builder::new()
        .name("mux-conn-panic-test".into())
        .spawn(move || {
            cmux_threads::disallow_blocking();
            line_tx.send(line!() + 1).expect("send line");
            let _ = registry.terminal_revision();
        })
        .expect("spawn")
        .join();
    let line = line_rx.recv().expect("line");
    let payload = result.expect_err("the registry read panics");
    let message = payload.downcast_ref::<String>().cloned().unwrap_or_default();
    assert!(message.contains(&format!("{}:{line}:", file!())), "{message}");
    assert!(message.contains("(sqlite)"), "{message}");
    assert!(message.contains("'mux-conn-panic-test'"), "{message}");
    let site = snapshot().site(file!(), line).copied().expect("site recorded");
    assert!(site.kinds.contains(BlockingKind::Sqlite));
    assert_eq!(site.count, 1);
}

#[test]
fn an_ordinary_thread_registry_read_never_panics() {
    set_mode(BlockingMode::Panic);
    let registry = WorkspaceRegistry::in_memory("blocking-panic-ordinary").expect("registry");
    let line = line!() + 1;
    registry.terminal_revision().expect("terminal revision");
    assert_eq!(snapshot().site(file!(), line), None);
}
