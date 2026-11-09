//! Terminal hosts that no live session owns are ended after a grace (Leo
//! 2026-11-09: "well those need to get auto cleaned up...").
//!
//! A session owner adopts, recovers (cx-0tgl LC, `orphan_hosts.rs`) or ends
//! every host under its own record root at its start. A host under the root
//! of another session of the same state root is seen by no one while that
//! session never starts again: a normal install's host has no orphan grace
//! (cx-t2sqm D1), so it kept its shell and PTY until reboot. This owner
//! looks at those roots off its restore, on its own thread: a first pass a
//! while after it answers, then one every [`PASS_INTERVAL`].
//!
//! The kill rule. A host is ended only when both hold:
//! 1. no live daemon can own it: its session's guard (`session-locks/`, held
//!    by every owner from its registry open to its exit) is free, and this
//!    owner holds that guard while it ends the host, so the session cannot
//!    start and adopt it meanwhile (such a start fails as during a session
//!    reset, and the app's next ensure starts it). A session whose guard is
//!    held is never touched, and its hosts' times start over;
//! 2. it has been seen that way for its grace, counted from the first pass
//!    that saw it, kept across restarts in this session's directory
//!    ([`STORE_FILE`]), so an owner in a restart loop still reaps.
//!
//! Graces: [`LIVE_SHELL_GRACE`] for a host whose shell still runs (the user's
//! work may be in it: a session that has not started for a day while this
//! one ran is taken as gone; its tab, if it comes back, starts a new shell),
//! [`ENDED_SHELL_GRACE`] for one whose shell already ended (its exit
//! sidecar is written; nothing is lost but the PTY it holds). Only a host
//! proven live is ended (a dead one holds nothing; an unclear one is never
//! ended). Bounds: at most [`MAX_ROOTS_PER_PASS`] roots and
//! [`MAX_REAPS_PER_PASS`] ends per pass; a pass that reached the cap runs
//! again after [`CATCH_UP_INTERVAL`]. Restore never reads these roots.
//!
//! Debug builds only (test seams): `CMUX_TUI_TEST_UNOWNED_HOST_GRACE_MS`
//! replaces both graces, `CMUX_TUI_TEST_UNOWNED_HOST_INTERVAL_MS` the first
//! delay and every interval.

use std::collections::BTreeMap;
use std::path::PathBuf;

use super::*;
use crate::workspace_registry::{SessionOwnerProbe, probe_session_owner};

/// How long a host with a live shell must have no owner before it ends.
pub(crate) const LIVE_SHELL_GRACE: Duration = Duration::from_secs(24 * 60 * 60);
/// How long a host whose shell already ended must have no owner.
pub(crate) const ENDED_SHELL_GRACE: Duration = Duration::from_secs(10 * 60);
/// The first pass waits this long after the owner answers (its start burst).
const FIRST_PASS_DELAY: Duration = Duration::from_secs(2 * 60);
/// Between passes.
const PASS_INTERVAL: Duration = Duration::from_secs(60 * 60);
/// After a pass that reached [`MAX_REAPS_PER_PASS`].
const CATCH_UP_INTERVAL: Duration = Duration::from_secs(60);
const MAX_ROOTS_PER_PASS: usize = 64;
const MAX_REAPS_PER_PASS: usize = 4;
/// First-seen times kept at most (the oldest go first past it).
const MAX_STORE_ENTRIES: usize = 4096;
/// In this session's directory: when each unowned host was first seen.
pub(crate) const STORE_FILE: &str = "unowned-terminal-hosts.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Timing {
    live_grace: Duration,
    ended_grace: Duration,
    first_delay: Duration,
    interval: Duration,
    catch_up: Duration,
}

impl Timing {
    const STANDARD: Self = Self {
        live_grace: LIVE_SHELL_GRACE,
        ended_grace: ENDED_SHELL_GRACE,
        first_delay: FIRST_PASS_DELAY,
        interval: PASS_INTERVAL,
        catch_up: CATCH_UP_INTERVAL,
    };

    fn for_owner() -> Self {
        #[cfg(debug_assertions)]
        {
            let millis = |key: &str| {
                std::env::var(key)
                    .ok()
                    .and_then(|value| value.parse::<u64>().ok())
                    .map(Duration::from_millis)
            };
            let mut timing = Self::STANDARD;
            if let Some(grace) = millis("CMUX_TUI_TEST_UNOWNED_HOST_GRACE_MS") {
                timing.live_grace = grace;
                timing.ended_grace = grace;
            }
            if let Some(interval) = millis("CMUX_TUI_TEST_UNOWNED_HOST_INTERVAL_MS") {
                timing.first_delay = interval;
                timing.interval = interval;
                timing.catch_up = interval;
            }
            timing
        }
        #[cfg(not(debug_assertions))]
        Self::STANDARD
    }
}

