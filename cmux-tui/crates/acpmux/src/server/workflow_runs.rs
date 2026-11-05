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
    if conn.caller() == Some(run.owner_session_id.as_str())
        || conn.is_person()
        || (run.local_principal && conn.origin == super::Origin::Local && conn.caller().is_none())
    {
        Ok(())
    } else {
        Err(RpcError::invalid_params("a chat reaches only its own workflow runs"))
    }
}

async fn handle(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let text = |key| {
        str_param(params, key).ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
    };
    let action = text("action")?;
    let internal = |e: anyhow::Error| RpcError::internal(format!("{e:#}"));
    if action == "start" {
        let local_principal = str_param(params, "sessionId").is_none() && conn.caller().is_none();
        let session = if let Some(session_id) =
            str_param(params, "sessionId").or_else(|| conn.caller())
        {
            let session = hub.resolve(session_id)?;
            if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
                return Err(RpcError::invalid_params(
                    "a workflow needs its owning chat's caller proof",
                ));
            }
            session
        } else {
            if conn.origin != super::Origin::Local {
                return Err(RpcError::invalid_params(
                    "a standalone workflow starts over the local Unix socket",
                ));
            }
            // Reuse every existing session/new policy, trust, admission and folder gate.
            // Request only the asking mode; a same-uid CLI never receives person authority.
            let create = json!({"cwd":text("cwd")?,"_meta":{"acpmux":{
                "name":format!("Workflow {}",text("name")?),"policy":"ask"
            }}});
            let created = Box::pin(super::requests::handle_request(
                hub,
                conn,
                crate::rpc::method::SESSION_NEW,
                create,
            ))
            .await?;
            let session_id = created.get("sessionId").and_then(Value::as_str).ok_or_else(|| {
                RpcError::internal("workflow owner creation returned no sessionId")
            })?;
            hub.resolve(session_id)?
        };
        let run = hub
            .workflow_start(
                &session,
                text("name")?.to_owned(),
                text("source")?.to_owned(),
                params.get("args").cloned().unwrap_or_else(|| json!([])),
                local_principal,
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
            return Ok(
                json!({"running":true,"allowedTools":hub.workflow_allowed_tools(&run).await.map_err(internal)?,
                    "upstreamNames":hub.workflow_upstream_names(&run).await.map_err(internal)?}),
            );
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
