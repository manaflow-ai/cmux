//! Terminal hosts that no live session owns are ended after a grace (Leo
//! 2026-11-09: "well those need to get auto cleaned up...").
//!
//! A session owner adopts, recovers (cx-0tgl LC, `orphan_hosts.rs`) or ends
//! every host under its own record root at its start. A host under the root
//! of another session is seen by no one while that session never starts
//! again: a normal install's host has no orphan grace (cx-t2sqm D1), so it
//! kept its shell and PTY until reboot. On a Mac every build keeps its own
//! state root (`cmux/tags/<tag>/tui`), so the hosts of an old NIGHTLY or a
//! thrown-away DEV tag sit in roots no other owner read. This owner looks at
//! the other sessions' roots of its own state root and of its siblings
//! ([`state_roots`]) off its restore, on its own thread: a first pass a
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
//! ended). A root whose hosts are all dead loses its stale records once
//! they have been seen so for [`ENDED_SHELL_GRACE`]. Bounds: at most
//! [`MAX_ROOTS_PER_PASS`] roots with records, [`MAX_REAPS_PER_PASS`] ends and
//! [`MAX_REMOVALS_PER_PASS`] record removals per pass, roots in a stable
//! order from where the last pass stopped (kept in [`STORE_FILE`]); a pass
//! that reached a cap runs again after [`CATCH_UP_INTERVAL`]. Restore never
//! reads these roots.
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
/// Stale records of all-dead roots removed at most per pass.
const MAX_REMOVALS_PER_PASS: usize = 64;
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
    /// Stale records of roots whose hosts are all dead, removed.
    pub(crate) removed: usize,
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
                    if report.reaped > 0 || report.failed > 0 || report.removed > 0 {
                        eprintln!(
                            "cmux-tui: ended {} terminal hosts no live session owns ({} failed, \
                             {} stale records removed, {} in their grace, {} of {} other \
                             session roots owned)",
                            report.reaped,
                            report.failed,
                            report.removed,
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

/// The state roots this owner looks in, sorted: its own, and on the app's
/// per-build layout every build's (`<Application Support>/cmux/tags/<tag>/tui`,
/// `BuildIdentity::state_dir` in cmux-agent-pane-policy) and the shared root
/// of the builds before cx-6so.41 (`<Application Support>/cmux-tui/sessions`,
/// the platform default `workspace_state_dir`). Each build's owner keeps one
/// of these; a build that is never launched again leaves its hosts in it.
/// Elsewhere (Linux, Windows, a standalone cmux-tui) a state root has no
/// such siblings and only the own one is looked in.
fn state_roots(own_state_root: &Path) -> Vec<PathBuf> {
    fn name(path: Option<&Path>) -> Option<&str> {
        path.and_then(Path::file_name).and_then(|name| name.to_str())
    }
    let tag_dir = own_state_root.parent();
    let tags = tag_dir.and_then(Path::parent);
    let base = if name(Some(own_state_root)) == Some("tui")
        && name(tags) == Some("tags")
        && name(tags.and_then(Path::parent)) == Some("cmux")
    {
        tags.and_then(Path::parent).and_then(Path::parent)
    } else if name(Some(own_state_root)) == Some("sessions") && name(tag_dir) == Some("cmux-tui") {
        tag_dir.and_then(Path::parent)
    } else {
        None
    };
    let mut roots = vec![own_state_root.to_path_buf()];
    if let Some(base) = base {
        let tags = base.join("cmux").join("tags");
        roots.extend(
            std::fs::read_dir(&tags)
                .into_iter()
                .flatten()
                .flatten()
                .map(|entry| entry.path().join("tui"))
                .filter(|root| root.is_dir()),
        );
        let shared = base.join("cmux-tui").join("sessions");
        if shared.is_dir() {
            roots.push(shared);
        }
    }
    roots.sort();
    roots.dedup();
    roots
}

/// The record roots of the sessions of `state_root` other than `own_root`,
/// each with its session's guard file stem when it can be named, sorted.
fn session_roots(state_root: &Path, own_root: &Path) -> Vec<(PathBuf, Option<String>)> {
    #[cfg(unix)]
    let components = crate::workspace_registry::session_guard_components(state_root);
    let mut roots = std::fs::read_dir(state_root)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path == own_root || !path.is_dir() {
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

/// Every record root of another session this owner looks at, in a stable
/// order: (state root, record root, guard file stem).
fn other_session_roots(own_root: &Path) -> Vec<(PathBuf, PathBuf, Option<String>)> {
    let Some(own_state_root) = own_root.parent() else { return Vec::new() };
    let mut roots = state_roots(own_state_root)
        .into_iter()
        .flat_map(|state_root| {
            session_roots(&state_root, own_root)
                .into_iter()
                .map(move |(root, component)| (state_root.clone(), root, component))
        })
        .collect::<Vec<_>>();
    roots.sort_by(|left, right| left.1.cmp(&right.1));
    roots
}

/// What the reaper keeps across passes and restarts ([`STORE_FILE`]).
#[derive(Debug, Default, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct Store {
    /// The last record root a pass finished: the next pass starts after it.
    #[serde(default)]
    cursor: Option<String>,
    /// `<record root>|<terminal id>|<incarnation>`: when a pass first saw
    /// that host (or dead record) with no owner, wall-clock ms.
    #[serde(default)]
    hosts: BTreeMap<String, u64>,
}

fn load_store(path: &Path) -> Store {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Store>(&bytes).ok())
        .unwrap_or_default()
}

fn save_store(path: &Path, store: &Store) {
    let mut store = store.clone();
    while store.hosts.len() > MAX_STORE_ENTRIES {
        let Some(newest) = store
            .hosts
            .iter()
            .max_by_key(|(_, first_seen)| **first_seen)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        store.hosts.remove(&newest);
    }
    let Ok(bytes) = serde_json::to_vec(&store) else { return };
    let temporary = path.with_extension("json.tmp");
    if std::fs::write(&temporary, bytes).is_ok() && std::fs::rename(&temporary, path).is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
}

/// One pass over the other sessions' record roots ([`other_session_roots`]),
/// starting after the root the last pass finished.
fn reap_pass(
    own_root: &Path,
    store_path: &Path,
    now_ms: u64,
    timing: Timing,
    stopped: &dyn Fn() -> bool,
) -> PassReport {
    let mut report = PassReport::default();
    let previous = load_store(store_path);
    let mut store = previous.clone();
    let mut roots = other_session_roots(own_root);
    if let Some(cursor) = previous.cursor.as_deref() {
        let cursor = Path::new(cursor);
        let after = roots.partition_point(|(_, root, _)| root.as_path() <= cursor);
        roots.rotate_left(after);
    }
    // Roots with records looked at, and dead records removed, this pass.
    let (mut visited, mut removed) = (0, 0);
    for (state_root, root, component) in roots {
        if stopped() {
            break;
        }
        let root_key = root.to_string_lossy().into_owned();
        let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(&root) else {
            continue;
        };
        if records.is_empty() {
            store.cursor = Some(root_key);
            continue;
        }
        if visited == MAX_ROOTS_PER_PASS {
            report.capped = true;
            break;
        }
        visited += 1;
        report.roots += 1;
        let prefix = format!("{root_key}|");
        store.hosts.retain(|key, _| !key.starts_with(&prefix));
        // Held to the end of this root: no owner of the session can start
        // while its hosts are judged and ended.
        let _lease =
            match component.as_deref().map(|component| probe_session_owner(&state_root, component))
            {
                Some(SessionOwnerProbe::Owned) => {
                    report.owned_roots += 1;
                    store.cursor = Some(root_key);
                    continue;
                }
                Some(SessionOwnerProbe::Unowned(lease)) => Some(lease),
                Some(SessionOwnerProbe::NoGuard) | None => None,
            };
        let mut finished = true;
        let mut dead = Vec::new();
        let mut all_dead = true;
        for (record_path, record) in records {
            let key = format!("{prefix}{}|{}", record.terminal_id, record.incarnation);
            // A wall clock set back only restarts the count.
            let first_seen = previous.hosts.get(&key).copied().filter(|first| *first <= now_ms);
            let first_seen = first_seen.unwrap_or(now_ms);
            let unowned_for = Duration::from_millis(now_ms - first_seen);
            match terminal_host_record_liveness(&record_path, &record) {
                TerminalHostLiveness::Dead => {
                    dead.push((record_path, record, key, first_seen, unowned_for));
                    continue;
                }
                TerminalHostLiveness::Indeterminate => {
                    all_dead = false;
                    continue;
                }
                TerminalHostLiveness::Live => all_dead = false,
            }
            let grace = if record_path.with_extension("exit").exists() {
                timing.ended_grace
            } else {
                timing.live_grace
            };
            if unowned_for < grace {
                report.in_grace += 1;
                store.hosts.insert(key, first_seen);
                continue;
            }
            if report.reaped + report.failed >= MAX_REAPS_PER_PASS || stopped() {
                report.capped = true;
                finished = false;
                store.hosts.insert(key, first_seen);
                continue;
            }
            if cleanup_terminal_host_record(&record, &record_path) {
                eprintln!(
                    "cmux-tui: ended terminal host {} of another session ({}): no live \
                     session owned it for {} s",
                    record.terminal_id,
                    root.display(),
                    unowned_for.as_secs()
                );
                report.reaped += 1;
            } else {
                report.failed += 1;
                store.hosts.insert(key, first_seen);
            }
        }
        // A root whose hosts are all dead holds only stale records: each is
        // removed (its record, live marker and endpoint, as the owner's own
        // cleanup does) once it has been seen that way for the ended-shell
        // grace. A root with a live or unclear host keeps its dead records
        // for that session's next start.
        if all_dead {
            for (record_path, record, key, first_seen, unowned_for) in dead {
                if unowned_for < timing.ended_grace {
                    store.hosts.insert(key, first_seen);
                    continue;
                }
                if removed == MAX_REMOVALS_PER_PASS {
                    report.capped = true;
                    finished = false;
                    store.hosts.insert(key, first_seen);
                    continue;
                }
                match crate::terminal_host_runtime::remove_stale_terminal_host_record(
                    &record_path,
                    &record,
                ) {
                    Ok(true) => {
                        removed += 1;
                        report.removed += 1;
                    }
                    Ok(false) | Err(_) => {
                        store.hosts.insert(key, first_seen);
                    }
                }
            }
        }
        if !finished {
            // The next pass starts at this root again.
            break;
        }
        store.cursor = Some(root_key);
    }
    if store != previous {
        save_store(store_path, &store);
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
        assert!(roots.contains(&(dir.clone(), other, Some(component))));
        assert!(roots.contains(&(dir.clone(), nameless, None)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn state_roots_cover_every_build_and_the_shared_root_on_the_app_layout() {
        let base = std::env::temp_dir().join(format!("unowned-layout-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let tags = base.join("cmux").join("tags");
        for tag in ["cmux-next", "nightly", "old-dev"] {
            std::fs::create_dir_all(tags.join(tag).join("tui")).unwrap();
        }
        std::fs::create_dir_all(tags.join("no-state")).unwrap();
        let shared = base.join("cmux-tui").join("sessions");
        std::fs::create_dir_all(&shared).unwrap();
        let mut expected = vec![
            shared.clone(),
            tags.join("cmux-next").join("tui"),
            tags.join("nightly").join("tui"),
            tags.join("old-dev").join("tui"),
        ];
        expected.sort();
        assert_eq!(state_roots(&tags.join("cmux-next").join("tui")), expected);
        assert_eq!(state_roots(&shared), expected);
        // Any other layout (Linux, a test's own state) has no siblings.
        let lone = base.join("elsewhere").join("sessions");
        std::fs::create_dir_all(&lone).unwrap();
        assert_eq!(state_roots(&lone), vec![lone]);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn the_store_keeps_the_oldest_first_seen_times_past_its_cap() {
        let dir = std::env::temp_dir().join(format!("unowned-store-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(STORE_FILE);
        let hosts = (0..MAX_STORE_ENTRIES as u64 + 2)
            .map(|index| (format!("root/{index}"), index))
            .collect::<BTreeMap<_, _>>();
        save_store(&path, &Store { cursor: None, hosts });
        let loaded = load_store(&path).hosts;
        assert_eq!(loaded.len(), MAX_STORE_ENTRIES);
        assert_eq!(loaded.get("root/0"), Some(&0));
        assert!(!loaded.contains_key(&format!("root/{}", MAX_STORE_ENTRIES + 1)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
