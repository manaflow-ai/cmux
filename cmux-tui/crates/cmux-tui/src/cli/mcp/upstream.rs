//! The other MCP servers of an agent chat, behind `cmux mcp serve` (code
//! mode for everything cmux gives an agent). acpmux folds its computer use,
//! secret and session offer servers into the `cmux` server's env as
//! [`ENV`] (acpmux `agent_tools::UPSTREAMS_ENV`): their exact command, args
//! and env, already scoped to the session. This server starts each one as a
//! stdio MCP client on first use and lists its tools as
//! `<prefix>_<tool>` (`cmux-cua` is `cua`), so `cmux_docs` finds them and a
//! `cmux_exec` script calls them through `Server::call`, under the same
//! allowlist as every other tool.

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

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
            Some(Spec { name, command, args, env, call_timeout })
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
    child: Child,
    stdin: ChildStdin,
    lines: mpsc::Receiver<String>,
    next_id: u64,
}

impl Drop for Conn {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
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
                tool["description"] = json!(format!("[{server}] {description}"));
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
    pub(super) fn call(
        &mut self,
        tool: &str,
        arguments: Value,
    ) -> Result<Value, (String, &'static str)> {
        if self.conn.is_none() {
            self.start().map_err(|error| (error, "not_run"))?;
        }
        let params = json!({"name": tool, "arguments": arguments});
        match self.request("tools/call", params, self.spec.call_timeout) {
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
        let mut child = Command::new(&self.spec.command)
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
        let (tx, lines) = mpsc::channel();
        std::thread::Builder::new()
            .name(format!("cmux-mcp-upstream-{}", self.prefix))
            .spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if tx.send(line).is_err() {
                        break;
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        self.conn = Some(Conn { child, stdin, lines, next_id: 1 });
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
            let line = match conn.lines.recv_timeout(left) {
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
