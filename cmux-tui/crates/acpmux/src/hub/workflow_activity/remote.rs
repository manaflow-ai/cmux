//! Peer agent calls reuse durable dispatch, including its origin and permission
//! checks. The run owns a persisted dispatch request before anything is sent.
use super::*;

fn remote_brief_id(run_id: &str, activity_id: &str, epoch: u64, corrected: bool) -> String {
    format!(
        "wf-{}",
        crate::workflow_runs::digest(&format!(
            "{run_id}:{activity_id}-remote-g{epoch}-{}",
            u8::from(corrected)
        ))
    )
}

fn remote_request(
    run: &RunRecord,
    activity: &ActivityRecord,
    epoch: u64,
    corrected: bool,
    text: &str,
    options: &Value,
    host: &str,
    allowed: &Option<Vec<String>>,
) -> Value {
    let brief_id = remote_brief_id(&run.id, &activity.id, epoch, corrected);
    // A domain-separated, per-brief capability cannot authorize another brief
    // or recover the owner's general caller proof. Only its hash reaches the receipt.
    let receipt_token =
        cmux_local_auth::frontend_proof::hex(&cmux_local_auth::frontend_proof::hmac_sha256(
            crate::hub::person::caller_token(&run.owner_session_id).as_bytes(),
            format!("workflow-dispatch-receipt-v1:{brief_id}").as_bytes(),
        ));
    let mut request = json!({"receiptToken":receipt_token,"durable":true,"briefId":brief_id,"host":host,"brief":text,
        "title":options.get("name").and_then(Value::as_str).unwrap_or(&run.name),
        "cwd":options.get("cwd").cloned().unwrap_or_else(||json!(run.cwd)),"policy":"ask","allowedTools":allowed,"wait":true});
    for field in ["harness", "preset", "model", "effort", "route", "policy"] {
        if let Some(value) = options.get(field) {
            request.set(field, value.clone());
        }
    }
    request
}

fn dispatch_child(request: &Value, host: &str) -> Result<Child, RpcError> {
    use sha2::{Digest, Sha256};
    let id = request
        .get("briefId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::internal("remote workflow intent has no brief id"))?;
    let digest = format!("{:x}", Sha256::digest(id.as_bytes()));
    Ok(Child::Agent {
        session_id: format!("wfd-{digest}"),
        prompt_id: format!("wfp-{digest}"),
        host: Some(host.into()),
    })
}

/// A reserved-looking logical sibling is never an owned remote effect. Match
/// the internal kind and the complete persisted dispatch identity, including
/// the exact destination, before a parent failure may send its cancellation.
pub(super) fn child_of(run_id: &str, parent: &ActivityRecord, child: &ActivityRecord) -> bool {
    if parent.kind != "agent" || child.kind != "remote_agent_prompt" {
        return false;
    }
    let Child::Agent { host: Some(host), .. } = &parent.child else {
        return false;
    };
    let Some((epoch, corrected)) = child
        .id
        .strip_prefix(&format!("{}-remote-", parent.id))
        .and_then(|suffix| suffix.split_once('-'))
    else {
        return false;
    };
    let Ok(epoch) = epoch.parse::<u64>() else {
        return false;
    };
    if !matches!(corrected, "0" | "1")
        || child.id != format!("{}-remote-{epoch}-{corrected}", parent.id)
    {
        return false;
    }
    let Some(request) = child.policy.get("remoteDispatch") else {
        return false;
    };
    let brief_id = remote_brief_id(run_id, &parent.id, epoch, corrected == "1");
    request.get("briefId").and_then(Value::as_str) == Some(brief_id.as_str())
        && request.get("host").and_then(Value::as_str) == Some(host.as_str())
        && request.get("durable").and_then(Value::as_bool) == Some(true)
        && child.fingerprint == crate::workflow_runs::digest(&request.to_string())
        && dispatch_child(request, host).is_ok_and(|expected| child.child == expected)
}

fn reply(result: &Value) -> Result<String, RpcError> {
    let outcome = result
        .pointer("/brief/outcome")
        .ok_or_else(|| RpcError::internal("durable remote agent returned no final outcome"))?;
    if let Some(error) = outcome.get("Err") {
        return Err(serde_json::from_value(error.clone()).map_err(workflow_error)?);
    }
    let outcome =
        outcome.get("Ok").ok_or_else(|| RpcError::internal("invalid remote agent outcome"))?;
    if outcome.pointer("/promptOutcome/stopReason").and_then(Value::as_str) == Some("cancelled")
        || outcome.pointer("/promptOutcome/_meta/acpmux/status").and_then(Value::as_str)
            == Some("interrupted")
    {
        return Err(RpcError::new(-32000, "remote workflow prompt was cancelled")
            .with_data(json!({"reason":"workflow.cancelled"})));
    }
    outcome
        .get("finalReply")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| RpcError::internal("remote agent returned no exact final reply"))
}

