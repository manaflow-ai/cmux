//! Terminal hosts that no live session owns are ended after a grace (Leo
//! 2026-11-09: "well those need to get auto cleaned up...").
//!
//! A session owner adopts, recovers (cx-0tgl LC, `orphan_hosts.rs`) or ends
//! every host under its own record root at its start. A host under the root
//! of another session is seen by no one while that session never starts
//! again: a normal install's host has no orphan grace (cx-t2sqm D1), so it
//! kept its shell and PTY until reboot. On a Mac every build keeps its own
//! state root (`cmux/tags/<tag>/tui` or `cmux/builds/<key>/tui`), so the hosts of an old NIGHTLY or a
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
//!    reset, and the app's next ensure starts it). A root whose guard is
//!    held, missing, or cannot be named is never touched; a held one starts
//!    its hosts' times over;
//! 2. it has been seen that way for its grace, counted from the first pass
//!    that saw it, kept across restarts in this session's directory
//!    ([`STORE_FILE`]), so an owner in a restart loop still reaps. Each time
//!    is saved with what the session's last owner run left in its session
//!    directory (`session_owner_mark`): an owner run since then (one that
//!    adopted or used the host) starts the grace over.
//!
//! Graces: [`LIVE_SHELL_GRACE`] for a host whose shell still runs (the user's
//! work may be in it: a session that has not started for a day while this
//! one ran is taken as gone; its tab, if it comes back, starts a new shell),
//! [`ENDED_SHELL_GRACE`] for one whose shell already ended (a valid exit
//! sidecar of its own incarnation is written; nothing is lost but the PTY it
//! holds; an older incarnation's sidecar keeps the live-shell grace). Only a host
//! proven live is ended (a dead one holds nothing; an unclear one is never
//! ended). A root whose hosts are all dead loses its stale records once
//! they have been seen so for [`ENDED_SHELL_GRACE`]. Bounds: at most
//! [`MAX_ROOTS_PER_PASS`] roots with records, [`MAX_REAPS_PER_PASS`] ends and
//! [`MAX_REMOVALS_PER_PASS`] record removals per pass, roots in a stable
//! order from where the last pass stopped (kept in [`STORE_FILE`]); a pass
//! that reached a cap runs again after [`CATCH_UP_INTERVAL`]. A host whose
//! end failed waits [`PASS_INTERVAL`] before it is tried again, so failures
//! never hold the budget from the hosts and roots after it, and the times of
//! roots that are gone or empty leave the store before its cap applies.
//! Restore never reads these roots.
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
    retry_failed: Duration,
}

impl Timing {
    const STANDARD: Self = Self {
        live_grace: LIVE_SHELL_GRACE,
        ended_grace: ENDED_SHELL_GRACE,
        first_delay: FIRST_PASS_DELAY,
        interval: PASS_INTERVAL,
        catch_up: CATCH_UP_INTERVAL,
        retry_failed: PASS_INTERVAL,
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
                timing.retry_failed = interval;
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
    /// Ends that failed (each retried after [`PASS_INTERVAL`]).
    pub(crate) failed: usize,
    /// Due hosts whose end failed within [`PASS_INTERVAL`]: not tried yet.
    pub(crate) deferred: usize,
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
        let own_root = self
            .surface_options
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_host_root
            .clone()?;
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
                             {} failed earlier, {} stale records removed, {} in their grace, {} \
                             of {} other session roots owned)",
                            report.reaped,
                            report.failed,
                            report.deferred,
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
/// per-build layout every build's (`<Application Support>/cmux/tags/<tag>/tui`
/// for a build with kept names, `cmux/builds/<key>/tui` for any other bundled
/// build: CmuxNextCompat `BuildIdentity.daemonStateDirectory`) and the shared root
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
        && matches!(name(tags), Some("tags" | "builds"))
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
        for builds in ["tags", "builds"] {
            roots.extend(
                std::fs::read_dir(base.join("cmux").join(builds))
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|entry| entry.path().join("tui"))
                    .filter(|root| root.is_dir()),
            );
        }
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

