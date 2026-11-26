//! What the reducer takes ([`Event`]) and returns ([`Effect`]), and the
//! tickets that pair an I/O effect with its answer.

use std::time::Duration;

use crate::model::{AuthTeam, AuthUser, SessionIdentity, TeamScope};
use crate::phase::{AuthPhase, PhaseBudget};

/// A failure, already classified by the caller (the display-safe reading of
/// a client or SDK error).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthFailure {
    /// A cancellation: a newer session transition won.
    Cancelled,
    TimedOut,
    Offline,
    /// The session was definitively rejected.
    Unauthorized,
    /// A code was verified with no code sent.
    InvalidCode,
    /// The sign-in service answered 429.
    RateLimited {
        retry_after: Option<Duration>,
    },
    /// A transient failure the caller may retry.
    NetworkError,
    Other,
}

/// What the session cache last read when the coordinator was built.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Persisted {
    pub cached_user: Option<AuthUser>,
    pub has_tokens: bool,
    pub selected_team_id: Option<String>,
}

/// The staleness context a restore captures at entry (Swift `checkExistingSessionBody`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RestoreTicket {
    pub generation: u64,
    pub store_write_high_water: u64,
    pub retry_on_storage_available: bool,
    pub failed_read_retries: usize,
}

/// The staleness context a sign-in flow captures before its first await
/// (Swift `SignInFlowContext`), plus how it was asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SignInFlow {
    pub generation: u64,
    pub attempt: u64,
    pub sign_out_epoch: u64,
    pub kind: SignInKind,
    pub sets_loading: bool,
}

/// Which sign-in a flow runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignInKind {
    /// A magic-link code against the pending nonce.
    VerifyCode,
    Password,
    /// Apple, Google or GitHub through the system sheet.
    Oauth,
    /// Tokens seeded outside the client (the hosted browser flow).
    External,
}

impl SignInKind {
    /// The phase and deadline of this kind's credential exchange.
    pub fn exchange(self) -> Option<(AuthPhase, PhaseBudget)> {
        match self {
            Self::VerifyCode => Some((AuthPhase::VerifyCode, PhaseBudget::Network)),
            Self::Password => Some((AuthPhase::PasswordSignIn, PhaseBudget::Network)),
            Self::Oauth => Some((AuthPhase::Oauth, PhaseBudget::Interactive)),
            Self::External => None,
        }
    }
}

/// What runs once a team-list read finishes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AfterTeams {
    /// Nothing: a plain refresh.
    Nothing,
    /// The restore with this ticket finishes.
    Restore,
    /// The sign-in flow completes.
    SignIn(SignInFlow),
}

/// The context of one team-list read (Swift `refreshTeams(generation:)`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TeamRefreshTicket {
    pub generation: u64,
    pub mutation_generation: u64,
    pub list_generation: u64,
    /// Whether the post-sign-in hook runs after the read.
    pub runs_post_sign_in_hook: bool,
    pub after: AfterTeams,
}

/// A team-list read's answer: the teams and the server's selected team.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TeamList {
    pub teams: Vec<AuthTeam>,
    pub server_selected_team_id: Option<String>,
}

/// Where the restore's automatic sign-in takes its credentials from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AutoLoginSource {
    /// The launch environment's credentials.
    Environment,
    /// The DEBUG credentials remembered from a `42` sign-in.
    DebugCredentials,
}

/// Which token read found nothing usable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenReadKind {
    AccessToken,
    ForceRefreshAccessToken,
}

/// How the restore was asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RestoreTrigger {
    /// `start()`: launch bootstrap.
    Launch,
    /// `revalidateSession()`: the app came to the foreground.
    Foreground,
    /// `recoverTeamScopeIfNeeded()`: network back, wake or activation.
    TeamScopeSignal,
}

/// An input to the reducer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// A restore entry point.
    Restore(RestoreTrigger),
    /// The stored-token probe answered: `Ok(has_stored_tokens)` or its failure.
    TokensProbed {
        ticket: RestoreTicket,
        probe: Result<bool, AuthFailure>,
        storage_was_available: bool,
        /// A token read since the probe's baseline failed with a storage error.
        read_failed: bool,
    },
    TokenStorageAvailability {
        ticket: RestoreTicket,
        available: bool,
    },
    /// The backoff before a failed-read retry ended (or was cancelled).
    ProbeRetryDue {
        ticket: RestoreTicket,
        cancelled: bool,
    },
    /// The cached session's user fetch answered.
    CachedSessionValidated {
        ticket: RestoreTicket,
        result: Result<Option<AuthUser>, AuthFailure>,
    },
    /// Whether a refresh token survives after a failed validation.
    SurvivingRefreshTokenRead {
        ticket: RestoreTicket,
        after_error: Option<AuthFailure>,
        result: Result<bool, AuthFailure>,
        read_failed: bool,
    },
    /// The stale session's token store clear finished.
    StaleSessionCleared {
        ticket: RestoreTicket,
        reason: String,
    },
    AutoLoginFinished {
        ticket: RestoreTicket,
        result: Result<(), AuthFailure>,
    },
    /// A sign-in was asked for. `sets_loading` is false for the automatic ones.
    SignInRequested {
        kind: SignInKind,
        sets_loading: bool,
    },
    /// Earlier token work was cancelled and joined before the sign-in.
    TokenWorkQuiesced {
        flow: SignInFlow,
        result: Result<(), AuthFailure>,
    },
    OnlineChecked {
        flow: SignInFlow,
        online: bool,
    },
    /// The credential exchange finished; on success it wrote the token store.
    ExchangeFinished {
        flow: SignInFlow,
        result: Result<(), AuthFailure>,
    },
    SignInUserFetched {
        flow: SignInFlow,
        result: Result<Option<AuthUser>, AuthFailure>,
    },
    /// A team-list read outside sign-in and restore.
    TeamsRequested,
    TeamsRefreshed {
        ticket: TeamRefreshTicket,
        result: Result<TeamList, AuthFailure>,
    },
    PostSignInHookFinished {
        ticket: TeamRefreshTicket,
    },
    /// The recovery loop's sleep ended.
    TeamScopeRecoveryDue {
        id: u64,
    },
    /// The recovery loop's session check finished.
    TeamScopeRecoveryCheckFinished {
        id: u64,
    },
    /// The selected team was set directly.
    SetSelectedTeam(Option<String>),
    /// A team switch was asked for: a team read already in flight must not
    /// put the old selection back.
    TeamSelectionMutated,
    /// A team delete or rename: a team read already in flight keeps the list
    /// the change left.
    TeamListMutated,
    SendCodeStarted,
    SendCodeFinished {
        sent: bool,
    },
    /// A `42` sign-in remembered its DEBUG credentials.
    DebugCredentialsRemembered,
    SignOutRequested,
    /// Sign-out captured its teardown credentials and cleared the local token store.
    SignOutLocalCleared,
    /// A token read found the session definitively gone.
    TokenReadUnauthorized(TokenReadKind),
    DevAuthAccessTokenFinished {
        got_token: bool,
    },
}

