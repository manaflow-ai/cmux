//! Part of `Hub`; see `hub/mod.rs`.

use super::exit_reason::explains_exit;
use super::*;
use std::sync::atomic::Ordering;
use std::time::Duration;

use super::message_events::{
    embed_message_context, ensure_message_provenance, message_context, name_message,
    record_message_context,
};

/// What the agent of `session` is sent for `blocks`: model-sized copies of its large images
/// (`model_copies.rs`), then [`acp_prompt_blocks`]. No copy is made, or kept, for a turn a remote
/// device controls: it is read from this machine's disk as the prompt's sender, who was local.
pub(super) async fn agent_blocks(
    hub: &Hub,
    session: &Session,
    blocks: &[Value],
) -> Result<Vec<Value>, RpcError> {
    let web = || session.turn().is_some_and(|t| t.control == Control::Web);
    if web() {
        return acp_prompt_blocks(session, blocks);
    }
    let family = session.meta().family;
    let copied = crate::model_copies::add(&session.id, family.as_deref(), blocks).await;
    // Tests only: a Stop or a remote device comes while the copies are made.
    #[cfg(test)]
    {
        let seam = hub.copy_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some((arrived, release)) = seam {
            let _ = arrived.send(());
            let _ = release.await;
        }
    }
    #[cfg(not(test))]
    let _ = hub;
    acp_prompt_blocks(session, if web() { blocks } else { &copied })
}

/// A prompt not written to its agent: a Stop came while its model-sized copies were made, or
/// while its agent started.
pub(super) fn stopped_before_prompt() -> RpcError {
    RpcError::new(-32000, "the turn was stopped before this prompt reached the agent")
        .with_data(json!({"reason": "stopped"}))
}

/// Whether `e` is [`stopped_before_prompt`]: the turn it ends is the Stop's, cancelled, not failed.
fn is_stopped_before_prompt(e: &RpcError) -> bool {
    e.data.as_ref().is_some_and(|d| d.get("reason").and_then(Value::as_str) == Some("stopped"))
}

/// What a turn a Stop ended before its prompt reached the agent answers in its `turn_result`.
fn stopped_answer() -> Value {
    json!({"stopReason": "cancelled"})
}

/// ACP v1 does not define a `document` content block. Claude's translator can
/// turn our internal document block into Anthropic's native document. Strict
/// ACP adapters (including Codex) instead get a stable workspace file and a
/// resource link, plus a short note telling the agent where to open it.
pub(super) fn acp_prompt_blocks(
    session: &Session,
    blocks: &[Value],
) -> Result<Vec<Value>, RpcError> {
    let is_claude = session.meta().family.as_deref() == Some("claude");
    let mut out = Vec::with_capacity(blocks.len());
    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("document") || is_claude {
            out.push(block.clone());
            continue;
        }
        let name = block.get("name").and_then(Value::as_str).unwrap_or("document.pdf");
        let safe_name: String = name
            .chars()
            .map(
                |c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '_' },
            )
            .collect();
        let safe_name = if safe_name.is_empty() { "document.pdf" } else { &safe_name };
        let dir = session.meta().cwd.join(".cmux").join("attachments");
        std::fs::create_dir_all(&dir).map_err(|e| {
            RpcError::internal(format!("cannot create PDF attachment directory: {e}"))
        })?;
        // The folder sits in the user's project; keep it out of their commits.
        let ignore = dir.join(".gitignore");
        if !ignore.exists() {
            let _ = std::fs::write(&ignore, "*\n");
        }
        let path = dir.join(format!("{}-{safe_name}", uuid::Uuid::now_v7()));
        let encoded = block.get("data").and_then(Value::as_str).unwrap_or("");
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|e| RpcError::invalid_params(format!("invalid PDF attachment: {e}")))?;
        std::fs::write(&path, bytes)
            .map_err(|e| RpcError::internal(format!("cannot save PDF attachment: {e}")))?;
        let uri = file_uri(&path);
        out.push(json!({
            "type": "text",
            "text": format!("PDF attachment saved at {}; open it with your tools.", path.display())
        }));
        out.push(json!({
            "type": "resource_link",
            "uri": uri,
            "name": name,
            "mimeType": "application/pdf"
        }));
    }
    Ok(out)
}

/// A `file://` URI for the saved file, percent-encoded so a project folder with
/// spaces or non-ASCII letters still names a valid link (and a Windows path
/// gets its drive form).
fn file_uri(path: &std::path::Path) -> String {
    reqwest::Url::from_file_path(path)
        .map(String::from)
        .unwrap_or_else(|()| format!("file://{}", path.display()))
}

