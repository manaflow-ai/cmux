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
        self.restore_transfer_authority(session);
        let (hosted, waiting) = {
            let plan = self.load_plan.lock().unwrap_or_else(|e| e.into_inner());
            (plan.hosted.contains(&session.id), plan.waiting.contains(&session.id))
        };
        // A turn whose agent host still runs is not lost: the host is adopted. A chat closed
        // since the start waits for nothing either.
        if waiting && !hosted && session.status() != SessionStatus::Closed {
            self.mark_lost_wait(session);
        }
        let continued = if hosted { None } else { self.mark_unknown_outcome(session) };
        // A subagent retry the restart dropped, hosted or not (`subagent_retry.rs`).
        self.settle_subagent_retries(session);
        self.restore_queue(session);
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
        loaded.done();
        if self.queues_resumed.load(Ordering::SeqCst) {
            if !hosted {
                self.resume_restored(std::slice::from_ref(session));
            }
            // A pause this log restored mid-resume drains (`agent_pairs.rs`).
            self.resume_agent_pair_drains();
        }
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
            && let Some(prompt_id) = self.mark_unknown_outcome(session)
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
    fn mark_unknown_outcome(&self, session: &Arc<Session>) -> Option<String> {
        let meta = session.meta();
        // A watched chat's open turn is the other app's, and goes on (`watch.rs`).
        if meta.watching.is_some() || meta.status == SessionStatus::Closed {
            return None;
        }
        // Scan the whole log: a long turn can stream far more records
        // than any fixed tail window after its `turn_started`.
        let mut open: Option<(u64, Value)> = None;
        let kinds = ["turn_started", "turn_result"];
        self.store
            .scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
                match e.kind.as_str() {
                    "turn_started" => {
                        open = Some((e.seq, e.msg.get("turnId").cloned().unwrap_or(Value::Null)))
                    }
                    "turn_result" => open = None,
                    _ => {}
                }
                true
            })
            .ok()?;
        let (seq, turn_id) = open?;
        let continued = turn_id.as_str().and_then(|t| self.log_restart_continuation(session, t));
        let error = "the daemon restarted before this turn settled";
        self.append_unknown_outcome(session, json!({"status": "failed", "detail": "outcome_unknown", "turnSeq": seq, "turnId": turn_id, "error": error, "errorText": error}));
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
