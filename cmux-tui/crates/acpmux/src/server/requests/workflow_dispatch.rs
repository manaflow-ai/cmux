//! Durable identity for a workflow's ordinary agent-dispatch request. This
//! grants no new operation: the caller still passes dispatch, peer, person,
//! trust, cwd and admission checks before a child can be created or prompted.
use super::*;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::sync::{OnceLock, Weak};

pub const FEATURE: &str = "durable-agent-dispatch-v1";

#[derive(Clone)]
pub(super) struct Identity {
    pub fingerprint: String,
    pub session_id: String,
    pub prompt_id: String,
}

pub(super) fn requested(params: &Value) -> Result<bool, RpcError> {
    match params.get("durable") {
        None | Some(Value::Bool(false)) => Ok(false),
        Some(Value::Bool(true))
            if params.get("briefId").and_then(Value::as_str).is_some_and(|id| !id.is_empty()) =>
        {
            let token = params.get("receiptToken").and_then(Value::as_str).ok_or_else(|| {
                RpcError::invalid_params("durable dispatch needs a private receiptToken")
            })?;
            if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                return Err(RpcError::invalid_params(
                    "receiptToken must contain 256 random bits as hex",
                ));
            }
            Ok(true)
        }
        Some(Value::Bool(true)) => {
            Err(RpcError::invalid_params("durable dispatch needs an explicit briefId"))
        }
        Some(_) => Err(RpcError::invalid_params("durable must be a boolean")),
    }
}

pub(super) fn identity(params: &Value, id: &str) -> Identity {
    // Forwarding adds attribution and routing metadata. Hash only execution
    // inputs, so the sender and destination agree across reconnects.
    let mut pinned = BTreeMap::new();
    for key in [
        "brief",
        "title",
        "stopCondition",
        "stop_condition",
        "harness",
        "preset",
        "model",
        "effort",
        "policy",
        "route",
        "cwd",
        "allowedTools",
        "receiptToken",
    ] {
        pinned.insert(key, params.get(key).cloned().unwrap_or(Value::Null));
    }
    pinned.insert(
        "brief",
        params.get("brief").or_else(|| params.get("text")).cloned().unwrap_or(Value::Null),
    );
    let bytes = serde_json::to_vec(&pinned).unwrap_or_default();
    let fingerprint = format!("{:x}", Sha256::digest(bytes));
    let namespace = format!("{:x}", Sha256::digest(id.as_bytes()));
    Identity {
        fingerprint,
        session_id: format!("wfd-{namespace}"),
        prompt_id: format!("wfp-{namespace}"),
    }
}

pub(super) fn check(row: &Value, identity: &Identity) -> Result<(), RpcError> {
    if row.get("dispatchFingerprint").and_then(Value::as_str) != Some(identity.fingerprint.as_str())
        || row.get("sessionId").and_then(Value::as_str) != Some(identity.session_id.as_str())
        || row.get("promptId").and_then(Value::as_str) != Some(identity.prompt_id.as_str())
    {
        return Err(RpcError::invalid_params(
            "this durable brief id already pins different inputs",
        )
        .with_data(json!({"reason":"dispatch.identity_changed"})));
    }
    Ok(())
}

/// Legacy list/steer/report requests carry no receipt capability. A durable
/// result is visible there only to its proven local initiating session.
pub(super) fn visible(conn: &Conn, row: &Value) -> bool {
    row.get("durable").and_then(Value::as_bool) != Some(true)
        || (conn.origin != Origin::Peer
            && conn.caller().is_some()
            && row.get("fromSession").and_then(Value::as_str) == conn.caller())
}

pub(super) fn check_caller(conn: &Conn, row: &Value) -> Result<(), RpcError> {
    if conn.origin != Origin::Peer
        && row.get("fromSession").and_then(Value::as_str).is_some()
        && row.get("fromSession").and_then(Value::as_str) != conn.caller()
    {
        return Err(RpcError::not_found("no durable brief for this caller"));
    }
    Ok(())
}

pub(super) fn local_reservation(row: &Value) -> bool {
    row.get("durable").and_then(Value::as_bool) == Some(true)
        && row.get("dispatchLocal").and_then(Value::as_bool) == Some(true)
}

/// `value[key]` without an index: `Null` for a missing key or a value that is not an object.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

