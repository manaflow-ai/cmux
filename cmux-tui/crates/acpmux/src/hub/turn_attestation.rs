//! Read the existing turn and journal; no new session state or turn counter.
use super::*;
use crate::turn_attestation::{TurnAttestation, refused};
use cmux_server::pairing::EnrolledIdentity;

impl Hub {
    pub(crate) fn issue_turn_attestation(
        &self,
        id: &str,
        identity: &EnrolledIdentity,
        ttl: u64,
    ) -> Result<Value, RpcError> {
        let session = self.resolve(id)?;
        // Exact identity only, never a name/prefix which might resolve to another chat.
        if session.id != id {
            return Err(refused("turn_attestation.caller_mismatch"));
        }
        // Keep the journal stable while validating it. Lifecycle paths such as detach
        // also mutate the live turn without this lock, so admission rechecks that state.
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        let (seq, turn_id) = session
            .turn
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|t| (t.turn_seq, t.turn_id.clone()))
            .filter(|(seq, _)| *seq > 0)
            .ok_or_else(|| refused("turn_attestation.not_live"))?;
        if session.purged.load(Ordering::SeqCst)
            || session.replaced.load(Ordering::SeqCst)
            || session.closing.load(Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
            || !self.session_log_loaded(&session)
        {
            return Err(refused("turn_attestation.not_live"));
        }
        let mut started = false;
        let mut ended = false;
        self.store
            .scan_strict(id, seq.saturating_sub(1), &mut |r| {
                if r.dir == "mux" {
                    let same_turn = r.msg.get("turnId").and_then(Value::as_str) == Some(&turn_id);
                    if r.seq == seq && r.kind == "turn_started" && same_turn {
                        started = true;
                    }
                    if (r.seq > seq && r.kind == "turn_started")
                        || (matches!(r.kind.as_str(), "turn_end" | "turn_result" | "turn_error")
                            && (same_turn
                                || r.msg.get("turnSeq").and_then(Value::as_u64) == Some(seq)))
                        || matches!(r.kind.as_str(), "stopped" | "exited")
                    {
                        ended = true;
                    }
                }
                true
            })
            .map_err(|_| refused("turn_attestation.journal_unavailable"))?;
        if !started || ended {
            return Err(refused("turn_attestation.not_live"));
        }
        #[cfg(test)]
        tests::before_admission();
        // Every clear/replacement of the live turn holds this mutex, including kill,
        // detach and startup. Revalidate after journal I/O and retain the guard through
        // signing and encoding; the admitted turn cannot be cleared or replaced meanwhile.
        // Lock order remains append_lock -> turn, never append_lock -> auto_resume.
        let live = session.turn.lock().unwrap_or_else(|e| e.into_inner());
        if !live.as_ref().is_some_and(|turn| turn.turn_seq == seq && turn.turn_id == turn_id)
            || session.purged.load(Ordering::SeqCst)
            || session.replaced.load(Ordering::SeqCst)
            || session.closing.load(Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
            || !self.session_log_loaded(&session)
        {
            return Err(refused("turn_attestation.not_live"));
        }
        #[cfg(test)]
        tests::after_live_check();
        let proof = TurnAttestation::issue(identity, id, seq, now_ms(), ttl)?;
        let encoded = serde_json::to_value(proof).map_err(|_| refused("turn_attestation.encoding"));
        drop(live);
        encoded
    }
}

#[cfg(test)]
#[path = "turn_attestation_tests.rs"]
mod tests;
