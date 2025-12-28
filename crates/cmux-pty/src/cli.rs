//! CLI client for cmux-pty server
//!
//! Provides tmux-like commands for managing PTY sessions.
//! Uses bridge socket when available, falls back to HTTP.

use std::io::Write;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use base64::Engine;
use crossterm::{
    event::{self, Event, KeyCode, KeyModifiers},
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[cfg(unix)]
use std::os::unix::fs::FileTypeExt;

// =============================================================================
// Types (shared with server)
// =============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: String,
    pub name: String,
    pub index: usize,
    pub shell: String,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub created_at: f64,
    pub alive: bool,
    pub pid: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionListResponse {
    pub sessions: Vec<SessionInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSessionRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shell: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResizeRequest {
    pub cols: u16,
    pub rows: u16,
}

// =============================================================================
// Bridge Socket Types (from sandboxd models)
// =============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BridgeRequest {
    PtyList {
        sandbox_id: String,
    },
    PtyGet {
        sandbox_id: String,
        session_id: String,
    },
    PtyCreate {
        sandbox_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        command: String,
        args: Vec<String>,
        cols: u16,
        rows: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        env: Option<std::collections::HashMap<String, String>>,
    },
    PtyInput {
        sandbox_id: String,
        session_id: String,
        data: String, // base64 encoded
    },
    PtyResize {
        sandbox_id: String,
        session_id: String,
        cols: u16,
        rows: u16,
    },
    PtyCapture {
        sandbox_id: String,
        session_id: String,
    },
    PtyDelete {
        sandbox_id: String,
        session_id: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BridgeResponse {
    Ok,
    Error {
        message: String,
    },
    PtyList {
        sessions: Vec<BridgeSessionInfo>,
    },
    PtySession {
        session: Option<BridgeSessionInfo>,
    },
    PtyCreated {
        session: BridgeSessionInfo,
    },
    PtyCapture {
        content: String,
        cursor_x: u16,
        cursor_y: u16,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeSessionInfo {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub exited: bool,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub pid: Option<u32>,
}

impl BridgeSessionInfo {
    /// Convert to the HTTP-style SessionInfo for display
    pub fn to_session_info(&self, index: usize) -> SessionInfo {
        SessionInfo {
            id: self.id.clone(),
            name: self
                .name
                .clone()
                .unwrap_or_else(|| format!("session-{}", index)),
            index,
            shell: self.command.clone(),
            cwd: self.cwd.clone(),
            cols: self.cols,
            rows: self.rows,
            created_at: 0.0,
            alive: !self.exited,
            pid: self.pid.unwrap_or(0),
        }
    }
}

// =============================================================================
// Socket Helper
// =============================================================================

fn socket_available(path: &str) -> bool {
    #[cfg(unix)]
    {
        let path = Path::new(path);
        if let Ok(metadata) = std::fs::metadata(path) {
            return metadata.file_type().is_socket();
        }
    }
    false
}

async fn send_bridge_request(socket_path: &str, request: &BridgeRequest) -> Result<BridgeResponse> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .with_context(|| format!("failed to connect to socket {socket_path}"))?;

    let payload = serde_json::to_string(request)?;
    stream.write_all(payload.as_bytes()).await?;
    stream.write_all(b"\n").await?;
    stream.flush().await?;

    let mut reader = BufReader::new(stream);
    let mut response_line = String::new();
    reader.read_line(&mut response_line).await?;

    let response: BridgeResponse =
        serde_json::from_str(response_line.trim()).context("failed to parse bridge response")?;

    Ok(response)
}

// =============================================================================
// Client Configuration
// =============================================================================

#[derive(Clone)]
pub struct PtyClientConfig {
    pub server_url: String,
    pub socket_path: String,
    pub sandbox_id: Option<String>,
}

impl PtyClientConfig {
    pub fn new(server_url: String, socket_path: String, sandbox_id: Option<String>) -> Self {
        Self {
            server_url,
            socket_path,
            sandbox_id,
        }
    }

    /// Check if socket is available and sandbox_id is set
    pub fn can_use_socket(&self) -> bool {
        self.sandbox_id.is_some() && socket_available(&self.socket_path)
    }
}

// =============================================================================
// Client
// =============================================================================

pub struct PtyClient {
    base_url: String,
    client: reqwest::Client,
    config: PtyClientConfig,
}

impl PtyClient {
    pub fn new(server_url: &str) -> Self {
        Self::with_config(PtyClientConfig::new(
            server_url.to_string(),
            "/run/cmux/bridge.sock".to_string(),
            std::env::var("CMUX_SANDBOX_ID").ok(),
        ))
    }

    pub fn with_config(config: PtyClientConfig) -> Self {
        let base_url = config.server_url.trim_end_matches('/').to_string();
        Self {
            base_url: base_url.clone(),
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .build()
                .expect("Failed to create HTTP client"),
            config,
        }
    }

    /// List all sessions
    pub async fn list_sessions(&self) -> Result<Vec<SessionInfo>> {
        // Try socket first
        if self.config.can_use_socket() {
            let sandbox_id = self.config.sandbox_id.as_ref().expect("sandbox_id checked");
            let request = BridgeRequest::PtyList {
                sandbox_id: sandbox_id.clone(),
            };
            match send_bridge_request(&self.config.socket_path, &request).await {
                Ok(BridgeResponse::PtyList { sessions }) => {
                    return Ok(sessions
                        .iter()
                        .enumerate()
                        .map(|(i, s)| s.to_session_info(i))
                        .collect());
                }
                Ok(BridgeResponse::Error { message }) => {
                    anyhow::bail!("Socket error: {}", message);
                }
                Ok(resp) => {
                    anyhow::bail!("Unexpected response: {:?}", resp);
                }
                Err(e) => {
                    eprintln!("Socket failed, falling back to HTTP: {}", e);
                }
            }
        }

        // Fallback to HTTP
        let url = format!("{}/sessions", self.base_url);
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .context("Failed to connect to server")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Server returned {}: {}", status, body);
        }

        let data: SessionListResponse = resp.json().await.context("Failed to parse response")?;
        Ok(data.sessions)
    }

    /// Create a new session
    pub async fn create_session(
        &self,
        name: Option<String>,
        shell: Option<String>,
        cwd: Option<String>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SessionInfo> {
        // Try socket first
        if self.config.can_use_socket() {
            let sandbox_id = self.config.sandbox_id.as_ref().expect("sandbox_id checked");
            let request = BridgeRequest::PtyCreate {
                sandbox_id: sandbox_id.clone(),
                name: name.clone(),
                command: shell.clone().unwrap_or_else(|| "/bin/zsh".to_string()),
                args: vec![],
                cols: cols.unwrap_or(80),
                rows: rows.unwrap_or(24),
                cwd: cwd.clone(),
                env: None,
            };
            match send_bridge_request(&self.config.socket_path, &request).await {
                Ok(BridgeResponse::PtyCreated { session }) => {
                    return Ok(session.to_session_info(0));
                }
                Ok(BridgeResponse::Error { message }) => {
                    anyhow::bail!("Socket error: {}", message);
                }
                Ok(resp) => {
                    anyhow::bail!("Unexpected response: {:?}", resp);
                }
                Err(e) => {
                    eprintln!("Socket failed, falling back to HTTP: {}", e);
                }
            }
        }

        // Fallback to HTTP
        let url = format!("{}/sessions", self.base_url);
        let request = CreateSessionRequest {
            shell,
            cwd,
            cols,
            rows,
            name,
        };

        let resp = self
            .client
            .post(&url)
            .json(&request)
            .send()
            .await
            .context("Failed to connect to server")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Server returned {}: {}", status, body);
        }

        let session: SessionInfo = resp.json().await.context("Failed to parse response")?;
        Ok(session)
    }

    /// Kill/delete a session
    pub async fn kill_session(&self, session_id: &str) -> Result<()> {
        let actual_id = self.resolve_session_id(session_id).await?;

        // Try socket first
        if self.config.can_use_socket() {
            let sandbox_id = self.config.sandbox_id.as_ref().expect("sandbox_id checked");
            let request = BridgeRequest::PtyDelete {
                sandbox_id: sandbox_id.clone(),
                session_id: actual_id.clone(),
            };
            match send_bridge_request(&self.config.socket_path, &request).await {
                Ok(BridgeResponse::Ok) => return Ok(()),
                Ok(BridgeResponse::Error { message }) => {
                    anyhow::bail!("Socket error: {}", message);
                }
                Ok(resp) => {
                    anyhow::bail!("Unexpected response: {:?}", resp);
                }
                Err(e) => {
                    eprintln!("Socket failed, falling back to HTTP: {}", e);
                }
            }
        }

        // Fallback to HTTP
        let url = format!("{}/sessions/{}", self.base_url, actual_id);
        let resp = self
            .client
            .delete(&url)
            .send()
            .await
            .context("Failed to connect to server")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Server returned {}: {}", status, body);
        }

        Ok(())
    }

    /// Send keys to a session
    pub async fn send_keys(&self, session_id: &str, keys: &str) -> Result<()> {
        let actual_id = self.resolve_session_id(session_id).await?;

        // Try socket first
        if self.config.can_use_socket() {
            let sandbox_id = self.config.sandbox_id.as_ref().expect("sandbox_id checked");
            let request = BridgeRequest::PtyInput {
                sandbox_id: sandbox_id.clone(),
                session_id: actual_id.clone(),
                data: base64::engine::general_purpose::STANDARD.encode(keys.as_bytes()),
            };
            match send_bridge_request(&self.config.socket_path, &request).await {
                Ok(BridgeResponse::Ok) => return Ok(()),
                Ok(BridgeResponse::Error { message }) => {
                    anyhow::bail!("Socket error: {}", message);
                }
                Ok(resp) => {
                    anyhow::bail!("Unexpected response: {:?}", resp);
                }
                Err(e) => {
                    eprintln!("Socket failed, falling back to HTTP: {}", e);
                }
            }
        }

        // Fallback to HTTP via WebSocket
        let ws_url = self.get_ws_url(&format!("/sessions/{}/ws", actual_id))?;

        let (mut ws_stream, _) = connect_async(&ws_url)
            .await
            .context("Failed to connect to WebSocket")?;

        // Send keys as binary (raw terminal input)
        ws_stream
            .send(Message::Binary(keys.as_bytes().to_vec()))
            .await
            .context("Failed to send keys")?;

        // Close gracefully
        ws_stream.close(None).await.ok();

        Ok(())
    }

    /// Capture pane content (scrollback buffer)
    pub async fn capture_pane(&self, session_id: &str) -> Result<String> {
        let actual_id = self.resolve_session_id(session_id).await?;

        // Try socket first
        if self.config.can_use_socket() {
            let sandbox_id = self.config.sandbox_id.as_ref().expect("sandbox_id checked");
            let request = BridgeRequest::PtyCapture {
                sandbox_id: sandbox_id.clone(),
                session_id: actual_id.clone(),
            };
            match send_bridge_request(&self.config.socket_path, &request).await {
                Ok(BridgeResponse::PtyCapture { content, .. }) => {
                    return Ok(content);
                }
                Ok(BridgeResponse::Error { message }) => {
                    anyhow::bail!("Socket error: {}", message);
                }
                Ok(resp) => {
                    anyhow::bail!("Unexpected response: {:?}", resp);
                }
                Err(e) => {
                    eprintln!("Socket failed, falling back to HTTP: {}", e);
                }
            }
        }

        // Fallback to HTTP
        let url = format!("{}/sessions/{}/capture", self.base_url, actual_id);

        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .context("Failed to connect to server")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Server returned {}: {}", status, body);
        }

        #[derive(Deserialize)]
        struct CaptureResponse {
            content: String,
        }

        let data: CaptureResponse = resp.json().await.context("Failed to parse response")?;
        Ok(data.content)
    }

    /// Resize a session
    pub async fn resize(&self, session_id: &str, cols: u16, rows: u16) -> Result<()> {
        let actual_id = self.resolve_session_id(session_id).await?;

        // Try socket first
        if self.config.can_use_socket() {
            let sandbox_id = self.config.sandbox_id.as_ref().expect("sandbox_id checked");
            let request = BridgeRequest::PtyResize {
                sandbox_id: sandbox_id.clone(),
                session_id: actual_id.clone(),
                cols,
                rows,
            };
            match send_bridge_request(&self.config.socket_path, &request).await {
                Ok(BridgeResponse::Ok) => return Ok(()),
                Ok(BridgeResponse::Error { message }) => {
                    anyhow::bail!("Socket error: {}", message);
                }
                Ok(resp) => {
                    anyhow::bail!("Unexpected response: {:?}", resp);
                }
                Err(e) => {
                    eprintln!("Socket failed, falling back to HTTP: {}", e);
                }
            }
        }

        // Fallback to HTTP
        let url = format!("{}/sessions/{}/resize", self.base_url, actual_id);

        let request = ResizeRequest { cols, rows };
        let resp = self
            .client
            .post(&url)
            .json(&request)
            .send()
            .await
            .context("Failed to connect to server")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("Server returned {}: {}", status, body);
        }

        Ok(())
    }

    /// Attach to a session interactively
    pub async fn attach(&self, session_id: &str) -> Result<()> {
        let actual_id = self.resolve_session_id(session_id).await?;
        let ws_url = self.get_ws_url(&format!("/sessions/{}/ws", actual_id))?;

        eprintln!("Attaching to session {}...", actual_id);
        eprintln!("Press Ctrl+B then D to detach");

        let (ws_stream, _) = connect_async(&ws_url)
            .await
            .context("Failed to connect to WebSocket")?;

        let (mut ws_sender, mut ws_receiver) = ws_stream.split();

        // Enable raw mode and enter alternate screen
        terminal::enable_raw_mode()?;
        let mut stdout = std::io::stdout();
        stdout.execute(EnterAlternateScreen)?;

        // Get terminal size and send resize (use fallback if terminal size can't be read)
        let (cols, rows) = terminal::size().unwrap_or((80, 24));
        let resize_msg = serde_json::json!({
            "type": "resize",
            "cols": cols,
            "rows": rows
        });
        ws_sender
            .send(Message::Text(resize_msg.to_string()))
            .await
            .ok();

        // Track if we're in the detach sequence (Ctrl+B pressed)
        let detach_prefix = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));

        // Spawn task to read from WebSocket and write to stdout
        let output_task = tokio::spawn(async move {
            while let Some(msg) = ws_receiver.next().await {
                match msg {
                    Ok(Message::Binary(data)) => {
                        let mut stdout = std::io::stdout();
                        stdout.write_all(&data).ok();
                        stdout.flush().ok();
                    }
                    Ok(Message::Text(text)) => {
                        // Could be control message or text output
                        if text.starts_with('\x00') {
                            // Control message (e.g., exit)
                            break;
                        }
                        let mut stdout = std::io::stdout();
                        stdout.write_all(text.as_bytes()).ok();
                        stdout.flush().ok();
                    }
                    Ok(Message::Close(_)) => break,
                    Err(_) => break,
                    _ => {}
                }
            }
        });

        // Read from stdin and send to WebSocket
        let input_result: Result<bool> = 'input: loop {
            // Poll for events with timeout
            if event::poll(Duration::from_millis(100))? {
                match event::read()? {
                    Event::Key(key_event) => {
                        // Check for detach sequence: Ctrl+B, D
                        if detach_prefix.load(std::sync::atomic::Ordering::SeqCst) {
                            detach_prefix.store(false, std::sync::atomic::Ordering::SeqCst);
                            if key_event.code == KeyCode::Char('d')
                                || key_event.code == KeyCode::Char('D')
                            {
                                break 'input Ok(true); // Detach requested
                            }
                            // Not 'd', send both Ctrl+B and this key
                            ws_sender
                                .send(Message::Binary(vec![0x02])) // Ctrl+B
                                .await
                                .ok();
                        }

                        // Check for Ctrl+B (detach prefix)
                        if key_event.modifiers.contains(KeyModifiers::CONTROL)
                            && key_event.code == KeyCode::Char('b')
                        {
                            detach_prefix.store(true, std::sync::atomic::Ordering::SeqCst);
                            continue;
                        }

                        // Convert key event to bytes
                        let data = key_event_to_bytes(&key_event);
                        if !data.is_empty() && ws_sender.send(Message::Binary(data)).await.is_err()
                        {
                            break 'input Ok(false);
                        }
                    }
                    Event::Resize(cols, rows) => {
                        let resize_msg = serde_json::json!({
                            "type": "resize",
                            "cols": cols,
                            "rows": rows
                        });
                        ws_sender
                            .send(Message::Text(resize_msg.to_string()))
                            .await
                            .ok();
                    }
                    _ => {}
                }
            }

            // Check if output task finished
            if output_task.is_finished() {
                break 'input Ok(false);
            }
        };

        // Cleanup
        output_task.abort();
        stdout.execute(LeaveAlternateScreen)?;
        terminal::disable_raw_mode()?;

        match input_result {
            Ok(true) => eprintln!("\nDetached from session {}", actual_id),
            Ok(false) => eprintln!("\nSession ended"),
            Err(e) => eprintln!("\nError: {}", e),
        }

        Ok(())
    }

    // Helper to resolve session name to ID
    async fn resolve_session_id(&self, session_id: &str) -> Result<String> {
        // If it looks like a UUID, use it directly
        if session_id.contains('-') && session_id.len() > 30 {
            return Ok(session_id.to_string());
        }

        // Try to find by name or partial ID
        let sessions = self.list_sessions().await?;

        // First try exact name match
        if let Some(s) = sessions.iter().find(|s| s.name == session_id) {
            return Ok(s.id.clone());
        }

        // Try partial ID match
        if let Some(s) = sessions.iter().find(|s| s.id.starts_with(session_id)) {
            return Ok(s.id.clone());
        }

        // Try index match (e.g., "0", "1")
        if let Ok(index) = session_id.parse::<usize>() {
            if let Some(s) = sessions.iter().find(|s| s.index == index) {
                return Ok(s.id.clone());
            }
        }

        anyhow::bail!("Session not found: {}", session_id)
    }

    fn get_ws_url(&self, path: &str) -> Result<String> {
        let http_url = format!("{}{}", self.base_url, path);
        let ws_url = http_url
            .replace("http://", "ws://")
            .replace("https://", "wss://");
        Ok(ws_url)
    }
}

