//! `_acpmux/retry` (`server/agent_messages.rs`), `acpmux retry` and the sub-session tool
//! `retry_session`: a chat's failed last turn, retried now in the same session. The webview's
//! Retry button calls it (subsession-card's ask, from Leo's "this needs to retry :(",
//! 2026-10-26).
//!
//! - When the last turn failed, it is sent again now as the next attempt of its prompt
//!   (`P~resume-n` after the failed `P` or `P~resume-(n-1)`, the id an automatic retry uses): the
//!   same prompt (its text and the images acpmux kept) when the turn produced nothing, and the
//!   continuation an automatic retry sends (`continue_text`) when the model had started on it, a
//!   message was steered into it, it was a turn of agent messages, it carried hidden context, or
//!   it cannot be rebuilt (a document, an image not kept). A retry that waits (the session row's
//!   `retry`, `auto_resume.rs`) is taken over: it is this attempt, sent now, and its timer records
//!   the skip `superseded`. A second click while the first is under way is `retry.busy`.
//! - Refused with `retry.busy` while a turn runs, a prompt waits to run or a continuation is
//!   about to start, and with `retry.nothing_failed` when the last turn did not fail.
//! - A retry that names a subagent (`subagentId`) asks for that subagent, never the chat's own
//!   turn (`hub/subagent_retry_manual.rs`).
//! - It runs under the caller's rules (`control`, the trust gate, a paired machine's Full
//!   access), checked before it claims the chat and at dispatch as any prompt's are; a sub-session's retry also as its
//!   messages are (`receiver_check`, and `family_dispatch_check` at dispatch).
//! - From the claim to its turn's start the chat's mark is firing: Stop or close then refuses it
//!   (`retry.stopped`), and another retry is `retry.busy` until that one's task has ended. Its `user_message` carries `_meta.provenance = {kind: "auto_resume",
//!   promptId, attempt, turnId, manual: true}`, and once its turn completes the prompts the
//!   failed turn held go on (`held_by`).
//! - A Stop the failed turn got does not hold a retry the caller asks for after it.

use super::{Mark, SUFFIX, continue_text, split_attempt, still_cut};
use crate::hub::digest::DIGEST_KIND;
use crate::hub::{Control, Hub, PromptOptions, Session};
use crate::protocol::session::{RetryKind, RetryResult};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::sync::Arc;

/// The rules a retry's prompt runs under: the caller's, as for a prompt it sent, and the
/// sub-session that asked for it (`from`), if one did.
pub struct RetryBy {
    pub control: Control,
    pub trust_gate: bool,
    pub full_access_device: Option<String>,
    pub from: Option<String>,
}

fn refused(reason: &str, why: &str) -> RpcError {
    RpcError::invalid_params(format!("{reason}: {why}")).with_data(json!({"reason": reason}))
}

pub(crate) fn busy() -> RpcError {
    refused("retry.busy", "a turn runs or is about to start in this chat; retry once it ends")
}

