//! Part of `Hub`; see `hub/mod.rs`.

use super::*;
use crate::close_why::{CloseActor, CloseRecord, CloseWhy};
use std::sync::atomic::Ordering;
use std::time::Duration;

use super::message_events::{
    embed_message_context, ensure_message_provenance, keep_message, message_context,
    name_kept_message, name_message, record_message_context,
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

/// How long a prompt under admission waits to read whether its chat's agent runs.
const LIVE_CHECK_WITHIN: std::time::Duration = std::time::Duration::from_secs(2);

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
        // A deferred start reads the queues after its ready line: a new prompt waits for its
        // chat's, so it never runs ahead of a prompt queued under the previous daemon, nor ahead
        // of a turn adoption recovers.
        // Read this log now, ahead of queued background loads, while keeping the prompt
        // behind adoption's recovered turn below.
        self.session_log(session).await;
        self.wait_adopted(session).await;
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

    pub(super) async fn finish_cloud_execution(
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
        use super::prompt_admission::{Admission, Unanswered};
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
            answer = &mut setup => {
                if admission.defer_requested() {
                    admission.release();
                    return match unanswered {
                        Unanswered::Defer(deferral) => self.defer_unanswered(session, deferral, admission.stage_now()).await,
                        Unanswered::Guarded(guard) => {
                            guard()?;
                            Err(super::auto_resume::retry_turn::busy())
                        }
                        Unanswered::Busy => Err(super::auto_resume::retry_turn::busy()),
                        Unanswered::SteerUnavailable => Err(super::turn_cap::steer_unavailable(false)),
                    };
                }
                return answer;
            },
            () = tokio::time::sleep_until(admission.answer_due()) => {}
        }
        // Past a step it must finish, it finishes: its answer is on its way.
        if admission.committed() {
            return setup.await;
        }
        // Nothing it did yet needs undoing: its setup is dropped where it waits.
        let stage = admission.stage_now();
        drop(setup);
        admission.release();
        match unanswered {
            Unanswered::Defer(deferral) => self.defer_unanswered(session, deferral, stage).await,
            Unanswered::Guarded(guard) => {
                guard()?;
                Err(super::auto_resume::retry_turn::busy())
            }
            Unanswered::Busy => Err(super::auto_resume::retry_turn::busy()),
            Unanswered::SteerUnavailable => Err(super::turn_cap::steer_unavailable(false)),
        }
    }

    /// Waits until the inbound loop handled every agent message queued before
    /// now. Bounded: a loop that is gone (closed channel) or stuck never holds
    /// a turn's settlement past the bound.
    pub(super) async fn drain_inbound(session: &Session) {
        // No channel yet: nothing was ever sent to the chat, so nothing is left to handle.
        let Some(channel) = session.inbound.get() else {
            return;
        };
        let (done, handled) = tokio::sync::oneshot::channel();
        let queued = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            channel.tx.send(crate::agent::Inbound::Barrier(done)),
        )
        .await;
        if matches!(queued, Ok(Ok(()))) {
            let _ = tokio::time::timeout(std::time::Duration::from_secs(5), handled).await;
        }
    }

    /// Keep the outcome of the last turn on the session (`lastTurn` in the
    /// summary), so `wait` can report a failed turn after it resolves.
    pub(super) fn record_last_turn(&self, session: &Session, turn_result: &Value) {
        let last = last_turn_of(turn_result, now_ms());
        self.lane_report_record_result(&session.id, turn_result);
        if turn_result.get("trigger") != Some(&Value::Bool(true)) {
            session.meta.lock().unwrap().last_turn = Some(last);
        }
        // Every turn's end passes here once: its parent hears it (`subsession_results.rs`).
        self.subsession_turn_ended(session, turn_result);
        // Opt-in team usage sharing (`usage_share.rs`): nothing while it is off.
        super::usage_share::turn_ended(session, turn_result);
    }

    /// Whether the failover onto profile `to` is skipped because it runs through the local
    /// CodeRouter (the built-in `cmux` profile or route) and this chat is on a Cloud machine or
    /// came over a remote connection (`fallback_start::coderouter_fallback_skipped`).
    pub(super) async fn no_coderouter_fallback(&self, session: &Session, to: &str) -> bool {
        let cfg = self.config.read().await;
        let Some(profile) = cfg.harnesses.get(to) else { return false };
        let remote = session.meta().remote_origin;
        super::fallback_start::coderouter_fallback_skipped(cfg.cloud_host, remote, to, profile)
    }

    /// The profile to fall over to, when the current one names one that exists.
    pub(super) async fn fallback_profile(&self, session: &Session) -> Option<String> {
        let cfg = self.config.read().await;
        let agent = session.meta().harness;
        let to = cfg.harnesses.get(&agent)?.fallback.clone()?;
        if to == agent || !cfg.harnesses.contains_key(&to) {
            return None;
        }
        Some(to)
    }

    pub async fn rename(&self, session: &Arc<Session>, name: String) -> Result<(), RpcError> {
        self.rename_as(session, name, super::task_names::Naming::Hand).await
    }

    /// `rename`, saying who names it (`task_names::Naming`): a person's or an agent's rename
    /// titles it by the name in words, a task's by the task's title, an address (`register`)
    /// leaves its title as it is. Every one keeps the old name as a former name
    /// (`former_names.rs`); a name another session has now is refused, one it had is taken.
    pub(super) async fn rename_as(
        &self,
        session: &Arc<Session>,
        name: String,
        naming: super::task_names::Naming<'_>,
    ) -> Result<(), RpcError> {
        use super::task_names::Naming;
        if self
            .sessions
            .lock()
            .unwrap()
            .values()
            .any(|s| s.id != session.id && s.read_meta(|m| m.name == name))
        {
            return Err(RpcError::invalid_params(format!("session name {name:?} is taken")));
        }
        let old = session.read_meta(|m| m.name.clone());
        self.release_former_names(session, &name, &old);
        let (old, titled) = {
            let mut m = session.meta.lock().unwrap();
            let prev_source = m.title_source.clone();
            // A chat renamed before it was titled asks no model for a title (`titles.rs`).
            super::titles::title_renamed(&mut m);
            let titled = match naming {
                Naming::Hand => super::task_names::name_in_words(&name).inspect(|title| {
                    super::title_log::renamed(session, &m.harness, prev_source.as_deref());
                    m.title = Some(title.clone());
                    m.title_source = Some(super::titles::NAMED.to_owned());
                    m.title_prompt = None;
                }),
                Naming::Task(title) => {
                    m.title = Some(title.to_owned());
                    m.title_source = Some(super::task_names::TASK.to_owned());
                    m.title_prompt = None;
                    Some(title.to_owned())
                }
                Naming::Address => None,
            };
            m.name_given = true;
            let old = std::mem::replace(&mut m.name, name.clone());
            super::former_names::push_former(&mut m.former_names, &old, &name);
            (old, titled)
        };
        // Both kept (`store/durability.rs`): the answer waits until they are written, not synced.
        self.append(session, "mux", "renamed", json!({"from": old, "to": name}));
        if let Some(title) = titled {
            self.append(session, "mux", "titled", json!({"title": title}));
        }
        self.save_meta_kept(session)?;
        // Its running Claude Code takes the name too (`live_name.rs`).
        self.rename_live_claude(session);
        Ok(())
    }

    /// Writes the close's record (`close_why.rs`): `mux/closed` in its log, `close` on its meta,
    /// and one INFO line. A chat already closed keeps the record of its first close.
    fn record_close(&self, session: &Arc<Session>, purge: bool, why: CloseWhy) {
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
    pub(super) async fn kill_held(
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
pub(super) fn restored_transcript(session: &Session, transcript: &str) -> Value {
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
#[path = "first_acceptance_tests.rs"]
mod first_acceptance_tests;

#[cfg(test)]
#[path = "set_mode_unchanged_tests.rs"]
mod set_mode_unchanged_tests;
