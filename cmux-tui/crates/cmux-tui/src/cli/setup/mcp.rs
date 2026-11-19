//! `cmux setup mcp [claude|codex ...]`: which coding agents get cmux's MCP
//! server (`cmux mcp serve`, Computer Use behind it) when cmux starts them,
//! and the lines a person can run to use it elsewhere. It writes nothing,
//! but for `--remove CLIENT` (below).
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
//! A `cmux` entry in the person's own config (`~/.claude.json`,
//! `$CODEX_HOME/config.toml`) that runs `cmux mcp serve` (`cmux_serve.rs`),
//! one an older cmux wrote or one the person added: each client row names one
//! it finds (`leftover`, with the exact line that removes it), but for the
//! very `manual` line this build names, which the person added on purpose.
//! Inside cmux the agent's own `cmux` replaces or overrides it; outside cmux
//! it is what starts. Nothing takes it out on its own: `cmux setup mcp
//! --remove CLIENT` does, when the person asks (Settings' Remove button), and
//! names the line that puts it back; `--dry-run` only names the line. An
//! entry with anything cmux could not put back (another field, an `env` key
//! outside [`RESTORABLE_ENV`]) is kept and named, its values never printed.
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

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::agents_doctor::{on_path, read_json, read_text};
use super::super::fix_command::quote_arg;
use super::{Outcome, Refusal};
use cmux_json::JsonSet as _;
use cmux_tui_core::user_settings::AgentsCmuxMcp;

const TASK: &str = "mcp";

/// The name the cmux server has in every agent cmux starts.
const SERVER: &str = crate::agent_computer_use::SERVER;

/// The `env` keys of a `cmux` entry whose values setup may print and put
/// back: cmux's own routing and settings-file keys, none of them a secret.
/// Any other key (a token, a proxy, `CMUX_SOCKET_PASSWORD`) is never printed,
/// and an entry with one is never removed (cmux could not put it back).
const RESTORABLE_ENV: [&str; 4] =
    ["CMUX_NEXT_CONFIG_FILE", "CMUX_TAG", "CMUX_BUNDLE_ID", "CMUX_TUI_SOCKET"];

