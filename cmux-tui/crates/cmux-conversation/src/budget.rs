//! The agent turn budget (plans/cmux-next/home.md section 5): in one
//! conversation agents may post at most [`MAX_AGENT_TURNS`] messages after the
//! last human message, at least [`MIN_AGENT_GAP_MS`] apart, so two agents
//! cannot loop. Pure: the host passes the newest messages and the clock.

use crate::reducer::Reject;
use crate::types::{ConversationHead, Message, ParticipantKind};

/// Most agent messages after the last human message.
pub const MAX_AGENT_TURNS: usize = 4;
/// Shortest gap between two agent messages, in milliseconds.
pub const MIN_AGENT_GAP_MS: u64 = 2_000;
/// How many of the newest messages the host must pass (enough to see the last
/// human message or the full budget).
pub const BUDGET_WINDOW: usize = MAX_AGENT_TURNS + 1;

/// Checks a `message.send` by `actor`. `recent` holds the newest messages of the
/// conversation, newest first (at least [`BUDGET_WINDOW`] when that many exist).
/// Humans are never limited.
pub fn check_agent_budget(
    head: &ConversationHead,
    actor: &str,
    recent: &[Message],
    now_ms: u64,
) -> Result<(), Reject> {
    let agent = ParticipantKind::Agent;
    let is_agent = |id: &str| head.participant(id).is_some_and(|p| p.kind == agent);
    if !is_agent(actor) {
        return Ok(());
    }
    let agent_turns = recent.iter().take_while(|message| is_agent(&message.author)).count();
    if agent_turns >= MAX_AGENT_TURNS {
        return Err(Reject::AgentBudget);
    }
    let too_soon = recent
        .iter()
        .find(|message| is_agent(&message.author))
        .and_then(|message| parse_rfc3339_millis(&message.created_at))
        .is_some_and(|at| now_ms < at.saturating_add(MIN_AGENT_GAP_MS));
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format_rfc3339_millis;
    use crate::types::{Part, Participant};

    fn head() -> ConversationHead {
        let participant = |id: &str, kind| Participant {
            id: id.to_string(),
            kind,
            display_name: id.to_string(),
            agent_class: None,
            acp_session: None,
        };
        ConversationHead {
            id: "conv_1".to_string(),
            title: "t".to_string(),
            participants: vec![
                participant("user_local", ParticipantKind::Human),
                participant("agent_mux", ParticipantKind::Agent),
                participant("agent_other", ParticipantKind::Agent),
            ],
            last_seq: 0,
            rev: 1,
            created_at: format_rfc3339_millis(0),
            updated_at: format_rfc3339_millis(0),
            read_cursors: Default::default(),
        }
    }

    fn message(seq: u64, author: &str, at_ms: u64) -> Message {
        Message {
            id: format!("msg_{seq}"),
            conversation: "conv_1".to_string(),
            seq,
            client_msg_id: format!("c{seq}"),
            author: author.to_string(),
            parts: vec![Part::Text { text: "x".to_string(), runs: None }],
            reply_to: None,
            created_at: format_rfc3339_millis(at_ms),
            edited_at: None,
            retracted_at: None,
            reactions: Vec::new(),
        }
    }

    #[test]
    fn conversation_budget_timestamps_round_trip() {
        for ms in [0, 1, 999, 86_399_999, 1_790_000_000_123, 4_102_444_800_000] {
            assert_eq!(parse_rfc3339_millis(&format_rfc3339_millis(ms)), Some(ms));
        }
        assert_eq!(parse_rfc3339_millis("2026-10-01 12:00:00.000Z"), None);
        assert_eq!(parse_rfc3339_millis("garbage"), None);
    }

    #[test]
    fn conversation_budget_limits_agents_not_humans() {
        let head = head();
        let base = 1_790_000_000_000;
        let mut newest_first = vec![message(1, "user_local", base)];
        for turn in 0..MAX_AGENT_TURNS {
            let at = base + 10_000 * (turn as u64 + 1);
            assert_eq!(check_agent_budget(&head, "agent_mux", &newest_first, at), Ok(()));
            let author = if turn % 2 == 0 { "agent_mux" } else { "agent_other" };
            newest_first.insert(0, message(turn as u64 + 2, author, at));
        }
        let later = base + 1_000_000;
        assert_eq!(
            check_agent_budget(&head, "agent_mux", &newest_first, later),
            Err(Reject::AgentBudget)
        );
        assert_eq!(check_agent_budget(&head, "user_local", &newest_first, later), Ok(()));
        newest_first.insert(0, message(10, "user_local", later));
        assert_eq!(check_agent_budget(&head, "agent_mux", &newest_first, later + 1), Ok(()));
    }

    #[test]
    fn conversation_budget_enforces_the_gap() {
        let head = head();
        let base = 1_790_000_000_000;
        let recent = vec![message(2, "agent_mux", base), message(1, "user_local", base - 5_000)];
        let early = base + MIN_AGENT_GAP_MS - 1;
        assert_eq!(
            check_agent_budget(&head, "agent_other", &recent, early),
            Err(Reject::AgentRate)
        );
        let on_time = base + MIN_AGENT_GAP_MS;
        assert_eq!(check_agent_budget(&head, "agent_other", &recent, on_time), Ok(()));
    }
}
