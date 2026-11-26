//! `process-census`, `cmux ps` and `cmux gc`: the terminal hosts and the
//! state this product keeps, answered from its own records (Leo 2026-11-21:
//! "clearly cmux/acpmux needs better exposure and capabilities to help deal
//! with lifecycles and state management").
//!
//! Nothing here reads a process's argv. A host's `--owner <bundle>:<tag>@<pid>`
//! names the daemon that launched it, which may be long dead while a later
//! daemon of the same session adopted the host over its socket; a cleanup
//! that took that pid's death as the host's killed ten live terminals. What
//! counts instead:
//! - a host's record and its lease (`terminal_host_record_liveness`: live,
//!   dead or indeterminate, proven with the lease the host holds for its
//!   lifetime, never with a pid);
//! - its session's guard (`session-locks/`, held by every owner daemon from
//!   its registry open to its exit): held means a live daemon owns every host
//!   of that record root;
//! - in the answering daemon, its own surfaces and registry: which hosts it
//!   holds a stream to, where each is shown, which it still references.
//!
//! States: `in-use` (a live daemon serves it: this one in a pane, or another
//! that owns its session), `idle` (this daemon holds it but no pane shows it),
//! `orphaned` (no live daemon holds it), `unknown` (its lease or session
//! cannot be read, or this daemon references it but does not hold it).
//!
//! A daemon that holds a host's stream or owns its session decides its state
//! before its lease does: an adopted legacy host whose lease cannot be read
//! still reads `in-use` while a live daemon holds or shows it.
//!
//! `cmux gc` ends only what [`super::unowned_hosts`] would end, with the same
//! proof: a live host of a root whose session guard is free, held by gc while
//! it ends the host so no daemon can start and adopt it meanwhile, after the
//! same grace. The grace counts from the first time a gc (dry run or
//! `--apply`) or a reaper saw the host with its guard free and no owner run
//! since ([`super::unowned_hosts::Sightings`]); a host never seen unowned
//! before is seen now, so its grace starts now, however long its session sat
//! quiet. The clock runs one way: gc reads the reapers' times, a reaper
//! counts only its own, so gc never makes a reaper end a host sooner.
//! gc refuses a host whose stream a live daemon holds, one a live workspace
//! references (both imply a held guard), one the on-disk workspace registry of
//! its free session still references (an unrestored workspace), one whose
//! registry cannot be read, and one whose lease is indeterminate. Each end is
//! logged before it is asked for and again with its outcome. Stale records and
//! sockets no record names are reported, never removed.
//!
//! `cmux ps` and a dry-run gc only peek at a free root's guard, under its
//! coordinator ([`crate::workspace_registry::peek_session_owner`]): a session
//! starting meanwhile waits on the coordinator for the peek, never fails on
//! the guard. Only `cmux gc --apply` keeps a free root's guard, and only
//! while it handles that root's hosts.
//!
//! `cmux ps` writes nothing: it reads the saved sightings to show each host's
//! grace, and a host gc has not seen yet reads "first seen unowned now". Only
//! gc, dry run or `--apply`, saves sightings ([`record_sightings`]). Reading a
//! free session's registry leaves its owner mark as it was
//! ([`session_owner_mark`] skips SQLite's reader side files).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::PoisonError;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use super::time::now_ms;
use super::unowned_hosts::{
    RootSighting, Sightings, current_shell_ended, record_sightings, session_roots, sighting_key,
    state_roots, unowned_host_grace,
};
use super::{HostEnd, Mux, request_terminal_host_end, terminal_host_record_liveness};
use crate::SurfaceId;
use crate::terminal_host_runtime::{TerminalHostLiveness, TerminalHostRecord};
use crate::workspace_registry::{
    SessionLease, SessionOwnerPeek, SessionOwnerProbe, TerminalLifecycle, peek_session_owner,
    probe_session_owner, session_owner_last_active, session_owner_mark, stored_terminal_references,
};

/// The shape of [`Census`] and [`GcReport`]; bumped on a breaking change.
pub const CENSUS_VERSION: u32 = 1;

/// What a host is to the live daemons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum HostState {
    InUse,
    Idle,
    Orphaned,
    Unknown,
}

/// Who owns a record root, from its session guard.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RootOwner {
    /// The daemon answering the census owns it.
    ThisDaemon,
    /// Another live daemon holds its session guard (or the probe could not
    /// tell, which counts as held).
    LiveDaemon,
    /// Its session guard is free: no daemon runs that session.
    #[serde(rename = "none")]
    Free,
    /// The session has no guard file.
    NoGuard,
    /// No guard file names this root.
    Unnamed,
}

/// Where the answering daemon shows a host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Placement {
    pub surface: SurfaceId,
    pub pane: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_name: Option<String>,
}

/// A host the answering daemon has a surface for.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HeldHost {
    pub incarnation: String,
    pub surfaces: Vec<SurfaceId>,
    /// One of its surfaces is connected to the host: this daemon holds its
    /// stream.
    pub connected: bool,
    pub placements: Vec<Placement>,
    pub last_output_ms: Option<u64>,
}

