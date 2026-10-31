//! How much one chat's queue holds (manaflow-ai/cmuxterm-hq#2930). Each waiting prompt keeps
//! its whole blocks in memory and in its `queued` record, and every restore replays them, so a
//! client that sends faster than the agent runs could grow all three without bound. A prompt
//! that would wait past `queueMaxPrompts` or `queueMaxBytes` is refused before anything is
//! copied or written, with `queue.full` or `queue.bytes` and what to do; nothing is dropped.
//!
//! Only a new prompt that would wait is checked (`queue.rs` `queue_slot`). One that runs at once
//! holds nothing here, and the prompts a restart rebuilds, a failed turn holds or an edit
//! changes were admitted already.

use super::Session;
use super::queue::Slot;
use crate::config::Config;
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::atomic::Ordering;

/// `queueMaxPrompts` and `queueMaxBytes`; None is no limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct QueueLimits {
    pub(super) prompts: Option<u64>,
    pub(super) bytes: Option<u64>,
}

impl QueueLimits {
    pub(super) const DEFAULT_PROMPTS: u64 = 1000;
    pub(super) const DEFAULT_BYTES: u64 = 256 << 20;

    /// The config's limits, or their defaults; 0 is no limit.
    pub(super) fn of(cfg: &Config) -> Self {
        let limit = |v: Option<u64>, default: u64| Some(v.unwrap_or(default)).filter(|&n| n != 0);
        Self {
            prompts: limit(cfg.queue_max_prompts, Self::DEFAULT_PROMPTS),
            bytes: limit(cfg.queue_max_bytes, Self::DEFAULT_BYTES),
        }
    }
}

/// Refused unless `session`'s queue has room for `p`: one more prompt, and its content. The
/// count is every prompt waiting (`Session::queued`, those about to queue too); the bytes are
/// those of the prompts in the queue, which a prompt waiting for the turn lock does not hold yet.
pub(super) fn room(session: &Session, p: &Slot<'_>, limits: QueueLimits) -> Result<(), RpcError> {
    let queued = session.queued.load(Ordering::SeqCst);
    if let Some(max) = limits.prompts
        && queued >= max
    {
        return Err(full(
            "queue.full",
            format!(
                "this chat's queue is full: {queued} prompts wait and the limit is {max} \
                 (queueMaxPrompts); send it again once some have run, or remove some"
            ),
            json!({"limit": max, "queued": queued}),
        ));
    }
    let Some(max) = limits.bytes else { return Ok(()) };
    let adding = blocks_bytes(p.blocks) + p.display_parts.map_or(0, bytes);
    let held: u64 = {
        let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        queue
            .iter()
            .map(|q| blocks_bytes(&q.run.blocks) + q.run.display_parts.as_ref().map_or(0, bytes))
            .sum()
    };
    if held.saturating_add(adding) > max {
        return Err(full(
            "queue.bytes",
            format!(
                "this chat's queue is full: its waiting prompts hold {held} bytes, this one \
                 {adding}, and the limit is {max} (queueMaxBytes); send it again once some have \
                 run, or send its files as uploads"
            ),
            json!({"limit": max, "queuedBytes": held, "bytes": adding, "queued": queued}),
        ));
    }
    Ok(())
}

fn full(reason: &str, message: String, mut data: Value) -> RpcError {
    data["reason"] = json!(reason);
    data["retryable"] = json!(true);
    RpcError::new(-32000, message).with_data(data)
}

fn blocks_bytes(blocks: &[Value]) -> u64 {
    blocks.iter().map(bytes).sum()
}

/// About what `v` takes as JSON: its strings' and keys' bytes, and a little for each value. It
/// walks the value once and allocates nothing, so it is cheap under the queue lock: a prompt is
/// a few values, an inline image one long string.
pub(super) fn bytes(v: &Value) -> u64 {
    match v {
        Value::String(s) => s.len() as u64 + 2,
        Value::Array(items) => items.iter().map(bytes).sum::<u64>() + 2,
        Value::Object(fields) => {
            fields.iter().map(|(k, v)| k.len() as u64 + 4 + bytes(v)).sum::<u64>() + 2
        }
        _ => 8,
    }
}

#[cfg(test)]
#[path = "queue_admission_tests.rs"]
mod tests;
