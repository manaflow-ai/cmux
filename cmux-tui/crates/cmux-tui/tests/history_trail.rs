//! The daemon owns the location trail and lists the terminal command rows
//! in the merged history (cx-hnmbt.12), against a real owner and the
//! History page's own boundaries: the host's page relay on the Unix socket
//! and the daemon WebSocket.
//!
//! - Only the verified app records a step (`history.trail.record`, gate
//!   A2); an agent is refused.
//! - The History page lists location rows (with their window and stored
//!   place) and this machine's command rows (`command:local/<row id>`, the
//!   ids the Swift History page and `history.open` use).
//! - A remove or clear from the page needs the person's gesture; with it,
//!   a location row removes every entry of its place, a command row is
//!   deleted from the command store, and Clear covers both kinds.
//! - The first write adopts the app's older `history.trail` document
//!   without its incognito entries.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};
use sha2::Digest;
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest};

const KEY_HEX: &str = "0f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0";
const INSTALL_ID: &str = "inst_history_trail";
const HISTORY_ORIGIN: &str = "cmux-page://cmux.history";

struct Owner {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Owner {
    /// An owner with the app's install key and the History page's
    /// WebSocket listener.
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-ht-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let owner = Self { socket: dir.join("mux.sock"), session: format!("ht-{name}"), dir };
        let mut child = owner
            .command("ensure")
            .args(["--install-key-stdin", "--ws-loopback", "--ws-allow-origin", HISTORY_ORIGIN])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL_ID} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output: Output = child.wait_with_output().unwrap();
        assert!(output.status.success(), "ensure: {}", String::from_utf8_lossy(&output.stderr));
        owner
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

    /// `cmux --json --socket <owner> <args>`; the parsed output.
    fn cli(&self, args: &[&str]) -> Value {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--json", "--socket"])
            .arg(&self.socket)
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap();
        assert!(output.status.success(), "{args:?}: {}", String::from_utf8_lossy(&output.stderr));
        serde_json::from_slice(&output.stdout).unwrap()
    }

    /// A connection with no hello: origin agent.
    fn agent(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        Client { reader: BufReader::new(stream), next: 100 }
    }

    /// The verified cmux app connection (install-key hello).
    fn app(&self) -> Client {
        let mut client = self.agent();
        let challenge =
            client.rpc(json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL_ID}));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL_ID, &nonce);
        let proved =
            client.rpc(json!({"cmd": "client-hello", "install_id": INSTALL_ID, "proof": proof}));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        client
    }

    /// The History page's relay connection and its id.
    fn relay(&self) -> (Client, String) {
        let mut relay = self.agent();
        let hello =
            relay.rpc(json!({"cmd": "client-hello", "role": "page_relay", "page": "history"}));
        assert_eq!(hello["ok"], true, "{hello}");
        let id = hello["data"]["connection_id"].as_str().unwrap().to_owned();
        (relay, id)
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
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.command("stop").arg("--end-terminals").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// Sends a raw command with a fresh id; the reply with that id.
    fn rpc(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        self.reply(&json!(self.next))
    }

    fn reply(&mut self, id: &Value) -> Value {
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply.get("event").is_none() && &reply["id"] == id {
                return reply;
            }
        }
    }

    /// A `cmux.protocol/2` request (selectors current); `extra` adds
    /// envelope members.
    fn v2(&mut self, operation: &str, params: Value, extra: Value) -> Value {
        self.next += 1;
        let request = request(&format!("v2-{}", self.next), operation, params, extra);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        self.reply(&request["id"])
    }
}

fn request(id: &str, operation: &str, params: Value, extra: Value) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": id,
        "operation": operation, "params": params,
    });
    for (key, value) in extra.as_object().unwrap() {
        request[key] = value.clone();
    }
    request
}

fn ok(reply: &Value) -> &Value {
    assert_eq!(reply["ok"], true, "{reply}");
    &reply["result"]
}

fn refusal(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    reply["error"]["details"]["reason"].as_str().unwrap_or_default()
}

