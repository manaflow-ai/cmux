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
//!
//! Design (third review of #37284): a restore is one exclusive operation on its chat.
//! - Locks, in this order: `turn_lock` (async, as a turn takes it; at most [`TURN_LOCK_WITHIN`],
//!   else `busy`), then `admit` (only to check and set `restoring`), then `log_load`, then
//!   `append_lock` (the check, the writes and the read-back). Nothing takes them the other way.
//! - States of the chat: idle; `restoring` (set under `admit` with no turn, claim or reservation;
//!   every new prompt waits for `restore_done`, nothing it would log goes in); settled.
//! - Writes: only past where the journal ends, each record with its own seq. After the writes
//!   (or an error) the journal's end and the meta's counts are read back from the log on disk,
//!   never counted in memory, so a line written before an error is kept once and a retry goes
//!   on after it with no seq twice. Short of the last record it answers `append_failed`.
//! - Released: `restoring` and `restore_done` when the restore returns (any outcome), the turn
//!   lock after the settle; what the settle starts (the cut turn's continuation) waits for it.

use super::*;
use std::time::Duration;

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
        // (1) The turn lock, as a turn takes it: no turn starts until the restore settled.
        let Ok(_turn) = tokio::time::timeout(TURN_LOCK_WITHIN, session.turn_lock.lock()).await
        else {
            return Err(refused("busy", "a turn holds this chat", &session));
        };
        // (2) Under `admit`, as a prompt is admitted: idle, nothing reserved, and from now on
        // every prompt waits for `restore_done` (`queue.rs` `queue_slot`).
        {
            let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
            if session.turn().is_some() || session.queued() > 0 || session.turn_claimed() {
                return Err(refused("busy", "a turn runs or waits here", &session));
            }
            session.restoring.store(true, Ordering::SeqCst);
        }
        struct Restoring<'a>(&'a Session);
        impl Drop for Restoring<'_> {
            fn drop(&mut self) {
                self.0.restoring.store(false, Ordering::SeqCst);
                self.0.restore_done.notify_waiters();
            }
        }
        let _restoring = Restoring(&session);
        #[cfg(debug_assertions)]
        test_pause(&session.id).await;
        // (3) The write and the settle, off the executor, with both held.
        let hub = self.clone();
        let held = session.clone();
        blocking(move || hub.restore_records(&held, after, records))
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
        let (at, failed) = {
            let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
            self.catch_up_locked(session);
            let at = session.seq.load(Ordering::SeqCst);
            if at < after {
                return Err(refused("diverged", "this journal ends before afterSeq", session));
            }
            // What the journal holds past `afterSeq` (a row read before its tail was counted, or
            // an earlier try that stopped midway) must be the restore's own records, by time and
            // kind: else it is another history.
            if at > after {
                let past = self
                    .store
                    .events(&session.id, after, usize::try_from(at - after).unwrap_or(usize::MAX))
                    .map_err(|e| RpcError::internal(e.to_string()))?;
                let held: HashMap<u64, (u64, String)> =
                    past.into_iter().map(|e| (e.seq, (e.at, e.kind))).collect();
                for record in records.iter().filter(|r| r.seq <= at) {
                    if held
                        .get(&record.seq)
                        .is_some_and(|(t, k)| (*t, k) != (record.at, &record.kind))
                    {
                        return Err(refused(
                            "diverged",
                            "this journal holds another history",
                            session,
                        ));
                    }
                }
            }
            let mut failed = None;
            for (n, record) in records.iter().filter(|r| r.seq > at).enumerate() {
                let appended = if test_fails_here(&session.id, n > 0) {
                    // As a real append can: the line is written, then the call fails.
                    self.store.append(&session.id, record).and_then(|()| {
                        Err(anyhow::anyhow!("test: the append fails after its line"))
                    })
                } else {
                    self.store.append(&session.id, record)
                };
                if let Err(e) = appended {
                    failed = Some(e);
                    break;
                }
            }
            let flushed = self.store.flush_session(&session.id);
            // (4) Where the journal ends is read back from it, never counted here: an append can
            // fail after its line is written, and the next try must go on after that line.
            let durable = self.store.events(&session.id, at, usize::MAX);
            let durable = match durable {
                Ok(durable) => durable,
                Err(e) => return Err(stopped(session, &e)),
            };
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            for record in &durable {
                count_restored(&mut meta, record);
            }
            let last = durable.iter().map(|r| r.seq).max().unwrap_or(at);
            meta.last_seq = last;
            drop(meta);
            session.seq.store(last, Ordering::SeqCst);
            (at, failed.or(flushed.err()))
        };
        self.save_meta(session);
        let last = session.seq.load(Ordering::SeqCst);
        let through = records.last().map_or(after, |r| r.seq);
        // Only every record in, on disk, is a restore: until then nothing settles the log, and
        // the owner keeps its copy and delivers nothing again (`peer_snapshot/restore.rs`).
        if let Some(e) = failed.filter(|_| last < through).or_else(|| {
            (last < through).then(|| anyhow::anyhow!("the journal ends at {last}, not {through}"))
        }) {
            drop(loaded);
            return Err(stopped(session, &e));
        }
        // (5) Settled as after a restart, still holding the turn lock: the cut turn is marked and
        // continued, the queue rebuilt; what they start waits for the lock.
        let restored = last > at;
        if *loaded && restored {
            self.settle_restored(session);
        }
        drop(loaded);
        tracing::info!(session = %session.id, after, last, "journal restored from the owner's copy");
        self.update_live_session_index(session);
        Ok(json!({"sessionId": session.id, "lastSeq": last, "restored": restored}))
    }
}

/// How long a restore waits for a turn to give back the chat before it answers `busy`.
const TURN_LOCK_WITHIN: Duration = Duration::from_secs(5);

fn stopped(session: &Session, e: &anyhow::Error) -> RpcError {
    tracing::warn!(session = %session.id, "journal restore stopped: {e:#}");
    let last = session.seq.load(Ordering::SeqCst);
    RpcError::internal(format!("journal restore stopped: {e:#}"))
        .with_data(json!({"reason": "append_failed", "lastSeq": last}))
}

/// Runs the restore's blocking work without holding up the runtime's other tasks (the daemon's
/// is multi-thread); a current-thread runtime (a one-shot test) runs it in place.
fn blocking<T>(f: impl FnOnce() -> T) -> T {
    let multi = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    if multi { tokio::task::block_in_place(f) } else { f() }
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

/// Debug builds only: the restore of chat `id` waits `ms` once it holds the chat, so a test can
/// send a prompt in that window ([`test_paused`] says when it is in it).
#[cfg(debug_assertions)]
static PAUSE: std::sync::Mutex<Option<(String, u64, bool)>> = std::sync::Mutex::new(None);

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn pause_once_holding(id: &str, ms: u64) {
    *PAUSE.lock().unwrap_or_else(|e| e.into_inner()) = Some((id.to_owned(), ms, false));
}

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn test_paused() -> bool {
    PAUSE.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|p| p.2)
}

#[cfg(debug_assertions)]
async fn test_pause(id: &str) {
    let ms = {
        let mut pause = PAUSE.lock().unwrap_or_else(|e| e.into_inner());
        match pause.as_mut() {
            Some(p) if p.0 == id && !p.2 => {
                p.2 = true;
                p.1
            }
            _ => return,
        }
    };
    tokio::time::sleep(Duration::from_millis(ms)).await;
    *PAUSE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}
