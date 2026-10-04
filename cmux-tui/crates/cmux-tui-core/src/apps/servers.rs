//! App servers: the top-level manifest `server` that implements an app's
//! catalog ops in its own process (app-platform.md, server kinds).
//!
//! Runs now: first-party `native` servers whose binary ships in the cmux
//! bundle (`binaries`), resolved next to `cmux-app-host`
//! ([`super::host::resolve_server_dir`]). Third-party native servers
//! (`artifacts`), `external` and `js` servers answer
//! `apps.server_unsupported` until artifact verification and credential
//! admission land. A declared binary that is not in the bundle answers
//! `apps.server_missing`; nothing retries it, so there is no crash loop.
//!
//! Lifecycle (`server.lifecycle`): `always` starts the server when the app is
//! installed and enabled (and when the supervisor starts for an app that
//! already is); `onDemand` (the default) starts it on the first `apps-run` of
//! one of its catalog ops. Disable and uninstall stop it. `idleStopSeconds`
//! stops an on-demand server that has no call in flight (absent: the
//! supervisor's idle stop; 0: never). An `always` server that crashes
//! restarts after a backoff, at most [`MAX_CRASHES`] times in a row.
//!
//! Wire: JSON lines on the server's stdin and stdout.
//!
//! - Catalog ops, supervisor -> server: `{"type":"op","id":"s1","op",
//!   "args":{},"origin":"user|cli|mcp|script|remote","idempotency_key"}`;
//!   server -> supervisor `{"type":"result","id":"s1","ok":true,"result":{}}`
//!   or `{"type":"result","id":"s1","ok":false,"error":{"code","message"}}`.
//!   Server events `{"type":"event","event","data"}` are broadcast to apps
//!   clients as `apps-server-event {app, name, data}`.
//! - Host-only ops (one shape for every op the host answers), server ->
//!   supervisor `{"t":"host.request","id":1,"op":"cmux.host.…","params":{}}`;
//!   supervisor -> server `{"t":"host.result","id":1,"value":{}}` or
//!   `{"t":"host.error","id":1,"code","message","retryable"}`. Host events,
//!   supervisor -> server: `{"t":"host.event","op":"cmux.host.…","data":{}}`.
//!   The id is the server's own (any JSON value), echoed back.
//!   - `cmux.host.link.get {}` -> `{binary, hub_socket, state_dir,
//!     socket_dir, device_name}` from the daemon's own values (see
//!     [`Supervisor::host_link`]; `hub_socket` is `null` until the link
//!     lane's registration exists); event `cmux.host.link.changed` with the
//!     same value. Needs server scope `op:cmux.host.link.get` and a
//!     first-party app, else `host.error` `apps.scope_missing`.
//!   - `cmux.credential.relay` answers `host.error` `unavailable` until the
//!     Mac provider side exists (APP-R1): the supervisor will forward the
//!     request params over the provider channel and the Mac app answers
//!     through its host capabilities; no user credential enters the daemon.
//!   - Any other `cmux.host.*` op answers `host.error` `apps.op.unknown`.
//!
//! Open tokens: the op line of a user run (origin user, admitted by the A2
//! gate) carries a top-level `"open_token"`, a fresh 128-bit hex token,
//! single use, bound to {app, op, idempotency_key} and valid for 60 s. No
//! other origin gets one, and a client's `open_token` (top level of the
//! request or of `args`) never reaches the server. The host side of a
//! connect checks a token the server passes on with
//! [`Supervisor::consume_open_token`].
//!
//! Environment: an allowlist only. `CMUX_APP_ID`, `CMUX_APP_DATA_DIR` (the
//! app's data directory; one subdirectory per `server.data` entry, the
//! ephemeral ones emptied at each start; removed at uninstall), `TMPDIR`
//! (a per-app directory emptied at each start) and the daemon's `LANG`.
//! Anything else, link details included, goes over ops. The server's stderr
//! goes to the app's log.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::catalog::Package;
use super::host::Exit;
use super::mirror::{Origin, Tier};
use super::supervisor::{ApiError, Inner, MAX_CRASHES, Out, Responder, Supervisor};
use super::timer::TimerId;
use crate::backoff::Backoff;

/// Longest line a server may write (a 16 MiB file read, base64 encoded).
const MAX_LINE_BYTES: u64 = 32 << 20;
/// Lines queued for one server before it counts as stuck and is killed.
const QUEUE: usize = 4096;
/// How long a stopping server may take to exit after its stdin closed.
const STOP_GRACE: Duration = Duration::from_secs(5);
/// Longest stderr line kept in the app's log.
const LOG_LINE_BYTES: usize = 4096;

