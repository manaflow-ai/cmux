//! The restart gate as one pure state machine (hq RFD 0026, option B; the shape of
//! `cmux-cloud-machine/src/power.rs`). [`step`] takes the gate's file ([`GateState`]), the time
//! and one [`Event`], and answers the next file, whether the shell must write it and a
//! [`Verdict`]. It reads no clock, no file and takes no lock: `gate.rs` is the shell that
//! locks, reads, steps, writes and maps the verdict to its own return types.
//!
//! The file holds absolute expiries; at a time `now_ms` it reads as a [`View`] of three
//! orthogonal facts and a mark: a [`Hold`] (none, a resume hold, or a connect hold, which
//! dominates), a [`Restart`] (idle or pending), a [`Bind`] (idle or in flight) and the own-flip
//! mark. Every decision below matches on those enums, every pair written out: a new variant does
//! not compile until each event decides it. Every bound lapses by time alone; no event shortens
//! a hold ([`Event::UnreadableFile`] replaces a file whose holds are lost anyway).
//!
//! [`table`] is the abstract machine as data (24 states x every event), committed as
//! `schemas/updater-gate/table.json`; a test fails when the committed copy is stale.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{BIND_IN_FLIGHT_FOR, CONNECT_HOLD, HoldKind, Honor, RESTART_PENDING_FOR};

/// The gate's file ([`super::GATE_FILE`]). Its serde shape is the one every build reads and
/// writes: keep the field names, and the rule that a missing `connect_until_ms` (a file from
/// before the hold kinds) makes every hold a connect hold.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GateState {
    /// The end of every hold, whatever its kind (all a build from before the
    /// kinds reads).
    #[serde(default)]
    held_until_ms: Option<u64>,
    /// The end of the connect holds alone (0: none). Missing in a file from
    /// before the kinds: then every hold in it is a connect hold.
    #[serde(default)]
    connect_until_ms: Option<u64>,
    #[serde(default)]
    restart_pending_until_ms: Option<u64>,
    /// The last update flip's mark, until the next start takes it. A build
    /// from before it drops it when it writes the file: a cold start then.
    #[serde(default)]
    own_flip: Option<OwnFlip>,
    /// Until when a bind's request may still be in flight
    /// ([`super::Gate::begin_bind`]).
    #[serde(default)]
    bind_in_flight_until_ms: Option<u64>,
}

/// An update's flip queued the service's restart at `at_ms`, with
/// `realtime - boottime` at `offset_ns` (a reboot or a restore moves it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnFlip {
    pub at_ms: u64,
    pub offset_ns: i64,
}

impl GateState {
    /// When the holds no flag skips end.
    fn connect_until(&self) -> Option<u64> {
        self.connect_until_ms.or(self.held_until_ms)
    }

    /// This state with a hold of `kind` until at least `until`.
    fn held(mut self, until: u64, kind: HoldKind) -> Self {
        // Read before `held_until_ms` moves: an old file's hold is a connect hold.
        let connect = self.connect_until().unwrap_or(0);
        self.connect_until_ms = Some(match kind {
            HoldKind::Connect => connect.max(until),
            HoldKind::Resume => connect,
        });
        self.held_until_ms = Some(self.held_until_ms.map_or(until, |held| held.max(until)));
        self
    }

    /// What replaces a file that can't be parsed: what it said is lost, so a
    /// connect hold, a pending restart and a bind in flight, each for a fresh
    /// bound from `now_ms`, as if a bind had just started. It lapses on its own.
    fn repaired(now_ms: u64) -> Self {
        let held = now_ms.saturating_add(ms(CONNECT_HOLD));
        GateState {
            held_until_ms: Some(held),
            connect_until_ms: Some(held),
            restart_pending_until_ms: Some(now_ms.saturating_add(ms(RESTART_PENDING_FOR))),
            own_flip: None,
            bind_in_flight_until_ms: Some(now_ms.saturating_add(ms(BIND_IN_FLIGHT_FOR))),
        }
    }
}

