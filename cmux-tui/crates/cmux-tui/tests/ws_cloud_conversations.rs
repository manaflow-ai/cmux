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
const CHIEF: &str = "agent_01M4X1B5362SM3QJVJ155DA0GB";

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
/// conversation (paged by `limit` and `cursor`, as UserDO pages it), every op answers as committed; every request is recorded
/// with its path and bearer.
struct FakeCloud {
    base: String,
    requests: Arc<Mutex<Vec<(String, String, Value)>>>,
    /// The entries `inbox.list` answers.
    inbox: Arc<Mutex<Value>>,
}

impl FakeCloud {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let seen = requests.clone();
        let inbox = Arc::new(Mutex::new(json!([{"conversation":CONV,"rev":4,"kind":"group",
            "title":"Cloud team","last_seq":3,"last_at":"2026-10-13T00:00:00Z","preview":"hi",
            "removed":false,"unread":1,"mentions":0,"counts_rev":1,"pinned":false,"muted":false,
            "archived":false,"archived_seq":0,"marked_unread":false}])));
        let entries = inbox.clone();
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
                let reply = if path.starts_with(&format!("/v1/chiefs/{CHIEF}/runs/run_7?")) {
                    json!({"ok":true,"value":{"run":{"id":"run_7","conversation":CONV,"author":CHIEF,
                        "status":"done","started_at":1,"ended_at":2,"step_count":1},
                        "steps":[{"id":"tool:t1","seq":1,"at":1,"kind":"tool","status":"done",
                            "tool":{"name":"web_search","input":{"q":"release"},"output":"3 hits"}}],
                        "has_more":false}})
                } else if path.starts_with(&format!("/v1/chiefs/{CHIEF}/runs?")) {
                    json!({"ok":true,"value":{"runs":[{"id":"run_7","conversation":CONV,"author":CHIEF,
                        "status":"done","turn":"turn:cloud:1","started_at":1,"ended_at":2,"step_count":1}],
                        "has_more":false}})
                } else if body["op"] == "inbox.list" {
                    // Pages as UserDO does: `limit` entries (at most 200) from `cursor`, and the
                    // next page's cursor (here the index of its first entry), null on the last.
                    let entries = entries.lock().unwrap().as_array().cloned().unwrap_or_default();
                    let limit =
                        body["params"]["limit"].as_u64().unwrap_or(200).clamp(1, 200) as usize;
                    let from = body["params"]["cursor"]
                        .as_str()
                        .and_then(|c| c.parse().ok())
                        .unwrap_or(0usize);
                    let to = (from + limit).min(entries.len());
                    let next = (to < entries.len()).then(|| to.to_string());
                    json!({"ok":true,"value":{"entries":entries[from.min(to)..to],"next_cursor":next},"revision":"7"})
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
        Self { base, requests, inbox }
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

    // A Cloud Chief's runs, read from its brain through the daemon (cloud-conversation-runs-v1).
    assert!(capabilities.iter().any(|v| v == "cloud-conversation-runs-v1"), "{identity}");
    let runs = page
        .rpc(json!({"cmd":"cloud-conversation-runs","conversation":CONV,"agent":CHIEF,"limit":20}));
    assert_eq!(runs["ok"], true, "{runs}");
    assert_eq!(runs["data"]["runs"][0]["id"], "run_7", "{runs}");
    assert_eq!(runs["data"]["runs"][0]["turn"], "turn:cloud:1", "{runs}");
    let run = page.rpc(json!({"cmd":"cloud-conversation-run","conversation":CONV,"agent":CHIEF,
                              "run":"run_7","after_seq":0}));
    assert_eq!(run["ok"], true, "{run}");
    assert_eq!(run["data"]["steps"][0]["tool"]["name"], "web_search", "{run}");
    let paths: Vec<String> = cloud.requests().into_iter().map(|(path, ..)| path).collect();
    assert!(
        paths.contains(&format!("/v1/chiefs/{CHIEF}/runs?conversation={CONV}&limit=20")),
        "{paths:?}"
    );
    assert!(
        paths.contains(&format!("/v1/chiefs/{CHIEF}/runs/run_7?conversation={CONV}&after_seq=0")),
        "{paths:?}"
    );
    // An id that is not a Chief's never reaches the cloud.
    let bad =
        page.rpc(json!({"cmd":"cloud-conversation-runs","conversation":CONV,"agent":"user_x"}));
    assert_eq!(bad["ok"], false, "{bad}");
    assert!(cloud.requests().iter().all(|(path, ..)| !path.contains("user_x")));

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

/// Hide Alerts on a Cloud DM or group (plans/cmux-next/home-dm-group-chats/AUDIT.md item 13):
/// the person's client sends `cloud-inbox-op` `inbox.mute` and the daemon forwards it to the
/// person's UserDO inbox unchanged, with an optional `until` (Unix ms) and the client's key.
#[test]
fn the_persons_page_mutes_a_cloud_conversation_through_the_daemon() {
    let fixture = Fixture::start("mute");
    let cloud = FakeCloud::start();
    let token = person_token();
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &token))["ok"], true);
    let mut page = Page::open(&fixture.credential().0, &page_credential(&mut app));
    let muted = page.rpc(json!({"cmd":"cloud-inbox-op","conversation":CONV,
        "idempotency_key":"mute-1","op":{"kind":"inbox.mute","muted":true,"until":1_900_000_000_000_u64}}));
    assert_eq!(muted["ok"], true, "{muted}");
    let unmuted = page.rpc(json!({"cmd":"cloud-inbox-op","conversation":CONV,
        "idempotency_key":"mute-2","op":{"kind":"inbox.mute","muted":false}}));
    assert_eq!(unmuted["ok"], true, "{unmuted}");
    let requests = cloud.requests();
    assert_eq!(
        requests.iter().map(|(path, _, body)| (path.clone(), body.clone())).collect::<Vec<_>>(),
        vec![
            (
                "/v1/ops".to_string(),
                json!({"op":"inbox.mute","params":{"muted":true,
                "until":1_900_000_000_000_u64,"conversation":CONV},"idempotency_key":"mute-1"})
            ),
            (
                "/v1/ops".to_string(),
                json!({"op":"inbox.mute","params":{"muted":false,
                "conversation":CONV},"idempotency_key":"mute-2"})
            ),
        ],
        "{requests:?}"
    );
}

