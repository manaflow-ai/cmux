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
//! The run is detached: the create never waits for it (a cap only warns, and a
//! create is never refused or slowed). One run at a time per daemon, and none
//! again within [`COOLDOWN`] of the last start, so a burst of over-cap creates
//! asks once. No registry, no `lane_overflow.providers`, or no leo-workspace
//! checkout holding the provider: nothing runs (acpmux outside the fleet is
//! unchanged). The new machine takes the next `--machine auto` start once it
//! is connected; making that start wait for it is a follow-up.

use super::*;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// No second run within this of the last start.
pub(crate) const COOLDOWN: Duration = Duration::from_secs(10 * 60);
/// `lane_overflow.timeout_seconds` without one, and its bounds (`lane_place.py`'s).
const BUDGET_DEFAULT: u64 = 240;
const BUDGET_MAX: u64 = 3600;
/// Seconds a provider gets past the `--budget` it was told before it is killed.
const SLACK: u64 = 10;

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

/// Where the placement engine's `verdict` over the connected peers would put
/// the create (`placement::placed`), when a peer has room: a pick that has no
/// room either (`overloaded`) is no place, and only with none does the fleet
/// scale up.
pub(crate) fn room_elsewhere(verdict: &Value) -> Option<String> {
    Some(verdict)
        .filter(|v| v.get("overloaded").and_then(Value::as_bool) != Some(true))
        .and_then(crate::placement::placed)
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

#[derive(Default)]
struct State {
    running: bool,
    last: Option<Instant>,
}

/// This daemon's scale-up: at most one run, none within the cooldown.
pub(crate) struct ScaleUp {
    state: Arc<StdMutex<State>>,
    runner: Runner,
    cooldown: Duration,
}

impl ScaleUp {
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
    /// run. Call inside a Tokio runtime.
    pub(crate) fn trigger(&self, owner: &cmux_scope::Scope, plan: Plan, now: Instant) -> Trigger {
        {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if state.running {
                return Trigger::InFlight;
            }
            if state.last.is_some_and(|last| now.saturating_duration_since(last) < self.cooldown) {
                return Trigger::Cooling;
            }
            state.running = true;
            state.last = Some(now);
        }
        let (state, runner) = (self.state.clone(), self.runner.clone());
        owner.spawn_named("admission scale-up", async move {
            let host = run_plan(&runner, plan).await;
            match host {
                Some(host) => tracing::info!(host, "scale-up: the fleet added a machine for lanes"),
                None => tracing::warn!("scale-up: no provider added a machine"),
            }
            state.lock().unwrap_or_else(|e| e.into_inner()).running = false;
        });
        Trigger::Started
    }
}

/// Asks each provider in turn within the plan's shared bound: the first host,
/// or None (`lane_place.run_overflow`'s order and stop rules).
async fn run_plan(runner: &Runner, plan: Plan) -> Option<String> {
    let deadline = Instant::now() + plan.budget + Duration::from_secs(SLACK);
    for provider in plan.providers {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            tracing::warn!(provider = provider.name, "scale-up: not asked: the budget is spent");
            break;
        }
        let (name, declared) = (provider.name.clone(), provider.terminal);
        match runner(provider, left).await {
            Answer::Host(host) => {
                tracing::info!(provider = name, host, "scale-up: provider answered");
                return Some(host);
            }
            Answer::Failed { why, terminal } => {
                tracing::warn!(provider = name, "scale-up: provider failed: {why}");
                if terminal || declared {
                    break;
                }
            }
        }
    }
    None
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
fn run_provider_blocking(provider: &Provider, bound: Duration) -> Answer {
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
