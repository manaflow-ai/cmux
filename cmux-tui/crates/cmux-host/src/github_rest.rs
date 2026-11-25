//! The GitHub host op: the fixed set of GitHub calls the Mac app's own GitHub features make (the
//! pull request page, its checks, merge and re-run, the PR chip, Create PR's lookups), as data.
//!
//! The Mac app used to spawn the person's `gh` for each of these, so a person who connected the
//! cmux GitHub App but never ran `gh auth login` had no PR page, no merge and no checks. acpmux
//! now runs them (`acpmux/src/github_rest_op.rs`, the `_acpmux/github_rest` request on the unix
//! socket, the person's own app only): with a token cmux Cloud mints for the cmux GitHub App
//! (`POST /v1/integrations/github/token`, the route Cloud machines use) for that one repository
//! and only the permissions the op's [`Scope`] names, and with the person's `gh` only when no cmux
//! sign-in is lent or the App cannot cover the repository.
//!
//! This module is the op table and nothing that touches the network: [`plan`] checks one op's
//! params and turns them into one HTTP call against `api.github.com` (a [`Plan`]); [`gh_args`]
//! is the same call as `gh api` for the fallback. An op names its repository, and every path it
//! reaches is under that repository (or GraphQL, which the minted token limits to it), so a token
//! minted for `owner/name` is only ever sent about `owner/name`.

use serde_json::{Value, json};

/// The most of a query, a variables object or a written body taken.
pub const TEXT_MAX: usize = 64 * 1024;
/// The most of GitHub's answer kept. A job's whole log can be far longer: a tail op keeps its end.
pub const BODY_MAX: usize = 8 * 1024 * 1024;
/// How long one op may take, mint aside.
pub const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);
const REPO_MAX: usize = 140;

/// What the minted token may do: each is the least the op's calls need, and no op asks for
/// `workflows`, `administration` or `contents: write` beyond a merge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// A pull request and what it links: its body, reviews, threads, labels, closing issues.
    Pulls,
    /// Its checks: check runs, commit statuses, Actions jobs and their logs.
    Checks,
    /// Merge one pull request (GitHub's merge endpoint needs contents and pull requests write).
    Merge,
    /// Re-run an Actions run's failed jobs.
    Rerun,
    /// A pull request review, a reply in a review thread, resolving one (pull requests write).
    Review,
    /// The repository's issues and their comments (read).
    Issues,
}

impl Scope {
    /// The App permissions this scope asks cmux Cloud for.
    pub fn permissions(self) -> Value {
        match self {
            Self::Pulls => json!({"metadata": "read", "pull_requests": "read", "issues": "read"}),
            Self::Checks => json!({"metadata": "read", "pull_requests": "read", "checks": "read",
                "statuses": "read", "actions": "read"}),
            Self::Merge => {
                json!({"metadata": "read", "contents": "write", "pull_requests": "write"})
            }
            Self::Rerun => json!({"metadata": "read", "actions": "write"}),
            Self::Review => json!({"metadata": "read", "pull_requests": "write"}),
            Self::Issues => json!({"metadata": "read", "issues": "read"}),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Pulls => "pulls",
            Self::Checks => "checks",
            Self::Merge => "merge",
            Self::Rerun => "rerun",
            Self::Review => "review",
            Self::Issues => "issues",
        }
    }

    /// Whether the op changes something on GitHub (a click spent it; never retried).
    pub fn writes(self) -> bool {
        matches!(self, Self::Merge | Self::Rerun | Self::Review)
    }
}

/// One checked GitHub call.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    /// The op's name, for the log line (never its params).
    pub op: &'static str,
    /// `owner/name`, the repository the token is minted for.
    pub repo: String,
    pub scope: Scope,
    pub method: &'static str,
    /// The API path: `graphql`, or `repos/{repo}/...` with its query string.
    pub path: String,
    pub body: Option<Value>,
    /// Only the last this many bytes of the answer (a job's log): a `Range` header, and the end
    /// kept when the server sends the whole of it.
    pub tail: Option<u64>,
    /// Who it is said by: [`Author::Person`] runs with the person's own `gh` first (a review or a
    /// reply is theirs), and with the App only when that has no login.
    pub author: Author,
}

