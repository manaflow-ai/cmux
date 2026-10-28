//! A suggested task's result back in the chat that offered it (cx-lo9yf).
//!
//! When the chat an accepted offer started (`offers.rs`) ends its first turn, however the
//! turn stopped, the offering chat gets one prompt:
//!
//! ```text
//! Result from the suggested task "<title>" (chat <childSessionId>):
//! <the child's last agent message of that turn, at most 4000 characters, or "(no reply)">
//! ```
//!
//! Its `user_message` (and `queued`) record carries `_meta.provenance = {kind:
//! "offer_result", offerId, childSessionId, title}` (`prompt_provenance::offer_result`),
//! set here: no client sends it, so the pane policy and `remote_guard.rs` are unchanged.
//! It steers into a running turn of an agent that steers, else starts or waits in the
//! queue, as `cmux agent message` does (`deliver.rs`); the parent agent then answers it.
//!
//! - Once per offer, across restarts: the parent's log decides (a `user_message` or
//!   `queued` with that offer's result provenance), and the prompt id
//!   `offer-result-<offerId>` runs once.
//! - Only a chat with a parent that is not a fork, and that the parent's log names as an
//!   accepted offer's `childSessionId`, sends: a parent's own turns send nothing for it.
//! - The person may accept after the child's first turn ended: the answer sends it then.

use super::{Hub, PromptOptions, Session};
use crate::no_panic::JsonExt;
use crate::rpc::method;
use crate::store::EventRecord;
use crate::supervised::{Fatal, ShutdownBehavior};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;

/// Longest reply sent back, in characters.
const MAX_REPLY_CHARS: usize = 4000;

/// The accepted offer that started a chat, from its parent's log.
struct Started {
    offer_id: String,
    title: String,
    /// The parent has the result already.
    sent: bool,
}

impl Hub {
    /// Sends `child`'s first reply to the chat whose offer started it, once. Nothing for
    /// any other chat, or before the child's first turn ended.
    pub(super) fn send_offer_result(self: &Arc<Self>, child: &Arc<Session>) {
        let meta = child.meta();
        let Some(parent_id) = meta.parent_id else { return };
        if meta.fork_seq.is_some() || meta.last_turn.is_none() {
            return;
        }
        // One sender per chat on this daemon: a turn end and the answer may race.
        if !self.offers.results.lock().unwrap_or_else(|e| e.into_inner()).insert(child.id.clone()) {
            return;
        }
        let (hub, child) = (self.clone(), child.clone());
        // Off the turn's path: the logs are read from disk, and the parent's turn runs.
        self.supervise("hub.offer-result", Fatal, ShutdownBehavior::Skip, async move {
            if !hub.offer_result(&child, &parent_id).await {
                hub.offers.results.lock().unwrap_or_else(|e| e.into_inner()).remove(&child.id);
            }
        });
    }

    /// Sends the result; false when it was neither sent nor due (another turn retries).
    async fn offer_result(self: &Arc<Self>, child: &Arc<Session>, parent_id: &str) -> bool {
        let Ok(parent) = self.resolve(parent_id) else { return false };
        let Some(started) = self.started_by_offer(&parent, &child.id) else { return false };
        if started.sent {
            return true;
        }
        let text = format!(
            "Result from the suggested task \"{}\" (chat {}):\n{}",
            started.title,
            child.id,
            self.first_reply(child)
        );
        let provenance =
            crate::prompt_provenance::offer_result(&started.offer_id, &child.id, &started.title);
        let opts = PromptOptions {
            prompt_id: Some(format!("offer-result-{}", started.offer_id)),
            resend: true,
            provenance: Some(provenance),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        match self.prompt_with(&parent, blocks, "acpmux", true, opts).await {
            Ok(_) => true,
            Err(e) => {
                tracing::warn!(session = %parent.id, "suggested task result: {}", e.message);
                // A prompt refused before it was recorded may be sent again.
                self.started_by_offer(&parent, &child.id).is_some_and(|s| s.sent)
            }
        }
    }

    /// The accepted offer of `parent` that started chat `child`, if any.
    fn started_by_offer(&self, parent: &Session, child: &str) -> Option<Started> {
        let mut titles: HashMap<String, String> = HashMap::new();
        let mut started: Option<Started> = None;
        let text = |e: &EventRecord, key: &str| {
            e.msg.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
        };
        // Streamed, not collected: a long chat's log stays on disk.
        let scanned = self.store.scan(&parent.id, 0, &mut |e: EventRecord| {
            if e.dir != "mux" {
                return true;
            }
            match e.kind.as_str() {
                "session_offer" if started.is_none() => {
                    titles.insert(text(&e, "offerId"), text(&e, "title"));
                }
                "session_offer_decision"
                    if started.is_none()
                        && e.msg.field("outcome") == "accepted"
                        && e.msg.field("childSessionId") == child =>
                {
                    let offer_id = text(&e, "offerId");
                    let title = titles.remove(&offer_id).unwrap_or_default();
                    started = Some(Started { offer_id, title, sent: false });
                }
                "user_message" | "queued" => {
                    let p = e.msg.pointer("/_meta/provenance");
                    if let (Some(s), Some(p)) = (started.as_mut(), p)
                        && p["kind"] == "offer_result"
                        && p["offerId"] == s.offer_id.as_str()
                    {
                        s.sent = true;
                        return false;
                    }
                }
                _ => {}
            }
            true
        });
        scanned.ok()?;
        started
    }

    /// The last agent message of `child`'s first turn: the chat's own, not a subagent's.
    fn first_reply(&self, child: &Session) -> String {
        let mut reply = String::new();
        // The last agent update was part of a message: a new chunk adds to it.
        let mut open = false;
        let _ = self.store.scan(&child.id, 0, &mut |e: EventRecord| {
            if e.dir == "mux" && matches!(e.kind.as_str(), "turn_end" | "turn_error") {
                return false;
            }
            let update = e.dir == "in"
                && !e.kind.ends_with(".replay")
                && e.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
                && e.msg.pointer("/params/_meta/acpmux/subagent").is_none();
            if update {
                match e.kind.as_str() {
                    "agent_message_chunk" => {
                        if !open {
                            reply.clear();
                            open = true;
                        }
                        let chunk = e.msg.pointer("/params/update/content/text");
                        reply.push_str(chunk.and_then(Value::as_str).unwrap_or_default());
                    }
                    "tool_call" | "tool_call_update" | "agent_thought_chunk" | "plan" => {
                        open = false;
                    }
                    _ => {}
                }
            }
            true
        });
        let reply = reply.trim();
        if reply.is_empty() {
            return "(no reply)".to_owned();
        }
        if reply.chars().count() <= MAX_REPLY_CHARS {
            return reply.to_owned();
        }
        let mut cut: String = reply.chars().take(MAX_REPLY_CHARS).collect();
        cut.push('…');
        cut
    }
}