/// What the answering daemon itself knows; `None` for the CLI reading the
/// records with no daemon.
#[derive(Debug, Clone, Default)]
pub struct OwnView {
    pub daemon_pid: u32,
    pub session: String,
    pub record_root: PathBuf,
    /// By terminal id.
    pub held: HashMap<String, HeldHost>,
    /// Terminal ids its registry has not tombstoned.
    pub referenced: HashSet<String>,
    /// Its registry could not be read, so `referenced` is not known: every
    /// host of its root it does not hold reads `unknown`.
    pub referenced_error: Option<String>,
}

/// Whether `cmux gc` may end a host, and why not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GcVerdict {
    pub candidate: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grace_ms: Option<u64>,
    /// Since the host was first seen with its session guard free and no
    /// owner run since (a free root only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unowned_for_ms: Option<u64>,
}

/// Whether a workspace still references a host: the answering daemon's live
/// registry for its own root, the on-disk registry for a free root.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Reference<'a> {
    None,
    Referenced,
    /// The registry could not be read: why.
    Unreadable(&'a str),
}

/// The facts one host is classified on.
#[derive(Debug, Clone, Copy)]
pub(crate) struct HostFacts<'a> {
    pub(crate) owner: RootOwner,
    /// Live or indeterminate: a dead host is a stale record, not a host.
    pub(crate) liveness: TerminalHostLiveness,
    pub(crate) incarnation: &'a str,
    pub(crate) held: Option<&'a HeldHost>,
    pub(crate) reference: Reference<'a>,
    pub(crate) shell_ended: bool,
    /// How long it has been seen with its session guard free and no owner
    /// run since, from the earliest saved sighting (a free root only); `None`
    /// when no sighting is saved: it is seen now.
    pub(crate) unowned_for: Option<Duration>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Verdict {
    pub(crate) state: HostState,
    pub(crate) reason: String,
    pub(crate) stream_held: bool,
    pub(crate) gc: GcVerdict,
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

fn refused(state: HostState, reason: impl Into<String>, refusal: &str) -> Verdict {
    Verdict {
        state,
        reason: reason.into(),
        stream_held: false,
        gc: GcVerdict {
            candidate: false,
            refusal: Some(refusal.to_string()),
            grace_ms: None,
            unowned_for_ms: None,
        },
    }
}

/// The census and gc rule for one live or indeterminate host. `grace` is
/// [`unowned_host_grace`] outside tests.
pub(crate) fn classify(facts: &HostFacts<'_>, grace: impl Fn(bool) -> Duration) -> Verdict {
    let stream_held = facts.owner == RootOwner::ThisDaemon
        && facts.held.is_some_and(|held| held.connected && held.incarnation == facts.incarnation);
    let mut verdict = classify_state(facts, grace);
    verdict.stream_held = stream_held;
    if stream_held {
        verdict.gc.candidate = false;
        verdict.gc.refusal = Some("a live daemon holds its stream".into());
    }
    verdict
}

fn classify_state(facts: &HostFacts<'_>, grace: impl Fn(bool) -> Duration) -> Verdict {
    let indeterminate = facts.liveness == TerminalHostLiveness::Indeterminate;
    let lease_note = if indeterminate { "; its lease cannot be read" } else { "" };
    match facts.owner {
        // A live daemon that holds or owns the host decides first: an adopted
        // legacy host it holds or shows reads in-use even when its lease
        // cannot be read (gc refuses it either way).
        RootOwner::ThisDaemon => {
            if let Some(held) = facts.held {
                if held.incarnation != facts.incarnation {
                    return refused(
                        HostState::Unknown,
                        format!(
                            "this daemon holds incarnation {} of this terminal, the record is \
                             {}{lease_note}",
                            held.incarnation, facts.incarnation
                        ),
                        "a surface of the live daemon names its terminal",
                    );
                }
                let how = if held.connected { "holds its stream" } else { "is reconnecting to it" };
                if held.placements.is_empty() {
                    return refused(
                        HostState::Idle,
                        format!("this daemon {how}; no pane shows it{lease_note}"),
                        "a surface of the live daemon names it",
                    );
                }
                return refused(
                    HostState::InUse,
                    format!(
                        "this daemon {how}; shown in {} pane(s){lease_note}",
                        held.placements.len()
                    ),
                    "a surface of the live daemon names it",
                );
            }
            if indeterminate {
                return indeterminate_verdict();
            }
            match facts.reference {
                Reference::Referenced => refused(
                    HostState::Unknown,
                    "a live workspace of this daemon references it but no surface holds it \
                     (adoption pending or failed)",
                    "a live workspace references it",
                ),
                Reference::Unreadable(why) => refused(
                    HostState::Unknown,
                    format!(
                        "no surface of this daemon holds it and its registry cannot be read \
                         ({why})"
                    ),
                    "the live daemon's registry cannot be read",
                ),
                Reference::None => refused(
                    HostState::Orphaned,
                    "nothing of the live daemon that owns its root names it (a product bug: \
                     that daemon adopts or ends its own hosts at start)",
                    "a live daemon owns its root",
                ),
            }
        }
        RootOwner::LiveDaemon => refused(
            HostState::InUse,
            format!("a live daemon owns its session (the session guard is held){lease_note}"),
            "a live daemon owns its session",
        ),
        _ if indeterminate => indeterminate_verdict(),
        RootOwner::NoGuard => refused(
            HostState::Unknown,
            "its session has no guard file, so no owner can be proven absent",
            "no session guard proves it unowned",
        ),
        RootOwner::Unnamed => refused(
            HostState::Unknown,
            "no session guard names its record root, so no owner can be proven absent",
            "no session guard proves it unowned",
        ),
        RootOwner::Free => {
            let shell = if facts.shell_ended { "its shell ended" } else { "its shell runs" };
            let reason = format!("no live daemon owns its session (the guard is free); {shell}");
            match facts.reference {
                Reference::Referenced => {
                    return refused(
                        HostState::Orphaned,
                        format!("{reason}; its session's workspace registry still references it"),
                        "referenced by an unrestored workspace",
                    );
                }
                Reference::Unreadable(why) => {
                    return refused(
                        HostState::Unknown,
                        format!(
                            "{reason}; its session's workspace registry cannot be read ({why})"
                        ),
                        "its session's workspace registry cannot be read",
                    );
                }
                Reference::None => {}
            }
            let grace = grace(facts.shell_ended);
            let verdict = |candidate: bool, refusal: Option<String>| Verdict {
                state: HostState::Orphaned,
                reason: reason.clone(),
                stream_held: false,
                gc: GcVerdict {
                    candidate,
                    refusal,
                    grace_ms: Some(millis(grace)),
                    unowned_for_ms: Some(millis(facts.unowned_for.unwrap_or_default())),
                },
            };
            // Never seen before counts as seen now: its grace starts now.
            let unowned_for = facts.unowned_for.unwrap_or_default();
            if unowned_for >= grace {
                return verdict(true, None);
            }
            let refusal = if facts.unowned_for.is_none() {
                format!("first seen unowned now: its grace of {} s starts now", grace.as_secs())
            } else {
                format!(
                    "in its grace: {} s of {} s left",
                    (grace - unowned_for).as_secs(),
                    grace.as_secs()
                )
            };
            verdict(false, Some(refusal))
        }
    }
}

fn indeterminate_verdict() -> Verdict {
    refused(
        HostState::Unknown,
        "its lease cannot be read, so whether the host lives is unknown",
        "its lease is indeterminate",
    )
}

/// One terminal host in the census.
#[derive(Debug, Clone, Serialize)]
pub struct HostEntry {
    pub terminal_id: String,
    pub incarnation: String,
    pub host_pid: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pgid: Option<i32>,
    pub record_path: String,
    pub record_root: String,
    pub endpoint: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub root_owner: RootOwner,
    pub workspace_key: String,
    pub placements: Vec<Placement>,
    pub surfaces: Vec<SurfaceId>,
    /// The answering daemon holds a connected stream to it.
    pub stream_held: bool,
    pub liveness: &'static str,
    pub shell_ended: bool,
    /// Since its record was last written (its launch or adoption).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub record_age_ms: Option<u64>,
    /// When its terminal last printed, as the answering daemon saw it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_output_ms: Option<u64>,
    pub state: HostState,
    pub reason: String,
    pub gc: GcVerdict,
}

/// A record whose host's lease is dead.
#[derive(Debug, Clone, Serialize)]
pub struct StaleRecord {
    pub terminal_id: String,
    pub incarnation: String,
    pub host_pid: u32,
    pub record_path: String,
    pub record_root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub shell_ended: bool,
}

/// An exit sidecar (`<id>.exit`).
#[derive(Debug, Clone, Serialize)]
pub struct ExitRecord {
    pub terminal_id: String,
    pub incarnation: String,
    pub path: String,
    pub record_root: String,
    /// A host record of the same terminal is still there.
    pub has_host_record: bool,
}

/// One record root and who owns it.
#[derive(Debug, Clone, Serialize)]
pub struct RootEntry {
    pub state_root: String,
    pub record_root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub owner: RootOwner,
    /// When an owner of its session last wrote its session directory
    /// (informational: the gc grace counts from the first sighting).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner_last_active_ms: Option<u64>,
    pub hosts: usize,
    pub stale_records: usize,
    pub exit_records: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DaemonEntry {
    pub pid: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pgid: Option<i32>,
    pub session: String,
    pub record_root: String,
}

/// A direct child process of the answering daemon.
#[derive(Debug, Clone, Serialize)]
pub struct HelperEntry {
    pub pid: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// It runs the daemon's own executable (a terminal host or another mode
    /// of cmux-tui).
    pub own_executable: bool,
    /// Its pid is a host pid of a record.
    pub terminal_host: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct StateSection {
    pub roots: Vec<RootEntry>,
    pub stale_records: Vec<StaleRecord>,
    pub exit_records: Vec<ExitRecord>,
    /// Sockets under `/tmp/cmux-th-<uid>/` that no record read here names.
    pub unnamed_sockets: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Census {
    pub census_version: u32,
    /// `daemon` when a daemon answered, `records` when the CLI read the
    /// records with no daemon.
    pub source: &'static str,
    pub generated_at_ms: u64,
    pub state_root: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub daemon: Option<DaemonEntry>,
    pub hosts: Vec<HostEntry>,
    pub helpers: Vec<HelperEntry>,
    pub state: StateSection,
}

fn unix_ms(time: SystemTime) -> Option<u64> {
    time.duration_since(UNIX_EPOCH).ok().map(millis)
}

fn liveness_name(liveness: TerminalHostLiveness) -> &'static str {
    match liveness {
        TerminalHostLiveness::Live => "live",
        TerminalHostLiveness::Dead => "dead",
        TerminalHostLiveness::Indeterminate => "indeterminate",
    }
}

#[cfg(unix)]
fn pgid(pid: u32) -> Option<i32> {
    let pid = i32::try_from(pid).ok().filter(|pid| *pid > 0)?;
    // SAFETY: getpgid only reads the process table.
    let group = unsafe { libc::getpgid(pid) };
    (group > 0).then_some(group)
}

#[cfg(not(unix))]
fn pgid(_pid: u32) -> Option<i32> {
    None
}

/// A record root's host records, each with the path it was read from.
type LoadedRecords = anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>>;

/// How the census reads and ends hosts: the real record files, leases and
/// host sockets, or a test's.
pub(super) struct CensusOps<'a> {
    pub(super) load: &'a dyn Fn(&Path) -> LoadedRecords,
    pub(super) liveness: &'a dyn Fn(&Path, &TerminalHostRecord) -> TerminalHostLiveness,
    /// Run under the session guard's coordinator: it must not wait on the
    /// host (see [`request_terminal_host_end`]).
    pub(super) end: &'a dyn Fn(&TerminalHostRecord, &Path) -> HostEnd,
    pub(super) grace: &'a dyn Fn(bool) -> Duration,
}

impl CensusOps<'static> {
    pub(super) const REAL: Self = Self {
        load: &crate::terminal_host_runtime::load_terminal_host_records,
        liveness: &terminal_host_record_liveness,
        end: &request_terminal_host_end,
        grace: &unowned_host_grace,
    };
}

/// How a free root's guard is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Probe {
    /// Under its coordinator, let go at once (`cmux ps`, a dry-run gc).
    Peek,
    /// Kept as a lease while the root's hosts are handled (`gc --apply`).
    Lease,
}

