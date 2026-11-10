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
//! Design (sixth and seventh reviews of #37284): a restore is one exclusive operation on its
//! chat, from the owner's first try until every record it holds is in and flushed, or the
//! owner gave up.
//! - Locks, in this order: `close_lock` (as a stop or purge takes it; refused `generation` when
//!   the chat was purged, replaced under its id, or has another `createdAt`), `turn_lock` (at
//!   most [`TURN_LOCK_WITHIN`], else `busy`), `admit` (check and set `restoring`; `restore_lease`
//!   inside it), `log_load`, `append_lock`. Nothing takes them the other way.
//! - States: idle (prompts may wait in the queue); `restoring` (no turn or claim; every new
//!   prompt, and every one that already waited in the queue, waits for `restore_done`); held (a
//!   try stopped short: still `restoring`, for the owner's next try, at most [`RESTORE_HOLD`],
//!   then the hold lapses, logged at warn); settled.
//! - Writes: only past where the journal ends. Afterwards the journal's end and the meta's
//!   counts are read back from disk, never counted in memory, so a retry writes no seq twice.
//!   Short of the last record, or any flush error, answers `append_failed`: the owner keeps its
//!   copy and tries again. The try that finishes settles the log as a restart's load does: the
//!   queue is rebuilt whole from the log, never merged; the restored prompts go first, then the
//!   machine's own that still wait (each keeps its task and handles, and takes the log's
//!   content and state); one the restored records settled is withdrawn. A chat whose log a
//!   deferred start has not read yet is read first, so the gate opens only after the settle;
//!   read so, its recovery writes nothing until the records are in, and runs on the restored
//!   log (or on the log as it is, refused or at the hold's lapse).
//! - On the owner (`peer_snapshot/restore.rs`): every step of a restore, each try and each change
//!   to its copy, goes only on the link and of the generation it started on; a copy that holds
//!   records past the machine's end stays, across a gap too, and goes back.
//! - A message the machine took stays open on the owner (`open_delivery.rs`): "accepted" and
//!   "duplicate" are no proof. Its session is pinned before its first attempt and kept for every
//!   later one. Once the owner's copy wrote records of its prompt's life to disk (only what that
//!   write held), the delivery keeps them itself, past the copy's bounds, a captures' queue that
//!   overflowed and the disk's eviction; it is never sent again, and a restore gives them back
//!   with the copy, unless the copy did not see the prompt's whole life since its first record
//!   and giving them back would start its work again. A later link whose journal holds them
//!   (read by seq, time and kind), of the same generation, releases it; another history there
//!   fails it, saying so, as a lapse does. A link's
//!   redelivery reaches every open delivery of the peer, in batches, on that link.
//!   Checked by the seeded move simulation (`peer_snapshot/move_sim_tests.rs`).

use super::*;
use std::time::Duration;

/// The most records one restore takes.
pub const MAX_RECORDS: usize = 4096;

/// Tests only: the rules of an earlier head, which a review of #37284 found losing prompts or
/// history, for the tests and the move simulation to replay (0: the rules of now). Each later
/// head's fixes are missing from an earlier one too. b7496c3f's: the twenty-third review's F1
/// and F2.
pub(crate) const AT_B749: u8 = 1;
/// fd33a65b's (the twenty-second review's F1 and F2 are missing too).
pub(crate) const AT_FD33: u8 = 2;
/// 4bce04df's (the twenty-first review's F1 and F2 are missing too).
pub(crate) const AT_4BCE: u8 = 3;
/// c4a1c13b's (the twentieth review's F1 is missing too).
pub(crate) const AT_C4A1: u8 = 4;
/// 8b5f3063's (the nineteenth review's F1 to F3 are missing too).
pub(crate) const AT_8B5F: u8 = 5;
/// 77f91e5a's (the eighteenth review's F1 is missing too).
pub(crate) const AT_77F9: u8 = 6;
/// a088585e's (the sixteenth review's F1 to F3 are missing too).
pub(crate) const AT_A088: u8 = 7;
/// 07f76930's (the fourteenth review's F1 and F2 are missing too).
pub(crate) const AT_07F7: u8 = 8;
/// ff3da306's (the twelfth review's F1 and F2 are missing too).
pub(crate) const AT_FF3D: u8 = 9;
/// c4a6f4e7's (the eleventh review's F1 to F3 are missing too).
pub(crate) const AT_C4A6: u8 = 10;
/// 4dcbe192's (the tenth review's F1 to F6 are missing too).
pub(crate) const AT_4DCB: u8 = 11;
/// 91b1343d's (the ninth review's F1 to F5 are missing too).
pub(crate) const AT_91B: u8 = 12;

#[cfg(test)]
thread_local! {
    /// Tests only: the rules this thread replays ([`AT_A088`] and earlier; 0: now).
    pub(crate) static OLD_RULES: std::cell::Cell<u8> = const { std::cell::Cell::new(0) };
}

impl Hub {
    /// The rules this hub replays (tests only; 0 in a build).
    fn old_rules(&self) -> u8 {
        #[cfg(test)]
        {
            self.old_rules.load(Ordering::SeqCst)
        }
        #[cfg(not(test))]
        {
            0
        }
    }

