//! The work placer of RFD agent-work-placement and RFD 0072 ("Auto, harmony between your
//! computer and its VMs"): for one piece of agent work about to start, whether it runs on the
//! person's computer, on the chat's warm (maybe paused) work VM, on that VM grown in place, on a
//! bigger VM, on cmux-ci's warm pool, or on a serve VM that outlives the call. It decides from
//! three things Leo named: the host's pressure, the person reclaiming their computer (lid, battery,
//! their own heavy app or build) and the work's predicted size.
//!
//! Leo (2026-11-25): "how does its work auto-route to a bigger vm instead of your local machine?
//! ... what if a user suddently wants to close their computer? ... open up photoshop? ... compile
//! their web app? ... compile chromium? and likewise what if the agent wants to do that? what if
//! someone/some agent suddenly wants to manually get a machine?"
//!
//! This file is pure: nothing here moves, forks, resumes or resizes anything. [`decide`] is the
//! whole rule, with one scenario test per RFD 0072 S1-S11 (`work_place_tests.rs`). It is off by
//! default: [`enabled`] reads `CMUX_WORK_PLACER=1`, and until a caller checks it the verdict is not
//! acted on. The thresholds marked **A** are assumed and wait on measured ones.

use super::command_shadow::{GROW_CEILING, MAX_WORKLOAD_VCPU, MEM_HEADROOM, Shape};
use serde::Serialize;

/// The default-off switch: `CMUX_WORK_PLACER=1` turns the placer on.
pub const ENV: &str = "CMUX_WORK_PLACER";

pub fn enabled() -> bool {
    std::env::var(ENV).is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true"))
}

/// Seconds to ship a job to the pool and read its result back (agent-work-placement, algorithm 2).
pub const SHIP_S: f64 = 20.0;
/// The pool's mean queue wait by class, measured (agent-work-placement, "Measurements").
pub const QUEUE_RUST_S: f64 = 246.0;
pub const QUEUE_SWIFT_S: f64 = 899.0;
pub const QUEUE_CHECK_LIGHT_S: f64 = 150.0;
/// Free memory the person keeps on their own computer before agent work counts as short (**A**).
pub const PERSON_MEM_RESERVE_GIB: f64 = 4.0;
/// Battery under this sends new work off a computer on battery (RFD 0072 rule, 15%).
pub const LOW_BATTERY_PERCENT: u8 = 15;
/// A job predicted above this many CPU-seconds is huge: never the person's computer (S10, **A**).
pub const HUGE_CPU_S: f64 = 8.0 * 3_600.0;
/// Dollars per hour of a person's or agent's waiting (agent-work-placement, "Cost").
pub const STALL_DOLLARS_PER_HOUR: f64 = 10.0;

/// The pool's queue classes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Class {
    Rust,
    Swift,
    CheckLight,
    /// Anything the pool does not run: it may go to a VM, never to the pool.
    Other,
}

impl Class {
    fn queue_s(self) -> Option<f64> {
        match self {
            Class::Rust => Some(QUEUE_RUST_S),
            Class::Swift => Some(QUEUE_SWIFT_S),
            Class::CheckLight => Some(QUEUE_CHECK_LIGHT_S),
            Class::Other => None,
        }
    }
}

/// The work about to start, as the predictor sees it.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Work {
    pub class: Class,
    /// Predicted wall seconds on the person's computer with it idle; `None` when unknown.
    pub local_s: Option<f64>,
    /// Predicted peak shape; `None` when unknown.
    pub need: Option<Shape>,
    /// Predicted CPU-seconds (S10's signal); `None` when unknown.
    pub cpu_s: Option<f64>,
    /// Listens on a port or outlives its tool call (a dev server, S9).
    pub listens: bool,
}

/// The person's computer: its load and whether the person is taking it back.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Host {
    pub ncpu: f64,
    /// One-minute load average.
    pub load1: f64,
    /// `/proc/pressure/cpu` some avg10, percent; `None` where PSI is off (macOS).
    pub psi_cpu_some10: Option<f64>,
    pub mem_available_gib: f64,
    /// The lid is closing or the computer is going to sleep (S7).
    pub sleeping: bool,
    pub on_battery: bool,
    pub battery_percent: Option<u8>,
    /// The person's own share of the CPU, 0-1, read apart from the agents' (S8). The person's load
    /// alone moves nothing: it only shrinks what is left for agents.
    pub person_cpu_share: f64,
    /// The person runs a heavy app or their own build (Photoshop, their web app, Chromium).
    pub person_heavy: bool,
}

