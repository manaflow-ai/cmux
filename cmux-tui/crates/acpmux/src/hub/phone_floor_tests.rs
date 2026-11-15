//! The owner's phone drives a chat started on this machine in the mode it has, one that does not
//! ask included (`Hub::owner_phone_full_access`, D13 in `web_control.rs`). Its running turn must
//! stop going on the moment the phone is removed or its Full access turned off: Claude Code's
//! PreToolUse gate refuses the turn's next tool, and `hold_policies_again` (which the revoke and
//! the setting run) ends the turn, though no policy holds the chat.

use super::*;
use serde_json::json;

fn fixture() -> (Arc<Hub>, Arc<Session>, String) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    // A chat started on this machine (not `remote_origin`), in a mode that does not ask.
    let meta: SessionMeta = serde_json::from_value(json!({"schema": META_SCHEMA, "id": "mac-chat",
        "name": "mac-chat", "harness": "fake", "cwd": "/tmp", "status": "idle",
        "createdAt": 1, "updatedAt": 1,
        "modes": {"currentModeId": "bypassPermissions",
            "availableModes": [{"id": "default", "name": "Default"},
                {"id": "bypassPermissions", "name": "Bypass"}]}}))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("mac-chat").unwrap();
    let seq = hub.append(&session, "mux", "turn_started", json!({"turnId": "turn-phone"})).seq;
    *session.turn.lock().unwrap() = Some(TurnInfo {
        trigger: false,
        started_at: 1,
        client: "phone".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "turn-phone".into(),
        prompt_id: "prompt-phone".into(),
        turn_seq: seq,
        control: Control::Web,
        doing: Default::default(),
        notice: false,
        persons: false,
        accepted: true,
    });
    let (device, _) = hub.pairing.issue_phone("phone-iphone").unwrap();
    *session.floor.turn_device.lock().unwrap() = Some(device.id.clone());
    (hub, session, device.id)
}

fn tool_call(session: &Session) -> Value {
    json!({"sessionId": session.id, "options": [],
        "toolCall": {"toolCallId": "t1", "title": "rm -rf build", "kind": "execute"}})
}

fn cancelled_turn(session: &Session) -> Option<String> {
    session.floor.floor_cancelled_turn.lock().unwrap().clone()
}

#[tokio::test]
async fn a_removed_phones_turn_gets_no_more_tools() {
    let (hub, session, phone) = fixture();
    let on = hub.answer_tool_gate(&session, tool_call(&session)).await;
    assert_ne!(on["decision"], "deny", "the phone with Full access drives the chat: {on}");
    assert_eq!(cancelled_turn(&session), None);
    hub.pairing.revoke(&phone).unwrap();
    let off = hub.answer_tool_gate(&session, tool_call(&session)).await;
    assert_eq!(off["decision"], "deny", "{off}");
    assert_eq!(off["reason"], "remote.mode_not_asking", "{off}");
    assert_eq!(cancelled_turn(&session).as_deref(), Some("turn-phone"), "the turn ends too");
}

#[tokio::test]
async fn full_access_off_ends_the_phones_running_turn_in_a_chat_no_policy_holds() {
    let (hub, session, phone) = fixture();
    assert_eq!(hub.hold_policies_again().await, 0, "no chat is out of its policy");
    assert_eq!(cancelled_turn(&session), None, "the phone still has Full access");
    hub.pairing.set_full_access(&phone, false).unwrap();
    hub.hold_policies_again().await;
    assert_eq!(cancelled_turn(&session).as_deref(), Some("turn-phone"));
    let off = hub.answer_tool_gate(&session, tool_call(&session)).await;
    assert_eq!(off["decision"], "deny", "{off}");
}
