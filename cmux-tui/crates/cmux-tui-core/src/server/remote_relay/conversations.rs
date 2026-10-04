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
use crate::remote_relay_state::remote_participant;

/// A remote peer resolved from its connection's peer record.
pub(super) struct RemoteCaller {
    /// `remote_<install>`.
    participant: String,
    /// The stamped user is the server owner.
    is_owner: bool,
}

fn caller(mux: &Mux, client: u64) -> anyhow::Result<RemoteCaller> {
    let Some(Principal::Remote(peer)) = mux.principal(client) else { return Err(denied()) };
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
        let _ = (mux, client);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

pub(in crate::server) fn snapshot(
    mux: &Mux,
    client: u64,
    params: SnapshotParams,
) -> anyhow::Result<Value> {
        let _ = (mux, client, params);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

pub(in crate::server) fn history(
    mux: &Mux,
    client: u64,
    params: HistoryParams,
) -> anyhow::Result<Value> {
        let _ = (mux, client, params);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
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
        let _ = (mux, client, params);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

pub(in crate::server) fn typing(
    mux: &Mux,
    client: u64,
    params: TypingParams,
) -> anyhow::Result<Value> {
        let _ = (mux, client, params);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
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
        let _ = (mux, caller_client, event);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

/// `subscribe` for a remote client: the outbound writer filter of section 8.
/// No pending pairing request is ever written.
pub(in crate::server) fn subscribe(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
        let _ = (mux, client, writer);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }
