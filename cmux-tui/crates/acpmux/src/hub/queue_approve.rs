//! Part of `Hub`; see `hub/mod.rs`. A person's prompt that waits for the owner (chat
//! multiplayer, Share with guest, hq#4766). `_meta.acpmux.author.approval: "owner"` (`author.rs`)
//! puts it in the queue marked `awaiting_owner` at `revision` 0, never steered in and never
//! stopping the running turn, and every way a queued prompt reaches the agent passes it by
//! (`QueuedPrompt::aside`: the queue's turn order, a digest of agent messages, a retry's busy
//! test, a restart). Only the owner answers it, under the queue's lock, so the first answer wins:
//! - `_acpmux/queue_approve {sessionId, promptId, turnId, revision}`: it waits no more and runs in its
//!   place in the queue as any queued prompt (never as a steer). `revision` must be the one it has
//!   now, and `turnId` must name that queued incarnation, else `queue.stale`, so the owner
//!   approves the words they saw even when a client reuses a prompt id. The log records
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
pub(in crate::hub) fn declined_error(prompt_id: &str, turn_id: &str) -> RpcError {
    RpcError::new(-32000, "queue.declined: the chat's owner declined this prompt; it never ran")
        .with_data(json!({"reason": "queue.declined", "promptId": prompt_id, "turnId": turn_id}))
}

/// What its author's edit of an approved prompt gets: it runs the words the owner approved.
pub(in crate::hub) fn approved_error() -> RpcError {
    let msg = "the chat's owner approved this prompt as it is; remove it and send another";
    refused(-32602, "queue.approved", msg, json!({}))
}

/// The rules the owner's approval came under (`server/requests/queued.rs`): the approved prompt
/// runs under the stricter of these and its sender's (`PromptRun::restricted`).
pub struct Approver<'a> {
    pub control: Control,
    /// From the app's pane or the Web, which run a prompt only in a trusted folder
    /// (`server/trust_gate.rs`).
    pub trust_gate: bool,
    /// The paired machine whose Full-access setting covers the request (`remote_guard.rs`).
    pub device: Option<&'a str>,
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

/// A move that carries prompts the owner approved that still wait for their place, refused
/// because nothing vouches that the daemon taking the bundle understands `queue_approved`: an
/// older one would run them under their sender's rules alone (`transfer_out.rs`, `transfer_in.rs`,
/// the move client's `cli/run/transfer.rs`).
pub(crate) fn approved_prompts_error(ids: Value, why: &str) -> RpcError {
    let msg = format!(
        "an approved prompt still waits for its turn and {why}: let it run (or remove it), then \
         move the chat"
    );
    refused(-32000, "transfer.approved_prompts", &msg, json!({"promptIds": ids}))
}

fn refused(code: i64, reason: &str, message: &str, mut data: Value) -> RpcError {
    data.set("reason", json!(reason));
    RpcError::new(code, format!("{reason}: {message}")).with_data(data)
}

