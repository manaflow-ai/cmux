//! Admission of a new session: whether this host has room for one more
//! (deputy-2, 2026-10-22). About 25 Codex reviewers started on huge-blue with
//! a raw `acpmux new` over reach went around lane-place's cap of 12, filled
//! the disk and pushed the load to 50-80. Every new session goes through the
//! daemon's create, so the daemon checks there, reading two files each time:
//!
//! - `~/.cache/worktree-reclaim/under-floor`, which worktree-reclaim writes
//!   while the disk is under its free-space floor: start with a warning;
//! - `lanes.max_lanes` of this machine in the fleet registry: a create while
//!   this host's live sessions (running, ready, waiting; a peer's are not
//!   counted) are at the cap starts all the same, with a warning that names
//!   the cap and the host the placement engine would pick instead
//!   (`placement.rs`, as `new --host auto` and lane-place weigh hosts). A cap
//!   only warns: no launch is refused for load or a cap (Leo's rulebook; at
//!   huge-blue's 12 the stall reconciler's PONG to claude-sr2 was refused,
//!   2026-10-26). The registry is `FLEET_REGISTRY` when set,
//!   else the first that exists of `~/.ssh/config.d/fleet-registry.json` (the
//!   copy `reach --install` renders) and leo-workspace's own
//!   `~/Projects/leo-workspace/machines/fleet-registry.json` (a fleet host
//!   with a checkout and no rendered copy, like cmux16).
//!
//! This machine is `FLEET_ORIGIN` when set, else the registry machine whose
//! name, `aliases` or origin `hostnames` match the host name, as `reach`
//! finds it. With no registry, or no `lanes` entry for this machine, a create
//! is admitted with no warning (a log line says why): acpmux outside the fleet
//! is unchanged. A registry that cannot be read, or whose every copy is gone
//! for a moment, keeps its last good copy; with none the cap is unknown, which
//! is logged and admitted, and a `FLEET_REGISTRY` that is missing counts as one
//! that cannot be read. `_meta.acpmux.forceAdmit` (`acpmux new --force-admit`)
//! remains accepted for compatibility; floors and caps never refuse a session. `session/new` (with no adopt, or an adopt that may fork), `session/fork`,
//! the composer's aside (`_acpmux/ask`) and sub-session starts are checked; a
//! send, a resume, a restart, an adopt that never forks, a side chat (`btw.rs`)
//! and a handoff target never are. An admitted create counts as live until it ends, so of concurrent
//! creates at the cap every one past it is warned.

use super::*;
use cmux_json::JsonSet as _;
use std::sync::OnceLock;

/// `data.reason` of a refusal; the CLI exits 5 on it (`cli/errors.rs`).
pub const REASON: &str = "admission_refused";
/// `_meta.acpmux` field that admits past the checks.
pub const FORCE_FIELD: &str = "forceAdmit";

const NO_REGISTRY: &str = "no fleet registry";

/// Disk pressure reported by the hygiene reconciler: advisory, just like the lane cap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct UnderFloor {
    flag: PathBuf,
}

impl UnderFloor {
    fn warning(&self, local: bool) -> String {
        let host = if local { super::start_gate::host_label() } else { "this machine" };
        let source = if local {
            format!("{} exists", self.flag.display())
        } else {
            "worktree-reclaim says so".into()
        };
        format!(
            "{host}'s disk is under its free-space floor ({source}); started anyway, as a floor only warns. Reclaim idle owned data or start the next session on a host with more room."
        )
    }
}

/// A create at or past this host's `lanes.max_lanes`: started, with a warning.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct OverCap {
    pub live: usize,
    pub max: u64,
    pub machine: String,
    pub source: PathBuf,
}

