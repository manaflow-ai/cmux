//! The person's cmux NEXT workspaces, for a browser's agent pane sidebar.
//!
//! The app names where its workspaces live: its own cmux-tui daemon socket and its
//! agent tab host (`install:<id>`), with `_acpmux/browser_workspace_source_set {socket, host}`
//! on its own proven connection (the unix socket or the LocalApp pane, as the person), and
//! clears it with an empty set (iPhone connections turned off, signed out). Nothing else ever
//! sets it, and it lives in memory only.
//!
//! `_acpmux/browser_workspaces` is answered only to a browser on the web listener that
//! presented its own enrolled device on this connection (`web_device.rs`, `Conn::proof`
//! `WebDevice`). It reads the tree from that socket as a remote device
//! (`set-client-info {remote: true}`, cmux-tui `incognito_remote.rs`), so an incognito
//! workspace never reaches the browser, and with the conversation tab capabilities, so an
//! agent chat tab reads as one (cmux-tui `conversation_tabs_wire.rs`). The answer:
//!
//! `{available, registryId, workspaces: [{id, name, title, chats: [{tabId, sessionId?,
//! local, title, host, harness?}]}]}`
//!
//! `local` says the chat runs on this machine's app (its tab's host is the source's host), so
//! the browser can open it here; `available` is false when no source is set or the read
//! failed. One read at a time, and a read younger than [`READ_REUSE`] answers again.

use std::path::{Path, PathBuf};
use std::sync::{Mutex as StdMutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};

use super::{Conn, ConnAuth, Origin};
use crate::rpc::{RpcError, method};

pub(crate) const SET: &str = method::MUX_BROWSER_WORKSPACE_SOURCE_SET;
pub(crate) const READ: &str = method::MUX_BROWSER_WORKSPACES;

/// The longest wait for the app's daemon to answer one read.
const READ_WAIT: Duration = Duration::from_secs(3);
/// A read this young answers the next one (a sidebar refresh after each session list).
const READ_REUSE: Duration = Duration::from_secs(2);
/// The most bytes read from the app's daemon for one read.
const MAX_REPLY_BYTES: u64 = 8 << 20;
/// The most workspaces listed (`list-workspaces` `limit`), and chats per workspace.
const MAX_WORKSPACES: usize = 500;
const MAX_CHATS: usize = 500;
/// The most bytes of workspaces one answer carries, well under a frame
/// (`rpc::REPLY_PAGE_BYTES`).
const REPLY_BUDGET: usize = crate::rpc::REPLY_PAGE_BYTES / 2;
const MAX_SOCKET_BYTES: usize = 1024;
const MAX_HOST_BYTES: usize = 256;
/// What the read's connection tells the app's daemon it understands: every tab kind the
/// public CLI does (cmux-tui `cli/tab_capabilities.rs`), so a chat tab is not shown as a page.
const CAPABILITIES: [&str; 4] = [
    "conversation-tabs-v1",
    "agent-session-tabs-v1",
    "page-tabs-v1",
    "closed-conversation-tabs-v1",
];
const CLIENT_NAME: &str = "acpmux browser workspaces";
const HELLO_ID: &str = "browser-workspaces-hello";
const LIST_ID: &str = "browser-workspaces-list";

/// Where the app's workspaces are read from.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Source {
    socket: PathBuf,
    host: String,
}

/// The source the app set, and the last read of it.
#[derive(Default)]
pub(crate) struct Sources {
    source: StdMutex<Option<Source>>,
    last: tokio::sync::Mutex<Option<(Source, Instant, Value)>>,
}

/// Whether a connection may set the source: the person, proven on this machine's unix
/// socket or the app's own pane connection, never a web, peer or device connection.
fn admits_set(origin: Origin, auth: ConnAuth, person: bool) -> bool {
    person
        && matches!(
            (origin, auth),
            (Origin::Local, ConnAuth::LocalSocket) | (Origin::LocalApp, ConnAuth::LocalApp)
        )
}

/// Whether a connection may read the workspaces: a browser holding its enrolled device.
fn admits_read(proof: ConnAuth) -> bool {
    proof == ConnAuth::WebDevice
}

