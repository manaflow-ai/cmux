//! Channels, nested threads and permalinks on the local conversation owner
//! (`conversation-tree-v1`), over a real headless daemon's WebSocket, the
//! path every page (the Channels page, a plain browser) and the Messages
//! Home share: a page creates a channel, replies to a reply to any depth
//! (each reply keeps the top `thread_root`; `reply_to` is its parent), and
//! opens a message from its `cmux://conversation/<id>/message/<id>` link with
//! the path from the thread root down to it.

use std::net::TcpStream;

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, WebSocket};

use super::*;

pub(super) const TOKEN: &str = "conversation-tree-test-credential";

pub(super) struct Ws {
    socket: WebSocket<TcpStream>,
    next: u64,
    pub(super) events: VecDeque<Value>,
}

impl Ws {
    pub(super) fn open(addr: &str) -> Self {
        let stream = TcpStream::connect(addr).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let (mut socket, _) = tungstenite::client(format!("ws://{addr}/"), stream).unwrap();
        socket.send(Message::Text(json!({"auth": {"token": TOKEN}}).to_string().into())).unwrap();
        Self { socket, next: 1, events: VecDeque::new() }
    }

    pub(super) fn read(&mut self) -> Value {
        loop {
            match self.socket.read().unwrap() {
                Message::Text(text) => return serde_json::from_str(&text).unwrap(),
                Message::Close(frame) => panic!("daemon closed the WebSocket: {frame:?}"),
                _ => continue,
            }
        }
    }

    /// The whole reply, `ok` true or false; events read meanwhile are kept.
    pub(super) fn reply(&mut self, cmd: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = params.as_object().cloned().unwrap_or_default();
        body.insert("id".into(), json!(id));
        body.insert("cmd".into(), json!(cmd));
        self.socket.send(Message::Text(Value::Object(body).to_string().into())).unwrap();
        loop {
            let value = self.read();
            if value.get("event").is_some() {
                self.events.push_back(value);
                continue;
            }
            if value["id"] == id {
                return value;
            }
        }
    }

    /// One `cmux.protocol/2` request on this WebSocket; the whole response
    /// (events read meanwhile are kept).
    pub(super) fn v2(&mut self, operation: &str, params: Value) -> Value {
        let id = format!("ws-v2-{}", self.next);
        self.next += 1;
        let mut params = params.as_object().cloned().unwrap_or_default();
        params.insert("machine".into(), json!("current"));
        params.insert("session".into(), json!("current"));
        let frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                           "operation": operation, "params": params});
        self.socket.send(Message::Text(frame.to_string().into())).unwrap();
        loop {
            let value = self.read();
            if value.get("event").is_some() {
                self.events.push_back(value);
                continue;
            }
            if value["id"] == json!(id) && value["type"] == "response" {
                return value;
            }
        }
    }

    pub(super) fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed over WebSocket: {value}");
        value["data"].clone()
    }

    /// The next `conversation-changed` message event.
    fn message_event(&mut self) -> Value {
        loop {
            let event = self.events.pop_front().unwrap_or_else(|| self.read());
            if event["event"] == "conversation-changed" && event["change"]["kind"] == "message" {
                return event["change"]["message"].clone();
            }
        }
    }

    /// Sends `text` in `conversation` with the optional parent and root;
    /// returns the whole reply.
    fn send(
        &mut self,
        conversation: &str,
        key: &str,
        text: &str,
        parent: Option<&str>,
        root: Option<&str>,
    ) -> Value {
        let mut op = json!({"kind": "message.send", "client_msg_id": key,
                            "parts": [{"type": "text", "text": text}]});
        if let Some(parent) = parent {
            op["reply_to"] = json!({"message_id": parent, "part_index": 0});
        }
        if let Some(root) = root {
            op["thread_root"] = json!(root);
        }
        self.reply(
            "conversation-op",
            json!({"conversation": conversation, "idempotency_key": key, "op": op}),
        )
    }

    /// Sends and returns the stored message from its event.
    pub(super) fn sent(
        &mut self,
        conversation: &str,
        key: &str,
        parent: Option<&str>,
        root: Option<&str>,
    ) -> Value {
        let reply = self.send(conversation, key, key, parent, root);
        assert_eq!(reply["ok"], true, "{key}: {reply}");
        // This send's own event (another message event may come first).
        loop {
            let message = self.message_event();
            if message["client_msg_id"] == key {
                return message;
            }
        }
    }

    pub(super) fn create_channel(&mut self, key: &str, title: &str) -> String {
        let created = self.request(
            "conversation-create",
            json!({"idempotency_key": key, "title": title, "participants": [
                {"id": "user_local", "kind": "human", "display_name": "Tester"},
                {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"},
                {"id": "agent_builder", "kind": "agent", "display_name": "Builder"}]}),
        );
        assert_eq!(created["conversation"]["title"], title, "{created}");
        created["conversation"]["id"].as_str().unwrap().to_owned()
    }
}

