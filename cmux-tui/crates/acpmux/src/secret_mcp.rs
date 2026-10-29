//! `acpmux secret-mcp`: the agent's `request_secret` and `run_with_secret`
//! tools (cx-ncc.42), an MCP stdio server for one agent session that
//! `agent_tools.rs` registers. Each call is one daemon request
//! (`hub/secrets.rs`) for the session in [`SESSION_ENV`]; the value never
//! passes through here, only the ref.

use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::future::Future;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{Semaphore, mpsc};

pub const SERVER_NAME: &str = "cmux-secrets";
/// The session the tools ask for, set in this server's own env.
pub const SESSION_ENV: &str = "ACPMUX_SECRET_SESSION";
/// The largest number of tool calls whose daemon reply and output may be retained at once.
/// Keeping this small matters because `ls` returns every session summary.
const MAX_IN_FLIGHT_CALLS: usize = 8;
/// The output writer's bounded backlog. Calls hold a permit until their serialized reply is
/// accepted here, so this queue and the in-flight calls are one memory bound.
const OUTPUT_QUEUE_CAPACITY: usize = 8;

fn tools() -> Value {
    json!([
        {
            "name": "request_secret",
            "description": "Ask the user for a secret (an API key, a token, a password) on a private card in cmux. The user types it there; you never see the value. The call waits until the user fills or declines the card (it closes after 15 minutes, or with your turn); inside a cmux_exec script it waits at most 10 minutes, so call it in a script of its own. Returns a one-use secretRef for this chat's folder, good for an hour: pass it to run_with_secret to run one command with the secret in an environment variable. Never ask for a secret in chat.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "The environment variable the secret goes in, e.g. STRIPE_API_KEY."},
                    "reason": {"type": "string", "description": "One sentence the card shows: what you will use it for."}
                },
                "required": ["name", "reason"]
            }
        },
        {
            "name": "run_with_secret",
            "description": "Run one command in this chat's folder with a secret from request_secret in an environment variable. It runs without your environment (only basics such as HOME, PATH and the locale, plus your login shell's variables), with no stdin, for at most 2 minutes (then it is killed and timedOut is true), and returns exitCode, stdout and stderr (about 64 KiB each at most) with the secret's value masked. The secretRef is spent once the command starts; one that could not start stays usable.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "secretRef": {"type": "string"},
                    "env": {"type": "string", "description": "The environment variable to set, e.g. STRIPE_API_KEY."},
                    "argv": {"type": "array", "items": {"type": "string"}, "description": "The command and its arguments, e.g. [\"sh\", \"-c\", \"curl -u \\\"$STRIPE_API_KEY:\\\" https://api.stripe.com/v1/balance\"]."}
                },
                "required": ["secretRef", "env", "argv"]
            }
        }
    ])
}

/// Runs the server on stdin and stdout.
pub async fn run() -> Result<()> {
    serve(SERVER_NAME, SESSION_ENV, tools(), None, |daemon, session, params| async move {
        call(&daemon, &session, &params).await
    })
    .await
}

/// An MCP stdio server for one agent session (the one in `session_env`):
/// `tools/call` is `call(daemon, session, params)` on a new daemon
/// connection, and `instructions` the MCP `instructions` it gives at
/// `initialize`. `offer_mcp.rs` and `subsession_mcp.rs` serve theirs with it too.
pub(crate) async fn serve<F, Fut>(
    name: &'static str,
    session_env: &str,
    tools: Value,
    instructions: Option<String>,
    call: F,
) -> Result<()>
where
    F: Fn(Arc<Client>, String, Value) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = Value> + Send + 'static,
{
    let session = std::env::var(session_env).map_err(|_| anyhow!("{session_env} is not set"))?;
    let call = call.clone();
    serve_io(tokio::io::stdin(), tokio::io::stdout(), name, tools, instructions, move |params| {
        let session = session.clone();
        let call = call.clone();
        async move {
            match crate::daemon::connect(false).await {
                Ok(daemon) => call(daemon, session, params).await,
                Err(e) => error_result(format!("{e:#}")),
            }
        }
    })
    .await
}

