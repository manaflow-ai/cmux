//! An acknowledged change to a chat's metadata survives a `kill -9` that comes inside the daemon
//! while a later change is between its in-memory change and its durable write (fuzz row g finding
//! g2). Only a change whose answer the client never got may be lost.
//!
//! Each case: a save of the chat (a change of another field) is held between its copy and its
//! write (debug seam `ACPMUX_TEST_SAVE_META_HOLD_DIR`, `hub/meta_save.rs`); the field's change C
//! is sent; the held save goes; C is answered. Then a third change D (another field) is sent with
//! the seam's kill point armed: the daemon kills itself with SIGKILL after D's change is made in
//! memory and copied, before its write, so D is never answered. After a restart on the same home,
//! the field must hold C's acknowledged value. On feat the held, older copy is written after C
//! and nothing writes C again before the kill, so C is lost although it was answered.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents (tests/fake_agent.py).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

struct Daemon {
    home: PathBuf,
    holds: PathBuf,
    socket: PathBuf,
    child: Option<Child>,
}

impl Daemon {
    fn new(tag: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-msk-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("p")).unwrap();
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
        let holds = home.join("holds");
        std::fs::create_dir_all(&holds).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
        // `fakem` takes its model at the next start (`${model}` on its command line), so a
        // model pick is recorded in the chat's metadata (`Hub::set_model`). `fakeclaude` is a
        // Claude Code stand-in whose MCP server `github` a chat may turn off (`_acpmux/set_tools`).
        let init = json!({"mcp_servers": [{"name": "github", "status": "connected"}]});
        let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]},
                                          "fakem": {"argv": ["python3", fake, "--model", "${model}"]},
                                          "fakep": {"argv": ["python3", fake],
                                                    "env": {"FAKE_PICKER": "1", "FAKE_MODELS": "m-a,m-b"}},
                                          "fakeclaude": {"argv": ["python3", claude], "kind": "claude-stdio",
                                                         "env": {"FAKE_CLAUDE_INIT": init.to_string()}}},
                            "defaultHarness": "fake", "permissionPolicy": "ask",
                            "agentInbox": false, "autoResumeDelaysMs": [],
                            // A policy and modes that ask, so the socket may change the rules and
                            // set either of the stand-in's modes (`hub/person.rs`: what does
                            // not ask is the person's).
                            "webAskingModes": {"fake": ["normal", "strict"]}});
        std::fs::write(home.join("config.json"), config.to_string()).unwrap();
        std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let socket = home.join("s.sock");
        let mut daemon = Self { home, holds, socket, child: None };
        daemon.start();
        daemon
    }

    fn start(&mut self) {
        let child = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_TEST_SAVE_META_HOLD_DIR", &self.holds)
            // No agent hosts: a host outlives its daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(self.home.join("p"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.child = Some(child);
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon did not listen");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// Waits (at most 30 s) for the daemon child to end by itself (the seam's kill point).
    fn wait_killed(&mut self) -> std::process::ExitStatus {
        let deadline = Instant::now() + Duration::from_secs(30);
        let child = self.child.as_mut().unwrap();
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                self.child = None;
                return status;
            }
            assert!(Instant::now() < deadline, "the kill point did not end the daemon");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// SIGKILL of the daemon child this test started.
    fn kill9(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SAFETY: the unreaped daemon child this test started.
            unsafe { libc::kill(child.id() as i32, libc::SIGKILL) };
            let _ = child.wait();
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.kill9();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        let mut c = Self { reader, writer: stream, next: 0 };
        c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "g2"}}));
        c
    }

    fn send(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        self.next
    }

    /// The answer to request `id` within `wait`: Some(result), or None when none came.
    fn answer(&mut self, id: u64, method: &str, wait: Duration) -> Option<Value> {
        let deadline = Instant::now() + wait;
        while Instant::now() < deadline {
            let mut text = String::new();
            match self.reader.read_line(&mut text) {
                Ok(0) => panic!("{method}: the daemon closed the socket"),
                Ok(_) => {
                    let v: Value = serde_json::from_str(&text).unwrap();
                    if v.get("method").is_none() && v["id"] == id {
                        assert!(v.get("error").is_none(), "{method}: {v}");
                        return Some(v["result"].clone());
                    }
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(e) => panic!("{method}: {e}"),
            }
        }
        None
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        self.answer(id, method, Duration::from_secs(30))
            .unwrap_or_else(|| panic!("{method}: no answer in 30 s"))
    }
}

