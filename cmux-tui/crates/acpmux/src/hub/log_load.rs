//! Part of `Hub`; see `hub/mod.rs`. The chat logs after a daemon restart, live agents first.
//!
//! claude-sr2, 2026-10-26: "After each restart, the daemon reads all 685 sessions' logs (453 of
//! them closed) before it reattaches any agent. For about 3–7 minutes every live session shows
//! idle and the daemon reports 0 live agents, while the agents keep working ... Fix: reattach
//! running and waiting sessions first, from a small index, and load closed or idle sessions'
//! logs lazily (on first open or in the background)."
//!
//! The small index is what a deferred start reads before its ready line: the session list
//! (`session.json`) and the agent host records (`hosts/`, [`LoadPlan`]). A chat whose host still
//! runs keeps its saved status until adoption reaches it (`load_from_store`), and its log is read
//! first (`load_live_logs`), so adoption reattaches it in seconds. Every other chat's log is read
//! by one background pass (`load_logs`, after adoption) or, sooner, by the first request that
//! needs it (`session_log`). Each log is read once (`load_session_log`, under the chat's
//! `log_load` lock).
//!
//! The background pass ends once it has read every chat's log (its stop condition); its worker
//! threads are scoped to it (`on_every_core`). Nothing repeats it, and a chat created after the
//! start has no log to read.

use super::*;

/// What a deferred start read before its ready line, for the chat logs read after it.
#[derive(Default)]
pub(crate) struct LoadPlan {
    /// Chats whose agent host still ran at the start: adopted, never marked lost.
    pub(super) hosted: std::collections::HashSet<String>,
    /// `hosted` as the start read it, never changed: prompts to these chats wait until adoption
    /// and its settling end (`wait_adopted`).
    pub(super) adopting: std::collections::HashSet<String>,
    /// Chats the previous daemon left waiting on a permission (`mark_lost_wait`).
    pub(super) waiting: std::collections::HashSet<String>,
}

impl Hub {
    /// The logs of the chats whose agent host still runs, before adoption reattaches them.
    pub fn load_live_logs(self: &Arc<Self>) {
        let started = std::time::Instant::now();
        let hosted = self.load_plan.lock().unwrap_or_else(|e| e.into_inner()).hosted.clone();
        let sessions: Vec<Arc<Session>> =
            self.sessions().into_iter().filter(|s| hosted.contains(&s.id)).collect();
        self.load_session_logs(&sessions);
        tracing::info!(
            "loaded the chat logs of {} sessions with a running agent in {} ms",
            sessions.len(),
            started.elapsed().as_millis()
        );
    }

    /// `load_live_logs` off the executor.
    pub async fn load_live_logs_async(self: &Arc<Self>) {
        let hub = self.clone();
        if let Err(e) = tokio::task::spawn_blocking(move || hub.load_live_logs()).await {
            tracing::error!("reading the chat logs of running agents failed: {e}");
        }
    }

    /// Reads every chat's log not read yet: each log's tail past its saved `lastSeq`, the turns
    /// a restart cut off, and the queued prompts. A daemon runs it after adoption, in the
    /// background; a request for one chat reads that chat's log first (`session_log`). The
    /// chats used last go first, closed ones after every open one.
    pub fn load_logs(self: &Arc<Self>) {
        let started = std::time::Instant::now();
        // The calls that wait for the load (`wait_logs`) answer even when it fails.
        let _ready = LogsReady(&self.logs_ready);
        let mut sessions = self.sessions();
        sessions.sort_by_cached_key(|s| {
            let m = s.meta();
            (m.status == SessionStatus::Closed, std::cmp::Reverse(m.updated_at))
        });
        self.load_session_logs(&sessions);
        // Deferred startup must restore ownership epochs before the move watchdog can issue an
        // automatic commit/abort. Starting it earlier could fence a valid in-flight move.
        self.watch_transfers();
        // Every log is read: a person's prompt no longer resumes pairs ahead of their logs.
        self.logs_ready.send_replace(true);
        self.forget_pair_peers();
        tracing::info!(
            "loaded the chat logs of {} sessions in {} ms",
            sessions.len(),
            started.elapsed().as_millis()
        );
    }

