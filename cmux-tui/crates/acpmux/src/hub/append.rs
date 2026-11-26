//! Part of `Hub`; see `hub/mod.rs`. Appending to a session's event log: every `append*` entry
//! point, and the locked write that stamps, stores and fans out one record.

use super::*;

impl Hub {
    // ------------------------------------------------------------ logging

    pub(crate) fn append(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> EventRecord {
        self.append_with_host_seq(session, dir, kind, msg, None)
    }

    /// Persist one session-to-session message projection. The journal containing the copy is
    /// named by `session`; the payload keeps that id too so clients can route a replayed event.
    #[cfg(test)]
    pub(crate) fn append_message_event(
        &self,
        session: &Session,
        sender: Value,
        text: String,
        message_id: String,
        at: u64,
    ) -> bool {
        self.append_message_event_scoped(session, sender, text, message_id, at, None, None)
    }

    /// `target_scope` names the receiving chat of a sender's copy, and `target_peer` the peer
    /// that holds it: a peer's chat may keep the raw id of one here (an export and import keeps
    /// ids), and a message to each is its own copy.
    #[allow(clippy::too_many_arguments)] // One copy's fields, each its own value.
    pub(crate) fn append_message_event_scoped(
        &self,
        session: &Session,
        sender: Value,
        text: String,
        message_id: String,
        at: u64,
        target_scope: Option<&str>,
        target_peer: Option<&str>,
    ) -> bool {
        #[cfg(test)]
        if self
            .message_projection_failures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&session.id)
        {
            return false;
        }
        let mut msg = json!({
            "sessionId": session.id.clone(),
            "sender": sender,
            "text": text,
            "at": at,
            "messageId": message_id,
        });
        if let Some(target) = target_scope {
            msg.set("_acpmuxTarget", json!(target));
            if let Some(peer) = target_peer {
                msg.set("_acpmuxTargetPeer", json!(peer));
            }
        }
        tool_paths::add_canonical_paths(session, "_acpmux/message", &mut msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        // A forwarded delivery can be accepted more than once while a caller retries
        // the same id.  Keep one projection per delivery id in the durable journal,
        // including after a daemon restart. Load the id index once, not once per
        // message or recovered record. The append lock serializes check and append.
        let mut index = session.message_ids.lock().unwrap_or_else(|e| e.into_inner());
        if index.is_none() {
            let mut ids = std::collections::HashSet::new();
            if let Err(error) =
                self.store.scan_kinds(&session.id, &["_acpmux/message"], &mut |record| {
                    if let Some(id) = record.msg.get("messageId").and_then(Value::as_str) {
                        let target = record.msg.get("_acpmuxTarget").and_then(Value::as_str);
                        let peer = record.msg.get("_acpmuxTargetPeer").and_then(Value::as_str);
                        ids.insert(message_key(id, target, peer));
                    }
                    true
                })
            {
                tracing::warn!(session = %session.id, %error, "cannot read message projection ids");
                return false;
            }
            *index = Some(ids);
        }
        let Some(ids) = index.as_mut() else { return false };
        let key = message_key(&message_id, target_scope, target_peer);
        if ids.contains(&key) {
            return true;
        }
        // The payload retains the acceptance time; the journal records when this
        // copy was appended, so recovering an old message cannot regress activity.
        // Published only once stored: a failed copy is repaired later (`message_events.rs`),
        // and that repair's copy is the one clients and peers hear.
        if self.append_at_locked(session, "mux", "_acpmux/message", msg, None, None, true, true).1 {
            ids.insert(key);
            true
        } else {
            false
        }
    }

    /// Record the sender-side copy when a prompt is accepted by peer `target_peer`'s chat
    /// `target_session`.
    #[allow(clippy::too_many_arguments)] // One copy's fields, each its own value.
    pub(crate) fn append_sender_message_event(
        &self,
        sender_session: &str,
        sender: Value,
        text: String,
        message_id: String,
        at: u64,
        target_peer: &str,
        target_session: &str,
    ) -> bool {
        if let Ok(session) = self.resolve(sender_session)
            && session.id == sender_session
        {
            self.append_message_event_scoped(
                &session,
                sender,
                text,
                message_id,
                at,
                Some(target_session),
                Some(target_peer),
            )
        } else {
            false
        }
    }

    pub(crate) fn append_stored(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> bool {
        self.append_logged(session, dir, kind, msg, None).1
    }

    /// Append one record; `host_seq` names the agent host entry it logs.
    pub(crate) fn append_with_host_seq(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
    ) -> EventRecord {
        self.append_logged(session, dir, kind, msg, host_seq).0
    }

    /// [`Hub::append_with_host_seq`], and whether THIS record is in the
    /// store (a purged session counts as stored: nothing is kept for it).
    /// The tap acknowledges a host entry on this result alone.
    pub(crate) fn append_logged(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
    ) -> (EventRecord, bool) {
        self.append_at(session, dir, kind, msg, host_seq, None)
    }

    /// Persist a record without broadcasting it. Callers use this for a durable marker whose
    /// in-memory state is installed immediately afterward; the following state event is the
    /// first watcher-visible record.
    pub(crate) fn append_quiet(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
    ) -> EventRecord {
        let mut msg = msg;
        tool_paths::add_canonical_paths(session, kind, &mut msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        self.append_at_locked(session, dir, kind, msg, None, None, false, false).0
    }

    /// [`Hub::append_logged`] of a record that happened at `at` (Unix ms;
    /// None: now), as a fork's copy of its parent's turns did.
    pub(crate) fn append_at(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
    ) -> (EventRecord, bool) {
        let mut msg = msg;
        // Off the append lock: it reads the disk.
        tool_paths::add_canonical_paths(session, kind, &mut msg);
        // A finished UI edit or shell call asks for a frame of the page (`turn_frames.rs`).
        turn_frames::record(&session.id, kind, &msg);
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
        self.append_at_locked(session, dir, kind, msg, host_seq, at, false, true)
    }

    /// [`Hub::append_at_locked`] of one record. A record the store refused is neither counted nor
    /// published, so no client or peer hears a copy the journal does not hold. `stored_only`: its
    /// caller appends it again when it is not stored (a restore parks it only otherwise,
    /// `restore_writer.rs`). `kept`: what the log stores for it.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn append_record_locked(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
        stored_only: bool,
        kept: log_deferral::Kept,
        notify: bool,
    ) -> (EventRecord, bool) {
        let msg = restore_writer::marked(msg);
        // A restore owns the chat: the record waits for it to end (`restore_writer.rs`).
        let (msg, kept) = match self.parked_write(
            session,
            dir,
            kind,
            msg,
            host_seq,
            at,
            stored_only,
            kept,
            notify,
        ) {
            Ok(parked) => return parked,
            Err(back) => back,
        };
        // What a restore's end could not store yet goes in first, and this one after it.
        let (msg, kept) = match self.behind_unparked(
            session,
            dir,
            kind,
            msg,
            host_seq,
            at,
            stored_only,
            kept,
            notify,
        ) {
            Ok(behind) => return behind,
            Err(back) => back,
        };
        self.write_record_locked(session, dir, kind, msg, host_seq, at, kept, notify)
    }

    /// [`Hub::append_record_locked`]'s write, once nothing holds the record back.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn write_record_locked(
        &self,
        session: &Session,
        dir: &str,
        kind: &str,
        msg: Value,
        host_seq: Option<u64>,
        at: Option<u64>,
        kept: log_deferral::Kept,
        notify: bool,
    ) -> (EventRecord, bool) {
        let started = std::time::Instant::now();
        let seq = session.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let at = at.unwrap_or_else(now_ms);
        // Record a harmless mux receipt instead of ambiguous completion metadata.
        // Hosted delivery must persist host_seq before acknowledging the entry; a
        // silent drop would lose its durable cursor and allow replay after reconnect.
        let fenced = dir == "in"
            && msg.pointer("/params/update").is_some_and(|u| session.fences_compaction_update(u));
        let record = if fenced {
            EventRecord {
                seq,
                at,
                dir: "mux".into(),
                kind: "compaction_metadata_fenced".into(),
                msg: json!({"sourceKind": kind}),
                host_seq,
            }
        } else {
            EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq }
        };
        // The agent message runaway guard reads progress from here, not the store.
        if agent_pairs::progress_record(&record) {
            session.last_progress.store(seq, Ordering::SeqCst);
        }
        if session.purged.load(Ordering::SeqCst) {
            return (record, true);
        }
        // What its harness spent, read after a turn (`usage_view.rs`), is bookkeeping: it never
        // keeps the chat's agent awake.
        if !(dir == "mux" && kind == usage_view::RECORD_KIND) {
            self.touch(session);
        }
        // A stub goes in without the record's recovery mark (`restore_writer.rs`).
        let stub = matches!(kept, log_deferral::Kept::Stub(_)) && !fenced;
        let appending = std::time::Instant::now();
        let appended = match kept {
            // A fenced record keeps its receipt.
            log_deferral::Kept::Stub(msg) if !fenced => self.store.append(
                &session.id,
                &EventRecord { msg, dir: record.dir.clone(), kind: record.kind.clone(), ..record },
            ),
            _ => self.store.append(&session.id, &record),
        };
        let store_time = appending.elapsed();
        let stored = match appended {
            Ok(()) => true,
            Err(e) => {
                session.append_errors.fetch_add(1, Ordering::SeqCst);
                tracing::warn!(session = %session.id, "append failed: {e}");
                false
            }
        };
        if stored {
            session.note_transfer_event(&record);
            let (save, backfill) = {
                let mut breakdown =
                    session.time_breakdown.lock().unwrap_or_else(|e| e.into_inner());
                if breakdown.initialized {
                    breakdown.record(&record);
                    // Keep the saved copy within `SAVE_EVERY` records of the log, so a restart
                    // folds a few records and never the whole journal.
                    let due =
                        breakdown.last_seq() >= breakdown.saved_seq + time_breakdown::SAVE_EVERY;
                    let save = due.then(|| breakdown.save()).flatten();
                    if let Some((_, seq)) = &save {
                        breakdown.saved_seq = *seq;
                    }
                    (save, false)
                } else {
                    // A chat with no saved copy is folded once, here, never by an open.
                    (None, record.kind == "turn_result")
                }
            };
            if let Some((bytes, seq)) = save
                && let Some(dir) = self.store.session_path(&session.id)
            {
                self.write_time_breakdown(session, &dir.join(time_breakdown::FILE), &bytes, seq);
            }
            if backfill {
                self.start_time_breakdown_backfill(session);
            }
            // The review queue's index and the audit trail: O(1), never blocking on a write.
            self.observe_for_review(session, &record);
        }
        // A closed session's log is not held open: its last records (`status`,
        // then the agent's `stopped`) each close it again (`store.rs` Writers).
        if session.status() == SessionStatus::Closed {
            self.store.close_log(&session.id);
        }
        // A record the store refused (its journal's backlog full, a failed write) is neither
        // counted nor published: no viewer sees an event no log holds, which a later catch-up
        // from the log would contradict (rework stage 3, C3). It leaves a gap in the chat's
        // sequence, which every reader skips; a caller that must keep it appends it again.
        if !stored {
            return (record, false);
        }
        // The line is in the store: v2's book tee marks the chat, whatever `notify` says (a mark
        // and an atomic store, no I/O, never a wait; nothing with no tee installed).
        if let Some(tee) = self.book_tee.get() {
            #[cfg(test)]
            let started = std::time::Instant::now();
            tee.mark(session, seq);
            #[cfg(test)]
            book_tee::note_hook(started.elapsed());
        }
        {
            let mut m = session.meta.lock().unwrap();
            m.last_seq = seq;
            m.event_count += 1;
            m.updated_at = record.at;
            if paging::is_transcript(&record) {
                m.transcript_seq = seq;
            }
            if record.dir == "mux" && record.kind == "turn_result" {
                m.harness_failures.observe(&record.msg, record.seq, record.at);
            }
            // Where the journal's own recovery at its end begins, as the list names it.
            if stub {
                m.recovered_after = None;
            } else {
                restore_writer::note_recovery(&mut m, &record);
            }
            if record.dir == "mux" {
                m.harness_sandbox.observe(&record.kind, &record.msg, record.at);
            }
        }
        // The cost ledger's index: O(1), no IO (its writer thread writes the file).
        self.ledger.observe(session, &record);
        // Its row's sequence numbers and date moved, sent or not: its cached closed row is stale.
        session.summary_gen.fetch_add(1, Ordering::SeqCst);
        if matches!(
            kind,
            "status"
                | "permission_request"
                | "permission_decision"
                | "permission_auto"
                | "permission_group"
                | "permission_chat_allowance"
                | "turn_started"
                | "turn_result"
                | "turn_end"
                | "turn_error"
                | "stopping"
                | "unstuck"
                | "loop_detected"
                | "loop_cleared"
                | harness_sandbox::RECORD_KIND
                | "harness_sandbox_recovered"
                | work_below::RECORD_KIND
                | asks_below::RECORD_KIND
                | "queued"
                | "dequeued"
                | "queue_removed"
                | "queue_order"
                | "queue_restored"
                | "queue_paused"
                | "queue_resumed"
                | "created"
                | "tags"
                | "rules"
                | profile_respawn::RECORD_KIND
        ) {
            session.state_seq.fetch_add(1, Ordering::SeqCst);
        }
        let closed = session.status() == SessionStatus::Closed;
        self.chat_activity_cache.note(&session.id, &record.kind, closed);
        if notify {
            let event = HubEvent {
                session_id: session.id.clone(),
                record: Arc::new(record.clone()),
                remote: None,
                update_line: Default::default(),
                row: Default::default(),
                list_seq: 0,
                peer_batch: false,
            };
            // A live chat's streamed text changes only its own row, which is never cached, so the
            // closed rows keep their bytes while agents stream. Read after the metadata update
            // above: a close that follows appends its own `status` record, which marks them stale.
            let _ = if list_guard::streamed_chunk(&record.dir, &record.kind)
                && session.status() != SessionStatus::Closed
            {
                self.events.send_live_stream(event)
            } else if list_guard::reaches_other_rows(&record.dir, &record.kind) {
                let sent = self.events.send(event);
                self.note_rows_reading(session);
                sent
            } else {
                // Any other record changes its own chat's row only: the other closed rows keep
                // their bytes (`list_guard::Events::send_row`).
                self.events.send_row(session, event)
            };
        }
        crate::gauges::record_writes().note(store_time, started.elapsed());
        (record, stored)
    }
}
