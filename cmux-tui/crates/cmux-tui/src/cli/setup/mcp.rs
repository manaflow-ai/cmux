//! `cmux setup mcp [claude|codex ...] [--dry-run]`: gives Claude Code and
//! Codex the cmux MCP server (`cmux mcp serve`) when they run outside cmux,
//! in a terminal or another app. Chats cmux starts already get it, and
//! cmux-cua, from acpmux (`agent_tools`); cmux-cua needs the app's
//! per-session socket token, so no user config can hold it.
//!
//! Each harness's own CLI writes its own config (`claude mcp add --scope
//! user`, `codex mcp add`), so the file keeps its one writer; setup only
//! reads the user-scope config to see what is there: `~/.claude.json` (or
//! `$CLAUDE_CONFIG_DIR/.claude.json`) and `$CODEX_HOME/config.toml`. An
//! entry that runs `cmux mcp serve` from a command that still runs is `ok`.
//! One named `cmux` whose command is gone (an app that moved) is replaced;
//! one named `cmux` that runs something else is the person's, and is left.
//!
//! `cmux mcp serve` answers a client outside a cmux chat only when the
//! settings file says `"mcp": {"enabled": true}`, the person's opt-in, which
//! is not a key agents set. Until it is on, setup writes nothing and the
//! result is `needs_user` naming that switch. With neither harness installed
//! (and none named) there is nothing to wire: `ok`, switch or not.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::agents_doctor::{on_path, read_json, read_text, toml_error};
use super::super::fix_command::quote_arg;
use super::{Outcome, Refusal};
use cmux_json::JsonSet as _;

const TASK: &str = "mcp";

/// The name the cmux server gets in each harness's config.
const SERVER: &str = "cmux";

/// The longest `claude mcp add` or `codex mcp add` may take.
const CLI_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Client {
    Claude,
    Codex,
}

const CLIENTS: [Client; 2] = [Client::Claude, Client::Codex];

impl Client {
    fn parse(id: &str) -> Option<Self> {
        CLIENTS.into_iter().find(|client| client.id() == id)
    }