    /// `load_logs` off the executor.
    pub async fn load_logs_async(self: &Arc<Self>) {
        let hub = self.clone();
        if let Err(e) = tokio::task::spawn_blocking(move || hub.load_logs()).await {
            tracing::error!("reading the chat logs failed: {e}");
            // A task that never ran dropped no guard.
            self.logs_ready.send_replace(true);
        }
    }

    /// Reads `sessions`' logs on up to 8 threads, each on this runtime when there is one (a
    /// restored queue and a watched chat start tasks).
    fn load_session_logs(self: &Arc<Self>, sessions: &[Arc<Session>]) {
        let runtime = tokio::runtime::Handle::try_current().ok();
        self.on_every_core(sessions, |session| {
            let _entered = runtime.as_ref().map(tokio::runtime::Handle::enter);
            self.load_session_log(session);
        });
    }

    /// Wait until adoption has ended, when `session`'s agent host ran at the start (immediate
    /// otherwise): a prompt that went first would take the turn ahead of the turn adoption
    /// recovers (`hosts.rs`).
    pub(crate) async fn wait_adopted(&self, session: &Session) {
        if self.load_plan.lock().unwrap_or_else(|e| e.into_inner()).adopting.contains(&session.id) {
            let mut adopted = self.adoption_ready.subscribe();
            let _ = adopted.wait_for(|ready| *ready).await;
        }
    }

    /// Wait until `session`'s log is read, reading it now when the background pass has not
    /// reached it (immediate outside a deferred start, and once every log is read or the load
    /// failed).
    pub(crate) async fn session_log(self: &Arc<Self>, session: &Arc<Session>) {
        self.session_log_at(session, false).await;
    }

    /// [`Self::session_log`] for a chat being opened on screen: the read is what the person
    /// is waiting on, so it runs ahead of agent work (`qos::on_screen`).
    pub(crate) async fn session_log_on_screen(self: &Arc<Self>, session: &Arc<Session>) {
        self.session_log_at(session, true).await;
    }

    async fn session_log_at(self: &Arc<Self>, session: &Arc<Session>, on_screen: bool) {
        if self.session_log_loaded(session) {
            return;
        }
        let (hub, s) = (self.clone(), session.clone());
        let read = move || {
            if on_screen {
                crate::qos::on_screen(|| hub.load_session_log(&s))
            } else {
                hub.load_session_log(&s)
            }
        };
        if let Err(e) = tokio::task::spawn_blocking(read).await {
            // It answers from the session list, as a failed load does (`LogsReady`).
            tracing::error!(session = %session.id, "reading the chat log failed: {e}");
        }
    }

    /// Whether `session`'s log is read, or every log is (or their load failed).
    pub(crate) fn session_log_loaded(&self, session: &Session) -> bool {
        session.log_loaded.load(Ordering::SeqCst) || self.logs_loaded()
    }

    /// Reads one chat's log, once: its tail, a permission wait or turn the restart cut off, its
    /// queue, and its watched transcript. A chat with no running agent host goes on with its
    /// restored queue as soon as the daemon's own startup resumed the queues (`resume_queues`);
    /// one with a host is resumed there, after adoption.
    pub(super) fn load_session_log(self: &Arc<Self>, session: &Arc<Session>) {
        self.read_log(session, true);
    }

    /// [`Self::load_session_log`] for a journal restore (`journal_restore.rs`): only the tail
    /// is read, and nothing is written (review of #37284 at 91b1343d, F4). The recovery a load
    /// writes (a cut turn's continuation and unknown outcome, a lost wait) would take the seqs
    /// of the records the restore puts back: it runs after them, on the restored log
    /// ([`Self::recover_pending`]).
    pub(super) fn load_session_log_for_restore(self: &Arc<Self>, session: &Arc<Session>) {
        self.read_log(session, self.at_91b());
    }

