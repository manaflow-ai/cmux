#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

//! cmx server.
//!
//! M3 + M5 + M6 scope: a Daemon holds N Workspaces; each Workspace holds N
//! Spaces; each Space owns a recursive pane tree, and each leaf pane owns a
//! terminal stack. Clients stream their focused workspace/space/pane/terminal.
//!
//! Persistence (M6): on clean shutdown, the daemon snapshots workspace +
//! tab structure (title + cwd only; no scrollback) to JSON. On startup, if
//! `ServerOptions::snapshot_path` exists, the daemon restores the structure
//! and respawns shells in each recorded cwd.
//!
//! Disk-backed scrollback (M6 finalisation) and richer copy mode commands are
//! later milestones.

mod ghostty_theme;
mod native_terminal;
pub mod render;
pub mod snapshot;
mod terminal_query;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn now_unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

const FLASH_TOTAL_MS: u64 = 1200;
const FLASH_PULSE_MS: u64 = 150;
const SELECTION_AUTOSCROLL_LINES: isize = 3;
const SELECTION_AUTOSCROLL_TICK_MS: u64 = 80;
const NATIVE_GRID_FRAME_MS: u64 = 16;
const PTY_REPLAY_MAX_BYTES: usize = 4 * 1024 * 1024;
const LIBGHOSTTY_PTY_REPLAY_RESET: &[u8] = b"\x1bc";
const CLIENT_VIEW_STALE_TIMEOUT_MS: u64 = 15_000;

fn flash_is_on(deadline_ms: u64, now_ms: u64) -> bool {
    if deadline_ms <= now_ms {
        return false;
    }
    let remaining = deadline_ms - now_ms;
    let elapsed = FLASH_TOTAL_MS.saturating_sub(remaining);
    (elapsed / FLASH_PULSE_MS).is_multiple_of(2)
}

#[allow(dead_code)]
fn wake_space_repaint(space: &Arc<Space>) {
    let active = space.active_tab_rx.borrow().clone();
    space.active_tab_tx.send(active).ok();
}

fn tab_size(rect: Rect) -> (u16, u16) {
    (rect.cols.max(1), rect.rows.max(1))
}

fn workspace_tab_id(workspace_id: u64, local_id: u64) -> u64 {
    workspace_id
        .saturating_mul(1 << 32)
        .saturating_add(local_id)
}

fn local_tab_index(workspace_id: u64, tab_id: u64) -> u64 {
    tab_id.saturating_sub(workspace_tab_id(workspace_id, 0))
}

fn workspace_space_id(workspace_id: u64, local_id: u64) -> u64 {
    workspace_id
        .saturating_mul(1 << 32)
        .saturating_add(local_id)
}

/// Accept `#RRGGBB` or `RRGGBB` (case-insensitive) and return the
/// normalised `#RRGGBB` form. Returns `None` for any other shape —
/// keeps the set-color command strict about what it stores so
/// downstream consumers can assume the format.
fn parse_hex_color(s: &str) -> Option<String> {
    let body = s.strip_prefix('#').unwrap_or(s);
    if body.len() != 6 {
        return None;
    }
    if !body.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("#{}", body.to_ascii_uppercase()))
}

/// Parse a `#RRGGBB` / `RRGGBB` string into (r, g, b). Returns
/// `None` for any other shape.
fn rgb_from_hex(s: &str) -> Option<(u8, u8, u8)> {
    let body = s.strip_prefix('#').unwrap_or(s);
    if body.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&body[0..2], 16).ok()?;
    let g = u8::from_str_radix(&body[2..4], 16).ok()?;
    let b = u8::from_str_radix(&body[4..6], 16).ok()?;
    Some((r, g, b))
}

use anyhow::{Context, Result, anyhow, bail};
use cmux_cli_core::layout::Rect;
use cmux_cli_core::probe;
use cmux_cli_core::settings::{self, InputHandler, KeybindTable};
use cmux_cli_protocol::{
    AttachedClientInfo, AttachedClientKind, BufferInfo, ClientMsg, CodecError, Command,
    CommandData, CommandResult, NativePanelNode, NativeSnapshot, NativeSplitDirection,
    NativeTerminalCursor, NativeTerminalFont, NativeTerminalRenderer, NativeTerminalThemeSet,
    NativeTerminalViewport, PROTOCOL_VERSION, ServerMsg, SpaceInfo, SplitDropEdge, SplitPathStep,
    TabInfo, TerminalColorReport, Viewport, WorkspaceInfo, read_msg, write_msg,
};
use futures_util::{SinkExt, StreamExt};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use tokio::io::BufReader;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpStream, UnixListener, UnixStream};
use tokio::sync::{Mutex, broadcast, mpsc, watch};
use tokio::task;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{WebSocketStream, accept_async};

use crate::native_terminal::{
    active_terminal_theme_set_for_host, native_terminal_grid_snapshot,
    native_terminal_pty_replay_from_grid_snapshot, terminal_default_colors_from_report,
    terminal_default_colors_from_theme, terminal_probe_colors_from_report,
    terminal_theme_set_from_report,
};
use crate::render::{
    BorderSpec, ChromeSpec, LineSelection, LogicalLineSelection, PaneChrome, RenderBroker,
    RenderTabInit, SidebarItem, SidebarSpec, StatusSpec, TabBarSpec, TabBarStyle, TabId, TabPill,
    TerminalProbeKind,
};
use crate::snapshot::{PanelSnapshot, Snapshot, SpaceSnapshot, TabSnapshot, WorkspaceSnapshot};
use crate::terminal_query::TerminalQueryScanner;

/// Width reserved for the vertical workspace sidebar (columns). When the
/// viewport is narrower than this plus a sensible pane width, the sidebar
/// collapses to zero. See `SIDEBAR_MIN_TERMINAL_COLS`.
const SIDEBAR_WIDTH: u16 = 16;
/// Viewport widths under this threshold hide the sidebar entirely so the
/// pane has room to breathe on narrow terminals.
const SIDEBAR_MIN_TERMINAL_COLS: u16 = 60;

/// Server configuration.
#[derive(Debug, Clone)]
pub struct ServerOptions {
    pub socket_path: PathBuf,
    pub shell: String,
    pub cwd: Option<PathBuf>,
    pub initial_viewport: (u16, u16),
    /// If set, read a snapshot from this path on startup (if present) and
    /// write one back on clean shutdown.
    pub snapshot_path: Option<PathBuf>,
    /// If set, load user settings from this path on startup and hot-reload
    /// when the file changes. If unset or unreadable, defaults are used.
    pub settings_path: Option<PathBuf>,
    /// If set, accept WebSocket connections on this address (e.g.
    /// 127.0.0.1:8787). Remote exposure requires changing the bind address;
    /// TLS is out-of-process (Caddy, Tailscale HTTPS, reverse proxy).
    pub ws_bind: Option<std::net::SocketAddr>,
    /// Bearer token required for WebSocket connections. Unix-socket clients
    /// ignore this (FS permissions gate them). If `None`, WS auth is
    /// disabled — do NOT expose the listener beyond localhost in that case.
    pub auth_token: Option<String>,
}

pub async fn run(opts: ServerOptions) -> Result<()> {
    run_with_heartbeat(opts, HeartbeatConfig::default()).await
}

#[derive(Debug, Clone, Copy)]
pub struct HeartbeatConfig {
    pub enabled: bool,
    pub check_interval: Duration,
    pub visible_timeout: Duration,
    pub hidden_timeout: Duration,
}

impl Default for HeartbeatConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            check_interval: Duration::from_secs(5),
            visible_timeout: Duration::from_secs(45),
            hidden_timeout: Duration::from_secs(180),
        }
    }
}

pub async fn run_with_heartbeat(opts: ServerOptions, heartbeat: HeartbeatConfig) -> Result<()> {
    run_inner(opts, heartbeat, None).await
}

/// Run with a caller-owned WebSocket listener.
///
/// Tests use this to bind `127.0.0.1:0` once, keep the selected port reserved,
/// and hand that exact listener to the server without a free-port race.
pub async fn run_with_websocket_listener(
    opts: ServerOptions,
    heartbeat: HeartbeatConfig,
    ws_listener: tokio::net::TcpListener,
) -> Result<()> {
    run_inner(opts, heartbeat, Some(ws_listener)).await
}

async fn run_inner(
    opts: ServerOptions,
    heartbeat: HeartbeatConfig,
    prebound_ws_listener: Option<tokio::net::TcpListener>,
) -> Result<()> {
    probe::log_event(
        "server",
        "run_start",
        &[
            ("socket", opts.socket_path.display().to_string()),
            ("shell", opts.shell.clone()),
            (
                "cwd",
                opts.cwd
                    .as_ref()
                    .map_or_else(|| "-".into(), |p| p.display().to_string()),
            ),
            (
                "viewport",
                format!("{}x{}", opts.initial_viewport.0, opts.initial_viewport.1),
            ),
            ("term", std::env::var("TERM").unwrap_or_default()),
            (
                "term_program",
                std::env::var("TERM_PROGRAM").unwrap_or_default(),
            ),
            ("colorterm", std::env::var("COLORTERM").unwrap_or_default()),
        ],
    );
    if opts.socket_path.exists() {
        std::fs::remove_file(&opts.socket_path).ok();
    }
    if let Some(parent) = opts.socket_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create parent {}", parent.display()))?;
    }

    let listener = UnixListener::bind(&opts.socket_path)
        .with_context(|| format!("bind {}", opts.socket_path.display()))?;

    let broker = Arc::new(RenderBroker::spawn().context("spawn render broker thread")?);
    let daemon = Daemon::start(&opts, broker).await?;
    let mut shutdown_rx = daemon.shutdown_rx.clone();

    // Start a settings watcher if configured. The watcher reloads the
    // KeybindTable used by all subsequent input handlers.
    let _watcher_guard = opts
        .settings_path
        .clone()
        .and_then(|p| spawn_settings_watcher(daemon.clone(), p));

    // Optionally start a WebSocket listener.
    let ws_listener = match (prebound_ws_listener, opts.ws_bind) {
        (Some(listener), _) => Some(listener),
        (None, Some(addr)) => Some(
            tokio::net::TcpListener::bind(addr)
                .await
                .with_context(|| format!("ws bind {addr}"))?,
        ),
        (None, None) => None,
    };
    if let Some(ws_listener) = ws_listener {
        let addr = ws_listener
            .local_addr()
            .context("read websocket listener local addr")?;
        tracing::info!(%addr, "cmx server ws listener up");
        let token = opts.auth_token.clone();
        let ws_daemon = daemon.clone();
        task::spawn(async move {
            loop {
                match ws_listener.accept().await {
                    Ok((stream, _)) => {
                        let daemon = ws_daemon.clone();
                        let token = token.clone();
                        let heartbeat = heartbeat;
                        task::spawn(async move {
                            if let Err(e) = handle_ws_client(daemon, stream, token, heartbeat).await
                            {
                                tracing::warn!(error = ?e, "ws client error");
                            }
                        });
                    }
                    Err(e) => {
                        tracing::warn!(error = ?e, "ws accept failed");
                    }
                }
            }
        });
    }

    tracing::info!(path = %opts.socket_path.display(), "cmx server listening");
    probe::log_event(
        "server",
        "listening",
        &[("socket", opts.socket_path.display().to_string())],
    );

    let result = loop {
        tokio::select! {
            biased;
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    tracing::info!("daemon shutting down");
                    break Ok(());
                }
            }
            accept = listener.accept() => {
                match accept {
                    Ok((stream, _)) => {
                        probe::log_event("server", "client_accept", &[]);
                        let daemon = daemon.clone();
                        task::spawn(async move {
                            if let Err(e) =
                                handle_client(daemon, stream, HeartbeatConfig::default()).await
                            {
                                tracing::warn!(error = ?e, "client handler error");
                            }
                        });
                    }
                    Err(e) => break Err(anyhow!("accept: {e}")),
                }
            }
        }
    };

    // Save snapshot best-effort before returning.
    if let Some(path) = daemon.snapshot_path.as_ref()
        && let Err(e) = daemon.save_snapshot(path).await
    {
        tracing::warn!(error = %e, "snapshot save failed");
    }
    daemon.kill_all_tabs().await;

    result
}

#[derive(Debug, Clone)]
struct TabSpawnOptions {
    shell: String,
    fallback_cwd: Option<PathBuf>,
    initial_viewport: (u16, u16),
}

// ------------------------------- Tab -----------------------------------

#[derive(Debug)]
struct PtyReplayBuffer {
    max_bytes: usize,
    byte_len: usize,
    chunks: VecDeque<Vec<u8>>,
}

impl PtyReplayBuffer {
    fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            byte_len: 0,
            chunks: VecDeque::new(),
        }
    }

    fn record(&mut self, data: &[u8]) {
        if data.is_empty() || self.max_bytes == 0 {
            return;
        }
        if data.len() > self.max_bytes {
            self.chunks.clear();
            self.chunks
                .push_back(data[data.len() - self.max_bytes..].to_vec());
            self.byte_len = self.max_bytes;
            return;
        }
        self.chunks.push_back(data.to_vec());
        self.byte_len += data.len();
        while self.byte_len > self.max_bytes {
            let Some(front) = self.chunks.pop_front() else {
                self.byte_len = 0;
                return;
            };
            self.byte_len = self.byte_len.saturating_sub(front.len());
        }
    }

    fn chunks(&self) -> Vec<Vec<u8>> {
        self.chunks.iter().cloned().collect()
    }
}

fn record_pty_replay(replay: &Arc<StdMutex<PtyReplayBuffer>>, chunk: &[u8]) {
    if let Ok(mut replay) = replay.lock() {
        replay.record(chunk);
    }
}

pub struct Tab {
    pub id: u64,
    /// Tab title. `ArcSwap` lets the render thread push updates
    /// from OSC 0/2 sequences without locking, and async callers
    /// load a cloned `Arc<String>` without awaiting.
    pub title: Arc<arc_swap::ArcSwap<String>>,
    /// True after an explicit user rename. OSC title updates from
    /// the PTY remain useful by default, but must not undo `cmx
    /// rename-tab`.
    explicit_title: Arc<AtomicBool>,
    pub cwd: Mutex<Option<PathBuf>>,
    output_tx: broadcast::Sender<Vec<u8>>,
    pty_replay: Arc<StdMutex<PtyReplayBuffer>>,
    pty_tx: Arc<mpsc::UnboundedSender<PtyOp>>,
    alive_rx: watch::Receiver<bool>,
    /// True while the program inside the PTY has mouse tracking enabled
    /// (CSI ?1000/1002/1003 h). Published by the render thread after every
    /// vt_write. Session handlers check this before deciding whether to
    /// intercept a mouse event for selection or pass it through.
    mouse_tracking: watch::Receiver<bool>,
    /// True while the PTY's alternate screen buffer is active. A child only
    /// owns mouse input when it has both mouse tracking and alternate-screen
    /// active; primary-screen tools such as Codex can enable mouse tracking
    /// while still behaving like scrollback text for host selection.
    alternate_screen: watch::Receiver<bool>,
    /// True once the PTY has emitted bytes that the user hasn't yet
    /// "seen" (inactive tabs). Cleared when the tab becomes active.
    /// The tab bar renders a dot next to tabs with this set so the
    /// user knows which background tabs have new output. `Arc` so
    /// the PTY reader closure can share the flag without needing
    /// the full Tab up front.
    has_activity: Arc<AtomicBool>,
    /// Running count of bell bytes (0x07) emitted by the PTY. Bell
    /// counts can be surfaced in the tab pill or used to trigger a
    /// configurable notification command in future revisions.
    bell_count: Arc<AtomicU64>,
    /// Unix epoch millisecond until which the pane border should
    /// flash in an attention color. `0` means "no flash active".
    /// Stored as an atomic so the notify handler and the compositor
    /// can share it without locking.
    flash_until_ms: Arc<AtomicU64>,
    child_killer: StdMutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>,
}

pub(crate) enum PtyOp {
    Write(Vec<u8>),
    TerminalResponse(TerminalResponse),
    Resize(PtySize),
}

impl Tab {
    fn pty_replay_chunks(&self) -> Vec<Vec<u8>> {
        match self.pty_replay.lock() {
            Ok(replay) => replay.chunks(),
            Err(_) => Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalResponse {
    pub(crate) kind: TerminalResponseSource,
    pub(crate) bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalResponseSource {
    Libghostty,
    DefaultForegroundColor,
    DefaultBackgroundColor,
}

impl TerminalResponseSource {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Libghostty => "libghostty",
            Self::DefaultForegroundColor => "default_foreground_color",
            Self::DefaultBackgroundColor => "default_background_color",
        }
    }
}

impl From<TerminalProbeKind> for TerminalResponseSource {
    fn from(kind: TerminalProbeKind) -> Self {
        match kind {
            TerminalProbeKind::DefaultForegroundColor => Self::DefaultForegroundColor,
            TerminalProbeKind::DefaultBackgroundColor => Self::DefaultBackgroundColor,
        }
    }
}

fn should_fallback_term(term: Option<&str>) -> bool {
    matches!(term.map(str::trim), None | Some("") | Some("dumb"))
        || term.is_some_and(is_multiplexer_term)
}

fn is_multiplexer_term(term: &str) -> bool {
    let term = term.trim();
    term == "tmux" || term.starts_with("tmux-") || term == "screen" || term.starts_with("screen-")
}

fn is_multiplexer_term_program(term_program: &str) -> bool {
    matches!(term_program.trim(), "tmux" | "screen")
}

fn should_skip_child_env(key: &str, value: &str) -> bool {
    matches!(key, "TMUX" | "TMUX_PANE" | "STY")
        || (key == "TERM_PROGRAM" && is_multiplexer_term_program(value))
}

fn child_term_override_for_environment(
    term: Option<&str>,
    term_program: Option<&str>,
) -> Option<&'static str> {
    if should_fallback_term(term) {
        return Some("xterm-256color");
    }
    if matches!(term_program.map(str::trim), Some("ghostty")) {
        return None;
    }
    None
}

#[derive(Default)]
struct CommandDetector {
    line: Vec<u8>,
}

impl CommandDetector {
    fn push_input(&mut self, bytes: &[u8]) -> Option<String> {
        let mut completed = None;
        for &byte in bytes {
            match byte {
                b'\r' | b'\n' => {
                    if !self.line.is_empty() {
                        completed = Some(String::from_utf8_lossy(&self.line).to_string());
                    }
                    self.line.clear();
                }
                0x7f | 0x08 => {
                    self.line.pop();
                }
                0x20..=0x7e if self.line.len() < 4096 => {
                    self.line.push(byte);
                }
                _ => {}
            }
        }
        completed
    }
}

impl Tab {
    fn spawn(
        id: u64,
        workspace_id: u64,
        title: &str,
        cwd: Option<PathBuf>,
        explicit_title: bool,
        opts: &TabSpawnOptions,
        broker: &Arc<RenderBroker>,
    ) -> Result<Arc<Self>> {
        let spawn_start_ms = probe::mono_ms();
        probe::log_event(
            "server",
            "tab_spawn_start",
            &[
                ("tab_id", id.to_string()),
                ("workspace_id", workspace_id.to_string()),
                ("shell", opts.shell.clone()),
                (
                    "cwd",
                    cwd.as_ref()
                        .or(opts.fallback_cwd.as_ref())
                        .map_or_else(|| "-".into(), |p| p.display().to_string()),
                ),
                (
                    "viewport",
                    format!("{}x{}", opts.initial_viewport.0, opts.initial_viewport.1),
                ),
            ],
        );
        let pty_system = native_pty_system();
        let openpty_start_ms = probe::mono_ms();
        let pair = pty_system
            .openpty(PtySize {
                cols: opts.initial_viewport.0,
                rows: opts.initial_viewport.1,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty")?;
        probe::log_event(
            "server",
            "tab_openpty_done",
            &[
                ("tab_id", id.to_string()),
                (
                    "elapsed_ms",
                    probe::mono_ms()
                        .saturating_sub(openpty_start_ms)
                        .to_string(),
                ),
            ],
        );

        let mut cmd = CommandBuilder::new(&opts.shell);
        let effective_cwd = cwd.clone().or_else(|| opts.fallback_cwd.clone());
        if let Some(cwd) = &effective_cwd {
            cmd.cwd(cwd);
        }
        for (k, v) in std::env::vars() {
            if should_skip_child_env(&k, &v) {
                continue;
            }
            cmd.env(k, v);
        }
        // cmx presents a real terminal model to child processes. If the server
        // is launched from a non-interactive harness, TERM is often `dumb`;
        // don't pass that through to shells because it disables the user's
        // prompt palette and TUI color probing.
        let term = std::env::var("TERM").ok();
        let term_program = std::env::var("TERM_PROGRAM").ok();
        if let Some(fallback_term) =
            child_term_override_for_environment(term.as_deref(), term_program.as_deref())
        {
            cmd.env("TERM", fallback_term);
            if std::env::var("COLORTERM")
                .ok()
                .is_none_or(|value| value.trim().is_empty())
            {
                cmd.env("COLORTERM", "truecolor");
            }
            probe::log_event(
                "server",
                "tab_env_terminal_fallback",
                &[
                    ("tab_id", id.to_string()),
                    ("server_term", term.unwrap_or_default()),
                    ("term_program", term_program.unwrap_or_default()),
                    ("fallback_term", fallback_term.to_string()),
                ],
            );
        }
        // Publish identity env vars so programs running inside a tab
        // (Claude Code, `cmx send`, status scripts, etc.) can identify
        // which workspace/tab they live in without walking the socket.
        // `CMUX_*` matches the macOS cmux app's convention so scripts
        // work across both surfaces; `CMX_*` is a cmx-native alias.
        cmd.env("CMUX_WORKSPACE_ID", workspace_id.to_string());
        cmd.env("CMUX_TAB_ID", id.to_string());
        cmd.env("CMX_WORKSPACE_ID", workspace_id.to_string());
        cmd.env("CMX_TAB_ID", id.to_string());
        // Put the running cmx binary's directory at the FRONT of PATH
        // so `cmx notify`, `cmx send`, etc. just work inside any tab
        // without the user having to install the binary globally.
        if let Ok(self_path) = std::env::current_exe()
            && let Some(self_dir) = self_path.parent()
        {
            let parent_path = std::env::var("PATH").unwrap_or_default();
            let new_path = if parent_path.is_empty() {
                self_dir.display().to_string()
            } else {
                format!("{}:{parent_path}", self_dir.display())
            };
            cmd.env("PATH", new_path);
        }

        let spawn_command_start_ms = probe::mono_ms();
        let child = pair.slave.spawn_command(cmd).context("spawn shell")?;
        probe::log_event(
            "server",
            "tab_spawn_command_done",
            &[
                ("tab_id", id.to_string()),
                (
                    "elapsed_ms",
                    probe::mono_ms()
                        .saturating_sub(spawn_command_start_ms)
                        .to_string(),
                ),
                (
                    "total_elapsed_ms",
                    probe::mono_ms().saturating_sub(spawn_start_ms).to_string(),
                ),
            ],
        );
        let child_killer = StdMutex::new(child.clone_killer());
        drop(pair.slave);

        let master = pair.master;
        let reader = master.try_clone_reader().context("clone pty reader")?;

        let (output_tx, _) = broadcast::channel::<Vec<u8>>(1024);
        let pty_replay = Arc::new(StdMutex::new(PtyReplayBuffer::new(PTY_REPLAY_MAX_BYTES)));
        let (pty_tx_raw, mut pty_rx) = mpsc::unbounded_channel::<PtyOp>();
        let pty_tx = Arc::new(pty_tx_raw);
        let (alive_tx, alive_rx) = watch::channel(true);

        let (mouse_tracking_tx, mouse_tracking_rx) = watch::channel(false);
        let (alternate_screen_tx, alternate_screen_rx) = watch::channel(false);
        // Shared title holder: the render thread writes to this when
        // it sees OSC 0/2 sequences, async readers load snapshots
        // without locking.
        let title_arc: Arc<arc_swap::ArcSwap<String>> =
            Arc::new(arc_swap::ArcSwap::new(Arc::new(title.to_string())));
        let explicit_title = Arc::new(AtomicBool::new(explicit_title));
        broker.add_tab(RenderTabInit {
            id,
            cols: opts.initial_viewport.0,
            rows: opts.initial_viewport.1,
            pty_response_tx: Arc::downgrade(&pty_tx),
            mouse_tracking_tx,
            alternate_screen_tx,
            title: title_arc.clone(),
            explicit_title: explicit_title.clone(),
        });

        let output_broadcast = output_tx.clone();
        let broker_reader = Arc::clone(broker);
        // Shared activity + bell counters between the reader task and the
        // Tab struct. `Arc<AtomicBool>` and `Arc<AtomicU64>` are cheap to
        // clone and avoid reordering the constructor.
        let has_activity: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let bell_count: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));
        let flash_until_ms: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));
        let pty_read_seq: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));
        let codex_enter_ms: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));
        let codex_output_seq: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));
        let activity_in_reader = has_activity.clone();
        let bell_in_reader = bell_count.clone();
        let pty_read_seq_reader = pty_read_seq.clone();
        let codex_enter_ms_reader = codex_enter_ms.clone();
        let codex_output_seq_reader = codex_output_seq.clone();
        let pty_tx_reader = Arc::downgrade(&pty_tx);
        let pty_replay_reader = Arc::clone(&pty_replay);
        task::spawn_blocking(move || {
            use std::io::Read;
            let mut reader = reader;
            let mut buf = [0u8; 8192];
            let mut terminal_query_scanner = TerminalQueryScanner::default();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let data = &buf[..n];
                        let read_seq = pty_read_seq_reader.fetch_add(1, Ordering::Relaxed) + 1;
                        let pending_codex_ms = codex_enter_ms_reader.load(Ordering::Relaxed);
                        let codex_seq = if pending_codex_ms > 0 {
                            codex_output_seq_reader.fetch_add(1, Ordering::Relaxed) + 1
                        } else {
                            0
                        };
                        let is_interesting = probe::verbose_enabled()
                            || read_seq <= 12
                            || probe::has_terminal_color_sequences(data)
                            || probe::contains_alt_screen(data)
                            || probe::contains_ascii_case_insensitive(data, b"codex")
                            || (pending_codex_ms > 0 && codex_seq <= 80);
                        if is_interesting {
                            probe::log_event(
                                "server",
                                "pty_read",
                                &[
                                    ("tab_id", id.to_string()),
                                    ("read_seq", read_seq.to_string()),
                                    ("bytes", n.to_string()),
                                    (
                                        "since_spawn_ms",
                                        probe::mono_ms().saturating_sub(spawn_start_ms).to_string(),
                                    ),
                                    (
                                        "since_codex_enter_ms",
                                        if pending_codex_ms > 0 {
                                            probe::mono_ms()
                                                .saturating_sub(pending_codex_ms)
                                                .to_string()
                                        } else {
                                            "-".into()
                                        },
                                    ),
                                    ("summary", probe::terminal_bytes_summary(data)),
                                ],
                            );
                        }
                        if pending_codex_ms > 0 && probe::contains_alt_screen(data) {
                            probe::log_event(
                                "server",
                                "codex_alt_screen_seen",
                                &[
                                    ("tab_id", id.to_string()),
                                    (
                                        "elapsed_ms",
                                        probe::mono_ms()
                                            .saturating_sub(pending_codex_ms)
                                            .to_string(),
                                    ),
                                    ("read_seq", read_seq.to_string()),
                                ],
                            );
                            codex_enter_ms_reader.store(0, Ordering::Relaxed);
                        }
                        // Tally bell bytes before forwarding. Bells are
                        // the standard attention-request mechanism for
                        // TUI programs; we surface the count so future
                        // work can hook a notification command.
                        let bells = data.iter().filter(|&&b| b == 0x07).count();
                        if bells > 0 {
                            bell_in_reader.fetch_add(bells as u64, Ordering::Relaxed);
                        }
                        activity_in_reader.store(true, Ordering::Relaxed);
                        let probes = terminal_query_scanner.ingest(data);
                        let mut offset = 0usize;
                        for probe in probes {
                            let end = probe.current_end.min(data.len());
                            if end > offset {
                                let chunk = data[offset..end].to_vec();
                                record_pty_replay(&pty_replay_reader, &chunk);
                                broker_reader.pty_bytes(id, chunk.clone());
                                let _ = output_broadcast.send(chunk);
                                offset = end;
                            }
                            let kind = probe.kind;
                            let Some(bytes) = broker_reader.terminal_probe_response(id, kind)
                            else {
                                if probe::verbose_enabled() || pending_codex_ms > 0 {
                                    probe::log_event(
                                        "server",
                                        "terminal_response_unavailable",
                                        &[
                                            ("tab_id", id.to_string()),
                                            ("query", kind.as_str().to_string()),
                                        ],
                                    );
                                }
                                continue;
                            };
                            let response = TerminalResponse {
                                kind: kind.into(),
                                bytes,
                            };
                            if probe::verbose_enabled() || pending_codex_ms > 0 {
                                probe::log_event(
                                    "server",
                                    "terminal_response",
                                    &[
                                        ("tab_id", id.to_string()),
                                        ("query", response.kind.as_str().to_string()),
                                        (
                                            "since_codex_enter_ms",
                                            if pending_codex_ms > 0 {
                                                probe::mono_ms()
                                                    .saturating_sub(pending_codex_ms)
                                                    .to_string()
                                            } else {
                                                "-".into()
                                            },
                                        ),
                                        ("response", probe::preview_bytes(&response.bytes, 80)),
                                    ],
                                );
                            }
                            if let Some(pty_tx) = pty_tx_reader.upgrade() {
                                let _ = pty_tx.send(PtyOp::TerminalResponse(response));
                            }
                        }
                        if offset < data.len() {
                            let chunk = data[offset..].to_vec();
                            record_pty_replay(&pty_replay_reader, &chunk);
                            broker_reader.pty_bytes(id, chunk.clone());
                            let _ = output_broadcast.send(chunk);
                        }
                    }
                }
            }
            let _ = alive_tx.send(false);
        });

        let codex_enter_ms_writer = codex_enter_ms.clone();
        let codex_output_seq_writer = codex_output_seq.clone();
        task::spawn_blocking(move || {
            use std::io::Write;
            let master = master;
            let mut writer = match master.take_writer() {
                Ok(w) => w,
                Err(e) => {
                    tracing::error!(error = %e, "take_writer failed");
                    return;
                }
            };
            let mut detector = CommandDetector::default();
            while let Some(op) = pty_rx.blocking_recv() {
                match op {
                    PtyOp::Write(bytes) => {
                        let write_start_ms = probe::mono_ms();
                        let completed_line = detector.push_input(&bytes);
                        let contains_codex =
                            completed_line.as_ref().is_some_and(|line| {
                                probe::contains_ascii_case_insensitive(line.as_bytes(), b"codex")
                            }) || probe::contains_ascii_case_insensitive(&bytes, b"codex");
                        if contains_codex {
                            let enter_ms = probe::mono_ms();
                            codex_enter_ms_writer.store(enter_ms, Ordering::Relaxed);
                            codex_output_seq_writer.store(0, Ordering::Relaxed);
                            probe::log_event(
                                "server",
                                "codex_command_enter",
                                &[
                                    ("tab_id", id.to_string()),
                                    (
                                        "line",
                                        completed_line
                                            .clone()
                                            .unwrap_or_else(|| probe::preview_bytes(&bytes, 160)),
                                    ),
                                    ("bytes", bytes.len().to_string()),
                                ],
                            );
                        } else if probe::verbose_enabled() {
                            probe::log_event(
                                "server",
                                "pty_write",
                                &[
                                    ("tab_id", id.to_string()),
                                    ("bytes", bytes.len().to_string()),
                                    ("preview", probe::preview_bytes(&bytes, 80)),
                                ],
                            );
                        }
                        if writer.write_all(&bytes).is_err() {
                            break;
                        }
                        let _ = writer.flush();
                        if contains_codex {
                            probe::log_event(
                                "server",
                                "codex_command_write_done",
                                &[
                                    ("tab_id", id.to_string()),
                                    (
                                        "elapsed_ms",
                                        probe::mono_ms().saturating_sub(write_start_ms).to_string(),
                                    ),
                                ],
                            );
                        }
                    }
                    PtyOp::TerminalResponse(response) => {
                        if writer.write_all(&response.bytes).is_err() {
                            break;
                        }
                        let _ = writer.flush();
                    }
                    PtyOp::Resize(size) => {
                        if probe::verbose_enabled() {
                            probe::log_event(
                                "server",
                                "pty_resize",
                                &[
                                    ("tab_id", id.to_string()),
                                    ("cols", size.cols.to_string()),
                                    ("rows", size.rows.to_string()),
                                ],
                            );
                        }
                        let _ = master.resize(size);
                    }
                }
            }
        });

        Ok(Arc::new(Self {
            id,
            title: title_arc,
            explicit_title,
            cwd: Mutex::new(effective_cwd),
            output_tx,
            pty_replay,
            pty_tx,
            alive_rx,
            mouse_tracking: mouse_tracking_rx,
            alternate_screen: alternate_screen_rx,
            has_activity,
            bell_count,
            flash_until_ms,
            child_killer,
        }))
    }

    fn kill_child(&self) {
        if let Ok(mut killer) = self.child_killer.lock() {
            let _ = killer.kill();
        }
    }
}

