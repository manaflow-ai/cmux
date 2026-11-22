//! Phase routing and the timed-out-phase damper: Swift `AuthPhase`,
//! `AuthCoordinator.runPhase`, `AuthPhaseTimeoutRegistry` and the damper cases
//! of `AuthCoordinatorTimeoutTests`.

use std::time::Duration;

use cmux_auth_coordinator::{AuthPhase, PhaseDamper, PhaseRunner, SignInKind, TIMED_OUT_RESET};

const SECOND: u64 = 1_000_000_000;

#[test]
fn phase_labels_match_the_swift_raw_values() {
    let labels = [
        (AuthPhase::SendCode, "send_code"),
        (AuthPhase::VerifyCode, "verify_code"),
        (AuthPhase::PasswordSignIn, "password_sign_in"),
        (AuthPhase::Oauth, "oauth"),
        (AuthPhase::AccessToken, "access_token"),
        (AuthPhase::ForceRefreshAccessToken, "force_refresh_access_token"),
        (AuthPhase::FetchUser, "fetch_user"),
        (AuthPhase::ValidateSession, "validate_session"),
        (AuthPhase::ListTeams, "list_teams"),
        (AuthPhase::TeamSelection, "team_selection"),
        (AuthPhase::TeamManagement, "team_management"),
        (AuthPhase::PostSignIn, "post_sign_in"),
        (AuthPhase::AccountDeletion, "account_deletion"),
        (AuthPhase::PushRegistrationSession, "push_registration_session"),
        (AuthPhase::PushUnregistrationSession, "push_unregistration_session"),
    ];
    for (phase, label) in labels {
        assert_eq!(phase.as_str(), label);
    }
}

#[test]
fn each_phase_takes_the_runner_swift_routes_it_to() {
    assert_eq!(AuthPhase::ValidateSession.runner(), PhaseRunner::Validation);
    assert_eq!(AuthPhase::FetchUser.runner(), PhaseRunner::TokenTouching);
    assert_eq!(AuthPhase::ListTeams.runner(), PhaseRunner::TokenTouching);
    assert_eq!(AuthPhase::AccessToken.runner(), PhaseRunner::TokenTouching);
    assert_eq!(AuthPhase::ForceRefreshAccessToken.runner(), PhaseRunner::TokenTouching);
    assert_eq!(AuthPhase::AccountDeletion.runner(), PhaseRunner::TokenTouching);
    assert_eq!(AuthPhase::VerifyCode.runner(), PhaseRunner::Exchange);
    assert_eq!(AuthPhase::PasswordSignIn.runner(), PhaseRunner::Exchange);
    assert_eq!(AuthPhase::Oauth.runner(), PhaseRunner::Exchange);
    assert_eq!(AuthPhase::PostSignIn.runner(), PhaseRunner::PostSignIn);
    assert_eq!(
        AuthPhase::SendCode.runner(),
        PhaseRunner::Prompt { blocks_retries_while_timed_out: true }
    );
    assert_eq!(
        AuthPhase::TeamSelection.runner(),
        PhaseRunner::Prompt { blocks_retries_while_timed_out: false }
    );
    assert_eq!(SignInKind::External.exchange(), None);
}

#[test]
fn one_live_operation_per_phase() {
    let mut damper = PhaseDamper::default();
    assert!(damper.begin(AuthPhase::Oauth, 1, 0));
    assert!(!damper.begin(AuthPhase::Oauth, 2, 0));
    assert!(damper.begin(AuthPhase::VerifyCode, 3, 0), "phases are independent");
    damper.end(AuthPhase::Oauth, 1);
    assert!(damper.begin(AuthPhase::Oauth, 2, 0));
}

#[test]
fn a_timed_out_phase_refuses_retries_until_it_ends_or_its_reset_passes() {
    let mut damper = PhaseDamper::default();
    assert_eq!(TIMED_OUT_RESET, Duration::from_secs(30));
    assert!(damper.begin(AuthPhase::SendCode, 1, 0));
    damper.mark_timed_out(AuthPhase::SendCode, 1, 0);
    assert!(!damper.can_begin(AuthPhase::SendCode, 29 * SECOND));
    assert!(damper.can_begin(AuthPhase::SendCode, 30 * SECOND));

    // The hung operation finishing releases the phase too.
    assert!(damper.begin(AuthPhase::SendCode, 2, 31 * SECOND));
    damper.mark_timed_out(AuthPhase::SendCode, 2, 31 * SECOND);
    damper.end(AuthPhase::SendCode, 2);
    assert!(damper.can_begin(AuthPhase::SendCode, 32 * SECOND));
}

#[test]
fn marking_an_operation_that_already_ended_does_nothing() {
    let mut damper = PhaseDamper::default();
    assert!(damper.begin(AuthPhase::Oauth, 1, 0));
    damper.end(AuthPhase::Oauth, 1);
    damper.mark_timed_out(AuthPhase::Oauth, 1, 0);
    assert!(damper.can_begin(AuthPhase::Oauth, 0));
}

#[test]
fn an_explicit_action_supersedes_only_the_timed_out_slot() {
    let mut damper = PhaseDamper::default();
    assert!(damper.begin(AuthPhase::SendCode, 1, 0));
    damper.mark_timed_out(AuthPhase::SendCode, 1, 0);
    assert!(damper.begin(AuthPhase::Oauth, 2, 0));
    damper.supersede_timed_out();
    assert!(damper.can_begin(AuthPhase::SendCode, SECOND));
    assert!(!damper.can_begin(AuthPhase::Oauth, SECOND), "a live operation keeps its slot");
}

#[test]
fn clearing_forgets_both_live_and_timed_out_operations() {
    let mut damper = PhaseDamper::new(Duration::from_secs(5));
    assert!(damper.begin(AuthPhase::VerifyCode, 1, 0));
    damper.mark_timed_out(AuthPhase::VerifyCode, 1, 0);
    assert!(damper.begin(AuthPhase::Oauth, 2, 0));
    damper.clear(&[AuthPhase::VerifyCode, AuthPhase::Oauth]);
    assert!(damper.can_begin(AuthPhase::VerifyCode, 0));
    assert!(damper.can_begin(AuthPhase::Oauth, 0));
}
