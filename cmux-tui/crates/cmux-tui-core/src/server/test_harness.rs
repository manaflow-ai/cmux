//! The stateful request fuzzer's harness (plans/cmux-next/chrome-parity/
//! p10-stability.md, task 176), Chromium's MojoLPM for the daemon
//! (mojo/public/tools/fuzzers/mojolpm.h): sequences of requests, in any
//! order, against one in-memory mux with no PTYs.
//!
//! - The methods and their parameters come from the SDK schema
//!   (spec/sdk-schema.json) through cmux-api-compat's surface flattener, the
//!   same surface its compat guard reads, so a new schema method is fuzzed
//!   with no change here.
//! - Each line goes through a trusted local connection's own dispatch
//!   ([`handle_connection_frame_at`]): head parse, feature routes, the
//!   `Command` decode, the connection's scheduler and the handlers.
//! - Ids are live (in the state now), stale (live earlier, gone now), learned
//!   (a string id a reply carried) or bogus.
//! - After every request: each answer is a typed result or a typed error,
//!   none is answered twice, the layout passes cmux-layout-reducer's
//!   invariants, and with no answer outstanding the durable topology agrees
//!   with memory (mux/fuzz_support.rs).
//!
//! The methods in [`HOST_EFFECTS`] reach outside the process (child
//! processes, sockets, the person's files, the daemon's own exit): their
//! lines are decoded as the dispatcher decodes them but never run.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_api_compat::coverage::{Shape, surface_from_sdk_schema};
use cmux_api_compat::pointer::{self, WILDCARD};
use cmux_threads::checked::sync as waits;
use serde_json::{Map, Value, json};

use super::{
    BoundedOutbound, CONNECTION_SURFACE_SHUTDOWN_TIMEOUT, ClientTransport,
    ConnectionSurfaceScheduler, MessageWriter, OutboundItem, QueuedSink, RenderService, Request,
    RequestHead, disconnect_client, handle_connection_frame_at,
};
use crate::mux::Mux;
use crate::mux::fuzz_support::LiveIds;
use crate::thread_qos::ThreadType;

const SDK_SCHEMA: &str = include_str!("../../../../spec/sdk-schema.json");

/// How long one request waits for its answer. A later answer is still
/// checked when it arrives; until then the durable check waits.
const ANSWER_WAIT: Duration = Duration::from_millis(100);

/// Deepest parameter value built (the flattener stops at 16).
const MAX_VALUE_DEPTH: usize = 8;

/// Learned string ids kept per harness.
const MAX_LEARNED: usize = 64;

/// Methods whose handlers leave the process; decoded, never run.
pub const HOST_EFFECTS: &[(&str, &str)] = &[
    ("shutdown-daemon", "ends the daemon process"),
    ("reload-config", "reads the person's settings files"),
    ("trace-start", "writes a trace file"),
    ("ws-listen", "opens a TCP listener"),
    ("cloud-session-set", "points the daemon at a network host"),
    ("cloud-host-replica-set", "points the daemon at a network host"),
    ("register-browser-provider", "makes the daemon dial a given socket"),
    ("browser-host-provider", "starts the browser host process"),
    ("browser-runtime-start", "starts the browser runtime process"),
    ("loopback-open", "dials a local TCP port"),
    ("machine-listening-tcp", "runs a child process to list ports"),
    ("terminal-ports", "runs a child process to list ports"),
    // Its time is the machine's process count, not the input's: 1.9 s under
    // ASan on a VM with 24,000 processes (a libFuzzer timeout).
    ("terminal-resources", "scans every process on the machine"),
    ("script-run", "runs script code"),
    ("script-repl-open", "starts a script runtime"),
    ("script-repl-eval", "runs script code"),
    ("agent-session-start", "starts an agent CLI"),
    ("agent-inventory-refresh", "runs agent CLIs for their versions"),
    ("agent-update-apply", "installs agent updates"),
    ("apps-run", "starts an app process"),
    ("apps-mount", "mounts a directory of the person's"),
    ("conversation-import", "reads other agents' session files"),
    ("paste-image", "writes the image spool"),
    ("agent-transfer-begin", "reads files for a transfer"),
    ("agent-transfer-receive", "writes received files"),
    ("agent-transfer-source", "reads files for a transfer"),
];

