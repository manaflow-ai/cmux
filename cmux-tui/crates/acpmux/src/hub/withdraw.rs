//! Part of `Hub` (declared in `queue_edit.rs`, a queue change like it). `_acpmux/prompt_withdraw
//! {sessionId, msgId | promptId}` (cx-55d27, "unsend"): the sender of an agent message
//! (`prompt_provenance.rs`) takes it back. The prompt is found in the session's log by its
//! provenance `msgId` (or its `promptId`), and the answer is `{sessionId, outcome, promptId,
//! msgId?, via?, already?}`:
//!
//! - `unsent`: it still waited (queued or held): it leaves the queue with a `queue_removed`
//!   record (`reason: "withdrawn"`) and never runs. A new daemon rebuilds the queue from the log
//!   (`queue.rs` `restore_queue`), which drops a removed prompt, so a restart never runs it.
//! - `retracted`: its turn runs. A notice that the message was withdrawn goes to the agent:
//!   steered into the running turn when the agent steers (`via: "steer"`), else queued at the
//!   head of the queue (`via: "queued"`). Once the notice is recorded, a `prompt_retracted`
//!   record {promptId, msgId, turnId, via, noticePromptId} is written; a notice that is not
//!   recorded within `NOTICE_WAIT` (refused, or the chat began a move) writes nothing and answers
//!   `withdraw.notice_failed`, so the sender may withdraw again.
//! - An inbox item (`inbox.rs`, a plain send from another agent): `unsent` while no notice carried
//!   it (an `inbox_removed` record, `reason: "withdrawn"`); once one did, `retracted` with
//!   `via: "inbox"`: the notice goes into its thread in the chat's inbox.
//! - `too_late`: its turn ended (`turn_result`, `turn_end`, `turn_error` or `prompt_refused`);
//!   nothing changes. The prompt is followed by its `promptId`: a send-now steers it into the
//!   running turn, and a steer that found no turn runs it as the next one, each under that turn.
//!
//! A second withdraw answers the first one's outcome again with `already: true` (an unsent
//! message stays unsent, a retracted one gets no second notice). Refused: an id the session's
//! log does not hold (`withdraw.not_found`); a prompt without a provenance, the person's own
//! (`withdraw.not_a_message`); a queued message the person edited, which made it theirs
//! (`withdraw.edited`). Only the unix socket withdraws (`remote_guard.rs`,
//! `withdraw.origin_refused`), and a peer's session is never forwarded one.

use super::super::*;
use cmux_json::JsonSet as _;
use std::sync::OnceLock;
use std::time::Duration;

/// One withdraw at a time, from the decision until its outcome is recorded: two at once send
/// one notice.
static DECIDING: OnceLock<Mutex<()>> = OnceLock::new();

/// How long the answer waits for the notice to be recorded (queued or steered).
const NOTICE_WAIT: Duration = Duration::from_secs(5);
/// How long a withdraw waits for a notice that carries its inbox message and is not written yet.
const INBOX_SETTLE: Duration = Duration::from_secs(10);

fn refusal(code: i64, reason: &str, message: &str) -> RpcError {
    RpcError::new(code, format!("{reason}: {message}")).with_data(json!({"reason": reason}))
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
    /// The person edited it while it waited (`queue_updated`).
    edited: bool,
    retracted: Option<Value>,
    /// An inbox item (`inbox.rs`), and its thread: no turn of its own; a notice carried it once
    /// an `inbox_noticed` record names it.
    inbox: Option<String>,
}

impl Found {
    fn msg_id(&self) -> String {
        let id = self.provenance.as_ref().and_then(|p| p.get("msgId")).and_then(Value::as_str);
        id.unwrap_or(&self.prompt_id).to_owned()
    }

