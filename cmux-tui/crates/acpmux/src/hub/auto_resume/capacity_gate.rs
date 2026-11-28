//! One host's capacity waiters go back one at a time while the outage lasts, then in a widening
//! stream once the model answers again (RFD cmuxterm-hq#24665 §3.4 and §3.5: "the fleet's resumes
//! are paced ... so they don't all hit the pool at the moment it recovers", "at most a few
//! sessions per minute per host, so recovery itself doesn't cause the next round of 529s").
//!
//! Leo, 2026-11-21: "We cannot ever afford to wait like this. We cannot ever afford to let these
//! things get away from us." Leo, 2026-11-24: "send a fella to do the deep work + design and
//! stuff to smooth over these siuations better pleaseeeeeee".
//!
//! Before this, each chat a 529 or the pool's 503 cut waited on its own timer (jittered, at most
//! 5 min) and then sent its whole context again, whatever the chats around it had just learned.
//! With 100 lanes cut on one host that is about 20 full-context resends a minute into a pool
//! that is still empty, each one a failed turn that spends the pool's quota and pushes the
//! recovery further out (RFD: "each resume re-sends the whole context into the same empty
//! pool"; lanes recover in a median of 28 min, p95 163 min).
//!
//! The gate, one per harness family on the hub:
//! - **Outage.** A capacity cut of a background chat's turn (`RetryReason::Capacity`: the 529,
//!   the pool's 503 or 502) starts one. While it lasts, a background chat whose capacity wait
//!   ended goes on only as the host's **probe**: one at a time. The others hold, their wait
//!   still theirs (Stop, close, a person's prompt still take them, as before).
//! - **A failed probe** (its turn cut on capacity again) backs the next probe off: the first
//!   configured wait, doubling, at most the last (capped at [`super::CAPACITY_MAX_WAIT_MS`]).
//!   So a host spends one full-context resend per back-off on a dead pool, not one per chat.
//!   A probe whose attempt never reached the model (Stop, close, refused) frees the slot at once.
//! - **Recovery.** The first sign the model answers a background chat on this host (any work
//!   it streams: a message, a thought, a tool call; or a turn that ends well) ends the outage.
//!   The holders go in a doubling stream: 1, then 2, 4, 8 ... per half of the first configured
//!   wait (5 s by default), so 100 chats are all back within about 35 s, and a cut among them
//!   starts the next outage, holding the rest again.
//! - **Who it never holds.** A person's chat, a coordinator, a leader, Chief, a priority lane
//!   (the subrouter class `interactive`, `subrouter_priority.rs`): they have the gateway's
//!   reserve, so their calls are no sign of the background pool and they never wait on it.
//!   Nor a person's own Retry (`_acpmux/retry`), nor a rate limit (its own hold,
//!   `rate_hold.rs`), nor a full disk.
//!
//! Each holder logs `capacity_gate_held` once ({reason, attempt, promptId, turnId, family}),
//! and `capacity_gate_released` with `heldMs` when it goes on; the probe logs
//! `capacity_gate_probe`. The gate itself is in memory: a restart restores each wait from its
//! record (`restore.rs`), and the first one due probes again.
use super::Hub;
use super::Session;
use crate::protocol::session::RetryReason;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::Notify;

/// Doublings of the recovery stream after which the gate is fully open again (2^10 = 1024
/// chats in that step, more than any host runs).
const OPEN_AFTER_STEPS: u32 = 10;

/// How the gate paces, from the configured continuation waits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::hub) struct Timing {
    /// The first back-off after a failed probe.
    pub probe_base: Duration,
    /// The longest back-off between probes.
    pub probe_max: Duration,
    /// How long each width of the recovery stream lasts.
    pub ramp_step: Duration,
}

impl Timing {
    /// From `delays` (`autoResumeDelaysMs`, or the defaults): the first wait is the probe's
    /// first back-off and twice the ramp's step; the last, at most the capacity cap, its
    /// longest. Scaled delays (tests) scale the gate with them.
    pub(in crate::hub) fn from_delays(delays: &[u64]) -> Self {
        let first = delays.first().copied().unwrap_or(super::DEFAULT_DELAYS_MS[0]).max(2);
        let last = delays.last().copied().unwrap_or(first).max(first);
        let last =
            last.min(super::CAPACITY_MAX_WAIT_MS).max(first.min(super::CAPACITY_MAX_WAIT_MS));
        Self {
            probe_base: Duration::from_millis(first.min(super::CAPACITY_MAX_WAIT_MS)),
            probe_max: Duration::from_millis(last),
            ramp_step: Duration::from_millis((first / 2).max(1)),
        }
    }

    /// The back-off after `failed` probes in a row (from 1).
    fn backoff(&self, failed: u32) -> Duration {
        let shift = failed.saturating_sub(1).min(20);
        self.probe_base.saturating_mul(1u32 << shift).min(self.probe_max)
    }
}

