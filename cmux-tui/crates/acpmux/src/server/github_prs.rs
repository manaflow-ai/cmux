//! The machine's GitHub poller (`pr_poller.rs`): `_acpmux/github/pr_state {repo, pr}` and
//! `_acpmux/github/pr_wait {repo, pr, timeoutSecs?, until?}`, each answering
//! `{pr, poller: {source, ageSecs, note?, waitedSecs?, timedOut?, budget, counters}}` where `pr`
//! has the shape `gh pr view --json` gives (`pr_poller::VIEW_FIELDS`). `until` is `settled`
//! (default: nothing pending, or merged or closed) or `change` (the summary line moved).
//!
//! `_acpmux/github/read {path, freshSecs?}` is the same poller's GET of any `repos/OWNER/REPO/...`
//! path (`Poller::get`), answering `{data, poller: {source, ageSecs, note?, budget, counters}}`:
//! a body no older than `freshSecs` (default [`READ_FRESH`]) when the budget allows, else kept.
//!
//! Only this machine's clients get them (the `acpmux` MCP server of each chat, the CLI, the
//! app): the poller spends this machine's GitHub budget with this machine's `gh` login.

use super::{Conn, str_param};
use crate::pr_poller::{self, Key, MAX_WAIT, Until};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// How old a kept body a `_acpmux/github/read` may answer with when the call names no `freshSecs`.
pub const READ_FRESH: Duration = Duration::from_secs(30);
/// How long a wait runs when the call names no `timeoutSecs`.
const DEFAULT_WAIT: Duration = Duration::from_secs(45);

/// The reply to a poller method, or None for any other method.
pub(super) async fn dispatch(
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_GITHUB_PR_STATE | method::MUX_GITHUB_PR_WAIT | method::MUX_GITHUB_READ
    ) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(m, params).await)
}

/// The pull request a call names: `repo` as OWNER/REPO and `pr` as a number.
pub(crate) fn key(params: &Value) -> Result<Key, RpcError> {
    let repo = str_param(params, "repo")
        .map(str::trim)
        .filter(|r| valid_repo(r))
        .ok_or_else(|| RpcError::invalid_params("repo must be OWNER/REPO"))?;
    let number = match params.get("pr") {
        Some(Value::Number(n)) => n.as_u64(),
        Some(Value::String(s)) => s.trim().trim_start_matches('#').parse().ok(),
        _ => None,
    }
    .filter(|n| *n > 0)
    .ok_or_else(|| RpcError::invalid_params("pr must be a pull request number"))?;
    Ok(Key::new(repo, number))
}

fn valid_repo(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    };
    matches!(repo.split_once('/'), Some((o, r)) if part(o) && part(r) && o != ".." && r != "..")
}

async fn handle(m: &str, params: &Value) -> Result<Value, RpcError> {
    if m == method::MUX_GITHUB_READ {
        return read(params).await;
    }
    let key = key(params)?;
    let poller = pr_poller::machine();
    let started = tokio::time::Instant::now();
    let (answer, timed_out) = if m == method::MUX_GITHUB_PR_WAIT {
        let until = match str_param(params, "until") {
            None | Some("settled") => Until::Settled,
            Some("change") => Until::Change,
            Some(other) => {
                return Err(RpcError::invalid_params(format!(
                    "until must be settled or change, not {other:?}"
                )));
            }
        };
        let timeout = params
            .get("timeoutSecs")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_WAIT, Duration::from_secs)
            .min(MAX_WAIT);
        let (answer, timed_out) =
            poller.wait(&key, until, started + timeout).await.map_err(|r| refusal(&r))?;
        (answer, Some(timed_out))
    } else {
        (poller.status(&key, pr_poller::FRESH).await.map_err(|r| refusal(&r))?, None)
    };
    let mut info = poller_info(poller, &answer);
    if let Some(obj) = info.as_object_mut() {
        if let Some(timed_out) = timed_out {
            obj.insert("timedOut".to_owned(), json!(timed_out));
            obj.insert("waitedSecs".to_owned(), json!(started.elapsed().as_secs()));
        }
    }
    Ok(json!({"pr": answer.pr, "poller": info}))
}

/// `_acpmux/github/read {path, freshSecs?}`.
async fn read(params: &Value) -> Result<Value, RpcError> {
    let path = str_param(params, "path")
        .ok_or_else(|| RpcError::invalid_params("path must be repos/OWNER/REPO/..."))?;
    let path = pr_poller::read_path(path).map_err(RpcError::invalid_params)?;
    let fresh =
        params.get("freshSecs").and_then(Value::as_u64).map_or(READ_FRESH, Duration::from_secs);
    let poller = pr_poller::machine();
    let answer = poller.get(&path, fresh).await.map_err(|r| refusal(&r))?;
    let info = poller_info(poller, &answer);
    Ok(json!({"data": answer.pr, "poller": info}))
}

/// `{source, ageSecs, note?, budget, counters}` for an answer.
fn poller_info<F: pr_poller::Fetch>(
    poller: &pr_poller::Poller<F>,
    answer: &pr_poller::Answer,
) -> Value {
    let c = poller.counters();
    let mut info = json!({
        "source": answer.source.as_str(),
        "ageSecs": answer.age.as_secs(),
        "budget": poller.budget_json(),
        "counters": {
            "requests": c.requests, "charged": c.charged, "notModified": c.not_modified,
            "refreshes": c.refreshes, "cacheHits": c.cache_hits,
        },
    });
    if let (Some(obj), Some(note)) = (info.as_object_mut(), &answer.note) {
        obj.insert("note".to_owned(), json!(note));
    }
    info
}

fn refusal(r: &pr_poller::Refusal) -> RpcError {
    let text = match r.retry_after {
        Some(after) => format!("{} (retry after {}s)", r.message, after.as_secs()),
        None => r.message.clone(),
    };
    RpcError::internal(&text)
}
