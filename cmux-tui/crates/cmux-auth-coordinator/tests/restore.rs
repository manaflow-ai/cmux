//! Launch restore and foreground revalidation: Swift `AuthCoordinatorTests`
//! (restore), `AuthCoordinatorSessionValidityTests`,
//! `AuthCoordinatorFailedTokenReadTests`, `AuthCoordinatorLockedStorageTests`
//! and `AuthCoordinatorStaleClearTests`.

mod common;

use cmux_auth_coordinator::{
    AuthFailure, AutoLoginCredentials, AutoLoginSource, Effect, Event,
    FAILED_TOKEN_READ_RETRY_DELAYS, LaunchOptions, Persisted, RestoreTicket, RestoreTrigger,
    SignInKind,
};
use common::{Driver, probe_ticket, refresh_ticket, teams, user};

#[test]
fn restore_with_stored_tokens_validates_the_session() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    let fx = d.probe(ticket, true);
    assert_eq!(fx, vec![Effect::SetHasTokens, Effect::ValidateCachedSession(ticket)]);

    let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u1"))) });
    // Same account: no new generation, so no transition and no hook.
    assert!(!fx.contains(&Effect::NotifySessionWillTransition));
    assert_eq!(d.c.session_generation(), 0);
    let teams_ticket = refresh_ticket(&fx).expect("teams are read");
    assert!(!teams_ticket.runs_post_sign_in_hook);
    assert!(d.c.is_authenticated() && !d.c.is_restoring_session());

    let fx =
        d.send(Event::TeamsRefreshed { ticket: teams_ticket, result: Ok(teams(&["t1", "t2"])) });
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
    assert_eq!(d.c.resolved_team_id().as_deref(), Some("t1"));
    assert_eq!(d.c.team_scope().map(|scope| scope.team_id), Some("t1".to_owned()));
}

#[test]
fn a_launch_after_an_environment_change_clears_the_store_before_the_probe() {
    let mut d = Driver::new(
        LaunchOptions { replace_stored_session_with_auto_login: true, ..LaunchOptions::default() },
        Persisted::default(),
    );
    let fx = d.send(Event::Restore(RestoreTrigger::Launch));
    assert_eq!(fx[0], Effect::ClearLocalSession);
    assert!(matches!(fx[1], Effect::ProbeStoredTokens(_)));
}

#[test]
fn a_concurrent_revalidation_joins_the_active_one() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    assert_eq!(d.send(Event::Restore(RestoreTrigger::Foreground)), vec![Effect::JoinRestore]);
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Err(AuthFailure::TimedOut) });
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
    // The next foreground return starts a fresh check.
    assert!(probe_ticket(&d.send(Event::Restore(RestoreTrigger::Foreground))).is_some());
}

#[test]
fn a_signed_out_foreground_return_keeps_the_pending_code() {
    let mut d = Driver::signed_out();
    d.send(Event::SendCodeStarted);
    d.send(Event::SendCodeFinished { sent: true });
    assert!(d.send(Event::Restore(RestoreTrigger::Foreground)).is_empty());
    assert!(d.c.has_pending_code());
}

#[test]
fn an_empty_session_routes_to_sign_in_and_keeps_the_pending_code() {
    let mut d = Driver::new(
        LaunchOptions::default(),
        Persisted { cached_user: None, has_tokens: true, selected_team_id: None },
    );
    d.send(Event::SendCodeFinished { sent: true });
    let ticket = d.start_restore(RestoreTrigger::Launch);
    let fx = d.probe(ticket, false);
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
    assert!(!d.c.is_authenticated() && !d.c.is_restoring_session());
    assert_eq!(
        d.c.last_sign_out_reason(),
        Some("launch restore found no stored tokens in readable storage")
    );
    assert!(d.c.has_pending_code());
    assert!(!fx.contains(&Effect::DropPendingCode));

    let mut fresh = Driver::signed_out();
    let ticket = fresh.start_restore(RestoreTrigger::Launch);
    fresh.probe(ticket, false);
    assert_eq!(fresh.c.last_sign_out_reason(), Some("launch restore found no session"));
}

