//! The answer of a turn that took steers (E19, 2026-10-09).
//!
//! codex-acp folds a steered `session/prompt` into the running turn and, at
//! the turn's end, answers only the last prompt it got: the turn's own
//! prompt and the earlier steers never get an answer, so their callers (the
//! Chief's turn) waited forever. A steer whose answer ends the turn (any
//! stop reason but Claude Code's `steered`, which it gives when it read the
//! steer and the turn runs on) answers every other prompt of that turn with
//! the same answer. Claude Code's steers are answered `steered` and change
//! nothing here.

use super::*;

/// Whether an agent's answer to a steer says that the turn ended.
fn ends_turn(answer: &Value) -> bool {
    answer
        .get("stopReason")
        .and_then(Value::as_str)
        .is_some_and(|reason| reason != "steered")
}

/// The agent's `session/prompt` for a prompt of turn `turn_id` (its own, or
/// a `steer` into it): the agent's answer, or the answer of a steer that
/// ended this turn first.
pub(super) async fn agent_prompt(
    session: &Session,
    child: &ChildAgent,
    params: Value,
    turn_id: &str,
    steer: bool,
) -> Result<Value, RpcError> {
    let mut ended = session.steer_end.subscribe();
    let request = child.request(method::SESSION_PROMPT, params);
    tokio::pin!(request);
    loop {
        tokio::select! {
            answer = &mut request => {
                if steer
                    && let Ok(value) = &answer
                    && ends_turn(value)
                {
                    session.steer_end.send_replace(Some((turn_id.to_owned(), value.clone())));
                }
                return answer;
            }
            changed = ended.changed() => {
                if changed.is_err() {
                    return request.await;
                }
                let by_steer = ended.borrow_and_update().clone();
                if let Some((turn, answer)) = by_steer
                    && turn == turn_id
                {
                    return Ok(answer);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_stop_reason_other_than_steered_ends_the_turn() {
        assert!(ends_turn(&json!({"stopReason": "end_turn"})));
        assert!(ends_turn(&json!({"stopReason": "cancelled"})));
        assert!(!ends_turn(&json!({"stopReason": "steered"})));
        assert!(!ends_turn(&json!({})));
    }
}
