//! One total per session across all its scopes, and one for every agent host scope together
//! (`session_budget.rs` [`Total`] sizes them).
//!
//! Before this, each scope acpmux made had its own ceiling and nothing capped their sum: a session
//! whose harness scope and three background task scopes each sat under their 20 GB ceiling held
//! 80 GB, and the hosts slice had no limit at all. Now a session's harness scope
//! (`session_scope.rs`) and its background task scopes (`hub/bg_tasks.rs`,
//! `agent_host/scope.rs`) join the transient slice `acpmuxsessions-<id>.slice` (a dash nests it
//! under `acpmuxsessions.slice`, so the all-sessions cap still holds), made here with the
//! session's total before its first scope joins it. The kernel enforces the sum: two scopes of one
//! session that together pass the total are OOM-killed inside that session only.
//!
//! - Made with `StartTransientUnit` over `busctl` (bounded by the caller's wait); one that already
//!   exists is used as it is. Any failure falls back to the shared slice, as before.
//! - An empty session slice stays active in systemd until stopped, so the budget watcher
//!   (`hub/session_budget_watch.rs`) stops one that held no scope for [`EMPTY_FOR`] ([`Sweep`]):
//!   the user manager keeps no unit per finished session.
//! - `acpmuxhosts.slice` gets its total as a runtime drop-in (`session_scope::limit_slice`) when
//!   the watcher starts.
//! - Off: all three session total knobs 0 (no per-session slice); `ACPMUX_HOSTS_*` 0 each.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use crate::session_budget::Total;
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

/// The prefix of a session's slice (a dash nests it under `acpmuxsessions.slice`).
pub(crate) const PREFIX: &str = "acpmuxsessions-";
/// How long a session slice may hold no scope before the watcher stops it: well past the moment
/// between its making and its first scope joining it.
pub(crate) const EMPTY_FOR: Duration = Duration::from_secs(120);
/// The most session slices one sweep reads.
pub(crate) const MAX_SLICES: usize = 4096;

/// The slice of `session`: its letters and digits (a dash would nest further), at most 64; None
/// for an id with none.
pub(crate) fn slice_name(session: &str) -> Option<String> {
    let key: String = session.chars().filter(char::is_ascii_alphanumeric).take(64).collect();
    (!key.is_empty()).then(|| format!("{PREFIX}{key}.slice"))
}