/// One field: the request that changes it, and how to read it back after the restart.
struct Case {
    field: &'static str,
    /// The request that changes the field, and the value it must keep, given the chat and the
    /// seq of its prompt (bookmarks only: a bookmark names a prompt; 0 otherwise).
    change: fn(&str, u64) -> (&'static str, Value),
    expect: fn(u64) -> Value,
    read: fn(&mut Client, &str) -> Value,
}

/// The harness a case's chat runs, and whether it runs one turn first (a bookmark names a
/// prompt; a Claude chat lists its MCP servers once it has started).
fn harness_of(field: &str) -> (&'static str, bool) {
    match field {
        "modelRequest" => ("fakem", false),
        "models.currentModelId" => ("fakep", false),
        "tools" => ("fakeclaude", true),
        "bookmarks" => ("fake", true),
        _ => ("fake", false),
    }
}

/// Whether the chat's tool `id` is on, as `_acpmux/info` lists it.
fn tool_on(c: &mut Client, id: &str, tool: &str) -> Value {
    let info = info(c, id);
    info["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row["id"] == tool)
        .map_or(Value::Null, |row| row["enabled"].clone())
}

fn info(c: &mut Client, id: &str) -> Value {
    c.call("_acpmux/info", json!({"sessionId": id}))
}

fn cases() -> Vec<Case> {
    vec![
        Case {
            field: "composerDraft",
            change: |id, _| {
                ("_acpmux/draft_set", json!({"sessionId": id, "text": "g2 kept draft"}))
            },
            expect: |_| json!("g2 kept draft"),
            read: |c, id| c.call("_acpmux/draft_get", json!({"sessionId": id}))["draft"].clone(),
        },
        Case {
            field: "name",
            change: |id, _| ("_acpmux/rename", json!({"sessionId": id, "newName": "g2-kept-name"})),
            expect: |_| json!("g2-kept-name"),
            read: |c, id| info(c, id)["name"].clone(),
        },
        Case {
            field: "modes.currentModeId",
            change: |id, _| ("session/set_mode", json!({"sessionId": id, "modeId": "strict"})),
            expect: |_| json!("strict"),
            read: |c, id| info(c, id)["currentModeId"].clone(),
        },
        Case {
            field: "unread",
            change: |id, _| ("_acpmux/markUnread", json!({"sessionId": id})),
            expect: |_| json!(true),
            read: |c, id| info(c, id)["unread"].clone(),
        },
        Case {
            field: "bookmarks",
            change: |id, seq| {
                ("_acpmux/bookmark_set", json!({"sessionId": id, "seq": seq, "bookmarked": true}))
            },
            expect: |seq| json!([seq]),
            read: |c, id| {
                c.call("_acpmux/bookmark_get", json!({"sessionId": id}))["bookmarks"].clone()
            },
        },
        Case {
            field: "tags",
            change: |id, _| ("_acpmux/tag", json!({"sessionId": id, "set": {"g2": "kept"}})),
            expect: |_| json!("kept"),
            read: |c, id| info(c, id)["tags"]["g2"].clone(),
        },
        Case {
            field: "turnCapMs",
            change: |id, _| {
                ("_acpmux/set_turn_cap", json!({"sessionId": id, "turnCapMs": 123_000}))
            },
            expect: |_| json!(123_000),
            read: |c, id| {
                c.call("_acpmux/set_turn_cap", json!({"sessionId": id}))["turnCapMs"].clone()
            },
        },
        Case {
            field: "permissionPolicy",
            change: |id, _| ("_acpmux/set_policy", json!({"sessionId": id, "policy": "deny-all"})),
            expect: |_| json!("deny-all"),
            read: |c, id| info(c, id)["policy"].clone(),
        },
        Case {
            field: "permissionRules",
            change: |id, _| {
                ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"autoDeny": ["g2"]}}))
            },
            expect: |_| json!({"autoDeny": ["g2"]}),
            read: |c, id| info(c, id)["rulesJson"].clone(),
        },
        Case {
            field: "modelRequest",
            change: |id, _| ("session/set_model", json!({"sessionId": id, "modelId": "g2-model"})),
            expect: |_| json!("g2-model"),
            read: |c, id| info(c, id)["model"].clone(),
        },
        Case {
            // `session/set_model` on a running harness with no model option: the model it
            // reports runs now (`Hub::set_model`, its last path).
            field: "models.currentModelId",
            change: |id, _| ("session/set_model", json!({"sessionId": id, "modelId": "m-b"})),
            expect: |_| json!("m-b"),
            read: |c, id| info(c, id)["model"].clone(),
        },
        Case {
            field: "tools",
            change: |id, _| {
                (
                    "_acpmux/set_tools",
                    json!({"sessionId": id, "id": "mcp:github", "enabled": false}),
                )
            },
            expect: |_| json!(false),
            read: |c, id| tool_on(c, id, "mcp:github"),
        },
    ]
}

