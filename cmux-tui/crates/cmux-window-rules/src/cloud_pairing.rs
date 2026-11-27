//! The rules of the app's cloud pairing calls (Add Server… on a signed-in
//! Mac, Revoke, the paired servers' reads): the API Worker request bodies,
//! how a reply reads (a Worker error reply, the team, the enrolled host),
//! the `team.hosts.list` paging bound, and which refusal a failure shows.
//! Pure: the app owns the POSTs, the localized texts and the sink. Was
//! `CloudPairingSource.swift`'s and `ServerReachService.swift`'s request
//! and reply code.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// The Worker's read path.
pub const READ: &str = "v1/read";
/// The Worker's ops path.
pub const OPS: &str = "v1/ops";
/// The owner error code of a lookup that found nothing (`pairNotFound`, not `pairFailed`).
pub const NOT_FOUND_CODE: &str = "selector.not_found";
/// The owner error code of a team read by a user with no personal team yet (`user.ensure` once, then read again).
pub const FORBIDDEN_CODE: &str = "auth.forbidden";
/// `team.hosts.list`'s page size.
pub const HOSTS_PAGE_LIMIT: u32 = 100;
/// The most `team.hosts.list` pages one read takes: a larger directory is a partial read, never acted on.
pub const HOSTS_PAGE_CAP: u32 = 20;

/// One Worker call the app makes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Request {
    /// `server.pair.preview {code}` (the code already normalized).
    Lookup { code: String },
    /// `team.policy.get`: the Worker's team for this session.
    TeamRead,
    /// `user.ensure` (idempotent), with a fresh `nonce` the app makes.
    Ensure { nonce: String },
    /// `server.pair.approve {code, team, name}`, the intent's key as the idempotency key.
    Approve { code: String, team: String, name: String, key: String },
    /// `server.revoke {host}`, the intent's key as the idempotency key.
    Revoke { host: String, key: String },
    /// `chief.list`: which servers run a chief.
    ChiefList,
    /// One page of `team.hosts.list`.
    HostsPage {
        #[serde(default)]
        cursor: Option<String>,
    },
}

/// A Worker call's path and body.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Call {
    pub path: &'static str,
    pub body: Value,
}

fn op(op: &str, params: Value) -> Value {
    json!({ "op": op, "params": params })
}

fn user_op(op: &str, params: Value, key: &str) -> Value {
    json!({ "op": op, "params": params, "idempotency_key": key, "origin": "user" })
}

/// The path and body of `request`.
pub fn call(request: &Request) -> Call {
    match request {
        Request::Lookup { code } => {
            Call { path: READ, body: op("server.pair.preview", json!({ "code": code })) }
        }
        Request::TeamRead => Call { path: READ, body: op("team.policy.get", json!({})) },
        Request::Ensure { nonce } => Call {
            path: OPS,
            body: user_op("user.ensure", json!({}), &format!("server-pair-ensure-{nonce}")),
        },
        Request::Approve { code, team, name, key } => Call {
            path: OPS,
            body: user_op(
                "server.pair.approve",
                json!({ "code": code, "team": team, "name": name }),
                key,
            ),
        },
        Request::Revoke { host, key } => {
            Call { path: OPS, body: user_op("server.revoke", json!({ "host": host }), key) }
        }
        Request::ChiefList => Call { path: READ, body: op("chief.list", json!({})) },
        Request::HostsPage { cursor } => {
            let mut params = Map::new();
            params.insert("limit".into(), json!(HOSTS_PAGE_LIMIT));
            if let Some(cursor) = cursor {
                params.insert("cursor".into(), json!(cursor));
            }
            Call { path: READ, body: op("team.hosts.list", Value::Object(params)) }
        }
    }
}

/// How a Worker reply reads (`okValue`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Reply {
    /// A successful reply's `value` (null when it has none).
    Ok { value: Value },
    /// A Worker error reply (`{_tag, code, message}`): the owner's error.
    Owner { code: String, message: String },
}

/// `reply` as the app reads it: a reply with a `_tag` and a string `code`
/// is the owner's error (its `message`, else its code); any other its `value`.
pub fn reply(reply: &Value) -> Reply {
    if reply.get("_tag").is_some_and(|tag| !tag.is_null())
        && let Some(code) = reply.get("code").and_then(Value::as_str)
    {
        let message = reply.get("message").and_then(Value::as_str).unwrap_or(code);
        return Reply::Owner { code: code.to_owned(), message: message.to_owned() };
    }
    Reply::Ok { value: reply.get("value").cloned().unwrap_or(Value::Null) }
}

