//! Part of `Hub` (declared in `queue_edit.rs`, a queue change like it). `_acpmux/prompt_withdraw
//! {sessionId, msgId | promptId}` (cx-55d27, "unsend"): the sender of an agent message
//! (`prompt_provenance.rs`) takes it back. The prompt is found in the session's log by its
//! provenance `msgId` (or its `promptId`), and the answer is `{sessionId, outcome, promptId,
//! msgId?, via?, already?}`:
//!
//! - `unsent`: it still waited (queued or held): it leaves the queue with a `queue_removed`
//!   record (`reason: "withdrawn"`) and never runs. A new daemon rebuilds the queue from the log
//!   (`queue.rs` `restore_queue`), which drops a removed prompt, so a restart never runs it.
//! - `retracted`: its turn runs. A `prompt_retracted` record {promptId, msgId, turnId, via,
//!   noticePromptId} is written, and a notice that the message was withdrawn goes to the agent:
//!   steered into the running turn when the agent steers (`via: "steer"`), else queued at the
//!   head of the queue (`via: "queued"`).
//! - `too_late`: its turn ended (`turn_result`, `turn_end`, `turn_error` or `prompt_refused`);
//!   nothing changes.
//!
//! A second withdraw answers the first one's outcome again with `already: true` (an unsent
//! message stays unsent, a retracted one gets no second notice). An id the session's log does
//! not hold is `withdraw.not_found`. Only the unix socket withdraws (`remote_guard.rs`,
//! `withdraw.origin_refused`), and a peer's session is never forwarded one.

use super::super::*;
use std::time::Duration;

/// One withdraw decides (and records its outcome) at a time: two at once send one notice.
static DECIDING: StdMutex<()> = StdMutex::new(());

/// How long the answer waits for the notice to be recorded (queued or steered).
const NOTICE_WAIT: Duration = Duration::from_secs(5);

fn not_found(key: &str) -> RpcError {
    let message = format!("withdraw.not_found: this session holds no prompt {key}");
    RpcError::new(-32002, message).with_data(json!({"reason": "withdraw.not_found"}))
}

/// What the session's log says about the withdrawn prompt.
#[derive(Default)]
struct Found {
    prompt_id: String,
    turn_id: String,
    provenance: Option<Value>,
    /// Its turn started (or it was steered into one).
    started: bool,
    ended: bool,
    removed: bool,
    retracted: Option<Value>,
}

impl Found {
    fn msg_id(&self) -> String {
        let id = self.provenance.as_ref().and_then(|p| p.get("msgId")).and_then(Value::as_str);
        id.unwrap_or(&self.prompt_id).to_owned()
    }
}

/// The reply of a withdraw.
fn outcome(session: &Session, found: &Found, outcome: &str) -> Value {
    json!({"sessionId": session.id, "outcome": outcome, "promptId": found.prompt_id, "msgId": found.msg_id()})
}

impl Hub {
    /// `_acpmux/prompt_withdraw`; see the module docs.
    pub async fn prompt_withdraw(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let key = |k: &str| params.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        let (by_msg, id) = match (key("msgId"), key("promptId")) {
            (Some(id), _) => (true, id),
            (None, Some(id)) => (false, id),
            (None, None) => return Err(RpcError::invalid_params("msgId or promptId is required")),
        };
        if session.moving().is_some() {
            return Err(super::super::queue::moving_error());
        }
        let notice = {
            let _deciding = DECIDING.lock().unwrap_or_else(|e| e.into_inner());
            let found = self.find_withdrawn(session, by_msg, id).ok_or_else(|| not_found(id))?;
            let waiting = session.queue().iter().any(|q| q.prompt_id == found.prompt_id);
            if waiting && self.remove_queued_because(session, &found.prompt_id, Some("withdrawn")) {
                return Ok(outcome(session, &found, "unsent"));
            }
            if found.removed || found.retracted.is_some() {
                let was = if found.removed { "unsent" } else { "retracted" };
                let mut reply = outcome(session, &found, was);
                reply["already"] = json!(true);
                if let Some(via) = found.retracted.as_ref().and_then(|r| r.get("via")) {
                    reply["via"] = via.clone();
                }
                return Ok(reply);
            }
            if found.ended || !found.started {
                return Ok(outcome(session, &found, "too_late"));
            }
            self.record_retraction(session, found)
        };
        let (found, via, notice_id, text) = notice;
        self.send_notice(session, &found, via, notice_id, text).await;
        let mut reply = outcome(session, &found, "retracted");
        reply["via"] = json!(via);
        Ok(reply)
    }

