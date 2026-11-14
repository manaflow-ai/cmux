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
    // Normal status writes cannot reopen a closed session. Exercise finishing states
    // on an open session, as the adopted-turn path does in production.
    assert!(hub.reopen(&session, session.stops.load(std::sync::atomic::Ordering::SeqCst)));
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
        trigger: false,
        notice: false,
        persons: true,
        accepted: true,
    });
    // Legacy resend behavior stays intact, but recovery must not answer interrupted.
    assert_eq!(
        hub.logged_prompt(&session, "p").unwrap().unwrap()["_meta"]["acpmux"]["status"],
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
    assert_eq!(session.status(), crate::store::SessionStatus::Running);
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
async fn prompt_outcome_waits_for_failed_summarys_original_record() {
    let (hub, session) = chat();
    hub.append(&session, "mux", "user_message", json!({"promptId": "p", "turnId": "t"}));
    hub.append(&session, "mux", "turn_started", json!({"promptId": "p", "turnId": "t"}));
    // finish_turn has taken TurnInfo and recorded lastTurn, but has not appended
    // turn_result yet. A reconnect must wait for its original code and error data.
    hub.set_status(&session, crate::store::SessionStatus::Running);
    assert_eq!(session.status(), crate::store::SessionStatus::Running);
    session.meta.lock().unwrap().last_turn = Some(json!({
        "promptId": "p", "turnId": "t", "status": "failed", "errorText": "summary only",
    }));
    let query = hub.prompt_outcome(&session, "p");
    tokio::pin!(query);
    tokio::select! {
        biased;
        result = &mut query => panic!("failed summary answered before its record: {result:?}"),
        () = tokio::task::yield_now() => {}
    }
    hub.append(&session, "mux", "turn_result", json!({
            "promptId": "p", "turnId": "t", "status": "failed", "code": -32042,
            "error": "original error", "data": {"reason": "original_reason"}, "recovery": "retry later",
        }));
    let error =
        tokio::time::timeout(std::time::Duration::from_secs(1), query).await.unwrap().unwrap_err();
    assert_eq!(error.code, -32042);
    assert_eq!(error.message, "original error");
    assert_eq!(error.data.as_ref().unwrap()["reason"], "original_reason");
    assert_eq!(error.data.unwrap()["recovery"], "retry later");
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
    session.meta.lock().unwrap().last_turn = Some(json!({
        "promptId": "compacted", "turnId": "older", "status": "failed", "errorText": "retained error",
    }));
    let compacted = hub.prompt_outcome(&session, "compacted").await.unwrap_err();
    assert_eq!(compacted.message, "retained error");
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
    assert_eq!(session.status(), crate::store::SessionStatus::Running);
    let orphan =
        tokio::time::timeout(std::time::Duration::from_secs(1), hub.prompt_outcome(&session, "p"))
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

#[tokio::test]
async fn durable_prompt_admission_and_terminal_records_suppress_only_consumed_prompts() {
    // Records are in crash order. A plain user_message precedes admission, whereas
    // steer and joined messages use an existing turn. Withdrawal consumes an ID
    // without admission. These distinctions must survive an empty in-memory ledger.
    for (point, expected_status) in [
        ("message", None),
        ("queued", None),
        ("started", Some("interrupted")),
        ("steer", Some("interrupted")),
        ("joined", Some("interrupted")),
        ("withdrawn", Some("withdrawn")),
        ("stopped_before_start", Some("cancelled")),
        ("stopped_before_message", Some("cancelled")),
        ("stopped_without_message", Some("cancelled")),
        ("orphan_stopped_without_message", Some("cancelled")),
        ("unrelated_stop_before_message", None),
        ("stopped_then_result", Some("failed")),
        ("completed", Some("completed")),
        ("orphan_resend", Some("completed")),
        ("orphan_steer", Some("interrupted")),
        ("requeued", None),
    ] {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        store.save(&serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": "ledger", "name": "ledger",
                "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
            })).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("ledger").unwrap();
        if point == "stopped_before_message" {
            hub.append(&session, "mux", "turn_stop_requested", json!({"turnId": "t"}));
        }
        // A later cancellation of another turn must neither replace nor create
        // cancellation for the prompt we are looking up.
        hub.append(&session, "mux", "turn_stop_requested", json!({"turnId": "unrelated"}));
        let queued = ["queued", "joined", "withdrawn"].contains(&point);
        if point == "orphan_stopped_without_message" {
            hub.append(
                &session,
                "in",
                "user_message",
                json!({"turnId": "orphan", "promptId": "p"}),
            );
        }
        if ["stopped_without_message", "orphan_stopped_without_message"].contains(&point) {
            hub.append(
                &session,
                "mux",
                "turn_stop_requested",
                json!({"turnId": "t", "promptId": "p"}),
            );
        } else {
            hub.append(
                &session,
                "in",
                if queued { "queued" } else { "user_message" },
                json!({"promptId": "p", "turnId": "t", "steer": point == "steer", "text": "hello"}),
            );
        }
        if ["started", "completed", "requeued"].contains(&point) {
            hub.append(&session, "mux", "turn_started", json!({"promptId": "p", "turnId": "t"}));
        }
        match point {
            "stopped_before_start" | "stopped_then_result" => {
                hub.append(&session, "mux", "turn_stop_requested", json!({"turnId": "t"}));
                if point == "stopped_then_result" {
                    hub.append(
                        &session,
                        "mux",
                        "turn_result",
                        json!({
                            "turnId": "t", "status": "failed", "stopReason": "cancelled"
                        }),
                    );
                }
            }
            "joined" => {
                hub.append(
                    &session,
                    "mux",
                    "dequeued",
                    json!({"promptId": "p", "turnId": "t", "joinedTurnId": "head"}),
                );
                hub.append(
                    &session,
                    "mux",
                    "turn_started",
                    json!({"promptId": "digest-head", "turnId": "head"}),
                );
            }
            "withdrawn" => {
                hub.append(
                    &session,
                    "mux",
                    "queue_removed",
                    json!({"promptId": "p", "turnId": "t"}),
                );
            }
            "completed" => {
                hub.append(
                    &session,
                    "mux",
                    "turn_result",
                    json!({"turnId": "t", "status": "completed", "stopReason": "end_turn"}),
                );
            }
            "orphan_resend" | "orphan_steer" => {
                hub.append(
                    &session,
                    "in",
                    "user_message",
                    json!({
                        "promptId": "p", "turnId": "actual", "steer": point == "orphan_steer"
                    }),
                );
                if point == "orphan_resend" {
                    hub.append(
                        &session,
                        "mux",
                        "turn_started",
                        json!({"promptId": "p", "turnId": "actual"}),
                    );
                    hub.append(
                        &session,
                        "mux",
                        "turn_result",
                        json!({"promptId": "p", "turnId": "actual", "status": "completed"}),
                    );
                }
                // The result cannot come from lastTurn's shortcut or the live ledger.
                session.meta.lock().unwrap().last_turn = Some(json!({
                    "promptId": "different", "turnId": "newer", "status": "completed"
                }));
            }
            "requeued" => {
                hub.append(
                    &session,
                    "mux",
                    "turn_result",
                    json!({"turnId": "t", "status": "failed"}),
                );
                hub.append(
                    &session,
                    "mux",
                    "queued",
                    json!({"promptId": "p", "turnId": "again", "requeued": true}),
                );
            }
            _ => {}
        }
        assert!(session.prompts.lock().unwrap().is_empty());
        let logged = hub.logged_prompt(&session, "p").map(|l| l.unwrap());
        assert_eq!(
            logged.as_ref().and_then(|v| v.pointer("/_meta/acpmux/status")).and_then(Value::as_str),
            expected_status,
            "crash after {point}: {logged:?}"
        );
        assert_eq!(
            hub.knows_prompt(&session, "p", true),
            expected_status.is_some(),
            "resend after {point}"
        );
        if ["orphan_resend", "orphan_steer"].contains(&point) {
            assert_eq!(logged.unwrap()["_meta"]["acpmux"]["turnId"], "actual");
        }
    }
}

