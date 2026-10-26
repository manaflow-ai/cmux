//! `_acpmux/retry` (`server/agent_messages.rs`), `acpmux retry` and the sub-session tool
//! `retry_session`: a chat's failed last turn, retried now in the same session. The webview's
//! Retry button calls it (subsession-card's ask, from Leo's "this needs to retry :(",
//! 2026-10-26).
//!
//! - A retry that waits (the session row's `retry`, `auto_resume.rs`) fires now: its wait ends
//!   at once, and the answer names its prompt id (no turn yet).
//! - Else, when the last turn failed, it is sent again as the next attempt of its prompt
//!   (`P~resume-n` after the failed `P` or `P~resume-(n-1)`, as an automatic continuation's):
//!   the same prompt (its text and the images acpmux kept) when the turn produced nothing, and
//!   the continuation an automatic retry sends (`continue_text`) when the model had started on
//!   it, a message was steered into it, or the prompt cannot be rebuilt (a document, an image
//!   not kept). One id runs once (`Hub::prompt_with`), so a double click sends one prompt.
//! - Refused with `retry.busy` while a turn runs, a prompt waits to run or a continuation is
//!   about to start, and with `retry.nothing_failed` when the last turn did not fail.
//! - A retry that names a subagent (`subagentId`) asks for that subagent, never the chat's own
//!   turn: refused with `retry.subagent_unsupported` until subagents retry (`Hub::retry`).
//! - It runs under the caller's rules (`control`, the trust gate), checked again as any
//!   prompt's are. Its `user_message` carries `_meta.provenance = {kind: "auto_resume",
//!   promptId, attempt, turnId, manual: true}`, and once its turn completes the prompts the
//!   failed turn held go on (`held_by`).
//! - A Stop the failed turn got does not hold a retry the caller asks for after it.

use super::{Mark, SUFFIX, continue_text, split_attempt, still_cut};
use crate::hub::{Control, Hub, PromptOptions, Session};
use crate::protocol::session::{RetryKind, RetryResult};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::sync::Arc;

/// The rules a retry's prompt runs under: the caller's, as for a prompt it sent.
pub struct RetryBy {
    pub control: Control,
    pub trust_gate: bool,
    pub full_access_device: Option<String>,
}

fn refused(reason: &str, why: &str) -> RpcError {
    RpcError::invalid_params(format!("{reason}: {why}")).with_data(json!({"reason": reason}))
}

fn busy() -> RpcError {
    refused("retry.busy", "a turn runs or is about to start in this chat; retry once it ends")
}

fn subagent_unsupported() -> RpcError {
    refused(
        "retry.subagent_unsupported",
        "this daemon does not retry a subagent yet; retry the chat's turn without subagentId",
    )
}

fn nothing_failed() -> RpcError {
    refused(
        "retry.nothing_failed",
        "the chat's last turn did not fail, so there is nothing to retry",
    )
}

fn answer(prompt_id: String, turn_id: Option<String>) -> Value {
    let result = RetryResult { prompt_id, turn_id, kind: RetryKind::Turn };
    serde_json::to_value(result).unwrap_or(Value::Null)
}

/// `user_message` `msg`'s blocks as the agent got them: its text, and each image from the bytes
/// acpmux kept (`image(id)`). None when a part cannot be rebuilt (a document, an audio clip, a
/// link, an image not kept) or there is nothing to send.
fn prompt_blocks(msg: &Value, image: impl Fn(&str) -> Option<Value>) -> Option<Vec<Value>> {
    let blocks: Option<Vec<Value>> = match msg.get("inlineParts").and_then(Value::as_array) {
        Some(parts) => parts
            .iter()
            .map(|part| {
                let text = part.get("text").and_then(Value::as_str);
                match (part.get("kind").and_then(Value::as_str)?, text) {
                    ("image", _) => image(part.get("id").and_then(Value::as_str)?),
                    (kind, Some(text)) => {
                        let mut block = json!({"type": "text", "text": text});
                        if kind == "pasted" || part.get("pasted") == Some(&Value::Bool(true)) {
                            block["_meta"] = json!({"cmux": {"pasted": true}});
                        }
                        Some(block)
                    }
                    _ => None,
                }
            })
            .collect(),
        None => {
            let text = msg.get("text").and_then(Value::as_str).filter(|t| !t.is_empty());
            let text = text.map(|t| json!({"type": "text", "text": t}));
            let images = msg.get("images").and_then(Value::as_array).into_iter().flatten();
            let images = images.map(|named| image(named.get("id").and_then(Value::as_str)?));
            text.into_iter().map(Some).chain(images).collect()
        }
    };
    blocks.filter(|b| !b.is_empty())
}