/// Waits (at most 30 s) until the daemon holds a save of chat `id` (the seam took the file).
fn wait_held(daemon: &Daemon, id: &str) {
    let held = daemon.holds.join(format!("held-{id}"));
    let deadline = Instant::now() + Duration::from_secs(30);
    while !held.exists() {
        assert!(Instant::now() < deadline, "no save of {id} was held");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn meta_save_kill_point_keeps_every_acknowledged_change() {
    use std::os::unix::process::ExitStatusExt;
    let mut daemon = Daemon::new("kp");
    let mut report = Vec::new();
    let mut lost = Vec::new();
    for case in cases() {
        let mut client = Client::connect(&daemon.socket);
        let (harness, turn_first) = harness_of(case.field);
        let made = client.call(
            "session/new",
            json!({"cwd": daemon.home.join("p"), "mcpServers": [],
                   "_meta": {"acpmux": {"harness": harness}}}),
        );
        let id = made["sessionId"].as_str().unwrap().to_owned();
        // One turn first (the stand-in echoes it); a bookmark names that prompt's seq.
        let seq = if turn_first {
            let prompt =
                json!({"sessionId": id, "prompt": [{"type": "text", "text": "g2 prompt"}]});
            client.call("session/prompt", prompt);
            let prompts = client.call(
                "_acpmux/events",
                json!({"sessionId": id, "afterSeq": 0, "kinds": ["user_message"]}),
            );
            prompts["events"][0]["seq"].as_u64().expect("the prompt's seq")
        } else {
            0
        };
        // Another field's change, from another client: its save is held after its copy.
        let other = |id: &str, text: &str| -> (&'static str, Value) {
            if case.field == "composerDraft" {
                ("_acpmux/rename", json!({"sessionId": id, "newName": text}))
            } else {
                ("_acpmux/draft_set", json!({"sessionId": id, "text": text}))
            }
        };
        std::fs::write(daemon.holds.join(format!("hold-{id}")), "").unwrap();
        let holder = {
            let socket = daemon.socket.clone();
            let (method, params) = other(&id, "g2-holder");
            std::thread::spawn(move || Client::connect(&socket).call(method, params))
        };
        wait_held(&daemon, &id);
        // C: the field's change, answered.
        let (method, params) = (case.change)(&id, seq);
        let request = client.send(method, params);
        let early = client.answer(request, method, Duration::from_secs(5));
        std::fs::write(daemon.holds.join(format!("release-{id}")), "").unwrap();
        let answered =
            early.is_some() || client.answer(request, method, Duration::from_secs(30)).is_some();
        assert!(answered, "{method} was not answered");
        holder.join().unwrap();
        // D: another change, with the kill point armed: the daemon dies after D's change is
        // made and copied, before its write. D is never answered.
        std::fs::write(daemon.holds.join(format!("kill-{id}")), "").unwrap();
        let (d_method, d_params) = other(&id, "g2-unacked");
        let _ = client.send(d_method, d_params);
        let status = daemon.wait_killed();
        assert_eq!(status.signal(), Some(libc::SIGKILL), "the daemon ended another way: {status}");
        daemon.start();
        let mut reader = Client::connect(&daemon.socket);
        let after = (case.read)(&mut reader, &id);
        let expect = (case.expect)(seq);
        let ok = after == expect;
        let line = format!(
            "META-KILL field={} acked={expect} after_kill_point={after} answered_before_release={} ok={ok}",
            case.field,
            early.is_some()
        );
        println!("{line}");
        report.push(line);
        if !ok {
            lost.push(case.field);
        }
    }
    assert!(
        lost.is_empty(),
        "acknowledged changes lost at the kill point: {lost:?}\n{}",
        report.join("\n")
    );
}

/// A request that changes nothing (the chat is unread already; the prompt is bookmarked
/// already) answers ok only once the earlier change that made it so is on disk: a client that
/// hears ok counts on that state surviving a crash. Review of #29311.
///
/// Each case: an older save of the chat is held; client A sends the change (it waits for the
/// held save); once the change shows in memory, client B sends the same request, a no-op. If B
/// is answered while the save is still held, the test kills the daemon there and the state must
/// survive. Else it lets the save go, waits for both answers, and kills the daemon then.
#[test]
fn meta_save_kill_point_a_no_op_answers_after_the_change_it_repeats_is_on_disk() {
    let mut daemon = Daemon::new("noop");
    let mut report = Vec::new();
    let mut lost = Vec::new();
    for field in ["unread", "bookmarks"] {
        let mut a = Client::connect(&daemon.socket);
        let made = a.call("session/new", json!({"cwd": daemon.home.join("p"), "mcpServers": []}));
        let id = made["sessionId"].as_str().unwrap().to_owned();
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "g2 prompt"}]});
        a.call("session/prompt", prompt);
        let prompts = a.call(
            "_acpmux/events",
            json!({"sessionId": id, "afterSeq": 0, "kinds": ["user_message"]}),
        );
        let seq = prompts["events"][0]["seq"].as_u64().expect("the prompt's seq");
        let (method, params, expect) = if field == "unread" {
            ("_acpmux/markUnread", json!({"sessionId": id}), json!(true))
        } else {
            (
                "_acpmux/bookmark_set",
                json!({"sessionId": id, "seq": seq, "bookmarked": true}),
                json!([seq]),
            )
        };
        let read = |c: &mut Client| {
            if field == "unread" {
                info(c, &id)["unread"].clone()
            } else {
                c.call("_acpmux/bookmark_get", json!({"sessionId": id}))["bookmarks"].clone()
            }
        };
        // An older save of the chat, held after its copy.
        std::fs::write(daemon.holds.join(format!("hold-{id}")), "").unwrap();
        let holder = {
            let (socket, id) = (daemon.socket.clone(), id.clone());
            std::thread::spawn(move || {
                Client::connect(&socket).call(
                    "_acpmux/rename",
                    json!({"sessionId": id, "newName": format!("g2-noop-holder-{id}")}),
                )
            })
        };
        wait_held(&daemon, &id);
        // A: the change; it waits for the held save.
        let a_request = a.send(method, params.clone());
        let mut watcher = Client::connect(&daemon.socket);
        let deadline = Instant::now() + Duration::from_secs(30);
        while read(&mut watcher) != expect {
            assert!(Instant::now() < deadline, "{field}: A's change never showed");
            std::thread::sleep(Duration::from_millis(10));
        }
        // B: the same request, a no-op now.
        let mut b = Client::connect(&daemon.socket);
        let b_request = b.send(method, params);
        let early = b.answer(b_request, method, Duration::from_secs(2));
        if early.is_none() {
            std::fs::write(daemon.holds.join(format!("release-{id}")), "").unwrap();
            assert!(b.answer(b_request, method, Duration::from_secs(30)).is_some(), "B unanswered");
            assert!(a.answer(a_request, method, Duration::from_secs(30)).is_some(), "A unanswered");
        }
        // The crash: with the save still held when B was answered early.
        daemon.kill9();
        daemon.start();
        let mut reader = Client::connect(&daemon.socket);
        let after = read(&mut reader);
        let ok = after == expect;
        let line = format!(
            "META-NOOP field={field} acked={expect} after_kill={after} answered_while_held={} ok={ok}",
            early.is_some()
        );
        println!("{line}");
        report.push(line);
        if !ok {
            lost.push(field);
        }
        // Answered, or its connection closed with the killed daemon.
        let _ = holder.join();
    }
    assert!(
        lost.is_empty(),
        "a no-op answered ok before the change it repeats was on disk: {lost:?}\n{}",
        report.join("\n")
    );
}