/// The holds at a time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hold {
    None,
    /// Only a resume hold is on, for `left`.
    Resume {
        left: Duration,
    },
    /// A connect hold is on, for `left`; `all` is what is left of every hold. It is at least
    /// `left` in every file a build writes; a hand-made file whose connect end lies past the end
    /// of every hold keeps the old answers (an update's flip honors `all` alone).
    Connect {
        left: Duration,
        all: Option<Duration>,
    },
}

/// A queued restart of the service, at a time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Restart {
    Idle,
    Pending { left: Duration },
}

/// A bind's request, at a time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bind {
    Idle,
    InFlight { left: Duration },
}

/// The file read at `now_ms`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct View {
    pub hold: Hold,
    pub restart: Restart,
    pub bind: Bind,
    pub own_flip: Option<OwnFlip>,
}

impl View {
    pub fn at(state: &GateState, now_ms: u64) -> View {
        let all = left(state.held_until_ms, now_ms);
        let hold = match (left(state.connect_until(), now_ms), all) {
            (Some(left), all) => Hold::Connect { left, all },
            (None, Some(left)) => Hold::Resume { left },
            (None, None) => Hold::None,
        };
        let restart = match left(state.restart_pending_until_ms, now_ms) {
            Some(left) => Restart::Pending { left },
            None => Restart::Idle,
        };
        let bind = match left(state.bind_in_flight_until_ms, now_ms) {
            Some(left) => Bind::InFlight { left },
            None => Bind::Idle,
        };
        View { hold, restart, bind, own_flip: state.own_flip }
    }

    /// What is left of every hold.
    pub fn held_left(&self) -> Option<Duration> {
        match self.hold {
            Hold::None => None,
            Hold::Resume { left } => Some(left),
            Hold::Connect { all, .. } => all,
        }
    }

    /// The abstract state ([`table`]'s).
    pub fn name(&self) -> String {
        let hold = match self.hold {
            Hold::None => "none",
            Hold::Resume { .. } => "resume",
            Hold::Connect { .. } => "connect",
        };
        let restart = match self.restart {
            Restart::Idle => "idle",
            Restart::Pending { .. } => "pending",
        };
        let bind = match self.bind {
            Bind::Idle => "idle",
            Bind::InFlight { .. } => "in_flight",
        };
        let flip = match self.own_flip {
            None => "none",
            Some(_) => "marked",
        };
        format!("hold={hold} restart={restart} bind={bind} own_flip={flip}")
    }
}

/// Every mutation and question the gate answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// [`super::Gate::hold`]: a hold of `kind` for `hold` from now.
    Hold {
        kind: HoldKind,
        hold: Duration,
    },
    /// [`super::Inside::hold`]: a hold of `kind` for [`CONNECT_HOLD`], inside a run.
    InsideHold {
        kind: HoldKind,
    },
    BeginBind,
    EndBind,
    /// [`super::Gate::held_left`]: a question; nothing changes.
    HeldLeft,
    /// A flip's entry into [`super::Gate::run`].
    Run {
        honor: Honor,
    },
    /// [`super::Inside::restart_queued`].
    RestartQueued,
    /// [`super::Inside::flip_restart_queued`], `realtime - boottime` at `offset_ns`.
    FlipRestartQueued {
        offset_ns: i128,
    },
    /// The run's `act` returned; `queued` when it queued the restart.
    RunFinished {
        queued: bool,
    },
    /// [`super::Gate::service_started_at`].
    ServiceStarted,
    /// [`super::Gate::take_own_flip`].
    TakeOwnFlip,
    /// The file could not be parsed ([`GateState::repaired`]).
    UnreadableFile,
}

/// Why an event was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A hold the flip honors is on, for this long.
    Held(Duration),
    /// A bind's request is in flight; its mark lasts this long at most.
    BindInFlight(Duration),
    /// A restart of the service is pending: a bind made now would be cut.
    RestartPending,
}

