//! `exit_with_process` (server/starter_exit.rs): an owner started for one
//! process ends its terminals and stops when that process exits.

use std::sync::atomic::Ordering;
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

/// A stand-in starter, killed when the test ends however it ends.
struct StarterProcess(std::process::Child);

impl StarterProcess {
    fn spawn() -> Self {
        Self(std::process::Command::new("sleep").arg("60").spawn().unwrap())
    }

    fn starter(&self) -> Starter {
        Starter::current(self.0.id()).expect("the stand-in starter runs")
    }

    fn exit(&mut self) {
        self.0.kill().unwrap();
        self.0.wait().unwrap();
    }
}

impl Drop for StarterProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn exit_with_process_ends_the_terminals_and_stops_the_owner() {
    let mux = mux("exits");
    let surface = mux.new_workspace(Some("job".into()), Some((80, 24))).unwrap();
    let terminal = mux.resource_terminal_host_identity(&surface).unwrap().terminal_id;
    // A client of the starter that is still registered does not keep the
    // owner: the process it served is gone.
    let leftover = connect(&mux);
    let mut starter = StarterProcess::spawn();
    exit_with_process(&mux, starter.starter()).unwrap();

    std::thread::sleep(Duration::from_millis(200));
    assert!(!mux.daemon_shutdown_requested(), "the owner stopped while its starter runs");
    assert_ne!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);

    starter.exit();
    assert!(shutdown_within(&mux, Duration::from_secs(30)), "the owner outlived its starter");
    assert_eq!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);
    assert!(mux.control_clients.contains(leftover));
    let late = connect(&mux);
    assert!(!mux.control_clients.contains(late), "a client arriving during the exit is refused");
}

#[test]
fn exit_with_process_of_an_exited_starter_stops_at_once() {
    let mux = mux("gone");
    let mut process = StarterProcess::spawn();
    let starter = process.starter();
    process.exit();
    exit_with_process(&mux, starter).unwrap();
    assert!(shutdown_within(&mux, Duration::from_secs(30)));
}

#[test]
fn exit_with_process_matches_a_known_start_time_only() {
    assert!(starter_exit::same_process(17, Some(17)));
    // Another start time, or one that cannot be read, is another process.
    assert!(!starter_exit::same_process(17, Some(18)));
    assert!(!starter_exit::same_process(17, None));
    // A bare pid (an owner started by hand) names the process alone.
    assert!(starter_exit::same_process(0, None));
    // ensure never records an unknown start time: a gone pid has no starter.
    let mut process = StarterProcess::spawn();
    let pid = process.starter().pid;
    process.exit();
    assert_eq!(Starter::current(pid), None);
}

#[test]
fn exit_with_process_never_follows_a_reused_pid() {
    let mux = mux("reused");
    let process = StarterProcess::spawn();
    // The same pid with another start time: the process the owner was
    // started for is gone, whoever holds the pid now.
    let mut starter = process.starter();
    starter.started_ms = starter.started_ms.saturating_sub(60_000).max(1);
    exit_with_process(&mux, starter).unwrap();
    assert!(shutdown_within(&mux, Duration::from_secs(30)));
}

#[test]
fn exit_with_process_waits_out_a_running_handoff_and_stops_after_it_is_cancelled() {
    let mux = mux("handoff");
    let surface = mux.new_workspace(Some("job".into()), Some((80, 24))).unwrap();
    let terminal = mux.resource_terminal_host_identity(&surface).unwrap().terminal_id;
    // Another handoff (a client's shutdown-daemon) holds the reservation.
    assert!(mux.control_clients.begin_owner_shutdown(true));
    assert!(!starter_exit::stop_for_exited_starter(&mux));
    assert!(!mux.daemon_shutdown_requested());
    assert_ne!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);

    let refused_before = starter_exit::REFUSED_STOPS.load(Ordering::SeqCst);
    let mut process = StarterProcess::spawn();
    exit_with_process(&mux, process.starter()).unwrap();
    process.exit();
    // The watcher met the running handoff (at least once) before it ends.
    let deadline = Instant::now() + Duration::from_secs(30);
    while starter_exit::REFUSED_STOPS.load(Ordering::SeqCst) == refused_before
        && Instant::now() < deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(starter_exit::REFUSED_STOPS.load(Ordering::SeqCst) > refused_before);
    assert!(!mux.daemon_shutdown_requested(), "the exit raced the running handoff");
    // That handoff is cancelled: the owner must still stop.
    mux.control_clients.cancel_daemon_handoff(orphan_shutdown::ORPHAN_SHUTDOWN_REQUESTER);
    assert!(shutdown_within(&mux, Duration::from_secs(30)), "the owner outlived its starter");
    assert_eq!(lifecycle(&mux, &terminal), TerminalLifecycle::Tombstoned);
}

#[test]
fn exit_with_process_fence_is_released_unless_committed() {
    let mux = mux("fence");
    {
        assert!(mux.control_clients.begin_owner_shutdown(false));
        let _fence = starter_exit::StopFence { mux: &mux, committed: false };
    }
    let later = connect(&mux);
    assert!(mux.control_clients.contains(later), "the fence was left behind");
}
