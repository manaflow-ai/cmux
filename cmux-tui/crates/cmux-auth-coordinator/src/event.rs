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
    /// Which restore run this answer belongs to: one run at a time owns the
    /// restore, and the answers of a finished run are dropped.
    pub id: u64,
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
    /// The restore run with this id finishes.
    Restore { id: u64 },
    /// The sign-in flow completes.
    SignIn(SignInFlow),
}

/// The context of one team-list read (Swift `refreshTeams(generation:)`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TeamRefreshTicket {
    /// Which read this is: each read is answered once, and a repeated or
    /// unknown answer is dropped.
    pub id: u64,
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
    /// Sign-out captured its teardown credentials and cleared the local token
    /// store. `sign_out_epoch` is the one its capture effect carried.
    SignOutLocalCleared {
        sign_out_epoch: u64,
    },
    /// A token read found the session definitively gone.
    TokenReadUnauthorized(TokenReadKind),
    DevAuthAccessTokenFinished {
        got_token: bool,
    },
}

impl Event {
    /// Every event's name, in the table's order (a restore by its trigger).
    pub const KINDS: [&'static str; 30] = [
        "restore_launch",
        "restore_foreground",
        "restore_team_scope_signal",
        "tokens_probed",
        "token_storage_availability",
        "probe_retry_due",
        "cached_session_validated",
        "surviving_refresh_token_read",
        "stale_session_cleared",
        "auto_login_finished",
        "sign_in_requested",
        "token_work_quiesced",
        "online_checked",
        "exchange_finished",
        "sign_in_user_fetched",
        "teams_requested",
        "teams_refreshed",
        "post_sign_in_hook_finished",
        "team_scope_recovery_due",
        "team_scope_recovery_check_finished",
        "set_selected_team",
        "team_selection_mutated",
        "team_list_mutated",
        "send_code_started",
        "send_code_finished",
        "debug_credentials_remembered",
        "sign_out_requested",
        "sign_out_local_cleared",
        "token_read_unauthorized",
        "dev_auth_access_token_finished",
    ];

    /// This event's name in the table.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Restore(RestoreTrigger::Launch) => "restore_launch",
            Self::Restore(RestoreTrigger::Foreground) => "restore_foreground",
            Self::Restore(RestoreTrigger::TeamScopeSignal) => "restore_team_scope_signal",
            Self::TokensProbed { .. } => "tokens_probed",
            Self::TokenStorageAvailability { .. } => "token_storage_availability",
            Self::ProbeRetryDue { .. } => "probe_retry_due",
            Self::CachedSessionValidated { .. } => "cached_session_validated",
            Self::SurvivingRefreshTokenRead { .. } => "surviving_refresh_token_read",
            Self::StaleSessionCleared { .. } => "stale_session_cleared",
            Self::AutoLoginFinished { .. } => "auto_login_finished",
            Self::SignInRequested { .. } => "sign_in_requested",
            Self::TokenWorkQuiesced { .. } => "token_work_quiesced",
            Self::OnlineChecked { .. } => "online_checked",
            Self::ExchangeFinished { .. } => "exchange_finished",
            Self::SignInUserFetched { .. } => "sign_in_user_fetched",
            Self::TeamsRequested => "teams_requested",
            Self::TeamsRefreshed { .. } => "teams_refreshed",
            Self::PostSignInHookFinished { .. } => "post_sign_in_hook_finished",
            Self::TeamScopeRecoveryDue { .. } => "team_scope_recovery_due",
            Self::TeamScopeRecoveryCheckFinished { .. } => "team_scope_recovery_check_finished",
            Self::SetSelectedTeam(..) => "set_selected_team",
            Self::TeamSelectionMutated => "team_selection_mutated",
            Self::TeamListMutated => "team_list_mutated",
            Self::SendCodeStarted => "send_code_started",
            Self::SendCodeFinished { .. } => "send_code_finished",
            Self::DebugCredentialsRemembered => "debug_credentials_remembered",
            Self::SignOutRequested => "sign_out_requested",
            Self::SignOutLocalCleared { .. } => "sign_out_local_cleared",
            Self::TokenReadUnauthorized(..) => "token_read_unauthorized",
            Self::DevAuthAccessTokenFinished { .. } => "dev_auth_access_token_finished",
        }
    }

    /// The restore ticket this event answers, if it answers a restore effect.
    pub fn restore_ticket(&self) -> Option<&RestoreTicket> {
        match self {
            Self::TokensProbed { ticket, .. }
            | Self::TokenStorageAvailability { ticket, .. }
            | Self::ProbeRetryDue { ticket, .. }
            | Self::CachedSessionValidated { ticket, .. }
            | Self::SurvivingRefreshTokenRead { ticket, .. }
            | Self::StaleSessionCleared { ticket, .. }
            | Self::AutoLoginFinished { ticket, .. } => Some(ticket),
            Self::Restore(..)
            | Self::SignInRequested { .. }
            | Self::TokenWorkQuiesced { .. }
            | Self::OnlineChecked { .. }
            | Self::ExchangeFinished { .. }
            | Self::SignInUserFetched { .. }
            | Self::TeamsRequested
            | Self::TeamsRefreshed { .. }
            | Self::PostSignInHookFinished { .. }
            | Self::TeamScopeRecoveryDue { .. }
            | Self::TeamScopeRecoveryCheckFinished { .. }
            | Self::SetSelectedTeam(..)
            | Self::TeamSelectionMutated
            | Self::TeamListMutated
            | Self::SendCodeStarted
            | Self::SendCodeFinished { .. }
            | Self::DebugCredentialsRemembered
            | Self::SignOutRequested
            | Self::SignOutLocalCleared { .. }
            | Self::TokenReadUnauthorized(..)
            | Self::DevAuthAccessTokenFinished { .. } => None,
        }
    }

    /// The sign-in flow this event answers, if it answers a sign-in effect.
    pub fn sign_in_flow(&self) -> Option<SignInFlow> {
        match self {
            Self::TokenWorkQuiesced { flow, .. }
            | Self::OnlineChecked { flow, .. }
            | Self::ExchangeFinished { flow, .. }
            | Self::SignInUserFetched { flow, .. } => Some(*flow),
            Self::Restore(..)
            | Self::TokensProbed { .. }
            | Self::TokenStorageAvailability { .. }
            | Self::ProbeRetryDue { .. }
            | Self::CachedSessionValidated { .. }
            | Self::SurvivingRefreshTokenRead { .. }
            | Self::StaleSessionCleared { .. }
            | Self::AutoLoginFinished { .. }
            | Self::SignInRequested { .. }
            | Self::TeamsRequested
            | Self::TeamsRefreshed { .. }
            | Self::PostSignInHookFinished { .. }
            | Self::TeamScopeRecoveryDue { .. }
            | Self::TeamScopeRecoveryCheckFinished { .. }
            | Self::SetSelectedTeam(..)
            | Self::TeamSelectionMutated
            | Self::TeamListMutated
            | Self::SendCodeStarted
            | Self::SendCodeFinished { .. }
            | Self::DebugCredentialsRemembered
            | Self::SignOutRequested
            | Self::SignOutLocalCleared { .. }
            | Self::TokenReadUnauthorized(..)
            | Self::DevAuthAccessTokenFinished { .. } => None,
        }
    }
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
    /// [`Event::SignOutLocalCleared`] with the same epoch.
    CaptureTeardownCredentialsAndClearLocalSession {
        sign_out_epoch: u64,
    },
    EndSignOutCredentialCapture,
    WaitForPostSignInHooks,
    /// The bounded best-effort hook and session revocation with the captured tokens.
    ServerTeardown,
    /// Answer a token read with this failure.
    FailTokenRead(AuthFailure),
    /// Sign in with the DEBUG credentials and read an access token.
    TryDevAuthAccessToken,
}