/// The answer to an event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// A mark or a hold went in ([`Event::EndBind`], the in-run marks, a repaired file), or a
    /// finished run had nothing to undo.
    Done,
    /// The hold went in; `restart_pending` when a restart is pending (the caller does not bind).
    HoldTaken {
        restart_pending: bool,
    },
    BindBegun,
    HeldLeft(Option<Duration>),
    /// The flip may run, the restart marked pending; `skipped` is the hold it goes past.
    Run {
        skipped: Option<HoldKind>,
    },
    /// The service's start; `restart_was_pending` when a pending mark had not lapsed.
    ServiceStarted {
        restart_was_pending: bool,
    },
    /// The own-flip mark taken: `fresh` when it is at most [`RESTART_PENDING_FOR`] old and not
    /// from the future. The shell still checks `mark.offset_ns` against the clock.
    OwnFlip {
        mark: Option<OwnFlip>,
        fresh: bool,
    },
    Refused(Refusal),
}

impl Verdict {
    /// Its name in [`table`].
    pub fn name(&self) -> &'static str {
        match self {
            Verdict::Done => "done",
            Verdict::HoldTaken { restart_pending: false } => "hold_taken",
            Verdict::HoldTaken { restart_pending: true } => "hold_taken_restart_pending",
            Verdict::BindBegun => "bind_begun",
            Verdict::HeldLeft(None) => "not_held",
            Verdict::HeldLeft(Some(_)) => "held",
            Verdict::Run { skipped: None } => "run",
            Verdict::Run { skipped: Some(HoldKind::Resume) } => "run_skipping_resume_hold",
            Verdict::Run { skipped: Some(HoldKind::Connect) } => "run_skipping_connect_hold",
            Verdict::ServiceStarted { restart_was_pending: true } => "started_as_queued_restart",
            Verdict::ServiceStarted { restart_was_pending: false } => "started_cold",
            Verdict::OwnFlip { mark: None, .. } => "no_own_flip",
            Verdict::OwnFlip { mark: Some(_), fresh: true } => "own_flip_fresh",
            Verdict::OwnFlip { mark: Some(_), fresh: false } => "own_flip_stale",
            Verdict::Refused(Refusal::Held(_)) => "refused_held",
            Verdict::Refused(Refusal::BindInFlight(_)) => "refused_bind_in_flight",
            Verdict::Refused(Refusal::RestartPending) => "refused_restart_pending",
        }
    }
}

/// One step: the next file, whether the shell writes it, and the answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub state: GateState,
    pub write: bool,
    pub verdict: Verdict,
}

impl Step {
    fn write(state: GateState, verdict: Verdict) -> Step {
        Step { state, write: true, verdict }
    }

    fn keep(state: GateState, verdict: Verdict) -> Step {
        Step { state, write: false, verdict }
    }

    fn refuse(state: GateState, refusal: Refusal) -> Step {
        Step::keep(state, Verdict::Refused(refusal))
    }
}

