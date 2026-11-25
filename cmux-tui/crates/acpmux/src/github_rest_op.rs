//! `_acpmux/github_rest`: the Mac app's own GitHub calls (its pull request page, checks, merge,
//! re-run, the PR chip, Create PR's lookups), run by this daemon so they need no `gh` login.
//!
//! The op table is `cmux_host::github_rest` (which calls exist, their paths, their scope). Here
//! each runs:
//!
//! - With the cmux GitHub App first: when the app lent this daemon its cmux sign-in
//!   (`github_app_token.rs`), cmux Cloud mints a token for the op's one repository with the op's
//!   scope and no more (the route Cloud machines use), and this daemon calls `api.github.com`
//!   with it. The token stays in this daemon's memory for that one call: never on disk, in a log,
//!   in argv or in the reply. It is not used once the sign-in it was minted with is replaced,
//!   cleared or expired.
//! - With the person's `gh` (`gh api`, the same call) when no sign-in is lent, or the App cannot
//!   cover the call (the repository is not in the installation, a permission it lacks): a person
//!   signed in to `gh` keeps what they had.
//! - Neither: the not-connected error, which carries the app's Connect GitHub action.
//!
//! The reply is `{ok, status, body, source}`: GitHub's status and answer (bounded), and which
//! login ran (`app` or `keyring`). Only the person's own app asks, over the unix socket
//! (`server/requests.rs`); a page, the Web, an agent or a peer is refused.

use crate::github_app_token::{AppLease, Source};
use crate::rpc::RpcError;
use cmux_host::github_rest::{self as rest, Plan};
use serde_json::{Value, json};

const API: &str = "https://api.github.com";

fn invalid(message: String) -> RpcError {
    RpcError::invalid_params(format!("github_rest: {message}"))
}

/// One op's answer from GitHub.
struct Answer {
    status: Option<u16>,
    ok: bool,
    body: Vec<u8>,
}

impl Answer {
    fn reply(self, source: &Source) -> Value {
        let body = String::from_utf8_lossy(&self.body).into_owned();
        let message = (!self.ok).then(|| rest::refusal_message(&body)).flatten();
        json!({"ok": self.ok, "status": self.status, "body": body, "source": source.name(),
            "message": message})
    }
}

/// Runs `params` (`cmux_host::github_rest::plan`) with the login the module docs pick.
pub async fn serve(params: Value, app: &AppLease) -> Result<Value, RpcError> {
    serve_at(params, app, API, "gh").await
}

async fn serve_at(params: Value, app: &AppLease, api: &str, gh: &str) -> Result<Value, RpcError> {
    let plan = rest::plan(&params).map_err(invalid)?;
    let started = std::time::Instant::now();
    let (source, answer) =
        match crate::github_app_token::mint_for(app, &plan.repo, &plan.scope.permissions()).await {
            Some(Ok(source)) => {
                crate::github_app_token::still_lent(&source, app)?;
                let token = source.token().unwrap_or_default();
                let answer = http(&plan, api, token).await?;
                (source, answer)
            }
            // The App cannot cover it: the person's own gh, if it works; else the App's reason.
            Some(Err(mint_error)) => match run_gh(&plan, gh).await {
                Gh::Ran(answer) => (Source::Keyring, answer),
                Gh::Unusable => return Err(logged(&plan, "app", Err(mint_error))),
                Gh::Failed(e) => return Err(logged(&plan, "keyring", Err(e))),
            },
            None => match run_gh(&plan, gh).await {
                Gh::Ran(answer) => (Source::Keyring, answer),
                Gh::Unusable => {
                    return Err(logged(
                        &plan,
                        "none",
                        Err(crate::github_app_token::not_connected()),
                    ));
                }
                Gh::Failed(e) => return Err(logged(&plan, "keyring", Err(e))),
            },
        };
    tracing::info!(op = plan.op, repo = %plan.repo, scope = plan.scope.name(), source = source.name(),
        status = ?answer.status, ms = started.elapsed().as_millis() as u64, "github rest");
    Ok(answer.reply(&source))
}

/// Logs a call that got no answer (no title, body or token), and passes its error on.
fn logged(plan: &Plan, source: &str, e: Result<(), RpcError>) -> RpcError {
    let e = e.unwrap_err();
    tracing::info!(op = plan.op, repo = %plan.repo, scope = plan.scope.name(), source,
        code = e.code, "github rest: no answer");
    e
}

/// Reads `res`'s body: whole up to `BODY_MAX`, or its last `tail` bytes.
async fn bounded(mut res: reqwest::Response, tail: Option<u64>) -> Result<Vec<u8>, RpcError> {
    let mut body = Vec::new();
    while let Some(chunk) = res.chunk().await.map_err(|e| {
        RpcError::internal(format!("GitHub's answer broke off: {}", e.without_url()))
    })? {
        body.extend_from_slice(&chunk);
        match tail {
            Some(t) if body.len() > 2 * t as usize => body = rest::keep_tail(body, Some(t)),
            None if body.len() > rest::BODY_MAX => {
                return Err(RpcError::internal("GitHub's answer is too long to read here"));
            }
            _ => {}
        }
    }
    Ok(rest::keep_tail(body, tail))
}

