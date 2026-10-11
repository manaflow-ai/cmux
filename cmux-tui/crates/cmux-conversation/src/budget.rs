//! The agent turn budget (plans/cmux-next/home.md section 5): in one
//! conversation agents may post at most [`MAX_AGENT_TURNS`] messages after the
//! last human message, at least [`MIN_AGENT_GAP_MS`] apart, so two agents
//! cannot loop. Pure: the host passes the newest messages and the clock.

use crate::reducer::Reject;
use crate::types::{ConversationHead, Message, Part, ParticipantKind};

/// Most agent messages after the last human message.
pub const MAX_AGENT_TURNS: usize = 4;
/// Shortest gap between two agent messages, in milliseconds.
pub const MIN_AGENT_GAP_MS: u64 = 2_000;
/// How many of the newest messages the host must pass (enough to see the last
/// human message or the full budget).
pub const BUDGET_WINDOW: usize = MAX_AGENT_TURNS + 1;

/// Checks a `message.send` of `parts` by `actor`. `recent` holds the newest
/// messages of the conversation, newest first (at least [`BUDGET_WINDOW`] when
/// that many exist). Humans are never limited, and messages with no text (work
/// cards an orchestrator posts for its children) are neither limited nor counted.
pub fn check_agent_budget(
    head: &ConversationHead,
    actor: &str,
    parts: &[Part],
    recent: &[Message],
    now_ms: u64,
) -> Result<(), Reject> {
    let agent = ParticipantKind::Agent;
    let is_agent = |id: &str| head.participant(id).is_some_and(|p| p.kind == agent);
    let has_text = |parts: &[Part]| parts.iter().any(Part::counts_as_turn);
    if !is_agent(actor) || !has_text(parts) {
        return Ok(());
    }
    let mut turns = recent.iter().filter(|message| has_text(&message.parts));
    let agent_turns = turns.clone().take_while(|message| is_agent(&message.author)).count();
    if agent_turns >= MAX_AGENT_TURNS {
        return Err(Reject::AgentBudget);
    }
    // A clock that moved back (now before the last agent message) never blocks.
    let too_soon = turns
        .find(|message| is_agent(&message.author))
        .and_then(|message| parse_rfc3339_millis(&message.created_at))
        .is_some_and(|at| now_ms >= at && now_ms < at.saturating_add(MIN_AGENT_GAP_MS));
    if too_soon {
        return Err(Reject::AgentRate);
    }
    Ok(())
}

/// The O(1) loop guard over the head's counters (`agent_text_streak`,
/// `last_agent_text_at`, kept by `apply` on every text send): the same limits as
/// [`check_agent_budget`], but no row window, so text-less work cards cannot push
/// the streak out of view and two agents cannot loop. The owner uses this one;
/// the row-window check stays for the conformance corpus's local cases.
pub fn check_agent_streak(
    head: &ConversationHead,
    actor: &str,
    parts: &[Part],
    now_ms: u64,
) -> Result<(), Reject> {
    let agent = head.participant(actor).is_some_and(|p| p.kind == ParticipantKind::Agent);
    if !agent || !parts.iter().any(Part::counts_as_turn) {
        return Ok(());
    }
    if head.agent_text_streak as usize >= MAX_AGENT_TURNS {
        return Err(Reject::AgentBudget);
    }
    let too_soon = head
        .last_agent_text_at
        .as_deref()
        .and_then(parse_rfc3339_millis)
        .is_some_and(|at| now_ms >= at && now_ms < at.saturating_add(MIN_AGENT_GAP_MS));
    if too_soon {
        return Err(Reject::AgentRate);
    }
    Ok(())
}

/// Parses the owner's own timestamp format (`format_rfc3339_millis`), for
/// example `2026-10-01T12:34:56.789Z`, to Unix milliseconds.
pub fn parse_rfc3339_millis(text: &str) -> Option<u64> {
    let bytes = text.as_bytes();
    if bytes.len() != 24
        || bytes[4] != b'-'
        || bytes[10] != b'T'
        || bytes[19] != b'.'
        || bytes[23] != b'Z'
    {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<u64> { text.get(range)?.parse().ok() };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second, millis) =
        (number(11..13)?, number(14..16)?, number(17..19)?, number(20..23)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let days = days_from_civil(year, month, day)?;
    Some(((days * 86_400 + hour * 3600 + minute * 60 + second) * 1000) + millis)
}

/// Howard Hinnant's `days_from_civil` for dates on or after 1970-01-01.
fn days_from_civil(year: u64, month: u64, day: u64) -> Option<u64> {
    let year = if month <= 2 { year.checked_sub(1)? } else { year };
    let era = year / 400;
    let year_of_era = year - era * 400;
    let month_index = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    (era * 146_097 + day_of_era).checked_sub(719_468)
}
