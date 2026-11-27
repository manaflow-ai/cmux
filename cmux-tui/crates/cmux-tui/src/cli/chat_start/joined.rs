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
//! prompt then goes as `acpmux send HOST/NAME --no-wait`, the hub's send, and so does `cmux chat
//! send HOST/NAME` (chat_send.rs), after the same account check ([`resolve`]). The start, its
//! receipt and the first prompt share one deadline ([`START_DEADLINE`]).

use std::io::Write as _;
use std::time::{Duration, Instant};

use cmux_json::JsonGet as _;
use cmux_process::{Command, Stdio};
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, Start, UsageError};

/// The prefix that names a joined machine by its account id.
pub(in crate::cli) const PREFIX: &str = "joined:";

/// How long a start waits for the machine to answer: it starts the agent first.
const START_DEADLINE: Duration = Duration::from_secs(120);

/// How often the start's receipt is read while it waits.
const RECEIPT_POLL: Duration = Duration::from_secs(1);

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
/// the caller keeps its own refusal. The account's list is read first and decides: a revoked
/// row is refused even while the hub still lists the machine (revocation reaches the hub
/// later). The hub's list only says a machine is up; when the account's list cannot be read, a
/// machine the hub lists is refused as unverified (`chat_target.unverified`). This check is the
/// client's and only advisory: the hub has to refuse a revoked machine itself. A name matches
/// without regard to case, and the machine carries its own spelling on (`--on STUDIO` starts on
/// `studio`).
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
        .filter(|peer| peer.get_str("via") == Some("hub"))
        .filter_map(|peer| peer.get_str("name").map(str::to_owned))
        .collect();
    let listed = |host: &str| hub_hosts.iter().find(|listed| listed.eq_ignore_ascii_case(host));
    let on_hub = |host: &str| listed(host).is_some();
    let rows = match (sources.rows)() {
        Ok(rows) => rows,
        // Without the account's list nothing says the machine is still the person's: a name the
        // hub lists is refused (the hub may still list a revoked machine, #38355 review), not
        // started on; else only `joined:ID` is ours to refuse.
        Err(reason) => {
            if let Some(host) = listed(selector).filter(|_| by_id.is_none()) {
                return Some(Err(refusal(
                    "chat_target.unverified",
                    format!(
                        "{host} could not be verified against your account: your joined machines could not be read ({reason})"
                    ),
                    "sign in to cmux (`cmux login`), then run this again; `cmux machine list` shows your machines",
                    json!({"host": host}),
                )));
            }
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
    Some(machine(row, &on_hub).map(|mut found| {
        // The host as the hub spells it, when the hub lists it in another case.
        if let Some(host) = listed(&found.host) {
            found.host.clone_from(host);
        }
        found
    }))
}

/// The row `key` names: by id, or (`by_id` false) by id, name or hostname, a live one first;
/// a name spelled as the row spells it first, then one that differs only in case.
/// Err: the ids of several live rows with that name.
fn find<'a>(key: &str, by_id: bool, rows: &'a [Value]) -> Result<Option<&'a Value>, Vec<String>> {
    let joined =
        || rows.iter().filter(|row| row.get_str("kind").is_none_or(|kind| kind == "joined"));
    if let Some(row) = joined().find(|row| row.get_str("id") == Some(key)) {
        return Ok(Some(row));
    }
    if by_id {
        return Ok(None);
    }
    let names = |row: &Value, same: &dyn Fn(&str) -> bool| {
        row.get_str("name").is_some_and(same) || row.get_str("hostname").is_some_and(same)
    };
    let mut named: Vec<&Value> = joined().filter(|row| names(row, &|name| name == key)).collect();
    if named.is_empty() {
        named = joined().filter(|row| names(row, &|name| name.eq_ignore_ascii_case(key))).collect();
    }
    let live: Vec<&Value> =
        named.iter().copied().filter(|row| row.get_str("state") != Some("revoked")).collect();
    match (live.as_slice(), named.as_slice()) {
        ([one], _) | ([], [one]) => Ok(Some(*one)),
        ([], []) => Ok(None),
        (several, _) if !several.is_empty() => {
            Err(several.iter().filter_map(|row| row.get_str("id").map(str::to_owned)).collect())
        }
        (_, several) => {
            Err(several.iter().filter_map(|row| row.get_str("id").map(str::to_owned)).collect())
        }
    }
}

