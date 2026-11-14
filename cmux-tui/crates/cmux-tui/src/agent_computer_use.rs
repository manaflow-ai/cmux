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
//! - Codex: `-c mcp_servers.<name>.…` merges key by key into an entry of
//!   that name its config layers make, and `codex mcp get --json` does not
//!   print every field such an entry can carry. So the shim never shares a
//!   key with a config entry: its server is always [`CODEX_TERMINAL_SERVER`]
//!   (nothing in cmux depends on the Codex server's name: the bg hook and the
//!   `mcp__cmux__*` names are Claude Code's, and `cmux.` in `cmux_exec` is the
//!   script's own namespace). It asks Codex for the `cmux` entry before each
//!   launch (codex_mcp_entry.rs: `codex mcp get cmux --json` with the
//!   launch's folder and config arguments) only to turn that entry off for the
//!   launch (`enabled=false`) when it is another cmux's server and on, so the
//!   agent never gets two cmux servers. A server of the person's own that is
//!   only named `cmux` stays on, and so does an entry Codex could not report.
//!   Nothing is turned off when Codex has no answer, or when its answer does
//!   not describe the launch (a new `--worktree`, a resumed or forked
//!   session, a remote app server, no user config: codex_mcp_entry.rs
//!   `probe_matches_launch`): there `enabled=false` could name an entry the
//!   session never loads, which fails Codex with "invalid transport".
//!   In those cases, and when Codex loads an untrusted project's `cmux` entry
//!   only after its trust prompt, the person's cmux entry can start beside
//!   this build's server: a second cmux server for that session. Both are
//!   cmux's own, and each reaches the app its own CLI and environment name
//!   (the person's entry has no terminal socket, so its tools act for the
//!   app that entry's CLI belongs to). Nothing here arbitrates Computer Use
//!   between the two.
//!   "Always allow" on a tool of `cmux_terminal` is not written to any
//!   config: Codex 0.160.1 persists an MCP tool approval only for a server a
//!   user (`config.toml`, profile) or project layer configures
//!   (core/src/mcp_tool_call.rs `persist_non_app_mcp_tool_approval`,
//!   `user_mcp_server_is_configured` over `effective_user_config`, which
//!   holds no `-c` flags); for a `-c` server it logs "failed to persist MCP
//!   tool approval" and keeps the approval for the session only.

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

/// The name Codex gets this build's server under, always: no config entry
/// shares it, so nothing merges into it (module docs).
pub(crate) const CODEX_TERMINAL_SERVER: &str = "cmux_terminal";

/// The person's own `cmux` entry as Codex itself resolves it for a launch
/// ([`crate::codex_mcp_entry::resolve`]: `codex mcp get cmux --json` with the
/// launch's folder and config arguments).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum CodexEntry {
    /// Codex has no `cmux` entry.
    Absent,
    /// The entry, as `codex mcp get --json` prints it.
    Found(serde_json::Value),
    /// Codex could not say (no answer in time, an error, output it could not
    /// read): nothing is turned off.
    Unknown,
}

/// Codex `-c` overrides that add this build's server as
/// [`CODEX_TERMINAL_SERVER`] (TOML values), and turn the reported `cmux`
/// entry off when it is another cmux's server that is on ([`disables_cmux`]).
/// `getenv` reads the pane's environment.
pub(crate) fn codex_settings(
    executable: &Path,
    socket: &Path,
    existing: &CodexEntry,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Option<Vec<OsString>> {
    let env = env(executable, socket, getenv)?;
    let name = CODEX_TERMINAL_SERVER;
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
    if disables_cmux(existing) {
        settings.push(OsString::from(format!("mcp_servers.{SERVER}.enabled=false")));
    }
    Some(settings)
}

/// Whether the `cmux` entry Codex reported is turned off for the launch: only
/// another cmux's server ([`cmux_serve`]) that is on. Never a server of the
/// person's own, never an entry Codex did not report.
fn disables_cmux(existing: &CodexEntry) -> bool {
    matches!(existing, CodexEntry::Found(entry)
        if serves_cmux(entry) && entry["enabled"].as_bool() == Some(true))
}

/// What an MCP server entry runs when it runs cmux's server (`cmux mcp
/// serve`): which entries count as cmux's own, from any build or install.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum CmuxServe<'a> {
    /// A cmux CLI (`…/cmux mcp serve`, a bare `cmux` on PATH, an npm or PyPI
    /// console script named `cmux`), or the launcher script a JavaScript
    /// runtime runs (`node …/cmux.js mcp serve`): this path.
    Path(&'a str),
    /// A package runner that fetches a published cmux each time (`npx [-y]
    /// cmux mcp serve`, `bunx`, `pnpm dlx`, `uvx`, `pipx run`).
    Published,
}

/// The names cmux's CLI is installed under (the app's `cmux`, the
/// side-by-side `cmux-next`, the binary `cmux-tui`).
const CLI_NAMES: [&str; 3] = ["cmux", "cmux-next", "cmux-tui"];
/// cmux's npm launcher script.
const LAUNCHER_SCRIPT: &str = "cmux.js";
/// The package name cmux is published under, on npm and PyPI.
const PACKAGE: &str = "cmux";

/// Whether a package runner's package argument names cmux: `cmux`, with a
/// version (`cmux@1.2`, `cmux==1.2`, `cmux>=1`) or not; never `cmux-sdk`.
fn names_cmux_package(spec: &str) -> bool {
    let name = spec.split(['@', '=', '<', '>', '~', '!', '[']).next().unwrap_or_default();
    name == PACKAGE
}

/// The arguments after a runner's own options: `takes_value` options use the
/// next argument unless written `--flag=value`; `None` when an option in
/// `refuses` turns the launch into something else (`node -e`, `npx -c`).
fn after_options<'a>(
    args: &'a [String],
    takes_value: &[&str],
    refuses: &[&str],
) -> Option<&'a [String]> {
    after_options_with(args, takes_value, refuses, &[]).map(|(rest, _)| rest)
}