    /// Whether this hub replays the rules of 91b1343d (tests only; never in a build).
    pub(super) fn at_91b(&self) -> bool {
        self.old_rules() >= AT_91B
    }

    /// Whether this hub replays the rules of 4dcbe192 (tests only; never in a build).
    pub(super) fn at_4dcb(&self) -> bool {
        self.old_rules() >= AT_4DCB
    }

    /// Tests only: this hub replays the rules `rules` of an earlier head (0: now).
    #[cfg(test)]
    pub(crate) fn replay_rules(&self, rules: u8) {
        self.old_rules.store(rules, Ordering::SeqCst);
    }

    /// Whether this hub replays the rules of b7496c3f (tests only; never in a build).
    pub(crate) fn at_b749(&self) -> bool {
        self.old_rules() >= AT_B749
    }

    /// Whether this hub replays the rules of fd33a65b (tests only; never in a build).
    pub(crate) fn at_fd33(&self) -> bool {
        self.old_rules() >= AT_FD33
    }

    /// Whether this hub replays the rules of 4bce04df (tests only; never in a build).
    pub(crate) fn at_4bce(&self) -> bool {
        self.old_rules() >= AT_4BCE
    }

    /// Whether this hub replays the rules of 8b5f3063 (tests only; never in a build).
    pub(crate) fn at_8b5f(&self) -> bool {
        self.old_rules() >= AT_8B5F
    }

    /// Whether this hub replays the rules of 77f91e5a (tests only; never in a build).
    pub(crate) fn at_77f9(&self) -> bool {
        self.old_rules() >= AT_77F9
    }

    /// Whether this hub replays the rules of a088585e (tests only; never in a build).
    pub(crate) fn at_a088(&self) -> bool {
        self.old_rules() >= AT_A088
    }

    /// Whether this hub replays the rules of 07f76930 (tests only; never in a build).
    pub(crate) fn at_07f7(&self) -> bool {
        self.old_rules() >= AT_07F7
    }

    /// Whether this hub replays the rules of ff3da306 (tests only; never in a build).
    pub(crate) fn at_ff3d(&self) -> bool {
        self.old_rules() >= AT_FF3D
    }

    /// Whether this hub replays the rules of c4a6f4e7 (tests only; never in a build).
    pub(crate) fn at_c4a6(&self) -> bool {
        self.old_rules() >= AT_C4A6
    }

    /// Whether a journal restore holds `session` (its try, or the hold between tries): no turn
    /// starts and nothing but the restore writes its journal.
    pub(super) fn restore_holds(&self, session: &Session) -> bool {
        session.restoring.load(Ordering::SeqCst) && !self.at_91b()
    }
}

fn thread_rules() -> u8 {
    #[cfg(test)]
    {
        OLD_RULES.with(std::cell::Cell::get)
    }
    #[cfg(not(test))]
    {
        0
    }
}

/// Whether this thread replays the rules of 91b1343d (tests only; never in a build): the
/// copies' store and the restore's merge, which tests drive on their own thread.
pub(crate) fn rules_of_91b() -> bool {
    thread_rules() >= AT_91B
}

/// Whether this thread replays the rules of b7496c3f (tests only; never in a build): the
/// store's cut of a journal (`store/compact.rs`), which runs on the restore's thread.
pub(crate) fn rules_of_b749() -> bool {
    thread_rules() >= AT_B749
}

/// Whether this thread replays the rules of fd33a65b (tests only; never in a build).
pub(crate) fn rules_of_fd33() -> bool {
    thread_rules() >= AT_FD33
}

/// Whether this thread replays the rules of 4bce04df (tests only; never in a build).
pub(crate) fn rules_of_4bce() -> bool {
    thread_rules() >= AT_4BCE
}

/// Whether this thread replays the rules of c4a1c13b (tests only; never in a build).
pub(crate) fn rules_of_c4a1() -> bool {
    thread_rules() >= AT_C4A1
}

/// Whether this thread replays the rules of 8b5f3063 (tests only; never in a build).
pub(crate) fn rules_of_8b5f() -> bool {
    thread_rules() >= AT_8B5F
}

/// Whether this thread replays the rules of 77f91e5a (tests only; never in a build).
pub(crate) fn rules_of_77f9() -> bool {
    thread_rules() >= AT_77F9
}

/// Whether this thread replays the rules of a088585e (tests only; never in a build).
pub(crate) fn rules_of_a088() -> bool {
    thread_rules() >= AT_A088
}

/// Whether this thread replays the rules of 07f76930 (tests only; never in a build).
pub(crate) fn rules_of_07f7() -> bool {
    thread_rules() >= AT_07F7
}

