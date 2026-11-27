//! `gh auth status` and `gh api user` on a cmux Cloud machine where the
//! person has no gh login of their own: the image's `gh` shim
//! (`cmux github gh --auto`) answers them from the GitHub account the
//! person's cmux team connected, never with a token.
//!
//! The shim only mints a token for one repository, so with no repo (a chat
//! with no folder) plain gh sees no login and an agent that asks it
//! "can you see my GitHub" would wrongly say no. The answer comes from the
//! same source as acpmux's `github_status` tool: the machine agent's
//! `{"github_status": {}}` socket line (`cloud/github_status.rs`, which
//! reads cmux-platform `GET /v1/me/github` with this machine's bearer). Its
//! reply is checked again with the same field check (`sanitize`), so a
//! token the source sends never reaches stdout or stderr.
//!
//! Only those two questions, in the forms below, are answered; any other gh
//! run, and these when the agent gives no answer, keep the shim's behaviour.

use std::io::Write;
use std::path::Path;
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::cloud::github_status::{REQUEST_KEY, sanitize};
use crate::github_cli::{Refused, agent_reply, refused};

/// The agent answers a status read within this (one platform read).
const STATUS_WAIT: Duration = Duration::from_secs(30);

/// An identity question gh would otherwise answer with no login.
#[derive(Debug, PartialEq, Eq)]
pub enum IdentityAsk {
    /// `gh auth status [-a] [-t] [-h github.com]`.
    AuthStatus,
    /// `gh api user` or `gh api /user`, with an optional `--jq` filter.
    User { jq: Option<String> },
}

/// What the shim prints and exits with in place of gh.
#[derive(Debug, PartialEq, Eq)]
pub struct Answered {
    pub stdout: String,
    pub stderr: String,
    pub code: u8,
}

impl Answered {
    /// Writes both streams and returns the exit code.
    pub fn emit(&self) -> u8 {
        let _ = std::io::stdout().write_all(self.stdout.as_bytes());
        let _ = std::io::stdout().flush();
        let _ = std::io::stderr().write_all(self.stderr.as_bytes());
        self.code
    }
}

fn github_host(host: Option<&String>) -> bool {
    host.is_some_and(|h| h.eq_ignore_ascii_case("github.com"))
}

/// Whether `hosts.yml` may hold a login for any host: any string key of its root mapping (a host), or a file the shared
/// YAML reader (`github_cli::parse_gh_hosts`) cannot parse; blank lines, comments, document
/// markers (`---`, `...`) and an empty `{}` are none. So a GitHub
/// Enterprise login, an indented root mapping, or a login in any other form gh reads keeps
/// gh's own answer. Unsure means yes.
pub fn hosts_has_any_login(hosts_yml: &str) -> bool {
    crate::github_cli::parse_gh_hosts(hosts_yml).any_login()
}

/// Whether the shim may answer an identity question from cmux's connection: only when the
/// person has no gh auth of their own (no token in the env, no login for any host in
/// `hosts.yml`), `GH_HOST` names no other host than github.com, and the caller did not ask
/// for the own gh login only (`GH_OWN_LOGIN_ONLY_ENV`, set by acpmux's `github_status`).
pub fn identity_applies(
    token_env: bool,
    hosts_yml: Option<&str>,
    gh_host: Option<&str>,
    own_login_only: bool,
) -> bool {
    !token_env
        && !own_login_only
        && gh_host.is_none_or(|h| h.is_empty() || h.eq_ignore_ascii_case("github.com"))
        && !hosts_yml.is_some_and(hosts_has_any_login)
}