/// How to run one app's server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ServerSpec {
    pub binary: PathBuf,
    pub args: Vec<String>,
    /// `lifecycle.start` is `always`.
    pub always: bool,
    /// When an idle on-demand server stops; `None` never.
    pub idle: Option<Duration>,
}

/// This machine's key in `server.binaries`.
fn platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("darwin-arm64"),
        ("macos", "x86_64") => Some("darwin-x64"),
        ("linux", "aarch64") => Some("linux-arm64"),
        ("linux", "x86_64") => Some("linux-x64"),
        _ => None,
    }
}

/// The server `package` declares: `None` without one, `Err` when it cannot
/// run here.
pub(super) fn spec(
    package: &Package,
    dir: Option<&Path>,
    default_idle: Duration,
) -> Option<Result<ServerSpec, ApiError>> {
    let server = package.manifest.get("server")?;
    let id = &package.id;
    let kind = server["kind"].as_str().unwrap_or_default();
    let binaries = server.get("binaries").and_then(Value::as_object);
    let Some(binaries) = binaries.filter(|_| kind == "native" && package.tier == Tier::FirstParty)
    else {
        return Some(Err(ApiError::new(
            "apps.server_unsupported",
            format!("{id} declares a {kind} server; only first-party native servers run for now"),
        )));
    };
    // The schema limits names to [a-z0-9-], so a name never leaves the directory.
    let Some(name) = platform().and_then(|p| binaries.get(p)).and_then(Value::as_str) else {
        return Some(Err(ApiError::new(
            "apps.server_missing",
            format!("{id} ships no server binary for this platform"),
        )));
    };
    let Some(binary) = dir.map(|d| d.join(name)).filter(|p| p.is_file()) else {
        return Some(Err(ApiError::new(
            "apps.server_missing",
            format!("the server binary {name} of {id} is not in the cmux bundle"),
        )));
    };
    let args = server["args"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|a| a.as_str().map(str::to_string))
        .collect();
    let always = server.pointer("/lifecycle/start").and_then(Value::as_str) == Some("always");
    let idle = match server.pointer("/lifecycle/idleStopSeconds").and_then(Value::as_u64) {
        Some(0) => None,
        Some(seconds) => Some(Duration::from_secs(seconds)),
        None => (!always).then_some(default_idle),
    };
    Some(Ok(ServerSpec { binary, args, always, idle }))
}

/// One running server process of an app.
pub(super) struct Server {
    pub generation: u64,
    pub process: Arc<ServerProcess>,
    pub spec: ServerSpec,
    /// Calls by wire id; every one waits for its `result` line.
    pub pending: HashMap<String, Responder>,
    /// Lines for calls that arrived while the process was stopping; they go
    /// to the next process.
    pub queued: Vec<(String, Vec<u8>)>,
    pub next_id: u64,
    pub idle: Option<TimerId>,
    /// Asked to exit (idle, disable, uninstall); the exit is expected.
    pub stopping: bool,
    pub kill: Option<TimerId>,
}

/// How long a stamped open token stays valid.
const OPEN_TOKEN_TTL: Duration = Duration::from_secs(60);
/// Open tokens kept at once; past it the one closest to expiry goes.
const MAX_OPEN_TOKENS: usize = 1024;

/// A minted open token: single use, for one app, op and idempotency key.
pub(super) struct OpenToken {
    app: String,
    op: String,
    idempotency_key: Option<String>,
    expires: Instant,
}

/// What a consumed open token was minted for, so the caller can check the op.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct OpenTokenUse {
    pub op: String,
    pub idempotency_key: Option<String>,
}

/// Mints a fresh 128-bit open token for one user run of `op`.
fn mint_open_token(
    inner: &mut Inner,
    app: &str,
    op: &str,
    idempotency_key: Option<String>,
    now: Instant,
) -> String {
    inner.open_tokens.retain(|_, t| t.expires > now);
    if inner.open_tokens.len() >= MAX_OPEN_TOKENS
        && let Some(oldest) =
            inner.open_tokens.iter().min_by_key(|(_, t)| t.expires).map(|(k, _)| k.clone())
    {
        inner.open_tokens.remove(&oldest);
    }
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("the OS random source");
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    inner.open_tokens.insert(
        token.clone(),
        OpenToken {
            app: app.to_string(),
            op: op.to_string(),
            idempotency_key,
            expires: now + OPEN_TOKEN_TTL,
        },
    );
    token
}

