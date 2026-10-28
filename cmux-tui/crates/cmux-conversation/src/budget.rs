//! The agent turn budget (plans/cmux-next/home.md section 5): in one thread
//! (the replies of one root, or the conversation's top level) agents may post
//! at most [`MAX_AGENT_TURNS`] text messages after the last person's text in
//! that thread, and agent text messages are at least [`MIN_AGENT_GAP_MS`]
//! apart in the conversation, so agents (Chiefs) cannot loop. Agents in two
//! threads do not spend each other's budget; only a person's text (or a
//! person's question answer) resets one. Pure: the host passes the head or the
//! newest messages and the clock. Same rule as home-core `budget.ts`.
//!
//! The first round after a person's text is free of the gap: while a thread's
//! streak is below the number of agents in the conversation, every agent may
//! answer the person at once (two Chiefs answer in parallel, not one gap
//! apart). After that round agent texts are spaced again, so an agent-to-agent
//! exchange still waits the gap and stops at the turn budget.

use crate::reducer::Reject;
use crate::types::{ConversationHead, Message, Part, Participant, ParticipantKind};

/// Most agent text messages in one thread after its last person's text.
pub const MAX_AGENT_TURNS: usize = 6;
/// Shortest gap between two agent messages, in milliseconds.
pub const MIN_AGENT_GAP_MS: u64 = 2_000;
/// How many of the newest messages of the thread the host must pass (enough
/// to see the last person's text or the full budget).
pub const BUDGET_WINDOW: usize = MAX_AGENT_TURNS + 1;

/// The agents in the conversation: how many answers the gap lets through
/// after a person's text (a local head drops a participant who leaves).
pub fn agent_count(participants: &[Participant]) -> usize {
    participants.iter().filter(|p| p.kind == ParticipantKind::Agent).count()
}

/// Whether `message` is in thread `thread_root` (None: the top level).
pub fn in_thread(message: &Message, thread_root: Option<&str>) -> bool {
    message.thread_root.as_deref() == thread_root
}

/// The agent text streak of thread `thread_root` from rows: agent text
/// messages at the end of that thread, after its last person's text.
/// `messages` newest first; other threads' messages are skipped;
/// `participants` say who is an agent. The same
/// count the head keeps ([`streak_of`]), for a host or a page that holds
/// messages, not the head ("Chiefs paused" when it is at the budget).
pub fn thread_agent_streak(
    participants: &[Participant],
    messages: &[Message],
    thread_root: Option<&str>,
) -> usize {
    let kind = |id: &str| participants.iter().find(|p| p.id == id).map(|p| p.kind);
    let mut count = 0;
    for m in messages
        .iter()
        .filter(|m| in_thread(m, thread_root) && m.parts.iter().any(Part::counts_as_turn))
    {
        // Only a person's text ends the streak; an author who left is
        // skipped (the head counted it at send time; a row count only falls
        // short).
        match kind(&m.author) {
            Some(ParticipantKind::Human) => break,
            Some(ParticipantKind::Agent) => count += 1,
            _ => {}
        }
    }
    count
}

/// The head's agent text streak of thread `thread_root` (None: the top level).
pub fn streak_of(head: &ConversationHead, thread_root: Option<&str>) -> u32 {
    match thread_root {
        None => head.agent_text_streak,
        Some(root) => head.thread_agent_streaks.get(root).copied().unwrap_or(0),
    }
}

/// One text turn in thread `thread_root` on `head`: an agent's adds 1 to that
/// thread's streak (from `seed` when given) and sets `last_agent_text_at`; a
/// person's resets that thread's streak only. A thread entry at 0 is dropped.
pub fn with_turn(
    head: &mut ConversationHead,
    thread_root: Option<&str>,
    agent: bool,
    now: &str,
    seed: Option<u32>,
) {
    let value = if agent {
        seed.unwrap_or_else(|| streak_of(head, thread_root)).saturating_add(1)
    } else {
        0
    };
    if agent {
        head.last_agent_text_at = Some(now.to_string());
    }
    match thread_root {
        None => head.agent_text_streak = value,
        Some(root) if value == 0 => {
            head.thread_agent_streaks.remove(root);
        }
        Some(root) => {
            head.thread_agent_streaks.insert(root.to_string(), value);
        }
    }
}

/// Checks a `message.send` of `parts` by `actor` into thread `thread_root`.
/// `recent` holds the newest messages of the conversation, newest first (at
/// least [`BUDGET_WINDOW`] of that thread when that many exist). Humans are
/// never limited, and messages with no text (work cards an orchestrator posts
/// for its children) are neither limited nor counted.
pub fn check_agent_budget(
    head: &ConversationHead,
    actor: &str,
    parts: &[Part],
    recent: &[Message],
    now_ms: u64,
    thread_root: Option<&str>,
) -> Result<(), Reject> {
    let agent = ParticipantKind::Agent;
    let is_agent = |id: &str| head.participant(id).is_some_and(|p| p.kind == agent);
    let has_text = |parts: &[Part]| parts.iter().any(Part::counts_as_turn);
    if !is_agent(actor) || !has_text(parts) {
        return Ok(());
    }
    let streak = thread_agent_streak(&head.participants, recent, thread_root);
    if streak >= MAX_AGENT_TURNS {
        return Err(Reject::AgentBudget);
    }
    if streak < agent_count(&head.participants) {
        return Ok(());
    }
    // A clock that moved back (now before the last agent message) never blocks.
    let too_soon = recent
        .iter()
        .filter(|message| has_text(&message.parts))
        .find(|message| is_agent(&message.author))
        .and_then(|message| parse_rfc3339_millis(&message.created_at))
        .is_some_and(|at| now_ms >= at && now_ms < at.saturating_add(MIN_AGENT_GAP_MS));
    if too_soon {
        return Err(Reject::AgentRate);
    }
    Ok(())
}

/// The O(1) loop guard over the head's counters (`agent_text_streak` for the
/// top level, `thread_agent_streaks` per thread, `last_agent_text_at`, kept by
/// `apply` on every text send): the same limits as [`check_agent_budget`], but
/// no row window, so text-less work cards cannot push the streak out of view.
/// The owner uses this one; the row-window check stays for hosts and pages.
pub fn check_agent_streak(
    head: &ConversationHead,
    actor: &str,
    parts: &[Part],
    now_ms: u64,
    thread_root: Option<&str>,
) -> Result<(), Reject> {
    let agent = head.participant(actor).is_some_and(|p| p.kind == ParticipantKind::Agent);
    if !agent || !parts.iter().any(Part::counts_as_turn) {
        return Ok(());
    }
    let streak = streak_of(head, thread_root) as usize;
    if streak >= MAX_AGENT_TURNS {
        return Err(Reject::AgentBudget);
    }
    if streak < agent_count(&head.participants) {
        return Ok(());
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
