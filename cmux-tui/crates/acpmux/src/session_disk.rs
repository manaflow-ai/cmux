//! Each session's disk budget (`session_budget.rs`), measured: the kernel has no per-scope disk
//! limit on our lane VMs (no project quota, no `io` controller in the user manager), so the
//! daemon reads what each acpmux scope's live processes wrote and kept, and what the session's
//! own temporary directory holds, once a [`TICK`].
//!
//! - Use: per scope, the sum over its live processes of `/proc/<pid>/io` `write_bytes` less
//!   `cancelled_write_bytes` (what it wrote and did not delete before writeback), or the size of
//!   the session's `ACPMUX_SESSION_TMPDIR`, whichever is larger. A 20 GB file writer shows while
//!   it writes; a build's many short compilers each count only while they run.
//! - Bounded: at most [`MAX_SCOPES`] scopes and [`MAX_PIDS`] processes a tick, and at most
//!   [`MAX_TMP_ENTRIES`] entries of a temporary directory (then its size is a floor, `partial`).
//!   No worktree is walked. The cost is the processes acpmux scopes hold, which their `TasksMax`
//!   caps, never the files on disk.
//! - A scope over its budget is warned once in its chat. One over its budget while the home
//!   filesystem's free space is under the host's floor (registry `lanes.free_gb_floor`, else
//!   10 GB) has its top writer's process group stopped (SIGSTOP: throttled, not killed), unless
//!   that group is one of the scope's own (`Known::protected`: the groups it held when the
//!   watcher first saw it, the harness or a task's runner): then it is only
//!   warned. A stopped group gets SIGCONT once free space is back over twice the floor.
//! - Restart: every group the watcher stops is written to [`LEDGER`] in acpmux's home before
//!   the SIGSTOP. A daemon start resumes (SIGCONT) each group listed there whose processes are
//!   still in that scope, then empties it, whether or not the watcher is on, so no chat stays
//!   frozen because the daemon that stopped it went away. Only listed groups are resumed: a
//!   group a session stopped itself (a debugger, a test's SIGSTOP) is left alone.
//! - Off: `ACPMUX_SESSION_DISK_WATCH=0`, or a disk budget of 0 (`ACPMUX_SESSION_DISK_MB=0`,
//!   `session.diskMb` 0).
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::time::Duration;

/// How often the watcher measures.
pub(crate) const TICK: Duration = Duration::from_secs(15);
/// How often while the host's free disk is under twice its floor: a `dd` writes 2 GB in 6 s
/// here (gcp-agent-lane-8, 2026-11-24), so at [`TICK`] a 20 GB writer would run 5 GB past its
/// budget before the watcher saw it.
pub(crate) const LOW_TICK: Duration = Duration::from_secs(2);

/// The wait before the next reading, with `free` bytes free on a host whose floor is `floor`.
pub(crate) fn next_tick(free: u64, floor: u64) -> Duration {
    if free < floor.saturating_mul(2) { LOW_TICK } else { TICK }
}
/// The most scopes, processes and temporary-directory entries one tick reads.
pub(crate) const MAX_SCOPES: usize = 1024;
pub(crate) const MAX_PIDS: usize = 32_768;
pub(crate) const MAX_TMP_ENTRIES: usize = 2_000;
/// How many scopes `daemon status` lists besides the ones over budget.
const LISTED: usize = 8;

/// One process's `/proc/<pid>/io` bytes it wrote and kept.
pub(crate) fn kept_bytes(io: &str) -> u64 {
    let field = |name: &str| {
        io.lines()
            .find_map(|l| l.strip_prefix(name)?.strip_prefix(':'))
            .and_then(|v| v.trim().parse::<u64>().ok())
            .unwrap_or(0)
    };
    field("write_bytes").saturating_sub(field("cancelled_write_bytes"))
}

/// What the watcher reads once per scope, the first tick it sees it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Known {
    /// `ACPMUX_SESSION_ID` and `ACPMUX_SESSION_TMPDIR` from one of its processes.
    pub session: Option<String>,
    pub tmp: Option<String>,
    /// The process groups never stopped: the ones it held when first seen (a scope starts with
    /// its harness or task runner alone; one that was already running when the daemon started
    /// keeps every group it had, so it is only warned).
    pub protected: Vec<i32>,
}

/// One scope's reading.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Sample {
    pub scope: String,
    pub session: Option<String>,
    pub written: u64,
    pub tmp: u64,
    pub tmp_partial: bool,
    /// The process group of the top writer, and the groups never stopped (`Known::protected`).
    pub top_pgid: Option<i32>,
    pub protected: Vec<i32>,
    pub memory: u64,
    pub tasks: u64,
}