/// Whether this thread replays the rules of 4dcbe192 (tests only; never in a build).
pub(crate) fn rules_of_4dcb() -> bool {
    thread_rules() >= AT_4DCB
}

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
        // (1) The close lock, as a stop or a purge takes it: none runs during the restore, and
        // this is still the chat the owner names (not purged, not replaced under its id, the
        // same generation), so no record goes into a purged chat's folder or a new one's.
        let _closing = session.close_lock.lock().await;
        if session.purged.load(Ordering::SeqCst)
            || !self.is_current_session(&session)
            || session.meta().created_at != created_at
        {
            return Err(refused("generation", "another generation of this session", &session));
        }
        // (2) The turn lock, as a turn takes it: no turn starts until the restore settled.
        let Ok(_turn) = tokio::time::timeout(TURN_LOCK_WITHIN, session.turn_lock.lock()).await
        else {
            return Err(refused("busy", "a turn holds this chat", &session));
        };
        // (3) Under `admit`, as a prompt is admitted: idle, nothing reserved, and from now on
        // every prompt waits for `restore_done` (`queue.rs` `queue_slot`). A hold an earlier
        // try left (it stopped short) is this restore's own: the owner alone restores.
        let resumed = {
            let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
            let held = session.restore_lease.lock().unwrap_or_else(|e| e.into_inner()).take();
            // Prompts may wait in its queue (a machine back on a disk that held one): the log
            // rebuilds the queue whole once the records are in (`log_load.rs`
            // `settle_restored`). A running or claimed turn refuses it.
            if session.turn().is_some() || session.turn_claimed() {
                if held.is_some() {
                    // Never so while held (every prompt waits); kept as it was, to be safe.
                    *session.restore_lease.lock().unwrap_or_else(|e| e.into_inner()) = held;
                }
                return Err(refused("busy", "a turn runs here", &session));
            }
            session.restoring.store(true, Ordering::SeqCst);
            held.is_some()
        };
        // From here every record but this try's own parks until the restore ends
        // (`restore_writer.rs`).
        static TRIES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        self.park_writes(&session, TRIES.fetch_add(1, Ordering::SeqCst) + 1);
        let mut restoring = Restoring { hub: self.clone(), session: session.clone(), hold: false };
        #[cfg(debug_assertions)]
        test_pause(&session.id).await;
        // (4) The write and the settle, off the executor, with all three held.
        let hub = self.clone();
        let held = session.clone();
        let files = files_of(params)?;
        let old = self.at_ff3d();
        let result = blocking(move || {
            // ff3da306 wrote the files before it decided (review of #37284 at ff3da306, F2).
            if old {
                restore_files(&held, &files, true)?;
            }
            hub.restore_records(&held, after, records, resumed, &files)
        });
        // (5) Stopped short: the chat stays held for the owner's next try, at most
        // [`RESTORE_HOLD`], so no prompt takes the seqs the rest of the records need.
        if result.as_ref().is_err_and(|e| reason_of(e) == Some("append_failed")) {
            restoring.hold = true;
            hold_for_next_try(self, &session);
        }
        result
    }

    fn is_current_session(&self, session: &Arc<Session>) -> bool {
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        sessions.get(&session.id).is_some_and(|current| Arc::ptr_eq(current, session))
    }

    fn restore_records(
        self: &Arc<Self>,
        session: &Arc<Session>,
        after: u64,
        records: Vec<EventRecord>,
        resumed: bool,
        files: &[(std::path::PathBuf, Vec<u8>)],
    ) -> Result<Value, RpcError> {
        // The chat's log is read first, now, when a deferred start has not read it yet (review
        // of #37284 at 98b4575a, F3): the restore settles the log it writes into, and only then
        // lets a prompt in. A log that still does not read refuses it, writing nothing. Read so,
        // its recovery writes nothing before the records go in (at 91b1343d, F4): it runs on the
        // restored log, or on the log as it is when the restore is refused. A try that stopped
        // short leaves it to the next try, or to its hold's lapse.
        // This thread alone writes the chat's journal while the restore owns it.
        let _writer = super::restore_writer::RestoreWriter::hold(session);
        self.load_session_log_for_restore(session);
        let loaded = session.log_load.lock().unwrap_or_else(|e| e.into_inner());
        if !*loaded {
            return Err(refused("busy", "this chat's log is not read yet", session));
        }
        let result = self.write_restored(session, after, &records, resumed, files);
        if result.as_ref().is_err_and(|e| reason_of(e) != Some("append_failed")) {
            self.recover_pending(session, None);
        }
        drop(loaded);
        result
    }

    /// The restore's write and settle; the caller holds `log_load`. Nothing on disk changes
    /// until every check has passed (review of #37284 at ff3da306, F2): the recovery it takes
    /// back, the files its prompts were saved as and its records all go only once it is decided
    /// that the journal is this restore's history.
    fn write_restored(
        self: &Arc<Self>,
        session: &Arc<Session>,
        after: u64,
        records: &[EventRecord],
        resumed: bool,
        files: &[(std::path::PathBuf, Vec<u8>)],
    ) -> Result<Value, RpcError> {
        let old = self.at_ff3d();
        let (at, failed, flush_failed) = {
            let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
            self.catch_up_locked(session);
            let mut at = session.seq.load(Ordering::SeqCst);
            // Where the recovery it takes back begins, once it is decided.
            let mut take_back = None;
            // Whether the journal's own recovery at its end is settled by this restore: taken
            // back, or held by the owner's copy as it is.
            let mut settled = false;
            // What this machine's own recovery wrote after a restart, at the end of its journal
            // (review of #37284 at 4dcbe192, F1): the owner's copy holds what was there. The
            // restore takes the copy from where the recovery began; those records go, and the
            // recovery is made again on the restored log.
            if !self.at_4dcb()
                && let Some(from) = self.recovery_tail(session, at)?
                && records.last().is_some_and(|r| r.seq > from)
            {
                settled = true;
                // A copy that holds the recovery's own records and nothing past them (its pages
                // saw them; the owner restores from `recoveredAfter`, review of #37284 at
                // 8b5f3063, F2) brings nothing back: the journal stays as it is, and its turn is
                // not continued again.
                if !self.at_8b5f() && self.holds_as_is(session, (from, at), records)? {
                    tracing::info!(session = %session.id, from, at, "journal restore: the owner's copy holds this journal's own recovery as it is");
                } else {
                    if after > from {
                        return Err(refused(
                            "recovered",
                            "this journal's end is its own recovery",
                            session,
                        )
                        .with_data(
                            json!({"reason": "recovered", "afterSeq": from, "lastSeq": at}),
                        ));
                    }
                    if old {
                        self.take_back_recovery(session, from)?;
                    } else {
                        take_back = Some(from);
                    }
                    at = from;
                }
            }
            tracing::info!(
                session = %session.id,
                at,
                after,
                records = records.len(),
                first = records.first().map(|r| r.seq),
                through = records.last().map(|r| r.seq),
                "journal restore: where this journal ends, and what the owner's copy brings"
            );
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
            // Decided: this restore goes ahead. Its recovery goes, then its prompts' files, then
            // its records.
            if let Some(from) = take_back {
                self.take_back_recovery(session, from)?;
            }
            if !old {
                let named = files_named(records.iter().filter(|r| r.seq > at));
                let files: Vec<_> =
                    files.iter().filter(|(p, _)| named.contains(p)).cloned().collect();
                restore_files(session, &files, false)?;
            }
            let mut failed = None;
            for (n, record) in records.iter().filter(|r| r.seq > at).enumerate() {
                #[cfg(test)]
                if n > 0 {
                    test_between_records(&session.id);
                }
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
            let flushed = if test_flush_fails(&session.id) {
                Err(anyhow::anyhow!("test: the flush fails"))
            } else {
                self.store.flush_session(&session.id)
            };
            // (4) Where the journal ends is read back from it, never counted here: an append can
            // fail after its line is written, and the next try must go on after that line.
            let durable = self.store.events(&session.id, at, usize::MAX);
            let durable = match durable {
                Ok(durable) => durable,
                Err(e) => return Err(stopped(session, &e)),
            };
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            // Its own recovery, settled (taken back, or held by the copy as it is), is named to
            // the owner no more; the records put back say where a recovery among them ends the
            // journal now (review of #37284 at 8b5f3063, F2).
            let note = !self.at_8b5f();
            if note && settled {
                meta.recovered_after = None;
            }
            for record in &durable {
                count_restored(&mut meta, record);
                if note {
                    super::restore_writer::note_recovery(&mut meta, record);
                }
            }
            let last = durable.iter().map(|r| r.seq).max().unwrap_or(at);
            meta.last_seq = last;
            drop(meta);
            session.seq.store(last, Ordering::SeqCst);
            (at, failed, flushed.err())
        };
        // Its counts and end are on disk before it answers, or it stops short (review of #37284
        // at a088585e: a failed save was logged, and the restore answered done).
        if !self.at_a088()
            && let Err(e) = self.save_meta_answered(session)
        {
            return Err(stopped(
                session,
                &anyhow::anyhow!("its counts were not saved: {}", e.message),
            ));
        }
        if self.at_a088() {
            self.save_meta(session);
        }
        let last = session.seq.load(Ordering::SeqCst);
        let through = records.last().map_or(after, |r| r.seq);
        // Only every record in and flushed to stable storage is a restore: until then nothing
        // settles the log, and the owner keeps its copy and delivers nothing again
        // (`peer_snapshot/restore.rs`). A flush that failed fails it however far the log reads.
        let short = last < through;
        if let Some(e) = flush_failed
            .or_else(|| failed.filter(|_| short))
            .or_else(|| short.then(|| anyhow::anyhow!("the journal ends at {last}, not {through}")))
        {
            return Err(stopped(session, &e));
        }
        // (6) Settled as after a restart, still holding the turn lock: the cut turn is marked and
        // continued, the queue rebuilt; what they start waits for the lock. A try that goes on
        // after one that stopped short settles what that one wrote too.
        let restored = last > at || resumed;
        // The prompts the restore queued: they go ahead of the machine's own.
        let from_copy = records
            .iter()
            .filter(|r| r.seq > after && r.kind == "queued")
            .filter_map(|r| r.msg.get("promptId").and_then(Value::as_str))
            .map(str::to_owned)
            .collect();
        // What parked while it held the chat goes in before anything is rebuilt from the
        // journal; one the store refuses fails the try (`append_failed`), and the chat stays held
        // for the next (review of #37284 at a088585e, F1: a088585e rebuilt without it, and the
        // queue edit it held was lost).
        if !self.at_a088() && !self.write_parked(session) {
            let e = anyhow::anyhow!("records kept while it held the chat were not stored");
            return Err(stopped(session, &e));
        }
        // A log read for this restore recovers now, on the restored log, as a load does.
        if !self.recover_pending(session, Some(&from_copy)) && restored {
            self.settle_restored(session, &from_copy);
        }
        tracing::info!(session = %session.id, after, last, "journal restored from the owner's copy");
        self.update_live_session_index(session);
        Ok(json!({"sessionId": session.id, "lastSeq": last, "restored": restored}))
    }
}

