use super::*;

fn pane(name: &str) -> Option<OsString> {
    match name {
        "CMUX_TUI_TERMINAL_ID" => Some("term_7".into()),
        "CMUX_SOCKET_PATH" => Some("/tmp/app.sock".into()),
        _ => None,
    }
}

/// The one server's folded Computer Use bridge: this build, pointed at the pane's socket.
fn assert_upstreams(text: &str, executable: &str, socket: &str) {
    let upstreams: serde_json::Value = serde_json::from_str(text).unwrap();
    let only = upstreams.as_array().unwrap();
    assert_eq!(only.len(), 1, "{upstreams}");
    assert_eq!(only[0]["name"], COMPUTER_USE_SERVER);
    assert_eq!(only[0]["command"], executable);
    assert_eq!(only[0]["args"], json!(["computer-use", "mcp"]));
    assert_eq!(only[0]["env"]["CMUX_TUI_SOCKET"], socket);
    assert_eq!(
        only[0]["env"][SESSION_ENV],
        format!("terminal:term_7:{}", std::process::id()),
        "a session stable across the agent's reconnects"
    );
    assert_eq!(only[0]["callTimeoutSecs"], COMPUTER_USE_CALL_TIMEOUT_SECS);
}

#[test]
fn the_session_is_the_terminal_and_the_agent_pid_or_none() {
    assert_eq!(session(&pane, 42).as_deref(), Some("terminal:term_7:42"));
    assert_eq!(session(&|_| None, 42), None, "no terminal: the bridge picks its own");
}

/// The `-c` overrides as Codex applies them (each key split on every `.`).
fn merged(settings: &[OsString]) -> toml::Table {
    let mut root = toml::Table::new();
    for setting in settings {
        let (path, raw) = setting.to_str().unwrap().split_once('=').unwrap();
        let value = toml::from_str::<toml::Table>(&format!("v = {raw}")).unwrap().remove("v");
        let segments: Vec<&str> = path.split('.').collect();
        let (last, parents) = segments.split_last().unwrap();
        let mut table = &mut root;
        for segment in parents {
            table = table
                .entry(*segment)
                .or_insert_with(|| toml::Value::Table(toml::Table::new()))
                .as_table_mut()
                .unwrap();
        }
        table.insert((*last).to_owned(), value.unwrap());
    }
    root
}

#[test]
fn codex_gets_one_cmux_server_with_computer_use_behind_it() {
    let settings = codex_settings(
        Path::new("/A pp/cmux"),
        Path::new("/tmp/s \"q\".sock"),
        Path::new("/w/proj"),
        &pane,
    )
    .unwrap();
    for setting in &settings {
        let text = setting.to_str().unwrap();
        assert!(text.starts_with("mcp_servers.cmux."), "{text}");
        assert!(!text.contains(COMPUTER_USE_SERVER) || text.contains(".env."), "{text}");
    }
    let merged = merged(&settings);
    let servers = merged["mcp_servers"].as_table().unwrap();
    assert_eq!(servers.keys().collect::<Vec<_>>(), [SERVER]);
    let server = servers[SERVER].as_table().unwrap();
    assert_eq!(server["command"].as_str(), Some("/A pp/cmux"));
    assert_eq!(server["args"], toml::Value::try_from(["mcp", "serve"]).unwrap());
    assert_eq!(server["cwd"].as_str(), Some("/w/proj"));
    assert_eq!(server["enabled"].as_bool(), Some(true));
    let env = server["env"].as_table().unwrap();
    assert_eq!(env["CMUX_TUI_SOCKET"].as_str(), Some("/tmp/s \"q\".sock"));
    assert_eq!(env[TERMINAL_AGENT_ENV].as_str(), Some("1"));
    assert_eq!(env["CMUX_TUI_TERMINAL_ID"].as_str(), Some("term_7"));
    assert_eq!(env["CMUX_SOCKET_PATH"].as_str(), Some("/tmp/app.sock"));
    assert!(env.get("CMUX_TAG").is_none(), "an unset pane env is left out");
    // The acpmux guest mode always off (a desktop-link `cmux` entry would merge it in), and
    // the settings file always named.
    assert_eq!(env[acpmux::desktop_link::GUEST_ENV].as_str(), Some(""));
    assert!(env["CMUX_NEXT_CONFIG_FILE"].as_str().is_some_and(|f| !f.is_empty()));
    assert_upstreams(env[UPSTREAMS_ENV].as_str().unwrap(), "/A pp/cmux", "/tmp/s \"q\".sock");
}

#[test]
fn claude_gets_one_cmux_server_with_computer_use_behind_it() {
    let config =
        claude_mcp_config_with(Path::new("/A/cmux"), Path::new("/tmp/s.sock"), &pane).unwrap();
    let value: serde_json::Value = serde_json::from_str(config.to_str().unwrap()).unwrap();
    let servers = value["mcpServers"].as_object().unwrap();
    assert_eq!(servers.keys().collect::<Vec<_>>(), [SERVER], "no separate Computer Use server");
    let server = &servers[SERVER];
    assert_eq!(server["command"], "/A/cmux");
    assert_eq!(server["args"], json!(["mcp", "serve"]));
    assert_eq!(server["env"]["CMUX_TUI_SOCKET"], "/tmp/s.sock");
    assert_eq!(server["env"][TERMINAL_AGENT_ENV], "1");
    assert_eq!(server["env"]["CMUX_TUI_TERMINAL_ID"], "term_7");
    assert_upstreams(server["env"][UPSTREAMS_ENV].as_str().unwrap(), "/A/cmux", "/tmp/s.sock");
}

/// `CMUX_MCP_CODE_MODE=0` in the pane lists every tool, cu_* among them, directly.
#[test]
fn code_mode_off_in_the_pane_lists_every_tool() {
    let all = |name: &str| (name == CODE_MODE_ENV).then(|| OsString::from("0"));
    let config =
        claude_mcp_config_with(Path::new("/A/cmux"), Path::new("/tmp/s.sock"), &all).unwrap();
    let value: serde_json::Value = serde_json::from_str(config.to_str().unwrap()).unwrap();
    assert_eq!(value["mcpServers"][SERVER]["args"], json!(["mcp", "serve", "--all-tools"]));
}