// =============================================================================
// Key Event Conversion
// =============================================================================

fn key_event_to_bytes(key: &event::KeyEvent) -> Vec<u8> {
    use KeyCode::*;

    // Handle Ctrl+key combinations
    if key.modifiers.contains(KeyModifiers::CONTROL) {
        if let Char(c) = key.code {
            let c = c.to_ascii_lowercase();
            if c.is_ascii_lowercase() {
                return vec![(c as u8) - b'a' + 1];
            }
            if c == '[' {
                return vec![0x1b]; // ESC
            }
            if c == '\\' {
                return vec![0x1c];
            }
            if c == ']' {
                return vec![0x1d];
            }
            if c == '^' {
                return vec![0x1e];
            }
            if c == '_' {
                return vec![0x1f];
            }
        }
    }

    match key.code {
        Char(c) => {
            let mut buf = [0u8; 4];
            let s = c.encode_utf8(&mut buf);
            s.as_bytes().to_vec()
        }
        Enter => vec![b'\r'],
        Backspace => vec![0x7f],
        Tab => vec![b'\t'],
        Esc => vec![0x1b],
        Up => b"\x1b[A".to_vec(),
        Down => b"\x1b[B".to_vec(),
        Right => b"\x1b[C".to_vec(),
        Left => b"\x1b[D".to_vec(),
        Home => b"\x1b[H".to_vec(),
        End => b"\x1b[F".to_vec(),
        PageUp => b"\x1b[5~".to_vec(),
        PageDown => b"\x1b[6~".to_vec(),
        Delete => b"\x1b[3~".to_vec(),
        Insert => b"\x1b[2~".to_vec(),
        F(1) => b"\x1bOP".to_vec(),
        F(2) => b"\x1bOQ".to_vec(),
        F(3) => b"\x1bOR".to_vec(),
        F(4) => b"\x1bOS".to_vec(),
        F(5) => b"\x1b[15~".to_vec(),
        F(6) => b"\x1b[17~".to_vec(),
        F(7) => b"\x1b[18~".to_vec(),
        F(8) => b"\x1b[19~".to_vec(),
        F(9) => b"\x1b[20~".to_vec(),
        F(10) => b"\x1b[21~".to_vec(),
        F(11) => b"\x1b[23~".to_vec(),
        F(12) => b"\x1b[24~".to_vec(),
        _ => vec![],
    }
}

