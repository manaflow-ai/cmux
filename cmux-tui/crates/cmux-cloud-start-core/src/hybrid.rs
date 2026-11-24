//! A hybrid chat's start: the chat answers here at once while its Cloud machine boots, then goes
//! on there (Leo, 2026-11-23: "we don't have to wait for cloud machines to be up and running
//! before we start a model ... start them all in parallel, in tandem"; "decouple the creation of
//! computers, the cloud, the setup"). Pure, as the start's sequencer is ([`crate::sequence`]): the
//! caller sends the state, one event and its monotonic clock in milliseconds; this answers the
//! next state and the effects to run, in order.
//!
//! What it decides:
//! - who gets it ([`enabled`]): everybody on a Pro plan, unless the server's flag says otherwise;
//! - one writer at a time: the chat's home is here until the machine holds the chat and the move
//!   committed, and there after. A prompt goes to the home; one sent while the chat moves is held
//!   and delivered once, to wherever the move left the chat ([`Effect::Deliver`]), so no turn is
//!   lost or doubled;
//! - the handoff point: with no turn running, at once; with a turn running, at its next tool
//!   boundary (a tool call ending) or its end, never in the middle of the model's answer and never
//!   under a running tool. The move itself is acpmux's session move at a tool boundary;
//! - what a failed machine or a failed move means: the chat stays here and says why; a move that
//!   may be tried again is, at the next boundary, at most [`MOVE_TRIES`] times;
//! - what the person sees ([`Cloud`]): booting, ready, moving, live or failed, each with its time;
//! - the machine nobody uses: one whose chat stayed here is paused ([`Effect::PauseMachine`]).
//!
//! Every wait here ends on an event (the machine's ready, a tool call's end, the move's commit),
//! never on a clock. Served over the app FFI's JSON channel as ops `cloud_hybrid_*`.

use serde::{Deserialize, Serialize};

/// What every time line starts with, as the start's own lines do ([`crate::sequence::PREFIX`]).
pub const PREFIX: &str = "hybrid start step: ";

/// How many times a start tries the move before the chat stays here.
pub const MOVE_TRIES: u8 = 3;

/// The plans a hybrid start is on for: every Cloud grant at Pro rank or above, as `cloud.plan.get`
/// (the team's grant, read from its billing owner) names them. The ranks are the platform's
/// (`backend/apps/api/src/cloud-vm-plan.ts:192`): `{ go: 1, next_plus: 1, pro: 2, founders: 2,
/// team: 2, next_pro: 2, max: 3, next_max: 3 }`; the entry plans (`next_intro`, `next_taste`) rank
/// 0. A teammate on a Team subscription reads as `team`.
pub const PLANS: &[&str] = &["pro", "founders", "team", "next_pro", "max", "next_max"];

/// The reason of a chat the person kept here.
pub const STOPPED: &str = "stopped";

/// Why a start is not hybrid.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Off {
    /// Cloud is off by policy, or nobody is signed in: the Cloud start's own refusal says which.
    NoCloud,
    /// The server's flag turned it off for this account.
    Flag,
    /// The plan is not Pro.
    Plan,
    /// This machine's acpmux cannot start the chat's agent (no Claude Code or Codex here, or not
    /// the one the start names), or could not be asked: the chat could not run here meanwhile.
    NoLocalHarness,
}

/// What the caller knows of the account.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Account {
    /// The plan's id (`cloud.plan.get`'s `id`: `next_plus`, `next_pro`, `next_max`), when its state
    /// is active.
    pub plan: Option<String>,
    /// The server's flag for this account, when it answered one: `false` turns hybrid starts off
    /// for a Pro account, `true` on for any plan (a teammate's account before its plan is set).
    pub flag: Option<bool>,
    pub cloud_disabled: bool,
    pub signed_in: bool,
}

/// Whether a Cloud start of this account is hybrid: on for everybody on a Pro plan (Leo,
/// 2026-11-23: "just on for everybody on a pro plan, essentially like my teammates"). `Err` says
/// why not; the start is then the Cloud start as it was.
pub fn enabled(account: &Account) -> Result<(), Off> {
    if account.cloud_disabled || !account.signed_in {
        return Err(Off::NoCloud);
    }
    match account.flag {
        Some(true) => Ok(()),
        Some(false) => Err(Off::Flag),
        None if account.plan.as_deref().is_some_and(|plan| PLANS.contains(&plan)) => Ok(()),
        None => Err(Off::Plan),
    }
}

