//! `cmux chat --on MACHINE` for a machine that joined the person's account (`cmux machine add`,
//! the app's Add Machine) and that only the mesh hub reaches: no ssh, no daemon link. acpmux
//! picks the carrier; this file only names the machine and asks acpmux (Leo, 2026-11-08: "the
//! app [freaking] gets the stuff done").
//!
//! The machine is found by `joined:ID` or by its name, from two lists read only when needed:
//!
//! - the machines acpmux's hub lists for this person (`cmux acp host ls`, rows with
//!   `via: "hub"`, by the mesh host name they heartbeat with). A name there is reachable now;
//! - the account's joined machines (`cmux machine list`'s joined rows, the platform's list),
//!   which name a machine by its id, label or hostname and say when it is offline or revoked.
//!   Read with `CMUX_CLOUD_ACCESS_TOKEN`, else a token the cmux app mints (`cmux auth token`).
//!
//! The start is acpmux's mesh control start (`acpmux session start NAME --machine HOST`), whose
//! receipt is read until the machine answers (the session runs there) or refuses. A first
//! prompt then goes as `acpmux send HOST/NAME`, the hub's send, and so does `cmux chat send
//! HOST/NAME` (chat_send.rs).

use std::io::Write as _;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, Start, UsageError};

/// The prefix that names a joined machine by its account id.
pub(in crate::cli) const PREFIX: &str = "joined:";

/// How long a start waits for the machine to answer: it starts the agent first.
const START_DEADLINE: Duration = Duration::from_secs(120);

/// How often the start's receipt is read while it waits.
const RECEIPT_EVERY: Duration = Duration::from_secs(1);

/// What a refusal says to run next.
const LIST: &str = "run `cmux machine list` for your machines and their ids";

/// A joined machine a chat starts on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct JoinedMachine {
    /// The account's id for it, when the account's list was read.
    pub id: Option<String>,
    /// Its name as `cmux machine list` shows it.
    pub name: String,
    /// The mesh host name the hub reaches it by (`acpmux --machine`).
    pub host: String,
}

/// The two lists, each read at most once and only when the selector needs it.
pub(in crate::cli) struct Sources<H, R> {
    /// acpmux's peers (`acp host ls --json`): the hub's rows are `via: "hub"`.
    pub hub: H,
    /// The account's joined machines, or why they could not be read.
    pub rows: R,
}

/// The joined machine `selector` names, `None` when it names none (and is no `joined:ID`), so
/// the caller keeps its own refusal. `joined:ID` and a name the hub does not list need the
/// account's list; a name the hub lists does not.
pub(in crate::cli) fn resolve<H, R>(
    selector: &str,
    sources: Sources<H, R>,
) -> Option<Result<JoinedMachine, Value>>
where
    H: FnOnce() -> Vec<Value>,
    R: FnOnce() -> Result<Vec<Value>, String>,
{
    let by_id = selector.strip_prefix(PREFIX);
    if by_id == Some("") {
        return Some(Err(refusal(
            "chat_target.unknown_device",
            "joined: needs a machine id".to_owned(),
            LIST,
            json!({}),
        )));
    }
    let hub_hosts: Vec<String> = (sources.hub)()
        .iter()
        .filter(|peer| text(peer, "via") == Some("hub"))
        .filter_map(|peer| text(peer, "name").map(str::to_owned))
        .collect();
    let on_hub = |host: &str| hub_hosts.iter().any(|listed| listed.eq_ignore_ascii_case(host));
    if by_id.is_none() && on_hub(selector) {
        return Some(Ok(JoinedMachine {
            id: None,
            name: selector.to_owned(),
            host: selector.to_owned(),
        }));
    }
    let rows = match (sources.rows)() {
        Ok(rows) => rows,
        // Without the account's list only `joined:ID` is ours to refuse.
        Err(reason) => {
            return by_id.map(|id| {
                Err(refusal(
                    "chat_target.unknown_device",
                    format!("your joined machines could not be read ({reason})"),
                    "sign in to cmux (`cmux login`), or name the machine by the name the hub \
                     lists (`cmux acp host ls`)",
                    json!({"id": id}),
                ))
            });
        }
    };
    let row = match find(by_id.unwrap_or(selector), by_id.is_some(), &rows) {
        Ok(Some(row)) => row,
        Ok(None) => {
            return by_id.map(|id| {
                Err(refusal(
                    "chat_target.unknown_device",
                    format!("no joined machine of yours has the id {id}"),
                    LIST,
                    json!({"id": id}),
                ))
            });
        }
        Err(ids) => {
            return Some(Err(refusal(
                "chat_target.ambiguous_device",
                format!("{} joined machines are named {selector}", ids.len()),
                &format!(
                    "give one: {}",
                    ids.iter().map(|id| format!("{PREFIX}{id}")).collect::<Vec<_>>().join(", ")
                ),
                json!({"name": selector, "ids": ids}),
            )));
        }
    };
    Some(machine(row, &on_hub))
}

