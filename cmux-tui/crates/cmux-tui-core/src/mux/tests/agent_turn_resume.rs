//! A Claude turn through its tool hooks: a failed tool call keeps the agent working, an
//! answered wait resumes it, and hooks delivered out of order (Claude runs them
//! asynchronously) change nothing. The sidebar spins from this state (cmux NEXT
//! https://github.com/manaflow-ai/cmux/issues/22995).

use super::*;

/// The hook projector's state (the app's agent rows) and the roster's (`list_agents`), which
/// must agree.
fn states(mux: &Mux, terminal_id: &TerminalPublicId) -> (String, String) {
    let projected = hook_projected_agents(mux)
        .first()
        .and_then(|agent| agent["state"].as_str())
        .unwrap_or_default()
        .to_owned();
    (projected, roster_agent_state(mux, terminal_id).unwrap_or_default())
}

#[track_caller]
fn assert_state(mux: &Mux, terminal_id: &TerminalPublicId, expected: &str) {
    assert_eq!(states(mux, terminal_id), (expected.to_owned(), expected.to_owned()));
}

#[test]
fn claude_tool_hooks_keep_the_turn_state_true() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = |event: &str, observed_at_ms: u64, native: Value| {
        let mut native = native;
        native["session_id"] = serde_json::json!("claude-1");
        let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(terminal_id.as_str()),
            native,
        )
        .unwrap();
        crate::agent_hooks::stamp_agent_hook_observed_at(&mut ingress, observed_at_ms);
        let key = format!("turn-resume-{}", crate::workspace_registry::new_uuid_v4());
        mux.append_journal_ingress(&ingress, "test", &key).unwrap();
    };
    let bash = || serde_json::json!({"tool_name": "Bash", "tool_input": {"command": "cargo test"}});

    append("SessionStart", 1_000, serde_json::json!({}));
    append("UserPromptSubmit", 1_100, serde_json::json!({"prompt": "fix it"}));
    assert_state(&mux, &terminal_id, "working");

    // A failed tool call (a red test, a grep with no match) is part of the turn.
    append("PreToolUse", 1_200, bash());
    append("PostToolUseFailure", 1_300, bash());
    assert_state(&mux, &terminal_id, "working");
    assert!(mux.resource_notifications(16).is_empty(), "a failed tool call is no error report");

    // A permission request blocks the turn; the approved tool's post-tool hook resumes it.
    let edit =
        || serde_json::json!({"tool_name": "Edit", "tool_input": {"file_path": "/repo/a.rs"}});
    let grep = || serde_json::json!({"tool_name": "Grep", "tool_input": {"pattern": "x"}});
    append("PreToolUse", 1_400, edit());
    append("PermissionRequest", 1_500, edit());
    assert_state(&mux, &terminal_id, "blocked");
    // A parallel read finishing while the person decides: still waiting.
    append("PostToolUse", 1_550, grep());
    assert_state(&mux, &terminal_id, "blocked");
    // The pre-tool hook of the waiting call, delivered after its request: still waiting.
    append("PreToolUse", 1_450, edit());
    assert_state(&mux, &terminal_id, "blocked");
    append("PostToolUse", 1_600, edit());
    assert_state(&mux, &terminal_id, "working");

    // A question waits; its own post-tool hook means the person answered.
    let question = || serde_json::json!({"tool_name": "AskUserQuestion"});
    append("PreToolUse", 1_700, question());
    assert_state(&mux, &terminal_id, "blocked");
    append("PostToolUse", 1_800, question());
    assert_state(&mux, &terminal_id, "working");

    // A turn that ends while it waits (the person interrupts and Claude stops): the waited
    // tool's post-tool hook, observed before that end but delivered after it, does not start
    // the spinner again.
    append("PreToolUse", 1_900, bash());
    append("PermissionRequest", 2_000, bash());
    assert_state(&mux, &terminal_id, "blocked");
    append("Stop", 2_200, serde_json::json!({}));
    append("PostToolUse", 2_100, bash());
    assert_state(&mux, &terminal_id, "idle");
    // Nor does a stray tool hook of an idle session.
    append("PostToolUse", 2_300, bash());
    assert_state(&mux, &terminal_id, "idle");
    let mut titles: Vec<_> =
        mux.resource_notifications(16).into_iter().map(|posted| posted.title).collect();
    titles.sort();
    assert_eq!(
        titles,
        [
            "Claude asked a question",
            "Claude finished",
            "Claude needs approval",
            "Claude needs approval"
        ],
        "the waits and the turn's end notify; tool hooks never do"
    );
}

/// A wait whose projection failed (its terminal was briefly between hosts) is answered before
/// the retry: the tool hook waits behind it in the retry queue, so the projector and the
/// roster both end working, not one blocked and one working.
#[test]
fn tool_hook_waits_behind_a_failed_wait_projection() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = |event: &str, observed_at_ms: u64| {
        let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(terminal_id.as_str()),
            serde_json::json!({"session_id": "claude-1", "tool_name": "Bash"}),
        )
        .unwrap();
        crate::agent_hooks::stamp_agent_hook_observed_at(&mut ingress, observed_at_ms);
        let key = format!("failed-wait-{observed_at_ms}");
        mux.append_journal_ingress(&ingress, "test", &key).unwrap();
    };
    let pending = || {
        mux.workspace_registry
            .lock()
            .unwrap()
            .pending_agent_hook_projections_for_terminal(&terminal_id)
            .unwrap()
            .len()
    };
    append("UserPromptSubmit", 1_000);
    // The request commits while the terminal is between hosts: its projection fails.
    let host = mux.remove_terminal_catalog_for_test(&terminal_id).unwrap();
    append("PermissionRequest", 1_100);
    assert_eq!(pending(), 1);
    mux.state.lock().unwrap().insert_catalog_terminal(&terminal_id, &host).unwrap();
    // Approved before the retry ran.
    append("PostToolUse", 1_200);
    assert_eq!(pending(), 2, "the tool hook waits behind the failed request");

    mux.retry_pending_agent_hooks_for_terminal(&terminal_id).unwrap();
    assert_eq!(pending(), 0);
    assert_state(&mux, &terminal_id, "working");
}
