//! Real journal shapes from turns.rs, permissions.rs and the ACP fixtures in
//! log_deferral_tests.rs/watch_events.rs. Chunks intentionally have no turnId.
use super::*;
use crate::config::{Config, StoreMode};
use crate::store::SessionMeta;

fn hub(root: Option<&std::path::Path>) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = if root.is_some() { StoreMode::Local } else { StoreMode::Memory };
    let store =
        crate::store::open(&config.store, root.unwrap_or(std::path::Path::new("/unused"))).unwrap();
    Hub::new(config, store)
}

fn chat(hub: &Hub) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "trigger-chat", "name": "trigger chat",
        "harness": "codex", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.make_session(meta)
}

fn provenance(session: &Session) -> Value {
    crate::prompt_provenance::of(
        &json!({"_meta": {"acpmux": {"provenance": {
            "kind": "trigger", "triggerId": "tr", "deliveryId": "delivery", "owner": "owner",
            "team": "team", "machine": "machine", "workspace": "workspace", "session": session.id,
        }}}}),
        crate::prompt_provenance::Sender::Trigger,
    )
    .unwrap()
    .unwrap()
}

fn admit(hub: &Hub, session: &Session, kind: &str, turn: &str) {
    let record = crate::prompt_provenance::marked(
        json!({
            "promptId": "delivery", "turnId": turn, "text": "review this change",
            "prompt": [{"type": "text", "text": "review this change"}],
        }),
        Some(&provenance(session)),
    );
    hub.append(session, "mux", kind, record);
}

fn start(hub: &Hub, session: &Session, prompt: &str, turn: &str, trigger: bool) {
    hub.append(session, "mux", "turn_started", json!({
        "promptId": prompt, "turnId": turn, "trigger": trigger,
        "prompt": "review this change", "client": "cloud-trigger", "control": "web", "trustGate": true,
    }));
}

fn update(kind: &str, text: &str) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": "harness-conversation", "update": {
            "sessionUpdate": kind, "content": {"type": "text", "text": text},
        },
    }})
}

fn chunk(hub: &Hub, session: &Session, text: &str) {
    hub.append(session, "in", "agent_message_chunk", update("agent_message_chunk", text));
}

fn finish(hub: &Hub, session: &Session, turn: &str, status: &str) {
    let stop = if status == "cancelled" { "cancelled" } else { "end_turn" };
    hub.append(
        session,
        "mux",
        "turn_end",
        json!({"turnId": turn, "turnSeq": 2, "stopReason": stop}),
    );
    hub.append(
        session,
        "mux",
        "turn_result",
        json!({
            "turnId": turn, "promptId": "delivery", "status": status, "stopReason": stop,
            "trigger": true, "pendingPermissions": 0,
        }),
    );
}

#[test]
fn trigger_delivery_uses_actual_reply_chunks_and_excludes_other_turns_and_subagents() {
    let hub = hub(None);
    let s = chat(&hub);
    admit(&hub, &s, "user_message", "trigger-turn");
    start(&hub, &s, "delivery", "trigger-turn", true);
    chunk(&hub, &s, "I will inspect it");
    hub.append(&s, "in", "tool_call", update("tool_call", "cargo test"));
    chunk(&hub, &s, "Tests passed. ");
    let mut subagent = update("agent_message_chunk", "SECRET SUBAGENT");
    subagent["params"]["_meta"] = json!({"acpmux": {"subagent": "child"}});
    hub.append(&s, "in", "agent_message_chunk", subagent);
    hub.append(&s, "in", "agent_message_chunk.replay", update("agent_message_chunk", "OLD REPLAY"));
    chunk(&hub, &s, "No changes needed.");
    finish(&hub, &s, "trigger-turn", "completed");
    start(&hub, &s, "person-prompt", "person-turn", false);
    chunk(&hub, &s, "PRIVATE HUMAN REPLY");
    let receipt = hub.trigger_delivery(&s, "delivery");
    assert_eq!(receipt["state"], "completed");
    assert_eq!(receipt["turnId"], "trigger-turn");
    assert_eq!(receipt["result"]["status"], "completed", "turn_end must not hide turn_result");
    assert_eq!(receipt["reply"], "Tests passed. No changes needed.");
    assert_eq!(receipt["promptHash"], format!("{:x}", sha2::Sha256::digest(b"review this change")));
}