impl Sample {
    pub(crate) fn used(&self) -> u64 {
        self.written.max(self.tmp)
    }
}

/// What the watcher holds for a scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum State {
    #[default]
    Ok,
    /// Over its budget, warned.
    Over,
    /// Its process group `pgid` stopped.
    Stopped(i32),
}

/// What to do for a scope this tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Action {
    Warn,
    /// Over with the disk low, but the writer is the scope's own leader: warned, not stopped.
    WarnUnstoppable,
    Stop(i32),
    Resume(i32),
}

/// The next state of a scope in `prev` that uses `used` of `budget`, with `free` bytes free on a
/// host whose floor is `floor`.
pub(crate) fn decide(
    prev: State,
    sample: &Sample,
    budget: u64,
    free: u64,
    floor: u64,
) -> (State, Option<Action>) {
    let used = sample.used();
    if let State::Stopped(g) = prev {
        // Resumed once the disk recovered, or the budget was turned off.
        if budget == 0 || free >= floor.saturating_mul(2) {
            return (
                if budget > 0 && used > budget { State::Over } else { State::Ok },
                Some(Action::Resume(g)),
            );
        }
        return (prev, None);
    }
    if budget == 0 || used <= budget {
        return (State::Ok, None);
    }
    if free < floor {
        return match sample.top_pgid.filter(|g| !sample.protected.contains(g) && *g > 1) {
            Some(g) => (State::Stopped(g), Some(Action::Stop(g))),
            None if prev == State::Ok => (State::Over, Some(Action::WarnUnstoppable)),
            None => (prev, None),
        };
    }
    match prev {
        State::Ok => (State::Over, Some(Action::Warn)),
        _ => (prev, None),
    }
}

/// The watcher's memory across ticks.
#[derive(Debug, Default)]
pub(crate) struct Watch {
    pub states: BTreeMap<String, State>,
    /// Each scope's session, read once from one of its processes' environment.
    pub sessions: BTreeMap<String, Known>,
    pub last: Vec<Sample>,
    pub free: u64,
    pub floor: u64,
    pub budget: u64,
    pub truncated: bool,
    pub ticks: u64,
}

impl Watch {
    /// Applies a tick's `samples`; the actions with each scope's sample. Scopes that went away
    /// are forgotten (a stopped one's group went with it).
    pub(crate) fn apply(&mut self, samples: Vec<Sample>) -> Vec<(Sample, Action)> {
        let mut actions = Vec::new();
        let mut states = BTreeMap::new();
        for s in &samples {
            let prev = self.states.get(&s.scope).copied().unwrap_or_default();
            let (next, action) = decide(prev, s, self.budget, self.free, self.floor);
            states.insert(s.scope.clone(), next);
            if let Some(a) = action {
                actions.push((s.clone(), a));
            }
        }
        self.sessions.retain(|scope, _| states.contains_key(scope));
        self.states = states;
        self.last = samples;
        self.ticks += 1;
        actions
    }

    /// `daemon status`'s `sessionBudgets.watch`.
    pub(crate) fn json(&self, enabled: bool) -> Value {
        let state_word = |scope: &str| match self.states.get(scope).copied().unwrap_or_default() {
            State::Ok => json!("ok"),
            State::Over => json!("over"),
            State::Stopped(_) => json!("stopped"),
        };
        let mut rows: Vec<&Sample> = self.last.iter().collect();
        rows.sort_by_key(|s| std::cmp::Reverse(s.used()));
        let listed: Vec<Value> = rows
            .iter()
            .enumerate()
            .filter(|(i, s)| {
                *i < LISTED || self.states.get(&s.scope).is_some_and(|st| *st != State::Ok)
            })
            .map(|(_, s)| {
                json!({
                    "scope": s.scope, "sessionId": s.session, "diskBytes": s.used(),
                    "writtenBytes": s.written, "tmpBytes": s.tmp, "tmpPartial": s.tmp_partial,
                    "memoryBytes": s.memory, "tasks": s.tasks, "state": state_word(&s.scope),
                    "stoppedPgid": match self.states.get(&s.scope) {
                        Some(State::Stopped(g)) => json!(g), _ => Value::Null },
                })
            })
            .collect();
        json!({
            "enabled": enabled,
            "tickSeconds": next_tick(self.free, self.floor).as_secs(),
            "ticks": self.ticks,
            "freeBytes": self.free,
            "floorBytes": self.floor,
            "scopes": self.last.len(),
            "truncated": self.truncated,
            "use": listed,
        })
    }
}

