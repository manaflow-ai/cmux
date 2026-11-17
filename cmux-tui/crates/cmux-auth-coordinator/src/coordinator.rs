//! The reducer: [`Coordinator::reduce`] takes an [`Event`] (a request, or the
//! result of I/O the caller ran) and returns the [`Effect`]s to run, in order.

use std::collections::BTreeMap;
use std::time::Duration;

use crate::model::{
    AuthState, AuthTeam, AuthUser, CachedTeamIdentity, LaunchOptions, PrimeInputs, SessionIdentity,
    TeamScope, resolve_team_id, should_start_auto_login,
};
use crate::phase::{
    AuthPhase, FAILED_TOKEN_READ_RETRY_DELAYS, PhaseBudget, SIGN_OUT_CLEARED_PHASES,
    team_scope_rate_limit_delay, team_scope_recovery_delay,
};

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

#[derive(Clone, Copy, Debug)]
struct RateLimitStreak {
    streak: u32,
    delay: Duration,
}

#[derive(Clone, Copy, Debug)]
struct Recovery {
    id: u64,
    attempt: u32,
}

/// The coordinator's view-less state: what it publishes and the generations
/// that keep a late answer from overwriting a newer session.
#[derive(Clone, Debug)]
pub struct Coordinator {
    launch: LaunchOptions,
    is_authenticated: bool,
    current_user: Option<AuthUser>,
    is_restoring_session: bool,
    is_loading: bool,
    available_teams: Vec<AuthTeam>,
    selected_team_id: Option<String>,
    cached_user: Option<AuthUser>,
    has_tokens: bool,
    has_pending_code: bool,
    has_debug_credentials: bool,
    last_sign_out_reason: Option<String>,
    session_generation: u64,
    sign_out_epoch: u64,
    sign_in_attempt_counter: u64,
    token_store_write_high_water: u64,
    active_sign_in_flows: BTreeMap<u64, SignInFlow>,
    is_revalidating_session: bool,
    is_capturing_sign_out_credentials: bool,
    authenticated_teams_session_generation: Option<u64>,
    team_scope_generation: u64,
    last_published_team_scope: Option<TeamScope>,
    team_mutation_generation: u64,
    team_list_generation: u64,
    active_team_refresh_count: u32,
    team_scope_rate_limit: Option<RateLimitStreak>,
    team_scope_recovery: Option<Recovery>,
    next_recovery_id: u64,
    rng: u64,
}

impl Coordinator {
    /// Builds the coordinator and primes its state from launch inputs.
    /// `jitter_seed` seeds the backoff jitter.
    pub fn new(
        launch: LaunchOptions,
        persisted: Persisted,
        jitter_seed: u64,
    ) -> (Self, Vec<Effect>) {
        let mut coordinator = Self {
            launch,
            is_authenticated: false,
            current_user: None,
            is_restoring_session: false,
            is_loading: false,
            available_teams: Vec::new(),
            selected_team_id: persisted.selected_team_id,
            cached_user: persisted.cached_user,
            has_tokens: persisted.has_tokens,
            has_pending_code: false,
            has_debug_credentials: false,
            last_sign_out_reason: None,
            session_generation: 0,
            sign_out_epoch: 0,
            sign_in_attempt_counter: 0,
            token_store_write_high_water: 0,
            active_sign_in_flows: BTreeMap::new(),
            is_revalidating_session: false,
            is_capturing_sign_out_credentials: false,
            authenticated_teams_session_generation: None,
            team_scope_generation: 0,
            last_published_team_scope: None,
            team_mutation_generation: 0,
            team_list_generation: 0,
            active_team_refresh_count: 0,
            team_scope_rate_limit: None,
            team_scope_recovery: None,
            next_recovery_id: 0,
            rng: jitter_seed | 1,
        };
        let mut fx = Vec::new();
        coordinator.prime(&mut fx);
        (coordinator, fx)
    }

    // MARK: - Reads

    pub fn is_authenticated(&self) -> bool {
        self.is_authenticated
    }

    pub fn current_user(&self) -> Option<&AuthUser> {
        self.current_user.as_ref()
    }

    pub fn is_restoring_session(&self) -> bool {
        self.is_restoring_session
    }

    pub fn is_loading(&self) -> bool {
        self.is_loading
    }

    pub fn state(&self) -> AuthState {
        AuthState {
            is_authenticated: self.is_authenticated,
            current_user: self.current_user.clone(),
            is_restoring_session: self.is_restoring_session,
        }
    }

    pub fn available_teams(&self) -> &[AuthTeam] {
        &self.available_teams
    }

    pub fn selected_team_id(&self) -> Option<&str> {
        self.selected_team_id.as_deref()
    }

    /// The team API calls target.
    pub fn resolved_team_id(&self) -> Option<String> {
        resolve_team_id(self.selected_team_id.as_deref(), &self.available_teams)
    }

