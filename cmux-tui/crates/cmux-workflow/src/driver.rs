//! The run's side: answers the engine's requests on the caller's thread,
//! starts steps on the host, journals what finishes and replays the journal.
//!
//! Replay: step `n` (the n-th step the script created) is cached when the
//! journal holds a finished step `n` with the same key and no earlier step
//! of this execution differed (the longest unchanged prefix, as Claude Code
//! workflows resume). Cached results go back in the order they first
//! finished, so the script sees the same interleaving and creates the same
//! steps. A step that started but never finished runs again, with its host
//! handle in `Step::resume`.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{self, Ending, Notice, Reply, Request, ToDriver};
use crate::journal::{Entry, Journal};
use crate::schema;

/// Console and log text kept in the outcome; later lines are only counted.
const MAX_LOG_BYTES: usize = 64 << 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StepKind {
    Agent,
    Machine,
}

impl StepKind {
    fn name(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Machine => "machine",
        }
    }
}

/// One `agent()` or `machine()` call, as the host starts it.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    /// The call order in the run: the n-th step the script created.
    pub id: u64,
    pub kind: StepKind,
    /// The prompt or the command.
    pub input: String,
    /// The options the script passed (`schema`, `harness`, `model`, `on`, …).
    pub options: Value,
    pub label: Option<String>,
    pub phase: Option<String>,
    /// A handle the host gave this step before: a previous execution's, to
    /// reattach, or this one's for `follow_up`.
    pub resume: Option<String>,
    /// For an agent: send this message to the `resume` session instead of
    /// starting with `input` (a reply that did not match its schema).
    pub follow_up: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Output {
    /// The agent's final reply, and its session for a follow-up.
    Agent {
        text: String,
        session: Option<String>,
    },
    Machine {
        exit: i32,
        log: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Completion {
    pub id: u64,
    /// `Err` when the step failed for good: the host already applied its
    /// stall policy (`crate::stall`).
    pub result: Result<Output, String>,
}

pub enum Wait {
    Done(Completion),
    /// Stop the run (pause): the host stops running steps, which stay
    /// resumable, and a later run of the same journal continues.
    Stopped,
}

pub trait Host {
    /// Starts `step` and returns at once, with a handle a later execution
    /// can pass back in `Step::resume`.
    fn start(&mut self, step: &Step) -> Result<Option<String>, String>;
    /// Blocks until a started step finishes, or until the run should stop.
    fn wait(&mut self) -> Wait;
    /// `cmux.call(name, arguments)`, answered as code mode answers a script:
    /// `{ok: true, value}` or `{ok: false, message, error}`.
    fn call(&mut self, name: &str, arguments: Map<String, Value>) -> Value;
    /// Progress for the UI (the sidebar run group).
    fn event(&mut self, _event: Event) {}
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Meta(Value),
    Phase(String),
    Log(String),
    Started(Step),
    /// The step's result came from the journal.
    Cached(Step),
    Finished {
        id: u64,
        ok: bool,
    },
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// The engine's heap.
    pub memory: usize,
    /// The script computing this long without a step or call is stopped.
    pub compute: Duration,
    /// `cmux.call`s in one execution (a resume starts the count again).
    pub max_calls: usize,
    /// `agent()` steps in the run, cached ones included.
    pub max_agents: usize,
    /// Steps running at once; more wait their turn.
    pub concurrency: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            memory: 64 << 20,
            compute: Duration::from_secs(30),
            max_calls: 2_000,
            max_agents: 1_000,
            concurrency: 16,
        }
    }
}

pub struct RunInput {
    pub script: String,
    pub args: Option<Value>,
    pub limits: Limits,
}