/// The address the daemon bound (`--ws` port 0), from its startup log.
pub(super) fn ws_addr(server: &HeadlessServer) -> String {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let tail = server.stderr_tail();
        if let Some(rest) = tail.split("WebSocket control at ws://").nth(1) {
            return rest.split_whitespace().next().unwrap().to_owned();
        }
        assert!(Instant::now() < deadline, "no WebSocket listener in the log: {tail}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn reason(reply: &Value) -> String {
    reply.to_string()
}

#[test]
fn a_page_creates_a_channel_nests_replies_without_limit_and_opens_message_links() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("conversation-tree", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "conversation-tree-v1"), "{identity}");
    page.request("subscribe", json!({}));

    // A new channel from the page, then a root and a first-level reply.
    let channel = page.create_channel("tree-channel", "release");
    let other = page.create_channel("tree-other", "design");
    let root = page.sent(&channel, "root", None, None);
    let root_id = root["id"].as_str().unwrap().to_owned();
    let first = page.sent(&channel, "first", Some(&root_id), Some(&root_id));
    let first_id = first["id"].as_str().unwrap().to_owned();
    assert_eq!(first["thread_root"], json!(root_id), "{first}");

    // A reply to the reply names only its parent: the owner keeps the top root.
    let second = page.sent(&channel, "second", Some(&first_id), None);
    let second_id = second["id"].as_str().unwrap().to_owned();
    assert_eq!(second["thread_root"], json!(root_id), "{second}");
    assert_eq!(second["reply_to"]["message_id"], json!(first_id), "{second}");
    // Deeper, with the root named too; and one more level.
    let third = page.sent(&channel, "third", Some(&second_id), Some(&root_id));
    let third_id = third["id"].as_str().unwrap().to_owned();
    assert_eq!(third["thread_root"], json!(root_id), "{third}");
    let fourth = page.sent(&channel, "fourth", Some(&third_id), None);
    let fourth_id = fourth["id"].as_str().unwrap().to_owned();
    assert_eq!(fourth["thread_root"], json!(root_id), "{fourth}");

    // A root that is not the parent's own is refused; so is a reply as root.
    let other_root = page.sent(&channel, "other-root", None, None);
    let other_root_id = other_root["id"].as_str().unwrap().to_owned();
    let wrong = page.send(&channel, "wrong", "wrong", Some(&second_id), Some(&other_root_id));
    assert_eq!(wrong["ok"], false, "{wrong}");
    assert!(reason(&wrong).contains("invalid_thread_root"), "{wrong}");
    let reply_root = page.send(&channel, "reply-root", "x", None, Some(&second_id));
    assert!(reason(&reply_root).contains("invalid_thread_root"), "{reply_root}");

    // The thread read holds every level, and the stats count them all.
    let thread =
        page.request("conversation-thread", json!({"conversation": channel, "root": root_id}));
    let replies: Vec<&str> =
        thread["replies"].as_array().unwrap().iter().map(|m| m["id"].as_str().unwrap()).collect();
    assert_eq!(
        replies,
        [first_id.as_str(), second_id.as_str(), third_id.as_str(), fourth_id.as_str()],
        "{thread}"
    );
    assert_eq!(thread["thread"]["reply_count"], 4, "{thread}");

    // A message link opens the message with its path from the thread root.
    let link = format!("cmux://conversation/{channel}/message/{fourth_id}");
    let resolved = page.request("conversation-link-resolve", json!({"url": link}));
    assert_eq!(resolved["url"], json!(link), "{resolved}");
    assert_eq!(resolved["conversation"]["id"], json!(channel), "{resolved}");
    assert_eq!(resolved["message"]["id"], json!(fourth_id), "{resolved}");
    assert_eq!(resolved["thread_root"], json!(root_id), "{resolved}");
    assert_eq!(
        resolved["path"],
        json!([root_id, first_id, second_id, third_id, fourth_id]),
        "{resolved}"
    );
    // A tagged build's scheme and a query work; a root is its own path.
    let tagged = page.request(
        "conversation-link-resolve",
        json!({"url": format!("cmux-dev-mytag://conversation/{channel}/message/{root_id}?machine=x")}),
    );
    assert_eq!(tagged["path"], json!([root_id]), "{tagged}");
    assert!(tagged.get("thread_root").is_none(), "{tagged}");
    assert_eq!(
        tagged["url"],
        json!(format!("cmux-dev-mytag://conversation/{channel}/message/{root_id}")),
        "{tagged}"
    );
    // A conversation link opens the conversation.
    let conversation = page.request(
        "conversation-link-resolve",
        json!({"url": format!("cmux://conversation/{channel}")}),
    );
    assert_eq!(conversation["conversation"]["title"], "release", "{conversation}");
    assert!(conversation.get("message").is_none(), "{conversation}");
    assert_eq!(conversation["path"], json!([]), "{conversation}");

    // A message of another conversation, an unknown conversation, and a
    // link of another kind are refused.
    let elsewhere = page.reply(
        "conversation-link-resolve",
        json!({"url": format!("cmux://conversation/{other}/message/{fourth_id}")}),
    );
    assert!(reason(&elsewhere).contains("unknown_message"), "{elsewhere}");
    let unknown = page.reply(
        "conversation-link-resolve",
        json!({"url": "cmux://conversation/conv_00000000000000000000000000"}),
    );
    assert!(reason(&unknown).contains("unknown_conversation"), "{unknown}");
    let slash = page.request(
        "conversation-link-resolve",
        json!({"url": format!("cmux://conversation/{channel}/message/{first_id}/")}),
    );
    assert_eq!(slash["path"], json!([root_id, first_id]), "{slash}");
    for url in [
        format!("cmux--x://conversation/{channel}"),
        format!("cmux-dev-://conversation/{channel}"),
        format!("https://example.com/conversation/{channel}"),
        format!("cmux://tab/{channel}"),
        format!("cmux://conversation/{channel}/message/{fourth_id}/extra"),
        "cmux://conversation/conv_bad/../x".to_owned(),
    ] {
        let refused = page.reply("conversation-link-resolve", json!({"url": url}));
        assert_eq!(refused["ok"], false, "{url}: {refused}");
    }
}