    /// Follows one later record of the session's log.
    fn follow(&mut self, e: &EventRecord) {
        let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or_default();
        if self.inbox.is_some() {
            let names = |k: &str| {
                e.msg.get(k).and_then(Value::as_array).is_some_and(|ids| {
                    ids.iter().any(|id| id.as_str() == Some(self.prompt_id.as_str()))
                })
            };
            match e.kind.as_str() {
                "inbox_noticed" if names("promptIds") => self.started = true,
                "inbox_removed" if field("promptId") == self.prompt_id => self.removed = true,
                "prompt_retracted" if field("promptId") == self.prompt_id => {
                    self.retracted = Some(e.msg.clone());
                }
                _ => {}
            }
            return;
        }
        // A send-now steer, or a steer run as the next turn: the prompt moved to that turn.
        if matches!(e.kind.as_str(), "user_message" | "turn_started")
            && field("promptId") == self.prompt_id
            && !field("turnId").is_empty()
            && field("turnId") != self.turn_id
        {
            self.turn_id = field("turnId").to_owned();
            self.ended = false;
        }
        // Back in the queue after the turn of agent messages it joined failed (`digest.rs`).
        if e.kind == "queued"
            && e.msg.get("requeued") == Some(&Value::Bool(true))
            && field("promptId") == self.prompt_id
        {
            self.turn_id = field("turnId").to_owned();
            (self.started, self.ended) = (false, false);
            return;
        }
        let same_turn = !self.turn_id.is_empty() && field("turnId") == self.turn_id;
        // It went in with an earlier agent message's turn (`digest.rs`): that turn is its own.
        if e.kind == "dequeued" && same_turn && !field("joinedTurnId").is_empty() {
            self.turn_id = field("joinedTurnId").to_owned();
            (self.started, self.ended) = (true, false);
            return;
        }
        match e.kind.as_str() {
            "user_message" | "dequeued" | "turn_started" if same_turn => self.started = true,
            "queue_removed" if same_turn => self.removed = true,
            "queue_updated" if same_turn => self.edited = true,
            "turn_result" | "turn_end" | "turn_error" | "prompt_refused" if same_turn => {
                self.ended = true;
            }
            "prompt_retracted" if field("promptId") == self.prompt_id => {
                self.retracted = Some(e.msg.clone());
            }
            _ => {}
        }
    }
}

/// The reply of a withdraw.
fn outcome(session: &Session, found: &Found, outcome: &str) -> Value {
    json!({"sessionId": session.id, "outcome": outcome, "promptId": found.prompt_id, "msgId": found.msg_id()})
}

/// What a withdraw does once it read the log.
enum Decision {
    Reply(Value),
    Retract(Found),
}

/// The name a reply from `session` is signed with (`fromName`): its title, else its name, else
/// its id, on one line, without control, bidi or zero-width marks, at most `MAX_NAME_CHARS`
/// characters, as `prompt_provenance::of` takes one. acpmux writes it; the pane never picks one.
fn sender_name(session: &Session) -> Option<String> {
    let meta = session.meta();
    [meta.title.unwrap_or_default(), meta.name, session.id.clone()].iter().find_map(|raw| {
        let shown: String = raw.chars().filter(|c| !unshown_mark(*c)).collect();
        let line = shown.split_whitespace().collect::<Vec<_>>().join(" ");
        let name: String = line.chars().take(crate::prompt_provenance::MAX_NAME_CHARS).collect();
        Some(name.trim().to_owned()).filter(|name| !name.is_empty())
    })
}

/// A character a provenance field may not hold: a control, or a bidi or zero-width mark.
fn unshown_mark(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}'
        )
}

impl Hub {
    /// The provenance of a `session/prompt` from a connection of `origin`
    /// (`prompt_provenance::of`): the unix socket's only. The app pane's reply in place is no
    /// prompt (`server/app_reply.rs`).
    pub(crate) fn prompt_provenance(
        params: &Value,
        origin: crate::server::Origin,
        trigger: bool,
    ) -> Result<Option<Value>, RpcError> {
        use crate::prompt_provenance::Sender;
        let sender = if trigger {
            Sender::Trigger
        } else if origin == crate::server::Origin::Local {
            Sender::Local
        } else {
            Sender::Other
        };
        crate::prompt_provenance::of(params, sender)
    }

