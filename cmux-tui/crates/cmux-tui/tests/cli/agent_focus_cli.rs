//! `cmux agent <agent> focus` through a real daemon: an agent id or its
//! terminal id focuses the tab that shows the agent's terminal, and an id the
//! session has no agent for is refused without moving focus.

use super::super::*;

#[test]
fn agent_focus_cli_focuses_the_tab_of_the_agents_terminal() {
    let server = HeadlessServer::start("agent-focus-cli");
    let create = || {
        let created = json_cli(&server, &["tab", "create", "terminal"]);
        assert_success(&created);
        let value = &json_output(&created)["value"];
        (
            value["tab_id"].as_str().unwrap().to_owned(),
            value["terminal_id"].as_str().unwrap().to_owned(),
        )
    };
    let (agent_tab, agent_terminal) = create();
    let (other_tab, _) = create();
    let report = json_cli(
        &server,
        &[
            "agent",
            "report",
            "--terminal",
            &agent_terminal,
            "--state",
            "blocked",
            "--source",
            "socket",
            "--source-session",
            "agent-focus",
        ],
    );
    assert_success(&report);
    let listed = json_cli(&server, &["agent", "list", "--terminal", &agent_terminal]);
    assert_success(&listed);
    let listed = json_output(&listed);
    let agent = find_agent(&listed, &agent_terminal);

    let focused = |tab: &str| -> bool {
        let shown = json_cli(&server, &["tab", tab, "show"]);
        assert_success(&shown);
        let shown = json_output(&shown);
        let tab = shown.get("value").unwrap_or(&shown);
        let tab = tab.get("tab").unwrap_or(tab);
        tab["focused"].as_bool().unwrap_or_else(|| panic!("no focused field: {shown}"))
    };
    let focus_other = || assert_success(&json_cli(&server, &["tab", &other_tab, "focus"]));

    focus_other();
    assert!(!focused(&agent_tab), "the agent's tab starts unfocused");
    let output = json_cli(&server, &["agent", &agent, "focus"]);
    assert_success(&output);
    assert!(focused(&agent_tab), "an agent id focuses its terminal's tab");
    assert!(!focused(&other_tab));

    focus_other();
    let output = json_cli(&server, &["agent", &agent_terminal, "focus"]);
    assert_success(&output);
    assert!(focused(&agent_tab), "a terminal id with an agent focuses its tab");

    focus_other();
    let unknown = format!("agent_{}", "0".repeat(32));
    let output = json_cli(&server, &["agent", &unknown, "focus"]);
    assert_eq!(output.status.code(), Some(1), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(json_error(&output)["code"], "selector.not_found");
    assert!(focused(&other_tab), "a refused focus leaves focus where it was");
}

/// The id of the agent on `terminal` in an `agent list --json` reply.
fn find_agent(listed: &serde_json::Value, terminal: &str) -> String {
    let rows = listed.get("value").unwrap_or(listed);
    let rows = rows.as_array().or_else(|| rows["agents"].as_array()).expect("agent rows");
    rows.iter()
        .find(|row| row["terminal_id"] == terminal)
        .and_then(|row| row["id"].as_str())
        .unwrap_or_else(|| panic!("no agent on {terminal}: {listed}"))
        .to_owned()
}