impl Hub {
    /// `_acpmux/retry` and `retry_session`: the subagent `subagent` names, or else the chat's
    /// failed turn ([`Hub::retry_turn`]). A subagent is refused for now: retrying the chat's
    /// turn instead would not do what was asked.
    pub async fn retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
        subagent: Option<&str>,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        if subagent.is_some() {
            return Err(subagent_unsupported());
        }
        self.retry_turn(session, by).await
    }

    /// Fires the chat's waiting retry now, or sends its failed last turn again (the module
    /// doc). Answers once the prompt is accepted: `{promptId, turnId?, kind}`.
    pub async fn retry_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        if let Some(fired) = self.fire_waiting_retry(session)? {
            return Ok(fired);
        }
        let last = session.meta().last_turn.unwrap_or(Value::Null);
        let field = |k: &str| last.get(k).and_then(Value::as_str).map(str::to_owned);
        let status = field("status");
        let (Some("failed"), Some(cut_turn), Some(failed)) =
            (status.as_deref(), field("turnId"), field("promptId"))
        else {
            return Err(nothing_failed());
        };
        let error = field("errorText").unwrap_or_default();
        let (root, done) = split_attempt(&failed);
        let (root, attempt) = (root.to_owned(), done + 1);
        let blocks = self.resend_of(session, &cut_turn, &failed).unwrap_or_else(|| {
            let reason = crate::hub::turn_errors::resume_cause(&error, &error).unwrap_or("error");
            vec![json!({"type": "text", "text": continue_text(&error, reason)})]
        });
        let held = self.held_by(session, &root, &cut_turn);
        let provenance = json!({"kind": "auto_resume", "promptId": root, "attempt": attempt, "turnId": cut_turn, "manual": true});
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let opts = PromptOptions {
            prompt_id: Some(format!("{root}{SUFFIX}{attempt}")),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            resend: true,
            control: by.control,
            trust_gate: by.trust_gate,
            full_access_device: by.full_access_device,
            provenance: Some(provenance),
            after_turn: Some(cut_turn),
            ..PromptOptions::default()
        };
        let (hub, s) = (self.clone(), session.clone());
        // The turn runs on: only its acceptance is awaited here.
        let turn = tokio::spawn(async move {
            let result = hub.prompt_with(&s, blocks, "acpmux", false, opts).await;
            if matches!(&result, Ok(v) if v.get("stopReason").and_then(Value::as_str) != Some("cancelled"))
            {
                hub.resume_held(&s, &held);
            }
            result
        });
        let accepted = match rx.await {
            Ok(v) => v,
            // Dropped before acceptance: the prompt was refused.
            Err(_) => match turn.await {
                Ok(Ok(v)) => v,
                Ok(Err(e)) => {
                    let reason = e.data.as_ref().and_then(|d| d.get("reason"));
                    // Something else took the chat between the check and the turn lock.
                    if reason.and_then(Value::as_str) == Some("auto_resume.superseded") {
                        return Err(busy());
                    }
                    return Err(e);
                }
                Err(e) => return Err(RpcError::internal(e.to_string())),
            },
        };
        let prompt_id = accepted.get("promptId").and_then(Value::as_str).unwrap_or_default();
        let turn_id = accepted.get("turnId").and_then(Value::as_str).map(str::to_owned);
        Ok(answer(prompt_id.to_owned(), turn_id))
    }

    /// The sub-session tool `retry_session`: `caller` retries its descendant `target`'s failed
    /// turn, under the remote floor when either drove a Web turn, as a family prompt does
    /// (`subsessions.rs` `send_family_prompt`).
    pub async fn subsession_retry(
        self: &Arc<Self>,
        caller: &Session,
        target: &Arc<Session>,
        subagent: Option<&str>,
    ) -> Result<Value, RpcError> {
        let web = Self::web_turn(caller) || Self::web_turn(target);
        let control = if web { Control::Web } else { Control::Local };
        let by = RetryBy { control, trust_gate: false, full_access_device: None };
        self.retry(target, subagent, by).await
    }

    /// The chat's waiting retry, fired now: its answer, None when none waits. `retry.busy`
    /// while a turn runs, a prompt waits to run, or a continuation is about to start.
    fn fire_waiting_retry(&self, session: &Session) -> Result<Option<Value>, RpcError> {
        if session.turn().is_some() || session.queue().iter().any(|q| !q.held) {
            return Err(busy());
        }
        let mut pending = self.auto_resumes.lock();
        match pending.get(&session.id) {
            Some(Mark::Waiting { turn, retry: Some(retry), wake }) if still_cut(session, turn) => {
                // Its timer ends now; asked twice, it still fires once (`fire_pending`).
                wake.0.notify_one();
                let prompt_id = format!("{}{SUFFIX}{}", retry.prompt_id, retry.attempt);
                Ok(Some(answer(prompt_id, None)))
            }
            // One the chat moved on from is skipped when its wait ends.
            Some(Mark::Waiting { retry: Some(_), .. }) => Ok(None),
            Some(Mark::Waiting { .. } | Mark::Firing(_) | Mark::Ending(_)) => Err(busy()),
            // Stop came while the failed turn ran: the caller asks for a retry anyway.
            Some(Mark::Stopped(_)) => {
                pending.remove(&session.id);
                Ok(None)
            }
            None => Ok(None),
        }
    }

    /// The failed turn `cut_turn`'s prompt `prompt_id`, to send again as it was: when the model
    /// produced nothing in it, nothing was steered into it, and its blocks can be rebuilt.
    /// The log is read from its end back to that prompt.
    fn resend_of(&self, session: &Session, cut_turn: &str, prompt_id: &str) -> Option<Vec<Value>> {
        let mut prompt = None;
        let skip = |_: &[u8], _: &[u8]| false;
        let _ = self.store.scan_back(&session.id, 0, u64::MAX, &skip, &mut |e: EventRecord| {
            if crate::hub::tap::logged_from_the_model(&e) {
                return false;
            }
            let turn = e.msg.get("turnId").and_then(Value::as_str);
            match e.kind.as_str() {
                // Its own prompt; a steered one (or another prompt of the turn) ends the read.
                "user_message" if turn == Some(cut_turn) => {
                    let own = e.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id);
                    if own && e.msg.get("steer").is_none() {
                        prompt = Some(e.msg);
                    }
                    false
                }
                // Another turn before its prompt: not the log this expects.
                "turn_started" | "turn_result" | "user_message" => turn == Some(cut_turn),
                _ => true,
            }
        });
        let image = |id: &str| {
            let kept = self.prompt_image(&session.id, id).ok()?;
            Some(
                json!({"type": "image", "mimeType": kept.get("mimeType")?, "data": kept.get("data")?}),
            )
        };
        prompt_blocks(&prompt?, image)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(id: &str) -> Option<Value> {
        (id == "img1").then(|| json!({"type": "image", "mimeType": "image/png", "data": "AQID"}))
    }

    #[test]
    fn a_prompt_is_rebuilt_from_its_record_in_order() {
        let msg = json!({"text": "look\nhere", "inlineParts": [
            {"kind": "text", "text": "look", "pasted": true},
            {"kind": "image", "id": "img1", "mimeType": "image/png"},
            {"kind": "pasted", "name": "Pasted text", "text": "here"},
        ]});
        assert_eq!(
            prompt_blocks(&msg, kept),
            Some(vec![
                json!({"type": "text", "text": "look", "_meta": {"cmux": {"pasted": true}}}),
                json!({"type": "image", "mimeType": "image/png", "data": "AQID"}),
                json!({"type": "text", "text": "here", "_meta": {"cmux": {"pasted": true}}}),
            ])
        );
        // Without its parts: its text, then its images.
        let msg = json!({"text": "hi", "images": [{"id": "img1"}]});
        assert_eq!(prompt_blocks(&msg, kept).map(|b| b.len()), Some(2));
    }

    #[test]
    fn a_prompt_that_cannot_be_rebuilt_is_not_resent() {
        for parts in [
            json!([{"kind": "text", "text": "a"}, {"kind": "image", "id": "gone"}]),
            json!([{"kind": "document", "name": "brief.pdf"}]),
            json!([{"kind": "file", "name": "notes.txt", "uri": "attachment://notes.txt"}]),
            json!([]),
        ] {
            let msg = json!({"text": "a", "inlineParts": parts});
            assert_eq!(prompt_blocks(&msg, kept), None, "{parts}");
        }
        assert_eq!(prompt_blocks(&json!({"text": ""}), kept), None);
    }

    #[test]
    fn a_continuation_names_the_error_it_continues_after() {
        assert!(continue_text("x", "transport").contains("a connection error (x)"));
        assert!(continue_text("simulated internal error", "error").contains("cut off by an error"));
    }
}