/// Something the fuzzer found, or a harness that could not start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Finding {
    /// The schema or the in-memory daemon could not be set up.
    Setup(String),
    /// An answer is not `{ok: true, ...}` or `{ok: false, error: <string>}`.
    UntypedAnswer { method: String, answer: String },
    /// A request was answered twice.
    AnsweredTwice { method: String, answer: String },
    /// The state after `method` breaks a layout invariant.
    Layout { method: String, violations: Vec<String> },
    /// After `method`, the durable topology and memory disagree.
    Durable { method: String, mismatches: Vec<String> },
}

impl std::fmt::Display for Finding {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Setup(why) => write!(f, "request harness setup failed: {why}"),
            Self::UntypedAnswer { method, answer } => {
                write!(f, "{method}: answer is neither a typed result nor an error: {answer}")
            }
            Self::AnsweredTwice { method, answer } => {
                write!(f, "{method}: answered twice: {answer}")
            }
            Self::Layout { method, violations } => {
                write!(f, "{method}: layout invariants broken: {violations:?}")
            }
            Self::Durable { method, mismatches } => {
                write!(f, "{method}: durable topology differs from memory: {mismatches:?}")
            }
        }
    }
}

impl std::error::Error for Finding {}

fn setup(error: impl std::fmt::Display) -> Finding {
    Finding::Setup(error.to_string())
}

/// Where the generator's decisions come from: the fuzzer's input, or a
/// seeded sequence in tests.
pub trait Choices {
    /// A number in `0..n` (`n > 0`); 0 once the input is used up.
    fn below(&mut self, n: usize) -> usize;
    /// The input is used up.
    fn exhausted(&self) -> bool;
}

/// One parameter of a method: its shape and its members, by pointer token
/// (`*` for every array element or map value).
#[derive(Clone, Debug, Default)]
struct Member {
    shape: Option<Shape>,
    children: BTreeMap<String, Member>,
}

impl Member {
    fn insert(&mut self, tokens: &[String], shape: Shape) {
        match tokens.split_first() {
            None => self.shape = Some(shape),
            Some((first, rest)) => {
                self.children.entry(first.clone()).or_default().insert(rest, shape);
            }
        }
    }

    fn required(&self) -> bool {
        self.shape.as_ref().is_some_and(|shape| shape.required)
    }

    fn nullable(&self) -> bool {
        self.shape.as_ref().is_some_and(|shape| shape.nullable)
    }
}

/// One schema method.
#[derive(Clone, Debug)]
struct Method {
    name: String,
    params: Member,
    host_effect: bool,
}

/// Every method of the SDK schema with its request parameters.
#[derive(Clone, Debug)]
pub struct RequestCatalog {
    methods: Vec<Method>,
}

impl RequestCatalog {
    /// The daemon's own schema (spec/sdk-schema.json).
    pub fn daemon() -> Result<Self, Finding> {
        let schema: Value = serde_json::from_str(SDK_SCHEMA).map_err(setup)?;
        Self::from_sdk_schema(&schema)
    }

    /// The methods of an SDK schema IR.
    pub fn from_sdk_schema(schema: &Value) -> Result<Self, Finding> {
        let commands = schema
            .get("commands")
            .and_then(Value::as_object)
            .ok_or_else(|| setup("the SDK schema has no commands"))?;
        let surface = surface_from_sdk_schema(schema);
        let mut methods = Vec::with_capacity(commands.len());
        for name in commands.keys() {
            let mut params = Member::default();
            if let Some(entries) = surface.get(&format!("request:{name}")) {
                for (at, shape) in entries {
                    let tokens = pointer::parse(at).map_err(setup)?;
                    params.insert(&tokens, shape.clone());
                }
            }
            let host_effect = HOST_EFFECTS.iter().any(|(effect, _)| effect == name);
            methods.push(Method { name: name.clone(), params, host_effect });
        }
        if methods.is_empty() {
            return Err(setup("the SDK schema has no commands"));
        }
        Ok(Self { methods })
    }

