//! Cloud conversations for the person's authenticated page
//! (`ws-cloud-conversations-v1`, cx-hnmbt): the app's real path.
//!
//! A real owner starts through `server ensure --install-key-stdin
//! --ws-loopback`, as the app starts it. The app's connection proves itself
//! (`client-hello`), leases the signed-in person's Cloud session and asks for
//! a page credential (`page-credential`). The Channels page connects to the
//! same daemon over its loopback WebSocket with that credential and gets the
//! cloud conversations through the daemon: the inbox, an op as the user, the
//! cloud events, and the person's participant id. The Cloud token stays in
//! the daemon; the page never sets or clears a lease. The file token next to
//! the socket (any same-user process can read it) never gets the lease. The
//! cloud is a loopback HTTP server that records each request.

#![cfg(unix)]

use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, WebSocket};

const KEY_HEX: &str = "5c2e3d4f60718293a4b5c6d7e8f9011223344556677889900aabbccddeeff011";
const INSTALL: &str = "inst_ws_cloud";
const CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    /// The owner as the app starts it: install key on stdin, loopback listener.
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-wsc-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let fixture = Self { socket: dir.join("mux.sock"), session: format!("wsc-{name}"), dir };
        let mut child = fixture
            .command("ensure")
            .args(["--install-key-stdin", "--ws-loopback"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "ensure failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        fixture
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

    /// `(address, token)` from the daemon's own credential file.
    fn credential(&self) -> (String, String) {
        let mut name = self.socket.file_name().unwrap().to_os_string();
        name.push(".websocket.json");
        let value: Value =
            serde_json::from_slice(&fs::read(self.socket.with_file_name(name)).unwrap()).unwrap();
        let url = value["url"].as_str().unwrap();
        let addr = url.strip_prefix("ws://").unwrap().trim_end_matches('/').to_owned();
        (addr, value["token"].as_str().unwrap().to_owned())
    }

    fn plain(&self) -> Unix {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Unix { reader: BufReader::new(stream), next: 100 }
    }

    /// A connection proven as the cmux app (the `frontend` actor).
    fn app(&self) -> Unix {
        let mut client = self.plain();
        let challenge =
            client.rpc(json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL}));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL, &nonce);
        let proved =
            client.rpc(json!({"cmd": "client-hello", "install_id": INSTALL, "proof": proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        client
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").arg("--end-terminals").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Unix {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Unix {
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
}

/// The Channels page's connection: the daemon WebSocket with its credential.
struct Page {
    socket: WebSocket<TcpStream>,
    next: u64,
    events: VecDeque<Value>,
}

impl Page {
    fn open(addr: &str, token: &str) -> Self {
        let stream = TcpStream::connect(addr).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let (mut socket, _) = tungstenite::client(format!("ws://{addr}/"), stream).unwrap();
        socket.send(Message::Text(json!({"auth": {"token": token}}).to_string().into())).unwrap();
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

    fn rpc(&mut self, request: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = request.as_object().cloned().unwrap();
        body.insert("id".into(), json!(id));
        self.socket.send(Message::Text(Value::Object(body).to_string().into())).unwrap();
        loop {
            let value = self.read();
            if value.get("event").is_some() {
                self.events.push_back(value);
            } else if value["id"] == id {
                return value;
            }
        }
    }

    /// The next `cloud-*` event within `wait` (None: none came).
    fn cloud_event_within(&mut self, wait: Duration) -> Option<Value> {
        let cloud =
            |event: &Value| event["event"].as_str().is_some_and(|n| n.starts_with("cloud-"));
        if let Some(at) = self.events.iter().position(cloud) {
            return self.events.remove(at);
        }
        let deadline = Instant::now() + wait;
        let mut found = None;
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            self.socket
                .get_mut()
                .set_read_timeout(Some(left.max(Duration::from_millis(1))))
                .unwrap();
            let event = match self.socket.read() {
                Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).unwrap(),
                Ok(_) => continue,
                Err(_) => break,
            };
            if cloud(&event) {
                found = Some(event);
                break;
            }
        }
        self.socket.get_mut().set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        found
    }

    /// The `cloud-*` events before the next `tree-changed` marker.
    fn cloud_events_before_marker(&mut self) -> Vec<Value> {
        let mut cloud = Vec::new();
        loop {
            let event = self.events.pop_front().unwrap_or_else(|| self.read());
            match event["event"].as_str() {
                Some("tree-changed") => return cloud,
                Some(name) if name.starts_with("cloud-") => cloud.push(event),
                _ => {}
            }
        }
    }
}

/// A loopback stand-in for the cmux Cloud API: `inbox.list` lists one
/// conversation, every op answers as committed; every request is recorded
/// with its path and bearer.
struct FakeCloud {
    base: String,
    requests: Arc<Mutex<Vec<(String, String, Value)>>>,
}

impl FakeCloud {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut reader = BufReader::new(stream);
                let (mut length, mut path, mut bearer) = (0usize, String::new(), String::new());
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        break;
                    }
                    if path.is_empty() {
                        path = line.split(' ').nth(1).unwrap_or("").to_string();
                    }
                    let lower = line.to_ascii_lowercase();
                    if let Some(value) = lower.strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap_or(0);
                    }
                    if lower.starts_with("authorization:") {
                        bearer = line["authorization:".len()..].trim().to_string();
                    }
                    if line == "\r\n" {
                        break;
                    }
                }
                let mut body = vec![0; length];
                let body = if reader.read_exact(&mut body).is_ok() {
                    serde_json::from_slice::<Value>(&body).unwrap_or(Value::Null)
                } else {
                    Value::Null
                };
                let reply = if body["op"] == "inbox.list" {
                    json!({"ok":true,"value":{"entries":[{"conversation":CONV,"rev":4,"kind":"group",
                        "title":"Cloud team","last_seq":3,"last_at":"2026-10-13T00:00:00Z","preview":"hi",
                        "removed":false,"unread":1,"mentions":0,"counts_rev":1,"pinned":false,"muted":false,
                        "archived":false,"archived_seq":0,"marked_unread":false}]},"revision":"7"})
                } else {
                    json!({"ok":true,"op":body["op"],"value":{"rev":5,"seq":4,
                        "message_id":"msg_0000000000000000000000000Z"},
                        "revision":"5","transaction":"tx-1","idempotency_key":body["idempotency_key"],
                        "replayed":false,"stream":format!("conv:{CONV}"),"sequence":4})
                };
                seen.lock().unwrap().push((path, bearer, body));
                let reply = reply.to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                let _ = reader.get_mut().write_all(response.as_bytes());
            }
        });
        Self { base, requests }
    }

    fn requests(&self) -> Vec<(String, String, Value)> {
        self.requests.lock().unwrap().clone()
    }
}

