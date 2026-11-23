//! Which machines to resume or pause. Pure: the providers and GitHub are read before, called after.

use std::collections::{HashMap, HashSet};

use crate::model::{Machine, Power, Provider, Runner};

/// The machines `up` resumes to bring `count` runners up: paused before stopped (a memory resume is faster than
/// a boot), Freestyle before GCP (0.8 s against 14.5 s), then by name, taken until their slots reach `count`.
pub fn pick_up(machines: &[Machine], count: u32) -> Vec<&Machine> {
    pick_up_by(machines, u64::from(count), |m| u64::from(m.slots.max(1)))
}

/// The machines to resume to cover `need` vCPU (the learned-size scheduler's demand), same order as
/// [`pick_up`]. A machine of unknown size counts as 4 vCPU.
pub fn pick_up_vcpu(machines: &[Machine], need: u64) -> Vec<&Machine> {
    pick_up_by(machines, need, vcpu_of)
}

/// A machine's vCPU for demand, 4 when unknown.
pub fn vcpu_of(machine: &Machine) -> u64 {
    if machine.vcpu == 0 { 4 } else { u64::from(machine.vcpu) }
}

fn pick_up_by(machines: &[Machine], need: u64, weight: impl Fn(&Machine) -> u64) -> Vec<&Machine> {
    let mut candidates: Vec<&Machine> = machines.iter().filter(|m| m.power.resumable()).collect();
    candidates.sort_by(|a, b| {
        let rank = |m: &Machine| (m.power != Power::Paused, m.provider != Provider::Freestyle);
        rank(a).cmp(&rank(b)).then_with(|| a.name.cmp(&b.name))
    });
    let mut picked = Vec::new();
    let mut covered = 0u64;
    for machine in candidates {
        if covered >= need {
            break;
        }
        covered = covered.saturating_add(weight(machine).max(1));
        picked.push(machine);
    }
    picked
}

/// The machine a runner belongs to: the longest machine name that owns it.
pub fn owner<'a>(machines: &'a [Machine], runner: &str) -> Option<&'a Machine> {
    machines.iter().filter(|m| m.owns_runner(runner)).max_by_key(|m| m.name.len())
}

/// Each machine's runners in the roster, by machine id.
pub fn runners_by_machine<'a>(
    machines: &[Machine],
    roster: &'a [Runner],
) -> HashMap<String, Vec<&'a Runner>> {
    let mut by: HashMap<String, Vec<&Runner>> = HashMap::new();
    for runner in roster {
        if let Some(machine) = owner(machines, &runner.name) {
            by.entry(machine.id.clone()).or_default().push(runner);
        }
    }
    by
}

/// Running machines that may pause: every runner GitHub lists for it is in `allowed` (a set of runner
/// names, e.g. the ones idle long enough) and none is busy. A machine with no runner in the roster is
/// never picked: nothing says it is idle.
pub fn pick_pause<'a>(
    machines: &'a [Machine],
    roster: &[Runner],
    allowed: &HashSet<String>,
) -> Vec<&'a Machine> {
    let by = runners_by_machine(machines, roster);
    machines
        .iter()
        .filter(|m| m.power == Power::Running)
        .filter(|m| {
            by.get(&m.id).is_some_and(|runners| {
                !runners.is_empty() && runners.iter().all(|r| !r.busy && allowed.contains(&r.name))
            })
        })
        .collect()
}

/// The runner names `up` waits for: the roster's runners of the picked machines, or, for a machine GitHub
/// does not list yet, nothing (it cannot come online under a name we do not know).
pub fn wanted_runners(picked: &[&Machine], roster: &[Runner]) -> HashSet<String> {
    roster
        .iter()
        .filter(|r| picked.iter().any(|m| m.owns_runner(&r.name)))
        .map(|r| r.name.clone())
        .collect()
}

/// The pool's size and use: machines by power state, runner slots, and the pool's runners in GitHub
/// (online, busy, idle). With queued jobs beside it, this is "slots busy against jobs queued".
pub fn totals(machines: &[Machine], roster: &[Runner]) -> serde_json::Value {
    let count = |power: Power| machines.iter().filter(|m| m.power == power).count();
    let pool: Vec<&Runner> =
        roster.iter().filter(|r| machines.iter().any(|m| m.owns_runner(&r.name))).collect();
    let online = pool.iter().filter(|r| r.online).count();
    let busy = pool.iter().filter(|r| r.online && r.busy).count();
    serde_json::json!({
        "machines": machines.len(),
        "running": count(Power::Running),
        "paused": count(Power::Paused),
        "stopped": count(Power::Stopped),
        "slots": machines.iter().map(|m| u64::from(m.slots.max(1))).sum::<u64>(),
        "runners_listed": pool.len(),
        "runners_online": online,
        "runners_busy": busy,
        "runners_idle": online - busy,
    })
}
