//! `cmux chat [--device ID|NAME|cloud | --vm MACHINE|new] [flags] [PROMPT]`: start an agent chat,
//! here by default, or on another device, a Cloud machine or in cmux Cloud (Leo, 2026-11-07: "the
//! goal is like... cmux chat is normal, and cmux chat with the flag/arguments can separate if you
//! want it on a different device/vm/cloud/whatevret").
//!
//! - No target: the chat starts right here, as `cmux agents chat new` starts it (a chat tab in the
//!   app, in this machine's acpmux).
//! - `--vm MACHINE`: a chat on that Cloud machine (`machine:ID`, a name, made when no machine has
//!   it, or `new`). It is the run `cmux cloud start-chat` does (cloud_start_chat.rs); that verb
//!   stays as its old spelling.
//! - `--device SELECTOR`: `cloud` (a new Cloud machine), or a device of the daemon's machine
//!   catalog by its machine id (a name that names exactly one device is read as its id). Every
//!   device goes through the SDK's [`cmux::resolve_chat_target`] first, with the catalog read now
//!   and the app's cloud sign-in read now, so a device the person may not use, one that does not
//!   run agent chats, or one not running is refused before anything starts. Nothing here lists
//!   devices of its own.
//!
//! The selector `cloud` and a device id stay apart: `cloud` is never looked up in the catalog, and
//! a device called "cloud" is reached by its id.

use std::time::Duration;

use cmux::{CallKind, ChatTarget, ChatTargetRefusal};
use serde_json::{Value, json};

use super::cloud_start_chat::{self, Machine};
use super::{GlobalArgs, OutputMode, UsageError};

/// This command's flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &[
    "--device",
    "--vm",
    "--prompt",
    "-p",
    "--agent",
    "--harness",
    "--model",
    "--cwd",
    "--name",
    "--timeout",
];

/// The `chat` verbs other modules own (chief/chat_scope.rs and the app's `chat …` actions).
const OTHER_VERBS: &[&str] = &["send", "read", "wait", "list", "create", "replies", "colors"];

/// How long the catalog read may take.
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) const USAGE: &str = "\
usage: cmux chat [--device ID|NAME|cloud | --vm MACHINE|machine:ID|new]
                 [--agent AGENT] [--model MODEL] [--cwd DIR] [--name NAME]
                 [--wait] [--timeout SECONDS] [--json] [[--prompt] TEXT]

Starts an agent chat. With no target it starts right here, as a tab in the
cmux app. A target sends it elsewhere:

  --device ID|NAME   A connected device by its machine id (`cmux machine list`);
                     a name that names exactly one device works too.
                     The device must be yours, running, and run agent chats.
  --device cloud     cmux Cloud: a new Cloud machine.
  --vm MACHINE       A Cloud machine: machine:ID, or a name (made when no
                     machine has it). --vm new makes a new one.

  --agent AGENT      claude (default), codex, ...
  --model MODEL      The agent's model (a chat here)
  --cwd DIR          The chat's folder (absolute)
  --name NAME        The chat's name (a chat here)
  --prompt TEXT      A first prompt (`-` reads it from stdin); a Cloud chat needs one
  --wait             Wait for a Cloud chat's turn to end and print the reply
  --timeout SECONDS  How long --wait waits (default 900)

EXAMPLES
  cmux chat 'Summarize README.md'
  cmux chat --device machine_3f2a 'Run the tests'
  cmux chat --vm new --prompt 'Summarize README.md' --wait --json
  cmux chat --vm dev --cwd /home/cmux/work --prompt 'Run the tests' --json

Messages to a chat: cmux chat send|read|wait|list (`cmux chat send --help`).
Refusals: chat_target.unknown_device, chat_target.ambiguous_device,
chat_target.not_permitted, chat_target.unavailable, chat_target.signed_out,
chat_target.no_route. Exit codes: 0 ok, 1 refused, 2 bad arguments.
";

/// Where the chat goes, as typed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Target {
    Here,
    /// `--device`: `cloud` or a device id or name, checked against the catalog when it runs.
    Device(String),
    /// `--vm`: a Cloud machine.
    Vm(Machine),
}

