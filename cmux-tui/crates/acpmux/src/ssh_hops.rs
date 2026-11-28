//! Who owns each ssh hop a peer starts (its `-W` tunnel, a path probe's tunnel, a token or
//! listener read), so none outlives the daemon that started it, and how many one host may have.
//!
//! A hop is the daemon's direct child, spawned `kill_on_drop`: it ends when its owner drops it,
//! but nothing ends it when the daemon itself goes without running drops (a NIGHTLY install's
//! take-over, a crash, an `exit`). It is reparented to pid 1 and stays as long as its channel
//! does. So every hop is recorded before it is used: one file per hop in
//! `$ACPMUX_HOME/run/ssh-hops/`, naming the daemon that owns it and the hop, each by pid and start
//! time. The hop's exit (the kernel's event, `proc_exit.rs`) takes its record away and gives its
//! host's slot back; at start, and every [`SWEEP_EVERY`] after, [`reap_recorded`] ends the hops a
//! dead owner recorded: only a recorded pid whose start time still matches, never a process found
//! by name or by scanning, and never its process group.
//!
//! Not a hop: a host's shared master (`peer_ssh_master.rs`). ssh forks it off the first hop once
//! it logged in (ControlPersist), so it has a pid of its own that nothing recorded, runs in a
//! session of its own, outlives daemon restarts by design, and ends `CONTROL_PERSIST_SECS` after
//! its last channel. Its ProxyCommand (a fleet relay) shares the first hop's process group, which
//! is why a hop is ended by its pid alone: a signal to the group would end the master's relay.
//!
//! A host has at most [`MAX_PER_HOST`] hops open at once; one more is refused with a reason, so a
//! redial loop cannot pile them up.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

/// The hops one host may have open at once. A peer holds one for its link, one per path probe
/// and one per read beside them: a handful. Past this something redials without ending.
pub(crate) const MAX_PER_HOST: usize = 12;

/// How often a running daemon sweeps the ledger, so the hops of a daemon that went while this
/// one already ran (a handoff) end within this, not at the next start.
pub(crate) const SWEEP_EVERY: Duration = Duration::from_secs(60);

/// The records read in one sweep, so a sweep costs the same however many were left.
const MAX_RECORDS: usize = 4096;

/// The ledger under an acpmux home.
pub(crate) fn ledger_dir(home: &Path) -> PathBuf {
    home.join("run").join("ssh-hops")
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    /// The daemon that started the hop, and its start time (`owner_exit::process_start`).
    pub owner: u32,
    pub owner_start: Option<u64>,
    /// The hop's ssh, and its start time.
    pub pid: u32,
    pub start: Option<u64>,
    /// The ssh destination.
    pub host: String,
    /// Seconds since the epoch when it was started.
    pub opened: u64,
}

/// Counts for `gauges.links` (`sshHops*`).
#[derive(Default)]
pub(crate) struct Counts {
    /// Hops open now.
    pub open: AtomicU64,
    /// Hops refused because their host had [`MAX_PER_HOST`] open.
    pub refused: AtomicU64,
    /// Hops a dead owner left, ended by a sweep.
    pub reaped: AtomicU64,
}

pub(crate) fn counts() -> &'static Counts {
    static COUNTS: std::sync::OnceLock<Counts> = std::sync::OnceLock::new();
    COUNTS.get_or_init(Counts::default)
}

/// Open hops by host.
fn live() -> &'static Mutex<HashMap<String, usize>> {
    // test-hook-allow: holds no hook; the process's one count of its open hops, keyed by host
    static LIVE: std::sync::OnceLock<Mutex<HashMap<String, usize>>> = std::sync::OnceLock::new();
    LIVE.get_or_init(Default::default)
}

/// The hops open now to `host`.
pub(crate) fn open_to(host: &str) -> usize {
    live().lock().unwrap_or_else(|e| e.into_inner()).get(host).copied().unwrap_or(0)
}

/// One open hop's slot and record: given back when dropped (the hop exited, or it could not be
/// watched).
struct Slot {
    host: String,
    file: Option<PathBuf>,
}

impl Slot {
    fn take(host: &str) -> io::Result<Self> {
        let mut live = live().lock().unwrap_or_else(|e| e.into_inner());
        let open = live.entry(host.to_owned()).or_insert(0);
        if *open >= MAX_PER_HOST {
            counts().refused.fetch_add(1, Ordering::Relaxed);
            return Err(io::Error::other(format!(
                "{host} has {open} ssh hops open, the most one host may have ({MAX_PER_HOST})"
            )));
        }
        *open += 1;
        counts().open.fetch_add(1, Ordering::Relaxed);
        Ok(Self { host: host.to_owned(), file: None })
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        if let Some(file) = self.file.take() {
            let _ = crate::home_fs::remove_file(file);
        }
        let mut live = live().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(open) = live.get_mut(&self.host) {
            *open = open.saturating_sub(1);
            if *open == 0 {
                live.remove(&self.host);
            }
        }
        drop(live);
        let less = |v: u64| Some(v.saturating_sub(1));
        let _ = counts().open.fetch_update(Ordering::Relaxed, Ordering::Relaxed, less);
    }
}