/// `row` as the machine a chat starts on, or why it cannot take one now.
fn machine(row: &Value, on_hub: &dyn Fn(&str) -> bool) -> Result<JoinedMachine, Value> {
    let id = row.get_str("id").unwrap_or_default().to_owned();
    let name = row.get_str("name").unwrap_or(&id).to_owned();
    // The hub knows it by the host name it heartbeats with; a label is only the list's.
    let host = row.get_str("hostname").filter(|host| !host.is_empty()).unwrap_or(&name).to_owned();
    let details = json!({"device": format!("{PREFIX}{id}"), "name": name, "host": host});
    match row.get_str("state") {
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
    acp_json(&["host", "ls", "--json"], None, START_DEADLINE)
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
            "--wait and --timeout wait for a chat here or in Cloud; a joined machine's reply is `cmux acp last HOST/NAME`",
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
    let detail = || receipt.get_str("detail").unwrap_or("no detail").to_owned();
    match receipt.get_str("state") {
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
    let target = format!("{}/{name}", machine.host);
    let prompt = prompt.filter(|prompt| !prompt.trim().is_empty());
    let started = start_chat(
        &Steps { words: &words, target: &target, prompt: prompt.as_deref() },
        START_DEADLINE,
        RECEIPT_POLL,
        acp_json,
    );
    let (receipt, sent) = match started {
        Ok(started) => started,
        Err(error) => return fail(global, error),
    };
    // `cmux chat send TEXT` (no SESSION) goes on with this chat, as after a start here.
    super::super::last_chat::remember(&target, None);
    let answer = json!({
        "session_id": target,
        "machine": {"id": machine.id, "name": machine.name, "host": machine.host},
        "placement": machine.id.as_ref().map_or_else(|| format!("hub:{}", machine.host), |id| format!("{PREFIX}{id}")),
        "remote_session_id": receipt.get_str("detail"),
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

/// What a start runs: `acp session start …`'s words, the chat it names (`HOST/NAME`) and its
/// first prompt.
pub(in crate::cli) struct Steps<'a> {
    pub words: &'a [&'a str],
    pub target: &'a str,
    pub prompt: Option<&'a str>,
}

/// Runs `steps` through `acp` (`cmux acp WORDS` with a stdin, for at most a limit: [`acp_json`]
/// in production): the start, its receipt read every `poll` until the machine takes the chat,
/// then the first prompt. One deadline, `limit` from now, bounds them all: each call gets only
/// what is left of it, so the start ends by `limit` however slow each call is (#38355 review:
/// three calls of 120 s each could take 360 s under an error that said 120 s). Answers the
/// start's receipt and the prompt's.
pub(in crate::cli) fn start_chat<A>(
    steps: &Steps<'_>,
    limit: Duration,
    poll: Duration,
    mut acp: A,
) -> Result<(Value, Option<Value>), Value>
where
    A: FnMut(&[&str], Option<&str>, Duration) -> Result<Value, Value>,
{
    let deadline = Instant::now() + limit;
    let mut call = |words: &[&str], stdin: Option<&str>| match deadline
        .checked_duration_since(Instant::now())
        .filter(|left| !left.is_zero())
    {
        Some(left) => acp(words, stdin, left),
        None => Err(error("acpmux.timeout", "the start's deadline passed", true)),
    };
    let enqueued = call(steps.words, None).map_err(|e| late(e, || not_taken(limit, None)))?;
    let receipt = wait_started(&enqueued, deadline, limit, poll, &mut call)?;
    let Some(prompt) = steps.prompt else { return Ok((receipt, None)) };
    let id = prompt_id();
    let words = send_words(steps.target, &id);
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let sent = call(&words, Some(prompt)).map_err(|e| {
        let what = format!("{} started, but its first prompt", steps.target);
        late(e, || unconfirmed(&what, steps.target, &id, limit))
    })?;
    Ok((receipt, Some(sent)))
}

/// The start's receipt once the machine answered: the session runs there. Read every `poll`
/// until `deadline`.
fn wait_started<C>(
    enqueued: &Value,
    deadline: Instant,
    limit: Duration,
    poll: Duration,
    call: &mut C,
) -> Result<Value, Value>
where
    C: FnMut(&[&str], Option<&str>) -> Result<Value, Value>,
{
    let Some(id) = enqueued.get_str("messageId").map(str::to_owned) else {
        return Err(error("acpmux.invalid_response", "acpmux's start answered no receipt", false));
    };
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
            Settled::Pending => {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err(not_taken(limit, Some(&id)));
                }
                std::thread::sleep(poll.min(left));
            }
        }
        receipt = call(&["session", "receipt", &id, "--json"], None)
            .map_err(|e| late(e, || not_taken(limit, Some(&id))))?;
    }
}