    /// The method names, in schema order.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.methods.iter().map(|method| method.name.as_str())
    }

    /// Whether `name` is decoded only ([`HOST_EFFECTS`]).
    pub fn is_host_effect(&self, name: &str) -> bool {
        self.methods.iter().any(|method| method.name == name && method.host_effect)
    }

    fn method(&self, index: usize) -> Option<&Method> {
        self.methods.get(index)
    }
}

/// Every id the harness has seen live, by kind; with the live ids, the
/// stale ones.
#[derive(Default)]
struct Seen {
    workspaces: BTreeSet<u64>,
    screens: BTreeSet<u64>,
    panes: BTreeSet<u64>,
    surfaces: BTreeSet<u64>,
    splits: BTreeSet<u64>,
    names: BTreeSet<String>,
}

impl Seen {
    fn add(&mut self, live: &LiveIds) {
        self.workspaces.extend(&live.workspaces);
        self.screens.extend(&live.screens);
        self.panes.extend(&live.panes);
        self.surfaces.extend(&live.surfaces);
        self.splits.extend(&live.splits);
        self.names.extend(live.names.iter().cloned());
    }
}

/// The id kind a parameter's name asks for.
#[derive(Clone, Copy)]
enum IdKind {
    Workspace,
    Screen,
    Pane,
    Surface,
    Split,
    Any,
}

impl IdKind {
    fn of(key: &str) -> Self {
        if key.contains("workspace") {
            Self::Workspace
        } else if key.contains("screen") {
            Self::Screen
        } else if key.contains("pane") {
            Self::Pane
        } else if key.contains("surface") || key.contains("tab") {
            Self::Surface
        } else if key.contains("split") {
            Self::Split
        } else {
            Self::Any
        }
    }

    fn live(self, ids: &LiveIds) -> Vec<u64> {
        match self {
            Self::Workspace => ids.workspaces.clone(),
            Self::Screen => ids.screens.clone(),
            Self::Pane => ids.panes.clone(),
            Self::Surface => ids.surfaces.clone(),
            Self::Split => ids.splits.clone(),
            Self::Any => [&ids.workspaces, &ids.screens, &ids.panes, &ids.surfaces, &ids.splits]
                .into_iter()
                .flatten()
                .copied()
                .collect(),
        }
    }

    fn seen(self, seen: &Seen) -> Vec<u64> {
        let sets = match self {
            Self::Workspace => vec![&seen.workspaces],
            Self::Screen => vec![&seen.screens],
            Self::Pane => vec![&seen.panes],
            Self::Surface => vec![&seen.surfaces],
            Self::Split => vec![&seen.splits],
            Self::Any => {
                vec![&seen.workspaces, &seen.screens, &seen.panes, &seen.surfaces, &seen.splits]
            }
        };
        sets.into_iter().flatten().copied().collect()
    }
}

/// Strings that are no id of anything, and edge cases of every string field.
const BOGUS_STRINGS: &[&str] = &[
    "",
    "x",
    "0",
    "-1",
    "*",
    "/",
    "..",
    "main",
    "w:1",
    "\u{0}",
    "\u{1b}[31m",
    "é漢",
    "00000000000000000000000000000000",
];

/// Builds one request line from the choices.
struct Generator<'a> {
    choices: &'a mut dyn Choices,
    live: &'a LiveIds,
    seen: &'a Seen,
    learned: &'a [String],
}

