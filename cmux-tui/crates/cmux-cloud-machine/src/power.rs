//! One Cloud machine's power as an explicit state machine: an enum of states that carry their
//! own data, and one pure [`step`] from `(Machine, Event)` to the next machine and the effects to
//! run, or a named [`Refusal`]. Every (state, event) pair is written out: no arm falls through to a
//! default, so a new state or event does not compile until each pair is decided.
//!
//! Nothing calls this yet. It is the runtime layer the `cmux-lifeline` typestate handles
//! (cmux#46922) can sit on, and its table ([`table`], committed as
//! `schemas/cloud-machine-power/table.json`) is what the TypeScript platform's `Power.ts` and the
//! app's copies of the status (`CloudMachine.swift`, `webviews/src/pages/cloud/model.ts`) can
//! replay later.
//!
//! The states are [`Status`]'s, with `running` split in two: a running VM whose daemon has not
//! answered its handshake yet (`running`) and one that has (`ready`). Only `ready` can attach
//! (docs: hq `docs/handbook/vm-operation-without-state-proof.md`).
//!
//! Every provider call, timer and handshake is issued under a fresh [`Generation`], and its
//! answer comes back as an event carrying it. A state that awaits an answer holds the generation
//! it waits for; an answer under any other generation is refused ([`Refusal::StaleGeneration`])
//! and the state stays, so a late provider answer cannot overwrite newer intent. A timeout is not
//! proof of failure: it moves the machine to `unknown` and asks for a fresh observation.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::record::{PauseReason, Status};

/// The intent id an effect was issued under, and its answer carries back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Generation(pub u64);

/// A machine's power state and the data only that state has.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Power {
    /// Create was sent under `op`; the provider has not answered.
    Provisioning { op: Generation },
    /// The VM runs; the daemon handshake issued under `since` has not answered.
    Running { since: Generation },
    /// The VM runs and its daemon answered the handshake issued under `since`. Attachable.
    Ready { since: Generation },
    /// The provider said the VM failed, at `failed_at` (epoch ms).
    Failed { failed_at: u64 },
    /// Paused at `paused_at` (epoch ms); `reason` is None when an observation found it paused.
    Paused { paused_at: u64, reason: Option<PauseReason> },
    /// Gone. Nothing leaves it.
    Destroyed,
    /// Not known: an operation timed out or failed without proof of where it left the VM. A
    /// refresh was issued under `probe`.
    Unknown { probe: Generation },
    /// Pause was sent under `op`.
    Pausing { op: Generation, reason: PauseReason },
    /// Resume was sent under `op`.
    Starting { op: Generation },
    /// Delete was sent under `op`.
    Deleting { op: Generation },
}

impl Power {
    /// Every state's name, in the table's order.
    pub const KINDS: [&'static str; 10] = [
        "provisioning",
        "running",
        "ready",
        "failed",
        "paused",
        "destroyed",
        "unknown",
        "pausing",
        "starting",
        "deleting",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Power::Provisioning { .. } => "provisioning",
            Power::Running { .. } => "running",
            Power::Ready { .. } => "ready",
            Power::Failed { .. } => "failed",
            Power::Paused { .. } => "paused",
            Power::Destroyed => "destroyed",
            Power::Unknown { .. } => "unknown",
            Power::Pausing { .. } => "pausing",
            Power::Starting { .. } => "starting",
            Power::Deleting { .. } => "deleting",
        }
    }

    /// The record status this state shows as ([`Status`], the app's and the server's word).
    pub fn status(&self) -> Status {
        match self {
            Power::Provisioning { .. } => Status::Provisioning,
            Power::Running { .. } | Power::Ready { .. } => Status::Running,
            Power::Failed { .. } => Status::Failed,
            Power::Paused { .. } => Status::Paused,
            Power::Destroyed => Status::Destroyed,
            Power::Unknown { .. } => Status::Unknown,
            Power::Pausing { .. } => Status::Pausing,
            Power::Starting { .. } => Status::Starting,
            Power::Deleting { .. } => Status::Deleting,
        }
    }

    /// The power operation (create, pause, resume, delete) in flight, by its generation.
    pub fn in_flight(&self) -> Option<Generation> {
        match self {
            Power::Provisioning { op }
            | Power::Pausing { op, .. }
            | Power::Starting { op }
            | Power::Deleting { op } => Some(*op),
            Power::Running { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Destroyed
            | Power::Unknown { .. } => None,
        }
    }

    /// The generation whose answer this state waits for (an operation, a handshake or a probe).
    pub fn awaits(&self) -> Option<Generation> {
        match self {
            Power::Provisioning { op }
            | Power::Pausing { op, .. }
            | Power::Starting { op }
            | Power::Deleting { op } => Some(*op),
            Power::Running { since } => Some(*since),
            Power::Unknown { probe } => Some(*probe),
            Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Destroyed => None,
        }
    }
}

