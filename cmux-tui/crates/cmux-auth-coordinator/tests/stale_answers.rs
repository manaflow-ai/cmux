//! A late answer is checked against the session it was issued under: team and
//! hook completions (F1), the restore completion (F2) and the online check
//! (F3) of the review of the reducer's first PR, then every other answer: the
//! sign-in flow's quiesce, exchange and user fetch, each team read and each
//! sign-out capture. Swift guards the same writes with `sessionGeneration`,
//! `signOutEpoch` and the flow's attempt.

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

// MARK: - The rest of the class: every answer is checked against what it answers

#[test]
fn a_repeated_exchange_answer_for_a_finished_sign_in_records_no_token() {
    let mut d = Driver::signed_out();
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
    let read = refresh_ticket(&fx).expect("sign-in reads the teams");
    let fx = d.send(Event::TeamsRefreshed { ticket: read, result: Ok(teams(&["t1"])) });
    let hook = hook_ticket(&fx).expect("the hook runs");
    assert!(succeeded(&d.send(Event::PostSignInHookFinished { ticket: hook })));
    let generation = d.c.session_generation();

    assert_eq!(d.send(Event::ExchangeFinished { flow, result: Ok(()) }), vec![]);
    assert_eq!(d.send(Event::ExchangeFinished { flow, result: Err(AuthFailure::Other) }), vec![]);
    assert_eq!(d.c.session_generation(), generation);
    assert!(d.c.is_authenticated());
}

#[test]
fn a_late_user_fetch_for_a_finished_sign_in_publishes_nothing() {
    let mut d = Driver::signed_out();
    let (flow, _) = d.sign_in_through_exchange(SignInKind::Password);
    d.send(Event::SignInUserFetched { flow, result: Err(AuthFailure::TimedOut) });
    assert!(!d.c.is_authenticated());
    let generation = d.c.session_generation();

    let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u9"))) });
    assert_eq!(fx, vec![]);
    assert!(!d.c.is_authenticated());
    assert_eq!(d.c.current_user(), None);
    assert_eq!(d.c.session_generation(), generation);
}

#[test]
fn a_late_user_fetch_cannot_replace_a_newer_sign_ins_user() {
    let mut d = Driver::signed_out();
    let (old, _) = d.sign_in_through_exchange(SignInKind::Password);
    d.send(Event::SignInUserFetched { flow: old, result: Err(AuthFailure::Cancelled) });
    d.sign_in("u2", Ok(teams(&["t2"])));
    let generation = d.c.session_generation();
    let scope = d.c.team_scope();

    let fx = d.send(Event::SignInUserFetched { flow: old, result: Ok(Some(user("u1"))) });
    assert_eq!(fx, vec![]);
    assert_eq!(d.c.current_user(), Some(&user("u2")));
    assert_eq!(d.c.session_generation(), generation);
    assert_eq!(d.c.team_scope(), scope);
}

#[test]
fn a_repeated_quiesce_answer_for_a_finished_external_sign_in_starts_nothing() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::External);
    let fx = d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    assert!(fx.contains(&Effect::FetchUser(flow)), "the current answer is applied");
    d.send(Event::SignInUserFetched { flow, result: Ok(None) });
    assert!(!d.c.is_loading());

    assert_eq!(d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) }), vec![]);
    assert!(!d.c.is_loading());
}

#[test]
fn an_answer_whose_flow_differs_from_the_registered_one_is_dropped() {
    let mut d = Driver::signed_out();
    let flow = d.begin_sign_in(SignInKind::Password);
    let forged = SignInFlow { generation: flow.generation + 1, ..flow };
    assert_eq!(d.send(Event::TokenWorkQuiesced { flow: forged, result: Ok(()) }), vec![]);
    let forged = SignInFlow { kind: SignInKind::External, ..flow };
    assert_eq!(d.send(Event::TokenWorkQuiesced { flow: forged, result: Ok(()) }), vec![]);
    let fx = d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    assert_eq!(fx, vec![Effect::CheckOnline(flow)], "the registered flow still proceeds");
}

