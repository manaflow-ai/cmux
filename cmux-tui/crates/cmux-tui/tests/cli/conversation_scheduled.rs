//! Send Later on the local conversation owner (`conversation-scheduled-v1`,
//! cmux#25634), over a real headless daemon: the page (the Chief chat's path)
//! schedules a message and the daemon sends it at its time as the person,
//! never before; the page lists, edits, cancels and sends one now; the Chief
//! (a bound agent) schedules its own and never sees or changes the person's;
//! a message survives a daemon kill and one that came due while the daemon was
//! down goes out when it starts again.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::conversation_inbox_state::{Unix, last_ws_addr, restart};
use super::conversation_tree::{TOKEN, Ws};
use super::*;

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

fn send(key: &str, text: &str) -> Value {
    json!({"kind": "message.send", "client_msg_id": key, "parts": [{"type": "text", "text": text}]})
}

fn create(conversation: &str, key: &str, text: &str, send_at_ms: u64) -> Value {
    json!({"op": {"kind": "scheduled.create", "conversation": conversation,
                  "send_at_ms": send_at_ms, "send": send(key, text)}})
}

fn op(kind: &str, id: &str) -> Value {
    json!({"op": {"kind": kind, "id": id}})
}

fn refused(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains(code), "expected {code}: {reply}");
}

/// The message with `client_msg_id` `key` from the page's stream, and every
/// `conversation-scheduled-changed` event read before it.
fn sent_message(page: &mut Ws, key: &str) -> (Value, Vec<Value>) {
    let mut scheduled = Vec::new();
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-scheduled-changed" {
            scheduled.push(event);
            continue;
        }
        if event["event"] == "conversation-changed"
            && event["change"]["kind"] == "message"
            && event["change"]["message"]["client_msg_id"] == key
        {
            return (event["change"]["message"].clone(), scheduled);
        }
    }
}

/// The next `conversation-scheduled-changed` event on the page's stream.
fn scheduled_event(page: &mut Ws) -> Value {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-scheduled-changed" {
            return event;
        }
    }
}

fn listed(page: &mut Ws, conversation: &str) -> Vec<Value> {
    page.request("conversation-scheduled-list", json!({"conversation": conversation}))["scheduled"]
        .as_array()
        .unwrap()
        .clone()
}

/// The owner's `created_at` (`2026-10-26T12:34:56.789Z`) in Unix ms.
fn created_ms(message: &Value) -> u64 {
    let text = message["created_at"].as_str().unwrap();
    let number = |range: std::ops::Range<usize>| -> i64 { text[range].parse().unwrap() };
    let (year, month, day) = (number(0..4), number(5..7), number(8..10));
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let days = era * 146_097 + year_of_era * 365 + year_of_era / 4 - year_of_era / 100
        + day_of_year
        - 719_468;
    let seconds = days * 86_400 + number(11..13) * 3_600 + number(14..16) * 60 + number(17..19);
    (seconds * 1_000 + number(20..23)) as u64
}