#[test]
fn a_failed_token_probe_keeps_the_cached_session() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    let fx = d.send(Event::TokensProbed {
        ticket,
        probe: Err(AuthFailure::TimedOut),
        storage_was_available: true,
        read_failed: false,
    });
    assert!(d.c.is_authenticated() && !d.c.is_restoring_session());
    assert!(fx.contains(&Effect::SetHasTokens));
    assert!(common::recovery_sleep(&fx).is_some(), "teams never loaded: recovery starts");
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
}

#[test]
fn a_validation_timeout_keeps_the_session_and_starts_recovery() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Err(AuthFailure::TimedOut) });
    assert!(d.c.is_authenticated());
    assert!(d.c.has_pending_team_scope_recovery());
    assert!(!fx.iter().any(|effect| matches!(effect, Effect::ReadSurvivingRefreshToken { .. })));
}

fn validate_and_fail(d: &mut Driver, failure: AuthFailure) -> RestoreTicket {
    let ticket = d.start_restore(RestoreTrigger::Foreground);
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Err(failure.clone()) });
    assert_eq!(fx, vec![Effect::ReadSurvivingRefreshToken { ticket, after_error: Some(failure) }]);
    ticket
}

#[test]
fn a_validation_failure_with_no_refresh_token_routes_to_sign_in() {
    let mut d = Driver::cached("u1");
    let ticket = validate_and_fail(&mut d, AuthFailure::NetworkError);
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::NetworkError),
        result: Ok(false),
        read_failed: false,
    });
    let reason = "validation failed and no refresh token survives".to_owned();
    assert_eq!(
        fx,
        vec![Effect::ClearStaleSession {
            ticket,
            compare_refresh_token: false,
            reason: reason.clone(),
        }]
    );
    d.send(Event::StaleSessionCleared { ticket, reason });
    assert!(!d.c.is_authenticated());
    assert_eq!(d.c.last_sign_out_reason(), Some("validation failed and no refresh token survives"));
}

#[test]
fn a_validation_failure_with_a_surviving_refresh_token_keeps_the_session() {
    let mut d = Driver::cached("u1");
    let ticket = validate_and_fail(&mut d, AuthFailure::NetworkError);
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::NetworkError),
        result: Ok(true),
        read_failed: false,
    });
    assert!(d.c.is_authenticated());
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
}

#[test]
fn a_definitive_rejection_with_a_surviving_token_compare_clears() {
    let mut d = Driver::cached("u1");
    let ticket = validate_and_fail(&mut d, AuthFailure::Unauthorized);
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::Unauthorized),
        result: Ok(true),
        read_failed: false,
    });
    assert_eq!(
        fx,
        vec![Effect::ClearStaleSession {
            ticket,
            compare_refresh_token: true,
            reason: "validation failed with a session-clearing error".to_owned(),
        }]
    );
}

#[test]
fn a_failed_read_during_validation_keeps_the_cached_session() {
    let mut d = Driver::cached("u1");
    let ticket = validate_and_fail(&mut d, AuthFailure::NetworkError);
    d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::NetworkError),
        result: Ok(false),
        read_failed: true,
    });
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.last_sign_out_reason(), None);
}

#[test]
fn no_current_user_follows_the_surviving_refresh_token() {
    for (survives, signed_in) in [(true, true), (false, false)] {
        let mut d = Driver::cached("u1");
        let ticket = d.start_restore(RestoreTrigger::Launch);
        d.probe(ticket, true);
        let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(None) });
        assert_eq!(fx, vec![Effect::ReadSurvivingRefreshToken { ticket, after_error: None }]);
        let fx = d.send(Event::SurvivingRefreshTokenRead {
            ticket,
            after_error: None,
            result: Ok(survives),
            read_failed: false,
        });
        if let Some(Effect::ClearStaleSession { reason, .. }) = fx.first() {
            d.send(Event::StaleSessionCleared { ticket, reason: reason.clone() });
        }
        assert_eq!(d.c.is_authenticated(), signed_in, "survives={survives}");
    }
}

#[test]
fn a_timed_out_read_after_no_user_takes_the_failure_path() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    d.probe(ticket, true);
    d.send(Event::CachedSessionValidated { ticket, result: Ok(None) });
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: None,
        result: Err(AuthFailure::TimedOut),
        read_failed: false,
    });
    assert!(d.c.is_authenticated());
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
}