// ----------------------------- Workspace -------------------------------

/// How multiple tabs are laid out simultaneously when splits are on.
/// In MVP splits, each tab becomes a visible leaf pane; the split
/// direction controls whether those leaves sit side-by-side or
/// stacked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDirection {
    /// Side-by-side: each leaf gets 1/N of the pane-area's width.
    Horizontal,
    /// Stacked: each leaf gets 1/N of the pane-area's height.
    Vertical,
}

type PanelId = u64;
type SpaceId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct PanelRef {
    space_id: SpaceId,
    panel_id: PanelId,
}

/// A leaf panel owns its own tab stack. The global workspace tab registry is
/// only for lookup, sizing, and cleanup; panel membership lives here.
#[derive(Debug, Clone)]
struct Panel {
    id: PanelId,
    tabs: Vec<TabId>,
    active_tab: Option<TabId>,
}

#[derive(Debug, Clone)]
enum PanelNode {
    Leaf(Panel),
    Split {
        direction: SplitDirection,
        ratio_permille: u16,
        first: Box<PanelNode>,
        second: Box<PanelNode>,
    },
}

#[derive(Debug, Clone)]
struct PanelLeaf {
    id: PanelId,
    tabs: Vec<TabId>,
    active_tab: Option<TabId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PanelEdge {
    Left,
    Right,
    Top,
    Bottom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PanelFocusTarget {
    panel_id: PanelId,
    tab_id: TabId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RemoveTabResult {
    removed: bool,
    empty: bool,
    focus: Option<PanelFocusTarget>,
}

impl RemoveTabResult {
    const fn not_removed() -> Self {
        Self {
            removed: false,
            empty: false,
            focus: None,
        }
    }
}

impl PanelNode {
    fn root(tab_id: TabId) -> Self {
        Self::Leaf(Panel {
            id: 0,
            tabs: vec![tab_id],
            active_tab: Some(tab_id),
        })
    }

    fn leaves(&self) -> Vec<PanelLeaf> {
        let mut out = Vec::new();
        self.collect_leaves(&mut out);
        out
    }

    fn collect_leaves(&self, out: &mut Vec<PanelLeaf>) {
        match self {
            Self::Leaf(panel) => out.push(PanelLeaf {
                id: panel.id,
                tabs: panel.tabs.clone(),
                active_tab: panel.active_tab,
            }),
            Self::Split { first, second, .. } => {
                first.collect_leaves(out);
                second.collect_leaves(out);
            }
        }
    }

    fn is_split(&self) -> bool {
        matches!(self, Self::Split { .. })
    }

    fn first_panel_id(&self) -> Option<PanelId> {
        match self {
            Self::Leaf(panel) => Some(panel.id),
            Self::Split { first, .. } => first.first_panel_id(),
        }
    }

    fn contains_panel(&self, panel_id: PanelId) -> bool {
        match self {
            Self::Leaf(panel) => panel.id == panel_id,
            Self::Split { first, second, .. } => {
                first.contains_panel(panel_id) || second.contains_panel(panel_id)
            }
        }
    }

    fn find_panel(&self, panel_id: PanelId) -> Option<&Panel> {
        match self {
            Self::Leaf(panel) if panel.id == panel_id => Some(panel),
            Self::Leaf(_) => None,
            Self::Split { first, second, .. } => first
                .find_panel(panel_id)
                .or_else(|| second.find_panel(panel_id)),
        }
    }

    fn find_panel_mut(&mut self, panel_id: PanelId) -> Option<&mut Panel> {
        match self {
            Self::Leaf(panel) if panel.id == panel_id => Some(panel),
            Self::Leaf(_) => None,
            Self::Split { first, second, .. } => {
                if first.contains_panel(panel_id) {
                    first.find_panel_mut(panel_id)
                } else {
                    second.find_panel_mut(panel_id)
                }
            }
        }
    }

    fn panel_containing_tab(&self, tab_id: TabId) -> Option<PanelId> {
        match self {
            Self::Leaf(panel) if panel.tabs.contains(&tab_id) => Some(panel.id),
            Self::Leaf(_) => None,
            Self::Split { first, second, .. } => first
                .panel_containing_tab(tab_id)
                .or_else(|| second.panel_containing_tab(tab_id)),
        }
    }

    fn set_active_tab(&mut self, panel_id: PanelId, tab_id: TabId) -> bool {
        let Some(panel) = self.find_panel_mut(panel_id) else {
            return false;
        };
        if !panel.tabs.contains(&tab_id) {
            return false;
        }
        panel.active_tab = Some(tab_id);
        true
    }

    fn add_tab_to_panel(&mut self, panel_id: PanelId, tab_id: TabId) -> bool {
        let Some(panel) = self.find_panel_mut(panel_id) else {
            return false;
        };
        panel.tabs.push(tab_id);
        panel.active_tab = Some(tab_id);
        true
    }

    fn split_panel(
        &mut self,
        panel_id: PanelId,
        direction: SplitDirection,
        new_panel_id: PanelId,
        new_tab_id: TabId,
    ) -> bool {
        match self {
            Self::Leaf(panel) if panel.id == panel_id => {
                let old = panel.clone();
                let new = Panel {
                    id: new_panel_id,
                    tabs: vec![new_tab_id],
                    active_tab: Some(new_tab_id),
                };
                *self = Self::Split {
                    direction,
                    ratio_permille: 500,
                    first: Box::new(Self::Leaf(old)),
                    second: Box::new(Self::Leaf(new)),
                };
                true
            }
            Self::Leaf(_) => false,
            Self::Split { first, second, .. } => {
                if first.contains_panel(panel_id) {
                    first.split_panel(panel_id, direction, new_panel_id, new_tab_id)
                } else {
                    second.split_panel(panel_id, direction, new_panel_id, new_tab_id)
                }
            }
        }
    }

    fn split_panel_with_existing_tab(
        &mut self,
        panel_id: PanelId,
        edge: PanelEdge,
        new_panel_id: PanelId,
        tab_id: TabId,
    ) -> bool {
        match self {
            Self::Leaf(panel) if panel.id == panel_id => {
                let old = panel.clone();
                let new = Panel {
                    id: new_panel_id,
                    tabs: vec![tab_id],
                    active_tab: Some(tab_id),
                };
                let (direction, first, second) = match edge {
                    PanelEdge::Left => {
                        (SplitDirection::Horizontal, Self::Leaf(new), Self::Leaf(old))
                    }
                    PanelEdge::Right => {
                        (SplitDirection::Horizontal, Self::Leaf(old), Self::Leaf(new))
                    }
                    PanelEdge::Top => (SplitDirection::Vertical, Self::Leaf(new), Self::Leaf(old)),
                    PanelEdge::Bottom => {
                        (SplitDirection::Vertical, Self::Leaf(old), Self::Leaf(new))
                    }
                };
                *self = Self::Split {
                    direction,
                    ratio_permille: 500,
                    first: Box::new(first),
                    second: Box::new(second),
                };
                true
            }
            Self::Leaf(_) => false,
            Self::Split { first, second, .. } => {
                if first.contains_panel(panel_id) {
                    first.split_panel_with_existing_tab(panel_id, edge, new_panel_id, tab_id)
                } else {
                    second.split_panel_with_existing_tab(panel_id, edge, new_panel_id, tab_id)
                }
            }
        }
    }

    fn move_tab(&mut self, panel_id: PanelId, from: usize, to: usize) -> Result<()> {
        let Some(panel) = self.find_panel_mut(panel_id) else {
            bail!("no panel {panel_id}");
        };
        if panel.tabs.is_empty() {
            bail!("no tabs");
        }
        if from >= panel.tabs.len() {
            bail!("no tab at index {from}");
        }
        let clamped_to = to.min(panel.tabs.len() - 1);
        if from == clamped_to {
            return Ok(());
        }
        let tab = panel.tabs.remove(from);
        panel.tabs.insert(clamped_to, tab);
        Ok(())
    }

    fn move_tab_to_panel(
        &mut self,
        from_panel_id: PanelId,
        from: usize,
        to_panel_id: PanelId,
        to: usize,
    ) -> Result<TabId> {
        if from_panel_id == to_panel_id {
            let Some(panel) = self.find_panel_mut(from_panel_id) else {
                bail!("no panel {from_panel_id}");
            };
            if panel.tabs.is_empty() {
                bail!("no tabs");
            }
            if from >= panel.tabs.len() {
                bail!("no tab at index {from}");
            }
            let insertion = to.min(panel.tabs.len());
            let tab_id = panel.tabs.remove(from);
            let adjusted = if from < insertion {
                insertion.saturating_sub(1)
            } else {
                insertion
            }
            .min(panel.tabs.len());
            panel.tabs.insert(adjusted, tab_id);
            panel.active_tab = Some(tab_id);
            return Ok(tab_id);
        }

        if !self.contains_panel(to_panel_id) {
            bail!("no panel {to_panel_id}");
        }
        let tab_id = {
            let Some(source) = self.find_panel(from_panel_id) else {
                bail!("no panel {from_panel_id}");
            };
            *source
                .tabs
                .get(from)
                .ok_or_else(|| anyhow!("no tab at index {from}"))?
        };

        let result = self.remove_tab(tab_id);
        if !result.removed {
            bail!("no tab at index {from}");
        }

        let Some(target) = self.find_panel_mut(to_panel_id) else {
            bail!("no panel {to_panel_id}");
        };
        let insertion = to.min(target.tabs.len());
        target.tabs.insert(insertion, tab_id);
        target.active_tab = Some(tab_id);
        Ok(tab_id)
    }

    fn move_tab_to_split(
        &mut self,
        from_panel_id: PanelId,
        from: usize,
        target_panel_id: PanelId,
        edge: PanelEdge,
        new_panel_id: PanelId,
        replacement_tab_id: Option<TabId>,
    ) -> Result<TabId> {
        let Some(source) = self.find_panel(from_panel_id) else {
            bail!("no panel {from_panel_id}");
        };
        let Some(tab_id) = source.tabs.get(from).copied() else {
            bail!("no tab at index {from}");
        };
        if from_panel_id == target_panel_id && source.tabs.len() <= 1 {
            let Some(replacement_tab_id) = replacement_tab_id else {
                bail!("cannot split the only tab from its own panel");
            };
            if replacement_tab_id == tab_id {
                bail!("replacement tab cannot match moved tab");
            }
            let Some(source) = self.find_panel_mut(from_panel_id) else {
                bail!("no panel {from_panel_id}");
            };
            source.tabs.push(replacement_tab_id);
            source.active_tab = Some(replacement_tab_id);
        }
        if !self.contains_panel(target_panel_id) {
            bail!("no panel {target_panel_id}");
        }

        let result = self.remove_tab(tab_id);
        if !result.removed {
            bail!("no tab at index {from}");
        }
        if !self.split_panel_with_existing_tab(target_panel_id, edge, new_panel_id, tab_id) {
            bail!("no panel {target_panel_id}");
        }
        Ok(tab_id)
    }

    fn focus_target_for_panel(panel: &Panel) -> Option<PanelFocusTarget> {
        let tab_id = panel
            .active_tab
            .filter(|id| panel.tabs.contains(id))
            .or_else(|| panel.tabs.first().copied())?;
        Some(PanelFocusTarget {
            panel_id: panel.id,
            tab_id,
        })
    }

    /// Pick the leaf that should absorb focus when a neighbouring pane on
    /// `edge` disappears. When several leaves touch that edge, prefer the
    /// first leaf in reading order.
    fn focus_target_for_edge(&self, edge: PanelEdge) -> Option<PanelFocusTarget> {
        match self {
            Self::Leaf(panel) => Self::focus_target_for_panel(panel),
            Self::Split {
                direction,
                first,
                second,
                ..
            } => match (direction, edge) {
                (SplitDirection::Horizontal, PanelEdge::Left) => first.focus_target_for_edge(edge),
                (SplitDirection::Horizontal, PanelEdge::Right) => {
                    second.focus_target_for_edge(edge)
                }
                (SplitDirection::Vertical, PanelEdge::Top) => first.focus_target_for_edge(edge),
                (SplitDirection::Vertical, PanelEdge::Bottom) => second.focus_target_for_edge(edge),
                _ => first
                    .focus_target_for_edge(edge)
                    .or_else(|| second.focus_target_for_edge(edge)),
            },
        }
    }

    fn remove_tab(&mut self, tab_id: TabId) -> RemoveTabResult {
        match self {
            Self::Leaf(panel) => {
                let Some(idx) = panel.tabs.iter().position(|id| *id == tab_id) else {
                    return RemoveTabResult::not_removed();
                };
                panel.tabs.remove(idx);
                if panel.active_tab == Some(tab_id) {
                    panel.active_tab = panel.tabs.get(idx).or_else(|| panel.tabs.last()).copied();
                }
                if panel.tabs.is_empty() {
                    RemoveTabResult {
                        removed: true,
                        empty: true,
                        focus: None,
                    }
                } else {
                    RemoveTabResult {
                        removed: true,
                        empty: false,
                        focus: Self::focus_target_for_panel(panel),
                    }
                }
            }
            Self::Split {
                direction,
                first,
                second,
                ..
            } => {
                if first.panel_containing_tab(tab_id).is_some() {
                    let result = first.remove_tab(tab_id);
                    if !result.removed {
                        return result;
                    }
                    if result.empty {
                        let focus = match direction {
                            SplitDirection::Horizontal => {
                                second.focus_target_for_edge(PanelEdge::Left)
                            }
                            SplitDirection::Vertical => {
                                second.focus_target_for_edge(PanelEdge::Top)
                            }
                        };
                        *self = (**second).clone();
                        RemoveTabResult {
                            removed: true,
                            empty: focus.is_none(),
                            focus,
                        }
                    } else {
                        result
                    }
                } else if second.panel_containing_tab(tab_id).is_some() {
                    let result = second.remove_tab(tab_id);
                    if !result.removed {
                        return result;
                    }
                    if result.empty {
                        let focus = match direction {
                            SplitDirection::Horizontal => {
                                first.focus_target_for_edge(PanelEdge::Right)
                            }
                            SplitDirection::Vertical => {
                                first.focus_target_for_edge(PanelEdge::Bottom)
                            }
                        };
                        *self = (**first).clone();
                        RemoveTabResult {
                            removed: true,
                            empty: focus.is_none(),
                            focus,
                        }
                    } else {
                        result
                    }
                } else {
                    RemoveTabResult::not_removed()
                }
            }
        }
    }

    fn all_tab_ids(&self) -> Vec<TabId> {
        let mut out = Vec::new();
        self.collect_tab_ids(&mut out);
        out
    }

    fn collect_tab_ids(&self, out: &mut Vec<TabId>) {
        match self {
            Self::Leaf(panel) => out.extend(panel.tabs.iter().copied()),
            Self::Split { first, second, .. } => {
                first.collect_tab_ids(out);
                second.collect_tab_ids(out);
            }
        }
    }

    fn flatten(&mut self, active_panel_id: PanelId, active_tab_id: TabId) -> PanelId {
        let tabs = self.all_tab_ids();
        let active = if tabs.contains(&active_tab_id) {
            Some(active_tab_id)
        } else {
            tabs.first().copied()
        };
        let id = if self.contains_panel(active_panel_id) {
            active_panel_id
        } else {
            self.first_panel_id().unwrap_or(0)
        };
        *self = Self::Leaf(Panel {
            id,
            tabs,
            active_tab: active,
        });
        id
    }

    fn resize_active_split(&mut self, panel_id: PanelId, delta: i16) -> bool {
        match self {
            Self::Leaf(_) => false,
            Self::Split {
                ratio_permille,
                first,
                second,
                ..
            } => {
                if first.resize_active_split(panel_id, delta)
                    || second.resize_active_split(panel_id, delta)
                {
                    true
                } else if first.contains_panel(panel_id) || second.contains_panel(panel_id) {
                    let cur = *ratio_permille as i32;
                    *ratio_permille = (cur + delta as i32).clamp(100, 900) as u16;
                    true
                } else {
                    false
                }
            }
        }
    }

    fn resize_split_at_path(&mut self, path: &[SplitPathStep], ratio_permille: u16) -> bool {
        match self {
            Self::Leaf(_) => false,
            Self::Split {
                ratio_permille: ratio,
                first,
                second,
                ..
            } => match path.split_first() {
                None => {
                    *ratio = ratio_permille.clamp(100, 900);
                    true
                }
                Some((SplitPathStep::First, rest)) => {
                    first.resize_split_at_path(rest, ratio_permille)
                }
                Some((SplitPathStep::Second, rest)) => {
                    second.resize_split_at_path(rest, ratio_permille)
                }
            },
        }
    }
}

fn next_panel_id(node: &PanelNode) -> PanelId {
    match node {
        PanelNode::Leaf(panel) => panel.id,
        PanelNode::Split { first, second, .. } => next_panel_id(first).max(next_panel_id(second)),
    }
}

fn snapshot_panel_to_node(snapshot: &PanelSnapshot, tab_ids: &[TabId]) -> Option<PanelNode> {
    match snapshot {
        PanelSnapshot::Leaf {
            id,
            active_tab,
            tabs,
        } => {
            let ids: Vec<TabId> = tabs
                .iter()
                .filter_map(|idx| tab_ids.get(*idx).copied())
                .collect();
            if ids.is_empty() {
                return None;
            }
            let active = active_tab
                .and_then(|idx| tab_ids.get(idx).copied())
                .filter(|id| ids.contains(id))
                .or_else(|| ids.first().copied());
            Some(PanelNode::Leaf(Panel {
                id: *id,
                tabs: ids,
                active_tab: active,
            }))
        }
        PanelSnapshot::Split {
            direction,
            ratio_permille,
            first,
            second,
        } => {
            let first = snapshot_panel_to_node(first, tab_ids)?;
            let second = snapshot_panel_to_node(second, tab_ids)?;
            let direction = match direction.as_str() {
                "horizontal" => SplitDirection::Horizontal,
                "vertical" => SplitDirection::Vertical,
                _ => return None,
            };
            Some(PanelNode::Split {
                direction,
                ratio_permille: (*ratio_permille).clamp(100, 900),
                first: Box::new(first),
                second: Box::new(second),
            })
        }
    }
}

fn panel_node_to_snapshot(
    node: &PanelNode,
    tab_index_by_id: &HashMap<TabId, usize>,
) -> Option<PanelSnapshot> {
    match node {
        PanelNode::Leaf(panel) => {
            let tabs: Vec<usize> = panel
                .tabs
                .iter()
                .filter_map(|id| tab_index_by_id.get(id).copied())
                .collect();
            if tabs.is_empty() {
                return None;
            }
            let active_tab = panel
                .active_tab
                .and_then(|id| tab_index_by_id.get(&id).copied());
            Some(PanelSnapshot::Leaf {
                id: panel.id,
                active_tab,
                tabs,
            })
        }
        PanelNode::Split {
            direction,
            ratio_permille,
            first,
            second,
        } => Some(PanelSnapshot::Split {
            direction: match direction {
                SplitDirection::Horizontal => "horizontal".to_string(),
                SplitDirection::Vertical => "vertical".to_string(),
            },
            ratio_permille: *ratio_permille,
            first: Box::new(panel_node_to_snapshot(first, tab_index_by_id)?),
            second: Box::new(panel_node_to_snapshot(second, tab_index_by_id)?),
        }),
    }
}

pub struct Space {
    pub id: SpaceId,
    pub workspace_id: u64,
    pub title: Mutex<String>,
    panels: Mutex<PanelNode>,
    tabs: Mutex<Vec<Arc<Tab>>>,
    active_tab_tx: watch::Sender<Arc<Tab>>,
    active_tab_rx: watch::Receiver<Arc<Tab>>,
    dead_tx: watch::Sender<bool>,
    dead_rx: watch::Receiver<bool>,
    spawn_opts: TabSpawnOptions,
    next_tab_id: Arc<AtomicU64>,
    last_viewport: Mutex<(u16, u16)>,
    broker: Arc<RenderBroker>,
    next_panel_id: AtomicU64,
    /// When true AND split mode is on, only the active tab's leaf is
    /// rendered, it fills the whole pane area. Toggling off restores the
    /// split layout. Stored as AtomicBool so the compositor reads it without
    /// locking on every frame.
    zoomed: AtomicBool,
    default_panel_id: AtomicU64,
}

pub struct Workspace {
    pub id: u64,
    pub title: Mutex<String>,
    spaces: Mutex<Vec<Arc<Space>>>,
    dead_tx: watch::Sender<bool>,
    dead_rx: watch::Receiver<bool>,
    spawn_opts: TabSpawnOptions,
    next_tab_id: Arc<AtomicU64>,
    next_space_id: AtomicU64,
    broker: Arc<RenderBroker>,
    /// Pinned workspaces don't auto-close when their last tab
    /// exits — a fresh shell is spawned instead so the workspace
    /// survives `exit` / `C-d`. Matches the macOS cmux app's
    /// `keepWorkspaceOpenWhenClosingLastSurface` setting scoped to
    /// a single workspace.
    pinned: AtomicBool,
    /// Optional user-set color for the workspace. Stored as a
    /// `#RRGGBB` string so the wire format is transparent; the
    /// compositor parses it once per frame into an RGB triple for
    /// the sidebar tint. `None` = default sidebar styling.
    color: Mutex<Option<String>>,
}

#[allow(dead_code)]
impl Space {
    fn new_with_seed_tab(
        workspace_id: u64,
        id: SpaceId,
        title: &str,
        seed_cwd: Option<PathBuf>,
        next_tab_id: Arc<AtomicU64>,
        spawn_opts: TabSpawnOptions,
        broker: Arc<RenderBroker>,
    ) -> Result<Arc<Self>> {
        let tab_id = next_tab_id.fetch_add(1, Ordering::Relaxed);
        let tab = Tab::spawn(
            tab_id,
            workspace_id,
            "sh",
            seed_cwd,
            false,
            &spawn_opts,
            &broker,
        )?;
        let (active_tab_tx, active_tab_rx) = watch::channel(tab.clone());
        let (dead_tx, dead_rx) = watch::channel(false);
        let space = Arc::new(Self {
            id,
            workspace_id,
            title: Mutex::new(title.to_string()),
            panels: Mutex::new(PanelNode::root(tab.id)),
            tabs: Mutex::new(vec![tab.clone()]),
            active_tab_tx,
            active_tab_rx,
            dead_tx,
            dead_rx,
            spawn_opts: spawn_opts.clone(),
            next_tab_id,
            last_viewport: Mutex::new(spawn_opts.initial_viewport),
            broker,
            next_panel_id: AtomicU64::new(1),
            zoomed: AtomicBool::new(false),
            default_panel_id: AtomicU64::new(0),
        });
        space.clone().spawn_tab_reaper(tab);
        Ok(space)
    }

    fn from_snapshot(
        workspace_id: u64,
        id: SpaceId,
        snap: &SpaceSnapshot,
        next_tab_id: Arc<AtomicU64>,
        spawn_opts: TabSpawnOptions,
        broker: Arc<RenderBroker>,
    ) -> Result<Arc<Self>> {
        let mut tabs: Vec<Arc<Tab>> = Vec::with_capacity(snap.tabs.len());
        for t in &snap.tabs {
            let tab_id = next_tab_id.fetch_add(1, Ordering::Relaxed);
            let tab = Tab::spawn(
                tab_id,
                workspace_id,
                &t.title,
                t.cwd.clone(),
                t.explicit_title,
                &spawn_opts,
                &broker,
            )?;
            tabs.push(tab);
        }
        if tabs.is_empty() {
            let tab_id = next_tab_id.fetch_add(1, Ordering::Relaxed);
            let tab = Tab::spawn(
                tab_id,
                workspace_id,
                "sh",
                None,
                false,
                &spawn_opts,
                &broker,
            )?;
            tabs.push(tab);
        }
        let active_idx = snap.active_tab.min(tabs.len() - 1);
        let active = tabs[active_idx].clone();
        let (active_tab_tx, active_tab_rx) = watch::channel(active);
        let (dead_tx, dead_rx) = watch::channel(false);
        let tab_ids: Vec<TabId> = tabs.iter().map(|t| t.id).collect();
        let panels = snap
            .panel_tree
            .as_ref()
            .and_then(|tree| snapshot_panel_to_node(tree, &tab_ids))
            .unwrap_or_else(|| {
                PanelNode::Leaf(Panel {
                    id: 0,
                    tabs: tab_ids.clone(),
                    active_tab: tab_ids
                        .get(active_idx)
                        .copied()
                        .or_else(|| tab_ids.first().copied()),
                })
            });
        let next_panel_id = next_panel_id(&panels).saturating_add(1);
        let default_panel_id = snap
            .active_panel
            .filter(|id| panels.contains_panel(*id))
            .or_else(|| panels.panel_containing_tab(tab_ids[active_idx]))
            .or_else(|| panels.first_panel_id())
            .unwrap_or(0);
        let space = Arc::new(Self {
            id,
            workspace_id,
            title: Mutex::new(snap.title.clone()),
            panels: Mutex::new(panels),
            tabs: Mutex::new(tabs.clone()),
            active_tab_tx,
            active_tab_rx,
            dead_tx,
            dead_rx,
            spawn_opts: spawn_opts.clone(),
            next_tab_id,
            last_viewport: Mutex::new(spawn_opts.initial_viewport),
            broker,
            next_panel_id: AtomicU64::new(next_panel_id),
            zoomed: AtomicBool::new(false),
            default_panel_id: AtomicU64::new(default_panel_id),
        });
        for tab in tabs {
            space.clone().spawn_tab_reaper(tab);
        }
        Ok(space)
    }

    fn spawn_tab_reaper(self: Arc<Self>, tab: Arc<Tab>) {
        let ws = self;
        tokio::spawn(async move {
            let mut alive = tab.alive_rx.clone();
            while *alive.borrow() {
                if alive.changed().await.is_err() {
                    break;
                }
            }
            ws.remove_tab(tab.id).await;
        });
    }

    async fn remove_tab(self: Arc<Self>, tab_id: u64) {
        let existed = {
            let mut tabs = self.tabs.lock().await;
            let before = tabs.len();
            tabs.retain(|t| t.id != tab_id);
            tabs.len() != before
        };
        if !existed {
            return;
        }
        let removal = {
            let mut panels = self.panels.lock().await;
            panels.remove_tab(tab_id)
        };
        self.broker.remove_tab(tab_id);
        if removal.empty {
            self.dead_tx.send(true).ok();
            return;
        }
        if let Some(focus) = removal.focus {
            self.default_panel_id
                .store(focus.panel_id, Ordering::Relaxed);
        }
        let active_removed = self.active_tab_rx.borrow().id == tab_id;
        if active_removed {
            let next = if let Some(focus) = removal.focus {
                self.tab_by_id(focus.tab_id).await
            } else {
                self.first_tab().await
            };
            if let Some(tab) = next {
                self.active_tab_tx.send(tab).ok();
            }
        } else {
            wake_space_repaint(&self);
        }
    }

    async fn new_tab(self: Arc<Self>) -> Result<Arc<Tab>> {
        let panel_id = self.default_panel_id().await.unwrap_or(0);
        self.new_tab_in_panel(panel_id).await
    }

    async fn spawn_shell_tab(&self, cwd: Option<PathBuf>) -> Result<Arc<Tab>> {
        let id = self.next_tab_id.fetch_add(1, Ordering::Relaxed);
        let viewport = *self.last_viewport.lock().await;
        let title = format!("term-{}", local_tab_index(self.workspace_id, id));
        let spawn_opts = TabSpawnOptions {
            shell: self.spawn_opts.shell.clone(),
            fallback_cwd: self.spawn_opts.fallback_cwd.clone(),
            initial_viewport: viewport,
        };
        Tab::spawn(
            id,
            self.workspace_id,
            &title,
            cwd,
            false,
            &spawn_opts,
            &self.broker,
        )
    }

    async fn new_tab_in_panel(self: Arc<Self>, panel_id: PanelId) -> Result<Arc<Tab>> {
        let tab = self.spawn_shell_tab(None).await?;
        {
            let mut tabs = self.tabs.lock().await;
            tabs.push(tab.clone());
        }
        {
            let mut panels = self.panels.lock().await;
            if !panels.add_tab_to_panel(panel_id, tab.id) {
                bail!("no panel {panel_id}");
            }
        }
        self.default_panel_id.store(panel_id, Ordering::Relaxed);
        tab.has_activity.store(false, Ordering::Relaxed);
        self.active_tab_tx.send(tab.clone()).ok();
        self.clone().spawn_tab_reaper(tab.clone());
        Ok(tab)
    }

    async fn select_tab(&self, index: usize) -> Result<Arc<Tab>> {
        let panel_id = self.default_panel_id().await.unwrap_or(0);
        self.select_tab_in_panel(panel_id, index).await
    }

    async fn select_tab_in_panel(&self, panel_id: PanelId, index: usize) -> Result<Arc<Tab>> {
        let tab_id = {
            let mut panels = self.panels.lock().await;
            let panel = panels
                .find_panel(panel_id)
                .ok_or_else(|| anyhow!("no panel {panel_id}"))?;
            let tab_id = *panel
                .tabs
                .get(index)
                .ok_or_else(|| anyhow!("no tab at index {index}"))?;
            panels.set_active_tab(panel_id, tab_id);
            tab_id
        };
        let t = self
            .tab_by_id(tab_id)
            .await
            .ok_or_else(|| anyhow!("no tab {tab_id}"))?;
        t.has_activity.store(false, Ordering::Relaxed);
        self.default_panel_id.store(panel_id, Ordering::Relaxed);
        self.active_tab_tx.send(t.clone()).ok();
        Ok(t)
    }

    async fn offset_active(&self, offset: i32) -> Result<Arc<Tab>> {
        let current_id = self.active_tab_rx.borrow().id;
        self.offset_tab_from(current_id, offset).await
    }

    async fn close_active_tab(&self) -> Result<()> {
        let active = self.active_tab_rx.borrow().clone();
        active.pty_tx.send(PtyOp::Write(vec![0x04])).ok(); // Ctrl-D
        Ok(())
    }

    /// Reorder tabs: remove the tab at `from`, re-insert at `to`.
    /// Indices beyond the bounds clamp to the end. Returns an error
    /// only for truly empty workspaces or an obviously invalid
    /// `from` index.
    async fn move_tab(&self, from: usize, to: usize) -> Result<()> {
        let panel_id = self.default_panel_id().await.unwrap_or(0);
        self.move_tab_in_panel(panel_id, from, to).await
    }

    async fn move_tab_in_panel(&self, panel_id: PanelId, from: usize, to: usize) -> Result<()> {
        self.panels.lock().await.move_tab(panel_id, from, to)
    }

    async fn move_tab_to_panel(
        &self,
        from_panel_id: PanelId,
        from: usize,
        to_panel_id: PanelId,
        to: usize,
    ) -> Result<Arc<Tab>> {
        let tab_id =
            self.panels
                .lock()
                .await
                .move_tab_to_panel(from_panel_id, from, to_panel_id, to)?;
        let tab = self
            .tab_by_id(tab_id)
            .await
            .ok_or_else(|| anyhow!("no tab {tab_id}"))?;
        tab.has_activity.store(false, Ordering::Relaxed);
        self.default_panel_id.store(to_panel_id, Ordering::Relaxed);
        Ok(tab)
    }

    async fn move_tab_to_split(
        self: Arc<Self>,
        from_panel_id: PanelId,
        from: usize,
        target_panel_id: PanelId,
        edge: PanelEdge,
    ) -> Result<(PanelId, Arc<Tab>)> {
        let (moving_tab_id, needs_replacement) = {
            let panels = self.panels.lock().await;
            let source = panels
                .find_panel(from_panel_id)
                .ok_or_else(|| anyhow!("no panel {from_panel_id}"))?;
            let tab_id = source
                .tabs
                .get(from)
                .copied()
                .ok_or_else(|| anyhow!("no tab at index {from}"))?;
            (
                tab_id,
                from_panel_id == target_panel_id && source.tabs.len() <= 1,
            )
        };
        let replacement_tab = if needs_replacement {
            let cwd = if let Some(tab) = self.tab_by_id(moving_tab_id).await {
                tab.cwd.lock().await.clone()
            } else {
                None
            };
            Some(self.spawn_shell_tab(cwd).await?)
        } else {
            None
        };
        let new_panel_id = self.next_panel_id.fetch_add(1, Ordering::Relaxed);
        let tab_id = match self.panels.lock().await.move_tab_to_split(
            from_panel_id,
            from,
            target_panel_id,
            edge,
            new_panel_id,
            replacement_tab.as_ref().map(|tab| tab.id),
        ) {
            Ok(tab_id) => tab_id,
            Err(err) => {
                if let Some(tab) = replacement_tab {
                    tab.pty_tx.send(PtyOp::Write(vec![0x04])).ok();
                    self.broker.remove_tab(tab.id);
                }
                return Err(err);
            }
        };
        if let Some(tab) = replacement_tab {
            {
                let mut tabs = self.tabs.lock().await;
                tabs.push(tab.clone());
            }
            tab.has_activity.store(false, Ordering::Relaxed);
            self.clone().spawn_tab_reaper(tab);
        }
        let tab = self
            .tab_by_id(tab_id)
            .await
            .ok_or_else(|| anyhow!("no tab {tab_id}"))?;
        tab.has_activity.store(false, Ordering::Relaxed);
        self.default_panel_id.store(new_panel_id, Ordering::Relaxed);
        Ok((new_panel_id, tab))
    }

    async fn tab_list(&self) -> (Vec<TabInfo>, usize) {
        let active_id = self.active_tab_rx.borrow().id;
        self.tab_list_with_active(active_id).await
    }

    async fn tab_list_with_active(&self, active_id: u64) -> (Vec<TabInfo>, usize) {
        let panel_id = self
            .panel_containing_tab(active_id)
            .await
            .or_else(|| Some(self.default_panel_id.load(Ordering::Relaxed)))
            .unwrap_or(0);
        self.tab_list_for_panel_with_active(panel_id, active_id)
            .await
    }

    async fn tab_list_for_panel_with_active(
        &self,
        panel_id: PanelId,
        active_id: u64,
    ) -> (Vec<TabInfo>, usize) {
        let tab_ids = {
            let panels = self.panels.lock().await;
            panels
                .find_panel(panel_id)
                .map(|p| p.tabs.clone())
                .unwrap_or_default()
        };
        let tabs = self.tabs.lock().await;
        let by_id: HashMap<TabId, Arc<Tab>> = tabs.iter().map(|t| (t.id, t.clone())).collect();
        self.tab_list_locked(&tab_ids, &by_id, active_id)
    }

    fn tab_list_locked(
        &self,
        tab_ids: &[TabId],
        by_id: &HashMap<TabId, Arc<Tab>>,
        active_id: u64,
    ) -> (Vec<TabInfo>, usize) {
        let mut infos = Vec::with_capacity(tab_ids.len());
        let mut active = 0usize;
        for (i, tab_id) in tab_ids.iter().enumerate() {
            let Some(t) = by_id.get(tab_id) else {
                continue;
            };
            if t.id == active_id {
                active = i;
            }
            let title = t.title.load_full().as_ref().clone();
            // Mask `has_activity` on the active tab — a tab the user
            // is currently looking at is by definition "seen".
            let is_active = t.id == active_id;
            let has_activity = if is_active {
                false
            } else {
                t.has_activity.load(Ordering::Relaxed)
            };
            infos.push(TabInfo {
                id: t.id,
                title,
                has_activity,
                bell_count: t.bell_count.load(Ordering::Relaxed),
            });
        }
        (infos, active)
    }

    async fn first_tab(&self) -> Option<Arc<Tab>> {
        let first_id = self.panels.lock().await.all_tab_ids().first().copied();
        match first_id {
            Some(id) => self.tab_by_id(id).await,
            None => None,
        }
    }

    async fn tab_by_id(&self, tab_id: u64) -> Option<Arc<Tab>> {
        self.tabs
            .lock()
            .await
            .iter()
            .find(|t| t.id == tab_id)
            .cloned()
    }

    async fn tab_at(&self, index: usize) -> Result<Arc<Tab>> {
        let panel_id = self.default_panel_id().await.unwrap_or(0);
        self.tab_at_in_panel(panel_id, index).await
    }

    async fn tab_index(&self, tab_id: u64) -> Option<usize> {
        let panels = self.panels.lock().await;
        let panel_id = panels.panel_containing_tab(tab_id)?;
        panels
            .find_panel(panel_id)?
            .tabs
            .iter()
            .position(|id| *id == tab_id)
    }

    async fn tab_at_in_panel(&self, panel_id: PanelId, index: usize) -> Result<Arc<Tab>> {
        let tab_id = {
            let panels = self.panels.lock().await;
            *panels
                .find_panel(panel_id)
                .ok_or_else(|| anyhow!("no panel {panel_id}"))?
                .tabs
                .get(index)
                .ok_or_else(|| anyhow!("no tab at index {index}"))?
        };
        self.tab_by_id(tab_id)
            .await
            .ok_or_else(|| anyhow!("no tab {tab_id}"))
    }

    async fn offset_tab_from(&self, active_id: u64, offset: i32) -> Result<Arc<Tab>> {
        let (panel_id, tab_id) = {
            let mut panels = self.panels.lock().await;
            let panel_id = panels
                .panel_containing_tab(active_id)
                .or_else(|| panels.first_panel_id())
                .ok_or_else(|| anyhow!("no panels"))?;
            let panel = panels
                .find_panel(panel_id)
                .ok_or_else(|| anyhow!("no panel {panel_id}"))?;
            if panel.tabs.is_empty() {
                bail!("no tabs");
            }
            let current_idx = panel
                .tabs
                .iter()
                .position(|id| *id == active_id)
                .unwrap_or(0);
            let len = panel.tabs.len() as i32;
            let next = ((current_idx as i32 + offset).rem_euclid(len)) as usize;
            let tab_id = panel.tabs[next];
            panels.set_active_tab(panel_id, tab_id);
            (panel_id, tab_id)
        };
        let tab = self
            .tab_by_id(tab_id)
            .await
            .ok_or_else(|| anyhow!("no tab {tab_id}"))?;
        tab.has_activity.store(false, Ordering::Relaxed);
        self.default_panel_id.store(panel_id, Ordering::Relaxed);
        self.active_tab_tx.send(tab.clone()).ok();
        Ok(tab)
    }

    async fn resize(&self, cols: u16, rows: u16) {
        *self.last_viewport.lock().await = (cols, rows);
        let tabs = self.tabs.lock().await;
        for tab in tabs.iter() {
            tab.pty_tx
                .send(PtyOp::Resize(PtySize {
                    cols,
                    rows,
                    pixel_width: 0,
                    pixel_height: 0,
                }))
                .ok();
            self.broker.resize(tab.id, cols, rows);
        }
    }

    async fn resize_panel_tabs(&self, panes: &[(TabId, Rect)]) {
        let tabs = self.tabs.lock().await;
        let by_id: HashMap<TabId, Arc<Tab>> = tabs.iter().map(|t| (t.id, t.clone())).collect();
        for (tab_id, leaf) in panes {
            let Some(tab) = by_id.get(tab_id) else {
                continue;
            };
            tab.pty_tx
                .send(PtyOp::Resize(PtySize {
                    cols: leaf.cols,
                    rows: leaf.rows,
                    pixel_width: 0,
                    pixel_height: 0,
                }))
                .ok();
            self.broker.resize(tab.id, leaf.cols, leaf.rows);
        }
    }

    async fn default_panel_id(&self) -> Option<PanelId> {
        let current = self.default_panel_id.load(Ordering::Relaxed);
        let panels = self.panels.lock().await;
        if panels.contains_panel(current) {
            Some(current)
        } else {
            panels.first_panel_id()
        }
    }

    async fn panel_containing_tab(&self, tab_id: TabId) -> Option<PanelId> {
        self.panels.lock().await.panel_containing_tab(tab_id)
    }

    async fn active_tab_in_panel(&self, panel_id: PanelId) -> Result<Arc<Tab>> {
        let tab_id = {
            let panels = self.panels.lock().await;
            let panel = panels
                .find_panel(panel_id)
                .ok_or_else(|| anyhow!("no panel {panel_id}"))?;
            panel
                .active_tab
                .filter(|id| panel.tabs.contains(id))
                .or_else(|| panel.tabs.first().copied())
                .ok_or_else(|| anyhow!("panel {panel_id} has no tabs"))?
        };
        self.tab_by_id(tab_id)
            .await
            .ok_or_else(|| anyhow!("no tab {tab_id}"))
    }

    async fn split_panel(
        self: Arc<Self>,
        panel_id: PanelId,
        direction: SplitDirection,
    ) -> Result<(PanelId, Arc<Tab>)> {
        let new_panel_id = self.next_panel_id.fetch_add(1, Ordering::Relaxed);
        let tab = self.spawn_shell_tab(None).await?;
        {
            let mut panels = self.panels.lock().await;
            if !panels.split_panel(panel_id, direction, new_panel_id, tab.id) {
                bail!("no panel {panel_id}");
            }
        }
        {
            let mut tabs = self.tabs.lock().await;
            tabs.push(tab.clone());
        }
        self.default_panel_id.store(new_panel_id, Ordering::Relaxed);
        tab.has_activity.store(false, Ordering::Relaxed);
        self.active_tab_tx.send(tab.clone()).ok();
        self.clone().spawn_tab_reaper(tab.clone());
        Ok((new_panel_id, tab))
    }

    async fn flatten_panels(&self, active_panel_id: PanelId, active_tab_id: TabId) -> PanelId {
        let new_panel = self
            .panels
            .lock()
            .await
            .flatten(active_panel_id, active_tab_id);
        self.default_panel_id.store(new_panel, Ordering::Relaxed);
        new_panel
    }

    async fn resize_split_for_panel(&self, panel_id: PanelId, delta: i16) {
        let changed = self
            .panels
            .lock()
            .await
            .resize_active_split(panel_id, delta);
        if changed {
            self.default_panel_id.store(panel_id, Ordering::Relaxed);
        }
    }

    async fn resize_split_at_path(
        &self,
        path: &[SplitPathStep],
        ratio_permille: u16,
    ) -> Result<()> {
        if self
            .panels
            .lock()
            .await
            .resize_split_at_path(path, ratio_permille)
        {
            Ok(())
        } else {
            bail!("no split at path {path:?}")
        }
    }

    async fn snapshot(&self) -> SpaceSnapshot {
        let tabs = self.tabs.lock().await;
        let active_id = self.active_tab_rx.borrow().id;
        let mut out = Vec::with_capacity(tabs.len());
        let mut active = 0usize;
        for (i, t) in tabs.iter().enumerate() {
            if t.id == active_id {
                active = i;
            }
            let title = t.title.load_full().as_ref().clone();
            let cwd = t.cwd.lock().await.clone();
            let explicit_title = t.explicit_title.load(Ordering::Relaxed);
            out.push(TabSnapshot {
                title,
                cwd,
                explicit_title,
            });
        }
        let title = self.title.lock().await.clone();
        let tab_index_by_id: HashMap<TabId, usize> = tabs
            .iter()
            .enumerate()
            .map(|(idx, tab)| (tab.id, idx))
            .collect();
        let panels = self.panels.lock().await;
        let panel_tree = panel_node_to_snapshot(&panels, &tab_index_by_id);
        drop(panels);
        SpaceSnapshot {
            title,
            active_tab: active,
            tabs: out,
            active_panel: self.default_panel_id().await,
            panel_tree,
        }
    }
}

#[allow(dead_code)]
impl Workspace {
    fn new_with_seed_space(
        id: u64,
        title: &str,
        seed_cwd: Option<PathBuf>,
        spawn_opts: TabSpawnOptions,
        broker: Arc<RenderBroker>,
    ) -> Result<Arc<Self>> {
        let next_tab_id = Arc::new(AtomicU64::new(workspace_tab_id(id, 0)));
        let space = Space::new_with_seed_tab(
            id,
            workspace_space_id(id, 0),
            "space-1",
            seed_cwd,
            next_tab_id.clone(),
            spawn_opts.clone(),
            broker.clone(),
        )?;
        let (dead_tx, dead_rx) = watch::channel(false);
        let ws = Arc::new(Self {
            id,
            title: Mutex::new(title.to_string()),
            spaces: Mutex::new(vec![space.clone()]),
            dead_tx,
            dead_rx,
            spawn_opts: spawn_opts.clone(),
            next_tab_id,
            next_space_id: AtomicU64::new(1),
            broker,
            pinned: AtomicBool::new(false),
            color: Mutex::new(None),
        });
        ws.clone().spawn_space_reaper(space);
        Ok(ws)
    }

    fn from_snapshot(
        id: u64,
        snap: &WorkspaceSnapshot,
        spawn_opts: TabSpawnOptions,
        broker: Arc<RenderBroker>,
    ) -> Result<Arc<Self>> {
        let next_tab_id = Arc::new(AtomicU64::new(workspace_tab_id(id, 0)));
        let mut spaces: Vec<Arc<Space>> = Vec::new();
        if snap.spaces.is_empty() {
            let legacy = SpaceSnapshot {
                title: "space-1".into(),
                active_tab: snap.active_tab,
                tabs: snap.tabs.clone(),
                active_panel: snap.active_panel,
                panel_tree: snap.panel_tree.clone(),
            };
            spaces.push(Space::from_snapshot(
                id,
                workspace_space_id(id, 0),
                &legacy,
                next_tab_id.clone(),
                spawn_opts.clone(),
                broker.clone(),
            )?);
        } else {
            for (idx, space_snap) in snap.spaces.iter().enumerate() {
                spaces.push(Space::from_snapshot(
                    id,
                    workspace_space_id(id, idx as u64),
                    space_snap,
                    next_tab_id.clone(),
                    spawn_opts.clone(),
                    broker.clone(),
                )?);
            }
        }
        let (dead_tx, dead_rx) = watch::channel(false);
        let ws = Arc::new(Self {
            id,
            title: Mutex::new(snap.title.clone()),
            spaces: Mutex::new(spaces.clone()),
            dead_tx,
            dead_rx,
            spawn_opts: spawn_opts.clone(),
            next_tab_id,
            next_space_id: AtomicU64::new(spaces.len() as u64),
            broker,
            pinned: AtomicBool::new(snap.pinned),
            color: Mutex::new(snap.color.clone()),
        });
        for space in spaces {
            ws.clone().spawn_space_reaper(space);
        }
        Ok(ws)
    }

    fn spawn_space_reaper(self: Arc<Self>, space: Arc<Space>) {
        let workspace = self;
        tokio::spawn(async move {
            let mut dead = space.dead_rx.clone();
            while !*dead.borrow() {
                if dead.changed().await.is_err() {
                    break;
                }
            }
            workspace.remove_space(space.id).await;
        });
    }

    async fn remove_space(self: Arc<Self>, space_id: SpaceId) {
        let (remaining, was_removed) = {
            let mut spaces = self.spaces.lock().await;
            let before = spaces.len();
            spaces.retain(|space| space.id != space_id);
            (spaces.len(), spaces.len() != before)
        };
        if !was_removed {
            return;
        }
        if remaining == 0 {
            if self.pinned.load(Ordering::Relaxed) {
                if let Err(e) = self.clone().new_space(None).await {
                    tracing::warn!(error = %e, "pinned workspace could not respawn a space");
                    self.dead_tx.send(true).ok();
                }
            } else {
                self.dead_tx.send(true).ok();
            }
        }
    }

    async fn first_space(&self) -> Option<Arc<Space>> {
        self.spaces.lock().await.first().cloned()
    }

    async fn space_by_id(&self, space_id: SpaceId) -> Option<Arc<Space>> {
        self.spaces
            .lock()
            .await
            .iter()
            .find(|space| space.id == space_id)
            .cloned()
    }

    async fn space_at(&self, index: usize) -> Result<Arc<Space>> {
        self.spaces
            .lock()
            .await
            .get(index)
            .cloned()
            .ok_or_else(|| anyhow!("no space at index {index}"))
    }

    async fn space_index(&self, space_id: SpaceId) -> Option<usize> {
        self.spaces
            .lock()
            .await
            .iter()
            .position(|space| space.id == space_id)
    }

    async fn space_list_with_active(&self, active_space_id: SpaceId) -> (Vec<SpaceInfo>, usize) {
        let spaces = self.spaces.lock().await;
        let mut infos = Vec::with_capacity(spaces.len());
        let mut active = 0usize;
        for (idx, space) in spaces.iter().enumerate() {
            if space.id == active_space_id {
                active = idx;
            }
            let title = space.title.lock().await.clone();
            let tabs = space.tabs.lock().await;
            let terminal_count = tabs.len();
            let pane_count = space.panels.lock().await.leaves().len();
            drop(tabs);
            infos.push(SpaceInfo {
                id: space.id,
                title,
                pane_count,
                terminal_count,
            });
        }
        (infos, active)
    }

    async fn total_terminal_count(&self) -> usize {
        let spaces = self.spaces.lock().await.clone();
        let mut count = 0usize;
        for space in spaces {
            count += space.tabs.lock().await.len();
        }
        count
    }

    async fn new_space(self: Arc<Self>, title: Option<String>) -> Result<Arc<Space>> {
        let local_id = self.next_space_id.fetch_add(1, Ordering::Relaxed);
        let space_id = workspace_space_id(self.id, local_id);
        let title = title.unwrap_or_else(|| format!("space-{}", local_id + 1));
        let space = Space::new_with_seed_tab(
            self.id,
            space_id,
            &title,
            self.spawn_opts.fallback_cwd.clone(),
            self.next_tab_id.clone(),
            self.spawn_opts.clone(),
            self.broker.clone(),
        )?;
        {
            let mut spaces = self.spaces.lock().await;
            spaces.push(space.clone());
        }
        self.clone().spawn_space_reaper(space.clone());
        Ok(space)
    }

    async fn snapshot(&self) -> WorkspaceSnapshot {
        let spaces = self.spaces.lock().await;
        let mut out = Vec::with_capacity(spaces.len());
        for space in spaces.iter() {
            out.push(space.snapshot().await);
        }
        let title = self.title.lock().await.clone();
        let color = self.color.lock().await.clone();
        WorkspaceSnapshot {
            title,
            active_space: 0,
            spaces: out,
            active_tab: 0,
            tabs: Vec::new(),
            split_direction: None,
            first_split_ratio_permille: 500,
            active_panel: None,
            panel_tree: None,
            pinned: self.pinned.load(Ordering::Relaxed),
            color,
        }
    }
}

// ----------------------------- Window view -----------------------------

#[derive(Debug, Clone)]
struct WindowState {
    active_ws_id: u64,
    active_space_by_ws: HashMap<u64, SpaceId>,
    active_panel_by_space: HashMap<SpaceId, PanelId>,
    active_tab_by_panel: HashMap<PanelRef, TabId>,
    pane_focus_anchor_by_space: HashMap<SpaceId, PaneFocusAnchor>,
    sidebar_focused: bool,
    space_strip_focused: bool,
}

impl WindowState {
    async fn new(daemon: &Daemon) -> Self {
        let active_ws_id = daemon.active_ws_rx.borrow().id;
        Self {
            active_ws_id,
            active_space_by_ws: HashMap::new(),
            active_panel_by_space: HashMap::new(),
            active_tab_by_panel: HashMap::new(),
            pane_focus_anchor_by_space: HashMap::new(),
            sidebar_focused: false,
            space_strip_focused: false,
        }
    }

    async fn active_workspace(&mut self, daemon: &Daemon) -> Result<Arc<Workspace>> {
        if let Some(ws) = daemon.workspace_by_id(self.active_ws_id).await {
            return Ok(ws);
        }
        let ws = daemon
            .first_workspace()
            .await
            .ok_or_else(|| anyhow!("no workspaces"))?;
        self.active_ws_id = ws.id;
        Ok(ws)
    }

    async fn active_workspace_index(&mut self, daemon: &Daemon) -> Result<usize> {
        let ws = self.active_workspace(daemon).await?;
        Ok(daemon.workspace_index(ws.id).await.unwrap_or(0))
    }

    async fn active_space(&mut self, ws: &Arc<Workspace>) -> Result<Arc<Space>> {
        if let Some(space_id) = self.active_space_by_ws.get(&ws.id).copied()
            && let Some(space) = ws.space_by_id(space_id).await
        {
            return Ok(space);
        }
        let space = ws.first_space().await.ok_or_else(|| anyhow!("no spaces"))?;
        self.active_space_by_ws.insert(ws.id, space.id);
        Ok(space)
    }

    async fn active_space_index(&mut self, ws: &Arc<Workspace>) -> Result<usize> {
        let space = self.active_space(ws).await?;
        Ok(ws.space_index(space.id).await.unwrap_or(0))
    }

    async fn active_tab(&mut self, space: &Arc<Space>) -> Result<Arc<Tab>> {
        let panel_id = self.active_panel(space).await?;
        let panel_ref = PanelRef {
            space_id: space.id,
            panel_id,
        };
        if let Some(tab_id) = self.active_tab_by_panel.get(&panel_ref).copied()
            && space.panel_containing_tab(tab_id).await == Some(panel_id)
            && let Some(tab) = space.tab_by_id(tab_id).await
        {
            return Ok(tab);
        }
        let tab = space.active_tab_in_panel(panel_id).await?;
        self.active_tab_by_panel.insert(panel_ref, tab.id);
        Ok(tab)
    }

    async fn active_panel(&mut self, space: &Arc<Space>) -> Result<PanelId> {
        if let Some(panel_id) = self.active_panel_by_space.get(&space.id).copied()
            && space.panels.lock().await.contains_panel(panel_id)
        {
            return Ok(panel_id);
        }
        let panel_id = space
            .default_panel_id()
            .await
            .ok_or_else(|| anyhow!("no panels"))?;
        self.active_panel_by_space.insert(space.id, panel_id);
        Ok(panel_id)
    }

    async fn select_workspace(&mut self, daemon: &Daemon, index: usize) -> Result<Arc<Workspace>> {
        let ws = daemon.workspace_at(index).await?;
        self.active_ws_id = ws.id;
        Ok(ws)
    }

    async fn offset_workspace(&mut self, daemon: &Daemon, offset: i32) -> Result<Arc<Workspace>> {
        let workspaces = daemon.workspaces.lock().await;
        if workspaces.is_empty() {
            bail!("no workspaces");
        }
        let current_idx = workspaces
            .iter()
            .position(|w| w.id == self.active_ws_id)
            .unwrap_or(0);
        let len = workspaces.len() as i32;
        let next = ((current_idx as i32 + offset).rem_euclid(len)) as usize;
        let ws = workspaces[next].clone();
        drop(workspaces);
        self.active_ws_id = ws.id;
        Ok(ws)
    }

    async fn select_space(&mut self, ws: &Arc<Workspace>, index: usize) -> Result<Arc<Space>> {
        let space = ws.space_at(index).await?;
        self.active_space_by_ws.insert(ws.id, space.id);
        Ok(space)
    }

    async fn offset_space(&mut self, ws: &Arc<Workspace>, offset: i32) -> Result<Arc<Space>> {
        let spaces = ws.spaces.lock().await;
        if spaces.is_empty() {
            bail!("no spaces");
        }
        let current_id = self
            .active_space_by_ws
            .get(&ws.id)
            .copied()
            .unwrap_or_else(|| spaces[0].id);
        let current_idx = spaces
            .iter()
            .position(|space| space.id == current_id)
            .unwrap_or(0);
        let len = spaces.len() as i32;
        let next = ((current_idx as i32 + offset).rem_euclid(len)) as usize;
        let space = spaces[next].clone();
        drop(spaces);
        self.active_space_by_ws.insert(ws.id, space.id);
        Ok(space)
    }

    async fn select_tab(&mut self, space: &Arc<Space>, index: usize) -> Result<Arc<Tab>> {
        let panel_id = self.active_panel(space).await?;
        let tab = space.select_tab_in_panel(panel_id, index).await?;
        tab.has_activity.store(false, Ordering::Relaxed);
        self.active_tab_by_panel.insert(
            PanelRef {
                space_id: space.id,
                panel_id,
            },
            tab.id,
        );
        Ok(tab)
    }

    async fn offset_tab(&mut self, space: &Arc<Space>, offset: i32) -> Result<Arc<Tab>> {
        let active = self.active_tab(space).await?;
        let tab = space.offset_tab_from(active.id, offset).await?;
        tab.has_activity.store(false, Ordering::Relaxed);
        if let Some(panel_id) = space.panel_containing_tab(tab.id).await {
            self.active_panel_by_space.insert(space.id, panel_id);
            self.active_tab_by_panel.insert(
                PanelRef {
                    space_id: space.id,
                    panel_id,
                },
                tab.id,
            );
        }
        Ok(tab)
    }

    fn remember_tab(
        &mut self,
        ws: &Arc<Workspace>,
        space: &Arc<Space>,
        panel_id: PanelId,
        tab: &Arc<Tab>,
    ) {
        self.active_space_by_ws.insert(ws.id, space.id);
        self.active_panel_by_space.insert(space.id, panel_id);
        self.active_tab_by_panel.insert(
            PanelRef {
                space_id: space.id,
                panel_id,
            },
            tab.id,
        );
    }

    fn remember_panel(
        &mut self,
        ws: &Arc<Workspace>,
        space: &Arc<Space>,
        panel_id: PanelId,
        tab_id: TabId,
    ) {
        self.active_space_by_ws.insert(ws.id, space.id);
        self.active_panel_by_space.insert(space.id, panel_id);
        self.active_tab_by_panel.insert(
            PanelRef {
                space_id: space.id,
                panel_id,
            },
            tab_id,
        );
    }

    fn pane_focus_anchor(&self, space: &Arc<Space>) -> Option<PaneFocusAnchor> {
        self.pane_focus_anchor_by_space.get(&space.id).copied()
    }

    fn remember_pane_focus_anchor(&mut self, space: &Arc<Space>, anchor: PaneFocusAnchor) {
        self.pane_focus_anchor_by_space.insert(space.id, anchor);
    }

    fn remember_pane_focus_anchor_for_panel(
        &mut self,
        space: &Arc<Space>,
        leaves: &[ResolvedPanelLeaf],
        panel_id: PanelId,
    ) {
        if let Some(leaf) = leaves.iter().find(|leaf| leaf.panel_id == panel_id) {
            self.remember_pane_focus_anchor(space, rect_center_anchor(leaf.inner));
        }
    }
}

// ------------------------------- Daemon --------------------------------

pub struct Daemon {
    workspaces: Mutex<Vec<Arc<Workspace>>>,
    active_ws_tx: watch::Sender<Arc<Workspace>>,
    active_ws_rx: watch::Receiver<Arc<Workspace>>,
    model_tx: watch::Sender<u64>,
    model_rx: watch::Receiver<u64>,
    model_version: AtomicU64,
    client_views: Mutex<HashMap<String, ClientView>>,
    shutdown_tx: watch::Sender<bool>,
    pub shutdown_rx: watch::Receiver<bool>,
    spawn_opts: TabSpawnOptions,
    next_ws_id: AtomicU64,
    snapshot_path: Option<PathBuf>,
    buffers: Mutex<Vec<Buffer>>,
    keybinds_tx: watch::Sender<Arc<KeybindTable>>,
    keybinds_rx: watch::Receiver<Arc<KeybindTable>>,
    /// User-configured shell command fired on every `cmx notify`.
    /// Swapped atomically by the settings watcher on hot reload.
    notification_command: arc_swap::ArcSwapOption<String>,
    /// Transient message shown in the status bar in place of the
    /// usual `[workspace]` label, until `expires_ms` passes. Set by
    /// `Command::DisplayMessage`, read by `build_chrome_spec`.
    display_message: Mutex<Option<DisplayMessage>>,
    broker: Arc<RenderBroker>,
    terminal_theme: Option<NativeTerminalThemeSet>,
    terminal_theme_override: Mutex<Option<NativeTerminalThemeSet>>,
    terminal_font: Option<NativeTerminalFont>,
    terminal_cursor: Option<NativeTerminalCursor>,
}

#[derive(Debug, Clone)]
struct ClientView {
    kind: AttachedClientKind,
    terminals: Vec<(TabId, Rect)>,
    updated_at_ms: u64,
    latency_ms: Option<u32>,
}

fn prune_stale_client_views(views: &mut HashMap<String, ClientView>) {
    let now = now_unix_millis();
    views.retain(|_, view| now.saturating_sub(view.updated_at_ms) <= CLIENT_VIEW_STALE_TIMEOUT_MS);
}

#[derive(Debug, Clone)]
struct DisplayMessage {
    text: String,
    expires_ms: u64,
}

#[derive(Debug, Clone)]
struct Buffer {
    name: Option<String>,
    data: String,
}

/// Cap on how many buffers the server keeps. Configurable in M8.
const MAX_BUFFERS: usize = 50;

/// Max preview characters returned by `ListBuffers`.
const BUFFER_PREVIEW_CHARS: usize = 60;

#[allow(dead_code)]
impl Daemon {
    async fn start(opts: &ServerOptions, broker: Arc<RenderBroker>) -> Result<Arc<Self>> {
        let spawn_opts = TabSpawnOptions {
            shell: opts.shell.clone(),
            fallback_cwd: opts.cwd.clone(),
            initial_viewport: opts.initial_viewport,
        };
        let terminal_theme = ghostty_theme::load_terminal_theme()
            .as_ref()
            .map(active_terminal_theme_set_for_host);
        broker.set_default_colors(terminal_default_colors_from_theme(terminal_theme.as_ref()));

        // If a snapshot exists, load it. Otherwise, start fresh.
        let loaded: Option<Snapshot> = opts.snapshot_path.as_deref().and_then(snapshot::load);

        let (workspaces, active_idx, next_id) = if let Some(snap) = loaded {
            let mut workspaces = Vec::with_capacity(snap.workspaces.len());
            let mut next_id = 0u64;
            for ws_snap in &snap.workspaces {
                let ws =
                    Workspace::from_snapshot(next_id, ws_snap, spawn_opts.clone(), broker.clone())?;
                workspaces.push(ws);
                next_id += 1;
            }
            if workspaces.is_empty() {
                let ws = Workspace::new_with_seed_space(
                    0,
                    "main",
                    spawn_opts.fallback_cwd.clone(),
                    spawn_opts.clone(),
                    broker.clone(),
                )?;
                (vec![ws], 0, 1u64)
            } else {
                let active = snap.active_workspace.min(workspaces.len() - 1);
                (workspaces, active, next_id)
            }
        } else {
            let ws = Workspace::new_with_seed_space(
                0,
                "main",
                spawn_opts.fallback_cwd.clone(),
                spawn_opts.clone(),
                broker.clone(),
            )?;
            (vec![ws], 0, 1u64)
        };

        let active_ws = workspaces[active_idx].clone();
        let (active_ws_tx, active_ws_rx) = watch::channel(active_ws);
        let (model_tx, model_rx) = watch::channel(0);
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let initial_settings = opts
            .settings_path
            .as_deref()
            .map(|p| settings::load(p).unwrap_or_default())
            .unwrap_or_default();
        let initial_table = Arc::new(settings::compile(&initial_settings));
        let (keybinds_tx, keybinds_rx) = watch::channel(initial_table);
        let notification_command = arc_swap::ArcSwapOption::new(
            initial_settings.notifications.command.clone().map(Arc::new),
        );
        let terminal_font = {
            let font = ghostty_theme::load_terminal_font();
            ghostty_theme::font_has_any_setting(&font).then_some(font)
        };
        let terminal_cursor = {
            let cursor = ghostty_theme::load_terminal_cursor();
            ghostty_theme::cursor_has_any_setting(&cursor).then_some(cursor)
        };

        let daemon = Arc::new(Self {
            workspaces: Mutex::new(workspaces.clone()),
            active_ws_tx,
            active_ws_rx,
            model_tx,
            model_rx,
            model_version: AtomicU64::new(0),
            client_views: Mutex::new(HashMap::new()),
            shutdown_tx,
            shutdown_rx,
            spawn_opts,
            next_ws_id: AtomicU64::new(next_id),
            snapshot_path: opts.snapshot_path.clone(),
            buffers: Mutex::new(Vec::new()),
            keybinds_tx,
            keybinds_rx,
            notification_command,
            display_message: Mutex::new(None),
            broker,
            terminal_theme,
            terminal_theme_override: Mutex::new(None),
            terminal_font,
            terminal_cursor,
        });
        for ws in workspaces {
            daemon.clone().spawn_workspace_reaper(ws);
        }
        Ok(daemon)
    }

    fn wake_model(&self) {
        let next = self.model_version.fetch_add(1, Ordering::Relaxed) + 1;
        self.model_tx.send(next).ok();
    }

    fn model_rx(&self) -> watch::Receiver<u64> {
        self.model_rx.clone()
    }

    async fn first_workspace(&self) -> Option<Arc<Workspace>> {
        self.workspaces.lock().await.first().cloned()
    }

    async fn workspace_by_id(&self, ws_id: u64) -> Option<Arc<Workspace>> {
        self.workspaces
            .lock()
            .await
            .iter()
            .find(|w| w.id == ws_id)
            .cloned()
    }

    async fn workspace_at(&self, index: usize) -> Result<Arc<Workspace>> {
        self.workspaces
            .lock()
            .await
            .get(index)
            .cloned()
            .ok_or_else(|| anyhow!("no workspace at index {index}"))
    }

    async fn workspace_index(&self, ws_id: u64) -> Option<usize> {
        self.workspaces
            .lock()
            .await
            .iter()
            .position(|w| w.id == ws_id)
    }

    async fn workspace_list_with_active(&self, active_ws_id: u64) -> (Vec<WorkspaceInfo>, usize) {
        let workspaces = self.workspaces.lock().await;
        let mut infos = Vec::with_capacity(workspaces.len());
        let mut active = 0usize;
        for (i, w) in workspaces.iter().enumerate() {
            if w.id == active_ws_id {
                active = i;
            }
            let title = w.title.lock().await.clone();
            let spaces = w.spaces.lock().await;
            let space_count = spaces.len();
            let mut terminal_count = 0usize;
            for space in spaces.iter() {
                terminal_count += space.tabs.lock().await.len();
            }
            drop(spaces);
            let color = w.color.lock().await.clone();
            infos.push(WorkspaceInfo {
                id: w.id,
                title,
                space_count,
                tab_count: terminal_count,
                terminal_count,
                pinned: w.pinned.load(Ordering::Relaxed),
                color,
            });
        }
        (infos, active)
    }

    async fn update_client_view(
        &self,
        client_id: &str,
        window: &mut WindowState,
        viewport: (u16, u16),
    ) {
        let panes = window_pane_paints(self, window, viewport)
            .await
            .unwrap_or_default();
        let changed = {
            let mut views = self.client_views.lock().await;
            let now = now_unix_millis();
            let changed = views
                .get(client_id)
                .is_none_or(|view| view.kind != AttachedClientKind::Tui || view.terminals != panes);
            if changed {
                let latency_ms = views.get(client_id).and_then(|view| view.latency_ms);
                views.insert(
                    client_id.to_string(),
                    ClientView {
                        kind: AttachedClientKind::Tui,
                        terminals: panes,
                        updated_at_ms: now,
                        latency_ms,
                    },
                );
            } else if let Some(view) = views.get_mut(client_id) {
                view.updated_at_ms = now;
            }
            changed
        };
        if changed {
            self.apply_canonical_tab_sizes().await;
            self.wake_model();
        }
    }

    async fn remove_client_view(&self, client_id: &str) {
        let removed = {
            let mut views = self.client_views.lock().await;
            views.remove(client_id).is_some()
        };
        if removed {
            self.apply_canonical_tab_sizes().await;
            self.wake_model();
        }
    }

    async fn update_client_native_view(
        &self,
        client_id: &str,
        terminals: Vec<NativeTerminalViewport>,
    ) {
        let panes: Vec<(TabId, Rect)> = terminals
            .into_iter()
            .map(|terminal| {
                (
                    terminal.tab_id,
                    Rect {
                        col: 0,
                        row: 0,
                        cols: terminal.cols.max(1),
                        rows: terminal.rows.max(1),
                    },
                )
            })
            .collect();
        let changed = {
            let mut views = self.client_views.lock().await;
            let now = now_unix_millis();
            let changed = views.get(client_id).is_none_or(|view| {
                view.kind != AttachedClientKind::Native || view.terminals != panes
            });
            if changed {
                let latency_ms = views.get(client_id).and_then(|view| view.latency_ms);
                views.insert(
                    client_id.to_string(),
                    ClientView {
                        kind: AttachedClientKind::Native,
                        terminals: panes,
                        updated_at_ms: now,
                        latency_ms,
                    },
                );
            } else if let Some(view) = views.get_mut(client_id) {
                view.updated_at_ms = now;
            }
            changed
        };
        if changed {
            self.apply_canonical_tab_sizes().await;
            self.wake_model();
        }
    }

    async fn update_client_latency(&self, client_id: &str, latency_ms: u32) {
        let changed = {
            let mut views = self.client_views.lock().await;
            let Some(view) = views.get_mut(client_id) else {
                return;
            };
            let latency_ms = latency_ms.min(60_000);
            let changed = view.latency_ms != Some(latency_ms);
            view.latency_ms = Some(latency_ms);
            view.updated_at_ms = now_unix_millis();
            changed
        };
        if changed {
            self.wake_model();
        }
    }

    async fn update_terminal_colors(&self, colors: TerminalColorReport) {
        self.broker
            .set_terminal_probe_colors(terminal_probe_colors_from_report(&colors));
        self.broker
            .set_default_colors(terminal_default_colors_from_report(&colors));

        let next_theme = terminal_theme_set_from_report(&colors);
        let changed = {
            let mut theme = self.terminal_theme_override.lock().await;
            let changed = *theme != next_theme;
            *theme = next_theme;
            changed
        };
        if changed {
            self.wake_model();
        }
    }

    async fn native_terminal_theme(&self) -> Option<NativeTerminalThemeSet> {
        self.terminal_theme_override
            .lock()
            .await
            .clone()
            .or_else(|| self.terminal_theme.clone())
    }

    async fn client_latency_ms(&self, client_id: &str) -> Option<u32> {
        self.client_views
            .lock()
            .await
            .get(client_id)
            .and_then(|view| view.latency_ms)
    }

    async fn apply_canonical_tab_sizes(&self) {
        let views = {
            let mut views = self.client_views.lock().await;
            prune_stale_client_views(&mut views);
            views.clone()
        };
        let mut sizes: HashMap<TabId, (u16, u16)> = HashMap::new();
        for view in views.values() {
            for (tab_id, rect) in &view.terminals {
                let size = tab_size(*rect);
                sizes
                    .entry(*tab_id)
                    .and_modify(|current| {
                        current.0 = current.0.min(size.0);
                        current.1 = current.1.min(size.1);
                    })
                    .or_insert(size);
            }
        }

        let workspaces = self.workspaces.lock().await;
        for ws in workspaces.iter() {
            let spaces = ws.spaces.lock().await.clone();
            for space in spaces {
                let tabs = space.tabs.lock().await;
                for tab in tabs.iter() {
                    let Some((cols, rows)) = sizes.get(&tab.id).copied() else {
                        continue;
                    };
                    tab.pty_tx
                        .send(PtyOp::Resize(PtySize {
                            cols,
                            rows,
                            pixel_width: 0,
                            pixel_height: 0,
                        }))
                        .ok();
                    self.broker.resize(tab.id, cols, rows);
                }
            }
        }
    }

    async fn attached_client_infos(&self) -> Vec<AttachedClientInfo> {
        let views = {
            let mut views = self.client_views.lock().await;
            prune_stale_client_views(&mut views);
            views.clone()
        };
        let mut clients: Vec<AttachedClientInfo> = views
            .into_iter()
            .map(|(client_id, view)| {
                let terminals = view
                    .terminals
                    .into_iter()
                    .map(|(tab_id, rect)| {
                        let (cols, rows) = tab_size(rect);
                        NativeTerminalViewport { tab_id, cols, rows }
                    })
                    .collect::<Vec<_>>();
                AttachedClientInfo {
                    client_id,
                    kind: view.kind,
                    visible_terminal_count: terminals.len(),
                    updated_at_ms: view.updated_at_ms,
                    terminals,
                    latency_ms: view.latency_ms,
                }
            })
            .collect();
        clients.sort_by(|a, b| a.client_id.cmp(&b.client_id));
        clients
    }

    async fn tab_by_id(&self, tab_id: TabId) -> Option<Arc<Tab>> {
        let workspaces = self.workspaces.lock().await.clone();
        for ws in workspaces {
            let spaces = ws.spaces.lock().await.clone();
            for space in spaces {
                if let Some(tab) = space.tab_by_id(tab_id).await {
                    return Some(tab);
                }
            }
        }
        None
    }

    fn spawn_workspace_reaper(self: Arc<Self>, ws: Arc<Workspace>) {
        let daemon = self;
        tokio::spawn(async move {
            let mut dead = ws.dead_rx.clone();
            while !*dead.borrow() {
                if dead.changed().await.is_err() {
                    break;
                }
            }
            daemon.remove_workspace(ws.id).await;
        });
    }

    async fn remove_workspace(self: Arc<Self>, ws_id: u64) {
        let (empty, new_active) = {
            let mut workspaces = self.workspaces.lock().await;
            let before = workspaces.len();
            let was_active_idx = workspaces.iter().position(|w| w.id == ws_id);
            workspaces.retain(|w| w.id != ws_id);
            if workspaces.len() == before {
                return;
            }
            let empty = workspaces.is_empty();
            let active_id = self.active_ws_rx.borrow().id;
            let new_active = if !empty && active_id == ws_id {
                let idx = was_active_idx.unwrap_or(0).min(workspaces.len() - 1);
                Some(workspaces[idx].clone())
            } else {
                None
            };
            (empty, new_active)
        };
        if let Some(w) = new_active {
            self.active_ws_tx.send(w).ok();
        }
        self.wake_model();
        if empty {
            self.shutdown_tx.send(true).ok();
        }
    }

    async fn new_workspace(
        self: Arc<Self>,
        title: Option<String>,
        cwd: Option<PathBuf>,
    ) -> Result<Arc<Workspace>> {
        let id = self.next_ws_id.fetch_add(1, Ordering::Relaxed);
        let title = title.unwrap_or_else(|| format!("ws-{id}"));
        let ws = Workspace::new_with_seed_space(
            id,
            &title,
            cwd,
            self.spawn_opts.clone(),
            self.broker.clone(),
        )?;
        {
            let mut workspaces = self.workspaces.lock().await;
            workspaces.push(ws.clone());
        }
        self.active_ws_tx.send(ws.clone()).ok();
        self.clone().spawn_workspace_reaper(ws.clone());
        Ok(ws)
    }

    async fn select_workspace(&self, index: usize) -> Result<Arc<Workspace>> {
        let workspaces = self.workspaces.lock().await;
        let w = workspaces
            .get(index)
            .cloned()
            .ok_or_else(|| anyhow!("no workspace at index {index}"))?;
        drop(workspaces);
        self.active_ws_tx.send(w.clone()).ok();
        Ok(w)
    }

    async fn offset_active_workspace(&self, offset: i32) -> Result<Arc<Workspace>> {
        let workspaces = self.workspaces.lock().await;
        if workspaces.is_empty() {
            bail!("no workspaces");
        }
        let current_id = self.active_ws_rx.borrow().id;
        let current_idx = workspaces
            .iter()
            .position(|w| w.id == current_id)
            .unwrap_or(0);
        let len = workspaces.len() as i32;
        let next = ((current_idx as i32 + offset).rem_euclid(len)) as usize;
        let w = workspaces[next].clone();
        drop(workspaces);
        self.active_ws_tx.send(w.clone()).ok();
        Ok(w)
    }

    async fn close_active_workspace(&self) -> Result<()> {
        let active = self.active_ws_rx.borrow().clone();
        // Signal Ctrl-D to every tab in the workspace; they'll exit and the
        // workspace reaper will clean up.
        let spaces = active.spaces.lock().await.clone();
        for space in spaces {
            let tabs = space.tabs.lock().await;
            for tab in tabs.iter() {
                tab.pty_tx.send(PtyOp::Write(vec![0x04])).ok();
            }
        }
        Ok(())
    }

    async fn kill_all_tabs(&self) {
        let workspaces = self.workspaces.lock().await.clone();
        for ws in workspaces {
            let spaces = ws.spaces.lock().await.clone();
            for space in spaces {
                let tabs = space.tabs.lock().await.clone();
                for tab in tabs {
                    tab.kill_child();
                }
            }
        }
    }

    async fn workspace_list(&self) -> (Vec<WorkspaceInfo>, usize) {
        let workspaces = self.workspaces.lock().await;
        let active_id = self.active_ws_rx.borrow().id;
        let mut infos = Vec::with_capacity(workspaces.len());
        let mut active = 0usize;
        for (i, w) in workspaces.iter().enumerate() {
            if w.id == active_id {
                active = i;
            }
            let title = w.title.lock().await.clone();
            let spaces = w.spaces.lock().await;
            let space_count = spaces.len();
            let mut terminal_count = 0usize;
            for space in spaces.iter() {
                terminal_count += space.tabs.lock().await.len();
            }
            drop(spaces);
            let color = w.color.lock().await.clone();
            infos.push(WorkspaceInfo {
                id: w.id,
                title,
                space_count,
                tab_count: terminal_count,
                terminal_count,
                pinned: w.pinned.load(Ordering::Relaxed),
                color,
            });
        }
        (infos, active)
    }

    /// Resize in response to a client viewport change. `viewport_cols` /
    /// `viewport_rows` describe the whole visible area; cmx reserves chrome
    /// (sidebar + status) so the pane PTY gets the remaining interior.
    async fn resize(&self, viewport_cols: u16, viewport_rows: u16) {
        let active = self.active_ws_rx.borrow().clone();
        let Some(space) = active.first_space().await else {
            return;
        };
        *space.last_viewport.lock().await = (viewport_cols, viewport_rows);
        let panels = space.panels.lock().await.clone();
        let leaves = chrome_layout_panel_leaves((viewport_cols, viewport_rows), &panels);
        let mut sizes = Vec::new();
        for leaf in leaves {
            for tab_id in leaf.tab_ids {
                sizes.push((tab_id, leaf.inner));
            }
        }
        space.resize_panel_tabs(&sizes).await;
    }

    /// Fresh snapshot of the current keybind table. Callers (per-client
    /// handlers) build an InputHandler from this.
    pub fn keybind_table(&self) -> KeybindTable {
        (**self.keybinds_rx.borrow()).clone()
    }

    /// Subscribe to keybind-table updates. Handles `.changed()` the usual
    /// way.
    pub fn keybinds_rx(&self) -> watch::Receiver<Arc<KeybindTable>> {
        self.keybinds_rx.clone()
    }

    /// Replace the live keybind table. Called by the settings watcher.
    pub fn replace_keybinds(&self, table: KeybindTable) {
        let _ = self.keybinds_tx.send(Arc::new(table));
    }

    async fn buffer_push(&self, name: Option<String>, data: String) {
        let mut buffers = self.buffers.lock().await;
        buffers.insert(0, Buffer { name, data });
        if buffers.len() > MAX_BUFFERS {
            buffers.truncate(MAX_BUFFERS);
        }
    }

    async fn buffer_list(&self) -> Vec<BufferInfo> {
        let buffers = self.buffers.lock().await;
        buffers
            .iter()
            .map(|b| BufferInfo {
                name: b.name.clone(),
                len: b.data.len(),
                preview: preview(&b.data),
            })
            .collect()
    }

    async fn buffer_find(&self, index: Option<usize>, name: Option<String>) -> Option<Buffer> {
        let buffers = self.buffers.lock().await;
        if let Some(name) = name {
            return buffers
                .iter()
                .find(|b| b.name.as_deref() == Some(&name))
                .cloned();
        }
        let idx = index.unwrap_or(0);
        buffers.get(idx).cloned()
    }

    async fn buffer_delete(&self, index: Option<usize>, name: Option<String>) -> bool {
        let mut buffers = self.buffers.lock().await;
        if let Some(name) = name {
            let before = buffers.len();
            buffers.retain(|b| b.name.as_deref() != Some(&name));
            return buffers.len() != before;
        }
        if let Some(idx) = index {
            if idx < buffers.len() {
                buffers.remove(idx);
                return true;
            }
            return false;
        }
        let was_empty = buffers.is_empty();
        buffers.clear();
        !was_empty
    }

    async fn save_snapshot(&self, path: &std::path::Path) -> Result<()> {
        let workspaces = self.workspaces.lock().await;
        let active_id = self.active_ws_rx.borrow().id;
        let mut out = Vec::with_capacity(workspaces.len());
        let mut active_idx = 0usize;
        for (i, w) in workspaces.iter().enumerate() {
            if w.id == active_id {
                active_idx = i;
            }
            out.push(w.snapshot().await);
        }
        let snap = Snapshot {
            version: 1,
            active_workspace: active_idx,
            workspaces: out,
        };
        snapshot::save(path, &snap)
    }
}

fn preview(data: &str) -> String {
    let mut out = String::new();
    for (count, ch) in data.chars().enumerate() {
        if count >= BUFFER_PREVIEW_CHARS {
            out.push('…');
            break;
        }
        if ch.is_control() {
            out.push(' ');
        } else {
            out.push(ch);
        }
    }
    out
}

struct SettingsWatcherGuard {
    _watcher: notify::PollWatcher,
    poll_task: task::JoinHandle<()>,
}

impl Drop for SettingsWatcherGuard {
    fn drop(&mut self) {
        self.poll_task.abort();
    }
}

/// Watch the given settings file and reload `daemon.keybinds` on change.
/// Returns a guard that must be kept alive.
fn spawn_settings_watcher(daemon: Arc<Daemon>, path: PathBuf) -> Option<SettingsWatcherGuard> {
    use notify::{Config, RecursiveMode, Watcher};
    probe::log_event(
        "settings",
        "watcher_start",
        &[("path", path.display().to_string())],
    );
    let last_bytes = Arc::new(StdMutex::new(settings_file_bytes(&path).ok()));
    // Load once at startup so the caller's daemon already reflects this file
    // (in case it was written after `Daemon::start` loaded defaults).
    if let Ok(settings) = settings::load(&path) {
        daemon.replace_keybinds(settings::compile(&settings));
        daemon
            .notification_command
            .store(settings.notifications.command.map(Arc::new));
        probe::log_event(
            "settings",
            "initial_load_ok",
            &[("path", path.display().to_string())],
        );
    }

    let watched_path = path.clone();
    let daemon_for_cb = daemon.clone();
    let last_bytes_for_cb = last_bytes.clone();
    let watcher_result = notify::PollWatcher::new(
        move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            tracing::debug!(kind = ?event.kind, paths = ?event.paths, "settings watch event");
            let path = watched_path.clone();
            probe::log_event(
                "settings",
                "watch_event",
                &[
                    ("path", path.display().to_string()),
                    ("kind", format!("{:?}", event.kind)),
                    ("paths", format!("{:?}", event.paths)),
                ],
            );
            // Reload on any touch of the watched file. notify may emit several
            // events for one save; the reload is idempotent.
            match reload_settings_if_changed(&daemon_for_cb, &path, &last_bytes_for_cb) {
                Ok(true) => {
                    tracing::info!(path = %path.display(), "reloaded changed settings");
                    probe::log_event(
                        "settings",
                        "reload_ok",
                        &[("path", path.display().to_string())],
                    );
                }
                Ok(false) => {}
                Err(e) => {
                    tracing::warn!(error = %e, "settings reload failed");
                    probe::log_event(
                        "settings",
                        "reload_failed",
                        &[
                            ("path", path.display().to_string()),
                            ("error", e.to_string()),
                        ],
                    );
                }
            }
        },
        Config::default().with_poll_interval(Duration::from_millis(250)),
    );
    // If we can't build a watcher (unsupported platform, FD exhausted,
    // etc.) just log and return None. Hot-reload is a nicety, not a
    // hard requirement — the daemon runs fine without it.
    let mut watcher = match watcher_result {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!(error = %e, "could not build notify watcher; settings hot-reload disabled");
            return None;
        }
    };

    // Watch the parent directory so atomic-rename writes (tempfile → rename)
    // still trigger the callback.
    let target = path
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(|| path.clone());
    // Create parent dir if missing — otherwise `watch` errors.
    if let Err(e) = std::fs::create_dir_all(&target) {
        tracing::warn!(error = %e, "could not create settings parent dir");
    }
    if let Err(e) = watcher.watch(&target, RecursiveMode::NonRecursive) {
        tracing::warn!(error = %e, "notify watch failed");
        probe::log_event(
            "settings",
            "watch_failed",
            &[
                ("path", path.display().to_string()),
                ("target", target.display().to_string()),
                ("error", e.to_string()),
            ],
        );
    }
    probe::log_event(
        "settings",
        "watch_ok",
        &[
            ("path", path.display().to_string()),
            ("target", target.display().to_string()),
        ],
    );
    let poll_daemon = daemon.clone();
    let poll_path = path.clone();
    let poll_last_bytes = last_bytes;
    let poll_task = task::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_millis(500));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            match reload_settings_if_changed(&poll_daemon, &poll_path, &poll_last_bytes) {
                Ok(true) => {
                    tracing::info!(path = %poll_path.display(), "reloaded changed settings from poll");
                    probe::log_event(
                        "settings",
                        "poll_reload_ok",
                        &[("path", poll_path.display().to_string())],
                    );
                }
                Ok(false) => {}
                Err(e) => {
                    tracing::warn!(error = %e, "settings poll reload failed");
                    probe::log_event(
                        "settings",
                        "poll_reload_failed",
                        &[
                            ("path", poll_path.display().to_string()),
                            ("error", e.to_string()),
                        ],
                    );
                }
            }
        }
    });

    Some(SettingsWatcherGuard {
        _watcher: watcher,
        poll_task,
    })
}

