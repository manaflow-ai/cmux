//! The lease: `POST /:id/lease`, and the `{holder, epoch}` that fences every other write.

use serde::{Deserialize, Serialize};

use super::{Holder, MoveTo, SessionView};

/// What the store made of a renewal. A renewal is answered a role, never `auto.stale_epoch`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// The chat is the caller's, at the epoch in the answer's `session`. To a renewal that is
    /// not a standby's: go on as you are. To a standby's renewal: the chat was given to this
    /// laptop, which imports the Cloud copy first.
    Holder,
    /// Another holder runs it; the caller is remembered as a laptop to hand it back to, for a
    /// lease's length from this renewal.
    Standby,
    /// What the caller runs is not the chat any more: stop it, then renew as standby. A machine
    /// whose chat went home to a laptop is answered this too.
    Lost,
}

impl Role {
    pub const ALL: [Role; 3] = [Role::Holder, Role::Standby, Role::Lost];

    pub fn as_str(self) -> &'static str {
        match self {
            Role::Holder => "holder",
            Role::Standby => "standby",
            Role::Lost => "lost",
        }
    }
}

/// `POST /:id/lease`: renew as the holder, or as a laptop standing by.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseRequest {
    pub holder: Holder,
    /// The epoch the caller last knew. The laptop whose lease ran straight into `parked` takes
    /// its chat back as it is by renewing with the epoch it held.
    pub epoch: u64,
    /// A turn runs, a prompt is queued or a background task is at work. When a laptop's lease
    /// runs out, this (or an unacked inbox message) decides between a takeover and parking. A
    /// machine that says `false` with everything acked and copied gives the chat home.
    pub needs_run: bool,
    /// A laptop that is online and not the holder renews with `true`. A standby's renewal also
    /// takes a parked chat, unless the chat is kept in the Cloud.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standby: Option<bool>,
}

/// The lease's answer. `session.epoch` is the epoch to write under from now on.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseAnswer {
    pub session: SessionView,
    pub role: Role,
    /// How long the lease lasts from this renewal.
    pub lease_ms: u64,
    /// `move`: the person asked to move the chat, and the caller holds it. The holder stops its
    /// agent, stores its last events and a snapshot that covers them, then calls `give`. None
    /// when nobody asked, and always None to a standby or a holder that lost the chat.
    #[serde(rename = "move", default, skip_serializing_if = "Option::is_none")]
    pub move_to: Option<MoveTo>,
}

/// `{holder, epoch}`: the writer's holder and epoch. `release` and `assignment/ack` send only
/// this; every other holder write carries the same two fields.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fence {
    pub holder: Holder,
    pub epoch: u64,
}

impl Fence {
    pub fn new(holder: Holder, epoch: u64) -> Fence {
        Fence { holder, epoch }
    }
}