/// The team a pairing approves into.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Team {
    pub id: String,
    pub name: String,
}

/// The Worker's team from a `team.policy.get` reply's `value` (`value.team`,
/// non-empty), named as the account (its id when the account has no name);
/// `None`: a bad reply.
pub fn team(value: &Value, account: &str) -> Option<Team> {
    let id = value.get("team")?.as_str().filter(|id| !id.is_empty())?;
    let name = if account.is_empty() { id } else { account };
    Some(Team { id: id.to_owned(), name: name.to_owned() })
}

/// Whether a failed team read runs `user.ensure` once and reads again (a
/// user who only ever signed in on a Mac has no personal team yet).
pub fn team_read_ensures(code: &str) -> bool {
    code == FORBIDDEN_CODE
}

/// An approve's success: the enrolled host, and the install a Chief moves to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Approved {
    pub host: String,
    pub install: Option<String>,
}

/// An approve reply's `value`: success only with the enrolled host (`value.host`); `None`: a bad reply.
pub fn approved(value: &Value) -> Option<Approved> {
    let host = value.get("host")?.as_str()?;
    Some(Approved {
        host: host.to_owned(),
        install: value.get("install").and_then(Value::as_str).map(str::to_owned),
    })
}

/// After one `team.hosts.list` page: read the next, or stop.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum HostsNext {
    /// Read the page at `cursor`.
    Read { cursor: String },
    /// Every host was read.
    Done,
    /// Past the cap: a partial read, never acted on.
    TooMany,
}

/// What follows page `index` (from 0) whose next cursor is `next`.
pub fn hosts_next(index: u32, next: Option<&str>) -> HostsNext {
    match next.filter(|next| !next.is_empty()) {
        None => HostsNext::Done,
        Some(_) if index + 1 >= HOSTS_PAGE_CAP => HostsNext::TooMany,
        Some(cursor) => HostsNext::Read { cursor: cursor.to_owned() },
    }
}

/// Which call failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    Lookup,
    Approve,
    Revoke,
    /// Placing the user's Chief on the server just approved.
    PlaceChief,
}

/// How a call failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Failure {
    /// The Worker's own error.
    Owner { code: String, message: String },
    /// No signed-in account.
    SignedOut,
    /// Anything else (no raw error dump reaches the person).
    Other,
    /// A Chief place with no install to move to.
    NoInstall,
    /// A lookup whose server's key could not be checked.
    KeyUnchecked,
}

/// The refusal a failure shows: a `refusal.server.*` key, the Worker's
/// message when the text carries one, and the inner refusal a Chief that
/// could not move names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Refusal {
    pub key: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cause: Option<&'static str>,
}

impl Refusal {
    fn key(key: &'static str) -> Self {
        Refusal { key, message: None, cause: None }
    }

    fn with(key: &'static str, message: &str) -> Self {
        Refusal { key, message: Some(message.to_owned()), cause: None }
    }
}

/// `refusal.server.pairSignedOut`.
pub const SIGNED_OUT: &str = "pairSignedOut";
/// `refusal.server.pairUnreachable`.
pub const UNREACHABLE: &str = "pairUnreachable";

/// The fixed text of a failure that is not the owner's.
fn plain(failure: &Failure) -> &'static str {
    if matches!(failure, Failure::SignedOut) { SIGNED_OUT } else { UNREACHABLE }
}

/// The refusal `failure` of `stage` shows.
pub fn refusal(stage: Stage, failure: &Failure) -> Refusal {
    match (stage, failure) {
        (Stage::Lookup, Failure::KeyUnchecked) => Refusal::key("pairKeyUnchecked"),
        (Stage::Lookup, Failure::Owner { code, .. }) if code == NOT_FOUND_CODE => {
            Refusal::key("pairNotFound")
        }
        (Stage::Lookup | Stage::Approve, Failure::Owner { message, .. }) => {
            Refusal::with("pairFailed", message)
        }
        (Stage::Revoke, Failure::Owner { message, .. }) => Refusal::with("revokeFailed", message),
        (Stage::PlaceChief, Failure::Owner { message, .. }) => {
            Refusal::with("chiefNotMoved", message)
        }
        (Stage::PlaceChief, Failure::NoInstall) => {
            Refusal { key: "chiefNotMoved", message: None, cause: Some("noInstall") }
        }
        (Stage::PlaceChief, other) => {
            Refusal { key: "chiefNotMoved", message: None, cause: Some(plain(other)) }
        }
        (_, other) => Refusal::key(plain(other)),
    }
}

#[cfg(test)]
#[path = "cloud_pairing_tests.rs"]
mod tests;