/// A person's session token (JWT shape; the daemon reads `sub` and `aud`
/// without verifying, the Worker verifies).
fn person_token() -> String {
    use base64::Engine;
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(json!({"sub": "stack-user-1", "aud": "stack-project-1"}).to_string());
    format!("e30.{payload}.sig")
}

fn lease(base: &str, token: &str) -> Value {
    json!({"cmd":"cloud-session-set","api_base_url":base,"access_token":token,
           "expires_at":4_102_444_800_000_u64})
}

/// Whether a WebSocket handshake with `token` is refused.
fn identify_fails(addr: &str, token: &str) -> bool {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let Ok((mut socket, _)) = tungstenite::client(format!("ws://{addr}/"), stream) else {
        return true;
    };
    let auth = json!({"auth": {"token": token}}).to_string();
    let identify = json!({"id": 1, "cmd": "identify"}).to_string();
    if socket.send(Message::Text(auth.into())).is_err()
        || socket.send(Message::Text(identify.into())).is_err()
    {
        return true;
    }
    loop {
        match socket.read() {
            Ok(Message::Text(text)) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["id"] == 1 {
                    return value["ok"] != true;
                }
            }
            Ok(Message::Close(_)) | Err(_) => return true,
            Ok(_) => {}
        }
    }
}

/// The verified app's page credential (`page-credential`).
fn page_credential(app: &mut Unix) -> String {
    let reply = app.rpc(json!({"cmd":"page-credential"}));
    assert_eq!(reply["ok"], true, "{reply}");
    reply["data"]["credential"].as_str().unwrap().to_owned()
}