impl Generator<'_> {
    fn below(&mut self, n: usize) -> usize {
        self.choices.below(n.max(1))
    }

    fn pick<T: Clone>(&mut self, items: &[T]) -> Option<T> {
        if items.is_empty() {
            return None;
        }
        let index = self.below(items.len());
        items.get(index).cloned()
    }

    fn line(&mut self, method: &Method, id: u64) -> String {
        let mut line = self.object(&method.params, 0);
        line.insert("cmd".into(), json!(method.name));
        line.insert("id".into(), json!(id));
        Value::Object(line).to_string()
    }

    fn object(&mut self, member: &Member, depth: usize) -> Map<String, Value> {
        let mut object = Map::new();
        for (key, child) in &member.children {
            if key == WILDCARD {
                continue;
            }
            // A required member is left out now and then, an optional one half the time.
            let include = if child.required() { self.below(16) != 0 } else { self.below(2) == 0 };
            if include {
                let value = self.value(key, child, depth + 1);
                object.insert(key.clone(), value);
            }
        }
        object
    }

    fn value(&mut self, key: &str, member: &Member, depth: usize) -> Value {
        if depth > MAX_VALUE_DEPTH {
            return Value::Null;
        }
        // A value of the wrong type, one in sixteen.
        if self.below(16) == 0 {
            return self
                .pick(&[Value::Null, json!(true), json!(0), json!(""), json!([]), json!({})])
                .unwrap_or(Value::Null);
        }
        if member.nullable() && self.below(8) == 0 {
            return Value::Null;
        }
        let types = member.shape.as_ref().map_or("object", |shape| shape.ty.as_str());
        let alternatives = types.split('|').collect::<Vec<_>>();
        let ty = self.pick(&alternatives).unwrap_or("object");
        if let Some(item) = member.children.get(WILDCARD) {
            let count = self.below(3);
            if ty == "map" || ty == "object" {
                let mut map = Map::new();
                for _ in 0..count {
                    let name = self.string();
                    let value = self.value(key, item, depth + 1);
                    map.insert(name.as_str().unwrap_or_default().to_owned(), value);
                }
                return Value::Object(map);
            }
            return Value::Array((0..count).map(|_| self.value(key, item, depth + 1)).collect());
        }
        if !member.children.is_empty() {
            return Value::Object(self.object(member, depth));
        }
        let values = member
            .shape
            .as_ref()
            .map(|shape| shape.values.iter().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        self.scalar(key, ty, &values)
    }

    fn scalar(&mut self, key: &str, ty: &str, values: &[String]) -> Value {
        match ty {
            "boolean" => json!(self.below(2) == 1),
            "uint64" | "uint32" | "uint16" | "uint8" | "int64" | "int32" => self.number(key, ty),
            "float32" | "float64" => self
                .pick(&[json!(0.0), json!(0.5), json!(1.0), json!(-1.0), json!(1e9)])
                .unwrap_or(Value::Null),
            "enum" | "literal" if !values.is_empty() && self.below(8) != 0 => {
                let value = self.pick(values).unwrap_or_default();
                // Literals are stored as JSON (`"\"leaf\""`), enum values bare.
                serde_json::from_str(&value).unwrap_or(Value::String(value))
            }
            "string" | "enum" | "literal" => self.string(),
            "array" => json!([]),
            _ => json!({}),
        }
    }

    fn number(&mut self, key: &str, ty: &str) -> Value {
        // A wait field stays short, so a legal long wait is not a timeout finding.
        if key.ends_with("_ms") {
            return json!(self.below(51));
        }
        let kind = IdKind::of(key);
        match self.below(6) {
            0 | 1 => {
                if let Some(id) = self.pick(&kind.live(self.live)) {
                    return json!(id);
                }
            }
            2 => {
                if let Some(id) = self.pick(&kind.seen(self.seen)) {
                    return json!(id);
                }
            }
            _ => {}
        }
        let max = match ty {
            "uint8" => u64::from(u8::MAX),
            "uint16" => u64::from(u16::MAX),
            "uint32" | "int32" => u64::from(u32::MAX),
            _ => u64::MAX,
        };
        match self.below(6) {
            0 => json!(0),
            1 => json!(max),
            2 if ty.starts_with("int") => json!(-1),
            3 => json!(u64::MAX),
            _ => json!(self.below(64)),
        }
    }

    fn string(&mut self) -> Value {
        let live = self.live.names.iter().chain(self.learned).cloned().collect::<Vec<_>>();
        let stale = self.seen.names.iter().cloned().collect::<Vec<_>>();
        let picked = match self.below(5) {
            0 | 1 => self.pick(&live),
            2 => self.pick(&stale),
            3 => self.pick(BOGUS_STRINGS).map(str::to_owned),
            _ => {
                let length = self.below(9);
                Some((0..length).map(|_| char::from(b' ' + self.below(95) as u8)).collect())
            }
        };
        Value::String(picked.unwrap_or_default())
    }
}

