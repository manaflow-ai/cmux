//! WebSocket PTY Server for VSCode Terminal Backend
//!
//! Server-authoritative model: The server is the source of truth for all terminal state.
//! Clients subscribe to state changes and mirror the server state.
//!
//! Also provides a CLI client for managing PTY sessions (tmux-like interface).

mod cli;

// Re-export terminal emulation library
use cmux_terminal::{DaFilter, VirtualTerminal};

use std::{
    collections::HashMap,
    env,
    io::{Read, Write as IoWrite},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use axum::{
    extract::{
        ws::{Message, WebSocket},
        Path, Query, State, WebSocketUpgrade,
    },
    http::StatusCode,
    response::{Html, IntoResponse, Json},
    routing::{delete, get, patch, post},
    Router,
};
use clap::{Parser, Subcommand};
use futures::{SinkExt, StreamExt};
use parking_lot::{Mutex, RwLock};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use tower_http::cors::CorsLayer;
use tracing::{error, info, warn};
use uuid::Uuid;

// =============================================================================
// CLI Argument Parsing
// =============================================================================

#[derive(Parser)]
#[command(name = "cmux-pty")]
#[command(about = "PTY server and client for terminal session management")]
#[command(version)]
struct Cli {
    /// Server URL for client commands (fallback if socket unavailable)
    #[arg(
        short = 'S',
        long,
        env = "CMUX_PTY_URL",
        default_value = "http://localhost:39383"
    )]
    server: String,

    /// Path to the Unix socket for bridge requests
    #[arg(
        long,
        env = "CMUX_BRIDGE_SOCKET",
        default_value = "/run/cmux/bridge.sock"
    )]
    socket: String,

    /// Sandbox ID for socket-based operations
    #[arg(long, env = "CMUX_SANDBOX_ID")]
    sandbox_id: Option<String>,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Run the PTY server
    Server {
        /// Host to bind to
        #[arg(long, env = "PTY_SERVER_HOST", default_value = "0.0.0.0")]
        host: String,

        /// Port to listen on
        #[arg(short, long, env = "PTY_SERVER_PORT", default_value = "39383")]
        port: u16,
    },

    /// List all sessions
    #[command(visible_alias = "ls")]
    List {
        /// Output as JSON
        #[arg(long)]
        json: bool,
    },

    /// Create a new session
    New {
        /// Session name
        #[arg(short, long)]
        name: Option<String>,

        /// Shell to use
        #[arg(short, long)]
        shell: Option<String>,

        /// Working directory
        #[arg(short, long)]
        cwd: Option<String>,

        /// Create session but don't attach
        #[arg(short, long)]
        detached: bool,
    },

    /// Attach to a session
    Attach {
        /// Session ID, name, or index
        session: String,
    },

    /// Kill one or more sessions
    Kill {
        /// Session IDs, names, or indices
        sessions: Vec<String>,
    },

    /// Send keys to a session
    SendKeys {
        /// Session ID, name, or index
        session: String,

        /// Keys to send (supports Enter, Tab, C-c, etc.)
        keys: Vec<String>,
    },

    /// Capture pane content
    CapturePane {
        /// Session ID, name, or index
        session: String,

        /// Print without trailing newline
        #[arg(short, long)]
        print: bool,
    },

    /// Resize a session
    Resize {
        /// Session ID, name, or index
        session: String,

        /// Number of columns
        cols: u16,

        /// Number of rows
        rows: u16,
    },
}

// =============================================================================
// Constants
// =============================================================================

const INDEX_HTML: &str = include_str!("../static/index.html");
const MAX_SCROLLBACK: usize = 100_000;
const PTY_READ_BUFFER_SIZE: usize = 4096;
const PTY_WRITE_CHUNK_SIZE: usize = 512; // Small chunks for smooth writes
const PTY_INPUT_CHANNEL_SIZE: usize = 1024; // Bounded channel for backpressure

// =============================================================================
// Error Types
// =============================================================================

#[derive(Debug, thiserror::Error)]
enum ServerError {
    #[error("Session not found: {0}")]
    SessionNotFound(String),

    #[error("Failed to spawn PTY: {0}")]
    PtySpawnError(String),
}

impl IntoResponse for ServerError {
    fn into_response(self) -> axum::response::Response {
        let (status, message) = match &self {
            ServerError::SessionNotFound(_) => (StatusCode::NOT_FOUND, self.to_string()),
            ServerError::PtySpawnError(_) => (StatusCode::INTERNAL_SERVER_ERROR, self.to_string()),
        };

        let body = serde_json::json!({ "error": message });
        (status, Json(body)).into_response()
    }
}

// =============================================================================
// Models
// =============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct CreateSessionRequest {
    #[serde(default = "default_shell")]
    shell: String,
    #[serde(default = "default_cwd")]
    cwd: String,
    #[serde(default = "default_cols")]
    cols: u16,
    #[serde(default = "default_rows")]
    rows: u16,
    env: Option<HashMap<String, String>>,
    name: Option<String>,
    client_id: Option<String>,
    /// Flexible metadata - clients can store any JSON here.
    /// Example: {"location": "editor", "type": "agent", "managed": true}
    metadata: Option<serde_json::Value>,
}

fn default_shell() -> String {
    "/bin/zsh".to_string()
}
fn default_cwd() -> String {
    "/home/vscode".to_string()
}
fn default_cols() -> u16 {
    80
}
fn default_rows() -> u16 {
    24
}

