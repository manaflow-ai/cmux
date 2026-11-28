//! `Hub::prompt` and `prompt_with`: a prompt's admission up to its run (part of `hub/turns.rs`).

use super::*;

impl Hub {
    /// Run one prompt turn. Waits for any running turn unless `steer` is set
    /// and the agent supports steering. Returns the agent's prompt response.
    pub async fn prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
    ) -> Result<Value, RpcError> {
        self.prompt_with(session, blocks, client, steer, PromptOptions::default()).await
    }

    /// `prompt` with a client prompt id and an acceptance callback. The
    /// response gains `_meta.acpmux {promptId, turnId, turnSeq}` next to the
    /// agent's own `_meta`.
    ///
    /// A client prompt id is run once: the same id again (a resend after the
    /// connection closed) answers with the first run's outcome, marked
    /// `_meta.acpmux.duplicate`, waiting for it when it is still running.
    pub async fn prompt_with(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        mut opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        let mut blocks = blocks;
        // A check that went red between turns rides the next real prompt, hidden (`verify.rs`).
        if client != "acpmux"
            && let Some(text) = super::verify::take_held(&session.id)
        {
            blocks.push(
                json!({"type": "text", "text": text, "_meta": {"acpmux": {"context": true}}}),
            );
        }
        // A budget notice that asked nothing now rides the next prompt, hidden
        // (`session_budget_watch.rs`).
        if let Some(text) = super::session_budget_watch::take_held(&session.id) {
            blocks.push(
                json!({"type": "text", "text": text, "_meta": {"acpmux": {"context": true}}}),
            );
        }
        // A deferred start reads the queues after its ready line: a new prompt waits for its
        // chat's, so it never runs ahead of a prompt queued under the previous daemon, nor ahead
        // of a turn adoption recovers.
        // Read this log now, ahead of queued background loads, while keeping the prompt
        // behind adoption's recovered turn below.
        self.session_log(session).await;
        self.wait_adopted(session).await;
        // A chat a past capacity switch left on a smaller model runs this prompt on its own one
        // while switching is off (`auto_resume/capacity_failover.rs`).
        self.restore_capacity_fallback_if_off(session).await;
        // An Auto chat another holder runs takes the prompt through its Cloud inbox
        // (`auto_hold.rs`); nothing starts here.
        if self.auto_held(session) {
            // Only the prompt's id goes across the wait: the options hold what no other thread
            // may. On the heap (`heap_future.rs`): a prompt is polled deep in a worker's stack.
            let away_id = opts.prompt_id.clone();
            let away = crate::heap_future::heap(|| {
                self.auto_away_prompt(session, &blocks, client, away_id.as_deref())
            });
            if let Some(answer) = away.await {
                return answer;
            }
        }
        // A watched Claude chat whose app still runs it takes the prompt into that app (`bridge.rs`).
        if let Some(answer) = self.bridged_prompt(session, &blocks, client, &mut opts).await {
            return answer;
        }
        // A prompt the daemon sends for a session (a workflow's step, its nudge) names that
        // session: with no provenance its record would read as the person's own.
        if opts.provenance.is_none()
            && let Some(agent) = opts.agent.as_deref()
        {
            opts.provenance = Some(match self.resolve(agent).ok().filter(|s| s.id == agent) {
                Some(from) => crate::prompt_provenance::session_message(
                    &from.id,
                    &self.session_name(&from.id),
                    &session.id,
                ),
                None => crate::prompt_provenance::named_sender(agent, &session.id),
            });
        }
        self.pair_logs(opts.provenance.as_ref()).await;
        // Opt-in usage patterns: a prompt (or steer) on this harness; never its text.
        if cmux_usage_patterns::enabled() {
            let harness = session.meta.lock().unwrap_or_else(|e| e.into_inner()).harness.clone();
            cmux_usage_patterns::count(
                if steer { "agent-steer" } else { "agent-prompt" },
                &harness,
            );
        }
        // A person's own prompt is the person asking for the chat: what a daemon start held in
        // its protected folder goes on, ahead of this prompt (`protected_hold.rs`). Not the
        // owner's terminal send, which no connection proved (`PromptOptions::unproven_owner`).
        if opts.agent.is_none()
            && opts.provenance.is_none()
            && opts.after_turn.is_none()
            && !opts.unproven_owner
        {
            self.release_protected_hold(session);
        }
        // The person's own prompt, proven by its connection, lifts a hold (`session_hold.rs`).
        if opts.human_authenticated && opts.after_turn.is_none() {
            self.release_session_hold_for_person(session);
        }
        let Some(prompt_id) = opts.prompt_id.clone() else {
            // `session/prompt` accepts prompts without a client id.  They still need a
            // durable message id when they came from another session, so wrap the
            // acceptance callback with a generated id without adding a prompt ledger
            // entry (the ledger is only for client-supplied idempotency keys).
            let generated_id = uuid::Uuid::now_v7().to_string();
            opts.prompt_id = Some(generated_id.clone());
            if let Some(text) = opts.coach.take() {
                self.coach_prompt(session, &generated_id, &text);
            }
            ensure_message_provenance(&mut opts, &session.id);
            let message = message_context(self, session, &blocks, &opts, &generated_id);
            embed_message_context(&mut opts, message.as_ref(), &session.id);
            let target_id = session.id.clone();
            let hub = self.clone();
            let prior = opts.on_accepted.take();
            opts.on_accepted = Some(Box::new(move |mut v| {
                if let Some(message) = message.as_ref() {
                    record_message_context(&hub, &target_id, message, &v);
                    name_message(&mut v, message);
                }
                if let Some(prior) = prior {
                    prior(v);
                }
            }));
            return self.prompt_unless_held(session, blocks, client, steer, opts).await;
        };
        let duplicate = |v: Value| {
            let mut answer = json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true, "queued": false, "turnId": v.pointer("/_meta/acpmux/turnId")});
            if v.pointer("/_meta/acpmux/surgeHeld").and_then(Value::as_bool) == Some(true) {
                let thread = v.pointer("/_meta/acpmux/threadId").cloned().unwrap_or(Value::Null);
                crate::surge_triage::set_key(&mut answer, "inbox", json!(true));
                crate::surge_triage::set_key(&mut answer, "surgeHeld", json!(true));
                crate::surge_triage::set_key(&mut answer, "threadId", thread);
            }
            name_kept_message(&mut answer, session, &prompt_id);
            answer
        };
        let seen = begin_outcome(session, &prompt_id);
        let outcome = match seen {
            Err((token, mut first)) => {
                // A copy never reaches the queue: it lets the chat's prompt admission go
                // (#52381) before it waits for the first run. Held, it kept every later prompt
                // of the chat from its queue for the whole first run, and that run's own queue
                // never moved on (a burst of doubled sends answered none of them).
                if let Some(admission) = opts.admission.take() {
                    admission.release();
                }
                if let Some(f) = opts.on_accepted.take() {
                    // The first run's acceptance, once it was accepted: its queue place, its
                    // turn or its inbox receipt. Not yet: this copy waits for it (or for the
                    // first run's end), so it never answers "taken, no turn" for a run that may
                    // yet be refused, nor waits out a whole inbox message's answer (an outbox
                    // retry did, every 120 s, forever: 2026-11-25).
                    if let Some(kept) =
                        Box::pin(first_acceptance(session, &prompt_id, token, &mut first)).await
                    {
                        let mut notice = duplicate(json!({"_meta": {"acpmux": {
                            "turnId": kept.get("turnId"),
                            "surgeHeld": kept.get("surgeHeld"),
                            "threadId": kept.get("threadId"),
                        }}}));
                        for key in ["queued", "inbox", "sessionHeld", "held"] {
                            if let Some(v) = kept.get(key) {
                                notice.set(key, v.clone());
                            }
                        }
                        f(notice);
                        let dropped =
                            || RpcError::internal("the first run of this prompt was dropped");
                        let result = first
                            .wait_for(Option::is_some)
                            .await
                            .map_err(|_| dropped())?
                            .clone()
                            .unwrap_or_else(|| Err(dropped()));
                        return result.map(|mut v| {
                            merge_mux_meta(&mut v, json!({"duplicate": true}));
                            v
                        });
                    }
                    // The first run ended unaccepted (refused) or is gone: as before, its
                    // answer says.
                    let (turn, queued) = pending_turn(session, &prompt_id).unzip();
                    let previous = first
                        .borrow()
                        .as_ref()
                        .and_then(|r| r.as_ref().ok())
                        .filter(|v| {
                            v.pointer("/_meta/acpmux/surgeHeld").and_then(Value::as_bool)
                                == Some(true)
                        })
                        .cloned();
                    let mut notice = duplicate(
                        previous.unwrap_or_else(|| json!({"_meta": {"acpmux": {"turnId": turn}}})),
                    );
                    if queued == Some(true) {
                        notice.set("queued", json!(true));
                    }
                    f(notice);
                }
                let result = first
                    .wait_for(Option::is_some)
                    .await
                    .map_err(|_| RpcError::internal("the first run of this prompt was dropped"))?
                    .clone()
                    .expect("waited for an outcome");
                return result.map(|mut v| {
                    merge_mux_meta(&mut v, json!({"duplicate": true}));
                    v
                });
            }
            Ok(outcome) => outcome,
        };
        // A client's resend of this id was answered above: the coach counts the prompt once.
        if let Some(text) = opts.coach.take() {
            self.coach_prompt(session, &prompt_id, &text);
        }
        // A chat that moved here (a Mac-first turn handed to its Cloud machine) reads its log
        // for every client prompt id, as a resend does: the turn the other host ran is answered
        // from its record, never run again (`moved_prompt_fence.rs`).
        let resend = opts.resend || super::moved_prompt_fence::reads_log(session);
        // A resent inbox message answers as its notice did, a failure as the same error.
        // A resend reads the chat's indexed records (a whole kind index, hashed): off the
        // workers, as Leo's daemon had two workers busy in it for a whole sample (2026-11-22).
        if resend
            && let Some(answer) =
                crate::qos::off_worker(|| self.logged_inbox_answer(session, &prompt_id))
        {
            if let Some(f) = opts.on_accepted.take() {
                f(duplicate(answer.clone().unwrap_or(Value::Null)));
            }
            let mut ledger = session.prompts.lock().unwrap();
            outcome.send_replace(Some(answer.clone()));
            release_acceptance(session, &prompt_id, &outcome);
            prompt_ledger::prune(&mut ledger);
            return answer;
        }
        if resend
            && let Some(logged) =
                crate::qos::off_worker(|| self.logged_prompt_past_inbox(session, &prompt_id))
        {
            if let Some(f) = opts.on_accepted.take() {
                let value = match &logged {
                    Ok(value) => value.clone(),
                    Err(error) => json!({"_meta": {"acpmux": {
                        "turnId": error.data.as_ref().and_then(|d| d.get("turnId"))
                    }}}),
                };
                f(duplicate(value));
            }
            let mut ledger = session.prompts.lock().unwrap();
            outcome.send_replace(Some(logged.clone()));
            release_acceptance(session, &prompt_id, &outcome);
            prompt_ledger::prune(&mut ledger);
            return logged;
        }
        // Message events are acknowledged at the same point as the prompt. This covers direct
        // sends and automatic lane reports, both of which can call `prompt_with` without passing
        // through the RPC request handler. A duplicate or a refused prompt never records a new
        // event.
        ensure_message_provenance(&mut opts, &session.id);
        let message = message_context(self, session, &blocks, &opts, &prompt_id);
        embed_message_context(&mut opts, message.as_ref(), &session.id);
        // Remember the outcome only for a prompt that reached the session:
        // one refused before that (no agent, a bad session) may be sent again.
        let accepted = Arc::new(AtomicBool::new(false));
        if let Some(f) = opts.on_accepted.take() {
            let accepted = accepted.clone();
            let hub = self.clone();
            let target_id = session.id.clone();
            let (kept_in, kept_id) = (session.clone(), prompt_id.clone());
            opts.on_accepted = Some(Box::new(move |mut v| {
                accepted.store(true, Ordering::SeqCst);
                if let Some(message) = message.as_ref() {
                    record_message_context(&hub, &target_id, message, &v);
                    keep_message(&kept_in, &kept_id, message);
                    name_message(&mut v, message);
                }
                keep_acceptance(&kept_in, &kept_id, &v);
                f(v);
            }));
        } else {
            let accepted = accepted.clone();
            let hub = self.clone();
            let target_id = session.id.clone();
            let (kept_in, kept_id) = (session.clone(), prompt_id.clone());
            opts.on_accepted = Some(Box::new(move |v| {
                accepted.store(true, Ordering::SeqCst);
                if let Some(message) = message.as_ref() {
                    record_message_context(&hub, &target_id, message, &v);
                    keep_message(&kept_in, &kept_id, message);
                }
                keep_acceptance(&kept_in, &kept_id, &v);
            }));
        }
        let result = self.prompt_unless_held(session, blocks, client, steer, opts).await;
        let mut ledger = session.prompts.lock().unwrap();
        if !accepted.load(Ordering::SeqCst) {
            ledger.retain(|(id, _)| *id != prompt_id);
        }
        outcome.send_replace(Some(result.clone()));
        release_acceptance(session, &prompt_id, &outcome);
        prompt_ledger::prune(&mut ledger);
        result
    }
}