/// One trusted local connection: what a socket client gets, with the
/// writer thread's socket replaced by a channel.
struct Connection {
    client: u64,
    writer: MessageWriter,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    answers: Receiver<Value>,
    drain: Option<JoinHandle<()>>,
}

impl Connection {
    fn open(mux: &Arc<Mux>) -> Result<Self, Finding> {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: outbound.clone(), control: None },
            Arc::new(RenderService::new()),
        );
        // Unbounded on purpose: the drain must never wait for the harness,
        // or a full queue would hold a handler that the harness is running.
        let (sender, answers) = channel();
        let drain = cmux_threads::spawn("mux-fuzz-out", ThreadType::Interactive.qos(), move || {
            while let Some(item) = outbound.recv() {
                match item {
                    OutboundItem::Text(text) => {
                        if let Ok(value) = serde_json::from_str::<Value>(&text.text)
                            && sender.send(value).is_err()
                        {
                            break;
                        }
                    }
                    OutboundItem::Flush(flushed) => {
                        let _ = flushed.send(());
                    }
                    OutboundItem::Frame(..) | OutboundItem::Chunk { .. } => {}
                }
            }
        })
        .map_err(setup)?;
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler = Arc::new(
            ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone())
                .classed(mux.control_clients.connection_class(client)),
        );
        Ok(Self { client, writer, scheduler, answers, drain: Some(drain) })
    }

    /// Ends the connection as a socket close does.
    fn close(mut self, mux: &Arc<Mux>) {
        let _ = self.scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
        disconnect_client(mux, self.client, false);
        self.writer.close();
        if let Some(drain) = self.drain.take() {
            let _ = waits::join(drain);
        }
    }
}

/// What one run did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RunSummary {
    /// Requests dispatched, by method.
    pub dispatched: BTreeMap<String, usize>,
    /// Host-effect lines decoded only, by method.
    pub decoded: BTreeMap<String, usize>,
    /// Answers checked.
    pub answers: usize,
    /// Requests not answered within the wait, by method.
    pub late: BTreeMap<String, usize>,
    /// `ok: true` answers, by method.
    pub succeeded: BTreeMap<String, usize>,
    /// Connections the daemon closed (each reopened).
    pub reconnects: usize,
}

/// One in-memory daemon and one connection to it.
pub struct RequestHarness {
    mux: Arc<Mux>,
    connection: Option<Connection>,
    next_id: u64,
    /// Request id -> method, until answered.
    pending: BTreeMap<u64, String>,
    answered: BTreeMap<u64, String>,
    seen: Seen,
    learned: Vec<String>,
    summary: RunSummary,
}

impl RequestHarness {
    /// A fresh in-memory daemon with one trusted local connection.
    pub fn open() -> Result<Self, Finding> {
        static SESSIONS: AtomicU64 = AtomicU64::new(0);
        let session = format!("request-fuzz-{}", SESSIONS.fetch_add(1, Ordering::Relaxed));
        let mux = Mux::in_memory_for_fuzz(&session).map_err(setup)?;
        let connection = match Connection::open(&mux) {
            Ok(connection) => connection,
            Err(finding) => {
                mux.shutdown();
                return Err(finding);
            }
        };
        Ok(Self {
            mux,
            connection: Some(connection),
            next_id: 1,
            pending: BTreeMap::new(),
            answered: BTreeMap::new(),
            seen: Seen::default(),
            learned: Vec::new(),
            summary: RunSummary::default(),
        })
    }