/// Restart spacing of crashed `always` servers, per app.
#[derive(Default)]
pub(super) struct Crashes {
    pub count: u32,
    pub backoff: Option<Backoff>,
    pub restart: Option<TimerId>,
}

enum Outgoing {
    Line(Vec<u8>),
    Close,
}

/// A server process. Sending never blocks: lines go through a bounded queue
/// to a writer thread, so the supervisor lock never waits on the server.
pub(super) struct ServerProcess {
    queue: SyncSender<Outgoing>,
    /// The child's pid until the reader thread reaps it; a kill only signals
    /// a pid that is not reaped yet.
    pid: Arc<Mutex<Option<u32>>>,
}

impl ServerProcess {
    /// Spawns `binary` with only `env` set. `on_line` runs on the
    /// reader thread for each stdout line, `on_log` for each stderr line,
    /// and `on_exit` once after stdout closed and the child was reaped.
    pub fn spawn(
        binary: &Path,
        args: &[String],
        env: &[(String, String)],
        name: &str,
        on_line: impl Fn(Value) + Send + 'static,
        on_log: impl Fn(String) + Send + 'static,
        on_exit: impl FnOnce(Exit) + Send + 'static,
    ) -> std::io::Result<Self> {
        let mut child = Command::new(binary)
            .args(args)
            .env_clear()
            .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let (Some(stdin), Some(stdout), Some(stderr)) =
            (child.stdin.take(), child.stdout.take(), child.stderr.take())
        else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::other("the server has no stdio pipes"));
        };
        let pid = Arc::new(Mutex::new(Some(child.id())));
        let (queue, outgoing) = sync_channel(QUEUE);
        std::thread::Builder::new()
            .name(format!("cmux-app-server-w:{name}"))
            .spawn(move || write_loop(stdin, outgoing))?;
        std::thread::Builder::new().name(format!("cmux-app-server-e:{name}")).spawn(move || {
            for line in BufReader::new(stderr).lines() {
                let Ok(mut line) = line else { break };
                if line.len() > LOG_LINE_BYTES {
                    let mut end = LOG_LINE_BYTES;
                    while !line.is_char_boundary(end) {
                        end -= 1;
                    }
                    line.truncate(end);
                }
                on_log(line);
            }
        })?;
        let reaper = pid.clone();
        std::thread::Builder::new().name(format!("cmux-app-server:{name}")).spawn(move || {
            let mut lines = BufReader::new(stdout);
            let mut line = Vec::new();
            loop {
                line.clear();
                match lines.by_ref().take(MAX_LINE_BYTES + 1).read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => break,
                    // An oversized line ends the server.
                    Ok(_) if line.last() != Some(&b'\n') => break,
                    Ok(_) if line.iter().all(u8::is_ascii_whitespace) => {}
                    Ok(_) => {
                        on_line(serde_json::from_slice(&line).unwrap_or_else(
                            |e| json!({ "type": "invalid", "error": e.to_string() }),
                        ));
                    }
                }
            }
            // Stdout closed (or a bad line): end the process, then reap it.
            if let Some(pid) = reaper.lock().unwrap().take() {
                // SAFETY: signalling our own child by pid; it is not reaped yet.
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            }
            let exit = match child.wait() {
                Ok(status) => {
                    use std::os::unix::process::ExitStatusExt;
                    Exit { code: status.code(), signal: status.signal() }
                }
                Err(_) => Exit { code: None, signal: None },
            };
            on_exit(exit);
        })?;
        Ok(Self { queue, pid })
    }

    /// Queues one line. A server whose queue is full is stuck and is killed.
    pub fn send(&self, line: Vec<u8>) {
        if let Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) =
            self.queue.try_send(Outgoing::Line(line))
        {
            self.kill();
        }
    }

    /// Closes the server's stdin after the queued lines: it reads end of
    /// input and exits.
    pub fn close(&self) {
        if self.queue.try_send(Outgoing::Close).is_err() {
            self.kill();
        }
    }

    pub fn kill(&self) {
        if let Some(pid) = *self.pid.lock().unwrap() {
            // SAFETY: the pid is ours and not reaped (the reader takes it first).
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        }
    }
}

fn write_loop(mut stdin: ChildStdin, outgoing: Receiver<Outgoing>) {
    while let Ok(item) = outgoing.recv() {
        match item {
            Outgoing::Line(line) => {
                if stdin.write_all(&line).and_then(|()| stdin.flush()).is_err() {
                    return;
                }
            }
            Outgoing::Close => return,
        }
    }
}

