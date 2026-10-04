//! A blocking JSON-RPC 2.0 client over one newline-delimited Unix socket
//! connection: acpmux's wire. One reader thread hands responses to the
//! waiting caller and notifications to a callback, in arrival order.
//!
//! Deviation: the `acpmux` crate's own client is tokio-async and comes with
//! the TUI's dependency tree; this host is threads and blocking calls (like
//! cmux-sdk and optchat-host), so it speaks the same small wire directly and
//! reads it with cmux-chief's acpmux types.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

/// A server notification.
#[derive(Clone, Debug, PartialEq)]
pub struct Notification {
    pub method: String,
    pub params: Value,
}

/// Why a request failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RpcError {
    /// The server answered with an error object.
    Remote { code: Option<i64>, message: String },
    /// The connection is gone; nothing was or will be answered.
    Closed,
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::Remote { message, .. } => f.write_str(message),
            RpcError::Closed => f.write_str("connection closed"),
        }
    }
}

type Waiters = Arc<Mutex<Option<HashMap<u64, Sender<Result<Value, RpcError>>>>>>;

pub struct RpcClient {
    writer: Mutex<UnixStream>,
    waiters: Waiters,
    next_id: AtomicU64,
    closed: Arc<AtomicBool>,
}

impl RpcClient {
    /// Connects; `on_notification` runs on the reader thread for every
    /// notification, then once with method `""` when the connection ends.
    pub fn connect(
        path: &Path,
        on_notification: impl Fn(Notification) + Send + 'static,
    ) -> std::io::Result<Arc<RpcClient>> {
        let stream = UnixStream::connect(path)?;
        let reader = stream.try_clone()?;
        let waiters: Waiters = Arc::new(Mutex::new(Some(HashMap::new())));
        let closed = Arc::new(AtomicBool::new(false));
        let client = Arc::new(RpcClient {
            writer: Mutex::new(stream),
            waiters: waiters.clone(),
            next_id: AtomicU64::new(1),
            closed: closed.clone(),
        });
        std::thread::Builder::new()
            .name("rpc-reader".into())
            .spawn(move || {
                let mut lines = BufReader::new(reader);
                let mut line = String::new();
                loop {
                    line.clear();
                    match lines.read_line(&mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    let Ok(message) = serde_json::from_str::<Value>(line.trim()) else {
                        continue;
                    };
                    dispatch(&waiters, &on_notification, message);
                }
                closed.store(true, Ordering::SeqCst);
                // Taking the map refuses later registrations and fails the waiting ones.
                if let Some(pending) = waiters.lock().expect("waiters").take() {
                    for (_, tx) in pending {
                        let _ = tx.send(Err(RpcError::Closed));
                    }
                }
                on_notification(Notification {
                    method: String::new(),
                    params: Value::Null,
                });
            })?;
        Ok(client)
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Ends the connection; waiting calls fail with `Closed`.
    pub fn close(&self) {
        let _ = self
            .writer
            .lock()
            .expect("writer")
            .shutdown(std::net::Shutdown::Both);
    }

    /// Sends a request; the receiver gets its one answer.
    pub fn start(&self, method: &str, params: Value) -> Receiver<Result<Value, RpcError>> {
        let (tx, rx) = channel();
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        {
            let mut waiters = self.waiters.lock().expect("waiters");
            let Some(map) = waiters.as_mut() else {
                let _ = tx.send(Err(RpcError::Closed));
                return rx;
            };
            map.insert(id, tx.clone());
        }
        let line = format!(
            "{}\n",
            json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        );
        let sent = self
            .writer
            .lock()
            .expect("writer")
            .write_all(line.as_bytes());
        if sent.is_err()
            && let Some(map) = self.waiters.lock().expect("waiters").as_mut()
            && let Some(tx) = map.remove(&id)
        {
            let _ = tx.send(Err(RpcError::Closed));
        }
        rx
    }

    /// Sends a request and waits for its answer.
    pub fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        self.start(method, params)
            .recv()
            .unwrap_or(Err(RpcError::Closed))
    }
}

fn dispatch(waiters: &Waiters, on_notification: &impl Fn(Notification), message: Value) {
    let id = message.get("id").and_then(Value::as_u64);
    let is_response = message.get("result").is_some() || message.get("error").is_some();
    if let (Some(id), true) = (id, is_response) {
        let tx = waiters
            .lock()
            .expect("waiters")
            .as_mut()
            .and_then(|m| m.remove(&id));
        if let Some(tx) = tx {
            let answer = match message.get("error").filter(|e| !e.is_null()) {
                Some(error) => Err(RpcError::Remote {
                    code: error.get("code").and_then(Value::as_i64),
                    message: error
                        .get("message")
                        .and_then(Value::as_str)
                        .map_or_else(|| error.to_string(), str::to_owned),
                }),
                None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
            };
            let _ = tx.send(answer);
        }
        return;
    }
    if let Some(method) = message.get("method").and_then(Value::as_str) {
        on_notification(Notification {
            method: method.to_owned(),
            params: message.get("params").cloned().unwrap_or(Value::Null),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    #[test]
    fn requests_and_notifications_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.sock");
        let listener = UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut out = stream.try_clone().unwrap();
            for line in BufReader::new(stream).lines() {
                let req: Value = serde_json::from_str(&line.unwrap()).unwrap();
                let id = req["id"].clone();
                writeln!(
                    out,
                    "{}",
                    json!({"jsonrpc": "2.0", "method": "note", "params": {"n": 1}})
                )
                .unwrap();
                if req["method"] == "fail" {
                    writeln!(
                        out,
                        "{}",
                        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -1, "message": "no"}})
                    )
                    .unwrap();
                } else {
                    writeln!(
                        out,
                        "{}",
                        json!({"jsonrpc": "2.0", "id": id, "result": {"echo": req["params"]}})
                    )
                    .unwrap();
                }
            }
        });
        let (ntx, nrx) = channel();
        let client = RpcClient::connect(&path, move |n| {
            let _ = ntx.send(n.method);
        })
        .unwrap();
        assert_eq!(client.request("x", json!(5)).unwrap(), json!({"echo": 5}));
        assert_eq!(
            nrx.recv().unwrap(),
            "note",
            "the notification before the answer came first"
        );
        assert_eq!(
            client.request("fail", json!({})),
            Err(RpcError::Remote {
                code: Some(-1),
                message: "no".into()
            })
        );
        client.close();
        while let Ok(method) = nrx.recv() {
            if method.is_empty() {
                break;
            }
        }
        assert_eq!(client.request("x", json!(1)), Err(RpcError::Closed));
    }
}