/// The longest `claude mcp remove` or `codex mcp remove` may take.
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

    /// The person's own config file the agent's CLI writes (user scope).
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

    /// The `mcp remove` arguments for the entry named `cmux`.
    fn remove_args(self) -> Vec<String> {
        let scope: &[&str] = match self {
            Self::Claude => &["--scope", "user"],
            Self::Codex => &[],
        };
        ["mcp", "remove"].iter().chain(scope).chain(&[SERVER]).map(|a| (*a).to_owned()).collect()
    }

    /// `args` as the shell line a person runs.
    fn line(self, args: &[String]) -> String {
        std::iter::once(self.id().to_owned())
            .chain(args.iter().map(|arg| quote_arg(arg)))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// The `cmux` entry in the person's own config, when it runs cmux's server
    /// and is not exactly this build's [`Self::manual`] line (`cli`), which the
    /// person added on purpose. `Err` for a config it cannot read.
    fn leftover(self, cli: &str) -> Result<Option<Leftover>, String> {
        let Some(file) = self.config() else { return Ok(None) };
        let shown = file.display();
        let entry: Option<Value> = match self {
            Self::Claude => read_json(&file)
                .map_err(|error| format!("{shown}: {error}"))?
                .and_then(|config| config.pointer(&format!("/mcpServers/{SERVER}")).cloned()),
            Self::Codex => {
                let Some(text) = read_text(&file).map_err(|error| format!("{shown}: {error}"))?
                else {
                    return Ok(None);
                };
                let config: toml::Table =
                    text.parse().map_err(|error| format!("{shown}: {error}"))?;
                config
                    .get("mcp_servers")
                    .and_then(|servers| servers.get(SERVER))
                    .map(|entry| serde_json::to_value(entry).unwrap_or(Value::Null))
            }
        };
        let Some(entry) = entry.as_ref().and_then(Value::as_object) else { return Ok(None) };
        let Some(command) = entry.get("command").and_then(Value::as_str) else { return Ok(None) };
        let args: Vec<String> = entry
            .get("args")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|a| a.as_str().map(str::to_owned))
            .collect();
        let Some(runs) = super::cmux_serve::cmux_serve(command, &args) else { return Ok(None) };
        let runs = match runs {
            super::cmux_serve::CmuxServe::Path(path) => path.to_owned(),
            super::cmux_serve::CmuxServe::Published => "a published cmux package".to_owned(),
        };
        let all_env = entry.get("env").and_then(Value::as_object);
        // Only cmux's own keys are kept, values and all: another key's value
        // may be a secret, so it is named, never held or printed.
        let env: Vec<(String, String)> = all_env
            .into_iter()
            .flatten()
            .filter(|(k, _)| RESTORABLE_ENV.contains(&k.as_str()))
            .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned())))
            .collect();
        let kept = ["type", "command", "args", "env"];
        let mut unrestorable: Vec<String> =
            entry.keys().filter(|k| !kept.contains(&k.as_str())).cloned().collect();
        unrestorable.extend(
            all_env
                .into_iter()
                .flatten()
                .filter(|(k, v)| !RESTORABLE_ENV.contains(&k.as_str()) || !v.is_string())
                .map(|(k, _)| format!("env {k}")),
        );
        // A secret in its command or args (a URL with credentials, `--token=…`, `key=<long random
        // value>`): shown redacted, and the entry is kept, as for a token in `env` (cmux could
        // not put the secret back).
        let line: Vec<String> =
            std::iter::once(command.to_owned()).chain(args.iter().cloned()).collect();
        if redact_secrets(&line) != line {
            unrestorable.push("command or args (a secret)".to_owned());
        }
        let stdio = entry.get("type").is_none_or(|t| t == "stdio");
        let manual = stdio
            && unrestorable.is_empty()
            && env.is_empty()
            && args == ["mcp", "serve"]
            && same_file(command, cli);
        if manual {
            return Ok(None);
        }
        Ok(Some(Leftover {
            config: file,
            command: command.to_owned(),
            args,
            env,
            unrestorable,
            runs,
        }))
    }

    /// The line that adds `leftover` back, as it was: only for an entry with
    /// nothing [`Leftover::unrestorable`], so every `env` value it prints is
    /// one of [`RESTORABLE_ENV`].
    fn add_back(self, leftover: &Leftover) -> String {
        let mut args = vec!["mcp".to_owned(), "add".to_owned()];
        for (key, value) in &leftover.env {
            args.push("--env".to_owned());
            args.push(format!("{key}={value}"));
        }
        if self == Self::Claude {
            args.extend(["--scope".to_owned(), "user".to_owned()]);
        }
        // Never a secret: an entry with one is kept, so this runs only for one without; redacted
        // all the same, so no path can print one.
        args.extend([SERVER.to_owned(), "--".to_owned()]);
        let mut line = vec![leftover.command.clone()];
        line.extend(leftover.args.iter().cloned());
        args.extend(redact_secrets(&line));
        self.line(&args)
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

/// A `cmux` entry in the person's own config that runs cmux's server.
struct Leftover {
    config: PathBuf,
    command: String,
    args: Vec<String>,
    /// Its [`RESTORABLE_ENV`] keys and values.
    env: Vec<(String, String)>,
    /// What cmux could not put back if it removed it: other fields, and
    /// `env KEY` for each other `env` key (named, never its value).
    unrestorable: Vec<String>,
    /// The cmux CLI or launcher it runs, or that it fetches a published one.
    runs: String,
}

impl Leftover {
    fn json(&self, client: Client) -> Value {
        json!({
            "config": self.config,
            "command": redact_one(&self.command),
            "args": redact_secrets(&self.args),
            "runs": redact_one(&self.runs),
            "remove": client.line(&client.remove_args()),
        })
    }
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let cli = this_cli()?;
    if let Some(client) = request.remove {
        return Ok(remove(client, &cli, request.dry_run));
    }
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
                "leftover": Value::Null,
                "user_action": Value::Null,
                "error": Value::Null,
            });
            match client.leftover(&cli) {
                Ok(Some(leftover)) => {
                    row.set("leftover", leftover.json(client));
                }
                Ok(None) => {}
                Err(error) => {
                    row.set("error", json!(error));
                }
            }
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
    let needs_user = report.get("state").and_then(Value::as_str) == Some("needs_user");
    json!({
        "task": TASK,
        "state": report.get("state"),
        "scope": "terminals",
        "settings": report.get("settings"),
        "enabled": report.get("enabled"),
        "choice": report.get("choice"),
        "clients": report.get("clients").and_then(Value::as_array).map(|clients| {
            clients
                .iter()
                .filter(|client| client["installed"] == true)
                .map(|client| json!({"id": client["id"], "state": client["state"]}))
                .collect::<Vec<_>>()
        }),
        "terminals": report.get("terminals"),
        "manual": report.get("manual"),
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
    /// `--remove CLIENT`: take that agent's leftover `cmux` entry out.
    remove: Option<Client>,
    /// `--confirm`: the person asked for `--remove` (Settings' Remove button passes it).
    confirm: bool,
}

/// `--remove CLIENT`: takes out the `cmux` entry in `client`'s own config
/// that runs `cmux mcp serve` ([`Client::leftover`]), through its own `mcp
/// remove`, and names the line that puts it back. An entry with anything cmux
/// could not put back is left, and the line to run is named. `dry_run` only
/// names the line (`plan`).
fn remove(client: Client, cli: &str, dry_run: bool) -> Outcome {
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "action": "remove",
        "client": client.id(),
        "state": "ok",
        "dry_run": dry_run,
        "plan": Value::Null,
        "undo": Value::Null,
        "user_action": Value::Null,
        "error": Value::Null,
    });
    let line = client.line(&client.remove_args());
    match client.leftover(cli) {
        Err(error) => {
            report.set("state", json!("failed"));
            report.set("error", json!(error));
            return Outcome { report, failed: true };
        }
        Ok(None) => {}
        Ok(Some(leftover)) if !leftover.unrestorable.is_empty() => {
            report.set("state", json!("needs_user"));
            report.set(
                "user_action",
                json!({
                    "kind": "keep",
                    "text": format!(
                        "{}'s cmux entry has settings cmux would not put back ({}), so it is left \
                         as it is. Keep what you need from it, then run `{line}`",
                        client.name(),
                        leftover.unrestorable.join(", ")
                    ),
                    "command": line,
                    "url": Value::Null,
                }),
            );
        }
        Ok(Some(_)) if dry_run => {
            report.set("plan", json!(line));
        }
        Ok(Some(leftover)) => match run_cli(client, &client.remove_args()) {
            Ok(()) => {
                report.set("state", json!("changed"));
                report.set("undo", json!(client.add_back(&leftover)));
            }
            Err(error) => {
                report.set("state", json!("failed"));
                report.set("error", json!(error));
                return Outcome { report, failed: true };
            }
        },
    }
    Outcome { report, failed: false }
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

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut request = Request::default();
    let mut removing = false;
    for arg in args {
        match arg.as_str() {
            "--remove" => removing = true,
            "--confirm" => request.confirm = true,
            // Nothing is written by a report either way; with --remove, only the plan.
            "--dry-run" => request.dry_run = true,
            flag if flag.starts_with('-') => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup mcp: unknown option {flag:?}; cmux adds nothing to an agent's own \
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
    if removing {
        // A person's act only: at a terminal, or Settings' Remove button (`--confirm`). An agent
        // (the Chief, a script) never runs it on its own; `--dry-run` only plans. This is a
        // consent speed bump, not a security boundary: anything that runs as the person can pass
        // `--confirm`, or run the agent's own `mcp remove` itself.
        use std::io::IsTerminal as _;
        let person = request.confirm || std::io::stdin().is_terminal();
        if !person && !request.dry_run {
            return Err(Refusal::Usage(
                "cmux: setup mcp: --remove changes an agent's own settings, so a person runs it: \
                 in a terminal, or with Settings > Agents' Remove button. Show the person the \
                 report's leftover instead"
                    .into(),
            ));
        }
        let [client] = request.named.as_slice() else {
            return Err(Refusal::Usage(
                "cmux: setup mcp: --remove takes one agent, claude or codex: it takes out the \
                 cmux entry in that agent's own settings that runs `cmux mcp serve`"
                    .into(),
            ));
        };
        request.remove = Some(*client);
    }
    request.clients = request.named.clone();
    Ok(request)
}

/// [`redact_secrets`] of one value.
fn redact_one(value: &str) -> String {
    redact_secrets(&[value.to_owned()]).pop().unwrap_or_default()
}

/// `args` (a command line) with each secret-shaped value replaced by `<redacted>`: a URL's
/// credentials ([`redact_url_credentials`]); the value of a flag whose name says secret
/// (`--token=V`, `--api-key V`, `--password`, `--secret`, `--auth…`, `--credential…`); and a
/// `NAME=VALUE` whose value is a long random-looking string (20 or more characters of letters
/// and digits, both present, and nothing but `-_.+/=`), as an `env`-style key=token; an HTTP
/// header with credentials (`Authorization: Bearer …`, `X-Api-Key: …`, `Cookie: …`, or any
/// `Name: Bearer|Basic|Token …`, alone or after `--header=`); and a bare positional token (24 or
/// more characters of letters and digits, both present, and nothing but `-_+`, so no path,
/// package or version); a bare JWT (three base64url segments); a URL query parameter that
/// names a secret (`?token=`, `?api_key=`, `?access_token=`, `&sig=`, ...); and a header split
/// across arguments (`Authorization:` then `Bearer x`, or `Authorization: Bearer` then `x`, or
/// `Bearer` then `x`): the part after the name is redacted.
fn redact_secrets(args: &[String]) -> Vec<String> {
    const SECRET_WORDS: [&str; 7] =
        ["token", "key", "secret", "password", "passwd", "auth", "credential"];
    let names_secret = |flag: &str| {
        let name = flag.trim_start_matches('-').to_ascii_lowercase();
        flag.starts_with('-') && SECRET_WORDS.iter().any(|word| name.contains(word))
    };
    let random = |value: &str| {
        value.len() >= 20
            && value.chars().all(|c| c.is_ascii_alphanumeric() || "-_.+/=".contains(c))
            && value.chars().any(|c| c.is_ascii_digit())
            && value.chars().any(|c| c.is_ascii_alphabetic())
    };
    // `Name: value` with credentials: the name and `<redacted>`.
    let header = |text: &str| -> Option<String> {
        let (name, value) = text.split_once(':')?;
        let name = name.trim();
        if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return None;
        }
        let lower = name.to_ascii_lowercase();
        let scheme = value.split_whitespace().next().unwrap_or_default().to_ascii_lowercase();
        let secret = SECRET_WORDS.iter().any(|word| lower.contains(word))
            || matches!(lower.as_str(), "cookie" | "proxy-authorization")
            || matches!(scheme.as_str(), "bearer" | "basic" | "token" | "digest");
        (secret && !value.trim().is_empty()).then(|| format!("{name}: <redacted>"))
    };
    let bare = |value: &str| {
        value.len() >= 24
            && value.chars().all(|c| c.is_ascii_alphanumeric() || "-_+".contains(c))
            && value.chars().any(|c| c.is_ascii_digit())
            && value.chars().any(|c| c.is_ascii_alphabetic())
    };
    let jwt = |value: &str| {
        let parts: Vec<&str> = value.split('.').collect();
        parts.len() == 3
            && parts.iter().all(|part| {
                part.len() >= 8
                    && part.chars().all(|c| c.is_ascii_alphanumeric() || "-_".contains(c))
            })
    };
    const SCHEMES: [&str; 4] = ["bearer", "basic", "token", "digest"];
    // An argument that leaves a header's credential to the next one: `Name:` (a secret-shaped
    // header name, no value), `Name: Scheme` (no credential), or a bare `Scheme`.
    let header_continues = |text: &str| {
        let trimmed = text.trim();
        if SCHEMES.contains(&trimmed.to_ascii_lowercase().as_str()) {
            return true;
        }
        let Some((name, value)) = trimmed.split_once(':') else { return false };
        let lower = name.trim().to_ascii_lowercase();
        let value = value.trim().to_ascii_lowercase();
        let secret_name = SECRET_WORDS.iter().any(|word| lower.contains(word))
            || matches!(lower.as_str(), "cookie" | "proxy-authorization");
        !lower.is_empty()
            && lower.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            && ((value.is_empty() && secret_name) || SCHEMES.contains(&value.as_str()))
    };
    let mut out = Vec::with_capacity(args.len());
    let mut next_is_secret = false;
    for arg in args {
        if std::mem::take(&mut next_is_secret) {
            out.push("<redacted>".to_owned());
            continue;
        }
        let arg = redact_query_secrets(&redact_url_credentials(arg));
        if header_continues(&arg) {
            next_is_secret = true;
            out.push(if arg.contains(':') {
                format!("{}: <redacted>", arg.split_once(':').map_or("", |(n, _)| n.trim()))
            } else {
                arg
            });
            continue;
        }
        if let Some(shown) = header(&arg) {
            out.push(shown);
            continue;
        }
        if jwt(&arg) {
            out.push("<redacted>".to_owned());
            continue;
        }
        if let Some((flag, value)) = arg.split_once('=')
            && flag.starts_with('-')
        {
            // `--header=Authorization:` or `--header=Authorization: Bearer`: the credential is next.
            if header_continues(value) {
                next_is_secret = true;
                let name = value.split_once(':').map_or(value.trim(), |(n, _)| n.trim());
                out.push(if value.contains(':') {
                    format!("{flag}={name}: <redacted>")
                } else {
                    arg.clone()
                });
                continue;
            }
            if let Some(shown) = header(value) {
                out.push(format!("{flag}={shown}"));
                continue;
            }
        }
        if !arg.starts_with('-') && bare(&arg) {
            out.push("<redacted>".to_owned());
            continue;
        }
        match arg.split_once('=') {
            Some((flag, _)) if names_secret(flag) => out.push(format!("{flag}=<redacted>")),
            Some((name, value))
                if !name.is_empty()
                    && !name.contains('/')
                    && !name.contains(':')
                    && random(value) =>
            {
                out.push(format!("{name}=<redacted>"));
            }
            None if names_secret(&arg) => {
                next_is_secret = true;
                out.push(arg);
            }
            _ => out.push(arg),
        }
    }
    out
}