/// Group roles through the daemon (plans/cmux-next/home-dm-group-chats/DESIGN.md section 4): the
/// page's `cloud-conversation-op` forwards `participants.set_role`, `ownership.transfer`,
/// `participants.unban`, a `participants.remove` with `ban`, and the group link ops
/// `grant.create` and `grant.revoke` to `POST /v1/ops` unchanged.
#[test]
fn the_persons_page_manages_group_roles_through_the_daemon() {
    let fixture = Fixture::start("roles");
    let cloud = FakeCloud::start();
    let token = person_token();
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &token))["ok"], true);
    let mut page = Page::open(&fixture.credential().0, &page_credential(&mut app));
    let ops = [
        json!({"kind":"participants.set_role","participant":"user_ben","role":"admin"}),
        json!({"kind":"ownership.transfer","participant":"user_ben"}),
        json!({"kind":"participants.remove","participant":"user_cat","ban":true}),
        json!({"kind":"participants.unban","participant":"user_cat"}),
        json!({"kind":"grant.create","role":"read_only","max_uses":5}),
        json!({"kind":"grant.revoke","grant_id":"grt_00000000000000000000000001"}),
    ];
    for (n, op) in ops.iter().enumerate() {
        let reply = page.rpc(json!({"cmd":"cloud-conversation-op","conversation":CONV,
            "idempotency_key":format!("roles-{n}"),"origin":"user","op":op}));
        assert_eq!(reply["ok"], true, "{op}: {reply}");
    }
    let names: Vec<Value> = cloud
        .requests()
        .iter()
        .filter(|(path, _, _)| path == "/v1/ops")
        .map(|(_, _, body)| body["op"].clone())
        .collect();
    assert_eq!(
        names,
        vec![
            json!("participants.set_role"),
            json!("ownership.transfer"),
            json!("participants.remove"),
            json!("participants.unban"),
            json!("grant.create"),
            json!("grant.revoke")
        ]
    );
    let bodies: Vec<Value> = cloud
        .requests()
        .iter()
        .filter(|(path, _, _)| path == "/v1/ops")
        .map(|(_, _, body)| body["params"].clone())
        .collect();
    assert_eq!(bodies[0]["role"], "admin");
    assert_eq!(bodies[2]["ban"], true);
}

