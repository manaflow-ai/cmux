//! The account pool's limit holds every chat of the pool at once (Leo, 2026-11-20: "every single
//! coordinator is hitting a 429 ... we're not being efficient enough again").
//!
//! The SR2 gateway answers 503 "no non-exhausted claude accounts available, next account frees
//! up in 1h6m (retry after 3930s)" when every account of its pool is capped (all 192 were, from
//! about 22:00Z). That is no one chat's limit: on 2026-11-20 between 21:23Z and 23:00Z, 108 chats
//! on nine hosts failed 159 turns on it, each a notice or another agent's message that started a
//! turn into the same empty pool, resending 19M tokens. So:
//!
//! - A turn that fails on it ([`is_pool_exhausted`], `rate_hold.rs` `Hub::limit_failure`) holds
//!   the daemon's pool ([`PoolHold`]): every chat of that harness starts no turn
//!   (`queue.rs` via `Hub::rate_holds`), its continuation waits (`Hub::wait_retry`), and what
//!   comes in queues. One deadline for all: the gateway's `retry after` when it names one, and
//!   never sooner than the pool's own backoff (60 s, doubling with each failure, jittered).
//! - At the deadline one chat probes ([`Hub::pick_pool_probe`]): of the chats with work waiting,
//!   the one with the smallest context, so the probe is the cheapest request the daemon has. Its
//!   turn decides: when it fails on the pool again the hold starts over, longer; any other end
//!   lifts the hold for every chat, and their queues drain. A probe that never starts a turn
//!   within [`PROBE_WAIT_MS`] lifts it too, so nothing waits on a chat that went away.
//! - Each chat's row says until when (`rateLimitedUntil`), and the records say so:
//!   `rate_limit_pool_held` (in the chat that failed), `rate_limit_pool_probe` (in the probe),
//!   `rate_limit_pool_lifted` (in the probe, or the chat that ended it).

use super::*;
use std::sync::Mutex as StdMutex;
use std::time::Duration;

/// How long a probe may take to start and end its turn before the hold lifts without it.
pub(super) const PROBE_WAIT_MS: u64 = 10 * 60_000;

/// Whether `error` is the account pool's limit, not one account's: the SR2 gateway's 503
/// "no non-exhausted ... accounts", or an "out of accounts".
pub(crate) fn is_pool_exhausted(error: &str) -> bool {
    let m = error.to_lowercase();
    (m.contains("no non-exhausted") && m.contains("account")) || m.contains("out of accounts")
}

/// The daemon's pool hold (`Hub::pool_hold`).
#[derive(Default)]
pub(crate) struct PoolHold {
    state: StdMutex<PoolState>,
    /// The deadline moved, a probe was picked or the hold ended.
    changed: Notify,
}

#[derive(Default)]
struct PoolState {
    /// Absolute ms; `None` when the pool is not held.
    until: Option<u64>,
    /// The harness whose chats the hold holds.
    harness: Option<String>,
    /// Turns in a row that failed on the pool; a probe that ends otherwise clears them.
    strikes: u32,
    /// The chat that probes, and since when.
    probe: Option<(String, u64)>,
    /// The hold's timer task runs.
    timer: bool,
}

impl PoolHold {
    fn lock(&self) -> std::sync::MutexGuard<'_, PoolState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl Hub {
    /// The pool's deadline for `session`, when the pool holds it: of its harness, and not the
    /// probe.
    pub(super) fn pool_until(&self, session: &Session) -> Option<u64> {
        let (until, harness, probe) = {
            let s = self.pool_hold.lock();
            (s.until?, s.harness.clone(), s.probe.as_ref().map(|(id, _)| id.clone()))
        };
        if probe.as_deref() == Some(session.id.as_str()) {
            return None;
        }
        let ours = harness.is_none_or(|h| h == session.meta().harness);
        ours.then_some(until)
    }

    /// Whether the pool holds `session` now ([`Hub::pool_until`]).
    pub(super) fn pool_holds(&self, session: &Session) -> bool {
        self.pool_until(session).is_some()
    }

    /// A turn of `session` failed with `error` on the pool's limit: the pool holds every chat
    /// of its harness until the gateway's reset, and no sooner than its backoff. A later failure
    /// only moves the deadline later.
    pub(super) fn hold_pool(
        self: &Arc<Self>,
        session: &Arc<Session>,
        error: &str,
        not_before: Option<u64>,
    ) {
        let now = now_ms();
        session.rate_hold.count_failure(now);
        let reset = super::auto_resume::reset_hint::reset_at(error, None, now).max(not_before);
        let base = self.backoff_base_now();
        let harness = session.meta().harness;
        let (until, strikes, spawn) = {
            let mut s = self.pool_hold.lock();
            s.strikes = s.strikes.saturating_add(1);
            s.probe = None;
            s.harness = Some(harness.clone());
            let until = super::rate_hold::hold_until(now, s.strikes, base, reset, "pool");
            let until = s.until.map_or(until, |held| held.max(until));
            s.until = Some(until);
            (until, s.strikes, !std::mem::replace(&mut s.timer, true))
        };
        self.pool_hold.changed.notify_waiters();
        tracing::info!(session = %session.id, until, strikes, harness, "rate limit: the pool holds");
        self.append(
            session,
            "mux",
            "rate_limit_pool_held",
            json!({"until": until, "strikes": strikes, "harness": harness}),
        );
        if spawn {
            let hub = self.clone();
            // One per daemon; it ends with the hold, or with the hub.
            self.scope.spawn_until_cancelled("pool-hold-timer", async move {
                hub.pool_hold_timer().await;
            });
        }
    }