impl Default for CreateSessionRequest {
    fn default() -> Self {
        Self {
            shell: default_shell(),
            cwd: default_cwd(),
            cols: default_cols(),
            rows: default_rows(),
            env: None,
            name: None,
            client_id: None,
            metadata: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UpdateSessionRequest {
    name: Option<String>,
    index: Option<usize>,
    /// Update metadata - merges with existing metadata (use null to remove keys)
    metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SessionInfo {
    id: String,
    name: String,
    index: usize,
    shell: String,
    cwd: String,
    cols: u16,
    rows: u16,
    created_at: f64,
    alive: bool,
    pid: u32,
    /// Flexible metadata for client use (location, type, managed flag, etc.)
    #[serde(skip_serializing_if = "Option::is_none")]
    metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
enum ServerEvent {
    #[serde(rename = "state_sync")]
    StateSync { terminals: Vec<SessionInfo> },

    #[serde(rename = "pty_created")]
    PtyCreated {
        terminal: SessionInfo,
        creator_client_id: Option<String>,
    },

    #[serde(rename = "pty_updated")]
    PtyUpdated {
        terminal: SessionInfo,
        changes: HashMap<String, serde_json::Value>,
    },

    #[serde(rename = "pty_deleted")]
    PtyDeleted { pty_id: String },

    #[serde(rename = "output")]
    Output { data: String },

    #[serde(rename = "exit")]
    Exit { exit_code: Option<i32> },

    #[serde(rename = "error")]
    Error { error: String },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
enum ClientMessage {
    #[serde(rename = "get_state")]
    GetState,

    #[serde(rename = "create_pty")]
    CreatePty {
        shell: Option<String>,
        cwd: Option<String>,
        cols: Option<u16>,
        rows: Option<u16>,
        name: Option<String>,
        client_id: Option<String>,
        metadata: Option<serde_json::Value>,
    },

    #[serde(rename = "rename_pty")]
    RenamePty { pty_id: String, name: String },

    #[serde(rename = "reorder_pty")]
    ReorderPty { pty_id: String, index: usize },

    #[serde(rename = "delete_pty")]
    DeletePty { pty_id: String },
}

// =============================================================================
// PTY Session - Wrapped in Arc<Mutex<>> for thread safety
// =============================================================================

struct PtySessionInner {
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn portable_pty::Child + Send>,
}

struct PtySession {
    id: String,
    inner: Mutex<PtySessionInner>,
    shell: String,
    cwd: String,
    name: RwLock<String>,
    index: RwLock<usize>,
    created_at: f64,
    cols: RwLock<u16>,
    rows: RwLock<u16>,
    scrollback: RwLock<String>,
    output_tx: broadcast::Sender<String>,
    input_tx: std::sync::mpsc::SyncSender<Vec<u8>>, // Bounded channel for backpressure
    pid: u32,
    metadata: RwLock<Option<serde_json::Value>>,
    /// DA (Device Attributes) filter to prevent feedback loops with nested terminals.
    /// Filters DA1/DA2 queries and responses that can cause infinite loops when
    /// running terminal emulators inside terminal emulators.
    da_filter: Mutex<DaFilter>,
    /// Virtual terminal emulator for tracking terminal state.
    /// Provides server-side ANSI sequence parsing and grid-based storage.
    terminal: Mutex<VirtualTerminal>,
}

impl PtySession {
    fn to_info(&self) -> SessionInfo {
        let alive = {
            let mut inner = self.inner.lock();
            inner.child.try_wait().ok().flatten().is_none()
        };

        SessionInfo {
            id: self.id.clone(),
            name: self.name.read().clone(),
            index: *self.index.read(),
            shell: self.shell.clone(),
            cwd: self.cwd.clone(),
            cols: *self.cols.read(),
            rows: *self.rows.read(),
            created_at: self.created_at,
            alive,
            pid: self.pid,
            metadata: self.metadata.read().clone(),
        }
    }

    fn is_alive(&self) -> bool {
        let mut inner = self.inner.lock();
        inner.child.try_wait().ok().flatten().is_none()
    }

    /// Send input to the PTY via the channel.
    /// Uses a bounded channel for backpressure - if the PTY can't keep up,
    /// this will block (which is correct behavior for flow control).
    fn write_input(&self, data: &str) -> Result<()> {
        let len = data.len();
        if len > 100 {
            info!("[session:{}] Queueing large input: {} bytes", self.id, len);
        }
        self.input_tx.send(data.as_bytes().to_vec()).map_err(|e| {
            error!("[session:{}] Input channel send failed: {}", self.id, e);
            anyhow::anyhow!("PTY input channel closed")
        })?;
        Ok(())
    }

    fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        *self.cols.write() = cols;
        *self.rows.write() = rows;

        // Resize PTY
        let inner = self.inner.lock();
        inner
            .master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("Failed to resize PTY")?;
        drop(inner);

        // Resize virtual terminal emulator
        self.resize_terminal(rows as usize, cols as usize);

        Ok(())
    }

    fn kill(&self) {
        let mut inner = self.inner.lock();
        if let Err(e) = inner.child.kill() {
            warn!("Failed to kill PTY process: {}", e);
        }
    }

    fn append_scrollback(&self, data: &str) {
        let mut scrollback = self.scrollback.write();
        scrollback.push_str(data);
        if scrollback.len() > MAX_SCROLLBACK {
            let mut start = scrollback.len() - MAX_SCROLLBACK;
            // Find a valid UTF-8 char boundary to avoid panic on multi-byte chars
            while start < scrollback.len() && !scrollback.is_char_boundary(start) {
                start += 1;
            }
            *scrollback = scrollback[start..].to_string();
        }
    }

    fn get_scrollback(&self) -> String {
        self.scrollback.read().clone()
    }

    fn set_name(&self, name: String) {
        *self.name.write() = name;
    }

    fn set_index(&self, index: usize) {
        *self.index.write() = index;
    }

    fn get_index(&self) -> usize {
        *self.index.read()
    }

    fn set_metadata(&self, metadata: Option<serde_json::Value>) {
        *self.metadata.write() = metadata;
    }

    /// Process bytes through the virtual terminal emulator.
    /// Updates the terminal's internal grid state.
    fn process_terminal(&self, data: &[u8]) {
        let mut terminal = self.terminal.lock();
        terminal.process(data);
    }

    /// Resize the virtual terminal emulator.
    fn resize_terminal(&self, rows: usize, cols: usize) {
        let mut terminal = self.terminal.lock();
        terminal.resize(rows, cols);
    }

    /// Get the current terminal content as plain text lines.
    fn get_terminal_content(&self) -> Vec<String> {
        let terminal = self.terminal.lock();
        terminal.get_lines()
    }

    /// Get the viewport content (visible area) as plain text lines.
    fn get_terminal_viewport(&self) -> Vec<String> {
        let terminal = self.terminal.lock();
        terminal.viewport_lines()
    }
}

// =============================================================================
// Application State
// =============================================================================

struct AppState {
    sessions: RwLock<HashMap<String, Arc<PtySession>>>,
    terminal_counter: RwLock<u32>,
    event_tx: broadcast::Sender<ServerEvent>,
}

impl AppState {
    fn new() -> Self {
        let (event_tx, _) = broadcast::channel(1024);
        Self {
            sessions: RwLock::new(HashMap::new()),
            terminal_counter: RwLock::new(0),
            event_tx,
        }
    }

    fn get_next_terminal_name(&self, shell: &str) -> String {
        let mut counter = self.terminal_counter.write();
        *counter += 1;
        // Extract shell name from path (e.g., "/bin/zsh" -> "zsh")
        let shell_name = std::path::Path::new(shell)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("shell");
        format!("{} {}", shell_name, *counter)
    }

    fn get_ordered_sessions(&self) -> Vec<SessionInfo> {
        let sessions = self.sessions.read();
        let mut infos: Vec<_> = sessions
            .values()
            .filter(|s| s.is_alive())
            .map(|s| s.to_info())
            .collect();
        infos.sort_by_key(|s| s.index);
        infos
    }

    fn get_full_state(&self) -> ServerEvent {
        ServerEvent::StateSync {
            terminals: self.get_ordered_sessions(),
        }
    }

    fn reindex_sessions(&self) {
        let sessions = self.sessions.read();
        let mut infos: Vec<_> = sessions
            .values()
            .filter(|s| s.is_alive())
            .map(|s| (s.id.clone(), s.get_index()))
            .collect();
        infos.sort_by_key(|(_, idx)| *idx);

        for (i, (id, _)) in infos.iter().enumerate() {
            if let Some(session) = sessions.get(id) {
                session.set_index(i);
            }
        }
    }

    fn broadcast_event(&self, event: ServerEvent) {
        // Ignore errors - just means no subscribers
        let _ = self.event_tx.send(event);
    }

    fn broadcast_state_sync(&self) {
        self.broadcast_event(self.get_full_state());
    }
}

// =============================================================================
// PTY Writer Task - Handles async writes to PTY
// =============================================================================

/// Spawns a dedicated thread for PTY writes.
/// This thread reads from a channel and writes to the PTY in small chunks.
/// Using a dedicated thread (not spawn_blocking) ensures writes happen
/// sequentially and the PTY buffer can drain between chunks.
fn spawn_pty_writer_thread(
    session_id: String,
    mut writer: Box<dyn IoWrite + Send>,
    input_rx: std::sync::mpsc::Receiver<Vec<u8>>,
) {
    std::thread::spawn(move || {
        info!("[writer:{}] Writer thread started", session_id);

        let mut total_bytes_written: usize = 0;
        let mut message_count: usize = 0;

        while let Ok(data) = input_rx.recv() {
            message_count += 1;
            let data_len = data.len();
            info!(
                "[writer:{}] Received input: {} bytes (message #{})",
                session_id, data_len, message_count
            );

            // Write in small chunks to prevent blocking
            let mut chunk_num = 0;
            for chunk in data.chunks(PTY_WRITE_CHUNK_SIZE) {
                chunk_num += 1;
                if let Err(e) = writer.write_all(chunk) {
                    error!(
                        "[writer:{}] Write error on chunk {}: {} (errno: {:?})",
                        session_id,
                        chunk_num,
                        e,
                        e.raw_os_error()
                    );
                    return;
                }
                if let Err(e) = writer.flush() {
                    error!(
                        "[writer:{}] Flush error on chunk {}: {} (errno: {:?})",
                        session_id,
                        chunk_num,
                        e,
                        e.raw_os_error()
                    );
                    return;
                }
                // Small yield to allow PTY to process
                std::thread::yield_now();
            }

            total_bytes_written += data_len;
            if data_len > 100 {
                info!(
                    "[writer:{}] Large input processed: {} bytes in {} chunks (total: {} bytes)",
                    session_id, data_len, chunk_num, total_bytes_written
                );
            }
        }

        info!(
            "[writer:{}] Writer thread finished (channel closed). Total: {} messages, {} bytes",
            session_id, message_count, total_bytes_written
        );
    });
}

// =============================================================================
// UTF-8 Helper
// =============================================================================

/// Find the last valid UTF-8 boundary in a byte slice.
/// Returns the number of bytes that form complete UTF-8 characters.
/// Any trailing incomplete sequence is not included.
fn find_utf8_boundary(bytes: &[u8]) -> usize {
    if bytes.is_empty() {
        return 0;
    }

    // Try to validate the entire slice first
    if std::str::from_utf8(bytes).is_ok() {
        return bytes.len();
    }

    // Find the last valid boundary by checking from the end
    // UTF-8 continuation bytes start with 10xxxxxx (0x80-0xBF)
    // Start bytes are 0xxxxxxx, 110xxxxx, 1110xxxx, 11110xxx
    let mut end = bytes.len();

    // Look back up to 4 bytes (max UTF-8 char length) to find a complete sequence
    for i in 1..=4.min(bytes.len()) {
        let check_pos = bytes.len() - i;
        if std::str::from_utf8(&bytes[..check_pos]).is_ok() {
            end = check_pos;
            break;
        }
    }

    // If we couldn't find a valid boundary in the last 4 bytes,
    // there might be invalid data - return what we can
    if end == bytes.len() {
        // Find the last non-continuation byte
        for i in (0..bytes.len()).rev() {
            // Not a continuation byte (doesn't start with 10) and valid UTF-8 up to that point
            if bytes[i] & 0b1100_0000 != 0b1000_0000 && std::str::from_utf8(&bytes[..i]).is_ok() {
                return i;
            }
        }
        return 0;
    }

    end
}

// =============================================================================
// PTY Output Reader Task
// =============================================================================

async fn spawn_pty_reader(
    session: Arc<PtySession>,
    mut reader: Box<dyn Read + Send>,
    state: Arc<AppState>,
) {
    let session_id = session.id.clone();
    let mut buf = [0u8; PTY_READ_BUFFER_SIZE];
    let mut utf8_buffer: Vec<u8> = Vec::new(); // Buffer for incomplete UTF-8 sequences

    info!("[reader:{}] Reader task started", session_id);

    let mut total_bytes_read: usize = 0;
    let mut read_count: usize = 0;

    loop {
        // Read in a blocking task
        let read_result = tokio::task::spawn_blocking({
            move || {
                let result = reader.read(&mut buf);
                (reader, buf, result)
            }
        })
        .await;

        let (returned_reader, returned_buf, result) = match read_result {
            Ok(r) => r,
            Err(e) => {
                error!("[reader:{}] spawn_blocking panicked: {}", session_id, e);
                break;
            }
        };

        reader = returned_reader;
        buf = returned_buf;

        match result {
            Ok(0) => {
                // EOF - flush DaFilter and remaining buffer
                {
                    let mut filter = session.da_filter.lock();
                    utf8_buffer.extend(filter.flush());
                }
                if !utf8_buffer.is_empty() {
                    let data = String::from_utf8_lossy(&utf8_buffer).to_string();
                    session.append_scrollback(&data);
                    let _ = session.output_tx.send(data);
                }
                info!(
                    "[reader:{}] EOF received. Total: {} reads, {} bytes",
                    session_id, read_count, total_bytes_read
                );
                break;
            }
            Ok(n) => {
                read_count += 1;
                total_bytes_read += n;

                // Apply DaFilter to raw bytes to remove DA query/response sequences
                let filtered_bytes = {
                    let mut filter = session.da_filter.lock();
                    filter.filter(&buf[..n])
                };

                // Process through virtual terminal emulator for state tracking
                session.process_terminal(&filtered_bytes);

                // Combine any leftover bytes from previous read with filtered data
                utf8_buffer.extend_from_slice(&filtered_bytes);

                // Find the last valid UTF-8 boundary
                let valid_up_to = find_utf8_boundary(&utf8_buffer);

                if valid_up_to > 0 {
                    // Convert valid portion to string
                    let data = String::from_utf8_lossy(&utf8_buffer[..valid_up_to]).to_string();

                    // Update scrollback
                    session.append_scrollback(&data);

                    // Send to session-specific subscribers
                    let send_result = session.output_tx.send(data);
                    if send_result.is_err() {
                        warn!(
                            "[reader:{}] No subscribers for output ({} bytes)",
                            session_id, valid_up_to
                        );
                    }

                    // Keep any incomplete bytes for the next read
                    utf8_buffer = utf8_buffer[valid_up_to..].to_vec();
                }
                // If valid_up_to is 0, we're still accumulating an incomplete char
            }
            Err(e) => {
                if e.kind() == std::io::ErrorKind::WouldBlock {
                    tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                    continue;
                }
                error!(
                    "[reader:{}] Read error: {} (kind: {:?}, errno: {:?})",
                    session_id,
                    e,
                    e.kind(),
                    e.raw_os_error()
                );
                break;
            }
        }
    }

    // Get exit code
    let exit_code = {
        let mut inner = session.inner.lock();
        inner
            .child
            .try_wait()
            .ok()
            .flatten()
            .map(|s| s.exit_code().try_into().unwrap_or(1))
    };

    info!(
        "[reader:{}] Process exited with code: {:?}",
        session_id, exit_code
    );

    // Send exit event to terminal-specific subscribers
    // Prefix with \x00 to distinguish control messages from regular PTY output
    let exit_json = serde_json::to_string(&ServerEvent::Exit { exit_code }).unwrap_or_default();
    let exit_msg = format!("\x00{}", exit_json);
    let _ = session.output_tx.send(exit_msg);

    // Clean up: remove session from state and broadcast deletion
    let session_count = {
        let mut sessions = state.sessions.write();
        sessions.remove(&session_id);
        sessions.len()
    };
    state.reindex_sessions();

    info!(
        "[reader:{}] Session removed from state. Remaining sessions: {}",
        session_id, session_count
    );

    state.broadcast_event(ServerEvent::PtyDeleted {
        pty_id: session_id.clone(),
    });

    info!(
        "[reader:{}] Cleanup complete. Broadcast pty_deleted event.",
        session_id
    );
}

// =============================================================================
// Session Creation Helper
// =============================================================================

fn create_pty_session_inner(
    state: &AppState,
    request: &CreateSessionRequest,
) -> Result<(Arc<PtySession>, Box<dyn Read + Send>), ServerError> {
    let pty_system = native_pty_system();

    let pair = pty_system
        .openpty(PtySize {
            rows: request.rows,
            cols: request.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| ServerError::PtySpawnError(e.to_string()))?;

    let mut cmd = CommandBuilder::new(&request.shell);
    cmd.cwd(&request.cwd);
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.env("SHELL", &request.shell);

    if let Some(env) = &request.env {
        for (key, value) in env {
            cmd.env(key, value);
        }
    }

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| ServerError::PtySpawnError(e.to_string()))?;

    let pid = child.process_id().unwrap_or(0);

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| ServerError::PtySpawnError(e.to_string()))?;

    let writer = pair
        .master
        .take_writer()
        .map_err(|e| ServerError::PtySpawnError(e.to_string()))?;

    let session_id = Uuid::new_v4().to_string();
    let name = request
        .name
        .clone()
        .unwrap_or_else(|| state.get_next_terminal_name(&request.shell));

    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);

    let (output_tx, _) = broadcast::channel(1024);

    // Create bounded channel for input with backpressure
    let (input_tx, input_rx) = std::sync::mpsc::sync_channel(PTY_INPUT_CHANNEL_SIZE);

    // Spawn dedicated writer thread
    spawn_pty_writer_thread(session_id.clone(), writer, input_rx);

    let index = state.sessions.read().len();

    let session = Arc::new(PtySession {
        id: session_id,
        inner: Mutex::new(PtySessionInner {
            master: pair.master,
            child,
        }),
        shell: request.shell.clone(),
        cwd: request.cwd.clone(),
        name: RwLock::new(name),
        index: RwLock::new(index),
        created_at,
        cols: RwLock::new(request.cols),
        rows: RwLock::new(request.rows),
        scrollback: RwLock::new(String::new()),
        output_tx,
        input_tx,
        pid,
        metadata: RwLock::new(request.metadata.clone()),
        da_filter: Mutex::new(DaFilter::new()),
        terminal: Mutex::new(VirtualTerminal::new(
            request.rows as usize,
            request.cols as usize,
        )),
    });

    Ok((session, reader))
}

// =============================================================================
// HTTP Handlers
// =============================================================================

async fn index_handler() -> Html<&'static str> {
    Html(INDEX_HTML)
}

async fn health(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let sessions = state.sessions.read();
    Json(serde_json::json!({
        "status": "ok",
        "sessions": sessions.len()
    }))
}

async fn list_sessions(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(serde_json::json!({
        "sessions": state.get_ordered_sessions()
    }))
}

async fn create_session(
    State(state): State<Arc<AppState>>,
    Json(request): Json<CreateSessionRequest>,
) -> Result<impl IntoResponse, ServerError> {
    let client_id = request.client_id.clone();

    info!(
        "[http] POST /sessions - shell={}, cwd={}, client={:?}",
        request.shell, request.cwd, client_id
    );

    let (session, reader) = create_pty_session_inner(&state, &request)?;
    let info = session.to_info();
    let session_id = session.id.clone();

    let session_count = {
        let mut sessions = state.sessions.write();
        sessions.insert(session_id.clone(), session.clone());
        sessions.len()
    };

    info!(
        "[http] Session created: {} (pid: {}, total sessions: {})",
        session_id, info.pid, session_count
    );

    // Spawn reader task
    tokio::spawn(spawn_pty_reader(session, reader, state.clone()));

    // Broadcast event
    state.broadcast_event(ServerEvent::PtyCreated {
        terminal: info.clone(),
        creator_client_id: client_id,
    });

    Ok(Json(info))
}

async fn update_session(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
    Json(request): Json<UpdateSessionRequest>,
) -> Result<impl IntoResponse, ServerError> {
    let mut changes = HashMap::new();

    let session = {
        let sessions = state.sessions.read();
        sessions
            .get(&session_id)
            .cloned()
            .ok_or_else(|| ServerError::SessionNotFound(session_id.clone()))?
    };

    if let Some(new_name) = request.name {
        let old_name = session.name.read().clone();
        if new_name != old_name {
            session.set_name(new_name.clone());
            changes.insert("name".to_string(), serde_json::json!(new_name));
        }
    }

    if let Some(new_index) = request.index {
        let old_index = session.get_index();
        let sessions = state.sessions.read();
        let max_index = sessions.len().saturating_sub(1);
        let new_index = new_index.min(max_index);

        if new_index != old_index {
            // Shift other sessions
            if new_index < old_index {
                for s in sessions.values() {
                    let idx = s.get_index();
                    if s.id != session_id && idx >= new_index && idx < old_index {
                        s.set_index(idx + 1);
                    }
                }
            } else {
                for s in sessions.values() {
                    let idx = s.get_index();
                    if s.id != session_id && idx > old_index && idx <= new_index {
                        s.set_index(idx - 1);
                    }
                }
            }

            session.set_index(new_index);
            changes.insert("index".to_string(), serde_json::json!(new_index));
        }
    }

    if let Some(new_metadata) = request.metadata {
        session.set_metadata(Some(new_metadata.clone()));
        changes.insert("metadata".to_string(), new_metadata);
    }

    state.reindex_sessions();

    let info = session.to_info();

    if !changes.is_empty() {
        state.broadcast_event(ServerEvent::PtyUpdated {
            terminal: info.clone(),
            changes,
        });
    }

    Ok(Json(info))
}

async fn delete_session(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
) -> Result<impl IntoResponse, ServerError> {
    info!("[http] DELETE /sessions/{}", session_id);

    let (session, remaining) = {
        let mut sessions = state.sessions.write();
        let session = sessions.remove(&session_id).ok_or_else(|| {
            warn!("[http] Session not found: {}", session_id);
            ServerError::SessionNotFound(session_id.clone())
        })?;
        (session, sessions.len())
    };

    info!(
        "[http] Killing session {} (remaining: {})",
        session_id, remaining
    );

    session.kill();

    state.reindex_sessions();
    state.broadcast_event(ServerEvent::PtyDeleted {
        pty_id: session_id.clone(),
    });

    info!("[http] Session {} deleted successfully", session_id);

    Ok(Json(serde_json::json!({
        "status": "terminated",
        "id": session_id
    })))
}

async fn capture_session(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<impl IntoResponse, ServerError> {
    let sessions = state.sessions.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| ServerError::SessionNotFound(session_id.clone()))?;

    // Check if client wants processed terminal content
    let processed = params
        .get("processed")
        .map(|v| v == "true")
        .unwrap_or(false);
    let viewport_only = params.get("viewport").map(|v| v == "true").unwrap_or(false);

    if processed {
        // Return ANSI-processed terminal content (plain text)
        let lines = if viewport_only {
            session.get_terminal_viewport()
        } else {
            session.get_terminal_content()
        };
        let content = lines.join("\n");
        Ok(Json(serde_json::json!({
            "content": content,
            "lines": lines.len(),
            "processed": true
        })))
    } else {
        // Return raw scrollback (with ANSI sequences preserved)
        let content = session.get_scrollback();
        Ok(Json(serde_json::json!({
            "content": content,
            "length": content.len(),
            "processed": false
        })))
    }
}

#[derive(Debug, Clone, Deserialize)]
struct ResizeRequest {
    cols: u16,
    rows: u16,
}

async fn resize_session(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
    Json(request): Json<ResizeRequest>,
) -> Result<impl IntoResponse, ServerError> {
    let sessions = state.sessions.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| ServerError::SessionNotFound(session_id.clone()))?;

    session
        .resize(request.cols, request.rows)
        .map_err(|e| ServerError::PtySpawnError(e.to_string()))?;

    let info = session.to_info();

    // Broadcast update
    let mut changes = HashMap::new();
    changes.insert("cols".to_string(), serde_json::json!(request.cols));
    changes.insert("rows".to_string(), serde_json::json!(request.rows));

    drop(sessions); // Release lock before broadcast
    state.broadcast_event(ServerEvent::PtyUpdated {
        terminal: info.clone(),
        changes,
    });

    Ok(Json(info))
}

#[derive(Debug, Clone, Deserialize)]
struct InputRequest {
    data: String,
}

async fn send_input(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
    Json(request): Json<InputRequest>,
) -> Result<impl IntoResponse, ServerError> {
    let sessions = state.sessions.read();
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| ServerError::SessionNotFound(session_id.clone()))?;

