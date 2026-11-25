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
//! queued messages into one and so never adds a prompt. The messages it took leave the queue but
//! wait with it (`DigestTurn::taken`) until its turn takes them over, and are charged to
//! `Session::digest_bytes` meanwhile: charged in the critical section of the queue lock that takes
//! them out, released in the one that puts them back (`requeue_joined`) or once its turn has them,
//! so a new prompt always finds them in the queue or in the charge, and admission reads one number
//! under the queue lock and no other lock. Its own text is not checked: it may pass the byte limit by that much, which is at most
//! [`DIGEST_MAX_BYTES`](super::DIGEST_MAX_BYTES) of whole message texts plus, for each message it
//! took, its heading line and the first 400 characters of a text cut short. The next new prompt
//! then finds the queue full, so no prompt is admitted on top of it, and each message goes into
//! one digest (a digest that fails puts its messages back and its text goes). Refusing the digest
//! instead would leave the queue as full, one turn per message.
//!
//! Each prompt's size is measured once, where its run is made (`PromptRun::size`), so the check
//! adds up at most `queueMaxPrompts` numbers under the lock, and one for each message a waiting
//! digest took. A prompt the queue accepted already that goes back in (a Send now or a steer whose
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
/// waiting for the turn lock, whose content the queue does not hold yet; `taken` is what the
/// messages waiting digests took hold. Called with the queue locked.
pub(super) fn room(
    queue: &[QueuedPrompt],
    others: u64,
    taken: u64,
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
    let held = staying().map(|q| run_bytes(&q.run)).sum::<u64>().saturating_add(taken);
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
    if let Some(fields) = data.as_object_mut() {
        fields.insert("reason".into(), json!(reason));
        fields.insert("retryable".into(), json!(true));
    }
    RpcError::new(-32000, message).with_data(data)
}

/// About what `v` takes as JSON, and never less: each string and key with its quotes and escapes,
/// its separators, and a number at its longest. It walks the value once and allocates nothing,
/// and runs once per prompt, outside the queue lock (`PromptRun::size`).
pub(super) fn bytes(v: &Value) -> u64 {
    // The longest a JSON number is written (`-1.7976931348623157e308`).
    const NUMBER: u64 = 24;
    let items = |n: usize| n.saturating_sub(1) as u64 + 2;
    match v {
        Value::Null | Value::Bool(_) => 5,
        Value::Number(_) => NUMBER,
        Value::String(s) => string_bytes(s),
        Value::Array(values) => values.iter().map(bytes).sum::<u64>() + items(values.len()),
        Value::Object(fields) => {
            fields.iter().map(|(k, v)| string_bytes(k) + 1 + bytes(v)).sum::<u64>()
                + items(fields.len())
        }
    }
}

/// A string's bytes as JSON: its quotes, and an escape at its longest (`\u00XX`) for each byte
/// JSON escapes.
fn string_bytes(s: &str) -> u64 {
    let escapes = s.bytes().filter(|&b| b < 0x20 || b == b'"' || b == b'\\').count() as u64;
    s.len() as u64 + 2 + escapes * 5
}

#[cfg(test)]
#[path = "queue_admission_tests.rs"]
mod tests;
