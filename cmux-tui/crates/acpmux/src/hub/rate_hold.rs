//! A chat whose account hit its rate limit starts no turn until the limit resets (Leo,
//! 2026-11-17: "the old coord keeps running into these rate limit spirals" / "oh i mean not gh").
//!
//! claude-sr2-coord-old (a 323K-token context) failed 207 of its last 400 turns with "API Error:
//! Request rejected (429) · This request would exceed your account's rate limit". Each failed turn
//! sent the whole context again, against the same account limit: 49.4M input tokens in a day. The
//! 429 was retried as a 529 (`capacity`), and every message from another agent (26 of them) and
//! every background notice started a turn of its own, each with its own chain of four
//! continuations, so the retries multiplied instead of backing off.
//!
//! - A turn that fails on the account's usage or rate limit has reason `rate_limit`
//!   (`turn_errors::resume_cause`), told apart from a provider's 529 or a gateway's 503.
//! - The chat is then held ([`RateHold`]) until the reset: `retry-after` or the error's own reset
//!   (`reset_hint.rs`), else the account's `rate_limit_event` window
//!   (`claude_stdio/usage_limits.rs`), else the continuation's configured wait. One timer per chat,
//!   whatever comes in meanwhile; a later 429 moves the same hold's deadline.
//! - While held no turn starts (`queue.rs`): another agent's message, a background notice and
//!   the person's own prompt all queue. Only acpmux's own continuation of the cut turn runs, once
//!   the hold is due.
//! - At the reset the continuation decides once ([`Hub::rate_hold_due`]): when anything queued
//!   meanwhile, it is not sent; the queue's next turn carries its words instead, and the agent
//!   messages waiting join that one turn (`digest.rs`). When nothing waits, the continuation runs
//!   alone. Either way the first turn after the reset is one turn.
//! - A chat past [`COMPACT_BEFORE_TOKENS`] of context is compacted first (`compact_first.rs`),
//!   so the first turn after the reset does not send a 300K context again.
//! - The session row says so (`SessionSummary::rate_limited_until`; `acpmux ls`: "rate-limited
//!   until HH:MMZ"), and each hold and its end are logged (`rate_limit_held`, `rate_limit_lifted`).
//! - The person's Retry (`_acpmux/retry`) and Stop end the hold at once.

use super::*;
use std::sync::Mutex as StdMutex;

/// The context past which a chat is compacted before its first turn after a reset.
pub(super) const COMPACT_BEFORE_TOKENS: u64 = 250_000;

/// The shortest hold when nothing says when the limit resets: a per-minute rate limit's window.
pub(super) const MIN_HOLD_MS: u64 = 60_000;

/// A chat's rate-limit hold (`Session::rate_hold`).
#[derive(Default)]
pub(crate) struct RateHold {
    state: StdMutex<HoldState>,
    /// The deadline moved or the hold ended: the timer looks again.
    changed: Notify,
    /// The deadline passed while a continuation waits for it ([`Hub::wait_rate_hold`]).
    due: Notify,
}

#[derive(Default)]
struct HoldState {
    /// Absolute ms; `None` when the chat is not held.
    until: Option<u64>,
    /// The cut turn the hold is for.
    turn: Option<String>,
    /// The hold's timer task runs.
    timer: bool,
    /// A continuation waits for the deadline and ends the hold itself.
    continuation: bool,
}

impl RateHold {
    fn lock(&self) -> std::sync::MutexGuard<'_, HoldState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The deadline while the chat is held.
    pub(crate) fn until(&self) -> Option<u64> {
        self.lock().until
    }
}