fn settings_file_bytes(path: &Path) -> Result<Vec<u8>> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(bytes),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.into()),
    }
}

fn reload_settings_if_changed(
    daemon: &Daemon,
    path: &Path,
    last_bytes: &StdMutex<Option<Vec<u8>>>,
) -> Result<bool> {
    let bytes = settings_file_bytes(path)?;
    {
        let last = match last_bytes.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        if last.as_ref() == Some(&bytes) {
            return Ok(false);
        }
    }

    let settings = settings::load(path)?;
    daemon.replace_keybinds(settings::compile(&settings));
    daemon
        .notification_command
        .store(settings.notifications.command.map(Arc::new));

    let mut last = match last_bytes.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    };
    *last = Some(bytes);
    Ok(true)
}

/// Row inside the sidebar rect where workspace items begin (row 0 =
/// header, row 1 = spacer). Kept in sync with `paint_sidebar` in
/// `render.rs`; the hit tester below uses the same origin.
const SIDEBAR_ITEM_ROW_OFFSET: u16 = 2;

/// Given a click in viewport coordinates, return the 0-based workspace
/// index if it lands on a sidebar item row. Header and spacer rows
/// return None; clicks past the last workspace return None.
pub fn hit_test_sidebar(col: u16, row: u16, sidebar: Rect, item_count: usize) -> Option<usize> {
    if sidebar.cols == 0 || col >= sidebar.cols || row < SIDEBAR_ITEM_ROW_OFFSET {
        return None;
    }
    if row >= sidebar.row + sidebar.rows {
        return None;
    }
    let idx = (row - SIDEBAR_ITEM_ROW_OFFSET) as usize;
    if idx >= item_count { None } else { Some(idx) }
}

