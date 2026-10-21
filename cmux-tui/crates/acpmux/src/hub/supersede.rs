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
//! carries `replaced` (a count) and `replacedPromptIds`.

use super::super::*;
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

/// Adds what a prompt replaced to its acceptance.
pub(in crate::hub) fn mark(accepted: &mut Value, replaced: Option<&Vec<String>>) {
    let ids = replaced.cloned().unwrap_or_default();
    accepted["replaced"] = json!(ids.len());
    accepted["replacedPromptIds"] = json!(ids);
}

impl Hub {
    /// Takes `sender`'s prompts still waiting under `key` out of the queue, replaced by
    /// `by`, and returns their prompt ids in queue order.
    pub(in crate::hub) fn supersede_queued(
        &self,
        session: &Arc<Session>,
        key: &str,
        sender: Option<&str>,
        by: &str,
    ) -> Vec<String> {
        let ids: Vec<String> = session
            .queue()
            .iter()
            .filter(|q| {
                !q.steer
                    && q.prompt_id != by
                    && q.run.supersede.as_deref() == Some(key)
                    && q.run.agent.as_deref() == sender
            })
            .map(|q| q.prompt_id.clone())
            .collect();
        ids.into_iter()
            .filter(|id| {
                self.remove_queued_with(
                    session,
                    id,
                    json!({"reason": "superseded", "supersededBy": by}),
                )
            })
            .collect()
    }
}
