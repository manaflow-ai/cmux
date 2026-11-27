//! The cmux API Worker's routes a person's own session calls outside the op path
//! (`ownerAPIBaseURL`; cx-kvmz): the keyed acpmux start and its person_holds check on a Cloud
//! machine, a fork run (`fork_runs.rs`), the person's hand-offs and their turns, the harness login copy switch
//! the GitHub App status, repository list and Connect GitHub, and the feed's own ops and reads
//! (`owner.op`). The person key goes only in a request body; nothing is retried.

use std::time::Duration;

use cmux_cloud_machine::github::{self, GitHubApp};
use cmux_cloud_machine::harness_copy;
use cmux_json::JsonSet as _;
use reqwest::Method;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::http::{Body, Http, path_text, worker_error};
use super::{Failure, optional_int, optional_text, text};

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
        "owner.fork_run" => crate::fork_runs::run(http, args).await,
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
        "owner.github_app" => github_app(http, args).await,
        "owner.github_repos" => github_repos(http, args).await,
        "owner.github_connect" => github_connect(http, args).await,
        "owner.op" => op(http, args).await,
        "owner.github_complete" => github_complete(http, args).await,
        "owner.github_list" => github_list(http).await,
        "owner.github_clone_token" => github_clone_token(http, args).await,
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
/// machine's own GitHub sign-in. Answers `{state}` ([`github_app_state`]); with `raw: true` (the
/// Mac app's own status readers, whose parsers read more of it) also the route's `status` and its
/// JSON `body` (null when it is not JSON) when the route answered.
async fn github_app(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let team = text(args, "team")?;
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
    let Ok(reply) = reply else { return Ok(json!({ "state": "unknown" })) };
    let mut answer = Map::new();
    answer.insert("state".into(), json!(github_app_state(reply.status, &reply.body)));
    if args.get("raw").and_then(Value::as_bool) == Some(true) {
        answer.insert("status".into(), json!(reply.status));
        answer.insert("body".into(), reply.json().unwrap_or(Value::Null));
    }
    Ok(Value::Object(answer))
}

/// `team` when it is a team id (`team_` and up to 120 letters, digits, `_` or `-`): the only
/// team text that reaches a GitHub call's URL or team header.
pub(crate) fn team_id(team: &str) -> Result<&str, Failure> {
    let id = team.strip_prefix("team_").unwrap_or_default();
    if team.starts_with("team_") && all(id, 120, id_byte) {
        Ok(team)
    } else {
        Err(Failure::Transport("not a team id".into()))
    }
}

/// The longest repository filter the Worker takes.
const GITHUB_QUERY_MAX: usize = 256;

/// `GET /v1/integrations/github/repos?team=&query=&cursor=` with the person's session and no team
/// header: the repositories the cmux GitHub App reaches for `team`, filtered by `query` (any part of
/// `owner/name`, any case). Answers `{repos: [{full_name, private, default_branch}], truncated,
/// cursor}`; `truncated` says more remain and `cursor` continues the list. A team with no GitHub
/// connection is `github.not_connected` (the Worker's `integration.not_found`).
async fn github_repos(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let mut query = vec![("team", team_id(text(args, "team")?)?.to_owned())];
    if let Some(filter) = optional_text(args, "query").map(str::trim).filter(|q| !q.is_empty()) {
        if filter.chars().count() > GITHUB_QUERY_MAX || filter.chars().any(char::is_control) {
            return Err(Failure::Transport(format!(
                "a repository filter is at most {GITHUB_QUERY_MAX} characters of text"
            )));
        }
        query.push(("query", filter.to_owned()));
    }
    if let Some(cursor) = optional_text(args, "cursor").filter(|c| !c.is_empty()) {
        if cursor.len() > 4096 || !cursor.bytes().all(|b| id_byte(b) || b == b'.') {
            return Err(Failure::Transport("not a repository list cursor".into()));
        }
        query.push(("cursor", cursor.to_owned()));
    }
    let segments = ["v1", "integrations", "github", "repos"];
    // The Worker walks up to ten GitHub pages for one answer.
    match get(http, &segments, &query, Duration::from_secs(60)).await {
        Ok(body) => github_repo_list(&body).ok_or_else(|| {
            Failure::Decoding(format!("{}: no repository list", path_text(&segments)))
        }),
        Err(Failure::Http { status: 404, code: Some(code), message, .. })
            if code == "integration.not_found" =>
        {
            Err(Failure::http(404, Some("github.not_connected".into()), message))
        }
        Err(other) => Err(other),
    }
}

