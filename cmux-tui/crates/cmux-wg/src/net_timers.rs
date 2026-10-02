//! The driver's WireGuard timer and probe operations (an `impl` block of
//! [`super::Driver`], kept apart from the I/O loop in `net.rs`).

use boringtun::noise::TunnResult;
use cmux_transport::{DatagramClass, classify};
use tokio::time::Instant;

use super::Driver;
use crate::probing;
use crate::timers::SESSION_FRESH;

impl Driver {
    pub(super) fn initiate_handshake(&mut self) {
        if !self.underlay.has_peer() {
            return;
        }
        if let TunnResult::WriteToNetwork(packet) =
            self.tunn.format_handshake_initiation(&mut self.scratch, false)
        {
            self.underlay.send(packet);
            self.schedule.on_activity(Instant::now());
        }
    }

    /// After a network change or a wake: drop expired sessions, then send
    /// a keepalive on a fresh session so the peer roams, or a new handshake
    /// initiation at once. A plain `encapsulate(&[])` would wait for the
    /// 5 s retry whenever a lost initiation is still "in progress".
    pub(super) fn reassert(&mut self) {
        self.schedule.on_tick(Instant::now());
        self.update_timers();
        let fresh = self.tunn.time_since_last_handshake().is_some_and(|age| age < SESSION_FRESH);
        let result = if fresh {
            self.tunn.encapsulate(&[], &mut self.scratch)
        } else {
            self.tunn.format_handshake_initiation(&mut self.scratch, true)
        };
        if let TunnResult::WriteToNetwork(packet) = result {
            self.underlay.send(packet);
        }
        self.schedule.on_activity(Instant::now());
    }

    /// Send due path probes while the session carries traffic; an idle
    /// session probes nothing.
    pub(super) fn run_probes(&mut self) {
        let now = Instant::now();
        self.probe_deadline = if self.schedule.is_active(now) {
            let (tunn, scratch) = (&mut self.tunn, &mut self.scratch);
            probing::send_due(tunn, &mut *self.underlay, scratch, self.probe_route, now)
        } else {
            None
        };
    }

    /// Run boringtun's timers on any event a tick or more after the last
    /// run, not only when the schedule had one due: after an idle period or
    /// a stopped process boringtun's view of time is stale, and an expired
    /// session must be dropped before anything is encrypted with it. This
    /// adds no wakeup; it only runs when something else woke the driver.
    pub(super) fn catch_up_timers(&mut self) {
        let now = Instant::now();
        if self.schedule.overdue(now) {
            self.schedule.on_tick(now);
            self.update_timers();
        }
    }

    pub(super) fn update_timers(&mut self) {
        if let TunnResult::WriteToNetwork(packet) = self.tunn.update_timers(&mut self.scratch) {
            // A handshake retry keeps the timers running until boringtun
            // gives up; a keepalive alone does not.
            let retry = classify(packet) == DatagramClass::WireGuardInitiation;
            self.underlay.send(packet);
            if retry {
                self.schedule.on_activity(Instant::now());
            }
        }
    }
}
