//! cmux's MCP server for agents started in a terminal pane. The `claude` and
//! `codex` shims (claude_wrapper.rs, codex_wrapper.rs) already pass cmux's
//! hooks for each launch; they also pass ONE MCP server, `cmux` (this build's
//! own `cmux mcp serve`), with cmux Computer Use folded behind it as `cu_*`
//! (`cli/mcp/upstream.rs`), the same way a cmux agent chat gets it. So an agent
//! typed into a cmux terminal reaches Computer Use through the cmux server it
//! already has, and can script it in `cmux_exec` (`cu.click({...})`).
//!
//! The Computer Use bridge behind it is `cmux computer-use mcp`, pointed at
//! this pane's daemon socket: it asks that daemon for the worker at each call
//! and is started only on the first `cu_*` call. The person's Computer Use
//! settings (mode off, deny list) still decide what runs. While the settings
//! file keeps cmux's MCP tools off for clients outside cmux's chats
//! (`mcp.enabled` not true), the server serves only Computer Use
//! (`TERMINAL_AGENT_ENV`, `cli/mcp.rs`), which these agents always had.
//! `cmux computer-use mcp` stays available for any other MCP client.

use std::ffi::OsString;
use std::path::Path;

use serde_json::json;

/// The MCP server name agents see: the cmux server.
pub(crate) const SERVER: &str = "cmux";

/// The Computer Use server folded behind it (acpmux `computer_use::SERVER_NAME`).
const COMPUTER_USE_SERVER: &str = "cmux-computer-use";

/// The env `cmux mcp serve` reads its folded servers from (`cli/mcp/upstream.rs`).
const UPSTREAMS_ENV: &str = "CMUX_MCP_UPSTREAMS";
/// Marks a terminal agent's server (`cli/mcp.rs` `TERMINAL_AGENT_ENV`).
const TERMINAL_AGENT_ENV: &str = "CMUX_MCP_TERMINAL_AGENT";
/// `0` lists every cmux tool instead of code mode (acpmux `agent_tools::CODE_MODE_ENV`).
const CODE_MODE_ENV: &str = "CMUX_MCP_CODE_MODE";
/// A Computer Use call may wait for the person's approval card, plus the bridge's retries.
const COMPUTER_USE_CALL_TIMEOUT_SECS: u64 = 900;

/// The pane's routing env the server needs to reach this cmux: Claude Code
/// passes its own env to a stdio server, Codex only an allowlist plus `env`.
const PASSED_ENV: [&str; 5] = [
    "CMUX_TUI_TERMINAL_ID",
    "CMUX_SOCKET_PATH",
    "CMUX_BUNDLE_ID",
    "CMUX_TAG",
    "CMUX_NEXT_CONFIG_FILE",
];

/// The server's arguments after the executable.
fn args(getenv: &dyn Fn(&str) -> Option<OsString>) -> Vec<&'static str> {
    let all_tools = getenv(CODE_MODE_ENV).is_some_and(|v| v.to_str().map(str::trim) == Some("0"));
    if all_tools { vec!["mcp", "serve", "--all-tools"] } else { vec!["mcp", "serve"] }
}

