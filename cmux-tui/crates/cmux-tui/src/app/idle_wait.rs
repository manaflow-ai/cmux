//! How long the idle app loop may block. With nothing timed pending it
//! blocks until an event arrives, so an idle frontend has no wakeups; with
//! timed work pending it wakes at that work's earliest deadline.
//!
//! State another thread sets without an event wakes the loop itself
//! (`AppEvent::Wake`: a termination signal, a mux shutdown, a sidebar
//! document that fell back to timed reads).

use std::time::{Duration, Instant};

use crate::app::{App, DURABLE_NOTICE_DISPLAY_DURATION};
use crate::config::SidebarView;

/// The shortest idle wait while timed work is pending: the loop's old fixed
/// cadence. A deadline that passed while its work still waits on something
/// else (a retry whose request is in flight) wakes the loop at this rate,
/// never in a spin, and no deadline is served later than before.
pub(super) const IDLE_RETRY_FLOOR: Duration = Duration::from_millis(250);

impl App {
    /// The loop's wait when no event, animation or paint is pending:
    /// `None` blocks until an event arrives.
    pub(super) fn idle_wait(&self, now: Instant) -> Option<Duration> {
        self.idle_deadline(now)
            .map(|deadline| deadline.saturating_duration_since(now).max(IDLE_RETRY_FLOOR))
    }

    /// The earliest deadline of the timed work the loop runs after a wait.
    fn idle_deadline(&self, now: Instant) -> Option<Instant> {
        // Input that waits for its surface to attach retries on backoffs the
        // session keeps (attach failures, overflow, a stale tree).
        let input_waits = !self.deferred_input.is_empty() || self.pending_pointer_motion.is_some();
        let notice = self
            .durable_notices
            .front()
            .and_then(|front| front.painted_at)
            .map(|painted_at| painted_at + DURABLE_NOTICE_DISPLAY_DURATION);
        let ack_can_submit = !self.pending_durable_notice_acks.is_empty()
            && self.durable_notice_ack_in_flight.is_none()
            && !self.machine_action_in_flight
            && self.pending_machine_replacement.is_none();
        let notice_ack = ack_can_submit.then(|| self.durable_notice_ack_retry_at.unwrap_or(now));
        let machine_reconnect = (!self.machine_action_in_flight)
            .then_some(self.machine_provider_reconnect_retry_at)
            .flatten();
        let files_refresh = (self.config.sidebar.plugin.is_none()
            && self.sidebar_view == SidebarView::Files
            && self.sidebar_visible)
            .then(|| self.sidebar_files.next_refresh_at());
        [
            input_waits.then_some(now),
            notice,
            notice_ack,
            machine_reconnect,
            self.sidebar_plugin_retry_at,
            self.background_refresh_retry_at,
            files_refresh,
            self.browser_input.next_resize_retry(),
            self.session.next_surface_resize_retry(),
            self.session.next_surface_overflow_retry(),
            self.session.sidebar_doc_fallback_at(),
        ]
        .into_iter()
        .flatten()
        .min()
    }
}
