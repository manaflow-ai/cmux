//! Snapshot the team's machines, then pause each through the backend's existing guarded op.
//! An already paused machine must go through it too: its automatic pause becomes a person hold.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::api::models::Machine;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer, upstream_key};

const BATCH_BUDGET: Duration = Duration::from_secs(30);
const MAX_PAGES: usize = 1_000;

#[derive(Deserialize)]
struct Page {
    machines: Vec<Machine>,
    next_cursor: Option<String>,
}

pub(super) fn run<C: ControlPlane>(ctx: &mut Ctx<'_, C>) -> Result<Value, CloudError> {
    let key = ctx.key().ok_or_else(|| CloudError::invalid("pause-all needs a key"))?.to_owned();
    let mut machines = BTreeMap::new();
    let mut cursors = BTreeSet::new();
    let mut cursor = None;
    let started = Instant::now();
    // Complete the snapshot before pausing anything. A failed or looping list cannot silently
    // leave later pages running while the command reports success.
    loop {
        if cursors.len() >= MAX_PAGES || started.elapsed() >= BATCH_BUDGET {
            return Err(CloudError {
                retryable: true,
                ..CloudError::new(
                    codes::BAD_RESPONSE,
                    "machine listing exceeded its page or time budget; no machines were paused",
                )
            });
        }
        let mut params = json!({"limit": 100});
        if let Some(cursor) = &cursor {
            params["cursor"] = json!(cursor);
        }
        let page: Page = decode_answer(
            "cloud.machine.list",
            ctx.wire_key("cloud.machine.list", params, None)?.value,
        )?;
        for machine in page.machines {
            machines.insert(machine.id().to_owned(), machine);
        }
        let Some(next) = page.next_cursor else { break };
        if !cursors.insert(next.clone()) {
            return Err(CloudError::new(
                codes::BAD_RESPONSE,
                "machine listing repeated a page cursor",
            ));
        }
        cursor = Some(next);
    }
    let mut outcomes = Vec::new();
    let mut stopped = false;
    for (id, machine) in machines {
        let state = serde_json::to_value(&machine.record.status).unwrap_or(Value::Null);
        if state == "deleting" || state == "failed" {
            outcomes.push(json!({"machine": id, "status": "skipped"}));
            continue;
        }
        if stopped || started.elapsed() >= BATCH_BUDGET {
            outcomes.push(deferred(&id));
            continue;
        }
        match pause(ctx, &id, &key) {
            Ok(outcome) => {
                stopped = outcome.pointer("/error/retryable") == Some(&Value::Bool(true));
                outcomes.push(outcome);
            }
            Err(mut error) => {
                error.details = Some(json!({"machines": outcomes, "idempotency_key": key}));
                return Err(error);
            }
        }
    }
    Ok(json!({"machines": outcomes, "idempotency_key": key}))
}

pub(super) fn retryable(answer: &Value) -> bool {
    answer["machines"].as_array().is_some_and(|rows| {
        rows.iter().any(|row| row.pointer("/error/retryable") == Some(&Value::Bool(true)))
    })
}

/// Retry only unfinished targets from this server's saved snapshot. Completed pauses are
/// never repeated and machines created since the first attempt are not added to the batch.
pub(super) fn retry<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    mut answer: Value,
) -> Result<Value, CloudError> {
    let key = ctx.key().ok_or_else(|| CloudError::invalid("pause-all needs a key"))?.to_owned();
    let started = Instant::now();
    if let Some(rows) = answer["machines"].as_array_mut() {
        for row in rows {
            if started.elapsed() >= BATCH_BUDGET {
                break;
            }
            if row.pointer("/error/retryable") == Some(&Value::Bool(true)) {
                let id = row["machine"].as_str().unwrap_or_default().to_owned();
                *row = pause(ctx, &id, &key)?;
                if row.pointer("/error/retryable") == Some(&Value::Bool(true)) {
                    break;
                }
            }
        }
    }
    Ok(answer)
}

fn deferred(id: &str) -> Value {
    json!({"machine": id, "status": "failed", "error": {
        "code": "cmux.cloud.batch_deferred", "retryable": true,
        "message": "Not attempted: the batch reached a temporary failure or its time budget; retry with the same key",
    }})
}

fn pause<C: ControlPlane>(ctx: &mut Ctx<'_, C>, id: &str, key: &str) -> Result<Value, CloudError> {
    let params = json!({"machine": id});
    let child_key = upstream_key("cloud.machine.pause_all", &params, key);
    let result = ctx.wire_key("cloud.machine.pause", params, Some(&child_key));
    let result = result.and_then(|answer| {
        let paused: Machine =
            decode_answer("cloud.machine.pause", answer.value["machine"].clone())?;
        let status = serde_json::to_value(&paused.record.status).unwrap_or(Value::Null);
        if status != "paused" && status != "pausing" {
            return Err(CloudError::new(
                codes::BAD_RESPONSE,
                "pause answered without a paused or pausing machine",
            ));
        }
        ctx.projection.upsert(paused);
        Ok(status)
    });
    Ok(match result {
        Ok(status) => json!({"machine": id, "status": status}),
        // Keep sign-out visible to Server::handle so it clears the ledger and auth identity.
        Err(error) if error.code == codes::AUTH_REQUIRED => return Err(error),
        Err(error) if error.code == codes::NOT_FOUND => json!({"machine":id, "status":"skipped"}),
        Err(error) => json!({"machine": id, "status": "failed", "error": {
            "code": error.upstream_code.as_deref().unwrap_or(error.code), "message": error.message,
            "retryable": error.retryable || super::delete_retry::indeterminate(&error)
                || matches!(error.code, codes::BAD_RESPONSE | codes::RATE_LIMITED),
        }}),
    })
}
