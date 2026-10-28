//! `extra.shell_idle`: the terminal's own shell sits idle at its prompt, the
//! fact a close trusts without asking. An OSC 133 prompt mark alone
//! (`extra.prompt`) does not say so: a nested shell prints its own prompt
//! while ssh holds the terminal, a typed command has not reached its `C`
//! yet, and a program `exec`ed in the shell's place can print one too. The
//! shell here is an interactive bash (job control on, so each command is a
//! foreground job of its own) whose prompt is the only integration: `A` and
//! `B` around `idle> `, no `C` or `D`, so a running command leaves the
//! prompt fact standing as a shell that lost its integration does.

use super::*;

/// The prompt; also the screen marker of a drawn prompt.
const PROMPT: &str = "idle> ";

/// The first file of `candidates` that exists.
fn find(candidates: &[&str]) -> Option<String> {
    candidates.iter().find(|path| Path::new(path).is_file()).map(|path| (*path).to_string())
}

/// `extra` of the harness's only terminal record.
fn terminal_extra(harness: &RecoveryHarness) -> serde_json::Value {
    let terminals = resource_request(
        &harness.socket,
        "shell-idle-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminals = terminals.as_array().unwrap();
    assert_eq!(terminals.len(), 1, "expected one terminal: {terminals:?}");
    terminals[0]["extra"].clone()
}

/// Starts the interactive bash in a new workspace, waits for its prompt and
/// for the daemon to publish it idle. `None` when bash is not installed.
fn start_bash(name: &str) -> Option<(RecoveryHarness, u64)> {
    let Some(bash) = find(&["/bin/bash", "/usr/bin/bash", "/opt/homebrew/bin/bash"]) else {
        eprintln!("skipped: bash is not installed");
        return None;
    };
    let mut harness = RecoveryHarness::start_unstarted(name);
    // No Ghostty integration on top of the test's own prompt marks.
    harness.shell_integration = false;
    harness.restart();
    let rc = harness.dir.join("bashrc");
    fs::write(
        &rc,
        "PS1='\\[\\033]133;A\\007\\]idle> \\[\\033]133;B\\007\\]'\n\
         unset PROMPT_COMMAND\nHISTFILE=/dev/null\n",
    )
    .unwrap();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [bash, "--noprofile", "--rcfile", rc, "-i"],
            "new_workspace": true,
            "name": name,
            "cols": 100,
            "rows": 10,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, PROMPT).contains(PROMPT));
    wait_for_idle(&harness);
    Some((harness, surface))
}

/// Waits until the daemon says the shell sits idle at its prompt.
fn wait_for_idle(harness: &RecoveryHarness) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let extra = terminal_extra(harness);
        if extra["shell_idle"]["since_ms"].is_string() {
            assert_eq!(
                extra["shell_idle"]["since_ms"], extra["prompt"]["since_ms"],
                "idle since the prompt: {extra}"
            );
            return extra;
        }
        assert!(Instant::now() < deadline, "the shell at its prompt never read idle: {extra}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Types `text` into the terminal.
fn type_text(harness: &RecoveryHarness, surface: u64, text: &str) {
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": text}),
    );
}

/// Asserts the old prompt fact still stands (a close that trusts it alone
/// reads the tab idle) while `shell_idle` says no, and keeps saying no for
/// `hold` (the daemon's foreground check runs after the mark, on its work
/// lane, so a wrong answer would show within it).
fn assert_not_idle(harness: &RecoveryHarness, hold: Duration, what: &str) {
    let until = Instant::now() + hold;
    loop {
        let extra = terminal_extra(harness);
        assert!(extra["prompt"]["since_ms"].is_string(), "{what}: the prompt fact stands: {extra}");
        assert!(extra.get("shell_idle").is_none(), "{what}: not idle: {extra}");
        if Instant::now() >= until {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn shell_idle_a_plain_prompt_with_no_input_is_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, _surface)) = start_bash("shell-idle-plain") else { return };
    let extra = terminal_extra(&harness);
    assert!(extra.get("activity").is_none(), "{extra}");
    assert!(extra["shell_idle"]["since_ms"].is_string(), "{extra}");
}

#[test]
fn shell_idle_a_nested_shell_prompt_in_a_foreground_child_is_not_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash("shell-idle-nested") else { return };
    // A child job (ssh or `docker exec` into an integrated shell) holds the
    // terminal and prints its own prompt mark. `%s` keeps the marker out of
    // the echoed command line.
    type_text(&harness, surface, "sh -c 'printf \"\\033]133;A\\007%s> \" nested; sleep 600'\r");
    assert!(wait_for_screen(&harness.socket, surface, "nested> ").contains("nested> "));
    assert_not_idle(&harness, Duration::from_millis(500), "a nested prompt");
}

#[test]
fn shell_idle_input_after_the_prompt_is_not_idle_until_the_next_prompt() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash("shell-idle-input") else { return };
    // Typed, not yet run: no `C` has come, the prompt fact stands.
    type_text(&harness, surface, "echo typed");
    assert_not_idle(&harness, Duration::ZERO, "a typed line");
    // Ctrl-U clears the line and Return draws a new prompt: idle again.
    type_text(&harness, surface, "\u{15}\r");
    wait_for_idle(&harness);
    // A command typed and run a moment ago: still not idle while it runs
    // (here no `C` ever comes).
    type_text(&harness, surface, "sleep 600\r");
    assert_not_idle(&harness, Duration::from_millis(500), "a command just run");
}

#[test]
fn shell_idle_a_program_execed_in_the_shells_place_is_not_idle() {
    let _exclusive = exclusive_process_test();
    // A shell image other than bash (macOS /bin/sh runs bash).
    let Some(other) = find(&[
        "/bin/dash",
        "/usr/bin/dash",
        "/bin/zsh",
        "/usr/bin/zsh",
        "/bin/ksh",
        "/usr/bin/ksh",
    ]) else {
        eprintln!("skipped: no shell other than bash is installed");
        return;
    };
    let Some((harness, surface)) = start_bash("shell-idle-exec") else { return };
    // `exec` replaces bash in the same process, which keeps the foreground,
    // and the new image prints a prompt mark of its own.
    type_text(
        &harness,
        surface,
        &format!("exec {other} -c 'printf \"\\033]133;A\\007%s> \" execd; read line'\r"),
    );
    assert!(wait_for_screen(&harness.socket, surface, "execd> ").contains("execd> "));
    assert_not_idle(&harness, Duration::from_millis(500), "an exec'd shell");
}
