//! The worker's agent socket server (`cmux-computer-use-v1`, [`crate::wire`]),
//! the one implementation every platform uses: the Linux and Windows
//! worker (`cmux-tui __computer-use-worker`) serves it directly and the
//! macOS Swift worker through the C ABI (`cmux_cu_serve`).
//!
//! - Endpoint: a Unix socket, 0600 in a 0700 directory (macOS, Linux), or a
//!   local named pipe whose DACL admits only this user (Windows).
//! - Admission, in order: the peer is this user (the kernel's peer uid, or
//!   the pipe client's token user SID), then its first line carries the
//!   per-launch secret (compared in constant time). A refused peer gets
//!   `{"ok":false,"error":"refused","reason":R}` and is closed.
//! - Requests (`tools/call`, `session/end`) run on [`lanes::Lanes`]: one
//!   ordered lane per agent session on a shared pool, so a slow call never
//!   blocks another session and a session's calls never reorder. A retried
//!   `call_id` queues behind its first attempt and the engine answers it from
//!   memory. `status` and `tools/list` answer at once.
//! - A call keeps running when its connection drops, so the bridge's retry on
//!   a new connection gets the first attempt's result.
//! - Lifecycle: `session/attach` holds its connection open for the agent's
//!   life (the bridge's); when the last one of a session closes (the agent's
//!   process exited or crashed), the session ends as with `session/end`, so
//!   its cursor never lingers. A session that calls with no attach (the
//!   `cmux computer-use call` CLI, one process per call; a relayed remote
//!   call) keeps its state between its calls, so the element ids one call
//!   showed act in the next, and ends once idle or crowded out
//!   ([`detached`]). `session/idle {session, prefix?}` ends the
//!   Computer Use of a session whose agent turn ended (the daemon and
//!   acpmux send it), keeping its approvals.
//! - Hot upgrade (the worker's, [`serve_replaceable`]): once the worker's executable was
//!   replaced on disk, new requests that run on a lane are refused by closing their
//!   connection unanswered (the bridge retries them on the next worker), and the ones already
//!   admitted finish first ([`crate::replaced`]).
//! - `preview/watch` turns its connection into the live preview's stream
//!   ([`crate::preview`]): `{"event":"preview",...}` lines, the latest per
//!   session when the peer reads slower than frames come.

use std::io::{self, BufRead, BufReader, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::{CallContext, Engine, ToolOutput, set_key};
use crate::policy::OriginKind;
use crate::wire;

pub mod detached;
pub mod lanes;
#[cfg(unix)]
#[path = "server/unix.rs"]
mod transport;
#[cfg(windows)]
#[path = "server/windows.rs"]
mod transport;

#[cfg(unix)]
pub use transport::private_dir;

/// How long a new peer has to send its secret line.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// The secret line is short; anything longer is refused unread.
const SECRET_LINE_MAX: usize = 1024;

/// One connected peer, as the platform transport gives it.
pub(crate) trait Stream: Send + Sync + 'static {
    fn read(&self, buf: &mut [u8]) -> io::Result<usize>;
    fn write_all(&self, buf: &[u8]) -> io::Result<()>;
    fn set_read_timeout(&self, limit: Option<Duration>);
    /// Ends the connection; a blocked read returns.
    fn shutdown(&self);
}

struct Reader(Arc<dyn Stream>);

impl Read for Reader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.read(buf)
    }
}

struct Shared {
    engine: Arc<Engine>,
    secret: Vec<u8>,
    stopped: AtomicBool,
    lanes: Arc<lanes::Lanes>,
    connections: Mutex<Vec<Weak<dyn Stream>>>,
    /// Open `session/attach` connections per session.
    attached: Mutex<std::collections::HashMap<String, usize>>,
    /// Sessions that call with no open attach, ended once idle ([`detached`]).
    detached: Mutex<detached::Detached>,
    /// The worker's watch on its own executable (hot upgrade); None in cmux Remote.
    swap: Option<Arc<crate::replaced::Swap>>,
}

/// A serving endpoint. [`Server::stop`] (or drop) stops accepting, ends the
/// live connections and removes the Unix socket file.
pub struct Server {
    shared: Arc<Shared>,
    listener: Arc<transport::Listener>,
    accept: Option<std::thread::JoinHandle<()>>,
    endpoint: String,
}

/// Serves `engine` on `endpoint` (a socket path, or `\\.\pipe\NAME` on
/// Windows) for peers that present `secret`.
pub fn serve(engine: Arc<Engine>, endpoint: &str, secret: &[u8]) -> io::Result<Server> {
    serve_on(engine, transport::Listener::bind(endpoint)?, endpoint, secret, None)
}

