//! The scheduler's decisions, one tick at a time. Pure: [`Scheduler::tick`] takes what was read (machines,
//! roster, queued jobs) and says which machines to resume and which to pause; the CLI does the calls.
//!
//! - Demand: queued `cmux-linux` jobs no runner took. When they outnumber idle online runners plus runners
//!   already on their way, resume paused machines for the difference (Freestyle first, [`crate::plan::pick_up`]).
//! - Idle: a running machine whose runners have all been online and idle for `idle_ms` pauses, while at least
//!   `keep_idle` idle runners stay up for the next job, and never while jobs are queued.
//! - Never deletes; a machine in any state other than running or paused/stopped is left alone.

use std::collections::{HashMap, HashSet};

use serde_json::Value;

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
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            idle_ms: 10 * 60 * 1000,
            keep_idle: 4,
            prefixes: vec!["fsp-".to_owned(), "cmux-runner-pool-".to_owned()],
            label: "cmux-linux".to_owned(),
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
}

/// What the pool must cover this tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Demand {
    /// Queued jobs no runner took (the controller feed): one slot each.
    Jobs(u32),
    /// vCPU wanted (the learned-size scheduler's `--demand-file`: learned p90 over queued and starting jobs).
    Vcpu(u64),
}

impl Demand {
    /// Whether any work waits (no machine pauses while it does).
    pub fn wanted(self) -> bool {
        match self {
            Self::Jobs(n) => n > 0,
            Self::Vcpu(v) => v > 0,
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
}

impl Scheduler {
    pub fn new(policy: Policy) -> Self {
        Self { policy, idle_since: HashMap::new() }
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
        let idle_online =
            u32::try_from(pool.iter().filter(|r| r.online && !r.busy).count()).unwrap_or(u32::MAX);
        let starting: u32 = machines
            .iter()
            .filter(|m| {
                m.power == Power::Starting
                    || (m.power == Power::Running
                        && by.get(&m.id).is_none_or(|rs| rs.iter().all(|r| !r.online)))
            })
            .map(|m| m.slots.max(1))
            .sum();

        // Idle clocks: a machine is idle while running with every listed runner online and not busy.
        let mut live = HashSet::new();
        for machine in machines {
            let idle = machine.power == Power::Running
                && by
                    .get(&machine.id)
                    .is_some_and(|rs| !rs.is_empty() && rs.iter().all(|r| r.online && !r.busy));
            if idle {
                self.idle_since.entry(machine.id.clone()).or_insert(now_ms);
                live.insert(machine.id.clone());
            }
        }
        self.idle_since.retain(|id, _| live.contains(id));

        let queued = match demand {
            Demand::Jobs(n) => n,
            Demand::Vcpu(_) => 0,
        };
        let mut decision = Decision { queued, idle_online, starting, ..Decision::default() };
        let picked = match demand {
            Demand::Jobs(n) => {
                let available = idle_online.saturating_add(starting);
                (n > available).then(|| plan::pick_up(machines, n - available))
            }
            Demand::Vcpu(need) => {
                // Free vCPU: a running machine's idle runners' share of it, plus machines on their way.
                let free: u64 = machines
                    .iter()
                    .map(|m| {
                        let runners = by.get(&m.id).map_or(&[][..], Vec::as_slice);
                        let online = runners.iter().filter(|r| r.online).count() as u64;
                        let idle = runners.iter().filter(|r| r.online && !r.busy).count() as u64;
                        match m.power {
                            Power::Starting => plan::vcpu_of(m),
                            Power::Running if online == 0 => plan::vcpu_of(m),
                            Power::Running => plan::vcpu_of(m) * idle / online,
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
            return decision;
        }
        if demand.wanted() {
            return decision;
        }
        // Pause the longest-idle machines first while the idle floor stays.
        let mut idle: Vec<&Machine> = machines
            .iter()
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
            left -= slots;
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
