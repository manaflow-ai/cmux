//! Phase labels, how each phase is raced against its deadline, and the
//! damper that holds a timed-out phase back from automatic retries.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// The sign-in or session phase a deadline applies to (Swift `AuthPhase`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthPhase {
    SendCode,
    VerifyCode,
    PasswordSignIn,
    Oauth,
    AccessToken,
    ForceRefreshAccessToken,
    FetchUser,
    ValidateSession,
    ListTeams,
    TeamSelection,
    TeamManagement,
    PostSignIn,
    AccountDeletion,
    PushRegistrationSession,
    PushUnregistrationSession,
}

impl AuthPhase {
    /// The stable label timeout diagnostics use.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SendCode => "send_code",
            Self::VerifyCode => "verify_code",
            Self::PasswordSignIn => "password_sign_in",
            Self::Oauth => "oauth",
            Self::AccessToken => "access_token",
            Self::ForceRefreshAccessToken => "force_refresh_access_token",
            Self::FetchUser => "fetch_user",
            Self::ValidateSession => "validate_session",
            Self::ListTeams => "list_teams",
            Self::TeamSelection => "team_selection",
            Self::TeamManagement => "team_management",
            Self::PostSignIn => "post_sign_in",
            Self::AccountDeletion => "account_deletion",
            Self::PushRegistrationSession => "push_registration_session",
            Self::PushUnregistrationSession => "push_unregistration_session",
        }
    }

    /// How `runPhase` races this phase against its deadline.
    pub fn runner(self) -> PhaseRunner {
        match self {
            Self::ValidateSession => PhaseRunner::Validation,
            Self::FetchUser
            | Self::ListTeams
            | Self::AccessToken
            | Self::ForceRefreshAccessToken
            | Self::AccountDeletion => PhaseRunner::TokenTouching,
            Self::VerifyCode | Self::PasswordSignIn | Self::Oauth => PhaseRunner::Exchange,
            Self::PostSignIn => PhaseRunner::PostSignIn,
            other => {
                PhaseRunner::Prompt { blocks_retries_while_timed_out: other == Self::SendCode }
            }
        }
    }
}

/// The deadline runner a phase uses (Swift `AuthCoordinator.runPhase`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhaseRunner {
    /// A coordinator-owned validation task that sign-out cancels.
    Validation,
    /// A coordinator-owned task that may refresh or write tokens: a run its
    /// deadline or caller left running refuses new runs of the phase until it
    /// ends (or the reset passes after it ended).
    TokenTouching,
    /// A sign-in credential exchange: one live run per phase, damped once
    /// timed out; sign-out and a newer sign-in cancel it.
    Exchange,
    /// The post-sign-in hook: never refused; sign-out cancels and joins it.
    PostSignIn,
    /// A plain race whose losing side is not joined.
    Prompt { blocks_retries_while_timed_out: bool },
}

/// Which of the timeout table's deadlines a call uses (Swift `AuthTimeouts`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PhaseBudget {
    /// 300 s by default: flows with a system sign-in sheet.
    Interactive,
    /// 60 s by default: backend calls.
    Network,
    /// 8 s by default: launch restore.
    SessionRestore,
}

/// The phases sign-out clears from the damper.
pub const SIGN_OUT_CLEARED_PHASES: &[AuthPhase] = &[
    AuthPhase::SendCode,
    AuthPhase::VerifyCode,
    AuthPhase::PasswordSignIn,
    AuthPhase::Oauth,
    AuthPhase::ValidateSession,
];

/// How long a timed-out phase refuses new work unless superseded.
pub const TIMED_OUT_RESET: Duration = Duration::from_secs(30);

/// Holds each phase's live operations and its timed-out operation, so one call
/// hung on a dead connection does not get hammered by automatic retries
/// (Swift `AuthPhaseTimeoutRegistry`). Time is passed in as monotonic
/// nanoseconds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PhaseDamper {
    reset_nanos: u64,
    active: BTreeMap<AuthPhase, BTreeSet<u64>>,
    timed_out: BTreeMap<AuthPhase, TimedOut>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TimedOut {
    id: u64,
    expires_at: u64,
}

impl Default for PhaseDamper {
    fn default() -> Self {
        Self::new(TIMED_OUT_RESET)
    }
}

