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
//!   the daemon's pool of that harness ([`PoolHold`], one per harness): every chat of it starts
//!   no turn from a notice, another agent's message or a trigger (`queue.rs` via
//!   `Hub::rate_holds`; the person's own prompt still goes, and is a probe of its own), its
//!   continuation waits (`Hub::wait_retry`), and what comes in queues. One deadline for all: the
//!   gateway's `retry after` when it names one, and never sooner than the pool's own backoff
//!   (60 s, doubling with each failed probe, jittered). A chat whose turn was already running
//!   when the pool emptied fails once more; that only moves the deadline later, never adds a
//!   strike.
//! - At the deadline one chat probes ([`Hub::pick_pool_probe`]): of the chats with work waiting,
//!   the one with the smallest context, so the probe is the cheapest request the daemon has. Its
//!   turn decides: when it fails on the pool again the hold starts over, longer; a turn of any
//!   chat of the pool that ends well lifts the hold for every chat, and their queues drain. A
//!   probe Stop cut decides nothing: another is picked. A probe that never starts a turn
//!   within [`PROBE_WAIT_MS`] lifts it too, so nothing waits on a chat that went away.
//! - Each chat's row says until when (`rateLimitedUntil`), and the records say so:
//!   `rate_limit_pool_held` (in the chat that failed), `rate_limit_pool_probe` (in the probe),
//!   `rate_limit_pool_lifted` (in the probe, or the chat that ended it).

use super::*;
use std::collections::HashMap;
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

/// The daemon's pool holds, one per harness (`Hub::pool_hold`).
#[derive(Default)]
pub(crate) struct PoolHold {
    state: StdMutex<HashMap<String, PoolState>>,
    /// A deadline moved, a probe was picked or a hold ended.
    changed: Notify,
}

#[derive(Default)]
struct PoolState {
    /// Absolute ms; `None` when the pool is not held.
    until: Option<u64>,
    /// Probes in a row that failed on the pool; a turn that ends well clears them.
    strikes: u32,
    /// The chat that probes, and since when.
    probe: Option<(String, u64)>,
    /// The hold's timer task runs.
    timer: bool,
}

impl PoolHold {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, PoolState>> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// How a turn of a chat of the pool ended (`Hub::pool_turn_ended`).
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum PoolTurn {
    /// It ended well: the pool has an account.
    Ok,
    /// Stop cut it, or it failed on something else: it says nothing of the pool.
    Undecided,
    /// It failed on the pool's limit (held already by `Hub::limit_failure`).
    Exhausted,
}

/// What a turn's `result` says of its pool: a 429 says the gateway found an account.
pub(super) fn pool_turn(result: &Result<Value, RpcError>) -> PoolTurn {
    match result {
        Ok(v) if v.get("stopReason").and_then(Value::as_str) == Some("cancelled") => {
            PoolTurn::Undecided
        }
        Ok(_) => PoolTurn::Ok,
        Err(e) if is_pool_exhausted(&e.message) => PoolTurn::Exhausted,
        Err(e)
            if super::turn_errors::resume_cause(&e.message, &e.message) == Some("rate_limit") =>
        {
            PoolTurn::Ok
        }
        Err(_) => PoolTurn::Undecided,
    }
}

impl Hub {
    /// The pool's deadline for `session`, when the pool of its harness holds it and it is not
    /// the probe.
    pub(super) fn pool_until(&self, session: &Session) -> Option<u64> {
        let harness = session.meta().harness;
        let pools = self.pool_hold.lock();
        let s = pools.get(&harness)?;
        let probe = s.probe.as_ref().is_some_and(|(id, _)| *id == session.id);
        s.until.filter(|_| !probe)
    }

    /// Whether the pool holds `session` now ([`Hub::pool_until`]).
    pub(super) fn pool_holds(&self, session: &Session) -> bool {
        self.pool_until(session).is_some()
    }

    /// Whether `session` is its pool's probe: nothing steers into its turn (`inbox.rs`).
    pub(super) fn pool_probing(&self, session: &Session) -> bool {
        let harness = session.meta().harness;
        let pools = self.pool_hold.lock();
        pools.get(&harness).and_then(|s| s.probe.as_ref()).is_some_and(|(id, _)| *id == session.id)
    }

