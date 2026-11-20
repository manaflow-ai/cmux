//! The scheduler's decisions, one tick at a time. Pure: [`Scheduler::tick`] takes what was read (machines,
//! roster, queued jobs) and says which machines to resume and which to pause; the CLI does the calls.
//!
//! - Demand: queued `cmux-linux` jobs no runner took. When they outnumber idle online runners plus runners
//!   already on their way, resume paused machines for the difference (Freestyle first, [`crate::plan::pick_up`]).
//! - Idle: a running machine whose runners have all been online and idle for `idle_ms` pauses, while at least
//!   `keep_idle` idle runners stay up for the next job, and never while jobs are queued.
//! - Only machines opted in (metadata `cmux_schedule=pause`, GCE label `cmux-schedule=pause`, or `--pause-prefix`)
//!   ever pause: the persistent pools stay running by default.
//! - Never deletes; a machine in any state other than running or paused/stopped is left alone.

use std::collections::{HashMap, HashSet};

use serde_json::Value;

use crate::load::Load;
use crate::model::{Machine, Power, Runner};
use crate::plan;

#[derive(Clone, Debug)]
pub struct Policy {
    /// How long every runner of a machine must be idle before it pauses.
    pub idle_ms: u64,
    /// Idle online runners the pool keeps up for the next job.
    pub keep_idle: u32,
    /// Runner-name prefixes of the pool (`fsp-`, `cmux-runner-pool-`).
    pub prefixes: Vec<String>,
    /// The label demand is counted for.
    pub label: String,
    /// Measured CPU or RAM at or over this: the machine takes no more work (scale up when all are).
    pub busy_pct: f64,
    /// Measured CPU under this (and no job) for `idle_ms`: the machine pauses.
    pub quiet_pct: f64,
    /// Machine-name prefixes the idle pause may also take (`--pause-prefix`), beside machines that opted in
    /// themselves (`Machine::schedule_pause`). Empty by default: the persistent pools stay running.
    pub pause_prefixes: Vec<String>,
    /// How long a machine this scheduler resumed counts as on its way while none of its runners is online.
    pub start_grace_ms: u64,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            idle_ms: 10 * 60 * 1000,
            keep_idle: 4,
            prefixes: vec!["fsp-".to_owned(), "cmux-runner-pool-".to_owned()],
            label: "cmux-linux".to_owned(),
            busy_pct: 90.0,
            quiet_pct: 20.0,
            start_grace_ms: 3 * 60 * 1000,
            pause_prefixes: Vec::new(),
        }
    }
}

/// What one tick decided.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Decision {
    pub resume: Vec<String>,
    pub pause: Vec<String>,
    pub queued: u32,
    pub idle_online: u32,
    pub starting: u32,
    /// With a vCPU demand: what was asked and what was free.
    pub demand_vcpu: u64,
    pub free_vcpu: u64,
    /// Work waited and every measured running machine was at the admission line.
    pub all_full: bool,
}

/// What the pool must cover this tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Demand {
    /// Queued jobs no runner took (the controller feed): one slot each.
    Jobs(u32),
    /// vCPU wanted (the learned-size scheduler's `--demand-file`: learned p90 over queued and starting jobs),
    /// with the feed's queued jobs beside it: work waits while either is above 0.
    Vcpu { vcpu: u64, queued: u32 },
}

impl Demand {
    /// Whether any work waits (no machine pauses while it does).
    pub fn wanted(self) -> bool {
        match self {
            Self::Jobs(n) => n > 0,
            Self::Vcpu { vcpu, queued } => vcpu > 0 || queued > 0,
        }
    }
}

/// Reads `--demand-file`: one line `vcpu=N mem_gib=M` (only `vcpu` drives resumes today).
pub fn parse_demand(text: &str) -> Option<u64> {
    text.split_whitespace().find_map(|word| word.strip_prefix("vcpu=")?.parse().ok())
}

#[derive(Debug, Default)]
pub struct Scheduler {
    pub policy: Policy,
    /// Since when each machine has had every runner online and idle (by machine id).
    idle_since: HashMap<String, u64>,
    /// Measured load by machine name, set before each tick ([`Scheduler::set_loads`]); empty when unmeasured.
    loads: HashMap<String, Load>,
    /// When this scheduler resumed each machine (by id), kept for `start_grace_ms`.
    resumed_at: HashMap<String, u64>,
}

