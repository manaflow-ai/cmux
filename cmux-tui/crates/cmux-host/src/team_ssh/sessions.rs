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
//!
//! Work a user moved out of its session scope runs under its systemd user
//! manager (`user@<uid>.service`: `systemd-run --user`, user units), which
//! survives the session when the user lingers or has another session. So a
//! revocation also turns the user's lingering off, and when no live session
//! of that user holds an unrevoked certificate any more, stops exactly that
//! user's `user@<uid>.service`. Team users never linger: every pass turns
//! lingering off for each user that has a principals file. Every action
//! names one user or one unit; nothing is matched by name or pattern.

use std::collections::{BTreeMap, BTreeSet};
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
    /// Turns lingering off for exactly `user`; `Ok(false)` when it was off.
    fn disable_linger(&self, user: &str) -> io::Result<bool>;
    /// Stops exactly `user@<uid>.service` of `user` (its user manager, every
    /// user unit and process in it) without waiting for the stop, but only
    /// when every logind session of the user is one of `revoked_sessions` or
    /// already closing: a session no record covers (a valid login the
    /// recorder has not seen yet, a non-ssh login) keeps the manager.
    /// `Ok(false)` when nothing was stopped: such a session, an unknown user
    /// or a system account.
    fn stop_user_manager(&self, user: &str, revoked_sessions: &[String]) -> io::Result<bool>;
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
    if host.start_time(record.pid) != Some(record.start_time) {
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

/// Named by pid and start time, so forgetting a dead session never removes
/// the record of a new session that reused its pid.
fn record_path(paths: &Paths, pid: u32, start_time: u64) -> std::path::PathBuf {
    paths.at(SESSIONS_DIR).join(format!("{pid}-{start_time}.json"))
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
    write_atomic(&record_path(paths, record.pid, record.start_time), &json, 0o600)
}

/// Removes the record of `pid` started at `start_time` (close_session);
/// absent is fine.
pub fn forget(paths: &Paths, pid: u32, start_time: u64) -> io::Result<()> {
    match fs::remove_file(record_path(paths, pid, start_time)) {
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
    /// Users whose lingering this pass turned off.
    pub linger_off: Vec<String>,
    /// Users whose user manager this pass stopped.
    pub managers_stopped: Vec<String>,
    pub errors: Vec<String>,
}

/// One pass over the records against the KRL on disk, then the users'
/// lingering and user managers (module docs).
pub fn reap(paths: &Paths, host: &dyn Host) -> Reaped {
    let krl = paths.at(super::KRL_FILE);
    let mut out = Reaped::default();
    // Users seen with a revoked certificate, and users that still hold a
    // live session that is not revoked (or could not be checked).
    // Revoked users map to the logind sessions of their revoked records.
    let mut revoked: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut live = BTreeSet::new();
    for record in load_all(paths) {
        let verdict = judge(host, &krl, &record);
        match &verdict {
            Ok(Verdict::End) => {
                revoked
                    .entry(record.user.clone())
                    .or_default()
                    .extend(record.logind_session.clone());
            }
            Ok(Verdict::Keep) | Err(_) => {
                live.insert(record.user.clone());
            }
            Ok(Verdict::Forget) => {}
        }
        match verdict {
            Ok(Verdict::Keep) => {}
            Ok(Verdict::Forget) => {
                out.forgotten.push(record.pid);
                let _ = forget(paths, record.pid, record.start_time);
            }
            Ok(Verdict::End) => match host.end(&record) {
                Ok(()) => {
                    out.ended.push(record.pid);
                    let _ = forget(paths, record.pid, record.start_time);
                }
                Err(e) => out.errors.push(format!("end session {}: {e}", record.pid)),
            },
            Err(e) => out.errors.push(format!("check session {}: {e}", record.pid)),
        }
    }
    let mut linger_users: BTreeSet<String> = revoked.keys().cloned().collect();
    linger_users.extend(team_users(paths));
    for user in &linger_users {
        match host.disable_linger(user) {
            Ok(true) => out.linger_off.push(user.clone()),
            Ok(false) => {}
            Err(e) => out.errors.push(format!("disable linger {user}: {e}")),
        }
    }
    // Lingering is off first, so logind never keeps or restarts a manager
    // stopped here; a user with a valid live session keeps its manager until
    // that session ends (logind then stops it).
    for (user, sessions) in revoked.iter().filter(|(user, _)| !live.contains(*user)) {
        match host.stop_user_manager(user, sessions) {
            Ok(true) => out.managers_stopped.push(user.clone()),
            Ok(false) => {}
            Err(e) => out.errors.push(format!("stop user manager {user}: {e}")),
        }
    }
    out
}

/// Users with a principals file: the users certificates may log in as.
fn team_users(paths: &Paths) -> Vec<String> {
    let Ok(entries) = fs::read_dir(paths.at(super::PRINCIPALS_DIR)) else { return Vec::new() };
    entries
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(str::to_owned))
        .filter(|name| super::trust::valid_user(name))
        .collect()
}
