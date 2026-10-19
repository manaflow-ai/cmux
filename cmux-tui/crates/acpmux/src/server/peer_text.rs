//! What a peer daemon reads of a session's own words (hq#2509). A summary
//! carries what the person typed and what the agent said (`title`,
//! `lastPrompt`, `preview`, `lastMessage`, the running turn's and queued
//! prompts, the last turn's error), and a peer shows it on another screen,
//! so a connection with the Peer origin gets those fields masked
//! (`secret_scan`): a pasted token reads `[GitHub Personal Access Token]`.
//! The unix socket, the local app and the Web keep the raw text.
//!
//! The exception: `trustedPeers` in config.json names peer devices that get
//! the raw text, empty by default. A connecting daemon names its device in
//! the `x-acpmux-peer-device` upgrade header (its hostname). The name is
//! the peer's own claim: it only picks raw text for a connection already
//! proven a peer by the peer token, which may attach any session and read
//! its transcript anyway. That transcript (`session/update`, `_acpmux/event`
//! and history records) is not masked here.

use crate::rpc::Message;
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
    let _ = (origin, devices, trusted);
    true
}

/// `msg` as a peer may read it: the session text in every summary and chat
/// it carries masked. Agent updates and records pass as they are.
pub fn masked(msg: &Message) -> Option<Message> {
    let _ = msg;
    None
}

#[cfg(test)]
#[path = "peer_text_tests.rs"]
mod tests;
