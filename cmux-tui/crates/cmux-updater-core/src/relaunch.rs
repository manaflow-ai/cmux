//! Whether an update may relaunch the app now: CmuxUpdaterCore's `UpdateRelaunchBlockers`.

use serde::Deserialize;

/// Seconds hardware input must be quiet before an automatic relaunch, unless the host sets its
/// own (`updates.idleInstallQuietSeconds`).
pub const QUIET_INPUT_SECONDS: f64 = 60.0;

/// What a relaunch would interrupt, as the host reports it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Blockers {
    /// Agents mid-turn; they finish on their own.
    pub busy_agent_count: i64,
    /// Other foreground commands, which may never exit.
    pub running_command_count: i64,
    /// Hardware input during the quiet window (automatic installs only).
    pub user_input_active: bool,
    /// The daemon mirror is not confirmed yet (automatic installs only).
    pub daemon_state_unavailable: bool,
}

/// How long the gate has waited and its limits, in seconds.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Waits {
    pub waited: f64,
    pub daemon_unavailable_for: f64,
    pub agent_timeout: f64,
    pub daemon_unavailable_timeout: f64,
    pub automatic_wait_cap: f64,
}

impl Blockers {
    pub fn is_empty(&self) -> bool {
        self.busy_agent_count == 0
            && self.running_command_count == 0
            && !self.user_input_active
            && !self.daemon_state_unavailable
    }

    /// The blockers that hold an install the user asked for.
    pub fn for_user_install(&self) -> Self {
        Self {
            busy_agent_count: self.busy_agent_count,
            running_command_count: self.running_command_count,
            ..Self::default()
        }
    }

    /// Whether the relaunch may go ahead. A user install ignores the input and daemon holds and
    /// waits for agents only up to `agent_timeout`; an automatic one stops waiting at
    /// `automatic_wait_cap`.
    pub fn permits_relaunch(&self, automatic: bool, waits: &Waits) -> bool {
        if !automatic {
            if self.running_command_count > 0 {
                return false;
            }
            if self.busy_agent_count > 0 {
                return waits.waited >= waits.agent_timeout;
            }
            return true;
        }
        if waits.waited >= waits.automatic_wait_cap {
            return true;
        }
        if self.daemon_state_unavailable
            && waits.daemon_unavailable_for < waits.daemon_unavailable_timeout
        {
            return false;
        }
        self.running_command_count == 0 && !self.user_input_active && self.busy_agent_count == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn waits(waited: f64, daemon_for: f64) -> Waits {
        Waits {
            waited,
            daemon_unavailable_for: daemon_for,
            agent_timeout: 300.0,
            daemon_unavailable_timeout: 30.0,
            automatic_wait_cap: 3600.0,
        }
    }

    #[test]
    fn user_install_waits_for_commands_and_agents_only() {
        let commands = Blockers { running_command_count: 1, ..Blockers::default() };
        assert!(!commands.permits_relaunch(false, &waits(10_000.0, 0.0)));
        let agents =
            Blockers { busy_agent_count: 2, user_input_active: true, ..Blockers::default() };
        assert!(!agents.permits_relaunch(false, &waits(299.0, 0.0)));
        assert!(agents.permits_relaunch(false, &waits(300.0, 0.0)));
        let held = Blockers {
            user_input_active: true,
            daemon_state_unavailable: true,
            ..Blockers::default()
        };
        assert!(held.permits_relaunch(false, &waits(0.0, 0.0)));
        assert!(held.for_user_install().is_empty());
    }

    #[test]
    fn automatic_install_waits_for_everything_until_the_cap() {
        let daemon = Blockers { daemon_state_unavailable: true, ..Blockers::default() };
        assert!(!daemon.permits_relaunch(true, &waits(10.0, 29.0)));
        assert!(daemon.permits_relaunch(true, &waits(10.0, 30.0)));
        let input = Blockers { user_input_active: true, ..Blockers::default() };
        assert!(!input.permits_relaunch(true, &waits(10.0, 0.0)));
        let agents = Blockers { busy_agent_count: 1, ..Blockers::default() };
        assert!(!agents.permits_relaunch(true, &waits(3599.0, 0.0)));
        assert!(agents.permits_relaunch(true, &waits(3600.0, 0.0)));
        assert!(Blockers::default().permits_relaunch(true, &waits(0.0, 0.0)));
    }
}