    fn read_log(self: &Arc<Self>, session: &Arc<Session>, recover: bool) {
        let loaded = session.log_load.lock().unwrap_or_else(|e| e.into_inner());
        if *loaded {
            return;
        }
        // Read once, even when it fails: a second read would restore its queue twice. A chat
        // whose read failed answers from the session list, as a failed load did.
        let mut loaded = Loaded(loaded, &session.log_loaded);
        // Debug builds only: a test makes the load fail as a corrupt log could
        // (`durable_agents.rs`). Release builds have no seam.
        #[cfg(debug_assertions)]
        if std::env::var_os("ACPMUX_TEST_PANIC_IN_LOAD_LOGS").is_some() {
            // crash-allow: debug-build test seam; the test asks for this panic, like a corrupt log
            panic!("ACPMUX_TEST_PANIC_IN_LOAD_LOGS");
        }
        self.catch_up(session);
        if let Err(error) = self.restore_ownership_epoch(session) {
            session.invalidate_ownership_epoch();
            tracing::warn!(session = %session.id, "ownership epoch unreadable: {error}");
        }
        self.restore_transfer_authority(session);
        if !recover {
            // Read, with its recovery still to run: the restore that asked runs it.
            session.recovery_pending.store(true, Ordering::SeqCst);
            loaded.done();
            return;
        }
        let hosted =
            self.load_plan.lock().unwrap_or_else(|e| e.into_inner()).hosted.contains(&session.id);
        self.recover_log(session, None);
        loaded.done();
        self.resume_loaded(session, hosted);
    }

    /// The recovery of a log read for a journal restore ([`Self::load_session_log_for_restore`]),
    /// once, on the log as the restore left it: after its records went in (`from_copy`, the
    /// prompts they queued, go ahead of the machine's own, as `settle_restored` puts them), or
    /// when it was refused or its hold lapsed (None). The caller holds `log_load`. False when
    /// none was pending.
    pub(super) fn recover_pending(
        self: &Arc<Self>,
        session: &Arc<Session>,
        from_copy: Option<&std::collections::HashSet<String>>,
    ) -> bool {
        if !session.recovery_pending.swap(false, Ordering::SeqCst) {
            return false;
        }
        let hosted =
            self.load_plan.lock().unwrap_or_else(|e| e.into_inner()).hosted.contains(&session.id);
        self.recover_log(session, from_copy);
        self.resume_loaded(session, hosted);
        true
    }

    /// What reading a log writes and rebuilds past its tail: a lost wait, a cut turn's
    /// continuation, the queue (`from_copy`'s prompts first, after a restore), and the watch.
    fn recover_log(
        self: &Arc<Self>,
        session: &Arc<Session>,
        from_copy: Option<&std::collections::HashSet<String>>,
    ) {
        // What was written while a restore owns the chat is in the journal first (its own
        // records, never marked as recovery): the recovery reads it, and rebuilds the queue. One
        // the store refuses is read after the journal (`kept_unstored`).
        self.write_parked(session);
        #[cfg(test)]
        super::journal_restore::test_after_drain(&session.id);
        let _marked = super::restore_writer::Recovering::start();
        let (hosted, waiting) = {
            let plan = self.load_plan.lock().unwrap_or_else(|e| e.into_inner());
            (plan.hosted.contains(&session.id), plan.waiting.contains(&session.id))
        };
        // A turn whose agent host still runs is not lost: the host is adopted. A chat closed
        // since the start waits for nothing either.
        if waiting && !hosted && session.status() != SessionStatus::Closed {
            self.mark_lost_wait(session);
        }
        let continued =
            if hosted { None } else { self.mark_unknown_outcome(session, from_copy.is_some()) };
        // A subagent retry the restart dropped, hosted or not (`subagent_retry.rs`).
        self.settle_subagent_retries(session);
        self.restore_queue(session);
        if let Some(from_copy) = from_copy {
            self.replace_queue(session, Vec::new(), from_copy);
        }
        // A change of the queue made meanwhile is rebuilt in (`settle_queue_changes`).
        self.settle_queue_changes(session, from_copy.unwrap_or(&Default::default()));
        // A copy's first start runs none of what waited (`clone_boot.rs`).
        self.drop_cloned_queue(session);
        self.drop_unsent_subagent_retries(session);
        // A crash may leave a durable prompt/queue record before its acceptance
        // callback writes `_acpmux/message`; reconstruct those projections before
        // clients can attach or the restored queue resumes.
        super::message_events::recover_message_events(self, session);
        // A cut turn goes on before what waited behind it (`restart_resume.rs`).
        if let Some(prompt_id) = continued {
            let _ = self.move_queued(session, &prompt_id, 0, None);
        }
        // A watched chat goes on following its transcript where it stopped (`watch.rs`).
        if tokio::runtime::Handle::try_current().is_ok() {
            self.start_watch(session);
        }
    }

