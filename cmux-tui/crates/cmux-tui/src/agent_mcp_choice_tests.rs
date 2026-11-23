use super::*;

const EXE: &str = "/A/cmux";
const SOCKET: &str = "/tmp/s.sock";

const CWD: &str = "/w";

/// An environment with nothing set.
fn no_env(_: &str) -> Option<OsString> {
    None
}

fn choice(text: &str) -> AgentsCmuxMcp {
    AgentsCmuxMcp::from_config_text(text)
}

/// Unanswered (no file, no key, `ask`, an unknown value or a file that does
/// not parse): neither agent gets the server.
#[test]
fn unanswered_passes_no_server_to_either_agent() {
    for text in
        ["", "{}", r#"{"agents": {"cmuxMcp": "ask"}}"#, r#"{"agents.cmuxMcp": "maybe"}"#, "{"]
    {
        let unset = choice(text);
        assert_eq!(claude_mcp_config(unset, Path::new(EXE), Path::new(SOCKET)), None, "{text}");
        assert!(
            codex_settings(unset, Path::new(EXE), Path::new(SOCKET), Path::new(CWD), &no_env)
                .is_empty(),
            "{text}"
        );
    }
}

#[test]
fn on_passes_the_server_to_both_agents() {
    let on = choice(r#"{"agents": {"cmuxMcp": "on"}}"#);
    let config = claude_mcp_config(on, Path::new(EXE), Path::new(SOCKET)).unwrap();
    let value: serde_json::Value = serde_json::from_str(config.to_str().unwrap()).unwrap();
    let servers = value["mcpServers"].as_object().unwrap();
    assert_eq!(servers.len(), 1, "{value}");
    assert!(servers.contains_key(crate::agent_computer_use::SERVER), "{value}");
    // An empty pane environment: nothing of this machine is read.
    let codex = codex_settings(on, Path::new(EXE), Path::new(SOCKET), Path::new(CWD), &no_env);
    assert!(!codex.is_empty());
    let prefix = format!("mcp_servers.{}.", crate::agent_computer_use::SERVER);
    assert!(codex.iter().all(|s| s.to_str().unwrap().starts_with(&prefix)), "{codex:?}");
}

/// The terminal shims and acpmux's sessions read the person's answer the same way, so the
/// terminal and the agent pane never disagree on whether an agent gets cmux's tools.
#[test]
fn the_shims_and_acpmux_read_the_answer_alike() {
    for text in [
        "",
        "{}",
        "{",
        r#"{"agents": {"cmuxMcp": "on"}}"#,
        r#"{"agents.cmuxMcp": "on"}"#,
        r#"{"agents": {"cmuxMcp": "off"}}"#,
        r#"{"agents": {"cmuxMcp": "ask"}}"#,
        r#"{"agents": {"cmuxMcp": "maybe"}}"#,
        r#"{"agents": {"cmuxMcp": true}}"#,
        "{\n// mine\n\"agents.cmuxMcp\": \"on\",\n}",
    ] {
        assert_eq!(
            choice(text).injects(),
            acpmux::agent_tools::agents_get_cmux(Some(text)),
            "{text}"
        );
    }
    assert!(!acpmux::agent_tools::agents_get_cmux(None));
}

#[test]
fn off_passes_no_server_to_either_agent() {
    for text in [r#"{"agents": {"cmuxMcp": "off"}}"#, r#"{"agents.cmuxMcp": "off"}"#] {
        let off = choice(text);
        assert_eq!(claude_mcp_config(off, Path::new(EXE), Path::new(SOCKET)), None, "{text}");
        assert!(
            codex_settings(off, Path::new(EXE), Path::new(SOCKET), Path::new(CWD), &no_env)
                .is_empty(),
            "{text}"
        );
    }
}
