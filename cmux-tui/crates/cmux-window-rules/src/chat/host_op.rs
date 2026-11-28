//! The agent pane page's host ops: what a `{method, params}` message the page
//! posts to its native host asks for, checked. The host hands the page's
//! message here and acts on the answer (a Cloud call, a daemon frame, the
//! GitHub picker); an answer of `unsupported` is refused, and a method this
//! table does not hold yet is the host's own to decode (`swift`).
//!
//! This is the move of the Swift decoder (`AgentPaneRequest+Decoding.swift`
//! and its family envelopes) into Rust, one family at a time
//! (cmuxterm-hq docs/rfd/drafts/why-swift.md, "Web view host and host-op
//! bridge"): every host on every OS decodes the page the same way. The checks
//! are the Swift ones, unchanged; `host_op_tests.rs` pins them.

use serde::Serialize;
use serde_json::{Map, Value};

#[path = "host_op_host.rs"]
pub mod host;
#[path = "host_op_pane.rs"]
pub mod pane;

use pane::characters;

/// The page's Cloud environment editor (`cloud.environment.*`): an envelope
/// only, the shared web editor and Rust's Cloud client check the fields.
pub const CLOUD_ENVIRONMENT_METHODS: [&str; 5] = [
    "cloud.environment.list",
    "cloud.environment.get",
    "cloud.environment.update",
    "cloud.environment.derive",
    "cloud.environment.create",
];

/// The Cloud compose's machine reservation.
pub const CLOUD_RESERVATION_METHODS: [&str; 2] = ["cloud.reserve", "cloud.releaseReservation"];

/// The Cloud repository actions the daemon owns.
pub const CLOUD_REPOSITORY_METHODS: [&str; 6] = [
    "cloud.repo.local",
    "cloud.repo.sync",
    "cloud.repo.list",
    "cloud.repo.add",
    "cloud.repo.attached",
    "cloud.repo.wait_github",
];

/// The new chat folder picker's GitHub section and the clone of a URL.
pub const GITHUB_METHODS: [&str; 5] =
    ["github.status", "github.connect", "github.repos.list", "github.repos.checkout", "repo.clone"];

/// The most folders `github.repos.checkout` reads of its `candidates`
/// (`AgentPaneGitHubCheckout.maximumCandidates`).
pub const MAXIMUM_CHECKOUT_CANDIDATES: usize = 16;

/// Every method this table decodes; the host decodes any other itself.
pub fn methods() -> Vec<&'static str> {
    let mut all: Vec<&'static str> = CLOUD_ENVIRONMENT_METHODS
        .iter()
        .chain(CLOUD_RESERVATION_METHODS.iter())
        .chain(CLOUD_REPOSITORY_METHODS.iter())
        .chain(GITHUB_METHODS.iter())
        .chain(pane::PANE_METHODS.iter())
        .chain(host::HOST_METHODS.iter())
        .copied()
        .collect();
    all.sort_unstable();
    all
}

/// One GitHub section request, checked.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "request", rename_all = "camelCase")]
pub enum GitHubRequest {
    Status,
    /// `repo`: a Cloud start's Connect GitHub card for this repository.
    Connect {
        repo: Option<String>,
    },
    /// Open GitHub's account chooser to add another organization.
    AddAccount,
    /// `query`: the picker's search text.
    Repos {
        query: Option<String>,
    },
    /// `repo` as a folder on this Mac: one of `candidates`, else a clone.
    Checkout {
        repo: String,
        candidates: Vec<String>,
        key: String,
    },
    /// Clone a credential-free HTTPS URL on this Mac.
    CloneUrl {
        url: String,
        key: String,
    },
}

