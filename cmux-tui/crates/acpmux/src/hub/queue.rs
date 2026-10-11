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
    /// Rebuilt from the log at daemon start (`restore_queues`).
    pub(super) restored: bool,
    /// What a rebuilt prompt runs, until `resume_queues` starts it.
    pub(super) restore: Option<Restore>,
}

/// What a prompt rebuilt from the log needs to run.
#[derive(Debug, Clone)]
pub(super) struct Restore {
    blocks: Vec<Value>,
    control: Control,
    trust_gate: bool,
}

/// A prompt asking for its turn (`queue_slot`).
pub(super) struct Slot<'a> {
    pub(super) text: &'a str,
    pub(super) blocks: &'a [Value],
    pub(super) client: &'a str,
    pub(super) prompt_id: &'a str,
    pub(super) control: Control,
    pub(super) trust_gate: bool,
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
    /// and the turn lock; `Err` is the reply of a prompt `remove_queued` withdrew. A prompt
    /// `restore_queues` rebuilt is in the queue already, with its turn id.
    pub(super) async fn queue_slot<'a>(
        &self,
        session: &'a Arc<Session>,
        p: Slot<'_>,
        accept: &mut impl FnMut(Value),
    ) -> Result<(String, bool, tokio::sync::MutexGuard<'a, ()>), Value> {
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
                    None => return Err(withdrawn_reply(p.prompt_id, &turn_id)),
                }
            }
            None => {
                let turn_id = uuid::Uuid::now_v7().to_string();
                let waiting = session.turn().is_some() || session.queued() > 0;
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
            return Ok((turn_id, false, guard));
        };
        // A queued prompt `remove_queued` withdraws answers at once, not when the turn ends.
        let Some(guard) = self.queue_turn(session, &turn_id, &withdraw).await else {
            return Err(withdrawn_reply(p.prompt_id, &turn_id));
        };
        match self.take_queued(session, p.prompt_id, &turn_id) {
            Some(withdrawn) => Err(withdrawn),
            None => Ok((turn_id, true, guard)),
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
        session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(
            QueuedPrompt {
                prompt_id: p.prompt_id.to_owned(),
                turn_id: turn_id.to_owned(),
                client: p.client.to_owned(),
                preview: short_text(p.text, 200),
                queued_at: now_ms(),
                withdraw: withdraw.clone(),
                restored: false,
                restore: None,
            },
        );
        // `prompt`, `control` and `trustGate` let a new daemon run it (`restore_queues`).
        self.append(
            session,
            "mux",
            "queued",
            json!({"text": p.text, "client": p.client, "position": position, "promptId": p.prompt_id, "turnId": turn_id, "prompt": p.blocks, "control": p.control.as_str(), "trustGate": p.trust_gate}),
        );
        withdraw
    }

    /// Waits until the queued prompt `turn_id` is at the head of the queue and no other turn
    /// runs, and returns the turn lock; `None` once `remove_queued` withdrew it. A turn
    /// recovered from an agent host runs first, though its task may take the lock later.
    pub(super) async fn queue_turn<'a>(
        &self,
        session: &'a Session,
        turn_id: &str,
        withdraw: &Notify,
    ) -> Option<tokio::sync::MutexGuard<'a, ()>> {
        loop {
            let moved = session.queue_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            let guard = tokio::select! {
                guard = session.turn_lock.lock() => guard,
                () = withdraw.notified() => return None,
            };
            let head = session
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .first()
                .is_none_or(|q| q.turn_id == turn_id);
            if head && session.turn().is_none() {
                if !self.shutting_down() {
                    return Some(guard);
                }
                // A stopping daemon starts no turn: the prompt stays queued in the log, and the
                // next daemon runs it (`restore_queues`).
                drop(guard);
                withdraw.notified().await;
                return None;
            }
            drop(guard);
            tokio::select! {
                () = moved => {}
                () = withdraw.notified() => return None,
            }
        }
    }

    /// With the turn lock held, takes a queued prompt out of the queue for its turn. A prompt
    /// `remove_queued` withdrew just as the lock freed (and counted off) gets no turn: the reply
    /// its `session/prompt` answers instead.
    pub(super) fn take_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
    ) -> Option<Value> {
        {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.turn_id == turn_id) else {
                return Some(withdrawn_reply(prompt_id, turn_id));
            };
            queue.remove(i);
            session.queued.fetch_sub(1, Ordering::SeqCst);
        }
        session.queue_moved.notify_waiters();
        self.append(
            session,
            "mux",
            "dequeued",
            json!({"promptId": prompt_id, "turnId": turn_id, "queued": session.queued()}),
        );
        None
    }

    /// Takes a waiting prompt out of the queue before its turn starts; its `session/prompt` then
    /// answers `cancelled` with `_meta.acpmux.withdrawn`. False when the prompt is not waiting
    /// (it started, ended or was already removed).
    pub fn remove_queued(&self, session: &Arc<Session>, prompt_id: &str) -> bool {
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
            && let Some((_, outcome)) =
                session.prompts.lock().unwrap().iter().find(|(id, _)| id == prompt_id)
        {
            outcome.send_replace(Some(Ok(withdrawn_reply(prompt_id, &removed.turn_id))));
        }
        self.append(
            session,
            "mux",
            "queue_removed",
            json!({"promptId": prompt_id, "turnId": removed.turn_id, "queued": session.queued()}),
        );
        // A stored permit: the waiting task sees it even before it polls.
        removed.withdraw.notify_one();
        true
    }

    /// At load: puts back every prompt the log shows queued but never dequeued, started or
    /// removed, in queue order. They run once `resume_queues` starts them; a client that resends
    /// one meanwhile waits for that run (the ledger entry made here).
    pub(super) fn restore_queues(&self) {
        for session in self.sessions() {
            if session.meta().status == SessionStatus::Closed {
                continue;
            }
            let mut waiting: Vec<EventRecord> = Vec::new();
            let scanned = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
                match e.kind.as_str() {
                    "queued" => waiting.push(e),
                    "dequeued" | "queue_removed" | "user_message" | "turn_started" => {
                        let turn_id = e.msg.get("turnId");
                        waiting.retain(|q| q.msg.get("turnId") != turn_id);
                    }
                    _ => {}
                }
                true
            });
            if scanned.is_err() || waiting.is_empty() {
                continue;
            }
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut ledger = session.prompts.lock().unwrap();
            let mut restored = session.restored.lock().unwrap();
            for e in waiting {
                let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
                let (prompt_id, turn_id, text) =
                    (field("promptId"), field("turnId"), field("text"));
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
                restored.push((prompt_id.clone(), turn_id.clone()));
                queue.push(QueuedPrompt {
                    prompt_id: prompt_id.clone(),
                    turn_id,
                    client: field("client"),
                    preview: short_text(&text, 200),
                    queued_at: e.at,
                    withdraw: Arc::new(Notify::new()),
                    restored: true,
                    restore: Some(Restore { blocks, control, trust_gate }),
                });
                session.queued.fetch_add(1, Ordering::SeqCst);
                ledger.push_back((prompt_id, Arc::new(tokio::sync::watch::channel(None).0)));
                if ledger.len() > PROMPT_LEDGER {
                    ledger.pop_front();
                }
            }
            tracing::info!(session = %session.id, queued = queue.len(), "restored queued prompts");
        }
    }

    /// Runs the prompts `restore_queues` put back, each in its place in the queue (after any
    /// turn recovered from an agent host). Called once at daemon start, after adoption.
    pub fn resume_queues(self: &Arc<Self>) {
        for session in self.sessions() {
            let restored: Vec<(QueuedPrompt, Restore)> = session
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .iter_mut()
                .filter_map(|q| q.restore.take().map(|r| (q.clone(), r)))
                .collect();
            for (q, r) in restored {
                let hub = self.clone();
                let session = session.clone();
                tokio::spawn(async move {
                    // After the login env and the catalog reload: its harness may need them.
                    hub.wait_startup().await;
                    let opts = PromptOptions {
                        prompt_id: Some(q.prompt_id.clone()),
                        control: r.control,
                        trust_gate: r.trust_gate,
                        ..PromptOptions::default()
                    };
                    let result = hub.run_prompt(&session, r.blocks, &q.client, false, opts).await;
                    // A client that resent this prompt id waits on the entry `restore_queues` made.
                    let ledger = session.prompts.lock().unwrap();
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
