//! Certificate session records and the reaper that ends revoked ones
//! (team-vm-plan.md S14: "revocation cuts live sessions").
//!
//! `session-open` runs from pam_exec as root in sshd's session process, so
//! its parent is that process. It records the parent's pid, its start time
//! (`/proc/<pid>/stat` field 22) and the certificate lines from
//! `SSH_AUTH_INFO_0`. The reaper ends a session only when every check
//! passes: the record is its own (root-only directory), the pid still has
//! the recorded start time and an sshd command name, and the KRL revokes
//! one of the session's certificates. A pid that was reused or exited is
//! forgotten, never signalled.

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::SESSIONS_DIR;
use super::cert::SessionCert;
use super::store::write_atomic;
use crate::config::Paths;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRecord {
    /// sshd's session process (pam_exec's parent).
    pub pid: u32,
    /// Its start time in clock ticks since boot.
    pub start_time: u64,
    pub user: String,
    /// Certificate public key lines (`<type> <base64>`).
    pub certs: Vec<String>,
    pub serials: Vec<u64>,
    pub key_ids: Vec<String>,
    /// systemd-logind session id (`XDG_SESSION_ID`), when pam_systemd ran.
    pub logind_session: Option<String>,
}

impl SessionRecord {
    pub fn new(
        pid: u32,
        start_time: u64,
        user: &str,
        certs: &[SessionCert],
        logind: Option<String>,
    ) -> Self {
        Self {
            pid,
            start_time,
            user: user.to_owned(),
            certs: certs.iter().map(|c| c.line.clone()).collect(),
            serials: certs.iter().map(|c| c.serial).collect(),
            key_ids: certs.iter().map(|c| c.key_id.clone()).collect(),
            logind_session: logind.filter(|id| valid_logind_id(id)),
        }
    }
}

/// logind session ids are short alphanumeric names (`c1`, `42`).
pub fn valid_logind_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 32 && id.chars().all(|c| c.is_ascii_alphanumeric())
}

/// What the reaper needs from the machine.
pub trait Host {
    /// Start time of `pid` (clock ticks since boot), `None` when gone.
    fn start_time(&self, pid: u32) -> Option<u64>;
    /// The process's command name (`/proc/<pid>/comm`).
    fn comm(&self, pid: u32) -> Option<String>;
    /// Whether the KRL at `krl` revokes the certificate line.
    fn revoked(&self, krl: &Path, cert_line: &str) -> io::Result<bool>;
    /// Ends the recorded session: SIGTERM to exactly that process (after a
    /// start-time re-check on a pinned descriptor) and the logind session
    /// it leads.
    fn end(&self, record: &SessionRecord) -> io::Result<()>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Keep,
    /// The process exited or the pid now names another process.
    Forget,
    End,
}

/// The reaper's decision for one record (no side effects).
pub fn judge(host: &dyn Host, krl: &Path, record: &SessionRecord) -> io::Result<Verdict> {
    if host.start_time(record.pid).is_none() /* RED: start time not compared */ {
        return Ok(Verdict::Forget);
    }
    if !host.comm(record.pid).is_some_and(|c| c.starts_with("sshd")) {
        return Ok(Verdict::Forget);
    }
    for cert in &record.certs {
        if host.revoked(krl, cert)? {
            return Ok(Verdict::End);
        }
    }
    Ok(Verdict::Keep)
}

fn record_path(paths: &Paths, pid: u32) -> std::path::PathBuf {
    paths.at(SESSIONS_DIR).join(format!("{pid}.json"))
}

/// Writes a record (root-only directory, 0600 file).
pub fn save(paths: &Paths, record: &SessionRecord) -> io::Result<()> {
    let dir = paths.at(SESSIONS_DIR);
    fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    }
    let json = serde_json::to_vec(record).map_err(io::Error::other)?;
    write_atomic(&record_path(paths, record.pid), &json, 0o600)
}

/// Removes the record of `pid` (close_session); absent is fine.
pub fn forget(paths: &Paths, pid: u32) -> io::Result<()> {
    match fs::remove_file(record_path(paths, pid)) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// Every readable record; a file that does not parse is skipped.
pub fn load_all(paths: &Paths) -> Vec<SessionRecord> {
    let Ok(entries) = fs::read_dir(paths.at(SESSIONS_DIR)) else { return Vec::new() };
    let mut records: Vec<SessionRecord> = entries
        .flatten()
        .filter(|e| e.file_name().to_str().is_some_and(|n| n.ends_with(".json")))
        .filter_map(|e| fs::read(e.path()).ok())
        .filter_map(|bytes| serde_json::from_slice::<SessionRecord>(&bytes).ok())
        .collect();
    records.sort_by_key(|r| r.pid);
    records
}

/// What one reaper pass did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reaped {
    pub ended: Vec<u32>,
    pub forgotten: Vec<u32>,
    pub errors: Vec<String>,
}

/// One pass over the records against the KRL on disk.
pub fn reap(paths: &Paths, host: &dyn Host) -> Reaped {
    let krl = paths.at(super::KRL_FILE);
    let mut out = Reaped::default();
    for record in load_all(paths) {
        match judge(host, &krl, &record) {
            Ok(Verdict::Keep) => {}
            Ok(Verdict::Forget) => {
                out.forgotten.push(record.pid);
                let _ = forget(paths, record.pid);
            }
            Ok(Verdict::End) => match host.end(&record) {
                Ok(()) => {
                    out.ended.push(record.pid);
                    let _ = forget(paths, record.pid);
                }
                Err(e) => out.errors.push(format!("end session {}: {e}", record.pid)),
            },
            Err(e) => out.errors.push(format!("check session {}: {e}", record.pid)),
        }
    }
    out
}
