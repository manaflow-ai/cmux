//! The `Mux` reads of `oracle-state` (`crate::oracle_state`): debug and
//! `--features oracle` builds only.

use super::Mux;
use crate::oracle_state::{SwitchArms, launch_switch_arms};

impl Mux {
    /// Live event subscriptions.
    pub(crate) fn live_event_subscriber_count(&self) -> usize {
        self.subscribers.live_subscriber_count()
    }

    /// The terminal-host record directory, next to which the owner logs
    /// holder losses (`crate::terminal_loss_log`); none for a test mux.
    pub(crate) fn oracle_terminal_host_root(&self) -> Option<std::path::PathBuf> {
        let options =
            self.surface_options.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        options.terminal_host_root.clone()
    }

    /// The daemon's refactor switch arms: the launch value, frozen at the
    /// first read, unless a test installed others before it.
    pub(crate) fn oracle_switches(&self) -> &SwitchArms {
        self.oracle_switches.get_or_init(launch_switch_arms)
    }

    /// Install `arms` before the first [`Self::oracle_switches`] read.
    #[cfg(test)]
    pub(crate) fn install_oracle_switches_for_test(&self, arms: SwitchArms) {
        assert!(self.oracle_switches.set(arms).is_ok(), "switch arms already frozen");
    }
}
