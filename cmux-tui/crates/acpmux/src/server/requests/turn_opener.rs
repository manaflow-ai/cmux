//! The prompt that opened the turn an attach page starts inside (`_acpmux/attach`'s
//! `turnOpener`). A capped page of a long turn holds none of the turn's prompt; read with the page
//! here, the pane opening the chat shows what the turn was asked without a round trip of its own
//! after the attach (its `fetchTurnOpener`, which an older acpmux still leaves it).

use super::*;

/// The user messages read back before the page: steers into the turn are user messages too, and
/// the opener is the newest that is not one. The pane's own read asks the same.
const PROMPTS_READ: usize = 16;

/// The opener as an `_acpmux/event` value, `None` when the page needs none (it starts a turn, or
/// holds the log from its start) or the read back finds none.
pub(super) fn turn_opener(
    hub: &Hub,
    session_id: &str,
    page: &crate::hub::EventPage,
) -> Option<Value> {
    if !page.has_more {
        return None;
    }
    let first = page.events.first()?;
    if first.seq <= 1 || starts_turn(first) {
        return None;
    }
    let filter = crate::hub::EventFilter::parse(Some(&json!(["user_message"]))).ok()?;
    let prompts = hub
        .events_page(
            session_id,
            0,
            Some(first.seq),
            PROMPTS_READ,
            Some(crate::hub::page_bytes(&Value::Null)),
            true,
            &filter,
        )
        .ok()?;
    let opener = prompts.events.into_iter().rev().find(starts_turn)?;
    Some(into_event_value(session_id, opener))
}

/// A prompt that starts a turn: acpmux's own `user_message`, not a steer into a running turn.
fn starts_turn(rec: &crate::store::EventRecord) -> bool {
    rec.dir == "mux"
        && rec.kind == "user_message"
        && rec.msg.get("steer") != Some(&Value::Bool(true))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(seq: u64, kind: &str, msg: Value) -> crate::store::EventRecord {
        crate::store::EventRecord {
            seq,
            at: 0,
            dir: "mux".into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        }
    }

    #[test]
    fn a_steer_does_not_start_a_turn() {
        assert!(starts_turn(&rec(3, "user_message", json!({"text": "go"}))));
        assert!(!starts_turn(&rec(4, "user_message", json!({"text": "also", "steer": true}))));
        assert!(!starts_turn(&rec(5, "turn_result", json!({}))));
        let mut agent = rec(6, "user_message", json!({}));
        agent.dir = "in".into();
        assert!(!starts_turn(&agent));
    }
}
