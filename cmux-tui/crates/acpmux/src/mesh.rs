//! The mesh relay: a send reaches a session on any host by name, through a team hub
//! (cmux-platform), with no ssh peer list and no tailnet. This module is the hub's shape as the
//! daemon sees it: [`MeshHub`], which the HTTPS client implements and tests fake, and the
//! records it carries (cmux-platform `openapi.json` 1.3.0, `/v1/mesh`). `server/mesh_relay.rs`
//! runs the daemon's side: it heartbeats its sessions, long-polls its inbox, delivers each message
//! into the session it names as a local send does, acks with the prompt id, and posts the sends
//! this daemon's sessions make to a name no one here resolves. `mesh_http.rs` is the HTTPS client.
//!
//! Delivery is at least once: a message stays leased until acked and comes back when its lease
//! ends. The prompt id of a delivery is the message id, so a message delivered twice runs once
//! (`hub/prompt_ledger.rs`).

use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;

/// One session as the address book lists it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    pub name: String,
    pub session_id: String,
    pub harness: String,
    /// `idle`, `ready`, `running`, `waiting` or `disconnected` (`store::SessionStatus`).
    pub state: String,
    /// Why a session whose harness keeps failing is stuck, once the daemon reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stuck_reason: Option<String>,
}

/// A heartbeat: it replaces this daemon's sessions in the address book.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Heartbeat {
    pub host: String,
    pub sessions: Vec<SessionRow>,
}

/// The most sessions one heartbeat lists.
pub const MAX_HEARTBEAT_SESSIONS: usize = 256;

/// The hub took a heartbeat: this daemon's rows expire `ttlSeconds` after it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatReply {
    #[serde(default)]
    pub daemon_id: String,
    pub ttl_seconds: u64,
}

/// Whom a message is for: a session id, or a name (with `host` when several hosts have it); a
/// daemon (`daemonId`, or `host` alone) for a control message. The hub fills what it resolved.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_id: Option<String>,
}

/// Who sent a message: the session as its daemon named it; the hub adds the daemon id and the
/// user from the sender's token.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sender {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
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

/// A message's kind: text for a session, or a request to its daemon (start, resume or stop a
/// session, [`ControlHook`]). A kind this build does not know is refused.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    #[default]
    Prompt,
    Control,
    #[serde(other)]
    Unknown,
}

/// A message this daemon's inbox holds for one of its sessions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InMessage {
    pub message_id: String,
    /// Required: a message without one is malformed, never taken for a prompt.
    pub kind: Kind,
    /// A control message's request: `start`, `resume` or `stop`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<String>,
    #[serde(default)]
    pub mode: Mode,
    #[serde(default)]
    pub to: Target,
    #[serde(default)]
    pub from: Sender,
    #[serde(default)]
    pub body: String,
    /// How many times it was leased (1 for the first).
    #[serde(default)]
    pub attempt: u32,
}

/// A message to post.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutMessage {
    pub to: Target,
    pub from: Sender,
    pub kind: Kind,
    pub body: String,
    pub mode: Mode,
    /// The sender's prompt id: the same send posted again is the same message.
    pub idempotency_key: String,
}

/// A message's receipt: `queued`, `leased`, `delivered`, `refused` or `expired`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub message_id: String,
    pub state: String,
    #[serde(default)]
    pub to: Target,
    #[serde(default)]
    pub attempt: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
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
    /// The hub's code (`mesh.unknown_recipient`, `mesh.ambiguous`, ...).
    pub code: Option<String>,
    /// The sessions an ambiguous name names (`mesh.ambiguous`).
    pub candidates: Option<serde_json::Value>,
    /// How long a rate-limited caller waits (429 `retryAfterSeconds`).
    pub retry_after: Option<Duration>,
}

impl HubError {
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self { refused: false, ..Self::refused(message) }
    }

    pub fn refused(message: impl Into<String>) -> Self {
        let message = message.into();
        Self { message, refused: true, code: None, candidates: None, retry_after: None }
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
    /// Up to `max` messages for this daemon, leased to it, waiting up to `wait` for one.
    fn inbox(&self, wait: Duration, max: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>>;
    fn ack<'a>(&'a self, message_id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>>;
    /// Replace this daemon's sessions in the address book.
    fn heartbeat<'a>(
        &'a self,
        beat: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>>;
    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>>;
    fn receipt<'a>(&'a self, message_id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>>;
}

/// What runs a control message (start, resume or stop a session). The hub grants nothing: a hook
/// acts only through requests on a connection of `Origin::Peer` (`server::mesh_relay::
/// relay_connection`, proven as `ConnAuth::PeerToken`), so the daemon holds a relayed control to
/// exactly a peer daemon's rules, and never calls a `Hub` method that skips them. The message has
/// already been checked to be for this daemon (`Hub::mesh_for_here`). None leaves the message
/// unacked (its lease ends and it comes back).
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
        Self { first, cap, next: first.min(cap) }
    }

    pub fn reset(&mut self) {
        self.next = self.first.min(self.cap);
    }

    pub fn next_wait(&mut self) -> Duration {
        let wait = self.next.min(self.cap);
        self.next = wait.checked_mul(2).unwrap_or(self.cap).min(self.cap);
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
        // An inbox message as the hub sends it (cmux-platform openapi.json 1.3.0 MeshInboxMessage).
        let message: InMessage = serde_json::from_value(json!({
            "messageId": "msg_0123", "kind": "prompt", "op": null, "mode": "now",
            "to": {"sessionId": null, "name": "dep-land"},
            "from": {"daemonId": "inst_1", "user": "u_1", "host": "gcp-codex-lane-3",
                     "name": "lane-a", "sessionId": null},
            "body": "hi", "attempt": 2, "createdAt": 1, "leasedUntil": 2,
        }))
        .unwrap();
        assert_eq!((message.kind, message.mode), (Kind::Prompt, Mode::Now));
        assert_eq!(message.to.name.as_deref(), Some("dep-land"));
        assert_eq!(message.from.session_id, None);
        let kindless = json!({"messageId": "m", "body": "hi"});
        assert!(serde_json::from_value::<InMessage>(kindless).is_err(), "no kind is no prompt");
        let kind = |k: &str| serde_json::from_value::<Kind>(json!(k)).unwrap();
        assert_eq!((kind("control"), kind("later")), (Kind::Control, Kind::Unknown));
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
        // The cap bounds the first wait too, and a huge one never overflows.
        let mut b = Backoff::new(Duration::from_secs(10), Duration::from_secs(1));
        assert!(b.next_wait() <= Duration::from_secs(1));
        let mut b = Backoff::new(Duration::MAX, Duration::MAX);
        b.next_wait();
        assert!(b.next_wait() <= Duration::MAX);
    }
}