pub(super) fn pending(params: &Value, id: &str, identity: &Identity, host: &str) -> Value {
    json!({"briefId":id,"brief":field(params, "brief"),"title":field(params, "title"),"host":host,
        "status":"starting","sessionId":identity.session_id,"promptId":identity.prompt_id,
        "dispatchFingerprint":identity.fingerprint,"durable":true})
}

struct Flight {
    gate: tokio::sync::Mutex<()>,
    active: AtomicBool,
    changed: tokio::sync::Notify,
    failure: StdMutex<Option<String>>,
}
static FLIGHTS: OnceLock<StdMutex<HashMap<String, Weak<Flight>>>> = OnceLock::new();

fn flight(hub: &Arc<Hub>, id: &str) -> Arc<Flight> {
    let key = format!("{:p}:{id}", Arc::as_ptr(hub));
    let mut flights =
        FLIGHTS.get_or_init(StdMutex::default).lock().unwrap_or_else(|e| e.into_inner());
    flights.retain(|_, flight| flight.strong_count() != 0);
    if let Some(flight) = flights.get(&key).and_then(Weak::upgrade) {
        return flight;
    }
    let flight = Arc::new(Flight {
        gate: tokio::sync::Mutex::new(()),
        active: AtomicBool::new(false),
        changed: tokio::sync::Notify::new(),
        failure: StdMutex::new(None),
    });
    flights.insert(key, Arc::downgrade(&flight));
    flight
}

/// Reserve placement under the same gate used by a local child. Concurrent
/// auto picks may disagree, but only the first persisted destination can run.
pub(super) async fn reserve_remote(
    hub: &Arc<Hub>,
    caller: Option<&str>,
    params: &Value,
    id: &str,
    identity: &Identity,
    host: &str,
) -> Result<(), RpcError> {
    let flight = flight(hub, id);
    let _gate = flight.gate.lock().await;
    let row = if let Some(row) = hub.briefs.get(id) {
        if row.get("fromSession").and_then(Value::as_str) != caller {
            return Err(RpcError::not_found("no durable brief for this caller"));
        }
        check(&row, identity)?;
        if row.get("host").and_then(Value::as_str) != Some(host) {
            return Err(RpcError::invalid_params(
                "durable dispatch destination is already pinned; retry to reattach",
            ));
        }
        row
    } else {
        let mut row = pending(params, id, identity, host);
        row.set("fromSession", json!(caller));
        row
    };
    hub.briefs.put_durable(row).map_err(|error| RpcError::internal(error.to_string()))?;
    Ok(())
}

/// Reordered replies from concurrent forwards cannot erase a final receipt.
pub(super) async fn cache_remote(
    hub: &Arc<Hub>,
    id: &str,
    identity: &Identity,
    row: Value,
) -> Result<Value, RpcError> {
    let flight = flight(hub, id);
    let _gate = flight.gate.lock().await;
    let previous = hub
        .briefs
        .get(id)
        .ok_or_else(|| RpcError::not_found("durable dispatch reservation is missing"))?;
    if previous.get("durable").and_then(Value::as_bool) != Some(true)
        || previous.get("briefId").and_then(Value::as_str) != Some(id)
    {
        return Err(RpcError::invalid_params("durable dispatch reservation is not valid"));
    }
    if row.get("briefId").and_then(Value::as_str) != Some(id)
        || row.get("durable").and_then(Value::as_bool) != Some(true)
    {
        return Err(RpcError::invalid_params(
            "peer durable dispatch receipt does not match its requested brief id",
        )
        .with_data(json!({"reason":"dispatch.identity_changed"})));
    }
    check(&previous, identity)?;
    check(&row, identity)?;
    // The source daemon owns the durable identity and routing fields. Start
    // with its reservation, then import only peer-owned result fields. This
    // prevents a peer from moving the receipt to another host or caller while
    // still allowing its final outcome to be replayed locally.
    if previous.get("outcome").is_some() {
        return hub
            .briefs
            .put_durable(previous)
            .map_err(|error| RpcError::internal(error.to_string()));
    }
    let mut merged = previous;
    for key in ["status", "outcome", "error", "harness", "model", "dispatchCancelled"] {
        if let Some(value) = row.get(key) {
            merged.set(key, value.clone());
        }
    }
    hub.briefs.put_durable(merged).map_err(|error| RpcError::internal(error.to_string()))
}

