//! Part of `Hub`; see `hub/mod.rs`. Prompts waiting for a session's running turn.
//!
//! The queue is durable: each `queued` record carries the whole prompt, and a
//! new daemon rebuilds every session's queue from its log (`restore_queues`)
//! and runs it (`resume_queues`), so queued prompts survive a crash, an update
//! relaunch, a quit and a reboot.

use super::queue_admission::QueueLimits;
use super::subsession_runs::{ClaimedTurn, TurnGuard, WaitMark};
use super::*;
use cmux_json::JsonSet as _;
use std::sync::atomic::Ordering;

// A prompt dequeued for a turn that never started goes back at the head (`restore_queue`).
#[path = "lost_start.rs"]
mod lost_start;
// The waiting records and the order a restore reads, indexed (`restore_queue`).
#[path = "queue_waiting.rs"]
mod queue_waiting;

// `_acpmux/queue_approve` and `_acpmux/queue_decline`: a person's prompt waits for the owner.
#[path = "queue_approve.rs"]
mod queue_approve;
pub use queue_approve::Approver;
pub(crate) use queue_approve::approved_prompts_error;
pub(super) use queue_approve::{approved_error, declined_error, released};

// `_meta.acpmux.supersede`: a prompt replaces its sender's queued one under the same key.
#[path = "supersede.rs"]
pub(super) mod supersede;

/// A session's prompt ids and their outcomes (`Session::prompts`, `prompt_ledger.rs`).
pub(super) type PromptLedger = std::collections::VecDeque<(String, PromptOutcome)>;

/// What `_acpmux/queue_remove` did with one prompt (`Hub::withdraw_queued`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Withdrawn {
    Removed,
    /// Not in the queue: it started, ended or was already removed.
    NotWaiting,
    /// Kept: asked for another agent's message only, and it is not one (the person's own, or
    /// an agent's message the person edited, which makes it theirs).
    NotFromAgent,
}

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
    /// A person's prompt that waits for the owner (`author.rs` `approval`, `queue_approve.rs`):
    /// skipped like a held one until approved, never steered.
    pub(super) awaiting_owner: bool,
    /// Its version for the owner's approval: 0 when queued, one more at each edit by its author
    /// (`queue_edit.rs`). `_acpmux/queue_approve` names the one the owner saw.
    pub(super) revision: u64,
    /// Set by `_acpmux/queue_decline` before it is withdrawn: its `session/prompt` answers
    /// `queue.declined`.
    pub(super) declined: Arc<std::sync::atomic::AtomicBool>,
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

    /// It waits aside, not for its place: a failed turn holds it, or it waits for the owner.
    pub(super) fn aside(&self) -> bool {
        self.held || self.awaiting_owner
    }
}

/// A queued prompt and the rules it runs under.
#[derive(Debug, Clone)]
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
    /// Its class when it is another agent's message (`prompt_class.rs`), `None` when it is the
    /// person's; an edit makes it the person's.
    pub(super) class: Option<crate::prompt_class::PromptClass>,
    /// Its `_meta.acpmux.supersede` key (`supersede.rs`); an edit drops it.
    pub(super) supersede: Option<String>,
    /// The paired machine whose Full-access setting covered its sender (`PromptOptions`); an
    /// edit keeps it only from that machine.
    pub(super) full_access_device: Option<String>,
    /// Delivery metadata normalized before queueing or recovered from a durable queued record.
    pub(super) message_id: Option<String>,
    pub(super) message_sender: Option<Value>,
    /// What its content holds, measured once (`queue_admission::run_bytes`).
    pub(super) size: std::sync::OnceLock<u64>,
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
    /// Its class when it is another agent's message (`prompt_class.rs`).
    pub(super) class: Option<crate::prompt_class::PromptClass>,
    /// Its `_meta.acpmux.supersede` key (`supersede.rs`).
    pub(super) supersede: Option<&'a str>,
    /// `PromptOptions::full_access_device`.
    pub(super) full_access_device: Option<&'a str>,
    /// Set to the prompts it replaced when it queues (`enqueue`), for its acceptance.
    pub(super) replaced: &'a std::sync::OnceLock<Vec<String>>,
    /// `PromptOptions::no_queue`.
    pub(super) no_queue: bool,
    /// `PromptOptions::admitted`.
    pub(super) admitted: bool,
    /// An automatic continuation (`PromptOptions::after_turn`, `auto_resume.rs`): it never
    /// queues, so a prompt about to start its turn (`Session::turn_claimed`) does not make it
    /// queue; it waits for the lock, and `check_cut` decides after.
    pub(super) after_turn: bool,
}

/// What a queued prompt's task waits on (`enqueue`): its withdrawal, the turn it joined
/// (`digest.rs`), and whether the owner declined it.
type Waits =
    (Arc<Notify>, Arc<StdMutex<Option<super::digest::Joined>>>, Arc<std::sync::atomic::AtomicBool>);

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

/// What a queued prompt answers that `take_queued` no longer found: the answer of the inbox
/// digest that took it (`inbox_digest.rs` takes messages without the turn lock, so one may go
/// between its task's turn and its take), else `withdrawn`, no turn having run.
async fn gone_reply(
    joined: &StdMutex<Option<super::digest::Joined>>,
    prompt_id: &str,
    withdrawn: Value,
) -> Answer {
    let went_in = joined.lock().unwrap_or_else(|e| e.into_inner()).clone();
    match went_in {
        Some(went_in) => super::digest::joined_reply(&went_in, prompt_id).await,
        None => Ok(withdrawn),
    }
}

/// [`gone_reply`], unless the owner declined it (`queue_approve.rs`): its `queue_moved` may wake
/// its task before its withdrawal does, and the decline is its answer.
async fn gone_or_declined(
    declined: &std::sync::atomic::AtomicBool,
    joined: &StdMutex<Option<super::digest::Joined>>,
    prompt_id: &str,
    turn_id: &str,
    withdrawn: Value,
) -> Answer {
    if declined.load(Ordering::SeqCst) {
        return Err(queue_approve::declined_error(prompt_id, turn_id));
    }
    gone_reply(joined, prompt_id, withdrawn).await
}