impl Hub {
    /// Where the recovery records at the end of `session`'s journal (through `at`) begin: the
    /// seq before the first of them; None when its last record is not one. The whole run is read,
    /// back from `at` a page at a time, however long it is (review of #37284 at c4a6f4e7, F2: a
    /// recovery writes a record per open subagent, so no fixed window holds it); c4a6f4e7 read
    /// only the last 256 records.
    pub(super) fn recovery_tail(
        &self,
        session: &Session,
        at: u64,
    ) -> Result<Option<u64>, RpcError> {
        const PAGE: u64 = 256;
        let mut from = None;
        let mut end = at;
        while end > 0 {
            let start = end.saturating_sub(PAGE);
            let page = self
                .store
                .events(&session.id, start, usize::try_from(end - start).unwrap_or(usize::MAX))
                .map_err(|e| RpcError::internal(e.to_string()))?;
            for record in page.iter().rev().filter(|r| r.seq <= end) {
                if !super::restore_writer::is_recovery(record) {
                    return Ok(from);
                }
                from = Some(record.seq.saturating_sub(1));
            }
            if self.at_c4a6() {
                break;
            }
            end = start;
        }
        Ok(from)
    }

    /// Whether `records` hold nothing past `at` and are, at each seq past `from` they hold, the
    /// record `session`'s journal holds there (by time and kind, as a restore compares): the
    /// recovery's own records from `from` to `at`, as the owner's copy saw them on a link before.
    fn holds_as_is(
        &self,
        session: &Session,
        (from, at): (u64, u64),
        records: &[EventRecord],
    ) -> Result<bool, RpcError> {
        if records.last().is_none_or(|r| r.seq > at) {
            return Ok(false);
        }
        let held = self
            .store
            .events(&session.id, from, usize::try_from(at - from).unwrap_or(usize::MAX))
            .map_err(|e| RpcError::internal(e.to_string()))?;
        let held: HashMap<u64, (u64, &str)> =
            held.iter().map(|e| (e.seq, (e.at, e.kind.as_str()))).collect();
        Ok(records
            .iter()
            .filter(|r| r.seq > from)
            .all(|r| held.get(&r.seq) == Some(&(r.at, r.kind.as_str()))))
    }