/// The chat's machines.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Machines {
    /// The chat's work VM, if it has one, and whether it is paused.
    pub work_vm: Option<WorkVm>,
    /// The chat is pinned to a machine someone asked for by hand (S11): never moved or shrunk.
    pub pinned: Option<Pinned>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkVm {
    pub shape: Shape,
    pub paused: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Pinned {
    /// Pinned to the person's computer.
    Local,
    /// Pinned to a VM of this shape.
    Vm(Shape),
}

/// Team policy.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Policy {
    /// Above this predicted cost a cost-estimate card shows before a huge job starts (S10).
    pub estimate_card_dollars: f64,
    /// Dollars per vCPU-hour at list, for the estimate.
    pub dollars_per_vcpu_hour: f64,
}

impl Default for Policy {
    fn default() -> Self {
        Self { estimate_card_dollars: 5.0, dollars_per_vcpu_hour: 0.05 }
    }
}

/// Where the work runs.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "place")]
pub enum Place {
    /// On the person's computer.
    Local,
    /// On the chat's work VM as it is; `resume` when it is paused (S3).
    WorkVm { resume: bool },
    /// On the chat's work VM grown in place to `to` (S4).
    Grow { to: Shape },
    /// On a new VM of this shape: a first work VM, or past the grow ceiling (S4, S10).
    BiggerVm { shape: Shape },
    /// On cmux-ci's warm pool (S4, S10).
    Pool,
    /// On a serve VM that outlives the call, its port forwarded to the person's computer (S9).
    ServeVm,
}

/// Why, in the order [`decide`] asks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    /// A machine someone asked for by hand is never moved (S11).
    Pinned,
    /// The lid closes or the computer sleeps: work continues in the cloud (S7).
    Sleep,
    LowBattery,
    /// Listens on a port or outlives its call (S9).
    Listens,
    /// Predicted huge: never the person's computer (S10).
    Huge,
    /// The person's own heavy app or build leaves agents too little (S8).
    PersonBusy,
    /// Not enough memory on the person's computer for the predicted peak.
    MemoryShort,
    /// Algorithm 2: the stretch lost here is more than the pool's or VM's wait.
    Stretch,
    /// The chat already works on its VM: its working folders are there (S2).
    OnVm,
    /// Fits here and nothing presses (S1).
    Fits,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    pub place: Place,
    pub reason: Reason,
    /// Seconds the work would lose to stretch here, against the remote wait (algorithm 2).
    pub lose_s: Option<f64>,
    pub remote_s: Option<f64>,
    /// Predicted cost in dollars when a card must show first (S10); `None` when no card.
    pub estimate_card: Option<f64>,
}

impl Verdict {
    fn new(place: Place, reason: Reason) -> Self {
        Self { place, reason, lose_s: None, remote_s: None, estimate_card: None }
    }
}

/// How much longer work runs here than on an idle machine (algorithm 2): the larger of the run
/// queue's oversubscription with this work added and PSI's stall factor.
pub fn stretch(host: &Host, need_cores: f64) -> f64 {
    let ncpu = host.ncpu.max(1.0);
    // The person's share is theirs: agents see only what is left (S8).
    let agents_cpu = (ncpu * (1.0 - host.person_cpu_share.clamp(0.0, 0.95))).max(1.0);
    let queue = (host.load1 + need_cores) / agents_cpu;
    let psi = host.psi_cpu_some10.map_or(1.0, |p| 1.0 / (1.0 - (p / 100.0).min(0.95)));
    queue.max(psi).max(1.0)
}

/// The shape a job of this need runs on: headroom on memory, at most the largest workload VM.
fn sized(need: Shape) -> Shape {
    Shape {
        vcpu: need.vcpu.ceil().clamp(2.0, MAX_WORKLOAD_VCPU),
        mem_gib: (need.mem_gib * MEM_HEADROOM).ceil().max(4.0),
    }
}

fn holds(have: Shape, need: Shape) -> bool {
    need.vcpu <= have.vcpu + f64::EPSILON && need.mem_gib <= have.mem_gib + f64::EPSILON
}

/// Off the person's computer: the chat's VM as it is, grown, a bigger VM or the pool.
fn remote(work: &Work, m: &Machines) -> Place {
    let need = work.need.unwrap_or(Shape { vcpu: 1.0, mem_gib: 1.0 });
    if let Some(vm) = m.work_vm {
        if holds(vm.shape, need) {
            return Place::WorkVm { resume: vm.paused };
        }
        if holds(GROW_CEILING, need) {
            // A machine never shrinks in place: grow to the larger of each axis.
            let to = Shape {
                vcpu: vm.shape.vcpu.max(sized(need).vcpu),
                mem_gib: vm.shape.mem_gib.max(sized(need).mem_gib),
            };
            return Place::Grow { to };
        }
    } else if holds(GROW_CEILING, need) {
        return Place::BiggerVm { shape: sized(need) };
    }
    // Past the grow ceiling: the pool runs its classes, a big VM the rest.
    if work.class.queue_s().is_some() {
        Place::Pool
    } else {
        Place::BiggerVm { shape: sized(need) }
    }
}