#[test]
fn a_repeated_team_answer_does_not_end_another_reads_count() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let first = refresh_ticket(&d.send(Event::TeamsRequested)).expect("a read");
    let second = refresh_ticket(&d.send(Event::TeamsRequested)).expect("a read");
    assert_ne!(first.id, second.id);

    let fx = d.send(Event::TeamsRefreshed { ticket: first, result: Ok(teams(&["t1", "t2"])) });
    assert!(fx.contains(&Effect::SessionCheckSucceeded));
    let repeat = d.send(Event::TeamsRefreshed { ticket: first, result: Ok(teams(&["t9"])) });
    assert_eq!(repeat, vec![]);
    assert_eq!(d.c.available_teams().len(), 2, "the repeat did not apply its list");

    let fx = d.send(Event::TeamsRefreshed { ticket: second, result: Ok(teams(&["t3"])) });
    assert!(fx.contains(&Effect::SessionCheckSucceeded), "the other read is still applied");
    assert_eq!(d.c.available_teams(), &[common::team("t3")]);
}

#[test]
fn a_repeated_team_failure_cannot_start_recovery_while_a_read_is_in_flight() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Err(AuthFailure::NetworkError));
    // The sign-in's read failed, so recovery is pending. A fresh read is in
    // flight when an answer for a read never issued arrives.
    let read = refresh_ticket(&d.send(Event::TeamsRequested)).expect("a read");
    assert!(!d.c.needs_team_scope_recovery(), "a read is in flight");
    let stale = TeamRefreshTicket { id: read.id + 100, ..read };
    let fx = d.send(Event::TeamsRefreshed { ticket: stale, result: Err(AuthFailure::Other) });
    assert_eq!(fx, vec![]);
    assert!(!d.c.needs_team_scope_recovery(), "the unknown answer did not end the read");
    d.send(Event::TeamsRefreshed { ticket: read, result: Ok(teams(&["t1"])) });
    assert!(d.c.team_scope().is_some());
}

#[test]
fn a_late_local_clear_of_an_older_sign_out_does_not_sign_out_a_newer_session() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    d.send(Event::SignOutRequested);
    let first_epoch = d.c.sign_out_revision();
    d.send(Event::SignOutRequested);
    // The older capture answers while the newer one still runs: only its
    // server teardown runs, and the capture stays open for the newer one.
    let fx = d.send(Event::SignOutLocalCleared { sign_out_epoch: first_epoch });
    assert_eq!(fx, vec![Effect::WaitForPostSignInHooks { runs: vec![] }, Effect::ServerTeardown]);
    assert!(d.c.session_token_transition_is_active());
    assert_eq!(d.c.published_session_identity(), None);
    let fx = d.local_cleared();
    assert_eq!(fx[0], Effect::EndSignOutCredentialCapture, "the current answer is applied");
    assert!(!d.c.is_authenticated());
    assert!(!d.c.session_token_transition_is_active());

    d.sign_in("u2", Ok(teams(&["t2"])));
    let generation = d.c.session_generation();
    assert_eq!(d.send(Event::SignOutLocalCleared { sign_out_epoch: first_epoch }), vec![]);
    assert_eq!(d.local_cleared(), vec![], "a repeat of the latest capture's answer too");
    assert!(d.c.is_authenticated());
    assert_eq!(d.c.current_user(), Some(&user("u2")));
    assert_eq!(d.c.session_generation(), generation);
}

#[test]
fn an_older_capture_answering_last_ends_the_capture() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    d.send(Event::SignOutRequested);
    let first_epoch = d.c.sign_out_revision();
    d.send(Event::SignOutRequested);
    let fx = d.local_cleared();
    assert!(!fx.contains(&Effect::EndSignOutCredentialCapture), "the older capture is open");
    assert!(d.c.session_token_transition_is_active());
    let fx = d.send(Event::SignOutLocalCleared { sign_out_epoch: first_epoch });
    assert_eq!(
        fx,
        vec![
            Effect::EndSignOutCredentialCapture,
            Effect::WaitForPostSignInHooks { runs: vec![] },
            Effect::ServerTeardown
        ]
    );
    assert!(!d.c.session_token_transition_is_active());
    assert!(!d.c.is_authenticated());
}

// MARK: - Property: an answer delivered again changes nothing