impl Hub {
    /// Holds `session` until `until` (absolute ms) for its cut turn `turn`: no turn starts
    /// before. A held chat's deadline moves to `until`. One timer per chat.
    pub(super) fn hold_for_rate_limit(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        until: u64,
        continuation: bool,
    ) {
        let hold = &session.rate_hold;
        let spawn = {
            let mut s = hold.lock();
            let changed = s.until != Some(until);
            s.until = Some(until);
            s.turn = Some(turn.to_owned());
            s.continuation = continuation;
            if changed {
                self.append(
                    session,
                    "mux",
                    "rate_limit_held",
                    json!({"turnId": turn, "until": until}),
                );
            }
            !std::mem::replace(&mut s.timer, true)
        };
        hold.changed.notify_waiters();
        if spawn {
            let (hub, session) = (self.clone(), session.clone());
            tokio::spawn(async move { hub.rate_hold_timer(&session).await });
        }
    }

    async fn rate_hold_timer(self: &Arc<Self>, session: &Arc<Session>) {
        let hold = &session.rate_hold;
        loop {
            let changed = hold.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let until = {
                let mut s = hold.lock();
                match s.until {
                    Some(until) => until,
                    None => {
                        s.timer = false;
                        return;
                    }
                }
            };
            let now = now_ms();
            if now < until {
                tokio::select! {
                    () = tokio::time::sleep(Duration::from_millis(until - now)) => {}
                    () = changed.as_mut() => {}
                }
                continue;
            }
            let mut s = hold.lock();
            if s.until != Some(until) {
                continue;
            }
            s.timer = false;
            if s.continuation {
                // The continuation ends the hold once it decided (`rate_hold_due`).
                drop(s);
                hold.due.notify_one();
            } else {
                drop(s);
                self.lift_rate_hold(session, "reset");
            }
            return;
        }
    }

    /// Whether no turn may start in `session` now: it is held, or its continuation decides.
    pub(super) fn rate_held(session: &Session) -> bool {
        session.rate_hold.lock().until.is_some()
    }

    /// Ends `session`'s hold, if it has one, and lets its queue go on.
    pub(super) fn lift_rate_hold(&self, session: &Session, why: &str) {
        self.lift_hold(session, None, why);
    }

    /// Ends `session`'s hold only while it is still the one for cut turn `turn`: a continuation
    /// whose own turn hit the limit again left a newer hold, which stays.
    pub(super) fn lift_rate_hold_of(&self, session: &Session, turn: &str, why: &str) {
        self.lift_hold(session, Some(turn), why);
    }

    fn lift_hold(&self, session: &Session, of: Option<&str>, why: &str) {
        let hold = &session.rate_hold;
        let turn = {
            let mut s = hold.lock();
            if s.until.is_none() || of.is_some_and(|t| s.turn.as_deref() != Some(t)) {
                return;
            }
            s.until = None;
            s.continuation = false;
            s.turn.take()
        };
        hold.changed.notify_waiters();
        self.append(session, "mux", "rate_limit_lifted", json!({"turnId": turn, "why": why}));
        session.queue_moved.notify_waiters();
    }

    /// Holds `session` the moment its turn `turn` failed on the rate limit, before its
    /// continuation's wait is known: until the error's reset, else the account window's, else
    /// the turn's `retry-after` (`not_before`), else [`MIN_HOLD_MS`] from now. Whatever comes in
    /// meanwhile queues.
    pub(super) fn hold_at_failure(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        error: &str,
        not_before: Option<u64>,
    ) {
        let now = now_ms();
        let limits = session.meta().usage_limits;
        let reset = super::auto_resume::reset_hint::reset_at(error, limits.as_ref(), now);
        let until = reset.max(not_before).unwrap_or(now + MIN_HOLD_MS);
        self.hold_for_rate_limit(session, turn, until, false);
    }