    /// Its id, which is also its CLI.
    fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
        }
    }

    /// The user-scope config the harness's `mcp add` writes.
    fn config(self) -> Option<PathBuf> {
        let dir = |key: &str| std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from);
        match self {
            Self::Claude => {
                dir("CLAUDE_CONFIG_DIR").or_else(|| dir("HOME")).map(|d| d.join(".claude.json"))
            }
            Self::Codex => dir("CODEX_HOME")
                .or_else(|| dir("HOME").map(|home| home.join(".codex")))
                .map(|d| d.join("config.toml")),
        }
    }

    /// The servers of that config.
    fn servers(self, file: &Path) -> Result<Vec<Entry>, String> {
        let shown = file.display();
        match self {
            Self::Claude => {
                let config = read_json(file).map_err(|error| format!("{shown}: {error}"))?;
                let servers =
                    config.as_ref().and_then(|c| c.get("mcpServers")).and_then(Value::as_object);
                Ok(servers
                    .into_iter()
                    .flatten()
                    .map(|(name, server)| Entry {
                        name: name.clone(),
                        command: server.get("command").and_then(Value::as_str).map(str::to_owned),
                        args: server
                            .get("args")
                            .and_then(Value::as_array)
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect(),
                    })
                    .collect())
            }
            Self::Codex => {
                let Some(text) = read_text(file).map_err(|error| format!("{shown}: {error}"))?
                else {
                    return Ok(Vec::new());
                };
                let config = text
                    .parse::<toml::Table>()
                    .map_err(|error| format!("{shown}: {}", toml_error(&text, &error)))?;
                let servers = config.get("mcp_servers").and_then(toml::Value::as_table);
                Ok(servers
                    .into_iter()
                    .flatten()
                    .map(|(name, server)| Entry {
                        name: name.clone(),
                        command: server
                            .get("command")
                            .and_then(toml::Value::as_str)
                            .map(str::to_owned),
                        args: server
                            .get("args")
                            .and_then(toml::Value::as_array)
                            .into_iter()
                            .flatten()
                            .filter_map(toml::Value::as_str)
                            .map(str::to_owned)
                            .collect(),
                    })
                    .collect())
            }
        }
    }

    /// `mcp add` of the server named `cmux` that runs `command args`.
    fn add(self, command: &str, args: &[String]) -> Vec<String> {
        let scope: &[&str] = match self {
            Self::Claude => &["--scope", "user"],
            Self::Codex => &[],
        };
        ["mcp", "add"]
            .iter()
            .chain(scope)
            .chain(&[SERVER, "--", command])
            .map(|arg| (*arg).to_owned())
            .chain(args.iter().cloned())
            .collect()
    }

    /// `mcp remove` of the server named `cmux`.
    fn remove(self) -> Vec<String> {
        let scope: &[&str] = match self {
            Self::Claude => &["--scope", "user"],
            Self::Codex => &[],
        };
        ["mcp", "remove"]
            .iter()
            .chain(scope)
            .chain(&[SERVER])
            .map(|arg| (*arg).to_owned())
            .collect()
    }

    /// `args` as the shell line an agent runs.
    fn line(self, args: &[String]) -> String {
        std::iter::once(self.id().to_owned())
            .chain(args.iter().map(|arg| quote_arg(arg)))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// One MCP server in a harness's config.
struct Entry {
    name: String,
    command: Option<String>,
    args: Vec<String>,
}

impl Entry {
    /// Whether it runs `cmux mcp serve`, from any cmux build's CLI.
    fn serves_cmux(&self) -> bool {
        let program = self.command.as_deref().map(Path::new).and_then(Path::file_name);
        program.and_then(OsStr::to_str).is_some_and(|name| name.starts_with("cmux"))
            && self.args.iter().map(String::as_str).take(2).eq(["mcp", "serve"])
    }

    /// Whether its command is still there to run.
    fn runs(&self, path: Option<&OsStr>) -> bool {
        use std::os::unix::fs::PermissionsExt;
        match self.command.as_deref() {
            Some(command) if command.contains('/') => std::fs::metadata(command)
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0),
            Some(command) => on_path(path, command).is_some(),
            None => false,
        }
    }

    fn json(&self) -> Value {
        json!({"name": self.name, "command": self.command, "args": self.args})
    }
}

/// What setup does for one harness.
enum Plan {
    /// Not installed, and not named.
    Absent,
    /// Already gives the cmux server.
    Ok,
    Add,
    /// Replaces the `cmux` entry whose command is gone.
    Replace,
    /// The person must act: this `user_action`.
    Person(Value),
    Failed(String),
}

struct Request {
    clients: Vec<Client>,
    dry_run: bool,
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let command = this_cli()?;
    let (settings, enabled) = super::super::mcp::outside_chats();
    let path = std::env::var_os("PATH");
    let clients =
        if request.clients.is_empty() { CLIENTS.to_vec() } else { request.clients.clone() };
    let mut rows = Vec::new();
    let mut undo = Vec::new();
    let off = match &enabled {
        Ok(true) => None,
        Ok(false) => Some(switch(&settings, None)),
        Err(error) => Some(switch(&settings, Some(error.as_str()))),
    };
    let mut user_action = Value::Null;
    let (mut failed, mut planned, mut changed, mut installed) = (false, false, false, false);
    for client in clients {
        let (next, found) = plan(client, request.clients.contains(&client), path.as_deref());
        let here = on_path(path.as_deref(), client.id()).is_some();
        installed |= here;
        let mut row = json!({
            "id": client.id(),
            "name": client.name(),
            "installed": here,
            "config": client.config(),
            "entry": found.as_ref().map(Entry::json),
            "undo": Value::Null,
            "user_action": Value::Null,
            "error": Value::Null,
        });
        let state = match next {
            Plan::Absent => "not_applicable",
            Plan::Ok => "ok",
            Plan::Person(action) => {
                if user_action.is_null() {
                    user_action = action.clone();
                }
                row.set("user_action", action);
                "needs_user"
            }
            Plan::Failed(error) => {
                row.set("error", json!(error));
                failed = true;
                "failed"
            }
            // Nothing is written while the switch is off: the server would
            // refuse the harness.
            Plan::Add | Plan::Replace if enabled != Ok(true) || request.dry_run => {
                planned = true;
                "planned"
            }
            Plan::Add | Plan::Replace => {
                match apply(client, &command, found.as_ref().filter(|e| e.name == SERVER)) {
                    Ok(line) => {
                        row.set("undo", json!(line));
                        undo.push(line);
                        changed = true;
                        "changed"
                    }
                    Err(error) => {
                        row.set("error", json!(error));
                        failed = true;
                        "failed"
                    }
                }
            }
        };
        row.set("state", json!(state));
        rows.push(row);
    }
    // The switch comes first, but only when a harness is there to wire:
    // with none installed there is nothing to do, or the install comes first.
    if let Some(action) = off.filter(|_| installed) {
        user_action = action;
    }
    let state = if failed {
        "failed"
    } else if !user_action.is_null() {
        "needs_user"
    } else if changed {
        "changed"
    } else if planned {
        "planned"
    } else {
        "ok"
    };
    let report = json!({
        "schema_version": 1,
        "task": TASK,
        "state": state,
        "dry_run": request.dry_run,
        "server": {"name": SERVER, "command": command, "args": ["mcp", "serve"]},
        "settings": settings,
        "enabled": enabled == Ok(true),
        "clients": rows,
        "undo": (!undo.is_empty()).then(|| undo.join(" && ")),
        "user_action": user_action,
    });
    Ok(Outcome { report, failed })
}

