//! The actor thread: it owns the brain core, steps it with every input, and
//! runs the effects in order (the TypeScript host's `feed` and `drain`). An
//! effect whose answer is an input steps the core at once; that step's
//! effects queue after the ones already waiting. `persist` is the first
//! effect of its step, so the state is on disk before that step's requests.

use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_chief::{Core, Effect, HostState, Input, Port};
use serde_json::{Value, json};

use super::ChiefConfig;
use super::agent::{self, AgentConnection, AgentError};
use super::daemon_port::DaemonLink;
use super::lock::HostLock;
use super::state_file::StateFile;
use crate::Mux;

/// What the actor receives.
pub(super) enum Msg {
    /// A conversation event from daemon link `link`.
    Daemon {
        link: u64,
        input: Input,
    },
    /// Daemon link `link` lost events (the mailbox overflowed).
    DaemonLost {
        link: u64,
    },
    AgentUp {
        id: u64,
        connection: Arc<dyn AgentConnection>,
        input: Input,
    },
    AgentInput {
        id: u64,
        input: Input,
    },
    AgentDown {
        id: u64,
    },
    /// The answer to hub request `request` (dropped after its deadline).
    Reply {
        request: u64,
        input: Input,
    },
    /// Hub connection `id` acknowledged prompt `prompt_id` (`_acpmux/prompt_accepted`).
    PromptAck {
        id: u64,
        prompt_id: String,
    },
    /// Prompt `prompt_id` sent on connection `id` returned; `rejected`: the hub refused it.
    PromptSettled {
        id: u64,
        prompt_id: String,
        rejected: bool,
    },
    /// The durable state now, after every message queued before this one
    /// (the hub loop's attach cursor).
    State(Sender<HostState>),
    Log(String),
    Stop,
}

/// A hub request with a deadline, waiting for its answer.
struct Pending {
    connection: u64,
    deadline: Instant,
    /// The input a timeout feeds (the request's failure).
    failure: Input,
}

pub(super) struct Actor {
    pub(super) mux: Arc<Mux>,
    pub(super) config: ChiefConfig,
    core: Core,
    state_file: StateFile,
    sender: Sender<Msg>,
    ready: Arc<AtomicBool>,
    queue: VecDeque<Effect>,
    draining: bool,
    /// Core timers: key -> when (ms since the epoch).
    timers: BTreeMap<String, u64>,
    pending: BTreeMap<u64, Pending>,
    /// Prompts waiting for their acknowledgment: prompt id -> (connection, deadline).
    prompt_acks: BTreeMap<String, (u64, Instant)>,
    next_request: u64,
    agent: Option<(u64, Arc<dyn AgentConnection>)>,
    pub(super) daemon: DaemonLink,
}

pub(super) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as u64)
}

impl Actor {
    pub(super) fn new(
        mux: Arc<Mux>,
        config: ChiefConfig,
        state: HostState,
        state_file: StateFile,
        sender: Sender<Msg>,
        ready: Arc<AtomicBool>,
    ) -> Self {
        let daemon = DaemonLink::new(config.backoff_initial, config.backoff_max);
        Self {
            mux,
            config,
            core: Core::new(state),
            state_file,
            sender,
            ready,
            queue: VecDeque::new(),
            draining: false,
            timers: BTreeMap::new(),
            pending: BTreeMap::new(),
            prompt_acks: BTreeMap::new(),
            next_request: 1,
            agent: None,
            daemon,
        }
    }

    pub(super) fn sender(&self) -> Sender<Msg> {
        self.sender.clone()
    }

    pub(super) fn log(&self, line: &str) {
        (self.config.log)(line);
    }