/// A machine: its power state and the last generation it issued.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub power: Power,
    pub issued: Generation,
}

impl Machine {
    /// A new machine: create is sent under generation 1.
    pub fn create() -> (Machine, Vec<Effect>) {
        let op = Generation(1);
        (
            Machine { power: Power::Provisioning { op }, issued: op },
            vec![Effect::Create { generation: op }, Effect::ArmTimer { generation: op }],
        )
    }

    /// A machine the app found and knows nothing proven about: a refresh is sent under
    /// generation 1.
    pub fn adopt() -> (Machine, Vec<Effect>) {
        let probe = Generation(1);
        (Machine { power: Power::Unknown { probe }, issued: probe }, refresh(probe))
    }
}

/// What a provider observation said the VM is. An observation never grants `ready`: only the
/// daemon's handshake does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Observation {
    Running,
    Paused,
    Failed,
    Destroyed,
    Unknown,
}

impl Observation {
    pub const ALL: [Observation; 5] = [
        Observation::Running,
        Observation::Paused,
        Observation::Failed,
        Observation::Destroyed,
        Observation::Unknown,
    ];

    /// A record status read as an observation. An in-between status proves no end state.
    pub fn from_status(status: Status) -> Observation {
        match status {
            Status::Running => Observation::Running,
            Status::Paused => Observation::Paused,
            Status::Failed => Observation::Failed,
            Status::Destroyed => Observation::Destroyed,
            // `stopped` (cmux-lifeline: confirmed after a refused or failed start) is not a
            // power state this machine models, so it proves neither running nor paused.
            Status::Provisioning
            | Status::Unknown
            | Status::Pausing
            | Status::Starting
            | Status::Stopped
            | Status::Deleting => Observation::Unknown,
        }
    }
}

/// An intent, or an answer under the generation it was issued with. `at` is epoch ms.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Event {
    Pause {
        reason: PauseReason,
    },
    Resume,
    Delete,
    Attach,
    /// The provider finished the operation issued under `generation`.
    Succeeded {
        generation: Generation,
        at: u64,
    },
    /// The provider said the operation issued under `generation` failed.
    Failed {
        generation: Generation,
        at: u64,
    },
    /// The timer armed under `generation` fired.
    TimedOut {
        generation: Generation,
    },
    /// The daemon answered the handshake issued under `generation`.
    DaemonReady {
        generation: Generation,
    },
    /// The refresh issued under `generation` observed the VM.
    Observed {
        generation: Generation,
        observation: Observation,
        at: u64,
    },
}

impl Event {
    /// Every event's name, in the table's order.
    pub const KINDS: [&'static str; 13] = [
        "pause",
        "resume",
        "delete",
        "attach",
        "succeeded",
        "failed",
        "timed_out",
        "daemon_ready",
        "observed_running",
        "observed_paused",
        "observed_failed",
        "observed_destroyed",
        "observed_unknown",
    ];

    pub fn kind(&self) -> &'static str {
        match self {
            Event::Pause { .. } => "pause",
            Event::Resume => "resume",
            Event::Delete => "delete",
            Event::Attach => "attach",
            Event::Succeeded { .. } => "succeeded",
            Event::Failed { .. } => "failed",
            Event::TimedOut { .. } => "timed_out",
            Event::DaemonReady { .. } => "daemon_ready",
            Event::Observed { observation, .. } => match observation {
                Observation::Running => "observed_running",
                Observation::Paused => "observed_paused",
                Observation::Failed => "observed_failed",
                Observation::Destroyed => "observed_destroyed",
                Observation::Unknown => "observed_unknown",
            },
        }
    }

    /// The generation an answer carries; None for an intent.
    pub fn generation(&self) -> Option<Generation> {
        match self {
            Event::Pause { .. } | Event::Resume | Event::Delete | Event::Attach => None,
            Event::Succeeded { generation, .. }
            | Event::Failed { generation, .. }
            | Event::TimedOut { generation }
            | Event::DaemonReady { generation }
            | Event::Observed { generation, .. } => Some(*generation),
        }
    }
}

