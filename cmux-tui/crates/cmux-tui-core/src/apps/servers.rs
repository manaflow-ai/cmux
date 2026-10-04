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
//! Wire (JSON lines on the server's stdin and stdout, the `cmux-cloud`
//! shape): supervisor -> server `{type: op, id, op, args, origin,
//! idempotency_key}`; server -> supervisor `{type: result, id, ok,
//! result | error}`, `{type: event, event, data}` (broadcast as
//! `apps-server-event`) and `relay.request` / `relay.session`, answered
//! `relay.error` `unavailable` until the credential relay op exists. The
//! server's stderr goes to the app's log. The process gets an empty
//! environment.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
    /// Spawns `binary` with an empty environment. `on_line` runs on the
    /// reader thread for each stdout line, `on_log` for each stderr line,
    /// and `on_exit` once after stdout closed and the child was reaped.
    pub fn spawn(
        binary: &Path,
        args: &[String],
        name: &str,
        on_line: impl Fn(Value) + Send + 'static,
        on_log: impl Fn(String) + Send + 'static,
        on_exit: impl FnOnce(Exit) + Send + 'static,
    ) -> std::io::Result<Self> {
        let mut child = Command::new(binary)
            .args(args)
            .env_clear()
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
        args: Value,
        origin: Origin,
        idempotency_key: Option<String>,
        respond: Responder,
    ) -> Vec<Out> {
        let outs = match self.start_server_locked(inner, app) {
            Ok(outs) => outs,
            Err(error) => return vec![Out::Respond(respond, Err(error))],
        };
        let server = inner.servers.get_mut(app).expect("started");
        if let Some(timer) = server.idle.take() {
            self.timers.cancel(timer);
        }
        server.next_id += 1;
        let id = format!("s{}", server.next_id);
        let message = line(&json!({
            "type": "op", "id": id, "op": op, "args": args, "origin": origin,
            "idempotency_key": idempotency_key,
        }));
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
        let generation = inner.next_generation;
        inner.next_generation += 1;
        let (me_line, me_log, me_exit) = (self.me.clone(), self.me.clone(), self.me.clone());
        let (app_line, app_log, app_exit) = (app.to_string(), app.to_string(), app.to_string());
        let process = ServerProcess::spawn(
            &spec.binary,
            &spec.args,
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
            let Some(server) = inner.servers.get_mut(app).filter(|s| s.generation == generation)
            else {
                return;
            };
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
                Some(kind) if kind.starts_with("relay.") => {
                    // TODO(APP-R1): the credential relay op (`op:cmux.credential.relay`).
                    server.process.send(line(&json!({
                        "type": "relay.error", "id": value["id"], "code": "unavailable",
                        "message": "the cmux credential relay is not available yet",
                    })));
                    vec![]
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
