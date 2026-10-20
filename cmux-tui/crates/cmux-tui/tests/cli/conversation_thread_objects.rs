//! Threads as objects on the local conversation owner
//! (`conversation-thread-objects-v1`), over a real headless daemon's
//! WebSocket (the Channels page path) and a Chief's bound Unix connection: a
//! page titles a thread and gives it an owner, the Chief resolves it, a new
//! reply reopens it, and every read (`conversation-thread`, the snapshot's
//! `threads`) and the `message-updated` event on the stream carry the
//! object.

use serde_json::{Value, json};

use super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

/// A JSON-lines client of the daemon's Unix socket.
pub(super) struct Unix {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    next: u64,
}

impl Unix {
    pub(super) fn open(socket: &std::path::Path) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { reader: BufReader::new(stream), writer, next: 1 }
    }

    pub(super) fn reply(&mut self, cmd: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = params.as_object().cloned().unwrap_or_default();
        body.insert("id".into(), json!(id));
        body.insert("cmd".into(), json!(cmd));
        writeln!(self.writer, "{}", Value::Object(body)).unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the connection");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == id {
                return value;
            }
        }
    }

    pub(super) fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed: {value}");
        value["data"].clone()
    }
}

fn update(conversation: &str, key: &str, op: Value) -> Value {
    let mut op = op;
    op["kind"] = json!("thread.update");
    json!({"conversation": conversation, "idempotency_key": key, "op": op})
}

/// The next `message-updated` event of message `id` on the page's stream.
fn updated_event(page: &mut Ws, id: &str) -> Value {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-changed"
            && event["change"]["kind"] == "message-updated"
            && event["change"]["message"]["id"] == id
        {
            return event["change"]["message"].clone();
        }
    }
}

fn thread_of(page: &mut Ws, conversation: &str, root: &str) -> Value {
    page.request("conversation-thread", json!({"conversation": conversation, "root": root}))
        ["thread"]
        .clone()
}

fn snapshot_of(page: &mut Ws, conversation: &str) -> Value {
    page.request("conversation-snapshot", json!({"conversation": conversation, "tail": 10}))
}

fn rejected(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains(code), "expected {code}: {reply}");
}

#[test]
fn a_thread_has_a_title_an_owner_and_a_status_that_a_chief_resolves_and_a_reply_reopens() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("conversation-thread-objects", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(
        capabilities.iter().any(|value| value == "conversation-thread-objects-v1"),
        "{identity}"
    );
    page.request("subscribe", json!({}));
    let channel = page.create_channel("objects-channel", "release");
    // The Chief (agent_mux) acts on its own bound connection.
    let mut home = Unix::open(&server.socket);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut chief = Unix::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));

    let root = page.sent(&channel, "root", None, None);
    let root_id = root["id"].as_str().unwrap().to_owned();
    let first = page.sent(&channel, "first", Some(&root_id), Some(&root_id));
    let first_id = first["id"].as_str().unwrap().to_owned();
    // A thread starts open, untitled and unowned.
    let fresh = thread_of(&mut page, &channel, &root_id);
    assert_eq!(fresh["status"], "open", "{fresh}");
    assert!(fresh.get("title").is_none() && fresh.get("owner").is_none(), "{fresh}");

    // The page titles the thread and hands it to the Builder agent. It is not
    // a new message: the conversation keeps its place in the list.
    let updated_at = snapshot_of(&mut page, &channel)["conversation"]["updated_at"].clone();
    let title_op = json!({"root": root_id, "title": "Ship 1.0", "owner": "agent_builder"});
    let titled = page.request("conversation-op", update(&channel, "t1", title_op.clone()));
    assert_eq!(titled["change"]["kind"], "message-updated", "{titled}");
    let event = updated_event(&mut page, &root_id);
    assert_eq!(event["thread"], json!({"title": "Ship 1.0", "owner": "agent_builder"}), "{event}");
    assert!(event.get("edited_at").is_none(), "a thread update is not an edit: {event}");
    let summary = snapshot_of(&mut page, &channel)["conversation"].clone();
    assert_eq!(summary["updated_at"], updated_at, "{summary}");
    // The same key and op replays; the same key with another op conflicts.
    let replay = page.request("conversation-op", update(&channel, "t1", title_op));
    assert_eq!(replay["replayed"], true, "{replay}");
    let conflict = page.reply(
        "conversation-op",
        update(&channel, "t1", json!({"root": root_id, "title": "Other"})),
    );
    rejected(&conflict, "idempotency_conflict");

    // The Chief resolves it, like any participant.
    chief.request(
        "conversation-op",
        update(&channel, "c1", json!({"root": root_id, "status": "resolved"})),
    );
    let event = updated_event(&mut page, &root_id);
    assert_eq!(event["thread"]["resolved"]["by"], "agent_mux", "{event}");
    assert_eq!(event["thread"]["resolved"]["seq"], first["seq"], "{event}");
    let resolved = thread_of(&mut page, &channel, &root_id);
    assert_eq!(resolved["status"], "resolved", "{resolved}");
    assert_eq!(resolved["title"], "Ship 1.0", "{resolved}");
    assert_eq!(resolved["owner"], "agent_builder", "{resolved}");
    assert_eq!(resolved["resolved_by"], "agent_mux", "{resolved}");
    assert!(resolved["resolved_at"].is_string(), "{resolved}");
    let snapshot = snapshot_of(&mut page, &channel);
    assert_eq!(snapshot["threads"], json!([resolved]), "{snapshot}");

    // A new reply reopens the thread; the stored resolution stays on the root.
    let second = page.sent(&channel, "second", Some(&first_id), None);
    let reopened = thread_of(&mut page, &channel, &root_id);
    assert_eq!(reopened["status"], "open", "{reopened}");
    assert_eq!(reopened["last_reply_seq"], second["seq"], "{reopened}");
    assert!(reopened.get("resolved_by").is_none(), "{reopened}");
    assert_eq!(reopened["title"], "Ship 1.0", "{reopened}");

    // Resolve again, then reopen explicitly: the resolution is cleared.
    let resolve = json!({"root": root_id, "status": "resolved"});
    page.request("conversation-op", update(&channel, "t2", resolve));
    assert_eq!(updated_event(&mut page, &root_id)["thread"]["resolved"]["by"], "user_local");
    assert_eq!(thread_of(&mut page, &channel, &root_id)["status"], "resolved");
    let reopen = json!({"root": root_id, "status": "open"});
    page.request("conversation-op", update(&channel, "t3", reopen));
    let event = updated_event(&mut page, &root_id);
    assert!(event["thread"].get("resolved").is_none(), "{event}");
    assert_eq!(thread_of(&mut page, &channel, &root_id)["status"], "open");

    // Refusals: a thread reply as root, an unknown root, nothing to set, an
    // owner who is not a participant, a too-long title.
    let cases = [
        (json!({"root": first_id, "title": "x"}), "invalid_thread_root"),
        (json!({"root": "msg_00000000000000000000000000", "title": "x"}), "unknown_message"),
        (json!({"root": root_id}), "invalid_thread_update"),
        (json!({"root": root_id, "owner": "user_nobody"}), "invalid_thread_owner"),
        (json!({"root": root_id, "title": "x".repeat(201)}), "invalid_title"),
    ];
    for (index, (op, code)) in cases.into_iter().enumerate() {
        let reply = page.reply("conversation-op", update(&channel, &format!("bad-{index}"), op));
        rejected(&reply, code);
    }

    // Empty title and owner clear them: the root carries no thread object.
    page.request(
        "conversation-op",
        update(&channel, "t4", json!({"root": root_id, "title": "", "owner": ""})),
    );
    let event = updated_event(&mut page, &root_id);
    assert!(event.get("thread").is_none(), "{event}");

    // A message with no replies becomes a titled thread and is listed.
    let plain = page.sent(&channel, "plain", None, None);
    let plain_id = plain["id"].as_str().unwrap().to_owned();
    let later = json!({"root": plain_id, "title": "Later"});
    page.request("conversation-op", update(&channel, "t5", later));
    updated_event(&mut page, &plain_id);
    let snapshot = snapshot_of(&mut page, &channel);
    let listed: Vec<&Value> = snapshot["threads"].as_array().unwrap().iter().collect();
    assert!(
        listed.iter().any(|t| t["root"] == json!(plain_id)
            && t["reply_count"] == 0
            && t["title"] == "Later"),
        "{snapshot}"
    );
}

