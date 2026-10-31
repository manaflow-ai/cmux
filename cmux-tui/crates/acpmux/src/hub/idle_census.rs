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
//! Only a child of the harness can be a server, and only when its argv is exactly the server's:
//! its program (as configured, or what `PATH` runs for a name), or an interpreter running that
//! program as a script, then exactly its args (`runs`). The argv is read word by word
//! (`tree::argv`), never split from the line `ps` prints, so a server whose path has a space in it
//! (acpmux's own, from `/Applications/cmux NIGHTLY.app`) matches, and one process's words can
//! never pass for another's. Argv is the process's own to rewrite (`exec -a`, `process.title`), so
//! the executable the kernel says it runs (`tree::exe`) must be the server's program too, or for
//! a script the interpreter its argv names. A child whose executable or argv cannot be read is not
//! a server. What runs under a server is the server's. A launcher (an interpreter running a
//! script by path: npm's `node .../bin/codex ARGS`) whose child runs a program of the script's
//! name with exactly the same args relays to that child, which is then the harness too: its
//! children may be servers, and a program beside it named after it (`codex-code-mode-host`) is its
//! own helper, though what runs under a helper is judged on its own (`relays`, `part_of`). A
//! native wrapper (`sr2 claude ARGS`: a program, not an interpreter, naming the agent and its
//! args) whose own child runs that agent by absolute path with those args unchanged among its own
//! relays the same way (`wrapper`, `relays_for`). The
//! configs, and `ps` with the argv reads, each get [`CENSUS_BUDGET`]; past it the harness stays
//! up, so the leases the pass holds are never held longer.

#![cfg_attr(not(unix), allow(dead_code))]

use super::*;
use std::path::{Path, PathBuf};

/// One configured MCP server: its command and args, word by word.
/// `resolved`: for a command given by name, the program the harness's `PATH` runs for it; for a
/// relative path (`./mcp-server`), that path in the harness's folder, where the harness runs it.
/// `interpreter`: for a script, the interpreter its `#!` line runs (`#!/usr/bin/env node`: the
/// `node` the harness's `PATH` runs).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Sidecar {
    command: String,
    args: Vec<String>,
    resolved: Option<String>,
    // A record written before servers carried an interpreter has none: none is known.
    #[serde(default)]
    interpreter: Option<String>,
}