impl Hub {
    pub(crate) async fn workflow_cancel_dispatch_prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt: &str,
    ) -> Result<(), RpcError> {
        self.remove_queued(session, prompt);
        self.cancel_prompt(session, prompt).await
    }

    pub(super) async fn workflow_remote_agent(
        self: &Arc<Self>,
        run: &RunRecord,
        generation: u64,
        activity: &ActivityRecord,
        prompt: &str,
        options: &Value,
        host: &str,
    ) -> Result<Value, RpcError> {
        if matches!(host, "ci" | "auto") {
            return Err(RpcError::invalid_params(
                "workflow agents require an explicit peer; ci and auto placement are unavailable",
            ));
        }
        if options.get("cwd").is_some_and(|cwd| !cwd.is_string()) {
            return Err(RpcError::invalid_params("remote agent cwd must be a path string"));
        }
        let mut state: Policy = if activity.policy.is_null() {
            Policy::default()
        } else {
            serde_json::from_value(activity.policy.clone()).map_err(workflow_error)?
        };
        let key = AttemptKey::new(&activity.id);
        let mut validator = options
            .get("schema")
            .map(|schema| {
                ReplyPolicy::new(
                    schema,
                    state.reply.clone().unwrap_or_else(|| ReplyState::new(key.clone())),
                )
            })
            .transpose()
            .map_err(workflow_error)?;
        if state.epoch == 0 {
            state.epoch = generation;
        }
        loop {
            let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
            self.workflow_runs
                .store()
                .authorize(&run.id, generation, &run.owner_session_id)
                .map_err(workflow_error)?;
            let allowed = self.workflow_activity_scope(run, "agent").await?;
            let corrected = state.correction.is_some();
            let text = state.correction.as_deref().unwrap_or(prompt);
            let mut request = remote_request(
                run,
                activity,
                state.epoch,
                corrected,
                text,
                options,
                host,
                &allowed,
            );
            let child_id =
                format!("{}-remote-{}-{}", activity.id, state.epoch, u8::from(corrected));
            // The daemon's caller proof rotates at restart. Reattach with the
            // per-brief capability already persisted before the original send.
            if let Some(previous) = self
                .workflow_runs
                .store()
                .get(&run.id)
                .map_err(workflow_error)?
                .activities
                .get(&child_id)
                && let Some(token) = previous.policy.pointer("/remoteDispatch/receiptToken")
            {
                request.set("receiptToken", token.clone());
            }
            self.workflow_runs
                .store()
                .update_activity_policy(
                    &run.id,
                    generation,
                    &run.owner_session_id,
                    &activity.id,
                    serde_json::to_value(&state).map_err(workflow_error)?,
                )
                .map_err(workflow_error)?;
            let intent = self
                .workflow_runs
                .store()
                .register_activity(
                    &run.id,
                    generation,
                    &run.owner_session_id,
                    ActivityRecord {
                        id: child_id.clone(),
                        kind: "remote_agent_prompt".into(),
                        fingerprint: crate::workflow_runs::digest(&request.to_string()),
                        child: dispatch_child(&request, host)?,
                        policy: json!({"remoteDispatch":request}),
                        outcome: None,
                    },
                )
                .map_err(workflow_error)?;
            // This gate fences registration only. Pause can send a tombstone while
            // dispatch is in flight; the same brief gate prevents a later launch.
            drop(gate);
            let result = if let Some(outcome) = intent.outcome.clone() {
                outcome.map_err(|error| {
                    serde_json::from_value::<RpcError>(error)
                        .unwrap_or_else(|_| RpcError::internal("remote workflow child failed"))
                })
            } else {
                let result = Box::pin(crate::server::workflow_owner_call(
                    self,
                    &run.owner_session_id,
                    crate::rpc::method::MUX_DISPATCH,
                    request,
                ))
                .await
                .and_then(|value| reply(&value).map(Value::String));
                self.workflow_complete_child(run, generation, &child_id, &result).await?;
                result
            };
            if let Err(error) = &result
                && error.data.as_ref().and_then(|data| data.get("reason")).and_then(Value::as_str)
                    == Some("workflow.cancelled")
                && state.epoch < generation
            {
                state.epoch = generation;
                continue;
            }
            let answer = result?;
            let text =
                answer.as_str().ok_or_else(|| RpcError::internal("remote reply was not text"))?;
            let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
            self.workflow_runs
                .store()
                .authorize(&run.id, generation, &run.owner_session_id)
                .map_err(workflow_error)?;
            let Some(validator) = validator.as_mut() else {
                return Ok(answer);
            };
            let decision = validator.observe(&key, if corrected { 2 } else { 1 }, text);
            if let ReplyDecision::Correct { prompt: correction, .. } = &decision {
                state.reply = Some(validator.state().clone());
                // Correction is another durable agent call. Include the original
                // task and reply because its child has a separate transcript.
                state.correction = Some(format!(
                    "Original task:\n{prompt}\nPrevious reply:\n{text}\n{correction}"
                ));
                self.workflow_runs
                    .store()
                    .update_activity_policy(
                        &run.id,
                        generation,
                        &run.owner_session_id,
                        &activity.id,
                        serde_json::to_value(&state).map_err(workflow_error)?,
                    )
                    .map_err(workflow_error)?;
            }
            drop(gate);
            match decision {
                ReplyDecision::Accept(value) => return Ok(value),
                ReplyDecision::Correct { .. } => {}
                ReplyDecision::Fail { issues } => {
                    return Err(RpcError::internal(
                        "workflow agent reply failed its JSON schema after correction",
                    )
                    .with_data(json!(issues)));
                }
                ReplyDecision::Ignore => {
                    return Err(RpcError::internal("workflow reply policy was already terminal"));
                }
            }
        }
    }

    /// The only remotely cancellable handle is an already registered dispatch
    /// intent. No supplied session ID or generic session/cancel is forwarded.
    pub(crate) async fn workflow_cancel_remote(
        self: &Arc<Self>,
        run: &RunRecord,
        activity: &ActivityRecord,
    ) -> Result<(), RpcError> {
        let Some(mut request) = activity.policy.get("remoteDispatch").cloned() else {
            // Parent activity has no effect; its registered children own effects.
            if activity.kind == "agent" {
                return Ok(());
            }
            return Err(RpcError::internal("remote workflow child has no durable dispatch intent"));
        };
        let host = request
            .get("host")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::internal("remote workflow intent has no target"))?;
        if activity.child != dispatch_child(&request, host)? {
            return Err(RpcError::internal(
                "remote workflow child differs from its dispatch intent",
            ));
        }
        request.set("action", json!("cancel"));
        request.set("wait", json!(false));
        Box::pin(crate::server::workflow_owner_call(
            self,
            &run.owner_session_id,
            crate::rpc::method::MUX_DISPATCH,
            request,
        ))
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests;
