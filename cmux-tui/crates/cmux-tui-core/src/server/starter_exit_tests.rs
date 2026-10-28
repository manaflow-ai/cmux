//! `exit_with_process` (server/starter_exit.rs): an owner started for one
//! process ends its terminals and stops when that process exits.

use std::time::{Duration, Instant};

use crate::server::*;
use crate::workspace_registry::TerminalLifecycle;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("starter-exit-{label}"), crate::SurfaceOptions::default())
}

fn connect(mux: &Arc<Mux>) -> u64 {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    mux.control_clients.register(ClientTransport::Unix, writer)
}

fn lifecycle(mux: &Arc<Mux>, terminal_id: &str) -> TerminalLifecycle {
    mux.resolve_terminal(terminal_id).unwrap().unwrap().terminal.lifecycle
}

/// Test-only bounded wait for the watcher thread's effect.
fn shutdown_within(mux: &Arc<Mux>, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    while !mux.daemon_shutdown_requested() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    mux.daemon_shutdown_requested()
}

#[test]
fn exit_with_process_ends_the_terminals_and_stops_the_owner() {
    let mux = mux("exits");
    let surface = mux.new_workspace(Some("job".into()), Some((80, 24))).unwrap();
    let terminal = mux.resource_terminal_host_identity(&surface).unwrap().terminal_id;
    // A client of the starter that is still registered does not keep the
    // owner: the process it served is gone.
    let leftover = connect(&mux);
    let mut starter = std::process::Command::new("sleep").arg("60").spawn().unwrap();
    exit_with_process(&mux, starter.id()).unwrap();

    std::thread::sleep(Duration::from_millis(200));
    assert!(!mux.daemon_shutdown_requested(), "the owner stopped while its starter runs");
    assert_ne!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);

    starter.kill().unwrap();
    starter.wait().unwrap();
    assert!(shutdown_within(&mux, Duration::from_secs(30)), "the owner outlived its starter");
    assert_eq!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);
    assert!(mux.control_clients.contains(leftover));
    let late = connect(&mux);
    assert!(!mux.control_clients.contains(late), "a client arriving during the exit is refused");
}

#[test]
fn exit_with_process_of_an_exited_starter_stops_at_once() {
    let mux = mux("gone");
    let mut starter = std::process::Command::new("true").spawn().unwrap();
    let pid = starter.id();
    starter.wait().unwrap();
    exit_with_process(&mux, pid).unwrap();
    assert!(shutdown_within(&mux, Duration::from_secs(30)));
}

#[test]
fn exit_with_process_never_races_a_running_handoff() {
    let mux = mux("handoff");
    let surface = mux.new_workspace(Some("job".into()), Some((80, 24))).unwrap();
    let terminal = mux.resource_terminal_host_identity(&surface).unwrap().terminal_id;
    assert!(mux.control_clients.begin_owner_shutdown(true));
    assert!(!starter_exit::stop_for_exited_starter(&mux));
    assert!(!mux.daemon_shutdown_requested());
    assert_ne!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);
}