    session
        .write_input(&request.data)
        .map_err(|e| ServerError::PtySpawnError(e.to_string()))?;

    Ok(Json(serde_json::json!({
        "status": "ok",
        "bytes": request.data.len()
    })))
}

#[derive(Debug, Clone, Deserialize)]
struct SignalRequest {
    /// Signal number to send (e.g., 10 for SIGUSR1, 12 for SIGUSR2)
    signum: i32,
    /// Optional: only send to specific session. If not provided, sends to all sessions.
    session_id: Option<String>,
}

/// Send a signal to PTY child processes.
/// Used for theme change notifications (SIGUSR1) and other process-level signals.
async fn send_signal(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SignalRequest>,
) -> Result<impl IntoResponse, ServerError> {
    use nix::sys::signal::{kill, Signal};
    use nix::unistd::Pid;

    // Convert signal number to Signal enum
    let signal = Signal::try_from(request.signum).map_err(|_| {
        ServerError::PtySpawnError(format!("Invalid signal number: {}", request.signum))
    })?;

    let sessions = state.sessions.read();
    let mut sent_count = 0;
    let mut errors = Vec::new();

    // Determine which sessions to signal
    let sessions_to_signal: Vec<_> = if let Some(session_id) = &request.session_id {
        sessions
            .get(session_id)
            .map(|s| vec![s.clone()])
            .unwrap_or_default()
    } else {
        sessions.values().cloned().collect()
    };

    drop(sessions);

    for session in sessions_to_signal {
        if session.is_alive() {
            let pid = Pid::from_raw(session.pid as i32);
            match kill(pid, signal) {
                Ok(()) => {
                    info!(
                        "[signal] Sent {} to session {} (pid {})",
                        signal, session.id, session.pid
                    );
                    sent_count += 1;
                }
                Err(e) => {
                    warn!(
                        "[signal] Failed to send {} to session {} (pid {}): {}",
                        signal, session.id, session.pid, e
                    );
                    errors.push(format!("{}: {}", session.id, e));
                }
            }
        }
    }

    if errors.is_empty() {
        Ok(Json(serde_json::json!({
            "status": "ok",
            "signal": request.signum,
            "sent_count": sent_count
        })))
    } else {
        Ok(Json(serde_json::json!({
            "status": "partial",
            "signal": request.signum,
            "sent_count": sent_count,
            "errors": errors
        })))
    }
}

