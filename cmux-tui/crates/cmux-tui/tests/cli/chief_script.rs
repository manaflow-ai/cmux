//! The scriptable `cmux chief` verbs (plans/cmux-next/chief-tui.md) against a
//! real headless daemon: a coding agent reads and drives Chief/Home chats
//! with no terminal. `chats`, `send --wait`, `wait`, `read`, `react`,
//! `send --reply-to`, `send --thread`, `read --thread`, `send --attach` and
//! `--chat` on a second Chief's chat; and `--cloud` through the daemon's cloud
//! proxy with the CLI's own lease (a loopback stand-in for the cloud).

use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use super::*;
use serde_json::{Value, json};

/// A daemon with the Chief conversation and its agent token.
fn chief_daemon(name: &str) -> (HeadlessServer, Conn, String, String) {
    let server = HeadlessServer::start(name);
    let mut home = Conn::open(&server.socket);
    let conversation = chief_conversation(&mut home);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    (server, home, conversation, token)
}

/// `cmux chief ARGS`'s stdout as one JSON value, after asserting success.
fn json_of(output: &Output) -> Value {
    assert_success(output);
    let stdout = String::from_utf8_lossy(&output.stdout);
    serde_json::from_str(stdout.trim()).unwrap_or_else(|e| panic!("not JSON ({e}): {stdout}"))
}

/// One turn: `send TEXT --wait --json` answered by the fake brain.
fn one_turn(server: &HeadlessServer, conversation: &str, token: &str, text: &str) -> Value {
    let brain = fake_brain(server.socket.clone(), conversation.into(), token.into(), false);
    let sent =
        json_of(&chief_cli(server, &["send", text, "--wait", "--json", "--timeout", "40"], ""));
    brain.join().unwrap();
    sent
}

#[test]
fn chief_script_send_wait_prints_the_reply_and_read_shows_both() {
    let (server, _home, conversation, token) = chief_daemon("chief-script-send");
    let sent = one_turn(&server, &conversation, &token, "status?");
    assert_eq!(sent["seq"], 1, "{sent}");
    assert_eq!(sent["conversation"], conversation.as_str());
    let replies = sent["replies"].as_array().unwrap();
    assert_eq!(replies.len(), 1, "{sent}");
    assert_eq!(replies[0]["author"], "agent_mux");
    assert_eq!(replies[0]["text"], "echo: status?");

    let read = json_of(&chief_cli(&server, &["read", "--last", "5", "--json"], ""));
    let texts: Vec<&str> =
        read.as_array().unwrap().iter().map(|m| m["text"].as_str().unwrap()).collect();
    assert_eq!(texts, vec!["status?", "echo: status?"]);

    // Plain text names each message by #SEQ, as the chat does.
    let plain = chief_cli(&server, &["read"], "");
    assert_success(&plain);
    let stdout = String::from_utf8_lossy(&plain.stdout);
    assert!(stdout.contains("#1") && stdout.contains("#2"), "{stdout}");
    assert!(stdout.contains("echo: status?"), "{stdout}");
}

#[test]
fn chief_script_wait_returns_the_chiefs_next_message() {
    let (server, _home, conversation, token) = chief_daemon("chief-script-wait");
    // The wait starts first; the message and the reply come after it.
    let socket = server.socket.clone();
    let waiter = std::thread::spawn(move || {
        Command::new(bin())
            .arg("--socket")
            .arg(&socket)
            .args(["chief", "wait", "--after", "0", "--from", "chief", "--timeout", "40", "--json"])
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("ACPMUX_ENV")
            .env_remove("CMUX_AGENT_PRINCIPAL")
            .output()
            .unwrap()
    });
    // With --after 0 the wait cannot miss a reply that comes before its stream opens.
    let brain = fake_brain(server.socket.clone(), conversation, token, false);
    assert_success(&chief_cli(&server, &["send", "ping"], ""));
    brain.join().unwrap();
    let found = json_of(&waiter.join().unwrap());
    assert_eq!(found["author"], "agent_mux", "{found}");
    assert_eq!(found["text"], "echo: ping");

    // A message that is already there answers at once with --after.
    let again =
        json_of(&chief_cli(&server, &["wait", "--after", "0", "--from", "me", "--json"], ""));
    assert_eq!(again["text"], "ping");
    // Nothing matches: exit 124 after the timeout.
    let none = chief_cli(&server, &["wait", "--text", "never", "--timeout", "1"], "");
    assert_eq!(none.status.code(), Some(124), "{}", String::from_utf8_lossy(&none.stderr));
}