impl OverCap {
    /// The warning; `local` as in [`Ask::local`], `peers` as in [`Ask::peers`]. `instead`:
    /// where the placement engine would put it (`placement::placed`), when anywhere.
    fn warning(&self, local: bool, peers: bool, instead: Option<&str>) -> String {
        let host = if local { super::start_gate::host_label() } else { "this machine" };
        let source = if local {
            format!("lanes.max_lanes of {} in {}", self.machine, self.source.display())
        } else {
            "lanes.max_lanes in the fleet registry".into()
        };
        let next = match instead {
            Some(placed) => format!("Next time try `acpmux new --machine auto` ({placed})."),
            None if local && peers => "No connected host has room either.".into(),
            None => "Next time start it on another host.".into(),
        };
        format!(
            "{host} has {} live sessions, at its cap of {} ({source}); started anyway, as a cap only warns. {next}",
            self.live, self.max
        )
    }
}

/// What the checks read, so a test can give its own.
pub(crate) struct Inputs<'a> {
    pub flag: Option<&'a Path>,
    pub registry: Option<&'a Value>,
    /// The registry file is there but could not be read, with no good copy.
    pub unreadable: bool,
    /// Where the registry was read, for the warning.
    pub source: &'a Path,
    pub machine: Option<&'a str>,
    pub live: usize,
}

/// Advisory floor and cap warnings, plus why no cap applied (for the log).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Verdict {
    pub under_floor: Option<UnderFloor>,
    pub over: Option<OverCap>,
    pub uncapped: Option<String>,
}

/// The verdict for `inputs`.
pub(crate) fn check(inputs: &Inputs<'_>) -> Verdict {
    let under_floor = inputs
        .flag
        .filter(|f| f.try_exists().unwrap_or(true))
        .map(|flag| UnderFloor { flag: flag.to_path_buf() });
    let uncapped = |why: String| Verdict {
        under_floor: under_floor.clone(),
        uncapped: Some(why),
        ..Verdict::default()
    };
    let Some(registry) = inputs.registry else {
        if inputs.unreadable {
            return uncapped(format!(
                "fleet registry {} cannot be read, so the lane cap is unknown",
                inputs.source.display()
            ));
        }
        return uncapped(NO_REGISTRY.into());
    };
    let Some(machine) = inputs.machine else {
        return uncapped("this host is no registry machine".into());
    };
    let Some(max) = registry
        .pointer(&format!(
            "/machines/{}/lanes/max_lanes",
            machine.replace('~', "~0").replace('/', "~1")
        ))
        .and_then(Value::as_u64)
    else {
        return uncapped(format!("no lanes entry with max_lanes for {machine}"));
    };
    let over = (inputs.live as u64 >= max).then(|| OverCap {
        live: inputs.live,
        max,
        machine: machine.to_owned(),
        source: inputs.source.to_path_buf(),
    });
    Verdict { under_floor, over, uncapped: None }
}

/// The registry machine this host is (module docs), lowercase names compared.
pub(crate) fn machine_of(registry: &Value, origin: Option<&str>, host: &str) -> Option<String> {
    let machines = registry.get("machines").and_then(Value::as_object)?;
    if let Some(name) = origin.filter(|o| !o.is_empty()) {
        return machines.contains_key(name).then(|| name.to_owned());
    }
    let host = host.trim().to_lowercase();
    let short = host.split('.').next().unwrap_or_default().to_owned();
    let names = |key: &str| -> Vec<String> {
        let words = |v: Option<&Value>| -> Vec<String> {
            v.and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_lowercase)
                .collect()
        };
        let mut all = vec![key.to_lowercase()];
        all.extend(words(machines.get(key).and_then(|m| m.get("aliases"))));
        all.extend(words(registry.pointer(&format!("/origins/{key}/hostnames"))));
        all
    };
    machines.keys().find(|k| names(k).iter().any(|n| *n == host || *n == short)).cloned()
}

fn user_home() -> Option<PathBuf> {
    std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from)
}

