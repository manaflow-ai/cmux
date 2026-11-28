//! A daemon's relay registration state ([`RegistrationState`]) and the wall clock its
//! liveness check reads (split out of `relay.rs`).

use super::*;

/// What a daemon's relay registration is doing now ([`RelayDaemonRegistration::state`]): the
/// truth a status line or a peer's `reason` reads instead of stderr. Attempts go on in every
/// state but [`RegistrationState::Registered`]; the state only says what the last one met.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistrationState {
    /// The first attempt runs, or the registration dropped and registers again.
    Registering,
    /// The relay answered the Register: dials reach this daemon.
    Registered,
    /// No live registration, and the last attempt could get no ticket: the credential source
    /// (the ticket mint) failed or did not answer within its bound. `credential-unavailable`:
    /// it will not heal until the source answers again. `error` is the source's error.
    CredentialUnavailable { error: String },
    /// No live registration, and the relay refused or did not answer the last attempt.
    RelayUnavailable { error: String },
}

impl RegistrationState {
    /// The terminal reason word for a registration that cannot heal by retrying alone
    /// (`credential-unavailable`), as `PeerStateChanged.reason` names it; None otherwise.
    pub fn reason(&self) -> Option<&'static str> {
        matches!(self, Self::CredentialUnavailable { .. }).then_some("credential-unavailable")
    }
}

impl RelayDaemonRegistration {
    /// The registration's state now, and each change after it.
    pub fn state(&self) -> watch::Receiver<RegistrationState> {
        self.state.clone()
    }
}

/// The wall clock a registration compares with the monotonic one (`relay_liveness.rs`). A
/// test sets it ahead on its own thread ([`test_wall::jump`]) to stand for a paused VM's resume.
pub(super) fn wall_now() -> std::time::SystemTime {
    #[cfg(test)]
    {
        std::time::SystemTime::now() + test_wall::ahead()
    }
    #[cfg(not(test))]
    {
        std::time::SystemTime::now()
    }
}

/// The wall clock's lead on this thread (a `current_thread` test runtime's registration runs
/// on the test's thread), so parallel tests never see each other's jumps.
#[cfg(test)]
#[path = "relay_registration_state_test_wall_tests.rs"]
pub(crate) mod test_wall;