fn device_required() -> RpcError {
    RpcError::new(-32003, "the workspaces are shown only to an enrolled browser device")
        .with_data(json!({"reason": "device.required"}))
}

/// The source `params` names, None for an empty set (a clear).
fn source_of(params: &Value) -> Result<Option<Source>, RpcError> {
    let field = |key: &str| params.get(key).filter(|value| !value.is_null());
    let (socket, host) = match (field("socket"), field("host")) {
        (None, None) => return Ok(None),
        (Some(socket), Some(host)) => (socket, host),
        _ => return Err(RpcError::invalid_params("socket and host go together")),
    };
    let clean = |text: &str, max: usize| {
        !text.is_empty() && text.len() <= max && !text.chars().any(char::is_control)
    };
    let socket = socket
        .as_str()
        .filter(|socket| clean(socket, MAX_SOCKET_BYTES) && Path::new(socket).is_absolute())
        .ok_or_else(|| RpcError::invalid_params("socket is the absolute path of a socket"))?;
    let host = host
        .as_str()
        .filter(|host| clean(host, MAX_HOST_BYTES))
        .ok_or_else(|| RpcError::invalid_params("host is the app's agent tab host"))?;
    Ok(Some(Source { socket: PathBuf::from(socket), host: host.to_owned() }))
}

impl Sources {
    /// `_acpmux/browser_workspace_source_set {socket, host}`, or `{}` to clear.
    pub(crate) fn set(&self, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
        if !admits_set(conn.origin, conn.auth, conn.is_person()) {
            return Err(conn.person_only("setting the browser workspace source"));
        }
        self.set_admitted(params)
    }

    fn set_admitted(&self, params: &Value) -> Result<Value, RpcError> {
        let source = source_of(params)?;
        let set = source.is_some();
        *self.source.lock().unwrap_or_else(PoisonError::into_inner) = source;
        Ok(json!({"set": set}))
    }

    fn current(&self) -> Option<Source> {
        self.source.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// `_acpmux/browser_workspaces`.
    pub(crate) async fn read(&self, conn: &Conn) -> Result<Value, RpcError> {
        self.read_as(conn.proof()).await
    }

    async fn read_as(&self, proof: ConnAuth) -> Result<Value, RpcError> {
        if !admits_read(proof) {
            return Err(device_required());
        }
        let Some(source) = self.current() else {
            return Ok(unavailable(None));
        };
        let mut last = self.last.lock().await;
        if let Some((read, at, value)) = last.as_ref()
            && *read == source
            && at.elapsed() < READ_REUSE
        {
            return Ok(value.clone());
        }
        let value = match tokio::time::timeout(READ_WAIT, read_tree(&source.socket)).await {
            Ok(Ok(tree)) => project(&tree, &source),
            Ok(Err(error)) => {
                tracing::debug!("browser workspaces: the app's daemon did not answer: {error}");
                unavailable(Some(&source))
            }
            Err(_) => {
                tracing::debug!("browser workspaces: the app's daemon took over {READ_WAIT:?}");
                unavailable(Some(&source))
            }
        };
        *last = Some((source, Instant::now(), value.clone()));
        Ok(value)
    }
}

fn unavailable(source: Option<&Source>) -> Value {
    json!({
        "available": false,
        "registryId": source.map(|source| source.host.as_str()),
        "workspaces": [],
    })
}

/// The app daemon's `list-workspaces` tree, read as a remote device.
async fn read_tree(socket: &Path) -> std::io::Result<Value> {
    let stream = crate::local_stream::connect(socket).await?;
    let (read, mut write) = crate::local_stream::split(stream);
    let mut reader = BufReader::new(read.take(MAX_REPLY_BYTES));
    let hello = json!({
        "id": HELLO_ID,
        "cmd": "set-client-info",
        "name": CLIENT_NAME,
        "remote": true,
        "capabilities": CAPABILITIES,
    });
    send(&mut write, &hello).await?;
    answer(&mut reader, HELLO_ID).await?;
    send(&mut write, &json!({"id": LIST_ID, "cmd": "list-workspaces", "limit": MAX_WORKSPACES}))
        .await?;
    answer(&mut reader, LIST_ID).await
}

async fn send(write: &mut (impl AsyncWrite + Unpin), request: &Value) -> std::io::Result<()> {
    let mut line = request.to_string();
    line.push('\n');
    write.write_all(line.as_bytes()).await?;
    write.flush().await
}

/// The `data` of the reply to `id`; events and other replies before it are skipped.
async fn answer(reader: &mut (impl AsyncBufRead + Unpin), id: &str) -> std::io::Result<Value> {
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).await? == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "the app's daemon closed the connection",
            ));
        }
        let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
        if reply.get("id").and_then(Value::as_str) != Some(id) {
            continue; // an event or another answer
        }
        return crate::computer_use::client::daemon_reply(&reply)
            .map_err(|error| std::io::Error::other(error.to_string()));
    }
}

