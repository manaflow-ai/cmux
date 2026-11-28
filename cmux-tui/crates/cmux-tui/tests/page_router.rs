//! The daemon page router (`page-router-v1`, spec/page-router.md) against a
//! real owner: a page connection carries a page id, and the per-page allow
//! list of spec/page-router.json decides its `cmux.protocol/2` operations.
//!
//! hq-99's rule (cmux#13742): `history.*` reads only for page `history`; a
//! History delete needs page `history` and the person's gesture. Checked at
//! both page boundaries: the daemon WebSocket (page id from the handshake
//! Origin `cmux-page://cmux.<page>`) and the host's page relay on the Unix
//! socket (`client-hello {role: page_relay, page}`).

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest};

const HISTORY_ORIGIN: &str = "cmux-page://cmux.history";
const CHANNELS_ORIGIN: &str = "cmux-page://cmux.home-channels";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-pr-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("pr-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// An owner with its loopback page listener, admitting the page `origin`
    /// (one page per owner here, so each test proves one page's list).
    fn ensure(&self, origin: &str) {
        let output = self
            .command("ensure")
            .args(["--ws-loopback", "--ws-allow-origin", origin])
            .output()
            .unwrap();
        assert!(output.status.success(), "ensure: {}", String::from_utf8_lossy(&output.stderr));
    }

    /// The listener address and its credential (the 0600 file next to the socket).
    fn listener(&self) -> (String, String) {
        let mut name = self.socket.file_name().unwrap().to_os_string();
        name.push(".websocket.json");
        let credential: Value =
            serde_json::from_slice(&fs::read(self.socket.with_file_name(name)).unwrap()).unwrap();
        let url = credential["url"].as_str().unwrap();
        let addr = url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned();
        (addr, credential["token"].as_str().unwrap().to_owned())
    }

    fn unix(&self) -> Line {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Line { reader: BufReader::new(stream) }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// One line connection on the Unix socket.
struct Line {
    reader: BufReader<UnixStream>,
}

impl Line {
    fn send(&mut self, request: &Value) -> Value {
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == request["id"] {
                return value;
            }
        }
    }

    /// The next event line (the read timeout bounds the wait).
    fn event(&mut self) -> Value {
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_some() {
                return value;
            }
        }
    }
}

/// A `cmux.protocol/2` request as a page host sends it (selectors current).
fn v2(id: &str, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": id,
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    request
}

/// A page WebSocket: handshake with `origin`, the credential, then `requests`
/// in order; the replies in the same order.
fn page_websocket(addr: &str, origin: &str, token: &str, requests: &[Value]) -> Vec<Value> {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut handshake = format!("ws://{addr}/").into_client_request().unwrap();
    handshake.headers_mut().insert("Origin", origin.parse().unwrap());
    let (mut socket, _) = tungstenite::client(handshake, stream).unwrap();
    socket.send(Message::Text(json!({"auth": {"token": token}}).to_string().into())).unwrap();
    let mut replies = Vec::new();
    for request in requests {
        socket.send(Message::Text(request.to_string().into())).unwrap();
        loop {
            match socket.read().unwrap() {
                Message::Text(text) => {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    if value.get("event").is_none() && value["id"] == request["id"] {
                        replies.push(value);
                        break;
                    }
                }
                Message::Close(frame) => panic!("closed: {frame:?}"),
                _ => {}
            }
        }
    }
    replies
}

fn refusal_reason(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    reply["error"]["details"]["reason"].as_str().unwrap_or_default()
}