/// The row `key` names: by id, or (`by_id` false) by id, name or hostname, a live one first.
/// Err: the ids of several live rows with that name.
fn find<'a>(key: &str, by_id: bool, rows: &'a [Value]) -> Result<Option<&'a Value>, Vec<String>> {
    let joined = || rows.iter().filter(|row| text(row, "kind").is_none_or(|kind| kind == "joined"));
    if let Some(row) = joined().find(|row| text(row, "id") == Some(key)) {
        return Ok(Some(row));
    }
    if by_id {
        return Ok(None);
    }
    let named: Vec<&Value> = joined()
        .filter(|row| text(row, "name") == Some(key) || text(row, "hostname") == Some(key))
        .collect();
    let live: Vec<&Value> =
        named.iter().copied().filter(|row| text(row, "state") != Some("revoked")).collect();
    match (live.as_slice(), named.as_slice()) {
        ([one], _) | ([], [one]) => Ok(Some(*one)),
        ([], []) => Ok(None),
        (several, _) if !several.is_empty() => {
            Err(several.iter().filter_map(|row| text(row, "id").map(str::to_owned)).collect())
        }
        (_, several) => {
            Err(several.iter().filter_map(|row| text(row, "id").map(str::to_owned)).collect())
        }
    }
}

/// `row` as the machine a chat starts on, or why it cannot take one now.
fn machine(row: &Value, on_hub: &dyn Fn(&str) -> bool) -> Result<JoinedMachine, Value> {
    let id = text(row, "id").unwrap_or_default().to_owned();
    let name = text(row, "name").unwrap_or(&id).to_owned();
    // The hub knows it by the host name it heartbeats with; a label is only the list's.
    let host = text(row, "hostname").filter(|host| !host.is_empty()).unwrap_or(&name).to_owned();
    let details = json!({"device": format!("{PREFIX}{id}"), "name": name, "host": host});
    match text(row, "state") {
        Some("revoked") => Err(refusal(
            "chat_target.revoked",
            format!("{name} was revoked and takes no chats"),
            &format!("join it again (`cmux machine add --name {name}`), then run this again"),
            details,
        )),
        // The hub's own list is newer than the account's heartbeat age.
        _ if on_hub(&host) => Ok(JoinedMachine { id: Some(id), name, host }),
        Some("online") => Ok(JoinedMachine { id: Some(id), name, host }),
        state => {
            let mut error = refusal(
                "chat_target.unavailable",
                format!("{name} is {}", state.unwrap_or("offline")),
                &format!(
                    "wake it (or start cmux there), then run this again; `cmux machine doctor {name}` checks it"
                ),
                details,
            );
            if let Some(map) = error.as_object_mut() {
                map.insert("retryable".to_owned(), json!(true));
            }
            Err(error)
        }
    }
}

/// The hub's machines (`acp host ls --json`'s `peers`); none when acpmux does not answer.
pub(in crate::cli) fn hub_peers() -> Vec<Value> {
    acp_json(&["host", "ls", "--json"], None)
        .ok()
        .and_then(|listed| listed.get("peers").and_then(Value::as_array).cloned())
        .unwrap_or_default()
}

/// The account's joined machines: with `CMUX_CLOUD_ACCESS_TOKEN`, else a token the app mints.
pub(in crate::cli) fn account_rows(global: &GlobalArgs) -> Result<Vec<Value>, String> {
    let credential = match crate::cli::joined_machine_credential(None, false)? {
        Some(credential) => credential,
        None => app_token(global)?,
    };
    crate::cli::joined_machine_rows(None, Some(credential))
        .unwrap_or_else(|| Err("not signed in".to_owned()))
}

/// A short-lived token from the cmux app's sign-in (`auth.token`, as `cmux auth token`).
fn app_token(global: &GlobalArgs) -> Result<String, String> {
    const TIMEOUT: Duration = Duration::from_secs(30);
    let mut stream = super::super::app::connect_command(global)
        .map_err(|_| "not signed in: no CMUX_CLOUD_ACCESS_TOKEN and no cmux app".to_owned())?;
    let params = Value::Object(super::super::auth_token::request(None));
    let answer = super::super::app::request(&mut stream, "auth.token", params, TIMEOUT)?.map_err(
        |error| error.get("message").and_then(Value::as_str).unwrap_or("not signed in").to_owned(),
    )?;
    super::super::auth_token::token_line(&answer)
        .map(|line| line.trim().to_owned())
        .ok_or_else(|| "the cmux app gave no token".to_owned())
}

