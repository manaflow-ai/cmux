//! The other MCP servers of an agent chat, behind `cmux mcp serve` (code
//! mode for everything cmux gives an agent). acpmux folds its computer use,
//! secret and session offer servers into the `cmux` server's env as
//! [`ENV`] (acpmux `agent_tools::UPSTREAMS_ENV`): their exact command, args
//! and env, already scoped to the session. This server starts each one as a
//! stdio MCP client on first use and lists its tools as
//! `<prefix>_<tool>` (`cmux-cua` is `cua`), so `cmux_docs` finds them and a
//! `cmux_exec` script calls them through `Server::call`, under the same
//! allowlist as every other tool. A list from an earlier start
//! (`upstream_listing.rs`) answers `tools/list` without starting the server,
//! so a chat that never calls one of its tools never starts it.
//!
//! Servers whose specs name the same `shared` launch (acpmux's own five, `acpmux tools-mcp`,
//! `tools_mcp.rs`) run in one process: each sends its requests with its name in `_meta`
//! ([`acpmux::tools_mcp::SERVER_META`]), and each answer goes back to the request that waits
//! for it, so a call that waits (a secret card) holds no other server's call.

use std::collections::{BTreeSet, HashMap};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::computer_use_gate::{self, Gate};
use cmux_json::JsonSet as _;

/// The env acpmux gives the `cmux` server: a JSON array of
/// `{name, command, args, env}`.
pub(super) const ENV: &str = "CMUX_MCP_UPSTREAMS";

/// Each start step (`initialize`, a `tools/list` page). Short: a harness
/// waits for this server's own first `tools/list` (Codex about 10 s).
const START_TIMEOUT: Duration = Duration::from_secs(5);
/// After a failed start, the tools stay out this long before a new try,
/// so a slow or broken server does not slow every list.
const START_BACKOFF: Duration = Duration::from_secs(60);
/// One call, unless the spec says (`callTimeoutSecs`: acpmux gives the
/// secret card, which waits for the person, an hour).
const CALL_TIMEOUT: Duration = Duration::from_secs(300);
const PROTOCOL_VERSION: &str = "2025-06-18";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Spec {
    pub name: String,
    pub command: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub call_timeout: Duration,
    /// The process it runs in with other servers (acpmux's `shared`), instead of its own.
    pub shared: Option<Launch>,
}

/// A process to start: its command, args and env.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Launch {
    pub command: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl Launch {
    /// `{command, args, env}` in a spec, or None when it is not that.
    fn from_json(item: &Value) -> Option<Self> {
        let command = PathBuf::from(item["command"].as_str()?);
        let args = item["args"]
            .as_array()
            .map(|args| args.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();
        let env = item["env"]
            .as_object()
            .map(|env| {
                env.iter()
                    .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                    .collect()
            })
            .unwrap_or_default();
        Some(Self { command, args, env })
    }
}

/// The servers in `value` (the env's JSON). A bad entry is left out and
/// said on stderr; a bad list is no servers.
pub(super) fn specs(value: Option<std::ffi::OsString>) -> Vec<Spec> {
    let Some(value) = value else { return Vec::new() };
    let parsed = value.to_str().and_then(|text| serde_json::from_str::<Value>(text).ok());
    let Some(Value::Array(items)) = parsed else {
        eprintln!("cmux mcp: {ENV} is not a JSON array; no other servers");
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let name = item["name"].as_str()?.to_owned();
            let Launch { command, args, env } = Launch::from_json(item)?;
            let call_timeout = item["callTimeoutSecs"]
                .as_u64()
                .map_or(CALL_TIMEOUT, |secs| Duration::from_secs(secs.clamp(1, 24 * 3600)));
            let shared = item.get("shared").and_then(Launch::from_json);
            Some(Spec { name, command, args, env, call_timeout, shared })
        })
        .collect()
}

/// What a proxied tool's description puts between its own text and its
/// server's rules: `\n\n<server> rules: <rules>`.
const RULES_BREAK: &str = "\n\n";
const RULES_LABEL: &str = " rules: ";

