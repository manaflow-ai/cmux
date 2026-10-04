//! The acpmux side: the port the turn runner and the brain use, and its real
//! implementation over the acpmux socket, which reconnects on its own and
//! routes notifications to the turn that owns a session or to the brain.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_chief::acp::{AcpmuxEvent, SessionSummary};
use serde_json::{Value, json};

use crate::rpc::{Notification, RpcClient, RpcError};

/// A new acpmux session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionSpec {
    pub name: String,
    pub cwd: PathBuf,
    pub harness: String,
    pub policy: String,
    pub model: Option<String>,
}

/// What a running turn hears about its session.
#[derive(Clone, Debug, PartialEq)]
pub enum TurnSignal {
    /// New events that matter for the log (not text chunks): fetch them.
    Changed,
    /// The prompt's answer: the turn ended (or never started, on an error).
    Done(Result<Value, String>),
    /// The acpmux connection ended during the turn.
    Lost,
}

/// What the brain hears from acpmux.
#[derive(Clone, Debug, PartialEq)]
pub enum AgentEvent {
    /// Connected (again): every session, for reconciling children.
    Up(Vec<SessionSummary>),
    Down,
    SessionChanged(SessionSummary),
    Permission {
        session_id: String,
        permission_id: String,
        request: Value,
    },
}

/// The acpmux operations the Chief needs. Implemented over the socket here
/// and by in-process fakes in tests.
pub trait AgentPort: Send + Sync {
    /// Creates a session; returns its id.
    fn new_session(&self, spec: &SessionSpec) -> Result<String, String>;
    /// Sends a prompt as a new turn; the session's signals and the answer go to `signals`.
    fn start_prompt(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
        signals: Sender<TurnSignal>,
    ) -> Result<(), String>;
    /// The session's recorded events after `after`, oldest first.
    fn events(&self, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String>;
    /// Stops routing the session's signals and removes the session.
    fn end_session(&self, session: &str) -> Result<(), String>;
    /// A session's id by name.
    fn find(&self, name: &str) -> Result<Option<String>, String>;
}

/// Event kinds that never change the log by themselves; a turn fetches
/// events only on the others, so streaming text costs no requests.
fn is_noise(kind: &str) -> bool {
    matches!(
        kind,
        "agent_message_chunk" | "agent_thought_chunk" | "usage_update" | "user_message_chunk"
    )
}

type Sink = Arc<dyn Fn(AgentEvent) + Send + Sync>;

/// The real port: one connection at a time to the acpmux daemon.
pub struct Acpmux {
    socket: PathBuf,
    client: Mutex<Option<Arc<RpcClient>>>,
    turns: Arc<Mutex<HashMap<String, Sender<TurnSignal>>>>,
}

impl Acpmux {
    pub fn new(socket: PathBuf) -> Arc<Acpmux> {
        Arc::new(Acpmux {
            socket,
            client: Mutex::new(None),
            turns: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    fn client(&self) -> Result<Arc<RpcClient>, String> {
        self.client
            .lock()
            .expect("client")
            .clone()
            .filter(|c| !c.is_closed())
            .ok_or_else(|| "acpmux is not connected".to_owned())
    }

    /// Runs the connection loop on its own thread: start the daemon if needed,
    /// connect, report sessions, wait for the end, back off, again.
    pub fn spawn_link(self: &Arc<Self>, sink: Sink, log: Arc<dyn Fn(&str) + Send + Sync>) {
        let this = self.clone();
        std::thread::Builder::new()
            .name("acpmux-link".into())
            .spawn(move || {
                let mut delay = Duration::from_millis(500);
                loop {
                    let started = std::time::Instant::now();
                    match this.connect_once(&sink, &*log) {
                        Ok(closed) => {
                            let _ = closed.recv();
                            log("acpmux connection closed");
                        }
                        Err(e) => log(&format!("acpmux: {e}")),
                    }
                    *this.client.lock().expect("client") = None;
                    for (_, tx) in this.turns.lock().expect("turns").drain() {
                        let _ = tx.send(TurnSignal::Lost);
                    }
                    sink(AgentEvent::Down);
                    if started.elapsed() > Duration::from_secs(30) {
                        delay = Duration::from_millis(500);
                    }
                    std::thread::sleep(delay);
                    delay = (delay * 2).min(Duration::from_secs(30));
                }
            })
            .expect("spawn acpmux link");
    }

    fn connect_once(
        &self,
        sink: &Sink,
        log: &dyn Fn(&str),
    ) -> Result<std::sync::mpsc::Receiver<()>, String> {
        crate::acpmux_daemon::ensure(&self.socket, log)?;
        let (closed_tx, closed_rx) = channel();
        let turns = self.turns.clone();
        let route_sink = sink.clone();
        let client = RpcClient::connect(&self.socket, move |n| {
            if n.method.is_empty() {
                let _ = closed_tx.send(());
            } else {
                route(&turns, &route_sink, n);
            }
        })
        .map_err(|e| format!("connect {}: {e}", self.socket.display()))?;
        let result = (|| {
            client
                .request(
                    "initialize",
                    json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "optchat-chief", "version": env!("CARGO_PKG_VERSION")}}),
                )
                .map_err(|e| format!("initialize: {e}"))?;
            client
                .request("_acpmux/watch", json!({"enabled": true}))
                .map_err(|e| format!("watch: {e}"))?;
            sessions(&client)
        })();
        match result {
            Ok(list) => {
                *self.client.lock().expect("client") = Some(client);
                log(&format!("acpmux connected at {}", self.socket.display()));
                sink(AgentEvent::Up(list));
                Ok(closed_rx)
            }
            Err(e) => {
                client.close();
                Err(e)
            }
        }
    }
}

/// Sends a notification to the turn that owns its session, or to the brain.
fn route(turns: &Mutex<HashMap<String, Sender<TurnSignal>>>, sink: &Sink, n: Notification) {
    let session = n
        .params
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or("");
    match n.method.as_str() {
        "session/update" | "_acpmux/event" => {
            let kind = n
                .params
                .pointer("/_meta/acpmux/kind")
                .or_else(|| n.params.pointer("/update/sessionUpdate"))
                .or_else(|| n.params.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if !is_noise(kind)
                && let Some(tx) = turns.lock().expect("turns").get(session)
            {
                let _ = tx.send(TurnSignal::Changed);
            }
        }
        "_acpmux/session_changed" => {
            if let Some(summary) = n
                .params
                .get("session")
                .and_then(|s| serde_json::from_value::<SessionSummary>(s.clone()).ok())
            {
                sink(AgentEvent::SessionChanged(summary));
            }
        }
        "_acpmux/permission_pending" => sink(AgentEvent::Permission {
            session_id: session.to_owned(),
            permission_id: n
                .params
                .get("permissionId")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            request: n.params.get("request").cloned().unwrap_or(Value::Null),
        }),
        _ => {}
    }
}

/// `_acpmux/sessions`, rows that do not parse skipped.
pub fn sessions(client: &RpcClient) -> Result<Vec<SessionSummary>, String> {
    let result = client
        .request("_acpmux/sessions", json!({}))
        .map_err(|e| format!("sessions: {e}"))?;
    Ok(result
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|s| serde_json::from_value(s.clone()).ok())
        .collect())
}

/// `_acpmux/events` after `after`, every page.
pub fn events(client: &RpcClient, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String> {
    const LIMIT: u64 = 10_000;
    let mut all: Vec<AcpmuxEvent> = Vec::new();
    let mut cursor = after;
    loop {
        let result = client
            .request(
                "_acpmux/events",
                json!({"sessionId": session, "afterSeq": cursor, "limit": LIMIT}),
            )
            .map_err(|e| format!("events: {e}"))?;
        let page: Vec<AcpmuxEvent> = result
            .get("events")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|e| serde_json::from_value(e.clone()).ok())
            .collect();
        let full = page.len() as u64 >= LIMIT;
        let last = page.iter().map(|e| e.seq).max().unwrap_or(cursor);
        all.extend(page);
        if !full || last <= cursor {
            return Ok(all);
        }
        cursor = last;
    }
}

/// `session/new` with acpmux's name, harness, policy and model.
pub fn new_session(client: &RpcClient, spec: &SessionSpec) -> Result<String, String> {
    let mut meta = json!({"name": spec.name, "harness": spec.harness, "policy": spec.policy});
    if let Some(model) = &spec.model {
        meta["model"] = json!(model);
    }
    let result = client
        .request(
            "session/new",
            json!({"cwd": spec.cwd, "mcpServers": [], "_meta": {"acpmux": meta}}),
        )
        .map_err(|e| format!("session/new: {e}"))?;
    result
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "session/new answered without a sessionId".to_owned())
}

