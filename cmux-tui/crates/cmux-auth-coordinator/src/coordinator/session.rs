//! Sign-out and the state helpers every flow shares.

use super::Coordinator;
use crate::event::{AuthFailure, Effect, TokenReadKind};
use crate::model::{AuthState, AuthUser};
use crate::phase::SIGN_OUT_CLEARED_PHASES;

impl Coordinator {
    // MARK: - Sign-out

    pub(super) fn on_sign_out_requested(&mut self, fx: &mut Vec<Effect>) {
        self.is_capturing_sign_out_credentials = true;
        fx.push(Effect::CancelInFlightWork);
        self.advance_session_generation(true, fx);
        self.sign_out_epoch = self.sign_out_epoch.wrapping_add(1);
        self.publish_session_identity(fx);
        fx.push(Effect::ClearPhaseDampers(SIGN_OUT_CLEARED_PHASES));
        fx.push(Effect::CaptureTeardownCredentialsAndClearLocalSession);
    }

    pub(super) fn on_sign_out_local_cleared(&mut self, fx: &mut Vec<Effect>) {
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

    pub(super) fn fail_token_read_unauthorized(
        &mut self,
        kind: TokenReadKind,
        fx: &mut Vec<Effect>,
    ) {
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
    pub(super) fn clear_auth_state(
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

    pub(super) fn advance_session_generation(&mut self, notify: bool, fx: &mut Vec<Effect>) {
        if notify {
            fx.push(Effect::NotifySessionWillTransition);
        }
        self.session_generation = self.session_generation.wrapping_add(1);
        self.authenticated_teams_session_generation = None;
        self.set_available_teams(Vec::new(), fx);
    }

    pub(super) fn apply(&mut self, state: AuthState, fx: &mut Vec<Effect>) {
        self.current_user = state.current_user;
        self.is_authenticated = state.is_authenticated;
        self.is_restoring_session = state.is_restoring_session;
        self.publish_session_identity(fx);
    }

    pub(super) fn publish_session_identity(&mut self, fx: &mut Vec<Effect>) {
        fx.push(Effect::PublishSessionIdentity(self.published_session_identity()));
        self.publish_team_scope(fx);
    }

    /// Publishes the team scope when its account or team changed, advancing
    /// its generation.
    pub(super) fn publish_team_scope(&mut self, fx: &mut Vec<Effect>) {
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

    pub(super) fn save_cached_user(&mut self, user: AuthUser, fx: &mut Vec<Effect>) {
        self.cached_user = Some(user.clone());
        fx.push(Effect::SaveCachedUser(user));
    }

    pub(super) fn set_has_tokens(&mut self, fx: &mut Vec<Effect>) {
        self.has_tokens = true;
        fx.push(Effect::SetHasTokens);
    }

    /// A uniform draw in [0, 1) from a xorshift generator.
    pub(super) fn next_unit(&mut self) -> f64 {
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng = x;
        (x >> 11) as f64 / (1u64 << 53) as f64
    }
}
