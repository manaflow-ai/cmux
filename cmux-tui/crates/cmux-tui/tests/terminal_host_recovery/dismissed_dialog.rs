//! A permission dialog dismissed with Esc, on a daemon that runs no
//! screen-detection plugin (the plugin is not beside this test build, as it
//! was not beside the round 3 bench binary or in the NIGHTLY app bundle).
//!
//! Claude Code fires no hook when the person dismisses its dialog: the turn
//! is interrupted, so neither `PostToolUse` nor `Stop` comes, and the hook
//! row stays `blocked`. Claude Code does report its own status in the
//! terminal stream (OSC 7501: `blocked` with kind `permission` while the
//! dialog shows, then `idle`), and that report must end the hook row's
//! block, also across a daemon restart.

use super::*;

/// One script step that prints an OSC 7501 report of Claude Code.
fn claude_status(fields: &str) -> String {
    format!("printf '\\033]7501;{fields}:app=claude-code\\033\\\\'; ")
}

#[test]
fn dismissed_dialog_clears_blocked_from_the_agents_own_status_without_a_plugin() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("dismissed-dialog-osc");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    let hook = |event: &str, extra: &str| {
        format!(
            "printf '%s' '{{\"session_id\":\"dismissed-1\",\"hook_event_name\":\"{event}\",\
             \"cwd\":\"/tmp\"{extra}}}' | '{helper}' __agent-hook claude {event}; "
        )
    };
    let script = format!(
        "printf 'ready\\r\\n'; read step; {}{}{}{}printf 'asked\\r\\n'; read step; {}\
         printf 'denied\\r\\n'; sleep 600",
        claude_status("state=working"),
        hook("UserPromptSubmit", ",\"prompt\":\"touch a file\""),
        // The dialog draws, Claude reports it, then the hook arrives.
        claude_status("state=blocked:kind=permission"),
        hook("PermissionRequest", ",\"tool_name\":\"Bash\""),
        // Esc: no hook fires; Claude reports that it sits at its prompt.
        claude_status("state=idle"),
    );
    let (surface, _) = run_script(&harness, "dismissed-dialog-osc", &script, "ready");

    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "asked").contains("asked"));
    wait_for_agent_state(&harness, "blocked");

    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "denied").contains("denied"));
    wait_for_agent_state(&harness, "idle");

    // The roster folds from the journal, so a new daemon agrees.
    harness.sigkill();
    harness.restart();
    let agents = wait_for_agent_state(&harness, "idle");
    assert!(
        !agents["agents"].as_array().into_iter().flatten().any(|agent| agent["state"] == "blocked"),
        "the dismissed dialog came back after a restart: {agents}"
    );
}

#[test]
fn dismissed_dialog_needs_the_agents_own_blocked_report_first() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("dismissed-dialog-unseen");
    let helper = env!("CARGO_BIN_EXE_cmux-tui");
    let hook = |event: &str, extra: &str| {
        format!(
            "printf '%s' '{{\"session_id\":\"unseen-1\",\"hook_event_name\":\"{event}\",\
             \"cwd\":\"/tmp\"{extra}}}' | '{helper}' __agent-hook claude {event}; "
        )
    };
    // A program that reports only `idle` never said it showed the dialog the
    // hook announced: its report proves nothing about that dialog.
    let script = format!(
        "printf 'ready\\r\\n'; read step; {}{}printf 'asked\\r\\n'; read step; {}\
         printf 'idle\\r\\n'; sleep 600",
        hook("UserPromptSubmit", ",\"prompt\":\"touch a file\""),
        hook("PermissionRequest", ",\"tool_name\":\"Bash\""),
        claude_status("state=idle"),
    );
    let (surface, _) = run_script(&harness, "dismissed-dialog-unseen", &script, "ready");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "asked").contains("asked"));
    wait_for_agent_state(&harness, "blocked");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "idle").contains("idle"));
    // Give the publisher and the roster fold time to act on the report.
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        let agents = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-agents"}));
        assert!(
            agents["agents"]
                .as_array()
                .into_iter()
                .flatten()
                .all(|agent| agent["state"] == "blocked"),
            "an idle report without a blocked one cleared the hook's dialog: {agents}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}