#[test]
fn a_scheduled_message_is_sent_at_its_time_and_survives_a_restart() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let mut server = HeadlessServer::start_with_config("conversation-scheduled", Some(&config));
    let mut page = Ws::open(&last_ws_addr(&server));
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "conversation-scheduled-v1"), "{identity}");
    page.request("subscribe", json!({}));
    let chat = page.create_channel("scheduled-chat", "chief");
    let rev = |page: &mut Ws| {
        let list = page.request("conversation-list", json!({}));
        list["conversations"].as_array().unwrap().iter().find(|c| c["id"] == json!(chat)).unwrap()
            ["rev"]
            .clone()
    };
    let rev_before = rev(&mut page);

    // Scheduled 1.5 s ahead: listed as waiting, no message and no rev yet.
    let at = now_ms() + 1_500;
    let created =
        page.request("conversation-scheduled-op", create(&chat, "later-1", "Standup now", at));
    let scheduled = created["scheduled"].clone();
    assert_eq!(scheduled["state"], "waiting", "{created}");
    assert_eq!(scheduled["author"], "user_local", "{created}");
    assert_eq!(scheduled["send_at_ms"], at, "{created}");
    assert_eq!(created["replayed"], false, "{created}");
    let id = scheduled["id"].as_str().unwrap().to_owned();
    let event = scheduled_event(&mut page);
    assert_eq!(event["scheduled"]["id"], json!(id), "{event}");
    assert_eq!(event["participant"], "user_local", "{event}");
    let list = listed(&mut page, &chat);
    assert_eq!(list.len(), 1, "{list:?}");
    assert_eq!(rev(&mut page), rev_before, "a waiting message is not a conversation change");
    // The same request again is the same message.
    let again =
        page.request("conversation-scheduled-op", create(&chat, "later-1", "Standup now", at));
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(again["scheduled"]["id"], json!(id), "{again}");
    // A retry that counts its delay from a later now (a Chief replaying its
    // turn) is the same message at its first time, never a second one.
    let later =
        page.request("conversation-scheduled-op", create(&chat, "later-1", "Standup now", at + 9));
    assert_eq!(later["replayed"], true, "{later}");
    assert_eq!(later["scheduled"]["send_at_ms"], at, "{later}");
    refused(
        &page.reply("conversation-scheduled-op", create(&chat, "later-1", "Other text", at)),
        "idempotency_conflict",
    );

    // It goes out at its time, as the person, never before, and leaves the queue.
    let (message, events) = sent_message(&mut page, "later-1");
    assert_eq!(message["author"], "user_local", "{message}");
    assert!(created_ms(&message) >= at, "sent early: {message} (due {at})");
    let removed = match events.iter().find(|e| e.get("removed").is_some()) {
        Some(event) => event.clone(),
        None => scheduled_event(&mut page),
    };
    assert_eq!(removed["removed"]["id"], json!(id), "{removed}");
    assert_eq!(removed["removed"]["reason"], "sent", "{removed}");
    assert_eq!(removed["removed"]["seq"], message["seq"], "{removed}");
    assert!(listed(&mut page, &chat).is_empty());

    // Edit (text and time), then cancel: nothing is sent.
    let far = now_ms() + 3_600_000;
    let held = page.request("conversation-scheduled-op", create(&chat, "later-2", "draft", far));
    let held_id = held["scheduled"]["id"].as_str().unwrap().to_owned();
    let edited = page.request(
        "conversation-scheduled-op",
        json!({"op": {"kind": "scheduled.update", "id": held_id, "send_at_ms": far + 60_000,
                      "parts": [{"type": "text", "text": "final"}]}}),
    );
    assert_eq!(edited["scheduled"]["send_at_ms"], far + 60_000, "{edited}");
    assert_eq!(edited["scheduled"]["op"]["parts"][0]["text"], "final", "{edited}");
    let cancelled = page.request("conversation-scheduled-op", op("scheduled.cancel", &held_id));
    assert_eq!(cancelled["removed"]["reason"], "cancelled", "{cancelled}");
    refused(
        &page.reply("conversation-scheduled-op", op("scheduled.cancel", &held_id)),
        "unknown_scheduled",
    );

    // Send Now: at once, with the message in the reply.
    let soon =
        page.request("conversation-scheduled-op", create(&chat, "later-3", "right away", far));
    let soon_id = soon["scheduled"]["id"].as_str().unwrap().to_owned();
    let now = page.request("conversation-scheduled-op", op("scheduled.send_now", &soon_id));
    assert_eq!(now["removed"]["reason"], "sent", "{now}");
    let (message, _) = sent_message(&mut page, "later-3");
    assert_eq!(now["removed"]["seq"], message["seq"], "{now}");

    // Refusals: past the horizon, not a send, an id already sent, a
    // conversation the person is not in.
    refused(
        &page.reply(
            "conversation-scheduled-op",
            create(&chat, "later-4", "x", now_ms() + 400 * 86_400_000),
        ),
        "too_late",
    );
    refused(
        &page.reply(
            "conversation-scheduled-op",
            json!({"op": {"kind": "scheduled.create", "conversation": chat, "send_at_ms": far,
                          "send": {"kind": "read_cursor.set", "seq": 1}}}),
        ),
        "not_a_send",
    );
    refused(
        &page.reply("conversation-scheduled-op", create(&chat, "later-1", "Standup now", far)),
        "idempotency_conflict",
    );
    refused(
        &page.reply(
            "conversation-scheduled-op",
            create("conv_00000000000000000000000000", "later-5", "x", far),
        ),
        "unknown_conversation",
    );

    // The Chief (agent_mux) schedules its own, and never sees or changes the person's.
    let mut home = Unix::open(&server.socket);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut chief = Unix::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    chief.request("subscribe", json!({}));
    let mine = page.request("conversation-scheduled-op", create(&chat, "later-6", "mine", far));
    let mine_id = mine["scheduled"]["id"].as_str().unwrap().to_owned();
    let theirs =
        chief.request("conversation-scheduled-op", create(&chat, "chief-later", "reminder", far));
    assert_eq!(theirs["scheduled"]["author"], "agent_mux", "{theirs}");
    let chief_list = chief.request("conversation-scheduled-list", json!({}));
    let chief_list = chief_list["scheduled"].as_array().unwrap();
    assert_eq!(chief_list.len(), 1, "{chief_list:?}");
    assert_eq!(chief_list[0]["author"], "agent_mux");
    refused(
        &chief.reply("conversation-scheduled-op", op("scheduled.cancel", &mine_id)),
        "unknown_scheduled",
    );
    refused(
        &chief.reply("conversation-scheduled-op", op("scheduled.send_now", &mine_id)),
        "unknown_scheduled",
    );
    let page_list = listed(&mut page, &chat);
    assert_eq!(page_list.len(), 1, "{page_list:?}");
    assert_eq!(page_list[0]["id"], json!(mine_id));
    page.sent(&chat, "after-chief", None, None);
    let leaked: Vec<Value> = chief
        .events_before("after-chief")
        .into_iter()
        .filter(|event| event["event"] == "conversation-scheduled-changed")
        .filter(|event| event["participant"] != "agent_mux")
        .collect();
    assert!(leaked.is_empty(), "the Chief saw the person's scheduled messages: {leaked:?}");

    // Durable: a message due while the daemon is down goes out when it
    // starts again, and one still ahead stays listed.
    let due = now_ms() + 2_000;
    page.request("conversation-scheduled-op", create(&chat, "later-7", "while down", due));
    let waiting = listed(&mut page, &chat);
    assert!(
        waiting.iter().any(|item| item["op"]["client_msg_id"] == "later-7"),
        "still waiting before the kill: {waiting:?}"
    );
    drop(page);
    drop(chief);
    drop(home);
    let _ = server.child.kill();
    let _ = server.child.wait();
    // The daemon is down across the due time (a test wait, not a runtime one).
    std::thread::sleep(Duration::from_millis(due.saturating_sub(now_ms()) + 100));
    let restarted = now_ms();
    let addr = restart(&mut server);
    let mut page = Ws::open(&addr);
    page.request("subscribe", json!({}));
    let history = page.request("conversation-snapshot", json!({"conversation": chat, "tail": 20}));
    let message = match history["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["client_msg_id"] == "later-7")
    {
        Some(message) => message.clone(),
        None => sent_message(&mut page, "later-7").0,
    };
    assert!(created_ms(&message) >= restarted, "sent before the restart: {message}");
    let list = listed(&mut page, &chat);
    assert_eq!(list.len(), 1, "only the far one waits: {list:?}");
    assert_eq!(list[0]["id"], json!(mine_id));
}

