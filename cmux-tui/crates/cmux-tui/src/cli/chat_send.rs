//! `cmux chat send SESSION 'TEXT'` and `cmux chat --resume SESSION 'TEXT'`: the next prompt to a
//! chat that is already running, wherever `cmux chat` started it (Leo's CLI walkthrough,
//! 2026-11-07, cmuxterm-hq#7487 item 4). The session id decides where it goes, so the person
//! never names the machine again:
//!
//! - a chat tab the cmux app shows in a Cloud VM's workspace (its `snapshot.get` topology: the
//!   tab's `agent_session`, its workspace's `machine`) gets the prompt on that VM, as `cmux chat
//!   --on vm:…` sends its first one (cloud_start_chat.rs), and `--wait` prints the reply;
//! - any other session is this machine's: `cmux agents chat send SESSION`, which says when no
//!   chat has that id.
//!
//! `--on here|vm:ID|NAME` names the place instead, without the lookup. `cmux chat send --to …`
//! stays the message to a Chief, a person or a group (chief/chat_scope.rs).

#[cfg(test)]
mod tests;

use std::time::Duration;

use serde_json::{Value, json};

use super::chat_start;
use super::cloud_start_chat::{self, Machine};
use super::{GlobalArgs, OutputMode, UsageError};

pub(super) const USAGE: &str = "\
usage: cmux chat send SESSION [--on here|vm:ID|NAME] [--wait] [--timeout SECONDS] [--json] TEXT
       cmux chat --resume SESSION [--on here|vm:ID|NAME] [--wait] [--timeout SECONDS] [--json] TEXT

Sends the next prompt to the chat SESSION (the session_id `cmux chat` answered), wherever it
runs: here, or on the Cloud VM whose workspace in the cmux app shows it. TEXT `-` reads stdin.

  --on TARGET        Where the chat runs, when the app does not show it: here or vm:ID|NAME
  --wait             Wait for the turn to end and print the reply (a chat on a Cloud VM)
  --timeout SECONDS  How long --wait waits (default 900)

  cmux chat send --to chief|PERSON|GROUP --text TEXT messages a Chief or a person instead
  (`cmux chat send --help` without a SESSION).
";

/// The flags that take the next word as their value.
const TAKES_VALUE: &[&str] = &["--on", "--timeout", "--prompt", "-p", "--resume"];

/// A parsed send.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Send {
    pub session: String,
    pub text: String,
    pub on: Option<String>,
    pub wait: bool,
    pub timeout: Option<Duration>,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run(Send),
}

/// Where the chat runs.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Place {
    Here,
    Vm(String),
}

/// `Some(exit code)` when `args` is a send to a session: `chat send SESSION …` (no `--to`) or
/// `chat … --resume SESSION …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let words = words_of(&command)?;
    let words = cloud_start_chat::lift_output_of(words, &mut global.output, TAKES_VALUE);
    let send = match parse(&words, command.get(1).map(String::as_str) == Some("send")) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run(send)) => send,
        Err(error) => return Some(usage_failure(&error, global.output)),
    };
    let place = locate(
        &send.session,
        send.on.as_deref(),
        || topology(&global),
        || cloud_start_chat::app_machines(&global),
    );
    Some(match place {
        Ok(Place::Here) => here(&global, &send),
        Ok(Place::Vm(machine)) => cloud_start_chat::send_existing(
            &global,
            &machine,
            &send.session,
            send.text,
            send.wait,
            send.timeout,
        ),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    })
}

/// The words after `chat send` or `chat` for a send to a session, else `None`: `chat send` with
/// `--to` (or no session word) is chief/chat_scope.rs's, and a `chat` start without `--resume`
/// is chat_start.rs's.
fn words_of(command: &[String]) -> Option<&[String]> {
    let [scope, rest @ ..] = command else { return None };
    if scope != "chat" {
        return None;
    }
    match rest.split_first() {
        Some((verb, after)) if verb == "send" => {
            let (flags, positional) = scan(after);
            let names_a_chief = flags.iter().any(|flag| ["--to", "--text"].contains(flag));
            (positional && !names_a_chief).then_some(after)
        }
        _ => scan(rest).0.contains(&"--resume").then_some(rest),
    }
}

