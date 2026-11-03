//! Local workflow lifecycle RPC. Runner claims require a launch-local proof in addition to
//! the normal owner identity; status never includes source, launch proofs or caller tokens.
use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::RpcError;
use crate::workflow_runs::RunRecord;
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if method != "_acpmux/workflow" {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found("workflows are local only")));
    }
    Some(handle(hub, conn, params).await)
}

fn public(run: &RunRecord) -> Value {
    json!({"runId":run.id,"name":run.name,"ownerSessionId":run.owner_session_id,
        "generation":run.generation,"state":run.state,"sourceHash":run.source_hash,
        "activities":run.activities,"outcome":run.outcome})
}

fn owner(conn: &Conn, run: &RunRecord) -> Result<(), RpcError> {
    if conn.caller() == Some(run.owner_session_id.as_str()) || conn.is_person() {
        Ok(())
    } else {
        Err(RpcError::invalid_params("a chat reaches only its own workflow runs"))
    }
}

async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let text = |key| {
        str_param(params, key).ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
    };
    let action = text("action")?;
    let internal = |e: anyhow::Error| RpcError::internal(format!("{e:#}"));
    if action == "start" {
        let session_id = text("sessionId")?;
        let session = hub.resolve(session_id)?;
        if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
            return Err(RpcError::invalid_params(
                "a workflow needs its owning chat's caller proof",
            ));
        }
        let run = hub
            .workflow_start(
                &session,
                text("name")?.to_owned(),
                text("source")?.to_owned(),
                params.get("args").cloned().unwrap_or_else(|| json!([])),
            )
            .await
            .map_err(internal)?;
        return Ok(public(&run));
    }
    if action == "status" && params.get("runId").is_none() {
        let runs = hub.workflow_runs.store().list().map_err(internal)?;
        return Ok(
            json!({"runs":runs.iter().filter(|run| owner(conn,run).is_ok()).map(public).collect::<Vec<_>>()}),
        );
    }
    let id = text("runId")?;
    if matches!(action, "claim" | "settle" | "check" | "suspend") {
        let generation = params
            .get("generation")
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::invalid_params("generation is required"))?;
        let _gate = hub.workflow_runs.gate(id).lock_owned().await;
        let run = hub
            .workflow_runs
            .authorize_runner(id, generation, text("runnerToken")?)
            .map_err(internal)?;
        owner(conn, &run)?;
        if action == "check" {
            return Ok(json!({"running":true}));
        }
        if action == "suspend" {
            // A fresh-call budget stop keeps the same script and completed activities.
            // Fence while holding the dispatch gate, then stop the owned runner before
            // another generation is allowed to acquire its journal.
            hub.workflow_runs.store().pause(id, &run.owner_session_id).map_err(internal)?;
            drop(_gate);
            return hub
                .workflow_pause(id, &run.owner_session_id)
                .await
                .map(|run| public(&run))
                .map_err(internal);
        }
        if action == "claim" {
            let allowed_tools = hub.workflow_allowed_tools(&run).await.map_err(internal)?;
            let mut caller_env = crate::hub::person::caller_env(&run.owner_session_id)
                .into_iter()
                .collect::<std::collections::BTreeMap<_, _>>();
            caller_env.insert("ACPMUX_SESSION_ID", run.owner_session_id.clone());
            caller_env.insert(crate::agent_tools::AGENT_SESSION_ENV, run.owner_session_id.clone());
            return Ok(json!({"runId":run.id,"generation":run.generation,"source":run.source,
                "args":run.args,"journalDir":hub.workflow_runs.store().directory(id).map_err(internal)?.join("journal"),
                "ownerSessionId":run.owner_session_id,"allowedTools":allowed_tools,
                "callerEnv":caller_env}));
        }
        let outcome = params
            .get("outcome")
            .cloned()
            .ok_or_else(|| RpcError::invalid_params("outcome is required"))?;
        let outcome = serde_json::from_value(outcome)
            .map_err(|e| RpcError::invalid_params(format!("invalid workflow outcome: {e}")))?;
        let run = hub
            .workflow_runs
            .store()
            .settle(id, generation, &run.owner_session_id, outcome)
            .map_err(internal)?;
        if run.state == crate::workflow_runs::State::Failed {
            // The durable terminal fence prevents any more dispatch before cancellation.
            hub.workflow_cancel_children(&run).await.map_err(internal)?;
        }
        return Ok(public(&run));
    }
    let run = hub.workflow_runs.store().get(id).map_err(internal)?;
    owner(conn, &run)?;
    match action {
        "status" => Ok(public(&run)),
        "pause" => hub
            .workflow_pause(id, &run.owner_session_id)
            .await
            .map(|run| public(&run))
            .map_err(internal),
        "resume" => hub
            .workflow_resume(id, &run.owner_session_id)
            .await
            .map(|run| public(&run))
            .map_err(internal),
        _ => Err(RpcError::invalid_params("unknown workflow action")),
    }
}
