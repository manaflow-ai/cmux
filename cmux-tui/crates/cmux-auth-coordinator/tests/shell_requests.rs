//! What the Swift shell asks of the reducer outside a flow: a rollback's
//! local sign-out, a team list a team action replaced, and the snapshot
//! fields its remaining runners compare.

mod common;

use cmux_auth_coordinator::{Effect, Event, SignInKind};
use common::{Driver, team, teams};

#[test]
fn a_requested_clear_signs_out_with_its_reason_and_keeps_the_pending_code_when_asked() {
    let mut d = Driver::signed_out();
    d.send(Event::SendCodeStarted);
    d.send(Event::SendCodeFinished { sent: true });
    d.sign_in("u1", Ok(teams(&["t1"])));
    let generation = d.c.session_generation();
    d.clear_log();
    d.send(Event::ClearAuthStateRequested {
        reason: "a validation finished after a sign-out began".into(),
        preserve_pending_code: true,
    });
    assert!(!d.c.is_authenticated());
    assert!(d.c.available_teams().is_empty());
    assert_eq!(d.c.selected_team_id(), None);
    assert!(d.c.session_generation() > generation);
    assert_eq!(d.sign_out_reasons(), vec!["a validation finished after a sign-out began"]);
    assert_eq!(d.c.last_sign_out_reason(), Some("a validation finished after a sign-out began"));
    assert!(d.logged(&Effect::NotifySessionWillTransition));
    assert!(d.logged(&Effect::ClearCachedUser));
    assert!(d.logged(&Effect::ClearSessionCache));
    assert!(!d.logged(&Effect::DropPendingCode));
}

#[test]
fn a_requested_clear_drops_the_pending_code_unless_kept() {
    let mut d = Driver::signed_out();
    d.send(Event::SendCodeStarted);
    d.send(Event::SendCodeFinished { sent: true });
    assert!(d.c.has_pending_code());
    d.clear_log();
    d.send(Event::ClearAuthStateRequested { reason: "test".into(), preserve_pending_code: false });
    assert!(!d.c.has_pending_code());
    assert!(d.logged(&Effect::DropPendingCode));
}

#[test]
fn a_set_team_list_replaces_the_teams_and_publishes_the_scope() {
    let mut d = Driver::signed_out();
    d.sign_in("u1", Ok(teams(&["t1"])));
    let scope_generation = d.c.team_scope_generation();
    d.clear_log();
    d.send(Event::AvailableTeamsSet(vec![team("t1"), team("t2")]));
    let ids: Vec<&str> = d.c.available_teams().iter().map(|team| team.id.as_str()).collect();
    assert_eq!(ids, vec!["t1", "t2"]);
    // The resolved team is unchanged, so the published scope is too.
    assert_eq!(d.c.team_scope_generation(), scope_generation);
    d.send(Event::SetSelectedTeam(Some("t2".into())));
    assert_eq!(d.c.resolved_team_id().as_deref(), Some("t2"));
    assert!(d.c.team_scope_generation() > scope_generation);
}

#[test]
fn the_write_high_water_and_active_flows_follow_a_sign_in() {
    let mut d = Driver::signed_out();
    assert_eq!(d.c.token_store_write_high_water(), 0);
    assert!(!d.c.has_active_sign_in_flows());
    let flow = d.begin_sign_in(SignInKind::Password);
    assert!(d.c.has_active_sign_in_flows());
    assert_eq!(d.c.token_store_write_high_water(), 0);
    d.send(Event::TokenWorkQuiesced { flow, result: Ok(()) });
    d.send(Event::OnlineChecked { flow, online: true });
    d.send(Event::ExchangeFinished { flow, result: Ok(()) });
    assert_eq!(d.c.token_store_write_high_water(), flow.attempt);
    d.send(Event::SignInUserFetched { flow, result: Ok(None) });
    assert!(!d.c.has_active_sign_in_flows());
}