    /// A read log's queue goes on, once the daemon's own startup resumed the queues.
    fn resume_loaded(self: &Arc<Self>, session: &Arc<Session>, hosted: bool) {
        if self.queues_resumed.load(Ordering::SeqCst) {
            if !hosted {
                self.resume_restored(std::slice::from_ref(session));
            }
            // A pause this log restored mid-resume drains (`agent_pairs.rs`).
            self.resume_agent_pair_drains();
        }
    }

    /// A loaded chat's log after records its owner kept were put back (`journal_restore.rs`):
    /// read again as after a restart, so a turn the old machine was running is settled as cut
    /// and continued, and what it had queued waits here again. The caller holds `log_load`.
    /// Every projection a restart's load rebuilds from the log (`load_session_log`) is rebuilt
    /// here, but for a host to adopt (none runs for it here) and a copy's first start.
    ///
    /// The queue is rebuilt whole from the log, never merged with the one the machine had
    /// (review of #37284 at 98b4575a, F2): a prompt the restored records settled leaves it; one
    /// still waiting keeps its own entry (and the task that runs it); the restored records' own
    /// prompts (`from_copy`) go first, then the machine's, each in their order.
    pub(super) fn settle_restored(
        self: &Arc<Self>,
        session: &Arc<Session>,
        from_copy: &std::collections::HashSet<String>,
    ) {
        // What was written meanwhile is in the journal first: the queue is rebuilt from it, and
        // from what the store refused (`kept_unstored`).
        self.write_parked(session);
        #[cfg(test)]
        super::journal_restore::test_after_drain(&session.id);
        if let Err(error) = self.restore_ownership_epoch(session) {
            session.invalidate_ownership_epoch();
            tracing::warn!(session = %session.id, "ownership epoch unreadable: {error}");
        }
        self.restore_transfer_authority(session);
        let _marked = super::restore_writer::Recovering::start();
        let continued = self.mark_unknown_outcome(session, true);
        self.settle_subagent_retries(session);
        self.rebuild_queue(session, from_copy);
        self.settle_queue_changes(session, from_copy);
        self.drop_unsent_subagent_retries(session);
        super::message_events::recover_message_events(self, session);
        if let Some(prompt_id) = continued {
            let _ = self.move_queued(session, &prompt_id, 0, None);
        }
        if self.queues_resumed.load(Ordering::SeqCst) {
            self.resume_restored(std::slice::from_ref(session));
            self.resume_agent_pair_drains();
        }
    }

    /// `session`'s queue rebuilt whole from its log ([`Self::replace_queue`]).
    fn rebuild_queue(&self, session: &Arc<Session>, from_copy: &std::collections::HashSet<String>) {
        let before: Vec<super::queue::QueuedPrompt> = {
            let mut queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
            let before = std::mem::take(&mut *queue);
            session.queued.fetch_sub(before.len() as u64, Ordering::SeqCst);
            before
        };
        self.restore_queue(session);
        self.replace_queue(session, before, from_copy);
    }

    /// While a restore owns `session`: each change of its queue made since the queue was last
    /// rebuilt from the journal (an edit, a removal, a move, a hold: its record parked) goes in,
    /// and the queue is rebuilt again with it, until none came meanwhile (review of #37284 at
    /// 07f76930, F1). Each change logs its record under the queue's lock, so the rebuilt queue
    /// holds every change made before the last check, and one made after it is made on the
    /// rebuilt queue, its record kept until the restore ends. Each round needs a new change.
    fn settle_queue_changes(
        &self,
        session: &Arc<Session>,
        from_copy: &std::collections::HashSet<String>,
    ) {
        while self.queue_changed_meanwhile(session) {
            tracing::info!(session = %session.id, "the queue changed while it was rebuilt; rebuilt again with the change");
            self.write_parked(session);
            self.rebuild_queue(session, from_copy);
        }
    }