/// A file in a scheduled message is its author's until the message is sent:
/// the Chief can neither read it nor attach it before then, and can after.
#[test]
fn a_scheduled_file_stays_private_until_it_is_sent() {
    use base64::Engine as _;
    use sha2::{Digest, Sha256};

    const FILE: &[u8] = b"quarterly numbers, not yet shared";
    let hash: String = Sha256::digest(FILE).iter().map(|byte| format!("{byte:02x}")).collect();
    let server = HeadlessServer::start("conversation-scheduled-file");
    let mut home = Unix::open(&server.socket);
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": "sched-file", "title": "Numbers", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Tester"},
            {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]}),
    );
    let chat = created["conversation"]["id"].as_str().unwrap().to_owned();
    let begun = home.request(
        "conversation-attachment-upload",
        json!({"op": "begin", "conversation": chat, "sha256": hash, "byte_count": FILE.len(),
               "mime_type": "text/plain", "name": "numbers.txt"}),
    );
    let upload = begun["upload"].as_str().unwrap().to_owned();
    home.request(
        "conversation-attachment-upload",
        json!({"op": "chunk", "upload": upload, "piece": "original", "offset": 0,
               "data": base64::engine::general_purpose::STANDARD.encode(FILE)}),
    );
    home.request("conversation-attachment-upload", json!({"op": "commit", "upload": upload}));
    let part = json!({"type": "attachment", "hash": hash, "name": "numbers.txt",
                      "mime_type": "text/plain", "byte_count": FILE.len()});
    let scheduled = home.request(
        "conversation-scheduled-op",
        json!({"op": {"kind": "scheduled.create", "conversation": chat,
                      "send_at_ms": now_ms() + 3_600_000,
                      "send": {"kind": "message.send", "client_msg_id": "file-later",
                               "parts": [{"type": "text", "text": "numbers"}, part]}}}),
    );
    let id = scheduled["scheduled"]["id"].as_str().unwrap().to_owned();

    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut chief = Unix::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    let read = json!({"conversation": chat, "hash": hash, "variant": "original",
                      "offset": 0, "length": 4096});
    let early = chief.reply("conversation-attachment-read", read.clone());
    assert_eq!(early["ok"], false, "the Chief read a file that was only scheduled: {early}");
    let reuse = chief.reply(
        "conversation-op",
        json!({"conversation": chat, "idempotency_key": "chief-reuse",
               "op": {"kind": "message.send", "client_msg_id": "chief-reuse", "parts": [part]}}),
    );
    assert_eq!(reuse["ok"], false, "the Chief attached a file that was only scheduled: {reuse}");

    let sent = home.request("conversation-scheduled-op", op("scheduled.send_now", &id));
    assert_eq!(sent["removed"]["reason"], "sent", "{sent}");
    let read = chief.request("conversation-attachment-read", read);
    let bytes =
        base64::engine::general_purpose::STANDARD.decode(read["data"].as_str().unwrap()).unwrap();
    assert_eq!(bytes, FILE);
}
