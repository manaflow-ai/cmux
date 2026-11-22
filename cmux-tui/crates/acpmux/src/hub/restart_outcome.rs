//! What recovery did with a turn a daemon restart cut, shown in its conversation (teardown row
//! 14): one next action, and the detail behind it. The recovery engine (`restart_resume.rs`,
//! `log_load.rs`, `hosts.rs`) decides as before; this only names its decision on the cut turn's
//! `turn_result` (`restartOutcome`), so the session's `lastTurn` carries it until the next turn
//! ends.
//!
//! - `resumed`: its continuation is queued (`continuationPromptId`). Queued is not delivered: a
//!   client says it is delivered only once a turn with that prompt id has started.
//! - `waiting_for_user`: nothing goes on by itself; the person sends again (`send_again`), or
//!   first inspects what a trigger's turn did (`review_then_send`).
//! - `unable_to_resume`: no continuation (`why`); the person retries (`retry`).
//!
//! It never resubmits anything, and never says a tool still runs: `unfinishedTools` are the
//! tool calls the log saw start and never finish, whose outcome is unknown.
use crate::protocol::session::{RestartNextAction, RestartOutcome, RestartOutcomeState};
use serde_json::Value;

/// The outcome of a cut turn whose continuation [`super::Hub::log_continuation_outcome`]
/// queued, or did not (`why`).
pub(super) fn after_continuation(
    continued: Result<&super::auto_resume::Continued, &str>,
) -> RestartOutcome {
    match continued {
        Ok(c) => RestartOutcome {
            state: RestartOutcomeState::Resumed,
            next_action: RestartNextAction::None,
            why: None,
            continuation_prompt_id: Some(c.prompt_id.clone()),
            unfinished_tools: c.unfinished_tools.clone(),
            tools_omitted: c.tools_omitted,
        },
        Err(why) => unable(why),
    }
}

/// The person acts next: `why` says why nothing goes on by itself.
pub(super) fn waiting(why: &str, next_action: RestartNextAction) -> RestartOutcome {
    RestartOutcome {
        state: RestartOutcomeState::WaitingForUser,
        next_action,
        why: Some(why.to_owned()),
        continuation_prompt_id: None,
        unfinished_tools: Vec::new(),
        tools_omitted: false,
    }
}

fn unable(why: &str) -> RestartOutcome {
    // A Stop the person gave, or continuations they turned off: they send again themselves.
    let next_action = match why {
        "stopped" | "auto_resume_off" => RestartNextAction::SendAgain,
        _ => RestartNextAction::Retry,
    };
    RestartOutcome {
        state: RestartOutcomeState::UnableToResume,
        next_action,
        why: Some(why.to_owned()),
        continuation_prompt_id: None,
        unfinished_tools: Vec::new(),
        tools_omitted: false,
    }
}

/// `outcome` on a cut turn's `turn_result` message.
pub(super) fn mark(result: &mut Value, outcome: &RestartOutcome) {
    if let (Some(fields), Ok(v)) = (result.as_object_mut(), serde_json::to_value(outcome)) {
        fields.insert("restartOutcome".into(), v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_queued_continuation_is_resumed_with_no_action_and_names_unfinished_tools() {
        let c = super::super::auto_resume::Continued {
            prompt_id: "p~resume-1".into(),
            unfinished_tools: vec!["Bash".into()],
            tools_omitted: false,
        };
        let o = serde_json::to_value(after_continuation(Ok(&c))).unwrap();
        assert_eq!(
            o,
            json!({"state": "resumed", "nextAction": "none", "continuationPromptId": "p~resume-1", "unfinishedTools": ["Bash"]})
        );
    }

    #[test]
    fn no_continuation_is_unable_to_resume_with_one_next_action() {
        let o = serde_json::to_value(after_continuation(Err("attempts_exhausted"))).unwrap();
        assert_eq!(
            o,
            json!({"state": "unable_to_resume", "nextAction": "retry", "why": "attempts_exhausted"})
        );
        let off = after_continuation(Err("auto_resume_off"));
        assert_eq!(off.next_action, RestartNextAction::SendAgain);
        let mut result = json!({"status": "failed"});
        mark(&mut result, &waiting("trigger", RestartNextAction::ReviewThenSend));
        assert_eq!(result["restartOutcome"]["state"], "waiting_for_user");
        assert_eq!(result["restartOutcome"]["nextAction"], "review_then_send");
    }
}
