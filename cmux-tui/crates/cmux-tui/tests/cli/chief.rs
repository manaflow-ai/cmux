//! `cmux chief` against a real headless daemon: the CLI, a stand-in for the
//! Chief's brain (bound as `agent_mux`) and a stand-in for Home (a second
//! `user_local` client) share one conversation in the daemon.

use super::*;
use serde_json::{Value, json};

#[path = "chief_autostart.rs"]
mod autostart;

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
        self.events.pop_front().unwrap_or_else(|| {
            loop {
                let value = self.line();
                if value.get("event").is_some() {
                    break value;
                }
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
            brain.request(
                "conversation-op",
                op(json!({"kind": "read_cursor.set", "seq": seq}), format!("cursor:{seq}")),
            );
            typing(&mut brain, true);
            let key = format!("turn:optchat:{seq}");
            brain.request(
                "conversation-op",
                op(json!({"kind": "message.send", "client_msg_id": key, "parts": [{"type": "text", "text": format!("echo: {text}")}]}), key),
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
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    home.request("subscribe", json!({}));
    let brain = fake_brain(server.socket.clone(), conversation, token, busy);
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

impl Conn {
    /// A request that must fail; the refusal.
    fn refused(&mut self, cmd: &str, params: Value) -> String {
        self.attempt(cmd, params).unwrap_or_else(|| panic!("{cmd} was accepted"))
    }

    /// A request; `None` when it was accepted, else the refusal.
    fn attempt(&mut self, cmd: &str, params: Value) -> Option<String> {
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
                return (value["ok"] != true).then(|| value.to_string());
            }
        }
    }

    /// The next `user_local` message the conversation gets.
    fn person_message(&mut self) -> Value {
        loop {
            let event = self.event();
            if event["event"] == "conversation-changed"
                && event["change"]["kind"] == "message"
                && event["change"]["message"]["author"] == "user_local"
            {
                return event["change"]["message"].clone();
            }
        }
    }
}

/// A brain connection bound as `agent_mux`, subscribed.
fn bound_brain(socket: &std::path::Path, token: &str) -> Conn {
    let mut brain = Conn::open(socket);
    brain.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    brain.request("subscribe", json!({}));
    brain
}

fn typing(brain: &mut Conn, conversation: &str, on: bool) {
    brain.request("conversation-typing", json!({"conversation": conversation, "on": on}));
}

/// The brain's reply op: `parts`, the ids it answers and those still pending.
/// The owner holds agent messages to a minimum gap (`agent_rate`); like the
/// brain, the stand-in retries under the same key.
fn reply(
    brain: &mut Conn,
    conversation: &str,
    key: &str,
    parts: Value,
    answers: &[&str],
    pending: &[&str],
) {
    let params = json!({"conversation": conversation, "idempotency_key": key,
           "op": {"kind": "message.send", "client_msg_id": key, "parts": parts,
                  "answers": answers, "answers_pending": pending}});
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let refused = brain.attempt("conversation-op", params.clone());
        match refused {
            None => return,
            Some(why) if why.contains("agent_rate") && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(200));
            }
            Some(why) => panic!("reply {key} refused: {why}"),
        }
    }
}

fn text_parts(text: &str) -> Value {
    json!([{"type": "text", "text": text}])
}

/// A headless daemon with the Chief conversation; (server, home, conversation, brain token).
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

