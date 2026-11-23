//! Priming from launch inputs and restoring a saved session.

use super::Coordinator;
use super::state::{Backoff, DebugCredentials, Restore, Session, Teams, TokenCache};
use crate::event::{
    AfterTeams, AuthFailure, AutoLoginSource, Effect, RestoreTicket, RestoreTrigger,
};
use crate::machine::Refusal;
use crate::model::{AuthState, AuthUser, PrimeInputs, should_start_auto_login};
use crate::phase::FAILED_TOKEN_READ_RETRY_DELAYS;

impl Coordinator {
    // MARK: - Priming

    pub(super) fn prime(&mut self, fx: &mut Vec<Effect>) {
        if self.launch.clear_auth_requested {
            self.clear_auth_state("launch asked to clear auth", false, false, fx);
            if self.launch.includes_dev_auth {
                self.debug_credentials = DebugCredentials::None;
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
            has_tokens: fixture.is_some() || self.token_cache == TokenCache::Stored,
            cached_user: if fixture.is_some() { fixture.clone() } else { self.cached_user.clone() },
            fixture_user: fixture,
            has_auto_login_credentials: auto_login,
            mock_user: AuthUser::ui_test_mock(),
        });
        self.apply(state, fx);
    }

    // MARK: - Restore

    pub(super) fn on_restore(
        &mut self,
        trigger: RestoreTrigger,
        fx: &mut Vec<Effect>,
    ) -> Result<(), Refusal> {
        match trigger {
            RestoreTrigger::Launch => {
                if self.launch.should_clear_stored_session_before_priming() {
                    fx.push(Effect::ClearLocalSession);
                    // The clear runs even when the restore does not.
                    let _ = self.check_existing_session(fx);
                    return Ok(());
                }
            }
            RestoreTrigger::Foreground => {
                if !(self.is_authenticated()
                    || self.is_restoring_session()
                    || self.token_cache == TokenCache::Stored)
                {
                    return Err(Refusal::NothingToRestore);
                }
            }
            RestoreTrigger::TeamScopeSignal => {
                if !self.needs_team_scope_recovery() {
                    return Err(Refusal::TeamScopeNotNeeded);
                }
                match self.backoff {
                    Backoff::Clear => {}
                    Backoff::RateLimited { .. } => return Err(Refusal::RateLimited),
                }
            }
        }
        self.check_existing_session(fx)
    }

    pub(super) fn check_existing_session(&mut self, fx: &mut Vec<Effect>) -> Result<(), Refusal> {
        if self.launch.clear_auth_requested {
            return Err(Refusal::AuthClearRequested);
        }
        match self.restore {
            Restore::Running { .. } => {
                fx.push(Effect::JoinRestore);
                return Ok(());
            }
            Restore::Idle => {}
        }
        self.generations.restore = self.generations.restore.wrapping_add(1);
        let id = self.generations.restore;
        self.restore = Restore::Running { id };
        fx.push(Effect::ProbeStoredTokens(RestoreTicket {
            id,
            generation: self.generations.session,
            store_write_high_water: self.generations.store_write_high_water,
            retry_on_storage_available: true,
            failed_read_retries: 0,
        }));
        Ok(())
    }

    pub(super) fn on_tokens_probed(
        &mut self,
        ticket: RestoreTicket,
        probe: Result<bool, AuthFailure>,
        storage_was_available: bool,
        read_failed: bool,
        fx: &mut Vec<Effect>,
    ) {
        let stale = ticket.generation != self.generations.session;
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
            let restoring = self.is_restoring_session();
            self.set_session(Session::from_parts(Some(fixture), true, restoring), fx);
            if self.launch.fixture_teams_requested {
                let after = AfterTeams::Restore { id: ticket.id };
                return self.begin_team_refresh(ticket.generation, false, after, fx);
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
            // Show the cached user while the stored tokens validate.
            if self.session.user().is_none()
                && let Some(cached) = cached_user
            {
                self.session = Session::from_parts(
                    Some(cached),
                    self.is_authenticated(),
                    self.is_restoring_session(),
                );
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
        let has_cached_session = cached_user.is_some() || self.token_cache == TokenCache::Stored;
        if has_cached_session && read_failed {
            if let Some(delay) = FAILED_TOKEN_READ_RETRY_DELAYS.get(ticket.failed_read_retries) {
                fx.push(Effect::RetryProbeAfter { ticket, delay: *delay });
                return;
            }
            self.preserve_cached_session(fx);
            return self.finish_restore(fx);
        }
        if self.launch.includes_dev_auth && self.debug_credentials == DebugCredentials::Remembered {
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

    pub(super) fn on_cached_session_validated(
        &mut self,
        ticket: RestoreTicket,
        result: Result<Option<AuthUser>, AuthFailure>,
        fx: &mut Vec<Effect>,
    ) {
        if ticket.generation != self.generations.session {
            return self.finish_restore(fx);
        }
        match result {
            Ok(Some(user)) => {
                let after = AfterTeams::Restore { id: ticket.id };
                self.apply_signed_in_user(user, false, after, fx);
            }
            Ok(None) => fx.push(Effect::ReadSurvivingRefreshToken { ticket, after_error: None }),
            Err(AuthFailure::Cancelled) => self.finish_restore(fx),
            Err(AuthFailure::TimedOut) => {
                self.preserve_cached_session(fx);
                self.finish_restore(fx);
            }
            Err(failure) => {
                fx.push(Effect::ReadSurvivingRefreshToken { ticket, after_error: Some(failure) });
            }
        }
    }

    pub(super) fn on_surviving_refresh_token(
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
        if ticket.generation != self.generations.session {
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
    pub(super) fn clear_stale_session(
        &mut self,
        ticket: RestoreTicket,
        compare_refresh_token: bool,
        reason: &str,
        fx: &mut Vec<Effect>,
    ) {
        if self.generations.store_write_high_water != ticket.store_write_high_water {
            return self.finish_restore(fx);
        }
        fx.push(Effect::ClearStaleSession {
            ticket,
            compare_refresh_token,
            reason: reason.to_owned(),
        });
    }

    pub(super) fn finish_restore(&mut self, fx: &mut Vec<Effect>) {
        match self.teams {
            Teams::Loaded { .. } => self.cancel_team_scope_recovery(fx),
            Teams::Unloaded => {}
        }
        self.restore = Restore::Idle;
        fx.push(Effect::RestoreFinished);
    }

    pub(super) fn preserve_cached_session(&mut self, fx: &mut Vec<Effect>) {
        self.set_has_tokens(fx);
        let user = self.session.user().cloned().or_else(|| self.cached_user.clone());
        let session = match user {
            Some(user) => Session::SignedIn { user },
            None => Session::SignedOut { shown: None },
        };
        self.set_session(session, fx);
        self.schedule_team_scope_recovery(fx);
    }
}
