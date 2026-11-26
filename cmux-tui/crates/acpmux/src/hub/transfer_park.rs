//! Part of `Hub`; see `hub/mod.rs`. A pre-copied hub move's control over the circuit its stage
//! opened (`transfer_hub_precopy.rs`), so the freeze makes no hub trips and no dial.
//!
//! Through the hub, the freeze of a pre-copied move cost (2026-11-25) `answerMs` 1028: the dial
//! 85, the pages 368, the finish 46 and about 530 ms of the `move` op's hub legs (one send, its
//! answer long-polls). The target already held a circuit to the source for the stage, so:
//!
//! 1. Target: once a stage is finished it keeps that circuit and parks on it,
//!    `await_move {transferId: <prepareId>, stageId}` ([`Hub::park_for_move`]). The source
//!    answers `{body}` (the `move` body the hub would carry) or `{none}` after [`PARK_WAIT`];
//!    `{none}` parks again, until [`PARK_FOR`] or the stage is gone.
//! 2. Source: the circuit's server (`transfer_service.rs` `serve_pages`) registers the waiter only
//!    when its Noise-proven `from` is the prepare's `to-hub` ([`Hub::park_move`]).
//!    `_acpmux/transfer_hub` with a `stageId` hands the body to that waiter
//!    ([`Hub::move_over_circuit`]) when its `from` is the move's `to-hub`.
//! 3. Target: a body for its own stage and chat is pulled ([`Hub::transfer_pull_on`]) over the
//!    same circuit (`dialMs` 0, `timings.via` `"circuit"`), then answered with
//!    `moved {transferId, result | error: {code, message, data}}`; the source answers the
//!    client with it as it would the hub's.
//!
//! The hub stays the way when no waiter is parked (an old target, a dropped circuit, a stage
//! past [`PARK_FOR`]): the body goes as op `move`. Once a body went over the circuit it never
//! goes over the hub too: a circuit lost after the hand-off answers `transfer.unanswered` with
//! `data.unknown` (the move stays frozen; its watch ends it), as a hub move with no answer does.

use super::transfer_out::{inside, transfers_dir};
use super::transfer_pull::{PageSource, TO_HUB, pull_error};
use super::*;
use tokio::sync::oneshot;

/// How long the source holds one `await_move` before it answers `{none}`: within a circuit
/// call's own wait (`transfer_service.rs` `CALL_WAIT`, 60 s).
pub const PARK_WAIT: std::time::Duration = std::time::Duration::from_secs(40);
/// How long a target keeps a stage's circuit parked for its move.
const PARK_FOR: std::time::Duration = std::time::Duration::from_secs(600);

/// Why a move handed to a parked circuit has no result.
#[derive(Debug)]
pub enum Unmoved {
    /// The body never reached the target: the hub may carry it.
    NotSent,
    /// The target refused the move, in these words.
    Refused(String),
}

/// A move's body handed to a parked circuit, and where its answer goes. A dropped `answer` is
/// a move whose outcome is unknown.
pub struct Handoff {
    pub body: Value,
    pub answer: oneshot::Sender<Result<Value, Unmoved>>,
}

/// The waiters parked on this source, by stage.
#[derive(Default)]
pub struct Parked {
    next: u64,
    waiters: HashMap<String, Waiter>,
}

struct Waiter {
    from: String,
    id: u64,
    hand: oneshot::Sender<Handoff>,
}

/// A waiter `park_move` registered: its stage, its mark and where its body comes.
pub struct Parking {
    pub stage_id: String,
    pub id: u64,
    pub hand: oneshot::Receiver<Handoff>,
}

