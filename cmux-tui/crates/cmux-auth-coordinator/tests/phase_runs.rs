//! Phase runs: Swift's exchange, validation, post-sign-in and token-touching
//! timeout runners (`AuthCoordinatorTimeoutTests`, the token-phase and
//! validation race cases).

mod common;

use cmux_auth_coordinator::{AuthFailure, AuthPhase, Effect, Event, SignInKind, wire};
use common::{Driver, teams};

const SECOND: u64 = 1_000_000_000;

fn start(d: &mut Driver, phase: AuthPhase, now: u64) -> Option<u64> {
    match d.send(Event::PhaseStartRequested { phase, now_nanos: now }).as_slice() {
        [Effect::PhaseStarted { id, phase: started }] => {
            assert_eq!(*started, phase);
            Some(*id)
        }
        [Effect::PhaseRefused { phase: refused }] => {
            assert_eq!(*refused, phase);
            None
        }
        other => panic!("expected a start answer, got {other:?}"),
    }
}

#[test]
fn a_timed_out_validation_refuses_retries_until_it_ends_or_its_reset_passes() {
    let mut d = Driver::signed_out();
    let first = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");
    assert_eq!(start(&mut d, AuthPhase::ValidateSession, 0), None, "one live validation");
    d.send(Event::PhaseTimedOut { id: first, now_nanos: SECOND });
    assert_eq!(start(&mut d, AuthPhase::ValidateSession, 30 * SECOND), None);
    assert!(start(&mut d, AuthPhase::ValidateSession, 31 * SECOND).is_some(), "reset passed");

    let mut d = Driver::signed_out();
    let first = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");
    d.send(Event::PhaseTimedOut { id: first, now_nanos: 0 });
    d.send(Event::PhaseEnded { id: first });
    assert!(start(&mut d, AuthPhase::ValidateSession, SECOND).is_some(), "the hung run ended");
}

#[test]
fn a_cancelled_validation_caller_parks_nothing_but_an_exchange_caller_does() {
    let mut d = Driver::signed_out();
    let validation = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");
    d.send(Event::PhaseCallerCancelled { id: validation, now_nanos: 0 });
    d.send(Event::SupersedeTimedOutPhases);
    assert_eq!(
        start(&mut d, AuthPhase::ValidateSession, 0),
        None,
        "still live: superseding releases only a parked run"
    );

    let exchange = start(&mut d, AuthPhase::Oauth, 0).expect("starts");
    d.send(Event::PhaseCallerCancelled { id: exchange, now_nanos: 0 });
    d.send(Event::SupersedeTimedOutPhases);
    assert!(start(&mut d, AuthPhase::Oauth, 0).is_some(), "the parked exchange was released");
}

#[test]
fn token_phases_run_concurrently_until_one_is_left_running() {
    let mut d = Driver::signed_out();
    let first = start(&mut d, AuthPhase::AccessToken, 0).expect("starts");
    let second = start(&mut d, AuthPhase::AccessToken, 0).expect("token reads overlap");
    d.send(Event::PhaseTimedOut { id: first, now_nanos: 0 });
    assert_eq!(start(&mut d, AuthPhase::AccessToken, 60 * SECOND), None, "gated while it runs");
    assert!(start(&mut d, AuthPhase::FetchUser, 0).is_some(), "phases are independent");
    d.send(Event::PhaseEnded { id: second });
    assert_eq!(start(&mut d, AuthPhase::AccessToken, 60 * SECOND), None);
    d.send(Event::PhaseEnded { id: first });
    assert!(start(&mut d, AuthPhase::AccessToken, 60 * SECOND).is_some(), "it ended");

    let gated = start(&mut d, AuthPhase::ListTeams, 0).expect("starts");
    d.send(Event::PhaseCallerCancelled { id: gated, now_nanos: 0 });
    assert_eq!(start(&mut d, AuthPhase::ListTeams, 0), None, "a cancelled caller gates too");
    d.send(Event::SupersedeTimedOutPhases);
    assert!(start(&mut d, AuthPhase::ListTeams, 0).is_some(), "a user action reclaims it");
}