#[test]
fn chief_script_reacts_replies_and_threads_like_home() {
    let (server, mut home, conversation, token) = chief_daemon("chief-script-react");
    one_turn(&server, &conversation, &token, "plan?");

    // A tapback and an emoji on the Chief's reply (#2); Home sees them on the message.
    let liked = json_of(&chief_cli(&server, &["react", "#2", "like", "--json"], ""));
    assert_eq!(liked["reactions"][0]["kind"], json!({"tapback": "like"}), "{liked}");
    assert_eq!(liked["reactions"][0]["author"], "user_local");
    assert_success(&chief_cli(&server, &["react", "#2", "🎉"], ""));
    let snapshot =
        home.request("conversation-snapshot", json!({"conversation": conversation, "tail": 5}));
    let reply = &snapshot["messages"][1];
    assert_eq!(reply["reactions"].as_array().unwrap().len(), 2, "{reply}");
    let removed = json_of(&chief_cli(&server, &["react", "#2", "like", "--remove", "--json"], ""));
    assert_eq!(removed["reactions"].as_array().unwrap().len(), 1, "{removed}");

    // A quoted reply names its parent part.
    let quoted =
        json_of(&chief_cli(&server, &["send", "about this", "--reply-to", "#2", "--json"], ""));
    let read = json_of(&chief_cli(&server, &["read", "--last", "1", "--json"], ""));
    assert_eq!(read[0]["seq"], quoted["seq"]);
    assert_eq!(read[0]["reply_to"]["part_index"], 0);
    assert_eq!(read[0]["reply_to"]["message_id"], snapshot["messages"][1]["id"]);

    // A thread reply, then the thread.
    assert_success(&chief_cli(&server, &["send", "in the thread", "--thread", "#2"], ""));
    let thread = json_of(&chief_cli(&server, &["read", "--thread", "#2", "--json"], ""));
    let texts: Vec<&str> =
        thread.as_array().unwrap().iter().map(|m| m["text"].as_str().unwrap()).collect();
    assert_eq!(texts.first(), Some(&"echo: plan?"), "{thread}");
    assert_eq!(texts.last(), Some(&"in the thread"), "{thread}");

    // Edit and remove the person's own message.
    let edited = json_of(&chief_cli(&server, &["amend", "#1", "plan, please?", "--json"], ""));
    assert_eq!(edited["text"], "plan, please?");
    assert_success(&chief_cli(&server, &["retract", "#1"], ""));
    let first =
        json_of(&chief_cli(&server, &["read", "--before", "2", "--last", "1", "--json"], ""));
    assert!(first[0]["retracted_at"].is_string(), "{first}");

    // An unknown #SEQ is refused, not guessed.
    let missing = chief_cli(&server, &["react", "#99", "like"], "");
    assert_eq!(missing.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&missing.stderr).contains("#99"));
}

#[test]
fn chief_script_attach_uploads_the_file_and_sends_its_part() {
    let (server, mut home, conversation, _token) = chief_daemon("chief-script-attach");
    let file = server.dir.join("notes.txt");
    fs::write(&file, "three lines\nof notes\n").unwrap();
    let path = file.display().to_string();
    let sent =
        json_of(&chief_cli(&server, &["send", "see the file", "--attach", &path, "--json"], ""));
    let snapshot =
        home.request("conversation-snapshot", json!({"conversation": conversation, "tail": 1}));
    let message = &snapshot["messages"][0];
    assert_eq!(message["seq"], sent["seq"]);
    let parts = message["parts"].as_array().unwrap();
    assert_eq!(parts[0]["type"], "attachment", "{message}");
    assert_eq!(parts[0]["name"], "notes.txt");
    assert_eq!(parts[0]["mime_type"], "text/plain");
    assert_eq!(parts[0]["byte_count"], 21);
    assert_eq!(parts[1]["text"], "see the file");
    // The bytes are the file's.
    let read = home.request(
        "conversation-attachment-read",
        json!({"conversation": conversation, "hash": parts[0]["hash"], "offset": 0, "length": 64}),
    );
    let data = read["data"].as_str().unwrap_or_default();
    use base64::Engine as _;
    let bytes = base64::engine::general_purpose::STANDARD.decode(data).unwrap();
    assert_eq!(bytes, b"three lines\nof notes\n");
}

