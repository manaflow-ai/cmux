//! Admission of a new session: whether this host has room for one more
//! (deputy-2, 2026-10-22). About 25 Codex reviewers started on huge-blue with
//! a raw `acpmux new` over reach went around lane-place's cap of 12, filled
//! the disk and pushed the load to 50-80. Every new session goes through the
//! daemon's create, so the daemon checks there, reading two files each time:
//!
//! - `~/.cache/worktree-reclaim/under-floor`, which worktree-reclaim writes
//!   while the disk is under its free-space floor: no new session at all;
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
//! admits past the floor, and the daemon logs who asked and what it overrode;
//! the person's own new chat on this host (its app pane, or the person key) is
//! admitted and logged too. `session/new` (with no adopt, or an adopt that may fork), `session/fork`,
//! the composer's aside (`_acpmux/ask`) and sub-session starts are checked; a
//! send, a resume, a restart, an adopt that never forks, a side chat (`btw.rs`)
//! and a handoff target never are. An admitted create counts as live until it ends, so of concurrent
//! creates at the cap every one past it is warned.

use super::*;
use std::sync::OnceLock;

/// `data.reason` of a refusal; the CLI exits 5 on it (`cli/errors.rs`).
pub const REASON: &str = "admission_refused";
/// `_meta.acpmux` field that admits past the checks.
pub const FORCE_FIELD: &str = "forceAdmit";

const NO_REGISTRY: &str = "no fleet registry";

/// Why a create is refused, with what the refusal names.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Refusal {
    UnderFloor { flag: PathBuf },
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
    /// The warning; `local` as in [`Refusal::error`]. `instead`: where the
    /// placement engine would put it (`placement::placed`), when anywhere.
    fn warning(&self, local: bool, instead: Option<&str>) -> String {
        let host = if local { super::start_gate::host_label() } else { "this machine" };
        let source = if local {
            format!("lanes.max_lanes of {} in {}", self.machine, self.source.display())
        } else {
            "lanes.max_lanes in the fleet registry".into()
        };
        let next = match instead {
            Some(placed) => format!("Next time try `acpmux new --host auto` ({placed})."),
            None if local => "No connected host has room either.".into(),
            None => "Next time start it on another host.".into(),
        };
        format!(
            "{host} has {} live sessions, at its cap of {} ({source}); started anyway, as a cap only warns. {next}",
            self.live, self.max
        )
    }
}

impl Refusal {
    fn why(&self) -> &'static str {
        match self {
            Self::UnderFloor { .. } => "under_floor",
        }
    }

    /// `local`: the caller may learn this host's name and paths (not a Web client).
    /// `can_force`: the caller's `--force-admit` is honoured (`Ask::can_force`).
    fn error(&self, local: bool, can_force: bool) -> RpcError {
        let host = if local { super::start_gate::host_label() } else { "this machine" };
        let what = match self {
            Self::UnderFloor { flag } => format!(
                "{host}'s disk is under its free-space floor ({}): no new session until worktree-reclaim frees space",
                if local {
                    format!("{} exists", flag.display())
                } else {
                    "worktree-reclaim says so".into()
                }
            ),
        };
        let data = json!({"reason": REASON, "why": self.why(), "retryable": true});
        let hint = if can_force {
            "--force-admit creates it anyway"
        } else {
            "--force-admit is honoured only on that machine itself, not from a Web client or a peer"
        };
        RpcError::new(-32000, format!("{what}; {hint}")).with_data(data)
    }
}

/// What the checks read, so a test can give its own.
pub(crate) struct Inputs<'a> {
    pub flag: Option<&'a Path>,
    pub registry: Option<&'a Value>,
    /// The registry file is there but could not be read, with no good copy.
    pub unreadable: bool,
    /// Where the registry was read, for the refusal.
    pub source: &'a Path,
    pub machine: Option<&'a str>,
    pub live: usize,
}

/// What the checks say of one create: refused (the floor), started past the
/// cap (warned), or why no cap applied (for the log).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Verdict {
    pub refusal: Option<Refusal>,
    pub over: Option<OverCap>,
    pub uncapped: Option<String>,
}

