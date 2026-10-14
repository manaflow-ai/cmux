//! Threads and the sender's read cursor on the local conversation owner,
//! over a real headless daemon socket (cx-59n8.2): a thread reply carries
//! `thread_root` in its event, in history and in the snapshot; a reply into
//! a reply is refused; and a send moves only the sender's own read cursor,
//! so no client counts its own messages as unread, and only when the sender
//! had read everything before it (cx-59n8.4): a sender behind keeps its
//! cursor, so a message it has not read stays unread to it.

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

fn send(
    conn: &mut Conn,
    conversation: &str,
    key: &str,
    text: &str,
    thread_root: Option<&str>,
) -> Value {
    let mut op = json!({"kind": "message.send", "client_msg_id": key,
                        "parts": [{"type": "text", "text": text}]});
    if let Some(root) = thread_root {
        op["thread_root"] = json!(root);
    }
    conn.reply(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": key, "op": op}),
    )
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
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
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

    // B reads the root, then replies in the thread: the event carries thread_root.
    let read = agent.reply(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": "read-1",
               "op": {"kind": "read_cursor.set", "seq": 1}}),
    );
    assert_eq!(read["ok"], true, "{read}");
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
    let unknown =
        send(&mut home, &conversation, "unknown-1", "lost", Some("msg_00000000000000000000000000"));
    assert_eq!(unknown["ok"], false, "{unknown}");
    assert!(unknown.to_string().contains("invalid_thread_root"), "{unknown}");

    // History and snapshot read thread_root back from the store.
    let history = home.request(
        "conversation-history",
        json!({"conversation": conversation, "before_seq": 100, "limit": 10}),
    );
    let snapshot =
        home.request("conversation-snapshot", json!({"conversation": conversation, "tail": 10}));
    for messages in [&history["messages"], &snapshot["messages"]] {
        let messages = messages.as_array().unwrap();
        assert_eq!(messages.len(), 2, "{messages:?}");
        assert!(messages[0].get("thread_root").is_none(), "{:?}", messages[0]);
        assert_eq!(messages[1]["thread_root"], json!(root_id), "{:?}", messages[1]);
    }

    // A is behind (B's reply is unread to A): A's send keeps A's cursor, so
    // B's reply stays unread to A.
    let behind = send(&mut home, &conversation, "behind-1", "late", None);
    assert_eq!(behind["ok"], true, "{behind}");
    home.message_event();
    assert_eq!(
        unread(&mut home, &conversation, "user_local"),
        2,
        "a sender behind keeps its cursor"
    );
}

/// Creates a conversation of the local user and agent_mux; returns its id.
fn create(home: &mut Conn, key: &str) -> String {
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": key, "actor": "user_local", "title": key,
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]}),
    );
    created["conversation"]["id"].as_str().unwrap().to_owned()
}

/// Sends as the agent (when given) or the local user, and returns the
/// committed message from the subscribed `home` connection's event.
fn sent(
    home: &mut Conn,
    agent: Option<&mut Conn>,
    conversation: &str,
    key: &str,
    root: Option<&str>,
) -> Value {
    let reply = match agent {
        Some(agent) => send(agent, conversation, key, key, root),
        None => send(home, conversation, key, key, root),
    };
    assert_eq!(reply["ok"], true, "{reply}");
    home.message_event()
}

fn ids(messages: &Value) -> Vec<String> {
    messages.as_array().unwrap().iter().map(|m| m["id"].as_str().unwrap().to_owned()).collect()
}

/// The owner read `conversation-thread` (cx-59n8.6): the root, its replies
/// ascending and paged, and the thread summary; snapshot and history carry
/// `threads` for the roots in their page, so a client counts replies of an
/// old thread without loading them.
#[test]
fn conversation_thread_reads_the_whole_thread_and_pages_carry_root_stats() {
    let server = HeadlessServer::start("conversation-thread-read");
    let mut home = Conn::open(&server.socket);
    let identity = home.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "conversation-thread-v1"), "{identity}");
    let conversation = create(&mut home, "thread-read");
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Conn::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    home.request("subscribe", json!({}));

    // seq 1 root, seq 2 a plain message, seq 3-5 three replies (two authors).
    let root = sent(&mut home, None, &conversation, "root", None);
    let root_id = root["id"].as_str().unwrap().to_owned();
    let plain = sent(&mut home, None, &conversation, "plain", None);
    let plain_id = plain["id"].as_str().unwrap().to_owned();
    let r1 = sent(&mut home, None, &conversation, "r1", Some(&root_id));
    let r2 = sent(&mut home, Some(&mut agent), &conversation, "r2", Some(&root_id));
    let r3 = sent(&mut home, None, &conversation, "r3", Some(&root_id));
    let summary = json!({"root": root_id, "reply_count": 3, "last_reply_seq": r3["seq"],
                         "last_reply_at": r3["created_at"], "authors": ["user_local", "agent_mux"],
                         "status": "open"});

    // The first page: the root, two replies ascending, more to come.
    let page = home.request(
        "conversation-thread",
        json!({"conversation": conversation, "root": root_id, "limit": 2}),
    );
    assert_eq!(page["root"]["id"], json!(root_id), "{page}");
    assert_eq!(ids(&page["replies"]), vec![r1["id"].as_str().unwrap(), r2["id"].as_str().unwrap()]);
    assert_eq!(page["has_more"], true, "{page}");
    assert_eq!(page["thread"], summary, "{page}");
    // The next page starts after the last reply read.
    let next = home.request(
        "conversation-thread",
        json!({"conversation": conversation, "root": root_id, "after_seq": r2["seq"], "limit": 2}),
    );
    assert_eq!(ids(&next["replies"]), vec![r3["id"].as_str().unwrap()]);
    assert_eq!(next["has_more"], false, "{next}");
    // A message with no replies is a root with an empty thread.
    let empty = home
        .request("conversation-thread", json!({"conversation": conversation, "root": plain_id}));
    assert_eq!(ids(&empty["replies"]), Vec::<String>::new());
    assert_eq!(
        empty["thread"],
        json!({"root": plain_id, "reply_count": 0, "last_reply_seq": null,
               "last_reply_at": null, "authors": [], "status": "open"})
    );

    // Snapshot and history carry the stats of the roots in their page only.
    let snapshot =
        home.request("conversation-snapshot", json!({"conversation": conversation, "tail": 10}));
    assert_eq!(snapshot["threads"], json!([summary]), "{snapshot}");
    let history = home.request(
        "conversation-history",
        json!({"conversation": conversation, "before_seq": 3, "limit": 2}),
    );
    assert_eq!(history["threads"], json!([summary]), "{history}");
    let replies_only = home.request(
        "conversation-history",
        json!({"conversation": conversation, "before_seq": 100, "limit": 1}),
    );
    assert_eq!(replies_only["threads"], json!([]), "{replies_only}");

    // A reply, an unknown id and a root of another conversation are not roots here.
    let other = create(&mut home, "thread-other");
    let foreign = sent(&mut home, None, &other, "foreign", None);
    for root in [
        r1["id"].as_str().unwrap(),
        "msg_00000000000000000000000000",
        foreign["id"].as_str().unwrap(),
    ] {
        let refused =
            home.reply("conversation-thread", json!({"conversation": conversation, "root": root}));
        assert_eq!(refused["ok"], false, "{root}: {refused}");
        assert!(refused.to_string().contains("unknown_message"), "{root}: {refused}");
    }
}