/// Where this host's fleet registry is (module docs): `FLEET_REGISTRY`, else
/// the first of the two usual copies that exists. True when the file is meant
/// to be there: `FLEET_REGISTRY` names it, or the lookup could not tell (a folder
/// that cannot be searched). Only a clean "not found" moves on to the next copy.
fn registry_path() -> Option<(PathBuf, bool)> {
    if let Some(path) = std::env::var_os("FLEET_REGISTRY").filter(|p| !p.is_empty()) {
        return Some((path.into(), true));
    }
    let home = user_home()?;
    [".ssh/config.d/fleet-registry.json", "Projects/leo-workspace/machines/fleet-registry.json"]
        .iter()
        .map(|rel| home.join(rel))
        .find_map(|p| match p.try_exists() {
            Ok(true) => Some((p, false)),
            Ok(false) => None,
            Err(_) => Some((p, true)),
        })
}

/// The last registry read well, and where: it keeps the cap's warning while the registry
/// cannot be read, or while no copy is there at all (`read_registry`).
static LAST: StdMutex<Option<(PathBuf, Value)>> = StdMutex::new(None);

/// Where the registry is read from: `registry_path`, else, with no copy there
/// (a refresh that renames or rewrites it), where the last good copy came from,
/// so that copy keeps the cap's warning. Only a host that never read one has no registry.
fn registry_source() -> (PathBuf, bool) {
    registry_path().unwrap_or_else(|| {
        let last = LAST.lock().unwrap_or_else(|e| e.into_inner());
        (last.as_ref().map(|(p, _)| p.clone()).unwrap_or_default(), false)
    })
}

/// The registry at `source`, and whether it is there but unreadable. One that
/// cannot be read or parsed (a partial write, a permission error) answers with
/// the last copy read from the same path, so a bad read never drops the cap's
/// warning; with none it is unreadable, which is logged. A `set` path
/// (`FLEET_REGISTRY`) that is missing is unreadable too.
fn read_registry(source: &Path, set: bool) -> (Option<Value>, bool) {
    read_registry_in(&mut LAST.lock().unwrap_or_else(|e| e.into_inner()), source, set)
}

/// [`read_registry`] with its last good copy kept in `last`.
fn read_registry_in(
    last: &mut Option<(PathBuf, Value)>,
    source: &Path,
    set: bool,
) -> (Option<Value>, bool) {
    let read = std::fs::read(source)
        .map_err(|e| e.to_string())
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).map_err(|e| e.to_string()));
    match read {
        Ok(registry) => {
            *last = Some((source.to_owned(), registry.clone()));
            (Some(registry), false)
        }
        Err(e) => {
            let kept = last.as_ref().filter(|(p, _)| p == source).map(|(_, r)| r.clone());
            let there =
                set || (!source.as_os_str().is_empty() && source.try_exists().unwrap_or(true));
            if there {
                tracing::warn!(
                    path = %source.display(),
                    kept = kept.is_some(),
                    "fleet registry unreadable: {e}"
                );
            }
            let unreadable = there && kept.is_none();
            (kept, unreadable)
        }
    }
}

/// Creates admitted and not yet done (`Admitted`), counted with the live
/// sessions: concurrent creates at the cap cannot all pass the count. Each
/// holds the id of the session it made once that is inserted (`claim`), so a
/// create whose session already runs is counted once, as that session.
#[derive(Default)]
pub(crate) struct Admitting(StdMutex<Vec<Arc<Making>>>);

/// One admitted create: the name it asked for, and the id of the session it made.
#[derive(Default)]
pub(crate) struct Making {
    made: OnceLock<String>,
}

/// One admitted create, counted until it is dropped (its create ended, made or not).
pub(crate) struct Admitted<'a> {
    admitting: &'a Admitting,
    made: Arc<Making>,
    /// Started past the lane cap: `{"warning", "suggestedHost", "live", "maxLanes"}`,
    /// which the create returns as `_meta.acpmux.admission` and the CLI prints.
    pub warning: Option<Value>,
}

tokio::task_local! {
    /// The admitted create this task runs (`Admitted::run`).
    static MAKING: Arc<Making>;
}

