//! An accepted install, from the click to a download: CmuxUpdaterCore's
//! `AttemptUpdateCoordinator` (re-resolve to the newest item before installing, #6366) and the
//! `InstallWatchdog` predicates (what counts as stalled when its deadline fires).
//!
//! The app keeps the timer and Sparkle; it passes the attempt's [`Attempt`] in and stores the one
//! that comes back.

use serde::{Deserialize, Serialize};

/// The phase an install policy observes (`UpdateLifecyclePhase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Idle,
    PermissionRequest,
    PreparingCheck,
    Checking,
    UpdateAvailable,
    NotFound,
    Error,
    StartingDownload,
    Downloading,
    Extracting,
    Installing,
}

/// Where an install attempt is.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Attempt {
    /// Not coordinating an install.
    #[default]
    Inactive,
    /// A fresh check was asked for but Sparkle has not been called yet.
    AwaitingFreshCheck,
    /// Sparkle was called for the fresh check; install what it resolves.
    AwaitingResult,
    /// The fresh prompt was answered with install; waiting for a download or a visible error.
    StartingDownload,
}

/// What the app does next.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    None,
    StartFreshCheck,
    ConfirmInstall,
    InstallFailed,
}

impl Attempt {
    pub fn is_monitoring(self) -> bool {
        self != Self::Inactive
    }

    /// The user asked to install: re-resolve with a fresh check unless an install is underway.
    pub fn request_install_latest(self, current: Phase) -> (Self, Action) {
        if self != Self::Inactive {
            return (self, Action::None);
        }
        match current {
            Phase::StartingDownload
            | Phase::Downloading
            | Phase::Extracting
            | Phase::Installing => (self, Action::None),
            _ => (Self::AwaitingFreshCheck, Action::StartFreshCheck),
        }
    }

    /// The app called Sparkle for the fresh check.
    pub fn did_start_fresh_check(self) -> Self {
        if self == Self::AwaitingFreshCheck { Self::AwaitingResult } else { self }
    }

    /// A phase change seen during the attempt.
    pub fn handle(self, state: Phase) -> (Self, Action) {
        use Phase as P;
        match self {
            Self::Inactive => (self, Action::None),
            Self::AwaitingFreshCheck => match state {
                P::PreparingCheck | P::PermissionRequest => (self, Action::None),
                P::Error => (Self::Inactive, Action::None),
                _ => (Self::Inactive, Action::InstallFailed),
            },
            Self::AwaitingResult => match state {
                P::UpdateAvailable => (Self::StartingDownload, Action::ConfirmInstall),
                // Up to date is the expected answer of the fresh check (#9262).
                P::NotFound | P::Error | P::Downloading | P::Extracting | P::Installing => {
                    (Self::Inactive, Action::None)
                }
                P::Idle => (Self::Inactive, Action::InstallFailed),
                P::PreparingCheck | P::Checking | P::PermissionRequest | P::StartingDownload => {
                    (self, Action::None)
                }
            },
            Self::StartingDownload => match state {
                P::Downloading | P::Extracting | P::Installing | P::Error => {
                    (Self::Inactive, Action::None)
                }
                P::StartingDownload => (self, Action::None),
                P::Idle
                | P::PreparingCheck
                | P::Checking
                | P::UpdateAvailable
                | P::NotFound
                | P::PermissionRequest => (Self::Inactive, Action::InstallFailed),
            },
        }
    }
}

/// Seconds an accepted install has to start making progress.
pub const WATCHDOG_TIMEOUT_SECONDS: f64 = 25.0;

/// Whether `state`, seen when the watchdog fires, means the install never got going. Idle counts:
/// every legitimate way to be idle at the deadline disarms first.
pub fn stalled(state: Phase) -> bool {
    matches!(
        state,
        Phase::PreparingCheck
            | Phase::Checking
            | Phase::UpdateAvailable
            | Phase::StartingDownload
            | Phase::Idle
    )
}