/// What the browser is shown of the tree: the workspaces in the tree's order, up to
/// [`REPLY_BUDGET`] bytes (`truncated` once one was left out).
fn project(tree: &Value, source: &Source) -> Value {
    let mut workspaces = Vec::new();
    let mut bytes = 0usize;
    let mut truncated = false;
    let rows = tree.get("workspaces").and_then(Value::as_array).into_iter().flatten();
    for row in rows.filter_map(|row| workspace(row, source)) {
        bytes += row.to_string().len();
        if workspaces.len() >= MAX_WORKSPACES || bytes > REPLY_BUDGET {
            truncated = true;
            break;
        }
        workspaces.push(row);
    }
    let mut shown = json!({"available": true, "registryId": source.host, "workspaces": workspaces});
    if truncated && let Some(fields) = shown.as_object_mut() {
        fields.insert("truncated".to_owned(), json!(true));
    }
    shown
}

fn text<'a>(row: &'a Value, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Value::as_str).map(str::trim).filter(|text| !text.is_empty())
}

/// A row's id: its stable resource id, else its numeric id.
fn id_of(row: &Value, resource: &str) -> Option<String> {
    text(row, resource)
        .map(str::to_owned)
        .or_else(|| row.get("id").and_then(Value::as_u64).map(|id| id.to_string()))
}

fn workspace(row: &Value, source: &Source) -> Option<Value> {
    let id = id_of(row, "resource_id")?;
    let tabs = row
        .get("screens")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
        .flat_map(|pane| pane.get("tabs").and_then(Value::as_array).into_iter().flatten());
    let mut chats: Vec<Value> = Vec::new();
    for chat in tabs.filter_map(|tab| chat(tab, source)) {
        if chats.len() >= MAX_CHATS {
            break;
        }
        if !chats.iter().any(|seen| seen.get("tabId") == chat.get("tabId")) {
            chats.push(chat);
        }
    }
    Some(json!({
        "id": id,
        "name": text(row, "name").unwrap_or_default(),
        "title": text(row, "title"),
        "chats": chats,
    }))
}

/// An agent chat tab (`conversation.agent_session`); None for any other tab.
fn chat(tab: &Value, source: &Source) -> Option<Value> {
    let agent = tab
        .pointer("/conversation/agent_session")
        .or_else(|| tab.pointer("/extra/conversation/agent_session"))
        .filter(|agent| agent.is_object())?;
    let tab_id = id_of(tab, "tab_resource_id")?;
    let host = text(agent, "host")?;
    let session =
        text(agent, "session").map(|session| session.strip_prefix("acp:").unwrap_or(session));
    let title =
        text(tab, "name").or_else(|| text(tab, "title_text")).or_else(|| text(tab, "title"));
    let mut chat = Map::new();
    chat.insert("tabId".into(), json!(tab_id));
    if let Some(session) = session {
        chat.insert("sessionId".into(), json!(session));
    }
    chat.insert("local".into(), json!(host == source.host));
    chat.insert("title".into(), json!(title.unwrap_or_default()));
    chat.insert("host".into(), json!(text(agent, "host_name").unwrap_or(host)));
    if let Some(harness) = text(agent, "harness") {
        chat.insert("harness".into(), json!(harness));
    }
    Some(Value::Object(chat))
}

#[cfg(test)]
#[path = "browser_workspaces_tests.rs"]
mod tests;
