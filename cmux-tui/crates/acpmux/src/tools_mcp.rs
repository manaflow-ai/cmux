//! `acpmux tools-mcp`: acpmux's own agent tool servers (`cmux-secrets`, `cmux-sessions`,
//! `cmux-subsessions`, `cmux-forum` and `acpmux`) in one stdio MCP process per chat, over one
//! daemon connection, instead of a process and a connection per call each (acpmux audit finding
//! 10: five processes per chat, about 4 MB and 5 threads each, so 330 MB and 400 threads at 18
//! live chats on Leo's Mac, 2026-11-11).
//!
//! `cmux mcp serve` starts it once for every upstream whose spec carries the same `shared`
//! launch (`agent_tools::AgentTools::folded`) and names, in each request's `_meta`
//! ([`SERVER_META`]), the server the request is for: `initialize` answers that server's name and
//! instructions, `tools/list` its tools, `tools/call` runs its tool. So each server's tools,
//! names, descriptions and rules are exactly what its own process gives. Each server's own
//! command (`secret-mcp`, ...) stays: a harness without the cmux server (cmux.json turns MCP off)
//! lists them by their own names, and a `cmux` older than this helper starts them one by one
//! (it does not read `shared`).
//!
//! The same loop ([`serve`]) runs each server's own process with one server in it, and the
//! bridge and guest servers (`acpmux_mcp_bridge.rs`, `acpmux_mcp_guest.rs`) through
//! `secret_mcp::serve_as`. The daemon's gateway (`mcp_gateway.rs`) answers with the same
//! [`answer`] for a chat over HTTP, its servers reading their env from `tool_env.rs`.

use crate::client::Client;
use crate::secret_mcp::error_result;
use anyhow::{Result, anyhow};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

/// Its acpmux command word.
pub const ARG: &str = "tools-mcp";

/// The `_meta` key of a request that names the server it is for (`cmux mcp serve`'s shared
/// upstreams). A process that serves one server needs none.
pub const SERVER_META: &str = "cmux/server";

/// The servers it serves, each with its own command word.
pub const SERVERS: [(&str, &str); 5] = [
    (crate::secret_mcp::SERVER_NAME, "secret-mcp"),
    (crate::offer_mcp::SERVER_NAME, "offer-mcp"),
    (crate::subsession_mcp::SERVER_NAME, "subsession-mcp"),
    (crate::forum_mcp::SERVER_NAME, "forum-mcp"),
    (crate::acpmux_mcp_names::SERVER_NAME, "acpmux-mcp"),
];

static MCP_CLIENT: std::sync::OnceLock<Value> = std::sync::OnceLock::new();

/// Keep the `clientInfo` of this MCP server's `initialize`: one client per server process
/// (moved from `sender_harness.rs`, which reads it as [`mcp_client`]).
pub fn note_mcp_client(params: &Value) {
    if let Some(info) = params.get("clientInfo").filter(|i| i.is_object()) {
        let _ = MCP_CLIENT.set(info.clone());
    }
}

/// The `clientInfo` [`note_mcp_client`] kept, if any.
pub fn mcp_client() -> Option<&'static Value> {
    MCP_CLIENT.get()
}

/// A server env key: `1` when the harness already has the server's instructions in its system
/// prompt (a Claude Code chat acpmux starts, `agent_tools::AgentTools::instructions_in_prompt`).
/// `initialize` then gives none, so the chat never reads them twice: Claude Code puts MCP
/// instructions after its last cached system block, so each new chat wrote them to the prompt
/// cache again, while the appended system prompt is the prefix every chat shares.
pub const INSTRUCTIONS_IN_PROMPT_ENV: &str = "ACPMUX_MCP_INSTRUCTIONS_IN_PROMPT";

/// The instructions server `name` of [`SERVERS`] gives at `initialize` with the env
/// [`crate::tool_env`] reads (the acpmux server's depend on its tool allowlist), whatever
/// [`INSTRUCTIONS_IN_PROMPT_ENV`] says. None for a server without any, or not one of these.
pub(crate) fn instructions_of(name: &str) -> Option<String> {
    match name {
        crate::offer_mcp::SERVER_NAME => Some(crate::offer_mcp::INSTRUCTIONS.to_owned()),
        crate::subsession_mcp::SERVER_NAME => Some(crate::subsession_mcp::instructions()),
        crate::acpmux_mcp_names::SERVER_NAME => crate::acpmux_mcp::env_instructions(),
        _ => None,
    }
}

/// Whether server `name` run as `args` is one of [`SERVERS`] as acpmux runs it: its own
/// command word last.
pub fn owns(name: &str, args: &[String]) -> bool {
    SERVERS.iter().any(|(n, word)| *n == name && args.last().is_some_and(|a| a == word))
}

pub(crate) type CallFuture = Pin<Box<dyn Future<Output = Value> + Send>>;
/// A server's `tools/call`: `call(session, params)`.
pub(crate) type Call = Arc<dyn Fn(String, Value) -> CallFuture + Send + Sync>;