/// The verdict for `inputs`.
pub(crate) fn check(inputs: &Inputs<'_>) -> Verdict {
    // A marker that cannot be checked counts as there: the floor fails closed.
    if let Some(flag) = inputs.flag.filter(|f| f.try_exists().unwrap_or(true)) {
        let refusal = Some(Refusal::UnderFloor { flag: flag.to_path_buf() });
        return Verdict { refusal, ..Verdict::default() };
    }
    let uncapped = |why: String| Verdict { uncapped: Some(why), ..Verdict::default() };
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
    Verdict { over, ..Verdict::default() }
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
pub(crate) struct Admitting(StdMutex<Vec<Arc<Making>>>, tokio::sync::Notify);

/// One admitted create: the name it asked for, and the id of the session it made.
#[derive(Default)]
pub(crate) struct Making {
    name: Option<String>,
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

/// How long a refused create waits for another create of its name to end.
const NAME_WAIT: std::time::Duration = std::time::Duration::from_secs(120);

impl Admitting {
    /// Waits while `still` holds of the open creates, up to `limit` in all: every
    /// create's end wakes every waiter, so the limit is one deadline, never
    /// restarted by a wake. True when it still held as the wait ended.
    async fn wait_while(
        &self,
        limit: std::time::Duration,
        still: impl Fn(&[Arc<Making>]) -> bool,
    ) -> bool {
        let deadline = tokio::time::Instant::now() + limit;
        loop {
            // Listening before the check: a create that ends between the two
            // still wakes this wait.
            let wake = self.1.notified();
            tokio::pin!(wake);
            wake.as_mut().enable();
            if !still(&self.0.lock().unwrap_or_else(|e| e.into_inner())) {
                return false;
            }
            if tokio::time::timeout_at(deadline, wake).await.is_err() {
                return true;
            }
        }
    }
}

impl Drop for Admitted<'_> {
    fn drop(&mut self) {
        let mut open = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
        open.retain(|m| !Arc::ptr_eq(m, &self.made));
        drop(open);
        // A create refused while this one held its name waits for it (`admit_new`).
        self.admitting.1.notify_waiters();
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

    /// Whether a session named `name` is in the list.
    fn session_named(&self, name: &str) -> bool {
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        sessions.values().any(|s| s.meta().name == name)
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
            (flag, registry, unreadable, source, machine, hosted)
        });
        let (flag, registry, unreadable, source, machine, hosted) =
            read.await.map_err(|e| RpcError::internal(e.to_string()))?;
        let holds = |open: &[Arc<Making>], name: &String| {
            open.iter().any(|m| m.name.as_ref() == Some(name))
        };
        // Counted and reserved under one lock, in a scope of its own so no
        // await below holds it: no file I/O while it is held.
        let (refusal, live, held) = {
            let admitting = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
            let live = self.live_sessions(&admitting, &hosted);
            let Verdict { refusal, over, uncapped } = check(&Inputs {
                flag: flag.as_deref(),
                registry: registry.as_ref(),
                unreadable,
                source: &source,
                machine: machine.as_deref(),
                live,
            });
            // Takes the lock's guard and drops it: nothing after it holds the lock.
            let admitted = |mut open: std::sync::MutexGuard<'_, Vec<Arc<Making>>>| {
                let made = Arc::new(Making { name: ask.name.clone(), made: OnceLock::new() });
                open.push(made.clone());
                Admitted { admitting: &self.admitting, made, warning: None }
            };
            // Outside the fleet (no registry) that is every create: only a fleet host's gap is logged.
            match uncapped {
                Some(why) if why == NO_REGISTRY => {
                    tracing::debug!("session admitted with no lane cap: {why}")
                }
                Some(why) if unreadable => {
                    tracing::warn!("session admitted with no lane cap: {why}")
                }
                Some(why) => tracing::info!("session admitted with no lane cap: {why}"),
                None => {}
            }
            let Some(refusal) = refusal else {
                let mut admitted = admitted(admitting);
                admitted.warning = over.map(|o| self.over_cap_warning(&o, registry.as_ref(), &ask));
                return Ok(admitted);
            };
            let (who, why) = (ask.who, refusal.why());
            if ask.force {
                tracing::warn!(
                    caller = who,
                    why,
                    live,
                    "session/new admitted by force-admit past {refusal:?}"
                );
                return Ok(admitted(admitting));
            }
            // The person's own new chat (cmux NEXT, or the person's key): the cap
            // is for agents, and the app has no override to pass.
            if ask.person {
                tracing::info!(
                    caller = who,
                    why,
                    live,
                    "session/new admitted for the person past {refusal:?}"
                );
                return Ok(admitted(admitting));
            }
            let held = ask.name.as_ref().is_some_and(|n| holds(&admitting, n));
            (refusal, live, held)
        };
        let (who, why) = (ask.who, refusal.why());
        // A create of a name another create already holds (or made) lost the
        // race for that name, not for room: it says the name is taken, as the
        // create would, so `new --reuse` takes the session that won.
        if let Some(name) = &ask.name {
            if held {
                self.admitting.wait_while(NAME_WAIT, |open| holds(open, name)).await;
            }
            if self.session_named(name) {
                return Err(RpcError::invalid_params(format!("session name {name:?} is taken")));
            }
        }
        tracing::info!(caller = who, why, live, "session/new refused: {refusal:?}");
        Err(refusal.error(ask.local, ask.can_force))
    }
}