#[test]
fn chief_script_lists_chats_and_drives_another_chiefs_chat() {
    let (server, mut home, chief, _token) = chief_daemon("chief-script-chats");
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": "ops-chat", "actor": "user_local", "title": "Ops",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_01OPS", "kind": "agent", "display_name": "Ops", "agent_class": "mux"}]}),
    );
    let ops = created["conversation"]["id"].as_str().unwrap().to_owned();
    let rows = json_of(&chief_cli(&server, &["chats", "--json"], ""));
    let rows = rows.as_array().unwrap();
    assert_eq!(rows.len(), 2, "{rows:?}");
    let row = |id: &str| rows.iter().find(|r| r["id"] == id).unwrap().clone();
    assert_eq!(row(&chief)["default"], true);
    assert_eq!(row(&chief)["chief"], "agent_mux");
    assert_eq!(row(&ops)["chief"], "agent_01OPS");
    assert_eq!(row(&ops)["default"], false);

    // --chat by title or id; the default chat is untouched.
    let sent = json_of(&chief_cli(&server, &["send", "deploy?", "--chat", "Ops", "--json"], ""));
    assert_eq!(sent["conversation"], ops.as_str());
    let read = json_of(&chief_cli(&server, &["read", "--chat", &ops, "--json"], ""));
    assert_eq!(read[0]["text"], "deploy?");
    let default = json_of(&chief_cli(&server, &["read", "--json"], ""));
    assert_eq!(default, json!([]));
    // That chat's Chief is the one `wait` waits for: Ops answers, agent_mux would not count.
    let ops_token = home.request("conversation-agent-token", json!({"participant": "agent_01OPS"}))
        ["token"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut ops_brain = Conn::open(&server.socket);
    ops_brain
        .request("conversation-bind", json!({"participant": "agent_01OPS", "token": ops_token}));
    ops_brain.request(
        "conversation-op",
        json!({"conversation": ops, "idempotency_key": "ops-1",
               "op": {"kind": "message.send", "client_msg_id": "ops-1", "parts": [{"type": "text", "text": "shipped"}]}}),
    );
    let found =
        json_of(&chief_cli(&server, &["wait", "--chat", "Ops", "--after", "1", "--json"], ""));
    assert_eq!(found["author"], "agent_01OPS");
    assert_eq!(found["text"], "shipped");
    let marked = json_of(&chief_cli(&server, &["mark-read", "--chat", "Ops", "--json"], ""));
    assert_eq!(marked["seq"], 2, "the chat's last seq when it opened");

    let unknown = chief_cli(&server, &["read", "--chat", "Nope"], "");
    assert_eq!(unknown.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&unknown.stderr).contains("no chat Nope"));
}

/// A loopback stand-in for the cmux Cloud API: the inbox holds one Chief DM,
/// and every op is answered as a sent message. It records each request body.
struct FakeCloud {
    base: String,
    bodies: Arc<Mutex<Vec<Value>>>,
}

const CLOUD_CONV: &str = "conv_0123456789ABCDEFGHJKMNPQRS";
const CLOUD_CHIEF: &str = "agent_01M4X1B5362SM3QJVJ155DA0GB";

