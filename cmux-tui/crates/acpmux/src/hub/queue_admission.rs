//! How much one chat's queue holds (manaflow-ai/cmuxterm-hq#2930). Each waiting prompt keeps
//! its whole blocks in memory and in its `queued` record, and every restore replays them, so a
//! client that sends faster than the agent runs could grow all three without bound. A prompt
//! that would wait past `queueMaxPrompts` or `queueMaxBytes` is refused before anything is
//! copied or written, with `queue.full` or `queue.bytes` and what to do; nothing is dropped.
//!
//! The check runs in `queue.rs` `enqueue`, under the queue lock that puts the prompt in, so two
//! prompts cannot both take the last room, and every way a new prompt joins the queue passes it
//! (it waits behind a turn, behind a turn that began as it took the lock, or for a parent's run
//! slot). The prompts a supersede key replaces leave as it comes in, so they do not count against
//! it. Not checked: the prompts a restart rebuilds, a failed turn or a Stop holds, or an edit
//! changes, which were admitted already, and an inbox digest (`inbox_digest.rs`), which joins
//! queued messages into one and so never adds a prompt.
//!
//! Each prompt's size is measured once, where its run is made (`PromptRun::size`), so the check
//! adds up at most `queueMaxPrompts` numbers under the lock. A digest is charged with the messages
//! it holds. A prompt the queue accepted already that goes back in (a Send now or a steer whose
//! turn ended first, `PromptOptions::admitted`) is never refused for room.

use super::queue::{PromptRun, QueuedPrompt, Slot};
use crate::config::Config;
use crate::rpc::RpcError;
use serde_json::{Value, json};

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

/// Refused unless `queue` has room for one more prompt of `size` bytes, not counting the prompts
/// it `replaces`. `others` is every other prompt waiting (`Session::queued`), the queue's and those
/// waiting for the turn lock, whose content the queue does not hold yet. Called with the queue
/// locked.
pub(super) fn room(
    queue: &[QueuedPrompt],
    others: u64,
    size: u64,
    replaces: impl Fn(&QueuedPrompt) -> bool,
    limits: QueueLimits,
) -> Result<(), RpcError> {
    let staying = || queue.iter().filter(|q| !replaces(q));
    let replaced = (queue.len() - staying().count()) as u64;
    let queued = others.saturating_sub(replaced).max(staying().count() as u64);
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
    let held: u64 = staying().map(|q| run_bytes(&q.run)).sum();
    if held.saturating_add(size) > max {
        return Err(full(
            "queue.bytes",
            format!(
                "this chat's queue is full: its waiting prompts hold {held} bytes, this one \
                 {size}, and the limit is {max} (queueMaxBytes); send it again once some have \
                 run, or remove some"
            ),
            json!({"limit": max, "queuedBytes": held, "bytes": size, "queued": queued}),
        ));
    }
    Ok(())
}

/// What a prompt asking for its turn would hold in the queue.
pub(super) fn slot_bytes(p: &Slot<'_>) -> u64 {
    content_bytes(p.blocks, p.display_parts)
}

/// What a queued prompt holds, measured the first time it is asked.
pub(super) fn run_bytes(run: &PromptRun) -> u64 {
    *run.size.get_or_init(|| content_bytes(&run.blocks, run.display_parts.as_ref()))
}

pub(super) fn content_bytes(blocks: &[Value], display_parts: Option<&Value>) -> u64 {
    blocks.iter().map(bytes).sum::<u64>() + display_parts.map_or(0, bytes)
}

fn full(reason: &str, message: String, mut data: Value) -> RpcError {
    data["reason"] = json!(reason);
    data["retryable"] = json!(true);
    RpcError::new(-32000, message).with_data(data)
}

/// About what `v` takes as JSON, and no less than the memory its strings hold: each string's and
/// key's bytes with their quotes, its separators, and a number at its longest. It walks the value
/// once and allocates nothing: a prompt is a few values, an inline image one long string.
pub(super) fn bytes(v: &Value) -> u64 {
    // The longest a JSON number is written (`-1.7976931348623157e308`).
    const NUMBER: u64 = 24;
    let items = |n: usize| n.saturating_sub(1) as u64 + 2;
    match v {
        Value::Null | Value::Bool(_) => 5,
        Value::Number(_) => NUMBER,
        Value::String(s) => s.len() as u64 + 2,
        Value::Array(values) => values.iter().map(bytes).sum::<u64>() + items(values.len()),
        Value::Object(fields) => {
            fields.iter().map(|(k, v)| k.len() as u64 + 3 + bytes(v)).sum::<u64>()
                + items(fields.len())
        }
    }
}

#[cfg(test)]
#[path = "queue_admission_tests.rs"]
mod tests;