/// E22 (run5, claude-sr): a message that arrives while the Chief answers an
/// earlier one waits for the reply that names it in `answers`, not for the
/// end of the running turn. The owner keeps `answers`, a reply with them
/// meets the catalog when the CLI reads the conversation, and a malformed
/// list is refused.
#[test]
fn chief_pipe_waits_past_a_turn_that_answers_other_messages() {
    let (server, mut home, conversation, token) = chief_daemon("chief-answers");
    let (busy_tx, busy_rx) = mpsc::channel();
    let socket = server.socket.clone();
    let conv = conversation.clone();
    let brain = std::thread::spawn(move || {
        let mut brain = bound_brain(&socket, &token);
        busy_tx.send(()).unwrap();
        // An earlier question, already answered: the CLI's first read holds a
        // reply with `answers`.
        let first = brain.person_message();
        let first_id = first["id"].as_str().unwrap().to_owned();
        reply(&mut brain, &conv, "turn:optchat:1", text_parts("old answer"), &[&first_id], &[]);
        let refused = brain.refused(
            "conversation-op",
            json!({"conversation": conv, "idempotency_key": "turn:bad",
                   "op": {"kind": "message.send", "client_msg_id": "turn:bad",
                          "parts": [{"type": "text", "text": "x"}],
                          "answers": [first_id], "answers_pending": ["msg_other"]}}),
        );
        assert!(refused.contains("invalid_parts"), "{refused}");
        // The next question starts a turn that runs while the CLI sends.
        let second = brain.person_message();
        let second_id = second["id"].as_str().unwrap().to_owned();
        typing(&mut brain, &conv, true);
        busy_tx.send(()).unwrap();
        let mine = brain.person_message();
        let mine_id = mine["id"].as_str().unwrap().to_owned();
        let seq = mine["seq"].as_u64().unwrap();
        // Read while the turn runs, but that turn's reply answers `second`.
        brain.request(
            "conversation-op",
            json!({"conversation": conv, "idempotency_key": format!("cursor:{seq}"),
                   "op": {"kind": "read_cursor.set", "seq": seq}}),
        );
        reply(
            &mut brain,
            &conv,
            "turn:optchat:2",
            text_parts("for the second"),
            &[&second_id],
            &[],
        );
        typing(&mut brain, &conv, false);
        typing(&mut brain, &conv, true);
        reply(&mut brain, &conv, "turn:optchat:3", text_parts("for mine"), &[&mine_id], &[]);
        typing(&mut brain, &conv, false);
    });
    busy_rx.recv_timeout(Duration::from_secs(20)).unwrap();
    let send = |home: &mut Conn, key: &str, text: &str| {
        home.request(
            "conversation-op",
            json!({"conversation": conversation, "idempotency_key": key, "actor": "user_local",
                   "op": {"kind": "message.send", "client_msg_id": key, "parts": text_parts(text)}}),
        );
    };
    send(&mut home, "home-1", "first question");
    send(&mut home, "home-2", "second question");
    busy_rx.recv_timeout(Duration::from_secs(20)).unwrap();
    let output = chief_cli(&server, &["-p", "my question"], "");
    brain.join().unwrap();
    assert_success(&output);
    assert_eq!(String::from_utf8_lossy(&output.stdout), "for mine\n");
}

/// Wait-agents: pipe mode waits while a reply says the subagents its message
/// started still work, through the turns their reports cause, and ends with
/// the turn that closes that work even when it posts only a done marker.
/// `--no-wait-agents` ends with the first turn that answers it.
#[test]
fn chief_pipe_waits_for_the_subagents_its_message_started() {
    for (wait, expected) in [(true, 3usize), (false, 1usize)] {
        let (server, _home, conversation, token) = chief_daemon("chief-agents");
        let (ready_tx, ready_rx) = mpsc::channel();
        let socket = server.socket.clone();
        let conv = conversation.clone();
        let brain = std::thread::spawn(move || {
            let mut brain = bound_brain(&socket, &token);
            ready_tx.send(()).unwrap();
            let mine = brain.person_message();
            let id = mine["id"].as_str().unwrap().to_owned();
            let seq = mine["seq"].as_u64().unwrap();
            brain.request(
                "conversation-op",
                json!({"conversation": conv, "idempotency_key": format!("cursor:{seq}"),
                       "op": {"kind": "read_cursor.set", "seq": seq}}),
            );
            typing(&mut brain, &conv, true);
            reply(&mut brain, &conv, "turn:a", text_parts("a1 and a2 started"), &[&id], &[&id]);
            typing(&mut brain, &conv, false);
            typing(&mut brain, &conv, true);
            reply(&mut brain, &conv, "turn:b", text_parts("a1 reported"), &[&id], &[&id]);
            typing(&mut brain, &conv, false);
            typing(&mut brain, &conv, true);
            let marker = json!([{"type": "work", "session": "optchat-turn-3", "status": "done"}]);
            reply(&mut brain, &conv, "turn:c", marker, &[&id], &[]);
            typing(&mut brain, &conv, false);
        });
        ready_rx.recv_timeout(Duration::from_secs(20)).unwrap();
        let args: &[&str] = if wait {
            &["--json", "-p", "start two"]
        } else {
            &["--json", "--no-wait-agents", "-p", "start two"]
        };
        let output = chief_cli(&server, args, "");
        brain.join().unwrap();
        assert_success(&output);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<Value> = stdout.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines.len(), expected, "wait-agents {wait}: {stdout}");
        assert_eq!(text_of(&lines[0]), "a1 and a2 started");
        if wait {
            assert_eq!(text_of(&lines[1]), "a1 reported");
            assert_eq!(lines[2]["parts"][0]["status"], "done");
        }
    }
}