/// What the caller runs after a transition, in order. Each answer comes back as an [`Event`]
/// under the effect's generation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Effect {
    Create {
        generation: Generation,
    },
    Pause {
        generation: Generation,
        reason: PauseReason,
    },
    Resume {
        generation: Generation,
    },
    Delete {
        generation: Generation,
    },
    /// Read the provider's view of the VM; answer [`Event::Observed`].
    Refresh {
        generation: Generation,
    },
    /// Handshake with the VM's daemon; answer [`Event::DaemonReady`].
    AwaitDaemon {
        generation: Generation,
    },
    /// Arm the deadline for what was issued under `generation`; answer [`Event::TimedOut`].
    ArmTimer {
        generation: Generation,
    },
    /// Open the attach to the ready daemon.
    Attach,
}

impl Effect {
    pub fn kind(&self) -> &'static str {
        match self {
            Effect::Create { .. } => "create",
            Effect::Pause { .. } => "pause",
            Effect::Resume { .. } => "resume",
            Effect::Delete { .. } => "delete",
            Effect::Refresh { .. } => "refresh",
            Effect::AwaitDaemon { .. } => "await_daemon",
            Effect::ArmTimer { .. } => "arm_timer",
            Effect::Attach => "attach",
        }
    }

    /// A provider power call (create, pause, resume, delete).
    pub fn is_power_call(&self) -> bool {
        match self {
            Effect::Create { .. }
            | Effect::Pause { .. }
            | Effect::Resume { .. }
            | Effect::Delete { .. } => true,
            Effect::Refresh { .. }
            | Effect::AwaitDaemon { .. }
            | Effect::ArmTimer { .. }
            | Effect::Attach => false,
        }
    }

    pub fn generation(&self) -> Option<Generation> {
        match self {
            Effect::Create { generation }
            | Effect::Pause { generation, .. }
            | Effect::Resume { generation }
            | Effect::Delete { generation }
            | Effect::Refresh { generation }
            | Effect::AwaitDaemon { generation }
            | Effect::ArmTimer { generation } => Some(*generation),
            Effect::Attach => None,
        }
    }
}

/// Why an event was refused. The machine is unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// The machine is destroyed; nothing leaves it.
    Destroyed,
    /// Another power operation is in flight; at most one is.
    OperationInFlight,
    /// Pause and attach need a running machine.
    NotRunning,
    /// Resume needs a paused machine.
    NotPaused,
    /// Attach needs the daemon's handshake.
    NotReady,
    /// An answer the state does not wait for.
    NotAwaited,
    /// An answer under an older (or other) generation than the one the state waits for.
    StaleGeneration,
}

