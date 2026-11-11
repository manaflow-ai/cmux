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
//!
//! `--wait` waits for the turn and prints its reply here as on a Cloud VM (agents/turn.rs here).
//! `cmux chat read SESSION` and `cmux chat wait SESSION`, with a chat's session id (a UUID, or
//! `acp:…`) as the first word, read that chat's transcript and wait for its turn; `cmux chat
//! read|wait --to …` stays the Chief's.

#[cfg(test)]
mod tests;

use std::time::Duration;

use serde_json::{Value, json};

use super::agents::turn::{self, Begin};
use super::chat_start;
use super::cloud_start_chat::{self, Machine};
use super::{GlobalArgs, OutputMode, UsageError};

pub(super) const USAGE: &str = "\
usage: cmux chat send [SESSION|last] [--on here|vm:ID|NAME] [-w] [--timeout DURATION] [--json] TEXT
       cmux chat --resume SESSION [--on here|vm:ID|NAME] [-w] [--timeout DURATION] [--json] TEXT

Sends the next prompt to the chat SESSION (the session_id `cmux chat` answered), wherever it
runs: here, or on the Cloud VM whose workspace in the cmux app shows it. TEXT `-` reads stdin.
Without SESSION (or with `last`) it goes to the last chat this terminal started or sent to:
  cmux chat --on vm:new 'Run the tests'
  cmux chat send -w 'Now fix the failing one'

  --on TARGET        Where the chat runs, when the app does not show it: here or vm:ID|NAME
  -w, --wait         Wait for the turn to end and print the reply
  --timeout DURATION How long --wait waits: 30s, 5m, 1h (a bare number is seconds;
                     default 15m, at most 4h)

With --wait the answer has session_id and reply (and the turn's status); a chat here also
answers workspace_id and tab_id from `cmux chat`. Exit codes: 0 ok, 1 refused or the turn
failed, 2 bad arguments or the agent waits on a permission, 3 --timeout passed
(chat.wait_timeout, details.answer.timed_out true).

A chat here, by its session id (a UUID or acp:…), or `last`:
  cmux chat read SESSION|last [--after ID] [--limit N]   Its transcript (`cmux agents chat read`)
  cmux chat wait SESSION|last [--timeout DURATION]        Wait for its turn to end, print the reply

  cmux chat send --to chief|PERSON|GROUP --text TEXT messages a Chief or a person instead
  (`cmux chat send --help` without a SESSION).
";

/// `cmux chat wait SESSION`'s usage.
const WAIT_USAGE: &str = "\
usage: cmux chat wait SESSION|last [--timeout DURATION] [--json]

Waits until the chat SESSION here (a UUID or acp:…; `last`: the last chat this terminal started
or sent to) stops working and prints the reply of its
last turn, as `cmux chat send SESSION TEXT --wait` does. --timeout defaults to 900 seconds.
Exit codes: 0 ok, 1 refused or the turn failed, 2 bad arguments or the agent waits on a
permission, 3 --timeout passed (chat.wait_timeout).
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
    if let Some((verb, words)) = session_verb(&command) {
        return Some(read_or_wait(&mut global, verb, words));
    }
    let words = words_of(&command)?;
    let words = cloud_start_chat::lift_output_of(words, &mut global.output, TAKES_VALUE);
    let mut send = match parse(&words, command.get(1).map(String::as_str) == Some("send")) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run(send)) => send,
        Err(error) => return Some(usage_failure(&error, global.output)),
    };
    if send.session == super::last_chat::LAST {
        let Some(last) = super::last_chat::recall() else {
            return Some(super::wire::print_local_error(
                &super::last_chat::none_yet(),
                global.output,
                1,
            ));
        };
        send.session = last.session;
        // Its VM, as recorded: no lookup in the app's topology.
        if send.on.is_none() {
            send.on = last.vm.map(|vm| format!("vm:{vm}"));
        }
    }
    let place = locate(
        &send.session,
        send.on.as_deref(),
        || topology(&global),
        || cloud_start_chat::app_machines(&global),
    );
    Some(match place {
        Ok(Place::Here) => {
            let code = here(&global, &send);
            if code == 0 {
                super::last_chat::remember(&send.session, None);
            }
            code
        }
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

/// Whether `word` names an agent chat by its session id: a UUID, or `acp:…`. A Chief chat is
/// named with `--to`, and `chat read|wait` words are message refs (`#SEQ`, `msg_…`), never these.
pub(super) fn is_session_id(word: &str) -> bool {
    word.starts_with("acp:") || uuid::Uuid::parse_str(word).is_ok()
}

/// `chat read SESSION …` or `chat wait SESSION …`: the verb and the words after it, from the
/// session on.
pub(super) fn session_verb(command: &[String]) -> Option<(&str, &[String])> {
    let [scope, verb, rest @ ..] = command else { return None };
    let first = rest.first()?;
    let ours = scope == "chat"
        && matches!(verb.as_str(), "read" | "wait")
        && (is_session_id(first) || first == super::last_chat::LAST);
    ours.then_some((verb.as_str(), rest))
}

/// `chat wait SESSION [--timeout S]`: the session and the timeout.
pub(super) fn parse_wait(words: &[String]) -> Result<Option<(String, Duration)>, UsageError> {
    let mut session = None;
    let mut timeout = turn::DEFAULT_TIMEOUT;
    let mut words = words.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, inline)) if flag.starts_with("--") => (flag, Some(inline.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "-h" | "--help" => return Ok(None),
            "--timeout" => {
                let text = match inline {
                    Some(text) => text,
                    None => words
                        .next()
                        .cloned()
                        .ok_or_else(|| UsageError::new("--timeout needs a value"))?,
                };
                timeout = timeout_value(&text)?.min(turn::MAX_TIMEOUT);
            }
            _ if word.starts_with('-') => {
                return Err(UsageError::new(format!("unknown flag {word}")));
            }
            _ if session.is_none() => session = Some(word.clone()),
            _ => return Err(UsageError::new(format!("unexpected argument {word:?}"))),
        }
    }
    let session = session.ok_or_else(|| UsageError::new("name the chat: its SESSION id"))?;
    Ok(Some((session, timeout)))
}