/// E20: `cmux chief shutdown` sends SIGTERM to the brain that holds the
/// home's host lock and returns once the lock is free.
#[test]
fn chief_shutdown_stops_the_brain_that_holds_the_home_lock() {
    let home = unique_temp_dir("chief-shutdown");
    fs::create_dir_all(home.join("state")).unwrap();
    let lock = home.join("state/host.lock");
    let mut brain = Command::new("python3")
        .arg("-c")
        .arg(
            "import fcntl, os, sys, time\n\
             f = open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX)\n\
             f.write(f'{os.getpid()}\\n1\\nflock\\n'); f.flush()\n\
             open(sys.argv[1] + '.ready', 'w').close()\n\
             time.sleep(600)\n",
        )
        .arg(&lock)
        .spawn()
        .unwrap();
    let ready = home.join("state/host.lock.ready");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ready.exists() {
        assert!(Instant::now() < deadline, "the stand-in brain never took the lock");
        std::thread::sleep(Duration::from_millis(20));
    }
    let output = Command::new(bin())
        .args(["chief", "shutdown", "--chief-home"])
        .arg(&home)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let status = brain.wait().unwrap();
    assert_success(&output);
    assert!(!status.success(), "the brain ended by the signal: {status:?}");
    let _ = fs::remove_dir_all(&home);
}

/// Version skew step 2: `identify` names the daemon's build and the
/// absolute path of its own CLI, under `daemon-build-v1`.
#[test]
fn identify_names_the_daemon_build_and_its_cli() {
    let server = HeadlessServer::start("daemon-build");
    let mut conn = Conn::open(&server.socket);
    let identity = conn.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "daemon-build-v1"), "{identity}");
    assert!(!identity["build_id"].as_str().unwrap_or("").is_empty(), "{identity}");
    let cli = std::path::Path::new(identity["cli_path"].as_str().unwrap());
    assert!(cli.is_absolute(), "{identity}");
    assert_eq!(cli.canonicalize().unwrap(), std::path::Path::new(bin()).canonicalize().unwrap());
}

/// A stand-in daemon of another build: every request gets an `identify`
/// answer that lacks the session journal and names `cli_path` as its CLI.
/// The test process is the socket's peer, so its pid is the daemon's.
fn skew_daemon(dir: &std::path::Path, cli_path: &std::path::Path) -> PathBuf {
    let socket = dir.join("skew.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let identity = json!({
        "app": "cmux-tui", "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
        "capabilities": ["daemon-build-v1"], "build_id": "skew-test-other-build",
        "cli_path": cli_path.to_str().unwrap(), "pid": std::process::id(),
    });
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let identity = identity.clone();
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { return };
                    let Ok(request) = serde_json::from_str::<Value>(&line) else { return };
                    let answer = json!({"id": request["id"], "ok": true, "data": identity});
                    if writeln!(writer, "{answer}").is_err() {
                        return;
                    }
                }
            });
        }
    });
    socket
}

/// This CLI copied into a tagged DEV bundle, so the skew checks run as they
/// do for an installed app (an unbundled CLI never re-execs).
fn bundled_cli(dir: &std::path::Path, name: &str) -> PathBuf {
    let bin_dir = dir.join(format!("{name}.app/Contents/Resources/bin"));
    fs::create_dir_all(&bin_dir).unwrap();
    // Named cmux-tui: the full command surface (a `cmux` name is the app CLI).
    let cli = bin_dir.join("cmux-tui");
    fs::copy(bin(), &cli).unwrap();
    fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
    cli
}

/// The daemon's "CLI": a script that says it ran, at `path` with `mode`.
fn fake_daemon_cli(path: &std::path::Path, mode: u32) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, "#!/bin/sh\necho \"REEXECED $CMUX_CLI_REEXEC $*\"\n").unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

