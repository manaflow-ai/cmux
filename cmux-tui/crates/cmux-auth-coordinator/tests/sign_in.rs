//! Sign-in flows: Swift `AuthCoordinatorTests` (sign-in), the stale-completion
//! cases of `AuthCoordinatorStaleClearTests`, and the token-read ownership cases.

mod common;

use cmux_auth_coordinator::{
    AuthFailure, AuthPhase, Effect, Event, LaunchOptions, Persisted, PhaseBudget, RestoreTrigger,
    SignInKind, TokenReadKind,
};
use common::{Driver, hook_ticket, refresh_ticket, sign_in_failure, teams, user};

#[test]
fn a_password_sign_in_authenticates_caches_and_runs_the_hook_once() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Password);
    assert_eq!(flow.attempt, 1);
    assert_eq!(flow.generation, 0);
    assert_eq!(
        d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) }),
        vec![Effect::CheckOnline(flow)]
    );
    assert_eq!(
        d.send(Event::OnlineChecked { flow, online: true }),
        vec![
            Effect::SetLoading(true),
            Effect::RunExchange {
                flow,
                phase: AuthPhase::PasswordSignIn,
                budget: PhaseBudget::Network,
            },
        ]
    );
    assert!(d.c.is_loading());
    assert_eq!(
        d.send(Event::ExchangeFinished { flow, result: Ok(()) }),
        vec![Effect::RecordLatestSignInRefreshToken, Effect::FetchUser(flow)]
    );
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
    assert!(fx.contains(&Effect::NotifySessionWillTransition));
    assert!(fx.contains(&Effect::SaveCachedUser(user("u1"))));
    assert!(fx.contains(&Effect::SetHasTokens));
    assert_eq!(d.c.session_generation(), 1);
    assert!(d.c.is_authenticated());
    // Still loading until the teams and the hook are done.
    assert!(d.c.is_loading());

    let ticket = refresh_ticket(&fx).unwrap();
    assert!(ticket.runs_post_sign_in_hook);
    let fx = d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&["t1"])) });
    assert_eq!(hook_ticket(&fx), Some(ticket));
    let fx = d.send(Event::PostSignInHookFinished { ticket });
    assert_eq!(fx.last(), Some(&Effect::SignInSucceeded(flow)));
    assert!(fx.contains(&Effect::SetLoading(false)));
    assert!(!d.c.is_loading());
    assert_eq!(d.c.session_identity().map(|id| id.generation), Some(1));
}

#[test]
fn oauth_uses_the_interactive_deadline() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Oauth);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    let fx = d.send(Event::OnlineChecked { flow, online: true });
    assert!(fx.contains(&Effect::RunExchange {
        flow,
        phase: AuthPhase::Oauth,
        budget: PhaseBudget::Interactive,
    }));
}

#[test]
fn a_code_needs_a_sent_nonce_and_a_verified_code_drops_it() {
    let mut d = Driver::signed_out();
    let fx = d.send(Event::SignInRequested { kind: SignInKind::VerifyCode, sets_loading: true });
    assert_eq!(fx, vec![Effect::SignInFailed { flow: None, failure: AuthFailure::InvalidCode }]);

    d.send(Event::SendCodeStarted);
    assert!(d.c.is_loading());
    d.send(Event::SendCodeFinished { sent: true });
    assert!(!d.c.is_loading());
    let (flow, _) = d.sign_in_through_exchange(SignInKind::VerifyCode);
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
    let ticket = refresh_ticket(&fx).unwrap();
    d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&[])) });
    let fx = d.send(Event::PostSignInHookFinished { ticket });
    assert!(fx.contains(&Effect::DropPendingCode));
    assert!(!d.c.has_pending_code());
}

#[test]
fn a_failed_code_keeps_the_nonce() {
    let mut d = Driver::signed_out();
    d.send(Event::SendCodeFinished { sent: true });
    let flow = d.begin_sign_in(SignInKind::VerifyCode);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    d.send(Event::OnlineChecked { flow, online: true });
    let fx = d.send(Event::ExchangeFinished { flow, result: Err(AuthFailure::Unauthorized) });
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Unauthorized));
    assert!(d.c.has_pending_code());
    assert!(!d.c.is_loading());
}

