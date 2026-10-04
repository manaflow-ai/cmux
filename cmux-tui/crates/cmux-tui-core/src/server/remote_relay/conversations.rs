//! The conversation commands for a remote peer (server-remote-conversations.md
//! sections 5 and 8). Owner scope (v1): the peer's stamped `user` must be the
//! server owner (the `user` of the stored pairing record), and the
//! conversation must list the install's participant `remote_<install>`.
//! Anything else, including an unknown id, is `remote_denied`. The actor is
//! always `remote_<install>`; replies and events are remote projections.

use std::sync::Arc;

use cmux_conversation::{Op, Reject};
use serde_json::{Value, json};

use super::super::conversations::{
    HistoryParams, OpParams, SnapshotParams, TypingParams, commit_op, decode, op_reply,
    publish_typing, validate_page,
};
use super::super::{
    MessageWriter, Mux, MuxEvent, StreamInterrupt, subscription_overflow_json,
    validate_client_transaction,
};
use super::{Principal, denied, project};
use crate::conversation_store::{ConversationEvent, ConversationRejected};
use crate::remote_relay_state::{StreamPolicy, remote_participant};

/// A remote peer resolved from its connection's peer record.
pub(super) struct RemoteCaller {
    /// `remote_<install>`.
    participant: String,
    /// The stamped user is the server owner.
    is_owner: bool,
}

fn caller(mux: &Mux, client: u64) -> anyhow::Result<RemoteCaller> {
    let Some(Principal::Remote(peer)) = mux.principal(client) else { return Err(denied()) };
    // Every frame rechecks the revocation policy: a revoked install, or one
    // past the 72 h offline limit, is refused even before its streams close.
    if mux.remote_relay().revocation.lock().unwrap().policy(&peer.install) == StreamPolicy::Close {
        return Err(denied());
    }
    let owner = mux.remote_relay().owner_user();
    Ok(RemoteCaller {
        participant: remote_participant(&peer.install),
        is_owner: owner.as_deref() == Some(peer.user.as_str()),
    })
}

fn owns(caller: &RemoteCaller, participants: &[cmux_conversation::Participant]) -> bool {
    caller.is_owner && participants.iter().any(|p| p.id == caller.participant)
}

/// True when `caller` owns `conversation` now. Unknown and unowned are the
/// same answer.
fn owned(mux: &Mux, caller: &RemoteCaller, conversation: &str) -> anyhow::Result<bool> {
    if !caller.is_owner {
        return Ok(false);
    }
    let head = mux.with_conversations(|store| store.head(conversation))?;
    Ok(head.is_some_and(|head| owns(caller, &head.participants)))
}

fn require_owned(mux: &Mux, caller: &RemoteCaller, conversation: &str) -> anyhow::Result<()> {
    if owned(mux, caller, conversation)? { Ok(()) } else { Err(denied()) }
}

/// A request may name the actor; anyone but `remote_<install>` is refused.
fn check_actor(caller: &RemoteCaller, declared: Option<&str>) -> anyhow::Result<()> {
    if declared.is_some_and(|declared| declared != caller.participant) {
        return Err(ConversationRejected(Reject::ActorMismatch).into());
    }
    Ok(())
}

pub(in crate::server) fn list(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    if !caller.is_owner {
        return Ok(json!({"conversations": []}));
    }
    let summaries = mux.with_conversations(|store| store.list())?;
    let conversations: Vec<_> = summaries
        .iter()
        .filter(|summary| owns(&caller, &summary.participants))
        .map(|summary| project::summary(summary, &caller.participant))
        .collect();
    Ok(json!({"conversations": conversations}))
}

pub(in crate::server) fn snapshot(
    mux: &Mux,
    client: u64,
    params: SnapshotParams,
) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    validate_page(params.tail, "tail")?;
    require_owned(mux, &caller, &params.conversation)?;
    let (summary, messages) =
        mux.with_conversations(|store| store.snapshot(&params.conversation, params.tail))?;
    if !owns(&caller, &summary.participants) {
        return Err(denied());
    }
    let messages: Vec<_> = messages.iter().map(project::message).collect();
    Ok(
        json!({"conversation": project::summary(&summary, &caller.participant), "messages": messages}),
    )
}

