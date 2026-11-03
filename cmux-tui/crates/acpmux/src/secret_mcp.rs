//! `acpmux secret-mcp`: the agent's `request_secret` and `run_with_secret`
//! tools (cx-ncc.42) and `connect_mcp_server` (`hub/mcp_connect.rs`): every
//! tool here waits on a card only the person answers, an MCP stdio server for one agent session that
//! `agent_tools.rs` registers. Each call is one daemon request
//! (`hub/secrets.rs`) for the session in [`SESSION_ENV`]; the value never
//! passes through here, only the ref.

use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::future::Future;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

pub const SERVER_NAME: &str = "cmux-secrets";
/// The session the tools ask for, set in this server's own env.
pub const SESSION_ENV: &str = "ACPMUX_SECRET_SESSION";
/// The newest MCP protocol version our stdio servers speak.
pub const NEWEST_PROTOCOL_VERSION: &str = "2025-06-18";
/// The MCP protocol versions our stdio servers speak, newest first.
pub const PROTOCOL_VERSIONS: &[&str] = &[NEWEST_PROTOCOL_VERSION, "2025-03-26", "2024-11-05"];

/// The version an MCP `initialize` answers: the client's when we speak it,
/// else our newest (the client then decides whether to go on).
pub fn protocol_version(params: &Value) -> &'static str {
    let requested = params["protocolVersion"].as_str();
    PROTOCOL_VERSIONS
        .iter()
        .copied()
        .find(|v| Some(*v) == requested)
        .unwrap_or(NEWEST_PROTOCOL_VERSION)
}

/// Lists `connect_mcp_server` only with this set to `1`: until the daemon runs an approved
/// server (plans/cmux-next/mcp-connect-DESIGN.md step 2b), an approval connects nothing, so agents
/// do not see the tool by default.
pub const MCP_CONNECT_PREVIEW_ENV: &str = "CMUX_MCP_CONNECT_PREVIEW";

/// `value[key]` without an index: `Null` for a missing key or a value that is not an object.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

fn tools() -> Value {
    let mut all = all_tools();
    if std::env::var(MCP_CONNECT_PREVIEW_ENV).as_deref() != Ok("1")
        && let Some(list) = all.as_array_mut()
    {
        list.retain(|t| *field(t, "name") != "connect_mcp_server");
    }
    all
}

