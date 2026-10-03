//! The Chief's daemon shell against the real in-process conversation owner
//! and a fake acpmux hub.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::rules::{AGENT_MUX, DEFAULT_CONVERSATION_KEY, USER_LOCAL};
use cmux_conversation::{Message, Op, Part};
use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;

const MUX: &str = "s_mux";

/// An in-memory acpmux hub: the `mux` session's log, sessions, held methods.
#[derive(Default)]
struct FakeHub {
    sessions: Mutex<Vec<Value>>,
    log: Mutex<Vec<Value>>,
    prompts: Mutex<Vec<(String, String)>>,
    hold: Mutex<BTreeSet<String>>,
    calls: Mutex<Vec<String>>,
    connections: Mutex<Vec<Arc<FakeConnection>>>,
    connects: AtomicUsize,
}

struct FakeConnection {
    hub: Arc<FakeHub>,
    notices: Box<dyn Fn(AgentNotice) + Send + Sync>,
    closed: AtomicBool,
    held: Mutex<Vec<AgentReply>>,
}

impl FakeHub {
    fn calls(&self, method: &str) -> usize {
        self.calls.lock().unwrap().iter().filter(|call| *call == method).count()
    }

    fn notify(&self, method: &str, params: Value) {
        let open: Vec<_> = self.connections.lock().unwrap().iter().cloned().collect();
        for connection in open.iter().filter(|c| !c.closed.load(Ordering::Acquire)) {
            (connection.notices)(AgentNotice::Notification {
                method: method.into(),
                params: params.clone(),
            });
        }
    }

    fn append(&self, kind: &str, dir: &str, msg: Value) {
        let event = {
            let mut log = self.log.lock().unwrap();
            let seq = log.len() as u64 + 1;
            let event = json!({"sessionId": MUX, "seq": seq, "at": 1_790_985_600_000_u64 + seq,
                               "dir": dir, "kind": kind, "msg": msg});
            log.push(event.clone());
            event
        };
        self.notify("_acpmux/event", event);
    }

    /// The `mux` session answers each prompt with "echo: <text>" in one turn.
    fn answer(&self, params: &Value) -> Value {
        let prompt_id =
            params.pointer("/_meta/acpmux/promptId").and_then(Value::as_str).unwrap_or("");
        let text =
            params.pointer("/prompt/0/text").and_then(Value::as_str).unwrap_or("").to_owned();
        self.prompts.lock().unwrap().push((prompt_id.to_owned(), text.clone()));
        if params["sessionId"] != MUX {
            return json!({"stopReason": "end_turn"});
        }
        let reply = format!("echo: {}", text.rsplit("] ").next().unwrap_or(&text));
        self.append("user_message", "mux", json!({"promptId": prompt_id}));
        self.append("turn_started", "mux", json!({}));
        let chunk = json!({"params": {"update": {"content": {"type": "text", "text": reply}}}});
        self.append("agent_message_chunk", "agent", chunk);
        self.append("turn_end", "mux", json!({}));
        json!({"stopReason": "end_turn"})
    }

    fn handle(&self, method: &str, params: &Value) -> Value {
        let sessions = || json!({"sessions": self.sessions.lock().unwrap().clone()});
        match method {
            "_acpmux/sessions" | "_acpmux/watch" => sessions(),
            "session/new" => {
                let name = params.pointer("/_meta/acpmux/name").cloned().unwrap_or(json!("mux"));
                self.sessions.lock().unwrap().push(session(
                    MUX,
                    name.as_str().unwrap(),
                    "idle",
                    false,
                ));
                json!({"sessionId": MUX})
            }
            "_acpmux/events" | "_acpmux/attach" => {
                let after = params["afterSeq"].as_u64().unwrap_or(0);
                let limit = params["limit"].as_u64().unwrap_or(u64::MAX) as usize;
                let events: Vec<Value> = if params["sessionId"] == MUX {
                    let log = self.log.lock().unwrap();
                    log.iter()
                        .filter(|e| e["seq"].as_u64().unwrap() > after)
                        .take(limit)
                        .cloned()
                        .collect()
                } else {
                    Vec::new()
                };
                json!({"events": events})
            }
            "session/prompt" => self.answer(params),
            _ => json!({}),
        }
    }
}

