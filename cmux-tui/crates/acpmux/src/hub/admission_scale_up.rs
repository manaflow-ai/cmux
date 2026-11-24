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
//! is connected. A create that asked to spill (`admission_spill.rs`) waits for
//! the run's host instead ([`ScaleUp::host_for_spill`]): every waiter of one run
//! shares its answer, and a host a run added within the cooldown takes the
//! next spills until its lane cap.

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

/// A run's end: which run (`State::run`) and the host it added, if any.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Done {
    run: u64,
    host: Option<String>,
}

#[derive(Default)]
struct State {
    running: bool,
    last: Option<Instant>,
    /// Runs started so far; the one under way, or the last, is this number.
    run: u64,
    /// The last run's end.
    done: Done,
    /// Spills each host a run added took (`claim`).
    spilled: std::collections::HashMap<String, u64>,
}

/// One daemon's run state, and the channel each run's end is told on.
struct Shared {
    state: StdMutex<State>,
    done: tokio::sync::watch::Sender<Done>,
}

impl Default for Shared {
    fn default() -> Self {
        Self { state: StdMutex::default(), done: tokio::sync::watch::Sender::new(Done::default()) }
    }
}

/// This daemon's scale-up: at most one run, none within the cooldown.
pub(crate) struct ScaleUp {
    shared: Arc<Shared>,
    runner: Runner,
    cooldown: Duration,
}

/// Where a spill goes (`ScaleUp::host_for_spill`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SpillHost {
    /// A run answered this host (`fresh`: the run this spill started or joined, else a host an
    /// earlier run added within the cooldown, which still has room for spills).
    Host { name: String, fresh: bool },
    /// No host: why.
    None(String),
}

impl ScaleUp {
    pub(crate) fn new(runner: Runner, cooldown: Duration) -> Self {
        Self { shared: Arc::default(), runner, cooldown }
    }

