//! `cmux chat [--on TARGET] [flags] [PROMPT]`: start an agent chat, here by default, or on a
//! device, a Cloud VM or in cmux Cloud (Leo, 2026-11-07: "the goal is like... cmux chat is normal,
//! and cmux chat with the flag/arguments can separate if you want it on a different
//! device/vm/cloud/whatevret"; the one-flag shape, Leo, 2026-11-07: "i think this will be good").
//!
//! One flag, `--on`, whose value decides the kind of target, so it is learned once for every verb
//! that runs something somewhere:
//!
//! - no `--on` (and no `CMUX_TARGET`), or `--on here`: right here, as `cmux agents chat new`
//!   starts it (a chat tab in the app, in this machine's acpmux);
//! - `--on cloud`: cmux Cloud, today a new Cloud VM;
//! - `--on vm:new`: a new Cloud VM; `--on vm:ID|NAME`: the app's existing Cloud VM with that id,
//!   or the one VM with that title, never one made for it. Both are the run `cmux cloud
//!   start-chat` does (cloud_start_chat.rs), which stays as that run's old name;
//! - `--on DEVICE`: a device of the daemon's machine catalog by its id, or the one device with
//!   that name. It goes through the SDK's [`cmux::resolve_chat_target`] first, with the catalog
//!   and the app's cloud sign-in read now, so a device the person may not use, one that does not
//!   run agent chats or one not running is refused before anything starts. Nothing here keeps a
//!   device list of its own.
//!
//! `CMUX_TARGET` names the target when `--on` is absent, as `DOCKER_CONTEXT` does. A refusal says
//! what to run next. `cloud`, `here` and `vm:…` are selectors, never device names: a device called
//! "cloud" is reached by its id.

use std::time::Duration;

use cmux::{CallKind, ChatTarget, ChatTargetRefusal};
use serde_json::{Value, json};

use super::cloud_start_chat::{self, Machine};
use super::{GlobalArgs, OutputMode, UsageError};

/// This command's flags that take the next word as their value.
const TAKES_VALUE: &[&str] =
    &["--on", "--prompt", "-p", "--agent", "--harness", "--model", "--cwd", "--name", "--timeout"];

/// The `chat` verbs other modules own (chief/chat_scope.rs and the app's `chat …` actions).
const OTHER_VERBS: &[&str] = &["send", "read", "wait", "list", "create", "replies", "colors"];

/// The environment variable that names the target when `--on` is absent.
pub(super) const TARGET_ENV: &str = "CMUX_TARGET";

/// How long the catalog read may take.
const CATALOG_TIMEOUT: Duration = Duration::from_secs(10);

/// What a refusal says to run next.
const LIST_DEVICES: &str = "run `cmux machine list` for your devices and their ids";
const LIST_VMS: &str = "run `cmux vm list-machines` for your VMs, or use --on vm:new";

pub(super) const USAGE: &str = "\
usage: cmux chat [--on TARGET] [--agent AGENT] [--model MODEL] [--cwd DIR]
                 [--name NAME] [--wait] [--timeout SECONDS] [--json] [[--prompt] TEXT]

Starts an agent chat, right here unless --on names another target:

  --on here          This machine, as a tab in the cmux app (the default)
  --on cloud         cmux Cloud (a new Cloud VM)
  --on vm:new        A new Cloud VM
  --on vm:ID|NAME    Your Cloud VM with that id or name (`cmux vm list-machines`)
  --on DEVICE        A connected device by its id or name (`cmux machine list`);
                     it must be yours, running, and run agent chats
  CMUX_TARGET=TARGET names the target when --on is absent.

  --agent AGENT      claude (default), codex, ...
  --model MODEL      The agent's model (a chat here)
  --cwd DIR          The chat's folder (absolute)
  --name NAME        The chat's name (a chat here)
  --prompt TEXT      A first prompt (`-` reads it from stdin); a Cloud chat needs one
  --wait             Wait for a Cloud chat's turn to end and print the reply
  --timeout SECONDS  How long --wait waits (default 900)