    /// Leaves out of `session`'s journal every record past `from` (its own recovery's, read by
    /// [`Self::recovery_tail`]): its end is `from` again. The caller holds `append_lock`.
    fn take_back_recovery(&self, session: &Session, from: u64) -> Result<(), RpcError> {
        // The lowered end is on disk before the cut (review of #37284 at 8b5f3063, F3): a crash
        // after the cut, between the records put back, left the saved end at the recovery's,
        // past the journal's; a restart that found no cut turn trusted it, and the owner sent
        // only what was past that false end. Saved first, a restart counts whatever the journal
        // holds past `from` (`catch_up_locked`): the recovery when no cut ran, the records put
        // back when it did. 8b5f3063 lowered the end in memory only, after the cut.
        let was =
            if self.at_8b5f() { None } else { Some(self.save_end_before_cut(session, from)?) };
        let mut done = false;
        let mut error = None;
        // A store that wrote a record back meanwhile (`journal_store.rs`) refuses one try.
        for _ in 0..3 {
            match self.store.truncate_after(&session.id, from) {
                Ok(true) => {
                    done = true;
                    break;
                }
                Ok(false) => {}
                Err(e) => {
                    error = Some(e);
                    break;
                }
            }
        }
        if !done && was.is_some() && !self.at_fd33() {
            // Where the journal ends now is read back from it, never assumed (review of #37284
            // at fd33a65b, F2): a cut can fail after it put the shorter journal in place (the
            // store's `commit_compaction` renames the segments, then fails writing its marker).
            // fd33a65b took every failed cut as nothing cut and put the old end back: the next
            // try compared only the records the journal still held, appended only those past
            // that false end, and answered done with the records between them missing.
            self.end_after_failed_cut(session, from);
            let e = error
                .unwrap_or_else(|| anyhow::anyhow!("its own recovery could not be taken back"));
            return Err(stopped(session, &e));
        }
        if !done {
            // fd33a65b's (and 8b5f3063's, which saved no lowered end): the journal was taken to
            // hold the recovery still, its end and count as they were.
            if let Some((last_seq, event_count)) = was {
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                (meta.last_seq, meta.event_count) = (last_seq, event_count);
                drop(meta);
                self.save_meta(session);
            }
            let e = error
                .unwrap_or_else(|| anyhow::anyhow!("its own recovery could not be taken back"));
            return Err(stopped(session, &e));
        }
        tracing::info!(session = %session.id, from, "a restore takes back what this machine's recovery wrote");
        session.seq.store(from, Ordering::SeqCst);
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_seq = from;
        // The message ids it holds may be of records gone (`recover_message_events`).
        *session.message_ids.lock().unwrap_or_else(|e| e.into_inner()) = None;
        Ok(())
    }

