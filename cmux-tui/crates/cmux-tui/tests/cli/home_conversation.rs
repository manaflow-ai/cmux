//! One conversation for both Home views (`home-conversation-v1`) over a real
//! headless daemon's WebSocket (the Channels page path; the Messages view
//! reads the same command on the Unix socket): each message's thread depth and
//! parent along `reply_to`, the thread summaries, and "Chiefs paused" where a
//! Chief wrote MAX_AGENT_TURNS (6) text messages in a row with no person.

use std::io::{BufRead, BufReader};

use serde_json::{Value, json};

use super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

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

    fn reply(&mut self, cmd: &str, params: Value) -> Value {
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

    fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed: {value}");
        value["data"].clone()
    }
}

fn find<'a>(window: &'a Value, id: &str) -> &'a Value {
    window["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|message| message["id"] == id)
        .unwrap_or_else(|| panic!("{id} is not in the window: {window}"))
}

#[test]
fn home_conversation_gives_thread_depths_and_where_chiefs_are_paused() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("home-conversation", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "home-conversation-v1"),
        "{identity}"
    );
    page.request("subscribe", json!({}));
    let channel = page.create_channel("home-conv", "release");

    // A thread with a reply of a reply.
    let root = page.sent(&channel, "root", None, None);
    let root_id = root["id"].as_str().unwrap().to_owned();
    let first = page.sent(&channel, "first", Some(&root_id), Some(&root_id));
    let first_id = first["id"].as_str().unwrap().to_owned();
    let nested = page.sent(&channel, "nested", Some(&first_id), None);
    let nested_id = nested["id"].as_str().unwrap().to_owned();
    let plain = page.sent(&channel, "plain", None, None);
    let plain_id = plain["id"].as_str().unwrap().to_owned();

    let window = page.request("home-conversation", json!({"conversation": channel}));
    assert_eq!(window["conversation"]["id"], channel.as_str(), "{window}");
    assert_eq!(find(&window, &root_id)["depth"], 0, "{window}");
    assert!(find(&window, &root_id).get("parent").is_none(), "{window}");
    assert_eq!(find(&window, &first_id)["depth"], 1, "{window}");
    assert_eq!(find(&window, &first_id)["parent"], root_id.as_str(), "{window}");
    assert_eq!(find(&window, &nested_id)["depth"], 2, "{window}");
    assert_eq!(find(&window, &nested_id)["parent"], first_id.as_str(), "{window}");
    assert_eq!(find(&window, &nested_id)["thread_root"], root_id.as_str(), "{window}");
    assert_eq!(find(&window, &plain_id)["depth"], 0, "{window}");
    let thread = window["threads"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["root"] == root_id.as_str())
        .cloned();
    assert_eq!(thread.unwrap_or_default()["reply_count"], 2, "{window}");
    assert_eq!(window["agents_paused"], json!({"main": false, "threads": []}), "{window}");
    assert_eq!(window["has_older"], false, "{window}");

    // An older page: the window before the plain message.
    let older = page.request(
        "home-conversation",
        json!({"conversation": channel, "before_seq": plain["seq"], "limit": 1}),
    );
    let older_messages = older["messages"].as_array().unwrap();
    assert_eq!(older_messages.len(), 1, "{older}");
    assert_eq!(older_messages[0]["id"], nested_id.as_str(), "{older}");
    // Its parent is outside this window: it counts as the root's direct reply.
    assert_eq!(older_messages[0]["depth"], 1, "{older}");
    assert_eq!(older["has_older"], true, "{older}");

    // The Chief (agent_mux) writes in the thread until its budget is spent.
    // The owner holds agent messages to a 2 s gap (`agent_rate`); like the
    // brain, the test retries under the same key.
    let mut home = Unix::open(&server.socket);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Unix::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    for turn in 0..6 {
        let key = format!("chief-{turn}");
        let params = json!({"conversation": channel, "idempotency_key": key, "op": {
            "kind": "message.send", "client_msg_id": key,
            "parts": [{"type": "text", "text": format!("update {turn}")}],
            "reply_to": {"message_id": root_id, "part_index": 0}, "thread_root": root_id}});
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let reply = agent.reply("conversation-op", params.clone());
            if reply["ok"] == true {
                break;
            }
            assert!(
                reply.to_string().contains("agent_rate") && Instant::now() < deadline,
                "chief send {turn}: {reply}"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    let paused = home.request("home-conversation", json!({"conversation": channel}));
    assert_eq!(paused["agents_paused"]["threads"], json!([root_id]), "{paused}");
    assert_eq!(paused["agents_paused"]["main"], false, "{paused}");

    // A person's reply in the thread resets it: the Chiefs may talk again.
    page.sent(&channel, "person", Some(&root_id), Some(&root_id));
    let resumed = page.request("home-conversation", json!({"conversation": channel}));
    assert_eq!(resumed["agents_paused"], json!({"main": false, "threads": []}), "{resumed}");

    // The main timeline: six Chief texts in a row (imported history) pause it.
    let other = page.create_channel("home-conv-main", "ops");
    let messages: Vec<Value> = (0..6)
        .map(|turn| {
            json!({"client_msg_id": format!("m{turn}"), "author": "agent_mux",
                   "created_at": format!("2026-01-01T00:00:0{turn}.000Z"),
                   "parts": [{"type": "text", "text": format!("note {turn}")}]})
        })
        .collect();
    home.request("conversation-import", json!({"conversation": other, "messages": messages}));
    let main = page.request("home-conversation", json!({"conversation": other}));
    assert_eq!(main["agents_paused"], json!({"main": true, "threads": []}), "{main}");
    page.sent(&other, "person-main", None, None);
    let main_resumed = page.request("home-conversation", json!({"conversation": other}));
    assert_eq!(main_resumed["agents_paused"]["main"], false, "{main_resumed}");
}