#[test]
fn the_persons_page_gets_cloud_conversations_through_the_daemon() {
    let fixture = Fixture::start("page");
    let cloud = FakeCloud::start();
    let token = person_token();
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &token))["ok"], true);

    // The file token is any same-user process's: it never gets the person's lease.
    let (addr, file_token) = fixture.credential();
    let mut agent = Page::open(&addr, &file_token);
    let identity = agent.rpc(json!({"cmd":"identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|v| v == "ws-cloud-conversations-v1"), "{identity}");
    assert!(capabilities.iter().any(|v| v == "page-credential-v1"), "{identity}");
    for request in [json!({"cmd":"cloud-session-status"}), json!({"cmd":"cloud-inbox-list"})] {
        let refused = agent.rpc(request.clone());
        assert_eq!(refused["ok"], false, "{request}: {refused}");
    }
    // Only the verified app gets a page credential.
    assert_eq!(fixture.plain().rpc(json!({"cmd":"page-credential"}))["ok"], false);
    assert_eq!(agent.rpc(json!({"cmd":"page-credential"}))["ok"], false);
    assert!(cloud.requests().is_empty(), "{:?}", cloud.requests());

    let credential = page_credential(&mut app);
    let mut page = Page::open(&addr, &credential);
    assert_eq!(page.rpc(json!({"cmd":"subscribe"}))["ok"], true);
    // A page credential authenticates one handshake only.
    assert!(identify_fails(&addr, &credential), "a page credential was accepted twice");

    // The person's Worker user id, so the page knows itself in cloud conversations.
    let status = page.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "active", "{status}");
    // backend domains/user.ts userIdFor("stack-project-1", "stack-user-1").
    assert_eq!(status["data"]["participant"], "user_63ae3f9fb4418f43e36c", "{status}");
    assert!(!status.to_string().contains(&token), "the status echoed the token");

    // The inbox, through the daemon's lease.
    let inbox = page.rpc(json!({"cmd":"cloud-inbox-list"}));
    assert_eq!(inbox["ok"], true, "{inbox}");
    assert_eq!(inbox["data"]["entries"][0]["conversation"], CONV, "{inbox}");
    assert_eq!(inbox["data"]["entries"][0]["title"], "Cloud team", "{inbox}");

    // A send as the user.
    let sent = page.rpc(json!({"cmd":"cloud-conversation-op","conversation":CONV,
        "idempotency_key":"page-send-1","origin":"user",
        "op":{"kind":"message.send","client_msg_id":"page-send-1",
              "parts":[{"type":"text","text":"hello cloud from the page"}]}}));
    assert_eq!(sent["ok"], true, "{sent}");
    let requests = cloud.requests();
    assert_eq!(requests.len(), 2, "{requests:?}");
    assert_eq!(requests[0].0, "/v1/read", "{requests:?}");
    assert_eq!(requests[1].0, "/v1/ops", "{requests:?}");
    assert_eq!(requests[1].2["origin"], "user", "{requests:?}");
    assert_eq!(requests[1].2["params"]["parts"][0]["text"], "hello cloud from the page");
    // The token went only to the cloud, as the bearer.
    assert!(requests.iter().all(|(_, bearer, _)| *bearer == format!("Bearer {token}")));

    // The lease's cloud events reach the page's stream (the inbox socket's state).
    assert_eq!(page.rpc(json!({"cmd":"cloud-inbox-subscribe"}))["ok"], true);
    let event = page.cloud_event_within(Duration::from_secs(15));
    assert!(event.is_some(), "the page got no cloud events");

    // The page never sets or clears the lease.
    let set = page.rpc(lease("https://cloud-api-staging.cmux.dev", "other.jwt"));
    assert_eq!(set["ok"], false, "{set}");
    let clear = page.rpc(json!({"cmd":"cloud-session-clear"}));
    assert_eq!(clear["ok"], false, "{clear}");
    assert_eq!(page.rpc(json!({"cmd":"cloud-session-status"}))["data"]["state"], "active");

    // Once the app signs out, the page is signed out too.
    assert_eq!(app.rpc(json!({"cmd":"cloud-session-clear"}))["ok"], true);
    let signed_out = page.rpc(json!({"cmd":"cloud-inbox-list"}));
    assert_eq!(signed_out["error_code"], "cloud_signed_out", "{signed_out}");
}

#[test]
fn a_page_never_uses_a_lease_another_connection_set() {
    // A headless brain's lease (or any non-app lease) is not the person's.
    let fixture = Fixture::start("brain");
    let cloud = FakeCloud::start();
    let mut brain = fixture.plain();
    assert_eq!(brain.rpc(lease(&cloud.base, &person_token()))["ok"], true);

    let (addr, _) = fixture.credential();
    let mut page = Page::open(&addr, &page_credential(&mut fixture.app()));
    assert_eq!(page.rpc(json!({"cmd":"subscribe"}))["ok"], true);
    // The brain's stream events never reach the page.
    assert_eq!(brain.rpc(json!({"cmd":"cloud-inbox-subscribe"}))["ok"], true);
    assert_eq!(fixture.plain().rpc(json!({"cmd":"new-workspace"}))["ok"], true);
    let leaked = page.cloud_events_before_marker();
    assert!(leaked.is_empty(), "the page got the brain's cloud events: {leaked:?}");
    let status = page.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "signed_out", "{status}");
    let refused = page.rpc(json!({"cmd":"cloud-inbox-list"}));
    assert_eq!(refused["error_code"], "cloud_signed_out", "{refused}");
    // The brain's own inbox socket (`/v1/wire/user`) is its; the page sent no read.
    let reads: Vec<_> =
        cloud.requests().into_iter().filter(|(path, ..)| path != "/v1/wire/user").collect();
    assert!(reads.is_empty(), "the page used the brain's lease: {reads:?}");
}

#[test]
fn an_open_page_learns_that_the_app_signed_in() {
    let fixture = Fixture::start("signin");
    let cloud = FakeCloud::start();
    let mut app = fixture.app();
    let (addr, _) = fixture.credential();
    let mut page = Page::open(&addr, &page_credential(&mut app));
    assert_eq!(page.rpc(json!({"cmd":"subscribe"}))["ok"], true);
    let status = page.rpc(json!({"cmd":"cloud-session-status"}));
    assert_eq!(status["data"]["state"], "signed_out", "{status}");
    // The app signs in: the page is told to list the inbox again.
    assert_eq!(app.rpc(lease(&cloud.base, &person_token()))["ok"], true);
    let event = page.cloud_event_within(Duration::from_secs(15));
    assert_eq!(
        event.as_ref().map(|e| e["event"].clone()),
        Some(json!("cloud-inbox-reset")),
        "{event:?}"
    );
    // A renewal of the same account is not a new lease.
    assert_eq!(app.rpc(lease(&cloud.base, &person_token()))["ok"], true);
    assert_eq!(page.rpc(json!({"cmd":"cloud-session-status"}))["data"]["state"], "active");
}
