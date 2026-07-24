use std::collections::{HashMap, HashSet};
use std::fs;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::http::header::AUTHORIZATION;
use tungstenite::protocol::WebSocket;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Error as WebSocketError, Message};

use crate::config::MachineConfig;
use crate::localization::{Catalog, DiagnosticAction, Locale};
use crate::model::{Conversation, ThreadSummary, Turn};

const THREAD_PAGE_SIZE: u32 = 100;
const RPC_TIMEOUT: Duration = Duration::from_secs(15);
const RECONNECT_DELAY: Duration = Duration::from_secs(2);
const THREAD_REFRESH_INTERVAL: Duration = Duration::from_secs(2);
const ACTIVE_TRAJECTORY_INTERVAL: Duration = Duration::from_millis(350);
const IDLE_TRAJECTORY_INTERVAL: Duration = Duration::from_secs(2);

type CodexSocket = WebSocket<MaybeTlsStream<TcpStream>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionState {
    Connecting,
    Connected,
    Disconnected(String),
}

#[derive(Debug, Clone)]
pub enum NetworkEvent {
    Connection { machine_id: String, state: ConnectionState },
    Threads { machine_id: String, threads: Vec<ThreadSummary> },
    Conversation { machine_id: String, thread_id: String, conversation: Conversation },
    Notification { machine_id: String, method: String, params: Value },
    Error { machine_id: String, message: String },
}

#[derive(Debug)]
enum NetworkCommand {
    SelectThread(Option<String>),
    Refresh,
    Shutdown,
}

#[derive(Debug)]
struct WorkerHandle {
    sender: Sender<NetworkCommand>,
}

pub struct NetworkHub {
    event_sender: Sender<NetworkEvent>,
    event_receiver: Receiver<NetworkEvent>,
    workers: HashMap<String, WorkerHandle>,
}

impl NetworkHub {
    pub fn new() -> Self {
        let (event_sender, event_receiver) = mpsc::channel();
        Self { event_sender, event_receiver, workers: HashMap::new() }
    }

    pub fn add_machine(&mut self, machine: MachineConfig) {
        if self.workers.contains_key(&machine.id) {
            return;
        }
        let (sender, receiver) = mpsc::channel();
        let event_sender = self.event_sender.clone();
        let machine_id = machine.id.clone();
        let spawn_result = thread::Builder::new()
            .name(format!("cmux-tree-{}", machine.id))
            .spawn(move || run_machine_worker(machine, receiver, event_sender));
        if let Err(error) = spawn_result {
            let catalog = Catalog::new(Locale::detect());
            let message =
                format!("{}: {error}", catalog.diagnostic(DiagnosticAction::SpawnWorker, None));
            let _ = self.event_sender.send(NetworkEvent::Connection {
                machine_id,
                state: ConnectionState::Disconnected(message),
            });
            return;
        }
        self.workers.insert(machine_id, WorkerHandle { sender });
    }

    pub fn select_thread(&self, machine_id: &str, thread_id: Option<String>) {
        if let Some(worker) = self.workers.get(machine_id) {
            let _ = worker.sender.send(NetworkCommand::SelectThread(thread_id));
        }
    }

    pub fn refresh(&self, machine_id: &str) {
        if let Some(worker) = self.workers.get(machine_id) {
            let _ = worker.sender.send(NetworkCommand::Refresh);
        }
    }

    pub fn drain(&self) -> impl Iterator<Item = NetworkEvent> + '_ {
        self.event_receiver.try_iter()
    }
}

impl Drop for NetworkHub {
    fn drop(&mut self) {
        for worker in self.workers.values() {
            let _ = worker.sender.send(NetworkCommand::Shutdown);
        }
    }
}