/// When a pass first saw a host (or a dead record) with no owner, and what
/// its session's last owner run had left then
/// ([`crate::workspace_registry::session_owner_mark`]).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct Seen {
    first_seen_ms: u64,
    owner_mark: String,
    /// When ending it last failed: it waits [`PASS_INTERVAL`] before it is
    /// tried again, so hosts that cannot be ended never take every pass's
    /// budget from the hosts and roots after them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    failed_ms: Option<u64>,
}

/// Whether the host's exit sidecar is valid and records the end of this
/// record's own shell. Startup keeps the sidecars of older incarnations
/// (`terminal_adoption.rs`), and a replacement launch leaves them in
/// place, so any other sidecar says nothing about the shell running now.
fn current_shell_ended(
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> bool {
    matches!(
        crate::terminal_host_runtime::terminal_host_exit_record(record_path),
        Ok(Some((_, exit)))
            if exit.terminal_id == record.terminal_id && exit.incarnation == record.incarnation
    )
}

/// The record root a store key names (`<record root>|<id>|<incarnation>`).
fn key_root(key: &str) -> Option<&str> {
    key.rsplitn(3, '|').nth(2)
}

/// What the reaper keeps across passes and restarts ([`STORE_FILE`]).
#[derive(Debug, Default, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct Store {
    /// The last record root a pass finished: the next pass starts after it.
    #[serde(default)]
    cursor: Option<PathBuf>,
    /// By `<record root>|<terminal id>|<incarnation>`.
    #[serde(default)]
    hosts: BTreeMap<String, Seen>,
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
            .max_by_key(|(_, seen)| seen.first_seen_ms)
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

/// How a pass left one record root.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Visit {
    /// No records: not counted against [`MAX_ROOTS_PER_PASS`].
    Empty,
    /// Looked at in full.
    Done,
    /// A cap stopped it part way: the next pass starts at it again.
    Unfinished,
}

/// Visits `roots` (sorted) in order from the first after `cursor`, wrapping
/// around, at most [`MAX_ROOTS_PER_PASS`] roots with records. Returns the new
/// cursor (the last root finished) and whether a cap or a stop ended the pass
/// with roots left.
fn walk_roots<T>(
    roots: &[T],
    path: impl Fn(&T) -> &Path,
    cursor: Option<&Path>,
    stopped: &dyn Fn() -> bool,
    mut visit: impl FnMut(&T) -> Visit,
) -> (Option<PathBuf>, bool) {
    let start = cursor.map_or(0, |cursor| roots.partition_point(|root| path(root) <= cursor));
    let mut cursor = cursor.map(Path::to_path_buf);
    let mut counted = 0;
    let (before, after) = roots.split_at_checked(start).unwrap_or((roots, &[]));
    for root in after.iter().chain(before) {
        if stopped() {
            return (cursor, true);
        }
        if counted == MAX_ROOTS_PER_PASS {
            return (cursor, true);
        }
        match visit(root) {
            Visit::Empty => {}
            Visit::Done => counted += 1,
            Visit::Unfinished => return (cursor, true),
        }
        cursor = Some(path(root).to_path_buf());
    }
    (cursor, false)
}

/// Drops the entries of roots not in `visited` whose root no longer holds
/// their record. A root whose listing fails keeps its entries.
fn prune_unvisited_entries(hosts: &HostOps<'_>, store: &mut Store, visited: &HashSet<String>) {
    let mut held = HashMap::<String, Option<HashSet<String>>>::new();
    store.hosts.retain(|key, _| {
        let Some(root) = key_root(key) else { return false };
        if visited.contains(root) {
            return true;
        }
        let records = held.entry(root.to_string()).or_insert_with(|| {
            (hosts.load)(Path::new(root)).ok().map(|records| {
                records
                    .iter()
                    .map(|(_, record)| {
                        format!("{root}|{}|{}", record.terminal_id, record.incarnation)
                    })
                    .collect()
            })
        });
        records.as_ref().is_none_or(|records| records.contains(key))
    });
}

type LoadedRecords =
    anyhow::Result<Vec<(PathBuf, crate::terminal_host_runtime::TerminalHostRecord)>>;

/// How a pass reads and ends hosts: the real record files and host
/// processes, or a test's.
struct HostOps<'a> {
    load: &'a dyn Fn(&Path) -> LoadedRecords,
    liveness: &'a dyn Fn(
        &Path,
        &crate::terminal_host_runtime::TerminalHostRecord,
    ) -> TerminalHostLiveness,
    end: &'a dyn Fn(&crate::terminal_host_runtime::TerminalHostRecord, &Path) -> bool,
}

