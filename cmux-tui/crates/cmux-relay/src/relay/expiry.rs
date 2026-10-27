//! When the relay's cleanup has work (p14-energy-077m): the earliest lease,
//! join or idle expiry, so the cleanup task sleeps until then instead of
//! ticking every second.

use std::time::Instant;

use tokio::sync::Notify;

use super::{ALLOCATION_RATE_WINDOW, Relay, RelayState};
use crate::config::RelayConfig;

/// Tells the cleanup task, when the call that holds it returns (after its
/// state changes, on every path), to read the next expiry again.
pub(super) struct ExpiryChanged<'a>(&'a Notify);

impl Drop for ExpiryChanged<'_> {
    fn drop(&mut self) {
        self.0.notify_one();
    }
}

impl Relay {
    pub(super) fn expiry_changed(&self) -> ExpiryChanged<'_> {
        ExpiryChanged(&self.inner.expiry_changed)
    }
}

/// The earliest instant [`Relay::cleanup_expired`] has work: a control
/// lease's deadline, a pending circuit's join timeout, a ready circuit's idle
/// timeout, or the end of a slot's allocation window. `None` when nothing can
/// expire.
pub(super) fn next_expiry(state: &RelayState, config: &RelayConfig) -> Option<Instant> {
    let controls = state.controls.values().map(|control| Some(control.deadline));
    let circuits = state.circuits.values().map(|circuit| {
        if circuit.ready {
            circuit.last_activity.checked_add(config.idle_timeout)
        } else {
            circuit.created_at.checked_add(config.join_timeout)
        }
    });
    let allocations = state.slot_usage.values().map(|usage| {
        usage.recent_allocations.front().and_then(|at| at.checked_add(ALLOCATION_RATE_WINDOW))
    });
    controls.chain(circuits).chain(allocations).flatten().min()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::super::SlotUsage;
    use super::*;

    #[test]
    fn next_expiry_is_none_with_nothing_that_can_expire() {
        assert_eq!(next_expiry(&RelayState::default(), &RelayConfig::default()), None);
    }

    #[test]
    fn next_expiry_is_the_earliest_allocation_window_end() {
        let config = RelayConfig::default();
        let now = Instant::now();
        let mut state = RelayState::default();
        let mut usage = SlotUsage::default();
        usage.recent_allocations.push_back(now);
        state.slot_usage.insert("slot-a".into(), usage);
        let mut later = SlotUsage::default();
        later.recent_allocations.push_back(now + Duration::from_millis(400));
        state.slot_usage.insert("slot-b".into(), later);
        assert_eq!(next_expiry(&state, &config), Some(now + ALLOCATION_RATE_WINDOW));
    }
}
