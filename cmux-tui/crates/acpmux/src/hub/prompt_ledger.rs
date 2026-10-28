//! Pending prompt identities remain owned by the session until they settle.

use super::{Hub, PromptOutcome, Session};
use serde_json::{Value, json};
use std::collections::VecDeque;

/// Only completed outcomes count against the retry cache's bound. Pending senders
/// must stay discoverable, including restored prompts whose completion looks them up.
pub(super) fn prune(ledger: &mut VecDeque<(String, PromptOutcome)>) {
    const COMPLETED_OUTCOMES: usize = 64;
    let mut excess = ledger
        .iter()
        .filter(|(_, outcome)| outcome.borrow().is_some())
        .count()
        .saturating_sub(COMPLETED_OUTCOMES);
    if excess == 0 {
        return;
    }
    ledger.retain(|(_, outcome)| {
        if excess > 0 && outcome.borrow().is_some() {
            excess -= 1;
            false
        } else {
            true
        }
    });
}

impl Hub {
    /// Whether session `session`'s log records a turn that ran `prompt_id` (its `user_message`,
    /// alone or joined with other agent messages, `digest.rs`). Blocking: it reads the log.
    pub(crate) fn ran_prompt(&self, session: &str, prompt_id: &str) -> bool {
        let names = |m: &Value| m.get("promptId").and_then(Value::as_str) == Some(prompt_id);
        let mut ran = false;
        let _ = self.store.scan_kinds(session, &["user_message"], &mut |rec| {
            let joined = rec.msg.pointer("/_meta/provenance/messages").and_then(Value::as_array);
            ran = names(&rec.msg) || joined.is_some_and(|m| m.iter().any(names));
            !ran
        });
        ran
    }

    /// Whether session `session` took prompt `prompt_id` already: its ledger holds it, or, for a
    /// `resend`, its log does (`requests.rs`: a resend whose uploads are gone still answers with
    /// its first run). Blocking: it may read the log.
    pub fn knows_prompt(&self, session: &Session, prompt_id: &str, resend: bool) -> bool {
        let ledger = session.prompts.lock().unwrap_or_else(|e| e.into_inner());
        let held = ledger.iter().any(|(id, _)| id == prompt_id);
        drop(ledger);
        held || (resend && self.logged_prompt(session, prompt_id).is_some())
    }

    /// A prompt id the session's log already holds (`user_message` or
    /// `queued`), answered from the log: its turn's result when it ended,
    /// else `interrupted` (the daemon stopped during the turn).
    pub(super) fn logged_prompt(&self, session: &Session, prompt_id: &str) -> Option<Value> {
        let last = session.meta().last_turn;
        if let Some(last) =
            last.filter(|l| l.get("promptId").and_then(Value::as_str) == Some(prompt_id))
        {
            return Some(json!({
                "stopReason": last.get("stopReason").cloned().unwrap_or(Value::Null),
                "_meta": {"acpmux": {"promptId": prompt_id, "turnId": last.get("turnId"), "status": last.get("status"), "duplicate": true}},
            }));
        }
        let mut turn_id: Option<String> = None;
        let mut ended: Option<Value> = None;
        let _ = self.store.scan(&session.id, 0, &mut |rec| {
            match (rec.kind.as_str(), &turn_id) {
                ("user_message" | "queued", None)
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                }
                // Read on: a failed turn of agent messages may put it back (`requeued` below).
                ("turn_result", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    ended = Some(rec.msg);
                }
                // Put back after the turn it joined failed (`digest.rs` `requeue_joined`): it
                // waits again under its own turn id.
                ("queued", Some(_))
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                        && rec.msg.get("requeued") == Some(&Value::Bool(true)) =>
                {
                    turn_id = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    ended = None;
                }
                ("queue_removed", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id) =>
                {
                    ended = Some(json!({"stopReason": "cancelled", "status": "withdrawn"}));
                    return false;
                }
                // It went in with an earlier agent message's turn (`digest.rs`): that turn's.
                ("dequeued", Some(id))
                    if rec.msg.get("turnId").and_then(Value::as_str) == Some(id)
                        && rec.msg.get("joinedTurnId").is_some_and(Value::is_string) =>
                {
                    turn_id = rec.msg["joinedTurnId"].as_str().map(str::to_owned);
                }
                _ => {}
            }
            true
        });
        let turn_id = turn_id?;
        let status = ended
            .as_ref()
            .and_then(|e| e.get("status").cloned())
            .unwrap_or_else(|| json!("interrupted"));
        Some(json!({
            "stopReason": ended.as_ref().and_then(|e| e.get("stopReason").cloned()).unwrap_or(Value::Null),
            "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "status": status, "duplicate": true}},
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    #[test]
    fn prompt_ledger_keeps_pending_and_bounds_completed_outcomes_as_they_settle() {
        let outcomes: Vec<PromptOutcome> =
            (0..130).map(|_| Arc::new(tokio::sync::watch::channel(None).0)).collect();
        let mut ledger: VecDeque<_> = outcomes
            .iter()
            .enumerate()
            .map(|(i, outcome)| (i.to_string(), outcome.clone()))
            .collect();
        prune(&mut ledger);
        assert_eq!(ledger.len(), 130, "pending prompts were evicted");

        // Settle newer prompts first: pending entries at the front must not be evicted.
        for i in (0..130).rev() {
            outcomes[i].send_replace(Some(Ok(json!({"promptId": i}))));
            prune(&mut ledger);
            let pending = i;
            let completed = (130 - i).min(64);
            assert_eq!(ledger.len(), pending + completed, "settled prompt {i}");
            let ids: Vec<_> = ledger.iter().map(|(id, _)| id.parse::<usize>().unwrap()).collect();
            let expected: Vec<_> = (0..pending).chain((130 - completed)..130).collect();
            assert_eq!(ids, expected, "pruning changed pending or recent completed identities");
        }
    }
}
