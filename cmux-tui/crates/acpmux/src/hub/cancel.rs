//! Stop: the agent gets the cancel, and the turn ends even if it never
//! answers. Claude Code idle after a local slash command takes the interrupt
//! and writes no result, so acpmux's turn stayed open, Stop did nothing and
//! the queue waited (cosmic-gray, 2026-10-14). After [`CANCEL_GRACE`] acpmux
//! ends the turn itself, as cancelled, and its `turn_result` says
//! `cancelForced`; the prompt's answer, if it ever comes, finds no turn.
//!
//! The grace is long enough for an agent that is only slow to stop: the next
//! queued prompt goes out when the turn ends, and an agent still inside the
//! stopped turn mishandles it (codex-acp folds it into that turn and answers
//! it cancelled, cx-he737). The pane stops showing the turn as working 5 s
//! after Stop on its own.
//!
//! An agent that goes on working after the cancel is stopped harder (2026-10-29: a coordinator
//! kept making tool calls after Stop, and its 319 queued agent messages started the next turn
//! behind it). The forced end used to end only acpmux's turn: the harness went on, its tool
//! calls landed in the next queued turn, and the chat read as running again. Now, when the
//! agent's model kept sending signs of work (`Session::heard`) through the grace, it gets the
//! cancel once more (the adapter's own interrupt: Claude Code's `interrupt` control request,
//! Codex's `turn/interrupt`, ACP `session/cancel`), and if it still works [`INTERRUPT_GRACE`]
//! later acpmux ends its process (its own process group, `ChildAgent::kill`), ends the turn,
//! and starts it again on the same conversation before the next turn can start
//! (`turns.rs` `finish_turn`). Until the turn ends the row reads `stopping`; what the ended
//! process still had in flight never reaches the next turn (`permissions.rs`).
//!
//! Stop never ends a process that runs background work (2026-10-31: a Stop for one tool call
//! killed every background shell and background subagent of a coordinator, hours of work; Leo:
//! "WELL THAT STOP BUTTON STOPPED LITERALLY EVERYTHING"). Background work sends signs of work of
//! its own after the turn stopped (a subagent's progress, its model's stream), so it reads as an
//! agent working through the cancel, and the restart took it all down with the process. While a
//! background process or background subagent runs ([`Hub::runs_background_work`]), the escalation
//! sends the second cancel and then ends only acpmux's turn (`stop_escalated` step `spared`), as
//! an agent that went quiet gets; the process and its background work run on and report when
//! they end. Stopping them stays its own act: a process's kill (`_acpmux/process/kill`) or a
//! subagent's stop (`_acpmux/subagent_stop`). Claude Code's own interrupt spares them too once
//! acpmux says it stops tasks one by one (`claude_stdio/outbound.rs` `initialize_request`).
//!
//! The person's Stop also holds the other agents' messages queued behind the turn
//! ([`Hub::person_stop`]): they stay queued, held, until the person's next turn completes or the
//! queue is resumed, so they do not start a turn the moment the stopped one ends. The person's
//! own queued prompts run next as before.
//!
//! A stopped turn always ends as stopped (`cancelled`), so clients offer Continue on it: also one
//! whose adapter answers the cancel `end_turn` (`turns.rs` `finish_turn`), and one a Stop reached
//! while the chat had no agent (it started, or a failover's fallback did): that Stop is taken, the
//! turn reads `stopping`, and its prompt never reaches the agent that comes (`turns.rs`).

use super::*;
use cmux_json::JsonSet as _;
use std::sync::atomic::AtomicU64;

/// Listed in `initialize`'s features by a daemon that takes a peer's person's Stop as its own
/// person's (`server/requests/person_stop.rs`).
pub(crate) const PERSON_STOP_FEATURE: &str = "personStop";

/// How long a cancelled turn waits for its agent's answer before acpmux ends it.
const CANCEL_GRACE: std::time::Duration = std::time::Duration::from_secs(10);

/// How long an agent that worked through [`CANCEL_GRACE`] gets after its second cancel before
/// acpmux ends its process.
const INTERRUPT_GRACE: std::time::Duration = std::time::Duration::from_secs(5);