/// The gate after `event` at `now_ms`.
pub fn step(state: GateState, now_ms: u64, event: Event) -> Step {
    let view = View::at(&state, now_ms);
    let pending_until = Some(now_ms.saturating_add(ms(RESTART_PENDING_FOR)));
    let connect_hold = now_ms.saturating_add(ms(CONNECT_HOLD));
    match event {
        Event::Hold { kind, hold } => {
            let restart_pending = match view.restart {
                Restart::Idle => false,
                Restart::Pending { .. } => true,
            };
            let next = state.held(now_ms.saturating_add(ms(hold)), kind);
            Step::write(next, Verdict::HoldTaken { restart_pending })
        }
        Event::InsideHold { kind } => Step::write(state.held(connect_hold, kind), Verdict::Done),
        Event::BeginBind => match view.restart {
            Restart::Pending { .. } => Step::refuse(state, Refusal::RestartPending),
            Restart::Idle => {
                let mut next = state.held(connect_hold, HoldKind::Connect);
                next.bind_in_flight_until_ms = Some(now_ms.saturating_add(ms(BIND_IN_FLIGHT_FOR)));
                Step::write(next, Verdict::BindBegun)
            }
        },
        Event::EndBind => {
            let mut next = state;
            next.bind_in_flight_until_ms = None;
            Step::write(next.held(connect_hold, HoldKind::Connect), Verdict::Done)
        }
        Event::HeldLeft => Step::keep(state, Verdict::HeldLeft(view.held_left())),
        Event::Run { honor } => run(state, view, pending_until, honor),
        Event::RestartQueued => {
            let mut next = state;
            next.restart_pending_until_ms = pending_until;
            Step::write(next, Verdict::Done)
        }
        Event::FlipRestartQueued { offset_ns } => {
            let mut next = state;
            next.restart_pending_until_ms = pending_until;
            next.own_flip =
                i64::try_from(offset_ns).ok().map(|offset_ns| OwnFlip { at_ms: now_ms, offset_ns });
            Step::write(next, Verdict::Done)
        }
        Event::RunFinished { queued: true } => Step::keep(state, Verdict::Done),
        Event::RunFinished { queued: false } => {
            // The restart that was marked never comes.
            let mut next = state;
            next.restart_pending_until_ms = None;
            Step::write(next, Verdict::Done)
        }
        Event::ServiceStarted => {
            let restart_was_pending = match view.restart {
                Restart::Idle => false,
                Restart::Pending { .. } => true,
            };
            let verdict = Verdict::ServiceStarted { restart_was_pending };
            // A lapsed mark goes too; no mark at all, nothing to write.
            let mut next = state.clone();
            next.restart_pending_until_ms = None;
            Step { write: next != state, state: next, verdict }
        }
        Event::TakeOwnFlip => match view.own_flip {
            None => Step::keep(state, Verdict::OwnFlip { mark: None, fresh: false }),
            Some(mark) => {
                let age = now_ms.checked_sub(mark.at_ms);
                let fresh = age.is_some_and(|age| age <= ms(RESTART_PENDING_FOR));
                let mut next = state;
                next.own_flip = None;
                Step::write(next, Verdict::OwnFlip { mark: Some(mark), fresh })
            }
        },
        Event::UnreadableFile => Step::write(GateState::repaired(now_ms), Verdict::Done),
    }
}

/// A flip's entry: refused by a hold it honors, then by a bind in flight; else the restart is
/// marked pending and the flip runs.
fn run(state: GateState, view: View, pending_until: Option<u64>, honor: Honor) -> Step {
    let skipped = match (honor, view.hold) {
        (Honor::All, Hold::None) => None,
        (Honor::All, Hold::Resume { left }) => {
            return Step::refuse(state, Refusal::Held(left));
        }
        (Honor::All, Hold::Connect { all: Some(left), .. }) => {
            return Step::refuse(state, Refusal::Held(left));
        }
        (Honor::All, Hold::Connect { all: None, .. }) => None,
        (Honor::AllButResume, Hold::None) => None,
        (Honor::AllButResume, Hold::Resume { .. }) => Some(HoldKind::Resume),
        (Honor::AllButResume, Hold::Connect { left, .. }) => {
            return Step::refuse(state, Refusal::Held(left));
        }
        (Honor::Nothing, Hold::None | Hold::Resume { .. } | Hold::Connect { .. }) => None,
    };
    let mut next = state.clone();
    next.restart_pending_until_ms = pending_until;
    match (honor, view.bind) {
        (Honor::All | Honor::AllButResume | Honor::Nothing, Bind::Idle) => {
            Step::write(next, Verdict::Run { skipped })
        }
        (Honor::All | Honor::AllButResume, Bind::InFlight { left }) => {
            Step::refuse(state, Refusal::BindInFlight(left))
        }
        // A rollback that waits marks the restart pending (best effort), so no new bind
        // starts before it.
        (Honor::Nothing, Bind::InFlight { left }) => Step {
            state: next,
            write: true,
            verdict: Verdict::Refused(Refusal::BindInFlight(left)),
        },
    }
}