fn run_machine_worker(
    machine: MachineConfig,
    commands: Receiver<NetworkCommand>,
    events: Sender<NetworkEvent>,
) {
    let mut selected_thread = None;
    let mut thread_cache = Vec::new();
    loop {
        emit_connection(&events, &machine.id, ConnectionState::Connecting);
        let mut socket = match connect_and_initialize(&machine, &events) {
            Ok(socket) => socket,
            Err(error) => {
                emit_connection(
                    &events,
                    &machine.id,
                    ConnectionState::Disconnected(format!("{error:#}")),
                );
                if wait_for_reconnect(&commands, &mut selected_thread) {
                    return;
                }
                continue;
            }
        };
        emit_connection(&events, &machine.id, ConnectionState::Connected);

        let mut next_id = 10_u64;
        let mut next_threads_at = Instant::now();
        let mut next_trajectory_at = Instant::now();
        let mut selected_is_active = false;
        let mut should_reconnect = false;

        while !should_reconnect {
            loop {
                match commands.try_recv() {
                    Ok(NetworkCommand::SelectThread(thread_id)) => {
                        selected_thread = thread_id;
                        next_trajectory_at = Instant::now();
                    }
                    Ok(NetworkCommand::Refresh) => {
                        next_threads_at = Instant::now();
                        next_trajectory_at = Instant::now();
                    }
                    Ok(NetworkCommand::Shutdown) | Err(TryRecvError::Disconnected) => {
                        let _ = socket.close(None);
                        return;
                    }
                    Err(TryRecvError::Empty) => break,
                }
            }

            if Instant::now() >= next_threads_at {
                let load_all = thread_cache.is_empty();
                match list_threads(&mut socket, &mut next_id, &machine.id, &events, load_all) {
                    Ok(threads) => {
                        if load_all {
                            thread_cache = threads;
                        } else {
                            merge_threads(&mut thread_cache, threads);
                        }
                        selected_is_active = selected_thread.as_ref().is_some_and(|selected| {
                            thread_cache
                                .iter()
                                .any(|thread| &thread.id == selected && thread.is_active())
                        });
                        let _ = events.send(NetworkEvent::Threads {
                            machine_id: machine.id.clone(),
                            threads: thread_cache.clone(),
                        });
                    }
                    Err(CallError::Server { message, .. }) => {
                        emit_error(&events, &machine.id, message);
                    }
                    Err(CallError::Transport(error)) => {
                        emit_error(&events, &machine.id, format!("{error:#}"));
                        should_reconnect = true;
                    }
                }
                next_threads_at = Instant::now() + THREAD_REFRESH_INTERVAL;
            }

            if !should_reconnect
                && Instant::now() >= next_trajectory_at
                && let Some(thread_id) = selected_thread.as_deref()
            {
                match read_conversation(&mut socket, &mut next_id, &machine.id, thread_id, &events)
                {
                    Ok(conversation) => {
                        let _ = events.send(NetworkEvent::Conversation {
                            machine_id: machine.id.clone(),
                            thread_id: thread_id.to_string(),
                            conversation,
                        });
                    }
                    Err(CallError::Server { message, .. }) => {
                        emit_error(&events, &machine.id, message);
                    }
                    Err(CallError::Transport(error)) => {
                        emit_error(&events, &machine.id, format!("{error:#}"));
                        should_reconnect = true;
                    }
                }
                next_trajectory_at = Instant::now()
                    + if selected_is_active {
                        ACTIVE_TRAJECTORY_INTERVAL
                    } else {
                        IDLE_TRAJECTORY_INTERVAL
                    };
            }

            if !should_reconnect {
                match read_message(&mut socket, &machine.id, &events) {
                    Ok(ReadOutcome::Message) | Ok(ReadOutcome::TimedOut) => {}
                    Ok(ReadOutcome::Closed) => should_reconnect = true,
                    Err(error) => {
                        emit_error(&events, &machine.id, format!("{error:#}"));
                        should_reconnect = true;
                    }
                }
            }
        }

        emit_connection(
            &events,
            &machine.id,
            ConnectionState::Disconnected(
                Catalog::new(Locale::detect()).connection_closed().to_string(),
            ),
        );
        if wait_for_reconnect(&commands, &mut selected_thread) {
            return;
        }
    }
}