/// No request answers its change while an older commit of the chat is still held: an answer
/// then means the change is not on disk yet. Each case holds an older save, sends the field's
/// change and waits 2 s for its answer. An answer that comes while the save is held is checked at
/// once: the daemon is killed there and the field must survive. Review of #29311 (`set_model`,
/// `set_tools`).
#[test]
fn meta_save_kill_point_an_answer_while_an_older_commit_is_held_survives() {
    let mut daemon = Daemon::new("held");
    let mut report = Vec::new();
    let mut lost = Vec::new();
    for case in cases() {
        let mut client = Client::connect(&daemon.socket);
        let (harness, turn_first) = harness_of(case.field);
        let made = client.call(
            "session/new",
            json!({"cwd": daemon.home.join("p"), "mcpServers": [],
                   "_meta": {"acpmux": {"harness": harness}}}),
        );
        let id = made["sessionId"].as_str().unwrap().to_owned();
        let seq = if turn_first {
            let prompt =
                json!({"sessionId": id, "prompt": [{"type": "text", "text": "g2 prompt"}]});
            client.call("session/prompt", prompt);
            let prompts = client.call(
                "_acpmux/events",
                json!({"sessionId": id, "afterSeq": 0, "kinds": ["user_message"]}),
            );
            prompts["events"][0]["seq"].as_u64().expect("the prompt's seq")
        } else {
            0
        };
        std::fs::write(daemon.holds.join(format!("hold-{id}")), "").unwrap();
        let holder = {
            let (socket, id, field) = (daemon.socket.clone(), id.clone(), case.field);
            std::thread::spawn(move || {
                let mut other = Client::connect(&socket);
                if field == "composerDraft" {
                    other.call("_acpmux/rename", json!({"sessionId": id, "newName": "g2-holder"}))
                } else {
                    other.call("_acpmux/draft_set", json!({"sessionId": id, "text": "g2 holder"}))
                }
            })
        };
        wait_held(&daemon, &id);
        let (method, params) = (case.change)(&id, seq);
        let request = client.send(method, params);
        let early = client.answer(request, method, Duration::from_secs(2));
        if early.is_none() {
            // Not answered while held: nothing to check at this point.
            std::fs::write(daemon.holds.join(format!("release-{id}")), "").unwrap();
            assert!(client.answer(request, method, Duration::from_secs(30)).is_some());
        }
        daemon.kill9();
        let _ = holder.join();
        daemon.start();
        let mut reader = Client::connect(&daemon.socket);
        let after = (case.read)(&mut reader, &id);
        let expect = (case.expect)(seq);
        let ok = early.is_none() || after == expect;
        let line = format!(
            "META-HELD field={} answered_while_held={} acked={expect} after_kill={after} ok={ok}",
            case.field,
            early.is_some()
        );
        println!("{line}");
        report.push(line);
        if !ok {
            lost.push(case.field);
        }
    }
    assert!(
        lost.is_empty(),
        "answered while an older commit was held, and lost at a kill: {lost:?}\n{}",
        report.join("\n")
    );
}