    /// After `restore_queue` rebuilt `session`'s queue from its log: each prompt that was in the
    /// queue before (`before`) and still waits keeps that entry's task and handles (so the task
    /// that runs it is the only one) and takes the rebuilt entry's content and state; each one the log settled since is withdrawn (its waiting
    /// prompt answers, and it never runs). Then `from_copy`'s prompts go first.
    fn replace_queue(
        &self,
        session: &Arc<Session>,
        mut before: Vec<super::queue::QueuedPrompt>,
        from_copy: &std::collections::HashSet<String>,
    ) {
        let order = {
            let mut queue = session.queue.lock().unwrap_or_else(|e| e.into_inner());
            let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
            let mut restored = session.restored.lock().unwrap_or_else(|e| e.into_inner());
            for q in queue.iter_mut() {
                let Some(i) = before.iter().position(|b| b.prompt_id == q.prompt_id) else {
                    continue;
                };
                // The rebuilt entry's outcome and restored marks go: the kept one has its own.
                if let Some(at) = ledger.iter().rposition(|(id, _)| *id == q.prompt_id)
                    && ledger.iter().filter(|(id, _)| *id == q.prompt_id).count() > 1
                {
                    ledger.remove(at);
                }
                if let Some(at) = restored.iter().rposition(|(id, _)| *id == q.prompt_id) {
                    restored.remove(at);
                }
                let kept = before.remove(i);
                if self.at_91b() {
                    *q = kept;
                    continue;
                }
                // The task waiting on it stays its only runner, with what it waits on; what it
                // runs and how is the log's, past an edit, a hold or an approval the restored
                // records made (review of #37284 at 91b1343d, F3).
                q.turn_id = kept.turn_id;
                q.withdraw = kept.withdraw;
                q.declined = kept.declined;
                q.joined = kept.joined;
                q.restored = kept.restored;
                q.resume = kept.resume;
            }
            let ids = |queue: &[super::queue::QueuedPrompt]| -> Vec<String> {
                queue.iter().map(|q| q.prompt_id.clone()).collect()
            };
            let old = ids(&queue);
            queue.sort_by_key(|q| !from_copy.contains(&q.prompt_id));
            let new = ids(&queue);
            (new != old).then_some(new)
        };
        for gone in before {
            tracing::info!(session = %session.id, prompt = %gone.prompt_id, "a restore settled a queued prompt; withdrawn");
            gone.withdraw.notify_one();
        }
        if let Some(order) = order {
            self.append(session, "mux", "queue_order", json!({"order": order}));
        }
        session.queue_moved.notify_waiters();
    }

    /// After adoption: every chat whose agent host ran at the start and has no agent now. Its
    /// host ended before adoption reached it (or adoption failed): it shows idle, and when its
    /// host is gone its log is read as a chat without one (a lost wait, a cut turn and its
    /// continuation), before `resume_queues` runs its queue. Its host record may be gone too, so
    /// this goes by the start's index, not by the records adoption read.
    pub(crate) async fn settle_unadopted(self: &Arc<Self>) {
        let hosted: Vec<String> = {
            let plan = self.load_plan.lock().unwrap_or_else(|e| e.into_inner());
            plan.hosted.iter().cloned().collect()
        };
        // All hosted chats were considered by adoption. Read their liveness once for this
        // settling pass, off the executor, rather than reading every host record per chat.
        // A failed read proves no host gone; keep its turn for later recovery.
        let live = tokio::task::spawn_blocking(Self::read_live_host_sessions).await.ok().flatten();
        for id in hosted {
            let Ok(session) = self.resolve(&id) else { continue };
            if session.child.lock().await.is_some() {
                continue;
            }
            let gone = live.as_ref().is_some_and(|live| !live.contains(&id));
            let hub = self.clone();
            let settled = tokio::task::spawn_blocking(move || hub.settle_one(&session, gone));
            if let Err(e) = settled.await {
                tracing::error!(session = %id, "settling a chat whose agent was not adopted failed: {e}");
            }
        }
    }

