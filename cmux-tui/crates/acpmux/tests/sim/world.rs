//! One seed's run: the turmoil simulation with the daemon host and the app client, the fault
//! schedule applied step by step, and what is left afterwards for the invariants.
//!
//! The daemon host is the real `Hub` and protocol handler (`serve_connection`) over a
//! `SimStore`, its agents in process (`agent.rs`). A crash drops the daemon's runtime, which
//! ends every task it ran (its agents' too) wherever each one was waiting; a restart builds a new
//! hub over the same disk and runs the daemon's restore (`Hub::sim_startup`). The network is
//! turmoil's: latency on every message, and partitions and holds the plan asks for.

use crate::agent::{Agents, Given};
use crate::app::{self, App, Shared};
use crate::plan::{Fault, Kinds, Plan};
use crate::rng::Rng;
use crate::store::{Disk, SimStore};
use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::store::EventRecord;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

const APP: &str = "app";
const TICK: Duration = Duration::from_millis(10);

/// Which faults a run injects.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Faults(pub Kinds);

impl Faults {
    pub fn none() -> Self {
        Self(Kinds { crash: false, power_loss: false, network: false })
    }
    /// Daemon crashes and the network's: what every PR runs.
    pub fn standard() -> Self {
        Self(Kinds { crash: true, power_loss: false, network: true })
    }
    /// A comma list of `crash`, `power`, `network`; `none`; `all` (every kind).
    pub fn parse(spec: &str) -> Self {
        let mut k = Self::none().0;
        for part in spec.split(',').map(str::trim) {
            match part {
                "crash" => k.crash = true,
                "power" => k.power_loss = true,
                "network" => k.network = true,
                "all" => k = Kinds { crash: true, power_loss: true, network: true },
                _ => {}
            }
        }
        Self(k)
    }
}

pub struct Options {
    pub faults: Faults,
    /// Retries carry `_meta.acpmux.resend`.
    pub resend: bool,
}

/// What one simulation left.
pub struct Outcome {
    pub app: App,
    /// Every chat's records as the disk holds them at the end.
    pub log: BTreeMap<String, Vec<EventRecord>>,
    pub given: Vec<Given>,
    pub error: Option<String>,
    pub simulated: Duration,
    pub restarts: u32,
}

/// A seed's faulty run and, when it had faults, the same plan run without them.
pub struct Run {
    pub plan: Plan,
    pub faulty: Outcome,
    pub uninterrupted: Option<Outcome>,
    pub trace: Vec<String>,
    pub simulated: Duration,
}

pub fn human(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 3600 {
        format!("{}h{:02}m", s / 3600, s % 3600 / 60)
    } else {
        format!("{}m{:02}s", s / 60, s % 60)
    }
}

pub fn run(seed: u64, opts: &Options) -> Run {
    let mut rng = Rng::new(seed);
    let plan = Plan::draw(&mut rng.split(1), opts.faults.0);
    let faulty = simulate(seed, &plan, opts.resend);
    let uninterrupted = (!plan.faults.is_empty()).then(|| {
        let calm = Plan { sends: plan.sends.clone(), faults: Vec::new() };
        simulate(seed, &calm, opts.resend)
    });
    let mut trace = vec![format!(
        "seed {seed}: {} sends {:?}, faults {:?}",
        plan.sends.len(),
        plan.sends.iter().map(|s| (s.at.as_millis(), &s.prompt_id, s.steer)).collect::<Vec<_>>(),
        plan.faults
    )];
    trace.extend(same_instant_sorted(&faulty.app.trace));
    let simulated =
        faulty.simulated + uninterrupted.as_ref().map_or(Duration::ZERO, |u| u.simulated);
    Run { plan, faulty, uninterrupted, trace, simulated }
}

/// The trace in time order, and within one simulated instant in text order. Within an instant
/// the daemon answers waiters in its maps' iteration order, which std seeds per process
/// (`RandomState`); what happens, and when, is the same, only its order within the instant is
/// not. The driver's notes carry the time it last stepped to, so lines are sorted, not merged.
fn same_instant_sorted(trace: &[String]) -> Vec<String> {
    let time =
        |l: &String| l.split_whitespace().next().and_then(|t| t.parse::<u128>().ok()).unwrap_or(0);
    let mut out = trace.to_vec();
    out.sort_by(|a, b| time(a).cmp(&time(b)).then_with(|| a.cmp(b)));
    out
}

fn config() -> Config {
    let profile = HarnessProfile {
        kind: Default::default(),
        // Never run: the profile's ACPMUX_SIM_AGENT makes `ChildAgent::spawn_with` take the
        // in-process agent. A real command, so every check before the spawn passes as for a
        // stand-in agent.
        argv: vec!["python3".into(), "-c".into(), "raise SystemExit(1)".into()],
        env: BTreeMap::from([(acpmux::sim_agent::ENV.to_owned(), "1".to_owned())]),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("sim".to_owned(), profile)]),
        default_harness: Some("sim".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

/// The daemon: a hub over the disk, its restore in the background, and every connection the
/// app opens served by the real protocol handler.
async fn daemon(disk: Arc<Disk>, agents: Arc<Agents>, incarnation: u64) -> turmoil::Result {
    acpmux::sim_agent::install(agents.factory(incarnation));
    let hub = Hub::new(config(), Box::new(SimStore(disk)));
    let _ = hub.person.install_spawn_key(app::PERSON_KEY);
    {
        let hub = hub.clone();
        tokio::spawn(async move { hub.sim_startup().await });
    }
    let listener = turmoil::net::TcpListener::bind(("0.0.0.0", app::PORT)).await?;
    loop {
        let (stream, _) = listener.accept().await?;
        let hub = hub.clone();
        tokio::spawn(async move {
            let (read, mut write) = stream.into_split();
            let (in_tx, in_rx) = mpsc::channel::<String>(64);
            let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
            tokio::spawn(acpmux::server::serve_connection(hub, in_rx, out_tx));
            let reader = async move {
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if in_tx.send(line).await.is_err() {
                        break;
                    }
                }
            };
            let writer = async move {
                while let Some(mut line) = out_rx.recv().await {
                    if !line.ends_with('\n') {
                        line.push('\n');
                    }
                    if write.write_all(line.as_bytes()).await.is_err() {
                        break;
                    }
                }
            };
            tokio::select! { _ = reader => {}, _ = writer => {} }
        });
    }
}

