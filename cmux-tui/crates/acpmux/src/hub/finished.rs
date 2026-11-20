//! Finishing is durable intent, independent of a harness being idle or closed. Only the
//! explicit wake operation clears it; opening, sending, retries and daemon adoption do not.
use super::*;

pub(crate) const METHOD: &str = "_acpmux/session_lifecycle";

impl Hub {
    pub(crate) fn set_fleet_pause(&self, paused: bool, reason: &str) -> Result<Value, RpcError> {
        if reason.trim().is_empty() {
            return Err(RpcError::invalid_params("a reason is required"));
        }
        self.resume_admission.pause(paused.then_some(reason))?;
        Ok(json!({"paused": paused, "reason": reason}))
    }

    pub(crate) fn check_finished(&self, session: &Session) -> Result<(), RpcError> {
        let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let Some(finished) = &meta.finished else { return Ok(()) };
        Err(RpcError::invalid_params(format!(
            "{} is finished. Start afresh with acpmux fresh {} --name NEW, or intentionally reopen it with acpmux wake {} --reason REASON",
            meta.name, meta.id, meta.id,
        )).with_data(json!({"reason": "session.finished", "sessionId": meta.id,
            "handoff": finished, "next": format!("acpmux fresh {} --name NEW", meta.id)})))
    }

    pub(crate) fn finish_session(
        &self,
        session: &Session,
        handoff: &str,
    ) -> Result<Value, RpcError> {
        if handoff.trim().is_empty() {
            return Err(RpcError::invalid_params("finish requires a handoff"));
        }
        // start_turn takes this same lock before it installs a turn. A finish observed before
        // admission fences that turn, including a retry whose timer has already fired.
        session.auto_resume.synchronized(|| {
            {
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                if meta.finished.is_none() {
                    meta.finished = Some(json!({"at": now_ms(), "handoff": handoff}));
                }
            }
            self.save_meta_answered(session)
        })?;
        self.append(session, "mux", "session_finished", json!({"handoff": handoff}));
        self.events.row_changed(session);
        Ok(json!({"sessionId": session.id, "finished": session.meta().finished}))
    }

    /// Let the current turn answer its finish request, then retire the harness. A racing
    /// intentional wake cancels retirement; no new turn can enter while finished.
    pub(crate) fn retire_finished(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> tokio::task::JoinHandle<()> {
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_named("retire-finished", async move {
            let _turn = session.turn_lock.lock().await;
            let _using = session.harness_use.write().await;
            let _spawning = session.spawn_lock.lock().await;
            if hub.check_finished(&session).is_err() {
                hub.detach_child(&session).await;
            }
        })
    }

    pub(crate) async fn fresh_from_finished(
        self: &Arc<Self>,
        source: &Session,
        name: &str,
        starter: Option<String>,
    ) -> Result<Value, RpcError> {
        let meta = source.meta();
        let handoff =
            meta.finished.as_ref().and_then(|f| f["handoff"].as_str()).ok_or_else(|| {
                RpcError::invalid_params("only a finished session has a completion handoff")
            })?;
        let default_policy = self.config.read().await.permission_policy;
        let policy = self.policy_for(source, default_policy);
        let session = self
            .new_session(NewRequest {
                name: Some(name.to_owned()),
                harness: Some(meta.harness.clone()),
                cwd: Some(meta.cwd.clone()),
                policy: Some(policy),
                keep_harness_mode: true,
                starter,
                ..Default::default()
            })
            .await?;
        self.set_composer_draft(&session, handoff)?;
        Ok(json!({"sessionId": session.id, "name": session.meta().name,
            "from": source.id, "draft": handoff}))
    }

    pub(crate) fn wake_finished(&self, session: &Session, reason: &str) -> Result<Value, RpcError> {
        let reason = reason.trim();
        if reason.is_empty() {
            return Err(RpcError::invalid_params("wake requires a non-empty reason"));
        }
        session.auto_resume.synchronized(|| {
            let previous = session.meta.lock().unwrap_or_else(|e| e.into_inner()).finished.take();
            if let Err(error) = self.save_meta_answered(session) {
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).finished = previous;
                return Err(error);
            }
            Ok(())
        })?;
        self.append(session, "mux", "session_woken", json!({"reason": reason}));
        self.events.row_changed(session);
        Ok(json!({"sessionId": session.id, "finished": null, "reason": reason}))
    }
}
