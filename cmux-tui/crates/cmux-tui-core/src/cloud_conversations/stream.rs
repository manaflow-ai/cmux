//! One upstream `cmux.wire/1` stream as a pure state machine
//! (home-cloud-proxy.md sections 5 and 7): frames in, frames to send and
//! daemon events out. It keeps the last applied stream seq so a reconnect
//! resumes with `after_seq`, drops duplicates, and answers a gap with
//! `snapshot.request`, so events reach clients in seq order exactly once.

use serde_json::{Value, json};

use super::contract::{Target, conversation_change, inbox_entries, snapshot_parts};

/// A daemon event of `cloud-conversations-v1`.
///
/// `account` is the cloud user id (JWT `sub`) of the lease the daemon used
/// for the upstream socket that produced the event, `None` when that lease
/// had no readable `sub` (or no lease was involved). Clients drop stream
/// events whose account is not the one signed in now.
#[derive(Debug, Clone, PartialEq)]
pub enum CloudEvent {
    ConversationChanged {
        conversation: String,
        rev: u64,
        seq: u64,
        transaction: String,
        change: Value,
        account: Option<String>,
    },
    ConversationResynced {
        conversation: String,
        rev: u64,
        seq: u64,
        summary: Value,
        messages: Vec<Value>,
        account: Option<String>,
    },
    InboxChanged {
        seq: u64,
        transaction: String,
        entries: Vec<Value>,
        account: Option<String>,
    },
    InboxReset {
        seq: u64,
        account: Option<String>,
    },
    SubscriptionState {
        target: Target,
        state: &'static str,
        reason: Option<&'static str>,
        account: Option<String>,
    },
    SessionNeeded {
        reason: &'static str,
        expires_at: Option<u64>,
    },
}

impl CloudEvent {
    /// Tags a stream event with the account of the socket's lease.
    pub(crate) fn with_account(mut self, socket_account: Option<&str>) -> Self {
        match &mut self {
            Self::ConversationChanged { account, .. }
            | Self::ConversationResynced { account, .. }
            | Self::InboxChanged { account, .. }
            | Self::InboxReset { account, .. }
            | Self::SubscriptionState { account, .. } => {
                *account = socket_account.map(str::to_string);
            }
            Self::SessionNeeded { .. } => {}
        }
        self
    }

    fn account(&self) -> Option<&str> {
        match self {
            Self::ConversationChanged { account, .. }
            | Self::ConversationResynced { account, .. }
            | Self::InboxChanged { account, .. }
            | Self::InboxReset { account, .. }
            | Self::SubscriptionState { account, .. } => account.as_deref(),
            Self::SessionNeeded { .. } => None,
        }
    }

    /// The event line sent to subscribed trusted local clients.
    pub fn wire_json(&self) -> Value {
        let mut value = self.untagged_json();
        if let Some(account) = self.account() {
            value["account"] = json!(account);
        }
        value
    }

    fn untagged_json(&self) -> Value {
        match self {
            Self::ConversationChanged { conversation, rev, seq, transaction, change, .. } => {
                json!({
                    "event": "cloud-conversation-changed",
                    "conversation": conversation,
                    "rev": rev,
                    "seq": seq,
                    "transaction": transaction,
                    "change": change,
                })
            }
            Self::ConversationResynced { conversation, rev, seq, summary, messages, .. } => json!({
                "event": "cloud-conversation-resynced",
                "conversation": conversation,
                "rev": rev,
                "seq": seq,
                "summary": summary,
                "messages": messages,
            }),
            Self::InboxChanged { seq, transaction, entries, .. } => json!({
                "event": "cloud-inbox-changed",
                "seq": seq,
                "transaction": transaction,
                "entries": entries,
            }),
            Self::InboxReset { seq, .. } => json!({"event": "cloud-inbox-reset", "seq": seq}),
            Self::SubscriptionState { target, state, reason, .. } => {
                let mut value = json!({
                    "event": "cloud-subscription-state",
                    "scope": target.scope(),
                    "state": state,
                });
                if let Target::Conversation(id) = target {
                    value["conversation"] = json!(id);
                }
                if let Some(reason) = reason {
                    value["reason"] = json!(reason);
                }
                value
            }
            Self::SessionNeeded { reason, expires_at } => {
                let mut value = json!({"event": "cloud-session-needed", "reason": reason});
                if let Some(expires_at) = expires_at {
                    value["expires_at"] = json!(expires_at);
                }
                value
            }
        }
    }
}

/// What the connection driver does after a frame.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum StreamAction {
    Send(String),
    Emit(CloudEvent),
    /// The stream is subscribed.
    Live,
    /// The owner refused the stream; stop without reconnecting.
    Forbidden,
}

#[derive(Debug)]
pub(crate) struct StreamState {
    target: Target,
    /// The last stream seq applied (from a snapshot or an event).
    last_seq: Option<u64>,
    /// The principal of the last `welcome` (also the inbox owner). A
    /// different principal (another account signed in) drops `last_seq`, so
    /// the stream starts again from a snapshot instead of resuming another
    /// user's position.
    user: Option<String>,
    awaiting_snapshot: bool,
}