/// Whose words or verdict a write is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Author {
    /// Anyone's: the App first (a read, a merge, a re-run).
    Any,
    /// The person's, which the App may say for them as cmux when `gh` has no login (a comment
    /// review, a thread reply, resolving a thread).
    Person,
    /// The person's alone: an approval or a request for changes counts toward a branch's
    /// required reviews, so the App never gives one.
    PersonOnly,
}

impl Plan {
    /// The URL on `api` (`https://api.github.com` outside tests).
    /// The `Accept` header: a GraphQL read also takes the merge-info preview, which GitHub's
    /// `mergeStateStatus` still sits under (as `gh pr view` asks it).
    pub fn accept(&self) -> &'static str {
        if self.path == "graphql" {
            "application/vnd.github.merge-info-preview+json, application/vnd.github+json"
        } else {
            "application/vnd.github+json"
        }
    }

    pub fn url(&self, api: &str) -> String {
        format!("{}/{}", api.trim_end_matches('/'), self.path)
    }
}

fn invalid(message: impl Into<String>) -> String {
    message.into()
}

/// `owner/name` with GitHub's own characters, no leading `-` (gh would read it as a flag).
pub fn valid_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else { return false };
    !owner.is_empty()
        && !owner.starts_with('-')
        && !name.is_empty()
        && !name.starts_with('-')
        && repo.len() <= REPO_MAX
        && owner.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
        && name != "."
        && name != ".."
}

fn text<'a>(params: &'a Value, key: &str) -> Result<&'a str, String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.len() <= TEXT_MAX && !v.contains('\0'))
        .ok_or_else(|| invalid(format!("{key} must be 1..{TEXT_MAX} bytes of text")))
}

fn number(params: &Value, key: &str) -> Result<u64, String> {
    params
        .get(key)
        .and_then(Value::as_u64)
        .filter(|n| *n > 0)
        .ok_or_else(|| invalid(format!("{key} must be a positive number")))
}

fn commit(params: &Value, key: &str) -> Result<String, String> {
    let head = text(params, key)?;
    if (head.len() == 40 || head.len() == 64) && head.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(head.to_ascii_lowercase())
    } else {
        Err(invalid(format!("{key} must be a full commit id")))
    }
}

/// A GraphQL document that only reads: its first word is `query` (or it is a bare selection),
/// and it never names a mutation or a subscription anywhere, since a document may hold several
/// operations.
fn read_only_query(query: &str) -> bool {
    let start = query.trim_start();
    let first = start.split(|c: char| !c.is_ascii_alphanumeric() && c != '_').next().unwrap_or("");
    let words = query.split(|c: char| !c.is_ascii_alphanumeric() && c != '_');
    (first == "query" || start.starts_with('{'))
        && !words.clone().any(|w| w == "mutation" || w == "subscription")
}

/// A path under a repository: segments of GitHub's path characters, and a query of plain
/// `key=value` pairs (a branch name in `head=owner:branch`).
fn valid_subpath(path: &str) -> bool {
    let (segments, query) = path.split_once('?').unwrap_or((path, ""));
    let segment_ok = |s: &str| {
        !s.is_empty()
            && s != "."
            && s != ".."
            && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
    };
    let query_ok = query.bytes().all(|c| {
        c.is_ascii_alphanumeric()
            || matches!(c, b'-' | b'_' | b'.' | b'=' | b'&' | b':' | b'/' | b'%' | b'+')
    });
    path.len() <= 1024 && (segments.is_empty() || segments.split('/').all(segment_ok)) && query_ok
}

/// What a GET under a repository may read, and with which scope: the repository itself, its
/// pull requests (and their reviews, comments, commits) and Actions jobs (their logs).
fn get_scope(subpath: &str) -> Option<Scope> {
    let segments = subpath.split_once('?').map_or(subpath, |(s, _)| s);
    let mut parts = segments.split('/');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(""), None, ..) => Some(Scope::Pulls),
        (Some("pulls"), ..) => Some(Scope::Pulls),
        (Some("issues"), ..) => Some(Scope::Issues),
        (Some("actions"), Some("jobs"), Some(job), rest)
            if job.bytes().all(|b| b.is_ascii_digit()) && matches!(rest, None | Some("logs")) =>
        {
            Some(Scope::Checks)
        }
        _ => None,
    }
}