/// `chat read SESSION …` (`agents chat read`) or `chat wait SESSION …` (agents/turn.rs); `last`
/// is the last chat this terminal used (last_chat.rs).
fn read_or_wait(global: &mut GlobalArgs, verb: &str, words: &[String]) -> i32 {
    let mut words = words.to_vec();
    if words.first().map(String::as_str) == Some(super::last_chat::LAST) {
        let Some(last) = super::last_chat::recall() else {
            return super::wire::print_local_error(&super::last_chat::none_yet(), global.output, 1);
        };
        if let Some(vm) = last.vm {
            let error = refusal(
                "chat_target.vm_chat",
                format!(
                    "the last chat ({}) runs on vm:{vm}; chat {verb} reads a chat here",
                    last.session
                ),
                "cmux chat send -w 'TEXT' sends to it and prints the reply",
                json!({"session_id": last.session, "vm": vm}),
            );
            return super::wire::print_local_error(&error, global.output, 1);
        }
        if let Some(first) = words.first_mut() {
            *first = last.session;
        }
    }
    let words = cloud_start_chat::lift_output_of(
        &words,
        &mut global.output,
        &["--timeout", "--after", "--limit"],
    );
    if verb == "read" {
        let mut agents = chat_start::global_words(global);
        agents.extend(["agents", "chat", "read"].map(str::to_owned));
        agents.extend(words);
        return super::agents::run_if_requested(&agents).unwrap_or(2);
    }
    match parse_wait(&words) {
        Ok(Some((session, timeout))) => turn::run(global, &Begin::Wait { session }, timeout),
        Ok(None) => {
            print!("{WAIT_USAGE}");
            0
        }
        Err(error) => super::app::failure(
            "usage.invalid",
            &format!("cmux: {}\n{WAIT_USAGE}", error.0),
            global.output,
            2,
        ),
    }
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
    let mut positional: Vec<String> = Vec::new();
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
            "--wait" | "-w" => send.wait = true,
            "--on" => send.on = Some(take()?),
            "--resume" if !send_verb => set(&mut session, take()?, "the session")?,
            "--prompt" | "-p" => set(&mut text, take()?, "the prompt")?,
            "--timeout" => send.timeout = Some(timeout_value(&take()?)?),
            "--" => {
                let rest: Vec<String> = words.by_ref().cloned().collect();
                for rest in rest {
                    set(&mut text, rest, "the prompt")?;
                }
            }
            _ if word.starts_with('-') && word != "-" => {
                return Err(UsageError::new(format!("unknown flag {word}")));
            }
            _ if send_verb => positional.push(word.clone()),
            _ => set(&mut text, word.clone(), "the prompt")?,
        }
    }
    // `send SESSION TEXT`; `send TEXT` (or `--prompt TEXT`) to the last chat; one word that is a
    // session id is the session, still waiting for its prompt.
    match positional.as_slice() {
        [] => {}
        [one] if text.is_some() || is_session_id(one) || one == super::last_chat::LAST => {
            session = Some(one.clone());
        }
        [one] => set(&mut text, one.clone(), "the prompt")?,
        [first, second] => {
            session = Some(first.clone());
            set(&mut text, second.clone(), "the prompt")?;
        }
        _ => {
            return Err(UsageError::new("give the prompt once (quote a prompt of several words)"));
        }
    }
    if send_verb && session.is_none() {
        session = Some(super::last_chat::LAST.to_owned());
    }
    send.session = session.ok_or_else(|| UsageError::new("name the chat: its SESSION id"))?;
    let text = text.ok_or_else(|| UsageError::new("give the prompt: TEXT, or - for stdin"))?;
    send.text = if text == "-" { chat_start::read_stdin().map_err(UsageError::new)? } else { text };
    if send.text.trim().is_empty() {
        return Err(UsageError::new("the prompt is empty"));
    }
    Ok(Parsed::Run(send))
}