impl FakeCloud {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let seen = bodies.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let mut reader = BufReader::new(stream);
                let mut length = 0usize;
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        break;
                    }
                    if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap_or(0);
                    }
                    if line == "\r\n" {
                        break;
                    }
                }
                let mut body = vec![0; length];
                let body: Value = match reader.read_exact(&mut body) {
                    Ok(()) => serde_json::from_slice(&body).unwrap_or(Value::Null),
                    Err(_) => Value::Null,
                };
                seen.lock().unwrap().push(body.clone());
                let reply = if body["op"] == "inbox.list" {
                    json!({"ok": true, "revision": "1", "value": {"entries": [{
                        "conversation": CLOUD_CONV, "rev": 1, "kind": "dm", "title": "Cloud Chief",
                        "last_seq": 3, "unread": 1, "dm_peer": CLOUD_CHIEF}]}})
                } else {
                    let message = json!({"id": "msg_0123456789ABCDEFGHJKMNPQRS", "conversation": CLOUD_CONV,
                        "seq": 4, "client_msg_id": "k", "author": "user_00000000000000000001",
                        "parts": [{"type": "text", "text": "hi cloud"}], "created_at": "2026-10-23T00:00:00.000Z",
                        "reactions": []});
                    json!({"ok": true, "op": "message.send", "revision": "2", "transaction": "tx-1",
                        "replayed": false, "stream": format!("conv:{CLOUD_CONV}"), "sequence": 4,
                        "value": {"rev": 2, "seq": 4, "change": {"kind": "message", "message": message}}})
                }
                .to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                let _ = reader.get_mut().write_all(response.as_bytes());
            }
        });
        Self { base, bodies }
    }

    fn bodies(&self) -> Vec<Value> {
        self.bodies.lock().unwrap().clone()
    }
}

/// A daemon started as the app starts it (`server ensure`), which has the
/// cloud proxy (`cloud-conversations-v1`); a bare `--headless` owner has none.
struct EnsuredDaemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl EnsuredDaemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-cs-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let daemon = Self { socket: dir.join("mux.sock"), session: format!("cs-{name}"), dir };
        let output = daemon.server("ensure").output().unwrap();
        assert!(
            output.status.success(),
            "ensure failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        daemon
    }

    fn server(&self, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .stdin(Stdio::null());
        command
    }

    fn chief(&self, args: &[&str]) -> Output {
        let mut command = Command::new(bin());
        command.arg("--socket").arg(&self.socket).arg("chief").args(args).env("LC_ALL", "C");
        for key in
            ["CMUX_TUI_SOCKET", "ACPMUX_ENV", "CMUX_AGENT_PRINCIPAL", "CMUX_CHIEF_OWNER_SOCKET"]
        {
            command.env_remove(key);
        }
        command.stdin(Stdio::null()).output().unwrap()
    }
}

impl Drop for EnsuredDaemon {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn chief_script_cloud_chats_use_the_clis_own_lease_and_send_as_cli() {
    let daemon = EnsuredDaemon::start("cloud");
    let cloud = FakeCloud::start();
    let token = daemon.dir.join("cloud.token");
    fs::write(&token, "cli.jwt\n").unwrap();
    let token = token.display().to_string();
    let rows = json_of(&daemon.chief(&[
        "chats",
        "--cloud-api",
        &cloud.base,
        "--cloud-token-file",
        &token,
        "--json",
    ]));
    assert_eq!(rows[0]["id"], CLOUD_CONV, "{rows}");
    assert_eq!(rows[0]["owner"], "cloud");
    assert_eq!(rows[0]["chief"], CLOUD_CHIEF, "a Chief DM's Chief is its peer");
    assert_eq!(rows[0]["unread"], 1);
    assert_eq!(rows[0]["default"], true);

    // The lease stays on this daemon (no app holds one); a send needs only --cloud.
    let sent = json_of(&daemon.chief(&["send", "hi cloud", "--cloud", "--json"]));
    assert_eq!(sent["seq"], 4, "{sent}");
    assert_eq!(sent["conversation"], CLOUD_CONV);
    let ops: Vec<Value> =
        cloud.bodies().into_iter().filter(|b| b.to_string().contains("message.send")).collect();
    assert_eq!(ops.len(), 1, "{:?}", cloud.bodies());
    assert_ne!(ops[0]["origin"], "user", "the CLI never speaks with the app's user origin");
}