#[derive(Clone, Debug, PartialEq)]
pub enum RunState {
    Finished(Value),
    Failed(Value),
    Paused,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RunOutcome {
    pub state: RunState,
    pub meta: Option<Value>,
    pub logs: Vec<String>,
    pub dropped_logs: usize,
    /// Steps answered from the journal, and steps that ran.
    pub cached: usize,
    pub live: usize,
}

/// Runs `input.script` once against `journal` and `host`.
pub fn run(input: RunInput, journal: &mut Journal, host: &mut dyn Host) -> RunOutcome {
    let script_hash = hex(&Sha256::digest(input.script.as_bytes()));
    let mut driver = Driver::new(journal, host, input.limits);
    driver.journal(Entry::Run { script: script_hash });
    let from_engine = match engine::spawn(input.script, input.args, input.limits) {
        Ok(receiver) => receiver,
        Err(message) => {
            return driver
                .outcome(RunState::Failed(json!({"code": "script.engine", "message": message})));
        }
    };
    let state = driver.serve(&from_engine);
    driver.outcome(state)
}

struct Live {
    step: Step,
    key: String,
    schema: Option<Value>,
    retried: bool,
}

struct Delivery {
    id: u64,
    ok: bool,
    value: Value,
}

struct Driver<'a> {
    journal: &'a mut Journal,
    host: &'a mut dyn Host,
    limits: Limits,
    /// From the journal: each step's key, start handle and finished value
    /// with its finishing order.
    keys: HashMap<u64, String>,
    handles: HashMap<u64, String>,
    done: HashMap<u64, (usize, Value)>,
    diverged: bool,
    next_id: u64,
    agents: usize,
    running: HashMap<u64, Live>,
    queued: VecDeque<Live>,
    /// Cached results not yet delivered, by first finishing order.
    cached: BTreeMap<usize, (u64, Value)>,
    ready: VecDeque<Delivery>,
    meta: Option<Value>,
    logs: Vec<String>,
    log_bytes: usize,
    dropped_logs: usize,
    cached_count: usize,
    live_count: usize,
    journal_failed: bool,
}

impl<'a> Driver<'a> {
    fn new(journal: &'a mut Journal, host: &'a mut dyn Host, limits: Limits) -> Self {
        let mut keys = HashMap::new();
        let mut handles = HashMap::new();
        let mut done = HashMap::new();
        let mut finished = 0usize;
        for entry in journal.entries() {
            match entry {
                Entry::Run { .. } => {}
                Entry::Started { n, key, handle } => {
                    keys.insert(*n, key.clone());
                    handles.insert(*n, handle.clone());
                }
                Entry::Done { n, key, value } => {
                    keys.insert(*n, key.clone());
                    done.insert(*n, (finished, value.clone()));
                    finished += 1;
                }
            }
        }
        Self {
            journal,
            host,
            limits,
            keys,
            handles,
            done,
            diverged: false,
            next_id: 0,
            agents: 0,
            running: HashMap::new(),
            queued: VecDeque::new(),
            cached: BTreeMap::new(),
            ready: VecDeque::new(),
            meta: None,
            logs: Vec::new(),
            log_bytes: 0,
            dropped_logs: 0,
            cached_count: 0,
            live_count: 0,
            journal_failed: false,
        }
    }

    fn serve(&mut self, from_engine: &mpsc::Receiver<ToDriver>) -> RunState {
        for message in from_engine {
            match message {
                ToDriver::Request(request, reply) => {
                    let answer = match request {
                        Request::Call { name, arguments } => {
                            Reply::Value(self.host.call(&name, arguments))
                        }
                        Request::Start { kind, input, options, phase } => {
                            Reply::Value(self.start(kind, input, options, phase))
                        }
                        Request::Wait => self.wait(),
                    };
                    let _ = reply.send(answer);
                }
                ToDriver::Notice(Notice::Meta(value)) => {
                    self.meta = Some(value.clone());
                    self.host.event(Event::Meta(value));
                }
                ToDriver::Notice(Notice::Phase(title)) => self.host.event(Event::Phase(title)),
                ToDriver::Notice(Notice::Log(line)) => self.log(line),
                ToDriver::Done(Ending::Returned(value)) => return RunState::Finished(value),
                ToDriver::Done(Ending::Threw(error)) => return RunState::Failed(error),
                ToDriver::Done(Ending::Paused) => return RunState::Paused,
            }
        }
        RunState::Failed(json!({"code": "script.engine", "message": "the workflow engine stopped"}))
    }

