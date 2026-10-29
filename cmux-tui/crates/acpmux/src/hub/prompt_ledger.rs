//! Pending prompt identities remain owned by the session until they settle.

use super::{Hub, PromptOutcome, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::Arc;

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
    /// Read an accepted prompt without submitting another turn. An adopted active turn
    /// may have no in-memory ledger entry: its persisted completion wakes this wait.
    pub async fn prompt_outcome(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
    ) -> Result<Value, RpcError> {
        // Subscribe before reading either source so completion cannot fall in a lookup gap.
        let mut events = self.subscribe();
        self.wait_adopted(session).await;
        self.session_log(session).await;
        loop {
            let pending = session
                .prompts
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .find(|(id, _)| id == prompt_id)
                .map(|(_, outcome)| outcome.subscribe());
            if let Some(mut pending) = pending {
                return pending
                    .wait_for(Option::is_some)
                    .await
                    .map_err(|_| RpcError::internal("the first run of this prompt was dropped"))?
                    .clone()
                    .ok_or_else(|| RpcError::internal("prompt outcome is missing"))?;
            }
            let (result, settled) =
                self.logged_prompt_state(session, prompt_id).ok_or_else(|| {
                    RpcError::invalid_params("the session has no outcome for this promptId")
                        .with_data(
                            json!({"reason": "prompt_outcome_unknown", "promptId": prompt_id}),
                        )
                })?;
            if let Some(settled) = settled {
                if settled.get("status").and_then(Value::as_str) == Some("failed") {
                    let code = settled.get("code").and_then(Value::as_i64).unwrap_or(-32603);
                    let message = settled
                        .get("error")
                        .and_then(Value::as_str)
                        .or_else(|| settled.get("errorText").and_then(Value::as_str))
                        .unwrap_or("the original prompt failed");
                    let mut data = settled.clone();
                    if let (Some(data), Some(original)) =
                        (data.as_object_mut(), settled.get("data").and_then(Value::as_object))
                    {
                        data.extend(original.clone());
                    }
                    return Err(RpcError::new(code, message).with_data(data));
                }
                return Ok(result);
            }
            // finish_turn takes `turn` before awaiting its final writes, while the session
            // still says Running. A settled orphan has neither an active nor finishing turn.
            let active =
                session.turn.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|turn| {
                    turn.prompt_id == prompt_id
                        || result.pointer("/_meta/acpmux/turnId").and_then(Value::as_str)
                            == Some(turn.turn_id.as_str())
                });
            let active = active.unwrap_or_else(|| {
                if session.status() != crate::store::SessionStatus::Running {
                    return false;
                }
                let mut latest = None;
                let _ = self.store.scan_kinds(&session.id, &["turn_started"], &mut |record| {
                    latest = record.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    true
                });
                latest.as_deref().is_some_and(|id| {
                    result.pointer("/_meta/acpmux/turnId").and_then(Value::as_str) == Some(id)
                })
            });
            if !active {
                // Completion may have overtaken the first log read before its status settled.
                if self
                    .logged_prompt_state(session, prompt_id)
                    .is_some_and(|(_, settled)| settled.is_some())
                {
                    continue;
                }
                return Ok(result);
            }
            // Only terminal/queue changes warrant another log read, never every token.
            loop {
                match events.recv().await {
                    Ok(event)
                        if event.session_id == session.id
                            && matches!(
                                event.record.kind.as_str(),
                                "turn_result"
                                    | "queue_removed"
                                    | "queued"
                                    | "dequeued"
                                    | "prompt_refused"
                                    | "status"
                            ) =>
                    {
                        break;
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => break,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        return Err(RpcError::internal("prompt outcome event stream closed"));
                    }
                }
            }
        }
    }

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
        self.logged_prompt_state(session, prompt_id).map(|(result, _)| result)
    }

    /// The legacy resend value plus a separate completion marker. "Interrupted" in that
    /// value is a legacy fallback, not evidence an adopted active turn has finished.
    fn logged_prompt_state(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Option<(Value, Option<Value>)> {
        let last = session.meta().last_turn;
        if let Some(last) =
            last.filter(|l| l.get("promptId").and_then(Value::as_str) == Some(prompt_id))
        {
            let result = json!({
                "stopReason": last.get("stopReason").cloned().unwrap_or(Value::Null),
                "_meta": {"acpmux": {"promptId": prompt_id, "turnId": last.get("turnId"), "status": last.get("status"), "duplicate": true}},
            });
            // lastTurn deliberately omits the RPC code; use the persisted failure when held.
            let mut settled = last.clone();
            if last.get("status").and_then(Value::as_str) == Some("failed") {
                let _ = self.store.scan_kinds(&session.id, &["turn_result"], &mut |record| {
                    if record.msg.get("turnId") == last.get("turnId") {
                        settled = record.msg;
                    }
                    true
                });
            }
            return Some((result, Some(settled)));
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
                ("prompt_refused", _)
                    if rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id) =>
                {
                    turn_id = rec
                        .msg
                        .get("turnId")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .or(turn_id.take());
                    let mut failure = rec.msg;
                    failure["status"] = json!("failed");
                    ended = Some(failure);
                    return false;
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
        Some((
            json!({
                "stopReason": ended.as_ref().and_then(|e| e.get("stopReason").cloned()).unwrap_or(Value::Null),
                "_meta": {"acpmux": {"promptId": prompt_id, "turnId": turn_id, "status": status, "duplicate": true}},
            }),
            ended,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    fn chat() -> (Arc<Hub>, Arc<Session>) {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "fake",
            "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap();
        store.save(&meta).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("s").unwrap();
        (hub, session)
    }

    #[tokio::test]
    async fn prompt_outcome_reads_pending_success_errors_and_unknown_without_submitting() {
        let (hub, session) = chat();
        let outcome: PromptOutcome = Arc::new(tokio::sync::watch::channel(None).0);
        session.prompts.lock().unwrap().push_back(("p".into(), outcome.clone()));
        let query = hub.prompt_outcome(&session, "p");
        tokio::pin!(query);
        tokio::select! {
            result = &mut query => panic!("pending outcome answered early: {result:?}"),
            () = tokio::task::yield_now() => {}
        }
        let result = json!({"stopReason": "end_turn", "_meta": {"acpmux": {"promptId": "p"}}});
        outcome.send_replace(Some(Ok(result.clone())));
        assert_eq!(query.await.unwrap(), result);
        let error = RpcError::internal("original failure").with_data(json!({"reason": "failed"}));
        outcome.send_replace(Some(Err(error)));
        let error = hub.prompt_outcome(&session, "p").await.unwrap_err();
        assert_eq!(error.message, "original failure");
        assert_eq!(error.data, Some(json!({"reason": "failed"})));
        session.meta.lock().unwrap().last_turn = Some(json!({
            "promptId": "persisted", "turnId": "t", "stopReason": "end_turn", "status": "completed",
        }));
        let logged = hub.prompt_outcome(&session, "persisted").await.unwrap();
        assert_eq!(logged["stopReason"], "end_turn");
        assert_eq!(logged["_meta"]["acpmux"]["promptId"], "persisted");
        let unknown = hub.prompt_outcome(&session, "unknown").await.unwrap_err();
        assert_eq!(unknown.data.unwrap()["reason"], "prompt_outcome_unknown");
        assert_eq!(session.prompts.lock().unwrap().len(), 1);
        assert_eq!(session.meta().turn_count, 0);
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn prompt_outcome_waits_for_adopted_turn_without_a_ledger_entry() {
        let (hub, session) = chat();
        hub.append(&session, "mux", "user_message", json!({"promptId": "p", "turnId": "t"}));
        hub.append(&session, "mux", "turn_started", json!({"promptId": "p", "turnId": "t"}));
        assert!(session.prompts.lock().unwrap().is_empty());
        *session.turn.lock().unwrap() = Some(super::super::TurnInfo {
            started_at: 1,
            client: "test".into(),
            prompt_preview: String::new(),
            masked_preview: String::new(),
            turn_id: "t".into(),
            prompt_id: "p".into(),
            turn_seq: 1,
            control: super::super::Control::Local,
            doing: Default::default(),
        });
        // Legacy resend behavior stays intact, but recovery must not answer interrupted.
        assert_eq!(
            hub.logged_prompt(&session, "p").unwrap()["_meta"]["acpmux"]["status"],
            "interrupted"
        );
        let query = hub.prompt_outcome(&session, "p");
        tokio::pin!(query);
        tokio::select! {
            biased;
            result = &mut query => panic!("active adopted prompt answered early: {result:?}"),
            () = tokio::task::yield_now() => {}
        }
        *session.turn.lock().unwrap() = None;
        hub.set_status(&session, crate::store::SessionStatus::Running);
        tokio::select! {
            biased;
            result = &mut query => panic!("finishing adopted prompt answered early: {result:?}"),
            () = tokio::task::yield_now() => {}
        }
        hub.append(
            &session,
            "mux",
            "turn_result",
            json!({
                "promptId": "p", "turnId": "t", "stopReason": "end_turn", "status": "completed",
            }),
        );
        let result =
            tokio::time::timeout(std::time::Duration::from_secs(1), query).await.unwrap().unwrap();
        assert_eq!(result["stopReason"], "end_turn");
        assert_eq!(result["_meta"]["acpmux"]["status"], "completed");
        assert!(session.prompts.lock().unwrap().is_empty());
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn prompt_outcome_returns_persisted_failure_with_its_original_code_and_message() {
        let (hub, session) = chat();
        hub.append(&session, "mux", "user_message", json!({"promptId": "p", "turnId": "t"}));
        hub.append(&session, "mux", "turn_result", json!({
            "promptId": "p", "turnId": "t", "status": "failed", "code": -32042, "error": "original error", "errorKind": "disk.full", "recovery": "free space",
        }));
        for last in [
            None,
            Some(
                json!({"promptId": "p", "turnId": "t", "status": "failed", "errorText": "original error"}),
            ),
        ] {
            session.meta.lock().unwrap().last_turn = last;
            let error = hub.prompt_outcome(&session, "p").await.unwrap_err();
            assert_eq!(error.code, -32042);
            assert_eq!(error.message, "original error");
            assert_eq!(error.data.as_ref().unwrap()["errorKind"], "disk.full");
            assert_eq!(error.data.unwrap()["recovery"], "free space");
        }
        assert!(session.prompts.lock().unwrap().is_empty());
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn prompt_outcome_settles_orphans_and_persisted_refusals() {
        let (hub, session) = chat();
        hub.append(&session, "mux", "queued", json!({"promptId": "p", "turnId": "t"}));
        let orphan = hub.prompt_outcome(&session, "p").await.unwrap();
        assert_eq!(orphan["_meta"]["acpmux"]["status"], "interrupted");
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"promptId": "other", "turnId": "other-turn"}),
        );
        hub.set_status(&session, crate::store::SessionStatus::Running);
        let orphan = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            hub.prompt_outcome(&session, "p"),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(
            orphan["_meta"]["acpmux"]["status"], "interrupted",
            "another finishing turn held this orphan"
        );
        hub.append(&session, "mux", "prompt_refused", json!({"promptId": "p", "turnId": "t", "error": "refused", "data": {"reason": "trust_required", "recovery": "trust the folder"}}));
        let refused = hub.prompt_outcome(&session, "p").await.unwrap_err();
        assert_eq!(refused.message, "refused");
        assert_eq!(refused.data.as_ref().unwrap()["reason"], "trust_required");
        assert_eq!(refused.data.unwrap()["recovery"], "trust the folder");
        hub.shutdown_all().await;
    }

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
