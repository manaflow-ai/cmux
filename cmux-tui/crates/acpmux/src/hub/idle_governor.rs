//! Part of `Hub`; see `hub/mod.rs`. The idle period bounded by a chat's next known event (RFD
//! 0177, "Suspend, hibernate, and cpuidle states and governors").
//!
//! A fixed idle period (`idle.rs`, 2 min) hibernated chats that were woken again minutes later: on
//! one lane VM 68 of 190 wakes came within 5 min of the hibernation. A replay of 797 idle gaps from
//! that VM's chat logs (2026-11-22 to 11-25) found that a chat's earlier gaps do not predict its
//! next one (a governor on that history, as Linux's teo does, left churn at 50%), but its next
//! known event does, as Linux's menu governor bounds an idle period by the next timer. Of the
//! wakes after gaps over 2 min, 149 were the chat's own background task ending, 55 a scheduled
//! continuation and 10 a person. So:
//!
//! - A chat with a daemon-owned background task that will bring its end to the chat
//!   (`bg_notify.rs`) stays up at least [`BG_TASK_IDLE`]: the task's notice is likely to come
//!   before a new harness would have paid off.
//! - A chat whose cut turn's continuation (`auto_resume.rs`) waits longer than [`FAR_RESUME`]
//!   sleeps after [`FAR_RESUME_IDLE`]: the continuation's prompt starts it again when due, and
//!   the harness would idle until then. One due sooner keeps it awake, as before.
//! - Anything else keeps the configured period. Pool pressure and host moves still win
//!   (`host_level.rs` `idle_period`).
//!
//! In the replay, against a fixed 2 min this cut wakes 41% (276 to 163) and wakes within 5 min of
//! hibernating 64% (135 to 48), for about 7 more idle harness-hours over 2.5 days on one VM.
//!
//! Each wake also logs what woke it ([`prompt_wake_cause`]): the `woke` line's `cause` names the
//! prompt's sender kind instead of a bare `prompt`, so production can check the replay.

use super::*;

/// The least idle period of a chat whose background task will bring its end to the chat.
pub(super) const BG_TASK_IDLE: std::time::Duration = std::time::Duration::from_secs(420);

/// A continuation due further away than this lets its chat sleep (`Hub::continuation_waits_far`).
pub(super) const FAR_RESUME: std::time::Duration = std::time::Duration::from_secs(420);

/// The idle period of a chat whose continuation is due further away than [`FAR_RESUME`].
pub(super) const FAR_RESUME_IDLE: std::time::Duration = std::time::Duration::from_secs(30);

/// A chat's next known event, as far as its idle period cares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum NextEvent {
    /// A background task runs that will bring its end to the chat.
    BgTask,
    /// Its continuation waits until further away than [`FAR_RESUME`].
    FarResume,
    /// Nothing known.
    Unknown,
}

/// The idle period for `next`, from the configured `idle`.
pub(super) fn period_for(next: NextEvent, idle: std::time::Duration) -> std::time::Duration {
    match next {
        NextEvent::BgTask => idle.max(BG_TASK_IDLE),
        NextEvent::FarResume => idle.min(FAR_RESUME_IDLE),
        NextEvent::Unknown => idle,
    }
}

/// What a prompt's start wakes its chat for, logged as the `woke` line's `cause`: `person` for the
/// person's own turn, else its provenance's kind (`prompt_provenance.rs`), `prompt` when it names
/// none this knows. A resent peer message (`waited`) is `outbox`.
pub(super) fn prompt_wake_cause(person: bool, provenance: Option<&Value>) -> &'static str {
    if person {
        return "person";
    }
    let Some(p) = provenance else { return "prompt" };
    if p.get("bgTaskId").is_some() {
        return "bg-notice";
    }
    // A peer's message the outbox held and sent again once the link came back.
    if crate::prompt_provenance::waited(provenance) {
        return "outbox";
    }
    match p.get("kind").and_then(Value::as_str) {
        Some("auto_resume") => "auto_resume",
        Some("rate_limit_parked") => "rate-hold",
        Some("notice") => "notice",
        Some("trigger") => "trigger",
        Some(
            "agent_message" | "session_message" | "subsession_message" | "task_result"
            | "offer_result" | "lane_report" | "agent_digest",
        ) => "agent-msg",
        Some("unverified") => "unverified",
        _ => "prompt",
    }
}

impl Hub {
    /// `session`'s next known event ([`NextEvent`]).
    pub(super) fn next_event(&self, session: &Session) -> NextEvent {
        if self.continuation_waits_far(session, FAR_RESUME) {
            NextEvent::FarResume
        } else if self.bg_notifying_count(session) > 0 {
            NextEvent::BgTask
        } else {
            NextEvent::Unknown
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_background_task_keeps_the_chat_up_at_least_seven_minutes() {
        assert_eq!(period_for(NextEvent::BgTask, Duration::from_secs(120)), BG_TASK_IDLE);
        // A longer configured period is kept.
        let long = Duration::from_secs(900);
        assert_eq!(period_for(NextEvent::BgTask, long), long);
    }

    #[test]
    fn a_far_continuation_sleeps_after_thirty_seconds() {
        assert_eq!(period_for(NextEvent::FarResume, Duration::from_secs(120)), FAR_RESUME_IDLE);
        // A shorter configured period is kept.
        let short = Duration::from_secs(5);
        assert_eq!(period_for(NextEvent::FarResume, short), short);
    }

    #[test]
    fn nothing_known_keeps_the_configured_period() {
        let idle = Duration::from_secs(120);
        assert_eq!(period_for(NextEvent::Unknown, idle), idle);
    }

    #[test]
    fn a_wake_names_its_sender() {
        assert_eq!(prompt_wake_cause(true, None), "person");
        assert_eq!(prompt_wake_cause(false, None), "prompt");
        let bg = json!({"kind": "notice", "bgTaskId": "t1"});
        assert_eq!(prompt_wake_cause(false, Some(&bg)), "bg-notice");
        let resume = json!({"kind": "auto_resume", "attempt": 2});
        assert_eq!(prompt_wake_cause(false, Some(&resume)), "auto_resume");
        let msg = json!({"kind": "agent_message", "from": "a"});
        assert_eq!(prompt_wake_cause(false, Some(&msg)), "agent-msg");
        let parked = json!({"kind": "rate_limit_parked"});
        assert_eq!(prompt_wake_cause(false, Some(&parked)), "rate-hold");
        let notice = json!({"kind": "notice"});
        assert_eq!(prompt_wake_cause(false, Some(&notice)), "notice");
        let resent = json!({"kind": "agent_message", "waited": true});
        assert_eq!(prompt_wake_cause(false, Some(&resent)), "outbox");
        let odd = json!({"kind": "something_new"});
        assert_eq!(prompt_wake_cause(false, Some(&odd)), "prompt");
    }
}
