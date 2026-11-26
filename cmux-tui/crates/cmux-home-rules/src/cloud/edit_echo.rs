//! `CloudHomeSource+EditEcho`: the subscription an edit made outside a
//! transcript is kept until the edit's echo arrives or a deadline passes.
//! Swift keeps the timer (`DemandTimer`) and `endEditSubscription`; this is
//! the hold's state machine.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// `CloudHomeSource.editEchoDeadline`.
pub const DEADLINE_MS: u64 = 30_000;

/// One conversation's hold (`CloudHomeState.EditHold`, without its timer).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hold {
    #[serde(default)]
    pub in_flight: u64,
    #[serde(default)]
    pub awaited: Option<u64>,
    #[serde(default)]
    pub seen: u64,
}

/// The edit-echo part of `CloudHomeState`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Holds {
    #[serde(default)]
    pub generation: u64,
    #[serde(default)]
    pub holds: BTreeMap<String, Hold>,
    /// Conversations a transcript shows (they keep their own subscription).
    #[serde(default)]
    pub viewed: BTreeSet<String>,
}

/// An event of the holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    /// `beginEdit`.
    Begin { conversation: String, generation: u64 },
    /// `finishEdit`: the op answered at `committedAt`, or was refused
    /// (`final`: never resent).
    #[serde(rename_all = "camelCase")]
    Finish {
        conversation: String,
        generation: u64,
        #[serde(default)]
        committed_at: Option<u64>,
        #[serde(default)]
        r#final: bool,
    },
    /// `echoed`: a conversation event at `rev`.
    Echoed { conversation: String, rev: u64 },
    /// The hold's deadline passed.
    Deadline { conversation: String, generation: u64 },
}

/// What Swift does after an event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Effect {
    /// Cancel the hold's deadline (a new edit began).
    CancelDeadline { conversation: String },
    /// Arm the deadline (`afterMs`).
    #[serde(rename_all = "camelCase")]
    ScheduleDeadline { conversation: String, after_ms: u64 },
    /// `endEditSubscription`: the hold is gone; end the subscription
    /// unless a transcript shows it.
    EndSubscription { conversation: String },
}

/// One step of the holds.
pub fn step(mut state: Holds, event: Event) -> (Holds, Vec<Effect>) {
    let mut effects = Vec::new();
    match event {
        Event::Begin { conversation, generation } => {
            if state.generation == generation {
                let hold = state.holds.entry(conversation.clone()).or_default();
                hold.in_flight = hold.in_flight.saturating_add(1);
                effects.push(Effect::CancelDeadline { conversation });
            }
        }
        Event::Finish { conversation, generation, committed_at, r#final } => {
            if state.generation != generation {
                return (state, effects);
            }
            let Some(hold) = state.holds.get_mut(&conversation) else {
                return (state, effects);
            };
            hold.in_flight = hold.in_flight.saturating_sub(1);
            if let Some(rev) = committed_at {
                hold.awaited = Some(hold.awaited.unwrap_or(0).max(rev));
            }
            let hold = *hold;
            if hold.in_flight != 0 {
                return (state, effects);
            }
            if state.viewed.contains(&conversation) {
                state.holds.remove(&conversation);
                return (state, effects);
            }
            let echoed = hold.awaited.map_or(r#final, |awaited| hold.seen >= awaited);
            if echoed {
                state.holds.remove(&conversation);
                effects.push(Effect::EndSubscription { conversation });
            } else {
                effects.push(Effect::ScheduleDeadline { conversation, after_ms: DEADLINE_MS });
            }
        }
        Event::Echoed { conversation, rev } => {
            let Some(hold) = state.holds.get_mut(&conversation) else {
                return (state, effects);
            };
            hold.seen = hold.seen.max(rev);
            let done = hold.in_flight == 0 && hold.awaited.is_some_and(|a| hold.seen >= a);
            if done {
                state.holds.remove(&conversation);
                effects.push(Effect::EndSubscription { conversation });
            }
        }
        Event::Deadline { conversation, generation } => {
            let idle = state.holds.get(&conversation).is_some_and(|h| h.in_flight == 0);
            if state.generation == generation && idle {
                state.holds.remove(&conversation);
                effects.push(Effect::EndSubscription { conversation });
            }
        }
    }
    (state, effects)
}

/// `echo_step`'s request.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepRequest {
    #[serde(default)]
    pub state: Holds,
    pub event: Event,
}

/// `echo_step`'s reply.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StepReply {
    pub state: Holds,
    pub effects: Vec<Effect>,
}