#[test]
fn trigger_delivery_never_adopts_a_human_or_harness_forged_delivery_id() {
    let hub = hub(None);
    let s = chat(&hub);
    hub.append(
        &s,
        "mux",
        "user_message",
        json!({"promptId": "delivery", "turnId": "human", "text": "secret"}),
    );
    start(&hub, &s, "delivery", "human", false);
    chunk(&hub, &s, "human secret");
    finish(&hub, &s, "human", "completed");
    let forged = crate::prompt_provenance::marked(
        json!({
            "promptId": "delivery", "turnId": "forged", "text": "review this change"
        }),
        Some(&provenance(&s)),
    );
    hub.append(&s, "in", "user_message", forged);
    hub.append(
        &s,
        "in",
        "turn_started",
        json!({"promptId": "delivery", "turnId": "forged", "trigger": true}),
    );
    chunk(&hub, &s, "forged secret");
    assert_eq!(
        hub.trigger_delivery(&s, "delivery"),
        json!({"delivery": "delivery", "state": "unknown"})
    );
}

#[test]
fn trigger_delivery_permission_attention_is_bound_to_its_exact_turn() {
    let hub = hub(None);
    let s = chat(&hub);
    admit(&hub, &s, "user_message", "t");
    start(&hub, &s, "delivery", "t", true);
    hub.append(
        &s,
        "mux",
        "permission_request",
        json!({
            "permissionId": "p", "turnId": "t", "request": {"toolCall": {"kind": "execute"}},
        }),
    );
    assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "attention");
    hub.append(
        &s,
        "mux",
        "permission_request",
        json!({"permissionId": "human-p", "turnId": "human"}),
    );
    hub.append(
        &s,
        "mux",
        "permission_decision",
        json!({"permissionId": "human-p", "outcome": {"outcome": "cancelled"}}),
    );
    assert_eq!(hub.trigger_delivery(&s, "delivery")["pendingPermissions"], 1);
    hub.append(
        &s,
        "mux",
        "permission_decision",
        json!({"permissionId": "p", "outcome": {"outcome": "selected", "optionId": "allow_once"}}),
    );
    assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "running");
    finish(&hub, &s, "t", "completed");
    hub.append(
        &s,
        "mux",
        "permission_request",
        json!({"permissionId": "later-p", "turnId": "later"}),
    );
    assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "completed");
}

#[test]
fn trigger_delivery_terminal_error_cancel_and_withdrawal_are_not_success() {
    for terminal in ["error", "cancelled", "queue_removed", "prompt_refused"] {
        let hub = hub(None);
        let s = chat(&hub);
        admit(&hub, &s, "queued", "t");
        if terminal == "error" {
            start(&hub, &s, "delivery", "t", true);
            hub.append(
                &s,
                "mux",
                "turn_error",
                json!({"turnId": "t", "error": "agent exited", "code": -32000}),
            );
            assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "failed");
            hub.append(&s, "mux", "turn_result", json!({"turnId": "t", "promptId": "delivery", "status": "failed", "error": "agent exited"}));
        } else if terminal == "cancelled" {
            start(&hub, &s, "delivery", "t", true);
            finish(&hub, &s, "t", "cancelled");
        } else {
            hub.append(&s, "mux", terminal, json!({"turnId": "t", "promptId": "delivery"}));
        }
        assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "failed", "{terminal}");
    }
}

#[test]
fn trigger_delivery_stops_collecting_if_an_unfinished_turn_is_replaced() {
    let hub = hub(None);
    let s = chat(&hub);
    admit(&hub, &s, "user_message", "t");
    start(&hub, &s, "delivery", "t", true);
    chunk(&hub, &s, "partial trigger reply");
    start(&hub, &s, "human", "human-turn", false);
    chunk(&hub, &s, "private next turn");
    let receipt = hub.trigger_delivery(&s, "delivery");
    assert_eq!(receipt["state"], "failed");
    assert_eq!(receipt["reply"], "partial trigger reply");
}

