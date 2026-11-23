//! The coordinator's state as sum types: each region is one enum, and data
//! that exists only in one state lives on that variant (RFD 0026 rule 1).
//!
//! The regions are independent of each other (a restore can run while a
//! sign-in flow and a sign-out capture are open), so the coordinator is their
//! product, not one flat enum; inside each region no flag can contradict
//! another.

use std::time::Duration;

use crate::model::{AuthState, AuthTeam, AuthUser};

/// What the coordinator publishes about the session (Swift `CMUXAuthState`).
/// Signed in always has a user: `is_authenticated` with no `current_user`
/// cannot be built.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Session {
    /// Signed out and not restoring; `shown` is a cached user still on screen.
    SignedOut { shown: Option<AuthUser> },
    /// Not signed in yet while the launch restore runs, showing `shown`.
    Restoring { shown: Option<AuthUser> },
    /// Shown as signed in as `user` while the launch restore confirms it.
    RestoringSignedIn { user: AuthUser },
    /// Signed in as `user`.
    SignedIn { user: AuthUser },
}

impl Session {
    pub(crate) const KINDS: [&'static str; 4] =
        ["signed_out", "restoring", "restoring_signed_in", "signed_in"];

    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Session::SignedOut { .. } => "signed_out",
            Session::Restoring { .. } => "restoring",
            Session::RestoringSignedIn { .. } => "restoring_signed_in",
            Session::SignedIn { .. } => "signed_in",
        }
    }

    /// The state a published [`AuthState`] names. `AuthState::primed` never
    /// says signed in without a user; such a state reads as not signed in.
    pub(crate) fn from_state(state: AuthState) -> Session {
        let AuthState { is_authenticated, current_user, is_restoring_session } = state;
        match (current_user, is_authenticated, is_restoring_session) {
            (Some(user), true, true) => Session::RestoringSignedIn { user },
            (Some(user), true, false) => Session::SignedIn { user },
            (shown, false, true) | (shown @ None, true, true) => Session::Restoring { shown },
            (shown, false, false) | (shown @ None, true, false) => Session::SignedOut { shown },
        }
    }

    /// The state with `user` (or none) shown and the same signed-in and
    /// restoring answers where a user allows them.
    pub(crate) fn from_parts(user: Option<AuthUser>, signed_in: bool, restoring: bool) -> Session {
        Session::from_state(AuthState {
            is_authenticated: signed_in,
            current_user: user,
            is_restoring_session: restoring,
        })
    }

    pub(crate) fn user(&self) -> Option<&AuthUser> {
        match self {
            Session::SignedOut { shown } | Session::Restoring { shown } => shown.as_ref(),
            Session::RestoringSignedIn { user } | Session::SignedIn { user } => Some(user),
        }
    }

    pub(crate) fn is_authenticated(&self) -> bool {
        match self {
            Session::SignedOut { .. } | Session::Restoring { .. } => false,
            Session::RestoringSignedIn { .. } | Session::SignedIn { .. } => true,
        }
    }

    pub(crate) fn is_restoring(&self) -> bool {
        match self {
            Session::SignedOut { .. } | Session::SignedIn { .. } => false,
            Session::Restoring { .. } | Session::RestoringSignedIn { .. } => true,
        }
    }

    pub(crate) fn published(&self) -> AuthState {
        AuthState {
            is_authenticated: self.is_authenticated(),
            current_user: self.user().cloned(),
            is_restoring_session: self.is_restoring(),
        }
    }
}

/// The restore run (Swift `checkExistingSession`): at most one owns the
/// restore, and only its answers count.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Restore {
    Idle,
    /// The run with this id is revalidating the session.
    Running {
        id: u64,
    },
}

impl Restore {
    pub(crate) const KINDS: [&'static str; 2] = ["idle", "running"];

    pub(crate) fn kind(self) -> &'static str {
        match self {
            Restore::Idle => "idle",
            Restore::Running { .. } => "running",
        }
    }
}

/// The team list of the current session generation. A list only exists once
/// this session's read answered: a new generation starts unloaded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Teams {
    Unloaded,
    Loaded { teams: Vec<AuthTeam> },
}

impl Teams {
    pub(crate) const KINDS: [&'static str; 2] = ["unloaded", "loaded"];

    pub(crate) fn kind(&self) -> &'static str {
        match self {
            Teams::Unloaded => "unloaded",
            Teams::Loaded { .. } => "loaded",
        }
    }

    pub(crate) fn list(&self) -> &[AuthTeam] {
        match self {
            Teams::Unloaded => &[],
            Teams::Loaded { teams } => teams,
        }
    }
}

/// The sign-in service's 429 backoff for the session check.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Backoff {
    Clear,
    /// `streak` 429s in a row; the recovery loop waits at least `delay`.
    RateLimited {
        streak: u32,
        delay: Duration,
    },
}

/// The team-scope recovery loop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecoveryLoop {
    Idle,
    /// The loop with this id sleeps before its `attempt`th check.
    Sleeping {
        id: u64,
        attempt: u32,
    },
}

/// Whether the session cache says tokens are stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TokenCache {
    Empty,
    Stored,
}

/// The magic-link code's nonce, which the caller holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PendingCode {
    None,
    Sent,
}

/// The sign-in form's spinner.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Loading {
    Idle,
    Busy,
}

/// The DEBUG credentials a `42` sign-in remembered, which the caller holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DebugCredentials {
    None,
    Remembered,
}

/// The counters each issued ticket captures, so a late answer is told apart
/// from the one the coordinator waits for (RFD 0026 rule 3). Every one only
/// moves forward.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Generations {
    /// Advances on every session transition.
    pub session: u64,
    /// Advances at the start of every sign-out.
    pub sign_out_epoch: u64,
    /// The last sign-in attempt issued.
    pub sign_in_attempt: u64,
    /// The newest sign-in attempt that wrote the token store.
    pub store_write_high_water: u64,
    /// The last restore run issued.
    pub restore: u64,
    /// Advances on every published team-scope change.
    pub team_scope: u64,
    /// Advances on every team switch.
    pub team_mutation: u64,
    /// Advances on every team delete or rename.
    pub team_list: u64,
    /// The last team read issued.
    pub team_read: u64,
    /// The last recovery loop issued.
    pub recovery: u64,
}