    fn outcome(self, state: RunState) -> RunOutcome {
        let state = match state {
            RunState::Finished(_) if self.journal_failed => RunState::Failed(json!({
                "code": "workflow.journal",
                "message": "the run finished but its journal could not be written; a resume would rerun steps",
            })),
            state => state,
        };
        RunOutcome {
            state,
            meta: self.meta,
            logs: self.logs,
            dropped_logs: self.dropped_logs,
            cached: self.cached_count,
            live: self.live_count,
        }
    }

    fn start(
        &mut self,
        kind: StepKind,
        input: String,
        options: Value,
        phase: Option<String>,
    ) -> Value {
        let schema = match options.get("schema") {
            Some(schema) if kind == StepKind::Agent => match schema::compile(schema) {
                Ok(_) => Some(schema.clone()),
                Err(message) => return refusal("usage.invalid", &message),
            },
            _ => None,
        };
        if kind == StepKind::Agent {
            if self.agents >= self.limits.max_agents {
                return refusal(
                    "workflow.too_many_agents",
                    &format!("a workflow runs at most {} agents", self.limits.max_agents),
                );
            }
            self.agents += 1;
        }
        let id = self.next_id;
        self.next_id += 1;
        let key = step_key(kind, &input, &options);
        let text = |name: &str| options.get(name).and_then(Value::as_str).map(str::to_owned);
        let label = text("label");
        let phase = text("phase").or(phase);
        let mut step =
            Step { id, kind, input, options, label, phase, resume: None, follow_up: None };
        if !self.diverged && self.keys.get(&id) == Some(&key) {
            if let Some((order, value)) = self.done.get(&id).cloned() {
                self.cached_count += 1;
                self.host.event(Event::Cached(step));
                self.cached.insert(order, (id, value));
                return json!({"ok": true, "id": id});
            }
            step.resume = self.handles.get(&id).cloned();
        } else if !self.diverged {
            // The first step that differs: it and every later step run.
            self.diverged = true;
        }
        self.queued.push_back(Live { step, key, schema, retried: false });
        self.pump();
        json!({"ok": true, "id": id})
    }

    /// Starts queued steps while there is room.
    fn pump(&mut self) {
        while self.running.len() < self.limits.concurrency.max(1) {
            let Some(live) = self.queued.pop_front() else { break };
            self.launch(live);
        }
    }

    fn launch(&mut self, live: Live) {
        let id = live.step.id;
        match self.host.start(&live.step) {
            Ok(handle) => {
                if live.step.follow_up.is_none() {
                    self.live_count += 1;
                    if let Some(handle) = handle {
                        self.journal(Entry::Started { n: id, key: live.key.clone(), handle });
                    }
                    self.host.event(Event::Started(live.step.clone()));
                }
                self.running.insert(id, live);
            }
            Err(message) => self.fail(&live.step, message),
        }
    }

    fn wait(&mut self) -> Reply {
        loop {
            if let Some(delivery) = self.ready.pop_front() {
                return Reply::Deliver { id: delivery.id, ok: delivery.ok, value: delivery.value };
            }
            if let Some((_, (id, value))) = self.cached.pop_first() {
                return Reply::Deliver { id, ok: true, value };
            }
            self.pump();
            if self.running.is_empty() {
                if self.ready.is_empty() {
                    return Reply::Idle;
                }
                continue;
            }
            match self.host.wait() {
                Wait::Stopped => return Reply::Stopped,
                Wait::Done(completion) => self.complete(completion),
            }
        }
    }