/// One record root as read: its owner, and its lease while gc holds it.
struct RootScan {
    state_root: PathBuf,
    record_root: PathBuf,
    component: Option<String>,
    owner: RootOwner,
    lease: Option<SessionLease>,
    owner_last_active: Option<SystemTime>,
    /// A free root's owner mark ([`session_owner_mark`]), read under its lease
    /// when gc applies.
    owner_mark: Option<String>,
    /// A free root's on-disk registry: the terminals it has not tombstoned.
    stored: Result<HashSet<String>, String>,
    records: Vec<(PathBuf, TerminalHostRecord)>,
    error: Option<String>,
}

/// A record root to scan: (state root, record root, guard file stem, owned
/// by the answering daemon).
type ListedRoot = (PathBuf, PathBuf, Option<String>, bool);

/// Every record root under the state roots of `state_root` (its own and,
/// on the app's per-build layout, every build's: as the reaper reads them).
/// `own` is the answering daemon's root, listed once, as its own.
fn list_roots(state_root: &Path, own: Option<&OwnView>) -> Vec<ListedRoot> {
    let own_root = own.map(|own| own.record_root.clone());
    let mut found = Vec::new();
    if let Some(own) = own {
        found.push((state_root.to_path_buf(), own.record_root.clone(), None, true));
    }
    let excluded = own_root.unwrap_or_default();
    for root_dir in state_roots(state_root) {
        for (record_root, component) in session_roots(&root_dir, &excluded) {
            found.push((root_dir.clone(), record_root, component, false));
        }
    }
    // By path, the answering daemon's entry first: `dedup_by` sees each
    // path's entries side by side and keeps the first.
    found.sort_by(|left, right| (&left.1, !left.3).cmp(&(&right.1, !right.3)));
    found.dedup_by(|later, kept| later.1 == kept.1);
    found
}