/// A proxied tool's own description, without the server rules added to it:
/// docs search matches what a tool does, not the rules every tool of its
/// server shares (they name terminals, messages, files and passwords).
pub(super) fn without_rules(description: &str) -> &str {
    let mut from = 0;
    while let Some(at) = description.get(from..).and_then(|tail| tail.find(RULES_BREAK)) {
        let start = from + at;
        let rest = description.get(start + RULES_BREAK.len()..).unwrap_or_default();
        if let Some((server, _)) = rest.split_once(RULES_LABEL)
            && !server.is_empty()
            && !server.contains(char::is_whitespace)
        {
            return description.get(..start).unwrap_or(description);
        }
        from = start + RULES_BREAK.len();
    }
    description
}

/// The tool name prefix of server `name`: `cmux-cua` is `cua`.
fn prefix(name: &str) -> String {
    let name = name.strip_prefix("cmux-").unwrap_or(name);
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
        .collect()
}

/// The rules the model gets for server `spec`: cmux's own rules for its
/// computer use server ([`acpmux::agent_tools::CUA_RULES`]) first, then the
/// server's `initialize` instructions. The helper v2 bridge has the same name
/// (its spec names the endpoint folder), but no target guard yet: its chats
/// get no cmux rules, which promise one.
pub(super) fn rules(spec: &Spec, own: Option<&str>) -> Option<String> {
    let own = own.filter(|text| !text.trim().is_empty());
    let v2 = spec.env.iter().any(|(key, _)| key == acpmux::cua_v2::ENDPOINT_DIR_ENV);
    let cmux =
        (spec.name == acpmux::cua_v2::SERVER_NAME && !v2).then_some(acpmux::agent_tools::CUA_RULES);
    match (cmux, own) {
        (Some(cmux), Some(own)) => Some(format!("{cmux}\n\n{own}")),
        (Some(cmux), None) => Some(cmux.to_owned()),
        (None, own) => own.map(str::to_owned),
    }
}

/// One server: started on first use, again after it dies or times out.
pub(super) struct Upstream {
    spec: Spec,
    pub prefix: String,
    conn: Option<Arc<Conn>>,
    /// Its tools as the server lists them (original names).
    tools: Option<Vec<Value>>,
    pub instructions: Option<String>,
    /// Why and when the last start failed: said once, retried after
    /// `START_BACKOFF`.
    failed: Option<(String, Instant)>,
    /// Where lists from earlier starts are kept (`upstream_listing.rs`).
    listings: Option<PathBuf>,
}

/// Why a request has no result.
enum Failure {
    /// The server answered with a JSON-RPC error: the call did not run and
    /// the connection is fine.
    Refused(String),
    /// No answer (timeout, exit, closed pipe): the call may have run.
    Lost(String),
}

impl Failure {
    fn message(self) -> String {
        match self {
            Failure::Refused(message) | Failure::Lost(message) => message,
        }
    }
}

/// A running server process. Requests go out on its stdin, and a thread reads its stdout and
/// gives each answer to the request that waits for it (by id), so the servers that share it
/// (`Spec::shared`) call it at the same time. It ends when the last upstream holding it lets go.
struct Conn {
    child: Mutex<Child>,
    wire: Arc<Wire>,
}

/// What the reader thread shares with the requests (never the child: it ends the process).
struct Wire {
    stdin: Mutex<ChildStdin>,
    waiting: Mutex<HashMap<u64, mpsc::Sender<Value>>>,
    next_id: AtomicU64,
    /// Its stdout ended: the process exited or closed it.
    ended: AtomicBool,
}