fn stopped() -> RpcError {
    refused("retry.stopped", "Stop or close came before the retry's turn started")
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
    /// `_acpmux/retry` and `retry_session`: the failed subagent `subagent` names
    /// ([`Hub::retry_subagent`]), or else the chat's failed turn ([`Hub::retry_turn`]).
    pub async fn retry(
        self: &Arc<Self>,
        session: &Arc<Session>,
        subagent: Option<&str>,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        match subagent {
            Some(subagent) => self.retry_subagent(session, subagent, by).await,
            None => self.retry_turn(session, by).await,
        }
    }

    /// Sends the chat's failed last turn again now, under the caller's rules (the module doc),
    /// taking over a retry that waits. Answers once the prompt is accepted:
    /// `{promptId, turnId, kind}`.
    pub async fn retry_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        by: RetryBy,
    ) -> Result<Value, RpcError> {
        self.retry_allowed(session, &by).await?;
        let (cut_turn, failed, error) = self.claim_failed_turn(session)?;
        let (root, done) = split_attempt(&failed);
        let (root, attempt) = (root.to_owned(), done + 1);
        let blocks = self.resend_of(session, &cut_turn, &failed).unwrap_or_else(|| {
            let reason = crate::hub::turn_errors::resume_cause(&error, &error).unwrap_or("error");
            vec![json!({"type": "text", "text": continue_text(&error, reason)})]
        });
        let held = self.held_by(session, &root, &cut_turn);
        let mut provenance = json!({"kind": "auto_resume", "promptId": root, "attempt": attempt, "turnId": cut_turn, "manual": true});
        // A sub-session's retry names its sender: checked again at dispatch as its messages are
        // (`subsession_guard.rs` `family_dispatch_check`).
        if let Some(from) = by.from {
            provenance["from"] = json!(from);
        }
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
            after_turn: Some(cut_turn.clone()),
            ..PromptOptions::default()
        };
        let (hub, s) = (self.clone(), session.clone());
        // The turn runs on: only its acceptance is awaited here.
        let turn = tokio::spawn(async move {
            let result = hub.prompt_with(&s, blocks, "acpmux", false, opts).await;
            // What is left of the claim when the prompt never started its turn, once the
            // prompt is out of the ledger: a retry after this one is never joined to it.
            hub.clear_fired(&s, &cut_turn);
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
                    return Err(match reason.and_then(Value::as_str) {
                        // Something else took the chat between the claim and the turn lock.
                        Some("auto_resume.superseded") => busy(),
                        Some("auto_resume.stopped") => stopped(),
                        _ => e,
                    });
                }
                Err(e) => return Err(RpcError::internal(e.to_string())),
            },
        };
        let prompt_id = accepted.get("promptId").and_then(Value::as_str).unwrap_or_default();
        let turn_id = accepted.get("turnId").and_then(Value::as_str).map(str::to_owned);
        Ok(answer(prompt_id.to_owned(), turn_id))
    }

    /// The sub-session tool `retry_session`: `caller` retries its descendant `target`'s failed
    /// turn. Never to a session that asks less than the caller (`receiver_check`, again at
    /// dispatch), and under the remote floor when either drove a Web turn, as a family prompt
    /// (`subsessions.rs` `send_family_prompt`).
    pub async fn subsession_retry(
        self: &Arc<Self>,
        caller: &Session,
        target: &Arc<Session>,
        subagent: Option<&str>,
    ) -> Result<Value, RpcError> {
        self.receiver_check(caller, target).await?;
        let web = Self::web_turn(caller) || Self::web_turn(target);
        let control = if web { Control::Web } else { Control::Local };
        let from = Some(caller.id.clone());
        let by = RetryBy { control, trust_gate: false, full_access_device: None, from };
        self.retry(target, subagent, by).await
    }

    /// The caller's rules, checked before the retry claims the chat, so a refused caller leaves
    /// a retry that waits as it was, and again at dispatch (`check_dispatch`).
    pub(crate) async fn retry_allowed(
        self: &Arc<Self>,
        session: &Arc<Session>,
        by: &RetryBy,
    ) -> Result<(), RpcError> {
        {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let device = by.full_access_device.as_deref();
            self.web_control_verdict(session, &m, by.control)
                .and_then(|()| self.full_access_hold(&m, by.control, device))?;
        }
        let web = by.control == Control::Web;
        crate::server::trust_gate::check_dispatch(self, by.trust_gate, web, session).await
    }

    /// Claims the chat's failed last turn for a retry: `(turn id, prompt id, error)`, its mark
    /// now firing, so Stop or close until its turn starts still counts (`start_turn`). A retry
    /// that waits is taken over (its timer wakes and records the skip `superseded`). `retry.busy`
    /// while a turn runs, a prompt waits to run, or a continuation is about to start.
    fn claim_failed_turn(&self, session: &Session) -> Result<(String, String, String), RpcError> {
        let mut pending = self.auto_resumes.lock();
        if session.turn().is_some() || session.queue().iter().any(|q| !q.held) {
            return Err(busy());
        }
        let last = session.meta().last_turn.unwrap_or(Value::Null);
        let field = |k: &str| last.get(k).and_then(Value::as_str).map(str::to_owned);
        let status = field("status");
        let (Some("failed"), Some(cut_turn), Some(failed)) =
            (status.as_deref(), field("turnId"), field("promptId"))
        else {
            return Err(nothing_failed());
        };
        match pending.get(&session.id) {
            // A retry of this turn that waits gives way to this one.
            Some(Mark::Waiting { turn, .. }) if *turn == cut_turn => {}
            // One under way, or one Stop overtook whose task has not ended: never two at once.
            Some(Mark::Waiting { .. } | Mark::Firing(_) | Mark::Ending(_) | Mark::Stopping(_)) => {
                return Err(busy());
            }
            // Stop came while the failed turn ran: the caller asks for a retry anyway.
            Some(Mark::Stopped(_)) | None => {}
        }
        if !still_cut(session, &cut_turn) {
            return Err(busy());
        }
        pending.insert(session.id.clone(), Mark::Firing(cut_turn.clone()));
        Ok((cut_turn, failed, field("errorText").unwrap_or_default()))
    }

    /// The failed turn `cut_turn`'s prompt `prompt_id`, to send again as it was: when the model
    /// produced nothing in it, nothing was steered into it, it was no turn of agent messages
    /// (whose joined messages went back to the queue, `digest.rs`), it carried no hidden context
    /// (`prompt_context.rs`, never recorded), and its blocks can be rebuilt. The log is read from
    /// its end back to that prompt.
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
                    let kind = e.msg.pointer("/_meta/provenance/kind").and_then(Value::as_str);
                    let whole = e.msg.get("hiddenContext").is_none();
                    if own && whole && e.msg.get("steer").is_none() && kind != Some(DIGEST_KIND) {
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