// =============================================================================
// WebSocket Handlers
// =============================================================================

async fn websocket_events(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(|socket| handle_event_websocket(socket, state))
}

async fn handle_event_websocket(socket: WebSocket, state: Arc<AppState>) {
    let (mut sender, mut receiver) = socket.split();
    let mut event_rx = state.event_tx.subscribe();

    let ws_id = uuid::Uuid::new_v4().to_string()[..8].to_string();
    info!("[events-ws:{}] Event subscriber connected", ws_id);

    // Send initial state
    let initial_state = state.get_full_state();
    let terminal_count = match &initial_state {
        ServerEvent::StateSync { terminals } => terminals.len(),
        _ => 0,
    };
    info!(
        "[events-ws:{}] Sending initial state_sync with {} terminals",
        ws_id, terminal_count
    );

    if let Ok(json) = serde_json::to_string(&initial_state) {
        if sender.send(Message::Text(json)).await.is_err() {
            warn!("[events-ws:{}] Failed to send initial state", ws_id);
            return;
        }
    }

    // Spawn task to forward events to WebSocket
    let ws_id_clone = ws_id.clone();
    let send_task = tokio::spawn(async move {
        let mut event_count = 0usize;
        while let Ok(event) = event_rx.recv().await {
            event_count += 1;
            let event_type = match &event {
                ServerEvent::StateSync { .. } => "state_sync",
                ServerEvent::PtyCreated { .. } => "pty_created",
                ServerEvent::PtyUpdated { .. } => "pty_updated",
                ServerEvent::PtyDeleted { .. } => "pty_deleted",
                ServerEvent::Output { .. } => "output",
                ServerEvent::Exit { .. } => "exit",
                ServerEvent::Error { .. } => "error",
            };
            info!(
                "[events-ws:{}] Forwarding event #{}: {}",
                ws_id_clone, event_count, event_type
            );

            if let Ok(json) = serde_json::to_string(&event) {
                if sender.send(Message::Text(json)).await.is_err() {
                    warn!("[events-ws:{}] Failed to send event, closing", ws_id_clone);
                    break;
                }
            }
        }
        info!(
            "[events-ws:{}] Send task finished after {} events",
            ws_id_clone, event_count
        );
    });

    // Handle incoming messages
    while let Some(msg) = receiver.next().await {
        let msg = match msg {
            Ok(Message::Text(text)) => text,
            Ok(Message::Close(_)) => break,
            Ok(_) => continue,
            Err(e) => {
                warn!("WebSocket receive error: {}", e);
                break;
            }
        };

        let client_msg: ClientMessage = match serde_json::from_str(&msg) {
            Ok(m) => m,
            Err(e) => {
                warn!("Invalid client message: {}", e);
                continue;
            }
        };

        match client_msg {
            ClientMessage::GetState => {
                state.broadcast_state_sync();
            }
            ClientMessage::CreatePty {
                shell,
                cwd,
                cols,
                rows,
                name,
                client_id,
                metadata,
            } => {
                let request = CreateSessionRequest {
                    shell: shell.unwrap_or_else(default_shell),
                    cwd: cwd.unwrap_or_else(default_cwd),
                    cols: cols.unwrap_or_else(default_cols),
                    rows: rows.unwrap_or_else(default_rows),
                    env: None,
                    name,
                    client_id: client_id.clone(),
                    metadata,
                };

                match create_pty_session_inner(&state, &request) {
                    Ok((session, reader)) => {
                        let info = session.to_info();
                        let session_id = session.id.clone();

                        {
                            let mut sessions = state.sessions.write();
                            sessions.insert(session_id, session.clone());
                        }

                        tokio::spawn(spawn_pty_reader(session, reader, state.clone()));

                        state.broadcast_event(ServerEvent::PtyCreated {
                            terminal: info,
                            creator_client_id: client_id,
                        });
                    }
                    Err(e) => {
                        state.broadcast_event(ServerEvent::Error {
                            error: e.to_string(),
                        });
                    }
                }
            }
            ClientMessage::RenamePty { pty_id, name } => {
                let mut changes = HashMap::new();
                let info = {
                    let sessions = state.sessions.read();
                    if let Some(session) = sessions.get(&pty_id) {
                        session.set_name(name.clone());
                        changes.insert("name".to_string(), serde_json::json!(name));
                        Some(session.to_info())
                    } else {
                        None
                    }
                };

                if let Some(info) = info {
                    state.broadcast_event(ServerEvent::PtyUpdated {
                        terminal: info,
                        changes,
                    });
                }
            }
            ClientMessage::ReorderPty { pty_id, index } => {
                {
                    let sessions = state.sessions.read();
                    if let Some(session) = sessions.get(&pty_id) {
                        let old_index = session.get_index();
                        let max_index = sessions.len().saturating_sub(1);
                        let new_index = index.min(max_index);

                        if new_index != old_index {
                            if new_index < old_index {
                                for s in sessions.values() {
                                    let idx = s.get_index();
                                    if s.id != pty_id && idx >= new_index && idx < old_index {
                                        s.set_index(idx + 1);
                                    }
                                }
                            } else {
                                for s in sessions.values() {
                                    let idx = s.get_index();
                                    if s.id != pty_id && idx > old_index && idx <= new_index {
                                        s.set_index(idx - 1);
                                    }
                                }
                            }
                            session.set_index(new_index);
                        }
                    }
                }

                state.reindex_sessions();
                state.broadcast_state_sync();
            }
            ClientMessage::DeletePty { pty_id } => {
                let session = {
                    let mut sessions = state.sessions.write();
                    sessions.remove(&pty_id)
                };

                if let Some(session) = session {
                    session.kill();
                }

                state.reindex_sessions();
                state.broadcast_event(ServerEvent::PtyDeleted { pty_id });
            }
        }
    }

    send_task.abort();
    info!("Event subscriber disconnected");
}

