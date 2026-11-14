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
//! Which server the agent uses when the person's own config also has one
//! named `cmux` (a global entry another cmux wrote), checked live with
//! Claude Code 2.1.310 and Codex 0.160.1 (cmux-tui/scripts/mcp-precedence-check.sh):
//!
//! - Claude Code: a `--mcp-config` server replaces a user-scope server of the
//!   same name whole; only the shim's starts. So the shim keeps the name `cmux`
//!   (the tools stay `mcp__cmux__*`).
//! - Codex: `-c mcp_servers.cmux.…` merges key by key into the config.toml
//!   entry: the shim's `command`, `args` and `env` keys win, but every other
//!   key of the person's entry stays (`cwd`, `startup_timeout_sec`,
//!   `enabled_tools`, other `env` keys). So the shim keeps `cmux` only when
//!   the person's entry has nothing the shim does not overwrite; otherwise it
//!   passes its server as [`CODEX_TERMINAL_SERVER`], and turns the person's
//!   `cmux` entry off for this launch (`enabled=false`) when that entry is
//!   another cmux's server, so the agent never gets two cmux servers. A server
//!   of the person's own that is only named `cmux` stays on.

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

/// The server's env: the pane's socket, the terminal-agent mark, the Computer
/// Use bridge as its folded server, and the pane's routing env that is set.
fn env(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<Vec<(String, String)>> {
    let executable = executable.to_str()?;
    let socket = socket.to_str()?;
    let mut bridge_env = serde_json::Map::new();
    bridge_env.insert("CMUX_TUI_SOCKET".into(), json!(socket));
    if let Some(session) = session(getenv, std::process::id()) {
        bridge_env.insert(SESSION_ENV.into(), json!(session));
    }
    let upstreams = json!([{
        "name": COMPUTER_USE_SERVER,
        "command": executable,
        "args": ["computer-use", "mcp"],
        "env": bridge_env,
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

/// The name Codex gets this build's server under when the person's own
/// `[mcp_servers.cmux]` would merge settings into it (module docs).
pub(crate) const CODEX_TERMINAL_SERVER: &str = "cmux_terminal";

/// Codex `-c` overrides that add the server (TOML values).
pub(crate) fn codex_settings(executable: &Path, socket: &Path) -> Option<Vec<OsString>> {
    codex_settings_with(executable, socket, &process_env)
}

/// The person's own `[mcp_servers.cmux]` in `$CODEX_HOME/config.toml`
/// (`~/.codex` without `CODEX_HOME`), when there is one.
fn codex_config_entry(getenv: &dyn Fn(&str) -> Option<OsString>) -> Option<toml::Table> {
    let dir = |key: &str| getenv(key).filter(|v| !v.is_empty()).map(std::path::PathBuf::from);
    let home = dir("CODEX_HOME").or_else(|| dir("HOME").map(|home| home.join(".codex")))?;
    let text = std::fs::read_to_string(home.join("config.toml")).ok()?;
    let config: toml::Table = text.parse().ok()?;
    config.get("mcp_servers")?.as_table()?.get(SERVER)?.as_table().cloned()
}

/// Whether a Codex entry runs `cmux mcp serve`, from any cmux build's CLI.
fn serves_cmux(entry: &toml::Table) -> bool {
    let program = entry.get("command").and_then(toml::Value::as_str).map(Path::new);
    let named = program.and_then(Path::file_name).and_then(|name| name.to_str());
    let args: Vec<&str> = entry
        .get("args")
        .and_then(toml::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(toml::Value::as_str)
        .take(2)
        .collect();
    named.is_some_and(|name| name.starts_with("cmux")) && args == ["mcp", "serve"]
}

/// The name this build's server goes under in Codex, and whether the
/// person's `cmux` entry is turned off for this launch: `cmux` when there is
/// no entry, or one of another cmux whose every setting the shim's
/// `command`, `args` and `env` (`env_keys`) overwrite;
/// [`CODEX_TERMINAL_SERVER`] otherwise, turning the entry off when it is
/// another cmux's server (module docs).
fn codex_placement(existing: Option<&toml::Table>, env_keys: &[&str]) -> (&'static str, bool) {
    let Some(entry) = existing else { return (SERVER, false) };
    let overwritten = entry.iter().all(|(key, value)| match key.as_str() {
        "command" | "args" => true,
        "env" => value
            .as_table()
            .is_some_and(|env| env.keys().all(|key| env_keys.contains(&key.as_str()))),
        _ => false,
    });
    let cmux = serves_cmux(entry);
    if cmux && overwritten { (SERVER, false) } else { (CODEX_TERMINAL_SERVER, cmux) }
}

fn codex_settings_with(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<Vec<OsString>> {
    let env = env(executable, socket, getenv)?;
    let env_keys: Vec<&str> = env.iter().map(|(key, _)| key.as_str()).collect();
    let (name, disable) = codex_placement(codex_config_entry(getenv).as_ref(), &env_keys);
    let command = toml::Value::String(executable.to_str()?.to_owned());
    let args = toml::Value::Array(
        args(getenv).into_iter().map(|a| toml::Value::String(a.to_owned())).collect(),
    );
    let table = env
        .iter()
        .map(|(k, v)| format!("{k}={}", toml::Value::String(v.clone())))
        .collect::<Vec<_>>()
        .join(",");
    let mut settings = vec![
        OsString::from(format!("mcp_servers.{name}.command={command}")),
        OsString::from(format!("mcp_servers.{name}.args={args}")),
        OsString::from(format!("mcp_servers.{name}.env={{{table}}}")),
    ];
    if disable {
        settings.push(OsString::from(format!("mcp_servers.{SERVER}.enabled=false")));
    }
    Some(settings)
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

    /// The `-c` overrides as one merged table per server name.
    fn servers(settings: &[OsString]) -> toml::Table {
        let mut merged = toml::Table::new();
        for setting in settings {
            let parsed: toml::Table = toml::from_str(setting.to_str().unwrap()).unwrap();
            for (name, server) in parsed["mcp_servers"].as_table().unwrap() {
                let into = merged
                    .entry(name.clone())
                    .or_insert_with(|| toml::Value::Table(toml::Table::new()));
                for (k, v) in server.as_table().unwrap() {
                    into.as_table_mut().unwrap().insert(k.clone(), v.clone());
                }
            }
        }
        merged
    }

    /// Codex merges `-c mcp_servers.cmux.…` into the person's own
    /// `[mcp_servers.cmux]` key by key (checked live,
    /// cmux-tui/scripts/mcp-precedence-check.sh). The shim keeps the name
    /// `cmux` only when that entry has nothing it does not overwrite; else its
    /// server is `cmux_terminal`, and another cmux's entry is turned off for
    /// the launch, never a server of the person's own.
    #[test]
    fn codex_never_merges_the_persons_cmux_settings_into_this_builds_server() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("config.toml");
        let with = |text: Option<&str>| {
            match text {
                Some(text) => std::fs::write(&config, text).unwrap(),
                None => drop(std::fs::remove_file(&config)),
            }
            let home = dir.path().to_owned();
            let getenv = move |name: &str| match name {
                "CODEX_HOME" => Some(home.clone().into_os_string()),
                other => pane(other),
            };
            servers(
                &codex_settings_with(Path::new("/A/cmux"), Path::new("/tmp/s.sock"), &getenv)
                    .unwrap(),
            )
        };
        let names = |servers: &toml::Table| servers.keys().cloned().collect::<Vec<_>>();

        // No entry, or another cmux's plain entry: the name stays `cmux`.
        let none = with(None);
        assert_eq!(names(&none), [SERVER]);
        let plain = with(Some(
            "[mcp_servers.cmux]\ncommand = \"/Applications/cmux.app/Contents/Resources/bin/cmux\"\nargs = [\"mcp\", \"serve\"]\n[mcp_servers.cmux.env]\nCMUX_TUI_SOCKET = \"/old.sock\"\n",
        ));
        assert_eq!(names(&plain), [SERVER], "{plain}");
        assert!(plain[SERVER].get("enabled").is_none(), "{plain}");
        // An env key the shim does not set would stay on its server: a new name.
        let tagged = with(Some(
            "[mcp_servers.cmux]\ncommand = \"/opt/cmux\"\nargs = [\"mcp\", \"serve\"]\n[mcp_servers.cmux.env]\nCMUX_TAG = \"x\"\n",
        ));
        assert_eq!(tagged[SERVER]["enabled"].as_bool(), Some(false), "{tagged}");
        assert!(tagged.contains_key(CODEX_TERMINAL_SERVER), "{tagged}");

        // Another cmux's entry with settings the shim would not overwrite:
        // this build's server goes under its own name, and that entry is off.
        for extra in [
            "cwd = \"/w\"",
            "startup_timeout_sec = 7",
            "enabled_tools = [\"a\"]",
            "[mcp_servers.cmux.env]\nUSER_ONLY = \"x\"",
        ] {
            let merged = with(Some(&format!(
                "[mcp_servers.cmux]\ncommand = \"/opt/cmux\"\nargs = [\"mcp\", \"serve\"]\n{extra}\n"
            )));
            assert_eq!(
                merged[CODEX_TERMINAL_SERVER]["command"].as_str(),
                Some("/A/cmux"),
                "{extra}"
            );
            assert_eq!(merged[SERVER]["enabled"].as_bool(), Some(false), "{extra}: {merged}");
            assert_eq!(merged[SERVER].as_table().unwrap().len(), 1, "only `enabled`: {merged}");
        }

        // A server of the person's own named `cmux`: kept on, never replaced.
        let own =
            with(Some("[mcp_servers.cmux]\ncommand = \"/usr/bin/my-tool\"\nargs = [\"x\"]\n"));
        assert_eq!(names(&own), [CODEX_TERMINAL_SERVER], "{own}");
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
