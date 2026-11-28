//! Which GitHub account the person connected to cmux, for an agent on this
//! Cloud machine (sans I/O): the agent socket line `{"github_status": {}}`,
//! the platform read it becomes (`GET /v1/me/github` as this machine's `vm`
//! install, the same bearer `github_repos` uses), and the one reply line.
//!
//! The connection is the cmux team's GitHub App installation: `login` is the installation's
//! account, the person's own for a personal install or an organization's (`accountType`).
//!
//! The reply holds only the account's public profile fields the contract
//! names, each checked: never a token, whatever the platform answers. The
//! caller supplies nothing; the machine picks its own origin and bearer.

use serde_json::{Map, Value, json};

use super::github::refusal;
use super::sender::Answer;

/// The socket line's key.
pub const REQUEST_KEY: &str = "github_status";
/// The platform route (cmux-platform `GET /v1/me/github`).
pub const STATUS_PATH: &str = "/v1/me/github";
/// Set (to `1`) on a `gh` run that asks for this machine's own gh login only: the Cloud `gh`
/// shim then never answers `gh auth status` / `gh api user` from cmux's connection
/// (`github_cli_identity.rs`), so acpmux's `github_status` does not count the team's account
/// twice, once as the person's own gh login.
pub const GH_OWN_LOGIN_ONLY_ENV: &str = "CMUX_GITHUB_GH_OWN_LOGIN_ONLY";

/// The `github_status` object of a socket line: it takes no fields, so a
/// caller cannot steer the read.
pub fn check_ask(value: &Value) -> Result<(), String> {
    match value {
        Value::Null => Ok(()),
        Value::Object(fields) if fields.is_empty() => Ok(()),
        _ => Err("github_status takes no fields; the machine reads its own account.".to_owned()),
    }
}

/// A GitHub login: 1 to 39 letters, digits or single hyphens.
pub fn valid_login(login: &str) -> bool {
    !login.is_empty()
        && login.len() <= 39
        && !login.starts_with('-')
        && login.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Whether `text` looks like it carries a GitHub or bearer credential.
pub fn looks_secret(text: &str) -> bool {
    const PREFIXES: [&str; 7] = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "v1."];
    let lower = text.to_ascii_lowercase();
    PREFIXES.iter().any(|p| lower.contains(p))
        || lower.contains("bearer ")
        || lower.contains("token")
        || text.split(|c: char| !c.is_ascii_alphanumeric()).any(|word| word.len() >= 32)
}

/// A display string: bounded, no control characters, nothing that looks
/// like a credential.
fn plain(value: Option<&Value>, max: usize) -> Option<String> {
    let text = value?.as_str()?.trim();
    (!text.is_empty()
        && text.len() <= max
        && !text.chars().any(char::is_control)
        && !looks_secret(text))
    .then(|| text.to_owned())
}

/// An https URL on `hosts`, bounded, with no query that could carry a secret.
fn url_on(value: Option<&Value>, hosts: &[&str]) -> Option<String> {
    let text = value?.as_str()?.trim();
    let rest = text.strip_prefix("https://")?;
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    (text.len() <= 512
        && hosts.contains(&host)
        && !text.chars().any(|c| c.is_control() || c.is_whitespace())
        && !looks_secret(text))
    .then(|| text.to_owned())
}

/// The reply for a contract body: only its named fields, each checked.
pub fn sanitize(body: &Value) -> Value {
    let mut out = Map::new();
    out.insert("ok".into(), json!(true));
    let login = body.get("login").and_then(Value::as_str).filter(|l| valid_login(l));
    let connected = body.get("connected").and_then(Value::as_bool) == Some(true) && login.is_some();
    out.insert("connected".into(), json!(connected));
    if connected {
        out.insert("login".into(), json!(login));
        if let Some(name) = plain(body.get("name"), 255) {
            out.insert("name".into(), json!(name));
        }
        if let Some(url) = url_on(body.get("htmlUrl"), &["github.com"]) {
            out.insert("htmlUrl".into(), json!(url));
        }
        if let Some(url) =
            url_on(body.get("avatarUrl"), &["github.com", "avatars.githubusercontent.com"])
        {
            out.insert("avatarUrl".into(), json!(url));
        }
        if let Some(kind @ ("user" | "organization")) =
            body.get("accountType").and_then(Value::as_str)
        {
            out.insert("accountType".into(), json!(kind));
        }
        if let Some(source @ ("github-app" | "oauth")) = body.get("source").and_then(Value::as_str)
        {
            out.insert("source".into(), json!(source));
        }
        if let Some(repos) = body.get("repositories") {
            let count = repos.get("count").and_then(Value::as_u64);
            let selection = repos
                .get("selection")
                .and_then(Value::as_str)
                .filter(|s| matches!(*s, "all" | "selected"));
            if let Some(count) = count {
                let mut r = Map::new();
                r.insert("count".into(), json!(count));
                if let Some(selection) = selection {
                    r.insert("selection".into(), json!(selection));
                }
                out.insert("repositories".into(), Value::Object(r));
            }
        }
    } else if let Some(url) =
        url_on(body.get("connectUrl"), &["github.com", "cmux.com", "cmux.dev"])
    {
        out.insert("connectUrl".into(), json!(url));
    }
    Value::Object(out)
}

/// The reply for the platform's answer to `GET /v1/me/github`.
pub fn reply_for(answer: &Answer) -> Value {
    match answer {
        Answer::Http { status: 200, body } if body.is_object() => sanitize(body),
        Answer::Http { status: 200, .. } => {
            refusal("integration.bad_answer", "cmux did not return a GitHub status.")
        }
        Answer::Http { status: 401 | 403, .. } => {
            refusal("auth.refused", "cmux refused this machine's GitHub status read.")
        }
        Answer::Http { status: 404, .. } => {
            refusal("integration.unavailable", "cmux has no GitHub status route here yet.")
        }
        Answer::Http { status: 429, .. } => {
            refusal("rate_limited", "cmux is rate limited. Wait a moment, then retry.")
        }
        Answer::Http { .. } => {
            refusal("integration.unavailable", "cmux did not answer the GitHub status read.")
        }
        Answer::Transport => refusal(
            "integration.unreachable",
            "Check this machine's connection and retry the GitHub status read.",
        ),
    }
}
