//! The carrier session's sleep gate ([`SleepGate`]): a paused Cloud VM is
//! woken by any byte that reaches it, so an idle carrier session reads the
//! machine's state, with the machine read that wakes nothing (`POST /v1/read`
//! `cloud.machine.get`, the read [`super::serve_quiet`] uses), before it sends
//! a heartbeat or redials. While the machine reads `paused` or `pausing` and
//! nothing is sent on the session, it sends nothing at all (cmux-platform#1849:
//! a dial held through a person's pause woke the VM with its 2 s heartbeat).
//! The first byte the person sends (a keystroke, a message) goes out as it
//! always did: that byte is the wake.
//!
//! - A session is idle once nothing was sent on it for [`LOOK`]
//!   (`CMUX_CARRIER_IDLE_LOOK_MS`, 1 to 3 600 000, overrides it); an idle
//!   session reads the state once per look and probes only after a read that
//!   says the machine is up.
//! - A read that fails counts as up: the session probes as it did without
//!   the gate.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use cmux_remote::connection::SleepGate;

use super::answer::CarrierSource;
use super::serve_quiet;

/// How long a session goes unsent before it reads the machine, and how often
/// an idle session reads it.
pub(super) const LOOK: Duration = Duration::from_secs(10);

/// [`LOOK`], or `CMUX_CARRIER_IDLE_LOOK_MS` when set.
pub(super) fn look_time() -> Duration {
    look_from(std::env::var("CMUX_CARRIER_IDLE_LOOK_MS").ok().as_deref())
}

fn look_from(raw: Option<&str>) -> Duration {
    raw.and_then(|text| text.trim().parse::<u64>().ok())
        .filter(|ms| (1..=3_600_000).contains(ms))
        .map_or(LOOK, Duration::from_millis)
}

/// The machine's state as the platform reads it, for one session.
pub(super) struct MachineSleep {
    pub source: Arc<dyn CarrierSource>,
    pub machine: String,
    pub look: Duration,
}

#[async_trait]
impl SleepGate for MachineSleep {
    fn look(&self) -> Duration {
        self.look
    }

    async fn asleep(&self) -> bool {
        match tokio::time::timeout(self.look, self.source.machine_status(&self.machine)).await {
            Ok(Ok(status)) => serve_quiet::asleep(&status),
            _ => false,
        }
    }
}

#[cfg(test)]
#[path = "sleep_gate_tests.rs"]
mod tests;