/// [`after_options`], also answering the values of the options in `package`
/// (`npx -p PKG`, `uvx --from PKG`, `pipx run --spec PKG`): the package the
/// runner installs, whose command the next argument names.
fn after_options_with<'a>(
    args: &'a [String],
    takes_value: &[&str],
    refuses: &[&str],
    package: &[&str],
) -> Option<(&'a [String], Vec<&'a str>)> {
    let mut rest = args;
    let mut packages = Vec::new();
    while let Some((first, tail)) = rest.split_first() {
        if first == "--" {
            return Some((tail, packages));
        }
        if !first.starts_with('-') || first == "-" {
            return Some((rest, packages));
        }
        let (flag, attached) = match first.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (first.as_str(), None),
        };
        if refuses.contains(&flag) {
            return None;
        }
        let value = if takes_value.contains(&flag) && attached.is_none() {
            let value = tail.first().map(String::as_str);
            rest = tail.get(1..).unwrap_or_default();
            value
        } else {
            rest = tail;
            attached
        };
        if package.contains(&flag) {
            packages.push(value.unwrap_or_default());
        }
    }
    Some((rest, packages))
}

/// [`CmuxServe`] of an entry that runs `command args`, or `None` when it runs
/// no cmux server. Names match exactly: the CLI's ([`CLI_NAMES`]), the
/// launcher script's and the package's.
pub(crate) fn cmux_serve<'a>(command: &'a str, args: &'a [String]) -> Option<CmuxServe<'a>> {
    let base = |path: &str| Path::new(path).file_name().and_then(|n| n.to_str()).map(str::to_owned);
    let serves = |rest: &[String]| rest.iter().map(String::as_str).take(2).eq(["mcp", "serve"]);
    let program = base(command)?;
    if CLI_NAMES.contains(&program.as_str()) {
        return serves(args).then_some(CmuxServe::Path(command));
    }
    // `bun x PKG` is bunx, `bun run SCRIPT` runs a script like `bun SCRIPT`.
    let (program, args) = match (program.as_str(), args.first().map(String::as_str)) {
        ("bun", Some("x")) => ("bunx".to_owned(), &args[1..]),
        ("bun", Some("run")) => ("bun".to_owned(), &args[1..]),
        ("uv", Some("tool")) if args.get(1).is_some_and(|a| a == "run") => {
            ("uvx".to_owned(), &args[2..])
        }
        ("npm", Some("exec" | "x")) => ("npx".to_owned(), &args[1..]),
        _ => (program, args),
    };
    // A JavaScript runtime and its script, after the runtime's own options.
    if matches!(program.as_str(), "node" | "nodejs" | "bun") {
        let rest = after_options(
            args,
            &[
                "-r",
                "--require",
                "--import",
                "--loader",
                "--experimental-loader",
                "-C",
                "--conditions",
                "--inspect-port",
                "--env-file",
                "--title",
                "--preserve-symlinks-main",
            ],
            &["-e", "--eval", "-p", "--print", "-c", "--check", "-i", "--interactive"],
        )?;
        let (script, rest) = rest.split_first()?;
        return (base(script).as_deref() == Some(LAUNCHER_SCRIPT) && serves(rest))
            .then_some(CmuxServe::Path(script.as_str()));
    }
    // A package runner: its own options, then the package (or the command of
    // a package an option names), then its args.
    let (args, takes_value, refuses): (&[String], &[&str], &[&str]) = match program.as_str() {
        "npx" | "pnpx" => {
            (args, &["-p", "--package", "--registry", "--cache", "--userconfig"], &["-c", "--call"])
        }
        "bunx" => (args, &["-p", "--package"], &[]),
        "pnpm" if args.first().is_some_and(|a| a == "dlx") => {
            (&args[1..], &["--package", "--dir", "-C"], &["-c", "--shell-mode"])
        }
        "uvx" => (
            args,
            &[
                "--from",
                "--with",
                "--with-editable",
                "--with-requirements",
                "-w",
                "--python",
                "-p",
                "--index",
                "--default-index",
                "--index-url",
                "-i",
                "--extra-index-url",
                "--find-links",
                "-f",
                "--constraints",
                "--overrides",
                "--cache-dir",
                "--directory",
                "--project",
                "--config-file",
            ],
            &[],
        ),
        "pipx" if args.first().is_some_and(|a| a == "run") => (
            &args[1..],
            &[
                "--spec",
                "--python",
                "--index-url",
                "-i",
                "--pip-args",
                "--backend",
                "--fetch-python",
            ],
            &[],
        ),
        _ => return None,
    };
    // `-p PKG`/`--package PKG` (npx, bunx, pnpm dlx), `--from PKG` (uvx) or
    // `--spec PKG` (pipx run) name the package; the command after is one of
    // its binaries. (uvx's `-p` is its Python.)
    let package_options: &[&str] = match program.as_str() {
        "uvx" => &["--from"],
        "pipx" => &["--spec"],
        _ => &["-p", "--package"],
    };
    let (rest, packages) = after_options_with(args, takes_value, refuses, package_options)?;
    let (command, rest) = rest.split_first()?;
    let package_is_cmux = if packages.is_empty() {
        names_cmux_package(command)
    } else {
        packages.iter().all(|package| names_cmux_package(package))
            && CLI_NAMES.contains(&command.as_str())
    };
    (package_is_cmux && serves(rest)).then_some(CmuxServe::Published)
}

