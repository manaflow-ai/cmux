//! Admission of a new session: whether this host has room for one more
//! (deputy-2, 2026-10-22). About 25 Codex reviewers started on huge-blue with
//! a raw `acpmux new` over reach went around lane-place's cap of 12, filled
//! the disk and pushed the load to 50-80. Every new session goes through the
//! daemon's create, so the daemon checks there, reading two files each time:
//!
//! - `~/.cache/worktree-reclaim/under-floor`, which worktree-reclaim writes
//!   while the disk is under its free-space floor: no new session at all;
//! - `lanes.max_lanes` of this machine in the fleet registry: no new session
//!   while this host's live sessions (running, ready, waiting; a peer's are
//!   not counted) are at the cap. The registry is `FLEET_REGISTRY` when set,
//!   else the first that exists of `~/.ssh/config.d/fleet-registry.json` (the
//!   copy `reach --install` renders) and leo-workspace's own
//!   `~/Projects/leo-workspace/machines/fleet-registry.json` (a fleet host
//!   with a checkout and no rendered copy, like cmux16).
//!
//! This machine is `FLEET_ORIGIN` when set, else the registry machine whose
//! name, `aliases` or origin `hostnames` match the host name, as `reach`
//! finds it. With no registry, or no `lanes` entry for this machine, a create
//! is admitted (a log line says why): acpmux outside the fleet is unchanged.
//! `_meta.acpmux.forceAdmit` (`acpmux new --force-admit`) admits past both,
//! and the daemon logs who asked and what it overrode; the person's own new
//! chat on this host (its app pane, or the person key) is admitted and logged
//! too. `session/new` (with an adopt that may fork), `session/fork`, the
//! composer's aside (`_acpmux/ask`) and sub-session starts are checked; a
//! send, a resume, a restart, an adopted conversation, a side chat
//! (`btw.rs`) and a handoff target never are. An admitted create counts as
//! live until it ends, so concurrent creates at the cap cannot all pass.

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
    MaxLanes { live: usize, max: u64, machine: String, source: PathBuf },
}

impl Refusal {
    fn why(&self) -> &'static str {
        match self {
            Self::UnderFloor { .. } => "under_floor",
            Self::MaxLanes { .. } => "max_lanes",
        }
    }

    /// `local`: the caller may learn this host's name and paths (not a Web client).
    fn error(&self, local: bool) -> RpcError {
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
            Self::MaxLanes { live, max, machine, source } => format!(
                "{host} has {live} live sessions, at its cap of {max} (lanes.max_lanes of {machine} in {}): stop one or start the session on another host",
                if local { source.display().to_string() } else { "the fleet registry".into() }
            ),
        };
        let mut data = json!({"reason": REASON, "why": self.why(), "retryable": true});
        if let Self::MaxLanes { live, max, machine, .. } = self {
            (data["live"], data["maxLanes"], data["machine"]) =
                (json!(live), json!(max), json!(machine));
        }
        RpcError::new(-32000, format!("{what}; --force-admit creates it anyway")).with_data(data)
    }
}

/// What the checks read, so a test can give its own.
pub(crate) struct Inputs<'a> {
    pub flag: Option<&'a Path>,
    pub registry: Option<&'a Value>,
    /// Where the registry was read, for the refusal.
    pub source: &'a Path,
    pub machine: Option<&'a str>,
    pub live: usize,
}

/// The refusal for `inputs`, and why a cap did not apply (for the log).
pub(crate) fn check(inputs: &Inputs<'_>) -> (Option<Refusal>, Option<String>) {
    if let Some(flag) = inputs.flag.filter(|f| f.exists()) {
        return (Some(Refusal::UnderFloor { flag: flag.to_path_buf() }), None);
    }
    let Some(registry) = inputs.registry else {
        return (None, Some(NO_REGISTRY.into()));
    };
    let Some(machine) = inputs.machine else {
        return (None, Some("this host is no registry machine".into()));
    };
    let Some(max) = registry
        .pointer(&format!(
            "/machines/{}/lanes/max_lanes",
            machine.replace('~', "~0").replace('/', "~1")
        ))
        .and_then(Value::as_u64)
    else {
        return (None, Some(format!("no lanes entry with max_lanes for {machine}")));
    };
    let refusal = (inputs.live as u64 >= max).then(|| Refusal::MaxLanes {
        live: inputs.live,
        max,
        machine: machine.to_owned(),
        source: inputs.source.to_path_buf(),
    });
    (refusal, None)
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
/// the first of the two usual copies that exists.
fn registry_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("FLEET_REGISTRY").filter(|p| !p.is_empty()) {
        return Some(path.into());
    }
    let home = user_home()?;
    [".ssh/config.d/fleet-registry.json", "Projects/leo-workspace/machines/fleet-registry.json"]
        .iter()
        .map(|rel| home.join(rel))
        .find(|p| p.exists())
}

