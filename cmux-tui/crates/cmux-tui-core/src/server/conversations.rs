//! Raw protocol handlers for the local conversation owner
//! (`local-conversations-v1`, plans/cmux-next/home.md section 2). The store
//! commits each op in one transaction; `conversation-changed` is published
//! only after that commit and never for a replay. Rejects carry `error_code`
//! `conversation_rejected` and the reason code as the error text.

use std::sync::Arc;

use cmux_conversation::{Change, Op, Participant, Reject};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::remote_relay::participants::{device_id_refused, is_device_id};
use super::{Mux, MuxEvent, validate_client_transaction};
use crate::conversation_search::ConversationSearchRejected;
use crate::conversation_store::{
    ConversationEvent, ConversationRejected, LOCAL_USER, MAX_PAGE_MESSAGES, OpOutcome,
};

/// The local conversation owner: the `conversation-*` commands and the
/// `conversation-changed` and `conversation-typing` events, on trusted local
/// connections only.
pub const LOCAL_CONVERSATIONS_CAPABILITY: &str = "local-conversations-v1";
/// `conversation-search` on the local conversation owner.
pub const CONVERSATION_SEARCH_CAPABILITY: &str = "conversation-search-v1";

/// `conversation-create`: a retry with the same `idempotency_key` and request
/// returns the conversation it created.
#[derive(Deserialize)]
pub(super) struct CreateParams {
    idempotency_key: String,
    #[serde(default)]
    actor: Option<String>,
    title: String,
    participants: Value,
}

/// `conversation-snapshot`: the summary and the last `tail` (1-500) messages.
#[derive(Deserialize)]
pub(super) struct SnapshotParams {
    pub(super) conversation: String,
    pub(super) tail: u32,
}

/// `conversation-history`: up to `limit` (1-500) messages below `before_seq`.
#[derive(Deserialize)]
pub(super) struct HistoryParams {
    pub(super) conversation: String,
    pub(super) before_seq: u64,
    pub(super) limit: u32,
}

/// `conversation-op`: one op under a client idempotency key.
#[derive(Deserialize)]
pub(super) struct OpParams {
    pub(super) conversation: String,
    pub(super) idempotency_key: String,
    #[serde(default)]
    pub(super) actor: Option<String>,
    #[serde(default)]
    pub(super) transaction: Option<String>,
    pub(super) op: Value,
}

/// `conversation-search`: Home-only search, the shared read model
/// (`cmux_conversation::search`): a case-insensitive substring of the text of
/// the caller's conversations, newest first.
#[derive(Deserialize)]
pub(super) struct SearchParams {
    query: String,
    limit: u32,
}

/// `conversation-typing`: a typing indicator. Never stored.
#[derive(Deserialize)]
pub(super) struct TypingParams {
    pub(super) conversation: String,
    #[serde(default)]
    pub(super) actor: Option<String>,
    pub(super) on: bool,
}

/// `conversation-bind`: become agent `participant` for the rest of the
/// connection, proven by the token the local user minted for it.
#[derive(Deserialize)]
pub(super) struct BindParams {
    participant: String,
    token: String,
}

/// `conversation-agent-token`: mint the credential of agent `participant`
/// (local user connections only).
#[derive(Deserialize)]
pub(super) struct AgentTokenParams {
    participant: String,
}

/// The actor of a write is the connection's principal, stamped by the owner.
/// A request may still name it; naming anyone else is refused.
fn resolve_actor(mux: &Mux, client: u64, declared: Option<String>) -> anyhow::Result<String> {
    let principal = mux.conversation_principal(client);
    if declared.is_some_and(|declared| declared != principal) {
        return Err(ConversationRejected(Reject::ActorMismatch).into());
    }
    Ok(principal)
}

/// The stable reason of a conversation reject (the `reason` response field).
pub(super) fn error_reason(error: &anyhow::Error) -> Option<String> {
    error
        .downcast_ref::<ConversationRejected>()
        .map(|rejected| rejected.0.code().to_string())
        .or_else(|| {
            error.downcast_ref::<ConversationSearchRejected>().map(|r| r.0.code().to_string())
        })
}

/// The `error_code` of a conversation reject.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    let rejected = error.downcast_ref::<ConversationRejected>().is_some()
        || error.downcast_ref::<ConversationSearchRejected>().is_some();
    rejected.then(|| ConversationRejected::CODE.to_string())
}

fn require_local(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "local conversations require a trusted local connection"
    );
    Ok(())
}

pub(super) fn decode<T: DeserializeOwned>(value: Value, field: &str) -> anyhow::Result<T> {
    serde_json::from_value(value).map_err(|error| anyhow::anyhow!("bad request: {field}: {error}"))
}

pub(super) fn validate_page(value: u32, field: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        (1..=MAX_PAGE_MESSAGES).contains(&value),
        "bad request: {field} must be 1-{MAX_PAGE_MESSAGES}"
    );
    Ok(())
}

pub(super) fn list(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::list(mux, client);
    }
    require_local(mux, client)?;
    let conversations = mux.with_conversations(|store| store.list())?;
    Ok(json!({"conversations": conversations}))
}

pub(super) fn create(mux: &Mux, client: u64, params: CreateParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let CreateParams { idempotency_key, actor, title, participants } = params;
    let actor = resolve_actor(mux, client, actor)?;
    let participants: Vec<Participant> = decode(participants, "participants")?;
    // Device participants come only from the pairing system path.
    if participants.iter().any(|participant| is_device_id(&participant.id)) {
        return Err(device_id_refused());
    }
    let outcome = mux.conversation_write(
        |store| store.create(&idempotency_key, &actor, &title, &participants),
        |outcome| {
            if outcome.replayed {
                return None;
            }
            let change = Change::Conversation { conversation: Box::new(outcome.summary.clone()) };
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                conversation: outcome.summary.id.clone(),
                rev: outcome.summary.rev,
                transaction: None,
                change: serde_json::to_value(change).ok()?,
            })))
        },
    )?;
    Ok(json!({"conversation": outcome.summary, "replayed": outcome.replayed}))
}

