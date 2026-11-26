//! Where a chat runs, and moving it: the chat's place mode (Local, Cloud on its own VM, Auto), the
//! move's state machine and the view the chat draws while it moves, the Auto rule, Evacuate's
//! plan and the own-VM pick (Leo, 2026-11-23: "buttons for cloud/auto/evacuate aka move/teleport
//! is necessary. the whole moving to and from cloud requires additional gui ux. this is a big
//! deal.").
//!
//! Pure. The app runs the move it already runs (Move to Cloud and Bring Back Local: `cmux link
//! seed push`, then `cmux link agent move`), tells [`reduce`] each step as it starts, ends or
//! fails, and draws [`view`]'s answer; the webview turns its keys into words. Served over the app
//! FFI's JSON channel as ops `cloud_move_place_*` (`cmux-layout-reducer-ffi/src/cloud_move.rs`).
//!
//! The steps, in order (their names are the wire's, and what a kill-mid-move drill kills at):
//! `preflight` (the folder and its size), `machine` (the chat's own VM resumed, or a new one),
//! `sync` (the folder's bulk copy while the chat still runs), `freeze` (the chat stops taking
//! turns), `carry` (the changes made since the bulk copy, and a running turn's continuation),
//! `commit` (the far side takes the chat; from here it is there), `attach` (its tab opens at the
//! new place) and `release` (the old place's tab closes). Cancel is offered up to `sync`'s end:
//! nothing has left the old place yet. From `freeze` on the move runs out (a failure before
//! `commit` gives the chat back where it was, `cmux link agent move`'s own rule).

use serde::{Deserialize, Serialize};

/// The chat's place mode, the control's three choices.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    /// Runs on this computer, and stays.
    #[default]
    Local,
    /// Runs on its own Cloud VM.
    Cloud,
    /// Runs on this computer and moves to its own Cloud VM when [`auto`] says so.
    Auto,
}

/// Where the chat runs now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum At {
    #[default]
    Local,
    Cloud,
}

/// Which way a move goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    ToCloud,
    ToLocal,
}

/// Who started the move.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Trigger {
    /// The person's click: Cloud, Bring back, Retry.
    Person,
    /// The Auto rule, with its reason.
    Auto(AutoReason),
    /// Evacuate.
    Evacuate,
}

/// A move's steps, in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Step {
    Preflight,
    Machine,
    Sync,
    Freeze,
    Carry,
    Commit,
    Attach,
    Release,
}

impl Step {
    pub const ALL: [Step; 8] = [
        Step::Preflight,
        Step::Machine,
        Step::Sync,
        Step::Freeze,
        Step::Carry,
        Step::Commit,
        Step::Attach,
        Step::Release,
    ];

    pub fn index(self) -> usize {
        Self::ALL.iter().position(|step| *step == self).unwrap_or(0)
    }

    /// The wire name (`preflight` ... `release`).
    pub fn name(self) -> &'static str {
        match self {
            Step::Preflight => "preflight",
            Step::Machine => "machine",
            Step::Sync => "sync",
            Step::Freeze => "freeze",
            Step::Carry => "carry",
            Step::Commit => "commit",
            Step::Attach => "attach",
            Step::Release => "release",
        }
    }

    /// Whether a cancel at this step leaves the chat untouched where it was: nothing has frozen.
    pub fn cancellable(self) -> bool {
        self <= Step::Sync
    }

    /// Whether the chat is at the new place once this step is reached: from `commit`'s end. A
    /// failure at `attach` or `release` leaves it there, with a retry that only opens its tab.
    pub fn landed(self) -> bool {
        self >= Step::Attach
    }

    /// The `cmux link agent move` phase names (its output's `phases`) that belong to this step.
    pub fn agent_move_phases(self) -> &'static [&'static str] {
        match self {
            Step::Sync => &["bulk_sync"],
            Step::Freeze => &["state", "gate", "connect", "begin"],
            Step::Carry => &["frozen_sync"],
            Step::Commit => &["receive", "copy", "finish", "commit", "resolve"],
            _ => &[],
        }
    }
}

/// RFD 0058's budget for both moves, start to first reply at the new place: p95 10 s.
pub const BUDGET_MS: u64 = 10_000;