/// The check `cmux setup status` reports: the switch, and whether each
/// installed harness gives the cmux server outside cmux. With none
/// installed it is `ok`, as `run` is: the switch has nothing to serve.
pub(super) fn status() -> Value {
    let (settings, enabled) = super::super::mcp::outside_chats();
    let path = std::env::var_os("PATH");
    let clients: Vec<Value> = CLIENTS
        .into_iter()
        .filter_map(|client| {
            let (next, found) = plan(client, false, path.as_deref());
            let state = match next {
                Plan::Absent => return None,
                Plan::Ok => "ok",
                Plan::Add | Plan::Replace => "needs_setup",
                Plan::Person(_) => "needs_user",
                Plan::Failed(_) => "failed",
            };
            Some(json!({"id": client.id(), "state": state, "entry": found.as_ref().map(Entry::json)}))
        })
        .collect();
    let ready = (clients.is_empty() || enabled == Ok(true))
        && clients.iter().all(|client| client["state"] == "ok");
    json!({
        "task": TASK,
        "state": if ready { "ok" } else { "needs_setup" },
        "settings": settings,
        "enabled": enabled == Ok(true),
        "clients": clients,
        "fix": (!ready).then_some("cmux setup mcp"),
    })
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut request = Request { clients: Vec::new(), dry_run: false };
    for arg in args {
        match arg.as_str() {
            "--dry-run" => request.dry_run = true,
            flag if flag.starts_with('-') => {
                return Err(Refusal::Usage(format!("cmux: setup mcp: unknown option {flag:?}")));
            }
            id => {
                let client = Client::parse(id).ok_or_else(|| {
                    Refusal::Usage(format!(
                        "cmux: setup mcp: no client {id:?}; give claude or codex"
                    ))
                })?;
                if !request.clients.contains(&client) {
                    request.clients.push(client);
                }
            }
        }
    }
    Ok(request)
}

/// This cmux's own path: the command the harness runs.
fn this_cli() -> Result<String, Refusal> {
    std::env::current_exe()
        .map(|exe| exe.to_string_lossy().into_owned())
        .map_err(|error| Refusal::Failed(format!("cmux: setup mcp: no path to this cmux: {error}")))
}

