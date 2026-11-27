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
//! `secret_mcp::serve_as`.

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
    (crate::acpmux_mcp::SERVER_NAME, "acpmux-mcp"),
];

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
pub(crate) struct Daemon(tokio::sync::Mutex<Option<Arc<Client>>>);

impl Daemon {
    pub(crate) async fn client(&self) -> Result<Arc<Client>> {
        let mut held = self.0.lock().await;
        if let Some(client) = held.as_ref().filter(|client| !client.is_closed()) {
            return Ok(client.clone());
        }
        let client = crate::daemon::connect(false).await?;
        *held = Some(client.clone());
        Ok(client)
    }
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
    let session = std::env::var(session_env).map_err(|_| anyhow!("{session_env} is not set"))?;
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

/// Runs every server of [`SERVERS`] whose session this process's env names, over one daemon
/// connection.
pub async fn run() -> Result<()> {
    let daemon = Arc::<Daemon>::default();
    let makers: [fn(&Arc<Daemon>) -> Result<Served>; 5] = [
        crate::secret_mcp::served,
        crate::offer_mcp::served,
        crate::subsession_mcp::served,
        crate::forum_mcp::served,
        crate::acpmux_mcp::served,
    ];
    let mut servers = Vec::new();
    for make in makers {
        // A server whose session the env does not name (the secret tools without the card)
        // is not asked for: `cmux mcp serve` asks only for the servers acpmux gave it.
        match make(&daemon) {
            Ok(served) => servers.push(served),
            Err(e) => tracing::debug!("tools-mcp: a server is left out: {e:#}"),
        }
    }
    if servers.is_empty() {
        return Err(anyhow!("tools-mcp: the env names no session for any server"));
    }
    serve(servers).await
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
        let Some(id) = message.get("id").cloned() else { continue }; // a notification
        let verb = message["method"].as_str().unwrap_or_default().to_owned();
        if verb == "ping" {
            let _ = tx.send(response(&id, json!({}))).await;
            continue;
        }
        if !matches!(verb.as_str(), "initialize" | "tools/list" | "tools/call") {
            let error = json!({"code": -32601, "message": format!("method not found: {verb}")});
            let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "error": error})).await;
            continue;
        }
        let mut params = message.get("params").cloned().unwrap_or(Value::Null);
        let served = match pick(&servers, &mut params) {
            Ok(served) => served,
            Err(message) => {
                let error = json!({"code": -32602, "message": message});
                let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "error": error})).await;
                continue;
            }
        };
        let reply = match verb.as_str() {
            "initialize" => {
                crate::sender_harness::note_mcp_client(&params);
                let mut reply = json!({
                    "protocolVersion": crate::secret_mcp::protocol_version(&params),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": served.name, "version": env!("CARGO_PKG_VERSION")},
                });
                if let Some(text) = &served.instructions {
                    reply.set("instructions", json!(text));
                }
                reply
            }
            "tools/list" => json!({"tools": served.tools}),
            _ => {
                // A card waits on the person: the next request is read meanwhile.
                let (tx, call) = (tx.clone(), (served.call)(served.session.clone(), params));
                tasks.spawn_until_cancelled("tools-mcp-call", async move {
                    let result = call.await;
                    let _ = tx.send(response(&id, result)).await;
                });
                continue;
            }
        };
        let _ = tx.send(response(&id, reply)).await;
    };
    // The agent closed the pipe: no one reads an answer still on its way, and
    // ending here drops the calls' daemon connection with it.
    drop(tx);
    // Every task stops at the cancellation (`spawn_until_cancelled`): none is left to report.
    let _ = tasks.close(std::time::Duration::ZERO).await;
    ended
}

fn response(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server(name: &'static str) -> Served {
        Served {
            name,
            session: "s".into(),
            tools: json!([]),
            instructions: None,
            call: boxed(|_, _| async { json!({}) }),
        }
    }

    #[test]
    fn a_request_names_its_server_and_the_call_keeps_the_rest_of_its_meta() {
        let servers = [server("cmux-forum"), server("acpmux")];
        let mut params =
            json!({"name": "ls", "_meta": {SERVER_META: "acpmux", "claudecode/toolUseId": "t1"}});
        assert_eq!(pick(&servers, &mut params).unwrap().name, "acpmux");
        assert_eq!(params, json!({"name": "ls", "_meta": {"claudecode/toolUseId": "t1"}}));
        // Only the selector in `_meta`: the call sees no `_meta`, as before.
        let mut params = json!({"name": "rules", "_meta": {SERVER_META: "cmux-forum"}});
        assert_eq!(pick(&servers, &mut params).unwrap().name, "cmux-forum");
        assert_eq!(params, json!({"name": "rules"}));
        // Several servers and none named, or one it does not serve: refused, never guessed.
        assert!(pick(&servers, &mut json!({"name": "ls"})).is_err());
        assert!(pick(&servers, &mut json!({"_meta": {SERVER_META: "cmux-secrets"}})).is_err());
        // A process of one server needs no name.
        let one = [server("cmux-forum")];
        assert_eq!(pick(&one, &mut json!({})).unwrap().name, "cmux-forum");
    }

    #[test]
    fn it_owns_only_acpmux_s_own_server_commands() {
        let args = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
        assert!(owns("cmux-forum", &args(&["forum-mcp"])));
        assert!(owns("acpmux", &args(&["acp", "acpmux-mcp"])));
        assert!(!owns("cmux-forum", &args(&["acpmux-mcp"])));
        assert!(!owns("cmux-repo", &args(&["repo-mcp"])));
        assert!(!owns("cmux-cua", &args(&["cua-mcp"])));
    }
}