/// One server a process answers for.
pub(crate) struct Served {
    pub name: &'static str,
    /// The session (or bridge address) its calls act for.
    pub session: String,
    pub tools: Value,
    /// The MCP `instructions` it gives at `initialize`.
    pub instructions: Option<String>,
    pub call: Call,
}

/// `call` as a [`Call`]. It is only ever called to make its future, under a lock, so it need
/// not be `Sync`.
pub(crate) fn boxed<F, Fut>(call: F) -> Call
where
    F: Fn(String, Value) -> Fut + Send + 'static,
    Fut: Future<Output = Value> + Send + 'static,
{
    let call = std::sync::Mutex::new(call);
    Arc::new(move |session, params| {
        let call = call.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let future = (*call)(session, params);
        drop(call);
        Box::pin(future)
    })
}

/// The daemon connection the calls of one process share: made by the first call that needs
/// it, and again by the next call once the daemon closed it, so a restarted daemon serves the
/// next call. The daemon runs each request of a connection on its own (64 at once,
/// `server/mod.rs` `REQUEST_WORK_LIMIT`), so a card that waits for the person holds no other
/// call.
#[derive(Default)]
pub(crate) struct Daemon {
    held: tokio::sync::Mutex<Option<Arc<Client>>>,
    /// The socket it dials; none: this process's daemon (`daemon::connect`).
    socket: Option<std::path::PathBuf>,
}

impl Daemon {
    /// The daemon at `socket`, dialed as is: the gateway's own (`mcp_gateway.rs`).
    pub(crate) fn at(socket: std::path::PathBuf) -> Self {
        Self { held: Default::default(), socket: Some(socket) }
    }

    /// The connection, made now if there is none. It names its caller by the session and
    /// caller token [`crate::tool_env`] reads where it is made.
    pub(crate) async fn client(&self) -> Result<Arc<Client>> {
        let mut held = self.held.lock().await;
        if let Some(client) = held.as_ref().filter(|client| !client.is_closed()) {
            return Ok(client.clone());
        }
        let client = match &self.socket {
            Some(socket) => Client::connect(socket).await?,
            None => crate::daemon::connect(false).await?,
        };
        *held = Some(client.clone());
        Ok(client)
    }

    /// Drops the connection when no call holds it, so an idle chat holds none.
    pub(crate) fn release(&self) {
        if let Ok(mut held) = self.held.try_lock()
            && held.as_ref().is_some_and(|client| Arc::strong_count(client) == 1)
        {
            *held = None;
        }
    }
}

/// The makers of [`SERVERS`], in its order.
pub(crate) const MAKERS: [fn(&Arc<Daemon>) -> Result<Served>; 5] = [
    crate::secret_mcp::served,
    crate::offer_mcp::served,
    crate::subsession_mcp::served,
    crate::forum_mcp::served,
    crate::acpmux_mcp::served,
];

/// Every server of [`SERVERS`] whose session the env ([`crate::tool_env`]) names, on `daemon`.
/// One it does not name (the secret tools without the card) is not asked for: `cmux mcp serve`
/// asks only for the servers acpmux gave it.
pub(crate) fn servers(daemon: &Arc<Daemon>) -> Vec<Served> {
    MAKERS
        .iter()
        .filter_map(|make| {
            make(daemon).map_err(|e| tracing::debug!("tools-mcp: a server is left out: {e:#}")).ok()
        })
        .collect()
}

/// Server `name` for the session in env `session_env`: `tools/call` is
/// `call(daemon, session, params)` on `daemon`'s connection.
pub(crate) fn served<F, Fut>(
    name: &'static str,
    session_env: &str,
    tools: Value,
    instructions: Option<String>,
    daemon: &Arc<Daemon>,
    call: F,
) -> Result<Served>
where
    F: Fn(Arc<Client>, String, Value) -> Fut + Clone + Send + 'static,
    Fut: Future<Output = Value> + Send + 'static,
{
    let session =
        crate::tool_env::var(session_env).ok_or_else(|| anyhow!("{session_env} is not set"))?;
    // Already in the harness's system prompt: said once ([`INSTRUCTIONS_IN_PROMPT_ENV`]).
    let instructions = instructions
        .filter(|_| crate::tool_env::var(INSTRUCTIONS_IN_PROMPT_ENV).as_deref() != Some("1"));
    let daemon = daemon.clone();
    let call = boxed(move |session, params| {
        let (daemon, call) = (daemon.clone(), call.clone());
        async move {
            match daemon.client().await {
                Ok(client) => call(client, session, params).await,
                Err(e) => error_result(format!("{e:#}")),
            }
        }
    });
    Ok(Served { name, session, tools, instructions, call })
}

/// The one server `served` makes, on stdin and stdout with a daemon connection of its own.
pub(crate) async fn serve_one(served: fn(&Arc<Daemon>) -> Result<Served>) -> Result<()> {
    serve(vec![served(&Arc::default())?]).await
}