/// Cancelling names exactly the durable prompt, never whichever turn happens
/// to occupy a session. A pre-launch tombstone also fences a delayed dispatch.
pub(super) async fn cancel(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    id: &str,
    mut row: Value,
) -> Result<Value, RpcError> {
    let identity = identity(params, id);
    let flight = flight(hub, id);
    let _gate = flight.gate.lock().await;
    if let Some(previous) = hub.briefs.get(id) {
        check_caller(conn, &previous)?;
        check(&previous, &identity)?;
        if !local_reservation(&previous) {
            return Err(RpcError::invalid_params(
                "durable dispatch destination is already pinned; retry to reattach",
            ));
        }
        row = brief_for(hub, conn, previous, Some(&identity))?;
    } else {
        row.set("sessionId", json!(identity.session_id));
        row.set("promptId", json!(identity.prompt_id));
        row.set("dispatchFingerprint", json!(identity.fingerprint));
        row.set("durable", json!(true));
        row.set("dispatchLocal", json!(true));
    }
    if row.get("outcome").is_none() {
        row.set("status", json!("cancelled"));
        row.set("dispatchCancelled", json!(true));
        row.set(
            "outcome",
            json!({"Err":RpcError::new(-32000,"workflow prompt was cancelled")
            .with_data(json!({"reason":"workflow.cancelled"}))}),
        );
        row = hub.briefs.put_durable(row).map_err(|e| RpcError::internal(e.to_string()))?;
    }
    if row.get("dispatchCancelled").and_then(Value::as_bool) == Some(true) {
        hub.wait_store().await;
        if let Ok(session) = hub.resolve(&identity.session_id) {
            hub.workflow_cancel_dispatch_prompt(&session, &identity.prompt_id).await?;
        }
    }
    flight.changed.notify_waiters();
    Ok(json!({"brief":row}))
}

