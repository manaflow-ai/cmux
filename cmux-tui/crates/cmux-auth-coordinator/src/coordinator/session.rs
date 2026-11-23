//! Sign-out and the state helpers every flow shares.

use super::Coordinator;
use super::state::{DebugCredentials, PendingCode, Session, Teams, TokenCache};
use crate::event::{AuthFailure, Effect, TokenReadKind};
use crate::model::{AuthState, AuthUser};
use crate::phase::PhaseRunner;

impl Coordinator {
    // MARK: - Sign-out

    pub(super) fn on_sign_out_requested(&mut self, fx: &mut Vec<Effect>) {
        self.cancel_runs_for_sign_out(fx);
        self.advance_session_generation(true, fx);
        self.generations.sign_out_epoch = self.generations.sign_out_epoch.wrapping_add(1);
        self.pending_sign_out_captures.insert(self.generations.sign_out_epoch);
        self.publish_session_identity(fx);
        fx.push(Effect::CaptureTeardownCredentialsAndClearLocalSession {
            sign_out_epoch: self.generations.sign_out_epoch,
        });
    }

    pub(super) fn on_sign_out_local_cleared(&mut self, sign_out_epoch: u64, fx: &mut Vec<Effect>) {
        // Each capture is answered once (`step` refused a repeated answer, or
        // one for a capture never started): it must not clear a session
        // signed in since.
        self.pending_sign_out_captures.remove(&sign_out_epoch);
        if sign_out_epoch != self.generations.sign_out_epoch {
            // A newer sign-out began after this one captured: that one owns
            // the local clear (and keeps the capture open until it answers).
            // Only this capture's own server teardown still runs.
            if self.pending_sign_out_captures.is_empty() {
                fx.push(Effect::EndSignOutCredentialCapture);
            }
            fx.push(Effect::WaitForPostSignInHooks {
                runs: self.live_runs(&[PhaseRunner::PostSignIn]),
            });
            fx.push(Effect::ServerTeardown);
            return;
        }
        if self.pending_sign_out_captures.is_empty() {
            fx.push(Effect::EndSignOutCredentialCapture);
        }
        if self.launch.includes_dev_auth {
            self.debug_credentials = DebugCredentials::None;
            fx.push(Effect::ForgetDebugCredentials);
        }
        self.clear_auth_state("signed out by the person", false, true, fx);
        fx.push(Effect::WaitForPostSignInHooks {
            runs: self.live_runs(&[PhaseRunner::PostSignIn]),
        });
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
            self.pending_code = PendingCode::None;
            fx.push(Effect::DropPendingCode);
        }
        self.cached_user = None;
        fx.push(Effect::ClearCachedUser);
        self.token_cache = TokenCache::Empty;
        fx.push(Effect::ClearSessionCache);
        self.teams = Teams::Unloaded;
        self.publish_team_scope(fx);
        self.set_selected_team(None, fx);
        self.apply(AuthState::cleared(), fx);
    }

    pub(super) fn advance_session_generation(&mut self, notify: bool, fx: &mut Vec<Effect>) {
        if notify {
            fx.push(Effect::NotifySessionWillTransition);
        }
        self.generations.session = self.generations.session.wrapping_add(1);
        // A new generation's list has not loaded.
        self.teams = Teams::Unloaded;
        self.publish_team_scope(fx);
    }

    pub(super) fn apply(&mut self, state: AuthState, fx: &mut Vec<Effect>) {
        self.set_session(Session::from_state(state), fx);
    }

    pub(super) fn set_session(&mut self, session: Session, fx: &mut Vec<Effect>) {
        self.session = session;
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
        self.generations.team_scope = self.generations.team_scope.wrapping_add(1);
        let scope = self.team_scope();
        self.last_published_team_scope = scope.clone();
        fx.push(Effect::PublishTeamScope(scope));
    }

    pub(super) fn save_cached_user(&mut self, user: AuthUser, fx: &mut Vec<Effect>) {
        self.cached_user = Some(user.clone());
        fx.push(Effect::SaveCachedUser(user));
    }

    pub(super) fn set_has_tokens(&mut self, fx: &mut Vec<Effect>) {
        self.token_cache = TokenCache::Stored;
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
