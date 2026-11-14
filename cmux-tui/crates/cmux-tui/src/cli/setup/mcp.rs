//! `cmux setup mcp [claude|codex ...] [--dry-run] [--remove]`: gives Claude
//! Code and Codex the cmux MCP server (`cmux mcp serve`) when they run outside
//! cmux, in a terminal or another app, or with `--remove` takes cmux's own
//! entry out of their configs again. Chats cmux starts already get it, and
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
//!
//! The person's answer to "may cmux add its tools to your coding agents?"
//! (`agents.cmuxMcp`: the onboarding step, Settings > Agents) decides too.
//! `on` is the opt-in above (it turns the server on unless `mcp.enabled`
//! says otherwise, `cli/mcp/config.rs`); `off` writes nothing, names that
//! answer as the setting to change, and makes `status` content (the person
//! declined, nothing is missing); unanswered keeps the switch's rule.
//! `--remove` runs whatever the answer is: it only takes out an entry named
//! `cmux` that runs `cmux mcp serve`, never a server of the person's.
//!
//! Only a shipped build (release or nightly) on the shared settings file
//! writes the person's global agent configs (`mcp_writer`). Any other cmux
//! (a tagged DEV build, DerivedData, RC or staging, or one on its own
//! settings file) does a dry run: it writes and removes nothing, and reports
//! `"scope": "terminals"` with why and the shim folder through which its own
//! terminals give their agents cmux's server. Its agents get the server from
//! the `claude` and `codex` shims (`agent_mcp_choice`), with the terminal's
//! settings file, never from a global entry.
//!
//! A shipped build writes its own path (`this_cli`) with no `env`. It
//! replaces a `cmux` entry whose command is gone or runs from a DEV build
//! (decided by the command alone), or that names a settings file which is
//! gone; the undo line puts it back. An entry with anything setup cannot put
//! back is left alone (`keep`).

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::agents_doctor::{on_path, read_json, read_text, toml_error};
use super::super::fix_command::quote_arg;
use super::mcp_writer::{RESTORABLE_ENV, Writer, dev_build, settings_path, writer};
use super::{Outcome, Refusal};
use cmux_json::JsonSet as _;
use cmux_tui_core::user_settings::{AgentsCmuxMcp, CONFIG_OVERRIDE};

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
                        env: server
                            .get("env")
                            .and_then(Value::as_object)
                            .into_iter()
                            .flatten()
                            .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                            .collect(),
                        unread: unread_json(server),
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
                        env: server
                            .get("env")
                            .and_then(toml::Value::as_table)
                            .into_iter()
                            .flatten()
                            .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
                            .collect(),
                        unread: unread_toml(server),
                    })
                    .collect())
            }
        }
    }

    /// `mcp add` of the server named `cmux` that runs `command args` with
    /// `env`. Each `--env KEY=VALUE` goes before the scope and the name:
    /// Claude Code's `--env` takes several values, so the next option
    /// (`--scope`) ends it before the name, and Codex takes one per flag.
    fn add(self, command: &str, args: &[String], env: &[(String, String)]) -> Vec<String> {
        let scope: &[&str] = match self {
            Self::Claude => &["--scope", "user"],
            Self::Codex => &[],
        };
        let env =
            env.iter().flat_map(|(key, value)| ["--env".to_owned(), format!("{key}={value}")]);
        ["mcp", "add"]
            .iter()
            .map(|arg| (*arg).to_owned())
            .chain(env)
            .chain(scope.iter().chain(&[SERVER, "--", command]).map(|arg| (*arg).to_owned()))
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
    /// Its `env` (string values only).
    env: Vec<(String, String)>,
    /// What setup did not read into the fields above, so could not put back:
    /// another field (Codex `cwd`, `env_vars`, `startup_timeout_sec`,
    /// `enabled_tools`), an `env` value or `args` item that is no string.
    unread: Vec<String>,
}

/// Fields a Claude Code stdio entry may have that setup reads or rewrites.
const CLAUDE_FIELDS: [&str; 4] = ["type", "command", "args", "env"];
/// Fields a Codex entry may have that setup reads.
const CODEX_FIELDS: [&str; 3] = ["command", "args", "env"];

