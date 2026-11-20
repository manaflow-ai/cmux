//! A late answer is checked against the session it was issued under: team and
//! hook completions (F1), the restore completion (F2) and the online check
//! (F3) of the review of the reducer's first PR. Swift guards the same writes
//! with `sessionGeneration`, `signOutEpoch` and the flow's attempt.

mod common;

use cmux_auth_coordinator::{
    AuthFailure, Effect, Event, RestoreTrigger, SignInFlow, SignInKind, TeamRefreshTicket,
};
use common::{Driver, hook_ticket, refresh_ticket, sign_in_failure, teams, user};

/// Runs a password sign-in to its team read and returns the flow and that read's ticket.
fn sign_in_to_team_read(d: &mut Driver) -> (SignInFlow, TeamRefreshTicket) {
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
    (flow, refresh_ticket(&fx).expect("sign-in reads the teams"))
}

fn succeeded(fx: &[Effect]) -> bool {
    fx.iter().any(|effect| matches!(effect, Effect::SignInSucceeded(_)))
}

// MARK: - F1: team and hook completions

#[test]
fn a_team_read_answering_after_sign_out_cancels_the_sign_in_instead_of_succeeding() {
    let mut d = Driver::signed_out();
    let (_, ticket) = sign_in_to_team_read(&mut d);
    d.sign_out();
    let fx = d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&["t1"])) });
    assert!(!succeeded(&fx));
    assert!(!fx.contains(&Effect::DropPendingCode));
    assert!(!fx.iter().any(|effect| matches!(effect, Effect::RunPostSignInHook(_))));
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
    assert!(!d.c.is_authenticated());
    assert!(!d.c.is_loading());
}

#[test]
fn a_hook_finishing_after_sign_out_cancels_the_sign_in_instead_of_succeeding() {
    let mut d = Driver::signed_out();
    let (_, ticket) = sign_in_to_team_read(&mut d);
    let fx = d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&["t1"])) });
    let hook = hook_ticket(&fx).expect("the hook runs after the read");
    d.sign_out();
    let fx = d.send(Event::PostSignInHookFinished { ticket: hook });
    assert!(!succeeded(&fx));
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
    assert!(!d.c.is_authenticated());
}

#[test]
fn a_hook_answer_for_a_flow_that_already_finished_changes_nothing() {
    let mut d = Driver::signed_out();
    let (_, ticket) = sign_in_to_team_read(&mut d);
    let fx = d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&["t1"])) });
    let hook = hook_ticket(&fx).expect("the hook runs after the read");
    let fx = d.send(Event::PostSignInHookFinished { ticket: hook });
    assert!(succeeded(&fx), "the current answer still completes the sign-in");
    assert_eq!(d.send(Event::PostSignInHookFinished { ticket: hook }), vec![]);
    let fx = d.send(Event::TeamsRefreshed { ticket, result: Ok(teams(&["t1"])) });
    assert!(hook_ticket(&fx).is_none(), "a finished flow runs no second hook");
    assert!(!succeeded(&fx));
    assert!(d.c.is_authenticated());
}

// MARK: - F2: the restore completion

#[test]
fn a_finished_restores_late_answer_cannot_end_the_next_restore() {
    let mut d = Driver::cached("u1");
    let first = d.start_restore(RestoreTrigger::Launch);
    d.probe(first, true);
    let fx =
        d.send(Event::CachedSessionValidated { ticket: first, result: Err(AuthFailure::TimedOut) });
    assert!(fx.contains(&Effect::RestoreFinished));

    let second = d.start_restore(RestoreTrigger::Foreground);
    assert_ne!(first.id, second.id);
    let late = d
        .send(Event::CachedSessionValidated { ticket: first, result: Err(AuthFailure::Cancelled) });
    assert_eq!(late, vec![]);
    // The newer restore still runs: a third caller joins it.
    assert_eq!(d.send(Event::Restore(RestoreTrigger::Foreground)), vec![Effect::JoinRestore]);

    d.probe(second, true);
    let fx = d
        .send(Event::CachedSessionValidated { ticket: second, result: Err(AuthFailure::TimedOut) });
    assert!(fx.contains(&Effect::RestoreFinished), "the current ticket is still applied");
}

#[test]
fn a_late_team_read_of_a_finished_restore_does_not_finish_the_next_one() {
    let mut d = Driver::cached("u1");
    let first = d.start_restore(RestoreTrigger::Launch);
    d.probe(first, true);
    let fx = d.send(Event::CachedSessionValidated { ticket: first, result: Ok(Some(user("u1"))) });
    let read = refresh_ticket(&fx).expect("restore reads the teams");
    // The first restore ends another way before its team read answers.
    d.send(Event::StaleSessionCleared { ticket: first, reason: "test".into() });
    let second = d.start_restore(RestoreTrigger::Launch);
    let fx = d.send(Event::TeamsRefreshed { ticket: read, result: Ok(teams(&["t1"])) });
    assert!(!fx.contains(&Effect::RestoreFinished));
    assert_eq!(d.send(Event::Restore(RestoreTrigger::Launch)), vec![Effect::JoinRestore]);
    d.probe(second, true);
}

// MARK: - F3: the online check

#[test]
fn an_online_answer_for_a_sign_in_a_newer_session_replaced_is_cancelled() {
    let mut d = Driver::signed_out();
    let old = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow: old, result: Ok(()) });
    d.sign_in("u2", Ok(teams(&["t2"])));
    assert!(d.c.is_authenticated());
    let generation = d.c.session_generation();

    let fx = d.send(Event::OnlineChecked { flow: old, online: true });
    assert!(!fx.iter().any(|effect| matches!(effect, Effect::RunExchange { .. })));
    assert!(!fx.contains(&Effect::SetLoading(true)));
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.current_user(), Some(&user("u2")));
    assert_eq!(d.c.session_generation(), generation);
    // The flow is retired: a second answer changes nothing.
    assert_eq!(d.send(Event::OnlineChecked { flow: old, online: true }), vec![]);
}

#[test]
fn an_online_answer_after_sign_out_starts_no_exchange() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    d.sign_out();
    let fx = d.send(Event::OnlineChecked { flow, online: true });
    assert!(!fx.iter().any(|effect| matches!(effect, Effect::RunExchange { .. })));
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Cancelled));
}

#[test]
fn a_current_online_answer_still_starts_the_exchange() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    let fx = d.send(Event::OnlineChecked { flow, online: true });
    assert!(fx.iter().any(|effect| matches!(effect, Effect::RunExchange { .. })));
    let flow = d.begin_sign_in(SignInKind::Password);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    let fx = d.send(Event::OnlineChecked { flow, online: false });
    assert_eq!(sign_in_failure(&fx), Some(AuthFailure::Offline));
}
