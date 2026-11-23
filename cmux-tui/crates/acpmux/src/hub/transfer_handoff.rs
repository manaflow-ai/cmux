//! Part of `Hub` (a child of `transfer_out.rs`). The acked hand-off of a chat move, opt-in per
//! move (`transfer_begin {ackedHandoff: true}`, `acpmux session transfer --acked-handoff`):
//! idea w47-25 of cmuxterm-hq goals/super-highway.md (0 lost messages across a move).
//!
//! A prompt checks the chat's `moving` mark when it arrives (`queue.rs` `queue_slot`) and puts
//! itself in the queue later, under the queue's lock (`enqueue`). One that passed the check just
//! before a move froze the chat goes in after the bundle was made: its `queued` record is not in
//! the bundle, so the target never has it, and the commit withdraws it here. Its sender was told
//! it was accepted (an outbox delivery is `delivered`), so the message is lost.
//!
//! With the hand-off:
//!
//! 1. The begin notes, under the queue's lock and before the bundle is made, which prompts the
//!    queue holds (`handoff-base` beside the bundle): every one of them is in the bundle.
//! 2. The commit reads the queue again. Each prompt in it that the base does not name came in
//!    after the bundle was made. Each gets the move's next sequence number and goes, in queue
//!    order, to the target's outbox under its own prompt id, marked `resend` (one the bundle did
//!    carry joins its copy there, never runs twice). The commit waits for the target's ack of
//!    each one (its delivery `delivered`, or held by the target's outbox) before it commits; one
//!    that is not acked refuses the commit, so the client may try it again, and the chat stays
//!    frozen here with the prompt still in its queue.
//! 3. The queue is read once more after the chat is marked moved, for one that went in during
//!    the hand-off, and those are handed off the same way.
//!
//! The `transferred` record lists what was handed off (`handedOff: [{seq, promptId, ack}]`).
//! Without `ackedHandoff` none of this runs.

use super::*;

/// The file beside a move's bundle naming the prompts its queue held as the bundle was made.
const BASE_FILE: &str = "handoff-base";

/// How long the commit waits for the target to ack one handed-off prompt.
const ACK_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// How long one `send_status` waits on the target for the delivery to settle.
const STATUS_WAIT_MS: u64 = 2_000;

/// Notes the prompts `session`'s queue holds now, beside the bundle at `dir`. Called with the
/// turn lock held and the chat frozen, before the bundle is made.
pub(super) fn note_base(session: &Session, dir: &Path) -> Result<(), RpcError> {
    let ids: Vec<String> = {
        let queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        queue.iter().map(|q| q.prompt_id.clone()).collect()
    };
    crate::home_fs::write(dir.join(BASE_FILE), json!(ids).to_string())
        .map_err(|e| RpcError::internal(format!("transfer: handoff base: {e}")))
}

/// Whether the move at `dir` hands off (its begin noted a base).
pub(super) fn acked(dir: &Path) -> bool {
    dir.join(BASE_FILE).is_file()
}

/// The prompt ids the base at `dir` names.
fn base(dir: &Path) -> std::collections::HashSet<String> {
    std::fs::read(dir.join(BASE_FILE))
        .ok()
        .and_then(|raw| serde_json::from_slice::<Vec<String>>(&raw).ok())
        .unwrap_or_default()
        .into_iter()
        .collect()
}

/// One prompt handed to the target: its sequence number in the move, and the target's ack.
#[derive(Clone, Debug)]
pub(super) struct HandedOff {
    pub seq: u64,
    pub prompt_id: String,
    pub ack: Value,
}

impl HandedOff {
    pub(super) fn record(&self) -> Value {
        json!({"seq": self.seq, "promptId": self.prompt_id, "ack": self.ack})
    }
}

/// The `session/prompt` params that run `q` on the target chat `target`: its blocks under its
/// own prompt id, marked `resend` so a copy the bundle carried answers instead of running again.
fn request_for(q: &QueuedPrompt, target: &str, transfer_id: &str, seq: u64) -> Value {
    let mut mux = json!({
        "promptId": q.prompt_id,
        "resend": true,
        "handoff": {"transferId": transfer_id, "seq": seq},
    });
    if let Some(id) = &q.run.message_id {
        mux.set("messageId", json!(id));
    }
    json!({"sessionId": target, "prompt": q.run.blocks, "_meta": {"acpmux": mux}})
}

/// Whether a target's `send_status` answer is an ack: the target's chat took it, or the target's
/// outbox holds it (it owns the delivery from here, on disk). A failed delivery is no ack.
fn is_ack(status: &Value) -> bool {
    let state = status.get("status").or_else(|| status.get("state")).and_then(Value::as_str);
    matches!(state, Some("delivered" | "queued" | "delivering" | "held"))
}

fn is_delivered(status: &Value) -> bool {
    let state = status.get("status").or_else(|| status.get("state")).and_then(Value::as_str);
    state == Some("delivered")
}

