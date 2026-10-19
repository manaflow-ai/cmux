//! One upstream `cmux.wire/1` stream as a pure state machine
//! (home-cloud-proxy.md sections 5 and 7): frames in, frames to send and
//! daemon events out. The position is the shared `cmux.wire/1` mirror
//! (cmux-cloud-wire `StreamMirror`, the engine the phone apps use): a
//! reconnect resumes with `after_seq`, a duplicate is dropped, a gap is
//! buffered and answered with `snapshot.request`, and the buffered events
//! replay after the snapshot, so events reach clients in seq order exactly once.

use cmux_cloud_wire::{Applied, ClientOut, OwnerFrame, PositionOnly, StreamMirror};
use serde_json::{Value, json};

use super::contract::{
    Target, conversation_change, inbox_entries, mux_pending, mux_wakes, snapshot_parts,
};

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
    /// New wakes in the leased chief's MuxDO queue: ids only.
    MuxWake {
        seq: u64,
        wakes: Vec<Value>,
        account: Option<String>,
    },
    /// The queue's pending wakes after a (re)subscribe: a wake missed while
    /// the socket was down is here.
    MuxResynced {
        seq: u64,
        pending: Vec<Value>,
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
    /// A Chief's run in a subscribed conversation changed (the owner's
    /// `conversation-run-changed` frame: the run and the steps that changed;
    /// ephemeral, never stored by the owner's stream).
    RunChanged {
        conversation: String,
        run: Value,
        steps: Vec<Value>,
        account: Option<String>,
    },
    /// A Cloud Chief's live frame in a subscribed conversation
    /// (`chief-live-v1`: `step.delta`, `run.activity`, or the `run.live`
    /// snapshot the owner sends on join, on reconnect and on request), with
    /// its `type`; ephemeral, never stored by the owner or the daemon.
    Live {
        conversation: String,
        frame: Value,
        account: Option<String>,
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
            | Self::MuxWake { account, .. }
            | Self::MuxResynced { account, .. }
            | Self::SubscriptionState { account, .. }
            | Self::RunChanged { account, .. }
            | Self::Live { account, .. } => {
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
            | Self::MuxWake { account, .. }
            | Self::MuxResynced { account, .. }
            | Self::SubscriptionState { account, .. }
            | Self::RunChanged { account, .. }
            | Self::Live { account, .. } => account.as_deref(),
            Self::SessionNeeded { .. } => None,
        }
    }

    /// The event line sent to subscribed trusted local clients.
    pub fn wire_json(&self) -> Value {
        let mut value = match self {
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
            Self::MuxWake { seq, wakes, .. } => {
                json!({"event": "cloud-mux-wake", "seq": seq, "wakes": wakes})
            }
            Self::MuxResynced { seq, pending, .. } => {
                json!({"event": "cloud-mux-resynced", "seq": seq, "pending": pending})
            }
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
            Self::RunChanged { conversation, run, steps, .. } => json!({
                "event": "cloud-conversation-run-changed",
                "conversation": conversation,
                "run": run,
                "steps": steps,
            }),
            Self::Live { conversation, frame, .. } => json!({
                "event": "cloud-conversation-live",
                "conversation": conversation,
                "frame": frame,
            }),
        };
        if let Some(account) = self.account() {
            value["account"] = json!(account);
        }
        value
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
    /// The stream position and the head, without rows (the daemon's clients
    /// hold the rows): the shared `cmux.wire/1` mirror decides which events
    /// apply, buffers a gap's events until the snapshot that closes it, and
    /// says where a new connection resumes.
    mirror: StreamMirror<PositionOnly>,
    /// The principal of the last `welcome` (also the inbox owner). A
    /// different principal (another account signed in) resets the mirror, so
    /// the stream starts again from a snapshot instead of resuming another
    /// user's position.
    user: Option<String>,
    /// This connection's `welcome` came and the subscribe went out.
    subscribed: bool,
}

impl StreamState {
    pub(crate) fn new(target: Target) -> Self {
        // The daemon sends ops over HTTP, never on this socket, so the
        // mirror issues no keys; the prefix only names it.
        let mirror =
            StreamMirror::with_reducer(PositionOnly, "daemon-proxy", Value::Null).without_rows();
        Self { target, mirror, user: None, subscribed: false }
    }

    /// A new connection starts; the next `welcome` subscribes again.
    pub(crate) fn on_connect(&mut self) {
        self.mirror.disconnect();
        self.subscribed = false;
    }

    /// The stream sent its subscribe on this connection.
    pub(crate) fn is_live(&self) -> bool {
        self.subscribed
    }

    fn stream_name(&self) -> Option<String> {
        match &self.target {
            Target::Conversation(id) => Some(format!("conv:{id}")),
            Target::Mux(agent) => Some(format!("mux:{agent}")),
            Target::Inbox => self.user.as_ref().map(|user| format!("inbox:{user}")),
        }
    }

    fn frame(&self, kind: &str) -> Value {
        let mut frame = json!({"t": kind});
        if let (Target::Inbox, Some(stream)) = (&self.target, self.stream_name()) {
            frame["stream"] = json!(stream);
        }
        frame
    }

    /// The mirror's frames as this socket sends them (the inbox names its
    /// stream on every frame).
    fn send(&self, out: Vec<ClientOut>) -> Vec<StreamAction> {
        out.into_iter()
            .map(|out| {
                let mut frame = out.to_value();
                if let (Target::Inbox, Some(stream)) = (&self.target, self.stream_name()) {
                    frame["stream"] = json!(stream);
                }
                StreamAction::Send(frame.to_string())
            })
            .collect()
    }

    fn subscribe(&mut self) -> Vec<StreamAction> {
        self.subscribed = true;
        let resume = self.mirror.resume(now_ms());
        let mut frame = self.frame("subscribe");
        if let Some(after) = resume.after_seq {
            frame["after_seq"] = json!(after);
        }
        let mut actions = vec![StreamAction::Send(frame.to_string())];
        actions.extend(self.send(resume.send));
        actions.push(StreamAction::Live);
        actions
    }

    /// Handles one text frame from the owner.
    pub(crate) fn on_text(&mut self, text: &str) -> Vec<StreamAction> {
        let Ok(frame) = serde_json::from_str::<Value>(text) else { return Vec::new() };
        // The live frames name their kind with `type` (the brain contract),
        // every other owner frame with `t`.
        let kind = frame.get("t").or_else(|| frame.get("type")).and_then(Value::as_str);
        if let Some(kind @ ("step.delta" | "run.activity" | "run.live")) = kind {
            return self.on_live(kind, frame.clone());
        }
        match frame.get("t").and_then(Value::as_str) {
            Some("welcome") => {
                let user = frame
                    .pointer("/principal/user")
                    .and_then(Value::as_str)
                    .filter(|user| !user.is_empty());
                match user {
                    Some(user) => {
                        if self.user.as_deref() != Some(user) {
                            self.mirror.reset(Value::Null);
                            self.user = Some(user.to_string());
                        }
                    }
                    // The inbox stream is named after the principal.
                    None if self.target == Target::Inbox => return vec![StreamAction::Forbidden],
                    // Unknown principal: never resume a position it may not own.
                    None => {
                        self.mirror.reset(Value::Null);
                        self.user = None;
                    }
                }
                self.subscribe()
            }
            Some("snapshot" | "event") => self.on_stream_frame(frame),
            // A Chief run change for this conversation's members (no seq: it
            // is never replayed, a page reads the run again after a gap).
            Some("conversation-run-changed") => match &self.target {
                Target::Conversation(conversation)
                    if frame.get("conversation").and_then(Value::as_str)
                        == Some(conversation.as_str())
                        && frame.get("run").is_some_and(Value::is_object) =>
                {
                    vec![StreamAction::Emit(CloudEvent::RunChanged {
                        conversation: conversation.clone(),
                        run: frame["run"].clone(),
                        steps: frame
                            .get("steps")
                            .and_then(Value::as_array)
                            .cloned()
                            .unwrap_or_default(),
                        account: None,
                    })]
                }
                _ => Vec::new(),
            },
            Some("error") => {
                let code = frame.get("code").and_then(Value::as_str).unwrap_or_default();
                if code == "auth.forbidden" { vec![StreamAction::Forbidden] } else { Vec::new() }
            }
            // result, reject and request-settled answer ops; the daemon sends
            // ops over HTTP, never on this socket.
            _ => Vec::new(),
        }
    }

    /// A live frame of this conversation goes to its subscribers unchanged,
    /// with both `type` and `t` (passed through, never kept: a page that
    /// missed one asks for the `run.live` snapshot again).
    fn on_live(&self, kind: &str, mut frame: Value) -> Vec<StreamAction> {
        let Target::Conversation(conversation) = &self.target else { return Vec::new() };
        if frame.get("conversation").and_then(Value::as_str) != Some(conversation.as_str()) {
            return Vec::new();
        }
        let Some(object) = frame.as_object_mut() else { return Vec::new() };
        // Both keys, as the owner sends them (`t` = `type`).
        object.insert("type".into(), json!(kind));
        object.insert("t".into(), json!(kind));
        vec![StreamAction::Emit(CloudEvent::Live {
            conversation: conversation.clone(),
            frame,
            account: None,
        })]
    }

    fn mine(&self, frame: &Value) -> bool {
        match (frame.get("stream").and_then(Value::as_str), self.stream_name()) {
            (Some(stream), Some(expected)) => stream == expected,
            _ => false,
        }
    }

    /// An event or a snapshot of this stream goes through the mirror; what
    /// it applies, in order, becomes daemon events.
    fn on_stream_frame(&mut self, frame: Value) -> Vec<StreamAction> {
        // Before the welcome, nothing is subscribed on this connection.
        if !self.subscribed || !self.mine(&frame) {
            return Vec::new();
        }
        let Ok(frame) = OwnerFrame::from_value(frame) else {
            // A frame of this stream that does not decode: the snapshot
            // replaces whatever it carried.
            let out = self.mirror.resync();
            return self.send(out);
        };
        let received = self.mirror.receive_applied(frame);
        let mut actions = self.send(received.send);
        for applied in received.applied {
            match self.translate(applied) {
                Translated::Emit(event) => actions.push(StreamAction::Emit(event)),
                Translated::Nothing => {}
                // The events after it are covered by the snapshot asked for.
                Translated::Resync => {
                    let out = self.mirror.resync();
                    actions.extend(self.send(out));
                    break;
                }
            }
        }
        actions
    }

    fn translate(&self, applied: Applied) -> Translated {
        match applied {
            Applied::Snapshot(snapshot) => {
                let seq = snapshot.seq;
                let Ok(frame) = serde_json::to_value(&*snapshot) else { return Translated::Resync };
                match &self.target {
                    Target::Inbox => {
                        Translated::Emit(CloudEvent::InboxReset { seq, account: None })
                    }
                    Target::Mux(_) => Translated::Emit(CloudEvent::MuxResynced {
                        seq,
                        pending: mux_pending(&frame),
                        account: None,
                    }),
                    // A snapshot without a conversation head has nothing to
                    // show; the next one will.
                    Target::Conversation(conversation) => match snapshot_parts(&frame) {
                        Ok((summary, messages, rev, seq)) => {
                            Translated::Emit(CloudEvent::ConversationResynced {
                                conversation: conversation.clone(),
                                rev,
                                seq,
                                summary,
                                messages,
                                account: None,
                            })
                        }
                        Err(_) => Translated::Nothing,
                    },
                }
            }
            Applied::Event(event) => {
                let (seq, transaction) = (event.seq, event.tx.clone());
                let Ok(frame) = serde_json::to_value(&*event) else { return Translated::Resync };
                match &self.target {
                    Target::Conversation(conversation) => match conversation_change(&frame) {
                        Some((rev, change)) => Translated::Emit(CloudEvent::ConversationChanged {
                            conversation: conversation.clone(),
                            rev,
                            seq,
                            transaction,
                            change,
                            account: None,
                        }),
                        None => Translated::Resync,
                    },
                    Target::Mux(_) => {
                        let wakes = mux_wakes(&frame);
                        // An ack or a configure changes no wake the brain must see.
                        if wakes.is_empty() {
                            Translated::Nothing
                        } else {
                            Translated::Emit(CloudEvent::MuxWake { seq, wakes, account: None })
                        }
                    }
                    Target::Inbox => match inbox_entries(&frame) {
                        Some(entries) => Translated::Emit(CloudEvent::InboxChanged {
                            seq,
                            transaction,
                            entries,
                            account: None,
                        }),
                        None => Translated::Resync,
                    },
                }
            }
        }
    }
}

enum Translated {
    Emit(CloudEvent),
    Nothing,
    /// The frame applied but has no daemon event: resync from a snapshot.
    Resync,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}
