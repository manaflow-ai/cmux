//! Part of `Hub`; see `hub/mod.rs`.

use super::auto_resume::RefusedRules;
use super::exit_reason::explains_exit;
use super::transcript::REPLAY_CHARS;
use super::*;
use crate::close_why::{CloseActor, CloseRecord, CloseWhy};
use std::sync::atomic::Ordering;
use std::time::Duration;

use super::message_events::{
    embed_message_context, ensure_message_provenance, keep_message, message_context,
    name_kept_message, name_message, record_message_context,
};

mod close;
mod controls;
mod finish;
mod prompt_entry;

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

/// The project's folder of PDFs saved for agents, `<cwd>/.cmux/attachments` (it holds one folder
/// per chat and a `.gitignore`).
fn pdf_attachments_root(cwd: &Path) -> PathBuf {
    cwd.join(".cmux").join("attachments")
}

/// Session `id`'s folder of PDFs under `root` (`<cwd>/.cmux/attachments`); none for an id that is
/// not one plain path component.
fn pdf_attachments_dir(root: &Path, id: &str) -> Option<PathBuf> {
    let plain =
        !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| root.join(id))
}

/// Deletes the PDFs session `id` saved in its project (`acp_prompt_blocks`): the chat was
/// deleted. They were never removed, so every PDF sent to a deleted chat stayed in the project.
/// Never follows a symlink (`remove_dir_all` removes the link). Blocking: run it off the runtime.
pub(super) fn remove_pdf_attachments(cwd: &Path, id: &str) {
    let Some(dir) = pdf_attachments_dir(&pdf_attachments_root(cwd), id) else {
        return;
    };
    match crate::home_fs::remove_dir_all(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::warn!(session = id, "PDF attachments not deleted: {e}"),
    }
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
        let root = pdf_attachments_root(&session.meta().cwd);
        // The chat's own folder, so deleting the chat deletes its PDFs (`remove_pdf_attachments`).
        let dir = pdf_attachments_dir(&root, &session.id).ok_or_else(|| {
            RpcError::internal("cannot create PDF attachment directory: bad session id")
        })?;
        crate::home_fs::create_dirs(&dir).map_err(|e| {
            RpcError::internal(format!("cannot create PDF attachment directory: {e}"))
        })?;
        // The folder sits in the user's project; keep it out of their commits.
        let ignore = root.join(".gitignore");
        if !ignore.exists() {
            let _ = crate::home_fs::write(&ignore, "*\n");
        }
        let path = dir.join(format!("{}-{safe_name}", uuid::Uuid::now_v7()));
        let encoded = block.get("data").and_then(Value::as_str).unwrap_or("");
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|e| RpcError::invalid_params(format!("invalid PDF attachment: {e}")))?;
        crate::home_fs::write(&path, bytes)
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

/// The turn a pending run of `prompt_id` was given on `session`, and whether it still waits in
/// the queue: the queued prompt's, or the running turn's. None while that run has not been
/// accepted (its agent still starts, a check still runs, also one after its turn shows: a
/// Cloud turn's claim can still refuse it), or between its leaving the queue and its turn's
/// start.
fn pending_turn(session: &Session, prompt_id: &str) -> Option<(String, bool)> {
    let queued = {
        let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        queue.iter().find(|q| q.prompt_id == prompt_id).map(|q| (q.turn_id.clone(), true))
    };
    queued.or_else(|| {
        let turn = session.turn.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        turn.as_ref()
            .filter(|t| t.prompt_id == prompt_id && t.accepted)
            .map(|t| (t.turn_id.clone(), false))
    })
}

/// How many recent first-run acceptances a session keeps for resends (`Session::accepted_prompts`).
pub(super) const KEPT_ACCEPTS: usize = 512;

fn outcome_token(outcome: &PromptOutcome) -> usize {
    Arc::as_ptr(outcome) as usize
}

/// Return the existing outcome, or create a new attempt and retire any receipt for an
/// older attempt with the same client id. The ledger is bounded and can forget a completed
/// outcome while the larger acceptance cache still remembers it; leaving that receipt live
/// would make a new attempt look like a duplicate of the old one.
fn begin_outcome(
    session: &Session,
    prompt_id: &str,
) -> Result<PromptOutcome, (usize, tokio::sync::watch::Receiver<Option<Result<Value, RpcError>>>)> {
    let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
    match ledger.iter().find(|(id, _)| id == prompt_id) {
        Some((_, outcome)) => Err((outcome_token(outcome), outcome.subscribe())),
        None => {
            // A pending outcome cannot be pruned, so this only retires a receipt whose
            // original outcome is already complete.
            session
                .accepted_prompts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .retain(|(id, _, _)| id != prompt_id);
            session.pending_acceptances.lock().unwrap_or_else(|e| e.into_inner()).remove(prompt_id);
            let outcome = Arc::new(tokio::sync::watch::channel(None).0);
            ledger.push_back((prompt_id.to_owned(), outcome.clone()));
            Ok(outcome)
        }
    }
}

/// Keeps the acceptance `v` of client prompt id `prompt_id`'s first run, for a resend of it.
fn keep_acceptance(session: &Session, prompt_id: &str, v: &Value) {
    let Some((token, pending)) = session
        .prompts
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .find(|(id, _)| id == prompt_id)
        .map(|(_, outcome)| (outcome_token(outcome), outcome.borrow().is_none()))
    else {
        return;
    };
    if pending {
        session
            .pending_acceptances
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(prompt_id.to_owned(), (token, v.clone()));
    } else {
        session.pending_acceptances.lock().unwrap_or_else(|e| e.into_inner()).remove(prompt_id);
    }
    {
        let mut kept = session.accepted_prompts.lock().unwrap_or_else(|e| e.into_inner());
        kept.retain(|(id, _, _)| id != prompt_id);
        kept.push_back((prompt_id.to_owned(), token, v.clone()));
        while kept.len() > KEPT_ACCEPTS {
            kept.pop_front();
        }
    }
    session.accepted_seq.send_modify(|n| *n = n.wrapping_add(1));
}