    fn settle_one(self: &Arc<Self>, session: &Arc<Session>, gone: bool) {
        let loaded = session.log_load.lock().unwrap_or_else(|e| e.into_inner());
        let _marked = super::restore_writer::Recovering::start();
        if gone {
            // From now on its log is read as any other chat's: under its load lock, so a read
            // either came before (its cut turn is settled below) or comes after this.
            self.load_plan.lock().unwrap_or_else(|e| e.into_inner()).hosted.remove(&session.id);
        }
        let waiting =
            self.load_plan.lock().unwrap_or_else(|e| e.into_inner()).waiting.contains(&session.id);
        let kept = matches!(
            session.status(),
            SessionStatus::Running | SessionStatus::Waiting | SessionStatus::Ready
        );
        if kept && gone && waiting {
            // A wait the restart cut: its `status idle` record says so (`mark_lost_wait`), now
            // or when the background pass reads its log.
            {
                let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                m.status = SessionStatus::Idle;
                // Its harness is gone: a sub-session frees its parent's width slot, under the
                // same lock as the status, as `write_status` does (`subsessions.rs`).
                if let Some(link) = &m.subsession {
                    self.subsessions.note_status(&link.started_by, &session.id, m.status);
                }
            }
            session.mark_waiting(false);
            if *loaded {
                self.mark_lost_wait(session);
            } else {
                self.save_meta(session);
            }
        } else if kept {
            self.set_status(session, SessionStatus::Idle);
            self.save_meta(session);
        }
        // A log read before adoption kept its cut turn for the host: settle it now, and queue
        // its continuation at the head (`restore_queue` adds only what it has not restored).
        if gone
            && *loaded
            && let Some(prompt_id) = self.mark_unknown_outcome(session, false)
        {
            self.restore_queue(session);
            self.drop_unsent_subagent_retries(session);
            let _ = self.move_queued(session, &prompt_id, 0, None);
        }
    }

    /// After a restart: a turn that started but never settled gets a
    /// `turn_result failed outcome_unknown`, so nobody replays a prompt that
    /// may have run to completion; its continuation is queued instead
    /// (`restart_resume.rs`). Returns the continuation's prompt id.
    ///
    /// `restored`: the log is settled after a journal restore (`journal_restore.rs`). A cut turn
    /// there whose prompt (or a message steered into it) carried a hidden context (an inline
    /// document's text, never logged) gets no continuation: one would carry only the logged
    /// text, and the owner's delivery again of that prompt id, which carries the whole prompt
    /// and its files, would be answered from the settled turn and never reach the agent (review
    /// of #37284 at 4bce04df, F1). Its `turn_result` says so ([`od::RERUN_ON_RESEND`]): the
    /// resend runs the prompt again whole, once (`logged_prompt`). A prompt whose sender never
    /// sends it again (no open delivery holds it) ends failed, as a cut turn with continuations
    /// turned off does. 4bce04df continued it with its text alone.
    ///
    /// [`od::RERUN_ON_RESEND`]: super::open_delivery::RERUN_ON_RESEND
    fn mark_unknown_outcome(&self, session: &Arc<Session>, restored: bool) -> Option<String> {
        let meta = session.meta();
        // A watched chat's open turn is the other app's, and goes on (`watch.rs`).
        if meta.watching.is_some() || meta.status == SessionStatus::Closed {
            return None;
        }
        // Scan the whole log: a long turn can stream far more records
        // than any fixed tail window after its `turn_started`.
        let mut open: Option<(u64, Value, Value, bool)> = None;
        // The turns (by id) a `user_message` with a hidden context went into: the prompt that
        // started one is logged before its `turn_started`, a steer after it.
        let mut hidden_turns: std::collections::HashSet<String> = Default::default();
        let kinds = ["turn_started", "turn_result", "user_message"];
        self.store
            .scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
                match e.kind.as_str() {
                    "turn_started" => {
                        open = Some((
                            e.seq,
                            e.msg.get("turnId").cloned().unwrap_or(Value::Null),
                            e.msg.get("promptId").cloned().unwrap_or(Value::Null),
                            e.msg.get("trigger") == Some(&Value::Bool(true)),
                        ))
                    }
                    "turn_result" => open = None,
                    "user_message" if e.msg.get("hiddenContext").is_some() => {
                        if let Some(turn) = e.msg.get("turnId").and_then(Value::as_str) {
                            hidden_turns.insert(turn.to_owned());
                        }
                    }
                    _ => {}
                }
                true
            })
            .ok()?;
        let open = open?;
        // A copy's first start: stopped, not continued (`clone_boot.rs`).
        if let Some(from) = self.clone_of() {
            self.settle_cloned_turn(session, from, open);
            return None;
        }
        let (seq, turn_id, prompt_id, trigger) = open;
        let hidden = turn_id.as_str().is_some_and(|t| hidden_turns.contains(t));
        let rerun = restored && hidden && !trigger && !self.at_4bce();
        let continued = if rerun {
            tracing::info!(session = %session.id, prompt = ?prompt_id, "a restored cut turn carried a hidden context; its prompt runs again whole when it is sent again");
            None
        } else {
            turn_id.as_str().and_then(|t| self.log_restart_continuation(session, t))
        };
        let error = if trigger {
            "the trigger turn was interrupted by a daemon restart; inspect its outcome before authorizing another delivery"
        } else if rerun {
            "this turn was cut when its machine went away; its prompt runs again whole when its sender sends it again"
        } else {
            "the daemon restarted before this turn settled"
        };
        if trigger {
            self.append(session, "mux", super::background_turn::RECORD_KIND, json!({
                "state":"ended", "id":format!("bg-trigger-{}", turn_id.as_str().unwrap_or_default()),
                "trigger":"system", "quiet":false, "reason":"exit"
            }));
        }
        let mut result = json!({"status": "failed", "detail": "outcome_unknown", "turnSeq": seq, "turnId": turn_id, "promptId":prompt_id, "trigger":trigger, "error": error, "errorText": error});
        if rerun && let Some(fields) = result.as_object_mut() {
            fields.insert(super::open_delivery::RERUN_ON_RESEND.into(), Value::Bool(true));
        }
        self.append_unknown_outcome(session, result);
        self.save_meta(session);
        continued
    }
}