impl Hub {
    /// The warning of a create started past the lane cap, logged, with where the
    /// placement engine would put it instead from the connected peers' last
    /// readings (`server/place.rs` `pick` weighs the same hosts, this one too).
    /// A caller that may not learn host names (a Web client) gets no host.
    fn over_cap_warning(&self, over: &OverCap, registry: Option<&Value>, ask: &Ask<'_>) -> Value {
        use crate::placement::{Candidate, Work};
        let verdict = ask.local.then(|| {
            let peers: Vec<Candidate> = self
                .peers()
                .into_iter()
                .filter(|p| p.get("connected").and_then(Value::as_bool) == Some(true))
                .filter_map(|p| {
                    Some(Candidate {
                        name: p.get("name")?.as_str()?.to_owned(),
                        local: false,
                        health: p.get("health").cloned().unwrap_or(Value::Null),
                    })
                })
                .collect();
            crate::placement::place(&peers, registry, Work::Agent)
        });
        // A pick that has no room either (`overloaded`) is no better a place: no suggestion.
        let verdict =
            verdict.filter(|v| v.get("overloaded").and_then(Value::as_bool) != Some(true));
        let placed = verdict.as_ref().and_then(crate::placement::placed);
        let host = verdict.as_ref().and_then(|v| v.get("pick")).and_then(Value::as_str);
        let text = over.warning(ask.local, placed.as_deref());
        tracing::warn!(
            caller = ask.who,
            live = over.live,
            max = over.max,
            suggested = host,
            "session/new admitted past the lane cap: {text}"
        );
        let mut warning = json!({"warning": text, "live": over.live, "maxLanes": over.max});
        if let Some(host) = host {
            warning["suggestedHost"] = json!(host);
        }
        warning
    }
}