/// The server a request with `params` is for, and the params without the [`SERVER_META`] it
/// named it by (a call's `_meta` then is what the client sent with it, `subagent_call.rs`).
fn pick<'a>(servers: &'a [Served], params: &mut Value) -> Result<&'a Served, String> {
    let named = params
        .get_mut("_meta")
        .and_then(Value::as_object_mut)
        .and_then(|meta| meta.remove(SERVER_META));
    if params.get("_meta").and_then(Value::as_object).is_some_and(|meta| meta.is_empty())
        && let Some(fields) = params.as_object_mut()
    {
        fields.remove("_meta");
    }
    let list = || servers.iter().map(|s| s.name).collect::<Vec<_>>().join(", ");
    match (named.as_ref().and_then(Value::as_str), servers) {
        (Some(name), _) => servers
            .iter()
            .find(|s| s.name == name)
            .ok_or_else(|| format!("this process serves no {name} (it serves {})", list())),
        (None, [only]) => Ok(only),
        (None, _) => Err(format!("name the server in _meta \"{SERVER_META}\": one of {}", list())),
    }
}

/// An MCP stdio server for `servers` on stdin and stdout, until the client closes stdin.
pub(crate) async fn serve(servers: Vec<Served>) -> Result<()> {
    // Stdin may stay open after the agent died (`parent_watch.rs`).
    crate::parent_watch::exit_with_parent();
    // The writer and the calls under way: cancelled when the client closes stdin.
    let tasks = cmux_scope::Scope::new("tools-mcp");
    let (tx, mut rx) = mpsc::channel::<Value>(64);
    tasks.spawn_until_cancelled("tools-mcp-writer", async move {
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
    let ended = loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break Ok(()),
            Err(e) => break Err(e.into()),
        };
        let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
        if message.get("id").is_some()
            && message.get("method").and_then(Value::as_str) == Some("initialize")
        {
            // One client per server process (the daemon's gateway notes none).
            note_mcp_client(message.get("params").unwrap_or(&Value::Null));
        }
        match answer(&servers, &message) {
            Answer::None => {}
            Answer::Now(reply) => {
                let _ = tx.send(reply).await;
            }
            Answer::Call(call) => {
                // A card waits on the person: the next request is read meanwhile.
                let tx = tx.clone();
                tasks.spawn_until_cancelled("tools-mcp-call", async move {
                    let _ = tx.send(call.await).await;
                });
            }
        }
    };
    // The agent closed the pipe: no one reads an answer still on its way, and
    // ending here drops the calls' daemon connection with it.
    drop(tx);
    // Every task stops at the cancellation (`spawn_until_cancelled`): none is left to report.
    let _ = tasks.close(std::time::Duration::ZERO).await;
    ended
}

/// What a message gets back from [`answer`].
pub(crate) enum Answer {
    /// Nothing: a notification.
    None,
    /// This JSON-RPC message.
    Now(Value),
    /// The JSON-RPC message this call ends in.
    Call(CallFuture),
}

/// The answer of `servers` to JSON-RPC `message`: `initialize` answers the server it names
/// ([`SERVER_META`]) with its name and instructions, `tools/list` its tools, `tools/call` runs its
/// tool for its session.
pub(crate) fn answer(servers: &[Served], message: &Value) -> Answer {
    let Some(id) = message.get("id").cloned() else { return Answer::None };
    let verb = message["method"].as_str().unwrap_or_default();
    let error = |code: i64, text: String| {
        Answer::Now(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": text}}))
    };
    if verb == "ping" {
        return Answer::Now(response(&id, json!({})));
    }
    if !matches!(verb, "initialize" | "tools/list" | "tools/call") {
        return error(-32601, format!("method not found: {verb}"));
    }
    let mut params = message.get("params").cloned().unwrap_or(Value::Null);
    let served = match pick(servers, &mut params) {
        Ok(served) => served,
        Err(text) => return error(-32602, text),
    };
    match verb {
        "initialize" => {
            let mut reply = json!({
                "protocolVersion": crate::secret_mcp::protocol_version(&params),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": served.name, "version": env!("CARGO_PKG_VERSION")},
            });
            if let Some(text) = &served.instructions {
                reply.set("instructions", json!(text));
            }
            Answer::Now(response(&id, reply))
        }
        "tools/list" => Answer::Now(response(&id, json!({"tools": served.tools}))),
        _ => {
            // An argument under another name than the schema's (`session` for `name`) is
            // read as the schema's, and the result says so (`mcp_args.rs`).
            let renamed = crate::mcp_args::normalize(&served.tools, &mut params);
            let call = (served.call)(served.session.clone(), params);
            Answer::Call(Box::pin(async move {
                let mut result = call.await;
                crate::mcp_args::tell(&mut result, &renamed);
                response(&id, result)
            }))
        }
    }
}

fn response(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

#[cfg(test)]
#[path = "tools_mcp_tests.rs"]
mod tests;
