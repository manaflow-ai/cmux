//! Launch-proof authenticated workflow activities. Register deterministic child identities
//! before effects; start is nonblocking so QuickJS can enqueue parallel branches.
use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::RpcError;
use crate::workflow_runs::{ActivityRecord, Child};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use tokio::sync::Notify;

struct Flight {
    key: String,
    active: Mutex<bool>,
    changed: Notify,
}

static FLIGHTS: OnceLock<Mutex<HashMap<String, Weak<Flight>>>> = OnceLock::new();

impl Drop for Flight {
    fn drop(&mut self) {
        if let Some(flights) = FLIGHTS.get() {
            let mut flights = flights.lock().unwrap_or_else(|e| e.into_inner());
            if flights.get(&self.key).is_some_and(|flight| flight.strong_count() == 0) {
                flights.remove(&self.key);
            }
        }
    }
}

fn flight(run: &str, activity: &str, generation: u64) -> Arc<Flight> {
    let key = format!("{run}:{generation}:{activity}");
    let mut flights = FLIGHTS.get_or_init(Mutex::default).lock().unwrap_or_else(|e| e.into_inner());
    if let Some(flight) = flights.get(&key).and_then(Weak::upgrade) {
        return flight;
    }
    let flight =
        Arc::new(Flight { key: key.clone(), active: Mutex::new(false), changed: Notify::new() });
    flights.insert(key, Arc::downgrade(&flight));
    flight
}

fn internal(e: impl std::fmt::Display) -> RpcError {
    RpcError::internal(e.to_string())
}

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if method != "_acpmux/workflow_activity" {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found("workflow activities are local only")));
    }
    Some(handle(hub, conn, params).await)
}

async fn handle(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let text = |key| {
        str_param(params, key).ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
    };
    let id = text("runId")?;
    let activity = str_param(params, "activityId").unwrap_or("");
    let token = text("runnerToken")?;
    let generation = params
        .get("generation")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("generation is required"))?;
    let action = text("action")?;
    let guard = hub.workflow_runs.gate(id).lock_owned().await;
    let run = hub.workflow_runs.authorize_runner(id, generation, token).map_err(internal)?;
    if conn.caller() != Some(run.owner_session_id.as_str()) && !conn.is_person() {
        return Err(RpcError::invalid_params("a workflow reaches only its owner's activities"));
    }
    let store = hub.workflow_runs.store();
    let pending = flight(id, "", generation);
    if action == "wait" {
        let activities = params
            .get("activityIds")
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(Value::as_str).collect::<Vec<_>>())
            .unwrap_or_else(|| vec![activity]);
        if activities.is_empty() || activities.iter().any(|id| id.is_empty()) {
            return Err(RpcError::invalid_params("activityIds must name activities"));
        }
        drop(guard);
        loop {
            let changed = pending.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            hub.workflow_runs.authorize_runner(id, generation, token).map_err(internal)?;
            for activity in &activities {
                let record = store
                    .activity(id, generation, &run.owner_session_id, activity)
                    .map_err(internal)?
                    .ok_or_else(|| RpcError::not_found("workflow activity"))?;
                if let Some(outcome) = record.outcome {
                    return Ok(json!({"activityId":activity,"outcome":outcome}));
                }
            }
            changed.await;
        }
    }
    if action != "start" {
        return Err(RpcError::invalid_params("use start or wait"));
    }
    if activity.is_empty() {
        return Err(RpcError::invalid_params("activityId is required"));
    }
    let worker = flight(id, activity, generation);
    let kind = text("kind")?;
    if !matches!(kind, "agent" | "machine") {
        return Err(RpcError::invalid_params("unknown workflow activity kind"));
    }
    if let Some(allowed) = hub.workflow_allowed_tools(&run).await.map_err(internal)? {
        let operation = if kind == "agent" { "agent_dispatch" } else { "acpmux_bg_start" };
        if !allowed.iter().any(|tool| tool == "cmux_workflow")
            || !allowed.iter().any(|tool| tool == operation)
        {
            return Err(RpcError::invalid_params(
                "workflow activity is outside its owner's current tool scope",
            ));
        }
    }
    let prompt = text("prompt")?;
    let options = params.get("options").cloned().unwrap_or_else(|| json!({}));
    // Command execution on peers remains denied by bg_tasks. A requested placement never
    // silently falls back to this daemon's machine.
    if let Some(host) = options.get("on").and_then(Value::as_str)
        && host != "local"
        && host != crate::hub::host_label()
    {
        return Err(RpcError::invalid_params(
            "remote workflow activities require an authenticated machine executor; no local fallback",
        ));
    }
    if let Some(schema) = options.get("schema") {
        crate::workflow_reply::ReplyPolicy::new(
            schema,
            crate::workflow_reply::ReplyState::new(crate::workflow_reply::AttemptKey::new(
                activity,
            )),
        )
        .map_err(internal)?;
    }
    let fingerprint = crate::workflow_runs::digest(&json!([kind, prompt, options]).to_string());
    let key = crate::workflow_runs::digest(&format!("{id}:{activity}"));
    let session = format!("wf-{key}");
    let child = if kind == "agent" {
        Child::Agent { session_id: session, prompt_id: format!("wf-{key}-initial"), host: None }
    } else {
        Child::Machine {
            session_id: run.owner_session_id.clone(),
            task_id: format!("wf-{key}"),
            host: None,
        }
    };
    let record = store
        .register_activity(
            id,
            generation,
            &run.owner_session_id,
            ActivityRecord {
                id: activity.to_owned(),
                kind: kind.to_owned(),
                fingerprint,
                child,
                policy: Value::Null,
                outcome: None,
            },
        )
        .map_err(internal)?;
    if record.outcome.is_none() {
        let mut active = worker.active.lock().unwrap_or_else(|e| e.into_inner());
        if !*active {
            *active = true;
            let hub = hub.clone();
            let prompt = prompt.to_owned();
            let pending = pending.clone();
            let worker = worker.clone();
            let run_id = id.to_owned();
            let owner = run.owner_session_id.clone();
            tokio::spawn(async move {
                let mut result =
                    hub.workflow_execute(&run, generation, &record, &prompt, &options).await;
                let _gate = hub.workflow_runs.gate(&run_id).lock_owned().await;
                if let Ok(current) =
                    hub.workflow_runs.store().authorize(&run_id, generation, &owner)
                {
                    if let Err(error) = hub.workflow_cancel_activity(&current, &record.id).await {
                        result = Err(error);
                    }
                }
                let _ = hub.workflow_runs.store().complete_activity(
                    &run_id,
                    generation,
                    &owner,
                    &record.id,
                    result.map_err(|e| json!({"code":e.code,"message":e.message,"data":e.data})),
                );
                *worker.active.lock().unwrap_or_else(|e| e.into_inner()) = false;
                pending.changed.notify_waiters();
            });
        }
    }
    Ok(json!({"id":activity}))
}