fn wait_for_reconnect(
    commands: &Receiver<NetworkCommand>,
    selected_thread: &mut Option<String>,
) -> bool {
    let deadline = Instant::now() + RECONNECT_DELAY;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match commands.recv_timeout(remaining) {
            Ok(NetworkCommand::SelectThread(thread_id)) => *selected_thread = thread_id,
            Ok(NetworkCommand::Refresh) => return false,
            Ok(NetworkCommand::Shutdown) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                return true;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => return false,
        }
    }
}

fn connect_and_initialize(
    machine: &MachineConfig,
    events: &Sender<NetworkEvent>,
) -> Result<CodexSocket> {
    let catalog = Catalog::new(Locale::detect());
    let mut request = machine.url.as_str().into_client_request().with_context(|| {
        catalog.diagnostic(DiagnosticAction::ParseWebSocketUrl, Some(&machine.url))
    })?;
    if let Some(path) = machine.token_file.as_deref() {
        let token = read_token(path)?;
        let value = HeaderValue::from_str(&format!("Bearer {token}"))
            .context(catalog.diagnostic(DiagnosticAction::BearerHeader, None))?;
        request.headers_mut().insert(AUTHORIZATION, value);
    }

    let (mut socket, _) = tungstenite::connect(request).with_context(|| {
        catalog.diagnostic(DiagnosticAction::ConnectAppServer, Some(&machine.url))
    })?;
    set_read_timeout(&mut socket, Some(Duration::from_millis(75)))
        .context(catalog.diagnostic(DiagnosticAction::ConfigureSocket, None))?;

    let mut next_id = 1;
    rpc(
        &mut socket,
        &mut next_id,
        &machine.id,
        events,
        "initialize",
        json!({
            "clientInfo": {
                "name": "cmux_tree",
                "title": "cmux tree",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {
                "experimentalApi": true
            }
        }),
    )
    .map_err(CallError::into_anyhow)?;
    send_value(&mut socket, &json!({"method": "initialized", "params": {}}))
        .context(catalog.diagnostic(DiagnosticAction::SendInitialized, None))?;
    Ok(socket)
}

fn read_token(path: &Path) -> Result<String> {
    let catalog = Catalog::new(Locale::detect());
    let expanded = expand_tilde(path);
    let token = fs::read_to_string(&expanded).with_context(|| {
        catalog.diagnostic(DiagnosticAction::ReadBearerToken, Some(&expanded.display().to_string()))
    })?;
    let token = token.trim();
    if token.is_empty() {
        anyhow::bail!(catalog.empty_bearer_token(&expanded.display().to_string()));
    }
    Ok(token.to_string())
}

fn expand_tilde(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else { return path.to_path_buf() };
    if value == "~" {
        return std::env::var_os("HOME").map_or_else(|| path.to_path_buf(), PathBuf::from);
    }
    let Some(suffix) = value.strip_prefix("~/") else { return path.to_path_buf() };
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(suffix))
        .unwrap_or_else(|| path.to_path_buf())
}