/// Retracts `message` as the author on `conn`; the subscribed `home`
/// connection sees the change.
fn retract(conn: &mut Conn, conversation: &str, key: &str, message: &Value) {
    let reply = conn.reply(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": key,
               "op": {"kind": "message.retract", "message_id": message["id"]}}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
}

/// A retracted reply stays in the thread read (the panel shows "message
/// deleted") but not in the stats (cx-59n8.9): reply_count, the last reply
/// and the authors count only replies that are not retracted, the same on
/// the cloud owner.
#[test]
fn a_retracted_reply_stays_in_the_thread_but_not_in_the_stats() {
    let server = HeadlessServer::start("conversation-thread-retract");
    let mut home = Conn::open(&server.socket);
    let conversation = create(&mut home, "thread-retract");
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Conn::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    home.request("subscribe", json!({}));

    let root = sent(&mut home, None, &conversation, "root", None);
    let root_id = root["id"].as_str().unwrap().to_owned();
    let r1 = sent(&mut home, None, &conversation, "r1", Some(&root_id));
    let r2 = sent(&mut home, Some(&mut agent), &conversation, "r2", Some(&root_id));
    let r3 = sent(&mut home, None, &conversation, "r3", Some(&root_id));
    let all = vec![
        r1["id"].as_str().unwrap().to_owned(),
        r2["id"].as_str().unwrap().to_owned(),
        r3["id"].as_str().unwrap().to_owned(),
    ];
    let thread = |home: &mut Conn| {
        home.request("conversation-thread", json!({"conversation": conversation, "root": root_id}))
    };
    let stats = |home: &mut Conn| {
        let snapshot = home
            .request("conversation-snapshot", json!({"conversation": conversation, "tail": 10}));
        let history = home.request(
            "conversation-history",
            json!({"conversation": conversation, "before_seq": 100, "limit": 10}),
        );
        (snapshot["threads"].clone(), history["threads"].clone())
    };

    // A middle reply retracted: its author leaves the authors, the count
    // drops, the last reply stays.
    retract(&mut agent, &conversation, "retract-r2", &r2);
    let middle = json!({"root": root_id, "reply_count": 2, "last_reply_seq": r3["seq"],
                        "last_reply_at": r3["created_at"], "authors": ["user_local"],
                        "status": "open"});
    let page = thread(&mut home);
    assert_eq!(ids(&page["replies"]), all, "{page}");
    assert!(page["replies"][1]["retracted_at"].is_string(), "{page}");
    assert_eq!(page["thread"], middle, "{page}");
    assert_eq!(stats(&mut home), (json!([middle]), json!([middle])));

    // The last reply retracted: the last reply is the newest one that is
    // not retracted.
    retract(&mut home, &conversation, "retract-r3", &r3);
    let last = json!({"root": root_id, "reply_count": 1, "last_reply_seq": r1["seq"],
                      "last_reply_at": r1["created_at"], "authors": ["user_local"],
                      "status": "open"});
    assert_eq!(thread(&mut home)["thread"], last);
    assert_eq!(stats(&mut home), (json!([last]), json!([last])));

    // Every reply retracted: no stats entry, an empty summary on the read.
    retract(&mut home, &conversation, "retract-r1", &r1);
    let none = thread(&mut home);
    assert_eq!(ids(&none["replies"]), all, "{none}");
    assert_eq!(
        none["thread"],
        json!({"root": root_id, "reply_count": 0, "last_reply_seq": null,
               "last_reply_at": null, "authors": [], "status": "open"})
    );
    assert_eq!(stats(&mut home), (json!([]), json!([])));
}