/// What setup does for `client`, and the entry that decided it. A harness
/// that is not installed is the person's only when it was named.
fn plan(client: Client, named: bool, path: Option<&OsStr>) -> (Plan, Option<Entry>) {
    if on_path(path, client.id()).is_none() {
        if !named {
            return (Plan::Absent, None);
        }
        let setup = format!("cmux setup harness {}", client.id());
        let action = json!({
            "kind": "install",
            "text": format!(
                "Install {}: `{}` is not on PATH; `{setup}` says how",
                client.name(),
                client.id()
            ),
            "command": setup,
            "url": Value::Null,
        });
        return (Plan::Person(action), None);
    }
    let Some(file) = client.config() else {
        return (Plan::Failed("no home directory".into()), None);
    };
    let mut entries = match client.servers(&file) {
        Ok(entries) => entries,
        Err(error) => return (Plan::Failed(error), None),
    };
    if let Some(at) = entries.iter().position(|entry| entry.serves_cmux() && entry.runs(path)) {
        return (Plan::Ok, Some(entries.swap_remove(at)));
    }
    let Some(at) = entries.iter().position(|entry| entry.name == SERVER) else {
        return (Plan::Add, None);
    };
    let taken = entries.swap_remove(at);
    if taken.serves_cmux() {
        return (Plan::Replace, Some(taken));
    }
    let remove = client.line(&client.remove());
    let action = json!({
        "kind": "conflict",
        "text": format!(
            "{} already has an MCP server named `{SERVER}` that does not run `cmux mcp serve`. \
             If it is no longer needed, `{remove}` removes it; then run `cmux setup mcp {}` again",
            client.name(),
            client.id()
        ),
        "command": remove,
        "url": Value::Null,
    });
    (Plan::Person(action), Some(taken))
}

/// Adds the cmux server to `client`, removing `old` (the `cmux` entry whose
/// command is gone) first, and answers the line that undoes it. When the add
/// fails after the remove, the error names the line that puts `old` back.
fn apply(client: Client, command: &str, old: Option<&Entry>) -> Result<String, String> {
    let remove = client.remove();
    let restore = old.and_then(|old| {
        old.command.as_deref().map(|command| client.line(&client.add(command, &old.args)))
    });
    if old.is_some() {
        run_cli(client, &remove)?;
    }
    run_cli(client, &client.add(command, &["mcp".into(), "serve".into()])).map_err(|error| {
        match &restore {
            Some(restore) => format!("{error}; `{restore}` puts the old entry back"),
            None => error,
        }
    })?;
    let undo = client.line(&remove);
    Ok(match restore {
        Some(restore) => format!("{undo} && {restore}"),
        None => undo,
    })
}

/// Runs `client`'s CLI with `args`, within [`CLI_TIMEOUT`].
fn run_cli(client: Client, args: &[String]) -> Result<(), String> {
    use std::io::Read;
    let line = client.line(args);
    let mut child = std::process::Command::new(client.id())
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| format!("`{line}`: {error}"))?;
    // Read on its own thread, so a CLI that writes more than the pipe holds
    // never blocks on it.
    let stderr = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut text = String::new();
            let _ = pipe.read_to_string(&mut text);
            text
        })
    });
    let deadline = Instant::now() + CLI_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => {
                // A bounded wait for one child, polled in 20 ms steps: std
                // has no wait with a timeout.
                std::thread::sleep(Duration::from_millis(20));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("`{line}` did not finish in {}s", CLI_TIMEOUT.as_secs()));
            }
            // The child may still run: stop it before reporting, as on a timeout.
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("`{line}`: {error}"));
            }
        }
    };
    if status.success() {
        return Ok(());
    }
    let text = stderr.and_then(|reader| reader.join().ok()).unwrap_or_default();
    let text: String = text.trim().chars().take(2000).collect();
    Err(format!("`{line}` failed ({status}): {text}"))
}

/// The person's switch for MCP clients outside cmux, and why the settings
/// file could not be read when it could not.
fn switch(settings: &Path, unreadable: Option<&str>) -> Value {
    let why =
        unreadable.map(|error| format!(" (it cannot be read now: {error})")).unwrap_or_default();
    json!({
        "kind": "setting",
        "text": format!(
            "Turn on the cmux MCP server for agents outside cmux: add \"mcp\": {{\"enabled\": true}} \
             to {}{why}, then run `cmux setup mcp` again",
            settings.display()
        ),
        "command": Value::Null,
        "url": Value::Null,
    })
}
