//! Part of `Hub`; see `hub/mod.rs`. The coordinator setting (`_acpmux/set_coordinator`,
//! `acpmux session coordinator`): a session that many lanes report to reads their messages in
//! batches instead of giving each one a turn (Leo, 2026-10-29: "You never end a fucking turn. As
//! soon as it comes in, it fucking, like, occupies you for another fucking turn.").
//!
//! Another agent's message to a coordinator (`digest.rs` `agent_sender`) is an inbox item: it
//! waits in the chat's queue (`QueuedPrompt::inbox`, shown as `inbox` on its queue row), never
//! steers in and never takes a turn by itself. The person's own prompts are never inbox items and
//! run as before. The inbox goes to the agent as ONE inbox digest (`inbox_digest.rs`, the one
//! renderer), made when:
//!
//! - a block or a question arrives (`prompt_class.rs`) and the chat can read it now: it is idle
//!   (the digest starts a turn) or its running turn steers and is under its cap (the digest
//!   steers in at the agent's next tool step);
//! - a turn ends ([`Hub::coordinator_turn_ended`]) and (a) a block or a question waits, (b) the
//!   turn ran past its cap (`turn_cap.rs`), or (c) the flush is due: the later of the last digest
//!   and the oldest waiting item is `inboxFlushMs` old. One digest per turn end: nothing else
//!   wakes the chat there;
//! - the flush timer fires while the chat is idle (the same (c));
//! - the interval timer fires while a turn runs that steers and is under its cap: the later of
//!   the last digest and the turn's start is `digestIntervalMs` old.
//!
//! Results and FYIs otherwise wait. An item the digest cannot take (an image, an upload, a slash
//! command, a sub-session family message: `inbox_digest.rs` `digestible`) leaves the inbox at the
//! digest and waits in the ordinary queue. The person sending an item now takes it out too
//! (`queue.rs` `put_next`, `queue_edit.rs`). Turning the setting off releases every item where it
//! is, in its order, and they run as other agents' messages do (`digest.rs` fan-in).
//!
//! A restart keeps the inbox: the setting is in `SessionMeta`, each item's `queued` record makes
//! it an inbox item again (`restore_queue`), and its wait counts from that record's time, so the
//! flush comes when it would have.
//!
//! The timer: one per session (`Session::inbox_timer`), for the next flush or interval digest.
//! Stop condition: it wakes once, at its deadline, and ends; it is not armed when the inbox is
//! empty, the setting is off, the session is closed, or a running turn is capped or does not
//! steer (that turn's end decides). Cleanup: every arm aborts the one before (a new item, a turn
//! start or end, a digest, a settings change), turning the setting off or closing the session
//! aborts it, and it holds the hub and the session weakly, so a dropped one ends it.

use super::*;
use crate::prompt_class::PromptClass;
use std::sync::Weak;
use std::sync::atomic::Ordering;

/// How long a coordinator's results and FYIs wait while it is idle when it set no
/// `inboxFlushMs` (Leo's coordinator timing, 2026-10-29).
pub const INBOX_FLUSH_MS: u64 = 10 * 60 * 1000;
/// The least time between two digests steered into a running turn when it set no
/// `digestIntervalMs`.
pub const DIGEST_INTERVAL_MS: u64 = 5 * 60 * 1000;
/// The client a digest the hub makes goes under.
pub const DIGEST_CLIENT: &str = "acpmux";

/// The session's flush, in ms.
pub(crate) fn inbox_flush_ms(meta: &SessionMeta) -> u64 {
    meta.inbox_flush_ms.unwrap_or(INBOX_FLUSH_MS)
}

/// The session's digest interval, in ms.
pub(crate) fn digest_interval_ms(meta: &SessionMeta) -> u64 {
    meta.digest_interval_ms.unwrap_or(DIGEST_INTERVAL_MS)
}

/// Whether a prompt to a session that is a `coordinator` is an inbox item: it is another agent's
/// message (`agent`) that is no digest itself.
pub(super) fn is_inbox_item(coordinator: bool, agent: bool, provenance: Option<&Value>) -> bool {
    coordinator && agent && !super::digest::inbox_digest::is_digest(provenance)
}