/// The answer acpmux gives a turn it ended itself; `restarted` when it ended the agent's
/// process for it too.
pub(super) fn forced_answer(restarted: bool) -> Value {
    let mut mux = json!({"cancelForced": true});
    if restarted {
        mux.set("restarted", json!(true));
    }
    json!({"stopReason": "cancelled", "_meta": {"acpmux": mux}})
}

impl Hub {
    /// Publish one forced answer for a turn. Multiple Stop presses can race
    /// their timers, but a turn has one and only one forced settlement.
    fn force_cancel(session: &Session, turn: &TurnInfo) {
        // The cancel may have waited for the child writer. If that turn ended
        // while the request was in flight, never publish a stale answer into
        // the next turn; the turn its agent ran on into after it ended is the
        // work the Stop was for (`carried_turn.rs`).
        let Some(turn) = Self::carried_on(session, turn) else { return };
        let turn = &turn;
        let already_forced = {
            let mut forced = session.cancel_forced_turn.lock().unwrap_or_else(|e| e.into_inner());
            if forced.as_deref() == Some(turn.turn_id.as_str()) {
                true
            } else {
                *forced = Some(turn.turn_id.clone());
                false
            }
        };
        if already_forced {
            return;
        }
        tracing::warn!(session = %session.id, turn_id = %turn.turn_id, "the agent did not answer the cancel: ending its turn");
        session.steer_end.send_replace(Some((turn.turn_id.clone(), forced_answer(false))));
    }

    /// The person's Stop (`session/cancel` from the person's connection): the running turn's
    /// cancel, and the other agents' messages queued behind it are held (`hold_agent_messages`).
    /// Also with no turn running while anything waits in the queue: the turn may have just ended
    /// and the next one be about to start. A Stop of an idle chat with nothing queued holds nothing.
    pub async fn person_stop(self: &Arc<Self>, session: &Arc<Session>) -> Result<(), RpcError> {
        let turn = session.turn().map(|t| t.turn_id);
        if turn.is_some() || session.queued() > 0 {
            self.hold_agent_messages(session, turn.as_deref().unwrap_or_default());
        }
        self.cancel(session).await
    }

    /// Holds the other agents' messages queued now, and those that come until the hold ends: the
    /// person's next completed turn (`release_held_agent_messages`) or a resume of the queue.
    /// Nothing releases them by a timer (a person's Stop stops the chat until the person acts):
    /// a failed turn's retry wait and a continuation's end leave them held (`resume_held`).
    /// A daemon restart forgets the hold. None is dropped: each stays queued, as `held`, and is
    /// logged so (`queue_paused` with `reason: "stop"`).
    pub(super) fn hold_agent_messages(&self, session: &Arc<Session>, turn_id: &str) {
        static HOLDS: AtomicU64 = AtomicU64::new(0);
        let held: Vec<String> = {
            // Begun under the queue lock, where a release checks and ends it (`digest.rs`).
            let mut queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
            session.stop_hold.store(HOLDS.fetch_add(1, Ordering::SeqCst) + 1, Ordering::SeqCst);
            // Named with those a failed turn held already: the Stop holds them too, and a pane
            // shows each as held by it (`views.rs` `held_by_stop`).
            queue
                .iter_mut()
                .filter(|q| q.run.agent.is_some())
                .map(|q| {
                    // One sent now waits too: the Stop came after it.
                    (q.held, q.sent_now) = (true, false);
                    q.prompt_id.clone()
                })
                .collect()
        };
        if !held.is_empty() {
            self.append(
                session,
                "mux",
                "queue_paused",
                json!({"stoppedTurnId": turn_id, "held": held, "reason": "stop"}),
            );
        }
    }

    /// The turn this Stop stops reads `stopping` until it ends (`views.rs`); true for the first
    /// Stop of the turn, which runs its escalation (`escalate_stop`).
    fn mark_stopping(&self, session: &Session, turn: &TurnInfo) -> bool {
        let first = {
            let mut stopping = session.stopping.lock().unwrap_or_else(|e| e.into_inner());
            let first = stopping.as_deref() != Some(turn.turn_id.as_str());
            *stopping = Some(turn.turn_id.clone());
            first
        };
        if first {
            self.append(session, "mux", "stopping", json!({"turnId": turn.turn_id}));
        }
        first
    }