async fn websocket_terminal(
    ws: WebSocketUpgrade,
    Path(session_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<impl IntoResponse, ServerError> {
    // Verify session exists and get data
    let (scrollback, output_rx) = {
        let sessions = state.sessions.read();
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| ServerError::SessionNotFound(session_id.clone()))?;
        (session.get_scrollback(), session.output_tx.subscribe())
    };

    let session = {
        let sessions = state.sessions.read();
        sessions.get(&session_id).cloned()
    };

    let session = session.ok_or_else(|| ServerError::SessionNotFound(session_id.clone()))?;

    Ok(ws.on_upgrade(move |socket| {
        handle_terminal_websocket(socket, session, scrollback, output_rx)
    }))
}

async fn handle_terminal_websocket(
    socket: WebSocket,
    session: Arc<PtySession>,
    scrollback: String,
    mut output_rx: broadcast::Receiver<String>,
) {
    let (mut sender, mut receiver) = socket.split();
    let session_id = session.id.clone();

    info!(
        "[term-ws:{}] Terminal WebSocket connected (scrollback: {} bytes)",
        session_id,
        scrollback.len()
    );

    // Send scrollback as raw binary (xterm expects raw data)
    if !scrollback.is_empty() {
        info!(
            "[term-ws:{}] Sending scrollback: {} bytes",
            session_id,
            scrollback.len()
        );
        if sender
            .send(Message::Binary(scrollback.into_bytes()))
            .await
            .is_err()
        {
            warn!("[term-ws:{}] Failed to send scrollback", session_id);
            return;
        }
    }

    // Spawn task to forward PTY output to WebSocket as raw binary
    let session_id_clone = session_id.clone();
    let send_task = tokio::spawn(async move {
        let mut output_count = 0usize;
        let mut total_bytes = 0usize;

        while let Ok(data) = output_rx.recv().await {
            output_count += 1;
            total_bytes += data.len();

            // Send raw binary data (xterm AttachAddon expects this)
            if sender
                .send(Message::Binary(data.into_bytes()))
                .await
                .is_err()
            {
                warn!(
                    "[term-ws:{}] Failed to send output, closing",
                    session_id_clone
                );
                break;
            }
        }

        info!(
            "[term-ws:{}] Output forwarder finished. Sent {} messages, {} bytes total",
            session_id_clone, output_count, total_bytes
        );
    });

    // Handle incoming messages (xterm sends raw text/binary for input, JSON for resize)
    let mut input_count = 0usize;
    let mut input_bytes = 0usize;

    while let Some(msg) = receiver.next().await {
        match msg {
            Ok(Message::Binary(data)) => {
                // Raw binary input from xterm
                input_count += 1;
                input_bytes += data.len();

                if data.len() > 100 {
                    info!(
                        "[term-ws:{}] Large binary input: {} bytes",
                        session_id,
                        data.len()
                    );
                }

                if let Ok(text) = String::from_utf8(data) {
                    if let Err(e) = session.write_input(&text) {
                        error!("[term-ws:{}] Failed to write to PTY: {}", session_id, e);
                    }
                }
            }
            Ok(Message::Text(text)) => {
                // Could be JSON control message or raw text input
                // Try parsing as JSON first (for resize commands)
                if text.starts_with('{') {
                    if let Ok(ctrl) = serde_json::from_str::<serde_json::Value>(&text) {
                        if let Some(typ) = ctrl.get("type").and_then(|t| t.as_str()) {
                            match typ {
                                "resize" => {
                                    let cols =
                                        ctrl.get("cols").and_then(|c| c.as_u64()).unwrap_or(80)
                                            as u16;
                                    let rows =
                                        ctrl.get("rows").and_then(|r| r.as_u64()).unwrap_or(24)
                                            as u16;
                                    info!("[term-ws:{}] Resize: {}x{}", session_id, cols, rows);
                                    if let Err(e) = session.resize(cols, rows) {
                                        error!(
                                            "[term-ws:{}] Failed to resize PTY: {}",
                                            session_id, e
                                        );
                                    }
                                }
                                "input" => {
                                    if let Some(data) = ctrl.get("data").and_then(|d| d.as_str()) {
                                        input_count += 1;
                                        input_bytes += data.len();
                                        if let Err(e) = session.write_input(data) {
                                            error!(
                                                "[term-ws:{}] Failed to write to PTY: {}",
                                                session_id, e
                                            );
                                        }
                                    }
                                }
                                _ => {}
                            }
                            continue;
                        }
                    }
                }
                // Raw text input from xterm
                input_count += 1;
                input_bytes += text.len();

                if text.len() > 100 {
                    info!(
                        "[term-ws:{}] Large text input: {} bytes",
                        session_id,
                        text.len()
                    );
                }

                if let Err(e) = session.write_input(&text) {
                    error!("[term-ws:{}] Failed to write to PTY: {}", session_id, e);
                }
            }
            Ok(Message::Close(reason)) => {
                info!(
                    "[term-ws:{}] Client sent close frame: {:?}",
                    session_id, reason
                );
                break;
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => continue,
            Err(e) => {
                warn!("[term-ws:{}] WebSocket receive error: {}", session_id, e);
                break;
            }
        }
    }

    send_task.abort();
    info!(
        "[term-ws:{}] Disconnected. Total input: {} messages, {} bytes",
        session_id, input_count, input_bytes
    );
}

// =============================================================================
// Main
// =============================================================================

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        // Server mode
        Some(Commands::Server { host, port }) => run_server(&host, port).await,

        // No command = server mode (for backwards compatibility)
        None => {
            let host = env::var("PTY_SERVER_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
            let port: u16 = env::var("PTY_SERVER_PORT")
                .unwrap_or_else(|_| "39383".to_string())
                .parse()
                .context("Invalid PTY_SERVER_PORT")?;
            run_server(&host, port).await
        }

        // Client commands - create config for socket + HTTP fallback
        Some(Commands::List { json }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_list(config, json).await
        }

        Some(Commands::New {
            name,
            shell,
            cwd,
            detached,
        }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_new(config, name, shell, cwd, detached).await
        }

        Some(Commands::Attach { session }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_attach(config, &session).await
        }

        Some(Commands::Kill { sessions }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_kill(config, &sessions).await
        }

        Some(Commands::SendKeys { session, keys }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_send_keys(config, &session, &keys).await
        }

        Some(Commands::CapturePane { session, print }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_capture_pane(config, &session, print).await
        }

        Some(Commands::Resize {
            session,
            cols,
            rows,
        }) => {
            let config = cli::PtyClientConfig::new(
                cli.server.clone(),
                cli.socket.clone(),
                cli.sandbox_id.clone(),
            );
            cli::cmd_resize(config, &session, cols, rows).await
        }
    }
}

async fn run_server(host: &str, port: u16) -> Result<()> {
    // Debug output to ensure binary is running
    eprintln!("[pty-server] Starting...");
    std::io::Write::flush(&mut std::io::stderr()).ok();

    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .init();

    eprintln!("[pty-server] Logging initialized");

    let state = Arc::new(AppState::new());

    let app = Router::new()
        // Static frontend
        .route("/", get(index_handler))
        .route("/index.html", get(index_handler))
        // HTTP endpoints
        .route("/health", get(health))
        .route("/sessions", get(list_sessions))
        .route("/sessions", post(create_session))
        .route("/sessions/:session_id", patch(update_session))
        .route("/sessions/:session_id", delete(delete_session))
        .route("/sessions/:session_id/capture", get(capture_session))
        .route("/sessions/:session_id/resize", post(resize_session))
        .route("/sessions/:session_id/input", post(send_input))
        .route("/signal", post(send_signal))
        // WebSocket endpoints
        .route("/ws", get(websocket_events))
        .route("/sessions/:session_id/ws", get(websocket_terminal))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = format!("{}:{}", host, port);
    info!("Starting PTY server on {}", addr);
    eprintln!("[pty-server] Binding to {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .context("Failed to bind to address")?;

    eprintln!("[pty-server] Server running on {}", addr);
    info!("PTY server running on {}", addr);

    axum::serve(listener, app).await.context("Server error")?;

    Ok(())
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    fn create_test_app() -> Router {
        let state = Arc::new(AppState::new());
        Router::new()
            .route("/health", get(health))
            .route("/sessions", get(list_sessions))
            .route("/sessions", post(create_session))
            .route("/sessions/:session_id", patch(update_session))
            .route("/sessions/:session_id", delete(delete_session))
            .route("/ws", get(websocket_events))
            .route("/sessions/:session_id/ws", get(websocket_terminal))
            .layer(CorsLayer::permissive())
            .with_state(state)
    }

    #[tokio::test]
    async fn test_health_endpoint() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_list_sessions_empty() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/sessions")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_session() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/sessions")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"shell": "/bin/sh", "cwd": "/tmp"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_session_not_found() {
        let app = create_test_app();

        let response = app
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/sessions/nonexistent-id")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    /// Test moderate input size (small enough to not block)
    #[tokio::test]
    async fn test_pty_moderate_input() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Test writing moderate input (1KB) - should work without blocking
        let input = "a".repeat(1000);
        let result = session.write_input(&input);
        assert!(
            result.is_ok(),
            "Moderate input should not fail: {:?}",
            result.err()
        );

        session.kill();
    }

    /// Test sequential writes with small delay (simulates typing)
    #[tokio::test]
    async fn test_pty_sequential_writes() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Write 10 small commands with delay to allow shell to process
        for i in 0..10 {
            let input = format!("echo test{}\n", i);
            let result = session.write_input(&input);
            assert!(result.is_ok(), "Write {} failed: {:?}", i, result.err());
            tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
        }

        session.kill();
    }

    /// Test large input - should complete without blocking thanks to
    /// the dedicated writer thread and chunked writes.
    #[tokio::test]
    async fn test_pty_large_input() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Test with 10KB of input - should work smoothly with new architecture
        let large_input = "a".repeat(10_000);
        let result = session.write_input(&large_input);
        assert!(
            result.is_ok(),
            "Large input should succeed: {:?}",
            result.err()
        );

        // Test with 50KB of input
        let very_large_input = "b".repeat(50_000);
        let result = session.write_input(&very_large_input);
        assert!(
            result.is_ok(),
            "Very large input should succeed: {:?}",
            result.err()
        );

        // Give time for the writer thread to process
        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;

        session.kill();
    }

    /// Test rapid large pastes (simulates user pasting multiple times quickly)
    #[tokio::test]
    async fn test_pty_rapid_large_pastes() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Rapid paste simulation - 5 pastes of 5KB each
        for i in 0..5 {
            let paste = format!("# Paste {} {}\n", i, "x".repeat(5000));
            let result = session.write_input(&paste);
            assert!(
                result.is_ok(),
                "Paste {} should succeed: {:?}",
                i,
                result.err()
            );
        }

        // Give time for processing
        tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;

        session.kill();
    }

    /// Test resize during activity
    #[tokio::test]
    async fn test_pty_resize_during_activity() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            cols: 80,
            rows: 24,
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Write and resize concurrently
        for i in 0..20 {
            session.write_input(&format!("echo line{}\n", i)).unwrap();
            session
                .resize(80 + (i as u16 % 40), 24 + (i as u16 % 10))
                .unwrap();
        }

        session.kill();
    }

    /// Test scrollback buffer limits
    #[tokio::test]
    async fn test_scrollback_limit() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, _reader) = create_pty_session_inner(&state, &request).unwrap();

        // Append more than MAX_SCROLLBACK
        let large_data = "x".repeat(MAX_SCROLLBACK + 10_000);
        session.append_scrollback(&large_data);

        let scrollback = session.get_scrollback();
        assert!(
            scrollback.len() <= MAX_SCROLLBACK,
            "Scrollback should be limited to {} but was {}",
            MAX_SCROLLBACK,
            scrollback.len()
        );

        session.kill();
    }

    /// Test capture endpoint returns scrollback content
    #[tokio::test]
    async fn test_capture_endpoint() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        let session_id = session.id.clone();

        {
            let mut sessions = state.sessions.write();
            sessions.insert(session_id.clone(), session.clone());
        }

        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        // Write something to generate scrollback
        session.write_input("echo hello\n").unwrap();
        tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;

        // Test capture endpoint
        let app = Router::new()
            .route("/sessions/:session_id/capture", get(capture_session))
            .with_state(state.clone());

        let response = app
            .oneshot(
                Request::builder()
                    .uri(format!("/sessions/{}/capture", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        session.kill();
    }

    /// Test resize endpoint
    #[tokio::test]
    async fn test_resize_endpoint() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            cols: 80,
            rows: 24,
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        let session_id = session.id.clone();

        {
            let mut sessions = state.sessions.write();
            sessions.insert(session_id.clone(), session.clone());
        }

        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));

        // Test resize endpoint
        let app = Router::new()
            .route("/sessions/:session_id/resize", post(resize_session))
            .with_state(state.clone());

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/sessions/{}/resize", session_id))
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"cols": 120, "rows": 40}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        // Verify dimensions changed
        assert_eq!(*session.cols.read(), 120);
        assert_eq!(*session.rows.read(), 40);

        session.kill();
    }

    /// Test input endpoint
    #[tokio::test]
    async fn test_input_endpoint() {
        let state = Arc::new(AppState::new());

        let request = CreateSessionRequest {
            shell: "/bin/sh".to_string(),
            cwd: "/tmp".to_string(),
            ..Default::default()
        };

        let (session, reader) = create_pty_session_inner(&state, &request).unwrap();
        let session_id = session.id.clone();

        {
            let mut sessions = state.sessions.write();
            sessions.insert(session_id.clone(), session.clone());
        }

        tokio::spawn(spawn_pty_reader(session.clone(), reader, state.clone()));
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        // Test input endpoint
        let app = Router::new()
            .route("/sessions/:session_id/input", post(send_input))
            .with_state(state.clone());

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/sessions/{}/input", session_id))
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"data": "echo test\n"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);

        session.kill();
    }
}