/// The token the verified app mints for one relay request: `operation` with
/// exactly `params` (plus the host's `current` selectors) on `relay_id`.
fn confirmation(app: &mut Client, relay_id: &str, operation: &str, params: &Value) -> String {
    let mut sorted: std::collections::BTreeMap<String, Value> =
        params.as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    sorted.insert("machine".into(), json!("current"));
    sorted.insert("session".into(), json!("current"));
    let digest = sha2::Sha256::digest(serde_json::to_string(&sorted).unwrap().as_bytes());
    let digest: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    let issued = app.v2(
        "origin.confirmation.issue",
        json!({"operation": operation, "params_sha256": digest, "relay_connection_id": relay_id}),
        json!({}),
    );
    ok(&issued)["token"].as_str().unwrap().to_owned()
}

/// A gesture-confirmed relay request (the person clicked).
fn with_gesture(
    app: &mut Client,
    relay: &mut Client,
    relay_id: &str,
    operation: &str,
    params: Value,
    key: &str,
) -> Value {
    let token = confirmation(app, relay_id, operation, &params);
    let extra = json!({"idempotency_key": key, "origin": {"claim": "user", "confirmation": token}});
    relay.v2(operation, params, extra)
}

/// A terminal tab's place in workspace `workspace`.
fn location(tab: &str, title: &str, workspace: &str) -> Value {
    json!({"machine": "local", "tab": tab, "title": title, "workspace": workspace,
           "workspace_title": format!("{workspace} name"), "content": "terminal", "cwd": "/tmp"})
}

/// One step at `at_ms` (the app's clock) in window `window`.
fn step(window: &str, location: Value, at_ms: u64) -> Value {
    json!({"window": window, "location": location, "at_ms": at_ms.to_string()})
}

fn record(app: &mut Client, key: &str, params: Value) -> Value {
    ok(&app.v2("history.trail.record", params, json!({"idempotency_key": key})))["value"].clone()
}

/// The rows of `kinds` the History page's relay lists.
fn rows(relay: &mut Client, kinds: &[&str]) -> Vec<Value> {
    let reply = relay.v2("history.entries.list", json!({"kinds": kinds}), json!({}));
    ok(&reply)["entries"].as_array().unwrap_or_else(|| panic!("{reply}")).clone()
}

fn field(rows: &[Value], name: &str) -> Vec<String> {
    rows.iter().map(|row| row[name].as_str().unwrap_or_default().to_owned()).collect()
}