fn set_read_timeout(socket: &mut CodexSocket, timeout: Option<Duration>) -> std::io::Result<()> {
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => stream.set_read_timeout(timeout),
        MaybeTlsStream::Rustls(stream) => stream.sock.set_read_timeout(timeout),
        _ => Ok(()),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadListPage {
    #[serde(default)]
    data: Vec<ThreadSummary>,
    #[serde(default)]
    next_cursor: Option<String>,
}

fn list_threads(
    socket: &mut CodexSocket,
    next_id: &mut u64,
    machine_id: &str,
    events: &Sender<NetworkEvent>,
    load_all: bool,
) -> Result<Vec<ThreadSummary>, CallError> {
    let catalog = Catalog::new(Locale::detect());
    let mut cursor = None;
    let mut threads = Vec::new();
    let mut seen_cursors = HashSet::new();
    let mut page_index = 0;
    loop {
        let result = rpc(
            socket,
            next_id,
            machine_id,
            events,
            "thread/list",
            json!({
                "cursor": cursor,
                "limit": THREAD_PAGE_SIZE,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "sourceKinds": [
                    "cli",
                    "vscode",
                    "exec",
                    "appServer",
                    "subAgent",
                    "subAgentReview",
                    "subAgentCompact",
                    "subAgentThreadSpawn",
                    "subAgentOther",
                    "unknown"
                ],
                "archived": false,
                "useStateDbOnly": true
            }),
        )?;
        let page: ThreadListPage = serde_json::from_value(result).map_err(|error| {
            CallError::transport(
                anyhow::Error::new(error)
                    .context(catalog.diagnostic(DiagnosticAction::DecodeThreadList, None)),
            )
        })?;
        threads.extend(page.data);
        let is_last_page = page.next_cursor.is_none();
        if load_all && (page_index == 0 || page_index % 5 == 4 || is_last_page) {
            sort_threads(&mut threads);
            let _ = events.send(NetworkEvent::Threads {
                machine_id: machine_id.to_string(),
                threads: threads.clone(),
            });
        }
        if !load_all {
            break;
        }
        let Some(next_cursor) = page.next_cursor else { break };
        if !seen_cursors.insert(next_cursor.clone()) {
            return Err(CallError::transport(anyhow::anyhow!(
                catalog.repeated_pagination_cursor("thread/list")
            )));
        }
        cursor = Some(next_cursor);
        page_index += 1;
    }
    sort_threads(&mut threads);
    Ok(threads)
}

fn sort_threads(threads: &mut [ThreadSummary]) {
    threads.sort_by(|left, right| {
        right.activity_at().cmp(&left.activity_at()).then_with(|| right.id.cmp(&left.id))
    });
}

fn merge_threads(cached: &mut Vec<ThreadSummary>, updates: Vec<ThreadSummary>) {
    let positions = cached
        .iter()
        .enumerate()
        .map(|(index, thread)| (thread.id.clone(), index))
        .collect::<HashMap<_, _>>();
    for thread in updates {
        if let Some(index) = positions.get(&thread.id).copied() {
            cached[index] = thread;
        } else {
            cached.push(thread);
        }
    }
    sort_threads(cached);
}

fn read_conversation(
    socket: &mut CodexSocket,
    next_id: &mut u64,
    machine_id: &str,
    thread_id: &str,
    events: &Sender<NetworkEvent>,
) -> Result<Conversation, CallError> {
    let catalog = Catalog::new(Locale::detect());
    match rpc(
        socket,
        next_id,
        machine_id,
        events,
        "thread/read",
        json!({"threadId": thread_id, "includeTurns": true}),
    ) {
        Ok(result) => serde_json::from_value(result.get("thread").cloned().unwrap_or(Value::Null))
            .map_err(|error| {
                CallError::transport(
                    anyhow::Error::new(error)
                        .context(catalog.diagnostic(DiagnosticAction::DecodeThreadRead, None)),
                )
            }),
        Err(CallError::Server { code, message })
            if code == -32601
                || message.contains("paginated")
                || message.contains("includeTurns") =>
        {
            read_paginated_conversation(socket, next_id, machine_id, thread_id, events)
        }
        Err(error) => Err(error),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TurnsPage {
    #[serde(default)]
    data: Vec<Turn>,
    #[serde(default)]
    next_cursor: Option<String>,
}

fn read_paginated_conversation(
    socket: &mut CodexSocket,
    next_id: &mut u64,
    machine_id: &str,
    thread_id: &str,
    events: &Sender<NetworkEvent>,
) -> Result<Conversation, CallError> {
    let catalog = Catalog::new(Locale::detect());
    let metadata = rpc(
        socket,
        next_id,
        machine_id,
        events,
        "thread/read",
        json!({"threadId": thread_id, "includeTurns": false}),
    )?;
    let mut conversation: Conversation = serde_json::from_value(
        metadata.get("thread").cloned().unwrap_or(Value::Null),
    )
    .map_err(|error| {
        CallError::transport(
            anyhow::Error::new(error)
                .context(catalog.diagnostic(DiagnosticAction::DecodeThreadMetadata, None)),
        )
    })?;

    let mut cursor = None;
    let mut turns = Vec::new();
    let mut seen_cursors = HashSet::new();
    loop {
        let result = rpc(
            socket,
            next_id,
            machine_id,
            events,
            "thread/turns/list",
            json!({
                "threadId": thread_id,
                "cursor": cursor,
                "limit": THREAD_PAGE_SIZE,
                "sortDirection": "desc",
                "itemsView": "full"
            }),
        )?;
        let page: TurnsPage = serde_json::from_value(result).map_err(|error| {
            CallError::transport(
                anyhow::Error::new(error)
                    .context(catalog.diagnostic(DiagnosticAction::DecodeThreadTurns, None)),
            )
        })?;
        turns.extend(page.data);
        let Some(next_cursor) = page.next_cursor else { break };
        if !seen_cursors.insert(next_cursor.clone()) {
            return Err(CallError::transport(anyhow::anyhow!(
                catalog.repeated_pagination_cursor("thread/turns/list")
            )));
        }
        cursor = Some(next_cursor);
    }
    turns.reverse();
    conversation.turns = turns;
    Ok(conversation)
}

#[derive(Debug)]
enum CallError {
    Server { code: i64, message: String },
    Transport(anyhow::Error),
}

impl CallError {
    fn transport(error: impl Into<anyhow::Error>) -> Self {
        Self::Transport(error.into())
    }

    fn into_anyhow(self) -> anyhow::Error {
        let catalog = Catalog::new(Locale::detect());
        match self {
            Self::Server { code, message } => {
                anyhow::anyhow!(catalog.app_server_response_error(code, &message))
            }
            Self::Transport(error) => error,
        }
    }
}

fn rpc(
    socket: &mut CodexSocket,
    next_id: &mut u64,
    machine_id: &str,
    events: &Sender<NetworkEvent>,
    method: &str,
    params: Value,
) -> Result<Value, CallError> {
    let catalog = Catalog::new(Locale::detect());
    let id = *next_id;
    *next_id = next_id.saturating_add(1);
    send_value(socket, &json!({"id": id, "method": method, "params": params}))
        .map_err(CallError::transport)?;

    let deadline = Instant::now() + RPC_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return Err(CallError::transport(anyhow::anyhow!(catalog.request_timed_out(method))));
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let message: Value =
                    serde_json::from_str(text.as_ref()).map_err(|error| {
                        CallError::transport(anyhow::Error::new(error).context(
                            catalog.diagnostic(DiagnosticAction::DecodeAppServerJson, None),
                        ))
                    })?;
                if message.get("id").and_then(Value::as_u64) == Some(id)
                    && (message.get("result").is_some() || message.get("error").is_some())
                {
                    if let Some(error) = message.get("error") {
                        return Err(CallError::Server {
                            code: error.get("code").and_then(Value::as_i64).unwrap_or(-32000),
                            message: error
                                .get("message")
                                .and_then(Value::as_str)
                                .unwrap_or(catalog.unknown_app_server_error())
                                .to_string(),
                        });
                    }
                    return Ok(message.get("result").cloned().unwrap_or(Value::Null));
                }
                handle_server_message(socket, machine_id, events, message)
                    .map_err(CallError::transport)?;
            }
            Ok(Message::Close(_)) => {
                return Err(CallError::transport(anyhow::anyhow!(catalog.app_server_closed())));
            }
            Ok(Message::Ping(payload)) => {
                socket.send(Message::Pong(payload)).map_err(CallError::transport)?;
            }
            Ok(_) => {}
            Err(error) if is_read_timeout(&error) => {}
            Err(error) => return Err(CallError::transport(error)),
        }
    }
}