/// [`serve`] for a worker that hands over to a replaced executable between calls.
pub fn serve_replaceable(
    engine: Arc<Engine>,
    endpoint: &str,
    secret: &[u8],
    swap: Arc<crate::replaced::Swap>,
) -> io::Result<Server> {
    serve_on(engine, transport::Listener::bind(endpoint)?, endpoint, secret, Some(swap))
}

fn serve_on(
    engine: Arc<Engine>,
    listener: transport::Listener,
    endpoint: &str,
    secret: &[u8],
    swap: Option<Arc<crate::replaced::Swap>>,
) -> io::Result<Server> {
    if secret.len() < 16 {
        listener.remove();
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the secret must be at least 16 bytes",
        ));
    }
    let listener = Arc::new(listener);
    let shared = Arc::new(Shared {
        engine,
        secret: secret.to_vec(),
        stopped: AtomicBool::new(false),
        lanes: lanes::Lanes::new(),
        connections: Mutex::new(Vec::new()),
        attached: Mutex::new(std::collections::HashMap::new()),
        detached: Mutex::new(detached::Detached::default()),
        swap,
    });
    let accept = {
        let shared = Arc::clone(&shared);
        let listener = Arc::clone(&listener);
        std::thread::Builder::new()
            .name("cmux-cu-accept".into())
            .spawn(move || accept_loop(&shared, &listener))?
    };
    Ok(Server { shared, listener, accept: Some(accept), endpoint: endpoint.to_string() })
}

impl Server {
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        if self.shared.stopped.swap(true, Ordering::SeqCst) {
            return;
        }
        self.listener.wake();
        if let Some(accept) = self.accept.take() {
            let _ = accept.join();
        }
        self.listener.remove();
        for connection in lock(&self.shared.connections).drain(..) {
            if let Some(connection) = connection.upgrade() {
                connection.shutdown();
            }
        }
        self.shared.lanes.stop();
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn accept_loop(shared: &Arc<Shared>, listener: &transport::Listener) {
    let mut failures = 0u32;
    while !shared.stopped.load(Ordering::SeqCst) {
        let (stream, admitted) = match listener.accept() {
            Ok(accepted) => {
                failures = 0;
                accepted
            }
            Err(error) => {
                failures += 1;
                if failures > 100 {
                    eprintln!("cmux Computer Use: the agent socket stopped accepting: {error}");
                    return;
                }
                continue;
            }
        };
        if shared.stopped.load(Ordering::SeqCst) {
            stream.shutdown();
            return;
        }
        {
            let mut connections = lock(&shared.connections);
            connections.retain(|c| c.strong_count() > 0);
            connections.push(Arc::downgrade(&stream));
        }
        let shared = Arc::clone(shared);
        let _ = std::thread::Builder::new()
            .name("cmux-cu-conn".into())
            .spawn(move || connection(&shared, stream, admitted));
    }
}

fn send(stream: &Arc<dyn Stream>, writer: &Mutex<()>, value: &Value) {
    let mut line = value.to_string();
    line.push('\n');
    let _guard = lock(writer);
    let _ = stream.write_all(line.as_bytes());
}

fn refuse(stream: &Arc<dyn Stream>, reason: &str) {
    let line = format!("{}\n", json!({"ok": false, "error": "refused", "reason": reason}));
    let _ = stream.write_all(line.as_bytes());
    stream.shutdown();
}

/// Reads one line of at most `max` bytes (without its newline); None at EOF
/// or when the line is longer.
fn read_line(reader: &mut BufReader<Reader>, max: usize) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let read = reader.by_ref().take(max as u64 + 1).read_until(b'\n', &mut line)?;
    if read == 0 {
        return Ok(None);
    }
    if line.last() == Some(&b'\n') {
        line.pop();
    } else if line.len() > max {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "line too long"));
    }
    Ok(Some(line))
}

fn connection(shared: &Arc<Shared>, stream: Arc<dyn Stream>, admitted: Result<(), String>) {
    if let Err(reason) = admitted {
        refuse(&stream, &reason);
        return;
    }
    stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT));
    let mut reader = BufReader::new(Reader(Arc::clone(&stream)));
    let hello = match read_line(&mut reader, SECRET_LINE_MAX) {
        Ok(Some(line)) => line,
        _ => return refuse(&stream, "no secret"),
    };
    let presented = serde_json::from_slice::<Value>(&hello)
        .ok()
        .and_then(|v| v.get("secret").and_then(Value::as_str).and_then(wire::unhex));
    if !presented.is_some_and(|s| wire::same_secret(&s, &shared.secret)) {
        return refuse(&stream, "bad secret");
    }
    stream.set_read_timeout(None);
    let writer = Arc::new(Mutex::new(()));
    send(
        &stream,
        &writer,
        &json!({"ok": true, "protocol": wire::PROTOCOL, "capabilities": [wire::CAPABILITY], "pid": std::process::id()}),
    );
    let mut conn = Conn::default();
    loop {
        let line = match read_line(&mut reader, wire::MAX_LINE) {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(_) => {
                send(&stream, &writer, &json!({"id": null, "ok": false, "error": "line_too_long"}));
                break;
            }
        };
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        if shared.stopped.load(Ordering::SeqCst) {
            break;
        }
        handle(shared, &stream, &writer, &line, &mut conn);
    }
    conn.close(shared);
    stream.shutdown();
}