/// What one page message asks for.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "case", rename_all = "camelCase")]
pub enum HostOp {
    /// A method this table does not decode yet: the host decodes it.
    Swift,
    /// Refused: no such method, or params it does not take.
    Unsupported { method: String },
    /// `cloud.environment.<action>` with the page's params as they are.
    #[serde(rename_all = "camelCase")]
    CloudEnvironment { action: String, params: Value },
    /// A reserve or release; `params` without the host's own three keys.
    #[serde(rename_all = "camelCase")]
    CloudReservation {
        release: bool,
        params: Value,
        compose_key: Option<String>,
        replaces_chat: Option<String>,
        at_open: bool,
        auto: bool,
    },
    /// A Cloud repository action whose params passed its shape.
    #[serde(rename_all = "camelCase")]
    CloudRepository { method: String, params: Value },
    #[serde(rename_all = "camelCase")]
    GitHub { github: GitHubRequest },
    /// One of the pane's own messages ([`pane::PaneOp`]).
    Pane { pane: pane::PaneOp },
    /// One of the host's own small asks ([`host::HostCall`]).
    Host { host: host::HostCall },
}

/// Decodes one page message (`WKScriptMessage.body` as JSON): an object with
/// a string `method` and an optional object `params` (any other `params` is
/// none, as the Swift host read it).
pub fn decode(body: &Value) -> HostOp {
    let Some(object) = body.as_object() else {
        return unsupported("");
    };
    let Some(method) = object.get("method").and_then(Value::as_str) else {
        return unsupported("");
    };
    decode_method(method, object.get("params").and_then(Value::as_object))
}

/// Decodes `method` with its params object (none when the page sent none).
pub fn decode_method(method: &str, params: Option<&Map<String, Value>>) -> HostOp {
    let decoded = if CLOUD_RESERVATION_METHODS.contains(&method) {
        cloud_reservation(method, params)
    } else if CLOUD_ENVIRONMENT_METHODS.contains(&method) {
        cloud_environment(method, params)
    } else if CLOUD_REPOSITORY_METHODS.contains(&method) {
        cloud_repository(method, params)
    } else if GITHUB_METHODS.contains(&method) {
        github(method, params).map(|github| HostOp::GitHub { github })
    } else if pane::PANE_METHODS.contains(&method) {
        pane::decode(method, params).map(|pane| HostOp::Pane { pane })
    } else if host::HOST_METHODS.contains(&method) {
        host::decode(method, params).map(|host| HostOp::Host { host })
    } else {
        return HostOp::Swift;
    };
    decoded.unwrap_or_else(|| unsupported(method))
}

fn unsupported(method: &str) -> HostOp {
    HostOp::Unsupported { method: method.to_owned() }
}

fn object_or_empty(params: Option<&Map<String, Value>>) -> Map<String, Value> {
    params.cloned().unwrap_or_default()
}

fn cloud_environment(method: &str, params: Option<&Map<String, Value>>) -> Option<HostOp> {
    let action = method.rsplit('.').next()?;
    Some(HostOp::CloudEnvironment {
        action: action.to_owned(),
        params: Value::Object(object_or_empty(params)),
    })
}

fn cloud_reservation(method: &str, params: Option<&Map<String, Value>>) -> Option<HostOp> {
    let mut object = object_or_empty(params);
    let replaces = object.remove("replacesChat");
    let at_open = object.remove("atOpen");
    let auto = object.remove("auto");
    let flag = |value: Option<Value>| -> Option<bool> {
        match value {
            None => Some(false),
            Some(Value::Bool(value)) => Some(value),
            Some(_) => None,
        }
    };
    let at_open = flag(at_open)?;
    let auto = flag(auto)?;
    let replaces_chat = match replaces {
        None => None,
        Some(Value::String(chat)) if !chat.is_empty() && characters(&chat) <= 128 => Some(chat),
        Some(_) => return None,
    };
    let compose_key = object.get("composeKey").and_then(Value::as_str).map(str::to_owned);
    Some(HostOp::CloudReservation {
        release: method == "cloud.releaseReservation",
        params: Value::Object(object),
        compose_key,
        replaces_chat,
        at_open,
        auto,
    })
}

fn cloud_repository(method: &str, params: Option<&Map<String, Value>>) -> Option<HostOp> {
    let object = object_or_empty(params);
    if !repository_params_valid(method, &object) {
        return None;
    }
    Some(HostOp::CloudRepository { method: method.to_owned(), params: Value::Object(object) })
}