/// What the inbox holds now: whether a block or a question waits, and the oldest item's time.
fn inbox_state(session: &Session) -> Option<(bool, u64)> {
    let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let items = || queue.iter().filter(|q| q.inbox);
    let oldest = items().map(|q| q.queued_at).min()?;
    Some((items().any(|q| q.run.class.is_some_and(PromptClass::urgent)), oldest))
}

/// Whether a digest made at `now` reaches the agent now: the chat is idle, or its running turn
/// steers and is under its cap.
fn reaches_now(session: &Session, meta: &SessionMeta, now: u64) -> bool {
    match session.turn() {
        None => true,
        Some(turn) => {
            session.steering.load(Ordering::SeqCst) && !capped(meta, turn.started_at, now)
        }
    }
}

/// Whether a turn that started at `started_at` is past the session's cap at `now`.
fn capped(meta: &SessionMeta, started_at: u64, now: u64) -> bool {
    super::turn_cap::turn_cap_ms(meta).is_some_and(|cap| now.saturating_sub(started_at) >= cap)
}

/// When the inbox is due by time (module docs), `None` when no timer waits for it.
fn deadline(session: &Session, meta: &SessionMeta, now: u64) -> Option<u64> {
    if !meta.coordinator || meta.status == SessionStatus::Closed {
        return None;
    }
    let (_, oldest) = inbox_state(session)?;
    let last = session.last_digest_at.load(Ordering::SeqCst);
    match session.turn() {
        None => Some(last.max(oldest).saturating_add(inbox_flush_ms(meta))),
        Some(turn) if reaches_now(session, meta, now) => {
            Some(last.max(turn.started_at).saturating_add(digest_interval_ms(meta)))
        }
        Some(_) => None,
    }
}

impl Hub {
    /// An inbox item was queued (`queue_slot`): a block or a question the chat can read now
    /// brings the digest at once; anything else waits for the timer or a turn's end.
    pub(super) fn inbox_arrived(
        self: &Arc<Self>,
        session: &Arc<Session>,
        class: Option<PromptClass>,
    ) {
        let meta = session.meta();
        if class.is_some_and(PromptClass::urgent) && reaches_now(session, &meta, now_ms()) {
            self.coordinator_digest(session);
        } else {
            self.arm_inbox(session);
        }
    }

