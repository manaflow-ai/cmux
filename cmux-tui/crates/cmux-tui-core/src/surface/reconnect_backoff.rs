//! Terminal host reconnect backoff: failure counting, spacing between attempts,
//! and the reset after a healthy connection.

use super::*;

#[cfg(any(unix, windows))]
pub(super) const TERMINAL_HOST_RECONNECT_MAX_FAILURES: u8 = 16;
#[cfg(any(unix, windows))]
pub(super) const TERMINAL_HOST_RECONNECT_MAX_DELAY: Duration = Duration::from_secs(1);
/// A host connection that lasted this long was healthy: the next loss starts
/// its reconnect spacing from zero again.
#[cfg(any(unix, windows))]
pub(super) const TERMINAL_HOST_HEALTHY_CONNECTION: Duration = Duration::from_secs(10);

/// Past the budget, a reconnect leaves the terminal `failed` but keeps
/// retrying its host this often, doubling up to the cap: a host that answers
/// again brings the terminal back without a daemon restart (cx-6so.19).
#[cfg(any(unix, windows))]
const TERMINAL_HOST_FAILED_RETRY: Duration = Duration::from_secs(2);
#[cfg(any(unix, windows))]
const TERMINAL_HOST_FAILED_RETRY_MAX: Duration = Duration::from_secs(60);
/// A failed link's retry wait ends this soon after a close or shutdown.
#[cfg(any(unix, windows))]
const TERMINAL_HOST_FAILED_RETRY_SLICE: Duration = Duration::from_millis(250);

#[cfg(any(unix, windows))]
#[derive(Default)]
pub(super) struct TerminalHostReconnectBackoff {
    failures: u8,
    /// Retry on after the budget (a reconnect), not give up (flaps, resyncs).
    /// The next wait while `failed`.
    failed_retry: Option<Duration>,
}

#[cfg(any(unix, windows))]
impl TerminalHostReconnectBackoff {
    pub(super) fn next_delay(&mut self) -> Option<Duration> {
        if self.failures >= TERMINAL_HOST_RECONNECT_MAX_FAILURES {
            return None;
        }
        let multiplier = 1_u32 << self.failures.min(6);
        self.failures += 1;
        Some((Duration::from_millis(25) * multiplier).min(TERMINAL_HOST_RECONNECT_MAX_DELAY))
    }

    /// A reconnect's backoff: past the budget the terminal is `failed` and
    /// its host is still retried.
    pub(super) fn retrying_after_failure() -> Self {
        Self { failures: 0, failed_retry: Some(TERMINAL_HOST_FAILED_RETRY) }
    }

    /// [`Self::wait_or_fail`] without the retry past the budget: for a
    /// failure no later attempt can fix.
    pub(super) fn wait_or_give_up(&mut self, pty: &PtySurface) -> bool {
        let failed_retry = self.failed_retry.take();
        let retry = self.wait_or_fail(pty);
        self.failed_retry = failed_retry;
        retry
    }

    pub(super) fn wait_or_fail(&mut self, pty: &PtySurface) -> bool {
        let Some(delay) = self.next_delay() else {
            if let Some(delay) = self.failed_retry {
                self.failed_retry = Some((delay * 2).min(TERMINAL_HOST_FAILED_RETRY_MAX));
                let was = pty
                    .host_connection_state
                    .swap(TerminalHostConnectionState::Failed as u8, Ordering::AcqRel);
                if was != TerminalHostConnectionState::Failed as u8 {
                    if let PtyRuntime::Hosted(host) =
                        &*pty.runtime.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
                    {
                        host.disconnect();
                    }
                    pty.stream_progress.notify();
                    publish_host_link_state(pty);
                }
                return wait_unless_detached(pty, delay);
            }
            pty.host_connection_state
                .store(TerminalHostConnectionState::Failed as u8, Ordering::Release);
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                host.disconnect();
            }
            // Input waiting out the reconnect (surface/input.rs) fails now.
            pty.stream_progress.notify();
            return false;
        };
        #[cfg(test)]
        pty.run_geometry_test_hook(PtyGeometryTestStep::ReconnectBackoffStarted);
        std::thread::sleep(delay);
        true
    }
}

/// Sleep `delay` in slices; false once the terminal is closed or the daemon
/// shuts down (both set `owner_detaching`) or its mux is gone. A recover
/// request (`recover_requested`) ends the wait at once.
#[cfg(any(unix, windows))]
fn wait_unless_detached(pty: &PtySurface, delay: Duration) -> bool {
    let until = Instant::now() + delay;
    loop {
        if pty.owner_detaching.load(Ordering::Acquire) || pty.mux.upgrade().is_none() {
            return false;
        }
        if pty.recover_requested.load(Ordering::Acquire) {
            return true;
        }
        let Some(left) = until.checked_duration_since(Instant::now()).filter(|d| !d.is_zero())
        else {
            return true;
        };
        std::thread::sleep(left.min(TERMINAL_HOST_FAILED_RETRY_SLICE));
    }
}

/// Tell clients the terminal's host link changed state (`terminal_state`
/// `reconnecting`, `failed`, `running` again).
#[cfg(any(unix, windows))]
pub(super) fn publish_host_link_state(pty: &PtySurface) {
    if let Some(mux) = pty.mux.upgrade() {
        mux.emit_terminal_host_link_changed(pty.event_surface_id);
    }
}

#[cfg(any(unix, windows))]
pub(super) fn wait_for_reconnect_after_geometry_failure(
    retry: &mut TerminalHostReconnectBackoff,
    pty: &PtySurface,
    geometry: RankedGuard<'_, PtyGeometry>,
) -> bool {
    drop(geometry);
    retry.wait_or_fail(pty)
}