/// The scope a server op needs, from the fragment family and the op's risk:
/// the derivation `gen-cmux-global` uses for scopes.json (`<family>:read`,
/// `:write` for mutate-own and mutate-shared, `:execute`, `:external`).
/// `None` (destructive) means no app scope covers it: only the user runs it.
pub(super) fn op_scope(family: &str, entry: &Value) -> Option<String> {
    let verb = match entry["risk"].as_str() {
        Some("read") => "read",
        Some("mutate-own" | "mutate-shared") => "write",
        Some("execute") => "execute",
        Some("send-external") => "external",
        Some(_) => return None,
        None => match entry["class"].as_str() {
            Some("read") => "read",
            Some("mutation") => "write",
            _ => return None,
        },
    };
    Some(format!("{family}:{verb}"))
}

fn line(value: &Value) -> Vec<u8> {
    let mut line = serde_json::to_vec(value).unwrap_or_default();
    line.push(b'\n');
    line
}

impl Supervisor {
    fn server_spec_locked(&self, inner: &Inner, app: &str) -> Option<Result<ServerSpec, ApiError>> {
        let package = inner.catalog.packages.get(app)?;
        spec(package, self.config.server_dir.as_deref(), self.config.idle_stop)
    }

    /// The supervisor's own check of a server op, before the server's (a
    /// second layer): a `gesture: required` op needs origin user (admitted
    /// on the wire only from the hosting app connection, A2), and the app
    /// must hold the op's scope. A destructive op has no scope and needs
    /// origin user.
    pub(super) fn admit_server_op(
        inner: &Inner,
        app: &str,
        op: &str,
        origin: Origin,
    ) -> Result<(), ApiError> {
        let Some((family, entry)) = inner.catalog.packages.get(app).and_then(|p| p.catalog_op(op))
        else {
            return Err(ApiError::new("apps.op.unknown", format!("{app} has no op {op}")));
        };
        let user = origin == Origin::User;
        if entry["gesture"] == "required" && !user {
            return Err(ApiError::new(
                "apps.gesture_required",
                format!("{op} runs only from a user action (a tap, palette pick or shortcut)"),
            ));
        }
        let key = super::supervisor::HostKey { app: app.to_string(), preview: false };
        match op_scope(&family, &entry) {
            Some(scope) if !Self::grant_for(inner, &key).scopes.contains(&scope) => {
                Err(ApiError::new("apps.scope_missing", format!("{app} is not granted {scope}")))
            }
            None if !user => {
                Err(ApiError::new("apps.scope_missing", format!("only you can run {op}")))
            }
            _ => Ok(()),
        }
    }

    /// True when `app` declares a server and `op` is one of its catalog ops.
    pub(super) fn server_op_locked(inner: &Inner, app: &str, op: &str) -> bool {
        inner.catalog.packages.get(app).is_some_and(|package| {
            package.manifest.get("server").is_some()
                && package.catalog_ops().iter().any(|(name, _)| name == op)
        })
    }

