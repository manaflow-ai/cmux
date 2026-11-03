//! Durable workflow child execution over existing session and background-task machinery.
use super::*;
use crate::workflow_reply::{
    AttemptKey, RecoveryAction, RecoveryEvent, RecoveryState, ReplyDecision, ReplyPolicy,
    ReplyState,
};
use crate::workflow_runs::{ActivityRecord, Child, RunRecord};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Default)]
struct Policy {
    correction: Option<String>,
    reply: Option<ReplyState>,
    #[serde(default)]
    recovery: Option<RecoveryState>,
    #[serde(default)]
    observation: u64,
    #[serde(default)]
    epoch: u64,
}

impl Hub {
    pub(crate) async fn workflow_execute(
        self: &Arc<Self>,
        run: &RunRecord,
        generation: u64,
        activity: &ActivityRecord,
        prompt: &str,
        options: &Value,
    ) -> Result<Value, RpcError> {
        match &activity.child {
            Child::Machine { session_id, task_id, .. } => {
                let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                self.workflow_runs
                    .store()
                    .authorize(&run.id, generation, &run.owner_session_id)
                    .map_err(workflow_error)?;
                let session = self.resolve(session_id)?;
                self.workflow_activity_scope(run, "machine").await?;
                let mut policy: Policy = if activity.policy.is_null() {
                    Policy::default()
                } else {
                    serde_json::from_value(activity.policy.clone()).map_err(workflow_error)?
                };
                let previous_id = format!("{task_id}-g{}", policy.epoch);
                if policy.epoch != 0 && policy.epoch != generation {
                    if self.workflow_bg_uncertain(&session, &previous_id) {
                        return Err(RpcError::internal(
                            "prior workflow task launch is uncertain; resume cannot execute it twice",
                        ));
                    }
                    let previous = self.bg_list(&session);
                    let previous =
                        previous.get("tasks").and_then(Value::as_array).and_then(|rows| {
                            rows.iter().find(|row| {
                                row.get("id").and_then(Value::as_str) == Some(previous_id.as_str())
                            })
                        });
                    if previous.is_some_and(|row| {
                        matches!(
                            row.get("state").and_then(Value::as_str),
                            Some("running" | "exited")
                        )
                    }) {
                        drop(gate);
                        return self.workflow_bg_wait(&session, &previous_id).await;
                    }
                }
                policy.epoch = generation;
                self.workflow_runs
                    .store()
                    .update_activity_policy(
                        &run.id,
                        generation,
                        &run.owner_session_id,
                        &activity.id,
                        serde_json::to_value(policy).map_err(workflow_error)?,
                    )
                    .map_err(workflow_error)?;
                let task_id = format!("{task_id}-g{generation}");
                self.workflow_runs
                    .store()
                    .register_activity(
                        &run.id,
                        generation,
                        &run.owner_session_id,
                        ActivityRecord {
                            id: format!("{}-task-{generation}", activity.id),
                            kind: "machine_task".into(),
                            fingerprint: activity.fingerprint.clone(),
                            child: Child::Machine {
                                session_id: session.id.clone(),
                                task_id: task_id.clone(),
                                host: None,
                            },
                            policy: Value::Null,
                            outcome: None,
                        },
                    )
                    .map_err(workflow_error)?;
                self.bg_start_with_id(&session, prompt, Some(run.cwd.clone()), Some(&task_id))
                    .await?;
                drop(gate);
                self.workflow_bg_wait(&session, &task_id).await
            }
            Child::Agent { session_id, prompt_id, .. } => {
                let key = AttemptKey::new(&activity.id);
                let mut state: Policy = if activity.policy.is_null() {
                    Policy::default()
                } else {
                    serde_json::from_value(activity.policy.clone()).map_err(workflow_error)?
                };
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
                let mut recovery =
                    state.recovery.clone().unwrap_or_else(|| RecoveryState::new(key.clone()));
                if state.epoch == 0 {
                    state.epoch = generation;
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
                let stall = std::time::Duration::from_millis(
                    options.get("stallMs").and_then(Value::as_u64).unwrap_or(300_000).max(1),
                );
                'attempt: loop {
                    let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                    self.workflow_runs
                        .store()
                        .authorize(&run.id, generation, &run.owner_session_id)
                        .map_err(workflow_error)?;
                    let restarted = recovery.key.generation > 0;
                    let allowed = self.workflow_activity_scope(run, "agent").await?;
                    if restarted && let Ok(previous) = self.resolve(session_id) {
                        let previous_id = format!(
                            "{prompt_id}-g{}-0-{}",
                            state.epoch,
                            if state.correction.is_some() { 1 } else { 0 }
                        );
                        self.remove_queued(&previous, &previous_id);
                        if previous.turn().is_some_and(|turn| turn.prompt_id == previous_id) {
                            self.cancel(&previous).await?;
                        }
                    }
                    let session_id = if restarted {
                        format!("{session_id}-restart")
                    } else {
                        session_id.clone()
                    };
                    let session = match self.resolve(&session_id) {
                        Ok(session) => session,
                        Err(_) => {
                            let pick = |field| {
                                options.get(field).and_then(Value::as_str).map(str::to_owned)
                            };
                            let mut env = std::collections::BTreeMap::new();
                            if let Some(allowed) = &allowed {
                                env.insert(
                                    crate::agent_tools::MCP_TOOLS_ENV.into(),
                                    allowed.join(","),
                                );
                            }
                            self.new_session_with_id(
                                NewRequest {
                                    harness: pick(if restarted {
                                        "fallbackHarness"
                                    } else {
                                        "harness"
                                    }),
                                    model: pick("model"),
                                    effort: pick("effort"),
                                    route: pick(if restarted { "fallbackRoute" } else { "route" }),
                                    name: Some(pick("name").unwrap_or_else(|| run.name.clone())),
                                    cwd: Some(run.cwd.clone()),
                                    starter: Some(run.owner_session_id.clone()),
                                    env,
                                    ..Default::default()
                                },
                                Some(session_id.clone()),
                            )
                            .await?
                        }
                    };
                    let corrected = state.correction.is_some();
                    if let Some(allowed) = &allowed {
                        let recorded = session
                            .meta()
                            .session_env
                            .get(crate::agent_tools::MCP_TOOLS_ENV)
                            .cloned();
                        let expected = allowed.join(",");
                        if recorded.as_deref() != Some(expected.as_str()) {
                            return Err(RpcError::invalid_params(
                                "workflow child tool scope changed; refusing a wider existing child",
                            ));
                        }
                    }
                    let text = state.correction.as_deref().unwrap_or(prompt).to_owned();
                    let current_id = format!(
                        "{prompt_id}-g{}-{}-{}",
                        state.epoch,
                        recovery.key.generation,
                        if corrected { 1 } else { 0 }
                    );
                    // Each exact prompt is also a child handle, including the correction, so
                    // pause fences and cancels whichever prompt is currently admitted.
                    let child_id = format!(
                        "{}-prompt-{}-{}-{}",
                        activity.id,
                        state.epoch,
                        recovery.key.generation,
                        if corrected { 1 } else { 0 }
                    );
                    self.workflow_runs
                        .store()
                        .register_activity(
                            &run.id,
                            generation,
                            &run.owner_session_id,
                            ActivityRecord {
                                id: child_id.clone(),
                                kind: "agent_prompt".into(),
                                fingerprint: crate::workflow_runs::digest(&text),
                                child: Child::Agent {
                                    session_id: session_id.clone(),
                                    prompt_id: current_id.clone(),
                                    host: None,
                                },
                                policy: Value::Null,
                                outcome: None,
                            },
                        )
                        .map_err(workflow_error)?;
                    let (accepted, mut admission) = tokio::sync::oneshot::channel();
                    let mut events = self.subscribe();
                    let future = self.prompt_with(
                        &session,
                        vec![json!({"type":"text","text":text})],
                        "workflow",
                        false,
                        PromptOptions {
                            prompt_id: Some(current_id.clone()),
                            resend: true,
                            agent: Some(run.owner_session_id.clone()),
                            on_accepted: Some(Box::new(move |value| {
                                let _ = accepted.send(value);
                            })),
                            ..Default::default()
                        },
                    );
                    tokio::pin!(future);
                    let mut gate = Some(gate);
                    let mut admitted = false;
                    let mut waiting = false;
                    let deadline = tokio::time::sleep(stall);
                    tokio::pin!(deadline);
                    let outcome = loop {
                        tokio::select! {
                            result = &mut future => {drop(gate.take()); break result?;},
                            _ = &mut admission, if !admitted => {admitted=true; drop(gate.take());},
                            event = events.recv() => {
                                match event {
                                    Ok(event) if event.session_id == session.id => {
                                        waiting = session.status() == SessionStatus::Waiting || session.meta().usage_limits.is_some();
                                        deadline.as_mut().reset(tokio::time::Instant::now()+stall);
                                    }
                                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return Err(RpcError::internal("workflow event stream closed")),
                                    _ => {},
                                }
                            }
                            _ = &mut deadline, if admitted && !waiting => {
                                if session.status() == SessionStatus::Waiting || session.meta().usage_limits.is_some() {
                                    waiting = true;
                                    continue;
                                }
                                let action_gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                                self.workflow_runs.store().authorize(&run.id,generation,&run.owner_session_id).map_err(workflow_error)?;
                                state.observation += 1;
                                let current = recovery.key.clone();
                                let action = recovery.observe(&current,state.observation,RecoveryEvent::Stalled);
                                state.recovery = Some(recovery.clone());
                                self.workflow_runs.store().update_activity_policy(&run.id,generation,&run.owner_session_id,
                                    &activity.id,serde_json::to_value(&state).map_err(workflow_error)?).map_err(workflow_error)?;
                                match action {
                                    RecoveryAction::Nudge => {
                                        let hub = self.clone();
                                        let session = session.clone();
                                        let run = run.clone();
                                        let nudge_id = format!("{current_id}-nudge");
                                        self.workflow_runs.store().register_activity(&run.id,generation,&run.owner_session_id,ActivityRecord {
                                            id:format!("{}-nudge",activity.id),kind:"agent_nudge".into(),fingerprint:"continue".into(),
                                            child:Child::Agent {session_id:session.id.clone(),prompt_id:nudge_id.clone(),host:None},policy:Value::Null,outcome:None,
                                        }).map_err(workflow_error)?;
                                        tokio::spawn(async move {
                                            let (send, mut accepted) = tokio::sync::oneshot::channel();
                                            let nudge = hub.prompt_with(&session,vec![json!({"type":"text","text":"Please continue and report your current progress."})],
                                                "workflow",true,PromptOptions {prompt_id:Some(nudge_id),resend:true,steer_only:true,
                                                    agent:Some(run.owner_session_id),on_accepted:Some(Box::new(move |v| {let _=send.send(v);})),..Default::default()});
                                            tokio::pin!(nudge);
                                            tokio::select! { _ = &mut nudge => {drop(action_gate);}, _ = &mut accepted => {drop(action_gate); let _=nudge.await;} }
                                        });
                                        deadline.as_mut().reset(tokio::time::Instant::now()+stall);
                                    }
                                    RecoveryAction::Restart {..} => {
                                        let alternate = options.get("fallbackHarness").and_then(Value::as_str).filter(|h| *h != session.meta().harness)
                                            .is_some() || options.get("fallbackRoute").and_then(Value::as_str)
                                                .is_some_and(|r| options.get("route").and_then(Value::as_str) != Some(r));
                                        if !alternate {return Err(RpcError::internal("workflow stalled after nudge; no different permitted fallback harness or route configured"));}
                                        self.remove_queued(&session,&current_id);
                                        if session.turn().is_some_and(|turn| turn.prompt_id == current_id) {self.cancel(&session).await?;}
                                        drop(action_gate);
                                        continue 'attempt;
                                    }
                                    _ => return Err(RpcError::internal("workflow agent stalled after its one restart")),
                                }
                            }
                        }
                    };
                    if outcome.get("stopReason").and_then(Value::as_str) == Some("cancelled")
                        || outcome.pointer("/_meta/acpmux/status").and_then(Value::as_str)
                            == Some("interrupted")
                    {
                        if state.epoch < generation {
                            state.epoch = generation;
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
                            continue 'attempt;
                        }
                        return Err(RpcError::internal("workflow prompt was cancelled"));
                    }
                    let reply = self.workflow_final_reply(&session, &current_id, &outcome)?;
                    let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                    self.workflow_runs
                        .store()
                        .complete_activity(
                            &run.id,
                            generation,
                            &run.owner_session_id,
                            &child_id,
                            Ok(json!(reply)),
                        )
                        .map_err(workflow_error)?;
                    let Some(validator) = validator.as_mut() else {
                        return Ok(json!(reply));
                    };
                    let decision = validator.observe(&key, if corrected { 2 } else { 1 }, &reply);
                    if let ReplyDecision::Correct { prompt, .. } = &decision {
                        state.reply = Some(validator.state().clone());
                        state.correction = Some(prompt.clone());
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
                            return Err(RpcError::internal(
                                "workflow reply policy was already terminal",
                            ));
                        }
                    }
                }
            }
        }
    }

    pub(crate) async fn workflow_activity_scope(
        &self,
        run: &RunRecord,
        kind: &str,
    ) -> Result<Option<Vec<String>>, RpcError> {
        let allowed = self.workflow_allowed_tools(run).await.map_err(workflow_error)?;
        if let Some(allowed) = &allowed {
            let operation = if kind == "agent" { "agent_dispatch" } else { "acpmux_bg_start" };
            if !allowed.iter().any(|tool| tool == "cmux_workflow")
                || !allowed.iter().any(|tool| tool == operation)
            {
                return Err(RpcError::invalid_params(
                    "workflow activity is outside its owner's current tool scope",
                ));
            }
        }
        Ok(allowed)
    }

    /// Called under the run gate, after checking its generation, on a terminal failure.
    pub(crate) async fn workflow_cancel_activity(
        self: &Arc<Self>,
        run: &RunRecord,
        activity: &str,
    ) -> Result<(), RpcError> {
        let prefix = format!("{activity}-");
        for child in run.activities.values().filter(|child| {
            child.outcome.is_none() && (child.id == activity || child.id.starts_with(&prefix))
        }) {
            match &child.child {
                Child::Agent { session_id, prompt_id, .. } => {
                    if let Ok(session) = self.resolve(session_id) {
                        self.remove_queued(&session, prompt_id);
                        if session.turn().is_some_and(|turn| turn.prompt_id == *prompt_id) {
                            self.cancel(&session).await?;
                        }
                    }
                }
                Child::Machine { session_id, task_id, .. } => {
                    if let Ok(session) = self.resolve(session_id) {
                        match self.bg_stop(&session, task_id).await {
                            Err(error) if error.code != RpcError::not_found("").code => {
                                return Err(error);
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// Read the final assistant message inside this prompt's exact persisted turn window.
    /// A person's later messages never become a workflow result; subagent output is excluded.
    fn workflow_final_reply(
        &self,
        session: &Session,
        prompt_id: &str,
        outcome: &Value,
    ) -> Result<String, RpcError> {
        let mut turn =
            outcome.pointer("/_meta/acpmux/turnId").and_then(Value::as_str).map(str::to_owned);
        let mut active = false;
        let mut reply = String::new();
        let mut message_open = false;
        self.store
            .scan_strict(&session.id, 0, &mut |record| {
                if record.dir == "mux" && record.kind == "turn_started" {
                    if record.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) {
                        turn = record.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                        active = true;
                    } else if active {
                        return false;
                    }
                }
                if !active {
                    return true;
                }
                if record.dir == "mux"
                    && matches!(record.kind.as_str(), "turn_end" | "turn_error" | "turn_result")
                    && record.msg.get("turnId").and_then(Value::as_str) == turn.as_deref()
                {
                    return false;
                }
                if record.dir == "in"
                    && record.msg.pointer("/params/_meta/acpmux/subagent").is_none()
                {
                    match record.kind.as_str() {
                        "agent_message_chunk" => {
                            if let Some(text) = record
                                .msg
                                .pointer("/params/update/content/text")
                                .and_then(Value::as_str)
                            {
                                if !message_open {
                                    reply.clear();
                                    message_open = true;
                                }
                                reply.push_str(text);
                            }
                        }
                        "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan" => {
                            message_open = false
                        }
                        _ => {}
                    }
                }
                true
            })
            .map_err(workflow_error)?;
        if !active {
            return Err(RpcError::internal("workflow prompt has no exact persisted turn"));
        }
        Ok(reply)
    }
}

fn workflow_error(error: impl std::fmt::Display) -> RpcError {
    RpcError::internal(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn workflow_reply_reads_only_exact_final_message_before_human_followup() {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,"id":"s",
            "name":"s","harness":"fake","cwd":"/tmp","status":"closed","createdAt":1,"updatedAt":2})).unwrap();
        store.save(&meta).unwrap();
        let hub = Hub::new(config, store);
        let session = hub.resolve("s").unwrap();
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"promptId":"workflow-prompt","turnId":"t"}),
        );
        let chunk = |text| json!({"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}});
        hub.append(&session, "in", "agent_message_chunk", chunk("Working on it"));
        hub.append(&session, "in", "tool_call", json!({}));
        hub.append(&session, "in", "agent_message_chunk", chunk("{\"ok\":"));
        hub.append(&session, "in", "agent_message_chunk", chunk("true}"));
        let mut subagent = chunk("WRONG SUBAGENT");
        subagent["params"]["_meta"] = json!({"acpmux":{"subagent":"child"}});
        hub.append(&session, "in", "agent_message_chunk", subagent);
        hub.append(&session, "mux", "turn_end", json!({"turnId":"t"}));
        hub.append(&session, "mux", "turn_started", json!({"promptId":"human","turnId":"later"}));
        hub.append(&session, "in", "agent_message_chunk", chunk("WRONG FOLLOWUP"));
        assert_eq!(
            hub.workflow_final_reply(&session, "workflow-prompt", &json!({})).unwrap(),
            "{\"ok\":true}"
        );
        assert!(hub.workflow_final_reply(&session, "missing", &json!({})).is_err());
        hub.shutdown_all().await;
    }
}