/// Whether the entry Codex reported runs cmux's server ([`cmux_serve`]).
fn serves_cmux(entry: &serde_json::Value) -> bool {
    let transport = &entry["transport"];
    let Some(command) = transport["command"].as_str() else { return false };
    let args: Vec<String> = transport["args"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|arg| arg.as_str().map(str::to_owned))
        .collect();
    cmux_serve(command, &args).is_some()
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
        let settings = codex_settings(
            Path::new("/A pp/cmux"),
            Path::new("/tmp/s \"q\".sock"),
            &CodexEntry::Absent,
            &pane,
        )
        .unwrap();
        assert_eq!(settings.len(), 3);
        let mut merged = toml::Table::new();
        for setting in &settings {
            let text = setting.to_str().unwrap();
            assert!(!text.contains(COMPUTER_USE_SERVER) || text.contains(".env="), "{text}");
            let parsed: toml::Table = toml::from_str(text).unwrap();
            let servers = parsed["mcp_servers"].as_table().unwrap();
            assert_eq!(servers.keys().collect::<Vec<_>>(), [CODEX_TERMINAL_SERVER], "{text}");
            for (k, v) in servers[CODEX_TERMINAL_SERVER].as_table().unwrap() {
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

    /// The `-c` flags for a launch where Codex reported `existing`.
    fn placed(existing: CodexEntry) -> toml::Table {
        servers(
            &codex_settings(Path::new("/A/cmux"), Path::new("/tmp/s.sock"), &existing, &pane)
                .unwrap(),
        )
    }

    /// An entry as `codex mcp get --json` prints it (Codex 0.160.1), with
    /// `extra` fields set over a plain cmux entry.
    fn entry(command: &str, extra: serde_json::Value) -> CodexEntry {
        let mut value = json!({
            "name": "cmux", "enabled": true, "disabled_reason": null,
            "transport": {"type": "stdio", "command": command, "args": ["mcp", "serve"],
                          "env": null, "env_vars": [], "cwd": null},
            "enabled_tools": null, "disabled_tools": null,
            "startup_timeout_sec": null, "tool_timeout_sec": null,
        });
        for (key, field) in extra.as_object().unwrap() {
            if let Some(inner) = key.strip_prefix("transport.") {
                value["transport"][inner] = field.clone();
            } else {
                value[key] = field.clone();
            }
        }
        CodexEntry::Found(value)
    }

    /// This build's server is always `cmux_terminal` in Codex, sharing no key
    /// with a config entry, so nothing merges into it; the reported `cmux`
    /// entry is turned off only when it is another cmux's server and on.
    #[test]
    fn codex_gets_cmux_terminal_and_turns_off_only_another_cmuxs_entry() {
        let names = |servers: &toml::Table| servers.keys().cloned().collect::<Vec<_>>();
        let off = |servers: &toml::Table| {
            servers.get(SERVER).and_then(|s| s.get("enabled")).and_then(toml::Value::as_bool)
        };
        for existing in [
            CodexEntry::Absent,
            CodexEntry::Unknown,
            entry("/usr/bin/my-tool", json!({})),
            entry("/opt/cmux", json!({"enabled": false})),
        ] {
            let placed = placed(existing.clone());
            assert_eq!(names(&placed), [CODEX_TERMINAL_SERVER], "{existing:?}");
            assert_eq!(off(&placed), None, "nothing turned off: {existing:?}");
        }
        for existing in [
            entry("/Applications/cmux.app/Contents/Resources/bin/cmux", json!({})),
            entry("/opt/cmux", json!({"transport.cwd": "/w", "startup_timeout_sec": 7.0})),
            entry("npx", json!({"transport.args": ["-y", "cmux", "mcp", "serve"]})),
        ] {
            let placed = placed(existing.clone());
            assert_eq!(placed[CODEX_TERMINAL_SERVER]["command"].as_str(), Some("/A/cmux"));
            assert_eq!(off(&placed), Some(false), "{existing:?}");
            assert_eq!(placed[SERVER].as_table().unwrap().len(), 1, "only `enabled`: {placed}");
        }
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
        // Options with values, in both forms, before the package or script.
        assert_eq!(
            of("uvx", &["--with", "rich", "--python", "3.12", "cmux==1.2", "mcp", "serve"]),
            published
        );
        assert_eq!(of("uvx", &["--python=3.12", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("pipx", &["run", "--python", "python3.12", "cmux", "mcp", "serve"]),
            published
        );
        assert_eq!(of("npx", &["--package", "cmux@1", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("npx", &["-p", "cmux", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("node", &["--require", "/x/hook.js", "/n/cmux/bin/cmux.js", "mcp", "serve"]),
            path("/n/cmux/bin/cmux.js")
        );
        assert_eq!(
            of("node", &["--max-old-space-size=512", "/n/cmux.js", "mcp", "serve"]),
            path("/n/cmux.js")
        );
        assert_eq!(of("/A/cmux-next", &["mcp", "serve"]), path("/A/cmux-next"));
        assert_eq!(of("/A/cmux-tui", &["mcp", "serve"]), path("/A/cmux-tui"));
        // The runners' long forms.
        assert_eq!(of("uv", &["tool", "run", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("uv", &["tool", "run", "--python", "3.12", "cmux", "mcp", "serve"]),
            published
        );
        assert_eq!(of("npm", &["exec", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("npm", &["exec", "--", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("npm", &["exec", "--package", "cmux@1", "--", "cmux", "mcp", "serve"]),
            published
        );
        assert_eq!(of("bun", &["x", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("bun", &["run", "/n/cmux.js", "mcp", "serve"]), path("/n/cmux.js"));
        assert_eq!(
            of("uv", &["run", "cmux", "mcp", "serve"]),
            None,
            "uv run is a project's script"
        );
        for (command, args) in [
            ("/A/cmux", &["serve"][..]),
            ("/usr/bin/my-tool", &["mcp", "serve"]),
            ("node", &["/x/other.js", "mcp", "serve"]),
            ("npx", &["-y", "other", "mcp", "serve"]),
            ("pipx", &["install", "cmux"]),
            // Names match exactly, never by prefix.
            ("/A/cmux-helper", &["mcp", "serve"]),
            ("npx", &["cmux-sdk", "mcp", "serve"]),
            ("uvx", &["cmuxtools", "mcp", "serve"]),
            ("node", &["/n/cmux-other.js", "mcp", "serve"]),
            // The value of an option is not the package.
            ("uvx", &["--from", "cmux", "other", "mcp", "serve"]),
            // A package an option names that is not cmux, whose command is
            // only called `cmux`.
            ("npx", &["-p", "evil", "cmux", "mcp", "serve"]),
            ("npx", &["--package=evil@1", "cmux", "mcp", "serve"]),
            ("uvx", &["--from", "evil", "cmux", "mcp", "serve"]),
            ("pipx", &["run", "--spec", "evil", "cmux", "mcp", "serve"]),
            ("bunx", &["-p", "evil", "cmux", "mcp", "serve"]),
            // Code that is no script: not a launch of cmux.
            ("node", &["-e", "x", "/n/cmux.js", "mcp", "serve"]),
            ("npx", &["-c", "cmux mcp serve"]),
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