impl Drop for Conn {
    fn drop(&mut self) {
        let mut child = self.child.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// The processes of shared launches, while an upstream holds one.
static SHARED: Mutex<Vec<(Launch, Weak<Conn>)>> = Mutex::new(Vec::new());

impl Conn {
    /// `launch` started, its stdout read on a thread named for `prefix`.
    fn start(launch: &Launch, prefix: &str) -> Result<Self, String> {
        let mut child = Command::new(&launch.command)
            .args(&launch.args)
            // This server's own folding and allowlist stay with it.
            .env_remove(ENV)
            .envs(launch.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|error| format!("cannot start {}: {error}", launch.command.display()))?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let wire = Arc::new(Wire {
            stdin: Mutex::new(stdin),
            waiting: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            ended: AtomicBool::new(false),
        });
        let reader = wire.clone();
        let read = std::thread::Builder::new()
            .name(format!("cmux-mcp-upstream-{prefix}"))
            .spawn(move || reader.read(stdout));
        let conn = Self { child: Mutex::new(child), wire };
        // Dropped on failure: the child ends with it.
        read.map_err(|error| error.to_string())?;
        Ok(conn)
    }

    /// The running process of `launch` other upstreams hold, else a new one.
    fn shared(launch: &Launch, prefix: &str) -> Result<Arc<Self>, String> {
        let mut shared = SHARED.lock().unwrap_or_else(PoisonError::into_inner);
        shared.retain(|(_, conn)| conn.upgrade().is_some_and(|conn| conn.alive()));
        if let Some(conn) =
            shared.iter().find(|(running, _)| running == launch).and_then(|(_, c)| c.upgrade())
        {
            return Ok(conn);
        }
        let conn = Arc::new(Self::start(launch, prefix)?);
        shared.push((launch.clone(), Arc::downgrade(&conn)));
        Ok(conn)
    }

    fn alive(&self) -> bool {
        !self.wire.ended.load(Ordering::SeqCst)
    }

    fn notify(&self, method: &str) -> Result<(), String> {
        self.wire
            .write(&json!({"jsonrpc": "2.0", "method": method}))
            .map_err(|error| format!("write: {error}"))
    }

    /// One request, answered or not within `timeout`.
    fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, Failure> {
        let wire = &self.wire;
        let id = wire.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        wire.waiting.lock().unwrap_or_else(PoisonError::into_inner).insert(id, tx);
        let forget = || {
            wire.waiting.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
        };
        // The reader marks the end before it lets go of the waiting requests: one added after
        // that sees the mark.
        if !self.alive() {
            forget();
            return Err(Failure::Lost(format!("the server exited before {method}")));
        }
        let message = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if let Err(error) = wire.write(&message) {
            forget();
            return Err(Failure::Lost(format!("the server closed its input: {error}")));
        }
        let reply = match rx.recv_timeout(timeout) {
            Ok(reply) => reply,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                forget();
                let secs = timeout.as_secs();
                return Err(Failure::Lost(format!("no answer to {method} in {secs} s")));
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(Failure::Lost(format!("the server exited during {method}")));
            }
        };
        if let Some(error) = reply.get("error") {
            return Err(Failure::Refused(error["message"].as_str().unwrap_or("error").to_owned()));
        }
        Ok(reply["result"].clone())
    }
}

impl Wire {
    fn write(&self, message: &Value) -> std::io::Result<()> {
        let mut stdin = self.stdin.lock().unwrap_or_else(PoisonError::into_inner);
        writeln!(stdin, "{message}").and_then(|()| stdin.flush())
    }

    /// Gives each answer on `stdout` to its request; answers the server's own requests with
    /// method not found and skips its notifications. At the end, every waiting request learns
    /// that the server is gone.
    fn read(&self, stdout: std::process::ChildStdout) {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply.get("method").is_some() {
                if let Some(their_id) = reply.get("id") {
                    let refused = json!({"jsonrpc": "2.0", "id": their_id,
                        "error": {"code": -32601, "message": "not supported by cmux"}});
                    let _ = self.write(&refused);
                }
                continue;
            }
            let Some(id) = reply["id"].as_u64() else { continue };
            let waiter = self.waiting.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            if let Some(waiter) = waiter {
                let _ = waiter.send(reply);
            }
        }
        self.ended.store(true, Ordering::SeqCst);
        self.waiting.lock().unwrap_or_else(PoisonError::into_inner).clear();
    }
}

impl Upstream {
    pub(super) fn new(spec: Spec) -> Self {
        let prefix = prefix(&spec.name);
        let listings = super::upstream_listing::default_dir();
        Self { spec, prefix, conn: None, tools: None, instructions: None, failed: None, listings }
    }

    /// The same server with its stored lists kept in `dir` (none: never stored).
    #[cfg(test)]
    pub(super) fn with_listings(mut self, dir: Option<PathBuf>) -> Self {
        self.listings = dir;
        self
    }

    /// Whether the server's process runs.
    #[cfg(test)]
    pub(super) fn started(&self) -> bool {
        self.conn.is_some()
    }

    pub(super) fn name(&self) -> &str {
        &self.spec.name
    }