/// One family's gate.
#[derive(Debug, Default)]
pub(in crate::hub) struct State {
    /// Since when the background pool reads as out; None while it answers.
    outage_since: Option<Instant>,
    /// The chat whose attempt probes the pool now, and its permit's number.
    probe: Option<(String, u64)>,
    /// Probes cut on capacity in a row this outage.
    failed_probes: u32,
    /// No probe goes before this.
    next_probe_at: Option<Instant>,
    /// When the last outage ended: the recovery stream widens from here.
    ramp_from: Option<Instant>,
    /// Chats the recovery stream let go since `ramp_from`.
    released: u64,
    /// Permit numbers.
    issued: u64,
}

/// What a waiter does now.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::hub) enum Verdict {
    /// Go on; `Some(n)` as the probe with permit `n`.
    Go(Option<u64>),
    /// Hold until the gate changes, or until this time.
    Hold(Option<Instant>),
}

impl State {
    /// Whether an outage holds background capacity continuations now.
    pub(in crate::hub) fn in_outage(&self) -> bool {
        self.outage_since.is_some()
    }

    /// The decision for one background chat whose capacity wait ended at `now`.
    pub(in crate::hub) fn decide(&mut self, session: &str, now: Instant, t: &Timing) -> Verdict {
        if self.outage_since.is_some() {
            if self.probe.is_some() {
                return Verdict::Hold(None);
            }
            if let Some(at) = self.next_probe_at.filter(|at| now < *at) {
                return Verdict::Hold(Some(at));
            }
            self.issued += 1;
            self.probe = Some((session.to_owned(), self.issued));
            return Verdict::Go(Some(self.issued));
        }
        let Some(from) = self.ramp_from else {
            return Verdict::Go(None);
        };
        let step = t.ramp_step.max(Duration::from_millis(1));
        let steps = (now.saturating_duration_since(from).as_millis() / step.as_millis()) as u32;
        if steps >= OPEN_AFTER_STEPS {
            self.ramp_from = None;
            return Verdict::Go(None);
        }
        // Cumulative: the probe's own chat, then 1, 2, 4 ... more per step.
        let allowed = (1u64 << (steps + 1)) - 1;
        if self.released < allowed {
            self.released += 1;
            return Verdict::Go(None);
        }
        Verdict::Hold(Some(from + step * (steps + 1)))
    }

    /// A background chat's turn was cut on capacity at `now`.
    pub(in crate::hub) fn cut(&mut self, session: &str, now: Instant, t: &Timing) {
        let probing = self.probe.as_ref().is_some_and(|(s, _)| s == session);
        if self.outage_since.is_none() {
            self.outage_since = Some(now);
            self.failed_probes = 0;
            self.ramp_from = None;
            self.released = 0;
            // Cut while the stream widened: the next probe waits one back-off.
            self.next_probe_at = None;
        }
        if probing {
            self.probe = None;
            self.failed_probes += 1;
            self.next_probe_at = Some(now + t.backoff(self.failed_probes));
        }
    }

    /// The model answered a background chat at `now`. True when that ended an outage.
    pub(in crate::hub) fn answered(&mut self, now: Instant) -> bool {
        if self.outage_since.take().is_none() {
            return false;
        }
        self.probe = None;
        self.failed_probes = 0;
        self.next_probe_at = None;
        self.ramp_from = Some(now);
        self.released = 0;
        true
    }

    /// Probe permit `n` ended. True when it still held the slot (its attempt told the gate
    /// nothing: it never reached the model, or ended without a word).
    pub(in crate::hub) fn probe_done(&mut self, n: u64) -> bool {
        if self.probe.as_ref().is_some_and(|(_, held)| *held == n) {
            self.probe = None;
            return true;
        }
        false
    }
}

/// The hub's gates, one per harness family.
#[derive(Default)]
pub(crate) struct CapacityGate {
    families: StdMutex<HashMap<String, State>>,
    changed: Notify,
    /// Any family in an outage: the hot path (every streamed update) reads only this.
    any_outage: AtomicBool,
    /// The pacing the last admitted waiter read from the config, for a cut, which runs on the
    /// turn's path and must land before the probe's permit drops.
    timing: StdMutex<Option<Timing>>,
}

impl CapacityGate {
    fn with<R>(&self, family: &str, f: impl FnOnce(&mut State) -> R) -> R {
        let mut families = self.families.lock().unwrap_or_else(|e| e.into_inner());
        let r = f(families.entry(family.to_owned()).or_default());
        let any = families.values().any(State::in_outage);
        self.any_outage.store(any, Ordering::Release);
        r
    }

    fn any_outage(&self) -> bool {
        self.any_outage.load(Ordering::Acquire)
    }

    fn timing(&self) -> Timing {
        let cached = *self.timing.lock().unwrap_or_else(|e| e.into_inner());
        cached.unwrap_or_else(|| Timing::from_delays(&super::DEFAULT_DELAYS_MS))
    }
}

