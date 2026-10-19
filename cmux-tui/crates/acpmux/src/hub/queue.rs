//! Part of `Hub`; see `hub/mod.rs`. Prompts waiting for a session's running turn.
//!
//! The queue is durable: each `queued` record carries the whole prompt, and a
//! new daemon rebuilds every session's queue from its log (`restore_queues`)
//! and runs it (`resume_queues`), so queued prompts survive a crash, an update
//! relaunch, a quit and a reboot.

use super::*;
use std::sync::atomic::Ordering;

/// A prompt waiting for the running turn to end.
#[derive(Debug, Clone)]
pub struct QueuedPrompt {
    pub prompt_id: String,
    pub turn_id: String,
    pub client: String,
    pub preview: String,
    pub queued_at: u64,
    /// Fired by `remove_queued`: the waiting `session/prompt` answers withdrawn at once.
    pub(super) withdraw: Arc<Notify>,
    /// What it runs when its turn comes: an edit (`queue_edit.rs`) replaces it.
    pub(super) run: Arc<PromptRun>,
    /// Rebuilt from the log at daemon start (`restore_queues`).
    pub(super) restored: bool,
    /// Rebuilt, and no task runs it yet (`resume_queues`).
    pub(super) resume: bool,
    /// Send now into the running turn (`queue_edit.rs`): its waiting task steers it.
    pub(super) steer: bool,
    /// Waited behind a turn that failed (`pause_queue`): it waits until the queue is resumed.
    pub(super) held: bool,
    /// Sent now (`put_next`): a turn that fails as it stops does not hold it.
    pub(super) sent_now: bool,
}

/// A queued prompt and the rules it runs under.
#[derive(Debug)]
pub(super) struct PromptRun {
    pub(super) blocks: Vec<Value>,
    pub(super) control: Control,
    pub(super) trust_gate: bool,
    /// Who sent it (`prompt_provenance.rs`); an edit drops it.
    pub(super) provenance: Option<Value>,
}

/// A prompt asking for its turn (`queue_slot`).
pub(super) struct Slot<'a> {
    pub(super) text: &'a str,
    pub(super) blocks: &'a [Value],
    pub(super) client: &'a str,
    pub(super) prompt_id: &'a str,
    pub(super) control: Control,
    pub(super) trust_gate: bool,
    /// A steer the agent cannot take: it goes to the head of the queue and the running turn
    /// stops (`queue_edit.rs` `send_queued_now`).
    pub(super) interrupt: bool,
    pub(super) provenance: Option<&'a Value>,
}

/// What a prompt's `session/prompt` answers.
pub(super) type Answer = Result<Value, RpcError>;

/// How a queued prompt's wait ends (`queue_turn`).
pub(super) enum Wait<'a> {
    Turn(tokio::sync::MutexGuard<'a, ()>),
    Withdrawn,
    Steer,
}

/// What a prompt, or a change to the queue or the draft, gets while the chat is being moved to
/// another daemon (`transfer_out.rs`).
pub(super) fn moving_error() -> RpcError {
    RpcError::new(-32000, "transfer.moving: this chat is being moved to another daemon")
}

/// What a withdrawn prompt's `session/prompt` answers: no turn ran.
pub(super) fn withdrawn_reply(prompt_id: &str, turn_id: &str) -> Value {
    json!({
        "stopReason": "cancelled",
        "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "withdrawn": true}},
    })
}

