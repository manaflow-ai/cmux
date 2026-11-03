//! Peer agent calls reuse durable dispatch, including its origin and permission
//! checks. The run owns a persisted dispatch request before anything is sent.
use super::*;

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
    let brief_id = format!("{}-remote-g{epoch}-{}", activity.id, u8::from(corrected));
    let brief_id =
        format!("wf-{}", crate::workflow_runs::digest(&format!("{}:{brief_id}", run.id)));
    let mut request = json!({"durable":true,"briefId":brief_id,"host":host,"brief":text,
        "title":options.get("name").and_then(Value::as_str).unwrap_or(&run.name),
        "cwd":options.get("cwd").cloned().unwrap_or_else(||json!(run.cwd)),"policy":"ask","allowedTools":allowed,"wait":true});
    for field in ["harness", "preset", "model", "effort", "route", "policy"] {
        if let Some(value) = options.get(field) {
            request[field] = value.clone();
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
            let request = remote_request(
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
        request["action"] = json!("cancel");
        request["wait"] = json!(false);
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
mod tests {
    use super::*;
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn remote_workflow_agent_journals_guarded_dispatch_and_reuses_the_reply() {
        let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_workflow_agent.py");
        let mut config: crate::config::Config =
            serde_json::from_value(json!({"defaultHarness":"fake",
            "harnesses":{"fake":{"argv":["python3",fixture]}}}))
            .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let owner: SessionMeta = serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,
            "id":"remote-owner","name":"Remote owner","harness":"fake","cwd":std::env::temp_dir(),
            "status":"closed","createdAt":1,"updatedAt":2}))
        .unwrap();
        store.save(&owner).unwrap();
        let hub = Hub::new(config, store);
        let run = hub
            .workflow_runs
            .store()
            .start(RunRecord {
                version: 1,
                id: format!("wf-test-{}", uuid::Uuid::now_v7().simple()),
                name: "Remote workflow".into(),
                owner_session_id: owner.id,
                local_principal: false,
                source: "await agent('schema-once')".into(),
                source_hash: String::new(),
                args: json!([]),
                allowed_tools: None,
                cwd: std::env::temp_dir(),
                generation: 1,
                state: crate::workflow_runs::State::Running,
                activities: Default::default(),
                outcome: None,
            })
            .unwrap();
        let activity = ActivityRecord {
            id: "remote-agent".into(),
            kind: "agent".into(),
            fingerprint: "pinned".into(),
            child: Child::Agent {
                session_id: "pending".into(),
                prompt_id: "pending".into(),
                host: Some("local".into()),
            },
            policy: Value::Null,
            outcome: None,
        };
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, &run.owner_session_id, activity.clone())
            .unwrap();
        let options = json!({"harness":"fake","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}});
        let explicit_cwd = remote_request(
            &run,
            &activity,
            1,
            false,
            "task",
            &json!({"cwd":"/remote/project"}),
            "paired-machine",
            &None,
        );
        assert_eq!(explicit_cwd["cwd"], "/remote/project");
        assert!(
            hub.workflow_remote_agent(
                &run,
                run.generation,
                &activity,
                "task",
                &json!({"cwd":7}),
                "local"
            )
            .await
            .is_err()
        );
        // Exercise the complete owner-authenticated RPC path in process; the
        // peer transport itself is covered by dispatch_durable integration tests.
        let value = tokio::time::timeout(
            std::time::Duration::from_secs(20),
            hub.workflow_remote_agent(
                &run,
                run.generation,
                &activity,
                "schema-once",
                &options,
                "local",
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(value, json!({"ok":true}));
        let saved = hub.workflow_runs.store().get(&run.id).unwrap();
        let attempts = saved
            .activities
            .values()
            .filter(|a| a.kind == "remote_agent_prompt")
            .collect::<Vec<_>>();
        assert_eq!(attempts.len(), 2, "schema correction budget did not persist");
        assert!(
            attempts
                .iter()
                .all(|a| a.policy.get("remoteDispatch").is_some() && a.outcome.is_some())
        );
        let saved_activity = saved.activities.get(&activity.id).unwrap();
        assert_eq!(
            hub.workflow_remote_agent(
                &saved,
                saved.generation,
                saved_activity,
                "schema-once",
                &options,
                "local"
            )
            .await
            .unwrap(),
            value
        );
        let replay = hub.workflow_runs.store().get(&run.id).unwrap();
        assert_eq!(
            replay.activities.len(),
            saved.activities.len(),
            "replay dispatched another effect"
        );
        assert!(
            crate::server::workflow_owner_call(
                &hub,
                "nonexistent-owner",
                crate::rpc::method::MUX_STATUS,
                json!({})
            )
            .await
            .is_err()
        );
        hub.shutdown_all().await;
        std::fs::remove_dir_all(hub.workflow_runs.store().directory(&run.id).unwrap()).unwrap();
    }

    #[test]
    fn remote_workflow_reply_never_falls_back_to_another_turn() {
        assert!(reply(&json!({"brief":{"sessionId":"other"},"lastReply":"unrelated"})).is_err());
        assert_eq!(
            reply(&json!({"brief":{"outcome":{"Ok":{"finalReply":"exact","promptOutcome":{}}}}}))
                .unwrap(),
            "exact"
        );
        assert!(reply(&json!({"brief":{"outcome":{"Ok":{"finalReply":"partial","promptOutcome":{"stopReason":"cancelled"}}}}})).is_err());
    }
}