async fn serve_io<R, W, E, Fut>(
    reader: R,
    mut writer: W,
    name: &'static str,
    tools: Value,
    instructions: Option<String>,
    execute: E,
) -> Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
    E: Fn(Value) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = Value> + Send + 'static,
{
    let (tx, mut rx) = mpsc::channel::<String>(OUTPUT_QUEUE_CAPACITY);
    let permits = Arc::new(Semaphore::new(MAX_IN_FLIGHT_CALLS));
    let writer = tokio::spawn(async move {
        while let Some(mut line) = rx.recv().await {
            line.push('\n');
            if writer.write_all(line.as_bytes()).await.is_err() || writer.flush().await.is_err() {
                break;
            }
        }
    });
    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = message.get("id").cloned() else { continue }; // a notification
        let verb = message["method"].as_str().unwrap_or_default().to_owned();
        let reply = match verb.as_str() {
            "initialize" => {
                let mut reply = json!({
                    "protocolVersion": message["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": name, "version": env!("CARGO_PKG_VERSION")},
                });
                if let Some(text) = &instructions {
                    reply["instructions"] = json!(text);
                }
                reply
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": tools}),
            "tools/call" => {
                // A card waits on the person: the next request is read meanwhile. Each call
                // connects anew, so a restarted daemon serves the next one.
                let Ok(permit) = permits.clone().acquire_owned().await else { break };
                let (tx, params, execute) =
                    (tx.clone(), message["params"].clone(), execute.clone());
                tokio::spawn(async move {
                    let _permit = permit;
                    let _ = tx.send(response(&id, execute(params).await).to_string()).await;
                });
                continue;
            }
            other => {
                let error =
                    json!({"code": -32601, "message": format!("method not found: {other}")});
                let _ =
                    tx.send(json!({"jsonrpc": "2.0", "id": id, "error": error}).to_string()).await;
                continue;
            }
        };
        let _ = tx.send(response(&id, reply).to_string()).await;
    }
    // The agent closed the pipe: no one reads an answer still on its way, and
    // ending here drops the calls' daemon connections with it.
    drop(tx);
    writer.abort();
    Ok(())
}

fn response(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

pub(crate) fn error_result(text: String) -> Value {
    json!({"content": [{"type": "text", "text": text}], "isError": true})
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;
    use tokio::sync::{Barrier, Notify};

    #[tokio::test]
    async fn tools_calls_bound_concurrent_large_replies() {
        const CALLS: usize = 500;
        const MAX_CONCURRENT: usize = MAX_IN_FLIGHT_CALLS;
        let rows: Vec<Value> = (0..3000)
            .map(|i| json!({"sessionId": format!("session-{i}"), "status": "idle"}))
            .collect();
        let maximum = Arc::new(AtomicUsize::new(0));
        let overflow = Arc::new(AtomicBool::new(false));
        let overflow_seen = Arc::new(Notify::new());
        let first = Arc::new(Barrier::new(MAX_CONCURRENT + 1));
        let release = Arc::new(Notify::new());
        let (client, server) = tokio::io::duplex(64 * 1024);
        let (_client_read, mut client_write) = tokio::io::split(client);
        let (server_read, server_write) = tokio::io::split(server);
        let call_maximum = maximum.clone();
        let call_overflow = overflow.clone();
        let call_overflow_seen = overflow_seen.clone();
        let call_first = first.clone();
        let call_release = release.clone();
        let call_rows = rows.clone();
        let server = tokio::spawn(serve_io(
            server_read,
            server_write,
            "acpmux",
            json!([]),
            None,
            move |_params| {
                let maximum = call_maximum.clone();
                let overflow = call_overflow.clone();
                let overflow_seen = call_overflow_seen.clone();
                let first = call_first.clone();
                let release = call_release.clone();
                let rows = call_rows.clone();
                async move {
                    let now = maximum.fetch_add(1, Ordering::SeqCst) + 1;
                    if now > MAX_CONCURRENT {
                        overflow.store(true, Ordering::SeqCst);
                        overflow_seen.notify_waiters();
                    }
                    if now <= MAX_CONCURRENT {
                        first.wait().await;
                    }
                    release.notified().await;
                    maximum.fetch_sub(1, Ordering::SeqCst);
                    json!({"sessions": rows})
                }
            },
        ));
        let requests = tokio::spawn(async move {
            for id in 0..CALLS {
                let request = json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": "tools/call",
                    "params": {"name": "ls", "arguments": {}}
                });
                client_write.write_all(request.to_string().as_bytes()).await.unwrap();
                client_write.write_all(b"\n").await.unwrap();
            }
        });
        tokio::time::timeout(Duration::from_secs(5), first.wait()).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(100), overflow_seen.notified())
                .await
                .is_err(),
            "more than {MAX_CONCURRENT} large MCP replies were retained concurrently"
        );
        assert!(!overflow.load(Ordering::SeqCst));
        release.notify_waiters();
        requests.abort();
        server.abort();
    }
}

async fn call(daemon: &Client, session: &str, params: &Value) -> Value {
    let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let (m, mut request) = match params["name"].as_str() {
        Some("request_secret") => (
            method::MUX_SECRET_REQUEST,
            json!({
                "name": arguments["name"], "reason": arguments["reason"],
            }),
        ),
        Some("run_with_secret") => (
            method::MUX_SECRET_RUN,
            json!({
                "secretRef": arguments["secretRef"], "env": arguments["env"], "argv": arguments["argv"],
            }),
        ),
        other => return error_result(format!("unknown tool: {}", other.unwrap_or_default())),
    };
    request["sessionId"] = Value::String(session.to_owned());
    match daemon.request(m, request).await {
        Ok(result) => {
            let text = if result["outcome"] == "cancelled" {
                "The card closed before the user answered (the turn stopped, or a newer ask replaced it).".to_owned()
            } else if result["declined"] == true {
                "The user declined to give this secret.".to_owned()
            } else {
                result.to_string()
            };
            json!({"content": [{"type": "text", "text": text}], "structuredContent": result, "isError": false})
        }
        Err(e) => error_result(format!("{e:#}")),
    }
}
