//! Part of `Hub`; see `hub/mod.rs`. Putting sessions in the table: the stored list read at
//! startup, a stored session installed on its own, its log caught up, and `make_session`, which
//! every new, loaded or adopted session passes through.

use super::*;

impl Hub {
    pub(crate) fn load_from_store(self: &Arc<Self>, deferred: bool) {
        // A bounded debug seam for slow-filesystem startup tests; absent in release builds.
        #[cfg(debug_assertions)]
        if let Some(ms) = std::env::var("ACPMUX_TEST_DELAY_LOAD_STORE_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            std::thread::sleep(std::time::Duration::from_millis(ms.min(10_000)));
        }
        let Ok(mut metas) = self.store.list().inspect_err(|e| tracing::warn!("store list: {e}"))
        else {
            // Adoption still reaches every host this list hid: an off push waits for it
            // (`full_access_turned_off`).
            if deferred {
                self.adoption_ready.send_replace(false);
            }
            return;
        };
        // The small index the chat logs load by (`log_load.rs`): agent hosts still running.
        let read = Self::read_live_host_sessions();
        // Records that can not be read may hide a host whose lines adoption holds again: an off
        // push waits for adoption then too (`full_access_turned_off`).
        let unknown = read.is_none();
        let hosted = read.unwrap_or_default();
        let waiting =
            metas.iter().filter(|m| m.status == SessionStatus::Waiting).map(|m| m.id.clone());
        if deferred && (!hosted.is_empty() || unknown) {
            self.adoption_ready.send_replace(false);
        }
        {
            let mut plan = self.load_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            plan.listed = true;
            plan.waiting.extend(waiting);
            plan.adopting.extend(hosted.iter().cloned());
            plan.hosted.extend(hosted.iter().cloned());
        }
        // An older daemon's approve-all that could be vmHost's asks now (`policy_source.rs`).
        let unsaved = self.settle_legacy_grants(&mut metas);
        self.store_load.total.store(metas.len(), Ordering::SeqCst);
        // A first start with no ledger file: each session's running totals (`hub/ledger`).
        if self.ledger.wants_seed() {
            // Forks' own turns are read first, so the ledger's lock waits on no log read.
            let seeds: Vec<_> =
                metas.iter().map(|m| ledger::Seed::of(m, self.fork_own_turns(m))).collect();
            self.ledger.seed(seeds);
        }
        for meta in metas {
            let hosted = hosted.contains(&meta.id);
            let saved = !unsaved.contains(&meta.id);
            self.install_stored_session(meta, deferred, hosted, saved);
        }
        tracing::info!(
            "loaded {} sessions from store",
            self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
        );
        if deferred {
            self.logs_ready.send_replace(false);
        }
        self.resume_races();
    }

    pub(crate) fn install_stored_session(
        &self,
        meta: SessionMeta,
        deferred: bool,
        hosted: bool,
        saved: bool,
    ) {
        if let Some(session) = self.install_stored(meta, deferred, hosted, saved) {
            // A session read from the store may be another row's parent: every closed row is
            // built again, and no cursor from before it is followed (`Events::changed`), which
            // costs one barrier, not a walk of every session per session read at start.
            self.events.changed(Some(&session));
        }
    }

    /// An evicted chat back in memory (`evict.rs`): as a start reads it, but its own row alone
    /// changes. It was in the list all along, so no other row reads it anew.
    pub(crate) fn install_stored_session_quiet(&self, meta: SessionMeta) {
        if let Some(session) = self.install_stored(meta, false, false, true) {
            self.events.row_changed(&session);
        }
    }

