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

use std::io::{self, BufRead, BufReader, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::{CallContext, Engine, ToolOutput};
use crate::policy::OriginKind;
use crate::wire;

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
    serve_on(engine, transport::Listener::bind(endpoint)?, endpoint, secret)
}

fn serve_on(
    engine: Arc<Engine>,
    listener: transport::Listener,
    endpoint: &str,
    secret: &[u8],
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
        handle(shared, &stream, &writer, &line);
    }
    stream.shutdown();
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

fn handle(shared: &Arc<Shared>, stream: &Arc<dyn Stream>, writer: &Arc<Mutex<()>>, line: &[u8]) {
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
    match request.get("method").and_then(Value::as_str).unwrap_or_default() {
        "tools/call" => {
            let Some(name) = request.get("name").and_then(Value::as_str).map(str::to_string) else {
                return fail("invalid_request", "name is required".into());
            };
            let arguments = request.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let (engine, stream, writer) =
                (Arc::clone(&shared.engine), Arc::clone(stream), Arc::clone(writer));
            let session = ctx.session.clone();
            shared.lanes.submit(&session, move || {
                let out = engine.call(&ctx, &name, &arguments);
                send(&stream, &writer, &json!({"id": id, "ok": true, "result": out.to_json()}));
            });
        }
        "session/end" => {
            let (engine, stream, writer) =
                (Arc::clone(&shared.engine), Arc::clone(stream), Arc::clone(writer));
            let session = ctx.session.clone();
            shared.lanes.submit(&session, move || {
                engine.end_session(&ctx.session);
                send(&stream, &writer, &json!({"id": id, "ok": true, "result": {}}));
            });
        }
        "status" => {
            let out: ToolOutput = shared.engine.call(&ctx, "status", &json!({}));
            let mut result = out.to_json();
            result["protocol"] = json!(wire::PROTOCOL);
            result["pid"] = json!(std::process::id());
            send(stream, writer, &json!({"id": id, "ok": true, "result": result}));
        }
        "tools/list" => {
            let mut list = crate::tools::mcp_list();
            list["instructions"] = json!(crate::tools::INSTRUCTIONS);
            send(stream, writer, &json!({"id": id, "ok": true, "result": list}));
        }
        other => fail("unknown_method", format!("unknown method {other:?}")),
    }
}

#[cfg(all(test, unix))]
#[path = "server/tests.rs"]
mod tests;
