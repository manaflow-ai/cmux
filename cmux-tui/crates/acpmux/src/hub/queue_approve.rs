//! Part of `Hub`; see `hub/mod.rs`. A person's prompt that waits for the owner (chat
//! multiplayer, Share with guest, hq#4766). `_meta.acpmux.author.approval: "owner"` (`author.rs`)
//! puts it in the queue marked `awaiting_owner` at `revision` 0, never steered in and never
//! stopping the running turn, and every way a queued prompt reaches the agent passes it by
//! (`QueuedPrompt::aside`: the queue's turn order, a digest of agent messages, a retry's busy
//! test, a restart). Only the owner answers it, under the queue's lock, so the first answer wins:
//! - `_acpmux/queue_approve {sessionId, promptId, revision}`: it waits no more and runs in its
//!   place in the queue as any queued prompt (never as a steer). `revision` must be the one it has
//!   now, else `queue.stale`, so the owner approves the words they saw. The log records
//!   `queue_approved {promptId, turnId, revision, approvedAt}`.
//! - `_acpmux/queue_decline {sessionId, promptId}`: it leaves the queue and never runs; its
//!   `session/prompt` answers an error with `data.reason` `queue.declined`, and the log records
//!   `queue_declined {promptId, turnId, revision, declinedAt}`, then `queue_removed {reason:
//!   "declined"}`.
//!
//! An answer to a prompt that no longer waits gets `queue.not_found`, with `decided`
//! (`approved`, `declined` or `removed`) once the log says which. A request that carries an author
//! is refused `queue.owner_only` (`author::owner_only`). The person's own edit (the next revision,
//! still waiting) and removal still work; once approved, their edit is refused `queue.approved`,
//! and their move, send now and interrupt are refused `queue.awaiting_owner` approved or not, as
//! they would run it out of its place. A restart rebuilds all of it from the log
//! (`restore_queue`).

use super::*;
use std::sync::atomic::Ordering;

/// What the `session/prompt` of a declined prompt answers.
pub(super) fn declined_error(prompt_id: &str, turn_id: &str) -> RpcError {
    RpcError::new(-32000, "queue.declined: the chat's owner declined this prompt; it never ran")
        .with_data(json!({"reason": "queue.declined", "promptId": prompt_id, "turnId": turn_id}))
}

/// What its author's edit of an approved prompt gets: it runs the words the owner approved.
pub(in crate::hub) fn approved_error() -> RpcError {
    let msg = "the chat's owner approved this prompt as it is; remove it and send another";
    refused(-32602, "queue.approved", msg, json!({}))
}

/// The most prompts one person has waiting for the owner at once.
const MAX_HELD_PER_AUTHOR: usize = 16;

/// `queue.too_many_held` when the prompt's author already has [`MAX_HELD_PER_AUTHOR`] prompts
/// waiting for the owner. Called with the queue locked by the insertion, before recording it.
pub(super) fn held_cap(queue: &[QueuedPrompt], provenance: Option<&Value>) -> Result<(), RpcError> {
    let author = crate::author::of_provenance(provenance);
    let held = queue.iter().filter(|q| q.awaiting_owner && q.sender() == author).count();
    if held < MAX_HELD_PER_AUTHOR {
        return Ok(());
    }
    let msg = format!("{held} of your prompts already wait for the chat's owner");
    let data = json!({"max": MAX_HELD_PER_AUTHOR});
    Err(refused(-32602, "queue.too_many_held", &msg, data))
}

/// `queue.awaiting_owner` for a prompt whose every version waits for the owner, approved or
/// not: moved, sent now or interrupted for, it would run out of its place or before the owner said
/// so. Checked under the queue lock that would change it (`queue_edit.rs`, `put_next`).
pub(in crate::hub) fn released(q: &QueuedPrompt) -> Result<(), RpcError> {
    if q.awaiting_owner || crate::author::awaits_owner(q.run.provenance.as_ref()) {
        let msg = "this prompt runs only in its place, once the chat's owner approves it";
        return Err(refused(-32602, "queue.awaiting_owner", msg, json!({})));
    }
    Ok(())
}

fn refused(code: i64, reason: &str, message: &str, mut data: Value) -> RpcError {
    data["reason"] = json!(reason);
    RpcError::new(code, format!("{reason}: {message}")).with_data(data)
}