    /// Sets `session`'s end and count from what its journal holds past `from` after a cut that
    /// failed or was refused, whose lowered end ([`Self::save_end_before_cut`]) is in its meta
    /// now: the records the cut left past `from` count again, none when it cut them all (review
    /// of #37284 at fd33a65b, F2). The try stops with that end, and the owner's next try sends
    /// from it. A journal that does not read keeps the lowered end, never past the journal's,
    /// and the next try counts its tail before it begins (`catch_up_locked`). The caller holds
    /// `append_lock`.
    fn end_after_failed_cut(&self, session: &Session, from: u64) {
        // The message ids it holds may be of records gone (`recover_message_events`).
        *session.message_ids.lock().unwrap_or_else(|e| e.into_inner()) = None;
        let Ok((left, last)) = self.store.tail_after(&session.id, from) else {
            tracing::warn!(session = %session.id, from, "a failed cut's journal does not read; its end stays lowered");
            session.seq.store(from, Ordering::SeqCst);
            session.caught_up.store(false, Ordering::SeqCst);
            return;
        };
        tracing::info!(session = %session.id, from, last, left, "a cut that failed left the journal ending here");
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        meta.last_seq = last;
        meta.event_count += left;
        drop(meta);
        session.seq.store(last, Ordering::SeqCst);
        self.save_meta(session);
    }

    /// Saves `session`'s end as `from`, and its count without the records past it, before a
    /// [`Self::take_back_recovery`] cuts them, and waits until that is durable: the saved end is
    /// never past the journal's, whenever a crash comes. A restart before the cut counts those
    /// records again (`catch_up_locked`). Answers the end and count it had; a save that fails
    /// puts them back and stops the try, with nothing cut. The caller holds `append_lock`.
    fn save_end_before_cut(&self, session: &Session, from: u64) -> Result<(u64, u64), RpcError> {
        let (taken, _) =
            self.store.tail_after(&session.id, from).map_err(|e| stopped(session, &e))?;
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let was = (meta.last_seq, meta.event_count);
        meta.last_seq = from;
        meta.event_count = meta.event_count.saturating_sub(taken);
        drop(meta);
        if let Err(e) = self.save_meta_answered(session) {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            (meta.last_seq, meta.event_count) = was;
            drop(meta);
            let e = anyhow::anyhow!("its end before the cut was not saved: {}", e.message);
            return Err(stopped(session, &e));
        }
        Ok(was)
    }
}

/// The files a restore brings (`files`: each one's `path` and base64 `data`), checked to be in
/// the chat's own uploads folder before anything is written; and its prompts' images (`image`,
/// the id a record names it by, and `data`, whose SHA-256 that id is: review of #37284 at
/// a088585e, F2), kept where this machine keeps a prompt's images.
fn files_of(params: &Value) -> Result<Vec<(std::path::PathBuf, Vec<u8>)>, RpcError> {
    use base64::Engine as _;
    let Some(files) = params.get("files").and_then(Value::as_array) else { return Ok(Vec::new()) };
    let id = params.get("sessionId").and_then(Value::as_str).unwrap_or_default();
    files
        .iter()
        .map(|f| {
            let data = f.get("data").and_then(Value::as_str);
            let bytes = data.and_then(|d| base64::engine::general_purpose::STANDARD.decode(d).ok());
            if let Some(image) = f.get("image").and_then(Value::as_str) {
                let path = super::prompt_images::image_path(image);
                return match (path, bytes) {
                    (Some(path), Some(bytes)) if crate::attach::sha256(&bytes) == image => {
                        Ok((path, bytes))
                    }
                    _ => Err(RpcError::invalid_params(
                        "a restore's image is the SHA-256 of its base64 data",
                    )),
                };
            }
            let path = f.get("path").and_then(Value::as_str).and_then(|p| upload_path(id, p));
            match (path, bytes) {
                (Some(path), Some(bytes)) => Ok((path, bytes)),
                _ => Err(RpcError::invalid_params(
                    "a restore's file is a path in this chat's uploads and its base64 data",
                )),
            }
        })
        .collect()
}

/// `path` when it is a file in chat `id`'s uploads folder (`hub/file_uploads.rs`): absolute,
/// under it, with no `..`.
fn upload_path(id: &str, path: &str) -> Option<std::path::PathBuf> {
    let root = super::file_uploads::session_dir(id)?;
    let path = std::path::PathBuf::from(path);
    let plain = path
        .components()
        .all(|c| matches!(c, std::path::Component::RootDir | std::path::Component::Normal(_)));
    (plain && path.is_absolute() && path.starts_with(&root) && path != root).then_some(path)
}

/// The files the `queued` records among `records` name as saved on this machine, and the kept
/// images their prompts' records name (`user_message`, `queued`, `queue_updated`).
fn files_named<'a>(
    records: impl Iterator<Item = &'a EventRecord> + Clone,
) -> std::collections::HashSet<std::path::PathBuf> {
    let files = records
        .clone()
        .filter(|r| r.kind == "queued")
        .filter_map(|r| r.msg.get("prompt").and_then(Value::as_array))
        .flat_map(|blocks| crate::attach::saved_links(blocks))
        .map(|(path, _)| path);
    let images = records
        .filter(|r| matches!(r.kind.as_str(), "user_message" | "queued" | "queue_updated"))
        .flat_map(|r| super::prompt_images::named_ids(&r.msg))
        .filter_map(super::prompt_images::image_path);
    files.chain(images).collect()
}