    pub fn session_generation(&self) -> u64 {
        self.session_generation
    }

    /// Advances at the start of every sign-out.
    pub fn sign_out_revision(&self) -> u64 {
        self.sign_out_epoch
    }

    pub fn last_sign_out_reason(&self) -> Option<&str> {
        self.last_sign_out_reason.as_deref()
    }

    pub fn has_pending_code(&self) -> bool {
        self.has_pending_code
    }

    pub fn team_scope_generation(&self) -> u64 {
        self.team_scope_generation
    }

    pub fn has_pending_team_scope_recovery(&self) -> bool {
        self.team_scope_recovery.is_some()
    }

    /// Whether a sign-in, a restore or a sign-out's credential capture owns a
    /// possibly empty token store: a reader's empty read is then transient.
    pub fn session_token_transition_is_active(&self) -> bool {
        let sign_in_owns_store = self.active_sign_in_flows.values().any(|flow| {
            flow.generation == self.session_generation && flow.sign_out_epoch == self.sign_out_epoch
        });
        let validation_owns_store =
            self.is_revalidating_session && (self.is_restoring_session || self.is_authenticated);
        sign_in_owns_store || validation_owns_store || self.is_capturing_sign_out_credentials
    }

    /// The current account and generation, while no token transition runs.
    pub fn session_identity(&self) -> Option<SessionIdentity> {
        if self.session_token_transition_is_active() {
            return None;
        }
        self.identity_if_signed_in()
    }

    /// The identity the lifecycle streams carry: stable through same-account
    /// revalidation, gone at the synchronous start of sign-out.
    pub fn published_session_identity(&self) -> Option<SessionIdentity> {
        if self.is_capturing_sign_out_credentials {
            return None;
        }
        self.identity_if_signed_in()
    }

    fn identity_if_signed_in(&self) -> Option<SessionIdentity> {
        if !self.is_authenticated {
            return None;
        }
        let account_id = self.current_user.as_ref()?.id.clone();
        if account_id.is_empty() {
            return None;
        }
        Some(SessionIdentity { generation: self.session_generation, account_id })
    }

    /// The current account and its resolved team, once this session's team
    /// list has loaded and contains that team.
    pub fn team_scope(&self) -> Option<TeamScope> {
        let session = self.published_session_identity()?;
        if self.authenticated_teams_session_generation != Some(session.generation) {
            return None;
        }
        let team_id = self.resolved_team_id().filter(|id| !id.is_empty())?;
        if !self.available_teams.iter().any(|team| team.id == team_id) {
            return None;
        }
        Some(TeamScope { session, team_id, generation: self.team_scope_generation })
    }

    /// The persisted account and team, for read-only warming only.
    pub fn cached_team_identity(&self) -> Option<CachedTeamIdentity> {
        if !self.has_tokens {
            return None;
        }
        let account_id = self.current_user.as_ref()?.id.clone();
        let team_id = self.selected_team_id.clone()?;
        if account_id.is_empty() || team_id.is_empty() {
            return None;
        }
        Some(CachedTeamIdentity { account_id, team_id })
    }

    /// Signed in, but this session's team list has not loaded and no read is
    /// in flight to load it.
    pub fn needs_team_scope_recovery(&self) -> bool {
        self.is_authenticated
            && self.active_team_refresh_count == 0
            && self.authenticated_teams_session_generation != Some(self.session_generation)
    }

    /// The recovery loop's next wait: the normal backoff, or the longer
    /// rate-limit backoff while the session check answers 429.
    pub fn team_scope_recovery_wait(&self, attempt: u32) -> Duration {
        let normal = team_scope_recovery_delay(attempt);
        match self.team_scope_rate_limit {
            Some(limit) => normal.max(limit.delay),
            None => normal,
        }
    }

    // MARK: - Reducer