#[test]
fn offline_fails_fast_without_a_spinner() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    let fx = d.send(Event::OnlineChecked { flow, online: false });
    assert!(!fx.contains(&Effect::SetLoading(true)));
    assert!(!fx.contains(&Effect::SetLoading(false)));
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Offline));
    assert!(!d.c.session_token_transition_is_active());
}

#[test]
fn a_sign_in_that_does_not_set_loading_never_touches_the_spinner() {
    let mut d = Driver::signed_out();
    let fx = d.send(Event::SignInRequested { kind: SignInKind::Password, sets_loading: false });
    let Some(Effect::QuiesceTokenWork { flow, .. }) = fx.first().cloned() else {
        panic!("expected a quiesce");
    };
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    let fx = d.send(Event::OnlineChecked { flow, online: true });
    assert!(!fx.contains(&Effect::SetLoading(true)));
    let fx = d.send(Event::ExchangeFinished { flow, result: Err(AuthFailure::NetworkError) });
    assert!(!fx.contains(&Effect::SetLoading(false)));
}

#[test]
fn a_sign_out_during_token_quiescing_cancels_the_sign_in() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Password);
    d.sign_out();
    let fx = d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    assert_eq!(
        fx,
        vec![Effect::SignInFailed { flow: Some(flow), failure: AuthFailure::Cancelled }]
    );
}

#[test]
fn an_exchange_resuming_inside_sign_out_rolls_back_its_tokens() {
    let mut d = Driver::cached("u1");
    let flow = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    d.send(Event::OnlineChecked { flow, online: true });
    // Sign-out begins; the published flag still reads signed in.
    d.send(Event::SignOutRequested);
    assert!(d.c.is_authenticated());
    let fx = d.send(Event::ExchangeFinished { flow, result: Ok(()) });
    assert!(fx.contains(&Effect::ClearLocalSession), "{fx:?}");
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
}

#[test]
fn a_newer_attempts_write_blocks_an_older_ones_rollback() {
    let mut d = Driver::signed_out();
    let old = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow: old, result: Ok(()) });
    d.send(Event::OnlineChecked { flow: old, online: true });
    d.send(Event::SignOutRequested);
    d.local_cleared();
    // A newer attempt writes the store first.
    let (newer, _) = d.sign_in_through_exchange(SignInKind::Password);
    assert!(newer.attempt > old.attempt);
    let fx = d.send(Event::ExchangeFinished { flow: old, result: Ok(()) });
    assert!(!fx.contains(&Effect::ClearLocalSession), "{fx:?}");
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
}

#[test]
fn a_user_fetch_landing_after_sign_out_is_dropped() {
    let mut d = Driver::signed_out();
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    d.sign_out();
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
    assert!(!d.c.is_authenticated());
}

#[test]
fn a_missing_user_after_the_exchange_is_unauthorized() {
    let mut d = Driver::signed_out();
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(None) });
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Unauthorized));
}

#[test]
fn an_external_sign_in_skips_the_online_check_and_records_the_seeded_token() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::External);
    let fx = d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    assert_eq!(
        fx,
        vec![
            Effect::SetLoading(true),
            Effect::ClearExternalSignInFailureDetail,
            Effect::RecordLatestSignInRefreshToken,
            Effect::FetchUser(flow),
        ]
    );
    let fx = d.send(Event::SignInUserFetched { flow, result: Err(AuthFailure::Unauthorized) });
    assert!(fx.contains(&Effect::SetLoading(false)));
    assert!(!d.c.is_authenticated());
}