/// The shape each Cloud repository action takes (`AgentPaneCloudRepositoryRequest.valid`).
pub fn repository_params_valid(method: &str, object: &Map<String, Value>) -> bool {
    let only = |keys: &[&str]| object.keys().all(|key| keys.contains(&key.as_str()));
    let session_ok =
        || object.get("session").is_none_or(|value| repository_session(value).is_some());
    match method {
        "cloud.repo.local" => object.is_empty(),
        "cloud.repo.sync" => {
            object.get("repos").is_some_and(Value::is_array)
                && only(&["repos", "recent", "complete", "install_url"])
        }
        "cloud.repo.list" | "cloud.repo.attached" => session_ok() && only(&["session", "query"]),
        "cloud.repo.add" => {
            session_ok()
                && object.get("repo").is_some_and(|value| repository_repo(value).is_some())
                && only(&["session", "repo", "ref"])
        }
        "cloud.repo.wait_github" => {
            if !only(&["session", "timeout_ms"]) || !session_ok() {
                return false;
            }
            match object.get("timeout_ms") {
                None => true,
                Some(value) => {
                    integer(value).is_some_and(|timeout| (0..=60_000).contains(&timeout))
                }
            }
        }
        _ => false,
    }
}

/// A chat session id a repository action may name: 1 to 128 of `A-Za-z0-9_.:-`.
pub fn repository_session(value: &Value) -> Option<&str> {
    let text = value.as_str()?;
    let ok = (1..=128).contains(&text.len())
        && text.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.:-".contains(&byte));
    ok.then_some(text)
}

/// A repository `cloud.repo.add` names: non-empty, at most 2048 bytes, no NUL.
pub fn repository_repo(value: &Value) -> Option<&str> {
    let text = value.as_str()?;
    (!text.is_empty() && text.len() <= 2048 && !text.contains('\0')).then_some(text)
}

/// A JSON number that is a whole number under 1e15 (`JSONValue.intValue`).
fn integer(value: &Value) -> Option<i64> {
    if let Some(whole) = value.as_i64() {
        return (whole.unsigned_abs() < 1_000_000_000_000_000).then_some(whole);
    }
    let number = value.as_f64()?;
    (number.round() == number && number.abs() < 1e15).then_some(number as i64)
}

fn github(method: &str, params: Option<&Map<String, Value>>) -> Option<GitHubRequest> {
    let get = |key: &str| params.and_then(|object| object.get(key));
    let absent = |value: Option<&Value>| matches!(value, None | Some(Value::Null));
    match method {
        "github.status" => Some(GitHubRequest::Status),
        "github.connect" => match get("repo") {
            value if absent(value) && get("add_account").and_then(Value::as_bool) == Some(true) => {
                Some(GitHubRequest::AddAccount)
            }
            value if absent(value) => Some(GitHubRequest::Connect { repo: None }),
            Some(Value::String(repo)) if is_github_full_name(repo) => {
                Some(GitHubRequest::Connect { repo: Some(repo.clone()) })
            }
            _ => None,
        },
        "github.repos.list" => match get("query") {
            value if absent(value) => Some(GitHubRequest::Repos { query: None }),
            Some(Value::String(text)) if text.len() <= 1024 && !text.contains('\0') => {
                Some(GitHubRequest::Repos { query: Some(text.clone()) })
            }
            _ => None,
        },
        "repo.clone" => {
            let url = get("url")?.as_str()?;
            let key = get("idempotency_key")?.as_str()?;
            (url.len() <= 4096 && !url.contains('\0') && is_git_write_key(key))
                .then(|| GitHubRequest::CloneUrl { url: url.to_owned(), key: key.to_owned() })
        }
        "github.repos.checkout" => {
            let repo = get("repo")?.as_str().filter(|repo| is_github_full_name(repo))?;
            let key = get("idempotency_key")?.as_str().filter(|key| is_git_write_key(key))?;
            let candidates = match get("candidates") {
                value if absent(value) => Vec::new(),
                Some(Value::Array(list)) => list
                    .iter()
                    .take(MAXIMUM_CHECKOUT_CANDIDATES)
                    .map(|item| {
                        item.as_str()
                            .filter(|path| {
                                path.starts_with('/') && !path.contains('\0') && path.len() <= 4096
                            })
                            .map(str::to_owned)
                    })
                    .collect::<Option<Vec<_>>>()?,
                _ => return None,
            };
            Some(GitHubRequest::Checkout { repo: repo.to_owned(), candidates, key: key.to_owned() })
        }
        _ => None,
    }
}

