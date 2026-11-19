//! Teams and team scope: Swift `AuthCoordinatorTests` (teams),
//! `AuthCoordinatorTeamScopeRecoveryTests` and the team-scope generation rules.

mod common;

use std::time::Duration;

use cmux_auth_coordinator::{
    AuthFailure, Effect, Event, LaunchOptions, Persisted, RestoreTrigger, SignInKind, TeamList,
    team_scope_rate_limit_delay, team_scope_recovery_delay,
};
use common::{Driver, recovery_sleep, refresh_ticket, team, teams, user};

fn with_selection(selected: &str) -> Driver {
    Driver::new(
        LaunchOptions::default(),
        Persisted {
            cached_user: None,
            has_tokens: false,
            selected_team_id: Some(selected.to_owned()),
        },
    )
}

#[test]
fn sign_in_takes_the_servers_selection() {
    let mut d = with_selection("t1");
    d.sign_in(
        "u1",
        Ok(TeamList {
            teams: vec![team("t1"), team("t2")],
            server_selected_team_id: Some("t2".into()),
        }),
    );
    assert_eq!(d.c.selected_team_id(), Some("t2"));
    assert!(d.logged(&Effect::PersistSelectedTeam(Some("t2".into()))));
}

#[test]
fn a_persisted_selection_survives_sign_in() {
    let mut d = with_selection("t2");
    d.sign_in("u1", Ok(teams(&["t1", "t2"])));
    assert_eq!(d.c.selected_team_id(), Some("t2"));
    assert_eq!(d.c.resolved_team_id().as_deref(), Some("t2"));
}

#[test]
fn a_stale_selection_falls_back_to_the_first_team() {
    let mut d = with_selection("gone");
    d.sign_in("u1", Ok(teams(&["t1", "t2"])));
    assert_eq!(d.c.selected_team_id(), Some("t1"));
}

#[test]
fn a_failed_team_read_does_not_unwind_sign_in_and_keeps_the_selection_effective() {
    let mut d = with_selection("t9");
    let fx = d.sign_in("u1", Err(AuthFailure::NetworkError));
    assert!(fx.iter().any(|effect| matches!(effect, Effect::SignInSucceeded(_))));
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.resolved_team_id().as_deref(), Some("t9"));
    assert_eq!(d.c.team_scope(), None);
    assert!(d.c.needs_team_scope_recovery());
    let (_, delay) = recovery_sleep(&d.log).expect("recovery starts");
    assert_eq!(delay, Duration::from_secs(2));
}

#[test]
fn a_selection_made_during_a_read_wins_over_the_reads_answer() {
    let mut d = Driver::signed_out();
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
    let ticket = refresh_ticket(&fx).unwrap();
    d.send(Event::TeamSelectionMutated);
    d.send(Event::SetSelectedTeam(Some("t2".into())));
    d.send(Event::TeamsRefreshed {
        ticket,
        result: Ok(TeamList {
            teams: vec![team("t1"), team("t2")],
            server_selected_team_id: Some("t1".into()),
        }),
    });
    assert_eq!(d.c.selected_team_id(), Some("t2"));
}

#[test]
fn a_list_change_during_a_read_keeps_the_list_the_change_left() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1", "t2"])));
    let fx = d.send(Event::TeamsRequested);
    let ticket = refresh_ticket(&fx).unwrap();
    d.send(Event::TeamListMutated);
    d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&["t1", "t2", "deleted"])) });
    assert_eq!(d.c.available_teams().len(), 2);
}

#[test]
fn a_changed_account_cannot_borrow_the_previous_accounts_teams() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    assert!(d.c.team_scope().is_some());
    d.sign_in("u2", Err(AuthFailure::NetworkError));
    assert!(d.c.available_teams().is_empty());
    assert_eq!(d.c.team_scope(), None);
}

#[test]
fn the_team_scope_generation_advances_on_every_account_or_team_change() {
    let mut d = Driver::signed_out();
    d.sign_in("a", Ok(teams(&["t1"])));
    let first = d.c.team_scope().unwrap();
    d.sign_in("b", Ok(teams(&["t1"])));
    let second = d.c.team_scope().unwrap();
    d.sign_in("a", Ok(teams(&["t1"])));
    let third = d.c.team_scope().unwrap();
    assert!(first.generation < second.generation && second.generation < third.generation);
    assert_ne!(first, third, "A to B to A is a new scope");

    d.send(Event::SetSelectedTeam(Some("t1".into())));
    assert_eq!(d.c.team_scope(), Some(third), "no change, no new scope");
}

#[test]
fn the_cached_team_identity_needs_tokens_an_account_and_a_team() {
    let d = Driver::new(
        LaunchOptions::default(),
        Persisted {
            cached_user: Some(user("u1")),
            has_tokens: true,
            selected_team_id: Some("t1".into()),
        },
    );
    let identity = d.c.cached_team_identity().unwrap();
    assert_eq!((identity.account_id.as_str(), identity.team_id.as_str()), ("u1", "t1"));
    assert_eq!(Driver::cached("u1").c.cached_team_identity(), None);
}