    /// Applies `event` and returns the effects to run, in order.
    pub fn reduce(&mut self, event: Event) -> Vec<Effect> {
        let mut fx = Vec::new();
        match event {
            Event::Restore(trigger) => self.on_restore(trigger, &mut fx),
            Event::TokensProbed { ticket, probe, storage_was_available, read_failed } => {
                self.on_tokens_probed(ticket, probe, storage_was_available, read_failed, &mut fx)
            }
            Event::TokenStorageAvailability { ticket, available } => {
                if ticket.generation != self.session_generation || !available {
                    self.finish_restore(&mut fx);
                } else {
                    fx.push(Effect::ProbeStoredTokens(RestoreTicket {
                        retry_on_storage_available: false,
                        ..ticket
                    }));
                }
            }
            Event::ProbeRetryDue { ticket, cancelled } => {
                if cancelled {
                    if ticket.generation == self.session_generation {
                        self.preserve_cached_session(&mut fx);
                    }
                    self.finish_restore(&mut fx);
                } else if ticket.generation != self.session_generation {
                    self.finish_restore(&mut fx);
                } else {
                    fx.push(Effect::ProbeStoredTokens(RestoreTicket {
                        failed_read_retries: ticket.failed_read_retries + 1,
                        ..ticket
                    }));
                }
            }
            Event::CachedSessionValidated { ticket, result } => {
                self.on_cached_session_validated(ticket, result, &mut fx)
            }
            Event::SurvivingRefreshTokenRead { ticket, after_error, result, read_failed } => {
                self.on_surviving_refresh_token(ticket, after_error, result, read_failed, &mut fx)
            }
            Event::StaleSessionCleared { ticket, reason } => {
                if ticket.generation == self.session_generation
                    && self.token_store_write_high_water == ticket.store_write_high_water
                {
                    self.clear_auth_state(&reason, true, false, &mut fx);
                }
                self.finish_restore(&mut fx);
            }
            Event::AutoLoginFinished { ticket, result } => match result {
                Ok(()) | Err(AuthFailure::Cancelled) => self.finish_restore(&mut fx),
                Err(_) => self.clear_stale_session(ticket, false, "auto-login failed", &mut fx),
            },
            Event::SignInRequested { kind, sets_loading } => {
                self.on_sign_in_requested(kind, sets_loading, &mut fx)
            }
            Event::TokenWorkQuiesced { flow, result } => {
                self.on_token_work_quiesced(flow, result, &mut fx)
            }
            Event::OnlineChecked { flow, online } => {
                if !online {
                    self.fail_sign_in(flow, AuthFailure::Offline, false, &mut fx);
                } else {
                    if flow.sets_loading {
                        self.is_loading = true;
                        fx.push(Effect::SetLoading(true));
                    }
                    if let Some((phase, budget)) = flow.kind.exchange() {
                        fx.push(Effect::RunExchange { flow, phase, budget });
                    }
                }
            }
            Event::ExchangeFinished { flow, result } => match result {
                Err(failure) => self.fail_sign_in(flow, failure, flow.sets_loading, &mut fx),
                Ok(()) => {
                    self.token_store_write_high_water =
                        self.token_store_write_high_water.max(flow.attempt);
                    fx.push(Effect::RecordLatestSignInRefreshToken);
                    self.complete_sign_in(flow, &mut fx);
                }
            },
            Event::SignInUserFetched { flow, result } => match result {
                Err(failure) => self.fail_sign_in(flow, failure, flow.sets_loading, &mut fx),
                Ok(None) => {
                    self.fail_sign_in(flow, AuthFailure::Unauthorized, flow.sets_loading, &mut fx)
                }
                Ok(Some(_)) if flow.generation != self.session_generation => {
                    self.fail_sign_in(flow, AuthFailure::Cancelled, flow.sets_loading, &mut fx);
                }
                Ok(Some(user)) => {
                    self.apply_signed_in_user(user, true, AfterTeams::SignIn(flow), &mut fx)
                }
            },
            Event::TeamsRequested => {
                let generation = self.session_generation;
                self.begin_team_refresh(generation, false, AfterTeams::Nothing, &mut fx);
            }
            Event::TeamsRefreshed { ticket, result } => {
                self.on_teams_refreshed(ticket, result, &mut fx)
            }
            Event::PostSignInHookFinished { ticket } => self.after_teams(ticket.after, &mut fx),
            Event::TeamScopeRecoveryDue { id } => self.on_recovery_due(id, &mut fx),
            Event::TeamScopeRecoveryCheckFinished { id } => {
                if let Some(recovery) = self.team_scope_recovery
                    && recovery.id == id
                {
                    fx.push(Effect::SleepTeamScopeRecovery {
                        id,
                        delay: self.team_scope_recovery_wait(recovery.attempt),
                    });
                }
            }
            Event::SetSelectedTeam(team_id) => self.set_selected_team(team_id, &mut fx),
            Event::TeamSelectionMutated => {
                self.team_mutation_generation = self.team_mutation_generation.wrapping_add(1)
            }
            Event::TeamListMutated => {
                self.team_list_generation = self.team_list_generation.wrapping_add(1)
            }
            Event::SendCodeStarted => {
                self.is_loading = true;
                fx.push(Effect::SetLoading(true));
            }
            Event::SendCodeFinished { sent } => {
                if sent {
                    self.has_pending_code = true;
                }
                self.is_loading = false;
                fx.push(Effect::SetLoading(false));
            }
            Event::DebugCredentialsRemembered => self.has_debug_credentials = true,
            Event::SignOutRequested => self.on_sign_out_requested(&mut fx),
            Event::SignOutLocalCleared => self.on_sign_out_local_cleared(&mut fx),
            Event::TokenReadUnauthorized(kind) => {
                if self.session_token_transition_is_active() {
                    fx.push(Effect::FailTokenRead(AuthFailure::NetworkError));
                } else if kind == TokenReadKind::AccessToken
                    && self.launch.debug_build
                    && self.launch.includes_dev_auth
                    && self.has_debug_credentials
                {
                    fx.push(Effect::TryDevAuthAccessToken);
                } else {
                    self.fail_token_read_unauthorized(kind, &mut fx);
                }
            }
            Event::DevAuthAccessTokenFinished { got_token } => {
                if !got_token {
                    self.fail_token_read_unauthorized(TokenReadKind::AccessToken, &mut fx);
                }
            }
        }
        fx
    }

