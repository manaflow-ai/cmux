//! What a peer daemon reads of a session's own words (hq#2509). A summary
//! carries what the person typed and what the agent said (`title`,
//! `lastPrompt`, `preview`, `lastMessage`, the running turn's prompt, the
//! last turn's error), and a peer shows it on another screen, so a
//! connection proven a peer (`peer_auth.rs`) gets those fields masked
//! (`secret_scan`): a pasted token reads `[GitHub Personal Access Token]`.
//! So do a chat's title and preview. The unix socket, the local app and the
//! Web keep the raw text, and so does a peer daemon served as Web (its peer
//! token withheld over plain `ws://`).
//!
//! Queued prompts stay raw: a client edits one starting from its text
//! (`_acpmux/queue_edit`), so a masked one would be written back over it.
//!
//! The exception: `trustedPeers` in config.json names peer devices that get
//! the raw text, empty by default. A connecting daemon names its device in
//! the `x-acpmux-peer-device` upgrade header (its hostname, as `hostname`
//! prints it). The list is read when a peer connects. The name is
//! the peer's own claim: it only picks raw text for a connection already
//! proven a peer by the peer token, which may attach any session and read
//! its transcript anyway. That transcript (`session/update`, `_acpmux/event`,
//! history records, a chat transcript's turns) is not masked here.

use crate::rpc::{Message, method};
use serde_json::Value;

/// The upgrade request header that names the connecting peer's device.
pub const DEVICE_HEADER: &str = "x-acpmux-peer-device";

/// The device name this daemon sends as a peer: its hostname.
pub fn device_name() -> String {
    crate::hand::pair::hostname()
}

/// Whether a connection gets the summaries' text raw: every origin but
/// Peer, and a peer whose one named device is in `trusted`.
pub fn sends_raw(origin: super::Origin, devices: &[String], trusted: &[String]) -> bool {
    origin != super::Origin::Peer
        || matches!(devices, [one] if !one.is_empty() && trusted.iter().any(|t| t == one))
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
                for key in ["title", "lastPrompt", "preview"] {
                    changed |= mask_field(map.get_mut(key));
                }
                changed |= mask_field(map.get_mut("lastMessage").and_then(|m| m.get_mut("text")));
                changed |= mask_field(map.get_mut("turn").and_then(|t| t.get_mut("prompt")));
                changed |= mask_field(map.get_mut("lastTurn").and_then(|t| t.get_mut("errorText")));
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
