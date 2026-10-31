//! A terminal's process end ends the agent hook session that still claims it (#22995).

use super::*;
use crate::terminal_end::TerminalEnd;

const INCARNATION: &str = "1000000000004000800000000000229e";

/// The sidebar spun for a terminal whose agent died with it: a crash, a kill, a host lost in
/// a daemon restart. Nothing would ever report that agent's end, so the terminal's process
/// end does, through the journal and the session fence. The session stays resumable, and a
/// resumed session (`claude --resume`, the same id) works again.
#[cfg(unix)]
fn assert_terminal_end_ends_its_working_agent(
    case: &str,
    on_exit: TerminalOnExit,
    end: impl FnOnce(&Mux, &str, TerminalExit),
) {
    const TERMINAL: &str = "0000000000004000800000000000229e";
    let root = std::env::temp_dir().join(format!(
        "cmux-agent-terminal-exit-{case}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux("agent-terminal-exit", &root);
    let workspace = mux
        .create_empty_workspace(
            Some("agent-terminal-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000229e".into()),
            None,
        )
        .unwrap();
    let surface = mux
        .seed_running_terminal_with_on_exit_for_test(TERMINAL, INCARNATION, &workspace.key, on_exit)
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
    assert_eq!(mux.list_agents(Some(surface), None)[0].state, AgentState::Working, "{case}");
    let relaunch_agent = || {
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_relaunch_record(TERMINAL)
            .unwrap()
            .and_then(|record| record.agent)
    };
    let resumable = relaunch_agent();

    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGKILL,
            core_dumped: false,
        },
        exited_at_ms: 1_000,
    };
    end(&mux, TERMINAL, exit);

    // The tab stays, dead, and no view lists its agent working.
    assert!(mux.list_agents(None, Some(AgentState::Working)).is_empty(), "{case}");
    assert!(
        !mux.agent_roster.lock().unwrap().roster.entries.contains_key(terminal.as_str()),
        "{case}"
    );
    let projections = mux
        .workspace_registry
        .lock()
        .unwrap()
        .public_agent_projections(Some(&terminal), None)
        .unwrap();
    assert!(
        projections.iter().all(|projection| projection.state != "working"),
        "{case}: {projections:?}"
    );
    // The lost session stays resumable ("Resume Agents After Restart").
    assert_eq!(relaunch_agent(), resumable, "{case}");

    // A resumed session (`claude --resume`, the same id) is not fenced out.
    hook("SessionStart", "exit-3");
    hook("UserPromptSubmit", "exit-4");
    let working = mux.list_agents(None, Some(AgentState::Working));
    assert_eq!(working.len(), 1, "{case}: {working:?}");
    assert_eq!(working[0].terminal_id, terminal, "{case}");

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn a_kept_terminal_whose_process_ended_has_no_working_agent() {
    assert_terminal_end_ends_its_working_agent("kept", TerminalOnExit::Keep, |mux, _, exit| {
        let terminal = mux
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id("0000000000004000800000000000229e")
            .unwrap()
            .unwrap();
        assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());
    });
}

#[cfg(unix)]
#[test]
fn a_terminal_whose_host_was_lost_has_no_working_agent() {
    // A host lost (a crash, a daemon restart that could not keep it) leaves the tabs in place
    // for a respawn, whatever the exit policy.
    assert_terminal_end_ends_its_working_agent(
        "host-lost",
        TerminalOnExit::Close,
        |mux, host, exit| {
            assert!(
                mux.persist_terminal_exit(host, Some(INCARNATION), &TerminalEnd::HostLost(exit))
                    .unwrap()
            );
        },
    );
}

/// A late exit of an earlier process of the terminal (it respawned since) is refused, and it
/// does not end the agent of the process that runs now.
#[cfg(unix)]
#[test]
fn a_stale_exit_does_not_end_the_running_agent() {
    const TERMINAL: &str = "0000000000004000800000000000229f";
    const EARLIER: &str = "1000000000004000800000000000229f";
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-stale-exit-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("agent-stale-exit", &root);
    let workspace = mux
        .create_empty_workspace(
            Some("agent-stale-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000229f".into()),
            None,
        )
        .unwrap();
    mux.seed_running_terminal_with_on_exit_for_test(
        TERMINAL,
        INCARNATION,
        &workspace.key,
        TerminalOnExit::Close,
    )
    .unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    for (event, key) in [("SessionStart", "stale-1"), ("UserPromptSubmit", "stale-2")] {
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(&terminal.to_string()),
            serde_json::json!({"session_id":"native-2"}),
        )
        .unwrap();
        mux.append_journal_ingress(&ingress, "test", key).unwrap();
    }
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
            signal: libc::SIGKILL,
            core_dumped: false,
        },
        exited_at_ms: 1_000,
    };

    let stale = mux.persist_terminal_exit(TERMINAL, Some(EARLIER), &TerminalEnd::HostLost(exit));
    assert!(stale.is_err(), "the stale exit is refused: {stale:?}");
    let working = mux.list_agents(None, Some(AgentState::Working));
    assert_eq!(working.len(), 1, "{working:?}");
    assert_eq!(working[0].terminal_id, terminal);
    assert_eq!(
        mux.agent_roster.lock().unwrap().roster.entries[terminal.as_str()].state,
        "working",
        "the roster keeps the running agent"
    );

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