/// The flags `words` give in flag position (a flag's value, and anything after `--`, is text:
/// `cmux chat --prompt --resume` is a start), each without its `=value`; and whether a word
/// stands alone before `--` (a session id).
fn scan(words: &[String]) -> (Vec<&str>, bool) {
    // This file's, chat_start.rs's and chief/chat_scope.rs's flags that take a value.
    const VALUED: &[&str] = &[
        "--on",
        "--timeout",
        "--prompt",
        "-p",
        "--resume",
        "--agent",
        "--harness",
        "--model",
        "--cwd",
        "--name",
        "--to",
        "--text",
        "--from",
        "--class",
    ];
    let mut flags = Vec::new();
    let mut positional = false;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if word == "--" {
            break;
        }
        if !word.starts_with('-') || word == "-" {
            positional = true;
            continue;
        }
        let (flag, inline) =
            word.split_once('=').map_or((word.as_str(), false), |(f, _)| (f, true));
        if VALUED.contains(&flag) && !inline {
            words.next();
        }
        flags.push(flag);
    }
    (flags, positional)
}

pub(super) fn parse(words: &[String], send_verb: bool) -> Result<Parsed, UsageError> {
    let mut send = Send::default();
    let mut session = None;
    let mut text = None;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, inline)) if flag.starts_with("--") => (flag, Some(inline)),
            _ => (word.as_str(), None),
        };
        let mut take = || match inline {
            Some(inline) => Ok(inline.to_owned()),
            None => words
                .next()
                .cloned()
                .ok_or_else(|| UsageError::new(format!("{flag} needs a value"))),
        };
        match flag {
            "-h" | "--help" => return Ok(Parsed::Help),
            "--wait" => send.wait = true,
            "--on" => send.on = Some(take()?),
            "--resume" if !send_verb => set(&mut session, take()?, "the session")?,
            "--prompt" | "-p" => set(&mut text, take()?, "the prompt")?,
            "--timeout" => {
                let seconds = take()?;
                // As `cloud start-chat` takes it: whole seconds, more than none.
                let seconds =
                    seconds.parse::<u64>().ok().filter(|seconds| *seconds > 0).ok_or_else(
                        || UsageError::new(format!("--timeout takes seconds, not {seconds}")),
                    )?;
                send.timeout = Some(Duration::from_secs(seconds));
            }
            "--" => {
                let rest: Vec<String> = words.by_ref().cloned().collect();
                for rest in rest {
                    set(&mut text, rest, "the prompt")?;
                }
            }
            _ if word.starts_with('-') && word != "-" => {
                return Err(UsageError::new(format!("unknown flag {word}")));
            }
            _ if send_verb && session.is_none() => session = Some(word.clone()),
            _ => set(&mut text, word.clone(), "the prompt")?,
        }
    }
    send.session = session.ok_or_else(|| UsageError::new("name the chat: its SESSION id"))?;
    let text = text.ok_or_else(|| UsageError::new("give the prompt: TEXT, or - for stdin"))?;
    send.text = if text == "-" { chat_start::read_stdin().map_err(UsageError::new)? } else { text };
    if send.text.trim().is_empty() {
        return Err(UsageError::new("the prompt is empty"));
    }
    Ok(Parsed::Run(send))
}

fn set(slot: &mut Option<String>, value: String, what: &str) -> Result<(), UsageError> {
    if slot.is_some() {
        return Err(UsageError::new(format!("give {what} once (quote a prompt of several words)")));
    }
    *slot = Some(value);
    Ok(())
}

