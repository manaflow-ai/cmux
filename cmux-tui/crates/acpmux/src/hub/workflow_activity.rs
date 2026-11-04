//! Durable workflow child execution over existing session and background-task machinery.
use super::*;
use crate::workflow_reply::{
    AttemptKey, RecoveryAction, RecoveryEvent, RecoveryState, ReplyDecision, ReplyPolicy,
    ReplyState, WaitReason,
};
use crate::workflow_runs::{ActivityRecord, Child, RunRecord};
use serde::{Deserialize, Serialize};
mod remote;

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
    #[serde(default)]
    nudge: Option<Nudge>,
    #[serde(default)]
    route_nudge: bool,
    #[serde(default)]
    waiting_for: Option<String>,
    #[serde(default)]
    restart_prompt_id: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
struct Nudge {
    id: String,
    session_id: String,
    prompt_id: String,
    target_prompt_id: String,
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
        if options.get("on").is_some_and(|host| !host.is_string()) {
            return Err(RpcError::invalid_params("on must name a machine"));
        }
        if let Some(host) = options.get("on").and_then(Value::as_str)
            && host != "local"
            && host != crate::hub::host_label()
            && matches!(&activity.child, Child::Agent { .. })
        {
            return Box::pin(
                self.workflow_remote_agent(run, generation, activity, prompt, options, host),
            )
            .await;
        }
        match &activity.child {
            Child::CiMachine { intent } => {
                self.workflow_ci_execute(run, generation, activity, intent).await
            }
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
                        let result = self.workflow_bg_wait(&session, &previous_id).await;
                        self.workflow_complete_child(
                            run,
                            generation,
                            &format!("{}-task-{}", activity.id, policy.epoch),
                            &result,
                        )
                        .await?;
                        return result;
                    }
                    let child_id = format!("{}-task-{}", activity.id, policy.epoch);
                    if self
                        .workflow_runs
                        .store()
                        .activity(&run.id, generation, &run.owner_session_id, &child_id)
                        .map_err(workflow_error)?
                        .is_some_and(|child| child.outcome.is_none())
                    {
                        self.workflow_runs.store().complete_activity(&run.id,generation,&run.owner_session_id,&child_id,
                            Err(json!({"code":"activity.cancelled","message":"task stopped before explicit resume"}))).map_err(workflow_error)?;
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
                self.bg_start_with_id(
                    &session,
                    prompt,
                    Some(run.cwd.clone()),
                    Some(&task_id),
                    None,
                    false,
                    false,
                )
                .await?;
                drop(gate);
                let result = self.workflow_bg_wait(&session, &task_id).await;
                self.workflow_complete_child(
                    run,
                    generation,
                    &format!("{}-task-{generation}", activity.id),
                    &result,
                )
                .await?;
                result
            }
            Child::Agent { session_id, prompt_id, .. } => {
                let mut key = AttemptKey::new(&activity.id);
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
                let resumed_wait = state.waiting_for.is_some() && state.epoch < generation;
                if resumed_wait {
                    // Pause fenced the old retry chain. An explicit resume authorizes a
                    // fresh prompt in this same session/account, never another route.
                    state.waiting_for = None;
                    state.observation += 1;
                    let current = recovery.key.clone();
                    recovery.observe(&current, state.observation, RecoveryEvent::Resumed);
                    state.recovery = Some(recovery.clone());
                }
                if state.epoch == 0 || resumed_wait {
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
                    if key != recovery.key
                        && let Some(validator) = validator.as_mut()
                    {
                        validator.rebind(recovery.key.clone());
                    }
                    key = recovery.key.clone();
                    let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                    self.workflow_runs
                        .store()
                        .authorize(&run.id, generation, &run.owner_session_id)
                        .map_err(workflow_error)?;
                    let restarted = recovery.key.generation > 0;
                    let allowed = self.workflow_activity_scope(run, "agent").await?;
                    if restarted && let Ok(previous) = self.resolve(session_id) {
                        let previous_id = state.restart_prompt_id.clone().unwrap_or_else(|| {
                            format!(
                                "{prompt_id}-g{}-0-{}",
                                state.epoch,
                                if state.correction.is_some() { 1 } else { 0 }
                            )
                        });
                        self.remove_queued(&previous, &previous_id);
                        self.cancel_prompt(&previous, &previous_id).await?;
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
                                    })
                                    .or_else(|| pick("harness")),
                                    model: pick("model"),
                                    effort: pick("effort"),
                                    route: pick(if restarted { "fallbackRoute" } else { "route" }),
                                    name: Some(format!(
                                        "{} · {}",
                                        pick("name").unwrap_or_else(|| run.name.clone()),
                                        crate::workflow_runs::digest(&session_id)
                                            .chars()
                                            .take(12)
                                            .collect::<String>()
                                    )),
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
                    let requested = state.correction.as_deref().unwrap_or(prompt);
                    let text = if state.route_nudge {
                        format!(
                            "Please continue the task after the route failure. Check what already finished before repeating any effect.\nOriginal task:\n{requested}"
                        )
                    } else {
                        requested.to_owned()
                    };
                    let current_id = state.waiting_for.clone().unwrap_or_else(|| {
                        format!(
                            "{prompt_id}-g{}-{}-{}",
                            state.epoch,
                            recovery.key.generation,
                            if corrected { 1 } else { 0 }
                        ) + if state.route_nudge { "-route-nudge" } else { "" }
                    });
                    // Each exact prompt is also a child handle, including the correction, so
                    // pause fences and cancels whichever prompt is currently admitted.
                    let child_id = format!(
                        "{}-prompt-{}",
                        activity.id,
                        crate::workflow_runs::digest(&current_id)
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
                    let automatic = state.waiting_for.is_some();
                    let waiting_id = current_id.clone();
                    let future = async {
                        if automatic {
                            // The normal daemon retry owns admission and its account's wait.
                            // Join its exact prompt outcome without submitting another effect.
                            let mut changes = self.subscribe();
                            while !self.knows_prompt(&session, &waiting_id, true) {
                                self.workflow_runs
                                    .store()
                                    .authorize(&run.id, generation, &run.owner_session_id)
                                    .map_err(workflow_error)?;
                                match changes.recv().await {
                                    Ok(_)
                                    | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                                    Err(error) => return Err(workflow_error(error)),
                                }
                            }
                            let outcome = self.prompt_outcome(&session, &waiting_id);
                            tokio::pin!(outcome);
                            let mut accepted = Some(accepted);
                            loop {
                                // A queued retry still belongs to the daemon's account wait.
                                // Only its exact running turn starts workflow stall recovery.
                                if session.turn().is_some_and(|turn| turn.prompt_id == waiting_id)
                                    && let Some(accepted) = accepted.take()
                                {
                                    let _ = accepted.send(json!({"state":"started"}));
                                }
                                tokio::select! {
                                    result = &mut outcome => break result,
                                    event = changes.recv() => {
                                        self.workflow_runs.store().authorize(&run.id,generation,&run.owner_session_id).map_err(workflow_error)?;
                                        if let Err(error) = event && !matches!(error,tokio::sync::broadcast::error::RecvError::Lagged(_)) {
                                            return Err(workflow_error(error));
                                        }
                                    }
                                }
                            }
                        } else {
                            self.prompt_with(
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
                            )
                            .await
                        }
                    };
                    tokio::pin!(future);
                    let mut gate = if automatic {
                        drop(gate);
                        None
                    } else {
                        Some(gate)
                    };
                    let mut admitted = false;
                    let mut admission_open = true;
                    let mut waiting = false;
                    let mut nudge_reconciled = false;
                    let deadline = tokio::time::sleep(stall);
                    tokio::pin!(deadline);
                    let outcome = loop {
                        tokio::select! {
                            result = &mut future => {drop(gate.take()); break result;},
                            value = &mut admission, if admission_open => {
                                admission_open=false;
                                if value.is_err() {continue;}
                                admitted=true; drop(gate.take());
                                waiting = session.status() == SessionStatus::Waiting || crate::claude_stdio::usage_limit_reached(session.meta().usage_limits.as_ref(), (super::now_ms() / 1000) as i64);
                                if automatic && recovery.waiting.is_some() {
                                    let admission_gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                                    self.workflow_runs.store().authorize(&run.id,generation,&run.owner_session_id).map_err(workflow_error)?;
                                    state.observation += 1;
                                    let current = recovery.key.clone();
                                    recovery.observe(&current,state.observation,RecoveryEvent::Resumed);
                                    state.recovery = Some(recovery.clone());
                                    self.workflow_runs.store().update_activity_policy(&run.id,generation,&run.owner_session_id,&activity.id,serde_json::to_value(&state).map_err(workflow_error)?).map_err(workflow_error)?;
                                    drop(admission_gate);
                                }
                                deadline.as_mut().reset(tokio::time::Instant::now()+stall);
                                if let Some(nudge) = &state.nudge {nudge_reconciled=self.workflow_nudge(run,generation,nudge).await?;}
                            },
                            event = events.recv() => {
                                match event {
                                    Ok(event) if event.session_id == session.id => {
                                        waiting = session.status() == SessionStatus::Waiting || crate::claude_stdio::usage_limit_reached(session.meta().usage_limits.as_ref(), (super::now_ms() / 1000) as i64);
                                        if admitted && !waiting && !nudge_reconciled && let Some(nudge) = &state.nudge {nudge_reconciled=self.workflow_nudge(run,generation,nudge).await?;}
                                        deadline.as_mut().reset(tokio::time::Instant::now()+stall);
                                    }
                                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return Err(RpcError::internal("workflow event stream closed")),
                                    _ => {},
                                }
                            }
                            _ = &mut deadline, if admitted && !waiting => {
                                if session.status() == SessionStatus::Waiting || crate::claude_stdio::usage_limit_reached(session.meta().usage_limits.as_ref(), (super::now_ms() / 1000) as i64) {
                                    waiting = true;
                                    continue;
                                }
                                let action_gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                                self.workflow_runs.store().authorize(&run.id,generation,&run.owner_session_id).map_err(workflow_error)?;
                                state.observation += 1;
                                let current = recovery.key.clone();
                                let action = recovery.observe(&current,state.observation,RecoveryEvent::Stalled);
                                state.recovery = Some(recovery.clone());
                                if action == RecoveryAction::Nudge {
                                    state.nudge = Some(Nudge {id:format!("{}-nudge",activity.id),session_id:session.id.clone(),
                                        prompt_id:format!("{current_id}-nudge"),target_prompt_id:current_id.clone()});
                                } else if matches!(action, RecoveryAction::Restart { .. }) {
                                    // The daemon retry belongs to the original session. A
                                    // fallback must reserve its own prompt identity before
                                    // admission, including after recovery from this write.
                                    state.restart_prompt_id = Some(current_id.clone());
                                    state.waiting_for = None;
                                    state.route_nudge = false;
                                }
                                self.workflow_runs.store().update_activity_policy(&run.id,generation,&run.owner_session_id,
                                    &activity.id,serde_json::to_value(&state).map_err(workflow_error)?).map_err(workflow_error)?;
                                match action {
                                    RecoveryAction::Nudge => {
                                        drop(action_gate);
                                        if let Some(nudge) = &state.nudge {nudge_reconciled=self.workflow_nudge(run,generation,nudge).await?;}
                                        deadline.as_mut().reset(tokio::time::Instant::now()+stall);
                                    }
                                    RecoveryAction::Restart {..} => {
                                        let alternate = options.get("fallbackHarness").and_then(Value::as_str).filter(|h| *h != session.meta().harness)
                                            .is_some() || options.get("fallbackRoute").and_then(Value::as_str)
                                                .is_some_and(|r| options.get("route").and_then(Value::as_str) != Some(r));
                                        if !alternate {return Err(RpcError::internal("workflow stalled after nudge; no different permitted fallback harness or route configured"));}
                                        self.remove_queued(&session,&current_id);
                                        self.cancel_prompt(&session,&current_id).await?;
                                        drop(action_gate);
                                        continue 'attempt;
                                    }
                                    _ => return Err(RpcError::internal("workflow agent stalled after its one restart")),
                                }
                            }
                        }
                    };
                    let outcome = match outcome {
                        Ok(outcome) => outcome,
                        Err(error) => {
                            self.workflow_complete_child(
                                run,
                                generation,
                                &child_id,
                                &Err(error.clone()),
                            )
                            .await?;
                            let observation = workflow_error_observation(&error);
                            let action_gate = self.workflow_runs.gate(&run.id).lock_owned().await;
                            self.workflow_runs
                                .store()
                                .authorize(&run.id, generation, &run.owner_session_id)
                                .map_err(workflow_error)?;
                            if recovery.waiting.is_some() {
                                state.observation += 1;
                                let current = recovery.key.clone();
                                recovery.observe(
                                    &current,
                                    state.observation,
                                    RecoveryEvent::Resumed,
                                );
                            }
                            state.observation += 1;
                            let current = recovery.key.clone();
                            let action =
                                recovery.observe(&current, state.observation, observation.clone());
                            state.recovery = Some(recovery.clone());
                            match action {
                                RecoveryAction::Wait(_) => {
                                    state.waiting_for = Some(workflow_next_retry(&current_id));
                                }
                                RecoveryAction::Nudge => {
                                    state.route_nudge = true;
                                    state.waiting_for = None;
                                }
                                RecoveryAction::Restart { .. } => {
                                    let alternate = options
                                        .get("fallbackHarness")
                                        .and_then(Value::as_str)
                                        .is_some_and(|h| h != session.meta().harness)
                                        || options
                                            .get("fallbackRoute")
                                            .and_then(Value::as_str)
                                            .is_some_and(|r| {
                                                options.get("route").and_then(Value::as_str)
                                                    != Some(r)
                                            });
                                    if !alternate {
                                        return Err(RpcError::internal("workflow route failed after nudge; no different permitted fallback harness or route configured").with_data(json!({"original":error.message})));
                                    }
                                    state.restart_prompt_id = Some(current_id.clone());
                                    state.route_nudge = false;
                                    state.waiting_for = None;
                                }
                                _ => return Err(error),
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
                            if !matches!(action, RecoveryAction::Wait(_)) {
                                self.cancel_prompt(&session, &current_id).await?;
                            }
                            drop(action_gate);
                            continue 'attempt;
                        }
                    };
                    if state.waiting_for.is_some() {
                        state.waiting_for = None;
                        state.observation += 1;
                        let current = recovery.key.clone();
                        recovery.observe(&current, state.observation, RecoveryEvent::Resumed);
                        state.recovery = Some(recovery.clone());
                    }
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

    async fn workflow_complete_child(
        &self,
        run: &RunRecord,
        generation: u64,
        id: &str,
        result: &Result<Value, RpcError>,
    ) -> Result<(), RpcError> {
        let _gate = self.workflow_runs.gate(&run.id).lock_owned().await;
        let store = self.workflow_runs.store();
        if store
            .activity(&run.id, generation, &run.owner_session_id, id)
            .map_err(workflow_error)?
            .is_some_and(|activity| activity.outcome.is_none())
        {
            store.complete_activity(&run.id,generation,&run.owner_session_id,id,
                result.clone().map_err(|error|json!({"code":error.code,"message":error.message,"data":error.data}))).map_err(workflow_error)?;
        }
        Ok(())
    }

    /// Reconcile the persisted action with its exact target turn before another escalation.
    /// Repeated calls join the same prompt ID; a terminal target records a superseded action.
    async fn workflow_nudge(
        self: &Arc<Self>,
        run: &RunRecord,
        generation: u64,
        intent: &Nudge,
    ) -> Result<bool, RpcError> {
        let gate = self.workflow_runs.gate(&run.id).lock_owned().await;
        let record = self
            .workflow_runs
            .store()
            .register_activity(
                &run.id,
                generation,
                &run.owner_session_id,
                ActivityRecord {
                    id: intent.id.clone(),
                    kind: "agent_nudge".into(),
                    fingerprint: "continue".into(),
                    child: Child::Agent {
                        session_id: intent.session_id.clone(),
                        prompt_id: intent.prompt_id.clone(),
                        host: None,
                    },
                    policy: Value::Null,
                    outcome: None,
                },
            )
            .map_err(workflow_error)?;
        if record.outcome.is_some() {
            return Ok(true);
        }
        let session = self.resolve(&intent.session_id)?;
        if session.status() == SessionStatus::Waiting
            || crate::claude_stdio::usage_limit_reached(
                session.meta().usage_limits.as_ref(),
                (super::now_ms() / 1000) as i64,
            )
        {
            return Ok(false);
        }
        let known = self.knows_prompt(&session, &intent.prompt_id, true);
        if known {
            self.workflow_runs
                .store()
                .complete_activity(
                    &run.id,
                    generation,
                    &run.owner_session_id,
                    &intent.id,
                    Ok(json!({"admitted":true,"replayed":true})),
                )
                .map_err(workflow_error)?;
            return Ok(true);
        }
        let target = session.turn().filter(|turn| turn.prompt_id == intent.target_prompt_id);
        if !known && target.is_none() {
            self.workflow_runs.store().complete_activity(&run.id,generation,&run.owner_session_id,&intent.id,
                Err(json!({"code":"activity.superseded","message":"nudge target already ended"}))).map_err(workflow_error)?;
            return Ok(true);
        }
        let hub = self.clone();
        let run = run.clone();
        let intent = intent.clone();
        tokio::spawn(async move {
            let (send, mut accepted) = tokio::sync::oneshot::channel();
            let future=hub.prompt_with(&session,vec![json!({"type":"text","text":"Please continue and report your current progress."})],
                "workflow",true,PromptOptions {prompt_id:Some(intent.prompt_id),resend:true,steer_only:true,
                    interrupt_turn:target.map(|turn|turn.turn_id),agent:Some(run.owner_session_id.clone()),
                    on_accepted:Some(Box::new(move |value|{let _=send.send(value);})),..Default::default()});
            tokio::pin!(future);
            let result = tokio::select! {
                result=&mut future=>{drop(gate);result},
                accepted=&mut accepted=>{
                    drop(gate);
                    if let Ok(value)=accepted {let _=hub.workflow_complete_child(&run,generation,&intent.id,&Ok(value)).await;}
                    future.await
                },
            };
            let _ = hub.workflow_complete_child(&run, generation, &intent.id, &result).await;
        });
        Ok(true)
    }

    /// Called under the run gate, after checking its generation, on a terminal failure.
    pub(crate) async fn workflow_cancel_activity(
        self: &Arc<Self>,
        run: &RunRecord,
        activity: &str,
    ) -> Result<(), RpcError> {
        let Some(parent) = run.activities.get(activity) else {
            return Ok(());
        };
        for child in run.activities.values().filter(|child| {
            child.outcome.is_none()
                && (child.id == activity || workflow_child_of(run, parent, child))
        }) {
            match &child.child {
                Child::CiMachine { intent } => {
                    self.workflow_ci_cancel(child, intent).await?;
                }
                Child::Agent { session_id, prompt_id, host } => {
                    if host.as_deref().is_some_and(|host| host != "local") {
                        self.workflow_cancel_remote(run, child).await?;
                    } else if let Ok(session) = self.resolve(session_id) {
                        self.remove_queued(&session, prompt_id);
                        self.cancel_prompt(&session, prompt_id).await?;
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
            if child.id != activity {
                let _ = self.workflow_runs.store().complete_activity(&run.id,run.generation,&run.owner_session_id,
                    &child.id,Err(json!({"code":"activity.cancelled","message":"workflow child was superseded or stopped"})));
            }
        }
        Ok(())
    }

    /// Read the final assistant message inside this prompt's exact persisted turn window.
    /// A person's later messages never become a workflow result; subagent output is excluded.
    pub(crate) fn workflow_final_reply(
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

/// Internal child kinds cannot be requested by the runner. Require their exact
/// deterministic identity and owned session/task as well, so a logical sibling
/// named like `test-prompt-x` is never mistaken for a child of `test`.
fn workflow_child_of(run: &RunRecord, parent: &ActivityRecord, child: &ActivityRecord) -> bool {
    if remote::child_of(&run.id, parent, child) {
        return true;
    }
    match (&parent.child, &child.child, child.kind.as_str()) {
        (
            Child::Agent { session_id, prompt_id, host },
            Child::Agent { session_id: owned, prompt_id: prompt, host: owned_host },
            "agent_prompt",
        ) => {
            owned_host == host
                && (owned == session_id || owned == &format!("{session_id}-restart"))
                && prompt.strip_prefix(prompt_id).is_some_and(|suffix| suffix.starts_with("-g"))
                && child.id
                    == format!("{}-prompt-{}", parent.id, crate::workflow_runs::digest(prompt))
        }
        (
            Child::Agent { host, .. },
            Child::Agent { session_id, prompt_id, host: owned_host },
            "agent_nudge",
        ) => {
            owned_host == host
                && serde_json::from_value::<Policy>(parent.policy.clone())
                    .ok()
                    .and_then(|policy| policy.nudge)
                    .is_some_and(|intent| {
                        intent.id == child.id
                            && intent.session_id == *session_id
                            && intent.prompt_id == *prompt_id
                    })
        }
        (
            Child::Machine { session_id, task_id, host },
            Child::Machine { session_id: owned, task_id: task, host: owned_host },
            "machine_task",
        ) => {
            owned == session_id
                && owned_host == host
                && child.fingerprint == parent.fingerprint
                && task
                    .strip_prefix(task_id)
                    .and_then(|suffix| suffix.strip_prefix("-g"))
                    .and_then(|generation| generation.parse::<u64>().ok())
                    .is_some_and(|generation| {
                        task == &format!("{task_id}-g{generation}")
                            && child.id == format!("{}-task-{generation}", parent.id)
                    })
        }
        _ => false,
    }
}

fn workflow_error(error: impl std::fmt::Display) -> RpcError {
    RpcError::internal(error.to_string())
}

fn workflow_error_observation(error: &RpcError) -> RecoveryEvent {
    let text = format!("{} {}", error.message, error.data.as_ref().unwrap_or(&Value::Null));
    if super::turn_errors::is_usage_limit_error(&text) {
        RecoveryEvent::Waiting(WaitReason::UsageLimit { reset_at_ms: None })
    } else if super::turn_errors::is_capacity_error(&text) {
        RecoveryEvent::Waiting(WaitReason::Capacity)
    } else if error
        .data
        .as_ref()
        .and_then(|data| data.get("reason"))
        .and_then(Value::as_str)
        .is_some_and(|reason| reason.starts_with("permission.") || reason.starts_with("policy."))
    {
        RecoveryEvent::Waiting(WaitReason::Permission)
    } else if super::turn_errors::is_transport_error(&text)
        || super::turn_errors::is_gateway_error(&text)
        || error
            .data
            .as_ref()
            .and_then(|data| data.get("reason"))
            .and_then(Value::as_str)
            .is_some_and(|reason| reason.starts_with("route."))
        || text.to_ascii_lowercase().contains("route unavailable")
    {
        RecoveryEvent::RouteError
    } else {
        RecoveryEvent::Failed
    }
}

fn workflow_next_retry(prompt: &str) -> String {
    if let Some((root, attempt)) = prompt.rsplit_once("~resume-")
        && let Ok(attempt) = attempt.parse::<u64>()
    {
        return format!("{root}~resume-{}", attempt.saturating_add(1));
    }
    format!("{prompt}~resume-1")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn activity_chat() -> (Arc<Hub>, RunRecord, ActivityRecord) {
        let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_workflow_agent.py");
        let mut config: crate::config::Config =
            serde_json::from_value(json!({"defaultHarness":"fake","autoResumeDelaysMs":[1000],
            "harnesses":{"fake":{"argv":["python3",fixture]},"fake-alternate":{"argv":["python3",fixture,"alternate"]}}}))
            .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let owner:crate::store::SessionMeta=serde_json::from_value(json!({"schema":crate::store::META_SCHEMA,
            "id":"owner","name":"owner","harness":"fake","cwd":"/tmp","status":"closed","createdAt":1,"updatedAt":2})).unwrap();
        store.save(&owner).unwrap();
        let hub = Hub::new(config, store);
        let id = format!("wf-test-{}", uuid::Uuid::now_v7().simple());
        let run = hub
            .workflow_runs
            .store()
            .start(RunRecord {
                version: 1,
                id: id.clone(),
                name: "Test workflow".into(),
                owner_session_id: "owner".into(),
                source: "await agent('test')".into(),
                source_hash: String::new(),
                args: json!([]),
                allowed_tools: None,
                cwd: std::env::temp_dir(),
                generation: 1,
                state: crate::workflow_runs::State::Running,
                activities: Default::default(),
                outcome: None,
                local_principal: false,
            })
            .unwrap();
        let child = ActivityRecord {
            id: "activity".into(),
            kind: "agent".into(),
            fingerprint: "pinned".into(),
            child: Child::Agent {
                session_id: format!("{id}-child"),
                prompt_id: format!("{id}-prompt"),
                host: None,
            },
            policy: Value::Null,
            outcome: None,
        };
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, "owner", child.clone())
            .unwrap();
        (hub, run, child)
    }

    async fn cleanup(hub: Arc<Hub>, run: RunRecord) {
        hub.shutdown_all().await;
        // This test created the UUID-named directory; no other run is touched.
        std::fs::remove_dir_all(hub.workflow_runs.store().directory(&run.id).unwrap()).unwrap();
    }

    fn turns(hub: &Hub, child: &ActivityRecord) -> usize {
        let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
        let mut turns = 0;
        hub.store
            .scan_strict(session_id, 0, &mut |record| {
                if record.kind == "turn_started" {
                    turns += 1;
                }
                true
            })
            .unwrap();
        turns
    }

    #[tokio::test]
    async fn workflow_invalid_placement_cannot_create_a_local_agent() {
        let (hub, run, child) = activity_chat();
        for on in [json!(["ci"]), Value::Null, json!(true), json!(4), json!({"host":"ci"})] {
            let error = hub
                .workflow_execute(&run, run.generation, &child, "test", &json!({"on":on}))
                .await
                .unwrap_err();
            assert_eq!(error.code, RpcError::invalid_params("").code);
        }
        let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
        assert!(
            hub.resolve(session_id).is_err(),
            "invalid placement cannot silently launch locally"
        );
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_parallel_activities_have_distinct_names_with_same_title() {
        let (hub, run, first) = activity_chat();
        let mut second = first.clone();
        second.id = "second".into();
        second.child = Child::Agent {
            session_id: format!("{}-second", run.id),
            prompt_id: format!("{}-second-prompt", run.id),
            host: None,
        };
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, "owner", second.clone())
            .unwrap();
        let options = json!({"harness":"fake","name":"Shared title"});
        let (a, b) = tokio::time::timeout(std::time::Duration::from_secs(15), async {
            tokio::join!(
                hub.workflow_execute(&run, run.generation, &first, "test", &options),
                hub.workflow_execute(&run, run.generation, &second, "test", &options)
            )
        })
        .await
        .unwrap();
        assert_eq!(a.unwrap(), json!("{\"ok\":true}"));
        assert_eq!(b.unwrap(), json!("{\"ok\":true}"));
        let name = |activity: &ActivityRecord| {
            let Child::Agent { session_id, .. } = &activity.child else { unreachable!() };
            hub.resolve(session_id).unwrap().meta().name
        };
        let (a, b) = (name(&first), name(&second));
        assert!(a.starts_with("Shared title · ") && b.starts_with("Shared title · "));
        assert_ne!(a, b);
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_cancellation_preserves_reserved_looking_logical_siblings() {
        let (hub, run, mut parent) = activity_chat();
        parent.id = "test".into();
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, "owner", parent.clone())
            .unwrap();
        let Child::Agent { session_id, prompt_id, host } = &parent.child else { unreachable!() };
        let prompt = format!("{prompt_id}-g1-0-0");
        let owned = ActivityRecord {
            id: format!("test-prompt-{}", crate::workflow_runs::digest(&prompt)),
            kind: "agent_prompt".into(),
            child: Child::Agent {
                session_id: session_id.clone(),
                prompt_id: prompt,
                host: host.clone(),
            },
            ..parent.clone()
        };
        hub.workflow_runs
            .store()
            .register_activity(&run.id, run.generation, "owner", owned.clone())
            .unwrap();
        for id in ["test-lint", "test-prompt-x", "test-task-1", "test-nudge-x"] {
            let sibling = ActivityRecord { id: id.into(), ..parent.clone() };
            hub.workflow_runs
                .store()
                .register_activity(&run.id, run.generation, "owner", sibling)
                .unwrap();
        }
        let current = hub.workflow_runs.store().get(&run.id).unwrap();
        hub.workflow_cancel_activity(&current, "test").await.unwrap();
        let current = hub.workflow_runs.store().get(&run.id).unwrap();
        assert!(
            current.activities[&owned.id].outcome.is_some(),
            "owned internal prompt must be cancelled"
        );
        for id in ["test-lint", "test-prompt-x", "test-task-1", "test-nudge-x"] {
            assert!(current.activities[id].outcome.is_none(), "sibling {id} must survive");
        }
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_schema_corrects_once_and_replay_reuses_both_prompt_outcomes() {
        let (hub, run, child) = activity_chat();
        let options = json!({"harness":"fake","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}});
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(&run, run.generation, &child, "schema-once", &options),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(result, json!({"ok":true}));
        assert_eq!(turns(&hub, &child), 2);
        let saved = hub
            .workflow_runs
            .store()
            .activity(&run.id, run.generation, "owner", &child.id)
            .unwrap()
            .unwrap();
        assert_eq!(
            hub.workflow_execute(&run, run.generation, &saved, "schema-once", &options)
                .await
                .unwrap(),
            result
        );
        assert_eq!(turns(&hub, &child), 2, "replay must not create new turns");
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_route_error_nudges_once_then_restarts_and_validates_new_generation() {
        let (hub, run, child) = activity_chat();
        let options = json!({"harness":"fake","fallbackHarness":"fake-alternate","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}});
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(&run, run.generation, &child, "route-failure-schema", &options),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(result, json!({"ok":true}));
        assert_eq!(turns(&hub, &child), 2, "original route gets one continuation only");
        let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
        let mut restarted = 0;
        hub.store
            .scan_strict(&format!("{session_id}-restart"), 0, &mut |event| {
                if event.kind == "turn_started" {
                    restarted += 1;
                }
                true
            })
            .unwrap();
        assert_eq!(restarted, 1, "alternate route gets one schema-checked attempt");
        let saved = hub
            .workflow_runs
            .store()
            .activity(&run.id, run.generation, "owner", &child.id)
            .unwrap()
            .unwrap();
        assert_eq!(
            hub.workflow_execute(&run, run.generation, &saved, "route-failure-schema", &options)
                .await
                .unwrap(),
            result
        );
        assert_eq!(turns(&hub, &child), 2, "replay must not repeat original effects");
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_explicit_resume_replaces_fenced_wait_on_same_harness() {
        let (hub, run, child) = activity_chat();
        let mut recovery = RecoveryState::new(AttemptKey::new(&child.id));
        recovery.observe(
            &AttemptKey::new(&child.id),
            1,
            RecoveryEvent::Waiting(WaitReason::Capacity),
        );
        let policy = Policy {
            epoch: run.generation,
            observation: 1,
            waiting_for: Some("old-prompt~resume-1".into()),
            recovery: Some(recovery),
            ..Default::default()
        };
        hub.workflow_runs
            .store()
            .update_activity_policy(
                &run.id,
                run.generation,
                "owner",
                &child.id,
                serde_json::to_value(policy).unwrap(),
            )
            .unwrap();
        hub.workflow_pause(&run.id, "owner").await.unwrap();
        let resumed = hub.workflow_runs.store().resume(&run.id, "owner", false).unwrap();
        let saved = hub
            .workflow_runs
            .store()
            .activity(&run.id, resumed.generation, "owner", &child.id)
            .unwrap()
            .unwrap();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(
                &resumed,
                resumed.generation,
                &saved,
                "test",
                &json!({"harness":"fake","fallbackHarness":"fake-alternate"}),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(result, json!("{\"ok\":true}"));
        let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
        assert_eq!(hub.resolve(session_id).unwrap().meta().harness, "fake");
        assert!(
            hub.resolve(&format!("{session_id}-restart")).is_err(),
            "explicit resume must not select the alternate account/harness"
        );
        assert_eq!(turns(&hub, &child), 1);
        cleanup(hub, resumed).await;
    }

    #[tokio::test]
    async fn workflow_restart_reconciles_persisted_automatic_retry_target() {
        let (hub, run, child) = activity_chat();
        let Child::Agent { session_id, prompt_id, .. } = &child.child else { unreachable!() };
        let session = hub
            .new_session_with_id(
                NewRequest {
                    harness: Some("fake".into()),
                    name: Some("Original retry".into()),
                    cwd: Some(run.cwd.clone()),
                    ..Default::default()
                },
                Some(session_id.clone()),
            )
            .await
            .unwrap();
        let retry_id = format!("{prompt_id}-g1-0-0-route-nudge~resume-1");
        let worker_hub = hub.clone();
        let worker_session = session.clone();
        let worker_id = retry_id.clone();
        let mut events = hub.subscribe();
        let worker = tokio::spawn(async move {
            worker_hub
                .prompt_with(
                    &worker_session,
                    vec![json!({"type":"text","text":"until-cancel"})],
                    "workflow",
                    false,
                    PromptOptions { prompt_id: Some(worker_id), ..Default::default() },
                )
                .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                let event = events.recv().await.unwrap();
                if event.session_id == session.id && event.record.kind == "agent_message_chunk" {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let key = AttemptKey::new(&child.id);
        let mut recovery = RecoveryState::new(key.clone());
        assert_eq!(recovery.observe(&key, 1, RecoveryEvent::RouteError), RecoveryAction::Nudge);
        assert!(matches!(
            recovery.observe(&key, 2, RecoveryEvent::Stalled),
            RecoveryAction::Restart { .. }
        ));
        // Simulate a crash after persisting Restart but before cancelling the actual retry.
        let policy = Policy {
            recovery: Some(recovery),
            epoch: run.generation,
            observation: 2,
            restart_prompt_id: Some(retry_id),
            ..Default::default()
        };
        hub.workflow_runs
            .store()
            .update_activity_policy(
                &run.id,
                run.generation,
                "owner",
                &child.id,
                serde_json::to_value(policy).unwrap(),
            )
            .unwrap();
        let saved = hub
            .workflow_runs
            .store()
            .activity(&run.id, run.generation, "owner", &child.id)
            .unwrap()
            .unwrap();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(
                &run,
                run.generation,
                &saved,
                "test",
                &json!({"harness":"fake","fallbackHarness":"fake-alternate"}),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(result, json!("{\"ok\":true}"));
        tokio::time::timeout(std::time::Duration::from_secs(15), worker)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(session.turn().is_none(), "the original retry cannot outlive fallback admission");
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_automatic_retry_stall_nudges_then_restarts_after_running_admission() {
        let (hub, run, child) = activity_chat();
        let result=tokio::time::timeout(std::time::Duration::from_secs(15),hub.workflow_execute(&run,run.generation,&child,"capacity-then-stall",&json!({"harness":"fake","fallbackHarness":"fake-alternate","stallMs":200,"schema":{"type":"object","required":["ok"]}}))).await.unwrap().unwrap();
        assert_eq!(result, json!({"ok":true}));
        let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
        let mut working = None;
        let mut nudges = Vec::new();
        hub.store
            .scan_strict(session_id, 0, &mut |event| {
                match event.msg.pointer("/params/update/content/text").and_then(Value::as_str) {
                    Some("retry working") => working = Some(event.seq),
                    Some("nudge accepted") => nudges.push(event.seq),
                    _ => {}
                }
                true
            })
            .unwrap();
        assert_eq!(nudges.len(), 1, "the running retry gets its one stall nudge");
        assert!(
            working.unwrap() < nudges[0],
            "capacity waiting must not trigger a premature nudge"
        );
        assert_eq!(turns(&hub, &child), 2, "original turn and same-account daemon retry only");
        assert_eq!(
            hub.resolve(&format!("{session_id}-restart")).unwrap().meta().harness,
            "fake-alternate"
        );
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_route_error_without_alternate_fails_after_one_nudge() {
        let (hub, run, child) = activity_chat();
        let error = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(
                &run,
                run.generation,
                &child,
                "route-failure",
                &json!({"harness":"fake"}),
            ),
        )
        .await
        .unwrap()
        .unwrap_err();
        assert!(error.message.contains("no different permitted fallback"));
        assert_eq!(turns(&hub, &child), 2);
        cleanup(hub, run).await;
    }

    #[test]
    fn account_and_permission_waits_never_escalate_to_route_fallback() {
        for (message, data, expected) in [
            (
                "route unavailable HTTP 429",
                json!({"reason":"route.unavailable"}),
                WaitReason::UsageLimit { reset_at_ms: None },
            ),
            (
                "route unavailable HTTP 503",
                json!({"reason":"route.unavailable"}),
                WaitReason::Capacity,
            ),
            ("route unavailable", json!({"reason":"permission.denied"}), WaitReason::Permission),
        ] {
            assert_eq!(
                workflow_error_observation(&RpcError::internal(message).with_data(data)),
                RecoveryEvent::Waiting(expected)
            );
        }
    }

    #[tokio::test]
    async fn workflow_schema_second_mismatch_is_terminal_without_third_prompt() {
        let (hub, run, child) = activity_chat();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(
                &run,
                run.generation,
                &child,
                "schema-twice",
                &json!({"harness":"fake","schema":{"type":"object"}}),
            ),
        )
        .await
        .unwrap();
        assert!(result.unwrap_err().message.contains("after correction"));
        assert_eq!(turns(&hub, &child), 2);
        cleanup(hub, run).await;
    }

    #[tokio::test]
    async fn workflow_pause_resume_preserves_child_and_restarts_only_cancelled_prompt() {
        let (hub, run, child) = activity_chat();
        let mut events = hub.subscribe();
        let worker_hub = hub.clone();
        let worker_run = run.clone();
        let worker_child = child.clone();
        let worker = tokio::spawn(async move {
            worker_hub
                .workflow_execute(
                    &worker_run,
                    worker_run.generation,
                    &worker_child,
                    "until-cancel",
                    &json!({"harness":"fake"}),
                )
                .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                let event = events.recv().await.unwrap();
                if event.record.kind == "agent_message_chunk" {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let paused = hub.workflow_pause(&run.id, "owner").await.unwrap();
        assert_eq!(paused.state, crate::workflow_runs::State::Paused);
        assert!(worker.await.unwrap().is_err(), "paused generation cannot save a late outcome");
        let resumed = hub.workflow_runs.store().resume(&run.id, "owner", false).unwrap();
        let saved = hub
            .workflow_runs
            .store()
            .activity(&run.id, resumed.generation, "owner", &child.id)
            .unwrap()
            .unwrap();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            hub.workflow_execute(
                &resumed,
                resumed.generation,
                &saved,
                "until-cancel",
                &json!({"harness":"fake"}),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(result, json!("{\"ok\":true}"));
        assert_eq!(turns(&hub, &child), 2, "same session, one cancelled and one resumed turn");
        cleanup(hub, resumed).await;
    }

    #[tokio::test]
    async fn workflow_reconciles_persisted_nudge_intent_without_duplicate_effect() {
        let (hub, run, child) = activity_chat();
        let mut events = hub.subscribe();
        let worker_hub = hub.clone();
        let worker_run = run.clone();
        let worker_child = child.clone();
        let worker = tokio::spawn(async move {
            worker_hub
                .workflow_execute(
                    &worker_run,
                    worker_run.generation,
                    &worker_child,
                    "until-cancel",
                    &json!({"harness":"fake"}),
                )
                .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                let event = events.recv().await.unwrap();
                if event.record.kind == "agent_message_chunk" {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let Child::Agent { session_id, .. } = &child.child else { unreachable!() };
        let session = hub.resolve(session_id).unwrap();
        let target = session.turn().unwrap().prompt_id;
        let intent = Nudge {
            id: "activity-nudge".into(),
            session_id: session.id.clone(),
            prompt_id: format!("{target}-nudge"),
            target_prompt_id: target,
        };
        let mut recovery = RecoveryState::new(AttemptKey::new(&child.id));
        recovery.observe(&AttemptKey::new(&child.id), 1, RecoveryEvent::Stalled);
        let policy = Policy {
            nudge: Some(intent.clone()),
            recovery: Some(recovery),
            epoch: run.generation,
            ..Default::default()
        };
        hub.workflow_runs
            .store()
            .update_activity_policy(
                &run.id,
                run.generation,
                "owner",
                &child.id,
                serde_json::to_value(policy).unwrap(),
            )
            .unwrap();
        // Simulate the gap after the durable decision and before its child/effect existed.
        assert!(
            hub.workflow_runs
                .store()
                .activity(&run.id, run.generation, "owner", &intent.id)
                .unwrap()
                .is_none()
        );
        hub.workflow_nudge(&run, run.generation, &intent).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            loop {
                let event = events.recv().await.unwrap();
                if event.record.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                    == Some("nudge accepted")
                {
                    break;
                }
            }
        })
        .await
        .unwrap();
        hub.workflow_nudge(&run, run.generation, &intent).await.unwrap();
        assert!(
            hub.workflow_runs
                .store()
                .activity(&run.id, run.generation, "owner", &intent.id)
                .unwrap()
                .unwrap()
                .outcome
                .is_some()
        );
        let mut nudges = 0;
        hub.store
            .scan_strict(&session.id, 0, &mut |event| {
                if event.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                    == Some("nudge accepted")
                {
                    nudges += 1;
                }
                true
            })
            .unwrap();
        assert_eq!(nudges, 1, "reconciled intent must steer only once");
        hub.workflow_pause(&run.id, "owner").await.unwrap();
        assert!(worker.await.unwrap().is_err());
        cleanup(hub, run).await;
    }

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
