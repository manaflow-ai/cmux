//! Read-only GitHub discovery for a Cloud machine. The agent owns the bearer,
//! environment and team; its unprivileged caller supplies only search/cursor.
//!
//! The listing is cmux-api's `GET /v1/integrations/github/repos` as this
//! machine's `vm` install, the route that answers a machine in every
//! environment under the same gate as its token mint (the platform's
//! `/v1/connectors/github/repos` is off on staging and never listed for a
//! machine outside development). A machine cannot issue `integration.connect`,
//! so a missing or expired link answers `connect: {}` and the linked Mac
//! supplies the install link.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::github::{refusal, valid_repo};
use super::sender::Answer;

pub const REQUEST_KEY: &str = "github_repos";
const REPOS_PATH: &str = "/v1/integrations/github/repos";

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

/// The machine is not linked to GitHub (or the link needs renewing): a
/// recoverable state with no list, never a failure.
fn connect() -> Value {
    json!({"ok": true, "repos": [], "connect": {}})
}

fn failure(answer: &Answer) -> Value {
    match answer {
        Answer::Transport => refusal(
            "integration.unreachable",
            "Check this machine's connection and retry listing repositories.",
        ),
        Answer::Http { status, body } => {
            let error = body.get("error");
            let api_code = error.and_then(|e| e.get("code")).and_then(Value::as_str);
            let api_message =
                error.and_then(|e| e.get("message")).and_then(Value::as_str).unwrap_or("");
            let code = match (status, api_code) {
                (400, _) if api_message.contains("cursor") => "cursor_stale",
                (403, Some("policy.denied")) => "repo.no_access",
                (429, _) => "rate_limited",
                (400, _) => "request.invalid",
                (401, _) => "auth.required",
                (403, _) => "auth.forbidden",
                _ => "integration.unavailable",
            };
            let message = match code {
                "cursor_stale" => {
                    "The repository selection changed. List repositories again from the first page."
                }
                "repo.no_access" => {
                    "Ask your team administrator to allow GitHub access, then retry."
                }
                "rate_limited" => "GitHub is rate limited. Wait a moment, then retry.",
                "request.invalid" => {
                    "Check the repository search and list again from the first page."
                }
                "auth.required" => {
                    "This machine's cmux Cloud sign-in needs renewing. Reconnect to the machine, then retry."
                }
                // Not a sign-in to renew: the machine is not live, or it, its team or the person may not use GitHub.
                "auth.forbidden" => {
                    "cmux Cloud refused GitHub for this machine. Check that it is running and you are still in its team, then retry."
                }
                _ => "GitHub did not answer. Retry listing repositories.",
            };
            let mut reply = refusal(code, message);
            if let Some(retry) = body.get("retry_after").and_then(Value::as_u64) {
                reply.set("retry_after", json!(retry));
            }
            reply
        }
    }
}

/// One page, preserving the opaque next cursor. A connected account with
/// zero repos remains connected; it is never confused with a missing link.
/// The caller follows `next_cursor` until absent before resolving a name.
/// Rows keep the socket's `fullName` / `private` shape.
pub fn answer(ask: &ReposAsk, team: &str, mut get: impl FnMut(&str) -> Answer) -> Value {
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
                    row.get("full_name").and_then(Value::as_str).filter(|name| valid_repo(name));
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
        Answer::Http { status: 404 | 409, body }
            if matches!(
                body.get("error").and_then(|e| e.get("code")).and_then(Value::as_str),
                Some("integration.not_found" | "needs_reauth")
            ) =>
        {
            connect()
        }
        _ => failure(&listed),
    }
}