/// `params` (`{op, repo, ...}`) as one call, or why not.
///
/// - `graphql {repo, query, variables?, scope?: "pulls"|"checks"}`: a read-only query.
/// - `get {repo, path, tail?}`: `GET repos/{repo}/{path}` for the repository, its pull requests
///   or an Actions job and its log; `tail` keeps only the answer's last bytes.
/// - `pr.merge {repo, number, head, method}`: merge, pinned to `head` (GitHub refuses when the
///   pull request moved on), with `merge`, `squash` or `rebase`.
/// - `run.rerunFailed {repo, run}`: re-run an Actions run's failed jobs.
/// - `review.submit {repo, number, event, body?, head?}`: a review (`APPROVE`, `REQUEST_CHANGES`
///   or `COMMENT`), on `head` when given; the person's alone unless it only comments.
/// - `thread.reply {repo, thread, body}`: a reply in a review thread (its GraphQL node id).
/// - `thread.resolve {repo, thread, resolved}`: resolve the thread, or reopen it.
pub fn plan(params: &Value) -> Result<Plan, String> {
    let op = params.get("op").and_then(Value::as_str).unwrap_or("");
    let repo = text(params, "repo")?;
    if !valid_repo(repo) {
        return Err(invalid("repo must be owner/name"));
    }
    let repo = repo.to_owned();
    let at = |path: &str| format!("repos/{repo}/{path}");
    let plan = |op, scope, method, path: String, body| Plan {
        op,
        repo: repo.clone(),
        scope,
        method,
        path,
        body,
        tail: None,
        author: Author::Any,
    };
    match op {
        "graphql" => {
            let query = text(params, "query")?;
            if !read_only_query(query) {
                return Err(invalid("graphql reads only: use the op for a write"));
            }
            let variables = params.get("variables").cloned().unwrap_or_else(|| json!({}));
            if !variables.is_object() || variables.to_string().len() > TEXT_MAX {
                return Err(invalid("variables must be an object"));
            }
            let scope = match params.get("scope").and_then(Value::as_str) {
                None | Some("pulls") => Scope::Pulls,
                Some("checks") => Scope::Checks,
                Some(_) => return Err(invalid("scope must be pulls or checks")),
            };
            let body = json!({"query": query, "variables": variables});
            Ok(plan("graphql", scope, "POST", "graphql".to_owned(), Some(body)))
        }
        "get" => {
            let path = params.get("path").and_then(Value::as_str).unwrap_or("");
            let path = path.trim_start_matches('/');
            if !valid_subpath(path) {
                return Err(invalid("path must be a plain path under the repository"));
            }
            let scope =
                get_scope(path).ok_or_else(|| invalid("path is not one the host op reads"))?;
            let tail = match params.get("tail") {
                None | Some(Value::Null) => None,
                Some(v) => Some(
                    v.as_u64()
                        .filter(|n| *n > 0 && *n as usize <= BODY_MAX)
                        .ok_or_else(|| invalid(format!("tail must be 1..{BODY_MAX}")))?,
                ),
            };
            let path = if path.is_empty() { format!("repos/{repo}") } else { at(path) };
            Ok(Plan { tail, ..plan("get", scope, "GET", path, None) })
        }
        "pr.merge" => {
            let number = number(params, "number")?;
            let head = commit(params, "head")?;
            let method = params.get("method").and_then(Value::as_str).unwrap_or("merge");
            if !matches!(method, "merge" | "squash" | "rebase") {
                return Err(invalid("method must be merge, squash or rebase"));
            }
            let body = json!({"sha": head, "merge_method": method});
            Ok(plan(
                "pr.merge",
                Scope::Merge,
                "PUT",
                at(&format!("pulls/{number}/merge")),
                Some(body),
            ))
        }
        "run.rerunFailed" => {
            let run = number(params, "run")?;
            let path = at(&format!("actions/runs/{run}/rerun-failed-jobs"));
            Ok(plan("run.rerunFailed", Scope::Rerun, "POST", path, None))
        }
        "review.submit" => {
            let number = number(params, "number")?;
            let event = params.get("event").and_then(Value::as_str).unwrap_or("");
            let author = match event {
                "COMMENT" => Author::Person,
                "APPROVE" | "REQUEST_CHANGES" => Author::PersonOnly,
                _ => return Err(invalid("event must be APPROVE, REQUEST_CHANGES or COMMENT")),
            };
            let words = match params.get("body") {
                None | Some(Value::Null) => "",
                Some(_) => text(params, "body")?,
            };
            if words.is_empty() && event != "APPROVE" {
                return Err(invalid("a comment or a request for changes needs its words"));
            }
            let mut body = json!({"event": event, "body": words});
            if params.get("head").is_some_and(|h| !h.is_null()) {
                body["commit_id"] = Value::String(commit(params, "head")?);
            }
            let path = at(&format!("pulls/{number}/reviews"));
            Ok(Plan { author, ..plan("review.submit", Scope::Review, "POST", path, Some(body)) })
        }
        "thread.reply" | "thread.resolve" => {
            let thread = text(params, "thread")?;
            if thread.len() > 200
                || !thread
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'='))
            {
                return Err(invalid("thread must be a review thread's node id"));
            }
            let (name, query, variables) = if op == "thread.reply" {
                (
                    "thread.reply",
                    "mutation($thread: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { id url } } }",
                    json!({"thread": thread, "body": text(params, "body")?}),
                )
            } else {
                let resolved = params
                    .get("resolved")
                    .and_then(Value::as_bool)
                    .ok_or_else(|| invalid("resolved must be true or false"))?;
                let query = if resolved {
                    "mutation($thread: ID!) { resolveReviewThread(input: {threadId: $thread}) { thread { id isResolved } } }"
                } else {
                    "mutation($thread: ID!) { unresolveReviewThread(input: {threadId: $thread}) { thread { id isResolved } } }"
                };
                ("thread.resolve", query, json!({"thread": thread}))
            };
            let body = json!({"query": query, "variables": variables});
            Ok(Plan {
                author: Author::Person,
                ..plan(name, Scope::Review, "POST", "graphql".to_owned(), Some(body))
            })
        }
        "" => Err(invalid("op is required")),
        _ => Err(invalid("op is not one the host op runs")),
    }
}