/// Given a click in viewport coordinates and the layout leaves,
/// return the 0-based leaf index whose inner pane rect contains the
/// click. Used by the mouse handler to focus a leaf in a split
/// workspace when the user clicks anywhere inside that leaf's
/// terminal area.
pub fn hit_test_leaf_pane(col: u16, row: u16, leaves: &[Rect]) -> Option<usize> {
    for (i, r) in leaves.iter().enumerate() {
        if col >= r.col && col < r.col + r.cols && row >= r.row && row < r.row + r.rows {
            return Some(i);
        }
    }
    None
}

/// Given a click in viewport coordinates and the current tab titles,
/// return the 0-based tab index if the click hits a pill. Uses the
/// same `"X {i+1}:{title} "` label layout as `paint_tab_bar` in
/// `render.rs` (first column is an activity marker or a space —
/// either way, 1 column wide).
pub fn hit_test_tab_bar(col: u16, row: u16, tab_bar: Rect, tab_titles: &[String]) -> Option<usize> {
    hit_test_tab_bar_with_active(col, row, tab_bar, tab_titles, 0)
}

/// Active-aware tab hit testing. When the tab strip overflows, rendering keeps
/// the active tab visible with elision markers, so hit testing must use the
/// same visible range.
pub fn hit_test_tab_bar_with_active(
    col: u16,
    row: u16,
    tab_bar: Rect,
    tab_titles: &[String],
    active: usize,
) -> Option<usize> {
    if tab_bar.rows == 0 || tab_bar.cols == 0 {
        return None;
    }
    if row != tab_bar.row {
        return None;
    }
    if col < tab_bar.col || col >= tab_bar.col + tab_bar.cols {
        return None;
    }
    if tab_titles.is_empty() {
        return None;
    }
    let active = active.min(tab_titles.len() - 1);
    let (start, end, left_hidden, right_hidden) =
        visible_tab_range(tab_titles, active, tab_bar.cols);
    let mut cursor = tab_bar.col;
    let max_col = tab_bar.col + tab_bar.cols;
    if left_hidden {
        cursor = cursor.saturating_add(2).min(max_col);
    }
    for (i, title) in tab_titles.iter().enumerate().take(end).skip(start) {
        // Label shape matches `paint_tab_bar`'s "{marker} {index}:{title} "
        // where marker is one column (a dot or a space) and index is
        // 0-based to match `cmx select-tab N`.
        let label = format!("  {i}:{title} ");
        let len = label.chars().count().try_into().unwrap_or(u16::MAX);
        let visible_len = len.min(max_col.saturating_sub(cursor));
        if visible_len == 0 {
            return None;
        }
        if col >= cursor && col < cursor + visible_len {
            return Some(i);
        }
        cursor = cursor.saturating_add(visible_len);
    }
    let _ = right_hidden;
    None
}

fn tab_label_width(index: usize, title: &str) -> usize {
    format!("  {index}:{title} ").chars().count()
}