/// `--timeout`'s value: a duration (`30s`, `5m`, `1h`, `1500ms`); a bare number is seconds, as it
/// always was (cmuxterm-hq#8621: one duration form for every `--timeout`). None is refused.
pub(super) fn timeout_value(text: &str) -> Result<Duration, UsageError> {
    super::status::duration(text).ok().filter(|timeout| !timeout.is_zero()).ok_or_else(|| {
        UsageError::new(format!(
            "--timeout takes a duration such as 30s, 5m or 1h (a bare number is seconds), not {text:?}"
        ))
    })
}

/// A Chief's `--timeout`: [`timeout_value`] in whole seconds (rounded up), `0` for none, as before.
pub(in crate::cli) fn timeout_secs(text: &str) -> Result<Option<u64>, String> {
    if text == "0" {
        return Ok(None);
    }
    let timeout = timeout_value(text).map_err(|error| error.0)?;
    Ok(Some(timeout.as_millis().div_ceil(1000).try_into().unwrap_or(u64::MAX)))
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
            let vm = super::vm_words::bare_id(vm);
            return match chat_start::existing_vm(vm, Some(vm), &listed()?) {
                Ok(Machine::Target(id)) => Ok(Place::Vm(id)),
                Ok(_) | Err(_) => Err(refusal(
                    "chat_target.unknown_vm",
                    format!("no one VM of yours has the id or name {vm}"),
                    "run `cmux vm ls` for your VMs",
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
pub(super) fn topology(global: &GlobalArgs) -> Result<Value, Value> {
    let read =
        super::mcp::agent_app(global, "snapshot.get", json!({}), super::app::READ_TIMEOUT, None)?;
    read.get("topology").cloned().ok_or(read)
}

/// `cmux agents chat send SESSION -- TEXT` with the same globals; with `--wait`, the send, the
/// wait for its turn and the reply (agents/turn.rs).
fn here(global: &GlobalArgs, send: &Send) -> i32 {
    if send.wait {
        let timeout = send.timeout.unwrap_or(turn::DEFAULT_TIMEOUT).min(turn::MAX_TIMEOUT);
        let begin = Begin::Send { session: send.session.clone(), text: send.text.clone() };
        return turn::run(global, &begin, timeout);
    }
    if send.timeout.is_some() {
        return usage_failure(
            &UsageError::new("--timeout says how long --wait waits; add --wait"),
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
