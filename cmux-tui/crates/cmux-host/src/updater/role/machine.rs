//! The updater role's process-wide state as one pure state machine (hq RFD 0047, item 2; the
//! shape of `../gate/machine.rs`). [`step`] takes the [`State`] and one [`Event`] and answers the
//! next state and a [`Verdict`]. It reads no clock, takes no lock and runs no thread: `role.rs`
//! is the shell that keeps the one [`State`] of the process under a mutex, steps it and maps
//! the verdict to what it did before (a blocking commit section, a stale worker's stop).
//!
//! The state is three facts that used to be three statics of `role.rs`:
//!
//! - the stop count ([`State::generation`], was `GENERATION`): every stop bumps it, and a
//!   worker started at another count has been told to stop ([`Refusal::Stale`]);
//! - the commit section ([`Commit`], was the `COMMIT` mutex): one flip, rollback or adopt's
//!   flip at a time in this process, from its worker's last stale look through the flip and the
//!   queued restarts; a stop waits for it ([`Refusal::CommitHeld`]), so once a stop returns no
//!   worker flips or restarts anything;
//! - the holds the gate's file could not record (was `UNRECORDED`), kept as an in-memory
//!   [`GateState`] that the gate machine itself steps: the same hold rules as the file, and
//!   this process's flips honor them as a flip through the gate would.
//!
//! [`table`] is the abstract machine as data (6 states x every event), committed as
//! `schemas/updater-role/table.json`; a test fails when the committed copy is stale.

use std::time::Duration;

use serde_json::{Value, json};

use crate::updater::gate::machine::{self as gate, GateState, Hold, View};
use crate::updater::gate::{CONNECT_HOLD, HoldKind, Honor};

/// The updater role's state in one process.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct State {
    /// How many stops this process made: a worker runs at the count its start read.
    generation: u64,
    commit: Commit,
    /// The holds this process could not record in the gate's file; never written to a file.
    unrecorded: GateState,
}

impl State {
    /// The stop count.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn commit(&self) -> Commit {
        self.commit
    }

    /// The unrecorded holds at `now_ms`.
    pub fn unrecorded(&self, now_ms: u64) -> Hold {
        View::at(&self.unrecorded, now_ms).hold
    }

    /// The abstract state ([`table`]'s) at `now_ms`.
    pub fn name(&self, now_ms: u64) -> String {
        let commit = match self.commit {
            Commit::Free => "free",
            Commit::Held => "held",
        };
        let unrecorded = match self.unrecorded(now_ms) {
            Hold::None => "none",
            Hold::Resume { .. } => "resume",
            Hold::Connect { .. } => "connect",
        };
        format!("commit={commit} unrecorded={unrecorded}")
    }
}

/// The commit section.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Commit {
    #[default]
    Free,
    /// A flip (a check's, an adopt's or an install's) or a rollback runs its last steps.
    Held,
}

/// Who asks whether it may go on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caller {
    /// A `cmux host update` verb, outside any worker: it never stops.
    Verb,
    /// The service's worker, started at `generation`.
    Worker { generation: u64 },
}

/// Every mutation and question of the role's state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// A role start: the generation its worker runs at. Nothing changes.
    Start,
    /// A role stop (`UpdaterRole::halt`): the next generation, once no commit runs.
    Stop,
    /// A flip or rollback enters the commit section.
    Enter,
    /// It leaves it.
    Leave,
    /// A question at each step that would change something: may `by` go on?
    Live { by: Caller },
    /// The gate's file could not record a hold of `kind` taken at `now_ms` (it lasts
    /// [`CONNECT_HOLD`]): this process keeps it.
    HoldNotRecorded { kind: HoldKind, now_ms: u64 },
    /// A question: what is left at `now_ms` of the unrecorded holds a flip honoring `honor`
    /// honors.
    HeldLeft { honor: Honor, now_ms: u64 },
}

