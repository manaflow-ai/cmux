//! What the daemon does after a step.

use serde::{Deserialize, Serialize};

use super::ImportReason;
use crate::wire::Blocked;

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
    /// `POST /:id/release` at `epoch`. Answer: `Released`, also when the store says the chat is
    /// no longer this machine's; nothing when it did not answer (the next tick sends it again).
    Release { epoch: u64 },
    /// `PUT /:id` with `auto: false`. Answer: `Closed` once the store closed the chat. Nothing
    /// when it refused (`auto.held_in_cloud`: a machine holds the chat) or did not answer: the
    /// chat stays an Auto chat and the daemon tells the person why.
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
    /// its manifest, after its events. Answer: `SnapshotStored { copy, .. }` or
    /// `SnapshotFailed { copy, .. }`. A newer copy may replace one still on its way.
    UploadSnapshot { epoch: u64, copy: u64 },
    /// Read the inbox, give its messages to the chat (each id once), and ack them.
    DrainInbox,
    /// Bring the chat's Cloud copy in as a local session at `epoch`. Answer:
    /// `ImportDone { epoch, .. }` or `ImportFailed { epoch }`.
    Import { reason: ImportReason, epoch: u64 },
    /// `POST /:id/assignment/ack` at `epoch`: the import is done. Machine only.
    AckAssignment { epoch: u64 },
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
            Effect::Release { .. } => "release",
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
            Effect::ShowBlocked { .. } => "show_blocked",
            Effect::ScheduleAt { .. } => "schedule_at",
        }
    }

    /// The name with the data the table shows: `renew(standby)`, `import(handback)`,
    /// `show_blocked(offline)`.
    pub fn label(&self) -> String {
        let detail = match self {
            Effect::Renew { standby: true, .. } => "standby",
            Effect::Renew { needs_run: true, .. } => "needs_run",
            Effect::Import { reason, .. } => reason.as_str(),
            Effect::ShowBlocked { blocked: Some(blocked) } => blocked.as_str(),
            Effect::ShowBlocked { blocked: None } => "none",
            Effect::Register { .. }
            | Effect::Renew { .. }
            | Effect::Release { .. }
            | Effect::Close
            | Effect::StopTree
            | Effect::ContinueTree
            | Effect::KillTree
            | Effect::WriteLeftoverPatch
            | Effect::UploadEvents { .. }
            | Effect::UploadSnapshot { .. }
            | Effect::DrainInbox
            | Effect::AckAssignment { .. }
            | Effect::ScheduleAt { .. } => return self.kind().to_owned(),
        };
        format!("{}({detail})", self.kind())
    }
}
