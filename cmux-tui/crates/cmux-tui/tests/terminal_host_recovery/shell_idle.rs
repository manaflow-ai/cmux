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

/// The screen marker of a drawn prompt (PS1 is `idle> `): `read-screen`
/// trims trailing blanks, so the space after it is never on the screen text.
const PROMPT: &str = "idle>";

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
    start_bash_with(name, "")
}

/// [`start_bash`] with `rc` first in its rc file (`set +m`).
fn start_bash_with(name: &str, rc_prefix: &str) -> Option<(RecoveryHarness, u64)> {
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
        format!(
            "{rc_prefix}PS1='\\[\\033]133;A\\007\\]idle> \\[\\033]133;B\\007\\]'\n\
             unset PROMPT_COMMAND\nHISTFILE=/dev/null\n"
        ),
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

/// The pid of the terminal's own process (`process-info`).
fn shell_pid(harness: &RecoveryHarness, surface: u64) -> u64 {
    let info = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "process-info", "surface": surface}),
    );
    info["pid"].as_u64().unwrap_or_else(|| panic!("no pid: {info}"))
}

/// Waits until the daemon's foreground check after the last mark has run and
/// says the terminal's own shell does NOT hold the foreground, and returns
/// the leader it saw. A check that is broken (says own) or never runs fails
/// here, whatever the timing: the test reads the daemon's decision
/// (`extra.foreground_check`), not only that `shell_idle` is absent.
fn wait_for_foreign_foreground(harness: &RecoveryHarness, what: &str) -> Option<u64> {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let extra = terminal_extra(harness);
        if let Some(own) = extra["foreground_check"]["own"].as_bool() {
            assert!(
                !own,
                "{what}: the daemon's foreground check says the shell holds the foreground: {extra}"
            );
            assert!(extra.get("shell_idle").is_none(), "{what}: not idle: {extra}");
            return extra["foreground_check"]["leader"].as_u64();
        }
        assert!(
            Instant::now() < deadline,
            "{what}: the foreground check never ran after the mark: {extra}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
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
    let Some((harness, surface)) = start_bash("shell-idle-plain") else { return };
    let extra = terminal_extra(&harness);
    assert!(extra.get("activity").is_none(), "{extra}");
    assert!(extra["shell_idle"]["since_ms"].is_string(), "{extra}");
    // The decision behind it: the shell itself leads the foreground.
    assert_eq!(extra["foreground_check"]["own"], true, "{extra}");
    assert_eq!(
        extra["foreground_check"]["leader"].as_u64(),
        Some(shell_pid(&harness, surface)),
        "{extra}"
    );
}

#[test]
fn shell_idle_a_nested_shell_prompt_in_a_foreground_child_is_not_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash("shell-idle-nested") else { return };
    // A child job (ssh or `docker exec` into an integrated shell) holds the
    // terminal and prints its own prompt mark. `%s` keeps the marker out of
    // the echoed command line.
    type_text(&harness, surface, "sh -c 'printf \"\\033]133;A\\007%s> \" nested; sleep 600'\r");
    assert!(wait_for_screen(&harness.socket, surface, "nested>").contains("nested>"));
    // The job (the nested sh) leads the foreground, not the shell: asserted on
    // the daemon's own check, so a check that always says own fails here.
    let leader = wait_for_foreign_foreground(&harness, "a nested prompt");
    assert!(
        leader.is_some_and(|leader| leader != shell_pid(&harness, surface)),
        "the job leads the foreground: {leader:?}"
    );
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
    assert!(wait_for_screen(&harness.socket, surface, "execd>").contains("execd>"));
    // The same process leads the foreground, but runs another program.
    let leader = wait_for_foreign_foreground(&harness, "an exec'd shell");
    assert_eq!(leader, Some(shell_pid(&harness, surface)), "the exec'd image keeps the pid");
    assert_not_idle(&harness, Duration::from_millis(500), "an exec'd shell");
}