/// Why an event was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A commit runs: a stop or another commit waits for it.
    CommitHeld,
    /// [`Event::Leave`] with no commit running.
    NotEntered,
    /// The worker started at `mine` was told to stop: the count is `now`.
    Stale { mine: u64, now: u64 },
}

/// The answer to an event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// The worker starting now runs at `generation`.
    Started {
        generation: u64,
    },
    /// The stop went in: workers of earlier generations stop; `generation` is the new count.
    Stopped {
        generation: u64,
    },
    Entered,
    Left,
    /// The caller goes on.
    Live,
    /// The hold is kept.
    Kept,
    /// What is left of the unrecorded holds asked about.
    HeldLeft(Option<Duration>),
    Refused(Refusal),
}

impl Verdict {
    /// Its name in [`table`].
    pub fn name(&self) -> &'static str {
        match self {
            Verdict::Started { .. } => "started",
            Verdict::Stopped { .. } => "stopped",
            Verdict::Entered => "entered",
            Verdict::Left => "left",
            Verdict::Live => "live",
            Verdict::Kept => "kept",
            Verdict::HeldLeft(None) => "not_held",
            Verdict::HeldLeft(Some(_)) => "held",
            Verdict::Refused(Refusal::CommitHeld) => "refused_commit_held",
            Verdict::Refused(Refusal::NotEntered) => "refused_not_entered",
            Verdict::Refused(Refusal::Stale { .. }) => "refused_stale",
        }
    }
}

/// One step: the next state and the answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub state: State,
    pub verdict: Verdict,
}

impl Step {
    fn to(state: State, verdict: Verdict) -> Step {
        Step { state, verdict }
    }

    fn refuse(state: State, refusal: Refusal) -> Step {
        Step::to(state, Verdict::Refused(refusal))
    }
}

/// The role's state after `event`.
pub fn step(state: State, event: Event) -> Step {
    match event {
        Event::Start => {
            let generation = state.generation;
            Step::to(state, Verdict::Started { generation })
        }
        Event::Stop => match state.commit {
            Commit::Held => Step::refuse(state, Refusal::CommitHeld),
            Commit::Free => {
                let mut next = state;
                next.generation = next.generation.wrapping_add(1);
                let generation = next.generation;
                Step::to(next, Verdict::Stopped { generation })
            }
        },
        Event::Enter => match state.commit {
            Commit::Held => Step::refuse(state, Refusal::CommitHeld),
            Commit::Free => Step::to(State { commit: Commit::Held, ..state }, Verdict::Entered),
        },
        Event::Leave => match state.commit {
            Commit::Free => Step::refuse(state, Refusal::NotEntered),
            Commit::Held => Step::to(State { commit: Commit::Free, ..state }, Verdict::Left),
        },
        Event::Live { by: Caller::Verb } => Step::to(state, Verdict::Live),
        Event::Live { by: Caller::Worker { generation: mine } } => {
            let now = state.generation;
            // Any other count, also one from the future, is a stop the worker missed.
            if mine == now {
                Step::to(state, Verdict::Live)
            } else {
                Step::refuse(state, Refusal::Stale { mine, now })
            }
        }
        Event::HoldNotRecorded { kind, now_ms } => {
            let held =
                gate::step(state.unrecorded.clone(), now_ms, gate::Event::InsideHold { kind });
            Step::to(State { unrecorded: held.state, ..state }, Verdict::Kept)
        }
        Event::HeldLeft { honor, now_ms } => {
            // What a flip through a gate holding these holds alone would answer; its pending
            // mark is not kept.
            let ran = gate::step(state.unrecorded.clone(), now_ms, gate::Event::Run { honor });
            let left = match ran.verdict {
                gate::Verdict::Refused(gate::Refusal::Held(left)) => Some(left),
                // Never a bind or a restart in this state: nothing else holds the flip.
                gate::Verdict::Refused(
                    gate::Refusal::BindInFlight(_) | gate::Refusal::RestartPending,
                )
                | gate::Verdict::Run { .. }
                | gate::Verdict::Done
                | gate::Verdict::HoldTaken { .. }
                | gate::Verdict::BindBegun
                | gate::Verdict::HeldLeft(_)
                | gate::Verdict::ServiceStarted { .. }
                | gate::Verdict::OwnFlip { .. } => None,
            };
            Step::to(state, Verdict::HeldLeft(left))
        }
    }
}

