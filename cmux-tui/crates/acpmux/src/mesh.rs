//! The mesh relay: a send reaches a session on any host by name, through a team hub
//! (cmux-platform), with no ssh peer list and no tailnet. This module is the hub's shape as the
//! daemon sees it: [`MeshHub`], which the HTTPS client implements and tests fake, and the
//! records it carries. `server/mesh_relay.rs` runs the daemon's side: it long-polls its inbox,
//! delivers each message into the session it names as a local send does, and acks with the prompt
//! id.
//!
//! Delivery is at least once: a message stays leased until acked and comes back when its lease
//! ends. The prompt id of a delivery is the message id, so a message delivered twice runs once
//! (`hub/prompt_ledger.rs`).

use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

/// Whom a message is for: a session name (on its own or as `host/name`) or a session id.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

/// Who sent a message, as the sending daemon named it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sender {
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default)]
    pub host: String,
}

/// When a message reaches a busy session: after its turn (`turn-end`), or into the running
/// turn (`now`, a steer), as `acpmux send` and `--steer` do.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    #[default]
    TurnEnd,
    Now,
}

/// A message this daemon's inbox holds for one of its sessions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InMessage {
    pub message_id: String,
    #[serde(default)]
    pub to: Target,
    #[serde(default)]
    pub from: Sender,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub mode: Mode,
    /// Which lease of the message this is (1 for the first).
    #[serde(default)]
    pub attempt: u32,
    /// `control` for a start, resume or stop ([`ControlHook`]); none for a message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control: Option<Value>,
}

impl InMessage {
    pub fn is_control(&self) -> bool {
        self.kind.as_deref() == Some("control")
    }
}

/// How a delivery settled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AckState {
    Delivered,
    Refused,
}

/// The ack of one message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ack {
    pub state: AckState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl Ack {
    pub fn delivered(prompt_id: &str, detail: Option<String>) -> Self {
        Self { state: AckState::Delivered, prompt_id: Some(prompt_id.to_owned()), detail }
    }

    pub fn refused(detail: impl Into<String>) -> Self {
        Self { state: AckState::Refused, prompt_id: None, detail: Some(detail.into()) }
    }
}

/// A failed hub call. `refused`: the hub answered and said no (a 4xx other than a timeout or a
/// rate limit), so the same call fails the same way; else the hub may answer later.
#[derive(Debug, Clone, PartialEq)]
pub struct HubError {
    pub message: String,
    pub refused: bool,
}

impl HubError {
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self { message: message.into(), refused: false }
    }

    pub fn refused(message: impl Into<String>) -> Self {
        Self { message: message.into(), refused: true }
    }
}

impl std::fmt::Display for HubError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for HubError {}

/// The hub, as one daemon (its `daemonId` and credential are the implementation's) calls it.
pub trait MeshHub: Send + Sync {
    /// This daemon's leased messages, waiting up to `wait` for one.
    fn inbox(&self, wait: Duration) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>>;
    fn ack<'a>(&'a self, message_id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>>;
}

/// What runs a control message (start, resume or stop a session). The daemon applies its own
/// rules for that origin, exactly as for a peer's request; the hub grants nothing. None leaves
/// the message unacked (its lease ends and it comes back).
pub trait ControlHook: Send + Sync {
    fn control<'a>(
        &'a self,
        hub: &'a Arc<crate::hub::Hub>,
        message: &'a InMessage,
    ) -> BoxFuture<'a, Option<Ack>>;
}

/// The control hook of a daemon that runs no control messages: each one is refused.
pub struct RefuseControl;

impl ControlHook for RefuseControl {
    fn control<'a>(
        &'a self,
        _hub: &'a Arc<crate::hub::Hub>,
        _message: &'a InMessage,
    ) -> BoxFuture<'a, Option<Ack>> {
        Box::pin(async { Some(Ack::refused("this daemon runs no control messages")) })
    }
}

/// The waits after consecutive failures: doubling from `first` to `cap`, each with up to a
/// fifth taken off at random, so daemons that lost the hub together do not return together.
#[derive(Debug, Clone)]
pub struct Backoff {
    first: Duration,
    cap: Duration,
    next: Duration,
}

impl Backoff {
    pub fn new(first: Duration, cap: Duration) -> Self {
        Self { first, cap, next: first }
    }

    pub fn reset(&mut self) {
        self.next = self.first;
    }

    pub fn next_wait(&mut self) -> Duration {
        let wait = self.next;
        self.next = (self.next * 2).min(self.cap);
        let fifth = wait.as_millis() as u64 / 5;
        let jitter = if fifth == 0 { 0 } else { uuid::Uuid::now_v7().as_u128() as u64 % fifth };
        wait.saturating_sub(Duration::from_millis(jitter))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn records_read_and_write_the_hubs_field_names() {
        let message: InMessage = serde_json::from_value(json!({
            "messageId": "m-1", "to": {"name": "dep-land"},
            "from": {"name": "lane-a", "sessionId": "s-1", "host": "gcp-codex-lane-3"},
            "body": "hi", "mode": "now", "attempt": 2,
        }))
        .unwrap();
        assert_eq!(message.mode, Mode::Now);
        assert_eq!(message.to.name.as_deref(), Some("dep-land"));
        assert!(!message.is_control());
        let ack = serde_json::to_value(Ack::delivered("m-1", None)).unwrap();
        assert_eq!(ack, json!({"state": "delivered", "promptId": "m-1"}));
        let ack = serde_json::to_value(Ack::refused("no")).unwrap();
        assert_eq!(ack, json!({"state": "refused", "detail": "no"}));
        let mode = serde_json::to_value(Mode::TurnEnd).unwrap();
        assert_eq!(mode, json!("turn-end"));
    }

    #[test]
    fn backoff_doubles_to_its_cap_and_starts_over_after_a_success() {
        let mut b = Backoff::new(Duration::from_secs(1), Duration::from_secs(8));
        let waits: Vec<_> = (0..6).map(|_| b.next_wait()).collect();
        let bounds = [1, 2, 4, 8, 8, 8];
        for (wait, top) in waits.iter().zip(bounds) {
            let top = Duration::from_secs(top);
            assert!(*wait <= top && *wait >= top * 4 / 5, "{wait:?} for {top:?}");
        }
        b.reset();
        assert!(b.next_wait() <= Duration::from_secs(1));
    }
}