/// The process-wide watch (one daemon per process).
pub(crate) fn shared() -> &'static std::sync::Mutex<Watch> {
    static WATCH: std::sync::OnceLock<std::sync::Mutex<Watch>> = std::sync::OnceLock::new();
    WATCH.get_or_init(Default::default)
}

/// Whether the watcher runs (`ACPMUX_SESSION_DISK_WATCH=0` turns it off).
pub(crate) fn enabled() -> bool {
    cfg!(target_os = "linux")
        && !std::env::var("ACPMUX_SESSION_DISK_WATCH").is_ok_and(|v| v.trim() == "0")
}

/// The user manager's cgroup directory this daemon runs under, from `/proc/self/cgroup` text.
pub(crate) fn manager_dir(cgroup: &str) -> Option<String> {
    let path = crate::agent_host::scope::unified(cgroup)?;
    let mut out = String::from("/sys/fs/cgroup");
    for part in path.split('/').filter(|p| !p.is_empty()) {
        out.push('/');
        out.push_str(part);
        if part.starts_with("user@") && part.ends_with(".service") {
            return Some(out);
        }
    }
    None
}

/// The size of `dir`, reading at most `max` entries: `(bytes, partial)`.
pub(crate) fn dir_size(dir: &std::path::Path, max: usize) -> (u64, bool) {
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    let (mut bytes, mut seen) = (0u64, 0usize);
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            seen += 1;
            if seen > max {
                return (bytes, true);
            }
            let Ok(m) = e.metadata() else { continue };
            if m.is_dir() {
                stack.push(e.path());
            } else {
                #[cfg(unix)]
                {
                    bytes = bytes.saturating_add(m.blocks().saturating_mul(512));
                }
                #[cfg(not(unix))]
                {
                    bytes = bytes.saturating_add(m.len());
                }
            }
        }
    }
    (bytes, false)
}

/// Reads every acpmux scope under `manager` (`manager_dir`): the samples, and whether a bound cut
/// the read short. `known` is each scope's session and temporary directory already read.
#[cfg(target_os = "linux")]
pub(crate) fn scan(manager: &str, known: &mut BTreeMap<String, Known>) -> (Vec<Sample>, bool) {
    let read = |p: &str| std::fs::read_to_string(p).ok();
    let (mut samples, mut pids_read, mut truncated) = (Vec::new(), 0usize, false);
    let mut slices: Vec<String> =
        [crate::session_scope::SESSIONS_SLICE, crate::agent_host::scope::HOST_SLICE]
            .into_iter()
            .map(str::to_owned)
            .collect();
    // Each session's own slice (`session_total.rs`) holds its scopes under the sessions slice.
    slices.extend(
        crate::session_total::session_slices(manager)
            .into_iter()
            .map(|(name, _)| format!("{}/{name}", crate::session_scope::SESSIONS_SLICE)),
    );
    for slice in &slices {
        let Ok(entries) = std::fs::read_dir(format!("{manager}/{slice}")) else { continue };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".scope") {
                continue;
            }
            if samples.len() >= MAX_SCOPES || pids_read >= MAX_PIDS {
                truncated = true;
                break;
            }
            let dir = format!("{manager}/{slice}/{name}");
            let procs: Vec<u32> = read(&format!("{dir}/cgroup.procs"))
                .unwrap_or_default()
                .lines()
                .filter_map(|l| l.trim().parse().ok())
                .collect();
            let mut s = Sample { scope: name.clone(), ..Sample::default() };
            let mut top: Option<(u64, i32)> = None;
            let mut groups: Vec<i32> = Vec::new();
            for pid in procs.iter().copied() {
                if pids_read >= MAX_PIDS {
                    truncated = true;
                    break;
                }
                pids_read += 1;
                let kept = read(&format!("/proc/{pid}/io")).map_or(0, |io| kept_bytes(&io));
                s.written = s.written.saturating_add(kept);
                // SAFETY: getpgid takes any pid; a gone one is -1.
                let pgid = unsafe { libc::getpgid(pid as i32) };
                if pgid <= 0 {
                    continue;
                }
                if !groups.contains(&pgid) {
                    groups.push(pgid);
                }
                if top.is_none_or(|(k, _)| kept > k) {
                    top = Some((kept, pgid));
                }
            }
            s.top_pgid = top.filter(|(k, _)| *k > 0).map(|(_, g)| g);
            let known = known.entry(name.clone()).or_insert_with(|| {
                let (session, tmp) = procs
                    .iter()
                    .find_map(|pid| {
                        let env = crate::agent_host::tree::environ(*pid)?;
                        let get =
                            |k: &str| env.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
                        Some((get("ACPMUX_SESSION_ID"), get("ACPMUX_SESSION_TMPDIR")))
                    })
                    .unwrap_or((None, None));
                Known { session, tmp, protected: groups.clone() }
            });
            s.protected = known.protected.clone();
            s.session = known.session.clone();
            if let Some(tmp) = &known.tmp {
                (s.tmp, s.tmp_partial) = dir_size(std::path::Path::new(tmp), MAX_TMP_ENTRIES);
            }
            s.memory = read(&format!("{dir}/memory.current"))
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or(0);
            s.tasks = read(&format!("{dir}/pids.current"))
                .and_then(|v| v.trim().parse().ok())
                .unwrap_or(0);
            samples.push(s);
        }
    }
    (samples, truncated)
}