    /// The app pane's reply in place (`server/app_reply.rs`, as a provenance) as acpmux signs it,
    /// when it answers a real message as what the pane may speak for; `None` refuses it. Default
    /// deny; each must hold:
    /// - `from` is `acp:<id>` and `to` is `acp:<to>`, the addresses `cmux agent message` uses
    ///   (`agent_message_prompt.rs` `provenance`), so the sender's chat links the reply back;
    /// - `<id>` is a chat here other than `to` that this connection `shows` (attached and not
    ///   held unseen): the chat the pane draws, not any chat that got the message;
    /// - its log holds a `user_message` that `to` sent it as an agent message under the id the
    ///   reply names (`replyTo`);
    /// - `threadId` is that message's thread (its `threadId`, else its `msgId`).
    ///
    /// `fromName` is never the pane's: acpmux signs the reply with the chat's own name
    /// (`sender_name`), so a renamed chat's reply is never refused for a stale title. The pane
    /// cannot then put words in a chat's mouth beyond answering, as that chat, what it was sent.
    pub(crate) fn app_reply_fits(
        &self,
        provenance: &Value,
        to: &str,
        shows: &dyn Fn(&str) -> bool,
    ) -> Option<Value> {
        let field = |k: &str| provenance.get(k).and_then(Value::as_str).unwrap_or_default();
        let (reply_to, thread) = (field("replyTo"), field("threadId"));
        let from = field("from").strip_prefix("acp:")?;
        if field("to").strip_prefix("acp:") != Some(to)
            || from == to
            || reply_to.is_empty()
            || thread.is_empty()
        {
            return None;
        }
        let session = self.resolve(from).ok()?;
        if session.id != from || !shows(&session.id) {
            return None;
        }
        let mut answered = false;
        let fits = |m: &Value| {
            let p = |k: &str| m.get(k).and_then(Value::as_str);
            p("kind") == Some("agent_message")
                && p("msgId") == Some(reply_to)
                && p("threadId").or(p("msgId")) == Some(thread)
                // `cmux agent message` names a chat `acp:<id>` (PaletteNavigationEntry.swift).
                && p("from").is_some_and(|f| f.strip_prefix("acp:").unwrap_or(f) == to)
        };
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            let Some(p) = e.msg.pointer("/_meta/provenance").filter(|_| e.kind == "user_message")
            else {
                return true;
            };
            answered = match p.get("messages").and_then(Value::as_array) {
                // It went in with other agents' messages (`digest.rs`): each keeps its provenance.
                Some(joined)
                    if p.get("kind").and_then(Value::as_str)
                        == Some(super::digest::DIGEST_KIND) =>
                {
                    joined.iter().filter_map(|m| m.get("provenance")).any(fits)
                }
                _ => fits(p),
            };
            !answered
        });
        if !answered {
            return None;
        }
        let mut signed = provenance.clone();
        let fields = signed.as_object_mut()?;
        match sender_name(&session) {
            Some(name) => fields.insert("fromName".to_owned(), Value::String(name)),
            None => fields.remove("fromName"),
        };
        Some(signed)
    }

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
        // An inbox message a notice carries that is not written yet: decided once it was written
        // (retracted) or ended (still new, so unsent). Waited for outside the lock every withdraw
        // takes, and for at most `INBOX_SETTLE`: a notice still on its way then (queued behind a
        // turn) is retracted, and the retraction goes into its thread next to it.
        let prompt_id = match by_msg {
            true => self.find_withdrawn(session, true, id).map(|f| f.prompt_id),
            false => Some(id.to_owned()),
        };
        if let Some(prompt_id) = prompt_id {
            let settle = self.inbox_settled(session, &prompt_id);
            let _ = tokio::time::timeout(INBOX_SETTLE, settle).await;
        }
        let _deciding = DECIDING.get_or_init(|| Mutex::new(())).lock().await;
        let found = match self.decide(session, by_msg, id)? {
            Decision::Reply(reply) => return Ok(reply),
            Decision::Retract(found) => found,
        };
        let steer = found.inbox.is_none()
            && session.steering.load(Ordering::SeqCst)
            && session.turn().is_some_and(|t| t.turn_id == found.turn_id);
        let via = match (&found.inbox, steer) {
            (Some(_), _) => "inbox",
            (None, true) => "steer",
            (None, false) => "queued",
        };
        // One id per attempt: a notice that failed leaves its id in the prompt ledger.
        let notice_id = format!("{}.withdrawn.{}", found.prompt_id, uuid::Uuid::now_v7());
        if !self.send_notice(session, &found, steer, &notice_id).await {
            let message = "the retraction notice did not reach the agent; withdraw again";
            return Err(refusal(-32000, "withdraw.notice_failed", message));
        }
        self.append(
            session,
            "mux",
            "prompt_retracted",
            json!({"promptId": found.prompt_id, "msgId": found.msg_id(), "turnId": found.turn_id, "via": via, "noticePromptId": notice_id}),
        );
        let mut reply = outcome(session, &found, "retracted");
        reply.set("via", json!(via));
        Ok(reply)
    }

    /// Unsends a waiting message, or answers what became of it, or says to retract it.
    fn decide(&self, session: &Arc<Session>, by_msg: bool, id: &str) -> Result<Decision, RpcError> {
        let lookup = || {
            let missing = format!("this session holds no prompt {id}");
            self.find_withdrawn(session, by_msg, id)
                .ok_or_else(|| refusal(-32002, "withdraw.not_found", &missing))
        };
        let mut found = lookup()?;
        // A person's prompt (`author.rs`) is no agent message either.
        if found.provenance.is_none()
            || crate::author::of_provenance(found.provenance.as_ref()).is_some()
        {
            let message = "the prompt is the person's own, not an agent message";
            return Err(refusal(-32602, "withdraw.not_a_message", message));
        }
        if found.edited {
            let message = "the person edited this message, so it is no longer the sender's";
            return Err(refusal(-32602, "withdraw.edited", message));
        }
        // An inbox item no notice carried yet leaves the inbox; one a notice carried is retracted
        // with a notice into its thread.
        if found.inbox.is_some() && !found.removed && found.retracted.is_none() {
            match self.inbox_unsend(session, &found.prompt_id) {
                super::super::inbox::Unsend::Unsent => {
                    return Ok(Decision::Reply(outcome(session, &found, "unsent")));
                }
                // Written since, or still on its way past `INBOX_SETTLE` (above): retracted.
                super::super::inbox::Unsend::Noticed | super::super::inbox::Unsend::Carried => {
                    found.started = true
                }
                super::super::inbox::Unsend::Gone => {}
            }
        }
        if session.queue().iter().any(|q| q.prompt_id == found.prompt_id) {
            if self.remove_queued_because(session, &found.prompt_id, Some("withdrawn")) {
                return Ok(Decision::Reply(outcome(session, &found, "unsent")));
            }
            // It left the queue between the scan and the removal: its turn took it (or another
            // client removed it). Read the log again; a turn that took it but has not logged
            // it yet counts as started.
            found = lookup()?;
            found.started |= !found.removed;
        }
        if found.removed || found.retracted.is_some() {
            let was = if found.removed { "unsent" } else { "retracted" };
            let mut reply = outcome(session, &found, was);
            reply.set("already", json!(true));
            if let Some(via) = found.retracted.as_ref().and_then(|r| r.get("via")) {
                reply.set("via", via.clone());
            }
            return Ok(Decision::Reply(reply));
        }
        if found.ended || !found.started {
            return Ok(Decision::Reply(outcome(session, &found, "too_late")));
        }
        Ok(Decision::Retract(found))
    }

    /// The first prompt the log holds under `id` (its provenance `msgId` when `by_msg`, else its
    /// `promptId`) and what became of it.
    fn find_withdrawn(&self, session: &Session, by_msg: bool, id: &str) -> Option<Found> {
        let mut found: Option<Found> = None;
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            if let Some(f) = found.as_mut() {
                f.follow(&e);
                return true;
            }
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).unwrap_or_default();
            let hit = if by_msg {
                e.msg.pointer("/_meta/provenance/msgId").and_then(Value::as_str) == Some(id)
            } else {
                field("promptId") == id
            };
            if hit && matches!(e.kind.as_str(), "queued" | "user_message" | "inbox") {
                found = Some(Found {
                    prompt_id: field("promptId").to_owned(),
                    turn_id: field("turnId").to_owned(),
                    provenance: e.msg.pointer("/_meta/provenance").cloned(),
                    started: e.kind == "user_message",
                    inbox: (e.kind == "inbox").then(|| field("threadId").to_owned()),
                    ..Found::default()
                });
            }
            true
        });
        found
    }

    /// Sends the retraction notice (as the sender's message): steered into the running turn, or
    /// queued and moved to the head of the queue. True once it is recorded (a resend of a notice
    /// counts when the log holds it); false when it is refused or not recorded in time.
    async fn send_notice(
        self: &Arc<Self>,
        session: &Arc<Session>,
        found: &Found,
        steer: bool,
        notice_id: &str,
    ) -> bool {
        let msg_id = found.msg_id();
        let from = found.provenance.as_ref().and_then(|p| p.get("from")).and_then(Value::as_str);
        let text = format!(
            "The message {msg_id} from {} was withdrawn by its sender; disregard it.",
            from.unwrap_or("its sender")
        );
        let provenance = found.provenance.clone().map(|mut p| {
            p.set("replyTo", json!(msg_id));
            p.set("msgId", json!(format!("{msg_id}.withdrawn")));
            p
        });
        let (tx, rx) = oneshot::channel::<bool>();
        let (hub, queued_in) = (self.clone(), session.clone());
        let on_accepted: Box<dyn FnOnce(Value) + Send> = Box::new(move |accepted: Value| {
            let duplicate = accepted.get("duplicate") == Some(&json!(true));
            if !duplicate
                && accepted.get("queued") == Some(&json!(true))
                && accepted.get("inbox") != Some(&json!(true))
                && let Some(id) = accepted.get("promptId").and_then(Value::as_str)
            {
                let _ = hub.move_queued(&queued_in, id, 0, None);
            }
            let _ = tx.send(!duplicate);
        });
        let opts = PromptOptions {
            prompt_id: Some(notice_id.to_owned()),
            on_accepted: Some(on_accepted),
            provenance,
            // An inbox item's notice goes into its thread, never a turn of its own.
            thread: found.inbox.clone(),
            inbox: found.inbox.is_some(),
            ..PromptOptions::default()
        };
        let (hub, chat) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            if let Err(e) = hub.prompt_with(&chat, blocks, "acpmux", steer, opts).await {
                tracing::warn!(session = %chat.id, "withdraw notice: {}", e.message);
            }
        });
        match tokio::time::timeout(NOTICE_WAIT, rx).await {
            Ok(Ok(true)) => true,
            // A resend of the notice's id: it counts only if it was recorded the first time.
            Ok(Ok(false)) => self.find_withdrawn(session, false, notice_id).is_some(),
            // Refused before it was recorded (the sender dropped), or not recorded in time.
            Ok(Err(_)) | Err(_) => {
                tracing::warn!(session = %session.id, "withdraw notice not recorded");
                false
            }
        }
    }
}