impl PhaseDamper {
    pub fn new(reset: Duration) -> Self {
        Self {
            reset_nanos: u64::try_from(reset.as_nanos()).unwrap_or(u64::MAX),
            active: BTreeMap::new(),
            timed_out: BTreeMap::new(),
        }
    }

    /// Whether `phase` could begin now.
    pub fn can_begin(&mut self, phase: AuthPhase, now: u64) -> bool {
        self.expire(phase, now);
        !self.timed_out.contains_key(&phase)
            && self.active.get(&phase).is_none_or(BTreeSet::is_empty)
    }

    /// Registers operation `id`; false while another operation of the phase
    /// is live or a timed-out one is parked.
    pub fn begin(&mut self, phase: AuthPhase, id: u64, now: u64) -> bool {
        if !self.can_begin(phase, now) {
            return false;
        }
        self.active.entry(phase).or_default().insert(id);
        true
    }

    /// Parks operation `id` as timed out, when it is still live.
    pub fn mark_timed_out(&mut self, phase: AuthPhase, id: u64, now: u64) {
        if !self.active.get(&phase).is_some_and(|ids| ids.contains(&id)) {
            return;
        }
        self.timed_out
            .insert(phase, TimedOut { id, expires_at: now.saturating_add(self.reset_nanos) });
    }

    /// Operation `id` finished: it no longer blocks the phase.
    pub fn end(&mut self, phase: AuthPhase, id: u64) {
        if let Some(ids) = self.active.get_mut(&phase) {
            ids.remove(&id);
            if ids.is_empty() {
                self.active.remove(&phase);
            }
        }
        if self.timed_out.get(&phase).is_some_and(|parked| parked.id == id) {
            self.timed_out.remove(&phase);
        }
    }

    /// Forgets everything about `phases`.
    pub fn clear(&mut self, phases: &[AuthPhase]) {
        for phase in phases {
            self.active.remove(phase);
            self.timed_out.remove(phase);
        }
    }

    /// An explicit user action reclaims every timed-out phase at once. Only
    /// the timed-out operation's slot is released; a live operation keeps
    /// refusing concurrent begins.
    pub fn supersede_timed_out(&mut self) {
        let parked = std::mem::take(&mut self.timed_out);
        for (phase, state) in parked {
            if let Some(ids) = self.active.get_mut(&phase) {
                ids.remove(&state.id);
                if ids.is_empty() {
                    self.active.remove(&phase);
                }
            }
        }
    }

    fn expire(&mut self, phase: AuthPhase, now: u64) {
        let Some(parked) = self.timed_out.get(&phase) else {
            return;
        };
        if now < parked.expires_at {
            return;
        }
        self.active.remove(&phase);
        self.timed_out.remove(&phase);
    }
}

/// The backoffs launch restore waits before each retry of a token read that
/// failed with a storage error; after the last one the cached session is kept.
pub const FAILED_TOKEN_READ_RETRY_DELAYS: [Duration; 3] =
    [Duration::from_millis(100), Duration::from_millis(300), Duration::from_millis(900)];

/// Backoff before team-scope recovery attempt `attempt` (zero-based): 2 s,
/// doubling, capped at 60 s.
pub fn team_scope_recovery_delay(attempt: u32) -> Duration {
    Duration::from_secs((2u64 << attempt.min(5)).min(60))
}

/// The wait after a 429 on the session check: `Retry-After` clamped to
/// 1 s-15 min and stretched by up to 50%, else 30 s doubling to 15 min, each
/// scaled by `jitter` (clamped to 0.5-1.0).
pub fn team_scope_rate_limit_delay(
    retry_after: Option<Duration>,
    streak: u32,
    jitter: f64,
) -> Duration {
    let ceiling = Duration::from_secs(15 * 60);
    let spread = jitter.clamp(0.5, 1.0);
    if let Some(retry_after) = retry_after {
        let base = retry_after.clamp(Duration::from_secs(1), ceiling);
        return base.mul_f64(0.5 + spread).min(ceiling);
    }
    let exponent = streak.saturating_sub(1).min(5);
    let seconds = (30.0 * f64::from(1u32 << exponent)).min(900.0) * spread;
    // Swift truncates to whole milliseconds.
    Duration::from_millis((seconds * 1000.0) as u64)
}
