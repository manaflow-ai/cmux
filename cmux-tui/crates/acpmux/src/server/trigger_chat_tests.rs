//! Focused authorization and wire-contract tests for the Cloud trigger chat bridge.
//!
//! This file is included by `trigger_chat.rs`; keeping the tests beside the private validators
//! lets them exercise the server's actual scope and flat receipt builders rather than a copied
//! protocol model.

use super::*;
use crate::config::{Config, StoreMode};
use cmux_host::identity::HostIdentity;
use serde_json::{Value, json};
use sha2::Digest;
use std::path::Path;
use std::sync::Arc;

fn identity() -> HostIdentity {
    HostIdentity {
        machine: "machine-1".into(),
        instance_id: "instance-1".into(),
        guest_key: format!("sha256:{}", "a".repeat(64)),
    }
}

fn principal(now: u64) -> Value {
    json!({
        "audience": "cmux-trigger-chat-v1",
        "operations": ["ensure", "send", "status"],
        "trigger": "trigger-1",
        "owner": "user-1",
        "team": "team-1",
        "machine": "machine-1",
        "workspace": "workspace-1",
        "session": "session-1",
        "delivery": "delivery-1",
        "promptHash": "a".repeat(64),
        "cwd": "/workspace",
        "harness": "fake",
        "guestKey": format!("sha256:{}", "a".repeat(64)),
        "issuedAt": now.saturating_sub(1_000),
        "expiresAt": now + 60_000,
        "revision": 1,
    })
}

fn scope() -> TriggerScope {
    scope_from(&principal(chrono::Utc::now().timestamp_millis() as u64)).unwrap()
}

fn scope_from(value: &Value) -> Result<TriggerScope, RpcError> {
    super::scope(value)
}

fn token() -> String {
    "ctg1/invalid".into()
}

fn valid_token() -> String {
    "ctg1.123e4567-e89b-12d3-a456-426614174000.payload_1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned()
}

#[test]
fn scope_rejects_wrong_audience_operations_and_guest_key() {
    let mut value = principal(chrono::Utc::now().timestamp_millis() as u64);
    value["audience"] = json!("other-audience");
    assert!(scope_from(&value).is_err());

    let mut value = principal(chrono::Utc::now().timestamp_millis() as u64);
    value["operations"] = json!(["send", "ensure", "status"]);
    assert!(scope_from(&value).is_err());

    let mut value = principal(chrono::Utc::now().timestamp_millis() as u64);
    value["guestKey"] = json!("sha256:not-a-key");
    let candidate = scope_from(&value).expect("guest key shape is checked against identity");
    assert!(validate_claims(&value, &candidate, "trigger-1", &identity()).is_err());
}

#[test]
fn claims_reject_expired_future_reversed_and_long_ttl_principals() {
    let now = chrono::Utc::now().timestamp_millis() as u64;
    let id = identity();
    let base = scope();

    for (issued, expires) in [
        (now.saturating_sub(600_000), now.saturating_sub(300_000)),
        (now + 600_000, now + 660_000),
        (now.saturating_sub(1_000), now.saturating_sub(2_000)),
        (now.saturating_sub(1_000), now + 600_000),
    ] {
        let mut p = principal(now);
        p["issuedAt"] = json!(issued);
        p["expiresAt"] = json!(expires);
        assert!(validate_claims(&p, &base, "trigger-1", &id).is_err());
    }
}

#[test]
fn claims_pin_machine_guest_key_owner_team_revision_and_route() {
    let now = chrono::Utc::now().timestamp_millis() as u64;
    let id = identity();
    let base = scope();
    for (field, value) in [
        ("machine", json!("other-machine")),
        ("guestKey", json!(format!("sha256:{}", "b".repeat(64)))),
        ("owner", json!("")),
        ("team", json!("")),
        ("revision", json!(0)),
    ] {
        let mut p = principal(now);
        p[field] = value;
        let candidate = scope_from(&p).unwrap_or_else(|_| base.clone());
        assert!(validate_claims(&p, &candidate, "trigger-1", &id).is_err(), "field {field}");
    }
    assert!(validate_claims(&principal(now), &base, "other-trigger", &id).is_err());
}

#[test]
fn token_route_requires_all_four_bounded_segments() {
    assert!(token_route(&valid_token()).is_ok());
    for malformed in [
        token(),
        "ctg0.123e4567-e89b-12d3-a456-426614174000.payload_1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
        "ctg1.123e4567-e89b-12d3-a456-426614174000.payload_1.short".to_owned(),
        "ctg1.123e4567-e89b-12d3-a456-426614174000.payload!.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
        "ctg1.123e4567-e89b-12d3-a456-426614174000.payload_1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.extra".to_owned(),
    ] {
        assert!(token_route(&malformed).is_err(), "accepted malformed token {malformed}");
    }
}

#[test]
fn prompt_allows_newlines_but_rejects_nul_and_other_controls() {
    assert!(prompt(&json!({"body": "line one\nline two\tand carriage\r"}), "body").is_ok());
    assert!(prompt(&json!({"body": "nul\u{0}"}), "body").is_err());
    assert!(prompt(&json!({"body": "escape\u{1b}"}), "body").is_err());
}

