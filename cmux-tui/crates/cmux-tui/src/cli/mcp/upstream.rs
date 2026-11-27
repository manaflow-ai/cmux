//! The other MCP servers of an agent chat, behind `cmux mcp serve` (code
//! mode for everything cmux gives an agent). acpmux folds its computer use,
//! secret and session offer servers into the `cmux` server's env as
//! [`ENV`] (acpmux `agent_tools::UPSTREAMS_ENV`): their exact command, args
//! and env, already scoped to the session. This server starts each one as a
//! stdio MCP client on first use and lists its tools as
//! `<prefix>_<tool>` (`cmux-computer-use` is `cu`), so `cmux_docs` finds them and a
//! `cmux_exec` script calls them through `Server::call`, under the same
//! allowlist as every other tool. A list from an earlier start
//! (`upstream_listing.rs`) answers `tools/list` without starting the server,
//! so a chat that never calls one of its tools never starts it. The Computer
//! Use server's list is the catalog compiled into this binary
//! (`cmux_computer_use::tools`, through acpmux), the same one its bridge
//! serves, so it never needs a start to be listed.
//!
//! Servers whose specs name the same `shared` launch (acpmux's own five, `acpmux tools-mcp`,
//! `tools_mcp.rs`) run in one process: each sends its requests with its name in `_meta`
//! ([`acpmux::tools_mcp::SERVER_META`]), and each answer goes back to the request that waits
//! for it, so a call that waits (a secret card) holds no other server's call.
//!
//! A spec with `http` names a loopback streamable HTTP endpoint instead (acpmux's daemon serving
//! those servers, `upstream_http.rs`): no process, the same `_meta` routing.

use std::collections::{BTreeSet, HashMap};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

#[path = "upstream_http.rs"]
pub(super) mod upstream_http;
use cmux_json::JsonSet as _;
use upstream_http::Http;

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
/// A server's process ends after this long with no call; its tools stay listed and the next
/// call starts it again. A harness keeps an idle chat's `cmux mcp serve` running for days (one
/// Codex app-server held 15 on Leo's Mac, 2026-11-14), and each kept its computer use proxy and
/// acpmux's servers running under it: 90 processes, about 300 MB, for chats no one used.
pub(super) const IDLE_STOP: Duration = Duration::from_secs(10 * 60);
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
    /// The loopback HTTP endpoint it is served at (acpmux's daemon), instead of a process.
    pub http: Option<Http>,
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
            let http = item.get("http").and_then(Http::from_json);
            Some(Spec { name, command, args, env, call_timeout, shared, http })
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

/// The tool name prefix of server `name`: `cmux-secrets` is `secrets`,
/// `cmux-computer-use` is `cu` (`cu_screenshot`).
fn prefix(name: &str) -> String {
    if name == acpmux::computer_use::tools::SERVER_NAME {
        return acpmux::computer_use::tools::TOOL_PREFIX.to_owned();
    }
    let name = name.strip_prefix("cmux-").unwrap_or(name);
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
        .collect()
}

/// The rules the model gets for server `spec`: its own `initialize`
/// instructions (the Computer Use server's are `tools::INSTRUCTIONS`).
pub(super) fn rules(_spec: &Spec, own: Option<&str>) -> Option<String> {
    own.filter(|text| !text.trim().is_empty()).map(str::to_owned)
}

/// One server: started on first use, again after it dies or times out.
pub(super) struct Upstream {
    spec: Spec,
    pub prefix: String,
    conn: Option<Link>,
    /// Its tools as the server lists them (original names).
    tools: Option<Vec<Value>>,
    pub instructions: Option<String>,
    /// Why and when the last start failed: said once, retried after
    /// `START_BACKOFF`.
    failed: Option<(String, Instant)>,
    /// Where lists from earlier starts are kept (`upstream_listing.rs`).
    listings: Option<PathBuf>,
    /// The Computer Use server only: this server's client has its own
    /// Computer Use (Codex), so the `cu_*` tools are its second choice
    /// (acpmux `computer_use::mcp::defers_to_own_computer_use`). The bridge
    /// cannot tell by itself: its client is this server, named `cmux`.
    defer: bool,
    /// When it last started or answered a call: its process ends [`IDLE_STOP`] after
    /// ([`stop_idle`]).
    used: Instant,
}

/// Why a request has no result.
pub(super) enum Failure {
    /// The server answered with a JSON-RPC error: the call did not run and
    /// the connection is fine.
    Refused(String),
    /// No answer (timeout, exit, closed pipe): the call may have run.
    Lost(String),
    /// Never reached (an HTTP server that is down, or ended the session): the call did not run,
    /// and the next one starts again.
    Unsent(String),
}