fn visible_tab_range(
    tab_titles: &[String],
    active: usize,
    max_cols: u16,
) -> (usize, usize, bool, bool) {
    if tab_titles.is_empty() {
        return (0, 0, false, false);
    }
    let count = tab_titles.len();
    let active = active.min(count - 1);
    let widths: Vec<usize> = tab_titles
        .iter()
        .enumerate()
        .map(|(idx, title)| tab_label_width(idx, title))
        .collect();
    let total: usize = widths.iter().sum();
    let max_cols = usize::from(max_cols);
    if total <= max_cols {
        return (0, count, false, false);
    }
    let mut best = (active, active + 1);
    let mut best_visible = 1usize;
    for start in 0..=active {
        for end in (active + 1)..=count {
            let left_hidden = start > 0;
            let right_hidden = end < count;
            let marker_width =
                (if left_hidden { 2 } else { 0 }) + (if right_hidden { 2 } else { 0 });
            let width: usize = widths[start..end].iter().sum::<usize>() + marker_width;
            let visible = end - start;
            if width <= max_cols && visible > best_visible {
                best = (start, end);
                best_visible = visible;
            }
        }
    }
    (best.0, best.1, best.0 > 0, best.1 < count)
}

/// For a split workspace with `n_panes` leaves, return one
/// `(top_border, pane, bottom_border)` rect trio per leaf. In the
/// unsplit (`n_panes <= 1`) case this collapses to a single leaf
/// covering the full pane area — callers can treat split and
/// un-split cases uniformly.
pub fn chrome_layout_leaves(
    viewport: (u16, u16),
    n_panes: usize,
    direction: SplitDirection,
) -> Vec<(Rect, Rect, Rect)> {
    chrome_layout_leaves_ratio(viewport, n_panes, direction, 500)
}

/// As [`chrome_layout_leaves`] but with a configurable first-leaf
/// size ratio (in thousandths, clamped to [100, 900]). Kept for
/// legacy tests and flat split geometry helpers; recursive panels use
/// `chrome_layout_panel_leaves`.
pub fn chrome_layout_leaves_ratio(
    viewport: (u16, u16),
    n_panes: usize,
    direction: SplitDirection,
    first_leaf_permille: u16,
) -> Vec<(Rect, Rect, Rect)> {
    let (_sidebar, _space_bar, top_border, pane, bottom_border, _status) = chrome_layout(viewport);
    if n_panes <= 1 {
        return vec![(top_border, pane, bottom_border)];
    }
    let n = n_panes as u16;
    let permille = first_leaf_permille.clamp(100, 900);
    match direction {
        SplitDirection::Horizontal => {
            let total_cols = top_border.cols;
            if total_cols < n * 3 {
                return vec![(top_border, pane, bottom_border)];
            }
            let sizes: Vec<u16> = if n_panes == 2 {
                let first = ((total_cols as u32 * permille as u32 + 500) / 1000) as u16;
                let first = first.max(3).min(total_cols - 3);
                vec![first, total_cols - first]
            } else {
                let per = total_cols / n;
                (0..n_panes)
                    .map(|i| {
                        if i == n_panes - 1 {
                            total_cols - (i as u16 * per)
                        } else {
                            per
                        }
                    })
                    .collect()
            };
            let mut leaves = Vec::with_capacity(n_panes);
            let mut col = top_border.col;
            for cols in sizes {
                let tb = Rect {
                    col,
                    row: top_border.row,
                    cols,
                    rows: top_border.rows,
                };
                let bb = Rect {
                    col,
                    row: bottom_border.row,
                    cols,
                    rows: bottom_border.rows,
                };
                let inner = Rect {
                    col: col + 1,
                    row: pane.row,
                    cols: cols.saturating_sub(2).max(1),
                    rows: pane.rows,
                };
                leaves.push((tb, inner, bb));
                col += cols;
            }
            leaves
        }
        SplitDirection::Vertical => {
            let total_rows = pane.rows + top_border.rows + bottom_border.rows;
            if total_rows < n * 3 {
                return vec![(top_border, pane, bottom_border)];
            }
            let sizes: Vec<u16> = if n_panes == 2 {
                let first = ((total_rows as u32 * permille as u32 + 500) / 1000) as u16;
                let first = first.max(3).min(total_rows - 3);
                vec![first, total_rows - first]
            } else {
                let per = total_rows / n;
                (0..n_panes)
                    .map(|i| {
                        if i == n_panes - 1 {
                            total_rows - (i as u16 * per)
                        } else {
                            per
                        }
                    })
                    .collect()
            };
            let mut leaves = Vec::with_capacity(n_panes);
            let mut row = top_border.row;
            for rows in sizes {
                let tb = Rect {
                    col: top_border.col,
                    row,
                    cols: top_border.cols,
                    rows: 1,
                };
                let bb = Rect {
                    col: top_border.col,
                    row: row + rows - 1,
                    cols: top_border.cols,
                    rows: 1,
                };
                let inner = Rect {
                    col: top_border.col + 1,
                    row: row + 1,
                    cols: top_border.cols.saturating_sub(2).max(1),
                    rows: rows.saturating_sub(2).max(1),
                };
                leaves.push((tb, inner, bb));
                row += rows;
            }
            leaves
        }
    }
}

#[derive(Debug, Clone)]
struct PanelLayoutLeaf {
    panel_id: PanelId,
    tab_ids: Vec<TabId>,
    panel_active_tab: Option<TabId>,
    top_border: Rect,
    inner: Rect,
    bottom_border: Rect,
}

fn chrome_layout_panel_leaves(viewport: (u16, u16), panels: &PanelNode) -> Vec<PanelLayoutLeaf> {
    let (_sidebar, _space_bar, top_border, pane, bottom_border, _status) = chrome_layout(viewport);
    let outer = if top_border.rows > 0 && bottom_border.rows > 0 {
        Rect {
            col: top_border.col,
            row: top_border.row,
            cols: top_border.cols,
            rows: bottom_border
                .row
                .saturating_add(bottom_border.rows)
                .saturating_sub(top_border.row),
        }
    } else {
        pane
    };
    let mut out = Vec::new();
    collect_panel_layout_leaves(panels, outer, &mut out);
    out
}

fn collect_panel_layout_leaves(node: &PanelNode, outer: Rect, out: &mut Vec<PanelLayoutLeaf>) {
    match node {
        PanelNode::Leaf(panel) => {
            let (top_border, inner, bottom_border) = leaf_rects_from_outer(outer);
            out.push(PanelLayoutLeaf {
                panel_id: panel.id,
                tab_ids: panel.tabs.clone(),
                panel_active_tab: panel.active_tab,
                top_border,
                inner,
                bottom_border,
            });
        }
        PanelNode::Split {
            direction,
            ratio_permille,
            first,
            second,
        } => {
            let (a, b) = split_outer_rect(outer, *direction, *ratio_permille);
            collect_panel_layout_leaves(first, a, out);
            if b.cols > 0 && b.rows > 0 {
                collect_panel_layout_leaves(second, b, out);
            }
        }
    }
}

fn split_outer_rect(outer: Rect, direction: SplitDirection, ratio_permille: u16) -> (Rect, Rect) {
    let ratio = ratio_permille.clamp(100, 900);
    match direction {
        SplitDirection::Horizontal => {
            if outer.cols <= 1 {
                return (
                    outer,
                    Rect {
                        col: outer.col.saturating_add(outer.cols),
                        row: outer.row,
                        cols: 0,
                        rows: outer.rows,
                    },
                );
            }
            let first_cols = ((outer.cols as u32 * ratio as u32 + 500) / 1000)
                .clamp(1, outer.cols as u32 - 1) as u16;
            let second_cols = outer.cols.saturating_sub(first_cols);
            (
                Rect {
                    cols: first_cols,
                    ..outer
                },
                Rect {
                    col: outer.col + first_cols,
                    cols: second_cols,
                    ..outer
                },
            )
        }
        SplitDirection::Vertical => {
            if outer.rows <= 1 {
                return (
                    outer,
                    Rect {
                        col: outer.col,
                        row: outer.row.saturating_add(outer.rows),
                        cols: outer.cols,
                        rows: 0,
                    },
                );
            }
            let first_rows = ((outer.rows as u32 * ratio as u32 + 500) / 1000)
                .clamp(1, outer.rows as u32 - 1) as u16;
            let second_rows = outer.rows.saturating_sub(first_rows);
            (
                Rect {
                    rows: first_rows,
                    ..outer
                },
                Rect {
                    row: outer.row + first_rows,
                    rows: second_rows,
                    ..outer
                },
            )
        }
    }
}

fn leaf_rects_from_outer(outer: Rect) -> (Rect, Rect, Rect) {
    if outer.rows >= 3 && outer.cols >= 3 {
        let top_border = Rect {
            col: outer.col,
            row: outer.row,
            cols: outer.cols,
            rows: 1,
        };
        let bottom_border = Rect {
            col: outer.col,
            row: outer.row + outer.rows - 1,
            cols: outer.cols,
            rows: 1,
        };
        let inner = Rect {
            col: outer.col + 1,
            row: outer.row + 1,
            cols: outer.cols.saturating_sub(2).max(1),
            rows: outer.rows.saturating_sub(2).max(1),
        };
        (top_border, inner, bottom_border)
    } else {
        (
            Rect { rows: 0, ..outer },
            outer,
            Rect {
                row: outer.row.saturating_add(outer.rows),
                rows: 0,
                ..outer
            },
        )
    }
}

/// Compute (sidebar, space_bar, top_border, pane, bottom_border, status)
/// rects for a viewport. Sidebar hides on narrow viewports. The space bar
/// is a 1-row strip above the pane area that carries workspace-local spaces.
/// The top border is a 1-row strip that carries both the zellij-style
/// box-drawing corner/edge glyphs and the inline terminal-pill strip. The
/// bottom border is the matching single-row strip.
pub fn chrome_layout(viewport: (u16, u16)) -> (Rect, Rect, Rect, Rect, Rect, Rect) {
    let (cols, rows) = viewport;
    let sidebar_w = if cols >= SIDEBAR_MIN_TERMINAL_COLS {
        SIDEBAR_WIDTH
    } else {
        0
    };
    let status_h: u16 = if rows >= 3 { 1 } else { 0 };
    let space_bar_h: u16 = if rows >= 6 { 1 } else { 0 };
    // Only draw borders when we have at least 5 rows: top-border +
    // 1 pane row + bottom-border + status + enough to be useful.
    let border_rows: u16 = if rows >= 5 { 1 } else { 0 };
    let content_rows = rows.saturating_sub(status_h);
    let pane_content_rows = content_rows.saturating_sub(space_bar_h);

    let sidebar = Rect {
        col: 0,
        row: 0,
        cols: sidebar_w,
        rows: content_rows,
    };
    let pane_area_col = sidebar_w;
    let pane_area_cols = cols.saturating_sub(sidebar_w).max(1);
    let space_bar = Rect {
        col: pane_area_col,
        row: 0,
        cols: pane_area_cols,
        rows: space_bar_h,
    };
    let top_border = Rect {
        col: pane_area_col,
        row: space_bar_h,
        cols: pane_area_cols,
        rows: border_rows,
    };
    let bottom_border = Rect {
        col: pane_area_col,
        row: space_bar_h + pane_content_rows.saturating_sub(border_rows),
        cols: pane_area_cols,
        rows: border_rows,
    };
    // Pane inset by vertical borders on each side (1 col left, 1 col
    // right) when there's room; otherwise fall back to the full
    // pane-area width.
    let has_side_borders = border_rows > 0 && pane_area_cols >= 3;
    let pane_col = if has_side_borders {
        pane_area_col + 1
    } else {
        pane_area_col
    };
    let pane_cols = if has_side_borders {
        pane_area_cols.saturating_sub(2).max(1)
    } else {
        pane_area_cols
    };
    let pane = Rect {
        col: pane_col,
        row: space_bar_h + border_rows,
        cols: pane_cols,
        rows: pane_content_rows.saturating_sub(border_rows * 2).max(1),
    };
    let status = Rect {
        col: 0,
        row: rows.saturating_sub(status_h),
        cols,
        rows: status_h,
    };
    (sidebar, space_bar, top_border, pane, bottom_border, status)
}

async fn build_chrome_spec(
    daemon: &Arc<Daemon>,
    client_id: &str,
    window: &mut WindowState,
    viewport: (u16, u16),
) -> ChromeSpec {
    let active_ws = window
        .active_workspace(daemon)
        .await
        .unwrap_or_else(|_| daemon.active_ws_rx.borrow().clone());
    let active = window.active_workspace_index(daemon).await.unwrap_or(0);
    let (workspaces, _) = daemon.workspace_list_with_active(active_ws.id).await;
    let active_ws_title = active_ws.title.lock().await.clone();
    let latency_text = daemon
        .client_latency_ms(client_id)
        .await
        .map(|latency_ms| format!(" · {latency_ms}ms"))
        .unwrap_or_default();
    let (sidebar, space_bar_rect, _top_border, _pane, _bottom_border, _status) =
        chrome_layout(viewport);
    let items: Vec<SidebarItem> = workspaces
        .iter()
        .map(|w| SidebarItem {
            title: w.title.clone(),
            pinned: w.pinned,
            color_rgb: w
                .color
                .as_deref()
                .and_then(rgb_from_hex)
                .map(|(r, g, b)| cmux_cli_core::compositor::RgbColor { r, g, b }),
        })
        .collect();
    let active_space = match window.active_space(&active_ws).await {
        Ok(space) => Some(space),
        Err(_) => active_ws.first_space().await,
    };
    let Some(active_space) = active_space else {
        return ChromeSpec {
            sidebar: SidebarSpec {
                width: sidebar.cols,
                items,
                active,
                focused: window.sidebar_focused,
            },
            space_bar: TabBarSpec {
                rect: space_bar_rect,
                tabs: Vec::new(),
                style: TabBarStyle::Text,
            },
            status: StatusSpec {
                text: format!(" [{active_ws_title}] "),
                hints: "workspace is closing ".to_string(),
            },
            panes: Vec::new(),
        };
    };
    let active_panel_id = window.active_panel(&active_space).await.unwrap_or(0);
    let active_space_idx = window.active_space_index(&active_ws).await.unwrap_or(0);
    let active_space_title = active_space.title.lock().await.clone();
    let leaves = window_panel_layouts(&active_space, window, viewport)
        .await
        .unwrap_or_default();
    let spaces = active_ws.spaces.lock().await.clone();
    let mut space_pills = Vec::with_capacity(spaces.len());
    for (idx, space) in spaces.iter().enumerate() {
        let title = space.title.lock().await.clone();
        let tabs = space.tabs.lock().await;
        let has_activity = if idx == active_space_idx {
            false
        } else {
            tabs.iter()
                .any(|tab| tab.has_activity.load(Ordering::Relaxed))
        };
        drop(tabs);
        space_pills.push(TabPill {
            title,
            active: idx == active_space_idx,
            has_activity,
            index: idx,
        });
    }

    // Transient `cmx display-message` overlay takes precedence over
    // the default `[workspace]` label until it expires.
    let now_ms_for_msg = now_unix_millis();
    let status_text = {
        let mut guard = daemon.display_message.lock().await;
        match guard.as_ref() {
            Some(msg) if msg.expires_ms > now_ms_for_msg => format!(" {} ", msg.text),
            Some(_) => {
                *guard = None;
                if window.sidebar_focused {
                    format!(" [workspace nav: {active_ws_title}{latency_text}] ")
                } else if window.space_strip_focused {
                    format!(" [space nav: {active_space_title}{latency_text}] ")
                } else {
                    format!(" [{active_ws_title} · {active_space_title}{latency_text}] ")
                }
            }
            None => {
                if window.sidebar_focused {
                    format!(" [workspace nav: {active_ws_title}{latency_text}] ")
                } else if window.space_strip_focused {
                    format!(" [space nav: {active_space_title}{latency_text}] ")
                } else {
                    format!(" [{active_ws_title} · {active_space_title}{latency_text}] ")
                }
            }
        }
    };
    // Shortcut hints mirror tmux's split defaults: `%` for side-by-side
    // and `"` for stacked panes.
    let hints = if window.sidebar_focused {
        "j/k or C-n/C-p move · c new · enter done · esc cancel ".to_string()
    } else if window.space_strip_focused {
        "h/l or C-p/C-n move · enter done · esc cancel ".to_string()
    } else {
        concat!(
            "C-b W new-ws · ",
            "C-b w ws-nav · ",
            "C-b c new-space · ",
            "C-b s space-nav · ",
            "C-b n/p space-next/prev · ",
            "C-b t new-term · ",
            "C-b [/ ] term-prev/next · ",
            "C-b % / \" split · ",
            "C-b = unsplit · ",
            "C-b & close-space · ",
            "C-b d detach ",
        )
        .to_string()
    };
    let now_ms = now_unix_millis();
    let mut pane_chromes: Vec<PaneChrome> = Vec::with_capacity(leaves.len());
    for leaf in &leaves {
        let tab_bar_rect = if leaf.top_border.cols >= 2 {
            Rect {
                col: leaf.top_border.col + 1,
                row: leaf.top_border.row,
                cols: leaf.top_border.cols - 2,
                rows: leaf.top_border.rows,
            }
        } else {
            leaf.top_border
        };
        let focused = leaf.panel_id == active_panel_id;
        let focused_tab_flashing = focused
            && leaf
                .active_tab
                .as_ref()
                .is_some_and(|tab| flash_is_on(tab.flash_until_ms.load(Ordering::Relaxed), now_ms));
        let border = if leaf.top_border.rows > 0
            && leaf.bottom_border.rows > 0
            && leaf.bottom_border.row >= leaf.top_border.row
        {
            Some(BorderSpec {
                rect: Rect {
                    col: leaf.top_border.col,
                    row: leaf.top_border.row,
                    cols: leaf.top_border.cols,
                    rows: leaf.bottom_border.row + leaf.bottom_border.rows - leaf.top_border.row,
                },
                tabs: leaf.pills.clone(),
                flashing: focused_tab_flashing,
                focused,
            })
        } else {
            None
        };
        pane_chromes.push(PaneChrome {
            active_tab_id: leaf.active_tab_id,
            terminal_rect: leaf.inner,
            tab_bar: TabBarSpec {
                rect: tab_bar_rect,
                tabs: leaf.pills.clone(),
                style: TabBarStyle::Pill,
            },
            border,
        });
    }

    ChromeSpec {
        sidebar: SidebarSpec {
            width: sidebar.cols,
            items,
            active,
            focused: window.sidebar_focused,
        },
        space_bar: TabBarSpec {
            rect: space_bar_rect,
            tabs: space_pills,
            style: TabBarStyle::Text,
        },
        status: StatusSpec {
            text: status_text,
            hints,
        },
        panes: pane_chromes,
    }
}

#[derive(Clone)]
struct ResolvedPanelLeaf {
    panel_id: PanelId,
    active_tab_id: TabId,
    active_tab: Option<Arc<Tab>>,
    pills: Vec<TabPill>,
    top_border: Rect,
    inner: Rect,
    bottom_border: Rect,
}

async fn window_panel_layouts(
    active_space: &Arc<Space>,
    window: &mut WindowState,
    viewport: (u16, u16),
) -> Result<Vec<ResolvedPanelLeaf>> {
    let active_panel_id = window.active_panel(active_space).await?;
    let panels = active_space.panels.lock().await.clone();
    let layouts = if active_space.zoomed.load(Ordering::Relaxed) && panels.is_split() {
        let leaf = panels
            .leaves()
            .into_iter()
            .find(|leaf| leaf.id == active_panel_id)
            .or_else(|| panels.leaves().into_iter().next())
            .ok_or_else(|| anyhow!("no panels"))?;
        let (_sidebar, _space_bar, top_border, pane, bottom_border, _status) =
            chrome_layout(viewport);
        vec![PanelLayoutLeaf {
            panel_id: leaf.id,
            tab_ids: leaf.tabs,
            panel_active_tab: leaf.active_tab,
            top_border,
            inner: pane,
            bottom_border,
        }]
    } else {
        chrome_layout_panel_leaves(viewport, &panels)
    };

    let tabs_guard = active_space.tabs.lock().await;
    let by_id: HashMap<TabId, Arc<Tab>> = tabs_guard.iter().map(|t| (t.id, t.clone())).collect();
    drop(tabs_guard);

    let mut resolved = Vec::new();
    for layout in layouts {
        let panel_tabs: Vec<Arc<Tab>> = layout
            .tab_ids
            .iter()
            .filter_map(|id| by_id.get(id).cloned())
            .collect();
        if panel_tabs.is_empty() {
            continue;
        }
        let panel_ref = PanelRef {
            space_id: active_space.id,
            panel_id: layout.panel_id,
        };
        let remembered = window
            .active_tab_by_panel
            .get(&panel_ref)
            .copied()
            .filter(|id| layout.tab_ids.contains(id));
        let active_tab_id = remembered
            .or(layout
                .panel_active_tab
                .filter(|id| layout.tab_ids.contains(id)))
            .unwrap_or(panel_tabs[0].id);
        window.active_tab_by_panel.insert(panel_ref, active_tab_id);
        let mut active_idx = 0usize;
        let pills = panel_tabs
            .iter()
            .enumerate()
            .map(|(idx, tab)| {
                if tab.id == active_tab_id {
                    active_idx = idx;
                }
                let title = tab.title.load_full().as_ref().clone();
                let active = tab.id == active_tab_id;
                TabPill {
                    title,
                    active,
                    has_activity: if active {
                        false
                    } else {
                        tab.has_activity.load(Ordering::Relaxed)
                    },
                    index: idx,
                }
            })
            .collect();
        let active_tab = panel_tabs.get(active_idx).cloned();
        resolved.push(ResolvedPanelLeaf {
            panel_id: layout.panel_id,
            active_tab_id,
            active_tab,
            pills,
            top_border: layout.top_border,
            inner: layout.inner,
            bottom_border: layout.bottom_border,
        });
    }
    Ok(resolved)
}