    /// The tools under their cmux names: the stored list from an earlier
    /// start, else the server's own, starting it. `taken` holds names already
    /// in use; a clash is left out.
    pub(super) fn descriptors(&mut self, taken: &BTreeSet<String>) -> Vec<Value> {
        if self.tools.is_none()
            && let Some(stored) = self
                .listings
                .as_deref()
                .and_then(|dir| super::upstream_listing::load(dir, &self.spec))
        {
            self.instructions = rules(&self.spec, stored.instructions.as_deref());
            self.tools = Some(stored.tools);
        }
        if self.tools.is_none() {
            if self.failed.as_ref().is_some_and(|(_, at)| at.elapsed() < START_BACKOFF) {
                return Vec::new();
            }
            if let Err(error) = self.start() {
                if self.failed.as_ref().is_none_or(|(said, _)| *said != error) {
                    eprintln!("cmux mcp: the {} server is unavailable: {error}", self.spec.name);
                }
                self.failed = Some((error, Instant::now()));
                return Vec::new();
            }
        }
        let server = self.spec.name.clone();
        self.tools
            .iter()
            .flatten()
            .filter_map(|tool| {
                let name = format!("{}_{}", self.prefix, tool["name"].as_str()?);
                if taken.contains(&name) {
                    return None;
                }
                let mut tool = tool.clone();
                let description = tool["description"].as_str().unwrap_or_default();
                // The server's own instructions (the computer use consent
                // rules) no longer reach the model through its `initialize`:
                // they go with each of its tools, which a harness with tool
                // search loads only when a turn needs them.
                let rules = self
                    .instructions
                    .as_deref()
                    .filter(|r| !r.trim().is_empty())
                    .map(|r| format!("{RULES_BREAK}{server}{RULES_LABEL}{r}"))
                    .unwrap_or_default();
                tool.set("description", json!(format!("[{server}] {description}{rules}")));
                tool.set("name", json!(name));
                Some(tool)
            })
            .collect()
    }

    /// Starts the server when it is not running, so a stored list gives way
    /// to its own before a call is checked against it.
    pub(super) fn connect(&mut self) -> Result<(), String> {
        if self.conn.as_ref().is_some_and(|conn| conn.alive()) { Ok(()) } else { self.start() }
    }

    /// The server's own name of cmux tool `name`, when it is one of its.
    pub(super) fn owns(&self, name: &str) -> Option<String> {
        let tool = name.strip_prefix(&self.prefix)?.strip_prefix('_')?;
        self.tools.iter().flatten().any(|known| known["name"] == tool).then(|| tool.to_owned())
    }

    /// `tools/call` of `tool`: the server's result unchanged, or why there
    /// is none (`in_progress` when it may have run).
    /// `meta` is the `_meta` it passes on ([`passed_meta`]).
    /// `cap` shortens the call's timeout (a `cmux_exec` script's own limit).
    pub(super) fn call(
        &mut self,
        tool: &str,
        arguments: Value,
        meta: Option<&Value>,
        cap: Option<Duration>,
    ) -> Result<Value, (String, &'static str)> {
        if !self.conn.as_ref().is_some_and(|conn| conn.alive()) {
            self.start().map_err(|error| (error, "not_run"))?;
        }
        let mut params = json!({"name": tool, "arguments": arguments});
        if let (Some(meta), Some(fields)) = (meta, params.as_object_mut()) {
            fields.insert("_meta".to_owned(), meta.clone());
        }
        let timeout = cap.map_or(self.spec.call_timeout, |cap| cap.min(self.spec.call_timeout));
        match self.request("tools/call", params, timeout) {
            Ok(result) => Ok(result),
            Err(Failure::Refused(error)) => Err((error, "not_run")),
            Err(Failure::Lost(error)) => {
                // A dead or late server starts again on the next call (a shared one once no
                // other server holds it); the call itself may have run.
                self.conn = None;
                Err((error, "in_progress"))
            }
        }
    }

    /// Starts the server: a connection only when it initialized and listed.
    fn start(&mut self) -> Result<(), String> {
        let started = self.try_start();
        if started.is_err() {
            self.conn = None;
        }
        started
    }