    /// After a Stop's cancel: the turn ends as it did (the agent answered, or stayed quiet
    /// through the grace and acpmux ends it), or, for an agent that keeps working, the cancel
    /// again and then its process restarted (module docs). `heard` is the agent's count of
    /// model signs when the cancel went out.
    async fn escalate_stop(self: Arc<Self>, session: Arc<Session>, turn: TurnInfo, heard: u64) {
        tokio::time::sleep(CANCEL_GRACE).await;
        // The turn, or the turn its agent ran on into meanwhile (`carried_turn.rs`).
        let open = || Self::carried_on(&session, &turn);
        let Some(current) = open() else { return };
        let working = |since: u64| session.heard.load(Ordering::SeqCst) != since;
        // The agent that runs the turn now: a failover may have replaced the one the Stop saw.
        let Some(child) = session.child.lock().await.clone().filter(|_| working(heard)) else {
            Self::force_cancel(&session, &current);
            return;
        };
        tracing::warn!(session = %session.id, turn_id = %turn.turn_id, "the agent works on after Stop: cancelling again");
        self.append(
            &session,
            "mux",
            "stop_escalated",
            json!({"turnId": turn.turn_id, "step": "interrupt"}),
        );
        let heard = session.heard.load(Ordering::SeqCst);
        let deadline = tokio::time::Instant::now() + INTERRUPT_GRACE;
        // Bounded: an agent that stopped reading its input is ended all the same.
        if let Some(sid) = session.meta().agent_session_id {
            let cancel = child.notify(method::SESSION_CANCEL, json!({"sessionId": sid}));
            match tokio::time::timeout_at(deadline, cancel).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => tracing::debug!(session = %session.id, "second cancel: {e}"),
                Err(_) => tracing::debug!(session = %session.id, "second cancel: not written"),
            }
        }
        tokio::time::sleep_until(deadline).await;
        let Some(current) = open() else { return };
        let Some(child) = session.child.lock().await.clone().filter(|_| working(heard)) else {
            Self::force_cancel(&session, &current);
            return;
        };
        // Its background work would end with the process: only the turn ends (module docs).
        if self.runs_background_work(&session) {
            tracing::warn!(session = %session.id, turn_id = %turn.turn_id, "the agent works on after two cancels, beside background work: ending only its turn");
            self.append(
                &session,
                "mux",
                "stop_escalated",
                json!({"turnId": turn.turn_id, "step": "spared", "reason": "background_work"}),
            );
            Self::force_cancel(&session, &current);
            return;
        }
        self.restart_stopped_agent(&session, &child, &current).await;
    }

    /// A background process (`processes.rs`) or a background subagent (`subagents.rs`) of the
    /// session still runs: work that outlives the turn and ends with the agent's process.
    pub(super) fn runs_background_work(&self, session: &Session) -> bool {
        self.any_process_running(session)
            || session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running() > 0
    }

    /// After a turn ends, with its turn lock still held: starts the agent a Stop ended
    /// (`restart_stopped_agent`) again on the same conversation, so the next queued turn finds
    /// it running. Run by a prompt's turn (`turns.rs`) and by a carried turn
    /// (`carried_turn.rs`). A close (`kill`) since the turn's request came (`stops`) starts
    /// nothing (`child_for_since`), nor does another Stop since the restart was marked.
    ///
    /// This start decides nothing about what runs next: every queued turn starts its agent
    /// itself (`run_prompt`'s `child_for_since`), and after the person's Stop the hold
    /// (`hold_agent_messages`), not the agent, keeps the other agents' messages from running.
    /// The Stop count read here only saves a start nobody may need; a Stop that lands while the
    /// agent starts finds no turn to stop and leaves it idle, as a Stop of an idle chat does.
    pub(super) async fn respawn_stopped_agent(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_id: &str,
        stops: u64,
    ) {
        let respawn = session.stop_respawn.swap(0, Ordering::SeqCst);
        if respawn == 0
            || respawn != session.cancels.load(Ordering::SeqCst) + 1
            || session.status() == SessionStatus::Closed
        {
            return;
        }
        match self.child_for_since(session, stops).await {
            Ok(_) => {
                self.append(session, "mux", "stop_restarted", json!({"turnId": turn_id}));
            }
            Err(e) => {
                tracing::warn!(session = %session.id, "the agent a Stop ended did not start again: {}", e.message);
            }
        }
    }

    /// Ends the process of an agent that worked through both cancels, then its turn. Its prompt
    /// fails as the process ends and answers as the forced cancel; the agent starts again on the
    /// same conversation as the turn ends, before the next one (`finish_turn`).
    async fn restart_stopped_agent(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        turn: &TurnInfo,
    ) {
        {
            // Under the agent slot: it is still this agent's, and the turn still runs, as the
            // marks are set, so the turn's end (`finish_turn`) reads them, whenever it comes.
            let mut slot = session.child.lock().await;
            if slot.as_ref().is_none_or(|c| c.generation != child.generation) {
                return;
            }
            *session.stop_restart.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(turn.turn_id.clone());
            // With the Stop count now: a Stop after this one starts nothing (`turns.rs`).
            let cancels = session.cancels.load(Ordering::SeqCst);
            session.stop_respawn.store(cancels + 1, Ordering::SeqCst);
            if session.turn().is_none_or(|t| t.turn_id != turn.turn_id) {
                // It ended by itself just now: nothing to stop, and nothing marked stays.
                session.stop_respawn.store(0, Ordering::SeqCst);
                session.stop_restart.lock().unwrap_or_else(|e| e.into_inner()).take();
                return;
            }
            // No other Stop's timer settles this turn now: this one does, once the process ended.
            *session.cancel_forced_turn.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(turn.turn_id.clone());
            session.stopped_agent.store(child.generation, Ordering::SeqCst);
            // Its tap and every older one no longer count signs of work (`tap.rs`).
            session.muted_taps.store(session.taps.load(Ordering::SeqCst), Ordering::SeqCst);
            // Ended on purpose: no failover and no continuation starts it again for this turn.
            child.end_on_purpose();
            *slot = None;
        }
        tracing::warn!(session = %session.id, turn_id = %turn.turn_id, pid = ?child.pid, "the agent works on after two cancels: restarting it");
        self.append(
            session,
            "mux",
            "stop_escalated",
            json!({"turnId": turn.turn_id, "step": "restart", "pid": child.pid}),
        );
        self.cancel_pending_permissions(session);
        // Its own process group only (`ChildAgent::kill`), and it waits for the process to end.
        child.kill().await;
        if session.turn().is_some_and(|t| t.turn_id == turn.turn_id) {
            session.steer_end.send_replace(Some((turn.turn_id.clone(), forced_answer(true))));
        }
    }

    pub async fn cancel(self: &Arc<Self>, session: &Arc<Session>) -> Result<(), RpcError> {
        self.cancel_preserving_queued(session, None).await
    }

    /// A Stop while Claude compacts ends the turn at once and withdraws the person's queued
    /// prompts, a prompt promoted with Send now included, except `replacement` (an interrupt's
    /// own prompt); other agents' messages are held, never dropped (`hold_agent_messages`).
    /// Any other Stop withdraws nothing: the queue runs on once the turn ends.
    pub(super) async fn cancel_preserving_queued(
        self: &Arc<Self>,
        session: &Arc<Session>,
        replacement: Option<&str>,
    ) -> Result<(), RpcError> {
        // First: a prompt about to be written sees it (`turns.rs`).
        session.cancels.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        // Stop also stops an automatic continuation that has not fired yet, and the running
        // turn gets none (`auto_resume.rs`).
        self.stop_auto_resume(session);
        self.stop_subagent_retries(session, false);
        // Capture the turn before waiting for the child writer. A second Stop
        // arriving while Claude is compacting must not retarget a queued or
        // auto-resumed next turn after the first one settles.
        let turn = session.turn();
        let Some(child) = session.child.lock().await.clone() else {
            // No agent runs the turn right now: it starts, or a failover's fallback does
            // (`turns.rs`). The Stop counted above keeps the turn's prompt from that agent, and the
            // turn then ends as cancelled; until then it reads `stopping`, so the Stop shows.
            // With no turn there is nothing it reached: a turn a restart still recovers may be
            // about to run, and the client keeps its Stop for it.
            return match turn.and_then(|turn| Self::carried_on(session, &turn)) {
                Some(turn) => {
                    self.mark_stopping(session, &turn);
                    Ok(())
                }
                None => Err(RpcError::invalid_params("session has no live agent")),
            };
        };
        let compacting = session.compacting.load(std::sync::atomic::Ordering::SeqCst)
            || child.translator.as_ref().is_some_and(|t| t.is_compacting());
        let sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        self.cancel_pending_permissions(session);
        // Reserve our FIFO place before ending the logical turn, without waiting for a
        // backpressured prompt writer. Tokio mutexes queue only when polled; constructing the
        // future alone would let the next prompt overtake the session-wide cancellation.
        // Disable cooperative yielding for this first poll so Pending means a registered
        // mutex waiter, rather than an exhausted task budget before queue registration.
        let input_handoff = tokio::task::unconstrained(session.input_handoff.clone().lock_owned());
        tokio::pin!(input_handoff);
        let acquired = std::future::poll_fn(|cx| {
            std::task::Poll::Ready(std::future::Future::poll(input_handoff.as_mut(), cx))
        })
        .await;
        // Another Stop or a natural result may have ended the captured turn while this
        // caller prepared. Never settle or send its session-wide interrupt into a different turn,
        // except the turn its agent runs on into after it ended (`carried_turn.rs`): that is
        // the work the Stop was for.
        let turn = match turn {
            Some(turn) => match Self::carried_on(session, &turn) {
                Some(current) => Some(current),
                None => return Ok(()),
            },
            None if session.turn().is_some() => return Ok(()),
            None => None,
        };
        // End the logical turn before waiting on a hosted writer. A compacting
        // Claude process can ignore the interrupt, and the first Stop must
        // still settle the UI immediately.
        if compacting && let Some(turn) = turn.as_ref() {
            // Fence inbound metadata before publishing the forced end. The cancel
            // writer can be delayed while Claude continues emitting its old tail.
            session.fence_compaction_metadata();
            if let Some(translator) = child.translator.as_ref() {
                translator.fence_compaction_metadata();
            }
            self.hold_agent_messages(session, &turn.turn_id);
            let queued: Vec<String> = session
                .queue
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .filter(|q| replacement != Some(q.prompt_id.as_str()) && q.run.agent.is_none())
                .map(|q| q.prompt_id.clone())
                .collect();
            for prompt_id in queued {
                self.remove_queued_because(session, &prompt_id, Some("cancel_forced"));
            }
            Self::force_cancel(session, turn);
        }
        // The reservation precedes any next turn's transport handoff, even if that turn
        // starts logically while this Stop waits. Do not reject our own forced settlement:
        // its interrupt must still reach the harness before the replacement prompt.
        let input_handoff = match acquired {
            std::task::Poll::Ready(guard) => guard,
            std::task::Poll::Pending => input_handoff.await,
        };
        #[cfg(test)]
        {
            let seam = self.cancel_write_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        let sent = child
            // Preserve the Stop's compaction snapshot: a delayed writer may run only
            // after the old boundary has already cleared the translator's live flag.
            .notify(
                method::SESSION_CANCEL,
                json!({"sessionId": sid, "_meta": {"acpmux": {"compactionCancelled": compacting}}}),
            )
            .await
            .map_err(|e| RpcError::internal(e.to_string()));
        drop(input_handoff);
        // Stop always ends the turn: an agent that does not answer the cancel
        // (Claude Code idle after a local slash command, while acpmux still
        // waits on the prompt) gets its turn ended here, as cancelled and
        // marked forced. The prompt's answer, if it ever comes, finds no turn.
        if let Some(turn) = turn {
            // Claude Code can report a compaction while it is running, but its
            // interrupt is not guaranteed to end that internal operation. End
            // the acpmux turn now; a later Claude result is stale and cannot
            // reopen it. Other harnesses retain the normal grace period.
            if compacting {
                Self::force_cancel(session, &turn);
            } else if self.mark_stopping(session, &turn) {
                // The model's signs from here on are work after the cancel (`escalate_stop`).
                let heard = session.heard.load(Ordering::SeqCst);
                tokio::spawn(self.clone().escalate_stop(session.clone(), turn, heard));
            }
        }
        sent
    }
}
