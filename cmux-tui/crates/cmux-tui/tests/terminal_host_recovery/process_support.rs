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