/// A parsed `cmux chat …` start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Start {
    pub target: Target,
    pub agent: Option<String>,
    pub model: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub prompt: Option<String>,
    pub wait: bool,
    pub timeout: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run(Start),
}

/// Where a resolved target runs the chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// This machine's acpmux and app (`agents chat new`).
    Here,
    /// A Cloud machine (`cloud start-chat`'s run).
    Cloud(Machine),
}

/// `Some(exit code)` when `args` is a chat start: `cmux chat` with no words, `cmux chat new …`,
/// or `cmux chat` followed by a flag. Every other `chat` verb runs where it did.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let (scope, rest) = command.split_first()?;
    if scope != "chat" {
        return None;
    }
    let rest = match rest.split_first() {
        Some((first, after)) if first == "new" => after,
        Some((first, _)) if OTHER_VERBS.contains(&first.as_str()) || !first.starts_with('-') => {
            return None;
        }
        _ => rest,
    };
    let prefix = args.get(..args.len().saturating_sub(command.len())).unwrap_or_default();
    let words = cloud_start_chat::lift_output_of(rest, &mut global.output, TAKES_VALUE);
    let start = match parse(&words) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run(start)) => start,
        Err(error) => return Some(usage_failure(&error, global.output)),
    };
    Some(run(&global, prefix, start))
}

/// The words after `chat` (or `chat new`).
pub(super) fn parse(words: &[String]) -> Result<Parsed, UsageError> {
    let mut start = Start {
        target: Target::Here,
        agent: None,
        model: None,
        cwd: None,
        name: None,
        prompt: None,
        wait: false,
        timeout: None,
    };
    let mut device = None;
    let mut vm = None;
    let mut index = 0;
    while let Some(word) = words.get(index).map(String::as_str) {
        if word == "--" {
            match words.get(index + 1..).unwrap_or_default() {
                [] => {}
                [text] => set_prompt(&mut start.prompt, text.clone())?,
                _ => return Err(UsageError::new("give the prompt as one quoted argument")),
            }
            break;
        }
        if !word.starts_with('-') || word == "-" {
            if index + 1 != words.len() {
                return Err(UsageError::new(format!("unexpected argument {word:?}")));
            }
            set_prompt(&mut start.prompt, word.to_owned())?;
            break;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word, None),
        };
        let mut value = || -> Result<String, UsageError> {
            if let Some(value) = inline.clone() {
                return Ok(value);
            }
            index += 1;
            words
                .get(index)
                .cloned()
                .ok_or_else(|| UsageError::new(format!("{flag} needs a value")))
        };
        match flag {
            "-h" | "--help" => return Ok(Parsed::Help),
            "--device" => device = Some(value()?),
            "--vm" => vm = Some(value()?),
            "--prompt" | "-p" => {
                let text = value()?;
                set_prompt(&mut start.prompt, text)?;
            }
            "--agent" | "--harness" => start.agent = Some(value()?),
            "--model" => start.model = Some(value()?),
            "--cwd" => start.cwd = Some(value()?),
            "--name" => start.name = Some(value()?),
            "--timeout" => start.timeout = Some(value()?),
            "--wait" => start.wait = true,
            "--no-wait" => start.wait = false,
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
        index += 1;
    }
    start.target = match (device, vm) {
        (Some(_), Some(_)) => return Err(UsageError::new("give --device or --vm, not both")),
        (Some(device), None) if device.trim().is_empty() => {
            return Err(UsageError::new("--device needs a machine id, a name, or cloud"));
        }
        (Some(device), None) => Target::Device(device.trim().to_owned()),
        (None, Some(vm)) => Target::Vm(vm_machine(&vm)?),
        (None, None) => Target::Here,
    };
    Ok(Parsed::Run(start))
}

fn set_prompt(slot: &mut Option<String>, text: String) -> Result<(), UsageError> {
    if slot.is_some() {
        return Err(UsageError::new("give the prompt once"));
    }
    *slot = Some(text);
    Ok(())
}

