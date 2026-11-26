use super::*;

/// A newer page's field never refuses a verb: it is dropped unread. A redirecting name
/// (a session id, a cwd, ...) is still a bad request.
#[test]
fn an_unknown_param_is_ignored_and_a_redirect_is_refused() {
    let parsed = AgentSessionCommand::parse(
        "agent-session-typing",
        json!({"surface": 7, "on": true, "from_a_newer_page": {"x": 1}}),
    );
    assert!(matches!(parsed, Some(AgentSessionCommand::Typing(TypingParams { on: true, .. }))));
    let prompt = AgentSessionCommand::parse(
        "agent-session-prompt",
        json!({"surface": 7, "prompt_id": "p1", "text": "hi", "initialize": {"v": 2}}),
    );
    assert!(matches!(prompt, Some(AgentSessionCommand::Prompt(_))));
    for redirect in REDIRECT_PARAMS {
        let mut params = json!({"surface": 7, "on": true});
        params[*redirect] = json!("other");
        assert!(
            AgentSessionCommand::parse("agent-session-typing", params).is_none(),
            "{redirect} must stay a bad request"
        );
    }
}
