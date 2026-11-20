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
            "{} is finished. Start a new session with its handoff, or intentionally wake it with acpmux wake {} --reason REASON",
            meta.name, meta.id,
        )).with_data(json!({"reason": "session.finished", "sessionId": meta.id,
            "handoff": finished, "next": "Start a new session seeded with this handoff"})))
    }

    pub(crate) fn finish_session(
        &self,
        session: &Session,
        handoff: &str,
    ) -> Result<Value, RpcError> {
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
        Ok(json!({"sessionId": session.id, "finished": session.meta().finished}))
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
        Ok(json!({"sessionId": session.id, "finished": null, "reason": reason}))
    }
}
