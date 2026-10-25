//! GitHub tokens for the machine's own git and `gh` (sans I/O): the agent
//! socket line `{"github_token": {"repo", "permissions", "label"?}}`, the
//! Cloud API request it becomes (`POST /v1/integrations/github/token` as
//! this machine's `vm` install), and the one reply line the agent writes
//! back on the same connection.
//!
//! The bearer never leaves the agent (root): a process on the machine gets
//! only the short-lived, repo-scoped GitHub token, and only for itself. The
//! agent does not keep the token, write it anywhere or log it; the API
//! caches and audits each mint.

use crate::json::JsonField;
use serde_json::{Map, Value, json};

use super::sender::Answer;

/// The Cloud API route (backend/apps/api, the token endpoint contract).
pub const TOKEN_PATH: &str = "/v1/integrations/github/token";

/// The socket line's key.
pub const REQUEST_KEY: &str = "github_token";

/// The permission names the endpoint accepts; each value is read or write.
pub const PERMISSION_NAMES: [&str; 8] = [
    "contents",
    "pull_requests",
    "issues",
    "workflows",
    "checks",
    "actions",
    "statuses",
    "metadata",
];

/// One checked ask: an `owner/name` repo and a non-empty permission set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TokenAsk {
    pub repo: String,
    pub permissions: Map<String, Value>,
    pub label: Option<String>,
}

/// `owner/name` with GitHub's own characters (no `..`, no slashes inside).
pub fn valid_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else { return false };
    let owner_ok = !owner.is_empty()
        && owner.len() <= 39
        && owner.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    let name_ok = !name.is_empty()
        && name.len() <= 100
        && name != "."
        && name != ".."
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b));
    owner_ok && name_ok
}

fn valid_label(label: &str) -> bool {
    !label.is_empty()
        && label.len() <= 64
        && label.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

impl TokenAsk {
    /// The `github_token` object of a socket line, refused unless every
    /// field has the contract's shape (the API checks again).
    pub fn from_json(v: &Value) -> Result<TokenAsk, String> {
        let repo = v.field("repo").as_str().unwrap_or("");
        if !valid_repo(repo) {
            return Err("repo must be owner/name".to_owned());
        }
        let Some(asked) = v.field("permissions").as_object().filter(|p| !p.is_empty()) else {
            return Err("permissions must be a non-empty object".to_owned());
        };
        for (name, level) in asked {
            if !PERMISSION_NAMES.contains(&name.as_str()) {
                return Err(format!("unknown permission {name}"));
            }
            if !matches!(level.as_str(), Some("read" | "write")) {
                return Err(format!("permission {name} must be read or write"));
            }
        }
        let label = match v.field("label") {
            Value::Null => None,
            Value::String(s) if valid_label(s) => Some(s.clone()),
            _ => return Err("label must be 1-64 of [A-Za-z0-9._-]".to_owned()),
        };
        Ok(TokenAsk { repo: repo.to_owned(), permissions: asked.clone(), label })
    }

    /// The socket line a client sends.
    pub fn to_line(&self) -> String {
        let mut ask = json!({ "repo": self.repo, "permissions": self.permissions });
        if let Some(label) = &self.label {
            ask["label"] = json!(label);
        }
        json!({ REQUEST_KEY: ask }).to_string()
    }

    /// The API request body for a machine of `team`.
    pub fn api_body(&self, team: &str) -> Value {
        let mut body = json!({ "team": team, "repo": self.repo, "permissions": self.permissions });
        if let Some(label) = &self.label {
            body["label"] = json!(label);
        }
        body
    }

    /// `repo contents:write,...` for the journal (never a token).
    pub fn describe(&self) -> String {
        let perms: Vec<String> = self
            .permissions
            .iter()
            .map(|(k, v)| format!("{k}:{}", v.as_str().unwrap_or("")))
            .collect();
        format!("{} {}", self.repo, perms.join(","))
    }
}

/// A refusal reply (`ok: false`) with the API's error code and message.
pub fn refusal(code: &str, message: &str) -> Value {
    json!({ "ok": false, "error": { "code": code, "message": message } })
}

/// The reply line for the API's answer: the token and its expiry, or the
/// API's error (code, message, HTTP status, `retry_after` when given).
pub fn reply_for(answer: &Answer) -> Value {
    match answer {
        Answer::Http { status: 200, body } => {
            let token = body.field("token").as_str().filter(|t| !t.is_empty());
            let expires = body.field("expires_at").as_str();
            match (token, expires) {
                (Some(token), Some(expires)) => json!({
                    "ok": true,
                    "token": token,
                    "expires_at": expires,
                    "repo": body.field("repo"),
                    "permissions": body.field("permissions"),
                }),
                _ => refusal("integration.bad_answer", "the API answered without a token"),
            }
        }
        Answer::Http { status, body } => {
            let error = body.field("error");
            let code = error
                .field("code")
                .as_str()
                .map_or_else(|| format!("http.{status}"), str::to_owned);
            // The contract keeps tokens out of messages; cap the length anyway.
            let message: String =
                error.field("message").as_str().unwrap_or("").chars().take(300).collect();
            let mut out = refusal(&code, &message);
            out["status"] = json!(status);
            let retry = body.field("retry_after").as_u64().or(error.field("retry_after").as_u64());
            if let Some(retry) = retry {
                out["retry_after"] = json!(retry);
            }
            out
        }
        Answer::Transport => {
            refusal("integration.unreachable", "the cmux Cloud API did not answer")
        }
    }
}

/// A journal line for one answer: status and code only.
pub fn note_for(ask: &TokenAsk, reply: &Value) -> String {
    let outcome = if *reply.field("ok") == true {
        "minted".to_owned()
    } else {
        format!("refused {}", reply.field("error").field("code").as_str().unwrap_or("?"))
    };
    format!("github token {}: {outcome}", ask.describe())
}