/// The file in acpmux's home listing the groups the watcher holds stopped.
pub(crate) const LEDGER: &str = "session-disk-stopped.json";

/// One group the watcher stopped: its scope and process group.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoppedGroup {
    pub scope: String,
    pub pgid: i32,
}

impl Watch {
    /// The groups held stopped now, sorted (what [`LEDGER`] lists).
    pub(crate) fn stopped(&self) -> Vec<StoppedGroup> {
        self.states
            .iter()
            .filter_map(|(scope, st)| match st {
                State::Stopped(g) => Some(StoppedGroup { scope: scope.clone(), pgid: *g }),
                _ => None,
            })
            .collect()
    }
}

/// The groups [`LEDGER`] in `home` lists; none when it is missing or unreadable.
pub(crate) fn read_ledger(home: &std::path::Path) -> Vec<StoppedGroup> {
    std::fs::read(home.join(LEDGER))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Writes `groups` to [`LEDGER`] in `home` (atomically: a temporary file, then a rename); an
/// empty list removes the file.
pub(crate) fn write_ledger(home: &std::path::Path, groups: &[StoppedGroup]) -> std::io::Result<()> {
    let path = home.join(LEDGER);
    if groups.is_empty() {
        return match std::fs::remove_file(&path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        };
    }
    std::fs::create_dir_all(home)?;
    let tmp = home.join(format!("{LEDGER}.tmp"));
    std::fs::write(&tmp, serde_json::to_vec(groups).map_err(std::io::Error::other)?)?;
    std::fs::rename(&tmp, &path)
}

/// Whether a process of group `pgid` is still in `scope` under `manager` (`manager_dir`): a
/// group id can be reused once its processes are gone, and a group in another scope is not ours.
#[cfg(target_os = "linux")]
fn group_in_scope(manager: &str, scope: &str, pgid: i32) -> bool {
    [crate::session_scope::SESSIONS_SLICE, crate::agent_host::scope::HOST_SLICE].iter().any(
        |slice| {
            std::fs::read_to_string(format!("{manager}/{slice}/{scope}/cgroup.procs"))
                .unwrap_or_default()
                .lines()
                .filter_map(|l| l.trim().parse::<i32>().ok())
                // SAFETY: getpgid takes any pid; a gone one is -1.
                .any(|pid| unsafe { libc::getpgid(pid) } == pgid)
        },
    )
}

/// At a daemon start: resumes (`signal`, SIGCONT) every group [`LEDGER`] in `home` lists whose
/// processes are still in its scope, then empties the ledger. The groups resumed.
#[cfg(target_os = "linux")]
pub(crate) fn resume_left_stopped(
    home: &std::path::Path,
    manager: &str,
    mut signal: impl FnMut(i32) -> bool,
) -> Vec<StoppedGroup> {
    let left = read_ledger(home);
    let resumed: Vec<StoppedGroup> = left
        .into_iter()
        .filter(|g| group_in_scope(manager, &g.scope, g.pgid) && signal(g.pgid))
        .collect();
    if let Err(e) = write_ledger(home, &[]) {
        tracing::warn!("could not empty {LEDGER}: {e}");
    }
    resumed
}

/// Sends `signal` to process group `pgid` (never 0 or 1, never this process's group).
#[cfg(unix)]
pub(crate) fn signal_group(pgid: i32, signal: i32) -> bool {
    // SAFETY: getpgrp has no preconditions.
    if pgid <= 1 || pgid == unsafe { libc::getpgrp() } {
        return false;
    }
    // SAFETY: a signal to a process group the watcher read from a scope this daemon made.
    unsafe { libc::kill(-pgid, signal) == 0 }
}

#[cfg(test)]
#[path = "session_disk_tests.rs"]
mod tests;
