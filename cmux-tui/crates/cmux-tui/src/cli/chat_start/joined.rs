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
//! A machine acpmux reaches itself (`acpmux machine add HOST`: an ssh or direct peer, a row of
//! `cmux acp host ls` with no `via: "hub"`) is a target too, by its acpmux name, with no account
//! check: the person's own acpmux reaches it, as `acpmux new --machine HOST` would (hq#11835:
//! `cmux chat --on gcp-agent-lane-3` was refused while `acpmux ls` listed sessions there).
//!
//! The start on a joined machine is acpmux's mesh control start (`acpmux session start NAME
//! --machine HOST`), whose receipt is read until the machine answers (the session runs there)
//! or refuses; on a peer it is `acpmux new --machine HOST -n NAME -d`, which answers once the
//! session runs there. A first prompt then goes as `acpmux send HOST/NAME --no-wait`, and so
//! does `cmux chat send HOST/NAME` (chat_send.rs), after the same check ([`resolve`]). The start,
//! its receipt and the first prompt share one deadline ([`START_DEADLINE`]). `--wait` then waits
//! for the turn with `acpmux wait HOST/NAME` and prints its reply ([`wait_turn`]), as a chat here
//! or in Cloud does.

use std::io::Write as _;
use std::time::{Duration, Instant};

use cmux_json::{JsonGet as _, JsonSet as _};
use cmux_process::{Command, Stdio};
use serde_json::{Value, json};

use super::super::agents::turn::Outcome;
use super::{GlobalArgs, OutputMode, Start, UsageError};

/// The prefix that names a joined machine by its account id.
pub(in crate::cli) const PREFIX: &str = "joined:";

/// How long a start waits for the machine to answer: it starts the agent first.
const START_DEADLINE: Duration = Duration::from_secs(120);

/// How often the start's receipt is read while it waits.
const RECEIPT_POLL: Duration = Duration::from_secs(1);

/// What a refusal says to run next.
const LIST: &str = "run `cmux machine list` for your machines and their ids";

/// How acpmux reaches a machine a chat starts on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) enum Carrier {
    /// Only the mesh hub: a machine joined to the account (`cmux machine add`).
    #[default]
    Hub,
    /// acpmux's own link to it (`acpmux machine add HOST`: ssh or direct).
    Peer,
}

/// A joined machine, or one of acpmux's peers, a chat starts on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct JoinedMachine {
    /// The account's id for it, when the account's list was read (None for a peer).
    pub id: Option<String>,
    /// Its name as `cmux machine list` shows it.
    pub name: String,
    /// The host name acpmux reaches it by (`acpmux --machine`, `HOST/NAME`).
    pub host: String,
    pub carrier: Carrier,
}