/// `error`, or `instead` when it is a call that ran out of time.
fn late(error: Value, instead: impl FnOnce() -> Value) -> Value {
    if error.get_str("code") == Some("acpmux.timeout") { instead() } else { error }
}

/// The machine did not take the chat by the deadline (it may still: `id` is its receipt).
fn not_taken(limit: Duration, id: Option<&str>) -> Value {
    let receipt = id
        .map(|id| format!("; `cmux acp session receipt {id}` says when it does"))
        .unwrap_or_default();
    error(
        "chat_target.unavailable",
        &format!("the machine has not taken the chat after {}s{receipt}", limit.as_secs()),
        true,
    )
}

/// `what` (a prompt to `target`) was not confirmed within `limit`. It may have been delivered,
/// so it is not retryable: a retry would send it twice (#38355 review).
fn unconfirmed(what: &str, target: &str, prompt_id: &str, limit: Duration) -> Value {
    let next = format!(
        "do not send it again: `cmux acp last {target}` shows whether it arrived, `cmux acp send --status` lists its delivery"
    );
    let mut failure = error(
        "acpmux.timeout",
        &format!(
            "{what} was not confirmed within {}s and may still arrive; {next}",
            limit.as_secs()
        ),
        false,
    );
    if let Some(map) = failure.as_object_mut() {
        map.insert(
            "details".to_owned(),
            json!({"session_id": target, "prompt_id": prompt_id, "next": next}),
        );
    }
    failure
}

/// A prompt id for one send (`acpmux send --prompt-id`): acpmux and the hub deliver an id once,
/// so a send acpmux tries again is never a second prompt.
fn prompt_id() -> String {
    format!("cmux-chat-{}", uuid::Uuid::new_v4().simple())
}

/// `acp send TARGET -`'s words, the prompt on stdin, through the hub when only the hub reaches
/// it. `--no-wait`: acpmux answers once the prompt is queued, with its delivery receipt, never
/// after the turn (a peer link's `--wait` waits for the agent's whole turn, and an agent's
/// `--wait` asks a question the hub's send refuses). `--no-steer`: it queues behind a running
/// turn, as a person's send does.
pub(in crate::cli) fn send_words(target: &str, prompt_id: &str) -> Vec<String> {
    ["send", target, "-", "--no-wait", "--no-steer", "--prompt-id", prompt_id, "--json"]
        .map(str::to_owned)
        .to_vec()
}

/// `acp send TARGET -` with the prompt ([`send_words`]); the answer is acpmux's delivery
/// receipt, not the reply.
pub(in crate::cli) fn send(target: &str, prompt: &str) -> Result<Value, Value> {
    let id = prompt_id();
    let words = send_words(target, &id);
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    acp_json(&words, Some(prompt), START_DEADLINE).map_err(|e| {
        late(e, || unconfirmed(&format!("the prompt to {target}"), target, &id, START_DEADLINE))
    })
}

/// Prints `error` and gives the exit code.
pub(in crate::cli) fn fail(global: &GlobalArgs, error: Value) -> i32 {
    super::super::wire::print_local_error(&error, global.output, 1)
}