impl Scheduler {
    pub fn new(policy: Policy) -> Self {
        Self { policy, ..Self::default() }
    }

    pub fn set_loads(&mut self, loads: HashMap<String, Load>) {
        self.loads = loads;
    }

    fn note_resumed(&mut self, now_ms: u64, ids: &[String]) {
        for id in ids {
            self.resumed_at.insert(id.clone(), now_ms);
        }
    }

    /// Whether the idle pause may take this machine: it opted in, or a `--pause-prefix` names it. The
    /// persistent pools (hq#15361, hq#15371) stay running by default (hq#15393: no deletes, no caps).
    pub fn pausable(&self, machine: &Machine) -> bool {
        machine.schedule_pause
            || self.policy.pause_prefixes.iter().any(|p| machine.name.starts_with(p.as_str()))
    }

    fn in_pool(&self, runner: &str) -> bool {
        self.policy.prefixes.iter().any(|p| runner.starts_with(p.as_str()))
    }

    pub fn tick(
        &mut self,
        now_ms: u64,
        machines: &[Machine],
        roster: &[Runner],
        demand: Demand,
    ) -> Decision {
        let pool: Vec<Runner> = roster.iter().filter(|r| self.in_pool(&r.name)).cloned().collect();
        let by = plan::runners_by_machine(machines, &pool);
        let no_runner_online =
            |m: &Machine| by.get(&m.id).is_none_or(|rs| rs.iter().all(|r| !r.online));
        // On its way: a machine the provider says is starting, or one this scheduler resumed within the grace
        // window whose runners are not online yet. A running machine with no online runner past that window
        // (a dead listener, or a full VM's stopped listeners) is not capacity on the way.
        let grace = self.policy.start_grace_ms;
        self.resumed_at.retain(|_, at| now_ms.saturating_sub(*at) < grace);
        let on_the_way = |m: &Machine| {
            m.power == Power::Starting
                || (m.power == Power::Running
                    && self.resumed_at.contains_key(&m.id)
                    && no_runner_online(m))
        };
        // Idle online runners on running machines only: GitHub keeps a paused machine's runners online for a
        // while, and those take no job.
        let idle_online = u32::try_from(
            machines
                .iter()
                .filter(|m| m.power == Power::Running)
                .filter_map(|m| by.get(&m.id))
                .flatten()
                .filter(|r| r.online && !r.busy)
                .count(),
        )
        .unwrap_or(u32::MAX);
        let starting: u32 = machines.iter().filter(|m| on_the_way(m)).map(|m| m.slots.max(1)).sum();

        // Idle clocks. Measured: running, no job on it, CPU under the quiet line (its runners may be offline: the
        // guest's admit loop stops listeners while the VM is full). Unmeasured: running with every listed runner
        // online and not busy.
        let mut live = HashSet::new();
        for machine in machines {
            let runners = by.get(&machine.id);
            let no_job = runners.is_none_or(|rs| rs.iter().all(|r| !r.busy));
            let idle = machine.power == Power::Running
                && match self.loads.get(&machine.name) {
                    Some(load) => no_job && load.quiet(self.policy.quiet_pct),
                    None => runners
                        .is_some_and(|rs| !rs.is_empty() && rs.iter().all(|r| r.online && !r.busy)),
                };
            if idle {
                self.idle_since.entry(machine.id.clone()).or_insert(now_ms);
                live.insert(machine.id.clone());
            }
        }
        self.idle_since.retain(|id, _| live.contains(id));

        let queued = match demand {
            Demand::Jobs(n) | Demand::Vcpu { queued: n, .. } => n,
        };
        let mut decision = Decision { queued, idle_online, starting, ..Decision::default() };
        let picked = match demand {
            Demand::Jobs(n) => {
                let available = idle_online.saturating_add(starting);
                (n > available).then(|| plan::pick_up(machines, n - available))
            }
            Demand::Vcpu { vcpu: need, .. } => {
                // Free vCPU: a running machine's idle runners' share of it, plus machines on their way.
                let free: u64 = machines
                    .iter()
                    .map(|m| {
                        let runners = by.get(&m.id).map_or(&[][..], Vec::as_slice);
                        let online = runners.iter().filter(|r| r.online).count() as u64;
                        let idle = runners.iter().filter(|r| r.online && !r.busy).count() as u64;
                        if on_the_way(m) {
                            return plan::vcpu_of(m);
                        }
                        // Measured: the room under the admission line (90% of its vCPU less what it uses, by
                        // the higher of CPU and RAM), not its runners' count.
                        if m.power == Power::Running
                            && let Some(load) = self.loads.get(&m.name)
                        {
                            let used = load.cpu_pct.max(load.mem_pct.unwrap_or(0.0));
                            let room = (self.policy.busy_pct - used).max(0.0) / 100.0;
                            return (plan::vcpu_of(m) as f64 * room).floor() as u64;
                        }
                        match m.power {
                            Power::Running if online > 0 => plan::vcpu_of(m) * idle / online,
                            _ => 0,
                        }
                    })
                    .sum();
                decision.demand_vcpu = need;
                decision.free_vcpu = free;
                (need > free).then(|| plan::pick_up_vcpu(machines, need - free))
            }
        };
        if let Some(picked) = picked {
            decision.resume = picked.into_iter().map(|m| m.id.clone()).collect();
            self.note_resumed(now_ms, &decision.resume);
            return decision;
        }
        if demand.wanted() {
            // Measured: work waits, nothing is on its way, and every running machine is measured at the admission
            // line: grow, even when runners look idle (a full VM's listeners are stopped, or its idle runners
            // cannot fit the work). A machine just resumed has no reading yet, so this waits for it rather than
            // resuming more on every tick.
            let running: Vec<&Machine> =
                machines.iter().filter(|m| m.power == Power::Running).collect();
            let all_full = starting == 0
                && !running.is_empty()
                && running
                    .iter()
                    .all(|m| self.loads.get(&m.name).is_some_and(|l| l.full(self.policy.busy_pct)));
            if all_full {
                decision.all_full = true;
                let grow = match demand {
                    Demand::Jobs(n) => plan::pick_up(machines, n.max(1)),
                    Demand::Vcpu { vcpu, .. } => plan::pick_up_vcpu(machines, vcpu.max(1)),
                };
                decision.resume = grow.into_iter().map(|m| m.id.clone()).collect();
                self.note_resumed(now_ms, &decision.resume);
            }
            return decision;
        }
        // Pause the longest-idle machines first while the idle floor stays.
        let mut idle: Vec<&Machine> = machines
            .iter()
            .filter(|m| self.pausable(m))
            .filter(|m| {
                self.idle_since
                    .get(&m.id)
                    .is_some_and(|&since| now_ms.saturating_sub(since) >= self.policy.idle_ms)
            })
            .collect();
        idle.sort_by_key(|m| {
            (self.idle_since.get(&m.id).copied().unwrap_or(now_ms), m.name.clone())
        });
        let mut left = idle_online;
        for machine in idle {
            let slots = u32::try_from(by.get(&machine.id).map_or(0, Vec::len)).unwrap_or(u32::MAX);
            if left.saturating_sub(slots) < self.policy.keep_idle {
                continue;
            }
            left = left.saturating_sub(slots);
            decision.pause.push(machine.id.clone());
        }
        decision
    }
}