/// `--vm`'s value: `new`, `machine:ID`, or a machine's name.
fn vm_machine(value: &str) -> Result<Machine, UsageError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(UsageError::new("--vm needs machine:ID, a machine name, or new"));
    }
    if value == "new" {
        return Ok(Machine::New);
    }
    match value.strip_prefix("machine:") {
        Some("") => Err(UsageError::new("--vm machine:MACHINE_ID")),
        Some(id) => Ok(Machine::Target(id.to_owned())),
        None => Ok(Machine::Named(value.to_owned())),
    }
}

/// Where `selector` runs a chat, checked against `catalog` (`machine.list` with `catalog: true`,
/// read for this call) by the SDK's [`cmux::resolve_chat_target`]. `signed_in` reads the app's
/// cloud sign-in, and only when the target needs it. A name that names exactly one device is read
/// as that device's id; the id is what the check sees.
pub(super) fn route(
    selector: &str,
    catalog: &Value,
    signed_in: impl FnOnce() -> bool,
) -> Result<Route, Value> {
    let id = if selector == "cloud" { selector.to_owned() } else { device_id(selector, catalog)? };
    let record = machines(catalog).iter().find(|machine| text(machine, "id") == Some(id.as_str()));
    let origin = record.and_then(|machine| text(machine, "origin")).unwrap_or("local");
    let needs_sign_in = id == "cloud" || origin == "cloud";
    let signed_in = needs_sign_in && signed_in();
    match cmux::resolve_chat_target(&id, catalog, signed_in) {
        Err(refusal) => Err(refused(&refusal)),
        Ok(ChatTarget::Cloud) => Ok(Route::Cloud(Machine::New)),
        Ok(ChatTarget::Device { local: true, .. }) => Ok(Route::Here),
        Ok(ChatTarget::Device { id, local: false }) => match (origin, record) {
            // A Cloud machine in the catalog is the app's Cloud machine of that name.
            ("cloud", Some(machine)) => {
                Ok(Route::Cloud(Machine::Named(text(machine, "name").unwrap_or(&id).to_owned())))
            }
            _ => Err(json!({
                "code": "chat_target.no_route",
                "message": format!(
                    "device {id} ({origin}) runs agent chats, but the CLI cannot start one there \
                     yet; open a workspace on it in the cmux app and start the chat there"
                ),
                "details": {"device": id, "origin": origin},
                "retryable": false,
            })),
        },
    }
}

/// The id `selector` names: a catalog machine with that id, else the one machine with that name.
fn device_id(selector: &str, catalog: &Value) -> Result<String, Value> {
    let machines = machines(catalog);
    if machines.iter().any(|machine| text(machine, "id") == Some(selector)) {
        return Ok(selector.to_owned());
    }
    let named: Vec<&str> = machines
        .iter()
        .filter(|machine| text(machine, "name") == Some(selector))
        .filter_map(|machine| text(machine, "id"))
        .collect();
    match named.as_slice() {
        [id] => Ok((*id).to_owned()),
        [] => Err(refused(&ChatTargetRefusal::UnknownDevice { id: selector.to_owned() })),
        ids => Err(json!({
            "code": "chat_target.ambiguous_device",
            "message": format!("{} devices are named {selector}; give one id: {}", ids.len(),
                               ids.join(", ")),
            "details": {"name": selector, "ids": ids},
            "retryable": false,
        })),
    }
}

fn refused(refusal: &ChatTargetRefusal) -> Value {
    json!({"code": refusal.code(), "message": refusal.to_string(), "details": {},
           "retryable": false})
}

fn machines(catalog: &Value) -> &[Value] {
    catalog.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice)
}

fn text<'a>(machine: &'a Value, key: &str) -> Option<&'a str> {
    machine.get(key).and_then(Value::as_str)
}

