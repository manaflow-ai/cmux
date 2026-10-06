//! The daemon's cloud events (home-cloud-proxy.md section 5) as what the
//! brain needs: a change of its conversation, a resync, the upstream socket's
//! state, or a request for a new lease. Ids come out in the brain's shape.

use cmux_conversation::{Change, Message, Summary};
use serde_json::Value;

use super::idmap::to_brain;

pub enum CloudSignal {
    Changed(Change),
    /// The proxy replaced its view (first subscription, resume by snapshot,
    /// or a gap): the summary and the snapshot tail.
    Resynced {
        summary: Summary,
        messages: Vec<Message>,
    },
    /// The upstream socket of this conversation: `live` or not.
    State {
        live: bool,
        state: String,
        reason: Option<String>,
    },
    /// `cloud-session-needed`: mint and lease a new chief token now.
    SessionNeeded(String),
}

/// Maps one event line; None for events of other conversations or kinds.
pub fn map_event(raw: &Value, conversation: &str, chief: &str) -> Option<CloudSignal> {
    let name = raw.get("event")?.as_str()?;
    let ours = || raw.get("conversation").and_then(Value::as_str) == Some(conversation);
    match name {
        "cloud-conversation-changed" if ours() => {
            let mut change = raw.get("change")?.clone();
            to_brain(&mut change, chief);
            decode_change(change).map(CloudSignal::Changed)
        }
        "cloud-conversation-resynced" if ours() => {
            let mut summary = raw.get("summary")?.clone();
            to_brain(&mut summary, chief);
            let summary = decode_summary(summary)?;
            let messages = raw
                .get("messages")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(|m| decode_message(m.clone(), chief))
                        .collect()
                })
                .unwrap_or_default();
            Some(CloudSignal::Resynced { summary, messages })
        }
        "cloud-subscription-state"
            if raw.get("scope").and_then(Value::as_str) == Some("conversation") && ours() =>
        {
            let state = raw.get("state")?.as_str()?.to_owned();
            Some(CloudSignal::State {
                live: state == "live",
                reason: raw.get("reason").and_then(Value::as_str).map(str::to_owned),
                state,
            })
        }
        "cloud-session-needed" => Some(CloudSignal::SessionNeeded(
            raw.get("reason")
                .and_then(Value::as_str)
                .unwrap_or("missing")
                .to_owned(),
        )),
        _ => None,
    }
}

/// A message in cloud shape, ids rewritten. A part this brain cannot read
/// (an image, a file) is dropped rather than losing the whole message.
pub fn decode_message(mut value: Value, chief: &str) -> Option<Message> {
    to_brain(&mut value, chief);
    if let Ok(message) = serde_json::from_value::<Message>(value.clone()) {
        return Some(message);
    }
    let parts = value.get_mut("parts")?.as_array_mut()?;
    parts.retain(|p| matches!(p.get("type").and_then(Value::as_str), Some("text" | "work")));
    serde_json::from_value(value).ok()
}

/// A summary already in brain shape; its last message decoded leniently.
pub fn decode_summary(mut value: Value) -> Option<Summary> {
    if let Some(parts) = value
        .pointer_mut("/last_message/parts")
        .and_then(Value::as_array_mut)
    {
        parts.retain(|p| matches!(p.get("type").and_then(Value::as_str), Some("text" | "work")));
    }
    serde_json::from_value(value).ok()
}

fn decode_change(mut value: Value) -> Option<Change> {
    if let Ok(change) = serde_json::from_value::<Change>(value.clone()) {
        return Some(change);
    }
    for key in ["message", "conversation"] {
        if let Some(inner) = value.get_mut(key) {
            let target = if key == "conversation" {
                inner.get_mut("last_message")
            } else {
                Some(inner)
            };
            if let Some(parts) = target
                .and_then(|m| m.get_mut("parts"))
                .and_then(Value::as_array_mut)
            {
                parts.retain(|p| {
                    matches!(p.get("type").and_then(Value::as_str), Some("text" | "work"))
                });
            }
        }
    }
    serde_json::from_value(value).ok()
}
