//! A terminal's process end ends the agent hook session that still claims it (#22995).

use super::*;

/// The sidebar spun for a terminal whose agent died with it: a crash, a kill, a host lost in
/// a daemon restart. Nothing would ever report that agent's end, so the terminal's process
/// end does, through the journal and the session fence, and a resumed session starts again.
#[cfg(unix)]
#[test]
fn a_kept_terminal_whose_process_ended_has_no_working_agent() {
    const TERMINAL: &str = "0000000000004000800000000000229e";
    const INCARNATION: &str = "1000000000004000800000000000229e";
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-terminal-exit-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agent-terminal-exit", &root);
    let workspace = mux
        .create_empty_workspace(
            Some("agent-terminal-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000229e".into()),
            None,
        )
        .unwrap();
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(
            TERMINAL,
            INCARNATION,
            &workspace.key,
            TerminalOnExit::Keep,
        )
        .unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let hook = |event: &str, key: &str| {
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal.to_string()),
            serde_json::json!({"session_id":"native-1"}),
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", key).unwrap();
    };
    hook("SessionStart", "exit-1");
    hook("UserPromptSubmit", "exit-2");
    assert_eq!(mux.list_agents(Some(surface), None)[0].state, AgentState::Working);

    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGKILL,
            core_dumped: false,
        },
        exited_at_ms: 1_000,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());

    // The kept tab stays, dead, and no view lists its agent working.
    assert!(mux.with_state(|state| state.terminal_catalog.contains_key(&terminal)));
    assert!(mux.list_agents(None, Some(AgentState::Working)).is_empty());
    assert!(mux.agent_roster.lock().unwrap().roster.entries.get(terminal.as_str()).is_none());
    let projections =
        mux.workspace_registry.lock().unwrap().public_agent_projections(Some(&terminal), None).unwrap();
    assert!(projections.iter().all(|projection| projection.state != "working"), "{projections:?}");

    // A resumed session (`claude --resume`, the same id) is not fenced out.
    hook("SessionStart", "exit-3");
    hook("UserPromptSubmit", "exit-4");
    assert_eq!(mux.list_agents(None, Some(AgentState::Working)).len(), 1);

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