/// The time the table's sample states are read at.
const SAMPLE_NOW: u64 = 1_000_000_000;
/// The sample states' stop count.
const SAMPLE_GENERATION: u64 = 7;

/// Every abstract state, read at [`SAMPLE_NOW`]: commit (free, held) x unrecorded hold (none,
/// resume, connect), each at [`SAMPLE_GENERATION`].
pub fn sample_states() -> Vec<State> {
    let taken = SAMPLE_NOW.saturating_sub(1_000);
    let mut states = Vec::new();
    for commit in [Commit::Free, Commit::Held] {
        for kind in [None, Some(HoldKind::Resume), Some(HoldKind::Connect)] {
            let mut state = State { generation: SAMPLE_GENERATION, commit, ..State::default() };
            if let Some(kind) = kind {
                state = step(state, Event::HoldNotRecorded { kind, now_ms: taken }).state;
            }
            states.push(state);
        }
    }
    states
}

/// One event per kind, with its name in [`table`].
pub fn sample_events() -> Vec<(&'static str, Event)> {
    let now_ms = SAMPLE_NOW;
    let worker = |generation| Event::Live { by: Caller::Worker { generation } };
    vec![
        ("start", Event::Start),
        ("stop", Event::Stop),
        ("enter", Event::Enter),
        ("leave", Event::Leave),
        ("live_verb", Event::Live { by: Caller::Verb }),
        ("live_worker_current", worker(SAMPLE_GENERATION)),
        ("live_worker_stale", worker(SAMPLE_GENERATION - 1)),
        ("live_worker_ahead", worker(SAMPLE_GENERATION + 1)),
        ("hold_not_recorded_resume", Event::HoldNotRecorded { kind: HoldKind::Resume, now_ms }),
        ("hold_not_recorded_connect", Event::HoldNotRecorded { kind: HoldKind::Connect, now_ms }),
        ("held_left_all", Event::HeldLeft { honor: Honor::All, now_ms }),
        ("held_left_all_but_resume", Event::HeldLeft { honor: Honor::AllButResume, now_ms }),
        ("held_left_nothing", Event::HeldLeft { honor: Honor::Nothing, now_ms }),
    ]
}

/// The abstract machine as data: every state against every event, with the verdict, the state
/// after it and whether the stop count moved.
pub fn table() -> Value {
    let states = sample_states();
    let events = sample_events();
    let mut rows = Vec::new();
    for state in &states {
        let from = state.name(SAMPLE_NOW);
        for (name, event) in &events {
            let step = step(state.clone(), *event);
            rows.push(json!({
                "from": from,
                "event": name,
                "verdict": step.verdict.name(),
                "to": step.state.name(SAMPLE_NOW),
                "generation_moved": step.state.generation != state.generation,
            }));
        }
    }
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-host/src/updater/role/machine.rs",
        "generation": "Every stop bumps the count, once no commit runs. A worker runs at the count its start read; a worker's live look at any other count is refused_stale (the sample states are at 7: current 7, stale 6, ahead 8).",
        "time": format!("An unrecorded hold lasts {} s from when it was taken and lapses by time alone; no event shortens one. Its rules are the gate machine's (schemas/updater-gate/table.json): a connect hold is held by every flip that honors any hold, a resume hold only by one honoring all.", CONNECT_HOLD.as_secs()),
        "refusals": "A refusal leaves the state unchanged. refused_commit_held is a wait: the shell blocks a commit until the one running leaves, and retries a stop until its deadline.",
        "states": states.iter().map(|s| s.name(SAMPLE_NOW)).collect::<Vec<_>>(),
        "events": events.iter().map(|(name, _)| *name).collect::<Vec<_>>(),
        "transitions": rows,
    })
}

#[cfg(test)]
mod tests;
