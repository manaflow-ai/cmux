//! Delivery: what a message does to each recipient, and how far it has got.
//!
//! - `fyi` stores a durable note and wakes nobody.
//! - `ask` stores a question for an agent's digest and wakes nobody (ask-first, as RFD 0018).
//! - `wake` starts an agent's turn only when the agent's owner granted that space wake
//!   ([`crate::permission::wake_allowed`]); otherwise it lands in the digest as an ask, and the
//!   preview says so before send.
//!
//! A person recipient gets the message stored for them in every mode, announced as their
//! notification policy says; a message to people never wakes an agent, because only the audience is
//! routed. A bridge author's message wakes nobody.

use serde::{Deserialize, Serialize};

use crate::identity::PrincipalKind;
use crate::model::{Notify, Principal};

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum DeliveryMode {
    Fyi,
    /// The safe default.
    #[default]
    Ask,
    Wake,
}

/// What one recipient gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    /// The author themself: nothing.
    Skip,
    /// Stored in the thread; nobody is told or woken.
    Store,
    /// A person's inbox and digest.
    Inbox,
    /// A person's digest only.
    PersonDigest,
    /// Stored, announced nowhere (the person muted the space).
    Muted,
    /// An agent's digest, read at its next ordinary turn. Wakes nobody.
    AgentDigest,
    /// Start the agent's turn.
    Wake,
}

impl Route {
    pub fn wakes(self) -> bool {
        self == Self::Wake
    }
}

/// Route a message in `mode` from `author` to `recipient`. `wake_allowed` is the owner's grant for
/// this agent in this space; `notify` is the person's notification policy there.
pub fn route(
    mode: DeliveryMode,
    author: &Principal,
    recipient: &Principal,
    wake_allowed: bool,
    notify: Notify,
) -> Route {
    if author.id == recipient.id && author.kind == recipient.kind {
        return Route::Skip;
    }
    match recipient.kind {
        PrincipalKind::Person => match notify {
            Notify::Inbox => Route::Inbox,
            Notify::Digest => Route::PersonDigest,
            Notify::Muted => Route::Muted,
        },
        PrincipalKind::Agent => match mode {
            DeliveryMode::Fyi => Route::Store,
            DeliveryMode::Ask => Route::AgentDigest,
            DeliveryMode::Wake if wake_allowed && author.via.is_none() => Route::Wake,
            DeliveryMode::Wake => Route::AgentDigest,
        },
    }
}

/// How far a message has got for one recipient. The derived order is the progression; a state only
/// moves forward, so states arriving late, twice or out of order converge on the furthest one.
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(rename_all = "lowercase")]
pub enum DeliveryState {
    #[default]
    Sent,
    Stored,
    Delivered,
    Read,
    /// The recipient replied or marked it handled.
    Handled,
}

impl DeliveryState {
    /// Take `next` if it is further along. Returns whether the state changed.
    pub fn advance(&mut self, next: DeliveryState) -> bool {
        if next > *self {
            *self = next;
            true
        } else {
            false
        }
    }
}

/// How the asker judged an agent's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AnswerState {
    Accepted,
    NeedsWork,
    Blocked,
}
