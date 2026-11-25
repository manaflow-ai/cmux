//! What the daemon does after a step.

use serde::{Deserialize, Serialize};

use super::{ImportReason, MoveTo};
use crate::wire::Blocked;

/// Why a holder does not give the chat the person moved.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Declined {
    /// The chat is past the size cap: it cannot be copied, so it cannot change hands.
    TooLarge,
    /// The store refused to take the chat and named why (no laptop stands by, no machine to
    /// be found).
    Refused,
    /// The turn that runs here did not stop.
    Stuck,
}

impl Declined {
    pub fn as_str(self) -> &'static str {
        match self {
            Declined::TooLarge => "too_large",
            Declined::Refused => "refused",
            Declined::Stuck => "stuck",
        }
    }
}

/// One thing for the daemon to do. Plain data: the daemon runs a step's effects in order and
/// sends what comes of them back as events.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case", rename_all_fields = "camelCase")]
pub enum Effect {
    /// `PUT /:id` with `auto: true`. Answer: `Event::from_registration(request, ..)`.
    Register { request: u64 },
    /// `POST /:id/lease` with this machine's holder and these fields. Answer:
    /// `Event::from_renewal(request, ..)`.
    Renew { request: u64, epoch: u64, needs_run: bool, standby: bool },
    /// `PUT /:id` with `auto: false`. Answer: `Closed` once the store closed the chat. Nothing
    /// when it refused (`auto.held_in_cloud`: the Cloud has something no laptop has) or did not
    /// answer: the chat stays an Auto chat and the daemon tells the person why.
    Close,
    /// SIGSTOP the chat's whole process tree, detached tool shells included.
    StopTree,
    /// SIGCONT the tree a `StopTree` stopped.
    ContinueTree,
    /// SIGKILL the chat's whole process tree, detached tool shells included. The chat's
    /// transcript and folder stay.
    KillTree,
    /// Write the folder's changes since the last snapshot the store acknowledged as a leftover
    /// patch beside the chat. It is never merged silently.
    WriteLeftoverPatch,
    /// Append the log records the store does not have yet, under `epoch`.
    UploadEvents { epoch: u64 },
    /// Take a snapshot of the chat as it is now and send it under `epoch`: its chunks, then
    /// its manifest, after its events (the store counts a snapshot as covering only the events
    /// it has). Answer: `SnapshotStored { copy, .. }` or `SnapshotFailed { copy, .. }`. A newer
    /// copy may replace one still on its way.
    UploadSnapshot { epoch: u64, copy: u64 },
    /// Read the inbox, give its messages to the chat (each id once), and ack them. Then send
    /// `Changed` (a queue change) with the chat's work as it is now, so the messages are in
    /// the next copy.
    DrainInbox,
    /// Bring the chat's Cloud copy in as a local session at `epoch`. Answer:
    /// `ImportDone { epoch, .. }` or `ImportFailed { epoch }`.
    Import { reason: ImportReason, epoch: u64 },
    /// `POST /:id/assignment/ack` at `epoch`: this machine picked up what it was given. It
    /// follows the drain, because the store keeps a `deliver` while a message is unread.
    /// Machine only.
    AckAssignment { epoch: u64 },
    /// The person moved the chat: stop the turn that runs here now, the way a move by hand
    /// interrupts one. Its continuation is queued first, in the log, so it runs where the chat
    /// lands. Nothing else of the chat starts here meanwhile. Answer: `TurnStopped`, also when
    /// no turn ran.
    StopTurn,
    /// `POST /:id/give` at `epoch`: hand the chat to where the person wants it. It follows the
    /// copy that covers the chat's last event. Answer: `Event::from_give(..)`.
    Give { epoch: u64 },
    /// A give did not happen and the chat goes on here: a continuation `StopTurn` queued runs
    /// here, told that the chat did not move.
    Stay,
    /// Tell the person the chat was not moved `to` where they asked, and why. It goes out once
    /// for a wish: the same wish is not acted on again while the store still tells it.
    NotMoved { to: MoveTo, why: Declined },
    /// Show this on the chat's row (`autoSession.blocked`), or clear it with None.
    ShowBlocked { blocked: Option<Blocked> },
    /// Send `Tick` at this time (epoch ms). It replaces any earlier schedule for the chat.
    ScheduleAt { at: u64 },
}

impl Effect {
    /// The effect's name, without its data.
    pub fn kind(&self) -> &'static str {
        match self {
            Effect::Register { .. } => "register",
            Effect::Renew { .. } => "renew",
            Effect::Close => "close",
            Effect::StopTree => "stop_tree",
            Effect::ContinueTree => "continue_tree",
            Effect::KillTree => "kill_tree",
            Effect::WriteLeftoverPatch => "write_leftover_patch",
            Effect::UploadEvents { .. } => "upload_events",
            Effect::UploadSnapshot { .. } => "upload_snapshot",
            Effect::DrainInbox => "drain_inbox",
            Effect::Import { .. } => "import",
            Effect::AckAssignment { .. } => "ack_assignment",
            Effect::StopTurn => "stop_turn",
            Effect::Give { .. } => "give",
            Effect::Stay => "stay",
            Effect::NotMoved { .. } => "not_moved",
            Effect::ShowBlocked { .. } => "show_blocked",
            Effect::ScheduleAt { .. } => "schedule_at",
        }
    }

    /// The name with the data the table shows: `renew(standby)`, `import(handback)`,
    /// `show_blocked(offline)`, `not_moved(too_large)`.
    pub fn label(&self) -> String {
        let detail = match self {
            Effect::Renew { standby: true, .. } => "standby",
            Effect::Renew { needs_run: true, .. } => "needs_run",
            Effect::Import { reason, .. } => reason.as_str(),
            Effect::NotMoved { why, .. } => why.as_str(),
            Effect::ShowBlocked { blocked: Some(blocked) } => blocked.as_str(),
            Effect::ShowBlocked { blocked: None } => "none",
            Effect::Register { .. }
            | Effect::Renew { .. }
            | Effect::Close
            | Effect::StopTree
            | Effect::ContinueTree
            | Effect::KillTree
            | Effect::WriteLeftoverPatch
            | Effect::UploadEvents { .. }
            | Effect::UploadSnapshot { .. }
            | Effect::DrainInbox
            | Effect::AckAssignment { .. }
            | Effect::StopTurn
            | Effect::Give { .. }
            | Effect::Stay
            | Effect::ScheduleAt { .. } => return self.kind().to_owned(),
        };
        format!("{}({detail})", self.kind())
    }
}
