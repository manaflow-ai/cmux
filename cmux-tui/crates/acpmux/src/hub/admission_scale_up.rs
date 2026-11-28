//! A create past this host's lane cap with no connected host that has room
//! asks the fleet for one more machine (Leo, 2026-11-23: "well we should be
//! able to autoscale ourselves. that's the whole point of scaling."). The
//! fleet's autoscale is the registry's `lane_overflow.providers`, which
//! leo-workspace's `tools/lane_place.py new` asks in order when every lane host
//! is busy; a start that came straight to the daemon never asked them. Now the
//! admission (`admission.rs`) does, the same way `lane_place.run_overflow`
//! does: each provider is argv relative to the leo-workspace checkout, given
//! `--origin` (this registry machine), `--busy` (it), `--budget` and
//! `--registry`, and answers `{"host": NAME}` on its last stdout line with exit
//! 0, or `{"error": WHY}`; the first host, or a provider declared or answering
//! `terminal: true`, ends the chain.
//!
//! The run is detached for ordinary starts: the create never waits for it (a
//! cap only warns, and a create is never refused or slowed). An Auto start may
//! await the same run while it waits for the new peer to connect. One run at a time per daemon, and none
//! again within [`COOLDOWN`] of the last start, so a burst of over-cap creates
//! asks once. No registry, no `lane_overflow.providers`, or no leo-workspace
//! checkout holding the provider: nothing runs (acpmux outside the fleet is
//! unchanged). The new machine takes the next `--machine auto` start once it
//! is connected; Auto starts wait for that connection below.
//!
//! Warm spare (default off; `ACPMUX_AUTO_WARM_SPARE=1`, or the registry's
//! `lane_overflow.warm_spare: true`, the environment winning): the same run is
//! asked for one create earlier, when a create takes this host's last free slot
//! and no connected host has room, so the next Auto start finds the new machine
//! connected instead of waiting for it, and is placed there. Never more than
//! one spare: once it joins a connected host has room and nothing more is
//! asked, and the single flight and cooldown above hold under a burst. The
//! providers keep their own quota (no slot: no host, so no spare) and idle or
//! pause policy, which the spare follows like any other machine.

use super::*;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// No second run within this of the last start. 2 min, not 10: on the 2026-11-24 start-trace replay
/// (8 seats, 6 min lead, static T=0) 10 min left 1,300 overload lane-minutes over 24 h and 2 min left
/// 502, for +4.4 host-hours (leo-workspace `tools/lane_elastic_replay.py`).
pub(crate) const COOLDOWN: Duration = Duration::from_secs(2 * 60);
/// `lane_overflow.timeout_seconds` without one, and its bounds (`lane_place.py`'s).
const BUDGET_DEFAULT: u64 = 240;
const BUDGET_MAX: u64 = 3600;
/// Seconds a provider gets past the `--budget` it was told before it is killed.
const SLACK: u64 = 10;
/// Auto waits for the default provider budget plus the process-kill slack.
/// A configured provider may run longer, but an Auto start stays bounded.
pub(crate) const AUTO_WAIT_BOUND: Duration = Duration::from_secs(BUDGET_DEFAULT + SLACK);

/// One provider to ask: its name, and the argv to run (resolved).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Provider {
    pub name: String,
    pub argv: Vec<String>,
    pub terminal: bool,
}

/// What a scale-up runs: the providers in order, and the bound they share.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Plan {
    pub providers: Vec<Provider>,
    pub budget: Duration,
}

/// The plan for `registry` read at `source`, this host being `machine`, with
/// the provider argv resolved against the leo-workspace checkout `workspace`.
/// None when the registry declares no provider, or a provider's program is not
/// in the checkout.
pub(crate) fn plan(
    registry: &Value,
    source: &Path,
    machine: &str,
    workspace: Option<&Path>,
) -> Option<Plan> {
    let spec = registry.get("lane_overflow")?;
    let workspace = workspace?;
    let budget = spec
        .get("timeout_seconds")
        .and_then(Value::as_f64)
        .filter(|s| s.is_finite() && *s >= 1.0)
        .map_or(BUDGET_DEFAULT, |s| (s as u64).min(BUDGET_MAX));
    let providers: Vec<Provider> = spec
        .get("providers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|p| {
            let name = p.get("name").and_then(Value::as_str).unwrap_or("provider").to_owned();
            let words: Vec<&str> =
                p.get("argv").and_then(Value::as_array)?.iter().filter_map(Value::as_str).collect();
            let (program, rest) = words.split_first()?;
            let program = workspace.join(program);
            if !program.is_file() {
                tracing::debug!(provider = name, path = %program.display(), "scale-up: no provider program");
                return None;
            }
            let mut argv = vec![program.to_string_lossy().into_owned()];
            argv.extend(rest.iter().map(|w| (*w).to_owned()));
            argv.extend(["--origin".into(), machine.to_owned(), "--busy".into(), machine.to_owned()]);
            argv.extend(["--budget".into(), budget.to_string()]);
            if !source.as_os_str().is_empty() {
                argv.extend(["--registry".into(), source.to_string_lossy().into_owned()]);
            }
            let terminal = p.get("terminal").and_then(Value::as_bool) == Some(true);
            Some(Provider { name, argv, terminal })
        })
        .collect();
    (!providers.is_empty()).then(|| Plan { providers, budget: Duration::from_secs(budget) })
}