    /// The first prompt the log holds under `id` (its provenance `msgId` when `by_msg`, else its
    /// `promptId`) and what became of it.
    fn find_withdrawn(&self, session: &Session, by_msg: bool, id: &str) -> Option<Found> {
        let mut found: Option<Found> = None;
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or_default();
            if found.is_none() {
                let hit = if by_msg {
                    e.msg.pointer("/_meta/provenance/msgId").and_then(Value::as_str) == Some(id)
                } else {
                    field("promptId") == id
                };
                if hit && matches!(e.kind.as_str(), "queued" | "user_message") {
                    found = Some(Found {
                        prompt_id: field("promptId").to_owned(),
                        turn_id: field("turnId").to_owned(),
                        provenance: e.msg.pointer("/_meta/provenance").cloned(),
                        started: e.kind == "user_message",
                        ..Found::default()
                    });
                }
                return true;
            }
            let Some(f) = found.as_mut() else { return true };
            let same_turn = !f.turn_id.is_empty() && field("turnId") == f.turn_id;
            match e.kind.as_str() {
                "user_message" | "dequeued" | "turn_started" if same_turn => f.started = true,
                "queue_removed" if same_turn => f.removed = true,
                "turn_result" | "turn_end" | "turn_error" | "prompt_refused" if same_turn => {
                    f.ended = true;
                }
                "prompt_retracted" if field("promptId") == f.prompt_id => {
                    f.retracted = Some(e.msg.clone());
                }
                _ => {}
            }
            true
        });
        found
    }

    /// Records that a running message is retracted, and how its notice goes: steered into its
    /// turn when the agent steers and that turn runs now, else queued next.
    fn record_retraction(
        &self,
        session: &Session,
        found: Found,
    ) -> (Found, &'static str, String, String) {
        let steer = session.steering.load(Ordering::SeqCst)
            && session.turn().is_some_and(|t| t.turn_id == found.turn_id);
        let via = if steer { "steer" } else { "queued" };
        let msg_id = found.msg_id();
        let from = found.provenance.as_ref().and_then(|p| p.get("from")).and_then(Value::as_str);
        let text = format!(
            "The message {msg_id} from {} was withdrawn by its sender; disregard it.",
            from.unwrap_or("its sender")
        );
        let notice_id = format!("{}.withdrawn", found.prompt_id);
        self.append(
            session,
            "mux",
            "prompt_retracted",
            json!({"promptId": found.prompt_id, "msgId": msg_id, "turnId": found.turn_id, "via": via, "noticePromptId": notice_id}),
        );
        (found, via, notice_id, text)
    }

    /// Sends the retraction notice (as the sender's message) and waits until it is recorded:
    /// steered in, or queued and moved to the head of the queue.
    async fn send_notice(
        self: &Arc<Self>,
        session: &Arc<Session>,
        found: &Found,
        via: &'static str,
        notice_id: String,
        text: String,
    ) {
        let provenance = found.provenance.clone().map(|mut p| {
            p["replyTo"] = json!(found.msg_id());
            p["msgId"] = json!(format!("{}.withdrawn", found.msg_id()));
            p
        });
        let (tx, rx) = oneshot::channel::<()>();
        let (hub, queued_in) = (self.clone(), session.clone());
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |accepted: Value| {
            if accepted.get("queued") == Some(&json!(true))
                && let Some(id) = accepted.get("promptId").and_then(Value::as_str)
            {
                hub.move_queued(&queued_in, id, 0);
            }
            let _ = tx.send(());
        });
        let opts = PromptOptions {
            prompt_id: Some(notice_id),
            on_accepted: Some(on_accepted),
            provenance,
            ..PromptOptions::default()
        };
        let (hub, chat) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            if let Err(e) = hub.prompt_with(&chat, blocks, "acpmux", via == "steer", opts).await {
                tracing::warn!(session = %chat.id, "withdraw notice: {}", e.message);
            }
        });
        if tokio::time::timeout(NOTICE_WAIT, rx).await.is_err() {
            tracing::warn!(session = %session.id, "withdraw notice not recorded yet");
        }
    }
}
