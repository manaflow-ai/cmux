//! Part of `Hub`; see `hub/mod.rs`. Prompts waiting for a session's running turn.
//!
//! The queue is durable: each `queued` record carries the whole prompt, and a
//! new daemon rebuilds every session's queue from its log (`restore_queues`)
//! and runs it (`resume_queues`), so queued prompts survive a crash, an update
//! relaunch, a quit and a reboot.

use super::subsession_runs::{TurnGuard, WaitMark};
use super::*;
use std::sync::atomic::Ordering;

// A prompt dequeued for a turn that never started goes back at the head (`restore_queue`).
#[path = "lost_start.rs"]
mod lost_start;
// The waiting records and the order a restore reads, indexed (`restore_queue`).
#[path = "queue_waiting.rs"]
mod queue_waiting;

// `_meta.acpmux.supersede`: a prompt replaces its sender's queued one under the same key.
#[path = "supersede.rs"]
pub(super) mod supersede;

/// A session's prompt ids and their outcomes (`Session::prompts`, `prompt_ledger.rs`).
pub(super) type PromptLedger = std::collections::VecDeque<(String, PromptOutcome)>;

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
    /// Set when it went in with an earlier agent message's turn (`digest.rs`): its waiting task
    /// answers with that turn, or waits again when that turn failed (`requeue_joined`).
    pub(super) joined: Arc<StdMutex<Option<super::digest::Joined>>>,
    /// Put back once after a failed turn of agent messages (`requeue_joined`): not again.
    pub(super) requeued: bool,
    /// Times a hold let it go by itself (`digest.rs` `retry_held_agent_messages`): the next
    /// hold waits longer.
    pub(super) retries: usize,
}

impl QueuedPrompt {
    /// The person who sent it (`author.rs`), `None` for the owner or an agent.
    pub(super) fn sender(&self) -> Option<&str> {
        crate::author::of_provenance(self.run.provenance.as_ref())
    }
}

/// A queued prompt and the rules it runs under.
#[derive(Debug)]
pub(super) struct PromptRun {
    pub(super) blocks: Vec<Value>,
    /// Sanitized app display metadata, keyed by ACP block index. It is persisted with queued
    /// records and used only to rebuild the transcript; it never crosses the agent boundary.
    pub(super) display_parts: Option<Value>,
    pub(super) control: Control,
    pub(super) trust_gate: bool,
    /// Who sent it (`prompt_provenance.rs`); an edit drops it.
    pub(super) provenance: Option<Value>,
    /// Another agent's name when it is that agent's message, `None` when it is the person's
    /// (`digest.rs`); an edit makes it the person's.
    pub(super) agent: Option<String>,
    /// Its `_meta.acpmux.supersede` key (`supersede.rs`); an edit drops it.
    pub(super) supersede: Option<String>,
    /// The paired machine whose Full-access setting covered its sender (`PromptOptions`); an
    /// edit keeps it only from that machine.
    pub(super) full_access_device: Option<String>,
}

/// A prompt asking for its turn (`queue_slot`).
pub(super) struct Slot<'a> {
    pub(super) text: &'a str,
    pub(super) blocks: &'a [Value],
    pub(super) display_parts: Option<&'a Value>,
    pub(super) client: &'a str,
    pub(super) prompt_id: &'a str,
    pub(super) control: Control,
    pub(super) trust_gate: bool,
    /// A steer the agent cannot take (`_meta.acpmux.interrupt`): it goes to the head of the
    /// queue and the running turn stops.
    pub(super) interrupt: bool,
    /// The turn `interrupt` was aimed at, when it was one turn (`PromptOptions::interrupt_turn`):
    /// another turn running now is not stopped.
    pub(super) interrupt_turn: Option<&'a str>,
    pub(super) provenance: Option<&'a Value>,
    /// Another agent's name when it is that agent's message (`digest.rs`).
    pub(super) agent: Option<&'a str>,
    /// Its `_meta.acpmux.supersede` key (`supersede.rs`).
    pub(super) supersede: Option<&'a str>,
    /// `PromptOptions::full_access_device`.
    pub(super) full_access_device: Option<&'a str>,
    /// Set to the prompts it replaced when it queues (`enqueue`), for its acceptance.
    pub(super) replaced: &'a std::sync::OnceLock<Vec<String>>,
}

/// What a prompt's `session/prompt` answers.
pub(super) type Answer = Result<Value, RpcError>;

