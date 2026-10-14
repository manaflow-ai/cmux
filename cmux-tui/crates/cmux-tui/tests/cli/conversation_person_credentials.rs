//! Other people of a shared room act as themselves on the local conversation
//! owner (`conversation-person-credentials-v1`): the local user mints a
//! credential for `user_mira`, a Unix connection binds with it, and the page
//! (a real headless daemon's WebSocket, the Channels page path) sees Mira
//! type, reply inside a thread, react and edit, each stamped with her id.
//! The owner's own id and a paired device never get a credential, a
//! replaced credential ends the old binding, and Mira's typing ends when
//! her connection does.

use serde_json::{Value, json};

use super::conversation_thread_objects::Unix;
use super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

/// The next event on the page's stream that `matches`.
fn next_event(page: &mut Ws, matches: impl Fn(&Value) -> bool) -> Value {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if matches(&event) {
            return event;
        }
    }
}

fn typing(page: &mut Ws, participant: &str, on: bool) -> Value {
    next_event(page, |event| {
        event["event"] == "conversation-typing"
            && event["participant"] == participant
            && event["on"] == on
    })
}

fn change(page: &mut Ws, kind: &str, id_or_key: &str) -> Value {
    let event = next_event(page, |event| {
        let message = &event["change"]["message"];
        event["event"] == "conversation-changed"
            && event["change"]["kind"] == kind
            && (message["id"] == id_or_key || message["client_msg_id"] == id_or_key)
    });
    event["change"]["message"].clone()
}

fn op(conversation: &str, key: &str, op: Value) -> Value {
    json!({"conversation": conversation, "idempotency_key": key, "op": op})
}

fn refused(reply: &Value, text: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains(text), "expected {text}: {reply}");
}

#[test]
fn another_person_binds_with_a_minted_credential_and_replies_reacts_types_and_edits_as_themselves()
{
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server =
        HeadlessServer::start_with_config("conversation-person-credentials", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "conversation-person-credentials-v1"),
        "{identity}"
    );
    page.request("subscribe", json!({}));
    let created = page.request(
        "conversation-create",
        json!({"idempotency_key": "people-channel", "title": "design", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Lawrence"},
            {"id": "user_mira", "kind": "human", "display_name": "Mira Chen"},
            {"id": "user_jonas", "kind": "human", "display_name": "Jonas Weber"},
            {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"}]}),
    );
    let channel = created["conversation"]["id"].as_str().unwrap().to_owned();

    // Only the local user's own Unix connection mints; never for itself or a device.
    let mut home = Unix::open(&server.socket);
    refused(
        &home.reply("conversation-agent-token", json!({"participant": "user_local"})),
        "only for agents and other people",
    );
    refused(
        &home.reply("conversation-agent-token", json!({"participant": "remote_inst_1"})),
        "only for agents and other people",
    );
    refused(
        &page.reply("conversation-agent-token", json!({"participant": "user_mira"})),
        "Unix socket",
    );
    let token =
        home.request("conversation-agent-token", json!({"participant": "user_mira"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut mira = Unix::open(&server.socket);
    refused(
        &mira.reply("conversation-bind", json!({"participant": "user_jonas", "token": token})),
        "not valid",
    );
    refused(
        &mira.reply("conversation-bind", json!({"participant": "user_local", "token": token})),
        "only agent participants and other people",
    );
    let bound =
        mira.request("conversation-bind", json!({"participant": "user_mira", "token": token}));
    assert_eq!(bound["participant"], "user_mira", "{bound}");
    // A bound person is never the owner: no credential minting, no import.
    refused(
        &mira.reply("conversation-agent-token", json!({"participant": "user_jonas"})),
        "only the local user mints",
    );
    refused(
        &mira.reply("conversation-import", json!({"conversation": channel, "messages": []})),
        "only the local user imports",
    );

    // The page starts a thread; Mira types, then replies inside it.
    let root = page.sent(&channel, "root", None, None);
    let root_id = root["id"].as_str().unwrap().to_owned();
    mira.request("conversation-typing", json!({"conversation": channel, "on": true}));
    typing(&mut page, "user_mira", true);
    mira.request(
        "conversation-op",
        op(
            &channel,
            "mira-reply",
            json!({"kind": "message.send", "client_msg_id": "mira-reply",
            "parts": [{"type": "text", "text": "The new rows look great."}],
            "reply_to": {"message_id": root_id, "part_index": 0}, "thread_root": root_id}),
        ),
    );
    let reply = change(&mut page, "message", "mira-reply");
    assert_eq!(reply["author"], "user_mira", "{reply}");
    assert_eq!(reply["thread_root"], root_id, "{reply}");
    let reply_id = reply["id"].as_str().unwrap().to_owned();
    // A name on the request that is not the connection's principal is refused.
    refused(
        &mira.reply(
            "conversation-op",
            json!({"conversation": channel, "idempotency_key": "spoof", "actor": "user_local",
                   "op": {"kind": "message.send", "client_msg_id": "spoof",
                          "parts": [{"type": "text", "text": "x"}]}}),
        ),
        "actor_mismatch",
    );

    // A reaction and an edit carry her id too.
    mira.request(
        "conversation-op",
        op(
            &channel,
            "mira-react",
            json!({"kind": "reaction.add", "message_id": root_id,
            "part_index": 0, "reaction": {"emoji": "🎉"}}),
        ),
    );
    let reacted = change(&mut page, "message-updated", &root_id);
    assert!(
        reacted["reactions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reaction| reaction["author"] == "user_mira"),
        "{reacted}"
    );
    mira.request(
        "conversation-op",
        op(
            &channel,
            "mira-edit",
            json!({"kind": "message.edit", "message_id": reply_id,
            "parts": [{"type": "text", "text": "The new rows look great. Ship it."}]}),
        ),
    );
    let edited = change(&mut page, "message-updated", &reply_id);
    assert_eq!(edited["parts"][0]["text"], "The new rows look great. Ship it.", "{edited}");
    let thread =
        page.request("conversation-thread", json!({"conversation": channel, "root": root_id}));
    assert!(thread.to_string().contains("\"author\":\"user_mira\""), "{thread}");

    // Her typing ends when her connection ends.
    mira.request("conversation-typing", json!({"conversation": channel, "on": true}));
    typing(&mut page, "user_mira", true);
    drop(mira);
    typing(&mut page, "user_mira", false);

    // A new credential ends every binding made with the old one, and its
    // typing; the old connection is neither Mira nor the owner.
    let mut old = Unix::open(&server.socket);
    old.request("conversation-bind", json!({"participant": "user_mira", "token": token}));
    old.request("conversation-typing", json!({"conversation": channel, "on": true}));
    typing(&mut page, "user_mira", true);
    home.request("conversation-agent-token", json!({"participant": "user_mira"}));
    typing(&mut page, "user_mira", false);
    let stale = old.reply(
        "conversation-op",
        op(
            &channel,
            "stale",
            json!({"kind": "message.send", "client_msg_id": "stale",
            "parts": [{"type": "text", "text": "after the new credential"}]}),
        ),
    );
    refused(&stale, "not_participant");
    refused(
        &old.reply("conversation-agent-token", json!({"participant": "user_jonas"})),
        "only the local user mints",
    );
}