/// The remote wait for `place` (algorithm 2's `pool = queue_s + ship_s`).
fn remote_wait(place: Place, work: &Work) -> f64 {
    match place {
        Place::Pool => work.class.queue_s().unwrap_or(0.0) + SHIP_S,
        Place::WorkVm { resume: false } => SHIP_S,
        // Resume 2.8 s, grow 6.5 s, create 5 s (RFD 0072 R numbers), plus the ship.
        Place::WorkVm { resume: true } => SHIP_S + 2.8,
        Place::Grow { .. } => SHIP_S + 6.5,
        Place::BiggerVm { .. } | Place::ServeVm => SHIP_S + 5.0,
        Place::Local => 0.0,
    }
}

fn estimate(work: &Work, policy: &Policy) -> Option<f64> {
    let cpu_s = work.cpu_s?;
    let dollars = cpu_s / 3_600.0 * policy.dollars_per_vcpu_hour;
    (dollars > policy.estimate_card_dollars).then_some(dollars)
}

/// Where this work runs. Asked in order: pinned, the person leaving, a server, huge, the person
/// busy, memory, stretch, the chat already on its VM, else here.
pub fn decide(work: &Work, host: &Host, m: &Machines, policy: &Policy) -> Verdict {
    // S11: a machine got by hand is never moved or shrunk. Work bigger than a pinned VM still runs
    // on it; the person chose it.
    match m.pinned {
        Some(Pinned::Local) => return Verdict::new(Place::Local, Reason::Pinned),
        Some(Pinned::Vm(_)) => {
            return Verdict::new(Place::WorkVm { resume: false }, Reason::Pinned);
        }
        None => {}
    }
    // S9: a dev server runs on a serve VM, its port forwarded.
    if work.listens {
        return Verdict::new(Place::ServeVm, Reason::Listens);
    }
    // S7: the lid closes; the work goes on in the cloud.
    if host.sleeping {
        return Verdict::new(remote(work, m), Reason::Sleep);
    }
    if host.on_battery && host.battery_percent.is_some_and(|p| p < LOW_BATTERY_PERCENT) {
        return Verdict::new(remote(work, m), Reason::LowBattery);
    }
    // S10: huge is never the person's computer; a card first above the team's threshold.
    let huge = work.cpu_s.is_some_and(|c| c > HUGE_CPU_S)
        || work.need.is_some_and(|n| !holds(GROW_CEILING, n));
    if huge {
        let mut v = Verdict::new(remote(work, m), Reason::Huge);
        v.estimate_card = estimate(work, policy);
        return v;
    }
    // S8: the person's heavy app or build: new agent work leaves rather than being throttled.
    if host.person_heavy {
        return Verdict::new(remote(work, m), Reason::PersonBusy);
    }
    let need = work.need;
    if need.is_some_and(|n| n.mem_gib > host.mem_available_gib - PERSON_MEM_RESERVE_GIB) {
        return Verdict::new(remote(work, m), Reason::MemoryShort);
    }
    // Algorithm 2: offload when the seconds lost to stretch here beat the remote wait.
    if let Some(local_s) = work.local_s {
        let s = stretch(host, need.map_or(1.0, |n| n.vcpu));
        let lose = local_s * (s - 1.0);
        let place = remote(work, m);
        let wait = remote_wait(place, work);
        if lose > wait {
            let mut v = Verdict::new(place, Reason::Stretch);
            v.lose_s = Some(lose);
            v.remote_s = Some(wait);
            return v;
        }
    }
    // S2: a chat already working on its VM keeps its work there, beside its working folders.
    if let Some(vm) = m.work_vm
        && need.is_none_or(|n| holds(vm.shape, n))
    {
        return Verdict::new(Place::WorkVm { resume: vm.paused }, Reason::OnVm);
    }
    Verdict::new(Place::Local, Reason::Fits)
}

/// Dollars the wait costs at [`STALL_DOLLARS_PER_HOUR`].
pub fn stall_dollars(seconds: f64) -> f64 {
    seconds / 3_600.0 * STALL_DOLLARS_PER_HOUR
}

#[cfg(test)]
#[path = "work_place_tests.rs"]
mod tests;