impl Hub {
    /// `_acpmux/queue_approve`: the prompt at `revision` runs in its place in the queue.
    pub fn approve_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        revision: u64,
    ) -> Result<(), RpcError> {
        if session.moving().is_some() {
            return Err(moving_error());
        }
        {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let found = queue.iter_mut().find(|q| q.prompt_id == prompt_id && q.awaiting_owner);
            let Some(q) = found else {
                drop(queue);
                return Err(self.not_waiting(session, prompt_id));
            };
            if q.revision != revision {
                let msg = "the prompt was edited since; approve the words it has now";
                let data = json!({"promptId": prompt_id, "revision": q.revision});
                return Err(refused(-32602, "queue.stale", msg, data));
            }
            // It runs in its place, never as a steer, whatever flag a race left on it.
            (q.awaiting_owner, q.steer) = (false, false);
            let msg = json!({"promptId": prompt_id, "turnId": q.turn_id, "revision": revision,
                             "approvedAt": now_ms()});
            // The session summary's queue changed (`awaitingOwner`), as a `queue_order` changes it.
            session.state_seq.fetch_add(1, Ordering::SeqCst);
            // Logged under the lock that approved it: the author's removal, which takes this lock
            // too, is logged after it, so the log's order is the queue's (`not_waiting`, restore).
            self.append(session, "mux", "queue_approved", msg);
        }
        session.queue_moved.notify_waiters();
        Ok(())
    }

    /// `_acpmux/queue_decline`: takes a prompt that waits for the owner out of the queue, as
    /// `remove_queued` does; its `session/prompt` answers `queue.declined`.
    pub fn decline_queued(&self, session: &Arc<Session>, prompt_id: &str) -> Result<(), RpcError> {
        if session.moving().is_some() {
            return Err(moving_error());
        }
        let (removed, mut ledger) = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let found = queue.iter().position(|q| q.prompt_id == prompt_id && q.awaiting_owner);
            let Some(i) = found else {
                drop(queue);
                return Err(self.not_waiting(session, prompt_id));
            };
            // Pinned before it leaves the queue, as `remove_queued_by` pins it.
            let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
            session.queued.fetch_sub(1, Ordering::SeqCst);
            let removed = queue.remove(i);
            removed.declined.store(true, Ordering::SeqCst);
            // Logged under the lock that took it out, as `queue_approved` is.
            let msg = json!({"promptId": prompt_id, "turnId": removed.turn_id,
                             "revision": removed.revision, "declinedAt": now_ms()});
            self.append(session, "mux", "queue_declined", msg);
            (removed, ledger)
        };
        self.settle_removed(session, removed, &mut ledger, json!({"reason": "declined"}));
        Ok(())
    }

    /// `transfer.held_prompts` while any prompt of the chat waits for the owner: a move would
    /// take it to a daemon that may not hold it (`transfer_out.rs`). Approve or decline it first.
    pub(in crate::hub) fn held_prompts(&self, session: &Session) -> Result<(), RpcError> {
        let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let held: Vec<&str> =
            queue.iter().filter(|q| q.awaiting_owner).map(|q| q.prompt_id.as_str()).collect();
        if held.is_empty() {
            return Ok(());
        }
        let msg = "a prompt waits for the chat's owner: approve or decline it, then move the chat";
        let data = json!({"promptIds": held});
        Err(refused(-32000, "transfer.held_prompts", msg, data))
    }

    /// `queue.not_found` for an answer to a prompt that does not wait for the owner, with how its
    /// latest incarnation (the turn id of the last `queued` record under that prompt id, which a
    /// client may reuse) was decided: the last of its decision records, which are logged in the
    /// order the queue changed (`approve_queued`).
    fn not_waiting(&self, session: &Session, prompt_id: &str) -> RpcError {
        let approved = session.queue().iter().any(|q| {
            q.prompt_id == prompt_id && crate::author::awaits_owner(q.run.provenance.as_ref())
        });
        let mut decided = approved.then_some("approved");
        if decided.is_none() {
            let mut turn: Option<String> = None;
            let kinds = ["queued", "queue_approved", "queue_declined", "queue_removed"];
            let _ = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
                let field = |k: &str| e.msg.get(k).and_then(Value::as_str);
                if field("promptId") != Some(prompt_id) {
                    return true;
                }
                if e.kind == "queued" {
                    (turn, decided) = (field("turnId").map(str::to_owned), None);
                } else if turn.is_some() && field("turnId") == turn.as_deref() {
                    decided = Some(match (e.kind.as_str(), field("reason")) {
                        ("queue_approved", _) => "approved",
                        ("queue_declined", _) | (_, Some("declined")) => "declined",
                        _ => "removed",
                    });
                }
                true
            });
        }
        let mut data = json!({"promptId": prompt_id});
        if let Some(decided) = decided {
            data["decided"] = json!(decided);
        }
        refused(-32002, "queue.not_found", "no prompt waits for the owner under this id", data)
    }
}

#[cfg(test)]
#[path = "queue_approve_tests.rs"]
mod tests;