    /// The daemon's own, running real providers.
    /// Only the run state is the daemon's one copy (so every create shares the one run and
    /// its cooldown); the runner is made here, never held in a static a test could replace.
    pub(crate) fn daemon() -> ScaleUp {
        static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();
        ScaleUp {
            shared: SHARED.get_or_init(Arc::default).clone(),
            runner: Arc::new(|p, bound| Box::pin(run_provider(p, bound))),
            cooldown: COOLDOWN,
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.shared.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Starts `plan` on `owner` (the Hub's scope: its close ends the run)
    /// unless a run is under way or within the cooldown. Never waits for the
    /// run. Call inside a Tokio runtime.
    pub(crate) fn trigger(&self, owner: &cmux_scope::Scope, plan: Plan, now: Instant) -> Trigger {
        {
            let mut state = self.state();
            if state.running {
                return Trigger::InFlight;
            }
            if state.last.is_some_and(|last| now.saturating_duration_since(last) < self.cooldown) {
                return Trigger::Cooling;
            }
            self.start(&mut state, owner, plan, now);
        }
        Trigger::Started
    }

    /// Marks a run started in `state` (held) and spawns it on `owner`.
    fn start(&self, state: &mut State, owner: &cmux_scope::Scope, plan: Plan, now: Instant) {
        state.running = true;
        state.last = Some(now);
        state.run = state.run.saturating_add(1);
        let run = state.run;
        let (shared, runner) = (self.shared.clone(), self.runner.clone());
        owner.spawn_named("admission scale-up", async move {
            let host = run_plan(&runner, plan).await;
            match &host {
                Some(host) => tracing::info!(host, "scale-up: the fleet added a machine for lanes"),
                None => tracing::warn!("scale-up: no provider added a machine"),
            }
            let done = Done { run, host };
            {
                let mut state = shared.state.lock().unwrap_or_else(|e| e.into_inner());
                state.running = false;
                state.done = done.clone();
            }
            shared.done.send_replace(done);
        });
    }

    /// The host a spill (`admission_spill.rs`) goes to, waiting up to `wait` for it: the
    /// host of the run under way, or of one started now; within the cooldown, the host the
    /// last run added while fewer than `cap` spills went there, else a new run (the cooldown
    /// keeps a burst to one run, and a full host it added is no burst). A run that added
    /// nothing within the cooldown is not asked again: the spill starts here, as before.
    pub(crate) async fn host_for_spill(
        &self,
        owner: &cmux_scope::Scope,
        plan: Plan,
        cap: u64,
        wait: Duration,
    ) -> SpillHost {
        let until = tokio::time::Instant::now() + wait;
        loop {
            let mut rx = self.shared.done.subscribe();
            let run = {
                let mut state = self.state();
                let now = Instant::now();
                let cooling = state
                    .last
                    .is_some_and(|last| now.saturating_duration_since(last) < self.cooldown);
                if state.running {
                    state.run
                } else if cooling && let Some(host) = state.done.host.clone() {
                    // A host a run added takes spills up to its cap, then a new run is asked.
                    if claim(&mut state, &host, cap) {
                        return SpillHost::Host { name: host, fresh: false };
                    }
                    self.start(&mut state, owner, plan.clone(), now);
                    state.run
                } else if cooling {
                    return SpillHost::None(
                        "the fleet's last scale-up added no machine (it is asked again after its cooldown)"
                            .into(),
                    );
                } else {
                    self.start(&mut state, owner, plan.clone(), now);
                    state.run
                }
            };
            let ended = tokio::time::timeout_at(until, rx.wait_for(|d| d.run >= run)).await;
            let host = match ended {
                Ok(Ok(done)) => done.host.clone(),
                Ok(Err(_)) => return SpillHost::None("the scale-up ended with the daemon".into()),
                Err(_) => {
                    return SpillHost::None(format!(
                        "no machine was added within {}s (the scale-up goes on; the next start may take it)",
                        wait.as_secs()
                    ));
                }
            };
            let Some(name) = host else {
                return SpillHost::None("no provider added a machine".into());
            };
            // Every waiter of a burst shares one run: the first `cap` take its host, and the
            // rest ask for the next one (one run at a time) while the wait lasts.
            if claim(&mut self.state(), &name, cap) {
                return SpillHost::Host { name, fresh: true };
            }
        }
    }
}

/// Counts one more spill on `host` when it has taken fewer than `cap`: whether it did.
fn claim(state: &mut State, host: &str, cap: u64) -> bool {
    let n = state.spilled.entry(host.to_owned()).or_default();
    let room = *n < cap;
    if room {
        *n += 1;
    }
    room
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
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn provider(name: &str) -> Provider {
        Provider { name: name.into(), argv: vec![name.into()], terminal: false }
    }

    fn one_plan() -> Plan {
        Plan { providers: vec![provider("a")], budget: Duration::from_secs(5) }
    }

    /// A runner that counts its calls and answers each once `release` is notified.
    fn held_runner(calls: Arc<AtomicUsize>, release: Arc<tokio::sync::Notify>) -> Runner {
        Arc::new(move |_p, _bound| {
            let (calls, release) = (calls.clone(), release.clone());
            Box::pin(async move {
                calls.fetch_add(1, Ordering::SeqCst);
                release.notified().await;
                Answer::Host("new-machine".into())
            })
        })
    }

    async fn settle(scale: &ScaleUp) {
        for _ in 0..200 {
            if !scale.state().running {
                return;
            }
            tokio::task::yield_now().await;
        }
        panic!("the run never ended");
    }

    #[tokio::test]
    async fn admission_scale_up_runs_once_for_concurrent_over_cap_creates() {
        let (calls, release) =
            (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
        let scale = Arc::new(ScaleUp::new(held_runner(calls.clone(), release.clone()), COOLDOWN));
        let owner = Arc::new(cmux_scope::Scope::new("test"));
        let now = Instant::now();
        let creates: Vec<_> = (0..16)
            .map(|_| {
                let (scale, owner) = (scale.clone(), owner.clone());
                tokio::spawn(async move { scale.trigger(&owner, one_plan(), now) })
            })
            .collect();
        let mut seen = Vec::new();
        for c in creates {
            seen.push(c.await.unwrap());
        }
        assert_eq!(seen.iter().filter(|t| **t == Trigger::Started).count(), 1, "{seen:?}");
        assert!(
            seen.iter().all(|t| t.scaling()),
            "every one of them says a machine is coming: {seen:?}"
        );
        release.notify_one();
        settle(&scale).await;
        assert_eq!(calls.load(Ordering::SeqCst), 1, "one provider run for 16 creates");
        assert!(owner.close(Duration::from_secs(1)).await.joined());
    }

    #[tokio::test]
    async fn admission_scale_up_waits_out_its_cooldown() {
        let (calls, release) =
            (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
        let scale = ScaleUp::new(held_runner(calls.clone(), release.clone()), COOLDOWN);
        let owner = cmux_scope::Scope::new("test");
        let start = Instant::now();
        assert_eq!(scale.trigger(&owner, one_plan(), start), Trigger::Started);
        release.notify_one();
        settle(&scale).await;
        let soon = start + COOLDOWN - Duration::from_secs(1);
        assert_eq!(scale.trigger(&owner, one_plan(), soon), Trigger::Cooling);
        assert!(!Trigger::Cooling.scaling());
        assert_eq!(scale.trigger(&owner, one_plan(), start + COOLDOWN), Trigger::Started);
        release.notify_one();
        settle(&scale).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(owner.close(Duration::from_secs(1)).await.joined());
    }

    #[tokio::test]
    async fn admission_scale_up_stops_at_the_first_host_or_a_terminal_failure() {
        let asked = Arc::new(StdMutex::new(Vec::<String>::new()));
        let answers = |script: Vec<(&'static str, Answer)>| -> Runner {
            let asked = asked.clone();
            Arc::new(move |p: Provider, _| {
                asked.lock().unwrap().push(p.name.clone());
                let a = script.iter().find(|(n, _)| *n == p.name).map(|(_, a)| a.clone());
                Box::pin(
                    async move { a.unwrap_or(Answer::Failed { why: "?".into(), terminal: false }) },
                )
            })
        };
        let plan = Plan {
            providers: vec![provider("a"), provider("b"), provider("c")],
            budget: Duration::from_secs(5),
        };
        let failed = Answer::Failed { why: "full".into(), terminal: false };
        let runner = answers(vec![("a", failed.clone()), ("b", Answer::Host("h".into()))]);
        assert_eq!(run_plan(&runner, plan.clone()).await.as_deref(), Some("h"));
        assert_eq!(*asked.lock().unwrap(), ["a", "b"]);
        asked.lock().unwrap().clear();
        let runner = answers(vec![("a", Answer::Failed { why: "making".into(), terminal: true })]);
        assert_eq!(run_plan(&runner, plan).await, None);
        assert_eq!(*asked.lock().unwrap(), ["a"], "a terminal answer ends the chain");
    }

    #[test]
    fn admission_scale_up_needs_providers_and_a_checkout() {
        let dir = std::env::temp_dir().join(format!("acpmux-scale-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(dir.join("tools")).unwrap();
        std::fs::create_dir_all(dir.join("machines")).unwrap();
        std::fs::write(dir.join("tools/lane_overflow.py"), "").unwrap();
        let source = dir.join("machines/fleet-registry.json");
        assert_eq!(workspace_of(&source).as_deref(), Some(dir.as_path()));
        let none = json!({"machines": {"m": {"lanes": {"max_lanes": 8}}}});
        assert_eq!(plan(&none, &source, "m", Some(&dir)), None, "no lane_overflow: nothing runs");
        let empty = json!({"lane_overflow": {"providers": []}});
        assert_eq!(plan(&empty, &source, "m", Some(&dir)), None, "no providers: nothing runs");
        let registry = json!({"lane_overflow": {"timeout_seconds": 900, "providers": [
            {"name": "lanes", "argv": ["tools/lane_overflow.py", "freestyle-lanes"]},
            {"name": "gone", "argv": ["tools/missing.py"]},
            {"name": "bad"},
        ]}});
        assert_eq!(plan(&registry, &source, "m", None), None, "no checkout: nothing runs");
        let got = plan(&registry, &source, "m", Some(&dir)).unwrap();
        assert_eq!(got.budget, Duration::from_secs(900));
        assert_eq!(got.providers.len(), 1, "{got:?}");
        let argv = &got.providers.first().unwrap().argv;
        let program = dir.join("tools/lane_overflow.py").to_string_lossy().into_owned();
        let source_arg = source.to_string_lossy().into_owned();
        let want: Vec<&str> = vec![
            &program,
            "freestyle-lanes",
            "--origin",
            "m",
            "--busy",
            "m",
            "--budget",
            "900",
            "--registry",
            &source_arg,
        ];
        assert_eq!(argv.iter().map(String::as_str).collect::<Vec<_>>(), want);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn admission_scale_up_is_skipped_while_a_peer_has_room() {
        let roomy = json!({"pick": "big-red", "why": "big-red: 31 GB RAM free"});
        assert_eq!(room_elsewhere(&roomy).as_deref(), Some("placed on big-red: 31 GB RAM free"));
        let full = json!({"pick": "big-red", "why": "least loaded", "overloaded": true});
        assert_eq!(room_elsewhere(&full), None, "a pick with no room is nowhere: scale up");
        assert_eq!(room_elsewhere(&json!({"error": "no candidates"})), None, "no peer: scale up");
    }

    #[test]
    fn admission_scale_up_reads_a_providers_answer() {
        assert_eq!(
            parse_answer(true, "log\n{\"host\": \"lane-9\"}\n"),
            Answer::Host("lane-9".into())
        );
        assert_eq!(
            parse_answer(false, "{\"error\": \"no slot\", \"terminal\": true}"),
            Answer::Failed { why: "no slot".into(), terminal: true }
        );
        assert!(matches!(parse_answer(true, "not json"), Answer::Failed { terminal: false, .. }));
        assert!(matches!(parse_answer(false, "{\"host\": \"x\"}"), Answer::Failed { .. }));
    }

    /// A provider's answer of any shape version parses: none (today's lane_overflow.py),
    /// `"v": 1`, and a later one with keys this daemon does not know.
    #[test]
    fn scale_up_answers_of_every_version_parse() {
        for line in [
            r#"{"host": "e1"}"#,
            r#"{"v": 1, "host": "e1", "skipped": ["fs-lane-3 (full)"]}"#,
            r#"{"v": 2, "host": "e1", "fresh": true, "joinBy": 123}"#,
        ] {
            assert!(matches!(parse_answer(true, line), Answer::Host(h) if h == "e1"), "{line}");
        }
        let failed =
            parse_answer(false, r#"{"v": 2, "error": "no quota", "terminal": true, "x": 1}"#);
        assert!(matches!(failed, Answer::Failed { terminal: true, .. }));
    }

    /// Sixteen creates no host has room for share one run, the first `cap` of them take its
    /// host, and the rest ask for the next one: never sixteen machines, never sixteen on one.
    #[tokio::test]
    async fn spill_waiters_share_one_run_and_fill_its_host_to_the_cap() {
        let calls = Arc::new(AtomicUsize::new(0));
        let n = calls.clone();
        let runner: Runner = Arc::new(move |_p, _b| {
            let n = n.clone();
            Box::pin(async move {
                let k = n.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(20)).await;
                Answer::Host(format!("e{k}"))
            })
        });
        let scale = Arc::new(ScaleUp::new(runner, COOLDOWN));
        let owner = Arc::new(cmux_scope::Scope::new("test"));
        let waits: Vec<_> = (0..16)
            .map(|_| {
                let (scale, owner) = (scale.clone(), owner.clone());
                tokio::spawn(async move {
                    scale.host_for_spill(&owner, one_plan(), 6, Duration::from_secs(5)).await
                })
            })
            .collect();
        let mut hosts = std::collections::BTreeMap::<String, usize>::new();
        for w in waits {
            match w.await.unwrap() {
                SpillHost::Host { name, .. } => *hosts.entry(name).or_default() += 1,
                SpillHost::None(why) => panic!("no host: {why}"),
            }
        }
        assert!(hosts.values().all(|n| *n <= 6), "{hosts:?}");
        assert_eq!(calls.load(Ordering::SeqCst), 3, "16 at 6 a host: three runs, {hosts:?}");
        // Within the cooldown a host with room takes the next spill with no run.
        assert!(matches!(
            scale.host_for_spill(&owner, one_plan(), 6, Duration::from_secs(5)).await,
            SpillHost::Host { fresh: false, .. }
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 3);
        assert!(owner.close(Duration::from_secs(1)).await.joined());
    }

    /// A run that adds nothing, or outlasts the wait, answers no host (the create starts where
    /// it is, warned), and a failed run is not asked again within its cooldown.
    #[tokio::test]
    async fn spill_without_a_host_in_time_answers_none() {
        let (calls, release) =
            (Arc::new(AtomicUsize::new(0)), Arc::new(tokio::sync::Notify::new()));
        let scale = ScaleUp::new(held_runner(calls.clone(), release.clone()), COOLDOWN);
        let owner = cmux_scope::Scope::new("test");
        let got = scale.host_for_spill(&owner, one_plan(), 6, Duration::from_millis(50)).await;
        assert!(matches!(got, SpillHost::None(ref why) if why.contains("no machine was added")));
        release.notify_one();
        settle(&scale).await;
        let failing: Runner = Arc::new(|_p, _b| {
            Box::pin(async { Answer::Failed { why: "no quota".into(), terminal: false } })
        });
        let scale = ScaleUp::new(failing, COOLDOWN);
        let got = scale.host_for_spill(&owner, one_plan(), 6, Duration::from_secs(5)).await;
        assert!(matches!(got, SpillHost::None(ref why) if why.contains("no provider")), "{got:?}");
        let again = scale.host_for_spill(&owner, one_plan(), 6, Duration::from_secs(5)).await;
        assert!(matches!(again, SpillHost::None(ref why) if why.contains("cooldown")), "{again:?}");
        assert!(owner.close(Duration::from_secs(1)).await.joined());
    }
}
