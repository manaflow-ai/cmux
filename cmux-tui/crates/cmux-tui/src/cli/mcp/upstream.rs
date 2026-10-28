//! The other MCP servers of an agent chat, behind `cmux mcp serve` (code
//! mode for everything cmux gives an agent). acpmux folds its computer use,
//! secret and session offer servers into the `cmux` server's env as
//! [`ENV`] (acpmux `agent_tools::UPSTREAMS_ENV`): their exact command, args
//! and env, already scoped to the session. This server starts each one as a
//! stdio MCP client on first use and lists its tools as
//! `<prefix>_<tool>` (`cmux-cua` is `cua`), so `cmux_docs` finds them and a
//! `cmux_exec` script calls them through `Server::call`, under the same
//! allowlist as every other tool.
//!
//! An entry with a `socket` is a tool set the acpmux daemon serves itself
//! (acpmux `subsession_mcp::DaemonTools`, p07-memory-092): this server dials
//! that socket and sends the entry's `initializeMeta` with its `initialize`,
//! which proves the session, so the tools run with no process of their own.
//! Its command (the acpmux relay) is for a `cmux mcp serve` that reads no
//! `socket`, and for Windows.

use cmux_process::{Child, Command, Stdio};
use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

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
    /// The acpmux daemon socket to dial instead of starting `command` (module docs).
    pub socket: Option<PathBuf>,
    /// The `_meta` of its first `initialize`.
    pub initialize_meta: Option<Value>,
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
            let call_timeout = item["callTimeoutSecs"]
                .as_u64()
                .map_or(CALL_TIMEOUT, |secs| Duration::from_secs(secs.clamp(1, 24 * 3600)));
            let socket = item["socket"].as_str().map(PathBuf::from);
            let initialize_meta = item.get("initializeMeta").filter(|m| m.is_object()).cloned();
            Some(Spec { name, command, args, env, call_timeout, socket, initialize_meta })
        })
        .collect()
}

/// The tool name prefix of server `name`: `cmux-cua` is `cua`.
fn prefix(name: &str) -> String {
    let name = name.strip_prefix("cmux-").unwrap_or(name);
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
        .collect()
}

/// One server: started on first use, again after it dies or times out.
pub(super) struct Upstream {
    spec: Spec,
    pub prefix: String,
    conn: Option<Conn>,
    /// Its tools as the server lists them (original names).
    tools: Option<Vec<Value>>,
    pub instructions: Option<String>,
    /// Why and when the last start failed: said once, retried after
    /// `START_BACKOFF`.
    failed: Option<(String, Instant)>,
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

struct Conn {
    peer: Peer,
    stdin: Box<dyn Write + Send>,
    lines: mpsc::Receiver<String>,
    next_id: u64,
}

/// What a connection talks to: a server process, or the acpmux daemon.
enum Peer {
    Process(Child),
    #[cfg(unix)]
    Daemon(std::os::unix::net::UnixStream),
}

impl Drop for Conn {
    fn drop(&mut self) {
        match &mut self.peer {
            Peer::Process(child) => {
                let _ = child.kill();
                let _ = child.wait();
            }
            // Ends the reader thread's read too.
            #[cfg(unix)]
            Peer::Daemon(stream) => {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        }
    }
}

impl Upstream {
    pub(super) fn new(spec: Spec) -> Self {
        let prefix = prefix(&spec.name);
        Self { spec, prefix, conn: None, tools: None, instructions: None, failed: None }
    }

    pub(super) fn name(&self) -> &str {
        &self.spec.name
    }

    /// The tools under their cmux names, starting the server if needed.
    /// `taken` holds names already in use; a clash is left out.
    pub(super) fn descriptors(&mut self, taken: &BTreeSet<String>) -> Vec<Value> {
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
                    .map(|r| format!("\n\n{server} rules: {r}"))
                    .unwrap_or_default();
                tool["description"] = json!(format!("[{server}] {description}{rules}"));
                tool["name"] = json!(name);
                Some(tool)
            })
            .collect()
    }

    /// The server's own name of cmux tool `name`, when it is one of its.
    pub(super) fn owns(&self, name: &str) -> Option<String> {
        let tool = name.strip_prefix(&self.prefix)?.strip_prefix('_')?;
        self.tools.iter().flatten().any(|known| known["name"] == tool).then(|| tool.to_owned())
    }