/// Reads one listed root: its owner from its session guard and, for a free
/// root, its owner mark and stored references. With [`Probe::Lease`] the
/// free guard is held from before the records are read until the scan drops.
fn scan_root(listed: ListedRoot, probe: Probe, ops: &CensusOps<'_>) -> RootScan {
    let (state_root, record_root, component, is_own) = listed;
    let (owner, lease) = if is_own {
        (RootOwner::ThisDaemon, None)
    } else {
        match (component.as_deref(), probe) {
            (None, _) => (RootOwner::Unnamed, None),
            (Some(component), Probe::Peek) => match peek_session_owner(&state_root, component) {
                SessionOwnerPeek::Unowned => (RootOwner::Free, None),
                SessionOwnerPeek::Owned => (RootOwner::LiveDaemon, None),
                SessionOwnerPeek::NoGuard => (RootOwner::NoGuard, None),
            },
            (Some(component), Probe::Lease) => match probe_session_owner(&state_root, component) {
                SessionOwnerProbe::Unowned(lease) => (RootOwner::Free, Some(lease)),
                SessionOwnerProbe::Owned => (RootOwner::LiveDaemon, None),
                SessionOwnerProbe::NoGuard => (RootOwner::NoGuard, None),
            },
        }
    };
    let (records, error) = match (ops.load)(&record_root) {
        Ok(records) => (records, None),
        Err(error) => (Vec::new(), Some(format!("{error:#}"))),
    };
    let free = component.as_deref().filter(|_| owner == RootOwner::Free);
    let owner_mark = free.map(|component| session_owner_mark(&state_root, component));
    let stored = match free {
        None => Ok(HashSet::new()),
        Some(component) => match stored_terminal_references(&state_root, component) {
            Ok(ids) => Ok(ids.unwrap_or_default()),
            Err(error) => Err(format!("{error:#}")),
        },
    };
    let owner_last_active = component
        .as_deref()
        .and_then(|component| session_owner_last_active(&state_root, component));
    RootScan {
        state_root,
        record_root,
        component,
        owner,
        lease,
        owner_last_active,
        owner_mark,
        stored,
        records,
        error,
    }
}