    /// A `rate_limit` continuation of `turn` waits here for the hold's deadline `until`, or for
    /// `wake` (Stop, close, a turn that took the chat: the hold then ends). True when the
    /// deadline came: the continuation then decides ([`Hub::rate_hold_due`]).
    pub(super) async fn wait_rate_hold(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        until: u64,
        wake: &Notify,
    ) -> bool {
        self.hold_for_rate_limit(session, turn, until, true);
        let came = loop {
            tokio::select! {
                () = session.rate_hold.due.notified() => {}
                () = wake.notified() => break false,
            }
            // A permit an earlier hold's timer left is no deadline of this one.
            if session.rate_hold.until().is_none_or(|until| now_ms() >= until) {
                break true;
            }
        };
        if !came {
            self.lift_rate_hold(session, "stopped");
        }
        came
    }

    /// At the reset: whether `session`'s continuation folds into the queue's next turn. When
    /// anything waits in the queue (a message, a notice, the person's prompt), the continuation
    /// is not sent: the held prompts of the cut turn go on, the next turn carries the
    /// continuation's words (`rate_note`), and the hold ends. Otherwise the hold ends and the
    /// continuation runs alone.
    pub(super) fn rate_hold_due(
        &self,
        session: &Arc<Session>,
        held: &[String],
        note: String,
    ) -> bool {
        let waiting: Vec<String> = session.queue().iter().map(|q| q.prompt_id.clone()).collect();
        if waiting.is_empty() {
            self.lift_rate_hold(session, "reset");
            return false;
        }
        *session.rate_note.lock().unwrap_or_else(|e| e.into_inner()) = Some(note);
        // What the cut turn held, and every agent message a failed turn held: they waited only
        // for the limit, and go in together as one turn.
        let mut release: Vec<String> = held.to_vec();
        release.extend(
            session
                .queue()
                .iter()
                .filter(|q| q.held && q.run.agent.is_some())
                .map(|q| q.prompt_id.clone()),
        );
        self.resume_held(session, &release);
        self.lift_rate_hold(session, "folded");
        true
    }

    /// The continuation's words a folded continuation left for the chat's next turn, taken.
    pub(super) fn take_rate_note(session: &Session) -> Option<String> {
        session.rate_note.lock().unwrap_or_else(|e| e.into_inner()).take()
    }

    /// Whether `session`'s context is past [`COMPACT_BEFORE_TOKENS`].
    pub(super) fn context_past_compact_line(&self, session: &Session) -> bool {
        let m = session.meta();
        self.usage_stats_of(session, &m)
            .and_then(|s| s.context_tokens)
            .is_some_and(|n| n > COMPACT_BEFORE_TOKENS)
    }
}

impl Hub {
    /// Whether a prompt with `provenance` waits for `session`'s hold: every one but acpmux's own
    /// continuation of the cut turn (`auto_resume` provenance), which runs once the hold is due.
    pub(super) fn rate_holds(session: &Session, provenance: Option<&Value>) -> bool {
        Self::rate_held(session)
            && provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) != Some("auto_resume")
    }
}

impl Hub {
    /// A continuation's wait for its attempt at `next_at`: a `rate_limit` one waits for the chat's
    /// hold ([`Hub::wait_rate_hold`]), any other for its delay. Either ends early when its mark
    /// goes (`Wake`): Stop, close, a turn that took the chat.
    pub(super) async fn wait_retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        reason: crate::protocol::session::RetryReason,
        next_at: u64,
        wake: &Notify,
    ) {
        if reason == crate::protocol::session::RetryReason::RateLimit {
            self.wait_rate_hold(session, turn, next_at, wake).await;
            return;
        }
        let delay = next_at.saturating_sub(now_ms());
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(delay)) => {}
            () = wake.notified() => {}
        }
    }
}

/// "rate-limited until 04:30Z": a hold's deadline `until` (Unix ms), in UTC (`acpmux ls`, the
/// session row, a refused retry).
pub(crate) fn until_line(until: u64) -> String {
    let at = i64::try_from(until).ok().and_then(chrono::DateTime::from_timestamp_millis);
    match at {
        Some(at) => format!("rate-limited until {}", at.format("%H:%MZ")),
        None => "rate-limited".into(),
    }
}
