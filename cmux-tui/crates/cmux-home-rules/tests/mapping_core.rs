//! `HomeCoreMapping` as ops: the local owner's wire rows as Home rows, and Home ops as the owner's.
//! Ports `HomeCoreWidgetMappingTests` and pins the decisions the Swift mapping makes.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("mapping.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn wire_message(parts: Value) -> Value {
    json!({"id": "m1", "conversation": "c1", "seq": 3, "client_msg_id": "k1", "author": "p_me",
           "parts": parts, "created_at": "2026-11-25T20:16:00.000Z"})
}

fn identity() -> Value {
    json!({"cloudId": "user_cloud", "localId": "p_me", "displayName": "Me", "participantId": "user_cloud"})
}

#[test]
fn a_stored_widget_shows_its_fallback_text() {
    let reply = op(
        "part",
        json!({"part": {"type": "widget", "kind": "pr", "fallback": "PR #38629: open, checks passing"}}),
    );
    assert_eq!(
        reply["part"],
        json!({"text": {"_0": "PR #38629: open, checks passing", "mentions": []}})
    );
    assert!(reply.get("question").is_none());
}

#[test]
fn a_widget_without_fallback_shows_its_plain_text() {
    let reply = op("part", json!({"part": {"type": "widget", "url": "https://example.com/a"}}));
    assert_eq!(reply["part"]["text"]["_0"], "https://example.com/a");
}

#[test]
fn a_question_part_is_text_and_its_payload() {
    let payload = json!({"type": "question", "id": "q1", "prompt": "Ship it?"});
    let reply = op("part", json!({"part": payload}));
    assert_eq!(reply["part"]["text"]["_0"], "question");
    assert_eq!(reply["question"], payload);
}

#[test]
fn an_unknown_work_status_reads_as_running() {
    let reply = op("part", json!({"part": {"type": "work", "session": "s1", "status": "paused"}}));
    assert_eq!(reply["part"]["work"]["_0"]["status"], "running");
    assert_eq!(reply["part"]["work"]["_0"]["title"], "s1");
}

#[test]
fn the_mux_agent_is_the_chief() {
    let chief = op(
        "participant",
        json!({"participant": {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}}),
    );
    let other = op(
        "participant",
        json!({"participant": {"id": "agent_1", "kind": "agent", "display_name": "Helper", "agent_class": "codex"}}),
    );
    assert_eq!(chief["participant"]["displayName"], "Chief");
    assert_eq!(other["participant"]["displayName"], "Helper");
    let named = op(
        "participant",
        json!({"participant": {"id": "agent_mux", "kind": "agent", "agent_class": "mux"}, "chiefName": "Boss"}),
    );
    assert_eq!(named["participant"]["displayName"], "Boss");
}

#[test]
fn dates_parse_or_fall_back() {
    assert_eq!(op("date", json!({"text": "1970-01-01T00:00:01.500Z"}))["date"], 1.5);
    assert!(op("date", json!({"text": "not a date"})).get("date").is_none_or(Value::is_null));
}

#[test]
fn an_unknown_tapback_reads_as_an_emoji_and_authors_map_through_the_identity() {
    let mut message = wire_message(
        json!([{"type": "text", "text": "hi", "runs": [{"start": 0, "length": 2, "mention": "user_cloud"}]}]),
    );
    message["reactions"] = json!([
        {"author": "user_cloud", "part_index": 0, "kind": {"tapback": "love"}},
        {"author": "user_x", "part_index": 0, "kind": {"tapback": "sparkle"}},
    ]);
    message["author"] = json!("user_cloud");
    let reply = op("message", json!({"message": message, "identity": identity()}));
    let reactions = reply["message"]["reactions"].as_array().unwrap();
    assert_eq!(reactions[0]["kind"], json!({"tapback": {"_0": "love"}}));
    assert_eq!(reactions[1]["kind"], json!({"emoji": {"_0": "sparkle"}}));
    assert_eq!(reactions[0]["author"], "p_me");
    assert_eq!(reply["message"]["author"], "p_me");
}

#[test]
fn a_reply_without_thread_root_threads_under_its_reply_target() {
    let mut message = wire_message(json!([{"type": "text", "text": "re"}]));
    message["reply_to"] = json!({"message_id": "m0", "part_index": 0});
    let reply = op("message", json!({"message": message}));
    assert_eq!(reply["message"]["threadRoot"], "m0");
}

#[test]
fn home_ops_encode_as_the_owners() {
    let send = op(
        "op",
        json!({"key": "k1", "op": {"kind": "sendMessage", "conversation": "c1",
        "parts": [{"text": {"_0": "hi", "mentions": []}}], "threadRoot": "m0"}}),
    );
    assert_eq!(send["conversation"], "c1");
    assert_eq!(send["op"]["kind"], "message.send");
    assert_eq!(send["op"]["client_msg_id"], "k1");
    assert_eq!(send["op"]["reply_to"], json!({"message_id": "m0", "part_index": 0}));
    assert_eq!(send["op"]["thread_root"], "m0");
    let title = op(
        "op",
        json!({"key": "k2", "op": {"kind": "renameConversation", "conversation": "c1", "title": "  Plans  "}}),
    );
    assert_eq!(title["op"]["title"], "Plans");
    let unknown = op("op", json!({"key": "k3", "op": {"kind": "setPinned", "conversation": "c1"}}));
    assert!(unknown["op"].is_null());
}

#[test]
fn home_parts_go_as_owner_parts_or_their_text() {
    let reply = op(
        "parts",
        json!({
            "parts": [
                {"text": {"_0": "hi", "mentions": [{"start": 0, "length": 2, "participant": "p_me"}]}},
                {"location": {"_0": {"latitude": 1.5, "longitude": 2.0}}},
            ],
        }),
    );
    let parts = reply["parts"].as_array().unwrap();
    assert_eq!(parts[0]["type"], "text");
    assert_eq!(parts[0]["runs"][0]["mention"], "p_me");
    assert_eq!(parts[1], json!({"type": "text", "text": "1.5, 2.0"}));
}

#[test]
fn a_stored_attachment_keeps_the_owners_record() {
    let reply = op(
        "refStoredAs",
        json!({
            "ref": {"hash": "h1", "name": "a.png", "mimeType": "image/png", "byteCount": 10},
            "stored": {"hash": "h1", "mime_type": "image/jpeg", "byte_count": 20},
        }),
    );
    assert_eq!(reply["ref"]["name"], "a.png");
    assert_eq!(reply["ref"]["mime_type"], "image/jpeg");
    assert_eq!(reply["ref"]["byte_count"], 20);
}
