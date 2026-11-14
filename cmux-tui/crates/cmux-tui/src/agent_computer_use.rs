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
//! - Claude Code: a `--mcp-config` server replaces a server of the same name
//!   in the user, project (`.mcp.json`) and local scopes whole; only the
//!   shim's starts, with none of the other's settings. So the shim keeps the
//!   name `cmux` (the tools stay `mcp__cmux__*`). That includes a server of
//!   the person's own that is only named `cmux`: in a cmux terminal, with the
//!   person's yes to cmux's tools, this build's server takes that name for
//!   the launch. Outside cmux terminals, and with the answer off, the
//!   person's server is untouched.
//! - Codex: `-c mcp_servers.cmux.…` merges key by key into the entry its
//!   config layers make ([`codex_layers`]): the shim's `command`, `args` and `env` keys win, but every other
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

/// What of a Codex launch decides which config layers it loads: the folder
/// it starts in (project layers) and the profile it names (`--profile`).
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct CodexLaunch<'a> {
    pub cwd: Option<&'a Path>,
    pub profile: Option<&'a str>,
}

/// The profile Codex's own arguments name: `-p NAME`, `--profile NAME` or
/// `--profile=NAME` (Codex reads no environment variable for it).
pub(crate) fn codex_profile(args: &[OsString]) -> Option<&str> {
    let mut args = args.iter().filter_map(|arg| arg.to_str());
    while let Some(arg) = args.next() {
        if arg == "--" {
            return None;
        }
        if arg == "-p" || arg == "--profile" {
            return args.next();
        }
        if let Some(name) = arg.strip_prefix("--profile=") {
            return Some(name);
        }
    }
    None
}

/// Codex `-c` overrides that add the server (TOML values).
pub(crate) fn codex_settings(
    executable: &Path,
    socket: &Path,
    launch: CodexLaunch<'_>,
) -> Option<Vec<OsString>> {
    codex_settings_with(executable, socket, &process_env, launch)
}

/// Codex's system folder: `/etc/codex` (its `config.toml`, the lowest layer,
/// and the legacy `managed_config.toml`, which wins over everything).
const CODEX_SYSTEM_DIR: &str = "/etc/codex";

/// The config files Codex 0.160 merges into `[mcp_servers.cmux]`, lowest
/// first, as checked live (cmux-tui/scripts/mcp-precedence-check.sh): the
/// system `config.toml`; `$CODEX_HOME/config.toml` (`~/.codex`); with
/// `--profile NAME`, `$CODEX_HOME/NAME.config.toml`; then, for a project the
/// user config trusts (`[projects."<root>"] trust_level = "trusted"`), each
/// `.codex/config.toml` from the project root (the nearest folder above the
/// launch folder with `.git`, else the launch folder) down to the launch
/// folder; then the shim's `-c` flags; last the legacy `managed_config.toml`.
/// The legacy `[profiles.*]` tables hold no MCP servers Codex uses.
fn codex_layers(
    getenv: &dyn Fn(&str) -> Option<OsString>,
    launch: CodexLaunch<'_>,
    system: &Path,
) -> Vec<std::path::PathBuf> {
    let dir = |key: &str| getenv(key).filter(|v| !v.is_empty()).map(std::path::PathBuf::from);
    let mut layers = vec![system.join("config.toml")];
    let home = dir("CODEX_HOME").or_else(|| dir("HOME").map(|home| home.join(".codex")));
    if let Some(home) = &home {
        layers.push(home.join("config.toml"));
        if let Some(profile) = launch.profile.filter(|p| !p.is_empty() && !p.contains('/')) {
            layers.push(home.join(format!("{profile}.config.toml")));
        }
    }
    if let (Some(cwd), Some(home)) = (launch.cwd, &home) {
        let root = cwd.ancestors().find(|dir| dir.join(".git").exists()).unwrap_or(cwd);
        let user: Option<toml::Table> = std::fs::read_to_string(home.join("config.toml"))
            .ok()
            .and_then(|text| text.parse().ok());
        let trusted = user
            .as_ref()
            .and_then(|config| {
                config
                    .get("projects")?
                    .as_table()?
                    .get(root.to_str()?)?
                    .get("trust_level")?
                    .as_str()
                    .map(str::to_owned)
            })
            .is_some_and(|level| level == "trusted");
        if trusted {
            let mut chain: Vec<&Path> =
                cwd.ancestors().take_while(|dir| dir.starts_with(root)).collect();
            chain.reverse();
            layers.extend(chain.into_iter().map(|dir| dir.join(".codex").join("config.toml")));
        }
    }
    layers.push(system.join("managed_config.toml"));
    layers
}