/// Writes each of `files` that the chat lacks; a failed write stops the restore
/// (`append_failed`): the owner keeps its copy, and its delivery stays open. A file the chat
/// holds is its own, as the machine may have changed it, and stays (review of #37284 at
/// ff3da306, F2); `replace` (ff3da306) wrote the owner's bytes over one that differed.
fn restore_files(
    session: &Session,
    files: &[(std::path::PathBuf, Vec<u8>)],
    replace: bool,
) -> Result<(), RpcError> {
    for (path, bytes) in files {
        if std::fs::read(path).is_ok_and(|held| held == *bytes) {
            continue;
        }
        if !replace && std::fs::symlink_metadata(path).is_ok() {
            tracing::info!(session = %session.id, path = %path.display(), "a restored prompt's file is here already, changed: it stays");
            continue;
        }
        // A prompt's image goes where the machine keeps them, named by its hash.
        let image = path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| super::prompt_images::image_path(n).filter(|p| p == path));
        let written = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("{} has no folder", path.display()))
            .and_then(|dir| {
                if image.is_none()
                    && let Some(uploads) = dir.parent()
                {
                    crate::config::private_state_dir(uploads)?;
                }
                crate::config::private_state_dir(dir)
            })
            .and_then(|()| crate::agent_tools::write_private(path, bytes));
        if let Err(e) = written {
            return Err(stopped(session, &e.context(format!("restore {}", path.display()))));
        }
    }
    Ok(())
}