/// An output of the reducer: I/O or a publication for the caller to run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    /// Runs before every session generation change the caller did not announce.
    NotifySessionWillTransition,
    PublishSessionIdentity(Option<SessionIdentity>),
    PublishTeamScope(Option<TeamScope>),
    SaveCachedUser(AuthUser),
    ClearCachedUser,
    SetHasTokens,
    ClearSessionCache,
    PersistSelectedTeam(Option<String>),
    /// Forget the sent code's nonce.
    DropPendingCode,
    /// Store the token store's current refresh token as the latest sign-in's.
    RecordLatestSignInRefreshToken,
    ForgetLatestSignInRefreshToken,
    ForgetDebugCredentials,
    /// Log, at error level, why the app signed out.
    LogSignOut {
        reason: String,
    },
    /// Clear the local token store with no server call.
    ClearLocalSession,
    /// Clear the token store, comparing against the refresh token just read
    /// when `compare_refresh_token`; then send [`Event::StaleSessionCleared`].
    ClearStaleSession {
        ticket: RestoreTicket,
        compare_refresh_token: bool,
        reason: String,
    },
    /// Read the cached user and token baseline, then probe the stored tokens
    /// under [`AuthPhase::ValidateSession`] and the restore budget.
    ProbeStoredTokens(RestoreTicket),
    /// Fetch the current user under the restore budget.
    ValidateCachedSession(RestoreTicket),
    ReadSurvivingRefreshToken {
        ticket: RestoreTicket,
        after_error: Option<AuthFailure>,
    },
    CheckTokenStorageAvailable(RestoreTicket),
    RetryProbeAfter {
        ticket: RestoreTicket,
        delay: Duration,
    },
    /// Run a password sign-in with `sets_loading: false`, then send
    /// [`Event::AutoLoginFinished`].
    AutoLogin {
        ticket: RestoreTicket,
        source: AutoLoginSource,
    },
    /// A restore is already running: wait for its [`Effect::RestoreFinished`].
    JoinRestore,
    /// The restore ended: resume every joined waiter.
    RestoreFinished,
    SetLoading(bool),
    ClearExternalSignInFailureDetail,
    /// Cancel and join earlier validation, token and exchange work.
    QuiesceTokenWork(SignInFlow),
    CheckOnline(SignInFlow),
    RunExchange {
        flow: SignInFlow,
        phase: AuthPhase,
        budget: PhaseBudget,
    },
    /// Fetch the user under [`AuthPhase::FetchUser`] and the network budget.
    FetchUser(SignInFlow),
    SignInSucceeded(SignInFlow),
    SignInFailed {
        flow: Option<SignInFlow>,
        failure: AuthFailure,
    },
    /// Read the teams and the server's selected team under [`AuthPhase::ListTeams`].
    RefreshTeams(TeamRefreshTicket),
    /// Run the post-sign-in hook under [`AuthPhase::PostSignIn`].
    RunPostSignInHook(TeamRefreshTicket),
    SessionCheckRateLimited {
        retry_after: Option<Duration>,
        backoff: Duration,
        attempt: u32,
    },
    SessionCheckSucceeded,
    /// Sleep `delay`, then send [`Event::TeamScopeRecoveryDue`]; once the
    /// check that starts has finished (or started nothing), send
    /// [`Event::TeamScopeRecoveryCheckFinished`]. Cancelled by
    /// [`Effect::CancelTeamScopeRecovery`] with the same id.
    SleepTeamScopeRecovery {
        id: u64,
        delay: Duration,
    },
    CancelTeamScopeRecovery {
        id: u64,
    },
    /// Cancel registered exchanges, validations, post-sign-in hooks and token work.
    CancelInFlightWork,
    ClearPhaseDampers(&'static [AuthPhase]),
    /// Read the stored access and refresh tokens with no network, forget the
    /// latest sign-in refresh token, clear the local token store, then send
    /// [`Event::SignOutLocalCleared`].
    CaptureTeardownCredentialsAndClearLocalSession,
    EndSignOutCredentialCapture,
    WaitForPostSignInHooks,
    /// The bounded best-effort hook and session revocation with the captured tokens.
    ServerTeardown,
    /// Answer a token read with this failure.
    FailTokenRead(AuthFailure),
    /// Sign in with the DEBUG credentials and read an access token.
    TryDevAuthAccessToken,
}