/// Spawns the hop `command` (an ssh to `host`) under its host's cap, recorded in `ledger` (None:
/// counted, not recorded) until it exits. The caller owns the child as before (`kill_on_drop`).
pub(crate) fn spawn(
    command: &mut tokio::process::Command,
    host: &str,
    ledger: Option<&Path>,
) -> io::Result<tokio::process::Child> {
    let mut slot = Slot::take(host)?;
    let child = command.spawn()?;
    let Some(pid) = child.id() else { return Ok(child) };
    let start = crate::owner_exit::process_start(pid);
    if let Some(ledger) = ledger {
        let me = std::process::id();
        let record = Record {
            owner: me,
            owner_start: own_start(),
            pid,
            start,
            host: host.to_owned(),
            opened: now_secs(),
        };
        match write_record(ledger, &record) {
            Ok(file) => slot.file = Some(file),
            Err(e) => tracing::warn!(%host, pid, "recording an ssh hop: {e:#}"),
        }
    }
    // The slot goes with the hop's exit; where exits cannot be watched it goes now (the hop is
    // still owned by the caller's drop, but uncounted and unrecorded).
    if let Err(e) = crate::proc_exit::watch(pid, start, move || drop(slot)) {
        static SAID: std::sync::Once = std::sync::Once::new();
        SAID.call_once(|| tracing::warn!("ssh hops are not counted on this host: {e}"));
    }
    Ok(child)
}

fn own_start() -> Option<u64> {
    static START: std::sync::OnceLock<Option<u64>> = std::sync::OnceLock::new();
    *START.get_or_init(|| crate::owner_exit::process_start(std::process::id()))
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn write_record(ledger: &Path, record: &Record) -> anyhow::Result<PathBuf> {
    crate::home_fs::private_dir(ledger)?;
    let name = format!("{}-{}.json", record.pid, record.start.unwrap_or(0));
    let file = ledger.join(&name);
    let tmp = ledger.join(format!(".{name}.tmp"));
    crate::home_fs::write(&tmp, serde_json::to_vec(record)?)?;
    crate::home_fs::rename(&tmp, &file)?;
    Ok(file)
}

/// What one sweep did.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Reaped {
    /// Hops a dead owner left, still running: ended (SIGKILL to the recorded pid).
    pub ended: usize,
    /// Records of a dead owner whose hop was gone already (or is not provably it): removed.
    pub gone: usize,
    /// Records kept: their owner still runs.
    pub kept: usize,
}

/// Ends every hop recorded in `ledger` whose owner no longer runs, and removes its record. A hop
/// is signalled only when a process still runs at its recorded pid with its recorded start time;
/// anything less proves nothing, so only the record goes. Blocking (a few file reads): run it off
/// the runtime's workers.
pub(crate) fn reap_recorded(ledger: &Path) -> Reaped {
    reap_with(ledger, &crate::owner_exit::process_start)
}

pub(crate) fn reap_with(ledger: &Path, process_start: &dyn Fn(u32) -> Option<u64>) -> Reaped {
    let mut reaped = Reaped::default();
    let Ok(entries) = std::fs::read_dir(ledger) else { return reaped };
    let now = SystemTime::now();
    for entry in entries.flatten().take(MAX_RECORDS) {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            // A record whose writer died before its rename; the rename comes right after.
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
        if owner_runs(&record, process_start) {
            reaped.kept += 1;
            continue;
        }
        let same = record.start.is_some() && process_start(record.pid) == record.start;
        if same && kill(record.pid) {
            tracing::info!(host = %record.host, pid = record.pid, owner = record.owner,
                "ended an ssh hop its daemon left");
            counts().reaped.fetch_add(1, Ordering::Relaxed);
            reaped.ended += 1;
        } else {
            reaped.gone += 1;
        }
        let _ = crate::home_fs::remove_file(&path);
    }
    reaped
}

/// Whether the record's owner still runs: this process (its own open hops), or a process at the
/// owner's pid with the owner's start time. With no start time recorded, a live pid counts.
fn owner_runs(record: &Record, process_start: &dyn Fn(u32) -> Option<u64>) -> bool {
    if record.owner == std::process::id() {
        return record.owner_start.is_none() || record.owner_start == own_start();
    }
    match record.owner_start {
        Some(start) => process_start(record.owner) == Some(start),
        None => process_start(record.owner).is_some(),
    }
}

#[cfg(unix)]
fn kill(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 1 {
        return false;
    }
    // SAFETY: SIGKILL to one pid whose start time was just matched to the record's.
    unsafe { libc::kill(pid, libc::SIGKILL) == 0 }
}

#[cfg(not(unix))]
fn kill(_pid: u32) -> bool {
    false
}

/// The start sweep, then one every [`SWEEP_EVERY`], for the daemon's life.
pub(crate) fn spawn_sweeps(ledger: PathBuf) {
    tokio::spawn(async move {
        let mut every = tokio::time::interval(SWEEP_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            let dir = ledger.clone();
            let Ok(reaped) = tokio::task::spawn_blocking(move || reap_recorded(&dir)).await else {
                continue;
            };
            if reaped.ended + reaped.gone > 0 {
                tracing::info!(
                    ended = reaped.ended,
                    gone = reaped.gone,
                    kept = reaped.kept,
                    "swept ssh hops left by a daemon that went"
                );
            }
        }
    });
}

#[cfg(test)]
#[path = "ssh_hops_tests.rs"]
mod tests;