impl Hub {
    /// `_acpmux/attachments_held`: whether chat `sessionId` holds each of `files` (`path`,
    /// `sha256`) as it was saved (review of #37284 at 4dcbe192, F4): the owner lets a proven
    /// delivery's bytes go only then (`open_delivery.rs`).
    pub async fn attachments_held(&self, params: &Value) -> Result<Value, RpcError> {
        let id = params
            .get("sessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?
            .to_owned();
        let files = params
            .get("files")
            .and_then(Value::as_array)
            .ok_or_else(|| RpcError::invalid_params("files is required"))?;
        let mut wanted = Vec::new();
        for f in files {
            let path = f.get("path").and_then(Value::as_str).and_then(|p| upload_path(&id, p));
            let hash = f.get("sha256").and_then(Value::as_str);
            let (Some(path), Some(hash)) = (path, hash) else {
                return Err(RpcError::invalid_params(
                    "each file is a path in this chat's uploads and its sha256",
                ));
            };
            wanted.push((path, hash.to_owned()));
        }
        // And the images its prompt's records name, by id (review of #37284 at a088585e, F2).
        let images = params.get("images").and_then(Value::as_array).into_iter().flatten();
        for image in images {
            let image = image.as_str().unwrap_or_default();
            let Some(path) = super::prompt_images::image_path(image) else {
                return Err(RpcError::invalid_params("each image is the SHA-256 of its bytes"));
            };
            wanted.push((path, image.to_owned()));
        }
        // And the uploads its prompt names, which only this machine holds (review of #37284 at
        // 77f91e5a, F1): each a finished upload of the chat, as the prompt reads it
        // (`prompt_uploads.rs`).
        let mut uploads = Vec::new();
        for upload in params.get("uploads").and_then(Value::as_array).into_iter().flatten() {
            let text = |key: &str| upload.get(key).and_then(Value::as_str);
            let path = text("uploadId")
                .zip(text("fileName"))
                .and_then(|(upload, name)| super::file_uploads::finished_path(&id, upload, name));
            let Some(path) = path else {
                return Err(RpcError::invalid_params(
                    "each upload is an uploadId and fileName of this chat",
                ));
            };
            uploads.push(path);
        }
        let held = tokio::task::spawn_blocking(move || {
            wanted.iter().all(|(path, hash)| {
                std::fs::read(path).is_ok_and(|b| crate::attach::sha256(&b) == *hash)
            }) && uploads.iter().all(|path| super::file_uploads::open_finished(path).is_ok())
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
        Ok(json!({"sessionId": id, "held": held}))
    }
}

/// How long a restore waits for a turn to give back the chat before it answers `busy`.
const TURN_LOCK_WITHIN: Duration = Duration::from_secs(5);

/// How long a restore that stopped short holds its chat for the owner's next try: well past the
/// owner's own tries (`peer_snapshot/restore.rs` `RETRY_WAITS`, 7.5 s, each try at most
/// [`TURN_LOCK_WITHIN`] more). Past it the hold lapses, logged; by then the owner has held the
/// chat on its side (`restore_pending`) and keeps its copy.
const RESTORE_HOLD: Duration = Duration::from_secs(60);

/// The chat is restoring while this lives, unless it is held for the next try.
struct Restoring {
    hub: Arc<Hub>,
    session: Arc<Session>,
    hold: bool,
}

impl Drop for Restoring {
    fn drop(&mut self) {
        if !self.hold {
            release(&self.hub, &self.session);
        }
    }
}

/// The restore ended: what parked meanwhile goes in, then prompts go on.
fn release(hub: &Hub, session: &Session) {
    {
        let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
        *session.restore_lease.lock().unwrap_or_else(|e| e.into_inner()) = None;
        session.restoring.store(false, Ordering::SeqCst);
    }
    hub.unpark_writes(session);
    session.restore_done.notify_waiters();
}

/// Holds `session` (still `restoring`) for the owner's next try; a one-shot timer ends the hold
/// after [`RESTORE_HOLD`] unless a try took it first. A lapse runs the recovery a log read for
/// the restore still owes (`log_load.rs` `recover_pending`) before any prompt goes on, holding
/// the turn lock as a try does, so no try runs meanwhile.
fn hold_for_next_try(hub: &Arc<Hub>, session: &Arc<Session>) {
    static HOLDS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = HOLDS.fetch_add(1, Ordering::SeqCst) + 1;
    {
        let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
        *session.restore_lease.lock().unwrap_or_else(|e| e.into_inner()) = Some(n);
    }
    let (hub, session) = (hub.clone(), session.clone());
    tokio::spawn(async move {
        tokio::time::sleep(RESTORE_HOLD).await;
        let _turn = session.turn_lock.lock().await;
        let lapsed = {
            let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
            let mut lease = session.restore_lease.lock().unwrap_or_else(|e| e.into_inner());
            let lapsed = *lease == Some(n);
            if lapsed {
                *lease = None;
            }
            lapsed
        };
        if !lapsed {
            return;
        }
        let (h, s) = (hub.clone(), session.clone());
        let recovered = tokio::task::spawn_blocking(move || {
            let _writer = super::restore_writer::RestoreWriter::hold(&s);
            let _loaded = s.log_load.lock().unwrap_or_else(|e| e.into_inner());
            h.recover_pending(&s, None);
        });
        if let Err(e) = recovered.await {
            tracing::error!(session = %session.id, "recovering a chat log after a restore's hold failed: {e}");
        }
        tracing::warn!(
            session = %session.id,
            "the owner did not finish restoring this chat's journal; its prompts go on"
        );
        release(&hub, &session);
    });
}

fn reason_of(e: &RpcError) -> Option<&str> {
    e.data.as_ref()?.get("reason")?.as_str()
}

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
    // A subagent entry may leave a retry open: the settle reads the log for it
    // (`subagent_retry.rs` `settle_subagent_retries`), and saves what it finds.
    if record.kind == "subagent_state_update" {
        meta.subagent_retry_open = true;
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

/// Tests only: what runs on another thread once the settle of a restore of chat `id` wrote
/// what parked, before it rebuilds the queue (`log_load.rs`): a queue change in that gap.
#[cfg(test)]
type Gap = Box<dyn FnOnce() + Send>;

#[cfg(test)]
static AFTER_DRAIN: std::sync::Mutex<Option<(String, Gap)>> = std::sync::Mutex::new(None);

#[cfg(test)]
pub(crate) fn after_drain_once(id: &str, change: Gap) {
    *AFTER_DRAIN.lock().unwrap_or_else(|e| e.into_inner()) = Some((id.to_owned(), change));
}

/// Runs [`after_drain_once`]'s change of chat `id` on its own thread, and waits for it.
#[cfg(test)]
pub(super) fn test_after_drain(id: &str) {
    let change = {
        let mut armed = AFTER_DRAIN.lock().unwrap_or_else(|e| e.into_inner());
        match armed.take() {
            Some((at, change)) if at == id => Some(change),
            other => {
                *armed = other;
                None
            }
        }
    };
    if let Some(change) = change {
        std::thread::spawn(change).join().unwrap();
    }
}

/// Tests only: what runs once a restore of chat `id` put its first record back, before its
/// second: a crash there, as a test copies what the disk holds then.
#[cfg(test)]
static BETWEEN_RECORDS: std::sync::Mutex<Option<(String, Gap)>> = std::sync::Mutex::new(None);

#[cfg(test)]
pub(crate) fn between_records_once(id: &str, crash: Gap) {
    *BETWEEN_RECORDS.lock().unwrap_or_else(|e| e.into_inner()) = Some((id.to_owned(), crash));
}

/// Runs [`between_records_once`]'s crash of chat `id`, on the restore's thread.
#[cfg(test)]
fn test_between_records(id: &str) {
    let crash = {
        let mut armed = BETWEEN_RECORDS.lock().unwrap_or_else(|e| e.into_inner());
        match armed.take() {
            Some((at, crash)) if at == id => Some(crash),
            other => {
                *armed = other;
                None
            }
        }
    };
    if let Some(crash) = crash {
        crash();
    }
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

/// Debug builds only: the next flush of a restore of chat `id` fails (a disk whose fsync fails),
/// after every record is written.
#[cfg(debug_assertions)]
static FLUSH_FAILS: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn fail_flush_once(id: &str) {
    *FLUSH_FAILS.lock().unwrap_or_else(|e| e.into_inner()) = Some(id.to_owned());
}

#[cfg(debug_assertions)]
fn test_flush_fails(id: &str) -> bool {
    let mut armed = FLUSH_FAILS.lock().unwrap_or_else(|e| e.into_inner());
    let fails = armed.as_deref() == Some(id);
    if fails {
        *armed = None;
    }
    fails
}

#[cfg(not(debug_assertions))]
fn test_flush_fails(_: &str) -> bool {
    false
}