/// Called after dispatch's ordinary origin/person/trust and destination role
/// checks. The ordinary session/new path repeats its own checks too; only its
/// private identity argument differs from a normal create.
pub(super) async fn local(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    id: &str,
    mut new_params: Value,
    mut row: Value,
) -> Result<Value, RpcError> {
    let identity = identity(params, id);
    let wait = params.get("wait").and_then(Value::as_bool) == Some(true);
    let flight = flight(hub, id);
    let _gate = flight.gate.lock().await;
    if let Some(previous) = hub.briefs.get(id) {
        check_caller(conn, &previous)?;
        check(&previous, &identity)?;
        if !local_reservation(&previous) {
            return Err(RpcError::invalid_params(
                "durable dispatch destination is already pinned; retry to reattach",
            ));
        }
        row = brief_for(hub, conn, previous, Some(&identity))?;
    } else {
        row.set("sessionId", json!(identity.session_id));
        row.set("promptId", json!(identity.prompt_id));
        row.set("dispatchFingerprint", json!(identity.fingerprint));
        row.set("durable", json!(true));
        row.set("dispatchLocal", json!(true));
        row.set("status", json!("starting"));
        row = hub.briefs.put_durable(row).map_err(|e| RpcError::internal(e.to_string()))?;
    }
    if row.get("outcome").is_some() {
        return Ok(json!({"brief":row,"replayed":true}));
    }
    if flight.active.load(Ordering::SeqCst) {
        drop(_gate);
        return answer(hub, &flight, id, wait).await;
    }
    // A crash between session creation and the receipt cannot lose its child:
    // the pending row reserved this exact id before session/new could run.
    hub.wait_store().await;
    let session = match hub.resolve(&identity.session_id) {
        Ok(session) if session.id == identity.session_id => session,
        _ => {
            // Forwarding metadata is already attached by dispatch_brief.
            new_params.set("mcpServers", json!([]));
            Box::pin(dispatch_request_with_identity(
                hub,
                conn,
                method::SESSION_NEW,
                new_params,
                None,
                Some(identity.session_id.clone()),
            ))
            .await?;
            hub.resolve(&identity.session_id)?
        }
    };
    if let Some(ceiling) = params.get("allowedTools").filter(|value| !value.is_null()) {
        let ceiling: Vec<String> = serde_json::from_value(ceiling.clone())
            .map_err(|_| RpcError::invalid_params("allowedTools must be a list of tool names"))?;
        if session.meta().session_env.get(crate::agent_tools::MCP_TOOLS_ENV).map(String::as_str)
            != Some(ceiling.join(",").as_str())
        {
            return Err(RpcError::invalid_params(
                "durable dispatch child tool ceiling differs from its pinned inputs",
            ));
        }
    }
    row.set("status", json!("running"));
    row.set("harness", json!(session.meta().harness));
    row = hub.briefs.put_durable(row).map_err(|e| RpcError::internal(e.to_string()))?;
    let mut prompt = json!({"sessionId":session.id,"text":field(&row, "brief"),
        "_meta":{"acpmux":{"briefId":id,"fromAgent":field(&row, "from")}}});
    if let Some(via) = params.pointer("/_meta/acpmux/via").cloned() {
        prompt.set_path(&["_meta", "acpmux", "via"], via);
    }
    let web = super::super::trust_gate::for_web(conn.origin, &prompt);
    let device = super::super::remote_guard::full_access_device(hub, conn, &prompt);
    let control = super::super::remote_guard::control_of(conn.origin, conn.auth, &prompt);
    let trust_gate = params.pointer("/_meta/acpmux/via").is_some() || web;
    *flight.failure.lock().unwrap_or_else(|e| e.into_inner()) = None;
    flight.active.store(true, Ordering::SeqCst);
    let task_hub = hub.clone();
    let conn = conn.clone();
    let task_row = row.clone();
    let task_flight = flight.clone();
    tokio::spawn(async move {
        let hub = task_hub;
        let id = field(&task_row, "briefId").as_str().unwrap_or_default().to_owned();
        let gate = task_flight.gate.lock().await;
        if hub
            .briefs
            .get(&id)
            .is_some_and(|row| row.get("dispatchCancelled").and_then(Value::as_bool) == Some(true))
        {
            task_flight.active.store(false, Ordering::SeqCst);
            task_flight.changed.notify_waiters();
            return;
        }
        let (accepted, mut admission) = tokio::sync::oneshot::channel();
        let label = conn.label();
        let future = hub.prompt_with(
            &session,
            vec![json!({"type":"text","text":field(&task_row, "brief")})],
            &label,
            false,
            crate::hub::PromptOptions {
                prompt_id: Some(identity.prompt_id.clone()),
                resend: true,
                on_accepted: Some(Box::new(move |value| {
                    let _ = accepted.send(value);
                })),
                control,
                trust_gate,
                agent: field(&task_row, "from").as_str().map(str::to_owned),
                full_access_device: device,
                ..Default::default()
            },
        );
        tokio::pin!(future);
        let outcome = tokio::select! {
            result = &mut future => {drop(gate); result},
            _ = &mut admission => {drop(gate); future.await},
        };
        let outcome = outcome.and_then(|outcome| {
            let reply = hub.workflow_final_reply(&session, &identity.prompt_id, &outcome)?;
            Ok(json!({"promptOutcome":outcome,"finalReply":reply}))
        });
        let mut row = task_row;
        row.set("status", json!("reported"));
        row.set(
            "outcome",
            serde_json::to_value(outcome)
                .unwrap_or_else(|e| json!({"Err":{"code":-32603,"message":e.to_string()}})),
        );
        let _gate = task_flight.gate.lock().await;
        // A pause may have fenced this task while its harness was settling.
        let cancelled = hub
            .briefs
            .get(&id)
            .is_some_and(|row| row.get("dispatchCancelled").and_then(Value::as_bool) == Some(true));
        if !cancelled && let Err(error) = hub.briefs.put_durable(row) {
            tracing::warn!(brief_id=id, %error, "persist durable dispatch outcome");
            *task_flight.failure.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(error.to_string());
        }
        task_flight.active.store(false, Ordering::SeqCst);
        task_flight.changed.notify_waiters();
    });
    drop(_gate);
    answer(hub, &flight, id, wait).await
}

