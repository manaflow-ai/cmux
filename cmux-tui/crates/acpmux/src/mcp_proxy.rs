//! `acpmux mcp-proxy`: the agent's one MCP server for the MCP servers the person connected
//! through cmux (plans/cmux-next/mcp-connect-DESIGN.md section 6). `agent_tools.rs` registers it
//! for every chat that gets the card tools.
//!
//! It holds no key, token or server address: each request goes to the daemon on this machine's
//! socket, proven as its chat by the caller token in its env (`hub/person.rs` (a)), and the
//! daemon calls the server (`hub/mcp_calls.rs`).
//!
//! - `tools/list`: the chat's approved tools, named `<server>__<tool>`.
//! - `tools/call`: the daemon checks the scope, the pin and the policy (an `ask` tool waits on
//!   the person's card), adds the key or token, and answers the server's result.
//! - When the person connects, removes or changes a server, the daemon's version moves and this
//!   server sends `notifications/tools/list_changed`, so the agent's list changes in the same chat.

use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

pub const SERVER_NAME: &str = "cmux-mcp";
/// The chat the proxy serves, set in its own env.
pub const SESSION_ENV: &str = "ACPMUX_MCP_SESSION";
/// The first wait after a failed watch; doubled up to [`RETRY_MAX`].
const RETRY_FIRST: Duration = Duration::from_secs(1);
const RETRY_MAX: Duration = Duration::from_secs(30);

const INSTRUCTIONS: &str = "Tools of the MCP servers the user connected through cmux, named \
<server>__<tool>. cmux makes each call for you with the user's sign-in; you never see a key or \
token. A tool that writes may wait for the user's OK on a card. To add a server, use \
connect_mcp_server.";

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    let session = std::env::var(SESSION_ENV).map_err(|_| anyhow!("{SESSION_ENV} is not set"))?;
    let (tx, mut rx) = mpsc::channel::<Value>(64);
    let writer = tokio::spawn(async move {
        let mut out = tokio::io::stdout();
        while let Some(message) = rx.recv().await {
            let mut line = message.to_string();
            line.push('\n');
            if out.write_all(line.as_bytes()).await.is_err() || out.flush().await.is_err() {
                break;
            }
        }
    });
    // The version the agent's list was last read at; the watcher tells it of a newer one.
    let seen = Arc::new(AtomicU64::new(0));
    let listed = Arc::new(AtomicBool::new(false));
    let watcher = tokio::spawn(watch(session.clone(), seen.clone(), listed.clone(), tx.clone()));
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = message.get("id").cloned() else { continue }; // a notification
        let verb = message["method"].as_str().unwrap_or_default().to_owned();
        match verb.as_str() {
            "initialize" => {
                let reply = json!({
                    "protocolVersion": crate::secret_mcp::protocol_version(&message["params"]),
                    "capabilities": {"tools": {"listChanged": true}},
                    "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
                    "instructions": INSTRUCTIONS,
                });
                let _ = tx.send(response(&id, reply)).await;
            }
            "ping" => {
                let _ = tx.send(response(&id, json!({}))).await;
            }
            "tools/list" => {
                let (tx, session, seen, listed) =
                    (tx.clone(), session.clone(), seen.clone(), listed.clone());
                tokio::spawn(async move {
                    let reply = match list(&session).await {
                        Ok((version, tools)) => {
                            seen.store(version, Ordering::SeqCst);
                            listed.store(true, Ordering::SeqCst);
                            json!({"tools": tools})
                        }
                        // No daemon: no tools now; the watcher says when there are.
                        Err(_) => json!({"tools": []}),
                    };
                    let _ = tx.send(response(&id, reply)).await;
                });
            }
            "tools/call" => {
                let (tx, session, params) =
                    (tx.clone(), session.clone(), message["params"].clone());
                tokio::spawn(async move {
                    let result = call(&session, &params).await;
                    let _ = tx.send(response(&id, result)).await;
                });
            }
            other => {
                let error =
                    json!({"code": -32601, "message": format!("method not found: {other}")});
                let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "error": error})).await;
            }
        }
    }
    drop(tx);
    watcher.abort();
    writer.abort();
    Ok(())
}

fn response(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

async fn list(session: &str) -> Result<(u64, Value)> {
    let daemon = crate::daemon::connect(false).await?;
    let r = daemon.request(method::MUX_MCP_TOOLS, json!({"sessionId": session})).await?;
    Ok((r["version"].as_u64().unwrap_or(0), r["tools"].clone()))
}

async fn call(session: &str, params: &Value) -> Value {
    let name = params["name"].as_str().unwrap_or_default();
    let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let daemon = match crate::daemon::connect(false).await {
        Ok(d) => d,
        Err(e) => return crate::secret_mcp::error_result(format!("{e:#}")),
    };
    match daemon
        .request(
            method::MUX_MCP_CALL,
            json!({"sessionId": session, "name": name, "arguments": arguments}),
        )
        .await
    {
        Ok(result) => result,
        Err(e) => crate::secret_mcp::error_result(format!("{e:#}")),
    }
}

/// Holds `_acpmux/mcp_watch` on the daemon; when its version passes the one the agent's list
/// was read at, sends `notifications/tools/list_changed` (once the agent has listed).
async fn watch(
    session: String,
    seen: Arc<AtomicU64>,
    listed: Arc<AtomicBool>,
    tx: mpsc::Sender<Value>,
) {
    let mut retry = RETRY_FIRST;
    loop {
        let known = seen.load(Ordering::SeqCst);
        let answer = async {
            let daemon = crate::daemon::connect(false).await?;
            daemon
                .request(method::MUX_MCP_WATCH, json!({"sessionId": session, "version": known}))
                .await
        }
        .await;
        match answer {
            Ok(r) => {
                retry = RETRY_FIRST;
                let version = r["version"].as_u64().unwrap_or(known);
                if version != known && listed.load(Ordering::SeqCst) {
                    // The agent lists again and stores the new version; until then, wait on it.
                    seen.store(version, Ordering::SeqCst);
                    let note =
                        json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"});
                    if tx.send(note).await.is_err() {
                        return;
                    }
                } else if version != known {
                    seen.store(version, Ordering::SeqCst);
                }
            }
            Err(_) => {
                // A bounded backoff while the daemon restarts: the intended delay, not a poll of
                // state (the watch itself is the signal).
                tokio::time::sleep(retry).await;
                retry = (retry * 2).min(RETRY_MAX);
            }
        }
    }
}