#[test]
fn token_reads_that_fail_retry_with_backoff_then_keep_the_cached_session() {
    let mut d = Driver::cached("u1");
    let mut ticket = d.start_restore(RestoreTrigger::Launch);
    for delay in FAILED_TOKEN_READ_RETRY_DELAYS {
        let fx = d.send(Event::TokensProbed {
            ticket,
            probe: Ok(false),
            storage_was_available: true,
            read_failed: true,
        });
        assert_eq!(fx, vec![Effect::RetryProbeAfter { ticket, delay }]);
        let fx = d.send(Event::ProbeRetryDue { ticket, cancelled: false });
        ticket = probe_ticket(&fx).expect("the probe runs again");
    }
    assert_eq!(ticket.failed_read_retries, 3);
    let fx = d.send(Event::TokensProbed {
        ticket,
        probe: Ok(false),
        storage_was_available: true,
        read_failed: true,
    });
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.last_sign_out_reason(), None);
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
}

#[test]
fn reads_that_fail_twice_then_succeed_keep_the_session_signed_in() {
    let mut d = Driver::cached("u1");
    let mut ticket = d.start_restore(RestoreTrigger::Launch);
    for _ in 0..2 {
        d.send(Event::TokensProbed {
            ticket,
            probe: Ok(false),
            storage_was_available: true,
            read_failed: true,
        });
        let fx = d.send(Event::ProbeRetryDue { ticket, cancelled: false });
        ticket = probe_ticket(&fx).expect("the probe runs again");
    }
    let fx = d.probe(ticket, true);
    assert!(fx.contains(&Effect::ValidateCachedSession(ticket)));
}

#[test]
fn a_cancelled_retry_backoff_settles_on_the_cached_session() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    d.send(Event::TokensProbed {
        ticket,
        probe: Ok(false),
        storage_was_available: true,
        read_failed: true,
    });
    let fx = d.send(Event::ProbeRetryDue { ticket, cancelled: true });
    assert!(d.c.is_authenticated());
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
}

#[test]
fn locked_storage_keeps_the_cached_session_and_retries_once_after_unlock() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    let fx = d.send(Event::TokensProbed {
        ticket,
        probe: Ok(false),
        storage_was_available: false,
        read_failed: false,
    });
    assert!(d.c.is_authenticated());
    assert_eq!(fx.last(), Some(&Effect::CheckTokenStorageAvailable(ticket)));

    let fx = d.send(Event::TokenStorageAvailability { ticket, available: true });
    let retry = probe_ticket(&fx).expect("unlock retries the probe");
    assert!(!retry.retry_on_storage_available);
    // Still locked on the retry: no second retry.
    let fx = d.send(Event::TokensProbed {
        ticket: retry,
        probe: Ok(false),
        storage_was_available: false,
        read_failed: false,
    });
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
    assert!(d.c.is_authenticated());
}

#[test]
fn a_stale_validation_failure_does_not_clear_a_fresh_sign_in() {
    let mut d = Driver::cached("old");
    let ticket = validate_and_fail(&mut d, AuthFailure::NetworkError);
    // A sign-in publishes before the stale validation's token read lands.
    d.sign_in("new", Ok(teams(&["t1"])));
    let generation = d.c.session_generation();
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::NetworkError),
        result: Ok(false),
        read_failed: false,
    });
    assert_eq!(fx, vec![Effect::RestoreFinished]);
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.session_generation(), generation);
}

#[test]
fn a_parked_stale_clear_cannot_wipe_a_fresh_sign_ins_tokens() {
    let mut d = Driver::cached("old");
    let ticket = d.start_restore(RestoreTrigger::Foreground);
    d.probe(ticket, true);
    // A newer sign-in's exchange writes the store while validation is parked.
    d.sign_in_through_exchange(SignInKind::Password);
    d.send(Event::CachedSessionValidated { ticket, result: Err(AuthFailure::NetworkError) });
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::NetworkError),
        result: Ok(false),
        read_failed: false,
    });
    assert_eq!(fx, vec![Effect::RestoreFinished], "the store has a new owner");
}