    fn install_stored(
        &self,
        meta: SessionMeta,
        deferred: bool,
        hosted: bool,
        saved: bool,
    ) -> Option<Arc<Session>> {
        // An on-demand read may already have installed and updated this chat. Never replace it
        // with the snapshot the background list read earlier.
        let mut sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if sessions.contains_key(&meta.id) {
            return None;
        }
        let saved_meta = saved.then(|| meta.clone());
        let mut meta = meta;
        // An agent whose host still runs keeps its saved status until adoption reaches it:
        // it works on meanwhile, never shown idle (claude-sr2, 2026-10-26).
        let kept = deferred
            && hosted
            && matches!(
                meta.status,
                SessionStatus::Running | SessionStatus::Waiting | SessionStatus::Ready
            );
        if meta.status != SessionStatus::Closed && !kept {
            meta.status = SessionStatus::Idle;
        }
        // A kept Waiting loads working: the ask it waited on lives in its host, which asks it
        // again when adoption reaches it, and that ask sets it Waiting with what it asks
        // (`hosts.rs`, `Hub::set_waiting`). Until then nothing here is open to answer, and a
        // Waiting that says no reason is never shown (goal cloud-chat-waiting-always-explained).
        if kept && meta.status == SessionStatus::Waiting {
            meta.status = SessionStatus::Running;
        }
        // Every child's short name stays taken (`subsessions.rs`).
        if let Some(link) = &meta.subsession {
            self.subsessions.note_name(&link.started_by, &link.short_name);
        }
        // A live sub-session holds a slot of its parent (`subsessions.rs`). Idle-finished,
        // disconnected and closed children are retained in the store but do not use a slot.
        if let Some(link) = meta.subsession.as_ref() {
            self.subsessions.note_status(&link.started_by, &meta.id, meta.status);
        }
        let cut_off = fork_start::close_cut_off(&mut meta);
        let session = self.make_session(meta);
        if let Some(meta) = saved_meta {
            session.meta_writer.note_saved(&meta);
        }
        session.caught_up.store(false, Ordering::SeqCst);
        *session.transfer_authority.lock().unwrap_or_else(|e| e.into_inner()) = None;
        // Its log is read after the ready line (`log_load.rs`).
        *session.log_load.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = false;
        session.log_loaded.store(false, Ordering::SeqCst);
        sessions.insert(session.id.clone(), session.clone());
        drop(sessions);
        // Closed for good: the next start finds it closed and says nothing again.
        if cut_off {
            self.save_meta(&session);
        }
        self.update_live_session_index(&session);
        Some(session)
    }

    /// Wait until every chat log is read, or their load failed (immediate outside a deferred
    /// daemon start). A request for one chat waits for its own log instead (`session_log`).
    pub(crate) async fn wait_logs(&self) {
        let mut rx = self.logs_ready.subscribe();
        let _ = rx.wait_for(|ready| *ready).await;
    }

    /// Meta is saved less often than events; after a hard stop the log can be
    /// ahead of it. Counts the tail past `lastSeq` once, so no sequence is
    /// handed out twice; only that tail is read.
    pub(crate) fn catch_up(&self, session: &Session) {
        #[cfg(test)]
        log_load::catch_up_note(&log_load::NOTE_BEFORE_CATCH_UP_LOCK, "takes the append lock");
        let _order = session.append_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.catch_up_locked(session);
    }

