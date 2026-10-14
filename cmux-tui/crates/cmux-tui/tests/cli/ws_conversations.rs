//! The local conversations on an authenticated WebSocket connection
//! (`ws-conversations-v1`, cmux#13742): a real headless daemon with its
//! WebSocket listener. A browser page (or any host) that presented the
//! daemon's credential reads and writes the person's conversations as
//! `user_local`, gets their events on `subscribe`, and still cannot act as
//! an agent (`conversation-agent-token` stays on the Unix socket).

use std::net::TcpStream;

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, WebSocket};

use super::*;

/// Attachments from a browser page over the same WebSocket (`ws-attachments-v1`).
#[path = "ws_attachments.rs"]
mod attachments;

/// Chiefs from the person's page over the same WebSocket (`chief-profile-ws-v1`).
#[path = "ws_chief_profiles.rs"]
mod chief_profiles;

pub(super) const TOKEN: &str = "ws-conversations-test-credential";

pub(super) struct Ws {
    socket: WebSocket<TcpStream>,
    next: u64,
    events: VecDeque<Value>,
}

impl Ws {
    pub(super) fn open(addr: &str) -> Self {
        let stream = TcpStream::connect(addr).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let (mut socket, _) = tungstenite::client(format!("ws://{addr}/"), stream).unwrap();
        socket.send(Message::Text(json!({"auth": {"token": TOKEN}}).to_string().into())).unwrap();
        Self { socket, next: 1, events: VecDeque::new() }
    }

    fn read(&mut self) -> Value {
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

    pub(super) fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed over WebSocket: {value}");
        value["data"].clone()
    }

    /// The next `conversation-changed` message event.
    pub(super) fn message_event(&mut self) -> Value {
        loop {
            let event = self.events.pop_front().unwrap_or_else(|| self.read());
            if event["event"] == "conversation-changed" && event["change"]["kind"] == "message" {
                return event["change"]["message"].clone();
            }
        }
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

#[test]
fn an_authenticated_websocket_client_reads_and_writes_the_persons_conversations() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("ws-conversations", Some(&config));
    let created = json_socket_request(
        &server.socket,
        json!({"id": 1, "cmd": "conversation-create", "idempotency_key": "ws-conv", "title": "WS",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]}),
    );
    let conversation = created["conversation"]["id"].as_str().unwrap().to_owned();

    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "ws-conversations-v1"), "{identity}");
    page.request("subscribe", json!({}));

    let list = page.request("conversation-list", json!({}));
    assert!(
        list["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|summary| summary["id"] == conversation),
        "{list}"
    );
    let snapshot =
        page.request("conversation-snapshot", json!({"conversation": conversation, "tail": 50}));
    assert_eq!(snapshot["conversation"]["title"], "WS", "{snapshot}");

    let sent = page.request(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": "ws-send-1",
               "op": {"kind": "message.send", "client_msg_id": "ws-send-1",
                      "parts": [{"type": "text", "text": "hello from a browser"}]}}),
    );
    assert_eq!(sent["seq"], 1, "{sent}");
    let event = page.message_event();
    assert_eq!(event["author"], "user_local", "{event}");
    assert_eq!(event["parts"][0]["text"], "hello from a browser", "{event}");

    // The owner stored it as the person's message: the Unix socket reads it back.
    let history = json_socket_request(
        &server.socket,
        json!({"id": 2, "cmd": "conversation-history", "conversation": conversation,
               "before_seq": 100, "limit": 10}),
    );
    let messages = history["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 1, "{history}");
    assert_eq!(messages[0]["author"], "user_local");
    assert_eq!(messages[0]["parts"][0]["text"], "hello from a browser");

    // The page is the person, never an agent.
    let token = page.reply("conversation-agent-token", json!({"participant": "agent_mux"}));
    assert_eq!(token["ok"], false, "{token}");
}

/// A browser page on another loopback origin (a dev server, the page host)
/// reaches the daemon only through `--ws-allow-origin`; the daemon must start
/// with that flag instead of routing the command line to the public CLI.
#[test]
fn a_headless_daemon_starts_with_an_allowed_browser_origin() {
    let dir = unique_temp_dir("ws-allow-origin");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let config = dir.join("config.json");
    fs::write(&config, json!({"server": {"ws_token": TOKEN}}).to_string()).unwrap();
    let child = Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .args(["--ws", "127.0.0.1:0", "--ws-allow-origin", "http://127.0.0.1:4190"])
        .env("CMUX_TUI_CONFIG", &config)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let server = HeadlessServer::adopt(child, socket, dir.join("state"), dir);
    server.wait_for_socket();
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "ws-conversations-v1")
    );
}
