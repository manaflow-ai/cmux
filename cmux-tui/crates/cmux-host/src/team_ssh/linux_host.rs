//! The Linux [`Host`]: `/proc` reads, `ssh-keygen -Q`, pidfd signals, and
//! `loginctl disable-linger` / `systemctl stop user@<uid>.service` for one
//! named user.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::sessions::{Host, SessionRecord};
use super::trust::valid_user;
use crate::linux::fds::PidFd;
use crate::linux::spawn::lookup_user;

/// Lowest uid of a regular account (Debian and Ubuntu `UID_MIN`); a user
/// manager below it, or of `nobody`, is never stopped.
const UID_MIN: u32 = 1000;
const NOBODY_UID: u32 = 65534;

/// Runs a tool with no stdin and fails on a non-zero exit.
fn run_tool(tool: &Path, args: &[&str]) -> io::Result<()> {
    let out = Command::new(tool).args(args).stdin(Stdio::null()).output()?;
    if out.status.success() {
        return Ok(());
    }
    Err(io::Error::other(format!(
        "{} {}: {}",
        tool.display(),
        args.join(" "),
        String::from_utf8_lossy(&out.stderr).trim()
    )))
}

pub struct LinuxHost {
    /// Absolute tool paths (root runs these; PATH is not consulted).
    pub ssh_keygen: PathBuf,
    pub loginctl: PathBuf,
    pub systemctl: PathBuf,
    /// logind's lingering flags (one file per lingering user).
    pub linger_dir: PathBuf,
    /// Root-only scratch directory for the certificate file `-Q` reads.
    pub scratch: PathBuf,
}

impl LinuxHost {
    pub fn new(scratch: PathBuf) -> Self {
        Self {
            ssh_keygen: PathBuf::from("/usr/bin/ssh-keygen"),
            loginctl: PathBuf::from("/usr/bin/loginctl"),
            systemctl: PathBuf::from("/usr/bin/systemctl"),
            linger_dir: PathBuf::from("/var/lib/systemd/linger"),
            scratch,
        }
    }
}

/// Field 22 of `/proc/<pid>/stat` (start time in clock ticks since boot).
pub fn proc_start_time(pid: u32) -> Option<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // comm (field 2) may hold spaces and parens; fields after it are plain.
    let rest = &stat[stat.rfind(')')? + 1..];
    rest.split_whitespace().nth(19)?.parse().ok()
}

impl Host for LinuxHost {
    fn start_time(&self, pid: u32) -> Option<u64> {
        proc_start_time(pid)
    }

    fn comm(&self, pid: u32) -> Option<String> {
        fs::read_to_string(format!("/proc/{pid}/comm")).ok().map(|s| s.trim_end().to_owned())
    }

    fn revoked(&self, krl: &Path, cert_line: &str) -> io::Result<bool> {
        fs::create_dir_all(&self.scratch)?;
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&self.scratch, fs::Permissions::from_mode(0o700))?;
        }
        let file = self.scratch.join(format!(".check-{}.pub", std::process::id()));
        fs::write(&file, format!("{cert_line}\n"))?;
        let out = Command::new(&self.ssh_keygen)
            .arg("-Q")
            .arg("-f")
            .arg(krl)
            .arg(&file)
            .stdin(Stdio::null())
            .output();
        let _ = fs::remove_file(&file);
        let out = out?;
        let stdout = String::from_utf8_lossy(&out.stdout);
        if stdout.contains("REVOKED") {
            return Ok(true);
        }
        if out.status.success() && stdout.contains(": ok") {
            return Ok(false);
        }
        Err(io::Error::other(format!(
            "ssh-keygen -Q failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }

    fn end(&self, record: &SessionRecord) -> io::Result<()> {
        // Pin the process, then confirm the pinned process is the recorded one.
        let pidfd = PidFd::open(record.pid)?;
        if proc_start_time(record.pid) != Some(record.start_time) {
            return Err(io::Error::other("pid no longer names the recorded session"));
        }
        if let Some(id) = &record.logind_session {
            self.terminate_logind(id, record.pid);
        }
        match pidfd.signal(libc::SIGTERM) {
            Err(e) if e.raw_os_error() != Some(libc::ESRCH) => Err(e),
            _ => Ok(()),
        }
    }

    fn disable_linger(&self, user: &str) -> io::Result<bool> {
        if !valid_user(user) {
            return Err(io::Error::other(format!("invalid user name {user:?}")));
        }
        match fs::symlink_metadata(self.linger_dir.join(user)) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(e) => return Err(e),
            Ok(_) => {}
        }
        run_tool(&self.loginctl, &["disable-linger", user])?;
        Ok(true)
    }

    fn stop_user_manager(&self, user: &str, revoked_sessions: &[String]) -> io::Result<bool> {
        if !valid_user(user) {
            return Err(io::Error::other(format!("invalid user name {user:?}")));
        }
        let Some(account) = lookup_user(user) else { return Ok(false) };
        if account.uid < UID_MIN || account.uid == NOBODY_UID {
            return Ok(false);
        }
        for id in self.logind_sessions(account.uid) {
            if !revoked_sessions.contains(&id) && !self.session_closing(&id) {
                return Ok(false);
            }
        }
        // --no-block: a slow user unit must not hold the trust sync past
        // its fail-closed bound; logind finishes the stop.
        let unit = format!("user@{}.service", account.uid);
        run_tool(&self.systemctl, &["--no-block", "stop", &unit])?;
        Ok(true)
    }
}

impl LinuxHost {
    /// The user's logind session ids; none when logind does not know the
    /// user (not logged in, not lingering).
    fn logind_sessions(&self, uid: u32) -> Vec<String> {
        let Ok(out) = Command::new(&self.loginctl)
            .args(["show-user", &uid.to_string(), "-p", "Sessions", "--value"])
            .stdin(Stdio::null())
            .output()
        else {
            return Vec::new();
        };
        String::from_utf8_lossy(&out.stdout).split_whitespace().map(str::to_owned).collect()
    }

    /// Whether the logind session is closing (or already gone).
    fn session_closing(&self, id: &str) -> bool {
        let Ok(out) = Command::new(&self.loginctl)
            .args(["show-session", id, "-p", "State", "--value"])
            .stdin(Stdio::null())
            .output()
        else {
            return false;
        };
        !out.status.success() || String::from_utf8_lossy(&out.stdout).trim() == "closing"
    }

    /// The leader pid of a logind session, `None` when unknown.
    pub fn session_leader(&self, id: &str) -> Option<u32> {
        let out = Command::new(&self.loginctl)
            .args(["show-session", id, "-p", "Leader", "--value"])
            .stdin(Stdio::null())
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stdout).trim().parse().ok()
    }

    /// Ends the logind session (every process of its scope) only when the
    /// recorded sshd process leads it.
    fn terminate_logind(&self, id: &str, leader: u32) {
        if self.session_leader(id) != Some(leader) {
            return;
        }
        let _ = Command::new(&self.loginctl)
            .args(["terminate-session", id])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}