enum ReadOutcome {
    Message,
    TimedOut,
    Closed,
}

fn read_message(
    socket: &mut CodexSocket,
    machine_id: &str,
    events: &Sender<NetworkEvent>,
) -> Result<ReadOutcome> {
    let catalog = Catalog::new(Locale::detect());
    match socket.read() {
        Ok(Message::Text(text)) => {
            let message: Value = serde_json::from_str(text.as_ref())
                .context(catalog.diagnostic(DiagnosticAction::DecodeAppServerJson, None))?;
            handle_server_message(socket, machine_id, events, message)?;
            Ok(ReadOutcome::Message)
        }
        Ok(Message::Ping(payload)) => {
            socket.send(Message::Pong(payload))?;
            Ok(ReadOutcome::Message)
        }
        Ok(Message::Close(_)) => Ok(ReadOutcome::Closed),
        Ok(_) => Ok(ReadOutcome::Message),
        Err(error) if is_read_timeout(&error) => Ok(ReadOutcome::TimedOut),
        Err(error) => Err(error.into()),
    }
}

fn handle_server_message(
    socket: &mut CodexSocket,
    machine_id: &str,
    events: &Sender<NetworkEvent>,
    message: Value,
) -> Result<()> {
    let catalog = Catalog::new(Locale::detect());
    let method = message.get("method").and_then(Value::as_str);
    if message.get("id").is_some() && method.is_some() {
        send_value(
            socket,
            &json!({
                "id": message.get("id").cloned().unwrap_or(Value::Null),
                "error": {
                    "code": -32601,
                    "message": catalog.read_only_observer()
                }
            }),
        )?;
        return Ok(());
    }
    if let Some(method) = method {
        let _ = events.send(NetworkEvent::Notification {
            machine_id: machine_id.to_string(),
            method: method.to_string(),
            params: message.get("params").cloned().unwrap_or_else(|| json!({})),
        });
    }
    Ok(())
}