pub(super) fn snapshot(mux: &Mux, client: u64, params: SnapshotParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::snapshot(mux, client, params);
    }
    require_local(mux, client)?;
    let SnapshotParams { conversation, tail } = params;
    validate_page(tail, "tail")?;
    let (summary, messages) =
        mux.with_conversations(|store| store.snapshot(&conversation, tail))?;
    Ok(json!({"conversation": summary, "messages": messages}))
}

pub(super) fn history(mux: &Mux, client: u64, params: HistoryParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::history(mux, client, params);
    }
    require_local(mux, client)?;
    let HistoryParams { conversation, before_seq, limit } = params;
    validate_page(limit, "limit")?;
    let messages =
        mux.with_conversations(|store| store.history(&conversation, before_seq, limit))?;
    Ok(json!({"messages": messages}))
}

pub(super) fn search(mux: &Mux, client: u64, params: SearchParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let SearchParams { query, limit } = params;
    // The owner stamps the actor: a search sees only the caller's conversations.
    let actor = mux.conversation_principal(client);
    let input = cmux_conversation::SearchInput { query, limit };
    let hits = mux.with_conversations(|store| store.search(&actor, &input))?;
    Ok(json!({"hits": hits}))
}

pub(super) fn op(mux: &Mux, client: u64, params: OpParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::op(mux, client, params);
    }
    require_local(mux, client)?;
    let OpParams { conversation, idempotency_key, actor, transaction, op } = params;
    let actor = resolve_actor(mux, client, actor)?;
    validate_client_transaction(transaction.as_deref())?;
    let op: Op = decode(op, "op")?;
    if let Op::ParticipantsAdd { participant } = &op
        && is_device_id(&participant.id)
    {
        return Err(device_id_refused());
    }
    let transaction: Option<Arc<str>> = transaction.map(Arc::from);
    let outcome = commit_op(mux, &conversation, &idempotency_key, &actor, &op, &transaction)?;
    Ok(op_reply(&outcome, outcome.result.change.clone(), transaction))
}

/// Commit `op` as `actor` and publish its `conversation-changed` (not for a
/// replay). Shared by the local and the remote handler.
pub(super) fn commit_op(
    mux: &Mux,
    conversation: &str,
    idempotency_key: &str,
    actor: &str,
    op: &Op,
    transaction: &Option<Arc<str>>,
) -> anyhow::Result<OpOutcome> {
    mux.conversation_write(
        |store| store.apply_op(conversation, idempotency_key, actor, op),
        |outcome| {
            if outcome.replayed {
                return None;
            }
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                conversation: conversation.to_string(),
                rev: outcome.result.rev,
                transaction: transaction.clone(),
                change: outcome.result.change.clone(),
            })))
        },
    )
}

/// The `conversation-op` reply with `change` (local or projected).
pub(super) fn op_reply(outcome: &OpOutcome, change: Value, transaction: Option<Arc<str>>) -> Value {
    let result = &outcome.result;
    let mut reply = json!({"rev": result.rev, "replayed": outcome.replayed, "change": change});
    if let Some(seq) = result.seq {
        reply["seq"] = json!(seq);
    }
    if let Some(transaction) = transaction {
        reply["transaction"] = json!(&*transaction);
    }
    reply
}

pub(super) fn typing(mux: &Mux, client: u64, params: TypingParams) -> anyhow::Result<Value> {
    if mux.is_remote_client(client) {
        return super::remote_relay::conversations::typing(mux, client, params);
    }
    require_local(mux, client)?;
    let TypingParams { conversation, actor, on } = params;
    let actor = resolve_actor(mux, client, actor)?;
    publish_typing(mux, &conversation, &actor, on)?;
    Ok(json!({}))
}

/// Validate and publish a typing indicator of `actor`. Never stored.
pub(super) fn publish_typing(
    mux: &Mux,
    conversation: &str,
    actor: &str,
    on: bool,
) -> anyhow::Result<()> {
    mux.conversation_write(
        |store| store.check_typing(conversation, actor),
        |_| {
            Some(MuxEvent::Conversation(Arc::new(ConversationEvent::Typing {
                conversation: conversation.to_string(),
                participant: actor.to_string(),
                on,
            })))
        },
    )
}

pub(super) fn bind(mux: &Mux, client: u64, params: BindParams) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    let BindParams { participant, token } = params;
    anyhow::ensure!(participant.starts_with("agent_"), "only agent participants bind with a token");
    let valid = mux.with_conversations(|store| store.verify_agent_token(&participant, &token))?;
    anyhow::ensure!(valid, "conversation agent token is not valid for {participant}");
    mux.bind_conversation_principal(client, participant.clone());
    Ok(json!({"participant": participant}))
}

pub(super) fn agent_token(
    mux: &Mux,
    client: u64,
    params: AgentTokenParams,
) -> anyhow::Result<Value> {
    require_local(mux, client)?;
    anyhow::ensure!(
        mux.conversation_principal(client) == LOCAL_USER,
        "only the local user mints agent tokens"
    );
    anyhow::ensure!(
        params.participant.starts_with("agent_"),
        "agent tokens are only for agent participants"
    );
    let token = mux.with_conversations(|store| store.mint_agent_token(&params.participant))?;
    // A replaced token also ends the connections bound with the old one.
    mux.unbind_conversation_participant(&params.participant);
    Ok(json!({"participant": params.participant, "token": token}))
}

#[cfg(test)]
#[path = "conversation_tests.rs"]
mod tests;