/// Where chat `session` runs: `on` when given, else the workspace the app shows its tab in.
pub(super) fn locate<T, L>(
    session: &str,
    on: Option<&str>,
    topology: T,
    listed: L,
) -> Result<Place, Value>
where
    T: FnOnce() -> Result<Value, Value>,
    L: FnOnce() -> Result<Value, Value>,
{
    match on {
        Some("here") => return Ok(Place::Here),
        Some(on) => {
            let Some(vm) = on.strip_prefix("vm:").filter(|vm| *vm != "new") else {
                return Err(refusal(
                    "chat_target.no_route",
                    format!(
                        "a prompt to a running chat goes --on here or --on vm:ID|NAME, not {on}"
                    ),
                    "leave out --on: the session id finds its chat",
                    json!({"on": on}),
                ));
            };
            let vm = vm.strip_prefix("machine:").unwrap_or(vm);
            return match chat_start::existing_vm(vm, Some(vm), &listed()?) {
                Ok(Machine::Target(id)) => Ok(Place::Vm(id)),
                Ok(_) | Err(_) => Err(refusal(
                    "chat_target.unknown_vm",
                    format!("no one VM of yours has the id or name {vm}"),
                    "run `cmux vm list-machines` for your VMs",
                    json!({"vm": vm}),
                )),
            };
        }
        None => {}
    }
    // No app (CI, a headless agent): only this machine's chats are reachable.
    let Ok(topology) = topology() else { return Ok(Place::Here) };
    Ok(match machine_of(session, &topology) {
        Some(machine) if is_cloud(&machine, &topology) => Place::Vm(machine),
        _ => Place::Here,
    })
}

/// The `machine` of the workspace whose tab shows chat `session`.
fn machine_of(session: &str, topology: &Value) -> Option<String> {
    fn shows(value: &Value, session: &str) -> bool {
        match value {
            Value::Object(object) => {
                object.get("agent_session").and_then(Value::as_str) == Some(session)
                    || object.values().any(|child| shows(child, session))
            }
            Value::Array(values) => values.iter().any(|value| shows(value, session)),
            _ => false,
        }
    }
    let workspaces = topology.get("workspaces").and_then(Value::as_array)?;
    let workspace = workspaces.iter().find(|workspace| shows(workspace, session))?;
    if let Some(machine) = workspace.get("machine").and_then(Value::as_str) {
        return Some(machine.to_owned());
    }
    // No machine on the workspace: its session's (`sessions[].machine`).
    let id = workspace.get("session").and_then(Value::as_str)?;
    sessions(topology)
        .iter()
        .find(|row| row.get("id").and_then(Value::as_str) == Some(id))
        .and_then(|row| row.get("machine").and_then(Value::as_str))
        .map(str::to_owned)
}

/// Whether `machine` is a Cloud VM: its session's transport says `cloud`.
fn is_cloud(machine: &str, topology: &Value) -> bool {
    sessions(topology).iter().any(|row| {
        row.get("machine").and_then(Value::as_str) == Some(machine)
            && row.get("transport").and_then(Value::as_str) == Some("cloud")
    })
}

fn sessions(topology: &Value) -> &[Value] {
    topology.get("sessions").and_then(Value::as_array).map_or(&[][..], Vec::as_slice)
}

/// The app's topology (`snapshot.get`), or why it could not be read.
fn topology(global: &GlobalArgs) -> Result<Value, Value> {
    let read =
        super::mcp::agent_app(global, "snapshot.get", json!({}), super::app::READ_TIMEOUT, None)?;
    read.get("topology").cloned().ok_or(read)
}

/// `cmux agents chat send SESSION -- TEXT` with the same globals.
fn here(global: &GlobalArgs, send: &Send) -> i32 {
    if send.wait || send.timeout.is_some() {
        return usage_failure(
            &UsageError::new(
                "--wait and --timeout wait for a chat on a Cloud VM; for a chat here, `cmux agents wait`",
            ),
            global.output,
        );
    }
    let mut words = chat_start::global_words(global);
    words.extend(["agents", "chat", "send", &send.session, "--", &send.text].map(str::to_owned));
    super::agents::run_if_requested(&words).unwrap_or(2)
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: String, next: &str, mut details: Value) -> Value {
    if let Some(map) = details.as_object_mut() {
        map.insert("next".to_owned(), json!(next));
    }
    json!({"code": code, "message": format!("{message}; {next}"), "details": details,
           "retryable": false})
}

fn usage_failure(error: &UsageError, output: OutputMode) -> i32 {
    super::app::failure("usage.invalid", &format!("cmux: {}\n{USAGE}", error.0), output, 2)
}
