use super::{QuestionIdentity, QuestionReply, QuestionReplyPrompt, ReplyError, ResolvedChoice};
use crate::Question;

/// Caller-owned observation facts. These are not person authentication.
/// The connector must identify its emitted messages by stored IDs/watermarks;
/// `is_from_me` alone cannot distinguish the owner's self-thread from Chief.
#[derive(Debug, Clone, Copy)]
pub struct ReplyEnvelope {
    pub is_from_me: bool,
    pub confirmed_self_thread: bool,
    pub emitted_by_chief: bool,
    pub sent_at_ms: Option<i64>,
    /// Associated-message type from Messages. A removal (3000+) cannot answer.
    pub associated_message_type: Option<i64>,
}

/// The owner picks the window when it delivers the question, not on each reply.
#[derive(Debug, Clone, Copy)]
pub struct ReplyWindow {
    pub offered_at_ms: i64,
    pub expires_at_ms: i64,
}

#[derive(Debug, Clone, Copy)]
pub struct ObservedReply<'a> {
    pub thread: &'a str,
    pub reply: QuestionReply<'a>,
    pub envelope: ReplyEnvelope,
    pub window: ReplyWindow,
    pub now_ms: i64,
}

impl QuestionReplyPrompt {
    /// Connector entry point: reject echoed, undated, old, future or removed
    /// events before interpreting them. The adapter still authenticates sender,
    /// binds tapback targets, and atomically revalidates the question on commit.
    pub fn resolve_observed(
        &self,
        current_identity: &QuestionIdentity,
        current: Option<&Question>,
        event: ObservedReply<'_>,
    ) -> Result<ResolvedChoice, ReplyError> {
        let ObservedReply { thread, reply, envelope: observation, window, now_ms } = event;
        if thread != self.thread {
            return Err(ReplyError::WrongThread);
        }
        if observation.emitted_by_chief
            || (observation.is_from_me && !observation.confirmed_self_thread)
        {
            return Err(ReplyError::Echo);
        }
        let sent = observation.sent_at_ms.ok_or(ReplyError::Stale)?;
        if window.expires_at_ms <= window.offered_at_ms
            || sent < window.offered_at_ms
            || sent > now_ms
            || now_ms >= window.expires_at_ms
        {
            return Err(ReplyError::Stale);
        }
        if observation.associated_message_type.is_some_and(|kind| kind >= 3000) {
            return Err(ReplyError::RemovedTapback);
        }
        // Associated-message events must be parsed as a tapback; never process
        // a Messages-generated reaction summary ("Liked …") as ordinary text.
        if observation.associated_message_type.is_some_and(|kind| kind != 0)
            && !matches!(reply, QuestionReply::Tapback { .. })
        {
            return Err(ReplyError::UnboundTapback);
        }
        self.resolve(current_identity, current, thread, reply)
    }
}
