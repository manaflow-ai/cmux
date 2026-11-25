//! Sign-in flows: the code exchange, the dev shortcut and their outcomes.

use super::Coordinator;
use super::state::{Loading, PendingCode, Session};
use crate::event::{AfterTeams, AuthFailure, Effect, SignInFlow, SignInKind};
use crate::model::AuthUser;

impl Coordinator {
    // MARK: - Sign-in

    pub(super) fn on_sign_in_requested(
        &mut self,
        kind: SignInKind,
        sets_loading: bool,
        fx: &mut Vec<Effect>,
    ) {
        if kind == SignInKind::VerifyCode && self.pending_code == PendingCode::None {
            fx.push(Effect::SignInFailed { flow: None, failure: AuthFailure::InvalidCode });
            return;
        }
        self.generations.sign_in_attempt = self.generations.sign_in_attempt.wrapping_add(1);
        let flow = SignInFlow {
            generation: self.generations.session,
            attempt: self.generations.sign_in_attempt,
            sign_out_epoch: self.generations.sign_out_epoch,
            kind,
            sets_loading,
        };
        self.active_sign_in_flows.insert(flow.attempt, flow);
        fx.push(Effect::QuiesceTokenWork(flow));
    }

    pub(super) fn on_token_work_quiesced(
        &mut self,
        flow: SignInFlow,
        result: Result<(), AuthFailure>,
        fx: &mut Vec<Effect>,
    ) {
        let current = self.flow_is_current(flow);
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
            self.set_loading(Loading::Busy, fx);
            fx.push(Effect::ClearExternalSignInFailureDetail);
            return self.complete_sign_in(flow, fx);
        }
        fx.push(Effect::CheckOnline(flow));
    }

    /// Whether `flow` is still registered exactly as it began: a finished or
    /// failed flow is not, nor one whose fields differ from the registered one.
    pub(super) fn flow_is_active(&self, flow: SignInFlow) -> bool {
        self.active_sign_in_flows.get(&flow.attempt) == Some(&flow)
    }

    /// Whether no sign-out or newer session has landed since `flow` began.
    pub(super) fn flow_is_current(&self, flow: SignInFlow) -> bool {
        flow.generation == self.generations.session
            && flow.sign_out_epoch == self.generations.sign_out_epoch
    }

    pub(super) fn complete_sign_in(&mut self, flow: SignInFlow, fx: &mut Vec<Effect>) {
        let high_water = &mut self.generations.store_write_high_water;
        if *high_water < flow.attempt {
            fx.push(Effect::RecordLatestSignInRefreshToken);
        }
        *high_water = (*high_water).max(flow.attempt);
        if flow.generation != self.generations.session {
            // A sign-out (or newer session) landed during the exchange. Roll
            // back the tokens it re-stored, unless a newer attempt owns the store.
            let sign_out_began = flow.sign_out_epoch != self.generations.sign_out_epoch;
            if (sign_out_began || !self.is_authenticated())
                && self.generations.store_write_high_water == flow.attempt
            {
                fx.push(Effect::ClearLocalSession);
            }
            return self.fail_sign_in(flow, AuthFailure::Cancelled, flow.sets_loading, fx);
        }
        fx.push(Effect::FetchUser(flow));
    }

    pub(super) fn fail_sign_in(
        &mut self,
        flow: SignInFlow,
        failure: AuthFailure,
        loading_was_set: bool,
        fx: &mut Vec<Effect>,
    ) {
        let loading_was_set = loading_was_set || flow.kind == SignInKind::External;
        if loading_was_set {
            self.set_loading(Loading::Idle, fx);
        }
        self.finish_sign_in_flow(flow, fx);
        fx.push(Effect::SignInFailed { flow: Some(flow), failure });
    }

    pub(super) fn finish_sign_in_flow(&mut self, flow: SignInFlow, fx: &mut Vec<Effect>) {
        self.active_sign_in_flows.remove(&flow.attempt);
        self.publish_session_identity(fx);
    }

    pub(super) fn succeed_sign_in(&mut self, flow: SignInFlow, fx: &mut Vec<Effect>) {
        if flow.sets_loading || flow.kind == SignInKind::External {
            self.set_loading(Loading::Idle, fx);
        }
        self.finish_sign_in_flow(flow, fx);
        if flow.kind == SignInKind::VerifyCode {
            self.pending_code = PendingCode::None;
            fx.push(Effect::DropPendingCode);
        }
        fx.push(Effect::SignInSucceeded(flow));
    }

    /// Publishes `user`. A completed exchange (`sign_in`) always advances the
    /// generation; a revalidation advances it only on an account change.
    pub(super) fn apply_signed_in_user(
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
            let transition = match &self.session {
                Session::SignedOut { .. } | Session::Restoring { .. } => true,
                Session::RestoringSignedIn { user: current }
                | Session::SignedIn { user: current } => current.id != user.id,
            };
            if transition {
                self.advance_session_generation(true, fx);
            }
            transition
        };
        let generation = self.generations.session;
        self.set_session(Session::SignedIn { user: user.clone() }, fx);
        self.save_cached_user(user, fx);
        self.set_has_tokens(fx);
        self.begin_team_refresh(generation, runs_hook, after, fx);
    }
}
