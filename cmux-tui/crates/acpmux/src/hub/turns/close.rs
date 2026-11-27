//! Closing a chat: kill, purge and detaching its child (part of `hub/turns.rs`).

use super::*;

impl Hub {
    /// Writes the close's record (`close_why.rs`): `mux/closed` in its log, `close` on its meta,
    /// and one INFO line. A chat already closed keeps the record of its first close.
    pub(super) fn record_close(&self, session: &Arc<Session>, purge: bool, why: CloseWhy) {
        let record = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.status == SessionStatus::Closed {
                return;
            }
            let record = CloseRecord::new(why, &m, now_ms());
            m.close = Some(record.clone());
            record
        };
        tracing::info!(
            session = %session.id,
            name = %session.meta().name,
            actor = %record.actor.kind,
            actor_session = ?record.actor.session,
            actor_host = ?record.actor.host,
            actor_pid = ?record.actor.pid,
            reason = %record.reason,
            outcome = %record.outcome,
            purge,
            "closed"
        );
        self.append(session, "mux", "closed", serde_json::to_value(&record).unwrap_or_default());
    }

    /// Stop the child. The log stays. `purge` also deletes the log.
    /// A close with no closer named is recorded `daemon`/`unrecorded` (`close_why.rs`); every
    /// path that knows who asked calls [`Self::kill_why`].
    pub async fn kill(&self, session: &Arc<Session>, purge: bool) -> Result<(), RpcError> {
        self.kill_why(session, purge, CloseWhy::actor(CloseActor::new("daemon"))).await
    }

    /// `kill`, recording who closed it and why (`close_why.rs`).
    pub async fn kill_why(
        &self,
        session: &Arc<Session>,
        purge: bool,
        why: CloseWhy,
    ) -> Result<(), RpcError> {
        // An idle pass under way ends first; none starts while this stop runs (`idle.rs`).
        let using = session.harness_use.read().await;
        self.kill_held(session, purge, using, why).await
    }

    /// `kill`, with `_using`, a lease of `harness_use` (shared, or exclusive for a conditional
    /// stop, `stop_if_idle.rs`), held until the session is closed.
    pub(in crate::hub) async fn kill_held(
        &self,
        session: &Arc<Session>,
        purge: bool,
        _using: impl Send,
        why: CloseWhy,
    ) -> Result<(), RpcError> {
        // Transfer retirement also closes this exact instance before replacing it.
        // Keep it registered until all cleanup by ID finishes, even across awaits.
        let _closing = session.close_lock.lock().await;
        if !self
            .sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&session.id)
            .is_some_and(|current| Arc::ptr_eq(current, session))
        {
            return Ok(());
        }
        // A chat that goes starts no agent from here on (`Session::purging`): set before the stop
        // is counted, so a start that reads the count after it sees this too. A delete that fails
        // leaves the chat as it was, startable again.
        struct Purging<'a>(Option<&'a AtomicBool>);
        impl Drop for Purging<'_> {
            fn drop(&mut self) {
                if let Some(flag) = self.0 {
                    flag.store(false, Ordering::SeqCst);
                }
            }
        }
        let mut purging = Purging(None);
        if purge && !session.purging.swap(true, Ordering::SeqCst) {
            purging.0 = Some(&session.purging);
        }
        // A chat that goes: its forks take its history before anything of it is stopped or marked
        // purged, and no fork references it after. A fork still being made fails the delete here,
        // with the chat as it was (review of #37020: it failed after `purged`, and the chat's
        // later records were never written).
        let _fence = if purge && !session.replaced.load(Ordering::SeqCst) {
            Some(
                crate::store::fence_history(self.store.as_ref(), &session.id)
                    .map_err(|e| RpcError::internal(e.to_string()))?,
            )
        } else {
            None
        };
        // Its approvals audit entries go first (`audit_log.rs`), before anything of the chat is
        // stopped or marked purged: a purge that fails or times out fails the delete with the
        // chat as it was, still recording (the writer lifts its own fence again).
        if purge {
            self.audit_purge(&session.id).await?;
        }
        // Counted first: a start for a request from before this stop ends (`ensure_child`).
        session.stops.fetch_add(1, Ordering::SeqCst);
        session.closing.store(true, Ordering::SeqCst);
        // A start that waits to be tried again ends its wait (`start_retry.rs`).
        session.start_retry_wake.notify_waiters();
        // Stopped, not hibernated: its next start is no wake (`idle.rs`).
        self.clear_hibernation(session);
        self.stop_auto_resume(session);
        self.stop_subagent_retries(session, true);
        self.revoke_permission_chat(session);
        self.cancel_pending_permissions(session);
        // The prompts queued behind its turn are answered withdrawn: run after the stop, the
        // next one started the closed session again (ergo-walk2). A restart restores no closed
        // session's queue either (`queue.rs` `restore_queue`). A chat an import replaces
        // (`transfer_in.rs`) keeps its log as it was for the copy that takes its id.
        if !session.replaced.load(Ordering::SeqCst) {
            for queued in session.queue() {
                self.remove_queued_because(session, &queued.prompt_id, Some("stopped"));
            }
        }
        if let Some(child) = session.child.lock().await.take() {
            if let Some(sid) = session.meta().agent_session_id {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_millis(500),
                    child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})),
                )
                .await;
            }
            let link_lost = child.host_record().is_some() && !child.is_alive().await;
            child.kill().await;
            // A host whose link was lost cannot take a Terminate frame; one whose link stopped
            // reading did not take it within the grace (`host_unended`).
            if link_lost || child.host_unended() {
                self.end_unadopted_host(session).await;
            }
        } else {
            // A host this daemon could not adopt keeps running until the user
            // ends the session: end it without its protocol (frozen path).
            self.end_unadopted_host(session).await;
        }
        *session.turn.lock().unwrap() = None;
        // A turn its agent ran on its own ends with the chat, whatever its agent's exit said or
        // did not say (a direct agent, a host whose link was lost): no line spins in a closed chat.
        self.end_background_turn(session, "exit");
        // Before the close's event, which sends the cards it owes (`tasks.rs`).
        self.orphan_tasks_of(session, purge);
        // Who closed it, why, and whether its work was done: one record in its log and on its
        // meta, before the status (a lane's tags are still on it: `lane_retire` runs after).
        self.record_close(session, purge, why);
        self.set_status(session, NotWaiting::Closed);
        // Its inbox's timer stops and its senders are answered (`inbox.rs`).
        self.inbox_closed(session);
        // A lane link either end of which closes is retired (`lane_reports.rs`).
        self.lane_retire(&session.id);
        // The session's Claude Code MCP config holds the helper token.
        crate::agent_tools::remove_mcp_config(&crate::config::home(), &session.id);
        // A stop frees its temporary folder (`closed_tmp.rs`); a purge removes it below.
        #[cfg(unix)]
        if !purge && !session.replaced.load(Ordering::SeqCst) {
            self.free_closed_tmp_soon(session);
        }
        if purge {
            super::watches::before_purge(self, &session.id).await?;
            // Its background tasks end with it (`bg_tasks.rs`); a stop keeps them.
            self.bg_purge(session).await?;
            // Their ends go nowhere now: none stays watched (`bg_notify.rs`).
            self.bg_unwatch_session(&session.id);
            {
                // Under the breakdown's lock: a time breakdown save running now lands before the
                // folder is deleted, and none starts after (`views.rs` `write_time_breakdown`).
                let _breakdown = session.time_breakdown.lock().unwrap_or_else(|e| e.into_inner());
                session.purged.store(true, Ordering::SeqCst);
            }
            // An append that read the chat as not purged yet holds its append lock until its line
            // is written: it finishes before the folder goes, and every later one sees `purged`
            // and writes nothing. One that came after the delete removed the folder wrote the
            // chat's log again, its folder with it (`tests/session_delete_disk.rs`).
            drop(session.append_lock.lock().unwrap_or_else(|e| e.into_inner()));
            // Purged now: it never starts an agent again.
            purging.0 = None;
            // Its spend, title and folder leave the cost ledger with it (`hub/ledger`).
            self.ledger.purge(&session.id);
            self.remove_cached_closed_summary(&session.id);
            let replaced = session.replaced.load(Ordering::SeqCst);
            if !self
                .sessions
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&session.id)
                .is_some_and(|current| Arc::ptr_eq(current, session))
            {
                return Ok(());
            }
            self.child_tags.forget(&session.id);
            // Its temporary folder goes with it (`agent/session_tmp.rs`).
            #[cfg(unix)]
            {
                let id = session.id.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    crate::agent::session_tmp::remove_session(&id)
                })
                .await;
            }
            self.git_branch_forget(&session.id);
            // v2's book of the chat lives in its directory: its actor is closed and forgotten
            // first, so none writes into what the delete removes (`book_tee.rs`).
            if let Some(tee) = self.book_tee().cloned() {
                let id = session.id.clone();
                let _ = tokio::task::spawn_blocking(move || tee.forget(&id)).await;
            }
            let deleted = self.store.delete(&session.id);
            if deleted.is_err()
                && let Some(tee) = self.book_tee()
            {
                // The chat stays: its book may be read again.
                tee.unforget(&session.id);
            }
            deleted.map_err(|e| RpcError::internal(e.to_string()))?;
            // An earlier run's caller token proves a purged session no more (`caller_registry.rs`).
            self.caller_registry.forget(&session.id);
            // Its chat secrets go with it (`chat_secrets.rs`).
            crate::chat_secrets::clear(&session.id);
            super::spend_burn::forget(&session.id);
            #[cfg(test)]
            {
                let seam = self.purge_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
                if let Some((arrived, release)) = seam {
                    let _ = arrived.send(());
                    let _ = release.await;
                }
            }
            // The files dropped into the chat go with it (`file_uploads.rs`), unless the chat
            // itself comes back under this id.
            if !replaced {
                let id = session.id.clone();
                let cwd = session.meta().cwd.clone();
                let _ = tokio::task::spawn_blocking(move || {
                    super::file_uploads::remove_session(&id);
                    super::turn_shots::remove_session(&id);
                    super::turn_frames::remove_session(&id);
                    // And the PDFs it saved in its project (`acp_prompt_blocks`).
                    remove_pdf_attachments(&cwd, &id);
                })
                .await;
            }
            // No awaits follow unregistering: a fixed-ID creator may now publish. Keep the
            // removal, index update and event publication under the same lock so a replacement
            // cannot publish its created event before this purge notice.
            let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            if sessions.get(&session.id).is_some_and(|current| Arc::ptr_eq(current, session)) {
                sessions.remove(&session.id);
            }
            self.remove_live_session_index(&session.id);
            // Tell watchers after local resolution can no longer find it, while the sessions lock
            // still prevents a fixed-ID replacement from publishing first.
            let _ = self.events.send(HubEvent {
                session_id: session.id.clone(),
                record: Arc::new(EventRecord {
                    seq: session.meta().last_seq + 1,
                    at: now_ms(),
                    dir: "mux".into(),
                    kind: "purged".into(),
                    msg: if replaced {
                        json!({"sessionId": session.id, "replaced": true})
                    } else {
                        json!({"sessionId": session.id})
                    },
                    host_seq: None,
                }),
                remote: None,
                update_line: Default::default(),
                row: Default::default(),
                list_seq: 0,
                peer_batch: false,
            });
            drop(sessions);
            // Gone from v1: a chat that comes back under the id gets a book again.
            if let Some(tee) = self.book_tee() {
                tee.unforget(&session.id);
            }
            // Its parent's row and the rows below it read it (#42091 F1).
            self.note_rows_reading(session);
        }
        Ok(())
    }

    /// Stop the child but keep the session resumable.
    pub async fn detach_child(&self, session: &Arc<Session>) {
        let _ = self.detach_child_if_current(session, None).await;
    }

    /// Stop the child only while an automatic retry generation remains current. The generation
    /// is checked again under the child-slot lock, so Stop cannot race the final kill.
    pub(in crate::hub) async fn detach_child_if_current(
        &self,
        session: &Arc<Session>,
        generation: Option<u64>,
    ) -> bool {
        // A shutdown that hands this agent to the next daemon began: the agent, its turn and its
        // permission prompts are that daemon's (`shutdown.rs`). Read under the child lock, held
        // until the agent is gone: the shutdown takes it only after it began, so it finds either
        // this detach done or nothing of it.
        // Stop takes the retry mark before it waits for this child slot. A generation-fenced
        // teardown therefore takes the slot without waiting, then tries the mark; if either
        // operation is busy it returns and the retry handoff rechecks after the competitor
        // releases its lock. The guard stays alive through the asynchronous kill.
        let mut slot = match generation {
            Some(_) => match session.child.try_lock() {
                Ok(slot) => slot,
                Err(_) => return false,
            },
            None => session.child.lock().await,
        };
        let child = if let Some(generation) = generation {
            let Some(result) = session.auto_resume.try_with_current(generation, || {
                if self.hands_off(session) {
                    return Err(());
                }
                session.detaching.store(true, Ordering::SeqCst);
                Ok(slot.take())
            }) else {
                return false;
            };
            let Ok(child) = result else {
                return false;
            };
            child
        } else {
            if self.hands_off(session) {
                return false;
            }
            // Held through the agent's end, so no new agent starts beside the one ending; a
            // shutdown that meets the lock meanwhile waits for this end (`detaching`).
            session.detaching.store(true, Ordering::SeqCst);
            slot.take()
        };
        // Permission state is independent of the retry mark. Keep it outside that mark's
        // critical section, while the child slot remains held through the asynchronous kill.
        self.revoke_permission_chat(session);
        self.cancel_pending_permissions(session);
        if let Some(child) = child {
            child.kill().await;
            // A host that never took the terminate still runs its agent: it is ended by its
            // nonce, within a bound too, and what waited on the agent is answered (no exit is
            // read for it). Under the child lock, so no new agent starts beside it.
            if child.host_unended() {
                tracing::warn!(session = %session.id, "its agent's host did not end it in time; the host is ended");
                child.fail_pending().await;
                self.end_unadopted_host(session).await;
            }
        }
        session.detaching.store(false, Ordering::SeqCst);
        drop(slot);
        // Its next start runs the profile as it is now (`profile_respawn.rs`).
        self.settle_profile_respawn(session);
        *session.turn.lock().unwrap() = None;
        if session.status() != SessionStatus::Closed {
            self.set_status(session, NotWaiting::Idle);
        }
        true
    }
}
