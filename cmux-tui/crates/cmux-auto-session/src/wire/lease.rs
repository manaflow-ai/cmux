//! The lease: `POST /:id/lease`, and the `{holder, epoch}` that fences every other write.

use serde::{Deserialize, Serialize};

use super::{Holder, SessionView};

/// What the store made of a renewal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// The caller holds the chat, at the epoch in the answer's `session`.
    Holder,
    /// Another holder runs it; the caller is listed as a laptop to hand it back to.
    Standby,
    /// The caller held it and no longer does.
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
    /// The epoch the caller last knew.
    pub epoch: u64,
    /// A turn runs, a prompt is queued or a background task is at work. When the lease runs
    /// out, this decides between a takeover and parking.
    pub needs_run: bool,
    /// A laptop that is online and not the holder renews with `true`.
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