    // MARK: - Priming

    fn prime(&mut self, fx: &mut Vec<Effect>) {
        if self.launch.clear_auth_requested {
            self.clear_auth_state("launch asked to clear auth", false, false, fx);
            if self.launch.includes_dev_auth {
                self.has_debug_credentials = false;
                fx.push(Effect::ForgetDebugCredentials);
            }
            fx.push(Effect::ClearLocalSession);
            return;
        }
        if self.launch.should_clear_stored_session_before_priming() {
            self.clear_auth_state("auth environment changed", false, false, fx);
        }
        let mock = self.launch.mock_data();
        let fixture = if mock { None } else { self.launch.fixture().cloned() };
        let auto_login = !mock
            && fixture.is_none()
            && self.launch.environment_auto_login
            && self.launch.auto_login.is_some();
        let state = AuthState::primed(&PrimeInputs {
            clear_auth_requested: false,
            mock_data_enabled: mock,
            has_tokens: fixture.is_some() || self.has_tokens,
            cached_user: if fixture.is_some() { fixture.clone() } else { self.cached_user.clone() },
            fixture_user: fixture,
            has_auto_login_credentials: auto_login,
            mock_user: AuthUser::ui_test_mock(),
        });
        self.apply(state, fx);
    }

    // MARK: - Restore

    fn on_restore(&mut self, trigger: RestoreTrigger, fx: &mut Vec<Effect>) {
        match trigger {
            RestoreTrigger::Launch => {
                if self.launch.should_clear_stored_session_before_priming() {
                    fx.push(Effect::ClearLocalSession);
                }
            }
            RestoreTrigger::Foreground => {
                if !(self.is_authenticated || self.is_restoring_session || self.has_tokens) {
                    return;
                }
            }
            RestoreTrigger::TeamScopeSignal => {
                if !self.needs_team_scope_recovery() || self.team_scope_rate_limit.is_some() {
                    return;
                }
            }
        }
        self.check_existing_session(fx);
    }

    fn check_existing_session(&mut self, fx: &mut Vec<Effect>) {
        if self.launch.clear_auth_requested {
            return;
        }
        if self.is_revalidating_session {
            fx.push(Effect::JoinRestore);
            return;
        }
        self.is_revalidating_session = true;
        fx.push(Effect::ProbeStoredTokens(RestoreTicket {
            generation: self.session_generation,
            store_write_high_water: self.token_store_write_high_water,
            retry_on_storage_available: true,
            failed_read_retries: 0,
        }));
    }

    fn on_tokens_probed(
        &mut self,
        ticket: RestoreTicket,
        probe: Result<bool, AuthFailure>,
        storage_was_available: bool,
        read_failed: bool,
        fx: &mut Vec<Effect>,
    ) {
        let stale = ticket.generation != self.session_generation;
        let has_stored_tokens = match probe {
            Err(_) => {
                if !stale {
                    self.preserve_cached_session(fx);
                }
                return self.finish_restore(fx);
            }
            Ok(_) if stale => return self.finish_restore(fx),
            Ok(has) => has,
        };
        if self.launch.mock_data() {
            return self.finish_restore(fx);
        }
        if let Some(fixture) = self.launch.fixture().cloned() {
            self.save_cached_user(fixture.clone(), fx);
            self.set_has_tokens(fx);
            self.current_user = Some(fixture);
            self.is_authenticated = true;
            self.publish_session_identity(fx);
            if self.launch.fixture_teams_requested {
                return self.begin_team_refresh(ticket.generation, false, AfterTeams::Restore, fx);
            }
            return self.finish_restore(fx);
        }
        if self.launch.environment_auto_login
            && let Some(credentials) = self.launch.auto_login
            && should_start_auto_login(true, has_stored_tokens)
            && !credentials.email_is_empty
        {
            fx.push(Effect::AutoLogin { ticket, source: AutoLoginSource::Environment });
            return;
        }
        let cached_user = self.cached_user.clone();
        if has_stored_tokens {
            self.set_has_tokens(fx);
            if self.current_user.is_none() && cached_user.is_some() {
                self.current_user = cached_user;
            }
            fx.push(Effect::ValidateCachedSession(ticket));
            return;
        }
        if !storage_was_available {
            self.preserve_cached_session(fx);
            if ticket.retry_on_storage_available {
                fx.push(Effect::CheckTokenStorageAvailable(ticket));
                return;
            }
            return self.finish_restore(fx);
        }
        let has_cached_session = cached_user.is_some() || self.has_tokens;
        if has_cached_session && read_failed {
            if let Some(delay) = FAILED_TOKEN_READ_RETRY_DELAYS.get(ticket.failed_read_retries) {
                fx.push(Effect::RetryProbeAfter { ticket, delay: *delay });
                return;
            }
            self.preserve_cached_session(fx);
            return self.finish_restore(fx);
        }
        if self.launch.includes_dev_auth && self.has_debug_credentials {
            fx.push(Effect::AutoLogin { ticket, source: AutoLoginSource::DebugCredentials });
            return;
        }
        let reason = if has_cached_session {
            "launch restore found no stored tokens in readable storage"
        } else {
            "launch restore found no session"
        };
        self.clear_auth_state(reason, true, false, fx);
        self.finish_restore(fx);
    }

