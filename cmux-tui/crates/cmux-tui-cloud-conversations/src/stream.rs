//! One upstream `cmux.wire/1` stream as a pure state machine
//! (home-cloud-proxy.md sections 5 and 7): frames in, frames to send and
//! daemon events out. The position is the shared `cmux.wire/1` mirror
//! (cmux-cloud-wire `StreamMirror`, the engine the phone apps use): a
//! reconnect resumes with `after_seq`, a duplicate is dropped, a gap is
//! buffered and answered with `snapshot.request`, and the buffered events
//! replay after the snapshot, so events reach clients in seq order exactly once.
//! A snapshot that does not decode is asked for again after a backoff; after
//! the last attempt the connection drops and the next one resumes.

use cmux_cloud_wire::{
    Applied, ClientOut, PositionOnly, SnapshotBackoff, SnapshotRetry, StreamMirror,
};
use serde_json::{Value, json};

use crate::panic_free::JsonFields as _;

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
    /// The host replica publisher needs a new install token lease
    /// (`cloud-host-replica-needed`, host_replica.rs): `expiring` before the
    /// lease ends, `unauthenticated` when the cloud refused it. Only the
    /// verified app connection hears it.
    HostReplicaNeeded {
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
    /// Someone in a subscribed conversation started or stopped typing (the
    /// owner's `conversation-typing` broadcast: a Cloud Chief's reply, or
    /// another person); ephemeral, never stored or replayed.
    Typing {
        conversation: String,
        participant: String,
        on: bool,
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
            | Self::Live { account, .. }
            | Self::Typing { account, .. } => {
                *account = socket_account.map(str::to_string);
            }
            Self::SessionNeeded { .. } | Self::HostReplicaNeeded { .. } => {}
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
            | Self::Live { account, .. }
            | Self::Typing { account, .. } => account.as_deref(),
            Self::SessionNeeded { .. } | Self::HostReplicaNeeded { .. } => None,
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
                    value.insert("conversation", json!(id));
                }
                if let Some(reason) = reason {
                    value.insert("reason", json!(reason));
                }
                value
            }
            Self::SessionNeeded { reason, expires_at } => {
                let mut value = json!({"event": "cloud-session-needed", "reason": reason});
                if let Some(expires_at) = expires_at {
                    value.insert("expires_at", json!(expires_at));
                }
                value
            }
            Self::HostReplicaNeeded { reason, expires_at } => {
                let mut value = json!({"event": "cloud-host-replica-needed", "reason": reason});
                if let Some(expires_at) = expires_at {
                    value.insert("expires_at", json!(expires_at));
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
            Self::Typing { conversation, participant, on, .. } => json!({
                "event": "cloud-conversation-typing",
                "conversation": conversation,
                "participant": participant,
                "on": on,
            }),
        };
        if let Some(account) = self.account() {
            value.insert("account", json!(account));
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
    /// Every attempt to get a readable snapshot failed: drop the connection
    /// and reconnect after the backoff.
    Drop,
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
    /// A snapshot or an event reached clients since the last
    /// [`StreamState::take_progress`].
    progressed: bool,
    /// The participants this socket heard typing `on` and not yet `off`: the
    /// owner sends their `off` only on a socket, so a socket that ends turns
    /// them off for the clients ([`StreamState::typing_ended`]).
    typing: std::collections::BTreeSet<String>,
}

/// At most this many participants are kept typing per socket (an owner that
/// sends more is not a real conversation's).
const MAX_TYPING: usize = 256;

impl StreamState {
    pub(crate) fn new(target: Target, backoff: SnapshotBackoff) -> Self {
        // The daemon sends ops over HTTP, never on this socket, so the
        // mirror issues no keys; the prefix only names it.
        let mirror = StreamMirror::with_reducer(PositionOnly, "daemon-proxy", Value::Null)
            .without_rows()
            .with_snapshot_backoff(backoff);
        Self {
            target,
            mirror,
            user: None,
            subscribed: false,
            progressed: false,
            typing: std::collections::BTreeSet::new(),
        }
    }

    /// True once after a snapshot or an event reached clients: the stream
    /// works (a welcome alone does not count).
    pub(crate) fn take_progress(&mut self) -> bool {
        std::mem::take(&mut self.progressed)
    }

    /// No snapshot failed since the last one that decoded.
    pub(crate) fn is_healthy(&self) -> bool {
        self.mirror.snapshot_failures() == 0
    }

    /// When the next snapshot request is due (Unix ms), after a snapshot
    /// that did not decode.
    pub(crate) fn snapshot_retry_at(&self) -> Option<i64> {
        self.mirror.snapshot_retry_at()
    }

    /// The snapshot request whose time came.
    pub(crate) fn snapshot_retry_due(&mut self, now: i64) -> Vec<StreamAction> {
        let out = self.mirror.snapshot_retry_due(now);
        self.send(out)
    }

    fn snapshot_unusable(&mut self, now: i64) -> Option<StreamAction> {
        match self.mirror.snapshot_unusable(now) {
            SnapshotRetry::At(_) => None,
            SnapshotRetry::Exhausted => Some(StreamAction::Drop),
        }
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
            frame.insert("stream", json!(stream));
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
                    frame.insert("stream", json!(stream));
                }
                StreamAction::Send(frame.to_string())
            })
            .collect()
    }

    fn subscribe(&mut self) -> Vec<StreamAction> {
        self.subscribed = true;
        // The log is always empty (ops go over HTTP), so no intent can expire
        // and the clock does not matter.
        let resume = self.mirror.resume(0);
        let mut frame = self.frame("subscribe");
        if let Some(after) = resume.after_seq {
            frame.insert("after_seq", json!(after));
        }
        if !resume.pending.is_empty() {
            frame.insert("pending", json!(resume.pending));
        }
        let mut actions = vec![StreamAction::Send(frame.to_string())];
        actions.extend(self.send(resume.send));
        actions.push(StreamAction::Live);
        actions
    }

    /// Handles one text frame from the owner; `now` is Unix ms.
    pub(crate) fn on_text(&mut self, text: &str, now: i64) -> Vec<StreamAction> {
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
            Some("snapshot" | "event") => self.on_stream_frame(frame, now),
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
                        run: frame.field("run").clone(),
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
            // Someone types in this conversation (no seq: never replayed; the
            // owner turns a closed socket's typing off).
            Some("conversation-typing") => self.on_typing(&frame),
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

    /// The owner's `conversation-typing {conversation, participant, on}` of
    /// this conversation; any other shape is dropped.
    fn on_typing(&mut self, frame: &Value) -> Vec<StreamAction> {
        let Target::Conversation(conversation) = &self.target else { return Vec::new() };
        if frame.get("conversation").and_then(Value::as_str) != Some(conversation.as_str()) {
            return Vec::new();
        }
        let participant =
            frame.get("participant").and_then(Value::as_str).filter(|id| !id.is_empty());
        let (Some(participant), Some(on)) = (participant, frame.get("on").and_then(Value::as_bool))
        else {
            return Vec::new();
        };
        if on {
            if self.typing.len() >= MAX_TYPING && !self.typing.contains(participant) {
                return Vec::new();
            }
            self.typing.insert(participant.to_string());
        } else {
            self.typing.remove(participant);
        }
        vec![StreamAction::Emit(CloudEvent::Typing {
            conversation: conversation.clone(),
            participant: participant.to_string(),
            on,
            account: None,
        })]
    }

    /// The socket ended: everyone it heard typing stops, because no `off`
    /// for them can come on it any more (the next socket hears only new
    /// typing).
    pub(crate) fn typing_ended(&mut self) -> Vec<CloudEvent> {
        let Target::Conversation(conversation) = &self.target else { return Vec::new() };
        std::mem::take(&mut self.typing)
            .into_iter()
            .map(|participant| CloudEvent::Typing {
                conversation: conversation.clone(),
                participant,
                on: false,
                account: None,
            })
            .collect()
    }

    fn mine(&self, frame: &Value) -> bool {
        match (frame.get("stream").and_then(Value::as_str), self.stream_name()) {
            (Some(stream), Some(expected)) => stream == expected,
            _ => false,
        }
    }

    /// An event or a snapshot of this stream goes through the mirror; what
    /// it applies, in order, becomes daemon events.
    fn on_stream_frame(&mut self, frame: Value, now: i64) -> Vec<StreamAction> {
        // Before the welcome, nothing is subscribed on this connection.
        if !self.subscribed || !self.mine(&frame) {
            return Vec::new();
        }
        // An event that does not decode asks for a snapshot (which replaces
        // whatever it carried); a snapshot that does not decode is asked for
        // again after the backoff, and events wait for it.
        let received = self.mirror.receive_value(frame, now);
        let mut actions = self.send(received.send);
        if received.snapshot_retry == Some(SnapshotRetry::Exhausted) {
            actions.push(StreamAction::Drop);
        }
        for applied in received.applied {
            match self.translate(applied) {
                Translated::Emit(event) => {
                    self.progressed = true;
                    actions.push(StreamAction::Emit(event));
                }
                Translated::Nothing => self.progressed = true,
                // The events after it are covered by the snapshot asked for;
                // a resume before it comes must not skip them.
                Translated::Resync => {
                    self.mirror.forget_position();
                    let out = self.mirror.resync();
                    actions.extend(self.send(out));
                    break;
                }
                // A snapshot clients cannot use: its position is forgotten
                // and the events after it wait for the one asked for after
                // the backoff, which covers them.
                Translated::SnapshotUnusable => {
                    actions.extend(self.snapshot_unusable(now));
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
                let Ok(frame) = serde_json::to_value(&*snapshot) else {
                    return Translated::SnapshotUnusable;
                };
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
                    // show: it is asked for again.
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
                        Err(_) => Translated::SnapshotUnusable,
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
    /// The snapshot applied but has no daemon event: ask again after the backoff.
    SnapshotUnusable,
}