/// The lead, 2026-10-28: a shell with job control off (`set +m`) runs its
/// jobs in its own process group, so its group leading the foreground proves
/// nothing. A background job, and a foreground job that prints its own
/// prompt mark (a nested shell over ssh), both share the shell's group: not
/// idle. Before, both read idle (a close with no question).
#[test]
fn shell_idle_job_control_off_a_job_in_the_shells_group_is_not_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash_with("shell-idle-nojobs", "set +m\n") else { return };
    // A background job, then the next prompt.
    type_text(&harness, surface, "sleep 600 &\r");
    let leader = wait_for_foreign_foreground(&harness, "a background job, job control off");
    assert_eq!(
        leader,
        Some(shell_pid(&harness, surface)),
        "job control off: the shell's own group leads"
    );
    assert_not_idle(&harness, Duration::from_millis(500), "a background job, job control off");
}

#[test]
fn shell_idle_job_control_off_a_nested_prompt_is_not_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash_with("shell-idle-nojobs-nested", "set +m\n") else {
        return;
    };
    type_text(&harness, surface, "sh -c 'printf \"\\033]133;A\\007%s> \" nested; sleep 600'\r");
    assert!(wait_for_screen(&harness.socket, surface, "nested>").contains("nested>"));
    wait_for_foreign_foreground(&harness, "a nested prompt, job control off");
    assert_not_idle(&harness, Duration::from_millis(500), "a nested prompt, job control off");
}

#[test]
fn shell_idle_a_renderer_grant_ends_idle_for_good() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash("shell-idle-grant") else { return };
    // A renderer grant's holder writes Input and Paste frames to the
    // terminal host directly, unseen by the daemon (a remote viewer).
    let mint = serde_json::json!({
        "id": 3, "cmd": "mint-terminal-renderer", "surface": surface, "ttl_ms": 10_000
    });
    let grant = request(&harness.socket, mint);
    assert!(grant["token"].is_string(), "the terminal is hosted: {grant}");
    assert_not_idle(&harness, Duration::from_millis(500), "a renderer grant");
    // A new prompt does not make it idle again: the grant's input stays
    // unseen.
    // `ag''ain` keeps the marker out of the echoed command line.
    type_text(&harness, surface, "echo ag''ain\r");
    assert!(wait_for_screen(&harness.socket, surface, "again").contains("again"));
    assert_not_idle(&harness, Duration::from_millis(500), "a renderer grant, a later prompt");
}

/// Review 2: a background job (job control on: its own group) dies with the
/// terminal, so the shell at its next prompt is not idle to close.
#[test]
fn shell_idle_a_background_job_is_not_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash("shell-idle-background") else { return };
    type_text(&harness, surface, "sleep 600 &\r");
    let leader = wait_for_foreign_foreground(&harness, "a background job");
    assert_eq!(
        leader,
        Some(shell_pid(&harness, surface)),
        "the shell leads the foreground at its prompt"
    );
    assert_not_idle(&harness, Duration::from_millis(500), "a background job");
}

/// Review 2: a stopped job (vim after Ctrl-Z) would die with the terminal.
#[test]
fn shell_idle_a_stopped_job_is_not_idle() {
    let _exclusive = exclusive_process_test();
    let Some((harness, surface)) = start_bash("shell-idle-stopped") else { return };
    type_text(&harness, surface, "sleep 600\r");
    // Ctrl-Z stops it; bash draws the next prompt.
    std::thread::sleep(Duration::from_millis(300)); // test harness: let bash hand the terminal to `sleep`
    type_text(&harness, surface, "\u{1a}");
    assert!(wait_for_screen(&harness.socket, surface, "Stopped").contains("Stopped"));
    wait_for_foreign_foreground(&harness, "a stopped job");
    assert_not_idle(&harness, Duration::from_millis(500), "a stopped job");
}