/// What one pass saw.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct PassReport {
    /// Other sessions' roots looked at.
    pub(crate) roots: usize,
    /// Of them, roots whose session a live daemon owns.
    pub(crate) owned_roots: usize,
    /// Live hosts of unowned roots still in their grace.
    pub(crate) in_grace: usize,
    pub(crate) reaped: usize,
    /// Ends that failed (retried next pass).
    pub(crate) failed: usize,
    /// The pass stopped at a cap with more left.
    pub(crate) capped: bool,
}

/// The reaper thread of one owner; [`UnownedHostReaper::stop`] ends it
/// between two hosts.
pub struct UnownedHostReaper {
    stop: Arc<(Mutex<bool>, Condvar)>,
}

impl UnownedHostReaper {
    pub fn stop(self) {
        let (stopped, changed) = &*self.stop;
        *stopped.lock().unwrap_or_else(PoisonError::into_inner) = true;
        changed.notify_all();
    }
}

impl Mux {
    /// Starts this owner's reaper of other sessions' unowned hosts; none for
    /// a session with no durable state.
    pub fn start_unowned_host_reaper(self: &Arc<Self>) -> Option<UnownedHostReaper> {
        let own_root = self.surface_options.lock().unwrap().terminal_host_root.clone()?;
        let store = self.session_state_directory()?.join(STORE_FILE);
        let timing = Timing::for_owner();
        let stop = Arc::new((Mutex::new(false), Condvar::new()));
        let thread_stop = stop.clone();
        std::thread::Builder::new()
            .name("unowned-host-reap".into())
            .spawn(move || {
                let stopped = || *thread_stop.0.lock().unwrap_or_else(PoisonError::into_inner);
                let wait = |timeout: Duration| {
                    let (flag, changed) = &*thread_stop;
                    let guard = flag.lock().unwrap_or_else(PoisonError::into_inner);
                    let (guard, _) = changed
                        .wait_timeout_while(guard, timeout, |stopped| !*stopped)
                        .unwrap_or_else(PoisonError::into_inner);
                    !*guard
                };
                let mut next = timing.first_delay;
                while wait(next) {
                    let report = reap_pass(&own_root, &store, now_ms(), timing, &stopped);
                    if report.reaped > 0 || report.failed > 0 {
                        eprintln!(
                            "cmux-tui: ended {} terminal hosts no live session owns ({} failed, \
                             {} in their grace, {} of {} other session roots owned)",
                            report.reaped,
                            report.failed,
                            report.in_grace,
                            report.owned_roots,
                            report.roots
                        );
                    }
                    next = if report.capped { timing.catch_up } else { timing.interval };
                }
            })
            .ok()?;
        Some(UnownedHostReaper { stop })
    }
}

/// The record roots of the other sessions of `own_root`'s state root, each
/// with its session's guard file stem when it can be named, sorted.
fn other_session_roots(own_root: &Path) -> Vec<(PathBuf, Option<String>)> {
    let Some(state_root) = own_root.parent() else { return Vec::new() };
    #[cfg(unix)]
    let components = crate::workspace_registry::session_guard_components(state_root);
    let mut roots = std::fs::read_dir(state_root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.file_name() == own_root.file_name() || !path.is_dir() {
                return None;
            }
            let name = entry.file_name().into_string().ok()?;
            // Unix: `terminal-hosts-<session hash>`; the guard is
            // `<readable session>-<same hash>`.
            #[cfg(unix)]
            let component = {
                let hash = name.strip_prefix("terminal-hosts-")?;
                let suffix = format!("-{hash}");
                components.iter().find(|component| component.ends_with(&suffix)).cloned()
            };
            // Windows: `<session>.terminal-hosts`.
            #[cfg(not(unix))]
            let component = Some(crate::workspace_registry::session_guard_component(
                name.strip_suffix(".terminal-hosts")?,
            ));
            Some((path, component))
        })
        .collect::<Vec<_>>();
    roots.sort();
    roots
}

fn load_store(path: &Path) -> BTreeMap<String, u64> {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<BTreeMap<String, u64>>(&bytes).ok())
        .unwrap_or_default()
}

