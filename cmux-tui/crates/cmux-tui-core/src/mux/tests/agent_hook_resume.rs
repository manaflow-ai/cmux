//! A hook agent that waited goes back to work when its wait is answered, and a failed tool
//! call is no wait (#22995: sidebar rows of working agents showed no spinner).

use super::*;

/// The terminal's hook agent state, as the hook projector (its agent record, the
/// published projection) and the journal's roster fold (`list_agents`, `list-agents` after a
/// restart, the TUI) see it. Both must agree.
fn states(mux: &Mux, surface: SurfaceId, terminal_id: &TerminalPublicId) -> (AgentState, String) {
    let listed = mux.list_agents(Some(surface), None);
    assert_eq!(listed.len(), 1, "one agent on the terminal: {listed:?}");
    let projected = mux.agent_records.lock().unwrap()[terminal_id].state;
    assert_eq!(listed[0].state, projected, "the roster and the projector agree");
    let roster =
        mux.agent_roster.lock().unwrap().roster.entries[terminal_id.as_str()].state.clone();
    (projected, roster)
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

/// While the session's own agent waits on an approval, a parallel subagent's tool hooks (its
/// `agent_id`) do not end the wait; the waiting agent's own next tool hook does.
#[test]
fn a_subagent_tool_call_does_not_end_the_main_agent_wait() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = claude(&mux, &terminal_id);
    let blocked = (AgentState::Blocked, "blocked".to_string());

    append("SessionStart", "s-1", serde_json::json!({}));
    append("UserPromptSubmit", "s-2", serde_json::json!({"prompt": "fan out"}));
    append("PermissionRequest", "s-3", serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);

    append("PreToolUse", "s-4", serde_json::json!({"tool_name": "Read", "agent_id": "sub-1"}));
    append("PostToolUse", "s-5", serde_json::json!({"tool_name": "Read", "agent_id": "sub-1"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked, "the approval still waits");

    append("PostToolUse", "s-6", serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Working, "working".to_string()),
        "the approved tool ran"
    );

    // A subagent's own wait ends with that subagent's next tool hook, not the main agent's.
    append(
        "PermissionRequest",
        "s-7",
        serde_json::json!({"tool_name": "Edit", "agent_id": "sub-1"}),
    );
    append("PreToolUse", "s-8", serde_json::json!({"tool_name": "Grep"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    append("PostToolUse", "s-9", serde_json::json!({"tool_name": "Edit", "agent_id": "sub-1"}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Working, "working".to_string())
    );
}

/// A restart keeps whose wait it is: the hook projector restores its fences from the durable
/// projection, which keeps no wait, and takes the wait from the roster's restored fence. A
/// test mux has no terminal host after a reopen, so the waiting agent's terminal did not
/// survive the restart: the reopen then ends that session (#22995) and no row is left waiting.
#[test]
fn a_restart_keeps_whose_wait_it_is() {
    let session = "agent-wait-restart";
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-wait-restart-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let terminal_id = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    {
        let append = claude(&mux, &terminal_id);
        append("SessionStart", "w-1", serde_json::json!({}));
        append("UserPromptSubmit", "w-2", serde_json::json!({"prompt": "fan out"}));
        append("PermissionRequest", "w-3", serde_json::json!({"tool_name": "Bash"}));
    }
    mux.shutdown();
    drop(mux);

    let head = WorkspaceRegistry::open(&root, session).unwrap().session_journal_head().unwrap();
    let reopened = open_persistent_test_mux(session, &root);
    let fence = reopened.agent_hook_fences.lock().unwrap()[&terminal_id].clone();
    assert_eq!(fence.waiting_agent.as_deref(), Some(""), "the projector knows whose wait it is");
    assert_eq!(fence.waiting_tool.as_deref(), Some("bash"), "and which tool it waits on");
    assert_eq!(reopened.agent_records.lock().unwrap()[&terminal_id].state, AgentState::Blocked);
    assert!(terminal_exit_end_journaled(&reopened, head, terminal_id.as_str()));
    assert!(
        !reopened.agent_roster.lock().unwrap().roster.entries.contains_key(terminal_id.as_str()),
        "the lost terminal's waiting agent leaves the roster"
    );
    reopened.shutdown();
    drop(reopened);
    std::fs::remove_dir_all(root).unwrap();
}

/// `claude`, with the time the hook helper observed each hook (`observed_at_ms`).
fn claude_at<'a>(
    mux: &'a Mux,
    terminal_id: &TerminalPublicId,
) -> impl Fn(&str, &str, u64, Value) + 'a {
    let terminal = terminal_id.to_string();
    move |event, key, observed_at_ms, mut native| {
        native["session_id"] = serde_json::json!("claude-session-1");
        let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal),
            native,
        )
        .unwrap();
        crate::agent_hooks::stamp_agent_hook_observed_at(&mut ingress, observed_at_ms);
        mux.append_journal_ingress(&ingress, "test", key).unwrap();
    }
}

