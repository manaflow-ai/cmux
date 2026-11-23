//! Local-first sign-out: Swift `AuthCoordinatorTests` (sign-out),
//! `AuthCoordinatorSignOutOfflineTests` and the sign-out ownership cases.

mod common;

use cmux_auth_coordinator::{
    AuthPhase, Effect, Event, LaunchOptions, Persisted, SIGN_OUT_CLEARED_PHASES, SignInKind,
};
use common::{Driver, teams};

#[test]
fn sign_out_runs_local_first_in_order() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let generation = d.c.session_generation();
    let revision = d.c.sign_out_revision();
    d.clear_log();

    let fx = d.send(Event::SignOutRequested);
    assert_eq!(fx[0], Effect::CancelInFlightWork { runs: vec![] });
    assert_eq!(fx[1], Effect::NotifySessionWillTransition);
    assert!(fx.contains(&Effect::PublishSessionIdentity(None)));
    assert!(fx.contains(&Effect::PublishTeamScope(None)));
    assert_eq!(
        fx.last(),
        Some(&Effect::CaptureTeardownCredentialsAndClearLocalSession {
            sign_out_epoch: revision + 1
        })
    );
    assert_eq!(d.c.sign_out_revision(), revision + 1);
    // The flag flips only when the local clear lands, but the identity is gone at once.
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.published_session_identity(), None);
    assert!(d.c.session_token_transition_is_active());

    let fx = d.local_cleared();
    assert_eq!(fx[0], Effect::EndSignOutCredentialCapture);
    let tail: Vec<_> = fx.iter().rev().take(2).cloned().collect();
    assert_eq!(tail, vec![Effect::ServerTeardown, Effect::WaitForPostSignInHooks { runs: vec![] }]);
    assert!(!d.c.is_authenticated());
    assert!(d.c.available_teams().is_empty());
    assert_eq!(d.c.selected_team_id(), None);
    assert!(fx.contains(&Effect::PersistSelectedTeam(None)));
    assert!(fx.contains(&Effect::ClearCachedUser));
    assert!(fx.contains(&Effect::ClearSessionCache));
    assert!(fx.contains(&Effect::DropPendingCode));
    assert_eq!(d.c.last_sign_out_reason(), Some("signed out by the person"));
    assert_eq!(d.c.session_generation(), generation + 2);
    assert!(!d.c.session_token_transition_is_active());
}

#[test]
fn sign_out_announces_one_session_transition() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    d.clear_log();
    d.sign_out();
    assert_eq!(d.count(&Effect::NotifySessionWillTransition), 1);
    assert_eq!(d.sign_out_reasons(), vec!["signed out by the person".to_owned()]);
}

#[test]
fn sign_out_forgets_debug_credentials_in_dev_builds() {
    let mut d = Driver::new(
        LaunchOptions { includes_dev_auth: true, ..LaunchOptions::default() },
        Persisted::default(),
    );
    d.send(Event::DebugCredentialsRemembered);
    let fx = d.sign_out();
    assert!(fx.contains(&Effect::ForgetDebugCredentials));

    let mut plain = Driver::signed_out();
    assert!(!plain.sign_out().contains(&Effect::ForgetDebugCredentials));
}

#[test]
fn sign_out_invalidates_a_parked_sign_ins_ownership_of_token_reads() {
    let mut d = Driver::signed_out();
    d.begin_sign_in(SignInKind::Password);
    assert!(d.c.session_token_transition_is_active());
    d.sign_out();
    assert!(!d.c.session_token_transition_is_active());
}

#[test]
fn sign_out_clears_the_interactive_phases_from_the_damper() {
    assert_eq!(
        SIGN_OUT_CLEARED_PHASES,
        &[
            AuthPhase::SendCode,
            AuthPhase::VerifyCode,
            AuthPhase::PasswordSignIn,
            AuthPhase::Oauth,
            AuthPhase::ValidateSession,
        ]
    );
}
