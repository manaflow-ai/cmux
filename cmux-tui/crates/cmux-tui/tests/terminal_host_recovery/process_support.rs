//! Process and terminal-host liveness waits shared by the recovery tests.

use super::*;

pub(crate) fn wait_for_process_and_group_absent(pid: libc::pid_t) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let process_exists = process_exists(pid);
        // SAFETY: same signal-0 probe for the positive process-group id.
        let group_exists = unsafe { libc::killpg(pid, 0) } == 0
            || std::io::Error::last_os_error().kind() == std::io::ErrorKind::PermissionDenied;
        if !process_exists && !group_exists {
            return;
        }
        assert!(Instant::now() < deadline, "terminated PTY process/group {pid} remained alive");
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub(crate) fn process_exists(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 performs existence/permission checks only.
    (unsafe { libc::kill(pid, 0) }) == 0
        || std::io::Error::last_os_error().kind() == std::io::ErrorKind::PermissionDenied
}

pub(crate) fn wait_for_terminal_host_dead(path: &Path, record: &TerminalHostRecord) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if terminal_host_record_liveness(path, record).unwrap() == TerminalHostLiveness::Dead {
            return;
        }
        assert!(Instant::now() < deadline, "terminal host remained alive after termination");
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub(crate) fn wait_for_pid_file(path: &Path) -> libc::pid_t {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(contents) = fs::read_to_string(path)
            && let Ok(pid) = contents.trim().parse::<libc::pid_t>()
            && pid > 0
        {
            return pid;
        }
        assert!(Instant::now() < deadline, "process did not publish pid at {}", path.display());
        std::thread::sleep(Duration::from_millis(20));
    }
}

// R81 spare host tests live beside these waits (the root file is at its size limit).
#[path = "standby_host.rs"]
mod standby_host;

pub(crate) fn wait_for_no_host_records(root: &Path) {
    if let Some((records, exits)) = host_records_left_after_close(root) {
        panic!(
            "terminal host records or exit sidecars remained after close: {records:?}; {exits:?}"
        );
    }
}

/// [`wait_for_no_host_records`] for a test that made several terminals: on
/// failure it names which of `named` (label, terminal id) left a record,
/// whether that host still runs, and what the daemon reports for it
/// (FLAKE-TEMPLATE-ADOPT: the bare record did not say which terminal it was).
pub(crate) fn wait_for_no_host_records_naming(root: &Path, socket: &Path, named: &[(&str, &str)]) {
    let Some((records, exits)) = host_records_left_after_close(root) else { return };
    let leftovers = records
        .iter()
        .map(|(_, record)| {
            let label = named
                .iter()
                .find(|(_, id)| *id == record.terminal_id)
                .map_or("unnamed", |(label, _)| *label);
            let alive = libc::pid_t::try_from(record.host_pid).is_ok_and(process_exists);
            let resolved = request_response(
                socket,
                serde_json::json!({"id": 61, "cmd": "resolve-terminal", "terminal_id": record.terminal_id}),
            );
            format!("{label} {} host_pid={} alive={alive} resolved={resolved}", record.terminal_id, record.host_pid)
        })
        .collect::<Vec<_>>();
    panic!(
        "terminal host records or exit sidecars remained after close: {leftovers:?}; exits {exits:?}; named {named:?}"
    );
}

/// Host records and exit sidecars still present at a close deadline.
type LeftoverHostRecords = (
    Vec<(PathBuf, TerminalHostRecord)>,
    Vec<(PathBuf, cmux_tui_core::terminal_host_runtime::TerminalHostExitRecord)>,
);

/// Waits up to 10 s for every host record and exit sidecar to go; returns
/// what is still there at the deadline.
fn host_records_left_after_close(root: &Path) -> Option<LeftoverHostRecords> {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while Instant::now() < deadline {
        if load_terminal_host_records(root).unwrap().is_empty()
            && load_terminal_host_exit_records(root).unwrap().is_empty()
        {
            return None;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Some((
        load_terminal_host_records(root).unwrap(),
        load_terminal_host_exit_records(root).unwrap(),
    ))
}

/// [`wait_for_screen`] that names what the terminal showed and its state when
/// `marker` never appears (FLAKE-TEMPLATE-ADOPT, second mode: typed input after
/// adoption did not show, and the old assert dropped the screen).
pub(crate) fn assert_screen_shows(socket: &Path, surface: u64, marker: &str, terminal_id: &str) {
    let screen = wait_for_screen(socket, surface, marker);
    if screen.contains(marker) {
        return;
    }
    let resolved = request_response(
        socket,
        serde_json::json!({"id": 62, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
    );
    // crash-allow: test-only helper; a missing marker must fail with its evidence.
    panic!(
        "{marker:?} never showed on surface {surface}; resolved={resolved}; last screen:\n{screen}"
    );
}
