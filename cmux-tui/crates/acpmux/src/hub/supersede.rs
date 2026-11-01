//! Part of `Hub` (declared in `queue.rs`). `_meta.acpmux.supersede` on `session/prompt`
//! (`acpmux send --supersede KEY`): a prompt replaces the prompts its sender still has waiting
//! in the queue under the same key. Prompts queue behind running turns, so without it a
//! correction is read after the order it corrects.
//!
//! A replaced prompt leaves the queue as a withdrawn one does (`remove_queued`): its
//! `session/prompt` answers withdrawn, its `queue_removed` record says `reason: "superseded"`
//! and `supersededBy`, and a restart never runs it (`restore_queue` drops a removed prompt).
//! Only a prompt that still waits is replaced: one whose turn started, or that is being sent
//! into the running turn, stays. The sender is the queue's own notion of it (`digest.rs`
//! `agent_sender`): an agent's name, or `None` for the person. The new prompt's acceptance
//! carries `replaced` (a count) and `replacedPromptIds`. It happens where the prompt is
//! committed, never before a refusal: a queued one inside `enqueue` (under the queue lock, after
//! the moving and watched checks), one that starts at once when its turn starts, a steer once it
//! is recorded. A forwarded prompt names its sender to the peer (`peer_forward.rs`).

use super::super::*;
use super::PromptLedger;
use crate::rpc::RpcError;

/// Longest key, in bytes.
pub const MAX_KEY_BYTES: usize = 256;

/// `_meta.acpmux.supersede` of a `session/prompt`: `None` when absent or null; refused
/// (`supersede.invalid`) when it is not a non-empty string of at most `MAX_KEY_BYTES`.
pub fn key(params: &Value) -> Result<Option<String>, RpcError> {
    match params.pointer("/_meta/acpmux/supersede") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(k)) if !k.is_empty() && k.len() <= MAX_KEY_BYTES => Ok(Some(k.clone())),
        Some(_) => Err(RpcError::invalid_params(format!(
            "supersede.invalid: supersede must be a non-empty string of at most {MAX_KEY_BYTES} bytes"
        ))
        .with_data(json!({"reason": "supersede.invalid"}))),
    }
}

/// Adds what a prompt replaced to its acceptance, unless the path that committed it did.
pub(in crate::hub) fn mark(accepted: &mut Value, replaced: Option<&Vec<String>>) {
    if !accepted.is_object() || accepted.get("replaced").is_some() {
        return;
    }
    let ids = replaced.cloned().unwrap_or_default();
    accepted["replaced"] = json!(ids.len());
    accepted["replacedPromptIds"] = json!(ids);
}

/// Whether the queued prompt `q` is `sender`'s under `key`, waiting, and not `by` itself.
pub(in crate::hub) fn superseded(
    q: &QueuedPrompt,
    key: &str,
    sender: Option<&str>,
    by: &str,
) -> bool {
    !q.steer
        && q.prompt_id != by
        && q.run.supersede.as_deref() == Some(key)
        && q.run.agent.as_deref() == sender
}

/// Takes the prompts `by` replaces out of the locked `queue`, in queue order, and counts them out
/// of the session's queued total. The caller settles them (`settle_superseded`) after it holds the
/// prompt ledger and lets the queue go.
pub(in crate::hub) fn take(
    session: &Session,
    queue: &mut Vec<QueuedPrompt>,
    key: &str,
    sender: Option<&str>,
    by: &str,
) -> Vec<QueuedPrompt> {
    let mut gone = Vec::new();
    let mut i = 0;
    while i < queue.len() {
        if superseded(&queue[i], key, sender, by) {
            gone.push(queue.remove(i));
        } else {
            i += 1;
        }
    }
    if !gone.is_empty() {
        session.queued.fetch_sub(gone.len() as u64, std::sync::atomic::Ordering::SeqCst);
    }
    gone
}

impl Hub {
    /// Takes `sender`'s prompts still waiting under `key` out of the queue, replaced by `by`, and
    /// returns their prompt ids in queue order. A prompt that queues does this inside `enqueue`,
    /// under the lock that puts it in, so two sends under one key never both stay.
    pub(in crate::hub) fn supersede_queued(
        &self,
        session: &Arc<Session>,
        key: &str,
        sender: Option<&str>,
        by: &str,
    ) -> Vec<String> {
        let (gone, mut ledger) = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let gone = take(session, &mut queue, key, sender, by);
            // Pinned before the queue lets them go, as `remove_queued_with` pins one.
            (gone, session.prompts.lock().unwrap_or_else(|e| e.into_inner()))
        };
        self.settle_superseded(session, gone, &mut ledger, by)
    }

    /// Settles the prompts `take` removed, each as `remove_queued_with` settles one.
    pub(in crate::hub) fn settle_superseded(
        &self,
        session: &Arc<Session>,
        gone: Vec<QueuedPrompt>,
        ledger: &mut PromptLedger,
        by: &str,
    ) -> Vec<String> {
        let ids = gone.iter().map(|q| q.prompt_id.clone()).collect();
        for removed in gone {
            let why = json!({"reason": "superseded", "supersededBy": by});
            self.settle_removed(session, removed, ledger, why);
        }
        ids
    }
}