    /// Sends `op` to the app's server, starting it first when needed. The
    /// caller has checked install, enable and hidden access.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn call_server_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        op: &str,
        mut args: Value,
        origin: Origin,
        idempotency_key: Option<String>,
        respond: Responder,
    ) -> Vec<Out> {
        let outs = match self.start_server_locked(inner, app) {
            Ok(outs) => outs,
            Err(error) => return vec![Out::Respond(respond, Err(error))],
        };
        // Only the supervisor mints open tokens: a client's never reaches the
        // server, and only a user run (origin user, admitted by the A2 gate)
        // gets one.
        if let Some(fields) = args.as_object_mut() {
            fields.remove("open_token");
        }
        let open_token = (origin == Origin::User)
            .then(|| mint_open_token(inner, app, op, idempotency_key.clone(), Instant::now()));
        let server = inner.servers.get_mut(app).expect("started");
        if let Some(timer) = server.idle.take() {
            self.timers.cancel(timer);
        }
        server.next_id += 1;
        let id = format!("s{}", server.next_id);
        let mut message = json!({
            "type": "op", "id": id, "op": op, "args": args, "origin": origin,
            "idempotency_key": idempotency_key,
        });
        if let Some(token) = open_token {
            message["open_token"] = json!(token);
        }
        let message = line(&message);
        server.pending.insert(id.clone(), respond);
        if server.stopping {
            server.queued.push((id, message));
        } else {
            server.process.send(message);
        }
        outs
    }

    /// Starts the app's server unless one runs. A stopping server keeps its
    /// slot: calls queue and the next process starts after its exit, so one
    /// app never has two servers (single writer).
    fn start_server_locked(&self, inner: &mut Inner, app: &str) -> Result<Vec<Out>, ApiError> {
        if inner.servers.contains_key(app) {
            return Ok(vec![]);
        }
        let spec = match self.server_spec_locked(inner, app) {
            Some(Ok(spec)) => spec,
            Some(Err(error)) => return Err(error),
            None => {
                return Err(ApiError::new("apps.server_missing", format!("{app} has no server")));
            }
        };
        if let Some(timer) = inner.server_crashes.get_mut(app).and_then(|c| c.restart.take()) {
            self.timers.cancel(timer);
        }
        let env = self.prepare_server_env(inner, app)?;
        let generation = inner.next_generation;
        inner.next_generation += 1;
        let (me_line, me_log, me_exit) = (self.me.clone(), self.me.clone(), self.me.clone());
        let (app_line, app_log, app_exit) = (app.to_string(), app.to_string(), app.to_string());
        let process = ServerProcess::spawn(
            &spec.binary,
            &spec.args,
            &env,
            app,
            move |value| {
                if let Some(me) = me_line.upgrade() {
                    me.server_line(&app_line, generation, value);
                }
            },
            move |message| {
                if let Some(me) = me_log.upgrade() {
                    let outs = {
                        let mut inner = me.inner.lock().unwrap();
                        me.log_locked(&mut inner, &app_log, "info", message)
                    };
                    me.emit(outs);
                }
            },
            move |exit| {
                if let Some(me) = me_exit.upgrade() {
                    me.server_exit(&app_exit, generation, exit);
                }
            },
        )
        .map_err(|e| {
            ApiError::new("apps.server_failed", format!("could not start the server: {e}"))
        })?;
        inner.servers.insert(
            app.to_string(),
            Server {
                generation,
                process: Arc::new(process),
                spec,
                pending: HashMap::new(),
                queued: Vec::new(),
                next_id: 0,
                idle: None,
                stopping: false,
                kill: None,
            },
        );
        let mut outs = self.log_locked(inner, app, "info", "server started".into());
        outs.push(Out::Broadcast(
            json!({ "event": "apps-server", "app": app, "state": "running" }),
        ));
        Ok(outs)
    }

    /// Asks the app's server to exit; it is killed when it has not exited
    /// after [`STOP_GRACE`]. Calls in flight fail with `reason`.
    pub(super) fn stop_server_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        reason: &str,
    ) -> Vec<Out> {
        if let Some(timer) = inner.server_crashes.get_mut(app).and_then(|c| c.restart.take()) {
            self.timers.cancel(timer);
        }
        let Some(server) = inner.servers.get_mut(app).filter(|s| !s.stopping) else {
            return vec![];
        };
        server.stopping = true;
        if let Some(timer) = server.idle.take() {
            self.timers.cancel(timer);
        }
        server.process.close();
        let process = server.process.clone();
        server.kill = Some(self.timers.schedule(STOP_GRACE, move || process.kill()));
        let mut outs: Vec<Out> = server
            .pending
            .drain()
            .map(|(_, respond)| {
                Out::Respond(respond, Err(ApiError::new("apps.server_stopped", reason)))
            })
            .collect();
        server.queued.clear();
        outs.extend(self.log_locked(inner, app, "info", format!("server stopping: {reason}")));
        outs
    }

    /// After a commit: an installed and enabled app with an `always` server
    /// runs it; any other app's server stops.
    pub(super) fn sync_server_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let active = inner.mirror.apps.get(app).is_some_and(|r| r.installed && r.enabled);
        if !active {
            // Enabling again starts over after a crash series.
            inner.server_crashes.remove(app);
            return self.stop_server_locked(inner, app, "disabled");
        }
        let gave_up = inner.server_crashes.get(app).is_some_and(|c| c.count > MAX_CRASHES);
        match self.server_spec_locked(inner, app) {
            Some(Ok(spec)) if spec.always && !gave_up => match self.start_server_locked(inner, app)
            {
                Ok(outs) => outs,
                Err(error) => self.log_locked(inner, app, "error", error.message),
            },
            // Logged once per commit or start; nothing retries it.
            Some(Err(error)) if !inner.servers.contains_key(app) => {
                let always = inner.catalog.packages.get(app).is_some_and(|p| {
                    p.manifest.pointer("/server/lifecycle/start").and_then(Value::as_str)
                        == Some("always")
                });
                if always { self.log_locked(inner, app, "error", error.message) } else { vec![] }
            }
            _ => vec![],
        }
    }

    /// At supervisor start: the `always` servers of enabled apps.
    pub(super) fn start_always_servers(&self) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            let apps: Vec<String> = inner.catalog.packages.keys().cloned().collect();
            let mut outs = Vec::new();
            for app in apps {
                outs.extend(self.sync_server_locked(&mut inner, &app));
            }
            outs
        };
        self.emit(outs);
    }

    fn server_line(&self, app: &str, generation: u64, value: Value) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            if inner.servers.get(app).is_none_or(|s| s.generation != generation) {
                return;
            }
            if value["t"] == "host.request" {
                let reply = self.host_request_locked(&inner, app, &value);
                inner.servers[app].process.send(line(&reply));
                return;
            }
            let server = inner.servers.get_mut(app).expect("current server");
            match value["type"].as_str() {
                Some("result") => {
                    let id = value["id"].as_str().unwrap_or_default();
                    let Some(respond) = server.pending.remove(id) else { return };
                    let result = if value["ok"] == true {
                        Ok(json!({ "value": value.get("result").cloned().unwrap_or(Value::Null) }))
                    } else {
                        let error = &value["error"];
                        Err(ApiError::new(
                            error["code"].as_str().unwrap_or("command.failed"),
                            error["message"].as_str().unwrap_or("command failed"),
                        ))
                    };
                    if let Some(crashes) = inner.server_crashes.get_mut(app) {
                        crashes.count = 0;
                        crashes.backoff = None;
                    }
                    let mut outs = vec![Out::Respond(respond, result)];
                    outs.extend(self.server_idle_check_locked(&mut inner, app));
                    outs
                }
                Some("event") => vec![Out::Broadcast(json!({
                    "event": "apps-server-event", "app": app,
                    "name": value["event"], "data": value["data"],
                }))],
                _ => self.log_locked(
                    &mut inner,
                    app,
                    "warn",
                    format!("server line ignored: {value}"),
                ),
            }
        };
        self.emit(outs);
    }

    /// Schedules the idle stop of an on-demand server with nothing in flight.
    fn server_idle_check_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let Some(server) = inner.servers.get_mut(app) else { return vec![] };
        let Some(after) = server.spec.idle.filter(|_| !server.spec.always) else { return vec![] };
        if server.stopping || !server.pending.is_empty() || server.idle.is_some() {
            return vec![];
        }
        let (me, app_id, generation) = (self.me.clone(), app.to_string(), server.generation);
        server.idle = Some(self.timers.schedule(after, move || {
            let Some(me) = me.upgrade() else { return };
            let outs = {
                let mut inner = me.inner.lock().unwrap();
                match inner.servers.get_mut(&app_id) {
                    Some(server)
                        if server.generation == generation && server.pending.is_empty() =>
                    {
                        server.idle = None;
                        me.stop_server_locked(&mut inner, &app_id, "idle")
                    }
                    _ => vec![],
                }
            };
            me.emit(outs);
        }));
        vec![]
    }

    fn server_exit(&self, app: &str, generation: u64, exit: Exit) {
        let outs = {
            let mut inner = self.inner.lock().unwrap();
            if inner.servers.get(app).is_none_or(|s| s.generation != generation) {
                return;
            }
            let mut server = inner.servers.remove(app).expect("server");
            for timer in [server.idle.take(), server.kill.take()].into_iter().flatten() {
                self.timers.cancel(timer);
            }
            let queued: Vec<(String, Vec<u8>)> = std::mem::take(&mut server.queued);
            // Calls this process received fail; queued ones go to the next one.
            let (keep, sent): (HashMap<String, Responder>, HashMap<String, Responder>) =
                server.pending.drain().partition(|(id, _)| queued.iter().any(|(q, _)| q == id));
            let mut outs: Vec<Out> = sent
                .into_values()
                .map(|respond| {
                    Out::Respond(respond, Err(ApiError::new("apps.server_exited", exit.describe())))
                })
                .collect();
            let level = if server.stopping { "info" } else { "error" };
            outs.extend(self.log_locked(
                &mut inner,
                app,
                level,
                format!("server {}", exit.describe()),
            ));
            outs.push(Out::Broadcast(
                json!({ "event": "apps-server", "app": app, "state": "stopped" }),
            ));
            let active = inner.mirror.apps.get(app).is_some_and(|r| r.installed && r.enabled);
            if !queued.is_empty() {
                // Calls that arrived while it stopped: start the next process.
                outs.extend(self.restart_with_queued_locked(&mut inner, app, keep, queued, active));
            } else if !server.stopping && server.spec.always && active {
                outs.extend(self.schedule_server_restart_locked(&mut inner, app));
            }
            outs
        };
        self.emit(outs);
    }

    fn restart_with_queued_locked(
        &self,
        inner: &mut Inner,
        app: &str,
        mut pending: HashMap<String, Responder>,
        queued: Vec<(String, Vec<u8>)>,
        active: bool,
    ) -> Vec<Out> {
        let started = if active {
            self.start_server_locked(inner, app)
        } else {
            Err(ApiError::new("apps.disabled", "the app is disabled"))
        };
        match started {
            Ok(mut outs) => {
                let server = inner.servers.get_mut(app).expect("started");
                for (id, message) in queued {
                    if let Some(respond) = pending.remove(&id) {
                        server.pending.insert(id, respond);
                        server.process.send(message);
                    }
                }
                outs.extend(pending.into_values().map(|respond| {
                    Out::Respond(
                        respond,
                        Err(ApiError::new("apps.server_exited", "server restarted")),
                    )
                }));
                outs
            }
            Err(error) => pending
                .into_values()
                .map(|respond| Out::Respond(respond, Err(error.clone())))
                .collect(),
        }
    }

    /// A crashed `always` server restarts after a backoff, at most
    /// [`MAX_CRASHES`] times in a row (a successful call resets the count).
    fn schedule_server_restart_locked(&self, inner: &mut Inner, app: &str) -> Vec<Out> {
        let crashes = inner.server_crashes.entry(app.to_string()).or_default();
        crashes.count += 1;
        if crashes.count > MAX_CRASHES {
            let count = crashes.count - 1;
            return self.log_locked(
                inner,
                app,
                "error",
                format!("server crashed {count} times in a row; not restarting until the app is enabled again"),
            );
        }
        let delay = crashes
            .backoff
            .get_or_insert_with(|| {
                Backoff::new(Duration::from_millis(500), Duration::from_secs(30))
            })
            .next_delay();
        let (me, app_id) = (self.me.clone(), app.to_string());
        crashes.restart = Some(self.timers.schedule(delay, move || {
            let Some(me) = me.upgrade() else { return };
            let outs = {
                let mut inner = me.inner.lock().unwrap();
                if let Some(crashes) = inner.server_crashes.get_mut(&app_id) {
                    crashes.restart = None;
                }
                me.sync_server_locked(&mut inner, &app_id)
            };
            me.emit(outs);
        }));
        vec![]
    }
}