/// The identity question `args` (gh's own arguments) asks, if it is one this
/// answers. Any flag outside the listed ones leaves it to gh.
pub fn identity_ask(args: &[String]) -> Option<IdentityAsk> {
    let (verb, rest) = args.split_first()?;
    let mut it = rest.iter();
    match verb.as_str() {
        "auth" => {
            if it.next()? != "status" {
                return None;
            }
            while let Some(arg) = it.next() {
                match arg.as_str() {
                    "-a" | "--active" | "-t" | "--show-token" => {}
                    "-h" | "--hostname" => {
                        if !github_host(it.next()) {
                            return None;
                        }
                    }
                    a if a.starts_with("--hostname=") => {
                        if !github_host(Some(&a.strip_prefix("--hostname=")?.to_owned())) {
                            return None;
                        }
                    }
                    _ => return None,
                }
            }
            Some(IdentityAsk::AuthStatus)
        }
        "api" => {
            let mut endpoint = None;
            let mut jq = None;
            while let Some(arg) = it.next() {
                match arg.as_str() {
                    "-q" | "--jq" => jq = Some(it.next()?.clone()),
                    "-X" | "--method" => {
                        if !it.next()?.eq_ignore_ascii_case("GET") {
                            return None;
                        }
                    }
                    "--hostname" => {
                        if !github_host(it.next()) {
                            return None;
                        }
                    }
                    a if a.starts_with("--jq=") => jq = Some(a.strip_prefix("--jq=")?.to_owned()),
                    a if a.starts_with("--method=") => {
                        if !a.strip_prefix("--method=")?.eq_ignore_ascii_case("GET") {
                            return None;
                        }
                    }
                    a if a.starts_with('-') => return None,
                    a if endpoint.is_none() => endpoint = Some(a),
                    _ => return None,
                }
            }
            matches!(endpoint, Some("user" | "/user")).then_some(IdentityAsk::User { jq })
        }
        _ => None,
    }
}

/// The checked status from the agent's reply line, or why there is none.
pub fn status_from_reply(reply: &Value) -> Result<Value, Refused> {
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(sanitize(reply));
    }
    let error = reply.get("error");
    let text = |k: &str| error.and_then(|e| e.get(k)).and_then(Value::as_str).unwrap_or("");
    let code = if text("code").is_empty() { "vm.agent_bad_answer" } else { text("code") };
    // The message is the agent's fixed text; it is still never echoed if it
    // looks like a credential.
    let message = text("message");
    let message = if crate::cloud::github_status::looks_secret(message) { "" } else { message };
    Err(refused(code, message))
}

fn connected_login(status: &Value) -> Option<&str> {
    (status.get("connected").and_then(Value::as_bool) == Some(true))
        .then(|| status.get("login").and_then(Value::as_str))
        .flatten()
}

fn field<'a>(status: &'a Value, key: &str) -> Option<&'a str> {
    status.get(key).and_then(Value::as_str)
}

fn not_connected_note(status: &Value) -> String {
    match field(status, "connectUrl") {
        Some(url) => format!(
            "cmux: this machine's cmux team has no GitHub connection; connect GitHub in cmux ({url})\n"
        ),
        None => "cmux: this machine's cmux team has no GitHub connection; connect GitHub in cmux\n"
            .to_owned(),
    }
}

/// `gh auth status`, shaped like gh's, for a checked status.
pub fn auth_status(status: &Value) -> Answered {
    let Some(login) = connected_login(status) else {
        return Answered {
            stdout: String::new(),
            stderr: format!(
                "You are not logged into any GitHub hosts. To log in, run: gh auth login\n{}",
                not_connected_note(status)
            ),
            code: 1,
        };
    };
    let how = match field(status, "source") {
        Some("oauth") => "cmux GitHub sign-in",
        _ => "GitHub App installation",
    };
    let mut out = format!("github.com\n  ✓ Connected through cmux as {login} ({how})\n");
    match field(status, "accountType") {
        Some("organization") => {
            out.push_str("  - Account type: Organization (connected by your cmux team)\n");
        }
        Some("user") => out.push_str("  - Account type: User\n"),
        _ => {}
    }
    let repos = status.get("repositories");
    if let Some(count) = repos.and_then(|r| r.get("count")).and_then(Value::as_u64) {
        let line = match repos.and_then(|r| r.get("selection")).and_then(Value::as_str) {
            Some("all") => format!("all ({count})"),
            Some("selected") => format!("{count} selected"),
            _ => count.to_string(),
        };
        out.push_str(&format!("  - Repositories: {line}\n"));
    }
    out.push_str("  - Git operations protocol: https\n");
    out.push_str(
        "  - Token: none on this machine; cmux mints a short-lived token per repository when gh or git needs one\n",
    );
    Answered { stdout: out, stderr: String::new(), code: 0 }
}