    /// What the harness did so far.
    pub fn summary(&self) -> &RunSummary {
        &self.summary
    }

    /// Sends one request of the method `choices` picks, then checks the
    /// answers and the state.
    pub fn step(
        &mut self,
        catalog: &RequestCatalog,
        choices: &mut dyn Choices,
    ) -> Result<(), Finding> {
        let index = choices.below(catalog.methods.len().max(1));
        let Some(method) = catalog.method(index) else {
            return Ok(());
        };
        self.send(method, choices)
    }

    /// Sends one request of the method named `name`.
    pub fn step_method(
        &mut self,
        catalog: &RequestCatalog,
        name: &str,
        choices: &mut dyn Choices,
    ) -> Result<(), Finding> {
        let Some(method) = catalog.methods.iter().find(|method| method.name == name) else {
            return Err(setup(format!("no schema method `{name}`")));
        };
        self.send(method, choices)
    }

    fn send(&mut self, method: &Method, choices: &mut dyn Choices) -> Result<(), Finding> {
        let live = self.mux.fuzz_live_ids();
        self.seen.add(&live);
        let id = self.next_id;
        self.next_id += 1;
        let line = Generator { choices, live: &live, seen: &self.seen, learned: &self.learned }
            .line(method, id);
        if method.host_effect {
            decode(&line);
            *self.summary.decoded.entry(method.name.clone()).or_default() += 1;
            return Ok(());
        }
        self.dispatch(&method.name, id, &line)
    }

    /// Sends `line`, whose `id` is `id`, through the connection's dispatch.
    fn dispatch(&mut self, method: &str, id: u64, line: &str) -> Result<(), Finding> {
        let connection = match self.connection.take() {
            Some(connection) => connection,
            None => Connection::open(&self.mux)?,
        };
        *self.summary.dispatched.entry(method.to_owned()).or_default() += 1;
        self.pending.insert(id, method.to_owned());
        let keep_open = handle_connection_frame_at(
            &self.mux,
            connection.client,
            ClientTransport::Unix,
            line,
            &connection.writer,
            &connection.scheduler,
            Instant::now(),
        );
        let collected = self.collect(&connection, id);
        if keep_open {
            self.connection = Some(connection);
        } else {
            // The daemon closed the connection: its unanswered requests end
            // with it, and the next request opens a new one.
            connection.close(&self.mux);
            self.pending.clear();
            self.summary.reconnects += 1;
        }
        collected?;
        self.check(method)
    }

    /// Reads answers until `id` is answered or [`ANSWER_WAIT`] passes.
    fn collect(&mut self, connection: &Connection, id: u64) -> Result<(), Finding> {
        let deadline = Instant::now() + ANSWER_WAIT;
        while self.pending.contains_key(&id) {
            let left = deadline.saturating_duration_since(Instant::now());
            match waits::recv_timeout(&connection.answers, left) {
                Ok(message) => self.answer(message)?,
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => break,
            }
        }
        // Answers that are already here, to earlier requests too.
        while let Ok(message) = connection.answers.try_recv() {
            self.answer(message)?;
        }
        if let Some(method) = self.pending.get(&id) {
            *self.summary.late.entry(method.clone()).or_default() += 1;
        }
        Ok(())
    }

