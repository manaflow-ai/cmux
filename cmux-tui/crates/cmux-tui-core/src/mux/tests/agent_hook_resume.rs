//! A hook agent that waited goes back to work when its wait is answered, and a failed tool
//! call is no wait (#22995: sidebar rows of working agents showed no spinner).

use super::*;

/// The terminal's hook agent state, as the hook projector (`list_agents`, the app's rows)
/// and the journal's roster fold (`list-agents` after restart, the TUI) both see it.
fn states(mux: &Mux, surface: SurfaceId, terminal_id: &TerminalPublicId) -> (AgentState, String) {
    let listed = mux.list_agents(Some(surface), None);
    assert_eq!(listed.len(), 1, "one agent on the terminal: {listed:?}");
    let roster =
        mux.agent_roster.lock().unwrap().roster.entries[terminal_id.as_str()].state.clone();
    (listed[0].state, roster)
}

fn claude<'a>(mux: &'a Mux, terminal_id: &TerminalPublicId) -> impl Fn(&str, &str, Value) + 'a {
    let terminal = terminal_id.to_string();
    move |event, key, mut native| {
        native["session_id"] = serde_json::json!("claude-session-1");
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal),
            native,
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", key).unwrap();
    }
}

/// An approval, a question and a plan review each wait; the next tool hook of the same
/// turn (the tool the person approved or answered) is work again, then the turn ends idle.
#[test]
fn an_answered_wait_shows_the_agent_working_again() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = claude(&mux, &terminal_id);
    let working = (AgentState::Working, "working".to_string());
    let blocked = (AgentState::Blocked, "blocked".to_string());

    append("SessionStart", "r-1", serde_json::json!({}));
    append("UserPromptSubmit", "r-2", serde_json::json!({"prompt": "ship it"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), working);

    append("PermissionRequest", "r-3", serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    append("PostToolUse", "r-4", serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), working, "the approved tool ran");

    append("PreToolUse", "r-5", serde_json::json!({"tool_name": "AskUserQuestion"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    append("PostToolUse", "r-6", serde_json::json!({"tool_name": "AskUserQuestion"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), working, "the question was answered");

    append("PreToolUse", "r-7", serde_json::json!({"tool_name": "ExitPlanMode"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    append("PostToolUse", "r-8", serde_json::json!({"tool_name": "ExitPlanMode"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), working, "the plan was approved");

    append("PermissionRequest", "r-9", serde_json::json!({"tool_name": "Edit"}));
    append("PreToolUse", "r-10", serde_json::json!({"tool_name": "Read"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), working, "another tool runs");

    append("Stop", "r-11", serde_json::json!({}));
    assert_eq!(states(&mux, surface.id, &terminal_id), (AgentState::Idle, "idle".to_string()));
    append("PostToolUse", "r-12", serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Idle, "idle".to_string()),
        "a tool hook never starts a turn"
    );
}

/// A failed tool call (a red test run, a missing file) is a result the agent works on: it
/// stays working and posts no error notification. A failed turn still waits.
#[test]
fn a_failed_tool_call_keeps_the_agent_working() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = claude(&mux, &terminal_id);

    append("SessionStart", "f-1", serde_json::json!({}));
    append("UserPromptSubmit", "f-2", serde_json::json!({"prompt": "run the tests"}));
    append("PreToolUse", "f-3", serde_json::json!({"tool_name": "Bash"}));
    append("PostToolUseFailure", "f-4", serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Working, "working".to_string())
    );
    assert!(mux.resource_notifications(16).is_empty(), "a failed tool call needs no attention");

    append("StopFailure", "f-5", serde_json::json!({}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Blocked, "blocked".to_string())
    );
}
