//! A JSON-RPC line client of an acpmux daemon's unix socket, as the app is: one writer, one reader
//! thread that hands each response to its caller and every other line to a handler. Many requests
//! can be in flight at once (`start`), so 2,000 attaches or prompts go out without waiting on each
//! other.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// What the reader hands a notification (or a request from the daemon): the line's arrival time
/// (unix us, taken before parsing), its method and the parsed message.
pub type Handler = Arc<dyn Fn(u64, &str, &Value) + Send + Sync>;

type Pending = Arc<Mutex<HashMap<u64, Sender<Value>>>>;

pub struct Rpc {
    writer: Mutex<UnixStream>,
    next: AtomicU64,
    pending: Pending,
}

pub fn now_us() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Dropping the client shuts the socket, so its reader (a thread of the caller's scope) ends.
impl Drop for Rpc {
    fn drop(&mut self) {
        let _ = lock(&self.writer).shutdown(std::net::Shutdown::Both);
    }
}

impl Rpc {
    /// Connects; the reader runs in scope `s`, its owner, until the socket closes.
    pub fn connect<'s>(
        s: &'s std::thread::Scope<'s, '_>,
        socket: &Path,
        handler: Handler,
    ) -> Result<Rpc, String> {
        let stream =
            UnixStream::connect(socket).map_err(|e| format!("{}: {e}", socket.display()))?;
        let reader = stream.try_clone().map_err(|e| e.to_string())?;
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let p = pending.clone();
        s.spawn(move || read_loop(reader, p, handler));
        Ok(Rpc { writer: Mutex::new(stream), next: AtomicU64::new(0), pending })
    }

    /// Sends a request; its answer (the whole response object) arrives on the receiver.
    pub fn start(&self, method: &str, params: Value) -> Result<Receiver<Value>, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = channel();
        lock(&self.pending).insert(id, tx);
        let mut line =
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string();
        line.push('\n');
        let mut w = lock(&self.writer);
        if let Err(e) = w.write_all(line.as_bytes()) {
            lock(&self.pending).remove(&id);
            return Err(format!("{method}: write: {e}"));
        }
        Ok(rx)
    }

    /// One request, waited for: its result, or its error as text.
    pub fn call(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, String> {
        let rx = self.start(method, params)?;
        wait(&rx, method, timeout)
    }
}

/// The answer on `rx`: its result, or its error (or a timeout) as text.
pub fn wait(rx: &Receiver<Value>, method: &str, timeout: Duration) -> Result<Value, String> {
    match rx.recv_timeout(timeout) {
        Ok(v) => match v.get("error") {
            Some(e) if !e.is_null() => Err(format!("{method}: {e}")),
            _ => Ok(v.get("result").cloned().unwrap_or(Value::Null)),
        },
        Err(_) => Err(format!("{method}: no answer in {} ms", timeout.as_millis())),
    }
}

fn read_loop(stream: UnixStream, pending: Pending, handler: Handler) {
    let mut r = BufReader::with_capacity(1 << 20, stream);
    let mut line = String::new();
    loop {
        line.clear();
        match r.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let at = now_us();
        let Ok(v) = serde_json::from_str::<Value>(line.trim()) else { continue };
        let method = v.get("method").and_then(Value::as_str);
        match (method, v.get("id").and_then(Value::as_u64)) {
            (None, Some(id)) => {
                if let Some(tx) = lock(&pending).remove(&id) {
                    let _ = tx.send(v);
                }
            }
            (Some(m), _) => handler(at, m, &v),
            _ => {}
        }
    }
    // The connection ended: every caller still waiting gets an error now.
    for (_, tx) in lock(&pending).drain() {
        let _ = tx.send(json!({"error": "connection closed"}));
    }
}
