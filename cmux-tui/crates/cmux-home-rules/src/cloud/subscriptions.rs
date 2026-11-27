//! `CloudHomeSource+Subscriptions`: one subscription per conversation, the
//! least recently used of 64 making room, and the edit gate on a socket's
//! state. The daemon calls and the lock stay in Swift; it passes the
//! subscription state in and applies the reply.

use super::lease::cloud_id;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// `CloudConversationSubscribeRequest.maxSubscriptions`.
pub const MAX_SUBSCRIPTIONS: usize = 64;

/// A subscribed conversation (`CloudHomeState.Target`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub state: String,
    /// An event set `state`; the subscribe reply no longer may.
    #[serde(default)]
    pub from_event: bool,
}

/// The subscription part of `CloudHomeState`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Subs {
    /// The source's generation now (a reply of an older one is ignored).
    #[serde(default)]
    pub generation: u64,
    #[serde(default)]
    pub targets: BTreeMap<String, Target>,
    /// Least recently used first.
    #[serde(default)]
    pub recent: Vec<String>,
}

/// `subscribe`'s first half under the lock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscribe {
    pub state: Subs,
    /// Send `cloud-conversation-subscribe` for the conversation.
    pub subscribe: bool,
    /// End these first (queued before the subscribe).
    pub unsubscribe: Vec<String>,
}

fn touch(recent: &mut Vec<String>, conversation: &str) {
    recent.retain(|c| c != conversation);
    recent.push(conversation.to_owned());
}

/// `subscribe(_:commands:generation:)` before the call: a subscribed one
/// only moves to most recent; a new one evicts the oldest at the limit.
pub fn subscribe(mut state: Subs, conversation: &str, generation: u64, max: usize) -> Subscribe {
    let mut unsubscribe = Vec::new();
    if state.generation != generation {
        return Subscribe { state, subscribe: false, unsubscribe };
    }
    if state.targets.contains_key(conversation) {
        touch(&mut state.recent, conversation);
        return Subscribe { state, subscribe: false, unsubscribe };
    }
    if state.recent.len() >= max && !state.recent.is_empty() {
        let oldest = state.recent.remove(0);
        state.targets.remove(&oldest);
        unsubscribe.push(oldest);
    }
    state.targets.insert(
        conversation.to_owned(),
        Target { state: "connecting".to_owned(), from_event: false },
    );
    state.recent.push(conversation.to_owned());
    Subscribe { state, subscribe: true, unsubscribe }
}

/// `subscribe`'s reply under the lock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Replied {
    pub state: Subs,
    /// The socket is live: edits refused while it connected go again.
    pub live: bool,
}

/// The subscribe reply: another account's socket is not this account's
/// state, and a state event that came first wins.
pub fn replied(
    mut state: Subs,
    conversation: &str,
    generation: u64,
    reply_state: &str,
    account: Option<&str>,
    identity_cloud_id: Option<&str>,
) -> Replied {
    if let Some(account) = account
        && identity_cloud_id != Some(cloud_id(account).as_str())
    {
        return Replied { state, live: false };
    }
    let fresh = state.generation == generation;
    match state.targets.get_mut(conversation) {
        Some(target) if fresh && !target.from_event => {
            reply_state.clone_into(&mut target.state);
            Replied { live: reply_state == "live", state }
        }
        _ => Replied { state, live: false },
    }
}

/// The subscribe failed: the conversation is forgotten unless an event or
/// a newer generation owns it.
pub fn failed(mut state: Subs, conversation: &str, generation: u64) -> Subs {
    let owned = state.generation == generation
        && state.targets.get(conversation).is_some_and(|t| !t.from_event);
    if owned {
        state.targets.remove(conversation);
        state.recent.retain(|c| c != conversation);
    }
    state
}

/// `requireEditable`'s decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Editable {
    /// Set the source's `degraded` (the socket is not live yet).
    pub degraded: bool,
    /// Subscribe first (no subscription yet).
    pub subscribe: bool,
    /// The refusal: `notAuthorized` (the owner closed it),
    /// `ownerUnreachable` (not live yet), or nil to send.
    pub error: Option<String>,
}

/// `requireEditable`: an edit goes out only while the socket is `live`.
pub fn editable(target: Option<&str>, closed: bool) -> Editable {
    if closed {
        return Editable {
            degraded: false,
            subscribe: false,
            error: Some("notAuthorized".to_owned()),
        };
    }
    let live = target == Some("live");
    Editable {
        degraded: !live,
        subscribe: target.is_none(),
        error: (!live).then(|| "ownerUnreachable".to_owned()),
    }
}
