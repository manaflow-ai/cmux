//! Part of `Hub`; see `hub/mod.rs`. The dynamic CPU class's loop (`cpu_class/pressure.rs`): every
//! [`TICK`](crate::cpu_class::pressure::TICK), or at once when the person's turn starts, it reads
//! the contention sample, lets the controller decide whether `dynamic` sessions yield, and puts
//! each live harness's whole tree in or out of background class to match. A turn the person
//! waits on (their own prompt, in a chat a person shows and attends, before its first token or
//! tool result) never yields. Each change is one daemon log line (`cpu class:`), and `session
//! info` shows each session's `cpuClass` (its class now, the time it spent demoted) and the
//! host's decision (`cpuPressure`).
//!
//! macOS only does anything: elsewhere no sampler runs, so the controller never demotes, and the
//! loop is not started. While no live session is `dynamic` (the class is opt-in) the loop and the
//! sampler wait with no timer, so an idle daemon does not wake for them; a session entering the
//! class wakes the loop ([`wake`]).

use super::*;
use crate::cpu_class::CpuClass;
use crate::cpu_class::pressure::{Sample, Sampler, TICK, mono_ms, wants_background};
use std::time::Duration;

/// Wakes the loop before its next tick: a turn the person waits on just started.
static WAKE: tokio::sync::Notify = tokio::sync::Notify::const_new();

/// Advances a periodic deadline past `now` without replaying missed samples. A wake burst can
/// win the `select!` repeatedly, so the deadline is checked after every wake as well as by the
/// timer arm itself.
fn timer_due(next: &mut tokio::time::Instant, now: tokio::time::Instant) -> bool {
    if now < *next {
        return false;
    }
    let periods = now.duration_since(*next).as_nanos() / TICK.as_nanos() + 1;
    let nanos = TICK.as_nanos().saturating_mul(periods).min(u64::MAX as u128) as u64;
    *next = next.checked_add(Duration::from_nanos(nanos)).unwrap_or(now + TICK);
    true
}

/// A turn the person waits on started: its harness leaves background class now, not within a
/// tick.
pub(crate) fn wake() {
    WAKE.notify_one();
}

impl Hub {
    /// Starts the loop once (macOS, unless `ACPMUX_CPU_PRESSURE=off`). It ends when the daemon
    /// stops.
    pub(crate) fn start_cpu_pressure(self: &Arc<Self>) {
        if std::env::var("ACPMUX_CPU_PRESSURE").is_ok_and(|v| v == "off" || v == "0") {
            tracing::info!("cpu class: the dynamic controller is off (ACPMUX_CPU_PRESSURE)");
            return;
        }
        if !Sampler::start() {
            return;
        }
        let weak = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("cpu-pressure", async move {
            let mut next_tick = tokio::time::Instant::now() + TICK;
            loop {
                let wanted = match weak.upgrade() {
                    Some(hub) => hub.cpu_pressure_wants_samples(),
                    None => break,
                };
                Sampler::want(wanted);
                if wanted {
                    tokio::select! {
                        _ = tokio::time::sleep_until(next_tick) => {},
                        _ = WAKE.notified() => {},
                    };
                } else {
                    // Nothing to decide for: no timer until a session enters the class.
                    WAKE.notified().await;
                    next_tick = tokio::time::Instant::now() + TICK;
                }
                let Some(hub) = weak.upgrade() else { break };
                if !hub.cpu_pressure_wants_samples() {
                    // The last dynamic session ended: never leave a decision standing on it.
                    hub.cpu_pressure_tick(None).await;
                    continue;
                }
                let now = tokio::time::Instant::now();
                if timer_due(&mut next_tick, now) {
                    hub.cpu_pressure_tick(Sampler::read()).await;
                } else {
                    // A wake only reapplies the current controller decision. Sampling here
                    // would count the same host reading twice when prompts arrive in a burst.
                    hub.cpu_pressure_reapply().await;
                }
            }
        });
    }

    /// Whether the sampler should read the host now: some live harness runs in the `dynamic`
    /// class (or is still starting toward it).
    #[doc(hidden)]
    pub fn cpu_pressure_wants_samples(&self) -> bool {
        self.live_session_handles().iter().any(|session| {
            session
                .child
                .try_lock()
                .ok()
                .and_then(|slot| slot.clone())
                .is_some_and(|child| child.run_class() == CpuClass::Dynamic)
        })
    }

