//! Part of `Hub`; see `hub/mod.rs`. What runs under an idle harness before it is ended.
//!
//! Ending an idle harness ends its process group and the processes under it, as Stop does. That
//! must never take work the harness did not report (a dev server it left running, a watcher), so
//! the idle pass first lists what runs under the harness (`agent_host/tree.rs` `under`: by parent
//! chain and by process group, zombies skipped). Each process must be one of the session's MCP
//! servers, or run under one; anything else keeps the harness up. A census that fails or is not
//! whole keeps it up too.
//!
//! The MCP servers are the ones the harness's configs named as it started: just before each
//! start, `LaunchServers::read` reads, once, the configs of that launch (argv, folder,
//! `HOME`, `PATH`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`): for Claude Code its `--mcp-config` files
//! (acpmux's among them) and, unless `--strict-mcp-config`, its `.claude.json` (user servers and
//! this folder's project entry) and the folder's `.mcp.json`; for Codex its `config.toml`. The
//! `mcpServers` acpmux gave an ACP harness are added. A config edited later never changes them. A
//! file that is missing or does not parse adds nothing, so a server only it names keeps the
//! harness up. For a harness another daemon started none are known: it ends only when nothing
//! runs under it.
//!
//! Only a child of the harness can be a server, and only when its command line is exactly the
//! server's: its program (as configured, or what `PATH` runs for a name), or an interpreter
//! running that program as a script, then exactly its args (`runs`). What runs under a server is
//! the server's. The configs and `ps` each get [`CENSUS_BUDGET`]; past it the harness stays up,
//! so the leases the pass holds are never held longer.

#![cfg_attr(not(unix), allow(dead_code))]

use super::*;
use std::path::{Path, PathBuf};

/// One configured MCP server: its command and args, each arg split on whitespace as `ps` prints.
/// `resolved`: for a command given by name, the program the harness's `PATH` runs for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Sidecar {
    command: String,
    args: Vec<String>,
    resolved: Option<String>,
}

/// The most the idle pass waits for the configs to be read, or for `ps`.
const CENSUS_BUDGET: std::time::Duration = std::time::Duration::from_secs(3);

/// Interpreters that run a server as a script (its `#!` line): `node /usr/local/bin/npx`.
const INTERPRETERS: &[&str] =
    &["node", "nodejs", "bun", "deno", "python", "ruby", "perl", "sh", "bash", "zsh", "dash"];

/// What keeps an idle harness up.
pub(super) enum Census {
    /// Only the harness and its MCP servers run: it may end.
    Clear,
    /// This process is neither an MCP server nor under one.
    Busy { pid: u32, comm: String },
    /// The processes or the harness's MCP servers could not be listed (or its pid is unknown).
    Unknown,
}

/// A refusal is logged at most this often per session.
const REFUSAL_LOG_EVERY: std::time::Duration = std::time::Duration::from_secs(600);

impl Hub {
    /// Lists what runs under `pid`, the session's harness, against `sidecars`, within
    /// [`CENSUS_BUDGET`].
    pub(super) async fn idle_census(
        &self,
        pid: Option<u32>,
        sidecars: Option<Vec<Sidecar>>,
    ) -> Census {
        #[cfg(unix)]
        if let (Some(pid), Some(sidecars)) = (pid, sidecars) {
            let found = tokio::task::spawn_blocking(move || crate::agent_host::tree::under(pid));
            return match tokio::time::timeout(CENSUS_BUDGET, found).await {
                Ok(Ok(Some(found))) => classify(&found, pid, &sidecars),
                _ => Census::Unknown,
            };
        }
        // Windows: no census, and closing the job ends everything under it.
        #[cfg(not(unix))]
        let _ = (pid, sidecars);
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
                "idle harness stays up: its MCP servers or the processes under it are not known"
            ),
            Census::Clear => {}
        }
    }

    /// The MCP servers `child`, the session's harness, runs: what its configs named as it
    /// started (`LaunchServers::read`) and the `mcpServers` acpmux gave it. None when its configs
    /// were not read in time: the harness stays up. For a
    /// harness another daemon started none are known, so it ends only when nothing at all runs
    /// under it.
    pub(super) async fn sidecars(&self, child: &ChildAgent) -> Option<Vec<Sidecar>> {
        let state = child.launch.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let (mut servers, path) = match state {
            None => return Some(Vec::new()),
            Some(LaunchServers::Known { servers, path }) => (servers, path),
            Some(LaunchServers::Unknown) => return None,
        };
        let given = child.given_servers.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let read = tokio::task::spawn_blocking(move || {
            servers.extend(resolved(from_json(given.as_ref()), &path));
            servers
        });
        tokio::time::timeout(CENSUS_BUDGET, read).await.ok()?.ok()
    }
}