/// A harness's MCP servers (`Hub::sidecars`), and the `PATH` it started with (`None` for a harness
/// another daemon started): a launcher's interpreter given by name is the one it runs.
pub(crate) struct Servers {
    list: Vec<Sidecar>,
    path: Option<String>,
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
    pub(super) async fn idle_census(&self, pid: Option<u32>, sidecars: Option<Servers>) -> Census {
        #[cfg(unix)]
        if let (Some(pid), Some(sidecars)) = (pid, sidecars) {
            // The listing, each candidate's argv and the match all run in the bounded task.
            let census = tokio::task::spawn_blocking(move || {
                let found = crate::agent_host::tree::under(pid)?;
                let (list, path) = (&sidecars.list, sidecars.path.as_deref());
                Some(classify(&found, pid, list, path, crate::agent_host::tree::identity))
            });
            return match tokio::time::timeout(CENSUS_BUDGET, census).await {
                Ok(Ok(Some(census))) => census,
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
    pub(super) async fn sidecars(&self, child: &ChildAgent) -> Option<Servers> {
        let state = child.launch.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let (mut servers, path, cwd) = match state {
            None => return Some(Servers { list: Vec::new(), path: None }),
            Some(LaunchServers::Known { servers, path, cwd }) => (servers, path, cwd),
            Some(LaunchServers::Unknown) => return None,
        };
        let given = child.given_servers.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let read = tokio::task::spawn_blocking(move || {
            servers.extend(resolved(from_json(given.as_ref()), &path, &cwd));
            Servers { list: servers, path: Some(path) }
        });
        tokio::time::timeout(CENSUS_BUDGET, read).await.ok()?.ok()
    }
}

/// The idle pass's census for an agent host whose daemon is gone (`agent_host/host/orphan.rs`,
/// `agent_host::OrphanExit`): true when nothing but `pid`, the harness, and its MCP servers runs
/// under it. Its servers are `exit`'s, read before it started, and the ACP `given` ones its
/// sessions opened with. A census that fails or is not whole says false.
#[cfg(unix)]
pub(crate) async fn host_census(
    pid: u32,
    exit: crate::agent_host::OrphanExit,
    given: Option<Value>,
) -> bool {
    let crate::agent_host::OrphanExit { mut servers, path, cwd, .. } = exit;
    // Off the host's one runtime thread, within the budget: resolving a server's name stats
    // each `PATH` folder, which a slow mount can hold.
    let found = tokio::task::spawn_blocking(move || {
        servers.extend(resolved(from_json(given.as_ref()), &path, &cwd));
        let found = crate::agent_host::tree::under(pid)?;
        let census =
            classify(&found, pid, &servers, Some(&path), crate::agent_host::tree::identity);
        Some(matches!(census, Census::Clear))
    });
    matches!(tokio::time::timeout(CENSUS_BUDGET, found).await, Ok(Ok(Some(true))))
}

/// What the idle census knows of a harness's MCP servers (`ChildAgent::launch`).
#[derive(Debug, Clone)]
pub(crate) enum LaunchServers {
    /// The servers its configs named just before it started, its `PATH` and its folder.
    Known { servers: Vec<Sidecar>, path: String, cwd: PathBuf },
    /// Its configs could not be read within [`CENSUS_BUDGET`].
    Unknown,
}

impl LaunchServers {
    /// `exit` (`Hub::orphan_exit`) with these servers: none when they are not known, since a
    /// host whose servers are unknown can never tell its agent is idle.
    pub(crate) fn orphan_exit(
        &self,
        exit: Option<crate::agent_host::OrphanExit>,
    ) -> Option<crate::agent_host::OrphanExit> {
        let Self::Known { servers, path, cwd } = self else { return None };
        exit.map(|e| crate::agent_host::OrphanExit {
            servers: servers.clone(),
            path: path.clone(),
            cwd: cwd.clone(),
            ..e
        })
    }

    /// Reads, once and before the harness of `family` is started as `launch`, the MCP servers
    /// its configs name, bounded by [`CENSUS_BUDGET`]; each start site awaits it before its
    /// spawn, so the census judges by what the harness could read at its start, never by a
    /// config edited after it.
    pub(crate) async fn read(launch: &crate::agent::Launch, family: String) -> Self {
        let path = launch.env.get("PATH").cloned().unwrap_or_default();
        let (at, cwd, launch) = (path.clone(), launch.cwd.clone(), launch.clone());
        let read = tokio::task::spawn_blocking(move || {
            resolved(from_launch(&family, &launch), &at, &launch.cwd)
        });
        match tokio::time::timeout(CENSUS_BUDGET, read).await {
            Ok(Ok(servers)) => Self::Known { servers, path, cwd },
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

/// `servers` with each one given by name resolved on `path`, each relative path in `cwd` (the
/// harness's folder: never acpmux's own), and each script's interpreter, without repeats.
fn resolved(mut servers: Vec<Sidecar>, path: &str, cwd: &Path) -> Vec<Sidecar> {
    for s in servers.iter_mut() {
        if !s.command.contains('/') {
            s.resolved = first_on_path(&s.command, path);
        } else if Path::new(&s.command).is_relative() {
            s.resolved = Some(cwd.join(&s.command).to_string_lossy().into_owned());
        }
        let program =
            s.resolved.as_deref().or(Path::new(&s.command).is_absolute().then_some(&*s.command));
        s.interpreter = program.and_then(|p| shebang(Path::new(p), path));
    }
    servers.dedup();
    servers
}

/// The interpreter a script's `#!` line runs: its program, or for `#!/usr/bin/env [-S] NAME`
/// the `NAME` that `path` runs. None for a file that is not a script or cannot be read.
fn shebang(script: &Path, path: &str) -> Option<String> {
    use std::io::Read;
    let mut head = [0u8; 256];
    let n = std::fs::File::open(script).ok()?.read(&mut head).ok()?;
    let line = head.get(..n)?.strip_prefix(b"#!")?;
    let line = std::str::from_utf8(line.split(|b| *b == b'\n').next()?).ok()?;
    // A `#!` line longer than the read has no newline in it: not one this census reads.
    if !head.get(..n)?.contains(&b'\n') {
        return None;
    }
    let mut words = line.split_whitespace();
    let program = words.next()?;
    if Path::new(program).file_name().is_some_and(|n| n == "env") {
        let name = words.find(|w| !w.starts_with('-'))?;
        return if name.contains('/') { Some(name.to_owned()) } else { first_on_path(name, path) };
    }
    Some(program.to_owned())
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
        for pair in launch.args.windows(2) {
            let [flag, value] = pair else { continue };
            if flag != "--mcp-config" {
                continue;
            }
            match serde_json::from_str::<Value>(value) {
                Ok(inline) if inline.is_object() => out.extend(from_json(inline.get("mcpServers"))),
                // A file, relative to the harness's folder.
                _ => {
                    let file = read_json(&cwd.join(value));
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

/// A server by its command and args, or None for an empty command. Args are kept word for word,
/// spaces and empty words included: the census compares exact argv (`runs`).
fn sidecar(command: &str, args: &[String]) -> Option<Sidecar> {
    (!command.is_empty()).then(|| Sidecar {
        command: command.to_owned(),
        args: args.to_vec(),
        resolved: None,
        interpreter: None,
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

/// Whether `who`, a process's executable and exact argv, is `s`: its argv's program is the
/// server's command (as configured, or the program `PATH` runs for a command given by name) and
/// its executable is that same file; or its argv's program is one of [`INTERPRETERS`] running the
/// server's program as a script (a `#!` line: `node /usr/local/bin/npx`) and its executable is the
/// interpreter that script's `#!` line runs. Then exactly the server's args. A server that is a
/// bare interpreter with no args says nothing about what it runs, so it never matches.
#[cfg(unix)]
fn runs(who: &crate::agent_host::tree::Identity, s: &Sidecar) -> bool {
    let interpreter = is_interpreter;
    if s.args.is_empty() && interpreter(&s.command) {
        return false;
    }
    let program = |w: &str| w == s.command || s.resolved.as_deref() == Some(w);
    let is_exe = |w: &str| runs_file(who, w);
    let runs_program = |first: &str| {
        program(first)
            && [Path::new(first).is_absolute().then_some(first), s.resolved.as_deref()]
                .into_iter()
                .flatten()
                .any(is_exe)
    };
    // A script given by a relative path (`./server.js`) is that path in the folder the process
    // runs in, which must be the server's file (`resolved`, in the harness's folder): one run from
    // another folder is another script.
    let script_is = |second: &str| {
        Path::new(second).is_absolute()
            || who
                .cwd
                .as_ref()
                .zip(s.resolved.as_deref())
                .is_some_and(|(cwd, server)| same_file(&cwd.join(second), Path::new(server)))
    };
    // A script: the executable must be the interpreter its `#!` line runs, not any file named
    // like one.
    let runs_script = |first: &str, second: &str| {
        interpreter(first)
            && second.contains('/')
            && program(second)
            && script_is(second)
            && s.interpreter.as_deref().is_some_and(is_exe)
    };
    let at = match who.argv.as_slice() {
        [first, ..] if runs_program(first) => 1,
        [first, second, ..] if runs_script(first, second) => 2,
        _ => return false,
    };
    who.argv.get(at..) == Some(s.args.as_slice())
}

/// Whether `who`'s executable is the file `w` names: the same path, or the same file once both
/// are canonical (a symlinked install, `/private/var` for `/var`). Only an absolute `w` is
/// canonicalized: a relative one would resolve in acpmux's folder (`resolved` holds a server's in
/// the harness's).
#[cfg(unix)]
fn runs_file(who: &crate::agent_host::tree::Identity, w: &str) -> bool {
    let w = Path::new(w);
    w == who.exe || (w.is_absolute() && same_file(w, &who.exe))
}

/// Whether `a` and `b` are one file once both are canonical; false when either is not there.
fn same_file(a: &Path, b: &Path) -> bool {
    let canonical = |p: &Path| std::fs::canonicalize(p).ok();
    canonical(a).is_some_and(|a| canonical(b) == Some(a))
}

/// Whether `w` names one of [`INTERPRETERS`] (`python3.12` included).
fn is_interpreter(w: &str) -> bool {
    let name = Path::new(w).file_name().map(|n| n.to_string_lossy().into_owned());
    let name = name.unwrap_or_default();
    INTERPRETERS.iter().any(|i| {
        name.strip_prefix(i)
            .is_some_and(|rest| rest.chars().all(|c| c.is_ascii_digit() || c == '.'))
    })
}

/// A launcher: an interpreter running a script by path (`node /home/u/.local/bin/codex -c x
/// app-server`, npm's Codex launcher). Its script's file name and the args after the script.
/// Argv is the leader's own to rewrite too, so the executable the kernel says it runs must be
/// that interpreter: the file argv names, or for a bare name (`node`, as `#!/usr/bin/env node`
/// runs it), the one the harness's `path` runs for that name. With no `path` known, a bare name
/// is no launcher.
#[cfg(unix)]
fn launcher<'a>(
    who: &'a crate::agent_host::tree::Identity,
    path: Option<&str>,
) -> Option<Launcher<'a>> {
    let [interp, script, args @ ..] = who.argv.as_slice() else { return None };
    if !is_interpreter(interp) || !script.starts_with('/') {
        return None;
    }
    let runs_interp = if interp.contains('/') {
        runs_file(who, interp)
    } else {
        path.and_then(|path| first_on_path(interp, path)).is_some_and(|i| runs_file(who, &i))
    };
    if !runs_interp {
        return None;
    }
    let name = Path::new(script).file_name()?.to_str()?;
    Some(Launcher { name, args, install: npm_install(Path::new(script))? })
}

/// A launcher (`launcher`): its script's file name, the args after the script, and the npm install
/// that holds the script (`npm_install`).
struct Launcher<'a> {
    name: &'a str,
    args: &'a [String],
    install: PathBuf,
}

/// The npm install that holds `script`: the outermost `node_modules` folder above the file it
/// really is (`<prefix>/bin/codex` links to `<prefix>/lib/node_modules/@openai/codex/bin/codex.js`).
/// npm puts the package's native program there too, nested in the package or hoisted beside it.
/// None for a script that is not in a `node_modules` folder.
fn npm_install(script: &Path) -> Option<PathBuf> {
    let real = std::fs::canonicalize(script).ok()?;
    real.ancestors()
        .filter(|a| a.file_name().is_some_and(|n| n == "node_modules"))
        .last()
        .map(Path::to_path_buf)
}

/// Whether `who` is the program a launcher (`launcher`) runs for itself: a program by absolute
/// path, not an interpreter, with the launcher's script name and exactly its args, and the file
/// the kernel says it runs. npm's Codex launcher runs its native `.../vendor/<triple>/bin/codex`
/// with its own args and relays stdio: that child is the harness, so its children are the
/// harness's children. Argv is the process's own to rewrite (`exec -a /tmp/codex ...`), so the
/// executable must be that program too, and it must be in the launcher's own npm install
/// (`npm_install`): a `codex` with the same args elsewhere (`/tmp/codex`) is other work.
#[cfg(unix)]
fn relays(who: &crate::agent_host::tree::Identity, launcher: &Launcher) -> bool {
    let [program, args @ ..] = who.argv.as_slice() else { return false };
    program.starts_with('/')
        && !is_interpreter(program)
        && Path::new(program).file_name().and_then(|n| n.to_str()) == Some(launcher.name)
        && args == launcher.args
        && runs_file(who, program)
        && std::fs::canonicalize(&who.exe).is_ok_and(|exe| exe.starts_with(&launcher.install))
}

/// A native wrapper (`wrapper`): the agent it names and the args it passes on.
struct Wrapper<'a> {
    name: &'a str,
    args: &'a [String],
}

/// A native wrapper harness: a program, not an interpreter, run as `WRAPPER NAME ARGS` with at
/// least one arg (`sr2 claude -p ...`, `sr codex -c ... app-server`). It runs the agent `NAME`
/// as its child with those args plus its own (`relays_for`), and that child starts the MCP
/// servers. Argv is the leader's own to rewrite too, so the executable the kernel says it runs
/// must be the wrapper: the file argv names, or for a bare name, the one the harness's `path`
/// runs. An agent run directly (`claude -p ...`, `codex app-server`) is no wrapper: its first arg
/// is a flag, or it has no args after it.
#[cfg(unix)]
fn wrapper<'a>(
    who: &'a crate::agent_host::tree::Identity,
    path: Option<&str>,
) -> Option<Wrapper<'a>> {
    let [program, name, args @ ..] = who.argv.as_slice() else { return None };
    let bare = !name.is_empty()
        && !name.starts_with('-')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if args.is_empty() || !bare || is_interpreter(program) {
        return None;
    }
    let runs_wrapper = if program.contains('/') {
        program.starts_with('/') && runs_file(who, program)
    } else {
        path.and_then(|path| first_on_path(program, path)).is_some_and(|w| runs_file(who, &w))
    };
    runs_wrapper.then_some(Wrapper { name, args })
}

/// Whether `who`, a child of a native wrapper (`wrapper`), is the agent it relays to: a program
/// by absolute path, not an interpreter, named the wrapper's `NAME` or `<prefix>-NAME`
/// (`cmux-codex` for `sr codex`), whose args hold the wrapper's args unchanged in one run (the
/// wrapper adds its own before them or after them), and the file the kernel says it runs.
#[cfg(unix)]
fn relays_for(who: &crate::agent_host::tree::Identity, wrapper: &Wrapper) -> bool {
    let [program, args @ ..] = who.argv.as_slice() else { return false };
    let Some(file) = Path::new(program).file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    let named = file == wrapper.name
        || file
            .strip_suffix(wrapper.name)
            .and_then(|prefix| prefix.strip_suffix('-'))
            .is_some_and(|prefix| !prefix.is_empty());
    program.starts_with('/')
        && !is_interpreter(program)
        && named
        && args.windows(wrapper.args.len()).any(|run| run == wrapper.args)
        && runs_file(who, program)
}

/// Whether `who` runs one of the harness's own helper programs: an absolute path in the same
/// folder as a relayed harness program (`relays`), named after it (`.../bin/codex-code-mode-host`
/// beside `.../bin/codex`), and the file the kernel says it runs. Only the helper itself: what
/// runs under it is judged on its own.
#[cfg(unix)]
fn part_of(who: &crate::agent_host::tree::Identity, harness_programs: &[String]) -> bool {
    let Some(program) = who.argv.first().filter(|w| w.starts_with('/')) else {
        return false;
    };
    let named = |p: &Path| p.file_name().and_then(|n| n.to_str()).map(str::to_owned);
    let beside = harness_programs.iter().map(Path::new).any(|h| {
        let program = Path::new(program);
        program.parent() == h.parent()
            && named(h).zip(named(program)).is_some_and(|(h, p)| p.starts_with(&format!("{h}-")))
    });
    beside && runs_file(who, program)
}

/// `Busy` with the first process that is neither a server (a child of the harness), under one, the
/// harness's relayed program (`relays`, or a native wrapper's agent: `relays_for`) nor one of its
/// helpers (`part_of`). Each is told by its identity (`identity_of`: exact argv, executable and
/// folder), the leader's own included (`launcher` or `wrapper`, a bare name looked up on `path`,
/// the harness's `PATH`), never by the line `ps`
/// prints; one whose identity cannot be read is none of them.
#[cfg(unix)]
fn classify(
    found: &[crate::agent_host::tree::Under],
    leader: u32,
    sidecars: &[Sidecar],
    path: Option<&str>,
    identity_of: impl Fn(u32) -> Option<crate::agent_host::tree::Identity>,
) -> Census {
    use crate::agent_host::tree::Identity;
    let leader_identity = identity_of(leader);
    let launched = leader_identity.as_ref().and_then(|who| launcher(who, path));
    let wrapped = match &launched {
        None => leader_identity.as_ref().and_then(|who| wrapper(who, path)),
        Some(_) => None,
    };
    let mut harness: Vec<u32> = vec![leader];
    let mut harness_programs: Vec<String> = Vec::new();
    let mut parts: Vec<u32> = Vec::new();
    let mut allowed: Vec<u32> = Vec::new();
    // Each child's identity is read once, however many passes look at it.
    let mut identities: std::collections::HashMap<u32, Option<Identity>> =
        std::collections::HashMap::new();
    let mut grew = true;
    while grew {
        grew = false;
        for p in found {
            if harness.contains(&p.pid) || parts.contains(&p.pid) || allowed.contains(&p.pid) {
                continue;
            }
            if allowed.contains(&p.ppid) {
                allowed.push(p.pid);
                grew = true;
                continue;
            }
            // The harness starts its servers, its relayed program and its helpers itself: only
            // its own children can be one.
            if !harness.contains(&p.ppid) {
                continue;
            }
            let Some(who) = &*identities.entry(p.pid).or_insert_with(|| identity_of(p.pid)) else {
                continue;
            };
            if sidecars.iter().any(|s| runs(who, s)) {
                allowed.push(p.pid);
            } else if launched.as_ref().is_some_and(|l| relays(who, l)) {
                harness.push(p.pid);
                harness_programs.extend(who.argv.first().cloned());
            } else if let Some(w) =
                wrapped.as_ref().filter(|w| p.ppid == leader && relays_for(who, w))
            {
                // Only the wrapper's own child is its agent. A renamed agent (`cmux-codex` for
                // `sr codex`) has helpers beside it named after the agent the wrapper named
                // (`codex-code-mode-host`). An agent under its own name (`sr2 claude` runs
                // `/opt/homebrew/bin/claude`) gets none: its folder is often a shared `bin`,
                // where `claude-*` is any program.
                harness.push(p.pid);
                let program = who.argv.first().map(Path::new);
                if program.and_then(Path::file_name).is_some_and(|f| f != w.name)
                    && let Some(program) = program
                {
                    let named = program.with_file_name(w.name);
                    harness_programs.push(named.to_string_lossy().into_owned());
                }
            } else if part_of(who, &harness_programs) {
                parts.push(p.pid);
            } else {
                continue;
            }
            grew = true;
        }
    }
    let known = |pid: &u32| harness.contains(pid) || parts.contains(pid) || allowed.contains(pid);
    match found.iter().find(|p| !known(&p.pid)) {
        Some(p) => {
            let first = p.args.split_whitespace().next().unwrap_or_default();
            let comm = Path::new(first).file_name().map_or(first.into(), |n| n.to_string_lossy());
            Census::Busy { pid: p.pid, comm: comm.into_owned() }
        }
        None => Census::Clear,
    }
}

#[cfg(all(test, unix))]
#[path = "idle_census_tests.rs"]
mod tests;