/// Merges `from` into `into` the way Codex merges config layers: tables key
/// by key, any other value replaced.
fn merge_toml(into: &mut toml::Table, from: &toml::Table) {
    for (key, value) in from {
        match (into.get_mut(key), value) {
            (Some(toml::Value::Table(old)), toml::Value::Table(new)) => merge_toml(old, new),
            _ => {
                into.insert(key.clone(), value.clone());
            }
        }
    }
}

/// The person's own `[mcp_servers.cmux]` as Codex sees it for this launch
/// (every [`codex_layers`] layer merged, the shim's flags aside), when any
/// layer has one.
fn codex_config_entry(
    getenv: &dyn Fn(&str) -> Option<OsString>,
    launch: CodexLaunch<'_>,
    system: &Path,
) -> Option<toml::Table> {
    let mut entry: Option<toml::Table> = None;
    for layer in codex_layers(getenv, launch, system) {
        let Some(config) =
            std::fs::read_to_string(&layer).ok().and_then(|t| t.parse::<toml::Table>().ok())
        else {
            continue;
        };
        if let Some(cmux) =
            config.get("mcp_servers").and_then(|s| s.get(SERVER)).and_then(toml::Value::as_table)
        {
            merge_toml(entry.get_or_insert_with(toml::Table::new), cmux);
        }
    }
    entry
}

/// What an MCP server entry runs when it runs cmux's server (`cmux mcp
/// serve`): which entries count as cmux's own, from any build or install.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CmuxServe<'a> {
    /// A cmux CLI (`…/cmux mcp serve`, a bare `cmux` on PATH, an npm or PyPI
    /// console script named `cmux…`), or the launcher script a JavaScript
    /// runtime runs (`node …/cmux.js mcp serve`): this path.
    Path(&'a str),
    /// A package runner that fetches a published cmux each time (`npx [-y]
    /// cmux mcp serve`, `bunx`, `pnpm dlx`, `uvx`, `pipx run`).
    Published,
}

/// [`CmuxServe`] of an entry that runs `command args`, or `None` when it runs
/// no cmux server.
pub(crate) fn cmux_serve<'a>(command: &'a str, args: &'a [String]) -> Option<CmuxServe<'a>> {
    let base = |path: &str| Path::new(path).file_name().and_then(|n| n.to_str()).map(str::to_owned);
    let serves = |rest: &[String]| rest.iter().map(String::as_str).take(2).eq(["mcp", "serve"]);
    let is_cmux = |name: &str| name.starts_with("cmux");
    let program = base(command)?;
    if is_cmux(&program) {
        return serves(args).then_some(CmuxServe::Path(command));
    }
    // A runtime and its script.
    if matches!(program.as_str(), "node" | "nodejs" | "bun") {
        let (script, rest) = args.split_first()?;
        return (base(script).is_some_and(|s| is_cmux(&s)) && serves(rest))
            .then_some(CmuxServe::Path(script.as_str()));
    }
    // A package runner: its own flags, then the package, then its args.
    let after = match program.as_str() {
        "npx" | "bunx" | "pnpx" | "uvx" => args,
        "pnpm" if args.first().is_some_and(|a| a == "dlx") => &args[1..],
        "pipx" if args.first().is_some_and(|a| a == "run") => &args[1..],
        _ => return None,
    };
    let mut rest = after;
    while let Some((first, tail)) = rest.split_first() {
        if !first.starts_with('-') {
            break;
        }
        // `--spec X`, `--package X`, `--from X`: a flag with its value.
        let takes_value = matches!(first.as_str(), "--spec" | "--package" | "-p" | "--from");
        rest = if takes_value { tail.get(1..).unwrap_or_default() } else { tail };
    }
    let (package, rest) = rest.split_first()?;
    (is_cmux(package) && serves(rest)).then_some(CmuxServe::Published)
}