/// The person's pin and "marked unread" of a Cloud conversation
/// (`conversation-inbox-state-v1`): the page sends `cloud-inbox-op` and the
/// daemon forwards the Cloud owner's own inbox ops (`inbox.pin`,
/// `inbox.mark_unread`) to `POST /v1/ops` with the page's key; any other
/// kind, and any connection that is not the person, is refused before
/// anything leaves the daemon.
#[test]
fn the_persons_page_pins_a_cloud_conversation_through_the_daemon() {
    let fixture = Fixture::start("pin");
    let cloud = FakeCloud::start();
    let token = person_token();
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &token))["ok"], true);
    let (addr, file_token) = fixture.credential();
    let mut page = Page::open(&addr, &page_credential(&mut app));
    let identity = page.rpc(json!({"cmd":"identify"}));
    let capabilities = identity["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|v| v == "conversation-inbox-state-v1"), "{identity}");

    let pinned = page.rpc(json!({"cmd":"cloud-inbox-op","conversation":CONV,
        "idempotency_key":"pin-1","op":{"kind":"inbox.pin","pinned":true,"position":1_760_000_000_000_u64}}));
    assert_eq!(pinned["ok"], true, "{pinned}");
    let marked = page.rpc(json!({"cmd":"cloud-inbox-op","conversation":CONV,
        "idempotency_key":"unread-1","op":{"kind":"inbox.mark_unread","unread":true}}));
    assert_eq!(marked["ok"], true, "{marked}");
    let requests = cloud.requests();
    assert_eq!(requests.len(), 2, "{requests:?}");
    assert!(
        requests
            .iter()
            .all(|(path, bearer, _)| path == "/v1/ops" && *bearer == format!("Bearer {token}")),
        "{requests:?}"
    );
    assert_eq!(
        requests[0].2,
        json!({"op":"inbox.pin","params":{"pinned":true,"position":1_760_000_000_000_u64,
               "conversation":CONV},"idempotency_key":"pin-1"}),
        "{requests:?}"
    );
    assert_eq!(
        requests[1].2,
        json!({"op":"inbox.mark_unread","params":{"unread":true,"conversation":CONV},
               "idempotency_key":"unread-1"}),
        "{requests:?}"
    );

    // Default deny: another inbox op, a conversation op, a malformed id.
    for op in [
        json!({"kind":"inbox.archive","archived":true}),
        json!({"kind":"message.send","client_msg_id":"x","parts":[]}),
    ] {
        let refused = page.rpc(json!({"cmd":"cloud-inbox-op","conversation":CONV,
            "idempotency_key":"deny","op":op}));
        assert_eq!(refused["ok"], false, "{refused}");
        assert!(refused.to_string().contains("unsupported_op"), "{refused}");
    }
    let bad_id = page.rpc(json!({"cmd":"cloud-inbox-op","conversation":"conv_bad",
        "idempotency_key":"bad","op":{"kind":"inbox.pin","pinned":true}}));
    assert_eq!(bad_id["ok"], false, "{bad_id}");
    // The file token is not the person: refused, nothing sent.
    let mut agent = Page::open(&addr, &file_token);
    let foreign = agent.rpc(json!({"cmd":"cloud-inbox-op","conversation":CONV,
        "idempotency_key":"agent","op":{"kind":"inbox.pin","pinned":true}}));
    assert_eq!(foreign["ok"], false, "{foreign}");
    assert_eq!(cloud.requests().len(), 2, "{:?}", cloud.requests());
}

