//! A blocking JSON-RPC client on acpmux's Unix socket (newline-delimited JSON), one reader thread
//! per connection. Replies go to their caller; every other line (a notification) goes to the
//! connection's `on_note` with its arrival time, unparsed, so a follower can scan for tags at
//! the rate the daemon sends.

use super::super::agent::now_us;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct Reply {
    pub v: Value,
    pub bytes: usize,
}

type Pending = Arc<Mutex<HashMap<u64, mpsc::Sender<Reply>>>>;

pub struct Conn {
    w: Mutex<UnixStream>,
    shut: UnixStream,
    pending: Pending,
    next: AtomicU64,
}

pub type OnNote<'a> = Box<dyn FnMut(&str, u64) + Send + 'a>;

/// Whether a line is a reply: its `"result"`/`"error"` key comes before any `"method"` key (the
/// top-level keys come before nested content, in either key order acpmux writes).
fn is_reply(line: &str) -> bool {
    let method = line.find("\"method\":");
    let result = [line.find("\"result\":"), line.find("\"error\":")].into_iter().flatten().min();
    match (method, result) {
        (Some(m), Some(r)) => r < m,
        (None, Some(_)) => true,
        _ => false,
    }
}

impl Conn {
    /// Its reader thread runs in scope `s` and ends when the connection closes (`close`, the
    /// last `Arc` dropped, or the daemon gone).
    pub fn connect<'s>(
        s: &'s std::thread::Scope<'s, '_>,
        path: &Path,
        mut on_note: OnNote<'s>,
    ) -> Result<Arc<Conn>, String> {
        let stream =
            UnixStream::connect(path).map_err(|e| format!("connect {}: {e}", path.display()))?;
        let r = stream.try_clone().map_err(|e| e.to_string())?;
        let shut = stream.try_clone().map_err(|e| e.to_string())?;
        let pending: Pending = Arc::default();
        let conn = Arc::new(Conn {
            w: Mutex::new(stream),
            shut,
            pending: pending.clone(),
            next: AtomicU64::new(1),
        });
        s.spawn(move || {
            let mut reader = BufReader::with_capacity(1 << 20, r);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let at = now_us();
                if !is_reply(&line) {
                    on_note(&line, at);
                    continue;
                }
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                let Some(id) = v.get("id").and_then(Value::as_u64) else { continue };
                let tx = pending.lock().ok().and_then(|mut p| p.remove(&id));
                if let Some(tx) = tx {
                    let _ = tx.send(Reply { v, bytes: line.len() });
                }
            }
            if let Ok(mut p) = pending.lock() {
                p.clear();
            }
        });
        Ok(conn)
    }

    fn write(&self, v: &Value) -> Result<(), String> {
        let mut text = v.to_string();
        text.push('\n');
        let mut w = self.w.lock().map_err(|_| "writer poisoned".to_string())?;
        w.write_all(text.as_bytes()).map_err(|e| format!("write: {e}"))
    }

    /// One request; the reply's `result`, or its error as text.
    pub fn call(&self, method: &str, params: Value, timeout: Duration) -> Result<Reply, String> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        if let Ok(mut p) = self.pending.lock() {
            p.insert(id, tx);
        }
        self.write(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))?;
        let reply = rx.recv_timeout(timeout).map_err(|e| {
            if let Ok(mut p) = self.pending.lock() {
                p.remove(&id);
            }
            match e {
                mpsc::RecvTimeoutError::Timeout => format!("{method}: no reply in {timeout:?}"),
                mpsc::RecvTimeoutError::Disconnected => format!("{method}: connection closed"),
            }
        })?;
        if let Some(err) = reply.v.get("error") {
            return Err(format!("{method}: {err}"));
        }
        Ok(reply)
    }

    pub fn notify(&self, method: &str, params: Value) -> Result<(), String> {
        self.write(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
    }

    pub fn close(&self) {
        let _ = self.shut.shutdown(std::net::Shutdown::Both);
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
#[path = "rpc_tests.rs"]
mod tests;