/// Creates admitted and not yet done (`Admitted`), counted with the live
/// sessions: concurrent creates at the cap cannot all pass the count. Each
/// holds the id of the session it made once that is inserted (`claim`), so a
/// create whose session already runs is counted once, as that session.
#[derive(Default)]
pub(crate) struct Admitting(StdMutex<Vec<Arc<OnceLock<String>>>>);

/// One admitted create, counted until it is dropped (its create ended, made or not).
pub(crate) struct Admitted<'a> {
    admitting: &'a Admitting,
    made: Arc<OnceLock<String>>,
}

tokio::task_local! {
    /// The admitted create this task runs (`Admitted::run`).
    static MAKING: Arc<OnceLock<String>>;
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
    let _ = MAKING.try_with(|made| made.set(id.to_owned()));
}

/// The live sessions `live` plus the admitted creates whose session is not one of
/// them: a create is counted once, as its session once that runs.
fn counted(live: &std::collections::HashSet<&str>, open: &[Arc<OnceLock<String>>]) -> usize {
    live.len()
        + open.iter().filter(|m| m.get().is_none_or(|id| !live.contains(id.as_str()))).count()
}

impl Drop for Admitted<'_> {
    fn drop(&mut self) {
        let mut open = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
        open.retain(|m| !Arc::ptr_eq(m, &self.made));
    }
}

impl Hub {
    /// This host's sessions whose harness runs, plus the admitted creates
    /// whose session is not (yet) one of them.
    fn live_sessions(&self, open: &[Arc<OnceLock<String>>]) -> usize {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let live: std::collections::HashSet<&str> = sessions
            .iter()
            .filter(|s| {
                matches!(
                    s.status(),
                    SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting
                )
            })
            .map(|s| s.id.as_str())
            .collect();
        counted(&live, open)
    }

    /// Whether a new session may start here (module docs). Hold the returned
    /// guard until the create ends: until then it counts as a live session.
    pub(crate) async fn admit_new(&self, ask: Ask<'_>) -> Result<Admitted<'_>, RpcError> {
        let flag = user_home().map(|h| h.join(".cache/worktree-reclaim/under-floor"));
        let read = tokio::task::spawn_blocking(move || {
            let source = registry_path().unwrap_or_default();
            let registry = match std::fs::read(&source) {
                Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
                    .map_err(|e| {
                        tracing::warn!(path = %source.display(), "fleet registry unreadable: {e}")
                    })
                    .ok(),
                Err(_) => None,
            };
            let origin = std::env::var("FLEET_ORIGIN").ok();
            let machine = registry
                .as_ref()
                .and_then(|r| machine_of(r, origin.as_deref(), super::start_gate::host_label()));
            (flag, registry, source, machine)
        });
        let (flag, registry, source, machine) =
            read.await.map_err(|e| RpcError::internal(e.to_string()))?;
        // Counted and reserved under one lock: no file I/O while it is held.
        let admitting = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
        let live = self.live_sessions(&admitting);
        let (refusal, uncapped) = check(&Inputs {
            flag: flag.as_deref(),
            registry: registry.as_ref(),
            source: &source,
            machine: machine.as_deref(),
            live,
        });
        let admitted = |mut open: std::sync::MutexGuard<'_, Vec<Arc<OnceLock<String>>>>| {
            let made = Arc::new(OnceLock::new());
            open.push(made.clone());
            Admitted { admitting: &self.admitting, made }
        };
        // Outside the fleet (no registry) that is every create: only a fleet host's gap is logged.
        match uncapped {
            Some(why) if why == NO_REGISTRY => {
                tracing::debug!("session admitted with no lane cap: {why}")
            }
            Some(why) => tracing::info!("session admitted with no lane cap: {why}"),
            None => {}
        }
        let Some(refusal) = refusal else { return Ok(admitted(admitting)) };
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
        drop(admitting);
        tracing::info!(caller = who, why, live, "session/new refused: {refusal:?}");
        Err(refusal.error(ask.local))
    }
}