impl Supervisor {
    /// The data and temporary directories of `app`'s server:
    /// `<state>/apps-data/<namespace>` and `<state>/apps-tmp/<namespace>`.
    fn server_dirs(&self, app: &str) -> (PathBuf, PathBuf) {
        let base =
            self.config.state_dir.clone().unwrap_or_else(|| std::env::temp_dir().join("cmux-apps"));
        let namespace = cmux_app_manifest::app_namespace(app);
        (base.join("apps-data").join(&namespace), base.join("apps-tmp").join(&namespace))
    }

    /// Creates the server's directories and returns its environment (the
    /// allowlist in the module docs).
    fn prepare_server_env(
        &self,
        inner: &Inner,
        app: &str,
    ) -> Result<Vec<(String, String)>, ApiError> {
        use std::os::unix::fs::DirBuilderExt;
        let failed = |e: std::io::Error| {
            ApiError::new("apps.server_failed", format!("server directories: {e}"))
        };
        let fresh = |dir: &Path| -> std::io::Result<()> {
            match std::fs::remove_dir_all(dir) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
            std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)
        };
        let (data, tmp) = self.server_dirs(app);
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&data).map_err(failed)?;
        let entries = inner
            .catalog
            .packages
            .get(app)
            .and_then(|p| p.manifest.pointer("/server/data").and_then(Value::as_array).cloned())
            .unwrap_or_default();
        for entry in entries {
            // The schema limits names to a local id, so a name stays inside.
            let Some(name) = entry["name"].as_str() else { continue };
            let dir = data.join(name);
            if entry["class"] == "ephemeral" {
                fresh(&dir).map_err(failed)?;
            } else {
                std::fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(&dir)
                    .map_err(failed)?;
            }
        }
        fresh(&tmp).map_err(failed)?;
        let mut env = vec![
            ("CMUX_APP_ID".to_string(), app.to_string()),
            ("CMUX_APP_DATA_DIR".to_string(), data.to_string_lossy().into_owned()),
            ("TMPDIR".to_string(), tmp.to_string_lossy().into_owned()),
        ];
        if let Ok(lang) = std::env::var("LANG") {
            env.push(("LANG".to_string(), lang));
        }
        Ok(env)
    }

    /// Uninstall: the server's data and temporary directories go with the
    /// app's storage.
    pub(super) fn remove_server_dirs(&self, app: &str) {
        let (data, tmp) = self.server_dirs(app);
        let _ = std::fs::remove_dir_all(data);
        let _ = std::fs::remove_dir_all(tmp);
    }

    /// `cmux.host.link.get` for `app`: the daemon executable, the WireGuard
    /// hub socket, a link state directory in the app's data directory, the
    /// app's temporary directory for link sockets, and this machine's name.
    ///
    /// `hub_socket` is always `null` for now. The link lane (lane 12: the
    /// WireGuard engine and the `cmux link` agent) owns that socket; the
    /// daemon neither spawns it nor reads it from its launch environment. It
    /// will come from the link agent's registration file at a well-known
    /// path under the daemon state directory, which lane 12 defines. Until
    /// then the Cloud server answers `link_unavailable`.
    pub(super) fn host_link(&self, app: &str) -> Value {
        let (data, tmp) = self.server_dirs(app);
        let state_dir = data.join("link");
        let _ = std::fs::create_dir_all(&state_dir);
        json!({
            "binary": std::env::current_exe().ok(),
            "hub_socket": Value::Null,
            "state_dir": state_dir,
            "socket_dir": tmp,
            "device_name": device_name(),
        })
    }

    /// Whether `app` may call the host op `op`: a first-party app whose
    /// manifest declares the server scope `op:<op>`.
    fn host_op_allowed(inner: &Inner, app: &str, op: &str) -> bool {
        inner.catalog.packages.get(app).is_some_and(|package| {
            package.tier == Tier::FirstParty
                && package
                    .manifest
                    .pointer("/server/scopes")
                    .and_then(Value::as_object)
                    .is_some_and(|scopes| scopes.contains_key(&format!("op:{op}")))
        })
    }

    /// Answers one `host.request` frame of `app`'s server.
    fn host_request_locked(&self, inner: &Inner, app: &str, request: &Value) -> Value {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let error = |code: &str, message: &str, retryable: bool| json!({ "t": "host.error", "id": id, "code": code, "message": message, "retryable": retryable });
        match request["op"].as_str().unwrap_or_default() {
            op @ "cmux.host.link.get" => {
                if Self::host_op_allowed(inner, app, op) {
                    json!({ "t": "host.result", "id": id, "value": self.host_link(app) })
                } else {
                    error(
                        "apps.scope_missing",
                        "the server does not declare op:cmux.host.link.get",
                        false,
                    )
                }
            }
            "cmux.credential.relay" => {
                error("unavailable", "the cmux credential relay is not available yet", true)
            }
            op => error("apps.op.unknown", &format!("the host has no op {op}"), false),
        }
    }

    /// Sends `cmux.host.link.changed` to every running server that may read
    /// the link. Nothing changes the daemon's link values during its life
    /// yet; the daemon calls this when the link agent's registration (lane
    /// 12) appears or changes.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(super) fn host_link_changed(&self) {
        let inner = self.inner.lock().unwrap();
        for (app, server) in &inner.servers {
            if !server.stopping && Self::host_op_allowed(&inner, app, "cmux.host.link.get") {
                server.process.send(line(&json!({
                    "t": "host.event", "op": "cmux.host.link.changed", "data": self.host_link(app),
                })));
            }
        }
    }
}

