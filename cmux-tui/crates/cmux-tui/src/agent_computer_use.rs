//! cmux Computer Use for agents started in a terminal pane. The `claude` and
//! `codex` shims (claude_wrapper.rs, codex_wrapper.rs) already pass cmux's
//! hooks for each launch; they also pass the `cmux-computer-use` MCP server,
//! so an agent typed into a cmux terminal has cmux Computer Use with no
//! setup, the same as one in a cmux agent chat. The server is this build's
//! own `cmux computer-use mcp`, pointed at this pane's daemon socket: it asks
//! that daemon for the worker and serves the tools even while the worker
//! starts. The person's Computer Use settings (mode off, deny list) still
//! decide what runs.

use std::ffi::OsString;
use std::path::Path;

use serde_json::json;

/// The MCP server name agents see (acpmux `computer_use::SERVER_NAME`).
pub(crate) const SERVER: &str = "cmux-computer-use";

/// The arguments that start the server, after the executable.
const ARGS: [&str; 2] = ["computer-use", "mcp"];

/// Codex `-c` overrides that add the server (TOML values).
pub(crate) fn codex_settings(executable: &Path, socket: &Path) -> Option<Vec<OsString>> {
    let executable = toml::Value::String(executable.to_str()?.to_owned());
    let socket = toml::Value::String(socket.to_str()?.to_owned());
    let args = toml::Value::Array(ARGS.iter().map(|a| toml::Value::String((*a).into())).collect());
    Some(vec![
        OsString::from(format!("mcp_servers.{SERVER}.command={executable}")),
        OsString::from(format!("mcp_servers.{SERVER}.args={args}")),
        OsString::from(format!("mcp_servers.{SERVER}.env={{CMUX_TUI_SOCKET={socket}}}")),
    ])
}

/// Claude Code's `--mcp-config` value (inline JSON) that adds the server.
pub(crate) fn claude_mcp_config(executable: &Path, socket: &Path) -> Option<OsString> {
    let config = json!({
        "mcpServers": {
            SERVER: {
                "command": executable.to_str()?,
                "args": ARGS,
                "env": {"CMUX_TUI_SOCKET": socket.to_str()?},
            }
        }
    });
    Some(OsString::from(config.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_overrides_are_valid_toml_with_the_socket() {
        let settings =
            codex_settings(Path::new("/A pp/cmux"), Path::new("/tmp/s \"q\".sock")).unwrap();
        assert_eq!(settings.len(), 3);
        for setting in &settings {
            let text = setting.to_str().unwrap();
            let parsed: toml::Table = toml::from_str(text).unwrap();
            assert!(parsed["mcp_servers"][SERVER].is_table(), "{text}");
        }
        let env: toml::Table = toml::from_str(settings[2].to_str().unwrap()).unwrap();
        assert_eq!(
            env["mcp_servers"][SERVER]["env"]["CMUX_TUI_SOCKET"].as_str(),
            Some("/tmp/s \"q\".sock")
        );
    }

    #[test]
    fn claude_config_names_the_server_and_the_socket() {
        let config = claude_mcp_config(Path::new("/A/cmux"), Path::new("/tmp/s.sock")).unwrap();
        let value: serde_json::Value = serde_json::from_str(config.to_str().unwrap()).unwrap();
        let server = &value["mcpServers"][SERVER];
        assert_eq!(server["command"], "/A/cmux");
        assert_eq!(server["args"], json!(["computer-use", "mcp"]));
        assert_eq!(server["env"]["CMUX_TUI_SOCKET"], "/tmp/s.sock");
    }
}