    /// One pass with `sample` (tests drive it with their own): the decision, then each live
    /// `dynamic` harness to the class it wants. Answers the decision.
    #[doc(hidden)]
    pub async fn cpu_pressure_tick(&self, sample: Option<Sample>) -> bool {
        let now = mono_ms();
        let (before, demoting) = {
            let mut c = self.cpu_pressure.lock().unwrap_or_else(|e| e.into_inner());
            let before = c.demoting();
            (before, c.observe(sample, now))
        };
        if before != demoting {
            tracing::info!(
                busy = sample.map(|s| s.busy),
                late_ms = sample.map(|s| s.late_ms),
                "cpu class: {}",
                if demoting {
                    "the host is contended; dynamic sessions yield to the GUI"
                } else {
                    "contention cleared; dynamic sessions run at normal class"
                }
            );
        }
        self.cpu_pressure_reapply_at(now, demoting).await;
        demoting
    }

    /// Re-applies the controller's current decision after a waited-on turn starts, without
    /// observing another host sample.
    async fn cpu_pressure_reapply(&self) {
        let demoting = self.cpu_pressure.lock().unwrap_or_else(|e| e.into_inner()).demoting();
        self.cpu_pressure_reapply_at(mono_ms(), demoting).await;
    }

    async fn cpu_pressure_reapply_at(&self, now: u64, demoting: bool) {
        for session in self.live_session_handles() {
            // Never wait on a start or a stop that holds the slot: the next tick reads it.
            let child = match session.child.try_lock() {
                Ok(slot) => slot.clone(),
                Err(_) => continue,
            };
            let Some(child) = child else { continue };
            let class = child.run_class();
            if class != CpuClass::Dynamic || !child.run_class_entered() {
                continue;
            }
            let waited = self.cpu_waited_on(&session);
            let want = wants_background(class, demoting, waited);
            if child.apply_background(want, now).await == Some(true) {
                tracing::info!(
                    session = %session.id,
                    waited_on = waited,
                    demoted_ms = child.cpu_class_view(now)["demotedMs"].as_u64(),
                    "cpu class: session {}",
                    if want { "demoted to background class" } else { "promoted to normal class" }
                );
            }
        }
    }

    /// The person waits on this chat's turn: their own prompt started it, a person shows and
    /// attends the chat, and no message, thought, or completed tool result has arrived yet.
    pub(super) fn cpu_waited_on(&self, session: &Session) -> bool {
        let person_turn = session
            .turn
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|turn| turn.persons && !turn.trigger);
        person_turn
            && session.awaiting_reply.load(std::sync::atomic::Ordering::SeqCst)
            && self.attended(session)
            && self.person_has_shown(session)
    }

    /// `session info`'s `cpuClass` for `session`: its harness's class and demotions, whether the
    /// person waits on it, and the host's decision. Null with no live harness.
    pub(crate) fn cpu_class_info(&self, session: &Session) -> Value {
        let child = match session.child.try_lock() {
            Ok(slot) => slot.clone(),
            // A start or stop holds it: no harness to read now.
            Err(_) => None,
        };
        let Some(child) = child else { return Value::Null };
        let mut view = child.cpu_class_view(mono_ms());
        if let Some(obj) = view.as_object_mut() {
            obj.insert("waitedOn".into(), json!(self.cpu_waited_on(session)));
            let host = self.cpu_pressure.lock().unwrap_or_else(|e| e.into_inner()).view();
            obj.insert("host".into(), host);
        }
        view
    }
}

#[cfg(test)]
mod tests {
    use super::{TICK, timer_due};
    use std::time::Duration;

    #[test]
    fn a_wake_burst_cannot_starve_or_replay_periodic_samples() {
        let start = tokio::time::Instant::now();
        let mut next = start + TICK;
        let mut samples = 0;
        for millis in (0..1000).step_by(10) {
            if timer_due(&mut next, start + Duration::from_millis(millis)) {
                samples += 1;
            }
        }
        assert_eq!(samples, 0, "the first deadline has not arrived");
        assert!(timer_due(&mut next, start + TICK));
        assert!(!timer_due(&mut next, start + TICK + Duration::from_millis(1)));
        assert!(timer_due(&mut next, start + Duration::from_secs(4)));
        assert!(!timer_due(&mut next, start + Duration::from_secs(4)));
    }
}