impl Hub {
    // --------------------------------------------------------------- turns

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
        // A deferred start reads the queues after its ready line: a new prompt waits for its
        // chat's, so it never runs ahead of a prompt queued under the previous daemon, nor ahead
        // of a turn adoption recovers.
        // Read this log now, ahead of queued background loads, while keeping the prompt
        // behind adoption's recovered turn below.
        self.session_log(session).await;
        self.wait_adopted(session).await;
        self.pair_logs(opts.provenance.as_ref()).await;
        // A person's own prompt is the person asking for the chat: what a daemon start held in
        // its protected folder goes on, ahead of this prompt (`protected_hold.rs`).
        if opts.agent.is_none() && opts.provenance.is_none() && opts.after_turn.is_none() {
            self.release_protected_hold(session);
        }
        let Some(prompt_id) = opts.prompt_id.clone() else {
            // `session/prompt` accepts prompts without a client id.  They still need a
            // durable message id when they came from another session, so wrap the
            // acceptance callback with a generated id without adding a prompt ledger
            // entry (the ledger is only for client-supplied idempotency keys).
            let generated_id = uuid::Uuid::now_v7().to_string();
            opts.prompt_id = Some(generated_id.clone());
            ensure_message_provenance(&mut opts, &session.id);
            let message = message_context(self, session, &blocks, &opts, &generated_id);
            embed_message_context(&mut opts, message.as_ref(), &session.id);
            let target_id = session.id.clone();
            let hub = self.clone();
            let prior = opts.on_accepted.take();
            opts.on_accepted = Some(Box::new(move |mut v| {
                if let Some(message) = message.as_ref() {
                    record_message_context(&hub, &target_id, message);
                    name_message(&mut v, message);
                }
                if let Some(prior) = prior {
                    prior(v);
                }
            }));
            return self.prompt_unless_held(session, blocks, client, steer, opts).await;
        };
        let duplicate = |v: Value| json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true, "queued": false, "turnId": v.pointer("/_meta/acpmux/turnId")});
        let seen = {
            let mut ledger = session.prompts.lock().unwrap();
            match ledger.iter().find(|(id, _)| *id == prompt_id) {
                Some((_, outcome)) => Err(outcome.subscribe()),
                None => {
                    let outcome = Arc::new(tokio::sync::watch::channel(None).0);
                    ledger.push_back((prompt_id.clone(), outcome.clone()));
                    Ok(outcome)
                }
            }
        };
        let outcome = match seen {
            Err(mut first) => {
                if let Some(f) = opts.on_accepted.take() {
                    f(duplicate(Value::Null));
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
        // A resent inbox message answers as its notice did, a failure as the same error.
        if opts.resend
            && let Some(answer) = self.logged_inbox_answer(session, &prompt_id)
        {
            if let Some(f) = opts.on_accepted.take() {
                f(duplicate(answer.clone().unwrap_or(Value::Null)));
            }
            let mut ledger = session.prompts.lock().unwrap();
            outcome.send_replace(Some(answer.clone()));
            prompt_ledger::prune(&mut ledger);
            return answer;
        }
        if opts.resend
            && let Some(logged) = self.logged_prompt(session, &prompt_id)
        {
            if let Some(f) = opts.on_accepted.take() {
                f(duplicate(logged.clone()));
            }
            let mut ledger = session.prompts.lock().unwrap();
            outcome.send_replace(Some(Ok(logged.clone())));
            prompt_ledger::prune(&mut ledger);
            return Ok(logged);
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
            opts.on_accepted = Some(Box::new(move |mut v| {
                accepted.store(true, Ordering::SeqCst);
                if let Some(message) = message.as_ref() {
                    record_message_context(&hub, &target_id, message);
                    name_message(&mut v, message);
                }
                f(v);
            }));
        } else {
            let accepted = accepted.clone();
            let hub = self.clone();
            let target_id = session.id.clone();
            opts.on_accepted = Some(Box::new(move |_| {
                accepted.store(true, Ordering::SeqCst);
                if let Some(message) = message.as_ref() {
                    record_message_context(&hub, &target_id, message);
                }
            }));
        }
        let result = self.prompt_unless_held(session, blocks, client, steer, opts).await;
        let mut ledger = session.prompts.lock().unwrap();
        if !accepted.load(Ordering::SeqCst) {
            ledger.retain(|(id, _)| *id != prompt_id);
        }
        outcome.send_replace(Some(result.clone()));
        prompt_ledger::prune(&mut ledger);
        result
    }

    pub(super) async fn run_prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        opts: PromptOptions,
    ) -> Result<Value, RpcError> {
        // The agent messages that go in with this one (`digest.rs`) answer with its answer, or
        // wait again when it failed.
        let joined = super::digest::DigestTurn::default();
        // On the heap: a prompt's whole turn is a large future, and a caller that awaits it in
        // place (a test, `steer_queued`'s steer that falls back to a turn) would hold it on its
        // stack; debug builds overflowed a 2 MB test thread with it.
        let result =
            Box::pin(self.run_prompt_joined(session, blocks, client, steer, opts, &joined)).await;
        // `finish_turn` put them back already when the turn itself failed, and a turn that never
        // reached its agent put them back unheld (`fail_unstarted_turn`); this is any other way.
        if result.is_err() {
            self.requeue_joined(session, &joined, true);
        }
        joined.answer.send_replace(Some(result.clone()));
        result
    }

    async fn finish_cloud_execution(
        cloud_exec: &mut Option<(
            crate::cloud_rewind::CloudTurnClient,
            crate::cloud_rewind::TurnScope,
        )>,
        session: &Session,
        turn_id: &str,
    ) {
        if let Some((cloud, scope)) = cloud_exec.take() {
            let session_id = session.id.clone();
            let turn_id = turn_id.to_owned();
            tokio::spawn(async move {
                let mut delay = Duration::from_millis(100);
                let mut attempts = 0u64;
                loop {
                    match cloud.finish_execution(&scope).await {
                        Ok(_) => break,
                        Err(error) => {
                            attempts += 1;
                            if attempts == 1 || attempts.is_power_of_two() {
                                tracing::warn!(session = %session_id, turn = %turn_id, attempts, "cloud turn finish pending: {error}");
                            }
                            tokio::time::sleep(delay).await;
                            delay = (delay * 2).min(Duration::from_secs(30));
                        }
                    }
                }
            });
        }
    }

    async fn run_prompt_joined(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        mut opts: PromptOptions,
        joined: &super::digest::DigestTurn,
    ) -> Result<Value, RpcError> {
        // Stop can arrive during dispatch setup, before session.turn is installed. Keep
        // that epoch through the write checks instead of sampling it after startup.
        let mut cancels = session.cancels.load(Ordering::SeqCst);
        let prompt_id = opts.prompt_id.unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        // A held agent message released, or a queued one sent now, may still name its uploads.
        let mut blocks = blocks;
        let web = opts.control == Control::Web;
        crate::prompt_uploads::resolve_off_runtime(&session.id, web, &mut blocks).await?;
        // A stop after this prompt came ends the agent start it waits on (`ensure_child`).
        let stops = session.stops.load(Ordering::SeqCst);
        let control = opts.control;
        let trust_gate = opts.trust_gate;
        let no_queue = opts.no_queue;
        let cloud_turn = opts.cloud_turn.clone();
        if let Some(envelope) = cloud_turn.as_ref() {
            if envelope.purpose != "execute"
                || envelope.session != session.id
                || envelope.turn != prompt_id
            {
                return Err(RpcError::invalid_params("cloud execution does not match this prompt"));
            }
            session
                .validate_prepared(
                    &prompt_id,
                    &envelope.turn,
                    envelope.generation,
                    &envelope.attempt_id,
                    None,
                )
                .map_err(|e| RpcError::invalid_params(e.to_string()))?;
        }
        let mut on_accepted = self.with_host_pressure(opts.on_accepted);
        // The prompts this one replaced (`supersede.rs`), named in its acceptance: set where it
        // is committed (queued, started, or steered in), never before a refusal.
        let supersede = opts.supersede.clone();
        let replaced = std::sync::OnceLock::<Vec<String>>::new();
        // Another agent's message queued as the running turn crosses its cap still gets the
        // turn its notice (`turn_cap.rs`): the timer may have looked at the queue just before.
        let from_agent =
            super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref()).is_some()
                && !opts.send_now;
        let mut accept = |mut v: Value| {
            if let Some(f) = on_accepted.take() {
                if supersede.is_some() {
                    super::queue::supersede::mark(&mut v, replaced.get());
                }
                let queued = v.get("queued") == Some(&Value::Bool(true));
                f(v);
                if queued && from_agent {
                    self.turn_cap_recheck(session);
                }
            }
        };
        // A prompt that cannot reach any agent (none running, and its folder or harness is gone)
        // is refused before it is recorded (`cold_prompt_check`, after steer-only's refusal).
        let live = match session.child.lock().await.as_ref() {
            Some(child) => child.is_alive().await,
            None => false,
        };
        let text = prompt_text(&blocks);
        let running = session.turn();
        // Another agent's message to a turn past its cap waits for the next turn (`turn_cap.rs`).
        let capped = running.is_some()
            && !opts.send_now
            && self.turn_cap_holds(session, opts.provenance.as_ref(), opts.agent.as_deref());
        // Another agent's message goes into the chat's inbox, never a turn or a steer of its own
        // (`inbox.rs`). Boxed, out of this future.
        let route = self.inbox_route(
            session,
            &prompt_id,
            &blocks,
            control,
            opts.send_now,
            opts.class,
            opts.provenance.as_ref(),
            opts.agent.as_deref(),
            opts.inbox,
        );
        // Held until this prompt ends: its turn, or its refusal (`inbox.rs`).
        let first_work = match route {
            super::inbox::Route::First(first) => Some(first),
            super::inbox::Route::Plain => None,
            super::inbox::Route::Inbox(agent, class) => {
                return Box::pin(self.inbox_accept(
                    session,
                    &blocks,
                    client,
                    &prompt_id,
                    &agent,
                    class,
                    opts.thread.as_deref(),
                    opts.provenance.as_ref(),
                    &mut accept,
                ))
                .await;
            }
        };
        // A first work says so in its provenance, which its queue entry keeps across a restart
        // (`queue.rs`): its sender is the delegator whichever turn it runs as.
        if first_work.is_some()
            && let Some(p) = opts.provenance.as_mut().and_then(Value::as_object_mut)
        {
            p.insert(super::inbox::FIRST_WORK.to_owned(), Value::Bool(true));
        }
        #[cfg(test)]
        if first_work.is_some() {
            let seam = self.first_work_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // An inbox notice steers in only while the turn is under its cap and no prompt waits
        // (`inbox.rs`), checked again here at dispatch.
        let notice_held = steer
            && running.is_some()
            && super::inbox::is_notice(opts.provenance.as_ref())
            && super::inbox::notice_held(session);
        // A review box's turn takes no other agent's steer: its message waits behind the review,
        // as the inbox leaves it (`inbox.rs`). The person's own steer and Send now still go in.
        // Read with or without a running turn: one that starts before this reaches the queue is
        // stopped by no agent's interrupt either.
        let review_held = from_agent && super::inbox::review_box(session);
        // Nor does another agent's steer go in while one of the person's prompts waits behind the
        // running turn, as no notice does (`inbox.rs`): it kept that turn going past the person's
        // queued prompt (Leo, 2026-10-29: "but even if im just queueing, your turn should still be
        // ending"). It queues behind the prompt, and one sent with `interrupt` stops nothing. The
        // person's own steer and Send now still go in, and so does an inbox digest asked to steer
        // (`inbox_digest.rs`): its drain asked for it. Checked again as the steer is written
        // (`steer_end.rs`).
        let prompt_held = from_agent
            && running.is_some()
            && !super::digest::inbox_digest::is_digest(opts.provenance.as_ref())
            && super::inbox::persons_prompt_waits(session);
        // Other agents wait until the person's own turn ends; family replies still enter it.
        let persons_held = from_agent
            && running.as_ref().is_some_and(|t| t.persons)
            && !super::digest::inbox_digest::is_digest(opts.provenance.as_ref())
            && !super::subsession_guard::is_family_prompt(opts.provenance.as_ref());
        let trigger = crate::prompt_provenance::is_trigger(opts.provenance.as_ref());
        let trigger_held = trigger || running.as_ref().is_some_and(|t| t.trigger);
        let steer_now = steer
            && !trigger_held
            && session.steering.load(Ordering::SeqCst)
            && running.is_some()
            && !capped
            && !notice_held
            && !review_held
            && !prompt_held
            && !persons_held;
        if steer && opts.steer_only && !steer_now {
            if review_held && running.is_some() {
                return Err(super::inbox::review_box_steer_refused());
            }
            if prompt_held && !capped {
                return Err(super::inbox::prompt_waits_steer_refused());
            }
            if persons_held && !capped {
                return Err(super::inbox::persons_turn_steer_refused());
            }
            return Err(super::turn_cap::steer_unavailable(capped));
        }
        if !live {
            self.cold_prompt_check(session).await?;
        }
        if steer_now && session.moving().is_some() {
            return Err(super::queue::moving_error());
        }
        // Who sent it, as the queue knows its prompts' senders (`digest.rs`).
        let agent = super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref());
        // What it asks of this chat: another agent's only, `result` when it named none.
        let class = crate::prompt_class::of_message(opts.class, agent.is_some());
        if steer_now {
            if cloud_turn.is_some() {
                return Err(RpcError::invalid_params(
                    "a captured cloud turn cannot steer another turn",
                ));
            }
            let turn_id = running.map(|t| t.turn_id).unwrap_or_default();
            let opts = PromptOptions { prompt_id: Some(prompt_id), on_accepted: None, ..opts };
            // Boxed: the steer's future stays out of this one, which every prompt's caller holds
            // on its stack (a debug build's test thread has little room).
            return Box::pin(self.steer_turn(session, blocks, client, &turn_id, opts, &mut accept))
                .await;
        }
        // An automatic continuation runs only while its chat still ends on the cut turn: no await
        // from here to `queue_slot`'s choice, so it never joins the queue (`auto_resume.rs`).
        let after_turn = opts.after_turn.clone();
        super::auto_resume::check_cut(session, after_turn.as_deref(), false)?;
        // Queued behind the running turn (and the queue) it waits for its turn (`queue.rs`).
        let slot = super::queue::Slot {
            text: &text,
            blocks: &blocks,
            display_parts: opts.display_parts.as_ref(),
            client,
            prompt_id: &prompt_id,
            control,
            trust_gate,
            // Held past the cap, it waits: it stops no turn (`turn_cap.rs`); nor does another
            // agent's message stop a review box's review, or go ahead of the person's prompt that
            // waits (`inbox.rs`).
            interrupt: opts.interrupt && !capped && !review_held && !prompt_held && !persons_held,
            interrupt_turn: opts.interrupt_turn.as_deref(),
            provenance: opts.provenance.as_ref(),
            agent: agent.as_deref(),
            class,
            supersede: supersede.as_deref(),
            full_access_device: opts.full_access_device.as_deref(),
            replaced: &replaced,
            no_queue: opts.no_queue,
            admitted: opts.admitted,
            after_turn: after_turn.is_some(),
        };
        let (turn_id, waiting, mut guard, run) =
            match self.queue_slot(session, slot, &mut accept).await {
                Ok(slot) => slot,
                Err(done) => return done,
            };
        // A normal Stop releases the next queued prompt. Its cancellation epoch starts
        // when it acquires the turn; an immediately admitted prompt keeps its entry epoch.
        if waiting {
            cancels = session.cancels.load(Ordering::SeqCst);
        }
        #[cfg(test)]
        {
            let seam = self.prompt_start_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // Debug builds only: a test stops the daemon between a queued prompt's `dequeued` and
        // its turn (`durable_agents.rs`). Release builds have no seam.
        #[cfg(debug_assertions)]
        if waiting && std::env::var_os("ACPMUX_TEST_EXIT_AFTER_DEQUEUE").is_some() {
            // crash-allow: debug-build test seam; the test asks for this stop, like a crash
            std::process::exit(0);
        }
        // A prompt that took the turn lock first (a person's) supersedes the continuation.
        if let Err(e) = super::auto_resume::check_cut(session, after_turn.as_deref(), waiting) {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        // What its queue entry holds now (`queue_edit.rs` may edit a prompt that waited).
        let (mut blocks, control, trust_gate) = (run.blocks.clone(), run.control, run.trust_gate);
        // A queued prompt restored from the log may still name its uploads (`prompt_uploads.rs`).
        let web = control == Control::Web;
        let read = crate::prompt_uploads::resolve_off_runtime(&session.id, web, &mut blocks).await;
        if let Err(e) = read {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        let device = run.full_access_device.clone();
        let mut display_parts = run.display_parts.clone();
        // A pushed forum rule whose key moved on while it waited tells the current one.
        let mut provenance = run.provenance.clone();
        let pushed = self.forum_refresh_push(&prompt_id, &mut blocks, &mut provenance);
        if let Err(e) = self
            .check_dispatch(
                session,
                control,
                trust_gate,
                device.as_deref(),
                &prompt_id,
                &turn_id,
                client,
            )
            .await
        {
            drop(guard);
            return Err(e);
        }
        // A family prompt that waited is checked again: the receiver may ask
        // less than its sender now (`subsession_guard.rs`).
        let bound = self.mdm_snapshot();
        if let Err(e) = self.family_dispatch_check(session, run.provenance.as_ref(), bound).await {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        let text = prompt_text(&blocks);
        // A subagent retry waits out Claude Code's own turn (`subagent_retry.rs`); a person's
        // never waits: `start_turn` refuses it then.
        if !no_queue {
            self.hold_retry_start(session, &prompt_id).await;
        }
        if session.cancels.load(Ordering::SeqCst) != cancels {
            // A continuation or retry of a cut turn is refused as one Stop overtook
            // (`auto_resume.stopped`): its callers answer `retry.stopped` and record the skip.
            let e = if after_turn.is_some() {
                super::auto_resume::stopped()
            } else {
                stopped_before_prompt()
            };
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        // A continuation Stop overtook since it fired is refused here (`auto_resume.rs`).
        // Another agent's message shows as its sender and words (`prompt_line.rs`).
        let trigger = crate::prompt_provenance::is_trigger(run.provenance.as_ref());
        let persons = super::inbox::persons_prompt(run.agent.as_deref(), run.provenance.as_ref())
            && self.config.read().await.agent_inbox();
        let mut turn = TurnInfo::prompted(client, &text, &turn_id, &prompt_id, control)
            .shown_as(&super::prompt_line::prompt_line(&text, client, provenance.as_ref()))
            .noticed(super::prompt_line::is_notice(provenance.as_ref()))
            .by_person(persons);
        turn.trigger = trigger;
        let retry = super::subagent_retry::is_retry(run.provenance.as_ref());
        let mut cloud_exec = if let Some(envelope) = cloud_turn.as_ref() {
            if envelope.session != session.id
                || envelope.turn != turn_id
                || envelope.purpose != "execute"
                || std::env::var("CMUX_PLATFORM_WORKSPACE_ID").ok().as_deref()
                    != Some(envelope.workspace.as_str())
                || std::env::var("CMUX_PLATFORM_MACHINE_ID").ok().as_deref()
                    != Some(envelope.machine.as_str())
                || session
                    .validate_prepared(
                        &prompt_id,
                        &turn_id,
                        envelope.generation,
                        &envelope.attempt_id,
                        None,
                    )
                    .is_err()
            {
                let e =
                    RpcError::invalid_params("cloud turn capability does not match this prompt");
                self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
                drop(guard);
                return Err(e);
            }
            let origin = std::env::var("CMUX_PLATFORM_ORIGIN")
                .map_err(|_| RpcError::invalid_params("Cloud platform is not configured"))?;
            let scope = envelope.scope();
            let auth = Arc::new(
                crate::cloud_rewind::EphemeralCapability::new(envelope.capability.clone())
                    .map_err(|e| RpcError::internal(e.to_string()))?,
            );
            let cloud = crate::cloud_rewind::CloudTurnClient::new(
                &origin,
                &scope.workspace,
                &scope.machine,
                auth,
            )
            .map_err(|e| RpcError::internal(e.to_string()))?;
            Some((cloud, scope))
        } else {
            None
        };
        if let Err(e) = self.start_turn(session, after_turn.as_deref(), no_queue, retry, turn) {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        self.arm_turn_cap(session, &turn_id);
        // The inbox's notice this turn is lands (`inbox.rs`): noticed once its prompt is written
        // (below), and what is new steers in then.
        self.inbox_turn_started(session);
        // A lane's report to a parent whose close began since `queue_slot` checked is refused
        // (`lane_reports.rs`). Checked once the turn is set: `kill` marks the close before it
        // clears the turn, so a close that began any time before this check is seen.
        if super::queue::refuses_closing_run(session, run.provenance.as_ref()) {
            *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = None;
            let e = super::queue::closing_error();
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        // Claim only after every dispatch fence that can refuse the prompt has passed. The
        // capability is one-use; every successful claim is finished below or on each early exit.
        if let Some((cloud, scope)) = cloud_exec.as_ref()
            && let Err(error) = cloud.claim_execution(scope).await
        {
            let e = RpcError::new(-32000, format!("cloud turn claim refused: {error}"));
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
            drop(guard);
            return Err(e);
        }
        // An agent message's turn takes the agent messages waiting behind it (`digest.rs`), once
        // the turn has started, so none leaves the queue for a turn that never runs. A forum push
        // is no agent's message: it never leads one.
        let parts = self.take_joined(session, &run, &prompt_id, &turn_id, joined);
        let team_prompt_ids: Vec<_> = std::iter::once(prompt_id.clone())
            .chain(parts.iter().map(|part| part.prompt_id.clone()))
            .collect();
        let digested = !parts.is_empty();
        let (blocks, text) = if !digested {
            (blocks, text)
        } else {
            let sender = run.agent.clone().unwrap_or_default();
            let head =
                super::digest::Part { prompt_id: prompt_id.clone(), sender, run: run.clone() };
            let parts: Vec<_> = std::iter::once(head).chain(parts).collect();
            provenance = Some(super::digest::digest_provenance(&parts));
            let blocks = super::digest::digest_blocks(&parts);
            let text = prompt_text(&blocks);
            display_parts = None;
            (blocks, text)
        };
        let mut blocks = blocks;
        // Another agent's message leaves its sender and words, not its envelope (`prompt_line.rs`).
        let line = super::prompt_line::prompt_line(&text, client, provenance.as_ref());
        // A turn that took in the messages behind its own shows them all, as its last prompt does.
        if digested
            && let Some(t) = session.turn.lock().unwrap_or_else(|e| e.into_inner()).as_mut()
            && t.turn_id == turn_id
        {
            t.show(&line);
        }
        {
            let mut m = session.meta.lock().unwrap();
            if !trigger {
                m.last_prompt = Some(short_text(&line, 200));
                drafts::clear_sent_draft(&mut m, &text);
                // Titled by the sender's words, never the envelope they came in.
                let words = super::prompt_line::prompt_words(&text, client, provenance.as_ref());
                super::titles::set_fallback_title(&mut m, &words);
                m.preview = Some(String::new());
            }
            // The sender of a chat's first turn is its delegator (`inbox.rs`): named once the
            // turn starts, so a prompt refused before it names none, and over one a message the
            // inbox took while this first work waited to start named. Its own sender, not a
            // digest's: messages that joined its turn (`digest.rs`) name none. A first work a
            // person's prompt went ahead of still names it.
            if (m.turn_count == 0 || super::inbox::is_first_work(run.provenance.as_ref()))
                && let Some(from) = super::inbox::sender_session(run.provenance.as_ref())
                && from != m.id
            {
                m.delegator = Some(from);
            }
            m.turn_count += 1;
        }
        // A turn on lane reports only reports nothing (`lane_reports.rs`).
        self.lane_turn_started(session, provenance.as_ref());
        // A family prompt (`subsessions.rs`) never clears the floor a Web
        // turn left: only a local turn the person or a client starts does.
        let family = super::subsession_guard::is_family_prompt(run.provenance.as_ref());
        if control == Control::Web || !family {
            session.floor.last_turn_web.store(control == Control::Web, Ordering::SeqCst);
        }
        self.reset_stream(session);
        // A forced Stop retires the logical turn even if Claude's compaction
        // finishes later. Do not let the stale compaction flag cancel the
        // next, explicit prompt immediately.
        session.compacting.store(false, Ordering::SeqCst);
        let msg = json!({"text": text, "client": client, "promptId": prompt_id, "turnId": turn_id});
        let msg = crate::prompt_provenance::marked(msg, provenance.as_ref());
        self.append_prompt(session, msg, &blocks, display_parts.as_ref());
        if trigger {
            self.start_trigger_background(session, &turn_id);
        }
        if !waiting {
            // Started at once: only prompts a failed turn holds can wait under its key.
            if let Some(key) = supersede.as_deref() {
                let _ =
                    replaced.set(self.supersede_queued(session, key, agent.as_deref(), &prompt_id));
            }
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false, "state": "started"}),
            );
        }
        // The prompt is recorded and acknowledged above before the agent is started again (it
        // died, or the daemon restarted), so a client hears prompt_accepted at once.
        self.wake_cause(session, "prompt");
        // Boxed: two starts and the fallback check inline overflowed a debug build's 2 MiB
        // worker stack (`fatal runtime error: stack overflow` in every prompt after #27484).
        let mut started = Box::pin(self.child_for_since(session, stops)).await;
        // A failover left the chat on a profile that cannot start: back to the profile it came
        // from, which starts this turn (`fallback_start.rs`).
        if let Err(e) = &started
            && Box::pin(self.back_from_fallback(session, e, &turn_id)).await
        {
            started = Box::pin(self.child_for_since(session, stops)).await;
        }
        let started = match started {
            Ok(child) => session
                .meta()
                .agent_session_id
                .map(|sid| (child, sid))
                .ok_or_else(|| RpcError::internal("no agent session")),
            Err(e) => Err(e),
        };
        let (mut child, agent_sid) = match started {
            Ok(started) => started,
            Err(e) => {
                self.fail_unstarted_turn(session, &prompt_id, &turn_id, &e, joined);
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
        };
        // A Web steer while the agent started made this a Web turn.
        let control = session.turn().map_or(control, |t| t.control);
        // Starting the agent may have changed its mode (a spawn, a resume, a
        // pool claim, a replayed config): checked again before the prompt.
        if let Err(e) = self
            .check_dispatch(
                session,
                control,
                trust_gate,
                device.as_deref(),
                &prompt_id,
                &turn_id,
                client,
            )
            .await
        {
            self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined);
            Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
            drop(guard);
            return Err(e);
        }
        // Held until the prompt is written: an MDM off push waits for it (`family_gate`).
        let mut family_gate = match self.family_gate(session, run.provenance.as_ref()).await {
            Ok(gate) => gate,
            Err(e) => {
                self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
                self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined);
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
        };
        // Add information after digest reconstruction and the person's display record. Slash
        // commands keep their prompt intact and leave these notices for a normal turn.
        let team_enabled =
            self.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging);
        let team_messages = if team_enabled && super::forum::slash_command(&blocks).is_none() {
            self.take_team_messages(session)
        } else {
            Vec::new()
        };
        super::team_information::prepend(&mut blocks, &team_messages);
        // A team message, or an inbox notice (`inbox.rs`), counts as delivered only once the
        // harness writer took its prompt: `on_sent` then logs it.
        let confirm_team_write = !team_messages.is_empty()
            || (team_enabled && self.has_team_work(session, &team_prompt_ids))
            || super::inbox::is_notice(provenance.as_ref());
        if session.rehydrate.swap(false, Ordering::SeqCst)
            && let Some(transcript) = self.transcript(session, 24_000)
        {
            blocks.insert(
                    0,
                    json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored this conversation on a new agent session; tool state was not restored\">\n{transcript}\n</restored_transcript>\n")}),
                );
        }
        // The forum rules this session was not told yet (`hub/forum.rs`).
        let mut told = self.forum_context(session, pushed.clone(), &mut blocks).await;
        session.stderr_tail.lock().unwrap().clear();
        // Under the turn lock: this turn ends a person's Stop's hold only if it began under it.
        session.turn_hold.store(session.stop_hold.load(Ordering::SeqCst), Ordering::SeqCst);
        let turn_seq = self
            .append(
                session,
                "mux",
                "turn_started",
                json!({"prompt": short_text(&text, 200), "promptLine": super::auto_resume::shown_line(&line), "client": client, "promptId": prompt_id, "turnId": turn_id, "control": control.as_str(), "trustGate": trust_gate, "persons": persons, "trigger": trigger}),
            )
            .seq;
        // The prompt as the agent gets it, before the checks below: making its model-sized copies
        // may take a moment, in which a Stop or a remote device may come (`model_copies.rs`).
        let wire = agent_blocks(self, session, &blocks).await;
        let stopped = session.cancels.load(Ordering::SeqCst) != cancels
            || session.stops.load(Ordering::SeqCst) != stops;
        let control = {
            let mut turn = session.turn.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(t) = turn.as_mut() {
                t.turn_seq = turn_seq;
            }
            turn.as_ref().map_or(control, |t| t.control)
        };
        let wire = match wire {
            // A remote device took the turn meanwhile: the prompt goes without copies.
            Ok(_) if control == Control::Web => acp_prompt_blocks(session, &blocks),
            wire => wire,
        };
        let wire = match wire {
            Ok(wire) if !stopped => wire,
            Ok(_) => {
                let e = stopped_before_prompt();
                self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined);
                self.forum_turn_end(session, &told, false);
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
            Err(e) => {
                self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined);
                self.forum_turn_end(session, &told, false);
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
        };
        // The remote floor fired before the prompt went out (a mode write
        // in the gap): the prompt is not sent. After this point the floor's
        // cancel reaches the agent after the prompt (`remote_floor.rs`).
        // A machine's Full access that ended since the dispatch check (`full_access_hold`).
        let full_access_ended = || {
            self.full_access_hold(&session.meta(), control, device.as_deref())
                .err()
                .map(|_| "remote.full_access_device")
        };
        if control == Control::Web
            && let Some(reason) = self.remote_floor_breach(session).or_else(full_access_ended)
        {
            let e = RpcError::new(-32000, "the remote floor cancelled this turn before its prompt")
                .with_data(json!({"reason": reason}));
            self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined);
            self.forum_turn_end(session, &told, false);
            Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
            drop(guard);
            return Err(e);
        }
        // Its stalled count starts once its prompt is written (`stalled_turn.rs`).
        Self::hold_stalled_count(session);
        // A new turn: its own end decides the dot, not an earlier one's (`work_below.rs`).
        if !trigger {
            self.clear_deferred_unread(session);
        }
        self.end_foreground_subagents(session);
        self.set_status(session, SessionStatus::Running);
        self.watch_silent_turn(session, &turn_id).await;
        // Tests only: a pause right before the write (`full_access_bound::WriteSeam`).
        #[cfg(test)]
        self.pause_at_family_write().await;
        let fence = family_gate.take().map(|hold| self.hold_until_written(session, hold));
        // A fence no writer took (an error before it was handed on) is cut: nothing waits on it
        // (review 86 of #23322); a written one stays written.
        let _unsent = crate::agent::CutOnDrop(fence.as_ref());
        // Start title generation after the first prompt is written to the harness, while its
        // session-info title can still win before the cheap completion is spent.
        let mut result = super::steer_end::agent_prompt_hook(
            session,
            &child,
            super::prompt_sender::run_params(&agent_sid, json!(wire), &run),
            &turn_id,
            false,
            false,
            fence.as_ref(),
            confirm_team_write,
            None,
            || {
                self.mark_team_messages(session, &team_messages);
                if team_enabled {
                    self.mark_team_work(session, &team_prompt_ids);
                }
                self.watch_stalled_turn(session, None);
                // Written: a notice this is went in, and what is new in the inbox may steer in
                // behind it (`inbox.rs`).
                self.inbox_prompt_written(session, &prompt_id);
                self.title_after_prompt(session)
            },
        )
        .await;
        // The account behind this harness is exhausted: move the session
        // onto its fallback profile (the subrouter pool for Claude), which
        // resumes the same agent session, and run the prompt once more.
        // A fallback that cannot start now takes no turn: `(profile, why)`.
        let mut unstartable = None;
        if let Err(e) = &result {
            // A pool launcher that dies on the prompt (its proxy is down)
            // moves the session too, not only a usage or auth limit.
            // A stopped session's agent closed because of the stop: no failover starts it again.
            // Nor does one MDM's off ended (review 3 of #26034).
            // The process exit and its stderr arrive on separate inbound messages; drain them
            // before deciding whether this is the supported authentication failover case.
            Self::drain_inbound(session).await;
            let stderr =
                session.stderr_tail.lock().unwrap().iter().cloned().collect::<Vec<_>>().join("\n");
            let dead_limit = e.message.starts_with("agent process closed")
                && is_limit_error(&stderr)
                && !super::turn_errors::is_usage_limit_error(&stderr)
                && !super::turn_errors::is_gateway_error(&stderr);
            let mut target = if ((is_limit_error(&e.message)
                && !super::turn_errors::is_usage_limit_error(&e.message)
                && !super::turn_errors::is_gateway_error(&e.message))
                || dead_limit)
                && session.stops.load(Ordering::SeqCst) == stops
                && !child.ended_on_purpose()
            {
                self.fallback_profile(session).await
            } else {
                None
            };
            // Its route cannot start (a local router that is down): the chat stays where it is
            // rather than moving onto a profile every later turn fails on (`fallback_start.rs`).
            if let Some(to) = &target
                && let Some(why) = Box::pin(self.route_refusal(&session.meta(), to)).await
            {
                unstartable = Some((to.clone(), why.message));
                target = None;
            }
            if let Some(to) = target {
                let from = session.meta().harness;
                // Before the failover is logged: a /context answer the old agent sends from here
                // on is not logged after it as the fallback's.
                if let Some(old) = session.child.lock().await.as_ref() {
                    old.retire();
                }
                self.append(
                    session,
                    "mux",
                    "failover",
                    json!({"from": from, "to": to, "reason": e.message, "turnId": turn_id}),
                );
                // The turn goes on, on the fallback. A new agent: the old one's silence and
                // tools are not its own, and its count starts once the prompt is written to it.
                Self::hold_stalled_count(session);
                // The conversation the chat's own profile resumes, if the fallback cannot start.
                let kept = super::fallback_start::ConversationMark::of(session);
                let turn = session.turn();
                self.detach_child(session).await;
                *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = turn;
                self.set_status(session, SessionStatus::Running);
                {
                    let mut m = session.meta.lock().unwrap();
                    m.harness = to.clone();
                    // The last harness's /context breakdown is not the fallback's, nor its
                    // account's usage limits.
                    m.context_breakdown = None;
                    m.usage_limits = None;
                }
                self.save_meta(session);
                let control = session.turn().map_or(control, |t| t.control);
                let fallback = Box::pin(self.child_for_since(session, stops)).await;
                let refusal = match &fallback {
                    Ok(_) => match self
                        .check_dispatch(
                            session,
                            control,
                            trust_gate,
                            device.as_deref(),
                            &prompt_id,
                            &turn_id,
                            client,
                        )
                        .await
                    {
                        // A family message is checked again, and held until it is resent: an
                        // off push may have come since its first write (`family_gate`).
                        Ok(()) => match self.family_gate(session, run.provenance.as_ref()).await {
                            Ok(hold) => {
                                family_gate = hold;
                                None
                            }
                            Err(e) => Some(e),
                        },
                        Err(e) => Some(e),
                    },
                    Err(_) => None,
                };
                match (fallback, refusal) {
                    // The fallback is checked as a new dispatch; its own
                    // refusal (folder trust, mode, D13) is the turn's error.
                    (Ok(_), Some(e)) => result = Err(e),
                    (Ok(child2), None) => {
                        // The turn ends on the fallback's agent: `finish_turn` reads its life.
                        child = child2.clone();
                        // A fallback that could not resume (another store)
                        // starts fresh: it gets the restored transcript first.
                        let mut blocks = blocks;
                        if session.rehydrate.swap(false, Ordering::SeqCst)
                            && let Some(transcript) = self.transcript(session, 24_000)
                        {
                            blocks.insert(
                                0,
                                json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored this conversation on a new agent session; tool state was not restored\">\n{transcript}\n</restored_transcript>\n")}),
                            );
                            // The new agent session gets every rule again.
                            told = self.forum_retell(session, pushed.clone(), &mut blocks).await;
                        }
                        // Its start read the chat ready: the turn runs on.
                        self.set_status(session, SessionStatus::Running);
                        if let Some(sid2) = session.meta().agent_session_id {
                            // A Stop since this turn began: not written. That is one while its
                            // copies were made (as the first), and one while the chat had no
                            // agent between the two, which found none to cancel (`cancel.rs`).
                            // A prompt that cannot be put into blocks is the turn's error, so
                            // `finish_turn` settles the turn rather than leaving it running.
                            let wire = agent_blocks(self, session, &blocks).await;
                            let stopped = session.cancels.load(Ordering::SeqCst) != cancels
                                || session.stops.load(Ordering::SeqCst) != stops;
                            let fence = family_gate
                                .take()
                                .map(|hold| self.hold_until_written(session, hold));
                            // Not handed on (a Stop meanwhile): cut, so nothing waits on it.
                            let _unsent = crate::agent::CutOnDrop(fence.as_ref());
                            // Like the first prompt: Stop's and a stalled turn's forced end
                            // (`cancel.rs`, `stalled_turn.rs`) end it too.
                            result = match wire {
                                Err(e) => Err(e),
                                Ok(_) if stopped => Err(stopped_before_prompt()),
                                Ok(wire) => {
                                    super::steer_end::agent_prompt_hook(
                                        session,
                                        &child2,
                                        json!({"sessionId": sid2, "prompt": wire}),
                                        &turn_id,
                                        false,
                                        false,
                                        fence.as_ref(),
                                        confirm_team_write,
                                        None,
                                        || {
                                            self.mark_team_messages(session, &team_messages);
                                            if team_enabled {
                                                self.mark_team_work(session, &team_prompt_ids);
                                            }
                                            self.watch_stalled_turn(session, None);
                                            self.inbox_prompt_written(session, &prompt_id);
                                        },
                                    )
                                    .await
                                }
                            };
                        }
                    }
                    // It could not start after all: the chat goes back to the profile it was
                    // on, and the turn fails with its own error, saying why.
                    // An agent its failed start left behind is not the chat's, and the
                    // conversation is the one it had.
                    (Err(e2), _) => {
                        let turn = session.turn();
                        self.detach_child(session).await;
                        *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = turn;
                        self.set_status(session, SessionStatus::Running);
                        kept.restore(session);
                        self.move_profile(session, &from, &e2.message, &turn_id, true);
                        result = Err(super::fallback_start::fallback_not_started(
                            e,
                            &from,
                            &to,
                            &e2.message,
                        ));
                    }
                }
            }
        }
        if let Some((to, why)) = unstartable
            && let Err(e) = &result
        {
            let from = session.meta().harness;
            self.append(
                session,
                "mux",
                "failover_skipped",
                json!({"from": from, "to": to, "reason": e.message, "error": why, "turnId": turn_id}),
            );
            result = Err(super::fallback_start::fallback_not_started(e, &from, &to, &why));
        }
        let ids = json!({"promptId": prompt_id, "turnId": turn_id, "turnSeq": turn_seq});
        // What the agent said, before `finish_turn` adds a dead process's last stderr line; a
        // model switch (`detach_child`) that ended the turn is no connection error.
        let agent_error = result.as_ref().err().map(|e| e.message.clone());
        let detached = session.turn().is_none_or(|t| t.turn_id != turn_id);
        // Its agent ended the turn and runs on with steers it read after: the next turn starts
        // as this one ends (`carried_turn.rs`). Boxed: this future stays small.
        let carried = self.next_carried(session, &turn_id, &result);
        let mut result = self
            .finish_turn(
                session,
                &child,
                result,
                &prompt_id,
                &turn_id,
                turn_seq,
                Some(joined),
                crate::prompt_provenance::is_trigger(run.provenance.as_ref()),
                carried.as_deref(),
            )
            .await;
        Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
        if let Some(c) = &carried {
            self.start_carried(session, &child, &turn_id, c, guard.take_slot());
        }
        // A rule counts as told once the agent answered the prompt that carried it.
        self.forum_turn_end(session, &told, result.is_ok());
        // A connection error cut the turn off: it goes on by itself (`auto_resume.rs`).
        let cut = match (&result, detached) {
            // A turn its agent runs on with carried steers was not cut.
            (Err(e), false) if carried.is_none() && !trigger => Some(super::auto_resume::CutTurn {
                // A family message's continuation speaks for its sender (`is_family`).
                from: run
                    .provenance
                    .as_ref()
                    .filter(|p| super::subsession_guard::is_family(Some(p)))
                    .and_then(|p| p["from"].as_str()),
                prompt_id: &prompt_id,
                turn_id: &turn_id,
                control,
                trust_gate,
                error: super::turn_errors::continuation_error(agent_error.as_deref(), &e.message),
                not_before: super::auto_resume::reset_hint::error_reset_at(
                    e.data.as_ref(),
                    now_ms(),
                ),
            }),
            _ => None,
        };
        self.schedule_auto_resume(session, &turn_id, cut);
        // The agent a Stop ended starts again on the same conversation now, while this turn's
        // lock is still held: the next queued turn finds it running (`cancel.rs`).
        self.respawn_stopped_agent(session, &turn_id, stops).await;
        // The chat's route changed during the turn: move it before the next
        // one starts (route_switch.rs). A restart that fails leaves the
        // harness stopped; the next prompt's spawn reports why. A carried turn runs on: its
        // task moves it when it ends.
        if session.route_switch.load(Ordering::SeqCst) && carried.is_none() {
            let _ = self.restart_on_route(session).await;
        }
        drop(guard);
        if let Ok(v) = &mut result {
            merge_mux_meta(v, ids);
        }
        result
    }

    /// Settle a turn once its `session/prompt` answered (or failed), also one recovered from an
    /// adopted agent host: `turn_end`/`turn_error`, `turn_result` and the session status.
    pub(super) async fn finish_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        mut result: Result<Value, RpcError>,
        prompt_id: &str,
        turn_id: &str,
        turn_seq: u64,
        joined: Option<&super::digest::DigestTurn>,
        trigger: bool,
        next: Option<&super::carried_turn::NextTurn>,
    ) -> Result<Value, RpcError> {
        // This turn's number, before taking it lets the next one start (`lane_reports.rs`).
        let turn = session.meta().turn_count;
        // A model switch (`detach_child`) ended this turn already: its failure is not the queue's.
        let in_place = next.map(|n| n.next.clone());
        // Taken under the shutdown's lock: its sweep finds the turn running or here, never in
        // between (`shutdown.rs` `settle_ends`).
        let detached = {
            let _ends = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
            let taken = self.take_turn(session, turn_id, in_place);
            let took = taken.as_ref().is_some_and(|t| t.turn_id == turn_id);
            if took {
                *session.ending.lock().unwrap_or_else(|e| e.into_inner()) = taken;
            }
            !took
        };
        let ending = EndUnderWay { hub: self, session, turn_id };
        // Named in this turn's `turn_result`, so a restart before it starts still runs it.
        let carried_next = next.filter(|_| !detached);
        // The turn a Stop was stopping has ended (`cancel.rs`): it no longer reads `stopping`,
        // unless its agent runs on in the turn that takes its place (`carried_turn.rs`).
        let was_stopping = take_if_turn(&session.stopping, turn_id);
        if was_stopping && let Some(n) = carried_next {
            *session.stopping.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(n.next.turn_id.clone());
        }
        if take_if_turn(&session.stop_restart, turn_id) && result.is_err() {
            result = Ok(super::cancel::forced_answer(true));
        }
        let carries_on = carried_next.is_some();
        let carried_to = || {
            carried_next.map(|n| {
                let live = session.turn().filter(|t| t.turn_id == n.next.turn_id);
                n.record(live.map_or(n.next.control, |t| t.control))
            })
        };
        session.queue_moved.notify_waiters();
        // Debug builds only: `ACPMUX_TEST_FINISH_HOLD_MS` holds a turn's end once its turn is
        // taken, as a slow end does (`tests/durable_agents.rs`). Bounded; release builds have no
        // seam.
        #[cfg(debug_assertions)]
        if let Some(ms) =
            std::env::var("ACPMUX_TEST_FINISH_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
        {
            tokio::time::sleep(std::time::Duration::from_millis(ms.min(10_000))).await;
        }
        #[cfg(test)]
        {
            let seam = self.finish_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // A turn Claude answered is in its store: a respawn resumes it.
        if result.is_ok() {
            let was_unstored = std::mem::take(&mut session.meta.lock().unwrap().claude_unstored);
            if was_unstored {
                self.save_meta(session);
            }
        }
        // Quit Everything already recorded this turn as cancelled. It ends the lane's parent too and
        // no agent starts after it, so the lane reports nothing (`lane_reports.rs`). A restart
        // handed it to the next daemon, which continues it: its end is that daemon's to write.
        if self.settled_by_shutdown.lock().unwrap().contains(turn_id) {
            if self.hands_off(session) {
                super::digest::forget_joined(joined);
            }
            return result;
        }
        // The agent's end came with a shutdown that hands the chat to the next daemon, or after
        // it began: the turn is cut, not ended, and that daemon continues it. Nothing here writes
        // its end, puts its messages back or holds the queue, whoever took the turn first.
        if result.is_err() && self.hands_off(session) {
            super::digest::forget_joined(joined);
            return result;
        }
        // acpmux ended a turn whose model said nothing for `stalledTurnEndMs`: it failed.
        let stalled = result.as_ref().ok().and_then(Self::stalled_error);
        if let Some(e) = stalled {
            result = Err(e);
        }
        // Apply queued stderr before classifying a dead process (a limit never resumes).
        Self::drain_inbound(session).await;
        // Before the message gains the stderr line: `recovery::annotate_as` below types it.
        let dead = matches!(&result, Err(e) if crate::recovery::dead_process(e));
        if let Err(e) = &mut result
            && dead
        {
            let tail: Vec<String> = session.stderr_tail.lock().unwrap().iter().cloned().collect();
            // The last stderr line that says why: not a stack frame, a wrapper tag or a wrapper exit line.
            if let Some(last) = tail.iter().rev().find(|line| explains_exit(line)).cloned() {
                let agent = session.meta().harness;
                e.message = format!("{} ({agent}): {last}", e.message);
            }
        }
        // A harness that reported a terminal error in-band (Codex
        // `_meta.codex.error` without willRetry) and then ended the turn
        // normally still failed it: answer the prompt with that error.
        let harness_error = session.stream.lock().unwrap().harness_error.clone();
        let harness_failure = match (&result, &harness_error) {
            (Ok(v), Some(h))
                if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") =>
            {
                let text = h.get("text").and_then(Value::as_str).unwrap_or("");
                let text =
                    if text.is_empty() { "the harness reported an error" } else { text }.to_owned();
                let data = json!({"errorSource": h.get("source"), "errorCode": h.get("code"), "stopReason": v.get("stopReason")});
                Some(RpcError::new(-32000, text).with_data(data))
            }
            _ => None,
        };
        let harness_failed = harness_failure.is_some();
        if let Some(e) = harness_failure {
            result = Err(e);
        }
        // The agent messages that went in with it go back before anything here waits, so one sent
        // from now on goes behind them (`digest.rs`).
        if let (Err(_), Some(joined)) = (&result, joined) {
            self.requeue_joined(session, joined, true);
        }
        // A failure on a bound route names the route and its fallback
        // (route_switch.rs), in the error's data and the turn result.
        let route_info = match &result {
            Err(e) => self.route_failure(session, &e.message).await,
            Ok(_) => None,
        };
        // A Claude agent that is not signed in: say what it had, how the
        // person's terminal signs in, and the fix (`claude_auth.rs`).
        let mut signed_out = false;
        if let Err(e) = &mut result
            && let Some(text) = crate::claude_auth::explain(&session.id, &e.message)
        {
            tracing::warn!(session = %session.id, "Claude agent is not signed in");
            e.message = text;
            signed_out = true;
        }
        if let (Err(e), Some(Value::Object(info))) = (&mut result, &route_info) {
            match &mut e.data {
                Some(Value::Object(data)) => data.extend(info.clone()),
                None => e.data = Some(Value::Object(info.clone())),
                Some(_) => {}
            }
        }
        // A failure acpmux knows the remedy for says it (`recovery.rs`): a full disk, an agent
        // that exited, a harness that cannot start. A sign-in failure already says its fix.
        if let Err(e) = &mut result {
            crate::recovery::annotate_as(e, Some(&session.meta().cwd), dead && !signed_out);
            // After the agent's own reason: its fallback could not take the turn, and why.
            super::fallback_start::say_fallback(e);
        }
        let git = super::turn_git::turn_git(session).await;
        // The end is written from here with no wait, under the shutdown's lock: a shutdown that
        // settled the turn meanwhile wrote its end (Quit Everything) or handed it on, and its
        // sweep finds this one either written or still to settle (`shutdown.rs` `settle_ends`).
        // In a block of its own: a guard only dropped would still count as held at the awaits
        // below, and the prompt futures that end here are spawned (`Send`).
        let stopped_early = {
            let ends = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
            if ends.contains(turn_id) {
                drop(ends);
                if self.hands_off(session) {
                    super::digest::forget_joined(joined);
                }
                return result;
            }
            ending.clear();
            // A Stop kept the prompt from the fallback a failover started (`stopped_before_prompt`),
            // or the agent of a turn a Stop was stopping ended it with an error (it exited, its
            // cancel failed, or it reported one): the turn ends as the Stop's, cancelled, and holds
            // no queue as a failure does; the prompt's caller still hears why.
            let stopped_early = result
                .as_ref()
                .err()
                .filter(|e| is_stopped_before_prompt(e) || (was_stopping && !carries_on))
                .cloned();
            if stopped_early.is_some() {
                result = Ok(stopped_answer());
            }
            match &result {
                Ok(v) => {
                    self.note_reply_refusal(session);
                    let stop = v.get("stopReason").cloned().unwrap_or(Value::Null);
                    self.append(
                        session,
                        "mux",
                        "turn_end",
                        json!({"stopReason": stop, "turnId": turn_id, "turnSeq": turn_seq}),
                    );
                    // A turn a Stop was stopping ended as the Stop's, whatever stop reason its agent
                    // gave: an adapter that answers the cancel `end_turn` still stopped, so clients
                    // offer Continue on it. Not one whose agent runs on into the next turn.
                    let stopped =
                        stop.as_str() == Some("cancelled") || (was_stopping && !carries_on);
                    let status = if stopped { "cancelled" } else { "completed" };
                    let mut msg = json!({"status": status, "stopReason": stop, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
                    if let Some(o) = msg.as_object_mut() {
                        o.extend(self.turn_error_fields(session, None));
                        // acpmux ended a turn whose agent did not answer the cancel (`cancel`).
                        if v.pointer("/_meta/acpmux/cancelForced") == Some(&Value::Bool(true)) {
                            o.insert("cancelForced".into(), Value::Bool(true));
                        }
                        o.extend(super::turn_usage::turn_usage(session, v));
                        if let Some(to) = carried_to() {
                            o.insert("carriedTo".into(), to);
                        }
                    }
                    self.write_turn_result(session, msg, git);
                    // The chat works again: agent messages a failed turn held go in (`digest.rs`).
                    // Not while a person's Stop that came after this turn began holds them
                    // (`cancel.rs`): only a turn begun under that hold, or a resume, ends it.
                    let hold = session.stop_hold.load(Ordering::SeqCst);
                    if status == "completed"
                        && (hold == 0 || hold == session.turn_hold.load(Ordering::SeqCst))
                    {
                        self.release_held_agent_messages(session, hold);
                    }
                }
                Err(e) => {
                    let mut record = json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": turn_seq});
                    if let Some(o) = record.as_object_mut() {
                        o.extend(crate::recovery::fields(e));
                    }
                    self.append(session, "mux", "turn_error", record);
                    self.note_model_refusal(session, &e.message);
                    if !detached {
                        self.pause_queue(session, turn_id);
                    }
                    let mut msg = json!({"status": "failed", "error": e.message, "code": e.code, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
                    if let Some(o) = msg.as_object_mut() {
                        let agent_error =
                            (!harness_failed).then(|| (e.message.as_str(), json!(e.code)));
                        o.extend(self.turn_error_fields(session, agent_error));
                        if let Some(Value::Object(info)) = &route_info {
                            o.extend(info.clone());
                        }
                        o.extend(crate::recovery::fields(e));
                        if let Some(to) = carried_to() {
                            o.insert("carriedTo".into(), to);
                        }
                        // Ended by acpmux, not the agent (`stalled_turn.rs`).
                        if let Some(data) = e.data.as_ref().filter(|d| d["detail"] == "stalled") {
                            o.insert("detail".into(), data["detail"].clone());
                            o.insert("stalledMs".into(), data["stalledMs"].clone());
                            o.insert("errorSource".into(), json!("acpmux"));
                        }
                    }
                    self.write_turn_result(session, msg, git);
                }
            }
            stopped_early
        };
        // Its harness wrote the turn's spend: read it (`usage_view.rs`).
        self.refresh_usage_stats_of(session);
        if trigger {
            self.end_trigger_background(session, turn_id);
        }
        self.reset_stream(session);
        // Nobody showing it: the sidebar dot and `wait --until done` see it. While work it
        // started still runs (a background subagent, a working sub-session) the task is not
        // done: the dot waits for that work to end (`work_below.rs`, manaflow-ai/cmux#25563).
        if !trigger && !self.shown(session) {
            self.mark_unread_unless_work_below(session);
        }
        if session.status() != SessionStatus::Closed {
            let alive = child.is_alive().await;
            // A subagent or background shell still waiting on the person
            // keeps the chat waiting after its turn (cx-jo8yo). The lock is
            // held across the write, so an answer in between cannot leave it
            // waiting on nothing.
            let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let asking = !state.pending.is_empty() || self.secrets.waiting_in(&session.id);
            // An agent MDM's off ended leaves the chat idle; read under the lock its end marks it
            // under (`end_managed_full_access`, reviews 2 and 3 of #26034).
            let ended = child.ended_on_purpose();
            self.set_status(
                session,
                match (ended, alive, asking) {
                    // The next turn runs already (`carried_turn.rs`).
                    (false, true, _) if carries_on => SessionStatus::Running,
                    (true, _, _) => SessionStatus::Idle,
                    (false, false, _) => SessionStatus::Disconnected,
                    (false, true, true) => SessionStatus::Waiting,
                    (false, true, false) => SessionStatus::Ready,
                },
            );
            drop(state);
        }
        self.save_meta(session);
        self.send_offer_result(session);
        self.lane_turn_ended(session, true, turn);
        self.inbox_turn_ended(session);
        match stopped_early {
            Some(e) => Err(e),
            None => result,
        }
    }

    /// A turn refused after it was accepted (dispatch check, remote floor): failed unstarted.
    fn refuse_started_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
        joined: &super::digest::DigestTurn,
    ) {
        self.fail_unstarted_turn(session, prompt_id, turn_id, e, joined);
        if session.status() == SessionStatus::Disconnected {
            self.set_status(session, SessionStatus::Ready);
        }
    }

    /// A prompt that left the queue (`dequeued`, `waiting`) refused before its turn: the log
    /// settles it with `prompt_refused`, so a restart does not queue it again (`restore_queue`).
    fn refuse_dequeued(
        &self,
        session: &Arc<Session>,
        waiting: bool,
        prompt_id: &str,
        turn_id: &str,
        client: &str,
        e: &RpcError,
    ) {
        if waiting {
            let msg = json!({"promptId": prompt_id, "turnId": turn_id, "client": client, "error": e.message, "data": e.data});
            self.append(session, "mux", "prompt_refused", msg);
        }
    }

    /// A recorded prompt whose agent could not start: the turn ends failed, so every client
    /// sees the prompt settle instead of a turn that never starts. It fails alone: the prompts
    /// behind it are not held (`pause_queue`), each gets its own try, as after a Stop. Only a turn
    /// whose prompt reached its agent and failed holds them (`finish_turn`).
    ///
    /// One a Stop kept from its agent ([`stopped_before_prompt`], a Stop while the agent started
    /// or the prompt's copies were made) ends as the Stop's turn: cancelled, so clients offer
    /// Continue on it, as on any stopped turn.
    fn fail_unstarted_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        e: &RpcError,
        joined: &super::digest::DigestTurn,
    ) {
        let turn = session.meta().turn_count;
        let trigger = session.turn().is_some_and(|t| t.trigger && t.turn_id == turn_id);
        self.end_trigger_background(session, turn_id);
        *session.turn.lock().unwrap() = None;
        // It no longer reads `stopping`: a Stop that came while its agent started (`cancel.rs`)
        // ends it as stopped, also when the start then failed.
        let was_stopping = take_if_turn(&session.stopping, turn_id);
        // The prompt behind it waits for no turn now (`queue_turn`).
        session.queue_moved.notify_waiters();
        // The agent messages that joined it never reached the agent either: back unheld, unless
        // a person's Stop holds them (`requeue_joined`).
        self.requeue_joined(session, joined, false);
        let stopped_early = is_stopped_before_prompt(e);
        if stopped_early || was_stopping {
            let stop = stopped_answer().get("stopReason").cloned().unwrap_or_default();
            self.append(
                session,
                "mux",
                "turn_end",
                json!({"stopReason": stop, "turnId": turn_id, "turnSeq": 0}),
            );
            let msg = json!({"status": "cancelled", "stopReason": stop, "turnSeq": 0, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
            self.record_last_turn(session, &msg);
            self.append(session, "mux", "turn_result", msg);
            self.reset_stream(session);
            // Its agent started (a Stop kept the prompt from it), or failed to: the chat waits
            // for the next prompt, or says its agent is not running.
            if session.status() != SessionStatus::Closed {
                let status =
                    if stopped_early { SessionStatus::Ready } else { SessionStatus::Disconnected };
                self.set_status(session, status);
            }
            self.save_meta(session);
            self.lane_turn_ended(session, false, turn);
            self.inbox_turn_ended(session);
            return;
        }
        let mut e = e.clone();
        crate::recovery::annotate(&mut e, Some(&session.meta().cwd));
        let typed = crate::recovery::fields(&e);
        let mut record =
            json!({"error": e.message, "code": e.code, "turnId": turn_id, "turnSeq": 0});
        if let Some(o) = record.as_object_mut() {
            o.extend(typed.clone());
        }
        self.append(session, "mux", "turn_error", record);
        // `errorText` as a started turn's failure has it: its `lastTurn` and its parent's
        // `turn_ended` say why.
        let mut msg = json!({"status": "failed", "error": e.message, "errorText": e.message, "code": e.code, "turnSeq": 0, "turnId": turn_id, "promptId": prompt_id, "turnCount": turn, "trigger": trigger});
        if let Some(o) = msg.as_object_mut() {
            o.extend(typed);
        }
        self.record_last_turn(session, &msg);
        self.append(session, "mux", "turn_result", msg);
        self.reset_stream(session);
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Disconnected);
        }
        self.save_meta(session);
        // The turn was counted: its lane's parent hears it failed, with no reply of its own
        // (`lane_reports.rs`).
        self.lane_turn_ended(session, false, turn);
        self.inbox_turn_ended(session);
    }

    /// Waits until the inbound loop handled every agent message queued before
    /// now. Bounded: a loop that is gone (closed channel) or stuck never holds
    /// a turn's settlement past the bound.
    pub(super) async fn drain_inbound(session: &Session) {
        let (done, handled) = tokio::sync::oneshot::channel();
        let queued = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            session.inbound_tx.send(crate::agent::Inbound::Barrier(done)),
        )
        .await;
        if matches!(queued, Ok(Ok(()))) {
            let _ = tokio::time::timeout(std::time::Duration::from_secs(5), handled).await;
        }
    }

    /// Keep the outcome of the last turn on the session (`lastTurn` in the
    /// summary), so `wait` can report a failed turn after it resolves.
    pub(super) fn record_last_turn(&self, session: &Session, turn_result: &Value) {
        let mut last = serde_json::Map::new();
        for k in super::views::LAST_TURN_KEYS {
            if let Some(v) = turn_result.get(k) {
                last.insert(k.to_owned(), v.clone());
            }
        }
        last.insert("endedAt".into(), json!(now_ms()));
        for key in ["turnCount", "turnSeq"] {
            if let Some(value) = turn_result.get(key) {
                last.insert(key.into(), value.clone());
            }
        }
        self.lane_report_record_result(&session.id, turn_result);
        if turn_result.get("trigger") != Some(&Value::Bool(true)) {
            session.meta.lock().unwrap().last_turn = Some(Value::Object(last));
        }
        // Every turn's end passes here once: its parent hears it (`subsession_results.rs`).
        self.subsession_turn_ended(session, turn_result);
    }

    /// The profile to fall over to, when the current one names one that exists.
    async fn fallback_profile(&self, session: &Session) -> Option<String> {
        let cfg = self.config.read().await;
        let agent = session.meta().harness;
        let to = cfg.harnesses.get(&agent)?.fallback.clone()?;
        if to == agent || !cfg.harnesses.contains_key(&to) {
            return None;
        }
        Some(to)
    }

    /// Pass a session-scoped request to the child, rewriting the session id.
    pub async fn forward(
        self: &Arc<Self>,
        session: &Arc<Session>,
        m: &str,
        params: Value,
    ) -> Result<Value, RpcError> {
        self.forward_as(session, m, params, false).await
    }

    /// `forward`; `granted`: a paired machine's Full-access setting covers the
    /// request (`crate::pairing`), so only a deny-all policy holds the mode.
    pub(crate) async fn forward_as(
        self: &Arc<Self>,
        session: &Arc<Session>,
        m: &str,
        mut params: Value,
        granted: bool,
    ) -> Result<Value, RpcError> {
        // MDM's off as this switch begins: its one read, which every check below takes, so an off
        // that comes and goes while it waits on the agent still holds for it (reviews 73, 75 and
        // 77 of #23322).
        let off = self.off_latch();
        // The idle pass never ends the harness under a mode change (`idle.rs`).
        self.touch(session);
        let _using = session.harness_use.read().await;
        // Every switch into a mode that skips approvals, from any client (the app, the CLI, a
        // script), passes here: refused while `sessions.allowFullAccess` is off.
        if super::start_mode::requests_full_access(m, &params) && !off.allows_full_access() {
            return Err(super::start_mode::full_access_off());
        }
        // Nor does a switch out of the mode a narrower policy needs (`policy_mode.rs`).
        self.refuse_wider_mode_as(session, m, &params, granted).await?;
        let child = self.child_for(session).await?;
        // Again once the agent is there (its start can take seconds): MDM may have forced full
        // access off since. A push after this ends the agent at the next prompt (`child_for`).
        if super::start_mode::requests_full_access(m, &params) && !off.allows_full_access() {
            return Err(super::start_mode::full_access_off());
        }
        let sid = session
            .meta()
            .agent_session_id
            .ok_or_else(|| RpcError::internal("no agent session"))?;
        if params.is_null() {
            params = json!({});
        }
        params["sessionId"] = Value::String(sid);
        let asked_mode = (m == method::SESSION_SET_MODE)
            .then(|| params.get("modeId").and_then(Value::as_str).map(str::to_owned))
            .flatten();
        // A mode picked through the harness's `mode` option (Claude Code's, or a harness whose
        // mode is only that option).
        let asked_option_mode = (m == method::SESSION_SET_CONFIG_OPTION
            && params.get("configId").and_then(Value::as_str) == Some("mode"))
        .then(|| params.get("value").and_then(Value::as_str).map(str::to_owned))
        .flatten();
        let asked_option = (m == method::SESSION_SET_CONFIG_OPTION)
            .then(|| super::full_access_bound::asked_option(&params))
            .flatten();
        let res = match child.request(m, params).await {
            Ok(v) => v,
            Err(mut e) => {
                // A process that died on this request: quote its last stderr
                // line, as prompt() does, so "agent process closed" says why.
                if e.message == "agent process closed" {
                    let tail: Vec<String> =
                        session.stderr_tail.lock().unwrap().iter().cloned().collect();
                    if let Some(last) = tail.iter().rev().find(|line| explains_exit(line)).cloned()
                    {
                        e.message =
                            format!("agent process closed ({}): {last}", session.meta().harness);
                    }
                }
                return Err(e);
            }
        };
        match m {
            method::SESSION_SET_MODE => {
                // The mode first, then the mark, under the lock, only while the chat runs it:
                // a write that moves the mode takes the mark (`write_mode_state`).
                let reported = res.get("currentModeId").or(res.get("modeId")).cloned();
                if let Some(mode) = reported.or_else(|| asked_mode.clone().map(Value::String)) {
                    self.write_mode_state(session, [ModeWrite::CurrentMode(mode)]);
                }
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                if asked_mode.is_some() && crate::web_modes::mode_of(&meta) == asked_mode {
                    meta.mode_set_by_cmux = asked_mode;
                }
            }
            method::SESSION_SET_CONFIG_OPTION => {
                let mut writes = Vec::new();
                if let Some(opts) = res.get("configOptions") {
                    writes.push(ModeWrite::ConfigOptions(opts.clone()));
                }
                // A bare answer took the value asked (`record_option_answer`).
                super::full_access_bound::record_option_answer(session, &res, asked_option);
                // Claude Code answers a `mode` option with the mode it now runs.
                if asked_option_mode.is_some()
                    && let Some(mode) = res.get("currentModeId").cloned()
                {
                    writes.push(ModeWrite::CurrentMode(mode));
                }
                if !writes.is_empty() {
                    self.write_mode_state(session, writes);
                }
                // A mode picked through its option is cmux's as a `set_mode` one is, once the
                // harness runs it (`trust_wait.rs` `full_access_by_cmux`).
                if let Some(mode) = &asked_option_mode {
                    let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                    if crate::web_modes::mode_of(&meta).as_deref() == Some(mode.as_str()) {
                        meta.mode_set_by_cmux = Some(mode.clone());
                    }
                }
            }
            method::SESSION_SET_MODEL => {
                if let Some(models) = res.get("models") {
                    session.meta.lock().unwrap().models = Some(models.clone());
                }
            }
            _ => {}
        }
        self.save_meta(session);
        // MDM forced full access off while this switch waited on the harness (after both checks
        // above). The mode is written before this reads the off, and the push writes the off
        // before its teardown reads modes (`end_every_managed_full_access`): either way the
        // agent ends.
        if self.managed_off_runs_full_access(&off, session) {
            let _spawning = session.spawn_lock.lock().await;
            self.end_if_runs_full_access(session, true).await;
            return Err(super::start_mode::full_access_off());
        }
        if m == method::SESSION_SET_MODE
            || (m == method::SESSION_SET_CONFIG_OPTION && asked_option_mode.is_some())
        {
            self.approve_pending_tools(session).await;
        }
        Ok(res)
    }

    pub async fn set_mode(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mode_id: &str,
    ) -> Result<Value, RpcError> {
        self.set_mode_as(session, mode_id, false).await
    }

    /// `set_mode`; `granted` as in `forward_as`.
    pub(crate) async fn set_mode_as(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mode_id: &str,
        granted: bool,
    ) -> Result<Value, RpcError> {
        let r = self
            .forward_as(session, method::SESSION_SET_MODE, json!({"modeId": mode_id}), granted)
            .await?;
        self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode_id))]);
        self.append(session, "mux", "mode", json!({"modeId": mode_id}));
        self.save_meta_answered(session)?;
        Ok(r)
    }

    pub async fn set_config(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
    ) -> Result<Value, RpcError> {
        self.set_config_as(session, config_id, value, false).await
    }

    /// `set_config`; `granted` as in `forward_as`.
    pub(crate) async fn set_config_as(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
        granted: bool,
    ) -> Result<Value, RpcError> {
        // Make sure the child is up so its option list is known, then map
        // portable names (effort) onto the harness's own id.
        let _ = self.child_for(session).await?;
        let config_id = resolve_config_id(&session.meta(), config_id);
        let config_id = config_id.as_str();
        let r = self
            .forward_as(
                session,
                method::SESSION_SET_CONFIG_OPTION,
                json!({"configId": config_id, "value": value}),
                granted,
            )
            .await?;
        self.append(session, "mux", "config", json!({"configId": config_id, "value": value}));
        {
            let mut applied =
                session.applied.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(effort) = super::start_defaults::effort_of(config_id, &value) {
                applied.effort = Some(effort.to_owned());
            }
        }
        Ok(r)
    }

    pub async fn set_model(
        self: &Arc<Self>,
        session: &Arc<Session>,
        model_id: &str,
    ) -> Result<Value, RpcError> {
        // A harness that takes its model on the command line or in env
        // gets it at the next spawn: record it and drop the current process.
        // Same test as `new_session`: the profile, its defaults' env, or the
        // session's preset env may carry `${model}`.
        let at_spawn = {
            let cfg = self.config.read().await;
            let meta = session.meta();
            let in_env = |env: &std::collections::BTreeMap<String, String>| {
                env.values().any(|v| v.contains("${model}"))
            };
            cfg.profile(&meta.harness)
                .map(super::lifecycle::profile_takes_model_at_spawn)
                .unwrap_or(false)
                || in_env(&cfg.defaults_for(&meta.harness).env)
                || meta
                    .preset
                    .as_ref()
                    .and_then(|n| cfg.presets.get(n))
                    .map(|p| in_env(&p.env) || p.args.iter().any(|a| a.contains("${model}")))
                    .unwrap_or(false)
        };
        if at_spawn {
            session.meta.lock().unwrap().model_request = Some(model_id.to_owned());
            self.save_meta_answered(session)?;
            self.detach_child(session).await;
            self.append(session, "mux", "model", json!({"modelId": model_id, "atSpawn": true}));
            super::start_defaults::model_applied(session, model_id);
            return Ok(json!({}));
        }
        // Prefer the config option named "model" when the agent exposes one.
        let has_model_option = session
            .meta()
            .config_options
            .as_ref()
            .and_then(Value::as_array)
            .map(|opts| opts.iter().any(|o| o.get("id").and_then(Value::as_str) == Some("model")))
            .unwrap_or(false);
        if has_model_option {
            let meta = session.meta();
            let option = meta
                .config_options
                .as_ref()
                .and_then(Value::as_array)
                .and_then(|opts| opts.iter().find(|o| o["id"] == "model"))
                .unwrap();
            let value = Value::String(
                crate::model_catalog::resolve(option, model_id)
                    .map_err(RpcError::invalid_params)?,
            );
            let r = self.set_config(session, "model", value).await?;
            super::start_defaults::model_applied(session, model_id);
            return Ok(r);
        }
        let r =
            self.forward(session, method::SESSION_SET_MODEL, json!({"modelId": model_id})).await?;
        self.append(session, "mux", "model", json!({"modelId": model_id}));
        super::start_defaults::model_applied(session, model_id);
        // The harness runs this model now, also when its reply lists no models.
        let reported = match session.meta.lock().unwrap().models.as_mut() {
            Some(Value::Object(models)) => {
                models.insert("currentModelId".into(), json!(model_id));
                true
            }
            _ => false,
        };
        if reported {
            self.save_meta_answered(session)?;
        }
        Ok(r)
    }

    pub async fn rename(&self, session: &Arc<Session>, name: String) -> Result<(), RpcError> {
        if self
            .sessions
            .lock()
            .unwrap()
            .values()
            .any(|s| s.id != session.id && s.meta().name == name)
        {
            return Err(RpcError::invalid_params(format!("session name {name:?} is taken")));
        }
        let old = {
            let mut m = session.meta.lock().unwrap();
            // A chat renamed before it was titled asks no model for a title (`titles.rs`).
            super::titles::title_renamed(&mut m);
            m.name_given = true;
            std::mem::replace(&mut m.name, name.clone())
        };
        self.append(session, "mux", "renamed", json!({"from": old, "to": name}));
        self.save_meta_answered(session)?;
        Ok(())
    }

    /// Stop the child. The log stays. `purge` also deletes the log.
    pub async fn kill(&self, session: &Arc<Session>, purge: bool) -> Result<(), RpcError> {
        // An idle pass under way ends first; none starts while this stop runs (`idle.rs`).
        let using = session.harness_use.read().await;
        self.kill_held(session, purge, using).await
    }

    /// `kill`, with `_using`, a lease of `harness_use` (shared, or exclusive for a conditional
    /// stop, `stop_if_idle.rs`), held until the session is closed.
    pub(super) async fn kill_held(
        &self,
        session: &Arc<Session>,
        purge: bool,
        _using: impl Send,
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
        // Counted first: a start for a request from before this stop ends (`ensure_child`).
        session.stops.fetch_add(1, Ordering::SeqCst);
        session.closing.store(true, Ordering::SeqCst);
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
            // A host whose link was lost cannot take a Terminate frame.
            if link_lost {
                self.end_unadopted_host(session).await;
            }
        } else {
            // A host this daemon could not adopt keeps running until the user
            // ends the session: end it without its protocol (frozen path).
            self.end_unadopted_host(session).await;
        }
        *session.turn.lock().unwrap() = None;
        // Before the close's event, which sends the cards it owes (`tasks.rs`).
        self.orphan_tasks_of(session, purge);
        self.set_status(session, SessionStatus::Closed);
        // Its inbox's timer stops and its senders are answered (`inbox.rs`).
        self.inbox_closed(session);
        // A lane link either end of which closes is retired (`lane_reports.rs`).
        self.lane_retire(&session.id);
        // The session's Claude Code MCP config holds the helper token.
        crate::agent_tools::remove_mcp_config(&crate::config::home(), &session.id);
        if purge {
            super::watches::before_purge(self, &session.id).await?;
            // Its background tasks end with it (`bg_tasks.rs`); a stop keeps them.
            self.bg_purge(session).await?;
            session.purged.store(true, Ordering::SeqCst);
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
            // Tell watchers (peers, TUIs) the session is gone.
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
            });
            self.store.delete(&session.id).map_err(|e| RpcError::internal(e.to_string()))?;
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
                let _ =
                    tokio::task::spawn_blocking(move || super::file_uploads::remove_session(&id))
                        .await;
            }
            // No awaits follow unregistering: a fixed-ID creator may now publish.
            let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            if sessions.get(&session.id).is_some_and(|current| Arc::ptr_eq(current, session)) {
                sessions.remove(&session.id);
            }
        }
        Ok(())
    }

    /// Stop the child but keep the session resumable.
    pub async fn detach_child(&self, session: &Arc<Session>) {
        // A shutdown that hands this agent to the next daemon began: the agent, its turn and its
        // permission prompts are that daemon's (`shutdown.rs`). Read under the child lock, held
        // until the agent is gone: the shutdown takes it only after it began, so it finds either
        // this detach done or nothing of it.
        let mut slot = session.child.lock().await;
        if self.hands_off(session) {
            return;
        }
        // Held through the agent's end, so no new agent starts beside the one ending; a shutdown
        // that meets the lock meanwhile waits for this end (`detaching`).
        session.detaching.store(true, Ordering::SeqCst);
        self.revoke_permission_chat(session);
        self.cancel_pending_permissions(session);
        if let Some(child) = slot.take() {
            child.kill().await;
        }
        session.detaching.store(false, Ordering::SeqCst);
        drop(slot);
        // Its next start runs the profile as it is now (`profile_respawn.rs`).
        self.settle_profile_respawn(session);
        *session.turn.lock().unwrap() = None;
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
    }
}

/// Clears `Session::ending` once `finish_turn` leaves, however it leaves, and wakes a shutdown
/// waiting for ends under way (`shutdown.rs` `settle_ends`).
struct EndUnderWay<'a> {
    hub: &'a Hub,
    session: &'a Session,
    turn_id: &'a str,
}

impl EndUnderWay<'_> {
    fn clear(&self) {
        let mut ending = self.session.ending.lock().unwrap_or_else(|e| e.into_inner());
        if ending.as_ref().is_some_and(|t| t.turn_id == self.turn_id) {
            *ending = None;
        }
        drop(ending);
        self.hub.ends_moved.notify_waiters();
    }
}

impl Drop for EndUnderWay<'_> {
    fn drop(&mut self) {
        self.clear();
    }
}

/// Clears `slot` when it names `turn_id`; whether it did.
fn take_if_turn(slot: &StdMutex<Option<String>>, turn_id: &str) -> bool {
    let mut slot = slot.lock().unwrap_or_else(|e| e.into_inner());
    if slot.as_deref() == Some(turn_id) {
        *slot = None;
        true
    } else {
        false
    }
}