/// What of the Claude Code entry `server` setup does not read ([`Entry::unread`]).
fn unread_json(server: &Value) -> Vec<String> {
    let Some(fields) = server.as_object() else { return vec!["the entry".into()] };
    let mut unread: Vec<String> =
        fields.keys().filter(|key| !CLAUDE_FIELDS.contains(&key.as_str())).cloned().collect();
    if fields.get("type").is_some_and(|kind| kind.as_str() != Some("stdio")) {
        unread.push("type".into());
    }
    if let Some(args) = fields.get("args")
        && args.as_array().is_none_or(|args| args.iter().any(|arg| !arg.is_string()))
    {
        unread.push("args".into());
    }
    match fields.get("env") {
        Some(Value::Object(env)) => unread
            .extend(env.iter().filter(|(_, v)| !v.is_string()).map(|(k, _)| format!("env {k}"))),
        Some(_) => unread.push("env".into()),
        None => {}
    }
    unread
}

/// What of the Codex entry `server` setup does not read ([`Entry::unread`]).
fn unread_toml(server: &toml::Value) -> Vec<String> {
    let Some(fields) = server.as_table() else { return vec!["the entry".into()] };
    let mut unread: Vec<String> =
        fields.keys().filter(|key| !CODEX_FIELDS.contains(&key.as_str())).cloned().collect();
    if let Some(args) = fields.get("args")
        && args.as_array().is_none_or(|args| args.iter().any(|arg| !arg.is_str()))
    {
        unread.push("args".into());
    }
    match fields.get("env") {
        Some(toml::Value::Table(env)) => {
            unread.extend(env.iter().filter(|(_, v)| !v.is_str()).map(|(k, _)| format!("env {k}")));
        }
        Some(_) => unread.push("env".into()),
        None => {}
    }
    unread
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

    /// The settings file its `env` names (`CMUX_NEXT_CONFIG_FILE`); `None`
    /// for the shared one.
    fn settings_file(&self) -> Option<&str> {
        self.env.iter().find(|(key, _)| key == CONFIG_OVERRIDE).map(|(_, value)| value.as_str())
    }

    /// What setup could not put back if it replaced or removed this entry:
    /// [`Entry::unread`], and every `env` key outside [`RESTORABLE_ENV`] (a
    /// token, a proxy, a cmux secret such as `CMUX_SOCKET_PASSWORD`). Setup
    /// leaves an entry with any of these alone and names them to the person.
    fn unrestorable(&self) -> Vec<String> {
        let mut lost = self.unread.clone();
        lost.extend(
            self.env
                .iter()
                .filter(|(key, _)| !RESTORABLE_ENV.contains(&key.as_str()))
                .map(|(key, _)| format!("env {key}")),
        );
        lost
    }

    /// What adds it back: its command, args and `env`. Only a
    /// [`RESTORABLE_ENV`] value is printed (the line goes in the report); any
    /// other key reads `<value of KEY>` and is named in [`Restore::hidden`].
    /// Setup restores only entries with nothing [`Entry::unrestorable`], so
    /// that never happens in practice.
    fn restore(&self, client: Client) -> Option<Restore> {
        let shown = |key: &str| RESTORABLE_ENV.contains(&key);
        let env: Vec<(String, String)> = self
            .env
            .iter()
            .map(|(key, value)| {
                let value = if shown(key) { value.clone() } else { format!("<value of {key}>") };
                (key.clone(), value)
            })
            .collect();
        let mut hidden: Vec<String> =
            self.env.iter().map(|(key, _)| key).filter(|key| !shown(key)).cloned().collect();
        hidden.extend(self.unread.iter().cloned());
        let command = self.command.as_deref()?;
        Some(Restore { line: client.line(&client.add(command, &self.args, &env)), hidden })
    }

    /// Whether a shipped build wrote it, by its command: a command that is no
    /// DEV build's ([`dev_build`]; a bare name on PATH counts as shipped),
    /// whatever settings file its `env` names.
    fn shipped(&self) -> bool {
        self.command.as_deref().is_none_or(|command| dev_build(Path::new(command)).is_none())
    }

    /// Whether the settings file its `env` names is there, a leading `~`
    /// expanded (no file named: the shared one, always). A file that is gone
    /// (a scratch launch's) would leave the server reading nothing, so the
    /// entry is replaced.
    fn settings_file_exists(&self) -> bool {
        self.settings_file()
            .is_none_or(|file| settings_path(file, &|key| std::env::var_os(key)).is_file())
    }

    /// For the report: no `env` values beyond the settings file, since a
    /// server of the person's may keep a secret there.
    fn json(&self) -> Value {
        json!({"name": self.name, "command": self.command, "args": self.args,
               "settings_file": self.settings_file()})
    }
}