    /// The loop: connect the daemon, then handle messages and due timers
    /// until `Stop`. The lock is released when the loop returns.
    pub(super) fn run(mut self, receiver: Receiver<Msg>, lock: HostLock) {
        self.daemon_connect();
        loop {
            let message = match self.next_wake() {
                Some(at) => receiver.recv_timeout(at.saturating_duration_since(Instant::now())),
                None => receiver.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match message {
                Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(message) => self.handle(message),
                Err(RecvTimeoutError::Timeout) => {}
            }
            self.fire_due();
        }
        self.daemon.close();
        if let Some((_, connection)) = self.agent.take() {
            connection.close();
        }
        drop(lock);
    }

    fn handle(&mut self, message: Msg) {
        match message {
            Msg::Daemon { link, input } => {
                if self.daemon.is_current(link) {
                    self.feed(input);
                }
            }
            Msg::DaemonLost { link } => {
                if self.daemon.is_current(link) {
                    self.log("conversation events overflowed; resubscribing");
                    self.daemon_lost();
                }
            }
            Msg::AgentUp { id, connection, input } => {
                self.agent = Some((id, connection));
                self.feed(input);
            }
            Msg::AgentInput { id, input } => {
                if self.agent.as_ref().is_some_and(|(current, _)| *current == id) {
                    self.feed(input);
                }
            }
            Msg::AgentDown { id } => {
                if self.agent.as_ref().is_some_and(|(current, _)| *current == id) {
                    self.agent = None;
                    self.feed(Input::Disconnected { port: Port::Acpmux });
                }
            }
            Msg::Reply { request, input } => {
                if self.pending.remove(&request).is_some() {
                    self.feed(input);
                }
            }
            Msg::PromptAck { id, prompt_id } => self.acknowledged(id, &prompt_id),
            Msg::PromptSettled { id, prompt_id, rejected } => {
                self.acknowledged(id, &prompt_id);
                self.feed(Input::PromptSettled { prompt_id, rejected });
            }
            Msg::State(reply) => {
                let _ = reply.send(self.core.state.clone());
            }
            Msg::Log(line) => self.log(&line),
            Msg::Stop => {}
        }
    }

    /// The earliest core timer, request deadline or daemon retry.
    fn next_wake(&self) -> Option<Instant> {
        let now_wall = now_ms();
        let now = Instant::now();
        let timers =
            self.timers.values().map(|at| now + Duration::from_millis(at.saturating_sub(now_wall)));
        let deadlines = self.pending.values().map(|pending| pending.deadline);
        let acks = self.prompt_acks.values().map(|(_, deadline)| *deadline);
        timers.chain(deadlines).chain(acks).chain(self.daemon.retry_at()).min()
    }

    fn fire_due(&mut self) {
        let now_wall = now_ms();
        let due: Vec<String> = self
            .timers
            .iter()
            .filter(|(_, at)| **at <= now_wall)
            .map(|(key, _)| key.clone())
            .collect();
        for key in due {
            self.timers.remove(&key);
            self.feed(Input::Timer { key });
        }
        let now = Instant::now();
        let late: Vec<u64> =
            self.pending.iter().filter(|(_, p)| p.deadline <= now).map(|(id, _)| *id).collect();
        for request in late {
            let Some(pending) = self.pending.remove(&request) else { continue };
            let timeout = self.config.request_timeout.as_millis();
            self.log(&format!("acpmux request got no answer in {timeout} ms; reconnecting"));
            self.feed(pending.failure);
            if let Some((id, connection)) = &self.agent
                && *id == pending.connection
            {
                connection.close();
            }
        }
        let unacknowledged: Vec<String> = self
            .prompt_acks
            .iter()
            .filter(|(_, (_, deadline))| *deadline <= now)
            .map(|(prompt_id, _)| prompt_id.clone())
            .collect();
        for prompt_id in unacknowledged {
            let Some((connection_id, _)) = self.prompt_acks.remove(&prompt_id) else { continue };
            let timeout = self.config.request_timeout.as_millis();
            self.log(&format!(
                "prompt {prompt_id} got no acknowledgment in {timeout} ms; reconnecting"
            ));
            if let Some((id, connection)) = &self.agent
                && *id == connection_id
            {
                connection.close();
            }
        }
        if self.daemon.retry_at().is_some_and(|at| at <= now) {
            self.daemon_connect();
        }
    }

    /// Steps the core and runs its effects in order (log lines at once).
    pub(super) fn feed(&mut self, input: Input) {
        for effect in self.core.step(input, now_ms()) {
            match effect {
                Effect::Log { line } => self.log(&line),
                effect => self.queue.push_back(effect),
            }
        }
        if self.draining {
            return;
        }
        self.draining = true;
        while let Some(effect) = self.queue.pop_front() {
            self.run_effect(effect);
        }
        self.draining = false;
    }

    fn run_effect(&mut self, effect: Effect) {
        match effect {
            Effect::Persist { state } => {
                if let Err(error) = self.state_file.save(&state) {
                    self.log(&format!("effect persist failed: {error}"));
                }
            }
            Effect::Ready => self.ready.store(true, Ordering::Release),
            Effect::ArmTimer { key, at } => {
                self.timers.insert(key, at);
            }
            Effect::Reconnect { port: Port::Daemon } => self.daemon_lost(),
            Effect::Reconnect { port: Port::Acpmux } => {
                if let Some((_, connection)) = &self.agent {
                    connection.close();
                }
            }
            Effect::Prompt { prompt_id, text } => self.prompt(prompt_id, text),
            Effect::FetchSessions => self.agent_read("_acpmux/sessions", json!({}), sessions_input),
            Effect::FetchChildEvents { session_id, after } => {
                let params =
                    json!({"sessionId": session_id, "afterSeq": after, "limit": 1_000_000});
                self.agent_read("_acpmux/events", params, move |answer| Input::ChildEvents {
                    session_id: session_id.clone(),
                    events: answer.map(|value| agent::parse_events(&value)).unwrap_or_default(),
                });
            }
            Effect::Log { line } => self.log(&line),
            daemon_effect => self.daemon_effect(daemon_effect),
        }
    }

    /// A prompt. Its request answers when the turn ends (no bound), but the
    /// hub acknowledges a recorded prompt at once (`_acpmux/prompt_accepted`):
    /// that acknowledgment has the request deadline, and a missing one closes
    /// the connection (the next connect sends the prompt again). A refusal by
    /// the hub settles it `rejected`; the core retries it on the clock.
    fn prompt(&mut self, prompt_id: String, text: String) {
        let (Some((id, connection)), Some(session)) =
            (&self.agent, &self.core.state.mux_session_id)
        else {
            return;
        };
        let id = *id;
        let deadline = Instant::now() + self.config.request_timeout;
        self.prompt_acks.insert(prompt_id.clone(), (id, deadline));
        let params = json!({
            "sessionId": session,
            "prompt": [{"type": "text", "text": text}],
            "_meta": {"acpmux": {"promptId": prompt_id, "delivery": "turn"}},
        });
        let sender = self.sender.clone();
        let log = self.config.log.clone();
        connection.request(
            "session/prompt",
            params,
            Box::new(move |answer| {
                let rejected = matches!(answer, Err(AgentError::Rejected { .. }));
                if let Err(error) = answer {
                    let next = if rejected {
                        "the core retries it"
                    } else {
                        "resent on the next acpmux connect"
                    };
                    log(&format!("prompt {prompt_id} failed: {error}; {next}"));
                }
                let _ = sender.send(Msg::PromptSettled { id, prompt_id, rejected });
            }),
        );
    }

    /// The prompt's acknowledgment arrived (or its request returned) on
    /// connection `id`: its deadline ends.
    fn acknowledged(&mut self, id: u64, prompt_id: &str) {
        if self.prompt_acks.get(prompt_id).is_some_and(|(connection, _)| *connection == id) {
            self.prompt_acks.remove(prompt_id);
        }
    }

    /// A hub read with the request deadline. `input` maps the answer (or the
    /// failure, also used when the deadline passes) to the core's input.
    fn agent_read(
        &mut self,
        method: &str,
        params: Value,
        input: impl Fn(Result<Value, ()>) -> Input + Send + 'static,
    ) {
        let Some((connection_id, connection)) = self.agent.clone() else { return };
        let request = self.next_request;
        self.next_request += 1;
        let deadline = Instant::now() + self.config.request_timeout;
        self.pending.insert(
            request,
            Pending { connection: connection_id, deadline, failure: input(Err(())) },
        );
        let sender = self.sender.clone();
        connection.request(
            method,
            params,
            Box::new(move |answer| {
                let input = input(answer.map_err(|_| ()));
                let _ = sender.send(Msg::Reply { request, input });
            }),
        );
    }
}

fn sessions_input(answer: Result<Value, ()>) -> Input {
    match answer {
        Ok(value) => Input::Sessions {
            sessions: serde_json::from_value(value.get("sessions").cloned().unwrap_or(Value::Null))
                .unwrap_or_default(),
            failed: false,
        },
        Err(()) => Input::Sessions { sessions: Vec::new(), failed: true },
    }
}