#[test]
fn durable_receipt_requires_exact_turn_and_prompt_digest() {
    let scope = scope();
    let receipt = json!({
        "delivery": scope.delivery,
        "state": "queued",
        "turnId": "turn-1",
        "promptHash": scope.prompt_hash,
    });
    assert_eq!(validate_durable_receipt(&receipt, &scope).unwrap(), receipt);

    for invalid in [
        json!({"delivery": "delivery-1", "turnId": "turn-1"}),
        json!({"delivery": "delivery-1", "turnId": "turn-1", "promptHash": "b".repeat(64)}),
        json!({"delivery": "delivery-1", "promptHash": "a".repeat(64)}),
        json!({"error": "journal unavailable"}),
    ] {
        assert!(validate_durable_receipt(&invalid, &scope).is_err(), "accepted {invalid}");
    }
}

fn hub_with_session() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("memory store");
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": "session-1",
        "name": "trigger-session",
        "harness": "fake",
        "cwd": "/workspace",
        "workspaceId": "workspace-1",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .expect("session metadata");
    store.save(&meta).expect("save session metadata");
    let hub = Hub::new(config, store);
    hub.insert_test_session(meta);
    hub
}

#[tokio::test]
async fn ensure_builds_the_flat_machine_workspace_session_delivery_receipt() {
    let hub = hub_with_session();
    let mut scoped = scope();
    scoped.session = "session-1".into();
    let receipt = ensure(&hub, &scoped).await.expect("ensure existing chat");
    assert_eq!(receipt["ok"], true);
    assert_eq!(receipt["state"], "started");
    assert_eq!(receipt["machine"], scoped.machine);
    assert_eq!(receipt["workspace"], scoped.workspace);
    assert_eq!(receipt["session"], scoped.session);
    assert_eq!(receipt["delivery"], scoped.delivery);
    assert!(receipt.get("turn").is_none());
}

#[tokio::test]
async fn ensure_refuses_changed_workspace_cwd_or_harness_for_existing_chat() {
    let hub = hub_with_session();
    for (workspace, cwd, harness) in [
        ("other-workspace", "/workspace", "fake"),
        ("workspace-1", "/other", "fake"),
        ("workspace-1", "/workspace", "other-harness"),
    ] {
        let mut scoped = scope();
        scoped.session = "session-1".into();
        scoped.workspace = workspace.into();
        scoped.cwd = cwd.into();
        scoped.harness = harness.into();
        assert!(ensure(&hub, &scoped).await.is_err(), "accepted changed chat binding");
    }
}

#[tokio::test]
async fn send_refuses_a_human_prompt_that_reused_the_delivery_id() {
    let hub = hub_with_session();
    let scoped = scope();
    let session = bound_session(&hub, &scoped).expect("bound session");
    hub.append(
        &session,
        "mux",
        "user_message",
        json!({"promptId": scoped.delivery, "turnId": "human-turn", "text": "human prompt"}),
    );
    hub.append(&session, "mux", "turn_started", json!({"promptId": scoped.delivery, "turnId": "human-turn"}));
    hub.append(&session, "mux", "turn_result", json!({"promptId": scoped.delivery, "turnId": "human-turn", "status": "completed"}));
    let error = send(&hub, &scoped, "trigger prompt".into()).await.expect_err("collision accepted");
    assert!(error.to_string().contains("prior delivery"), "{error}");
}

#[tokio::test]
async fn status_returns_flat_scope_and_durable_turn_receipt() {
    let hub = hub_with_session();
    let mut scoped = scope();
    scoped.session = "session-1".into();
    let body = "trigger body";
    scoped.prompt_hash = format!("{:x}", sha2::Sha256::digest(body.as_bytes()));
    let session = bound_session(&hub, &scoped).expect("bound session");
    let provenance = crate::prompt_provenance::of(
        &json!({"_meta": {"acpmux": {"provenance": {
            "kind": "trigger", "triggerId": scoped.trigger, "deliveryId": scoped.delivery,
            "owner": scoped.owner, "team": scoped.team, "machine": scoped.machine,
            "workspace": scoped.workspace, "session": scoped.session,
        }}}}),
        crate::prompt_provenance::Sender::Trigger,
    )
    .expect("provenance result")
    .expect("provenance");
    hub.append(
        &session,
        "mux",
        "user_message",
        crate::prompt_provenance::marked(
            json!({"promptId": scoped.delivery, "turnId": "turn-1", "text": body}),
            Some(&provenance),
        ),
    );
    hub.append(
        &session,
        "mux",
        "turn_started",
        json!({"promptId": scoped.delivery, "turnId": "turn-1", "trigger": true}),
    );
    hub.append(
        &session,
        "mux",
        "turn_result",
        json!({"promptId": scoped.delivery, "turnId": "turn-1", "status": "completed"}),
    );
    let receipt = status(&hub, &scoped).expect("status");
    assert_eq!(receipt["machine"], scoped.machine);
    assert_eq!(receipt["workspace"], scoped.workspace);
    assert_eq!(receipt["session"], scoped.session);
    assert_eq!(receipt["delivery"], scoped.delivery);
    assert_eq!(receipt["turnId"], "turn-1");
    assert_eq!(receipt["promptHash"], scoped.prompt_hash);
}
