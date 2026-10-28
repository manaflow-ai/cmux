//! Part of `Hub`; see `hub/mod.rs`. What runs under an idle harness before it is ended.
//!
//! Ending an idle harness ends its process group and the processes under it, as Stop does. That
//! must never take work the harness did not report (a dev server it left running, a watcher), so
//! the idle pass first lists what runs under the harness (`agent_host/tree.rs` `under`: by parent
//! chain and by process group, zombies skipped). Each process must be one of the session's MCP
//! servers, or run under one; anything else keeps the harness up. A census that fails or is not
//! whole keeps it up too.
//!
//! The MCP servers are read from every config the harness reads: the servers cmux gave this
//! session (`agent_tools.rs`, as `scoped` and `for_session` narrow them), and for Claude Code its
//! `.claude.json` (its user servers and this folder's project entry, in `~` and in the session's
//! `CLAUDE_CONFIG_DIR`) and the folder's `.mcp.json` (none with `--strict-mcp-config`), for Codex
//! its `config.toml` `[mcp_servers]` (in `~/.codex` and the session's `CODEX_HOME`). A file that
//! is missing or does not parse adds nothing, so a server only it names keeps the harness up. A
//! process is a server when its program is the server's command, or an interpreter runs that
//! command as a script, and the server's args follow it (`runs`).

#![cfg_attr(not(unix), allow(dead_code))]

use super::*;
use std::path::{Path, PathBuf};

/// One configured MCP server: its command and args, each arg split on whitespace as `ps` prints.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Sidecar {
    command: String,
    args: Vec<String>,
}

/// What keeps an idle harness up.
pub(super) enum Census {
    /// Only the harness and its MCP servers run: it may end.
    Clear,
    /// This process is neither an MCP server nor under one.
    Busy { pid: u32, comm: String },
    /// The processes could not be listed (or the harness pid is unknown).
    Unknown,
}

/// A refusal is logged at most this often per session.
const REFUSAL_LOG_EVERY: std::time::Duration = std::time::Duration::from_secs(600);

impl Hub {
    /// Lists what runs under `pid`, the session's harness, against its MCP servers.
    pub(super) async fn idle_census(&self, session: &Session, pid: Option<u32>) -> Census {
        #[cfg(unix)]
        if let Some(pid) = pid {
            let sidecars = self.sidecars(session).await;
            let found =
                tokio::task::spawn_blocking(move || crate::agent_host::tree::under(pid)).await;
            return match found {
                Ok(Some(found)) => classify(&found, &sidecars),
                _ => Census::Unknown,
            };
        }
        // Windows: no census, and closing the job ends everything under it.
        let _ = (session, pid);
        Census::Unknown
    }

    /// Logs why an idle harness stays up, once per [`REFUSAL_LOG_EVERY`] per session.
    pub(super) fn note_refusal(&self, session: &Session, census: &Census) {
        let now = self.clock_now();
        let last = session.idle_refusal_logged.load(Ordering::Relaxed);
        if last != 0 && now.saturating_sub(last) < REFUSAL_LOG_EVERY.as_nanos() as u64 {
            return;
        }
        session.idle_refusal_logged.store(now.max(1), Ordering::Relaxed);
        match census {
            Census::Busy { pid, comm } => tracing::info!(
                session = %session.id, pid, comm = %comm,
                "idle harness stays up: a process that is not one of its MCP servers runs under it"
            ),
            Census::Unknown => tracing::info!(
                session = %session.id,
                "idle harness stays up: the processes under it could not be listed"
            ),
            Census::Clear => {}
        }
    }

