//! A page credential bound to one page (`page-credential {page}`,
//! `page-credential-scoped-v1`) against a real owner, the way the app reaches
//! the Chief home's conversation owner: that owner's app connection is a
//! trusted local Unix connection but not the verified app, so it opens the
//! owner's loopback page listener (`ws-listen`) and asks for a credential
//! bound to the Channels page. The Channels page connects with it.
//!
//! Checked at the WebSocket boundary: the credential admits one handshake
//! with the Channels Origin only; that connection gets the Channels page's
//! raw commands and `cmux.protocol/2` allow list only (a terminal command or
//! an operation outside the Channels list is refused); it never
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
    /// Every event line the page heard, in order.
    events: Vec<Value>,
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
        let mut page = Self { socket, next: 1, events: Vec::new() };
        // Authenticated only when the daemon answers a request.
        let identify = page.try_rpc(json!({"cmd": "identify"}))?;
        (identify["ok"] == true).then_some(page)
    }

    fn try_rpc(&mut self, request: Value) -> Option<Value> {
        self.next += 1;
        let mut body = request.as_object().cloned().unwrap();
        // A `cmux.protocol/2` request carries a string id; a raw command a number.
        let id = if body.contains_key("protocol") {
            json!(format!("v2-{}", self.next))
        } else {
            json!(self.next)
        };
        body.insert("id".into(), id.clone());
        self.socket.send(Message::Text(Value::Object(body).to_string().into())).ok()?;
        loop {
            match self.socket.read() {
                Ok(Message::Text(text)) => {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    if value.get("event").is_some() {
                        self.events.push(value);
                    } else if value["id"] == id {
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

    /// Reads events until one named `name` (the read timeout bounds the wait).
    fn until_event(&mut self, name: &str) {
        while !self.events.iter().any(|event| event["event"] == name) {
            match self.socket.read().expect("no event") {
                Message::Text(text) => {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    if value.get("event").is_some() {
                        self.events.push(value);
                    }
                }
                Message::Close(frame) => panic!("closed: {frame:?}"),
                _ => {}
            }
        }
    }
}

fn v2(operation: &str, params: Value) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    json!({"protocol": "cmux.protocol/2", "type": "request", "operation": operation, "params": params})
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
    // Only the page's raw commands: no terminal, workspace or input command.
    for request in [
        json!({"cmd": "new-tab"}),
        json!({"cmd": "send-text", "text": "echo owned\n"}),
        json!({"cmd": "list-workspaces"}),
        json!({"cmd": "subscribe", "surface": "s1"}),
    ] {
        let refused = page.rpc(request.clone());
        assert_eq!(refused["ok"], false, "{request}: {refused}");
        assert_eq!(refused["error_code"], "origin.forbidden", "{request}: {refused}");
    }
    assert_eq!(page.rpc(json!({"cmd": "subscribe"}))["ok"], true);
    // Its stream carries its page's conversation events only: a workspace change made
    // before the conversation never reaches it.
    let workspace = app.rpc(json!({"cmd": "new-workspace"}));
    assert_eq!(workspace["ok"], true, "{workspace}");
    let created = page.rpc(json!({"cmd": "conversation-create", "idempotency_key": "spc-1",
        "title": "Scoped", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "You"},
            {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"}]}));
    assert_eq!(created["ok"], true, "{created}");
    page.until_event("conversation-changed");
    let names: Vec<&str> = page.events.iter().filter_map(|event| event["event"].as_str()).collect();
    assert!(names.iter().all(|name| name.starts_with("conversation-")), "{names:?}");
    // It is never the person: no Cloud command at all.
    for request in [
        json!({"cmd": "cloud-session-status"}),
        json!({"cmd": "cloud-inbox-list"}),
        json!({"cmd": "cloud-inbox-subscribe"}),
        json!({"cmd": "cloud-conversation-snapshot", "conversation": "conv_0123456789ABCDEFGHJKMNPQRS"}),
        json!({"cmd": "cloud-conversation-op", "conversation": "conv_0123456789ABCDEFGHJKMNPQRS",
               "idempotency_key": "spc-cloud", "origin": "user",
               "op": {"kind": "message.send", "client_msg_id": "spc-cloud",
                      "parts": [{"type": "text", "text": "hi"}]}}),
        json!({"cmd": "cloud-session-set", "api_base_url": "https://cloud-api-staging.cmux.dev",
               "access_token": "e30.e30.sig", "expires_at": 4_102_444_800_000_u64}),
    ] {
        let refused = page.rpc(request.clone());
        assert_eq!(refused["ok"], false, "{request}: {refused}");
    }
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

#[test]
fn the_channels_page_hears_its_chiefs_change() {
    // cx-ebm.60.4: the app connects the Channels page with a page-bound
    // credential; that page redraws its Chiefs on chief-changed.
    let owner = Fixture::new("chiefs");
    owner.ensure();
    let mut app = owner.unix();
    let addr = app.listen();
    let credential = app.channels_credential();
    let mut page = Page::open(&addr, Some(CHANNELS_ORIGIN), &credential)
        .expect("the Channels page was refused its own credential");
    let info = page.rpc(json!({"cmd": "set-client-info", "name": "channels",
        "capabilities": ["chief-events-v1"]}));
    assert_eq!(info["ok"], true, "{info}");
    assert_eq!(page.rpc(json!({"cmd": "subscribe"}))["ok"], true);

    // The person renames the default Chief from the page itself.
    let mut rename =
        v2("chief.profile.update", json!({"chief": "agent_mux", "display_name": "Boss"}));
    rename["idempotency_key"] = json!("rename-boss");
    let renamed = page.rpc(rename);
    assert_eq!(renamed["ok"], true, "{renamed}");
    page.until_event("chief-changed");
    let event = page.events.iter().find(|event| event["event"] == "chief-changed").unwrap();
    assert_eq!((&event["chief"], &event["change"]), (&json!("agent_mux"), &json!("updated")));
}

#[test]
fn the_channels_page_hears_a_participants_avatar_change() {
    // The Channels page draws every participant's picture and re-reads it on
    // participant-avatar-changed; connected with a page-bound credential it
    // must hear that event like the person's other connections.
    use base64::Engine as _;
    const GIF: &[u8] = b"GIF89a\x01\x00\x01\x00\x00\x00\x00;";
    let owner = Fixture::new("avatars");
    owner.ensure();
    let mut app = owner.unix();
    let addr = app.listen();
    let credential = app.channels_credential();
    let mut page = Page::open(&addr, Some(CHANNELS_ORIGIN), &credential)
        .expect("the Channels page was refused its own credential");
    let info = page.rpc(json!({"cmd": "set-client-info", "name": "channels",
        "capabilities": ["participant-avatars-v1"]}));
    assert_eq!(info["ok"], true, "{info}");
    assert_eq!(page.rpc(json!({"cmd": "subscribe"}))["ok"], true);

    // The person gives the default Chief a picture from the page itself.
    let mut picture = v2(
        "chief.profile.avatar.set",
        json!({"chief": "agent_mux", "media_type": "image/gif",
               "data": base64::engine::general_purpose::STANDARD.encode(GIF)}),
    );
    picture["idempotency_key"] = json!("mux-picture");
    let set = page.rpc(picture);
    assert_eq!(set["ok"], true, "{set}");
    page.until_event("participant-avatar-changed");
    let event =
        page.events.iter().find(|event| event["event"] == "participant-avatar-changed").unwrap();
    assert_eq!(event["participant"], "agent_mux", "{event}");
    assert_eq!(event["avatar"]["media_type"], "image/gif", "{event}");
}

#[test]
fn the_channels_page_hears_a_chiefs_live_run() {
    // chief-live-v1 through the app's path: the Channels page reaches the
    // Chief home's owner with a page-bound credential; it must hear the
    // Chief's live frames and read the run.live snapshot like any page.
    let owner = Fixture::new("live");
    owner.ensure();
    let mut app = owner.unix();
    let identity = app.rpc(json!({"cmd": "identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "chief-live-v1"), "{identity}");
    let addr = app.listen();
    let credential = app.channels_credential();
    let mut page = Page::open(&addr, Some(CHANNELS_ORIGIN), &credential)
        .expect("the Channels page was refused its own credential");
    let info = page.rpc(json!({"cmd": "set-client-info", "name": "channels",
        "capabilities": ["conversation-runs-v1", "chief-live-v1"]}));
    assert_eq!(info["ok"], true, "{info}");
    assert_eq!(page.rpc(json!({"cmd": "subscribe"}))["ok"], true);
    let created = page.rpc(json!({"cmd": "conversation-create", "idempotency_key": "spc-live",
        "title": "Chief", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "You"},
            {"id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"}]}));
    assert_eq!(created["ok"], true, "{created}");
    let conversation = created["data"]["conversation"]["id"].as_str().unwrap().to_owned();

    // The Chief's bound connection writes its run and streams its reply.
    let token = app.rpc(json!({"cmd": "conversation-agent-token", "participant": "agent_mux"}));
    assert_eq!(token["ok"], true, "{token}");
    let mut chief = owner.unix();
    let bound = chief.rpc(json!({"cmd": "conversation-bind", "participant": "agent_mux",
        "token": token["data"]["token"]}));
    assert_eq!(bound["ok"], true, "{bound}");
    let turn = "turn:spc:live";
    let started = chief.rpc(json!({"cmd": "conversation-run-append", "conversation": conversation,
        "run": {"id": turn, "turn": turn, "status": "running"}, "steps": []}));
    assert_eq!(started["ok"], true, "{started}");
    let frame = json!({"type": "step.delta", "conversation": conversation, "run": turn,
        "step": "talk:0", "kind": "talk", "seq": 0, "text": "Checking the release"});
    let sent = chief.rpc(json!({"cmd": "conversation-live-publish", "conversation": conversation,
            "frame": frame}));
    assert_eq!(sent["ok"], true, "{sent}");

    page.until_event("conversation-live");
    let event = page.events.iter().find(|event| event["event"] == "conversation-live").unwrap();
    assert_eq!(event["frame"]["text"], "Checking the release", "{event}");
    assert_eq!(event["frame"]["author"], "agent_mux", "{event}");
    assert_eq!(event["frame"]["t"], "step.delta", "{event}");
    let snapshot = page.rpc(json!({"cmd": "conversation-live", "conversation": conversation}));
    assert_eq!(snapshot["ok"], true, "{snapshot}");
    assert_eq!(snapshot["data"]["runs"][0]["steps"][0]["text"], "Checking the release");
    // The page hears nothing a Channels page may not (its page's events only).
    assert!(page.events.iter().all(|event| {
        event["event"]
            .as_str()
            .is_some_and(|name| name.starts_with("conversation-") || name == "chief-changed")
    }));
}