/// Where the chat's one writer is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Home {
    #[default]
    Here,
    Cloud,
}

/// The machine's side of the chat, as the person sees it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Cloud {
    /// No hybrid start began.
    #[default]
    None,
    /// The machine is being made or set up; the chat runs here.
    Booting,
    /// The machine is up; the chat moves at its turn's next tool boundary or end.
    Ready,
    /// The move is under way; a prompt sent now is held.
    Moving,
    /// The chat runs on the machine.
    Live,
    /// The machine or the move failed; the chat stays here.
    Failed,
}

/// The turn running here, as the caller's events told it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Turn {
    #[default]
    Idle,
    /// The model answers; no tool call is open.
    Running,
    /// At least one tool call is open.
    InTool,
}

/// The start's state: the caller keeps it between calls and sends it with each event.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    pub home: Home,
    pub cloud: Cloud,
    /// When `cloud` last changed.
    pub since: u64,
    /// When the start began: every time line counts from it.
    pub began: u64,
    pub turn: Turn,
    /// How many tool calls are open.
    pub open_tools: u32,
    /// Moves begun so far.
    pub tries: u8,
    /// Prompts held while the chat moves, oldest first, by the caller's ids.
    pub held: Vec<String>,
    /// Why `cloud` is [`Cloud::Failed`], in the caller's word.
    pub reason: Option<String>,
    /// The person chose to keep the chat here, or closed it: no move begins.
    pub stopped: bool,
}

/// One thing that happened, as the caller tells it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "on", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    /// A hybrid start begins; one under way ignores it.
    Begin,
    /// The person sent prompt `id`.
    Prompt {
        id: String,
    },
    TurnStarted,
    ToolStarted,
    /// A tool call ended: with none open, a tool boundary.
    ToolEnded,
    TurnEnded,
    /// The machine is up, set up and linked: the chat can move to it.
    MachineReady,
    /// The machine could not be made or set up.
    MachineFailed {
        reason: String,
    },
    /// The move committed: the machine holds the chat and is its writer.
    MoveCommitted,
    /// The move failed and the chat is still whole here. `again`: trying it again may work.
    MoveFailed {
        reason: String,
        #[serde(default)]
        again: bool,
    },
    /// The person keeps the chat here (or closed it).
    Stop,
}

/// What the caller does next.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Start the chat here, now.
    StartHere,
    /// Make and set up the machine, beside the chat; tell [`Event::MachineReady`] or
    /// [`Event::MachineFailed`].
    CreateMachine,
    /// Move the chat to the machine, cut at a tool boundary; tell [`Event::MoveCommitted`] or
    /// [`Event::MoveFailed`].
    Move,
    /// Send prompt `id` to the chat's writer at `to`.
    Deliver { id: String, to: Home },
    /// Keep prompt `id` until the move ends; a [`Effect::Deliver`] follows.
    Hold { id: String },
    /// The machine is not this chat's: pause it.
    PauseMachine,
    /// Show the machine's side of the chat.
    Show {
        cloud: Cloud,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// One line for the Cloud log.
    Log { line: String },
}

/// The next state and the effects to run, in order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Answer {
    pub state: State,
    pub effects: Vec<Effect>,
}

/// `hybrid start step: NAME MS ms`: whole milliseconds since the start began, a name only.
fn line(name: &str, state: &State, now: u64) -> Effect {
    Effect::Log { line: format!("{PREFIX}{name} {} ms", now.saturating_sub(state.began)) }
}

fn show(state: &mut State, cloud: Cloud, now: u64, effects: &mut Vec<Effect>) {
    (state.cloud, state.since) = (cloud, now);
    effects.push(Effect::Show { cloud, reason: state.reason.clone() });
}

/// Begins the move when the machine is ready and the turn is at a boundary: idle, or between
/// tool calls after one ended (`boundary`). A turn only answering goes on to its end.
fn move_if_due(state: &mut State, boundary: bool, now: u64, effects: &mut Vec<Effect>) {
    let due = state.cloud == Cloud::Ready
        && !state.stopped
        && (state.turn == Turn::Idle || (boundary && state.turn == Turn::Running));
    if due {
        state.tries += 1;
        effects.push(line("move-begin", state, now));
        effects.push(Effect::Move);
        show(state, Cloud::Moving, now, effects);
    }
}