/// Whether a Codex entry runs `cmux mcp serve`, from any cmux build or
/// install ([`cmux_serve`]).
fn serves_cmux(entry: &toml::Table) -> bool {
    let Some(command) = entry.get("command").and_then(toml::Value::as_str) else {
        return false;
    };
    let args: Vec<String> = entry
        .get("args")
        .and_then(toml::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(toml::Value::as_str)
        .map(str::to_owned)
        .collect();
    cmux_serve(command, &args).is_some()
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

/// [`codex_settings`] with the environment `getenv` (tests).
pub(crate) fn codex_settings_with(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
    launch: CodexLaunch<'_>,
) -> Option<Vec<OsString>> {
    codex_settings_in(executable, socket, getenv, launch, Path::new(CODEX_SYSTEM_DIR))
}

fn codex_settings_in(
    executable: &Path,
    socket: &Path,
    getenv: &dyn Fn(&str) -> Option<OsString>,
    launch: CodexLaunch<'_>,
    system: &Path,
) -> Option<Vec<OsString>> {
    let env = env(executable, socket, getenv)?;
    let env_keys: Vec<&str> = env.iter().map(|(key, _)| key.as_str()).collect();
    let existing = codex_config_entry(getenv, launch, system);
    let (name, disable) = codex_placement(existing.as_ref(), &env_keys);
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
        let settings = codex_settings_with(
            Path::new("/A pp/cmux"),
            Path::new("/tmp/s \"q\".sock"),
            &pane,
            CodexLaunch::default(),
        )
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
            let system = dir.path().join("etc");
            servers(
                &codex_settings_in(
                    Path::new("/A/cmux"),
                    Path::new("/tmp/s.sock"),
                    &getenv,
                    CodexLaunch::default(),
                    &system,
                )
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

    /// The same placement for every layer Codex merges into
    /// `[mcp_servers.cmux]` (checked live with Codex 0.160.1): a profile file
    /// named by `--profile`, a trusted project's `.codex/config.toml` from the
    /// git root down to the launch folder, the system file and the legacy
    /// managed file. An untrusted project's layer, a layer above the project
    /// root and another profile's file do not count.
    #[test]
    fn codex_placement_reads_every_layer_codex_merges() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let (home, system, project) = (root.join("codex"), root.join("etc"), root.join("w/proj"));
        let cwd = project.join("sub");
        for folder in [&home, &system, &cwd, &project.join(".git")] {
            std::fs::create_dir_all(folder).unwrap();
        }
        let plain = "[mcp_servers.cmux]\ncommand = \"/opt/cmux\"\nargs = [\"mcp\", \"serve\"]\n";
        let trust =
            |path: &Path| format!("[projects.\"{}\"]\ntrust_level = \"trusted\"\n", path.display());
        let extra = "[mcp_servers.cmux]\ncwd = \"/elsewhere\"\n";
        let write = |path: std::path::PathBuf, text: &str| {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        };
        let names = |profile: Option<&str>| {
            let home = home.clone();
            let getenv = move |name: &str| match name {
                "CODEX_HOME" => Some(home.clone().into_os_string()),
                other => pane(other),
            };
            let launch = CodexLaunch { cwd: Some(&cwd), profile };
            let settings = codex_settings_in(
                Path::new("/A/cmux"),
                Path::new("/tmp/s.sock"),
                &getenv,
                launch,
                &system,
            )
            .unwrap();
            servers(&settings).keys().cloned().collect::<Vec<_>>()
        };
        let renamed = vec![SERVER.to_owned(), CODEX_TERMINAL_SERVER.to_owned()];
        write(home.join("config.toml"), plain);
        assert_eq!(names(None), [SERVER], "the user layer alone, plain");

        // A trusted project's layer, at its root or in the launch folder.
        for at in [project.join(".codex/config.toml"), cwd.join(".codex/config.toml")] {
            write(at.clone(), extra);
            write(home.join("config.toml"), plain);
            assert_eq!(names(None), [SERVER], "{at:?} untrusted: not loaded");
            write(home.join("config.toml"), &format!("{plain}{}", trust(&project)));
            assert_eq!(names(None), renamed, "{at:?} trusted");
            std::fs::remove_file(&at).unwrap();
        }
        // Above the project root: not a layer.
        write(root.join("w/.codex/config.toml"), extra);
        assert_eq!(names(None), [SERVER]);
        std::fs::remove_file(root.join("w/.codex/config.toml")).unwrap();

        // The profile file of `--profile`, and only that one.
        write(home.join("work.config.toml"), extra);
        assert_eq!(names(None), [SERVER]);
        assert_eq!(names(Some("work")), renamed);
        assert_eq!(names(Some("other")), [SERVER]);
        std::fs::remove_file(home.join("work.config.toml")).unwrap();

        // The system layers.
        for file in ["config.toml", "managed_config.toml"] {
            write(system.join(file), extra);
            assert_eq!(names(None), renamed, "{file}");
            std::fs::remove_file(system.join(file)).unwrap();
        }
    }

    #[test]
    fn codex_profile_is_read_from_codexs_own_arguments() {
        let os = |args: &[&str]| args.iter().map(OsString::from).collect::<Vec<_>>();
        assert_eq!(codex_profile(&os(&["-p", "work", "hi"])), Some("work"));
        assert_eq!(codex_profile(&os(&["--profile", "work"])), Some("work"));
        assert_eq!(codex_profile(&os(&["exec", "--profile=work", "x"])), Some("work"));
        assert_eq!(codex_profile(&os(&["hi"])), None);
        assert_eq!(codex_profile(&os(&["--", "-p", "x"])), None);
    }

    /// cmux's server is recognised however an entry runs it: the CLI, a
    /// launcher script under a JavaScript runtime, or a package runner.
    #[test]
    fn cmux_serve_knows_every_way_to_run_cmuxs_server() {
        let of = |command: &str, args: &[&str]| {
            let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
            cmux_serve(command, &args).map(|serve| match serve {
                CmuxServe::Path(path) => path.to_owned(),
                CmuxServe::Published => "published".to_owned(),
            })
        };
        let path = |p: &str| Some(p.to_owned());
        let published = Some("published".to_owned());
        assert_eq!(of("/A/cmux", &["mcp", "serve"]), path("/A/cmux"));
        assert_eq!(of("cmux", &["mcp", "serve", "--all-tools"]), path("cmux"));
        assert_eq!(
            of("/u/node", &["/n/node_modules/cmux/bin/cmux.js", "mcp", "serve"]),
            path("/n/node_modules/cmux/bin/cmux.js")
        );
        assert_eq!(of("npx", &["-y", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("npx", &["cmux@latest", "mcp", "serve"]), published);
        assert_eq!(of("bunx", &["cmux", "mcp", "serve"]), published);
        assert_eq!(of("pnpm", &["dlx", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("uvx", &["cmux", "mcp", "serve"]), published);
        assert_eq!(of("/x/uvx", &["--from", "cmux==1", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("pipx", &["run", "--spec", "cmux", "cmux", "mcp", "serve"]), published);
        for (command, args) in [
            ("/A/cmux", &["serve"][..]),
            ("/usr/bin/my-tool", &["mcp", "serve"]),
            ("node", &["/x/other.js", "mcp", "serve"]),
            ("npx", &["-y", "other", "mcp", "serve"]),
            ("pipx", &["install", "cmux"]),
        ] {
            assert_eq!(of(command, args), None, "{command} {args:?}");
        }
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