impl Refusal {
    pub const ALL: [Refusal; 7] = [
        Refusal::Destroyed,
        Refusal::OperationInFlight,
        Refusal::NotRunning,
        Refusal::NotPaused,
        Refusal::NotReady,
        Refusal::NotAwaited,
        Refusal::StaleGeneration,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::Destroyed => "destroyed",
            Refusal::OperationInFlight => "operation_in_flight",
            Refusal::NotRunning => "not_running",
            Refusal::NotPaused => "not_paused",
            Refusal::NotReady => "not_ready",
            Refusal::NotAwaited => "not_awaited",
            Refusal::StaleGeneration => "stale_generation",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Refusal {}

pub type Step = Result<(Machine, Vec<Effect>), Refusal>;

/// The machine after `event`, and the effects to run; or why `event` is refused.
pub fn step(machine: Machine, event: Event) -> Step {
    let Machine { power, issued } = machine;
    let next = Generation(issued.0 + 1);
    let to = |power: Power, effects: Vec<Effect>| -> Step {
        Ok((Machine { power, issued: next }, effects))
    };
    let settle = |power: Power| -> Step { Ok((Machine { power, issued }, Vec::new())) };
    match event {
        Event::Pause { reason } => match power {
            Power::Running { .. } | Power::Ready { .. } => to(
                Power::Pausing { op: next, reason },
                call(Effect::Pause { generation: next, reason }, next),
            ),
            Power::Failed { .. } | Power::Paused { .. } | Power::Unknown { .. } => {
                Err(Refusal::NotRunning)
            }
            Power::Provisioning { .. }
            | Power::Pausing { .. }
            | Power::Starting { .. }
            | Power::Deleting { .. } => Err(Refusal::OperationInFlight),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::Resume => match power {
            Power::Paused { .. } => {
                to(Power::Starting { op: next }, call(Effect::Resume { generation: next }, next))
            }
            Power::Running { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Unknown { .. } => Err(Refusal::NotPaused),
            Power::Provisioning { .. }
            | Power::Pausing { .. }
            | Power::Starting { .. }
            | Power::Deleting { .. } => Err(Refusal::OperationInFlight),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::Delete => match power {
            Power::Running { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Unknown { .. } => {
                to(Power::Deleting { op: next }, call(Effect::Delete { generation: next }, next))
            }
            Power::Provisioning { .. }
            | Power::Pausing { .. }
            | Power::Starting { .. }
            | Power::Deleting { .. } => Err(Refusal::OperationInFlight),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::Attach => match power {
            Power::Ready { .. } => Ok((machine, vec![Effect::Attach])),
            Power::Running { .. } => Err(Refusal::NotReady),
            Power::Failed { .. } | Power::Paused { .. } | Power::Unknown { .. } => {
                Err(Refusal::NotRunning)
            }
            Power::Provisioning { .. }
            | Power::Pausing { .. }
            | Power::Starting { .. }
            | Power::Deleting { .. } => Err(Refusal::OperationInFlight),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::Succeeded { generation, at } => match power {
            Power::Provisioning { op } | Power::Starting { op } => {
                current(op, generation)?;
                to(Power::Running { since: next }, handshake(next))
            }
            Power::Pausing { op, reason } => {
                current(op, generation)?;
                settle(Power::Paused { paused_at: at, reason: Some(reason) })
            }
            Power::Deleting { op } => {
                current(op, generation)?;
                settle(Power::Destroyed)
            }
            Power::Running { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Unknown { .. } => Err(Refusal::NotAwaited),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::Failed { generation, at } => match power {
            Power::Provisioning { op } | Power::Starting { op } => {
                current(op, generation)?;
                settle(Power::Failed { failed_at: at })
            }
            // A failed pause or delete leaves the VM where the provider left it: look again.
            Power::Pausing { op, .. } | Power::Deleting { op } => {
                current(op, generation)?;
                to(Power::Unknown { probe: next }, refresh(next))
            }
            Power::Running { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Unknown { .. } => Err(Refusal::NotAwaited),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::TimedOut { generation } => match power {
            Power::Provisioning { op }
            | Power::Pausing { op, .. }
            | Power::Starting { op }
            | Power::Deleting { op }
            | Power::Running { since: op }
            | Power::Unknown { probe: op } => {
                current(op, generation)?;
                to(Power::Unknown { probe: next }, refresh(next))
            }
            Power::Ready { .. } | Power::Failed { .. } | Power::Paused { .. } => {
                Err(Refusal::NotAwaited)
            }
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::DaemonReady { generation } => match power {
            Power::Running { since } => {
                current(since, generation)?;
                settle(Power::Ready { since })
            }
            Power::Provisioning { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Unknown { .. }
            | Power::Pausing { .. }
            | Power::Starting { .. }
            | Power::Deleting { .. } => Err(Refusal::NotAwaited),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
        Event::Observed { generation, observation, at } => match power {
            Power::Unknown { probe } => {
                current(probe, generation)?;
                match observation {
                    Observation::Running => to(Power::Running { since: next }, handshake(next)),
                    Observation::Paused => settle(Power::Paused { paused_at: at, reason: None }),
                    Observation::Failed => settle(Power::Failed { failed_at: at }),
                    Observation::Destroyed => settle(Power::Destroyed),
                    // Still unknown: the probe's timer looks again.
                    Observation::Unknown => settle(power),
                }
            }
            Power::Provisioning { .. }
            | Power::Running { .. }
            | Power::Ready { .. }
            | Power::Failed { .. }
            | Power::Paused { .. }
            | Power::Pausing { .. }
            | Power::Starting { .. }
            | Power::Deleting { .. } => Err(Refusal::NotAwaited),
            Power::Destroyed => Err(Refusal::Destroyed),
        },
    }
}

/// An answer is for the generation the state waits on, or it is stale.
fn current(awaited: Generation, got: Generation) -> Result<(), Refusal> {
    if awaited == got { Ok(()) } else { Err(Refusal::StaleGeneration) }
}

fn call(effect: Effect, generation: Generation) -> Vec<Effect> {
    vec![effect, Effect::ArmTimer { generation }]
}

fn refresh(generation: Generation) -> Vec<Effect> {
    vec![Effect::Refresh { generation }, Effect::ArmTimer { generation }]
}

fn handshake(generation: Generation) -> Vec<Effect> {
    vec![Effect::AwaitDaemon { generation }, Effect::ArmTimer { generation }]
}

/// The generation the table's sample states await and its sample answers carry.
const SAMPLE: Generation = Generation(7);

/// One machine per state, in [`Power::KINDS`] order, awaiting [`SAMPLE`] where it awaits.
pub fn sample_states() -> [Machine; 10] {
    let g = SAMPLE;
    [
        Power::Provisioning { op: g },
        Power::Running { since: g },
        Power::Ready { since: g },
        Power::Failed { failed_at: 0 },
        Power::Paused { paused_at: 0, reason: Some(PauseReason::User) },
        Power::Destroyed,
        Power::Unknown { probe: g },
        Power::Pausing { op: g, reason: PauseReason::User },
        Power::Starting { op: g },
        Power::Deleting { op: g },
    ]
    .map(|power| Machine { power, issued: g })
}

/// One event per kind, in [`Event::KINDS`] order; answers carry `generation`.
pub fn sample_events(generation: Generation) -> [Event; 13] {
    let observed = |observation| Event::Observed { generation, observation, at: 0 };
    [
        Event::Pause { reason: PauseReason::User },
        Event::Resume,
        Event::Delete,
        Event::Attach,
        Event::Succeeded { generation, at: 0 },
        Event::Failed { generation, at: 0 },
        Event::TimedOut { generation },
        Event::DaemonReady { generation },
        observed(Observation::Running),
        observed(Observation::Paused),
        observed(Observation::Failed),
        observed(Observation::Destroyed),
        observed(Observation::Unknown),
    ]
}

/// The whole transition table as data: every state against every event, each a transition (the
/// state it moves to and its effects' kinds) or a named refusal. Answers in the rows carry the
/// generation the state awaits; any other generation is refused as the `stale` rule says.
pub fn table() -> Value {
    let mut rows = Vec::new();
    for machine in sample_states() {
        for event in sample_events(SAMPLE) {
            let row = match step(machine, event) {
                Ok((after, effects)) => json!({
                    "from": machine.power.kind(),
                    "event": event.kind(),
                    "to": after.power.kind(),
                    "effects": effects.iter().map(Effect::kind).collect::<Vec<_>>(),
                }),
                Err(refusal) => json!({
                    "from": machine.power.kind(),
                    "event": event.kind(),
                    "refusal": refusal.as_str(),
                }),
            };
            rows.push(row);
        }
    }
    let states: Vec<Value> = sample_states()
        .iter()
        .map(|m| {
            json!({
                "state": m.power.kind(),
                "status": m.power.status().as_str(),
                "awaits": m.power.awaits().is_some(),
                "inFlight": m.power.in_flight().is_some(),
            })
        })
        .collect();
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-cloud-machine/src/power.rs",
        "stale": "An answer (succeeded, failed, timed_out, daemon_ready, observed_*) whose generation is not the one the state awaits is refused stale_generation; a state that awaits nothing refuses it not_awaited; destroyed refuses every event. A refusal leaves the machine unchanged.",
        "generations": "Every transition that issues an effect issues it under a new generation (issued + 1), so an old timer or answer can never match.",
        "states": states,
        "events": Event::KINDS,
        "refusals": Refusal::ALL.map(Refusal::as_str),
        "transitions": rows,
    })
}

#[cfg(test)]
mod tests;