#[test]
fn recovery_retries_until_the_teams_load_then_stops() {
    let mut d = Driver::cached("u1");
    let ticket = d.start_restore(RestoreTrigger::Launch);
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u1"))) });
    let fx = d.send(Event::TeamsRefreshed {
        ticket: refresh_ticket(&fx).unwrap(),
        result: Err(AuthFailure::NetworkError),
    });
    let (id, delay) = recovery_sleep(&fx).expect("recovery starts");
    assert_eq!(delay, team_scope_recovery_delay(0));
    assert_eq!(fx.last(), Some(&Effect::RestoreFinished));

    // Attempt 1 fails again.
    let fx = d.send(Event::TeamScopeRecoveryDue { id });
    let ticket = common::probe_ticket(&fx).expect("recovery revalidates");
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u1"))) });
    d.send(Event::TeamsRefreshed {
        ticket: refresh_ticket(&fx).unwrap(),
        result: Err(AuthFailure::NetworkError),
    });
    let fx = d.send(Event::TeamScopeRecoveryCheckFinished { id });
    assert_eq!(
        fx,
        vec![Effect::SleepTeamScopeRecovery { id, delay: team_scope_recovery_delay(1) }]
    );

    // Attempt 2 loads the teams: the restore retires the loop.
    let fx = d.send(Event::TeamScopeRecoveryDue { id });
    let ticket = common::probe_ticket(&fx).unwrap();
    d.probe(ticket, true);
    let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u1"))) });
    let fx = d.send(Event::TeamsRefreshed {
        ticket: refresh_ticket(&fx).unwrap(),
        result: Ok(teams(&["t1"])),
    });
    assert!(fx.contains(&Effect::CancelTeamScopeRecovery { id }));
    assert!(!d.c.has_pending_team_scope_recovery());
    assert!(d.send(Event::TeamScopeRecoveryCheckFinished { id }).is_empty());
}

#[test]
fn sign_out_stops_recovery() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Err(AuthFailure::NetworkError));
    let (id, _) = recovery_sleep(&d.log).unwrap();
    let fx = d.sign_out();
    assert!(fx.contains(&Effect::CancelTeamScopeRecovery { id }));
    assert!(d.send(Event::TeamScopeRecoveryDue { id }).is_empty());
}

#[test]
fn a_new_sign_in_restarts_recovery_at_the_initial_delay() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Err(AuthFailure::NetworkError));
    let (first, _) = recovery_sleep(&d.log).unwrap();
    d.clear_log();
    d.sign_in("u1", Err(AuthFailure::NetworkError));
    assert!(d.logged(&Effect::CancelTeamScopeRecovery { id: first }));
    let (second, delay) = recovery_sleep(&d.log).unwrap();
    assert_ne!(first, second);
    assert_eq!(delay, team_scope_recovery_delay(0));
}

#[test]
fn a_host_signal_recovers_at_once_but_is_a_no_op_when_healthy_or_rate_limited() {
    let mut healthy = Driver::signed_out();
    healthy.sign_in("u1", Ok(teams(&["t1"])));
    assert!(healthy.send(Event::Restore(RestoreTrigger::TeamScopeSignal)).is_empty());

    let mut broken = Driver::signed_out();
    broken.sign_in("u1", Err(AuthFailure::NetworkError));
    assert!(
        common::probe_ticket(&broken.send(Event::Restore(RestoreTrigger::TeamScopeSignal)))
            .is_some()
    );

    let mut limited = Driver::signed_out();
    limited.sign_in(
        "u1",
        Err(AuthFailure::RateLimited { retry_after: Some(Duration::from_secs(120)) }),
    );
    assert!(limited.send(Event::Restore(RestoreTrigger::TeamScopeSignal)).is_empty());
}

#[test]
fn a_rate_limited_session_check_waits_at_least_retry_after() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Err(AuthFailure::RateLimited { retry_after: Some(Duration::from_secs(120)) }));
    let backoff = d
        .log
        .iter()
        .find_map(|effect| match effect {
            Effect::SessionCheckRateLimited { backoff, attempt, .. } => Some((*backoff, *attempt)),
            _ => None,
        })
        .unwrap();
    assert_eq!(backoff.1, 1);
    assert!(backoff.0 >= Duration::from_secs(120) && backoff.0 <= Duration::from_secs(180));
    // The recovery wait is the longer of the two.
    assert_eq!(d.c.team_scope_recovery_wait(0), backoff.0);
    let (_, delay) = recovery_sleep(&d.log).unwrap();
    assert_eq!(delay, backoff.0);
}

#[test]
fn backoff_tables_match_swift() {
    let delays: Vec<u64> = (0..8).map(|n| team_scope_recovery_delay(n).as_secs()).collect();
    assert_eq!(delays, vec![2, 4, 8, 16, 32, 60, 60, 60]);

    // Retry-After: clamped to 1 s-15 min, then stretched by 1.0-1.5x.
    assert_eq!(
        team_scope_rate_limit_delay(Some(Duration::from_millis(10)), 1, 0.5),
        Duration::from_secs(1)
    );
    assert_eq!(
        team_scope_rate_limit_delay(Some(Duration::from_secs(100)), 1, 1.0),
        Duration::from_secs(150)
    );
    assert_eq!(
        team_scope_rate_limit_delay(Some(Duration::from_secs(3600)), 1, 1.0),
        Duration::from_secs(900)
    );
    // No Retry-After: 30 s doubling to 15 min, times the jitter.
    assert_eq!(team_scope_rate_limit_delay(None, 1, 1.0), Duration::from_secs(30));
    assert_eq!(team_scope_rate_limit_delay(None, 3, 1.0), Duration::from_secs(120));
    assert_eq!(team_scope_rate_limit_delay(None, 9, 1.0), Duration::from_secs(900));
    assert_eq!(team_scope_rate_limit_delay(None, 1, 0.1), Duration::from_secs(15));
}
