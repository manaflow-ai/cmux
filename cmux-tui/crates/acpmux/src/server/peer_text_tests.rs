//! hq#2509: a peer reads a summary's session text masked; every other
//! origin reads it raw.

use serde_json::{Value, json};

use super::{masked, masks};
use crate::rpc::{Message, method};
use crate::server::Origin;

/// A fake token, assembled so no file holds one.
fn github_token() -> String {
    format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234")
}

const MASK: &str = "[GitHub Personal Access Token]";

/// A summary with the token in every field that carries session text.
fn summary(token: &str) -> Value {
    json!({
        "sessionId": "s1", "name": "deploy", "harness": "claude", "status": "running", "lastSeq": 4,
        "title": format!("rotate {token}"),
        "lastPrompt": format!("push with {token}"),
        "preview": format!("used {token}"),
        "lastMessage": {"role": "agent", "text": format!("used {token}")},
        "turn": {"prompt": format!("push with {token}"), "startedAt": 5, "client": "c", "turnId": "t", "promptId": "p", "turnSeq": 1,
                 "activity": format!("curl -H {token}"), "planStep": format!("log in with {token}")},
        "waitingOn": "question",
        "waitingPrompt": format!("Use {token}?"),
        "queue": [{"prompt": format!("then {token}"), "promptId": "q", "turnId": "t2", "client": "c", "queuedAt": 6, "held": false}],
        "lastTurn": {"status": "failed", "errorText": format!("bad credentials {token}")},
        "lane": {"state": "working", "since": 5, "error": null, "step": format!("push with {MASK}"), "title": format!("rotate {MASK}")},
    })
}

fn assert_masked(s: &Value) {
    let text = s.to_string();
    assert!(!text.contains("ghp_"), "a raw token reached a peer: {text}");
    assert_eq!(s["title"], format!("rotate {MASK}"));
    assert_eq!(s["lastPrompt"], format!("push with {MASK}"));
    assert_eq!(s["preview"], format!("used {MASK}"));
    assert_eq!(s["lastMessage"]["text"], format!("used {MASK}"));
    assert_eq!(s["lastMessage"]["role"], "agent");
    assert_eq!(s["turn"]["prompt"], format!("push with {MASK}"));
    assert_eq!(s["turn"]["activity"], format!("curl -H {MASK}"));
    assert_eq!(s["turn"]["planStep"], format!("log in with {MASK}"));
    assert_eq!(s["waitingPrompt"], format!("Use {MASK}?"));
    assert_eq!(s["queue"][0]["prompt"], format!("then {MASK}"));
    assert_eq!(s["lastTurn"]["errorText"], format!("bad credentials {MASK}"));
    // What addresses the session stays exact.
    assert_eq!(s["sessionId"], "s1");
    assert_eq!(s["name"], "deploy");
}

fn result(msg: &Message) -> Value {
    match msg {
        Message::Response { result: Some(r), .. } => r.clone(),
        Message::Notification { params: Some(p), .. } => p.clone(),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_session_list_reply_is_masked_for_a_peer() {
    let token = github_token();
    let reply = Message::ok(json!(1), json!({"sessions": [summary(&token), summary(&token)]}));
    let out = masked(&reply).expect("the reply carries session text");
    for s in result(&out)["sessions"].as_array().unwrap() {
        assert_masked(s);
    }
}

#[test]
fn a_session_changed_notification_and_a_summary_under_meta_are_masked() {
    let token = github_token();
    let changed = Message::notification(
        method::MUX_SESSION_CHANGED,
        json!({"sessionId": "s1", "session": summary(&token), "kind": "turn_start"}),
    );
    assert_masked(&result(&masked(&changed).expect("masked"))["session"]);
    let new =
        Message::ok(json!(2), json!({"sessionId": "s1", "_meta": {"acpmux": summary(&token)}}));
    assert_masked(&result(&masked(&new).expect("masked"))["_meta"]["acpmux"]);
}

#[test]
fn a_chats_title_and_preview_are_masked_for_a_peer() {
    let token = github_token();
    let chat = json!({"key": "claude:abc", "title": format!("fix {token}"), "attention": null, "preview": format!("ran {token}")});
    let page = Message::ok(json!(3), json!({"chats": [chat.clone()]}));
    let out = result(&masked(&page).expect("masked"));
    assert_eq!(out["chats"][0]["title"], format!("fix {MASK}"));
    assert_eq!(out["chats"][0]["preview"], format!("ran {MASK}"));
    assert_eq!(out["chats"][0]["key"], "claude:abc");
    let mut change = chat;
    change["kind"] = json!("activity");
    let note = Message::notification("_acpmux/chat_changed", change);
    assert_eq!(result(&masked(&note).expect("masked"))["preview"], format!("ran {MASK}"));
}

#[test]
fn agent_updates_and_records_pass_as_they_are() {
    let token = github_token();
    let update = Message::notification(
        method::SESSION_UPDATE,
        json!({"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": token}}}),
    );
    assert!(masked(&update).is_none());
    let event = Message::notification(
        method::MUX_EVENT,
        json!({"sessionId": "s1", "msg": summary(&token)}),
    );
    assert!(masked(&event).is_none());
}

#[test]
fn text_without_a_secret_is_left_alone() {
    let mut plain = summary("the build");
    plain["lane"] = Value::Null;
    let reply = Message::ok(json!(1), json!({"sessions": [plain.clone()]}));
    let out = masked(&reply).map(|m| result(&m)).unwrap_or_else(|| result(&reply));
    assert_eq!(out["sessions"][0], plain);
}

#[test]
fn only_a_peer_reads_masked_text() {
    for origin in [Origin::Local, Origin::LocalApp, Origin::Web] {
        assert!(!masks(origin), "{origin:?}");
    }
    assert!(masks(Origin::Peer));
}

#[test]
fn a_huge_prompt_is_cut_for_a_peer_after_it_is_masked() {
    let token = github_token();
    let mut s = summary(&token);
    // The token straddles the cut: masked first, so no part of it is left.
    s["lastPrompt"] = json!(format!("{}{token} {}", "x ".repeat(8_190), "y".repeat(4_000_000)));
    let out = result(&masked(&Message::ok(json!(1), json!({"sessions": [s]}))).expect("masked"));
    let prompt = out["sessions"][0]["lastPrompt"].as_str().unwrap();
    assert!(!prompt.contains("ghp_"), "{}", &prompt[16_000..]);
    assert!(prompt.ends_with("[Git…"), "{}", &prompt[16_000..]);
    assert_eq!(prompt.chars().count(), 16_385);
}

#[test]
fn an_acp_session_list_entry_and_a_chat_transcript_mask_their_titles() {
    let token = github_token();
    let entry = json!({"sessionId": "s1", "cwd": "/tmp", "title": format!("rotate {token}"), "_meta": {"acpmux": summary(&token)}});
    let list = Message::ok(json!(4), json!({"sessions": [entry]}));
    let out = result(&masked(&list).expect("masked"));
    assert_eq!(out["sessions"][0]["title"], format!("rotate {MASK}"));
    assert_masked(&out["sessions"][0]["_meta"]["acpmux"]);
    let transcript = json!({"key": "claude:abc", "harness": "claude", "title": format!("fix {token}"), "cwd": "/tmp", "turns": []});
    let out = result(&masked(&Message::ok(json!(5), transcript)).expect("masked"));
    assert_eq!(out["title"], format!("fix {MASK}"));
}