fn run(global: &GlobalArgs, prefix: &[String], start: Start) -> i32 {
    let route = match &start.target {
        Target::Here => Route::Here,
        Target::Vm(machine) => Route::Cloud(machine.clone()),
        Target::Device(selector) => {
            let catalog = match read_catalog(global) {
                Ok(catalog) => catalog,
                Err(error) => return super::wire::print_local_error(&error, global.output, 1),
            };
            match route(selector, &catalog, || cloud_start_chat::app_signed_in(global)) {
                Ok(route) => route,
                Err(error) => return super::wire::print_local_error(&error, global.output, 1),
            }
        }
    };
    match route {
        Route::Here => match here_words(prefix, &start) {
            Ok(words) => super::agents::run_if_requested(&words).unwrap_or(2),
            Err(error) => usage_failure(&error, global.output),
        },
        Route::Cloud(machine) => match cloud_words(&start, &machine) {
            Ok(words) => {
                let parsed = cloud_start_chat::parse(&words, read_stdin);
                match parsed {
                    Ok(cloud_start_chat::Parsed::Run(request)) => {
                        cloud_start_chat::start(global, &request)
                    }
                    Ok(cloud_start_chat::Parsed::Help) => {
                        print!("{USAGE}");
                        0
                    }
                    Err(error) => usage_failure(&error, global.output),
                }
            }
            Err(error) => usage_failure(&error, global.output),
        },
    }
}

/// The daemon's machine catalog, read now through the SDK (`machine.list`, `catalog: true`).
fn read_catalog(global: &GlobalArgs) -> Result<Value, Value> {
    let (socket, _) = super::wire::resolve_socket_with_origin(global).map_err(|error| {
        json!({"code": "daemon.unreachable",
               "message": super::wire::resolve_failure_message(&error),
               "details": {}, "retryable": true})
    })?;
    let unreachable = |error: cmux::Error| {
        json!({"code": "daemon.unreachable", "message": error.to_string(), "details": {},
               "retryable": true})
    };
    let client =
        cmux::Client::connect(cmux::Config::from_socket_path(socket).with_timeout(CATALOG_TIMEOUT))
            .map_err(unreachable)?;
    client.call("machine.list", CallKind::Read, json!({"catalog": true})).map_err(unreachable)
}

/// `agents chat new …` with this start's settings, after the same globals.
pub(super) fn here_words(prefix: &[String], start: &Start) -> Result<Vec<String>, UsageError> {
    if start.wait || start.timeout.is_some() {
        return Err(UsageError::new(
            "--wait and --timeout wait for a Cloud chat; for a chat here, `cmux agents wait`",
        ));
    }
    let mut words = prefix.to_vec();
    words.extend(["agents", "chat", "new"].map(str::to_owned));
    for (flag, value) in [
        ("--harness", &start.agent),
        ("--model", &start.model),
        ("--cwd", &start.cwd),
        ("--name", &start.name),
    ] {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.clone()]);
        }
    }
    if let Some(prompt) = &start.prompt {
        let prompt =
            if prompt == "-" { read_stdin().map_err(UsageError::new)? } else { prompt.clone() };
        words.extend(["--".to_owned(), prompt]);
    }
    Ok(words)
}

/// The `cloud start-chat` words for this start on `machine`.
pub(super) fn cloud_words(start: &Start, machine: &Machine) -> Result<Vec<String>, UsageError> {
    if start.model.is_some() || start.name.is_some() {
        return Err(UsageError::new(
            "--model and --name name a chat here; a Cloud chat takes --agent, --cwd and --prompt",
        ));
    }
    let Some(prompt) = &start.prompt else {
        return Err(UsageError::new("a Cloud chat needs a first prompt: --prompt TEXT"));
    };
    let mut words = vec!["--prompt".to_owned(), prompt.clone()];
    match machine {
        Machine::Named(name) => words.extend(["--name".to_owned(), name.clone()]),
        Machine::Target(id) => words.extend(["--target".to_owned(), format!("machine:{id}")]),
        Machine::New => {}
    }
    for (flag, value) in
        [("--agent", &start.agent), ("--cwd", &start.cwd), ("--timeout", &start.timeout)]
    {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.clone()]);
        }
    }
    if start.wait {
        words.push("--wait".to_owned());
    }
    Ok(words)
}

fn read_stdin() -> Result<String, String> {
    use std::io::Read as _;
    let mut text = String::new();
    std::io::stdin().read_to_string(&mut text).map(|_| text).map_err(|error| error.to_string())
}

fn usage_failure(error: &UsageError, output: OutputMode) -> i32 {
    super::app::failure("usage.invalid", &format!("cmux: {}\n{USAGE}", error.0), output, 2)
}

#[cfg(test)]
mod tests;