    fn on_cached_session_validated(
        &mut self,
        ticket: RestoreTicket,
        result: Result<Option<AuthUser>, AuthFailure>,
        fx: &mut Vec<Effect>,
    ) {
        if ticket.generation != self.session_generation {
            return self.finish_restore(fx);
        }
        match result {
            Ok(Some(user)) => self.apply_signed_in_user(user, false, AfterTeams::Restore, fx),
            Ok(None) => fx.push(Effect::ReadSurvivingRefreshToken { ticket, after_error: None }),
            Err(AuthFailure::Cancelled) => self.finish_restore(fx),
            Err(AuthFailure::TimedOut) => {
                self.preserve_cached_session(fx);
                self.finish_restore(fx);
            }
            Err(failure) => {
                fx.push(Effect::ReadSurvivingRefreshToken { ticket, after_error: Some(failure) })
            }
        }
    }

    fn on_surviving_refresh_token(
        &mut self,
        ticket: RestoreTicket,
        after_error: Option<AuthFailure>,
        result: Result<bool, AuthFailure>,
        read_failed: bool,
        fx: &mut Vec<Effect>,
    ) {
        let survives = match (result, &after_error) {
            // After a nil user, a failed read goes to the failure path.
            (Err(failure), None) => {
                return self.on_cached_session_validated(ticket, Err(failure), fx);
            }
            (Err(_), Some(_)) => {
                self.preserve_cached_session(fx);
                return self.finish_restore(fx);
            }
            (Ok(survives), _) => survives,
        };
        if ticket.generation != self.session_generation {
            return self.finish_restore(fx);
        }
        if !survives && read_failed {
            self.preserve_cached_session(fx);
            return self.finish_restore(fx);
        }
        let Some(failure) = after_error else {
            if survives {
                self.preserve_cached_session(fx);
                return self.finish_restore(fx);
            }
            return self.clear_stale_session(
                ticket,
                false,
                "validation returned no current user and no refresh token survives",
                fx,
            );
        };
        if !survives {
            return self.clear_stale_session(
                ticket,
                false,
                "validation failed and no refresh token survives",
                fx,
            );
        }
        self.note_team_scope_failure(&failure, fx);
        if failure == AuthFailure::Unauthorized {
            self.clear_stale_session(
                ticket,
                true,
                "validation failed with a session-clearing error",
                fx,
            );
        } else {
            self.preserve_cached_session(fx);
            self.finish_restore(fx);
        }
    }

    /// The first half of Swift `clearStaleSessionState`: nothing at all when a
    /// newer sign-in has written the store since the restore began.
    fn clear_stale_session(
        &mut self,
        ticket: RestoreTicket,
        compare_refresh_token: bool,
        reason: &str,
        fx: &mut Vec<Effect>,
    ) {
        if self.token_store_write_high_water != ticket.store_write_high_water {
            return self.finish_restore(fx);
        }
        fx.push(Effect::ClearStaleSession {
            ticket,
            compare_refresh_token,
            reason: reason.to_owned(),
        });
    }

    fn finish_restore(&mut self, fx: &mut Vec<Effect>) {
        if self.authenticated_teams_session_generation == Some(self.session_generation) {
            self.cancel_team_scope_recovery(fx);
        }
        self.is_revalidating_session = false;
        fx.push(Effect::RestoreFinished);
    }

    fn preserve_cached_session(&mut self, fx: &mut Vec<Effect>) {
        self.set_has_tokens(fx);
        let user = self.current_user.clone().or_else(|| self.cached_user.clone());
        self.is_authenticated = user.is_some();
        self.current_user = user;
        self.is_restoring_session = false;
        self.publish_session_identity(fx);
        self.schedule_team_scope_recovery(fx);
    }

    // MARK: - Sign-in

