//! The reducer: [`Coordinator::reduce`] takes an [`Event`] (a request, or the
//! result of I/O the caller ran) and returns the [`Effect`]s to run, in order.

use std::collections::BTreeMap;
use std::time::Duration;

use crate::event::{
    AfterTeams, AuthFailure, Effect, Event, Persisted, RestoreTicket, SignInFlow, TokenReadKind,
};
use crate::model::{
    AuthState, AuthTeam, AuthUser, CachedTeamIdentity, LaunchOptions, SessionIdentity, TeamScope,
    resolve_team_id,
};
use crate::phase::team_scope_recovery_delay;

mod restore;
mod session;
mod sign_in;
mod teams;

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
                self.on_tokens_probed(ticket, probe, storage_was_available, read_failed, &mut fx);
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
                self.on_cached_session_validated(ticket, result, &mut fx);
            }
            Event::SurvivingRefreshTokenRead { ticket, after_error, result, read_failed } => {
                self.on_surviving_refresh_token(ticket, after_error, result, read_failed, &mut fx);
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
                self.on_sign_in_requested(kind, sets_loading, &mut fx);
            }
            Event::TokenWorkQuiesced { flow, result } => {
                self.on_token_work_quiesced(flow, result, &mut fx);
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
                    self.fail_sign_in(flow, AuthFailure::Unauthorized, flow.sets_loading, &mut fx);
                }
                Ok(Some(_)) if flow.generation != self.session_generation => {
                    self.fail_sign_in(flow, AuthFailure::Cancelled, flow.sets_loading, &mut fx);
                }
                Ok(Some(user)) => {
                    self.apply_signed_in_user(user, true, AfterTeams::SignIn(flow), &mut fx);
                }
            },
            Event::TeamsRequested => {
                let generation = self.session_generation;
                self.begin_team_refresh(generation, false, AfterTeams::Nothing, &mut fx);
            }
            Event::TeamsRefreshed { ticket, result } => {
                self.on_teams_refreshed(ticket, result, &mut fx);
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
                self.team_mutation_generation = self.team_mutation_generation.wrapping_add(1);
            }
            Event::TeamListMutated => {
                self.team_list_generation = self.team_list_generation.wrapping_add(1);
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
}