/// `cmux acp WORDS` (this binary's acpmux) for at most `limit`: its stdout's last JSON line, or
/// the failure.
fn acp_json(words: &[&str], stdin: Option<&str>, limit: Duration) -> Result<Value, Value> {
    let exe = std::env::current_exe()
        .map_err(|e| error("acpmux.unreachable", &format!("cannot find cmux: {e}"), true))?;
    let mut command = Command::new(exe);
    command.arg0("cmux");
    run_acp(acp_command(command, words), words, stdin, limit)
}

/// `command` (this binary, in production) as `… acp WORDS`, with no cmux credential in its
/// environment: an acpmux daemon `cmux acp` auto-starts, and the harnesses it runs, would keep
/// them for their lifetime ([`crate::devices::CREDENTIAL_ENV`], the list every `cmux` child
/// is started without).
pub(in crate::cli) fn acp_command(mut command: Command, words: &[&str]) -> Command {
    command.arg("acp").args(words);
    for name in crate::devices::CREDENTIAL_ENV {
        command.env_remove(name);
    }
    command
}

/// Runs `command` (`cmux acp WORDS`), with `stdin` on its stdin, for at most `limit`: its
/// stdout's JSON answer, or the failure. A child still running at `limit` is ended with its
/// process group (dropping its `Child` sends SIGTERM, then SIGKILL) and the answer is
/// `acpmux.timeout`.
pub(in crate::cli) fn run_acp(
    mut command: Command,
    words: &[&str],
    stdin: Option<&str>,
    limit: Duration,
) -> Result<Value, Value> {
    // Its own process group: at the limit the group is ended, with anything it started that
    // still holds its pipes.
    command
        .process_group(0)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| error("acpmux.unreachable", &format!("cannot run cmux acp: {e}"), true))?;
    let stdin_pipe = child.stdin.take();
    // The prompt is written and both pipes are read on threads this scope owns, so the wait is
    // the only thing bounded: a child that never reads its stdin cannot hold a prompt larger
    // than a pipe (about 64 KiB) past the limit (#38355 review), and a full pipe never stalls
    // the child. At the limit the child's whole group is ended (it leads one), its pipes close
    // and the writer and the readers end with it.
    let finished = std::thread::scope(|scope| {
        let writer = stdin.zip(stdin_pipe).map(|(text, mut pipe)| {
            scope.spawn(move || {
                // Its end closes when the thread does: the child reads to the end of the prompt.
                let _ = pipe.write_all(text.as_bytes());
            })
        });
        let read = |pipe: Option<Box<dyn std::io::Read + Send>>| {
            scope.spawn(move || {
                let mut bytes = Vec::new();
                if let Some(mut pipe) = pipe {
                    let _ = std::io::Read::read_to_end(&mut pipe, &mut bytes);
                }
                bytes
            })
        };
        let stdout = read(child.stdout.take().map(|pipe| Box::new(pipe) as _));
        let stderr = read(child.stderr.take().map(|pipe| Box::new(pipe) as _));
        let status = child.wait_timeout(limit);
        if !matches!(status, Ok(Some(_))) {
            drop(child);
        }
        if let Some(writer) = writer {
            let _ = writer.join();
        }
        (status, stdout.join().unwrap_or_default(), stderr.join().unwrap_or_default())
    });
    let (out_bytes, err_bytes) = match finished {
        (Ok(Some(status)), out, err) if status.success() => (out, Ok(err)),
        (Ok(Some(_)), out, err) => (out, Err(err)),
        (Ok(None), _, _) => {
            return Err(error(
                "acpmux.timeout",
                &format!(
                    "cmux acp {} did not answer within {}s; `cmux acp host ls` shows whether acpmux and the hub answer",
                    words.join(" "),
                    limit.as_secs()
                ),
                true,
            ));
        }
        (Err(e), _, _) => {
            return Err(error(
                "acpmux.unreachable",
                &format!("cmux acp did not finish: {e}"),
                true,
            ));
        }
    };
    let stdout = String::from_utf8_lossy(&out_bytes);
    let parsed =
        stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok());
    if let Err(err_bytes) = err_bytes {
        let stderr = String::from_utf8_lossy(&err_bytes).trim().to_owned();
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
