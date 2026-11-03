//! The Home list rows (`home-inbox-v1`) over a real headless daemon's
//! WebSocket (the Channels page path; the native Messages view reads the same
//! command on the Unix socket): a Chief's direct conversation shows the Chief's
//! current registry name and its live state, a direct conversation and a
//! later titled one with the same participant are `direct` and `channel`,
//! unread counts follow the read cursor and the person's own last message, the
//! person's pins come first and a marked conversation says so.

use std::io::{BufRead, BufReader};

use serde_json::{Value, json};

use super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

fn person() -> Value {
    json!({"id": "user_local", "kind": "human", "display_name": "Tester"})
}

fn create(page: &mut Ws, key: &str, title: &str, others: Value) -> String {
    let mut participants = vec![person()];
    participants.extend(others.as_array().unwrap().iter().cloned());
    page.request(
        "conversation-create",
        json!({"idempotency_key": key, "title": title, "participants": participants}),
    )["conversation"]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn row(inbox: &Value, id: &str) -> Value {
    inbox["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == id)
        .unwrap_or_else(|| panic!("{id} has no row: {inbox}"))
        .clone()
}

fn order(inbox: &Value) -> Vec<String> {
    inbox["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap().to_owned())
        .collect()
}

/// A JSON-lines client of the daemon's Unix socket.
struct Unix {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    next: u64,
}

impl Unix {
    fn open(socket: &std::path::Path) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { reader: BufReader::new(stream), writer, next: 1 }
    }

    /// One `cmux.protocol/2` mutation; its result.
    fn v2(&mut self, operation: &str, params: Value, key: &str) -> Value {
        let id = format!("home-inbox-{}", self.next);
        self.next += 1;
        let mut params = params.as_object().cloned().unwrap_or_default();
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        let frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                           "operation": operation, "params": params, "idempotency_key": key});
        writeln!(self.writer, "{frame}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the connection");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == json!(id) && value["type"] == "response" {
                assert_eq!(value["ok"], true, "{operation}: {value}");
                return value["result"].clone();
            }
        }
    }

    fn request(&mut self, cmd: &str, params: Value) -> Value {
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
                assert_eq!(value["ok"], true, "{cmd} failed: {value}");
                return value["data"].clone();
            }
        }
    }
}