pub(in crate::server) fn history(
    mux: &Mux,
    client: u64,
    params: HistoryParams,
) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    validate_page(params.limit, "limit")?;
    require_owned(mux, &caller, &params.conversation)?;
    let HistoryParams { conversation, before_seq, limit } = params;
    let messages =
        mux.with_conversations(|store| store.history(&conversation, before_seq, limit))?;
    let messages: Vec<_> = messages.iter().map(project::message).collect();
    Ok(json!({"messages": messages}))
}

/// The op kinds a remote peer may commit (the gate checked the JSON shape;
/// this is the typed second check). Parts must be text only.
fn remote_op_allowed(op: &Op) -> bool {
    let text_only = |parts: &[cmux_conversation::Part]| {
        parts.iter().all(|part| matches!(part, cmux_conversation::Part::Text { .. }))
    };
    match op {
        Op::MessageSend { parts, .. } | Op::MessageEdit { parts, .. } => text_only(parts),
        Op::MessageRetract { .. }
        | Op::ReactionAdd { .. }
        | Op::ReactionRemove { .. }
        | Op::ReadCursorSet { .. } => true,
        Op::ParticipantsAdd { .. } | Op::TitleSet { .. } => false,
    }
}

pub(in crate::server) fn op(mux: &Mux, client: u64, params: OpParams) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    let OpParams { conversation, idempotency_key, actor, transaction, op } = params;
    require_owned(mux, &caller, &conversation)?;
    check_actor(&caller, actor.as_deref())?;
    validate_client_transaction(transaction.as_deref())?;
    let op: Op = decode(op, "op")?;
    if !remote_op_allowed(&op) {
        return Err(denied());
    }
    let transaction: Option<Arc<str>> = transaction.map(Arc::from);
    let outcome =
        commit_op(mux, &conversation, &idempotency_key, &caller.participant, &op, &transaction)?;
    let change = project::change(&outcome.result.change, &caller.participant);
    Ok(op_reply(&outcome, change.unwrap_or(Value::Null), transaction))
}

pub(in crate::server) fn typing(
    mux: &Mux,
    client: u64,
    params: TypingParams,
) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    let TypingParams { conversation, actor, on } = params;
    require_owned(mux, &caller, &conversation)?;
    check_actor(&caller, actor.as_deref())?;
    publish_typing(mux, &conversation, &caller.participant, on)?;
    Ok(json!({}))
}

/// The remote form of event `event`, or `None` when the outbound filter
/// drops it: only `conversation-changed` and `conversation-typing` of owned
/// conversations leave a remote writer. Pairing requests, terminal output,
/// tree events and client echoes are dropped.
pub(in crate::server) fn remote_event(
    mux: &Mux,
    caller_client: u64,
    event: &MuxEvent,
) -> Option<Value> {
    let MuxEvent::Conversation(event) = event else { return None };
    let caller = caller(mux, caller_client).ok()?;
    match event.as_ref() {
        ConversationEvent::Changed { conversation, rev, change, .. } => {
            if !owned(mux, &caller, conversation).ok()? {
                return None;
            }
            let change = project::change(change, &caller.participant)?;
            Some(json!({
                "event": "conversation-changed",
                "conversation": conversation,
                "rev": rev,
                "change": change,
            }))
        }
        ConversationEvent::Typing { conversation, participant, on } => {
            if !owned(mux, &caller, conversation).ok()? {
                return None;
            }
            Some(json!({
                "event": "conversation-typing",
                "conversation": conversation,
                "participant": participant,
                "on": on,
            }))
        }
    }
}

/// `subscribe` for a remote client: the outbound writer filter of section 8.
/// No pending pairing request is ever written.
pub(in crate::server) fn subscribe(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    caller(mux, client)?;
    let events = mux.subscribe();
    let event_mux = mux.clone();
    let writer = writer.clone();
    let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
    std::thread::Builder::new().name("mux-remote-events".into()).spawn(move || {
        let interrupt = StreamInterrupt::new();
        writer.register_interrupt(&interrupt);
        outbound_stream.register_interrupt(&interrupt);
        events.wake_on(&interrupt);
        let mut transport_overflow = false;
        while writer.is_open() && outbound_stream.is_open() {
            let event = match events.recv_until_interrupted(&interrupt) {
                Ok(event) => event,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            };
            let Some(value) = remote_event(&event_mux, client, &event) else { continue };
            if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                break;
            }
        }
        if events.overflowed() || transport_overflow {
            let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
        }
    })?;
    Ok(json!({}))
}