impl Hub {
    /// `_acpmux/queue_approve`: the prompt at `revision` runs in its place in the queue, under
    /// the stricter of its sender's rules and the owner's who approved it (`by`).
    pub fn approve_queued(
        &self,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        revision: u64,
        by: &Approver<'_>,
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
            if q.turn_id != turn_id || q.revision != revision {
                let msg = "the prompt was replaced or edited since; approve the words it has now";
                let data =
                    json!({"promptId": prompt_id, "turnId": q.turn_id, "revision": q.revision});
                return Err(refused(-32602, "queue.stale", msg, data));
            }
            // It runs in its place, never as a steer, whatever flag a race left on it.
            (q.awaiting_owner, q.steer) = (false, false);
            // An approval from the Web lets it run only as a Web prompt would: under the Web's
            // control, its trust gate and its Full-access machine, checked again at dispatch
            // (`check_dispatch`) and kept for a restart (review of #26747).
            q.run = Arc::new(q.run.restricted(by.control, by.trust_gate, by.device));
            let msg = json!({"promptId": prompt_id, "turnId": q.turn_id, "revision": revision,
                             "approvedAt": now_ms(), "control": q.run.control.as_str(),
                             "trustGate": q.run.trust_gate});
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

    /// Validate the immutable exported log, not the live queue: a removal that passed its
    /// moving check before the freeze can finish after export and is absent from the bundle.
    /// An older target must never receive a snapshot with a prompt still awaiting approval.
    /// One the owner approved that still waits for its place keeps `awaitingOwner` on its
    /// `queued` record, and only a receiver that understands `queue_approved` runs it under the
    /// approved rules: those are returned, for the move to name in its manifest
    /// (`approvedWaiting`, `transfer_out.rs`), so that only a receiver whose own `initialize`
    /// listed [`crate::author::QUEUE_APPROVAL_FEATURE`] takes the bundle (review of #28859).
    pub(in crate::hub) fn held_prompts(&self, bundle: &Path) -> Result<Vec<String>, RpcError> {
        use std::io::BufRead;
        let check = || -> anyhow::Result<(Vec<String>, Vec<String>)> {
            // Every segment, in name order, as import restores them (`copy_bundle_events`).
            let mut segments = Vec::new();
            for entry in std::fs::read_dir(bundle.join("events"))? {
                let path = entry?.path();
                if path.extension().is_some_and(|e| e == "ndjson") {
                    segments.push(path);
                }
            }
            segments.sort();
            let mut waiting = queue_waiting::Waiting::default();
            let mut approved: HashMap<String, u64> = HashMap::new();
            for segment in segments {
                let file = std::fs::File::open(segment)?;
                for line in std::io::BufReader::new(file).lines() {
                    let line = line?;
                    if line.trim().is_empty() {
                        continue;
                    }
                    let e: EventRecord = serde_json::from_str(&line)?;
                    let turn = e.msg.get("turnId");
                    if matches!(e.kind.as_str(), "queued" | "user_message" | "turn_started")
                        && let Some(id) = e.msg.get("promptId")
                    {
                        waiting.remove_other_turns(id, turn);
                    }
                    match e.kind.as_str() {
                        "queued" => waiting.push(e),
                        // Older daemons do not understand queue_declined. Until the subsequent
                        // legacy queue_removed is in this snapshot, they would still run it.
                        "queue_removed" | "user_message" | "turn_started" => {
                            waiting.remove_turn(turn)
                        }
                        "queue_updated" => {
                            if let Some(q) = waiting.first_of_turn(turn) {
                                for k in ["revision", "awaitingOwner"] {
                                    q.msg.set(k, e.msg.get(k).cloned().unwrap_or(Value::Null));
                                }
                            }
                        }
                        "queue_approved" => {
                            if let (Some(turn), Some(revision)) = (
                                turn.and_then(Value::as_str),
                                e.msg.get("revision").and_then(Value::as_u64),
                            ) {
                                approved.insert(turn.to_owned(), revision);
                            }
                        }
                        _ => {}
                    }
                }
            }
            // Waiting for the owner, and approved at the revision it waits with.
            let (mut held, mut approved_waiting) = (Vec::new(), Vec::new());
            for q in waiting.into_records() {
                // A link guest's record waits whatever it says (`author::awaits_owner`), as a
                // restore here holds it; an older target reads only `awaitingOwner`.
                if q.msg.get("awaitingOwner").and_then(Value::as_bool) != Some(true)
                    && !crate::author::awaits_owner(q.msg.pointer("/_meta/provenance"))
                {
                    continue;
                }
                let Some(id) = q.msg.get("promptId").and_then(Value::as_str) else { continue };
                let is_approved = q.msg.get("turnId").and_then(Value::as_str).is_some_and(|turn| {
                    q.msg
                        .get("revision")
                        .and_then(Value::as_u64)
                        .is_some_and(|revision| approved.get(turn) == Some(&revision))
                });
                if is_approved { &mut approved_waiting } else { &mut held }.push(id.to_owned());
            }
            for ids in [&mut held, &mut approved_waiting] {
                ids.sort();
                ids.dedup();
            }
            Ok((held, approved_waiting))
        };
        let (held, approved_waiting) = check()
            .map_err(|e| RpcError::internal(format!("transfer: read approval snapshot: {e}")))?;
        if !held.is_empty() {
            let msg =
                "a prompt waits for the chat's owner: approve or decline it, then move the chat";
            return Err(refused(-32000, "transfer.held_prompts", msg, json!({"promptIds": held})));
        }
        Ok(approved_waiting)
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
            data.set("decided", json!(decided));
        }
        refused(-32002, "queue.not_found", "no prompt waits for the owner under this id", data)
    }
}

#[cfg(test)]
#[path = "queue_approve_tests.rs"]
mod tests;