/// What the idle census knows of a harness's MCP servers (`ChildAgent::launch`).
#[derive(Debug, Clone)]
pub(crate) enum LaunchServers {
    /// The servers its configs named just before it started, and its `PATH`.
    Known { servers: Vec<Sidecar>, path: String },
    /// Its configs could not be read within [`CENSUS_BUDGET`].
    Unknown,
}

impl LaunchServers {
    /// Reads, once and before the harness of `family` is started as `launch`, the MCP servers
    /// its configs name, bounded by [`CENSUS_BUDGET`]; each start site awaits it before its
    /// spawn, so the census judges by what the harness could read at its start, never by a
    /// config edited after it.
    pub(crate) async fn read(launch: &crate::agent::Launch, family: String) -> Self {
        let path = launch.env.get("PATH").cloned().unwrap_or_default();
        let (at, launch) = (path.clone(), launch.clone());
        let read =
            tokio::task::spawn_blocking(move || resolved(from_launch(&family, &launch), &at));
        match tokio::time::timeout(CENSUS_BUDGET, read).await {
            Ok(Ok(servers)) => Self::Known { servers, path },
            _ => Self::Unknown,
        }
    }
}

impl ChildAgent {
    /// Records `servers`, what its configs named as it started (`LaunchServers::read`).
    pub(crate) fn record_launch(&self, servers: LaunchServers) {
        *self.launch.lock().unwrap_or_else(|e| e.into_inner()) = Some(servers);
    }
}

/// `servers` with each one given by name resolved on `path`, without repeats.
fn resolved(mut servers: Vec<Sidecar>, path: &str) -> Vec<Sidecar> {
    for s in servers.iter_mut().filter(|s| !s.command.contains('/')) {
        s.resolved = first_on_path(&s.command, path);
    }
    servers.dedup();
    servers
}