/// Cloud conversations' attachments through the daemon (`cloud-attachments-v1`).
#[path = "ws_cloud_conversations/attachments.rs"]
mod attachments;

#[test]
fn the_persons_page_gets_cloud_rows_in_the_home_inbox() {
    let fixture = Fixture::start("home");
    let cloud = FakeCloud::start();
    let token = person_token();
    let mut app = fixture.app();
    let (addr, file_token) = fixture.credential();

    // Before a lease: no Cloud rows, and the result says why.
    let mut page = Page::open(&addr, &page_credential(&mut app));
    let identity = page.rpc(json!({"cmd":"identify"}));
    assert!(
        identity["data"]["capabilities"].as_array().unwrap().iter().any(|v| v == "home-inbox-v1"),
        "{identity}"
    );
    let before = page.rpc(json!({"cmd":"home-inbox"}));
    assert_eq!(before["ok"], true, "{before}");
    assert_eq!(before["data"]["cloud"], "signed_out", "{before}");
    assert!(
        before["data"]["rows"].as_array().unwrap().iter().all(|row| row["owner"] != "cloud"),
        "{before}"
    );

    // The app leases the person's session: the page's rows include the Cloud inbox.
    assert_eq!(app.rpc(lease(&cloud.base, &token))["ok"], true);
    let inbox = page.rpc(json!({"cmd":"home-inbox"}));
    assert_eq!(inbox["ok"], true, "{inbox}");
    assert_eq!(inbox["data"]["cloud"], "included", "{inbox}");
    let row = inbox["data"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == CONV)
        .unwrap_or_else(|| panic!("no Cloud row: {inbox}"))
        .clone();
    assert_eq!(row["owner"], "cloud", "{row}");
    assert_eq!(row["kind"], "channel", "{row}");
    assert_eq!(row["name"], "Cloud team", "{row}");
    assert_eq!(row["unread"], 1, "{row}");
    assert_eq!(row["preview"], "hi", "{row}");
    assert_eq!(row["activity_at"], "2026-10-13T00:00:00Z", "{row}");
    assert_eq!(row["pinned"], false, "{row}");
    assert_eq!(row["muted"], false, "{row}");
    assert!(row.get("chief_state").is_none(), "{row}");
    assert!(
        cloud
            .requests()
            .iter()
            .any(|(_, bearer, body)| body["op"] == "inbox.list"
                && *bearer == format!("Bearer {token}")),
        "{:?}",
        cloud.requests()
    );

    // A view that asks this daemon for its local rows only gets no Cloud rows.
    let local = page.rpc(json!({"cmd":"home-inbox","owners":["local"]}));
    assert_eq!(local["data"]["cloud"], "not_asked", "{local}");
    assert!(
        local["data"]["rows"].as_array().unwrap().iter().all(|row| row["owner"] == "local"),
        "{local}"
    );
    let cloud_only = page.rpc(json!({"cmd":"home-inbox","owners":["cloud"]}));
    assert_eq!(cloud_only["data"]["rows"].as_array().unwrap().len(), 1, "{cloud_only}");
    let refused = page.rpc(json!({"cmd":"home-inbox","owners":["elsewhere"]}));
    assert_eq!(refused["ok"], false, "{refused}");

    // The file token is any same-user process's: it never gets the person's Cloud rows.
    let mut agent = Page::open(&addr, &file_token);
    let other = agent.rpc(json!({"cmd":"home-inbox"}));
    assert_eq!(other["ok"], true, "{other}");
    assert_eq!(other["data"]["cloud"], "signed_out", "{other}");
    assert!(
        other["data"]["rows"].as_array().unwrap().iter().all(|row| row["owner"] != "cloud"),
        "{other}"
    );
}