/// The chat's name on the machine: `--name`, else a few words of the prompt, with four letters
/// so a second chat with the same prompt gets its own.
pub(in crate::cli) fn chat_name(start: &Start, letters: &str) -> String {
    if let Some(name) = &start.name {
        return name.clone();
    }
    let words: Vec<String> = start
        .prompt
        .as_deref()
        .filter(|prompt| *prompt != "-")
        .unwrap_or("chat")
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .take(4)
        .map(str::to_ascii_lowercase)
        .collect();
    let mut stem = words.join("-");
    stem.truncate(40);
    let stem = stem.trim_end_matches('-');
    let stem = if stem.is_empty() { "chat" } else { stem };
    format!("{stem}-{letters}")
}

/// Four random lowercase letters (no digits, so the name never reads as a counter or an id).
fn letters() -> String {
    let mut bytes = [0u8; 4];
    let _ = getrandom::fill(&mut bytes);
    bytes.iter().map(|byte| char::from(b'a' + byte % 26)).collect()
}

/// `acp session start …`'s words for this start on `machine`.
pub(in crate::cli) fn start_words(
    start: &Start,
    machine: &JoinedMachine,
    name: &str,
) -> Result<Vec<String>, UsageError> {
    if start.wait || start.timeout.is_some() {
        return Err(UsageError::new(
            "--wait and --timeout wait for a Cloud chat; a joined machine's reply is `cmux acp last HOST/NAME`",
        ));
    }
    let mut words: Vec<String> =
        ["session", "start", name, "--machine", &machine.host].map(str::to_owned).to_vec();
    let harness = match (&start.agent, &start.model) {
        (Some(agent), Some(model)) => Some(format!("{agent}/{model}")),
        (Some(agent), None) => Some(agent.clone()),
        (None, Some(model)) => Some(format!("claude/{model}")),
        (None, None) => None,
    };
    if let Some(harness) = harness {
        words.extend(["-m".to_owned(), harness]);
    }
    if let Some(cwd) = &start.cwd {
        words.extend(["--cwd".to_owned(), cwd.clone()]);
    }
    words.push("--json".to_owned());
    Ok(words)
}

/// The start's receipt state: still on its way, run there, or refused.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) enum Settled {
    Pending,
    Started,
    Refused(String),
}

pub(in crate::cli) fn settled(receipt: &Value) -> Settled {
    let detail = || text(receipt, "detail").unwrap_or("no detail").to_owned();
    match text(receipt, "state") {
        Some("delivered") => Settled::Started,
        Some(state @ ("refused" | "expired")) => Settled::Refused(format!("{state}: {}", detail())),
        _ => Settled::Pending,
    }
}

/// Starts the chat on `machine` and sends its first prompt; prints the answer.
pub(in crate::cli) fn run(global: &GlobalArgs, start: &Start, machine: &JoinedMachine) -> i32 {
    let name = chat_name(start, &letters());
    let words = match start_words(start, machine, &name) {
        Ok(words) => words,
        Err(error) => return super::usage_failure(&error, global.output),
    };
    let prompt = match start.prompt.as_deref() {
        Some("-") => match super::read_stdin() {
            Ok(text) => Some(text),
            Err(error) => return super::usage_failure(&UsageError::new(error), global.output),
        },
        other => other.map(str::to_owned),
    };
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let enqueued = match acp_json(&words, None) {
        Ok(receipt) => receipt,
        Err(error) => return fail(global, error),
    };
    let receipt = match wait_started(&enqueued) {
        Ok(receipt) => receipt,
        Err(error) => return fail(global, error),
    };
    let target = format!("{}/{name}", machine.host);
    let sent = match prompt.filter(|prompt| !prompt.trim().is_empty()) {
        Some(prompt) => match send(&target, &prompt) {
            Ok(sent) => Some(sent),
            Err(error) => return fail(global, error),
        },
        None => None,
    };
    let answer = json!({
        "session_id": target,
        "machine": {"id": machine.id, "name": machine.name, "host": machine.host},
        "placement": machine.id.as_ref().map_or_else(|| format!("hub:{}", machine.host), |id| format!("{PREFIX}{id}")),
        "remote_session_id": text(&receipt, "detail"),
        "start": receipt,
        "prompt": sent,
        "next": {
            "send": format!("cmux chat send {target} 'TEXT'"),
            "read": format!("cmux acp last {target}"),
        },
    });
    match global.output {
        OutputMode::Human => {
            let mut out = std::io::stdout().lock();
            let _ = writeln!(out, "{target} started on {}", machine.name);
            let _ = writeln!(out, "send: cmux chat send {target} 'TEXT'");
            let _ = writeln!(out, "read: cmux acp last {target}");
            0
        }
        OutputMode::Quiet => 0,
        _ => super::super::wire::print_local_success(&answer, global.output),
    }
}