/// `value` with each URL query parameter that names a secret (`auth`, `sig`, `signature`,
/// `code`, or any name with `token`, `secret`, `password` or `key` in it: `access_token`,
/// `api_key`, `apikey`) given `<redacted>` as its value.
fn redact_query_secrets(value: &str) -> String {
    let Some(start) = value.find('?') else { return value.to_owned() };
    let (head, query) = value.split_at(start + 1);
    let secret_name = |name: &str| {
        let name = name.to_ascii_lowercase();
        matches!(name.as_str(), "auth" | "sig" | "signature" | "code")
            || ["token", "secret", "password", "key"].iter().any(|word| name.contains(word))
    };
    let (query, fragment) = match query.find('#') {
        Some(at) => query.split_at(at),
        None => (query, ""),
    };
    let params: Vec<String> = query
        .split('&')
        .map(|pair| match pair.split_once('=') {
            Some((name, value)) if secret_name(name) && !value.is_empty() => {
                format!("{name}=<redacted>")
            }
            _ => pair.to_owned(),
        })
        .collect();
    format!("{head}{}{fragment}", params.join("&"))
}

/// `value` with the credentials of each URL in it (`scheme://user:pass@host`) replaced by
/// `<redacted>`, as in `--registry=https://<redacted>@registry.example/`.
fn redact_url_credentials(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find("://") {
        let (head, tail) = rest.split_at(at + 3);
        out.push_str(head);
        let authority_end = tail.find(['/', '?', '#', ' ']).unwrap_or(tail.len());
        let (authority, after) = tail.split_at_checked(authority_end).unwrap_or((tail, ""));
        match authority.rfind('@') {
            Some(cut) => {
                out.push_str("<redacted>");
                rest = tail.get(cut..).unwrap_or_default();
            }
            None => rest = tail,
        }
        if rest.as_ptr() == tail.as_ptr() {
            // No credentials: copy the authority and go on after it.
            out.push_str(authority);
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

/// Whether `command` is the file `cli` (links followed): an entry that runs
/// this very cmux.
fn same_file(command: &str, cli: &str) -> bool {
    let canonical = |path: &str| std::fs::canonicalize(path).ok();
    command == cli || canonical(command).is_some_and(|c| Some(c) == canonical(cli))
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

#[cfg(test)]
mod tests {
    use super::redact_url_credentials as redact;

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| (*a).to_owned()).collect()
    }

    /// Secret-shaped values are redacted; a plain command line stays as it is.
    #[test]
    fn secret_shaped_args_are_redacted() {
        let r = |args: &[&str]| super::redact_secrets(&strings(args));
        assert_eq!(r(&["--token=abc", "x"]), ["--token=<redacted>", "x"]);
        assert_eq!(r(&["--api-key", "abc", "mcp"]), ["--api-key", "<redacted>", "mcp"]);
        assert_eq!(r(&["--password=hunter2"]), ["--password=<redacted>"]);
        assert_eq!(
            r(&["KEY=sk9f8a7d6s5f4g3h2j1k0l", "https://u:p@h/x"]),
            ["KEY=<redacted>", "https://<redacted>@h/x"]
        );
        assert_eq!(
            r(&["--header", "Authorization: Bearer abc.def", "-H", "X-Api-Key: k1"]),
            ["--header", "Authorization: <redacted>", "-H", "X-Api-Key: <redacted>"]
        );
        assert_eq!(
            r(&["--header=Authorization: Basic dXNlcjpw"]),
            ["--header=Authorization: <redacted>"]
        );
        assert_eq!(r(&["X-Custom: Token t0k3n"]), ["X-Custom: <redacted>"]);
        assert_eq!(r(&["mcp", "ghp1a2b3c4d5e6f7g8h9i0j1k2l3m4n"]), ["mcp", "<redacted>"]);
        assert_eq!(
            r(&[
                "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            ]),
            ["<redacted>"]
        );
        assert_eq!(
            r(&["--url=https://h.example/mcp?access_token=abc&v=2", "https://h/x?api_key=k#top"]),
            [
                "--url=https://h.example/mcp?access_token=<redacted>&v=2",
                "https://h/x?api_key=<redacted>#top"
            ]
        );
        assert_eq!(
            r(&["-H", "Authorization:", "Bearer xyz", "mcp"]),
            ["-H", "Authorization: <redacted>", "<redacted>", "mcp"]
        );
        assert_eq!(
            r(&["-H", "Authorization: Bearer", "xyz"]),
            ["-H", "Authorization: <redacted>", "<redacted>"]
        );
        assert_eq!(r(&["Bearer", "xyz", "mcp"]), ["Bearer", "<redacted>", "mcp"]);
        assert_eq!(
            r(&["--header=Authorization: Bearer", "xyz", "mcp"]),
            ["--header=Authorization: <redacted>", "<redacted>", "mcp"]
        );
        assert_eq!(
            r(&["--header=Authorization:", "Bearer xyz"]),
            ["--header=Authorization: <redacted>", "<redacted>"]
        );
        for plain in [
            &["npx", "-y", "cmux", "mcp", "serve"][..],
            &["/Applications/cmux.app/Contents/Resources/bin/cmux", "mcp", "serve", "--all-tools"],
            &["--registry=https://npm.example/", "--keep-alive", "LANG=en_US.UTF-8"],
            &["MODE=aaaaaaaaaaaaaaaaaaaaaaaaa"],
            &["lib/node_modules/cmux-tui-linux-x64/bin/cmux-tui", "mcp", "serve"],
            &[
                "cmux@1.2.3-beta.4",
                "Content-Type: application/json",
                "abcdefghijklmnopqrstuvwxyzab",
            ],
            &["https://npm.example/cmux?v=2&tag=next", "node_modules.cache.dir", "a.b.c"],
        ] {
            assert_eq!(r(plain), strings(plain), "{plain:?}");
        }
    }

    #[test]
    fn url_credentials_are_redacted_and_nothing_else_changes() {
        assert_eq!(
            redact("--registry=https://me:tok@npm.example/x"),
            "--registry=https://<redacted>@npm.example/x"
        );
        assert_eq!(redact("https://tok@h"), "https://<redacted>@h");
        assert_eq!(
            redact("a http://u:p@h/ b https://v@w"),
            "a http://<redacted>@h/ b https://<redacted>@w"
        );
        for plain in ["https://npm.example/x", "mcp", "user@host", "https://h/a@b", ""] {
            assert_eq!(redact(plain), plain);
        }
    }
}