/// A classified host, before it becomes a [`HostEntry`] or a gc candidate.
struct ScannedHost<'a> {
    root: &'a RootScan,
    record_path: &'a Path,
    record: &'a TerminalHostRecord,
    liveness: TerminalHostLiveness,
    shell_ended: bool,
    verdict: Verdict,
}

/// Classifies every record of `root`; dead ones go to `stale`. A free root's
/// hosts count their grace from `sightings` (now, when never seen).
fn classify_root<'a>(
    root: &'a RootScan,
    own: Option<&OwnView>,
    ops: &CensusOps<'_>,
    sightings: &Sightings,
    now_ms: u64,
    stale: &mut Vec<StaleRecord>,
) -> Vec<ScannedHost<'a>> {
    let mut hosts = Vec::new();
    let this_daemon = root.owner == RootOwner::ThisDaemon;
    let own = own.filter(|_| this_daemon);
    for (record_path, record) in &root.records {
        let liveness = (ops.liveness)(record_path, record);
        let shell_ended = current_shell_ended(record_path, record);
        if liveness == TerminalHostLiveness::Dead {
            stale.push(StaleRecord {
                terminal_id: record.terminal_id.clone(),
                incarnation: record.incarnation.clone(),
                host_pid: record.host_pid,
                record_path: record_path.display().to_string(),
                record_root: root.record_root.display().to_string(),
                session: root.component.clone(),
                shell_ended,
            });
            continue;
        }
        let reference = match (root.owner, own) {
            (RootOwner::ThisDaemon, Some(own)) => match &own.referenced_error {
                Some(why) => Reference::Unreadable(why),
                None if own.referenced.contains(&record.terminal_id) => Reference::Referenced,
                None => Reference::None,
            },
            (RootOwner::Free, _) => match &root.stored {
                Ok(ids) if ids.contains(&record.terminal_id) => Reference::Referenced,
                Ok(_) => Reference::None,
                Err(why) => Reference::Unreadable(why),
            },
            _ => Reference::None,
        };
        let unowned_for =
            root.owner_mark.as_deref().filter(|_| root.owner == RootOwner::Free).and_then(|mark| {
                let key = sighting_key(&root.record_root, &record.terminal_id, &record.incarnation);
                let first = sightings.first_seen(&key, mark, now_ms)?;
                Some(Duration::from_millis(now_ms.saturating_sub(first)))
            });
        let facts = HostFacts {
            owner: root.owner,
            liveness,
            incarnation: &record.incarnation,
            held: own.and_then(|own| own.held.get(&record.terminal_id)),
            reference,
            shell_ended,
            unowned_for,
        };
        let verdict = classify(&facts, ops.grace);
        hosts.push(ScannedHost { root, record_path, record, liveness, shell_ended, verdict });
    }
    hosts
}

/// What a gc saw of one root for its clock: a free root's live hosts keep
/// (or start) their first sighting; any other root's leave. A root whose
/// records could not be read is left as it was.
fn root_sighting(root: &RootScan, hosts: &[ScannedHost<'_>]) -> Option<RootSighting> {
    if root.error.is_some() {
        return None;
    }
    let (live, owner_mark) = match (root.owner, root.owner_mark.as_ref()) {
        (RootOwner::Free, Some(mark)) => (
            hosts
                .iter()
                .filter(|host| host.liveness == TerminalHostLiveness::Live)
                .map(|host| {
                    sighting_key(
                        &root.record_root,
                        &host.record.terminal_id,
                        &host.record.incarnation,
                    )
                })
                .collect(),
            mark.clone(),
        ),
        _ => (Vec::new(), String::new()),
    };
    Some(RootSighting { record_root: root.record_root.clone(), live, owner_mark })
}

/// The sockets under this user's host socket directory (flat legacy
/// `<id>.sock`, and `<install>/<id>.sock`) that no record in `named` names.
#[cfg(unix)]
fn unnamed_sockets(named: &HashSet<PathBuf>) -> Vec<String> {
    // SAFETY: geteuid has no failure mode.
    let owner = unsafe { libc::geteuid() };
    let dir = crate::terminal_host_runtime::terminal_host_endpoint_dir(owner);
    let mut sockets = BTreeSet::new();
    let mut visit = |path: PathBuf| {
        if path.extension().is_some_and(|extension| extension == "sock") && !named.contains(&path) {
            sockets.insert(path.display().to_string());
        }
    };
    for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            for inner in std::fs::read_dir(&path).into_iter().flatten().flatten() {
                visit(inner.path());
            }
        } else {
            visit(path);
        }
    }
    sockets.into_iter().collect()
}