/// What the chat carries, as the app reads it before the move starts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Cargo {
    /// The chat has a turn running now.
    pub turn_running: bool,
    /// The source's agent continues a turn where the chat lands (`identify` lists
    /// `agent-transfer-continues-v1`). Without it a running turn is interrupted, and said so first.
    pub continues_turn: bool,
    /// Messages queued behind the running turn.
    pub queued: u32,
    /// An unsent draft in the composer.
    pub has_draft: bool,
    /// The worktree's branch, when the folder is a git checkout.
    pub branch: Option<String>,
    /// Files with uncommitted changes (tracked and untracked), when the folder is a git checkout.
    pub dirty_files: u32,
}

/// How one thing travels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum How {
    /// Arrives as it is.
    Carried,
    /// A running turn that goes on at the new place.
    Continues,
    /// A running turn that stops at the freeze; the chat lands between turns.
    Interrupted,
}

/// One line of "what moves".
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Carry {
    /// `history`, `queue`, `draft`, `branch`, `changes`, `turn`.
    pub kind: &'static str,
    pub how: How,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// The truthful "what moves" list: history always; the queue, draft, branch, uncommitted changes
/// and a running turn when there are any. The folder copy carries the worktree as it is on disk,
/// committed or not, so uncommitted changes are carried, never a refusal; a running turn
/// continues where the source supports it and is said to be interrupted otherwise.
pub fn carries(cargo: &Cargo) -> Vec<Carry> {
    let mut out = vec![Carry { kind: "history", how: How::Carried, count: None, name: None }];
    if cargo.turn_running {
        let how = if cargo.continues_turn { How::Continues } else { How::Interrupted };
        out.push(Carry { kind: "turn", how, count: None, name: None });
    }
    if cargo.queued > 0 {
        out.push(Carry { kind: "queue", how: How::Carried, count: Some(cargo.queued), name: None });
    }
    if cargo.has_draft {
        out.push(Carry { kind: "draft", how: How::Carried, count: None, name: None });
    }
    if let Some(branch) = cargo.branch.as_ref().filter(|b| !b.is_empty()) {
        out.push(Carry {
            kind: "branch",
            how: How::Carried,
            count: None,
            name: Some(branch.clone()),
        });
    }
    if cargo.dirty_files > 0 {
        out.push(Carry {
            kind: "changes",
            how: How::Carried,
            count: Some(cargo.dirty_files),
            name: None,
        });
    }
    out
}

/// How a move ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Outcome {
    /// The chat is live at the new place.
    Live { at_ms: u64 },
    /// It stopped at `step`. Before `attach` the chat still runs where it was; at or after it the
    /// chat is at the new place and the retry only opens its tab.
    Failed { step: Step, reason: String, at_ms: u64 },
    /// The person cancelled at `step` (always a cancellable one); the chat runs where it was.
    Cancelled { step: Step, at_ms: u64 },
}

/// One move, as the app reports it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Flow {
    pub session: String,
    pub direction: Direction,
    pub trigger: Trigger,
    /// The old place's and the new place's names, as the chat says them ("This Mac", the VM's).
    pub from: String,
    pub to: String,
    pub cargo: Cargo,
    pub started_ms: u64,
    pub step: Step,
    pub step_started_ms: u64,
    /// Each finished step's wall time.
    pub done: Vec<(Step, u64)>,
    /// A cancel the person asked for, honoured at the next step boundary when the step it was
    /// asked at was past cancelling.
    pub cancel_asked: bool,
    pub outcome: Option<Outcome>,
}

/// What the app tells [`reduce`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "event")]
pub enum Event {
    /// The move starts at `preflight`.
    Begin {
        session: String,
        direction: Direction,
        trigger: Trigger,
        from: String,
        to: String,
        #[serde(default)]
        cargo: Cargo,
        at_ms: u64,
    },
    /// The machine got its name (a new VM is named once made).
    Target { to: String },
    /// `step` started (the steps before it are done).
    Step { step: Step, at_ms: u64 },
    /// The chat is live at the new place.
    Live { at_ms: u64 },
    /// The running step failed.
    Failed { reason: String, at_ms: u64 },
    /// The person pressed Cancel.
    Cancel { at_ms: u64 },
}

