//! `cmux chief` against a real headless daemon: the CLI, a stand-in for the
//! Chief's brain (bound as `agent_mux`) and a stand-in for Home (a second
//! `user_local` client) share one conversation in the daemon.

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

    fn line(&mut self) -> Value {
        let mut line = String::new();
        assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the connection");
        serde_json::from_str(&line).unwrap()
    }

    fn request(&mut self, cmd: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = params.as_object().cloned().unwrap_or_default();
        body.insert("id".into(), json!(id));
        body.insert("cmd".into(), json!(cmd));
        writeln!(self.writer, "{}", Value::Object(body)).unwrap();
        loop {
            let value = self.line();
            if value.get("event").is_some() {
                self.events.push_back(value);
                continue;
            }
            if value["id"] == id {
                assert_eq!(value["ok"], true, "{cmd} failed: {value}");
                return value["data"].clone();
            }
        }
    }

    fn event(&mut self) -> Value {
        self.events.pop_front().unwrap_or_else(|| loop {
            let value = self.line();
            if value.get("event").is_some() {
                break value;
            }
        })
    }
}

/// The Chief conversation the app makes when Home opens.
fn chief_conversation(home: &mut Conn) -> String {
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": "chief-test", "actor": "user_local", "title": "Chief",
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": "agent_mux", "kind": "agent", "display_name": "mux", "agent_class": "mux"}]}),
    );
    created["conversation"]["id"].as_str().unwrap().to_owned()
}

fn text_of(message: &Value) -> &str {
    message["parts"][0]["text"].as_str().unwrap_or("")
}

/// A brain that answers each `user_local` message as the Chief does: cursor,
/// typing on, the reply, typing off. When `busy`, it is already in a turn
/// (typing on) and stops it for the new message first.
fn fake_brain(
    socket: PathBuf,
    conversation: String,
    token: String,
    busy: bool,
) -> std::thread::JoinHandle<()> {
    let (ready_tx, ready_rx) = mpsc::channel();
    let brain = std::thread::spawn(move || {
        let mut brain = Conn::open(&socket);
        brain.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
        brain.request("subscribe", json!({}));
        let typing = |brain: &mut Conn, on: bool| {
            brain.request("conversation-typing", json!({"conversation": conversation, "on": on}));
        };
        if busy {
            typing(&mut brain, true);
        }
        ready_tx.send(()).unwrap();
        loop {
            let event = brain.event();
            let message = &event["change"]["message"];
            if event["event"] != "conversation-changed"
                || event["change"]["kind"] != "message"
                || message["author"] != "user_local"
            {
                continue;
            }
            let seq = message["seq"].as_u64().unwrap();
            let text = text_of(message).to_owned();
            if busy {
                typing(&mut brain, false);
            }
            let op = |kind: Value, key: String| json!({"conversation": conversation, "idempotency_key": key, "op": kind});
            brain.request("conversation-op", op(json!({"kind": "read_cursor.set", "seq": seq}), format!("cursor:{seq}")));
            typing(&mut brain, true);
            let key = format!("turn:optchat:{seq}");
            brain.request(
                "conversation-op",
                op(json!({"kind": "message.send", "client_msg_id": key, "parts": [{"type": "text", "text": format!("echo: {text}")}]}), key.clone()),
            );
            typing(&mut brain, false);
            return;
        }
    });
    ready_rx.recv_timeout(Duration::from_secs(20)).expect("the fake brain did not start");
    brain
}

fn chief_cli(server: &HeadlessServer, args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(bin())
        .arg("--socket")
        .arg(&server.socket)
        .arg("chief")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    rx.recv_timeout(Duration::from_secs(60)).expect("cmux chief did not exit").unwrap()
}

fn run_turn(busy: bool, args: &[&str], stdin: &str) -> (Output, Vec<Value>) {
    let server = HeadlessServer::start("chief-pipe");
    let mut home = Conn::open(&server.socket);
    let conversation = chief_conversation(&mut home);
    let token = home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
        .as_str()
        .unwrap()
        .to_owned();
    home.request("subscribe", json!({}));
    let brain = fake_brain(server.socket.clone(), conversation.clone(), token, busy);
    let output = chief_cli(&server, args, stdin);
    brain.join().unwrap();
    // What Home saw, in order: every message of the conversation.
    let mut seen = Vec::new();
    while seen.len() < 2 {
        let event = home.event();
        if event["event"] == "conversation-changed" && event["change"]["kind"] == "message" {
            seen.push(event["change"]["message"].clone());
        }
    }
    (output, seen)
}

#[test]
fn chief_pipe_sends_as_the_person_and_prints_the_reply_at_turn_end() {
    let (output, home_saw) = run_turn(false, &["-p", "status?"], "");
    assert_success(&output);
    assert_eq!(String::from_utf8_lossy(&output.stdout), "echo: status?\n");
    // Home shows the CLI's message as the person's, then the Chief's reply.
    assert_eq!(home_saw[0]["author"], "user_local");
    assert_eq!(text_of(&home_saw[0]), "status?");
    assert_eq!(home_saw[1]["author"], "agent_mux");
    assert_eq!(text_of(&home_saw[1]), "echo: status?");
}

#[test]
fn chief_pipe_reads_stdin_and_waits_through_a_turn_it_interrupted() {
    let (output, _) = run_turn(true, &["--json"], "from stdin\n");
    assert_success(&output);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<Value> = stdout.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{stdout}");
    assert_eq!(lines[0]["author"], "agent_mux");
    assert_eq!(text_of(&lines[0]), "echo: from stdin");
}

#[test]
fn chief_without_a_chief_conversation_says_how_to_get_one() {
    let server = HeadlessServer::start("chief-none");
    let output = chief_cli(&server, &["-p", "hi"], "");
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("no Chief conversation"));
}