#[test]
fn prompts_and_the_post_sign_in_hook_are_never_refused() {
    let mut d = Driver::signed_out();
    for phase in [AuthPhase::TeamSelection, AuthPhase::PostSignIn] {
        let first = start(&mut d, phase, 0).expect("starts");
        d.send(Event::PhaseTimedOut { id: first, now_nanos: 0 });
        assert!(start(&mut d, phase, 0).is_some());
    }
    let send_code = start(&mut d, AuthPhase::SendCode, 0).expect("starts");
    d.send(Event::PhaseTimedOut { id: send_code, now_nanos: 0 });
    assert_eq!(start(&mut d, AuthPhase::SendCode, 0), None, "send code blocks retries");
}

#[test]
fn sign_out_cancels_the_runs_that_touch_the_session_and_resets_interactive_phases() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let exchange = start(&mut d, AuthPhase::PasswordSignIn, 0).expect("starts");
    d.send(Event::PhaseTimedOut { id: exchange, now_nanos: 0 });
    let hook = start(&mut d, AuthPhase::PostSignIn, 0).expect("starts");
    let token = start(&mut d, AuthPhase::AccessToken, 0).expect("starts");
    let prompt = start(&mut d, AuthPhase::TeamManagement, 0).expect("starts");
    let validation = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");

    let fx = d.send(Event::SignOutRequested);
    assert_eq!(fx[0], Effect::CancelInFlightWork { runs: vec![exchange, hook, token, validation] });
    assert!(!fx.iter().any(
        |effect| matches!(effect, Effect::CancelInFlightWork { runs } if runs.contains(&prompt))
    ));
    assert!(start(&mut d, AuthPhase::PasswordSignIn, 0).is_some(), "the damper was cleared");

    let fx = d.local_cleared();
    assert!(fx.contains(&Effect::WaitForPostSignInHooks { runs: vec![hook] }));
    d.send(Event::PhaseEnded { id: hook });
    let fx = d.sign_out();
    assert!(fx.contains(&Effect::WaitForPostSignInHooks { runs: vec![] }));
}

#[test]
fn a_sign_in_quiesces_validation_token_and_exchange_runs() {
    let mut d = Driver::signed_out();
    let validation = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");
    let _hook = start(&mut d, AuthPhase::PostSignIn, 0).expect("starts");
    let token = start(&mut d, AuthPhase::FetchUser, 0).expect("starts");
    let exchange = start(&mut d, AuthPhase::VerifyCode, 0).expect("starts");
    let _prompt = start(&mut d, AuthPhase::SendCode, 0).expect("starts");
    let fx = d.send(Event::SignInRequested { kind: SignInKind::Password, sets_loading: true });
    let [Effect::QuiesceTokenWork { runs, .. }] = fx.as_slice() else {
        panic!("expected a quiesce, got {fx:?}");
    };
    assert_eq!(runs, &vec![validation, token, exchange]);
}

#[test]
fn a_run_in_an_unchanged_session_keeps_its_result() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    for phase in [AuthPhase::ValidateSession, AuthPhase::AccessToken, AuthPhase::Oauth] {
        let id = start(&mut d, phase, 0).expect("starts");
        assert_eq!(
            d.send(Event::PhaseOperationFinished { id }),
            vec![Effect::PhaseResultStands { id }]
        );
        d.send(Event::PhaseEnded { id });
    }
}

