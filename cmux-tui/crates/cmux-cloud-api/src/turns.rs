//! "Back to before this turn" for a Cloud chat: cmux-platform's whole-machine turn checkpoints
//! (`/v1/workspaces/{workspace}/machine/...`, owner auth, the person's personal team).
//!
//! - `owner.turn_checkpoint {workspace, carrierMachine?, session, turnSeq, clientKey}` reads the
//!   workspace's connection (a workspace with no machine yet binds `carrierMachine`, the chat's
//!   Cloud machine, with `import` at generation 0), snapshots the machine for turn
//!   `auto-t<turnSeq>-g<generation>` fenced by the live logical machine and generation, then finishes that turn
//!   at once (a checkpoint taken between turns never runs, and finish frees the workspace gate).
//!   Then the session's older automatic checkpoints past [`AUTO_CHECKPOINTS_KEPT`] are deleted,
//!   best effort. Answers `{turn, turnSeq, snapshotId, generation, machineId, connectionMachine,
//!   imported, seconds, retention: {kept, deleted, failed}}`.
//! - `owner.turn_rewind {workspace, session, turnSeq, clientKey}` reads the live fence, rewinds
//!   to this session's checkpoint nearest before turn `turnSeq` (the highest checkpoint turn number
//!   not past it, the newest of those), sending the same key again while the platform answers a
//!   retryable 5xx, for at most [`REWIND_DEADLINE`]) and reads the new connection. Answers
//!   `{turn, turnSeq, generation, machineId, connectionMachine, rewindId, seconds}`.
//! - `owner.turns {workspace, session?}` answers `{captures}`: the ready checkpoints (of `session`
//!   when given), newest first, each `{turn, turnSeq, session, snapshotId, machineGeneration,
//!   createdAt}` (`turnSeq` null for a turn this engine did not name).
//!
//! The platform answers its own shape (or the Worker's `{ok: true, value}`); a refusal is
//! `{_tag, code, message}` (or the Worker's `{error: {code, message}}`), read into
//! [`Failure::Http`].

use std::cmp::Reverse;
use std::future::Future;
use std::time::Duration;

use cmux_cloud_machine::refusals;
use reqwest::Method;
use serde_json::{Map, Value, json};
use tokio::time::Instant;

use super::http::{Body, Http, path_text};
use super::owner::{is_machine_id, is_session_id};
use super::{Failure, optional_int, optional_text, text};

/// How many automatic turn checkpoints of one chat session are kept: after each new one, older
/// ones past this count are deleted. `None` or `Some(0)` means never delete. Leo has not decided
/// between keeping 5 and no automatic deletion; either is this one line.
pub(crate) const AUTO_CHECKPOINTS_KEPT: Option<usize> = Some(5);

/// The prefix of every turn id this engine names (`auto-t<turnSeq>-g<generation>`): retention only ever
/// touches these, of the caller's own session.
const AUTO_TURN_PREFIX: &str = "auto-t";

/// The longest a rewind keeps retrying the same key (the platform restores onto a new carrier).
pub(crate) const REWIND_DEADLINE: Duration = Duration::from_secs(300);
/// The longest a checkpoint keeps retrying (a capture the platform still reads `capturing`).
pub(crate) const CHECKPOINT_DEADLINE: Duration = Duration::from_secs(180);
/// One platform request's deadline (the live snapshot took 8 s, a rewind 16 s).
const REQUEST_TIMEOUT: Duration = Duration::from_secs(180);
/// A delete of one old checkpoint.
const DELETE_TIMEOUT: Duration = Duration::from_secs(30);

/// How a call paces its same-key retries.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Pace {
    pub(crate) pause: Duration,
    pub(crate) deadline: Duration,
}

impl Pace {
    const fn new(deadline: Duration) -> Self {
        Pace { pause: Duration::from_secs(2), deadline }
    }
}