/// Whether the fleet registry gives every lane its own machine
/// (`lane_place.one_lane_per_host`). Leo: "each guy gets their individual lil machine for now".
pub(crate) fn one_per_host(registry: Option<&Value>) -> bool {
    registry.and_then(|r| r.pointer("/lane_place/one_lane_per_host")).and_then(Value::as_bool)
        == Some(true)
}

/// With [`one_per_host`], a peer pick that already runs a lane (or whose count is unknown)
/// is no room: the verdict reads `overloaded`, so [`room_elsewhere`] finds none and an
/// Auto start waits for a fresh machine instead of doubling up.
pub(crate) fn solo_pick(verdict: &mut Value, registry: Option<&Value>) {
    if !one_per_host(registry) {
        return;
    }
    let Some(pick) = verdict.get("pick").and_then(Value::as_str).map(str::to_owned) else {
        return;
    };
    let empty = verdict
        .get("hosts")
        .and_then(Value::as_array)
        .and_then(|h| h.iter().find(|r| r.get("name").and_then(Value::as_str) == Some(&pick)))
        .and_then(|r| r.get("live"))
        .and_then(Value::as_u64)
        == Some(0);
    if !empty && let Some(v) = verdict.as_object_mut() {
        v.insert("overloaded".into(), Value::Bool(true));
    }
}

/// Where the placement engine's `verdict` over the connected peers would put
/// the create (`placement::placed`), when a peer has room: a pick that has no
/// room either (`overloaded`) is no place, and only with none does the fleet
/// scale up.
pub(crate) fn room_elsewhere(verdict: &Value) -> Option<String> {
    Some(verdict)
        .filter(|v| v.get("overloaded").and_then(Value::as_bool) != Some(true))
        .and_then(crate::placement::placed)
}

/// The warm-spare switch (module docs): the environment's
/// [`WARM_SPARE_ENV`] when it says on or off (`cold_wake::env_flag`), else the
/// registry's `lane_overflow.warm_spare`; off by default.
pub(crate) const WARM_SPARE_ENV: &str = "ACPMUX_AUTO_WARM_SPARE";

pub(crate) fn warm_spare_on(
    registry: Option<&Value>,
    env: impl Fn(&str) -> Option<String>,
) -> bool {
    super::cold_wake::env_flag(env(WARM_SPARE_ENV).as_deref()).unwrap_or_else(|| {
        registry.and_then(|r| r.pointer("/lane_overflow/warm_spare")).and_then(Value::as_bool)
            == Some(true)
    })
}

/// Whether a create asks for a warm spare: the switch is on, it takes this
/// host's last free slot, and no connected host has room.
pub(crate) fn wants_warm_spare(on: bool, last_slot: bool, peer_room: bool) -> bool {
    on && last_slot && !peer_room
}

/// Whether an Auto start past the cap takes a connected host's room (the
/// spare) at once rather than starting here.
pub(crate) fn uses_spare(on: bool, auto: bool, peer_room: bool) -> bool {
    on && auto && peer_room
}

/// The leo-workspace checkout the provider argv is relative to: the one the
/// registry was read from (`.../machines/fleet-registry.json`), else
/// `~/Projects/leo-workspace`.
pub(crate) fn workspace_of(source: &Path) -> Option<PathBuf> {
    let from_registry = source
        .parent()
        .filter(|d| d.file_name().is_some_and(|n| n == "machines"))
        .and_then(Path::parent)
        .filter(|w| w.join("tools").is_dir())
        .map(Path::to_path_buf);
    from_registry.or_else(|| {
        std::env::var_os("HOME")
            .filter(|h| !h.is_empty())
            .map(|h| PathBuf::from(h).join("Projects/leo-workspace"))
            .filter(|w| w.join("tools").is_dir())
    })
}

/// What one provider answered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Answer {
    Host(String),
    Failed { why: String, terminal: bool },
}