    fn on_sign_in_requested(&mut self, kind: SignInKind, sets_loading: bool, fx: &mut Vec<Effect>) {
        if kind == SignInKind::VerifyCode && !self.has_pending_code {
            fx.push(Effect::SignInFailed { flow: None, failure: AuthFailure::InvalidCode });
            return;
        }
        self.sign_in_attempt_counter = self.sign_in_attempt_counter.wrapping_add(1);
        let flow = SignInFlow {
            generation: self.session_generation,
            attempt: self.sign_in_attempt_counter,
            sign_out_epoch: self.sign_out_epoch,
            kind,
            sets_loading,
        };
        self.active_sign_in_flows.insert(flow.attempt, flow);
        fx.push(Effect::QuiesceTokenWork(flow));
    }

    fn on_token_work_quiesced(
        &mut self,
        flow: SignInFlow,
        result: Result<(), AuthFailure>,
        fx: &mut Vec<Effect>,
    ) {
        let current = flow.generation == self.session_generation
            && flow.sign_out_epoch == self.sign_out_epoch;
        if let Err(failure) = result {
            self.active_sign_in_flows.remove(&flow.attempt);
            fx.push(Effect::SignInFailed { flow: Some(flow), failure });
            return;
        }
        if !current {
            self.active_sign_in_flows.remove(&flow.attempt);
            fx.push(Effect::SignInFailed { flow: Some(flow), failure: AuthFailure::Cancelled });
            return;
        }
        if flow.kind == SignInKind::External {
            self.is_loading = true;
            fx.push(Effect::SetLoading(true));
            fx.push(Effect::ClearExternalSignInFailureDetail);
            return self.complete_sign_in(flow, fx);
        }
        fx.push(Effect::CheckOnline(flow));
    }

    fn complete_sign_in(&mut self, flow: SignInFlow, fx: &mut Vec<Effect>) {
        if self.token_store_write_high_water < flow.attempt {
            fx.push(Effect::RecordLatestSignInRefreshToken);
        }
        self.token_store_write_high_water = self.token_store_write_high_water.max(flow.attempt);
        if flow.generation != self.session_generation {
            // A sign-out (or newer session) landed during the exchange. Roll
            // back the tokens it re-stored, unless a newer attempt owns the store.
            let sign_out_began = flow.sign_out_epoch != self.sign_out_epoch;
            if (sign_out_began || !self.is_authenticated)
                && self.token_store_write_high_water == flow.attempt
            {
                fx.push(Effect::ClearLocalSession);
            }
            return self.fail_sign_in(flow, AuthFailure::Cancelled, flow.sets_loading, fx);
        }
        fx.push(Effect::FetchUser(flow));
    }

    fn fail_sign_in(
        &mut self,
        flow: SignInFlow,
        failure: AuthFailure,
        loading_was_set: bool,
        fx: &mut Vec<Effect>,
    ) {
        let loading_was_set = loading_was_set || flow.kind == SignInKind::External;
        if loading_was_set {
            self.is_loading = false;
            fx.push(Effect::SetLoading(false));
        }
        self.finish_sign_in_flow(flow, fx);
        fx.push(Effect::SignInFailed { flow: Some(flow), failure });
    }

    fn finish_sign_in_flow(&mut self, flow: SignInFlow, fx: &mut Vec<Effect>) {
        self.active_sign_in_flows.remove(&flow.attempt);
        self.publish_session_identity(fx);
    }

    fn succeed_sign_in(&mut self, flow: SignInFlow, fx: &mut Vec<Effect>) {
        if flow.sets_loading || flow.kind == SignInKind::External {
            self.is_loading = false;
            fx.push(Effect::SetLoading(false));
        }
        self.finish_sign_in_flow(flow, fx);
        if flow.kind == SignInKind::VerifyCode {
            self.has_pending_code = false;
            fx.push(Effect::DropPendingCode);
        }
        fx.push(Effect::SignInSucceeded(flow));
    }

    /// Publishes `user`. A completed exchange (`sign_in`) always advances the
    /// generation; a revalidation advances it only on an account change.
    fn apply_signed_in_user(
        &mut self,
        user: AuthUser,
        sign_in: bool,
        after: AfterTeams,
        fx: &mut Vec<Effect>,
    ) {
        let runs_hook = if sign_in {
            self.cancel_team_scope_recovery(fx);
            self.advance_session_generation(true, fx);
            true
        } else {
            let transition = !self.is_authenticated
                || self.current_user.as_ref().map(|current| current.id.as_str()) != Some(&user.id);
            if transition {
                self.advance_session_generation(true, fx);
            }
            transition
        };
        let generation = self.session_generation;
        self.current_user = Some(user.clone());
        self.is_authenticated = true;
        self.is_restoring_session = false;
        self.publish_session_identity(fx);
        self.save_cached_user(user, fx);
        self.set_has_tokens(fx);
        self.begin_team_refresh(generation, runs_hook, after, fx);
    }

    // MARK: - Teams