/// Runs `echo <marker>` in a new terminal and waits until the command
/// store holds a row for it (recording is on).
fn run_commands(owner: &Owner, app: &mut Client, markers: &[&str]) -> Vec<Value> {
    let set = app.rpc(json!({"cmd": "set-terminal-command-history", "enabled": true}));
    assert_eq!(set["ok"], true, "{set}");
    // A new workspace starts with a terminal; else a terminal tab is added.
    let created = owner.cli(&["workspace", "create", "--name", "trail"]);
    let terminal = match created["value"]["terminal_id"].as_str() {
        Some(terminal) => terminal.to_owned(),
        None => owner.cli(&["tab", "create", "terminal"])["value"]["terminal_id"]
            .as_str()
            .unwrap_or_else(|| panic!("no terminal: {created}"))
            .to_owned(),
    };
    for marker in markers {
        owner.cli(&["terminal", &terminal, "write", "--text", &format!("echo {marker}\n")]);
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let listed = app.rpc(json!({"cmd": "list-terminal-commands"}));
        let found: Vec<Value> = listed["data"]["commands"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|row| {
                markers.iter().any(|marker| row["command"] == format!("echo {marker}").as_str())
            })
            .collect();
        if found.len() == markers.len() {
            return found;
        }
        assert!(Instant::now() < deadline, "commands were never recorded: {listed}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn the_history_page_lists_removes_and_clears_trail_and_command_rows() {
    let owner = Owner::start("rows");
    let mut app = owner.app();

    // An agent never adds a step.
    let refused = owner.agent().v2(
        "history.trail.record",
        json!({"window": "w1", "location": location("tab_a", "Alpha", "ws-1")}),
        json!({"idempotency_key": "agent-1"}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["code"], "origin.forbidden", "{refused}");
    assert_eq!(refused["error"]["details"]["required"], "user", "{refused}");

    // The app records steps; the daemon runs the app's step rules: a
    // refresh keeps the entry, another tab of the newest entry's workspace
    // replaces its place, a quick pass (under 750 ms) is dropped, an
    // incognito step is never stored.
    let at = 1_800_000_000_000_u64;
    let first = record(&mut app, "r1", step("w1", location("tab_a", "Alpha", "ws-1"), at));
    assert_eq!(first, json!({"id": "location:1", "recorded": true}));
    record(&mut app, "r2", step("w1", location("tab_b", "Beta", "ws-2"), at + 10_000));
    let refreshed =
        record(&mut app, "r3", step("w1", location("tab_b", "Beta 2", "ws-2"), at + 20_000));
    assert_eq!(refreshed, json!({"id": "location:2", "recorded": true}));
    let same_workspace =
        record(&mut app, "r4", step("w2", location("tab_c", "Gamma", "ws-2"), at + 30_000));
    assert_eq!(same_workspace, json!({"id": "location:2", "recorded": true}));
    let passed =
        record(&mut app, "r5", step("w2", location("tab_d", "Delta", "ws-3"), at + 40_000));
    assert_eq!(passed, json!({"id": "location:3", "recorded": true}));
    let quick = record(&mut app, "r6", step("w2", location("tab_e", "Echo", "ws-4"), at + 40_100));
    assert_eq!(quick, json!({"id": "location:4", "recorded": true}));
    let mut every = step("w2", location("tab_f", "Fox", "ws-4"), at + 50_000);
    every["steps"] = json!("everything");
    let fox = record(&mut app, "r7", every);
    assert_eq!(fox, json!({"id": "location:5", "recorded": true}));
    // A jump to another tab of the same workspace is its own step (Swift
    // recordJump never replaces the sidebar item's entry).
    let mut jump = step("w2", location("tab_g", "Golf", "ws-4"), at + 55_000);
    jump["jump"] = json!(true);
    assert_eq!(record(&mut app, "r7j", jump), json!({"id": "location:6", "recorded": true}));
    let mut secret = step("w3", location("tab_s", "Secret", "ws-9"), at + 60_000);
    secret["incognito"] = json!(true);
    assert_eq!(record(&mut app, "r8", secret), json!({"recorded": false}));

    // The History page lists them, newest first, with window and place.
    let (mut relay, relay_id) = owner.relay();
    let locations = rows(&mut relay, &["location"]);
    assert_eq!(
        field(&locations, "id"),
        ["location:6", "location:5", "location:4", "location:2", "location:1"],
        "{locations:?}"
    );
    assert_eq!(field(&locations, "title"), ["Golf", "Fox", "Echo", "Gamma", "Alpha"]);
    assert_eq!(
        field(&locations, "detail"),
        ["ws-4 name", "ws-4 name", "ws-4 name", "ws-2 name", "ws-1 name"]
    );
    assert_eq!(locations[0]["current"], true, "{locations:?}");
    assert_eq!(locations[1]["current"], false, "{locations:?}");
    assert_eq!(locations[3]["window"], "w2", "{locations:?}");
    assert_eq!(locations[3]["location"]["tab"], "tab_c", "{locations:?}");
    assert_eq!(locations[3]["at_ms"], (at + 10_000).to_string(), "{locations:?}");

    // The same rows over the daemon WebSocket (a page in a plain browser).
    let (addr, token) = owner.listener();
    let socket_rows = page_websocket(
        &addr,
        &token,
        &request("ws", "history.entries.list", json!({"kinds": ["location"]}), json!({})),
    );
    assert_eq!(
        field(socket_rows["result"]["entries"].as_array().unwrap(), "id"),
        field(&locations, "id")
    );

    // Command rows are this machine's terminal command rows.
    let stored = run_commands(&owner, &mut app, &["trail_one", "trail_two"]);
    let commands = rows(&mut relay, &["command"]);
    let mut ids = field(&commands, "id");
    ids.sort();
    let mut expected: Vec<String> =
        stored.iter().map(|row| format!("command:local/{}", row["id"].as_str().unwrap())).collect();
    expected.sort();
    assert_eq!(ids, expected, "{commands:?}");
    let one = commands.iter().find(|row| row["title"] == "echo trail_one").unwrap();
    assert_eq!(one["command"], "echo trail_one", "{one}");
    let one_id = one["id"].as_str().unwrap().to_owned();

    // A remove without the person's gesture is refused.
    let remove = json!({"ids": ["location:2", one_id]});
    let refused =
        relay.v2("history.entries.remove", remove.clone(), json!({"idempotency_key": "x1"}));
    assert_eq!(refusal(&refused), "gesture_required");

    // With it: the location's place goes, the command row is deleted in
    // the command store (the Swift Commands list reads the same rows).
    let removed =
        with_gesture(&mut app, &mut relay, &relay_id, "history.entries.remove", remove, "x2");
    assert_eq!(ok(&removed)["value"]["removed"], 2, "{removed}");
    let left = rows(&mut relay, &["location"]);
    assert_eq!(
        field(&left, "id"),
        ["location:6", "location:5", "location:4", "location:1"],
        "{left:?}"
    );
    let left = app.rpc(json!({"cmd": "list-terminal-commands"}));
    let left_ids: Vec<&str> = left["data"]["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap())
        .collect();
    assert!(!left_ids.contains(&one_id.trim_start_matches("command:local/")), "{left}");
    assert_eq!(rows(&mut relay, &["command"]).len(), 1);

    // Clear covers the trail and the command rows, as the Swift page does.
    let clear = json!({"range": "all", "kinds": ["location", "command"]});
    let refused = relay.v2("history.clear", clear.clone(), json!({"idempotency_key": "c1"}));
    assert_eq!(refusal(&refused), "gesture_required");
    let cleared = with_gesture(&mut app, &mut relay, &relay_id, "history.clear", clear, "c2");
    assert_eq!(ok(&cleared)["value"]["removed"], 5, "{cleared}");
    assert_eq!(rows(&mut relay, &["location", "command"]), Vec::<Value>::new());
}

#[test]
fn the_first_write_adopts_the_apps_older_trail_without_incognito_steps() {
    let owner = Owner::start("adopt");
    let mut app = owner.app();
    let legacy = |tab: &str, title: &str, incognito: bool, entered: f64| {
        json!({"enteredAt": entered, "location": {
            "key": {"machine": "local", "tab": tab}, "window": "w9", "workspace": "ws",
            "pane": "p", "content": "terminal", "title": title, "isIncognito": incognito}})
    };
    let put = app.rpc(json!({
        "cmd": "put-frontend-projection", "frontend": "cmux-next", "scope": "personal",
        "subject_key": "history.trail", "schema_version": 1, "origin": "test",
        "mutation_id": "legacy-trail",
        "projection": {"entries": [
            legacy("tab_old", "Old", false, 800_000_000.0),
            legacy("tab_private", "Private", true, 800_000_010.0),
            legacy("tab_new", "New", false, 800_000_020.0),
        ], "cursor": 2},
    }));
    assert_eq!(put["ok"], true, "{put}");

    let (mut relay, _) = owner.relay();
    let listed = rows(&mut relay, &["location"]);
    assert_eq!(field(&listed, "title"), ["New", "Old"], "{listed:?}");
    // 2001-01-01 + 800,000,000 s, in Unix milliseconds.
    assert_eq!(listed[1]["at_ms"], "1778307200000", "{listed:?}");
    let next = record(
        &mut app,
        "a1",
        json!({"window": "w9", "location": location("tab_x", "Next", "ws-x")}),
    );
    assert_eq!(next, json!({"id": "location:3", "recorded": true}));
    let listed = rows(&mut relay, &["location"]);
    assert_eq!(field(&listed, "title"), ["Next", "New", "Old"], "{listed:?}");
}

/// One request on a History page WebSocket; its reply.
fn page_websocket(addr: &str, token: &str, request: &Value) -> Value {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut handshake = format!("ws://{addr}/").into_client_request().unwrap();
    handshake.headers_mut().insert("Origin", HISTORY_ORIGIN.parse().unwrap());
    let (mut socket, _) = tungstenite::client(handshake, stream).unwrap();
    socket.send(Message::Text(json!({"auth": {"token": token}}).to_string().into())).unwrap();
    socket.send(Message::Text(request.to_string().into())).unwrap();
    loop {
        match socket.read().unwrap() {
            Message::Text(text) => {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value.get("event").is_none() && value["id"] == request["id"] {
                    return value;
                }
            }
            Message::Close(frame) => panic!("closed: {frame:?}"),
            _ => {}
        }
    }
}