impl Admitted<'_> {
    /// Runs the create `f`: the session it inserts is this admission's (`claim`).
    /// Boxed: a create's future is large, and moved by value it overflows the stack.
    pub(crate) async fn run<F: std::future::Future>(&self, f: F) -> F::Output {
        MAKING.scope(self.made.clone(), Box::pin(f)).await
    }
}

/// A new session `id` was inserted: the admitted create running in this task
/// (if any) made it. Called under the sessions lock, so the count never sees
/// the session and its admission apart.
pub(super) fn claim(id: &str) {
    let _ = MAKING.try_with(|making| making.made.set(id.to_owned()));
}

/// A session counts as live when its harness runs: a live status, or (any
/// status but Closed) an agent host still running for it.
fn is_live(status: SessionStatus, hosted: bool) -> bool {
    match status {
        SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting => true,
        SessionStatus::Closed => false,
        SessionStatus::Idle | SessionStatus::Disconnected => hosted,
    }
}

/// The live sessions `live` plus the admitted creates whose session is not one of
/// them: a create is counted once, as its session once that runs.
fn counted(live: &std::collections::HashSet<&str>, open: &[Arc<Making>]) -> usize {
    live.len()
        + open.iter().filter(|m| m.made.get().is_none_or(|id| !live.contains(id.as_str()))).count()
}

impl Drop for Admitted<'_> {
    fn drop(&mut self) {
        let mut open = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
        open.retain(|m| !Arc::ptr_eq(m, &self.made));
    }
}

impl Hub {
    /// This host's sessions whose harness runs (`hosted`: those with a running
    /// agent host), plus the admitted creates whose session is not (yet) one of them.
    /// `hosted` is read before the lock: a session whose host comes back after it is
    /// a resume of an existing session, which the cap never refuses either, so no
    /// later snapshot could hold it back.
    fn live_sessions(
        &self,
        open: &[Arc<Making>],
        hosted: &std::collections::HashSet<String>,
    ) -> usize {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let live: std::collections::HashSet<&str> = sessions
            .iter()
            .filter(|s| is_live(s.status(), hosted.contains(&s.id)))
            .map(|s| s.id.as_str())
            .collect();
        counted(&live, open)
    }