fn focus_panel_in_direction(
    active_panel_id: PanelId,
    leaves: &[ResolvedPanelLeaf],
    command: &Command,
    anchor: Option<PaneFocusAnchor>,
) -> Option<(PanelId, PaneFocusAnchor)> {
    let current = leaves
        .iter()
        .find(|leaf| leaf.panel_id == active_panel_id)?;
    let cur = current.inner;
    let cur_left = cur.col as i32;
    let cur_top = cur.row as i32;
    let cur_right = cur_left + cur.cols as i32;
    let cur_bottom = cur_top + cur.rows as i32;
    let anchor = clamp_anchor_to_rect(anchor.unwrap_or_else(|| rect_center_anchor(cur)), cur);
    leaves
        .iter()
        .filter(|leaf| leaf.panel_id != active_panel_id)
        .filter_map(|leaf| {
            let rect = leaf.inner;
            let left = rect.col as i32;
            let top = rect.row as i32;
            let right = left + rect.cols as i32;
            let bottom = top + rect.rows as i32;
            let center_col = left + rect.cols as i32 / 2;
            let center_row = top + rect.rows as i32 / 2;
            let cur_center_col = cur_left + cur.cols as i32 / 2;
            let cur_center_row = cur_top + cur.rows as i32 / 2;

            let overlap = |a0: i32, a1: i32, b0: i32, b1: i32| (a1.min(b1) - a0.max(b0)).max(0);

            let (primary_gap, orthogonal_overlap, anchor_distance, orthogonal_offset) =
                match command {
                    Command::FocusLeft => (
                        cur_left - right,
                        overlap(cur_top, cur_bottom, top, bottom),
                        interval_distance(anchor.row, top, bottom),
                        (center_row - cur_center_row).abs(),
                    ),
                    Command::FocusRight => (
                        left - cur_right,
                        overlap(cur_top, cur_bottom, top, bottom),
                        interval_distance(anchor.row, top, bottom),
                        (center_row - cur_center_row).abs(),
                    ),
                    Command::FocusUp => (
                        cur_top - bottom,
                        overlap(cur_left, cur_right, left, right),
                        interval_distance(anchor.col, left, right),
                        (center_col - cur_center_col).abs(),
                    ),
                    Command::FocusDown => (
                        top - cur_bottom,
                        overlap(cur_left, cur_right, left, right),
                        interval_distance(anchor.col, left, right),
                        (center_col - cur_center_col).abs(),
                    ),
                    _ => return None,
                };

            if primary_gap < 0 || orthogonal_overlap <= 0 {
                return None;
            }

            let projected_anchor = project_anchor_into_rect(anchor, rect, command);
            Some((
                (
                    primary_gap,
                    anchor_distance,
                    std::cmp::Reverse(orthogonal_overlap),
                    orthogonal_offset,
                ),
                leaf.panel_id,
                projected_anchor,
            ))
        })
        .min_by_key(|(score, _, _)| *score)
        .map(|(_, panel_id, anchor)| (panel_id, anchor))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PaneFocusAnchor {
    col: i32,
    row: i32,
}

fn rect_center_anchor(rect: Rect) -> PaneFocusAnchor {
    let left = rect.col as i32;
    let top = rect.row as i32;
    PaneFocusAnchor {
        col: left + rect.cols.saturating_sub(1) as i32 / 2,
        row: top + rect.rows.saturating_sub(1) as i32 / 2,
    }
}

fn clamp_anchor_to_rect(anchor: PaneFocusAnchor, rect: Rect) -> PaneFocusAnchor {
    let left = rect.col as i32;
    let top = rect.row as i32;
    let right = left + rect.cols.saturating_sub(1) as i32;
    let bottom = top + rect.rows.saturating_sub(1) as i32;
    PaneFocusAnchor {
        col: anchor.col.clamp(left, right),
        row: anchor.row.clamp(top, bottom),
    }
}

fn interval_distance(point: i32, start: i32, end_exclusive: i32) -> i32 {
    if end_exclusive <= start {
        return 0;
    }
    if point < start {
        start - point
    } else if point >= end_exclusive {
        point - end_exclusive + 1
    } else {
        0
    }
}

fn project_anchor_into_rect(
    anchor: PaneFocusAnchor,
    rect: Rect,
    command: &Command,
) -> PaneFocusAnchor {
    let clamped = clamp_anchor_to_rect(anchor, rect);
    let center = rect_center_anchor(rect);
    match command {
        Command::FocusLeft | Command::FocusRight => PaneFocusAnchor {
            col: center.col,
            row: clamped.row,
        },
        Command::FocusUp | Command::FocusDown => PaneFocusAnchor {
            col: clamped.col,
            row: center.row,
        },
        _ => center,
    }
}

async fn render_session_frame(
    daemon: &Arc<Daemon>,
    client_id: &str,
    window: &mut WindowState,
    viewport: (u16, u16),
    selection: Option<LineSelection>,
) -> Vec<u8> {
    let chrome = build_chrome_spec(daemon, client_id, window, viewport).await;
    let panes = window_pane_paints(daemon, window, viewport)
        .await
        .unwrap_or_default();
    daemon
        .broker
        .compose(panes, viewport, chrome, selection)
        .await
}

async fn window_pane_paints(
    daemon: &Daemon,
    window: &mut WindowState,
    viewport: (u16, u16),
) -> Result<Vec<(TabId, Rect)>> {
    let active_ws = window.active_workspace(daemon).await?;
    let active_space = window.active_space(&active_ws).await?;
    let active_panel_id = window.active_panel(&active_space).await?;
    let leaves = window_panel_layouts(&active_space, window, viewport).await?;
    let mut out = Vec::with_capacity(leaves.len());
    if let Some(pos) = leaves
        .iter()
        .position(|leaf| leaf.panel_id == active_panel_id)
    {
        let active = &leaves[pos];
        out.push((active.active_tab_id, active.inner));
        for (idx, leaf) in leaves.iter().enumerate() {
            if idx != pos {
                out.push((leaf.active_tab_id, leaf.inner));
            }
        }
    } else {
        for leaf in leaves {
            out.push((leaf.active_tab_id, leaf.inner));
        }
    }
    Ok(out)
}

/// Per-client mouse-drag selection state.
///
/// Anchor and current rows are stored in terminal scrollback coordinates
/// so viewport scrolling during a drag does not destroy the selected
/// range. The current endpoint also keeps the last viewport cell so
/// wheel/autoscroll can move the endpoint as the content under the mouse
/// changes.
#[derive(Debug, Clone, Copy)]
struct Selection {
    anchor: LogicalLineSelection,
    extent: LogicalLineSelection,
    last_view_col: u16,
    last_view_row: u16,
    granularity: SelectionGranularity,
    dragged: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SelectionGranularity {
    Cell,
    Word,
}

impl Selection {
    fn new(col: u16, row: u16, pane: Rect, viewport_offset: u64) -> Self {
        let range = Self::cell_range(col, row, pane, viewport_offset);
        Self::from_range(col, row, range, SelectionGranularity::Cell)
    }

    fn from_range(
        col: u16,
        row: u16,
        range: LogicalLineSelection,
        granularity: SelectionGranularity,
    ) -> Self {
        Self {
            anchor: range,
            extent: range,
            last_view_col: col,
            last_view_row: row,
            granularity,
            dragged: false,
        }
    }

    fn cell_range(col: u16, row: u16, pane: Rect, viewport_offset: u64) -> LogicalLineSelection {
        let (local_col, local_row) = Self::pane_cell(col, row, pane);
        let doc_row = viewport_offset.saturating_add(local_row as u64);
        LogicalLineSelection {
            start_col: local_col,
            start_row: doc_row,
            end_col: local_col,
            end_row: doc_row,
        }
    }

    fn update(&mut self, col: u16, row: u16, pane: Rect, viewport_offset: u64) {
        self.last_view_col = col;
        self.last_view_row = row;
        self.dragged = true;
        self.refresh_last_for_viewport(pane, viewport_offset);
    }

    fn update_range(&mut self, col: u16, row: u16, range: LogicalLineSelection) {
        self.last_view_col = col;
        self.last_view_row = row;
        self.extent = range;
        self.dragged = true;
    }

    fn refresh_last_for_viewport(&mut self, pane: Rect, viewport_offset: u64) {
        self.extent = Self::cell_range(
            self.last_view_col,
            self.last_view_row,
            pane,
            viewport_offset,
        );
    }

    fn logical_selection(self) -> LogicalLineSelection {
        if (self.anchor.start_row, self.anchor.start_col)
            <= (self.extent.start_row, self.extent.start_col)
        {
            LogicalLineSelection {
                start_col: self.anchor.start_col,
                start_row: self.anchor.start_row,
                end_col: self.extent.end_col,
                end_row: self.extent.end_row,
            }
        } else {
            LogicalLineSelection {
                start_col: self.extent.start_col,
                start_row: self.extent.start_row,
                end_col: self.anchor.end_col,
                end_row: self.anchor.end_row,
            }
        }
    }

    /// Line-wrapping selection in pane-local coordinates, clipped to the
    /// pane's currently visible rows. Returns None when the logical
    /// selection is wholly outside the viewport.
    fn line_in_pane(self, pane: Rect, viewport_offset: u64) -> Option<LineSelection> {
        if pane.rows == 0 || pane.cols == 0 {
            return None;
        }

        let ((start_col, start_row), (end_col, end_row)) = self.normalised();
        let visible_start = viewport_offset;
        let visible_end = viewport_offset
            .saturating_add(pane.rows as u64)
            .saturating_sub(1);
        if end_row < visible_start || start_row > visible_end {
            return None;
        }

        let clipped_start_row = start_row.max(visible_start);
        let clipped_end_row = end_row.min(visible_end);
        let pane_max_col = pane.cols.saturating_sub(1);
        Some(LineSelection {
            start_col: if clipped_start_row == start_row {
                start_col.min(pane_max_col)
            } else {
                0
            },
            start_row: (clipped_start_row - viewport_offset) as u16,
            end_col: if clipped_end_row == end_row {
                end_col.min(pane_max_col)
            } else {
                pane_max_col
            },
            end_row: (clipped_end_row - viewport_offset) as u16,
        })
    }

    fn normalised(self) -> ((u16, u64), (u16, u64)) {
        let logical = self.logical_selection();
        let start = (logical.start_col, logical.start_row);
        let end = (logical.end_col, logical.end_row);
        if (start.1, start.0) <= (end.1, end.0) {
            (start, end)
        } else {
            (end, start)
        }
    }

    fn pane_cell(col: u16, row: u16, pane: Rect) -> (u16, u16) {
        let pane_max_col = pane.col.saturating_add(pane.cols.saturating_sub(1));
        let pane_max_row = pane.row.saturating_add(pane.rows.saturating_sub(1));
        let local_col = col.max(pane.col).min(pane_max_col).saturating_sub(pane.col);
        let local_row = row.max(pane.row).min(pane_max_row).saturating_sub(pane.row);
        (local_col, local_row)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ClickTarget {
    tab_id: TabId,
    panel_id: PanelId,
}

#[derive(Debug, Clone, Copy)]
struct LastMouseDown {
    at: Instant,
    col: u16,
    row: u16,
    target: ClickTarget,
}

#[derive(Debug, Default)]
struct ClickTracker {
    last_down: Option<LastMouseDown>,
}

const DOUBLE_CLICK_MAX_MS: u128 = 500;
const DOUBLE_CLICK_MAX_CELL_DELTA: u16 = 1;

impl ClickTracker {
    fn record_down(&mut self, target: ClickTarget, col: u16, row: u16) -> bool {
        let now = Instant::now();
        let is_double_click = self.last_down.is_some_and(|last| {
            last.target == target
                && now.duration_since(last.at).as_millis() <= DOUBLE_CLICK_MAX_MS
                && last.col.abs_diff(col) <= DOUBLE_CLICK_MAX_CELL_DELTA
                && last.row.abs_diff(row) <= DOUBLE_CLICK_MAX_CELL_DELTA
        });
        self.last_down = Some(LastMouseDown {
            at: now,
            col,
            row,
            target,
        });
        is_double_click
    }
}

/// Convert an active drag (if any) into a pane-local line selection,
/// clipped to the current viewport's pane rect. Returns None when no
/// drag is in progress.
#[allow(dead_code)]
async fn current_selection(
    daemon: &Arc<Daemon>,
    tab_id: TabId,
    selection: Option<Selection>,
    viewport: (u16, u16),
) -> Option<LineSelection> {
    let (_, _, _, pane, _, _) = chrome_layout(viewport);
    selection_line_in_pane(daemon, tab_id, selection, pane).await
}

#[allow(dead_code)]
async fn current_selection_for_active_tab(
    daemon: &Arc<Daemon>,
    selection: Option<Selection>,
    viewport: (u16, u16),
) -> Option<LineSelection> {
    let active_ws = daemon.active_ws_rx.borrow().clone();
    let active_space = active_ws.first_space().await?;
    let active_tab = active_space.active_tab_rx.borrow().clone();
    current_selection(daemon, active_tab.id, selection, viewport).await
}

async fn selection_line_in_pane(
    daemon: &Arc<Daemon>,
    tab_id: TabId,
    selection: Option<Selection>,
    pane: Rect,
) -> Option<LineSelection> {
    let selection = selection?;
    let viewport_offset = daemon.broker.viewport_offset(tab_id).await;
    selection.line_in_pane(pane, viewport_offset)
}

async fn start_selection_for_mouse_down(
    daemon: &Arc<Daemon>,
    click_tracker: &mut ClickTracker,
    selection: &mut Option<Selection>,
    target: ClickTarget,
    col: u16,
    row: u16,
    pane: Rect,
) -> bool {
    let viewport_offset = daemon.broker.viewport_offset(target.tab_id).await;
    let is_double_click = click_tracker.record_down(target, col, row);
    if is_double_click {
        let (local_col, local_row) = Selection::pane_cell(col, row, pane);
        let doc_row = viewport_offset.saturating_add(local_row as u64);
        if let Some(range) = daemon
            .broker
            .word_selection(target.tab_id, local_col, doc_row)
            .await
        {
            *selection = Some(Selection::from_range(
                col,
                row,
                range,
                SelectionGranularity::Word,
            ));
            return true;
        }
    }
    *selection = Some(Selection::new(col, row, pane, viewport_offset));
    false
}

async fn refresh_selection_for_viewport(
    daemon: &Arc<Daemon>,
    tab_id: TabId,
    selection: &mut Selection,
    pane: Rect,
    viewport_offset: u64,
) {
    if selection.granularity == SelectionGranularity::Word {
        let (local_col, local_row) =
            Selection::pane_cell(selection.last_view_col, selection.last_view_row, pane);
        let doc_row = viewport_offset.saturating_add(local_row as u64);
        if let Some(range) = daemon
            .broker
            .word_selection(tab_id, local_col, doc_row)
            .await
        {
            selection.extent = range;
            return;
        }
    }
    selection.refresh_last_for_viewport(pane, viewport_offset);
}

fn selection_autoscroll_delta(row: u16, pane: Rect) -> Option<isize> {
    if pane.rows == 0 {
        return None;
    }
    let bottom = pane.row.saturating_add(pane.rows);
    if row <= pane.row {
        Some(-SELECTION_AUTOSCROLL_LINES)
    } else if row >= bottom.saturating_sub(1) {
        Some(SELECTION_AUTOSCROLL_LINES)
    } else {
        None
    }
}

/// Encode a mouse event as an SGR mouse report (DECSET 1006). Sent to
/// the inner PTY when the program inside has mouse tracking enabled —
/// lets vim / btop / less keep working without cmx intercepting clicks.
fn encode_sgr_mouse(col: u16, row: u16, event: cmux_cli_protocol::MouseKind) -> Vec<u8> {
    use cmux_cli_protocol::MouseKind;
    // Cell coords are 1-based in SGR mouse reports.
    let x = col.saturating_add(1);
    let y = row.saturating_add(1);
    let (btn, released) = match event {
        MouseKind::Down => (0, false),
        MouseKind::Drag => (32, false), // button 0 + motion flag (32)
        MouseKind::Up => (0, true),
        MouseKind::Wheel { lines } if lines < 0 => (64, false),
        MouseKind::Wheel { lines: _ } => (65, false),
    };
    let terminator = if released { b'm' } else { b'M' };
    let mut out = Vec::with_capacity(16);
    out.extend_from_slice(format!("\x1b[<{btn};{x};{y}").as_bytes());
    out.push(terminator);
    out
}

fn osc52_encode(data: &str) -> Vec<u8> {
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD.encode(data.as_bytes());
    let mut out = Vec::with_capacity(encoded.len() + 9);
    out.extend_from_slice(b"\x1b]52;c;");
    out.extend_from_slice(encoded.as_bytes());
    out.extend_from_slice(b"\x1b\\");
    out
}

// ----------------------------- Session -------------------------------

/// Unix-socket half of the session.
struct UnixSession {
    /// None once `spawn_unix_inbox` has moved the reader into a
    /// dedicated task. The session's `recv` becomes unreachable at
    /// that point; all reads come through `SessionInbox` instead.
    reader: Option<BufReader<OwnedReadHalf>>,
    writer: OwnedWriteHalf,
}

/// A client session multiplexed over either a Unix socket or a WebSocket.
/// Each recv/send deserializes/serializes one MessagePack frame.
enum Session {
    Unix(Box<UnixSession>),
    Ws(Box<WebSocketStream<TcpStream>>),
}

impl Session {
    fn is_websocket(&self) -> bool {
        matches!(self, Session::Ws(_))
    }

    async fn recv(&mut self) -> Result<Option<ClientMsg>, CodecError> {
        match self {
            Session::Unix(s) => match s.reader.as_mut() {
                Some(r) => read_msg(r).await,
                None => Err(CodecError::Io(std::io::Error::other(
                    "session reader was moved to SessionInbox; use inbox.recv()",
                ))),
            },
            Session::Ws(ws) => loop {
                let Some(msg) = ws.next().await else {
                    return Ok(None);
                };
                match msg {
                    Ok(Message::Binary(bytes)) => {
                        return Ok(Some(rmp_serde::from_slice(&bytes)?));
                    }
                    Ok(Message::Close(_)) => return Ok(None),
                    Ok(Message::Ping(_) | Message::Pong(_)) => continue,
                    Ok(Message::Text(t)) => {
                        return Err(CodecError::Io(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            format!(
                                "unexpected text frame: {}",
                                t.chars().take(32).collect::<String>()
                            ),
                        )));
                    }
                    Ok(Message::Frame(_)) => continue,
                    Err(e) => {
                        return Err(CodecError::Io(std::io::Error::other(e)));
                    }
                }
            },
        }
    }

    async fn send(&mut self, msg: &ServerMsg) -> Result<(), CodecError> {
        match self {
            Session::Unix(s) => write_msg(&mut s.writer, msg).await,
            Session::Ws(ws) => {
                let bytes = rmp_serde::to_vec_named(msg)?;
                ws.send(Message::Binary(bytes))
                    .await
                    .map_err(|e| CodecError::Io(std::io::Error::other(e)))
            }
        }
    }
}

/// Cancel-safe inbox backed by a dedicated reader task.
///
/// `AsyncReadExt::read_exact` (used inside `read_msg`) is explicitly
/// not cancel-safe. Dropping a `session.recv()` future mid-payload
/// leaves the underlying reader at an arbitrary byte offset; the next
/// call treats whatever happens to be there as a new length prefix
/// and desyncs. Under heavy `tokio::select!` contention (a client
/// typing + mouse-moving while the server streams frames) this
/// happens within seconds. The fix: do the reads on a non-cancellable
/// task and let `select!` observe the resulting `ClientMsg` values
/// through an `mpsc` — `mpsc::Receiver::recv` *is* cancel-safe.
struct SessionInbox {
    rx: mpsc::Receiver<Result<ClientMsg, String>>,
    task: tokio::task::JoinHandle<()>,
}

impl SessionInbox {
    async fn recv(&mut self) -> Result<Option<ClientMsg>, CodecError> {
        match self.rx.recv().await {
            Some(Ok(msg)) => Ok(Some(msg)),
            Some(Err(e)) => Err(CodecError::Io(std::io::Error::other(e))),
            None => Ok(None),
        }
    }
}

impl Drop for SessionInbox {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Cancel-safe `ClientMsg` fetch. Routes to the inbox when present
/// (Unix transport, fed by a dedicated reader task) and falls back to
/// `session.recv()` for WebSocket sessions.
async fn next_client_msg(
    inbox: &mut Option<SessionInbox>,
    session: &mut Session,
) -> Result<Option<ClientMsg>, CodecError> {
    match inbox.as_mut() {
        Some(inb) => inb.recv().await,
        None => session.recv().await,
    }
}

/// If this session is Unix-transport, spawn a reader task and return
/// an inbox that replaces `session.recv()` in the select loop. For WS
/// sessions, return None — `StreamExt::next` on tungstenite is
/// cancel-safe, so keeping `session.recv()` inline is fine there. The
/// split is only needed for Unix because `read_msg` uses
/// `AsyncReadExt::read_exact` which is NOT cancel-safe.
fn spawn_unix_inbox(session: &mut Session) -> Option<SessionInbox> {
    let Session::Unix(boxed) = session else {
        return None;
    };
    // Hand the reader to a dedicated task. The session's
    // `reader: Option<_>` becomes None; its `recv` now errors if it's
    // ever called — but it shouldn't be, because callers route reads
    // through the inbox.
    let real_reader = boxed.reader.take()?;
    let (tx, rx) = mpsc::channel::<Result<ClientMsg, String>>(64);
    let task = tokio::spawn(async move {
        let mut reader = real_reader;
        loop {
            match read_msg::<_, ClientMsg>(&mut reader).await {
                Ok(Some(m)) => {
                    if tx.send(Ok(m)).await.is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    let _ = tx.send(Err(format!("{e}"))).await;
                    break;
                }
            }
        }
    });
    Some(SessionInbox { rx, task })
}

/// Auth policy per transport. Enforced on the Hello token.
#[derive(Debug, Clone)]
enum AuthPolicy {
    /// Unix socket — FS permissions are enough.
    UnixFs,
    /// WebSocket — require this token (None means auth disabled).
    WsToken(Option<String>),
}

// --------------------------- Client handler ---------------------------

async fn handle_client(
    daemon: Arc<Daemon>,
    stream: UnixStream,
    heartbeat: HeartbeatConfig,
) -> Result<()> {
    let (read_half, write_half) = stream.into_split();
    let session = Session::Unix(Box::new(UnixSession {
        reader: Some(BufReader::new(read_half)),
        writer: write_half,
    }));
    run_session(daemon, session, AuthPolicy::UnixFs, heartbeat).await
}

async fn handle_ws_client(
    daemon: Arc<Daemon>,
    stream: TcpStream,
    auth_token: Option<String>,
    heartbeat: HeartbeatConfig,
) -> Result<()> {
    let stream = configure_ws_tcp_stream(stream)?;
    let ws = accept_async(stream).await.context("ws handshake")?;
    run_session(
        daemon,
        Session::Ws(Box::new(ws)),
        AuthPolicy::WsToken(auth_token),
        heartbeat,
    )
    .await
}

fn configure_ws_tcp_stream(stream: TcpStream) -> Result<TcpStream> {
    stream
        .set_nodelay(true)
        .context("enable TCP_NODELAY for websocket stream")?;
    Ok(stream)
}

struct ClientViewRegistration {
    daemon: Arc<Daemon>,
    client_id: String,
}

impl ClientViewRegistration {
    fn new(daemon: Arc<Daemon>, client_id: String) -> Self {
        Self { daemon, client_id }
    }
}

impl Drop for ClientViewRegistration {
    fn drop(&mut self) {
        let daemon = self.daemon.clone();
        let client_id = self.client_id.clone();
        tokio::spawn(async move {
            daemon.remove_client_view(&client_id).await;
        });
    }
}

#[derive(Debug)]
struct NativeTerminalDirtyEvent {
    tab_id: TabId,
}

#[derive(Debug)]
struct NativeTerminalDirtyBatch {
    tab_ids: Vec<TabId>,
    event_count: usize,
}

struct NativeTerminalDirtyMux {
    tx: mpsc::UnboundedSender<NativeTerminalDirtyEvent>,
    rx: mpsc::UnboundedReceiver<NativeTerminalDirtyEvent>,
    tasks: HashMap<TabId, tokio::task::JoinHandle<()>>,
}

impl NativeTerminalDirtyMux {
    fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self {
            tx,
            rx,
            tasks: HashMap::new(),
        }
    }

    fn sync(&mut self, tabs: Vec<Arc<Tab>>) {
        let wanted: HashSet<TabId> = tabs.iter().map(|tab| tab.id).collect();
        self.tasks.retain(|tab_id, task| {
            if wanted.contains(tab_id) {
                true
            } else {
                task.abort();
                false
            }
        });

        for tab in tabs {
            if self.tasks.contains_key(&tab.id) {
                continue;
            }
            let tab_id = tab.id;
            let mut rx = tab.output_tx.subscribe();
            let tx = self.tx.clone();
            let task = tokio::spawn(async move {
                loop {
                    match rx.recv().await {
                        Ok(_data) => {
                            if tx.send(NativeTerminalDirtyEvent { tab_id }).is_err() {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            if probe::verbose_enabled() {
                                probe::log_event(
                                    "server",
                                    "native_dirty_lagged",
                                    &[
                                        ("tab_id", tab_id.to_string()),
                                        ("skipped", skipped.to_string()),
                                    ],
                                );
                            }
                            if tx.send(NativeTerminalDirtyEvent { tab_id }).is_err() {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
            self.tasks.insert(tab_id, task);
        }
    }

    async fn recv_batch(&mut self) -> Option<NativeTerminalDirtyBatch> {
        let first = self.rx.recv().await?;
        let mut tab_ids = vec![first.tab_id];
        let mut seen = HashSet::from([first.tab_id]);
        let mut event_count = 1;
        while let Ok(event) = self.rx.try_recv() {
            event_count += 1;
            if seen.insert(event.tab_id) {
                tab_ids.push(event.tab_id);
            }
        }
        Some(NativeTerminalDirtyBatch {
            tab_ids,
            event_count,
        })
    }
}

impl Drop for NativeTerminalDirtyMux {
    fn drop(&mut self) {
        for (_, task) in self.tasks.drain() {
            task.abort();
        }
    }
}

#[derive(Debug)]
struct NativePtyOutputEvent {
    tab_id: TabId,
    data: Vec<u8>,
}

struct NativePtyOutputMux {
    tx: mpsc::UnboundedSender<NativePtyOutputEvent>,
    rx: mpsc::UnboundedReceiver<NativePtyOutputEvent>,
    tasks: HashMap<TabId, tokio::task::JoinHandle<()>>,
}

impl NativePtyOutputMux {
    fn new() -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        Self {
            tx,
            rx,
            tasks: HashMap::new(),
        }
    }

    fn sync(&mut self, tabs: &[Arc<Tab>]) {
        let wanted: HashSet<TabId> = tabs.iter().map(|tab| tab.id).collect();
        self.tasks.retain(|tab_id, task| {
            if wanted.contains(tab_id) {
                true
            } else {
                task.abort();
                false
            }
        });

        for tab in tabs {
            if self.tasks.contains_key(&tab.id) {
                continue;
            }
            let tab_id = tab.id;
            let mut rx = tab.output_tx.subscribe();
            let tx = self.tx.clone();
            let task = tokio::spawn(async move {
                loop {
                    match rx.recv().await {
                        Ok(data) => {
                            if tx.send(NativePtyOutputEvent { tab_id, data }).is_err() {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            if probe::verbose_enabled() {
                                probe::log_event(
                                    "server",
                                    "native_pty_lagged",
                                    &[
                                        ("tab_id", tab_id.to_string()),
                                        ("skipped", skipped.to_string()),
                                    ],
                                );
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            });
            self.tasks.insert(tab_id, task);
        }
    }

    async fn recv(&mut self) -> Option<NativePtyOutputEvent> {
        self.rx.recv().await
    }
}

impl Drop for NativePtyOutputMux {
    fn drop(&mut self) {
        for (_, task) in self.tasks.drain() {
            task.abort();
        }
    }
}

async fn run_session(
    daemon: Arc<Daemon>,
    mut session: Session,
    auth: AuthPolicy,
    heartbeat: HeartbeatConfig,
) -> Result<()> {
    let websocket_session = session.is_websocket();
    let hello = session
        .recv()
        .await?
        .ok_or_else(|| anyhow!("client disconnected before Hello"))?;
    let (native, version, viewport, token, terminal_renderer) = match hello {
        ClientMsg::Hello {
            version,
            viewport,
            token,
        } => (
            false,
            version,
            viewport,
            token,
            NativeTerminalRenderer::ServerGrid,
        ),
        ClientMsg::HelloNative {
            version,
            viewport,
            token,
            terminal_renderer,
        } => (true, version, viewport, token, terminal_renderer),
        _ => bail!("expected Hello, got {hello:?}"),
    };

    if version != PROTOCOL_VERSION {
        session
            .send(&ServerMsg::Error {
                message: format!(
                    "protocol version mismatch: server={PROTOCOL_VERSION} client={version}"
                ),
            })
            .await?;
        return Ok(());
    }
    if let AuthPolicy::WsToken(Some(expected)) = &auth
        && token.as_deref() != Some(expected.as_str())
    {
        session
            .send(&ServerMsg::Error {
                message: "invalid or missing token".into(),
            })
            .await?;
        return Ok(());
    }
    if native {
        return run_native_session(
            daemon,
            session,
            viewport,
            terminal_renderer,
            heartbeat,
            websocket_session,
        )
        .await;
    }
    let mut input = InputHandler::new(daemon.keybind_table());
    let mut keybinds_rx = daemon.keybinds_rx();
    let mut viewport_state = (viewport.cols, viewport.rows);
    let mut selection: Option<Selection> = None;
    let mut click_tracker = ClickTracker::default();
    let mut selection_autoscroll: Option<isize> = None;
    let mut selection_autoscroll_tick =
        tokio::time::interval(Duration::from_millis(SELECTION_AUTOSCROLL_TICK_MS));
    selection_autoscroll_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    selection_autoscroll_tick.tick().await;

    let session_id = uuid::Uuid::new_v4().to_string();
    session
        .send(&ServerMsg::Welcome {
            server_version: env!("CARGO_PKG_VERSION").into(),
            session_id: session_id.clone(),
        })
        .await?;

    let mut shutdown_rx = daemon.shutdown_rx.clone();
    let mut inbox = spawn_unix_inbox(&mut session);

    let mut window = WindowState::new(&daemon).await;
    let (_, _, initial_tab, _, _, _) = window_parts(&daemon, &mut window).await?;
    let mut output_rx = initial_tab.output_tx.subscribe();
    let mut subscribed_tab_id = initial_tab.id;
    let mut last_announced_ws_id: Option<u64> = None;
    let mut last_announced_tab: Option<(u64, u64)> = None;
    let _view_guard = ClientViewRegistration::new(daemon.clone(), session_id.clone());
    let heartbeat_enabled = heartbeat.enabled && websocket_session;
    let mut heartbeat_tick =
        tokio::time::interval(heartbeat.check_interval.max(Duration::from_millis(1)));
    heartbeat_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    heartbeat_tick.tick().await;
    let mut last_client_seen = Instant::now();

    sync_window_view(
        &mut session,
        &daemon,
        &session_id,
        &mut window,
        viewport_state,
        selection,
        &mut output_rx,
        &mut subscribed_tab_id,
        &mut last_announced_ws_id,
        &mut last_announced_tab,
    )
    .await?;

    let mut model_rx = daemon.model_rx();

    loop {
        tokio::select! {
            biased;
            _ = shutdown_rx.changed() => {
                if *shutdown_rx.borrow() {
                    while let Ok(_data) = output_rx.try_recv() {}
                    repaint_window(&mut session, &daemon, &session_id, &mut window, viewport_state, selection).await.ok();
                    daemon.remove_client_view(&session_id).await;
                    session.send(&ServerMsg::Bye).await.ok();
                    return Ok(());
                }
            }
            _ = keybinds_rx.changed() => {
                let pending = input.set_table((**keybinds_rx.borrow()).clone());
                forward_pending_input_to_active_tab(&daemon, &mut window, pending, "keybind reload").await;
            }
            changed = model_rx.changed() => {
                if changed.is_err() {
                    return Ok(());
                }
                if let Err(e) = sync_window_view(
                    &mut session,
                    &daemon,
                    &session_id,
                    &mut window,
                    viewport_state,
                    selection,
                    &mut output_rx,
                    &mut subscribed_tab_id,
                    &mut last_announced_ws_id,
                    &mut last_announced_tab,
                ).await {
                    tracing::warn!(error = %e, "could not refresh client view after model change");
                }
            }
            incoming = next_client_msg(&mut inbox, &mut session) => {
                let incoming = incoming?;
                if incoming.is_some() {
                    last_client_seen = Instant::now();
                }
                match incoming {
                    Some(ClientMsg::Input { data }) => {
                        let (mut pass, mut commands) = input.process(&data);
                        if window.sidebar_focused && !pass.is_empty() {
                            commands.extend(sidebar_mode_commands(&pass));
                            pass.clear();
                        } else if window.space_strip_focused && !pass.is_empty() {
                            commands.extend(space_strip_mode_commands(&pass));
                            pass.clear();
                        }
                        if !pass.is_empty() {
                            match window_parts(&daemon, &mut window).await {
                                Ok((_ws, _space, tab, _, _, _)) => {
                                    tab.pty_tx.send(PtyOp::Write(pass)).ok();
                                }
                                Err(e) => tracing::warn!(error = %e, "dropping input with no active tab"),
                            }
                        }
                        for cmd in commands {
                            if matches!(cmd, Command::Detach) {
                                daemon.remove_client_view(&session_id).await;
                                session.send(&ServerMsg::Bye).await.ok();
                                return Ok(());
                            }
                            let (_reply, side, repaint) =
                                run_window_command(&daemon, &mut window, cmd, viewport_state).await;
                            if let Some(control_bytes) = side {
                                session
                                    .send(&ServerMsg::HostControl {
                                        data: control_bytes,
                                    })
                                    .await?;
                            }
                            if repaint {
                                selection = None;
                                selection_autoscroll = None;
                                if let Err(e) = sync_window_view(
                                    &mut session,
                                    &daemon,
                                    &session_id,
                                    &mut window,
                                    viewport_state,
                                    selection,
                                    &mut output_rx,
                                    &mut subscribed_tab_id,
                                    &mut last_announced_ws_id,
                                    &mut last_announced_tab,
                                ).await {
                                    tracing::warn!(error = %e, "could not refresh client view after keybind command");
                                }
                            }
                        }
                    }
                    Some(ClientMsg::Resize { viewport }) => {
                        viewport_state = (viewport.cols, viewport.rows);
                        if let Err(e) = sync_window_view(
                            &mut session,
                            &daemon,
                            &session_id,
                            &mut window,
                            viewport_state,
                            selection,
                            &mut output_rx,
                            &mut subscribed_tab_id,
                            &mut last_announced_ws_id,
                            &mut last_announced_tab,
                        ).await {
                            tracing::warn!(error = %e, "could not refresh client view after resize");
                        }
                    }
                    Some(ClientMsg::Ping) => {
                        session.send(&ServerMsg::Pong).await?;
                    }
                    Some(ClientMsg::ClientLatency { latency_ms }) => {
                        daemon.update_client_latency(&session_id, latency_ms).await;
                    }
                    Some(ClientMsg::TerminalColors { colors }) => {
                        daemon.update_terminal_colors(colors).await;
                    }
                    Some(ClientMsg::Command { id, command }) => {
                        if matches!(command, Command::Detach) {
                            session
                                .send(&ServerMsg::CommandReply {
                                    id,
                                    result: CommandResult::Ok { data: None },
                                })
                                .await?;
                            daemon.remove_client_view(&session_id).await;
                            session.send(&ServerMsg::Bye).await.ok();
                            return Ok(());
                        }
                        let (reply, side_effect, repaint) =
                            run_window_command(&daemon, &mut window, command, viewport_state).await;
                        session
                            .send(&ServerMsg::CommandReply { id, result: reply })
                            .await?;
                        if let Some(control_bytes) = side_effect {
                            session
                                .send(&ServerMsg::HostControl {
                                    data: control_bytes,
                                })
                                .await?;
                        }
                        if repaint {
                            selection = None;
                            selection_autoscroll = None;
                            if let Err(e) = sync_window_view(
                                &mut session,
                                &daemon,
                                &session_id,
                                &mut window,
                                viewport_state,
                                selection,
                                &mut output_rx,
                                &mut subscribed_tab_id,
                                &mut last_announced_ws_id,
                                &mut last_announced_tab,
                            ).await {
                                tracing::warn!(error = %e, "could not refresh client view after command");
                            }
                        }
                    }
                    Some(ClientMsg::Mouse { col, row, event }) => {
                        handle_window_mouse(
                            &mut session,
                            &daemon,
                            &session_id,
                            &mut window,
                            viewport_state,
                            col,
                            row,
                            event,
                            &mut selection,
                            &mut click_tracker,
                            &mut selection_autoscroll,
                            &mut output_rx,
                            &mut subscribed_tab_id,
                            &mut last_announced_ws_id,
                            &mut last_announced_tab,
                        )
                        .await?;
                    }
                    Some(ClientMsg::Detach) | None => {
                        daemon.remove_client_view(&session_id).await;
                        session.send(&ServerMsg::Bye).await.ok();
                        return Ok(());
                    }
                    Some(
                        ClientMsg::Hello { .. }
                        | ClientMsg::HelloNative { .. }
                        | ClientMsg::NativeInput { .. }
                        | ClientMsg::NativeLayout { .. }
                        | ClientMsg::RequestPtyReplay { .. },
                    ) => return Ok(()),
                }
            }
            _ = heartbeat_tick.tick(), if heartbeat_enabled => {
                if last_client_seen.elapsed() >= heartbeat.visible_timeout {
                    tracing::warn!(
                        session_id = %session_id,
                        timeout_ms = heartbeat.visible_timeout.as_millis(),
                        "websocket client heartbeat timed out"
                    );
                    daemon.remove_client_view(&session_id).await;
                    session.send(&ServerMsg::Bye).await.ok();
                    return Ok(());
                }
            }
            _ = selection_autoscroll_tick.tick(), if selection.is_some() && selection_autoscroll.is_some() => {
                let Some(delta) = selection_autoscroll else {
                    continue;
                };
                let Ok((_ws, _space, active_tab, pane)) =
                    active_window_pane(&daemon, &mut window, viewport_state).await
                else {
                    continue;
                };
                let before_scroll_offset = daemon.broker.viewport_offset(active_tab.id).await;
                daemon.broker.scroll(active_tab.id, delta);
                let viewport_offset = daemon.broker.viewport_offset(active_tab.id).await;
                if viewport_offset == before_scroll_offset {
                    selection_autoscroll = None;
                }
                if let Some(sel) = &mut selection {
                    refresh_selection_for_viewport(&daemon, active_tab.id, sel, pane, viewport_offset)
                        .await;
                }
                repaint_window(&mut session, &daemon, &session_id, &mut window, viewport_state, selection)
                    .await?;
            }
            bytes = output_rx.recv() => {
                match bytes {
                    Ok(_data) => {
                        loop {
                            match output_rx.try_recv() {
                                Ok(_) => continue,
                                Err(broadcast::error::TryRecvError::Empty) => break,
                                Err(broadcast::error::TryRecvError::Lagged(_)) => break,
                                Err(broadcast::error::TryRecvError::Closed) => break,
                            }
                        }
                        repaint_window(&mut session, &daemon, &session_id, &mut window, viewport_state, selection)
                            .await?;
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        repaint_window(&mut session, &daemon, &session_id, &mut window, viewport_state, selection)
                            .await?;
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        if let Err(e) = sync_window_view(
                            &mut session,
                            &daemon,
                            &session_id,
                            &mut window,
                            viewport_state,
                            selection,
                            &mut output_rx,
                            &mut subscribed_tab_id,
                            &mut last_announced_ws_id,
                            &mut last_announced_tab,
                        ).await {
                            tracing::warn!(error = %e, "active tab closed before replacement was available");
                            let _ = model_rx.changed().await;
                        }
                    }
                }
            }
        }
    }
}

async fn forward_pending_input_to_active_tab(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    pending: Vec<u8>,
    reason: &'static str,
) {
    if pending.is_empty() {
        return;
    }
    let byte_count = pending.len();
    match window_parts(daemon, window).await {
        Ok((_ws, _space, tab, _, _, _)) => {
            if tab.pty_tx.send(PtyOp::Write(pending)).is_err() {
                tracing::warn!(
                    reason,
                    byte_count,
                    "dropping pending input with closed active tab"
                );
            }
        }
        Err(error) => {
            tracing::warn!(%error, reason, byte_count, "dropping pending input with no active tab");
        }
    }
}

async fn run_native_session(
    daemon: Arc<Daemon>,
    mut session: Session,
    viewport: Viewport,
    terminal_renderer: NativeTerminalRenderer,
    heartbeat: HeartbeatConfig,
    _websocket_session: bool,
) -> Result<()> {
    let session_id = uuid::Uuid::new_v4().to_string();
    session
        .send(&ServerMsg::Welcome {
            server_version: env!("CARGO_PKG_VERSION").into(),
            session_id: session_id.clone(),
        })
        .await?;

    let mut input = InputHandler::new(daemon.keybind_table());
    let mut keybinds_rx = daemon.keybinds_rx();
    let mut shutdown_rx = daemon.shutdown_rx.clone();
    let mut inbox = spawn_unix_inbox(&mut session);
    let mut model_rx = daemon.model_rx();
    let mut window = WindowState::new(&daemon).await;
    let mut viewport_state = (viewport.cols, viewport.rows);
    let mut output_mux = NativeTerminalDirtyMux::new();
    let mut pty_mux = NativePtyOutputMux::new();
    let mut pending_native_dirty_tabs = HashSet::<TabId>::new();
    let mut replayed_native_pty_tabs = HashSet::<TabId>::new();
    let mut has_native_layout = false;
    let _view_guard = ClientViewRegistration::new(daemon.clone(), session_id.clone());
    // Native libghostty clients include iroh-backed iOS sessions, not just
    // websocket sessions. Keep their client-view registrations leased by
    // heartbeat so killed/reloaded devices cannot pin stale PTY sizes.
    let heartbeat_enabled =
        heartbeat.enabled && terminal_renderer == NativeTerminalRenderer::Libghostty;
    let mut heartbeat_tick =
        tokio::time::interval(heartbeat.check_interval.max(Duration::from_millis(1)));
    heartbeat_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    heartbeat_tick.tick().await;
    let mut native_grid_tick = tokio::time::interval(Duration::from_millis(NATIVE_GRID_FRAME_MS));
    native_grid_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    native_grid_tick.tick().await;
    let mut last_client_seen = Instant::now();

    refresh_native_snapshot_for_renderer(
        &mut session,
        &daemon,
        &mut window,
        terminal_renderer,
        has_native_layout,
        &mut output_mux,
        &mut pty_mux,
        &mut replayed_native_pty_tabs,
        false,
    )
    .await?;

    loop {
        tokio::select! {
            biased;
            _ = shutdown_rx.changed() => {
                if *shutdown_rx.borrow() {
                    daemon.remove_client_view(&session_id).await;
                    session.send(&ServerMsg::Bye).await.ok();
                    return Ok(());
                }
            }
            _ = keybinds_rx.changed() => {
                let pending = input.set_table((**keybinds_rx.borrow()).clone());
                forward_pending_input_to_active_tab(&daemon, &mut window, pending, "native keybind reload").await;
            }
            changed = model_rx.changed() => {
                if changed.is_err() {
                    return Ok(());
                }
                if let Err(e) = refresh_native_snapshot_for_renderer(
                    &mut session,
                    &daemon,
                    &mut window,
                    terminal_renderer,
                    has_native_layout,
                    &mut output_mux,
                    &mut pty_mux,
                    &mut replayed_native_pty_tabs,
                    has_native_layout,
                ).await {
                    tracing::warn!(error = %e, "could not refresh native client snapshot");
                }
            }
            incoming = next_client_msg(&mut inbox, &mut session) => {
                let incoming = incoming?;
                if incoming.is_some() {
                    last_client_seen = Instant::now();
                }
                match incoming {
                    Some(ClientMsg::NativeInput { tab_id, data }) => {
                        let target_tab = match focus_tab_id_in_window(&daemon, &mut window, tab_id).await {
                            Ok(tab) => Some(tab),
                            Err(e) => {
                                tracing::warn!(error = %e, "native input target is not in the current window");
                                daemon.tab_by_id(tab_id).await
                            }
                        };
                        let (mut pass, mut commands) = input.process(&data);
                        if window.sidebar_focused && !pass.is_empty() {
                            commands.extend(sidebar_mode_commands(&pass));
                            pass.clear();
                        } else if window.space_strip_focused && !pass.is_empty() {
                            commands.extend(space_strip_mode_commands(&pass));
                            pass.clear();
                        }
                        if probe::verbose_enabled() {
                            probe::log_event(
                                "server",
                                "native_input",
                                &[
                                    ("session_id", session_id.clone()),
                                    ("tab_id", tab_id.to_string()),
                                    ("bytes", data.len().to_string()),
                                    ("pass_bytes", pass.len().to_string()),
                                    ("commands", commands.len().to_string()),
                                    ("preview", probe::preview_bytes(&data, 80)),
                                ],
                            );
                        }
                        if !pass.is_empty() {
                            if let Some(tab) = target_tab {
                                tab.pty_tx.send(PtyOp::Write(pass)).ok();
                            } else {
                                tracing::warn!(tab_id, "dropping native input with no target tab");
                            }
                        }
                        for cmd in commands {
                            if matches!(cmd, Command::Detach) {
                                daemon.remove_client_view(&session_id).await;
                                session.send(&ServerMsg::Bye).await.ok();
                                return Ok(());
                            }
                            let (_reply, side, repaint) =
                                run_window_command(&daemon, &mut window, cmd, viewport_state).await;
                            if let Some(control_bytes) = side {
                                session
                                    .send(&ServerMsg::HostControl {
                                        data: control_bytes,
                                    })
                                    .await?;
                            }
                            if repaint {
                                refresh_native_snapshot_for_renderer(
                                    &mut session,
                                    &daemon,
                                    &mut window,
                                    terminal_renderer,
                                    has_native_layout,
                                    &mut output_mux,
                                    &mut pty_mux,
                                    &mut replayed_native_pty_tabs,
                                    has_native_layout,
                                ).await?;
                            }
                        }
                    }
                    Some(ClientMsg::Input { data }) => {
                        let (mut pass, mut commands) = input.process(&data);
                        if window.sidebar_focused && !pass.is_empty() {
                            commands.extend(sidebar_mode_commands(&pass));
                            pass.clear();
                        } else if window.space_strip_focused && !pass.is_empty() {
                            commands.extend(space_strip_mode_commands(&pass));
                            pass.clear();
                        }
                        if !pass.is_empty() {
                            match window_parts(&daemon, &mut window).await {
                                Ok((_ws, _space, tab, _, _, _)) => {
                                    tab.pty_tx.send(PtyOp::Write(pass)).ok();
                                }
                                Err(e) => tracing::warn!(error = %e, "dropping native fallback input with no active tab"),
                            }
                        }
                        for cmd in commands {
                            if matches!(cmd, Command::Detach) {
                                daemon.remove_client_view(&session_id).await;
                                session.send(&ServerMsg::Bye).await.ok();
                                return Ok(());
                            }
                            let (_reply, side, repaint) =
                                run_window_command(&daemon, &mut window, cmd, viewport_state).await;
                            if let Some(control_bytes) = side {
                                session
                                    .send(&ServerMsg::HostControl {
                                        data: control_bytes,
                                    })
                                    .await?;
                            }
                            if repaint {
                                refresh_native_snapshot_for_renderer(
                                    &mut session,
                                    &daemon,
                                    &mut window,
                                    terminal_renderer,
                                    has_native_layout,
                                    &mut output_mux,
                                    &mut pty_mux,
                                    &mut replayed_native_pty_tabs,
                                    has_native_layout,
                                ).await?;
                            }
                        }
                    }
                    Some(ClientMsg::NativeLayout { terminals }) => {
                        has_native_layout = !terminals.is_empty();
                        if probe::verbose_enabled() {
                            probe::log_event(
                                "server",
                                "native_layout",
                                &[
                                    ("session_id", session_id.clone()),
                                    ("count", terminals.len().to_string()),
                                    (
                                        "terminals",
                                        terminals
                                            .iter()
                                            .map(|terminal| {
                                                format!(
                                                    "{}:{}x{}",
                                                    terminal.tab_id, terminal.cols, terminal.rows
                                                )
                                            })
                                            .collect::<Vec<_>>()
                                            .join(","),
                                    ),
                                ],
                            );
                        }
                        if terminals.is_empty() {
                            daemon.remove_client_view(&session_id).await;
                        } else {
                            daemon.update_client_native_view(&session_id, terminals).await;
                        }
                        if has_native_layout {
                            match terminal_renderer {
                                NativeTerminalRenderer::ServerGrid => {
                                    send_visible_native_terminal_grid_snapshots(
                                        &mut session,
                                        &daemon,
                                        &mut window,
                                    )
                                    .await?;
                                }
                                NativeTerminalRenderer::Libghostty => {
                                    send_visible_native_pty_replay(
                                        &mut session,
                                        &daemon,
                                        &mut window,
                                        &mut pty_mux,
                                        &mut replayed_native_pty_tabs,
                                    )
                                    .await?;
                                }
                            }
                        }
                    }
                    Some(ClientMsg::RequestPtyReplay { tab_id }) => {
                        if terminal_renderer == NativeTerminalRenderer::Libghostty {
                            send_native_pty_replay_for_tab(&mut session, &daemon, tab_id).await?;
                        }
                    }
                    Some(ClientMsg::Resize { viewport }) => {
                        viewport_state = (viewport.cols, viewport.rows);
                    }
                    Some(ClientMsg::Ping) => {
                        session.send(&ServerMsg::Pong).await?;
                    }
                    Some(ClientMsg::ClientLatency { latency_ms }) => {
                        daemon.update_client_latency(&session_id, latency_ms).await;
                    }
                    Some(ClientMsg::TerminalColors { colors }) => {
                        daemon.update_terminal_colors(colors).await;
                    }
                    Some(ClientMsg::Command { id, command }) => {
                        if matches!(command, Command::Detach) {
                            session
                                .send(&ServerMsg::CommandReply {
                                    id,
                                    result: CommandResult::Ok { data: None },
                                })
                                .await?;
                            daemon.remove_client_view(&session_id).await;
                            session.send(&ServerMsg::Bye).await.ok();
                            return Ok(());
                        }
                        let (reply, side_effect, repaint) =
                            run_window_command(&daemon, &mut window, command, viewport_state).await;
                        session
                            .send(&ServerMsg::CommandReply { id, result: reply })
                            .await?;
                        if let Some(control_bytes) = side_effect {
                            session
                                .send(&ServerMsg::HostControl {
                                    data: control_bytes,
                                })
                                .await?;
                        }
                        if repaint {
                            refresh_native_snapshot_for_renderer(
                                &mut session,
                                &daemon,
                                &mut window,
                                terminal_renderer,
                                has_native_layout,
                                &mut output_mux,
                                &mut pty_mux,
                                &mut replayed_native_pty_tabs,
                                has_native_layout,
                            ).await?;
                        }
                    }
                    Some(ClientMsg::Detach) | None => {
                        daemon.remove_client_view(&session_id).await;
                        session.send(&ServerMsg::Bye).await.ok();
                        return Ok(());
                    }
                    Some(ClientMsg::Mouse { .. }) => {}
                    Some(ClientMsg::Hello { .. } | ClientMsg::HelloNative { .. }) => return Ok(()),
                }
            }
            _ = heartbeat_tick.tick(), if heartbeat_enabled => {
                let timeout = if has_native_layout {
                    heartbeat.visible_timeout
                } else {
                    heartbeat.hidden_timeout
                };
                if last_client_seen.elapsed() >= timeout {
                    tracing::warn!(
                        session_id = %session_id,
                        visible = has_native_layout,
                        timeout_ms = timeout.as_millis(),
                        "native websocket client heartbeat timed out"
                    );
                    daemon.remove_client_view(&session_id).await;
                    session.send(&ServerMsg::Bye).await.ok();
                    return Ok(());
                }
            }
            batch = output_mux.recv_batch(), if terminal_renderer == NativeTerminalRenderer::ServerGrid => {
                let Some(batch) = batch else {
                    return Ok(());
                };
                for tab_id in &batch.tab_ids {
                    pending_native_dirty_tabs.insert(*tab_id);
                }
                if probe::verbose_enabled() {
                    probe::log_event(
                        "server",
                        "native_dirty_batch",
                        &[
                            ("session_id", session_id.clone()),
                            ("events", batch.event_count.to_string()),
                            ("unique_tabs", batch.tab_ids.len().to_string()),
                            (
                                "tab_ids",
                                batch
                                    .tab_ids
                                    .iter()
                                    .map(ToString::to_string)
                                    .collect::<Vec<_>>()
                                    .join(","),
                            ),
                        ],
                    );
                }
            }
            event = pty_mux.recv(), if has_native_layout && terminal_renderer == NativeTerminalRenderer::Libghostty => {
                let Some(event) = event else {
                    return Ok(());
                };
                session
                    .send(&ServerMsg::PtyBytes {
                        tab_id: event.tab_id,
                        data: event.data,
                    })
                    .await?;
            }
            _ = native_grid_tick.tick(), if has_native_layout && terminal_renderer == NativeTerminalRenderer::ServerGrid && !pending_native_dirty_tabs.is_empty() => {
                let mut tab_ids = pending_native_dirty_tabs.drain().collect::<Vec<_>>();
                tab_ids.sort_unstable();
                if probe::verbose_enabled() {
                    probe::log_event(
                        "server",
                        "native_dirty_flush",
                        &[
                            ("session_id", session_id.clone()),
                            ("tab_count", tab_ids.len().to_string()),
                            (
                                "tab_ids",
                                tab_ids
                                    .iter()
                                    .map(ToString::to_string)
                                    .collect::<Vec<_>>()
                                    .join(","),
                            ),
                        ],
                    );
                }
                for tab_id in tab_ids {
                    send_native_terminal_grid_snapshot(&mut session, &daemon, tab_id).await?;
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn refresh_native_snapshot_for_renderer(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    terminal_renderer: NativeTerminalRenderer,
    has_native_layout: bool,
    output_mux: &mut NativeTerminalDirtyMux,
    pty_mux: &mut NativePtyOutputMux,
    replayed_tabs: &mut HashSet<TabId>,
    send_terminal_grids: bool,
) -> Result<()> {
    let grid_mode = terminal_renderer == NativeTerminalRenderer::ServerGrid;
    let output_mux = if grid_mode { Some(output_mux) } else { None };
    send_native_snapshot(
        session,
        daemon,
        window,
        output_mux,
        send_terminal_grids && grid_mode,
    )
    .await?;
    if terminal_renderer == NativeTerminalRenderer::Libghostty && has_native_layout {
        send_visible_native_pty_replay(session, daemon, window, pty_mux, replayed_tabs).await?;
    }
    Ok(())
}

async fn send_native_snapshot(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    output_mux: Option<&mut NativeTerminalDirtyMux>,
    send_terminal_grids: bool,
) -> Result<()> {
    let snapshot = build_native_snapshot(daemon, window).await?;
    let mut visible_ids = Vec::new();
    collect_native_visible_tab_ids(&snapshot.panels, &mut visible_ids);
    let mut visible_tabs = Vec::with_capacity(visible_ids.len());
    for tab_id in &visible_ids {
        if let Some(tab) = daemon.tab_by_id(*tab_id).await {
            visible_tabs.push(tab);
        }
    }
    if let Some(output_mux) = output_mux {
        output_mux.sync(visible_tabs);
    }

    session
        .send(&ServerMsg::NativeSnapshot { snapshot })
        .await?;
    if !send_terminal_grids {
        return Ok(());
    }
    for tab_id in visible_ids {
        send_native_terminal_grid_snapshot(session, daemon, tab_id).await?;
    }
    Ok(())
}

async fn send_visible_native_terminal_grid_snapshots(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
) -> Result<()> {
    let snapshot = build_native_snapshot(daemon, window).await?;
    let mut visible_ids = Vec::new();
    collect_native_visible_tab_ids(&snapshot.panels, &mut visible_ids);
    for tab_id in visible_ids {
        send_native_terminal_grid_snapshot(session, daemon, tab_id).await?;
    }
    Ok(())
}

async fn send_visible_native_pty_replay(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    pty_mux: &mut NativePtyOutputMux,
    replayed_tabs: &mut HashSet<TabId>,
) -> Result<()> {
    let snapshot = build_native_snapshot(daemon, window).await?;
    let mut visible_ids = Vec::new();
    collect_native_visible_tab_ids(&snapshot.panels, &mut visible_ids);
    let visible_id_set: HashSet<TabId> = visible_ids.iter().copied().collect();
    replayed_tabs.retain(|tab_id| visible_id_set.contains(tab_id));

    let mut visible_tabs = Vec::with_capacity(visible_ids.len());
    for tab_id in visible_ids {
        if let Some(tab) = daemon.tab_by_id(tab_id).await {
            visible_tabs.push(tab);
        }
    }

    pty_mux.sync(&visible_tabs);
    for tab in visible_tabs {
        if !replayed_tabs.insert(tab.id) {
            continue;
        }
        send_native_pty_replay_chunks_for_tab(session, daemon, &tab).await?;
    }
    Ok(())
}

async fn send_native_pty_replay_for_tab(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    tab_id: TabId,
) -> Result<()> {
    let Some(tab) = daemon.tab_by_id(tab_id).await else {
        tracing::warn!(tab_id, "native client requested PTY replay for unknown tab");
        return Ok(());
    };
    send_native_pty_replay_chunks_for_tab(session, daemon, &tab).await
}

async fn send_native_pty_replay_chunks_for_tab(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    tab: &Arc<Tab>,
) -> Result<()> {
    let grid_replay = daemon.broker.grid_snapshot(tab.id).await.map(|snapshot| {
        native_terminal_pty_replay_from_grid_snapshot(snapshot, *tab.alternate_screen.borrow())
    });

    // PTY replay is a state replacement over an append-only byte stream.
    // Reset libghostty first, then prefer the authoritative server grid so
    // old resize history cannot append duplicate prompts on iOS reconnect.
    session
        .send(&ServerMsg::PtyBytes {
            tab_id: tab.id,
            data: LIBGHOSTTY_PTY_REPLAY_RESET.to_vec(),
        })
        .await?;
    if let Some(replay) = grid_replay {
        session
            .send(&ServerMsg::PtyBytes {
                tab_id: tab.id,
                data: replay,
            })
            .await?;
        return Ok(());
    }
    for chunk in tab.pty_replay_chunks() {
        session
            .send(&ServerMsg::PtyBytes {
                tab_id: tab.id,
                data: chunk,
            })
            .await?;
    }
    Ok(())
}

async fn send_native_terminal_grid_snapshot(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    tab_id: TabId,
) -> Result<()> {
    let start_ms = probe::mono_ms();
    let Some(snapshot) = daemon.broker.grid_snapshot(tab_id).await else {
        return Ok(());
    };
    let cols = snapshot.cols;
    let rows = snapshot.rows;
    let cells = snapshot.cells.len();
    session
        .send(&ServerMsg::TerminalGridSnapshot {
            snapshot: native_terminal_grid_snapshot(tab_id, snapshot),
        })
        .await?;
    if probe::verbose_enabled() {
        probe::log_event(
            "server",
            "native_grid_sent",
            &[
                ("tab_id", tab_id.to_string()),
                ("cols", cols.to_string()),
                ("rows", rows.to_string()),
                ("cells", cells.to_string()),
                (
                    "elapsed_ms",
                    probe::mono_ms().saturating_sub(start_ms).to_string(),
                ),
            ],
        );
    }
    Ok(())
}

fn collect_native_visible_tab_ids(node: &NativePanelNode, out: &mut Vec<TabId>) {
    match node {
        NativePanelNode::Leaf { active_tab_id, .. } => out.push(*active_tab_id),
        NativePanelNode::Split { first, second, .. } => {
            collect_native_visible_tab_ids(first, out);
            collect_native_visible_tab_ids(second, out);
        }
    }
}

async fn focus_tab_id_in_window(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    tab_id: TabId,
) -> Result<Arc<Tab>> {
    let workspaces = daemon.workspaces.lock().await.clone();
    for ws in workspaces {
        let spaces = ws.spaces.lock().await.clone();
        for space in spaces {
            let Some(panel_id) = space.panel_containing_tab(tab_id).await else {
                continue;
            };
            let Some(tab) = space.tab_by_id(tab_id).await else {
                continue;
            };
            tab.has_activity.store(false, Ordering::Relaxed);
            window.remember_tab(&ws, &space, panel_id, &tab);
            space.default_panel_id.store(panel_id, Ordering::Relaxed);
            space.active_tab_tx.send(tab.clone()).ok();
            return Ok(tab);
        }
    }
    Err(anyhow!("no tab {tab_id}"))
}

async fn build_native_snapshot(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
) -> Result<NativeSnapshot> {
    let ws = window.active_workspace(daemon).await?;
    let active_workspace_id = ws.id;
    let (workspaces, active_workspace) =
        daemon.workspace_list_with_active(active_workspace_id).await;
    let space = window.active_space(&ws).await?;
    let active_space_id = space.id;
    let (spaces, active_space) = ws.space_list_with_active(active_space_id).await;
    let focused_panel_id = window.active_panel(&space).await?;
    let focused_tab = window.active_tab(&space).await?;
    let raw_panel_tree = space.panels.lock().await.clone();
    let panel_tree = if space.zoomed.load(Ordering::Relaxed) && raw_panel_tree.is_split() {
        raw_panel_tree
            .find_panel(focused_panel_id)
            .cloned()
            .map(PanelNode::Leaf)
            .unwrap_or(raw_panel_tree)
    } else {
        raw_panel_tree
    };
    let tabs = space.tabs.lock().await;
    let by_id: HashMap<TabId, Arc<Tab>> = tabs.iter().map(|tab| (tab.id, tab.clone())).collect();
    drop(tabs);
    let panels = native_panel_node_from_panel(&panel_tree, space.id, window, &by_id);
    let attached_clients = daemon.attached_client_infos().await;
    let terminal_theme = daemon.native_terminal_theme().await;
    Ok(NativeSnapshot {
        workspaces,
        active_workspace,
        active_workspace_id,
        spaces,
        active_space,
        active_space_id,
        panels,
        focused_panel_id,
        focused_tab_id: focused_tab.id,
        attached_clients,
        terminal_theme: terminal_theme.map(Box::new),
        terminal_font: daemon.terminal_font.clone(),
        terminal_cursor: daemon.terminal_cursor.clone(),
    })
}

fn native_panel_node_from_panel(
    node: &PanelNode,
    space_id: SpaceId,
    window: &WindowState,
    tabs_by_id: &HashMap<TabId, Arc<Tab>>,
) -> NativePanelNode {
    match node {
        PanelNode::Leaf(panel) => {
            let panel_ref = PanelRef {
                space_id,
                panel_id: panel.id,
            };
            let active_tab_id = window
                .active_tab_by_panel
                .get(&panel_ref)
                .copied()
                .filter(|id| panel.tabs.contains(id))
                .or(panel.active_tab.filter(|id| panel.tabs.contains(id)))
                .or_else(|| panel.tabs.first().copied())
                .unwrap_or(0);
            let mut infos = Vec::with_capacity(panel.tabs.len());
            let mut active = 0usize;
            for (idx, tab_id) in panel.tabs.iter().enumerate() {
                let Some(tab) = tabs_by_id.get(tab_id) else {
                    continue;
                };
                if *tab_id == active_tab_id {
                    active = idx;
                }
                let is_active = *tab_id == active_tab_id;
                infos.push(TabInfo {
                    id: tab.id,
                    title: tab.title.load_full().as_ref().clone(),
                    has_activity: if is_active {
                        false
                    } else {
                        tab.has_activity.load(Ordering::Relaxed)
                    },
                    bell_count: tab.bell_count.load(Ordering::Relaxed),
                });
            }
            NativePanelNode::Leaf {
                panel_id: panel.id,
                tabs: infos,
                active,
                active_tab_id,
            }
        }
        PanelNode::Split {
            direction,
            ratio_permille,
            first,
            second,
        } => NativePanelNode::Split {
            direction: match direction {
                SplitDirection::Horizontal => NativeSplitDirection::Horizontal,
                SplitDirection::Vertical => NativeSplitDirection::Vertical,
            },
            ratio_permille: *ratio_permille,
            first: Box::new(native_panel_node_from_panel(
                first, space_id, window, tabs_by_id,
            )),
            second: Box::new(native_panel_node_from_panel(
                second, space_id, window, tabs_by_id,
            )),
        },
    }
}

async fn window_parts(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
) -> Result<(Arc<Workspace>, Arc<Space>, Arc<Tab>, usize, usize, usize)> {
    let ws = window.active_workspace(daemon).await?;
    let ws_idx = daemon.workspace_index(ws.id).await.unwrap_or(0);
    let space = window.active_space(&ws).await?;
    let space_idx = window.active_space_index(&ws).await?;
    let tab = window.active_tab(&space).await?;
    let tab_idx = space.tab_index(tab.id).await.unwrap_or(0);
    Ok((ws, space, tab, ws_idx, space_idx, tab_idx))
}

async fn active_window_pane(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    viewport: (u16, u16),
) -> Result<(Arc<Workspace>, Arc<Space>, Arc<Tab>, Rect)> {
    let ws = window.active_workspace(daemon).await?;
    let space = window.active_space(&ws).await?;
    let panel_id = window.active_panel(&space).await?;
    let leaves = window_panel_layouts(&space, window, viewport).await?;
    let leaf = leaves
        .iter()
        .find(|leaf| leaf.panel_id == panel_id)
        .or_else(|| leaves.first());
    let tab = if let Some(tab) = leaf.and_then(|leaf| leaf.active_tab.clone()) {
        tab
    } else {
        window.active_tab(&space).await?
    };
    let pane = leaf.map(|leaf| leaf.inner).unwrap_or_else(|| {
        let (_sidebar, _space_bar, _top, pane, _bottom, _status) = chrome_layout(viewport);
        pane
    });
    Ok((ws, space, tab, pane))
}

async fn current_window_selection(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    selection: Option<Selection>,
    viewport: (u16, u16),
) -> Option<LineSelection> {
    let (_ws, _space, tab, pane) = active_window_pane(daemon, window, viewport).await.ok()?;
    selection_line_in_pane(daemon, tab.id, selection, pane).await
}

async fn repaint_window(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    client_id: &str,
    window: &mut WindowState,
    viewport: (u16, u16),
    selection: Option<Selection>,
) -> Result<()> {
    let (_, _, tab, _, _, _) = window_parts(daemon, window).await?;
    let visible_selection = current_window_selection(daemon, window, selection, viewport).await;
    let frame = render_session_frame(daemon, client_id, window, viewport, visible_selection).await;
    session
        .send(&ServerMsg::PtyBytes {
            tab_id: tab.id,
            data: frame,
        })
        .await?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn sync_window_view(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    client_id: &str,
    window: &mut WindowState,
    viewport: (u16, u16),
    selection: Option<Selection>,
    output_rx: &mut broadcast::Receiver<Vec<u8>>,
    subscribed_tab_id: &mut TabId,
    last_announced_ws_id: &mut Option<u64>,
    last_announced_tab: &mut Option<(u64, u64)>,
) -> Result<()> {
    let (ws, space, tab, ws_idx, space_idx, tab_idx) = window_parts(daemon, window).await?;
    daemon.update_client_view(client_id, window, viewport).await;

    if *last_announced_ws_id != Some(ws.id) {
        let title = ws.title.lock().await.clone();
        session
            .send(&ServerMsg::ActiveWorkspaceChanged {
                index: ws_idx,
                workspace_id: ws.id,
                title,
            })
            .await?;
        *last_announced_ws_id = Some(ws.id);
        *last_announced_tab = None;
    }

    session
        .send(&ServerMsg::ActiveSpaceChanged {
            index: space_idx,
            space_id: space.id,
            title: space.title.lock().await.clone(),
        })
        .await?;

    if *last_announced_tab != Some((ws.id, tab.id)) {
        session
            .send(&ServerMsg::ActiveTabChanged {
                index: tab_idx,
                tab_id: tab.id,
            })
            .await?;
        *last_announced_tab = Some((ws.id, tab.id));
    }

    if *subscribed_tab_id != tab.id {
        *output_rx = tab.output_tx.subscribe();
        *subscribed_tab_id = tab.id;
    }

    repaint_window(session, daemon, client_id, window, viewport, selection).await
}

#[allow(clippy::too_many_arguments)]
async fn handle_window_mouse(
    session: &mut Session,
    daemon: &Arc<Daemon>,
    client_id: &str,
    window: &mut WindowState,
    viewport: (u16, u16),
    col: u16,
    row: u16,
    event: cmux_cli_protocol::MouseKind,
    selection: &mut Option<Selection>,
    click_tracker: &mut ClickTracker,
    selection_autoscroll: &mut Option<isize>,
    output_rx: &mut broadcast::Receiver<Vec<u8>>,
    subscribed_tab_id: &mut TabId,
    last_announced_ws_id: &mut Option<u64>,
    last_announced_tab: &mut Option<(u64, u64)>,
) -> Result<()> {
    use cmux_cli_protocol::MouseKind;

    let (sidebar, space_bar, _tab_bar, _full_pane, _bb, _st) = chrome_layout(viewport);
    let (active_ws, active_space, active_tab, pane) =
        active_window_pane(daemon, window, viewport).await?;
    let active_panel_id = window.active_panel(&active_space).await?;
    let in_pane = col >= pane.col
        && col < pane.col + pane.cols
        && row >= pane.row
        && row < pane.row + pane.rows;

    if matches!(event, MouseKind::Down) {
        *selection = None;
        *selection_autoscroll = None;
    }

    let inner_owns_mouse =
        *active_tab.mouse_tracking.borrow() && *active_tab.alternate_screen.borrow();
    if in_pane && inner_owns_mouse {
        let pc = col - pane.col;
        let pr = row - pane.row;
        let bytes = encode_sgr_mouse(pc, pr, event);
        active_tab.pty_tx.send(PtyOp::Write(bytes)).ok();
        return Ok(());
    }

    match event {
        MouseKind::Down => {
            let (ws_items, _) = daemon.workspace_list_with_active(window.active_ws_id).await;
            let sidebar_hit = hit_test_sidebar(col, row, sidebar, ws_items.len());
            let spaces = active_ws.spaces.lock().await.clone();
            let space_titles: Vec<String> = {
                let mut titles = Vec::with_capacity(spaces.len());
                for space in &spaces {
                    titles.push(space.title.lock().await.clone());
                }
                titles
            };
            let active_space_idx = window.active_space_index(&active_ws).await.unwrap_or(0);
            let space_hit = if sidebar_hit.is_none() {
                hit_test_tab_bar_with_active(col, row, space_bar, &space_titles, active_space_idx)
            } else {
                None
            };
            let leaves = window_panel_layouts(&active_space, window, viewport).await?;
            let tab_hit = if sidebar_hit.is_none() && space_hit.is_none() {
                leaves.iter().find_map(|leaf| {
                    let titles: Vec<String> = leaf.pills.iter().map(|p| p.title.clone()).collect();
                    let active = leaf.pills.iter().position(|p| p.active).unwrap_or(0);
                    let tab_bar = if leaf.top_border.cols >= 2 {
                        Rect {
                            col: leaf.top_border.col + 1,
                            row: leaf.top_border.row,
                            cols: leaf.top_border.cols - 2,
                            rows: leaf.top_border.rows,
                        }
                    } else {
                        leaf.top_border
                    };
                    hit_test_tab_bar_with_active(col, row, tab_bar, &titles, active)
                        .map(|idx| (leaf.panel_id, idx))
                })
            } else {
                None
            };

            let leaf_hit = if sidebar_hit.is_none()
                && space_hit.is_none()
                && tab_hit.is_none()
                && leaves.len() > 1
            {
                let inner_rects: Vec<Rect> = leaves.iter().map(|leaf| leaf.inner).collect();
                hit_test_leaf_pane(col, row, &inner_rects)
                    .and_then(|idx| leaves.get(idx).map(|leaf| leaf.panel_id))
            } else {
                None
            };

            if let Some(idx) = sidebar_hit {
                window.sidebar_focused = false;
                let ws = window.select_workspace(daemon, idx).await?;
                daemon.active_ws_tx.send(ws).ok();
                sync_window_view(
                    session,
                    daemon,
                    client_id,
                    window,
                    viewport,
                    None,
                    output_rx,
                    subscribed_tab_id,
                    last_announced_ws_id,
                    last_announced_tab,
                )
                .await?;
            } else if let Some(idx) = space_hit {
                window.sidebar_focused = false;
                window.space_strip_focused = false;
                let _space = window.select_space(&active_ws, idx).await?;
                sync_window_view(
                    session,
                    daemon,
                    client_id,
                    window,
                    viewport,
                    None,
                    output_rx,
                    subscribed_tab_id,
                    last_announced_ws_id,
                    last_announced_tab,
                )
                .await?;
            } else if let Some((panel_id, idx)) = tab_hit {
                window.sidebar_focused = false;
                window.space_strip_focused = false;
                let tab = active_space.select_tab_in_panel(panel_id, idx).await?;
                window.remember_panel(&active_ws, &active_space, panel_id, tab.id);
                window.remember_pane_focus_anchor(
                    &active_space,
                    PaneFocusAnchor {
                        col: i32::from(col),
                        row: i32::from(row),
                    },
                );
                active_space.active_tab_tx.send(tab).ok();
                sync_window_view(
                    session,
                    daemon,
                    client_id,
                    window,
                    viewport,
                    None,
                    output_rx,
                    subscribed_tab_id,
                    last_announced_ws_id,
                    last_announced_tab,
                )
                .await?;
            } else if let Some(panel_id) = leaf_hit {
                window.sidebar_focused = false;
                window.space_strip_focused = false;
                let hit_leaf = leaves
                    .iter()
                    .find(|leaf| leaf.panel_id == panel_id)
                    .cloned()
                    .ok_or_else(|| anyhow!("no panel {panel_id}"))?;
                let tab_id = hit_leaf.active_tab_id;
                let tab = active_space
                    .tab_by_id(tab_id)
                    .await
                    .ok_or_else(|| anyhow!("no tab {tab_id}"))?;
                tab.has_activity.store(false, Ordering::Relaxed);
                window.remember_panel(&active_ws, &active_space, panel_id, tab.id);
                window.remember_pane_focus_anchor(
                    &active_space,
                    PaneFocusAnchor {
                        col: i32::from(col),
                        row: i32::from(row),
                    },
                );
                active_space
                    .default_panel_id
                    .store(panel_id, Ordering::Relaxed);
                active_space.active_tab_tx.send(tab).ok();
                sync_window_view(
                    session,
                    daemon,
                    client_id,
                    window,
                    viewport,
                    None,
                    output_rx,
                    subscribed_tab_id,
                    last_announced_ws_id,
                    last_announced_tab,
                )
                .await?;
                let show_selection_now = start_selection_for_mouse_down(
                    daemon,
                    click_tracker,
                    selection,
                    ClickTarget { tab_id, panel_id },
                    col,
                    row,
                    hit_leaf.inner,
                )
                .await;
                if show_selection_now {
                    repaint_window(session, daemon, client_id, window, viewport, *selection)
                        .await?;
                }
            } else {
                let show_selection_now = start_selection_for_mouse_down(
                    daemon,
                    click_tracker,
                    selection,
                    ClickTarget {
                        tab_id: active_tab.id,
                        panel_id: active_panel_id,
                    },
                    col,
                    row,
                    pane,
                )
                .await;
                if show_selection_now {
                    repaint_window(session, daemon, client_id, window, viewport, *selection)
                        .await?;
                }
            }
        }
        MouseKind::Drag => {
            if selection.is_some() {
                let viewport_offset = daemon.broker.viewport_offset(active_tab.id).await;
                if let Some(sel) = selection {
                    if sel.granularity == SelectionGranularity::Word {
                        let (local_col, local_row) = Selection::pane_cell(col, row, pane);
                        let doc_row = viewport_offset.saturating_add(local_row as u64);
                        if let Some(range) = daemon
                            .broker
                            .word_selection(active_tab.id, local_col, doc_row)
                            .await
                        {
                            sel.update_range(col, row, range);
                        } else {
                            sel.update(col, row, pane, viewport_offset);
                        }
                    } else {
                        sel.update(col, row, pane, viewport_offset);
                    }
                }
                *selection_autoscroll = selection_autoscroll_delta(row, pane);
                if let Some(delta) = *selection_autoscroll {
                    let before_scroll_offset = viewport_offset;
                    daemon.broker.scroll(active_tab.id, delta);
                    let viewport_offset = daemon.broker.viewport_offset(active_tab.id).await;
                    if viewport_offset == before_scroll_offset {
                        *selection_autoscroll = None;
                    }
                    if let Some(sel) = selection {
                        refresh_selection_for_viewport(
                            daemon,
                            active_tab.id,
                            sel,
                            pane,
                            viewport_offset,
                        )
                        .await;
                    }
                }
                repaint_window(session, daemon, client_id, window, viewport, *selection).await?;
            }
        }
        MouseKind::Up => {
            *selection_autoscroll = None;
            if let Some(sel) = selection.take() {
                if sel.dragged || sel.granularity == SelectionGranularity::Word {
                    let text = daemon
                        .broker
                        .extract_logical_text(active_tab.id, sel.logical_selection(), pane)
                        .await;
                    if !text.trim().is_empty() {
                        daemon.buffer_push(None, text.clone()).await;
                        let osc = osc52_encode(&text);
                        session.send(&ServerMsg::HostControl { data: osc }).await?;
                    }
                }
                repaint_window(session, daemon, client_id, window, viewport, None).await?;
            }
        }
        MouseKind::Wheel { lines } => {
            let delta = lines as isize;
            daemon.broker.scroll(active_tab.id, delta);
            let viewport_offset = daemon.broker.viewport_offset(active_tab.id).await;
            if let Some(sel) = selection {
                refresh_selection_for_viewport(daemon, active_tab.id, sel, pane, viewport_offset)
                    .await;
            }
            repaint_window(session, daemon, client_id, window, viewport, *selection).await?;
        }
    }

    Ok(())
}

fn ok_result() -> CommandResult {
    CommandResult::Ok { data: None }
}

fn sidebar_mode_commands(bytes: &[u8]) -> Vec<Command> {
    let mut commands = Vec::new();
    for &byte in bytes {
        match byte {
            b'j' | 0x0e => commands.push(Command::NextWorkspace),
            b'k' | 0x10 => commands.push(Command::PrevWorkspace),
            b'c' => commands.push(Command::NewWorkspace {
                title: None,
                cwd: None,
            }),
            b'\r' | b' ' | 0x1b | b'q' => commands.push(Command::FocusSidebar),
            _ => {}
        }
    }
    commands
}

fn space_strip_mode_commands(bytes: &[u8]) -> Vec<Command> {
    let mut commands = Vec::new();
    for &byte in bytes {
        match byte {
            b'l' | 0x0e => commands.push(Command::NextSpace),
            b'h' | 0x10 => commands.push(Command::PrevSpace),
            b'\r' | b' ' | 0x1b | b'q' => commands.push(Command::FocusSpaceStrip),
            _ => {}
        }
    }
    commands
}

fn err_result(message: impl ToString) -> CommandResult {
    CommandResult::Err {
        message: message.to_string(),
    }
}

async fn close_workspace_tabs(ws: &Arc<Workspace>) {
    let spaces = ws.spaces.lock().await.clone();
    for space in spaces {
        let tabs = space.tabs.lock().await;
        for tab in tabs.iter() {
            tab.pty_tx.send(PtyOp::Write(vec![0x04])).ok();
        }
    }
}

async fn run_window_command(
    daemon: &Arc<Daemon>,
    window: &mut WindowState,
    command: Command,
    viewport: (u16, u16),
) -> (CommandResult, Option<Vec<u8>>, bool) {
    match command {
        Command::NewTab => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            match space.clone().new_tab_in_panel(panel_id).await {
                Ok(tab) => {
                    window.remember_tab(&ws, &space, panel_id, &tab);
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::SelectTab { index } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match window.select_tab(&space, index).await {
                Ok(tab) => {
                    space.active_tab_tx.send(tab).ok();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::SelectTabInPanel { panel_id, index } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match space.select_tab_in_panel(panel_id, index).await {
                Ok(tab) => {
                    window.remember_tab(&ws, &space, panel_id, &tab);
                    space.active_tab_tx.send(tab).ok();
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::NextTab => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match window.offset_tab(&space, 1).await {
                Ok(tab) => {
                    space.active_tab_tx.send(tab).ok();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::PrevTab => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match window.offset_tab(&space, -1).await {
                Ok(tab) => {
                    space.active_tab_tx.send(tab).ok();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::CloseTab => {
            let (_ws, _space, tab, _, _, _) = match window_parts(daemon, window).await {
                Ok(parts) => parts,
                Err(e) => return (err_result(e), None, false),
            };
            tab.pty_tx.send(PtyOp::Write(vec![0x04])).ok();
            (ok_result(), None, false)
        }
        Command::ListTabs => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let active_tab = match window.active_tab(&space).await {
                Ok(tab) => tab,
                Err(e) => return (err_result(e), None, false),
            };
            let (tabs, active) = space.tab_list_with_active(active_tab.id).await;
            (
                CommandResult::Ok {
                    data: Some(CommandData::TabList { tabs, active }),
                },
                None,
                false,
            )
        }
        Command::NewWorkspace { title, cwd } => {
            match daemon
                .clone()
                .new_workspace(title, cwd.map(PathBuf::from))
                .await
            {
                Ok(ws) => {
                    window.active_ws_id = ws.id;
                    if let Some(space) = ws.first_space().await
                        && let Some(panel_id) = space.default_panel_id().await
                        && let Some(tab) = space.first_tab().await
                    {
                        window.remember_tab(&ws, &space, panel_id, &tab);
                    }
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::NewSpace { title } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            match ws.clone().new_space(title).await {
                Ok(space) => {
                    window.active_space_by_ws.insert(ws.id, space.id);
                    if let Some(panel_id) = space.default_panel_id().await
                        && let Some(tab) = space.first_tab().await
                    {
                        window.remember_tab(&ws, &space, panel_id, &tab);
                    }
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::SelectWorkspace { index } => match window.select_workspace(daemon, index).await {
            Ok(ws) => {
                daemon.active_ws_tx.send(ws).ok();
                (ok_result(), None, true)
            }
            Err(e) => (err_result(e), None, false),
        },
        Command::NextWorkspace => match window.offset_workspace(daemon, 1).await {
            Ok(ws) => {
                daemon.active_ws_tx.send(ws).ok();
                (ok_result(), None, true)
            }
            Err(e) => (err_result(e), None, false),
        },
        Command::PrevWorkspace => match window.offset_workspace(daemon, -1).await {
            Ok(ws) => {
                daemon.active_ws_tx.send(ws).ok();
                (ok_result(), None, true)
            }
            Err(e) => (err_result(e), None, false),
        },
        Command::SelectSpace { index } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            match window.select_space(&ws, index).await {
                Ok(_space) => (ok_result(), None, true),
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::NextSpace => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            match window.offset_space(&ws, 1).await {
                Ok(_space) => (ok_result(), None, true),
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::PrevSpace => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            match window.offset_space(&ws, -1).await {
                Ok(_space) => (ok_result(), None, true),
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::CloseWorkspace => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            close_workspace_tabs(&ws).await;
            (ok_result(), None, false)
        }
        Command::ListWorkspaces => {
            let (workspaces, active) = daemon.workspace_list_with_active(window.active_ws_id).await;
            (
                CommandResult::Ok {
                    data: Some(CommandData::WorkspaceList { workspaces, active }),
                },
                None,
                false,
            )
        }
        Command::CloseSpace => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let tabs = space.tabs.lock().await;
            for tab in tabs.iter() {
                tab.pty_tx.send(PtyOp::Write(vec![0x04])).ok();
            }
            (ok_result(), None, false)
        }
        Command::ListSpaces => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let active_space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let (spaces, active) = ws.space_list_with_active(active_space.id).await;
            (
                CommandResult::Ok {
                    data: Some(CommandData::SpaceList { spaces, active }),
                },
                None,
                false,
            )
        }
        Command::Detach => (ok_result(), None, false),
        Command::SendInput { data } => {
            let (_ws, _space, tab, _, _, _) = match window_parts(daemon, window).await {
                Ok(parts) => parts,
                Err(e) => return (err_result(e), None, false),
            };
            if tab.pty_tx.send(PtyOp::Write(data.into_bytes())).is_err() {
                (err_result("active tab is not accepting input"), None, false)
            } else {
                (ok_result(), None, false)
            }
        }
        Command::SendKey { data } => {
            let (_ws, _space, tab, _, _, _) = match window_parts(daemon, window).await {
                Ok(parts) => parts,
                Err(e) => return (err_result(e), None, false),
            };
            if tab.pty_tx.send(PtyOp::Write(data)).is_err() {
                (err_result("active tab is not accepting input"), None, false)
            } else {
                (ok_result(), None, false)
            }
        }
        Command::RenameTab { title } => {
            let (_ws, _space, tab, _, _, _) = match window_parts(daemon, window).await {
                Ok(parts) => parts,
                Err(e) => return (err_result(e), None, false),
            };
            tab.explicit_title.store(true, Ordering::Relaxed);
            tab.title.store(Arc::new(title));
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::RenameWorkspace { title } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            {
                let mut current = ws.title.lock().await;
                *current = title;
            }
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::RenameSpace { title } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            {
                let mut current = space.title.lock().await;
                *current = title;
            }
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::SplitHorizontal | Command::SplitVertical => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            let dir = match command {
                Command::SplitHorizontal => SplitDirection::Horizontal,
                Command::SplitVertical => SplitDirection::Vertical,
                _ => SplitDirection::Horizontal,
            };
            match space.clone().split_panel(panel_id, dir).await {
                Ok((new_panel_id, tab)) => {
                    space.zoomed.store(false, Ordering::Relaxed);
                    window.remember_tab(&ws, &space, new_panel_id, &tab);
                    if let Ok(leaves) = window_panel_layouts(&space, window, viewport).await {
                        window.remember_pane_focus_anchor_for_panel(&space, &leaves, new_panel_id);
                    }
                }
                Err(e) => return (err_result(format!("split: {e}")), None, false),
            }
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::Unsplit => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            let active_tab = match window.active_tab(&space).await {
                Ok(tab) => tab,
                Err(e) => return (err_result(e), None, false),
            };
            let new_panel_id = space.flatten_panels(panel_id, active_tab.id).await;
            window.remember_panel(&ws, &space, new_panel_id, active_tab.id);
            if let Ok(leaves) = window_panel_layouts(&space, window, viewport).await {
                window.remember_pane_focus_anchor_for_panel(&space, &leaves, new_panel_id);
            }
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::FocusLeft | Command::FocusRight | Command::FocusUp | Command::FocusDown => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let active_panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            let leaves = match window_panel_layouts(&space, window, viewport).await {
                Ok(leaves) => leaves,
                Err(e) => return (err_result(e), None, false),
            };
            if leaves.len() <= 1 {
                let offset = match command {
                    Command::FocusLeft | Command::FocusUp => -1,
                    Command::FocusRight | Command::FocusDown => 1,
                    _ => 0,
                };
                return match window.offset_tab(&space, offset).await {
                    Ok(tab) => {
                        space.active_tab_tx.send(tab).ok();
                        (ok_result(), None, true)
                    }
                    Err(e) => (err_result(e), None, false),
                };
            }
            let Some((next_panel_id, next_anchor)) = focus_panel_in_direction(
                active_panel_id,
                &leaves,
                &command,
                window.pane_focus_anchor(&space),
            ) else {
                return (ok_result(), None, false);
            };
            let Some(next_leaf) = leaves.iter().find(|leaf| leaf.panel_id == next_panel_id) else {
                return (ok_result(), None, false);
            };
            match space.tab_by_id(next_leaf.active_tab_id).await {
                Some(tab) => {
                    tab.has_activity.store(false, Ordering::Relaxed);
                    window.remember_panel(&ws, &space, next_panel_id, tab.id);
                    window.remember_pane_focus_anchor(&space, next_anchor);
                    space
                        .default_panel_id
                        .store(next_panel_id, Ordering::Relaxed);
                    space.active_tab_tx.send(tab).ok();
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                None => (err_result("target panel has no active tab"), None, false),
            }
        }
        Command::FocusPanel { panel_id } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match space.active_tab_in_panel(panel_id).await {
                Ok(tab) => {
                    tab.has_activity.store(false, Ordering::Relaxed);
                    window.remember_panel(&ws, &space, panel_id, tab.id);
                    if let Ok(leaves) = window_panel_layouts(&space, window, viewport).await {
                        window.remember_pane_focus_anchor_for_panel(&space, &leaves, panel_id);
                    }
                    space.default_panel_id.store(panel_id, Ordering::Relaxed);
                    space.active_tab_tx.send(tab).ok();
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::FocusSidebar => {
            window.sidebar_focused = !window.sidebar_focused;
            if window.sidebar_focused {
                window.space_strip_focused = false;
            }
            (ok_result(), None, true)
        }
        Command::FocusSpaceStrip => {
            window.space_strip_focused = !window.space_strip_focused;
            if window.space_strip_focused {
                window.sidebar_focused = false;
            }
            (ok_result(), None, true)
        }
        Command::ResizePane { delta } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            space.resize_split_for_panel(panel_id, delta).await;
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::ResizeSplit {
            path,
            ratio_permille,
        } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match space.resize_split_at_path(&path, ratio_permille).await {
                Ok(()) => {
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::TogglePin => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            ws.pinned.fetch_xor(true, Ordering::Relaxed);
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::MoveTab { from, to } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            match space.move_tab_in_panel(panel_id, from, to).await {
                Ok(()) => {
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::MoveTabToPanel {
            from_panel_id,
            from,
            to_panel_id,
            to,
        } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            match space
                .move_tab_to_panel(from_panel_id, from, to_panel_id, to)
                .await
            {
                Ok(tab) => {
                    window.remember_tab(&ws, &space, to_panel_id, &tab);
                    space.active_tab_tx.send(tab).ok();
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::MoveTabToSplit {
            from_panel_id,
            from,
            target_panel_id,
            edge,
        } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let edge = match edge {
                SplitDropEdge::Left => PanelEdge::Left,
                SplitDropEdge::Right => PanelEdge::Right,
                SplitDropEdge::Top => PanelEdge::Top,
                SplitDropEdge::Bottom => PanelEdge::Bottom,
            };
            match space
                .clone()
                .move_tab_to_split(from_panel_id, from, target_panel_id, edge)
                .await
            {
                Ok((new_panel_id, tab)) => {
                    space.zoomed.store(false, Ordering::Relaxed);
                    window.remember_tab(&ws, &space, new_panel_id, &tab);
                    space.active_tab_tx.send(tab).ok();
                    daemon.wake_model();
                    (ok_result(), None, true)
                }
                Err(e) => (err_result(e), None, false),
            }
        }
        Command::SetWorkspaceColor { color } => {
            let normalised = match color.as_deref().map(str::trim) {
                None | Some("") => None,
                Some(raw) => match parse_hex_color(raw) {
                    Some(hex) => Some(hex),
                    None => {
                        return (
                            err_result(format!(
                                "invalid color {raw:?} (want `#RRGGBB` or `RRGGBB`)"
                            )),
                            None,
                            false,
                        );
                    }
                },
            };
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            {
                let mut current = ws.color.lock().await;
                *current = normalised;
            }
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::DisplayMessage { text } => {
            let now_ms = now_unix_millis();
            {
                let mut guard = daemon.display_message.lock().await;
                *guard = Some(DisplayMessage {
                    text,
                    expires_ms: now_ms + 2000,
                });
            }
            let daemon_for_clear = daemon.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(2100)).await;
                daemon_for_clear.wake_model();
            });
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::ToggleZoom => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            space.zoomed.fetch_xor(true, Ordering::Relaxed);
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::KillServer => {
            daemon.shutdown_tx.send(true).ok();
            (ok_result(), None, false)
        }
        Command::Notify {
            message,
            tab: tab_idx,
        } => {
            let ws = match window.active_workspace(daemon).await {
                Ok(ws) => ws,
                Err(e) => return (err_result(e), None, false),
            };
            let space = match window.active_space(&ws).await {
                Ok(space) => space,
                Err(e) => return (err_result(e), None, false),
            };
            let panel_id = match window.active_panel(&space).await {
                Ok(panel_id) => panel_id,
                Err(e) => return (err_result(e), None, false),
            };
            let target_tab = match tab_idx {
                Some(i) => match space.tab_at_in_panel(panel_id, i).await {
                    Ok(tab) => tab,
                    Err(e) => return (err_result(e), None, false),
                },
                None => match window.active_tab(&space).await {
                    Ok(tab) => tab,
                    Err(e) => return (err_result(e), None, false),
                },
            };
            target_tab.has_activity.store(true, Ordering::Relaxed);
            let new_count = target_tab.bell_count.fetch_add(1, Ordering::Relaxed) + 1;
            let now_ms = now_unix_millis();
            let flash_deadline = now_ms + FLASH_TOTAL_MS;
            target_tab
                .flash_until_ms
                .store(flash_deadline, Ordering::Relaxed);
            let daemon_for_flash = daemon.clone();
            let tab_for_clear = target_tab.clone();
            tokio::spawn(async move {
                let mut ticker = tokio::time::interval(Duration::from_millis(FLASH_PULSE_MS));
                ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                ticker.tick().await;
                loop {
                    ticker.tick().await;
                    let stored = tab_for_clear.flash_until_ms.load(Ordering::Relaxed);
                    if stored != flash_deadline {
                        break;
                    }
                    if now_unix_millis() >= flash_deadline {
                        tab_for_clear.flash_until_ms.store(0, Ordering::Relaxed);
                        daemon_for_flash.wake_model();
                        break;
                    }
                    daemon_for_flash.wake_model();
                }
            });
            if let Some(cmd) = daemon.notification_command.load_full() {
                let tab_title = target_tab.title.load_full().as_ref().clone();
                let ws_id = ws.id;
                let tab_id = target_tab.id;
                let message_env = message.unwrap_or_default();
                let cmd_str = (*cmd).clone();
                tokio::spawn(async move {
                    let _ = tokio::process::Command::new("/bin/sh")
                        .arg("-c")
                        .arg(cmd_str)
                        .env("CMX_BELL_WORKSPACE_ID", ws_id.to_string())
                        .env("CMX_BELL_TAB_ID", tab_id.to_string())
                        .env("CMX_BELL_TAB_TITLE", tab_title)
                        .env("CMX_BELL_COUNT", new_count.to_string())
                        .env("CMX_BELL_MESSAGE", message_env)
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .spawn();
                });
            }
            daemon.wake_model();
            (ok_result(), None, true)
        }
        Command::ReadScreen { lines } => {
            let (_ws, _space, tab, pane) = match active_window_pane(daemon, window, viewport).await
            {
                Ok(parts) => parts,
                Err(e) => return (err_result(e), None, false),
            };
            let end_row = pane.rows.saturating_sub(1);
            let start_row = if let Some(n) = lines {
                end_row.saturating_sub(n.saturating_sub(1).min(u16::MAX as usize) as u16)
            } else {
                0
            };
            let sel = crate::render::LineSelection {
                start_col: 0,
                start_row,
                end_col: pane.cols.saturating_sub(1),
                end_row,
            };
            let text = daemon.broker.extract_text(tab.id, sel, pane).await;
            (
                CommandResult::Ok {
                    data: Some(CommandData::ScreenText {
                        text,
                        cols: pane.cols,
                        rows: end_row + 1 - start_row,
                    }),
                },
                None,
                false,
            )
        }
        Command::Yank { buffer_name, data } => {
            let osc = osc52_encode(&data);
            daemon.buffer_push(buffer_name, data).await;
            (ok_result(), Some(osc), false)
        }
        Command::SetBuffer { buffer_name, data } => {
            daemon.buffer_push(buffer_name, data).await;
            (ok_result(), None, false)
        }
        Command::ListBuffers => {
            let buffers = daemon.buffer_list().await;
            (
                CommandResult::Ok {
                    data: Some(CommandData::BufferList { buffers }),
                },
                None,
                false,
            )
        }
        Command::PasteBuffer { index, buffer_name } => {
            match daemon.buffer_find(index, buffer_name).await {
                Some(buf) => {
                    let (_ws, _space, tab, _, _, _) = match window_parts(daemon, window).await {
                        Ok(parts) => parts,
                        Err(e) => return (err_result(e), None, false),
                    };
                    tab.pty_tx.send(PtyOp::Write(buf.data.into_bytes())).ok();
                    (ok_result(), None, false)
                }
                None => (err_result("no matching buffer"), None, false),
            }
        }
        Command::DeleteBuffer { index, buffer_name } => {
            let removed = daemon.buffer_delete(index, buffer_name).await;
            if removed {
                (ok_result(), None, false)
            } else {
                (err_result("no matching buffer to delete"), None, false)
            }
        }
    }
}

/// Run a command. The second return element is optional host-control bytes
/// for side effects such as OSC 52 clipboard sync.
#[allow(dead_code)]
async fn run_command(daemon: &Arc<Daemon>, command: Command) -> (CommandResult, Option<Vec<u8>>) {
    let mut window = WindowState::new(daemon).await;
    let ws = daemon.active_ws_rx.borrow().clone();
    let viewport = if let Some(space) = ws.first_space().await {
        *space.last_viewport.lock().await
    } else {
        daemon.spawn_opts.initial_viewport
    };
    let (reply, side_effect, _) = run_window_command(daemon, &mut window, command, viewport).await;
    (reply, side_effect)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn focused_panel(
        active_panel_id: PanelId,
        leaves: &[ResolvedPanelLeaf],
        command: &Command,
        anchor: Option<PaneFocusAnchor>,
    ) -> Option<PanelId> {
        focus_panel_in_direction(active_panel_id, leaves, command, anchor)
            .map(|(panel_id, _)| panel_id)
    }

    fn leaf(panel_id: PanelId, col: u16, row: u16, cols: u16, rows: u16) -> ResolvedPanelLeaf {
        let rect = Rect {
            col,
            row,
            cols,
            rows,
        };
        ResolvedPanelLeaf {
            panel_id,
            active_tab_id: panel_id,
            active_tab: None,
            pills: Vec::new(),
            top_border: rect,
            inner: rect,
            bottom_border: rect,
        }
    }

    #[test]
    fn focus_direction_requires_orthogonal_overlap() {
        let leaves = vec![leaf(1, 0, 0, 20, 8), leaf(2, 20, 10, 20, 8)];
        assert_eq!(focused_panel(2, &leaves, &Command::FocusLeft, None), None);
        assert_eq!(focused_panel(1, &leaves, &Command::FocusDown, None), None);
    }

    #[test]
    fn focus_direction_prefers_larger_overlap_before_diagonal_bias() {
        let leaves = vec![
            leaf(1, 0, 10, 40, 10),
            leaf(2, 25, 16, 15, 10),
            leaf(3, 40, 10, 20, 10),
        ];
        assert_eq!(
            focused_panel(3, &leaves, &Command::FocusLeft, None),
            Some(1)
        );
    }

    #[test]
    fn focus_direction_uses_anchor_to_round_trip_through_a_wide_pane() {
        let leaves = vec![
            leaf(1, 0, 0, 80, 10),
            leaf(2, 0, 10, 40, 10),
            leaf(3, 40, 10, 40, 10),
        ];
        assert_eq!(
            focused_panel(
                1,
                &leaves,
                &Command::FocusDown,
                Some(PaneFocusAnchor { col: 60, row: 4 }),
            ),
            Some(3)
        );
    }

    #[test]
    fn term_fallback_catches_missing_dumb_and_multiplexer_values() {
        assert!(should_fallback_term(None));
        assert!(should_fallback_term(Some("")));
        assert!(should_fallback_term(Some(" dumb ")));
        assert!(should_fallback_term(Some("tmux-256color")));
        assert!(should_fallback_term(Some("screen-256color")));
        assert!(!should_fallback_term(Some("xterm-256color")));
    }

    #[tokio::test]
    async fn websocket_tcp_stream_enables_nodelay_for_terminal_latency() -> Result<()> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let (client, (server, _)) =
            tokio::try_join!(tokio::net::TcpStream::connect(addr), listener.accept())?;

        let server = configure_ws_tcp_stream(server)?;

        assert!(server.nodelay()?);
        drop(client);
        Ok(())
    }

    #[test]
    fn term_fallback_uses_generic_truecolor_term_when_server_term_is_dumb() {
        assert_eq!(
            child_term_override_for_environment(Some("dumb"), Some("ghostty")),
            Some("xterm-256color")
        );
        assert_eq!(
            child_term_override_for_environment(Some(""), Some("Apple_Terminal")),
            Some("xterm-256color")
        );
        assert_eq!(
            child_term_override_for_environment(Some("xterm-ghostty"), Some("ghostty")),
            None
        );
    }

    #[test]
    fn term_override_preserves_generic_xterm_for_ghostty_hosts() {
        assert_eq!(
            child_term_override_for_environment(Some("xterm-256color"), Some("ghostty")),
            None
        );
        assert_eq!(
            child_term_override_for_environment(Some("tmux-256color"), Some("ghostty")),
            Some("xterm-256color")
        );
    }

    #[test]
    fn child_env_skips_host_multiplexer_identity() {
        assert!(should_skip_child_env("TMUX", "/tmp/tmux-501/default,1,0"));
        assert!(should_skip_child_env("TMUX_PANE", "%1"));
        assert!(should_skip_child_env("STY", "123.screen"));
        assert!(should_skip_child_env("TERM_PROGRAM", "tmux"));
        assert!(should_skip_child_env("TERM_PROGRAM", "screen"));
        assert!(!should_skip_child_env("TERM_PROGRAM", "ghostty"));
        assert!(!should_skip_child_env("PATH", "/usr/bin"));
    }
}
