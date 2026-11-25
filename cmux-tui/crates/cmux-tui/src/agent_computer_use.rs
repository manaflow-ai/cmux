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
//!
//! Both agents get it under the name `cmux`, so an agent never has two cmux
//! servers, also where the person's own config has an entry named `cmux` (a
//! global entry an older cmux wrote, one `cmux acp desktop link` wrote, or
//! a server of their own), checked live with Claude Code 2.1.310 and Codex
//! 0.160.1 and 0.169.0 (cmux-tui/scripts/mcp-launch-check.sh):
//!
//! - Claude Code: a `--mcp-config` server replaces a server of the same name
//!   in the user, project (`.mcp.json`) and local scopes whole; only the
//!   shim's starts, with none of the other's settings.
//! - Codex: `-c mcp_servers.cmux.…` merges key by key into a `cmux` entry
//!   its config layers make (user, `--profile` file, project, plugin). The
//!   shim sends this build's `command`, `args`, `env` (each key), `cwd` (the
//!   launch folder) and `enabled = true`, so those win, and only this
//!   build's server starts. Fields of the person's entry the shim does not
//!   send stay for that launch: other `env` keys, `env_vars`,
//!   `startup_timeout_sec`, `tool_timeout_sec`, `enabled_tools` and
//!   `disabled_tools` (a list there limits this build's tools too),
//!   `environment_id` (which sends the server to a remote executor),
//!   `required` and `scopes`. The acpmux guest mode a `cmux acp desktop
//!   link` entry carries in its env is sent empty (`cmux_server`). A
//!   person's own HTTP server named `cmux`, as the launch's Codex itself
//!   answers (`codex mcp get cmux --json`; acpmux codex_cmux_entry.rs),
//!   cannot merge: Codex refuses a command with a url, so there the shim
//!   passes no server and the person's keeps the name. An agent chat's Codex follows the same
//!   rule (acpmux agent_tools.rs `acp_servers_for`).
//!
//! In a cmux terminal, with cmux's tools on for agents started in cmux
//! (`agents.cmuxMcp`, on unless `off`), this build's server takes the name
//! `cmux` for the launch; outside cmux terminals, and with the setting off,
//! the person's configs are untouched. cmux never writes them on its own:
//! only `cmux acp desktop link` and `cmux acp bridge connect` do, when the
//! person runs them, and Settings' Remove takes out a `cmux` entry that runs
//! `cmux mcp serve` (`cmux setup mcp --remove`), on the person's click.
//!
//! "Always allow" on a tool of the shim's server is not written to any
//! config: Codex 0.160.1 persists an MCP tool approval only for a server a
//! user (`config.toml`, profile) or project layer configures
//! (core/src/mcp_tool_call.rs `persist_non_app_mcp_tool_approval`,
//! `user_mcp_server_is_configured` over `effective_user_config`, which
//! holds no `-c` flags); for a `-c` server it logs "failed to persist MCP
//! tool approval" and keeps the approval for the session only.

use std::ffi::OsString;
use std::path::Path;

use serde_json::json;

/// The MCP server name agents see: the cmux server (acpmux's [`acpmux::agent_tools::CMUX_SERVER`]).
pub(crate) const SERVER: &str = acpmux::agent_tools::CMUX_SERVER;

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
/// The settings file (`CMUX_NEXT_CONFIG_FILE`) comes with the shared server
/// definition ([`server`]).
const PASSED_ENV: [&str; 4] =
    ["CMUX_TUI_TERMINAL_ID", "CMUX_SOCKET_PATH", "CMUX_BUNDLE_ID", "CMUX_TAG"];

/// The Computer Use bridge's session env (acpmux `computer_use::mcp::SESSION_ENV`).
const SESSION_ENV: &str = "ACPMUX_COMPUTER_USE_SESSION";

/// The Computer Use session of the agent this launch starts: its terminal and
/// its pid (the wrapper execs into the agent, so this process's pid is the
/// agent's). It is the same across the agent's MCP reconnects, so the person's
/// Stop (the menu bar) holds for that agent instead of a new random session
/// each time the bridge restarts. Without a terminal id: none, and the bridge
/// picks its own.
fn session(getenv: &dyn Fn(&str) -> Option<OsString>, pid: u32) -> Option<String> {
    let terminal = getenv("CMUX_TUI_TERMINAL_ID")
        .and_then(|v| v.into_string().ok())
        .filter(|v| !v.is_empty())?;
    Some(format!("terminal:{terminal}:{pid}"))
}

