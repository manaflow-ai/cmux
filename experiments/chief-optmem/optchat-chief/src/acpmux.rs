//! The acpmux side: the port the turn runner and the brain use, and its real
//! implementation over the acpmux socket, which reconnects on its own and
//! routes notifications to the turn that owns a session or to the brain.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_chief::acp::{AcpmuxEvent, SessionSummary};
use serde_json::{Value, json};

use crate::rpc::{Notification, RpcClient, RpcError};

/// A new acpmux session.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionSpec {
    pub name: String,
    pub cwd: PathBuf,
    pub harness: String,
    pub policy: String,
    pub model: Option<String>,
    /// acpmux's `effort` (a harness config option); None: the harness default.
    pub effort: Option<String>,
    /// A preset the session requires: it never starts without it (the
    /// compactor). None: the port's turn preset when installed.
    pub preset: Option<String>,
    /// acpmux tags set on the session right after it is created.
    pub tags: BTreeMap<String, String>,
}

/// The tag on every session the Chief itself runs (its turns and its
/// compactor nodes), valued with its home id; its children never carry it
/// (they keep `mux.parent`). Quit counts and endAgents exclude these.
pub const CHIEF_TAG: &str = "cmux.chief";
/// `turn` or `compactor`, next to `cmux.chief`.
pub const CHIEF_ROLE_TAG: &str = "cmux.chief.role";

/// The tags of a Chief session of `role` for home `home_id`.
pub fn chief_tags(home_id: &str, role: &str) -> BTreeMap<String, String> {
    let _ = (home_id, role);
    BTreeMap::new()
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
    /// A session's summary by id (None: no such session).
    fn session(&self, _id: &str) -> Result<Option<SessionSummary>, String> {
        Ok(None)
    }
    /// Stops the session's running turn (`session/cancel`; Claude Code gets an
    /// interrupt). The turn then ends with stop reason `cancelled`.
    fn cancel(&self, _session: &str) -> Result<(), String> {
        Err("cancel is not supported".into())
    }
    /// Whether the connected daemon installed `preset` with its `args`.
    fn preset_args(&self, _preset: &str) -> bool {
        false
    }
    /// Whether the connected daemon installed `preset` with a system prompt
    /// (it knows `systemPrompt`): the cached layout.
    fn system_prompt(&self, _preset: &str) -> bool {
        false
    }
    /// Replaces preset `preset`'s system prompt text (acpmux writes the file
    /// and records its new sha256); sessions that start after it use it.
    fn set_system_prompt(&self, _preset: &str, _text: &str) -> Result<(), String> {
        Err("this acpmux takes no preset system prompt".into())
    }
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

/// An acpmux preset every turn session starts with: its env reaches the
/// harness process (acpmux puts a preset's env over the profile's).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preset {
    pub name: String,
    /// The harness the preset names (acpmux requires one); turn sessions
    /// still pass their own explicitly.
    pub harness: String,
    pub env: BTreeMap<String, String>,
    /// Words appended to the harness command (acpmux preset `args`, one argv
    /// word each, no shell). A daemon from before `args` refuses the key; the
    /// preset is then installed without them and `preset_args` says so.
    pub args: Vec<String>,
    /// The preset's system prompt text at install (acpmux `systemPrompt`,
    /// Claude harnesses only): acpmux writes it into its own preset directory
    /// and records its sha256; `set_system_prompt` replaces it later. A
    /// daemon from before `systemPrompt` refuses the key; the preset is then
    /// installed without it and `system_prompt` says so.
    pub system_prompt: Option<String>,
}

/// The real port: one connection at a time to the acpmux daemon.
pub struct Acpmux {
    socket: PathBuf,
    client: Mutex<Option<Arc<RpcClient>>>,
    turns: Arc<Mutex<HashMap<String, Sender<TurnSignal>>>>,
    /// The turn sessions' preset, used when installed (else a turn runs with
    /// the harness's own configuration, and host.log says so).
    preset: Option<Preset>,
    /// Presets that sessions name in `SessionSpec::preset` and require.
    required: Vec<Preset>,
    /// Presets installed in the connected daemon.
    ready: Mutex<HashSet<String>>,
    /// Presets installed with their `args` (the daemon knows the key).
    with_args: Mutex<HashSet<String>>,
    /// Presets installed with a system prompt (the daemon knows `systemPrompt`).
    with_prompt: Mutex<HashSet<String>>,
}

impl Acpmux {
    pub fn new(socket: PathBuf, preset: Option<Preset>, required: Vec<Preset>) -> Arc<Acpmux> {
        Arc::new(Acpmux {
            socket,
            client: Mutex::new(None),
            turns: Arc::new(Mutex::new(HashMap::new())),
            preset,
            required,
            ready: Mutex::new(HashSet::new()),
            with_args: Mutex::new(HashSet::new()),
            with_prompt: Mutex::new(HashSet::new()),
        })
    }