/// Hands `q` to the target daemon at `socket` (its chat `target`) and waits for its ack.
async fn hand_one(
    socket: &Path,
    target: &str,
    transfer_id: &str,
    seq: u64,
    q: &QueuedPrompt,
) -> Result<Value, String> {
    let client = crate::client::Client::connect_without_caller(socket)
        .await
        .map_err(|e| format!("the target daemon does not answer: {e}"))?;
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-handoff"}});
    client.request(method::INITIALIZE, init).await.map_err(|e| e.to_string())?;
    let request = request_for(q, target, transfer_id, seq);
    let queued = client
        .request(method::MUX_SEND_QUEUE, json!({"request": request}))
        .await
        .map_err(|e| format!("the target did not take it: {e}"))?;
    let Some(delivery) = queued.get("deliveryId").and_then(Value::as_str).map(str::to_owned) else {
        return Err(format!("the target's answer names no delivery: {queued}"));
    };
    // The target's outbox kept it on disk before it answered; wait a little for its chat to take
    // it, so the move's freeze ends with the prompt in the target's queue in the common case.
    let status = client
        .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": STATUS_WAIT_MS}))
        .await
        .unwrap_or(queued);
    if is_ack(&status) {
        let mut ack = json!({"deliveryId": delivery});
        ack.set("delivered", json!(is_delivered(&status)));
        Ok(ack)
    } else {
        Err(format!("the target's delivery did not settle: {status}"))
    }
}

impl Hub {
    /// Step 2 and 3 of the hand-off (see the module's doc): hands every prompt in the queue that
    /// is not in `already` (the base, and what was handed off before) to the target, in order,
    /// numbering them from `next_seq`, and waits for each ack. Each acked prompt leaves the
    /// queue here. Errors on the first prompt the target does not ack in [`ACK_WAIT`]; the ones
    /// before it stay handed off, and a retried commit goes on after them.
    pub(super) async fn hand_off_stragglers(
        &self,
        session: &Arc<Session>,
        dir: &Path,
        transfer_id: &str,
        to: &Value,
        handed: &mut Vec<HandedOff>,
    ) -> Result<(), RpcError> {
        let mut already = base(dir);
        already.extend(handed.iter().map(|h| h.prompt_id.clone()));
        let stragglers: Vec<QueuedPrompt> =
            session.queue().into_iter().filter(|q| !already.contains(&q.prompt_id)).collect();
        if stragglers.is_empty() {
            return Ok(());
        }
        let socket = std::fs::read_to_string(dir.join("to"))
            .ok()
            .or_else(|| to.get("socket").and_then(Value::as_str).map(str::to_owned));
        let target = to.get("sessionId").and_then(Value::as_str).unwrap_or(&session.id);
        let Some(socket) = socket.filter(|s| s.starts_with('/')) else {
            return Err(transfer_error(
                "handoff",
                "prompts came in after the bundle was made and the move names no target socket",
            ));
        };
        let socket = PathBuf::from(socket.trim());
        for q in stragglers {
            let seq = handed.len() as u64 + 1;
            let acked =
                tokio::time::timeout(ACK_WAIT, hand_one(&socket, target, transfer_id, seq, &q))
                    .await
                    .unwrap_or_else(|_| Err(format!("no ack in {} s", ACK_WAIT.as_secs())));
            match acked {
                Ok(ack) => {
                    tracing::info!(
                        session = %session.id, transfer = transfer_id, seq,
                        prompt = %q.prompt_id, "transfer: handed off a prompt"
                    );
                    self.remove_queued_because(session, &q.prompt_id, Some("handed_off"));
                    handed.push(HandedOff { seq, prompt_id: q.prompt_id.clone(), ack });
                }
                Err(why) => {
                    return Err(transfer_error(
                        "handoff",
                        format!("prompt {} (seq {seq}) was not acked: {why}", q.prompt_id),
                    ));
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ack_is_a_target_that_took_it_or_holds_it() {
        assert!(is_ack(&json!({"status": "delivered"})));
        assert!(is_ack(&json!({"status": "queued"})));
        assert!(is_ack(&json!({"status": "held"})));
        assert!(!is_ack(&json!({"status": "failed"})));
        assert!(!is_ack(&json!({})));
        assert!(is_delivered(&json!({"status": "delivered"})));
        assert!(!is_delivered(&json!({"status": "queued"})));
    }

    #[test]
    fn a_base_names_what_the_queue_held() {
        let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!acked(&dir));
        std::fs::write(dir.join(BASE_FILE), r#"["p1","p2"]"#).unwrap();
        assert!(acked(&dir));
        let names = base(&dir);
        assert!(names.contains("p1") && names.contains("p2") && names.len() == 2);
        let _ = std::fs::remove_dir_all(dir);
    }
}