EXAMPLES
  cmux chat 'Summarize README.md'
  cmux chat --on studio-mac 'Run the tests'
  cmux chat --on vm:new --prompt 'Summarize README.md' --wait --json
  cmux chat --on vm:dev --cwd /home/cmux/work --prompt 'Run the tests' --json

Messages to a chat: cmux chat send|read|wait|list (`cmux chat send --help`).
A refused target exits 1 and says what to run next (chat_target.unknown_device,
ambiguous_device, unknown_vm, not_permitted, unavailable, signed_out, no_route).
Exit codes: 0 ok, 1 refused, 2 bad arguments.
";

/// A parsed `cmux chat …` start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Start {
    /// `--on`'s value, else `CMUX_TARGET`'s; None is here.
    pub on: Option<String>,
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
    /// A Cloud VM (`cloud start-chat`'s run).
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
    let start = match parse(&words, std::env::var(TARGET_ENV).ok()) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run(start)) => start,
        Err(error) => return Some(usage_failure(&error, global.output)),
    };
    Some(run(&global, prefix, start))
}

/// The words after `chat` (or `chat new`); `env_target` is `CMUX_TARGET`, read when `--on` is
/// absent (an empty one is unset).
pub(super) fn parse(words: &[String], env_target: Option<String>) -> Result<Parsed, UsageError> {
    let mut start = Start {
        on: None,
        agent: None,
        model: None,
        cwd: None,
        name: None,
        prompt: None,
        wait: false,
        timeout: None,
    };
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
            "--on" => {
                if start.on.is_some() {
                    return Err(UsageError::new("give --on once"));
                }
                let on = value()?.trim().to_owned();
                if on.is_empty() {
                    return Err(UsageError::new(
                        "--on needs a target: here, cloud, vm:new, vm:ID|NAME or a device",
                    ));
                }
                start.on = Some(on);
            }
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
    if start.on.is_none() {
        start.on = env_target.map(|target| target.trim().to_owned()).filter(|t| !t.is_empty());
    }
    if start.on.as_deref() == Some("vm:") {
        return Err(UsageError::new("--on vm: needs new, or a VM's id or name"));
    }
    Ok(Parsed::Run(start))
}

fn set_prompt(slot: &mut Option<String>, text: String) -> Result<(), UsageError> {
    if slot.is_some() {
        return Err(UsageError::new("give the prompt once"));
    }
    *slot = Some(text);
    Ok(())
}

/// What `route` reads, each only when the target needs it.
pub(super) struct Reads<C, S, L> {
    /// The daemon's machine catalog (`machine.list`, `catalog: true`).
    pub catalog: C,
    /// The app's cloud sign-in now.
    pub signed_in: S,
    /// The app's `cloud list-machines` answer.
    pub cloud_machines: L,
}

