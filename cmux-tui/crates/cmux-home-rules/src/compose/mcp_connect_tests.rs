use super::*;
use serde_json::json;

fn run(auth: Auth, events: Vec<Event>) -> (Phase, String, Vec<Vec<Effect>>) {
    let (mut phase, mut scope, mut all) = (Phase::Ask, "chat".to_string(), vec![]);
    for event in events {
        let next = step(phase, scope, auth, event);
        (phase, scope) = (next.phase, next.scope);
        all.push(next.effects);
    }
    (phase, scope, all)
}

fn approve(scope: &str) -> Effect {
    Effect::Approve { scope: scope.into() }
}

#[test]
fn oauth_approves_with_the_chosen_scope_then_signs_in() {
    let events = vec![
        Event::Choose { scope: "chief".into() },
        Event::Connect,
        Event::SignedIn,
        Event::Connected,
    ];
    let (phase, scope, effects) = run(Auth::Oauth, events);
    assert_eq!((phase, scope.as_str()), (Phase::Connected, "chief"));
    assert_eq!(effects[1], vec![approve("chief"), Effect::BeginSignIn]);
    assert!(effects[2].is_empty() && effects[3].is_empty());
}

#[test]
fn scope_changes_only_while_asking() {
    let (phase, scope, _) =
        run(Auth::Device, vec![Event::Connect, Event::Choose { scope: "agents".into() }]);
    assert_eq!((phase, scope.as_str()), (Phase::SigningIn, "chat"));
}

#[test]
fn none_connects_straight_away() {
    let (phase, _, effects) = run(Auth::None, vec![Event::Connect]);
    assert_eq!((phase, effects), (Phase::Connecting, vec![vec![approve("chat")]]));
}

#[test]
fn a_required_key_waits_for_a_key() {
    let auth = Auth::Key { optional: false };
    let (phase, _, effects) = run(auth, vec![Event::Connect, Event::Submit { empty: true }]);
    assert_eq!((phase, effects[1].clone()), (Phase::EnterKey, vec![]));
    let (phase, _, effects) =
        run(auth, vec![Event::Connect, Event::Submit { empty: false }, Event::Connected]);
    assert_eq!((phase, effects[1].clone()), (Phase::Connected, vec![Effect::SubmitKey]));
}

#[test]
fn an_optional_key_connects_without_one() {
    let (phase, _, effects) =
        run(Auth::Key { optional: true }, vec![Event::Connect, Event::Submit { empty: true }]);
    assert_eq!((phase, effects[1].clone()), (Phase::Connecting, vec![]));
}

#[test]
fn submit_outside_the_key_step_does_nothing() {
    let (phase, _, effects) =
        run(Auth::Key { optional: false }, vec![Event::Submit { empty: false }]);
    assert_eq!((phase, effects[0].clone()), (Phase::Ask, vec![]));
}

#[test]
fn cancel_declines_until_connected() {
    for events in [vec![], vec![Event::Connect], vec![Event::Connect, Event::SignedIn]] {
        let mut events = events;
        events.push(Event::Cancel);
        let (phase, _, effects) = run(Auth::Oauth, events);
        assert_eq!(
            (phase, effects.last().unwrap().clone()),
            (Phase::Declined, vec![Effect::Decline])
        );
    }
    let (phase, _, effects) =
        run(Auth::None, vec![Event::Connect, Event::Connected, Event::Cancel]);
    assert_eq!((phase, effects[2].clone()), (Phase::Connected, vec![]));
    let (phase, _, effects) = run(Auth::None, vec![Event::Cancel, Event::Cancel]);
    assert_eq!((phase, effects[1].clone()), (Phase::Declined, vec![]));
}

#[test]
fn signed_in_and_connected_need_their_phase() {
    assert_eq!(run(Auth::None, vec![Event::SignedIn]).0, Phase::Ask);
    assert_eq!(run(Auth::None, vec![Event::Connected]).0, Phase::Ask);
    assert_eq!(run(Auth::Oauth, vec![Event::Connect, Event::Connected]).0, Phase::Connected);
    assert_eq!(
        run(Auth::Key { optional: false }, vec![Event::Connect, Event::Connected]).0,
        Phase::EnterKey
    );
}

#[test]
fn failure_lands_unless_connected_or_declined() {
    assert_eq!(run(Auth::Oauth, vec![Event::Failed]).0, Phase::Failed);
    assert_eq!(run(Auth::Oauth, vec![Event::Connect, Event::Failed]).0, Phase::Failed);
    assert_eq!(
        run(Auth::Oauth, vec![Event::Connect, Event::Failed, Event::Failed]).0,
        Phase::Failed
    );
    assert_eq!(
        run(Auth::None, vec![Event::Connect, Event::Connected, Event::Failed]).0,
        Phase::Connected
    );
    assert_eq!(run(Auth::None, vec![Event::Cancel, Event::Failed]).0, Phase::Declined);
}

#[test]
fn wire() {
    let request = json!({"phase": "ask", "scope": "everywhere", "auth": {"kind": "oauth"}, "event": {"kind": "connect"}});
    let reply = crate::compose::call("mcpConnect.step", &request).unwrap();
    let effects = json!([{"kind": "approve", "scope": "everywhere"}, {"kind": "beginSignIn"}]);
    assert_eq!(reply, json!({"phase": "signingIn", "scope": "everywhere", "effects": effects}));
    let request = json!({"phase": "enterKey", "scope": "chat", "auth": {"kind": "key", "optional": true},
                         "event": {"kind": "submit", "empty": false}});
    let reply = crate::compose::call("mcpConnect.step", &request).unwrap();
    assert_eq!(
        reply,
        json!({"phase": "connecting", "scope": "chat", "effects": [{"kind": "submitKey"}]})
    );
}
