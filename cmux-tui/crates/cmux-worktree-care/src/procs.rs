//! What works in a worktree besides acpmux's own sessions, from the
//! registries those programs keep of themselves; never a process scan
//! (plans/cmux-next/pty-holder.md section 4). Today: Claude Code's session
//! registry, `<config dir>/sessions/<pid>.json` with the session's pid and
//! folder, one per running Claude Code (an agent in a terminal outside
//! acpmux included). A record whose pid no longer runs is stale. A reused
//! pid reads as running, which keeps a worktree: the safe side.

use std::path::{Path, PathBuf};

use serde::Deserialize;

/// A program working in a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Process {
    pub pid: u32,
    pub cwd: PathBuf,
}

/// Where a pass learns what works where, read up front and again right
/// before anything goes. An error stops the pass's actions.
pub type Uses = dyn Fn() -> Result<Vec<Process>, String> + Send + Sync;

#[derive(Deserialize)]
struct ClaudeSession {
    pid: u32,
    cwd: PathBuf,
}

/// The running Claude Code sessions registered under each of `config_dirs`
/// (a `CLAUDE_CONFIG_DIR`, or `~/.claude`). A folder that is absent holds
/// none; one that cannot be read is an error.
pub fn claude_sessions(config_dirs: &[PathBuf]) -> Result<Vec<Process>, String> {
    let mut found = Vec::new();
    for dir in config_dirs {
        let sessions = dir.join("sessions");
        let entries = match std::fs::read_dir(&sessions) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("{}: {error}", sessions.display())),
        };
        let (mut records, mut read) = (0, 0);
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            records += 1;
            // A record being written reads as not JSON yet; its session
            // registers again on its next update.
            let Ok(bytes) = std::fs::read(&path) else { continue };
            let Ok(session) = serde_json::from_slice::<ClaudeSession>(&bytes) else { continue };
            read += 1;
            if runs(session.pid) {
                found.push(Process { pid: session.pid, cwd: session.cwd });
            }
        }
        // None of several records reads: the format changed, and every
        // session would look gone.
        if records >= 2 && read == 0 {
            return Err(format!(
                "{}: no session record reads ({records} files)",
                sessions.display()
            ));
        }
    }
    Ok(found)
}

/// Whether `pid` names a running process (`kill(pid, 0)`; one of another
/// user's counts as running).
#[cfg(unix)]
fn runs(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 checks for existence and delivers nothing.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Windows: a registered session counts as running.
#[cfg(not(unix))]
fn runs(_pid: u32) -> bool {
    true
}

/// The first program working in `folder` or below it, other than this one.
/// Registries record real paths, so `folder` is compared as given and as
/// its real path (`/tmp` is `/private/tmp` on macOS).
pub fn inside<'a>(processes: &'a [Process], folder: &Path) -> Option<&'a Process> {
    let own = std::process::id();
    let real = std::fs::canonicalize(folder).ok();
    processes.iter().find(|process| {
        process.pid != own
            && (process.cwd.starts_with(folder)
                || real.as_deref().is_some_and(|real| process.cwd.starts_with(real)))
    })
}

#[cfg(test)]
mod care_tests {
    use super::*;

    #[test]
    fn a_process_in_a_subfolder_is_inside_but_a_sibling_prefix_is_not() {
        let processes = vec![
            Process { pid: 1, cwd: PathBuf::from("/w/a-2/src") },
            Process { pid: 2, cwd: PathBuf::from("/w/a/src") },
        ];
        assert_eq!(inside(&processes, Path::new("/w/a")).map(|p| p.pid), Some(2));
        assert_eq!(inside(&processes, Path::new("/w/b")), None);
    }

    #[test]
    fn care_a_running_claude_session_is_found_and_a_stale_one_is_not() {
        let dir = crate::store::care_tests::scratch("claude-registry");
        let sessions = dir.join("sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let me = std::process::id();
        std::fs::write(
            sessions.join("1.json"),
            format!(r#"{{"pid":{me},"cwd":"/w/a","kind":"interactive"}}"#),
        )
        .unwrap();
        // Far above any pid_max: never running.
        std::fs::write(sessions.join("2.json"), r#"{"pid":2000000000,"cwd":"/w/b"}"#).unwrap();
        std::fs::write(sessions.join("3.json"), "{not json").unwrap();
        let found = claude_sessions(&[dir.clone(), dir.join("absent")]).unwrap();
        assert_eq!(found, vec![Process { pid: me, cwd: PathBuf::from("/w/a") }]);
        // A format change: no record reads, so the pass must not act.
        for name in ["1.json", "2.json"] {
            std::fs::write(sessions.join(name), r#"{"processId":1,"folder":"/w/a"}"#).unwrap();
        }
        assert!(claude_sessions(std::slice::from_ref(&dir)).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
