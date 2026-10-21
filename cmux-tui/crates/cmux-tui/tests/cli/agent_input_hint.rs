//! Typing into a terminal whose agent hooks report a live agent still sends
//! the input, and the CLI points at `cmux agent message` on stderr. A
//! terminal with no agent, keys, and `--quiet` get no hint; control
//! characters in the text never reach stderr.

use super::super::*;

#[test]
fn terminal_input_into_an_agent_suggests_agent_message() {
    let server = HeadlessServer::start("agent-input-hint");
    let create = || {
        let created = json_cli(&server, &["tab", "create", "terminal"]);
        assert_success(&created);
        json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_owned()
    };
    let agent_terminal = create();
    let plain_terminal = create();
    let report = json_cli(
        &server,
        &[
            "agent",
            "report",
            "--terminal",
            &agent_terminal,
            "--state",
            "idle",
            "--source",
            "socket",
            "--source-session",
            "agent-input-hint",
        ],
    );
    assert_success(&report);
    // The suggested command reaches the same daemon: `cli` passes --socket.
    let socket = format!("--socket '{}'", server.socket.display());
    let stderr = |output: &Output| String::from_utf8_lossy(&output.stderr).into_owned();

    let typed = cli(&server, &["terminal", &agent_terminal, "write", "--text", "it's done"]);
    assert_success(&typed);
    let hint = stderr(&typed);
    assert!(
        hint.contains(&format!(
            "cmux {socket} agent message {agent_terminal} -- 'it'\"'\"'s done'"
        )),
        "typing into an agent names the agent message command: {hint}"
    );

    // Text that starts with a dash stays the message: the hint ends flags
    // with `--`, so `agent message` reads neither `-n hello` as a flag nor
    // `-` as "read stdin".
    let dashed = cli(&server, &["terminal", &agent_terminal, "write", "--text", "-n hello"]);
    assert_success(&dashed);
    let hint = stderr(&dashed);
    assert!(
        hint.contains(&format!("agent message {agent_terminal} -- '-n hello'")),
        "dash-leading text follows --: {hint}"
    );

    // Keys (enter, ctrl+c) submit or interrupt the agent; they are not a
    // message, so they get no hint.
    let keys = cli(&server, &["terminal", &agent_terminal, "keys", "enter"]);
    assert_success(&keys);
    assert!(!stderr(&keys).contains("agent message"), "keys get no hint: {}", stderr(&keys));

    // Control characters never reach stderr: the command shows a placeholder.
    let submit =
        cli(&server, &["terminal", &agent_terminal, "write", "--text", "go\r\u{1b}]0;x\u{7}"]);
    assert_success(&submit);
    let hint = stderr(&submit);
    assert!(hint.contains(&format!("agent message {agent_terminal} -- '…'")), "{hint}");
    assert!(!hint.contains('\u{1b}') && !hint.contains('\r'), "raw control characters: {hint:?}");

    // The suggested command keeps the caller's route.
    let routed = cli(
        &server,
        &["--machine", "current", "terminal", &agent_terminal, "write", "--text", "hi"],
    );
    assert_success(&routed);
    assert!(
        stderr(&routed).contains(&format!(
            "cmux --machine current {socket} agent message {agent_terminal} -- 'hi'"
        )),
        "{}",
        stderr(&routed)
    );

    // --json stdout stays exactly the result.
    let json = json_cli(&server, &["terminal", &agent_terminal, "write", "--text", "x"]);
    assert_success(&json);
    json_output(&json);

    let quiet = cli(&server, &["--quiet", "terminal", &agent_terminal, "write", "--text", "x"]);
    assert_success(&quiet);
    assert!(!stderr(&quiet).contains("agent message"), "--quiet prints no hint");

    let plain = cli(&server, &["terminal", &plain_terminal, "write", "--text", "x"]);
    assert_success(&plain);
    assert!(!stderr(&plain).contains("agent message"), "no agent, no hint: {}", stderr(&plain));
}