pub(crate) async fn run(
    http: &Http,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    match call {
        "owner.turn_checkpoint" => {
            checkpoint(http, args, Pace::new(CHECKPOINT_DEADLINE), AUTO_CHECKPOINTS_KEPT).await
        }
        "owner.turn_rewind" => rewind(http, args, Pace::new(REWIND_DEADLINE)).await,
        "owner.turns" => turns(http, args).await,
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

fn id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

fn workspace(args: &Map<String, Value>) -> Result<&str, Failure> {
    let workspace = text(args, "workspace")?;
    if (1..=128).contains(&workspace.len()) && workspace.bytes().all(id_byte) {
        Ok(workspace)
    } else {
        Err(Failure::Transport("not a workspace id".into()))
    }
}

fn session(args: &Map<String, Value>) -> Result<&str, Failure> {
    let session = text(args, "session")?;
    if is_session_id(session) {
        Ok(session)
    } else {
        Err(Failure::Transport("not a session id".into()))
    }
}

/// The largest turn number (a transcript sequence fits well below it).
const MAX_TURN_SEQ: i64 = 1_000_000_000_000_000;

fn turn_seq(args: &Map<String, Value>) -> Result<i64, Failure> {
    optional_int(args, "turnSeq")
        .filter(|n| (1..=MAX_TURN_SEQ).contains(n))
        .ok_or_else(|| Failure::Transport("the call needs turnSeq, a turn number from 1".into()))
}

/// A client key the platform takes (at most 128 bytes) with room for this engine's suffixes.
fn client_key(args: &Map<String, Value>) -> Result<&str, Failure> {
    let key = text(args, "clientKey")?;
    if (1..=100).contains(&key.len()) && key.bytes().all(|b| id_byte(b) || b == b'.' || b == b':') {
        Ok(key)
    } else {
        Err(Failure::Transport("not a client key".into()))
    }
}

/// The turn id of turn `seq` taken at machine generation `generation` (`auto-t<seq>-g<generation>`).
/// The generation keeps a turn number the chat reaches again after a rewind (the restored
/// transcript counts from there again) from naming the checkpoint taken before the rewind.
pub(crate) fn auto_turn(seq: i64, generation: i64) -> String {
    format!("{AUTO_TURN_PREFIX}{seq}-g{generation}")
}

/// The turn number of a turn id this engine named, or none.
pub(crate) fn auto_turn_seq(turn: &str) -> Option<i64> {
    let (digits, generation) = turn.strip_prefix(AUTO_TURN_PREFIX)?.split_once("-g")?;
    let number = |text: &str| {
        (!text.is_empty()
            && text.bytes().all(|b| b.is_ascii_digit())
            && (text == "0" || !text.starts_with('0')))
        .then(|| text.parse::<i64>().ok())
        .flatten()
    };
    number(generation)?;
    number(digits).filter(|n| *n >= 1)
}

/// Now plus `wait` (now, should the clock overflow).
fn later(wait: Duration) -> Instant {
    let now = Instant::now();
    now.checked_add(wait).unwrap_or(now)
}

fn seconds(started: Instant) -> f64 {
    (started.elapsed().as_secs_f64() * 10.0).round() / 10.0
}

/// The workspace's logical machine, its generation and the physical carrier to connect to.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Connection {
    machine: String,
    generation: i64,
    carrier: String,
}

impl Connection {
    fn read(value: &Value, path: &str) -> Result<Self, Failure> {
        let text = |name: &str| value.get(name).and_then(Value::as_str).map(str::to_owned);
        match (text("machineId"), value.get("generation").and_then(Value::as_i64)) {
            (Some(machine), Some(generation)) => Ok(Connection {
                carrier: text("connectionMachine").unwrap_or_else(|| machine.clone()),
                machine,
                generation,
            }),
            _ => Err(Failure::Decoding(format!("{path}: no machineId and generation"))),
        }
    }
}

/// One platform request: its 2xx JSON (unwrapping the Worker's `{ok: true, value}`), or its
/// refusal.
async fn call(
    http: &Http,
    method: Method,
    segments: &[&str],
    body: Option<Value>,
    timeout: Duration,
) -> Result<Value, Failure> {
    call_query(http, method, segments, &[], body, timeout).await
}

/// [`call`] with a query string.
async fn call_query(
    http: &Http,
    method: Method,
    segments: &[&str],
    query: &[(&str, String)],
    body: Option<Value>,
    timeout: Duration,
) -> Result<Value, Failure> {
    let path = path_text(segments);
    let reply = http
        .send(method, http.url(segments, query), body.map(Body::Json), None, timeout, &path)
        .await?;
    let object = reply.json();
    if !reply.ok() {
        return Err(refusal_with(reply.status, object.as_ref(), reply.retry_after.as_deref()));
    }
    match object {
        Some(Value::Object(mut o)) if o.get("ok") == Some(&Value::Bool(true)) => {
            o.remove("value").ok_or_else(|| Failure::Decoding(format!("{path}: no value")))
        }
        Some(value) => Ok(value),
        None => Err(Failure::Decoding(format!("{path}: the answer is not JSON"))),
    }
}

/// The platform's refusal: `{_tag, code, message, retryable, retryAfterSeconds}` or
/// `{error: {code, message}}`, with no Retry-After header (the tests' shorthand; a call reads
/// its header through [`refusal_with`]).
#[cfg(test)]
pub(crate) fn refusal(status: u16, body: Option<&Value>) -> Failure {
    refusal_with(status, body, None)
}

/// [`refusal`] with the answer's Retry-After header, a rate limit's window when the body names none.
pub(crate) fn refusal_with(
    status: u16,
    body: Option<&Value>,
    retry_after: Option<&str>,
) -> Failure {
    let nested = body.and_then(|b| b.get("error")).filter(|e| e.is_object());
    let read = |name: &str| {
        body.and_then(|b| b.get(name))
            .and_then(Value::as_str)
            .or_else(|| nested.and_then(|e| e.get(name)).and_then(Value::as_str))
            .map(str::to_owned)
    };
    let facts = refusals::Facts::read(body, retry_after);
    match Failure::http(status, read("code"), read("message")) {
        Failure::Http { status, code, message, action, trace_id, .. } => Failure::Http {
            status,
            code,
            message,
            action,
            trace_id,
            retryable: facts.retryable,
            retry_after_s: facts.retry_after_s,
        },
        other => other,
    }
}

/// Whether the same key may be sent again: the body's own `retryable` when it has one
/// (cmux-platform#1192: a busy machine's 409 and a rate limit's 429 may, a cap's 403 and a
/// final 503 may not); else the platform's table for its code; else a gateway's 502/504, a
/// timeout, a 429, or the platform's 503 that says to retry (a restore or pause still pending,
/// the service briefly away).
pub(crate) fn retryable(failure: &Failure) -> bool {
    match failure {
        Failure::TimedOut(_) => true,
        Failure::Http { retryable: Some(flag), .. } => *flag,
        Failure::Http { code: Some(code), .. } if refusals::platform(code).is_some() => {
            refusals::platform(code).is_some_and(|row| row.handling() != refusals::Handling::Final)
        }
        Failure::Http { status: 429 | 502 | 504, .. } => true,
        Failure::Http { status: 503, code, .. } => matches!(
            code.as_deref(),
            None | Some(
                "machine.turn_restore_pending"
                    | "machine.rewind_pause_pending"
                    | "machine.unavailable"
                    | "MachineUnavailable"
            )
        ),
        _ => false,
    }
}

/// `attempt` until it answers or fails for good, the same request each time, while `pace`'s
/// deadline allows.
async fn retrying<F, Fut>(pace: Pace, mut attempt: F) -> Result<Value, Failure>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<Value, Failure>>,
{
    let deadline = later(pace.deadline);
    loop {
        match attempt().await {
            Err(failure) if retryable(&failure) && later(wait(&failure, pace)) < deadline => {
                tokio::time::sleep(wait(&failure, pace)).await;
            }
            other => return other,
        }
    }
}

/// How long before the same request again: a rate limit's own window (its Retry-After), at
/// least the pace's pause.
pub(crate) fn wait(failure: &Failure, pace: Pace) -> Duration {
    match failure {
        Failure::Http { status: 429, retry_after_s, .. } => pace.pause.max(Duration::from_secs(
            retry_after_s.unwrap_or(refusals::DEFAULT_RETRY_AFTER_SECONDS),
        )),
        _ => pace.pause,
    }
}

async fn connection(http: &Http, workspace: &str, pace: Pace) -> Result<Connection, Failure> {
    let segments = ["v1", "workspaces", workspace, "machine", "connection"];
    let value =
        retrying(pace, || call(http, Method::GET, &segments, None, REQUEST_TIMEOUT)).await?;
    Connection::read(&value, &path_text(&segments))
}

fn is_no_machine(failure: &Failure) -> bool {
    matches!(failure, Failure::Http { status: 404, code: Some(code), .. }
        if code == "workspace_machine.not_found")
}

pub(crate) async fn checkpoint(
    http: &Http,
    args: &Map<String, Value>,
    pace: Pace,
    kept: Option<usize>,
) -> Result<Value, Failure> {
    let started = Instant::now();
    let (workspace, session, seq, key) =
        (workspace(args)?, session(args)?, turn_seq(args)?, client_key(args)?);
    let carrier = optional_text(args, "carrierMachine");
    if carrier.is_some_and(|c| !is_machine_id(c)) {
        return Err(Failure::Transport("not a Cloud machine id".into()));
    }
    let (live, imported) = match connection(http, workspace, pace).await {
        Ok(live) => (live, false),
        Err(failure) if is_no_machine(&failure) => {
            let Some(carrier) = carrier else { return Err(failure) };
            let segments = ["v1", "workspaces", workspace, "machine", "import"];
            let body = json!({
                "carrierMachine": carrier, "expectedGeneration": 0,
                "clientKey": format!("{key}-import"),
            });
            retrying(pace, || {
                call(http, Method::POST, &segments, Some(body.clone()), REQUEST_TIMEOUT)
            })
            .await?;
            (connection(http, workspace, pace).await?, true)
        }
        Err(failure) => return Err(failure),
    };
    let turn = auto_turn(seq, live.generation);
    // A key per generation: the same turn number after a rewind is a new checkpoint.
    let key = format!("{key}-g{}", live.generation);
    let fence = |extra: Value| {
        let mut body = json!({
            "session": session, "expectedMachine": live.machine,
            "expectedGeneration": live.generation,
        });
        if let (Some(body), Value::Object(extra)) = (body.as_object_mut(), extra) {
            body.extend(extra);
        }
        body
    };
    let snapshot_segments = ["v1", "workspaces", workspace, "machine", "turns", &turn, "snapshot"];
    let snapshot_body = fence(json!({ "clientKey": key }));
    let deadline = later(pace.deadline);
    let capture = loop {
        let capture = retrying(pace, || {
            call(
                http,
                Method::POST,
                &snapshot_segments,
                Some(snapshot_body.clone()),
                REQUEST_TIMEOUT,
            )
        })
        .await?;
        let status = capture.get("status").and_then(Value::as_str);
        if status == Some("ready") {
            break capture;
        }
        if status != Some("capturing") || later(pace.pause) >= deadline {
            return Err(Failure::Decoding(format!(
                "{}: the checkpoint is not ready",
                path_text(&snapshot_segments)
            )));
        }
        tokio::time::sleep(pace.pause).await;
    };
    let snapshot = capture
        .get("snapshotId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            Failure::Decoding(format!("{}: no snapshotId", path_text(&snapshot_segments)))
        })?
        .to_owned();
    let finish_segments = ["v1", "workspaces", workspace, "machine", "turns", &turn, "finish"];
    let finish_body = fence(json!({}));
    retrying(pace, || {
        call(http, Method::POST, &finish_segments, Some(finish_body.clone()), REQUEST_TIMEOUT)
    })
    .await?;
    let retention = retain(http, workspace, session, kept).await;
    Ok(json!({
        "turn": turn, "turnSeq": seq, "snapshotId": snapshot,
        "generation": capture.get("machineGeneration").and_then(Value::as_i64).unwrap_or(live.generation),
        "machineId": live.machine, "connectionMachine": live.carrier, "imported": imported,
        "seconds": seconds(started), "retention": retention,
    }))
}

