//! A terminal's resume command (`set-terminal-resume-command`,
//! `terminal-resume-command-v1`): a command a person sets on a terminal tab
//! (Set Resume Command… in cmux-next). The daemon stores it with the
//! terminal, shows it on every tab of the terminal (`resume_command`), and
//! runs it in the new shell when the terminal is restarted: a respawn after
//! its host was lost, and a manual `restart-tab`. Null clears it.

use super::*;

fn set_resume_command(
    harness: &RecoveryHarness,
    surface: u64,
    command: serde_json::Value,
) -> serde_json::Value {
    request_response(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"set-terminal-resume-command","surface":surface,"command":command}),
    )
}

/// a. The command shows on the tab, and a respawned terminal runs it in its
/// new shell (the output, not only the typed line, appears).
#[test]
fn a_respawned_terminal_runs_its_resume_command() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("resume-command-respawn");
    let identify = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|capability| capability == "terminal-resume-command-v1"),
        "{identify}"
    );
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "resume");
    // The typed line shows `%s`; only the command's output shows `resume-ran-ok`.
    let command = "printf 'resume-ran-%s\\n' ok";
    let set = set_resume_command(&harness, surface, serde_json::json!(command));
    assert_eq!(set["ok"], true, "{set}");
    assert_eq!(set["data"]["resume_command"], command, "{set}");
    assert_eq!(set["data"]["terminal_id"], terminal_id.as_str(), "{set}");
    assert_eq!(tab_named(&harness, "resume")["resume_command"], command);

    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "resume");
    assert_eq!(tab["resume_command"], command, "the command outlives the restart: {tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, "resume-ran-ok");
    assert!(text.contains("resume-ran-ok"), "the resume command did not run: {text}");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(
        lines.first().map(|line| line["prefilled"].clone()),
        Some(serde_json::json!("resume")),
        "{lines:?}"
    );
}

/// b. Null clears the command; a command with a control character (a
/// newline would run part of it) is refused and keeps the stored one.
#[test]
fn a_resume_command_clears_with_null_and_refuses_control_characters() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("resume-command-clear");
    let (_, _, surface) = start_default_shell(&harness, "clear");
    assert_eq!(
        set_resume_command(&harness, surface, serde_json::json!("claude --resume abc"))["ok"],
        true
    );

    let refused = set_resume_command(&harness, surface, serde_json::json!("echo a\nrm b"));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(tab_named(&harness, "clear")["resume_command"], "claude --resume abc");

    let cleared = set_resume_command(&harness, surface, serde_json::Value::Null);
    assert_eq!(cleared["ok"], true, "{cleared}");
    assert_eq!(cleared["data"]["resume_command"], serde_json::Value::Null, "{cleared}");
    assert_eq!(tab_named(&harness, "clear")["resume_command"], serde_json::Value::Null);
}
