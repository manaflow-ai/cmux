//! Minimal JSON-RPC client for the local acpmux daemon (newline-delimited over its Unix socket).

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

type Reply = std::result::Result<Value, String>;

pub struct Acpmux {
    out: mpsc::UnboundedSender<String>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<i64, oneshot::Sender<Reply>>>>,
}

pub fn socket_path() -> PathBuf {
    if let Ok(path) = std::env::var("ACPMUX_SOCKET") {
        return PathBuf::from(path);
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".acpmux/acpmux.sock")
}

impl Acpmux {
    /// Connects and initializes. Notifications (requests without a reply id) go to `notifications`;
    /// the channel closes when the daemon connection ends.
    pub async fn connect(path: &Path, notifications: mpsc::UnboundedSender<Value>) -> Result<Arc<Self>> {
        let stream = UnixStream::connect(path).await.with_context(|| format!("connect {}", path.display()))?;
        let (read, mut write) = stream.into_split();
        let (out, mut out_rx) = mpsc::unbounded_channel::<String>();
        let pending: Arc<Mutex<HashMap<i64, oneshot::Sender<Reply>>>> = Arc::default();

        tokio::spawn(async move {
            while let Some(line) = out_rx.recv().await {
                if write.write_all(line.as_bytes()).await.is_err() || write.write_all(b"\n").await.is_err() {
                    break;
                }
            }
        });

        let readers_pending = pending.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(read).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                let id = message.get("id").and_then(Value::as_i64);
                let is_reply = message.get("result").is_some() || message.get("error").is_some();
                match (id, is_reply) {
                    (Some(id), true) => {
                        let sender = readers_pending.lock().unwrap().remove(&id);
                        if let Some(sender) = sender {
                            let reply = match message.get("error") {
                                Some(error) => Err(error
                                    .get("message")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned)
                                    .unwrap_or_else(|| error.to_string())),
                                None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                            };
                            let _ = sender.send(reply);
                        }
                    }
                    _ if message.get("method").is_some() => {
                        let _ = notifications.send(message);
                    }
                    _ => {}
                }
            }
            // Fail everything still waiting; dropping the senders does that.
            readers_pending.lock().unwrap().clear();
        });

        let client = Arc::new(Self { out, next_id: AtomicI64::new(1), pending });
        client
            .request(
                "initialize",
                json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "mux-link", "version": env!("CARGO_PKG_VERSION")}}),
            )
            .await?;
        Ok(client)
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string();
        if self.out.send(line).is_err() {
            self.pending.lock().unwrap().remove(&id);
            bail!("acpmux connection closed");
        }
        match rx.await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(message)) => Err(anyhow!("{method}: {message}")),
            Err(_) => Err(anyhow!("acpmux connection closed during {method}")),
        }
    }

    pub fn notify(&self, method: &str, params: Value) -> Result<()> {
        let line = json!({"jsonrpc": "2.0", "method": method, "params": params}).to_string();
        self.out.send(line).map_err(|_| anyhow!("acpmux connection closed"))
    }
}

/// The last reply of a session, through the acpmux CLI (which assembles it from the event log).
pub async fn last_reply(session: &str) -> Result<String> {
    let output = tokio::process::Command::new("acpmux")
        .args(["--json", "last", session])
        .output()
        .await
        .context("run acpmux last")?;
    if !output.status.success() {
        bail!("acpmux last {session}: {}", String::from_utf8_lossy(&output.stderr).trim());
    }
    let value: Value = serde_json::from_slice(&output.stdout)?;
    Ok(value
        .get("replies")
        .and_then(Value::as_array)
        .and_then(|replies| replies.last())
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned())
}