impl Hub {
    /// `await_move` from `from`: a waiter for the stage of a prepare whose `to-hub` is `from`.
    /// A later one for the same stage takes its place (the earlier answers `{none}`).
    pub fn park_move(&self, from: &str, params: &Value) -> Result<Parking, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        let (prepare_id, stage_id) = (text("transferId"), text("stageId"));
        if !prepare_id.starts_with("pre-")
            || !super::transfer::is_plain_id(prepare_id)
            || !super::transfer::is_plain_id(stage_id)
        {
            return Err(RpcError::invalid_params("await_move: a prepare and its stage"));
        }
        let dir = inside(&transfers_dir(), prepare_id)?;
        let to = std::fs::read_to_string(dir.join(TO_HUB)).ok();
        if from.is_empty() || to.as_deref().map(str::trim) != Some(from) {
            return Err(pull_error("not_yours", "this move does not go to the machine that asks"));
        }
        let (hand, rx) = oneshot::channel();
        let mut parked = self.parked_moves.lock().unwrap_or_else(|e| e.into_inner());
        parked.next += 1;
        let id = parked.next;
        parked.waiters.insert(stage_id.to_owned(), Waiter { from: from.to_owned(), id, hand });
        Ok(Parking { stage_id: stage_id.to_owned(), id, hand: rx })
    }

    /// The waiter `id` of `stage_id` is gone (answered, timed out or its circuit closed).
    pub fn unpark_move(&self, stage_id: &str, id: u64) {
        let mut parked = self.parked_moves.lock().unwrap_or_else(|e| e.into_inner());
        if parked.waiters.get(stage_id).is_some_and(|w| w.id == id) {
            parked.waiters.remove(stage_id);
        }
    }

    /// Whether a circuit is parked here for the move of `stage_id`.
    pub fn has_parked_move(&self, stage_id: &str) -> bool {
        let parked = self.parked_moves.lock().unwrap_or_else(|e| e.into_inner());
        parked.waiters.contains_key(stage_id)
    }

    /// The handoff, to the waiter of `stage_id` parked by `daemon`; it back when there is none.
    fn hand_parked(&self, stage_id: &str, daemon: &str, handoff: Handoff) -> Result<(), Handoff> {
        let mut parked = self.parked_moves.lock().unwrap_or_else(|e| e.into_inner());
        if !parked.waiters.get(stage_id).is_some_and(|w| w.from == daemon) {
            return Err(handoff);
        }
        let Some(waiter) = parked.waiters.remove(stage_id) else { return Err(handoff) };
        // Sent under the lock: a waiter whose circuit closes closes its receiver and then
        // takes what was sent, so a body is either taken or handed back here.
        waiter.hand.send(handoff)
    }

    /// The `move` `body` of a pre-copied move over the circuit `daemon` parked for `stage_id`:
    /// None when no waiter took it (the hub carries it), else `transfer_hub`'s answer.
    pub(super) async fn move_over_circuit(
        &self,
        daemon: &str,
        stage_id: &str,
        body: Value,
        wait: std::time::Duration,
    ) -> Option<Result<Value, RpcError>> {
        let (answer, answered) = oneshot::channel();
        if self.hand_parked(stage_id, daemon, Handoff { body, answer }).is_err() {
            return None;
        }
        match tokio::time::timeout(wait, answered).await {
            Ok(Ok(Ok(moved))) => Some(Ok(json!({"moved": moved, "daemonId": daemon}))),
            Ok(Ok(Err(Unmoved::NotSent))) => None,
            Ok(Ok(Err(Unmoved::Refused(why)))) => Some(Err(super::transfer_pull::refused(&why))),
            Ok(Err(_)) | Err(_) => Some(Err(super::transfer_pull::unanswered(daemon, "move"))),
        }
    }

    /// The target's side: the circuit `pages` that staged `stage_id` from `source`'s prepare
    /// `prepare_id`, parked for the move of `session_id` until it comes, the stage goes or
    /// [`PARK_FOR`] passes.
    pub(super) async fn park_for_move(
        self: Arc<Self>,
        mut pages: Box<dyn PageSource>,
        source: String,
        source_host: Option<String>,
        prepare_id: String,
        stage_id: String,
        session_id: String,
    ) {
        let until = tokio::time::Instant::now() + PARK_FOR;
        let stage = transfers_dir().join(format!("in-{stage_id}"));
        while tokio::time::Instant::now() < until && stage.is_dir() {
            let asked = json!({"transferId": prepare_id, "stageId": stage_id});
            let Ok(answer) = pages.call("await_move", asked).await else { return };
            let Some(body) = answer.get("body").filter(|b| b.is_object()) else { continue };
            let text = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("");
            let transfer_id = text("transferId").to_owned();
            let pulled = if text("stageId") != stage_id || text("sessionId") != session_id {
                Err(RpcError::invalid_params("move: the body names another stage or chat"))
            } else {
                let host = source_host.as_deref();
                self.transfer_pull_on(&source, host, body, Some(&mut *pages)).await
            };
            let moved = match pulled {
                Ok(result) => json!({"transferId": transfer_id, "result": result}),
                Err(e) => json!({"transferId": transfer_id,
                                 "error": {"code": e.code, "message": e.message, "data": e.data}}),
            };
            if let Err(e) = pages.call("moved", moved).await {
                tracing::warn!(
                    stage_id,
                    "a circuit move's answer did not reach its source: {}",
                    e.message
                );
            }
            return;
        }
    }
}

/// `moved {transferId, result | error}` on the source: the answer for the move `answering`
/// handed to this circuit.
pub fn take_moved(
    answering: &mut Option<(String, oneshot::Sender<Result<Value, Unmoved>>)>,
    params: &Value,
) -> Result<Value, RpcError> {
    let transfer_id = params.get("transferId").and_then(Value::as_str).unwrap_or("");
    if !answering.as_ref().is_some_and(|(id, _)| id == transfer_id) {
        return Err(pull_error("unknown", format!("no move {transfer_id:?} waits here")));
    }
    let Some((_, answer)) = answering.take() else { return Ok(json!({})) };
    let result = match params.get("error").filter(|e| e.is_object()) {
        Some(error) => {
            let why = error.get("message").and_then(Value::as_str).unwrap_or("refused");
            Err(Unmoved::Refused(why.to_owned()))
        }
        None => Ok(params.get("result").cloned().unwrap_or(Value::Null)),
    };
    let _ = answer.send(result);
    Ok(json!({}))
}

#[cfg(test)]
#[path = "transfer_park_tests.rs"]
mod tests;