/// What one connection holds beyond its requests.
#[derive(Default)]
struct Conn {
    /// Its `session/attach` sessions.
    attached: Vec<String>,
    /// Its `preview/watch`: the watcher id and its outbox.
    watch: Option<(u64, Arc<Outbox>)>,
}

impl Conn {
    /// The connection ended: its watch stops, and a session whose last
    /// attach this was ends (its agent's process is gone).
    fn close(&mut self, shared: &Arc<Shared>) {
        if let Some((id, outbox)) = self.watch.take() {
            shared.engine.preview().unwatch(id);
            outbox.close();
        }
        for session in self.attached.drain(..) {
            let last = {
                let mut attached = lock(&shared.attached);
                let count = attached.entry(session.clone()).or_insert(1);
                *count = count.saturating_sub(1);
                let last = *count == 0;
                if last {
                    attached.remove(&session);
                }
                last
            };
            if last {
                let engine = Arc::clone(&shared.engine);
                let ended = session.clone();
                shared.lanes.submit(&session, move || engine.end_session(&ended));
            }
        }
    }
}

/// A watch connection's outgoing lines, the latest per session: a slow
/// reader never stalls the preview (or the calls and frames that feed it),
/// and never misses a card's last state.
#[derive(Default)]
struct Outbox {
    state: Mutex<(Vec<(String, Value)>, bool)>,
    ready: std::sync::Condvar,
}

impl Outbox {
    fn push(&self, line: &Value) -> bool {
        let mut state = lock(&self.state);
        if state.1 {
            return false;
        }
        let key = line.get("session").and_then(Value::as_str).unwrap_or_default().to_string();
        match state.0.iter_mut().find(|(k, _)| *k == key) {
            Some(slot) => slot.1 = line.clone(),
            None => state.0.push((key, line.clone())),
        }
        self.ready.notify_one();
        true
    }

    fn close(&self) {
        lock(&self.state).1 = true;
        self.ready.notify_all();
    }

    /// The writer thread: sends lines until the outbox closes or a write fails.
    fn drain(&self, stream: &Arc<dyn Stream>, writer: &Mutex<()>) {
        loop {
            let lines = {
                let mut state = lock(&self.state);
                while state.0.is_empty() && !state.1 {
                    state = self.ready.wait(state).unwrap_or_else(PoisonError::into_inner);
                }
                if state.1 {
                    return;
                }
                std::mem::take(&mut state.0)
            };
            for (_, line) in lines {
                let mut text = line.to_string();
                text.push('\n');
                let _guard = lock(writer);
                if stream.write_all(text.as_bytes()).is_err() {
                    self.close();
                    return;
                }
            }
        }
    }
}

/// `session` calls now: a detached one (no open attach) is kept until idle,
/// and the detached sessions idle or crowded out end, each on its own lane
/// after its calls in flight ([`detached::Detached::touch`]).
fn end_idle_detached(shared: &Arc<Shared>, session: &str) {
    let ended = {
        let attached = lock(&shared.attached);
        lock(&shared.detached)
            .touch(session, std::time::Instant::now(), |s| attached.get(s).is_some_and(|n| *n > 0))
    };
    for session in ended {
        let engine = Arc::clone(&shared.engine);
        let ended = session.clone();
        shared.lanes.submit(&session, move || engine.end_session(&ended));
    }
}

/// A call's context from its request. `origin` is the bridge's (the only
/// client that holds the secret); a remote origin only ever narrows what the
/// policy allows, and a missing one is a local agent.
pub fn context(request: &Value) -> Result<CallContext, String> {
    let origin = match request.get("origin") {
        Some(o) if !o.is_null() => serde_json::from_value::<OriginKind>(o.clone())
            .map_err(|e| format!("bad origin: {e}"))?,
        _ => OriginKind::Local,
    };
    let text = |key: &str| request.get(key).and_then(Value::as_str).filter(|s| !s.is_empty());
    Ok(CallContext {
        session: text("session").unwrap_or("default").to_string(),
        label: text("label").unwrap_or("Agent").to_string(),
        call_id: text("call_id").map(str::to_string),
        origin,
        tag: text("tag").map(str::to_string),
    })
}