/// The line that puts an entry back, and the `env` keys whose values it does
/// not show (they read `<value of KEY>`).
struct Restore {
    line: String,
    hidden: Vec<String>,
}

impl Restore {
    /// Why the line does not put the entry back exactly, when it does not.
    fn note(hidden: &[String]) -> Option<String> {
        (!hidden.is_empty()).then(|| {
            format!(
                "The undo line does not put back all of the old entry: {} (values read \
                 <value of KEY>; put each in place before you run it)",
                hidden.join(", ")
            )
        })
    }
}

/// What setup does for one harness.
enum Plan {
    /// Not installed, and not named.
    Absent,
    /// Already gives the cmux server.
    Ok,
    Add,
    /// Replaces the `cmux` entry whose command is gone or runs from a DEV
    /// build, or that names a settings file which is gone.
    Replace,
    /// The person must act: this `user_action`.
    Person(Value),
    Failed(String),
}

#[derive(Default)]
struct Request {
    clients: Vec<Client>,
    dry_run: bool,
    remove: bool,
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let command = this_cli()?;
    if let Writer::Terminals(why) = writer(Path::new(&command), |key| std::env::var_os(key)) {
        return Ok(terminals(&request, &command, &why));
    }
    if request.remove {
        return Ok(remove(&request, false));
    }
    let (settings, enabled) = super::super::mcp::outside_chats();
    let choice = AgentsCmuxMcp::from_config_file(&settings);
    let path = std::env::var_os("PATH");
    let clients =
        if request.clients.is_empty() { CLIENTS.to_vec() } else { request.clients.clone() };
    let mut rows = Vec::new();
    let mut undo = Vec::new();
    let off = match &enabled {
        _ if choice == AgentsCmuxMcp::Off => Some(declined()),
        // No answer yet: the question is the person's to answer, whatever
        // `mcp.enabled` says (an agent can write that key; it is no answer).
        _ if choice == AgentsCmuxMcp::Ask => Some(unanswered()),
        Ok(true) => None,
        Ok(false) => Some(switch(&settings, None)),
        Err(error) => Some(switch(&settings, Some(error.as_str()))),
    };
    let mut user_action = Value::Null;
    let (mut failed, mut planned, mut changed, mut installed) = (false, false, false, false);
    let mut inexact = false;
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
            // Nothing is written until the person said yes (agents.cmuxMcp
            // `on`), or while the switch is off: the server would refuse the harness.
            Plan::Add | Plan::Replace
                if choice != AgentsCmuxMcp::On || enabled != Ok(true) || request.dry_run =>
            {
                planned = true;
                "planned"
            }
            Plan::Add | Plan::Replace => {
                match apply(client, &command, found.as_ref().filter(|e| e.name == SERVER)) {
                    Ok((line, hidden)) => {
                        row.set("undo", json!(line));
                        if let Some(note) = Restore::note(&hidden) {
                            row.set("undo_exact", json!(false));
                            row.set("undo_note", json!(note));
                            inexact = true;
                        }
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
    // A person's no names itself only when it kept something from being written.
    let declined = choice != AgentsCmuxMcp::On;
    if let Some(action) = off.filter(|_| installed && (!declined || planned)) {
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
        "server": {"name": SERVER, "command": command, "args": ["mcp", "serve"], "env": {}},
        "settings": settings,
        "enabled": enabled == Ok(true),
        "choice": choice.as_str(),
        "clients": rows,
        "undo": (!undo.is_empty()).then(|| undo.join(" && ")),
        "undo_exact": !inexact,
        "user_action": user_action,
    });
    Ok(Outcome { report, failed })
}

/// `--remove`: takes cmux's own entry (named `cmux`, running `cmux mcp
/// serve`, from any cmux build) out of each installed harness's config, or
/// of each named one, through the harness's own `mcp remove`. A `cmux` entry
/// that runs something else is the person's and stays. Runs whatever
/// `agents.cmuxMcp` says: taking cmux out never oversteps.
///
/// With `only_unshipped` (a DEV build, [`Writer::Terminals`]) it takes out
/// only an entry whose command runs from a development build or a temporary
/// cache ([`Entry::shipped`] is false: a DEV bundle, DerivedData, an
/// unbundled build outside a release install). The settings file an entry
/// names does not count. Any other entry stays, and says so.
fn remove(request: &Request, only_unshipped: bool) -> Outcome {
    let (settings, enabled) = super::super::mcp::outside_chats();
    let choice = AgentsCmuxMcp::from_config_file(&settings);
    let path = std::env::var_os("PATH");
    let clients =
        if request.clients.is_empty() { CLIENTS.to_vec() } else { request.clients.clone() };
    let (mut rows, mut undo) = (Vec::new(), Vec::new());
    let (mut failed, mut planned, mut changed, mut inexact) = (false, false, false, false);
    let mut user_action = Value::Null;
    for client in clients {
        let here = on_path(path.as_deref(), client.id()).is_some();
        let mut row = json!({
            "id": client.id(),
            "name": client.name(),
            "installed": here,
            "config": client.config(),
            "entry": Value::Null,
            "undo": Value::Null,
            "user_action": Value::Null,
            "error": Value::Null,
        });
        let found = if here {
            match client
                .config()
                .ok_or_else(|| "no home directory".to_owned())
                .and_then(|file| client.servers(&file))
            {
                Ok(entries) => Ok(entries
                    .into_iter()
                    .find(|entry| entry.name == SERVER && entry.serves_cmux())),
                Err(error) => Err(error),
            }
        } else {
            Ok(None)
        };
        let state = match found {
            _ if !here => "not_applicable",
            Err(error) => {
                row.set("error", json!(error));
                failed = true;
                "failed"
            }
            Ok(None) => "ok",
            Ok(Some(entry)) if only_unshipped && entry.shipped() => {
                row.set("entry", entry.json());
                row.set(
                    "kept",
                    json!("this entry runs no development build of cmux; this build leaves it"),
                );
                "ok"
            }
            Ok(Some(entry)) if !entry.unrestorable().is_empty() => {
                row.set("entry", entry.json());
                let action = keep(client, &entry.unrestorable(), true);
                if user_action.is_null() {
                    user_action = action.clone();
                }
                row.set("user_action", action);
                "needs_user"
            }
            Ok(Some(entry)) => {
                row.set("entry", entry.json());
                if request.dry_run {
                    planned = true;
                    "planned"
                } else {
                    match run_cli(client, &client.remove()) {
                        Ok(()) => {
                            if let Some(restore) = entry.restore(client) {
                                row.set("undo", json!(restore.line));
                                if let Some(note) = Restore::note(&restore.hidden) {
                                    row.set("undo_exact", json!(false));
                                    row.set("undo_note", json!(note));
                                    inexact = true;
                                }
                                undo.push(restore.line);
                            }
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
            }
        };
        row.set("state", json!(state));
        rows.push(row);
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
        "action": "remove",
        "state": state,
        "dry_run": request.dry_run,
        "server": {"name": SERVER, "args": ["mcp", "serve"]},
        "settings": settings,
        "enabled": enabled == Ok(true),
        "choice": choice.as_str(),
        "clients": rows,
        "undo": (!undo.is_empty()).then(|| undo.join(" && ")),
        "undo_exact": !inexact,
        "user_action": user_action,
    });
    Outcome { report, failed }
}

/// A cmux that may not write the person's global agent configs
/// ([`Writer::Terminals`]). Adding is a dry run that writes nothing: each
/// installed agent is `terminals` once the person said yes (`agents.cmuxMcp`
/// on) and the server serves them (`mcp.enabled` not false): this build's
/// terminals give it cmux's server through the `claude` and `codex` shims,
/// with the terminal's settings file. With the switch off the shim's server
/// would refuse, so the result names that switch, as [`run`] does. An entry a
/// DEV build left in an agent's config (not [`Entry::shipped`]) is named,
/// with the line that removes it. `--remove` takes out only such entries,
/// never a shipped build's. The report names `why` and the shim folder.
fn terminals(request: &Request, command: &str, why: &str) -> Outcome {
    let shims = crate::own_build_helpers::wrapper_shim_dir(Path::new(command));
    let shims_text = shims.as_ref().map(|dir| format!(" ({})", dir.display())).unwrap_or_default();
    if request.remove {
        let mut outcome = remove(request, true);
        outcome.report.set("scope", json!("terminals"));
        outcome.report.set(
            "terminals",
            json!({
                "why": why,
                "shims": shims,
                "text": format!(
                    "{why}: --remove takes out only entries whose command runs from a \
                     development build of cmux (a DEV app, DerivedData, a build folder) or a \
                     temporary cache; any other entry stays"
                ),
            }),
        );
        return outcome;
    }
    let (settings, enabled) = super::super::mcp::outside_chats();
    let choice = AgentsCmuxMcp::from_config_file(&settings);
    let serves = choice == AgentsCmuxMcp::On && enabled == Ok(true);
    let path = std::env::var_os("PATH");
    let clients =
        if request.clients.is_empty() { CLIENTS.to_vec() } else { request.clients.clone() };
    let mut installed = false;
    let mut stale = Vec::new();
    let rows: Vec<Value> = clients
        .into_iter()
        .map(|client| {
            let here = on_path(path.as_deref(), client.id()).is_some();
            installed |= here;
            let state = match () {
                _ if !here => "not_applicable",
                _ if serves => "terminals",
                _ => "planned",
            };
            let left = here
                .then(|| client.config().and_then(|file| client.servers(&file).ok()))
                .flatten()
                .and_then(|entries| {
                    entries.into_iter().find(|entry| {
                        entry.name == SERVER && entry.serves_cmux() && !entry.shipped()
                    })
                });
            let remove = left.as_ref().map(|_| client.line(&client.remove()));
            if let Some(line) = &remove {
                stale.push(format!("{} (`{line}`)", client.name()));
            }
            json!({
                "id": client.id(),
                "name": client.name(),
                "installed": here,
                "config": client.config(),
                "entry": Value::Null,
                "stale_entry": left.as_ref().map(Entry::json),
                "remove": remove,
                "undo": Value::Null,
                "user_action": Value::Null,
                "error": Value::Null,
                "state": state,
            })
        })
        .collect();
    // Only the person answers the question; a yes with the switch off needs
    // the switch (the shim's server would refuse); a no needs nothing more.
    let user_action = match &enabled {
        _ if !installed => Value::Null,
        _ if choice == AgentsCmuxMcp::Ask => unanswered(),
        _ if choice == AgentsCmuxMcp::Off => Value::Null,
        Ok(true) => Value::Null,
        Ok(false) => switch(&settings, None),
        Err(error) => switch(&settings, Some(error.as_str())),
    };
    let stale_text = if stale.is_empty() {
        String::new()
    } else {
        format!(
            ". An old cmux entry from a development build is still in the settings of {}: \
             `cmux setup mcp --remove` from this build takes it out (never a shipped cmux's \
             entry), or run that line",
            stale.join(", ")
        )
    };
    let report = json!({
        "schema_version": 1,
        "task": TASK,
        "state": if user_action.is_null() { "ok" } else { "needs_user" },
        "scope": "terminals",
        "dry_run": true,
        "server": {"name": SERVER, "command": command, "args": ["mcp", "serve"], "env": {}},
        "settings": settings,
        "enabled": enabled == Ok(true),
        "choice": choice.as_str(),
        "clients": rows,
        "undo": Value::Null,
        "user_action": user_action,
        "terminals": {
            "why": why,
            "shims": shims,
            "text": format!(
                "Nothing was written: {why}. Claude Code and Codex started in this build's \
                 terminals get cmux's tools through its claude and codex shims{shims_text}, \
                 reading {}{stale_text}",
                settings.display()
            ),
        },
    });
    Outcome { report, failed: false }
}

/// The check `cmux setup status` reports: the switch, and whether each
/// installed harness gives the cmux server outside cmux. With none
/// installed it is `ok`, as `run` is: the switch has nothing to serve.
pub(super) fn status() -> Value {
    let (settings, enabled) = super::super::mcp::outside_chats();
    if let Ok(command) = this_cli()
        && let Writer::Terminals(why) = writer(Path::new(&command), |key| std::env::var_os(key))
    {
        let report = terminals(&Request::default(), &command, &why).report;
        return json!({
            "task": TASK,
            "state": report["state"],
            "scope": "terminals",
            "settings": settings,
            "enabled": enabled == Ok(true),
            "choice": report["choice"],
            "clients": report["clients"],
            "terminals": report["terminals"],
            "fix": Value::Null,
        });
    }
    let choice = AgentsCmuxMcp::from_config_file(&settings);
    let declined = choice == AgentsCmuxMcp::Off;
    let unanswered = choice == AgentsCmuxMcp::Ask;
    let path = std::env::var_os("PATH");
    let clients: Vec<Value> = CLIENTS
        .into_iter()
        .filter_map(|client| {
            let (next, found) = plan(client, false, path.as_deref());
            let state = match next {
                Plan::Absent => return None,
                Plan::Ok => "ok",
                // The person said no: nothing is missing.
                Plan::Add | Plan::Replace | Plan::Person(_) if declined => "off",
                // The person has not answered: waiting on them, not on setup.
                Plan::Add | Plan::Replace | Plan::Person(_) if unanswered => "ask",
                Plan::Add | Plan::Replace => "needs_setup",
                Plan::Person(_) => "needs_user",
                Plan::Failed(_) => "failed",
            };
            Some(json!({"id": client.id(), "state": state, "entry": found.as_ref().map(Entry::json)}))
        })
        .collect();
    let ready = declined
        || ((clients.is_empty() || enabled == Ok(true))
            && clients.iter().all(|client| client["state"] == "ok"));
    let asking = !ready && clients.iter().any(|client| client["state"] == "ask");
    json!({
        "task": TASK,
        "state": if ready { "ok" } else if asking { "needs_user" } else { "needs_setup" },
        "settings": settings,
        "enabled": enabled == Ok(true),
        "choice": choice.as_str(),
        "clients": clients,
        "fix": (!ready).then_some("cmux setup mcp"),
    })
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut request = Request { clients: Vec::new(), dry_run: false, remove: false };
    for arg in args {
        match arg.as_str() {
            "--dry-run" => request.dry_run = true,
            "--remove" => request.remove = true,
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

/// This cmux's own path, links followed (the path [`writer`] judged): the
/// command the harness runs.
fn this_cli() -> Result<String, Refusal> {
    std::env::current_exe()
        .map(|exe| exe.canonicalize().unwrap_or(exe).to_string_lossy().into_owned())
        .map_err(|error| Refusal::Failed(format!("cmux: setup mcp: no path to this cmux: {error}")))
}

/// What setup does for `client`, and the entry that decided it. A harness
/// that is not installed is the person's only when it was named. The entry
/// named `cmux` is a shipped build's only while it names no settings file and
/// its command is no DEV build's; otherwise it is replaced.
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
    if let Some(at) = entries.iter().position(|entry| {
        entry.serves_cmux()
            && entry.runs(path)
            // Another name is the person's own wiring; the `cmux` entry must
            // reach this cmux's settings file.
            && entry.settings_file_exists()
            && (entry.name != SERVER || entry.shipped())
    }) {
        return (Plan::Ok, Some(entries.swap_remove(at)));
    }
    let Some(at) = entries.iter().position(|entry| entry.name == SERVER) else {
        return (Plan::Add, None);
    };
    let taken = entries.swap_remove(at);
    if taken.serves_cmux() {
        let lost = taken.unrestorable();
        if !lost.is_empty() {
            return (Plan::Person(keep(client, &lost, false)), Some(taken));
        }
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
/// command is gone or is a DEV build's, or that names a settings file which
/// is gone) first,
/// and answers the line that undoes it. When the add fails after the remove,
/// the error names the line that puts `old` back.
fn apply(
    client: Client,
    command: &str,
    old: Option<&Entry>,
) -> Result<(String, Vec<String>), String> {
    let remove = client.remove();
    let restore = old.and_then(|old| old.restore(client));
    let hidden = restore.as_ref().map(|restore| restore.hidden.clone()).unwrap_or_default();
    let restore = restore.map(|restore| restore.line);
    if old.is_some() {
        run_cli(client, &remove)?;
    }
    run_cli(client, &client.add(command, &["mcp".into(), "serve".into()], &[])).map_err(
        |error| match &restore {
            Some(restore) => format!("{error}; `{restore}` puts the old entry back"),
            None => error,
        },
    )?;
    let undo = client.line(&remove);
    let undo = match restore {
        Some(restore) => format!("{undo} && {restore}"),
        None => undo,
    };
    Ok((undo, hidden))
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

/// `client`'s `cmux` entry holds what setup could not put back (`lost`:
/// another field, a non-string value, an `env` key such as a token): setup
/// leaves it as it is, never deleting what it cannot restore, and names the
/// exact command for the person to run once they have kept what they need.
fn keep(client: Client, lost: &[String], removing: bool) -> Value {
    let remove = client.line(&client.remove());
    // This cmux's own path, quoted, as `apply` writes it: a bare `cmux` can be
    // another install's.
    let cli = this_cli().map(|cli| quote_arg(&cli)).unwrap_or_else(|_| "cmux".to_owned());
    let command =
        if removing { remove } else { format!("{remove} && {cli} setup mcp {}", client.id()) };
    json!({
        "kind": "keep",
        "text": format!(
            "{}'s cmux entry has settings cmux cannot put back ({}), so cmux left it as it is. \
             To {} it, keep what you need from it, then run `{command}`",
            client.name(),
            lost.join(", "),
            if removing { "remove" } else { "replace" },
        ),
        "command": command,
        "url": Value::Null,
    })
}

/// The person's answer was no (`agents.cmuxMcp` `off`): the setting to
/// change, where the person changes it.
fn declined() -> Value {
    json!({
        "kind": "setting",
        "text": format!(
            "You chose not to add cmux's tools to your coding agents ({} is \"off\"). \
             To add them, choose Add to My Agents in cmux Settings > Agents > cmux Tools in \
             Coding Agents, or run `cmux settings set {} on --confirm` and approve it in cmux; \
             then run `cmux setup mcp` again",
            AgentsCmuxMcp::KEY,
            AgentsCmuxMcp::KEY
        ),
        "command": format!("cmux settings set {} on --confirm", AgentsCmuxMcp::KEY),
        "url": Value::Null,
    })
}

/// The person has not answered whether cmux may add its tools to their coding
/// agents (`agents.cmuxMcp` unset or `ask`): only they answer it, in the
/// onboarding step or Settings > Agents.
fn unanswered() -> Value {
    json!({
        "kind": "setting",
        "text": format!(
            "The person has not chosen whether cmux may add its tools to their coding agents \
             ({} is \"ask\"). Ask them: they answer in cmux's cmux Tools step or in Settings > \
             Agents > cmux Tools in Your Coding Agents (Add to My Agents), or run `cmux settings \
             set {} on --confirm` themselves and approve it in cmux; then run `cmux setup mcp` \
             again",
            AgentsCmuxMcp::KEY,
            AgentsCmuxMcp::KEY
        ),
        "command": Value::Null,
        "url": Value::Null,
    })
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