/// A fault in force and what ends it.
enum Heal {
    Restart,
    RepairOneWay,
    Repair,
    Release,
}

fn simulate(seed: u64, plan: &Plan, resend: bool) -> Outcome {
    let mut rng = Rng::new(seed);
    let _plan_stream = rng.split(1);
    let agents = Agents::new(rng.split(2));
    let disk = Arc::new(Disk::default());
    let app: Shared = Rc::new(RefCell::new(App {
        items: plan.sends.iter().map(|s| (s.clone(), Default::default())).collect(),
        calm_after: plan
            .faults
            .iter()
            .map(|(at, f)| {
                *at + match *f {
                    Fault::Crash { down } | Fault::PowerLoss { down } => down,
                    Fault::OneWay { lasting }
                    | Fault::Partition { lasting }
                    | Fault::Hold { lasting } => lasting,
                }
            })
            .max()
            .unwrap_or_default(),
        ..Default::default()
    }));
    let incarnation = Rc::new(Cell::new(0u64));
    let mut sim = turmoil::Builder::new()
        .rng_seed(seed)
        .tick_duration(TICK)
        .simulation_duration(app::GIVE_UP + Duration::from_secs(600))
        .min_message_latency(Duration::from_millis(1))
        .max_message_latency(Duration::from_millis(30))
        .enable_tokio_io()
        .build();
    {
        let (disk, agents, incarnation) = (disk.clone(), agents.clone(), incarnation.clone());
        sim.host(app::DAEMON, move || {
            incarnation.set(incarnation.get() + 1);
            daemon(disk.clone(), agents.clone(), incarnation.get())
        });
    }
    sim.client(APP, app::run(app.clone(), resend));

    let mut faults = plan.faults.iter().copied().peekable();
    let mut heals: Vec<(Duration, Heal)> = Vec::new();
    let (mut down, mut cut) = (false, false);
    let mut restarts = 0;
    let mut error = None;
    let note = |app: &Shared, line: String| {
        let t = app::now_of(&app.borrow());
        app.borrow_mut().trace.push(format!("{t:>8} sim: {line}"));
    };
    loop {
        match sim.step() {
            Ok(true) => break,
            Ok(false) => {}
            Err(e) => {
                error = Some(e.to_string());
                break;
            }
        }
        let now = sim.elapsed();
        app.borrow_mut().clock = now;
        let ready = app.borrow().ready_at;
        if let Some(ready) = ready {
            while let Some((at, fault)) = faults.peek().copied() {
                if ready + at > now {
                    break;
                }
                faults.next();
                match fault {
                    Fault::Crash { down: d } | Fault::PowerLoss { down: d } if !down => {
                        sim.crash(app::DAEMON);
                        down = true;
                        let lost =
                            matches!(fault, Fault::PowerLoss { .. }).then(|| disk.power_loss());
                        note(&app, format!("{fault:?} (unflushed records lost: {lost:?})"));
                        heals.push((now + d, Heal::Restart));
                    }
                    Fault::OneWay { lasting } if !cut => {
                        sim.partition_oneway(app::DAEMON, APP);
                        cut = true;
                        note(&app, format!("{fault:?}"));
                        heals.push((now + lasting, Heal::RepairOneWay));
                    }
                    Fault::Partition { lasting } if !cut => {
                        sim.partition(app::DAEMON, APP);
                        cut = true;
                        note(&app, format!("{fault:?}"));
                        heals.push((now + lasting, Heal::Repair));
                    }
                    Fault::Hold { lasting } if !cut => {
                        sim.hold(app::DAEMON, APP);
                        cut = true;
                        note(&app, format!("{fault:?}"));
                        heals.push((now + lasting, Heal::Release));
                    }
                    _ => note(&app, format!("{fault:?} skipped: one already in force")),
                }
            }
        }
        let (due, later): (Vec<_>, Vec<_>) = heals.drain(..).partition(|(t, _)| *t <= now);
        heals = later;
        for (_, heal) in due {
            match heal {
                Heal::Restart => {
                    sim.bounce(app::DAEMON);
                    down = false;
                    restarts += 1;
                    note(&app, "daemon restarted".into());
                }
                Heal::RepairOneWay => sim.repair_oneway(app::DAEMON, APP),
                Heal::Repair => sim.repair(app::DAEMON, APP),
                Heal::Release => sim.release(app::DAEMON, APP),
            }
            cut = heals.iter().any(|(_, h)| !matches!(h, Heal::Restart));
        }
    }
    let simulated = sim.elapsed();
    drop(sim);
    acpmux::sim_agent::uninstall();
    let given = std::mem::take(&mut *agents.given.lock().unwrap());
    let app = Rc::try_unwrap(app)
        .map(RefCell::into_inner)
        .unwrap_or_else(|rc| std::mem::take(&mut *rc.borrow_mut()));
    Outcome { app, log: disk.snapshot(), given, error, simulated, restarts }
}