    /// `tools/call` of `tool`: the server's result unchanged, or why there
    /// is none (`in_progress` when it may have run).
    /// `cap` shortens the call's timeout (a `cmux_exec` script's own limit).
    pub(super) fn call(
        &mut self,
        tool: &str,
        arguments: Value,
        cap: Option<Duration>,
    ) -> Result<Value, (String, &'static str)> {
        if self.conn.is_none() {
            self.start().map_err(|error| (error, "not_run"))?;
        }
        let params = json!({"name": tool, "arguments": arguments});
        let timeout = cap.map_or(self.spec.call_timeout, |cap| cap.min(self.spec.call_timeout));
        match self.request("tools/call", params, timeout) {
            Ok(result) => Ok(result),
            Err(Failure::Refused(error)) => Err((error, "not_run")),
            Err(Failure::Lost(error)) => {
                // A dead or late server starts again on the next call; the
                // call itself may have run.
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
        self.conn = Some(self.connect()?);
        let mut init = json!({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "cmux", "version": env!("CARGO_PKG_VERSION")},
        });
        // The daemon's tool sets: the caller that proves the session, and the server (module docs).
        if let Some(meta) = &self.spec.initialize_meta {
            init["_meta"] = meta.clone();
        }
        let init = self.request("initialize", init, START_TIMEOUT).map_err(Failure::message)?;
        self.instructions = init["instructions"].as_str().map(str::to_owned);
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
        self.tools = Some(tools);
        self.failed = None;
        Ok(())
    }

    /// A new connection: the daemon's own when the spec names its socket
    /// (unix), else the server process.
    fn connect(&self) -> Result<Conn, String> {
        #[cfg(unix)]
        if let Some(socket) = &self.spec.socket {
            let stream = std::os::unix::net::UnixStream::connect(socket).map_err(|error| {
                format!("cannot reach the daemon at {}: {error}", socket.display())
            })?;
            let clone = || stream.try_clone().map_err(|error| error.to_string());
            let lines = self.read_lines(clone()?)?;
            let stdin = Box::new(clone()?);
            return Ok(Conn { peer: Peer::Daemon(stream), stdin, lines, next_id: 1 });
        }
        let mut command = Command::new(&self.spec.command);
        // In the shared host the server is the client's: its environment and
        // folder, not the host's.
        if let Some(caller) = super::super::caller_env::current() {
            command.env_clear().envs(caller.vars());
            if let Some(cwd) = caller.cwd() {
                command.current_dir(cwd);
            }
        }
        let mut child = command
            .args(&self.spec.args)
            // This server's own folding and allowlist stay with it.
            .env_remove(ENV)
            .envs(self.spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|error| format!("cannot start {}: {error}", self.spec.command.display()))?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let lines = self.read_lines(stdout)?;
        Ok(Conn { peer: Peer::Process(child), stdin: Box::new(stdin), lines, next_id: 1 })
    }

    /// The lines of `output`, read on a thread of their own.
    fn read_lines(
        &self,
        output: impl std::io::Read + Send + 'static,
    ) -> Result<mpsc::Receiver<String>, String> {
        let (tx, lines) = mpsc::channel();
        std::thread::Builder::new()
            .name(format!("cmux-mcp-upstream-{}", self.prefix))
            .spawn(move || {
                for line in BufReader::new(output).lines() {
                    let Ok(line) = line else { break };
                    if tx.send(line).is_err() {
                        break;
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        Ok(lines)
    }

    fn notify(&mut self, method: &str) -> Result<(), String> {
        let conn = self.conn.as_mut().ok_or("not started")?;
        writeln!(conn.stdin, "{}", json!({"jsonrpc": "2.0", "method": method}))
            .and_then(|()| conn.stdin.flush())
            .map_err(|error| format!("write: {error}"))
    }

    /// One request; answers the server's own requests with method not found
    /// and skips its notifications.
    fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        let conn = self.conn.as_mut().ok_or_else(|| Failure::Lost("not started".into()))?;
        let id = conn.next_id;
        conn.next_id += 1;
        let message = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(conn.stdin, "{message}")
            .and_then(|()| conn.stdin.flush())
            .map_err(|error| Failure::Lost(format!("the server closed its input: {error}")))?;
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let line = match crate::blocking::sync::recv_timeout(&conn.lines, left) {
                Ok(line) => line,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    let secs = timeout.as_secs();
                    return Err(Failure::Lost(format!("no answer to {method} in {secs} s")));
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(Failure::Lost(format!("the server exited during {method}")));
                }
            };
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply.get("method").is_some() {
                if let Some(their_id) = reply.get("id") {
                    let refused = json!({"jsonrpc": "2.0", "id": their_id,
                        "error": {"code": -32601, "message": "not supported by cmux"}});
                    let _ = writeln!(conn.stdin, "{refused}").and_then(|()| conn.stdin.flush());
                }
                continue;
            }
            if reply["id"] != id {
                continue;
            }
            if let Some(error) = reply.get("error") {
                return Err(Failure::Refused(
                    error["message"].as_str().unwrap_or("error").to_owned(),
                ));
            }
            return Ok(reply["result"].clone());
        }
    }
}

/// One proxied server (`upstream`): its client behind a lock, so a call
/// that waits holds only this server, and its tools as last listed.
pub(super) struct Proxied {
    pub prefix: String,
    pub name: String,
    pub inner: std::sync::Arc<std::sync::Mutex<Upstream>>,
    pub listed: Vec<Value>,
    pub instructions: Option<String>,
}

impl Proxied {
    pub(super) fn new(upstream: Upstream) -> Self {
        Self {
            prefix: upstream.prefix.clone(),
            name: upstream.name().to_owned(),
            inner: std::sync::Arc::new(std::sync::Mutex::new(upstream)),
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

/// A proxied tool call, runnable on any thread.
pub(super) struct ProxiedCall {
    pub inner: std::sync::Arc<std::sync::Mutex<Upstream>>,
    pub name: String,
    pub arguments: Value,
}

impl ProxiedCall {
    /// The server's result, or a tool error with the call's state.
    pub(super) fn run(self, cap: Option<Duration>) -> Value {
        let mut upstream = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(tool) = upstream.owns(&self.name) else {
            let error = json!({"code": "upstream.failed", "message": format!(
                "{}: the server no longer lists {}", upstream.name(), self.name),
                "details": {}, "retryable": true});
            return super::tool_error(super::envelope(error, "not_run", None));
        };
        match upstream.call(&tool, self.arguments, cap) {
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
        self.proxied_tool(name, &arguments)
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
        proxied.lists(name).then(|| ProxiedCall {
            inner: proxied.inner.clone(),
            name: name.to_owned(),
            arguments: Value::Object(arguments.clone()),
        })
    }
}