/// The repository list route's answer (`{repos, truncated}`, an older Worker's `cursor`), or none
/// when it has no `repos` list. A row that does not name `owner/name` ([`is_full_name`]) is
/// dropped, so no other text reaches the page; `private` is true unless the row says otherwise; a
/// default branch that is empty or past 255 bytes is null, as is a `size_kb` that is not a size.
pub(crate) fn github_repo_list(body: &Value) -> Option<Value> {
    let rows = body.get("repos")?.as_array()?;
    let repos: Vec<Value> = rows
        .iter()
        .filter_map(|row| {
            let name = row.get("full_name")?.as_str().filter(|n| is_full_name(n))?;
            let branch = row
                .get("default_branch")
                .and_then(Value::as_str)
                .filter(|b| !b.is_empty() && b.len() <= 255);
            let size = row
                .get("size_kb")
                .and_then(Value::as_f64)
                .filter(|n| (0.0..f64::from(i32::MAX)).contains(n))
                .map(|n| n as i64);
            Some(json!({
                "full_name": name,
                "private": row.get("private").and_then(Value::as_bool).unwrap_or(true),
                "default_branch": branch, "size_kb": size,
            }))
        })
        .collect();
    let cursor = body.get("cursor").and_then(Value::as_str);
    let truncated = body.get("truncated").and_then(Value::as_bool).unwrap_or(cursor.is_some());
    Some(json!({ "repos": repos, "truncated": truncated, "cursor": cursor }))
}

/// GitHub's `owner/name`: an owner of 1 to 39 letters, digits and `-` that neither starts nor ends
/// with `-`, and a name of 1 to 100 letters, digits, `.`, `_` and `-` that is not `.`, `..` or `.git`.
pub(crate) fn is_full_name(text: &str) -> bool {
    let Some((owner, name)) = text.split_once('/') else { return false };
    let owner_byte = |b: u8| b.is_ascii_alphanumeric() || b == b'-';
    let name_byte = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_');
    all(owner, 39, owner_byte)
        && !owner.starts_with('-')
        && !owner.ends_with('-')
        && all(name, 100, name_byte)
        && !matches!(name, "." | ".." | ".git")
}

/// An op's idempotency key: letters, digits, `_`, `-`, `:` and `.`, at most 128 bytes (the app's
/// keys: a UUID, `<uuid>:plain`, `complete:<state tail>`).
fn is_op_key(key: &str) -> bool {
    all(key, 128, |b| id_byte(b) || b == b':' || b == b'.')
}

/// A Connect GitHub's return link: `<scheme>://integration/complete`, the scheme a letter then up to
/// 63 letters, digits, `+`, `.` or `-` (`CloudGitHubCompletion.link(scheme:)`).
fn is_return_link(link: &str) -> bool {
    link.strip_suffix("://integration/complete").is_some_and(|scheme| {
        scheme.bytes().next().is_some_and(|b| b.is_ascii_alphabetic())
            && all(scheme, 64, |b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'.' | b'-'))
    })
}

/// `POST /v1/ops` `integration.connect {provider: "github"}` in the team the team header names:
/// the GitHub App's install page for the person to open. `idempotencyKey` keeps a retry on the same
/// pending connection; `returnTo` ([`is_return_link`]) asks GitHub's redirect back to the app;
/// `repo` ([`is_full_name`], a Cloud start's Connect GitHub card) lets the API reuse an active
/// connection that covers it, or answer GitHub's authorize page for an owner the App is already
/// installed on (#55104). Answers `{authorize_url, connection}`, or `{connected: true, connection}`
/// when a connection already covers `repo`; a deployment without the app answers the Worker's
/// `integration.not_configured`.
async fn github_connect(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let key = match optional_text(args, "idempotencyKey") {
        Some(key) if is_op_key(key) => key.to_owned(),
        Some(_) => return Err(Failure::Transport("not an idempotency key".into())),
        None => uuid::Uuid::new_v4().to_string(),
    };
    let mut params = Map::new();
    params.insert("provider".into(), json!("github"));
    match optional_text(args, "returnTo") {
        Some(link) if is_return_link(link) => {
            params.insert("return_to".into(), json!(link));
        }
        Some(_) => return Err(Failure::Transport("not a return link".into())),
        None => {}
    }
    match optional_text(args, "repo") {
        Some(repo) if is_full_name(repo) => {
            params.insert("repo".into(), json!(repo));
        }
        Some(_) => return Err(Failure::Transport("not a repository".into())),
        None => {}
    }
    let body = json!({
        "op": "integration.connect", "params": params, "origin": "user", "idempotency_key": key,
    });
    let segments = ["v1", "ops"];
    let value = post_value(http, &segments, Body::Json(body), Duration::from_secs(20)).await?;
    let url =
        value.get("authorize_url").and_then(Value::as_str).filter(|u| u.starts_with("https://"));
    let connection =
        value.pointer("/connection/id").and_then(Value::as_str).filter(|c| !c.is_empty());
    let connected = value.get("connected").and_then(Value::as_bool) == Some(true);
    match (url, connection) {
        (_, Some(connection)) if connected => {
            Ok(json!({ "connected": true, "connection": connection }))
        }
        (Some(url), Some(connection)) => {
            Ok(json!({ "authorize_url": url, "connection": connection }))
        }
        _ => Err(Failure::Decoding(format!("{}: no install page", path_text(&segments)))),
    }
}