    fn begin_team_refresh(
        &mut self,
        generation: u64,
        runs_hook: bool,
        after: AfterTeams,
        fx: &mut Vec<Effect>,
    ) {
        self.active_team_refresh_count += 1;
        fx.push(Effect::RefreshTeams(TeamRefreshTicket {
            generation,
            mutation_generation: self.team_mutation_generation,
            list_generation: self.team_list_generation,
            runs_post_sign_in_hook: runs_hook,
            after,
        }));
    }

    fn on_teams_refreshed(
        &mut self,
        ticket: TeamRefreshTicket,
        result: Result<TeamList, AuthFailure>,
        fx: &mut Vec<Effect>,
    ) {
        self.active_team_refresh_count = self.active_team_refresh_count.saturating_sub(1);
        let current = ticket.generation == self.session_generation;
        match result {
            Ok(list) if current => {
                self.team_scope_rate_limit = None;
                fx.push(Effect::SessionCheckSucceeded);
                self.authenticated_teams_session_generation = Some(ticket.generation);
                if ticket.list_generation == self.team_list_generation {
                    self.set_available_teams(list.teams, fx);
                }
                let selection_changed = ticket.mutation_generation != self.team_mutation_generation;
                let wanted = if selection_changed {
                    self.selected_team_id.clone()
                } else {
                    list.server_selected_team_id.or_else(|| self.selected_team_id.clone())
                };
                let resolved = resolve_team_id(wanted.as_deref(), &self.available_teams);
                self.set_selected_team(resolved, fx);
            }
            Err(failure) if current => {
                self.note_team_scope_failure(&failure, fx);
                self.schedule_team_scope_recovery(fx);
            }
            _ => {}
        }
        // The rest of `applySignedInUser`: a sign-out during the read skips the hook.
        if ticket.after == AfterTeams::Nothing {
            return;
        }
        if current && ticket.runs_post_sign_in_hook {
            fx.push(Effect::RunPostSignInHook(ticket));
            return;
        }
        self.after_teams(ticket.after, fx);
    }

    fn after_teams(&mut self, after: AfterTeams, fx: &mut Vec<Effect>) {
        match after {
            AfterTeams::Nothing => {}
            AfterTeams::Restore => self.finish_restore(fx),
            AfterTeams::SignIn(flow) => self.succeed_sign_in(flow, fx),
        }
    }

    fn set_available_teams(&mut self, teams: Vec<AuthTeam>, fx: &mut Vec<Effect>) {
        self.available_teams = teams;
        self.publish_team_scope(fx);
    }

    fn set_selected_team(&mut self, team_id: Option<String>, fx: &mut Vec<Effect>) {
        if team_id == self.selected_team_id {
            return;
        }
        self.selected_team_id = team_id.clone();
        fx.push(Effect::PersistSelectedTeam(team_id));
        self.publish_team_scope(fx);
    }

    /// A 429 starts or extends the backoff; any other classified failure ends
    /// it; a timeout leaves it as is.
    fn note_team_scope_failure(&mut self, failure: &AuthFailure, fx: &mut Vec<Effect>) {
        match failure {
            AuthFailure::RateLimited { retry_after } => {
                let streak = self.team_scope_rate_limit.map_or(0, |limit| limit.streak) + 1;
                let jitter = 0.5 + 0.5 * self.next_unit();
                let delay = team_scope_rate_limit_delay(*retry_after, streak, jitter);
                self.team_scope_rate_limit = Some(RateLimitStreak { streak, delay });
                fx.push(Effect::SessionCheckRateLimited {
                    retry_after: *retry_after,
                    backoff: delay,
                    attempt: streak,
                });
            }
            _ => self.team_scope_rate_limit = None,
        }
    }

    fn schedule_team_scope_recovery(&mut self, fx: &mut Vec<Effect>) {
        if !self.needs_team_scope_recovery() || self.team_scope_recovery.is_some() {
            return;
        }
        self.next_recovery_id += 1;
        let recovery = Recovery { id: self.next_recovery_id, attempt: 0 };
        self.team_scope_recovery = Some(recovery);
        fx.push(Effect::SleepTeamScopeRecovery {
            id: recovery.id,
            delay: self.team_scope_recovery_wait(0),
        });
    }

    fn on_recovery_due(&mut self, id: u64, fx: &mut Vec<Effect>) {
        let Some(recovery) = self.team_scope_recovery else {
            return;
        };
        if recovery.id != id {
            return;
        }
        if !self.needs_team_scope_recovery() {
            self.team_scope_recovery = None;
            return;
        }
        self.team_scope_recovery = Some(Recovery { id, attempt: recovery.attempt + 1 });
        self.check_existing_session(fx);
    }

    fn cancel_team_scope_recovery(&mut self, fx: &mut Vec<Effect>) {
        if let Some(recovery) = self.team_scope_recovery.take() {
            fx.push(Effect::CancelTeamScopeRecovery { id: recovery.id });
        }
        self.team_scope_rate_limit = None;
    }