impl Failure {
    pub(super) fn message(self) -> String {
        match self {
            Failure::Refused(message) | Failure::Lost(message) | Failure::Unsent(message) => {
                message
            }
        }
    }
}

/// How an upstream is reached: its process (its own or a shared one), or its HTTP endpoint.
#[derive(Clone)]
enum Link {
    Process(Arc<Conn>),
    Http(Arc<upstream_http::Client>),
}

impl Link {
    fn alive(&self) -> bool {
        match self {
            Link::Process(conn) => conn.alive(),
            // Each request connects again: a server that went down is a failed request.
            Link::Http(_) => true,
        }
    }

    fn notify(&self, method: &str) -> Result<(), String> {
        match self {
            Link::Process(conn) => conn.notify(method),
            Link::Http(client) => client.notify(method, START_TIMEOUT),
        }
    }

    fn request(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, Failure> {
        match self {
            Link::Process(conn) => conn.request(method, params, timeout),
            Link::Http(client) => client.request(method, params, timeout),
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
            .env_remove(super::TERMINAL_AGENT_ENV)
            // A guest mode this server inherited (a person's own `cmux` entry that `cmux acp
            // desktop link` wrote, merged by Codex into this server) never reaches a folded
            // server: the acpmux server would list no tools inside a chat.
            .env_remove(acpmux::desktop_link::GUEST_ENV)
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
        Self {
            spec,
            prefix,
            conn: None,
            tools: None,
            instructions: None,
            failed: None,
            listings,
            defer: false,
            used: Instant::now(),
        }
    }

    /// Whether this is the Computer Use server (`cu_*`).
    pub(super) fn is_computer_use(&self) -> bool {
        self.spec.name == acpmux::computer_use::tools::SERVER_NAME
    }

    /// Marks the `cu_*` tools second choice for a client with its own
    /// Computer Use (only the Computer Use server takes it).
    pub(super) fn set_defer(&mut self, defer: bool) {
        self.defer = defer && self.is_computer_use();
    }

    /// Ends its process when it has had no call for `idle`, keeping its tools listed (the next
    /// call starts it again). While a process runs, how long until it would be idle; `None`
    /// when none runs.
    pub(super) fn stop_if_idle(&mut self, idle: Duration) -> Option<Duration> {
        // An HTTP upstream has no process to end.
        if !matches!(self.conn, Some(Link::Process(_))) {
            return None;
        }
        let left = idle.saturating_sub(self.used.elapsed());
        if left.is_zero() {
            // The child ends with its connection (`Conn::drop`); a shared one once no other
            // server holds it.
            self.conn = None;
            return None;
        }
        Some(left)
    }

    /// The same server with its stored lists kept in `dir` (none: never stored).
    #[cfg(test)]
    pub(super) fn with_listings(mut self, dir: Option<PathBuf>) -> Self {
        self.listings = dir;
        self
    }

    /// The pid of its running process (tests kill it).
    #[cfg(test)]
    pub(super) fn pid(&self) -> Option<u32> {
        let Some(Link::Process(conn)) = self.conn.as_ref() else { return None };
        Some(conn.child.lock().unwrap_or_else(PoisonError::into_inner).id())
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
        if self.tools.is_none() && self.spec.name == acpmux::computer_use::tools::SERVER_NAME {
            let catalog = acpmux::computer_use::tools::mcp_list();
            self.tools = catalog.get("tools").and_then(Value::as_array).cloned();
            self.instructions = rules(&self.spec, Some(acpmux::computer_use::tools::INSTRUCTIONS));
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
        if self.is_computer_use() {
            // The rules the person's agent gets: Codex keeps its own Computer
            // Use first (acpmux `computer_use/mcp.rs`), whatever the bridge
            // told this server, whose client name is `cmux`.
            self.instructions = Some(if self.defer {
                acpmux::computer_use::mcp::DEFER_INSTRUCTIONS.to_owned()
            } else {
                acpmux::computer_use::tools::INSTRUCTIONS.to_owned()
            });
        }
        let server = self.spec.name.clone();
        let defer_prefix = if self.defer { acpmux::computer_use::mcp::DEFER_PREFIX } else { "" };
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
                tool.set(
                    "description",
                    json!(format!("[{server}] {defer_prefix}{description}{rules}")),
                );
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
        self.used = Instant::now();
        let mut params = json!({"name": tool, "arguments": arguments});
        if let (Some(meta), Some(fields)) = (meta, params.as_object_mut()) {
            fields.insert("_meta".to_owned(), meta.clone());
        }
        let timeout = cap.map_or(self.spec.call_timeout, |cap| cap.min(self.spec.call_timeout));
        let answered = self.request("tools/call", params, timeout);
        self.used = Instant::now();
        match answered {
            Ok(result) => Ok(result),
            Err(Failure::Refused(error)) => Err((error, "not_run")),
            Err(Failure::Unsent(error)) => {
                self.conn = None;
                Err((error, "not_run"))
            }
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
        self.conn = Some(match (&self.spec.http, &self.spec.shared) {
            (Some(http), _) => Link::Http(Arc::new(upstream_http::Client::new(http)?)),
            (None, Some(launch)) => Link::Process(Conn::shared(launch, &self.prefix)?),
            (None, None) => {
                let spec = &self.spec;
                let mut own = Launch {
                    command: spec.command.clone(),
                    args: spec.args.clone(),
                    env: spec.env.clone(),
                };
                // The Computer Use bridge names its caller on the person's approval
                // cards by its MCP client, which is this server ("cmux"): the agent's
                // own name goes in its env instead, unless the spec names one.
                let label = acpmux::computer_use::mcp::LABEL_ENV;
                if self.is_computer_use()
                    && !own.env.iter().any(|(k, _)| k == label)
                    && let Some(client) = super::chat_tools::client_name()
                {
                    own.env.push((label.to_owned(), client.to_owned()));
                }
                Link::Process(Arc::new(Conn::start(&own, &self.prefix)?))
            }
        });
        // Its own client's name as `title`: a Computer Use server cmux does not start itself (the
        // acpmux gateway's or a shared helper's) labels the person's approval cards with it, the
        // name the bridge's own env carries when cmux starts it (`LABEL_ENV` above).
        let mut client_info = json!({"name": "cmux", "version": env!("CARGO_PKG_VERSION")});
        if self.is_computer_use()
            && let Some(client) = super::chat_tools::client_name()
        {
            client_info["title"] = json!(client);
        }
        let init = self
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": client_info,
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
        self.used = Instant::now();
        Ok(())
    }

    fn notify(&mut self, method: &str) -> Result<(), String> {
        self.conn.as_ref().ok_or("not started")?.notify(method)
    }

    /// One request, for this server: in a shared process or at an HTTP endpoint (both route by
    /// it) its name goes in `_meta`.
    fn request(
        &mut self,
        method: &str,
        mut params: Value,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        let conn = self.conn.clone().ok_or_else(|| Failure::Lost("not started".into()))?;
        if (self.spec.shared.is_some() || self.spec.http.is_some())
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

    /// Marks its `cu_*` tools second choice (see [`Upstream::set_defer`]) and
    /// lists them again.
    pub(super) fn set_defer(&mut self, defer: bool) {
        if let Ok(mut upstream) = self.inner.lock() {
            upstream.set_defer(defer);
        }
        self.listed.clear();
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

/// Ends each server's process once it has had no call for `idle` ([`IDLE_STOP`]), on a thread
/// that sleeps until the next one could be idle and ends once every server is dropped. A server
/// a call holds is skipped: the call marks it used when it ends.
pub(super) fn stop_idle(
    servers: Vec<Weak<Mutex<Upstream>>>,
    idle: Duration,
) -> std::io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new().name("cmux-mcp-upstream-idle".into()).spawn(move || {
        loop {
            let mut next = idle;
            let mut any = false;
            for server in &servers {
                let Some(server) = server.upgrade() else { continue };
                any = true;
                if let Ok(mut upstream) = server.try_lock() {
                    next = next.min(upstream.stop_if_idle(idle).unwrap_or(idle));
                }
            }
            if !any {
                return;
            }
            std::thread::sleep(next.max(Duration::from_millis(10)));
        }
    })
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
}

impl ProxiedCall {
    /// The server's result, or a tool error with the call's state.
    pub(super) fn run(self, cap: Option<Duration>) -> Value {
        let mut upstream = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let server = upstream.name().to_owned();
        let failed = |message: String, state: &'static str| {
            let error = json!({"code": "upstream.failed",
                "message": format!("{server}: {message}"),
                "details": {}, "retryable": state == "not_run"});
            super::tool_error(super::envelope(error, state, None))
        };
        if let Err(message) = upstream.connect() {
            return failed(message, "not_run");
        }
        let Some(tool) = upstream.owns(&self.name) else {
            return failed(format!("the server no longer lists {}", self.name), "not_run");
        };
        match upstream.call(&tool, self.arguments, self.meta.as_ref(), cap) {
            Ok(result) => result,
            Err((message, state)) => failed(message, state),
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
            || (self.computer_use_only && !super::code_mode::computer_use::is_tool(name))
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
        let arguments = Value::Object(arguments.clone());
        let meta = self.call_meta.clone();
        Some(ProxiedCall { inner, name: name.to_owned(), arguments, meta })
    }
}