/// The longest an op's name is (`run.rerunFailed`, `user.presence_key.list`).
const OP_NAME_LIMIT: usize = 128;
/// The longest a client version is (`InstallAuthClient.clientVersionHeader`).
const CLIENT_VERSION_LIMIT: usize = 64;

/// `POST /v1/ops` (`route: "ops"`) or `POST /v1/read` (`route: "read"`) with `body`
/// (`{op, params, ...}`, sent as given; or `body_json`, the same as JSON text) as the session's principal: the person's Stack session or
/// this Mac's install token, in the team the team header names. `client_version` goes as
/// `x-cmux-client-version` (the app's version, so the Worker can refuse a too-old app; no secret).
/// Answers `{status, reply}` for every HTTP status, `reply` being the body when it is a JSON
/// object (`{ok, value}`, `{value}` or `{error: {code, message}}`) and null otherwise: the
/// feed reads its own refusals, and a 401 tells it the install token is spent.
async fn op(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let route = match text(args, "route")? {
        "ops" => "ops",
        "read" => "read",
        _ => return Err(Failure::Transport("not an op route".into())),
    };
    // `body_json` is the same object as JSON text: the app's own, exactly as it serialized it.
    let body = match (args.get("body"), optional_text(args, "body_json")) {
        (Some(body), None) => Some(body.clone()),
        (None, Some(text)) => serde_json::from_str::<Value>(text).ok(),
        _ => None,
    };
    let Some(body) = body.filter(Value::is_object) else {
        return Err(Failure::Transport("no op body".into()));
    };
    let name = body.get("op").and_then(Value::as_str).unwrap_or("");
    if !all(name, OP_NAME_LIMIT, |b| id_byte(b) || b == b'.') {
        return Err(Failure::Transport("not an op name".into()));
    }
    let mut headers = Vec::new();
    if let Some(version) = optional_text(args, "client_version") {
        if !all(version, CLIENT_VERSION_LIMIT, |b| b.is_ascii_graphic() || b == b' ') {
            return Err(Failure::Transport("not a client version".into()));
        }
        headers.push(("x-cmux-client-version", version.to_owned()));
    }
    let segments = ["v1", route];
    let path = path_text(&segments);
    let reply = http
        .send_named(
            Method::POST,
            http.url(&segments, &[]),
            Some(Body::Json(body)),
            (None, &headers),
            Duration::from_secs(15),
            &path,
        )
        .await?;
    let object = reply.json().filter(Value::is_object).unwrap_or(Value::Null);
    Ok(json!({ "status": reply.status, "reply": object }))
}

/// `POST /v1/ops` `integration.complete` in the team the team header names, under the key
/// `idempotencyKey` the console's callback also sends: finishes the GitHub install the app was handed
/// back (`params`: the signed `state` and what GitHub gave, each a string). 15 s, as the app's.
/// Answers the route's `status` and JSON `body` as sent (null when it is not JSON): the app reads
/// connected, refused or no answer, and a refusal's words, from them (`CloudGitHubCompletion`).
async fn github_complete(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let key = text(args, "idempotencyKey")?;
    if !is_op_key(key) {
        return Err(Failure::Transport("not an idempotency key".into()));
    }
    let params = args
        .get("params")
        .and_then(Value::as_object)
        .filter(|p| {
            p.contains_key("state")
                && p.values().all(|v| v.as_str().is_some_and(|t| t.len() <= 4096))
        })
        .ok_or_else(|| Failure::Transport("not a completion's params".into()))?;
    let body = json!({
        "op": "integration.complete", "params": params, "origin": "user", "idempotency_key": key,
    });
    let segments = ["v1", "ops"];
    let url = http.url(&segments, &[]);
    let reply = http
        .send(
            Method::POST,
            url,
            Some(Body::Json(body)),
            None,
            Duration::from_secs(15),
            &path_text(&segments),
        )
        .await?;
    Ok(json!({ "status": reply.status, "body": reply.json().unwrap_or(Value::Null) }))
}