#[cfg(not(unix))]
fn unnamed_sockets(_named: &HashSet<PathBuf>) -> Vec<String> {
    Vec::new()
}

fn helpers(daemon_pid: u32, host_pids: &HashSet<u32>) -> Vec<HelperEntry> {
    let sampler = crate::process_resources::Sampler::new();
    let tree = sampler.tree(daemon_pid);
    tree.nodes
        .iter()
        .filter(|node| node.parent == Some(daemon_pid))
        .map(|node| HelperEntry {
            pid: node.pid,
            name: sampler.sample(node.pid).map(|sample| sample.name),
            own_executable: sampler.runs_own_executable(node.pid),
            terminal_host: host_pids.contains(&node.pid),
        })
        .collect()
}

/// The census of `state_root`'s hosts and state. `own` is the answering
/// daemon's view, `None` when the CLI reads the records with no daemon.
pub fn census(state_root: &Path, own: Option<&OwnView>) -> Census {
    census_with(state_root, own, &CensusOps::REAL)
}

fn census_with(state_root: &Path, own: Option<&OwnView>, ops: &CensusOps<'_>) -> Census {
    let now_ms = now_ms();
    let now = UNIX_EPOCH + Duration::from_millis(now_ms);
    let sightings = Sightings::load(&state_roots(state_root));
    let roots = list_roots(state_root, own)
        .into_iter()
        .map(|listed| scan_root(listed, Probe::Peek, ops))
        .collect::<Vec<_>>();
    let mut state = StateSection::default();
    let mut scanned = Vec::new();
    for root in &roots {
        scanned.extend(classify_root(root, own, ops, &sightings, now_ms, &mut state.stale_records));
    }
    let mut named = HashSet::new();
    for root in &roots {
        let exits =
            crate::terminal_host_runtime::load_terminal_host_exit_records(&root.record_root)
                .unwrap_or_default();
        let ids =
            root.records.iter().map(|(_, record)| &record.terminal_id).collect::<HashSet<_>>();
        for (path, exit) in &exits {
            state.exit_records.push(ExitRecord {
                terminal_id: exit.terminal_id.clone(),
                incarnation: exit.incarnation.clone(),
                path: path.display().to_string(),
                record_root: root.record_root.display().to_string(),
                has_host_record: ids.contains(&exit.terminal_id),
            });
        }
        named.extend(root.records.iter().map(|(_, record)| PathBuf::from(&record.endpoint)));
        let live = scanned.iter().filter(|host| std::ptr::eq(host.root, root)).count();
        state.roots.push(RootEntry {
            state_root: root.state_root.display().to_string(),
            record_root: root.record_root.display().to_string(),
            session: root.component.clone().or_else(|| {
                own.filter(|_| root.owner == RootOwner::ThisDaemon).map(|own| own.session.clone())
            }),
            owner: root.owner,
            owner_last_active_ms: root.owner_last_active.and_then(unix_ms),
            hosts: live,
            stale_records: root.records.len() - live,
            exit_records: exits.len(),
            error: root.error.clone(),
        });
    }
    state.unnamed_sockets = unnamed_sockets(&named);
    let hosts = scanned
        .iter()
        .map(|host| {
            let held = own
                .filter(|_| host.root.owner == RootOwner::ThisDaemon)
                .and_then(|own| own.held.get(&host.record.terminal_id))
                .filter(|held| held.incarnation == host.record.incarnation);
            HostEntry {
                terminal_id: host.record.terminal_id.clone(),
                incarnation: host.record.incarnation.clone(),
                host_pid: host.record.host_pid,
                pgid: pgid(host.record.host_pid),
                record_path: host.record_path.display().to_string(),
                record_root: host.root.record_root.display().to_string(),
                endpoint: host.record.endpoint.clone(),
                session: host.root.component.clone(),
                root_owner: host.root.owner,
                workspace_key: host.record.workspace_key.clone(),
                placements: held.map(|held| held.placements.clone()).unwrap_or_default(),
                surfaces: held.map(|held| held.surfaces.clone()).unwrap_or_default(),
                stream_held: host.verdict.stream_held,
                liveness: liveness_name(host.liveness),
                shell_ended: host.shell_ended,
                record_age_ms: std::fs::metadata(host.record_path)
                    .and_then(|meta| meta.modified())
                    .ok()
                    .and_then(|written| now.duration_since(written).ok())
                    .map(millis),
                last_output_ms: held.and_then(|held| held.last_output_ms),
                state: host.verdict.state,
                reason: host.verdict.reason.clone(),
                gc: host.verdict.gc.clone(),
            }
        })
        .collect::<Vec<_>>();
    let host_pids = hosts.iter().map(|host| host.host_pid).collect::<HashSet<_>>();
    Census {
        census_version: CENSUS_VERSION,
        source: if own.is_some() { "daemon" } else { "records" },
        generated_at_ms: unix_ms(now).unwrap_or_default(),
        state_root: state_root.display().to_string(),
        daemon: own.map(|own| DaemonEntry {
            pid: own.daemon_pid,
            pgid: pgid(own.daemon_pid),
            session: own.session.clone(),
            record_root: own.record_root.display().to_string(),
        }),
        helpers: own.map(|own| helpers(own.daemon_pid, &host_pids)).unwrap_or_default(),
        hosts,
        state,
    }
}

