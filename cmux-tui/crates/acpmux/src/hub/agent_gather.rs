//! Part of `Hub`; see `digest.rs`. An idle chat's agent message waits for the ones after it.
//!
//! Agents that come close together go in together, busy or not: another agent's message that
//! would start a turn in an idle chat waits [`AGENT_GATHER_MS`] from its arrival, in the queue
//! (its `queued` record is written first, so a crash loses nothing and a restart runs it at
//! once), and the agent messages that come meanwhile queue behind it and join its turn
//! (`digest.rs` `take_joined`). It is the inbox's burst window (`inbox.rs` `WAKE_DEBOUNCE_MS`) applied to the
//! messages the inbox does not take (`inbox::plain_send` false: every cross-host message a
//! peer daemon or the mesh relay forwards, team messages, supersede sends, and the prompts
//! acpmux makes: lane reports, task cards, background-task cards), which each started a turn
//! at once. Leo, 2026-11-21: "i feel like if we measure per timestamp, we can group up quite
//! a few messages together, though i do know that steers and queued messages often come turn
//! by turn anyways, i just also feel like we may not even need to rely on that and just
//! say... ok it gets grouped up together". One lane VM over 24 h: 1,552 agent messages cost
//! 1,144 agent-started turns. The person's prompt never waits for the window: it does not
//! count the waiting message, starts at once, and that message's turn follows it. What would
//! not join a turn (`take_joined`) does not wait either, nor a blocker (a block or a question,
//! `prompt_class.rs`), nor a chat's first work (`inbox.rs` `first_work`), nor a chat that
//! never ran a turn ([`gathers`]).

use super::super::*;
use super::inbox_digest;

/// How long another agent's message that would start a turn in an idle chat waits, from its
/// arrival, for the agent messages that come right after it (module docs): the inbox's burst
/// window (`inbox.rs` `WAKE_DEBOUNCE_MS`). Not longer without Leo's say.
pub(in crate::hub) const AGENT_GATHER_MS: u64 = super::super::inbox::WAKE_DEBOUNCE_MS;

/// Whether the prompt `p`, about to start a turn in an idle chat, waits [`AGENT_GATHER_MS`] for
/// the agent messages after it (module docs): another agent's message that could lead a turn
/// others join (`take_joined`), no blocker, in a chat that ran a turn, that is not its first work.
pub(in crate::hub) fn gathers(session: &Session, p: &super::super::queue::Slot<'_>) -> bool {
    use crate::prompt_class::PromptClass;
    p.agent.is_some()
        && !p.no_queue
        // A steer its turn ended before reading, or a prompt let in again: it waited already.
        && !p.admitted
        && !p.after_turn
        && !p.interrupt
        && !p.steer_on_start
        && !matches!(p.class, Some(PromptClass::Block | PromptClass::Question))
        && !crate::prompt_provenance::is_trigger(p.provenance)
        && super::super::forum::slash_command(p.blocks).is_none()
        && !crate::prompt_uploads::any(p.blocks)
        && !super::super::subsession_guard::is_family_prompt(p.provenance)
        && !inbox_digest::is_digest(p.provenance)
        && !super::super::goal_tools::is_continuation(p.provenance)
        && !super::super::inbox::is_first_work(p.provenance)
        && !super::super::inbox::review_box(session)
        && session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_count > 0
}

/// The turn id of the agent message whose gather window is open in `session` (`gathers`): it
/// waits in the queue, and the person's prompt does not count it.
pub(in crate::hub) fn open_gather(session: &Session) -> Option<String> {
    let (turn_id, until) = session.gathering.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
    if tokio::time::Instant::now() >= until {
        return None;
    }
    let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    queue.iter().any(|q| q.turn_id == turn_id && !q.aside()).then_some(turn_id)
}

/// When the gather window of the queued prompt `turn_id` ends, while it is open; else ends it.
pub(in crate::hub) fn gather_until(
    session: &Session,
    turn_id: &str,
) -> Option<tokio::time::Instant> {
    let mut gathering = session.gathering.lock().unwrap_or_else(|e| e.into_inner());
    match gathering.as_ref() {
        Some((t, until)) if t == turn_id => {
            if tokio::time::Instant::now() < *until {
                return Some(*until);
            }
            *gathering = None;
            None
        }
        _ => None,
    }
}

/// Ends the gather window of `turn_id`, if it holds one.
pub(in crate::hub) fn end_gather(session: &Session, turn_id: &str) {
    let mut gathering = session.gathering.lock().unwrap_or_else(|e| e.into_inner());
    if gathering.as_ref().is_some_and(|(t, _)| t == turn_id) {
        *gathering = None;
    }
}