/// A message an inbox digest took, put back when the digest was refused before its turn,
/// then run on its own turn: a resend answers from that turn, not as withdrawn with the
/// digest whose removal is logged after the message went back (`inbox_digest.rs`).
#[tokio::test]
async fn a_message_a_refused_digest_put_back_answers_from_its_own_turn() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    store
        .save(
            &serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": "ledger", "name": "ledger",
                "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
            }))
            .unwrap(),
        )
        .unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("ledger").unwrap();
    let digest = json!({"promptId": "d", "turnId": "td", "took": [{"promptId": "p"}],
            "_meta": {"provenance": {"kind": crate::hub::digest::inbox_digest::KIND}}});
    for (kind, msg) in [
        ("queued", json!({"promptId": "p", "turnId": "t"})),
        ("queued", digest),
        ("dequeued", json!({"promptId": "p", "turnId": "t", "digestPromptId": "d"})),
        ("prompt_refused", json!({"promptId": "d", "turnId": "td"})),
        ("queued", json!({"promptId": "p", "turnId": "back", "requeued": true})),
        ("queue_removed", json!({"promptId": "d", "turnId": "td"})),
        ("turn_started", json!({"promptId": "p", "turnId": "back"})),
        ("turn_result", json!({"turnId": "back", "status": "completed", "stopReason": "end_turn"})),
    ] {
        hub.append(&session, "mux", kind, msg);
    }
    let logged = hub.logged_prompt(&session, "p").unwrap().unwrap();
    assert_eq!(logged["_meta"]["acpmux"]["status"], "completed", "{logged}");
    assert_eq!(logged["_meta"]["acpmux"]["turnId"], "back", "{logged}");
    assert_eq!(logged["stopReason"], "end_turn", "{logged}");
}

#[test]
fn prompt_ledger_keeps_pending_and_bounds_completed_outcomes_as_they_settle() {
    let outcomes: Vec<PromptOutcome> =
        (0..130).map(|_| Arc::new(tokio::sync::watch::channel(None).0)).collect();
    let mut ledger: VecDeque<_> =
        outcomes.iter().enumerate().map(|(i, outcome)| (i.to_string(), outcome.clone())).collect();
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
