//! Launch-proof authenticated workflow activities. Register deterministic child identities
//! before effects; start is nonblocking so QuickJS can enqueue parallel branches.
use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::RpcError;
use crate::workflow_runs::{ActivityRecord, Child};
use cmux_json::JsonSet as _;
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

fn validate_activity_id(id: &str, registered: bool) -> Result<(), RpcError> {
    // The runner hashes UUID:ordinal journal identities to a SHA-256 transport ID.
    // Preserve older safe identities already registered by this daemon.
    let generated_width = crate::workflow_runs::digest("").len();
    if id.is_empty()
        || !id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        || (id.len() > generated_width && !registered)
    {
        return Err(RpcError::invalid_params(
            "activityId must be a safe workflow journal identity",
        ));
    }
    Ok(())
}

fn validate_placement(kind: &str, options: &Value) -> Result<(), RpcError> {
    if !options.is_object() {
        return Err(RpcError::invalid_params("workflow activity options must be an object"));
    }
    if options.get("on").is_some_and(|host| !host.is_string()) {
        return Err(RpcError::invalid_params("on must name a machine"));
    }
    if let Some(host) = options.get("on").and_then(Value::as_str)
        && kind == "machine"
        && host != "local"
        && host != "ci"
        && host != crate::hub::host_label()
    {
        return Err(RpcError::invalid_params(
            "remote workflow activities require an authenticated machine executor; no local fallback",
        ));
    }
    Ok(())
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
        let activities = match params.get("activityIds") {
            Some(Value::Array(ids)) => ids
                .iter()
                .map(|id| {
                    id.as_str()
                        .ok_or_else(|| RpcError::invalid_params("activityIds must contain strings"))
                })
                .collect::<Result<Vec<_>, _>>()?,
            None => vec![activity],
            _ => return Err(RpcError::invalid_params("activityIds must be an array")),
        };
        if activities.is_empty() {
            return Err(RpcError::invalid_params("activityIds must name activities"));
        }
        for activity in &activities {
            validate_activity_id(
                activity,
                store
                    .activity(id, generation, &run.owner_session_id, activity)
                    .map_err(internal)?
                    .is_some(),
            )?;
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
    validate_activity_id(
        activity,
        store
            .activity(id, generation, &run.owner_session_id, activity)
            .map_err(internal)?
            .is_some(),
    )?;
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
    if kind == "agent" && matches!(options.get("on").and_then(Value::as_str), Some("ci" | "auto")) {
        return Err(RpcError::invalid_params(
            "workflow agents require an explicit peer; ci and auto placement are unavailable",
        ));
    }
    // Command execution on peers remains denied by bg_tasks. A requested placement never
    // silently falls back to this daemon's machine.
    validate_placement(kind, &options)?;
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
    // Read a persisted CI intent on resume; never resolve a newer checkout or target.
    let previous =
        store.activity(id, generation, &run.owner_session_id, activity).map_err(internal)?;
    let child = if kind == "machine" && options.get("on").and_then(Value::as_str) == Some("ci") {
        if let Some(previous) = &previous {
            previous.child.clone()
        } else {
            Child::CiMachine {
                intent: crate::hub::workflow_ci::prepare(&run, activity, prompt, &options).await?,
            }
        }
    } else if kind == "agent" {
        Child::Agent {
            session_id: session,
            prompt_id: format!("wf-{key}-initial"),
            host: options
                .get("on")
                .and_then(Value::as_str)
                .filter(|host| *host != "local" && *host != crate::hub::host_label())
                .map(str::to_owned),
        }
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
                    && let Err(error) = hub.workflow_cancel_activity(&current, &record.id).await
                {
                    result = Err(error);
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

/// An in-process request uses the same initialize caller proof and complete RPC
/// guards as the workflow runner. This creates no person identity and stores no
/// credential in the workflow record.
pub(crate) fn owner_call<'a>(
    hub: &'a Arc<Hub>,
    owner: &'a str,
    method: &'a str,
    params: Value,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value, RpcError>> + Send + 'a>> {
    Box::pin(async move {
        use crate::rpc::Message;
        use tokio::sync::mpsc;
        let (send, input) = mpsc::channel(4);
        let (output, mut receive) = mpsc::channel(256);
        struct Connection(tokio::task::JoinHandle<()>);
        impl Drop for Connection {
            fn drop(&mut self) {
                self.0.abort();
            }
        }
        let _connection =
            Connection(tokio::spawn(super::serve_connection(hub.clone(), input, output)));
        let mut hello = json!({"protocolVersion":1,"clientInfo":{"name":"workflow","version":crate::hub::VERSION}});
        hello.set_path(
            &["_meta", "acpmux", crate::hub::person::CALLER_FIELD],
            json!({
            "sessionId":owner,"token":crate::hub::person::caller_token(owner)}),
        );
        for (id, method, params) in
            [(1, crate::rpc::method::INITIALIZE, hello), (2, method, params)]
        {
            send.send(Message::request(id, method, params).to_line())
                .await
                .map_err(|_| RpcError::internal("workflow RPC connection closed"))?;
            loop {
                let line = receive
                    .recv()
                    .await
                    .ok_or_else(|| RpcError::internal("workflow RPC response missing"))?;
                let reply: Value =
                    serde_json::from_str(&line).map_err(|e| RpcError::internal(e.to_string()))?;
                if reply.get("id") != Some(&json!(id)) {
                    continue;
                }
                if let Some(error) = reply.get("error") {
                    return Err(serde_json::from_value(error.clone())
                        .map_err(|e| RpcError::internal(e.to_string()))?);
                }
                let answer = reply
                    .get("result")
                    .cloned()
                    .ok_or_else(|| RpcError::internal("workflow RPC result missing"))?;
                if id == 1 {
                    if answer.pointer("/_meta/acpmux/callerSessionId").and_then(Value::as_str)
                        != Some(owner)
                    {
                        return Err(RpcError::invalid_params(
                            "workflow owner proof was not accepted",
                        ));
                    }
                } else {
                    return Ok(answer);
                }
                break;
            }
        }
        Err(RpcError::internal("workflow RPC returned no result"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workflow_placement_rejects_present_non_string_and_remote_without_local_fallback() {
        for options in [Value::Null, json!([]), json!("local"), json!(true), json!(7)] {
            for kind in ["agent", "machine"] {
                assert!(validate_placement(kind, &options).is_err());
            }
        }
        for on in [
            json!(["ci"]),
            Value::Null,
            json!(true),
            json!(7),
            json!({"host":"ci"}),
            json!("remote-ci"),
        ] {
            assert!(validate_placement("machine", &json!({"on":on})).is_err());
        }
        assert!(validate_placement("machine", &json!({})).is_ok());
        assert!(validate_placement("machine", &json!({"on":"local"})).is_ok());
        assert!(validate_placement("machine", &json!({"on":"ci"})).is_ok());
        assert!(validate_placement("agent", &json!({"on":"paired-machine"})).is_ok());
        assert!(validate_placement("agent", &json!({"on":["ci"]})).is_err());
    }

    #[test]
    fn workflow_activity_identity_accepts_transport_hash_and_safe_registered_legacy() {
        let generated = crate::workflow_runs::digest(
            "01912345-1234-7123-8123-123456789abc:18446744073709551615",
        );
        assert!(validate_activity_id(&generated, false).is_ok());
        for id in ["test", "test-lint", "legacy_1"] {
            assert!(validate_activity_id(id, false).is_ok());
        }
        for id in ["", "../test", "a:b", "bad/name", "has space", "nonascii-λ", "line\nfeed"] {
            assert!(validate_activity_id(id, false).is_err());
            assert!(validate_activity_id(id, true).is_err());
        }
        let legacy = format!("legacy-{}", generated);
        assert!(validate_activity_id(&legacy, false).is_err());
        assert!(
            validate_activity_id(&legacy, true).is_ok(),
            "existing safe journal records stay addressable"
        );
    }
}