/// The start's receipt once the machine answered: the session runs there. Read every
/// [`RECEIPT_EVERY`] until [`START_DEADLINE`].
fn wait_started(enqueued: &Value) -> Result<Value, Value> {
    let Some(id) = text(enqueued, "messageId").map(str::to_owned) else {
        return Err(error("acpmux.invalid_response", "acpmux's start answered no receipt", false));
    };
    let deadline = Instant::now() + START_DEADLINE;
    let mut receipt = enqueued.clone();
    loop {
        match settled(&receipt) {
            Settled::Started => return Ok(receipt),
            Settled::Refused(why) => {
                return Err(error(
                    "chat_target.refused",
                    &format!("the machine refused the chat ({why})"),
                    false,
                ));
            }
            Settled::Pending if Instant::now() >= deadline => {
                return Err(error(
                    "chat_target.unavailable",
                    &format!(
                        "the machine has not taken the chat after {}s; `cmux acp session receipt {id}` says when it does",
                        START_DEADLINE.as_secs()
                    ),
                    true,
                ));
            }
            Settled::Pending => std::thread::sleep(RECEIPT_EVERY),
        }
        receipt = acp_json(&["session", "receipt", &id, "--json"], None)?;
    }
}

/// `acp send TARGET -` with the prompt on stdin, through the hub when only the hub reaches it.
/// `--wait` keeps it a person's send (an agent's defaults to `--no-wait`, which the hub's send
/// path does not take); the hub's send answers with its receipt, not the reply.
pub(in crate::cli) fn send(target: &str, prompt: &str) -> Result<Value, Value> {
    acp_json(&["send", target, "-", "--wait", "--json"], Some(prompt))
}

/// Prints `error` and gives the exit code.
pub(in crate::cli) fn fail(global: &GlobalArgs, error: Value) -> i32 {
    super::super::wire::print_local_error(&error, global.output, 1)
}

/// `cmux acp WORDS` (this binary's acpmux), its stdout's last JSON line, or the failure.
fn acp_json(words: &[&str], stdin: Option<&str>) -> Result<Value, Value> {
    let exe = std::env::current_exe()
        .map_err(|e| error("acpmux.unreachable", &format!("cannot find cmux: {e}"), true))?;
    let mut command = Command::new(exe);
    #[cfg(unix)]
    std::os::unix::process::CommandExt::arg0(&mut command, "cmux");
    command
        .arg("acp")
        .args(words)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| error("acpmux.unreachable", &format!("cannot run cmux acp: {e}"), true))?;
    if let (Some(text), Some(mut pipe)) = (stdin, child.stdin.take()) {
        let _ = pipe.write_all(text.as_bytes());
    }
    let out = child
        .wait_with_output()
        .map_err(|e| error("acpmux.unreachable", &format!("cmux acp did not finish: {e}"), true))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let parsed =
        stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_owned();
        let message = if stderr.is_empty() { stdout.trim().to_owned() } else { stderr };
        let mut failure =
            error("acpmux.failed", &format!("cmux acp {}: {message}", words.join(" ")), false);
        if let (Some(map), Some(parsed)) = (failure.as_object_mut(), parsed) {
            map.insert("details".to_owned(), json!({"answer": parsed}));
        }
        return Err(failure);
    }
    // A whole pretty-printed answer, else its last line.
    serde_json::from_str::<Value>(stdout.trim()).ok().or(parsed).ok_or_else(|| {
        error(
            "acpmux.invalid_response",
            &format!("cmux acp {} printed no JSON", words.join(" ")),
            false,
        )
    })
}

fn error(code: &str, message: &str, retryable: bool) -> Value {
    json!({"code": code, "message": message, "details": {}, "retryable": retryable})
}

/// A refusal whose message and `details.next` say what to run next.
fn refusal(code: &str, message: String, next: &str, mut details: Value) -> Value {
    if let Some(map) = details.as_object_mut() {
        map.insert("next".to_owned(), json!(next));
    }
    json!({"code": code, "message": format!("{message}; {next}"), "details": details,
           "retryable": false})
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}