/// How a queued prompt's wait ends (`queue_turn`).
pub(super) enum Wait<'a> {
    Turn(TurnGuard<'a>),
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
    /// (and `accept` hears `queued`) and reaches its head. A family prompt to a sub-session whose
    /// parent's run slots are all taken joins the queue too (`subsession_runs.rs`), and `accept`
    /// also hears `waitsForSlot`. Returns the turn id, whether it waited, the turn lock (with the
    /// run slot it holds), and what it runs (an edit may have changed a prompt that waited);
    /// `Err` when it left the queue another way. A prompt `restore_queues` rebuilt is in the
    /// queue already.
    pub(super) async fn queue_slot<'a>(
        self: &Arc<Self>,
        session: &'a Arc<Session>,
        p: Slot<'_>,
        accept: &mut impl FnMut(Value),
    ) -> Result<(String, bool, TurnGuard<'a>, Arc<PromptRun>), Answer> {
        // Claimed under the queue lock, as `restore_queue` takes them: a turn of agent messages
        // joins only a restored prompt its task claimed (`digest.rs` `take_joined`).
        let restored = {
            let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut ids =
                session.restored.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let i = ids.iter().position(|(id, _)| id == p.prompt_id);
            i.map(|i| {
                let turn_id = ids.remove(i).1;
                let q = queue.iter().find(|q| q.turn_id == turn_id);
                (turn_id, q.map(|q| (q.withdraw.clone(), q.joined.clone())))
            })
        };
        let (turn_id, withdraw) = match restored {
            // Queued already, unless `remove_queued` withdrew it meanwhile: then it never runs.
            Some((turn_id, Some(waits))) => (turn_id, Some(waits)),
            Some((turn_id, None)) => return Err(Ok(withdrawn_reply(p.prompt_id, &turn_id))),
            // A chat being moved takes no prompt: its new daemon does (`transfer_out.rs`).
            None if session.moving().is_some() => return Err(Err(moving_error())),
            // A watched chat takes no prompt until it is taken over (`watch.rs`).
            None if session.meta().watching.is_some() => {
                return Err(Err(super::watch::read_only()));
            }
            None => {
                let turn_id = uuid::Uuid::now_v7().to_string();
                // Another agent's message never overtakes the ones a failed turn held: they run
                // again and it waits behind them, to go in with them (`digest.rs`).
                if p.agent.is_some() {
                    self.release_held_agent_messages(session);
                }
                // Prompts a failed turn holds (`pause_queue`) do not hold up a new one.
                let held = session.queue().iter().filter(|q| q.held).count() as u64;
                let waiting = session.turn().is_some() || session.queued() > held;
                let position = session.queued.fetch_add(1, Ordering::SeqCst) + 1;
                let withdraw = waiting.then(|| {
                    let waits = self.enqueue(session, &p, position, &turn_id);
                    accept(
                        json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "position": position}),
                    );
                    waits
                });
                (turn_id, withdraw)
            }
        };
        // `_slot_wait` counts the sub-session as waiting for a run slot from the moment its prompt
        // is queued for one, so the summary that `queued` record brings already says so.
        let (withdraw, _slot_wait): (_, Option<WaitMark>) = match withdraw {
            Some(withdraw) => (withdraw, None),
            None => {
                let guard = session.turn_lock.lock().await;
                session.queued.fetch_sub(1, Ordering::SeqCst);
                // A move began while it waited for the lock (`transfer_out.rs`): it runs nowhere.
                if session.moving().is_some() {
                    return Err(Err(moving_error()));
                }
                match self.take_run_slot(session, p.provenance) {
                    Ok(slot) => {
                        let run = PromptRun {
                            blocks: p.blocks.to_vec(),
                            display_parts: p.display_parts.cloned(),
                            control: p.control,
                            trust_gate: p.trust_gate,
                            provenance: p.provenance.cloned(),
                            agent: p.agent.map(str::to_owned),
                            supersede: p.supersede.map(str::to_owned),
                            full_access_device: p.full_access_device.map(str::to_owned),
                        };
                        return Ok((turn_id, false, TurnGuard::new(guard, slot), Arc::new(run)));
                    }
                    // The parent's run slots are all taken: it waits in the queue for one.
                    Err(parent) => {
                        drop(guard);
                        let mark = self.mark_waiting_for_slot(&parent, session);
                        let position = session.queued.fetch_add(1, Ordering::SeqCst) + 1;
                        let waits = self.enqueue(session, &p, position, &turn_id);
                        accept(
                            json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "position": position, "waitsForSlot": true}),
                        );
                        (waits, Some(mark))
                    }
                }
            }
        };
        let (withdraw, joined) = withdraw;
        // A steer the agent cannot take goes next, and stops the turn that runs now, unless it was
        // aimed at a turn that has ended since: the one running now is another prompt's.
        if p.interrupt {
            let running = session.turn().map(|t| t.turn_id);
            if self.put_next(session, p.prompt_id, None).is_ok_and(|next| next)
                && let Some(running) = running
                && p.interrupt_turn.is_none_or(|aimed| aimed == running)
            {
                self.cancel_turn(session, &running).await;
            }
        }
        // A queued prompt `remove_queued` withdraws answers at once, not when the turn ends.
        let guard = loop {
            match self.queue_turn(session, &turn_id, &withdraw).await {
                Wait::Turn(guard) => break guard,
                // Gone in with an earlier agent message's turn (`digest.rs`): that turn's answer.
                // A failed one put it back in the queue (`requeue_joined`): it waits again.
                Wait::Withdrawn => {
                    let went_in = joined.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    let answer = match went_in {
                        Some(went_in) => super::digest::joined_reply(&went_in, p.prompt_id).await,
                        None => Ok(withdrawn_reply(p.prompt_id, &turn_id)),
                    };
                    if session.queue().iter().any(|q| q.turn_id == turn_id) {
                        continue;
                    }
                    return Err(answer);
                }
                Wait::Steer => {
                    let run = self.take_queued(session, p.prompt_id, &turn_id).map_err(Ok)?;
                    let answer = self.steer_queued(session, run, p.client, p.prompt_id).await;
                    // Refused: logged, so a restart does not queue it again (`lost_start.rs`).
                    if let Err(e) = &answer {
                        let msg = json!({"promptId": p.prompt_id, "turnId": turn_id, "client": p.client, "error": e.message, "data": e.data});
                        self.append(session, "mux", "prompt_refused", msg);
                    }
                    return Err(answer);
                }
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
            agent: run.agent.clone(),
            display_parts: run.display_parts.clone(),
            full_access_device: run.full_access_device.clone(),
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
    /// away. The returned `Notify` fires when `remove_queued` withdraws it or it joins an earlier
    /// agent message's turn (then `joined` is set, `digest.rs`).
    fn enqueue(
        &self,
        session: &Arc<Session>,
        p: &Slot<'_>,
        position: u64,
        turn_id: &str,
    ) -> (Arc<Notify>, Arc<StdMutex<Option<super::digest::Joined>>>) {
        let withdraw = Arc::new(Notify::new());
        let joined = Arc::new(StdMutex::new(None));
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // The sender's prompts under its key leave under the lock that puts this one in
        // (`supersede.rs`), with the ledger pinned first as `remove_queued_because` pins it.
        let superseded = p.supersede.map(|key| {
            let gone = supersede::take(session, &mut queue, key, p.agent, p.prompt_id);
            (gone, session.prompts.lock().unwrap_or_else(|e| e.into_inner()))
        });
        // Ahead of the prompts a failed turn holds: a prompt sent after the failure runs first.
        // The person's prompt goes ahead of every agent message waiting too (`digest.rs`), behind
        // the person's own and a prompt sent now.
        let at = match p.agent {
            Some(_) => queue.iter().position(|q| q.held),
            None => queue.iter().position(|q| q.held || (q.run.agent.is_some() && !q.sent_now)),
        };
        let at = at.unwrap_or(queue.len());
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
                    display_parts: p.display_parts.cloned(),
                    control: p.control,
                    trust_gate: p.trust_gate,
                    provenance: p.provenance.cloned(),
                    agent: p.agent.map(str::to_owned),
                    supersede: p.supersede.map(str::to_owned),
                    full_access_device: p.full_access_device.map(str::to_owned),
                }),
                restored: false,
                resume: false,
                steer: false,
                held: false,
                sent_now: false,
                joined: joined.clone(),
                requeued: false,
                retries: 0,
            },
        );
        let order: Vec<String> = queue.iter().map(|q| q.prompt_id.clone()).collect();
        let ahead = at + 1 < queue.len();
        drop(queue);
        if let Some((gone, mut ledger)) = superseded {
            let ids = self.settle_superseded(session, gone, &mut ledger, p.prompt_id);
            let _ = p.replaced.set(ids);
        }
        // `prompt`, `control`, `trustGate`, the provenance and the sending agent let a new daemon
        // run it (`restore_queues`).
        let mut queued = json!({"text": p.text, "client": p.client, "position": position, "promptId": p.prompt_id, "turnId": turn_id, "prompt": p.blocks, "control": p.control.as_str(), "trustGate": p.trust_gate});
        if let Some(agent) = p.agent {
            queued["fromAgent"] = json!(agent);
        }
        if let Some(key) = p.supersede {
            queued["supersede"] = json!(key);
        }
        // Its images are kept now and named, so its row shows them before it runs
        // (`prompt_images.rs`).
        let images = super::prompt_images::keep(p.blocks);
        if !images.is_empty() {
            queued["images"] = Value::Array(images);
        }
        let inline_parts = super::prompt_images::inline_parts(
            p.blocks,
            queued.get("images").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default(),
            p.display_parts,
        );
        if !inline_parts.is_empty() {
            queued["inlineParts"] = Value::Array(inline_parts);
        }
        if let Some(display_parts) = p.display_parts {
            queued["displayParts"] = display_parts.clone();
        }
        super::session::mark_pasted(&mut queued, p.blocks);
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
        (withdraw, joined)
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
        // Set while it waits for a run slot of its parent (`subsession_runs.rs`).
        let mut slot_wait: Option<WaitMark> = None;
        loop {
            let moved = session.queue_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            // Enabled before the slots are looked at, so a slot freed in between is not missed.
            let freed = self.run_slots_changed();
            tokio::pin!(freed);
            freed.as_mut().enable();
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
            let (head, held, provenance) = {
                let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let mine = queue.iter().find(|q| q.turn_id == turn_id);
                let held = mine.is_some_and(|q| q.held);
                let provenance = mine.and_then(|q| q.run.provenance.clone());
                let head = queue.iter().find(|q| !q.held).is_none_or(|q| q.turn_id == turn_id);
                (head, held, provenance)
            };
            let moving = session.moving().is_some();
            if head && !held && !moving && session.turn().is_none() {
                if !self.shutting_down() {
                    match self.take_run_slot(session, provenance.as_ref()) {
                        Ok(slot) => return Wait::Turn(TurnGuard::new(guard, slot)),
                        // Its parent's run slots are all taken: it waits for one to free (or a
                        // limit to change), or to be withdrawn.
                        Err(parent) => {
                            drop(guard);
                            if slot_wait.is_none() {
                                slot_wait = Some(self.mark_waiting_for_slot(&parent, session));
                            }
                            tokio::select! {
                                () = moved => {}
                                () = freed => {}
                                () = withdraw.notified() => return Wait::Withdrawn,
                            }
                            continue;
                        }
                    }
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
    /// went well. The person's wait until a client resumes them (`resume_queue`) or sends one now
    /// (`put_next`); a prompt sent meanwhile runs ahead of them. Agent messages go in again by
    /// themselves (`digest.rs` `retry_held_agent_messages`).
    pub(super) fn pause_queue(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
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
            self.retry_held_agent_messages(session);
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
    /// it, nor does the turn it stops. False when it no longer waits; `queue.not_author` when
    /// `editor` did not send it (`author.rs`).
    pub(super) fn put_next(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        editor: crate::author::Editor<'_>,
    ) -> Result<bool, RpcError> {
        let order: Vec<String> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(from) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return Ok(false);
            };
            crate::author::may_change(editor, queue[from].sender())?;
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
        Ok(true)
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
    /// Only `editor`'s own prompt (`author.rs`), checked as it leaves.
    pub fn withdraw_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        editor: crate::author::Editor<'_>,
    ) -> Result<bool, RpcError> {
        if session.moving().is_some() {
            return Err(moving_error());
        }
        self.remove_queued_by(session, prompt_id, None, editor)
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
        self.remove_queued_by(session, prompt_id, reason, None).unwrap_or(false)
    }

    /// `remove_queued_because`, only when `editor` sent it (`author.rs`; `None`: the hub's own).
    fn remove_queued_by(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        reason: Option<&str>,
        editor: crate::author::Editor<'_>,
    ) -> Result<bool, RpcError> {
        let (removed, mut ledger) = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return Ok(false);
            };
            crate::author::may_change(editor, queue[i].sender())?;
            // Pin the identity before it leaves the queue: its runner may settle it meanwhile.
            let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
            session.queued.fetch_sub(1, Ordering::SeqCst);
            (queue.remove(i), ledger)
        };
        let why = reason.map_or_else(|| json!({}), |reason| json!({"reason": reason}));
        self.settle_removed(session, removed, &mut ledger, why);
        Ok(true)
    }

    /// A prompt taken out of the queue (`remove_queued_because`, `supersede.rs`): its
    /// `queue_removed` record, with the fields of `why`, and its waiting `session/prompt` answers
    /// withdrawn. `ledger` was pinned before it left the queue.
    pub(super) fn settle_removed(
        &self,
        session: &Arc<Session>,
        removed: QueuedPrompt,
        ledger: &mut PromptLedger,
        why: Value,
    ) {
        let prompt_id = removed.prompt_id.as_str();
        let mut msg =
            json!({"promptId": prompt_id, "turnId": removed.turn_id, "queued": session.queued()});
        if let (Some(msg), Value::Object(why)) = (msg.as_object_mut(), why) {
            msg.extend(why);
        }
        self.append(session, "mux", "queue_removed", msg);
        // Finish the best-effort append before settlement can evict the retry identity.
        if removed.restored {
            if let Some((_, outcome)) = ledger.iter().find(|(id, _)| id == prompt_id) {
                outcome.send_replace(Some(Ok(withdrawn_reply(prompt_id, &removed.turn_id))));
            }
            prompt_ledger::prune(ledger);
        }
        session.queue_moved.notify_waiters();
        // A stored permit: the waiting task sees it even before it polls.
        removed.withdraw.notify_one();
    }

    /// At load: puts back every prompt the log shows queued but never dequeued, started or
    /// removed, in queue order, after any dequeued whose turn never started (`lost_start.rs`).
    /// They run once `resume_queues` starts them; a client that resends one meanwhile waits for
    /// that run (the ledger entry made here).
    pub(super) fn restore_queues(&self) {
        // Sessions restore apart (each reads only its own log), so they run on every core.
        let sessions = self.sessions();
        self.on_every_core(&sessions, |session| self.restore_queue(session));
    }

    /// The record kinds `restore_queue` reads; the store parses no other line.
    const QUEUE_KINDS: &[&str] = &[
        // Restore the branch baseline in this same pass, never by rereading at attach.
        "git",
        "queued",
        "transfer_out",
        "transfer_aborted",
        "imported",
        "dequeued",
        "queue_removed",
        "user_message",
        "turn_started",
        "queue_updated",
        "queue_paused",
        "queue_resumed",
        "queue_order",
        // What settles a dequeued prompt (`lost_start.rs`).
        "turn_result",
        "prompt_refused",
        // A paused agent pair's records (`agent_pairs.rs`).
        "agent_pair_held",
        "agent_pair_released",
        "agent_pair_dropped",
        "agent_pair_paused",
        "agent_pair_resumed",
    ];

    /// One session's queue, from its log (also a chat moved here, `transfer_in.rs`).
    pub(super) fn restore_queue(&self, session: &Arc<Session>) {
        if session.meta().status == SessionStatus::Closed {
            return;
        }
        let mut waiting = queue_waiting::Waiting::default();
        let mut order = queue_waiting::Order::default();
        let mut held: std::collections::HashSet<String> = Default::default();
        // A move that began and neither committed nor aborted (`transfer_out.rs`); a chat
        // moved here was the source's until its `imported` record.
        let mut moving: Option<String> = None;
        // What a paused agent pair held here, what its releases took, its pauses and resumes,
        // and the prompt ids that reached the session (`agent_pairs.rs`).
        let mut pair_records: Vec<EventRecord> = Vec::new();
        let mut recorded: std::collections::HashSet<String> = Default::default();
        let mut unstarted = lost_start::Unstarted::default();
        let mut branch = session.meta().git_branch;
        let scanned =
            self.store.scan_kinds(&session.id, Self::QUEUE_KINDS, &mut |e: EventRecord| {
                for (prompt_id, turn_id) in unstarted.read(&e, &waiting, &mut order) {
                    waiting.remove_turn(Some(&turn_id));
                    order.remove(&prompt_id);
                }
                let turn_id = e.msg.get("turnId");
                // Queued or run again under another turn id (a daemon that had not restored it
                // took its id as new): that copy is the prompt's, so this one does not run too.
                if matches!(e.kind.as_str(), "queued" | "user_message" | "turn_started")
                    && let Some(id) = e.msg.get("promptId")
                {
                    waiting.remove_other_turns(id, turn_id);
                }
                if matches!(e.kind.as_str(), "queued" | "user_message")
                    && let Some(id) = e.msg.get("promptId").and_then(Value::as_str)
                {
                    recorded.insert(id.to_owned());
                }
                match e.kind.as_str() {
                    "git" if e.dir == "mux" => {
                        branch = e.msg.get("gitBranch").and_then(Value::as_str).map(str::to_owned);
                    }
                    "queued" => {
                        // A restart's continuation of a cut turn goes ahead of what waited behind
                        // that turn, also when the daemon stopped before its `queue_order`
                        // (`restart_resume.rs`); a later reorder still holds.
                        if e.msg.pointer("/_meta/provenance/reason").and_then(Value::as_str)
                            == Some("daemon_restart")
                            && let Some(id) = e.msg.get("promptId")
                        {
                            order.prioritize_restart(id);
                        }
                        waiting.push(e);
                    }
                    "agent_pair_held"
                    | "agent_pair_released"
                    | "agent_pair_dropped"
                    | "agent_pair_paused"
                    | "agent_pair_resumed" => pair_records.push(e),
                    "transfer_out" => moving = e.msg["transferId"].as_str().map(str::to_owned),
                    "transfer_aborted" | "imported" => moving = None,
                    // Left the queue for a turn that has not started (`lost_start.rs`): its
                    // `queued` record stays waiting, so later records apply to it, and it goes
                    // back ahead of the queue.
                    "dequeued" | "user_message" if unstarted.holds(turn_id) => {
                        unstarted.lead(&mut order);
                    }
                    "dequeued" | "queue_removed" | "user_message" | "turn_started" => {
                        waiting.remove_turn(turn_id);
                    }
                    // An edit (`queue_edit.rs`): the prompt and its rules replace the queued ones,
                    // and it has no `_meta.provenance` (the person rewrote it), unless the edit
                    // kept a person's own (`author.rs`).
                    "queue_updated" => {
                        if let Some(q) = waiting.first_of_turn(turn_id) {
                            for k in [
                                "text",
                                "prompt",
                                "control",
                                "trustGate",
                                "inlineParts",
                                "displayParts",
                                "images",
                                "pasted",
                            ] {
                                if let Some(value) = e.msg.get(k) {
                                    q.msg[k] = value.clone();
                                } else if let Some(fields) = q.msg.as_object_mut() {
                                    fields.remove(k);
                                }
                            }
                            if let Some(meta) =
                                q.msg.get_mut("_meta").and_then(Value::as_object_mut)
                            {
                                meta.remove("provenance");
                            }
                            if let Some(p) = e.msg.pointer("/_meta/provenance") {
                                let kept = json!({"provenance": p});
                                crate::no_panic::JsonExt::set(&mut q.msg, "_meta", kept);
                            }
                            // The person's now (`digest.rs`), and no sender's to replace.
                            if let Some(fields) = q.msg.as_object_mut() {
                                fields.remove("fromAgent");
                                fields.remove("supersede");
                            }
                        }
                    }
                    "queue_paused" => {
                        let ids = e.msg.get("held").and_then(Value::as_array);
                        let ids = ids.into_iter().flatten().filter_map(Value::as_str);
                        held.extend(ids.map(str::to_owned));
                    }
                    // `resume_held` names the prompts it resumed; `resume_queue` resumes them all.
                    "queue_resumed" => match e.msg.get("promptIds").and_then(Value::as_array) {
                        Some(ids) => ids.iter().filter_map(Value::as_str).for_each(|id| {
                            held.remove(id);
                        }),
                        None => held.clear(),
                    },
                    "queue_order" => {
                        // Sent now (`put_next`): no longer held.
                        if e.msg.get("next") == Some(&Value::Bool(true))
                            && let Some(id) = e.msg.get("promptId").and_then(Value::as_str)
                        {
                            held.remove(id);
                        }
                        let ids = e.msg.get("order").and_then(Value::as_array);
                        order.set(ids.into_iter().flatten());
                        unstarted.lead(&mut order);
                    }
                    _ => {}
                }
                true
            });
        if scanned.is_ok() {
            self.restore_git_branch(session, branch);
        }
        self.restore_agent_pairs(&session.id, pair_records, &recorded);
        session.moving.lock().unwrap_or_else(|e| e.into_inner()).clone_from(&moving);
        let mut waiting = waiting.into_records();
        if scanned.is_err() || waiting.is_empty() {
            return;
        }
        // The last reorder holds (a prompt that left the queue for its turn went back ahead of
        // it); a prompt queued after it keeps its place at the end.
        waiting.sort_by_key(|q| {
            let id = q.msg.get("promptId");
            unstarted.key(id, &order).unwrap_or_else(|| order.key(id))
        });
        // A prompt that left the queue for its turn runs first, as it would have.
        for id in unstarted.prompts() {
            held.remove(id);
        }
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
            // A record from before `fromAgent` names an agent by its provenance (`digest.rs`).
            let from_agent = e.msg.get("fromAgent").and_then(Value::as_str);
            let agent = super::digest::agent_sender(provenance.as_ref(), from_agent);
            let supersede = crate::author::restored_supersede(&e.msg).map(str::to_owned);
            restored.push((prompt_id.clone(), turn_id.clone()));
            queue.push(QueuedPrompt {
                prompt_id: prompt_id.clone(),
                turn_id,
                client: field("client"),
                preview: short_text(&text, 200),
                queued_at: e.at,
                withdraw: Arc::new(Notify::new()),
                run: Arc::new(PromptRun {
                    blocks,
                    display_parts: e.msg.get("displayParts").cloned(),
                    control,
                    trust_gate,
                    provenance,
                    agent,
                    supersede,
                    // A restored prompt names no machine: it does not run a chat out of its
                    // policy's mode (`Hub::full_access_hold`).
                    full_access_device: None,
                }),
                restored: true,
                resume: true,
                steer: false,
                held: held.contains(&prompt_id),
                sent_now: false,
                joined: Arc::new(StdMutex::new(None)),
                requeued: e.msg.get("requeued") == Some(&Value::Bool(true)),
                retries: 0,
            });
            session.queued.fetch_add(1, Ordering::SeqCst);
            ledger.push_back((prompt_id, Arc::new(tokio::sync::watch::channel(None).0)));
        }
        tracing::info!(session = %session.id, queued = queue.len(), "restored queued prompts");
    }

    /// Runs the prompts `restore_queues` put back, each in its place in the queue (after any
    /// turn recovered from an agent host). Called once at daemon start, after adoption.
    pub fn resume_queues(self: &Arc<Self>) {
        // And what a resumed agent pair still held when the daemon stopped (`agent_pairs.rs`).
        self.resume_agent_pair_drains();
        for session in self.sessions() {
            // Agent messages a failed turn held before the restart go in again by themselves.
            self.retry_held_agent_messages(&session);
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
                        // Who sent it: a queued agent message stays that agent's after a restart.
                        provenance: q.run.provenance.clone(),
                        agent: q.run.agent.clone(),
                        display_parts: q.run.display_parts.clone(),
                        ..PromptOptions::default()
                    };
                    let blocks = q.run.blocks.clone();
                    let result = hub.run_prompt(&session, blocks, &q.client, false, opts).await;
                    // A client that resent this prompt id waits on the entry `restore_queues` made.
                    let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some((_, outcome)) = ledger.iter().find(|(id, _)| *id == q.prompt_id) {
                        outcome.send_replace(Some(result.clone()));
                    }
                    prompt_ledger::prune(&mut ledger);
                    drop(ledger);
                    // Refused before its turn (its harness is gone, or it may not start under
                    // the chat's control): it leaves the queue, so the prompts behind it still
                    // run, and its `prompt_refused` says why, so it never just disappears.
                    if let Err(e) = result
                        && hub.remove_queued(&session, &q.prompt_id)
                    {
                        tracing::warn!(session = %session.id, prompt = %q.prompt_id, "restored prompt refused: {}", e.message);
                        let msg = json!({"promptId": q.prompt_id, "turnId": q.turn_id, "client": q.client, "error": e.message, "data": e.data});
                        hub.append(&session, "mux", "prompt_refused", msg);
                    }
                });
            }
        }
    }
}