/// What the app does after [`reduce`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Next {
    /// Go on with the move.
    Go,
    /// Stop the move now: the chat stays where it was (the cancel was honoured).
    Stop,
    /// Nothing to do (an event for a move that already ended, or out of order).
    Ignore,
}

/// Folds `event` into `flow` (none before `Begin`). Out-of-order events are ignored, never a
/// panic: a step may only move forward, and an ended move takes no event.
pub fn reduce(flow: Option<Flow>, event: Event) -> (Option<Flow>, Next) {
    match (flow, event) {
        (
            None | Some(Flow { outcome: Some(_), .. }),
            Event::Begin { session, direction, trigger, from, to, cargo, at_ms },
        ) => (
            Some(Flow {
                session,
                direction,
                trigger,
                from,
                to,
                cargo,
                started_ms: at_ms,
                step: Step::Preflight,
                step_started_ms: at_ms,
                done: Vec::new(),
                cancel_asked: false,
                outcome: None,
            }),
            Next::Go,
        ),
        (Some(flow), _) if flow.outcome.is_some() => (Some(flow), Next::Ignore),
        (None, _) => (None, Next::Ignore),
        // A second begin while one runs: the running move stays.
        (Some(flow), Event::Begin { .. }) => (Some(flow), Next::Ignore),
        (Some(mut flow), Event::Target { to }) => {
            flow.to = to;
            (Some(flow), Next::Go)
        }
        (Some(mut flow), Event::Step { step, at_ms }) => {
            if step <= flow.step {
                return (Some(flow), Next::Ignore);
            }
            // A cancel asked while the last step could not stop is honoured here only if the new
            // step can still stop; once frozen the move runs out.
            if flow.cancel_asked && step.cancellable() {
                flow.outcome = Some(Outcome::Cancelled { step: flow.step, at_ms });
                return (Some(flow), Next::Stop);
            }
            let took = at_ms.saturating_sub(flow.step_started_ms);
            flow.done.push((flow.step, took));
            flow.step = step;
            flow.step_started_ms = at_ms;
            (Some(flow), Next::Go)
        }
        (Some(mut flow), Event::Live { at_ms }) => {
            let took = at_ms.saturating_sub(flow.step_started_ms);
            flow.done.push((flow.step, took));
            flow.outcome = Some(Outcome::Live { at_ms });
            (Some(flow), Next::Go)
        }
        (Some(mut flow), Event::Failed { reason, at_ms }) => {
            flow.outcome = Some(Outcome::Failed { step: flow.step, reason, at_ms });
            (Some(flow), Next::Go)
        }
        (Some(mut flow), Event::Cancel { at_ms }) => {
            if flow.step.cancellable() {
                flow.outcome = Some(Outcome::Cancelled { step: flow.step, at_ms });
                (Some(flow), Next::Stop)
            } else {
                // Past cancelling: the move runs out; the view says so.
                flow.cancel_asked = true;
                (Some(flow), Next::Go)
            }
        }
    }
}

/// Where the chat runs once a move ended, or while it runs.
pub fn runs_at(flow: &Flow) -> At {
    let new = match flow.direction {
        Direction::ToCloud => At::Cloud,
        Direction::ToLocal => At::Local,
    };
    let old = match flow.direction {
        Direction::ToCloud => At::Local,
        Direction::ToLocal => At::Cloud,
    };
    match &flow.outcome {
        Some(Outcome::Live { .. }) => new,
        Some(Outcome::Failed { step, .. }) if step.landed() => new,
        Some(Outcome::Failed { .. } | Outcome::Cancelled { .. }) => old,
        None if flow.step.landed() => new,
        None => old,
    }
}

