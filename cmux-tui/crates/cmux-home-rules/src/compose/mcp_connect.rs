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
#[path = "mcp_connect_tests.rs"]
mod tests;