#[test]
fn a_stale_clear_whose_store_clear_raced_a_publish_leaves_the_new_session() {
    let mut d = Driver::cached("old");
    let ticket = validate_and_fail(&mut d, AuthFailure::NetworkError);
    let fx = d.send(Event::SurvivingRefreshTokenRead {
        ticket,
        after_error: Some(AuthFailure::NetworkError),
        result: Ok(false),
        read_failed: false,
    });
    let Some(Effect::ClearStaleSession { reason, .. }) = fx.first().cloned() else {
        panic!("expected a stale clear, got {fx:?}");
    };
    d.sign_in("new", Ok(teams(&["t1"])));
    d.send(Event::StaleSessionCleared { ticket, reason });
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.current_user().map(|u| u.id.as_str()), Some("new"));
}

fn auto_login_launch() -> Driver {
    Driver::new(
        LaunchOptions {
            environment_auto_login: true,
            auto_login: Some(AutoLoginCredentials { email_is_empty: false }),
            ..LaunchOptions::default()
        },
        Persisted::default(),
    )
}

#[test]
fn an_empty_store_with_environment_credentials_auto_logs_in() {
    let mut d = auto_login_launch();
    let ticket = d.start_restore(RestoreTrigger::Launch);
    let fx = d.probe(ticket, false);
    assert_eq!(fx, vec![Effect::AutoLogin { ticket, source: AutoLoginSource::Environment }]);
    // Stored tokens win over the credentials.
    let mut d = auto_login_launch();
    let ticket = d.start_restore(RestoreTrigger::Launch);
    assert!(d.probe(ticket, true).contains(&Effect::ValidateCachedSession(ticket)));
}

#[test]
fn a_failed_auto_login_clears_but_a_superseded_one_does_not() {
    let mut d = auto_login_launch();
    let ticket = d.start_restore(RestoreTrigger::Launch);
    d.probe(ticket, false);
    let fx = d.send(Event::AutoLoginFinished { ticket, result: Err(AuthFailure::Cancelled) });
    assert_eq!(fx, vec![Effect::RestoreFinished]);

    let mut d = auto_login_launch();
    let ticket = d.start_restore(RestoreTrigger::Launch);
    d.probe(ticket, false);
    let fx = d.send(Event::AutoLoginFinished { ticket, result: Err(AuthFailure::Unauthorized) });
    assert_eq!(
        fx,
        vec![Effect::ClearStaleSession {
            ticket,
            compare_refresh_token: false,
            reason: "auto-login failed".to_owned(),
        }]
    );
}

#[test]
fn remembered_debug_credentials_sign_in_again_on_an_empty_store() {
    let mut d = Driver::new(
        LaunchOptions { includes_dev_auth: true, ..LaunchOptions::default() },
        Persisted::default(),
    );
    d.send(Event::DebugCredentialsRemembered);
    let ticket = d.start_restore(RestoreTrigger::Launch);
    assert_eq!(
        d.probe(ticket, false),
        vec![Effect::AutoLogin { ticket, source: AutoLoginSource::DebugCredentials }]
    );
}

#[test]
fn a_debug_fixture_signs_in_without_validation() {
    let mut d = Driver::new(
        LaunchOptions {
            debug_build: true,
            fixture_user: Some(user("fixture")),
            fixture_teams_requested: true,
            ..LaunchOptions::default()
        },
        Persisted::default(),
    );
    let ticket = d.start_restore(RestoreTrigger::Launch);
    let fx = d.probe(ticket, false);
    assert!(fx.contains(&Effect::SaveCachedUser(user("fixture"))));
    let teams_ticket = refresh_ticket(&fx).expect("fixture teams are read");
    let fx = d.send(Event::TeamsRefreshed { ticket: teams_ticket, result: Ok(teams(&["t1"])) });
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));
}

#[test]
fn a_clear_auth_launch_never_restores() {
    let mut d = Driver::new(
        LaunchOptions { clear_auth_requested: true, ..LaunchOptions::default() },
        Persisted::default(),
    );
    assert!(d.send(Event::Restore(RestoreTrigger::Launch)).is_empty());
}