#[test]
fn every_sign_in_advances_the_generation_but_revalidation_of_the_same_account_does_not() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let first = d.c.session_generation();
    d.sign_in("u1", Ok(teams(&["t1"])));
    assert_eq!(d.c.session_generation(), first + 1);

    d.clear_log();
    let ticket = d.start_restore(RestoreTrigger::Foreground);
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u1"))) });
    let teams_ticket = refresh_ticket(&fx).unwrap();
    assert!(!teams_ticket.runs_post_sign_in_hook);
    d.send(Event::TeamsRefreshed { ticket: teams_ticket, result: Ok(teams(&["t1"])) });
    assert_eq!(d.c.session_generation(), first + 1);
    assert_eq!(d.count(&Effect::NotifySessionWillTransition), 0);

    // A different account on revalidation is a transition and runs the hook.
    let ticket = d.start_restore(RestoreTrigger::Foreground);
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u2"))) });
    assert!(refresh_ticket(&fx).unwrap().runs_post_sign_in_hook);
    assert_eq!(d.c.session_generation(), first + 2);
}

#[test]
fn an_empty_account_id_never_publishes_an_identity() {
    let mut d = Driver::signed_out();
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user(""))) });
    assert!(d.c.is_authenticated());
    assert!(fx.contains(&Effect::PublishSessionIdentity(None)));
    assert_eq!(d.c.published_session_identity(), None);
}

#[test]
fn token_reads_during_a_sign_in_are_transient() {
    let mut d = Driver::cached("u1");
    let flow = d.begin_sign_in(SignInKind::Password);
    assert!(d.c.session_token_transition_is_active());
    assert_eq!(d.c.session_identity(), None);
    let fx = d.send(Event::TokenReadUnauthorized(TokenReadKind::AccessToken));
    assert_eq!(fx, vec![Effect::FailTokenRead(AuthFailure::NetworkError)]);
    assert!(d.c.is_authenticated());

    // Once the flow ends, the same read signs out.
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    d.send(Event::OnlineChecked { flow, online: false });
    assert!(!d.c.session_token_transition_is_active());
    let fx = d.send(Event::TokenReadUnauthorized(TokenReadKind::ForceRefreshAccessToken));
    assert_eq!(fx.last(), Some(&Effect::FailTokenRead(AuthFailure::Unauthorized)));
    assert_eq!(
        d.c.last_sign_out_reason(),
        Some("forced token refresh failed and no refresh token survives")
    );
}

#[test]
fn token_reads_during_a_restore_are_transient() {
    let mut d = Driver::cached("u1");
    d.start_restore(RestoreTrigger::Launch);
    let fx = d.send(Event::TokenReadUnauthorized(TokenReadKind::AccessToken));
    assert_eq!(fx, vec![Effect::FailTokenRead(AuthFailure::NetworkError)]);
}

#[test]
fn a_definitive_access_token_failure_routes_to_sign_in() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let fx = d.send(Event::TokenReadUnauthorized(TokenReadKind::AccessToken));
    assert_eq!(fx.last(), Some(&Effect::FailTokenRead(AuthFailure::Unauthorized)));
    assert!(!d.c.is_authenticated());
    assert_eq!(
        d.c.last_sign_out_reason(),
        Some("access token unavailable and no refresh token survives")
    );
}

#[test]
fn a_debug_build_tries_its_remembered_credentials_before_signing_out() {
    let mut d = Driver::new(
        LaunchOptions { debug_build: true, includes_dev_auth: true, ..LaunchOptions::default() },
        Persisted::default(),
    );
    d.sign_in("u1", Ok(teams(&["t1"])));
    d.send(Event::DebugCredentialsRemembered);
    assert_eq!(
        d.send(Event::TokenReadUnauthorized(TokenReadKind::AccessToken)),
        vec![Effect::TryDevAuthAccessToken]
    );
    assert!(d.send(Event::DevAuthAccessTokenFinished { got_token: true }).is_empty());
    // The forced refresh has no fallback.
    let fx = d.send(Event::TokenReadUnauthorized(TokenReadKind::ForceRefreshAccessToken));
    assert_eq!(fx.last(), Some(&Effect::FailTokenRead(AuthFailure::Unauthorized)));
}