fn send_value(socket: &mut CodexSocket, value: &Value) -> Result<()> {
    let catalog = Catalog::new(Locale::detect());
    let text = serde_json::to_string(value)
        .context(catalog.diagnostic(DiagnosticAction::EncodeAppServerJson, None))?;
    socket
        .send(Message::Text(text.into()))
        .context(catalog.diagnostic(DiagnosticAction::WriteAppServerMessage, None))
}

fn is_read_timeout(error: &WebSocketError) -> bool {
    matches!(
        error,
        WebSocketError::Io(io_error)
            if matches!(
                io_error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            )
    )
}

fn emit_connection(events: &Sender<NetworkEvent>, machine_id: &str, state: ConnectionState) {
    let _ = events.send(NetworkEvent::Connection { machine_id: machine_id.to_string(), state });
}

fn emit_error(events: &Sender<NetworkEvent>, machine_id: &str, message: String) {
    let _ = events.send(NetworkEvent::Error { machine_id: machine_id.to_string(), message });
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn current_codex_thread_list_shape_decodes() {
        let page: ThreadListPage = serde_json::from_value(json!({
            "data": [{
                "id": "thread-1",
                "sessionId": "session-1",
                "parentThreadId": null,
                "preview": "Build the tree",
                "createdAt": 100,
                "updatedAt": 110,
                "recencyAt": 120,
                "status": {"type": "active", "activeFlags": []},
                "cwd": "/work"
            }],
            "nextCursor": null,
            "backwardsCursor": null
        }))
        .unwrap();

        assert_eq!(page.data[0].activity_at(), 120);
        assert!(page.data[0].is_active());
    }

    #[test]
    fn tilde_expansion_preserves_non_tilde_paths() {
        assert_eq!(
            expand_tilde(Path::new("/run/secrets/codex")),
            PathBuf::from("/run/secrets/codex")
        );
    }

    #[test]
    fn first_page_refresh_updates_recent_threads_without_dropping_history() {
        let mut cached = vec![
            ThreadSummary { id: "recent".into(), updated_at: 20, ..ThreadSummary::default() },
            ThreadSummary { id: "older".into(), updated_at: 10, ..ThreadSummary::default() },
        ];
        merge_threads(
            &mut cached,
            vec![
                ThreadSummary { id: "recent".into(), updated_at: 40, ..ThreadSummary::default() },
                ThreadSummary { id: "new".into(), updated_at: 30, ..ThreadSummary::default() },
            ],
        );

        assert_eq!(
            cached.iter().map(|thread| thread.id.as_str()).collect::<Vec<_>>(),
            vec!["recent", "new", "older"]
        );
        assert_eq!(cached[0].updated_at, 40);
    }
}