/// Runs one provider within a bound; a test gives its own.
pub(crate) type Runner = Arc<
    dyn Fn(
            Provider,
            Duration,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Answer> + Send>>
        + Send
        + Sync,
>;

/// What a trigger did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Trigger {
    /// A run started now.
    Started,
    /// A run is already under way.
    InFlight,
    /// The last run started within [`COOLDOWN`] and has ended.
    Cooling,
}

impl Trigger {
    /// A machine is being added (the warning and `scalingUp` say so).
    pub(crate) fn scaling(self) -> bool {
        matches!(self, Trigger::Started | Trigger::InFlight)
    }
}

/// What the last run did (`fleet_elastic::ScaleUpStatus` on the wire), in Unix ms.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Outcome {
    pub started_ms: Option<u64>,
    pub ended_ms: Option<u64>,
    /// The machine the fleet added; None when none was.
    pub host: Option<String>,
    /// Why none was: the last provider's answer.
    pub error: Option<String>,
    /// The provider that answered, or the last one asked.
    pub provider: Option<String>,
}

#[derive(Default)]
struct State {
    running: bool,
    last: Option<Instant>,
    result: Option<Arc<tokio::sync::watch::Sender<Option<Option<String>>>>>,
    outcome: Outcome,
}

/// What [`run_plan`] came to.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Ran {
    pub host: Option<String>,
    pub error: Option<String>,
    pub provider: Option<String>,
}

/// A scale-up result shared by Auto starts that arrive during one provider run.
pub(crate) type ResultReceiver = tokio::sync::watch::Receiver<Option<Option<String>>>;

/// This daemon's scale-up: at most one run, none within the cooldown.
pub(crate) struct ScaleUp {
    state: Arc<StdMutex<State>>,
    runner: Runner,
    cooldown: Duration,
}

impl ScaleUp {
    #[cfg(test)]
    pub(crate) fn new(runner: Runner, cooldown: Duration) -> Self {
        Self { state: Arc::default(), runner, cooldown }
    }

    /// The daemon's own, running real providers.
    /// Only the run state is the daemon's one copy (so every create shares the one run and
    /// its cooldown); the runner is made here, never held in a static a test could replace.
    pub(crate) fn daemon() -> ScaleUp {
        static STATE: OnceLock<Arc<StdMutex<State>>> = OnceLock::new();
        ScaleUp {
            state: STATE.get_or_init(Arc::default).clone(),
            runner: Arc::new(|p, bound| Box::pin(run_provider(p, bound))),
            cooldown: COOLDOWN,
        }
    }

    /// Starts `plan` on `owner` (the Hub's scope: its close ends the run)
    /// unless a run is under way or within the cooldown. Never waits for the
    /// run. Call inside a Tokio runtime. Admission calls [`Self::trigger_wait`];
    /// the tests drive the detached form.
    #[cfg(test)]
    pub(crate) fn trigger(&self, owner: &cmux_scope::Scope, plan: Plan, now: Instant) -> Trigger {
        self.trigger_wait(owner, plan, now).0
    }

    /// Starts a provider run and returns a receiver for its eventual answer.
    /// The receiver is present for a newly started or already-running run and
    /// absent during cooldown. A caller that drops the receiver keeps the run
    /// detached.
    pub(crate) fn trigger_wait(
        &self,
        owner: &cmux_scope::Scope,
        plan: Plan,
        now: Instant,
    ) -> (Trigger, Option<ResultReceiver>) {
        {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if state.running {
                let receiver = state.result.as_ref().map(|result| result.subscribe());
                return (Trigger::InFlight, receiver);
            }
            if state.last.is_some_and(|last| now.saturating_duration_since(last) < self.cooldown) {
                return (Trigger::Cooling, None);
            }
            state.running = true;
            state.last = Some(now);
            state.outcome =
                Outcome { started_ms: Some(crate::store::now_ms()), ..Outcome::default() };
            let (result, receiver) = tokio::sync::watch::channel(None);
            let result = Arc::new(result);
            state.result = Some(result.clone());
            let (state, runner) = (self.state.clone(), self.runner.clone());
            owner.spawn_named("admission scale-up", async move {
                let ran = run_plan(&runner, plan).await;
                match &ran.host {
                    Some(host) => {
                        tracing::info!(host, "scale-up: the fleet added a machine for lanes")
                    }
                    None => tracing::warn!("scale-up: no provider added a machine"),
                }
                let _ = result.send(Some(ran.host.clone()));
                let mut state = state.lock().unwrap_or_else(|e| e.into_inner());
                state.running = false;
                state.result = None;
                state.outcome = Outcome {
                    ended_ms: Some(crate::store::now_ms()),
                    host: ran.host,
                    error: ran.error,
                    provider: ran.provider,
                    ..state.outcome.clone()
                };
            });
            (Trigger::Started, Some(receiver))
        }
    }

