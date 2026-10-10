//! Threads and the sender's read cursor on the local conversation owner,
//! over a real headless daemon socket (cx-59n8.2): a thread reply carries
//! `thread_root` in its event, in history and in the snapshot; a reply into
//! a reply is refused; and a send moves only the sender's own read cursor,
//! so no client counts its own messages as unread.

use super::*;
use serde_json::{Value, json};

/// A JSON-lines client of the daemon; events read while waiting for an
/// answer are kept in `events`.
struct Conn {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    next: u64,
    events: VecDeque<Value>,
}

impl Conn {
    fn open(socket: &std::path::Path) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { reader: BufReader::new(stream), writer, next: 1, events: VecDeque::new() }
    }

    /// The whole reply, `ok` true or false.
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
            if value.get("event").is_some() {
                self.events.push_back(value);
                continue;
            }
            if value["id"] == id {
                return value;
            }
        }
    }

    fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed: {value}");
        value["data"].clone()
    }

    /// The next `conversation-changed` message event.
    fn message_event(&mut self) -> Value {
        loop {
            let event = match self.events.pop_front() {
                Some(event) => event,
                None => {
                    let mut line = String::new();
                    assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed");
                    serde_json::from_str(&line).unwrap()
                }
            };
            if event["event"] == "conversation-changed" && event["change"]["kind"] == "message" {
                return event["change"]["message"].clone();
            }
        }
    }
}

fn send(conn: &mut Conn, conversation: &str, key: &str, text: &str, thread_root: Option<&str>) -> Value {
    let mut op = json!({"kind": "message.send", "client_msg_id": key,
                        "parts": [{"type": "text", "text": text}]});
    if let Some(root) = thread_root {
        op["thread_root"] = json!(root);
    }
    conn.reply("conversation-op", json!({"conversation": conversation, "idempotency_key": key, "op": op}))
}

/// Unread messages of `participant`: last_seq minus its read cursor, as
/// every client computes it from the conversation list.
fn unread(home: &mut Conn, conversation: &str, participant: &str) -> u64 {
    let list = home.request("conversation-list", json!({}));
    let summary = list["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|summary| summary["id"] == conversation)
        .unwrap_or_else(|| panic!("{conversation} is not listed: {list}"))
        .clone();
    let last_seq = summary["last_seq"].as_u64().unwrap();
    last_seq - summary["read_cursors"][participant].as_u64().unwrap_or(0)
}

#[test]
fn thread_replies_carry_thread_root_and_a_send_reads_only_for_its_sender() {
    let server = HeadlessServer::start("conversation-threads");
    let mut home = Conn::open(&server.socket);
    // Clients find the behavior by this capability (an older daemon lacks it).
    let identity = home.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "conversation-threads-v1"), "{identity}");
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": "threads-test", "actor": "user_local", "title": "Threads",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]}),
    );
    let conversation = created["conversation"]["id"].as_str().unwrap().to_owned();
    let token = home.request("conversation-agent-token", json!({"participant": "agent_mux"}))
        ["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut agent = Conn::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    home.request("subscribe", json!({}));

    // A (user_local) sends the root: A has read it, B (agent_mux) has not.
    let root = send(&mut home, &conversation, "root-1", "root", None);
    assert_eq!(root["ok"], true, "{root}");
    let root_event = home.message_event();
    let root_id = root_event["id"].as_str().unwrap().to_owned();
    assert!(root_event.get("thread_root").is_none(), "{root_event}");
    assert_eq!(unread(&mut home, &conversation, "user_local"), 0, "my own message is unread");
    assert_eq!(unread(&mut home, &conversation, "agent_mux"), 1);

    // B replies in the thread: the event carries thread_root.
    let reply = send(&mut agent, &conversation, "reply-1", "in thread", Some(&root_id));
    assert_eq!(reply["ok"], true, "{reply}");
    let reply_event = home.message_event();
    assert_eq!(reply_event["thread_root"], json!(root_id), "{reply_event}");
    let reply_id = reply_event["id"].as_str().unwrap().to_owned();
    assert_eq!(unread(&mut home, &conversation, "agent_mux"), 0, "the sender read through");
    assert_eq!(unread(&mut home, &conversation, "user_local"), 1);

    // A thread has one level: a reply into a reply is refused.
    let nested = send(&mut home, &conversation, "nested-1", "nested", Some(&reply_id));
    assert_eq!(nested["ok"], false, "{nested}");
    assert!(nested.to_string().contains("invalid_thread_root"), "{nested}");
    let unknown = send(&mut home, &conversation, "unknown-1", "lost", Some("msg_00000000000000000000000000"));
    assert_eq!(unknown["ok"], false, "{unknown}");
    assert!(unknown.to_string().contains("invalid_thread_root"), "{unknown}");

    // History and snapshot read thread_root back from the store.
    let history = home.request(
        "conversation-history",
        json!({"conversation": conversation, "before_seq": 100, "limit": 10}),
    );
    let snapshot = home.request("conversation-snapshot", json!({"conversation": conversation, "tail": 10}));
    for messages in [&history["messages"], &snapshot["messages"]] {
        let messages = messages.as_array().unwrap();
        assert_eq!(messages.len(), 2, "{messages:?}");
        assert!(messages[0].get("thread_root").is_none(), "{:?}", messages[0]);
        assert_eq!(messages[1]["thread_root"], json!(root_id), "{:?}", messages[1]);
    }
}