    async fn pool_hold_timer(self: &Arc<Self>) {
        loop {
            let changed = self.pool_hold.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let (until, probe_at) = {
                let mut s = self.pool_hold.lock();
                let Some(until) = s.until else {
                    s.timer = false;
                    return;
                };
                (until, s.probe.as_ref().map(|(_, at)| *at))
            };
            let now = now_ms();
            let wake_at = probe_at.map_or(until, |at| at.saturating_add(PROBE_WAIT_MS));
            if now < wake_at {
                tokio::select! {
                    () = tokio::time::sleep(Duration::from_millis(wake_at - now)) => {}
                    () = changed.as_mut() => {}
                }
                continue;
            }
            if probe_at.is_some() {
                self.lift_pool(None, "probe_timeout");
            } else {
                self.pick_pool_probe();
            }
        }
    }

    /// At the deadline: the chat with work waiting (a queued prompt, a continuation) and the
    /// smallest context probes; with none, nothing would be sent, and the hold ends.
    fn pick_pool_probe(self: &Arc<Self>) {
        let harness = self.pool_hold.lock().harness.clone();
        let waiting = self.sessions().into_iter().filter(|s| {
            harness.as_deref().is_none_or(|h| h == s.meta().harness)
                && s.status() != SessionStatus::Closed
                && (s.queue().iter().any(|q| !q.aside()) || self.continuation_pending(s))
        });
        let context = |s: &Arc<Session>| {
            self.usage_stats_of(s, &s.meta()).and_then(|u| u.context_tokens).unwrap_or(u64::MAX)
        };
        let Some(probe) = waiting.min_by_key(context) else {
            self.lift_pool(None, "reset");
            return;
        };
        let strikes = {
            let mut s = self.pool_hold.lock();
            if s.until.is_none() {
                return;
            }
            s.probe = Some((probe.id.clone(), now_ms()));
            s.strikes
        };
        self.pool_hold.changed.notify_waiters();
        let tokens = self.usage_stats_of(&probe, &probe.meta()).and_then(|u| u.context_tokens);
        self.append(
            &probe,
            "mux",
            "rate_limit_pool_probe",
            json!({"strikes": strikes, "contextTokens": tokens}),
        );
        probe.queue_moved.notify_waiters();
    }

    /// Ends the pool's hold: every chat it held goes on. `by`: the chat whose turn ended it.
    fn lift_pool(&self, by: Option<&Session>, why: &str) {
        let (probe, strikes) = {
            let mut s = self.pool_hold.lock();
            if s.until.is_none() {
                return;
            }
            s.until = None;
            let strikes = std::mem::take(&mut s.strikes);
            (s.probe.take().map(|(id, _)| id), strikes)
        };
        self.pool_hold.changed.notify_waiters();
        tracing::info!(why, strikes, "rate limit: the pool hold lifted");
        let record = by.map(|s| s.id.clone()).or(probe);
        let sessions = self.sessions();
        if let Some(at) = record.and_then(|id| sessions.iter().find(|s| s.id == id)) {
            let msg = json!({"why": why, "strikes": strikes});
            self.append(at, "mux", "rate_limit_pool_lifted", msg);
        }
        for s in &sessions {
            s.queue_moved.notify_waiters();
        }
    }

    /// Every turn's end (`turns.rs`): a probe's turn that did not fail on the pool lifts the
    /// hold; a turn that failed on it was held already (`Hub::limit_failure`).
    pub(super) fn pool_turn_ended(&self, session: &Session, error: Option<&str>) {
        if error.is_some_and(is_pool_exhausted) {
            return;
        }
        let probe = {
            let mut s = self.pool_hold.lock();
            if s.until.is_none() && error.is_none() {
                s.strikes = 0;
            }
            s.probe.as_ref().is_some_and(|(id, _)| *id == session.id)
        };
        if probe {
            self.lift_pool(Some(session), "probe_ok");
        }
    }

    /// A continuation of `session` waits here while the pool holds it, or until `wake`.
    pub(super) async fn wait_pool(&self, session: &Session, wake: &Notify) {
        loop {
            let changed = self.pool_hold.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if !self.pool_holds(session) {
                return;
            }
            tokio::select! {
                () = changed.as_mut() => {}
                () = wake.notified() => return,
            }
        }
    }
}

#[cfg(test)]
#[path = "pool_hold_tests.rs"]
mod tests;
