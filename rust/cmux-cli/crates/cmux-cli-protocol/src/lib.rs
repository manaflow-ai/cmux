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

//! Wire protocol for cmux-cli.
//!
//! All messages go over an async byte stream (Unix socket or WebSocket).
//! Framing: length-prefixed (big-endian u32) MessagePack payloads.
//!
//! v3 is deliberately small: enough to attach, stream terminal grids,
//! resize, and issue server-side commands.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Wire-protocol version. Bump on any non-backwards-compat change.
pub const PROTOCOL_VERSION: u32 = 3;

/// Client viewport in cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Viewport {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalColorReport {
    pub foreground: Option<TerminalRgb>,
    pub background: Option<TerminalRgb>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub palette: BTreeMap<u8, TerminalRgb>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum NativeTerminalRenderer {
    /// Server-side libghostty-vt emits styled cell snapshots.
    #[default]
    ServerGrid,
    /// Client-side libghostty receives raw PTY replay and live PTY bytes.
    Libghostty,
}

/// Client → server.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ClientMsg {
    /// First message on the wire. `version` must match [`PROTOCOL_VERSION`].
    Hello {
        version: u32,
        viewport: Viewport,
        /// Bearer token. Required for WebSocket transport; ignored for Unix
        /// socket transport (where filesystem permissions gate access).
        #[serde(default)]
        token: Option<String>,
    },
    /// Native graphical client mode. The server sends structured cmx state.
    /// `terminal_renderer` decides whether terminal content arrives as
    /// server-side styled cells or as raw PTY bytes for client-side libghostty.
    HelloNative {
        version: u32,
        viewport: Viewport,
        #[serde(default)]
        token: Option<String>,
        #[serde(default)]
        terminal_renderer: NativeTerminalRenderer,
    },
    /// Keystrokes / paste bytes destined for the focused tab's PTY.
    Input {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Client window/viewport changed.
    Resize { viewport: Viewport },
    /// Client is detaching cleanly.
    Detach,
    /// Heartbeat.
    Ping,
    /// Client-measured round trip latency from the most recent ping/pong.
    ClientLatency { latency_ms: u32 },
    /// Invoke a server-side command (e.g. `new-tab`, `select-tab`).
    Command {
        /// Incrementing id set by the client so replies can be correlated.
        id: u32,
        command: Command,
    },
    /// A mouse event against the client viewport. Used by server-side
    /// selection-to-yank (highlight to copy).
    Mouse {
        /// 0-based column relative to the viewport's top-left.
        col: u16,
        /// 0-based row relative to the viewport's top-left.
        row: u16,
        event: MouseKind,
    },
    /// Best-effort report of host terminal OSC 10/11 default colors. `None`
    /// means the host did not answer, so the server should not invent a
    /// response for child applications.
    TerminalColors { colors: TerminalColorReport },
    /// Raw bytes destined for a specific terminal. Native clients use this
    /// because the focused React pane owns its own input surface.
    NativeInput {
        tab_id: u64,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Complete list of terminal viewports currently visible in this client.
    /// The server uses this with the existing "smallest visible client wins"
    /// resize policy.
    NativeLayout {
        terminals: Vec<NativeTerminalViewport>,
    },
    /// Native libghostty client detected a lost/blank local renderer and needs
    /// the server to resend the buffered PTY stream for one terminal.
    RequestPtyReplay { tab_id: u64 },
}

/// Minimal mouse event model for M-era selection-to-yank. A richer model
/// (pixel coords, wheel granularity, modifiers) can arrive later without
/// breaking the wire.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MouseKind {
    /// Left button pressed down.
    Down,
    /// Moved while left button is held.
    Drag,
    /// Left button released.
    Up,
    /// Wheel scrolled up / down. Decimal lines; negative = scroll up.
    Wheel { lines: i16 },
}