    /// The daemon status's `scaleUp` (`fleet_elastic.rs`, version 1): `adding` while a run is
    /// under way, `cooling` within the cooldown of the last start, else `idle`, with the last
    /// run's outcome (null until one ended). Never waits for a run.
    pub(crate) fn status(&self, now: Instant) -> Value {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let word = if state.running {
            "adding"
        } else if state.last.is_some_and(|l| now.saturating_duration_since(l) < self.cooldown) {
            "cooling"
        } else {
            "idle"
        };
        let o = &state.outcome;
        json!({
            "v": crate::fleet_elastic::VERSION,
            "state": word,
            "lastStartedMs": o.started_ms,
            "lastEndedMs": o.ended_ms,
            "lastHost": o.host,
            "lastError": o.error,
            "lastProvider": o.provider,
        })
    }
}

/// Asks each provider in turn within the plan's shared bound: the first host, or why none
/// (`lane_place.run_overflow`'s order and stop rules).
async fn run_plan(runner: &Runner, plan: Plan) -> Ran {
    let mut ran = Ran::default();
    let deadline = Instant::now() + plan.budget + Duration::from_secs(SLACK);
    for provider in plan.providers {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            tracing::warn!(provider = provider.name, "scale-up: not asked: the budget is spent");
            ran.error = Some("the budget is spent".into());
            break;
        }
        let (name, declared) = (provider.name.clone(), provider.terminal);
        ran.provider = Some(name.clone());
        match runner(provider, left).await {
            Answer::Host(host) => {
                tracing::info!(provider = name, host, "scale-up: provider answered");
                ran.host = Some(host);
                ran.error = None;
                return ran;
            }
            Answer::Failed { why, terminal } => {
                tracing::warn!(provider = name, "scale-up: provider failed: {why}");
                ran.error = Some(why);
                if terminal || declared {
                    break;
                }
            }
        }
    }
    ran
}

/// The answer in a provider's last stdout line, given its exit.
pub(crate) fn parse_answer(ok: bool, stdout: &str) -> Answer {
    let last = stdout.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("{}");
    let Ok(out) = serde_json::from_str::<Value>(last.trim()) else {
        return Answer::Failed { why: "answered no JSON".into(), terminal: false };
    };
    let terminal = out.get("terminal").and_then(Value::as_bool) == Some(true);
    match out.get("host").and_then(Value::as_str).filter(|h| !h.is_empty()) {
        Some(host) if ok => Answer::Host(host.to_owned()),
        _ => {
            let why = out.get("error").and_then(Value::as_str).unwrap_or("no host").to_owned();
            Answer::Failed { why, terminal }
        }
    }
}

/// Runs a real provider off the runtime's threads (`run_provider_blocking`).
async fn run_provider(provider: Provider, bound: Duration) -> Answer {
    tokio::task::spawn_blocking(move || run_provider_blocking(&provider, bound))
        .await
        .unwrap_or_else(|e| Answer::Failed { why: e.to_string(), terminal: false })
}

/// Runs a real provider as the leader of its own process group (no signal to
/// the daemon's group reaches it), owned by its `cmux_process::Child`: past
/// `bound` the child is dropped, which ends its group. A provider answers in
/// one short stdout line (its log goes to stderr, dropped here), so the pipe
/// never fills before it exits.
pub(crate) fn run_provider_blocking(provider: &Provider, bound: Duration) -> Answer {
    use std::io::Read as _;
    let failed = |why: String| Answer::Failed { why, terminal: false };
    let Some((program, args)) = provider.argv.split_first() else {
        return failed("no argv".into());
    };
    let mut child = match cmux_process::Command::new(program)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .process_group(0)
        .spawn()
    {
        Ok(child) => child,
        Err(e) => return failed(e.to_string()),
    };
    let status = match child.wait_timeout(bound) {
        Ok(Some(status)) => status,
        Ok(None) => return failed("timed out".into()),
        Err(e) => return failed(e.to_string()),
    };
    let mut stdout = String::new();
    if let Some(mut pipe) = child.stdout.take()
        && let Err(e) = pipe.read_to_string(&mut stdout)
    {
        return failed(e.to_string());
    }
    parse_answer(status.success(), &stdout)
}

#[cfg(test)]
#[path = "admission_scale_up_tests.rs"]
mod tests;