/// A GitHub `owner/name` (`CloudGitHubRepos.isFullName`): an owner of 1 to 39
/// letters, digits and dashes, not starting or ending with one; a name of 1 to
/// 100 letters, digits, `-`, `.` and `_`, never `.`, `..` or `.git`.
pub fn is_github_full_name(text: &str) -> bool {
    let mut parts = text.split('/');
    let (Some(owner), Some(name), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    (1..=39).contains(&owner.len())
        && (1..=100).contains(&name.len())
        && !matches!(name, "." | ".." | ".git")
        && !owner.starts_with('-')
        && !owner.ends_with('-')
        && owner.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-._".contains(&byte))
}

/// A git write's idempotency key (`AgentPaneGitWrite.isKey`): 1 to 128
/// printable ASCII bytes, no space.
pub fn is_git_write_key(key: &str) -> bool {
    (1..=128).contains(&key.len()) && key.bytes().all(|byte| byte > 0x20 && byte < 0x7F)
}

/// A Cloud environment id as the platform makes them: `env_` and up to 64
/// letters, digits, `_` or `-`.
pub fn is_cloud_environment_id(id: &str) -> bool {
    id.starts_with("env_")
        && (5..=68).contains(&characters(id))
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// An editor id of the editors table: 1 to 32 lowercase ASCII letters, digits or dashes.
pub fn is_editor_id(id: &str) -> bool {
    (1..=32).contains(&id.len())
        && id.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

/// A page's one-time hand-off token: 16 to 64 ASCII letters, digits and dashes.
pub fn is_handoff_token(token: &str) -> bool {
    (16..=64).contains(&characters(token))
        && token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// A GitHub account or org name: 1 to 39 letters, digits and inner dashes.
pub fn is_github_owner(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=39).contains(&bytes.len())
        && bytes.iter().all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
        && bytes.first() != Some(&b'-')
        && bytes.last() != Some(&b'-')
}

/// A GitHub repository's full name as Connect GitHub passes it on: an owner
/// (`is_github_owner`), a name of 1 to 100 letters, digits, `.`, `_` and `-`,
/// never `.` or `..`, 140 bytes at most.
pub fn is_github_repo(value: &str) -> bool {
    if value.len() > 140 {
        return false;
    }
    let mut parts = value.split('/');
    let (Some(owner), Some(name), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    is_github_owner(owner)
        && (1..=100).contains(&name.len())
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        && name != "."
        && name != ".."
}

/// `action.run`'s `sessions` for the action `id`: Evacuate and Bring Back name
/// 1 to 500 chats; a chat-list row's place pick, priority, Cancel or Retry
/// names exactly one, and never alongside `session`. Each id is non-empty, at
/// most 256 characters, and has no comma.
pub fn are_session_targets(sessions: &[String], id: &str, alongside_session: bool) -> bool {
    let usable = sessions
        .iter()
        .all(|session| !session.is_empty() && characters(session) <= 256 && !session.contains(','));
    match id {
        "cloudEvacuate" | "cloudBringBackAll" => usable && (1..=500).contains(&sessions.len()),
        "chatPlace.set" | "chatPriority.set" | "chatMove.cancel" | "chatMove.retry" => {
            usable && sessions.len() == 1 && !alongside_session
        }
        _ => false,
    }
}

#[cfg(test)]
#[path = "host_op_tests.rs"]
mod tests;