    /// The session's MCP servers, from every config its harness reads.
    async fn sidecars(&self, session: &Session) -> Vec<Sidecar> {
        let meta = session.meta();
        let (_, env) = self.harness_env(&meta).await;
        let argv = meta.spawn_argv.as_ref().unwrap_or(&meta.harness_argv);
        // What this session's harness was given (`spawn.rs`, `agent/command.rs`), not every
        // server this daemon has.
        let mut out: Vec<Sidecar> = if crate::agent_tools::left_out(meta.remote_origin, &env, argv)
        {
            Vec::new()
        } else {
            let tools = crate::agent_tools::current().scoped(&env).for_session(&session.id);
            tools.servers.iter().map(|s| sidecar(&s.command.to_string_lossy(), &s.args)).collect()
        };
        // Its own family's configs only; Claude Code with --strict-mcp-config reads none of them.
        let family = meta.family.as_deref().unwrap_or_default();
        let strict = argv.iter().any(|a| a == "--strict-mcp-config");
        let home = dirs::home_dir().unwrap_or_default();
        let mut claude = Vec::new();
        if family == "claude" && !strict {
            claude.push(home.clone());
            claude.extend(crate::harness_config::config_dir(
                "CLAUDE_CONFIG_DIR",
                ".claude",
                &[&env],
            ));
            claude.extend(crate::route_account::current_home(&meta, "claude", &env));
        }
        let mut codex = Vec::new();
        if family == "codex" {
            codex.push(home.join(".codex"));
            codex.extend(crate::harness_config::config_dir("CODEX_HOME", ".codex", &[&env]));
            codex.extend(crate::route_account::current_home(&meta, "codex", &env));
        }
        let project = !claude.is_empty();
        let cwd = Path::new(&meta.cwd);
        let cwd_keys: Vec<String> = [Some(cwd.to_path_buf()), cwd.canonicalize().ok()]
            .into_iter()
            .flatten()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        tokio::task::spawn_blocking(move || {
            for dir in claude {
                let Some(json) = read_json(&dir.join(".claude.json")) else { continue };
                out.extend(from_json(json.get("mcpServers")));
                for key in &cwd_keys {
                    out.extend(from_json(json.pointer(&format!("/projects/{}", escape(key)))));
                }
            }
            for key in cwd_keys.iter().filter(|_| project) {
                let file = read_json(&PathBuf::from(key).join(".mcp.json"));
                out.extend(from_json(file.as_ref().and_then(|j| j.get("mcpServers"))));
            }
            for dir in codex {
                let Ok(text) = std::fs::read_to_string(dir.join("config.toml")) else { continue };
                out.extend(from_toml(&text));
            }
            out.dedup();
            out
        })
        .await
        .unwrap_or_default()
    }
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// A JSON pointer token for `key` (RFC 6901).
fn escape(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

fn sidecar(command: &str, args: &[String]) -> Sidecar {
    let args = args.iter().flat_map(|a| a.split_whitespace()).map(str::to_owned).collect();
    Sidecar { command: command.to_owned(), args }
}

/// The stdio servers of a `{"name": {"command", "args"}}` map; a project entry nests it.
fn from_json(servers: Option<&Value>) -> Vec<Sidecar> {
    let Some(map) = servers.and_then(|s| s.get("mcpServers").unwrap_or(s).as_object()) else {
        return Vec::new();
    };
    map.values()
        .filter_map(|s| {
            let command = s.get("command")?.as_str()?;
            let args: Vec<String> =
                s.get("args").and_then(Value::as_array).map_or_else(Vec::new, |a| {
                    a.iter().filter_map(Value::as_str).map(str::to_owned).collect()
                });
            Some(sidecar(command, &args))
        })
        .collect()
}

/// Codex's `[mcp_servers.<name>]` tables.
fn from_toml(text: &str) -> Vec<Sidecar> {
    let Ok(table) = text.parse::<toml::Table>() else { return Vec::new() };
    let Some(servers) = table.get("mcp_servers").and_then(toml::Value::as_table) else {
        return Vec::new();
    };
    servers
        .values()
        .filter_map(|s| {
            let command = s.get("command")?.as_str()?;
            let args: Vec<String> =
                s.get("args").and_then(toml::Value::as_array).map_or_else(Vec::new, |a| {
                    a.iter().filter_map(toml::Value::as_str).map(str::to_owned).collect()
                });
            Some(sidecar(command, &args))
        })
        .collect()
}

/// Whether command line `args` (as `ps` prints it) runs `s`: its program is the server's command
/// (the same path, or the same name for a command given by name), or an interpreter runs it as
/// a script (a `#!` line: `node /usr/local/bin/npx`), and the server's args follow right after,
/// in order. A shell whose command string names the server (`sh -c ...`) is not the server.
fn runs(args: &str, s: &Sidecar) -> bool {
    let words: Vec<&str> = args.split_whitespace().collect();
    let by_name = !s.command.contains('/');
    let name = Path::new(&s.command).file_name();
    let is_command = |w: &str| w == s.command || (by_name && Path::new(w).file_name() == name);
    let at = if words.first().is_some_and(|w| is_command(w)) {
        1
    } else if words.get(1).is_some_and(|w| w.contains('/') && is_command(w)) {
        2
    } else {
        return false;
    };
    words.len() >= at + s.args.len() && words[at..].iter().zip(&s.args).all(|(a, b)| a == b)
}

/// `Busy` with the first process that is neither a server nor under one.
#[cfg(unix)]
fn classify(found: &[crate::agent_host::tree::Under], sidecars: &[Sidecar]) -> Census {
    let mut allowed: Vec<u32> = Vec::new();
    let mut grew = true;
    while grew {
        grew = false;
        for p in found {
            if !allowed.contains(&p.pid)
                && (allowed.contains(&p.ppid) || sidecars.iter().any(|s| runs(&p.args, s)))
            {
                allowed.push(p.pid);
                grew = true;
            }
        }
    }
    match found.iter().find(|p| !allowed.contains(&p.pid)) {
        Some(p) => {
            let first = p.args.split_whitespace().next().unwrap_or_default();
            let comm = Path::new(first).file_name().map_or(first.into(), |n| n.to_string_lossy());
            Census::Busy { pid: p.pid, comm: comm.into_owned() }
        }
        None => Census::Clear,
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::agent_host::tree::Under;

    fn under(pid: u32, ppid: u32, args: &str) -> Under {
        Under { pid, ppid, args: args.into() }
    }

    #[test]
    fn mcp_servers_and_what_runs_under_them_let_a_harness_end() {
        let servers = from_json(Some(&json!({
            "cmux": {"command": "/Applications/cmux.app/Contents/Resources/bin/cmux", "args": ["mcp", "serve"]},
            "fetch": {"command": "npx", "args": ["-y", "@example/fetch"]},
            "remote": {"type": "http", "url": "https://example.com/mcp"},
        })));
        assert_eq!(servers.len(), 2, "a server with no command spawns nothing");
        let found = [
            under(
                11,
                10,
                "/Applications/cmux.app/Contents/Resources/bin/cmux mcp serve --all-tools",
            ),
            under(12, 10, "node /usr/local/bin/npx -y @example/fetch"),
            under(13, 12, "node /tmp/_npx/fetch/index.js"),
        ];
        assert!(matches!(classify(&found, &servers), Census::Clear));
        let mut busy = found.to_vec();
        busy.push(under(14, 10, "/usr/bin/python3 -m http.server 8000"));
        assert!(
            matches!(classify(&busy, &servers), Census::Busy { pid: 14, ref comm } if comm == "python3")
        );
        let renamed = [under(12, 10, "node /usr/local/bin/npx -y @example/other")];
        assert!(matches!(classify(&renamed, &servers), Census::Busy { pid: 12, .. }));
        for other in [
            "sh -c npx -y @example/fetch",
            "/tmp/other/cmux mcp serve",
            "python3 notes.py npx -y @example/fetch",
        ] {
            let found = [under(12, 10, other)];
            assert!(matches!(classify(&found, &servers), Census::Busy { .. }), "{other}");
        }
    }

    #[test]
    fn codex_and_project_entries_are_read_and_a_bad_file_adds_nothing() {
        let codex = from_toml("[mcp_servers.docs]\ncommand = \"docs-mcp\"\nargs = [\"--stdio\"]\n");
        assert_eq!(codex, vec![sidecar("docs-mcp", &["--stdio".into()])]);
        assert!(from_toml("[mcp_servers").is_empty());
        let project = json!({"projects": {"/w/a": {"mcpServers": {"x": {"command": "x-mcp"}}}}});
        let entry = project.pointer(&format!("/projects/{}", escape("/w/a")));
        assert_eq!(from_json(entry), vec![sidecar("x-mcp", &[])]);
    }
}
