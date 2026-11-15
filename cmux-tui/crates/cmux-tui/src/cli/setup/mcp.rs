//! `cmux setup mcp [claude|codex ...]`: which coding agents get cmux's MCP
//! server (`cmux mcp serve`, Computer Use behind it) when cmux starts them,
//! and the lines a person can run to use it elsewhere. It writes nothing.
//!
//! cmux gives its server to the agents it starts, and only through their
//! launch: a Claude Code or Codex typed into a cmux terminal gets it from the
//! `claude` and `codex` shims (agent_mcp_choice.rs, agent_computer_use.rs),
//! and the app's agent chats and the Chief get it from acpmux
//! (`acpmux::agent_tools`), all with the one server definition
//! (`acpmux::agent_tools::cmux_server`), named `cmux`. Each follows the
//! person's answer to "should agents you start in cmux get cmux's tools?"
//! (`agents.cmuxMcp`: the onboarding step, Settings > Agents): `on` gives it,
//! `off` and unanswered (`ask`) do not. cmux never writes an agent's own
//! config (`~/.claude.json`, `$CODEX_HOME/config.toml`): a person who wants
//! cmux's server in agents started elsewhere runs the `manual` lines this
//! report names themselves, and removes them the same way.
//!
//! The only cmux commands that write an agent's own config are two other
//! features the person runs themselves, each with its own server name:
//! `cmux acp desktop link` (an `acpmux-mcp` guest entry named `cmux` for
//! Claude desktop, Claude Code and Codex; `acpmux desktop_link.rs`) and
//! `cmux acp bridge connect` (`cmux-bridge`; `acpmux cli/bridge.rs`). Neither
//! runs from onboarding, Settings' cmux Tools row or this command.
//!
//! An installed agent is `terminals` once the person said yes and the server
//! serves these agents (`mcp.enabled` not false), else `planned`; one not
//! installed is `not_applicable` (named and missing: `needs_user`, install
//! it). The result is `needs_user` while the person has not answered, or
//! said yes with `mcp.enabled` false (the server would refuse cmux's tools).

use std::path::Path;

use serde_json::{Value, json};

use super::super::agents_doctor::on_path;
use super::super::fix_command::quote_arg;
use super::{Outcome, Refusal};
use cmux_json::JsonSet as _;
use cmux_tui_core::user_settings::AgentsCmuxMcp;

const TASK: &str = "mcp";

/// The name the cmux server has in every agent cmux starts.
const SERVER: &str = crate::agent_computer_use::SERVER;

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

    /// The line a person runs to give this agent cmux's server everywhere,
    /// in its own config, with its own CLI. cmux never runs it.
    fn manual(self, cli: &str) -> String {
        let add = match self {
            Self::Claude => "claude mcp add --scope user",
            Self::Codex => "codex mcp add",
        };
        format!("{add} {SERVER} -- {} mcp serve", quote_arg(cli))
    }
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let cli = this_cli()?;
    let (settings, enabled) = super::super::mcp::outside_chats();
    let choice = AgentsCmuxMcp::from_config_file(&settings);
    let serves = choice == AgentsCmuxMcp::On && enabled == Ok(true);
    let path = std::env::var_os("PATH");
    let clients = if request.clients.is_empty() { CLIENTS.to_vec() } else { request.clients };
    let mut installed = false;
    let mut user_action = Value::Null;
    let rows: Vec<Value> = clients
        .iter()
        .map(|&client| {
            let here = on_path(path.as_deref(), client.id()).is_some();
            installed |= here;
            let named = !request.named.is_empty() && request.named.contains(&client);
            let mut row = json!({
                "id": client.id(),
                "name": client.name(),
                "installed": here,
                "manual": client.manual(&cli),
                "user_action": Value::Null,
                "error": Value::Null,
            });
            let state = match () {
                _ if here && serves => "terminals",
                _ if here => "planned",
                _ if named => {
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
                    if user_action.is_null() {
                        user_action = action.clone();
                    }
                    row.set("user_action", action);
                    "needs_user"
                }
                _ => "not_applicable",
            };
            row.set("state", json!(state));
            row
        })
        .collect();
    // Only the person answers the question; a yes with the switch off needs
    // the switch (the server would refuse cmux's tools); a no needs nothing.
    if user_action.is_null() && installed {
        user_action = match &enabled {
            _ if choice == AgentsCmuxMcp::Ask => unanswered(),
            _ if choice == AgentsCmuxMcp::Off => Value::Null,
            Ok(true) => Value::Null,
            Ok(false) => switch(&settings, None),
            Err(error) => switch(&settings, Some(error.as_str())),
        };
    }
    let manual: Vec<String> = clients.iter().map(|client| client.manual(&cli)).collect();
    let text = match () {
        _ if serves => format!(
            "Claude Code and Codex you start in cmux (its terminals, agent chats and the Chief) \
             get cmux's tools from cmux's server, named {SERVER}, reading {}. cmux changes \
             no agent's own settings",
            settings.display()
        ),
        _ => format!(
            "Agents you start in cmux do not get cmux's tools until the person turns on {} \
             (Settings > Agents). cmux changes no agent's own settings",
            AgentsCmuxMcp::KEY
        ),
    };
    let report = json!({
        "schema_version": 1,
        "task": TASK,
        "state": if user_action.is_null() { "ok" } else { "needs_user" },
        "scope": "terminals",
        "dry_run": request.dry_run,
        "server": {"name": SERVER, "command": cli, "args": ["mcp", "serve"]},
        "settings": settings,
        "enabled": enabled == Ok(true),
        "choice": choice.as_str(),
        "clients": rows,
        "undo": Value::Null,
        "user_action": user_action,
        "terminals": {"text": text},
        "manual": {
            "text": format!(
                "To use cmux's tools in agents started outside cmux, the person can run these \
                 lines themselves; cmux never runs them. Each agent's own `mcp remove {SERVER}` \
                 takes the entry out again"
            ),
            "commands": manual,
        },
    });
    Ok(Outcome { report, failed: false })
}

