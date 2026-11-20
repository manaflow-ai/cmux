//! An observed failed turn's retry is parked before a recovery worker hands its work off.
//! Unlike Cancel or Stop, this operation never contacts or terminates the harness. The
//! admission and journal locks make checking the revision and fencing the timer one step.

use super::{Hub, Mark, Session};
use crate::protocol::session::ParkRetryResult;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::atomic::Ordering;

fn refused(session: &Session, reason: &str) -> RpcError {
    RpcError::invalid_params(format!("retry park refused: {reason}")).with_data(json!({
        "reason": reason, "sessionId": session.id, "revision": Hub::revision(session)
    }))
}

impl Hub {
    pub(crate) fn park_retry(
        &self,
        session: &Session,
        expect_revision: u64,
    ) -> Result<ParkRetryResult, RpcError> {
        let _turn = session.turn_lock.try_lock().map_err(|_| refused(session, "retry.busy"))?;
        let _harness =
            session.harness_use.try_write().map_err(|_| refused(session, "retry.busy"))?;
        let _spawn = session.spawn_lock.try_lock().map_err(|_| refused(session, "retry.busy"))?;
        let mut pending = session.auto_resume.lock();
        // Queue mutations append while holding their queue lock. Take it before append,
        // without waiting, so their pending write cannot deadlock a conditional park.
        let queue = session.queue.try_lock().map_err(|_| refused(session, "retry.busy"))?;
        let _append = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        self.catch_up_locked(session);
        if session.replaced.load(Ordering::SeqCst)
            || session.restoring.load(Ordering::SeqCst)
            || !session.caught_up.load(Ordering::SeqCst)
        {
            return Err(refused(session, "retry.unavailable"));
        }
        if Self::revision(session) != expect_revision {
            return Err(refused(session, "revision_moved"));
        }
        if session.turn().is_some()
            || session.harness_turn.load(Ordering::SeqCst)
            // Held prompts can retry themselves too (`digest.rs`), independently of
            // auto_resume. A handoff must not overlook that second source of work.
            || !queue.is_empty()
        {
            return Err(refused(session, "retry.busy"));
        }
        let last = session.meta().last_turn.unwrap_or(Value::Null);
        let Some(turn) = last["turnId"].as_str().filter(|_| last["status"] == "failed") else {
            return Err(refused(session, "retry.nothing_failed"));
        };
        match pending.as_ref() {
            Some(Mark::Waiting { turn: cut, retry: Some(_), .. } | Mark::Stopped(cut))
                if cut == turn => {}
            None => {}
            // In particular never steal a retry that has fired, or one still deciding.
            _ => return Err(refused(session, "retry.busy")),
        }
        self.persist_retry_park_boundary_locked(
            session,
            "auto_resume_stopped",
            json!({"turnId": turn, "promptId": last["promptId"], "why": "handoff"}),
        )?;
        // A rate-limit timer also owns the queue: its reset must not release that queue
        // after the continuation is removed. Persist its park before acknowledging either.
        self.park_retry_hold_locked(session)?;
        pending.replace(Mark::Stopped(turn.to_owned()));
        Ok(ParkRetryResult {
            session_id: session.id.clone(),
            revision: Self::revision(session),
            parked: true,
        })
    }

    /// Caller owns `auto_resume` and `append_lock`. Success means the boundary survived
    /// flush and journal readback, not merely that an in-memory append was accepted.
    pub(in crate::hub) fn persist_retry_park_boundary_locked(
        &self,
        session: &Session,
        kind: &str,
        msg: Value,
    ) -> Result<(), RpcError> {
        for _ in 0..2 {
            let (record, stored) =
                self.append_at_locked(session, "mux", kind, msg.clone(), None, None, true, true);
            if !stored {
                return Err(RpcError::internal("cannot persist retry park boundary"));
            }
            self.store.flush_session(&session.id).map_err(|e| {
                RpcError::internal(format!("cannot flush retry park boundary: {e}"))
            })?;
            let mut found = false;
            self.store
                .scan_back(
                    &session.id,
                    0,
                    u64::MAX,
                    &|_, candidate| candidate != kind.as_bytes(),
                    &mut |event| {
                        found = event.seq == record.seq
                            && event.dir == "mux"
                            && event.msg == record.msg;
                        false
                    },
                )
                .map_err(|e| RpcError::internal(format!("cannot read retry park boundary: {e}")))?;
            if found {
                return Ok(());
            }
            // An unterminated previous line may swallow the first append; it now ends
            // that line. As with exact-prompt cancellation, verify one fresh record.
        }
        Err(RpcError::internal("retry park boundary is not readable"))
    }
}