impl AgentPort for Acpmux {
    fn new_session(&self, spec: &SessionSpec) -> Result<String, String> {
        new_session(&*self.client()?, spec)
    }

    fn start_prompt(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
        signals: Sender<TurnSignal>,
    ) -> Result<(), String> {
        let client = self.client()?;
        self.turns
            .lock()
            .expect("turns")
            .insert(session.to_owned(), signals.clone());
        let answer = client.start(
            "session/prompt",
            json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": {"promptId": prompt_id}}}),
        );
        std::thread::Builder::new()
            .name("acpmux-prompt".into())
            .spawn(move || {
                let done = match answer.recv() {
                    Ok(Ok(value)) => TurnSignal::Done(Ok(value)),
                    Ok(Err(RpcError::Remote { message, .. })) => TurnSignal::Done(Err(message)),
                    Ok(Err(RpcError::Closed)) | Err(_) => TurnSignal::Lost,
                };
                let _ = signals.send(done);
            })
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn events(&self, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String> {
        events(&*self.client()?, session, after)
    }

    fn end_session(&self, session: &str) -> Result<(), String> {
        self.turns.lock().expect("turns").remove(session);
        self.client()?
            .request("_acpmux/kill", json!({"sessionId": session, "purge": true}))
            .map(|_| ())
            .map_err(|e| format!("kill: {e}"))
    }

    fn find(&self, name: &str) -> Result<Option<String>, String> {
        Ok(sessions(&*self.client()?)?
            .into_iter()
            .find(|s| s.name == name)
            .map(|s| s.session_id))
    }
}