    fn try_start(&mut self) -> Result<(), String> {
        self.conn = None;
        // The key before the start: a list is stored only for the command it came from.
        let key = self.listings.as_ref().and_then(|_| super::upstream_listing::key(&self.spec));
        self.conn = Some(match &self.spec.shared {
            Some(launch) => Conn::shared(launch, &self.prefix)?,
            None => {
                let spec = &self.spec;
                let own = Launch {
                    command: spec.command.clone(),
                    args: spec.args.clone(),
                    env: spec.env.clone(),
                };
                Arc::new(Conn::start(&own, &self.prefix)?)
            }
        });
        let init = self
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "cmux", "version": env!("CARGO_PKG_VERSION")},
                }),
                START_TIMEOUT,
            )
            .map_err(Failure::message)?;
        let given = init.get("instructions").and_then(Value::as_str).map(str::to_owned);
        self.instructions = rules(&self.spec, given.as_deref());
        self.notify("notifications/initialized")?;
        let mut tools = Vec::new();
        let mut cursor = None::<String>;
        loop {
            let params = cursor.as_ref().map_or_else(|| json!({}), |c| json!({"cursor": c}));
            let page =
                self.request("tools/list", params, START_TIMEOUT).map_err(Failure::message)?;
            tools.extend(page["tools"].as_array().cloned().unwrap_or_default());
            match page["nextCursor"].as_str() {
                Some(next) if !next.is_empty() && tools.len() < 1000 => cursor = Some(next.into()),
                _ => break,
            }
        }
        if let (Some(dir), Some(key)) = (&self.listings, &key) {
            let listing =
                super::upstream_listing::Listing { tools: tools.clone(), instructions: given };
            super::upstream_listing::store(dir, &self.spec, key, &listing);
        }
        self.tools = Some(tools);
        self.failed = None;
        Ok(())
    }

    fn notify(&mut self, method: &str) -> Result<(), String> {
        self.conn.as_ref().ok_or("not started")?.notify(method)
    }

    /// One request, for this server: in a shared process its name goes in `_meta`.
    fn request(
        &mut self,
        method: &str,
        mut params: Value,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        let conn = self.conn.clone().ok_or_else(|| Failure::Lost("not started".into()))?;
        if self.spec.shared.is_some()
            && let Some(fields) = params.as_object_mut()
            && let Some(meta) = fields.entry("_meta").or_insert_with(|| json!({})).as_object_mut()
        {
            meta.insert(acpmux::tools_mcp::SERVER_META.to_owned(), json!(self.spec.name));
        }
        conn.request(method, params, timeout)
    }
}

/// One proxied server (`upstream`): its client behind a lock, so a call
/// that waits holds only this server, and its tools as last listed.
pub(super) struct Proxied {
    pub prefix: String,
    pub name: String,
    pub inner: Arc<Mutex<Upstream>>,
    pub listed: Vec<Value>,
    pub instructions: Option<String>,
}

impl Proxied {
    pub(super) fn new(upstream: Upstream) -> Self {
        Self {
            prefix: upstream.prefix.clone(),
            name: upstream.name().to_owned(),
            inner: Arc::new(Mutex::new(upstream)),
            listed: Vec::new(),
            instructions: None,
        }
    }

    /// Lists its tools again, unless a call holds it: then the last list.
    pub(super) fn refresh(&mut self) {
        if let Ok(mut upstream) = self.inner.try_lock() {
            self.listed = upstream.descriptors(&BTreeSet::new());
            self.instructions = upstream.instructions.clone();
        }
    }

    pub(super) fn lists(&self, name: &str) -> bool {
        self.listed.iter().any(|tool| tool["name"] == name)
    }
}

/// Claude Code's name of the tool call a `tools/call` runs for (`_meta`), which its PreToolUse
/// hook got too, with the subagent that made the call (acpmux's `bg_hook.rs` records it there).
pub(super) const TOOL_USE_ID: &str = "claudecode/toolUseId";

/// The `_meta` a call to cmux passes on to a proxied server's call it makes, its own or a
/// `cmux_exec` script's: Claude Code's tool use id ([`TOOL_USE_ID`]), so acpmux's server knows
/// which subagent called (W5-M, 2026-11-08). Nothing else: a progress token names this call.
pub(super) fn passed_meta(params: &Value) -> Option<Value> {
    let id = params.pointer("/_meta")?.get(TOOL_USE_ID)?.as_str()?;
    Some(json!({ TOOL_USE_ID: id }))
}

/// A proxied tool call, runnable on any thread.
pub(super) struct ProxiedCall {
    pub inner: Arc<Mutex<Upstream>>,
    pub name: String,
    pub arguments: Value,
    /// What it passes on of its caller's `_meta` ([`passed_meta`]).
    pub meta: Option<Value>,
    /// A computer use call's setup check (`computer_use_gate`).
    pub gate: Gate,
}