fn ms(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

fn left(until_ms: Option<u64>, now_ms: u64) -> Option<Duration> {
    until_ms
        .and_then(|until| until.checked_sub(now_ms))
        .filter(|left| *left > 0)
        .map(Duration::from_millis)
}

/// The time the table's sample states are read at.
const SAMPLE_NOW: u64 = 1_000_000_000;
/// Where each bound of the sample states ends: a minute after [`SAMPLE_NOW`].
const SAMPLE_UNTIL: u64 = SAMPLE_NOW.saturating_add(60_000);
/// When the sample own flip was queued: a second before [`SAMPLE_NOW`].
const SAMPLE_FLIP_AT: u64 = SAMPLE_NOW.saturating_sub(1_000);

/// Every abstract state, as a file read at [`SAMPLE_NOW`]: hold (none, resume, connect) x
/// restart (idle, pending) x bind (idle, in flight) x own flip (none, marked).
pub fn sample_states() -> Vec<GateState> {
    let until = Some(SAMPLE_UNTIL);
    let mut states = Vec::new();
    for (held_until_ms, connect_until_ms) in [(None, None), (until, Some(0)), (until, until)] {
        for restart_pending_until_ms in [None, until] {
            for bind_in_flight_until_ms in [None, until] {
                for own_flip in [None, Some(OwnFlip { at_ms: SAMPLE_FLIP_AT, offset_ns: 0 })] {
                    states.push(GateState {
                        held_until_ms,
                        connect_until_ms,
                        restart_pending_until_ms,
                        own_flip,
                        bind_in_flight_until_ms,
                    });
                }
            }
        }
    }
    states
}

/// One event per kind, with its name in [`table`].
pub fn sample_events() -> Vec<(&'static str, Event)> {
    vec![
        ("hold_resume", Event::Hold { kind: HoldKind::Resume, hold: CONNECT_HOLD }),
        ("hold_connect", Event::Hold { kind: HoldKind::Connect, hold: CONNECT_HOLD }),
        ("inside_hold_resume", Event::InsideHold { kind: HoldKind::Resume }),
        ("inside_hold_connect", Event::InsideHold { kind: HoldKind::Connect }),
        ("begin_bind", Event::BeginBind),
        ("end_bind", Event::EndBind),
        ("held_left", Event::HeldLeft),
        ("run_all", Event::Run { honor: Honor::All }),
        ("run_all_but_resume", Event::Run { honor: Honor::AllButResume }),
        ("run_nothing", Event::Run { honor: Honor::Nothing }),
        ("restart_queued", Event::RestartQueued),
        ("flip_restart_queued", Event::FlipRestartQueued { offset_ns: 0 }),
        ("run_finished_queued", Event::RunFinished { queued: true }),
        ("run_finished_unqueued", Event::RunFinished { queued: false }),
        ("service_started", Event::ServiceStarted),
        ("take_own_flip", Event::TakeOwnFlip),
        ("unreadable_file", Event::UnreadableFile),
    ]
}

/// The abstract machine as data: every state against every event, with the verdict, whether
/// the shell writes, and the state the file reads as after it (at the same time).
pub fn table() -> Value {
    let states = sample_states();
    let events = sample_events();
    let mut rows = Vec::new();
    for state in &states {
        let from = View::at(state, SAMPLE_NOW).name();
        for (name, event) in &events {
            let step = step(state.clone(), SAMPLE_NOW, *event);
            rows.push(json!({
                "from": from,
                "event": name,
                "verdict": step.verdict.name(),
                "write": step.write,
                "to": View::at(&step.state, SAMPLE_NOW).name(),
            }));
        }
    }
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-host/src/updater/gate/machine.rs",
        "time": "Every bound (hold, pending restart, bind in flight) is an absolute expiry; at a later time a state reads as the one with the lapsed bounds dropped. No event shortens a hold; unreadable_file replaces a file whose contents are lost.",
        "refusals": "A refusal leaves the file unchanged and unwritten, except run_nothing (a rollback) meeting a bind in flight: it writes the pending restart, best effort, so no new bind starts before it.",
        "states": states.iter().map(|s| View::at(s, SAMPLE_NOW).name()).collect::<Vec<_>>(),
        "events": events.iter().map(|(name, _)| *name).collect::<Vec<_>>(),
        "transitions": rows,
    })
}

#[cfg(test)]
mod tests;