/// The move as the chat draws it: a labelled, bounded progress state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub session: String,
    pub direction: Direction,
    pub trigger: Trigger,
    pub from: String,
    pub to: String,
    /// `moving`, `live`, `failed`, `cancelled`.
    pub state: &'static str,
    /// The running step (or the one it ended at).
    pub step: Step,
    pub step_index: usize,
    pub step_count: usize,
    pub started_ms: u64,
    /// Start to now (or to the end).
    pub elapsed_ms: u64,
    /// RFD 0058's budget.
    pub budget_ms: u64,
    pub over_budget: bool,
    /// Cancel is offered now.
    pub can_cancel: bool,
    /// The person pressed Cancel past cancelling; the move is finishing.
    pub finishing: bool,
    /// Where the chat runs at this moment: the old place until it landed.
    pub runs_at: At,
    pub carries: Vec<Carry>,
    /// A running turn that will be interrupted, said before the freeze.
    pub interrupts_turn: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Retry is offered (a failure).
    pub can_retry: bool,
    /// Each finished step's time, for the report and the probe.
    pub steps: Vec<StepTime>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepTime {
    pub step: Step,
    pub ms: u64,
}

pub fn view(flow: &Flow, now_ms: u64) -> View {
    let (state, end_ms, reason) = match &flow.outcome {
        None => ("moving", now_ms, None),
        Some(Outcome::Live { at_ms }) => ("live", *at_ms, None),
        Some(Outcome::Failed { reason, at_ms, .. }) => ("failed", *at_ms, Some(reason.clone())),
        Some(Outcome::Cancelled { at_ms, .. }) => ("cancelled", *at_ms, None),
    };
    let step = match &flow.outcome {
        Some(Outcome::Failed { step, .. } | Outcome::Cancelled { step, .. }) => *step,
        _ => flow.step,
    };
    let elapsed_ms = end_ms.saturating_sub(flow.started_ms);
    let carries = carries(&flow.cargo);
    let interrupts_turn = carries.iter().any(|c| c.how == How::Interrupted);
    View {
        session: flow.session.clone(),
        direction: flow.direction,
        trigger: flow.trigger,
        from: flow.from.clone(),
        to: flow.to.clone(),
        state,
        step,
        step_index: step.index(),
        step_count: Step::ALL.len(),
        started_ms: flow.started_ms,
        elapsed_ms,
        budget_ms: BUDGET_MS,
        over_budget: elapsed_ms > BUDGET_MS,
        can_cancel: flow.outcome.is_none() && flow.step.cancellable() && !flow.cancel_asked,
        finishing: flow.outcome.is_none() && flow.cancel_asked,
        runs_at: runs_at(flow),
        carries,
        interrupts_turn,
        reason,
        can_retry: state == "failed",
        steps: flow.done.iter().map(|(step, ms)| StepTime { step: *step, ms: *ms }).collect(),
    }
}

/// Why Auto moves a chat: to Cloud (every reason but `Back`), or back to this Mac (`Back`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AutoReason {
    /// The conditions that sent it cleared ([`AutoDecision::Back`]): Auto brings it back to this Mac.
    Back,
    /// The lid closed, or the computer is about to sleep.
    Sleep,
    LowBattery,
    Memory,
    Disk,
    /// The person has been away.
    Away,
    /// A turn has run long.
    LongTurn,
}

/// The memory pressure the OS reports.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Pressure {
    #[default]
    Normal,
    Warn,
    Critical,
}

/// This computer's state, as the app reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Signals {
    /// The lid closed, or a sleep is announced (`NSWorkspace.willSleepNotification`).
    pub sleeping: bool,
    pub on_battery: bool,
    pub battery_percent: Option<u8>,
    pub memory: Pressure,
    pub disk_free_bytes: Option<u64>,
    /// Time since the person's last input on this computer.
    pub idle_ms: Option<u64>,
}

/// One chat, as Auto reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatState {
    pub at: At,
    /// Auto moved it to Cloud (so Auto may bring it back; a person's Cloud stays).
    pub moved_by_auto: bool,
    pub turn_running: bool,
    /// How long the running turn has run.
    pub turn_ms: u64,
    pub queued: u32,
    /// Time since its last turn ended.
    pub idle_ms: u64,
    /// A move of it is running.
    pub moving: bool,
}