/// A create that reuses its idempotency key with another request is
/// refused (`idempotency_conflict`). The refusal names the conversation the
/// key made (`error_details.conversation`) to a creator that takes part in
/// it: a Chief whose grown DM was also retitled finds its DM again (hq-6d
/// 2026-10-14). An actor outside that conversation gets the plain refusal,
/// so a key never discloses a conversation to someone not in it. (A remote
/// client never reaches the store: the remote relay's command gate refuses
/// `conversation-create`, and the daemon strips error_details from every
/// remote reply.)
#[test]
fn an_idempotency_conflict_names_the_keyed_conversation_only_to_a_participant() {
    let server = HeadlessServer::start("conversation-create-conflict");
    let mut home = Unix::open(&server.socket);
    let token = |home: &mut Unix, participant: &str| {
        home.request("conversation-agent-token", json!({"participant": participant}))["token"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let bound = |participant: &str, token: String| {
        let mut connection = Unix::open(&server.socket);
        connection
            .request("conversation-bind", json!({"participant": participant, "token": token}));
        connection
    };
    let dm = |title: &str| {
        json!({"idempotency_key": "chief-dm-conflict", "title": title, "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Tester"},
            {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"}]})
    };
    let chief_token = token(&mut home, "agent_mux");
    let mut chief = bound("agent_mux", chief_token);
    let created = chief.request("conversation-create", dm("Chief"));
    let keyed = created["conversation"]["id"].as_str().unwrap().to_owned();

    // The creator, a participant: the refusal names its conversation.
    let conflict = chief.reply("conversation-create", dm("Chief, renamed"));
    rejected(&conflict, "idempotency_conflict");
    assert_eq!(conflict["reason"], "idempotency_conflict", "{conflict}");
    assert_eq!(conflict["error_details"]["conversation"], keyed.as_str(), "{conflict}");

    // An agent outside the conversation, with the same key: refused, no id.
    let outsider_token = token(&mut home, "agent_outsider");
    let mut outsider = bound("agent_outsider", outsider_token);
    let conflict = outsider.reply("conversation-create", dm("Chief"));
    rejected(&conflict, "idempotency_conflict");
    assert_eq!(conflict["reason"], "idempotency_conflict", "{conflict}");
    assert!(
        conflict.get("error_details").is_none(),
        "an outsider learned the keyed conversation: {conflict}"
    );
    assert!(!conflict.to_string().contains(&keyed), "{conflict}");
}