/// The check `cmux setup status` reports: the same as [`run`], read only.
pub(super) fn status() -> Value {
    let report = match run(&[]) {
        Ok(outcome) => outcome.report,
        Err(Refusal::Usage(error) | Refusal::Failed(error)) => {
            return json!({"task": TASK, "state": "failed", "error": error, "fix": Value::Null});
        }
    };
    let needs_user = report["state"] == "needs_user";
    json!({
        "task": TASK,
        "state": report["state"],
        "scope": "terminals",
        "settings": report["settings"],
        "enabled": report["enabled"],
        "choice": report["choice"],
        "clients": report["clients"].as_array().map(|clients| {
            clients
                .iter()
                .filter(|client| client["installed"] == true)
                .map(|client| json!({"id": client["id"], "state": client["state"]}))
                .collect::<Vec<_>>()
        }),
        "terminals": report["terminals"],
        "manual": report["manual"],
        "fix": needs_user.then_some("cmux setup mcp"),
    })
}

#[derive(Default)]
struct Request {
    /// Every client to report: the named ones, else all.
    clients: Vec<Client>,
    /// The clients named on the command line.
    named: Vec<Client>,
    dry_run: bool,
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut request = Request::default();
    for arg in args {
        match arg.as_str() {
            // Accepted for `cmux setup local --dry-run`: nothing is written either way.
            "--dry-run" => request.dry_run = true,
            flag if flag.starts_with('-') => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup mcp: unknown option {flag:?}; cmux never changes an agent's own \
                     settings (the report's `manual` lines are for the person to run)"
                )));
            }
            id => {
                let client = Client::parse(id).ok_or_else(|| {
                    Refusal::Usage(format!(
                        "cmux: setup mcp: no client {id:?}; give claude or codex"
                    ))
                })?;
                if !request.named.contains(&client) {
                    request.named.push(client);
                }
            }
        }
    }
    request.clients = request.named.clone();
    Ok(request)
}

/// This cmux's own path, links followed: the command the manual lines run.
fn this_cli() -> Result<String, Refusal> {
    std::env::current_exe()
        .map(|exe| exe.canonicalize().unwrap_or(exe).to_string_lossy().into_owned())
        .map_err(|error| Refusal::Failed(format!("cmux: setup mcp: no path to this cmux: {error}")))
}

/// The person has not answered whether agents they start in cmux get cmux's
/// tools (`agents.cmuxMcp` unset or `ask`): only they answer it, in the
/// onboarding step or Settings > Agents.
fn unanswered() -> Value {
    json!({
        "kind": "setting",
        "text": format!(
            "The person has not chosen whether agents they start in cmux get cmux's tools ({} \
             is \"ask\"). Ask them: they answer in cmux's cmux Tools step or in Settings > \
             Agents, or run `cmux settings set {} on --confirm` themselves and approve it in cmux",
            AgentsCmuxMcp::KEY,
            AgentsCmuxMcp::KEY
        ),
        "command": Value::Null,
        "url": Value::Null,
    })
}

/// The person's switch for cmux's MCP tools, and why the settings file could
/// not be read when it could not.
fn switch(settings: &Path, unreadable: Option<&str>) -> Value {
    let why =
        unreadable.map(|error| format!(" (it cannot be read now: {error})")).unwrap_or_default();
    json!({
        "kind": "setting",
        "text": format!(
            "Turn on the cmux MCP server: \"mcp\": {{\"enabled\": false}} in {}{why} keeps \
             cmux's tools from the agents cmux starts; set it to true, or remove it",
            settings.display()
        ),
        "command": Value::Null,
        "url": Value::Null,
    })
}