/// The same call as `gh api` (the fallback), with the body, if any, on stdin.
pub fn gh_args(plan: &Plan) -> Vec<String> {
    let mut args: Vec<String> =
        ["api", "--hostname", "github.com", "--method", plan.method].map(str::to_owned).into();
    args.extend(["-H".to_owned(), format!("Accept: {}", plan.accept())]);
    if let Some(tail) = plan.tail {
        args.extend(["-H".to_owned(), format!("Range: bytes=-{tail}")]);
    }
    args.push(plan.path.clone());
    if plan.body.is_some() {
        args.extend(["--input".to_owned(), "-".to_owned()]);
    }
    args
}

/// The HTTP status in `gh api`'s error line (`gh: Not Found (HTTP 404)`), if it names one.
pub fn gh_status(stderr: &str) -> Option<u16> {
    let at = stderr.rfind("(HTTP ")?;
    stderr[at + 6..].split(')').next()?.trim().parse().ok()
}

/// The end of `body` when it is longer than `tail` (a store that ignored the `Range`).
pub fn keep_tail(mut body: Vec<u8>, tail: Option<u64>) -> Vec<u8> {
    if let Some(tail) = tail.map(|t| t as usize)
        && body.len() > tail
    {
        body.drain(..body.len() - tail);
    }
    body
}

/// GitHub's own words for a refusal (`{"message": ...}`, or a GraphQL `errors[0].message`),
/// bounded, for the person to read.
pub fn refusal_message(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    let message = value
        .get("message")
        .or_else(|| value.pointer("/errors/0/message"))
        .and_then(Value::as_str)?;
    Some(message.chars().take(500).collect())
}

#[cfg(test)]
#[path = "github_rest_tests.rs"]
mod tests;
