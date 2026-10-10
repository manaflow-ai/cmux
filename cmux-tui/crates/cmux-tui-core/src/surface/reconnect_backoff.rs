//! Terminal host reconnect backoff: failure counting, spacing between attempts,
//! and the reset after a healthy connection.

use super::*;

#[cfg(unix)]
pub(super) const TERMINAL_HOST_RECONNECT_MAX_FAILURES: u8 = 16;
#[cfg(unix)]
pub(super) const TERMINAL_HOST_RECONNECT_MAX_DELAY: Duration = Duration::from_secs(1);
/// A host connection that lasted this long was healthy: the next loss starts
/// its reconnect spacing from zero again.
#[cfg(unix)]
pub(super) const TERMINAL_HOST_HEALTHY_CONNECTION: Duration = Duration::from_secs(10);

#[cfg(unix)]
#[derive(Default)]
pub(super) struct TerminalHostReconnectBackoff {
    failures: u8,
}

#[cfg(unix)]
impl TerminalHostReconnectBackoff {
    pub(super) fn next_delay(&mut self) -> Option<Duration> {
        if self.failures >= TERMINAL_HOST_RECONNECT_MAX_FAILURES {
            return None;
        }
        let multiplier = 1_u32 << self.failures.min(6);
        self.failures += 1;
        Some((Duration::from_millis(25) * multiplier).min(TERMINAL_HOST_RECONNECT_MAX_DELAY))
    }

    pub(super) fn wait_or_fail(&mut self, pty: &PtySurface) -> bool {
        let Some(delay) = self.next_delay() else {
            pty.host_connection_state
                .store(TerminalHostConnectionState::Failed as u8, Ordering::Release);
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                host.disconnect();
            }
            return false;
        };
        #[cfg(test)]
        pty.run_geometry_test_hook(PtyGeometryTestStep::ReconnectBackoffStarted);
        std::thread::sleep(delay);
        true
    }
}

#[cfg(unix)]
pub(super) fn wait_for_reconnect_after_geometry_failure(
    retry: &mut TerminalHostReconnectBackoff,
    pty: &PtySurface,
    geometry: std::sync::MutexGuard<'_, PtyGeometry>,
) -> bool {
    drop(geometry);
    retry.wait_or_fail(pty)
}