/// The servers in the configs a harness of `family` started as `launch` reads: Claude Code's
/// `--mcp-config` files and JSON (acpmux's own among them), and unless `--strict-mcp-config`
/// its `.claude.json` (`$CLAUDE_CONFIG_DIR`, else `$HOME`: user servers and this folder's
/// project entry) and the folder's `.mcp.json`; Codex's `config.toml` (`$CODEX_HOME`, else
/// `$HOME/.codex`).
fn from_launch(family: &str, launch: &crate::agent::Launch) -> Vec<Sidecar> {
    let mut out = Vec::new();
    let env = |k: &str| launch.env.get(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    let Some(home) = env("HOME") else { return out };
    let cwd = &launch.cwd;
    if family == "claude" {
        for pair in launch.args.windows(2).filter(|w| w[0] == "--mcp-config") {
            match serde_json::from_str::<Value>(&pair[1]) {
                Ok(inline) if inline.is_object() => out.extend(from_json(inline.get("mcpServers"))),
                // A file, relative to the harness's folder.
                _ => {
                    let file = read_json(&cwd.join(&pair[1]));
                    out.extend(from_json(file.as_ref().and_then(|j| j.get("mcpServers"))));
                }
            }
        }
        if launch.args.iter().any(|a| a == "--strict-mcp-config") {
            return out;
        }
        let dir = env("CLAUDE_CONFIG_DIR").unwrap_or(home);
        let keys: Vec<String> = [Some(cwd.clone()), cwd.canonicalize().ok()]
            .into_iter()
            .flatten()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        if let Some(json) = read_json(&dir.join(".claude.json")) {
            out.extend(from_json(json.get("mcpServers")));
            for key in &keys {
                out.extend(from_json(json.pointer(&format!("/projects/{}", escape(key)))));
            }
        }
        let project = read_json(&cwd.join(".mcp.json"));
        out.extend(from_json(project.as_ref().and_then(|j| j.get("mcpServers"))));
    } else if family == "codex" {
        let dir = env("CODEX_HOME").unwrap_or_else(|| home.join(".codex"));
        if let Ok(text) = std::fs::read_to_string(dir.join("config.toml")) {
            out.extend(from_toml(&text));
        }
    }
    out
}

/// The program `PATH` runs for `name`: its first executable file there.
fn first_on_path(name: &str, path: &str) -> Option<String> {
    path.split(':').filter(|d| !d.is_empty()).find_map(|dir| {
        let at = Path::new(dir).join(name);
        let meta = std::fs::metadata(&at).ok()?;
        #[cfg(unix)]
        let runs = std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o111 != 0;
        #[cfg(not(unix))]
        let runs = true;
        (meta.is_file() && runs).then(|| at.to_string_lossy().into_owned())
    })
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// A JSON pointer token for `key` (RFC 6901).
fn escape(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

/// A server by its command and args, or None when `ps`'s space-joined command line could not
/// tell it apart (an empty word or one with whitespace in it): such a server never matches, so a
/// harness that runs it stays up.
fn sidecar(command: &str, args: &[String]) -> Option<Sidecar> {
    let plain = |w: &str| !w.is_empty() && !w.contains(char::is_whitespace);
    (plain(command) && args.iter().all(|a| plain(a))).then(|| Sidecar {
        command: command.to_owned(),
        args: args.to_vec(),
        resolved: None,
    })
}

/// The stdio servers of a `{"name": {"command", "args"}}` map (a project entry nests it) or an
/// ACP `mcpServers` list.
fn from_json(servers: Option<&Value>) -> Vec<Sidecar> {
    let Some(servers) = servers.map(|s| s.get("mcpServers").unwrap_or(s)) else {
        return Vec::new();
    };
    let all: Vec<&Value> = match servers {
        Value::Object(map) => map.values().collect(),
        Value::Array(list) => list.iter().collect(),
        _ => Vec::new(),
    };
    all.into_iter()
        .filter_map(|s| {
            let command = s.get("command")?.as_str()?;
            // An arg that is not a string: not a server this census can tell apart.
            let args = match s.get("args") {
                None => Vec::new(),
                Some(a) => a
                    .as_array()?
                    .iter()
                    .map(|a| a.as_str().map(str::to_owned))
                    .collect::<Option<_>>()?,
            };
            sidecar(command, &args)
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
            // An arg that is not a string: not a server this census can tell apart.
            let args = match s.get("args") {
                None => Vec::new(),
                Some(a) => a
                    .as_array()?
                    .iter()
                    .map(|a| a.as_str().map(str::to_owned))
                    .collect::<Option<_>>()?,
            };
            sidecar(command, &args)
        })
        .collect()
}

/// Whether command line `args` (as `ps` prints it) is exactly `s`: its program is the server's
/// command (as configured, or the program `PATH` runs for a command given by name), or one of
/// [`INTERPRETERS`] runs that program as a script (a `#!` line: `node /usr/local/bin/npx`), and
/// then exactly the server's args. A server that is a bare interpreter with no args says nothing
/// about what it runs, so it never matches.
fn runs(args: &str, s: &Sidecar) -> bool {
    let words: Vec<&str> = args.split_whitespace().collect();
    let base = |w: &str| Path::new(w).file_name().map(|n| n.to_string_lossy().into_owned());
    let interpreter = |w: &str| {
        let name = base(w).unwrap_or_default();
        INTERPRETERS.iter().any(|i| {
            name.strip_prefix(i)
                .is_some_and(|rest| rest.chars().all(|c| c.is_ascii_digit() || c == '.'))
        })
    };
    if s.args.is_empty() && interpreter(&s.command) {
        return false;
    }
    let program = |w: &str| w == s.command || s.resolved.as_deref() == Some(w);
    let at = if words.first().is_some_and(|w| program(w)) {
        1
    } else if words.first().is_some_and(|w| interpreter(w))
        && words.get(1).is_some_and(|w| w.contains('/') && program(w))
    {
        2
    } else {
        return false;
    };
    words.len() == at + s.args.len() && words[at..].iter().zip(&s.args).all(|(a, b)| a == b)
}

/// `Busy` with the first process that is neither a server (a child of `leader`) nor under one.
#[cfg(unix)]
fn classify(found: &[crate::agent_host::tree::Under], leader: u32, sidecars: &[Sidecar]) -> Census {
    let mut allowed: Vec<u32> = Vec::new();
    let mut grew = true;
    while grew {
        grew = false;
        for p in found {
            // The harness starts its servers itself: only its own children can be one.
            let server = p.ppid == leader && sidecars.iter().any(|s| runs(&p.args, s));
            if !allowed.contains(&p.pid) && (allowed.contains(&p.ppid) || server) {
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
        let mut servers = from_json(Some(&json!({
            "cmux": {"command": "/Applications/cmux.app/Contents/Resources/bin/cmux", "args": ["mcp", "serve", "--all-tools"]},
            "fetch": {"command": "npx", "args": ["-y", "@example/fetch"]},
            "py": {"command": "python3"},
            "remote": {"type": "http", "url": "https://example.com/mcp"},
        })));
        assert_eq!(servers.len(), 3, "a server with no command spawns nothing");
        servers[1].resolved = Some("/usr/local/bin/npx".into());
        let found = [
            under(
                11,
                10,
                "/Applications/cmux.app/Contents/Resources/bin/cmux mcp serve --all-tools",
            ),
            under(12, 10, "node /usr/local/bin/npx -y @example/fetch"),
            under(13, 12, "node /tmp/_npx/fetch/index.js"),
        ];
        assert!(matches!(classify(&found, 10, &servers), Census::Clear));
        for same in [
            "npx -y @example/fetch",
            "/usr/local/bin/npx -y @example/fetch",
            "/usr/bin/python3.12 /usr/local/bin/npx -y @example/fetch",
        ] {
            let found = [under(12, 10, same)];
            assert!(matches!(classify(&found, 10, &servers), Census::Clear), "{same}");
        }
        let mut busy = found.to_vec();
        busy.push(under(14, 10, "/usr/bin/python3 -m http.server 8000"));
        assert!(
            matches!(classify(&busy, 10, &servers), Census::Busy { pid: 14, ref comm } if comm == "python3")
        );
        for other in [
            "node /usr/local/bin/npx -y @example/other",
            "sh -c npx -y @example/fetch",
            "/tmp/other/cmux mcp serve --all-tools",
            "/Applications/cmux.app/Contents/Resources/bin/cmux mcp serve --all-tools --x",
            "python3 notes.py npx -y @example/fetch",
            "cat /usr/local/bin/npx -y @example/fetch",
            "/tmp/npx -y @example/fetch",
            "/opt/bin/npx -y @example/fetch",
            "node /tmp/npx -y @example/fetch",
            "python3",
            "python3 -c print(1)",
        ] {
            let found = [under(12, 10, other)];
            assert!(matches!(classify(&found, 10, &servers), Census::Busy { .. }), "{other}");
        }
        // A server's command line under something other than the harness is not its server.
        let nested = [under(15, 10, "bash"), under(16, 15, "npx -y @example/fetch")];
        assert!(matches!(classify(&nested, 10, &servers), Census::Busy { pid: 15, .. }));
    }

    #[test]
    fn the_configs_are_the_ones_the_harness_was_started_with() {
        let root = std::env::temp_dir().join(format!("idle-census-{}", uuid::Uuid::now_v7()));
        let (home, dir, cwd) = (root.join("home"), root.join("claude"), root.join("work"));
        for d in [&home, &dir, &cwd] {
            std::fs::create_dir_all(d).unwrap();
        }
        let server = |c: &str| json!({"mcpServers": {"s": {"command": c}}}).to_string();
        std::fs::write(home.join(".claude.json"), server("home-mcp")).unwrap();
        std::fs::write(dir.join(".claude.json"), server("dir-mcp")).unwrap();
        std::fs::write(cwd.join(".mcp.json"), server("project-mcp")).unwrap();
        std::fs::write(cwd.join("extra.json"), server("extra-mcp")).unwrap();
        let launch = |args: &[&str], env: &[(&str, &Path)]| crate::agent::Launch {
            args: args.iter().map(|a| a.to_string()).collect(),
            env: env.iter().map(|(k, v)| (k.to_string(), v.to_string_lossy().into())).collect(),
            cwd: cwd.clone(),
        };
        let names = |l: &crate::agent::Launch| {
            let mut n: Vec<String> =
                from_launch("claude", l).into_iter().map(|s| s.command).collect();
            n.sort();
            n
        };
        let plain = launch(&["claude", "--mcp-config", "extra.json"], &[("HOME", &home)]);
        assert_eq!(names(&plain), ["extra-mcp", "home-mcp", "project-mcp"]);
        let moved = launch(&["claude"], &[("HOME", &home), ("CLAUDE_CONFIG_DIR", &dir)]);
        assert_eq!(names(&moved), ["dir-mcp", "project-mcp"]);
        let strict = launch(&["claude", "--strict-mcp-config"], &[("HOME", &home)]);
        assert!(names(&strict).is_empty());
        assert!(from_launch("codex", &plain).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn codex_and_project_entries_are_read_and_a_bad_file_adds_nothing() {
        let codex = from_toml("[mcp_servers.docs]\ncommand = \"docs-mcp\"\nargs = [\"--stdio\"]\n");
        assert_eq!(codex, vec![sidecar("docs-mcp", &["--stdio".into()]).unwrap()]);
        assert!(from_toml("[mcp_servers").is_empty());
        // A server ps cannot tell apart from other argv, or with an arg that is not a string.
        let unclear = json!({
            "a": {"command": "srv", "args": ["foo bar"]},
            "b": {"command": "srv", "args": ["", "x"]},
            "c": {"command": "srv", "args": ["x", 1]},
            "d": {"command": "srv", "args": "x"},
        });
        assert!(from_json(Some(&unclear)).is_empty());
        let project = json!({"projects": {"/w/a": {"mcpServers": {"x": {"command": "x-mcp"}}}}});
        let entry = project.pointer(&format!("/projects/{}", escape("/w/a")));
        assert_eq!(from_json(entry), vec![sidecar("x-mcp", &[]).unwrap()]);
        let acp =
            json!([{"name": "cmux", "command": "/bin/cmux", "args": ["mcp", "serve"], "env": []}]);
        assert_eq!(
            from_json(Some(&acp)),
            vec![sidecar("/bin/cmux", &["mcp".into(), "serve".into()]).unwrap()]
        );
    }
}