fn save_store(path: &Path, store: &BTreeMap<String, u64>) {
    let mut store = store.clone();
    while store.len() > MAX_STORE_ENTRIES {
        let Some(newest) =
            store.iter().max_by_key(|(_, first_seen)| **first_seen).map(|(key, _)| key.clone())
        else {
            break;
        };
        store.remove(&newest);
    }
    let Ok(bytes) = serde_json::to_vec(&store) else { return };
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, bytes).is_ok() && std::fs::rename(&temporary, path).is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
}

/// One pass over the other sessions' roots of `own_root`'s state root.
fn reap_pass(
    own_root: &Path,
    store_path: &Path,
    now_ms: u64,
    timing: Timing,
    stopped: &dyn Fn() -> bool,
) -> PassReport {
    let mut report = PassReport::default();
    let Some(state_root) = own_root.parent() else { return report };
    let previous = load_store(store_path);
    let mut seen = BTreeMap::new();
    let roots = other_session_roots(own_root);
    report.capped = roots.len() > MAX_ROOTS_PER_PASS;
    for (root, component) in roots.into_iter().take(MAX_ROOTS_PER_PASS) {
        if stopped() {
            break;
        }
        report.roots += 1;
        let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(&root) else {
            continue;
        };
        if records.is_empty() {
            continue;
        }
        // Held to the end of this root: no owner of the session can start
        // while its hosts are judged and ended.
        let _lease = match component
            .as_deref()
            .map(|component| probe_session_owner(state_root, component))
        {
            Some(SessionOwnerProbe::Owned) => {
                report.owned_roots += 1;
                continue;
            }
            Some(SessionOwnerProbe::Unowned(lease)) => Some(lease),
            Some(SessionOwnerProbe::NoGuard) | None => None,
        };
        let root_name = root.file_name().and_then(|name| name.to_str()).unwrap_or_default();
        for (record_path, record) in records {
            if terminal_host_record_liveness(&record_path, &record) != TerminalHostLiveness::Live {
                continue;
            }
            let key = format!("{root_name}/{}/{}", record.terminal_id, record.incarnation);
            // A wall clock set back only restarts the count.
            let first_seen = previous.get(&key).copied().filter(|first| *first <= now_ms);
            let first_seen = first_seen.unwrap_or(now_ms);
            let grace = if record_path.with_extension("exit").exists() {
                timing.ended_grace
            } else {
                timing.live_grace
            };
            let unowned_for = Duration::from_millis(now_ms - first_seen);
            if unowned_for < grace {
                report.in_grace += 1;
                seen.insert(key, first_seen);
                continue;
            }
            if report.reaped + report.failed >= MAX_REAPS_PER_PASS || stopped() {
                report.capped = true;
                seen.insert(key, first_seen);
                continue;
            }
            if cleanup_terminal_host_record(&record, &record_path) {
                eprintln!(
                    "cmux-tui: ended terminal host {} of another session ({root_name}): no live \
                     session owned it for {} s",
                    record.terminal_id,
                    unowned_for.as_secs()
                );
                report.reaped += 1;
            } else {
                report.failed += 1;
                seen.insert(key, first_seen);
            }
        }
    }
    if seen != previous {
        save_store(store_path, &seen);
    }
    report
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn other_roots_name_their_session_guard_by_the_shared_hash() {
        let dir = std::env::temp_dir().join(format!("unowned-roots-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
        let other = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-other");
        let nameless = crate::terminal_host_runtime::terminal_host_root(&dir, "gone");
        for root in [&own, &other, &nameless] {
            std::fs::create_dir_all(root).unwrap();
        }
        std::fs::create_dir_all(dir.join("session-locks")).unwrap();
        let component = crate::workspace_registry::session_guard_component("cmux-app-other");
        std::fs::write(dir.join("session-locks").join(format!("{component}.lock")), b"").unwrap();

        let roots = other_session_roots(&own);
        assert_eq!(roots.len(), 2, "{roots:?}");
        assert!(roots.contains(&(other, Some(component))));
        assert!(roots.contains(&(nameless, None)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_store_keeps_the_oldest_first_seen_times_past_its_cap() {
        let dir = std::env::temp_dir().join(format!("unowned-store-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(STORE_FILE);
        let store = (0..MAX_STORE_ENTRIES as u64 + 2)
            .map(|index| (format!("root/{index}"), index))
            .collect::<BTreeMap<_, _>>();
        save_store(&path, &store);
        let loaded = load_store(&path);
        assert_eq!(loaded.len(), MAX_STORE_ENTRIES);
        assert_eq!(loaded.get("root/0"), Some(&0));
        assert!(!loaded.contains_key(&format!("root/{}", MAX_STORE_ENTRIES + 1)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