impl StreamState {
    pub(crate) fn new(target: Target) -> Self {
        Self { target, last_seq: None, user: None, awaiting_snapshot: false }
    }

    #[cfg(test)]
    pub(crate) fn last_seq(&self) -> Option<u64> {
        self.last_seq
    }

    /// A new connection starts; the next `welcome` subscribes again.
    pub(crate) fn on_connect(&mut self) {
        self.awaiting_snapshot = false;
    }

    fn stream_name(&self) -> Option<String> {
        match &self.target {
            Target::Conversation(id) => Some(format!("conv:{id}")),
            Target::Inbox => self.user.as_ref().map(|user| format!("inbox:{user}")),
        }
    }

    fn frame(&self, kind: &str) -> String {
        let mut frame = json!({"t": kind});
        if let (Target::Inbox, Some(stream)) = (&self.target, self.stream_name()) {
            frame["stream"] = json!(stream);
        }
        if kind == "subscribe"
            && let Some(after) = self.last_seq
        {
            frame["after_seq"] = json!(after);
        }
        frame.to_string()
    }

    fn request_snapshot(&mut self) -> Vec<StreamAction> {
        if self.awaiting_snapshot {
            return Vec::new();
        }
        self.awaiting_snapshot = true;
        vec![StreamAction::Send(self.frame("snapshot.request"))]
    }

    /// Handles one text frame from the owner.
    pub(crate) fn on_text(&mut self, text: &str) -> Vec<StreamAction> {
        let Ok(frame) = serde_json::from_str::<Value>(text) else { return Vec::new() };
        match frame.get("t").and_then(Value::as_str) {
            Some("welcome") => {
                let user = frame
                    .pointer("/principal/user")
                    .and_then(Value::as_str)
                    .filter(|user| !user.is_empty());
                match user {
                    Some(user) => {
                        if self.user.as_deref() != Some(user) {
                            self.last_seq = None;
                            self.user = Some(user.to_string());
                        }
                    }
                    // The inbox stream is named after the principal.
                    None if self.target == Target::Inbox => return vec![StreamAction::Forbidden],
                    // Unknown principal: never resume a position it may not own.
                    None => {
                        self.last_seq = None;
                        self.user = None;
                    }
                }
                vec![StreamAction::Send(self.frame("subscribe")), StreamAction::Live]
            }
            Some("snapshot") => self.on_snapshot(&frame),
            Some("event") => self.on_event(&frame),
            Some("error") => {
                let code = frame.get("code").and_then(Value::as_str).unwrap_or_default();
                if code == "auth.forbidden" { vec![StreamAction::Forbidden] } else { Vec::new() }
            }
            // result, reject and request-settled answer ops; the daemon sends
            // ops over HTTP, never on this socket.
            _ => Vec::new(),
        }
    }

    fn mine(&self, frame: &Value) -> bool {
        match (frame.get("stream").and_then(Value::as_str), self.stream_name()) {
            (Some(stream), Some(expected)) => stream == expected,
            _ => false,
        }
    }

    fn on_snapshot(&mut self, frame: &Value) -> Vec<StreamAction> {
        if !self.mine(frame) {
            return Vec::new();
        }
        let Some(seq) = frame.get("seq").and_then(Value::as_u64) else { return Vec::new() };
        self.awaiting_snapshot = false;
        self.last_seq = Some(seq);
        let event = match &self.target {
            Target::Inbox => CloudEvent::InboxReset { seq, account: None },
            Target::Conversation(conversation) => match snapshot_parts(frame) {
                Ok((summary, messages, rev, seq)) => CloudEvent::ConversationResynced {
                    conversation: conversation.clone(),
                    rev,
                    seq,
                    summary,
                    messages,
                    account: None,
                },
                Err(_) => return Vec::new(),
            },
        };
        vec![StreamAction::Emit(event)]
    }

    fn on_event(&mut self, frame: &Value) -> Vec<StreamAction> {
        if !self.mine(frame) || self.awaiting_snapshot {
            return Vec::new();
        }
        let Some(seq) = frame.get("seq").and_then(Value::as_u64) else { return Vec::new() };
        // Before the first snapshot nothing is confirmed; the snapshot that
        // answers the subscribe covers this event.
        let Some(last) = self.last_seq else { return Vec::new() };
        if seq <= last {
            return Vec::new();
        }
        if seq != last + 1 {
            return self.request_snapshot();
        }
        let transaction = frame.get("tx").and_then(Value::as_str).unwrap_or_default().to_string();
        let event = match &self.target {
            Target::Conversation(conversation) => match conversation_change(frame) {
                Some((rev, change)) => CloudEvent::ConversationChanged {
                    conversation: conversation.clone(),
                    rev,
                    seq,
                    transaction,
                    change,
                    account: None,
                },
                None => return self.request_snapshot(),
            },
            Target::Inbox => match inbox_entries(frame) {
                Some(entries) => {
                    CloudEvent::InboxChanged { seq, transaction, entries, account: None }
                }
                None => return self.request_snapshot(),
            },
        };
        self.last_seq = Some(seq);
        vec![StreamAction::Emit(event)]
    }
}
