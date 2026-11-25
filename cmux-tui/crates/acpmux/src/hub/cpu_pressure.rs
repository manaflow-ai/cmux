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
//! loop is not started.

use super::*;
use crate::cpu_class::CpuClass;
use crate::cpu_class::pressure::{Sample, Sampler, TICK, mono_ms, wants_background};

/// Wakes the loop before its next tick: a turn the person waits on just started.
static WAKE: tokio::sync::Notify = tokio::sync::Notify::const_new();

/// A turn the person waits on started: its harness leaves background class now, not within a
/// tick.
pub(super) fn wake() {
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
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(TICK) => {}
                    _ = WAKE.notified() => {}
                }
                let Some(hub) = weak.upgrade() else { break };
                hub.cpu_pressure_tick(Sampler::read()).await;
            }
        });
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
        demoting
    }

    /// The person waits on this chat's turn: their own prompt started it, a person shows the chat
    /// and attends it, and no token or tool result has come yet.
    pub(super) fn cpu_waited_on(&self, session: &Session) -> bool {
        session.awaiting_reply.load(Ordering::SeqCst)
            && session.turn.lock().unwrap_or_else(|e| e.into_inner()).is_some()
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
