//! The cmux API Worker's routes a person's own session calls outside the op path
//! (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
//! machine, a fork run, the person's hand-offs and their turns, the harness login copy switch
//! and the GitHub App status. The person key goes only in a request body; nothing is retried.

use std::time::Duration;

use cmux_cloud_machine::github::{self, GitHubApp};
use cmux_cloud_machine::harness_copy;
use cmux_json::JsonSet as _;
use reqwest::Method;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::http::{Body, Http, path_text, worker_error};
use super::{Failure, optional_int, text};

/// The longest the store holds one hand-off wait (`MAX_WAIT_MS`).
pub(crate) const HANDOFF_WAIT_LIMIT_MS: i64 = 25_000;
/// The statuses a hand-off's turn has.
pub(crate) const HANDOFF_STATUSES: [&str; 6] =
    ["starting", "running", "needs-you", "done", "failed", "cancelled"];
/// The refusals that answer the hand-off as it is.
pub(crate) const HANDOFF_REFUSALS: [&str; 4] =
    ["handoff.conflict", "handoff.turn_conflict", "handoff.turn_running", "handoff.closed"];

fn all(text: &str, max: usize, allowed: impl Fn(u8) -> bool) -> bool {
    (1..=max).contains(&text.len()) && text.bytes().all(allowed)
}

