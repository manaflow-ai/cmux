//! A terminal host's crash sidecar reaches the owner's panic log on every
//! path that removes it, also when the terminal's end was committed earlier
//! (an owner stopped between its commit and the loss record) or the
//! terminal was closed.

use super::*;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

/// A registry whose terminal `terminal_id` ended (`Exited`).
fn seed_ended_terminal(root: &Path, session: &str, terminal_id: &str, incarnation: &str) {
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    registry
        .commit(
            &WorkspaceMutation::daemon("workspace", "test").unwrap(),
            &serde_json::json!({"op":"create-workspace"}),
            None,
            Some(0),
            "workspace-added",
            "workspace-one",
            &[RegistryWorkspace {
                id: 1,
                public_id: WorkspacePublicId::random().unwrap(),
                key: "workspace-one".into(),
                name: "One".into(),
                name_source: Default::default(),
                name_revision: 0,
                group_key: session.into(),
            }],
            &serde_json::json!({"workspace":1,"key":"workspace-one"}),
        )
        .unwrap();
    let reserved = RegistryTerminal {
        terminal_id: terminal_id.into(),
        workspace_key: "workspace-one".into(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: serde_json::json!({}),
        exit: None,
        on_exit: TerminalOnExit::Close,
    };
    commit_terminal_transition(&mut registry, "terminal-reserved", "reserve-terminal", &reserved)
        .unwrap();
    commit_terminal_lifecycle(
        &mut registry,
        "terminal-exited",
        "host-exited",
        terminal_id,
        TerminalLifecycle::Exited,
        Some(incarnation),
        Some(serde_json::json!({
            "outcome":{"kind":"unknown","reason":"persisted-exit"},
            "exited_at":"1234567",
            "revision":"0",
        })),
    )
    .unwrap();
}

/// The host's exit receipt and crash sidecar, as a host that panicked and
/// exited leaves them.
fn write_host_leftovers(host_root: &Path, terminal_id: &str, incarnation: &str) -> PathBuf {
    std::fs::create_dir_all(host_root).unwrap();
    std::fs::set_permissions(host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let exit = crate::terminal_host_runtime::TerminalHostExitRecord::new(
        &TerminalHostIdentity { terminal_id: terminal_id.into(), incarnation: incarnation.into() },
        TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
            exited_at_ms: 1_234_567,
        },
    );
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(exit.record_path(host_root))
        .unwrap();
    file.write_all(&serde_json::to_vec(&exit).unwrap()).unwrap();
    file.sync_all().unwrap();
    let crash = host_root.join(format!("{terminal_id}.crash"));
    let sidecar = serde_json::json!({
        "terminal_id": terminal_id,
        "incarnation": incarnation,
        "message": "index out of bounds",
        "location": "crates/vt/src/parser.rs:12:5",
        "thread": "terminal-host-parser",
        "test": false,
        "host_pid": 4242,
        "at_ms": 1_700_000_000_000_u64,
        "backtrace": "0: vt::parser::advance",
    });
    std::fs::write(&crash, sidecar.to_string()).unwrap();
    File::open(host_root).unwrap().sync_all().unwrap();
    crash
}

fn panic_lines(log: &Path) -> Vec<Value> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Restart with the exit receipt and crash sidecar of a terminal whose end
/// is already committed: the receipt's acknowledgement appends the panic
/// once, then removes the sidecar.
fn assert_restart_logs_the_host_panic_once(closed: bool) {
    const TERMINAL: &str = "00000000000040008000000000000081";
    const INCARNATION: &str = "10000000000040008000000000000081";
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-host-panic-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "host-panic";
    seed_ended_terminal(&root, session, TERMINAL, INCARNATION);
    if closed {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-closed",
            "close-terminal",
            TERMINAL,
            TerminalLifecycle::Tombstoned,
            Some(INCARNATION),
            None,
        )
        .unwrap();
    }
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    let crash = write_host_leftovers(&host_root, TERMINAL, INCARNATION);
    let log = crate::terminal_host_runtime::HostPanicLog {
        path: root.join("owner-panics-host-panic.jsonl"),
        fields: cmux_panic_log::Fields::new(),
    };
    let options = SurfaceOptions {
        terminal_host_root: Some(host_root.clone()),
        host_panic_log: Some(log.clone()),
        ..SurfaceOptions::default()
    };

    let mux = Mux::open_persistent(session, options.clone(), &root).unwrap();

    assert!(!host_root.join(format!("{TERMINAL}.exit")).exists(), "the receipt is acknowledged");
    assert!(!crash.exists(), "the crash sidecar is removed with it");
    let lines = panic_lines(&log.path);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["source"], crate::terminal_host_runtime::PANIC_LOG_SOURCE);
    assert_eq!(lines[0]["terminal_id"], TERMINAL);
    assert_eq!(lines[0]["message"], "index out of bounds");
    mux.shutdown();
    drop(mux);

    // Nothing is left to log twice.
    let reopened = Mux::open_persistent(session, options, &root).unwrap();
    assert_eq!(panic_lines(&log.path).len(), 1);
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn host_panic_of_an_already_exited_terminal_reaches_the_panic_log_once() {
    assert_restart_logs_the_host_panic_once(false);
}

#[test]
fn host_panic_of_a_closed_terminal_reaches_the_panic_log_once() {
    assert_restart_logs_the_host_panic_once(true);
}