#[test]
fn home_inbox_rows_show_kinds_names_unread_chief_state_and_my_pins_in_list_order() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("home-inbox", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|value| value == "home-inbox-v1"),
        "{identity}"
    );
    page.request("subscribe", json!({}));

    let mux =
        json!({"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"});
    let builder = json!({"id": "agent_builder", "kind": "agent", "display_name": "Builder"});
    let docs = json!({"id": "agent_docs", "kind": "agent", "display_name": "Docs"});
    // Made in this order (created_at ascending).
    let chief = create(&mut page, "inbox-chief", "Chief", json!([mux]));
    let direct = create(&mut page, "inbox-direct", "Builder", json!([builder]));
    let room = create(&mut page, "inbox-room", "builder room", json!([builder]));
    let release = create(&mut page, "inbox-release", "release", json!([mux, builder, docs]));

    // The person renames the Chief (its registry record): the row follows.
    let mut home = Unix::open(&server.socket);
    home.v2(
        "chief.profile.update",
        json!({"chief": "agent_mux", "display_name": "Release Chief"}),
        "rename-chief",
    );

    // The Chief writes in its direct conversation on its own bound connection.
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Unix::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    // It types first: it works. Its posted message ends its typing.
    agent.request("conversation-typing", json!({"conversation": chief, "on": true}));
    let typing = page.request("home-inbox", json!({}));
    assert_eq!(row(&typing, &chief)["chief_state"], "working", "{typing}");
    agent.request(
        "conversation-op",
        json!({"conversation": chief, "idempotency_key": "chief-1", "op": {
            "kind": "message.send", "client_msg_id": "chief-1",
            "parts": [{"type": "text", "text": "Release notes are ready for review."}]}}),
    );
    // The person writes last in release: nothing unread there.
    page.sent(&release, "release-1", None, None);

    let inbox = page.request("home-inbox", json!({}));
    assert_eq!(inbox["me"], "user_local", "{inbox}");
    let chief_row = row(&inbox, &chief);
    assert_eq!(chief_row["kind"], "chief", "{chief_row}");
    assert_eq!(chief_row["name"], "Release Chief", "{chief_row}");
    assert_eq!(chief_row["chief"], "agent_mux", "{chief_row}");
    assert_eq!(chief_row["chief_state"], "idle", "{chief_row}");
    assert_eq!(chief_row["unread"], 1, "{chief_row}");
    assert_eq!(chief_row["preview"], "Release notes are ready for review.", "{chief_row}");
    assert_eq!(chief_row["last_author"], "agent_mux", "{chief_row}");
    // Of two conversations with the same one participant, the older (by
    // created_at, then id: both may be made in one millisecond here) is the
    // direct one and the later titled one is a channel.
    let list = page.request("conversation-list", json!({}));
    let made = |id: &str| {
        let summary =
            list["conversations"].as_array().unwrap().iter().find(|c| c["id"] == id).unwrap();
        (summary["created_at"].as_str().unwrap().to_owned(), id.to_owned())
    };
    let (direct, room) = if made(&direct) <= made(&room) { (direct, room) } else { (room, direct) };
    assert_eq!(row(&inbox, &direct)["kind"], "direct", "{inbox}");
    assert!(row(&inbox, &direct).get("chief_state").is_none(), "{inbox}");
    assert_eq!(row(&inbox, &room)["kind"], "channel", "{inbox}");
    // A direct row's name is its title.
    assert!(
        ["Builder", "builder room"].contains(&row(&inbox, &direct)["name"].as_str().unwrap()),
        "{inbox}"
    );
    let release_row = row(&inbox, &release);
    assert_eq!(release_row["kind"], "channel", "{release_row}");
    assert_eq!(release_row["unread"], 0, "{release_row}");
    // Newest activity first (ties by id: messages may share a millisecond
    // here): the two conversations with a message, then the others.
    let ids = order(&inbox);
    let mut newest = vec![release.clone(), chief.clone()];
    newest.sort_by(|a, b| {
        let at = |id: &str| row(&inbox, id)["activity_at"].as_str().unwrap().to_owned();
        at(b).cmp(&at(a)).then_with(|| a.cmp(b))
    });
    assert_eq!(&ids[..2], newest.as_slice(), "{inbox}");

    // The Chief types: it works now.
    agent.request("conversation-typing", json!({"conversation": chief, "on": true}));
    let typing = page.request("home-inbox", json!({}));
    assert_eq!(row(&typing, &chief)["chief_state"], "working", "{typing}");
    agent.request("conversation-typing", json!({"conversation": chief, "on": false}));

    // A run of the Chief's that runs is work too; it ends, and the Chief idles.
    let turn = "turn:home-inbox:1";
    agent.request(
        "conversation-run-append",
        json!({"conversation": chief, "run": {"id": turn, "turn": turn, "status": "running"},
               "steps": []}),
    );
    let running = page.request("home-inbox", json!({}));
    assert_eq!(row(&running, &chief)["chief_state"], "working", "{running}");
    agent.request(
        "conversation-run-append",
        json!({"conversation": chief, "run": {"id": turn, "status": "done"}, "steps": []}),
    );
    let done = page.request("home-inbox", json!({}));
    assert_eq!(row(&done, &chief)["chief_state"], "idle", "{done}");

    // My pins come first in my order; a marked conversation says so.
    page.request(
        "conversation-inbox-op",
        json!({"conversation": room, "op": {"kind": "inbox.pin", "pinned": true, "position": 2}}),
    );
    page.request(
        "conversation-inbox-op",
        json!({"conversation": direct, "op": {"kind": "inbox.pin", "pinned": true, "position": 1}}),
    );
    page.request(
        "conversation-inbox-op",
        json!({"conversation": release, "op": {"kind": "inbox.mark_unread", "unread": true}}),
    );
    let pinned = page.request("home-inbox", json!({}));
    assert_eq!(&order(&pinned)[..2], &[direct.clone(), room], "{pinned}");
    assert_eq!(&order(&pinned)[2..4], newest.as_slice(), "{pinned}");
    assert_eq!(row(&pinned, &direct)["pinned"], true, "{pinned}");
    assert_eq!(row(&pinned, &direct)["pin_position"], 1, "{pinned}");
    assert_eq!(row(&pinned, &release)["marked_unread"], true, "{pinned}");
    assert_eq!(row(&pinned, &chief)["pinned"], false, "{pinned}");
    assert_eq!(row(&pinned, &chief)["chief_state"], "idle", "{pinned}");

    // The same rows on the Unix socket (the native view's path).
    let native = home.request("home-inbox", json!({}));
    assert_eq!(native["rows"], pinned["rows"], "{native}");
}