impl ProxiedCall {
    /// The server's result, or a tool error with the call's state. A
    /// computer use call first waits for setup when it is not done.
    pub(super) fn run(self, cap: Option<Duration>) -> Value {
        if let Gate::Check(check) = self.gate
            && let Some(result) = check.run()
        {
            return result;
        }
        let mut upstream = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Err(message) = upstream.connect() {
            let error = json!({"code": "upstream.failed",
                "message": format!("{}: {message}", upstream.name()),
                "details": {}, "retryable": true});
            return super::tool_error(super::envelope(error, "not_run", None));
        }
        let Some(tool) = upstream.owns(&self.name) else {
            let error = json!({"code": "upstream.failed", "message": format!(
                "{}: the server no longer lists {}", upstream.name(), self.name),
                "details": {}, "retryable": true});
            return super::tool_error(super::envelope(error, "not_run", None));
        };
        match upstream.call(&tool, self.arguments, self.meta.as_ref(), cap) {
            Ok(result) => result,
            Err((message, state)) => {
                let error = json!({
                    "code": "upstream.failed",
                    "message": format!("{}: {message}", upstream.name()),
                    "details": {},
                    "retryable": state == "not_run",
                });
                super::tool_error(super::envelope(error, state, None))
            }
        }
    }
}

impl<B: super::Backend> super::Server<B> {
    /// A docs answer that shows another server's tools carries that
    /// server's own instructions as `servers.<name>` (the computer use
    /// consent rules among them), since its `initialize` no longer reaches
    /// the model.
    pub(super) fn add_server_rules(&self, value: &mut Value) {
        let mut names = Vec::new();
        for tool in value["tools"].as_array().into_iter().flatten() {
            names.extend(tool["name"].as_str().map(str::to_owned));
        }
        for name in value["more"].as_array().into_iter().flatten() {
            names.extend(name.as_str().map(str::to_owned));
        }
        for family in value["families"].as_object().into_iter().flat_map(|f| f.keys()) {
            names.push(format!("{family}_"));
        }
        let servers = self
            .upstreams
            .iter()
            .filter(|u| {
                let prefix = format!("{}_", u.prefix);
                names.iter().any(|name| name.starts_with(&prefix))
            })
            .filter_map(|u| Some((u.name.clone(), json!(u.instructions.clone()?))))
            .collect::<Map<_, _>>();
        if !servers.is_empty() {
            value["servers"] = Value::Object(servers);
        }
    }

    /// A `tools/call` of a proxied server's tool that this server may run
    /// (the same refusal and allowlist checks as `call`), or `None`.
    pub(super) fn proxied_job(&mut self, params: &Value) -> Option<ProxiedCall> {
        let name = params["name"].as_str()?;
        if self.config.as_ref().is_some_and(|path| super::refusal(path).is_some())
            || self.allowed.as_ref().is_some_and(|allowed| !allowed.contains(name))
        {
            return None;
        }
        let arguments = match params.get("arguments") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(arguments)) => arguments.clone(),
            Some(_) => return None,
        };
        let mut job = self.proxied_tool(name, &arguments)?;
        job.meta = passed_meta(params);
        Some(job)
    }

    /// The call of `name` when it is a proxied server's tool.
    pub(super) fn proxied_tool(
        &mut self,
        name: &str,
        arguments: &Map<String, Value>,
    ) -> Option<ProxiedCall> {
        let proxied = self.upstreams.iter_mut().find(|p| {
            name.strip_prefix(p.prefix.as_str()).is_some_and(|rest| rest.starts_with('_'))
        })?;
        if !proxied.lists(name) {
            // Not started yet (no list so far), or gone: list it now.
            proxied.refresh();
        }
        if !proxied.lists(name) {
            return None;
        }
        let inner = proxied.inner.clone();
        let computer_use = if proxied.name == computer_use_gate::SERVER {
            name.strip_prefix(proxied.prefix.as_str())
                .and_then(|rest| rest.strip_prefix('_'))
                .map(str::to_owned)
        } else {
            None
        };
        let arguments = Value::Object(arguments.clone());
        let gate = match computer_use {
            Some(tool) => computer_use_gate::gate(
                &tool,
                &arguments,
                self.backend.app_caller(),
                super::super::app::caller_from(|key| std::env::var(key).ok()),
                // The time the script has left, not its whole limit.
                self.call_deadline.map(|end| end.saturating_duration_since(Instant::now())),
            ),
            None => Gate::Run,
        };
        let meta = self.call_meta.clone();
        Some(ProxiedCall { inner, name: name.to_owned(), arguments, meta, gate })
    }
}