    fn complete(&mut self, completion: Completion) {
        let Some(mut live) = self.running.remove(&completion.id) else { return };
        let value = match completion.result {
            Err(message) => return self.fail(&live.step, message),
            Ok(Output::Machine { exit: 0, log }) => json!({"exit": 0, "log": log}),
            Ok(Output::Machine { exit, log }) => {
                self.host.event(Event::Finished { id: live.step.id, ok: false });
                self.ready.push_back(Delivery {
                    id: live.step.id,
                    ok: false,
                    value: json!({
                        "code": "machine.failed",
                        "message": format!("`{}` exited {exit}", live.step.input),
                        "exit": exit,
                        "log": log,
                    }),
                });
                return;
            }
            Ok(Output::Agent { text, session }) => match &live.schema {
                None => Value::String(text),
                Some(schema) => {
                    let checked = schema::compile(schema)
                        .and_then(|validator| schema::check(&text, &validator));
                    match checked {
                        Ok(value) => value,
                        Err(problem) if !live.retried && session.is_some() => {
                            live.retried = true;
                            live.step.resume = session;
                            live.step.follow_up = Some(format!(
                                "Your reply did not match the required JSON schema: {problem}. Reply again \
                                 with only a JSON value that matches this schema: {schema}"
                            ));
                            return self.launch(live);
                        }
                        Err(problem) => {
                            return self.fail(
                                &live.step,
                                format!("the reply did not match its schema: {problem}"),
                            );
                        }
                    }
                }
            },
        };
        self.journal(Entry::Done { n: live.step.id, key: live.key, value: value.clone() });
        self.host.event(Event::Finished { id: live.step.id, ok: true });
        self.ready.push_back(Delivery { id: live.step.id, ok: true, value });
    }

    /// A step that failed for good: an agent resolves to null (as in Claude
    /// Code workflows), a machine step rejects. Neither is journaled, so a
    /// resume tries it again.
    fn fail(&mut self, step: &Step, message: String) {
        self.host.event(Event::Finished { id: step.id, ok: false });
        let name =
            step.label.clone().unwrap_or_else(|| format!("{} {}", step.kind.name(), step.id));
        self.log(format!("[warn] {name} failed: {message}"));
        let (ok, value) = match step.kind {
            StepKind::Agent => (true, Value::Null),
            StepKind::Machine => (false, json!({"code": "machine.failed", "message": message})),
        };
        self.ready.push_back(Delivery { id: step.id, ok, value });
    }

    fn journal(&mut self, entry: Entry) {
        if let Err(error) = self.journal.append(entry) {
            if !self.journal_failed {
                self.log(format!("[error] journal: {error}"));
            }
            self.journal_failed = true;
        }
    }

    fn log(&mut self, line: String) {
        if self.log_bytes + line.len() + 1 > MAX_LOG_BYTES {
            self.dropped_logs += 1;
        } else {
            self.log_bytes += line.len() + 1;
            self.logs.push(line.clone());
        }
        self.host.event(Event::Log(line));
    }
}

fn refusal(code: &str, message: &str) -> Value {
    json!({"ok": false, "message": message, "error": {"code": code, "message": message}})
}

/// A step's journal key: what it runs, not how it is shown (label, phase).
pub(crate) fn step_key(kind: StepKind, input: &str, options: &Value) -> String {
    let mut options = options.clone();
    if let Some(options) = options.as_object_mut() {
        options.remove("label");
        options.remove("phase");
    }
    let mut text = String::new();
    canonical(&json!({"kind": kind.name(), "input": input, "options": options}), &mut text);
    hex(&Sha256::digest(text.as_bytes())[..16])
}

/// JSON with object keys sorted, so equal values hash the same whatever
/// order the script wrote them in.
fn canonical(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut keys = map.keys().collect::<Vec<_>>();
            keys.sort();
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                canonical(&map[key], out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(item, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
