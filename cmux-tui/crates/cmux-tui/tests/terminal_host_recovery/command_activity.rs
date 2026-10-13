//! cx-ag5.6.5: a running shell command is never work in progress. The
//! daemon publishes it on the terminal record as quiet `running` (a plain
//! command) or `in_use` (the command took the terminal for interaction:
//! htop, vim, less, a REPL), and only a program's own OSC 7501 report says
//! `working`. Each script plays the shell's OSC 133 marks itself and waits
//! for a line on the terminal between steps, so every state is read while
//! it holds.

use super::*;

/// `extra` of the harness's only terminal record.
fn terminal_extra(harness: &RecoveryHarness) -> serde_json::Value {
    let terminals = resource_request(
        &harness.socket,
        "command-activity-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminals = terminals.as_array().unwrap();
    assert_eq!(terminals.len(), 1, "expected one terminal: {terminals:?}");
    terminals[0]["extra"].clone()
}

/// Waits until `extra.activity.state` is `state` (`None`: no activity).
fn wait_for_activity(harness: &RecoveryHarness, state: Option<&str>) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let extra = terminal_extra(harness);
        if extra["activity"]["state"].as_str() == state {
            return extra;
        }
        assert!(Instant::now() < deadline, "activity never became {state:?}: {extra}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Starts `script` (sh) in a new workspace and waits for `marker`.
fn run_script(harness: &RecoveryHarness, name: &str, script: &str, marker: &str) -> (u64, String) {
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": name,
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    (surface, terminal_id)
}

/// Sends one line to the script's next `read`.
fn step(harness: &RecoveryHarness, surface: u64) {
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": "\n"}),
    );
}

#[test]
fn a_full_screen_program_is_in_use_never_running() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-alt-screen");
    let (surface, _) = run_script(
        &harness,
        "command-activity-alt-screen",
        concat!(
            // The shell starts a command, which takes the alternate screen
            // like htop does.
            "printf '\\033]133;C\\007started\\r\\n'; read step; ",
            "printf '\\033[?1049hfullscreen'; read step; ",
            // It leaves the alternate screen for a moment (vim `:!ls`).
            "printf '\\033[?1049lback\\r\\n'; read step; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "started",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    assert!(extra["busy"]["since_ms"].is_string(), "a plain command keeps busy: {extra}");
    let since = extra["activity"]["since_ms"].clone();

    step(&harness, surface);
    let extra = wait_for_activity(&harness, Some("in_use"));
    assert!(extra.get("busy").is_none(), "an in-use command is not busy: {extra}");
    assert_eq!(extra["activity"]["since_ms"], since, "the same command: {extra}");

    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "back").contains("back"));
    let extra = terminal_extra(&harness);
    assert_eq!(extra["activity"]["state"], "in_use", "in use for the whole command: {extra}");
    assert!(extra.get("busy").is_none(), "{extra}");

    step(&harness, surface);
    let extra = wait_for_activity(&harness, None);
    assert!(extra.get("busy").is_none(), "the prompt ends the command: {extra}");
}

#[test]
fn a_repl_that_reads_lines_is_in_use() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-repl");
    let (surface, _) = run_script(
        &harness,
        "command-activity-repl",
        concat!(
            "printf '\\033]133;C\\007started\\r\\n'; read step; ",
            // A line-editing REPL (python, psql, ssh's remote shell) turns
            // on bracketed paste to read the user's lines.
            "printf '\\033[?2004h>>> '; read step; ",
            "printf '\\033[?2004l\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "started",
    );
    wait_for_activity(&harness, Some("running"));
    step(&harness, surface);
    let extra = wait_for_activity(&harness, Some("in_use"));
    assert!(extra.get("busy").is_none(), "{extra}");
    step(&harness, surface);
    wait_for_activity(&harness, None);
}

#[test]
fn a_shell_that_turns_bracketed_paste_off_after_the_command_starts_keeps_it_running() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-late-paste-off");
    let (surface, _) = run_script(
        &harness,
        "command-activity-late-paste-off",
        concat!(
            // fish prints `C` while its line editor still has bracketed
            // paste and focus reporting on, and turns them off in a later
            // write: the command did not turn them on.
            "printf '\\033[?2004h\\033[?1004h\\033]133;C\\007started\\r\\n'; read step; ",
            "printf '\\033[?2004l\\033[?1004loff\\r\\n'; read step; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "started",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    assert!(extra["busy"]["since_ms"].is_string(), "{extra}");
    step(&harness, surface);
    assert!(wait_for_screen(&harness.socket, surface, "off").contains("off"));
    let extra = terminal_extra(&harness);
    assert_eq!(
        extra["activity"]["state"], "running",
        "the shell's modes are not the command's: {extra}"
    );
    step(&harness, surface);
    wait_for_activity(&harness, None);
}

#[test]
fn a_short_command_runs_quietly_then_ends() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-sleep");
    let (surface, _) = run_script(
        &harness,
        "command-activity-sleep",
        concat!(
            // `sleep 5` from the prompt, ended on cue.
            "printf '\\033]133;C\\007sleeping\\r\\n'; read step; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "sleeping",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    assert!(extra.get("program_status").is_none(), "a command reports no work: {extra}");
    step(&harness, surface);
    let extra = wait_for_activity(&harness, None);
    assert!(extra.get("busy").is_none(), "{extra}");
}

#[test]
fn only_the_programs_own_report_says_working_then_done() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("command-activity-osc7501");
    let (surface, _) = run_script(
        &harness,
        "command-activity-osc7501",
        concat!(
            "printf '\\033]133;C\\007\\033]7501;state=working:progress=40:app=make\\033\\\\building\\r\\n'; read step; ",
            "printf '\\033]7501;state=done:app=make\\033\\\\'; ",
            "printf '\\033]133;D;0\\007\\033]133;A\\007prompt\\r\\n'; sleep 600",
        ),
        "building",
    );
    let extra = wait_for_activity(&harness, Some("running"));
    let status = extra["program_status"].as_array().cloned().unwrap_or_default();
    assert_eq!(status.len(), 1, "{extra}");
    assert_eq!(status[0]["state"], "working", "{extra}");
    assert_eq!(status[0]["progress"], 40, "{extra}");

    step(&harness, surface);
    let extra = wait_for_activity(&harness, None);
    let status = extra["program_status"].as_array().cloned().unwrap_or_default();
    assert_eq!(status.len(), 1, "done survives the prompt: {extra}");
    assert_eq!(status[0]["state"], "done", "{extra}");
}
