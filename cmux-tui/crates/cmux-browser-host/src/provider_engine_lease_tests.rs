//! Automation lease review fixes (browser lead v4): agent reads through
//! `frame.observe` never act, and a closed session's late drop leaves a new
//! session of the same name alone.

use super::tests::{FakeApp, calls, leases, session, tab};
use super::*;
use crate::provider::{Frame, LeaseState};

fn state(app: &FakeApp, target: &str) -> Option<LeaseState> {
    leases(app, target).last().cloned().flatten().map(|lease| lease.state)
}

fn evaluate_calls(app: &FakeApp) -> Vec<Value> {
    app.frames
        .lock()
        .unwrap()
        .iter()
        .filter_map(|f| match f {
            Frame::Call { method, params, .. } if method == "frame.evaluate" => {
                Some(params.clone())
            }
            _ => None,
        })
        .collect()
}

/// A second session reads a tab the first one holds; nothing changes the
/// lease, and the app runs the host-written agent call, not caller code.
#[test]
fn observe_on_a_held_tab_from_a_second_session_takes_no_lease() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    let second = session(&provider, "webkit", "s2");
    first.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
    let before = leases(&app, "W").len();
    second
        .call(
            "frame.observe",
            &json!({"targetId": "W", "method": "snapshot", "args": [{}], "source": "evil()"}),
        )
        .unwrap();
    assert_eq!(leases(&app, "W").len(), before, "an observe changes no lease");
    assert_eq!(leases(&app, "W").last().unwrap().as_ref().unwrap().session, "s1");
    let evaluate = evaluate_calls(&app).pop().expect("the app ran the read");
    assert_eq!(evaluate["world"], "agent");
    assert_eq!(evaluate["args"][0], "snapshot");
    assert!(!evaluate["source"].as_str().unwrap().contains("evil"), "{evaluate}");
    // The same read through frame.evaluate is an act and is refused.
    let held = second
        .call("frame.evaluate", &json!({"targetId": "W", "world": "agent", "source": "() => 1"}))
        .unwrap_err();
    assert_eq!(held.error_name.as_deref(), Some("lease_held"), "{held}");
}

/// After the person hands the tab back, an observe is the fresh read the
/// lease asks for; a refused observe is not.
#[test]
fn observe_after_hand_back_lets_the_session_act_again() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    first.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
    app.send(Frame::UserInput { target_id: "W".into() });
    app.send(Frame::LeaseUser { op: "hand_back".into(), target_id: Some("W".into()), actor: None });
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    let evaluations = calls(&app, "frame.evaluate");
    let refused = first
        .call("frame.observe", &json!({"targetId": "W", "method": "fill", "args": [1, "x"]}))
        .unwrap_err();
    assert_eq!(refused.code, crate::protocol::ErrorCode::Forbidden, "{refused}");
    assert_eq!(refused.error_name.as_deref(), Some("observe_not_allowed"), "{refused}");
    assert_eq!(calls(&app, "frame.evaluate"), evaluations, "a refused observe reaches no tab");
    let stale = first.call("input.key", &json!({"targetId": "W"})).unwrap_err();
    assert_eq!(stale.error_name.as_deref(), Some("stale_after_hand_back"), "{stale}");
    first.call("frame.observe", &json!({"targetId": "W", "method": "snapshot"})).unwrap();
    first.call("input.key", &json!({"targetId": "W"})).unwrap();
    assert_eq!(state(&app, "W"), Some(LeaseState::Driving));
}

/// Review P1-b: a reset closes the session and opens the same name again.
/// The old engine's late drop must not clear the new session's lease.
#[test]
fn a_closed_session_late_drop_keeps_the_new_session_lease() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let old = session(&provider, "webkit", "s1");
    old.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
    old.end_session();
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    assert_eq!(leases(&app, "W").last().unwrap(), &None, "close clears the lease at once");
    let new = session(&provider, "webkit", "s1");
    new.call("tab.navigate", &json!({"targetId": "W", "url": "https://c.test/"})).unwrap();
    drop(old);
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    assert_eq!(state(&app, "W"), Some(LeaseState::Driving), "the new lease stays");
    drop(new);
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    assert_eq!(leases(&app, "W").last().unwrap(), &None, "the last drop still ends the session");
}

/// A tab that goes away takes its lease with it (host-local TargetGone).
#[test]
fn a_gone_tab_drops_its_lease() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("X", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    first.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
    app.send(Frame::Event { name: "tab.gone".into(), payload: json!({"targetId": "W"}) });
    provider.call("tab.info", &json!({"targetId": "X"})).unwrap();
    assert_eq!(leases(&app, "W").last().unwrap(), &None);
}

/// lease v2: allow lifts a stop for the stopped principal (actor), so the
/// same agent can act again under any session name.
#[test]
fn allow_from_the_app_lifts_a_stop_by_actor() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    first.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
    app.send(Frame::LeaseUser { op: "stop".into(), target_id: Some("W".into()), actor: None });
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    let renamed = session(&provider, "webkit", "s2");
    let stopped = renamed.call("input.key", &json!({"targetId": "W"})).unwrap_err();
    assert_eq!(stopped.error_name.as_deref(), Some("stopped_by_user"), "{stopped}");
    app.send(Frame::LeaseUser {
        op: "allow".into(),
        target_id: None,
        actor: Some("uid:501".into()),
    });
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    renamed.call("input.key", &json!({"targetId": "W"})).unwrap();
}

/// An observe counts as the fresh read after hand back only when it
/// succeeded: a failed read leaves the next act stale.
#[test]
fn a_failed_observe_is_not_the_fresh_read() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    first.call("tab.navigate", &json!({"targetId": "W", "url": "https://b.test/"})).unwrap();
    app.send(Frame::UserInput { target_id: "W".into() });
    app.send(Frame::LeaseUser { op: "hand_back".into(), target_id: Some("W".into()), actor: None });
    provider.call("tab.info", &json!({"targetId": "W"})).unwrap();
    first.call("tab.info", &json!({"targetId": "W", "failForTest": true})).unwrap_err();
    let stale = first.call("input.key", &json!({"targetId": "W"})).unwrap_err();
    assert_eq!(stale.error_name.as_deref(), Some("stale_after_hand_back"), "{stale}");
    first.call("tab.info", &json!({"targetId": "W"})).unwrap();
    first.call("input.key", &json!({"targetId": "W"})).unwrap();
}