#[test]
fn only_the_history_page_reads_history_over_the_daemon_websocket() {
    // One owner per page origin: each admits its own page's Origin.
    let history_owner = Fixture::new("wsh");
    history_owner.ensure(HISTORY_ORIGIN);
    let identity = history_owner.unix().send(&json!({"id": 1, "cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "page-router-v1"), "{identity}");
    let (addr, token) = history_owner.listener();

    let list = v2("list", "history.entries.list", json!({"limit": 50}), None);
    let clear = v2("clear", "history.clear", json!({"range": "hour"}), Some("pr-clear-1"));

    // Page history reads its history; a clear without the person's gesture is refused.
    let history = page_websocket(&addr, HISTORY_ORIGIN, &token, &[list.clone(), clear.clone()]);
    assert_eq!(history[0]["ok"], true, "{}", history[0]);
    assert!(history[0]["result"]["entries"].is_array(), "{}", history[0]);
    assert_eq!(refusal_reason(&history[1]), "gesture_required");
    assert_eq!(history[1]["error"]["details"]["required"], "user", "{}", history[1]);

    // Page home-channels may read no history at all.
    let channels_owner = Fixture::new("wsc");
    channels_owner.ensure(CHANNELS_ORIGIN);
    let (addr, token) = channels_owner.listener();
    let channels = page_websocket(&addr, CHANNELS_ORIGIN, &token, &[list, clear]);
    assert_eq!(refusal_reason(&channels[0]), "page_not_allowed");
    assert_eq!(refusal_reason(&channels[1]), "page_not_allowed");

    // The Channels page keeps its raw conversation commands.
    let raw = page_websocket(
        &addr,
        CHANNELS_ORIGIN,
        &token,
        &[json!({"id": 9, "cmd": "conversation-list"})],
    );
    assert_eq!(raw[0]["ok"], true, "{}", raw[0]);
}

#[test]
fn the_page_relay_names_its_page_and_gets_that_page_list() {
    let fixture = Fixture::new("relay");
    fixture.ensure(HISTORY_ORIGIN);
    let list = v2("list", "history.entries.list", json!({}), None);

    // The host names the page; the reply carries the page's allow list.
    let mut history = fixture.unix();
    let hello = history
        .send(&json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "history"}));
    assert_eq!(hello["ok"], true, "{hello}");
    assert_eq!(hello["data"]["page"], "history", "{hello}");
    let gesture = hello["data"]["page_operations"]["gesture"].as_array().unwrap();
    assert!(gesture.iter().any(|op| op == "history.clear"), "{hello}");
    let read = history.send(&list);
    assert_eq!(read["ok"], true, "{read}");
    let removed = history.send(&v2(
        "remove",
        "history.entries.remove",
        json!({"ids": ["closed:none"]}),
        Some("pr-remove-1"),
    ));
    assert_eq!(refusal_reason(&removed), "gesture_required");

    // Another page's relay may not read history.
    let mut channels = fixture.unix();
    let hello = channels.send(
        &json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "home-channels"}),
    );
    assert_eq!(hello["ok"], true, "{hello}");
    assert_eq!(refusal_reason(&channels.send(&list)), "page_not_allowed");

    // A relay that names no page may call nothing (as before page-router-v1).
    let mut anonymous = fixture.unix();
    let hello = anonymous.send(&json!({"id": 1, "cmd": "client-hello", "role": "page_relay"}));
    assert_eq!(hello["ok"], true, "{hello}");
    assert_eq!(anonymous.send(&list)["ok"], false);

    // Only a page relay names a page, and only a valid page id.
    let bad = fixture
        .unix()
        .send(&json!({"id": 1, "cmd": "client-hello", "role": "main", "page": "history"}));
    assert_eq!(bad["error_code"], "client_hello.bad_request", "{bad}");
    let bad = fixture
        .unix()
        .send(&json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "../x"}));
    assert_eq!(bad["error_code"], "client_hello.bad_request", "{bad}");

    // A connection that is no page keeps its history reads.
    assert_eq!(fixture.unix().send(&list)["ok"], true);
}

/// cx-hnmbt.9: an open History page hears history changes through the
/// protocol. The page relay subscribes on its own connection and gets only
/// the events its page's table entry names (`history-changed` for page
/// `history`), so a workspace the person closes shows on the open page as a
/// Closed row without a search. Other pages' relays get no event stream, and
/// a page relay never gets a terminal's output stream.
#[test]
fn the_history_page_relay_hears_a_closed_workspace_as_history_changed() {
    let fixture = Fixture::new("events");
    fixture.ensure(HISTORY_ORIGIN);
    let mut relay = fixture.unix();
    let hello = relay
        .send(&json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "history"}));
    assert_eq!(hello["ok"], true, "{hello}");
    assert_eq!(hello["data"]["page_events"], json!(["history-changed"]), "{hello}");
    // The page's first read (every kind), then its event stream.
    let list = v2("list", "history.entries.list", json!({}), None);
    assert_eq!(relay.send(&list)["ok"], true);
    let subscribed = relay.send(&json!({"id": 2, "cmd": "subscribe"}));
    assert_eq!(subscribed["ok"], true, "{subscribed}");

    let mut main = fixture.unix();
    for name in ["kept", "closing"] {
        let created = main.send(&json!({"id": 3, "cmd": "new-workspace", "name": name}));
        assert_eq!(created["ok"], true, "{created}");
    }
    let tree = main.send(&json!({"id": 4, "cmd": "list-workspaces"}));
    let key = tree["data"]["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "closing")
        .map(|workspace| workspace["key"].clone())
        .unwrap_or_else(|| panic!("no closing workspace: {tree}"));
    let closed =
        main.send(&json!({"id": 5, "cmd": "close-workspace", "key": key, "end_terminals": true}));
    assert_eq!(closed["ok"], true, "{closed}");

    // Only history-changed reaches the page (no tree or terminal events),
    // and one of them names the Closed kind.
    loop {
        let event = relay.event();
        assert_eq!(event["event"], "history-changed", "{event}");
        let kinds = event["kinds"].as_array().cloned().unwrap_or_default();
        if kinds.iter().any(|kind| kind == "closed") {
            break;
        }
    }
    let read = relay.send(&list);
    let entries = read["result"]["entries"].as_array().unwrap_or_else(|| panic!("{read}"));
    assert!(entries.iter().any(|entry| entry["kind"] == "closed"), "{read}");

    // A terminal's output stream is a screen read: refused on a page relay.
    let output = relay.send(&json!({"id": 6, "cmd": "subscribe", "surface": 1}));
    assert_eq!(output["ok"], false, "{output}");
    assert_eq!(output["error_code"], "origin.forbidden", "{output}");

    // A page whose entry names no event gets no event stream.
    let mut channels = fixture.unix();
    let hello = channels.send(
        &json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "home-channels"}),
    );
    assert_eq!(hello["data"]["page_events"], json!([]), "{hello}");
    let refused = channels.send(&json!({"id": 2, "cmd": "subscribe"}));
    assert_eq!(refused["error_code"], "origin.forbidden", "{refused}");
}
