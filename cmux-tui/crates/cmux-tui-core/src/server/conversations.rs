//! Raw protocol handlers for the local conversation owner
//! (`local-conversations-v1`, plans/cmux-next/home.md section 2). The store
//! commits each op in one transaction; `conversation-changed` is published
//! only after that commit and never for a replay. Rejects carry `error_code`
//! `conversation_rejected` and the reason code as the error text.

use std::sync::Arc;

use cmux_conversation::{Change, Op, Participant};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::{Mux, MuxEvent, validate_client_transaction};
use crate::conversation_store::MAX_PAGE_MESSAGES;

fn decode<T: DeserializeOwned>(value: Value, field: &str) -> anyhow::Result<T> {
    serde_json::from_value(value).map_err(|error| anyhow::anyhow!("bad request: {field}: {error}"))
}

fn validate_page(value: u32, field: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        (1..=MAX_PAGE_MESSAGES).contains(&value),
        "bad request: {field} must be 1-{MAX_PAGE_MESSAGES}"
    );
    Ok(())
}

pub(super) fn list(mux: &Mux) -> anyhow::Result<Value> {
    let conversations = mux.with_conversations(|store| store.list())?;
    Ok(json!({"conversations": conversations}))
}

pub(super) fn create(
    mux: &Mux,
    idempotency_key: &str,
    actor: &str,
    title: &str,
    participants: Value,
) -> anyhow::Result<Value> {
    let participants: Vec<Participant> = decode(participants, "participants")?;
    let outcome = mux.conversation_write(
        |store| store.create(idempotency_key, actor, title, &participants),
        |outcome| {
            if outcome.replayed {
                return None;
            }
            let change = Change::Conversation { conversation: Box::new(outcome.summary.clone()) };
            Some(MuxEvent::ConversationChanged {
                conversation: outcome.summary.id.clone(),
                rev: outcome.summary.rev,
                transaction: None,
                change: Arc::new(serde_json::to_value(change).ok()?),
            })
        },
    )?;
    Ok(json!({"conversation": outcome.summary, "replayed": outcome.replayed}))
}

pub(super) fn snapshot(mux: &Mux, conversation: &str, tail: u32) -> anyhow::Result<Value> {
    validate_page(tail, "tail")?;
    let (summary, messages) = mux.with_conversations(|store| store.snapshot(conversation, tail))?;
    Ok(json!({"conversation": summary, "messages": messages}))
}

pub(super) fn history(
    mux: &Mux,
    conversation: &str,
    before_seq: u64,
    limit: u32,
) -> anyhow::Result<Value> {
    validate_page(limit, "limit")?;
    let messages =
        mux.with_conversations(|store| store.history(conversation, before_seq, limit))?;
    Ok(json!({"messages": messages}))
}

pub(super) fn op(
    mux: &Mux,
    conversation: &str,
    idempotency_key: &str,
    actor: &str,
    transaction: Option<String>,
    op: Value,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let op: Op = decode(op, "op")?;
    let transaction: Option<Arc<str>> = transaction.map(Arc::from);
    let outcome = mux.conversation_write(
        |store| store.apply_op(conversation, idempotency_key, actor, &op),
        |outcome| {
            if outcome.replayed {
                return None;
            }
            Some(MuxEvent::ConversationChanged {
                conversation: conversation.to_string(),
                rev: outcome.result.rev,
                transaction: transaction.clone(),
                change: Arc::new(outcome.result.change.clone()),
            })
        },
    )?;
    let result = outcome.result;
    let mut reply =
        json!({"rev": result.rev, "replayed": outcome.replayed, "change": result.change});
    if let Some(seq) = result.seq {
        reply["seq"] = json!(seq);
    }
    if let Some(transaction) = transaction {
        reply["transaction"] = json!(&*transaction);
    }
    Ok(reply)
}

pub(super) fn typing(
    mux: &Mux,
    conversation: &str,
    actor: &str,
    on: bool,
) -> anyhow::Result<Value> {
    mux.conversation_write(
        |store| store.check_typing(conversation, actor),
        |_| {
            Some(MuxEvent::ConversationTyping {
                conversation: conversation.to_string(),
                participant: actor.to_string(),
                on,
            })
        },
    )?;
    Ok(json!({}))
}