    /// Checks one message: an answer has an `id` this harness sent and an
    /// `ok`; anything else (events, stream items) is not an answer.
    fn answer(&mut self, message: Value) -> Result<(), Finding> {
        let Some(object) = message.as_object() else {
            return Ok(());
        };
        let (Some(id), Some(ok)) = (object.get("id").and_then(Value::as_u64), object.get("ok"))
        else {
            return Ok(());
        };
        if let Some(method) = self.answered.get(&id) {
            return Err(Finding::AnsweredTwice {
                method: method.clone(),
                answer: message.to_string(),
            });
        }
        let Some(method) = self.pending.remove(&id) else {
            return Ok(());
        };
        let typed = match ok {
            Value::Bool(true) => true,
            Value::Bool(false) => object.get("error").is_some_and(Value::is_string),
            _ => false,
        };
        if !typed {
            return Err(Finding::UntypedAnswer { method, answer: message.to_string() });
        }
        if let Some(data) = object.get("data") {
            learn(data, &mut self.learned, 0);
        }
        if ok == &Value::Bool(true) {
            *self.summary.succeeded.entry(method.clone()).or_default() += 1;
        }
        self.answered.insert(id, method);
        self.summary.answers += 1;
        Ok(())
    }

    fn check(&self, method: &str) -> Result<(), Finding> {
        let violations = self.mux.fuzz_layout_violations();
        if !violations.is_empty() {
            return Err(Finding::Layout { method: method.to_owned(), violations });
        }
        if self.pending.is_empty() {
            let mismatches = self.mux.fuzz_durable_mismatches().map_err(setup)?;
            if !mismatches.is_empty() {
                return Err(Finding::Durable { method: method.to_owned(), mismatches });
            }
        }
        Ok(())
    }
}

impl Drop for RequestHarness {
    /// Closes the connection and shuts the daemon down.
    fn drop(&mut self) {
        if let Some(connection) = self.connection.take() {
            connection.close(&self.mux);
        }
        self.mux.shutdown();
    }
}

/// Records, and does not panic at, a blocking call on a request thread,
/// unless `CMUX_DAEMON_BLOCKING` says otherwise. Those sites are the
/// p02-threads sweep's (`server-blocking`, MQ-13); this fuzzer looks for
/// crashes and broken invariants past them. The mode is process-wide.
pub fn record_request_thread_blocking() {
    if std::env::var_os(cmux_threads::blocking::MODE_ENV).is_none() {
        cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
    }
}

/// The dispatcher's decode of a line it does not run: its head, then the
/// `Command` it names. Either may refuse the line; neither may panic.
fn decode(line: &str) {
    let head = RequestHead::parse(line);
    if head.is_command() {
        let _ = crate::line_parses::parse::<Request>(line);
    }
}

/// String ids an answer hands back (`"group": "tg-..."`, `"tab_id"`), for
/// later requests to name.
fn learn(value: &Value, learned: &mut Vec<String>, depth: usize) {
    if depth > MAX_VALUE_DEPTH || learned.len() >= MAX_LEARNED {
        return;
    }
    match value {
        Value::Object(object) => {
            for (key, value) in object {
                match value {
                    Value::String(text)
                        if (key == "id" || key.ends_with("_id") || key == "group")
                            && !learned.contains(text) =>
                    {
                        learned.push(text.clone());
                    }
                    _ => learn(value, learned, depth + 1),
                }
                if learned.len() >= MAX_LEARNED {
                    return;
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                learn(item, learned, depth + 1);
            }
        }
        _ => {}
    }
}

/// Runs up to `max_steps` requests from `choices` on a fresh daemon.
pub fn run(
    catalog: &RequestCatalog,
    choices: &mut dyn Choices,
    max_steps: usize,
) -> Result<RunSummary, Finding> {
    let mut harness = RequestHarness::open()?;
    let mut result = Ok(());
    for _ in 0..max_steps {
        if choices.exhausted() {
            break;
        }
        result = harness.step(catalog, choices);
        if result.is_err() {
            break;
        }
    }
    let summary = harness.summary().clone();
    drop(harness);
    result.map(|()| summary)
}

#[cfg(test)]
#[path = "test_harness_tests.rs"]
mod tests;