fn session(id: &str, name: &str, status: &str, child: bool) -> Value {
    let tags = if child { json!({"mux.parent": "mux"}) } else { json!({}) };
    json!({"sessionId": id, "name": name, "harness": "claude", "cwd": "/w", "status": status,
           "pendingPermissions": 0, "stateSeq": 1, "preview": null, "tags": tags})
}

impl AgentConnection for FakeConnection {
    fn request(&self, method: &str, params: Value, reply: AgentReply) {
        self.hub.calls.lock().unwrap().push(method.to_owned());
        if self.closed.load(Ordering::Acquire) {
            return reply(Err(AgentError::Closed));
        }
        if self.hub.hold.lock().unwrap().contains(method) {
            return self.held.lock().unwrap().push(reply);
        }
        reply(Ok(self.hub.handle(method, &params)));
    }

    fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        for reply in self.held.lock().unwrap().drain(..) {
            reply(Err(AgentError::Closed));
        }
        (self.notices)(AgentNotice::Closed);
    }
}

struct FakeConnector(Arc<FakeHub>);

impl AgentConnector for FakeConnector {
    fn connect(
        &self,
        notices: Box<dyn Fn(AgentNotice) + Send + Sync>,
    ) -> anyhow::Result<Arc<dyn AgentConnection>> {
        self.0.connects.fetch_add(1, Ordering::AcqRel);
        let connection = Arc::new(FakeConnection {
            hub: self.0.clone(),
            notices,
            closed: AtomicBool::new(false),
            held: Mutex::new(Vec::new()),
        });
        self.0.connections.lock().unwrap().push(connection.clone());
        Ok(connection)
    }
}

struct World {
    mux: Arc<Mux>,
    hub: Arc<FakeHub>,
    home: PathBuf,
    _dir: TempDir,
}