/// The Auto rule's thresholds.
pub mod rule {
    /// At or under this battery percent, on battery.
    pub const LOW_BATTERY_PERCENT: u8 = 15;
    /// Under this much free disk.
    pub const LOW_DISK_BYTES: u64 = 5 * 1024 * 1024 * 1024;
    /// Away this long.
    pub const AWAY_MS: u64 = 10 * 60 * 1000;
    /// A turn running this long.
    pub const LONG_TURN_MS: u64 = 15 * 60 * 1000;
    /// Back only when the person is here (input within this) ...
    pub const PRESENT_MS: u64 = 60 * 1000;
    /// ... the battery is above this or charging ...
    pub const BACK_BATTERY_PERCENT: u8 = 30;
    /// ... and the chat has been idle this long.
    pub const BACK_IDLE_MS: u64 = 30 * 1000;
}

/// What Auto says to do with one chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "do")]
pub enum AutoDecision {
    Stay,
    ToCloud { reason: AutoReason },
    Back,
}

/// The first reason this computer gives to move work off it, strongest first.
pub fn pressure(signals: &Signals) -> Option<AutoReason> {
    if signals.sleeping {
        return Some(AutoReason::Sleep);
    }
    if signals.on_battery && signals.battery_percent.is_some_and(|p| p <= rule::LOW_BATTERY_PERCENT)
    {
        return Some(AutoReason::LowBattery);
    }
    if signals.memory == Pressure::Critical {
        return Some(AutoReason::Memory);
    }
    if signals.disk_free_bytes.is_some_and(|free| free < rule::LOW_DISK_BYTES) {
        return Some(AutoReason::Disk);
    }
    if signals.idle_ms.is_some_and(|idle| idle >= rule::AWAY_MS) {
        return Some(AutoReason::Away);
    }
    None
}

/// The Auto rule, the one line the control says (`placeAuto.rule`): a chat in Auto runs here; it
/// moves to its own Cloud VM while it has work (a running turn or a queue) and this computer
/// sleeps, runs low on battery, memory or disk, the person is away 10 minutes, or the turn runs 15
/// minutes; it comes back when the person is here, this computer is fine and the chat is idle.
/// An idle chat never moves: pausing loses it nothing.
pub fn auto(mode: Mode, chat: &ChatState, signals: &Signals) -> AutoDecision {
    if mode != Mode::Auto || chat.moving {
        return AutoDecision::Stay;
    }
    let has_work = chat.turn_running || chat.queued > 0;
    match chat.at {
        At::Local => {
            if !has_work {
                return AutoDecision::Stay;
            }
            if let Some(reason) = pressure(signals) {
                return AutoDecision::ToCloud { reason };
            }
            if chat.turn_running && chat.turn_ms >= rule::LONG_TURN_MS {
                return AutoDecision::ToCloud { reason: AutoReason::LongTurn };
            }
            AutoDecision::Stay
        }
        At::Cloud => {
            let present = signals.idle_ms.is_some_and(|idle| idle < rule::PRESENT_MS);
            let battery_ok = !signals.on_battery
                || signals.battery_percent.is_none_or(|p| p > rule::BACK_BATTERY_PERCENT);
            let fine = !signals.sleeping
                && battery_ok
                && signals.memory == Pressure::Normal
                && signals.disk_free_bytes.is_none_or(|free| free >= rule::LOW_DISK_BYTES);
            let idle = !has_work && chat.idle_ms >= rule::BACK_IDLE_MS;
            if chat.moved_by_auto && present && fine && idle {
                AutoDecision::Back
            } else {
                AutoDecision::Stay
            }
        }
    }
}

/// One chat Evacuate may move.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EvacuateChat {
    pub session: String,
    pub at: At,
    /// It has had a first message (a chat with none has nothing to move yet).
    pub started: bool,
    pub turn_running: bool,
    pub moving: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Skipped {
    pub session: String,
    /// `alreadyCloud`, `alreadyLocal`, `notStarted`, `moving`.
    pub reason: &'static str,
}

/// Evacuate's plan: which chats move, in what order, and how many at once.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EvacuatePlan {
    /// Each to its own VM, running turns first, then the list's order.
    pub moves: Vec<String>,
    pub skipped: Vec<Skipped>,
    /// Moves run at once (each its own VM; the copy is this computer's upload, so a few at a time).
    pub parallel: usize,
}

/// How many moves Evacuate runs at once.
pub const EVACUATE_PARALLEL: usize = 4;

