//! `hybrid_hold.rs`: a hybrid start's call waits for its machine's ready tag, never a timer, and
//! gets one answer; a chat that is not a hybrid start is answered at once.

use super::*;
use crate::store::MemoryStore;
use cmux_cloud_start_core::hybrid_tools::{MACHINE_TAG, NOT_HYBRID, STAGE_TAG};

fn hub() -> (Arc<Hub>, Arc<Session>) {
    let config = serde_json::from_value(json!({})).unwrap_or_else(|e| panic!("config: {e}"));
    let hub = Hub::new(config, Box::new(MemoryStore::default()));
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "hybrid-hold", "name": "hybrid",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"));
    let session = hub.insert_test_session(meta);
    (hub, session)
}

fn tag(hub: &Hub, session: &Session, set: Value) {
    hub.set_tags_answered(session, set.as_object(), &[], None).unwrap_or_else(|e| panic!("{e:?}"));
}

#[tokio::test]
async fn a_chat_that_is_not_a_hybrid_start_is_answered_at_once() {
    let (hub, session) = hub();
    let route = tokio::time::timeout(Duration::from_secs(5), hub.hybrid_route(&session, "execute"))
        .await
        .expect("no hold");
    assert_eq!(route, Route::Here { reason: NOT_HYBRID.into() });
}

#[tokio::test]
async fn a_held_call_goes_on_when_the_machine_is_ready_and_only_then() {
    let (hub, session) = hub();
    tag(&hub, &session, json!({STAGE_TAG: "booting"}));
    let held = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move { hub.hybrid_route(&session, "execute").await })
    };
    // Held: no answer while the machine boots, whatever else changes.
    tokio::time::sleep(Duration::from_millis(200)).await;
    tag(&hub, &session, json!({"unrelated": "x"}));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!held.is_finished(), "answered before the machine was ready");
    // The driver's ready: the one answer, on the machine.
    tag(&hub, &session, json!({STAGE_TAG: "ready", MACHINE_TAG: "vm-1"}));
    let route = tokio::time::timeout(Duration::from_secs(5), held)
        .await
        .expect("the ready tag ends the hold")
        .expect("the hold's task");
    assert_eq!(route, Route::OnMachine { machine: "vm-1".into() });
}

#[tokio::test]
async fn a_failed_machine_lets_the_held_call_run_here_with_its_reason() {
    let (hub, session) = hub();
    tag(&hub, &session, json!({STAGE_TAG: "booting"}));
    let held = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move { hub.hybrid_route(&session, "edit").await })
    };
    tokio::time::sleep(Duration::from_millis(100)).await;
    tag(&hub, &session, json!({STAGE_TAG: "failed"}));
    let route = tokio::time::timeout(Duration::from_secs(5), held).await.unwrap().unwrap();
    assert_eq!(route, Route::Here { reason: hybrid_tools::MACHINE_FAILED.into() });
}

#[test]
fn an_expired_stage_tag_is_no_hybrid_start() {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "x", "name": "x", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "tags": {STAGE_TAG: {"value": "booting", "expires_at": 1}, MACHINE_TAG: {"value": "vm-1"}},
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"));
    assert_eq!(boot_tags(&meta), (None, Some("vm-1".into())));
}

#[test]
fn a_bash_call_on_the_machine_keeps_its_input_with_the_command_run_there() {
    let request = json!({"toolCall": {"kind": "execute",
        "rawInput": {"command": "ls -la", "description": "list", "timeout": 5000},
        "_meta": {"claude": {"tool": "Bash"}}}});
    let answer = on_machine_answer(&request, "vm-1").expect("a Bash call routes");
    assert!(answer.get("decision").is_none(), "routing a call never decides it: {answer}");
    assert_eq!(answer["updatedInput"]["command"], "cmux vm exec 'vm-1' -- bash -lc 'ls -la'");
    assert_eq!(answer["updatedInput"]["description"], "list");
    assert_eq!(answer["updatedInput"]["timeout"], 5000);
    let kill = json!({"toolCall": {"kind": "execute", "rawInput": {"shell_id": "1"},
        "_meta": {"claude": {"tool": "KillShell"}}}});
    assert_eq!(on_machine_answer(&kill, "vm-1"), None);
}

/// The gate end to end: a booting hybrid start's Bash call gets its one answer when the machine is
/// ready, its command run there; the same call of a chat that is not a hybrid start is unchanged.
#[tokio::test]
async fn the_gate_answers_a_held_bash_call_once_with_the_machine_command() {
    let request = json!({"sessionId": "hybrid-hold", "toolCall": {"toolCallId": "t1",
        "kind": "execute", "rawInput": {"command": "cargo test"},
        "_meta": {"claude": {"tool": "Bash"}}}});
    let (plain_hub, plain) = hub();
    let before = plain_hub.answer_tool_gate(&plain, request.clone()).await;
    assert!(before.get("updatedInput").is_none(), "{before}");

    let (hub, session) = hub();
    tag(&hub, &session, json!({STAGE_TAG: "booting"}));
    let gate = {
        let (hub, session, request) = (hub.clone(), session.clone(), request.clone());
        tokio::spawn(async move { hub.answer_tool_gate(&session, request).await })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!gate.is_finished(), "answered while the machine boots");
    tag(&hub, &session, json!({STAGE_TAG: "ready", MACHINE_TAG: "vm-1"}));
    let answer = tokio::time::timeout(Duration::from_secs(5), gate).await.unwrap().unwrap();
    // Routed, the call keeps the decision the same call gets in a chat that is not a hybrid
    // start: a person who would be asked is still asked.
    assert_eq!(answer["decision"], before["decision"], "{answer}");
    assert_eq!(answer["updatedInput"]["command"], "cmux vm exec 'vm-1' -- bash -lc 'cargo test'");
}

#[test]
fn a_routed_call_keeps_the_gates_decision() {
    let routed = || Some(json!({"reason": "on the machine", "updatedInput": {"command": "x"}}));
    for decision in ["none", "allow", "ask"] {
        let answer = with_machine(json!({"decision": decision}), routed());
        assert_eq!(answer["decision"], decision);
        assert_eq!(answer["updatedInput"]["command"], "x");
    }
    assert_eq!(with_machine(json!({"decision": "ask"}), None), json!({"decision": "ask"}));
}