/// A scratch directory removed on drop.
struct TempDir(PathBuf);

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn world(name: &str) -> World {
    let dir = std::env::temp_dir().join(format!(
        "chief-{name}-{}-{}",
        std::process::id(),
        actor::now_ms()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    World {
        mux: Mux::new_for_test(name, SurfaceOptions::default()),
        hub: Arc::new(FakeHub::default()),
        home: dir.join("mux"),
        _dir: TempDir(dir),
    }
}

impl World {
    fn config(&self) -> ChiefConfig {
        let mut config = ChiefConfig::new(self.home.clone(), "Me".to_owned());
        config.request_timeout = Duration::from_millis(300);
        config.backoff_initial = Duration::from_millis(20);
        config.backoff_max = Duration::from_millis(200);
        config.log = Arc::new(|_line| {});
        config
    }

    fn start(&self) -> ChiefHandle {
        start_chief(&self.mux, self.config(), Arc::new(FakeConnector(self.hub.clone())))
            .expect("start")
    }

    /// The default conversation (its create replays the Chief's).
    fn default_conversation(&self) -> String {
        let participants = daemon_port::default_participants("Me");
        let outcome = self.mux.conversation_create_as(
            DEFAULT_CONVERSATION_KEY,
            USER_LOCAL,
            "mux",
            &participants,
        );
        outcome.unwrap().summary.id
    }

    fn send(&self, conversation: &str, key: &str, text: &str) {
        let op = Op::MessageSend {
            client_msg_id: key.to_owned(),
            parts: vec![Part::Text { text: text.to_owned(), runs: None }],
            reply_to: None,
        };
        self.mux.conversation_op_as(conversation, key, USER_LOCAL, None, &op).unwrap();
    }

    fn messages(&self, conversation: &str) -> Vec<Message> {
        self.mux.with_conversations(|store| store.snapshot(conversation, 500)).unwrap().1
    }
}

/// Waits (bounded, test-only) until `done` holds.
fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn text_of(message: &Message) -> String {
    cmux_chief::rules::message_text(message)
}

#[test]
fn the_chief_answers_a_human_message_in_the_default_conversation_as_agent_mux() {
    let w = world("answer");
    let chief = w.start();
    wait_until("ready", || chief.is_ready());
    let conversation = w.default_conversation();
    w.send(&conversation, "m1", "hello");
    wait_until("the reply", || {
        w.messages(&conversation)
            .iter()
            .any(|m| m.author == AGENT_MUX && text_of(m) == "echo: hello")
    });
    let prompts = w.hub.prompts.lock().unwrap().clone();
    assert_eq!(prompts.len(), 1, "one prompt: {prompts:?}");
    assert_eq!(prompts[0].1, format!("[conversation {conversation} from Me] hello"));
    chief.stop();
    // The state carries over in the TypeScript host's JSON shape.
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(w.home.join("state/host.json")).unwrap())
            .unwrap();
    assert_eq!(saved["muxSessionId"], MUX);
    assert_eq!(saved["defaultConversation"], json!(conversation));
    assert_eq!(saved["acpmuxSeq"], 4, "one four-event turn");
}

#[test]
fn one_chief_per_mux_home_by_the_kernel_lock() {
    let w = world("lock");
    let first = w.start();
    let second = start_chief(&w.mux, w.config(), Arc::new(FakeConnector(w.hub.clone())));
    assert!(matches!(second, Err(LockError::Held)), "a second host is refused");
    let text = std::fs::read_to_string(w.home.join("state/host.lock")).unwrap();
    let lines: Vec<&str> = text.trim().split('\n').collect();
    assert_eq!(lines[0], std::process::id().to_string());
    assert_eq!(lines.get(2), Some(&"flock"), "the TypeScript host reads the flock mark: {text:?}");
    first.stop();
    w.start().stop();
}

#[test]
fn a_lock_held_by_text_only_by_an_older_live_host_is_refused() {
    let w = world("older");
    std::fs::create_dir_all(w.home.join("state")).unwrap();
    // pid 1 is alive and started before the recorded time.
    std::fs::write(w.home.join("state/host.lock"), format!("1\n{}\n", actor::now_ms())).unwrap();
    let start = start_chief(&w.mux, w.config(), Arc::new(FakeConnector(w.hub.clone())));
    assert!(matches!(start, Err(LockError::OlderHost(1))));
}

#[test]
fn a_stuck_child_events_fetch_hits_the_request_deadline_and_acpmux_reconnects() {
    let w = world("deadline");
    let chief = w.start();
    wait_until("ready", || chief.is_ready());
    let conversation = w.default_conversation();
    // A child the Chief started appears running.
    w.hub.sessions.lock().unwrap().push(session("s_c", "fixer", "running", true));
    w.hub.notify(
        "_acpmux/session_changed",
        json!({"session": session("s_c", "fixer", "running", true)}),
    );
    wait_until("the work card", || {
        w.messages(&conversation).iter().any(|m| matches!(m.parts.first(), Some(Part::Work { .. })))
    });
    let connects = w.hub.connects.load(Ordering::Acquire);
    w.hub.hold.lock().unwrap().insert("_acpmux/events".to_owned());
    let before = w.hub.calls("_acpmux/events");
    w.hub.notify(
        "_acpmux/session_changed",
        json!({"session": session("s_c", "fixer", "idle", true)}),
    );
    wait_until("the child events fetch", || w.hub.calls("_acpmux/events") > before);
    w.hub.hold.lock().unwrap().clear();
    wait_until("the reconnect", || w.hub.connects.load(Ordering::Acquire) > connects);
    wait_until("the finish prompt", || {
        w.hub
            .prompts
            .lock()
            .unwrap()
            .iter()
            .any(|(_, text)| text.starts_with("[mux-event] child fixer finished"))
    });
    chief.stop();
}

#[test]
fn stop_releases_the_lock_and_ends_the_hub_connection() {
    let w = world("stop");
    let chief = w.start();
    wait_until("ready", || chief.is_ready());
    chief.stop();
    let open = w
        .hub
        .connections
        .lock()
        .unwrap()
        .iter()
        .filter(|c| !c.closed.load(Ordering::Acquire))
        .count();
    assert_eq!(open, 0);
    w.start().stop();
}