/// Who asks for a new session, for `Hub::admit_new`.
pub(crate) struct Ask<'a> {
    /// `_meta.acpmux.forceAdmit`: admitted past a refusal, logged.
    pub force: bool,
    /// The person asks here (this host's app pane, or the person key). A peer's
    /// app pane is not: a forwarded `via: app` is the forwarding client's word.
    pub person: bool,
    /// The caller session or the connection, for the log.
    pub who: &'a str,
    /// The refusal may name this host and its paths (not a Web client, here or
    /// through a peer).
    pub local: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_create_whose_session_runs_counts_once() {
        let (starting, made, gone) =
            (Arc::new(OnceLock::new()), Arc::new(OnceLock::new()), Arc::new(OnceLock::new()));
        made.set("child".to_owned()).unwrap();
        gone.set("ended".to_owned()).unwrap();
        let live: std::collections::HashSet<&str> = ["parent", "child"].into();
        // parent, child (once, not again for its create), the create still starting,
        // and the create whose session is not live (yet, or any more).
        assert_eq!(counted(&live, &[starting, made, gone]), 4);
        assert_eq!(counted(&live, &[]), 2);
    }

    #[tokio::test]
    async fn the_session_a_create_inserts_is_claimed_by_its_own_admission() {
        let admitting = Admitting::default();
        let made = Arc::new(OnceLock::new());
        admitting.0.lock().unwrap().push(made.clone());
        let admitted = Admitted { admitting: &admitting, made: made.clone() };
        claim("outside");
        assert_eq!(made.get(), None, "a session inserted outside the create is not its");
        admitted.run(async { claim("mine") }).await;
        assert_eq!(made.get().map(String::as_str), Some("mine"));
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
    fn each_host_is_capped_at_its_own_max_lanes() {
        let r = registry();
        let source = Path::new("/r/fleet-registry.json");
        let at = |machine: &str, live| {
            check(&Inputs { flag: None, registry: Some(&r), source, machine: Some(machine), live })
                .0
        };
        let capped = |machine: &str, live, max| {
            Some(Refusal::MaxLanes { live, max, machine: machine.into(), source: source.into() })
        };
        for (machine, max) in [("huge-blue", 12), ("cmux16", 3), ("big-red", 6), ("air-blue", 3)] {
            assert_eq!(at(machine, max as usize - 1), None, "{machine} under its cap");
            assert_eq!(at(machine, max as usize), capped(machine, max as usize, max));
            // Over the cap already (sessions from before the check): still refused, nothing evicted.
            assert_eq!(at(machine, 16), capped(machine, 16, max));
        }
        assert_eq!(at("cmux-lawrence", 50), None, "no lanes entry: admitted");
        let message = capped("cmux16", 16, 3).unwrap().error(true).message;
        assert!(
            message.contains("16 live sessions")
                && message.contains("cap of 3")
                && message.contains("lanes.max_lanes of cmux16 in /r/fleet-registry.json"),
            "the refusal names the count, the cap and where it comes from: {message}"
        );
        let web = capped("cmux16", 16, 3).unwrap().error(false).message;
        assert!(!web.contains("/r/"), "a Web client learns no path: {web}");
    }

    #[test]
    fn the_flag_refuses_before_the_cap_and_no_registry_admits() {
        let r = registry();
        let source = Path::new("");
        let none = check(&Inputs { flag: None, registry: None, source, machine: None, live: 99 });
        assert_eq!(none.0, None, "no registry: admitted");
        let stray =
            check(&Inputs { flag: None, registry: Some(&r), source, machine: None, live: 99 });
        assert_eq!(stray.0, None, "not a registry machine: admitted");
        let dir = std::env::temp_dir().join(format!("acpmux-admission-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let flag = dir.join("under-floor");
        std::fs::write(&flag, "").unwrap();
        let (refusal, _) =
            check(&Inputs { flag: Some(&flag), registry: None, source, machine: None, live: 0 });
        assert_eq!(refusal, Some(Refusal::UnderFloor { flag: flag.clone() }));
        let missing = dir.join("absent");
        let (refusal, _) = check(&Inputs {
            flag: Some(&missing),
            registry: Some(&r),
            source,
            machine: Some("huge-blue"),
            live: 0,
        });
        assert_eq!(refusal, None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