    /// A turn of `session` failed with `error` on the pool's limit: the pool of its harness holds
    /// every chat of it until the gateway's reset, and no sooner than its backoff. A failure of
    /// the probe, or the first one, is a strike; any other (a turn already running when the pool
    /// emptied) only moves the deadline later.
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
            let mut pools = self.pool_hold.lock();
            let s = pools.entry(harness.clone()).or_default();
            let probe = s.probe.as_ref().is_some_and(|(id, _)| *id == session.id);
            if s.until.is_none() || probe {
                s.strikes = s.strikes.saturating_add(1);
                s.probe = None;
            }
            let key = format!("pool:{harness}");
            let until = super::rate_hold::hold_until(now, s.strikes.max(1), base, reset, &key);
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
            // One per held pool; it ends with the hold, or with the hub.
            self.scope.spawn_until_cancelled("pool-hold-timer", async move {
                hub.pool_hold_timer(&harness).await;
            });
        }
    }

    async fn pool_hold_timer(self: &Arc<Self>, harness: &str) {
        loop {
            let changed = self.pool_hold.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let (until, probe_at) = {
                let mut pools = self.pool_hold.lock();
                let Some(s) = pools.get_mut(harness) else { return };
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
                self.lift_pool(harness, None, "probe_timeout");
            } else {
                self.pick_pool_probe(harness);
            }
        }
    }

    /// At the deadline: of the chats of the pool with work waiting (a queued prompt, a
    /// continuation) that nothing else holds, the one with the smallest context probes; with
    /// none, nothing would be sent, and the hold ends.
    fn pick_pool_probe(self: &Arc<Self>, harness: &str) {
        let waiting = self.sessions().into_iter().filter(|s| {
            s.meta().harness == harness
                && s.status() != SessionStatus::Closed
                && !Self::rate_held(s)
                && (s.queue().iter().any(|q| !q.aside()) || self.continuation_pending(s))
        });
        let context = |s: &Arc<Session>| {
            self.usage_stats_of(s, &s.meta()).and_then(|u| u.context_tokens).unwrap_or(u64::MAX)
        };
        let Some(probe) = waiting.min_by_key(context) else {
            self.lift_pool(harness, None, "reset");
            return;
        };
        let now = now_ms();
        let strikes = {
            let mut pools = self.pool_hold.lock();
            let Some(s) = pools.get_mut(harness) else { return };
            // A failure since the look moved the deadline, or another look picked one.
            if s.until.is_none_or(|until| until > now) || s.probe.is_some() {
                return;
            }
            s.probe = Some((probe.id.clone(), now));
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

    /// Ends the pool's hold of `harness`: every chat it held goes on. `by`: the chat whose turn
    /// ended it.
    fn lift_pool(&self, harness: &str, by: Option<&Session>, why: &str) {
        let (probe, strikes) = {
            let mut pools = self.pool_hold.lock();
            let Some(s) = pools.get_mut(harness).filter(|s| s.until.is_some()) else { return };
            s.until = None;
            let strikes = std::mem::take(&mut s.strikes);
            (s.probe.take().map(|(id, _)| id), strikes)
        };
        self.pool_hold.changed.notify_waiters();
        tracing::info!(why, strikes, harness, "rate limit: the pool hold lifted");
        let record = by.map(|s| s.id.clone()).or(probe);
        let sessions = self.sessions();
        if let Some(at) = record.and_then(|id| sessions.iter().find(|s| s.id == id)) {
            let msg = json!({"why": why, "strikes": strikes, "harness": harness});
            self.append(at, "mux", "rate_limit_pool_lifted", msg);
        }
        for s in &sessions {
            s.queue_moved.notify_waiters();
        }
    }

    /// Every turn's end (`turns.rs`): a turn of a chat of a held pool that ended well lifts the
    /// hold, the probe's or any other (the person's own prompt goes through the hold); a probe
    /// that decided nothing (Stop) gives way to another; one that failed on the pool was held
    /// already (`Hub::limit_failure`).
    pub(super) fn pool_turn_ended(&self, session: &Session, turn: PoolTurn) {
        if turn == PoolTurn::Exhausted {
            return;
        }
        let harness = session.meta().harness;
        let held = {
            let mut pools = self.pool_hold.lock();
            let Some(s) = pools.get_mut(&harness) else { return };
            let probe = s.probe.as_ref().is_some_and(|(id, _)| *id == session.id);
            if s.until.is_none() {
                if turn == PoolTurn::Ok {
                    s.strikes = 0;
                }
                return;
            }
            if turn == PoolTurn::Undecided {
                if probe {
                    s.probe = None;
                }
                drop(pools);
                self.pool_hold.changed.notify_waiters();
                return;
            }
            true
        };
        if held {
            self.lift_pool(&harness, Some(session), "turn_ok");
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
