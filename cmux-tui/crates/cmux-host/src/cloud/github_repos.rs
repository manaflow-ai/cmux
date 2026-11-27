//! Read-only GitHub discovery for a Cloud machine. The agent owns the bearer,
//! environment and team; its unprivileged caller supplies only search/cursor.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::github::{refusal, valid_repo};
use super::sender::Answer;

pub const REQUEST_KEY: &str = "github_repos";
const REPOS_PATH: &str = "/v1/connectors/github/repos";
const INSTALL_PATH: &str = "/v1/connectors/github/install";
const CATALOG_PATH: &str = "/v1/connectors/";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReposAsk {
    pub query: Option<String>,
    pub cursor: Option<String>,
}

impl ReposAsk {
    pub fn from_json(value: &Value) -> Result<Self, String> {
        let object = value.as_object().ok_or("Use an object with query and cursor, then retry.")?;
        if object.keys().any(|key| key != "query" && key != "cursor") {
            return Err("Pass only query and cursor; the machine selects its own team.".to_owned());
        }
        let field = |key: &str, max: usize| -> Result<Option<String>, String> {
            match object.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.len() <= max && !s.chars().any(char::is_control) => {
                    Ok(Some(s.clone()))
                }
                _ => Err(format!("Use a {key} string of at most {max} bytes, then retry.")),
            }
        };
        Ok(Self { query: field("query", 256)?, cursor: field("cursor", 4096)? })
    }

    pub fn to_line(&self) -> String {
        json!({REQUEST_KEY: {"query": self.query, "cursor": self.cursor}}).to_string()
    }

    fn path(&self, team: &str) -> String {
        let mut path = team_path(REPOS_PATH, team);
        for (key, value) in [("query", &self.query), ("cursor", &self.cursor)] {
            if let Some(value) = value {
                path.push_str(&format!("&{key}={}", encode(value)));
            }
        }
        path
    }
}

fn encode(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn team_path(path: &str, team: &str) -> String {
    format!("{path}?team={}", encode(team))
}

fn failure(answer: &Answer) -> Value {
    match answer {
        Answer::Transport => refusal(
            "integration.unreachable",
            "Check this machine's connection and retry listing repositories.",
        ),
        Answer::Http { status, body } => {
            let code = match (status, body.get("_tag").and_then(Value::as_str)) {
                (_, Some("ConnectorCursorStale")) => "cursor_stale",
                (403, _) => "repo.no_access",
                (404, _) | (409, Some("ConnectorNeedsAuth")) => "repo.needs_github",
                (429, _) => "rate_limited",
                (400, _) => "request.invalid",
                _ => "integration.unavailable",
            };
            let message = match code {
                "cursor_stale" => {
                    "The repository selection changed. List repositories again from the first page."
                }
                "repo.no_access" => {
                    "Ask your team administrator to allow GitHub access, then retry."
                }
                "repo.needs_github" => "Connect GitHub, then retry adding the repository.",
                "rate_limited" => "GitHub is rate limited. Wait a moment, then retry.",
                "request.invalid" => {
                    "Check the repository search and list again from the first page."
                }
                _ => "The GitHub connector did not answer. Retry listing repositories.",
            };
            refusal(code, message)
        }
    }
}

/// Preserve the denied result even when a policy also denies issuing a link.
/// A user-authorized caller may receive an install URL here; a VM whose
/// upstream grant refuses integration.connect must recover through its Mac.
fn failure_with_install(
    answer: &Answer,
    team: &str,
    get: &mut impl FnMut(&str) -> Answer,
) -> Value {
    let mut reply = failure(answer);
    if reply.pointer("/error/code").and_then(Value::as_str) == Some("repo.no_access")
        && let Answer::Http { status: 200, body } = get(&team_path(INSTALL_PATH, team))
        && let Some(url) =
            body.get("url").and_then(Value::as_str).filter(|url| url.starts_with("https://"))
    {
        reply.set_path(&["error", "install_url"], json!(url));
        reply.set_path(
            &["error", "message"],
            json!("Install GitHub for this organization or request access, then retry."),
        );
    }
    reply
}

fn connect(team: &str, get: &mut impl FnMut(&str) -> Answer) -> Value {
    let answer = get(&team_path(INSTALL_PATH, team));
    match &answer {
        Answer::Http { status: 200, body } => {
            if let Some(url) =
                body.get("url").and_then(Value::as_str).filter(|url| url.starts_with("https://"))
            {
                json!({"ok": true, "repos": [], "connect": {"install_url": url}})
            } else {
                refusal(
                    "integration.bad_answer",
                    "GitHub did not return a connection link. Retry Connect GitHub.",
                )
            }
        }
        // The catalog/list already proved this account needs a link. VM
        // installs cannot issue integration.connect; the linked Mac supplies
        // its user-authorized URL. Preserve that recoverable state rather
        // than turning this expected policy refusal into a failed list.
        Answer::Http { status: 403, .. } => json!({"ok": true, "repos": [], "connect": {}}),
        _ => failure(&answer),
    }
}

/// One page, preserving the opaque next cursor. A connected account with
/// zero repos remains connected; it is never confused with a missing link.
/// The caller follows `next_cursor` until absent before resolving a name.
pub fn answer(ask: &ReposAsk, team: &str, mut get: impl FnMut(&str) -> Answer) -> Value {
    let catalog = get(&team_path(CATALOG_PATH, team));
    match &catalog {
        Answer::Http { status: 200, body } => {
            let state = body
                .get("connectors")
                .and_then(Value::as_array)
                .and_then(|rows| {
                    rows.iter()
                        .find(|row| row.get("provider").and_then(Value::as_str) == Some("github"))
                })
                .and_then(|row| row.get("state"))
                .and_then(Value::as_str);
            match state {
                Some("available" | "needs-auth" | "expired") => return connect(team, &mut get),
                Some("installed") => {}
                _ => {
                    return refusal(
                        "integration.unavailable",
                        "GitHub is unavailable. Retry listing repositories.",
                    );
                }
            }
        }
        _ => return failure_with_install(&catalog, team, &mut get),
    }
    let listed = get(&ask.path(team));
    match &listed {
        Answer::Http { status: 200, body } => {
            let Some(rows) = body.get("repos").and_then(Value::as_array) else {
                return refusal(
                    "integration.bad_answer",
                    "GitHub returned an invalid repository list. Retry listing repositories.",
                );
            };
            let mut repos = Vec::with_capacity(rows.len());
            for row in rows {
                let name =
                    row.get("fullName").and_then(Value::as_str).filter(|name| valid_repo(name));
                let private = row.get("private").and_then(Value::as_bool);
                let (Some(name), Some(private)) = (name, private) else {
                    return refusal(
                        "integration.bad_answer",
                        "GitHub returned an invalid repository. Retry listing repositories.",
                    );
                };
                repos.push(json!({"fullName": name, "private": private}));
            }
            let mut reply = json!({"ok": true, "repos": repos});
            match body.get("cursor") {
                None | Some(Value::Null) => {}
                Some(Value::String(cursor)) if !cursor.is_empty() => {
                    reply.set("next_cursor", json!(cursor));
                }
                _ => {
                    return refusal(
                        "integration.bad_answer",
                        "GitHub returned an invalid cursor. List repositories again from the first page.",
                    );
                }
            }
            reply
        }
        Answer::Http { status: 404, .. } => connect(team, &mut get),
        Answer::Http { status: 409, body }
            if body.get("_tag").and_then(Value::as_str) == Some("ConnectorNeedsAuth") =>
        {
            connect(team, &mut get)
        }
        _ => failure_with_install(&listed, team, &mut get),
    }
}