    pub(super) fn catch_up_locked(&self, session: &Session) {
        // Once: every caller holds `append_lock`. Marked only once the tail is counted, since
        // `scan_events` reads the mark without that lock (review of #36022, finding 1).
        if session.caught_up.load(Ordering::SeqCst) {
            return;
        }
        #[cfg(test)]
        log_load::catch_up_note(&log_load::NOTE_IN_CATCH_UP, "counts the tail");
        let after =
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).harness_failures.through_seq;
        let mut results = Vec::new();
        // Under the append lock: `turn_result` is indexed, so a chat whose results are all
        // failures reads only the index copies back, not its whole log.
        let restored = self.store.scan_back_indexed(
            &session.id,
            after,
            u64::MAX,
            &|dir, kind| dir != b"mux" || kind != b"turn_result",
            &mut |record| {
                let success =
                    record.msg["status"] == "completed" && record.msg["stopReason"] != "cancelled";
                results.push(record);
                // A success settles everything before it; the bounded window settles the rest
                // (a streak older than it reads as starting at the window's oldest result).
                !success && results.len() < crate::session_liveness::RESTORE_RESULTS
            },
        );
        let rebuilt = restored.is_ok() && !results.is_empty();
        if rebuilt {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            // A result past the saved metadata is one a kill lost the save of: its summary is the
            // chat's last turn before any request reads it (every chat request waits for this
            // read, `log_load.rs`), not only once the queue resume corrects it.
            if let Some(newest) = results.first() {
                Self::correct_last_turn(&mut meta, newest);
            }
            for record in results.into_iter().rev() {
                meta.harness_failures.observe(&record.msg, record.seq, record.at);
            }
        }
        let last_seq = session.meta.lock().unwrap().last_seq;
        self.catch_up_harness_sandbox(session, last_seq);
        if let Ok((extra, last)) = self.store.tail_after(&session.id, last_seq)
            && extra > 0
        {
            // Where its own recovery at the log's end begins, read from the log: the saved one
            // is of before that tail (review of #37284 at 8b5f3063, F2). Unread, it names none,
            // and the owner compares by `lastSeq` alone.
            let recovered = self.recovery_tail(session, last).ok().flatten();
            let mut meta = session.meta.lock().unwrap();
            meta.recovered_after = recovered;
            meta.event_count += extra;
            meta.last_seq = last;
            // Whether the tail held a transcript record is not read here: say it may have.
            meta.transcript_seq = last;
            // The log ran ahead of the saved session (a hard stop): a newer command list may be
            // in that tail, so a client reads the log for it instead of trusting the saved one.
            meta.available_commands = None;
            session.seq.fetch_max(last, Ordering::SeqCst);
        }
        // What an earlier run kept while a restore held the chat, and had not stored, is kept
        // again (review of #37284 at b7496c3f, F1). Until that list reads, the chat is not
        // caught up: the next append or read tries again, and its log is not read, so no queue
        // is rebuilt without the edits and removals it holds (review of #37284 at 23e76b07, F2).
        // Then the tool output bodies a killed run held back and wrote beside the log are stored,
        // before any record of this run and before its log is read (`store/deferred.rs`).
        if !self.take_back_kept(session) || !self.take_back_held(session) {
            if rebuilt {
                self.save_meta(session);
            }
            return;
        }
        session.caught_up.store(true, Ordering::SeqCst);
        // Kept, so the next start scans only past what this one read.
        if rebuilt {
            self.save_meta(session);
        }
    }

    /// Runs `work` for each session on up to 8 threads (sessions are independent).
    pub(crate) fn on_every_core(
        &self,
        sessions: &[Arc<Session>],
        work: impl Fn(&Arc<Session>) + Sync,
    ) {
        let workers = std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 8);
        let next = std::sync::atomic::AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..workers.min(sessions.len()) {
                scope.spawn(|| {
                    while let Some(session) = sessions.get(next.fetch_add(1, Ordering::Relaxed)) {
                        work(session);
                    }
                });
            }
        });
    }

    pub(crate) fn make_session(&self, mut meta: SessionMeta) -> Arc<Session> {
        // Hibernated before a restart: marked again, so it draws no row; it wakes on its next
        // turn or typing, never on an open alone (`idle.rs` `wake_for`).
        let hibernated_at = if meta.hibernated_ms != 0 { self.clock_now().max(1) } else { 0 };
        // A Claude chat saved without `steering` (an older build) still steers once adopted.
        meta.steering |= crate::claude_stdio::steers_by_info(meta.agent_info.as_ref());
        let steering = meta.steering;
        // Until it starts, an adopted chat goes by the agent it last ran (its saved `agentInfo`).
        let backgrounds_work = crate::claude_stdio::steers_by_info(meta.agent_info.as_ref());
        // A chat that moved away stays frozen after a restart: every prompt, queue, draft and
        // policy change refuses it as while it moved (`queue::moving_error`).
        let moving =
            meta.moved_to.as_ref().map(|_| transfer_out::MOVED_AWAY.to_owned()).or_else(|| {
                // A saved Auto chat is frozen from the moment it exists: the store, not this copy,
                // says whether it is this machine's, and the holder loop frees it when it is
                // (`auto_session/runtime/run.rs` `resume`). Until then nothing runs it.
                meta.auto_session
                    .as_ref()
                    .filter(|record| record.auto)
                    .map(|_| AUTO_AWAY.to_owned())
            });
        // Every start of a session whose creator asked waits on its harness (`SessionMeta::wait_start`).
        let wait_start = meta.wait_start;
        let parent_print = views::parent_print_of(&meta);
        // A fork whose agent had not started before a restart starts as the first daemon's would.
        let (fork_from, rehydrate, rehydrate_note) = fork_start::restored(&meta);
        let session = Arc::new(Session {
            id: meta.id.clone(),
            seq: AtomicU64::new(meta.last_seq),
            book_hint: Arc::new(AtomicU64::new(meta.last_seq)),
            found_at_start: meta.last_seq,
            book_opened: Arc::default(),
            meta: StdMutex::new(meta),
            child: Mutex::new(None),
            spawn_lock: Mutex::new(()),
            fork_lock: Mutex::new(()),
            close_lock: Mutex::new(()),
            harness_use: RwLock::new(()),
            idle_refusal_logged: AtomicU64::new(0),
            append_lock: Default::default(),
            time_breakdown: StdMutex::new(Default::default()),
            meta_writer: Default::default(),
            message_ids: StdMutex::new(None),
            log_deferral: StdMutex::new(Default::default()),
            loading: AtomicBool::new(false),
            replaying: StdMutex::new(Vec::new()),
            caught_up: AtomicBool::new(true),
            log_load: StdMutex::new(true),
            log_loaded: AtomicBool::new(true),
            log_skipped: AtomicBool::new(false),
            auto_resume_restored: AtomicBool::new(false),
            protected_hold: AtomicBool::new(false),
            auto_resume: Default::default(),
            rate_hold: Default::default(),
            rate_note: Default::default(),
            turn_lock: Mutex::new(()),
            releasing: AtomicBool::new(false),
            turn_claimed: AtomicBool::new(false),
            admit: StdMutex::new(()),
            prompt_admission: Arc::new(tokio::sync::Mutex::new(())),
            restoring: AtomicBool::new(false),
            restore_done: tokio::sync::Notify::new(),
            recovery_pending: AtomicBool::new(false),
            parked: StdMutex::new(None),
            unparked: StdMutex::new(Vec::new()),
            unflushed: StdMutex::new(Vec::new()),
            kept_read: AtomicBool::new(false),
            held_read: AtomicBool::new(false),
            restore_token: AtomicU64::new(0),
            restore_lease: StdMutex::new(None),
            input_handoff: std::sync::Arc::new(Mutex::new(())),
            #[cfg(test)]
            sent_seam: Default::default(),
            turn: StdMutex::new(None),
            away: StdMutex::new(Default::default()),
            coach: Default::default(),
            queued: AtomicU64::new(0),
            queue: StdMutex::new(Vec::new()),
            prepared: StdMutex::new(std::collections::VecDeque::new()),
            prepared_done: StdMutex::new(std::collections::VecDeque::new()),
            cloud_generation: AtomicU64::new(
                std::env::var("CMUX_CLOUD_GENERATION")
                    .ok()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
            ),
            team_information: Default::default(),
            queue_moved: Notify::new(),
            moving: StdMutex::new(moving),
            ownership_epoch: AtomicU64::new(0),
            ownership_epoch_valid: AtomicBool::new(true),
            transfer_authority: StdMutex::new(Some((0, false))),
            restored: StdMutex::new(Vec::new()),
            inbox_digests: StdMutex::new(HashMap::new()),
            digest_bytes: AtomicU64::new(0),
            stream: Default::default(),
            permissions: Default::default(),
            permission_epoch: AtomicU64::new(0),
            input_since: AtomicU64::new(0),
            wait_reason: StdMutex::new(None),
            work_below_since: StdMutex::new(0),
            loop_timers: StdMutex::new(None),
            asks_below: StdMutex::new((0, 0)),
            held_messages: StdMutex::new(std::collections::VecDeque::new()),
            unread_after_work: AtomicBool::new(false),
            asks_in_flight: std::sync::atomic::AtomicUsize::new(0),
            asks_landed: Notify::new(),
            rehydrate: AtomicBool::new(rehydrate),
            resume_cut_ask: AtomicBool::new(false),
            resumed_cut: AtomicBool::new(false),
            rehydrate_note: StdMutex::new(rehydrate_note),
            forum_retell: AtomicBool::new(false),
            forum_retold: std::sync::Mutex::default(),
            forum_telling: std::sync::Mutex::default(),
            launched_with_tools: std::sync::atomic::AtomicU8::new(0),
            codex_answer: StdMutex::default(),
            codex_answer_asked: StdMutex::default(),
            launch_env: StdMutex::new(None),
            credential: StdMutex::new(None),
            route_switch: AtomicBool::new(false),
            profile_respawn: AtomicBool::new(false),
            respawn_when_quiet: AtomicBool::new(false),
            ending: StdMutex::new(None),
            detaching: AtomicBool::new(false),
            inbound: std::sync::OnceLock::new(),
            closed: tokio::sync::watch::channel(false).0,
            steering: AtomicBool::new(steering),
            backgrounds_work: AtomicBool::new(backgrounds_work),
            person: AtomicBool::new(false),
            wait_start: AtomicBool::new(wait_start),
            steer_now: Default::default(),
            steer_end: tokio::sync::watch::channel(None).0,
            fork_from: StdMutex::new(fork_from),
            applied: Default::default(),
            purged: Arc::new(AtomicBool::new(false)),
            replaced: AtomicBool::new(false),
            purging: AtomicBool::new(false),
            closing: AtomicBool::new(false),
            stops: AtomicU64::new(0),
            cancels: AtomicU64::new(0),
            claim_runs: StdMutex::new(Default::default()),
            prefetch: StdMutex::new(None),
            start_retry_wake: Notify::new(),
            start_retry_waits: AtomicBool::new(false),
            start_retry_cancels: AtomicU64::new(start_retry::NO_RETRY),
            cancel_forced_turn: StdMutex::new(None),
            unwritten_prompt: StdMutex::new(None),
            gathering: StdMutex::new(None),
            cold_batch: StdMutex::new(None),
            cold_batch_turn: AtomicBool::new(false),
            person_hold: StdMutex::new(None),
            cancel_forced_result_turn: StdMutex::new(None),
            stopping: StdMutex::new(None),
            stop_restart: StdMutex::new(None),
            stopped_agent: AtomicU64::new(0),
            stop_respawn: AtomicU64::new(0),
            taps: AtomicU64::new(0),
            muted_taps: AtomicU64::new(0),
            stop_hold: AtomicU64::new(0),
            turn_hold: AtomicU64::new(0),
            compacting: AtomicBool::new(false),
            compaction_metadata_fenced: AtomicBool::new(false),
            status_writes: AtomicU64::new(0),
            status_changes: AtomicU64::new(0),
            state_seq: AtomicU64::new(0),
            summary_gen: AtomicU64::new(0),
            parent_print: AtomicU64::new(parent_print),
            attached: std::sync::atomic::AtomicUsize::new(0),
            hidden: std::sync::atomic::AtomicUsize::new(0),
            idle: std::sync::atomic::AtomicUsize::new(0),
            turn_ended_seq: AtomicU64::new(0),
            stderr_tail: StdMutex::new(std::collections::VecDeque::new()),
            exit_line: StdMutex::new(Default::default()),
            stderr_stream: StdMutex::new(session::SessionStderr::default()),
            prompts: StdMutex::new(std::collections::VecDeque::new()),
            kept_messages: StdMutex::new(std::collections::VecDeque::new()),
            accepted_prompts: StdMutex::new(std::collections::VecDeque::new()),
            pending_acceptances: StdMutex::new(std::collections::HashMap::new()),
            accepted_seq: tokio::sync::watch::channel(0).0,
            append_errors: AtomicU64::new(0),
            last_progress: AtomicU64::new(0),
            heard: AtomicU64::new(0),
            heard_at: std::sync::atomic::AtomicI64::new(0),
            stalled_recheck: AtomicU64::new(0),
            open_tools: StdMutex::new(Default::default()),
            unclosed_tools: StdMutex::new(Default::default()),
            loop_detector: Default::default(),
            harness_sandbox_calls: StdMutex::new(Default::default()),
            stalled_counted: StdMutex::new(None),
            stalled_gen: AtomicU64::new(0),
            sign_in_refused_turn: StdMutex::new(None),
            last_model_at: AtomicU64::new(0),
            silent_turn: StdMutex::new(None),
            turn_cap_timer: StdMutex::new(None),
            inbox_state: Default::default(),
            inbox_loaded: AtomicBool::new(false),
            inbox_load: StdMutex::new(()),
            hub_ref: std::sync::OnceLock::new(),
            last_active: AtomicU64::new(self.clock_now()),
            evict_tried_at: AtomicU64::new(0),
            start_for: std::sync::atomic::AtomicU8::new(0),
            hibernated_at: AtomicU64::new(hibernated_at),
            wake_cause: StdMutex::new(None),
            policy_refusal: Default::default(),
            launch_backoff: Default::default(),
            agent_requests: std::sync::atomic::AtomicUsize::new(0),
            web_control_ended: AtomicBool::new(false),
            floor: Default::default(),
            subagents: Default::default(),
            fork_replay: Default::default(),
            harness_turn: AtomicBool::new(false),
            awaiting_reply: AtomicBool::new(false),
            logged_init: StdMutex::new(Default::default()),
            update_repeats: StdMutex::new(Default::default()),
            background_turns: Default::default(),
            processes: Default::default(),
            pr_creates: StdMutex::new(Default::default()),
            pr_closes: StdMutex::new(Default::default()),
            touch_queue: StdMutex::new(Default::default()),
            overlaps_told: StdMutex::new(Default::default()),
            start_calls: StdMutex::new(Default::default()),
            composers: StdMutex::new(Default::default()),
        });
        if let Some(hub) = self.hub_ref.get() {
            let _ = session.hub_ref.set(hub.clone());
        }
        // Found by its tags from now on (`permissions/display.rs`).
        self.child_tags.note(&session);
        // Its pull requests wait for a review verdict (`review_queue.rs`).
        self.note_session_prs(&session);
        session
    }

    /// Changes a session's metadata in place, with no record or save (tests outside the hub).
    #[cfg(test)]
    pub(crate) fn edit_test_meta(&self, session: &Session, edit: impl FnOnce(&mut SessionMeta)) {
        edit(&mut session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        // A change no record carries, as any direct metadata write is (`list_order.rs`).
        self.events.row_changed(session);
    }

    #[cfg(any(test, feature = "test-support"))]
    pub(crate) fn insert_test_session(&self, meta: SessionMeta) -> Arc<Session> {
        let id = meta.id.clone();
        let session = self.make_session(meta);
        self.sessions.lock().unwrap().insert(id, session.clone());
        self.update_live_session_index(&session);
        self.session_came(&session);
        session
    }
}