impl Effect {
    /// This effect's name in the table.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::NotifySessionWillTransition => "notify_session_will_transition",
            Self::PublishSessionIdentity(..) => "publish_session_identity",
            Self::PublishTeamScope(..) => "publish_team_scope",
            Self::SaveCachedUser(..) => "save_cached_user",
            Self::ClearCachedUser => "clear_cached_user",
            Self::SetHasTokens => "set_has_tokens",
            Self::ClearSessionCache => "clear_session_cache",
            Self::PersistSelectedTeam(..) => "persist_selected_team",
            Self::DropPendingCode => "drop_pending_code",
            Self::RecordLatestSignInRefreshToken => "record_latest_sign_in_refresh_token",
            Self::ForgetLatestSignInRefreshToken => "forget_latest_sign_in_refresh_token",
            Self::ForgetDebugCredentials => "forget_debug_credentials",
            Self::LogSignOut { .. } => "log_sign_out",
            Self::ClearLocalSession => "clear_local_session",
            Self::ClearStaleSession { .. } => "clear_stale_session",
            Self::ProbeStoredTokens(..) => "probe_stored_tokens",
            Self::ValidateCachedSession(..) => "validate_cached_session",
            Self::ReadSurvivingRefreshToken { .. } => "read_surviving_refresh_token",
            Self::CheckTokenStorageAvailable(..) => "check_token_storage_available",
            Self::RetryProbeAfter { .. } => "retry_probe_after",
            Self::AutoLogin { .. } => "auto_login",
            Self::JoinRestore => "join_restore",
            Self::RestoreFinished => "restore_finished",
            Self::SetLoading(..) => "set_loading",
            Self::ClearExternalSignInFailureDetail => "clear_external_sign_in_failure_detail",
            Self::QuiesceTokenWork(..) => "quiesce_token_work",
            Self::CheckOnline(..) => "check_online",
            Self::RunExchange { .. } => "run_exchange",
            Self::FetchUser(..) => "fetch_user",
            Self::SignInSucceeded(..) => "sign_in_succeeded",
            Self::SignInFailed { .. } => "sign_in_failed",
            Self::RefreshTeams(..) => "refresh_teams",
            Self::RunPostSignInHook(..) => "run_post_sign_in_hook",
            Self::SessionCheckRateLimited { .. } => "session_check_rate_limited",
            Self::SessionCheckSucceeded => "session_check_succeeded",
            Self::SleepTeamScopeRecovery { .. } => "sleep_team_scope_recovery",
            Self::CancelTeamScopeRecovery { .. } => "cancel_team_scope_recovery",
            Self::CancelInFlightWork => "cancel_in_flight_work",
            Self::ClearPhaseDampers(..) => "clear_phase_dampers",
            Self::CaptureTeardownCredentialsAndClearLocalSession { .. } => {
                "capture_teardown_credentials_and_clear_local_session"
            }
            Self::EndSignOutCredentialCapture => "end_sign_out_credential_capture",
            Self::WaitForPostSignInHooks => "wait_for_post_sign_in_hooks",
            Self::ServerTeardown => "server_teardown",
            Self::FailTokenRead(..) => "fail_token_read",
            Self::TryDevAuthAccessToken => "try_dev_auth_access_token",
        }
    }
}