/// A restored prompt the owner approved runs under the stricter of its sender's rules and the
/// ones the owner approved it under (`queue_approve.rs`), as it did before the restart. A
/// `queue_approved` record that names none restores as the Web's: the strictest.
fn approved_rules(run: PromptRun, approval: Option<&Value>) -> PromptRun {
    let Some(approval) = approval else { return run };
    let control = Control::from_recorded(approval.get("control").and_then(Value::as_str));
    let trust_gate = approval.get("trustGate").and_then(Value::as_bool).unwrap_or(true);
    run.restricted(control, trust_gate, None)
}

/// Whether a prompt waits in the chat's queue that a failed turn does not hold, read under the
/// queue's lock.
fn queue_waits(session: &Session) -> bool {
    let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    queue.iter().any(|q| !q.aside())
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
        let limits = QueueLimits::of(&*self.config.read().await);
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
                (turn_id, q.map(|q| (q.withdraw.clone(), q.joined.clone(), q.declined.clone())))
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
            // A lane's report to a parent whose close has begun: refused, never reopening it
            // (`lane_reports.rs`). Nothing is awaited from this check to the commit below.
            None if refuses_closing(&p) && closing(session) => return Err(Err(closing_error())),
            None => {
                // A Cloud turn is prepared and captured before the prompt arrives. Reuse its
                // immutable id so the platform fence covers exactly the turn that runs.
                let turn_id = session
                    .prepared_turn_id(p.prompt_id)
                    .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
                // Another agent's message never overtakes the ones a failed turn held: they run
                // again and it waits behind them, to go in with them (`digest.rs`).
                // While a person's Stop holds them (`cancel.rs`), it waits with them, held.
                let stop_held =
                    p.agent.is_some() && (session.stop_hold.load(Ordering::SeqCst) != 0);
                if p.agent.is_some() && !stop_held {
                    // A Stop since the read above keeps them: the release checks under the lock.
                    self.release_held_agent_messages(session, 0);
                }
                // Whether it waits, and its place in the count, are one step under `admit`: two
                // prompts that come together never both find the chat free, so the second
                // queues and is accepted at once instead of waiting unanswered for the lock
                // (fuzz row g, g1). Nothing is awaited under it.
                let awaiting_owner = crate::author::awaits_owner(p.provenance);
                let waiting = {
                    let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
                    // Prompts a failed turn holds (`pause_queue`) or that wait for the owner do
                    // not hold up a new one. A prompt that waits for the owner (its provenance's
                    // `approval`, `author.rs`) always queues.
                    let held = session.queue().iter().filter(|q| q.aside()).count() as u64;
                    // A prompt that took the turn lock and has not shown its turn yet
                    // (`start_turn` runs after awaits) is a turn too. The count is read before
                    // the claim: a prompt counts in `queued` until it holds the claim.
                    let waiting = stop_held
                        || session.queued() > held
                        || (session.turn_claimed() && !p.after_turn)
                        || session.turn().is_some()
                        || awaiting_owner;
                    // It never queues: busy when the queue's own test says it would wait. The
                    // turn lock is tried below, and the queue read again under it.
                    if p.no_queue && waiting {
                        return Err(Err(super::auto_resume::retry_turn::busy()));
                    }
                    session.queued.fetch_add(1, Ordering::SeqCst);
                    waiting
                };
                let withdraw = if waiting {
                    let (waits, position) =
                        self.enqueue_or_refuse(session, &p, &turn_id, limits)?;
                    let mut accepted = json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "state": "queued", "position": position});
                    if awaiting_owner {
                        accepted.set("awaitingOwner", json!(true));
                    }
                    accept(accepted);
                    Some(waits)
                } else {
                    None
                };
                (turn_id, withdraw)
            }
        };
        // `_slot_wait` counts the sub-session as waiting for a run slot from the moment its prompt
        // is queued for one, so the summary that `queued` record brings already says so.
        let (withdraw, _slot_wait): (_, Option<WaitMark>) = match withdraw {
            Some(withdraw) => (withdraw, None),
            None => 'run: {
                let guard = if p.no_queue {
                    // A prompt about to start holds the lock with no turn shown yet. Held, a
                    // turn or a prompt waiting in the queue (read under its lock: the count may
                    // not show one yet) still makes it busy; a prompt that comes later waits
                    // behind it.
                    let guard = session.turn_lock.try_lock().ok();
                    match guard.filter(|_| session.turn().is_none() && !queue_waits(session)) {
                        Some(guard) => ClaimedTurn::new(session, guard),
                        None => {
                            session.queued.fetch_sub(1, Ordering::SeqCst);
                            return Err(Err(super::auto_resume::retry_turn::busy()));
                        }
                    }
                } else {
                    let guard = session.turn_lock.lock().await;
                    // `waiting` was read before the lock: a prompt the owner approved (or a
                    // resumed one) since then waits in the queue ahead of this one and keeps its
                    // place (`queue_approve.rs`). This one queues behind it, never claiming the
                    // turn.
                    if queue_waits(session) {
                        drop(guard);
                        // Its `queued` reservation is still counted.
                        let (waits, position) =
                            self.enqueue_or_refuse(session, &p, &turn_id, limits)?;
                        accept(
                            json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "state": "queued", "position": position}),
                        );
                        break 'run (waits, None);
                    }
                    ClaimedTurn::new(session, guard)
                };
                // Claimed before it leaves the count: a prompt that comes between sees one.
                session.queued.fetch_sub(1, Ordering::SeqCst);
                // Its close may have begun while it waited for the turn.
                if refuses_closing(&p) && closing(session) {
                    return Err(Err(closing_error()));
                }
                // A move began while it waited for the lock (`transfer_out.rs`): it runs nowhere.
                if session.moving().is_some() {
                    return Err(Err(moving_error()));
                }
                // A turn whose task takes the lock after it runs (the turn its agent ran on into
                // as the one before ended, `carried_turn.rs`; one recovered from a host): this
                // prompt waited for the lock, not that turn, and queues behind it.
                if session.turn().is_some() {
                    drop(guard);
                    session.queued.fetch_add(1, Ordering::SeqCst);
                    let (waits, position) =
                        self.enqueue_or_refuse(session, &p, &turn_id, limits)?;
                    accept(
                        json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "state": "queued", "position": position}),
                    );
                    (waits, None)
                } else {
                    match self.take_run_slot(session, p.provenance) {
                        Ok(slot) => {
                            let mut message_opts = PromptOptions::default();
                            super::message_events::restore_message_options(
                                &mut message_opts,
                                p.provenance,
                            );
                            let run = PromptRun {
                                size: Default::default(),
                                blocks: p.blocks.to_vec(),
                                display_parts: p.display_parts.cloned(),
                                control: p.control,
                                trust_gate: p.trust_gate,
                                provenance: p.provenance.cloned(),
                                agent: p.agent.map(str::to_owned),
                                class: p.class,
                                supersede: p.supersede.map(str::to_owned),
                                full_access_device: p.full_access_device.map(str::to_owned),
                                message_id: message_opts.message_id,
                                message_sender: message_opts.message_sender,
                            };
                            session.accept_prepared(p.prompt_id, &turn_id);
                            return Ok((
                                turn_id,
                                false,
                                TurnGuard::new(guard, slot),
                                Arc::new(run),
                            ));
                        }
                        // The parent's run slots are all taken: it waits in the queue for one.
                        Err(parent) => {
                            drop(guard);
                            if p.no_queue {
                                return Err(Err(super::auto_resume::retry_turn::busy()));
                            }
                            let mark = self.mark_waiting_for_slot(&parent, session);
                            session.queued.fetch_add(1, Ordering::SeqCst);
                            let (waits, position) =
                                self.enqueue_or_refuse(session, &p, &turn_id, limits)?;
                            session.accept_prepared(p.prompt_id, &turn_id);
                            accept(
                                json!({"sessionId": session.id, "promptId": p.prompt_id, "turnId": turn_id, "queued": true, "state": "queued", "position": position, "waitsForSlot": true}),
                            );
                            (waits, Some(mark))
                        }
                    }
                }
            }
        };
        let (withdraw, joined, declined) = withdraw;
        // A steer the agent cannot take goes next, and stops the turn that runs now, unless it was
        // aimed at a turn that has ended since: the one running now is another prompt's.
        if p.interrupt {
            let running = session.turn().map(|t| t.turn_id);
            if self.put_next(session, p.prompt_id, None).is_ok_and(|next| next)
                && let Some(running) = running
                && p.interrupt_turn.is_none_or(|aimed| aimed == running)
            {
                self.cancel_turn_for_replacement(session, &running, p.prompt_id).await;
            }
        }
        // A queued prompt `remove_queued` withdraws answers at once, not when the turn ends.
        // A lane's report queued behind a turn its parent's close then ended is refused before
        // its turn starts (`turns.rs`), so it never reopens the parent.
        let (guard, run) = loop {
            match self.queue_turn(session, &turn_id, &withdraw).await {
                Wait::Turn(guard) => match self.take_queued(session, p.prompt_id, &turn_id) {
                    Ok(Some(run)) => break (guard, run),
                    // It still waits for the owner, whatever let it out (`queue_approve.rs`).
                    Ok(None) => drop(guard),
                    // Gone as its turn came: withdrawn, declined by the owner, or taken into an
                    // inbox digest, which takes no turn lock (`inbox_digest.rs`). The turn is
                    // freed first (the digest runs in it), and the digest's answer is its own
                    // unless that turn failed and put it back (`requeue_joined`): then it waits
                    // again.
                    Err(gone) => {
                        drop(guard);
                        let answer =
                            gone_or_declined(&declined, &joined, p.prompt_id, &turn_id, gone).await;
                        if session.queue().iter().any(|q| q.turn_id == turn_id) {
                            continue;
                        }
                        return Err(answer);
                    }
                },
                // Gone in with an earlier agent message's turn (`digest.rs`): that turn's answer.
                // A failed one put it back in the queue (`requeue_joined`): it waits again.
                Wait::Withdrawn => {
                    let went_in = joined.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    let answer = match went_in {
                        Some(went_in) => super::digest::joined_reply(&went_in, p.prompt_id).await,
                        None if declined.load(Ordering::SeqCst) => {
                            Err(queue_approve::declined_error(p.prompt_id, &turn_id))
                        }
                        None => Ok(withdrawn_reply(p.prompt_id, &turn_id)),
                    };
                    if session.queue().iter().any(|q| q.turn_id == turn_id) {
                        continue;
                    }
                    return Err(answer);
                }
                Wait::Steer => {
                    let run = match self.take_queued(session, p.prompt_id, &turn_id) {
                        Ok(Some(run)) => run,
                        Ok(None) => continue,
                        Err(gone) => {
                            let answer =
                                gone_or_declined(&declined, &joined, p.prompt_id, &turn_id, gone)
                                    .await;
                            if session.queue().iter().any(|q| q.turn_id == turn_id) {
                                continue;
                            }
                            return Err(answer);
                        }
                    };
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
        let digest = super::digest::inbox_digest::is_digest(run.provenance.as_ref());
        // The person's Send now (`queue_edit.rs`) marks it in `steer_now.step` until it steers.
        let persons = session
            .steer_now
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .step
            .contains(prompt_id);
        let (prompt_id, provenance) = (Some(prompt_id.to_owned()), run.provenance.clone());
        let opts = PromptOptions {
            prompt_id,
            message_id: run.message_id.clone(),
            control,
            trust_gate,
            // An inbox digest whose turn ended first waits behind the person's prompts
            // (`enqueue`), and stops no turn.
            interrupt: !digest,
            provenance,
            message_sender: run.message_sender.clone(),
            agent: run.agent.clone(),
            class: run.class,
            display_parts: run.display_parts.clone(),
            full_access_device: run.full_access_device.clone(),
            // Send now is the person's; a digest the drain marked to steer is agents' messages,
            // which a turn past its cap does not take (`turn_cap.rs`): it waits for the next turn.
            send_now: !digest || persons,
            // Taken out of the queue to steer: if it waits again, it waited already.
            admitted: true,
            ..Default::default()
        };
        Box::pin(self.run_prompt(session, run.blocks.clone(), client, true, opts)).await
    }

    /// Stops the turn `turn_id` if it still runs: a bare cancel stops whatever turn runs now,
    /// which may already be the next one.
    pub(super) async fn cancel_turn(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
        if session.turn().is_some_and(|t| t.turn_id == turn_id)
            && let Err(e) = self.cancel(session).await
        {
            tracing::warn!(session = %session.id, "interrupt for a steer: {}", e.message);
        }
    }

    /// Stops only the targeted turn and preserves the prompt that requested its replacement.
    pub(super) async fn cancel_turn_for_replacement(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_id: &str,
        prompt_id: &str,
    ) {
        if session.turn().is_some_and(|t| t.turn_id == turn_id)
            && let Err(e) = self.cancel_preserving_queued(session, Some(prompt_id)).await
        {
            tracing::warn!(session = %session.id, "interrupt for a queued prompt: {}", e.message);
        }
    }

    /// Puts a prompt that waits for the running turn in the queue and tells every client right
    /// away. The returned `Notify` fires when `remove_queued` withdraws it or it joins an earlier
    /// agent message's turn (then `joined` is set, `digest.rs`). Also returns its place in the
    /// queue (1: next), as an inbox digest names its own (`inbox_digest.rs`): where it went in,
    /// not the count, which a prompt about to start its turn is still in. A prompt the queue has
    /// no room for is counted back out of the session's queued total, and its refusal is what
    /// `session/prompt` answers.
    fn enqueue_or_refuse(
        &self,
        session: &Arc<Session>,
        p: &Slot<'_>,
        turn_id: &str,
        limits: QueueLimits,
    ) -> Result<(Waits, u64), Answer> {
        self.enqueue(session, p, turn_id, limits).map_err(|e| {
            session.queued.fetch_sub(1, Ordering::SeqCst);
            Err(e)
        })
    }

    /// [`Self::enqueue_or_refuse`]'s step: puts `p` in the queue, unless it has no room for it
    /// (`queue_admission.rs`): then nothing is put in, written or replaced.
    fn enqueue(
        &self,
        session: &Arc<Session>,
        p: &Slot<'_>,
        turn_id: &str,
        limits: QueueLimits,
    ) -> Result<(Waits, u64), RpcError> {
        // Measured before the lock: under it only sizes measured already are added up.
        let size = super::queue_admission::slot_bytes(p);
        let withdraw = Arc::new(Notify::new());
        let joined = Arc::new(StdMutex::new(None));
        let declined = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let awaiting_owner = crate::author::awaits_owner(p.provenance);
        // `prompt`, `control`, `trustGate`, the provenance and the sending agent let a new daemon
        // run it (`restore_queues`). Made, and its images kept, before the queue's lock: a large
        // image is written without holding up the queue.
        let mut queued = json!({"text": p.text, "client": p.client, "promptId": p.prompt_id, "turnId": turn_id, "prompt": p.blocks, "control": p.control.as_str(), "trustGate": p.trust_gate});
        if let Some(agent) = p.agent {
            queued.set("fromAgent", json!(agent));
        }
        if let Some(class) = p.class {
            queued.set("class", json!(class));
        }
        if let Some(key) = p.supersede {
            queued.set("supersede", json!(key));
        }
        // It waits for the owner (`queue_approve.rs`); a restart keeps it waiting.
        if awaiting_owner {
            queued.set("awaitingOwner", json!(true));
            queued.set("revision", json!(0));
        }
        // Its images are kept now and named, so its row shows them before it runs
        // (`prompt_images.rs`).
        let images = super::prompt_images::keep_sourced(p.blocks, p.display_parts);
        if !images.is_empty() {
            queued.set("images", Value::Array(images));
        }
        let inline_parts = super::prompt_images::inline_parts(
            p.blocks,
            queued.get("images").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default(),
            p.display_parts,
        );
        if !inline_parts.is_empty() {
            queued.set("inlineParts", Value::Array(inline_parts));
        }
        if let Some(display_parts) = p.display_parts {
            queued.set("displayParts", display_parts.clone());
        }
        super::session::mark_pasted(&mut queued, p.blocks);
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Check and insert under one lock: simultaneous prompts cannot all reserve the last
        // held slot. Rejection precedes superseding and logging, so it has no queue side effects;
        // `enqueue_or_refuse` counts it back out of the session's queued total.
        if awaiting_owner {
            queue_approve::held_cap(&queue, p.provenance)?;
        }
        // Checked and put in under one lock, so two prompts cannot both take the last room. The
        // prompts it replaces leave as it comes in, so they do not count against it.
        let replaces = |q: &QueuedPrompt| {
            p.supersede.is_some_and(|key| supersede::superseded(q, key, p.agent, p.prompt_id))
        };
        if !p.admitted {
            // Every prompt waiting but this one: those in the queue, and those about to join it
            // or waiting for the turn lock, which `Session::queued` counts already.
            let others = session.queued.load(Ordering::SeqCst).saturating_sub(1);
            // The messages an inbox digest took wait with it, out of the queue, until its turn
            // takes them over (`digest.rs` `take_joined`) or they go back in: their charge, read
            // under the queue's lock, where every move in or out of it changes it.
            let taken = session.digest_bytes.load(Ordering::SeqCst);
            super::queue_admission::room(&queue, others, taken, size, replaces, limits)?;
        }
        // The sender's prompts under its key leave under the lock that puts this one in
        // (`supersede.rs`), with the ledger pinned first as `remove_queued_because` pins it.
        let superseded = p.supersede.map(|key| {
            let gone = supersede::take(session, &mut queue, key, p.agent, p.prompt_id);
            (gone, session.prompts.lock().unwrap_or_else(|e| e.into_inner()))
        });
        // Ahead of the prompts a failed turn holds: a prompt sent after the failure runs first.
        // The person's prompt goes ahead of every agent message waiting too (`digest.rs`), behind
        // the person's own and a prompt sent now.
        // An inbox digest goes behind the person's prompts, held ones too (`inbox_digest.rs`).
        // Another agent's message while a person's Stop holds them waits held, behind them
        // (`cancel.rs` `hold_agent_messages`); a digest then waits held in its place.
        let stop_held = p.agent.is_some() && (session.stop_hold.load(Ordering::SeqCst) != 0);
        let at = match p.agent {
            Some(_) if super::digest::inbox_digest::is_digest(p.provenance) => {
                Some(super::digest::inbox_digest::place(&queue))
            }
            Some(_) if stop_held => None,
            Some(_) => queue.iter().position(|q| q.held),
            None => queue.iter().position(|q| q.held || (q.run.agent.is_some() && !q.sent_now)),
        };
        let at = at.unwrap_or(queue.len());
        let position = at as u64 + 1;
        // Its place is known once it has one: the `queued` record names it.
        queued.set("position", json!(position));
        let mut message_opts = PromptOptions::default();
        super::message_events::restore_message_options(&mut message_opts, p.provenance);
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
                    size: size.into(),
                    blocks: p.blocks.to_vec(),
                    display_parts: p.display_parts.cloned(),
                    control: p.control,
                    trust_gate: p.trust_gate,
                    provenance: p.provenance.cloned(),
                    agent: p.agent.map(str::to_owned),
                    class: p.class,
                    supersede: p.supersede.map(str::to_owned),
                    full_access_device: p.full_access_device.map(str::to_owned),
                    message_id: message_opts.message_id,
                    message_sender: message_opts.message_sender,
                }),
                restored: false,
                resume: false,
                steer: false,
                held: stop_held,
                awaiting_owner,
                revision: 0,
                declined: declined.clone(),
                sent_now: false,
                joined: joined.clone(),
                requeued: false,
                retries: 0,
            },
        );
        let order: Vec<String> = queue.iter().map(|q| q.prompt_id.clone()).collect();
        let ahead = at + 1 < queue.len();
        if let Some((gone, mut ledger)) = superseded {
            let ids = self.settle_superseded(session, gone, &mut ledger, p.prompt_id);
            let _ = p.replaced.set(ids);
        }
        #[cfg(test)]
        {
            let seam = self.queued_log_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some(seam) = seam {
                seam();
            }
        }
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
        if stop_held {
            self.append(
                session,
                "mux",
                "queue_paused",
                json!({"held": [p.prompt_id], "reason": "stop"}),
            );
        }
        // Logged under the lock that put it in, as approvals, declines and edits are
        // (`queue_approve.rs`, `queue_edit.rs`): none of them can be logged before its `queued`
        // record, which a restart would read as a prompt no answer reached (review of #26747).
        drop(queue);
        Ok(((withdraw, joined, declined), position))
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
                .any(|q| q.turn_id == turn_id && q.steer && !q.awaiting_owner);
            // A chat being moved sends nothing into its turn; an abort lets it steer again.
            if steer && session.moving().is_none() {
                return Wait::Steer;
            }
            let guard = tokio::select! {
                guard = session.turn_lock.lock() => guard,
                () = withdraw.notified() => return Wait::Withdrawn,
                () = moved.as_mut() => continue,
            };
            // Prompts a failed turn holds, or that wait for the owner, wait wherever they are; the
            // first other one is next. Read with the lock held: the turn that just ended may have
            // held this one.
            let (head, held, provenance) = {
                let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let mine = queue.iter().find(|q| q.turn_id == turn_id);
                let held = mine.is_some_and(QueuedPrompt::aside);
                let provenance = mine.and_then(|q| q.run.provenance.clone());
                let head = queue.iter().find(|q| !q.aside()).is_none_or(|q| q.turn_id == turn_id);
                (head, held, provenance)
            };
            let moving = session.moving().is_some();
            if head && !held && !moving && session.turn().is_none() {
                if !self.shutting_down() {
                    match self.take_run_slot(session, provenance.as_ref()) {
                        // Claimed before `take_queued` takes it out of the count.
                        Ok(slot) => {
                            return Wait::Turn(TurnGuard::new(
                                ClaimedTurn::new(session, guard),
                                slot,
                            ));
                        }
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
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // A person's Stop's hold ends with it (`cancel.rs`), under the lock that begins it.
        session.stop_hold.store(0, Ordering::SeqCst);
        for q in queue.iter_mut() {
            resumed |= std::mem::take(&mut q.held);
        }
        drop(queue);
        if resumed {
            session.queue_moved.notify_waiters();
            self.append(session, "mux", "queue_resumed", json!({"queued": session.queued()}));
        }
        resumed
    }

    /// Runs only the held prompts named in `ids` (the ones one failed turn held, `auto_resume.rs`).
    /// False when none of them was held. While a person's Stop holds the other agents' messages
    /// (`cancel.rs`), those stay held: an automatic release (a failed turn's retry wait, a
    /// continuation's end) never ends that hold; only the person's next turn or a resume does.
    /// Read under the queue's lock, where the hold begins and ends.
    pub(super) fn resume_held(&self, session: &Arc<Session>, ids: &[String]) -> bool {
        let mut released = Vec::new();
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let stop_held = session.stop_hold.load(Ordering::SeqCst) != 0;
        for q in queue.iter_mut() {
            if ids.contains(&q.prompt_id)
                && !(stop_held && q.run.agent.is_some())
                && std::mem::take(&mut q.held)
            {
                released.push(q.prompt_id.clone());
            }
        }
        drop(queue);
        let resumed = !released.is_empty();
        if resumed {
            session.queue_moved.notify_waiters();
            // Only those it let go: one the Stop still holds stays held, in a client and after a
            // restart (`restore_queue`).
            self.append(
                session,
                "mux",
                "queue_resumed",
                json!({"queued": session.queued(), "promptIds": released}),
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
            let Some(item) = queue.get(from) else { return Ok(false) };
            crate::author::may_change(editor, item.sender())?;
            // Checked under the lock that moves it (`queue_approve.rs`).
            released(item)?;
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
    /// turn: the reply its `session/prompt` answers instead. One that still waits for the owner
    /// stays (`None`), whatever flag let its task out (`queue_approve.rs`): it never runs.
    pub(super) fn take_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
    ) -> Result<Option<Arc<PromptRun>>, Value> {
        let run = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.turn_id == turn_id) else {
                return Err(withdrawn_reply(prompt_id, turn_id));
            };
            if let Some(q) = queue.get_mut(i).filter(|q| q.awaiting_owner) {
                // Its steer flag goes: once approved it runs in its place, never as a steer.
                q.steer = false;
                return Ok(None);
            }
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
        Ok(Some(run))
    }

    /// `_acpmux/queue_remove`: `remove_queued`, refused while the chat is being moved.
    /// Only `editor`'s own prompt (`author.rs`), checked as it leaves; with `from_agents_only`
    /// (`acpmux session queue clear --from-agents`), only while it is still another agent's
    /// message, checked under the same lock: an edit that made it the person's keeps it queued.
    pub fn withdraw_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        editor: crate::author::Editor<'_>,
        from_agents_only: bool,
    ) -> Result<Withdrawn, RpcError> {
        if session.moving().is_some() {
            return Err(moving_error());
        }
        self.remove_queued_by(session, prompt_id, None, editor, from_agents_only)
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
        self.remove_queued_by(session, prompt_id, reason, None, false)
            .is_ok_and(|w| w == Withdrawn::Removed)
    }

    /// `remove_queued_because`, only when `editor` sent it (`author.rs`; `None`: the hub's own)
    /// and, with `from_agents_only`, only another agent's message.
    fn remove_queued_by(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        reason: Option<&str>,
        editor: crate::author::Editor<'_>,
        from_agents_only: bool,
    ) -> Result<Withdrawn, RpcError> {
        let (removed, mut ledger) = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let Some(i) = queue.iter().position(|q| q.prompt_id == prompt_id) else {
                return Ok(Withdrawn::NotWaiting);
            };
            let Some(item) = queue.get(i) else { return Ok(Withdrawn::NotWaiting) };
            // Who may change it first: a filtered removal tells no one else whose prompt it is.
            crate::author::may_change(editor, item.sender())?;
            if from_agents_only && item.run.agent.is_none() {
                return Ok(Withdrawn::NotFromAgent);
            }
            // Pin the identity before it leaves the queue: its runner may settle it meanwhile.
            let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
            session.queued.fetch_sub(1, Ordering::SeqCst);
            (queue.remove(i), ledger)
        };
        let why = reason.map_or_else(|| json!({}), |reason| json!({"reason": reason}));
        self.settle_removed(session, removed, &mut ledger, why);
        Ok(Withdrawn::Removed)
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
            let answer = if removed.declined.load(Ordering::SeqCst) {
                Err(queue_approve::declined_error(prompt_id, &removed.turn_id))
            } else {
                Ok(withdrawn_reply(prompt_id, &removed.turn_id))
            };
            if let Some((_, outcome)) = ledger.iter().find(|(id, _)| id == prompt_id) {
                prompt_ledger::settle_once(outcome, answer);
            }
            prompt_ledger::prune(ledger);
        }
        session.queue_moved.notify_waiters();
        // A stored permit: the waiting task sees it even before it polls.
        removed.withdraw.notify_one();
    }

    /// The record kinds `restore_queue` reads; the store parses no other line.
    pub(crate) const QUEUE_KINDS: &[&str] = &[
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
        // The owner's answer to a prompt that waits for them (`queue_approve.rs`).
        "queue_approved",
        "queue_declined",
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

    /// One session's queue, from its log (at load, `log_load.rs`, and for a chat moved here,
    /// `transfer_in.rs`): puts back every prompt the log shows queued but never dequeued, started
    /// or removed, in queue order, after any dequeued whose turn never started (`lost_start.rs`).
    /// They run once `resume_restored` starts them; a client that resends one meanwhile waits for
    /// that run (the ledger entry made here).
    pub(super) fn restore_queue(&self, session: &Arc<Session>) {
        self.restore_queue_only(session, None);
    }

    /// [`Self::restore_queue`]; with `only`, a live chat takes back just that logged prompt and
    /// nothing else is rebuilt (its inbox, agent pairs, branch and move state are live already).
    pub(super) fn restore_queue_only(&self, session: &Arc<Session>, only: Option<&str>) {
        // Other agents' messages are in its inbox, apart from the queue (`inbox.rs`); a closed
        // chat's threads stay readable.
        if only.is_none() {
            self.restore_inbox(session);
        }
        if session.meta().status == SessionStatus::Closed {
            return;
        }
        let mut waiting = queue_waiting::Waiting::default();
        let mut order = queue_waiting::Order::default();
        let mut held: std::collections::HashSet<String> = Default::default();
        // The revision the owner approved, by the queued prompt's turn id (`queue_approve.rs`):
        // its incarnation, never its client-chosen prompt id, which a later prompt may reuse.
        let mut approved: HashMap<String, Value> = Default::default();
        // A begun move not yet ended (`transfer_out.rs` `restored_moving`), until `imported`.
        let mut moving: Option<String> = None;
        // What a paused agent pair held here, what its releases took, its pauses and resumes,
        // and the prompt ids that reached the session (`agent_pairs.rs`).
        let mut pair_records: Vec<EventRecord> = Vec::new();
        let mut recorded: std::collections::HashSet<String> = Default::default();
        let mut unstarted = lost_start::Unstarted::default();
        let mut digests = queue_waiting::Digests::default();
        let mut branch = session.meta().git_branch;
        let scanned =
            self.store.scan_kinds(&session.id, Self::QUEUE_KINDS, &mut |e: EventRecord| {
                for (prompt_id, turn_id) in unstarted.read(&e, &waiting, &mut order) {
                    waiting.remove_turn(Some(&turn_id));
                    order.remove(&prompt_id);
                }
                digests.read(&e);
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
                        // A restart's or a move's continuation of a cut turn goes ahead of what
                        // waited behind that turn, also when the daemon stopped before its
                        // `queue_order` (`restart_resume.rs`); a later reorder still holds.
                        if super::auto_resume::Cut::queued(
                            e.msg.pointer("/_meta/provenance/reason").and_then(Value::as_str),
                        ) && let Some(id) = e.msg.get("promptId")
                        {
                            order.prioritize_restart(id);
                        }
                        // An inbox digest holds the queue's order with it in it, as its
                        // `queue_order` record does.
                        if super::digest::inbox_digest::is_digest_record(&e.msg)
                            && let Some(ids) = e.msg.get("order").and_then(Value::as_array)
                        {
                            order.set(ids.iter());
                            unstarted.lead(&mut order);
                        }
                        // Put back after a failed turn (`requeue_joined`): this copy replaces
                        // the one the turn took (an inbox digest's message is still waiting).
                        if e.msg.get("requeued") == Some(&Value::Bool(true)) {
                            waiting.remove_turn(turn_id);
                        }
                        waiting.push(e);
                    }
                    "agent_pair_held"
                    | "agent_pair_released"
                    | "agent_pair_dropped"
                    | "agent_pair_paused"
                    | "agent_pair_resumed" => pair_records.push(e),
                    // The daemon's own records only: an agent's update may carry any kind.
                    "transfer_out" if e.dir == "mux" => {
                        moving = e.msg.get("transferId").and_then(Value::as_str).map(str::to_owned)
                    }
                    "transfer_aborted" | "imported" if e.dir == "mux" => moving = None,
                    // Left the queue for a turn that has not started (`lost_start.rs`): its
                    // `queued` record stays waiting, so later records apply to it, and it goes
                    // back ahead of the queue.
                    "dequeued" | "user_message" if unstarted.holds(turn_id) => {
                        unstarted.lead(&mut order);
                    }
                    // Taken into an inbox digest: it waits until that digest's turn starts
                    // (`queue_waiting.rs` `Digests`).
                    "dequeued" if e.msg.get("digestPromptId").is_some() => {}
                    "dequeued" | "queue_removed" | "queue_declined" | "user_message"
                    | "turn_started" => {
                        waiting.remove_turn(turn_id);
                    }
                    "queue_approved" => {
                        if let Some(turn) = turn_id.and_then(Value::as_str) {
                            approved.insert(turn.to_owned(), e.msg.clone());
                        }
                    }
                    // An edit (`queue_edit.rs`): the prompt and its rules replace the queued ones,
                    // and it has no `_meta.provenance` (the person rewrote it), unless the edit
                    // kept a person's own (`author.rs`).
                    "queue_updated" => {
                        // A revision never goes back: a log from before edits were logged under
                        // the queue lock may hold an older edit after a newer one, and the newer
                        // one is the words the queue had (and an approval may name).
                        let revision = e.msg.get("revision").and_then(Value::as_u64);
                        let stale = |had: Option<&Value>| {
                            matches!((revision, had.and_then(Value::as_u64)), (Some(new), Some(had)) if new < had)
                        };
                        if let Some(q) =
                            waiting.first_of_turn(turn_id).filter(|q| !stale(q.msg.get("revision")))
                        {
                            for k in [
                                "text",
                                "prompt",
                                "control",
                                "trustGate",
                                "inlineParts",
                                "displayParts",
                                "images",
                                "pasted",
                                // An edit of a prompt that waits for the owner waits again.
                                "awaitingOwner",
                                "revision",
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
                                // The person rewrote it: no longer another session's message.
                                meta.remove(crate::prompt_provenance::MESSAGE_META);
                            }
                            if let Some(p) = e.msg.pointer("/_meta/provenance") {
                                let kept = json!({"provenance": p});
                                crate::no_panic::JsonExt::set(&mut q.msg, "_meta", kept);
                            }
                            // The person's now (`digest.rs`), and no sender's to replace.
                            if let Some(fields) = q.msg.as_object_mut() {
                                fields.remove("fromAgent");
                                fields.remove("class");
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
        if only.is_none() {
            if scanned.is_ok() {
                self.restore_git_branch(session, branch);
            }
            self.restore_agent_pairs(&session.id, pair_records, &recorded);
            *session.moving.lock().unwrap_or_else(|e| e.into_inner()) =
                transfer_out::restored_moving(scanned.is_ok(), moving);
        }
        // An inbox digest whose turn never started gives its messages back in its place.
        digests.finish(&mut waiting, &mut order, |id, order| {
            unstarted.key(Some(&json!(id)), order).unwrap_or_else(|| order.key(Some(&json!(id))))
        });
        let mut waiting = waiting.into_records();
        if scanned.is_err() || waiting.is_empty() {
            return;
        }
        // The last reorder holds (a prompt that left the queue for its turn went back ahead of
        // it); a prompt queued after it keeps its place at the end.
        // An inbox digest's messages share its place, in their order (`Digests::rank`).
        waiting.sort_by_key(|q| {
            let id = q.msg.get("promptId");
            (unstarted.key(id, &order).unwrap_or_else(|| order.key(id)), digests.rank(id))
        });
        // A prompt that left the queue for its turn runs first, as it would have.
        for id in unstarted.prompts() {
            held.remove(id);
        }
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
        let mut restored = session.restored.lock().unwrap_or_else(|e| e.into_inner());
        let mut restored_any = false;
        for e in waiting {
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let (prompt_id, turn_id, text) = (field("promptId"), field("turnId"), field("text"));
            // Restored already: a second pass (a chat settled after adoption, `log_load.rs`)
            // adds only what the first did not see.
            if prompt_id.is_empty()
                || turn_id.is_empty()
                || only.is_some_and(|only| only != prompt_id)
                || queue.iter().any(|q| q.prompt_id == prompt_id)
            {
                continue;
            }
            // A record from before the prompt was logged has its text only.
            let blocks = match e.msg.get("prompt").and_then(Value::as_array) {
                Some(blocks) => blocks.clone(),
                None => vec![json!({"type": "text", "text": text})],
            };
            let control = Control::from_recorded(e.msg.get("control").and_then(Value::as_str));
            let trust_gate = e.msg.get("trustGate").and_then(Value::as_bool).unwrap_or(false);
            let provenance = crate::prompt_provenance::recorded(&e.msg).filter(|p| p.is_object());
            // An inbox notice is never run again: what it carried is new again (`inbox.rs`).
            if super::inbox::is_notice(provenance.as_ref()) {
                continue;
            }
            let mut restored_message_opts = PromptOptions::default();
            super::message_events::restore_message_options(
                &mut restored_message_opts,
                provenance.as_ref(),
            );
            // A record from before `fromAgent` names an agent by its provenance (`digest.rs`).
            let from_agent = e.msg.get("fromAgent").and_then(Value::as_str);
            let agent = super::digest::agent_sender(provenance.as_ref(), from_agent);
            // A record from before classes: an agent's message is a result (`prompt_class.rs`).
            let class = crate::prompt_class::of_message(
                crate::prompt_class::recorded(&e.msg),
                agent.is_some(),
            );
            let supersede = crate::author::restored_supersede(&e.msg).map(str::to_owned);
            // Its approval counts for this incarnation at the revision the owner saw, which an
            // edit since replaced.
            let revision = e.msg.get("revision").and_then(Value::as_u64);
            let approval = approved
                .get(&turn_id)
                .filter(|a| a.get("revision").and_then(Value::as_u64) == revision);
            // A link guest's prompt waits whatever its record says (`author::awaits_owner`): one
            // an older writer recorded unmarked never runs unapproved after a restart.
            let awaiting_owner = (e.msg.get("awaitingOwner") == Some(&Value::Bool(true))
                || crate::author::awaits_owner(provenance.as_ref()))
                && approval.is_none();
            restored.push((prompt_id.clone(), turn_id.clone()));
            let display_parts = e.msg.get("displayParts").cloned();
            let size = super::queue_admission::content_bytes(&blocks, display_parts.as_ref());
            queue.push(QueuedPrompt {
                prompt_id: prompt_id.clone(),
                turn_id,
                client: field("client"),
                preview: short_text(&text, 200),
                queued_at: e.at,
                withdraw: Arc::new(Notify::new()),
                run: Arc::new(approved_rules(
                    PromptRun {
                        size: size.into(),
                        blocks,
                        display_parts,
                        control,
                        trust_gate,
                        provenance,
                        agent,
                        class,
                        supersede,
                        // A restored prompt names no machine: it does not run a chat out of its
                        // policy's mode (`Hub::full_access_hold`).
                        full_access_device: None,
                        message_id: restored_message_opts.message_id,
                        message_sender: restored_message_opts.message_sender,
                    },
                    approval,
                )),
                restored: true,
                resume: true,
                steer: false,
                held: held.contains(&prompt_id),
                awaiting_owner,
                revision: revision.unwrap_or(0),
                declined: Default::default(),
                sent_now: false,
                joined: Arc::new(StdMutex::new(None)),
                requeued: e.msg.get("requeued") == Some(&Value::Bool(true)),
                retries: 0,
            });
            restored_any = true;
            session.queued.fetch_add(1, Ordering::SeqCst);
            ledger.push_back((prompt_id, Arc::new(tokio::sync::watch::channel(None).0)));
        }
        let restored_count = queue.len();
        drop(restored);
        drop(ledger);
        drop(queue);
        // A visible attach may have answered before this background log restore. Publish one
        // durable change notice so session_changed publishes the current queue summary. It must
        // not persist an order captured before dropping the lock: a concurrent enqueue may have
        // already written a newer order. This notice has no replay effect. A second restore adds
        // no prompt and emits nothing.
        if restored_any {
            self.append(session, "mux", "queue_restored", json!({}));
        }
        tracing::info!(session = %session.id, queued = restored_count, "restored queued prompts");
    }

    /// Runs the prompts `restore_queue` put back, each in its place in the queue (after any
    /// turn recovered from an agent host). Called at daemon start, after adoption, and after an
    /// import. A chat whose log is read later resumes its own (`log_load.rs`).
    pub fn resume_queues(self: &Arc<Self>) {
        self.queues_resumed.store(true, Ordering::SeqCst);
        // And what a resumed agent pair still held when the daemon stopped (`agent_pairs.rs`).
        self.resume_agent_pair_drains();
        for session in self.sessions() {
            // Under its load lock: a log read now resumes its own queue (`log_load.rs`).
            let loaded = session.log_load.lock().unwrap_or_else(|e| e.into_inner());
            if *loaded {
                self.resume_restored(std::slice::from_ref(&session));
            }
        }
    }

    /// Runs `sessions`' restored prompts not started yet (each once: its `resume` mark). A chat
    /// in a privacy-protected folder that no client shows waits for the person instead
    /// (`protected_hold.rs`).
    pub(super) fn resume_restored(self: &Arc<Self>, sessions: &[Arc<Session>]) {
        self.resume_restored_as(sessions, false);
    }

    /// `resume_restored`; `asked`: the person asked for these chats now, so a protected folder
    /// holds nothing (`release_protected_hold`).
    pub(super) fn resume_restored_as(self: &Arc<Self>, sessions: &[Arc<Session>], asked: bool) {
        for session in sessions {
            if !asked && self.hold_in_protected_folder(session) {
                continue;
            }
            self.restore_auto_resume(session);
            // What the restored inbox holds new goes in as it may (`inbox.rs`).
            {
                let (hub, session) = (self.clone(), session.clone());
                tokio::spawn(async move {
                    hub.wait_startup().await;
                    hub.inbox_review(&session);
                });
            }
            // Agent messages a failed turn held before the restart go in again by themselves.
            self.retry_held_agent_messages(session);
            self.start_restored(session);
        }
    }

    /// Runs the chat's restored prompts not started yet (each once: its `resume` mark), and
    /// nothing else `resume_restored` does.
    pub(super) fn start_restored(self: &Arc<Self>, session: &Arc<Session>) {
        {
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
                        message_id: q.run.message_id.clone(),
                        control: q.run.control,
                        trust_gate: q.run.trust_gate,
                        // Who sent it: a queued agent message stays that agent's after a restart.
                        provenance: q.run.provenance.clone(),
                        message_sender: q.run.message_sender.clone(),
                        agent: q.run.agent.clone(),
                        class: q.run.class,
                        display_parts: q.run.display_parts.clone(),
                        ..PromptOptions::default()
                    };
                    let blocks = q.run.blocks.clone();
                    let result = hub.run_prompt(&session, blocks, &q.client, false, opts).await;
                    // A client that resent this prompt id waits on the entry `restore_queues` made.
                    let mut ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some((_, outcome)) = ledger.iter().find(|(id, _)| *id == q.prompt_id) {
                        prompt_ledger::settle_once(outcome, result.clone());
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

/// Whether the prompt is one a closing session refuses: a lane's report.
fn refuses_closing(p: &Slot<'_>) -> bool {
    is_lane_report(p.provenance)
}

fn is_lane_report(provenance: Option<&Value>) -> bool {
    provenance.and_then(|v| v.get("kind")).and_then(Value::as_str)
        == Some(super::lane_reports::KIND)
}

/// Whether a dequeued prompt with `provenance` is a lane's report to `session`, closing now.
pub(super) fn refuses_closing_run(session: &Session, provenance: Option<&Value>) -> bool {
    is_lane_report(provenance) && closing(session)
}

/// Whether `session`'s close has begun (`kill` marks it before anything else) or it is closed.
pub(super) fn closing(session: &Session) -> bool {
    session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed
}

/// The refusal of a lane's report to a session whose close has begun.
pub(super) fn closing_error() -> RpcError {
    RpcError::invalid_params("the session is closing or closed: it takes no prompt")
        .with_data(json!({"reason": "session.closing", "closing": true}))
}