/// This machine's name, or `cmux`.
fn device_name() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most buf.len() bytes into our buffer.
    let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    let name = if ok { String::from_utf8_lossy(&buf[..end]).into_owned() } else { String::new() };
    if name.is_empty() || name.chars().any(char::is_control) { "cmux".into() } else { name }
}

impl Supervisor {
    /// Verifies an open token a server passed on (the host side of the
    /// terminal connector and backend calls this in its connect path). A
    /// token works once, for the app it was minted for, within 60 s of its
    /// run; any lookup consumes it, so a wrong app's attempt burns it too.
    /// Answers what the token was minted for, so the caller can check the op.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn consume_open_token(&self, token: &str, app: &str) -> Option<OpenTokenUse> {
        self.consume_open_token_at(token, app, Instant::now())
    }

    /// [`Self::consume_open_token`] at `now` (tests of callers inject the clock).
    pub(crate) fn consume_open_token_at(
        &self,
        token: &str,
        app: &str,
        now: Instant,
    ) -> Option<OpenTokenUse> {
        let mut inner = self.inner.lock().unwrap();
        let minted = inner.open_tokens.remove(token)?;
        inner.open_tokens.retain(|_, t| t.expires > now);
        (minted.app == app && minted.expires > now)
            .then_some(OpenTokenUse { op: minted.op, idempotency_key: minted.idempotency_key })
    }
}