/// Where target `on` runs a chat (module docs). A device is checked by the SDK's
/// [`cmux::resolve_chat_target`] against the catalog read now; a name that names exactly one
/// device is read as its id, and the id is what the check sees.
pub(super) fn route<C, S, L>(on: Option<&str>, reads: Reads<C, S, L>) -> Result<Route, Value>
where
    C: FnOnce() -> Result<Value, Value>,
    S: FnOnce() -> bool,
    L: FnOnce() -> Result<Value, Value>,
{
    let Some(on) = on else { return Ok(Route::Here) };
    if on == "here" {
        return Ok(Route::Here);
    }
    if on == "cloud" {
        return match cmux::resolve_chat_target("cloud", &Value::Null, (reads.signed_in)()) {
            Ok(_) => Ok(Route::Cloud(Machine::New)),
            Err(refusal) => Err(refused(&refusal)),
        };
    }
    if let Some(vm) = on.strip_prefix("vm:") {
        if vm == "new" {
            return Ok(Route::Cloud(Machine::New));
        }
        let vm = vm.strip_prefix("machine:").unwrap_or(vm);
        return existing_vm(vm, Some(vm), &(reads.cloud_machines)()?).map(Route::Cloud).map_err(
            |found| {
                refusal(
                    "chat_target.unknown_vm",
                    format!("no one VM of yours has the id or name {vm}"),
                    LIST_VMS,
                    json!({"vm": vm, "matches": found}),
                )
            },
        );
    }
    let catalog = (reads.catalog)()?;
    let id = device_id(on, &catalog)?;
    let record = machines(&catalog).iter().find(|machine| text(machine, "id") == Some(id.as_str()));
    let origin = record.and_then(|machine| text(machine, "origin")).unwrap_or("local");
    let signed_in = origin == "cloud" && (reads.signed_in)();
    match cmux::resolve_chat_target(&id, &catalog, signed_in) {
        Err(refusal) => Err(refused(&refusal)),
        Ok(ChatTarget::Cloud) => Ok(Route::Cloud(Machine::New)),
        Ok(ChatTarget::Device { local: true, .. }) => Ok(Route::Here),
        Ok(ChatTarget::Device { id, local: false }) => match (origin, record) {
            ("cloud", Some(machine)) => {
                existing_vm(&id, text(machine, "name"), &(reads.cloud_machines)()?)
                    .map(Route::Cloud)
                    .map_err(|found| {
                        refusal(
                            "chat_target.unavailable",
                            format!("device {id} is a Cloud VM the app does not list as one VM"),
                            LIST_VMS,
                            json!({"device": id, "matches": found}),
                        )
                    })
            }
            _ => Err(refusal(
                "chat_target.no_route",
                format!(
                    "device {id} ({origin}) runs agent chats, but the CLI cannot start one there yet"
                ),
                "open a workspace on it in the cmux app and start the chat there",
                json!({"device": id, "origin": origin}),
            )),
        },
    }
}

/// The app's existing Cloud VM with machine id `id`, else the one VM titled `name`, from its
/// `cloud list-machines` answer. Err: the ids that matched (none, or several).
fn existing_vm(id: &str, name: Option<&str>, listed: &Value) -> Result<Machine, Vec<String>> {
    let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    if rows.iter().any(|row| text(row, "machine_id") == Some(id)) {
        return Ok(Machine::Target(id.to_owned()));
    }
    let titled: Vec<String> = rows
        .iter()
        .filter(|row| name.is_some() && text(row, "title") == name)
        .filter_map(|row| text(row, "machine_id").map(str::to_owned))
        .collect();
    match titled.as_slice() {
        [machine] => Ok(Machine::Target(machine.clone())),
        _ => Err(titled),
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
        ids => Err(refusal(
            "chat_target.ambiguous_device",
            format!("{} devices are named {selector}", ids.len()),
            &format!("give one id: {}", ids.join(", ")),
            json!({"name": selector, "ids": ids}),
        )),
    }
}

/// The SDK's refusal, with what to run next.
fn refused(refusal: &ChatTargetRefusal) -> Value {
    let next = match refusal {
        ChatTargetRefusal::SignedOut => "run `cmux vm sign-in`, then this command again",
        _ => LIST_DEVICES,
    };
    self::refusal(refusal.code(), refusal.to_string(), next, json!({}))
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: String, next: &str, mut details: Value) -> Value {
    if let Some(map) = details.as_object_mut() {
        map.insert("next".to_owned(), json!(next));
    }
    json!({"code": code, "message": format!("{message}; {next}"), "details": details,
           "retryable": false})
}

fn machines(catalog: &Value) -> &[Value] {
    cmux::catalog_machines(catalog)
}

fn text<'a>(machine: &'a Value, key: &str) -> Option<&'a str> {
    machine.get(key).and_then(Value::as_str)
}

fn run(global: &GlobalArgs, prefix: &[String], start: Start) -> i32 {
    let reads = Reads {
        catalog: || read_catalog(global),
        signed_in: || cloud_start_chat::app_signed_in(global),
        cloud_machines: || cloud_start_chat::app_machines(global),
    };
    let route = match route(start.on.as_deref(), reads) {
        Ok(route) => route,
        Err(error) => return super::wire::print_local_error(&error, global.output, 1),
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