/// Every held prompt, oldest first, to the chat's writer.
fn release(state: &mut State, effects: &mut Vec<Effect>) {
    let to = state.home;
    effects.extend(state.held.drain(..).map(|id| Effect::Deliver { id, to }));
}

/// The chat stays here for `reason`; a machine that came up is paused.
fn stay(state: &mut State, reason: String, pause: bool, now: u64, effects: &mut Vec<Effect>) {
    state.reason = Some(reason);
    effects.push(line("stays-here", state, now));
    show(state, Cloud::Failed, now, effects);
    if pause {
        effects.push(Effect::PauseMachine);
    }
    release(state, effects);
}

/// One event at `now` (the caller's monotonic clock, in milliseconds).
pub fn step(mut state: State, event: Event, now: u64) -> Answer {
    let mut effects = Vec::new();
    match event {
        Event::Begin => {
            if state.cloud == Cloud::None {
                state.began = now;
                effects.extend([Effect::StartHere, Effect::CreateMachine]);
                show(&mut state, Cloud::Booting, now, &mut effects);
            }
        }
        Event::Prompt { id } => {
            if state.cloud == Cloud::Moving {
                state.held.push(id.clone());
                effects.push(Effect::Hold { id });
            } else {
                effects.push(Effect::Deliver { id, to: state.home });
            }
        }
        Event::TurnStarted => {
            if state.home == Home::Here && state.cloud != Cloud::Moving {
                state.turn = Turn::Running;
            }
        }
        Event::ToolStarted => {
            if state.home == Home::Here && state.turn != Turn::Idle {
                state.open_tools += 1;
                state.turn = Turn::InTool;
            }
        }
        Event::ToolEnded => {
            if state.turn == Turn::InTool {
                state.open_tools = state.open_tools.saturating_sub(1);
                if state.open_tools == 0 {
                    state.turn = Turn::Running;
                    move_if_due(&mut state, true, now, &mut effects);
                }
            }
        }
        Event::TurnEnded => {
            (state.turn, state.open_tools) = (Turn::Idle, 0);
            move_if_due(&mut state, true, now, &mut effects);
        }
        Event::MachineReady => {
            if state.cloud == Cloud::Booting {
                effects.push(line("machine-ready", &state, now));
                if state.stopped {
                    stay(&mut state, STOPPED.to_owned(), true, now, &mut effects);
                } else {
                    show(&mut state, Cloud::Ready, now, &mut effects);
                    move_if_due(&mut state, false, now, &mut effects);
                }
            }
        }
        Event::MachineFailed { reason } => {
            if state.cloud == Cloud::Booting {
                stay(&mut state, reason, false, now, &mut effects);
            }
        }
        Event::MoveCommitted => {
            if state.cloud == Cloud::Moving {
                state.home = Home::Cloud;
                (state.turn, state.open_tools) = (Turn::Idle, 0);
                effects.push(line("live", &state, now));
                show(&mut state, Cloud::Live, now, &mut effects);
                release(&mut state, &mut effects);
            }
        }
        Event::MoveFailed { reason, again } => {
            if state.cloud == Cloud::Moving {
                if again && state.tries < MOVE_TRIES && !state.stopped {
                    effects.push(line("move-again", &state, now));
                    show(&mut state, Cloud::Ready, now, &mut effects);
                    // A held prompt starts a turn here; the move waits for its boundary.
                    if state.held.is_empty() {
                        move_if_due(&mut state, false, now, &mut effects);
                    } else {
                        release(&mut state, &mut effects);
                    }
                } else {
                    stay(&mut state, reason, true, now, &mut effects);
                }
            }
        }
        Event::Stop => {
            if !state.stopped && state.home == Home::Here {
                state.stopped = true;
                if state.cloud == Cloud::Ready {
                    stay(&mut state, STOPPED.to_owned(), true, now, &mut effects);
                }
            }
        }
    }
    Answer { state, effects }
}

#[cfg(test)]
mod tests;