impl HostOps<'static> {
    const REAL: Self = Self {
        load: &crate::terminal_host_runtime::load_terminal_host_records,
        liveness: &terminal_host_record_liveness,
        end: &cleanup_terminal_host_record,
    };
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
    reap_pass_with(&HostOps::REAL, own_root, store_path, now_ms, timing, stopped)
}

fn reap_pass_with(
    hosts: &HostOps<'_>,
    own_root: &Path,
    store_path: &Path,
    now_ms: u64,
    timing: Timing,
    stopped: &dyn Fn() -> bool,
) -> PassReport {
    let mut report = PassReport::default();
    let previous = load_store(store_path);
    let mut store = previous.clone();
    let roots = other_session_roots(own_root);
    // Times of roots that are gone leave before the store's cap can drop
    // the times of hosts seen since.
    let present =
        roots.iter().map(|(_, root, _)| root.display().to_string()).collect::<HashSet<_>>();
    store.hosts.retain(|key, _| key_root(key).is_some_and(|root| present.contains(root)));
    let mut removed = 0;
    let mut visited = HashSet::new();
    let (cursor, capped) = walk_roots(
        &roots,
        |(_, root, _)| root.as_path(),
        previous.cursor.as_deref(),
        stopped,
        |(state_root, root, component)| {
            let Ok(records) = (hosts.load)(root) else {
                return Visit::Done;
            };
            let prefix = format!("{}|", root.display());
            store.hosts.retain(|key, _| !key.starts_with(&prefix));
            visited.insert(root.display().to_string());
            if records.is_empty() {
                return Visit::Empty;
            }
            report.roots += 1;
            // Only while this root's own session guard is held here: no owner
            // of it runs, and none can start and adopt its hosts until the
            // lease drops at the end of this root. A root whose guard is held,
            // missing or cannot be named is never touched.
            let Some(component) = component else {
                report.owned_roots += 1;
                return Visit::Done;
            };
            let _lease = match probe_session_owner(state_root, component) {
                SessionOwnerProbe::Unowned(lease) => lease,
                SessionOwnerProbe::Owned | SessionOwnerProbe::NoGuard => {
                    report.owned_roots += 1;
                    return Visit::Done;
                }
            };
            // An owner run since a time was saved (it adopted or used the
            // hosts) starts every grace of this root over.
            let owner_mark = crate::workspace_registry::session_owner_mark(state_root, component);
            let mut visit = Visit::Done;
            let mut dead = Vec::new();
            let mut all_dead = true;
            for (record_path, record) in records {
                let key = format!("{prefix}{}|{}", record.terminal_id, record.incarnation);
                // A wall clock set back only restarts the count.
                let first_seen = previous
                    .hosts
                    .get(&key)
                    .filter(|seen| seen.owner_mark == owner_mark && seen.first_seen_ms <= now_ms)
                    .map_or(now_ms, |seen| seen.first_seen_ms);
                let failed_ms = previous
                    .hosts
                    .get(&key)
                    .filter(|seen| seen.first_seen_ms == first_seen)
                    .and_then(|seen| seen.failed_ms)
                    .filter(|failed| *failed <= now_ms);
                let seen =
                    Seen { first_seen_ms: first_seen, owner_mark: owner_mark.clone(), failed_ms };
                let unowned_for = Duration::from_millis(now_ms - first_seen);
                match (hosts.liveness)(&record_path, &record) {
                    TerminalHostLiveness::Dead => {
                        dead.push((record_path, record, key, seen, unowned_for));
                        continue;
                    }
                    TerminalHostLiveness::Indeterminate => {
                        all_dead = false;
                        continue;
                    }
                    TerminalHostLiveness::Live => all_dead = false,
                }
                let grace = if current_shell_ended(&record_path, &record) {
                    timing.ended_grace
                } else {
                    timing.live_grace
                };
                if unowned_for < grace {
                    report.in_grace += 1;
                    store.hosts.insert(key, seen);
                    continue;
                }
                if failed_ms.is_some_and(|failed| {
                    Duration::from_millis(now_ms - failed) < timing.retry_failed
                }) {
                    report.deferred += 1;
                    store.hosts.insert(key, seen);
                    continue;
                }
                if report.reaped + report.failed >= MAX_REAPS_PER_PASS || stopped() {
                    visit = Visit::Unfinished;
                    store.hosts.insert(key, seen);
                    continue;
                }
                if (hosts.end)(&record, &record_path) {
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
                    store.hosts.insert(key, Seen { failed_ms: Some(now_ms), ..seen });
                }
            }
            // A root whose hosts are all dead holds only stale records: each
            // is removed (its record, live marker and endpoint, as the owner's
            // own cleanup does) once seen so for the ended-shell grace. A root
            // with a live or unclear host keeps its dead records for that
            // session's next start.
            for (record_path, record, key, seen, unowned_for) in dead {
                if !all_dead || unowned_for < timing.ended_grace {
                    store.hosts.insert(key, seen);
                    continue;
                }
                if removed == MAX_REMOVALS_PER_PASS {
                    visit = Visit::Unfinished;
                    store.hosts.insert(key, seen);
                    continue;
                }
                match crate::terminal_host_runtime::remove_stale_terminal_host_record(
                    &record_path,
                    &record,
                ) {
                    Ok(true) => removed += 1,
                    Ok(false) | Err(_) => {
                        store.hosts.insert(key, seen);
                    }
                }
            }
            visit
        },
    );
    // Past the cap, the saved roots this pass did not reach (after the root
    // cap) drop the entries of hosts they no longer hold, so a root that went
    // empty never keeps the times of hosts seen since from the store.
    if store.hosts.len() > MAX_STORE_ENTRIES {
        prune_unvisited_entries(hosts, &mut store, &visited);
    }
    report.removed = removed;
    report.capped = capped;
    store.cursor = cursor;
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
    fn state_roots_cover_the_builds_of_their_key_on_the_app_layout() {
        // `BuildIdentity` (CmuxNextCompat `daemonStateDirectory`): a build
        // with kept names in `tags/<tag>/tui`, any other bundled build (the
        // untagged DEV build, an unknown bundle such as `cmux_NIGHTLY`) in
        // `builds/<key>/tui`, and release, unbundled and adopted legacy
        // channel builds in the shared default root.
        let base = std::env::temp_dir().join(format!("unowned-builds-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let cmux = base.join("cmux");
        let mut expected = Vec::new();
        for dir in [
            cmux.join("tags").join("cmux-next").join("tui"),
            cmux.join("tags").join("nightly").join("tui"),
            cmux.join("builds").join("cmux_NIGHTLY").join("tui"),
            cmux.join("builds").join("com.cmuxterm.app.debug").join("tui"),
            base.join("cmux-tui").join("sessions"),
        ] {
            std::fs::create_dir_all(&dir).unwrap();
            expected.push(dir);
        }
        // A build directory with no daemon state is not a root.
        std::fs::create_dir_all(cmux.join("builds").join("no-state")).unwrap();
        expected.sort();
        for own in &expected {
            assert_eq!(&state_roots(own), &expected, "from {}", own.display());
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_root_whose_listing_failed_keeps_its_entries_when_the_store_is_pruned() {
        let (dir, own, roots) = state_with_sessions("listing-failed", &["cmux-app-flaky"]);
        let flaky = roots[0].clone();
        let store_path = dir.join(STORE_FILE);
        let mut store = Store::default();
        for index in 0..=MAX_STORE_ENTRIES {
            store.hosts.insert(
                format!("{}|t{index}|i", flaky.display()),
                Seen { first_seen_ms: index as u64, owner_mark: String::new(), failed_ms: None },
            );
        }
        // Its listing fails once, then reads back nothing (a partial read).
        let calls = std::cell::Cell::new(0);
        let records = |_: &Path| -> LoadedRecords {
            calls.set(calls.get() + 1);
            if calls.get() == 1 { Err(anyhow::anyhow!("listing failed")) } else { Ok(Vec::new()) }
        };
        let hosts = HostOps {
            load: &records,
            liveness: &|_, _| TerminalHostLiveness::Live,
            end: &|_, _| panic!("nothing to end"),
        };
        // A store over its cap, as a pass leaves it before it saves.
        let bytes = serde_json::to_vec(&store).unwrap();
        std::fs::write(&store_path, bytes).unwrap();
        let never = || false;
        reap_pass_with(&hosts, &own, &store_path, 10_000_000, Timing::STANDARD, &never);
        assert_eq!(
            load_store(&store_path).hosts.len(),
            MAX_STORE_ENTRIES,
            "the times of a root whose listing failed were dropped"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn entries_of_an_empty_root_past_the_root_cap_leave_before_they_drop_new_hosts() {
        let sessions = (0..=MAX_ROOTS_PER_PASS)
            .map(|index| format!("cmux-app-{index:03}"))
            .collect::<Vec<_>>();
        let names = sessions.iter().map(String::as_str).collect::<Vec<_>>();
        let (dir, own, roots) = state_with_sessions("past-cap", &names);
        // The last root in order is empty and holds a full store's entries;
        // a pass reaches the root cap before it.
        let empty = roots[MAX_ROOTS_PER_PASS].clone();
        let store_path = dir.join(STORE_FILE);
        let mut store = Store::default();
        for index in 0..MAX_STORE_ENTRIES {
            store.hosts.insert(
                format!("{}|t{index}|i", empty.display()),
                Seen { first_seen_ms: index as u64, owner_mark: String::new(), failed_ms: None },
            );
        }
        save_store(&store_path, &store);
        let records = |root: &Path| -> LoadedRecords {
            Ok(if *root == *empty { Vec::new() } else { vec![fake_record(root, 0)] })
        };
        let hosts = HostOps {
            load: &records,
            liveness: &|_, _| TerminalHostLiveness::Live,
            end: &|_, _| panic!("ended in its grace"),
        };
        let never = || false;
        let first = 10_000_000;
        let report = reap_pass_with(&hosts, &own, &store_path, first, Timing::STANDARD, &never);
        assert!(report.capped, "{report:?}");
        let saved = load_store(&store_path);
        let key = format!("{}|t000|i", roots[0].display());
        assert_eq!(
            saved.hosts.get(&key).map(|seen| seen.first_seen_ms),
            Some(first),
            "a new host's time was dropped for an empty root's: {} entries kept",
            saved.hosts.len()
        );
        assert_eq!(saved.hosts.len(), MAX_ROOTS_PER_PASS, "stale entries kept");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A state root with an own record root and one free-guarded record
    /// root per session in `sessions`; returns (own root, other roots).
    fn state_with_sessions(name: &str, sessions: &[&str]) -> (PathBuf, PathBuf, Vec<PathBuf>) {
        let dir = std::env::temp_dir().join(format!("unowned-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let own = crate::terminal_host_runtime::terminal_host_root(&dir, "mine");
        std::fs::create_dir_all(&own).unwrap();
        std::fs::create_dir_all(dir.join("session-locks")).unwrap();
        let mut others = Vec::new();
        for session in sessions {
            let root = crate::terminal_host_runtime::terminal_host_root(&dir, session);
            std::fs::create_dir_all(&root).unwrap();
            let component = crate::workspace_registry::session_guard_component(session);
            std::fs::write(dir.join("session-locks").join(format!("{component}.lock")), b"")
                .unwrap();
            others.push(root);
        }
        others.sort();
        (dir, own, others)
    }

    fn fake_record(
        root: &Path,
        index: usize,
    ) -> (PathBuf, crate::terminal_host_runtime::TerminalHostRecord) {
        let terminal_id = format!("t{index:03}");
        let record = crate::terminal_host_runtime::TerminalHostRecord {
            record_version: 4,
            terminal_id: terminal_id.clone(),
            incarnation: "i".into(),
            ..Default::default()
        };
        (root.join(format!("{terminal_id}.json")), record)
    }

    const NO_GRACE: Timing =
        Timing { live_grace: Duration::ZERO, ended_grace: Duration::ZERO, ..Timing::STANDARD };

    #[test]
    fn hosts_that_fail_to_end_do_not_keep_later_hosts_and_roots_from_their_turn() {
        // The first root's 6 live hosts never end; the second root's host does.
        let (dir, own, roots) = state_with_sessions("failing", &["cmux-app-a", "cmux-app-b"]);
        let (stuck, free) = (roots[0].clone(), roots[1].clone());
        let records = |root: &Path| -> LoadedRecords {
            let count = if root == stuck {
                6
            } else if root == free {
                1
            } else {
                0
            };
            Ok((0..count).map(|index| fake_record(root, index)).collect())
        };
        let tried = std::cell::RefCell::new(Vec::<PathBuf>::new());
        let end = |_: &crate::terminal_host_runtime::TerminalHostRecord, path: &Path| {
            tried.borrow_mut().push(path.to_path_buf());
            !path.starts_with(&stuck)
        };
        let hosts =
            HostOps { load: &records, liveness: &|_, _| TerminalHostLiveness::Live, end: &end };
        let store = dir.join(STORE_FILE);
        let never = || false;
        let mut now = 1_000_000;
        for _ in 0..4 {
            reap_pass_with(&hosts, &own, &store, now, NO_GRACE, &never);
            now += CATCH_UP_INTERVAL.as_millis() as u64;
        }
        let tried = tried.into_inner();
        let stuck_tried =
            tried.iter().filter(|path| path.starts_with(&stuck)).collect::<HashSet<_>>();
        assert_eq!(stuck_tried.len(), 6, "hosts past the failing ones never tried: {tried:?}");
        assert!(
            tried.iter().any(|path| path.starts_with(&free)),
            "the next root was never reached past the failing hosts: {tried:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn entries_of_gone_and_empty_roots_leave_the_store_before_its_cap_drops_new_hosts() {
        let (dir, own, _) = state_with_sessions("stale", &["cmux-app-live", "cmux-app-empty"]);
        let live = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-live");
        let empty = crate::terminal_host_runtime::terminal_host_root(&dir, "cmux-app-empty");
        let store_path = dir.join(STORE_FILE);
        // A full store of hosts in a root since deleted and in one now empty.
        let mut store = Store::default();
        for index in 0..MAX_STORE_ENTRIES {
            let root =
                if index % 2 == 0 { dir.join("terminal-hosts-deleted") } else { empty.clone() };
            store.hosts.insert(
                format!("{}|t{index}|i", root.display()),
                Seen { first_seen_ms: index as u64, owner_mark: String::new(), failed_ms: None },
            );
        }
        save_store(&store_path, &store);
        let records = |root: &Path| -> LoadedRecords {
            Ok(if root == live { vec![fake_record(root, 0)] } else { Vec::new() })
        };
        let hosts = HostOps {
            load: &records,
            liveness: &|_, _| TerminalHostLiveness::Live,
            end: &|_, _| panic!("ended in its grace"),
        };
        let never = || false;
        let first = 10_000_000;
        reap_pass_with(&hosts, &own, &store_path, first, Timing::STANDARD, &never);
        reap_pass_with(&hosts, &own, &store_path, first + 60_000, Timing::STANDARD, &never);
        let saved = load_store(&store_path);
        let key = format!("{}|t000|i", live.display());
        assert_eq!(
            saved.hosts.get(&key).map(|seen| seen.first_seen_ms),
            Some(first),
            "the new host's grace did not build up: {} entries kept",
            saved.hosts.len()
        );
        assert_eq!(saved.hosts.len(), 1, "stale entries kept");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_replacement_shell_keeps_the_live_grace_past_an_older_incarnations_exit_sidecar() {
        use crate::terminal_host::{HostIncarnation, TerminalId};
        use crate::terminal_host_runtime::{TerminalHostExitRecord, TerminalHostIdentity};
        use std::os::unix::fs::PermissionsExt as _;

        let (dir, own, roots) = state_with_sessions("sidecar", &["cmux-app-replaced"]);
        let root = roots[0].clone();
        let terminal_id = TerminalId::random().unwrap().to_hex();
        let current = HostIncarnation::random().unwrap().to_hex();
        let record_path = root.join(format!("{terminal_id}.json"));
        let record = crate::terminal_host_runtime::TerminalHostRecord {
            record_version: 4,
            terminal_id: terminal_id.clone(),
            incarnation: current.clone(),
            ..Default::default()
        };
        let write_sidecar = |incarnation: &str| {
            let exit = TerminalHostExitRecord::new(
                &TerminalHostIdentity {
                    terminal_id: terminal_id.clone(),
                    incarnation: incarnation.to_string(),
                },
                TerminalExit {
                    outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
                    exited_at_ms: 1,
                },
            );
            let path = record_path.with_extension("exit");
            std::fs::write(&path, serde_json::to_vec(&exit).unwrap()).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        };
        let ended = std::cell::Cell::new(0);
        let records =
            |_: &Path| -> LoadedRecords { Ok(vec![(record_path.clone(), record.clone())]) };
        let end = |_: &crate::terminal_host_runtime::TerminalHostRecord, _: &Path| {
            ended.set(ended.get() + 1);
            true
        };
        let hosts =
            HostOps { load: &records, liveness: &|_, _| TerminalHostLiveness::Live, end: &end };
        let timing = Timing { ended_grace: Duration::ZERO, ..Timing::STANDARD };
        let store = dir.join(STORE_FILE);
        let never = || false;

        // The shell of an older incarnation ended; the running one did not.
        write_sidecar(&HostIncarnation::random().unwrap().to_hex());
        reap_pass_with(&hosts, &own, &store, 1_000_000, timing, &never);
        reap_pass_with(&hosts, &own, &store, 1_000_000 + 11 * 60_000, timing, &never);
        assert_eq!(ended.get(), 0, "a live replacement shell was ended on an old exit sidecar");

        // The current incarnation's own sidecar does take the shorter grace.
        write_sidecar(&current);
        reap_pass_with(&hosts, &own, &store, 1_000_000 + 12 * 60_000, timing, &never);
        assert_eq!(ended.get(), 1, "the current shell's end did not take the ended-shell grace");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn passes_resume_after_the_last_root_so_every_root_is_seen_past_the_cap() {
        let roots = (0..MAX_ROOTS_PER_PASS + 6)
            .map(|index| PathBuf::from(format!("/roots/r{index:03}")))
            .collect::<Vec<_>>();
        let never = || false;
        let mut seen = HashSet::new();
        let walk = |cursor: Option<&Path>| {
            let mut visited = Vec::new();
            let result = walk_roots(
                &roots,
                |root| root.as_path(),
                cursor,
                &never,
                |root| {
                    visited.push(root.clone());
                    Visit::Done
                },
            );
            (result, visited)
        };
        let ((cursor, capped), first) = walk(None);
        assert!(capped);
        assert_eq!(first.len(), MAX_ROOTS_PER_PASS);
        assert_eq!(cursor.as_ref(), Some(&roots[MAX_ROOTS_PER_PASS - 1]));
        seen.extend(first);
        let ((_, capped), second) = walk(cursor.as_deref());
        assert!(capped);
        // The second pass starts at the first root the first one left out.
        assert_eq!(second.first(), Some(&roots[MAX_ROOTS_PER_PASS]));
        seen.extend(second);
        assert_eq!(seen.len(), roots.len(), "a root no pass reached");

        // A root a cap left part way is the next pass's first.
        let ((cursor, capped), _) = {
            let mut visited = Vec::new();
            let result = walk_roots(
                &roots,
                |root| root.as_path(),
                None,
                &never,
                |root| {
                    visited.push(root.clone());
                    if visited.len() == 3 { Visit::Unfinished } else { Visit::Done }
                },
            );
            (result, visited)
        };
        assert!(capped);
        assert_eq!(cursor.as_ref(), Some(&roots[1]));
    }

    #[test]
    fn the_store_keeps_the_oldest_first_seen_times_past_its_cap() {
        let dir = std::env::temp_dir().join(format!("unowned-store-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(STORE_FILE);
        let hosts = (0..MAX_STORE_ENTRIES as u64 + 2)
            .map(|index| {
                (
                    format!("root/{index}"),
                    Seen { first_seen_ms: index, owner_mark: "-".into(), failed_ms: None },
                )
            })
            .collect::<BTreeMap<_, _>>();
        save_store(&path, &Store { cursor: None, hosts });
        let loaded = load_store(&path).hosts;
        assert_eq!(loaded.len(), MAX_STORE_ENTRIES);
        assert_eq!(loaded.get("root/0").map(|seen| seen.first_seen_ms), Some(0));
        assert!(!loaded.contains_key(&format!("root/{}", MAX_STORE_ENTRIES + 1)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
