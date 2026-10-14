//! A page credential bound to one page (`page-credential {page}`,
//! `page-credential-scoped-v1`) against a real owner, the way the app reaches
//! the Chief home's conversation owner: that owner's app connection is a
//! trusted local Unix connection but not the verified app, so it opens the
//! owner's loopback page listener (`ws-listen`) and asks for a credential
//! bound to the Channels page. The Channels page connects with it.
//!
//! Checked at the WebSocket boundary: the credential admits one handshake
//! with the Channels Origin only; the page-router table applies to that
//! connection (an operation outside the Channels list is refused); it never
//! carries the Cloud lease; a WebSocket connection cannot mint one; after an
//! owner restart a fresh credential connects again.

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

const CHANNELS_ORIGIN: &str = "cmux-page://cmux.home-channels";
const HISTORY_ORIGIN: &str = "cmux-page://cmux.history";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-spc-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("spc-{name}"), dir }
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

    /// The owner as the Chief home's owner starts: no install key, no listener.
    fn ensure(&self) {
        let output = self.command("ensure").output().unwrap();
        assert!(output.status.success(), "ensure: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn stop(&self) {
        let output = self.command("stop").output().unwrap();
        assert!(output.status.success(), "stop: {}", String::from_utf8_lossy(&output.stderr));
    }

    fn unix(&self) -> Line {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Line { reader: BufReader::new(stream), next: 1 }
    }

    /// The listener file token (only to prove a WebSocket cannot mint).
    fn file_token(&self) -> String {
        let mut name = self.socket.file_name().unwrap().to_os_string();
        name.push(".websocket.json");
        let file: Value =
            serde_json::from_slice(&fs::read(self.socket.with_file_name(name)).unwrap()).unwrap();
        file["token"].as_str().unwrap().to_owned()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Line {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Line {
    fn rpc(&mut self, request: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = request.as_object().cloned().unwrap();
        body.insert("id".into(), json!(id));
        writeln!(self.reader.get_mut(), "{}", Value::Object(body)).unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == id {
                return value;
            }
        }
    }

    /// `ws-listen` as the app sends it: the listener address.
    fn listen(&mut self) -> String {
        let reply = self.rpc(json!({"cmd": "ws-listen",
            "allow_origins": [CHANNELS_ORIGIN, HISTORY_ORIGIN]}));
        assert_eq!(reply["ok"], true, "{reply}");
        let url = reply["data"]["url"].as_str().unwrap();
        assert!(url.starts_with("ws://127.0.0.1:"), "not loopback: {url}");
        url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned()
    }

    fn scoped(&mut self, page: &str) -> Value {
        self.rpc(json!({"cmd": "page-credential", "page": page}))
    }

    fn channels_credential(&mut self) -> String {
        let reply = self.scoped("home-channels");
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(reply["data"]["page"], "home-channels", "{reply}");
        assert!(reply["data"]["expires_in"].as_u64().unwrap() <= 120, "{reply}");
        reply["data"]["credential"].as_str().unwrap().to_owned()
    }
}

/// A page WebSocket with `origin` (none: no Origin header) and `token`.
/// `None` when the daemon refused the handshake.
struct Page {
    socket: tungstenite::WebSocket<TcpStream>,
    next: u64,
}

impl Page {
    fn open(addr: &str, origin: Option<&str>, token: &str) -> Option<Self> {
        let stream = TcpStream::connect(addr).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut handshake = format!("ws://{addr}/").into_client_request().unwrap();
        if let Some(origin) = origin {
            handshake.headers_mut().insert("Origin", origin.parse().unwrap());
        }
        let (mut socket, _) = tungstenite::client(handshake, stream).ok()?;
        socket.send(Message::Text(json!({"auth": {"token": token}}).to_string().into())).ok()?;
        let mut page = Self { socket, next: 1 };
        // Authenticated only when the daemon answers a request.
        let identify = page.try_rpc(json!({"cmd": "identify"}))?;
        (identify["ok"] == true).then_some(page)
    }

    fn try_rpc(&mut self, request: Value) -> Option<Value> {
        let id = self.next;
        self.next += 1;
        let mut body = request.as_object().cloned().unwrap();
        body.insert("id".into(), json!(id));
        self.socket.send(Message::Text(Value::Object(body).to_string().into())).ok()?;
        loop {
            match self.socket.read() {
                Ok(Message::Text(text)) => {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    if value.get("event").is_none() && value["id"] == id {
                        return Some(value);
                    }
                }
                Ok(Message::Close(_)) | Err(_) => return None,
                Ok(_) => {}
            }
        }
    }

    fn rpc(&mut self, request: Value) -> Value {
        self.try_rpc(request).expect("the daemon closed the page WebSocket")
    }
}

fn v2(operation: &str, params: Value) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    json!({"protocol": "cmux.protocol/2", "type": "request", "id": "v2-1",
           "operation": operation, "params": params})
}

#[test]
fn a_page_bound_credential_admits_only_its_page_and_never_the_person() {
    let owner = Fixture::new("bound");
    owner.ensure();
    let mut app = owner.unix();
    let identity = app.rpc(json!({"cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "page-credential-scoped-v1"), "{identity}");
    let addr = app.listen();

    // This connection is not the verified app: the person's credential is refused.
    assert_eq!(app.rpc(json!({"cmd": "page-credential"}))["ok"], false);
    // An id outside the page-router table is refused.
    assert_eq!(app.scoped("no-such-page")["ok"], false);

    // The Channels page connects once with its Origin and reads its conversations.
    let credential = app.channels_credential();
    let mut page = Page::open(&addr, Some(CHANNELS_ORIGIN), &credential)
        .expect("the Channels page was refused its own credential");
    let list = page.rpc(json!({"cmd": "conversation-list"}));
    assert_eq!(list["ok"], true, "{list}");
    // The page-router table applies: an operation outside the Channels list is refused.
    let history = page.rpc(v2("history.entries.list", json!({"limit": 5})));
    assert_eq!(history["ok"], false, "{history}");
    assert_eq!(history["error"]["code"], "origin.forbidden", "{history}");
    assert_eq!(history["error"]["details"]["reason"], "page_not_allowed", "{history}");
    // It is never the person: no Cloud command.
    let cloud = page.rpc(json!({"cmd": "cloud-session-status"}));
    assert_eq!(cloud["ok"], false, "{cloud}");
    // A WebSocket connection never mints a credential.
    assert_eq!(page.rpc(json!({"cmd": "page-credential", "page": "home-channels"}))["ok"], false);

    // Single use.
    assert!(Page::open(&addr, Some(CHANNELS_ORIGIN), &credential).is_none(), "used twice");
    // Another page's Origin, or none, is refused (and uses the credential up).
    let other = app.channels_credential();
    assert!(Page::open(&addr, Some(HISTORY_ORIGIN), &other).is_none(), "history Origin admitted");
    assert!(Page::open(&addr, Some(CHANNELS_ORIGIN), &other).is_none(), "refused one reused");
    let bare = app.channels_credential();
    assert!(Page::open(&addr, None, &bare).is_none(), "admitted without a page Origin");

    // Even the file token's WebSocket connection cannot mint one.
    let mut file = Page::open(&addr, None, &owner.file_token()).expect("file token refused");
    assert_eq!(file.rpc(json!({"cmd": "page-credential", "page": "home-channels"}))["ok"], false);
}

#[test]
fn after_an_owner_restart_a_fresh_page_credential_connects_again() {
    let owner = Fixture::new("restart");
    owner.ensure();
    let addr = owner.unix().listen();
    let credential = owner.unix().channels_credential();
    let mut page = Page::open(&addr, Some(CHANNELS_ORIGIN), &credential).expect("first connect");
    assert_eq!(page.rpc(json!({"cmd": "conversation-list"}))["ok"], true);

    owner.stop();
    assert!(page.try_rpc(json!({"cmd": "conversation-list"})).is_none(), "the page outlived it");

    // The host asks again on reconnect: the new owner's listener and credential.
    owner.ensure();
    let mut app = owner.unix();
    let addr = app.listen();
    let fresh = app.channels_credential();
    let mut page = Page::open(&addr, Some(CHANNELS_ORIGIN), &fresh).expect("reconnect");
    assert_eq!(page.rpc(json!({"cmd": "conversation-list"}))["ok"], true);
}