/// Deletes `session`'s automatic checkpoints older than the newest `kept`, best effort: a
/// failure is listed, never the checkpoint's failure. Only turns this engine named
/// ([`auto_turn`]) of `session` are ever touched.
async fn retain(http: &Http, workspace: &str, session: &str, kept: Option<usize>) -> Value {
    let Some(kept) = kept.filter(|n| *n > 0) else {
        return json!({ "kept": null, "deleted": [], "failed": [] });
    };
    let segments = ["v1", "workspaces", workspace, "machine", "turns"];
    let listed = match call(http, Method::GET, &segments, None, DELETE_TIMEOUT).await {
        Ok(listed) => listed,
        Err(failure) => {
            return json!({ "kept": kept, "deleted": [], "failed": [{ "list": failure.json() }] });
        }
    };
    let mut ours = ready_captures(&listed, Some(session));
    ours.retain(|c| c.seq.is_some());
    let (mut deleted, mut failed) = (Vec::new(), Vec::new());
    for old in ours.iter().skip(kept) {
        match delete_checkpoint(http, workspace, session, &old.turn).await {
            Ok(()) => deleted.push(json!(old.turn)),
            Err(failure) => failed.push(json!({
                "turn": old.turn, "snapshotId": old.snapshot, "error": failure.json(),
            })),
        }
    }
    json!({ "kept": kept, "deleted": deleted, "failed": failed })
}

