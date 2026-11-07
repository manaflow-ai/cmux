//! Classic's sandboxed Runs (`/api/runs`, hq#3367): one task on a throwaway VM from a pinned
//! image. A Run has no NEXT route yet, so these are its classic calls as they were, plus the
//! one rule a send needs: a create whose answer was lost is sent once more under the same key
//! (the server returns the same Run, never a second paid one), and a send then long-polls the
//! Run to its receipt under one deadline.

use std::time::Duration;

use cmux_json::JsonSet as _;
use reqwest::Method;
use serde_json::{Map, Value, json};
use tokio::time::Instant;

use super::http::Http;
use super::{Failure, optional_int, optional_text, text};

/// The server holds one wait this long at most.
pub(crate) const WAIT_LIMIT_MS: i64 = 10_000;
pub(crate) const DEFAULT_TIMEOUT_MS: i64 = 600_000;
pub(crate) const DEFAULT_TEARDOWN_MS: i64 = 180_000;
pub(crate) const DEFAULT_CALLS_MARGIN_MS: i64 = 60_000;

fn millis(ms: i64) -> Duration {
    Duration::from_millis(u64::try_from(ms.max(0)).unwrap_or(0))
}

/// `POST /api/runs` once: the server's JSON as is (its views hold no secrets).
pub(crate) async fn create(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let mut body = json!({ "environment": "sandboxed", "task": text(args, "task")? });
    for name in ["agent", "image"] {
        if let Some(value) = optional_text(args, name).filter(|v| !v.is_empty()) {
            body.set(name, json!(value));
        }
    }
    if let Some(ms) = optional_int(args, "timeoutMs") {
        body.set("timeoutMs", json!(ms));
    }
    let key = text(args, "idempotencyKey")?;
    http.classic(
        Method::POST,
        &["api", "runs"],
        &[],
        Some(body),
        Some(key),
        Duration::from_secs(20),
    )
    .await
}

/// [`create`], sent once more when its answer was lost. A create that failed that way may have
/// made the Run: whatever the retry says, the outcome stays uncertain (`timed_out`, never a
/// refusal the caller could take as "nothing runs"). Answers the created Run, which has an id.
pub(crate) async fn start(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    // A request that is not one is refused as it is, before anything is sent: only an answer
    // lost on the way makes the outcome uncertain.
    text(args, "task")?;
    text(args, "idempotencyKey")?;
    let created = match create(http, args).await {
        Err(Failure::Transport(_) | Failure::TimedOut(_)) => {
            create(http, args).await.map_err(|_| Failure::TimedOut("/api/runs".into()))?
        }
        other => other?,
    };
    match created.get("id").and_then(Value::as_str) {
        Some(id) if !id.is_empty() => Ok(created),
        _ => Err(Failure::Decoding("/api/runs: no run id".into())),
    }
}

/// `GET /api/runs/:id/wait?timeoutMs=`: the snapshot once the Run is terminal or after the wait
/// (at most 10 s), with its receipt when it has one.
pub(crate) async fn wait(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    let ms = optional_int(args, "timeoutMs").unwrap_or(WAIT_LIMIT_MS);
    wait_once(http, id, ms).await
}

async fn wait_once(http: &Http, id: &str, ms: i64) -> Result<Value, Failure> {
    let held = ms.clamp(0, WAIT_LIMIT_MS);
    let query = [("timeoutMs", held.to_string())];
    http.classic(
        Method::GET,
        &["api", "runs", id, "wait"],
        &query,
        None,
        None,
        millis(held.saturating_add(10_000)),
    )
    .await
}

/// `POST /api/runs/:id/cancel`: a sandbox's VM is destroyed before it answers.
pub(crate) async fn cancel(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    http.classic(
        Method::POST,
        &["api", "runs", id, "cancel"],
        &[],
        None,
        None,
        Duration::from_secs(60),
    )
    .await
}

/// One sandboxed Run to its end: [`start`], then waits of 10 s until the snapshot carries its
/// receipt. Everything runs under one bound, the task's timeout plus `teardownMs` (boot, the last
/// output and the VM destroy) plus `callsMarginMs` for the calls themselves, so the caller always
/// gets an answer; the poll stops at the receipt, at the first error, or at the task's deadline
/// (`timed_out`). The server destroys the VM either way. Answers the final snapshot
/// (`{run, attempts, artifacts, receipt}`).
pub(crate) async fn sandbox(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let timeout_ms = optional_int(args, "timeoutMs").unwrap_or(DEFAULT_TIMEOUT_MS);
    let teardown = millis(optional_int(args, "teardownMs").unwrap_or(DEFAULT_TEARDOWN_MS));
    let margin = millis(optional_int(args, "callsMarginMs").unwrap_or(DEFAULT_CALLS_MARGIN_MS));
    let mut args = args.clone();
    args.insert("timeoutMs".into(), json!(timeout_ms));
    let bound = millis(timeout_ms).saturating_add(teardown);
    let now = Instant::now();
    let deadline = now.checked_add(bound).unwrap_or(now);
    let bound = bound.saturating_add(margin);
    tokio::time::timeout(bound, follow(http, &args, deadline))
        .await
        .unwrap_or_else(|_| Err(Failure::TimedOut("/api/runs".into())))
}

async fn follow(
    http: &Http,
    args: &Map<String, Value>,
    deadline: Instant,
) -> Result<Value, Failure> {
    let created = start(http, args).await?;
    let id = created.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
    let lost = || Failure::TimedOut(format!("/api/runs/{id}"));
    while Instant::now() < deadline {
        // The Run exists: losing sight of it is "no receipt in time", never a refusal to retry past.
        let snapshot = wait_once(http, &id, WAIT_LIMIT_MS).await.map_err(|_| lost())?;
        // A 200 that is no Run snapshot (an array, an error body) won't turn into one: stop now.
        if !snapshot.get("run").is_some_and(Value::is_object) {
            return Err(lost());
        }
        if snapshot.get("receipt").is_some_and(Value::is_object) {
            return Ok(snapshot);
        }
    }
    Err(lost())
}
