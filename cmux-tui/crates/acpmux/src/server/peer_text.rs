//! What a peer daemon reads of a session's own words (hq#2509). A summary
//! carries what the person typed and what the agent said (`title`,
//! `lastPrompt`, `preview`, `lastMessage`, the running turn's and queued
//! prompts, the last turn's error), and a peer shows it on another screen,
//! so a connection proven a peer (`peer_auth.rs`) gets those fields masked
//! (`secret_scan`): a pasted token reads `[GitHub Personal Access Token]`.
//! So do a chat's title and preview. The unix socket, the local app and the
//! Web keep the raw text, and so does a peer daemon served as Web (its peer
//! token withheld over plain `ws://`). Every peer is masked: the peer token
//! is one per launch, shared by every peer, so nothing here tells one peer
//! from another to trust.
//!
//! A peer may not rewrite a queued prompt that holds a secret
//! (`server/requests.rs`, `Hub::queued_holds_secret`): its edit would start
//! from the masked text and write the mask over the secret, and putting the
//! secret back would let it move one where a later summary no longer masks
//! it. It may still move, send or remove one.
//!
//! Only these summary fields are masked. What the session itself says
//! (`session/update`, `_acpmux/event`, history records, a chat transcript's
//! turns, tool output) still reaches a peer raw.

use crate::rpc::{Message, method};
use serde_json::Value;

/// Whether a connection reads session text masked: a peer's.
pub fn masks(origin: super::Origin) -> bool {
    origin == super::Origin::Peer
}

/// `msg` as a peer may read it: the session text in every summary and chat
/// it carries masked. Agent updates and records pass as they are.
/// None when nothing in it changed.
pub fn masked(msg: &Message) -> Option<Message> {
    match msg {
        Message::Notification { method, params: Some(params) }
            if method != method::SESSION_UPDATE && method != method::MUX_EVENT =>
        {
            let mut params = params.clone();
            mask_text(&mut params)
                .then(|| Message::Notification { method: method.clone(), params: Some(params) })
        }
        Message::Response { id, result: Some(result), error } => {
            let mut result = result.clone();
            mask_text(&mut result).then(|| Message::Response {
                id: id.clone(),
                result: Some(result),
                error: error.clone(),
            })
        }
        _ => None,
    }
}

/// How much of one field a peer reads: a prompt may be megabytes, and
/// masking all of it for every summary sent would stall the connection.
const PEER_TEXT_CHARS: usize = 16_384;
/// How much of a field is scanned: past the cut, so a secret that starts
/// before it is still whole when it is masked.
const PEER_SCAN_CHARS: usize = PEER_TEXT_CHARS + 4096;

/// Masks the session text of every summary and chat in `v`; whether any changed.
fn mask_text(v: &mut Value) -> bool {
    let mut changed = false;
    match v {
        Value::Array(items) => items.iter_mut().for_each(|item| changed |= mask_text(item)),
        Value::Object(map) => {
            if SUMMARY_KEYS.iter().all(|k| map.contains_key(*k)) {
                // Peers may learn liveness and its class, never new diagnostic details.
                changed |= map.remove("stuckError").is_some();
                changed |= map.remove("stuckSince").is_some();
                for key in ["title", "lastPrompt", "preview"] {
                    changed |= mask_field(map.get_mut(key));
                }
                changed |= mask_field(map.get_mut("lastMessage").and_then(|m| m.get_mut("text")));
                changed |= mask_field(map.get_mut("waitingPrompt"));
                if let Some(turn) = map.get_mut("turn") {
                    // What it does now: a tool call's title, often a command with its arguments.
                    for key in ["prompt", "activity", "planStep"] {
                        changed |= mask_field(turn.get_mut(key));
                    }
                }
                changed |= mask_field(map.get_mut("lastTurn").and_then(|t| t.get_mut("errorText")));
                if let Some(Value::Array(queue)) = map.get_mut("queue") {
                    for queued in queue {
                        changed |= mask_field(queued.get_mut("prompt"));
                    }
                }
            } else if map.contains_key("attention") || map.contains_key("turns") {
                // A chat (`chats/activity.rs`) or its transcript: its harness title and preview.
                for key in ["title", "preview"] {
                    changed |= mask_field(map.get_mut(key));
                }
            } else if map.get("_meta").and_then(|m| m.get("acpmux")).is_some_and(is_summary) {
                // An ACP `session/list` entry: its title is the summary's.
                changed |= mask_field(map.get_mut("title"));
            }
            map.values_mut().for_each(|child| changed |= mask_text(child));
        }
        _ => {}
    }
    changed
}

/// The keys every session summary has (`Hub::session_summary`), this daemon's or a peer's.
const SUMMARY_KEYS: [&str; 3] = ["sessionId", "harness", "lastSeq"];

fn is_summary(v: &Value) -> bool {
    SUMMARY_KEYS.iter().all(|k| v.get(*k).is_some())
}

fn mask_field(field: Option<&mut Value>) -> bool {
    let Some(Value::String(text)) = field else { return false };
    let long = text.chars().nth(PEER_TEXT_CHARS).is_some();
    let head: String =
        if long { text.chars().take(PEER_SCAN_CHARS).collect() } else { text.clone() };
    let mut masked = crate::secret_scan::mask(&head);
    if long {
        masked = masked.chars().take(PEER_TEXT_CHARS).collect();
        masked.push('…');
    }
    if masked == *text {
        return false;
    }
    *text = masked;
    true
}

#[cfg(test)]
#[path = "peer_text_tests.rs"]
mod tests;
