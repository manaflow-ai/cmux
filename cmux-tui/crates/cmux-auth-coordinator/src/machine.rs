//! Why [`Coordinator::step`](crate::Coordinator::step) refuses an event.

use std::fmt;

/// Why an event changes nothing. The coordinator is unchanged and no effect runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Refusal {
    /// A restore answer for a run that finished or was replaced.
    StaleRestore,
    /// A sign-in answer for a flow that finished, failed or was never begun.
    InactiveSignInFlow,
    /// A team-list answer for a read already answered or never issued.
    UnknownTeamRead,
    /// A post-sign-in hook whose restore run or sign-in flow is gone.
    HookOwnerGone,
    /// A recovery loop answer for a loop that is not the one sleeping.
    StaleRecovery,
    /// A sign-out capture answer already answered or never issued.
    UnknownSignOutCapture,
    /// A foreground revalidation with no session, restore or tokens to check.
    NothingToRestore,
    /// A team-scope signal while the scope is loaded or a read is in flight.
    TeamScopeNotNeeded,
    /// A team-scope signal during the session check's 429 backoff.
    RateLimited,
    /// The launch asked to clear auth: no restore runs.
    AuthClearRequested,
    /// The team asked for is already selected.
    AlreadySelected,
    /// An answer that asks for nothing (the dev token was found).
    NothingToDo,
}

impl Refusal {
    pub const ALL: [Refusal; 12] = [
        Refusal::StaleRestore,
        Refusal::InactiveSignInFlow,
        Refusal::UnknownTeamRead,
        Refusal::HookOwnerGone,
        Refusal::StaleRecovery,
        Refusal::UnknownSignOutCapture,
        Refusal::NothingToRestore,
        Refusal::TeamScopeNotNeeded,
        Refusal::RateLimited,
        Refusal::AuthClearRequested,
        Refusal::AlreadySelected,
        Refusal::NothingToDo,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::StaleRestore => "stale_restore",
            Refusal::InactiveSignInFlow => "inactive_sign_in_flow",
            Refusal::UnknownTeamRead => "unknown_team_read",
            Refusal::HookOwnerGone => "hook_owner_gone",
            Refusal::StaleRecovery => "stale_recovery",
            Refusal::UnknownSignOutCapture => "unknown_sign_out_capture",
            Refusal::NothingToRestore => "nothing_to_restore",
            Refusal::TeamScopeNotNeeded => "team_scope_not_needed",
            Refusal::RateLimited => "rate_limited",
            Refusal::AuthClearRequested => "auth_clear_requested",
            Refusal::AlreadySelected => "already_selected",
            Refusal::NothingToDo => "nothing_to_do",
        }
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for Refusal {}