fn all_tools() -> Value {
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
        },
        {
            "name": "connect_mcp_server",
            "description": "Ask the user to connect an MCP server (a known service such as linear, github, sentry or notion; an https:// URL; or a local command such as `npx -y @scope/server`). cmux checks it, then shows the user a card in this chat with the exact server, its publisher and the access it asks for; only the user can approve it, and they pick who gets it. You never see a token or key. The call waits until the user answers (15 minutes at most, or until your turn ends). Returns status approved (with the scope the user chose), declined, cancelled, or unknown (with near names to suggest). An address that is unsafe (a private network, http:// to another machine, a user name before the host) or a shell line is refused with the reason. Use it only when the user asked for the server.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "server": {"type": "string", "description": "What the user named: a service name, an https URL, or a command line."},
                    "scope": {"type": "string", "enum": ["chat", "chief", "allChiefs", "agents", "everywhere"], "description": "Your proposal of who gets it; the user decides. Default chat."},
                    "reason": {"type": "string", "description": "One sentence the card shows: what you will use it for."}
                },
                "required": ["server", "reason"]
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
    // Stdin may stay open after the agent died (`parent_watch.rs`).
    crate::parent_watch::exit_with_parent();
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
        let verb = message["method"].as_str().unwrap_or_default().to_owned();
        let reply = match verb.as_str() {
            "initialize" => {
                let mut reply = json!({
                    "protocolVersion": protocol_version(&message["params"]),
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
                    (tx.clone(), session.clone(), message["params"].clone(), call.clone());
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

async fn call(daemon: &Client, session: &str, params: &Value) -> Value {
    let arguments = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
    let (m, mut request) = match params["name"].as_str() {
        Some("request_secret") => (
            method::MUX_SECRET_REQUEST,
            json!({
                "name": arguments["name"], "reason": arguments["reason"],
            }),
        ),
        Some("connect_mcp_server")
            if std::env::var(MCP_CONNECT_PREVIEW_ENV).as_deref() != Ok("1") =>
        {
            return error_result(
                "connect_mcp_server is not on yet: cmux cannot run an approved MCP server until its \
                 sign-in and proxy land. Tell the user to add the server to the harness themselves."
                    .to_owned(),
            );
        }
        Some("connect_mcp_server") => (
            method::MUX_MCP_CONNECT_REQUEST,
            json!({
                "server": field(&arguments, "server"), "scope": field(&arguments, "scope"),
                "reason": field(&arguments, "reason"),
            }),
        ),
        Some("run_with_secret") => (
            method::MUX_SECRET_RUN,
            json!({
                "secretRef": arguments["secretRef"], "env": arguments["env"], "argv": arguments["argv"],
            }),
        ),
        other => {
            let name = other.unwrap_or_default();
            return error_result(crate::mcp_hint::unknown_tool(
                name,
                crate::mcp_hint::names(&tools()),
            ));
        }
    };
    request.set("sessionId", Value::String(session.to_owned()));
    match daemon.request(m, request).await {
        Ok(result) => {
            let text = if result["outcome"] == "cancelled" {
                "The card closed before the user answered (the turn stopped, or a newer ask replaced it).".to_owned()
            } else if *field(&result, "status") == "cancelled" {
                "The connect card closed before the user answered (the turn stopped, or a newer ask replaced it).".to_owned()
            } else if *field(&result, "status") == "declined" {
                "The user declined to connect this server.".to_owned()
            } else if result["declined"] == true {
                "The user declined to give this secret.".to_owned()
            } else if *field(&result, "connect") == "signInNeeded" {
                format!(
                    "The user approved {} (scope {}). The server needs a sign-in before it lists tools: \
                     ask the user to sign in on the card. The sign-in happens on the user's side; no \
                     token or code comes to you, so never ask for one.",
                    field(&result, "name").as_str().unwrap_or("the server"),
                    field(&result, "scope").as_str().unwrap_or("chat"),
                )
            } else if *field(&result, "connect") == "connected" {
                let prefix = field(&result, "toolPrefix").as_str().unwrap_or("server");
                let count = field(&result, "tools").as_array().map_or(0, Vec::len);
                format!(
                    "Connected {} (scope {}). Its {count} tools are yours now as {prefix}__<tool> on \
                     the cmux-mcp server (refresh your tool list if you do not see them). cmux makes \
                     each call with the user's sign-in; a tool that writes waits for the user's OK. \
                     Tools: {}",
                    field(&result, "name").as_str().unwrap_or("the server"),
                    field(&result, "scope").as_str().unwrap_or("chat"),
                    field(&result, "tools")
                        .as_array()
                        .map(|t| t
                            .iter()
                            .map(|x| format!(
                                "{prefix}__{} ({})",
                                field(x, "name").as_str().unwrap_or(""),
                                field(x, "policy").as_str().unwrap_or("ask")
                            ))
                            .collect::<Vec<_>>()
                            .join(", "))
                        .unwrap_or_default(),
                )
            } else if *field(&result, "connect") == "keyNeeded" {
                format!(
                    "The user approved {}. It needs a key, which the user types only into the card's \
                     secure field; never ask for it in the chat.",
                    field(&result, "name").as_str().unwrap_or("the server"),
                )
            } else {
                result.to_string()
            };
            json!({"content": [{"type": "text", "text": text}], "structuredContent": result, "isError": false})
        }
        Err(e) => error_result(format!("{e:#}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_answers_a_version_we_speak() {
        let version = |v: Value| protocol_version(&json!({"protocolVersion": v}));
        assert_eq!(version(json!("2024-11-05")), "2024-11-05");
        assert_eq!(version(json!("2099-01-01")), PROTOCOL_VERSIONS[0]);
        assert_eq!(version(json!(7)), PROTOCOL_VERSIONS[0]);
        assert_eq!(protocol_version(&Value::Null), PROTOCOL_VERSIONS[0]);
    }
}