/// The REST user object `gh api user` prints, from a checked status.
pub fn user_object(login: &str, status: &Value) -> Value {
    let mut user = Map::new();
    user.insert("login".into(), json!(login));
    let html = field(status, "htmlUrl")
        .map_or_else(|| format!("https://github.com/{login}"), str::to_owned);
    user.insert("html_url".into(), json!(html));
    if let Some(avatar) = field(status, "avatarUrl") {
        user.insert("avatar_url".into(), json!(avatar));
    }
    if let Some(name) = field(status, "name") {
        user.insert("name".into(), json!(name));
    }
    match field(status, "accountType") {
        Some("organization") => {
            user.insert("type".into(), json!("Organization"));
        }
        Some("user") => {
            user.insert("type".into(), json!("User"));
        }
        _ => {}
    }
    Value::Object(user)
}

/// `.` or `.field` (also `.["field"]`) over `value`, printed as gh's `--jq`
/// prints: strings raw, anything else as JSON, a missing field as `null`.
pub fn jq_path(value: &Value, filter: &str) -> Option<String> {
    let filter = filter.trim();
    if filter == "." {
        return Some(value.to_string());
    }
    let key = filter.strip_prefix('.')?;
    let key = key.strip_prefix("[\"").and_then(|k| k.strip_suffix("\"]")).unwrap_or(key);
    if key.is_empty() || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return None;
    }
    Some(match value.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
        None => "null".to_owned(),
    })
}

/// `gh api user`, shaped like gh's, for a checked status.
pub fn api_user(status: &Value, jq: Option<&str>) -> Answered {
    let Some(login) = connected_login(status) else {
        return Answered {
            stdout: "{\"message\":\"Requires authentication\",\"documentation_url\":\"https://docs.github.com/rest\",\"status\":\"401\"}".to_owned(),
            stderr: format!("gh: Requires authentication (HTTP 401)\n{}", not_connected_note(status)),
            code: 1,
        };
    };
    let user = user_object(login, status);
    match jq {
        None => Answered { stdout: format!("{user}\n"), stderr: String::new(), code: 0 },
        Some(filter) => match jq_path(&user, filter) {
            Some(out) => Answered { stdout: format!("{out}\n"), stderr: String::new(), code: 0 },
            None => Answered {
                stdout: String::new(),
                stderr: format!(
                    "cmux github gh: this machine answers `gh api user` from cmux's GitHub connection, and its --jq takes only `.` or `.FIELD` (fields: {})\n",
                    user.as_object()
                        .map(|o| o.keys().cloned().collect::<Vec<_>>().join(", "))
                        .unwrap_or_default()
                ),
                code: 1,
            },
        },
    }
}

/// The answer for `ask` from a checked status.
pub fn answer(ask: &IdentityAsk, status: &Value) -> Answered {
    match ask {
        IdentityAsk::AuthStatus => auth_status(status),
        IdentityAsk::User { jq } => api_user(status, jq.as_deref()),
    }
}

/// `None` when `args` is not an identity question; else the answer from
/// the agent at `socket`, or (`Err`) a note on why there is none, after
/// which gh runs as it would have.
pub fn answer_from_agent(args: &[String], socket: &Path) -> Option<Result<Answered, String>> {
    let ask = identity_ask(args)?;
    if !socket.exists() {
        return Some(Err(format!("no cmux Cloud agent at {}", socket.display())));
    }
    let line = json!({ REQUEST_KEY: {} }).to_string();
    let status =
        agent_reply(socket, &line, STATUS_WAIT).and_then(|reply| status_from_reply(&reply));
    Some(match status {
        Ok(status) => Ok(answer(&ask, &status)),
        Err(e) => Err(format!("cmux could not read its GitHub connection ({e}); gh runs as usual")),
    })
}

#[cfg(test)]
#[path = "github_cli_identity_tests.rs"]
mod tests;