/// Marks a chat's log read when its load ends, however it ends (`load_session_log`).
struct Loaded<'a>(std::sync::MutexGuard<'a, bool>, &'a AtomicBool);

impl Loaded<'_> {
    fn done(&mut self) {
        *self.0 = true;
        self.1.store(true, Ordering::SeqCst);
    }
}

impl Drop for Loaded<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            tracing::error!("reading a chat log panicked; it answers from the session list");
        }
        self.done();
    }
}

/// Ends adoption's hold on prompts to hosted chats (`session_log`) however adoption stops.
pub(crate) struct AdoptionReady<'a>(pub(crate) &'a tokio::sync::watch::Sender<bool>);

impl Drop for AdoptionReady<'_> {
    fn drop(&mut self) {
        self.0.send_replace(true);
    }
}

/// Tests: a one-shot note a thread sends when it reaches a point of the catch-up
/// (`Hub::catch_up`): a test knows from it where that thread is, with no timer.
#[cfg(test)]
pub(crate) type CatchUpNote = std::cell::RefCell<Option<std::sync::mpsc::Sender<&'static str>>>;

#[cfg(test)]
thread_local! {
    /// Tests: this thread says so, once, when its catch-up of a chat is under way (past the check
    /// that the chat is not caught up yet, before it counts the tail).
    pub(crate) static NOTE_IN_CATCH_UP: CatchUpNote = const { std::cell::RefCell::new(None) };
    /// Tests: this thread says so, once, right before its catch-up takes the chat's append lock.
    pub(crate) static NOTE_BEFORE_CATCH_UP_LOCK: CatchUpNote =
        const { std::cell::RefCell::new(None) };
    /// Tests: this thread's replay (`Hub::scan_events`) says so, once, right before it reads the
    /// log, past its catch-up or its skip of it.
    pub(crate) static NOTE_BEFORE_REPLAY_SCAN: CatchUpNote = const { std::cell::RefCell::new(None) };
}

/// Tests: sends `what` on the note in `slot`, if this thread has one, and drops the note.
#[cfg(test)]
pub(super) fn catch_up_note(slot: &'static std::thread::LocalKey<CatchUpNote>, what: &'static str) {
    if let Some(note) = slot.with(|note| note.borrow_mut().take()) {
        let _ = note.send(what);
    }
}