/// What the coordinator shows the app.
fn snapshot(d: &Driver) -> String {
    format!(
        "{:?} {:?} {} {} {:?} {:?} {:?} {} {} {}",
        d.c.state(),
        d.c.current_user().map(|user| user.id.clone()),
        d.c.session_generation(),
        d.c.sign_out_revision(),
        d.c.team_scope(),
        d.c.available_teams(),
        d.c.selected_team_id(),
        d.c.is_loading(),
        d.c.needs_team_scope_recovery(),
        d.c.session_token_transition_is_active(),
    )
}

/// An event that answers an effect (not a request a person or the OS makes).
fn is_answer(event: &Event) -> bool {
    !matches!(
        event,
        Event::Restore(_)
            | Event::SignInRequested { .. }
            | Event::TeamsRequested
            | Event::SetSelectedTeam(_)
            | Event::TeamSelectionMutated
            | Event::TeamListMutated
            | Event::SendCodeStarted
            | Event::SendCodeFinished { .. }
            | Event::DebugCredentialsRemembered
            | Event::SignOutRequested
            | Event::TokenReadUnauthorized(_)
            | Event::TokenReadEmpty { .. }
            | Event::PhaseStartRequested { .. }
            | Event::SupersedeTimedOutPhases
            | Event::DevAuthAccessTokenFinished { .. }
            | Event::TeamScopeRecoveryDue { .. }
            | Event::TeamScopeRecoveryCheckFinished { .. }
    )
}

/// Each scenario runs to its end; then every answer it consumed is sent
/// again, in order and then in seeded shuffles, and must return no effect
/// and change nothing a caller can see.
#[test]
fn every_consumed_answer_delivered_again_changes_nothing() {
    let scenarios: Vec<fn(&mut Driver)> = vec![
        |d| {
            d.sign_in("u1", Ok(teams(&["t1"])));
        },
        |d| {
            d.sign_in("u1", Err(AuthFailure::RateLimited { retry_after: None }));
        },
        |d| {
            d.sign_in("u1", Ok(teams(&["t1"])));
            d.sign_out();
            d.sign_in("u2", Ok(teams(&["t2"])));
        },
        |d| {
            let (flow, _) = d.sign_in_through_exchange(SignInKind::Oauth);
            d.sign_out();
            d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
            d.sign_in("u2", Ok(teams(&["t2"])));
        },
        |d| {
            let flow = d.begin_sign_in(SignInKind::External);
            let fx = d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
            assert!(fx.contains(&Effect::FetchUser(flow)));
            let fx = d.send(Event::SignInUserFetched { flow, result: Ok(Some(user("u1"))) });
            let read = refresh_ticket(&fx).expect("a read");
            let fx = d.send(Event::TeamsRefreshed { ticket: read, result: Ok(teams(&["t1"])) });
            let hook = hook_ticket(&fx).expect("a hook");
            d.send(Event::PostSignInHookFinished { ticket: hook });
        },
        |d| {
            let ticket = d.start_restore(RestoreTrigger::Launch);
            d.probe(ticket, true);
            let fx = d.send(Event::CachedSessionValidated { ticket, result: Ok(Some(user("u1"))) });
            let read = refresh_ticket(&fx).expect("a read");
            let fx = d.send(Event::TeamsRefreshed { ticket: read, result: Ok(teams(&["t1"])) });
            if let Some(hook) = hook_ticket(&fx) {
                d.send(Event::PostSignInHookFinished { ticket: hook });
            }
        },
    ];
    let mut rng: u64 = 0x9e37_79b9_7f4a_7c15;
    for (index, scenario) in scenarios.into_iter().enumerate() {
        let mut d = if index == 5 { Driver::cached("u1") } else { Driver::signed_out() };
        scenario(&mut d);
        let answers: Vec<Event> = d.events.iter().filter(|e| is_answer(e)).cloned().collect();
        assert!(!answers.is_empty());
        let before = snapshot(&d);
        for round in 0..8 {
            let mut order = answers.clone();
            if round > 0 {
                for i in (1..order.len()).rev() {
                    rng ^= rng << 13;
                    rng ^= rng >> 7;
                    rng ^= rng << 17;
                    order.swap(i, (rng % (i as u64 + 1)) as usize);
                }
            }
            for answer in order {
                let fx = d.send(answer.clone());
                assert_eq!(fx, vec![], "scenario {index}: {answer:?} applied twice");
                assert_eq!(snapshot(&d), before, "scenario {index}: {answer:?} changed state");
            }
        }
    }
}
