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
//!   2026-10-26). A create whose client asks (`_meta.acpmux.placeRedirect`) starts on
//!   that peer instead (`admission_redirect.rs`), and here, warned, when it cannot.
//!   The registry is `FLEET_REGISTRY` when set,
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
//! remains accepted for compatibility; floors and host caps never refuse a session. The one cap that refuses is an agent lane's fan-out cap (`lane_fanout.rs`), which `--force-admit` passes with a warning. `session/new` (with no adopt, or an adopt that may fork), `session/fork`,
//! the composer's aside (`_acpmux/ask`) and sub-session starts are checked; a
//! send, a resume, a restart, an adopt that never forks, a side chat (`btw.rs`)
//! and a handoff target never are. A Claude create while the sr2 model pool is short starts with a
//! warning that suggests Codex when it has room (`pool_pressure.rs`). An admitted create counts as live until it ends, so of concurrent
//! creates at the cap every one past it is warned.

use super::*;
use cmux_json::JsonSet as _;
use std::sync::OnceLock;

/// `data.reason` of a refusal; the CLI exits 5 on it (`cli/errors.rs`).
pub const REASON: &str = "admission_refused";
/// `_meta.acpmux` field that admits past the checks.
pub const FORCE_FIELD: &str = "forceAdmit";
/// `_meta.acpmux.autoPlace` marks a start whose place choice was Auto.
pub const AUTO_PLACE_FIELD: &str = "autoPlace";

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
    /// `scaling`: with nowhere to put it, the fleet is adding a machine (`admission_scale_up.rs`).
    fn warning(&self, local: bool, peers: bool, instead: Option<&str>, scaling: bool) -> String {
        let host = if local { super::start_gate::host_label() } else { "this machine" };
        let source = if local {
            format!("lanes.max_lanes of {} in {}", self.machine, self.source.display())
        } else {
            "lanes.max_lanes in the fleet registry".into()
        };
        let next = match instead {
            Some(placed) => format!("Next time try `acpmux new --machine auto` ({placed})."),
            None if scaling && local && peers => {
                "No connected host has room either, so a machine is being added to the fleet for the next ones.".into()
            }
            None if scaling => "A machine is being added to the fleet for the next ones.".into(),
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
    /// Under the cap, this create takes its last slot (no free one is left after it):
    /// where a warm spare is asked for (`admission_scale_up::wants_warm_spare`).
    pub last_slot: Option<OverCap>,
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
    let Some(max) = max_lanes(registry, machine) else {
        return uncapped(format!("no lanes entry with max_lanes for {machine}"));
    };
    let at = || OverCap {
        live: inputs.live,
        max,
        machine: machine.to_owned(),
        source: inputs.source.to_path_buf(),
    };
    let over = (inputs.live as u64 >= max).then(at);
    let last_slot = (over.is_none() && inputs.live as u64 + 1 >= max).then(at);
    Verdict { under_floor, over, last_slot, uncapped: None }
}

/// `machine`'s `lanes.max_lanes` in `registry`, at most 1 with one lane per machine
/// (`lane_place.one_lane_per_host`: a second lane there is over); `None`: no cap.
pub(crate) fn max_lanes(registry: &Value, machine: &str) -> Option<u64> {
    let max = registry
        .pointer(&format!(
            "/machines/{}/lanes/max_lanes",
            machine.replace('~', "~0").replace('/', "~1")
        ))
        .and_then(Value::as_u64)?;
    Some(if super::admission_scale_up::one_per_host(Some(registry)) { max.min(1) } else { max })
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
pub(super) fn registry_source() -> (PathBuf, bool) {
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
pub(super) fn read_registry(source: &Path, set: bool) -> (Option<Value>, bool) {
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
    /// The lane an agent's create is for (`lane_fanout.rs`), counted against its cap.
    lane: Option<String>,
}

impl Making {
    pub(crate) fn for_lane(lane: Option<String>) -> Self {
        Self { made: OnceLock::new(), lane }
    }
    pub(crate) fn lane(&self) -> Option<&str> {
        self.lane.as_deref()
    }
    pub(crate) fn made_id(&self) -> Option<&str> {
        self.made.get().map(String::as_str)
    }
    #[cfg(test)]
    pub(crate) fn set_made(&self, id: &str) {
        let _ = self.made.set(id.to_owned());
    }
}

/// One admitted create, counted until it is dropped (its create ended, made or not).
pub(crate) struct Admitted<'a> {
    admitting: &'a Admitting,
    made: Arc<Making>,
    /// Started past the lane cap: `{"warning", "suggestedHost", "live", "maxLanes",
    /// "scalingUp"}` (`scalingUp`: the fleet is adding a machine, `admission_scale_up.rs`),
    /// which the create returns as `_meta.acpmux.admission` and the CLI prints.
    pub warning: Option<Value>,
    /// The peer the placement engine put this create on, which it starts on
    /// instead of here (`admission_redirect.rs`); None to start here.
    pub placed: Option<super::admission_redirect::Placed>,
    /// The filler session whose room this start takes, hibernated once the create goes ahead
    /// here (`admission_redirect::free_filler`), with why there was no room.
    pub freed: Option<(String, super::admission_redirect::Reason)>,
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
pub(super) fn is_live(status: SessionStatus, hosted: bool) -> bool {
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
    ) -> (usize, Vec<String>) {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let live: Vec<&Arc<Session>> =
            sessions.iter().filter(|s| is_live(s.status(), hosted.contains(&s.id))).collect();
        // Filler work a real start may take the room of (`admission_redirect::is_filler`).
        let fillers = live
            .iter()
            .filter(|s| super::admission_redirect::is_filler(s))
            .map(|s| s.id.clone())
            .collect();
        let live: std::collections::HashSet<&str> = live.iter().map(|s| s.id.as_str()).collect();
        (counted(&live, open), fillers)
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
            // The sr2 pool's pressure, from sr2_pool's cache file (`pool_pressure.rs`).
            let pool = super::pool_pressure::current();
            (flag, registry, unreadable, source, machine, hosted, here, pool)
        });
        let (flag, registry, unreadable, source, machine, hosted, here, pool) =
            read.await.map_err(|e| RpcError::internal(e.to_string()))?;
        // Count and reserve under one lock, then render warnings after releasing it.
        let (verdict, fillers, mut admitted, lane) = {
            let mut admitting = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
            let (live, fillers) = self.live_sessions(&admitting, &hosted);
            // An agent's create counts against its lane's fan-out cap (`lane_fanout.rs`): the one
            // cap here that refuses, as Leo asked ("Cap fan-out per lane").
            let lane = match ask.caller.filter(|_| !ask.person) {
                Some(caller) => {
                    let lane = self.lane_fanout(caller, &admitting, &hosted);
                    if lane.over() && !(ask.force && ask.can_force) {
                        tracing::warn!(caller = ask.who, lane = %lane.id, live = lane.live, max = lane.max, "session/new refused: lane fan-out cap");
                        return Err(super::lane_fanout::refusal(
                            &lane.id,
                            lane.live,
                            lane.max,
                            lane.source,
                        ));
                    }
                    Some(lane)
                }
                None => None,
            };
            let verdict = check(&Inputs {
                flag: flag.as_deref(),
                registry: registry.as_ref(),
                unreadable,
                source: &source,
                machine: machine.as_deref(),
                live,
            });
            let made = Arc::new(Making::for_lane(lane.as_ref().map(|l| l.id.clone())));
            admitting.push(made.clone());
            (
                verdict,
                fillers,
                Admitted {
                    admitting: &self.admitting,
                    made,
                    warning: None,
                    placed: None,
                    freed: None,
                },
                lane,
            )
        };
        // Logged beside the admission; a create that asks moves on its verdict
        // (`admission_redirect.rs`), and nothing else does.
        let shadow =
            crate::shadow_admission::record("admit", Some(&here.name), std::slice::from_ref(&here));
        // Busy: the host-budget formula reads it saturated, never only its readings unknown.
        let busy = shadow.get("would_defer").and_then(Value::as_bool) == Some(true)
            && shadow
                .get("reason")
                .and_then(Value::as_str)
                .is_some_and(|r| r.starts_with("saturated"));
        match &verdict.uncapped {
            Some(why) if why == NO_REGISTRY => {
                tracing::debug!("session admitted with no lane cap: {why}")
            }
            Some(why) if unreadable => tracing::warn!("session admitted with no lane cap: {why}"),
            Some(why) => tracing::info!("session admitted with no lane cap: {why}"),
            None => {}
        }
        let reason = super::admission_redirect::considered(
            &ask,
            verdict.uncapped.is_none(),
            verdict.over.is_some(),
            busy,
        );
        // The connected peers as the placement engine weighs them, once for the move
        // and the warning.
        let warm_spare =
            super::admission_scale_up::warm_spare_on(registry.as_ref(), |k| std::env::var(k).ok());
        let mut peers = (reason.is_some()
            || verdict.over.is_some()
            || (warm_spare && verdict.last_slot.is_some()))
        .then(|| self.peer_verdict(registry.as_ref()));
        let peer_room = peers
            .as_ref()
            .is_some_and(|verdict| super::admission_scale_up::room_elsewhere(verdict).is_some());
        let mut scaling_up = false;
        let mut auto_joined = false;
        let no_peer_room = verdict.over.is_some()
            && peers.as_ref().is_some_and(|verdict| {
                super::admission_scale_up::room_elsewhere(verdict).is_none()
            });
        // A create that may move (`reason`) waits for the added machine as an Auto one does:
        // a cap routes the start elsewhere and never only warns (cmuxterm-hq lane-router RFD).
        if should_wait_for_scale_up(ask.auto || reason.is_some(), no_peer_room)
            && let Some(over) = verdict.over.as_ref()
        {
            // Subscribe before triggering the provider so a fast join cannot be missed.
            let peer_states = self.peer_states();
            let states = peer_states.subscribe();
            let (trigger, result) = self.scale_up_wait(over, registry.as_ref());
            scaling_up = trigger.scaling();
            if scaling_up && let Some(result) = result {
                // Tell the caller now that a machine is being added and its start waits for it.
                if let Some(waiting) = &ask.waiting {
                    waiting(waiting_note(over, &ask));
                }
                let joined = wait_for_scale_up(
                    result,
                    peer_states,
                    states,
                    super::admission_scale_up::AUTO_WAIT_BOUND,
                )
                .await;
                if joined {
                    let refreshed = self.peer_verdict(registry.as_ref());
                    if super::admission_scale_up::room_elsewhere(&refreshed).is_some() {
                        peers = Some(refreshed);
                        auto_joined = true;
                    }
                }
            }
        } else if let Some(over) = verdict.over.as_ref()
            && peers
                .as_ref()
                .is_some_and(|verdict| super::admission_scale_up::room_elsewhere(verdict).is_none())
        {
            let (trigger, _) = self.scale_up_wait(over, registry.as_ref());
            scaling_up = trigger.scaling();
        } else if let Some(last) = verdict.last_slot.as_ref()
            && super::admission_scale_up::wants_warm_spare(warm_spare, true, peer_room)
        {
            // Warm spare (default off): this create takes the last free slot and no
            // connected host has room, so one machine is asked for now, ahead of the next
            // start. The run's single flight and cooldown keep it to one; once it joins, a
            // peer has room and nothing more is asked.
            let (trigger, _) = self.scale_up_wait(last, registry.as_ref());
            tracing::info!(
                live = last.live,
                max = last.max,
                scaling = trigger.scaling(),
                "scale-up: warm spare"
            );
        }
        if let (Some(reason), Some(filler)) = (reason, fillers.first()) {
            // A filler's room is this start's: it starts here, never moved for it.
            super::admission_redirect::log(
                "local_filler_room",
                reason,
                None,
                Some(filler.as_str()),
            );
            admitted.freed = Some((filler.clone(), reason));
        } else if let (Some(reason), Some(peers)) = (reason, &peers) {
            let live = verdict.over.as_ref().map_or(0, |o| o.live);
            let max = verdict.over.as_ref().map(|o| o.max);
            admitted.placed = super::admission_redirect::pick(peers, reason, live, max);
            // A placed one is logged by its create once it started there, or failed.
            if admitted.placed.is_none() {
                super::admission_redirect::log("local_no_room", reason, None, None);
            }
        } else if auto_joined
            && admitted.placed.is_none()
            && let Some(over) = verdict.over.as_ref()
        {
            admitted.placed = peers.as_ref().and_then(|peers| {
                super::admission_redirect::pick(
                    peers,
                    super::admission_redirect::Reason::OverCap,
                    over.live,
                    Some(over.max),
                )
            });
        } else if super::admission_scale_up::uses_spare(warm_spare, ask.auto, peer_room)
            && admitted.placed.is_none()
            && let Some(over) = verdict.over.as_ref()
        {
            // Warm spare: an Auto start past the cap takes the connected host with room
            // (the spare) at once, as a joined one does, instead of waiting for a machine.
            admitted.placed = peers.as_ref().and_then(|peers| {
                super::admission_redirect::pick(
                    peers,
                    super::admission_redirect::Reason::OverCap,
                    over.live,
                    Some(over.max),
                )
            });
        } else if verdict.over.is_some() && verdict.uncapped.is_none() {
            // Past a lane host's cap, a create that may not move (an old client, a person,
            // a peer's or a Web caller) starts here as before.
            let reason = super::admission_redirect::Reason::OverCap;
            super::admission_redirect::log("local_not_asked", reason, None, Some(ask.who));
        }
        admitted.warning = match (&verdict.over, &peers) {
            (Some(over), Some(peers)) => Some(self.over_cap_warning(over, peers, &ask, scaling_up)),
            _ => None,
        };
        if let Some(lane) = lane.as_ref().filter(|l| l.over()) {
            let text = super::lane_fanout::forced_warning(&lane.id, lane.live, lane.max);
            tracing::warn!(
                caller = ask.who,
                "session/new forced past the lane fan-out cap: {text}"
            );
            admitted.warning =
                Some(super::lane_fanout::add_warning(admitted.warning.take(), &text, lane));
        }
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
        if let Some(pressure) = pool {
            let family = self.admission_family(ask.harness.as_deref()).await;
            if super::pool_pressure::is_claude(&family) {
                let text = super::pool_pressure::warning(&pressure);
                tracing::warn!(
                    caller = ask.who,
                    family,
                    "session/new admitted under pool pressure: {text}"
                );
                let mut warning = admitted.warning.take().unwrap_or_else(|| json!({}));
                let combined = match warning.get("warning").and_then(Value::as_str) {
                    Some(before) => format!("{before} {text}"),
                    None => text,
                };
                warning.set("warning", json!(combined));
                warning.set("poolPressure", super::pool_pressure::field(&pressure));
                admitted.warning = Some(warning);
            }
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
    /// The family of harness `name` (a family or profile name), or of the default harness.
    async fn admission_family(&self, name: Option<&str>) -> String {
        let cfg = self.config.read().await;
        let Some(name) = name.map(str::to_owned).or_else(|| cfg.default_harness.clone()) else {
            // acpmux's own default is Claude Code.
            return "claude".to_owned();
        };
        cfg.resolve_harness(&name).ok().and_then(|profile| cfg.family(&profile)).unwrap_or(name)
    }

    /// Where the placement engine would put a create from the connected peers' last
    /// readings (`server/place.rs` `pick` weighs the same hosts, this one too), with
    /// the shadow verdict of its pick (`shadow_admission.rs`).
    pub(super) fn peer_verdict(&self, registry: Option<&Value>) -> Value {
        use crate::placement::{Candidate, Work};
        let peers: Vec<Candidate> = self
            .peers()
            .into_iter()
            // The hosts `_acpmux/place` weighs (`placement::peer_down`): never a machine
            // only the hub reaches, where the suggested start would fail with `no peer`.
            .filter(|p| crate::placement::peer_down(p).is_none())
            .filter_map(|p| Candidate::peer(&p))
            .collect();
        let mut verdict = crate::placement::place(&peers, registry, Work::Agent);
        super::admission_scale_up::solo_pick(&mut verdict, registry);
        crate::shadow_admission::with_shadow("over-cap", verdict, &peers)
    }

    /// The warning of a create started past the lane cap, logged, with where the
    /// placement engine would put it instead (`peer_verdict`).
    /// A caller that may not learn host names (a Web client) or this host's peers (a peer
    /// daemon's connection) gets no host.
    fn over_cap_warning(
        &self,
        over: &OverCap,
        verdict: &Value,
        ask: &Ask<'_>,
        scaling: bool,
    ) -> Value {
        // Weighed for every caller: whether a peer has room decides the scale-up too.
        let placed = super::admission_scale_up::room_elsewhere(verdict);
        // No connected host has room: the fleet adds one (`admission_scale_up.rs`).
        // `scaling` was captured before an Auto wait, so its warning remains visible
        // while the request waits for the new peer.
        // Only a caller that may learn this host's peers hears where it could have gone.
        let shown = ask.local && ask.peers;
        let placed = placed.filter(|_| shown);
        let host = verdict.get("pick").and_then(Value::as_str).filter(|_| placed.is_some());
        let text = over.warning(ask.local, ask.peers, placed.as_deref(), scaling);
        tracing::warn!(
            caller = ask.who,
            live = over.live,
            max = over.max,
            suggested = host,
            scaling,
            "session/new admitted past the lane cap: {text}"
        );
        let mut warning = json!({"warning": text, "live": over.live, "maxLanes": over.max});
        if let Some(host) = host {
            warning.set("suggestedHost", json!(host));
        }
        if scaling {
            warning.set("scalingUp", json!(true));
        }
        warning
    }

    /// Asks the registry's `lane_overflow` providers for a machine. The
    /// receiver lets Auto wait for a provider failure or a peer join.
    fn scale_up_wait(
        &self,
        over: &OverCap,
        registry: Option<&Value>,
    ) -> (super::admission_scale_up::Trigger, Option<super::admission_scale_up::ResultReceiver>)
    {
        use super::admission_scale_up::{ScaleUp, plan, workspace_of};
        let workspace = workspace_of(&over.source);
        let Some(plan) = registry
            .and_then(|registry| plan(registry, &over.source, &over.machine, workspace.as_deref()))
        else {
            return (super::admission_scale_up::Trigger::Cooling, None);
        };
        ScaleUp::daemon().trigger_wait(&self.scope, plan, std::time::Instant::now())
    }
}

/// `_acpmux/admission_waiting`'s params: the over-cap warning with `scalingUp`, and how long the
/// start waits at most for the new machine before it starts here.
fn waiting_note(over: &OverCap, ask: &Ask<'_>) -> Value {
    let host = if ask.local { super::start_gate::host_label() } else { "this machine" };
    let secs = super::admission_scale_up::AUTO_WAIT_BOUND.as_secs();
    let warning = format!(
        "{host} has {} live sessions, at its cap of {}, and no connected host has room, so a machine is being added to the fleet. This start waits for it (up to {secs} s), then starts there, or here if it does not join.",
        over.live, over.max
    );
    json!({
        "warning": warning,
        "live": over.live,
        "maxLanes": over.max,
        "scalingUp": true,
        "waitSecs": secs,
    })
}

/// `movable`: the caller chose Auto, or a create past this lane host's cap that may move
/// (`admission_redirect::considered`). Only a create tied here (a person's, an explicit
/// machine, a named folder) never waits.
fn should_wait_for_scale_up(movable: bool, no_peer_room: bool) -> bool {
    movable && no_peer_room
}

/// Waits for the provider to fail or for a connected peer notification.
/// A successful provider answer is not enough because the peer must be
/// registered before placement can forward the create.
async fn wait_for_scale_up(
    mut result: super::admission_scale_up::ResultReceiver,
    peer_states: &crate::peer_states::PeerStates,
    mut states: tokio::sync::broadcast::Receiver<Value>,
    bound: std::time::Duration,
) -> bool {
    use crate::protocol::peer_state::{MachineLink, PeerStateChanged};
    let mut expected = None;
    let deadline = tokio::time::sleep(bound);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            changed = result.changed() => {
                if changed.is_err() {
                    return false;
                }
                match result.borrow().as_ref() {
                    Some(Some(host)) => {
                        expected = Some(host.clone());
                        // The peer can connect before the provider prints its answer. The
                        // retained state makes that ordering safe without polling.
                        if peer_states.snapshot().iter().any(|note| {
                            note.get(crate::peer_states::STATE_NOTE)
                                .and_then(|note| serde_json::from_value::<PeerStateChanged>(note.clone()).ok())
                                .is_some_and(|note| note.link == MachineLink::Connected && Some(note.peer) == expected)
                        }) {
                            return true;
                        }
                    }
                    Some(None) => return false,
                    None => {}
                }
            }
            note = states.recv() => {
                let Ok(note) = note else { return false };
                let connected = note
                    .get(crate::peer_states::STATE_NOTE)
                    .and_then(|note| serde_json::from_value::<PeerStateChanged>(note.clone()).ok())
                    .is_some_and(|note| {
                        note.link == MachineLink::Connected
                            && expected.as_deref() == Some(note.peer.as_str())
                    });
                if connected {
                    return true;
                }
            }
            _ = &mut deadline => return false,
        }
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
    /// The create asked to start on a peer when this host has no room, and nothing ties
    /// it here (`admission_redirect.rs` `movable`).
    pub redirect: bool,
    /// The caller chose Auto as the machine/place. Explicit machine choices never wait.
    pub auto: bool,
    /// Tells the caller, once, that its Auto start waits for a machine being added
    /// (`_acpmux/admission_waiting`); None where nobody listens.
    pub waiting: Option<Waiting<'a>>,
    /// The harness (family or profile) asked for; None: the default harness. A Claude one
    /// is warned while the sr2 pool is short (`pool_pressure.rs`).
    pub harness: Option<String>,
    /// The agent session this create runs in, proven by its connection or the
    /// `start_session` parent; None for a person, the app or a script. Its lane's
    /// fan-out cap applies (`lane_fanout.rs`).
    pub caller: Option<&'a str>,
}

/// [`Ask::waiting`]: sends `_acpmux/admission_waiting`'s params to the creating connection.
pub(crate) type Waiting<'a> = Box<dyn Fn(Value) + Send + Sync + 'a>;

#[cfg(test)]
#[path = "admission_tests.rs"]
mod tests;