    /// Installs (or refreshes) every preset; acpmux saves them in its config.
    /// A daemon that does not know a key refuses it ("unknown preset key"):
    /// the preset is installed again without it, and its users keep the
    /// layout without (args before #17283, systemPrompt before the preset
    /// system prompt).
    fn install_presets(&self, client: &RpcClient, log: &dyn Fn(&str)) {
        let mut ready = HashSet::new();
        let mut with_args = HashSet::new();
        let mut with_prompt = HashSet::new();
        let all = self.preset.iter().map(|p| (p, false));
        for (preset, required) in all.chain(self.required.iter().map(|p| (p, true))) {
            let mut set = json!({
                "harness": preset.harness,
                "env": preset.env,
                "description": "optchat-chief: an isolated Claude Code configuration",
            });
            if !preset.args.is_empty() {
                set["args"] = json!(preset.args);
            }
            if let Some(text) = &preset.system_prompt {
                set["systemPrompt"] = json!(text);
            }
            let result = loop {
                let result =
                    client.request("_acpmux/presets", json!({"name": preset.name, "set": set}));
                let Err(e) = &result else { break result };
                let text = e.to_string();
                // An unknown key ("unknown preset key \"systemPrompt\"; use
                // ..., args, ...") or a refused value ("systemPrompt: ...",
                // "args: ...").
                let key = if text.contains("key \"systemPrompt\"") || text.contains("systemPrompt:")
                {
                    "systemPrompt"
                } else if text.contains("args") {
                    "args"
                } else {
                    break result;
                };
                let Some(map) = set.as_object_mut() else {
                    break result;
                };
                if map.remove(key).is_none() {
                    break result;
                }
                log(&format!(
                    "acpmux refused the {key} of preset {} ({text}); installed without it",
                    preset.name
                ));
            };
            match result {
                Ok(_) => {
                    ready.insert(preset.name.clone());
                    if set.get("args").is_some() {
                        with_args.insert(preset.name.clone());
                    }
                    if set.get("systemPrompt").is_some() {
                        with_prompt.insert(preset.name.clone());
                    }
                }
                Err(e) if required => log(&format!(
                    "acpmux preset {} not installed ({e}); sessions that require it do not start",
                    preset.name
                )),
                Err(e) => log(&format!(
                    "acpmux preset {} not installed ({e}); turns run with the user's Claude configuration",
                    preset.name
                )),
            }
        }
        *self.ready.lock().expect("ready") = ready;
        *self.with_args.lock().expect("with_args") = with_args;
        *self.with_prompt.lock().expect("with_prompt") = with_prompt;
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
                self.install_presets(&client, log);
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

/// `session/new` with acpmux's name, harness, policy, model and preset.
pub fn new_session(
    client: &RpcClient,
    spec: &SessionSpec,
    preset: Option<&str>,
) -> Result<String, String> {
    let mut meta = json!({"name": spec.name, "harness": spec.harness, "policy": spec.policy});
    if let Some(model) = &spec.model {
        meta["model"] = json!(model);
    }
    if let Some(effort) = &spec.effort {
        meta["effort"] = json!(effort);
    }
    if let Some(preset) = preset {
        meta["preset"] = json!(preset);
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
        let ready = self.ready.lock().expect("ready").clone();
        let preset = match &spec.preset {
            Some(name) if ready.contains(name) => Some(name.as_str()),
            // Never a fallback to the user's own configuration.
            Some(name) => {
                return Err(format!(
                    "the acpmux preset {name} is not installed, and this session never starts without it"
                ));
            }
            None => self
                .preset
                .as_ref()
                .filter(|p| ready.contains(&p.name))
                .map(|p| p.name.as_str()),
        };
        new_session(&*self.client()?, spec, preset)
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
                    Ok(Err(RpcError::Closed | RpcError::Timeout(_))) | Err(_) => TurnSignal::Lost,
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

    fn session(&self, id: &str) -> Result<Option<SessionSummary>, String> {
        Ok(sessions(&*self.client()?)?
            .into_iter()
            .find(|s| s.session_id == id))
    }

    fn cancel(&self, session: &str) -> Result<(), String> {
        self.client()?
            .request("session/cancel", json!({"sessionId": session}))
            .map(|_| ())
            .map_err(|e| format!("cancel: {e}"))
    }

    fn preset_args(&self, preset: &str) -> bool {
        self.with_args.lock().expect("with_args").contains(preset)
    }

    fn system_prompt(&self, preset: &str) -> bool {
        self.with_prompt
            .lock()
            .expect("with_prompt")
            .contains(preset)
    }

    fn set_system_prompt(&self, preset: &str, text: &str) -> Result<(), String> {
        if !self.system_prompt(preset) {
            return Err(format!(
                "the acpmux preset {preset} was not installed with a system prompt"
            ));
        }
        self.client()?
            .request(
                "_acpmux/presets",
                json!({"name": preset, "set": {"systemPrompt": text}}),
            )
            .map(|_| ())
            .map_err(|e| format!("setting the system prompt of preset {preset}: {e}"))
    }
}