// =============================================================================
// CLI Commands
// =============================================================================

pub async fn cmd_list(config: PtyClientConfig, json: bool) -> Result<()> {
    let client = PtyClient::with_config(config);
    let sessions = client.list_sessions().await?;

    if json {
        println!("{}", serde_json::to_string_pretty(&sessions)?);
        return Ok(());
    }

    if sessions.is_empty() {
        println!("No sessions");
        return Ok(());
    }

    // Print header
    println!(
        "{:<4} {:<36} {:<20} {:<8} {:<10} {:<6}",
        "IDX", "ID", "NAME", "SIZE", "SHELL", "PID"
    );
    println!("{}", "-".repeat(90));

    for session in sessions {
        let shell_name = std::path::Path::new(&session.shell)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&session.shell);

        let status = if session.alive { "" } else { " (dead)" };

        println!(
            "{:<4} {:<36} {:<20} {:>3}x{:<4} {:<10} {:<6}{}",
            session.index,
            &session.id[..36.min(session.id.len())],
            &session.name[..20.min(session.name.len())],
            session.cols,
            session.rows,
            shell_name,
            session.pid,
            status
        );
    }

    Ok(())
}

pub async fn cmd_new(
    config: PtyClientConfig,
    name: Option<String>,
    shell: Option<String>,
    cwd: Option<String>,
    detached: bool,
) -> Result<()> {
    let client = PtyClient::with_config(config);

    // Get terminal size
    let (cols, rows) = terminal::size().unwrap_or((80, 24));

    let session = client
        .create_session(name, shell, cwd, Some(cols), Some(rows))
        .await?;

    println!("Created session: {} ({})", session.id, session.name);

    if !detached {
        client.attach(&session.id).await?;
    }

    Ok(())
}

