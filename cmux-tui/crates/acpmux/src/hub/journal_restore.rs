//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/journal_restore`: a machine started from an older
//! disk takes back what its owner's daemon kept of a chat past where its own journal ends, so
//! moving a session to a fresh machine loses no turn (cmuxterm-hq plans/cloud
//! ARCHITECTURE-2026-11.md, P4/E4: "the acpmux session is the source of truth, the machine is
//! disposable").
//!
//! The owner's daemon sends it when the chat's row names an older `lastSeq` than its copy of
//! the chat holds (`peer_snapshot/restore.rs`). The records keep their seqs and go in only past
//! where the journal ends, with no turn running, and only when every record the journal holds
//! past `afterSeq` is the restore's own (a row read before the log's tail was counted names an
//! older end): otherwise the journal is another history, answered `diverged` with its own
//! `lastSeq`. Once they are in, the chat's log is read again as after a restart (`log_load.rs`
//! `settle_restored`): a turn the old machine was running when it went away is settled as cut
//! and continued, and a prompt it had queued waits in this queue again, under its own id, so a
//! resend of that id joins it instead of running it twice. The agent resumes its own session
//! from that older disk too, so its next prompt carries the turns after where the journal ended
//! (`SessionMeta::agent_behind_seq`, `transcript.rs` `catch_up`).

use super::*;

/// The most records one restore takes.
pub const MAX_RECORDS: usize = 4096;

impl Hub {
    pub async fn journal_restore(self: &Arc<Self>, params: &Value) -> Result<Value, RpcError> {
        let id = params
            .get("sessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
        let created_at = params
            .get("createdAt")
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::invalid_params("createdAt is required"))?;
        let after = params
            .get("afterSeq")
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::invalid_params("afterSeq is required"))?;
        let raw = params
            .get("records")
            .and_then(Value::as_array)
            .ok_or_else(|| RpcError::invalid_params("records is required"))?;
        if raw.len() > MAX_RECORDS {
            return Err(RpcError::invalid_params(format!(
                "at most {MAX_RECORDS} records restore at once"
            )));
        }
        let mut records = Vec::with_capacity(raw.len());
        let mut last = after;
        for r in raw {
            let record: EventRecord = serde_json::from_value(r.clone())
                .map_err(|e| RpcError::invalid_params(format!("record: {e}")))?;
            if record.seq <= last {
                return Err(RpcError::invalid_params("records must follow afterSeq in seq order"));
            }
            last = record.seq;
            records.push(record);
        }
        self.session_meta(id).await;
        let session = self
            .resolve(id)
            .ok()
            .filter(|s| s.id == id)
            .ok_or_else(|| RpcError::invalid_params(format!("no session {id}")))?;
        if session.meta().created_at != created_at {
            return Err(refused("generation", "another generation of this session", &session));
        }
        let hub = self.clone();
        tokio::task::spawn_blocking(move || hub.restore_records(&session, after, records))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
    }

    fn restore_records(
        self: &Arc<Self>,
        session: &Arc<Session>,
        after: u64,
        records: Vec<EventRecord>,
    ) -> Result<Value, RpcError> {
        // Under the log's load lock: a first read of the log comes before (and is read again
        // below) or after (and reads the restored records itself).
        let loaded = session.log_load.lock().unwrap_or_else(|e| e.into_inner());
        if session.turn().is_some() || session.queued() > 0 {
            return Err(refused("busy", "a turn runs or waits here", session));
        }
        let restored = {
            let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
            self.catch_up_locked(session);
            let at = session.seq.load(Ordering::SeqCst);
            if at < after {
                return Err(refused("diverged", "this journal ends before afterSeq", session));
            }
            // A row read before the log's tail was counted can name an older end: the records
            // between are the same history only when each one the restore holds is the
            // journal's own (its time and kind).
            let mut held = HashMap::new();
            if at > after {
                let past = self
                    .store
                    .events(&session.id, after, usize::try_from(at - after).unwrap_or(usize::MAX))
                    .map_err(|e| RpcError::internal(e.to_string()))?;
                held.extend(past.into_iter().map(|e| (e.seq, (e.at, e.kind))));
            }
            for record in records.iter().filter(|r| r.seq <= at) {
                if held.get(&record.seq).is_some_and(|(t, k)| (*t, k) != (record.at, &record.kind))
                {
                    return Err(refused("diverged", "this journal holds another history", session));
                }
            }
            let mut last = at;
            for record in records.iter().filter(|r| r.seq > at) {
                if let Err(e) = self.store.append(&session.id, record) {
                    tracing::warn!(session = %session.id, "journal restore append failed: {e}");
                    break;
                }
                last = record.seq;
            }
            session.seq.store(last, Ordering::SeqCst);
            {
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                meta.last_seq = last;
                // The restored log may end in transcript records.
                meta.transcript_seq = last;
                // The agent's own session came from the same disk as this journal: it ends where
                // the journal did, and its next prompt carries the turns after (`transcript.rs`).
                if last > at {
                    meta.agent_behind_seq = Some(meta.agent_behind_seq.map_or(at, |s| s.min(at)));
                }
            }
            last > at
        };
        let _ = self.store.flush_session(&session.id);
        self.save_meta(session);
        if *loaded && restored {
            self.settle_restored(session);
        }
        drop(loaded);
        let last = session.seq.load(Ordering::SeqCst);
        tracing::info!(session = %session.id, after, last, "journal restored from the owner's copy");
        self.update_live_session_index(session);
        Ok(json!({"sessionId": session.id, "lastSeq": last, "restored": restored}))
    }
}

fn refused(reason: &str, why: &str, session: &Session) -> RpcError {
    let last = session.seq.load(Ordering::SeqCst);
    RpcError::invalid_params(format!("journal restore refused: {why}"))
        .with_data(json!({"reason": reason, "lastSeq": last}))
}