#[test]
fn a_validation_that_outlived_a_sign_out_clears_its_stale_token() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let id = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");
    d.send(Event::SignOutRequested);
    assert_eq!(
        d.send(Event::PhaseOperationFinished { id }),
        vec![Effect::AwaitSignOutCapture { id }]
    );
    assert_eq!(
        d.send(Event::PhaseSignOutCaptureAwaited { id }),
        vec![Effect::CompareStaleRefreshToken { id }]
    );
    d.clear_log();
    let fx = d.send(Event::PhaseStaleRefreshTokenCompared { id, cleared: true });
    assert_eq!(fx.last(), Some(&Effect::PhaseResultDropped { id }));
    assert_eq!(
        d.sign_out_reasons(),
        vec!["a validation raced a sign-out and cleared its stale refresh token".to_owned()]
    );
    assert!(!d.c.is_authenticated());
}

#[test]
fn a_token_run_that_outlived_a_sign_out_keeps_a_surviving_token() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let id = start(&mut d, AuthPhase::AccessToken, 0).expect("starts");
    d.send(Event::SignOutRequested);
    d.send(Event::PhaseOperationFinished { id });
    d.send(Event::PhaseSignOutCaptureAwaited { id });
    d.clear_log();
    let fx = d.send(Event::PhaseStaleRefreshTokenCompared { id, cleared: false });
    assert_eq!(fx, vec![Effect::PhaseResultDropped { id }]);
    assert!(d.sign_out_reasons().is_empty());
}

#[test]
fn a_sign_in_that_wrote_the_store_since_owns_it() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let id = start(&mut d, AuthPhase::FetchUser, 0).expect("starts");
    d.sign_out();
    d.sign_in("u2", Ok(teams(&["t2"])));
    assert_eq!(
        d.send(Event::PhaseOperationFinished { id }),
        vec![Effect::AwaitSignOutCapture { id }]
    );
    assert_eq!(
        d.send(Event::PhaseSignOutCaptureAwaited { id }),
        vec![Effect::PhaseResultDropped { id }]
    );
    assert!(d.c.is_authenticated());
}

#[test]
fn answers_for_an_ended_run_do_nothing() {
    let mut d = Driver::signed_out();
    let id = start(&mut d, AuthPhase::ValidateSession, 0).expect("starts");
    d.send(Event::PhaseEnded { id });
    for event in [
        Event::PhaseOperationFinished { id },
        Event::PhaseSignOutCaptureAwaited { id },
        Event::PhaseStaleRefreshTokenCompared { id, cleared: true },
        Event::PhaseTimedOut { id, now_nanos: 0 },
        Event::PhaseEnded { id },
    ] {
        assert_eq!(d.send(event), vec![]);
    }
    assert!(start(&mut d, AuthPhase::ValidateSession, 0).is_some());
}

#[test]
fn an_empty_token_read_signs_out_only_when_storage_answered() {
    let mut d = Driver::signed_out();
    let cases = [
        (true, false, AuthFailure::Unauthorized),
        (true, true, AuthFailure::NetworkError),
        (false, false, AuthFailure::NetworkError),
    ];
    for (storage_was_available, read_failed, failure) in cases {
        assert_eq!(
            d.send(Event::TokenReadEmpty { storage_was_available, read_failed }),
            vec![Effect::FailTokenRead(failure)]
        );
    }
}

#[test]
fn phase_events_and_effects_cross_the_wire() {
    let mut session = wire::Session::new(wire::Config::default());
    session.take_effects();
    session
        .feed_json(br#"{"phaseStartRequested":{"phase":"access_token","nowNanos":5}}"#)
        .expect("parses");
    assert_eq!(
        String::from_utf8(session.take_effects_json()).unwrap(),
        r#"[{"phaseStarted":{"id":1,"phase":"access_token"}}]"#
    );
    session.feed_json(br#"{"phaseOperationFinished":{"id":1}}"#).expect("parses");
    assert_eq!(
        String::from_utf8(session.take_effects_json()).unwrap(),
        r#"[{"phaseResultStands":{"id":1}}]"#
    );
    session.feed_json(br#""supersedeTimedOutPhases""#).expect("parses");
}