pub async fn cmd_attach(config: PtyClientConfig, session: &str) -> Result<()> {
    let client = PtyClient::with_config(config);
    client.attach(session).await
}

pub async fn cmd_kill(config: PtyClientConfig, sessions: &[String]) -> Result<()> {
    let client = PtyClient::with_config(config);

    for session_id in sessions {
        match client.kill_session(session_id).await {
            Ok(()) => println!("Killed session: {}", session_id),
            Err(e) => eprintln!("Failed to kill {}: {}", session_id, e),
        }
    }

    Ok(())
}

pub async fn cmd_send_keys(config: PtyClientConfig, session: &str, keys: &[String]) -> Result<()> {
    let client = PtyClient::with_config(config);

    // Join keys with spaces and process escape sequences
    let text = keys.join(" ");
    let processed = process_key_string(&text);

    client.send_keys(session, &processed).await?;
    println!("Sent {} bytes to session", processed.len());

    Ok(())
}

pub async fn cmd_capture_pane(config: PtyClientConfig, session: &str, print: bool) -> Result<()> {
    let client = PtyClient::with_config(config);
    let content = client.capture_pane(session).await?;

    if print {
        print!("{}", content);
    } else {
        println!("{}", content);
    }

    Ok(())
}

pub async fn cmd_resize(
    config: PtyClientConfig,
    session: &str,
    cols: u16,
    rows: u16,
) -> Result<()> {
    let client = PtyClient::with_config(config);
    client.resize(session, cols, rows).await?;
    println!("Resized session {} to {}x{}", session, cols, rows);
    Ok(())
}

// Process tmux-like key strings (e.g., "Enter", "C-c")
fn process_key_string(s: &str) -> String {
    let mut result = String::new();
    let mut chars = s.chars().peekable();

    while let Some(c) = chars.next() {
        if c == 'C' && chars.peek() == Some(&'-') {
            chars.next(); // consume '-'
            if let Some(key) = chars.next() {
                let ctrl_char = (key.to_ascii_lowercase() as u8)
                    .wrapping_sub(b'a')
                    .wrapping_add(1);
                result.push(ctrl_char as char);
                continue;
            }
        }
        result.push(c);
    }

    // Replace common key names
    result
        .replace("Enter", "\r")
        .replace("Tab", "\t")
        .replace("Escape", "\x1b")
        .replace("Space", " ")
        .replace("BSpace", "\x7f")
}
