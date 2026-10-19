//! Typing into a terminal whose agent hooks report a live agent still sends
//! the input, and the CLI points at `cmux agent message` on stderr. A
//! terminal with no agent, and `--quiet`, get no hint.

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
    let stderr = |output: &Output| String::from_utf8_lossy(&output.stderr).into_owned();

    let typed = cli(&server, &["terminal", &agent_terminal, "write", "--text", "it's done"]);
    assert_success(&typed);
    let hint = stderr(&typed);
    assert!(
        hint.contains(&format!("cmux agent message {agent_terminal} 'it'\"'\"'s done'")),
        "typing into an agent names the agent message command: {hint}"
    );

    let keys = cli(&server, &["terminal", &agent_terminal, "keys", "enter"]);
    assert_success(&keys);
    assert!(
        stderr(&keys).contains(&format!("cmux agent message {agent_terminal} ")),
        "keys into an agent get the hint too: {}",
        stderr(&keys)
    );

    let quiet = cli(&server, &["--quiet", "terminal", &agent_terminal, "write", "--text", "x"]);
    assert_success(&quiet);
    assert!(!stderr(&quiet).contains("agent message"), "--quiet prints no hint");

    let plain = cli(&server, &["terminal", &plain_terminal, "write", "--text", "x"]);
    assert_success(&plain);
    assert!(!stderr(&plain).contains("agent message"), "no agent, no hint: {}", stderr(&plain));
}