/// Release the overflow receipt once its prompt outcome settles. The token check keeps a late
/// completion from deleting a newer attempt with the same client prompt id.
pub(super) fn release_acceptance(session: &Session, prompt_id: &str, outcome: &PromptOutcome) {
    let token = outcome_token(outcome);
    let mut pending = session.pending_acceptances.lock().unwrap_or_else(|e| e.into_inner());
    if pending.get(prompt_id).is_some_and(|(kept, _)| *kept == token) {
        pending.remove(prompt_id);
    }
}

/// The acceptance a resend of `prompt_id` answers with: the first run's own (kept as it was
/// accepted), or its place in the queue or its turn (a prompt restored after a restart, accepted
/// by an earlier daemon). Waits while the first run is neither accepted nor ended; None once it
/// ended unaccepted (refused before it was taken: its answer says why).
async fn first_acceptance(
    session: &Session,
    prompt_id: &str,
    token: usize,
    first: &mut tokio::sync::watch::Receiver<Option<Result<Value, RpcError>>>,
) -> Option<Value> {
    let mut seq = session.accepted_seq.subscribe();
    loop {
        seq.borrow_and_update();
        let kept = {
            let _ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
            let kept = session
                .accepted_prompts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .rev()
                .find(|(id, kept_token, _)| id == prompt_id && *kept_token == token)
                .map(|(_, _, v)| v.clone());
            kept.or_else(|| {
                session
                    .pending_acceptances
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .get(prompt_id)
                    .filter(|(pending_token, _)| *pending_token == token)
                    .map(|(_, v)| v.clone())
            })
        };
        if kept.is_some() {
            return kept;
        }
        if let Some((turn, queued)) = pending_turn(session, prompt_id) {
            return Some(json!({"turnId": turn, "queued": queued}));
        }
        if first.borrow().is_some() {
            return None;
        }
        tokio::select! {
            changed = first.changed() => if changed.is_err() { return None },
            _ = seq.changed() => {}
        }
    }
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

    /// A prompt's setup up to its acceptance, bounded (`prompt_admission.rs`): it waits for admission
    /// and holds it a bounded time, and a prompt someone waits on that has no answer by its due
    /// time goes into the queue durably, accepted as queued, its setup dropped. A prompt the
    /// queue holds already takes no admission.
    async fn run_prompt_joined(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        mut opts: PromptOptions,
        joined: &super::digest::DigestTurn,
    ) -> Result<Value, RpcError> {
        if Self::queue_holds(session, opts.prompt_id.as_deref()) {
            let admission = super::prompt_admission::Admission::none(session);
            return self
                .run_prompt_admitted(session, blocks, client, steer, opts, joined, &admission)
                .await;
        }
        use super::prompt_admission::{Admission, Stage, Unanswered};
        let unanswered = Unanswered::of(&blocks, client, &mut opts);
        let admission = opts.admission.take().unwrap_or_else(|| Admission::new(session));
        let mut setup = Box::pin(async {
            admission.acquire(session, &self.scope).await;
            self.run_prompt_admitted(session, blocks, client, steer, opts, joined, &admission).await
        });
        let Some(unanswered) = unanswered else {
            return setup.await;
        };
        if matches!(unanswered, Unanswered::Defer(_) | Unanswered::Guarded(_)) {
            admission.listen();
        }
        tokio::select! {
            biased;
            answer = &mut setup => return answer,
            () = tokio::time::sleep_until(admission.answer_due()) => {}
        }
        // Past a step it must finish, it finishes: its answer is on its way.
        if admission.committed() {
            return setup.await;
        }
        let stage = admission.stage_now();
        // Cancel a pending wait before charging the queue. If setup owns the turn,
        // keep its lock until the durable row is in place ahead of later arrivals.
        let claimed_setup = matches!(stage, Stage::DirectDispatch).then(move || setup);
        admission.release();
        let outcome = match unanswered {
            Unanswered::Defer(deferral) => {
                self.queue_unanswered(session, deferral, stage, || drop(claimed_setup))?
            }
            Unanswered::Guarded(guard) => {
                guard()?;
                return Err(super::auto_resume::retry_turn::busy());
            }
            Unanswered::Busy => return Err(super::auto_resume::retry_turn::busy()),
            Unanswered::SteerUnavailable => return Err(super::turn_cap::steer_unavailable(false)),
        };
        let mut answer = outcome.subscribe();
        self.start_restored(session);
        let dropped = || RpcError::internal("the queued run of this prompt was dropped");
        let settled = answer.wait_for(Option::is_some).await.map_err(|_| dropped())?.clone();
        settled.unwrap_or_else(|| Err(dropped()))
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_prompt_admitted(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: Vec<Value>,
        client: &str,
        steer: bool,
        mut opts: PromptOptions,
        joined: &super::digest::DigestTurn,
        admission: &super::prompt_admission::Admission,
    ) -> Result<Value, RpcError> {
        // Each prompt's setup is ordered by its admission (`prompt_admission.rs`): resolving an
        // uploaded block can block in a worker, and a later prompt must not claim the chat while
        // the earlier one is still on its way to the queue. It is let go when the prompt is
        // accepted (a queued one is accepted inside `queue_slot` and then waits there for the
        // whole turn ahead of it: held that long, the next prompt would never queue), at the
        // latest right after `queue_slot`, and in any case when its lease lapses.
        let admitted = || admission.release();
        #[cfg(test)]
        {
            let seam = self.prompt_admission_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // Stop can arrive during dispatch setup, before session.turn is installed. Keep
        // that epoch through the write checks instead of sampling it after startup.
        let mut cancels = session.cancels.load(Ordering::SeqCst);
        let prompt_id = opts.prompt_id.take().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        // A held agent message released, or a queued one sent now, may still name its uploads.
        let mut blocks = blocks;
        let web = opts.control == Control::Web;
        // Capture this before guard validation: a stop racing the final setup fence must
        // still prevent the prompt from starting.
        let stops = session.stops.load(Ordering::SeqCst);
        admission.enter("uploads");
        crate::prompt_uploads::resolve_off_runtime(&session.id, web, &mut blocks).await?;
        if let Some(guard) = opts.race_guard.as_ref() {
            guard()?;
        }
        // A stop after this prompt came ends the agent start it waits on (`ensure_child`).
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
        // A held chat keeps what is not the person's in its inbox, with no turn
        // (`session_hold.rs`); else the surge may hold it.
        let held = match self.hold_for_session_hold(session, &prompt_id, client, &blocks, &opts)? {
            Some(receipt) => Some(receipt),
            None => self.hold_surge_message(session, &prompt_id, client, &blocks, &opts)?,
        };
        if let Some(receipt) = held {
            if let Some(accept) = opts.on_accepted.take() {
                accept(receipt.clone());
            }
            return Ok(json!({"stopReason":"end_turn","_meta":{"acpmux":receipt}}));
        }
        let mut on_accepted = self.with_host_pressure(opts.on_accepted);
        // The prompts this one replaced (`supersede.rs`), named in its acceptance: set where it
        // is committed (queued, started, or steered in), never before a refusal.
        let supersede = opts.supersede.clone();
        let replaced = std::sync::OnceLock::<Vec<String>>::new();
        // Another agent's message queued as the running turn crosses its cap still gets the
        // turn its notice (`turn_cap.rs`): the timer may have looked at the queue just before.
        // An unclassified notice is informational by default, so use its effective class for
        // cap checks and routing before any path can treat it as a result.
        let notice_class = super::inbox::is_notice(opts.provenance.as_ref())
            .then_some(crate::prompt_class::PromptClass::Fyi);
        let effective_class = opts.class.or(notice_class);
        let fyi = effective_class == Some(crate::prompt_class::PromptClass::Fyi);
        let from_agent =
            super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref()).is_some()
                && !opts.send_now;
        let race_guard = opts.race_guard.clone();
        // The name the target was given (`session_handle.rs`), in its acceptance, so the
        // sender's "Sent to" line names it as people do.
        let given =
            session.read_meta(|m| m.handle.clone()).filter(|h| crate::session_handle::valid(h));
        let mut accept = |mut v: Value| {
            admission.commit();
            admitted();
            if let Some(race_guard) = race_guard.as_ref()
                && let Err(error) = race_guard()
            {
                v = json!({"raceCancelled": true, "error": error.message});
            }
            if let (Some(given), Some(obj)) = (given.as_ref(), v.as_object_mut())
                && obj.contains_key("sessionId")
            {
                obj.entry("displayName").or_insert_with(|| json!(given));
            }
            if let Some(f) = on_accepted.take() {
                if supersede.is_some() {
                    super::queue::supersede::mark(&mut v, replaced.get());
                }
                let queued = v.get("queued") == Some(&Value::Bool(true));
                f(v);
                if queued && from_agent && !fyi {
                    self.turn_cap_recheck(session);
                }
            }
        };
        // Another agent's message goes into the chat's inbox, never a turn or a steer of its own
        // (`inbox.rs`). It can be accepted even while startup holds the child lock.
        let route = self.inbox_route(
            session,
            &prompt_id,
            &blocks,
            control,
            opts.send_now,
            effective_class,
            opts.provenance.as_ref(),
            opts.agent.as_deref(),
            opts.inbox,
        );
        // Held until this prompt ends: its turn, or its refusal (`inbox.rs`).
        let first_work = match route {
            super::inbox::Route::First(first) => Some(first),
            super::inbox::Route::Plain => None,
            super::inbox::Route::Inbox(agent, class) => {
                admission.enter("inbox");
                // The inbox's acceptance callback commits this delivery after its journal write.
                return Box::pin(self.inbox_accept(
                    session,
                    &blocks,
                    client,
                    &prompt_id,
                    &agent,
                    class,
                    opts.thread.as_deref(),
                    opts.provenance.as_ref(),
                    opts.human_authenticated,
                    opts.wake_or_fail,
                    opts.reply_reader.clone(),
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
                // Queue admission is let go first: held, it alone would keep every other prompt
                // out while this one waits, and `first_work_tests.rs` checks that the first
                // work's own hold (`inbox.rs`) keeps notices and the delegator right without it.
                admitted();
                let _ = arrived.send(());
                let _ = release.await;
            }
        }
        // A prompt that cannot reach any agent (none running, and its folder or harness is gone)
        // is refused before it is recorded (`cold_prompt_check`, after steer-only's refusal).
        admission.enter("agent");
        // Release the child mutex before probing the host. A delivery awaiting acceptance
        // stays in setup until the enclosing answer deadline queues it durably. Treating a
        // timed-out probe as live here would publish "started" before dispatch can proceed.
        // Restored/daemon prompts have no acceptance waiter; bound their probe separately.
        let probe = async {
            let child = session.child.lock().await.clone();
            match child {
                Some(child) => child.is_alive().await,
                None => false,
            }
        };
        let live = if admission.queue_due().is_some() {
            probe.await
        } else {
            tokio::time::timeout(super::prompt_admission::ADMISSION_BOUND, probe)
                .await
                .unwrap_or(true)
        };
        let text = prompt_text(&blocks);
        let running = session.turn();
        // Another agent's message to a turn past its cap waits for the next turn (`turn_cap.rs`).
        let capped = running.is_some()
            && !opts.send_now
            && self.turn_cap_holds(session, opts.provenance.as_ref(), opts.agent.as_deref(), fyi);
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
        // person's own steer and Send now still go in; an inbox digest does not (its drain never
        // asks to steer then, `inbox_digest.rs`; this holds one whose prompt came after the
        // drain). Checked again as the steer is written (`steer_end.rs`).
        let prompt_held =
            from_agent && running.is_some() && super::inbox::persons_prompt_waits(session);
        // Other agents wait until the person's own turn ends; family replies, and the reports
        // of the chat's own lanes (`lane_reports.rs`), still enter it.
        let persons_held = from_agent
            && running.as_ref().is_some_and(|t| t.persons)
            && !super::digest::inbox_digest::is_digest(opts.provenance.as_ref())
            && !super::subsession_guard::is_family_prompt(opts.provenance.as_ref())
            && !self.own_lane_report(session, opts.provenance.as_ref());
        // The person's own steer goes into any running turn, one another agent's message started
        // too (Leo, 2026-11-05: "WHY THE FUCK ARE MY MESSAGES BEING QUEUED INSTEAD OF STEERING").
        let trigger = crate::prompt_provenance::is_trigger(opts.provenance.as_ref());
        let trigger_held = trigger || running.as_ref().is_some_and(|t| t.trigger);
        if steer
            && opts.steer_only
            && opts.interrupt_turn.as_deref().is_some_and(|expected| {
                running.as_ref().is_none_or(|turn| turn.turn_id != expected)
            })
        {
            return Err(super::turn_cap::steer_unavailable(capped));
        }
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
            admission.enter("cold_check");
            self.cold_prompt_check(session).await?;
        }
        if steer_now && session.moving().is_some() {
            return Err(super::queue::moving_error(session));
        }
        // Who sent it, as the queue knows its prompts' senders (`digest.rs`).
        let agent = super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref());
        // What it asks of this chat: another agent's only, `result` when it named none.
        let class = crate::prompt_class::of_message(effective_class, agent.is_some());
        // A question no caller reads the reply of, from a session that did not start this chat
        // and that the inbox did not take: its reply goes back when the turn that answers it ends
        // (`question_replies.rs`). It is due under this prompt until its turn is known: its steer
        // is written into the running turn (`steer_end.rs`), or its own turn starts (below).
        // Dropped with this request when neither happened.
        let _reply_due = {
            let provenance = opts.provenance.as_ref();
            let subagent = provenance
                .and_then(|p| p.get(crate::prompt_provenance::FROM_SUBAGENT))
                .filter(|s| s.is_object())
                .cloned();
            let reads = opts.reply_reader.is_some() || opts.wake_or_fail;
            let asker = super::question_replies::asker_of(provenance);
            self.question_reply_pending(session, &prompt_id, asker, subagent, class, reads)
        };
        if steer_now {
            if cloud_turn.is_some() {
                return Err(RpcError::invalid_params(
                    "a captured cloud turn cannot steer another turn",
                ));
            }
            let turn_id = running.map(|t| t.turn_id).unwrap_or_default();
            let steer_id = prompt_id.clone();
            // Steer setup can still wait on the child or family gate. Its first write and
            // acceptance happen together, and the acceptance callback commits the admission.
            admission.enter("steer");
            let opts = PromptOptions { prompt_id: Some(prompt_id), on_accepted: None, ..opts };
            // Boxed: the steer's future stays out of this one, which every prompt's caller holds
            // on its stack (a debug build's test thread has little room).
            let steered =
                Box::pin(self.steer_turn(session, blocks, client, &turn_id, opts, &mut accept))
                    .await;
            // A steer refused or taken back unread answers no question in that turn.
            if steered.is_err() {
                self.question_replies_settled(session, &steer_id, false);
            }
            return steered;
        }
        // An automatic continuation runs only while its chat still ends on the cut turn: no await
        // from here to `queue_slot`'s choice, so it never joins the queue (`auto_resume.rs`).
        let after_turn = opts.after_turn.clone();
        let fired = opts.fired;
        super::auto_resume::check_cut(
            session,
            after_turn.as_deref(),
            false,
            opts.provenance.as_ref(),
        )?;
        // The person's steer to an agent that steers, sent while no turn showed yet: another
        // prompt holds the turn and is still starting (its agent spawning, its uploads read), so
        // this one queues behind it, and steers in once that turn shows (`queue.rs`
        // `queue_turn`). Two prompts sent close together never leave the second waiting for the
        // whole turn (Leo, 2026-11-14: "but all my things should be steer by default in the
        // app?").
        let steer_on_start = steer
            && running.is_none()
            && !from_agent
            && !trigger
            && session.steering.load(Ordering::SeqCst)
            && after_turn.is_none()
            && !opts.no_queue;
        // Queued behind the running turn (and the queue) it waits for its turn (`queue.rs`).
        let slot = super::queue::Slot {
            text: &text,
            blocks: &blocks,
            display_parts: opts.display_parts.as_ref(),
            client,
            prompt_id: &prompt_id,
            control,
            cloud_mobile: opts.cloud_mobile,
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
            steer_on_start,
            answer_due: admission.queue_due(),
        };
        // A prompt the queue already holds (restored after a restart or a move, `queue.rs`
        // `start_restored`) has its place and is not accepted again: it lets the order go
        // before it waits for its turn.
        if session
            .restored
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .any(|(id, _)| *id == prompt_id)
        {
            admitted();
        }
        admission.enter("queue");
        let (turn_id, waiting, mut guard, run) =
            match self.queue_slot(session, slot, &mut accept).await {
                Ok(slot) => slot,
                Err(done) => return done,
            };
        if !waiting {
            admission.claimed_direct_turn();
        }
        admitted();
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
        if let Err(e) = super::auto_resume::check_cut(
            session,
            after_turn.as_deref(),
            waiting,
            run.provenance.as_ref(),
        )
        // Its queue entry's provenance: an edit made it the person's, a restart restored it.
        .and_then(|()| super::goal_tools::check_goal_mark(session, run.provenance.as_ref()))
        {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        // What its queue entry holds now (`queue_edit.rs` may edit a prompt that waited).
        let (mut blocks, control, trust_gate, cloud_mobile) =
            (run.blocks.clone(), run.control, run.trust_gate, run.cloud_mobile);
        // What a turn the store refuses on a full disk goes on under (`auto_resume/disk_wait.rs`).
        let refused_prompt_text = super::session::prompt_text(&run.blocks);
        let rules = RefusedRules {
            control,
            trust_gate,
            from: run
                .provenance
                .as_ref()
                .filter(|p| super::subsession_guard::is_family(Some(p)))
                .and_then(|p| p["from"].as_str()),
            slash: super::auto_resume::resent_command(&refused_prompt_text),
            goes_on: !crate::prompt_provenance::is_trigger(run.provenance.as_ref())
                && !super::idle::cache_compact::is_own(run.provenance.as_ref())
                && !super::cold_wake::is_own(run.provenance.as_ref()),
        };
        // A queued prompt restored from the log may still name its uploads (`prompt_uploads.rs`).
        let web = control == Control::Web;
        let read = crate::prompt_uploads::resolve_off_runtime(&session.id, web, &mut blocks).await;
        if let Err(e) = read {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        let install_turn = self.harness_turn(session).await;
        let device = run.full_access_device.clone();
        let mut display_parts = run.display_parts.clone();
        // A pushed forum rule whose key moved on while it waited tells the current one.
        let mut provenance = run.provenance.clone();
        let pushed = self.forum_refresh_push(&prompt_id, &mut blocks, &mut provenance);
        if let Err(e) = self
            .check_dispatch(
                session,
                control,
                cloud_mobile,
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
        // Its line, masked once: the `turn_started` record below takes this masked line when
        // its own line is the same (`shown`), so a prompt pays one secret scan, not three.
        let shown_src = super::prompt_line::prompt_line(&text, client, provenance.as_ref());
        let mut turn =
            TurnInfo::prompted_as(client, &text, &turn_id, &prompt_id, control, &shown_src)
                .noticed(super::prompt_line::is_notice(provenance.as_ref()))
                .by_person(persons);
        let mut shown = (shown_src, turn.masked_preview.clone());
        turn.trigger = trigger;
        // Its sender, set with the turn so no steer and no read sees the turn without it.
        turn.device = run.full_access_device.clone().filter(|_| control == Control::Web);
        // A queued prompt was accepted when it was queued; any other is, once its checks pass.
        turn.accepted = waiting;
        // Before the turn shows: a Stop from then on fences its unwritten prompt (`cancel.rs`).
        *session.unwritten_prompt.lock().unwrap_or_else(|e| e.into_inner()) =
            Some((turn_id.to_string(), false));
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
            let origin = cmux_cloud_client::backend::platform_origin_env()
                .ok_or_else(|| RpcError::invalid_params("Cloud platform is not configured"))?;
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
        // Admission can wait through queueing and dispatch checks. A cancelled race
        // must refuse the prompt itself, not merely change its acceptance response.
        if let Some(race_guard) = race_guard.as_ref()
            && let Err(e) = race_guard()
        {
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        // After publishing the turn, finish its journal entry and acceptance together.
        // Until here a stalled direct dispatch can still release its speculative claim.
        admission.commit();
        if let Err(e) =
            self.start_turn(session, after_turn.as_deref(), fired, no_queue, retry, turn)
        {
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
        // Nor does any parent take one once a shutdown began: no agent may start from then on
        // (`shutdown.rs`), and the shutdown sets that before it ends the lane turns it cuts.
        let refused = if super::queue::refuses_closing_run(session, run.provenance.as_ref()) {
            Some(super::queue::closing_error())
        } else if super::queue::is_lane_report(run.provenance.as_ref()) && self.shutting_down() {
            Some(super::shutdown::shutting_down_error())
        } else {
            None
        };
        if let Some(e) = refused {
            *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = None;
            self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
            drop(guard);
            return Err(e);
        }
        #[cfg(test)]
        {
            let seam = self.turn_shown_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some((arrived, release)) = seam {
                let _ = arrived.send(());
                let _ = release.await;
            }
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
        // The message that leads it goes back with them when the account's limit refuses the
        // turn before its model read it (`digest.rs` `requeue_unread`).
        joined.lead(&prompt_id, client, &run);
        // This turn answers the questions its prompt and the joined ones carry
        // (`question_replies.rs`).
        for id in std::iter::once(&prompt_id).chain(parts.iter().map(|part| &part.prompt_id)) {
            self.question_reply_in_turn(session, id, &turn_id);
        }
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
            // The person's prompts a hold gathered stay the person's words (`person_hold.rs`).
            let blocks = if run.agent.is_none() {
                super::person_hold::person_blocks(&parts)
            } else {
                provenance = Some(super::digest::digest_provenance(&parts));
                super::digest::digest_blocks(&parts)
            };
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
            shown = (line.clone(), t.masked_preview.clone());
        }
        let mut draft_sent = false;
        {
            let mut m = session.meta.lock().unwrap();
            if !trigger {
                m.last_prompt = Some(short_text(&line, 200));
                draft_sent = drafts::clear_sent_draft(&mut m, &text);
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
            // One shared turn path applies the creation snapshot exactly once, including
            // queued/CLI prompts. A settings edit never changes an already-created chat. The
            // rules on a system-level channel are not in it: the spawn gives them
            // (`context_inventory::launch_args`). Appended, never put first: a client's display
            // parts name the person's blocks by index.
            if !m.cmux_context_delivered && control != Control::Web {
                crate::context_inventory::append_snapshot(m.cmux_context.as_deref(), &mut blocks);
            }
            m.turn_count += 1;
        }
        // The sent draft is gone on every replica of the person's (`hub/synced.rs`).
        if draft_sent {
            self.synced_record(super::synced::draft_key(&session.id), Value::Null);
        }
        // The first turn after a rate-limit reset carries the continuation it folded
        // (`rate_hold.rs`). Appended, as above; never to a slash command, whose words it would
        // become.
        if !text.trim_start().starts_with('/')
            && let Some(note) = Self::take_rate_note(session)
        {
            blocks.push(json!({"type": "text", "text": note}));
        }
        // A turn on lane reports only reports nothing (`lane_reports.rs`).
        self.lane_turn_started(session, provenance.as_ref());
        // A family prompt (`subsessions.rs`) never clears the floor a Web
        // turn left: only a local turn the person or a client starts does.
        let family = super::subsession_guard::is_family_prompt(run.provenance.as_ref());
        if control == Control::Web || !family {
            session.floor.mark_last_turn(control == Control::Web, device.clone());
        }
        session
            .floor
            .cloud_mobile_turn
            .store(control == Control::Web && run.cloud_mobile, Ordering::SeqCst);
        self.reset_stream(session);
        // A forced Stop retires the logical turn even if Claude's compaction
        // finishes later. Do not let the stale compaction flag cancel the
        // next, explicit prompt immediately.
        session.compacting.store(false, Ordering::SeqCst);
        // Its control, mobile origin and trust gate go with it: a restart that finds its turn
        // never started queues it again as it came (`unstarted_prompt.rs`).
        let msg = json!({"text": text, "client": client, "promptId": prompt_id, "turnId": turn_id, "control": control.as_str(), "cloudMobile": run.cloud_mobile, "trustGate": run.trust_gate});
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
            // From here a second copy of the prompt hears this turn (`pending_turn`).
            if let Some(turn) = session.turn.lock().unwrap_or_else(|e| e.into_inner()).as_mut()
                && turn.turn_id == turn_id
            {
                turn.accepted = true;
            }
            accept(
                json!({"sessionId": session.id, "promptId": prompt_id, "turnId": turn_id, "queued": false, "state": "started"}),
            );
        }
        // The prompt is recorded and acknowledged above before the agent is started again (it
        // died, or the daemon restarted), so a client hears prompt_accepted at once.
        // Logged on the `woke` line: who sent the prompt that woke the chat (`idle_governor.rs`).
        let person = super::prompt_sender::person_turn(&run, provenance.as_ref());
        self.wake_cause(
            session,
            super::idle_governor::prompt_wake_cause(person, provenance.as_ref()),
        );
        // A start for this turn asks for suggestions only when a person's prompt starts it.
        session
            .start_for
            .store(super::host_level::start_for(&run, provenance.as_ref()), Ordering::SeqCst);
        // Boxed: two starts and the fallback check inline overflowed a debug build's 2 MiB
        // worker stack (`fatal runtime error: stack overflow` in every prompt after #27484).
        // A continuation a move at a tool boundary left: a Claude process started for it resumes
        // the cut turn by itself (`claude_stdio/resume_cut.rs`).
        session
            .resume_cut_ask
            .store(super::auto_resume::silent(provenance.as_ref()), Ordering::SeqCst);
        session.resumed_cut.store(false, Ordering::SeqCst);
        // Whether this prompt's agent starts for it, for its start trace (`send_trace.rs`); read
        // only when the session has one.
        let trace_cold =
            crate::send_trace::waiting(&session.id) && session.child.lock().await.is_none();
        let mut started = Box::pin(self.child_for_since(session, stops)).await;
        // A failover left the chat on a profile that cannot start: back to the profile it came
        // from, which starts this turn (`fallback_start.rs`).
        if let Err(e) = &started
            && Box::pin(self.back_from_fallback(session, e, &turn_id)).await
        {
            started = Box::pin(self.child_for_since(session, stops)).await;
        }
        // A start that missed its deadline is pending, not failed: tried again after a wait.
        let started =
            Box::pin(self.retry_late_start(session, stops, cancels, &prompt_id, &turn_id, started))
                .await;
        // Only this turn's start resumes the cut turn, never a later one.
        session.resume_cut_ask.store(false, Ordering::SeqCst);
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
            Err(mut e) => {
                // A turn the shutdown settles writes no end of its own (`start_retry.rs`).
                let failed = self.fail_unless_shutdown_settles(
                    session,
                    &prompt_id,
                    &turn_id,
                    &e,
                    joined,
                    Some(&rules),
                );
                if !failed && self.hands_off(session) {
                    super::digest::forget_joined(Some(joined));
                }
                // Nor is it answered with what the shutdown did to its start (the agent it
                // ended, a host detached before it answered: "no agent session"): the prompt
                // hears the daemon is restarting, as one cut mid-turn does (chaos fault
                // `daemon-restart-session-new`).
                if !failed && self.shutting_down() && e.message != super::shutdown::SHUTTING_DOWN {
                    tracing::info!(session = %session.id, "agent start ended by the shutdown: {e}");
                    e = super::shutdown::shutting_down_error();
                }
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
        };
        // The process this turn started goes on with the cut turn by itself: this turn's prompt
        // is not written (it is sent as a carried one below), so nothing that rides on a written
        // prompt is added to it or counted as delivered; the next written prompt carries it. A
        // turn refused before that prompt ends the process, which would run the turn unheard.
        let resumed = session.resumed_cut.swap(false, Ordering::SeqCst);
        // A Web steer while the agent started made this a Web turn.
        let control = session.turn().map_or(control, |t| t.control);
        // Starting the agent may have changed its mode (a spawn, a resume, a
        // pool claim, a replayed config): checked again before the prompt.
        if let Err(e) = self
            .check_dispatch(
                session,
                control,
                cloud_mobile,
                trust_gate,
                device.as_deref(),
                &prompt_id,
                &turn_id,
                client,
            )
            .await
        {
            // A refusal once the shutdown began (its trust read found no answer: chaos fault
            // `daemon-restart-session-new`) writes no end of its own, as a start the shutdown
            // ended does: the next daemon queues the prompt again (`unstarted_prompt.rs`).
            // Decided and written under the shutdown's lock (`fail_unless_shutdown_settles`), not
            // after a read of its flag a shutdown could begin behind.
            if self.fail_unless_shutdown_settles(
                session,
                &prompt_id,
                &turn_id,
                &e,
                joined,
                Some(&rules),
            ) {
                if session.status() == SessionStatus::Disconnected {
                    self.set_status(session, NotWaiting::Ready);
                }
            } else if self.hands_off(session) {
                super::digest::forget_joined(Some(joined));
            }
            if resumed {
                child.kill().await;
            }
            Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
            drop(guard);
            return Err(e);
        }
        // Held until the prompt is written: an MDM off push waits for it (`family_gate`).
        let mut family_gate = match self.family_gate(session, run.provenance.as_ref()).await {
            Ok(gate) => gate,
            Err(e) => {
                self.refuse_dequeued(session, waiting, &prompt_id, &turn_id, client, &e);
                self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined, &rules);
                if resumed {
                    child.kill().await;
                }
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
        };
        // cmux's rules on a system-level channel that this agent's start did not carry (its own
        // value, rules too long for one argument, a chat moved under a guard): once, in this
        // message, like the first message's context. Read after the start, which records the
        // command line it ran (`spawn_argv`).
        let rules_owed = !resumed && control != Control::Web && {
            let m = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            !m.cmux_rules_in_transcript
                && crate::context_inventory::append_owed_rules(
                    m.cmux_context.as_deref(),
                    m.spawn_argv.as_deref(),
                    &mut blocks,
                )
        };
        // Add information after digest reconstruction and the person's display record. Slash
        // commands keep their prompt intact and leave these notices for a normal turn.
        let team_enabled =
            self.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging);
        let team_messages =
            if !resumed && team_enabled && super::forum::slash_command(&blocks).is_none() {
                self.take_team_messages(session)
            } else {
                Vec::new()
            };
        // A person's prompt (a shared chat's guest or participant, not the owner) tells the agent
        // who sent it (`author::agent_label`); the transcript's record above keeps their words.
        if super::forum::slash_command(&blocks).is_none()
            && let Some(label) = crate::author::agent_label(provenance.as_ref())
        {
            blocks.insert(0, label);
        }
        super::team_information::prepend(&mut blocks, &team_messages);
        // A team message, or an inbox notice (`inbox.rs`), counts as delivered only once the
        // harness writer took its prompt: `on_sent` then logs it.
        let confirm_team_write = !team_messages.is_empty()
            || (team_enabled && self.has_team_work(session, &team_prompt_ids))
            || super::inbox::is_notice(provenance.as_ref());
        if resumed {
            // Its own transcript is what it goes on from.
        } else if session.take_rehydrate()
            && let Some(transcript) = self.transcript(session, REPLAY_CHARS, &prompt_id)
        {
            // The whole transcript covers what an older agent session lacked too.
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).agent_behind_seq = None;
            blocks.insert(0, restored_transcript(session, &transcript));
        } else if let Some(block) = self.missed_turns(session, REPLAY_CHARS) {
            // The agent resumed an older copy of its own session (`journal_restore.rs`): only
            // the turns after it.
            blocks.insert(0, block);
        }
        // The forum rules this session was not told yet (`hub/forum.rs`).
        let mut told = if resumed {
            Default::default()
        } else {
            self.forum_context(session, pushed.clone(), &mut blocks).await
        };
        // The files the prompt names, read into this message, last, after the cached prefix
        // (`prefetch.rs`). Not into a resumed turn, a remote device's or a slash command.
        if !resumed && control != Control::Web && super::forum::slash_command(&blocks).is_none() {
            self.prefetch_into(session, &text, &turn_id, &mut blocks).await;
        } else {
            *session.prefetch.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
        // A turn rule that matches this prompt, and the end rule the last turn left (`turn_rules.rs`).
        if !resumed && let Some(said) = self.turn_rules_start(session, &text) {
            blocks.push(
                json!({"type": "text", "text": said, "_meta": {"acpmux": {"context": true}}}),
            );
        }
        session.stderr_tail.lock().unwrap().clear();
        // Under the turn lock: this turn ends a person's Stop's hold only if it began under it.
        session.turn_hold.store(session.stop_hold.load(Ordering::SeqCst), Ordering::SeqCst);
        let turn_seq = self
            .append(
                session,
                "mux",
                "turn_started",
                json!({"prompt": short_text(&text, 200), "promptLine": if line == shown.0 { std::mem::take(&mut shown.1) } else { super::auto_resume::shown_line(&line) }, "client": client, "promptId": prompt_id, "turnId": turn_id, "control": control.as_str(), "trustGate": trust_gate, "persons": persons, "trigger": trigger, "cloudMobile": run.cloud_mobile, "device": device.as_deref().filter(|_| control == Control::Web)}),
            )
            .seq;
        // The chat's page before the turn changes it (`turn_shots.rs`), off the turn's path.
        super::turn_shots::turn_began(session, &turn_id);
        // Its frames as the page forms (`turn_frames.rs`), at no agent tokens.
        super::turn_frames::turn_began(session, &turn_id);
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
                self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined, &rules);
                if resumed {
                    child.kill().await;
                }
                self.forum_turn_end(session, &told, false);
                Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
                drop(guard);
                return Err(e);
            }
            Err(e) => {
                self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined, &rules);
                self.forum_turn_end(session, &told, false);
                if resumed {
                    child.kill().await;
                }
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
            self.refuse_started_turn(session, &prompt_id, &turn_id, &e, joined, &rules);
            self.forum_turn_end(session, &told, false);
            if resumed {
                child.kill().await;
            }
            Self::finish_cloud_execution(&mut cloud_exec, session, &turn_id).await;
            drop(guard);
            return Err(e);
        }
        // Its stalled count starts once its prompt is written (`stalled_turn.rs`).
        self.hold_stalled_count(session);
        // A new turn: its own end decides the dot, not an earlier one's (`work_below.rs`).
        if !trigger {
            self.clear_deferred_unread(session);
        }
        self.end_foreground_subagents(session);
        self.set_status(session, NotWaiting::Running);
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
        let delivers_context = !resumed
            && control != Control::Web
            && blocks.iter().any(|b| b.pointer("/_meta/acpmux/contextSource").is_some());
        let person = super::prompt_sender::person_turn(&run, provenance.as_ref());
        // Only a person's own turn makes a recap worth asking for (`away_recap.rs`).
        self.recap_turn_started(session, person);
        // A person waits on this turn's tools: out of background class until it ends
        // (`cpu_class.rs`, item 6).
        let lifted = person && child.person_turn(true).await;
        let params = if resumed {
            // The turn the process resumed by itself: adopted, nothing written (`carry.rs`).
            json!({"sessionId": agent_sid, "prompt": [], "_meta": {"carried": true}})
        } else {
            // The effective provenance: a fan-in turn's is its digest's (above), not its head's.
            super::prompt_sender::run_params(&agent_sid, json!(wire), &run, provenance.as_ref())
        };
        let mut result = super::steer_end::agent_prompt_hook(
            session,
            &child,
            params,
            &turn_id,
            false,
            false,
            fence.as_ref(),
            confirm_team_write || delivers_context,
            None,
            || {
                crate::send_trace::handed(&session.id, trace_cold);
                if delivers_context {
                    let mut m =
                        session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    m.cmux_context_delivered = true;
                    if rules_owed {
                        crate::context_inventory::record_rules_in_transcript(&mut m, turn_seq);
                    }
                    drop(m);
                    self.save_meta(session);
                }
                self.mark_team_messages(session, &team_messages);
                if team_enabled {
                    self.mark_team_work(session, &team_prompt_ids);
                }
                self.watch_stalled_turn(session, None);
                // Written: a notice this is went in, and what is new in the inbox may steer in
                // behind it (`inbox.rs`).
                self.inbox_prompt_written(session, &prompt_id);
                // A Codex chat's stop condition becomes its goal now that a turn has its task.
                self.codex_goal_after_prompt(session, &child, &agent_sid);
                self.title_after_prompt(session)
            },
        )
        .await;
        if lifted {
            child.person_turn(false).await;
        }
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
            // Its route cannot start (a route whose key is missing): the chat stays where it is
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
                self.hold_stalled_count(session);
                // The conversation the chat's own profile resumes, if the fallback cannot start.
                let kept = super::fallback_start::ConversationMark::of(session);
                let turn = session.turn();
                self.detach_child(session).await;
                self.resume_before_turn();
                *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = turn;
                self.set_status(session, NotWaiting::Running);
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
                            cloud_mobile,
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
                        // Rules the fallback's start did not carry (its own appended prompt or
                        // developer instructions), judged by its own command line.
                        let rules_owed_here = !rules_owed && control != Control::Web && {
                            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                            !m.cmux_rules_in_transcript
                                && crate::context_inventory::append_owed_rules(
                                    m.cmux_context.as_deref(),
                                    m.spawn_argv.as_deref(),
                                    &mut blocks,
                                )
                        };
                        // The rules this message carries: owed here, or kept from the first
                        // attempt's blocks, whose write may have failed before it was confirmed.
                        let rules_in_message = rules_owed || rules_owed_here;
                        if session.take_rehydrate()
                            && let Some(transcript) =
                                self.transcript(session, REPLAY_CHARS, &prompt_id)
                        {
                            blocks.insert(0, restored_transcript(session, &transcript));
                            // The new agent session gets every rule again.
                            told = self.forum_retell(session, pushed.clone(), &mut blocks).await;
                        }
                        // Its start read the chat ready: the turn runs on.
                        self.set_status(session, NotWaiting::Running);
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
                                        // Its sender and marks as on the first write.
                                        super::prompt_sender::run_params(
                                            &sid2,
                                            json!(wire),
                                            &run,
                                            provenance.as_ref(),
                                        ),
                                        &turn_id,
                                        false,
                                        false,
                                        fence.as_ref(),
                                        // Owed rules are recorded only once the writer took them.
                                        confirm_team_write || rules_in_message,
                                        None,
                                        || {
                                            if rules_in_message {
                                                crate::context_inventory::record_rules_in_transcript(
                                                    &mut session
                                                        .meta
                                                        .lock()
                                                        .unwrap_or_else(|e| e.into_inner()),
                                                    turn_seq,
                                                );
                                                self.save_meta(session);
                                            }
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
                        self.resume_before_turn();
                        *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = turn;
                        self.set_status(session, NotWaiting::Running);
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
            self.start_carried(session, &child, &turn_id, c, guard.take_slot(), install_turn);
        }
        // A rule counts as told once the agent answered the prompt that carried it.
        self.forum_turn_end(session, &told, result.is_ok());
        // A cut turn goes on by itself (`auto_resume.rs`), unless carried on or cache_compact's.
        let goes_on = !trigger
            && !super::idle::cache_compact::is_own(run.provenance.as_ref())
            && !super::cold_wake::is_own(run.provenance.as_ref());
        // A cut `/compact` is resent as itself, not continued (`auto_resume::resent_command`).
        let cut_text = super::session::prompt_text(&run.blocks);
        let slash = super::auto_resume::resent_command(&cut_text);
        let cut = match (&result, detached) {
            (Err(e), false) if carried.is_none() && goes_on => Some(super::auto_resume::CutTurn {
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
                slash,
            }),
            _ => None,
        };
        self.schedule_auto_resume(session, &turn_id, cut);
        // A turn that ended well says the pool answers again (`auto_resume/capacity_gate.rs`).
        if result.is_ok() && !detached {
            self.capacity_gate_answered(session);
        }
        // A turn that ended well on a capacity fallback puts the chat's own model back
        // (`auto_resume/capacity_failover.rs`).
        if !detached
            && result
                .as_ref()
                .is_ok_and(|v| v.get("stopReason").and_then(Value::as_str) != Some("cancelled"))
        {
            self.restore_after_capacity(session);
        }
        // The agent a Stop ended starts again on the same conversation now, while this turn's
        // lock is still held: the next queued turn finds it running (`cancel.rs`).
        self.respawn_stopped_agent(session, &turn_id, stops).await;
        // The chat's route changed during the turn: move it before the next
        // one starts (route_switch.rs). A restart that fails leaves the
        // harness stopped; the next prompt's spawn reports why. A carried turn runs on: its
        // task moves it when it ends.
        // Work below it (a background subagent, a sub-session) would end with the agent: then
        // it waits for quiet (`route_switch.rs` `restart_waits_for_work_below`).
        if session.route_switch.load(Ordering::SeqCst)
            && carried.is_none()
            && !self.restart_waits_for_work_below(session)
        {
            let _ = self.restart_on_route(session).await;
        }
        drop(guard);
        if let Ok(v) = &mut result {
            merge_mux_meta(v, ids);
        }
        result
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

/// The `lastTurn` a turn's `turn_result` message leaves on the session, ended at `ended_at`.
pub(super) fn last_turn_of(turn_result: &Value, ended_at: u64) -> Value {
    let mut last = serde_json::Map::new();
    for k in super::views::LAST_TURN_KEYS {
        if let Some(v) = turn_result.get(k) {
            last.insert(k.to_owned(), v.clone());
        }
    }
    last.insert("endedAt".into(), json!(ended_at));
    for key in ["turnCount", "turnSeq"] {
        if let Some(value) = turn_result.get(key) {
            last.insert(key.into(), value.clone());
        }
    }
    Value::Object(last)
}

/// The chat's transcript as a rehydrated agent's first prompt gets it, under the note its session
/// holds (`Session::rehydrate_note`, a fork onto another harness), else the restore's own.
fn restored_transcript(session: &Session, transcript: &str) -> Value {
    let note = session
        .rehydrate_note
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
        .unwrap_or_else(|| {
            "acpmux restored this conversation on a new agent session; tool state was not restored"
                .to_owned()
        })
        .replace('"', "'");
    json!({"type": "text", "text": format!("<restored_transcript note=\"{note}\">\n{transcript}\n</restored_transcript>\n")})
}

#[cfg(test)]
#[path = "close_why_tests.rs"]
mod close_why_tests;

#[cfg(test)]
#[path = "exit_notify_tests.rs"]
mod exit_notify_tests;

#[cfg(test)]
#[path = "first_acceptance_tests.rs"]
mod first_acceptance_tests;

#[cfg(test)]
#[path = "set_mode_unchanged_tests.rs"]
mod set_mode_unchanged_tests;