/// Deletes one turn checkpoint: the platform deletes its snapshot and its ledger row, so it is
/// neither listed nor rewound to again. A delete of an already deleted checkpoint answers ok.
async fn delete_checkpoint(
    http: &Http,
    workspace: &str,
    session: &str,
    turn: &str,
) -> Result<(), Failure> {
    let segments = ["v1", "workspaces", workspace, "machine", "turns", turn];
    let query = [("session", session.to_owned())];
    call_query(http, Method::DELETE, &segments, &query, None, DELETE_TIMEOUT).await.map(|_| ())
}

/// A ready checkpoint as the page needs it.
#[derive(Debug, Clone)]
struct Capture {
    turn: String,
    seq: Option<i64>,
    session: String,
    snapshot: String,
    generation: Option<i64>,
    created: i64,
}

/// The ready captures of `listed` (`{captures}`), of `session` when given, newest first.
fn ready_captures(listed: &Value, session: Option<&str>) -> Vec<Capture> {
    let mut captures: Vec<Capture> = listed
        .get("captures")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|c| {
            let text = |name: &str| c.get(name).and_then(Value::as_str);
            if text("status") != Some("ready") {
                return None;
            }
            let capture_session = text("session")?;
            if session.is_some_and(|s| s != capture_session) {
                return None;
            }
            let turn = text("turn")?;
            Some(Capture {
                turn: turn.to_owned(),
                seq: auto_turn_seq(turn),
                session: capture_session.to_owned(),
                snapshot: text("snapshotId")?.to_owned(),
                generation: c.get("machineGeneration").and_then(Value::as_i64),
                created: c.get("createdAt").and_then(Value::as_i64).unwrap_or(0),
            })
        })
        .collect();
    captures.sort_by_key(|c| Reverse((c.created, c.seq)));
    captures
}