/// A capacity continuation the gate let go. Dropped when its attempt ends: a probe's slot goes
/// back unless the attempt's own outcome already decided it.
pub(in crate::hub) struct Permit {
    hub: std::sync::Weak<Hub>,
    family: String,
    probe: Option<u64>,
}

impl Drop for Permit {
    fn drop(&mut self) {
        let (Some(n), Some(hub)) = (self.probe, self.hub.upgrade()) else {
            return;
        };
        if hub.capacity_gate.with(&self.family, |s| s.probe_done(n)) {
            hub.capacity_gate.changed.notify_waiters();
        }
    }
}

fn family_of(session: &Session) -> String {
    session.meta().family.unwrap_or_default()
}

impl Hub {
    /// Whether `session`'s capacity waits go through the gate: a background chat's only, by the
    /// class its agent's requests carry to the gateway (`lifecycle.rs` `cold_start`), not by who
    /// sent the last prompt: a lane a coordinator made stays background when a person prompts it.
    fn gated(&self, session: &Session) -> bool {
        let meta = session.meta();
        let for_person = super::super::host_level::made_for_a_person(
            meta.created_by.as_ref(),
            session.person.load(Ordering::SeqCst),
        );
        self.subrouter_priority(session, &meta, for_person) == crate::subrouter_priority::BACKGROUND
    }

    async fn gate_timing(&self) -> Timing {
        let configured = self.config.read().await.auto_resume_delays_ms.clone();
        Timing::from_delays(&super::effective_delays(configured))
    }

    /// A turn of `session` ended cut for `reason` (`schedule_auto_resume`).
    /// Synchronous: the probe's permit drops once its turn returns, and its cut must count
    /// as a failed probe before that.
    pub(in crate::hub) fn capacity_gate_cut(&self, session: &Session, reason: Option<RetryReason>) {
        if reason != Some(RetryReason::Capacity) || !self.gated(session) {
            return;
        }
        let t = self.capacity_gate.timing();
        self.capacity_gate.with(&family_of(session), |s| s.cut(&session.id, Instant::now(), &t));
        self.capacity_gate.changed.notify_waiters();
    }

    /// The model answered `session` (a streamed update of work, or a turn that ended well).
    /// Costs one atomic read unless an outage is on.
    pub(in crate::hub) fn capacity_gate_answered(&self, session: &Session) {
        if !self.capacity_gate.any_outage() || !self.gated(session) {
            return;
        }
        let family = family_of(session);
        if self.capacity_gate.with(&family, |s| s.answered(Instant::now())) {
            tracing::info!(session = %session.id, family, "capacity gate: the model answers again");
            self.capacity_gate.changed.notify_waiters();
        }
    }

    /// A capacity continuation's wait of `session` ended: wait for the gate. None when `wake`
    /// came first (Stop, close, a turn that took the chat: the caller's mark check skips it).
    pub(in crate::hub) async fn capacity_gate_admit(
        self: &std::sync::Arc<Self>,
        session: &Session,
        turn: &str,
        reason: RetryReason,
        wake: &Notify,
    ) -> Option<Permit> {
        let family = family_of(session);
        let permit = |probe| {
            Some(Permit { hub: std::sync::Arc::downgrade(self), family: family.clone(), probe })
        };
        if reason != RetryReason::Capacity || !self.gated(session) {
            return permit(None);
        }
        let t = self.gate_timing().await;
        *self.capacity_gate.timing.lock().unwrap_or_else(|e| e.into_inner()) = Some(t);
        let mut held_at: Option<Instant> = None;
        loop {
            // Registered before the decision, so a change between the two is not lost.
            let changed = self.capacity_gate.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let verdict =
                self.capacity_gate.with(&family, |s| s.decide(&session.id, Instant::now(), &t));
            let until = match verdict {
                Verdict::Go(probe) => {
                    let msg = |extra: serde_json::Value| {
                        let mut m = json!({"turnId": turn, "family": family});
                        if let (Some(m), Some(extra)) = (m.as_object_mut(), extra.as_object()) {
                            m.extend(extra.clone());
                        }
                        m
                    };
                    if let Some(at) = held_at {
                        let held = at.elapsed().as_millis() as u64;
                        self.append(
                            session,
                            "mux",
                            "capacity_gate_released",
                            msg(json!({"heldMs": held})),
                        );
                    }
                    if probe.is_some() {
                        self.append(session, "mux", "capacity_gate_probe", msg(json!({})));
                    }
                    return permit(probe);
                }
                Verdict::Hold(until) => until,
            };
            if held_at.is_none() {
                held_at = Some(Instant::now());
                self.append(
                    session,
                    "mux",
                    "capacity_gate_held",
                    json!({"turnId": turn, "family": family, "reason": reason.as_str()}),
                );
            }
            let sleep = async {
                match until {
                    Some(at) => tokio::time::sleep_until(at.into()).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                () = wake.notified() => return None,
                () = changed => {}
                () = sleep => {}
            }
        }
    }
}

#[cfg(test)]
#[path = "capacity_gate_tests.rs"]
mod tests;
