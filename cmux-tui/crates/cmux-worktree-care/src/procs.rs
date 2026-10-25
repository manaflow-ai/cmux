//! What works in a worktree besides acpmux's own sessions, from the
//! registries those programs keep of themselves; never a process scan
//! (plans/cmux-next/pty-holder.md section 4). Today: Claude Code's session
//! registry, `<config dir>/sessions/<pid>.json` with the session's pid and
//! folder, one per running Claude Code (an agent in a terminal outside
//! acpmux included). A record whose pid no longer runs is stale. A reused
//! pid reads as running, which keeps a worktree: the safe side.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

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
/// Both sides are compared as given and resolved through links: a registry
/// may record a real path (`/tmp` is `/private/tmp` on macOS) or a linked
/// one (a Claude Code session in `~/.cmux/worktrees/...`, which git records
/// as `~/.cmux/worktrees.noindex/...`).
pub fn inside<'a>(processes: &'a [Process], folder: &Path) -> Option<&'a Process> {
    let own = std::process::id();
    let real = crate::store::resolved(folder);
    processes.iter().find(|process| {
        process.pid != own
            && (process.cwd.starts_with(folder)
                || process.cwd.starts_with(&real)
                || crate::store::resolved(&process.cwd).starts_with(&real))
    })
}

/// How long the open-file check of one folder may take.
pub const OPEN_CHECK: Duration = Duration::from_secs(10);

/// Whether a program has a folder open, and which: see [`open_inside`].
pub type Open = dyn Fn(&Path) -> Result<Option<u32>, String> + Send + Sync;

/// A program other than this one that has `folder` open: its working folder,
/// or a file at the folder's top level (`lsof +d`, not `+D`: no walk of the
/// tree). For what no registry records (a shell, an editor, a build started
/// by hand). One bounded check of one folder right before it is removed,
/// never a machine scan (the reviewed keep row in
/// `scripts/cmux-next/process-scan-baseline.tsv`). A timeout or an error is
/// an error, so the folder stays.
#[cfg(unix)]
pub fn open_inside(folder: &Path) -> Result<Option<u32>, String> {
    // lsof is in /usr/sbin on macOS, which a daemon's PATH may lack.
    let mut dirs: Vec<PathBuf> = vec!["/usr/sbin".into(), "/usr/bin".into()];
    dirs.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()));
    let path = std::env::join_paths(dirs).map_err(|error| error.to_string())?;
    let mut command = std::process::Command::new("lsof");
    command
        .env("PATH", path)
        .args(["-w", "-t", "+d"])
        .arg(folder)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output =
        crate::git::run_within(command, OPEN_CHECK).map_err(|error| format!("lsof: {error}"))?;
    let own = std::process::id();
    let pid = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .find(|pid| *pid != own);
    if pid.is_some() {
        return Ok(pid);
    }
    // lsof exits 1 both when nothing has the folder open and on an error;
    // with warnings off (-w), only an error says something.
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if output.status.success() || (output.status.code() == Some(1) && stderr.is_empty()) {
        Ok(None)
    } else if stderr.is_empty() {
        Err(format!("lsof: {}", output.status))
    } else {
        Err(format!("lsof: {stderr}"))
    }
}

/// Windows: an open file there makes the removal itself fail.
#[cfg(not(unix))]
pub fn open_inside(_folder: &Path) -> Result<Option<u32>, String> {
    Ok(None)
}

#[cfg(test)]
mod care_tests {
    #[cfg(unix)]
    #[test]
    fn care_a_program_working_in_a_folder_has_it_open() {
        let folder = std::env::temp_dir().join(format!("care-open-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let mut child =
            std::process::Command::new("sleep").arg("30").current_dir(&folder).spawn().unwrap();
        let found = open_inside(&folder);
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&folder);
        match found {
            Ok(pid) => assert_eq!(pid, Some(child.id())),
            // No lsof on this machine: the check fails closed, which is
            // what a pass needs; nothing more to test here.
            Err(error) => assert!(error.starts_with("lsof"), "{error}"),
        }
    }

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
