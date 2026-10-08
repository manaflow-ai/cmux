//! The Linux [`Host`]: `/proc` reads, `ssh-keygen -Q` and pidfd signals.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::sessions::{Host, SessionRecord};
use crate::linux::fds::PidFd;

pub struct LinuxHost {
    /// Absolute tool paths (root runs these; PATH is not consulted).
    pub ssh_keygen: PathBuf,
    pub loginctl: PathBuf,
    /// Root-only scratch directory for the certificate file `-Q` reads.
    pub scratch: PathBuf,
}

impl LinuxHost {
    pub fn new(scratch: PathBuf) -> Self {
        Self {
            ssh_keygen: PathBuf::from("/usr/bin/ssh-keygen"),
            loginctl: PathBuf::from("/usr/bin/loginctl"),
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
}

impl LinuxHost {
    /// Ends the logind session (every process of its scope) only when the
    /// recorded sshd process leads it.
    fn terminate_logind(&self, id: &str, leader: u32) {
        let Ok(out) = Command::new(&self.loginctl)
            .args(["show-session", id, "-p", "Leader", "--value"])
            .stdin(Stdio::null())
            .output()
        else {
            return;
        };
        if String::from_utf8_lossy(&out.stdout).trim() != leader.to_string() {
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