/// One host `cmux gc` would end (or did).
#[derive(Debug, Clone, Serialize)]
pub struct GcCandidate {
    pub terminal_id: String,
    pub incarnation: String,
    pub host_pid: u32,
    pub record_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unowned_for_ms: Option<u64>,
    /// With `--apply`: `ended`, `failed`, or `skipped: <why>`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<String>,
}

/// A live or unclear host gc will not end.
#[derive(Debug, Clone, Serialize)]
pub struct GcRefusal {
    pub terminal_id: String,
    pub incarnation: String,
    pub host_pid: u32,
    pub record_path: String,
    pub state: HostState,
    pub refusal: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct GcReport {
    pub census_version: u32,
    pub applied: bool,
    pub generated_at_ms: u64,
    pub state_root: String,
    pub candidates: Vec<GcCandidate>,
    pub refused: Vec<GcRefusal>,
    pub ended: usize,
    pub failed: usize,
    /// Stale records seen; gc leaves them to their session's next start and
    /// the reaper.
    pub stale_records: usize,
    /// The gc logs written (one per state root with an outcome).
    pub logs: Vec<String>,
    /// What gc could not do: a log line it could not write (a host whose
    /// intent line fails is not ended), saving its sightings.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
}

/// `cmux gc`: the proven orphans of `state_root`'s roots, ended when `apply`.
/// Runs with no daemon view: a root a live daemon owns has its guard held,
/// so every host it holds or references is refused.
pub fn gc(state_root: &Path, apply: bool) -> GcReport {
    gc_with(state_root, apply, &CensusOps::REAL)
}

/// One root at a time: with `apply` its free guard is held from its scan
/// until its last host is handled, then let go before the next root.
fn gc_with(state_root: &Path, apply: bool, ops: &CensusOps<'_>) -> GcReport {
    let now_ms = now_ms();
    let sightings = Sightings::load(&state_roots(state_root));
    let probe = if apply { Probe::Lease } else { Probe::Peek };
    let mut report = GcReport {
        census_version: CENSUS_VERSION,
        applied: apply,
        generated_at_ms: now_ms,
        state_root: state_root.display().to_string(),
        candidates: Vec::new(),
        refused: Vec::new(),
        ended: 0,
        failed: 0,
        stale_records: 0,
        logs: Vec::new(),
        errors: Vec::new(),
    };
    let mut logs = BTreeSet::new();
    let mut seen = Vec::new();
    for listed in list_roots(state_root, None) {
        let root = scan_root(listed, probe, ops);
        let mut stale = Vec::new();
        let hosts = classify_root(&root, None, ops, &sightings, now_ms, &mut stale);
        report.stale_records += stale.len();
        seen.extend(root_sighting(&root, &hosts));
        for host in hosts {
            if !host.verdict.gc.candidate {
                report.refused.push(GcRefusal {
                    terminal_id: host.record.terminal_id.clone(),
                    incarnation: host.record.incarnation.clone(),
                    host_pid: host.record.host_pid,
                    record_path: host.record_path.display().to_string(),
                    state: host.verdict.state,
                    refusal: host.verdict.gc.refusal.clone().unwrap_or_default(),
                });
                continue;
            }
            let mut candidate = GcCandidate {
                terminal_id: host.record.terminal_id.clone(),
                incarnation: host.record.incarnation.clone(),
                host_pid: host.record.host_pid,
                record_path: host.record_path.display().to_string(),
                session: host.root.component.clone(),
                reason: host.verdict.reason.clone(),
                unowned_for_ms: host.verdict.gc.unowned_for_ms,
                outcome: None,
            };
            if apply {
                candidate.outcome = Some(apply_candidate(&host, ops, &mut report, &mut logs));
            }
            report.candidates.push(candidate);
        }
        // `root`, and with it the lease on its guard, drops here.
    }
    if let Err(error) = record_sightings(state_root, &seen, now_ms) {
        report.errors.push(format!("saving the unowned-host sightings: {error:#}"));
    }
    report.logs = logs.into_iter().collect();
    report
}

/// Logs the intent to end `host`, ends it, and logs the outcome. A host
/// whose intent line cannot be written is not ended.
fn apply_candidate(
    host: &ScannedHost<'_>,
    ops: &CensusOps<'_>,
    report: &mut GcReport,
    logs: &mut BTreeSet<String>,
) -> String {
    let intent = gc_line(host, "host_gc_ending", None);
    match crate::terminal_loss_log::record_host_gc(host.record_path, &intent) {
        Ok(log) => {
            logs.insert(log.display().to_string());
        }
        Err(error) => {
            report.errors.push(format!(
                "gc log for {} ({}): {error}",
                host.record.terminal_id,
                host.record_path.display()
            ));
            return format!("skipped: its gc log cannot be written ({error})");
        }
    }
    let outcome = end_candidate(host, ops);
    let event = match outcome.as_str() {
        "ended" => {
            report.ended += 1;
            "host_gc_ended"
        }
        "failed" => {
            report.failed += 1;
            "host_gc_failed"
        }
        _ => "host_gc_skipped",
    };
    let line = gc_line(host, event, Some(&outcome));
    if let Err(error) = crate::terminal_loss_log::record_host_gc(host.record_path, &line) {
        report.errors.push(format!(
            "gc log for {} ({}): {error}; outcome {outcome}",
            host.record.terminal_id,
            host.record_path.display()
        ));
    }
    outcome
}

fn gc_line(host: &ScannedHost<'_>, event: &str, outcome: Option<&str>) -> serde_json::Value {
    serde_json::json!({
        "at_ms": unix_ms(SystemTime::now()).unwrap_or_default(),
        "event": event,
        "outcome": outcome,
        "terminal_id": host.record.terminal_id,
        "incarnation": host.record.incarnation,
        "host_pid": host.record.host_pid,
        "record_path": host.record_path.display().to_string(),
        "session": host.root.component,
        "reason": host.verdict.reason,
        "unowned_for_ms": host.verdict.gc.unowned_for_ms,
        "grace_ms": host.verdict.gc.grace_ms,
        "gc_pid": std::process::id(),
    })
}

/// Ends one candidate under its root's session lease, as the reaper does:
/// the guard is checked to still be this lease's and the host to still live
/// inside the guard's coordinator, the end is asked for there, and the wait
/// for its exit comes after.
fn end_candidate(host: &ScannedHost<'_>, ops: &CensusOps<'_>) -> String {
    let Some(lease) = host.root.lease.as_ref() else {
        return "skipped: its session guard is no longer held here".into();
    };
    let requested = lease.while_guarding(|| match (ops.liveness)(host.record_path, host.record) {
        TerminalHostLiveness::Live => Some((ops.end)(host.record, host.record_path)),
        _ => None,
    });
    let ended = match requested {
        None => return "skipped: its session guard was replaced".into(),
        Some(None) => return "skipped: the host no longer proves live".into(),
        Some(Some(HostEnd::Done(ended))) => ended,
        Some(Some(HostEnd::Requested(wait))) => wait(),
    };
    if ended { "ended".into() } else { "failed".into() }
}

impl Mux {
    /// This daemon's own view for the census: the hosts its surfaces hold,
    /// where each is shown, and the terminals its registry references.
    /// `None` for a session with no durable host records.
    pub fn process_census_view(&self) -> Option<OwnView> {
        let record_root = self
            .surface_options
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_host_root
            .clone()?;
        let mut held = HashMap::<String, HeldHost>::new();
        {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let mut pane_of = HashMap::new();
            for pane in state.panes.values() {
                for surface in &pane.tabs {
                    pane_of.insert(*surface, pane);
                }
            }
            let surfaces = state.surfaces.values().chain(state.terminal_catalog.values());
            for surface in surfaces {
                let Some(identity) = self.resource_terminal_host_identity(surface) else {
                    continue;
                };
                let entry = held.entry(identity.terminal_id).or_default();
                if entry.incarnation.is_empty() {
                    entry.incarnation = identity.incarnation;
                }
                if entry.surfaces.contains(&surface.id) {
                    continue;
                }
                entry.surfaces.push(surface.id);
                if !surface.is_dead()
                    && surface.terminal_host_connection_state()
                        == Some(crate::surface::TerminalHostConnectionState::Connected)
                {
                    entry.connected = true;
                }
                if let Some(at) = surface.terminal_last_output() {
                    entry.last_output_ms = Some(entry.last_output_ms.map_or(at, |old| old.max(at)));
                }
                if let Some(pane) = pane_of.get(&surface.id) {
                    let workspace =
                        state.screen_of(pane.id).and_then(|(index, _)| state.workspaces.get(index));
                    entry.placements.push(Placement {
                        surface: surface.id,
                        pane: pane.public_id.as_str().to_string(),
                        pane_name: pane.name.clone(),
                        workspace: workspace
                            .map(|workspace| workspace.public_id.as_str().to_string()),
                        workspace_name: workspace.map(|workspace| workspace.name.clone()),
                    });
                }
            }
        }
        // A registry that cannot be read references nothing provably: every
        // host this daemon does not hold then reads unknown, never orphaned.
        let (referenced, referenced_error) = match self.terminal_registry_snapshot() {
            Ok(snapshot) => (
                snapshot
                    .terminals
                    .into_iter()
                    .filter(|terminal| terminal.lifecycle != TerminalLifecycle::Tombstoned)
                    .map(|terminal| terminal.terminal_id)
                    .collect(),
                None,
            ),
            Err(error) => (HashSet::new(), Some(format!("{error:#}"))),
        };
        Some(OwnView {
            daemon_pid: std::process::id(),
            session: self.session.clone(),
            record_root,
            held,
            referenced,
            referenced_error,
        })
    }
}

#[cfg(all(test, unix))]
#[path = "process_census_tests.rs"]
mod tests;