/// Claude's hooks run `async`, so the journal can take them out of order. The pre-tool hook
/// of the call that asked for approval, landing after its permission request, does not end
/// the wait; neither does another tool of a parallel batch finishing during it. The post-tool
/// hook of the approved tool, observed after the request, does.
#[test]
fn a_late_or_parallel_tool_hook_does_not_end_the_wait() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = claude_at(&mux, &terminal_id);
    let blocked = (AgentState::Blocked, "blocked".to_string());

    append("SessionStart", "o-1", 1_000, serde_json::json!({}));
    append("UserPromptSubmit", "o-2", 1_001, serde_json::json!({"prompt": "edit it"}));
    append("PermissionRequest", "o-3", 1_011, serde_json::json!({"tool_name": "Edit"}));
    append("PreToolUse", "o-4", 1_010, serde_json::json!({"tool_name": "Edit"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked, "the late pre-tool hook");
    append("PostToolUse", "o-5", 1_020, serde_json::json!({"tool_name": "Grep"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked, "a parallel tool finished");

    append("PostToolUse", "o-6", 5_000, serde_json::json!({"tool_name": "Edit"}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Working, "working".to_string()),
        "the approved tool ran"
    );

    // A denied approval runs no post-tool hook: the agent's next tool start ends the wait.
    append("PermissionRequest", "o-7", 6_000, serde_json::json!({"tool_name": "Bash"}));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    append("PreToolUse", "o-8", 9_000, serde_json::json!({"tool_name": "Read"}));
    assert_eq!(
        states(&mux, surface.id, &terminal_id),
        (AgentState::Working, "working".to_string()),
        "the agent went on after a denial"
    );
}

/// Two parallel calls of the same tool: the one that finishes does not end the approval the
/// other still waits on. Claude's permission request names no call, so the waited call's
/// input tells them apart; a question names its call in the pre-tool hook, and its answer
/// (an input that now carries the answers) ends the wait by that id.
#[test]
fn a_parallel_call_of_the_same_tool_does_not_end_the_wait() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let append = claude_at(&mux, &terminal_id);
    let working = (AgentState::Working, "working".to_string());
    let blocked = (AgentState::Blocked, "blocked".to_string());
    let bash = |id: &str, command: &str| serde_json::json!({"tool_name": "Bash", "tool_use_id": id, "tool_input": {"command": command}});

    append("SessionStart", "p-1", 1_000, serde_json::json!({}));
    append("UserPromptSubmit", "p-2", 1_001, serde_json::json!({"prompt": "run both"}));
    append("PreToolUse", "p-3", 1_010, bash("toolu_a", "make test"));
    append("PreToolUse", "p-4", 1_011, bash("toolu_b", "rm -rf build"));
    append(
        "PermissionRequest",
        "p-5",
        1_012,
        serde_json::json!({"tool_name": "Bash", "tool_input": {"command": "rm -rf build"}}),
    );
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    append("PostToolUse", "p-6", 1_500, bash("toolu_a", "make test"));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked, "the other call finished");
    append("PostToolUse", "p-7", 4_000, bash("toolu_b", "rm -rf build"));
    assert_eq!(states(&mux, surface.id, &terminal_id), working, "the approved call ran");

    let question = |id: &str, input: Value| serde_json::json!({"tool_name": "AskUserQuestion", "tool_use_id": id, "tool_input": input});
    let asked = serde_json::json!({"questions": [{"question": "Which branch?"}]});
    append("PreToolUse", "p-8", 5_000, question("toolu_q", asked.clone()));
    append(
        "PermissionRequest",
        "p-9",
        5_001,
        serde_json::json!({"tool_name": "AskUserQuestion", "tool_input": asked}),
    );
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked);
    let answered = serde_json::json!({
        "questions": [{"question": "Which branch?"}],
        "answers": {"Which branch?": "main"}
    });
    append("PostToolUse", "p-10", 8_000, question("toolu_other", answered.clone()));
    assert_eq!(states(&mux, surface.id, &terminal_id), blocked, "another question's answer");
    append("PostToolUse", "p-11", 8_001, question("toolu_q", answered));
    assert_eq!(states(&mux, surface.id, &terminal_id), working, "the question was answered");
}