fn handle(
    shared: &Arc<Shared>,
    stream: &Arc<dyn Stream>,
    writer: &Arc<Mutex<()>>,
    line: &[u8],
    conn: &mut Conn,
) {
    let Ok(request) = serde_json::from_slice::<Value>(line) else {
        return send(stream, writer, &json!({"id": null, "ok": false, "error": "invalid_json"}));
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let fail = |error: &str, message: String| {
        send(stream, writer, &json!({"id": id, "ok": false, "error": error, "message": message}));
    };
    let ctx = match context(&request) {
        Ok(ctx) => ctx,
        Err(message) => return fail("invalid_request", message),
    };
    let method = request.get("method").and_then(Value::as_str).unwrap_or_default();
    // A request that runs on a lane holds a ticket until it ends; a replaced worker admits
    // none (the connection closes unanswered and the bridge retries on the next worker).
    let ticket = match (&shared.swap, method) {
        (Some(swap), "tools/call" | "session/end" | "session/idle") => match swap.enter() {
            Some(ticket) => Some(ticket),
            None => return stream.shutdown(),
        },
        _ => None,
    };
    match method {
        "tools/call" => {
            let Some(name) = request.get("name").and_then(Value::as_str).map(str::to_string) else {
                return fail("invalid_request", "name is required".into());
            };
            let arguments = request.get("arguments").cloned().unwrap_or_else(|| json!({}));
            end_idle_detached(shared, &ctx.session);
            let (engine, stream, writer) =
                (Arc::clone(&shared.engine), Arc::clone(stream), Arc::clone(writer));
            let session = ctx.session.clone();
            shared.lanes.submit(&session, move || {
                let _ticket = ticket;
                let out = engine.call(&ctx, &name, &arguments);
                send(&stream, &writer, &json!({"id": id, "ok": true, "result": out.to_json()}));
            });
        }
        "session/end" => {
            let (engine, stream, writer) =
                (Arc::clone(&shared.engine), Arc::clone(stream), Arc::clone(writer));
            let session = ctx.session.clone();
            lock(&shared.detached).forget(&session);
            shared.lanes.submit(&session, move || {
                let _ticket = ticket;
                engine.end_session(&ctx.session);
                send(&stream, &writer, &json!({"id": id, "ok": true, "result": {}}));
            });
        }
        "session/attach" => {
            if !conn.attached.contains(&ctx.session) {
                *lock(&shared.attached).entry(ctx.session.clone()).or_insert(0) += 1;
                conn.attached.push(ctx.session);
            }
            send(stream, writer, &json!({"id": id, "ok": true, "result": {}}));
        }
        "session/idle" => {
            let prefix = request.get("prefix").and_then(Value::as_bool).unwrap_or(false);
            let (engine, stream, writer) =
                (Arc::clone(&shared.engine), Arc::clone(stream), Arc::clone(writer));
            let session = ctx.session.clone();
            let run = move || {
                let _ticket = ticket;
                let ended = engine.idle(&session, prefix);
                send(&stream, &writer, &json!({"id": id, "ok": true, "result": {"ended": ended}}));
            };
            // One session: after its calls in flight. A prefix: at once.
            if prefix {
                run();
            } else {
                shared.lanes.submit(&ctx.session, run);
            }
        }
        // The window's pixels are for this machine's own cmux only.
        "preview/watch" if ctx.origin != OriginKind::Local => {
            fail("refused", "the live preview is for this machine's cmux".into());
        }
        "preview/watch" => {
            if conn.watch.is_none() {
                let outbox = Arc::new(Outbox::default());
                let (drain, stream, writer) =
                    (Arc::clone(&outbox), Arc::clone(stream), Arc::clone(writer));
                let _ = std::thread::Builder::new()
                    .name("cmux-cu-preview".into())
                    .spawn(move || drain.drain(&stream, &writer));
                let sink = Arc::clone(&outbox);
                let watcher = shared.engine.preview().watch(Arc::new(move |line| sink.push(line)));
                conn.watch = Some((watcher, outbox));
            }
            send(stream, writer, &json!({"id": id, "ok": true, "result": {}}));
        }
        "status" => {
            let out: ToolOutput = shared.engine.call(&ctx, "status", &json!({}));
            let mut result = out.to_json();
            set_key(&mut result, "protocol", json!(wire::PROTOCOL));
            set_key(&mut result, "pid", json!(std::process::id()));
            send(stream, writer, &json!({"id": id, "ok": true, "result": result}));
        }
        "tools/list" => {
            let mut list = crate::tools::mcp_list();
            set_key(&mut list, "instructions", json!(crate::tools::INSTRUCTIONS));
            send(stream, writer, &json!({"id": id, "ok": true, "result": list}));
        }
        other => fail("unknown_method", format!("unknown method {other:?}")),
    }
}

#[cfg(all(test, unix))]
#[path = "server/tests.rs"]
mod tests;