/// Delete Chief on one device removes the Chief's row from every other
/// device's Home (the phone reads this same `home-inbox` over its link): the
/// owner drops a deleted Chief's conversation from the rows, tells each
/// connected view with `conversation-inbox-changed` (the one event the
/// phone's link forwards), and a device that connects later never gets the
/// row back. Its conversation itself stays (`conversation-list`).
#[test]
fn a_deleted_chief_leaves_every_devices_home_list_including_one_offline_then() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("home-inbox-deleted-chief", Some(&config));
    let mut home = Unix::open(&server.socket);
    let made = home.v2("chief.profile.create", json!({"display_name": "Codex Chief"}), "make");
    let id = made["value"]["id"].as_str().unwrap().to_owned();
    let other = home.v2("chief.profile.create", json!({"display_name": "Kept"}), "make-kept");
    let kept_id = other["value"]["id"].as_str().unwrap().to_owned();

    // The other device (a phone's link, a page) watches the list.
    let mut phone = Ws::open(&ws_addr(&server));
    phone.request("subscribe", json!({}));
    let chief = create(
        &mut phone,
        "deleted-chief-dm",
        "Codex Chief",
        json!([{"id": id, "kind": "agent", "display_name": "Codex Chief", "agent_class": "mux"}]),
    );
    let kept = create(
        &mut phone,
        "kept-chief-dm",
        "Kept",
        json!([{"id": kept_id, "kind": "agent", "display_name": "Kept", "agent_class": "mux"}]),
    );
    // A later titled conversation with the same Chief is a channel: it keeps its history.
    let channel = create(
        &mut phone,
        "deleted-chief-channel",
        "release notes",
        json!([{"id": id, "kind": "agent", "display_name": "Codex Chief", "agent_class": "mux"}]),
    );
    // The older one (by created_at, then id: both may be made in one millisecond) is the direct one.
    let list = phone.request("conversation-list", json!({}));
    let made = |c: &str| {
        let summary =
            list["conversations"].as_array().unwrap().iter().find(|s| s["id"] == c).unwrap();
        (summary["created_at"].as_str().unwrap().to_owned(), c.to_owned())
    };
    let (chief, channel) =
        if made(&chief) <= made(&channel) { (chief, channel) } else { (channel, chief) };
    phone.sent(&chief, "before-delete", None, None);
    let before = phone.request("home-inbox", json!({"owners": ["local"]}));
    assert_eq!(row(&before, &chief)["kind"], "chief", "{before}");

    home.v2("chief.profile.delete", json!({"chief": id}), "delete");

    // The watching device is told its list changed for that conversation.
    loop {
        let event = phone.events.pop_front().unwrap_or_else(|| phone.read());
        if event["event"] == "conversation-inbox-changed" && event["conversation"] == chief {
            assert_eq!(event["participant"], "user_local", "{event}");
            break;
        }
    }
    let after = phone.request("home-inbox", json!({"owners": ["local"]}));
    assert!(!order(&after).contains(&chief), "a deleted Chief keeps its row: {after}");
    assert_eq!(row(&after, &kept)["kind"], "chief", "{after}");
    assert_eq!(row(&after, &channel)["kind"], "channel", "{after}");

    // A device that was offline at the time reads the list without it.
    let mut later = Ws::open(&ws_addr(&server));
    let fresh = later.request("home-inbox", json!({"owners": ["local"]}));
    assert!(!order(&fresh).contains(&chief), "{fresh}");
    let native = home.request("home-inbox", json!({}));
    assert!(!order(&native).contains(&chief), "{native}");
    // The conversation is kept; only the list leaves it out.
    let list = later.request("conversation-list", json!({}));
    assert!(list["conversations"].as_array().unwrap().iter().any(|c| c["id"] == chief), "{list}");
}