/// Home lists the whole Cloud inbox, not its newest page: the owner pages
/// `inbox.list` by 200, and `home-inbox` read only the first page, so a Chief
/// or conversation past the newest 200 never showed. `cloud-inbox-list` stays
/// one page per call and hands back the owner's cursor.
#[test]
fn home_inbox_lists_every_page_of_the_cloud_inbox() {
    let fixture = Fixture::start("pages");
    let cloud = FakeCloud::start();
    let template = cloud.inbox.lock().unwrap()[0].clone();
    let ids: Vec<String> = (0..450).map(|i| format!("conv_PAGE{i:04}0123456789ABCDEFGH")).collect();
    *cloud.inbox.lock().unwrap() = Value::Array(
        ids.iter()
            .map(|id| {
                let mut entry = template.clone();
                entry["conversation"] = json!(id);
                entry
            })
            .collect(),
    );
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &person_token()))["ok"], true);
    let (addr, _) = fixture.credential();
    let mut page = Page::open(&addr, &page_credential(&mut app));
    let inbox = page.rpc(json!({"cmd":"home-inbox","owners":["cloud"]}));
    assert_eq!(inbox["data"]["cloud"], "included", "{inbox}");
    let rows: Vec<&str> = inbox["data"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|row| row["id"].as_str())
        .collect();
    assert_eq!(rows.len(), ids.len(), "rows {}", rows.len());
    for id in &ids {
        assert_eq!(rows.iter().filter(|row| **row == id.as_str()).count(), 1, "{id}");
    }
    let cursors: Vec<Value> = cloud
        .requests()
        .iter()
        .filter(|(_, _, body)| body["op"] == "inbox.list")
        .map(|(_, _, body)| body["params"]["cursor"].clone())
        .collect();
    assert_eq!(cursors, [Value::Null, json!("200"), json!("400")]);

    // One page per cloud-inbox-list call, with the owner's cursor for the next.
    let first = app.rpc(json!({"cmd":"cloud-inbox-list"}));
    assert_eq!(first["data"]["entries"].as_array().unwrap().len(), 200, "{first}");
    assert_eq!(first["data"]["next_cursor"], "200", "{first}");
    let last = app.rpc(json!({"cmd":"cloud-inbox-list","cursor":"400"}));
    assert_eq!(last["data"]["entries"].as_array().unwrap().len(), 50, "{last}");
    assert_eq!(last["data"]["next_cursor"], Value::Null, "{last}");
}

/// The shared Cloud row corpus (tests/fixtures/home-inbox-cloud-cases.json):
/// the daemon's rows for each entry. The Channels page's Cloud list is held to
/// the same corpus by webviews/test/home-cloud-rows.test.ts, so the two Cloud
/// projections cannot drift apart silently.
#[test]
fn home_inbox_cloud_rows_follow_the_shared_corpus() {
    let corpus: Value =
        serde_json::from_str(include_str!("fixtures/home-inbox-cloud-cases.json")).unwrap();
    let cases = corpus["cases"].as_array().unwrap();
    let fixture = Fixture::start("corpus");
    let cloud = FakeCloud::start();
    *cloud.inbox.lock().unwrap() =
        Value::Array(cases.iter().map(|case| case["entry"].clone()).collect());
    let mut app = fixture.app();
    assert_eq!(app.rpc(lease(&cloud.base, &person_token()))["ok"], true);
    let (addr, _) = fixture.credential();
    let mut page = Page::open(&addr, &page_credential(&mut app));
    let inbox = page.rpc(json!({"cmd":"home-inbox","owners":["cloud"]}));
    assert_eq!(inbox["data"]["cloud"], "included", "{inbox}");
    let rows = inbox["data"]["rows"].as_array().unwrap();
    for case in cases {
        let id = &case["entry"]["conversation"];
        let row = rows.iter().find(|row| &row["id"] == id);
        match case["row"].as_object() {
            None => assert!(row.is_none(), "{}: {row:?}", case["name"]),
            Some(expected) => {
                let row = row.unwrap_or_else(|| panic!("{}: no row in {inbox}", case["name"]));
                for (field, value) in expected {
                    assert_eq!(&row[field], value, "{} {field}: {row}", case["name"]);
                }
            }
        }
    }
}