/// The server's env: the pane's socket, the terminal-agent mark, the Computer
/// Use bridge as its folded server, and the pane's routing env that is set.
fn env(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<Vec<(String, String)>> {
    let executable = executable.to_str()?;
    let socket = socket.to_str()?;
    let upstreams = json!([{
        "name": COMPUTER_USE_SERVER,
        "command": executable,
        "args": ["computer-use", "mcp"],
        "env": {"CMUX_TUI_SOCKET": socket},
        "callTimeoutSecs": COMPUTER_USE_CALL_TIMEOUT_SECS,
    }]);
    let mut env = vec![
        ("CMUX_TUI_SOCKET".to_owned(), socket.to_owned()),
        (TERMINAL_AGENT_ENV.to_owned(), "1".to_owned()),
        (UPSTREAMS_ENV.to_owned(), upstreams.to_string()),
    ];
    for key in PASSED_ENV {
        if let Some(value) =
            getenv(key).and_then(|v| v.into_string().ok()).filter(|v| !v.is_empty())
        {
            env.push((key.to_owned(), value));
        }
    }
    Some(env)
}

fn process_env(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

/// Codex `-c` overrides that add the server (TOML values).
pub(crate) fn codex_settings(executable: &Path, socket: &Path) -> Option<Vec<OsString>> {
    codex_settings_with(executable, socket, &process_env)
}

fn codex_settings_with(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<Vec<OsString>> {
    let env = env(executable, socket, getenv)?;
    let command = toml::Value::String(executable.to_str()?.to_owned());
    let args = toml::Value::Array(
        args(getenv).into_iter().map(|a| toml::Value::String(a.to_owned())).collect(),
    );
    let table = env
        .iter()
        .map(|(k, v)| format!("{k}={}", toml::Value::String(v.clone())))
        .collect::<Vec<_>>()
        .join(",");
    Some(vec![
        OsString::from(format!("mcp_servers.{SERVER}.command={command}")),
        OsString::from(format!("mcp_servers.{SERVER}.args={args}")),
        OsString::from(format!("mcp_servers.{SERVER}.env={{{table}}}")),
    ])
}

/// Claude Code's `--mcp-config` value (inline JSON) that adds the server.
pub(crate) fn claude_mcp_config(executable: &Path, socket: &Path) -> Option<OsString> {
    claude_mcp_config_with(executable, socket, &process_env)
}

fn claude_mcp_config_with(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<OsString> {
    let env: serde_json::Map<String, serde_json::Value> =
        env(executable, socket, getenv)?.into_iter().map(|(k, v)| (k, json!(v))).collect();
    let config = json!({
        "mcpServers": {
            SERVER: {
                "command": executable.to_str()?,
                "args": args(getenv),
                "env": env,
            }
        }
    });
    Some(OsString::from(config.to_string()))
}

#[cfg(test)]
mod tests {
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
        assert_eq!(only[0]["callTimeoutSecs"], COMPUTER_USE_CALL_TIMEOUT_SECS);
    }

    #[test]
    fn codex_gets_one_cmux_server_with_computer_use_behind_it() {
        let settings =
            codex_settings_with(Path::new("/A pp/cmux"), Path::new("/tmp/s \"q\".sock"), &pane)
                .unwrap();
        assert_eq!(settings.len(), 3);
        let mut merged = toml::Table::new();
        for setting in &settings {
            let text = setting.to_str().unwrap();
            assert!(!text.contains(COMPUTER_USE_SERVER) || text.contains(".env="), "{text}");
            let parsed: toml::Table = toml::from_str(text).unwrap();
            let servers = parsed["mcp_servers"].as_table().unwrap();
            assert_eq!(servers.keys().collect::<Vec<_>>(), [SERVER], "{text}");
            for (k, v) in servers[SERVER].as_table().unwrap() {
                merged.insert(k.clone(), v.clone());
            }
        }
        assert_eq!(merged["command"].as_str(), Some("/A pp/cmux"));
        assert_eq!(merged["args"], toml::Value::try_from(["mcp", "serve"]).unwrap());
        let env = merged["env"].as_table().unwrap();
        assert_eq!(env["CMUX_TUI_SOCKET"].as_str(), Some("/tmp/s \"q\".sock"));
        assert_eq!(env[TERMINAL_AGENT_ENV].as_str(), Some("1"));
        assert_eq!(env["CMUX_TUI_TERMINAL_ID"].as_str(), Some("term_7"));
        assert_eq!(env["CMUX_SOCKET_PATH"].as_str(), Some("/tmp/app.sock"));
        assert!(env.get("CMUX_TAG").is_none(), "an unset pane env is left out");
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
}
