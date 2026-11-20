//! Snapshot the team's machines, then pause each through the backend's existing guarded op.
//! An already paused machine must go through it too: its automatic pause becomes a person hold.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::api::models::Machine;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer, upstream_key};

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
    // Complete the snapshot before pausing anything. A failed or looping list cannot silently
    // leave later pages running while the command reports success.
    loop {
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
    for (id, machine) in machines {
        let state = serde_json::to_value(&machine.record.status).unwrap_or(Value::Null);
        if state == "deleting" || state == "failed" {
            outcomes.push(json!({"machine": id, "status": "skipped"}));
            continue;
        }
        let params = json!({"machine": id});
        let child_key = upstream_key("cloud.machine.pause_all", &params, &key);
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
        outcomes.push(match result {
            Ok(status) => json!({"machine": id, "status": status}),
            Err(error) => json!({"machine": id, "status": "failed", "error": {
                "code": error.upstream_code.as_deref().unwrap_or(&error.code), "message": error.message
            }}),
        });
    }
    Ok(json!({"machines": outcomes}))
}