/// Queued jobs for `label` that no runner took, from the build controller's webhook feed
/// (`GET /v1/github/actions?repo=OWNER/NAME&recent=0`; hq `gha_runners.py` `feed_demand` reads the same).
pub fn feed_queued(body: &Value, label: &str) -> u32 {
    let completed: HashSet<u64> = body
        .get("runs")
        .and_then(Value::as_array)
        .map(|runs| {
            runs.iter()
                .filter(|r| r.get("status").and_then(Value::as_str) == Some("completed"))
                .filter_map(|r| r.get("id").and_then(Value::as_u64))
                .collect()
        })
        .unwrap_or_default();
    let jobs = body.get("jobs").and_then(Value::as_array).cloned().unwrap_or_default();
    let count = jobs
        .iter()
        .filter(|j| j.get("status").and_then(Value::as_str) == Some("queued"))
        .filter(|j| {
            let named = |key: &str| {
                j.get(key).is_some_and(|v| {
                    !v.is_null() && v.as_str() != Some("") && v.as_u64() != Some(0)
                })
            };
            !named("runner_name") && !named("runner_id")
        })
        .filter(|j| {
            j.get("run_id").and_then(Value::as_u64).is_none_or(|id| !completed.contains(&id))
        })
        .filter(|j| {
            j.get("labels")
                .and_then(Value::as_array)
                .is_some_and(|labels| labels.iter().any(|l| l.as_str() == Some(label)))
        })
        .count();
    u32::try_from(count).unwrap_or(u32::MAX)
}
