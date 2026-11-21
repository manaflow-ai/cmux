//! A chat's prompts take their place in the order they were sent, not the order their reading
//! finished (Leo, 2026-11-17: "when I send a message and it gets queued, the next one should not
//! go before the previous").
//!
//! A connection serves its requests at once, each in a task of its own (`server/mod.rs`), and a
//! prompt is read before it is admitted: its uploads and attachments resolved, its chat's log
//! read (`server/requests.rs`, `turns.rs`). A prompt with an image sent just before a plain one
//! could finish reading second and take the turn, or the queue's place, ahead of it.
//!
//! The connection's reader numbers each `session/prompt` as it reads it, in order, before the
//! request's task is spawned ([`IntakeOrder::take`]). The prompt then waits, just before it takes
//! its place (`turns.rs` `run_prompt_joined`), until every prompt to the same chat numbered
//! before it took its own: queued, started, steered in, or gone (refused, or its request ended).
//! A prompt still reading after [`BOUND`] stops holding later ones, so an earlier prompt that
//! hangs never wedges the chat. What the queue does with a prompt once it has its place (the
//! person's prompts ahead of agents' messages, Send now, steer, interrupt) is unchanged.

use std::collections::{BTreeSet, HashMap};
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;
use tokio::sync::Notify;

/// How long a prompt waits for one sent before it to the same chat that is still being read.
pub(crate) const BOUND: Duration = Duration::from_secs(10);

/// The prompts each chat was sent that have not taken their place yet, by intake number.
#[derive(Default)]
pub(crate) struct IntakeOrder {
    next: AtomicU64,
    open: Mutex<HashMap<String, BTreeSet<u64>>>,
    changed: Notify,
}

/// One prompt's intake number. Dropped, or [`Ticket::release`]d, it holds no later prompt.
pub(crate) struct Ticket {
    order: Arc<IntakeOrder>,
    session: String,
    seq: u64,
    released: AtomicBool,
    taken: AtomicBool,
}

/// The ticket of the prompt being served, in its `prompt_with` (`turns.rs`): released when the
/// prompt takes its place, or when this is dropped (the prompt answered without one).
pub struct Hold(Arc<Ticket>);

tokio::task_local! {
    /// The intake ticket of the `session/prompt` request this task serves.
    static SENT: Option<Arc<Ticket>>;
}

impl IntakeOrder {
    /// Numbers a prompt to `session` (the id its request named), in the order prompts are read.
    pub(crate) fn take(self: &Arc<Self>, session: &str) -> Arc<Ticket> {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let seq = self.next.fetch_add(1, Ordering::SeqCst);
        open.entry(session.to_owned()).or_default().insert(seq);
        Arc::new(Ticket {
            order: self.clone(),
            session: session.to_owned(),
            seq,
            released: AtomicBool::new(false),
            taken: AtomicBool::new(false),
        })
    }

    /// Whether a prompt to `session` numbered before `seq` has not taken its place yet.
    fn earlier_open(&self, session: &str, seq: u64) -> bool {
        let open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        open.get(session).and_then(BTreeSet::first).is_some_and(|first| *first < seq)
    }

    #[cfg(test)]
    pub(crate) fn open_count(&self) -> usize {
        self.open.lock().unwrap_or_else(|e| e.into_inner()).values().map(BTreeSet::len).sum()
    }
}

impl Ticket {
    /// Waits until every prompt to the same chat numbered before this one took its place, or
    /// [`BOUND`] passed. False when the bound ended it.
    pub(crate) async fn wait_turn(&self) -> bool {
        let deadline = tokio::time::Instant::now() + BOUND;
        loop {
            // Enabled before the set is read, so a release in between is not missed.
            let changed = self.order.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if !self.order.earlier_open(&self.session, self.seq) {
                return true;
            }
            tokio::select! {
                () = changed => {}
                () = tokio::time::sleep_until(deadline) => return false,
            }
        }
    }

    /// The prompt took its place (or never will): later prompts no longer wait for it.
    pub(crate) fn release(&self) {
        if self.released.swap(true, Ordering::SeqCst) {
            return;
        }
        {
            let mut open = self.order.open.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(seqs) = open.get_mut(&self.session) {
                seqs.remove(&self.seq);
                if seqs.is_empty() {
                    open.remove(&self.session);
                }
            }
        }
        self.order.changed.notify_waiters();
    }
}

impl Drop for Ticket {
    fn drop(&mut self) {
        self.release();
    }
}

impl Hold {
    /// [`Ticket::wait_turn`].
    pub(crate) async fn wait_turn(&self) -> bool {
        self.0.wait_turn().await
    }

    /// [`Ticket::release`].
    pub(crate) fn release(&self) {
        self.0.release();
    }
}

impl Drop for Hold {
    fn drop(&mut self) {
        self.0.release();
    }
}

/// The chat a `session/prompt` names, as its request names it.
pub(crate) fn sent_to(params: Option<&Value>) -> Option<&str> {
    params?.get("sessionId").and_then(Value::as_str)
}

/// Runs `fut`, a request's work, with its prompt's intake ticket (if any).
pub(crate) async fn scope<F: Future>(ticket: Option<Arc<Ticket>>, fut: F) -> F::Output {
    SENT.scope(ticket, fut).await
}

/// The ticket of the `session/prompt` this task serves, once, for its own chat (`session_id`):
/// a prompt the request's work sends to another chat, or a second one, has none.
pub(crate) fn take_for(session_id: &str) -> Option<Hold> {
    let ticket = SENT.try_with(Clone::clone).ok().flatten()?;
    (ticket.session == session_id && !ticket.taken.swap(true, Ordering::SeqCst))
        .then(|| Hold(ticket))
}