/// The `busctl` arguments that make the transient `slice` with `total`.
pub(crate) fn busctl_args(slice: &str, total: &Total) -> Vec<String> {
    let props = total.bus_properties();
    let mut args: Vec<String> = [
        "--user",
        "--quiet",
        "call",
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        "ssa(sv)a(sa(sv))",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    args.extend([slice.to_owned(), "fail".into(), (1 + props.len()).to_string()]);
    args.extend(["Description".into(), "s".into(), format!("acpmux session total {slice}")]);
    for p in props {
        args.extend(p);
    }
    args.push("0".into());
    args
}

/// Whether `busctl`'s error text says the unit is already there (made by an earlier scope).
pub(crate) fn already_exists(stderr: &str) -> bool {
    stderr.contains("already exists") || stderr.contains("already loaded")
}

/// The session's total from the profile's `env` and the daemon's `limits`.
fn session_total(
    env: &BTreeMap<String, String>,
    limits: crate::session_scope::SessionLimits,
) -> Total {
    let host = crate::session_budget::this_host();
    let get = crate::session_scope::knob_reader(env, limits);
    let budget = crate::session_budget::Budget::read(&get, &host);
    crate::session_budget::session_total_from(&get, &host, &budget)
}

/// Makes `session`'s slice with its total; its name, or None (off, or not made: the caller uses
/// the shared slice). Blocking, bounded by `session_scope::run_bounded`'s wait.
#[cfg(target_os = "linux")]
pub(crate) fn ensure_blocking(
    session: &str,
    env: &BTreeMap<String, String>,
    limits: crate::session_scope::SessionLimits,
) -> Option<String> {
    let total = session_total(env, limits);
    let slice = slice_name(session).filter(|_| total.on())?;
    let busctl = crate::agent_host::scope::BUSCTL
        .iter()
        .find(|p| std::path::Path::new(p).is_file())
        .map(std::path::Path::new)?;
    let args = busctl_args(&slice, &total);
    let made = crate::session_scope::run_bounded(busctl, &args, &BTreeMap::new(), false);
    // run_bounded drops the error text; a slice already there is the usual reason, and a
    // scope that names a slice systemd lacks still starts (in an unlimited one).
    if made.is_none() && !exists(&slice) {
        tracing::warn!("could not make {slice}: the session's scopes share no total");
        return None;
    }
    Some(slice)
}

/// Whether `slice` is loaded and active in the user manager (its cgroup directory exists).
#[cfg(target_os = "linux")]
fn exists(slice: &str) -> bool {
    std::fs::read_to_string("/proc/self/cgroup")
        .ok()
        .as_deref()
        .and_then(crate::session_disk::manager_dir)
        .is_some_and(|m| {
            std::path::Path::new(&format!("{m}/{}/{slice}", crate::session_scope::SESSIONS_SLICE))
                .is_dir()
        })
}

/// [`ensure_blocking`] for an async caller (a background task's placement), with the daemon's
/// limits and no profile env, bounded by `wait`.
#[cfg(target_os = "linux")]
pub(crate) async fn ensure(session: &str, wait: Duration) -> Option<String> {
    let total = session_total(&BTreeMap::new(), crate::session_scope::daemon_limits());
    let slice = slice_name(session).filter(|_| total.on())?;
    let busctl =
        crate::agent_host::scope::BUSCTL.iter().find(|p| std::path::Path::new(p).is_file())?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let env = crate::agent_host::scope::busctl_env(
        std::env::var_os("XDG_RUNTIME_DIR"),
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        uid,
    );
    let output = tokio::time::timeout(
        wait,
        tokio::process::Command::new(busctl)
            .args(busctl_args(&slice, &total))
            .env_clear()
            .envs(env)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    if output.status.success() || already_exists(&stderr) {
        return Some(slice);
    }
    tracing::warn!("could not make {slice} ({}): the task shares no total", stderr.trim());
    None
}

/// No session slices off Linux.
#[cfg(not(target_os = "linux"))]
pub(crate) fn ensure_blocking(
    _session: &str,
    _env: &BTreeMap<String, String>,
    _limits: crate::session_scope::SessionLimits,
) -> Option<String> {
    None
}

/// No session slices off Linux.
#[cfg(not(target_os = "linux"))]
pub(crate) async fn ensure(_session: &str, _wait: Duration) -> Option<String> {
    None
}

/// Stops the session slices under `manager` that held no scope for [`EMPTY_FOR`] (the watcher's
/// tick; blocking): the user manager keeps no unit per finished session.
#[cfg(target_os = "linux")]
pub(crate) fn sweep_blocking(manager: &str) -> usize {
    static SWEEP: std::sync::Mutex<Sweep> =
        std::sync::Mutex::new(Sweep { empty_since: BTreeMap::new() });
    let slices = session_slices(manager);
    let stop = SWEEP.lock().unwrap_or_else(|e| e.into_inner()).tick(&slices, Instant::now());
    stop.iter().filter(|slice| stop_blocking(slice)).count()
}

/// The watcher's memory of session slices with no scope.
#[derive(Debug, Default)]
pub(crate) struct Sweep {
    pub empty_since: BTreeMap<String, Instant>,
}

impl Sweep {
    /// Given each session slice and whether it holds a scope, at `now`: the ones to stop (empty
    /// for [`EMPTY_FOR`]). Slices that went away are forgotten.
    pub(crate) fn tick(&mut self, slices: &[(String, bool)], now: Instant) -> Vec<String> {
        let mut next = BTreeMap::new();
        let mut stop = Vec::new();
        for (slice, busy) in slices {
            if *busy {
                continue;
            }
            let since = self.empty_since.get(slice).copied().unwrap_or(now);
            if now.saturating_duration_since(since) >= EMPTY_FOR {
                stop.push(slice.clone());
            } else {
                next.insert(slice.clone(), since);
            }
        }
        self.empty_since = next;
        stop
    }
}

/// Each session slice under `manager` (`session_disk::manager_dir`) and whether it holds a scope.
pub(crate) fn session_slices(manager: &str) -> Vec<(String, bool)> {
    let dir = format!("{manager}/{}", crate::session_scope::SESSIONS_SLICE);
    let Ok(entries) = std::fs::read_dir(&dir) else { return Vec::new() };
    entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with(PREFIX) && n.ends_with(".slice"))
        .take(MAX_SLICES)
        .map(|n| {
            let busy = std::fs::read_dir(format!("{dir}/{n}")).is_ok_and(|mut d| {
                d.any(|e| e.is_ok_and(|e| e.file_name().to_string_lossy().ends_with(".scope")))
            });
            (n, busy)
        })
        .collect()
}

/// Stops the session slice `slice` (`StopUnit`), bounded. Blocking.
#[cfg(target_os = "linux")]
pub(crate) fn stop_blocking(slice: &str) -> bool {
    let Some(busctl) = crate::agent_host::scope::BUSCTL
        .iter()
        .find(|p| std::path::Path::new(p).is_file())
        .map(std::path::Path::new)
    else {
        return false;
    };
    let args: Vec<String> = [
        "--user",
        "--quiet",
        "call",
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StopUnit",
        "ss",
        slice,
        "fail",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    crate::session_scope::run_bounded(busctl, &args, &BTreeMap::new(), false).is_some()
}

/// Sets `acpmuxhosts.slice`'s total (a runtime drop-in, only what differs). Blocking.
#[cfg(target_os = "linux")]
pub(crate) fn limit_hosts_slice(total: &Total) {
    let Some(systemctl) = ["/usr/bin/systemctl", "/bin/systemctl"]
        .into_iter()
        .map(std::path::Path::new)
        .find(|p| p.is_file())
    else {
        return;
    };
    let wanted = total.properties();
    let slice = crate::agent_host::scope::HOST_SLICE;
    if let Err(e) = crate::session_scope::limit_slice(systemctl, slice, &wanted, &BTreeMap::new()) {
        tracing::warn!("{e}: {slice} may lack its total");
    }
}

#[cfg(test)]
#[path = "session_total_tests.rs"]
mod tests;