/// A server-side command.
///
/// Kept as a fixed enum matching cmux action names where they exist.
/// String-based RPC with arbitrary args arrives later (see `Command::Rpc`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "name", rename_all = "kebab-case")]
pub enum Command {
    /// Create a new terminal in the focused pane. Compatibility alias:
    /// "tab".
    NewTab,
    /// Select the terminal at the given index in the focused pane's stack.
    /// Compatibility alias: "tab".
    SelectTab {
        index: usize,
    },
    /// Select the next terminal in the focused pane's stack (wraps).
    /// Compatibility alias: "tab".
    NextTab,
    /// Select the previous terminal in the focused pane's stack (wraps).
    /// Compatibility alias: "tab".
    PrevTab,
    /// Close the active terminal. Compatibility alias: "tab".
    CloseTab,
    /// List every terminal in the focused pane. Compatibility alias: "tab".
    ListTabs,
    /// Create a new workspace. Becomes active.
    NewWorkspace {
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
    },
    /// Create a new space in the active workspace. Becomes active.
    NewSpace {
        #[serde(default)]
        title: Option<String>,
    },
    /// Select the workspace at the given index.
    SelectWorkspace {
        index: usize,
    },
    /// Select the space at the given index within the active workspace.
    SelectSpace {
        index: usize,
    },
    /// Cycle to the next workspace (wraps).
    NextWorkspace,
    /// Cycle to the previous workspace (wraps).
    PrevWorkspace,
    /// Cycle to the next space in the active workspace (wraps).
    NextSpace,
    /// Cycle to the previous space in the active workspace (wraps).
    PrevSpace,
    /// Close the active workspace. If the last, the server shuts down.
    CloseWorkspace,
    /// Return the list of workspaces.
    ListWorkspaces,
    /// Close the active space. If it is the last space, the workspace
    /// closes according to normal workspace lifecycle rules.
    CloseSpace,
    /// Return the list of spaces in the active workspace.
    ListSpaces,
    /// Push a string onto the paste-buffer stack. The server also emits
    /// OSC 52 to attached clients so the host terminal's system clipboard
    /// mirrors the yank.
    Yank {
        #[serde(default)]
        buffer_name: Option<String>,
        data: String,
    },
    /// Alias for `Yank` that doesn't send OSC 52 (tmux-compatible
    /// `set-buffer` semantics).
    SetBuffer {
        #[serde(default)]
        buffer_name: Option<String>,
        data: String,
    },
    /// Return the paste-buffer stack.
    ListBuffers,
    /// Type the contents of a buffer into the active tab's PTY.
    /// `index` is 0 for the most recent yank, N-1 for the oldest kept.
    PasteBuffer {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        buffer_name: Option<String>,
    },
    /// Delete a buffer by index or name. None clears the whole stack.
    DeleteBuffer {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        buffer_name: Option<String>,
    },
    /// Detach this client. The server sends Bye; the client cleans up raw
    /// mode + alt screen and exits. Other clients and the server itself
    /// stay alive.
    Detach,
    /// Inject bytes into the active tab's PTY as if the user had typed
    /// them. Used by `cmx send`.
    SendInput {
        data: String,
    },
    /// Return the active tab's current visible screen text. `lines = None`
    /// returns the entire viewport; `Some(n)` returns the last n rows.
    ReadScreen {
        #[serde(default)]
        lines: Option<usize>,
    },
    /// Inject raw bytes into the active tab's PTY. Unlike `SendInput`,
    /// this carries arbitrary bytes (control chars, escape sequences,
    /// non-UTF-8 payloads), used by `cmx send-key` to synthesise key
    /// presses like `C-c`, `Up`, `F1`.
    SendKey {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Rename the currently-active terminal. Compatibility alias: "tab".
    RenameTab {
        title: String,
    },
    /// Rename the currently-active workspace.
    RenameWorkspace {
        title: String,
    },
    /// Rename the currently-active space.
    RenameSpace {
        title: String,
    },
    /// Shut down the server. The `CommandReply` may never arrive
    /// because the server is already tearing down; clients should
    /// treat a missing reply as success for this command.
    KillServer,
    /// Mark a tab as having new activity, optionally attaching a
    /// message. Bumps the tab's bell counter so downstream consumers
    /// (bell command, pane flash, etc.) can hook in. If `tab` is
    /// `None`, targets the active tab of the active workspace.
    Notify {
        #[serde(default)]
        message: Option<String>,
        #[serde(default)]
        tab: Option<usize>,
    },
    /// Split the active panel side-by-side and focus the new panel.
    /// Each leaf panel owns its own tab stack. Matches tmux `C-b %`
    /// semantics.
    SplitHorizontal,
    /// Switch into stacked split mode (horizontal divider → "one
    /// pane above, one below"). Matches tmux `C-b "` semantics.
    SplitVertical,
    /// Flatten the panel tree into one panel, preserving the active tab.
    Unsplit,
    /// Move focus to the nearest panel in that direction. Outside split
    /// mode this cycles tabs, matching tmux-style muscle memory.
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    /// Move keyboard focus to the workspace sidebar for this client.
    /// While focused there, `j` / `k` and `Ctrl-n` / `Ctrl-p` cycle
    /// workspaces without typing into the shell.
    FocusSidebar,
    /// Move keyboard focus to the space strip for this client. While focused
    /// there, `h` / `l` and `Ctrl-p` / `Ctrl-n` cycle spaces without typing
    /// into the shell.
    FocusSpaceStrip,
    /// Toggle pane-zoom: when on, the active leaf fills the whole
    /// pane area and other leaves are hidden. Toggling off restores
    /// the split layout. No-op when not in split mode.
    ToggleZoom,
    /// Resize the nearest split ancestor of the active panel. `delta`
    /// is a signed change in thousandths of that split's area (negative
    /// = shrink the first child; positive = grow it).
    ResizePane {
        delta: i16,
    },
    /// Set an explicit split ratio by walking the visible panel tree from
    /// the root. Native clients use this for direct mouse resizing of a
    /// specific divider, including nested split dividers.
    ResizeSplit {
        #[serde(default)]
        path: Vec<SplitPathStep>,
        ratio_permille: u16,
    },
    /// Show a transient message in the status bar for ~2 seconds.
    /// Used by `cmx display-message` and future prompt-style UIs.
    DisplayMessage {
        text: String,
    },
    /// Toggle the active workspace's pinned state. Pinned workspaces
    /// respawn their shell when the last tab exits, so the workspace
    /// survives `exit` / `C-d`.
    TogglePin,
    /// Set a workspace's pinned state without making that workspace active.
    SetWorkspacePinned {
        workspace_id: u64,
        pinned: bool,
    },
    /// Set or clear the unread/activity flag for every tab in a workspace.
    SetWorkspaceUnread {
        workspace_id: u64,
        unread: bool,
    },
    /// Set (or clear with `None`) the active workspace's color
    /// tint. Value is a `#RRGGBB` hex string, rejected if malformed.
    SetWorkspaceColor {
        #[serde(default)]
        color: Option<String>,
    },
    /// Reorder a tab. Moves the tab at `from` to index `to`. Other
    /// tabs shift to make room. Indices beyond the bounds clamp.
    MoveTab {
        from: usize,
        to: usize,
    },
    /// Move a tab between panel tab stacks. `to` is an insertion slot, so it
    /// may equal the destination tab count to append at the end.
    MoveTabToPanel {
        from_panel_id: u64,
        from: usize,
        to_panel_id: u64,
        to: usize,
    },
    /// Move a tab into a new split adjacent to an existing target panel.
    MoveTabToSplit {
        from_panel_id: u64,
        from: usize,
        target_panel_id: u64,
        edge: SplitDropEdge,
    },
    /// Focus a split panel by id. Used by native clients whose chrome can
    /// address panels directly.
    FocusPanel {
        panel_id: u64,
    },
    /// Select a terminal by index inside a specific panel.
    SelectTabInPanel {
        panel_id: u64,
        index: usize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitDropEdge {
    Left,
    Right,
    Top,
    Bottom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitPathStep {
    First,
    Second,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeTerminalViewport {
    pub tab_id: u64,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachedClientKind {
    Tui,
    Native,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachedClientInfo {
    pub client_id: String,
    pub kind: AttachedClientKind,
    pub visible_terminal_count: usize,
    pub updated_at_ms: u64,
    pub terminals: Vec<NativeTerminalViewport>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u32>,
}

/// Server → client.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ServerMsg {
    /// Response to Hello. Session id is opaque; clients should echo it back
    /// on reconnect to reclaim server-side per-client state.
    Welcome {
        server_version: String,
        session_id: String,
    },
    /// Rendered terminal bytes for Grid-mode clients. `tab_id` scopes the
    /// active terminal that should receive input and cursor ownership.
    PtyBytes {
        tab_id: u64,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Host-terminal control side effects that should not be fed into the
    /// client's libghostty-vt grid, such as OSC 52 clipboard writes.
    HostControl {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    /// Server is shutting down this session.
    Bye,
    /// Heartbeat reply.
    Pong,
    /// Reply to a `ClientMsg::Command`, keyed by the client's `id`.
    CommandReply { id: u32, result: CommandResult },
    /// Informational: the active tab changed (sent on command success and
    /// on external changes like the shell exiting).
    ActiveTabChanged { index: usize, tab_id: u64 },
    /// Informational: the active workspace changed.
    ActiveWorkspaceChanged {
        index: usize,
        workspace_id: u64,
        title: String,
    },
    /// Informational: the active space changed.
    ActiveSpaceChanged {
        index: usize,
        space_id: u64,
        title: String,
    },
    /// Structured chrome/layout state for native clients. Terminal cell
    /// content arrives through `TerminalGridSnapshot`.
    NativeSnapshot { snapshot: NativeSnapshot },
    /// Current visible, fully styled grid for one terminal. Server
    /// libghostty-vt is the only terminal parser in native mode; graphical
    /// clients draw these cells directly.
    TerminalGridSnapshot {
        snapshot: NativeTerminalGridSnapshot,
    },
    /// Protocol / application error. Fatal for the connection.
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeTerminalGridSnapshot {
    pub tab_id: u64,
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<NativeTerminalGridCell>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<NativeTerminalCursorPosition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeTerminalGridCell {
    pub text: String,
    pub width: u8,
    pub fg: TerminalRgb,
    pub bg: TerminalRgb,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub faint: bool,
    pub blink: bool,
    pub strikethrough: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct NativeTerminalCursorPosition {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub style: NativeTerminalCursorStyle,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<TerminalRgb>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeTerminalCursorStyle {
    Block,
    HollowBlock,
    Underline,
    Bar,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeSnapshot {
    pub workspaces: Vec<WorkspaceInfo>,
    pub active_workspace: usize,
    pub active_workspace_id: u64,
    pub spaces: Vec<SpaceInfo>,
    pub active_space: usize,
    pub active_space_id: u64,
    pub panels: NativePanelNode,
    pub focused_panel_id: u64,
    pub focused_tab_id: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attached_clients: Vec<AttachedClientInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_theme: Option<Box<NativeTerminalThemeSet>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_font: Option<NativeTerminalFont>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_cursor: Option<NativeTerminalCursor>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeTerminalThemeSet {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<NativeTerminalTheme>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light: Option<NativeTerminalTheme>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark: Option<NativeTerminalTheme>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeTerminalTheme {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub palette: BTreeMap<u8, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_accent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection_background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection_foreground: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub black: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub red: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub green: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub yellow: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blue: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub magenta: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cyan: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub white: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_black: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_red: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_green: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_yellow: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_blue: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_magenta: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_cyan: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bright_white: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NativeTerminalFont {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub families: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NativeTerminalCursor {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blink: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NativePanelNode {
    Leaf {
        panel_id: u64,
        tabs: Vec<TabInfo>,
        active: usize,
        active_tab_id: u64,
    },
    Split {
        direction: NativeSplitDirection,
        ratio_permille: u16,
        first: Box<NativePanelNode>,
        second: Box<NativePanelNode>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeSplitDirection {
    Horizontal,
    Vertical,
}

/// Outcome of a server-side command.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum CommandResult {
    /// Command succeeded. `data` carries command-specific output (e.g.
    /// `ListTabs` returns the tab list here).
    Ok { data: Option<CommandData> },
    /// Command failed with a human-readable reason.
    Err { message: String },
}

/// Optional structured output tied to specific commands.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CommandData {
    TabList {
        tabs: Vec<TabInfo>,
        active: usize,
    },
    WorkspaceList {
        workspaces: Vec<WorkspaceInfo>,
        active: usize,
    },
    SpaceList {
        spaces: Vec<SpaceInfo>,
        active: usize,
    },
    BufferList {
        buffers: Vec<BufferInfo>,
    },
    /// Full text of the active tab's current visible screen (or the last
    /// `lines` rows if the client asked for that). One row per line, no
    /// SGR attributes — plain text.
    ScreenText {
        text: String,
        cols: u16,
        rows: u16,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BufferInfo {
    /// Optional user-provided or auto-generated name.
    pub name: Option<String>,
    /// Total bytes held.
    pub len: usize,
    /// Short preview for display (up to ~60 chars, graphemes truncated).
    pub preview: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabInfo {
    pub id: u64,
    pub title: String,
    /// True when the tab has emitted PTY output since the user last
    /// viewed it (inactive tabs only; the active tab always reads as
    /// `false`). Used by the tab bar to show a dot next to noisy
    /// background tabs. Optional for wire-compat with older clients.
    #[serde(default)]
    pub has_activity: bool,
    /// Cumulative count of bell bytes (0x07) emitted by the tab.
    #[serde(default)]
    pub bell_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceInfo {
    pub id: u64,
    pub title: String,
    /// New public model: a workspace contains spaces.
    #[serde(default)]
    pub space_count: usize,
    /// Back-compat alias from the older workspace -> tab model.
    #[serde(default)]
    pub tab_count: usize,
    /// Total terminal count across every space in the workspace.
    #[serde(default)]
    pub terminal_count: usize,
    /// Pinned workspaces respawn their shell when the last tab
    /// exits, so they survive `exit` / `C-d`. Optional for wire
    /// compat with older clients.
    #[serde(default)]
    pub pinned: bool,
    /// True when any tab in this workspace has unseen activity.
    #[serde(default)]
    pub has_activity: bool,
    /// Total bell count across tabs in this workspace.
    #[serde(default)]
    pub bell_count: u64,
    /// User-set color tint in `#RRGGBB` format. `None` = default.
    #[serde(default)]
    pub color: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpaceInfo {
    pub id: u64,
    pub title: String,
    #[serde(default)]
    pub pane_count: usize,
    #[serde(default)]
    pub terminal_count: usize,
}

/// Error decoding a framed message.
#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("frame too large ({0} bytes, max {1})")]
    FrameTooLarge(usize, usize),
    #[error(
        "protocol desync — length prefix {0:?} ({0:x?}) looks like ASCII payload data. \
         The server is likely running stale code; try `./cmx.sh restart`."
    )]
    ProtocolDesync([u8; 4]),
    #[error("decode: {0}")]
    Decode(#[from] rmp_serde::decode::Error),
    #[error("encode: {0}")]
    Encode(#[from] rmp_serde::encode::Error),
}

/// Per-frame ceiling. 64 MiB leaves room for Kitty graphics bitmaps.
pub const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;

/// Read one length-prefixed MessagePack message.
///
/// Returns `Ok(None)` on clean EOF before the length prefix is read.
///
/// If the length prefix deserializes to a suspicious value (e.g. a stream
/// of ASCII bytes consumed as if they were a u32), we emit a targeted
/// error rather than trying to allocate a gigabyte. When the prefix's
/// bytes look printable it's almost always a protocol desync (client vs.
/// server version mismatch, or mid-stream garbage) — the error message
/// says so.
pub async fn read_msg<R, T>(reader: &mut R) -> Result<Option<T>, CodecError>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let Some(len_buf) = read_len_prefix(reader).await? else {
        return Ok(None);
    };
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME_BYTES {
        let all_printable = len_buf.iter().all(|b| (0x20..=0x7e).contains(b));
        if all_printable {
            return Err(CodecError::ProtocolDesync(len_buf));
        }
        return Err(CodecError::FrameTooLarge(len, MAX_FRAME_BYTES));
    }
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf).await?;
    let msg = rmp_serde::from_slice(&buf)?;
    Ok(Some(msg))
}

/// Write one length-prefixed MessagePack message.
pub async fn write_msg<W, T>(writer: &mut W, msg: &T) -> Result<(), CodecError>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let buf = rmp_serde::to_vec_named(msg)?;
    let len = checked_frame_len(buf.len())?;
    writer.write_all(&len.to_be_bytes()).await?;
    writer.write_all(&buf).await?;
    writer.flush().await?;
    Ok(())
}

async fn read_len_prefix<R>(reader: &mut R) -> Result<Option<[u8; 4]>, CodecError>
where
    R: AsyncRead + Unpin,
{
    let mut len_buf = [0u8; 4];
    let mut read = 0usize;
    while read < len_buf.len() {
        let n = reader.read(&mut len_buf[read..]).await?;
        if n == 0 {
            if read == 0 {
                return Ok(None);
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "truncated frame length",
            )
            .into());
        }
        read += n;
    }
    Ok(Some(len_buf))
}

fn checked_frame_len(len: usize) -> Result<u32, CodecError> {
    if len > MAX_FRAME_BYTES {
        return Err(CodecError::FrameTooLarge(len, MAX_FRAME_BYTES));
    }
    Ok(len as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::duplex;

    #[tokio::test]
    async fn roundtrip_hello() {
        let (mut a, mut b) = duplex(64 * 1024);
        let msg = ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport {
                cols: 120,
                rows: 40,
            },
            token: Some("probe".into()),
        };
        let sent = msg.clone();
        let writer = tokio::spawn(async move {
            write_msg(&mut a, &sent).await.unwrap();
        });
        let got: ClientMsg = read_msg(&mut b).await.unwrap().unwrap();
        writer.await.unwrap();
        match (msg, got) {
            (
                ClientMsg::Hello {
                    version: sent_version,
                    viewport: vp1,
                    token: t1,
                },
                ClientMsg::Hello {
                    version: got_version,
                    viewport: vp2,
                    token: t2,
                },
            ) => {
                assert_eq!(sent_version, got_version);
                assert_eq!(vp1, vp2);
                assert_eq!(t1, t2);
            }
            _ => panic!("wrong variant after roundtrip"),
        }
    }

    #[tokio::test]
    async fn roundtrip_pty_bytes() {
        let (mut a, mut b) = duplex(64 * 1024);
        let payload = vec![0u8, 1, 2, 3, 255, 254];
        let msg = ServerMsg::PtyBytes {
            tab_id: 7,
            data: payload.clone(),
        };
        let writer = tokio::spawn(async move {
            write_msg(&mut a, &msg).await.unwrap();
        });
        let got: ServerMsg = read_msg(&mut b).await.unwrap().unwrap();
        writer.await.unwrap();
        match got {
            ServerMsg::PtyBytes { tab_id, data } => {
                assert_eq!(tab_id, 7);
                assert_eq!(data, payload);
            }
            other => panic!("expected PtyBytes, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn roundtrip_terminal_colors() {
        let (mut a, mut b) = duplex(64 * 1024);
        let mut palette = BTreeMap::new();
        palette.insert(
            118,
            TerminalRgb {
                r: 95,
                g: 215,
                b: 0,
            },
        );
        let msg = ClientMsg::TerminalColors {
            colors: TerminalColorReport {
                foreground: Some(TerminalRgb {
                    r: 250,
                    g: 251,
                    b: 252,
                }),
                background: Some(TerminalRgb {
                    r: 10,
                    g: 11,
                    b: 12,
                }),
                palette,
            },
        };
        let sent = msg.clone();
        let writer = tokio::spawn(async move {
            write_msg(&mut a, &sent).await.unwrap();
        });
        let got: ClientMsg = read_msg(&mut b).await.unwrap().unwrap();
        writer.await.unwrap();

        match (msg, got) {
            (
                ClientMsg::TerminalColors { colors: sent },
                ClientMsg::TerminalColors { colors: got },
            ) => assert_eq!(sent, got),
            _ => panic!("wrong variant after roundtrip"),
        }
    }

    #[tokio::test]
    async fn read_msg_returns_none_only_for_clean_eof_before_frame() {
        let mut reader = tokio::io::empty();

        let got = read_msg::<_, ClientMsg>(&mut reader).await.unwrap();

        assert!(got.is_none());
    }

    #[tokio::test]
    async fn read_msg_rejects_truncated_length_prefix() {
        let mut reader = &b"\x00\x00"[..];

        let error = read_msg::<_, ClientMsg>(&mut reader).await.unwrap_err();

        assert!(matches!(
            error,
            CodecError::Io(ref io_error)
                if io_error.kind() == std::io::ErrorKind::UnexpectedEof
        ));
    }

    #[test]
    fn checked_frame_len_rejects_frames_above_protocol_limit() {
        let error = checked_frame_len(MAX_FRAME_BYTES + 1).unwrap_err();

        assert!(matches!(
            error,
            CodecError::FrameTooLarge(len, max)
                if len == MAX_FRAME_BYTES + 1 && max == MAX_FRAME_BYTES
        ));
    }
}