/// This launch's `cmux` server: acpmux's one definition for every agent cmux
/// starts ([`acpmux::agent_tools::cmux_server`]: the name, this CLI's `mcp
/// serve`, the pane's settings file), plus the pane's own routing env: its
/// socket, the terminal-agent mark, the Computer Use bridge as its folded
/// server, and the pane's routing env that is set.
fn server(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<acpmux::agent_tools::McpServer> {
    let socket = socket.to_str()?;
    let all_tools = getenv(CODE_MODE_ENV).is_some_and(|v| v.to_str().map(str::trim) == Some("0"));
    // The pane's settings file, else the one this CLI resolves (the shared file): always named.
    let settings_file = getenv(cmux_tui_core::user_settings::CONFIG_OVERRIDE)
        .filter(|v| !v.is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(cmux_tui_core::user_settings::config_path);
    let mut server = acpmux::agent_tools::cmux_server(executable, all_tools, &settings_file);
    let mut bridge_env = serde_json::Map::new();
    bridge_env.insert("CMUX_TUI_SOCKET".into(), json!(socket));
    if let Some(session) = session(getenv, std::process::id()) {
        bridge_env.insert(SESSION_ENV.into(), json!(session));
    }
    let upstreams = json!([{
        "name": COMPUTER_USE_SERVER,
        "command": executable.to_str()?,
        "args": ["computer-use", "mcp"],
        "env": bridge_env,
        "callTimeoutSecs": COMPUTER_USE_CALL_TIMEOUT_SECS,
    }]);
    server.env.extend([
        ("CMUX_TUI_SOCKET".to_owned(), socket.to_owned()),
        (TERMINAL_AGENT_ENV.to_owned(), "1".to_owned()),
        (UPSTREAMS_ENV.to_owned(), upstreams.to_string()),
    ]);
    for key in PASSED_ENV {
        if let Some(value) =
            getenv(key).and_then(|v| v.into_string().ok()).filter(|v| !v.is_empty())
        {
            server.env.push((key.to_owned(), value));
        }
    }
    Some(server)
}

fn process_env(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

/// Codex `-c` overrides (TOML values) that give this launch this build's
/// server under the name `cmux`: its command, args, each env key, the launch
/// folder `cwd` as its working folder, and `enabled = true`, all of which win
/// over the same keys of a `cmux` entry in the person's config (module docs).
/// `getenv` reads the pane's environment.
pub(crate) fn codex_settings(
    executable: &Path,
    socket: &Path,
    cwd: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<Vec<OsString>> {
    let server = server(executable, socket, getenv)?;
    let string = |value: &str| toml::Value::String(value.to_owned());
    let mut values = vec![
        ("command".to_owned(), string(server.command.to_str()?)),
        (
            "args".to_owned(),
            toml::Value::Array(server.args.iter().map(|arg| string(arg)).collect()),
        ),
        ("cwd".to_owned(), string(cwd.to_str()?)),
        ("enabled".to_owned(), toml::Value::Boolean(true)),
    ];
    values.extend(
        server
            .env
            .into_iter()
            .map(|(key, value)| (format!("env.{key}"), toml::Value::String(value))),
    );
    Some(
        values
            .into_iter()
            .map(|(key, value)| OsString::from(format!("mcp_servers.{SERVER}.{key}={value}")))
            .collect(),
    )
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
    let server = server(executable, socket, getenv)?;
    let env: serde_json::Map<String, serde_json::Value> =
        server.env.into_iter().map(|(k, v)| (k, json!(v))).collect();
    let config = json!({
        "mcpServers": {
            server.name: {
                "command": server.command.to_str()?,
                "args": server.args,
                "env": env,
            }
        }
    });
    Some(OsString::from(config.to_string()))
}

#[cfg(test)]
#[path = "agent_computer_use_tests.rs"]
mod tests;
