//! Who owns each `ssh -L` forward acpmux opens (`ssh_forward.rs`), so none outlives its owner.
//!
//! A forward asked for through a shared ssh master (the fleet ssh config gives every host
//! `ControlMaster auto`) belongs to the master, not to the `ssh` that asked: killing that `ssh`
//! leaves its listener bound on the master. 92 `acpmux-fwd` listeners sat on one master to
//! air-blue after `acpmux session move` runs. And an owner killed outright (SIGKILL, a timeout)
//! never runs its drop, so its `ssh` and its forward stay.
//!
//! So every forward is recorded here before it is waited on: one file per forward in
//! `$ACPMUX_HOME/ssh-forwards/`, naming the acpmux process that owns it, its `ssh` child, the
//! host and the exact `-L` spec. It ends with its owner ([`Owner`], dropped with the forward):
//! the child is killed, `ssh -O cancel` with the same spec takes the forward off any master
//! (a no-op when there is none), and the record is removed. An owner killed outright takes its
//! ssh with it (the ssh's stdin is a pipe from the owner: `ssh_forward::tied_command`), but a
//! master keeps that forward; at daemon start, [`reap_recorded`] cancels what a dead owner left:
//! only forwards recorded here, never ones found by name or by scanning processes.

use serde::{Deserialize, Serialize};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The folder of records under an acpmux home.
pub(crate) fn ledger_dir(home: &Path) -> PathBuf {
    home.join("ssh-forwards")
}

/// How long `ssh -O cancel` may take before it is killed: a hung master must not hold a drop.
const CANCEL_BOUND: Duration = Duration::from_secs(5);
/// A record older than this is ended at start even when a process runs at its owner's pid
/// (the pid reused): a move or a watch holds its forward for minutes, never hours.
const MAX_AGE: Duration = Duration::from_secs(6 * 3600);
/// The records read in one sweep, so a start costs the same however many were left.
const MAX_RECORDS: usize = 4096;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    /// The acpmux process that opened the forward.
    pub owner: u32,
    pub host: String,
    /// The local socket (`/tmp/acpmux-fwd-.../d.sock`).
    pub local: PathBuf,
    pub remote: String,
    /// Seconds since the epoch when it was opened.
    pub opened: u64,
}

impl Record {
    fn spec(&self) -> String {
        format!("{}:{}", self.local.display(), self.remote)
    }
}

/// A forward's recorded owner. Dropped after its `ssh` child is killed (a field of
/// `ssh_forward::Forward`): takes the forward off any master and removes the record.
pub(crate) struct Owner {
    ssh_program: OsString,
    record: Record,
    file: Option<PathBuf>,
}

impl Owner {
    /// Records the forward `record` in `ledger`. A record that cannot be written is logged and
    /// the forward still ends with its owner; only a start's sweep would miss it.
    pub(crate) fn record(ssh_program: &OsStr, ledger: &Path, record: Record) -> Self {
        let file = match write_record(ledger, &record) {
            Ok(file) => Some(file),
            Err(e) => {
                tracing::warn!(local = %record.local.display(), "recording an ssh forward: {e:#}");
                None
            }
        };
        Self { ssh_program: ssh_program.to_owned(), record, file }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let ssh_program = std::mem::take(&mut self.ssh_program);
        let record = self.record.clone();
        let file = self.file.take();
        let end = move || {
            cancel(&ssh_program, &record);
            if let Some(file) = file {
                let _ = crate::home_fs::remove_file(file);
            }
        };
        // `ssh -O cancel` waits on the master (bounded): off the worker when a runtime runs.
        match tokio::runtime::Handle::try_current() {
            Ok(rt) => {
                rt.spawn_blocking(end);
            }
            Err(_) => end(),
        }
    }
}