/// The call against `api` with `token`. Redirects (a job's log goes to its store) are followed
/// to at most 5, and reqwest drops the `Authorization` header when one leaves the API's host.
async fn http(plan: &Plan, api: &str, token: &str) -> Result<Answer, RpcError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = crate::happy_dial::http_client()
        .redirect(reqwest::redirect::Policy::limited(5))
        .timeout(rest::TIMEOUT)
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| RpcError::internal(format!("no HTTP client: {e}")))?;
    let method = reqwest::Method::from_bytes(plan.method.as_bytes())
        .map_err(|_| RpcError::internal("bad method"))?;
    let mut req = client
        .request(method, plan.url(api))
        .bearer_auth(token)
        .header("Accept", plan.accept())
        .header("X-GitHub-Api-Version", "2022-11-28");
    if let Some(tail) = plan.tail {
        req = req.header("Range", format!("bytes=-{tail}"));
    }
    if let Some(body) = &plan.body {
        req = req.json(body);
    }
    let res = req.send().await.map_err(|e| {
        RpcError::new(-32045, format!("GitHub did not answer: {}", e.without_url()))
            .with_data(json!({"reason": "github.unreachable", "retryable": !plan.scope.writes()}))
    })?;
    let status = res.status();
    // A GraphQL answer with `errors` and no `data` is a refusal under a 200.
    let body = bounded(res, plan.tail).await?;
    let graphql_refused = plan.path == "graphql"
        && serde_json::from_slice::<Value>(&body)
            .ok()
            .is_some_and(|v| v.get("errors").is_some() && v.get("data").is_none_or(Value::is_null));
    Ok(Answer { status: Some(status.as_u16()), ok: status.is_success() && !graphql_refused, body })
}

enum Gh {
    Ran(Answer),
    /// No `gh`, or it is not signed in: as if there were none.
    Unusable,
    Failed(RpcError),
}

/// The call as `gh api` with the person's keyring login (no token from this daemon's env).
async fn run_gh(plan: &Plan, gh: &str) -> Gh {
    let (plan, gh) = (plan.clone(), gh.to_owned());
    match tokio::task::spawn_blocking(move || run_gh_blocking(&plan, &gh)).await {
        Ok(ran) => ran,
        Err(e) => Gh::Failed(RpcError::internal(format!("lost gh: {e}"))),
    }
}

/// `gh api` with its answer and its words in unnamed files (no pipe to drain while it runs), its
/// body on stdin from another; past `TIMEOUT` it is ended (`cmux_process::Child` drop).
fn run_gh_blocking(plan: &Plan, gh: &str) -> Gh {
    use std::io::{Read, Seek, Write};
    let failed = |e: std::io::Error| Gh::Failed(RpcError::internal(format!("gh: {e}")));
    let files = (|| {
        Ok::<_, std::io::Error>((
            tempfile::tempfile()?,
            tempfile::tempfile()?,
            tempfile::tempfile()?,
        ))
    })();
    let (mut input, mut out, mut err) = match files {
        Ok(files) => files,
        Err(e) => return failed(e),
    };
    let mut cmd = cmux_process::Command::new(gh);
    cmd.args(rest::gh_args(plan)).envs(crate::github_broker::LOGIN_SET);
    for name in crate::github_broker::LOGIN_REMOVED {
        cmd.env_remove(name);
    }
    match &plan.body {
        Some(body) => {
            if let Err(e) =
                input.write_all(body.to_string().as_bytes()).and_then(|()| input.rewind())
            {
                return failed(e);
            }
            cmd.stdin(input);
        }
        None => {
            cmd.stdin(cmux_process::Stdio::null());
        }
    }
    let (Ok(stdout), Ok(stderr)) = (out.try_clone(), err.try_clone()) else {
        return Gh::Failed(RpcError::internal("gh: no answer file"));
    };
    cmd.stdout(stdout).stderr(stderr);
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Gh::Unusable,
        Err(e) => return Gh::Failed(RpcError::internal(format!("could not start gh: {e}"))),
    };
    let status = match child.wait_timeout(rest::TIMEOUT) {
        Ok(Some(status)) => status,
        Ok(None) => {
            return Gh::Failed(RpcError::internal(format!(
                "gh did not finish within {}s",
                rest::TIMEOUT.as_secs()
            )));
        }
        Err(e) => return failed(e),
    };
    let mut words = Vec::new();
    if let Err(e) = err.rewind().and_then(|()| (&mut err).take(64 * 1024).read_to_end(&mut words)) {
        return failed(e);
    }
    let stderr = String::from_utf8_lossy(&words);
    // gh's exit 4: it has no login (`gh auth login` was never run, or it ran out).
    if status.code() == Some(4) || stderr.contains("gh auth login") {
        return Gh::Unusable;
    }
    let mut body = Vec::new();
    let cap = rest::BODY_MAX as u64 + 1;
    // A tail is read from where it starts (a store that ignored the Range sent all of it).
    let start = match plan.tail {
        Some(t) => out.seek(std::io::SeekFrom::End(0)).map(|len| len.saturating_sub(t)),
        None => Ok(0),
    };
    if let Err(e) = start
        .and_then(|at| out.seek(std::io::SeekFrom::Start(at)))
        .and_then(|_| (&mut out).take(cap).read_to_end(&mut body))
    {
        return failed(e);
    }
    if plan.tail.is_none() && body.len() > rest::BODY_MAX {
        return Gh::Failed(RpcError::internal("GitHub's answer is too long to read here"));
    }
    let body = rest::keep_tail(body, plan.tail);
    let answer_status = if status.success() { Some(200) } else { rest::gh_status(&stderr) };
    Gh::Ran(Answer { status: answer_status, ok: status.success(), body })
}

#[cfg(test)]
#[path = "github_rest_op_tests.rs"]
mod tests;
