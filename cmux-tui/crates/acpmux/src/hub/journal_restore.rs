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
//! resend of that id joins it instead of running it twice.

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
            let mut failed = None;
            for record in records.iter().filter(|r| r.seq > at) {
                let appended = if test_fails_here(&session.id, last > at) {
                    Err(anyhow::anyhow!("test: the append fails here"))
                } else {
                    self.store.append(&session.id, record)
                };
                if let Err(e) = appended {
                    failed = Some(e);
                    break;
                }
                last = record.seq;
                // What an append of it here would have counted (`append_record_locked`, the
                // turn's start and end in `turns.rs`).
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                count_restored(&mut meta, record);
            }
            session.seq.store(last, Ordering::SeqCst);
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_seq = last;
            (last > at, failed)
        };
        let (restored, failed) = restored;
        // What went in is kept (a retry goes on after it), on disk before the answer.
        let flushed = self.store.flush_session(&session.id);
        self.save_meta(session);
        // Only every record in, on disk, is a restore: until then nothing settles the log and the
        // owner keeps its copy and delivers nothing again (`peer_snapshot/restore.rs`).
        if let Some(e) = failed.or(flushed.err()) {
            drop(loaded);
            tracing::warn!(session = %session.id, "journal restore stopped: {e:#}");
            let last = session.seq.load(Ordering::SeqCst);
            return Err(RpcError::internal(format!("journal restore stopped: {e:#}"))
                .with_data(json!({"reason": "append_failed", "lastSeq": last})));
        }
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

/// What a record put back changes in its chat's meta, as when it was first appended: the counts,
/// the transcript mark, the harness failures, the turns and the last turn's outcome.
fn count_restored(meta: &mut SessionMeta, record: &EventRecord) {
    meta.event_count += 1;
    meta.updated_at = meta.updated_at.max(record.at);
    if paging::is_transcript(record) {
        meta.transcript_seq = record.seq;
    }
    if record.dir != "mux" {
        return;
    }
    match record.kind.as_str() {
        "turn_started" => meta.turn_count += 1,
        "turn_result" => {
            meta.harness_failures.observe(&record.msg, record.seq, record.at);
            if record.msg.get("trigger") != Some(&Value::Bool(true)) {
                meta.last_turn = Some(super::turns::last_turn_of(&record.msg, record.at));
            }
        }
        _ => {}
    }
}

fn refused(reason: &str, why: &str, session: &Session) -> RpcError {
    let last = session.seq.load(Ordering::SeqCst);
    RpcError::invalid_params(format!("journal restore refused: {why}"))
        .with_data(json!({"reason": reason, "lastSeq": last}))
}

/// Debug builds only: the restore of chat `id` fails once, after its first record (a disk that
/// fills midway), so a test sees a partial restore answered as one and finished by a retry.
#[cfg(debug_assertions)]
static FAIL_ONCE: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn fail_once_after_first_record(id: &str) {
    *FAIL_ONCE.lock().unwrap_or_else(|e| e.into_inner()) = Some(id.to_owned());
}

/// Whether the failure [`fail_once_after_first_record`] armed has not happened yet.
#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn fail_once_armed() -> bool {
    FAIL_ONCE.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

#[cfg(debug_assertions)]
fn test_fails_here(id: &str, past_first: bool) -> bool {
    let mut armed = FAIL_ONCE.lock().unwrap_or_else(|e| e.into_inner());
    let fails = past_first && armed.as_deref() == Some(id);
    if fails {
        *armed = None;
    }
    fails
}

#[cfg(not(debug_assertions))]
fn test_fails_here(_: &str, _: bool) -> bool {
    false
}
