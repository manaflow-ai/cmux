//! `/proc` reads: adopting a running session host after an agent restart
//! and stopping terminal hosts at park. Matching is by pid file, uid and
//! exact argv elements; every signal goes through a pidfd opened before
//! the final argv check, so a reused pid is never signalled.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

use crate::daemon_spec::{
    is_session_host_argv, is_terminal_host_argv, record_host_pid, split_cmdline,
};
use crate::linux::fds::PidFd;

fn cmdline(pid: u32) -> Option<Vec<String>> {
    fs::read(format!("/proc/{pid}/cmdline")).ok().map(|raw| split_cmdline(&raw))
}

fn uid_of(pid: u32) -> Option<u32> {
    fs::metadata(format!("/proc/{pid}")).ok().map(|m| m.uid())
}

fn pids() -> Vec<u32> {
    let Ok(dir) = fs::read_dir("/proc") else { return Vec::new() };
    dir.filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok()).collect()
}

fn is_session_host(pid: u32, bin: &Path, uid: u32) -> bool {
    uid_of(pid) == Some(uid) && cmdline(pid).is_some_and(|argv| is_session_host_argv(&argv, bin))
}

/// A pidfd for `pid` when it is still the session host after the open.
fn open_verified(pid: u32, bin: &Path, uid: u32) -> Option<PidFd> {
    if !is_session_host(pid, bin, uid) {
        return None;
    }
    let pidfd = PidFd::open(pid).ok()?;
    is_session_host(pid, bin, uid).then_some(pidfd)
}

/// Finds a running session host by the agent's own pid file. The file is
/// trusted only when it is a regular file owned by the agent's effective
/// user and not writable by group or others (`/run/cmux-host`, root-only);
/// there is no `/proc` scan, so no other process can steer adoption.
pub fn find_session_host(pid_file: &Path, bin: &Path, uid: u32) -> Option<(u32, PidFd)> {
    if !trusted_pid_file(pid_file) {
        return None;
    }
    let pid = fs::read_to_string(pid_file).ok()?.trim().parse::<u32>().ok()?;
    open_verified(pid, bin, uid).map(|pidfd| (pid, pidfd))
}

fn trusted_pid_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    fs::symlink_metadata(path).is_ok_and(|meta| {
        meta.file_type().is_file() && meta.uid() == euid && meta.permissions().mode() & 0o022 == 0
    })
}

/// `host_pid` of every terminal host record under the session host's
/// state root (`<home>/.local/state/cmux-tui/**/terminal-hosts-*/*.json`).
pub fn template_host_pids(home: &Path) -> Vec<u32> {
    let mut out = Vec::new();
    collect_records(&home.join(".local/state/cmux-tui"), 0, false, &mut out);
    out
}

fn collect_records(dir: &Path, depth: u32, in_hosts: bool, out: &mut Vec<u32>) {
    if depth > 5 {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if kind.is_dir() {
            collect_records(&path, depth + 1, in_hosts || name.starts_with("terminal-hosts-"), out);
        } else if kind.is_file()
            && in_hosts
            && name.ends_with(".json")
            && let Some(pid) = fs::read_to_string(&path).ok().as_deref().and_then(record_host_pid)
        {
            out.push(pid);
        }
    }
}

/// SIGKILLs every terminal host of `uid` except `keep`. Terminal hosts
/// leave the session host's process group, so stopping the session host
/// does not stop them. Returns the pids signalled.
pub fn stop_terminal_hosts(uid: u32, keep: &[u32]) -> Vec<u32> {
    let mut killed = Vec::new();
    for pid in pids() {
        if keep.contains(&pid) || uid_of(pid) != Some(uid) {
            continue;
        }
        if !cmdline(pid).is_some_and(|argv| is_terminal_host_argv(&argv)) {
            continue;
        }
        let Ok(pidfd) = PidFd::open(pid) else { continue };
        if cmdline(pid).is_some_and(|argv| is_terminal_host_argv(&argv))
            && pidfd.signal(libc::SIGKILL).is_ok()
        {
            killed.push(pid);
        }
    }
    killed
}

/// The process exists.
pub fn alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_records_are_found_only_under_terminal_hosts_dirs() {
        let home = tempfile::tempdir().unwrap();
        let state = home.path().join(".local/state/cmux-tui/sessions/x/terminal-hosts-abc");
        fs::create_dir_all(&state).unwrap();
        fs::write(state.join("t1.json"), r#"{"host_pid":4321}"#).unwrap();
        let other = home.path().join(".local/state/cmux-tui/sessions/x");
        fs::write(other.join("registry.json"), r#"{"host_pid":99}"#).unwrap();
        assert_eq!(template_host_pids(home.path()), [4321]);
    }

    #[test]
    fn untrusted_pid_files_are_ignored() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("daemon.pid");
        fs::write(&file, format!("{}\n", std::process::id())).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(trusted_pid_file(&file));
        fs::set_permissions(&file, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(!trusted_pid_file(&file), "group/other writable");
        let link = dir.path().join("link.pid");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(!trusted_pid_file(&link), "symlink");
        assert!(find_session_host(&dir.path().join("none"), Path::new("/x"), 0).is_none());
    }

    #[test]
    fn own_process_is_not_a_session_host() {
        let me = std::process::id();
        assert!(alive(me));
        assert!(!is_session_host(me, Path::new("/nonexistent/cmux-tui"), 0));
    }
}