    /// Whether a new session may start here (module docs). Hold the returned
    /// guard until the create ends: until then it counts as a live session.
    pub(crate) async fn admit_new(&self, ask: Ask<'_>) -> Result<Admitted<'_>, RpcError> {
        let flag = user_home().map(|h| h.join(".cache/worktree-reclaim/under-floor"));
        let read = tokio::task::spawn_blocking(move || {
            let (source, set) = registry_source();
            let (registry, unreadable) = read_registry(&source, set);
            let origin = std::env::var("FLEET_ORIGIN").ok();
            let machine = registry
                .as_ref()
                .and_then(|r| machine_of(r, origin.as_deref(), super::start_gate::host_label()));
            // Running agent hosts: after a restart a session reads Idle until a
            // prompt reattaches its host, but the host runs all the same.
            let hosted = Hub::live_host_sessions();
            // This machine's readings for the shadow verdict: none of them waits.
            let here = crate::shadow_admission::local_candidate();
            (flag, registry, unreadable, source, machine, hosted, here)
        });
        let (flag, registry, unreadable, source, machine, hosted, here) =
            read.await.map_err(|e| RpcError::internal(e.to_string()))?;
        // Count and reserve under one lock, then render warnings after releasing it.
        let (verdict, mut admitted) = {
            let mut admitting = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
            let live = self.live_sessions(&admitting, &hosted);
            let verdict = check(&Inputs {
                flag: flag.as_deref(),
                registry: registry.as_ref(),
                unreadable,
                source: &source,
                machine: machine.as_deref(),
                live,
            });
            let made = Arc::new(Making::default());
            admitting.push(made.clone());
            (verdict, Admitted { admitting: &self.admitting, made, warning: None })
        };
        // Logged beside the admission it never changes (`shadow_admission.rs`).
        crate::shadow_admission::record("admit", Some(&here.name), std::slice::from_ref(&here));
        match verdict.uncapped {
            Some(why) if why == NO_REGISTRY => {
                tracing::debug!("session admitted with no lane cap: {why}")
            }
            Some(why) if unreadable => tracing::warn!("session admitted with no lane cap: {why}"),
            Some(why) => tracing::info!("session admitted with no lane cap: {why}"),
            None => {}
        }
        admitted.warning =
            verdict.over.map(|over| self.over_cap_warning(&over, registry.as_ref(), &ask));
        if let Some(floor) = verdict.under_floor {
            let text = floor.warning(ask.local);
            tracing::warn!(caller = ask.who, "session/new admitted below the disk floor: {text}");
            let mut warning = admitted.warning.take().unwrap_or_else(|| json!({}));
            let combined = match warning.get("warning").and_then(Value::as_str) {
                Some(cap) => format!("{text} {cap}"),
                None => text,
            };
            warning.set("warning", json!(combined));
            warning.set("underFloor", json!(true));
            admitted.warning = Some(warning);
        }
        tracing::debug!(
            caller = ask.who,
            name = ask.name.as_deref(),
            force_admit = ask.force && ask.can_force,
            person = ask.person,
            "session/new admitted; disk floors and lane caps are advisory"
        );
        Ok(admitted)
    }
}

impl Hub {
    /// The warning of a create started past the lane cap, logged, with where the
    /// placement engine would put it instead from the connected peers' last
    /// readings (`server/place.rs` `pick` weighs the same hosts, this one too).
    /// A caller that may not learn host names (a Web client) or this host's peers (a peer
    /// daemon's connection) gets no host.
    fn over_cap_warning(&self, over: &OverCap, registry: Option<&Value>, ask: &Ask<'_>) -> Value {
        use crate::placement::{Candidate, Work};
        let verdict = (ask.local && ask.peers).then(|| {
            let peers: Vec<Candidate> = self
                .peers()
                .into_iter()
                .filter(|p| p.get("connected").and_then(Value::as_bool) == Some(true))
                .filter_map(|p| Candidate::peer(&p))
                .collect();
            let verdict = crate::placement::place(&peers, registry, Work::Agent);
            crate::shadow_admission::with_shadow("over-cap", verdict, &peers)
        });
        // A pick that has no room either (`overloaded`) is no better a place: no suggestion.
        let verdict =
            verdict.filter(|v| v.get("overloaded").and_then(Value::as_bool) != Some(true));
        let placed = verdict.as_ref().and_then(crate::placement::placed);
        let host = verdict.as_ref().and_then(|v| v.get("pick")).and_then(Value::as_str);
        let text = over.warning(ask.local, ask.peers, placed.as_deref());
        tracing::warn!(
            caller = ask.who,
            live = over.live,
            max = over.max,
            suggested = host,
            "session/new admitted past the lane cap: {text}"
        );
        let mut warning = json!({"warning": text, "live": over.live, "maxLanes": over.max});
        if let Some(host) = host {
            warning.set("suggestedHost", json!(host));
        }
        warning
    }
}

/// Who asks for a new session, for `Hub::admit_new`.
pub(crate) struct Ask<'a> {
    /// Legacy force-admit provenance, kept for compatibility and logging.
    pub force: bool,
    pub can_force: bool,
    pub person: bool,
    pub name: Option<String>,
    /// The caller session or the connection, for the log.
    pub who: &'a str,
    /// The warning may name this host and its paths (not a Web client, here or
    /// through a peer).
    pub local: bool,
    /// The warning may name this host's peers (`suggestedHost`): not a peer daemon's
    /// connection, which never learns them (`server/redact.rs` `hide_peers_from_peer`).
    pub peers: bool,
}

#[cfg(test)]
mod tests;
