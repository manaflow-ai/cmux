//! The agent's `request_secret` and `run_with_secret` tools (cx-ncc.42) for
//! one agent session that `agent_tools.rs` registers. Each call is one
//! daemon request (`hub/secrets.rs`) for the session; the value never passes
//! through here, only the ref. The daemon serves them itself, for the
//! session the caller token proves (`subsession_mcp::DaemonTools`); `acpmux
//! secret-mcp`, the stdio server for the session in [`SESSION_ENV`], stays
//! for a harness an earlier daemon started and for Windows.

use crate::client::Client;
use crate::no_panic::JsonExt;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::future::Future;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

pub const SERVER_NAME: &str = "cmux-secrets";
/// The session the tools ask for, set in this server's own env.
pub const SESSION_ENV: &str = "ACPMUX_SECRET_SESSION";

pub(crate) fn tools() -> Value {
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
        call(daemon.as_ref(), &session, &params).await
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
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = message.get("id").cloned() else { continue }; // a notification
        let verb = message.field("method").as_str().unwrap_or_default().to_owned();
        let reply = match verb.as_str() {
            "initialize" => {
                let mut reply = json!({
                    "protocolVersion": message.field("params").field("protocolVersion").as_str().unwrap_or("2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": name, "version": env!("CARGO_PKG_VERSION")},
                });
                if let Some(text) = &instructions {
                    reply.set("instructions", json!(text));
                }
                reply
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": tools}),
            "tools/call" => {
                // A card waits on the person: the next request is read meanwhile. Each call
                // connects anew, so a restarted daemon serves the next one.
                let (tx, session, params, call) =
                    (tx.clone(), session.clone(), message.field("params").clone(), call.clone());
                tokio::spawn(async move {
                    let result = match crate::daemon::connect(false).await {
                        Ok(daemon) => call(daemon, session, params).await,
                        Err(e) => error_result(format!("{e:#}")),
                    };
                    let _ = tx.send(response(&id, result)).await;
                });
                continue;
            }
            other => {
                let error =
                    json!({"code": -32601, "message": format!("method not found: {other}")});
                let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "error": error})).await;
                continue;
            }
        };
        let _ = tx.send(response(&id, reply)).await;
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

pub(crate) async fn call<D: crate::subsession_mcp::ToolRequests>(
    daemon: &D,
    session: &str,
    params: &Value,
) -> Value {
    let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let (m, mut request) = match params["name"].as_str() {
        Some("request_secret") => (
            method::MUX_SECRET_REQUEST,
            json!({
                "name": arguments.field("name"), "reason": arguments.field("reason"),
            }),
        ),
        Some("run_with_secret") => (
            method::MUX_SECRET_RUN,
            json!({
                "secretRef": arguments.field("secretRef"), "env": arguments.field("env"), "argv": arguments.field("argv"),
            }),
        ),
        other => return error_result(format!("unknown tool: {}", other.unwrap_or_default())),
    };
    request.set("sessionId", Value::String(session.to_owned()));
    match daemon.request(m, request).await {
        Ok(result) => {
            let text = if *result.field("outcome") == "cancelled" {
                "The card closed before the user answered (the turn stopped, or a newer ask replaced it).".to_owned()
            } else if *result.field("declined") == true {
                "The user declined to give this secret.".to_owned()
            } else {
                result.to_string()
            };
            json!({"content": [{"type": "text", "text": text}], "structuredContent": result, "isError": false})
        }
        Err(e) => error_result(format!("{e:#}")),
    }
}