pub(crate) async fn rewind(
    http: &Http,
    args: &Map<String, Value>,
    pace: Pace,
) -> Result<Value, Failure> {
    let started = Instant::now();
    let (workspace, session, seq, key) =
        (workspace(args)?, session(args)?, turn_seq(args)?, client_key(args)?);
    let live = connection(http, workspace, pace).await?;
    let listed = call(
        http,
        Method::GET,
        &["v1", "workspaces", workspace, "machine", "turns"],
        None,
        Duration::from_secs(30),
    )
    .await?;
    // The checkpoint nearest before turn `seq` of this session (the highest turn number not past
    // it, the newest of those; an older generation's too): a prompt's turn number is its own
    // transcript sequence, and the checkpoint before it was taken after the turn before it ended.
    let captures = ready_captures(&listed, Some(session));
    let nearest = captures.iter().filter_map(|c| c.seq).filter(|n| *n <= seq).max();
    let turn = captures
        .into_iter()
        .find(|c| c.seq.is_some() && c.seq == nearest)
        .map(|c| c.turn)
        .ok_or_else(|| {
        Failure::http(
            404,
            Some("machine.turn_capture_not_found".into()),
            Some(format!("no checkpoint before turn {seq}")),
        )
    })?;
    let segments = ["v1", "workspaces", workspace, "machine", "turns", &turn, "rewind"];
    let body = json!({
        "session": session, "clientKey": key, "expectedMachine": live.machine,
        "expectedGeneration": live.generation,
    });
    let rewound =
        retrying(pace, || call(http, Method::POST, &segments, Some(body.clone()), REQUEST_TIMEOUT))
            .await?;
    let rewind_id = rewound
        .get("rewindId")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Decoding(format!("{}: no rewindId", path_text(&segments))))?
        .to_owned();
    let after = connection(http, workspace, pace).await?;
    Ok(json!({
        "turn": turn, "turnSeq": seq,
        "generation": rewound.get("generation").and_then(Value::as_i64).unwrap_or(after.generation),
        "machineId": after.machine, "connectionMachine": after.carrier, "rewindId": rewind_id,
        "seconds": seconds(started),
    }))
}

async fn turns(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let workspace = workspace(args)?;
    let session = match optional_text(args, "session") {
        Some(session) if is_session_id(session) => Some(session),
        Some(_) => return Err(Failure::Transport("not a session id".into())),
        None => None,
    };
    let segments = ["v1", "workspaces", workspace, "machine", "turns"];
    let listed = call(http, Method::GET, &segments, None, Duration::from_secs(30)).await?;
    let captures: Vec<Value> = ready_captures(&listed, session)
        .into_iter()
        .map(|c| {
            json!({
                "turn": c.turn, "turnSeq": c.seq, "session": c.session, "snapshotId": c.snapshot,
                "machineGeneration": c.generation, "createdAt": c.created,
            })
        })
        .collect();
    Ok(json!({ "captures": captures }))
}
