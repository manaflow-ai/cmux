//! The reducer: [`Coordinator::reduce`] takes an [`Event`] (a request, or the
//! result of I/O the caller ran) and returns the [`Effect`]s to run, in order.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use crate::event::{
    AfterTeams, AuthFailure, Effect, Event, Persisted, RestoreTicket, SignInFlow, TokenReadKind,
};
use crate::machine::Refusal;
use crate::model::{
    AuthState, AuthTeam, AuthUser, CachedTeamIdentity, LaunchOptions, SessionIdentity, TeamScope,
    resolve_team_id,
};
use crate::phase::team_scope_recovery_delay;

mod restore;
mod session;
mod sign_in;
pub(crate) mod state;
pub(crate) mod table;
mod teams;

use state::{
    Backoff, DebugCredentials, Generations, Loading, PendingCode, RecoveryLoop, Restore, Session,
    Teams, TokenCache,
};

/// The coordinator's view-less state: what it publishes and the generations
/// that keep a late answer from overwriting a newer session. Each region is a
/// sum type ([`state`]); the open tickets (sign-in flows, sign-out captures,
/// team reads) are keyed by the generation they were issued under.
#[derive(Clone, Debug, PartialEq)]
pub struct Coordinator {
    launch: LaunchOptions,
    session: Session,
    restore: Restore,
    loading: Loading,
    teams: Teams,
    selected_team_id: Option<String>,
    cached_user: Option<AuthUser>,
    token_cache: TokenCache,
    pending_code: PendingCode,
    debug_credentials: DebugCredentials,
    last_sign_out_reason: Option<String>,
    generations: Generations,
    /// The sign-in flows begun and not yet finished, by attempt.
    active_sign_in_flows: BTreeMap<u64, SignInFlow>,
    /// The sign-out epochs whose credential capture has not answered yet.
    pending_sign_out_captures: BTreeSet<u64>,
    last_published_team_scope: Option<TeamScope>,
    /// The team reads issued and not yet answered, by id.
    pending_team_reads: BTreeSet<u64>,
    backoff: Backoff,
    recovery: RecoveryLoop,
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
            session: Session::SignedOut { shown: None },
            restore: Restore::Idle,
            loading: Loading::Idle,
            teams: Teams::Unloaded,
            selected_team_id: persisted.selected_team_id,
            cached_user: persisted.cached_user,
            token_cache: if persisted.has_tokens { TokenCache::Stored } else { TokenCache::Empty },
            pending_code: PendingCode::None,
            debug_credentials: DebugCredentials::None,
            last_sign_out_reason: None,
            generations: Generations::default(),
            active_sign_in_flows: BTreeMap::new(),
            pending_sign_out_captures: BTreeSet::new(),
            last_published_team_scope: None,
            pending_team_reads: BTreeSet::new(),
            backoff: Backoff::Clear,
            recovery: RecoveryLoop::Idle,
            rng: jitter_seed | 1,
        };
        let mut fx = Vec::new();
        coordinator.prime(&mut fx);
        (coordinator, fx)
    }

    // MARK: - Reads

    pub fn is_authenticated(&self) -> bool {
        self.session.is_authenticated()
    }

    pub fn current_user(&self) -> Option<&AuthUser> {
        self.session.user()
    }

    pub fn is_restoring_session(&self) -> bool {
        self.session.is_restoring()
    }

    pub fn is_loading(&self) -> bool {
        self.loading == Loading::Busy
    }

    pub fn state(&self) -> AuthState {
        self.session.published()
    }

    pub fn available_teams(&self) -> &[AuthTeam] {
        self.teams.list()
    }

    pub fn selected_team_id(&self) -> Option<&str> {
        self.selected_team_id.as_deref()
    }

    /// The team API calls target.
    pub fn resolved_team_id(&self) -> Option<String> {
        resolve_team_id(self.selected_team_id.as_deref(), self.teams.list())
    }

    pub fn session_generation(&self) -> u64 {
        self.generations.session
    }

    /// Advances at the start of every sign-out.
    pub fn sign_out_revision(&self) -> u64 {
        self.generations.sign_out_epoch
    }

    pub fn last_sign_out_reason(&self) -> Option<&str> {
        self.last_sign_out_reason.as_deref()
    }

    pub fn has_pending_code(&self) -> bool {
        self.pending_code == PendingCode::Sent
    }

    pub fn team_scope_generation(&self) -> u64 {
        self.generations.team_scope
    }

    pub fn has_pending_team_scope_recovery(&self) -> bool {
        self.recovery != RecoveryLoop::Idle
    }

    /// Whether a sign-in, a restore or a sign-out's credential capture owns a
    /// possibly empty token store: a reader's empty read is then transient.
    pub fn session_token_transition_is_active(&self) -> bool {
        let sign_in_owns_store =
            self.active_sign_in_flows.values().any(|flow| self.flow_is_current(*flow));
        let validation_owns_store = match self.restore {
            Restore::Idle => false,
            Restore::Running { .. } => self.session.is_restoring() || self.is_authenticated(),
        };
        sign_in_owns_store || validation_owns_store || !self.pending_sign_out_captures.is_empty()
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
        if !self.pending_sign_out_captures.is_empty() {
            return None;
        }
        self.identity_if_signed_in()
    }

    fn identity_if_signed_in(&self) -> Option<SessionIdentity> {
        let user = match &self.session {
            Session::SignedOut { .. } | Session::Restoring { .. } => return None,
            Session::RestoringSignedIn { user } | Session::SignedIn { user } => user,
        };
        if user.id.is_empty() {
            return None;
        }
        Some(SessionIdentity { generation: self.generations.session, account_id: user.id.clone() })
    }

    /// The current account and its resolved team, once this session's team
    /// list has loaded and contains that team.
    pub fn team_scope(&self) -> Option<TeamScope> {
        let session = self.published_session_identity()?;
        let teams = match &self.teams {
            Teams::Unloaded => return None,
            Teams::Loaded { teams } => teams,
        };
        let team_id = self.resolved_team_id().filter(|id| !id.is_empty())?;
        if !teams.iter().any(|team| team.id == team_id) {
            return None;
        }
        Some(TeamScope { session, team_id, generation: self.generations.team_scope })
    }

    /// The persisted account and team, for read-only warming only.
    pub fn cached_team_identity(&self) -> Option<CachedTeamIdentity> {
        if self.token_cache == TokenCache::Empty {
            return None;
        }
        let account_id = self.session.user()?.id.clone();
        let team_id = self.selected_team_id.clone()?;
        if account_id.is_empty() || team_id.is_empty() {
            return None;
        }
        Some(CachedTeamIdentity { account_id, team_id })
    }

    /// Signed in, but this session's team list has not loaded and no read is
    /// in flight to load it.
    pub fn needs_team_scope_recovery(&self) -> bool {
        self.is_authenticated()
            && self.pending_team_reads.is_empty()
            && self.teams == Teams::Unloaded
    }

    /// The recovery loop's next wait: the normal backoff, or the longer
    /// rate-limit backoff while the session check answers 429.
    pub fn team_scope_recovery_wait(&self, attempt: u32) -> Duration {
        let normal = team_scope_recovery_delay(attempt);
        match self.backoff {
            Backoff::RateLimited { delay, .. } => normal.max(delay),
            Backoff::Clear => normal,
        }
    }

    // MARK: - Reducer

    /// Applies `event` and returns the effects to run, in order. A refused
    /// event ([`Coordinator::step`]) runs nothing.
    pub fn reduce(&mut self, event: Event) -> Vec<Effect> {
        self.step(event).unwrap_or_default()
    }

    /// Applies `event` and returns the effects to run, in order; or the
    /// [`Refusal`] that names why `event` changes nothing. A refusal leaves
    /// the coordinator exactly as it was. Every event is one arm, and each
    /// arm decides every state it can meet: there is no default.
    pub fn step(&mut self, event: Event) -> Result<Vec<Effect>, Refusal> {
        let mut fx = Vec::new();
        // An answer must be for the run, flow, read or loop that is waiting
        // for it: a late one must not end or steer the one that replaced it.
        self.check_answer(&event)?;
        match event {
            Event::Restore(trigger) => self.on_restore(trigger, &mut fx)?,
            Event::TokensProbed { ticket, probe, storage_was_available, read_failed } => {
                self.on_tokens_probed(ticket, probe, storage_was_available, read_failed, &mut fx);
            }
            Event::TokenStorageAvailability { ticket, available } => {
                if ticket.generation != self.generations.session || !available {
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
                    if ticket.generation == self.generations.session {
                        self.preserve_cached_session(&mut fx);
                    }
                    self.finish_restore(&mut fx);
                } else if ticket.generation != self.generations.session {
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
                if ticket.generation == self.generations.session
                    && self.generations.store_write_high_water == ticket.store_write_high_water
                {
                    self.clear_auth_state(&reason, true, false, &mut fx);
                }
                self.finish_restore(&mut fx);
            }
            Event::AutoLoginFinished { ticket, result } => match result {
                Ok(()) | Err(AuthFailure::Cancelled) => self.finish_restore(&mut fx),
                Err(
                    AuthFailure::TimedOut
                    | AuthFailure::Offline
                    | AuthFailure::Unauthorized
                    | AuthFailure::InvalidCode
                    | AuthFailure::RateLimited { .. }
                    | AuthFailure::NetworkError
                    | AuthFailure::Other,
                ) => self.clear_stale_session(ticket, false, "auto-login failed", &mut fx),
            },
            Event::SignInRequested { kind, sets_loading } => {
                self.on_sign_in_requested(kind, sets_loading, &mut fx);
            }
            Event::TokenWorkQuiesced { flow, result } => {
                self.on_token_work_quiesced(flow, result, &mut fx);
            }
            Event::OnlineChecked { flow, online } => {
                if !self.flow_is_current(flow) {
                    self.fail_sign_in(flow, AuthFailure::Cancelled, false, &mut fx);
                } else if !online {
                    self.fail_sign_in(flow, AuthFailure::Offline, false, &mut fx);
                } else {
                    if flow.sets_loading {
                        self.set_loading(Loading::Busy, &mut fx);
                    }
                    if let Some((phase, budget)) = flow.kind.exchange() {
                        fx.push(Effect::RunExchange { flow, phase, budget });
                    }
                }
            }
            Event::ExchangeFinished { flow, result } => match result {
                Err(failure) => self.fail_sign_in(flow, failure, flow.sets_loading, &mut fx),
                Ok(()) => {
                    self.generations.store_write_high_water =
                        self.generations.store_write_high_water.max(flow.attempt);
                    fx.push(Effect::RecordLatestSignInRefreshToken);
                    self.complete_sign_in(flow, &mut fx);
                }
            },
            Event::SignInUserFetched { flow, result } => match result {
                Err(failure) => self.fail_sign_in(flow, failure, flow.sets_loading, &mut fx),
                Ok(None) => {
                    self.fail_sign_in(flow, AuthFailure::Unauthorized, flow.sets_loading, &mut fx);
                }
                Ok(Some(_)) if flow.generation != self.generations.session => {
                    self.fail_sign_in(flow, AuthFailure::Cancelled, flow.sets_loading, &mut fx);
                }
                Ok(Some(user)) => {
                    self.apply_signed_in_user(user, true, AfterTeams::SignIn(flow), &mut fx);
                }
            },
            Event::TeamsRequested => {
                let generation = self.generations.session;
                self.begin_team_refresh(generation, false, AfterTeams::Nothing, &mut fx);
            }
            Event::TeamsRefreshed { ticket, result } => {
                self.on_teams_refreshed(ticket, result, &mut fx);
            }
            Event::PostSignInHookFinished { ticket } => {
                self.after_teams(ticket.generation, ticket.after, &mut fx);
            }
            Event::TeamScopeRecoveryDue { id } => self.on_recovery_due(id, &mut fx),
            Event::TeamScopeRecoveryCheckFinished { id } => match self.recovery {
                RecoveryLoop::Sleeping { attempt, .. } => {
                    fx.push(Effect::SleepTeamScopeRecovery {
                        id,
                        delay: self.team_scope_recovery_wait(attempt),
                    });
                }
                RecoveryLoop::Idle => return Err(Refusal::StaleRecovery),
            },
            Event::SetSelectedTeam(team_id) => {
                if team_id == self.selected_team_id {
                    return Err(Refusal::AlreadySelected);
                }
                self.set_selected_team(team_id, &mut fx);
            }
            Event::TeamSelectionMutated => {
                self.generations.team_mutation = self.generations.team_mutation.wrapping_add(1);
            }
            Event::TeamListMutated => {
                self.generations.team_list = self.generations.team_list.wrapping_add(1);
            }
            Event::SendCodeStarted => self.set_loading(Loading::Busy, &mut fx),
            Event::SendCodeFinished { sent } => {
                if sent {
                    self.pending_code = PendingCode::Sent;
                }
                self.set_loading(Loading::Idle, &mut fx);
            }
            Event::DebugCredentialsRemembered => {
                self.debug_credentials = DebugCredentials::Remembered;
            }
            Event::SignOutRequested => self.on_sign_out_requested(&mut fx),
            Event::SignOutLocalCleared { sign_out_epoch } => {
                self.on_sign_out_local_cleared(sign_out_epoch, &mut fx);
            }
            Event::TokenReadUnauthorized(kind) => {
                if self.session_token_transition_is_active() {
                    fx.push(Effect::FailTokenRead(AuthFailure::NetworkError));
                } else if kind == TokenReadKind::AccessToken
                    && self.launch.debug_build
                    && self.launch.includes_dev_auth
                    && self.debug_credentials == DebugCredentials::Remembered
                {
                    fx.push(Effect::TryDevAuthAccessToken);
                } else {
                    self.fail_token_read_unauthorized(kind, &mut fx);
                }
            }
            Event::DevAuthAccessTokenFinished { got_token } => {
                if got_token {
                    return Err(Refusal::NothingToDo);
                }
                self.fail_token_read_unauthorized(TokenReadKind::AccessToken, &mut fx);
            }
        }
        Ok(fx)
    }

    /// Refuses an answer whose ticket is not the one waited for. Requests
    /// carry no ticket and pass.
    fn check_answer(&self, event: &Event) -> Result<(), Refusal> {
        match event {
            Event::TokensProbed { ticket, .. }
            | Event::TokenStorageAvailability { ticket, .. }
            | Event::ProbeRetryDue { ticket, .. }
            | Event::CachedSessionValidated { ticket, .. }
            | Event::SurvivingRefreshTokenRead { ticket, .. }
            | Event::StaleSessionCleared { ticket, .. }
            | Event::AutoLoginFinished { ticket, .. } => match self.restore {
                Restore::Running { id } if id == ticket.id => Ok(()),
                Restore::Running { .. } | Restore::Idle => Err(Refusal::StaleRestore),
            },
            Event::TokenWorkQuiesced { flow, .. }
            | Event::OnlineChecked { flow, .. }
            | Event::ExchangeFinished { flow, .. }
            | Event::SignInUserFetched { flow, .. } => {
                if self.flow_is_active(*flow) {
                    Ok(())
                } else {
                    Err(Refusal::InactiveSignInFlow)
                }
            }
            Event::TeamsRefreshed { ticket, .. } => {
                if self.pending_team_reads.contains(&ticket.id) {
                    Ok(())
                } else {
                    Err(Refusal::UnknownTeamRead)
                }
            }
            Event::PostSignInHookFinished { ticket } => {
                if self.hook_owner_is_active(ticket.after) {
                    Ok(())
                } else {
                    Err(Refusal::HookOwnerGone)
                }
            }
            Event::TeamScopeRecoveryDue { id } | Event::TeamScopeRecoveryCheckFinished { id } => {
                match self.recovery {
                    RecoveryLoop::Sleeping { id: sleeping, .. } if sleeping == *id => Ok(()),
                    RecoveryLoop::Sleeping { .. } | RecoveryLoop::Idle => {
                        Err(Refusal::StaleRecovery)
                    }
                }
            }
            Event::SignOutLocalCleared { sign_out_epoch } => {
                if self.pending_sign_out_captures.contains(sign_out_epoch) {
                    Ok(())
                } else {
                    Err(Refusal::UnknownSignOutCapture)
                }
            }
            Event::Restore(_)
            | Event::SignInRequested { .. }
            | Event::TeamsRequested
            | Event::SetSelectedTeam(_)
            | Event::TeamSelectionMutated
            | Event::TeamListMutated
            | Event::SendCodeStarted
            | Event::SendCodeFinished { .. }
            | Event::DebugCredentialsRemembered
            | Event::SignOutRequested
            | Event::TokenReadUnauthorized(_)
            | Event::DevAuthAccessTokenFinished { .. } => Ok(()),
        }
    }

    pub(super) fn set_loading(&mut self, loading: Loading, fx: &mut Vec<Effect>) {
        self.loading = loading;
        fx.push(Effect::SetLoading(loading == Loading::Busy));
    }
}