/// Who asks for a new session, for `Hub::admit_new`.
pub(crate) struct Ask<'a> {
    /// `_meta.acpmux.forceAdmit`: admitted past a refusal, logged. Set only
    /// where `can_force`.
    pub force: bool,
    /// The caller may force: this host's unix socket or app, never a Web client
    /// or a peer (as `--policy` and `--mode`).
    pub can_force: bool,
    /// The person asks here (this host's app pane, or the person key). A peer's
    /// app pane is not: a forwarded `via: app` is the forwarding client's word.
    pub person: bool,
    /// The caller session or the connection, for the log.
    pub who: &'a str,
    /// The name the create asks for, if any: a refusal while another create
    /// holds it says the name is taken instead.
    pub name: Option<String>,
    /// The refusal may name this host and its paths (not a Web client, here or
    /// through a peer).
    pub local: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_whose_agent_host_runs_is_live_whatever_its_status() {
        // After a daemon restart every kept session reads Idle until it is reattached.
        assert!(is_live(SessionStatus::Idle, true));
        assert!(is_live(SessionStatus::Disconnected, true));
        assert!(!is_live(SessionStatus::Idle, false));
        assert!(!is_live(SessionStatus::Closed, true));
        assert!(is_live(SessionStatus::Ready, false));
    }

    /// A registry that turns unreadable keeps its last good copy: a partial write
    /// never drops the cap's warning.
    #[test]
    fn an_unreadable_registry_keeps_the_last_good_copy() {
        let dir = std::env::temp_dir().join(format!("acpmux-reg-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        // Its own last good copy: the process-wide one is shared with every test that admits.
        let mut last = None;
        let mut read_registry = |source: &Path, set: bool| read_registry_in(&mut last, source, set);
        let path = dir.join("fleet-registry.json");
        std::fs::write(&path, br#"{"machines":{"m":{"max_lanes":1}}}"#).unwrap();
        let fresh = dir.join("first-read-truncated.json");
        std::fs::write(&fresh, br#"{"machines":"#).unwrap();
        assert_eq!(read_registry(&fresh, false), (None, true), "no good copy yet: unreadable");
        let good = read_registry(&path, false).0.unwrap();
        std::fs::write(&path, br#"{"machines":{"m":"#).unwrap();
        assert_eq!(read_registry(&path, false), (Some(good.clone()), false));
        assert_eq!(read_registry(&dir.join("never-there.json"), false), (None, false));
        // FLEET_REGISTRY names a file that is missing: unreadable, or its last good copy.
        assert_eq!(read_registry(&dir.join("never-there.json"), true), (None, true));
        std::fs::remove_file(&path).unwrap();
        assert_eq!(read_registry(&path, true), (Some(good), false));
        let _ = std::fs::remove_dir_all(&dir);
        let unreadable = check(&Inputs {
            flag: None,
            registry: None,
            unreadable: true,
            source: &fresh,
            machine: None,
            live: 99,
        });
        assert_eq!(
            (&unreadable.refusal, &unreadable.over),
            (&None, &None),
            "admitted: {unreadable:?}"
        );
        let why = unreadable.uncapped.unwrap_or_default();
        assert!(
            why.contains("cannot be read") && why.contains("first-read-truncated.json"),
            "{why}"
        );
    }

    #[tokio::test]
    async fn other_creates_ending_never_stretch_a_wait_past_its_limit() {
        // Every create's end wakes every waiter: one held for its name still ends
        // at its limit, not one limit after the last wake.
        let admitting = Arc::new(Admitting::default());
        admitting.0.lock().unwrap().push(Arc::new(Making::default()));
        let waker = admitting.clone();
        let wakes = tokio::spawn(async move {
            for _ in 0..40 {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                waker.1.notify_waiters();
            }
        });
        let start = std::time::Instant::now();
        let held = admitting
            .wait_while(std::time::Duration::from_millis(200), |open| !open.is_empty())
            .await;
        let waited = start.elapsed();
        wakes.abort();
        assert!(held, "the holder never ended");
        assert!(waited < std::time::Duration::from_millis(1000), "waited {waited:?}");
    }

    #[test]
    fn a_create_whose_session_runs_counts_once() {
        let (starting, made, gone) =
            (Arc::new(Making::default()), Arc::new(Making::default()), Arc::new(Making::default()));
        made.made.set("child".to_owned()).unwrap();
        gone.made.set("ended".to_owned()).unwrap();
        let live: std::collections::HashSet<&str> = ["parent", "child"].into();
        // parent, child (once, not again for its create), the create still starting,
        // and the create whose session is not live (yet, or any more).
        assert_eq!(counted(&live, &[starting, made, gone]), 4);
        assert_eq!(counted(&live, &[]), 2);
    }

    #[tokio::test]
    async fn the_session_a_create_inserts_is_claimed_by_its_own_admission() {
        let admitting = Admitting::default();
        let made = Arc::new(Making::default());
        admitting.0.lock().unwrap().push(made.clone());
        let admitted = Admitted { admitting: &admitting, made: made.clone(), warning: None };
        claim("outside");
        assert_eq!(made.made.get(), None, "a session inserted outside the create is not its");
        admitted.run(async { claim("mine") }).await;
        assert_eq!(made.made.get().map(String::as_str), Some("mine"));
        drop(admitted);
        assert!(admitting.0.lock().unwrap().is_empty(), "a dropped admission is no longer counted");
    }

    /// The four lane hosts as leo-workspace's registry has them.
    fn registry() -> Value {
        json!({
            "origins": {
                "huge-blue": {"hostnames": ["huge-blue"]},
                "air-blue": {"hostnames": ["air-blue", "air-blue.local", "macbook-air"]},
            },
            "machines": {
                "huge-blue": {"lanes": {"max_lanes": 12}},
                "cmux16": {"lanes": {"max_lanes": 3}},
                "big-red": {"lanes": {"max_lanes": 6}},
                "air-blue": {"aliases": ["macbook-air"], "lanes": {"max_lanes": 3}},
                "cmux-lawrence": {},
            },
        })
    }

    #[test]
    fn this_machine_is_found_by_name_alias_or_origin_hostname() {
        let r = registry();
        assert_eq!(machine_of(&r, None, "huge-blue").as_deref(), Some("huge-blue"));
        assert_eq!(machine_of(&r, None, "cmux16").as_deref(), Some("cmux16"));
        assert_eq!(machine_of(&r, None, "cmux16.local").as_deref(), Some("cmux16"));
        assert_eq!(machine_of(&r, None, "Air-Blue.local").as_deref(), Some("air-blue"));
        assert_eq!(machine_of(&r, None, "MacBook-Air").as_deref(), Some("air-blue"));
        assert_eq!(machine_of(&r, None, "somewhere-else"), None);
        assert_eq!(machine_of(&r, Some("huge-blue"), "air-blue").as_deref(), Some("huge-blue"));
        assert_eq!(machine_of(&r, Some("nowhere"), "huge-blue"), None);
    }

    #[test]
    fn each_host_warns_at_its_own_max_lanes_and_never_refuses() {
        // huge-blue at its 12 refused the stall reconciler's PONG (2026-10-26):
        // a cap only warns.
        let r = registry();
        let source = Path::new("/r/fleet-registry.json");
        let at = |machine: &str, live| {
            check(&Inputs {
                flag: None,
                registry: Some(&r),
                unreadable: false,
                source,
                machine: Some(machine),
                live,
            })
        };
        let over = |machine: &str, live, max| {
            Some(OverCap { live, max, machine: machine.into(), source: source.into() })
        };
        for (machine, max) in [("huge-blue", 12), ("cmux16", 3), ("big-red", 6), ("air-blue", 3)] {
            assert_eq!(
                at(machine, max as usize - 1),
                Verdict::default(),
                "{machine} under its cap"
            );
            for live in [max as usize, 16] {
                let v = at(machine, live);
                assert_eq!(v.refusal, None, "{machine} at {live}: a cap never refuses");
                assert_eq!(v.over, over(machine, live, max), "{machine} at {live}: warned");
            }
        }
        assert_eq!(at("cmux-lawrence", 50).over, None, "no lanes entry: no warning");
        let cap = over("cmux16", 16, 3).unwrap();
        let message = cap.warning(true, Some("placed on big-red: 31 GB RAM free"));
        assert!(
            message.contains("16 live sessions")
                && message.contains("cap of 3")
                && message.contains("lanes.max_lanes of cmux16 in /r/fleet-registry.json")
                && message.contains("started anyway")
                && message.contains("`acpmux new --host auto` (placed on big-red: 31 GB RAM free)"),
            "the warning names the count, the cap, where it comes from and a host with room: {message}"
        );
        assert!(cap.warning(true, None).contains("No connected host has room"));
        let web = cap.warning(false, None);
        assert!(!web.contains("/r/"), "a Web client learns no path: {web}");
        assert!(!web.contains("cmux16"), "nor the machine: {web}");
    }

    #[test]
    fn the_flag_refuses_before_the_cap_and_no_registry_admits() {
        let r = registry();
        let source = Path::new("");
        let none = check(&Inputs {
            flag: None,
            registry: None,
            unreadable: false,
            source,
            machine: None,
            live: 99,
        });
        assert_eq!((none.refusal, none.over), (None, None), "no registry: admitted");
        let stray = check(&Inputs {
            flag: None,
            registry: Some(&r),
            unreadable: false,
            source,
            machine: None,
            live: 99,
        });
        assert_eq!((stray.refusal, stray.over), (None, None), "not a registry machine: admitted");
        let dir = std::env::temp_dir().join(format!("acpmux-admission-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let flag = dir.join("under-floor");
        std::fs::write(&flag, "").unwrap();
        let refusal = check(&Inputs {
            flag: Some(&flag),
            registry: None,
            unreadable: false,
            source,
            machine: None,
            live: 0,
        })
        .refusal;
        assert_eq!(refusal, Some(Refusal::UnderFloor { flag: flag.clone() }));
        let missing = dir.join("absent");
        let verdict = check(&Inputs {
            flag: Some(&missing),
            registry: Some(&r),
            unreadable: false,
            source,
            machine: Some("huge-blue"),
            live: 0,
        });
        assert_eq!(verdict, Verdict::default());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