fn id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// A Worker machine id (`vm_` and 20 lowercase letters or digits).
pub(crate) fn is_machine_id(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|tail| {
        tail.len() == 20 && tail.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}

/// The store's hand-off ids (`ho_` and 20 lowercase hex digits).
pub(crate) fn is_handoff_id(id: &str) -> bool {
    id.strip_prefix("ho_").is_some_and(|tail| {
        tail.len() == 20 && tail.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// The store's session ids (`SESSION` in routes.ts).
pub(crate) fn is_session_id(id: &str) -> bool {
    all(id, 128, |b| id_byte(b) || b == b'.' || b == b':')
}

pub(crate) async fn run(
    http: &Http,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    match call {
        "owner.acpmux_person_holds" => {
            let machine = machine(args)?;
            let body = json!({ "nonce": text(args, "nonce")? });
            let segments = ["v1", "cloud", "machines", machine, "acpmux", "person-holds"];
            let value =
                post_value(http, &segments, Body::Json(body), Duration::from_secs(40)).await?;
            let read = |name: &str| value.get(name).and_then(Value::as_str).map(str::to_owned);
            match (read("instance"), read("proof")) {
                (Some(instance), Some(proof)) => {
                    Ok(json!({ "instance": instance, "proof": proof }))
                }
                _ => Err(Failure::Decoding(format!(
                    "{}: no instance and proof",
                    path_text(&segments)
                ))),
            }
        }
        "owner.fork_run" => fork_run(http, args).await,
        "owner.handoff_wait" => {
            let id = text(args, "id")?;
            if !is_handoff_id(id) {
                return Err(Failure::Transport("not a hand-off id".into()));
            }
            let held = optional_int(args, "timeoutMs")
                .unwrap_or(HANDOFF_WAIT_LIMIT_MS)
                .clamp(0, HANDOFF_WAIT_LIMIT_MS);
            let after = optional_int(args, "after").unwrap_or(0).max(0);
            let query = [("after", after.to_string()), ("timeoutMs", held.to_string())];
            let timeout = Duration::from_millis(u64::try_from(held).unwrap_or(0))
                .saturating_add(Duration::from_secs(15));
            get(http, &["v1", "handoffs", id, "wait"], &query, timeout).await
        }
        "owner.handoffs" => handoffs(http, optional_int(args, "pages").unwrap_or(20)).await,
        "owner.handoff_open" => {
            let (session, machine) = (text(args, "session")?, text(args, "machine")?);
            if !is_session_id(session) {
                return Err(Failure::Transport("not a session id".into()));
            }
            if !all(machine, 64, id_byte) {
                return Err(Failure::Transport("not a Cloud machine id".into()));
            }
            handoff_post(
                http,
                &["v1", "handoffs"],
                json!({ "sessionId": session, "machine": machine }),
            )
            .await
        }
        "owner.handoff_begin_turn" => {
            let id = text(args, "id")?;
            if !is_handoff_id(id) {
                return Err(Failure::Transport("not a hand-off id".into()));
            }
            let after = optional_int(args, "after").unwrap_or(0).max(0);
            handoff_post(http, &["v1", "handoffs", id, "turns"], json!({ "after": after })).await
        }
        "owner.harness_login_copy" => {
            let body =
                get(http, &["v1", "cloud", "harness-login-copy"], &[], Duration::from_secs(5))
                    .await?;
            harness_login_copy(&body)
        }
        "owner.github_app" => github_app(http, text(args, "team")?).await,
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

fn machine(args: &Map<String, Value>) -> Result<&str, Failure> {
    let machine = text(args, "machine")?;
    // The machine id is the only path part that varies; anything else is refused before a request.
    if is_machine_id(machine) {
        Ok(machine)
    } else {
        Err(Failure::Transport("not a Cloud machine id".into()))
    }
}

/// `POST /v1/cloud/machines/{machine}/acpmux/keyed-start`: restarts the machine's acpmux with
/// the person key in `key` (the bytes after the request's line, exactly `key_length` of them).
/// Answers `{personInstance}`, the new daemon run.
pub(crate) async fn keyed_start(
    http: &Http,
    args: &Map<String, Value>,
    key: Zeroizing<Vec<u8>>,
) -> Result<Value, Failure> {
    let machine = machine(args)?;
    let length = optional_int(args, "key_length").and_then(|n| usize::try_from(n).ok());
    if length != Some(key.len()) || key.is_empty() {
        return Err(Failure::Transport("the key did not reach the request body".into()));
    }
    let segments = ["v1", "cloud", "machines", machine, "acpmux", "keyed-start"];
    // The request owns the key's buffer (no copy), and it is wiped when reqwest drops it.
    let body = Body::Bytes(key, "application/octet-stream");
    let value = post_value(http, &segments, body, Duration::from_secs(100))
        .await
        .map_err(without_service_text)?;
    match value.get("personInstance").and_then(Value::as_str) {
        Some(instance) => Ok(json!({ "personInstance": instance })),
        None => Err(Failure::Decoding(format!("{}: no personInstance", path_text(&segments)))),
    }
}

/// `failure` with no text the service wrote: a refusal of the keyed start could echo the person
/// key, which the caller's credential scrub does not know. Only the status, a code from the
/// known table and local text remain.
fn without_service_text(failure: Failure) -> Failure {
    match failure {
        Failure::Http { status, code, .. } => {
            let code = crate::session::known_code(code.as_deref());
            Failure::http(status, (!code.is_empty()).then(|| code.to_owned()), None)
        }
        Failure::PlanRequired { plan, .. } => {
            Failure::PlanRequired { message: None, upgrade_url: None, plan }
        }
        other => other,
    }
}

/// A POST answered `{ok: true, value}` (anything else is the route's refusal).
async fn post_value(
    http: &Http,
    segments: &[&str],
    body: Body,
    timeout: Duration,
) -> Result<Value, Failure> {
    let path = path_text(segments);
    let reply =
        http.send(Method::POST, http.url(segments, &[]), Some(body), None, timeout, &path).await?;
    let object = reply.json();
    match object.as_ref().filter(|_| reply.ok()) {
        Some(o) if o.get("ok") == Some(&Value::Bool(true)) && o.get("value").is_some() => {
            Ok(o["value"].clone())
        }
        _ => Err(worker_error(reply.status, object.as_ref())),
    }
}

/// A GET whose 2xx body is answered as sent.
async fn get(
    http: &Http,
    segments: &[&str],
    query: &[(&str, String)],
    timeout: Duration,
) -> Result<Value, Failure> {
    let path = path_text(segments);
    let reply =
        http.send(Method::GET, http.url(segments, query), None, None, timeout, &path).await?;
    if !reply.ok() {
        return Err(worker_error(reply.status, reply.json().as_ref()));
    }
    reply.json().ok_or_else(|| Failure::Decoding(format!("{path}: the answer is not JSON")))
}

/// `POST /v1/workspaces/{workspace}/fork-runs`: snapshots the source machine now and creates
/// one durable child per harness. The value is a list, `{children}`, or one child; answers the list.
async fn fork_run(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let workspace = text(args, "workspace")?;
    if !all(workspace, 128, id_byte) {
        return Err(Failure::Transport("not a workspace id".into()));
    }
    let body = json!({
        "clientKey": text(args, "clientKey")?, "sourceMachine": text(args, "sourceMachine")?,
        "session": text(args, "session")?, "harnesses": args.get("harnesses").cloned().unwrap_or_else(|| json!([])),
    });
    let segments = ["v1", "workspaces", workspace, "fork-runs"];
    let value = post_value(http, &segments, Body::Json(body), Duration::from_secs(180)).await?;
    fork_children(value)
        .ok_or_else(|| Failure::Decoding(format!("{}: no children", path_text(&segments))))
}

/// The children of a fork run's value, each `{id, harness, state, machineId?, error?}`.
pub(crate) fn fork_children(value: Value) -> Option<Value> {
    let list = match value {
        Value::Array(list) => list,
        Value::Object(mut object) => match object.remove("children") {
            Some(Value::Array(list)) => list,
            Some(Value::Null) | None => vec![Value::Object(object)],
            Some(_) => return None,
        },
        _ => return None,
    };
    let child = |v: &Value| {
        let text = |name: &str| v.get(name).and_then(Value::as_str);
        // Absent or null is null; any other value than a string is no child.
        let optional = |name: &str| match v.get(name) {
            None | Some(Value::Null) => Some(Value::Null),
            Some(Value::String(s)) => Some(json!(s)),
            Some(_) => None,
        };
        Some(json!({
            "id": text("id")?, "harness": text("harness")?, "state": text("state")?,
            "machineId": optional("machineId")?, "error": optional("error")?,
        }))
    };
    list.iter().map(child).collect::<Option<Vec<_>>>().map(Value::Array)
}

/// The most pages `owner.handoffs` reads (100 hand-offs each).
const MAX_HANDOFF_PAGES: i64 = 50;

/// `GET /v1/handoffs?limit=100&cursor=`: the person's hand-offs, newest first, page after page
/// (at most `pages`). Answers the list.
async fn handoffs(http: &Http, pages: i64) -> Result<Value, Failure> {
    let mut all_handoffs = Vec::new();
    let mut bytes = 0_usize;
    let mut cursor: Option<String> = None;
    for _ in 0..pages.clamp(1, MAX_HANDOFF_PAGES) {
        let mut query = vec![("limit", "100".to_owned())];
        if let Some(cursor) = &cursor {
            if !all(cursor, 512, id_byte) {
                return Err(Failure::Transport("not a list cursor".into()));
            }
            query.push(("cursor", cursor.clone()));
        }
        let page = get(http, &["v1", "handoffs"], &query, Duration::from_secs(30)).await?;
        let Some(list) = page.get("handoffs").and_then(Value::as_array) else {
            return Err(Failure::Decoding("/v1/handoffs: no handoffs".into()));
        };
        bytes = bytes.saturating_add(Value::Array(list.clone()).to_string().len());
        if bytes > crate::MAX_ANSWER_BYTES {
            return Err(Failure::Transport(format!(
                "/v1/handoffs: the list is larger than {} bytes",
                crate::MAX_ANSWER_BYTES
            )));
        }
        all_handoffs.extend(list.iter().cloned());
        match page.get("nextCursor").and_then(Value::as_str) {
            Some(next) if !next.is_empty() => cursor = Some(next.to_owned()),
            _ => break,
        }
    }
    Ok(Value::Array(all_handoffs))
}

/// A POST to the hand-off routes: the `{handoff}` of a 2xx answer, or of a refusal that carries
/// it ([`HANDOFF_REFUSALS`]), with `refusal` the code (null for a 2xx). Any other answer fails.
/// Only the turn's fields are read: the machine token the answer carries is never kept.
async fn handoff_post(http: &Http, segments: &[&str], body: Value) -> Result<Value, Failure> {
    let path = path_text(segments);
    let reply = http
        .send(
            Method::POST,
            http.url(segments, &[]),
            Some(Body::Json(body)),
            None,
            Duration::from_secs(20),
            &path,
        )
        .await?;
    let object = reply.json();
    let code = object
        .as_ref()
        .and_then(|o| o.pointer("/error/code"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let refused = code.as_deref().is_some_and(|c| HANDOFF_REFUSALS.contains(&c));
    let turn = object.as_ref().and_then(|o| o.get("handoff")).and_then(handoff_turn);
    match turn {
        Some(mut turn) if reply.ok() || refused => {
            turn.set("refusal", if reply.ok() { Value::Null } else { json!(code) });
            Ok(turn)
        }
        _ => Err(worker_error(reply.status, object.as_ref())),
    }
}

/// A hand-off as its turns need it: `{id, sessionId, machine, turn, state, status}`, or none
/// when the answer is not one.
pub(crate) fn handoff_turn(handoff: &Value) -> Option<Value> {
    let text = |name: &str| handoff.get(name).and_then(Value::as_str);
    let id = text("id").filter(|id| is_handoff_id(id))?;
    let turn = handoff.get("turn").and_then(Value::as_i64).filter(|t| *t >= 1)?;
    let state = text("state").filter(|s| matches!(*s, "open" | "closed"))?;
    let status = text("status").filter(|s| HANDOFF_STATUSES.contains(s))?;
    Some(json!({
        "id": id, "sessionId": text("sessionId")?, "machine": text("machine")?,
        "turn": turn, "state": state, "status": status,
    }))
}

/// The switch's answer: `{enabled, ttlSeconds}` (or that object under `value`), `ttlSeconds`
/// clamped to 0..=300 ([`cmux_cloud_machine::harness_copy::read`]).
pub(crate) fn harness_login_copy(body: &Value) -> Result<Value, Failure> {
    let copy = harness_copy::read(body).map_err(Failure::Decoding)?;
    Ok(json!({ "enabled": copy.enabled, "ttlSeconds": copy.ttl_seconds }))
}

/// `GET /v1/integrations/github/status?team=` with the person's session and no team header (the
/// team in the query is no secret): whether `team`'s Cloud machines can use the cmux GitHub App.
/// Never fails: an answer that says nothing usable is `unknown`, and the app falls back to the
/// machine's own GitHub sign-in. Answers `{state}` ([`github_app_state`]).
async fn github_app(http: &Http, team: &str) -> Result<Value, Failure> {
    // Only a team id reaches the URL.
    let id = team.strip_prefix("team_").unwrap_or_default();
    if !(team.starts_with("team_") && all(id, 120, id_byte)) {
        return Ok(json!({ "state": "unknown" }));
    }
    let segments = ["v1", "integrations", "github", "status"];
    let url = http.url(&segments, &[("team", team.to_owned())]);
    let reply = http
        .send(Method::GET, url, None, None, Duration::from_secs(15), &path_text(&segments))
        .await;
    let state = match reply {
        Ok(reply) => github_app_state(reply.status, &reply.body),
        Err(_) => "unknown",
    };
    Ok(json!({ "state": state }))
}

/// The status route's answer (`{configured, app_slug, allowed?, connection: {status} | null}`,
/// else `{error: {code, message}}`) as `ready`, `not_connected`, `not_configured` or `unknown`
/// ([`cmux_cloud_machine::github::status`]).
pub(crate) fn github_app_state(status: u16, body: &[u8]) -> &'static str {
    match github::status(status, body) {
        GitHubApp::Ready => "ready",
        GitHubApp::NotConnected => "not_connected",
        GitHubApp::NotConfigured => "not_configured",
        GitHubApp::Unknown => "unknown",
    }
}