/// `POST /v1/read` `integration.list` in the team the team header names: whether a GitHub
/// connection the person sees is pending (Settings' Connect, another launch's). Answers `{pending}`;
/// a reply that is not `{value: {connections: [...]}}` is the route's refusal, or no list.
async fn github_list(http: &Http) -> Result<Value, Failure> {
    let segments = ["v1", "read"];
    let url = http.url(&segments, &[]);
    let body = json!({ "op": "integration.list", "params": {} });
    let path = path_text(&segments);
    let reply = http
        .send(Method::POST, url, Some(Body::Json(body)), None, Duration::from_secs(15), &path)
        .await?;
    let object = reply.json();
    if !reply.ok() || object.as_ref().and_then(|o| o.get("ok")) == Some(&Value::Bool(false)) {
        return Err(worker_error(reply.status, object.as_ref()));
    }
    let rows = object
        .as_ref()
        .and_then(|o| o.pointer("/value/connections"))
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Decoding(format!("{path}: no connection list")))?;
    let pending = rows.iter().any(|row| {
        row.get("provider").and_then(Value::as_str) == Some("github")
            && row.get("status").and_then(Value::as_str) == Some("pending")
    });
    Ok(json!({ "pending": pending }))
}

/// What a clone token may read: the repository's contents and metadata, nothing more.
const CLONE_PERMISSIONS: [&str; 2] = ["contents", "metadata"];

/// `POST /v1/integrations/github/token` with the install's own token (the call's credential) and no
/// team header: a GitHub App token for git on this Mac to clone `repo` (`owner/name`) in `team`,
/// scoped to reading it, labeled `cmux-local-clone` in Cloud's ledger. 20 s, as the app's. Answers
/// `{token}` only when it is an installation token (`ghs_`, [`is_installation_token`]) for that
/// repository with read permissions alone; any other answer names no part of its body.
async fn github_clone_token(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let team = team_id(text(args, "team")?)?;
    let repo = text(args, "repo")?;
    if !is_full_name(repo) {
        return Err(Failure::Transport("not a repository".into()));
    }
    let body = json!({
        "team": team, "repo": repo, "label": "cmux-local-clone",
        "permissions": { "contents": "read", "metadata": "read" },
    });
    let segments = ["v1", "integrations", "github", "token"];
    let path = path_text(&segments);
    let url = http.url(&segments, &[]);
    let reply = http
        .send(Method::POST, url, Some(Body::Json(body)), None, Duration::from_secs(20), &path)
        .await?;
    let object = reply.json();
    if !reply.ok() {
        return Err(worker_error(reply.status, object.as_ref()));
    }
    clone_token(object.as_ref(), repo)
        .map(|token| json!({ "token": token }))
        .ok_or_else(|| Failure::Decoding(format!("{path}: no clone token for that repository")))
}

/// The token route's 2xx answer `{token, repo, permissions?}`: its token when it is an installation
/// token for `repo` (any case) whose granted permissions are each a read of [`CLONE_PERMISSIONS`].
pub(crate) fn clone_token<'a>(body: Option<&'a Value>, repo: &str) -> Option<&'a str> {
    let body = body?;
    let token = body.get("token")?.as_str().filter(|t| is_installation_token(t))?;
    let named = body.get("repo")?.as_str()?;
    if !named.eq_ignore_ascii_case(repo) {
        return None;
    }
    if let Some(granted) = body.get("permissions").and_then(Value::as_object) {
        let read = |(name, level): (&String, &Value)| {
            CLONE_PERMISSIONS.contains(&name.as_str()) && level.as_str() == Some("read")
        };
        if !granted.iter().all(read) {
            return None;
        }
    }
    Some(token)
}

/// GitHub's installation token: `ghs_` and letters, digits or `_`, at most 255 bytes.
pub(crate) fn is_installation_token(token: &str) -> bool {
    token.len() <= 255
        && token
            .strip_prefix("ghs_")
            .is_some_and(|tail| tail.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
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