impl JoinedMachine {
    /// The answer's `placement`: `joined:ID`, `peer:HOST`, or `hub:HOST` with no id.
    pub(in crate::cli) fn placement(&self) -> String {
        match (self.carrier, &self.id) {
            (Carrier::Peer, _) => format!("peer:{}", self.host),
            (Carrier::Hub, Some(id)) => format!("{PREFIX}{id}"),
            (Carrier::Hub, None) => format!("hub:{}", self.host),
        }
    }
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
    let peers = (sources.hub)();
    // A machine acpmux reaches itself needs no account: the person's acpmux added it.
    if by_id.is_none()
        && let Some(found) = direct_peer(selector, &peers)
    {
        return Some(found);
    }
    let hub_hosts: Vec<String> = peers
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

/// The peer acpmux reaches itself (a `host ls` row with no `via: "hub"`) named `selector`,
/// matched without regard to case and carried on in acpmux's own spelling. A peer acpmux lists
/// but cannot reach now is refused as retryable, with the command that says why.
fn direct_peer(selector: &str, peers: &[Value]) -> Option<Result<JoinedMachine, Value>> {
    let peer = peers.iter().find(|peer| {
        peer.get_str("via") != Some("hub")
            && peer.get_str("name").is_some_and(|name| name.eq_ignore_ascii_case(selector))
    })?;
    let host = peer.get_str("name").unwrap_or(selector).to_owned();
    if peer.get("connected").and_then(Value::as_bool) == Some(true) {
        return Some(Ok(JoinedMachine {
            id: None,
            name: host.clone(),
            host,
            carrier: Carrier::Peer,
        }));
    }
    let why = peer.get_str("error").filter(|error| !error.is_empty());
    let mut error = refusal(
        "chat_target.unavailable",
        format!(
            "acpmux cannot reach {host} now{}",
            why.map(|why| format!(" ({why})")).unwrap_or_default()
        ),
        &format!("`cmux acp machine status {host}` says why; run this again once it connects"),
        json!({"host": host}),
    );
    if let Some(map) = error.as_object_mut() {
        map.insert("retryable".to_owned(), json!(true));
    }
    Some(Err(error))
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
        _ if on_hub(&host) => Ok(JoinedMachine { id: Some(id), name, host, carrier: Carrier::Hub }),
        Some("online") => Ok(JoinedMachine { id: Some(id), name, host, carrier: Carrier::Hub }),
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

/// acpmux's machines (`acp host ls --json`'s `peers`: its own peers and the hub's); none when
/// acpmux does not answer.
pub(in crate::cli) fn hub_peers() -> Vec<Value> {
    peers_within(START_DEADLINE).unwrap_or_default()
}

/// [`hub_peers`] read for at most `limit`, or why acpmux did not answer.
pub(in crate::cli) fn peers_within(limit: Duration) -> Result<Vec<Value>, String> {
    let listed = acp_json(&["host", "ls", "--json"], None, limit)
        .map_err(|error| error.get_str("message").unwrap_or("acpmux did not answer").to_owned())?;
    Ok(listed.get("peers").and_then(Value::as_array).cloned().unwrap_or_default())
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

/// A short-lived token from the cmux app's sign-in (`auth.token`, as `cmux auth token`); also
/// `automation create --webhook --on cloud`.
pub(in crate::cli) fn app_token(global: &GlobalArgs) -> Result<String, String> {
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

/// `acp session start …`'s words for this start on a joined machine, `acp new --machine …`'s on
/// a peer. A bad `--wait`/`--timeout` is refused here, before anything starts.
pub(in crate::cli) fn start_words(
    start: &Start,
    machine: &JoinedMachine,
    name: &str,
) -> Result<Vec<String>, UsageError> {
    super::here_wait(start)?;
    let mut words: Vec<String> = match machine.carrier {
        Carrier::Hub => {
            ["session", "start", name, "--machine", &machine.host].map(str::to_owned).to_vec()
        }
        Carrier::Peer => {
            ["new", "--machine", &machine.host, "-n", name, "-d"].map(str::to_owned).to_vec()
        }
    };
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
    let receipt = machine.carrier == Carrier::Hub;
    let started = start_chat(
        &Steps { words: &words, target: &target, prompt: prompt.as_deref(), receipt },
        START_DEADLINE,
        RECEIPT_POLL,
        acp_json,
    );
    let (started, sent) = match started {
        Ok(started) => started,
        Err(error) => return fail(global, error),
    };
    // `cmux chat send TEXT` (no SESSION) goes on with this chat, as after a start here.
    super::super::last_chat::remember(&target, None);
    let answer = start_answer(machine, &target, started, sent);
    // `--wait`: the turn the first prompt started, its reply printed as a chat here prints it.
    if let Ok(Some(timeout)) = super::here_wait(start)
        && answer.get("prompt").is_some_and(|sent| !sent.is_null())
    {
        let outcome = wait_turn(&target, Some(0), timeout, acp_json);
        return super::super::agents::turn::report(&with_answer(outcome, answer), global.output);
    }
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

/// The start's answer: the chat (`HOST/NAME`), its machine and placement, the start's receipt
/// (a peer's: only the id and name of the session record `acp new` answers) and the prompt's.
pub(in crate::cli) fn start_answer(
    machine: &JoinedMachine,
    target: &str,
    started: Value,
    sent: Option<Value>,
) -> Value {
    let (remote_session_id, started) = match machine.carrier {
        Carrier::Hub => (started.get_str("detail").map(str::to_owned), started),
        Carrier::Peer => {
            let id = started.get_str("sessionId").map(str::to_owned);
            let name = started.get_str("name").map(str::to_owned);
            (id.clone(), json!({"sessionId": id, "name": name}))
        }
    };
    json!({
        "session_id": target,
        "machine": {"id": machine.id, "name": machine.name, "host": machine.host},
        "placement": machine.placement(),
        "remote_session_id": remote_session_id,
        "start": started,
        "prompt": sent,
        "next": {
            "send": format!("cmux chat send {target} 'TEXT'"),
            "wait": format!("cmux chat wait {target}"),
            "read": format!("cmux acp last {target}"),
        },
    })
}

/// `outcome` (a [`wait_turn`]) with `answer`'s fields under its own: the start's or the send's
/// ids stay in the answer `--wait` prints, as they do for a chat here.
pub(in crate::cli) fn with_answer(outcome: Outcome, answer: Value) -> Outcome {
    let merge = |turn: &mut Value| {
        if let (Some(turn), Value::Object(answer)) = (turn.as_object_mut(), &answer) {
            for (key, value) in answer {
                turn.entry(key.clone()).or_insert_with(|| value.clone());
            }
        }
    };
    match outcome {
        Outcome::Done(mut turn) => {
            merge(&mut turn);
            Outcome::Done(turn)
        }
        Outcome::Failed { mut error, exit } => {
            if let Some(turn) = error.pointer_mut("/details/answer") {
                merge(turn);
            }
            Outcome::Failed { error, exit }
        }
    }
}

/// How long one `acp wait` call may run past the wait it asks for (acpmux answering).
const WAIT_SLACK: Duration = Duration::from_secs(30);

/// How long a wait that came back before the prompt's turn began pauses before it waits again.
// timeout: not a timeout: the pause between two `acp wait` calls; the caller's own `timeout` bounds the wait.
const NOT_STARTED_PAUSE: Duration = Duration::from_millis(500);

/// Waits at most `timeout` for chat `target`'s (`HOST/NAME`) turn to end through acpmux (`acp
/// wait`), and answers its reply as `cmux chat --wait` does here (agents/turn.rs): exit 2 when
/// the agent waits on a permission, 3 (`chat.wait_timeout`) when the turn still runs.
///
/// `baseline`: the chat's turn count before the prompt went (`Some(0)` for a new chat). A send
/// queued on another machine may not have begun its turn when the wait first reads the chat,
/// which is still idle from the turn before; the wait is over only once the chat ran more turns
/// than `baseline` and is idle again (`acp session info`'s `turnCount` and `status`). None (`chat
/// wait`): the turn running now, or the last one.
pub(in crate::cli) fn wait_turn<A>(
    target: &str,
    baseline: Option<u64>,
    timeout: Duration,
    mut acp: A,
) -> Outcome
where
    A: FnMut(&[&str], Option<&str>, Duration) -> Result<Value, Value>,
{
    let deadline = Instant::now() + timeout;
    let answer = json!({"session_id": target, "follow_up": {
        "send": format!("cmux chat send {target} 'PROMPT' --wait"),
        "wait": format!("cmux chat wait {target}"),
        "read": format!("cmux acp last {target}"),
    }});
    let failed = |code: &str, message: String, mut answer: Value, exit: i32| {
        if code == "chat.wait_timeout" {
            answer.set("timed_out", json!(true));
        }
        Outcome::Failed {
            error: json!({"code": code, "message": message, "details": {"answer": answer},
                          "retryable": false}),
            exit,
        }
    };
    let timed_out = |answer: Value| {
        failed(
            "chat.wait_timeout",
            format!(
                "the turn is still running after {}s; wait on with: cmux chat wait {target}",
                timeout.as_secs()
            ),
            answer,
            3,
        )
    };
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return timed_out(answer);
        }
        let secs = left.as_secs().max(1).to_string();
        let words = ["wait", target, "--timeout", &secs, "--json"];
        // acpmux's wait exits 2 on a permission and 3 at its timeout; both still print the answer.
        let waited = match acp(&words, None, left + WAIT_SLACK) {
            Ok(waited) => waited,
            Err(error) => match error.pointer("/details/answer") {
                Some(waited) if waited.get("sessions").is_some() => waited.clone(),
                _ => {
                    return failed(
                        "chat.lost",
                        format!("acpmux could not wait on {target}"),
                        json!({"session_id": target, "error": error}),
                        1,
                    );
                }
            },
        };
        let session = waited.pointer("/sessions/0").cloned().unwrap_or(Value::Null);
        if waited.get("timedOut") == Some(&json!(true)) || session.is_null() {
            return timed_out(answer);
        }
        if session.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0
            || session.get("status").and_then(Value::as_str) == Some("permission")
        {
            return failed(
                "chat.permission_waiting",
                format!(
                    "the agent asks for a permission: answer it in the cmux app or with `cmux acp pending`, then: cmux chat wait {target}"
                ),
                answer,
                2,
            );
        }
        if let Some(baseline) = baseline {
            let info = acp(&["session", "info", target, "--json"], None, WAIT_SLACK);
            let ran = info.as_ref().ok().and_then(|info| info.get("turnCount")?.as_u64());
            let idle = info.as_ref().ok().and_then(|info| info.get_str("status")) == Some("ready");
            // An info that cannot be read leaves the wait's word: never a wait with no end.
            if ran.is_some_and(|ran| ran <= baseline || !idle) {
                let left = deadline.saturating_duration_since(Instant::now());
                std::thread::sleep(left.min(NOT_STARTED_PAUSE));
                continue;
            }
        }
        let mut answer = answer;
        answer.set("status", session.get("status").cloned().unwrap_or(Value::Null));
        answer.set("reply", session.get("reply").cloned().unwrap_or(Value::Null));
        if let Some(error) = session.get("error").filter(|error| !error.is_null()) {
            answer.set("error", error.clone());
            return Outcome::Failed {
                error: json!({"code": "chat.turn_failed",
                              "message": format!("the turn on {target} ended with an error"),
                              "details": answer, "retryable": false}),
                exit: 1,
            };
        }
        return Outcome::Done(answer);
    }
}

/// Chat `target`'s turn count now (`acp session info`'s `turnCount`); None when acpmux cannot
/// say (then a wait takes `acp wait`'s word alone).
pub(in crate::cli) fn turn_count(target: &str) -> Option<u64> {
    let info = acp_json(&["session", "info", target, "--json"], None, WAIT_SLACK).ok()?;
    info.get("turnCount")?.as_u64()
}

/// [`wait_turn`] through this binary's acpmux.
pub(in crate::cli) fn wait(target: &str, baseline: Option<u64>, timeout: Duration) -> Outcome {
    wait_turn(target, baseline, timeout, acp_json)
}

/// What a start runs: `acp session start …`'s (or `acp new …`'s) words, the chat it names
/// (`HOST/NAME`) and its first prompt. `receipt`: the start answers a mesh receipt to read until
/// the machine takes the chat (a joined machine's); a peer's `new` answers once it runs.
pub(in crate::cli) struct Steps<'a> {
    pub words: &'a [&'a str],
    pub target: &'a str,
    pub prompt: Option<&'a str>,
    pub receipt: bool,
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
    let receipt = if steps.receipt {
        wait_started(&enqueued, deadline, limit, poll, &mut call)?
    } else {
        enqueued
    };
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
    // A whole pretty-printed answer, else its last line: an exit 2 or 3 (`acp wait`) still
    // prints the whole answer.
    let parsed = serde_json::from_str::<Value>(stdout.trim()).ok().or_else(|| {
        stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
    });
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
    parsed.ok_or_else(|| {
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