/// Whether `state` resolves the attempt (progressing or a visible outcome), so the watchdog disarms.
pub fn resolved(state: Phase) -> bool {
    matches!(
        state,
        Phase::Downloading | Phase::Extracting | Phase::Installing | Phase::NotFound | Phase::Error
    )
}

/// Whether a phase change ended the attempt without handing an install to Sparkle, so the
/// watchdog bound to it disarms.
pub fn ended_without_install(action: Action, monitoring: bool) -> bool {
    !monitoring && action != Action::ConfirmInstall
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Phase; 11] = [
        Phase::Idle,
        Phase::PermissionRequest,
        Phase::PreparingCheck,
        Phase::Checking,
        Phase::UpdateAvailable,
        Phase::NotFound,
        Phase::Error,
        Phase::StartingDownload,
        Phase::Downloading,
        Phase::Extracting,
        Phase::Installing,
    ];

    #[test]
    fn request_starts_a_fresh_check_unless_installing() {
        for phase in ALL {
            let (attempt, action) = Attempt::Inactive.request_install_latest(phase);
            let installing = matches!(
                phase,
                Phase::StartingDownload
                    | Phase::Downloading
                    | Phase::Extracting
                    | Phase::Installing
            );
            if installing {
                assert_eq!((attempt, action), (Attempt::Inactive, Action::None));
            } else {
                assert_eq!(
                    (attempt, action),
                    (Attempt::AwaitingFreshCheck, Action::StartFreshCheck)
                );
            }
        }
        assert_eq!(
            Attempt::AwaitingResult.request_install_latest(Phase::Idle),
            (Attempt::AwaitingResult, Action::None)
        );
    }

    #[test]
    fn fresh_check_then_update_confirms_install() {
        let (attempt, _) = Attempt::Inactive.request_install_latest(Phase::UpdateAvailable);
        let attempt = attempt.did_start_fresh_check();
        assert_eq!(attempt, Attempt::AwaitingResult);
        assert_eq!(attempt.handle(Phase::Checking), (attempt, Action::None));
        let (attempt, action) = attempt.handle(Phase::UpdateAvailable);
        assert_eq!((attempt, action), (Attempt::StartingDownload, Action::ConfirmInstall));
        assert_eq!(attempt.handle(Phase::Downloading), (Attempt::Inactive, Action::None));
        assert_eq!(
            Attempt::StartingDownload.handle(Phase::Idle),
            (Attempt::Inactive, Action::InstallFailed)
        );
    }

    #[test]
    fn up_to_date_is_quiet_and_idle_fails() {
        assert_eq!(
            Attempt::AwaitingResult.handle(Phase::NotFound),
            (Attempt::Inactive, Action::None)
        );
        assert_eq!(
            Attempt::AwaitingResult.handle(Phase::Idle),
            (Attempt::Inactive, Action::InstallFailed)
        );
    }

    #[test]
    fn a_change_before_sparkle_was_called_fails_the_attempt() {
        assert_eq!(
            Attempt::AwaitingFreshCheck.handle(Phase::PreparingCheck),
            (Attempt::AwaitingFreshCheck, Action::None)
        );
        assert_eq!(
            Attempt::AwaitingFreshCheck.handle(Phase::Error),
            (Attempt::Inactive, Action::None)
        );
        assert_eq!(
            Attempt::AwaitingFreshCheck.handle(Phase::Checking),
            (Attempt::Inactive, Action::InstallFailed)
        );
        assert_eq!(Attempt::Inactive.handle(Phase::Idle), (Attempt::Inactive, Action::None));
        assert_eq!(Attempt::Inactive.did_start_fresh_check(), Attempt::Inactive);
    }

    #[test]
    fn watchdog_stalled_and_resolved_split_the_phases() {
        for phase in ALL {
            if phase == Phase::PermissionRequest {
                assert!(!stalled(phase) && !resolved(phase));
            } else {
                assert_ne!(stalled(phase), resolved(phase), "{phase:?}");
            }
        }
        assert!(ended_without_install(Action::None, false));
        assert!(!ended_without_install(Action::ConfirmInstall, false));
        assert!(!ended_without_install(Action::None, true));
    }
}