    // MARK: - Sign-out

    fn on_sign_out_requested(&mut self, fx: &mut Vec<Effect>) {
        self.is_capturing_sign_out_credentials = true;
        fx.push(Effect::CancelInFlightWork);
        self.advance_session_generation(true, fx);
        self.sign_out_epoch = self.sign_out_epoch.wrapping_add(1);
        self.publish_session_identity(fx);
        fx.push(Effect::ClearPhaseDampers(SIGN_OUT_CLEARED_PHASES));
        fx.push(Effect::CaptureTeardownCredentialsAndClearLocalSession);
    }

    fn on_sign_out_local_cleared(&mut self, fx: &mut Vec<Effect>) {
        self.is_capturing_sign_out_credentials = false;
        fx.push(Effect::EndSignOutCredentialCapture);
        if self.launch.includes_dev_auth {
            self.has_debug_credentials = false;
            fx.push(Effect::ForgetDebugCredentials);
        }
        self.clear_auth_state("signed out by the person", false, true, fx);
        fx.push(Effect::WaitForPostSignInHooks);
        fx.push(Effect::ServerTeardown);
    }

    fn fail_token_read_unauthorized(&mut self, kind: TokenReadKind, fx: &mut Vec<Effect>) {
        let reason = match kind {
            TokenReadKind::AccessToken => "access token unavailable and no refresh token survives",
            TokenReadKind::ForceRefreshAccessToken => {
                "forced token refresh failed and no refresh token survives"
            }
        };
        self.clear_auth_state(reason, true, false, fx);
        fx.push(Effect::FailTokenRead(AuthFailure::Unauthorized));
    }

    // MARK: - State helpers

    /// The one place every local sign-out goes through, each with its reason.
    fn clear_auth_state(
        &mut self,
        reason: &str,
        preserve_pending_code: bool,
        transition_already_announced: bool,
        fx: &mut Vec<Effect>,
    ) {
        fx.push(Effect::LogSignOut { reason: reason.to_owned() });
        self.last_sign_out_reason = Some(reason.to_owned());
        self.advance_session_generation(!transition_already_announced, fx);
        self.cancel_team_scope_recovery(fx);
        fx.push(Effect::ForgetLatestSignInRefreshToken);
        if !preserve_pending_code {
            self.has_pending_code = false;
            fx.push(Effect::DropPendingCode);
        }
        self.cached_user = None;
        fx.push(Effect::ClearCachedUser);
        self.has_tokens = false;
        fx.push(Effect::ClearSessionCache);
        self.set_available_teams(Vec::new(), fx);
        self.set_selected_team(None, fx);
        self.apply(AuthState::cleared(), fx);
    }

    fn advance_session_generation(&mut self, notify: bool, fx: &mut Vec<Effect>) {
        if notify {
            fx.push(Effect::NotifySessionWillTransition);
        }
        self.session_generation = self.session_generation.wrapping_add(1);
        self.authenticated_teams_session_generation = None;
        self.set_available_teams(Vec::new(), fx);
    }

    fn apply(&mut self, state: AuthState, fx: &mut Vec<Effect>) {
        self.current_user = state.current_user;
        self.is_authenticated = state.is_authenticated;
        self.is_restoring_session = state.is_restoring_session;
        self.publish_session_identity(fx);
    }

    fn publish_session_identity(&mut self, fx: &mut Vec<Effect>) {
        fx.push(Effect::PublishSessionIdentity(self.published_session_identity()));
        self.publish_team_scope(fx);
    }

    /// Publishes the team scope when its account or team changed, advancing
    /// its generation.
    fn publish_team_scope(&mut self, fx: &mut Vec<Effect>) {
        let next = self.team_scope();
        let previous = self.last_published_team_scope.as_ref();
        let same = next.as_ref().map(|scope| (&scope.session, &scope.team_id))
            == previous.map(|scope| (&scope.session, &scope.team_id));
        if same {
            return;
        }
        self.team_scope_generation = self.team_scope_generation.wrapping_add(1);
        let scope = self.team_scope();
        self.last_published_team_scope = scope.clone();
        fx.push(Effect::PublishTeamScope(scope));
    }

    fn save_cached_user(&mut self, user: AuthUser, fx: &mut Vec<Effect>) {
        self.cached_user = Some(user.clone());
        fx.push(Effect::SaveCachedUser(user));
    }

    fn set_has_tokens(&mut self, fx: &mut Vec<Effect>) {
        self.has_tokens = true;
        fx.push(Effect::SetHasTokens);
    }

    /// A uniform draw in [0, 1) from a xorshift generator.
    fn next_unit(&mut self) -> f64 {
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng = x;
        (x >> 11) as f64 / (1u64 << 53) as f64
    }
}