    /// A coordinator's turn ended (`finish_turn`): the one digest a turn end may bring, when a
    /// block or a question waits, the turn (it started at `started_at`; `None` when it never
    /// reached its agent) ran past its cap, or the flush is due; else the timer (module docs).
    pub(super) fn coordinator_turn_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        started_at: Option<u64>,
    ) {
        let meta = session.meta();
        if !meta.coordinator {
            return;
        }
        let now = now_ms();
        let past_cap = started_at.is_some_and(|at| capped(&meta, at, now));
        self.inbox_review(session, &meta, past_cap, now);
    }

    /// Digests the inbox when a block or a question waits, `past_cap`, or the flush is due, and
    /// the chat can read it now; else arms the timer.
    fn inbox_review(
        self: &Arc<Self>,
        session: &Arc<Session>,
        meta: &SessionMeta,
        past_cap: bool,
        now: u64,
    ) {
        let Some((urgent, oldest)) = inbox_state(session) else {
            self.disarm_inbox(session);
            return;
        };
        let last = session.last_digest_at.load(Ordering::SeqCst);
        let due = last.max(oldest).saturating_add(inbox_flush_ms(meta)) <= now;
        if (urgent || past_cap || due) && reaches_now(session, meta, now) {
            self.coordinator_digest(session);
        } else {
            self.arm_inbox(session);
        }
    }

    /// Makes the inbox digest (`inbox_digest.rs`) off the caller's path, one at a time. Items it
    /// could not take leave the inbox; the timer is armed again for what came meanwhile.
    pub(super) fn coordinator_digest(self: &Arc<Self>, session: &Arc<Session>) {
        if session.inbox_digesting.swap(true, Ordering::SeqCst) {
            return;
        }
        self.disarm_inbox(session);
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let made = hub.inbox_digest(&session, DIGEST_CLIENT, false).await;
            if let Err(e) = &made {
                tracing::info!(session = %session.id, "coordinator digest not made: {}", e.message);
            }
            // Made or refused, the clock restarts: a refusal (a move, a watch) is not retried
            // at once, over and over.
            session.last_digest_at.store(now_ms(), Ordering::SeqCst);
            hub.release_undigestible(&session);
            session.inbox_digesting.store(false, Ordering::SeqCst);
            hub.arm_inbox(&session);
        });
    }

    /// Takes the items a digest cannot take out of the inbox: they wait in the ordinary queue.
    fn release_undigestible(&self, session: &Arc<Session>) {
        let released = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut released = false;
            for q in queue.iter_mut().filter(|q| q.inbox) {
                if !super::digest::inbox_digest::digestible(q) {
                    q.inbox = false;
                    released = true;
                }
            }
            released
        };
        if released {
            session.queue_moved.notify_waiters();
        }
    }

    /// Arms the inbox timer for its next deadline, aborting the one before (module docs).
    pub(super) fn arm_inbox(self: &Arc<Self>, session: &Arc<Session>) {
        let mut timer = session.inbox_timer.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = timer.take() {
            previous.abort();
        }
        // A digest being made arms it again once it is.
        if session.inbox_digesting.load(Ordering::SeqCst) {
            return;
        }
        let now = now_ms();
        let Some(at) = deadline(session, &session.meta(), now) else { return };
        let hub = Arc::downgrade(self);
        let weak: Weak<Session> = Arc::downgrade(session);
        let task = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(at.saturating_sub(now))).await;
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            hub.inbox_due(&session);
        });
        *timer = Some(task.abort_handle());
    }

    /// Aborts the inbox timer, if one waits.
    pub(super) fn disarm_inbox(&self, session: &Session) {
        let timer = session.inbox_timer.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(timer) = timer {
            timer.abort();
        }
    }

    /// The timer woke: the digest when the inbox is due and the chat can read it, else the timer
    /// again (a turn started or ended since it was armed, or the deadline moved).
    fn inbox_due(self: &Arc<Self>, session: &Arc<Session>) {
        let meta = session.meta();
        let now = now_ms();
        match deadline(session, &meta, now) {
            Some(at) if at <= now => self.coordinator_digest(session),
            _ => self.arm_inbox(session),
        }
    }

    /// Restored prompts are back in a coordinator's queue (`resume_restored`): what is due now
    /// goes in, the rest waits for its timer.
    pub(super) fn inbox_restored(self: &Arc<Self>, session: &Arc<Session>) {
        let meta = session.meta();
        if meta.coordinator {
            self.inbox_review(session, &meta, false, now_ms());
        }
    }

    /// `_acpmux/set_coordinator`: turns the setting on or off and sets its times (`Some(None)`
    /// clears one back to its default). On, the other agents' messages waiting now become inbox
    /// items; off, every inbox item is released where it is, in its order, and the timer stops.
    pub(crate) fn set_coordinator(
        self: &Arc<Self>,
        session: &Arc<Session>,
        on: Option<bool>,
        flush_ms: Option<Option<u64>>,
        interval_ms: Option<Option<u64>>,
    ) {
        let meta = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(on) = on {
                meta.coordinator = on;
            }
            if let Some(ms) = flush_ms {
                meta.inbox_flush_ms = ms;
            }
            if let Some(ms) = interval_ms {
                meta.digest_interval_ms = ms;
            }
            meta.clone()
        };
        self.save_meta(session);
        {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for q in queue.iter_mut() {
                q.inbox = meta.coordinator
                    && !q.sent_now
                    && !q.steer
                    && is_inbox_item(true, q.run.agent.is_some(), q.run.provenance.as_ref());
            }
        }
        session.queue_moved.notify_waiters();
        if meta.coordinator {
            self.inbox_review(session, &meta, false, now_ms());
        } else {
            self.disarm_inbox(session);
        }
    }
}

#[cfg(test)]
#[path = "coordinator_tests.rs"]
mod tests;