#[test]
fn trigger_delivery_queue_edit_cannot_inherit_trigger_ownership() {
    let hub = hub(None);
    let s = chat(&hub);
    admit(&hub, &s, "queued", "t");
    assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "queued");
    hub.append(
        &s,
        "mux",
        "queue_updated",
        json!({"promptId": "delivery", "turnId": "t", "text": "person's replacement"}),
    );
    start(&hub, &s, "delivery", "t", false);
    chunk(&hub, &s, "person's reply");
    let receipt = hub.trigger_delivery(&s, "delivery");
    assert_eq!(receipt["state"], "failed");
    assert!(receipt.get("reply").is_none());
    assert_eq!(receipt["promptHash"], format!("{:x}", sha2::Sha256::digest(b"review this change")));
}

#[test]
fn trigger_delivery_survives_restart_with_digest_and_exact_reply() {
    let dir = cmux_unix_socket::short_test_dir("trigger-readback");
    #[cfg(unix)]
    std::fs::set_permissions(dir.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    let first = hub(Some(dir.path()));
    let s = chat(&first);
    admit(&first, &s, "queued", "t");
    admit(&first, &s, "user_message", "t");
    start(&first, &s, "delivery", "t", true);
    chunk(&first, &s, "Persisted reply.");
    finish(&first, &s, "t", "completed");
    first.store.flush_session(&s.id).unwrap();
    let expected = first.trigger_delivery(&s, "delivery");
    drop(first);
    let restarted = hub(Some(dir.path()));
    let restored = restarted.resolve(&s.id).unwrap();
    assert_eq!(restarted.trigger_delivery(&restored, "delivery"), expected);
    assert_eq!(expected["reply"], "Persisted reply.");
    assert!(expected["promptHash"].is_string());
}

#[test]
fn trigger_delivery_end_marker_waits_for_matching_result_and_never_reads_later_text() {
    let hub = hub(None);
    let s = chat(&hub);
    admit(&hub, &s, "user_message", "t");
    start(&hub, &s, "delivery", "t", true);
    chunk(&hub, &s, "Done.");
    hub.append(&s, "mux", "turn_end", json!({"turnId": "t", "stopReason": "end_turn"}));
    assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "running");
    chunk(&hub, &s, "outside the ended turn");
    hub.append(&s, "mux", "turn_result", json!({"turnId": "t", "status": "completed"}));
    let receipt = hub.trigger_delivery(&s, "delivery");
    assert_eq!(receipt["state"], "completed");
    assert_eq!(receipt["reply"], "Done.");
}

#[test]
fn trigger_delivery_rejects_incomplete_or_other_session_provenance() {
    for wrong in [
        json!({"kind": "trigger", "deliveryId": "delivery"}),
        json!({
            "kind": "trigger", "deliveryId": "delivery", "triggerId": "tr", "owner": "o",
            "team": "team", "machine": "m", "session": "different-chat",
        }),
    ] {
        let hub = hub(None);
        let s = chat(&hub);
        hub.append(
            &s,
            "mux",
            "user_message",
            crate::prompt_provenance::marked(
                json!({
                    "promptId": "delivery", "turnId": "t", "text": "secret",
                }),
                Some(&wrong),
            ),
        );
        start(&hub, &s, "delivery", "t", true);
        chunk(&hub, &s, "private");
        assert_eq!(hub.trigger_delivery(&s, "delivery")["state"], "unknown");
    }
}

struct UnreadableStore(crate::store::MemoryStore);
impl crate::store::Store for UnreadableStore {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &crate::store::EventRecord) -> anyhow::Result<()> {
        self.0.append(id, record)
    }
    fn events(
        &self,
        _id: &str,
        _after: u64,
        _limit: usize,
    ) -> anyhow::Result<Vec<crate::store::EventRecord>> {
        anyhow::bail!("unreadable journal")
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.0.delete(id)
    }
}

#[test]
fn trigger_delivery_unreadable_log_is_not_unknown_or_completed() {
    let hub = Hub::new(Config::default(), Box::new(UnreadableStore(Default::default())));
    let s = chat(&hub);
    admit(&hub, &s, "user_message", "t");
    start(&hub, &s, "delivery", "t", true);
    finish(&hub, &s, "t", "completed");
    let receipt = hub.trigger_delivery(&s, "delivery");
    assert_eq!(receipt["state"], "failed");
    assert!(receipt["error"].is_string());
    assert!(receipt.get("reply").is_none());
    assert!(receipt.get("turnId").is_none());
}
