//! The MCP connect card's state machine (`McpConnectCardFlow`, CmuxNextHome/McpConnect): the
//! person's choices move it, the daemon's answers move it, and nothing else does. The host sends
//! what each effect names to the acpmux daemon on the person's own connection.
//!
//! The key never comes here: a submit says only whether the key is empty. The tools a connect
//! lists and a failure's reason stay with the host, which pairs them with the `connected` and
//! `failed` phases this answers.

use serde::{Deserialize, Serialize};

/// Where the card is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    /// The facts and Connect / Cancel.
    Ask,
    /// A key server: the private field is shown.
    EnterKey,
    /// The sign-in page is open; cmux waits for it to finish.
    SigningIn,
    /// Approved and signed in; listing the tools.
    Connecting,
    Connected,
    Declined,
    Failed,
}

/// How the server signs in (`McpConnectCard.Auth`, without its scopes and key name).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Auth {
    None,
    Oauth,
    Device,
    Key {
        #[serde(default)]
        optional: bool,
    },
}

/// One step: the person's or the daemon's.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Event {
    /// The person picks who gets the server (only while asking).
    Choose { scope: String },
    /// Connect: approve with the chosen scope, then sign in or ask for the key.
    Connect,
    /// The key from the private field; an empty key connects only an optional-key server.
    Submit { empty: bool },
    /// Cancel (any time before connected).
    Cancel,
    /// The daemon saw the sign-in finish.
    SignedIn,
    /// The daemon connected and listed the tools.
    Connected,
    /// The daemon failed (sign-in refused, server down, metadata refused).
    Failed,
}

/// What the host must send for the step just taken.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Effect {
    /// `_acpmux/mcp_connect_answer {approve: true, scope}`.
    Approve { scope: String },
    /// `_acpmux/mcp_connect_answer {approve: false}`.
    Decline,
    /// `_acpmux/mcp_key_submit` with the key the host holds.
    SubmitKey,
    /// `_acpmux/mcp_auth_begin`, then open the URL it returns in a cmux browser tab.
    BeginSignIn,
}

/// `compose.mcpConnect.step`'s request.
#[derive(Deserialize)]
pub struct StepRequest {
    pub phase: Phase,
    pub scope: String,
    pub auth: Auth,
    pub event: Event,
}

/// The card after the step, and what to send.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Step {
    pub phase: Phase,
    pub scope: String,
    pub effects: Vec<Effect>,
}

/// Takes one step from `phase` with `scope` chosen.
pub fn step(phase: Phase, scope: String, auth: Auth, event: Event) -> Step {
    let (phase, scope, effects) = match event {
        Event::Choose { scope: chosen } if phase == Phase::Ask => (phase, chosen, vec![]),
        Event::Connect if phase == Phase::Ask => {
            let approve = Effect::Approve { scope: scope.clone() };
            match auth {
                Auth::None => (Phase::Connecting, scope, vec![approve]),
                Auth::Oauth | Auth::Device => {
                    (Phase::SigningIn, scope, vec![approve, Effect::BeginSignIn])
                }
                Auth::Key { .. } => (Phase::EnterKey, scope, vec![approve]),
            }
        }
        Event::Submit { empty: true } if phase == Phase::EnterKey => match auth {
            Auth::Key { optional: true } => (Phase::Connecting, scope, vec![]),
            _ => (phase, scope, vec![]),
        },
        Event::Submit { empty: false } if phase == Phase::EnterKey => {
            (Phase::Connecting, scope, vec![Effect::SubmitKey])
        }
        Event::Cancel
            if matches!(
                phase,
                Phase::Ask | Phase::EnterKey | Phase::SigningIn | Phase::Connecting
            ) =>
        {
            (Phase::Declined, scope, vec![Effect::Decline])
        }
        Event::SignedIn if phase == Phase::SigningIn => (Phase::Connecting, scope, vec![]),
        Event::Connected if matches!(phase, Phase::Connecting | Phase::SigningIn) => {
            (Phase::Connected, scope, vec![])
        }
        Event::Failed if !matches!(phase, Phase::Connected | Phase::Declined) => {
            (Phase::Failed, scope, vec![])
        }
        _ => (phase, scope, vec![]),
    };
    Step { phase, scope, effects }
}

#[cfg(test)]
mod tests {
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
}