fn write_record(ledger: &Path, record: &Record) -> anyhow::Result<PathBuf> {
    crate::home_fs::create_dirs(ledger)?;
    let name = format!("{}.json", uuid::Uuid::now_v7().simple());
    let file = ledger.join(&name);
    let tmp = ledger.join(format!(".{name}.tmp"));
    crate::home_fs::write(&tmp, serde_json::to_vec(record)?)?;
    crate::home_fs::rename(&tmp, &file)?;
    Ok(file)
}

/// `ssh -O cancel -L SPEC -- HOST`: the forward off the host's master, if one holds it. Bounded
/// by [`CANCEL_BOUND`]; with no master it fails at once, which is fine.
pub(crate) fn cancel_argv(record: &Record) -> Vec<String> {
    vec![
        "-O".into(),
        "cancel".into(),
        "-o".into(),
        "BatchMode=yes".into(),
        "-L".into(),
        record.spec(),
        "--".into(),
        record.host.clone(),
    ]
}

fn cancel(ssh_program: &OsStr, record: &Record) {
    let spawned = cmux_process::Command::new(ssh_program)
        .args(cancel_argv(record))
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn();
    let Ok(mut child) = spawned else { return };
    // Past the bound the drop ends it (`cmux_process::Child`).
    if let Ok(None) = child.wait_timeout(CANCEL_BOUND) {
        tracing::warn!(host = %record.host, "ssh -O cancel took over {CANCEL_BOUND:?}");
    }
}

/// What a start's sweep did.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Reaped {
    /// Forwards whose owner was gone: ended and their records removed.
    pub ended: usize,
    /// Records kept: their owner still runs.
    pub kept: usize,
}

/// Ends every forward recorded in `ledger` whose owner no longer runs (or is older than
/// [`MAX_AGE`]): the forward cancelled on any master, its folder and record removed. Its own
/// `ssh` already ended with the owner (`ssh_forward::tied_command`), so no pid is signalled. Reads at most
/// [`MAX_RECORDS`] records; blocking, run it off the runtime's workers.
pub(crate) fn reap_recorded(ssh_program: &OsStr, ledger: &Path) -> Reaped {
    let mut reaped = Reaped::default();
    let Ok(entries) = std::fs::read_dir(ledger) else { return reaped };
    let now = SystemTime::now();
    for entry in entries.flatten().take(MAX_RECORDS) {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            // A record whose writer died before its rename: nothing was spawned on it yet
            // past a minute (the write comes right after the spawn, the rename right after).
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|m| now.duration_since(m).ok())
                .is_some_and(|age| age > Duration::from_secs(60));
            if old {
                let _ = crate::home_fs::remove_file(&path);
            }
            continue;
        }
        if !name.ends_with(".json") {
            continue;
        }
        let Some(record) = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Record>(&bytes).ok())
        else {
            let _ = crate::home_fs::remove_file(&path);
            continue;
        };
        let age = now
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs().saturating_sub(record.opened))
            .unwrap_or(0);
        // This process's own records are its live forwards (one opened while this sweep runs).
        let owner_runs = record.owner == std::process::id() || pid_runs(record.owner);
        if owner_runs && age < MAX_AGE.as_secs() {
            reaped.kept += 1;
            continue;
        }
        cancel(ssh_program, &record);
        // Only the forward's own folder (`/tmp/acpmux-fwd-...`), never what a bad record names.
        if let Some(dir) = record.local.parent().filter(|d| {
            d.file_name().is_some_and(|n| n.to_string_lossy().starts_with("acpmux-fwd-"))
        }) {
            let _ = crate::home_fs::remove_dir_all(dir);
        }
        let _ = crate::home_fs::remove_file(&path);
        reaped.ended += 1;
    }
    reaped
}

#[cfg(unix)]
fn pid_runs(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the pid exists.
    let r = unsafe { libc::kill(pid, 0) };
    r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn pid_runs(_pid: u32) -> bool {
    false
}

#[cfg(test)]
#[path = "ssh_forward_owners_tests.rs"]
mod tests;