fn journal_list(cli: &std::path::Path, socket: &std::path::Path, guard: Option<&str>) -> Output {
    let mut command = Command::new(cli);
    command
        .arg("--socket")
        .arg(socket)
        .args(["session", "current", "journal", "producer", "list"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_CLI_REEXEC");
    if let Some(guard) = guard {
        command.env("CMUX_CLI_REEXEC", guard);
    }
    command.output().unwrap()
}

/// Version skew step 3 at the CLI boundary: at a dead end the CLI runs the
/// daemon's own CLI only when every check passes, and otherwise refuses
/// with the reason and the one exact fix command; a re-exec'd CLI never
/// re-execs again.
#[test]
fn a_dead_end_runs_the_daemons_cli_only_when_every_check_passes() {
    let dir = unique_temp_dir("skew-reexec");
    fs::create_dir_all(&dir).unwrap();
    let cli = bundled_cli(&dir, "cmux DEV skewme");
    let target = |name: &str| dir.join(format!("{name}/Contents/Resources/bin/cmux"));
    let stderr = |o: &Output| String::from_utf8_lossy(&o.stderr).into_owned();

    // Every check passes: one re-exec line, the daemon's CLI runs with the
    // same arguments and the loop guard set to the daemon's build.
    let good = target("cmux DEV skewother.app");
    fake_daemon_cli(&good, 0o755);
    let ok_dir = dir.join("ok");
    fs::create_dir_all(&ok_dir).unwrap();
    let output = journal_list(&cli, &skew_daemon(&ok_dir, &good), None);
    let out = String::from_utf8_lossy(&output.stdout);
    assert!(
        out.contains("REEXECED skew-test-other-build --socket"),
        "stdout {out} stderr {}",
        stderr(&output)
    );
    assert_eq!(
        stderr(&output).matches("running the daemon's CLI").count(),
        1,
        "{}",
        stderr(&output)
    );

    // A command this build does not know is a dead end too (live run on
    // cmux-lawrence-2: an unknown-action hint used to end it first).
    let unknown_dir = dir.join("unknown");
    fs::create_dir_all(&unknown_dir).unwrap();
    let output = Command::new(&cli)
        .arg("--socket")
        .arg(skew_daemon(&unknown_dir, &good))
        .args(["nosuchscope", "nosuchverb"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_CLI_REEXEC")
        .output()
        .unwrap();
    let out = String::from_utf8_lossy(&output.stdout);
    assert!(
        out.contains("REEXECED skew-test-other-build --socket"),
        "unknown command: stdout {out} stderr {}",
        stderr(&output)
    );

    // Each refusal: nothing runs, the reason and the fix command are named.
    let writable = target("cmux DEV skewgw.app");
    fake_daemon_cli(&writable, 0o775);
    let outside = dir.join("loose/bin/cmux");
    fake_daemon_cli(&outside, 0o755);
    let release = target("cmux NIGHTLY.app");
    fake_daemon_cli(&release, 0o755);
    for (case, path, reason) in [
        ("group-writable", &writable, "is writable by group or other"),
        ("outside a cmux app", &outside, "is not inside a cmux app"),
        ("another install family", &release, "belongs to another cmux install family"),
    ] {
        let case_dir = dir.join(case.replace(' ', "-"));
        fs::create_dir_all(&case_dir).unwrap();
        let output = journal_list(&cli, &skew_daemon(&case_dir, path), None);
        let text = stderr(&output);
        assert!(
            !String::from_utf8_lossy(&output.stdout).contains("REEXECED"),
            "{case} ran: {text}"
        );
        assert_ne!(output.status.code(), Some(0), "{case}: {text}");
        assert!(text.contains(reason), "{case}: {text}");
        assert_eq!(text.matches("fix: ").count(), 1, "{case}: {text}");
        assert!(!text.contains("update the"), "{case}: {text}");
    }

    // The refusal speaks the CLI's language; the fix command stays literal.
    let ja_dir = dir.join("ja");
    fs::create_dir_all(&ja_dir).unwrap();
    let output = Command::new(&cli)
        .arg("--socket")
        .arg(skew_daemon(&ja_dir, &writable))
        .args(["session", "current", "journal", "producer", "list"])
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_CLI_REEXEC")
        .output()
        .unwrap();
    let text = stderr(&output);
    assert!(text.contains("書き込めます") && text.contains("修正: "), "ja: {text}");
    assert!(text.contains("daemon stop --socket"), "ja: {text}");

    // The loop guard: a CLI started by a re-exec never re-execs again.
    let guard_dir = dir.join("guard");
    fs::create_dir_all(&guard_dir).unwrap();
    let output = journal_list(&cli, &skew_daemon(&guard_dir, &good), Some("skew-test-other-build"));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("REEXECED"), "{}", stderr(&output));
    assert!(!stderr(&output).contains("running the daemon's CLI"), "{}", stderr(&output));
    let _ = fs::remove_dir_all(&dir);
}