/// Evacuate's plan for `chats` (only `selected` when given), to Cloud.
pub fn evacuate(chats: &[EvacuateChat], selected: Option<&[String]>) -> EvacuatePlan {
    evacuate_toward(chats, selected, Direction::ToCloud)
}

/// The plan for moving `chats` the way `direction` goes: to Cloud (Evacuate) or back to this Mac (Bring Back All).
/// Back, a chat already here is skipped as `alreadyLocal`, and a chat needs no first message to come back.
pub fn evacuate_toward(
    chats: &[EvacuateChat],
    selected: Option<&[String]>,
    direction: Direction,
) -> EvacuatePlan {
    let mut running = Vec::new();
    let mut rest = Vec::new();
    let mut skipped = Vec::new();
    for chat in chats {
        if selected.is_some_and(|picked| !picked.iter().any(|s| *s == chat.session)) {
            continue;
        }
        let reason = if chat.moving {
            Some("moving")
        } else if direction == Direction::ToCloud && chat.at == At::Cloud {
            Some("alreadyCloud")
        } else if direction == Direction::ToLocal && chat.at != At::Cloud {
            Some("alreadyLocal")
        } else if direction == Direction::ToCloud && !chat.started {
            Some("notStarted")
        } else {
            None
        };
        match reason {
            Some(reason) => skipped.push(Skipped { session: chat.session.clone(), reason }),
            None if chat.turn_running => running.push(chat.session.clone()),
            None => rest.push(chat.session.clone()),
        }
    }
    running.extend(rest);
    let parallel = EVACUATE_PARALLEL.min(running.len().max(1));
    EvacuatePlan { moves: running, skipped, parallel }
}

/// What the app read of an error from picking or making a chat's own VM (the Cloud API's answer or the account's state).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct VmError {
    /// The account is signed out.
    pub signed_out: bool,
    /// The plan does not allow another VM (a machine cap or a paid-plan refusal).
    pub plan_required: bool,
    /// The Cloud API's HTTP status, when it answered.
    pub status: Option<u16>,
    /// The Cloud API's error code, when it gave one.
    pub code: Option<String>,
}

/// Why this chat's own VM could not start, in the words' keys the app localizes: `signIn`, `planLimit`,
/// `capacity`, `offline`, or none when the cause is not known. The reason always reads "Its Cloud VM could
/// not start" first: each chat has its own VM, so it never names a shared pool.
pub fn vm_failure_cause(error: &VmError) -> Option<&'static str> {
    let code = error.code.as_deref().unwrap_or("");
    if error.signed_out || error.status == Some(401) {
        Some("signIn")
    } else if error.plan_required
        || error.status == Some(402)
        || code.contains("limit")
        || code.contains("quota")
        || code.contains("plan")
    {
        Some("planLimit")
    } else if matches!(error.status, Some(429 | 503 | 507))
        || code.contains("capacity")
        || code.contains("unavailable")
    {
        Some("capacity")
    } else if error.status.is_none() && code == "offline" {
        Some("offline")
    } else {
        None
    }
}

/// A Cloud machine as the own-VM pick reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Machine {
    pub id: String,
    /// The chats it holds now (by session).
    pub sessions: Vec<String>,
    /// Deleted, or being deleted.
    pub gone: bool,
}

/// The chat's own VM.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "do")]
pub enum OwnMachine {
    /// The VM it ran on before (paused or awake), which holds no other chat: resumed, so its
    /// folder copy is only a delta.
    Reuse { machine: String },
    /// A new VM for this chat alone.
    Create,
}

/// One VM per agent: the VM this chat used before when it is still there and holds no other
/// chat, else a new one. A shared machine is never picked.
pub fn own_machine(session: &str, before: Option<&str>, machines: &[Machine]) -> OwnMachine {
    let reusable = before
        .and_then(|id| machines.iter().find(|m| m.id == id))
        .filter(|m| !m.gone && m.sessions.iter().all(|s| s == session));
    match reusable {
        Some(machine) => OwnMachine::Reuse { machine: machine.id.clone() },
        None => OwnMachine::Create,
    }
}

#[cfg(test)]
mod tests;
