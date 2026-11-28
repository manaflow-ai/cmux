//! How a hub status and a wait read each other (moved from `hub/mod.rs` as is).

use super::{NotWaiting, SessionStatus, WaitReason, is_question};
use serde_json::Value;

impl From<NotWaiting> for SessionStatus {
    fn from(s: NotWaiting) -> Self {
        match s {
            NotWaiting::Idle => Self::Idle,
            NotWaiting::Ready => Self::Ready,
            NotWaiting::Running => Self::Running,
            NotWaiting::Disconnected => Self::Disconnected,
            NotWaiting::Closed => Self::Closed,
        }
    }
}

impl NotWaiting {
    /// `status` as one [`Hub::set_status`] writes; None for Waiting.
    pub(crate) fn of(status: SessionStatus) -> Option<Self> {
        Some(match status {
            SessionStatus::Idle => Self::Idle,
            SessionStatus::Ready => Self::Ready,
            SessionStatus::Running => Self::Running,
            SessionStatus::Disconnected => Self::Disconnected,
            SessionStatus::Closed => Self::Closed,
            SessionStatus::Waiting => return None,
        })
    }
}

impl WaitReason {
    /// What a chat asked `request` (a permission request) waits for: a question when it carries
    /// one, else a permission.
    pub(crate) fn of_request(request: &Value) -> Self {
        if is_question(request) { Self::Question } else { Self::Permission }
    }
}