async fn answer(hub: &Hub, flight: &Flight, id: &str, wait: bool) -> Result<Value, RpcError> {
    loop {
        let changed = flight.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        let row = hub
            .briefs
            .get(id)
            .ok_or_else(|| RpcError::not_found("durable dispatch receipt missing"))?;
        if !wait || row.get("outcome").is_some() {
            return Ok(json!({"brief":row}));
        }
        if let Some(error) = flight.failure.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return Err(RpcError::internal(format!(
                "durable dispatch outcome was not persisted: {error}"
            )));
        }
        changed.await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn durable_dispatch_keeps_one_destination_and_never_loses_a_finished_reply() {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let params = json!({"brief":"effect","durable":true,"briefId":"placement"});
        let identity = identity(&params, "placement");
        let (one, two) = tokio::join!(
            reserve_remote(&hub, None, &params, "placement", &identity, "one"),
            reserve_remote(&hub, None, &params, "placement", &identity, "two"),
        );
        assert_ne!(one.is_ok(), two.is_ok(), "two destinations admitted one effect");
        let pending = hub.briefs.get("placement").unwrap();
        let mut finished = pending.clone();
        finished.set("status", json!("reported"));
        finished.set("outcome", json!({"Ok":{"finalReply":"exact reply"}}));
        let mut remote = finished.clone();
        remote.set("dispatchLocal", json!(true));
        let cached = cache_remote(&hub, "placement", &identity, remote).await.unwrap();
        assert!(
            cached.get("dispatchLocal").is_none(),
            "a peer's reservation was marked local here"
        );
        let late = cache_remote(&hub, "placement", &identity, pending).await.unwrap();
        assert_eq!(late, finished, "a late pending response erased the final reply");
        assert_eq!(hub.briefs.get("placement"), Some(finished));
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn cache_remote_rejects_peer_key_or_durability_changes_and_keeps_local_routing() {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let params = json!({
            "briefId":"local-id",
            "durable":true,
            "receiptToken":"1111111111111111111111111111111111111111111111111111111111111111",
            "brief":"local brief",
            "title":"local title"
        });
        let identity = identity(&params, "local-id");
        reserve_remote(&hub, Some("caller"), &params, "local-id", &identity, "paired-target")
            .await
            .unwrap();
        let reserved = hub.briefs.get("local-id").unwrap();
        let victim = json!({
            "briefId":"other-id",
            "durable":true,
            "sessionId":"wfd-victim",
            "promptId":"wfp-victim",
            "dispatchFingerprint":"victim-fingerprint",
            "status":"running"
        });
        hub.briefs.put_durable(victim.clone()).unwrap();

        let mut wrong_id = reserved.clone();
        wrong_id.set("briefId", json!("other-id"));
        assert!(cache_remote(&hub, "local-id", &identity, wrong_id).await.is_err());
        assert_eq!(hub.briefs.get("other-id"), Some(victim), "peer key overwrote another receipt");
        assert_eq!(hub.briefs.get("local-id"), Some(reserved.clone()));

        let mut advisory = reserved.clone();
        advisory.set("durable", json!(false));
        assert!(cache_remote(&hub, "local-id", &identity, advisory).await.is_err());
        assert_eq!(hub.briefs.get("local-id"), Some(reserved.clone()));

        let mut finished = reserved.clone();
        finished.set("host", json!("attacker-host"));
        finished.set("fromSession", json!("attacker-caller"));
        finished.set("dispatchLocal", json!(true));
        finished.set("status", json!("reported"));
        finished.set("outcome", json!({"Ok":{"finalReply":"done"}}));
        let cached = cache_remote(&hub, "local-id", &identity, finished).await.unwrap();
        assert_eq!(cached["host"], reserved["host"]);
        assert_eq!(cached["fromSession"], reserved["fromSession"]);
        assert!(cached.get("dispatchLocal").is_none());
        assert_eq!(cached["outcome"]["Ok"]["finalReply"], "done");
        hub.shutdown_all().await;
    }

    #[test]
    fn durable_dispatch_pins_execution_inputs_but_not_forwarding_metadata() {
        let base = json!({"durable":true,"receiptToken":"1111111111111111111111111111111111111111111111111111111111111111","briefId":"activity","brief":"original","harness":"codex"});
        assert!(requested(&base).unwrap());
        assert!(requested(&json!({"durable":true})).is_err());
        let identity = identity(&base, "activity");
        let mut forwarded = base.clone();
        forwarded.set("forwarded", json!(true));
        forwarded.set("host", json!("remote"));
        assert_eq!(identity.fingerprint, super::identity(&forwarded, "activity").fingerprint);
        let row = pending(&base, "activity", &identity, "remote");
        check(&row, &identity).unwrap();
        forwarded.set("brief", json!("changed"));
        assert!(check(&row, &super::identity(&forwarded, "activity")).is_err());
        assert_ne!(identity.session_id, super::identity(&base, "another").session_id);
    }
}