impl Hub {
    /// Gets a prompt its turn: at once when nothing runs or waits, else after it joins the queue
    /// (and `accept` hears `queued`) and reaches its head. Returns the turn id, whether it waited,
    /// the turn lock, and what it runs (an edit may have changed a prompt that waited); `Err` when
    /// it left the queue another way. A prompt `restore_queues` rebuilt is in the queue already.
    pub(super) async fn queue_slot<'a>(
        self: &Arc<Self>,
        session: &'a Arc<Session>,
        p: Slot<'_>,
        accept: &mut impl FnMut(Value),
    ) -> Result<(String, bool, tokio::sync::MutexGuard<'a, ()>, Arc<PromptRun>), Answer> {
        let restored = {
            let mut ids =
                session.restored.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let i = ids.iter().position(|(id, _)| id == p.prompt_id);
            i.map(|i| ids.remove(i).1)
        };
        let (turn_id, withdraw) = match restored {
            // Queued already, unless `remove_queued` withdrew it meanwhile: then it never runs.
            Some(turn_id) => {
                let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                match queue.iter().find(|q| q.turn_id == turn_id) {
                    Some(q) => (turn_id, Some(q.withdraw.clone())),
                    None => return Err(Ok(withdrawn_reply(p.prompt_id, &turn_id))),
                }
            }
            // A chat being moved takes no prompt: its new daemon does (`transfer_out.rs`).
            None if session.moving().is_some() => return Err(Err(moving_error())),
            None => {
                let turn_id = uuid::Uuid::now_v7().to_string();
                // Prompts a failed turn holds (`pause_queue`) do not hold up a new one.
                let held = session.queue().iter().filter(|q| q.held).count() as u64;
                let waiting = session.turn().is_some() || session.queued() > held;
                let position = session.queued.fetch_add(1, Ordering::SeqCst) + 1;
                let withdraw = waiting.then(|| {
                    let withdraw = self.enqueue(session, &p, position, &turn_id);
                    accept(
                        json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "position": position}),
                    );
                    withdraw
                });
                (turn_id, withdraw)
            }
        };
        let Some(withdraw) = withdraw else {
            let guard = session.turn_lock.lock().await;
            session.queued.fetch_sub(1, Ordering::SeqCst);
            // A move began while it waited for the lock (`transfer_out.rs`): it runs nowhere.
            if session.moving().is_some() {
                return Err(Err(moving_error()));
            }
            let run = PromptRun {
                blocks: p.blocks.to_vec(),
                control: p.control,
                trust_gate: p.trust_gate,
                provenance: p.provenance.cloned(),
            };
            return Ok((turn_id, false, guard, Arc::new(run)));
        };
        // A steer the agent cannot take goes next, and stops the turn that runs now.
        if p.interrupt {
            let running = session.turn().map(|t| t.turn_id);
            if self.put_next(session, p.prompt_id)
                && let Some(running) = running
            {
                self.cancel_turn(session, &running).await;
            }
        }
        // A queued prompt `remove_queued` withdraws answers at once, not when the turn ends.
        let guard = match self.queue_turn(session, &turn_id, &withdraw).await {
            Wait::Turn(guard) => guard,
            Wait::Withdrawn => return Err(Ok(withdrawn_reply(p.prompt_id, &turn_id))),
            Wait::Steer => {
                let run = self.take_queued(session, p.prompt_id, &turn_id).map_err(Ok)?;
                return Err(self.steer_queued(session, run, p.client, p.prompt_id).await);
            }
        };
        let run = self.take_queued(session, p.prompt_id, &turn_id).map_err(Ok)?;
        Ok((turn_id, true, guard, run))
    }

    /// Runs a queued prompt sent now (`queue_edit.rs` `send_now`) as a steer under its own prompt
    /// id, so its `session/prompt` answers how it ran. A turn that ended meanwhile leaves it next.
    pub(super) async fn steer_queued(
        self: &Arc<Self>,
        session: &Arc<Session>,
        run: Arc<PromptRun>,
        client: &str,
        prompt_id: &str,
    ) -> Answer {
        let (control, trust_gate) = (run.control, run.trust_gate);
        let (prompt_id, provenance) = (Some(prompt_id.to_owned()), run.provenance.clone());
        let opts = PromptOptions {
            prompt_id,
            control,
            trust_gate,
            interrupt: true,
            provenance,
            ..Default::default()
        };
        Box::pin(self.run_prompt(session, run.blocks.clone(), client, true, opts)).await
    }

    /// Stops the turn `turn_id` if it still runs: a bare cancel stops whatever turn runs now,
    /// which may already be the next one.
    pub(super) async fn cancel_turn(&self, session: &Arc<Session>, turn_id: &str) {
        if session.turn().is_some_and(|t| t.turn_id == turn_id)
            && let Err(e) = self.cancel(session).await
        {
            tracing::warn!(session = %session.id, "interrupt for a steer: {}", e.message);
        }
    }

    /// Puts a prompt that waits for the running turn in the queue and tells every client right
    /// away. The returned `Notify` fires when `remove_queued` withdraws it.
    fn enqueue(
        &self,
        session: &Arc<Session>,
        p: &Slot<'_>,
        position: u64,
        turn_id: &str,
    ) -> Arc<Notify> {
        let withdraw = Arc::new(Notify::new());
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Ahead of the prompts a failed turn holds: a prompt sent after the failure runs first.
        let at = queue.iter().position(|q| q.held).unwrap_or(queue.len());
        queue.insert(
            at,
            QueuedPrompt {
                prompt_id: p.prompt_id.to_owned(),
                turn_id: turn_id.to_owned(),
                client: p.client.to_owned(),
                preview: short_text(p.text, 200),
                queued_at: now_ms(),
                withdraw: withdraw.clone(),
                run: Arc::new(PromptRun {
                    blocks: p.blocks.to_vec(),
                    control: p.control,
                    trust_gate: p.trust_gate,
                    provenance: p.provenance.cloned(),
                }),
                restored: false,
                resume: false,
                steer: false,
                held: false,
                sent_now: false,
            },
        );
        let order: Vec<String> = queue.iter().map(|q| q.prompt_id.clone()).collect();
        let ahead = at + 1 < queue.len();
        drop(queue);
        // `prompt`, `control`, `trustGate` and the provenance let a new daemon run it
        // (`restore_queues`).
        let queued = json!({"text": p.text, "client": p.client, "position": position, "promptId": p.prompt_id, "turnId": turn_id, "prompt": p.blocks, "control": p.control.as_str(), "trustGate": p.trust_gate});
        self.append(
            session,
            "mux",
            "queued",
            crate::prompt_provenance::marked(queued, p.provenance),
        );
        if ahead {
            self.append(
                session,
                "mux",
                "queue_order",
                json!({"promptId": p.prompt_id, "order": order}),
            );
        }
        withdraw
    }

    /// Waits until the queued prompt `turn_id` is at the head of the queue and no other turn
    /// runs, and returns the turn lock; or until `remove_queued` withdraws it, or `send_now`
    /// sends it into the running turn. A turn recovered from an agent host runs first, though its
    /// task may take the lock later.
    pub(super) async fn queue_turn<'a>(
        &self,
        session: &'a Session,
        turn_id: &str,
        withdraw: &Notify,
    ) -> Wait<'a> {
        loop {
            let moved = session.queue_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            let steer = session
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter()
                .any(|q| q.turn_id == turn_id && q.steer);
            // A chat being moved sends nothing into its turn; an abort lets it steer again.
            if steer && session.moving().is_none() {
                return Wait::Steer;
            }
            let guard = tokio::select! {
                guard = session.turn_lock.lock() => guard,
                () = withdraw.notified() => return Wait::Withdrawn,
                () = moved.as_mut() => continue,
            };
            // Prompts a failed turn holds wait wherever they are; the first other one is next. Read
            // with the lock held: the turn that just ended may have held this one.
            let (head, held) = {
                let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let held = queue.iter().any(|q| q.turn_id == turn_id && q.held);
                (queue.iter().find(|q| !q.held).is_none_or(|q| q.turn_id == turn_id), held)
            };
            let moving = session.moving().is_some();
            if head && !held && !moving && session.turn().is_none() {
                if !self.shutting_down() {
                    return Wait::Turn(guard);
                }
                // A stopping daemon starts no turn: the prompt stays queued in the log, and the
                // next daemon runs it (`restore_queues`).
                drop(guard);
                withdraw.notified().await;
                return Wait::Withdrawn;
            }
            drop(guard);
            tokio::select! {
                () = moved => {}
                () = withdraw.notified() => return Wait::Withdrawn,
            }
        }
    }

    /// A failed turn holds the prompts that waited behind it: they were written for a turn that
    /// went well. They wait until a client resumes them (`resume_queue`) or sends one now
    /// (`put_next`); a prompt sent meanwhile runs ahead of them.
    pub(super) fn pause_queue(&self, session: &Arc<Session>, turn_id: &str) {
        let held: Vec<String> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            queue
                .iter_mut()
                .filter(|q| !q.held && !q.sent_now)
                .map(|q| {
                    q.held = true;
                    q.prompt_id.clone()
                })
                .collect()
        };
        if !held.is_empty() {
            self.append(session, "mux", "queue_paused", json!({"turnId": turn_id, "held": held}));
        }
    }

    /// Runs the prompts a failed turn held (`_acpmux/queue_edit` `resume`). False when none was.
    pub(super) fn resume_queue(&self, session: &Arc<Session>) -> bool {
        let mut resumed = false;
        for q in session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).iter_mut()
        {
            resumed |= std::mem::take(&mut q.held);
        }
        if resumed {
            session.queue_moved.notify_waiters();
            self.append(session, "mux", "queue_resumed", json!({"queued": session.queued()}));
        }
        resumed
    }

    /// Runs only the held prompts named in `ids` (the ones one failed turn held, `auto_resume.rs`).
    /// False when none of them was held.
    pub(super) fn resume_held(&self, session: &Arc<Session>, ids: &[String]) -> bool {
        let mut resumed = false;
        for q in session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).iter_mut()
        {
            if ids.contains(&q.prompt_id) {
                resumed |= std::mem::take(&mut q.held);
            }
        }
        if resumed {
            session.queue_moved.notify_waiters();
            self.append(
                session,
                "mux",
                "queue_resumed",
                json!({"queued": session.queued(), "promptIds": ids}),
            );
        }
        resumed
    }

    /// Puts a waiting prompt sent now at the head of the queue; a failed turn no longer holds
    /// it, nor does the turn it stops. False when it no longer waits.
    pub(super) fn put_next(&self, session: &Arc<Session>, prompt_id: &str) -> bool {
        let order: Vec<String> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(from) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return false;
            };
            // Only the last prompt sent now: one sent before it is a queued prompt again.
            queue.iter_mut().for_each(|q| q.sent_now = false);
            let mut q = queue.remove(from);
            (q.held, q.sent_now) = (false, true);
            queue.insert(0, q);
            queue.iter().map(|q| q.prompt_id.clone()).collect()
        };
        session.queue_moved.notify_waiters();
        let msg = json!({"promptId": prompt_id, "order": order, "next": true});
        self.append(session, "mux", "queue_order", msg);
        true
    }

    /// With the turn lock held, takes a queued prompt out of the queue for its turn, with what it
    /// runs. A prompt `remove_queued` withdrew just as the lock freed (and counted off) gets no
    /// turn: the reply its `session/prompt` answers instead.
    pub(super) fn take_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
    ) -> Result<Arc<PromptRun>, Value> {
        let run = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.turn_id == turn_id) else {
                return Err(withdrawn_reply(prompt_id, turn_id));
            };
            session.queued.fetch_sub(1, Ordering::SeqCst);
            queue.remove(i).run
        };
        session.queue_moved.notify_waiters();
        self.append(
            session,
            "mux",
            "dequeued",
            json!({"promptId": prompt_id, "turnId": turn_id, "queued": session.queued()}),
        );
        Ok(run)
    }

    /// `_acpmux/queue_remove`: `remove_queued`, refused while the chat is being moved.
    pub fn withdraw_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
    ) -> Result<bool, RpcError> {
        if session.moving().is_some() {
            return Err(moving_error());
        }
        Ok(self.remove_queued(session, prompt_id))
    }

    /// Takes a waiting prompt out of the queue before its turn starts; its `session/prompt` then
    /// answers `cancelled` with `_meta.acpmux.withdrawn`. False when the prompt is not waiting
    /// (it started, ended or was already removed).
    pub fn remove_queued(&self, session: &Arc<Session>, prompt_id: &str) -> bool {
        self.remove_queued_because(session, prompt_id, None)
    }

    /// `remove_queued`, its `queue_removed` record naming why (`withdrawn`: `withdraw.rs`).
    pub(super) fn remove_queued_because(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        reason: Option<&str>,
    ) -> bool {
        let removed = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return false;
            };
            session.queued.fetch_sub(1, Ordering::SeqCst);
            queue.remove(i)
        };
        session.queue_moved.notify_waiters();
        // A resend of a rebuilt prompt waits on the ledger entry `restore_queues` made.
        if removed.restored
            && let Some((_, outcome)) = session
                .prompts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .find(|(id, _)| id == prompt_id)
        {
            outcome.send_replace(Some(Ok(withdrawn_reply(prompt_id, &removed.turn_id))));
        }
        let mut msg =
            json!({"promptId": prompt_id, "turnId": removed.turn_id, "queued": session.queued()});
        if let Some(reason) = reason {
            msg["reason"] = json!(reason);
        }
        self.append(session, "mux", "queue_removed", msg);
        // A stored permit: the waiting task sees it even before it polls.
        removed.withdraw.notify_one();
        true
    }

    /// At load: puts back every prompt the log shows queued but never dequeued, started or
    /// removed, in queue order. They run once `resume_queues` starts them; a client that resends
    /// one meanwhile waits for that run (the ledger entry made here).
    pub(super) fn restore_queues(&self) {
        for session in self.sessions() {
            self.restore_queue(&session);
        }
    }

    /// One session's queue, from its log (also a chat moved here, `transfer_in.rs`).
    pub(super) fn restore_queue(&self, session: &Arc<Session>) {
        if session.meta().status == SessionStatus::Closed {
            return;
        }
        let mut waiting: Vec<EventRecord> = Vec::new();
        let mut order: Vec<Value> = Vec::new();
        let mut held: Vec<Value> = Vec::new();
        // A move that began and neither committed nor aborted (`transfer_out.rs`); a chat
        // moved here was the source's until its `imported` record.
        let mut moving: Option<String> = None;
        let scanned = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            let turn_id = e.msg.get("turnId");
            match e.kind.as_str() {
                "queued" => waiting.push(e),
                "transfer_out" => moving = e.msg["transferId"].as_str().map(str::to_owned),
                "transfer_aborted" | "imported" => moving = None,
                "dequeued" | "queue_removed" | "user_message" | "turn_started" => {
                    waiting.retain(|q| q.msg.get("turnId") != turn_id);
                }
                // An edit (`queue_edit.rs`): the prompt and its rules replace the queued ones,
                // and it has no `_meta.provenance` (the person rewrote it).
                "queue_updated" => {
                    if let Some(q) = waiting.iter_mut().find(|q| q.msg.get("turnId") == turn_id) {
                        for k in ["text", "prompt", "control", "trustGate"] {
                            q.msg[k] = e.msg.get(k).cloned().unwrap_or(Value::Null);
                        }
                        if let Some(meta) = q.msg.get_mut("_meta").and_then(Value::as_object_mut) {
                            meta.remove("provenance");
                        }
                    }
                }
                "queue_paused" => {
                    let ids = e.msg.get("held").and_then(Value::as_array);
                    held.extend(ids.into_iter().flatten().cloned());
                }
                "queue_resumed" => held.clear(),
                "queue_order" => {
                    // Sent now (`put_next`): no longer held.
                    if e.msg.get("next") == Some(&Value::Bool(true)) {
                        held.retain(|id| Some(id) != e.msg.get("promptId"));
                    }
                    order =
                        e.msg.get("order").and_then(Value::as_array).cloned().unwrap_or_default()
                }
                _ => {}
            }
            true
        });
        session.moving.lock().unwrap_or_else(|e| e.into_inner()).clone_from(&moving);
        if scanned.is_err() || waiting.is_empty() {
            return;
        }
        // The last reorder holds; a prompt queued after it keeps its place at the end.
        waiting.sort_by_key(|q| {
            order.iter().position(|id| Some(id) == q.msg.get("promptId")).unwrap_or(order.len())
        });
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
        let mut restored = session.restored.lock().unwrap_or_else(|e| e.into_inner());
        for e in waiting {
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let (prompt_id, turn_id, text) = (field("promptId"), field("turnId"), field("text"));
            if prompt_id.is_empty() || turn_id.is_empty() {
                continue;
            }
            // A record from before the prompt was logged has its text only.
            let blocks = match e.msg.get("prompt").and_then(Value::as_array) {
                Some(blocks) => blocks.clone(),
                None => vec![json!({"type": "text", "text": text})],
            };
            let control = Control::from_recorded(e.msg.get("control").and_then(Value::as_str));
            let trust_gate = e.msg.get("trustGate").and_then(Value::as_bool).unwrap_or(false);
            let provenance = e.msg.pointer("/_meta/provenance").filter(|p| p.is_object()).cloned();
            restored.push((prompt_id.clone(), turn_id.clone()));
            queue.push(QueuedPrompt {
                prompt_id: prompt_id.clone(),
                turn_id,
                client: field("client"),
                preview: short_text(&text, 200),
                queued_at: e.at,
                withdraw: Arc::new(Notify::new()),
                run: Arc::new(PromptRun { blocks, control, trust_gate, provenance }),
                restored: true,
                resume: true,
                steer: false,
                held: held.iter().any(|id| id.as_str() == Some(&prompt_id)),
                sent_now: false,
            });
            session.queued.fetch_add(1, Ordering::SeqCst);
            ledger.push_back((prompt_id, Arc::new(tokio::sync::watch::channel(None).0)));
            if ledger.len() > PROMPT_LEDGER {
                ledger.pop_front();
            }
        }
        tracing::info!(session = %session.id, queued = queue.len(), "restored queued prompts");
    }

    /// Runs the prompts `restore_queues` put back, each in its place in the queue (after any
    /// turn recovered from an agent host). Called once at daemon start, after adoption.
    pub fn resume_queues(self: &Arc<Self>) {
        for session in self.sessions() {
            let restored: Vec<QueuedPrompt> = session
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter_mut()
                .filter_map(|q| std::mem::take(&mut q.resume).then(|| q.clone()))
                .collect();
            for q in restored {
                let hub = self.clone();
                let session = session.clone();
                tokio::spawn(async move {
                    // After the login env and the catalog reload: its harness may need them.
                    hub.wait_startup().await;
                    let opts = PromptOptions {
                        prompt_id: Some(q.prompt_id.clone()),
                        control: q.run.control,
                        trust_gate: q.run.trust_gate,
                        ..PromptOptions::default()
                    };
                    let blocks = q.run.blocks.clone();
                    let result = hub.run_prompt(&session, blocks, &q.client, false, opts).await;
                    // A client that resent this prompt id waits on the entry `restore_queues` made.
                    let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some((_, outcome)) = ledger.iter().find(|(id, _)| *id == q.prompt_id) {
                        outcome.send_replace(Some(result.clone()));
                    }
                    drop(ledger);
                    // Refused before its turn (its harness is gone): it leaves the queue, so the
                    // prompts behind it still run.
                    if let Err(e) = result
                        && hub.remove_queued(&session, &q.prompt_id)
                    {
                        tracing::warn!(session = %session.id, prompt = %q.prompt_id, "restored prompt refused: {}", e.message);
                    }
                });
            }
        }
    }
}
