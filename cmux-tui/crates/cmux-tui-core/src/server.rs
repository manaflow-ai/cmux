//! Control protocol server over Unix JSON-lines and WebSocket text frames.
//!
//! This is the attach surface for external frontends (the cmux app, the
//! bundled `cmux-tui attach` client, scripts). Unix uses one JSON message
//! per line and WebSocket uses one JSON message per text frame. Two commands
//! additionally turn the connection full-duplex:
//!
//! - `subscribe` — the server pushes `{"event":...}` lines (tree-changed,
//!   surface-output, surface-exited, title-changed, bell) interleaved
//!   with responses.
//! - `attach-surface` — PTYs receive `{"event":"vt-state"}` with a
//!   base64 VT replay followed by live `{"event":"output"}` pty bytes.
//!   Browsers receive `{"event":"browser-state"}` with optional latest
//!   frame followed by live `{"event":"frame"}` PNG payloads.
//!
//! ```text
//! {"id":1,"cmd":"identify"}
//! {"id":1,"ok":true,"data":{"app":"cmux-tui","session":"main",...}}
//! ```

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::mem::{offset_of, size_of};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context;
use base64::Engine;
use ghostty_vt::{
    Dirty, KeyAction, KeyEncoder, KeyInput, KittyReplayState, Mods, StyledRun, UnderlineStyle,
    key_input_from_chord, rows_to_runs, sys,
};
use regex::Regex;
use regex::bytes::{Regex as BytesRegex, RegexBuilder as BytesRegexBuilder};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket, accept_with_config};
use zeroize::Zeroize;

use crate::browser::{
    BrowserAttachUpdate, BrowserFrameUpdate, BrowserMouseDispatch, BrowserPointerOwner,
};
use crate::browser_provider::{
    BrowserProviderAuthentication, BrowserProviderRegistration, BrowserProviderSnapshot,
};
use crate::journal_kernel::{JournalDocument, SharedJournalPage, SharedJournalRead};
use crate::model::{Screen, State, Workspace};
use crate::mux::{DaemonHandoffRequest, ResourceWaitWake, clamp_terminal_size};
use crate::platform::{self, transport};
use crate::resource::{
    BrowserPublicId, ClientPublicId, ContentPublicId, RequestId as ResourceRequestId,
    ResourceError, ResourceOperation, ResponseEnvelope as ResourceResponseEnvelope, Selector,
    SessionPublicId, StreamPublicId, TabPublicId, TerminalPublicId, WireDecimal,
};
use crate::sidebar_resource::{
    SidebarRenderAttachment, SidebarRenderClientState, attach_sidebar_render, resolve_sidebar_view,
    sidebar_attach_snapshot, sidebar_snapshot,
};
use crate::surface::{
    AttachLifecycle, CLEAR_HISTORY_KEY_TEXT_MAX_BYTES, ClearHistoryDelivery, ClearHistoryFailure,
};
use crate::workspace_registry::TerminalLifecycle;
use crate::{
    AgentRecord, AgentSource, AgentState, AttachFrame, BrowserAttachState, BrowserFrameStream,
    DefaultColors, Direction, GraphicsStatus, JournalClass, JournalSensitivity, JournalSubject,
    LayoutLeafSpec, LayoutRatioError, LayoutSpec, LayoutUndoResult, Mux, MuxEvent, Node,
    NotificationLevel, PairingDecision, PaneId, RenderAttachFrame, RenderAttachStream, Rgb,
    ScreenId, SidebarPluginStatus, SplitDir, SplitId, SurfaceId, SurfaceKind, SurfaceNotification,
    SurfaceRenderFrame, TerminalColors, TreeDelta, TreeDeltaKind, ViewportWidthError, WorkspaceId,
    WorkspaceMutation, ZoomMode, assign_short_ids,
};

pub const ATTACH_INITIAL_SIZE_CAPABILITY: &str = "attach-initial-size";
/// Maximum JSON payload accepted on the Unix JSON-lines control socket.
const MAX_JSON_LINE_BYTES: usize = 16 * 1024 * 1024;
const WORKSPACE_REGISTRY_CAPABILITY: &str = "workspace-registry-v1";
pub const GUARDED_BROWSER_POINTER_CAPABILITY: &str = "browser-pointer-frame-guard-v1";
pub const DAEMON_HANDOFF_FORCE_CAPABILITY: &str = "daemon-handoff-force-v1";
pub const VIEWPORT_SPLITS_CAPABILITY: &str = "viewport-splits-v1";
pub const VIEWPORT_COLUMN_RESIZE_CAPABILITY: &str = "viewport-column-resize-v1";
pub const LAYOUT_UNDO_CAPABILITY: &str = "layout-undo-v1";
pub const CLEAR_HISTORY_CAPABILITY: &str = "clear-history-v1";
pub const CLEAR_HISTORY_KEY_CAPABILITY: &str = "clear-history-key-v1";
pub const SURFACE_SUBSCRIBE_FILTER_CAPABILITY: &str = "surface-subscribe-filter";
pub const SESSION_JOURNAL_CAPABILITY: &str = "session-journal-v1";
pub const FRONTEND_JOURNAL_CAPABILITY: &str = "frontend-journal-v1";
/// Journal administration is restricted to the owner-only Unix socket. Use
/// that stable security principal for receipts so a reconnect can safely
/// replay a command instead of creating a second event.
const LOCAL_JOURNAL_PRINCIPAL: &str = "cmux.local-owner";
pub const VIEW_ATTACHMENT_LEASE_CAPABILITY: &str = "view-attachment-lease-v1";
pub const VIEW_ATTACHMENT_DETACH_CAPABILITY: &str = "view-attachment-detach-v1";
pub const CREATION_RECEIPTS_CAPABILITY: &str = "creation-receipts-v1";
pub const CREATION_ATTEMPT_KEYS_CAPABILITY: &str = "creation-attempt-keys-v1";
pub const CREATION_SELECTOR_FALLBACKS_CAPABILITY: &str = "creation-selector-fallbacks-v1";
pub const MAX_CREATION_SELECTOR_FALLBACKS: usize = 7;
pub const PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY: &str =
    "provider-managed-workspace-authority-v2";
pub const BROWSER_PROVIDER_CAPABILITY: &str = "browser-provider-v1";
pub const CLIENT_FOCUS_CAPABILITY: &str = "client-focus-v1";
const INITIAL_BROWSER_RESIZE_TIMEOUT: Duration = Duration::from_secs(10);
pub const STABLE_SPLIT_IDS_PROTOCOL_VERSION: u32 = 8;
pub const STACK_LAYOUT_PROTOCOL_VERSION: u32 = 9;
pub const PER_SURFACE_CLIENT_SIZING_PROTOCOL_VERSION: u32 = 10;
/// Protocol version in which the session journal capability became available.
pub const SESSION_JOURNAL_PROTOCOL_VERSION: u32 = PER_SURFACE_CLIENT_SIZING_PROTOCOL_VERSION;
pub const TERMINAL_LIFECYCLE_PROTOCOL_VERSION: u32 = 11;
pub const LIFECYCLE_READINESS_PROTOCOL_VERSION: u32 = 12;
pub const PROTOCOL_VERSION: u32 = LIFECYCLE_READINESS_PROTOCOL_VERSION;
const PROTOCOL_KEY_TEXT_MAX_BYTES: usize = CLEAR_HISTORY_KEY_TEXT_MAX_BYTES;

fn validate_client_focus_id(client_id: &str) -> anyhow::Result<()> {
    if client_id.is_empty()
        || client_id.len() > 128
        || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        anyhow::bail!("bad request: invalid client_id");
    }
    Ok(())
}

fn advertised_capabilities(bounded_clear_history_fallback_writes: bool) -> Vec<&'static str> {
    let mut capabilities = vec![
        ATTACH_INITIAL_SIZE_CAPABILITY,
        WORKSPACE_REGISTRY_CAPABILITY,
        DAEMON_HANDOFF_FORCE_CAPABILITY,
        GUARDED_BROWSER_POINTER_CAPABILITY,
        VIEWPORT_SPLITS_CAPABILITY,
        VIEWPORT_COLUMN_RESIZE_CAPABILITY,
        LAYOUT_UNDO_CAPABILITY,
        CLEAR_HISTORY_CAPABILITY,
        SURFACE_SUBSCRIBE_FILTER_CAPABILITY,
        SESSION_JOURNAL_CAPABILITY,
        FRONTEND_JOURNAL_CAPABILITY,
        VIEW_ATTACHMENT_LEASE_CAPABILITY,
        VIEW_ATTACHMENT_DETACH_CAPABILITY,
        CREATION_RECEIPTS_CAPABILITY,
        CREATION_ATTEMPT_KEYS_CAPABILITY,
        CREATION_SELECTOR_FALLBACKS_CAPABILITY,
        PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY,
        BROWSER_PROVIDER_CAPABILITY,
        CLIENT_FOCUS_CAPABILITY,
    ];
    if bounded_clear_history_fallback_writes {
        capabilities.push(CLEAR_HISTORY_KEY_CAPABILITY);
    }
    capabilities
}

macro_rules! protocol_keys {
    ($($variant:ident => $constant:ident),+ $(,)?) => {
        #[derive(Debug, Clone, Copy, Deserialize, Serialize)]
        #[serde(rename_all = "kebab-case")]
        enum ProtocolKey {
            $($variant),+
        }

        impl TryFrom<sys::GhosttyKey> for ProtocolKey {
            type Error = anyhow::Error;

            fn try_from(key: sys::GhosttyKey) -> Result<Self, Self::Error> {
                match key {
                    $(sys::$constant => Ok(Self::$variant),)+
                    _ => anyhow::bail!("unsupported terminal key"),
                }
            }
        }

        impl From<ProtocolKey> for sys::GhosttyKey {
            fn from(key: ProtocolKey) -> Self {
                match key {
                    $(ProtocolKey::$variant => sys::$constant),+
                }
            }
        }
    };
}

protocol_keys! {
    Unidentified => GHOSTTY_KEY_UNIDENTIFIED,
    Backquote => GHOSTTY_KEY_BACKQUOTE,
    Backslash => GHOSTTY_KEY_BACKSLASH,
    BracketLeft => GHOSTTY_KEY_BRACKET_LEFT,
    BracketRight => GHOSTTY_KEY_BRACKET_RIGHT,
    Comma => GHOSTTY_KEY_COMMA,
    Digit0 => GHOSTTY_KEY_DIGIT_0,
    Digit1 => GHOSTTY_KEY_DIGIT_1,
    Digit2 => GHOSTTY_KEY_DIGIT_2,
    Digit3 => GHOSTTY_KEY_DIGIT_3,
    Digit4 => GHOSTTY_KEY_DIGIT_4,
    Digit5 => GHOSTTY_KEY_DIGIT_5,
    Digit6 => GHOSTTY_KEY_DIGIT_6,
    Digit7 => GHOSTTY_KEY_DIGIT_7,
    Digit8 => GHOSTTY_KEY_DIGIT_8,
    Digit9 => GHOSTTY_KEY_DIGIT_9,
    Equal => GHOSTTY_KEY_EQUAL,
    A => GHOSTTY_KEY_A,
    B => GHOSTTY_KEY_B,
    C => GHOSTTY_KEY_C,
    D => GHOSTTY_KEY_D,
    E => GHOSTTY_KEY_E,
    F => GHOSTTY_KEY_F,
    G => GHOSTTY_KEY_G,
    H => GHOSTTY_KEY_H,
    I => GHOSTTY_KEY_I,
    J => GHOSTTY_KEY_J,
    K => GHOSTTY_KEY_K,
    L => GHOSTTY_KEY_L,
    M => GHOSTTY_KEY_M,
    N => GHOSTTY_KEY_N,
    O => GHOSTTY_KEY_O,
    P => GHOSTTY_KEY_P,
    Q => GHOSTTY_KEY_Q,
    R => GHOSTTY_KEY_R,
    S => GHOSTTY_KEY_S,
    T => GHOSTTY_KEY_T,
    U => GHOSTTY_KEY_U,
    V => GHOSTTY_KEY_V,
    W => GHOSTTY_KEY_W,
    X => GHOSTTY_KEY_X,
    Y => GHOSTTY_KEY_Y,
    Z => GHOSTTY_KEY_Z,
    Minus => GHOSTTY_KEY_MINUS,
    Period => GHOSTTY_KEY_PERIOD,
    Quote => GHOSTTY_KEY_QUOTE,
    Semicolon => GHOSTTY_KEY_SEMICOLON,
    Slash => GHOSTTY_KEY_SLASH,
    Backspace => GHOSTTY_KEY_BACKSPACE,
    Enter => GHOSTTY_KEY_ENTER,
    Space => GHOSTTY_KEY_SPACE,
    Tab => GHOSTTY_KEY_TAB,
    Delete => GHOSTTY_KEY_DELETE,
    End => GHOSTTY_KEY_END,
    Home => GHOSTTY_KEY_HOME,
    Insert => GHOSTTY_KEY_INSERT,
    PageDown => GHOSTTY_KEY_PAGE_DOWN,
    PageUp => GHOSTTY_KEY_PAGE_UP,
    ArrowDown => GHOSTTY_KEY_ARROW_DOWN,
    ArrowLeft => GHOSTTY_KEY_ARROW_LEFT,
    ArrowRight => GHOSTTY_KEY_ARROW_RIGHT,
    ArrowUp => GHOSTTY_KEY_ARROW_UP,
    Numpad0 => GHOSTTY_KEY_NUMPAD_0,
    Numpad1 => GHOSTTY_KEY_NUMPAD_1,
    Numpad2 => GHOSTTY_KEY_NUMPAD_2,
    Numpad3 => GHOSTTY_KEY_NUMPAD_3,
    Numpad4 => GHOSTTY_KEY_NUMPAD_4,
    Numpad5 => GHOSTTY_KEY_NUMPAD_5,
    Numpad6 => GHOSTTY_KEY_NUMPAD_6,
    Numpad7 => GHOSTTY_KEY_NUMPAD_7,
    Numpad8 => GHOSTTY_KEY_NUMPAD_8,
    Numpad9 => GHOSTTY_KEY_NUMPAD_9,
    NumpadAdd => GHOSTTY_KEY_NUMPAD_ADD,
    NumpadBackspace => GHOSTTY_KEY_NUMPAD_BACKSPACE,
    NumpadComma => GHOSTTY_KEY_NUMPAD_COMMA,
    NumpadDecimal => GHOSTTY_KEY_NUMPAD_DECIMAL,
    NumpadDivide => GHOSTTY_KEY_NUMPAD_DIVIDE,
    NumpadEnter => GHOSTTY_KEY_NUMPAD_ENTER,
    NumpadEqual => GHOSTTY_KEY_NUMPAD_EQUAL,
    NumpadMultiply => GHOSTTY_KEY_NUMPAD_MULTIPLY,
    NumpadSubtract => GHOSTTY_KEY_NUMPAD_SUBTRACT,
    NumpadUp => GHOSTTY_KEY_NUMPAD_UP,
    NumpadDown => GHOSTTY_KEY_NUMPAD_DOWN,
    NumpadRight => GHOSTTY_KEY_NUMPAD_RIGHT,
    NumpadLeft => GHOSTTY_KEY_NUMPAD_LEFT,
    NumpadBegin => GHOSTTY_KEY_NUMPAD_BEGIN,
    NumpadHome => GHOSTTY_KEY_NUMPAD_HOME,
    NumpadEnd => GHOSTTY_KEY_NUMPAD_END,
    NumpadInsert => GHOSTTY_KEY_NUMPAD_INSERT,
    NumpadDelete => GHOSTTY_KEY_NUMPAD_DELETE,
    NumpadPageUp => GHOSTTY_KEY_NUMPAD_PAGE_UP,
    NumpadPageDown => GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
    Escape => GHOSTTY_KEY_ESCAPE,
    F1 => GHOSTTY_KEY_F1,
    F2 => GHOSTTY_KEY_F2,
    F3 => GHOSTTY_KEY_F3,
    F4 => GHOSTTY_KEY_F4,
    F5 => GHOSTTY_KEY_F5,
    F6 => GHOSTTY_KEY_F6,
    F7 => GHOSTTY_KEY_F7,
    F8 => GHOSTTY_KEY_F8,
    F9 => GHOSTTY_KEY_F9,
    F10 => GHOSTTY_KEY_F10,
    F11 => GHOSTTY_KEY_F11,
    F12 => GHOSTTY_KEY_F12,
    F13 => GHOSTTY_KEY_F13,
    F14 => GHOSTTY_KEY_F14,
    F15 => GHOSTTY_KEY_F15,
    F16 => GHOSTTY_KEY_F16,
    F17 => GHOSTTY_KEY_F17,
    F18 => GHOSTTY_KEY_F18,
    F19 => GHOSTTY_KEY_F19,
    F20 => GHOSTTY_KEY_F20,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ProtocolModifiers {
    shift: bool,
    control: bool,
    alt: bool,
    #[serde(rename = "super")]
    super_key: bool,
    caps_lock: bool,
    num_lock: bool,
}

impl ProtocolModifiers {
    fn try_from_ghostty(mods: Mods) -> anyhow::Result<Self> {
        let known = Mods::SHIFT.0
            | Mods::CTRL.0
            | Mods::ALT.0
            | Mods::SUPER.0
            | Mods::CAPS_LOCK.0
            | Mods::NUM_LOCK.0;
        if mods.0 & !known != 0 {
            anyhow::bail!("unsupported terminal modifier bits");
        }
        Ok(Self {
            shift: mods.contains(Mods::SHIFT),
            control: mods.contains(Mods::CTRL),
            alt: mods.contains(Mods::ALT),
            super_key: mods.contains(Mods::SUPER),
            caps_lock: mods.contains(Mods::CAPS_LOCK),
            num_lock: mods.contains(Mods::NUM_LOCK),
        })
    }

    fn into_ghostty(self) -> Mods {
        let mut mods = Mods::default();
        for (enabled, flag) in [
            (self.shift, Mods::SHIFT),
            (self.control, Mods::CTRL),
            (self.alt, Mods::ALT),
            (self.super_key, Mods::SUPER),
            (self.caps_lock, Mods::CAPS_LOCK),
            (self.num_lock, Mods::NUM_LOCK),
        ] {
            if enabled {
                mods = mods | flag;
            }
        }
        mods
    }
}

/// Validated key input carried over the clear-history control protocol for
/// authoritative terminal-mode encoding.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProtocolKeyInput {
    key: ProtocolKey,
    mods: ProtocolModifiers,
    consumed_mods: ProtocolModifiers,
    #[serde(default)]
    composing: bool,
    utf8: String,
    unshifted_codepoint: Option<char>,
    #[serde(default)]
    shifted_codepoint: Option<char>,
    #[serde(default)]
    base_layout_codepoint: Option<char>,
    action: Option<ProtocolKeyAction>,
    macos_option_as_alt: bool,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum ProtocolKeyAction {
    Press,
    Release,
    Repeat,
}

fn validate_protocol_key_text(text: &str) -> anyhow::Result<()> {
    if text.len() > PROTOCOL_KEY_TEXT_MAX_BYTES {
        anyhow::bail!("terminal key text exceeds the 4 KiB protocol limit");
    }
    if text.chars().any(char::is_control) {
        anyhow::bail!("terminal key text contains control characters");
    }
    Ok(())
}

impl TryFrom<&KeyInput> for ProtocolKeyInput {
    type Error = anyhow::Error;

    fn try_from(input: &KeyInput) -> Result<Self, Self::Error> {
        validate_protocol_key_text(&input.utf8)?;
        let unshifted_codepoint = match input.unshifted_codepoint {
            0 => None,
            codepoint => Some(
                char::from_u32(codepoint)
                    .ok_or_else(|| anyhow::anyhow!("invalid unshifted key codepoint"))?,
            ),
        };
        let shifted_codepoint = match input.shifted_codepoint {
            0 => None,
            codepoint => Some(
                char::from_u32(codepoint)
                    .ok_or_else(|| anyhow::anyhow!("invalid shifted key codepoint"))?,
            ),
        };
        let base_layout_codepoint = match input.base_layout_codepoint {
            0 => None,
            codepoint => Some(
                char::from_u32(codepoint)
                    .ok_or_else(|| anyhow::anyhow!("invalid base-layout key codepoint"))?,
            ),
        };
        Ok(Self {
            key: ProtocolKey::try_from(input.key)?,
            mods: ProtocolModifiers::try_from_ghostty(input.mods)?,
            consumed_mods: ProtocolModifiers::try_from_ghostty(input.consumed_mods)?,
            composing: input.composing,
            utf8: input.utf8.clone(),
            unshifted_codepoint,
            shifted_codepoint,
            base_layout_codepoint,
            action: input.action.map(|action| match action {
                KeyAction::Press => ProtocolKeyAction::Press,
                KeyAction::Release => ProtocolKeyAction::Release,
                KeyAction::Repeat => ProtocolKeyAction::Repeat,
            }),
            macos_option_as_alt: input.macos_option_as_alt,
        })
    }
}

impl TryFrom<ProtocolKeyInput> for KeyInput {
    type Error = anyhow::Error;

    fn try_from(input: ProtocolKeyInput) -> Result<Self, Self::Error> {
        validate_protocol_key_text(&input.utf8)?;
        let mods = input.mods.into_ghostty();
        let consumed_mods = input.consumed_mods.into_ghostty();
        if consumed_mods.0 & !mods.0 != 0 {
            anyhow::bail!("consumed terminal modifiers are not active");
        }
        if !input.macos_option_as_alt
            && (!mods.contains(Mods::ALT) || !consumed_mods.contains(Mods::ALT))
        {
            anyhow::bail!("consumed macOS Option requires an active Alt modifier");
        }
        Ok(Self {
            key: input.key.into(),
            mods,
            consumed_mods,
            composing: input.composing,
            utf8: input.utf8,
            unshifted_codepoint: input.unshifted_codepoint.map_or(0, char::into),
            shifted_codepoint: input.shifted_codepoint.map_or(0, char::into),
            base_layout_codepoint: input.base_layout_codepoint.map_or(0, char::into),
            action: input.action.map(|action| match action {
                ProtocolKeyAction::Press => KeyAction::Press,
                ProtocolKeyAction::Release => KeyAction::Release,
                ProtocolKeyAction::Repeat => KeyAction::Repeat,
            }),
            macos_option_as_alt: input.macos_option_as_alt,
        })
    }
}

pub(crate) fn encode_terminal_host_clear_history(
    fallback_key: Option<&KeyInput>,
) -> anyhow::Result<Vec<u8>> {
    let fallback_key = fallback_key.map(ProtocolKeyInput::try_from).transpose()?;
    Ok(serde_json::to_vec(&fallback_key)?)
}

pub(crate) fn decode_terminal_host_clear_history(
    payload: &[u8],
) -> anyhow::Result<Option<KeyInput>> {
    let fallback_key: Option<ProtocolKeyInput> = serde_json::from_slice(payload)?;
    fallback_key.map(KeyInput::try_from).transpose()
}

/// Validate the component used to identify a local session.
///
/// Session names become socket file names. Keep legacy names that are still a
/// single path component, but reject values that can escape the socket root or
/// carry control and line-separator characters.
pub fn validate_session_name(session: &str) -> anyhow::Result<()> {
    let invalid = session.is_empty()
        || matches!(session, "." | "..")
        || session.chars().any(|character| {
            character == '/'
                || character == '\\'
                || character == '\0'
                || character.is_control()
                || matches!(character, '\u{0085}' | '\u{2028}' | '\u{2029}')
        });
    anyhow::ensure!(
        !invalid,
        "session name must be a non-empty path component without separators or control characters"
    );
    Ok(())
}

/// Default socket path for a session.
pub fn default_socket_path(session: &str) -> PathBuf {
    match try_default_socket_path(session) {
        Ok(path) => path,
        Err(_) => invalid_session_socket_path(session),
    }
}

/// Resolve a session socket path and report invalid input before any path use.
pub fn try_default_socket_path(session: &str) -> anyhow::Result<PathBuf> {
    validate_session_name(session)?;
    Ok(default_socket_path_in_runtime_dir(session, platform::runtime_dir()))
}

fn invalid_session_socket_path(session: &str) -> PathBuf {
    let digest = format!("{:x}", Sha256::digest(session.as_bytes()));
    platform::invalid_runtime_dir().join(format!("{digest}.sock"))
}

fn default_socket_path_in_runtime_dir(session: &str, runtime_dir: PathBuf) -> PathBuf {
    let file_name = format!("{session}.sock");
    let preferred = runtime_dir.join(&file_name);
    #[cfg(unix)]
    if !unix_socket_path_fits(&preferred) {
        let fallback = platform::fallback_runtime_dir().join(&file_name);
        if unix_socket_path_fits(&fallback) {
            return fallback;
        }
        let digest = format!("{:x}", Sha256::digest(session.as_bytes()));
        let preferred_base = runtime_dir.parent().unwrap_or_else(|| Path::new("/tmp"));
        let hashed =
            platform::hashed_runtime_dir_for_base(preferred_base).join(format!("{digest}.sock"));
        if unix_socket_path_fits(&hashed) {
            return hashed;
        }
        return platform::fallback_hashed_runtime_dir().join(format!("{digest}.sock"));
    }
    preferred
}

#[cfg(unix)]
fn unix_socket_path_fits(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;

    // Filesystem Unix sockets require a trailing NUL in sun_path, so the
    // encoded pathname itself must be strictly shorter than the field.
    const SUN_PATH_CAPACITY: usize =
        size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
    path.as_os_str().as_bytes().len() < SUN_PATH_CAPACITY
}

#[derive(Deserialize)]
struct Request {
    id: Option<Value>,
    #[serde(flatten)]
    cmd: Command,
}

#[derive(Deserialize)]
struct CreateSurfaceWithReceiptRequest {
    operation: String,
    origin: String,
    /// Stable correlation identity for the logical creation across retries.
    receipt: String,
    /// One execution attempt. Omission preserves the original adapter
    /// behavior by using `receipt` for both identities.
    #[serde(default)]
    idempotency_key: Option<String>,
    /// Stable public identities captured by the frontend before the request
    /// is sent. Numeric targets remain a legacy fallback.
    #[serde(default)]
    selectors: Option<crate::ResourceSelectors>,
    /// Ordered client-local selection continuations used only when the
    /// primary creation target disappeared before the mutation committed.
    #[serde(default)]
    selector_fallbacks: Vec<crate::ResourceSelectors>,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    width: Option<f32>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BrowserProviderTargetRequest {
    tab_id: String,
    target_id: String,
}

#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum Command {
    Identify,
    /// Gracefully hand this daemon's durable session to a replacement.
    /// The caller must fence the request with values from this daemon's
    /// `identify` response.
    ShutdownDaemon {
        pid: u32,
        generation: String,
        #[serde(default)]
        force: bool,
    },
    Ping,
    SetClientInfo {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        kind: Option<String>,
        #[serde(default)]
        capabilities: Option<Vec<String>>,
    },
    ListClients,
    /// Publish the native browser process's live CDP targets. This is an
    /// owner-only, connection-scoped lease and never enters the journal.
    RegisterBrowserProvider {
        provider_id: String,
        endpoint: String,
        authentication: String,
        #[serde(default)]
        bearer_token: Option<String>,
        targets: Vec<BrowserProviderTargetRequest>,
    },
    /// Return the current provider lease for local automation such as
    /// Vercel agent-browser. Remote/WebSocket clients cannot read it.
    GetBrowserProvider,
    UnregisterBrowserProvider,
    /// Canonical non-tombstoned terminal placement/lifecycle snapshot.
    ListTerminals,
    /// Durable ordered terminal mutations after `terminal_revision`.
    TerminalEvents {
        #[serde(default)]
        after_revision: u64,
    },
    SetClientSizing {
        surface: SurfaceId,
        #[serde(default)]
        client: Option<u64>,
        enabled: bool,
        #[serde(default)]
        exclusive: bool,
    },
    PairingResponse {
        request: u64,
        approve: bool,
    },
    DetachClient {
        client: u64,
    },
    ReloadConfig,
    SetWindowTitle {
        title: String,
    },
    ClearWindowTitle,
    ListWorkspaces,
    GetFrontendProjection {
        frontend: String,
        scope: String,
        subject_key: String,
    },
    PutFrontendProjection {
        frontend: String,
        scope: String,
        subject_key: String,
        schema_version: u32,
        #[serde(default)]
        expected_projection_revision: Option<u64>,
        projection: Value,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    JournalFrontendEvent {
        event: crate::FrontendJournalEvent,
    },
    ExportLayout {
        #[serde(default)]
        screen: Option<ScreenId>,
    },
    ApplyLayout {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        name: Option<String>,
        layout: LayoutRequest,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    Send {
        surface: SurfaceId,
        #[serde(default)]
        text: Option<String>,
        /// Base64-encoded raw bytes, written verbatim to the pty.
        #[serde(default)]
        bytes: Option<String>,
        #[serde(default)]
        paste: bool,
    },
    ReadScreen {
        surface: SurfaceId,
    },
    ClearHistory {
        surface: SurfaceId,
        /// Structured key input encoded using the authoritative terminal
        /// modes when the surface is in the alternate screen.
        #[serde(default)]
        fallback_key: Option<ProtocolKeyInput>,
    },
    ReadScrollback {
        surface: SurfaceId,
        start: u32,
        count: u32,
    },
    SidebarPlugin {
        cols: u16,
        rows: u16,
        #[serde(default)]
        relaunch: bool,
    },
    WaitFor {
        surface: SurfaceId,
        pattern: String,
        #[serde(alias = "timeout_ms")]
        timeout_ms: u64,
    },
    Run {
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        new_workspace: bool,
        /// Optional stable key for a newly-created workspace.
        ///
        /// This is rejected unless `new_workspace` is true. Detached and
        /// provider-backed frontends use it to keep workspace identity stable
        /// across display-name changes and reconciliation.
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// Execute one destination-creating TUI action behind a durable receipt.
    /// Repeating the same receipt with identical fields returns the exact
    /// created view, so a lost response can never duplicate or retarget it.
    CreateSurfaceWithReceipt(Box<CreateSurfaceWithReceiptRequest>),
    SendKey {
        surface: SurfaceId,
        keys: Vec<String>,
    },
    Copy {
        surface: SurfaceId,
        mode: String,
    },
    Ids {
        #[serde(default)]
        kind: Option<String>,
    },
    Notify {
        title: String,
        body: String,
        #[serde(default)]
        level: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    ListAgents {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        state: Option<String>,
    },
    ReportAgent {
        surface: SurfaceId,
        state: String,
        source: String,
        #[serde(default)]
        session: Option<String>,
    },
    /// One-shot VT replay of the surface's current state (base64).
    VtState {
        surface: SurfaceId,
    },
    /// Mint a one-use direct renderer credential without exposing the
    /// daemon's durable owner capability.
    MintTerminalRenderer {
        surface: SurfaceId,
        #[serde(default = "default_renderer_capability_ttl_ms")]
        ttl_ms: u64,
    },
    /// Mint a renderer credential from the stable public terminal identity.
    /// Remote clients must not depend on this daemon generation's local
    /// numeric surface handle.
    MintTerminalRendererByTerminal {
        terminal: String,
        #[serde(default = "default_renderer_capability_ttl_ms")]
        ttl_ms: u64,
    },
    /// Resolve a process-stable hosted terminal UUID to this daemon
    /// generation's local surface handle without creating anything.
    ResolveTerminal {
        terminal_id: String,
    },
    /// Close a hosted terminal by stable identity. This is safe across daemon
    /// generations; the incarnation guard prevents a stale close request.
    CloseTerminal {
        terminal_id: String,
        #[serde(default)]
        terminal_incarnation: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// New tab in a pane (default: the active pane).
    NewTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cwd: Option<String>,
        /// Expected content size in cells (spawn-at-size avoids shell
        /// redraw artifacts).
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    NewBrowserTab {
        url: String,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SetCellPixels {
        #[serde(alias = "width_px")]
        width_px: u16,
        #[serde(alias = "height_px")]
        height_px: u16,
    },
    GetCellPixels,
    BrowserFramePresented {
        surface: SurfaceId,
        frame_seq: u64,
    },
    BrowserMouse {
        surface: SurfaceId,
        kind: String,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(default)]
        button: Option<String>,
        #[serde(default, alias = "click_count")]
        click_count: Option<u32>,
        #[serde(default)]
        frame_seq: Option<u64>,
    },
    BrowserMouseGuarded {
        surface: SurfaceId,
        kind: String,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(default)]
        button: Option<String>,
        #[serde(default, alias = "click_count")]
        click_count: Option<u32>,
        frame_seq: u64,
    },
    BrowserWheel {
        surface: SurfaceId,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(alias = "delta_y_px")]
        delta_y_px: f64,
        #[serde(default)]
        frame_seq: Option<u64>,
    },
    BrowserWheelGuarded {
        surface: SurfaceId,
        #[serde(alias = "x_px")]
        x_px: f64,
        #[serde(alias = "y_px")]
        y_px: f64,
        #[serde(alias = "delta_y_px")]
        delta_y_px: f64,
        frame_seq: u64,
    },
    BrowserKey {
        surface: SurfaceId,
        kind: String,
        key: String,
        code: String,
        #[serde(alias = "windows_virtual_key_code")]
        windows_virtual_key_code: u32,
        modifiers: u32,
        #[serde(default)]
        text: Option<String>,
    },
    BrowserKeyPress {
        surface: SurfaceId,
        key: String,
        code: String,
        #[serde(alias = "windows_virtual_key_code")]
        windows_virtual_key_code: u32,
        modifiers: u32,
        #[serde(default)]
        text: Option<String>,
    },
    BrowserInsertText {
        surface: SurfaceId,
        text: String,
    },
    BrowserNavigate {
        surface: SurfaceId,
        url: String,
    },
    BrowserBack {
        surface: SurfaceId,
    },
    BrowserForward {
        surface: SurfaceId,
    },
    BrowserReload {
        surface: SurfaceId,
    },
    BrowserActivate {
        surface: SurfaceId,
    },
    NewWorkspace {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// Create a registry entry without implicitly spawning a terminal.
    CreateWorkspace {
        #[serde(default)]
        name: Option<String>,
        /// Optional frontend-generated stable key. When absent, the mux
        /// generates a UUIDv4 key and returns it.
        #[serde(default)]
        key: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Create a terminal inside an existing workspace selected by stable key
    /// or legacy numeric id.
    CreateTerminal {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(default)]
        argv: Option<Vec<String>>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        /// Optional frontend-reserved canonical UUID. Supplying it with a
        /// mutation id makes a lost-response retry exactly once.
        #[serde(default)]
        terminal_id: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// New screen in a workspace (default: the active one).
    NewScreen {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    NewPane {
        pane: PaneId,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    NewPaneRight {
        pane: PaneId,
        #[serde(default)]
        width: Option<f32>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    Split {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    SetRatio {
        pane: PaneId,
        /// "right" or "down"
        dir: String,
        ratio: f32,
    },
    SetSplitRatio {
        split: SplitId,
        ratio: f32,
        #[serde(default)]
        transaction: Option<u64>,
    },
    SetViewportPaneWidth {
        pane: PaneId,
        width: f32,
        #[serde(default)]
        transaction: Option<u64>,
    },
    UndoLayout {
        pane: PaneId,
        #[serde(default)]
        revision: Option<u64>,
        #[serde(default)]
        confirm_close: bool,
    },
    PaneNeighbor {
        pane: PaneId,
        dir: String,
    },
    FocusDirection {
        #[serde(default)]
        pane: Option<PaneId>,
        dir: String,
    },
    SwapPane {
        pane: PaneId,
        #[serde(default)]
        dir: Option<String>,
        #[serde(default)]
        target: Option<PaneId>,
    },
    ZoomPane {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        mode: Option<String>,
    },
    ProcessInfo {
        surface: SurfaceId,
    },
    MoveTerminal {
        terminal_id: String,
        workspace_key: String,
        #[serde(default)]
        terminal_incarnation: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    MoveTab {
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
    },
    MoveWorkspace {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        index: usize,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    SetDefaultColors {
        #[serde(default)]
        fg: Option<String>,
        #[serde(default)]
        bg: Option<String>,
        #[serde(default)]
        cursor: Option<String>,
        #[serde(default)]
        selection_bg: Option<String>,
        #[serde(default)]
        selection_fg: Option<String>,
        #[serde(default)]
        cursor_style: Option<String>,
        #[serde(default)]
        cursor_blink: Option<bool>,
        #[serde(default)]
        palette: Option<BTreeMap<String, String>>,
        /// Complete frontend configuration replaces absent optional values;
        /// legacy CLI calls retain their historical sparse-overlay behavior.
        #[serde(default)]
        complete: bool,
    },
    /// Close one tab.
    CloseSurface {
        surface: SurfaceId,
    },
    /// Close a pane and all its tabs.
    ClosePane {
        pane: PaneId,
    },
    CloseScreen {
        screen: ScreenId,
    },
    CloseWorkspace {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    /// Verifies that this provider frontend holds the authority provisioned
    /// before the mux accepted control clients.
    MarkWorkspacesProviderManaged {
        authority: String,
    },
    CloseProviderManagedWorkspace {
        workspace: WorkspaceId,
        key: String,
        authority: String,
    },
    RenamePane {
        pane: PaneId,
        /// Empty clears the name (falls back to the tab title).
        name: String,
    },
    RenameSurface {
        surface: SurfaceId,
        /// Empty clears the name (falls back to the generated tab label).
        name: String,
    },
    RenameScreen {
        screen: ScreenId,
        /// Empty clears the name (falls back to the screen number).
        name: String,
    },
    RenameWorkspace {
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        key: Option<String>,
        name: String,
        #[serde(flatten)]
        mutation: MutationRequest,
    },
    RenameProviderManagedWorkspace {
        workspace: WorkspaceId,
        key: String,
        name: String,
        authority: String,
    },
    ResizeSurface {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    /// Resize one negotiated view attachment. The opaque lease prevents a
    /// delayed request from mutating a replacement view or another terminal.
    ResizeAttachedView {
        surface: SurfaceId,
        lease: String,
        cols: u16,
        rows: u16,
    },
    /// Stop this client from contributing a size for a surface while
    /// retaining its attach stream for cached rendering.
    ReleaseSurfaceSize {
        surface: SurfaceId,
    },
    /// Stop one negotiated view attachment from contributing geometry.
    ReleaseAttachedViewSize {
        surface: SurfaceId,
        lease: String,
    },
    /// Close one negotiated view attachment without affecting the terminal or
    /// any other placement or client view.
    DetachAttachedView {
        surface: SurfaceId,
        lease: String,
    },
    FocusPane {
        pane: PaneId,
    },
    /// Select a tab within a pane (default: the active pane).
    SelectTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Select a screen within the active workspace.
    SelectScreen {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    SelectWorkspace {
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
    /// Report one client's focus: applied as the session focus and remembered
    /// per client id so that client's own reconnection restores it.
    ReportFocus {
        client_id: String,
        pane: PaneId,
        #[serde(default)]
        tab: Option<usize>,
    },
    /// The remembered focus for one client, if its pane is still alive.
    ClientFocus {
        client_id: String,
    },
    /// Stream mux events on this connection.
    Subscribe {
        #[serde(default)]
        tree_events: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    /// Stream a surface: vt-state event followed by live output events.
    AttachSurface {
        surface: SurfaceId,
        #[serde(default)]
        mode: Option<String>,
        /// Optional initial viewer size. Supplying this pair makes the attach
        /// stream a sizing participant immediately, before its first frame is
        /// rendered.
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    /// Scroll a surface's viewport by a row delta (negative is up).
    ScrollSurface {
        surface: SurfaceId,
        delta: isize,
    },
}

impl Command {
    fn ordering_surface(&self) -> Option<SurfaceId> {
        match self {
            Self::SetClientSizing { surface, .. }
            | Self::Send { surface, .. }
            | Self::ReadScreen { surface }
            | Self::ClearHistory { surface, .. }
            | Self::ReadScrollback { surface, .. }
            | Self::WaitFor { surface, .. }
            | Self::SendKey { surface, .. }
            | Self::Copy { surface, .. }
            | Self::ReportAgent { surface, .. }
            | Self::VtState { surface }
            | Self::MintTerminalRenderer { surface, .. }
            | Self::BrowserFramePresented { surface, .. }
            | Self::BrowserMouse { surface, .. }
            | Self::BrowserMouseGuarded { surface, .. }
            | Self::BrowserWheel { surface, .. }
            | Self::BrowserWheelGuarded { surface, .. }
            | Self::BrowserKey { surface, .. }
            | Self::BrowserKeyPress { surface, .. }
            | Self::BrowserInsertText { surface, .. }
            | Self::BrowserNavigate { surface, .. }
            | Self::BrowserBack { surface }
            | Self::BrowserForward { surface }
            | Self::BrowserReload { surface }
            | Self::BrowserActivate { surface }
            | Self::ProcessInfo { surface }
            | Self::MoveTab { surface, .. }
            | Self::CloseSurface { surface }
            | Self::RenameSurface { surface, .. }
            | Self::ResizeSurface { surface, .. }
            | Self::ResizeAttachedView { surface, .. }
            | Self::ReleaseSurfaceSize { surface }
            | Self::ReleaseAttachedViewSize { surface, .. }
            | Self::DetachAttachedView { surface, .. }
            | Self::AttachSurface { surface, .. }
            | Self::ScrollSurface { surface, .. } => Some(*surface),
            Self::Notify { surface, .. }
            | Self::ListAgents { surface, .. }
            | Self::Subscribe { surface, .. } => *surface,
            _ => None,
        }
    }

    fn is_clear_history(&self) -> bool {
        matches!(self, Self::ClearHistory { .. })
    }

    fn can_overtake_clear_barrier(&self) -> bool {
        matches!(
            self,
            Self::ClearHistory { .. }
                | Self::Send { .. }
                | Self::SendKey { .. }
                | Self::BrowserFramePresented { .. }
                | Self::BrowserMouse { .. }
                | Self::BrowserMouseGuarded { .. }
                | Self::BrowserWheel { .. }
                | Self::BrowserWheelGuarded { .. }
                | Self::BrowserKey { .. }
                | Self::BrowserKeyPress { .. }
                | Self::BrowserInsertText { .. }
                | Self::BrowserNavigate { .. }
                | Self::BrowserBack { .. }
                | Self::BrowserForward { .. }
                | Self::BrowserReload { .. }
                | Self::BrowserActivate { .. }
                | Self::ScrollSurface { .. }
        )
    }
}

#[derive(Debug, Default, Deserialize)]
struct MutationRequest {
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
    #[serde(default)]
    expected_generation: Option<String>,
    #[serde(default, alias = "expected_terminal_revision")]
    expected_revision: Option<u64>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
enum LayoutRequest {
    Leaf {
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        command: Option<Vec<String>>,
    },
    Split {
        dir: String,
        ratio: f32,
        a: Box<LayoutRequest>,
        b: Box<LayoutRequest>,
    },
    Stack {
        panes: Vec<PaneId>,
        expanded: PaneId,
    },
}

#[derive(Serialize)]
struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_delivery: Option<ResponseErrorDelivery>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "kebab-case")]
enum ResponseErrorDelivery {
    KnownNotDelivered,
    Ambiguous,
}

impl From<ClearHistoryDelivery> for ResponseErrorDelivery {
    fn from(delivery: ClearHistoryDelivery) -> Self {
        match delivery {
            ClearHistoryDelivery::KnownNotDelivered => Self::KnownNotDelivered,
            ClearHistoryDelivery::Ambiguous => Self::Ambiguous,
        }
    }
}

#[derive(Debug)]
struct DeliveryClassifiedError {
    error: anyhow::Error,
    delivery: ResponseErrorDelivery,
}

impl DeliveryClassifiedError {
    fn known_not_delivered(error: anyhow::Error) -> anyhow::Error {
        anyhow::Error::new(Self { error, delivery: ResponseErrorDelivery::KnownNotDelivered })
    }
}

impl From<ClearHistoryFailure> for DeliveryClassifiedError {
    fn from(failure: ClearHistoryFailure) -> Self {
        let delivery = failure.delivery().into();
        Self { error: failure.into_error(), delivery }
    }
}

impl std::fmt::Display for DeliveryClassifiedError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(formatter)
    }
}

impl std::error::Error for DeliveryClassifiedError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.error.source()
    }
}

const STREAM_DISCONNECT_POLL: Duration = Duration::from_millis(100);
const STREAM_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
const SHUTDOWN_ACK_FLUSH_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(not(test))]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(100);
const MAX_SERVER_CONNECTIONS: usize = 64;
const WEBSOCKET_AUTH_MAX_BYTES: usize = 4 * 1024;
const WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES: usize = 4 * 1024 * 1024;
// One outbound render budget chain:
// 10,000,000 decoded image bytes -> 13,333,336 base64 bytes.
// 16,384 maximal placement objects -> 7,962,625 JSON bytes.
// Their 21,295,961-byte subtotal fits a 32 MiB attach message with
// 12,258,471 bytes left for image metadata, rows, and the JSON wrapper.
// Keep the TypeScript SDK and web decoder constants in sync.
const RENDER_GRAPHIC_MAX_DECODED_BYTES: usize = 10_000_000;
const RENDER_GRAPHIC_MAX_ENCODED_BYTES: usize = RENDER_GRAPHIC_MAX_DECODED_BYTES.div_ceil(3) * 4;
const RENDER_GRAPHIC_MAX_PLACEMENTS: usize = 16_384;
const RENDER_GRAPHIC_MAX_PLACEMENT_JSON_BYTES: usize = 485;
const RENDER_GRAPHIC_MAX_PLACEMENT_ARRAY_BYTES: usize = 2
    + RENDER_GRAPHIC_MAX_PLACEMENTS * RENDER_GRAPHIC_MAX_PLACEMENT_JSON_BYTES
    + (RENDER_GRAPHIC_MAX_PLACEMENTS - 1);
const RENDER_ATTACH_MAX_BYTES: usize = crate::REMOTE_SESSION_MESSAGE_MAX_BYTES;
// Share expensive image encoding across render clients without retaining an
// unbounded second copy of terminal pixel state process-wide.
const RENDER_GRAPHIC_BASE64_CACHE_MAX_BYTES: usize = RENDER_GRAPHIC_MAX_ENCODED_BYTES * 2;
const RENDER_GRAPHIC_BASE64_CACHE_MAX_ENTRIES: usize = 4_096;
const _: () = assert!(
    RENDER_GRAPHIC_MAX_ENCODED_BYTES + RENDER_GRAPHIC_MAX_PLACEMENT_ARRAY_BYTES
        < RENDER_ATTACH_MAX_BYTES
);
const OUTBOUND_CAPACITY: usize = 256;
// Browser projection updates are an ordered frame/state pair. Keep one pair
// writable without allowing a slow socket to accumulate an unbounded trail.
const OUTBOUND_BACKPRESSURED_STREAM_CAPACITY: usize = 2;
const OUTBOUND_CONTROL_RESERVE: usize = 256;
const OUTBOUND_BYTE_CAPACITY: usize = RENDER_ATTACH_MAX_BYTES;
// The synchronous `vt-state` command returns the same bounded replay as an
// attach, encoded as base64 inside its response envelope.
const OUTBOUND_CONTROL_BYTE_RESERVE: usize = RENDER_ATTACH_MAX_BYTES;
const OUTBOUND_GLOBAL_BYTE_CAPACITY: usize = OUTBOUND_BYTE_CAPACITY * 4;
const OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY: usize = OUTBOUND_CONTROL_BYTE_RESERVE * 4;
const _: () =
    assert!(crate::surface::VT_REPLAY_MAX_BYTES.div_ceil(3) * 4 < OUTBOUND_CONTROL_BYTE_RESERVE);
const OUTBOUND_CONNECTION_CAPACITY: usize = OUTBOUND_CAPACITY * 16;
const OUTBOUND_CONNECTION_BYTE_CAPACITY: usize = OUTBOUND_BYTE_CAPACITY * 8;
const CLIENT_DETACH_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
const CONNECTION_SURFACE_QUEUE_CAPACITY: usize = 256;
const CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
const CONNECTION_SURFACE_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(3);
const SERVER_SURFACE_WORKER_CAPACITY: usize = 16;
const SERVER_SURFACE_RETAINED_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
const RESOURCE_STREAMS_PER_CLIENT_CAPACITY: usize = 64;
const RESOURCE_STREAMS_SERVER_CAPACITY: usize = 256;
const RESOURCE_WAITS_PER_CLIENT_CAPACITY: usize = 8;
const RESOURCE_WAITS_SERVER_CAPACITY: usize = 64;

#[derive(Default)]
struct ResourceWorkerAdmissionState {
    active: usize,
    active_by_client: HashMap<u64, usize>,
}

struct ResourceWorkerAdmission {
    per_client_capacity: usize,
    server_capacity: usize,
    state: Mutex<ResourceWorkerAdmissionState>,
    changed: Condvar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResourceWorkerAdmissionError {
    ClientCapacity,
    ServerCapacity,
}

#[derive(Clone)]
struct ResourceWorkerPermit {
    _lease: Arc<ResourceWorkerPermitLease>,
}

struct ResourceWorkerPermitLease {
    admission: Arc<ResourceWorkerAdmission>,
    client: u64,
}

impl Drop for ResourceWorkerPermitLease {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap();
        state.active = state.active.saturating_sub(1);
        let remove_client = state.active_by_client.get_mut(&self.client).is_some_and(|active| {
            *active = active.saturating_sub(1);
            *active == 0
        });
        if remove_client {
            state.active_by_client.remove(&self.client);
        }
        self.admission.changed.notify_all();
    }
}

impl ResourceWorkerAdmission {
    fn new(per_client_capacity: usize, server_capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            per_client_capacity,
            server_capacity,
            state: Mutex::new(ResourceWorkerAdmissionState::default()),
            changed: Condvar::new(),
        })
    }

    fn try_reserve(
        self: &Arc<Self>,
        client: u64,
    ) -> Result<ResourceWorkerPermit, ResourceWorkerAdmissionError> {
        let mut state = self.state.lock().unwrap();
        if state.active_by_client.get(&client).copied().unwrap_or_default()
            >= self.per_client_capacity
        {
            return Err(ResourceWorkerAdmissionError::ClientCapacity);
        }
        if state.active >= self.server_capacity {
            return Err(ResourceWorkerAdmissionError::ServerCapacity);
        }
        state.active += 1;
        *state.active_by_client.entry(client).or_default() += 1;
        Ok(ResourceWorkerPermit {
            _lease: Arc::new(ResourceWorkerPermitLease { admission: self.clone(), client }),
        })
    }

    #[cfg(test)]
    fn active(&self) -> usize {
        self.state.lock().unwrap().active
    }

    #[cfg(test)]
    fn wait_until_idle(&self, deadline: Instant) -> bool {
        let mut state = self.state.lock().unwrap();
        while state.active != 0 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if timeout.timed_out() && state.active != 0 {
                return false;
            }
        }
        true
    }
}

#[derive(Default)]
struct ServerSurfaceOperationState {
    workers: usize,
    retained_bytes: usize,
}

#[derive(Default)]
pub(crate) struct ServerSurfaceOperationAdmission {
    state: Mutex<ServerSurfaceOperationState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServerSurfaceAdmissionError {
    RetainedByteCapacity,
}

struct ServerSurfaceWorkerPermit {
    admission: Arc<ServerSurfaceOperationAdmission>,
}

impl Drop for ServerSurfaceWorkerPermit {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap();
        state.workers = state.workers.saturating_sub(1);
    }
}

struct ServerSurfaceBytesPermit {
    admission: Arc<ServerSurfaceOperationAdmission>,
    retained_bytes: usize,
}

impl Drop for ServerSurfaceBytesPermit {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().unwrap();
        state.retained_bytes = state.retained_bytes.saturating_sub(self.retained_bytes);
    }
}

impl ServerSurfaceOperationAdmission {
    fn try_reserve_worker(self: &Arc<Self>) -> Option<ServerSurfaceWorkerPermit> {
        let mut state = self.state.lock().unwrap();
        if state.workers >= SERVER_SURFACE_WORKER_CAPACITY {
            return None;
        }
        state.workers += 1;
        Some(ServerSurfaceWorkerPermit { admission: self.clone() })
    }

    fn try_reserve_bytes(
        self: &Arc<Self>,
        retained_bytes: usize,
    ) -> Result<ServerSurfaceBytesPermit, ServerSurfaceAdmissionError> {
        let mut state = self.state.lock().unwrap();
        if retained_bytes
            > SERVER_SURFACE_RETAINED_BYTE_CAPACITY.saturating_sub(state.retained_bytes)
        {
            return Err(ServerSurfaceAdmissionError::RetainedByteCapacity);
        }
        state.retained_bytes += retained_bytes;
        Ok(ServerSurfaceBytesPermit { admission: self.clone(), retained_bytes })
    }
}

struct PendingSurfaceRequest {
    request: Request,
    retained_bytes: usize,
    _bytes_permit: ServerSurfaceBytesPermit,
}

#[derive(Default)]
struct ConnectionSurfaceState {
    requests: VecDeque<PendingSurfaceRequest>,
    queued_bytes: usize,
    active_clear_surfaces: HashSet<SurfaceId>,
    dispatcher_started: bool,
    dispatcher_done: bool,
    closed: bool,
}

struct ConnectionSurfaceScheduler {
    state: Mutex<ConnectionSurfaceState>,
    changed: Condvar,
    admission: Arc<ServerSurfaceOperationAdmission>,
    cancelled: AtomicBool,
    dispatcher: Mutex<Option<JoinHandle<()>>>,
    connection_permit: Mutex<Option<ConnectionPermit>>,
}

impl Default for ConnectionSurfaceScheduler {
    fn default() -> Self {
        Self::new(Arc::new(ServerSurfaceOperationAdmission::default()))
    }
}

impl ConnectionSurfaceScheduler {
    fn new(admission: Arc<ServerSurfaceOperationAdmission>) -> Self {
        Self::new_inner(admission, None)
    }

    #[cfg(test)]
    fn new_with_connection_permit(
        admission: Arc<ServerSurfaceOperationAdmission>,
        permit: ConnectionPermit,
    ) -> Self {
        Self::new_inner(admission, Some(permit))
    }

    fn new_inner(
        admission: Arc<ServerSurfaceOperationAdmission>,
        connection_permit: Option<ConnectionPermit>,
    ) -> Self {
        Self {
            state: Mutex::new(ConnectionSurfaceState::default()),
            changed: Condvar::new(),
            admission,
            cancelled: AtomicBool::new(false),
            dispatcher: Mutex::new(None),
            connection_permit: Mutex::new(connection_permit),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct RenderGraphicCacheKey {
    data_ptr: usize,
    data_len: usize,
}

struct RenderGraphicCacheEntry {
    source: Weak<[u8]>,
    encoded: Arc<str>,
}

struct RenderGraphicBase64Cache {
    entries: HashMap<RenderGraphicCacheKey, RenderGraphicCacheEntry>,
    insertion_order: VecDeque<RenderGraphicCacheKey>,
    retained_bytes: usize,
    max_bytes: usize,
    max_entries: usize,
}

impl RenderGraphicBase64Cache {
    fn new(max_bytes: usize, max_entries: usize) -> Self {
        Self {
            entries: HashMap::new(),
            insertion_order: VecDeque::new(),
            retained_bytes: 0,
            max_bytes,
            max_entries,
        }
    }

    fn encode(&mut self, data: &Arc<[u8]>) -> Arc<str> {
        let key = RenderGraphicCacheKey { data_ptr: data.as_ptr() as usize, data_len: data.len() };
        if let Some(entry) = self.entries.get(&key)
            && entry.source.upgrade().is_some_and(|source| Arc::ptr_eq(&source, data))
        {
            return entry.encoded.clone();
        }
        if let Some(stale) = self.entries.remove(&key) {
            self.retained_bytes = self.retained_bytes.saturating_sub(stale.encoded.len());
            self.insertion_order.retain(|candidate| *candidate != key);
        }

        // Serialize while holding the cache lock. Competing render clients
        // wait for this one bounded encode instead of allocating duplicates.
        let encoded: Arc<str> =
            Arc::from(base64::engine::general_purpose::STANDARD.encode(data.as_ref()));
        if encoded.len() > self.max_bytes || self.max_entries == 0 {
            return encoded;
        }
        while self.entries.len() >= self.max_entries
            || encoded.len() > self.max_bytes.saturating_sub(self.retained_bytes)
        {
            let Some(oldest) = self.insertion_order.pop_front() else {
                break;
            };
            if let Some(evicted) = self.entries.remove(&oldest) {
                self.retained_bytes = self.retained_bytes.saturating_sub(evicted.encoded.len());
            }
        }
        self.retained_bytes += encoded.len();
        self.insertion_order.push_back(key);
        self.entries.insert(
            key,
            RenderGraphicCacheEntry { source: Arc::downgrade(data), encoded: encoded.clone() },
        );
        encoded
    }
}

struct OutboundByteBudget {
    retained_bytes: AtomicUsize,
    max_bytes: usize,
}

impl OutboundByteBudget {
    fn new(max_bytes: usize) -> Self {
        Self { retained_bytes: AtomicUsize::new(0), max_bytes }
    }

    fn try_retain(&self, bytes: usize) -> bool {
        self.retained_bytes
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |retained| {
                retained.checked_add(bytes).filter(|next| *next <= self.max_bytes)
            })
            .is_ok()
    }

    fn release(&self, bytes: usize) {
        let previous = self.retained_bytes.fetch_sub(bytes, Ordering::AcqRel);
        debug_assert!(previous >= bytes, "outbound byte budget underflow");
    }
}

struct BudgetedText {
    text: String,
    retained_bytes: usize,
    budget: Arc<OutboundByteBudget>,
}

impl Deref for BudgetedText {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        &self.text
    }
}

impl Drop for BudgetedText {
    fn drop(&mut self) {
        self.budget.release(self.retained_bytes);
    }
}

struct BudgetedJsonWriter {
    bytes: Vec<u8>,
    // Total quota charged while this writer is alive. A reserved writer
    // starts with logical quota but grows its Vec only as bytes are written.
    retained_bytes: usize,
    reservation_bytes: usize,
    budget: Arc<OutboundByteBudget>,
}

impl BudgetedJsonWriter {
    fn new(budget: Arc<OutboundByteBudget>) -> Self {
        Self { bytes: Vec::new(), retained_bytes: 0, reservation_bytes: 0, budget }
    }

    fn with_reservation(
        budget: Arc<OutboundByteBudget>,
        reserved_bytes: usize,
    ) -> std::io::Result<Self> {
        let mut writer = Self::new(budget);
        if !writer.budget.try_retain(reserved_bytes) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "global outbound byte budget overflowed",
            ));
        }
        writer.retained_bytes = reserved_bytes;
        writer.reservation_bytes = reserved_bytes;
        Ok(writer)
    }

    fn ensure_capacity(&mut self, required_len: usize) -> std::io::Result<()> {
        if required_len <= self.bytes.capacity() {
            return Ok(());
        }
        let target = required_len.checked_next_power_of_two().unwrap_or(required_len).max(8);
        let previous_retained = self.retained_bytes;
        let target_retained = target.max(self.reservation_bytes);
        let additional_retained = target_retained.saturating_sub(previous_retained);
        if additional_retained > 0 && !self.budget.try_retain(additional_retained) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "global outbound byte budget overflowed",
            ));
        }
        self.retained_bytes = target_retained;
        if let Err(error) = self.bytes.try_reserve_exact(target.saturating_sub(self.bytes.len())) {
            self.retained_bytes = previous_retained;
            if additional_retained > 0 {
                self.budget.release(additional_retained);
            }
            return Err(std::io::Error::other(error));
        }
        let actual_capacity = self.bytes.capacity();
        let actual_retained = actual_capacity.max(self.reservation_bytes);
        if actual_retained > self.retained_bytes {
            let additional = actual_retained - self.retained_bytes;
            if !self.budget.try_retain(additional) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "global outbound byte budget overflowed",
                ));
            }
            self.retained_bytes = actual_retained;
        } else if actual_retained < self.retained_bytes {
            let unused = self.retained_bytes - actual_retained;
            self.retained_bytes = actual_retained;
            self.budget.release(unused);
        }
        Ok(())
    }

    fn finish(mut self) -> Arc<BudgetedText> {
        let bytes = std::mem::take(&mut self.bytes);
        let retained_bytes = bytes.capacity();
        debug_assert!(retained_bytes <= self.retained_bytes);
        if retained_bytes < self.retained_bytes {
            self.budget.release(self.retained_bytes - retained_bytes);
        }
        self.retained_bytes = 0;
        self.reservation_bytes = 0;
        let text = String::from_utf8(bytes).expect("serde_json emits UTF-8");
        Arc::new(BudgetedText { text, retained_bytes, budget: self.budget.clone() })
    }
}

impl Write for BudgetedJsonWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let required_len = self.bytes.len().checked_add(bytes.len()).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "serialized message is too large")
        })?;
        self.ensure_capacity(required_len)?;
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for BudgetedJsonWriter {
    fn drop(&mut self) {
        if self.retained_bytes > 0 {
            self.budget.release(self.retained_bytes);
        }
    }
}

struct RenderService {
    graphic_base64: Mutex<RenderGraphicBase64Cache>,
    outbound_budget: Arc<OutboundByteBudget>,
    control_budget: Arc<OutboundByteBudget>,
}

impl RenderService {
    fn new() -> Self {
        Self::new_with_outbound_budgets(
            OUTBOUND_GLOBAL_BYTE_CAPACITY,
            OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY,
        )
    }

    #[cfg(test)]
    fn new_with_outbound_budget(max_bytes: usize) -> Self {
        Self::new_with_outbound_budgets(max_bytes, OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY)
    }

    fn new_with_outbound_budgets(max_bytes: usize, control_max_bytes: usize) -> Self {
        Self {
            graphic_base64: Mutex::new(RenderGraphicBase64Cache::new(
                RENDER_GRAPHIC_BASE64_CACHE_MAX_BYTES,
                RENDER_GRAPHIC_BASE64_CACHE_MAX_ENTRIES,
            )),
            outbound_budget: Arc::new(OutboundByteBudget::new(max_bytes)),
            control_budget: Arc::new(OutboundByteBudget::new(control_max_bytes)),
        }
    }

    fn encode_graphic(&self, data: &Arc<[u8]>) -> Arc<str> {
        self.graphic_base64.lock().unwrap().encode(data)
    }

    fn serialize<T: Serialize + ?Sized>(&self, value: &T) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::new(self.outbound_budget.clone());
        serde_json::to_writer(&mut writer, value).map_err(json_error_to_io)?;
        Ok(writer.finish())
    }

    fn serialize_control<T: Serialize + ?Sized>(
        &self,
        value: &T,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::new(self.control_budget.clone());
        serde_json::to_writer(&mut writer, value).map_err(json_error_to_io)?;
        Ok(writer.finish())
    }

    fn serialize_vt_state(&self, value: &VtStateMessage) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::new(self.outbound_budget.clone());
        write!(
            writer,
            "{{\"event\":\"vt-state\",\"surface\":{},\"cols\":{},\"rows\":{},\"data\":\"",
            value.surface, value.cols, value.rows
        )?;
        {
            let mut encoder = base64::write::EncoderWriter::new(
                &mut writer,
                &base64::engine::general_purpose::STANDARD,
            );
            encoder.write_all(&value.replay)?;
            encoder.finish()?;
        }
        writer.write_all(b"\",\"kitty_image_aliases\":")?;
        write_kitty_image_aliases_json(&mut writer, &value.kitty_image_aliases)?;
        writer.write_all(b",\"kitty_graphics_state\":")?;
        write_kitty_replay_state_json(&mut writer, value.kitty_state)?;
        writer.write_all(b",\"colors\":")?;
        serde_json::to_writer(&mut writer, &value.colors).map_err(json_error_to_io)?;
        writer.write_all(b"}")?;
        Ok(writer.finish())
    }

    fn serialize_attach_frame(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::new(self.outbound_budget.clone());
        match frame {
            AttachFrame::Output(output) => {
                write!(writer, "{{\"event\":\"output\",\"surface\":{surface},\"data\":\"")?;
                write_base64_json_string(&mut writer, output)?;
                writer.write_all(b"\"}")?;
            }
            AttachFrame::OutputWithColors { output, colors } => {
                write!(writer, "{{\"event\":\"output\",\"surface\":{surface},\"data\":\"")?;
                write_base64_json_string(&mut writer, output)?;
                writer.write_all(b"\",\"colors\":")?;
                serde_json::to_writer(&mut writer, &terminal_colors_json(**colors))
                    .map_err(json_error_to_io)?;
                writer.write_all(b"}")?;
            }
            AttachFrame::Resized { cols, rows, replay, kitty_image_aliases, kitty_state } => {
                write!(
                    writer,
                    "{{\"event\":\"resized\",\"surface\":{surface},\"cols\":{cols},\"rows\":{rows},\"replay\":\""
                )?;
                write_base64_json_string(&mut writer, replay)?;
                writer.write_all(b"\",\"kitty_image_aliases\":")?;
                write_kitty_image_aliases_json(&mut writer, kitty_image_aliases)?;
                writer.write_all(b",\"kitty_graphics_state\":")?;
                write_kitty_replay_state_json(&mut writer, *kitty_state)?;
                writer.write_all(b"}")?;
            }
            AttachFrame::ResizedWithColors {
                cols,
                rows,
                replay,
                kitty_image_aliases,
                kitty_state,
                colors,
            } => {
                write!(
                    writer,
                    "{{\"event\":\"resized\",\"surface\":{surface},\"cols\":{cols},\"rows\":{rows},\"replay\":\""
                )?;
                write_base64_json_string(&mut writer, replay)?;
                writer.write_all(b"\",\"kitty_image_aliases\":")?;
                write_kitty_image_aliases_json(&mut writer, kitty_image_aliases)?;
                writer.write_all(b",\"kitty_graphics_state\":")?;
                write_kitty_replay_state_json(&mut writer, *kitty_state)?;
                writer.write_all(b",\"colors\":")?;
                serde_json::to_writer(&mut writer, &terminal_colors_json(**colors))
                    .map_err(json_error_to_io)?;
                writer.write_all(b"}")?;
            }
            AttachFrame::ColorsChanged(colors) => {
                let mut value = terminal_colors_json(**colors);
                value["event"] = json!("colors-changed");
                value["surface"] = json!(surface);
                serde_json::to_writer(&mut writer, &value).map_err(json_error_to_io)?;
            }
        }
        Ok(writer.finish())
    }

    fn reserved_control_writer(&self) -> std::io::Result<BudgetedJsonWriter> {
        BudgetedJsonWriter::with_reservation(
            self.control_budget.clone(),
            OUTBOUND_CONTROL_BYTE_RESERVE,
        )
    }
}

fn json_error_to_io(error: serde_json::Error) -> std::io::Error {
    std::io::Error::new(error.io_error_kind().unwrap_or(std::io::ErrorKind::InvalidData), error)
}

fn write_base64_json_string(writer: &mut BudgetedJsonWriter, bytes: &[u8]) -> std::io::Result<()> {
    let mut encoder =
        base64::write::EncoderWriter::new(writer, &base64::engine::general_purpose::STANDARD);
    encoder.write_all(bytes)?;
    encoder.finish().map(|_| ())
}

fn write_kitty_image_aliases_json(
    writer: &mut BudgetedJsonWriter,
    aliases: &[ghostty_vt::KittyImageAlias],
) -> std::io::Result<()> {
    writer.write_all(b"[")?;
    for (index, alias) in aliases.iter().enumerate() {
        if index != 0 {
            writer.write_all(b",")?;
        }
        write!(
            writer,
            "{{\"image_id\":{},\"image_number\":{}}}",
            alias.image_id, alias.image_number
        )?;
    }
    writer.write_all(b"]")
}

fn write_kitty_replay_state_json(
    writer: &mut BudgetedJsonWriter,
    state: KittyReplayState,
) -> std::io::Result<()> {
    write!(
        writer,
        concat!(
            "{{\"image_bytes\":{},\"inflight_bytes\":{},\"images\":{},\"placements\":{},",
            "\"replay_cursor_offset\":{},",
            "\"primary_replay_next_image_id\":{},\"primary_next_image_id\":{},",
            "\"alternate_replay_next_image_id\":{},\"alternate_next_image_id\":{}}}"
        ),
        state.limits.image_bytes,
        state.limits.inflight_bytes,
        state.limits.images,
        state.limits.placements,
        state.replay_cursor_offset,
        state.replay_next_image_ids.primary,
        state.next_image_ids.primary,
        state.replay_next_image_ids.alternate,
        state.next_image_ids.alternate,
    )
}

#[derive(Clone)]
struct OutboundStream {
    id: u64,
    open: Arc<AtomicBool>,
    terminal_enqueued: Arc<AtomicBool>,
    overflow_text: Arc<Mutex<Arc<BudgetedText>>>,
}

impl OutboundStream {
    fn new(id: u64, overflow_text: Arc<BudgetedText>) -> Self {
        Self {
            id,
            open: Arc::new(AtomicBool::new(true)),
            terminal_enqueued: Arc::new(AtomicBool::new(false)),
            overflow_text: Arc::new(Mutex::new(overflow_text)),
        }
    }

    fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }

    fn close(&self) {
        self.open.store(false, Ordering::Release);
    }

    fn update_overflow(&self, text: Arc<BudgetedText>) {
        *self.overflow_text.lock().unwrap() = text;
    }
}

trait MessageSink: Send + Sync {
    fn send_initial(&self, text: Arc<BudgetedText>, stream: &OutboundStream)
    -> std::io::Result<()>;
    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()>;
    fn send_stream_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.send_stream(text, stream)
    }
    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()>;
    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()>;
    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()>;
    fn set_write_timeout(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
        Ok(())
    }
    fn flush_control(&self, _timeout: Duration) -> std::io::Result<()> {
        Ok(())
    }
    fn is_open(&self) -> bool;
    fn close(&self);
    fn abort(&self) {
        self.close();
    }
    fn close_after_control(&self) {
        self.close();
    }
}

/// Transport-independent writer shared by command responses and event streams.
#[derive(Clone)]
struct MessageWriter {
    sink: Arc<dyn MessageSink>,
    open: Arc<AtomicBool>,
    next_stream_id: Arc<AtomicU64>,
    render_service: Arc<RenderService>,
    wait_wakeups: Arc<Mutex<Vec<Weak<ResourceWaitWake>>>>,
}

impl MessageWriter {
    #[cfg(test)]
    fn new(sink: impl MessageSink + 'static) -> Self {
        Self::new_with_render_service(sink, Arc::new(RenderService::new()))
    }

    fn new_with_render_service(
        sink: impl MessageSink + 'static,
        render_service: Arc<RenderService>,
    ) -> Self {
        Self {
            sink: Arc::new(sink),
            open: Arc::new(AtomicBool::new(true)),
            next_stream_id: Arc::new(AtomicU64::new(1)),
            render_service,
            wait_wakeups: Arc::new(Mutex::new(Vec::new())),
        }
    }

    fn start_stream(&self, overflow: &Value) -> std::io::Result<OutboundStream> {
        Ok(OutboundStream::new(
            self.next_stream_id.fetch_add(1, Ordering::Relaxed),
            self.render_service.serialize_control(overflow)?,
        ))
    }

    fn update_stream_overflow(
        &self,
        stream: &OutboundStream,
        overflow: &Value,
    ) -> std::io::Result<()> {
        stream.update_overflow(self.render_service.serialize_control(overflow)?);
        Ok(())
    }

    #[cfg(test)]
    fn send_stream<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize(value)
            .and_then(|text| self.sink.send_stream(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    /// Send an ordered state stream without mistaking a healthy slow client
    /// for a disconnected one. Its source must retain or coalesce updates
    /// while this call waits for the socket writer to accept the prior item.
    fn send_stream_backpressured<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize(value)
            .and_then(|text| self.sink.send_stream_backpressured(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_initial<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize(value)
            .and_then(|text| self.sink.send_initial(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_initial_vt_state(
        &self,
        value: &VtStateMessage,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_vt_state(value)
            .and_then(|text| self.sink.send_initial(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_attach_frame_backpressured(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_attach_frame(surface, frame)
            .and_then(|text| self.sink.send_stream_backpressured(text, stream));
        if result.as_ref().is_err_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
            stream.close();
        }
        result
    }

    fn send_terminal<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_control(value)
            .and_then(|text| self.sink.send_terminal(text, stream));
        if result.is_err() {
            self.close();
        }
        result
    }

    fn send_ordered_terminal<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_control(value)
            .and_then(|text| self.sink.send_ordered_terminal(text, stream));
        if result.is_err() {
            self.close();
        }
        result
    }

    fn send_control<T: Serialize + ?Sized>(&self, value: &T) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self
            .render_service
            .serialize_control(value)
            .and_then(|text| self.sink.send_control(text));
        if result.is_err() {
            self.close();
        }
        result
    }

    fn send_serialized_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.send_control(text);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire) && self.sink.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.sink.set_write_timeout(timeout)
    }

    fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        if !self.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let result = self.sink.flush_control(timeout);
        if result.is_err() {
            self.abort();
        }
        result
    }

    fn register_wait_wakeup(&self, wake: &Arc<ResourceWaitWake>) {
        let mut wakeups = self.wait_wakeups.lock().unwrap();
        wakeups.retain(|registered| registered.strong_count() > 0);
        if self.is_open() {
            wakeups.push(Arc::downgrade(wake));
        } else {
            drop(wakeups);
            wake.notify();
        }
    }

    fn close_with(&self, preserve_control: bool) {
        if self.open.swap(false, Ordering::AcqRel) {
            let wakeups = std::mem::take(&mut *self.wait_wakeups.lock().unwrap());
            for wake in wakeups.into_iter().filter_map(|wake| wake.upgrade()) {
                wake.notify();
            }
            if preserve_control {
                self.sink.close_after_control();
            } else {
                self.sink.close();
            }
        }
    }

    fn abort(&self) {
        if self.open.swap(false, Ordering::AcqRel) {
            let wakeups = std::mem::take(&mut *self.wait_wakeups.lock().unwrap());
            for wake in wakeups.into_iter().filter_map(|wake| wake.upgrade()) {
                wake.notify();
            }
        }
        self.sink.abort();
    }

    fn close_after_control(&self) {
        self.close_with(true);
    }

    fn close(&self) {
        self.close_with(false);
    }
}

impl ConnectionSurfaceScheduler {
    fn dispatch(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        request: &mut Option<Request>,
        retained_bytes: usize,
        writer: MessageWriter,
    ) -> Option<bool> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Some(false);
        }
        let is_clear_history = request.as_ref().unwrap().cmd.is_clear_history();
        let over_count = state.requests.len() >= CONNECTION_SURFACE_QUEUE_CAPACITY;
        let over_bytes = retained_bytes
            > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(state.queued_bytes);
        if over_count || over_bytes {
            drop(state);
            return Some(send_request_error_with_delivery(
                &writer,
                request.take().unwrap().id,
                "surface request queue is full; request was not executed",
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        let request_id = request.as_ref().unwrap().id.clone();
        let bytes_permit = match self.admission.try_reserve_bytes(retained_bytes) {
            Ok(bytes) => bytes,
            Err(ServerSurfaceAdmissionError::RetainedByteCapacity) => {
                drop(state);
                let request_id = request.take().unwrap().id;
                return Some(if is_clear_history {
                    send_request_error_with_delivery(
                        &writer,
                        request_id,
                        "server surface-operation byte budget is full; request was not executed",
                        Some(ResponseErrorDelivery::KnownNotDelivered),
                    )
                } else {
                    send_request_error(
                        &writer,
                        request_id,
                        "server surface-operation byte budget is full; request was not executed",
                    )
                });
            }
        };
        let start_dispatcher = !state.dispatcher_started;
        state.dispatcher_started = true;
        state.queued_bytes = state.queued_bytes.saturating_add(retained_bytes);
        state.requests.push_back(PendingSurfaceRequest {
            request: request.take().unwrap(),
            retained_bytes,
            _bytes_permit: bytes_permit,
        });
        self.changed.notify_all();
        drop(state);

        if start_dispatcher && let Err(error) = self.start_dispatcher(mux, client, writer.clone()) {
            self.finish_dispatcher();
            self.close();
            return Some(send_request_error_with_delivery(
                &writer,
                request_id,
                &format!("could not start connection request dispatcher: {error}"),
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        Some(true)
    }

    fn start_dispatcher(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        writer: MessageWriter,
    ) -> std::io::Result<()> {
        let scheduler = self.clone();
        let handle = std::thread::Builder::new()
            .name("mux-control-dispatch".into())
            .spawn(move || run_connection_surface_dispatcher(scheduler, mux, client, writer))?;
        *self.dispatcher.lock().unwrap() = Some(handle);
        Ok(())
    }

    fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        if state.active_clear_surfaces.is_empty() {
            return (!state.requests.is_empty()).then_some(0);
        }
        for (index, pending) in state.requests.iter().enumerate() {
            let surface = pending.request.cmd.ordering_surface()?;
            if state.active_clear_surfaces.contains(&surface) {
                continue;
            }
            if pending.request.cmd.can_overtake_clear_barrier() {
                return Some(index);
            }
            return None;
        }
        None
    }

    fn next_request(&self) -> Option<PendingSurfaceRequest> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(index) = Self::next_runnable_index(&state) {
                let pending = state.requests.remove(index).unwrap();
                state.queued_bytes = state.queued_bytes.saturating_sub(pending.retained_bytes);
                if pending.request.cmd.is_clear_history() {
                    let surface = pending
                        .request
                        .cmd
                        .ordering_surface()
                        .expect("clear-history is ordered by surface");
                    let inserted = state.active_clear_surfaces.insert(surface);
                    assert!(inserted, "a clear worker cannot overlap its surface");
                }
                return Some(pending);
            }
            if state.closed && state.requests.is_empty() {
                state.dispatcher_done = true;
                self.changed.notify_all();
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    fn finish_clear(&self, surface: SurfaceId) {
        let mut state = self.state.lock().unwrap();
        state.active_clear_surfaces.remove(&surface);
        self.changed.notify_all();
    }

    fn finish_dispatcher(&self) {
        {
            let mut state = self.state.lock().unwrap();
            state.dispatcher_done = true;
            self.changed.notify_all();
        }
        self.connection_permit.lock().unwrap().take();
    }

    fn close(&self) {
        self.cancelled.store(true, Ordering::Release);
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.requests.clear();
        state.queued_bytes = 0;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().unwrap().take();
        }
    }

    fn finish(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().unwrap().take();
        }
    }

    fn wait_for_completion(&self, timeout: Option<Duration>) -> bool {
        let deadline = timeout.map(|timeout| Instant::now() + timeout);
        let mut state = self.state.lock().unwrap();
        while !state.dispatcher_done || !state.active_clear_surfaces.is_empty() {
            if let Some(deadline) = deadline {
                if Instant::now() >= deadline {
                    break;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) = self.changed.wait_timeout(state, remaining).unwrap();
                state = next;
            } else {
                state = self.changed.wait(state).unwrap();
            }
        }
        let drained = state.dispatcher_done && state.active_clear_surfaces.is_empty();
        drop(state);
        if drained && let Some(dispatcher) = self.dispatcher.lock().unwrap().take() {
            let _ = dispatcher.join();
        }
        drained
    }

    fn finish_and_wait(&self) {
        self.finish();
        let drained = self.wait_for_completion(None);
        debug_assert!(drained, "unbounded graceful drain must settle");
    }

    fn close_and_wait(&self, timeout: Duration) -> bool {
        self.close();
        self.wait_for_completion(Some(timeout))
    }
}

struct ActiveClearGuard {
    scheduler: Arc<ConnectionSurfaceScheduler>,
    surface: SurfaceId,
}

impl Drop for ActiveClearGuard {
    fn drop(&mut self) {
        self.scheduler.finish_clear(self.surface);
    }
}

struct ConnectionDispatcherGuard(Arc<ConnectionSurfaceScheduler>);

impl Drop for ConnectionDispatcherGuard {
    fn drop(&mut self) {
        self.0.finish_dispatcher();
    }
}

fn run_pending_request(
    scheduler: &ConnectionSurfaceScheduler,
    mux: &Arc<Mux>,
    client: u64,
    pending: PendingSurfaceRequest,
    writer: &MessageWriter,
) -> bool {
    let PendingSurfaceRequest { request, _bytes_permit, .. } = pending;
    handle_request_with_cancellation(mux, client, request, writer, Some(&scheduler.cancelled))
}

fn run_connection_surface_dispatcher(
    scheduler: Arc<ConnectionSurfaceScheduler>,
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
) {
    let _dispatcher = ConnectionDispatcherGuard(scheduler.clone());
    while writer.is_open() {
        let Some(pending) = scheduler.next_request() else { return };
        if pending.request.cmd.is_clear_history() {
            let surface = pending
                .request
                .cmd
                .ordering_surface()
                .expect("clear-history is ordered by surface");
            let Some(worker_permit) = scheduler.admission.try_reserve_worker() else {
                let id = pending.request.id.clone();
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &writer,
                    id,
                    "too many clear-history operations are already in progress",
                    Some(ResponseErrorDelivery::KnownNotDelivered),
                ) {
                    scheduler.close();
                    return;
                }
                continue;
            };
            let shared_pending = Arc::new(Mutex::new(Some(pending)));
            let worker_pending = shared_pending.clone();
            let worker_scheduler = scheduler.clone();
            let worker_mux = mux.clone();
            let worker_writer = writer.clone();
            let spawn =
                std::thread::Builder::new().name("mux-surface-control".into()).spawn(move || {
                    let _active = ActiveClearGuard { scheduler: worker_scheduler.clone(), surface };
                    // Drop the mux-wide permit before `_active` wakes the next
                    // request queued behind this surface barrier.
                    let _worker_permit = worker_permit;
                    let pending = worker_pending.lock().unwrap().take().unwrap();
                    if !run_pending_request(
                        &worker_scheduler,
                        &worker_mux,
                        client,
                        pending,
                        &worker_writer,
                    ) {
                        worker_scheduler.close();
                    }
                });
            if let Err(error) = spawn {
                let pending = shared_pending.lock().unwrap().take().unwrap();
                let id = pending.request.id.clone();
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &writer,
                    id,
                    &format!("could not start clear-history worker: {error}"),
                    Some(ResponseErrorDelivery::KnownNotDelivered),
                ) {
                    scheduler.close();
                    return;
                }
            }
        } else if !run_pending_request(&scheduler, &mux, client, pending, &writer) {
            scheduler.close();
            return;
        }
    }
    scheduler.close();
}

#[derive(Default)]
struct BoundedOutbound {
    state: Mutex<BoundedOutboundState>,
    changed: Condvar,
}

#[derive(Default)]
struct BoundedOutboundState {
    initial: VecDeque<RegularOutbound>,
    control: VecDeque<ControlOutbound>,
    regular: VecDeque<RegularOutbound>,
    stream_usage: HashMap<u64, StreamOutboundUsage>,
    control_messages: usize,
    control_bytes: usize,
    regular_bytes: usize,
    closed: bool,
}

struct StreamOutboundUsage {
    messages: usize,
    bytes: usize,
    stream: OutboundStream,
}

struct RegularOutbound {
    text: Arc<BudgetedText>,
    stream: OutboundStream,
}

enum ControlOutbound {
    Text(Arc<BudgetedText>),
    Flush(std::sync::mpsc::SyncSender<()>),
}

enum OutboundItem {
    Text(Arc<BudgetedText>),
    Flush(std::sync::mpsc::SyncSender<()>),
}

#[derive(Clone)]
struct ConnectionPermit {
    _lease: Arc<ConnectionPermitLease>,
}

struct ConnectionPermitLease(Arc<AtomicU64>);

impl Drop for ConnectionPermitLease {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn claim_connection(active: &Arc<AtomicU64>) -> Option<ConnectionPermit> {
    active
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_SERVER_CONNECTIONS as u64).then_some(count + 1)
        })
        .ok()
        .map(|_| ConnectionPermit { _lease: Arc::new(ConnectionPermitLease(active.clone())) })
}

impl BoundedOutbound {
    fn push_regular(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, false)
    }

    fn push_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.push_regular_with_priority(text, stream, true)
    }

    fn push_regular_with_priority(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        let result = Self::push_regular_locked(&mut state, text, stream, initial);
        drop(state);
        self.changed.notify_all();
        result
    }

    fn push_regular_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        loop {
            if state.closed {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "connection closed",
                ));
            }
            if !stream.is_open() {
                return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
            }
            let pending =
                state.stream_usage.get(&stream.id).map(|usage| usage.messages).unwrap_or_default();
            if pending < OUTBOUND_BACKPRESSURED_STREAM_CAPACITY {
                let result = Self::push_regular_locked(&mut state, text, stream, false);
                drop(state);
                self.changed.notify_all();
                return result;
            }
            let (next, _) = self.changed.wait_timeout(state, STREAM_DISCONNECT_POLL).unwrap();
            state = next;
        }
    }

    fn push_regular_locked(
        state: &mut BoundedOutboundState,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
        initial: bool,
    ) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if !stream.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
        }
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            Self::terminate_stream_locked(state, stream)?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound queue overflowed",
            ));
        }
        let (stream_messages, stream_bytes) = state
            .stream_usage
            .get(&stream.id)
            .map(|usage| (usage.messages, usage.bytes))
            .unwrap_or_default();
        if stream_messages >= OUTBOUND_CAPACITY
            || bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(stream_bytes)
        {
            Self::terminate_stream_locked(state, stream)?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound stream queue overflowed",
            ));
        }
        loop {
            let byte_full =
                bytes > OUTBOUND_CONNECTION_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            let count_full =
                state.initial.len() + state.regular.len() >= OUTBOUND_CONNECTION_CAPACITY;
            if !byte_full && !count_full {
                break;
            }
            let Some(victim) = Self::largest_stream(state, byte_full) else {
                Self::terminate_stream_locked(state, stream)?;
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            };
            let incoming_terminated = victim.id == stream.id;
            Self::terminate_stream_locked(state, &victim)?;
            if incoming_terminated {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            }
        }
        state.regular_bytes += bytes;
        let usage = state.stream_usage.entry(stream.id).or_insert_with(|| StreamOutboundUsage {
            messages: 0,
            bytes: 0,
            stream: stream.clone(),
        });
        usage.messages += 1;
        usage.bytes += bytes;
        let message = RegularOutbound { text, stream: stream.clone() };
        if initial {
            state.initial.push_back(message);
        } else {
            state.regular.push_back(message);
        }
        Ok(())
    }

    fn push_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        let (flushed_tx, flushed_rx) = std::sync::mpsc::sync_channel(1);
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        state.control.push_back(ControlOutbound::Flush(flushed_tx));
        drop(state);
        self.changed.notify_one();
        match flushed_rx.recv_timeout(timeout) {
            Ok(()) => Ok(()),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "timed out while flushing the shutdown response",
            )),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "connection closed while flushing the shutdown response",
            )),
        }
    }

    fn push_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        stream.close();
        Self::purge_stream_locked(&mut state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        Self::push_control_locked(&mut state, text)?;
        self.changed.notify_one();
        Ok(())
    }

    /// Gracefully closes a stream after every item already admitted for it.
    ///
    /// Overflow and cancellation use `push_terminal`, which intentionally
    /// purges stale items. Successful bounded replay must preserve FIFO order.
    fn push_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound stream terminal exceeds its byte capacity",
            ));
        }
        let mut state = self.state.lock().unwrap();
        loop {
            if state.closed {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "connection closed",
                ));
            }
            if stream.terminal_enqueued.load(Ordering::Acquire) {
                return Ok(());
            }
            if !stream.is_open() {
                return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
            }
            let (stream_messages, stream_bytes) = state
                .stream_usage
                .get(&stream.id)
                .map(|usage| (usage.messages, usage.bytes))
                .unwrap_or_default();
            let stream_full = stream_messages >= OUTBOUND_CAPACITY
                || bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(stream_bytes);
            let connection_full = state.initial.len() + state.regular.len()
                >= OUTBOUND_CONNECTION_CAPACITY
                || bytes > OUTBOUND_CONNECTION_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            if !stream_full && !connection_full {
                state.regular_bytes += bytes;
                let usage = state.stream_usage.entry(stream.id).or_insert_with(|| {
                    StreamOutboundUsage { messages: 0, bytes: 0, stream: stream.clone() }
                });
                usage.messages += 1;
                usage.bytes += bytes;
                state.regular.push_back(RegularOutbound { text, stream: stream.clone() });
                stream.terminal_enqueued.store(true, Ordering::Release);
                stream.close();
                drop(state);
                self.changed.notify_all();
                return Ok(());
            }
            let (next, _) = self.changed.wait_timeout(state, STREAM_DISCONNECT_POLL).unwrap();
            state = next;
        }
    }

    fn terminate_stream_locked(
        state: &mut BoundedOutboundState,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        stream.close();
        Self::purge_stream_locked(state, stream.id);
        if stream.terminal_enqueued.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let overflow_text = stream.overflow_text.lock().unwrap().clone();
        if let Err(error) = Self::push_control_locked(state, overflow_text) {
            state.closed = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                format!("could not report stream overflow: {error}"),
            ));
        }
        Ok(())
    }

    fn purge_stream_locked(state: &mut BoundedOutboundState, stream_id: u64) {
        state.initial.retain(|message| message.stream.id != stream_id);
        state.regular.retain(|message| message.stream.id != stream_id);
        if let Some(usage) = state.stream_usage.remove(&stream_id) {
            state.regular_bytes = state.regular_bytes.saturating_sub(usage.bytes);
        }
    }

    fn largest_stream(state: &BoundedOutboundState, by_bytes: bool) -> Option<OutboundStream> {
        state
            .stream_usage
            .values()
            .filter(|usage| !usage.stream.terminal_enqueued.load(Ordering::Acquire))
            .max_by_key(|usage| if by_bytes { usage.bytes } else { usage.messages })
            .map(|usage| usage.stream.clone())
    }

    fn push_control_locked(
        state: &mut BoundedOutboundState,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        let bytes = text.len();
        if state.control_messages >= OUTBOUND_CONTROL_RESERVE
            || bytes > OUTBOUND_CONTROL_BYTE_RESERVE.saturating_sub(state.control_bytes)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound control reserve overflowed",
            ));
        }
        state.control_messages += 1;
        state.control_bytes += bytes;
        state.control.push_back(ControlOutbound::Text(text));
        Ok(())
    }

    #[cfg(test)]
    fn try_pop(&self) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        loop {
            match Self::pop_locked(&mut state) {
                Some(OutboundItem::Text(text)) => {
                    drop(state);
                    self.changed.notify_all();
                    return Some(text.to_string());
                }
                Some(OutboundItem::Flush(flushed)) => {
                    drop(state);
                    self.changed.notify_all();
                    let _ = flushed.send(());
                    state = self.state.lock().unwrap();
                }
                None => return None,
            }
        }
    }

    fn recv(&self) -> Option<OutboundItem> {
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(item) = Self::pop_locked(&mut state) {
                drop(state);
                self.changed.notify_all();
                return Some(item);
            }
            if state.closed {
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    fn pop_locked(state: &mut BoundedOutboundState) -> Option<OutboundItem> {
        if let Some(message) = state.initial.pop_front() {
            Self::record_stream_pop(state, &message);
            return Some(OutboundItem::Text(message.text));
        }
        if let Some(control) = state.control.pop_front() {
            return Some(match control {
                ControlOutbound::Text(text) => {
                    state.control_messages = state.control_messages.saturating_sub(1);
                    state.control_bytes = state.control_bytes.saturating_sub(text.len());
                    OutboundItem::Text(text)
                }
                ControlOutbound::Flush(flushed) => OutboundItem::Flush(flushed),
            });
        }
        let message = state.regular.pop_front()?;
        Self::record_stream_pop(state, &message);
        Some(OutboundItem::Text(message.text))
    }

    fn record_stream_pop(state: &mut BoundedOutboundState, message: &RegularOutbound) {
        let bytes = message.text.len();
        state.regular_bytes = state.regular_bytes.saturating_sub(bytes);
        let remove = state.stream_usage.get_mut(&message.stream.id).is_some_and(|usage| {
            usage.messages = usage.messages.saturating_sub(1);
            usage.bytes = usage.bytes.saturating_sub(bytes);
            usage.messages == 0
        });
        if remove {
            state.stream_usage.remove(&message.stream.id);
        }
    }

    fn is_open(&self) -> bool {
        !self.state.lock().unwrap().closed
    }

    fn close(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        state.control.retain(|item| matches!(item, ControlOutbound::Text(_)));
        drop(state);
        self.changed.notify_all();
    }

    fn abort(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        for usage in state.stream_usage.values() {
            usage.stream.close();
        }
        state.initial.clear();
        state.control.clear();
        state.regular.clear();
        state.stream_usage.clear();
        state.control_messages = 0;
        state.control_bytes = 0;
        state.regular_bytes = 0;
        drop(state);
        self.changed.notify_all();
    }

    fn close_after_control(&self) {
        let mut state = self.state.lock().unwrap();
        for usage in state.stream_usage.values() {
            usage.stream.close();
        }
        state.initial.clear();
        state.regular.clear();
        state.stream_usage.clear();
        state.regular_bytes = 0;
        state.closed = true;
        drop(state);
        self.changed.notify_all();
    }
}

fn write_line_outbound_item<W: Write + ?Sized>(
    writer: &mut W,
    item: OutboundItem,
) -> std::io::Result<()> {
    match item {
        OutboundItem::Text(text) => {
            writer.write_all(text.as_bytes())?;
            writer.write_all(b"\n")
        }
        OutboundItem::Flush(flushed) => {
            writer.flush()?;
            let _ = flushed.send(());
            Ok(())
        }
    }
}

struct QueuedSink {
    outbound: Arc<BoundedOutbound>,
    control: Option<SinkControl>,
}

enum SinkControl {
    Unix(Box<dyn transport::Stream>),
    WebSocket(TcpStream),
}

/// Cloned TCP streams share one write boundary so independent Tungstenite
/// reader and writer contexts cannot interleave frame bytes. Reads remain
/// fully blocking and are interrupted by shutting down a clone.
struct SynchronizedTcpStream {
    stream: TcpStream,
    write_lock: Arc<Mutex<()>>,
}

impl SynchronizedTcpStream {
    fn new(stream: TcpStream) -> Self {
        Self { stream, write_lock: Arc::new(Mutex::new(())) }
    }

    fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self { stream: self.stream.try_clone()?, write_lock: self.write_lock.clone() })
    }

    fn try_clone_raw(&self) -> std::io::Result<TcpStream> {
        self.stream.try_clone()
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }

    fn write_websocket_text(&mut self, text: &str) -> std::io::Result<()> {
        if text.len() > RENDER_ATTACH_MAX_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "WebSocket outbound message exceeds the protocol limit",
            ));
        }
        self.write_websocket_frame(0x1, text.as_bytes())
    }

    fn write_websocket_close(&mut self) -> std::io::Result<()> {
        self.write_websocket_frame(0x8, &[])
    }

    fn write_websocket_frame(&mut self, opcode: u8, payload: &[u8]) -> std::io::Result<()> {
        let (header, header_len) = websocket_server_frame_header(opcode, payload.len());
        let _guard = self.write_lock.lock().unwrap();
        self.stream.write_all(&header[..header_len])?;
        self.stream.write_all(payload)?;
        self.stream.flush()
    }
}

fn websocket_server_frame_header(opcode: u8, payload_len: usize) -> ([u8; 10], usize) {
    let mut header = [0_u8; 10];
    header[0] = 0x80 | (opcode & 0x0f);
    match payload_len {
        0..=125 => {
            header[1] = payload_len as u8;
            (header, 2)
        }
        126..=65_535 => {
            header[1] = 126;
            header[2..4].copy_from_slice(&(payload_len as u16).to_be_bytes());
            (header, 4)
        }
        _ => {
            header[1] = 127;
            header[2..10].copy_from_slice(&(payload_len as u64).to_be_bytes());
            (header, 10)
        }
    }
}

impl Read for SynchronizedTcpStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Write for SynchronizedTcpStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _guard = self.write_lock.lock().unwrap();
        self.stream.flush()
    }
}

impl SinkControl {
    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.set_write_timeout(timeout),
            Self::WebSocket(stream) => stream.set_write_timeout(timeout),
        }
    }

    fn shutdown(&self) -> std::io::Result<()> {
        match self {
            Self::Unix(stream) => stream.shutdown(Shutdown::Both),
            Self::WebSocket(stream) => stream.shutdown(Shutdown::Both),
        }
    }
}

impl MessageSink for QueuedSink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.outbound.push_regular(text, stream)
    }

    fn send_stream_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_regular_backpressured(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        self.outbound.push_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.outbound.push_ordered_terminal(text, stream)
    }

    fn is_open(&self) -> bool {
        self.outbound.is_open()
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.control.as_ref().map_or(Ok(()), |control| control.set_write_timeout(timeout))
    }

    fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        self.control.as_ref().map_or(Ok(()), |_| self.outbound.flush_control(timeout))
    }

    fn close(&self) {
        self.outbound.close();
    }

    fn abort(&self) {
        self.outbound.abort();
        if let Some(control) = &self.control {
            let _ = control.shutdown();
        }
    }

    fn close_after_control(&self) {
        self.outbound.close_after_control();
    }
}

/// First-attach announcement payload: (transport, name, kind).
type ClientAnnouncement = (String, Option<String>, Option<String>);
/// Size-report update payload: (changed, name, kind, previous size).
pub(crate) type ClientSizeUpdate = (bool, Option<String>, Option<String>, Option<(u16, u16)>);
const RETIRED_VIEW_LEASE_CAPACITY: usize = 1024;

#[derive(Clone, Copy)]
enum ClientTransport {
    Unix,
    WebSocket,
}

impl ClientTransport {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unix => "unix",
            Self::WebSocket => "ws",
        }
    }
}

#[derive(Default)]
struct AttachedSurface {
    streams: BTreeMap<u64, OutboundStream>,
    pending_streams: BTreeMap<u64, OutboundStream>,
    size_rollbacks: BTreeMap<u64, crate::mux::ClientSizeRollback>,
    size: Option<(u16, u16)>,
    committed_size: Option<(u16, u16)>,
    current_report_order: Option<u64>,
    lease_by_stream: BTreeMap<u64, String>,
    view_sizes: HashMap<String, Option<(u16, u16)>>,
    geometry_lease: Option<String>,
}

struct DetachedSurface {
    final_stream: bool,
    rollback: Option<crate::mux::ClientSizeRollback>,
    geometry_replacement: Option<Option<(u16, u16)>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ViewLeaseStatus {
    Current { geometry_owner: bool },
    Superseded,
}

enum ViewResizePreparation {
    GeometryOwner { update: ClientSizeUpdate, previous_view_size: Option<(u16, u16)> },
    Passive { changed: bool, name: Option<String>, kind: Option<String> },
    Superseded,
}

enum ViewReleasePreparation {
    GeometryOwner { changed: bool, name: Option<String>, kind: Option<String> },
    Passive,
    Superseded,
}

fn mint_view_lease() -> anyhow::Result<String> {
    let mut bytes = [0_u8; 24];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("could not mint view attachment lease: {error}"))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

struct ResourceClientStream {
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
}

impl Drop for ResourceClientStream {
    fn drop(&mut self) {
        self.canceled.store(true, Ordering::Release);
        self.outbound.close();
    }
}

struct ResourceClientWait {
    canceled: Arc<ResourceWaitCancellation>,
    _worker_permit: ResourceWorkerPermit,
}

impl Drop for ResourceClientWait {
    fn drop(&mut self) {
        self.canceled.cancel();
    }
}

#[derive(Default)]
struct ResourceWaitCancellation {
    canceled: AtomicBool,
    wakeups: Mutex<Vec<Weak<ResourceWaitWake>>>,
    lifecycle: Mutex<ResourceWaitLifecycleState>,
    lifecycle_changed: Condvar,
}

#[derive(Default)]
struct ResourceWaitLifecycleState {
    completion_started: bool,
    response_attempted: bool,
    worker_finished: bool,
}

impl ResourceWaitCancellation {
    fn is_canceled(&self) -> bool {
        self.canceled.load(Ordering::Acquire)
    }

    fn register(&self, wake: &Arc<ResourceWaitWake>) {
        let mut wakeups = self.wakeups.lock().unwrap();
        wakeups.retain(|registered| registered.strong_count() > 0);
        if self.is_canceled() {
            drop(wakeups);
            wake.notify();
        } else {
            wakeups.push(Arc::downgrade(wake));
        }
    }

    fn cancel(&self) {
        if self.canceled.swap(true, Ordering::AcqRel) {
            return;
        }
        let wakeups = std::mem::take(&mut *self.wakeups.lock().unwrap());
        for wake in wakeups.into_iter().filter_map(|wake| wake.upgrade()) {
            wake.notify();
        }
    }

    fn begin_completion(&self) -> bool {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        if self.is_canceled() || lifecycle.completion_started {
            return false;
        }
        lifecycle.completion_started = true;
        true
    }

    fn completion_started(&self) -> bool {
        self.lifecycle.lock().unwrap().completion_started
    }

    fn mark_response_attempted(&self) {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        lifecycle.response_attempted = true;
        self.lifecycle_changed.notify_all();
    }

    fn wait_for_response_attempt(&self) -> bool {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        while !lifecycle.response_attempted && !lifecycle.worker_finished {
            lifecycle = self.lifecycle_changed.wait(lifecycle).unwrap();
        }
        lifecycle.response_attempted
    }

    fn mark_worker_finished(&self) {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        lifecycle.worker_finished = true;
        self.lifecycle_changed.notify_all();
    }

    fn wait_for_worker_finish(&self) {
        let mut lifecycle = self.lifecycle.lock().unwrap();
        while !lifecycle.worker_finished {
            lifecycle = self.lifecycle_changed.wait(lifecycle).unwrap();
        }
    }
}

enum ResourceWaitCancel {
    Missing,
    Canceled(Arc<ResourceWaitCancellation>),
    Completing(Arc<ResourceWaitCancellation>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResourceStreamInstallError {
    UnknownClient,
    Duplicate,
    ClientCapacity,
    ServerCapacity,
}

impl From<ResourceWorkerAdmissionError> for ResourceStreamInstallError {
    fn from(error: ResourceWorkerAdmissionError) -> Self {
        match error {
            ResourceWorkerAdmissionError::ClientCapacity => Self::ClientCapacity,
            ResourceWorkerAdmissionError::ServerCapacity => Self::ServerCapacity,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResourceWaitInstallError {
    UnknownClient,
    Duplicate,
    ClientCapacity,
    ServerCapacity,
}

impl From<ResourceWorkerAdmissionError> for ResourceWaitInstallError {
    fn from(error: ResourceWorkerAdmissionError) -> Self {
        match error {
            ResourceWorkerAdmissionError::ClientCapacity => Self::ClientCapacity,
            ResourceWorkerAdmissionError::ServerCapacity => Self::ServerCapacity,
        }
    }
}

struct ClientRecord {
    transport: ClientTransport,
    connected_at: Instant,
    name: Option<String>,
    kind: Option<String>,
    capabilities: HashSet<String>,
    browser_pointer_owner: Option<BrowserPointerOwner>,
    attached: BTreeMap<SurfaceId, AttachedSurface>,
    view_leases: HashMap<String, (SurfaceId, u64)>,
    retired_view_leases: HashMap<String, SurfaceId>,
    retired_view_lease_order: VecDeque<String>,
    retired_surfaces: HashSet<SurfaceId>,
    retired_surface_order: VecDeque<SurfaceId>,
    resource_streams: HashMap<String, ResourceClientStream>,
    resource_waits: HashMap<ResourceRequestId, ResourceClientWait>,
    announced_attached: bool,
    writer: MessageWriter,
}

#[derive(Clone)]
struct ResourceClientRecord {
    client: u64,
    transport: &'static str,
    connected_seconds: u64,
    name: Option<String>,
    kind: Option<String>,
    attached: Vec<(SurfaceId, Option<(u16, u16)>)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DaemonHandoffReservation {
    Pending(u64),
    Committed(u64),
}

#[derive(Default)]
struct ClientRegistryState {
    clients: BTreeMap<u64, ClientRecord>,
    attached_by_surface: HashMap<SurfaceId, HashSet<u64>>,
    /// Shares the registry lock with registration so accepting a handoff and
    /// admitting a new owner cannot pass each other.
    daemon_handoff: Option<DaemonHandoffReservation>,
}

pub(crate) struct ClientRegistry {
    next_id: AtomicU64,
    resource_stream_admission: Arc<ResourceWorkerAdmission>,
    resource_wait_admission: Arc<ResourceWorkerAdmission>,
    state: Mutex<ClientRegistryState>,
}

impl ClientRegistry {
    pub(crate) fn new() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            resource_stream_admission: ResourceWorkerAdmission::new(
                RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
                RESOURCE_STREAMS_SERVER_CAPACITY,
            ),
            resource_wait_admission: ResourceWorkerAdmission::new(
                RESOURCE_WAITS_PER_CLIENT_CAPACITY,
                RESOURCE_WAITS_SERVER_CAPACITY,
            ),
            state: Mutex::new(ClientRegistryState::default()),
        }
    }

    fn register(&self, transport: ClientTransport, writer: MessageWriter) -> u64 {
        let client = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut state = self.state.lock().unwrap();
        if state.daemon_handoff.is_some() {
            drop(state);
            writer.close();
            return client;
        }
        state.clients.insert(
            client,
            ClientRecord {
                transport,
                connected_at: Instant::now(),
                name: None,
                kind: None,
                capabilities: HashSet::new(),
                browser_pointer_owner: None,
                attached: BTreeMap::new(),
                view_leases: HashMap::new(),
                retired_view_leases: HashMap::new(),
                retired_view_lease_order: VecDeque::new(),
                retired_surfaces: HashSet::new(),
                retired_surface_order: VecDeque::new(),
                resource_streams: HashMap::new(),
                resource_waits: HashMap::new(),
                announced_attached: false,
                writer,
            },
        );
        client
    }

    fn client_ids(&self) -> Vec<u64> {
        self.state.lock().unwrap().clients.keys().copied().collect()
    }

    #[cfg(test)]
    fn daemon_handoff_pending(&self) -> bool {
        self.state.lock().unwrap().daemon_handoff.is_some()
    }

    fn is_unix(&self, client: u64) -> bool {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .is_some_and(|record| matches!(record.transport, ClientTransport::Unix))
    }

    fn install_resource_stream(
        &self,
        client: u64,
        stream_id: &StreamPublicId,
        outbound: OutboundStream,
    ) -> Result<(Arc<AtomicBool>, ResourceWorkerPermit), ResourceStreamInstallError> {
        let mut state = self.state.lock().unwrap();
        let record =
            state.clients.get_mut(&client).ok_or(ResourceStreamInstallError::UnknownClient)?;
        if record.resource_streams.contains_key(stream_id.as_str()) {
            return Err(ResourceStreamInstallError::Duplicate);
        }
        let worker_permit = self.resource_stream_admission.try_reserve(client)?;
        let canceled = Arc::new(AtomicBool::new(false));
        record.resource_streams.insert(
            stream_id.to_string(),
            ResourceClientStream {
                outbound,
                canceled: canceled.clone(),
                _worker_permit: worker_permit.clone(),
            },
        );
        Ok((canceled, worker_permit))
    }

    fn take_resource_stream(
        &self,
        client: u64,
        stream_id: &StreamPublicId,
    ) -> Option<ResourceClientStream> {
        self.state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)?
            .resource_streams
            .remove(stream_id.as_str())
    }

    fn finish_resource_stream(&self, client: u64, stream_id: &StreamPublicId, outbound_id: u64) {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else { return };
        if record
            .resource_streams
            .get(stream_id.as_str())
            .is_some_and(|stream| stream.outbound.id == outbound_id)
        {
            record.resource_streams.remove(stream_id.as_str());
        }
    }

    fn install_resource_wait(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
    ) -> Result<(Arc<ResourceWaitCancellation>, ResourceWorkerPermit), ResourceWaitInstallError>
    {
        let mut state = self.state.lock().unwrap();
        let record =
            state.clients.get_mut(&client).ok_or(ResourceWaitInstallError::UnknownClient)?;
        if record.resource_waits.contains_key(request_id) {
            return Err(ResourceWaitInstallError::Duplicate);
        }
        let worker_permit = self.resource_wait_admission.try_reserve(client)?;
        let canceled = Arc::new(ResourceWaitCancellation::default());
        record.resource_waits.insert(
            request_id.clone(),
            ResourceClientWait {
                canceled: canceled.clone(),
                _worker_permit: worker_permit.clone(),
            },
        );
        Ok((canceled, worker_permit))
    }

    /// Atomically claim completion for one exact request registration.
    ///
    /// The cancellation identity check prevents an old worker from removing a
    /// replacement that reused the same public request id after cancellation.
    fn begin_resource_wait_completion(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
        canceled: &Arc<ResourceWaitCancellation>,
    ) -> bool {
        let state = self.state.lock().unwrap();
        let Some(record) = state.clients.get(&client) else { return false };
        record
            .resource_waits
            .get(request_id)
            .filter(|wait| Arc::ptr_eq(&wait.canceled, canceled))
            .is_some_and(|_| canceled.begin_completion())
    }

    fn finish_resource_wait(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
        canceled: &Arc<ResourceWaitCancellation>,
    ) -> bool {
        let removed = {
            let mut state = self.state.lock().unwrap();
            let Some(record) = state.clients.get_mut(&client) else { return false };
            if record
                .resource_waits
                .get(request_id)
                .is_some_and(|wait| Arc::ptr_eq(&wait.canceled, canceled))
            {
                record.resource_waits.remove(request_id)
            } else {
                None
            }
        };
        removed.is_some()
    }

    /// Remove and wake a detached wait by its public request id. Removal is
    /// the cancellation linearization point, so repeated and late requests
    /// return false and a worker that lost this race cannot send a response.
    fn cancel_resource_wait(
        &self,
        client: u64,
        request_id: &ResourceRequestId,
    ) -> ResourceWaitCancel {
        {
            let mut state = self.state.lock().unwrap();
            let Some(record) = state.clients.get_mut(&client) else {
                return ResourceWaitCancel::Missing;
            };
            let Some(wait) = record.resource_waits.get(request_id) else {
                return ResourceWaitCancel::Missing;
            };
            if wait.canceled.completion_started() {
                ResourceWaitCancel::Completing(wait.canceled.clone())
            } else {
                let canceled = wait.canceled.clone();
                record.resource_waits.remove(request_id);
                ResourceWaitCancel::Canceled(canceled)
            }
        }
    }

    fn set_info(
        &self,
        client: u64,
        name: Option<String>,
        kind: Option<String>,
        capabilities: Option<Vec<String>>,
    ) -> anyhow::Result<(Option<String>, Option<String>)> {
        let mut state = self.state.lock().unwrap();
        if kind.as_deref() == Some("native-browser") && state.daemon_handoff.is_some() {
            anyhow::bail!("daemon handoff is already in progress");
        }
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some(name) = name {
            record.name = Some(clamp_client_label(name));
        }
        if let Some(kind) = kind {
            record.kind = Some(clamp_client_label(kind));
        }
        if let Some(capabilities) = capabilities {
            record.capabilities.extend(capabilities.into_iter().filter(|capability| {
                capability == GUARDED_BROWSER_POINTER_CAPABILITY
                    || capability == VIEW_ATTACHMENT_LEASE_CAPABILITY
                    || capability == VIEW_ATTACHMENT_DETACH_CAPABILITY
                    || capability == CREATION_RECEIPTS_CAPABILITY
                    || capability == CREATION_ATTEMPT_KEYS_CAPABILITY
                    || capability == CREATION_SELECTOR_FALLBACKS_CAPABILITY
            }));
        }
        Ok((record.name.clone(), record.kind.clone()))
    }

    fn set_resource_info(
        &self,
        client: u64,
        name: Option<Option<String>>,
        kind: Option<Option<String>>,
    ) -> Result<(Option<String>, Option<String>), ResourceError> {
        let name = name.map(|name| validate_resource_client_label("name", name)).transpose()?;
        let kind = kind.map(|kind| validate_resource_client_label("kind", kind)).transpose()?;
        let mut state = self.state.lock().unwrap();
        if kind.as_ref().and_then(|kind| kind.as_deref()) == Some("native-browser")
            && state.daemon_handoff.is_some()
        {
            return Err(ResourceError::operation_failed(
                "client.metadata.update",
                "daemon handoff is already in progress",
                json!({}),
            ));
        }
        let record = state.clients.get_mut(&client).ok_or_else(|| {
            ResourceError::operation_failed(
                "client.metadata.update",
                format!("unknown client {client}"),
                json!({}),
            )
        })?;
        if let Some(name) = name {
            record.name = name;
        }
        if let Some(kind) = kind {
            record.kind = kind;
        }
        Ok((record.name.clone(), record.kind.clone()))
    }

    fn resource_records(&self) -> Vec<ResourceClientRecord> {
        self.state
            .lock()
            .unwrap()
            .clients
            .iter()
            .map(|(client, record)| ResourceClientRecord {
                client: *client,
                transport: match record.transport {
                    ClientTransport::Unix => "unix",
                    ClientTransport::WebSocket => "websocket",
                },
                connected_seconds: record.connected_at.elapsed().as_secs(),
                name: record.name.clone(),
                kind: record.kind.clone(),
                attached: record
                    .attached
                    .iter()
                    .filter_map(|(surface, attached)| {
                        (!attached.streams.is_empty())
                            .then_some((*surface, attached.committed_size))
                    })
                    .collect(),
            })
            .collect()
    }

    fn supports_capability(&self, client: u64, capability: &str) -> bool {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .is_some_and(|record| record.capabilities.contains(capability))
    }

    fn surface_attachment_is_current_or_retired(&self, client: u64, surface: SurfaceId) -> bool {
        self.state.lock().unwrap().clients.get(&client).is_some_and(|record| {
            record.attached.contains_key(&surface) || record.retired_surfaces.contains(&surface)
        })
    }

    pub(crate) fn surface_attachment_is_retired_without_current(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> bool {
        self.state.lock().unwrap().clients.get(&client).is_some_and(|record| {
            !record.attached.contains_key(&surface) && record.retired_surfaces.contains(&surface)
        })
    }

    fn browser_pointer_owner(&self, client: u64) -> anyhow::Result<BrowserPointerOwner> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some(owner) = record.browser_pointer_owner {
            return Ok(owner);
        }
        let owner = if record.capabilities.contains(GUARDED_BROWSER_POINTER_CAPABILITY) {
            BrowserPointerOwner::Client(client)
        } else {
            BrowserPointerOwner::Legacy
        };
        record.browser_pointer_owner = Some(owner);
        Ok(owner)
    }

    pub(crate) fn begin_daemon_handoff(
        &self,
        requesting_client: u64,
        force: bool,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let requester = state
            .clients
            .get(&requesting_client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {requesting_client}"))?;
        if !matches!(requester.transport, ClientTransport::Unix) {
            anyhow::bail!("daemon shutdown requires a trusted local connection");
        }
        if !force
            && state.clients.iter().any(|(client, record)| {
                *client != requesting_client && record.kind.as_deref() == Some("native-browser")
            })
        {
            anyhow::bail!("another native-browser frontend still owns this daemon");
        }
        if state.daemon_handoff.is_some() {
            anyhow::bail!("daemon handoff is already in progress");
        }
        state.daemon_handoff = Some(DaemonHandoffReservation::Pending(requesting_client));
        Ok(())
    }

    pub(crate) fn commit_daemon_handoff_after_ack(
        &self,
        requesting_client: u64,
        acknowledge: impl FnOnce() -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        match state.daemon_handoff {
            Some(DaemonHandoffReservation::Pending(requester))
                if requester == requesting_client =>
            {
                acknowledge()?;
                state.daemon_handoff = Some(DaemonHandoffReservation::Committed(requesting_client));
                Ok(())
            }
            _ => anyhow::bail!("daemon handoff reservation changed before commit"),
        }
    }

    pub(crate) fn cancel_daemon_handoff(&self, requesting_client: u64) {
        let mut state = self.state.lock().unwrap();
        if state.daemon_handoff == Some(DaemonHandoffReservation::Pending(requesting_client)) {
            state.daemon_handoff = None;
        }
    }

    pub(crate) fn list_json(&self, requesting_client: u64) -> Value {
        let state = self.state.lock().unwrap();
        json!(
            state
                .clients
                .iter()
                .map(|(client, record)| {
                    json!({
                        "client": client,
                        "transport": record.transport.as_str(),
                        "name": record.name,
                        "kind": record.kind,
                        "connected_seconds": record.connected_at.elapsed().as_secs(),
                        "attached": record.attached.iter().filter_map(|(surface, attached)| {
                            (!attached.streams.is_empty()).then_some(*surface)
                        }).collect::<Vec<_>>(),
                        "sizes": record.attached.iter().filter_map(|(surface, attached)| {
                            if attached.streams.is_empty() {
                                return None;
                            }
                            Some(match attached.committed_size {
                                Some((cols, rows)) => json!({
                                    "surface": surface,
                                    "cols": cols,
                                    "rows": rows,
                                }),
                                None => json!({
                                    "surface": surface,
                                    "cols": null,
                                    "rows": null,
                                }),
                            })
                        }).collect::<Vec<_>>(),
                        "self": *client == requesting_client,
                    })
                })
                .collect::<Vec<_>>()
        )
    }

    fn attach_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
    ) -> anyhow::Result<Option<String>> {
        self.attach_surface_with_lease_policy(client, surface, stream, false)
    }

    fn attach_surface_with_required_lease(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
    ) -> anyhow::Result<String> {
        self.attach_surface_with_lease_policy(client, surface, stream, true)?
            .ok_or_else(|| anyhow::anyhow!("required view attachment lease was not minted"))
    }

    fn attach_surface_with_lease_policy(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: OutboundStream,
        require_lease: bool,
    ) -> anyhow::Result<Option<String>> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let lease =
            if require_lease || record.capabilities.contains(VIEW_ATTACHMENT_LEASE_CAPABILITY) {
                let mut lease = mint_view_lease()?;
                while record.view_leases.contains_key(&lease)
                    || record.retired_view_leases.contains_key(&lease)
                {
                    lease = mint_view_lease()?;
                }
                Some(lease)
            } else {
                None
            };
        let stream_id = stream.id;
        let attached = record.attached.entry(surface).or_default();
        attached.pending_streams.insert(stream_id, stream);
        if let Some(lease) = &lease {
            attached.lease_by_stream.insert(stream_id, lease.clone());
            attached.view_sizes.insert(lease.clone(), None);
            if attached.geometry_lease.is_none() {
                attached.geometry_lease = Some(lease.clone());
            }
            record.view_leases.insert(lease.clone(), (surface, stream_id));
        }
        state.attached_by_surface.entry(surface).or_default().insert(client);
        Ok(lease)
    }

    fn commit_surface(
        &self,
        client: u64,
        surface: SurfaceId,
        stream: u64,
        rollback: Option<crate::mux::ClientSizeRollback>,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let attached = record
            .attached
            .get_mut(&surface)
            .ok_or_else(|| anyhow::anyhow!("client {client} has no pending surface {surface}"))?;
        let outbound = attached.pending_streams.remove(&stream).ok_or_else(|| {
            anyhow::anyhow!("client {client} has no pending stream {stream} for surface {surface}")
        })?;
        attached.streams.insert(stream, outbound);
        if let Some(lease) = attached.lease_by_stream.get(&stream)
            && let Some(current) = record.view_leases.get_mut(lease)
        {
            current.1 = stream;
        }
        if let Some(rollback) = rollback {
            attached.size_rollbacks.insert(stream, rollback);
        }
        attached.committed_size = attached.size;
        Ok(())
    }

    fn view_lease_status(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
    ) -> anyhow::Result<ViewLeaseStatus> {
        let state = self.state.lock().unwrap();
        let record =
            state.clients.get(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if let Some((lease_surface, _)) = record.view_leases.get(lease) {
            anyhow::ensure!(
                *lease_surface == surface,
                "view attachment lease belongs to surface {lease_surface}, not {surface}"
            );
            let geometry_owner = record
                .attached
                .get(&surface)
                .and_then(|attached| attached.geometry_lease.as_deref())
                == Some(lease);
            return Ok(ViewLeaseStatus::Current { geometry_owner });
        }
        if let Some(lease_surface) = record.retired_view_leases.get(lease) {
            anyhow::ensure!(
                *lease_surface == surface,
                "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
            );
            return Ok(ViewLeaseStatus::Superseded);
        }
        anyhow::bail!("invalid or foreign view attachment lease")
    }

    fn view_stream(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
    ) -> anyhow::Result<Option<(u64, OutboundStream)>> {
        let state = self.state.lock().unwrap();
        let record =
            state.clients.get(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some((lease_surface, stream)) = record.view_leases.get(lease).copied() else {
            if let Some(lease_surface) = record.retired_view_leases.get(lease) {
                anyhow::ensure!(
                    *lease_surface == surface,
                    "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
                );
                return Ok(None);
            }
            anyhow::bail!("invalid or foreign view attachment lease");
        };
        anyhow::ensure!(
            lease_surface == surface,
            "view attachment lease belongs to surface {lease_surface}, not {surface}"
        );
        let Some(attached) = record.attached.get(&surface) else { return Ok(None) };
        Ok(attached
            .streams
            .get(&stream)
            .or_else(|| attached.pending_streams.get(&stream))
            .cloned()
            .map(|outbound| (stream, outbound)))
    }

    fn prepare_view_resize(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
        size: (u16, u16),
    ) -> anyhow::Result<ViewResizePreparation> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some((lease_surface, _)) = record.view_leases.get(lease).copied() else {
            if let Some(lease_surface) = record.retired_view_leases.get(lease) {
                anyhow::ensure!(
                    *lease_surface == surface,
                    "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
                );
                return Ok(ViewResizePreparation::Superseded);
            }
            anyhow::bail!("invalid or foreign view attachment lease");
        };
        anyhow::ensure!(
            lease_surface == surface,
            "view attachment lease belongs to surface {lease_surface}, not {surface}"
        );
        let Some(attached) = record.attached.get_mut(&surface) else {
            return Ok(ViewResizePreparation::Superseded);
        };
        let previous_view_size = attached.view_sizes.get(lease).copied().flatten();
        let changed = previous_view_size != Some(size);
        attached.view_sizes.insert(lease.to_string(), Some(size));
        if attached.geometry_lease.as_deref() != Some(lease) {
            return Ok(ViewResizePreparation::Passive {
                changed,
                name: record.name.clone(),
                kind: record.kind.clone(),
            });
        }
        let previous = attached.size;
        attached.size = Some(size);
        if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
            attached.committed_size = attached.size;
        }
        Ok(ViewResizePreparation::GeometryOwner {
            update: (previous != Some(size), record.name.clone(), record.kind.clone(), previous),
            previous_view_size,
        })
    }

    fn restore_view_size(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
        size: Option<(u16, u16)>,
    ) {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else { return };
        let Some(attached) = record.attached.get_mut(&surface) else { return };
        if !attached.view_sizes.contains_key(lease) {
            return;
        }
        attached.view_sizes.insert(lease.to_string(), size);
        if attached.geometry_lease.as_deref() == Some(lease) {
            attached.size = size;
            if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
                attached.committed_size = size;
            }
        }
    }

    fn release_view_size(
        &self,
        client: u64,
        surface: SurfaceId,
        lease: &str,
    ) -> anyhow::Result<ViewReleasePreparation> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some((lease_surface, _)) = record.view_leases.get(lease).copied() else {
            if let Some(lease_surface) = record.retired_view_leases.get(lease) {
                anyhow::ensure!(
                    *lease_surface == surface,
                    "retired view attachment lease belongs to surface {lease_surface}, not {surface}"
                );
                return Ok(ViewReleasePreparation::Superseded);
            }
            anyhow::bail!("invalid or foreign view attachment lease");
        };
        anyhow::ensure!(
            lease_surface == surface,
            "view attachment lease belongs to surface {lease_surface}, not {surface}"
        );
        let Some(attached) = record.attached.get_mut(&surface) else {
            return Ok(ViewReleasePreparation::Superseded);
        };
        let changed = attached.view_sizes.insert(lease.to_string(), None).flatten().is_some();
        if attached.geometry_lease.as_deref() != Some(lease) {
            return Ok(ViewReleasePreparation::Passive);
        }
        attached.size = None;
        attached.committed_size = None;
        attached.current_report_order = None;
        Ok(ViewReleasePreparation::GeometryOwner {
            changed,
            name: record.name.clone(),
            kind: record.kind.clone(),
        })
    }

    fn announce_attached(&self, client: u64) -> anyhow::Result<Option<ClientAnnouncement>> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        if record.announced_attached {
            return Ok(None);
        }
        anyhow::ensure!(
            record.attached.values().any(|attached| !attached.streams.is_empty()),
            "client {client} has no attached surfaces"
        );
        record.announced_attached = true;
        Ok(Some((record.transport.as_str().to_string(), record.name.clone(), record.kind.clone())))
    }

    fn retain_retired_view_lease(record: &mut ClientRecord, lease: String, surface: SurfaceId) {
        record.retired_view_leases.insert(lease.clone(), surface);
        record.retired_view_lease_order.push_back(lease);
        while record.retired_view_lease_order.len() > RETIRED_VIEW_LEASE_CAPACITY {
            if let Some(expired) = record.retired_view_lease_order.pop_front() {
                record.retired_view_leases.remove(&expired);
            }
        }
    }

    fn retain_retired_surface(record: &mut ClientRecord, surface: SurfaceId) {
        if record.retired_surfaces.insert(surface) {
            record.retired_surface_order.push_back(surface);
        }
        while record.retired_surface_order.len() > RETIRED_VIEW_LEASE_CAPACITY {
            if let Some(expired) = record.retired_surface_order.pop_front() {
                record.retired_surfaces.remove(&expired);
            }
        }
    }

    fn detach_surface(&self, client: u64, surface: SurfaceId, stream: u64) -> DetachedSurface {
        let mut state = self.state.lock().unwrap();
        let Some(record) = state.clients.get_mut(&client) else {
            return DetachedSurface {
                final_stream: false,
                rollback: None,
                geometry_replacement: None,
            };
        };
        let Some(attached) = record.attached.get_mut(&surface) else {
            return DetachedSurface {
                final_stream: false,
                rollback: None,
                geometry_replacement: None,
            };
        };
        attached.streams.remove(&stream);
        attached.pending_streams.remove(&stream);
        let removed_lease = attached.lease_by_stream.remove(&stream);
        let removed_geometry_owner = removed_lease
            .as_deref()
            .is_some_and(|lease| attached.geometry_lease.as_deref() == Some(lease));
        if let Some(lease) = &removed_lease {
            attached.view_sizes.remove(lease);
        }
        let rollback = attached.size_rollbacks.remove(&stream);
        if let Some(removed) = rollback {
            for remaining in attached.size_rollbacks.values_mut() {
                if remaining.previous_report_order == Some(removed.applied_report_order) {
                    remaining.previous_size = removed.previous_size;
                    remaining.previous_report_order = removed.previous_report_order;
                    remaining.previous_geometry = removed.previous_geometry;
                }
            }
        }
        let final_stream = attached.streams.is_empty() && attached.pending_streams.is_empty();
        let geometry_replacement = if removed_geometry_owner && !final_stream {
            let replacement = attached
                .lease_by_stream
                .iter()
                .find(|(stream, _)| attached.streams.contains_key(stream))
                .or_else(|| attached.lease_by_stream.iter().next())
                .map(|(_, lease)| lease.clone());
            attached.geometry_lease = replacement.clone();
            let size = replacement
                .as_ref()
                .and_then(|lease| attached.view_sizes.get(lease).copied().flatten());
            attached.size = size;
            attached.committed_size = size;
            attached.current_report_order = None;
            Some(size)
        } else {
            None
        };
        let rollback = rollback.filter(|rollback| {
            geometry_replacement.is_none()
                && attached.current_report_order == Some(rollback.applied_report_order)
        });
        if let Some(lease) = removed_lease {
            record.view_leases.remove(&lease);
            Self::retain_retired_view_lease(record, lease, surface);
        }
        if final_stream {
            record.attached.remove(&surface);
            Self::retain_retired_surface(record, surface);
            if let Some(clients) = state.attached_by_surface.get_mut(&surface) {
                clients.remove(&client);
                if clients.is_empty() {
                    state.attached_by_surface.remove(&surface);
                }
            }
            return DetachedSurface {
                final_stream: true,
                rollback,
                geometry_replacement: Some(None),
            };
        }
        DetachedSurface { final_stream: false, rollback, geometry_replacement }
    }

    pub(crate) fn record_size(
        &self,
        client: u64,
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<ClientSizeUpdate>> {
        let mut state = self.state.lock().unwrap();
        let record = state
            .clients
            .get_mut(&client)
            .ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
        let Some(attached) = record.attached.get_mut(&surface) else { return Ok(None) };
        let previous = attached.size;
        let changed = previous != Some((cols, rows));
        attached.size = Some((cols, rows));
        if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
            attached.committed_size = attached.size;
        }
        Ok(Some((changed, record.name.clone(), record.kind.clone(), previous)))
    }

    pub(crate) fn set_report_order(&self, client: u64, surface: SurfaceId, report_order: u64) {
        if let Some(attached) = self
            .state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.current_report_order = Some(report_order);
        }
    }

    pub(crate) fn restore_size(&self, client: u64, surface: SurfaceId, size: Option<(u16, u16)>) {
        if let Some(attached) = self
            .state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.size = size;
            if attached.pending_streams.is_empty() && !attached.streams.is_empty() {
                attached.committed_size = size;
            }
        }
    }

    pub(crate) fn restore_size_and_report_order(
        &self,
        client: u64,
        surface: SurfaceId,
        size: Option<(u16, u16)>,
        report_order: Option<u64>,
    ) {
        self.restore_size(client, surface, size);
        if let Some(attached) = self
            .state
            .lock()
            .unwrap()
            .clients
            .get_mut(&client)
            .and_then(|record| record.attached.get_mut(&surface))
        {
            attached.current_report_order = report_order;
        }
    }

    fn clear_size(
        &self,
        client: u64,
        surface: SurfaceId,
    ) -> Option<(bool, Option<String>, Option<String>)> {
        let mut state = self.state.lock().unwrap();
        let record = state.clients.get_mut(&client)?;
        let attached = record.attached.get_mut(&surface)?;
        let changed = attached.size.take().is_some();
        attached.committed_size = None;
        attached.current_report_order = None;
        Some((changed, record.name.clone(), record.kind.clone()))
    }

    fn remove(&self, client: u64) -> Option<ClientRecord> {
        let mut state = self.state.lock().unwrap();
        let record = state.clients.remove(&client)?;
        if state.daemon_handoff == Some(DaemonHandoffReservation::Pending(client)) {
            state.daemon_handoff = None;
        }
        for surface in record.attached.keys() {
            if let Some(clients) = state.attached_by_surface.get_mut(surface) {
                clients.remove(&client);
                if clients.is_empty() {
                    state.attached_by_surface.remove(surface);
                }
            }
        }
        Some(record)
    }

    pub(crate) fn contains(&self, client: u64) -> bool {
        self.state.lock().unwrap().clients.contains_key(&client)
    }

    pub(crate) fn client_info(&self, client: u64) -> Option<(Option<String>, Option<String>)> {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .map(|record| (record.name.clone(), record.kind.clone()))
    }

    #[cfg(test)]
    pub(crate) fn attached_client_ids(&self) -> HashSet<u64> {
        self.state
            .lock()
            .unwrap()
            .clients
            .iter()
            .filter_map(|(client, record)| (!record.attached.is_empty()).then_some(*client))
            .collect()
    }

    pub(crate) fn attached_client_ids_by_surface(&self) -> HashMap<SurfaceId, HashSet<u64>> {
        self.state.lock().unwrap().attached_by_surface.clone()
    }

    /// Query one surface without walking every client's retained attachments.
    pub(crate) fn attached_client_ids_for_surface(&self, surface: SurfaceId) -> HashSet<u64> {
        self.state.lock().unwrap().attached_by_surface.get(&surface).cloned().unwrap_or_default()
    }
}

fn clamp_client_label(value: String) -> String {
    sanitize_window_title(&value).chars().take(64).collect()
}

fn validate_resource_client_label(
    field: &'static str,
    value: Option<String>,
) -> Result<Option<String>, ResourceError> {
    let Some(value) = value else { return Ok(None) };
    if value.chars().count() > 64 {
        return Err(ResourceError::validation_invalid(
            Some(field),
            "client metadata labels cannot exceed 64 characters",
        ));
    }
    if value.chars().any(char::is_control) {
        return Err(ResourceError::validation_invalid(
            Some(field),
            "client metadata labels cannot contain control characters",
        ));
    }
    Ok(Some(value))
}

/// A bound local server whose lifecycle endpoint is not ready yet.
pub struct PendingServer {
    path: Option<PathBuf>,
    mux: Arc<Mux>,
    shutdown: Arc<AtomicBool>,
}

impl PendingServer {
    /// Publish lifecycle readiness and transfer socket cleanup to the caller.
    pub fn mark_ready(mut self) -> anyhow::Result<PathBuf> {
        self.mux.mark_server_lifecycle_ready();
        Ok(self.path.take().expect("pending server path is available"))
    }

    /// Transfer socket cleanup while another startup owner publishes readiness.
    pub fn into_bound_path(mut self) -> PathBuf {
        self.path.take().expect("pending server path is available")
    }
}

impl Drop for PendingServer {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            self.shutdown.store(true, Ordering::Release);
            let _ = transport::connect(&path);
            cleanup(&path);
        }
    }
}

/// Prepare the daemon-owned runtime directory without accepting a symlink or
/// an existing directory controlled by another user. The final metadata check
/// also confirms that tightening permissions did not change the object type.
fn prepare_runtime_socket_directory(dir: &Path) -> anyhow::Result<()> {
    match std::fs::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                anyhow::bail!("runtime socket directory must not be a symlink: {}", dir.display());
            }
            if !metadata.is_dir() {
                anyhow::bail!("runtime socket path parent is not a directory: {}", dir.display());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(dir)?;
        }
        Err(error) => return Err(error.into()),
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let metadata = std::fs::symlink_metadata(dir)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            anyhow::bail!("runtime socket directory changed during creation: {}", dir.display());
        }
        // The effective user must own the directory before we chmod it. This
        // prevents an inherited path from being used to mutate another user's
        // runtime directory.
        if metadata.uid() != unsafe { libc::geteuid() } {
            anyhow::bail!(
                "runtime socket directory is not owned by the effective user: {}",
                dir.display()
            );
        }
        if metadata.permissions().mode() & 0o077 != 0 {
            platform::restrict_directory(dir)?;
        }
        let verified = std::fs::symlink_metadata(dir)?;
        if verified.file_type().is_symlink()
            || !verified.is_dir()
            || verified.uid() != unsafe { libc::geteuid() }
            || verified.permissions().mode() & 0o077 != 0
        {
            anyhow::bail!("runtime socket directory is not private: {}", dir.display());
        }
    }
    #[cfg(not(unix))]
    {
        platform::restrict_directory(dir)?;
    }
    Ok(())
}

/// Create missing parents for an explicitly selected socket path without
/// changing the permissions or ownership of an existing directory. Explicit
/// paths may point at a caller-managed location, but the final parent must
/// still be a real directory rather than a symlink or other file.
fn prepare_explicit_socket_directory(path: &Path) -> anyhow::Result<()> {
    let Some(dir) = path.parent() else { return Ok(()) };
    if dir.as_os_str().is_empty() {
        return Ok(());
    }

    match std::fs::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                anyhow::bail!("explicit socket path parent is not a directory: {}", dir.display());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(dir)?;
            let metadata = std::fs::symlink_metadata(dir)?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                anyhow::bail!(
                    "explicit socket path parent changed to a non-directory: {}",
                    dir.display()
                );
            }
        }
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

/// Bind the socket and accept protocol clients before lifecycle readiness.
pub fn serve_paused(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PendingServer> {
    let (path, is_derived) = match path {
        Some(path) => (path, false),
        None => (try_default_socket_path(&mux.session)?, true),
    };
    // Only harden directories selected by the daemon. An explicit socket path
    // is authoritative, so its parent may be a shared or pre-configured path
    // such as /tmp and must not be chmod'ed or ownership-checked.
    if is_derived {
        if let Some(dir) = path.parent() {
            prepare_runtime_socket_directory(dir)?;
        }
    } else {
        prepare_explicit_socket_directory(&path)?;
    }
    // Refuse to clobber a live socket; remove a stale one.
    if path.exists() {
        match transport::connect(&path) {
            Ok(_) => anyhow::bail!(
                "session socket {} is already in use (another instance running?)",
                path.display()
            ),
            Err(_) => std::fs::remove_file(&path)?,
        }
    }
    let listener = transport::listen(&path)?;
    if let Err(error) = platform::restrict_file(&path) {
        cleanup(&path);
        return Err(error.into());
    }
    let active_connections = Arc::new(AtomicU64::new(0));
    let render_service = Arc::new(RenderService::new());
    let shutdown = Arc::new(AtomicBool::new(false));
    let server_shutdown = shutdown.clone();
    let server_mux = mux.clone();

    let server = std::thread::Builder::new().name("mux-server".into()).spawn(move || {
        loop {
            let Ok(stream) = listener.accept() else { continue };
            if server_shutdown.load(Ordering::Acquire) {
                break;
            }
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let mux = server_mux.clone();
            let render_service = render_service.clone();
            let _ = std::thread::Builder::new().name("mux-conn".into()).spawn(move || {
                handle_connection_with_permit(mux, stream, render_service, Some(permit));
            });
        }
    });
    if let Err(error) = server {
        cleanup(&path);
        return Err(error.into());
    }
    Ok(PendingServer { path: Some(path), mux, shutdown })
}

/// Bind the socket and serve connections on background threads.
pub fn serve(mux: Arc<Mux>, path: Option<PathBuf>) -> anyhow::Result<PathBuf> {
    serve_paused(mux, path)?.mark_ready()
}

/// A running opt-in WebSocket listener. Dropping it stops accepts and closes clients.
pub struct WebSocketServer {
    local_addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    connections: Arc<Mutex<HashMap<u64, TcpStream>>>,
    thread: Option<JoinHandle<()>>,
}

impl WebSocketServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }
}

impl Drop for WebSocketServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        for stream in self.connections.lock().unwrap().values() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Ok(stream) = TcpStream::connect(self.local_addr) {
            let _ = stream.set_nodelay(true);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Bind an opt-in WebSocket listener using one JSON message per text frame.
pub fn serve_websocket(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
) -> anyhow::Result<WebSocketServer> {
    // WebSocket has no TLS here. Remote deployments must explicitly opt in and
    // should put cmux-tui behind a TLS-terminating reverse proxy.
    if !addr.ip().is_loopback() && !allow_insecure_bind {
        anyhow::bail!("refusing non-loopback WebSocket bind {addr} without --ws-insecure-bind");
    }
    let token = token.filter(|value| !value.trim().is_empty());
    if let Some(token_value) = token.as_ref() {
        let auth_message_bytes =
            serde_json::to_vec(&json!({"auth": {"token": token_value}}))?.len();
        if auth_message_bytes > WEBSOCKET_AUTH_MAX_BYTES {
            anyhow::bail!(
                "WebSocket token produces a {auth_message_bytes}-byte auth message; maximum is {WEBSOCKET_AUTH_MAX_BYTES} bytes"
            );
        }
    }
    let listener = TcpListener::bind(addr)?;
    let local_addr = listener.local_addr()?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(Mutex::new(HashMap::new()));
    let next_connection = Arc::new(AtomicU64::new(1));
    let active_connections = Arc::new(AtomicU64::new(0));
    let thread_shutdown = shutdown.clone();
    let thread_connections = connections.clone();
    let render_service = Arc::new(RenderService::new());
    let thread = std::thread::Builder::new().name("mux-ws-server".into()).spawn(move || {
        while !thread_shutdown.load(Ordering::Acquire) {
            let (stream, peer) = match listener.accept() {
                Ok(connection) => connection,
                Err(_) => {
                    if thread_shutdown.load(Ordering::Acquire) {
                        break;
                    }
                    // Accept errors can persist (for example, after resource exhaustion).
                    // A short backoff prevents a hot retry loop while still recovering promptly.
                    std::thread::sleep(STREAM_DISCONNECT_POLL);
                    continue;
                }
            };
            if stream.set_nodelay(true).is_err() {
                continue;
            }
            if thread_shutdown.load(Ordering::Acquire) {
                break;
            }
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let id = next_connection.fetch_add(1, Ordering::Relaxed);
            if let Ok(tracked) = stream.try_clone() {
                thread_connections.lock().unwrap().insert(id, tracked);
            }
            let mux = mux.clone();
            let token = token.clone();
            let render_service = render_service.clone();
            let connections = thread_connections.clone();
            let cleanup_connections = thread_connections.clone();
            if std::thread::Builder::new()
                .name("mux-ws-conn".into())
                .spawn(move || {
                    handle_websocket_connection_with_permit(
                        mux,
                        stream,
                        peer,
                        token.as_deref(),
                        render_service,
                        Some(permit),
                    );
                    connections.lock().unwrap().remove(&id);
                })
                .is_err()
            {
                cleanup_connections.lock().unwrap().remove(&id);
            }
        }
    })?;
    Ok(WebSocketServer { local_addr, shutdown, connections, thread: Some(thread) })
}

pub fn window_title_osc(title: &str) -> Vec<u8> {
    let title = sanitize_window_title(title);
    format!("\x1b]0;{title}\x07\x1b]2;{title}\x07").into_bytes()
}

fn sanitize_window_title(title: &str) -> String {
    title
        .chars()
        .map(|ch| match ch {
            '\u{00}'..='\u{1f}' | '\u{7f}' => ' ',
            _ => ch,
        })
        .collect()
}

#[cfg(test)]
fn handle_connection(mux: Arc<Mux>, stream: Box<dyn transport::Stream>) {
    handle_connection_with_permit(mux, stream, Arc::new(RenderService::new()), None);
}

fn handle_connection_with_permit(
    mux: Arc<Mux>,
    stream: Box<dyn transport::Stream>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    let Ok(mut write_half) = stream.try_clone_box() else { return };
    let Ok(control) = write_half.try_clone_box() else { return };
    if write_half.set_write_timeout(Some(STREAM_WRITE_TIMEOUT)).is_err() {
        return;
    }
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: outbound.clone(), control: Some(SinkControl::Unix(control)) },
        render_service,
    );
    let writer_outbound = outbound;
    let writer_close = writer.clone();
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-line-out".into()).spawn(move || {
            while let Some(item) = writer_outbound.recv() {
                if write_line_outbound_item(&mut *write_half, item).is_err() {
                    writer_outbound.close();
                    let _ = write_half.shutdown(Shutdown::Both);
                    break;
                }
            }
            writer_close.close();
            let _ = write_half.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let surface_scheduler = Arc::new(ConnectionSurfaceScheduler::new_inner(
        mux.surface_operation_admission.clone(),
        connection_permit.clone(),
    ));
    let mut reader = BufReader::new(stream);
    let mut drain_accepted = true;
    loop {
        let mut line = String::new();
        // read_line includes the trailing LF. Read one byte beyond the largest
        // valid payload plus its delimiter so an oversized payload is visible.
        let read = match reader.by_ref().take((MAX_JSON_LINE_BYTES + 2) as u64).read_line(&mut line)
        {
            Ok(read) => read,
            Err(_) => {
                drain_accepted = false;
                break;
            }
        };
        if read == 0 {
            break;
        }
        if json_line_payload_len(&line) > MAX_JSON_LINE_BYTES {
            drain_accepted = false;
            break;
        }
        if line.trim().is_empty() {
            zeroize_string(&mut line);
            continue;
        }
        let keep_open = handle_connection_message(&mux, client, &line, &writer, &surface_scheduler);
        zeroize_string(&mut line);
        if !keep_open {
            drain_accepted = false;
            break;
        }
    }
    if drain_accepted {
        surface_scheduler.finish_and_wait();
    } else {
        let _ = surface_scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
    }
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
    drop(connection_permit);
}

fn json_line_payload_len(line: &str) -> usize {
    line.strip_suffix('\n').map_or(line.len(), str::len)
}

#[cfg(test)]
fn handle_websocket_connection(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
    render_service: Arc<RenderService>,
) {
    handle_websocket_connection_with_permit(mux, stream, peer, token, render_service, None);
}

fn handle_websocket_connection_with_permit(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    let stream = SynchronizedTcpStream::new(stream);
    if stream.set_read_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
        || stream.set_write_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
    {
        return;
    }
    let auth_config = WebSocketConfig::default()
        .read_buffer_size(4 * 1024)
        .write_buffer_size(4 * 1024)
        .max_write_buffer_size(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES)
        .max_message_size(Some(WEBSOCKET_AUTH_MAX_BYTES))
        .max_frame_size(Some(WEBSOCKET_AUTH_MAX_BYTES));
    let Ok(mut websocket) = accept_with_config(stream, Some(auth_config)) else { return };

    if !authenticate_websocket(&mux, &mut websocket, peer, token) {
        let frame = CloseFrame { code: CloseCode::Policy, reason: "authentication failed".into() };
        let _ = websocket.close(Some(frame));
        let _ = websocket.flush();
        return;
    }
    websocket.set_config(|config| {
        config.max_message_size = Some(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES);
        config.max_frame_size = Some(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES);
    });
    let _ = websocket.get_mut().set_read_timeout(None);
    let _ = websocket.get_mut().set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let Ok(writer_stream) = websocket.get_ref().try_clone() else { return };
    let Ok(writer_shutdown) = writer_stream.try_clone_raw() else { return };
    let Ok(control) = writer_stream.try_clone_raw() else { return };
    let _ = writer_stream.set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: outbound.clone(), control: Some(SinkControl::WebSocket(control)) },
        render_service,
    );
    let writer_outbound = outbound;
    let writer_close = writer.clone();
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-ws-out".into()).spawn(move || {
            let mut writer_stream = writer_stream;
            while let Some(item) = writer_outbound.recv() {
                let result = match item {
                    OutboundItem::Text(text) => writer_stream.write_websocket_text(&text),
                    OutboundItem::Flush(flushed) => writer_stream.flush().map(|()| {
                        let _ = flushed.send(());
                    }),
                };
                if result.is_err() {
                    writer_outbound.close();
                    break;
                }
            }
            writer_close.close();
            let _ = writer_stream.write_websocket_close();
            let _ = writer_shutdown.shutdown(Shutdown::Both);
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    let surface_scheduler = Arc::new(ConnectionSurfaceScheduler::new_inner(
        mux.surface_operation_admission.clone(),
        connection_permit.clone(),
    ));

    loop {
        if !writer.is_open() {
            break;
        }

        let incoming = websocket.read();
        match incoming {
            Ok(Message::Text(text)) => {
                let mut text = text.to_string();
                let keep_open =
                    handle_connection_message(&mux, client, &text, &writer, &surface_scheduler);
                zeroize_string(&mut text);
                if !keep_open {
                    break;
                }
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                let _ = websocket.flush();
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => break,
            Err(_) => break,
        }
    }
    let _ = surface_scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
    let _ = websocket.close(None);
    drop(connection_permit);
}

fn authenticate_websocket(
    mux: &Arc<Mux>,
    websocket: &mut WebSocket<SynchronizedTcpStream>,
    peer: SocketAddr,
    configured_token: Option<&str>,
) -> bool {
    let Ok(Message::Text(text)) = websocket.read() else { return false };
    let mut text = text.to_string();
    if let Some(mut provided) = auth_token(&text) {
        let authenticated = configured_token
            .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.as_bytes()))
            || mux.authenticate_pairing_credential(&provided);
        zeroize_string(&mut provided);
        zeroize_string(&mut text);
        return authenticated;
    }
    if !pairing_request(&text) {
        zeroize_string(&mut text);
        return false;
    }
    zeroize_string(&mut text);

    let (challenge, decision) = match mux.begin_pairing(peer.ip()) {
        Ok(pairing) => pairing,
        Err(error) => {
            let _ = websocket.send(Message::Text(
                json!({"pairing_error": {"code": error.code(), "message": error.to_string()}})
                    .to_string()
                    .into(),
            ));
            return false;
        }
    };
    if websocket
        .send(Message::Text(
            json!({"pairing": {
                "id": challenge.id,
                "code": challenge.code,
                "peer": challenge.peer,
                "expires_in": challenge.expires_in,
            }})
            .to_string()
            .into(),
        ))
        .is_err()
    {
        mux.cancel_pairing(challenge.id);
        return false;
    }

    match decision.recv_timeout(Duration::from_secs(challenge.expires_in)) {
        Ok(PairingDecision::Approved { credential }) => websocket
            .send(Message::Text(json!({"paired": {"credential": credential}}).to_string().into()))
            .is_ok(),
        Ok(PairingDecision::Denied) | Err(_) => {
            mux.cancel_pairing(challenge.id);
            false
        }
    }
}

fn disconnect_client(mux: &Arc<Mux>, client: u64, send_detached: bool) -> bool {
    let record = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        let Some(record) = mux.control_clients.remove(client) else { return false };
        mux.remove_size_client_from_attached_surfaces(client, record.attached.keys().copied());
        record
    };
    // Provider capabilities are valid only for the control connection that
    // published them. Release before announcing detachment so waiters can
    // never observe a stale target after the owning client is gone.
    mux.unregister_browser_provider(client);
    if let Some(owner @ BrowserPointerOwner::Client(_)) = record.browser_pointer_owner {
        // Pointer commands do not require a frame-stream attachment, so any
        // browser worker may own this negotiated client. Disconnects are rare;
        // wake all browser workers after registry removal instead of polling
        // every idle worker forever.
        let surfaces = mux.with_state(|state| {
            state
                .surfaces
                .values()
                .filter(|surface| surface.kind() == SurfaceKind::Browser)
                .cloned()
                .collect::<Vec<_>>()
        });
        for surface in surfaces {
            surface.forget_browser_pointer_owner(owner);
            surface.wake_browser_pointer_cleanup();
        }
    }
    if send_detached {
        let _ = record.writer.set_write_timeout(Some(CLIENT_DETACH_WRITE_TIMEOUT));
        for (surface, attached) in &record.attached {
            for stream in attached.streams.values() {
                let _ = record
                    .writer
                    .send_terminal(&json!({"event": "detached", "surface": surface}), stream);
            }
        }
        record.writer.close_after_control();
    } else {
        record.writer.close();
    }
    mux.emit(MuxEvent::ClientDetached(client));
    true
}

fn complete_daemon_shutdown_after_ack(
    mux: &Arc<Mux>,
    requesting_client: u64,
    writer: &MessageWriter,
) -> bool {
    if mux
        .commit_daemon_handoff_after_ack(requesting_client, || {
            writer.flush_control(SHUTDOWN_ACK_FLUSH_TIMEOUT)
        })
        .is_err()
    {
        mux.cancel_daemon_handoff(requesting_client);
        return false;
    }
    mux.request_daemon_shutdown();
    for peer in mux.control_clients.client_ids() {
        if peer != requesting_client {
            disconnect_client(mux, peer, true);
        }
    }
    true
}

pub fn detach_control_client(mux: &Arc<Mux>, client: u64) -> bool {
    disconnect_client(mux, client, true)
}

#[cfg(test)]
fn handle_message(mux: &Arc<Mux>, client: u64, message: &str, writer: &MessageWriter) -> bool {
    match serde_json::from_str::<Request>(message) {
        Ok(request) => handle_request(mux, client, request, writer),
        Err(error) => send_request_error(writer, None, &format!("bad request: {error}")),
    }
}

struct SessionEventStreamStart {
    stream_id: StreamPublicId,
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
    initial_items: Vec<(Value, Value)>,
    next_sequence: u64,
    last_revision: u64,
    epoch: u64,
}

const JOURNAL_STREAM_PAGE_SIZE: usize = 1024;

struct SessionJournalStreamStart {
    stream_id: StreamPublicId,
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
    session_id: SessionPublicId,
    next_sequence: u64,
    last_sequence: u64,
    through_sequence: Option<u64>,
    epoch: u64,
    filter: JournalStreamFilter,
    indexed_subjects: Option<Vec<JournalSubject>>,
    reader: Option<crate::workspace_registry::SessionJournalReader>,
    shared_fanout: bool,
    remote_redacted: bool,
}

struct JournalStreamFilter {
    exact_kinds: HashSet<String>,
    kind_prefixes: Vec<String>,
    classes: [bool; 4],
    has_class_filter: bool,
    subject_kinds: HashSet<String>,
    subject_ids: HashSet<String>,
    exact_subjects: HashMap<String, HashSet<String>>,
    has_subject_filter: bool,
    max_sensitivity: Option<JournalSensitivity>,
    regex: Option<JournalCompiledRegex>,
}

impl Default for JournalStreamFilter {
    fn default() -> Self {
        Self {
            exact_kinds: HashSet::new(),
            kind_prefixes: Vec::new(),
            classes: [false; 4],
            has_class_filter: false,
            subject_kinds: HashSet::new(),
            subject_ids: HashSet::new(),
            exact_subjects: HashMap::new(),
            has_subject_filter: false,
            max_sensitivity: Some(JournalSensitivity::Metadata),
            regex: None,
        }
    }
}

enum JournalRegexField {
    Kind,
    Subjects,
    Payload,
    Record,
    TerminalOutput,
}

struct JournalCompiledRegex {
    field: JournalRegexField,
    matcher: BytesRegex,
}

impl JournalCompiledRegex {
    fn parse(value: &Value) -> Result<Self, ResourceError> {
        let object = value.as_object().ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("filter.regex"),
                "journal regex is not an object",
            )
        })?;
        let pattern = object.get("pattern").and_then(Value::as_str).ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("filter.regex.pattern"),
                "journal regex pattern is absent",
            )
        })?;
        let field = match object.get("field").and_then(Value::as_str).unwrap_or("record") {
            "kind" => JournalRegexField::Kind,
            "subjects" => JournalRegexField::Subjects,
            "payload" => JournalRegexField::Payload,
            "record" => JournalRegexField::Record,
            "terminal_output" => JournalRegexField::TerminalOutput,
            _ => {
                return Err(ResourceError::validation_invalid(
                    Some("filter.regex.field"),
                    "journal regex field is invalid",
                ));
            }
        };
        let case_sensitive = object.get("case_sensitive").and_then(Value::as_bool).unwrap_or(true);
        let matcher = BytesRegexBuilder::new(pattern)
            .case_insensitive(!case_sensitive)
            .size_limit(1 << 20)
            .dfa_size_limit(2 << 20)
            .build()
            .map_err(|error| {
                ResourceError::validation_invalid(
                    Some("filter.regex.pattern"),
                    format!("journal regex is invalid: {error}"),
                )
            })?;
        Ok(Self { field, matcher })
    }

    fn matches(&self, document: &JournalDocument) -> bool {
        let record = &document.record;
        match self.field {
            JournalRegexField::Kind => self.matcher.is_match(record.kind.as_bytes()),
            JournalRegexField::Subjects => self.matcher.is_match(document.subjects_bytes()),
            JournalRegexField::Payload => {
                document.payload_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
            JournalRegexField::Record => {
                document.record_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
            JournalRegexField::TerminalOutput => {
                document.terminal_output_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
        }
    }

    fn exposes_payload_or_record(&self) -> bool {
        matches!(
            self.field,
            JournalRegexField::Payload
                | JournalRegexField::Record
                | JournalRegexField::TerminalOutput
        )
    }
}

impl JournalStreamFilter {
    fn parse(value: Option<&Value>) -> Result<Self, ResourceError> {
        let Some(value) = value else { return Ok(Self::default()) };
        let object = value.as_object().ok_or_else(|| {
            ResourceError::validation_invalid(Some("filter"), "journal filter is not an object")
        })?;
        let mut exact_kinds = HashSet::new();
        let mut kind_prefixes = Vec::new();
        if let Some(kinds) = object.get("kinds") {
            let kinds = kinds.as_array().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("filter.kinds"),
                    "journal kind filters are not an array",
                )
            })?;
            for kind in kinds {
                let kind = kind.as_str().ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("filter.kinds"),
                        "journal kind filter is not a string",
                    )
                })?;
                validate_journal_kind_filter(kind)?;
                if let Some(prefix) = kind.strip_suffix(".*") {
                    kind_prefixes.push(format!("{prefix}."));
                } else {
                    exact_kinds.insert(kind.to_string());
                }
            }
        }
        let mut classes = [false; 4];
        let mut has_class_filter = false;
        if let Some(values) = object.get("classes") {
            let values = values.as_array().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("filter.classes"),
                    "journal class filters are not an array",
                )
            })?;
            has_class_filter = !values.is_empty();
            for value in values {
                let class =
                    serde_json::from_value::<JournalClass>(value.clone()).map_err(|_| {
                        ResourceError::validation_invalid(
                            Some("filter.classes"),
                            "journal class filter is invalid",
                        )
                    })?;
                classes[journal_class_index(class)] = true;
            }
        }
        let mut subject_kinds = HashSet::new();
        let mut subject_ids = HashSet::new();
        let mut exact_subjects = HashMap::<String, HashSet<String>>::new();
        let mut has_subject_filter = false;
        if let Some(values) = object.get("subjects") {
            let values = values.as_array().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("filter.subjects"),
                    "journal subject filters are not an array",
                )
            })?;
            has_subject_filter = !values.is_empty();
            for value in values {
                let subject = value.as_object().ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("filter.subjects"),
                        "journal subject filter is not an object",
                    )
                })?;
                let kind = subject.get("kind").and_then(Value::as_str);
                let id = subject.get("id").and_then(Value::as_str);
                match (kind, id) {
                    (Some(kind), Some(id)) => {
                        exact_subjects.entry(kind.into()).or_default().insert(id.into());
                    }
                    (Some(kind), None) => {
                        subject_kinds.insert(kind.into());
                    }
                    (None, Some(id)) => {
                        subject_ids.insert(id.into());
                    }
                    (None, None) => {
                        return Err(ResourceError::validation_invalid(
                            Some("filter.subjects"),
                            "journal subject filters require kind or id",
                        ));
                    }
                }
            }
        }
        let max_sensitivity = object
            .get("max_sensitivity")
            .map(|value| {
                serde_json::from_value::<JournalSensitivity>(value.clone()).map_err(|_| {
                    ResourceError::validation_invalid(
                        Some("filter.max_sensitivity"),
                        "journal sensitivity filter is invalid",
                    )
                })
            })
            .transpose()?
            .or(Some(JournalSensitivity::Metadata));
        if max_sensitivity == Some(JournalSensitivity::Secret) {
            return Err(ResourceError::validation_invalid(
                Some("filter.max_sensitivity"),
                "journal subscriptions cannot include secret records",
            ));
        }
        let regex = object.get("regex").map(JournalCompiledRegex::parse).transpose()?;
        Ok(Self {
            exact_kinds,
            kind_prefixes,
            classes,
            has_class_filter,
            subject_kinds,
            subject_ids,
            exact_subjects,
            has_subject_filter,
            max_sensitivity,
            regex,
        })
    }

    fn matches(&self, document: &JournalDocument) -> bool {
        let record = &document.record;
        let kind_matches = (self.exact_kinds.is_empty() && self.kind_prefixes.is_empty())
            || self.exact_kinds.contains(&record.kind)
            || self.kind_prefixes.iter().any(|prefix| record.kind.starts_with(prefix));
        let class_matches =
            !self.has_class_filter || self.classes[journal_class_index(record.class)];
        let subject_matches = !self.has_subject_filter
            || record.subjects.iter().any(|subject| {
                self.subject_kinds.contains(&subject.kind)
                    || self.subject_ids.contains(&subject.id)
                    || self
                        .exact_subjects
                        .get(&subject.kind)
                        .is_some_and(|ids| ids.contains(&subject.id))
            });
        let sensitivity_matches = self.max_sensitivity.is_none_or(|maximum| {
            journal_sensitivity_rank(record.sensitivity) <= journal_sensitivity_rank(maximum)
        });
        kind_matches
            && class_matches
            && subject_matches
            && sensitivity_matches
            && self.regex.as_ref().is_none_or(|regex| regex.matches(document))
    }

    fn indexed_subjects(&self) -> Option<Vec<JournalSubject>> {
        if !self.has_subject_filter
            || !self.subject_kinds.is_empty()
            || !self.subject_ids.is_empty()
            || self.exact_subjects.is_empty()
        {
            return None;
        }
        Some(
            self.exact_subjects
                .iter()
                .flat_map(|(kind, ids)| {
                    ids.iter().map(|id| JournalSubject { kind: kind.clone(), id: id.clone() })
                })
                .collect(),
        )
    }
}

fn validate_journal_kind_filter(kind: &str) -> Result<(), ResourceError> {
    let base = kind.strip_suffix(".*").unwrap_or(kind);
    if base.is_empty()
        || kind.trim() != kind
        || kind.contains('*') != kind.ends_with(".*")
        || base.split('.').any(|part| {
            part.is_empty()
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
        })
    {
        return Err(ResourceError::validation_invalid(
            Some("filter.kinds"),
            "journal kind filters must be dotted names with an optional terminal .*",
        ));
    }
    Ok(())
}

const fn journal_sensitivity_rank(sensitivity: JournalSensitivity) -> u8 {
    match sensitivity {
        JournalSensitivity::Public => 0,
        JournalSensitivity::Metadata => 1,
        JournalSensitivity::Sensitive => 2,
        JournalSensitivity::Secret => 3,
    }
}

const fn journal_class_index(class: JournalClass) -> usize {
    match class {
        JournalClass::State => 0,
        JournalClass::Observation => 1,
        JournalClass::Effect => 2,
        JournalClass::Checkpoint => 3,
    }
}

const fn handles_resource_connection_operation(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::SessionEvents
            | ResourceOperation::SessionJournalSubscribe
            | ResourceOperation::SessionJournalProducerList
            | ResourceOperation::SessionJournalProducerPut
            | ResourceOperation::SessionJournalAppend
            | ResourceOperation::SessionJournalHookList
            | ResourceOperation::SessionJournalHookPut
            | ResourceOperation::SessionJournalCheckpointCreate
            | ResourceOperation::SessionJournalCheckpointList
            | ResourceOperation::SessionJournalRestorePreview
            | ResourceOperation::SessionJournalSegmentList
            | ResourceOperation::SessionJournalSegmentSeal
            | ResourceOperation::SessionShutdown
            | ResourceOperation::PairingRequestList
            | ResourceOperation::PairingRequestResolve
            | ResourceOperation::RequestCancel
            | ResourceOperation::ClientList
            | ResourceOperation::ClientGet
            | ResourceOperation::ClientMetadataUpdate
            | ResourceOperation::ClientSizingSet
            | ResourceOperation::ClientSizingRelease
            | ResourceOperation::ClientCellPixelsSet
            | ResourceOperation::ClientDetach
            | ResourceOperation::TerminalRendererGrantCreate
            | ResourceOperation::TerminalViewerResize
            | ResourceOperation::TerminalViewerRelease
            | ResourceOperation::TerminalAttach
            | ResourceOperation::BrowserViewerResize
            | ResourceOperation::BrowserViewerRelease
            | ResourceOperation::BrowserAttach
            | ResourceOperation::SidebarViewAttach
            | ResourceOperation::StreamCancel
    )
}

fn trusted_local_resource_client(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
) -> Result<(), ResourceError> {
    if mux.control_clients.is_unix(client) {
        Ok(())
    } else {
        let operation = serde_json::to_value(operation)
            .expect("resource operations serialize")
            .as_str()
            .expect("resource operations serialize as strings")
            .to_string();
        Err(ResourceError::operation_failed(
            operation,
            "operation requires a trusted local connection",
            json!({"required_authority":"trusted_local"}),
        ))
    }
}

fn handle_resource_session_shutdown(
    mux: &Arc<Mux>,
    client: u64,
    request: crate::resource_router::ParsedResourceRequest,
    id: ResourceRequestId,
    writer: &MessageWriter,
) -> bool {
    let operation = ResourceOperation::SessionShutdown;
    let force =
        request.fields["force"].as_bool().expect("catalog validates the shutdown force flag");
    let result = trusted_local_resource_client(mux, client, operation).and_then(|()| {
        mux.begin_daemon_handoff(client, DaemonHandoffRequest::unfenced(force)).map_err(|error| {
            ResourceError::operation_failed(
                "session.shutdown",
                error.to_string(),
                json!({"force":force}),
            )
        })
    });
    if let Err(error) = result {
        return send_resource_response(writer, id, operation, Err(error));
    }

    match crate::resource_router::commit_session_shutdown(mux, request) {
        Ok(result) => {
            let sent = send_resource_response(writer, id, operation, Ok(result));
            if sent {
                complete_daemon_shutdown_after_ack(mux, client, writer)
            } else {
                mux.cancel_daemon_handoff(client);
                false
            }
        }
        Err(error) => {
            mux.cancel_daemon_handoff(client);
            send_resource_response(writer, id, operation, Err(error))
        }
    }
}

fn handle_resource_connection_message(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> bool {
    let request = match crate::resource_router::parse_resource_request(message) {
        Ok(request) => request,
        Err(error) => {
            let response = crate::resource_router::malformed_resource_response(message, error);
            return writer.send_control(&response).is_ok();
        }
    };
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if matches!(
        operation,
        ResourceOperation::SessionShutdown | ResourceOperation::SessionReloadConfig
    ) && !mux.server_lifecycle_ready()
    {
        let operation_name = match operation {
            ResourceOperation::SessionShutdown => "session.shutdown",
            ResourceOperation::SessionReloadConfig => "session.reload_config",
            _ => unreachable!("lifecycle readiness applies only to lifecycle operations"),
        };
        return send_resource_response(
            writer,
            id,
            operation,
            Err(ResourceError::new(
                "operation.failed",
                "server lifecycle is not ready",
                json!({
                    "operation": operation_name,
                    "reason": "lifecycle_not_ready",
                }),
                false,
            )),
        );
    }
    debug_assert_eq!(
        handles_resource_connection_operation(operation),
        crate::resource_router::requires_connection_context(operation)
    );
    match operation {
        ResourceOperation::SessionShutdown => {
            handle_resource_session_shutdown(mux, client, request, id, writer)
        }
        ResourceOperation::PairingRequestList | ResourceOperation::PairingRequestResolve => {
            let result = trusted_local_resource_client(mux, client, operation).and_then(|()| {
                crate::resource_router::handle_trusted_local_auxiliary(mux, request)
            });
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::ClientList
        | ResourceOperation::ClientGet
        | ResourceOperation::ClientMetadataUpdate
        | ResourceOperation::ClientSizingSet
        | ResourceOperation::ClientSizingRelease
        | ResourceOperation::ClientCellPixelsSet
        | ResourceOperation::TerminalRendererGrantCreate
        | ResourceOperation::TerminalViewerResize
        | ResourceOperation::TerminalViewerRelease
        | ResourceOperation::BrowserViewerResize
        | ResourceOperation::BrowserViewerRelease => {
            let result = handle_resource_connection_control(mux, client, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::ClientDetach => {
            let result = prepare_resource_client_detach(mux, client, &request);
            match result {
                Ok(target) if target == client => {
                    if !send_resource_response(writer, id, operation, Ok(json!({}))) {
                        return false;
                    }
                    false
                }
                Ok(target) => {
                    let result = if disconnect_client(mux, target, true) {
                        Ok(json!({}))
                    } else {
                        Err(ResourceError::not_found(
                            "client",
                            request.selectors.client.as_deref().unwrap_or("<missing>"),
                        ))
                    };
                    send_resource_response(writer, id, operation, result)
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::TerminalAttach => {
            match prepare_terminal_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_attach(mux, client, &start.common);
                        return false;
                    }
                    start_terminal_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::BrowserAttach => {
            match prepare_browser_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_attach(mux, client, &start.common);
                        return false;
                    }
                    start_browser_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SidebarViewAttach => {
            match prepare_sidebar_resource_attach(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        cleanup_resource_stream(mux, client, &start.stream_id);
                        return false;
                    }
                    start_sidebar_resource_attach(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionEvents => {
            match prepare_session_event_stream(mux, client, writer, &request) {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                        return false;
                    }
                    start_session_event_stream(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionJournalProducerList
        | ResourceOperation::SessionJournalProducerPut
        | ResourceOperation::SessionJournalAppend
        | ResourceOperation::SessionJournalHookList
        | ResourceOperation::SessionJournalHookPut
        | ResourceOperation::SessionJournalCheckpointCreate
        | ResourceOperation::SessionJournalCheckpointList
        | ResourceOperation::SessionJournalRestorePreview
        | ResourceOperation::SessionJournalSegmentList
        | ResourceOperation::SessionJournalSegmentSeal => {
            let result = trusted_local_resource_client(mux, client, operation)
                .and_then(|()| handle_journal_extension_request(mux, &request));
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::SessionJournalSubscribe => {
            let prepared = prepare_session_journal_stream(mux, client, writer, &request);
            match prepared {
                Ok((result, start)) => {
                    if !send_resource_response(writer, id, operation, Ok(result)) {
                        let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                        return false;
                    }
                    start_session_journal_stream(mux.clone(), client, writer.clone(), start);
                    true
                }
                Err(error) => send_resource_response(writer, id, operation, Err(error)),
            }
        }
        ResourceOperation::SessionSnapshot => {
            let result = resource_session_snapshot(mux, client, &request.selectors);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::TerminalWait | ResourceOperation::TerminalWaitExit => {
            start_resource_wait(mux.clone(), client, writer.clone(), request, id)
        }
        ResourceOperation::RequestCancel => {
            let result = cancel_resource_request(mux, client, writer, &request);
            send_resource_response(writer, id, operation, result)
        }
        ResourceOperation::StreamCancel => {
            let result = cancel_resource_stream(mux, client, writer, &request);
            send_resource_response(writer, id, operation, result)
        }
        _ => {
            debug_assert!(
                !crate::resource_router::requires_connection_context(request.envelope.operation),
                "connection-owned operation fell through to the transport-independent router"
            );
            match crate::resource_router::handle_parsed_resource_request(mux, request) {
                Ok(response) => writer.send_control(&response).is_ok(),
                Err(error) => {
                    let response =
                        crate::resource_router::malformed_resource_response(message, error);
                    writer.send_control(&response).is_ok()
                }
            }
        }
    }
}

struct ResourceWaitWorkerGuard {
    mux: Arc<Mux>,
    client: u64,
    request_id: ResourceRequestId,
    canceled: Arc<ResourceWaitCancellation>,
}

impl ResourceWaitWorkerGuard {
    fn claim_completion(&self) -> bool {
        self.mux.control_clients.begin_resource_wait_completion(
            self.client,
            &self.request_id,
            &self.canceled,
        )
    }

    fn finish_response_attempt(&self) {
        self.canceled.mark_response_attempted();
        let _ = self.mux.control_clients.finish_resource_wait(
            self.client,
            &self.request_id,
            &self.canceled,
        );
    }
}

impl Drop for ResourceWaitWorkerGuard {
    fn drop(&mut self) {
        let _ = self.mux.control_clients.finish_resource_wait(
            self.client,
            &self.request_id,
            &self.canceled,
        );
        self.canceled.mark_worker_finished();
    }
}

fn resource_wait_runtime_error(error: impl Into<anyhow::Error>) -> ResourceError {
    crate::resource_router::resource_operation_error(error.into())
}

fn resource_wait_timeout(
    request: &crate::resource_router::ParsedResourceRequest,
) -> Option<Duration> {
    request.fields.get("timeout_ms").map(|value| {
        Duration::from_millis(
            serde_json::from_value::<WireDecimal>(value.clone())
                .expect("catalog validates terminal wait timeout")
                .get(),
        )
    })
}

fn resource_wait_stopped(canceled: &ResourceWaitCancellation, writer: &MessageWriter) -> bool {
    canceled.is_canceled() || !writer.is_open()
}

fn run_terminal_resource_wait(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
    canceled: &ResourceWaitCancellation,
) -> Result<Option<Value>, ResourceError> {
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let pattern = request.fields["pattern"].as_str().expect("catalog validates wait pattern");
    let regex = Regex::new(pattern).map_err(|_| {
        ResourceError::validation_invalid(
            None,
            "terminal wait pattern is not a valid regular expression",
        )
    })?;
    let timeout = resource_wait_timeout(request);
    let deadline = timeout
        .map(|timeout| {
            Instant::now().checked_add(timeout).ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("timeout_ms"),
                    "terminal wait timeout exceeds the platform deadline range",
                )
            })
        })
        .transpose()?;
    let check = || -> Result<String, ResourceError> {
        surface
            .try_with_terminal(|terminal| terminal.viewport_text())
            .map_err(resource_wait_runtime_error)?
            .map_err(resource_wait_runtime_error)
    };
    loop {
        if resource_wait_stopped(canceled, writer) {
            return Ok(None);
        }
        // Register every wake source before reading terminal state. Output,
        // cancellation, and connection close therefore share one blocking
        // primitive without a read/wait gap or an idle polling deadline.
        let subscription =
            surface.subscribe_terminal_stream_change().map_err(resource_wait_runtime_error)?;
        let wake = subscription.wake();
        canceled.register(&wake);
        writer.register_wait_wakeup(&wake);
        if resource_wait_stopped(canceled, writer) {
            return Ok(None);
        }
        let text = check()?;
        if regex.is_match(&text) {
            return Ok(Some(json!({"matched":true,"text":text})));
        }
        if timeout == Some(Duration::ZERO) {
            return Ok(Some(json!({"matched":false,"text":text})));
        }

        if !subscription.wait_until(deadline) {
            // Close the output/deadline race with one final authoritative
            // snapshot after the one deadline wake.
            let text = check()?;
            return Ok(Some(json!({
                "matched":regex.is_match(&text),
                "text":text,
            })));
        }
    }
}

fn run_terminal_resource_wait_exit(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
    canceled: &ResourceWaitCancellation,
) -> Result<Option<Value>, ResourceError> {
    let terminal_id =
        crate::resource_router::resolve_terminal_wait_exit_id(mux, &request.selectors)?;
    let timeout = resource_wait_timeout(request);
    let deadline = timeout
        .map(|timeout| {
            Instant::now().checked_add(timeout).ok_or_else(|| {
                resource_wait_runtime_error(anyhow::anyhow!(
                    "terminal exit timeout exceeds deadline range"
                ))
            })
        })
        .transpose()?;
    if resource_wait_stopped(canceled, writer) {
        return Ok(None);
    }
    // Register every wake source before the initial query. A concurrent exit,
    // connection close, or client cleanup therefore cannot strand this wait.
    let subscription = mux.subscribe_terminal_exit(&terminal_id);
    let wake = subscription.wake();
    canceled.register(&wake);
    writer.register_wait_wakeup(&wake);
    if resource_wait_stopped(canceled, writer) {
        return Ok(None);
    }
    let state = mux.terminal_exit_state(&terminal_id).map_err(resource_wait_runtime_error)?;
    if state["state"] == "exited" || timeout == Some(Duration::ZERO) {
        return Ok(Some(state));
    }

    let _explicit_wake = subscription.wait_until(deadline);
    if resource_wait_stopped(canceled, writer) {
        return Ok(None);
    }
    mux.terminal_exit_state(&terminal_id).map(Some).map_err(resource_wait_runtime_error)
}

fn run_resource_wait(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    request: crate::resource_router::ParsedResourceRequest,
    canceled: &ResourceWaitCancellation,
) -> Option<Result<Value, ResourceError>> {
    if canceled.is_canceled() || !writer.is_open() {
        return None;
    }
    let result = match request.envelope.operation {
        ResourceOperation::TerminalWait => {
            run_terminal_resource_wait(mux, writer, &request, canceled)
        }
        ResourceOperation::TerminalWaitExit => {
            run_terminal_resource_wait_exit(mux, writer, &request, canceled)
        }
        _ => unreachable!("only terminal waits use the detached request path"),
    };
    match result {
        Ok(result) => result.map(Ok),
        Err(error) => Some(Err(error)),
    }
}

fn start_resource_wait(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    request: crate::resource_router::ParsedResourceRequest,
    id: crate::resource::RequestId,
) -> bool {
    let operation = request.envelope.operation;
    let name = match operation {
        ResourceOperation::TerminalWait => "terminal.wait",
        ResourceOperation::TerminalWaitExit => "terminal.wait_exit",
        _ => unreachable!("only terminal waits use the detached request path"),
    };
    let (canceled, worker_permit) = match mux.control_clients.install_resource_wait(client, &id) {
        Ok(installed) => installed,
        Err(error) => {
            return send_resource_response(
                &writer,
                id,
                operation,
                Err(resource_wait_install_error(name, error)),
            );
        }
    };
    let worker_writer = writer.clone();
    let worker_mux = mux.clone();
    let worker_canceled = canceled.clone();
    let worker_id = id.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-terminal-wait".into()).spawn(move || {
            let _registration = ResourceWaitWorkerGuard {
                mux: worker_mux.clone(),
                client,
                request_id: worker_id.clone(),
                canceled: worker_canceled.clone(),
            };
            let _worker_permit = worker_permit;
            if let Some(result) =
                run_resource_wait(&worker_mux, &worker_writer, request, &worker_canceled)
                && _registration.claim_completion()
            {
                let _ = send_resource_response(&worker_writer, worker_id, operation, result);
                _registration.finish_response_attempt();
            }
        });
    match spawn {
        Ok(_) => true,
        Err(error) => {
            mux.control_clients.finish_resource_wait(client, &id, &canceled);
            send_resource_response(
                &writer,
                id,
                operation,
                Err(ResourceError::operation_failed(name, error.to_string(), json!({}))),
            )
        }
    }
}

fn handle_resource_connection_control(
    mux: &Arc<Mux>,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    match request.envelope.operation {
        ResourceOperation::ClientList => resource_client_list(mux, client, request),
        ResourceOperation::ClientGet => resource_client_get(mux, client, request),
        ResourceOperation::ClientMetadataUpdate => {
            resource_client_metadata_update(mux, client, request)
        }
        ResourceOperation::ClientSizingSet => resource_client_sizing_set(mux, client, request),
        ResourceOperation::ClientSizingRelease => {
            resource_client_sizing_release(mux, client, request)
        }
        ResourceOperation::ClientCellPixelsSet => {
            resource_client_cell_pixels_set(mux, client, request)
        }
        ResourceOperation::TerminalViewerResize => {
            resource_terminal_viewer_resize(mux, client, request)
        }
        ResourceOperation::TerminalViewerRelease => {
            resource_terminal_viewer_release(mux, client, request)
        }
        ResourceOperation::BrowserViewerResize => {
            resource_browser_viewer_resize(mux, client, request)
        }
        ResourceOperation::BrowserViewerRelease => {
            resource_browser_viewer_release(mux, client, request)
        }
        ResourceOperation::TerminalRendererGrantCreate => {
            resource_terminal_renderer_grant(mux, request)
        }
        operation => unreachable!("connection handler received {operation:?}"),
    }
}

fn resource_session_id(
    mux: &Mux,
    selectors: &crate::ResourceSelectors,
) -> Result<SessionPublicId, ResourceError> {
    let route = crate::ResourceSelectors {
        machine: selectors.machine.clone(),
        session: selectors.session.clone(),
        ..Default::default()
    };
    mux.resolve_resource_path(crate::ResourceTarget::Session, &route)?
        .session
        .ok_or_else(|| ResourceError::not_found("session", "<resolved>"))
}

pub(crate) fn public_client_id(
    session_id: &SessionPublicId,
    client: u64,
) -> Result<ClientPublicId, ResourceError> {
    let mut digest = Sha256::new();
    digest.update(b"cmux.protocol/2/client/");
    digest.update(session_id.as_str().as_bytes());
    digest.update(b"/");
    digest.update(client.to_be_bytes());
    let digest = digest.finalize();
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    ClientPublicId::parse(format!("client_{payload}"))
}

fn resolve_resource_client(
    mux: &Mux,
    requesting_client: u64,
    selectors: &crate::ResourceSelectors,
) -> Result<(u64, SessionPublicId), ResourceError> {
    let session_id = resource_session_id(mux, selectors)?;
    let raw = selectors.client.as_deref().ok_or_else(|| {
        ResourceError::selector_invalid("client", "", "missing required client selector")
    })?;
    let records = mux.control_clients.resource_records();
    let selected = match Selector::parse(raw)? {
        Selector::Current => records
            .iter()
            .any(|record| record.client == requesting_client)
            .then_some(requesting_client),
        Selector::Id(id) => {
            let id = ClientPublicId::parse(id)?;
            records.iter().find_map(|record| {
                public_client_id(&session_id, record.client)
                    .ok()
                    .filter(|candidate| candidate == &id)
                    .map(|_| record.client)
            })
        }
        Selector::Name(name) => {
            let matches = records
                .iter()
                .filter(|record| record.name.as_deref() == Some(name.as_str()))
                .collect::<Vec<_>>();
            if matches.len() > 1 {
                return Err(ResourceError::ambiguous(
                    "client",
                    raw,
                    matches
                        .into_iter()
                        .filter_map(|record| public_client_id(&session_id, record.client).ok())
                        .map(|id| id.to_string())
                        .collect(),
                ));
            }
            matches.first().map(|record| record.client)
        }
    };
    selected
        .map(|selected| (selected, session_id))
        .ok_or_else(|| ResourceError::not_found("client", raw))
}

fn resource_client_snapshot(
    mux: &Mux,
    requesting_client: u64,
    session_id: &SessionPublicId,
    record: &ResourceClientRecord,
) -> Result<Value, ResourceError> {
    let mut attached_terminal_ids = Vec::<TerminalPublicId>::new();
    let mut sizes = Vec::<Value>::new();
    for (surface_id, size) in &record.attached {
        let Some(surface) = mux.surface(*surface_id) else {
            continue;
        };
        let Some(identity) = surface.resource_identity() else {
            continue;
        };
        let ContentPublicId::Terminal(terminal_id) = &identity.content_id else {
            continue;
        };
        attached_terminal_ids.push(terminal_id.clone());
        let (cols, rows) =
            size.map_or((Value::Null, Value::Null), |(cols, rows)| (json!(cols), json!(rows)));
        sizes.push(json!({
            "terminal_id":terminal_id,
            "cols":cols,
            "rows":rows,
            "participating":mux.client_size_participates(*surface_id, record.client),
        }));
    }
    attached_terminal_ids.sort_by(|left, right| left.as_str().cmp(right.as_str()));
    attached_terminal_ids.dedup();
    sizes.sort_by(|left, right| {
        left["terminal_id"]
            .as_str()
            .unwrap_or_default()
            .cmp(right["terminal_id"].as_str().unwrap_or_default())
    });
    Ok(json!({
        "id":public_client_id(session_id, record.client)?,
        "session_id":session_id,
        "name":record.name,
        "client_kind":record.kind,
        "transport":record.transport,
        "connected_seconds":record.connected_seconds.to_string(),
        "attached_terminal_ids":attached_terminal_ids,
        "sizes":sizes,
        "self":record.client == requesting_client,
    }))
}

fn resource_client_list(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resource_session_id(mux, &request.selectors)?;
    Ok(Value::Array(resource_client_snapshots(mux, requesting_client, &session_id)?))
}

fn resource_client_snapshots(
    mux: &Mux,
    requesting_client: u64,
    session_id: &SessionPublicId,
) -> Result<Vec<Value>, ResourceError> {
    let mut clients = mux
        .control_clients
        .resource_records()
        .iter()
        .map(|record| resource_client_snapshot(mux, requesting_client, session_id, record))
        .collect::<Result<Vec<_>, _>>()?;
    clients.sort_by(|left, right| {
        left["id"].as_str().unwrap_or_default().cmp(right["id"].as_str().unwrap_or_default())
    });
    Ok(clients)
}

fn resource_session_snapshot(
    mux: &Mux,
    requesting_client: u64,
    selectors: &crate::ResourceSelectors,
) -> Result<Value, ResourceError> {
    let session_id = resource_session_id(mux, selectors)?;
    let mut snapshot = crate::resource_api::public_session_snapshot(mux)?;
    snapshot["clients"] =
        Value::Array(resource_client_snapshots(mux, requesting_client, &session_id)?);
    Ok(snapshot)
}

fn resource_client_get(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| ResourceError::not_found("client", target.to_string().as_str()))?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

fn resource_client_metadata_update(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let name = request.fields.get("name").map(|value| value.as_str().map(str::to_string));
    let kind = request.fields.get("kind").map(|value| value.as_str().map(str::to_string));
    let (name, kind) = mux.control_clients.set_resource_info(target, name, kind)?;
    mux.emit(MuxEvent::ClientChanged { client: target, name, kind });
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| {
            ResourceError::not_found(
                "client",
                request.selectors.client.as_deref().unwrap_or("<missing>"),
            )
        })?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

fn resource_terminal_surface(
    mux: &Mux,
    selectors: &crate::ResourceSelectors,
) -> Result<(TerminalPublicId, Arc<crate::Surface>), ResourceError> {
    let mut route = selectors.clone();
    route.client = None;
    let terminal_id = mux
        .resolve_resource_path(crate::ResourceTarget::Terminal, &route)?
        .terminal
        .ok_or_else(|| ResourceError::not_found("terminal", "<resolved>"))?;
    let surface_id = mux
        .resource_surface_for_terminal(&terminal_id)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    let surface = mux
        .surface(surface_id)
        .filter(|surface| surface.kind() == SurfaceKind::Pty)
        .ok_or_else(|| ResourceError::not_found("terminal", terminal_id.as_str()))?;
    Ok((terminal_id, surface))
}

fn resource_browser_surface(
    mux: &Mux,
    selectors: &crate::ResourceSelectors,
) -> Result<(BrowserPublicId, Arc<crate::Surface>), ResourceError> {
    let browser_id = mux
        .resolve_resource_path(crate::ResourceTarget::Browser, selectors)?
        .browser
        .ok_or_else(|| ResourceError::not_found("browser", "<resolved>"))?;
    let surface = mux
        .with_state(|state| {
            state
                .single_placement_of_content(&ContentPublicId::Browser(browser_id.clone()))
                .and_then(|surface| state.surfaces.get(&surface))
                .cloned()
        })
        .filter(|surface| surface.kind() == SurfaceKind::Browser)
        .ok_or_else(|| ResourceError::not_found("browser", browser_id.as_str()))?;
    Ok((browser_id, surface))
}

fn resource_client_sizing_set(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "client.sizing.set";
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let enabled =
        request.fields["enabled"].as_bool().expect("catalog validates client sizing enabled");
    let exclusive = request.fields.get("exclusive").and_then(Value::as_bool).unwrap_or(false);
    if exclusive && !enabled {
        return Err(ResourceError::validation_invalid(
            Some("exclusive"),
            "exclusive client sizing must be enabled",
        ));
    }
    let changed = if exclusive {
        mux.use_only_client_size(surface.id, target)
    } else {
        mux.set_client_size_participation(surface.id, target, enabled)
    }
    .ok_or_else(|| {
        ResourceError::operation_failed(
            operation,
            "the selected client has no size lease for the terminal",
            json!({}),
        )
    })?;
    let _ = changed;
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| {
            ResourceError::not_found(
                "client",
                request.selectors.client.as_deref().unwrap_or("<missing>"),
            )
        })?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

fn resource_client_sizing_release(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (target, session_id) = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let attached = mux.control_clients.clear_size(target, surface.id);
    let had_report = mux.client_surface_size(surface.id, target).is_some();
    if had_report {
        mux.remove_surface_size_client(surface.id, target);
    }
    if attached.as_ref().is_some_and(|(changed, _, _)| *changed) || had_report {
        let (name, kind) = attached
            .map(|(_, name, kind)| (name, kind))
            .or_else(|| mux.control_clients.client_info(target))
            .unwrap_or((None, None));
        mux.emit(MuxEvent::ClientChanged { client: target, name, kind });
    }
    let record = mux
        .control_clients
        .resource_records()
        .into_iter()
        .find(|record| record.client == target)
        .ok_or_else(|| {
            ResourceError::not_found(
                "client",
                request.selectors.client.as_deref().unwrap_or("<missing>"),
            )
        })?;
    resource_client_snapshot(mux, requesting_client, &session_id, &record)
}

fn checked_resource_u16(
    operation: &'static str,
    fields: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<u16, ResourceError> {
    let value = fields[field].as_u64().expect("catalog validates integer fields");
    u16::try_from(value).map_err(|_| {
        ResourceError::operation_failed(
            operation,
            format!("{field} exceeds the runtime uint16 limit"),
            json!({"field":field,"value":value}),
        )
    })
}

fn surface_public_content_id(mux: &Mux, surface: SurfaceId) -> Option<String> {
    let surface = mux.surface(surface)?;
    surface.resource_identity().map(|identity| identity.content_id.as_str().to_string())
}

fn resource_client_cell_pixels_set(
    mux: &Arc<Mux>,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "client.cell_pixels.set";
    let _ = resolve_resource_client(mux, requesting_client, &request.selectors)?;
    let width_px = checked_resource_u16(operation, &request.fields, "width_px")?;
    let height_px = checked_resource_u16(operation, &request.fields, "height_px")?;
    let update = mux.set_cell_pixel_size(width_px, height_px);
    let mut resized_terminals = update
        .resizes
        .into_iter()
        .filter_map(|(surface, _, _)| {
            let surface = mux.surface(surface)?;
            let identity = surface.resource_identity()?;
            let ContentPublicId::Terminal(terminal_id) = &identity.content_id else {
                return None;
            };
            Some(terminal_id.clone())
        })
        .collect::<Vec<_>>();
    resized_terminals.sort_by(|left, right| left.as_str().cmp(right.as_str()));
    resized_terminals.dedup();
    let failures = update
        .failures
        .into_iter()
        .filter_map(|failure| {
            surface_public_content_id(mux, failure.surface)
                .map(|id| (id, Value::String(failure.error)))
        })
        .collect::<serde_json::Map<_, _>>();
    Ok(json!({
        "width_px":u32::from(width_px),
        "height_px":u32::from(height_px),
        "resized_terminals":resized_terminals,
        "failures":failures,
    }))
}

fn resource_terminal_viewer_resize(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "terminal.viewer.resize";
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let cols = checked_resource_u16(operation, &request.fields, "cols")?;
    let rows = checked_resource_u16(operation, &request.fields, "rows")?;
    let (cols, rows) = clamp_terminal_size(cols, rows);
    let (accepted, outcome) =
        resize_resource_view(mux, client, surface.id, lease, (cols, rows), operation)?;
    Ok(json!({
        "accepted":accepted,
        "size":{"cols":cols,"rows":rows},
        "outcome":outcome,
    }))
}

fn invalid_resource_view_lease(operation: &'static str) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        "attachment lease is invalid for this resource",
        json!({"reason_code":"invalid_attachment_lease"}),
    )
}

fn resize_resource_view(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    lease: &str,
    size: (u16, u16),
    operation: &'static str,
) -> Result<(bool, &'static str), ResourceError> {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    match mux
        .control_clients
        .view_lease_status(client, surface, lease)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewLeaseStatus::Superseded => return Ok((false, "superseded")),
        ViewLeaseStatus::Current { .. } if !surface_has_view_placement(mux, surface) => {
            return Ok((false, "superseded"));
        }
        ViewLeaseStatus::Current { .. } => {}
    }
    match mux
        .control_clients
        .prepare_view_resize(client, surface, lease, size)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewResizePreparation::Superseded => Ok((false, "superseded")),
        ViewResizePreparation::Passive { .. } => Ok((false, "passive")),
        ViewResizePreparation::GeometryOwner { update, previous_view_size } => {
            let resize = match mux.resize_surface_for_prepared_control_client_with_completion(
                surface,
                client,
                size,
                None,
                Some(update),
            ) {
                Ok(resize) => resize,
                Err(error) => {
                    mux.control_clients.restore_view_size(
                        client,
                        surface,
                        lease,
                        previous_view_size,
                    );
                    if !surface_has_view_placement(mux, surface) {
                        return Ok((false, "superseded"));
                    }
                    return Err(ResourceError::operation_failed(
                        operation,
                        error.to_string(),
                        json!({}),
                    ));
                }
            };
            if let Some((true, name, kind, _)) = resize.attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok((resize.accepted, "applied"))
        }
    }
}

fn release_resource_view(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    lease: &str,
    operation: &'static str,
) -> Result<&'static str, ResourceError> {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    match mux
        .control_clients
        .view_lease_status(client, surface, lease)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewLeaseStatus::Superseded => return Ok("superseded"),
        ViewLeaseStatus::Current { .. } if !surface_has_view_placement(mux, surface) => {
            return Ok("superseded");
        }
        ViewLeaseStatus::Current { .. } => {}
    }
    match mux
        .control_clients
        .release_view_size(client, surface, lease)
        .map_err(|_| invalid_resource_view_lease(operation))?
    {
        ViewReleasePreparation::Superseded => Ok("superseded"),
        ViewReleasePreparation::Passive => Ok("passive"),
        ViewReleasePreparation::GeometryOwner { changed, name, kind } => {
            let had_report = mux.client_surface_size(surface, client).is_some();
            if had_report {
                mux.remove_surface_size_client(surface, client);
            }
            if changed || had_report {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok("applied")
        }
    }
}

fn resource_terminal_viewer_release(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let outcome = release_resource_view(mux, client, surface.id, lease, "terminal.viewer.release")?;
    Ok(json!({"outcome":outcome}))
}

fn browser_cells_for_pixels(mux: &Mux, width_px: u32, height_px: u32) -> (u16, u16) {
    let (cell_width, cell_height) = mux.cell_pixel_size();
    let cols = width_px.div_ceil(u32::from(cell_width.max(1)));
    let rows = height_px.div_ceil(u32::from(cell_height.max(1)));
    clamp_terminal_size(
        u16::try_from(cols).unwrap_or(u16::MAX),
        u16::try_from(rows).unwrap_or(u16::MAX),
    )
}

fn browser_pixels_for_cells(mux: &Mux, cols: u16, rows: u16) -> (u32, u32) {
    let (cell_width, cell_height) = mux.cell_pixel_size();
    (
        u32::from(cols) * u32::from(cell_width.max(1)),
        u32::from(rows) * u32::from(cell_height.max(1)),
    )
}

fn resource_browser_viewer_resize(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "browser.viewer.resize";
    let (_, surface) = resource_browser_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let width_px =
        u32::try_from(request.fields["width_px"].as_u64().expect("catalog validates width_px"))
            .expect("catalog validates uint32");
    let height_px =
        u32::try_from(request.fields["height_px"].as_u64().expect("catalog validates height_px"))
            .expect("catalog validates uint32");
    let (cols, rows) = browser_cells_for_pixels(mux, width_px, height_px);
    let (accepted, outcome) =
        resize_resource_view(mux, client, surface.id, lease, (cols, rows), operation)?;
    let (width_px, height_px) = browser_pixels_for_cells(mux, cols, rows);
    Ok(json!({
        "accepted":accepted,
        "size":{"width_px":width_px,"height_px":height_px},
        "outcome":outcome,
    }))
}

fn resource_browser_viewer_release(
    mux: &Mux,
    client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let (_, surface) = resource_browser_surface(mux, &request.selectors)?;
    let lease =
        request.fields["attachment_lease"].as_str().expect("catalog validates attachment leases");
    let outcome = release_resource_view(mux, client, surface.id, lease, "browser.viewer.release")?;
    Ok(json!({"outcome":outcome}))
}

fn resource_terminal_renderer_grant(
    mux: &Mux,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = "terminal.renderer_grant.create";
    let (terminal_id, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let ttl_ms = request.fields.get("ttl_ms").and_then(Value::as_u64).unwrap_or(30_000);
    let grant = surface.mint_renderer_grant(Duration::from_millis(ttl_ms)).map_err(|error| {
        ResourceError::operation_failed(operation, error.to_string(), json!({}))
    })?;
    Ok(json!({
        "endpoint":grant.endpoint,
        "terminal_id":terminal_id,
        "token":grant.token,
        "rights":["render"],
        "ttl_ms":u32::try_from(ttl_ms).expect("catalog validates renderer grant TTL"),
    }))
}

fn prepare_resource_client_detach(
    mux: &Mux,
    requesting_client: u64,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<u64, ResourceError> {
    resolve_resource_client(mux, requesting_client, &request.selectors).map(|(target, _)| target)
}

struct ResourceSurfaceAttachStart {
    stream_id: StreamPublicId,
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
    surface: SurfaceId,
    lifecycle: AttachLifecycle,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
    client_changed: Option<(Option<String>, Option<String>)>,
}

struct TerminalResourceAttachStart {
    common: ResourceSurfaceAttachStart,
    terminal_id: TerminalPublicId,
    attach: RenderAttachStream,
}

struct BrowserResourceAttachStart {
    common: ResourceSurfaceAttachStart,
    initial: BrowserAttachState,
    frames: BrowserFrameStream,
    snapshot: Value,
}

struct SidebarResourceAttachStart {
    stream_id: StreamPublicId,
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
    attachment: SidebarRenderAttachment,
}

fn resource_stream_id(
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<StreamPublicId, ResourceError> {
    serde_json::from_value(request.fields["stream_id"].clone()).map_err(|_| {
        ResourceError::selector_invalid(
            "stream",
            request.fields["stream_id"].as_str().unwrap_or(""),
            "expected an opaque stream id",
        )
    })
}

fn resource_transport_error(reason: impl Into<String>) -> ResourceError {
    ResourceError::transport_closed(reason)
}

fn resource_stream_install_error(
    operation: &'static str,
    stream_id: &StreamPublicId,
    error: ResourceStreamInstallError,
) -> ResourceError {
    let (reason, reason_code, scope, limit) = match error {
        ResourceStreamInstallError::UnknownClient => {
            ("control connection is no longer registered", "connection_closed", "client", 0)
        }
        ResourceStreamInstallError::Duplicate => (
            "resource stream id is already open on this connection",
            "stream_id_in_use",
            "client",
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
        ),
        ResourceStreamInstallError::ClientCapacity => (
            "resource stream capacity exceeded for this connection",
            "resource_stream_capacity",
            "client",
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
        ),
        ResourceStreamInstallError::ServerCapacity => (
            "resource stream capacity exceeded for this server",
            "resource_stream_capacity",
            "server",
            RESOURCE_STREAMS_SERVER_CAPACITY,
        ),
    };
    ResourceError::operation_failed(
        operation,
        reason,
        json!({
            "reason_code":reason_code,
            "scope":scope,
            "limit":limit,
            "stream_id":stream_id,
        }),
    )
}

fn resource_wait_install_error(
    operation: &'static str,
    error: ResourceWaitInstallError,
) -> ResourceError {
    let (reason, reason_code, scope, limit) = match error {
        ResourceWaitInstallError::UnknownClient => {
            ("control connection is no longer registered", "connection_closed", "client", 0)
        }
        ResourceWaitInstallError::Duplicate => (
            "request id already owns a detached terminal wait on this connection",
            "request_id_in_use",
            "client",
            1,
        ),
        ResourceWaitInstallError::ClientCapacity => (
            "terminal wait capacity exceeded for this connection",
            "terminal_wait_capacity",
            "client",
            RESOURCE_WAITS_PER_CLIENT_CAPACITY,
        ),
        ResourceWaitInstallError::ServerCapacity => (
            "terminal wait capacity exceeded for this server",
            "terminal_wait_capacity",
            "server",
            RESOURCE_WAITS_SERVER_CAPACITY,
        ),
    };
    ResourceError::operation_failed(
        operation,
        reason,
        json!({"reason_code":reason_code,"scope":scope,"limit":limit}),
    )
}

fn register_resource_outbound(
    mux: &Mux,
    client: u64,
    stream_id: &StreamPublicId,
    outbound: &OutboundStream,
    operation: &'static str,
) -> Result<(Arc<AtomicBool>, ResourceWorkerPermit), ResourceError> {
    match mux.control_clients.install_resource_stream(client, stream_id, outbound.clone()) {
        Ok(installed) => Ok(installed),
        Err(error) => {
            outbound.close();
            Err(resource_stream_install_error(operation, stream_id, error))
        }
    }
}

fn install_resource_outbound(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    stream_id: &StreamPublicId,
    operation: &'static str,
) -> Result<(OutboundStream, Arc<AtomicBool>, ResourceWorkerPermit), ResourceError> {
    let overflow =
        resource_stream_end(stream_id, "gap", None, Some("open a fresh attachment stream"), None);
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|error| resource_transport_error(error.to_string()))?;
    let (canceled, worker_permit) =
        register_resource_outbound(mux, client, stream_id, &outbound, operation)?;
    Ok((outbound, canceled, worker_permit))
}

fn prepare_resource_surface_attach(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    operation: &'static str,
    stream_id: StreamPublicId,
    surface: SurfaceId,
    initial_size: Option<(u16, u16)>,
) -> Result<(ResourceSurfaceAttachStart, MarkedClientAttach), ResourceError> {
    let (outbound, canceled, worker_permit) =
        install_resource_outbound(mux, client, writer, &stream_id, operation)?;
    let lifecycle = AttachLifecycle::default();
    let marked =
        match mark_resource_client_attached(mux, client, surface, outbound.clone(), initial_size) {
            Ok(marked) => marked,
            Err(error) => {
                cleanup_resource_stream(mux, client, &stream_id);
                return Err(ResourceError::operation_failed(
                    operation,
                    error.to_string(),
                    json!({}),
                ));
            }
        };
    Ok((
        ResourceSurfaceAttachStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            surface,
            lifecycle,
            size_rollback: marked.size_rollback,
            client_changed: marked.client_changed.clone(),
        },
        marked,
    ))
}

fn cleanup_resource_stream(mux: &Mux, client: u64, stream_id: &StreamPublicId) {
    let _ = mux.control_clients.take_resource_stream(client, stream_id);
}

fn cleanup_resource_attach(mux: &Mux, client: u64, start: &ResourceSurfaceAttachStart) {
    start.lifecycle.cancel();
    cleanup_resource_stream(mux, client, &start.stream_id);
    rollback_failed_attach(mux, client, start.surface, start.outbound.id, start.size_rollback);
}

fn prepare_terminal_resource_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, TerminalResourceAttachStart), ResourceError> {
    let operation = "terminal.attach";
    let (terminal_id, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let initial_size = match (request.fields.get("cols"), request.fields.get("rows")) {
        (Some(cols), Some(rows)) => Some((
            u16::try_from(cols.as_u64().expect("catalog validates terminal attach cols"))
                .expect("catalog validates uint16"),
            u16::try_from(rows.as_u64().expect("catalog validates terminal attach rows"))
                .expect("catalog validates uint16"),
        )),
        (None, None) => None,
        _ => unreachable!("catalog validates paired terminal attach size"),
    };
    let (common, marked) = prepare_resource_surface_attach(
        mux,
        client,
        writer,
        operation,
        stream_id.clone(),
        surface.id,
        initial_size,
    )?;
    let attach = match surface.attach_render_stream() {
        Ok(attach) => attach,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(ResourceError::operation_failed(operation, error.to_string(), json!({})));
        }
    };
    Ok((
        json!({
            "stream_id":stream_id,
            "attachment_lease":marked.lease.expect("resource attach always mints a lease"),
        }),
        TerminalResourceAttachStart { common, terminal_id, attach },
    ))
}

fn terminal_resource_snapshot(
    render_service: &RenderService,
    terminal_id: &TerminalPublicId,
    frame: &SurfaceRenderFrame,
) -> Value {
    let mut render = serde_json::to_value(render_state_message(render_service, 0, frame))
        .expect("render snapshot serializes");
    let render = render.as_object_mut().expect("render snapshot is an object");
    render.remove("event");
    render.remove("surface");
    json!({
        "kind":"snapshot",
        "terminal_id":terminal_id,
        "render":render,
    })
}

fn terminal_resource_patch(
    terminal_id: &TerminalPublicId,
    state: &mut RenderClientState,
    frame: &SurfaceRenderFrame,
) -> Value {
    let mut render =
        serde_json::to_value(state.delta_message(0, frame)).expect("render patch serializes");
    let render = render.as_object_mut().expect("render patch is an object");
    render.remove("event");
    render.remove("surface");
    let full_reset = render.remove("full").expect("render patch contains full");
    render.insert("full_reset".to_string(), full_reset);
    json!({
        "kind":"patch",
        "terminal_id":terminal_id,
        "render":render,
    })
}

fn terminal_resource_scroll(terminal_id: &TerminalPublicId, offset: u64, at_bottom: bool) -> Value {
    json!({
        "kind":"scroll",
        "terminal_id":terminal_id,
        "scroll":{
            "offset":offset.to_string(),
            "at_bottom":at_bottom,
        },
    })
}

fn send_resource_uncursored_stream_item(
    writer: &MessageWriter,
    outbound: &OutboundStream,
    stream_id: &StreamPublicId,
    sequence: u64,
    item: Value,
) -> bool {
    writer
        .send_stream_backpressured(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":stream_id,
                "sequence":sequence.to_string(),
                "item":item,
            }),
            outbound,
        )
        .is_ok()
}

fn finish_resource_surface_attach(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    start: &ResourceSurfaceAttachStart,
    reason: &str,
) {
    if writer.is_open() && start.outbound.is_open() && !start.canceled.load(Ordering::Acquire) {
        let end = resource_stream_end(&start.stream_id, reason, None, None, None);
        let _ = writer.send_terminal(&end, &start.outbound);
    }
    mux.control_clients.finish_resource_stream(client, &start.stream_id, start.outbound.id);
    detach_committed_attach(mux, client, start.surface, start.outbound.id);
}

fn start_terminal_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: TerminalResourceAttachStart,
) {
    let stream_id = start.common.stream_id.clone();
    let outbound = start.common.outbound.clone();
    let surface = start.common.surface;
    let lifecycle = start.common.lifecycle.clone();
    let client_changed = start.common.client_changed.clone();
    let size_rollback = start.common.size_rollback;
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-terminal-attach".into()).spawn(move || {
            if worker_committed.recv().is_err() {
                return;
            }
            let mut sequence = 0u64;
            if !send_resource_uncursored_stream_item(
                &worker_writer,
                &start.common.outbound,
                &start.common.stream_id,
                sequence,
                terminal_resource_snapshot(
                    &worker_writer.render_service,
                    &start.terminal_id,
                    &start.attach.initial,
                ),
            ) {
                finish_resource_surface_attach(
                    &worker_mux,
                    client,
                    &worker_writer,
                    &start.common,
                    "gap",
                );
                return;
            }
            sequence = sequence.saturating_add(1);
            let mut render_state =
                RenderClientState::new(worker_writer.render_service.clone(), &start.attach.initial);
            while worker_writer.is_open()
                && start.common.outbound.is_open()
                && !start.common.canceled.load(Ordering::Acquire)
                && !start.common.lifecycle.is_canceled()
            {
                let item = match start.attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                    Ok(RenderAttachFrame::Frame(frame)) => {
                        terminal_resource_patch(&start.terminal_id, &mut render_state, &frame)
                    }
                    Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                        terminal_resource_scroll(&start.terminal_id, offset, at_bottom)
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &start.common.outbound,
                    &start.common.stream_id,
                    sequence,
                    item,
                ) {
                    break;
                }
                sequence = sequence.saturating_add(1);
            }
            finish_resource_surface_attach(
                &worker_mux,
                client,
                &worker_writer,
                &start.common,
                "closed",
            );
        });
    if let Err(error) = spawn {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh terminal attachment"),
            Some((
                ResourceOperation::TerminalAttach,
                ResourceError::operation_failed("terminal.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        lifecycle.cancel();
        cleanup_resource_stream(&mux, client, &stream_id);
        rollback_failed_attach(&mux, client, surface, outbound.id, size_rollback);
        return;
    }
    if let Err(error) = commit_client_attach_and_start_worker(
        &mux,
        client,
        surface,
        outbound.id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: client_changed,
            size_rollback,
        },
    ) {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh terminal attachment"),
            Some((
                ResourceOperation::TerminalAttach,
                ResourceError::operation_failed("terminal.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        cleanup_resource_stream(&mux, client, &stream_id);
    }
}

fn browser_snapshot_for_id(
    mux: &Mux,
    browser_id: &BrowserPublicId,
) -> Result<Value, ResourceError> {
    crate::resource_api::public_session_snapshot(mux)?["browsers"]
        .as_array()
        .and_then(|browsers| browsers.iter().find(|browser| browser["id"] == browser_id.as_str()))
        .cloned()
        .ok_or_else(|| ResourceError::not_found("browser", browser_id.as_str()))
}

fn prepare_browser_resource_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, BrowserResourceAttachStart), ResourceError> {
    let operation = "browser.attach";
    let (browser_id, surface) = resource_browser_surface(mux, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let initial_size = match (request.fields.get("width_px"), request.fields.get("height_px")) {
        (Some(width), Some(height)) => Some(browser_cells_for_pixels(
            mux,
            u32::try_from(width.as_u64().expect("catalog validates browser attach width"))
                .expect("catalog validates uint32"),
            u32::try_from(height.as_u64().expect("catalog validates browser attach height"))
                .expect("catalog validates uint32"),
        )),
        (None, None) => None,
        _ => unreachable!("catalog validates paired browser attach size"),
    };
    let (common, marked) = prepare_resource_surface_attach(
        mux,
        client,
        writer,
        operation,
        stream_id.clone(),
        surface.id,
        initial_size,
    )?;
    if let Some(reservation) = marked.resize_reservation
        && let Err(error) = wait_for_initial_browser_resize(
            marked
                .resize_completion
                .as_ref()
                .expect("sized browser attach has a completion receiver"),
            surface.id,
            reservation,
        )
    {
        cleanup_resource_attach(mux, client, &common);
        return Err(ResourceError::operation_failed(operation, error.to_string(), json!({})));
    }
    let (initial, frames) = surface.attach_frames().map_err(|error| {
        cleanup_resource_attach(mux, client, &common);
        ResourceError::operation_failed(operation, error.to_string(), json!({}))
    })?;
    let browser = match browser_snapshot_for_id(mux, &browser_id) {
        Ok(browser) => browser,
        Err(error) => {
            cleanup_resource_attach(mux, client, &common);
            return Err(error);
        }
    };
    let (width_px, height_px) = browser_pixels_for_cells(mux, initial.cols, initial.rows);
    let snapshot = json!({
        "kind":"snapshot",
        "browser":browser,
        "size":{"width_px":width_px,"height_px":height_px},
    });
    Ok((
        json!({
            "stream_id":stream_id,
            "attachment_lease":marked.lease.expect("resource attach always mints a lease"),
        }),
        BrowserResourceAttachStart { common, initial, frames, snapshot },
    ))
}

fn browser_resource_state(state: &BrowserAttachState) -> Value {
    json!({
        "kind":"state",
        "url":state.url,
        "title":state.title,
        "loading":matches!(state.status, crate::BrowserStatus::Starting),
    })
}

fn browser_resource_frame(frame: &crate::BrowserFrame, pointer_frame_seq: Option<u64>) -> Value {
    json!({
        "kind":"frame",
        "mime_type":"image/png",
        "data_base64":frame.data_b64,
        "width_px":frame.image_width.max(1),
        "height_px":frame.image_height.max(1),
        "pointer_frame_seq":pointer_frame_seq.map(WireDecimal::new),
    })
}

fn start_browser_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: BrowserResourceAttachStart,
) {
    let stream_id = start.common.stream_id.clone();
    let outbound = start.common.outbound.clone();
    let surface = start.common.surface;
    let lifecycle = start.common.lifecycle.clone();
    let client_changed = start.common.client_changed.clone();
    let size_rollback = start.common.size_rollback;
    let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-browser-attach".into()).spawn(move || {
            if worker_committed.recv().is_err() {
                return;
            }
            let mut sequence = 0u64;
            if !send_resource_uncursored_stream_item(
                &worker_writer,
                &start.common.outbound,
                &start.common.stream_id,
                sequence,
                start.snapshot,
            ) {
                finish_resource_surface_attach(
                    &worker_mux,
                    client,
                    &worker_writer,
                    &start.common,
                    "gap",
                );
                return;
            }
            sequence = sequence.saturating_add(1);
            if let Some(frame) = start.initial.frame.as_ref() {
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &start.common.outbound,
                    &start.common.stream_id,
                    sequence,
                    browser_resource_frame(frame, start.initial.pointer_frame_seq),
                ) {
                    finish_resource_surface_attach(
                        &worker_mux,
                        client,
                        &worker_writer,
                        &start.common,
                        "gap",
                    );
                    return;
                }
                sequence = sequence.saturating_add(1);
            }
            while worker_writer.is_open()
                && start.common.outbound.is_open()
                && !start.common.canceled.load(Ordering::Acquire)
                && !start.common.lifecycle.is_canceled()
            {
                match start.frames.notify.recv_timeout(STREAM_DISCONNECT_POLL) {
                    Ok(()) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
                let update = std::mem::take(&mut *start.frames.slot.lock().unwrap());
                let mut items = Vec::with_capacity(2);
                if let Some(state) = update.state.as_ref() {
                    items.push(browser_resource_state(state));
                }
                if let Some(frame) = update.frame.as_ref() {
                    items.push(browser_resource_frame(&frame.frame, frame.pointer_frame_seq));
                }
                for item in items {
                    if !send_resource_uncursored_stream_item(
                        &worker_writer,
                        &start.common.outbound,
                        &start.common.stream_id,
                        sequence,
                        item,
                    ) {
                        finish_resource_surface_attach(
                            &worker_mux,
                            client,
                            &worker_writer,
                            &start.common,
                            "gap",
                        );
                        return;
                    }
                    sequence = sequence.saturating_add(1);
                }
            }
            finish_resource_surface_attach(
                &worker_mux,
                client,
                &worker_writer,
                &start.common,
                "closed",
            );
        });
    if let Err(error) = spawn {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh browser attachment"),
            Some((
                ResourceOperation::BrowserAttach,
                ResourceError::operation_failed("browser.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        lifecycle.cancel();
        cleanup_resource_stream(&mux, client, &stream_id);
        rollback_failed_attach(&mux, client, surface, outbound.id, size_rollback);
        return;
    }
    if let Err(error) = commit_client_attach_and_start_worker(
        &mux,
        client,
        surface,
        outbound.id,
        AttachWorkerCommit {
            start: worker_start,
            lifecycle,
            changed: client_changed,
            size_rollback,
        },
    ) {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh browser attachment"),
            Some((
                ResourceOperation::BrowserAttach,
                ResourceError::operation_failed("browser.attach", error.to_string(), json!({})),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        cleanup_resource_stream(&mux, client, &stream_id);
    }
}

fn prepare_sidebar_resource_attach(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, SidebarResourceAttachStart), ResourceError> {
    let (sidebar_id, session_id) = resolve_sidebar_view(mux, &request.selectors)?;
    let (status, last_size, configured) = mux.sidebar_plugin_resource_status();
    if !configured {
        return Err(ResourceError::not_found("sidebar_view", sidebar_id.as_str()));
    }
    let surface = status
        .surface
        .and_then(|surface| mux.surface(surface))
        .filter(|surface| surface.kind() == SurfaceKind::Pty && !surface.is_dead())
        .ok_or_else(|| ResourceError::not_found("sidebar_view", sidebar_id.as_str()))?;
    let sidebar = sidebar_snapshot(
        &sidebar_id,
        &session_id,
        last_size.unwrap_or_else(|| surface.size()),
        Some(&surface),
    );
    let attachment = attach_sidebar_render(sidebar_id, sidebar, &surface)?;
    let stream_id = resource_stream_id(request)?;
    let (outbound, canceled, worker_permit) =
        install_resource_outbound(mux, client, writer, &stream_id, "sidebar_view.attach")?;
    Ok((
        json!({"stream_id":stream_id}),
        SidebarResourceAttachStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            attachment,
        },
    ))
}

fn start_sidebar_resource_attach(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SidebarResourceAttachStart,
) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-sidebar-attach".into()).spawn(move || {
            let mut sequence = 0u64;
            if !send_resource_uncursored_stream_item(
                &worker_writer,
                &start.outbound,
                &start.stream_id,
                sequence,
                sidebar_attach_snapshot(&start.attachment),
            ) {
                worker_mux.control_clients.finish_resource_stream(
                    client,
                    &start.stream_id,
                    start.outbound.id,
                );
                return;
            }
            sequence = sequence.saturating_add(1);
            let mut render_state = SidebarRenderClientState::new(&start.attachment.initial);
            while worker_writer.is_open()
                && start.outbound.is_open()
                && !start.canceled.load(Ordering::Acquire)
            {
                let item = match start.attachment.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                    Ok(RenderAttachFrame::Frame(frame)) => {
                        render_state.patch(&start.attachment.sidebar_view_id, &frame)
                    }
                    Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                        SidebarRenderClientState::scroll(
                            &start.attachment.sidebar_view_id,
                            offset,
                            at_bottom,
                        )
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                if !send_resource_uncursored_stream_item(
                    &worker_writer,
                    &start.outbound,
                    &start.stream_id,
                    sequence,
                    item,
                ) {
                    break;
                }
                sequence = sequence.saturating_add(1);
            }
            if worker_writer.is_open()
                && start.outbound.is_open()
                && !start.canceled.load(Ordering::Acquire)
            {
                let end = resource_stream_end(&start.stream_id, "closed", None, None, None);
                let _ = worker_writer.send_terminal(&end, &start.outbound);
            }
            worker_mux.control_clients.finish_resource_stream(
                client,
                &start.stream_id,
                start.outbound.id,
            );
        });
    if let Err(error) = spawn {
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a fresh sidebar attachment"),
            Some((
                ResourceOperation::SidebarViewAttach,
                ResourceError::operation_failed(
                    "sidebar_view.attach",
                    error.to_string(),
                    json!({}),
                ),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
        cleanup_resource_stream(&mux, client, &stream_id);
    }
}

fn send_resource_response(
    writer: &MessageWriter,
    id: ResourceRequestId,
    operation: ResourceOperation,
    result: Result<Value, ResourceError>,
) -> bool {
    let result = crate::resource_router::validate_operation_outcome(operation, result);
    let envelope = match result {
        Ok(result) => ResourceResponseEnvelope::success(id, result),
        Err(error) => ResourceResponseEnvelope::failure(id, error),
    };
    serde_json::to_value(envelope).is_ok_and(|value| writer.send_control(&value).is_ok())
}

fn prepare_session_event_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, SessionEventStreamStart), ResourceError> {
    mux.resolve_resource_path(crate::ResourceTarget::Session, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let epoch = mux.resource_event_epoch();
    let snapshot = resource_session_snapshot(mux, client, &request.selectors)?;
    let snapshot_cursor = snapshot["cursor"].clone();
    let snapshot_generation = snapshot_cursor["generation"]
        .as_str()
        .expect("public snapshot cursor generation")
        .to_string();
    let snapshot_revision = snapshot_cursor["revision"]
        .as_str()
        .and_then(|revision| revision.parse::<u64>().ok())
        .expect("public snapshot cursor revision");
    let requested_cursor = request
        .fields
        .get("cursor")
        .map(|cursor| {
            let generation = cursor["generation"]
                .as_str()
                .ok_or_else(|| {
                    ResourceError::validation_invalid(
                        Some("cursor"),
                        "cursor generation is missing",
                    )
                })?
                .to_string();
            let revision = serde_json::from_value::<WireDecimal>(cursor["revision"].clone())
                .map(WireDecimal::get)
                .map_err(|_| {
                    ResourceError::validation_invalid(Some("cursor"), "cursor revision is invalid")
                })?;
            Ok::<_, ResourceError>((generation, revision))
        })
        .transpose()?;

    let mut initial_items = Vec::new();
    let last_revision;
    let opened_cursor;
    match requested_cursor {
        None => {
            initial_items.push((
                snapshot_cursor.clone(),
                json!({
                    "kind":"snapshot",
                    "cursor":snapshot_cursor,
                    "reset_reason":"initial",
                    "snapshot":snapshot,
                }),
            ));
            last_revision = snapshot_revision;
            opened_cursor = json!({
                "generation":snapshot_generation,
                "revision":snapshot_revision.to_string(),
            });
        }
        Some((generation, _)) if generation != snapshot_generation => {
            initial_items.push((
                snapshot_cursor.clone(),
                json!({
                    "kind":"snapshot",
                    "cursor":snapshot_cursor,
                    "reset_reason":"generation_changed",
                    "snapshot":snapshot,
                }),
            ));
            last_revision = snapshot_revision;
            opened_cursor = json!({
                "generation":snapshot_generation,
                "revision":snapshot_revision.to_string(),
            });
        }
        Some((generation, revision)) => match mux.resource_events_after(revision) {
            Ok(page)
                if page.batches.last().map_or(revision, |batch| batch.revision)
                    < page.head_revision =>
            {
                initial_items.push((
                    snapshot_cursor.clone(),
                    json!({
                        "kind":"snapshot",
                        "cursor":snapshot_cursor,
                        "reset_reason":"cursor_expired",
                        "snapshot":snapshot,
                    }),
                ));
                last_revision = snapshot_revision;
                opened_cursor = json!({
                    "generation":snapshot_generation,
                    "revision":snapshot_revision.to_string(),
                });
            }
            Ok(page) => {
                for batch in page.batches {
                    let cursor = json!({
                        "generation":page.generation,
                        "revision":batch.revision.to_string(),
                    });
                    initial_items.push((
                        cursor.clone(),
                        json!({
                            "kind":"delta",
                            "cursor":cursor,
                            "previous_revision":batch.previous_revision.to_string(),
                            "revision":batch.revision.to_string(),
                            "changes":batch.changes,
                        }),
                    ));
                }
                last_revision = page.head_revision;
                opened_cursor = json!({
                    "generation":page.generation,
                    "revision":page.head_revision.to_string(),
                });
            }
            Err(error) if error.to_string().starts_with("cursor.gap:") => {
                initial_items.push((
                    snapshot_cursor.clone(),
                    json!({
                        "kind":"snapshot",
                        "cursor":snapshot_cursor,
                        "reset_reason":"cursor_expired",
                        "snapshot":snapshot,
                    }),
                ));
                last_revision = snapshot_revision;
                opened_cursor = json!({
                    "generation":snapshot_generation,
                    "revision":snapshot_revision.to_string(),
                });
            }
            Err(error) if error.to_string().starts_with("cursor.invalid:") => {
                return Err(ResourceError::new(
                    "cursor.invalid",
                    "cursor revision is ahead of the session",
                    json!({
                        "requested":{
                            "generation":generation,
                            "revision":revision.to_string(),
                        },
                        "current":snapshot_cursor,
                        "reason":"cursor revision is ahead of the session",
                    }),
                    false,
                ));
            }
            Err(error) => {
                return Err(ResourceError::operation_failed(
                    "session.events",
                    "could not read session event journal",
                    json!({"error":error.to_string()}),
                ));
            }
        },
    }
    let overflow = resource_stream_end(
        &stream_id,
        "gap",
        Some(opened_cursor.clone()),
        Some("request a fresh session snapshot"),
        None,
    );
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|_| ResourceError::transport_closed("could not allocate an outbound stream"))?;
    let (canceled, worker_permit) =
        register_resource_outbound(mux, client, &stream_id, &outbound, "session.events")?;
    Ok((
        json!({"stream_id":stream_id,"cursor":opened_cursor}),
        SessionEventStreamStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            initial_items,
            next_sequence: 0,
            last_revision,
            epoch,
        },
    ))
}

fn start_session_event_stream(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SessionEventStreamStart,
) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn = std::thread::Builder::new()
        .name("mux-resource-session-events".into())
        .spawn(move || run_session_event_stream(&worker_mux, client, &worker_writer, start));
    if spawn.is_err() {
        let _ = mux.control_clients.take_resource_stream(client, &stream_id);
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a new session event stream"),
            Some((
                ResourceOperation::SessionEvents,
                ResourceError::operation_failed(
                    "session.events",
                    "could not start the session event stream",
                    json!({}),
                ),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
    }
}

fn run_session_event_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    mut stream: SessionEventStreamStart,
) {
    for (cursor, item) in stream.initial_items.drain(..) {
        if stream.canceled.load(Ordering::Acquire)
            || !send_resource_stream_item(
                writer,
                &stream.outbound,
                &stream.stream_id,
                stream.next_sequence,
                &cursor,
                item,
            )
        {
            mux.control_clients.finish_resource_stream(
                client,
                &stream.stream_id,
                stream.outbound.id,
            );
            return;
        }
        stream.next_sequence = stream.next_sequence.saturating_add(1);
    }

    'stream: loop {
        if stream.canceled.load(Ordering::Acquire) || !writer.is_open() {
            break;
        }
        let epoch = mux.wait_for_resource_event(stream.epoch, Duration::from_secs(1));
        if epoch == stream.epoch {
            continue;
        }
        stream.epoch = epoch;
        loop {
            let page = match mux.resource_events_after(stream.last_revision) {
                Ok(page) => page,
                Err(error) => {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        None,
                        Some("request a fresh session snapshot"),
                        None,
                    );
                    let _ = error;
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
            };
            let head_revision = page.head_revision;
            if page.batches.is_empty() && stream.last_revision < head_revision {
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    None,
                    Some("request a fresh session snapshot"),
                    None,
                );
                let _ = writer.send_terminal(&end, &stream.outbound);
                break 'stream;
            }
            for batch in page.batches {
                let cursor = json!({
                    "generation":page.generation,
                    "revision":batch.revision.to_string(),
                });
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    Some(cursor.clone()),
                    Some("request a fresh session snapshot"),
                    None,
                );
                let _ = writer.update_stream_overflow(&stream.outbound, &end);
                if stream.canceled.load(Ordering::Acquire)
                    || !send_resource_stream_item(
                        writer,
                        &stream.outbound,
                        &stream.stream_id,
                        stream.next_sequence,
                        &cursor,
                        json!({
                            "kind":"delta",
                            "cursor":cursor,
                            "previous_revision":batch.previous_revision.to_string(),
                            "revision":batch.revision.to_string(),
                            "changes":batch.changes,
                        }),
                    )
                {
                    mux.control_clients.finish_resource_stream(
                        client,
                        &stream.stream_id,
                        stream.outbound.id,
                    );
                    return;
                }
                stream.next_sequence = stream.next_sequence.saturating_add(1);
                stream.last_revision = batch.revision;
            }
            if stream.last_revision >= head_revision {
                break;
            }
        }
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
}

fn journal_cursor(session_id: &SessionPublicId, sequence: u64) -> Value {
    json!({
        "generation":session_id,
        "revision":sequence.to_string(),
    })
}

fn remote_journal_record_value(document: &JournalDocument) -> Value {
    let Value::Object(mut object) = document.wire_value().clone() else {
        return Value::Null;
    };
    object.insert("authority".into(), Value::Null);
    object.insert("causation_id".into(), Value::Null);
    object.insert("correlation_id".into(), Value::Null);
    Value::Object(object)
}

fn handle_journal_extension_request(
    mux: &Arc<Mux>,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resource_session_id(mux, &request.selectors)?;
    let origin = LOCAL_JOURNAL_PRINCIPAL;
    match request.envelope.operation {
        ResourceOperation::SessionJournalProducerList => mux
            .journal_producer_manifests()
            .map(|producers| json!({"producers":producers}))
            .map_err(|error| journal_extension_error("session.journal.producer.list", error)),
        ResourceOperation::SessionJournalProducerPut => {
            let manifest = serde_json::from_value::<crate::JournalProducerManifest>(
                request.fields["manifest"].clone(),
            )
            .map_err(|error| {
                eprintln!("cmux-tui: invalid journal producer manifest: {error}");
                ResourceError::validation_invalid(
                    Some("manifest"),
                    "journal producer manifest is invalid",
                )
            })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.put_journal_producer(&manifest, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "producer_id":manifest.producer_id,
                            "manifest_version":manifest.manifest_version,
                            "namespace":manifest.namespace,
                            "sequence":commit.sequence.to_string(),
                            "event_id":commit.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.sequence.to_string(),
                        "replayed":commit.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.producer.put", error))
        }
        ResourceOperation::SessionJournalAppend => {
            let ingress =
                serde_json::from_value::<crate::JournalIngress>(request.fields["event"].clone())
                    .map_err(|error| {
                        ResourceError::validation_invalid(
                            Some("event"),
                            format!("journal event is invalid: {error}"),
                        )
                    })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.append_journal_ingress(&ingress, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "producer_id":ingress.producer_id,
                            "sequence":commit.sequence.to_string(),
                            "event_id":commit.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.sequence.to_string(),
                        "replayed":commit.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.append", error))
        }
        ResourceOperation::SessionJournalHookList => mux
            .journal_hook_states()
            .map(|hooks| {
                json!({
                    "hooks":hooks.into_iter().map(|hook| json!({
                        "manifest":hook.manifest,
                        "enabled":hook.enabled,
                        "cursor":journal_cursor(&session_id, hook.cursor_sequence),
                    })).collect::<Vec<_>>()
                })
            })
            .map_err(|error| journal_extension_error("session.journal.hook.list", error)),
        ResourceOperation::SessionJournalHookPut => {
            let manifest = serde_json::from_value::<crate::JournalHookManifest>(
                request.fields["manifest"].clone(),
            )
            .map_err(|error| {
                eprintln!("cmux-tui: invalid journal hook manifest: {error}");
                ResourceError::validation_invalid(
                    Some("manifest"),
                    "journal hook manifest is invalid",
                )
            })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.put_journal_hook(&manifest, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "hook_id":manifest.hook_id,
                            "manifest_version":manifest.manifest_version,
                            "sequence":commit.sequence.to_string(),
                            "event_id":commit.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.sequence.to_string(),
                        "replayed":commit.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.hook.put", error))
        }
        ResourceOperation::SessionJournalCheckpointCreate => {
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.create_journal_checkpoint(origin, idempotency_key)
                .map(|commit| {
                    let checkpoint = commit.checkpoint;
                    json!({
                        "value":{
                            "checkpoint_id":checkpoint.checkpoint_id,
                            "source_sequence":checkpoint.source_sequence.to_string(),
                            "reducer_version":checkpoint.reducer_version,
                            "sha256":checkpoint.sha256,
                            "created_at_ms":checkpoint.created_at_ms.to_string(),
                            "content_refs":checkpoint.content_refs,
                            "sequence":commit.journal.sequence.to_string(),
                            "event_id":commit.journal.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.journal.sequence.to_string(),
                        "replayed":commit.journal.replayed,
                    })
                })
                .map_err(|error| {
                    journal_extension_error("session.journal.checkpoint.create", error)
                })
        }
        ResourceOperation::SessionJournalCheckpointList => mux
            .journal_checkpoints()
            .map(|checkpoints| {
                json!({"checkpoints":checkpoints.into_iter().map(|checkpoint| json!({
                    "checkpoint_id":checkpoint.checkpoint_id,
                    "source_sequence":checkpoint.source_sequence.to_string(),
                    "reducer_version":checkpoint.reducer_version,
                    "sha256":checkpoint.sha256,
                    "created_at_ms":checkpoint.created_at_ms.to_string(),
                    "content_refs":checkpoint.content_refs,
                })).collect::<Vec<_>>()})
            })
            .map_err(|error| journal_extension_error("session.journal.checkpoint.list", error)),
        ResourceOperation::SessionJournalRestorePreview => {
            let selector =
                request.fields.get("checkpoint").and_then(Value::as_str).unwrap_or("latest");
            mux.journal_restore_preview(selector)
                .map_err(|error| journal_extension_error("session.journal.restore.preview", error))
        }
        ResourceOperation::SessionJournalSegmentList => mux
            .journal_segments()
            .map(|segments| json!({"segments":segments}))
            .map_err(|error| journal_extension_error("session.journal.segment.list", error)),
        ResourceOperation::SessionJournalSegmentSeal => {
            let through_sequence =
                serde_json::from_value::<WireDecimal>(request.fields["through_sequence"].clone())
                    .map(WireDecimal::get)
                    .map_err(|error| {
                        ResourceError::validation_invalid(
                            Some("through_sequence"),
                            format!("segment through sequence is invalid: {error}"),
                        )
                    })?;
            let idempotency_key = request
                .envelope
                .idempotency_key
                .as_deref()
                .expect("catalog requires mutation idempotency");
            mux.seal_journal_segments(through_sequence, origin, idempotency_key)
                .map(|commit| {
                    json!({
                        "value":{
                            "through_sequence":commit.through_sequence.to_string(),
                            "segments":commit.segments,
                            "sequence":commit.journal.sequence.to_string(),
                            "event_id":commit.journal.event_id,
                        },
                        "generation":session_id,
                        "revision":commit.journal.sequence.to_string(),
                        "replayed":commit.journal.replayed,
                    })
                })
                .map_err(|error| journal_extension_error("session.journal.segment.seal", error))
        }
        _ => unreachable!("journal extension handler received another operation"),
    }
}

fn journal_extension_error(operation: &str, error: anyhow::Error) -> ResourceError {
    let message = error.to_string();
    eprintln!("cmux-tui: {operation} failed: {error:#}");
    if error.downcast_ref::<crate::journal_ingress::JournalCommitIndeterminate>().is_some() {
        // The helper must retry the same idempotency key until SQLite exposes
        // the authoritative result. A non-retryable operation failure would
        // make a later provider invocation allocate a new key and duplicate a
        // commit that completed after the first receipt window.
        return ResourceError::transport_closed(message);
    }
    if message.contains("idempotency key was retried with a different payload") {
        return ResourceError::idempotency_conflict("<redacted>", operation);
    }
    if message.contains("schema")
        || message.contains("manifest")
        || message.contains("namespace")
        || message.contains("producer")
        || message.contains("sensitivity")
        || message.contains("causation")
        || message.contains("payload")
    {
        return ResourceError::validation_invalid(None, "journal request is invalid");
    }
    ResourceError::operation_failed(operation, "journal operation failed", json!({}))
}

fn session_journal_page(
    mux: &Mux,
    reader: Option<&crate::workspace_registry::SessionJournalReader>,
    indexed_subjects: Option<&[JournalSubject]>,
    shared_fanout: bool,
    sequence: u64,
    limit: usize,
) -> anyhow::Result<SharedJournalRead> {
    if let Some(reader) = reader {
        if let Some(subjects) = indexed_subjects {
            let page = reader.after_subjects(sequence, limit, subjects)?;
            return Ok(SharedJournalRead::Page(SharedJournalPage {
                head_sequence: page.head_sequence,
                scanned_through: page.scanned_through,
                records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
            }));
        }
        let page = reader.after(sequence, limit)?;
        let scanned_through =
            page.records.last().map_or(page.head_sequence, |record| record.sequence);
        return Ok(SharedJournalRead::Page(SharedJournalPage {
            head_sequence: page.head_sequence,
            scanned_through,
            records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
        }));
    }
    if shared_fanout {
        return Ok(mux.shared_journal_after(sequence, limit));
    }
    let page = mux.session_journal_after(sequence, limit)?;
    let scanned_through = page.records.last().map_or(page.head_sequence, |record| record.sequence);
    Ok(SharedJournalRead::Page(SharedJournalPage {
        head_sequence: page.head_sequence,
        scanned_through,
        records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
    }))
}

fn prepare_session_journal_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<(Value, SessionJournalStreamStart), ResourceError> {
    let session_id = resource_session_id(mux, &request.selectors)?;
    let stream_id = resource_stream_id(request)?;
    let shared_fanout = mux.shared_journal_enabled();
    let epoch = if shared_fanout { mux.shared_journal_epoch() } else { mux.journal_event_epoch() };
    let head_sequence = mux
        .session_journal_after(0, 1)
        .map_err(|error| {
            eprintln!("cmux-tui: read session journal head: {error:#}");
            ResourceError::operation_failed(
                "session.journal.subscribe",
                "could not read the session journal",
                json!({}),
            )
        })?
        .head_sequence;
    let current_cursor = journal_cursor(&session_id, head_sequence);
    let requested_cursor = request
        .fields
        .get("cursor")
        .map(|cursor| {
            let generation = cursor["generation"].as_str().ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("cursor.generation"),
                    "journal cursor generation is invalid",
                )
            })?;
            let sequence = serde_json::from_value::<WireDecimal>(cursor["revision"].clone())
                .map(WireDecimal::get)
                .map_err(|_| {
                    ResourceError::validation_invalid(
                        Some("cursor.revision"),
                        "journal cursor revision is invalid",
                    )
                })?;
            Ok((generation, sequence))
        })
        .transpose()?;
    let last_sequence = if let Some((generation, sequence)) = requested_cursor {
        if generation != session_id.as_str() || sequence > head_sequence {
            return Err(ResourceError::new(
                "cursor.invalid",
                "journal cursor does not belong to this session position",
                json!({
                    "requested":{
                        "generation":generation,
                        "revision":sequence.to_string(),
                    },
                    "current":current_cursor,
                    "reason":if generation != session_id.as_str() {
                        "cursor belongs to a different session"
                    } else {
                        "cursor sequence is ahead of the journal"
                    },
                }),
                false,
            ));
        }
        sequence
    } else if request.fields.get("start").and_then(Value::as_str) == Some("beginning") {
        0
    } else {
        head_sequence
    };
    let through_sequence = request
        .fields
        .get("follow")
        .and_then(Value::as_bool)
        .is_some_and(|follow| !follow)
        .then_some(head_sequence);
    let reader = if shared_fanout && last_sequence < head_sequence {
        mux.session_journal_reader().map_err(|error| {
            eprintln!("cmux-tui: open session journal catch-up reader: {error:#}");
            ResourceError::operation_failed(
                "session.journal.subscribe",
                "could not open the session journal catch-up reader",
                json!({}),
            )
        })?
    } else {
        None
    };
    let remote_redacted = !mux.control_clients.is_unix(client);
    let mut filter = JournalStreamFilter::parse(request.fields.get("filter"))?;
    if remote_redacted {
        let requested_sensitivity = request
            .fields
            .get("filter")
            .and_then(Value::as_object)
            .and_then(|filter| filter.get("max_sensitivity"));
        if requested_sensitivity.and_then(Value::as_str) == Some("sensitive") {
            return Err(ResourceError::operation_failed(
                "session.journal.subscribe",
                "remote journal subscriptions are limited to metadata sensitivity",
                json!({"maximum_sensitivity":"metadata"}),
            ));
        }
        if filter.regex.as_ref().is_some_and(JournalCompiledRegex::exposes_payload_or_record) {
            return Err(ResourceError::operation_failed(
                "session.journal.subscribe",
                "remote journal regex can match only kind or subjects",
                json!({"allowed_regex_fields":["kind","subjects"]}),
            ));
        }
        filter.max_sensitivity = Some(JournalSensitivity::Metadata);
    }
    let indexed_subjects = filter.indexed_subjects();
    let opened_cursor = journal_cursor(&session_id, last_sequence);
    let overflow = resource_stream_end(
        &stream_id,
        "gap",
        Some(opened_cursor.clone()),
        Some("reconnect with the last journal cursor"),
        None,
    );
    let outbound = writer
        .start_stream(&overflow)
        .map_err(|_| ResourceError::transport_closed("could not allocate an outbound stream"))?;
    let (canceled, worker_permit) = register_resource_outbound(
        mux,
        client,
        &stream_id,
        &outbound,
        "session.journal.subscribe",
    )?;
    Ok((
        json!({"stream_id":stream_id,"cursor":opened_cursor}),
        SessionJournalStreamStart {
            stream_id,
            outbound,
            canceled,
            _worker_permit: worker_permit,
            session_id,
            next_sequence: 0,
            last_sequence,
            through_sequence,
            epoch,
            filter,
            indexed_subjects,
            reader,
            shared_fanout,
            remote_redacted,
        },
    ))
}

fn start_session_journal_stream(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    start: SessionJournalStreamStart,
) {
    let stream_id = start.stream_id.clone();
    let outbound = start.outbound.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let spawn = std::thread::Builder::new()
        .name("mux-resource-session-journal".into())
        .spawn(move || run_session_journal_stream(&worker_mux, client, &worker_writer, start));
    if spawn.is_err() {
        let _ = mux.control_clients.take_resource_stream(client, &stream_id);
        let end = resource_stream_end(
            &stream_id,
            "error",
            None,
            Some("open a new session journal stream"),
            Some((
                ResourceOperation::SessionJournalSubscribe,
                ResourceError::operation_failed(
                    "session.journal.subscribe",
                    "could not start the session journal stream",
                    json!({}),
                ),
            )),
        );
        let _ = writer.send_terminal(&end, &outbound);
    }
}

fn run_session_journal_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    mut stream: SessionJournalStreamStart,
) {
    'stream: loop {
        if stream.canceled.load(Ordering::Acquire) || !writer.is_open() {
            break;
        }
        if complete_bounded_journal_replay(writer, &stream) {
            break;
        }
        loop {
            let page = match session_journal_page(
                mux,
                stream.reader.as_ref(),
                stream.indexed_subjects.as_deref(),
                stream.shared_fanout,
                stream.last_sequence,
                JOURNAL_STREAM_PAGE_SIZE,
            ) {
                Ok(SharedJournalRead::Page(page)) => page,
                Ok(SharedJournalRead::Gap { .. } | SharedJournalRead::Unavailable)
                    if stream.shared_fanout && stream.reader.is_none() =>
                {
                    match mux.session_journal_reader() {
                        Ok(Some(reader)) => {
                            stream.reader = Some(reader);
                            continue;
                        }
                        Ok(None) | Err(_) => {
                            let end = resource_stream_end(
                                &stream.stream_id,
                                "gap",
                                Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                                Some("reconnect with the last journal cursor"),
                                None,
                            );
                            let _ = writer.send_terminal(&end, &stream.outbound);
                            break 'stream;
                        }
                    }
                }
                Ok(SharedJournalRead::Gap { .. } | SharedJournalRead::Unavailable) => {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                        Some("reconnect with the last journal cursor"),
                        None,
                    );
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
                Err(_) => {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                        Some("reconnect with the last journal cursor"),
                        None,
                    );
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
            };
            let head_sequence = page.head_sequence;
            let scanned_through = page.scanned_through;
            if page.records.is_empty() {
                stream.last_sequence = stream.last_sequence.max(
                    stream
                        .through_sequence
                        .map_or(scanned_through, |through| scanned_through.min(through)),
                );
                if complete_bounded_journal_replay(writer, &stream) {
                    break 'stream;
                }
                if stream.last_sequence < head_sequence {
                    let end = resource_stream_end(
                        &stream.stream_id,
                        "gap",
                        Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                        Some("reconnect from a retained journal cursor"),
                        None,
                    );
                    let _ = writer.send_terminal(&end, &stream.outbound);
                    break 'stream;
                }
                if stream.shared_fanout && stream.reader.is_some() {
                    stream.reader = None;
                    stream.epoch = mux.shared_journal_epoch();
                }
                break;
            }
            for document in page.records {
                let record_sequence = document.record.sequence;
                if stream
                    .through_sequence
                    .is_some_and(|through_sequence| record_sequence > through_sequence)
                {
                    stream.last_sequence = stream.through_sequence.expect("presence checked");
                    if complete_bounded_journal_replay(writer, &stream) {
                        break 'stream;
                    }
                }
                if stream.filter.matches(&document) {
                    let cursor = journal_cursor(&stream.session_id, record_sequence);
                    if stream.canceled.load(Ordering::Acquire)
                        || !send_resource_stream_item(
                            writer,
                            &stream.outbound,
                            &stream.stream_id,
                            stream.next_sequence,
                            &cursor,
                            if stream.remote_redacted {
                                remote_journal_record_value(&document)
                            } else {
                                document.wire_value().clone()
                            },
                        )
                    {
                        mux.control_clients.finish_resource_stream(
                            client,
                            &stream.stream_id,
                            stream.outbound.id,
                        );
                        return;
                    }
                    stream.next_sequence = stream.next_sequence.saturating_add(1);
                }
                stream.last_sequence = record_sequence;
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                    Some("reconnect with the last journal cursor"),
                    None,
                );
                let _ = writer.update_stream_overflow(&stream.outbound, &end);
                if complete_bounded_journal_replay(writer, &stream) {
                    break 'stream;
                }
            }
            if scanned_through > stream.last_sequence {
                stream.last_sequence = stream
                    .through_sequence
                    .map_or(scanned_through, |through| scanned_through.min(through));
                let end = resource_stream_end(
                    &stream.stream_id,
                    "gap",
                    Some(journal_cursor(&stream.session_id, stream.last_sequence)),
                    Some("reconnect with the last journal cursor"),
                    None,
                );
                let _ = writer.update_stream_overflow(&stream.outbound, &end);
                if complete_bounded_journal_replay(writer, &stream) {
                    break 'stream;
                }
            }
            if stream.last_sequence >= head_sequence {
                if stream.shared_fanout && stream.reader.is_some() {
                    stream.reader = None;
                    stream.epoch = mux.shared_journal_epoch();
                }
                break;
            }
        }
        loop {
            if stream.canceled.load(Ordering::Acquire) || !writer.is_open() {
                break 'stream;
            }
            let epoch = if stream.shared_fanout && stream.reader.is_none() {
                mux.wait_for_shared_journal(stream.epoch, Duration::from_secs(1))
            } else {
                mux.wait_for_journal_event(stream.epoch, Duration::from_secs(1))
            };
            if epoch != stream.epoch {
                stream.epoch = epoch;
                break;
            }
        }
    }
    mux.control_clients.finish_resource_stream(client, &stream.stream_id, stream.outbound.id);
}

fn complete_bounded_journal_replay(
    writer: &MessageWriter,
    stream: &SessionJournalStreamStart,
) -> bool {
    let Some(through_sequence) = stream.through_sequence else {
        return false;
    };
    if stream.last_sequence < through_sequence {
        return false;
    }
    let end = resource_stream_end(
        &stream.stream_id,
        "completed",
        Some(journal_cursor(&stream.session_id, through_sequence)),
        None,
        None,
    );
    let _ = writer.send_ordered_terminal(&end, &stream.outbound);
    true
}

fn send_resource_stream_item(
    writer: &MessageWriter,
    outbound: &OutboundStream,
    stream_id: &StreamPublicId,
    sequence: u64,
    cursor: &Value,
    item: Value,
) -> bool {
    writer
        .send_stream_backpressured(
            &json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_item",
                "stream_id":stream_id,
                "sequence":sequence.to_string(),
                "cursor":cursor,
                "item":item,
            }),
            outbound,
        )
        .is_ok()
}

fn cancel_resource_stream(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let route = crate::ResourceSelectors {
        machine: request.selectors.machine.clone(),
        session: request.selectors.session.clone(),
        ..Default::default()
    };
    mux.resolve_resource_path(crate::ResourceTarget::Session, &route)?;
    let stream_id: StreamPublicId = request
        .selectors
        .stream
        .as_deref()
        .ok_or_else(|| ResourceError::not_found("stream", "<missing>"))
        .and_then(|stream| StreamPublicId::parse(stream.to_string()))?;
    if let Some(stream) = mux.control_clients.take_resource_stream(client, &stream_id) {
        stream.canceled.store(true, Ordering::Release);
        let end = resource_stream_end(&stream_id, "canceled", None, None, None);
        writer
            .send_terminal(&end, &stream.outbound)
            .map_err(|_| ResourceError::transport_closed("could not end the canceled stream"))?;
    }
    Ok(json!({}))
}

fn cancel_resource_request(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let request_id = ResourceRequestId::parse(
        request.fields["request_id"].as_str().expect("catalog validates request cancellation ids"),
    )?;
    let canceled = match mux.control_clients.cancel_resource_wait(client, &request_id) {
        ResourceWaitCancel::Missing => false,
        ResourceWaitCancel::Canceled(lifecycle) => {
            lifecycle.wait_for_worker_finish();
            true
        }
        ResourceWaitCancel::Completing(lifecycle) => {
            if !lifecycle.wait_for_response_attempt() {
                writer.close();
                return Err(ResourceError::transport_closed(
                    "terminal wait completion ended before attempting its response",
                ));
            }
            false
        }
    };
    Ok(json!({"canceled":canceled}))
}

fn resource_stream_end(
    stream_id: &StreamPublicId,
    reason: &str,
    cursor: Option<Value>,
    recovery: Option<&str>,
    error: Option<(ResourceOperation, ResourceError)>,
) -> Value {
    let mut end = json!({
        "protocol":"cmux.protocol/2",
        "type":"stream_end",
        "stream_id":stream_id,
        "reason":reason,
    });
    if let Some(cursor) = cursor {
        end["cursor"] = cursor;
    }
    if let Some(recovery) = recovery {
        end["recovery"] = json!(recovery);
    }
    if let Some((operation, error)) = error {
        let error = crate::resource_router::validate_operation_error(operation, error);
        end["error"] = json!(error);
    }
    end
}

fn handle_connection_message(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
) -> bool {
    // Keep an idle shutdown requester connected until owner cleanup closes
    // the transport, so lifecycle clients receive authoritative completion.
    // A pipelined message after the acknowledgement must not reach parsing or
    // dispatch; returning false makes the connection loop close that client.
    if mux.daemon_shutdown_requested() {
        return false;
    }
    if crate::resource_router::is_resource_protocol_message(message) {
        return handle_resource_connection_message(mux, client, message, writer);
    }
    let request = match serde_json::from_str::<Request>(message) {
        Ok(request) => request,
        Err(error) => return send_request_error(writer, None, &format!("bad request: {error}")),
    };
    let mut pending = Some(request);
    match scheduler.dispatch(mux.clone(), client, &mut pending, message.len(), writer.clone()) {
        Some(keep_open) => keep_open,
        None => handle_request(mux, client, pending.take().unwrap(), writer),
    }
}

fn handle_request(mux: &Arc<Mux>, client: u64, request: Request, writer: &MessageWriter) -> bool {
    handle_request_with_cancellation(mux, client, request, writer, None)
}

fn handle_request_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    writer: &MessageWriter,
    cancellation: Option<&AtomicBool>,
) -> bool {
    let Request { id, cmd } = request;
    if matches!(&cmd, Command::ShutdownDaemon { .. } | Command::ReloadConfig)
        && !mux.server_lifecycle_ready()
    {
        return send_request_error(writer, id, "server lifecycle is not ready");
    }
    if let Command::VtState { surface } = &cmd {
        return match send_vt_state_command_response(mux, id.clone(), *surface, writer) {
            Ok(()) => true,
            Err(error) => send_request_error(writer, id, &error.to_string()),
        };
    }

    let detach_self = matches!(&cmd, Command::DetachClient { client: target } if *target == client);
    let shutdown_daemon = matches!(&cmd, Command::ShutdownDaemon { .. });
    let response = match handle_command_with_cancellation(mux, client, cmd, writer, cancellation) {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => {
            let error_code = response_error_code(&error);
            let error_delivery =
                error.downcast_ref::<DeliveryClassifiedError>().map(|error| error.delivery);
            Response {
                id,
                ok: false,
                data: None,
                error: Some(error.to_string()),
                error_code,
                error_delivery,
            }
        }
    };
    let response_ok = response.ok;
    let sent = send_response(writer, response);
    // Flush the successful acknowledgement before making the owning loop
    // leave, so process teardown cannot race the response writer.
    if shutdown_daemon && response_ok {
        if sent {
            return complete_daemon_shutdown_after_ack(mux, client, writer);
        } else {
            mux.cancel_daemon_handoff(client);
        }
    }
    if detach_self && response_ok && sent {
        disconnect_client(mux, client, true);
        return false;
    }
    sent
}

fn send_vt_state_command_response(
    mux: &Mux,
    id: Option<Value>,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> anyhow::Result<()> {
    // Reserve the entire wire-frame allowance before copying a replay or
    // starting its base64 encoder. The writer allocates only for actual
    // output and releases unused logical quota before the response is queued.
    let mut output = writer.render_service.reserved_control_writer()?;
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let (cols, rows, replay) = surface.try_with_terminal(|terminal| {
        terminal
            .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
            .map(|replay| (terminal.cols(), terminal.rows(), replay))
    })??;

    write_vt_state_command_json(
        &mut output,
        id.as_ref(),
        cols,
        rows,
        &replay.bytes,
        &replay.kitty_image_aliases,
        replay.kitty_state,
    )?;
    writer.send_serialized_control(output.finish())?;
    Ok(())
}

fn write_vt_state_command_json(
    output: &mut BudgetedJsonWriter,
    id: Option<&Value>,
    cols: u16,
    rows: u16,
    replay: &[u8],
    kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
    kitty_state: KittyReplayState,
) -> std::io::Result<()> {
    output.write_all(b"{")?;
    if let Some(id) = id {
        output.write_all(b"\"id\":")?;
        serde_json::to_writer(&mut *output, id).map_err(json_error_to_io)?;
        output.write_all(b",")?;
    }
    write!(output, "\"ok\":true,\"data\":{{\"cols\":{cols},\"rows\":{rows},\"data\":\"")?;
    {
        let mut encoder = base64::write::EncoderWriter::new(
            &mut *output,
            &base64::engine::general_purpose::STANDARD,
        );
        encoder.write_all(replay)?;
        encoder.finish()?;
    }
    output.write_all(b"\",\"kitty_image_aliases\":")?;
    write_kitty_image_aliases_json(output, kitty_image_aliases)?;
    output.write_all(b",\"kitty_graphics_state\":")?;
    write_kitty_replay_state_json(output, kitty_state)?;
    output.write_all(b"}}")?;
    Ok(())
}

fn response_error_code(error: &anyhow::Error) -> Option<String> {
    error
        .downcast_ref::<crate::LayoutUndoError>()
        .map(|error| error.code().to_string())
        .or_else(|| error.downcast_ref::<LayoutRatioError>().map(|error| error.code().to_string()))
        .or_else(|| {
            error.downcast_ref::<ViewportWidthError>().map(|error| error.code().to_string())
        })
}

fn send_request_error(writer: &MessageWriter, id: Option<Value>, error: &str) -> bool {
    send_request_error_with_delivery(writer, id, error, None)
}

fn send_request_error_with_delivery(
    writer: &MessageWriter,
    id: Option<Value>,
    error: &str,
    error_delivery: Option<ResponseErrorDelivery>,
) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(error.to_string()),
            error_code: None,
            error_delivery,
        },
    )
}

fn send_response(writer: &MessageWriter, response: Response) -> bool {
    serde_json::to_value(response).is_ok_and(|value| writer.send_control(&value).is_ok())
}

fn auth_token(message: &str) -> Option<String> {
    let value: Value = serde_json::from_str(message).ok()?;
    let object = value.as_object()?;
    if object.len() != 1 {
        return None;
    }
    let auth = object.get("auth")?.as_object()?;
    if auth.len() != 1 {
        return None;
    }
    auth.get("token")?.as_str().map(str::to_string)
}

fn pairing_request(message: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(message) else { return false };
    let Some(object) = value.as_object() else { return false };
    if object.len() != 1 {
        return false;
    }
    let Some(pair) = object.get("pair").and_then(Value::as_object) else { return false };
    pair.len() == 1 && pair.get("request").and_then(Value::as_bool) == Some(true)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

fn authorize_provider_workspace_command(mux: &Mux, mut authority: String) -> anyhow::Result<()> {
    let result = mux.authorize_provider_workspace_authority(&authority);
    zeroize_string(&mut authority);
    result
}

fn with_provider_workspace_authority<T>(
    mut authority: String,
    operation: impl FnOnce(&str) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let result = operation(&authority);
    zeroize_string(&mut authority);
    result
}

fn zeroize_string(value: &mut str) {
    // NUL remains valid UTF-8, so decoded control frames can be cleared in
    // place immediately after dispatch.
    value.zeroize();
}

fn node_json(node: &Node, active_pane: PaneId) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { id, dir, ratio, a, b } => json!({
            "type": "split",
            "split": id,
            "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
            "ratio": ratio,
            "a": node_json(a, active_pane),
            "b": node_json(b, active_pane),
        }),
        Node::Stack { panes, expanded } => json!({
            "type": "stack",
            "panes": panes.as_slice(),
            "expanded": if panes.contains(&active_pane) {
                active_pane
            } else {
                *expanded
            },
        }),
    }
}

fn layout_request_to_spec(layout: LayoutRequest) -> anyhow::Result<LayoutSpec> {
    match layout {
        LayoutRequest::Leaf { cwd, command } => {
            Ok(LayoutSpec::Leaf(LayoutLeafSpec { cwd, command }))
        }
        LayoutRequest::Split { dir, ratio, a, b } => Ok(LayoutSpec::Split {
            dir: parse_split_dir(&dir)?,
            ratio,
            a: Box::new(layout_request_to_spec(*a)?),
            b: Box::new(layout_request_to_spec(*b)?),
        }),
        LayoutRequest::Stack { panes, expanded } => {
            if panes.is_empty() {
                anyhow::bail!("stack must contain at least one pane");
            }
            let Some(expanded_index) = panes.iter().position(|pane| *pane == expanded) else {
                anyhow::bail!("stack expanded pane must be a member");
            };
            Ok(LayoutSpec::Stack { pane_count: panes.len(), expanded_index })
        }
    }
}

fn create_surface_with_receipt(
    mux: &Arc<Mux>,
    client: u64,
    request: CreateSurfaceWithReceiptRequest,
) -> anyhow::Result<Value> {
    let CreateSurfaceWithReceiptRequest {
        operation,
        origin,
        receipt,
        idempotency_key,
        selectors: supplied_selectors,
        selector_fallbacks,
        pane,
        workspace,
        argv,
        cwd,
        url,
        width,
        cols,
        rows,
    } = request;
    anyhow::ensure!(
        mux.control_clients.supports_capability(client, CREATION_RECEIPTS_CAPABILITY),
        "client did not negotiate {CREATION_RECEIPTS_CAPABILITY}"
    );
    anyhow::ensure!(
        idempotency_key.is_none()
            || mux.control_clients.supports_capability(client, CREATION_ATTEMPT_KEYS_CAPABILITY),
        "client did not negotiate {CREATION_ATTEMPT_KEYS_CAPABILITY}"
    );
    let mutation =
        WorkspaceMutation::new(idempotency_key.unwrap_or_else(|| receipt.clone()), origin)?;
    let size = paired_surface_size("create-surface-with-receipt", cols, rows)?;
    let mut fields = serde_json::Map::new();
    if let Some((cols, rows)) = size {
        fields.insert("cols".to_string(), json!(cols));
        fields.insert("rows".to_string(), json!(rows));
    }
    fields.insert("correlation_key".to_string(), json!(receipt));
    let session_selectors = || crate::ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..crate::ResourceSelectors::default()
    };
    let pane_selectors = |pane| {
        supplied_selectors.clone().map(Ok).unwrap_or_else(|| mux.resource_selectors_for_pane(pane))
    };
    let workspace_selectors = |workspace| {
        supplied_selectors
            .clone()
            .map(Ok)
            .unwrap_or_else(|| mux.resource_selectors_for_workspace(workspace))
    };
    let (resource_operation, selectors) = match operation.as_str() {
        "new-tab" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && url.is_none() && width.is_none(),
                "new-tab received fields that belong to another creation operation"
            );
            if let Some(cwd) = cwd {
                fields.insert("cwd".to_string(), json!(cwd));
            }
            (ResourceOperation::TabCreateTerminal, pane_selectors(pane)?)
        }
        "run-command" => {
            anyhow::ensure!(
                workspace.is_none() && url.is_none() && width.is_none(),
                "run-command received fields that belong to another creation operation"
            );
            let argv = argv
                .filter(|argv| !argv.is_empty())
                .ok_or_else(|| anyhow::anyhow!("run-command omitted argv"))?;
            fields.insert("argv".to_string(), json!(argv));
            if let Some(cwd) = cwd {
                fields.insert("cwd".to_string(), json!(cwd));
            }
            (ResourceOperation::PaneRun, pane_selectors(pane)?)
        }
        "new-browser-tab" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && cwd.is_none() && width.is_none(),
                "new-browser-tab received fields that belong to another creation operation"
            );
            let url = url
                .filter(|url| !url.is_empty())
                .ok_or_else(|| anyhow::anyhow!("browser creation omitted URL"))?;
            fields.insert("url".to_string(), json!(url));
            if let Some((cols, rows)) = size {
                let (cell_width, cell_height) = mux.cell_pixel_size();
                fields.remove("cols");
                fields.remove("rows");
                fields
                    .insert("width_px".to_string(), json!(u64::from(cols) * u64::from(cell_width)));
                fields.insert(
                    "height_px".to_string(),
                    json!(u64::from(rows) * u64::from(cell_height)),
                );
            }
            (ResourceOperation::TabCreateBrowser, pane_selectors(pane)?)
        }
        "new-workspace" => {
            anyhow::ensure!(
                pane.is_none()
                    && workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-workspace received fields that belong to another creation operation"
            );
            fields.insert("initial_content".to_string(), json!("terminal"));
            (
                ResourceOperation::WorkspaceCreate,
                supplied_selectors.clone().unwrap_or_else(session_selectors),
            )
        }
        "new-screen" => {
            anyhow::ensure!(
                pane.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-screen received fields that belong to another creation operation"
            );
            (ResourceOperation::ScreenCreate, workspace_selectors(workspace)?)
        }
        "new-pane" => {
            anyhow::ensure!(
                workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "new-pane received fields that belong to another creation operation"
            );
            (ResourceOperation::PaneCreate, pane_selectors(pane)?)
        }
        "new-pane-right" => {
            anyhow::ensure!(
                workspace.is_none() && argv.is_none() && cwd.is_none() && url.is_none(),
                "new-pane-right received fields that belong to another creation operation"
            );
            let width =
                width.ok_or_else(|| anyhow::anyhow!("new-pane-right omitted viewport width"))?;
            fields.insert("direction".to_string(), json!("right"));
            fields.insert("viewport_width".to_string(), json!(width));
            (ResourceOperation::PaneSplit, pane_selectors(pane)?)
        }
        "split-right" | "split-down" => {
            anyhow::ensure!(
                workspace.is_none()
                    && argv.is_none()
                    && cwd.is_none()
                    && url.is_none()
                    && width.is_none(),
                "split creation received fields that belong to another creation operation"
            );
            fields.insert(
                "direction".to_string(),
                json!(if operation == "split-right" { "right" } else { "down" }),
            );
            (ResourceOperation::PaneSplit, pane_selectors(pane)?)
        }
        other => anyhow::bail!("unknown receipted creation operation {other:?}"),
    };
    anyhow::ensure!(
        selector_fallbacks.len() <= MAX_CREATION_SELECTOR_FALLBACKS,
        "creation accepts at most {MAX_CREATION_SELECTOR_FALLBACKS} selector fallbacks"
    );
    anyhow::ensure!(
        selector_fallbacks.is_empty()
            || mux
                .control_clients
                .supports_capability(client, CREATION_SELECTOR_FALLBACKS_CAPABILITY),
        "client did not negotiate {CREATION_SELECTOR_FALLBACKS_CAPABILITY}"
    );
    anyhow::ensure!(
        selector_fallbacks.is_empty()
            || matches!(
                resource_operation,
                ResourceOperation::PaneSplit
                    | ResourceOperation::PaneCreate
                    | ResourceOperation::PaneRun
                    | ResourceOperation::TabCreateTerminal
                    | ResourceOperation::TabCreateBrowser
            ),
        "selector fallbacks require a pane-targeted creation"
    );
    let mut selector_candidates = Vec::with_capacity(1 + selector_fallbacks.len());
    selector_candidates.push(selectors);
    for fallback in selector_fallbacks {
        if !selector_candidates.contains(&fallback) {
            selector_candidates.push(fallback);
        }
    }
    let (surface, replayed) =
        mux.receipted_surface_creation(resource_operation, selector_candidates, fields, &mutation)?;
    Ok(json!({"surface": surface, "replayed": replayed}))
}

fn parse_split_dir(dir: &str) -> anyhow::Result<SplitDir> {
    match dir {
        "right" => Ok(SplitDir::Right),
        "down" => Ok(SplitDir::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"right\" or \"down\")"),
    }
}

fn optional_surface_size(cols: Option<u16>, rows: Option<u16>) -> Option<(u16, u16)> {
    cols.zip(rows).map(|(cols, rows)| (cols.max(1), rows.max(1)))
}

fn paired_surface_size(
    command: &str,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Option<(u16, u16)>> {
    match (cols, rows) {
        (Some(cols), Some(rows)) => Ok(Some((cols.max(1), rows.max(1)))),
        (None, None) => Ok(None),
        _ => anyhow::bail!("{command} cols and rows must be supplied together"),
    }
}

fn default_renderer_capability_ttl_ms() -> u64 {
    30_000
}

fn workspace_mutation(request: &MutationRequest) -> anyhow::Result<WorkspaceMutation> {
    match (&request.mutation_id, &request.origin) {
        (Some(id), Some(origin)) => WorkspaceMutation::new(id.clone(), origin.clone()),
        (None, None) => Ok(WorkspaceMutation::local("legacy-control")),
        _ => anyhow::bail!("origin and mutation_id must be provided together"),
    }
}

fn parse_direction(dir: &str) -> anyhow::Result<Direction> {
    match dir {
        "left" => Ok(Direction::Left),
        "right" => Ok(Direction::Right),
        "up" => Ok(Direction::Up),
        "down" => Ok(Direction::Down),
        other => anyhow::bail!("bad dir {other:?} (want \"left\", \"right\", \"up\", or \"down\")"),
    }
}

fn parse_zoom_mode(mode: Option<String>) -> anyhow::Result<ZoomMode> {
    match mode.as_deref().unwrap_or("toggle") {
        "toggle" => Ok(ZoomMode::Toggle),
        "on" => Ok(ZoomMode::On),
        "off" => Ok(ZoomMode::Off),
        other => anyhow::bail!("bad mode {other:?} (want \"toggle\", \"on\", or \"off\")"),
    }
}

fn export_layout_json(state: &State, screen_id: Option<ScreenId>) -> anyhow::Result<Value> {
    let screen = match screen_id {
        Some(id) => state
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .find(|screen| screen.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown screen {id}"))?,
        None => state
            .workspaces
            .get(state.active_workspace)
            .and_then(|ws| ws.active_screen_ref())
            .ok_or_else(|| anyhow::anyhow!("no active screen"))?,
    };
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    let mut value = json!({
        "layout": node_json(&screen.root, screen.active_pane),
        "panes": pane_ids.iter().map(|pane_id| {
            let surfaces = state
                .panes
                .get(pane_id)
                .map(|pane| pane.tabs.clone())
                .unwrap_or_default();
            json!({ "pane": pane_id, "surfaces": surfaces })
        }).collect::<Vec<_>>(),
    });
    if !screen.viewport_splits.is_empty() {
        value["viewport_splits"] = json!(
            screen
                .viewport_splits
                .iter()
                .map(|(split, width)| json!({"split": split, "width": width}))
                .collect::<Vec<_>>()
        );
        if let Some(width) = screen.viewport_base_width {
            value["viewport_base_width"] = json!(width);
        }
    }
    Ok(value)
}

fn pane_json(
    state: &State,
    id: PaneId,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let Some(pane) = state.panes.get(&id) else {
        return json!({ "id": id, "dead": true });
    };
    json!({
        "id": id,
        "resource_id": state.resource_indexes.pane_ids.get(&id),
        "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
        "name": pane.name,
        "active_tab": pane.active_tab,
        "focused_at": pane.focused_at,
        "tabs": pane.tabs.iter().map(|sid| {
            let surface = state.surfaces.get(sid);
            let terminal_identity = surface.and_then(|surface| surface.terminal_host_identity());
            let terminal_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .and_then(|identity| match &identity.content_id {
                    ContentPublicId::Terminal(id) => Some(id),
                    ContentPublicId::Browser(_) => None,
                });
            let tab_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .map(|identity| &identity.tab_id);
            let content_resource_id = surface
                .and_then(|surface| surface.resource_identity())
                .map(|identity| identity.content_id.as_str());
            json!({
                "surface": sid,
                "tab_resource_id": tab_resource_id,
                "content_resource_id": content_resource_id,
                "terminal_id": terminal_identity.as_ref().map(|identity| &identity.terminal_id),
                "terminal_resource_id": terminal_resource_id,
                "terminal_incarnation": terminal_identity
                    .as_ref()
                    .map(|identity| &identity.incarnation),
                "short_id": short_ids.get(sid).cloned().unwrap_or_default(),
                "kind": surface.map(|s| s.kind().as_str()).unwrap_or("pty"),
                "browser_source": surface.and_then(|s| s.browser_source().map(|source| source.as_str())),
                "browser_status": surface.and_then(|s| s.browser_status().map(|status| status.as_str())),
                "browser_error": surface.and_then(|s| s.browser_status().and_then(|status| status.error())),
                "browser_frames_stalled": surface.and_then(|s| s.browser_frames_stalled()),
                "url": surface.and_then(|s| s.browser_url()),
                "supports_clear_history_key_fallback": surface
                    .is_some_and(|surface| surface.supports_clear_history_key_fallback()),
                "notification": notifications.get(sid).copied().map(|n| {
                    json!({
                        "notification": n.notification,
                        "unread": n.unread,
                        "level": n.level.as_str(),
                    })
                }),
                "name": surface.and_then(|s| s.name()),
                "title": surface.map(|s| s.title()).unwrap_or_default(),
                "size": surface.map(|s| {
                    let (c, r) = s.size();
                    json!({"cols": c, "rows": r})
                }),
                "dead": surface.map(|s| s.is_dead()).unwrap_or(true),
            })
        }).collect::<Vec<_>>(),
    })
}

fn screen_json(
    state: &State,
    screen: &Screen,
    active: bool,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    let mut value = json!({
        "id": screen.id,
        "resource_id": screen.public_id,
        "short_id": short_ids.get(&screen.id).cloned().unwrap_or_default(),
        "name": screen.name,
        "active": active,
        "active_pane": screen.active_pane,
        "zoomed_pane": screen.zoomed_pane,
        "layout": node_json(&screen.root, screen.active_pane),
        "panes": pane_ids.iter().map(|id| pane_json(state, *id, short_ids, notifications)).collect::<Vec<_>>(),
    });
    if !screen.viewport_splits.is_empty() {
        value["viewport_splits"] = json!(
            screen
                .viewport_splits
                .iter()
                .map(|(split, width)| json!({"split": split, "width": width}))
                .collect::<Vec<_>>()
        );
        if let Some(width) = screen.viewport_base_width {
            value["viewport_base_width"] = json!(width);
        }
    }
    if screen.layout_columns_active() {
        value["columns"] = json!(
            screen
                .layout_columns
                .iter()
                .map(|column| {
                    json!({
                        "id": column.id,
                        "width": column.width,
                        "layout": node_json(&column.root, screen.active_pane),
                    })
                })
                .collect::<Vec<_>>()
        );
    }
    value
}

fn workspaces_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    let short_ids = tree_short_ids(state);
    json!({
        "workspace_revision": state.workspace_revision,
        "pane_revision": state.pane_revision,
        "workspaces": state.workspaces.iter().enumerate().map(|(index, workspace)| {
            workspace_json(state, workspace, index, &short_ids, notifications)
        }).collect::<Vec<_>>(),
    })
}

fn tree_short_ids(state: &State) -> HashMap<u64, String> {
    let ids = state
        .workspaces
        .iter()
        .flat_map(|ws| {
            let mut ids = vec![ws.id];
            for screen in &ws.screens {
                ids.push(screen.id);
                screen.root.pane_ids(&mut ids);
            }
            ids
        })
        .chain(state.surfaces.keys().copied());
    assign_short_ids(ids)
}

fn workspace_json(
    state: &State,
    workspace: &Workspace,
    index: usize,
    short_ids: &HashMap<u64, String>,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> Value {
    json!({
        "id": workspace.id,
        "resource_id": workspace.public_id,
        "key": workspace.key,
        "short_id": short_ids.get(&workspace.id).cloned().unwrap_or_default(),
        "name": workspace.name,
        "active": index == state.active_workspace,
        "screens": workspace.screens.iter().enumerate().map(|(screen_index, screen)| {
            screen_json(
                state,
                screen,
                screen_index == workspace.active_screen,
                short_ids,
                notifications,
            )
        }).collect::<Vec<_>>(),
    })
}

pub(crate) fn tree_entity_json(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
    kind: TreeDeltaKind,
    id: u64,
) -> Option<Value> {
    if matches!(
        kind,
        TreeDeltaKind::WorkspaceAdded
            | TreeDeltaKind::WorkspaceClosed
            | TreeDeltaKind::WorkspaceRenamed
            | TreeDeltaKind::WorkspaceMoved
    ) {
        let short_ids = tree_short_ids(state);
        let index = state.workspace_index(id)?;
        let workspace = state.workspaces.get(index)?;
        return Some(workspace_json(state, workspace, index, &short_ids, notifications));
    }
    let tree = workspaces_json(state, notifications);
    let workspaces = tree.get("workspaces")?.as_array()?;
    match kind {
        TreeDeltaKind::WorkspaceAdded
        | TreeDeltaKind::WorkspaceClosed
        | TreeDeltaKind::WorkspaceRenamed
        | TreeDeltaKind::WorkspaceMoved => unreachable!("workspace deltas returned above"),
        TreeDeltaKind::ScreenAdded | TreeDeltaKind::ScreenClosed | TreeDeltaKind::ScreenRenamed => {
            workspaces
                .iter()
                .flat_map(|workspace| {
                    workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
                })
                .find(|screen| screen.get("id").and_then(Value::as_u64) == Some(id))
                .cloned()
        }
        TreeDeltaKind::PaneAdded | TreeDeltaKind::PaneClosed => workspaces
            .iter()
            .flat_map(|workspace| {
                workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
            })
            .flat_map(|screen| screen.get("panes").and_then(Value::as_array).into_iter().flatten())
            .find(|pane| pane.get("id").and_then(Value::as_u64) == Some(id))
            .cloned(),
        TreeDeltaKind::TabAdded | TreeDeltaKind::TabClosed | TreeDeltaKind::TabRenamed => {
            workspaces
                .iter()
                .flat_map(|workspace| {
                    workspace.get("screens").and_then(Value::as_array).into_iter().flatten()
                })
                .flat_map(|screen| {
                    screen.get("panes").and_then(Value::as_array).into_iter().flatten()
                })
                .flat_map(|pane| pane.get("tabs").and_then(Value::as_array).into_iter().flatten())
                .find(|tab| tab.get("surface").and_then(Value::as_u64) == Some(id))
                .cloned()
        }
    }
}

fn tree_delta_json(delta: &TreeDelta, mux: &Mux) -> Value {
    let mut value = json!({
        "event": delta.kind.as_str(),
        "workspace": delta.workspace,
        "entity": delta.entity,
    });
    if let Some(screen) = delta.screen {
        value["screen"] = json!(screen);
    }
    if let Some(pane) = delta.pane {
        value["pane"] = json!(pane);
    }
    if let Some(surface) = delta.surface {
        value["surface"] = json!(surface);
    }
    if let Some(index) = delta.index {
        value["index"] = json!(index);
    }
    if let Some(revision) = delta.workspace_revision {
        value["workspace_revision"] = json!(revision);
        if let Ok(Some(event)) = mux.workspace_registry_event(revision) {
            value["origin"] = json!(event.origin);
            value["mutation_id"] = json!(event.mutation_id);
        }
        let (registry_id, generation) = mux.registry_identity();
        value["registry_id"] = json!(registry_id);
        value["generation"] = json!(generation);
    }
    value
}

fn ids_json(state: &State, kind: Option<&str>) -> anyhow::Result<Value> {
    let allowed = ["workspace", "screen", "pane", "surface"];
    if let Some(kind) = kind
        && !allowed.contains(&kind)
    {
        anyhow::bail!("bad kind {kind}");
    }
    let mut raw = Vec::new();
    for ws in &state.workspaces {
        raw.push(("workspace", ws.id));
        for screen in &ws.screens {
            raw.push(("screen", screen.id));
            let mut panes = Vec::new();
            screen.root.pane_ids(&mut panes);
            for pane in panes {
                raw.push(("pane", pane));
            }
        }
    }
    raw.extend(state.surfaces.keys().copied().map(|id| ("surface", id)));
    let short_ids = assign_short_ids(raw.iter().map(|(_, id)| *id));
    Ok(json!({
        "ids": raw
            .into_iter()
            .filter(|(item_kind, _)| kind.is_none_or(|kind| kind == *item_kind))
            .map(|(kind, id)| json!({
                "kind": kind,
                "id": id,
                "short_id": short_ids.get(&id).cloned().unwrap_or_default(),
            }))
            .collect::<Vec<_>>()
    }))
}

fn get_surface(mux: &Mux, id: SurfaceId) -> anyhow::Result<Arc<crate::Surface>> {
    mux.surface(id)
        .filter(|surface| !surface.is_dead())
        .ok_or_else(|| anyhow::anyhow!("unknown surface {id}"))
}

fn surface_has_view_placement(mux: &Mux, id: SurfaceId) -> bool {
    mux.with_state(|state| state.pane_of(id).is_some())
}

fn resolve_workspace(
    mux: &Mux,
    id: Option<WorkspaceId>,
    key: Option<&str>,
) -> anyhow::Result<(WorkspaceId, String)> {
    mux.with_state(|state| {
        let by_id = id.and_then(|id| state.workspace_by_id(id));
        let by_key = key.and_then(|key| state.workspace_by_key(key));
        let workspace = match (id, key, by_id, by_key) {
            (None, None, _, _) => anyhow::bail!("workspace or key is required"),
            (Some(id), None, Some(workspace), _) if workspace.id == id => workspace,
            (Some(id), None, None, _) => anyhow::bail!("unknown workspace {id}"),
            (None, Some(key), _, Some(workspace)) if workspace.key == key => workspace,
            (None, Some(key), _, None) => anyhow::bail!("unknown workspace key {key}"),
            (Some(_), Some(_), Some(by_id), Some(by_key)) if by_id.id == by_key.id => by_id,
            (Some(_), Some(_), _, _) => {
                anyhow::bail!("workspace id and key do not identify the same workspace")
            }
            _ => unreachable!("workspace selector cases are exhaustive"),
        };
        Ok((workspace.id, workspace.key.clone()))
    })
}

fn sidebar_plugin_status_json(status: SidebarPluginStatus) -> Value {
    let retry_after_ms = status.retry_after.map(|duration| duration.as_millis() as u64);
    json!({
        "surface": status.surface,
        "error": status.error,
        "retry_after_ms": retry_after_ms,
    })
}

fn require_pty(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Pty {
        Ok(())
    } else {
        anyhow::bail!("browser surface does not support PTY/VT socket commands")
    }
}

fn require_browser(surface: &crate::Surface) -> anyhow::Result<()> {
    if surface.kind() == SurfaceKind::Browser {
        Ok(())
    } else {
        anyhow::bail!("PTY surface is not a browser surface")
    }
}

fn browser_provider_registration(
    provider_id: String,
    endpoint: String,
    authentication: String,
    bearer_token: Option<String>,
    targets: Vec<BrowserProviderTargetRequest>,
) -> anyhow::Result<BrowserProviderRegistration> {
    anyhow::ensure!(
        !provider_id.is_empty()
            && provider_id.len() <= 128
            && provider_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-._:".contains(&byte)),
        "browser provider id must contain 1..128 ASCII identifier characters"
    );
    anyhow::ensure!(endpoint.len() <= 2_048, "browser provider endpoint is too long");
    let parsed = url::Url::parse(&endpoint).context("invalid browser provider endpoint")?;
    anyhow::ensure!(parsed.scheme() == "ws", "browser provider endpoint must use ws://");
    anyhow::ensure!(
        parsed.username().is_empty() && parsed.password().is_none(),
        "browser provider endpoint must not contain URL credentials"
    );
    anyhow::ensure!(parsed.port().is_some(), "browser provider endpoint must include a port");
    anyhow::ensure!(
        parsed.fragment().is_none(),
        "browser provider endpoint must not have a fragment"
    );
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("browser provider endpoint must include a host"))?;
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host.parse::<std::net::IpAddr>().is_ok_and(|address| address.is_loopback());
    anyhow::ensure!(
        loopback,
        "browser provider endpoint must be loopback; use an authenticated local gateway"
    );

    let authentication = match authentication.as_str() {
        "none" => {
            anyhow::ensure!(
                bearer_token.is_none(),
                "bearer_token is only valid with bearer authentication"
            );
            BrowserProviderAuthentication::None
        }
        "bearer" => {
            let token = bearer_token
                .filter(|token| !token.is_empty())
                .ok_or_else(|| anyhow::anyhow!("bearer authentication requires bearer_token"))?;
            anyhow::ensure!(
                token.len() <= 4_096 && token.bytes().all(|byte| byte.is_ascii_graphic()),
                "browser provider bearer token must contain 1..4096 visible ASCII characters"
            );
            BrowserProviderAuthentication::Bearer(token)
        }
        other => anyhow::bail!("unsupported browser provider authentication {other:?}"),
    };

    anyhow::ensure!(targets.len() <= 16_384, "too many browser provider targets");
    let mut parsed_targets = BTreeMap::new();
    for target in targets {
        let tab_id =
            TabPublicId::parse(target.tab_id).context("invalid browser provider tab_id")?;
        anyhow::ensure!(
            !target.target_id.is_empty()
                && target.target_id.len() <= 512
                && !target.target_id.chars().any(char::is_control),
            "browser provider target_id must contain 1..512 non-control characters"
        );
        anyhow::ensure!(
            parsed_targets.insert(tab_id, target.target_id).is_none(),
            "duplicate browser provider tab_id"
        );
    }
    Ok(BrowserProviderRegistration {
        provider_id,
        endpoint: parsed.to_string(),
        authentication,
        targets: parsed_targets,
    })
}

fn browser_provider_json(snapshot: Option<BrowserProviderSnapshot>) -> Value {
    let Some(snapshot) = snapshot else {
        return json!({"available":false,"revision":0,"targets":[]});
    };
    let targets = snapshot
        .targets
        .into_iter()
        .map(|(tab_id, target_id)| json!({"tab_id":tab_id,"target_id":target_id}))
        .collect::<Vec<_>>();
    json!({
        "available":true,
        "provider_id":snapshot.provider_id,
        "endpoint":snapshot.endpoint,
        "authentication":snapshot.authentication.name(),
        "revision":snapshot.revision,
        "clients":snapshot.clients,
        "targets":targets,
    })
}

fn handle_browser_frame_presented(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    frame_seq: u64,
) -> anyhow::Result<Value> {
    if !mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY) {
        anyhow::bail!(
            "browser frame presentation requires client capability \
             {GUARDED_BROWSER_POINTER_CAPABILITY}"
        );
    }
    let surface = get_surface(mux, surface)?;
    require_browser(&surface)?;
    let owner = mux.control_clients.browser_pointer_owner(client)?;
    let accepted = surface.browser_acknowledge_pointer_frame_from(owner, frame_seq);
    Ok(json!({ "accepted": accepted }))
}

struct BrowserMouseCommand<'a> {
    surface: SurfaceId,
    kind: &'a str,
    x_px: f64,
    y_px: f64,
    button: Option<&'a str>,
    click_count: Option<u32>,
    frame_seq: Option<u64>,
}

fn handle_browser_mouse_command(
    mux: &Mux,
    client: u64,
    command: BrowserMouseCommand<'_>,
) -> anyhow::Result<Value> {
    let frame_seq = command
        .frame_seq
        .ok_or_else(|| anyhow::anyhow!("browser pointer input requires a frame guard"))?;
    let surface = get_surface(mux, command.surface)?;
    require_browser(&surface)?;
    let event_type = match command.kind {
        "down" => "mousePressed",
        "up" => "mouseReleased",
        "move" => "mouseMoved",
        other => anyhow::bail!("bad browser mouse kind {other:?}"),
    };
    // Capability-aware clients keep a connection-scoped capture owner. Legacy
    // one-shot calls share a bounded compatibility owner so down/move/up calls
    // issued through separate short-lived sockets remain wire-compatible.
    let input_owner = mux.control_clients.browser_pointer_owner(client)?;
    surface.browser_mouse_event_for_frame_from(BrowserMouseDispatch {
        input_owner,
        event_type,
        x: command.x_px,
        y: command.y_px,
        button: command.button,
        click_count: command.click_count,
        frame_seq: Some(frame_seq),
    })?;
    Ok(json!({}))
}

fn handle_browser_wheel_command(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    x_px: f64,
    y_px: f64,
    delta_y_px: f64,
    frame_seq: Option<u64>,
) -> anyhow::Result<Value> {
    let frame_seq =
        frame_seq.ok_or_else(|| anyhow::anyhow!("browser pointer input requires a frame guard"))?;
    let surface = get_surface(mux, surface)?;
    require_browser(&surface)?;
    let input_owner = mux.control_clients.browser_pointer_owner(client)?;
    surface.browser_wheel_for_frame_from(input_owner, x_px, y_px, delta_y_px, Some(frame_seq))?;
    Ok(json!({}))
}

fn parse_notification_level(level: &str) -> anyhow::Result<NotificationLevel> {
    match level {
        "info" => Ok(NotificationLevel::Info),
        "warning" => Ok(NotificationLevel::Warning),
        "error" => Ok(NotificationLevel::Error),
        other => anyhow::bail!("bad level {other}"),
    }
}

fn parse_agent_state(state: &str) -> anyhow::Result<AgentState> {
    match state {
        "working" => Ok(AgentState::Working),
        "blocked" => Ok(AgentState::Blocked),
        "idle" => Ok(AgentState::Idle),
        "done" => Ok(AgentState::Done),
        "unknown" => Ok(AgentState::Unknown),
        other => anyhow::bail!("bad state {other}"),
    }
}

fn parse_agent_source(source: &str) -> anyhow::Result<AgentSource> {
    match source {
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("bad source {other}"),
    }
}

fn agent_json(record: &AgentRecord) -> Value {
    json!({
        "surface": record.surface,
        "state": record.state.as_str(),
        "source": record.source.as_str(),
        "session": record.session,
        "updated_at_ms": record.updated_at_ms,
    })
}

fn parse_hex_color(value: &str) -> anyhow::Result<Rgb> {
    let bytes = value.as_bytes();
    if bytes.len() != 7 || bytes[0] != b'#' {
        anyhow::bail!("bad color {value:?} (want \"#rrggbb\")");
    }
    let nibble = |b: u8| -> anyhow::Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            b'A'..=b'F' => Ok(b - b'A' + 10),
            _ => anyhow::bail!("bad color {value:?} (want \"#rrggbb\")"),
        }
    };
    let hex = |idx: usize| -> anyhow::Result<u8> {
        Ok((nibble(bytes[idx])? << 4) | nibble(bytes[idx + 1])?)
    };
    Ok(Rgb { r: hex(1)?, g: hex(3)?, b: hex(5)? })
}

fn color_hex(color: Option<Rgb>) -> Option<String> {
    color.map(|color| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b))
}

fn terminal_colors_json(colors: TerminalColors) -> Value {
    let cursor_style = colors.cursor_style.map(|style| match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    });
    let palette = colors
        .palette
        .into_iter()
        .enumerate()
        .filter_map(|(index, color)| {
            color_hex(color).map(|color| (index.to_string(), Value::String(color)))
        })
        .collect::<serde_json::Map<String, Value>>();
    json!({
        "fg": color_hex(colors.fg),
        "bg": color_hex(colors.bg),
        "cursor": color_hex(colors.cursor),
        "selection_bg": color_hex(colors.selection_bg),
        "selection_fg": color_hex(colors.selection_fg),
        "palette": palette,
        "cursor_style": cursor_style,
        "cursor_blink": colors.cursor_blink,
    })
}

struct VtStateMessage {
    surface: SurfaceId,
    cols: u16,
    rows: u16,
    replay: Arc<[u8]>,
    kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
    kitty_state: KittyReplayState,
    colors: Value,
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

fn styled_run_json(run: &StyledRun) -> Value {
    let underline = run.underline.map(|style| match style {
        UnderlineStyle::Single => "single",
        UnderlineStyle::Double => "double",
        UnderlineStyle::Curly => "curly",
        UnderlineStyle::Dotted => "dotted",
        UnderlineStyle::Dashed => "dashed",
    });
    let mut value = json!({
        "text": run.text,
        "fg": run.fg.map(rgb_hex),
        "bg": run.bg.map(rgb_hex),
        "attrs": run.attrs,
    });
    if let Some(underline) = underline {
        value["underline"] = json!(underline);
    }
    if let Some(width_hint) = run.width_hint {
        value["width_hint"] = json!(width_hint);
    }
    value
}

fn render_rows_json(frame: &SurfaceRenderFrame, rows: impl IntoIterator<Item = u16>) -> Vec<Value> {
    rows.into_iter()
        .filter_map(|row| {
            frame.frame.row_runs(row).map(|runs| {
                json!({
                    "row": row,
                    "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                })
            })
        })
        .collect()
}

fn render_cursor_json(frame: &SurfaceRenderFrame) -> Value {
    let (style, blink) = frame.frame.cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) =
        frame.frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    json!({
        "x": x,
        "y": y,
        "style": style,
        "blink": blink,
        "visible": visible,
        "color": frame.frame.cursor_color.map(rgb_hex),
    })
}

fn serialize_arc_str<S>(value: &Arc<str>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(value)
}

#[derive(Serialize)]
struct RenderGraphicImageMessage {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    format: &'static str,
    #[serde(serialize_with = "serialize_arc_str")]
    data: Arc<str>,
}

#[derive(Serialize)]
struct RenderGraphicPlacementMessage {
    image_id: u32,
    placement_id: u32,
    ordinal: u32,
    x_offset: u32,
    y_offset: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    columns: u32,
    rows: u32,
    grid_cols: u32,
    grid_rows: u32,
    pixel_width: u32,
    pixel_height: u32,
    viewport_col: i32,
    viewport_row: i32,
    viewport_visible: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    anchor_col: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    anchor_row: Option<u32>,
    z: i32,
}

impl From<&ghostty_vt::KittyPlacement> for RenderGraphicPlacementMessage {
    fn from(placement: &ghostty_vt::KittyPlacement) -> Self {
        Self {
            image_id: placement.image_id,
            placement_id: placement.placement_id,
            ordinal: placement.key.ordinal,
            x_offset: placement.x_offset,
            y_offset: placement.y_offset,
            source_x: placement.source_x,
            source_y: placement.source_y,
            source_width: placement.source_width,
            source_height: placement.source_height,
            columns: placement.columns,
            rows: placement.rows,
            grid_cols: placement.grid_cols,
            grid_rows: placement.grid_rows,
            pixel_width: placement.pixel_width,
            pixel_height: placement.pixel_height,
            viewport_col: placement.viewport_col,
            viewport_row: placement.viewport_row,
            viewport_visible: placement.viewport_visible,
            anchor_col: placement.anchor.map(|anchor| anchor.col),
            anchor_row: placement.anchor.map(|anchor| anchor.row),
            z: placement.z,
        }
    }
}

#[derive(Serialize)]
struct RenderGraphicsMessage {
    generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    placements: Option<Vec<RenderGraphicPlacementMessage>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    images: Option<Vec<RenderGraphicImageMessage>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    removed_image_ids: Option<Vec<u32>>,
}

fn render_graphics_message(
    render_service: &RenderService,
    graphics: &ghostty_vt::KittyGraphicsSnapshot,
    image_ids: Option<&HashSet<u32>>,
    removed_image_ids: &[u32],
    include_placements: bool,
) -> RenderGraphicsMessage {
    let images = graphics
        .images
        .iter()
        .filter(|image| image_ids.is_none_or(|ids| ids.contains(&image.id)))
        .map(|image| {
            let data = render_service.encode_graphic(&image.data);
            RenderGraphicImageMessage {
                id: image.id,
                generation: image.generation,
                width: image.width,
                height: image.height,
                format: match image.format {
                    ghostty_vt::KittyImageFormat::Rgb => "rgb",
                    ghostty_vt::KittyImageFormat::Rgba => "rgba",
                },
                data,
            }
        })
        .collect::<Vec<_>>();
    RenderGraphicsMessage {
        generation: graphics.generation,
        placements: include_placements
            .then(|| graphics.placements.iter().map(RenderGraphicPlacementMessage::from).collect()),
        images: (image_ids.is_none() || !images.is_empty()).then_some(images),
        removed_image_ids: (!removed_image_ids.is_empty()).then(|| removed_image_ids.to_vec()),
    }
}

#[derive(Serialize)]
struct RenderSizeMessage {
    cols: u16,
    rows: u16,
}

#[derive(Serialize)]
struct RenderStateMessage {
    event: &'static str,
    surface: SurfaceId,
    size: RenderSizeMessage,
    cursor: Value,
    default_fg: String,
    default_bg: String,
    scrollback_rows: u32,
    history_epoch: u64,
    rows: Vec<Value>,
    graphics: RenderGraphicsMessage,
}

fn render_state_message(
    render_service: &RenderService,
    surface: SurfaceId,
    frame: &SurfaceRenderFrame,
) -> RenderStateMessage {
    let (cols, rows) = frame.frame.size;
    RenderStateMessage {
        event: "render-state",
        surface,
        size: RenderSizeMessage { cols, rows },
        cursor: render_cursor_json(frame),
        default_fg: rgb_hex(frame.frame.default_colors.1),
        default_bg: rgb_hex(frame.frame.default_colors.0),
        scrollback_rows: frame.scrollback_rows,
        history_epoch: frame.history_epoch,
        rows: render_rows_json(frame, 0..rows),
        graphics: render_graphics_message(
            render_service,
            &frame.frame.kitty_graphics,
            None,
            &[],
            true,
        ),
    }
}

#[derive(Serialize)]
struct RenderDeltaMessage {
    event: &'static str,
    surface: SurfaceId,
    cursor: Value,
    full: bool,
    rows: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<RenderSizeMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    default_fg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    default_bg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scrollback_rows: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    history_epoch: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    graphics: Option<RenderGraphicsMessage>,
}

struct RenderClientState {
    render_service: Arc<RenderService>,
    size: (u16, u16),
    default_colors: (Rgb, Rgb),
    scrollback_rows: u32,
    history_epoch: u64,
    graphics_snapshot_id: u64,
    graphics_image_revision: u64,
    graphics_placement_revision: u64,
    graphics_image_generations: Arc<[(u32, u64)]>,
    graphics_image_generations_match_snapshot: bool,
    #[cfg(test)]
    image_generation_scan_count: usize,
}

fn render_client_image_delta(
    previous: &[(u32, u64)],
    next: &[(u32, u64)],
) -> (HashSet<u32>, Vec<u32>) {
    let mut changed = HashSet::new();
    let mut removed = Vec::new();
    let (mut previous_index, mut next_index) = (0, 0);
    while previous_index < previous.len() || next_index < next.len() {
        match (previous.get(previous_index), next.get(next_index)) {
            (Some(&(previous_id, previous_generation)), Some(&(next_id, next_generation))) => {
                if previous_id < next_id {
                    removed.push(previous_id);
                    previous_index += 1;
                } else if next_id < previous_id {
                    changed.insert(next_id);
                    next_index += 1;
                } else {
                    if previous_generation != next_generation {
                        changed.insert(next_id);
                    }
                    previous_index += 1;
                    next_index += 1;
                }
            }
            (Some(&(previous_id, _)), None) => {
                removed.push(previous_id);
                previous_index += 1;
            }
            (None, Some(&(next_id, _))) => {
                changed.insert(next_id);
                next_index += 1;
            }
            (None, None) => break,
        }
    }
    (changed, removed)
}

impl RenderClientState {
    fn new(render_service: Arc<RenderService>, frame: &SurfaceRenderFrame) -> Self {
        let graphics_delta = &frame.frame.kitty_graphics_delta;
        let mut graphics_image_generations = frame
            .frame
            .kitty_graphics
            .images
            .iter()
            .map(|image| (image.id, image.generation))
            .collect::<Vec<_>>();
        graphics_image_generations.sort_unstable_by_key(|(id, _)| *id);
        let graphics_image_generations: Arc<[(u32, u64)]> = graphics_image_generations.into();
        let graphics_image_generations_match_snapshot =
            graphics_image_generations.as_ref() == graphics_delta.image_generations.as_ref();
        Self {
            render_service,
            size: frame.frame.size,
            default_colors: frame.frame.default_colors,
            scrollback_rows: frame.scrollback_rows,
            history_epoch: frame.history_epoch,
            graphics_snapshot_id: graphics_delta.snapshot_id,
            graphics_image_revision: graphics_delta.image_revision,
            graphics_placement_revision: graphics_delta.placement_revision,
            graphics_image_generations,
            graphics_image_generations_match_snapshot,
            #[cfg(test)]
            image_generation_scan_count: 0,
        }
    }

    fn delta_message(
        &mut self,
        surface: SurfaceId,
        frame: &SurfaceRenderFrame,
    ) -> RenderDeltaMessage {
        let size_changed = self.size != frame.frame.size;
        let foreground_changed = self.default_colors.1 != frame.frame.default_colors.1;
        let background_changed = self.default_colors.0 != frame.frame.default_colors.0;
        let scrollback_changed = self.scrollback_rows != frame.scrollback_rows;
        let history_epoch_changed = self.history_epoch != frame.history_epoch;
        let full = size_changed
            || foreground_changed
            || background_changed
            || frame.frame.dirty == Dirty::Full;
        let rows = if full {
            render_rows_json(frame, 0..frame.frame.size.1)
        } else {
            render_rows_json(frame, frame.frame.dirty_rows.iter().copied())
        };
        let mut message = RenderDeltaMessage {
            event: "render-delta",
            surface,
            cursor: render_cursor_json(frame),
            full,
            rows,
            size: size_changed.then_some(RenderSizeMessage {
                cols: frame.frame.size.0,
                rows: frame.frame.size.1,
            }),
            default_fg: foreground_changed.then(|| rgb_hex(frame.frame.default_colors.1)),
            default_bg: background_changed.then(|| rgb_hex(frame.frame.default_colors.0)),
            scrollback_rows: scrollback_changed.then_some(frame.scrollback_rows),
            history_epoch: history_epoch_changed.then_some(frame.history_epoch),
            graphics: None,
        };
        let graphics_delta = &frame.frame.kitty_graphics_delta;
        if self.graphics_snapshot_id != graphics_delta.snapshot_id {
            let graphics = &frame.frame.kitty_graphics;
            let image_revision_changed =
                self.graphics_image_revision != graphics_delta.image_revision;
            let (upsert_image_ids, removed_image_ids) = if self
                .graphics_image_generations_match_snapshot
                && graphics_delta.previous_snapshot_id == Some(self.graphics_snapshot_id)
            {
                if image_revision_changed {
                    (
                        graphics_delta.changed_image_ids.iter().copied().collect::<HashSet<_>>(),
                        graphics_delta.removed_image_ids.to_vec(),
                    )
                } else {
                    (HashSet::new(), Vec::new())
                }
            } else {
                #[cfg(test)]
                {
                    self.image_generation_scan_count += self
                        .graphics_image_generations
                        .len()
                        .max(graphics_delta.image_generations.len());
                }
                render_client_image_delta(
                    &self.graphics_image_generations,
                    &graphics_delta.image_generations,
                )
            };
            let images_changed = !upsert_image_ids.is_empty() || !removed_image_ids.is_empty();
            let placements_changed =
                self.graphics_placement_revision != graphics_delta.placement_revision;
            if images_changed || placements_changed {
                message.graphics = Some(render_graphics_message(
                    &self.render_service,
                    graphics,
                    Some(&upsert_image_ids),
                    &removed_image_ids,
                    placements_changed,
                ));
            }
            self.graphics_snapshot_id = graphics_delta.snapshot_id;
            self.graphics_image_revision = graphics_delta.image_revision;
            self.graphics_placement_revision = graphics_delta.placement_revision;
            self.graphics_image_generations = graphics_delta.image_generations.clone();
            self.graphics_image_generations_match_snapshot = true;
        }
        self.size = frame.frame.size;
        self.default_colors = frame.frame.default_colors;
        self.scrollback_rows = frame.scrollback_rows;
        self.history_epoch = frame.history_epoch;
        message
    }
}

#[derive(Serialize)]
struct BrowserStateMessage<'a> {
    event: &'static str,
    surface: SurfaceId,
    cols: u16,
    rows: u16,
    url: &'a str,
    title: &'a str,
    status: &'static str,
    error: Option<&'a str>,
    pointer_frame_floor_seq: Option<u64>,
    pointer_frame_seq: Option<u64>,
    frames_stalled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    frame: Option<Option<BrowserFramePayload<'a>>>,
}

#[derive(Serialize)]
struct BrowserFramePayload<'a> {
    seq: u64,
    width: u32,
    height: u32,
    image_width: u32,
    image_height: u32,
    data: &'a str,
}

fn browser_state_message<'a>(
    surface: SurfaceId,
    state: &'a BrowserAttachState,
    include_frame: bool,
) -> BrowserStateMessage<'a> {
    BrowserStateMessage {
        event: "browser-state",
        surface,
        cols: state.cols,
        rows: state.rows,
        url: &state.url,
        title: &state.title,
        status: state.status.as_str(),
        error: match &state.status {
            crate::BrowserStatus::Failed(error) => Some(error),
            crate::BrowserStatus::Starting | crate::BrowserStatus::Live => None,
        },
        pointer_frame_floor_seq: state.pointer_frame_floor_seq,
        pointer_frame_seq: state.pointer_frame_seq,
        frames_stalled: state.frames_stalled,
        frame: include_frame.then(|| state.frame.as_ref().map(browser_frame_payload)),
    }
}

fn browser_frame_json(surface: SurfaceId, update: &BrowserFrameUpdate) -> Value {
    json!({
        "event": "frame",
        "surface": surface,
        "seq": update.frame.seq,
        "width": update.frame.css_width,
        "height": update.frame.css_height,
        "image_width": update.frame.image_width,
        "image_height": update.frame.image_height,
        "data": update.frame.data_b64,
        "status": update.status.as_str(),
        "error": update.status.error(),
        "pointer_frame_floor_seq": update.pointer_frame_floor_seq,
        "pointer_frame_seq": update.pointer_frame_seq,
    })
}

fn send_browser_attach_update(
    writer: &MessageWriter,
    surface: SurfaceId,
    update: BrowserAttachUpdate,
    outbound_stream: &OutboundStream,
) -> std::io::Result<()> {
    if let Some(frame) = update.frame {
        writer.send_stream_backpressured(&browser_frame_json(surface, &frame), outbound_stream)?;
    }
    if let Some(state) = update.state {
        writer.send_stream_backpressured(
            &browser_state_message(surface, &state, false),
            outbound_stream,
        )?;
    }
    Ok(())
}

fn browser_frame_payload(frame: &crate::BrowserFrame) -> BrowserFramePayload<'_> {
    BrowserFramePayload {
        seq: frame.seq,
        width: frame.css_width,
        height: frame.css_height,
        image_width: frame.image_width,
        image_height: frame.image_height,
        data: &frame.data_b64,
    }
}

fn spawn_attach_notification_stream(
    mux: Arc<Mux>,
    surface_id: SurfaceId,
    writer: MessageWriter,
    lifecycle: AttachLifecycle,
    outbound_stream: OutboundStream,
) -> std::io::Result<()> {
    let events = mux.subscribe_attached_surface(surface_id);
    std::thread::Builder::new()
        .name("mux-attach-notifications".into())
        .spawn(move || {
            while writer.is_open() && outbound_stream.is_open() && !lifecycle.is_canceled() {
                let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                    Ok(event) => event,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                };
                let value = match event {
                    MuxEvent::Notification(notification)
                        if notification.surface == Some(surface_id) =>
                    {
                        json!({
                            "event": "notification",
                            "notification": notification.notification,
                            "title": notification.title,
                            "body": notification.body,
                            "level": notification.level.as_str(),
                            "surface": notification.surface,
                        })
                    }
                    MuxEvent::ScrollChanged { surface, offset, at_bottom }
                        if surface == surface_id =>
                    {
                        json!({
                            "event": "scroll-changed",
                            "surface": surface,
                            "offset": offset,
                            "at_bottom": at_bottom,
                        })
                    }
                    _ => continue,
                };
                if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                    handle_attach_send_error(&lifecycle, &error);
                    break;
                }
            }
            if events.overflowed() {
                lifecycle.mark_overflow();
            }
            report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
        })
        .map(|_| ())
}

fn report_attach_overflow(
    writer: &MessageWriter,
    surface_id: SurfaceId,
    lifecycle: &AttachLifecycle,
    outbound_stream: &OutboundStream,
) {
    if lifecycle.claim_overflow_report() {
        let _ = writer.send_terminal(&attach_overflow_json(surface_id), outbound_stream);
    }
}

fn handle_attach_send_error(lifecycle: &AttachLifecycle, error: &std::io::Error) {
    if error.kind() == std::io::ErrorKind::WouldBlock {
        lifecycle.mark_overflow();
    } else {
        lifecycle.cancel();
    }
}

struct MarkedClientAttach {
    lease: Option<String>,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
    client_changed: Option<(Option<String>, Option<String>)>,
    resize_reservation: Option<u64>,
    resize_completion: Option<std::sync::mpsc::Receiver<Result<(), Arc<str>>>>,
}

fn mark_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mark_client_attached_with_lease_policy(mux, client, surface, stream, initial_size, false)
}

fn mark_resource_client_attached(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
) -> anyhow::Result<MarkedClientAttach> {
    mark_client_attached_with_lease_policy(mux, client, surface, stream, initial_size, true)
}

fn mark_client_attached_with_lease_policy(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: OutboundStream,
    initial_size: Option<(u16, u16)>,
    require_lease: bool,
) -> anyhow::Result<MarkedClientAttach> {
    let lease = if require_lease {
        Some(mux.control_clients.attach_surface_with_required_lease(
            client,
            surface,
            stream.clone(),
        )?)
    } else {
        mux.control_clients.attach_surface(client, surface, stream.clone())?
    };
    if let Some((cols, rows)) = initial_size {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let is_browser = mux.surface(surface).is_some_and(|surface| surface.as_browser().is_some());
        let (completion_tx, completion_rx) = std::sync::mpsc::sync_channel(1);
        let mut previous_view_size = None;
        let resize = if let Some(lease) = lease.as_deref() {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            match mux.control_clients.prepare_view_resize(client, surface, lease, (cols, rows))? {
                ViewResizePreparation::GeometryOwner { update, previous_view_size: previous } => {
                    previous_view_size = Some(previous);
                    mux.resize_surface_for_prepared_control_client_with_completion(
                        surface,
                        client,
                        (cols, rows),
                        is_browser.then_some(completion_tx),
                        Some(update),
                    )
                }
                ViewResizePreparation::Passive { changed, name, kind } => {
                    return Ok(MarkedClientAttach {
                        lease: Some(lease.to_string()),
                        size_rollback: None,
                        client_changed: changed.then_some((name, kind)),
                        resize_reservation: None,
                        resize_completion: None,
                    });
                }
                ViewResizePreparation::Superseded => {
                    anyhow::bail!("view attachment was superseded before initial sizing");
                }
            }
        } else {
            mux.resize_surface_for_control_client_with_completion(
                surface,
                client,
                cols,
                rows,
                is_browser.then_some(completion_tx),
            )
        }
        .inspect_err(|_| {
            if let (Some(lease), Some(previous)) = (lease.as_deref(), previous_view_size) {
                mux.control_clients.restore_view_size(client, surface, lease, previous);
            }
            cleanup_failed_attach(mux, client, surface, stream.id);
        })?;
        let Some((changed, name, kind, _)) = resize.attached else {
            cleanup_failed_attach(mux, client, surface, stream.id);
            anyhow::bail!("client {client} is not attached to surface {surface}");
        };
        let mut resize_reservation = resize.reservation_id;
        let mut resize_completion = is_browser.then_some(completion_rx);
        let effective_size = resize.effective_size;
        let rollback = resize.rollback;
        if resize_reservation.is_none()
            && let Some((effective_cols, effective_rows)) = effective_size
        {
            let Some(attached_surface) = mux.surface(surface) else {
                rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                anyhow::bail!("surface {surface} disappeared while sizing before attach");
            };
            match attached_surface.pending_resize_completion(effective_cols, effective_rows) {
                Ok(Some(pending)) => {
                    resize_reservation = Some(pending.reservation);
                    resize_completion = Some(pending.completion);
                }
                Ok(None) => {}
                Err(error) => {
                    rollback_failed_attach(mux, client, surface, stream.id, Some(rollback));
                    return Err(error);
                }
            }
        }
        return Ok(MarkedClientAttach {
            lease,
            size_rollback: Some(rollback),
            client_changed: changed.then_some((name, kind)),
            resize_reservation,
            resize_completion,
        });
    }
    Ok(MarkedClientAttach {
        lease,
        size_rollback: None,
        client_changed: None,
        resize_reservation: None,
        resize_completion: None,
    })
}

fn wait_for_initial_browser_resize(
    completion: &std::sync::mpsc::Receiver<Result<(), Arc<str>>>,
    surface: SurfaceId,
    reservation: u64,
) -> anyhow::Result<()> {
    match completion.recv_timeout(INITIAL_BROWSER_RESIZE_TIMEOUT) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => {
            anyhow::bail!(
                "failed to size browser surface {surface} before attach (reservation {reservation}): {error}"
            )
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            anyhow::bail!("timed out sizing browser surface {surface} before attach");
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            anyhow::bail!(
                "browser resize completion disconnected before attach (surface {surface}, reservation {reservation})"
            )
        }
    }
}

fn announce_client_attached(mux: &Mux, client: u64) -> anyhow::Result<bool> {
    if let Some((transport, name, kind)) = mux.control_clients.announce_attached(client)? {
        mux.emit(MuxEvent::ClientAttached { client, transport, name, kind });
        return Ok(true);
    }
    Ok(false)
}

fn commit_client_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    changed: Option<(Option<String>, Option<String>)>,
    rollback: Option<crate::mux::ClientSizeRollback>,
) -> anyhow::Result<()> {
    mux.control_clients.commit_surface(client, surface, stream, rollback)?;
    let newly_announced = announce_client_attached(mux, client)?;
    if !newly_announced && let Some((name, kind)) = changed {
        mux.emit(MuxEvent::ClientChanged { client, name, kind });
    }
    Ok(())
}

struct AttachWorkerCommit {
    start: std::sync::mpsc::SyncSender<()>,
    lifecycle: AttachLifecycle,
    changed: Option<(Option<String>, Option<String>)>,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
}

fn commit_client_attach_and_start_worker(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    worker: AttachWorkerCommit,
) -> anyhow::Result<()> {
    if let Err(error) =
        commit_client_attach(mux, client, surface, stream, worker.changed, worker.size_rollback)
    {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        return Err(error);
    }
    if worker.start.send(()).is_err() {
        worker.lifecycle.cancel();
        rollback_failed_attach(mux, client, surface, stream, worker.size_rollback);
        anyhow::bail!("attach output worker exited before stream {stream} was committed");
    }
    Ok(())
}

fn cleanup_failed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let _lifecycle = mux.lock_client_sizing_lifecycle();
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    }
}

fn rollback_failed_attach(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    stream: u64,
    size_rollback: Option<crate::mux::ClientSizeRollback>,
) {
    let detached = {
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        mux.control_clients.detach_surface(client, surface, stream)
    };
    if detached.final_stream {
        // A failed first attach is one transaction: restore the geometry that
        // preceded its provisional size report before removing the report.
        // Final-stream detach has no surviving view to promote, so the
        // generic geometry-replacement marker must not suppress this rollback.
        if let Some(size_rollback) = detached.rollback.or(size_rollback) {
            mux.rollback_surface_size_client(surface, client, size_rollback);
        }
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    } else if let Some(size_rollback) = detached.rollback.or(size_rollback) {
        mux.rollback_surface_size_client(surface, client, size_rollback);
    }
}

fn detach_committed_attach(mux: &Mux, client: u64, surface: SurfaceId, stream: u64) {
    let lifecycle = mux.lock_client_sizing_lifecycle();
    let detached = mux.control_clients.detach_surface(client, surface, stream);
    if detached.final_stream {
        mux.remove_surface_size_client(surface, client);
    } else if let Some(replacement) = detached.geometry_replacement {
        apply_view_geometry_replacement(mux, client, surface, replacement);
    } else if let Some(rollback) = detached.rollback {
        // Rollback performs its own report-order-checked lifecycle transaction.
        // Release this transaction first so legacy multi-stream clients cannot
        // recursively acquire the non-reentrant lifecycle mutex.
        drop(lifecycle);
        mux.rollback_surface_size_client(surface, client, rollback);
    }
}

fn apply_view_geometry_replacement(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    replacement: Option<(u16, u16)>,
) {
    if let Some((cols, rows)) = replacement {
        let _ = mux.resize_surface_for_client_with_reservation(surface, client, cols, rows);
    } else {
        mux.remove_surface_size_client(surface, client);
    }
}

#[cfg(test)]
fn handle_command(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    handle_command_with_cancellation(mux, client, cmd, writer, None)
}

fn terminal_renderer_grant_json(
    grant: crate::terminal_host_runtime::RendererGrant,
    ttl_ms: u64,
) -> Value {
    json!({
        "endpoint": grant.endpoint,
        "terminal_id": grant.terminal_id,
        "incarnation": grant.incarnation,
        "token": grant.token,
        "rights": grant.rights.bits(),
        "protocol_version": grant.protocol_version,
        "ttl_ms": ttl_ms,
    })
}

fn handle_command_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    cmd: Command,
    writer: &MessageWriter,
    cancellation: Option<&AtomicBool>,
) -> anyhow::Result<Value> {
    match cmd {
        Command::Identify => {
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "app": "cmux-tui",
                "version": env!("CARGO_PKG_VERSION"),
                "build_commit": stamped_build_commit(),
                "ghostty_commit": stamped_ghostty_commit(),
                "protocol": PROTOCOL_VERSION,
                "capabilities": advertised_capabilities(cfg!(unix)),
                "session": mux.session,
                "pid": std::process::id(),
                "registry_id": registry_id,
                "generation": generation,
                "workspace_revision": mux.with_state(|state| state.workspace_revision),
                "terminal_revision": mux.terminal_registry_snapshot()?.revision,
                "daemon_handoff": 1,
                "lifecycle_ready": mux.server_lifecycle_ready(),
            }))
        }
        Command::ShutdownDaemon { pid, generation, force } => {
            let actual_identity = mux.begin_daemon_handoff(
                client,
                DaemonHandoffRequest::fenced(pid, generation, force),
            )?;
            Ok(json!({
                "accepted": true,
                "pid": actual_identity.pid,
                "generation": actual_identity.generation,
            }))
        }
        Command::Ping => Ok(json!({
            "ok": true,
            "version": env!("CARGO_PKG_VERSION"),
            "build_commit": stamped_build_commit(),
            "ghostty_commit": stamped_ghostty_commit(),
            "protocol": PROTOCOL_VERSION,
        })),
        Command::SetClientInfo { name, kind, capabilities } => {
            let (name, kind) = mux.control_clients.set_info(client, name, kind, capabilities)?;
            mux.emit(MuxEvent::ClientChanged { client, name, kind });
            Ok(json!({}))
        }
        Command::ListClients => Ok(mux.control_clients_json(client)),
        Command::RegisterBrowserProvider {
            provider_id,
            endpoint,
            authentication,
            bearer_token,
            targets,
        } => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("browser provider registration requires a trusted local connection");
            }
            let registration = browser_provider_registration(
                provider_id,
                endpoint,
                authentication,
                bearer_token,
                targets,
            )?;
            let snapshot = mux.register_browser_provider(client, registration)?;
            Ok(browser_provider_json(Some(snapshot)))
        }
        Command::GetBrowserProvider => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("browser provider discovery requires a trusted local connection");
            }
            Ok(browser_provider_json(mux.browser_provider_snapshot()))
        }
        Command::UnregisterBrowserProvider => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("browser provider registration requires a trusted local connection");
            }
            Ok(json!({"removed":mux.unregister_browser_provider(client)}))
        }
        Command::ListTerminals => {
            let snapshot = mux.terminal_registry_snapshot()?;
            let terminals = snapshot
                .terminals
                .into_iter()
                .map(|terminal| {
                    json!({
                        "terminal_id":terminal.terminal_id,
                        "workspace_key":terminal.workspace_key,
                        "terminal_incarnation":terminal.incarnation,
                        "lifecycle":terminal.lifecycle,
                        "launch_spec":terminal.launch_spec,
                        "exit":terminal.exit,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({
                "registry_id":snapshot.registry_id,
                "generation":snapshot.generation,
                "terminal_revision":snapshot.revision,
                "terminals":terminals,
            }))
        }
        Command::TerminalEvents { after_revision } => {
            let (snapshot, events) = mux.terminal_registry_events_page(after_revision)?;
            let events = events
                .into_iter()
                .map(|event| {
                    json!({
                        "terminal_revision":event.revision,
                        "kind":event.kind,
                        "terminal_id":event.terminal_id,
                        "workspace_key":event.workspace_key,
                        "origin":event.origin,
                        "mutation_id":event.mutation_id,
                        "result":event.result,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({
                "registry_id":snapshot.registry_id,
                "generation":snapshot.generation,
                "terminal_revision":snapshot.revision,
                "events":events,
            }))
        }
        Command::SetClientSizing { surface, client: target, enabled, exclusive } => {
            if exclusive && !enabled {
                anyhow::bail!("exclusive client sizing must be enabled");
            }
            get_surface(mux, surface)?;
            if exclusive && target.is_none() {
                mux.use_only_client_size(surface, client).ok_or_else(|| {
                    anyhow::anyhow!(
                        "client {client} is not attached with a reported size for surface {surface}"
                    )
                })?;
                return Ok(json!({}));
            }
            if let Some(target) = target {
                if exclusive {
                    mux.use_only_client_size(surface, target).ok_or_else(|| {
                        anyhow::anyhow!(
                            "client {target} is not attached with a reported size for surface {surface}"
                        )
                    })?;
                } else {
                    mux.set_client_size_participation(surface, target, enabled).ok_or_else(
                        || anyhow::anyhow!("client {target} is not attached to surface {surface}"),
                    )?;
                }
            } else if enabled {
                mux.use_all_client_sizes(surface)
                    .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
            } else {
                anyhow::bail!("client is required when disabling sizing");
            }
            Ok(json!({}))
        }
        Command::PairingResponse { request, approve } => {
            if !mux.control_clients.is_unix(client) {
                anyhow::bail!("pairing decisions require a trusted local connection");
            }
            if !mux.respond_pairing(request, approve) {
                anyhow::bail!("unknown or expired pairing request {request}");
            }
            Ok(json!({}))
        }
        Command::DetachClient { client: target } => {
            if target == client {
                if !mux.control_clients.contains(target) {
                    anyhow::bail!("unknown client {target}");
                }
            } else if !disconnect_client(mux, target, true) {
                anyhow::bail!("unknown client {target}");
            }
            Ok(json!({}))
        }
        Command::ReloadConfig => {
            mux.request_config_reload()?;
            Ok(json!({
                "reloaded": true,
                "path": platform::config_path().map(|path| path.display().to_string()),
            }))
        }
        Command::SetWindowTitle { title } => {
            mux.emit(MuxEvent::WindowTitleRequested(title));
            Ok(json!({}))
        }
        Command::ClearWindowTitle => {
            mux.emit(MuxEvent::WindowTitleRequested(String::new()));
            Ok(json!({}))
        }
        Command::ListWorkspaces => {
            let notifications = mux.surface_notifications();
            let mut workspaces = mux.with_state(|state| workspaces_json(state, &notifications));
            let (registry_id, generation) = mux.registry_identity();
            workspaces["registry_id"] = json!(registry_id);
            workspaces["generation"] = json!(generation);
            workspaces["terminal_revision"] = json!(mux.terminal_registry_snapshot()?.revision);
            Ok(workspaces)
        }
        Command::GetFrontendProjection { frontend, scope, subject_key } => {
            let projection = mux.get_frontend_projection(&frontend, &scope, &subject_key)?;
            Ok(match projection {
                Some(projection) => serde_json::to_value(projection)?,
                None => json!({
                    "frontend": frontend,
                    "scope": scope,
                    "subject_key": subject_key,
                    "schema_version": 0,
                    "projection_revision": 0,
                    "projection": null,
                }),
            })
        }
        Command::PutFrontendProjection {
            frontend,
            scope,
            subject_key,
            schema_version,
            expected_projection_revision,
            projection,
            mutation,
        } => {
            let workspace_mutation = workspace_mutation(&mutation)?;
            let commit = mux.put_frontend_projection(
                &workspace_mutation,
                &frontend,
                &scope,
                &subject_key,
                schema_version,
                expected_projection_revision,
                &projection,
            )?;
            let mut value = serde_json::to_value(commit.projection)?;
            value["replayed"] = json!(commit.replayed);
            Ok(value)
        }
        Command::JournalFrontendEvent { event } => {
            let session_id = mux.session_public_id();
            let principal_id = public_client_id(&session_id, client)?.to_string();
            mux.journal_frontend_event(principal_id, event)?;
            Ok(json!({"committed":true}))
        }
        Command::ExportLayout { screen } => {
            mux.with_state(|state| export_layout_json(state, screen))
        }
        Command::ApplyLayout { workspace, name, layout, cols, rows } => {
            let layout = layout_request_to_spec(layout)?;
            let applied =
                mux.apply_layout(workspace, name, &layout, optional_surface_size(cols, rows))?;
            Ok(json!({
                "screen": applied.screen,
                "panes": applied.panes.iter().map(|pane| {
                    json!({ "pane": pane.pane, "surface": pane.surface })
                }).collect::<Vec<_>>(),
            }))
        }
        Command::Send { surface, text, bytes, paste } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            if paste {
                let mut payload = text.unwrap_or_default().into_bytes();
                if let Some(b64) = bytes {
                    payload.extend(base64::engine::general_purpose::STANDARD.decode(b64)?);
                }
                surface.write_paste(&payload)?;
            } else {
                if let Some(text) = text {
                    surface.write_bytes(text.as_bytes())?;
                }
                if let Some(b64) = bytes {
                    let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
                    surface.write_bytes(&raw)?;
                }
            }
            Ok(json!({}))
        }
        Command::ReadScreen { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = surface.try_with_terminal(|t| t.viewport_text())??;
            Ok(json!({ "text": text }))
        }
        Command::ClearHistory { surface, fallback_key } => {
            let surface =
                get_surface(mux, surface).map_err(DeliveryClassifiedError::known_not_delivered)?;
            require_pty(&surface).map_err(DeliveryClassifiedError::known_not_delivered)?;
            let fallback_key = fallback_key
                .map(KeyInput::try_from)
                .transpose()
                .map_err(DeliveryClassifiedError::known_not_delivered)?;
            surface
                .clear_history_or_encode_key_classified(fallback_key.as_ref())
                .map_err(DeliveryClassifiedError::from)?;
            Ok(json!({}))
        }
        Command::ReadScrollback { surface, start, count } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let count = u16::try_from(count).map_err(|_| anyhow::anyhow!("count out of range"))?;
            let (start, total, epoch, rows) = surface.try_with_terminal(|term| {
                let total = term.history_rows();
                let start = start.min(total);
                let epoch = term.history_epoch();
                term.styled_history_rows(start, count).map(|rows| (start, total, epoch, rows))
            })??;
            let runs = rows_to_runs(&rows);
            let rows = runs
                .iter()
                .enumerate()
                .map(|(row, runs)| {
                    json!({
                        "row": row as u16,
                        "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({ "rows": rows, "start": start, "total": total, "epoch": epoch }))
        }
        Command::SidebarPlugin { cols, rows, relaunch } => {
            Ok(sidebar_plugin_status_json(mux.ensure_sidebar_plugin(cols, rows, relaunch)))
        }
        Command::WaitFor { surface, pattern, timeout_ms } => {
            let cancelled = || cancellation.is_some_and(|flag| flag.load(Ordering::Acquire));
            if cancelled() {
                anyhow::bail!("connection closed while waiting for pattern");
            }
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let regex = Regex::new(&pattern).map_err(|err| anyhow::anyhow!("bad regex: {err}"))?;
            let start = Instant::now();
            let check = || -> anyhow::Result<Option<String>> {
                let text = surface.try_with_terminal(|t| t.viewport_text())??;
                Ok(regex.is_match(&text).then_some(text))
            };
            if timeout_ms == 0 {
                if let Some(text) = check()? {
                    return Ok(json!({
                        "matched": true,
                        "text": text,
                        "elapsed_ms": start.elapsed().as_millis() as u64,
                    }));
                }
                anyhow::bail!("timeout waiting for pattern");
            }
            let deadline = start + Duration::from_millis(timeout_ms);
            let attach = surface.attach_stream()?;
            if let Some(text) = check()? {
                return Ok(json!({
                    "matched": true,
                    "text": text,
                    "elapsed_ms": start.elapsed().as_millis() as u64,
                }));
            }
            loop {
                if cancelled() {
                    anyhow::bail!("connection closed while waiting for pattern");
                }
                let now = Instant::now();
                if now >= deadline {
                    anyhow::bail!("timeout waiting for pattern");
                }
                let remaining = deadline.saturating_duration_since(now);
                match attach.stream.recv_timeout(remaining.min(STREAM_DISCONNECT_POLL)) {
                    Ok(_) => {
                        if let Some(text) = check()? {
                            return Ok(json!({
                                "matched": true,
                                "text": text,
                                "elapsed_ms": start.elapsed().as_millis() as u64,
                            }));
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        if Instant::now() >= deadline {
                            anyhow::bail!("timeout waiting for pattern");
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                }
            }
        }
        Command::Run { argv, command, cwd, pane, new_workspace, key, name, cols, rows } => {
            if argv.is_some() && command.is_some() {
                anyhow::bail!("argv and command are mutually exclusive");
            }
            let argv = match (argv, command) {
                (Some(argv), None) if !argv.is_empty() => argv,
                (None, Some(command)) if !command.is_empty() => {
                    vec![platform::default_shell(), "-lc".to_string(), command]
                }
                _ => anyhow::bail!("argv or command is required"),
            };
            if new_workspace && pane.is_some() {
                anyhow::bail!("pane and new_workspace are mutually exclusive");
            }
            if key.is_some() && !new_workspace {
                anyhow::bail!("key requires new_workspace");
            }
            let result = mux.run_command_result_with_options(
                argv,
                crate::mux::RunCommandOptions {
                    pane,
                    new_workspace,
                    workspace_key: key,
                    cwd,
                    name,
                    size: optional_surface_size(cols, rows),
                },
            )?;
            let placement = result.placement;
            let already_exited = result.terminal.lifecycle == TerminalLifecycle::Exited;
            Ok(json!({
                "surface": placement.as_ref().map(|placement| placement.surface),
                "terminal_id": result.terminal.terminal_id,
                "terminal_incarnation": result.terminal.incarnation,
                "pane": placement.as_ref().map(|placement| placement.pane),
                "screen": placement.as_ref().map(|placement| placement.screen),
                "workspace": placement.as_ref().map(|placement| placement.workspace),
                "lifecycle": result.terminal.lifecycle,
                "exit": result.terminal.exit,
                "terminal_revision": result.terminal_revision,
                "already_exited": already_exited,
            }))
        }
        Command::CreateSurfaceWithReceipt(request) => {
            create_surface_with_receipt(mux, client, *request)
        }
        Command::SendKey { surface, keys } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)
                .map_err(|_| anyhow::anyhow!("surface does not support key input"))?;
            if keys.is_empty() {
                anyhow::bail!("bad request: keys must be non-empty");
            }
            let mut encoder = KeyEncoder::new()?;
            let mut encoded = Vec::new();
            surface.scroll_to_bottom()?;
            surface.try_with_terminal(|term| {
                encoder.sync_from_terminal(term);
                for key in &keys {
                    let Some(input) = key_input_from_chord(key) else {
                        return Err(anyhow::anyhow!("unknown key {key}"));
                    };
                    encoder.encode(&input, &mut encoded).map_err(anyhow::Error::from)?;
                }
                Ok::<(), anyhow::Error>(())
            })??;
            surface.write_bytes(&encoded)?;
            Ok(json!({}))
        }
        Command::Copy { surface, mode } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let text = match mode.as_str() {
                "screen" => surface.try_with_terminal(|t| t.viewport_text())??,
                "scrollback" => surface.try_with_terminal(|t| t.plain_text())??,
                "selection" => {
                    surface.selection_text().ok_or_else(|| anyhow::anyhow!("no selection"))?
                }
                other => anyhow::bail!("bad mode {other}"),
            };
            Ok(json!({ "text": text, "mode": mode }))
        }
        Command::Ids { kind } => mux.with_state(|state| ids_json(state, kind.as_deref())),
        Command::Notify { title, body, level, surface } => {
            if title.is_empty() {
                anyhow::bail!("title is required");
            }
            let level = parse_notification_level(level.as_deref().unwrap_or("info"))?;
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let notification = mux.post_notification(title, body, level, surface)?;
            Ok(json!({ "notification": notification }))
        }
        Command::ListAgents { surface, state } => {
            if let Some(surface) = surface {
                get_surface(mux, surface)?;
            }
            let state = match state {
                Some(state) => Some(parse_agent_state(&state)?),
                None => None,
            };
            let agents = mux.list_agents(surface, state).iter().map(agent_json).collect::<Vec<_>>();
            Ok(json!({ "agents": agents }))
        }
        Command::ReportAgent { surface, state, source, session } => {
            get_surface(mux, surface)?;
            let state = parse_agent_state(&state)?;
            let source = parse_agent_source(&source)?;
            let record = mux.report_agent(surface, state, source, session)?;
            Ok(json!({
                "surface": record.surface,
                "state": record.state.as_str(),
                "source": record.source.as_str(),
                "session": record.session,
            }))
        }
        Command::VtState { .. } => unreachable!("vt-state uses its streaming response path"),
        Command::MintTerminalRenderer { surface, ttl_ms } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let grant = surface.mint_renderer_grant(Duration::from_millis(ttl_ms))?;
            Ok(terminal_renderer_grant_json(grant, ttl_ms))
        }
        Command::MintTerminalRendererByTerminal { terminal, ttl_ms } => {
            let terminal = TerminalPublicId::parse(terminal)?;
            let surface = mux
                .resource_surface_for_terminal(&terminal)
                .ok_or_else(|| anyhow::anyhow!("terminal {terminal} is not live"))?;
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            let grant = surface.mint_renderer_grant(Duration::from_millis(ttl_ms))?;
            Ok(terminal_renderer_grant_json(grant, ttl_ms))
        }
        Command::ResolveTerminal { terminal_id } => {
            let Some(resolution) = mux.resolve_terminal(&terminal_id)? else {
                anyhow::bail!("terminal_not_found");
            };
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "surface": resolution.surface,
                "terminal_id": resolution.terminal.terminal_id,
                "terminal_incarnation": resolution.terminal.incarnation,
                "workspace_key": resolution.terminal.workspace_key,
                "lifecycle": resolution.terminal.lifecycle,
                "launch_spec": resolution.terminal.launch_spec,
                "exit": resolution.terminal.exit,
                "terminal_revision": resolution.terminal_revision,
                "registry_id": registry_id,
                "generation": generation,
            }))
        }
        Command::CloseTerminal { terminal_id, terminal_incarnation, mutation } => {
            let workspace_mutation = workspace_mutation(&mutation)?;
            let result = mux.close_terminal_with_mutation(
                &terminal_id,
                terminal_incarnation.as_deref(),
                mutation.expected_generation.as_deref(),
                mutation.expected_revision,
                &workspace_mutation,
            )?;
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "surface": result.surface,
                "terminal_id": result.terminal_id,
                "terminal_incarnation": result.terminal_incarnation,
                "already_closed": result.already_closed,
                "closed": true,
                "terminal_revision": result.terminal_revision,
                "registry_id": registry_id,
                "generation": generation,
            }))
        }
        Command::NewTab { pane, cwd, cols, rows } => {
            let surface = mux.new_tab(pane, cwd, optional_surface_size(cols, rows))?;
            let terminal_identity = surface.terminal_host_identity();
            Ok(json!({
                "surface": surface.id,
                "terminal_id": terminal_identity.as_ref().map(|identity| &identity.terminal_id),
                "terminal_incarnation": terminal_identity
                    .as_ref()
                    .map(|identity| &identity.incarnation),
            }))
        }
        Command::NewBrowserTab { url, pane, cols, rows } => {
            let surface = mux.new_browser_tab(url, pane, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::GetCellPixels => {
            let (width_px, height_px) = mux.cell_pixel_creation_size();
            let surfaces = mux.with_state(|state| {
                state
                    .surfaces
                    .values()
                    .map(|surface| {
                        let (width_px, height_px) = surface.cell_pixel_size();
                        json!({
                            "surface": surface.id,
                            "width_px": width_px,
                            "height_px": height_px,
                        })
                    })
                    .collect::<Vec<_>>()
            });
            Ok(json!({
                "width_px": width_px,
                "height_px": height_px,
                "surfaces": surfaces,
            }))
        }
        Command::SetCellPixels { width_px, height_px } => {
            let update = mux.set_cell_pixel_size(width_px, height_px);
            let resizes = update
                .resizes
                .into_iter()
                .map(|(surface, (cols, rows), reservation_id)| {
                    json!({
                        "surface": surface,
                        "cols": cols,
                        "rows": rows,
                        "reservation_id": reservation_id,
                    })
                })
                .collect::<Vec<_>>();
            let failures = update
                .failures
                .into_iter()
                .map(|failure| {
                    json!({
                        "surface": failure.surface,
                        "error": failure.error,
                        "deferred": failure.deferred,
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"resizes": resizes, "failures": failures}))
        }
        Command::BrowserFramePresented { surface, frame_seq } => {
            handle_browser_frame_presented(mux, client, surface, frame_seq)
        }
        Command::BrowserMouse { surface, kind, x_px, y_px, button, click_count, frame_seq } => {
            handle_browser_mouse_command(
                mux,
                client,
                BrowserMouseCommand {
                    surface,
                    kind: &kind,
                    x_px,
                    y_px,
                    button: button.as_deref(),
                    click_count,
                    frame_seq,
                },
            )
        }
        Command::BrowserMouseGuarded {
            surface,
            kind,
            x_px,
            y_px,
            button,
            click_count,
            frame_seq,
        } => handle_browser_mouse_command(
            mux,
            client,
            BrowserMouseCommand {
                surface,
                kind: &kind,
                x_px,
                y_px,
                button: button.as_deref(),
                click_count,
                frame_seq: Some(frame_seq),
            },
        ),
        Command::BrowserWheel { surface, x_px, y_px, delta_y_px, frame_seq } => {
            handle_browser_wheel_command(mux, client, surface, x_px, y_px, delta_y_px, frame_seq)
        }
        Command::BrowserWheelGuarded { surface, x_px, y_px, delta_y_px, frame_seq } => {
            handle_browser_wheel_command(
                mux,
                client,
                surface,
                x_px,
                y_px,
                delta_y_px,
                Some(frame_seq),
            )
        }
        Command::BrowserKey {
            surface,
            kind,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            let event_type = match kind.as_str() {
                "down" => "keyDown",
                "up" => "keyUp",
                other => anyhow::bail!("bad browser key kind {other:?}"),
            };
            surface.browser_key_event(
                event_type,
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            )?;
            Ok(json!({}))
        }
        Command::BrowserKeyPress {
            surface,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_key_press(
                &key,
                &code,
                windows_virtual_key_code,
                modifiers,
                text.as_deref(),
            )?;
            Ok(json!({}))
        }
        Command::BrowserInsertText { surface, text } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_insert_text(&text)?;
            Ok(json!({}))
        }
        Command::BrowserNavigate { surface, url } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_navigate(&url)?;
            Ok(json!({}))
        }
        Command::BrowserBack { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_back()?;
            Ok(json!({}))
        }
        Command::BrowserForward { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_forward()?;
            Ok(json!({}))
        }
        Command::BrowserReload { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_reload()?;
            Ok(json!({}))
        }
        Command::BrowserActivate { surface } => {
            let surface = get_surface(mux, surface)?;
            require_browser(&surface)?;
            surface.browser_activate()?;
            Ok(json!({}))
        }
        Command::NewWorkspace { name, cols, rows } => {
            let surface = mux.new_workspace(name, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::CreateWorkspace { name, key, mutation } => {
            if let Some(key) = key.as_deref()
                && !crate::workspace_registry::is_canonical_workspace_key(key)
            {
                anyhow::bail!("workspace key must be a lowercase UUID");
            }
            let workspace_mutation = workspace_mutation(&mutation)?;
            let placement = mux.create_empty_workspace_with_mutation(
                name,
                key,
                mutation.expected_generation.as_deref(),
                mutation.expected_revision,
                &workspace_mutation,
            )?;
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "workspace": placement.workspace,
                "key": placement.key,
                "index": placement.index,
                "workspace_revision": placement.revision,
                "replayed": placement.replayed,
                "registry_id": registry_id,
                "generation": generation,
            }))
        }
        Command::CreateTerminal {
            workspace,
            key,
            argv,
            command,
            cwd,
            name,
            cols,
            rows,
            terminal_id,
            mutation,
        } => {
            if argv.is_some() && command.is_some() {
                anyhow::bail!("argv and command are mutually exclusive");
            }
            let argv = match (argv, command) {
                (Some(argv), None) if !argv.is_empty() => Some(argv),
                (None, Some(command)) if !command.is_empty() => {
                    Some(vec![platform::default_shell(), "-lc".to_string(), command])
                }
                (None, None) => None,
                _ => anyhow::bail!("argv or command must be non-empty when provided"),
            };
            let size = paired_surface_size("create-terminal", cols, rows)?;
            let (workspace, key) = resolve_workspace(mux, workspace, key.as_deref())?;
            let (registry_id, generation) = mux.registry_identity();
            if terminal_id.is_some() || mutation.mutation_id.is_some() {
                let workspace_mutation = workspace_mutation(&mutation)?;
                let result = mux.create_raw_terminal_in_workspace_with_mutation(
                    workspace,
                    argv,
                    cwd,
                    name,
                    size,
                    terminal_id.as_deref(),
                    mutation.expected_generation.as_deref(),
                    mutation.expected_revision,
                    &workspace_mutation,
                )?;
                let projection_fingerprint = json!({
                    "terminal_id":result.terminal_id,
                    "workspace_key":key,
                });
                mux.commit_full_resource_projection_with_mutation(
                    &workspace_mutation,
                    "raw.terminal.create",
                    &projection_fingerprint,
                    json!({
                        "terminal_id":result.terminal_id,
                        "workspace_key":key,
                    }),
                )?;
                mux.activate_created_terminal_surface(result.created_surface)?;
                mux.reap_created_terminal_surface(result.created_surface);
                let created = mux.created_terminal_run_result(&result.terminal_id)?;
                let placement = created.placement;
                let already_exited = created.terminal.lifecycle == TerminalLifecycle::Exited;
                Ok(json!({
                    "surface": placement.as_ref().map(|placement| placement.surface),
                    "terminal_id": created.terminal.terminal_id,
                    "terminal_incarnation": created.terminal.incarnation,
                    "pane": placement.as_ref().map(|placement| placement.pane),
                    "screen": placement.as_ref().map(|placement| placement.screen),
                    "workspace": placement.as_ref().map(|placement| placement.workspace),
                    "key": key,
                    "lifecycle": created.terminal.lifecycle,
                    "exit": created.terminal.exit,
                    "already_exited": already_exited,
                    "terminal_revision": created.terminal_revision,
                    "replayed": result.replayed,
                    "registry_id": registry_id,
                    "generation": generation,
                }))
            } else {
                let created =
                    mux.create_terminal_result_in_workspace(workspace, argv, cwd, name, size)?;
                let placement = created.placement;
                let already_exited = created.terminal.lifecycle == TerminalLifecycle::Exited;
                Ok(json!({
                    "surface": placement.as_ref().map(|placement| placement.surface),
                    "terminal_id": created.terminal.terminal_id,
                    "terminal_incarnation": created.terminal.incarnation,
                    "pane": placement.as_ref().map(|placement| placement.pane),
                    "screen": placement.as_ref().map(|placement| placement.screen),
                    "workspace": placement.as_ref().map(|placement| placement.workspace),
                    "key": key,
                    "lifecycle": created.terminal.lifecycle,
                    "exit": created.terminal.exit,
                    "already_exited": already_exited,
                    "terminal_revision": created.terminal_revision,
                    "replayed": false,
                    "registry_id": registry_id,
                    "generation": generation,
                }))
            }
        }
        Command::NewScreen { workspace, cols, rows } => {
            let surface = mux.new_screen(workspace, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::NewPane { pane, cols, rows } => {
            let surface = mux.new_pane(pane, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::NewPaneRight { pane, width, cols, rows } => {
            let surface = mux.new_pane_right(
                pane,
                width.unwrap_or(crate::DEFAULT_VIEWPORT_PANE_WIDTH),
                optional_surface_size(cols, rows),
            )?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::Split { pane, dir, cols, rows } => {
            let dir = parse_split_dir(&dir)?;
            let surface = mux.split(pane, dir, optional_surface_size(cols, rows))?;
            Ok(json!({ "surface": surface.id }))
        }
        Command::SetRatio { pane, dir, ratio } => {
            let dir = parse_split_dir(&dir)?;
            mux.set_ratio_checked(pane, dir, ratio)?;
            Ok(json!({}))
        }
        Command::SetSplitRatio { split, ratio, transaction } => {
            transaction.map_or_else(
                || mux.set_split_ratio_checked(split, ratio),
                |transaction| {
                    mux.set_split_ratio_in_transaction_checked(split, ratio, client, transaction)
                },
            )?;
            Ok(json!({}))
        }
        Command::SetViewportPaneWidth { pane, width, transaction } => {
            transaction.map_or_else(
                || mux.set_viewport_pane_width_checked(pane, width),
                |transaction| {
                    mux.set_viewport_pane_width_in_transaction_checked(
                        pane,
                        width,
                        client,
                        transaction,
                    )
                },
            )?;
            Ok(json!({}))
        }
        Command::UndoLayout { pane, revision, confirm_close } => {
            match mux.undo_layout(pane, revision, confirm_close)? {
                LayoutUndoResult::Undone { screen, revision } => Ok(json!({
                    "undone": true,
                    "screen": screen,
                    "revision": revision,
                })),
                LayoutUndoResult::ConfirmationRequired { screen, revision, closes_panes } => {
                    Ok(json!({
                        "undone": false,
                        "confirmation_required": true,
                        "screen": screen,
                        "revision": revision,
                        "closes_panes": closes_panes,
                    }))
                }
            }
        }
        Command::PaneNeighbor { pane, dir } => {
            let dir = parse_direction(&dir)?;
            let pane = mux.pane_neighbor(pane, dir)?;
            Ok(json!({ "pane": pane }))
        }
        Command::FocusDirection { pane, dir } => {
            let dir = parse_direction(&dir)?;
            let pane = mux.focus_direction(pane, dir)?;
            Ok(json!({ "pane": pane }))
        }
        Command::SwapPane { pane, dir, target } => {
            let target = match (dir, target) {
                (Some(_), Some(_)) => anyhow::bail!("use only one of dir or target"),
                (Some(dir), None) => {
                    let dir = parse_direction(&dir)?;
                    mux.pane_neighbor(pane, dir)?.ok_or_else(|| anyhow::anyhow!("no neighbor"))?
                }
                (None, Some(target)) => target,
                (None, None) => anyhow::bail!("one of dir or target is required"),
            };
            if !mux.swap_panes(pane, target) {
                anyhow::bail!("unknown pane/target");
            }
            Ok(json!({}))
        }
        Command::ZoomPane { pane, mode } => {
            let mode = parse_zoom_mode(mode)?;
            let state = mux.zoom_pane(pane, mode)?;
            Ok(json!({
                "pane": state.pane,
                "zoomed": state.zoomed,
                "zoomed_pane": state.zoomed_pane,
            }))
        }
        Command::ProcessInfo { surface } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            Ok(json!({
                "pid": surface.process_id(),
                "command": surface.spawn_command(),
                "cwd": surface.local_cwd(),
                "foreground_cwd": surface.process_id().and_then(platform::foreground_cwd),
            }))
        }
        Command::MoveTerminal { terminal_id, workspace_key, terminal_incarnation, mutation } => {
            let workspace_mutation = workspace_mutation(&mutation)?;
            let result = mux.move_terminal_with_mutation(
                &terminal_id,
                &workspace_key,
                terminal_incarnation.as_deref(),
                mutation.expected_generation.as_deref(),
                mutation.expected_revision,
                &workspace_mutation,
            )?;
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "surface":result.placement.as_ref().map(|placement| placement.surface),
                "pane":result.placement.as_ref().map(|placement| placement.pane),
                "screen":result.placement.as_ref().map(|placement| placement.screen),
                "workspace":result.placement.as_ref().map(|placement| placement.workspace),
                "terminal_id":result.terminal.terminal_id,
                "terminal_incarnation":result.terminal.incarnation,
                "workspace_key":result.terminal.workspace_key,
                "lifecycle":result.terminal.lifecycle,
                "changed":result.changed,
                "replayed":result.replayed,
                "terminal_revision":result.terminal_revision,
                "registry_id":registry_id,
                "generation":generation,
            }))
        }
        Command::MoveTab { surface, pane, index } => {
            let valid = mux.with_state(|state| {
                state.surfaces.contains_key(&surface)
                    && state.panes.contains_key(&pane)
                    && state.pane_of(surface).is_some()
            });
            if !valid {
                anyhow::bail!("unknown surface/pane");
            }
            mux.move_tab(surface, pane, index);
            Ok(json!({}))
        }
        Command::MoveWorkspace { workspace, key, index, mutation } => {
            let workspace_mutation = workspace_mutation(&mutation)?;
            let result = mux.move_workspace_with_mutation(
                workspace,
                key.as_deref(),
                index,
                mutation.expected_generation.as_deref(),
                mutation.expected_revision,
                &workspace_mutation,
            )?;
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "workspace": result.workspace,
                "key": result.key,
                "index": result.index,
                "workspace_revision": result.revision,
                "changed": result.changed,
                "replayed": result.replayed,
                "registry_id": registry_id,
                "generation": generation,
            }))
        }
        Command::SetDefaultColors {
            fg,
            bg,
            cursor,
            selection_bg,
            selection_fg,
            cursor_style,
            cursor_blink,
            palette,
            complete,
        } => {
            let current = mux.default_colors();
            let base = if complete { DefaultColors::default() } else { current };
            let palette = match palette {
                Some(entries) => {
                    let mut palette = [None; 256];
                    for (index, value) in entries {
                        let index = index
                            .parse::<u8>()
                            .map_err(|_| anyhow::anyhow!("invalid palette index {index}"))?;
                        palette[index as usize] = Some(parse_hex_color(&value)?);
                    }
                    palette
                }
                None => base.palette,
            };
            let colors = DefaultColors {
                fg: match fg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.fg,
                },
                bg: match bg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.bg,
                },
                cursor: match cursor {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.cursor,
                },
                selection_bg: match selection_bg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.selection_bg,
                },
                selection_fg: match selection_fg {
                    Some(value) => Some(parse_hex_color(&value)?),
                    None => base.selection_fg,
                },
                cursor_style: match cursor_style.as_deref() {
                    Some("block") => Some(ghostty_vt::CursorShape::Block),
                    Some("underline") => Some(ghostty_vt::CursorShape::Underline),
                    Some("bar") => Some(ghostty_vt::CursorShape::Bar),
                    Some(value) => anyhow::bail!("invalid cursor style {value}"),
                    None => base.cursor_style,
                },
                cursor_blink: cursor_blink.or(base.cursor_blink),
                palette,
            };
            mux.set_default_colors(colors);
            Ok(json!({}))
        }
        Command::CloseSurface { surface } => {
            get_surface(mux, surface)?;
            if !mux.close_surface(surface)? {
                anyhow::bail!("unknown surface {surface}");
            }
            Ok(json!({}))
        }
        Command::ClosePane { pane } => {
            if !mux.close_pane(pane)? {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::CloseScreen { screen } => {
            if !mux.close_screen(screen)? {
                anyhow::bail!("unknown screen {screen}");
            }
            Ok(json!({}))
        }
        Command::CloseWorkspace { workspace, key, mutation } => {
            let workspace_mutation = workspace_mutation(&mutation)?;
            let result = mux.close_workspace_with_mutation(
                workspace,
                key.as_deref(),
                mutation.expected_generation.as_deref(),
                mutation.expected_revision,
                &workspace_mutation,
            )?;
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "workspace": result.workspace,
                "key": result.key,
                "index": result.index,
                "workspace_revision": result.revision,
                "changed": result.changed,
                "replayed": result.replayed,
                "registry_id": registry_id,
                "generation": generation,
            }))
        }
        Command::MarkWorkspacesProviderManaged { authority } => {
            authorize_provider_workspace_command(mux, authority)?;
            Ok(json!({}))
        }
        Command::CloseProviderManagedWorkspace { workspace, key, authority } => {
            let Some(revision) = with_provider_workspace_authority(authority, |authority| {
                mux.close_provider_managed_workspace_authorized(workspace, &key, authority)
            })?
            else {
                anyhow::bail!("unknown provider-managed workspace selector");
            };
            Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
        }
        Command::RenamePane { pane, name } => {
            if !mux.rename_pane(pane, name) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::RenameSurface { surface, name } => {
            if !mux.rename_surface(surface, name) {
                anyhow::bail!("unknown surface {surface}");
            }
            Ok(json!({}))
        }
        Command::RenameScreen { screen, name } => {
            if !mux.rename_screen(screen, name) {
                anyhow::bail!("unknown screen {screen}");
            }
            Ok(json!({}))
        }
        Command::RenameWorkspace { workspace, key, name, mutation } => {
            let workspace_mutation = workspace_mutation(&mutation)?;
            let result = mux.rename_workspace_with_mutation(
                workspace,
                key.as_deref(),
                name,
                mutation.expected_generation.as_deref(),
                mutation.expected_revision,
                &workspace_mutation,
            )?;
            let (registry_id, generation) = mux.registry_identity();
            Ok(json!({
                "workspace": result.workspace,
                "key": result.key,
                "index": result.index,
                "workspace_revision": result.revision,
                "changed": result.changed,
                "replayed": result.replayed,
                "registry_id": registry_id,
                "generation": generation,
            }))
        }
        Command::RenameProviderManagedWorkspace { workspace, key, name, authority } => {
            let Some(revision) = with_provider_workspace_authority(authority, |authority| {
                mux.rename_provider_managed_workspace_authorized(workspace, &key, name, authority)
            })?
            else {
                anyhow::bail!("unknown provider-managed workspace selector");
            };
            Ok(json!({"workspace": workspace, "key": key, "workspace_revision": revision}))
        }
        Command::ResizeSurface { surface, cols, rows } => {
            let (cols, rows) = clamp_terminal_size(cols, rows);
            if mux.control_clients.surface_attachment_is_retired_without_current(client, surface)
                || (!surface_has_view_placement(mux, surface)
                    && mux
                        .control_clients
                        .surface_attachment_is_current_or_retired(client, surface))
            {
                return Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "superseded",
                }));
            }
            // Every live control connection participates through the same
            // client-size reducer. An unattached one-shot resize is removed
            // when its connection closes, so it cannot bypass visible viewers.
            // Recording and reducing happen under the sizing lock so a
            // concurrent detach cannot finish cleanup before this lease exists.
            let resize = match mux
                .resize_surface_for_control_client_with_reservation(surface, client, cols, rows)
            {
                Ok(resize) => resize,
                Err(_)
                    if mux
                        .control_clients
                        .surface_attachment_is_retired_without_current(client, surface)
                        || (!surface_has_view_placement(mux, surface)
                            && mux
                                .control_clients
                                .surface_attachment_is_current_or_retired(client, surface)) =>
                {
                    return Ok(json!({
                        "accepted": false,
                        "reservation_id": null,
                        "outcome": "superseded",
                    }));
                }
                Err(error) => return Err(error),
            };
            if let Some((true, name, kind, _)) = resize.attached {
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({
                "accepted": resize.accepted,
                "reservation_id": resize.reservation_id,
                "outcome": "applied",
            }))
        }
        Command::ResizeAttachedView { surface, lease, cols, rows } => {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            let (cols, rows) = clamp_terminal_size(cols, rows);
            match mux.control_clients.view_lease_status(client, surface, &lease)? {
                ViewLeaseStatus::Superseded => {
                    return Ok(json!({
                        "accepted": false,
                        "reservation_id": null,
                        "outcome": "superseded",
                    }));
                }
                ViewLeaseStatus::Current { .. } if !surface_has_view_placement(mux, surface) => {
                    return Ok(json!({
                        "accepted": false,
                        "reservation_id": null,
                        "outcome": "superseded",
                    }));
                }
                ViewLeaseStatus::Current { .. } => {}
            }
            match mux.control_clients.prepare_view_resize(client, surface, &lease, (cols, rows))? {
                ViewResizePreparation::Superseded => Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "superseded",
                })),
                ViewResizePreparation::Passive { .. } => Ok(json!({
                    "accepted": false,
                    "reservation_id": null,
                    "outcome": "passive",
                })),
                ViewResizePreparation::GeometryOwner { update, previous_view_size } => {
                    let resize = match mux
                        .resize_surface_for_prepared_control_client_with_completion(
                            surface,
                            client,
                            (cols, rows),
                            None,
                            Some(update),
                        ) {
                        Ok(resize) => resize,
                        Err(error) => {
                            mux.control_clients.restore_view_size(
                                client,
                                surface,
                                &lease,
                                previous_view_size,
                            );
                            if !surface_has_view_placement(mux, surface) {
                                return Ok(json!({
                                    "accepted": false,
                                    "reservation_id": null,
                                    "outcome": "superseded",
                                }));
                            }
                            return Err(error);
                        }
                    };
                    if let Some((true, name, kind, _)) = resize.attached {
                        mux.emit(MuxEvent::ClientChanged { client, name, kind });
                    }
                    Ok(json!({
                        "accepted": resize.accepted,
                        "reservation_id": resize.reservation_id,
                        "outcome": "applied",
                    }))
                }
            }
        }
        Command::ReleaseSurfaceSize { surface } => {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            if mux.control_clients.surface_attachment_is_retired_without_current(client, surface)
                || (!surface_has_view_placement(mux, surface)
                    && mux
                        .control_clients
                        .surface_attachment_is_current_or_retired(client, surface))
            {
                return Ok(json!({"outcome": "superseded"}));
            }
            let attached = mux.control_clients.clear_size(client, surface);
            let had_report = mux.client_surface_size(surface, client).is_some();
            if had_report {
                mux.remove_surface_size_client(surface, client);
            }
            let attached_changed = attached.as_ref().is_some_and(|(changed, _, _)| *changed);
            if attached_changed || (attached.is_none() && had_report) {
                let (name, kind) = attached
                    .map(|(_, name, kind)| (name, kind))
                    .or_else(|| mux.control_clients.client_info(client))
                    .unwrap_or((None, None));
                mux.emit(MuxEvent::ClientChanged { client, name, kind });
            }
            Ok(json!({"outcome": "applied"}))
        }
        Command::ReleaseAttachedViewSize { surface, lease } => {
            let _lifecycle = mux.lock_client_sizing_lifecycle();
            match mux.control_clients.view_lease_status(client, surface, &lease)? {
                ViewLeaseStatus::Superseded => {
                    return Ok(json!({"outcome": "superseded"}));
                }
                ViewLeaseStatus::Current { .. } if !surface_has_view_placement(mux, surface) => {
                    return Ok(json!({"outcome": "superseded"}));
                }
                ViewLeaseStatus::Current { .. } => {}
            }
            match mux.control_clients.release_view_size(client, surface, &lease)? {
                ViewReleasePreparation::Superseded => Ok(json!({"outcome": "superseded"})),
                ViewReleasePreparation::Passive => Ok(json!({"outcome": "passive"})),
                ViewReleasePreparation::GeometryOwner { changed, name, kind } => {
                    let had_report = mux.client_surface_size(surface, client).is_some();
                    if had_report {
                        mux.remove_surface_size_client(surface, client);
                    }
                    if changed || had_report {
                        mux.emit(MuxEvent::ClientChanged { client, name, kind });
                    }
                    Ok(json!({"outcome": "applied"}))
                }
            }
        }
        Command::DetachAttachedView { surface, lease } => {
            let Some((stream, outbound)) =
                mux.control_clients.view_stream(client, surface, &lease)?
            else {
                return Ok(json!({"outcome": "superseded"}));
            };
            // Closing the stream stops every producer immediately. Removing
            // its attachment state synchronously makes the command response a
            // cleanup fence; the attach worker's eventual duplicate detach is
            // intentionally idempotent.
            outbound.close();
            detach_committed_attach(mux, client, surface, stream);
            Ok(json!({"outcome": "applied"}))
        }
        Command::FocusPane { pane } => {
            if !mux.focus_pane(pane) {
                anyhow::bail!("unknown pane {pane}");
            }
            Ok(json!({}))
        }
        Command::SelectTab { pane, index, delta } => {
            mux.select_tab(pane, index, delta);
            Ok(json!({}))
        }
        Command::SelectScreen { index, delta } => {
            mux.select_screen(index, delta);
            Ok(json!({}))
        }
        Command::SelectWorkspace { index, delta } => {
            mux.select_workspace(index, delta);
            Ok(json!({}))
        }
        Command::ReportFocus { client_id, pane, tab } => {
            validate_client_focus_id(&client_id)?;
            if !mux.with_state(|state| state.panes.contains_key(&pane)) {
                anyhow::bail!("unknown pane {pane}");
            }
            // A report only writes memory (the session's last reported focus
            // and this client's own record). It never moves the live shared
            // focus, so other attached clients stay where they are.
            mux.record_session_focus(pane, tab);
            mux.remember_client_focus(client_id, pane, tab);
            Ok(json!({}))
        }
        Command::ClientFocus { client_id } => {
            validate_client_focus_id(&client_id)?;
            Ok(match mux.client_focus(&client_id).or_else(|| mux.session_focus()) {
                Some((pane, tab)) => json!({"pane": pane, "tab": tab}),
                None => json!({"pane": null, "tab": null}),
            })
        }
        Command::ScrollSurface { surface, delta } => {
            let surface = get_surface(mux, surface)?;
            require_pty(&surface)?;
            mux.scroll_surface_viewport(&surface, delta)?;
            Ok(json!({}))
        }
        Command::Subscribe { tree_events, surface } => {
            let tree_deltas = match tree_events.as_deref().unwrap_or("coarse") {
                "coarse" => false,
                "deltas" => true,
                other => anyhow::bail!("bad request: unsupported tree_events {other:?}"),
            };
            let events = match surface {
                Some(surface) => mux
                    .subscribe_surface_session(surface)
                    .ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?,
                None => mux.subscribe(),
            };
            let event_mux = mux.clone();
            let trusted_pairing_client = mux.control_clients.is_unix(client);
            let pending_pairings =
                if trusted_pairing_client { mux.pending_pairings() } else { Vec::new() };
            let writer = writer.clone();
            let outbound_stream = writer.start_stream(&subscription_overflow_json())?;
            std::thread::Builder::new().name("mux-events-out".into()).spawn(move || {
                let mut transport_overflow = false;
                for challenge in pending_pairings {
                    let value = json!({
                        "event": "pairing-requested",
                        "request": challenge.id,
                        "code": challenge.code,
                        "peer": challenge.peer,
                        "expires_in": challenge.expires_in,
                    });
                    if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                while writer.is_open() && outbound_stream.is_open() {
                    let event = match events.recv_timeout(STREAM_DISCONNECT_POLL) {
                        Ok(event) => event,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    let value = match &event {
                        MuxEvent::PairingRequested(_) | MuxEvent::PairingResolved { .. }
                            if !trusted_pairing_client =>
                        {
                            continue;
                        }
                        MuxEvent::PairingRequested(challenge) => json!({
                            "event": "pairing-requested",
                            "request": challenge.id,
                            "code": challenge.code,
                            "peer": challenge.peer,
                            "expires_in": challenge.expires_in,
                        }),
                        MuxEvent::PairingResolved { request } => json!({
                            "event": "pairing-resolved",
                            "request": request,
                        }),
                        MuxEvent::TreeDelta(delta) if tree_deltas => {
                            tree_delta_json(delta, &event_mux)
                        }
                        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
                        MuxEvent::TreeSelectionChanged if tree_deltas => {
                            json!({"event": "tree-changed"})
                        }
                        MuxEvent::TreeSelectionChanged => continue,
                        _ => subscribed_event_json(&event),
                    };
                    if let Err(error) = writer.send_stream_backpressured(&value, &outbound_stream) {
                        transport_overflow = error.kind() == std::io::ErrorKind::WouldBlock;
                        break;
                    }
                }
                if events.overflowed() || transport_overflow {
                    let _ = writer.send_terminal(&subscription_overflow_json(), &outbound_stream);
                }
            })?;
            Ok(json!({}))
        }
        Command::AttachSurface { surface: surface_id, mode, cols, rows } => {
            let initial_size = match (cols, rows) {
                (Some(cols), Some(rows)) => Some((cols, rows)),
                (None, None) => None,
                _ => anyhow::bail!("attach-surface cols and rows must be supplied together"),
            };
            let surface = get_surface(mux, surface_id)?;
            if surface.kind() == SurfaceKind::Browser {
                let guarded_owner = mux
                    .control_clients
                    .supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY)
                    && mux.control_clients.browser_pointer_owner(client)?
                        == BrowserPointerOwner::Client(client);
                if !guarded_owner {
                    anyhow::bail!(
                        "browser attach requires client capability \
                         {GUARDED_BROWSER_POINTER_CAPABILITY} before the first browser pointer \
                         command; upgrade or restart the cmux-tui client"
                    );
                }
            }
            let lifecycle = AttachLifecycle::default();
            let outbound_stream = writer.start_stream(&attach_overflow_json(surface_id))?;
            let render_mode = match mode.as_deref().unwrap_or("bytes") {
                "bytes" => false,
                "render" => true,
                other => anyhow::bail!("bad attach mode {other}"),
            };
            if render_mode {
                require_pty(&surface)?;
                let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
                    mark_client_attached(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.clone(),
                        initial_size,
                    )?;
                let attach = match surface.attach_render_stream() {
                    Ok(attach) => attach,
                    Err(error) => {
                        rollback_failed_attach(
                            mux,
                            client,
                            surface_id,
                            outbound_stream.id,
                            size_rollback,
                        );
                        return Err(error.into());
                    }
                };
                if let Err(error) = writer.send_initial(
                    &render_state_message(&writer.render_service, surface_id, &attach.initial),
                    &outbound_stream,
                ) {
                    handle_attach_send_error(&lifecycle, &error);
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                let worker_writer = writer.clone();
                let worker_mux = mux.clone();
                let worker_lifecycle = lifecycle.clone();
                let worker_stream = outbound_stream.clone();
                let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
                let spawned = std::thread::Builder::new()
                    .name("mux-render-attach-out".into())
                    .spawn(move || {
                        let writer = worker_writer;
                        let mux = worker_mux;
                        let lifecycle = worker_lifecycle;
                        let outbound_stream = worker_stream;
                        if worker_committed.recv().is_err() {
                            return;
                        }
                        let mut state =
                            RenderClientState::new(writer.render_service.clone(), &attach.initial);
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            let send_result =
                                match attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                                    Ok(RenderAttachFrame::Frame(frame)) => {
                                        let message = state.delta_message(surface_id, &frame);
                                        writer.send_stream_backpressured(&message, &outbound_stream)
                                    }
                                    Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom }) => {
                                        writer.send_stream_backpressured(
                                            &json!({
                                                "event": "scroll-changed",
                                                "surface": surface_id,
                                                "offset": offset,
                                                "at_bottom": at_bottom,
                                            }),
                                            &outbound_stream,
                                        )
                                    }
                                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                                };
                            if let Err(error) = send_result {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        if writer.is_open() && !lifecycle.overflowed() {
                            let _ = writer.send_stream_backpressured(
                                &json!({"event": "detached", "surface": surface_id}),
                                &outbound_stream,
                            );
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                    });
                if let Err(error) = spawned {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                commit_client_attach_and_start_worker(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.id,
                    AttachWorkerCommit {
                        start: worker_start,
                        lifecycle,
                        changed: client_changed,
                        size_rollback,
                    },
                )?;
                return Ok(lease.map_or_else(|| json!({}), |lease| json!({"lease": lease})));
            }
            if surface.kind() == SurfaceKind::Browser {
                let MarkedClientAttach {
                    lease,
                    size_rollback,
                    client_changed,
                    resize_reservation,
                    resize_completion,
                } = mark_client_attached(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.clone(),
                    initial_size,
                )?;
                if let Some(reservation) = resize_reservation
                    && let Err(error) = wait_for_initial_browser_resize(
                        resize_completion
                            .as_ref()
                            .expect("sized browser attach has a completion receiver"),
                        surface_id,
                        reservation,
                    )
                {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error);
                }
                let (state, frames) = match surface.attach_frames() {
                    Ok(attach) => attach,
                    Err(error) => {
                        lifecycle.cancel();
                        rollback_failed_attach(
                            mux,
                            client,
                            surface_id,
                            outbound_stream.id,
                            size_rollback,
                        );
                        return Err(error);
                    }
                };
                if let Err(error) = writer.send_initial(
                    &browser_state_message(surface_id, &state, true),
                    &outbound_stream,
                ) {
                    handle_attach_send_error(&lifecycle, &error);
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                if let Err(error) = spawn_attach_notification_stream(
                    mux.clone(),
                    surface_id,
                    writer.clone(),
                    lifecycle.clone(),
                    outbound_stream.clone(),
                ) {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                let worker_writer = writer.clone();
                let worker_mux = mux.clone();
                let worker_lifecycle = lifecycle.clone();
                let worker_stream = outbound_stream.clone();
                let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
                let spawned =
                    std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                        let writer = worker_writer;
                        let mux = worker_mux;
                        let lifecycle = worker_lifecycle;
                        let outbound_stream = worker_stream;
                        if worker_committed.recv().is_err() {
                            return;
                        }
                        while writer.is_open()
                            && outbound_stream.is_open()
                            && !lifecycle.is_canceled()
                        {
                            match frames.notify.recv_timeout(STREAM_DISCONNECT_POLL) {
                                Ok(()) => {}
                                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                    lifecycle.cancel();
                                    if writer.is_open() {
                                        let _ = writer.send_stream_backpressured(
                                            &json!({"event": "detached", "surface": surface_id}),
                                            &outbound_stream,
                                        );
                                    }
                                    break;
                                }
                            }
                            let update = std::mem::take(&mut *frames.slot.lock().unwrap());
                            // A frame event applies its bitmap and authority
                            // atomically. Publish it before a paired state
                            // snapshot can expose the same positive token.
                            if let Err(error) = send_browser_attach_update(
                                &writer,
                                surface_id,
                                update,
                                &outbound_stream,
                            ) {
                                handle_attach_send_error(&lifecycle, &error);
                                break;
                            }
                        }
                        report_attach_overflow(&writer, surface_id, &lifecycle, &outbound_stream);
                        detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                    });
                if let Err(error) = spawned {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
                commit_client_attach_and_start_worker(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.id,
                    AttachWorkerCommit {
                        start: worker_start,
                        lifecycle,
                        changed: client_changed,
                        size_rollback,
                    },
                )?;
                return Ok(lease.map_or_else(|| json!({}), |lease| json!({"lease": lease})));
            }
            let MarkedClientAttach { lease, size_rollback, client_changed, .. } =
                mark_client_attached(
                    mux,
                    client,
                    surface_id,
                    outbound_stream.clone(),
                    initial_size,
                )?;
            let attach = match surface.attach_stream_with_lifecycle(lifecycle.clone()) {
                Ok(attach) => attach,
                Err(error) => {
                    lifecycle.cancel();
                    rollback_failed_attach(
                        mux,
                        client,
                        surface_id,
                        outbound_stream.id,
                        size_rollback,
                    );
                    return Err(error.into());
                }
            };
            let initial = VtStateMessage {
                surface: surface_id,
                cols: attach.cols,
                rows: attach.rows,
                replay: attach.replay.clone(),
                kitty_image_aliases: attach.kitty_image_aliases.clone(),
                kitty_state: attach.kitty_state,
                colors: terminal_colors_json(attach.colors),
            };
            if let Err(error) = writer.send_initial_vt_state(&initial, &outbound_stream) {
                handle_attach_send_error(&lifecycle, &error);
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            if let Err(error) = spawn_attach_notification_stream(
                mux.clone(),
                surface_id,
                writer.clone(),
                lifecycle.clone(),
                outbound_stream.clone(),
            ) {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            let worker_writer = writer.clone();
            let worker_mux = mux.clone();
            let worker_stream = outbound_stream.clone();
            let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
            let spawned =
                std::thread::Builder::new().name("mux-attach-out".into()).spawn(move || {
                    let writer = worker_writer;
                    let mux = worker_mux;
                    let outbound_stream = worker_stream;
                    if worker_committed.recv().is_err() {
                        return;
                    }
                    while writer.is_open()
                        && outbound_stream.is_open()
                        && !attach.lifecycle.is_canceled()
                    {
                        let frame = match attach.stream.recv_timeout(STREAM_DISCONNECT_POLL) {
                            Ok(frame) => frame,
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                                attach.lifecycle.cancel();
                                if writer.is_open() {
                                    let _ = writer.send_stream_backpressured(
                                        &json!({"event": "detached", "surface": surface_id}),
                                        &outbound_stream,
                                    );
                                }
                                break;
                            }
                        };
                        if let Err(error) = writer.send_attach_frame_backpressured(
                            surface_id,
                            &frame,
                            &outbound_stream,
                        ) {
                            handle_attach_send_error(&attach.lifecycle, &error);
                            break;
                        }
                    }
                    report_attach_overflow(
                        &writer,
                        surface_id,
                        &attach.lifecycle,
                        &outbound_stream,
                    );
                    detach_committed_attach(&mux, client, surface_id, outbound_stream.id);
                });
            if let Err(error) = spawned {
                lifecycle.cancel();
                rollback_failed_attach(mux, client, surface_id, outbound_stream.id, size_rollback);
                return Err(error.into());
            }
            commit_client_attach_and_start_worker(
                mux,
                client,
                surface_id,
                outbound_stream.id,
                AttachWorkerCommit {
                    start: worker_start,
                    lifecycle,
                    changed: client_changed,
                    size_rollback,
                },
            )?;
            Ok(lease.map_or_else(|| json!({}), |lease| json!({"lease": lease})))
        }
    }
}

fn stamped_build_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_BUILD_COMMIT")
        .or(option_env!("CMUX_MUX_BUILD_COMMIT"))
        .filter(|commit| !commit.is_empty())
}

fn stamped_ghostty_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty())
}

fn subscribed_event_json(event: &MuxEvent) -> Value {
    match event {
        MuxEvent::SurfaceOutput(id) => json!({"event": "surface-output", "surface": id}),
        MuxEvent::SurfaceResized { surface, cols, rows, reservation_id } => json!({
            "event": "surface-resized",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceResizeFailed {
            surface,
            cols,
            rows,
            error,
            retry_after_ms,
            reservation_id,
        } => json!({
            "event": "surface-resize-failed",
            "surface": surface,
            "cols": cols,
            "rows": rows,
            "error": error.as_ref(),
            "retry_after_ms": retry_after_ms,
            "reservation_id": reservation_id,
        }),
        MuxEvent::SurfaceExited(id) => json!({"event": "surface-exited", "surface": id}),
        MuxEvent::TitleChanged { surface, title } => {
            json!({"event": "title-changed", "surface": surface, "title": title.as_ref()})
        }
        MuxEvent::AgentChanged { surface, state, source, session, updated_at_ms } => json!({
            "event": "agent-changed",
            "surface": surface,
            "state": state.as_ref(),
            "source": source.as_ref(),
            "session": session.as_deref(),
            "updated_at_ms": updated_at_ms,
        }),
        MuxEvent::Bell(id) => json!({"event": "bell", "surface": id}),
        MuxEvent::Notification(notification) => json!({
            "event": "notification",
            "notification": notification.notification,
            "title": notification.title,
            "body": notification.body,
            "level": notification.level.as_str(),
            "surface": notification.surface,
        }),
        MuxEvent::GraphicsStatus(status) => match status {
            GraphicsStatus::KittyImageBudgetWorkerStartFailed { error } => json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-worker-start-failed",
                "error": error.as_ref(),
            }),
            GraphicsStatus::KittyImageBudgetUpdateFailed { retry_exhausted, summary } => json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-update-failed",
                "retry_exhausted": retry_exhausted,
                "summary": summary.as_ref(),
            }),
            GraphicsStatus::CellPixelUpdateRetriesExhausted {
                attempts,
                remaining,
                cell_pixels,
            } => json!({
                "event": "graphics-status",
                "kind": "cell-pixel-update-retries-exhausted",
                "attempts": attempts,
                "remaining": remaining,
                "cell_width": cell_pixels.0,
                "cell_height": cell_pixels.1,
            }),
        },
        MuxEvent::Status(message) => json!({"event": "status", "message": message}),
        MuxEvent::ConfigReloadRequested => json!({"event": "config-reload-requested"}),
        MuxEvent::WindowTitleRequested(title) => {
            json!({"event": "window-title-requested", "title": title})
        }
        MuxEvent::ScrollChanged { surface, offset, at_bottom } => json!({
            "event": "scroll-changed",
            "surface": surface,
            "offset": offset,
            "at_bottom": at_bottom,
        }),
        MuxEvent::TreeChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeSelectionChanged => json!({"event": "tree-changed"}),
        MuxEvent::TreeDelta(_) => json!({"event": "tree-changed"}),
        MuxEvent::FrontendProjectionChanged {
            frontend,
            scope,
            subject_key,
            projection_revision,
            origin,
            mutation_id,
        } => json!({
            "event": "frontend-projection-changed",
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "projection_revision": projection_revision,
            "origin": origin,
            "mutation_id": mutation_id,
        }),
        MuxEvent::TerminalRegistryChanged { registry_id, generation, terminal_revision } => json!({
            "event":"terminal-registry-changed",
            "registry_id":registry_id,
            "generation":generation,
            "terminal_revision":terminal_revision,
            "refetch":"terminal-events-or-list-terminals",
        }),
        MuxEvent::LayoutChanged(screen) => json!({"event": "layout-changed", "screen": screen}),
        MuxEvent::ClientAttached { client, transport, name, kind } => json!({
            "event": "client-attached",
            "client": client,
            "transport": transport,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientChanged { client, name, kind } => json!({
            "event": "client-changed",
            "client": client,
            "name": name,
            "kind": kind,
        }),
        MuxEvent::ClientDetached(client) => {
            json!({"event": "client-detached", "client": client})
        }
        MuxEvent::ClientListInvalidated => json!({"event": "client-list-invalidated"}),
        MuxEvent::PairingRequested(challenge) => json!({
            "event": "pairing-requested",
            "request": challenge.id,
            "code": challenge.code,
            "peer": challenge.peer,
            "expires_in": challenge.expires_in,
        }),
        MuxEvent::PairingResolved { request } => {
            json!({"event": "pairing-resolved", "request": request})
        }
        MuxEvent::Empty => json!({"event": "empty"}),
    }
}

fn subscription_overflow_json() -> Value {
    json!({
        "event": "overflow",
        "error": "subscriber fell behind; resubscribe to continue receiving events",
    })
}

fn attach_overflow_json(surface: SurfaceId) -> Value {
    json!({
        "event": "overflow",
        "scope": "surface",
        "surface": surface,
        "error": "surface stream fell behind; reattach the surface",
    })
}

/// Remove the socket file (call on clean shutdown).
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        BrowserFrame, BrowserStatus, JournalProducer, JournalReplayPolicy, JournalSubject,
        ProviderWorkspaceAuthority, SessionJournalRecord, SidebarPluginOptions, SurfaceOptions,
    };
    use ghostty_vt::{Callbacks, RenderState, Terminal};
    use std::sync::mpsc::TryRecvError;
    use std::time::Duration;

    static NEXT_TEST_SOCKET_DIR: AtomicU64 = AtomicU64::new(1);

    #[test]
    fn json_line_limit_excludes_the_newline_delimiter() {
        let exact_payload = "x".repeat(MAX_JSON_LINE_BYTES);
        assert_eq!(json_line_payload_len(&exact_payload), MAX_JSON_LINE_BYTES);

        let mut exact_line = exact_payload;
        exact_line.push('\n');
        assert_eq!(json_line_payload_len(&exact_line), MAX_JSON_LINE_BYTES);

        let oversized_payload = "x".repeat(MAX_JSON_LINE_BYTES + 1);
        assert!(json_line_payload_len(&oversized_payload) > MAX_JSON_LINE_BYTES);

        let mut oversized_line = oversized_payload;
        oversized_line.push('\n');
        assert!(json_line_payload_len(&oversized_line) > MAX_JSON_LINE_BYTES);
    }

    struct TestSocketDir(PathBuf);

    impl TestSocketDir {
        fn create(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "cmux-tui-server-{name}-{}-{}",
                std::process::id(),
                NEXT_TEST_SOCKET_DIR.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestSocketDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn default_socket_path_preserves_compatible_runtime_dir() {
        let runtime_dir = PathBuf::from("/tmp/cmux-tui-compat");
        assert_eq!(
            default_socket_path_in_runtime_dir("main", runtime_dir.clone()),
            runtime_dir.join("main.sock")
        );
    }

    #[test]
    fn session_name_validation_rejects_path_escape_input() {
        for session in ["", ".", "..", "../escape", "nested/session", "nested\\session"] {
            assert!(validate_session_name(session).is_err(), "accepted {session:?}");
        }
        assert!(validate_session_name("main").is_ok());
        assert!(validate_session_name("legacy name").is_ok());
        assert_ne!(default_socket_path("../escape"), default_socket_path("main"));
    }

    #[test]
    fn journal_filter_rejects_secret_max_sensitivity() {
        let error = JournalStreamFilter::parse(Some(&json!({
            "max_sensitivity":"secret",
        })))
        .err()
        .expect("secret journal sensitivity must be rejected");
        assert_eq!(error.code, "validation.invalid");
        assert_eq!(error.details["field"], "filter.max_sensitivity");
    }

    #[test]
    fn indeterminate_journal_commit_remains_retryable() {
        let error = journal_extension_error(
            "session.journal.append",
            anyhow::Error::new(crate::journal_ingress::JournalCommitIndeterminate::after(
                Duration::from_secs(3),
            )),
        );

        assert_eq!(error.code, "transport.closed");
        assert!(error.retryable);
        assert!(error.message.contains("indeterminate"));
    }

    #[test]
    fn journal_filter_requires_an_explicit_sensitive_opt_in() {
        assert_eq!(
            JournalStreamFilter::parse(None).unwrap().max_sensitivity,
            Some(JournalSensitivity::Metadata)
        );
        assert_eq!(
            JournalStreamFilter::parse(Some(&json!({}))).unwrap().max_sensitivity,
            Some(JournalSensitivity::Metadata)
        );
        assert_eq!(
            JournalStreamFilter::parse(Some(&json!({"max_sensitivity":"sensitive"})))
                .unwrap()
                .max_sensitivity,
            Some(JournalSensitivity::Sensitive)
        );
    }

    #[cfg(unix)]
    #[test]
    fn default_socket_path_falls_back_for_long_tmpdir() {
        let long_tmpdir = PathBuf::from("/tmp").join("x".repeat(200));
        let preferred_runtime_dir = long_tmpdir.join("cmux-tui-test-user");
        let path = default_socket_path_in_runtime_dir(
            "cmux-browser-0123456789abcdef",
            preferred_runtime_dir,
        );

        assert_eq!(
            path,
            platform::fallback_runtime_dir().join("cmux-browser-0123456789abcdef.sock")
        );
        assert!(unix_socket_path_fits(&path));
        assert_ne!(path.parent(), Some(Path::new("/tmp")));
    }

    #[cfg(unix)]
    #[test]
    fn default_socket_path_hash_prefers_runtime_base_and_falls_back_to_tmp() {
        let session = format!("legacy-{}", "x".repeat(200));
        let preferred_runtime = PathBuf::from("/run/user/501/cmux-tui-501");
        let preferred = default_socket_path_in_runtime_dir(&session, preferred_runtime);
        assert_eq!(
            preferred,
            platform::hashed_runtime_dir_for_base(Path::new("/run/user/501"))
                .join("e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock",)
        );
        assert!(unix_socket_path_fits(&preferred));

        let long_base = PathBuf::from("/tmp").join("x".repeat(200));
        let fallback =
            default_socket_path_in_runtime_dir(&session, long_base.join("cmux-tui-test-user"));
        assert!(fallback.starts_with(platform::fallback_hashed_runtime_dir()));
        assert!(unix_socket_path_fits(&fallback));
    }

    #[cfg(unix)]
    #[test]
    fn runtime_socket_directory_rejects_symlinks_and_non_directories() {
        use std::os::unix::fs::symlink;

        let root = TestSocketDir::create("runtime-directory-security");
        let target = root.path().join("target");
        std::fs::create_dir(&target).unwrap();
        let alias = root.path().join("alias");
        symlink(&target, &alias).unwrap();
        assert!(prepare_runtime_socket_directory(&alias).is_err());

        let file = root.path().join("file");
        std::fs::write(&file, b"not a directory").unwrap();
        assert!(prepare_runtime_socket_directory(&file).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn runtime_socket_directory_tightens_existing_owned_directory() {
        use std::os::unix::fs::PermissionsExt;

        let root = TestSocketDir::create("runtime-directory-mode");
        let directory = root.path().join("runtime");
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        prepare_runtime_socket_directory(&directory).unwrap();
        assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[cfg(unix)]
    #[test]
    fn serve_paused_preserves_explicit_socket_parent_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let root = TestSocketDir::create("explicit-runtime-directory");
        let directory = root.path().join("socket-parent");
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        let pending = serve_paused(test_mux(), Some(directory.join("mux.sock"))).unwrap();
        drop(pending);
        assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o755);
    }

    #[test]
    fn serve_paused_creates_missing_explicit_socket_parent() {
        let root = TestSocketDir::create("explicit-runtime-directory-missing");
        let directory = root.path().join("missing").join("nested");
        let socket = directory.join("mux.sock");
        let pending = serve_paused(test_mux(), Some(socket.clone())).unwrap();
        drop(pending);
        assert!(directory.is_dir());
        assert!(!socket.exists());
    }

    #[cfg(unix)]
    #[test]
    fn unix_socket_path_reserves_trailing_nul() {
        const SUN_PATH_CAPACITY: usize =
            size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
        assert!(unix_socket_path_fits(Path::new(&"x".repeat(SUN_PATH_CAPACITY - 1))));
        assert!(!unix_socket_path_fits(Path::new(&"x".repeat(SUN_PATH_CAPACITY))));
    }

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("test", SurfaceOptions::default())
    }

    fn sizing_browser(mux: &Arc<Mux>, size: (u16, u16)) -> Arc<crate::Surface> {
        mux.new_browser_tab("about:blank#client-sizing".to_string(), None, Some(size)).unwrap()
    }

    fn settle_browser_size(surface: &Arc<crate::Surface>, expected: (u16, u16)) {
        if surface.size() != expected {
            if let Some(pending) =
                surface.pending_resize_completion(expected.0, expected.1).unwrap()
            {
                wait_for_initial_browser_resize(
                    &pending.completion,
                    surface.id,
                    pending.reservation,
                )
                .unwrap();
            } else {
                // The resize worker may commit between the size observation
                // above and the pending-completion lookup. Absence is valid
                // only when that exact resize has already landed.
                assert_eq!(surface.size(), expected);
            }
        }
        assert_eq!(surface.size(), expected);
    }

    fn settle_marked_browser_resize(surface: &Arc<crate::Surface>, marked: &MarkedClientAttach) {
        if let Some(reservation) = marked.resize_reservation {
            wait_for_initial_browser_resize(
                marked
                    .resize_completion
                    .as_ref()
                    .expect("sized browser attach has a completion receiver"),
                surface.id,
                reservation,
            )
            .unwrap();
        }
    }

    const PROVIDER_AUTHORITY: &str = "provider-workspace-authority-for-server-tests-00000001";

    fn provider_test_mux() -> Arc<Mux> {
        Mux::new_provider_managed_for_test(
            "provider-test",
            SurfaceOptions::default(),
            ProviderWorkspaceAuthority::new(PROVIDER_AUTHORITY).unwrap(),
        )
    }

    fn test_writer() -> MessageWriter {
        MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        })
    }

    struct TestSocket {
        directory: PathBuf,
        path: PathBuf,
    }

    impl TestSocket {
        fn new(label: &str) -> Self {
            static SEQUENCE: AtomicU64 = AtomicU64::new(0);

            let directory = loop {
                let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
                let candidate = std::env::temp_dir()
                    .join(format!("cmux-tui-test-{}-{sequence}", std::process::id()));
                match std::fs::create_dir(&candidate) {
                    Ok(()) => break candidate,
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => panic!("create private test socket directory: {error}"),
                }
            };
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
                    .expect("secure private test socket directory");
            }
            let path = directory.join(format!("{label}.sock"));
            #[cfg(unix)]
            assert!(unix_socket_path_fits(&path));
            Self { directory, path }
        }
    }

    impl Drop for TestSocket {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
            let _ = std::fs::remove_dir(&self.directory);
        }
    }

    fn render_protocol_frame(
        terminal: &mut Terminal,
        render_state: &mut RenderState,
    ) -> SurfaceRenderFrame {
        render_state.update(terminal).unwrap();
        SurfaceRenderFrame {
            frame: render_state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: terminal.history_epoch(),
            pointer_semantics: terminal.pointer_semantic_snapshot(),
            palette_colors: [Rgb::default(); 256],
            palette_overridden: [false; 256],
        }
    }

    fn render_protocol_client(
        terminal: &mut Terminal,
        render_state: &mut RenderState,
    ) -> RenderClientState {
        RenderClientState::new(
            Arc::new(RenderService::new()),
            &render_protocol_frame(terminal, render_state),
        )
    }

    fn replace_render_image(
        frame: &mut SurfaceRenderFrame,
        image_id: u32,
        pixels: impl Into<Arc<[u8]>>,
    ) {
        let graphics = Arc::make_mut(&mut frame.frame.kitty_graphics);
        graphics.generation += 1;
        let image = graphics.images.iter_mut().find(|image| image.id == image_id).unwrap();
        image.generation += 1;
        image.data = pixels.into();
        let delta = Arc::make_mut(&mut frame.frame.kitty_graphics_delta);
        delta.previous_snapshot_id = Some(delta.snapshot_id);
        delta.snapshot_id = delta.snapshot_id.wrapping_add(1);
        delta.image_revision = delta.image_revision.wrapping_add(1);
        delta.image_generations = graphics
            .images
            .iter()
            .map(|image| (image.id, image.generation))
            .collect::<Vec<_>>()
            .into();
        delta.changed_image_ids = Arc::from([image_id]);
        delta.removed_image_ids = Arc::from([]);
    }

    const RED_IMAGE_41: &[u8] = b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\";
    const GREEN_IMAGE_42: &[u8] = b"\x1b_Ga=T,t=d,f=24,i=42,p=8,s=1,v=1,c=1,r=1,q=2;AP8A\x1b\\";
    const LARGE_RENDER_IMAGE_WIDTH: usize = 1_024;
    const LARGE_RENDER_IMAGE_HEIGHT: usize = 768;
    const LARGE_RENDER_IMAGE_RAW_BYTES: usize =
        LARGE_RENDER_IMAGE_WIDTH * LARGE_RENDER_IMAGE_HEIGHT * 4;
    const LARGE_RENDER_IMAGE_BASE64_CHARS: usize = LARGE_RENDER_IMAGE_RAW_BYTES.div_ceil(3) * 4;

    fn large_rgba_kitty_transmission() -> Vec<u8> {
        let data = base64::engine::general_purpose::STANDARD
            .encode(vec![0x7f; LARGE_RENDER_IMAGE_RAW_BYTES]);
        assert_eq!(data.len(), LARGE_RENDER_IMAGE_BASE64_CHARS);
        format!(
            "\x1b_Ga=T,t=d,f=32,i=51,p=1,s={LARGE_RENDER_IMAGE_WIDTH},v={LARGE_RENDER_IMAGE_HEIGHT},c=80,r=24,q=2;{data}\x1b\\"
        )
        .into_bytes()
    }

    #[test]
    fn large_rgba_render_state_serializes_and_queues_within_websocket_budget() {
        assert_eq!(LARGE_RENDER_IMAGE_RAW_BYTES, 3_145_728);
        assert_eq!(LARGE_RENDER_IMAGE_BASE64_CHARS, 4_194_304);

        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(&large_rgba_kitty_transmission());
        let mut render_state = RenderState::new().unwrap();
        let frame = render_protocol_frame(&mut terminal, &mut render_state);
        let value = render_state_message(&RenderService::new(), 7, &frame);
        let serialized = serde_json::to_string(&value).unwrap();

        assert_eq!(
            value.graphics.images.as_ref().unwrap()[0].data.len(),
            LARGE_RENDER_IMAGE_BASE64_CHARS
        );
        assert!(
            serialized.len() > 4 * 1024 * 1024,
            "JSON overhead must put the payload beyond the old 4 MiB boundary"
        );
        assert!(
            serialized.len() <= OUTBOUND_BYTE_CAPACITY,
            "{}-byte render state exceeds the configured {}-byte outbound boundary",
            serialized.len(),
            OUTBOUND_BYTE_CAPACITY
        );

        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
        writer.send_initial(&value, &stream).unwrap();
        assert_eq!(outbound.try_pop().unwrap(), serialized);
        assert!(writer.is_open());
        assert!(stream.is_open());
        eprintln!("1024x768 RGBA render-state bytes: {}", serialized.len());
    }

    #[test]
    fn render_image_base64_cache_shares_encodes_and_evicts_within_its_byte_cap() {
        let first_pixels: Arc<[u8]> = Arc::from([1_u8, 2, 3, 4, 5, 6]);
        let second_pixels: Arc<[u8]> = Arc::from([7_u8, 8, 9, 10, 11, 12]);
        let encoded_len = base64::engine::general_purpose::STANDARD.encode(&*first_pixels).len();
        let mut cache = RenderGraphicBase64Cache::new(encoded_len, 2);

        let first = cache.encode(&first_pixels);
        let shared = cache.encode(&first_pixels);
        assert!(Arc::ptr_eq(&first, &shared), "same immutable pixels were encoded twice");
        assert_eq!(cache.entries.len(), 1);
        assert_eq!(cache.retained_bytes, encoded_len);

        let second = cache.encode(&second_pixels);
        assert_eq!(cache.entries.len(), 1);
        assert_eq!(cache.retained_bytes, encoded_len);
        assert!(!Arc::ptr_eq(&first, &second));
        assert!(
            cache.entries.values().all(|entry| {
                entry.source.upgrade().is_some_and(|source| Arc::ptr_eq(&source, &second_pixels))
            }),
            "byte-cap eviction retained the older image"
        );
    }

    #[test]
    fn render_graphics_message_borrows_the_shared_base64_payload() {
        let service = RenderService::new();
        let pixels: Arc<[u8]> = Arc::from([1_u8, 2, 3, 4, 5, 6]);
        let encoded = service.encode_graphic(&pixels);
        let graphics = ghostty_vt::KittyGraphicsSnapshot {
            generation: 1,
            images: vec![ghostty_vt::KittyImage {
                id: 1,
                number: 0,
                generation: 1,
                width: 2,
                height: 1,
                format: ghostty_vt::KittyImageFormat::Rgb,
                data: pixels,
            }],
            placements: Vec::new(),
        };

        let message = render_graphics_message(&service, &graphics, None, &[], true);
        let data = &message.images.as_ref().unwrap()[0].data;

        assert!(
            Arc::ptr_eq(data, &encoded),
            "render message copied the cached base64 payload before serialization"
        );
    }

    #[test]
    fn outbound_memory_budget_is_shared_across_connections() {
        let first_overflow = attach_overflow_json(1);
        let second_overflow = attach_overflow_json(2);
        let message = json!({"event": "render-state", "data": "x".repeat(300)});
        let budget = serde_json::to_vec(&first_overflow).unwrap().len()
            + serde_json::to_vec(&second_overflow).unwrap().len()
            + serde_json::to_vec(&message).unwrap().len();
        let service = Arc::new(RenderService::new_with_outbound_budget(budget));
        let first_outbound = Arc::new(BoundedOutbound::default());
        let second_outbound = Arc::new(BoundedOutbound::default());
        let first = MessageWriter::new_with_render_service(
            QueuedSink { outbound: first_outbound.clone(), control: None },
            service.clone(),
        );
        let second = MessageWriter::new_with_render_service(
            QueuedSink { outbound: second_outbound, control: None },
            service,
        );
        let first_stream = first.start_stream(&first_overflow).unwrap();
        let second_stream = second.start_stream(&second_overflow).unwrap();

        first.send_initial(&message, &first_stream).unwrap();
        let error = second.send_initial(&message, &second_stream).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);

        drop(first_outbound.try_pop().expect("first queued message"));
        second.send_initial(&message, &second_stream).unwrap();
    }

    #[test]
    fn global_render_pressure_does_not_starve_control_replies() {
        let overflow = attach_overflow_json(1);
        let render = json!({"event": "render-state", "data": "x".repeat(300)});
        let render_bytes = {
            let probe = RenderService::new_with_outbound_budget(usize::MAX);
            probe.serialize(&render).unwrap().retained_bytes
        };
        let service = Arc::new(RenderService::new_with_outbound_budgets(render_bytes, 1_024));
        let render_outbound = Arc::new(BoundedOutbound::default());
        let control_outbound = Arc::new(BoundedOutbound::default());
        let render_writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: render_outbound, control: None },
            service.clone(),
        );
        let control_writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: control_outbound.clone(), control: None },
            service,
        );
        let render_stream = render_writer.start_stream(&overflow).unwrap();
        let blocked_stream = control_writer.start_stream(&overflow).unwrap();

        render_writer.send_initial(&render, &render_stream).unwrap();
        assert_eq!(
            control_writer.send_initial(&render, &blocked_stream).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        control_writer.send_control(&json!({"id": 7, "ok": true})).unwrap();

        let reply: Value = serde_json::from_str(&control_outbound.try_pop().unwrap()).unwrap();
        assert_eq!(reply["id"], 7);
        assert!(control_writer.is_open());
    }

    #[test]
    fn render_service_shares_cache_across_connections_and_releases_it_with_its_owner() {
        let service = Arc::new(RenderService::new());
        let weak = Arc::downgrade(&service);
        let first_writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None },
            service.clone(),
        );
        let second_writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None },
            service.clone(),
        );
        let pixels: Arc<[u8]> = Arc::from([1_u8, 2, 3, 4, 5, 6]);

        let first = first_writer.render_service.encode_graphic(&pixels);
        let second = second_writer.render_service.encode_graphic(&pixels);
        assert!(Arc::ptr_eq(&first, &second));

        drop(service);
        assert!(weak.upgrade().is_some(), "connection writers must retain their server service");
        drop(first_writer);
        drop(second_writer);
        assert!(weak.upgrade().is_none(), "the cache outlived its server and connections");
    }

    #[test]
    fn render_budget_covers_max_image_and_placement_metadata() {
        let placement = ghostty_vt::KittyPlacement {
            key: ghostty_vt::KittyPlacementKey {
                image_id: u32::MAX,
                placement_id: u32::MAX,
                ordinal: u32::MAX,
            },
            image_id: u32::MAX,
            placement_id: u32::MAX,
            is_internal: false,
            x_offset: u32::MAX,
            y_offset: u32::MAX,
            source_x: u32::MAX,
            source_y: u32::MAX,
            source_width: u32::MAX,
            source_height: u32::MAX,
            columns: u32::MAX,
            rows: u32::MAX,
            grid_cols: u32::MAX,
            grid_rows: u32::MAX,
            pixel_width: u32::MAX,
            pixel_height: u32::MAX,
            viewport_col: i32::MIN,
            viewport_row: i32::MIN,
            viewport_visible: false,
            anchor: Some(ghostty_vt::KittyPlacementAnchor { col: u16::MAX, row: u32::MAX }),
            z: i32::MIN,
        };
        let graphics = ghostty_vt::KittyGraphicsSnapshot {
            generation: u64::MAX,
            images: Vec::new(),
            placements: vec![placement],
        };
        let message = render_graphics_message(&RenderService::new(), &graphics, None, &[], true);
        let serialized = serde_json::to_value(&message).unwrap();
        let placement_bytes = serde_json::to_string(&serialized["placements"][0]).unwrap().len();
        let placement_array_bytes = 2
            + placement_bytes * RENDER_GRAPHIC_MAX_PLACEMENTS
            + RENDER_GRAPHIC_MAX_PLACEMENTS.saturating_sub(1);
        let image_base64_bytes = RENDER_GRAPHIC_MAX_DECODED_BYTES.div_ceil(3) * 4;
        let required_without_rows = image_base64_bytes + placement_array_bytes;

        assert_eq!(placement_bytes, 485);
        assert_eq!(placement_array_bytes, 7_962_625);
        assert_eq!(image_base64_bytes, 13_333_336);
        assert_eq!(required_without_rows, 21_295_961);
        assert_eq!(placement_bytes, RENDER_GRAPHIC_MAX_PLACEMENT_JSON_BYTES);
        assert_eq!(placement_array_bytes, RENDER_GRAPHIC_MAX_PLACEMENT_ARRAY_BYTES);
        assert_eq!(image_base64_bytes, RENDER_GRAPHIC_MAX_ENCODED_BYTES);
        assert_eq!(OUTBOUND_BYTE_CAPACITY - required_without_rows, 12_258_471);
        assert!(
            required_without_rows < OUTBOUND_BYTE_CAPACITY,
            "{required_without_rows} image and placement bytes exceed the configured \
             {OUTBOUND_BYTE_CAPACITY}-byte outbound boundary before rows and wrapper metadata"
        );
    }

    #[test]
    fn render_delta_omits_graphics_for_text_only_damage() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(RED_IMAGE_41);
        let mut render_state = RenderState::new().unwrap();
        let mut client = render_protocol_client(&mut terminal, &mut render_state);

        terminal.vt_write(b"text");
        let frame = render_protocol_frame(&mut terminal, &mut render_state);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();

        assert!(delta.get("graphics").is_none(), "{delta:#}");
    }

    #[test]
    fn render_delta_sends_placement_geometry_without_unchanged_pixels() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(RED_IMAGE_41);
        let mut render_state = RenderState::new().unwrap();
        let mut client = render_protocol_client(&mut terminal, &mut render_state);

        terminal.vt_write(b"\x1b[3G\x1b_Ga=p,i=41,p=9,c=1,r=1,q=2;\x1b\\");
        let frame = render_protocol_frame(&mut terminal, &mut render_state);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
        let graphics = &delta["graphics"];

        assert!(graphics.get("images").is_none(), "{delta:#}");
        assert!(graphics.get("removed_image_ids").is_none(), "{delta:#}");
        assert_eq!(graphics["placements"].as_array().unwrap().len(), 2);
        assert!(graphics["placements"].as_array().unwrap().iter().any(|placement| {
            placement["placement_id"] == 9
                && placement["viewport_col"] == 2
                && placement["anchor_col"] == 2
                && placement["anchor_row"] == 0
        }));
    }

    #[test]
    fn placing_an_initially_unplaced_image_does_not_resend_its_pixels() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,i=43,s=1,v=1,q=2;/wAA\x1b\\");
        let mut render_state = RenderState::new().unwrap();
        let mut initial = render_protocol_frame(&mut terminal, &mut render_state);
        initial.frame.kitty_graphics =
            render_state.snapshot_kitty_graphics(&terminal, true).unwrap();
        assert!(initial.frame.kitty_graphics.image(43).is_some());
        assert!(initial.frame.kitty_graphics_delta.image_generations.is_empty());
        let mut client = RenderClientState::new(Arc::new(RenderService::new()), &initial);

        terminal.vt_write(b"\x1b_Ga=p,i=43,p=9,c=1,r=1,q=2;\x1b\\");
        let frame = render_protocol_frame(&mut terminal, &mut render_state);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
        let graphics = &delta["graphics"];

        assert!(graphics.get("images").is_none(), "{delta:#}");
        assert_eq!(graphics["placements"].as_array().unwrap().len(), 1);
        assert_eq!(graphics["placements"][0]["image_id"], 43);
    }

    #[test]
    fn deleting_an_initially_unplaced_image_releases_client_pixels() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,i=43,s=1,v=1,q=2;/wAA\x1b\\");
        let mut render_state = RenderState::new().unwrap();
        let mut initial = render_protocol_frame(&mut terminal, &mut render_state);
        initial.frame.kitty_graphics =
            render_state.snapshot_kitty_graphics(&terminal, true).unwrap();
        let mut client = RenderClientState::new(Arc::new(RenderService::new()), &initial);

        terminal.vt_write(b"\x1b_Ga=d,d=I,i=43,q=2;\x1b\\");
        let frame = render_protocol_frame(&mut terminal, &mut render_state);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();

        assert_eq!(delta["graphics"]["removed_image_ids"], json!([43]), "{delta:#}");
        assert!(delta["graphics"].get("images").is_none(), "{delta:#}");
    }

    #[test]
    fn render_delta_upserts_only_images_with_changed_generations() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(RED_IMAGE_41);
        terminal.vt_write(GREEN_IMAGE_42);
        let mut render_state = RenderState::new().unwrap();
        let mut frame = render_protocol_frame(&mut terminal, &mut render_state);
        let mut client = RenderClientState::new(Arc::new(RenderService::new()), &frame);
        replace_render_image(&mut frame, 41, [0, 0, 255]);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
        let images = delta["graphics"]["images"].as_array().unwrap();

        assert_eq!(images.len(), 1, "{delta:#}");
        assert_eq!(images[0]["id"], 41);
        assert_eq!(images[0]["data"], "AAD/");
        assert!(delta["graphics"].get("placements").is_none(), "{delta:#}");
    }

    #[test]
    fn pixel_only_render_delta_does_not_rescan_the_full_graphics_scene() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(RED_IMAGE_41);
        terminal.vt_write(GREEN_IMAGE_42);
        let mut render_state = RenderState::new().unwrap();
        let mut frame = render_protocol_frame(&mut terminal, &mut render_state);
        let placement_revision = frame.frame.kitty_graphics_delta.placement_revision;
        let mut client = RenderClientState::new(Arc::new(RenderService::new()), &frame);

        replace_render_image(&mut frame, 41, [0, 0, 255]);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();

        assert_eq!(
            delta["graphics"]["images"]
                .as_array()
                .unwrap_or_else(|| panic!("pixel update omitted graphics: {delta:#}"))
                .len(),
            1
        );
        assert_eq!(
            client.image_generation_scan_count, 0,
            "pixel-only animation rebuilt the complete image-generation map"
        );
        assert_eq!(
            frame.frame.kitty_graphics_delta.placement_revision, placement_revision,
            "pixel-only animation changed the shared placement revision"
        );
    }

    #[test]
    fn render_client_that_skips_a_graphics_frame_falls_back_to_one_linear_diff() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(RED_IMAGE_41);
        terminal.vt_write(GREEN_IMAGE_42);
        let mut render_state = RenderState::new().unwrap();
        let initial = render_protocol_frame(&mut terminal, &mut render_state);
        let mut client = RenderClientState::new(Arc::new(RenderService::new()), &initial);
        let mut skipped = initial;
        replace_render_image(&mut skipped, 41, [0, 0, 255]);
        let mut latest = skipped;
        replace_render_image(&mut latest, 42, [255, 255, 0]);

        let delta = serde_json::to_value(client.delta_message(1, &latest)).unwrap();
        let images = delta["graphics"]["images"].as_array().unwrap();

        assert_eq!(images.len(), 2, "{delta:#}");
        assert_eq!(
            client.image_generation_scan_count, 2,
            "a skipped frame did not use one bounded linear image diff"
        );
        assert!(delta["graphics"].get("placements").is_none(), "{delta:#}");
    }

    #[test]
    fn render_delta_reports_deleted_image_ids_without_resending_survivors() {
        let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
        terminal.vt_write(RED_IMAGE_41);
        terminal.vt_write(GREEN_IMAGE_42);
        let mut render_state = RenderState::new().unwrap();
        let mut client = render_protocol_client(&mut terminal, &mut render_state);

        terminal.vt_write(b"\x1b_Ga=d,d=I,i=41,q=2;\x1b\\");
        let frame = render_protocol_frame(&mut terminal, &mut render_state);
        let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
        let graphics = &delta["graphics"];

        assert_eq!(graphics["removed_image_ids"], json!([41]));
        assert!(graphics.get("images").is_none(), "{delta:#}");
        assert!(
            graphics["placements"]
                .as_array()
                .unwrap()
                .iter()
                .all(|placement| placement["image_id"] == 42)
        );
    }

    fn captured_writer() -> (MessageWriter, Arc<BoundedOutbound>) {
        let outbound = Arc::new(BoundedOutbound::default());
        (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
    }

    struct BlockingControlSink {
        outbound: Arc<BoundedOutbound>,
        blocked_request_id: String,
        entered: std::sync::mpsc::SyncSender<()>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }

    impl MessageSink for BlockingControlSink {
        fn send_initial(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_initial(text, stream)
        }

        fn send_stream(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_regular(text, stream)
        }

        fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
            let value: Value = serde_json::from_str(&text).map_err(json_error_to_io)?;
            if value["type"] == "response"
                && value["id"].as_str() == Some(self.blocked_request_id.as_str())
            {
                self.entered.send(()).map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "response blocker observer closed",
                    )
                })?;
                self.release.lock().unwrap().recv().map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "response blocker release closed",
                    )
                })?;
            }
            self.outbound.push_control(text)
        }

        fn send_terminal(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_terminal(text, stream)
        }

        fn send_ordered_terminal(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_ordered_terminal(text, stream)
        }

        fn is_open(&self) -> bool {
            self.outbound.is_open()
        }

        fn close(&self) {
            self.outbound.close();
        }

        fn abort(&self) {
            self.outbound.abort();
        }
    }

    fn blocking_control_writer(
        request_id: &str,
    ) -> (
        MessageWriter,
        Arc<BoundedOutbound>,
        std::sync::mpsc::Receiver<()>,
        std::sync::mpsc::SyncSender<()>,
    ) {
        let outbound = Arc::new(BoundedOutbound::default());
        let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let writer = MessageWriter::new(BlockingControlSink {
            outbound: outbound.clone(),
            blocked_request_id: request_id.to_string(),
            entered: entered_tx,
            release: Mutex::new(release_rx),
        });
        (writer, outbound, entered_rx, release_tx)
    }

    struct BlockingFlushSink {
        outbound: Arc<BoundedOutbound>,
        entered: std::sync::mpsc::SyncSender<()>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }

    impl MessageSink for BlockingFlushSink {
        fn send_initial(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_initial(text, stream)
        }

        fn send_stream(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_regular(text, stream)
        }

        fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
            self.outbound.push_control(text)
        }

        fn send_terminal(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_terminal(text, stream)
        }

        fn send_ordered_terminal(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_ordered_terminal(text, stream)
        }

        fn flush_control(&self, _timeout: Duration) -> std::io::Result<()> {
            self.entered.send(()).map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::BrokenPipe, "flush blocker observer closed")
            })?;
            self.release.lock().unwrap().recv().map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::BrokenPipe, "flush blocker release closed")
            })
        }

        fn is_open(&self) -> bool {
            self.outbound.is_open()
        }

        fn close(&self) {
            self.outbound.close();
        }

        fn abort(&self) {
            self.outbound.abort();
        }
    }

    struct TimedOutFlushSink {
        outbound: Arc<BoundedOutbound>,
    }

    impl MessageSink for TimedOutFlushSink {
        fn send_initial(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_initial(text, stream)
        }

        fn send_stream(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_regular(text, stream)
        }

        fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
            self.outbound.push_control(text)
        }

        fn send_terminal(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_terminal(text, stream)
        }

        fn send_ordered_terminal(
            &self,
            text: Arc<BudgetedText>,
            stream: &OutboundStream,
        ) -> std::io::Result<()> {
            self.outbound.push_ordered_terminal(text, stream)
        }

        fn flush_control(&self, _timeout: Duration) -> std::io::Result<()> {
            Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "timed out while flushing the shutdown response",
            ))
        }

        fn is_open(&self) -> bool {
            self.outbound.is_open()
        }

        fn close(&self) {
            self.outbound.close();
        }

        fn abort(&self) {
            self.outbound.abort();
        }
    }

    fn blocking_flush_writer() -> (
        MessageWriter,
        Arc<BoundedOutbound>,
        std::sync::mpsc::Receiver<()>,
        std::sync::mpsc::SyncSender<()>,
    ) {
        let outbound = Arc::new(BoundedOutbound::default());
        let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let writer = MessageWriter::new(BlockingFlushSink {
            outbound: outbound.clone(),
            entered: entered_tx,
            release: Mutex::new(release_rx),
        });
        (writer, outbound, entered_rx, release_tx)
    }

    fn pop_json(outbound: &BoundedOutbound) -> Value {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(message) = outbound.try_pop() {
                return serde_json::from_str(&message).expect("outbound JSON");
            }
            assert!(Instant::now() < deadline, "timed out waiting for outbound JSON");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn resource_request(
        id: &str,
        operation: &str,
        params: Value,
        idempotency_key: Option<&str>,
    ) -> String {
        let mut request = json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":id,
            "operation":operation,
            "params":params,
        });
        if let Some(idempotency_key) = idempotency_key {
            request["idempotency_key"] = json!(idempotency_key);
        }
        serde_json::to_string(&request).unwrap()
    }

    fn journal_subscription_filter(
        max_sensitivity: JournalSensitivity,
        mut filter: Value,
    ) -> Value {
        filter
            .as_object_mut()
            .expect("journal subscription filter fixture is an object")
            .insert("max_sensitivity".into(), json!(max_sensitivity));
        filter
    }

    fn test_stream_id(index: u64) -> StreamPublicId {
        StreamPublicId::parse(format!("stream_{index:032x}"))
            .expect("test stream id uses the public wire format")
    }

    #[test]
    fn resource_protocol_responses_are_identical_for_unix_and_websocket_clients() {
        let mux = test_mux();
        let request = serde_json::to_string(&json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"transport-parity",
            "operation":"session.ping",
            "params":{"machine":"current","session":"current"},
        }))
        .unwrap();
        let mut responses = Vec::new();
        for transport in [ClientTransport::Unix, ClientTransport::WebSocket] {
            let (writer, outbound) = captured_writer();
            let client = mux.control_clients.register(transport, writer.clone());
            let scheduler =
                Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
            assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
            responses.push(outbound.try_pop().expect("one resource response"));
            disconnect_client(&mux, client, false);
        }

        assert_eq!(responses[0], responses[1]);
        let response: Value = serde_json::from_str(&responses[0]).unwrap();
        assert_eq!(response["protocol"], "cmux.protocol/2");
        assert_eq!(response["type"], "response");
        assert_eq!(response["id"], "transport-parity");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["alive"], true);
        assert_eq!(response["result"]["cursor"]["revision"], "0");
        assert!(response["result"]["cursor"]["generation"].as_str().is_some());
    }

    #[test]
    fn browser_provider_is_owner_only_loopback_and_released_on_disconnect() {
        let mux = test_mux();
        let local_writer = test_writer();
        let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
        let tab_id = "tab_00000000000000000000000000000001";
        let registered = handle_command(
            &mux,
            local,
            Command::RegisterBrowserProvider {
                provider_id: "browser-process-1".into(),
                endpoint: "ws://127.0.0.1:9222/devtools/browser/one".into(),
                authentication: "bearer".into(),
                bearer_token: Some("secret-token".into()),
                targets: vec![BrowserProviderTargetRequest {
                    tab_id: tab_id.into(),
                    target_id: "target-one".into(),
                }],
            },
            &local_writer,
        )
        .unwrap();
        assert_eq!(registered["available"], true);
        assert_eq!(registered["authentication"], "bearer");
        assert_eq!(registered["targets"][0]["tab_id"], tab_id);

        let discovered =
            handle_command(&mux, local, Command::GetBrowserProvider, &local_writer).unwrap();
        assert!(
            discovered.get("bearer_token").is_none(),
            "provider discovery must not expose a registered bearer token"
        );

        let remote_writer = test_writer();
        let remote =
            mux.control_clients.register(ClientTransport::WebSocket, remote_writer.clone());
        let error = handle_command(
            &mux,
            remote,
            Command::RegisterBrowserProvider {
                provider_id: "browser-process-1".into(),
                endpoint: "ws://127.0.0.1:9222/devtools/browser/one".into(),
                authentication: "none".into(),
                bearer_token: None,
                targets: vec![],
            },
            &remote_writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains("trusted local"));
        assert!(
            handle_command(&mux, remote, Command::GetBrowserProvider, &remote_writer)
                .unwrap_err()
                .to_string()
                .contains("trusted local")
        );

        let error = browser_provider_registration(
            "browser-process-1".into(),
            "ws://192.0.2.1:9222/devtools/browser/one".into(),
            "none".into(),
            None,
            vec![],
        )
        .unwrap_err();
        assert!(error.to_string().contains("loopback"));

        assert!(disconnect_client(&mux, local, false));
        assert!(mux.browser_provider_snapshot().is_none());
    }

    #[test]
    fn browser_provider_clients_share_one_process_without_sharing_client_state() {
        let mux = test_mux();
        let first_writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let second_writer = test_writer();
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        let command = |tab_id: &str, target_id: &str| Command::RegisterBrowserProvider {
            provider_id: "browser-process-1".into(),
            endpoint: "ws://localhost:9222/devtools/browser/one".into(),
            authentication: "none".into(),
            bearer_token: None,
            targets: vec![BrowserProviderTargetRequest {
                tab_id: tab_id.into(),
                target_id: target_id.into(),
            }],
        };
        handle_command(
            &mux,
            first,
            command("tab_00000000000000000000000000000001", "target-one"),
            &first_writer,
        )
        .unwrap();
        let snapshot = handle_command(
            &mux,
            second,
            command("tab_00000000000000000000000000000002", "target-two"),
            &second_writer,
        )
        .unwrap();
        assert_eq!(snapshot["clients"], 2);
        assert_eq!(snapshot["targets"].as_array().unwrap().len(), 2);

        assert!(disconnect_client(&mux, first, false));
        let snapshot = mux.browser_provider_snapshot().unwrap();
        assert_eq!(snapshot.clients, 1);
        assert_eq!(snapshot.targets.len(), 1);
    }

    #[test]
    fn protocol_v1_is_rejected_before_returning_a_zero_view_terminal_snapshot() {
        let mux = test_mux();
        let surface = mux.new_workspace(Some("exiting".into()), None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().unwrap();
        mux.surface_exited(surface.id);

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let current_request = serde_json::to_string(&json!({
            "protocol":crate::resource::PROTOCOL,
            "type":"request",
            "id":"current-zero-view-snapshot",
            "operation":"session.snapshot",
            "params":{"machine":"current","session":"current"},
        }))
        .unwrap();

        assert!(handle_connection_message(&mux, client, &current_request, &writer, &scheduler));
        let current_response = pop_json(&outbound);
        assert_eq!(current_response["ok"], true);
        let terminal = current_response["result"]["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .expect("the actual response contains the durable exit receipt");
        assert_eq!(terminal["tab_id"], Value::Null);
        assert_eq!(terminal["tab_ids"], json!([]));

        let legacy_request = serde_json::to_string(&json!({
            "protocol":"cmux.protocol/1",
            "type":"request",
            "id":"legacy-zero-view-snapshot",
            "operation":"session.snapshot",
            "params":{"machine":"current","session":"current"},
        }))
        .unwrap();

        assert!(handle_connection_message(&mux, client, &legacy_request, &writer, &scheduler));
        let response = pop_json(&outbound);

        assert_eq!(response["protocol"], crate::resource::PROTOCOL);
        assert_eq!(response["type"], "response");
        assert_eq!(response["id"], "legacy-zero-view-snapshot");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "validation.invalid");
        assert_eq!(response["error"]["details"]["field"], "protocol");
        assert!(response.get("result").is_none());

        disconnect_client(&mux, client, false);
        mux.shutdown();
    }

    #[test]
    fn terminal_waits_do_not_block_ping_or_stream_cancel_on_the_same_connection() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-waits",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-waits"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        assert_eq!(created["ok"], true, "{created}");
        let terminal_id =
            created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");
        let stream_id = "stream_00000000000000000000000000000042";
        let open = resource_request(
            "events-open-for-wait",
            "session.events",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["id"], "events-open-for-wait");
        assert_eq!(pop_json(&outbound)["type"], "stream_item");

        for (id, operation, extra) in [
            ("screen-wait", "terminal.wait", json!({"pattern":"cmux-pattern-that-never-matches"})),
            ("process-wait", "terminal.wait_exit", json!({})),
        ] {
            let mut params = json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "timeout_ms":"250",
            });
            params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            let wait = resource_request(id, operation, params, None);
            assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        }

        let ping = resource_request(
            "ping-during-waits",
            "session.ping",
            json!({"machine":"current","session":"current"}),
            None,
        );
        assert!(handle_connection_message(&mux, client, &ping, &writer, &scheduler));
        let cancel = resource_request(
            "cancel-during-waits",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));

        let first = pop_json(&outbound);
        assert_eq!(
            first["id"], "ping-during-waits",
            "a wait completed before the same-connection ping: {first}"
        );
        let messages = (0..4).map(|_| pop_json(&outbound)).collect::<Vec<_>>();
        assert!(messages.iter().any(|message| {
            message["type"] == "stream_end" && message["stream_id"] == stream_id
        }));
        let responses =
            messages.iter().filter(|message| message["type"] == "response").collect::<Vec<_>>();
        assert!(
            responses.iter().all(|response| response["ok"] == true),
            "wait/cancel responses failed: {responses:?}"
        );
        assert!(responses.iter().any(|response| response["id"] == "cancel-during-waits"));
        let wait_ids = responses
            .iter()
            .filter_map(|response| response["id"].as_str())
            .filter(|id| *id != "cancel-during-waits")
            .map(str::to_string)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            wait_ids,
            ["process-wait".to_string(), "screen-wait".to_string()].into_iter().collect()
        );

        disconnect_client(&mux, client, false);
    }

    #[test]
    fn connection_terminal_wait_coalesces_more_than_attach_capacity() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-coalesced-wait",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-coalesced-wait"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let surface = mux
            .resource_surface_for_terminal(&terminal_id)
            .and_then(|surface| mux.surface(surface))
            .expect("created terminal surface");
        let wait = resource_request(
            "coalesced-wait",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"READY",
                "timeout_ms":"2000",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));

        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1) {
            assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
            std::thread::yield_now();
        }
        for _ in 0..300 {
            surface.apply_stream_output_for_test(b"\r").unwrap();
        }
        surface.apply_stream_output_for_test(b"READY").unwrap();

        let response = pop_json(&outbound);
        assert_eq!(response["id"], "coalesced-wait");
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["matched"], true, "{response}");
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn request_cancel_suppresses_target_response_and_reuses_request_id_and_capacity() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-request-cancel",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-request-cancel"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let surface = mux
            .resource_surface_for_terminal(&terminal_id)
            .and_then(|surface| mux.surface(surface))
            .expect("created terminal surface");

        let wait = resource_request(
            "reused-request-id",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"cmux-request-cancel-never-matches",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1) {
            assert!(Instant::now() < waiting_deadline, "terminal wait did not subscribe");
            std::thread::yield_now();
        }
        assert_eq!(mux.control_clients.resource_wait_admission.active(), 1);

        let cancel = resource_request(
            "cancel-reused-request-id",
            "request.cancel",
            json!({"request_id":"reused-request-id"}),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        let canceled = pop_json(&outbound);
        assert_eq!(canceled["id"], "cancel-reused-request-id");
        assert_eq!(canceled["ok"], true, "{canceled}");
        assert_eq!(canceled["result"], json!({"canceled":true}));
        assert_eq!(
            mux.control_clients.resource_wait_admission.active(),
            0,
            "cancel confirmation preceded worker permit release"
        );
        assert_eq!(surface.terminal_stream_waiter_count_for_test(), Some(0));
        assert!(outbound.try_pop().is_none(), "canceled target emitted a response");

        let repeated = resource_request(
            "repeat-cancel",
            "request.cancel",
            json!({"request_id":"reused-request-id"}),
            None,
        );
        assert!(handle_connection_message(&mux, client, &repeated, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["result"], json!({"canceled":false}));

        let replacement = resource_request(
            "reused-request-id",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"CMUX_REUSED_REQUEST_READY",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &replacement, &writer, &scheduler));
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1) {
            assert!(
                Instant::now() < waiting_deadline,
                "replacement terminal wait did not subscribe"
            );
            std::thread::yield_now();
        }
        surface.apply_stream_output_for_test(b"CMUX_REUSED_REQUEST_READY").unwrap();
        let replacement = pop_json(&outbound);
        assert_eq!(replacement["id"], "reused-request-id");
        assert_eq!(replacement["result"]["matched"], true, "{replacement}");

        let cleanup_deadline = Instant::now() + Duration::from_secs(1);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "completed wait retained admission");
            std::thread::yield_now();
        }
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn request_cancel_wakes_wait_exit_and_is_connection_local() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let (other_writer, other_outbound) = captured_writer();
        let other = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let other_scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-wait-exit-cancel",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-wait-exit-cancel"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let wait = resource_request(
            "connection-owned-wait-exit",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&terminal_id) != 1 {
            assert!(Instant::now() < waiting_deadline, "wait_exit did not subscribe");
            std::thread::yield_now();
        }

        let foreign_cancel = resource_request(
            "foreign-cancel",
            "request.cancel",
            json!({"request_id":"connection-owned-wait-exit"}),
            None,
        );
        assert!(handle_connection_message(
            &mux,
            other,
            &foreign_cancel,
            &other_writer,
            &other_scheduler,
        ));
        assert_eq!(pop_json(&other_outbound)["result"], json!({"canceled":false}));
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 1);

        let owner_cancel = resource_request(
            "owner-cancel",
            "request.cancel",
            json!({"request_id":"connection-owned-wait-exit"}),
            None,
        );
        assert!(handle_connection_message(&mux, client, &owner_cancel, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["result"], json!({"canceled":true}));
        assert_eq!(
            mux.control_clients.resource_wait_admission.active(),
            0,
            "wait_exit cancel confirmation preceded worker permit release"
        );
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);
        assert!(outbound.try_pop().is_none(), "canceled wait_exit emitted a response");

        assert!(disconnect_client(&mux, other, false));
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn completion_winner_queues_target_response_before_cancel_false() {
        let mux = test_mux();
        let (writer, outbound, target_send_entered, release_target_send) =
            blocking_control_writer("ordered-target");
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-cancel-order",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-cancel-order"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let surface = mux
            .resource_surface_for_terminal(&terminal_id)
            .and_then(|surface| mux.surface(surface))
            .expect("created terminal surface");
        let wait = resource_request(
            "ordered-target",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"CMUX_ORDERED_TARGET_READY",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1) {
            assert!(Instant::now() < waiting_deadline, "ordered wait did not subscribe");
            std::thread::yield_now();
        }
        surface.apply_stream_output_for_test(b"CMUX_ORDERED_TARGET_READY").unwrap();
        target_send_entered
            .recv_timeout(Duration::from_secs(1))
            .expect("wait completion did not begin its target response");

        let cancel = resource_request(
            "ordered-cancel",
            "request.cancel",
            json!({"request_id":"ordered-target"}),
            None,
        );
        std::thread::scope(|scope| {
            let cancel_mux = mux.clone();
            let cancel_writer = writer.clone();
            let cancel_scheduler = scheduler.clone();
            let cancel = scope.spawn(move || {
                handle_connection_message(
                    &cancel_mux,
                    client,
                    &cancel,
                    &cancel_writer,
                    &cancel_scheduler,
                )
            });
            std::thread::yield_now();
            assert!(
                outbound.try_pop().is_none(),
                "cancel responded before the completing target attempted its response"
            );
            release_target_send.send(()).unwrap();
            assert!(cancel.join().unwrap());
        });

        let target = pop_json(&outbound);
        let canceled = pop_json(&outbound);
        assert_eq!(target["id"], "ordered-target", "{target}");
        assert_eq!(target["result"]["matched"], true, "{target}");
        assert_eq!(canceled["id"], "ordered-cancel", "{canceled}");
        assert_eq!(canceled["result"], json!({"canceled":false}));
        let cleanup_deadline = Instant::now() + Duration::from_secs(1);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "completed wait retained admission");
            std::thread::yield_now();
        }
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn request_cancel_and_completion_have_one_atomic_winner() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer);
        for index in 0..128 {
            let request_id = ResourceRequestId::parse(format!("request-race-{index}")).unwrap();
            let (canceled, worker_permit) =
                mux.control_clients.install_resource_wait(client, &request_id).unwrap();
            let barrier = Arc::new(std::sync::Barrier::new(2));
            let completion = std::thread::scope(|scope| {
                let completion_barrier = barrier.clone();
                let completion_id = request_id.clone();
                let completion_canceled = canceled.clone();
                let completion_mux = mux.clone();
                let completion = scope.spawn(move || {
                    completion_barrier.wait();
                    let won = completion_mux.control_clients.begin_resource_wait_completion(
                        client,
                        &completion_id,
                        &completion_canceled,
                    );
                    if won {
                        completion_canceled.mark_response_attempted();
                        completion_mux.control_clients.finish_resource_wait(
                            client,
                            &completion_id,
                            &completion_canceled,
                        );
                    }
                    completion_canceled.mark_worker_finished();
                    won
                });
                barrier.wait();
                let cancellation =
                    match mux.control_clients.cancel_resource_wait(client, &request_id) {
                        ResourceWaitCancel::Missing => false,
                        ResourceWaitCancel::Canceled(lifecycle) => {
                            lifecycle.wait_for_worker_finish();
                            true
                        }
                        ResourceWaitCancel::Completing(lifecycle) => {
                            assert!(lifecycle.wait_for_response_attempt());
                            false
                        }
                    };
                (completion.join().unwrap(), cancellation)
            });
            assert_ne!(
                completion.0, completion.1,
                "completion and cancellation did not have exactly one winner"
            );
            drop(worker_permit);
        }
        assert_eq!(mux.control_clients.resource_wait_admission.active(), 0);
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn idle_terminal_wait_worker_registers_once_without_polling() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-idle-screen-wait",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-idle-screen-wait"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let surface = mux
            .resource_surface_for_terminal(&terminal_id)
            .and_then(|surface| mux.surface(surface))
            .expect("created terminal surface");
        let wait = resource_request(
            "idle-screen-wait",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"cmux-idle-pattern-that-never-matches",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while surface.terminal_stream_waiter_count_for_test() != Some(1)
            || surface.terminal_stream_subscription_count_for_test() != Some(1)
        {
            assert!(Instant::now() < waiting_deadline, "terminal wait did not become idle");
            std::thread::yield_now();
        }
        std::thread::sleep(Duration::from_millis(350));
        assert_eq!(
            surface.terminal_stream_subscription_count_for_test(),
            Some(1),
            "idle terminal.wait worker polled"
        );

        let cancel = resource_request(
            "cancel-idle-screen-wait",
            "request.cancel",
            json!({"request_id":"idle-screen-wait"}),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["result"], json!({"canceled":true}));
        let cleanup_deadline = Instant::now() + Duration::from_secs(1);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "idle wait retained admission");
            std::thread::yield_now();
        }
        assert!(disconnect_client(&mux, client, false));
    }

    #[cfg(unix)]
    #[test]
    fn connection_wait_exit_resolves_durable_detached_terminal_after_restart() {
        let root = std::env::temp_dir().join(format!(
            "cmux-connection-wait-exit-restart-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let session = "connection-wait-exit-restart";
        let first = Mux::open_persistent(session, SurfaceOptions::default(), &root).unwrap();
        let (writer, outbound) = captured_writer();
        let client = first.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(first.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-restart-exit-wait",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-restart-exit-wait"),
        );
        assert!(handle_connection_message(&first, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        assert_eq!(created["ok"], true, "{created}");
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        let exit = crate::terminal_host_protocol::TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
            exited_at_ms: 4_567_890,
        };
        assert!(first.persist_terminal_exit_for_test(&terminal_id, &exit).unwrap());
        assert_eq!(first.resource_surface_for_terminal(&terminal_id), None);
        assert!(disconnect_client(&first, client, false));
        drop(scheduler);
        drop(writer);
        first.shutdown();
        let shutdown_deadline = Instant::now() + Duration::from_secs(10);
        while Arc::strong_count(&first) > 1 && Instant::now() < shutdown_deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(Arc::strong_count(&first), 1, "terminal workers retained the first mux");
        drop(first);

        let reopened = Mux::open_persistent(session, SurfaceOptions::default(), &root).unwrap();
        let (writer, outbound) = captured_writer();
        let client = reopened.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(reopened.surface_operation_admission.clone()));
        let wait = resource_request(
            "wait-for-exit-after-restart",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "timeout_ms":"0",
            }),
            None,
        );
        assert!(handle_connection_message(&reopened, client, &wait, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["state"], "exited", "{response}");
        assert_eq!(response["result"]["terminal_id"], terminal_id.as_str(), "{response}");
        assert_eq!(response["result"]["outcome"], json!({"kind":"exit","code":0}));
        assert_eq!(response["result"]["exited_at"], "4567890");

        assert!(disconnect_client(&reopened, client, false));
        reopened.shutdown();
        drop(scheduler);
        drop(writer);
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn idle_wait_exit_workers_do_not_poll_the_terminal_registry() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-idle-exit-waits",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-idle-exit-waits"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        mux.reset_terminal_exit_state_query_count_for_test();

        for index in 0..RESOURCE_WAITS_PER_CLIENT_CAPACITY {
            let wait = resource_request(
                &format!("idle-exit-wait-{index}"),
                "terminal.wait_exit",
                json!({
                    "machine":"current",
                    "session":"current",
                    "terminal":terminal_id,
                }),
                None,
            );
            assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        }
        let admission_deadline = Instant::now() + Duration::from_secs(2);
        while mux.terminal_exit_waiter_count_for_test(&terminal_id)
            != RESOURCE_WAITS_PER_CLIENT_CAPACITY
            || mux.terminal_exit_state_query_count_for_test()
                != RESOURCE_WAITS_PER_CLIENT_CAPACITY as u64
        {
            assert!(Instant::now() < admission_deadline, "exit waits did not become idle");
            std::thread::yield_now();
        }
        std::thread::sleep(Duration::from_millis(350));
        assert_eq!(
            mux.terminal_exit_state_query_count_for_test(),
            RESOURCE_WAITS_PER_CLIENT_CAPACITY as u64,
            "idle wait_exit workers polled the registry"
        );

        assert!(disconnect_client(&mux, client, false));
        let cleanup_deadline = Instant::now() + Duration::from_secs(2);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "canceled exit waits stayed blocked");
            std::thread::yield_now();
        }
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);
        assert_eq!(
            mux.terminal_exit_state_query_count_for_test(),
            RESOURCE_WAITS_PER_CLIENT_CAPACITY as u64,
            "cancellation performed a redundant terminal query"
        );
    }

    #[test]
    fn wait_exit_deadline_performs_only_one_final_targeted_query() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-exit-deadline",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-exit-deadline"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id = created["result"]["value"]["terminal_id"].as_str().unwrap();
        mux.reset_terminal_exit_state_query_count_for_test();

        let wait = resource_request(
            "bounded-exit-wait",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "timeout_ms":"25",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["id"], "bounded-exit-wait");
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["state"], "pending", "{response}");
        assert_eq!(response["result"]["lifecycle"], "running", "{response}");
        assert_eq!(
            mux.terminal_exit_state_query_count_for_test(),
            2,
            "a deadline should perform one initial and one final query"
        );

        let cleanup_deadline = Instant::now() + Duration::from_secs(1);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "bounded exit wait retained admission");
            std::thread::yield_now();
        }
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn concurrent_terminal_close_settles_unbounded_connection_wait_exit() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-close-exit-wait",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-close-exit-wait"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            TerminalPublicId::parse(created["result"]["value"]["terminal_id"].as_str().unwrap())
                .unwrap();
        mux.reset_terminal_exit_state_query_count_for_test();

        let wait = resource_request(
            "wait-until-concurrent-close",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&terminal_id) != 1
            || mux.terminal_exit_state_query_count_for_test() != 1
        {
            assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
            std::thread::yield_now();
        }

        let close = resource_request(
            "close-terminal-during-exit-wait",
            "terminal.close",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
            }),
            Some("close-terminal-during-exit-wait"),
        );
        assert!(handle_connection_message(&mux, client, &close, &writer, &scheduler));
        let responses = [pop_json(&outbound), pop_json(&outbound)];
        let close_response =
            responses.iter().find(|response| response["id"] == "close-terminal-during-exit-wait");
        let wait_response =
            responses.iter().find(|response| response["id"] == "wait-until-concurrent-close");
        let close_response = close_response.expect("terminal close response");
        let wait_response = wait_response.expect("terminal wait_exit response");
        assert_eq!(close_response["ok"], true, "{close_response}");
        assert_eq!(wait_response["ok"], false, "{wait_response}");
        assert_eq!(wait_response["error"]["code"], "terminal.closed");
        assert_eq!(wait_response["error"]["details"]["terminal_id"], terminal_id.as_str());
        assert_eq!(mux.terminal_exit_state_query_count_for_test(), 2);
        assert_eq!(mux.terminal_exit_waiter_count_for_test(&terminal_id), 0);

        let cleanup_deadline = Instant::now() + Duration::from_secs(1);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "settled exit wait retained admission");
            std::thread::yield_now();
        }
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn disconnect_cancels_unbounded_terminal_waits_and_releases_worker_capacity() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-unbounded-waits",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-unbounded-waits"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");

        for index in 0..RESOURCE_WAITS_PER_CLIENT_CAPACITY {
            let wait = resource_request(
                &format!("unbounded-wait-{index}"),
                "terminal.wait",
                json!({
                    "machine":"current",
                    "session":"current",
                    "terminal":terminal_id,
                    "pattern":format!("cmux-pattern-that-never-matches-{index}"),
                }),
                None,
            );
            assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        }
        let admission_deadline = Instant::now() + Duration::from_secs(2);
        while mux.control_clients.resource_wait_admission.active()
            != RESOURCE_WAITS_PER_CLIENT_CAPACITY
        {
            assert!(Instant::now() < admission_deadline, "wait workers did not start");
            std::thread::sleep(Duration::from_millis(2));
        }

        let rejected = resource_request(
            "unbounded-wait-rejected",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"cmux-pattern-that-never-matches-rejected",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &rejected, &writer, &scheduler));
        let rejection = pop_json(&outbound);
        assert_eq!(rejection["id"], "unbounded-wait-rejected");
        assert_eq!(rejection["error"]["code"], "operation.failed");
        assert_eq!(rejection["error"]["details"]["extra"]["reason_code"], "terminal_wait_capacity");
        assert_eq!(rejection["error"]["details"]["extra"]["scope"], "client");

        assert!(disconnect_client(&mux, client, false));
        let cleanup_deadline = Instant::now() + Duration::from_secs(2);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(
                Instant::now() < cleanup_deadline,
                "disconnected unbounded waits retained worker capacity"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn writer_close_cancels_unbounded_wait_before_client_registry_cleanup() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-writer-close-wait",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-writer-close-wait"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");
        let wait = resource_request(
            "writer-close-wait",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        assert_eq!(mux.control_clients.resource_wait_admission.active(), 1);
        let terminal_id = TerminalPublicId::parse(terminal_id).unwrap();
        let waiting_deadline = Instant::now() + Duration::from_secs(1);
        while mux.terminal_exit_waiter_count_for_test(&terminal_id) != 1 {
            assert!(Instant::now() < waiting_deadline, "exit wait did not subscribe");
            std::thread::yield_now();
        }

        writer.close();
        assert!(
            mux.control_clients.contains(client),
            "test must isolate writer failure from registry disconnect"
        );
        let cleanup_deadline = Instant::now() + Duration::from_secs(2);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(
                Instant::now() < cleanup_deadline,
                "closed writer retained terminal wait worker capacity"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        assert!(mux.control_clients.contains(client));
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn zero_timeout_terminal_waits_complete_once_and_release_worker_capacity() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let create = resource_request(
            "create-for-zero-wait",
            "workspace.create",
            json!({
                "machine":"current",
                "session":"current",
                "initial_content":"terminal",
            }),
            Some("create-for-zero-wait"),
        );
        assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
        let created = pop_json(&outbound);
        let terminal_id =
            created["result"]["value"]["terminal_id"].as_str().expect("created terminal ID");
        let wait = resource_request(
            "zero-timeout-wait",
            "terminal.wait",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "pattern":"cmux-pattern-that-never-matches-zero-timeout",
                "timeout_ms":"0",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["id"], "zero-timeout-wait");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["matched"], false);

        let wait_exit = resource_request(
            "zero-timeout-wait-exit",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "timeout_ms":"0",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &wait_exit, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["id"], "zero-timeout-wait-exit");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["state"], "pending");

        let cleanup_deadline = Instant::now() + Duration::from_secs(2);
        while mux.control_clients.resource_wait_admission.active() != 0 {
            assert!(Instant::now() < cleanup_deadline, "zero-timeout wait retained capacity");
            std::thread::sleep(Duration::from_millis(2));
        }
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn resource_stream_capacity_is_stable_and_reused_after_worker_exit() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let mut installed = Vec::new();
        for index in 0..RESOURCE_STREAMS_PER_CLIENT_CAPACITY {
            let stream_id = test_stream_id(index as u64 + 1);
            let stream = writer.start_stream(&json!({})).unwrap();
            let (canceled, worker_permit) = mux
                .control_clients
                .install_resource_stream(client, &stream_id, stream)
                .expect("stream below the per-client capacity");
            installed.push((stream_id, canceled, worker_permit));
        }
        assert_eq!(
            mux.control_clients.resource_stream_admission.active(),
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY
        );

        let overflow_id = test_stream_id(10_000);
        let denied_outbound = writer.start_stream(&json!({})).unwrap();
        let denied = register_resource_outbound(
            &mux,
            client,
            &overflow_id,
            &denied_outbound,
            "session.events",
        );
        let Err(denied) = denied else { panic!("stream above capacity was admitted") };
        assert_eq!(denied.code, "operation.failed");
        assert!(!denied_outbound.is_open(), "denied stream retained an open outbound handle");
        assert_eq!(
            mux.control_clients.resource_stream_admission.active(),
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY,
            "denied stream consumed admission capacity"
        );
        let open_overflow = |request_id: &str| {
            resource_request(
                request_id,
                "session.events",
                json!({
                    "machine":"current",
                    "session":"current",
                    "stream_id":overflow_id,
                }),
                None,
            )
        };
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        assert!(handle_connection_message(
            &mux,
            client,
            &open_overflow("stream-overflow-first"),
            &writer,
            &scheduler,
        ));
        let first_rejection = pop_json(&outbound);
        assert_eq!(first_rejection["error"]["code"], "operation.failed");
        assert_eq!(
            first_rejection["error"]["details"]["extra"]["reason_code"],
            "resource_stream_capacity"
        );
        assert_eq!(first_rejection["error"]["details"]["extra"]["scope"], "client");
        assert_eq!(
            first_rejection["error"]["details"]["extra"]["limit"],
            RESOURCE_STREAMS_PER_CLIENT_CAPACITY
        );

        let (first_id, first_canceled, first_worker_permit) = installed.remove(0);
        drop(
            mux.control_clients
                .take_resource_stream(client, &first_id)
                .expect("installed stream remains registered"),
        );
        assert!(first_canceled.load(Ordering::Acquire));
        assert!(handle_connection_message(
            &mux,
            client,
            &open_overflow("stream-overflow-worker-still-live"),
            &writer,
            &scheduler,
        ));
        assert_eq!(pop_json(&outbound)["error"]["code"], "operation.failed");

        drop(first_worker_permit);
        assert!(handle_connection_message(
            &mux,
            client,
            &open_overflow("stream-overflow-reused"),
            &writer,
            &scheduler,
        ));
        assert_eq!(pop_json(&outbound)["id"], "stream-overflow-reused");
        assert_eq!(pop_json(&outbound)["type"], "stream_item");
        let cancel = resource_request(
            "stream-overflow-cancel",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":overflow_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["reason"], "canceled");
        assert_eq!(pop_json(&outbound)["id"], "stream-overflow-cancel");

        for (stream_id, _, worker_permit) in installed {
            drop(mux.control_clients.take_resource_stream(client, &stream_id));
            drop(worker_permit);
        }
        assert!(disconnect_client(&mux, client, false));
        assert!(
            mux.control_clients
                .resource_stream_admission
                .wait_until_idle(Instant::now() + Duration::from_secs(2)),
            "ended streams retained server worker capacity"
        );
    }

    #[test]
    fn resource_stream_server_capacity_survives_disconnect_until_workers_exit() {
        let mux = test_mux();
        let writer = test_writer();
        let mut clients = Vec::new();
        let mut worker_permits = Vec::new();
        for client_index in
            0..(RESOURCE_STREAMS_SERVER_CAPACITY / RESOURCE_STREAMS_PER_CLIENT_CAPACITY)
        {
            let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
            let mut client_permits = Vec::new();
            for stream_index in 0..RESOURCE_STREAMS_PER_CLIENT_CAPACITY {
                let id = test_stream_id(
                    (client_index * RESOURCE_STREAMS_PER_CLIENT_CAPACITY + stream_index + 1) as u64,
                );
                let stream = writer.start_stream(&json!({})).unwrap();
                let (_, permit) = mux
                    .control_clients
                    .install_resource_stream(client, &id, stream)
                    .expect("stream below the server capacity");
                client_permits.push(permit);
            }
            clients.push(client);
            worker_permits.push(client_permits);
        }
        assert_eq!(
            mux.control_clients.resource_stream_admission.active(),
            RESOURCE_STREAMS_SERVER_CAPACITY
        );

        let (extra_writer, extra_outbound) = captured_writer();
        let extra = mux.control_clients.register(ClientTransport::Unix, extra_writer.clone());
        let extra_id = test_stream_id(20_000);
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let open = resource_request(
            "server-stream-overflow",
            "session.events",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":extra_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, extra, &open, &extra_writer, &scheduler,));
        let rejection = pop_json(&extra_outbound);
        assert_eq!(rejection["error"]["code"], "operation.failed");
        assert_eq!(
            rejection["error"]["details"]["extra"]["reason_code"],
            "resource_stream_capacity"
        );
        assert_eq!(rejection["error"]["details"]["extra"]["scope"], "server");
        assert_eq!(
            rejection["error"]["details"]["extra"]["limit"],
            RESOURCE_STREAMS_SERVER_CAPACITY
        );

        assert!(disconnect_client(&mux, clients[0], false));
        let still_rejected = mux.control_clients.install_resource_stream(
            extra,
            &extra_id,
            extra_writer.start_stream(&json!({})).unwrap(),
        );
        assert!(matches!(still_rejected, Err(ResourceStreamInstallError::ServerCapacity)));
        drop(worker_permits.remove(0));
        let (_, extra_permit) = mux
            .control_clients
            .install_resource_stream(
                extra,
                &extra_id,
                extra_writer.start_stream(&json!({})).unwrap(),
            )
            .expect("disconnect cleanup is reusable after its workers exit");

        for client in clients.into_iter().skip(1) {
            assert!(disconnect_client(&mux, client, false));
        }
        drop(worker_permits);
        drop(mux.control_clients.take_resource_stream(extra, &extra_id));
        drop(extra_permit);
        assert!(disconnect_client(&mux, extra, false));
        assert_eq!(mux.control_clients.resource_stream_admission.active(), 0);
    }

    #[test]
    fn session_event_stream_acknowledges_before_snapshot_and_cancel_ends_before_response() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stream_id = "stream_00000000000000000000000000000001";
        let open = resource_request(
            "events-open",
            "session.events",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));

        let response = pop_json(&outbound);
        assert_eq!(response["type"], "response");
        assert_eq!(response["id"], "events-open");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["stream_id"], stream_id);
        let snapshot = pop_json(&outbound);
        assert_eq!(snapshot["type"], "stream_item");
        assert_eq!(snapshot["stream_id"], stream_id);
        assert_eq!(snapshot["sequence"], "0");
        assert_eq!(snapshot["item"]["kind"], "snapshot");
        assert_eq!(snapshot["item"]["reset_reason"], "initial");
        let clients = snapshot["item"]["snapshot"]["clients"].as_array().unwrap();
        assert_eq!(clients.len(), 1);
        assert_eq!(clients[0]["self"], true);
        assert_eq!(clients[0]["transport"], "unix");

        let cancel = resource_request(
            "events-cancel",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        let end = pop_json(&outbound);
        assert_eq!(end["type"], "stream_end");
        assert_eq!(end["stream_id"], stream_id);
        assert_eq!(end["reason"], "canceled");
        let response = pop_json(&outbound);
        assert_eq!(response["type"], "response");
        assert_eq!(response["id"], "events-cancel");
        assert_eq!(response["ok"], true);
        assert!(
            mux.control_clients
                .resource_stream_admission
                .wait_until_idle(Instant::now() + Duration::from_secs(2)),
            "canceled event stream retained server worker capacity"
        );
        assert!(outbound.try_pop().is_none(), "an item followed stream_end");
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn session_journal_stream_replays_filters_and_resumes_from_its_cursor() {
        let mux = test_mux();
        let created = crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "journal-create",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"journal",
                    "initial_content":"empty",
                }),
                Some("journal-create"),
            ),
        )
        .unwrap();
        let workspace_id = created["result"]["value"]["workspace_id"].as_str().unwrap().to_string();
        let session_id =
            crate::resource_api::public_session_snapshot(&mux).unwrap()["session"]["id"]
                .as_str()
                .unwrap()
                .to_string();

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let first_stream = "stream_00000000000000000000000000000031";
        let open = resource_request(
            "journal-open",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":first_stream,
                "start":"beginning",
                "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                    "kinds":["workspace.*"],
                    "classes":["state"],
                    "subjects":[{"kind":"workspace","id":workspace_id}],
                    "regex":{
                        "pattern":"JOURNAL|missing",
                        "field":"payload",
                        "case_sensitive":false,
                    },
                })),
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["id"], "journal-open");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["cursor"]["generation"], session_id);
        assert_eq!(response["result"]["cursor"]["revision"], "0");
        let item = pop_json(&outbound);
        assert_eq!(item["type"], "stream_item");
        assert_eq!(item["stream_id"], first_stream);
        assert_eq!(item["cursor"]["generation"], session_id);
        assert_eq!(item["cursor"]["revision"], item["item"]["sequence"]);
        assert_eq!(item["item"]["kind"], "workspace.create");
        assert_eq!(item["item"]["class"], "state");
        assert_eq!(item["item"]["sensitivity"], "sensitive");
        assert!(item["item"]["payload"]["changes"].is_array());
        let cursor = item["cursor"].clone();

        let cancel = resource_request(
            "journal-cancel",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":first_stream,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["reason"], "canceled");
        assert_eq!(pop_json(&outbound)["id"], "journal-cancel");

        crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "journal-rename",
                "workspace.rename",
                json!({
                    "machine":"current",
                    "session":"current",
                    "workspace":workspace_id,
                    "name":"resumed",
                }),
                Some("journal-rename"),
            ),
        )
        .unwrap();
        let second_stream = "stream_00000000000000000000000000000032";
        let resume = resource_request(
            "journal-resume",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":second_stream,
                "cursor":cursor,
                "filter":journal_subscription_filter(
                    JournalSensitivity::Sensitive,
                    json!({"kinds":["workspace.rename"]}),
                ),
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &resume, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["id"], "journal-resume");
        let resumed = pop_json(&outbound);
        assert_eq!(resumed["item"]["kind"], "workspace.rename");
        assert!(resumed["item"]["payload"]["changes"].as_array().unwrap().iter().any(|change| {
            change["resource"] == "workspace" && change["value"]["name"] == "resumed"
        }));

        let invalid_stream = "stream_00000000000000000000000000000035";
        let invalid = resource_request(
            "journal-invalid-regex",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":invalid_stream,
                "filter":{
                    "regex":{
                        "pattern":"(",
                        "field":"record",
                        "case_sensitive":true,
                    },
                },
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &invalid, &writer, &scheduler));
        let rejected = pop_json(&outbound);
        assert_eq!(rejected["id"], "journal-invalid-regex");
        assert_eq!(rejected["error"]["code"], "validation.invalid");
        assert_eq!(rejected["error"]["details"]["field"], "filter.regex.pattern");
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn bounded_journal_read_includes_the_durable_exact_subject_head() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-subject-head-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("journal-subject-head", SurfaceOptions::default(), &root).unwrap();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

        for index in 0..32_u128 {
            let marker = format!("subject-head-child-{index}");
            let ingress = crate::agent_hook_journal_ingress(
                "codex",
                "SubagentStop",
                None,
                json!({
                    "session_id":"subject-head-root",
                    "root_session_id":"subject-head-root",
                    "parent_session_id":"subject-head-root",
                    "child_agent_id":marker.clone(),
                    "message":"complete",
                }),
            )
            .unwrap();
            let subject = ingress
                .subjects
                .iter()
                .find(|subject| subject.kind == "agent_tree")
                .cloned()
                .unwrap();
            let commit = mux
                .append_journal_ingress(
                    &ingress,
                    "client_subject_head",
                    &format!("subject_head_{index}"),
                )
                .unwrap();
            let filter_value = journal_subscription_filter(
                JournalSensitivity::Sensitive,
                json!({
                    "kinds":["agent.child.completed"],
                    "subjects":[subject.clone()],
                    "regex":{
                        "pattern":marker,
                        "field":"payload",
                        "case_sensitive":true,
                    },
                }),
            );
            let direct = mux
                .session_journal_reader()
                .unwrap()
                .unwrap()
                .after_subjects(
                    commit.sequence.saturating_sub(1),
                    1,
                    std::slice::from_ref(&subject),
                )
                .unwrap();
            let document = JournalDocument::new(direct.records.into_iter().next().unwrap());
            assert!(JournalStreamFilter::parse(Some(&filter_value)).unwrap().matches(&document));
            let stream_id = format!("stream_{:032x}", 0x5000_u128 + index);
            let open = resource_request(
                &format!("subject-head-open-{index}"),
                "session.journal.subscribe",
                json!({
                    "machine":"current",
                    "session":"current",
                    "stream_id":stream_id,
                    "start":"beginning",
                    "follow":false,
                    "filter":filter_value,
                }),
                None,
            );
            assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
            assert_eq!(pop_json(&outbound)["ok"], true);
            let item = pop_json(&outbound);
            assert_eq!(item["type"], "stream_item", "missing durable subject head {index}");
            assert_eq!(item["item"]["sequence"], commit.sequence.to_string());
            assert_eq!(pop_json(&outbound)["reason"], "completed");
        }

        assert!(disconnect_client(&mux, client, false));
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_session_journal_replay_completes_at_its_open_head() {
        let mux = test_mux();
        crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "journal-bounded-create",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"bounded",
                    "initial_content":"empty",
                }),
                Some("journal-bounded-create"),
            ),
        )
        .unwrap();

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stream_id = "stream_00000000000000000000000000000039";
        let open = resource_request(
            "journal-bounded-open",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
                "start":"beginning",
                "follow":false,
                "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                    "kinds":["workspace.*"],
                })),
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["ok"], true);
        assert_eq!(pop_json(&outbound)["item"]["kind"], "workspace.create");
        let end = pop_json(&outbound);
        assert_eq!(end["type"], "stream_end");
        assert_eq!(end["reason"], "completed");
        assert_eq!(end["stream_id"], stream_id);
        assert!(end["cursor"]["revision"].as_str().is_some());

        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn bounded_filtered_replay_advances_to_head_without_matching_items() {
        let mux = test_mux();
        crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "journal-bounded-filter-create",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"bounded-filter",
                    "initial_content":"empty",
                }),
                Some("journal-bounded-filter-create"),
            ),
        )
        .unwrap();

        let head = mux.session_journal_after(0, 1).unwrap().head_sequence;
        assert!(head > 0);
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stream_id = "stream_0000000000000000000000000000003a";
        let open = resource_request(
            "journal-bounded-filter-open",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
                "start":"beginning",
                "follow":false,
                "filter":{"kinds":["agent.*"]},
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["ok"], true);
        let end = pop_json(&outbound);
        assert_eq!(end["type"], "stream_end");
        assert_eq!(end["reason"], "completed");
        assert_eq!(end["cursor"]["revision"], head.to_string());

        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn session_journal_stream_regex_matches_exact_terminal_output_bytes() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-terminal-regex-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent("terminal-regex", SurfaceOptions::default(), &root).unwrap();
        let terminal_id = TerminalPublicId::parse("term_00000000000000000000000000000041").unwrap();
        let output = b"ready\xff\x00fatal: SIMD needle\r\n".to_vec();
        mux.journal_terminal_output(
            Arc::new(terminal_id),
            Arc::from("terminal-regex-generation"),
            output.clone(),
        );
        mux.flush_terminal_journal().unwrap();

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stream_id = "stream_00000000000000000000000000000041";
        let open = resource_request(
            "journal-terminal-regex-open",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
                "start":"beginning",
                "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                    "kinds":["terminal.output"],
                    "regex":{
                        "pattern":"fatal: SIMD [a-z]+",
                        "field":"terminal_output",
                        "case_sensitive":true
                    }
                }))
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["ok"], true);
        let item = pop_json(&outbound);
        assert_eq!(item["item"]["kind"], "terminal.output");
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(item["item"]["payload"]["data"].as_str().unwrap())
                .unwrap(),
            output
        );
        assert!(disconnect_client(&mux, client, false));
        drop(scheduler);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn journal_restore_preview_satisfies_the_public_result_contract() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-restore-contract-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("restore-contract", SurfaceOptions::default(), &root).unwrap();
        mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let request = resource_request(
            "journal-restore-preview",
            "session.journal.restore.preview",
            json!({
                "machine":"current",
                "session":"current",
                "checkpoint":"latest",
            }),
            None,
        );

        assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["result"]["unsupported_required_record_count"], "0");
        assert_eq!(response["result"]["unsupported_required_records_truncated"], false);

        assert!(disconnect_client(&mux, client, false));
        drop(scheduler);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn journal_hook_list_omits_absent_optional_filters() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-hook-list-contract-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("hook-list-contract", SurfaceOptions::default(), &root).unwrap();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let put = resource_request(
            "journal-hook-put",
            "session.journal.hook.put",
            json!({
                "machine":"current",
                "session":"current",
                "manifest":{
                    "hook_id":"contract_hook",
                    "manifest_version":1,
                    "filter":{"kinds":["plugin.contract.*"]},
                    "exec":{"argv":["/usr/bin/true"],"timeout_ms":1000,"max_parallel":1},
                    "delivery":{"start":"tail","retry":{"max_attempts":1,"backoff_ms":0}},
                    "permissions":["journal.read"],
                },
            }),
            Some("journal-hook-put-1"),
        );
        assert!(handle_connection_message(&mux, client, &put, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["ok"], true);

        let list = resource_request(
            "journal-hook-list",
            "session.journal.hook.list",
            json!({"machine":"current","session":"current"}),
            None,
        );
        assert!(handle_connection_message(&mux, client, &list, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], true, "{response}");
        let filter = &response["result"]["hooks"][0]["manifest"]["filter"];
        assert_eq!(filter["kinds"], json!(["plugin.contract.*"]));
        assert!(filter.get("classes").is_none());
        assert!(filter.get("subject_kinds").is_none());

        assert!(disconnect_client(&mux, client, false));
        drop(scheduler);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_journal_manifests_do_not_echo_private_field_names() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

        for (request_id, operation, expected_field) in [
            (
                "private-producer-manifest",
                "session.journal.producer.put",
                "session.journal.producer.put.manifest",
            ),
            (
                "private-hook-manifest",
                "session.journal.hook.put",
                "session.journal.hook.put.manifest",
            ),
        ] {
            let request = resource_request(
                request_id,
                operation,
                json!({
                    "machine":"current",
                    "session":"current",
                    "manifest":{"private-provider-token-name":true},
                }),
                Some(request_id),
            );
            assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
            let response = pop_json(&outbound);
            assert_eq!(response["ok"], false);
            assert_eq!(response["error"]["code"], "validation.invalid");
            assert_eq!(response["error"]["details"]["field"], expected_field);
            assert!(!response.to_string().contains("private-provider-token-name"));
        }

        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    #[ignore = "manual throughput probe"]
    fn journal_compiled_regex_throughput_probe() {
        let document = JournalDocument::new(SessionJournalRecord {
            sequence: 1,
            event_id: "event_benchmark".into(),
            schema_version: 1,
            kind: "plugin.benchmark.observation".into(),
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            occurred_at_ms: 1,
            committed_at_ms: 1,
            producer: JournalProducer { kind: "benchmark".into(), id: "benchmark".into() },
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: vec![JournalSubject { kind: "workspace".into(), id: "ws_benchmark".into() }],
            sensitivity: JournalSensitivity::Metadata,
            payload: json!({"message":"approval-42 is ready"}),
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: None,
        });
        let filter = JournalStreamFilter::parse(Some(&json!({
            "kinds":["plugin.benchmark.*"],
            "classes":["observation"],
            "max_sensitivity":"metadata",
            "regex":{
                "pattern":"approval-[0-9]+",
                "field":"payload",
                "case_sensitive":true
            }
        })))
        .unwrap();
        let iterations = 1_000_000_u64;
        let started = Instant::now();
        let mut matched = 0_u64;
        for _ in 0..iterations {
            if std::hint::black_box(&filter).matches(std::hint::black_box(&document)) {
                matched += 1;
            }
        }
        let elapsed = started.elapsed();
        let per_second = iterations as f64 / elapsed.as_secs_f64();
        eprintln!(
            "journal compiled-regex filter: {iterations} records in {elapsed:?}, {per_second:.0} records/s"
        );
        assert_eq!(matched, iterations);

        let mut output = vec![b'x'; 256 * 1024];
        let needle = b"fatal: SIMD needle";
        let needle_start = output.len() - needle.len();
        output[needle_start..].copy_from_slice(needle);
        let output_bytes = output.len();
        let terminal_document = JournalDocument::new(SessionJournalRecord {
            sequence: 2,
            event_id: "event_terminal_benchmark".into(),
            schema_version: 1,
            kind: "terminal.output".into(),
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms: 2,
            committed_at_ms: 2,
            producer: JournalProducer { kind: "terminal_runtime".into(), id: "benchmark".into() },
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: vec![JournalSubject { kind: "terminal".into(), id: "benchmark".into() }],
            sensitivity: JournalSensitivity::Sensitive,
            payload: json!({"format":"cmux.terminal-output.v1"}),
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: Some(Arc::from(output)),
        });
        let terminal_filter = JournalStreamFilter::parse(Some(&json!({
            "max_sensitivity":"sensitive",
            "regex":{
                "pattern":"fatal: SIMD needle",
                "field":"terminal_output",
                "case_sensitive":true
            }
        })))
        .unwrap();
        let terminal_iterations = 8_192_u64;
        let started = Instant::now();
        let mut terminal_matches = 0_u64;
        for _ in 0..terminal_iterations {
            if std::hint::black_box(&terminal_filter)
                .matches(std::hint::black_box(&terminal_document))
            {
                terminal_matches += 1;
            }
        }
        let elapsed = started.elapsed();
        let gibibytes_per_second = output_bytes as f64 * terminal_iterations as f64
            / (1024.0 * 1024.0 * 1024.0)
            / elapsed.as_secs_f64();
        eprintln!(
            "journal terminal-output regex: {} MiB in {elapsed:?}, {gibibytes_per_second:.1} GiB/s",
            output_bytes * usize::try_from(terminal_iterations).unwrap() / (1024 * 1024)
        );
        assert_eq!(terminal_matches, terminal_iterations);
        assert!(
            gibibytes_per_second >= 1.0,
            "terminal-output regex regressed: {gibibytes_per_second:.1} GiB/s"
        );
    }

    #[test]
    fn persistent_journal_tail_subscribers_share_one_decoded_database_reader() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-shared-reader-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent("shared-journal", SurfaceOptions::default(), &root).unwrap();
        assert_eq!(mux.journal_database_reader_count_for_test(), 1);

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        for (request_id, stream_id) in [
            ("journal-shared-open-a", "stream_00000000000000000000000000000036"),
            ("journal-shared-open-b", "stream_00000000000000000000000000000037"),
        ] {
            let open = resource_request(
                request_id,
                "session.journal.subscribe",
                json!({
                    "machine":"current",
                    "session":"current",
                    "stream_id":stream_id,
                    "filter":journal_subscription_filter(
                        JournalSensitivity::Sensitive,
                        json!({}),
                    ),
                }),
                None,
            );
            assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
            assert_eq!(pop_json(&outbound)["id"], request_id);
        }

        crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "journal-shared-create",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"shared",
                    "initial_content":"empty",
                }),
                Some("journal-shared-create"),
            ),
        )
        .unwrap();

        let first = pop_json(&outbound);
        let second = pop_json(&outbound);
        assert_eq!(first["type"], "stream_item");
        assert_eq!(second["type"], "stream_item");
        assert_ne!(first["stream_id"], second["stream_id"]);
        assert_eq!(first["item"]["event_id"], second["item"]["event_id"]);
        assert_eq!(first["item"]["kind"], "workspace.create");
        assert_eq!(mux.journal_database_reader_count_for_test(), 1);

        assert!(disconnect_client(&mux, client, false));
        drop(scheduler);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn journal_producer_ingress_is_namespaced_schema_validated_and_idempotent() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let manifest = json!({
            "producer_id":"demo",
            "namespace":"plugin.demo",
            "manifest_version":1,
            "max_sensitivity":"sensitive",
            "permissions":["journal.append.plugin.demo"],
            "events":[{
                "kind":"plugin.demo.agent.question",
                "schema_version":1,
                "class":"observation",
                "replay":"advisory",
                "sensitivity":"metadata",
                "payload_schema":{
                    "type":"object",
                    "properties":{"question":{"type":"string"}},
                    "required":["question"],
                    "additionalProperties":false
                }
            }]
        });
        let put = resource_request(
            "journal-producer-put",
            "session.journal.producer.put",
            json!({"machine":"current","session":"current","manifest":manifest}),
            Some("producer-put-1"),
        );
        assert!(handle_connection_message(&mux, client, &put, &writer, &scheduler));
        let installed = pop_json(&outbound);
        assert_eq!(installed["ok"], true);
        assert_eq!(installed["result"]["value"]["producer_id"], "demo");
        assert_eq!(installed["result"]["replayed"], false);

        let event = json!({
            "producer_id":"demo",
            "manifest_version":1,
            "kind":"plugin.demo.agent.question",
            "schema_version":1,
            "subjects":[{"kind":"pane","id":"pane_00000000000000000000000000000001"}],
            "payload":{"question":"Continue?"}
        });
        let append = resource_request(
            "journal-ingress-append",
            "session.journal.append",
            json!({"machine":"current","session":"current","event":event}),
            Some("append-question-1"),
        );
        assert!(handle_connection_message(&mux, client, &append, &writer, &scheduler));
        let appended = pop_json(&outbound);
        assert_eq!(appended["ok"], true);
        assert_eq!(appended["result"]["replayed"], false);
        let event_id = appended["result"]["value"]["event_id"].clone();

        assert!(handle_connection_message(&mux, client, &append, &writer, &scheduler));
        let replayed = pop_json(&outbound);
        assert_eq!(replayed["result"]["replayed"], true);
        assert_eq!(replayed["result"]["value"]["event_id"], event_id);

        let (retry_writer, retry_outbound) = captured_writer();
        let retry_client =
            mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
        assert!(handle_connection_message(&mux, retry_client, &append, &retry_writer, &scheduler,));
        let reconnected_replay = pop_json(&retry_outbound);
        assert_eq!(reconnected_replay["result"]["replayed"], true);
        assert_eq!(reconnected_replay["result"]["value"]["event_id"], event_id);

        let invalid = resource_request(
            "journal-ingress-invalid",
            "session.journal.append",
            json!({
                "machine":"current",
                "session":"current",
                "event":{
                    "producer_id":"demo",
                    "manifest_version":1,
                    "kind":"plugin.demo.agent.question",
                    "schema_version":1,
                    "payload":{"wrong":true}
                }
            }),
            Some("append-question-invalid"),
        );
        assert!(handle_connection_message(&mux, client, &invalid, &writer, &scheduler));
        let rejected = pop_json(&outbound);
        assert_eq!(rejected["error"]["code"], "validation.invalid");
        assert_eq!(rejected["error"]["message"], "journal request is invalid");
        assert_eq!(rejected["error"]["details"], json!({"reason":"journal request is invalid"}));

        let subscribe = resource_request(
            "journal-plugin-subscribe",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":"stream_00000000000000000000000000000038",
                "start":"beginning",
                "filter":journal_subscription_filter(
                    JournalSensitivity::Metadata,
                    json!({"kinds":["plugin.demo.*"]}),
                )
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &subscribe, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["ok"], true);
        let item = pop_json(&outbound);
        assert_eq!(item["item"]["event_id"], event_id);
        assert_eq!(item["item"]["producer"]["id"], "demo");
        assert_eq!(item["item"]["payload"]["question"], "Continue?");
        assert!(disconnect_client(&mux, retry_client, false));
        assert!(disconnect_client(&mux, client, false));
    }

    #[test]
    fn session_journal_stream_redacts_remote_clients_and_rejects_foreign_cursors() {
        let mux = test_mux();
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

        let (remote_writer, remote_outbound) = captured_writer();
        let remote =
            mux.control_clients.register(ClientTransport::WebSocket, remote_writer.clone());
        let remote_open = resource_request(
            "journal-remote",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":"stream_00000000000000000000000000000033",
                "filter":{"max_sensitivity":"metadata","kinds":["plugin.remote_test.*"]},
            }),
            None,
        );
        assert!(handle_connection_message(&mux, remote, &remote_open, &remote_writer, &scheduler,));
        let accepted = pop_json(&remote_outbound);
        assert_eq!(accepted["ok"], true);

        let producer: crate::JournalProducerManifest = serde_json::from_value(json!({
            "producer_id":"remote_test",
            "namespace":"plugin.remote_test",
            "manifest_version":1,
            "max_sensitivity":"metadata",
            "permissions":["journal.append.plugin.remote_test"],
            "events":[{
                "kind":"plugin.remote_test.changed",
                "schema_version":1,
                "class":"observation",
                "replay":"advisory",
                "sensitivity":"metadata",
                "payload_schema":{"type":"object"}
            }]
        }))
        .unwrap();
        mux.put_journal_producer(&producer, "client_test", "remote_producer_1").unwrap();
        let ingress: crate::JournalIngress = serde_json::from_value(json!({
            "producer_id":"remote_test",
            "manifest_version":1,
            "kind":"plugin.remote_test.changed",
            "schema_version":1,
            "payload":{"visible":"metadata"},
            "correlation_id":"local_correlation_secret"
        }))
        .unwrap();
        mux.append_journal_ingress(&ingress, "client_private", "remote_event_1").unwrap();
        let item = pop_json(&remote_outbound);
        assert_eq!(item["item"]["kind"], "plugin.remote_test.changed");
        assert_eq!(item["item"]["payload"]["visible"], "metadata");
        assert_eq!(item["item"]["authority"], Value::Null);
        assert_eq!(item["item"]["causation_id"], Value::Null);
        assert_eq!(item["item"]["correlation_id"], Value::Null);

        let sensitive = resource_request(
            "journal-remote-sensitive",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":"stream_00000000000000000000000000000039",
                "filter":{"max_sensitivity":"sensitive"},
            }),
            None,
        );
        assert!(handle_connection_message(&mux, remote, &sensitive, &remote_writer, &scheduler,));
        let rejected = pop_json(&remote_outbound);
        assert_eq!(rejected["error"]["code"], "operation.failed");
        assert!(rejected["error"]["message"].as_str().unwrap().contains("metadata"));

        let payload_regex = resource_request(
            "journal-remote-payload-regex",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":"stream_00000000000000000000000000000040",
                "filter":{"regex":{"pattern":"secret","field":"payload"}},
            }),
            None,
        );
        assert!(handle_connection_message(
            &mux,
            remote,
            &payload_regex,
            &remote_writer,
            &scheduler,
        ));
        let rejected = pop_json(&remote_outbound);
        assert_eq!(rejected["error"]["code"], "operation.failed");
        assert!(rejected["error"]["message"].as_str().unwrap().contains("kind or subjects"));
        assert!(disconnect_client(&mux, remote, false));

        let (local_writer, local_outbound) = captured_writer();
        let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
        let foreign = resource_request(
            "journal-foreign",
            "session.journal.subscribe",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":"stream_00000000000000000000000000000034",
                "cursor":{
                    "generation":"session_ffffffffffffffffffffffffffffffff",
                    "revision":"0",
                },
            }),
            None,
        );
        assert!(handle_connection_message(&mux, local, &foreign, &local_writer, &scheduler,));
        let rejected = pop_json(&local_outbound);
        assert_eq!(rejected["error"]["code"], "cursor.invalid");
        assert_eq!(rejected["error"]["details"]["reason"], "cursor belongs to a different session");
        assert!(disconnect_client(&mux, local, false));
    }

    #[test]
    fn resource_shutdown_requires_local_authority_and_force_for_a_live_browser_owner() {
        let mux = test_mux();
        mux.mark_server_lifecycle_ready();
        let owner_writer = test_writer();
        let owner = mux.control_clients.register(ClientTransport::Unix, owner_writer.clone());
        handle_command(
            &mux,
            owner,
            Command::SetClientInfo {
                name: Some("browser owner".to_string()),
                kind: Some("native-browser".to_string()),
                capabilities: None,
            },
            &owner_writer,
        )
        .unwrap();
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

        let (websocket_writer, websocket_outbound) = captured_writer();
        let websocket =
            mux.control_clients.register(ClientTransport::WebSocket, websocket_writer.clone());
        let websocket_request = resource_request(
            "websocket-shutdown",
            "session.shutdown",
            json!({"machine":"current","session":"current","force":true}),
            Some("websocket-shutdown"),
        );
        assert!(handle_connection_message(
            &mux,
            websocket,
            &websocket_request,
            &websocket_writer,
            &scheduler,
        ));
        let rejected = pop_json(&websocket_outbound);
        assert_eq!(rejected["ok"], false);
        assert!(rejected["error"]["message"].as_str().unwrap().contains("trusted local"));
        assert!(!mux.daemon_shutdown_requested());
        assert!(!mux.control_clients.daemon_handoff_pending());

        let (local_writer, local_outbound) = captured_writer();
        let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
        let ordinary_request = resource_request(
            "ordinary-shutdown",
            "session.shutdown",
            json!({"machine":"current","session":"current","force":false}),
            Some("ordinary-shutdown"),
        );
        assert!(handle_connection_message(
            &mux,
            local,
            &ordinary_request,
            &local_writer,
            &scheduler,
        ));
        let rejected = pop_json(&local_outbound);
        assert_eq!(rejected["ok"], false);
        assert!(rejected["error"]["message"].as_str().unwrap().contains("still owns"));
        assert!(!mux.daemon_shutdown_requested());
        assert!(!mux.control_clients.daemon_handoff_pending());

        let forced_request = resource_request(
            "forced-shutdown",
            "session.shutdown",
            json!({"machine":"current","session":"current","force":true}),
            Some("forced-shutdown"),
        );
        assert!(
            handle_connection_message(&mux, local, &forced_request, &local_writer, &scheduler,)
        );
        // Observing shutdown means the durable result was returned and queued
        // before the owning loop was asked to exit.
        assert!(mux.daemon_shutdown_requested());
        assert!(mux.control_clients.daemon_handoff_pending());
        assert!(mux.control_clients.contains(local));
        let accepted = pop_json(&local_outbound);
        assert_eq!(accepted["ok"], true);
        assert_eq!(accepted["result"]["value"]["accepted"], true);
        assert_eq!(accepted["result"]["replayed"], false);
    }

    #[test]
    fn paused_server_rejects_resource_shutdown_until_lifecycle_readiness() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let request = resource_request(
            "paused-resource-shutdown",
            "session.shutdown",
            json!({"machine":"current","session":"current","force":true}),
            Some("paused-resource-shutdown"),
        );

        assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], false);
        assert!(response["error"]["message"].as_str().unwrap().contains("not ready"));
        assert_eq!(response["error"]["details"]["reason"], "lifecycle_not_ready");
        assert!(!mux.daemon_shutdown_requested());
        assert!(!mux.control_clients.daemon_handoff_pending());
    }

    #[test]
    fn paused_server_rejects_resource_reload_until_lifecycle_readiness() {
        let mux = test_mux();
        let events = mux.subscribe_config_reload();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let request = resource_request(
            "paused-resource-reload",
            "session.reload_config",
            json!({"machine":"current","session":"current"}),
            Some("paused-resource-reload"),
        );

        assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], false);
        assert!(response["error"]["message"].as_str().unwrap().contains("not ready"));
        assert_eq!(response["error"]["details"]["reason"], "lifecycle_not_ready");
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn resource_shutdown_replay_reserves_handoff_and_retries_the_post_ack_exit() {
        let root = std::env::temp_dir().join(format!(
            "cmux-resource-shutdown-replay-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let request = resource_request(
            "shutdown-replay",
            "session.shutdown",
            json!({"machine":"current","session":"current","force":false}),
            Some("shutdown-replay"),
        );

        let first =
            Mux::open_persistent("shutdown-replay", SurfaceOptions::default(), &root).unwrap();
        first.mark_server_lifecycle_ready();
        let (closed_writer, _) = captured_writer();
        let client = first.control_clients.register(ClientTransport::Unix, closed_writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(first.surface_operation_admission.clone()));
        closed_writer.close();
        assert!(!handle_connection_message(&first, client, &request, &closed_writer, &scheduler,));
        assert!(!first.daemon_shutdown_requested());
        assert!(!first.control_clients.daemon_handoff_pending());
        drop(scheduler);
        drop(first);

        let reopened =
            Mux::open_persistent("shutdown-replay", SurfaceOptions::default(), &root).unwrap();
        reopened.mark_server_lifecycle_ready();
        let (writer, outbound) = captured_writer();
        let client = reopened.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(reopened.surface_operation_admission.clone()));
        assert!(handle_connection_message(&reopened, client, &request, &writer, &scheduler,));
        assert!(reopened.daemon_shutdown_requested());
        assert!(reopened.control_clients.daemon_handoff_pending());
        assert!(reopened.control_clients.contains(client));
        let replay = pop_json(&outbound);
        assert_eq!(replay["ok"], true);
        assert_eq!(replay["result"]["value"]["accepted"], true);
        assert_eq!(replay["result"]["replayed"], true);
        drop(scheduler);
        drop(reopened);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pairing_request_resources_require_a_trusted_local_connection() {
        let mux = test_mux();
        let (challenge, decision) = mux.begin_pairing("127.0.0.1".parse().unwrap()).unwrap();
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let (websocket_writer, websocket_outbound) = captured_writer();
        // Registered WebSocket clients are already authenticated or paired;
        // pairing never upgrades their transport to trusted local authority.
        let websocket =
            mux.control_clients.register(ClientTransport::WebSocket, websocket_writer.clone());

        let list = resource_request(
            "pairing-list-websocket",
            "pairing_request.list",
            json!({"machine":"current","session":"current"}),
            None,
        );
        assert!(handle_connection_message(&mux, websocket, &list, &websocket_writer, &scheduler,));
        let rejected = pop_json(&websocket_outbound);
        assert_eq!(rejected["ok"], false);
        assert!(rejected["error"]["message"].as_str().unwrap().contains("trusted local"));

        let resolve = resource_request(
            "pairing-resolve-websocket",
            "pairing_request.resolve",
            json!({
                "machine":"current",
                "session":"current",
                "pairing_request":format!("pairing_{:032x}", challenge.id),
                "decision":"accept",
            }),
            Some("pairing-resolve-websocket"),
        );
        assert!(handle_connection_message(
            &mux,
            websocket,
            &resolve,
            &websocket_writer,
            &scheduler,
        ));
        let rejected = pop_json(&websocket_outbound);
        assert_eq!(rejected["ok"], false);
        assert!(rejected["error"]["message"].as_str().unwrap().contains("trusted local"));
        assert_eq!(mux.pending_pairings().len(), 1);
        assert!(matches!(decision.try_recv(), Err(TryRecvError::Empty)));

        let (local_writer, local_outbound) = captured_writer();
        let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
        assert!(handle_connection_message(&mux, local, &list, &local_writer, &scheduler,));
        let listed = pop_json(&local_outbound);
        assert_eq!(listed["ok"], true);
        assert_eq!(listed["result"].as_array().unwrap().len(), 1);
        assert_eq!(listed["result"][0]["code"], challenge.code);
    }

    #[test]
    fn resource_clients_use_opaque_ids_and_preserve_exact_nullable_metadata() {
        let mux = test_mux();
        let (first_writer, first_outbound) = captured_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let (second_writer, second_outbound) = captured_writer();
        let second =
            mux.control_clients.register(ClientTransport::WebSocket, second_writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

        let update = resource_request(
            "client-metadata",
            "client.metadata.update",
            json!({
                "machine":"current",
                "session":"current",
                "client":"current",
                "name":"  α  ",
                "kind":null,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, first, &update, &first_writer, &scheduler));
        let updated = pop_json(&first_outbound);
        assert_eq!(updated["ok"], true);
        assert_eq!(updated["result"]["name"], "  α  ");
        assert_eq!(updated["result"]["client_kind"], Value::Null);
        assert_eq!(updated["result"]["transport"], "unix");
        let first_id = updated["result"]["id"].as_str().unwrap().to_string();
        assert!(first_id.starts_with("client_"));
        assert!(!first_id.ends_with(&format!("{first:032x}")));

        let list = resource_request(
            "client-list",
            "client.list",
            json!({"machine":"current","session":"current"}),
            None,
        );
        assert!(handle_connection_message(&mux, first, &list, &first_writer, &scheduler));
        let listed = pop_json(&first_outbound);
        assert_eq!(listed["result"].as_array().unwrap().len(), 2);
        assert!(listed["result"].as_array().unwrap().iter().any(|client| {
            client["id"] == first_id && client["self"] == true && client["transport"] == "unix"
        }));
        assert!(
            listed["result"]
                .as_array()
                .unwrap()
                .iter()
                .any(|client| { client["self"] == false && client["transport"] == "websocket" })
        );

        let snapshot = resource_request(
            "session-snapshot-with-clients",
            "session.snapshot",
            json!({"machine":"current","session":"current"}),
            None,
        );
        assert!(handle_connection_message(&mux, first, &snapshot, &first_writer, &scheduler));
        let snapshot = pop_json(&first_outbound);
        let clients = snapshot["result"]["clients"].as_array().unwrap();
        assert_eq!(clients.len(), 2);
        assert!(clients.iter().any(|client| client["id"] == first_id && client["self"] == true));
        assert!(
            clients
                .iter()
                .any(|client| client["self"] == false && client["transport"] == "websocket")
        );

        let clear = resource_request(
            "client-clear-name",
            "client.metadata.update",
            json!({
                "machine":"current",
                "session":"current",
                "client":first_id,
                "name":null,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, first, &clear, &first_writer, &scheduler));
        assert_eq!(pop_json(&first_outbound)["result"]["name"], Value::Null);

        let websocket_update = resource_request(
            "websocket-client-metadata",
            "client.metadata.update",
            json!({
                "machine":"current",
                "session":"current",
                "client":"current",
                "name":"websocket exact α",
                "kind":"web-client",
            }),
            None,
        );
        assert!(handle_connection_message(
            &mux,
            second,
            &websocket_update,
            &second_writer,
            &scheduler,
        ));
        let updated = pop_json(&second_outbound);
        assert_eq!(updated["ok"], true);
        assert_eq!(updated["result"]["transport"], "websocket");
        assert_eq!(updated["result"]["name"], "websocket exact α");
        assert_eq!(updated["result"]["client_kind"], "web-client");

        for (id, field, value) in [
            ("websocket-client-metadata-control", "name", "\u{1b}]0;evil\u{07}".to_string()),
            ("websocket-client-metadata-c1-control", "name", "c1\u{0085}control".to_string()),
            ("websocket-client-metadata-long", "kind", "k".repeat(65)),
        ] {
            let mut params = json!({
                "machine":"current",
                "session":"current",
                "client":"current",
            });
            params[field] = json!(value);
            let invalid = resource_request(id, "client.metadata.update", params, None);
            assert!(handle_connection_message(&mux, second, &invalid, &second_writer, &scheduler,));
            let rejected = pop_json(&second_outbound);
            assert_eq!(rejected["ok"], false);
            assert_eq!(rejected["error"]["code"], "validation.invalid");
            assert_eq!(rejected["error"]["details"]["field"], field);
        }

        let unchanged = resource_request(
            "websocket-client-metadata-unchanged",
            "client.get",
            json!({
                "machine":"current",
                "session":"current",
                "client":"current",
            }),
            None,
        );
        assert!(handle_connection_message(&mux, second, &unchanged, &second_writer, &scheduler,));
        let unchanged = pop_json(&second_outbound);
        assert_eq!(unchanged["result"]["name"], "websocket exact α");
        assert_eq!(unchanged["result"]["client_kind"], "web-client");

        let websocket_clear = resource_request(
            "websocket-client-metadata-clear",
            "client.metadata.update",
            json!({
                "machine":"current",
                "session":"current",
                "client":"current",
                "name":null,
                "kind":null,
            }),
            None,
        );
        assert!(handle_connection_message(
            &mux,
            second,
            &websocket_clear,
            &second_writer,
            &scheduler,
        ));
        let cleared = pop_json(&second_outbound);
        assert_eq!(cleared["result"]["name"], Value::Null);
        assert_eq!(cleared["result"]["client_kind"], Value::Null);
        disconnect_client(&mux, first, false);
        disconnect_client(&mux, second, false);
    }

    #[test]
    fn connection_handler_owns_every_router_connection_operation() {
        let catalog: Value =
            serde_json::from_str(include_str!("../../../spec/resource-operations-v2.json"))
                .unwrap();
        let mut connection_operations = 0usize;
        for name in catalog["operations"].as_object().unwrap().keys() {
            let operation: ResourceOperation =
                serde_json::from_value(Value::String(name.clone())).unwrap();
            let requires_connection =
                crate::resource_router::requires_connection_context(operation);
            assert_eq!(
                handles_resource_connection_operation(operation),
                requires_connection,
                "{name} has inconsistent connection ownership"
            );
            connection_operations += usize::from(requires_connection);
        }
        assert_eq!(connection_operations, 32);
    }

    #[test]
    fn terminal_resource_attach_acknowledges_before_styled_snapshot_and_cancels() {
        let mux = test_mux();
        let created = crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "terminal-attach-create",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"attach",
                    "initial_content":"terminal",
                }),
                Some("terminal-resource-attach-create"),
            ),
        )
        .unwrap();
        assert_eq!(created["ok"], true);
        let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
        let terminal_id =
            snapshot["terminals"][0]["id"].as_str().expect("created terminal id").to_string();

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stream_id = "stream_00000000000000000000000000000021";
        let attach = resource_request(
            "terminal-attach-open",
            "terminal.attach",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "stream_id":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &attach, &writer, &scheduler));

        let response = pop_json(&outbound);
        assert_eq!(response["type"], "response");
        assert_eq!(response["id"], "terminal-attach-open");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["stream_id"], stream_id);
        let attachment_lease = response["result"]["attachment_lease"]
            .as_str()
            .expect("resource attachments must expose a per-view lease")
            .to_string();
        let item = pop_json(&outbound);
        assert_eq!(item["type"], "stream_item");
        assert_eq!(item["stream_id"], stream_id);
        assert_eq!(item["sequence"], "0");
        assert!(item.get("cursor").is_none());
        assert_eq!(item["item"]["kind"], "snapshot");
        assert_eq!(item["item"]["terminal_id"], terminal_id);
        assert_eq!(
            item["item"]["render"]["rows"].as_array().unwrap().len(),
            item["item"]["render"]["size"]["rows"].as_u64().unwrap() as usize
        );

        let resize = resource_request(
            "terminal-attach-resize",
            "terminal.viewer.resize",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
                "attachment_lease":attachment_lease,
                "cols":91,
                "rows":27,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &resize, &writer, &scheduler));
        let resized = pop_json(&outbound);
        assert_eq!(resized["result"]["outcome"], "applied");
        assert_eq!(resized["result"]["size"], json!({"cols":91,"rows":27}));

        let cancel = resource_request(
            "terminal-attach-cancel",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        let end = pop_json(&outbound);
        assert_eq!(end["type"], "stream_end");
        assert_eq!(end["stream_id"], stream_id);
        assert_eq!(end["reason"], "canceled");
        assert_eq!(pop_json(&outbound)["id"], "terminal-attach-cancel");
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn sidebar_resource_attach_acknowledges_before_styled_snapshot_and_cancels() {
        let mux = Mux::new("server-sidebar-resource", SurfaceOptions::default());
        mux.configure_sidebar_plugin(Some(SidebarPluginOptions {
            command: vec!["/bin/cat".to_string()],
            cwd: None,
        }));
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let ensure = resource_request(
            "sidebar-attach-ensure",
            "sidebar_view.ensure",
            json!({
                "machine":"current",
                "session":"current",
                "cols":20,
                "rows":4,
            }),
            Some("server-sidebar-attach-ensure"),
        );
        assert!(handle_connection_message(&mux, client, &ensure, &writer, &scheduler));
        let ensured = pop_json(&outbound);
        assert_eq!(ensured["ok"], true);
        let sidebar_id =
            ensured["result"]["value"]["id"].as_str().expect("sidebar view id").to_string();

        let stream_id = "stream_00000000000000000000000000000022";
        let attach = resource_request(
            "sidebar-attach-open",
            "sidebar_view.attach",
            json!({
                "machine":"current",
                "session":"current",
                "sidebar_view":sidebar_id,
                "stream_id":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &attach, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["type"], "response");
        assert_eq!(response["id"], "sidebar-attach-open");
        assert_eq!(response["ok"], true);
        assert_eq!(response["result"]["stream_id"], stream_id);
        let item = pop_json(&outbound);
        assert_eq!(item["type"], "stream_item");
        assert_eq!(item["stream_id"], stream_id);
        assert_eq!(item["sequence"], "0");
        assert!(item.get("cursor").is_none());
        assert_eq!(item["item"]["kind"], "snapshot");
        assert_eq!(item["item"]["sidebar_view"]["id"], sidebar_id);
        assert_eq!(
            item["item"]["render"]["rows"].as_array().unwrap().len(),
            item["item"]["render"]["size"]["rows"].as_u64().unwrap() as usize
        );

        let cancel = resource_request(
            "sidebar-attach-cancel",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":stream_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        let end = pop_json(&outbound);
        assert_eq!(end["type"], "stream_end");
        assert_eq!(end["stream_id"], stream_id);
        assert_eq!(end["reason"], "canceled");
        assert_eq!(pop_json(&outbound)["id"], "sidebar-attach-cancel");
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn session_event_stream_replays_covered_cursor_and_rejects_ahead_cursor() {
        let mux = test_mux();
        let initial = crate::resource_api::public_session_snapshot(&mux).unwrap();
        let generation = initial["cursor"]["generation"].as_str().unwrap().to_string();
        let created = crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "create-for-replay",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"replayed",
                    "initial_content":"empty",
                }),
                Some("create-for-session-event-replay"),
            ),
        )
        .unwrap();
        assert_eq!(created["result"]["revision"], "1");

        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let stream_id = "stream_00000000000000000000000000000002";
        let open = resource_request(
            "events-replay",
            "session.events",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
                "cursor":{"generation":generation,"revision":"0"},
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["id"], "events-replay");
        let delta = pop_json(&outbound);
        assert_eq!(delta["item"]["kind"], "delta");
        assert_eq!(delta["item"]["previous_revision"], "0");
        assert_eq!(delta["item"]["revision"], "1");
        assert_eq!(delta["item"]["changes"][0]["kind"], "upsert");
        assert_eq!(delta["item"]["changes"][0]["resource"], "workspace");

        let ahead_id = "stream_00000000000000000000000000000003";
        let ahead = resource_request(
            "events-ahead",
            "session.events",
            json!({
                "machine":"current",
                "session":"current",
                "stream_id":ahead_id,
                "cursor":{"generation":generation,"revision":"999"},
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &ahead, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["id"], "events-ahead");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "cursor.invalid");
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn generation_mismatch_resets_one_stream_without_interrupting_another() {
        let mux = test_mux();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let first_id = "stream_00000000000000000000000000000004";
        let second_id = "stream_00000000000000000000000000000005";
        for (request_id, stream_id, cursor) in [
            ("events-reset", first_id, Some(json!({"generation":"stale","revision":"0"}))),
            ("events-live", second_id, None),
        ] {
            let mut params = json!({
                "machine":"current",
                "session":"current",
                "stream_id":stream_id,
            });
            if let Some(cursor) = cursor {
                params["cursor"] = cursor;
            }
            let open = resource_request(request_id, "session.events", params, None);
            assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
            assert_eq!(pop_json(&outbound)["id"], request_id);
            let snapshot = pop_json(&outbound);
            assert_eq!(snapshot["stream_id"], stream_id);
            assert_eq!(
                snapshot["item"]["reset_reason"],
                if stream_id == first_id { "generation_changed" } else { "initial" }
            );
        }

        let cancel = resource_request(
            "cancel-reset",
            "stream.cancel",
            json!({
                "machine":"current",
                "session":"current",
                "stream":first_id,
            }),
            None,
        );
        assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
        assert_eq!(pop_json(&outbound)["stream_id"], first_id);
        assert_eq!(pop_json(&outbound)["id"], "cancel-reset");

        crate::resource_router::handle_resource_message(
            &mux,
            &resource_request(
                "create-for-live",
                "workspace.create",
                json!({
                    "machine":"current",
                    "session":"current",
                    "name":"live",
                    "initial_content":"empty",
                }),
                Some("create-for-live-session-event"),
            ),
        )
        .unwrap();
        let delta = pop_json(&outbound);
        assert_eq!(delta["type"], "stream_item");
        assert_eq!(delta["stream_id"], second_id);
        assert_eq!(delta["item"]["kind"], "delta");
        disconnect_client(&mux, client, false);
    }

    #[test]
    fn browser_state_json_exposes_pointer_admission_separately_from_the_retained_frame() {
        let state = BrowserAttachState {
            url: "https://example.test".to_string(),
            title: "example".to_string(),
            cols: 10,
            rows: 5,
            status: BrowserStatus::Live,
            frame: Some(BrowserFrame {
                session_id: "session-test".to_string(),
                data_b64: "AAAA".to_string(),
                css_width: 80,
                css_height: 48,
                image_width: 80,
                image_height: 48,
                seq: 7,
            }),
            pointer_frame_floor_seq: None,
            pointer_frame_seq: None,
            frames_stalled: false,
        };

        let value = serde_json::to_value(browser_state_message(1, &state, true)).unwrap();
        assert_eq!(
            value.get("pointer_frame_seq"),
            Some(&Value::Null),
            "a retained image can remain renderable while pointer admission is invalid"
        );
        assert_eq!(value["frame"]["seq"], 7);
    }

    #[test]
    fn browser_frame_json_couples_authoritative_pointer_admission() {
        let update = BrowserFrameUpdate {
            frame: BrowserFrame {
                session_id: "session-test".to_string(),
                data_b64: "AAAA".to_string(),
                css_width: 80,
                css_height: 48,
                image_width: 80,
                image_height: 48,
                seq: 7,
            },
            status: BrowserStatus::Failed("navigation failed".to_string()),
            pointer_frame_floor_seq: None,
            pointer_frame_seq: None,
        };

        let value = browser_frame_json(1, &update);

        assert_eq!(value["status"], "failed");
        assert_eq!(value["error"], "navigation failed");
        assert_eq!(value.get("pointer_frame_seq"), Some(&Value::Null));
        assert_eq!(value["seq"], 7);
    }

    #[test]
    fn browser_resource_frame_couples_exact_nullable_pointer_authority() {
        let frame = BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            seq: 7,
        };

        let guarded = browser_resource_frame(&frame, Some(u64::MAX));
        assert_eq!(guarded["pointer_frame_seq"], u64::MAX.to_string());

        let retained = browser_resource_frame(&frame, None);
        assert_eq!(retained.get("pointer_frame_seq"), Some(&Value::Null));
    }

    #[test]
    fn browser_attach_stream_publishes_frame_before_positive_state_authority() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&json!({"event": "overflow"})).unwrap();
        let frame = BrowserFrame {
            session_id: "session-test".to_string(),
            data_b64: "AAAA".to_string(),
            css_width: 80,
            css_height: 48,
            image_width: 80,
            image_height: 48,
            seq: 7,
        };
        let update = BrowserAttachUpdate {
            frame: Some(BrowserFrameUpdate {
                frame: frame.clone(),
                status: BrowserStatus::Live,
                pointer_frame_floor_seq: Some(7),
                pointer_frame_seq: Some(7),
            }),
            state: Some(BrowserAttachState {
                url: "https://example.test".to_string(),
                title: "example".to_string(),
                cols: 10,
                rows: 5,
                status: BrowserStatus::Live,
                frame: Some(frame),
                pointer_frame_floor_seq: Some(7),
                pointer_frame_seq: Some(7),
                frames_stalled: false,
            }),
        };

        send_browser_attach_update(&writer, 1, update, &stream).unwrap();
        let first: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        let second: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();

        assert_eq!(first["event"], "frame");
        assert_eq!(first["pointer_frame_floor_seq"], 7);
        assert_eq!(first["pointer_frame_seq"], 7);
        assert_eq!(second["event"], "browser-state");
        assert_eq!(second["pointer_frame_floor_seq"], 7);
        assert_eq!(second["pointer_frame_seq"], 7);
    }

    #[test]
    fn browser_state_serializes_css_and_encoded_image_dimensions() {
        let state = BrowserAttachState {
            url: "https://example.com".to_string(),
            title: "Example".to_string(),
            cols: 80,
            rows: 24,
            status: BrowserStatus::Live,
            frame: Some(BrowserFrame {
                session_id: "browser-session".to_string(),
                data_b64: "frame".to_string(),
                css_width: 800,
                css_height: 600,
                image_width: 400,
                image_height: 300,
                seq: 7,
            }),
            pointer_frame_floor_seq: Some(7),
            pointer_frame_seq: Some(7),
            frames_stalled: false,
        };

        let value = serde_json::to_value(browser_state_message(3, &state, true)).unwrap();
        assert_eq!(value["frame"]["width"], 800);
        assert_eq!(value["frame"]["height"], 600);
        assert_eq!(value["frame"]["image_width"], 400);
        assert_eq!(value["frame"]["image_height"], 300);
    }

    #[test]
    fn stack_json_uses_the_stored_expansion_while_focus_is_elsewhere() {
        let stack = Node::stack_with_expanded(vec![1, 2, 3], 2).unwrap();

        assert_eq!(node_json(&stack, 1)["expanded"], 1);
        assert_eq!(node_json(&stack, 9)["expanded"], 2);
    }

    #[test]
    fn exported_stack_layout_is_accepted_as_an_apply_request() {
        let request = serde_json::from_value::<LayoutRequest>(json!({
            "type": "stack",
            "panes": [3, 4, 5],
            "expanded": 4
        }));

        let spec = layout_request_to_spec(request.unwrap()).unwrap();
        assert!(matches!(spec, LayoutSpec::Stack { pane_count: 3, expanded_index: 1 }));
    }

    #[test]
    fn swapping_across_a_stack_boundary_keeps_exported_expansion_valid() {
        let mut root = Node::Split {
            id: 10,
            dir: SplitDir::Right,
            ratio: 0.5,
            a: Box::new(Node::Leaf(1)),
            b: Box::new(Node::stack_with_expanded(vec![2, 3], 2).unwrap()),
        };

        assert!(root.swap_leaves(1, 2));
        let exported = node_json(&root, 2);
        assert_eq!(exported["b"]["panes"], json!([1, 3]));
        assert_eq!(exported["b"]["expanded"], 1);
    }

    #[test]
    fn swapping_within_a_stack_keeps_the_same_pane_expanded() {
        let mut stack = Node::stack_with_expanded(vec![1, 2, 3], 2).unwrap();

        assert!(stack.swap_leaves(2, 3));
        let exported = node_json(&stack, 9);
        assert_eq!(exported["panes"], json!([1, 3, 2]));
        assert_eq!(exported["expanded"], 2);
    }

    #[test]
    fn bounded_writer_reserves_a_control_lane_for_responses_and_overflow() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let backlog = writer.start_stream(&json!({"event": "overflow"})).unwrap();

        for sequence in 0..OUTBOUND_CAPACITY - 1 {
            writer
                .send_stream(&json!({"event": "output", "sequence": sequence}), &backlog)
                .unwrap();
        }

        let failed_stream = writer.start_stream(&subscription_overflow_json()).unwrap();
        writer.send_control(&json!({"id": 42, "ok": true, "data": {}})).unwrap();
        writer.send_terminal(&subscription_overflow_json(), &failed_stream).unwrap();
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 42);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        let drained = (0..OUTBOUND_CAPACITY - 1)
            .map(|_| outbound.try_pop().expect("accepted output"))
            .collect::<Vec<_>>();
        assert!(drained[0].contains("\"sequence\":0"));
        assert!(writer.is_open());
    }

    #[test]
    fn initial_stream_state_precedes_its_response_and_overflows_only_its_stream() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();

        writer.send_initial(&json!({"event": "vt-state", "surface": 7}), &stream).unwrap();
        writer.send_control(&json!({"id": 1, "ok": true})).unwrap();
        let initial: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(initial["event"], "vt-state");
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 1);

        let oversized = writer.start_stream(&attach_overflow_json(8)).unwrap();
        let error = writer
            .send_initial(
                &json!({"event": "vt-state", "data": "x".repeat(OUTBOUND_BYTE_CAPACITY)}),
                &oversized,
            )
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        let overflow: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(overflow["event"], "overflow");
        assert_eq!(overflow["surface"], 8);
        assert!(writer.is_open());
    }

    #[test]
    fn vt_state_wire_prefix_identifies_attach_before_large_replay_data() {
        let replay = Arc::<[u8]>::from(vec![b'x'; 1024]);
        let message = VtStateMessage {
            surface: 7,
            cols: 80,
            rows: 24,
            replay: replay.clone(),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::disabled(),
            colors: Value::Null,
        };

        let serialized = RenderService::new().serialize_vt_state(&message).unwrap();

        assert!(serialized.starts_with(r#"{"event":"vt-state","surface":7,"#), "{}", &**serialized);
        let decoded: Value = serde_json::from_str(&serialized).unwrap();
        assert_eq!(decoded["data"], base64::engine::general_purpose::STANDARD.encode(replay));
    }

    #[test]
    fn maximum_vt_state_command_response_fits_the_control_reserve() {
        let service = RenderService::new();
        let outbound = BoundedOutbound::default();
        let replay = vec![0_u8; crate::surface::VT_REPLAY_MAX_BYTES];

        let mut output = service.reserved_control_writer().unwrap();
        write_vt_state_command_json(
            &mut output,
            Some(&json!(1)),
            80,
            24,
            &replay,
            &[],
            KittyReplayState::disabled(),
        )
        .unwrap();
        let serialized = output.finish();
        assert!(serialized.len() < OUTBOUND_CONTROL_BYTE_RESERVE);
        assert_eq!(serialized.retained_bytes, OUTBOUND_CONTROL_BYTE_RESERVE);
        assert!(serialized.starts_with(r#"{"id":1,"ok":true,"data":{"cols":80,"#));
        outbound.push_control(serialized).unwrap();
        assert!(outbound.try_pop().is_some());
    }

    #[test]
    fn vt_state_releases_unused_control_reservation_after_encoding() {
        const RESERVATION: usize = 128;
        let budget = Arc::new(OutboundByteBudget::new(RESERVATION * 4));
        let mut queued = Vec::new();

        for _ in 0..5 {
            let mut reservation =
                BudgetedJsonWriter::with_reservation(budget.clone(), RESERVATION).unwrap();
            assert_eq!(reservation.bytes.capacity(), 0);
            reservation.write_all(b"{}").unwrap();
            queued.push(reservation.finish());
        }

        assert!(budget.retained_bytes.load(Ordering::Acquire) < RESERVATION);
        drop(queued);
        assert_eq!(budget.retained_bytes.load(Ordering::Acquire), 0);
    }

    #[test]
    fn websocket_server_headers_cover_every_outbound_payload_width() {
        let (small, small_len) = websocket_server_frame_header(0x1, 125);
        assert_eq!(&small[..small_len], &[0x81, 125]);

        let (medium, medium_len) = websocket_server_frame_header(0x1, 126);
        assert_eq!(&medium[..medium_len], &[0x81, 126, 0, 126]);

        let (large, large_len) = websocket_server_frame_header(0x1, RENDER_ATTACH_MAX_BYTES);
        assert_eq!(large_len, 10);
        assert_eq!(large[0], 0x81);
        assert_eq!(large[1], 127);
        assert_eq!(&large[2..10], &(RENDER_ATTACH_MAX_BYTES as u64).to_be_bytes());
    }

    #[test]
    fn browser_state_wire_prefix_identifies_attach_before_large_frame_data() {
        let state = BrowserAttachState {
            url: "https://example.com".into(),
            title: "Example".into(),
            cols: 80,
            rows: 24,
            status: BrowserStatus::Live,
            frame: Some(BrowserFrame {
                session_id: "session".into(),
                data_b64: "eA==".repeat(256),
                css_width: 800,
                css_height: 600,
                image_width: 800,
                image_height: 600,
                seq: 1,
            }),
            pointer_frame_floor_seq: Some(1),
            pointer_frame_seq: Some(1),
            frames_stalled: false,
        };

        let serialized =
            RenderService::new().serialize(&browser_state_message(7, &state, true)).unwrap();

        assert!(
            serialized.starts_with(r#"{"event":"browser-state","surface":7,"#),
            "{}",
            &**serialized
        );
        let decoded: Value = serde_json::from_str(&serialized).unwrap();
        assert_eq!(decoded["frame"]["data"], state.frame.as_ref().unwrap().data_b64);
    }

    #[test]
    fn vt_state_streaming_releases_partial_global_budget_on_overflow() {
        let service = RenderService::new_with_outbound_budget(64);
        let message = VtStateMessage {
            surface: 7,
            cols: 80,
            rows: 24,
            replay: Arc::from(vec![b'x'; 1024]),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::disabled(),
            colors: Value::Null,
        };

        let error = service
            .serialize_vt_state(&message)
            .err()
            .expect("oversized replay must exhaust the global budget");

        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        assert_eq!(service.outbound_budget.retained_bytes.load(Ordering::Acquire), 0);
    }

    #[test]
    fn resize_stream_serialization_reserves_budget_before_queueing() {
        let service = Arc::new(RenderService::new_with_outbound_budget(64));
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: outbound.clone(), control: None },
            service.clone(),
        );
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
        let frame = AttachFrame::Resized {
            cols: 80,
            rows: 24,
            replay: Arc::from(vec![b'x'; 1024]),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::disabled(),
        };

        let error = writer.send_attach_frame_backpressured(7, &frame, &stream).unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        assert!(outbound.try_pop().is_none());
        assert_eq!(service.outbound_budget.retained_bytes.load(Ordering::Acquire), 0);
    }

    #[test]
    fn server_connection_permits_enforce_and_release_the_cap() {
        let active = Arc::new(AtomicU64::new(MAX_SERVER_CONNECTIONS as u64));
        assert!(claim_connection(&active).is_none());
        active.store(MAX_SERVER_CONNECTIONS as u64 - 1, Ordering::Release);
        let permit = claim_connection(&active).expect("last connection slot");
        assert_eq!(active.load(Ordering::Acquire), MAX_SERVER_CONNECTIONS as u64);
        drop(permit);
        assert_eq!(active.load(Ordering::Acquire), MAX_SERVER_CONNECTIONS as u64 - 1);
    }

    #[test]
    fn shutting_down_a_writer_clone_unblocks_the_reader() {
        let socket = TestSocket::new("shutdown");
        let listener = transport::listen(&socket.path).unwrap();
        let _client = transport::connect(&socket.path).unwrap();
        let mut reader = listener.accept().unwrap();
        let writer = reader.try_clone_box().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let read_thread = std::thread::spawn(move || {
            let mut byte = [0_u8; 1];
            done.send(reader.read(&mut byte)).unwrap();
        });

        writer.shutdown(Shutdown::Both).unwrap();
        assert_eq!(finished.recv_timeout(Duration::from_secs(1)).unwrap().unwrap(), 0);
        read_thread.join().unwrap();
    }

    #[test]
    fn write_side_eof_drains_accepted_surface_requests() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
        });

        let socket = TestSocket::new("write-eof-drain");
        let listener = transport::listen(&socket.path).unwrap();
        let mut client = transport::connect(&socket.path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));

        writeln!(client, "{}", json!({"id": 1, "cmd": "clear-history", "surface": surface.id}))
            .unwrap();
        writeln!(
            client,
            "{}",
            json!({"id": 2, "cmd": "send", "surface": surface.id, "text": "after-eof"})
        )
        .unwrap();
        client.flush().unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(2))).unwrap();

        let mut responses = Vec::new();
        let mut reader = BufReader::new(client);
        while responses.len() < 2 {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => responses.push(serde_json::from_str::<Value>(&line).unwrap()),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                }
                Err(error) => panic!("unexpected response read error: {error}"),
            }
        }
        let _ = reader.get_ref().shutdown(Shutdown::Both);
        handler.join().unwrap();
        mux.close_surface(surface.id).unwrap();

        let response_ids =
            responses.iter().filter_map(|response| response["id"].as_u64()).collect::<Vec<_>>();
        assert_eq!(response_ids, [1, 2], "write-side EOF discarded an accepted request");
    }

    #[test]
    fn clear_history_rejection_reports_known_not_delivered_delivery() {
        let mux = test_mux();
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        assert!(handle_message(
            &mux,
            client,
            &json!({"id": 1, "cmd": "clear-history", "surface": 999_999}).to_string(),
            &writer,
        ));
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();

        assert_eq!(response["ok"], false);
        assert_eq!(response["error_delivery"], "known-not-delivered");
    }

    #[test]
    fn clear_history_does_not_block_unrelated_surface_input_on_one_connection() {
        let mux = test_mux();
        let blocked = mux.new_workspace(None, Some((80, 24))).unwrap();
        let unrelated = mux.new_workspace(None, Some((80, 24))).unwrap();
        blocked.with_terminal(|term| {
            for line in 0..24 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07prompt> \x1b[31");
        });

        let socket = TestSocket::new("clear-concurrency");
        let listener = transport::listen(&socket.path).unwrap();
        let mut client = transport::connect(&socket.path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux.clone();
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));

        client.set_read_timeout(Some(Duration::from_millis(150))).unwrap();
        writeln!(client, "{}", json!({"id": 1, "cmd": "clear-history", "surface": blocked.id}))
            .unwrap();
        client.flush().unwrap();
        std::thread::sleep(Duration::from_millis(30));
        writeln!(
            client,
            "{}",
            json!({"id": 2, "cmd": "send", "surface": blocked.id, "text": "same"})
        )
        .unwrap();
        writeln!(
            client,
            "{}",
            json!({"id": 3, "cmd": "send", "surface": unrelated.id, "text": "other"})
        )
        .unwrap();
        client.flush().unwrap();

        let mut reader = BufReader::new(client);
        let mut first_line = String::new();
        let first_response = reader.read_line(&mut first_line);
        reader.get_ref().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut ordered_lines = Vec::new();
        for _ in 0..2 {
            let mut line = String::new();
            ordered_lines.push((reader.read_line(&mut line), line));
        }
        let _ = reader.get_ref().shutdown(Shutdown::Both);
        handler.join().unwrap();
        mux.close_surface(blocked.id).unwrap();
        mux.close_surface(unrelated.id).unwrap();

        first_response.expect("unrelated input response was blocked behind clear-history");
        let first_response: Value = serde_json::from_str(&first_line).unwrap();
        assert_eq!(first_response["id"], 3);
        assert_eq!(first_response["ok"], true);
        let ordered_ids = ordered_lines
            .into_iter()
            .map(|(read, line)| {
                read.expect("same-surface request did not settle after clear-history");
                serde_json::from_str::<Value>(&line).unwrap()["id"].as_u64().unwrap()
            })
            .collect::<Vec<_>>();
        assert_eq!(ordered_ids, [1, 2]);
    }

    #[test]
    fn lifecycle_command_waits_for_active_clear_history_on_one_connection() {
        let mux = test_mux();
        let blocked = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(blocked.id).unwrap());
        blocked.with_terminal(|term| {
            for line in 0..24 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07prompt> \x1b[31");
        });

        let socket = TestSocket::new("clear-lifecycle");
        let listener = transport::listen(&socket.path).unwrap();
        let mut client = transport::connect(&socket.path).unwrap();
        let server = listener.accept().unwrap();
        let server_mux = mux;
        let handler = std::thread::spawn(move || handle_connection(server_mux, server));

        writeln!(client, "{}", json!({"id": 1, "cmd": "clear-history", "surface": blocked.id}))
            .unwrap();
        client.flush().unwrap();
        std::thread::sleep(Duration::from_millis(30));
        writeln!(client, "{}", json!({"id": 2, "cmd": "close-pane", "pane": pane})).unwrap();
        client.flush().unwrap();

        client.set_read_timeout(Some(Duration::from_millis(75))).unwrap();
        let mut reader = BufReader::new(client);
        let mut early_line = String::new();
        let early_response = match reader.read_line(&mut early_line) {
            Ok(0) => panic!("connection closed before clear-history settled"),
            Ok(_) => Some(early_line),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                None
            }
            Err(error) => panic!("unexpected response read error: {error}"),
        };

        reader.get_ref().set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut responses = early_response.iter().cloned().collect::<Vec<_>>();
        while responses.len() < 2 {
            let mut line = String::new();
            reader.read_line(&mut line).expect("ordered lifecycle response");
            responses.push(line);
        }
        let _ = reader.get_ref().shutdown(Shutdown::Both);
        handler.join().unwrap();

        assert!(
            early_response.is_none(),
            "lifecycle command responded before clear-history reached a safe boundary"
        );
        let response_ids = responses
            .into_iter()
            .map(|line| serde_json::from_str::<Value>(&line).unwrap()["id"].as_u64().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(response_ids, [1, 2]);
    }

    fn active_clear_lanes_across_connections(request_count: usize, retained_bytes: usize) -> usize {
        let mux = test_mux();
        let writer = test_writer();
        let admission = Arc::new(ServerSurfaceOperationAdmission::default());
        let schedulers = [
            Arc::new(ConnectionSurfaceScheduler::new(admission.clone())),
            Arc::new(ConnectionSurfaceScheduler::new(admission)),
        ];
        let surfaces = (0..request_count)
            .map(|_| {
                let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
                surface.with_terminal(|term| {
                    term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
                });
                surface
            })
            .collect::<Vec<_>>();

        for (index, surface) in surfaces.iter().enumerate() {
            let scheduler = &schedulers[index % schedulers.len()];
            let mut request = Some(Request {
                id: Some(json!(index)),
                cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
            });
            assert_eq!(
                scheduler.dispatch(mux.clone(), 0, &mut request, retained_bytes, writer.clone(),),
                Some(true)
            );
        }
        let active = schedulers
            .iter()
            .map(|scheduler| scheduler.state.lock().unwrap().active_clear_surfaces.len())
            .sum();

        for scheduler in &schedulers {
            let _ = scheduler.close_and_wait(Duration::from_secs(1));
        }
        for surface in surfaces {
            mux.close_surface(surface.id).unwrap();
        }
        active
    }

    #[test]
    fn connection_surface_schedulers_for_one_mux_share_admission() {
        let mux = test_mux();
        let first = ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone());
        let second = ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone());
        assert!(Arc::ptr_eq(&first.admission, &second.admission));
    }

    #[test]
    fn blocking_wait_cannot_overtake_input_queued_behind_a_clear_barrier() {
        let admission = Arc::new(ServerSurfaceOperationAdmission::default());
        let mut state = ConnectionSurfaceState::default();
        state.active_clear_surfaces.insert(1);
        for (id, cmd) in [
            (
                1,
                Command::Send {
                    surface: 1,
                    text: Some("input".to_string()),
                    bytes: None,
                    paste: false,
                },
            ),
            (2, Command::WaitFor { surface: 2, pattern: "never".to_string(), timeout_ms: 60_000 }),
        ] {
            state.requests.push_back(PendingSurfaceRequest {
                request: Request { id: Some(json!(id)), cmd },
                retained_bytes: 0,
                _bytes_permit: admission.try_reserve_bytes(0).unwrap(),
            });
        }

        assert_eq!(
            ConnectionSurfaceScheduler::next_runnable_index(&state),
            None,
            "blocking wait overtook earlier input while its clear barrier was active"
        );
    }

    #[test]
    fn guarded_browser_pointer_input_overtakes_an_unrelated_clear_barrier() {
        for cmd in [
            Command::BrowserFramePresented { surface: 2, frame_seq: 7 },
            Command::BrowserMouseGuarded {
                surface: 2,
                kind: "move".to_string(),
                x_px: 1.0,
                y_px: 1.0,
                button: None,
                click_count: None,
                frame_seq: 7,
            },
            Command::BrowserWheelGuarded {
                surface: 2,
                x_px: 1.0,
                y_px: 1.0,
                delta_y_px: 1.0,
                frame_seq: 7,
            },
        ] {
            let admission = Arc::new(ServerSurfaceOperationAdmission::default());
            let mut state = ConnectionSurfaceState::default();
            state.active_clear_surfaces.insert(1);
            state.requests.push_back(PendingSurfaceRequest {
                request: Request { id: Some(json!(1)), cmd },
                retained_bytes: 0,
                _bytes_permit: admission.try_reserve_bytes(0).unwrap(),
            });

            assert_eq!(
                ConnectionSurfaceScheduler::next_runnable_index(&state),
                Some(0),
                "guarded browser pointer input waited behind an unrelated clear-history worker"
            );
        }
    }

    #[test]
    fn queued_same_surface_clears_do_not_reserve_worker_permits() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
        });
        let admission = Arc::new(ServerSurfaceOperationAdmission::default());
        let scheduler = Arc::new(ConnectionSurfaceScheduler::new(admission.clone()));
        let writer = test_writer();

        for id in 0..SERVER_SURFACE_WORKER_CAPACITY {
            let mut clear = Some(Request {
                id: Some(json!(id)),
                cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
            });
            assert_eq!(
                scheduler.dispatch(mux.clone(), 0, &mut clear, 0, writer.clone()),
                Some(true)
            );
        }

        let reserved_workers = admission.state.lock().unwrap().workers;
        let _ = scheduler.close_and_wait(Duration::from_secs(1));
        mux.close_surface(surface.id).unwrap();

        assert!(
            reserved_workers <= 1,
            "queued same-surface clears reserved {reserved_workers} mux-wide worker permits"
        );
    }

    #[test]
    fn queued_wait_releases_clear_worker_permit_after_clear_settles() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
        });
        let admission = Arc::new(ServerSurfaceOperationAdmission::default());
        let scheduler = Arc::new(ConnectionSurfaceScheduler::new(admission.clone()));
        let (writer, outbound) = captured_writer();

        let mut clear = Some(Request {
            id: Some(json!(1)),
            cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
        });
        assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut clear, 0, writer.clone()), Some(true));
        let mut wait = Some(Request {
            id: Some(json!(2)),
            cmd: Command::WaitFor {
                surface: surface.id,
                pattern: "never-matches".to_string(),
                timeout_ms: 500,
            },
        });
        assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut wait, 0, writer), Some(true));

        let clear_response = pop_json(&outbound);
        assert_eq!(clear_response["id"], json!(1));
        let clear_deadline = Instant::now() + Duration::from_secs(1);
        let mut state = scheduler.state.lock().unwrap();
        while state.active_clear_surfaces.contains(&surface.id) {
            let remaining = clear_deadline.saturating_duration_since(Instant::now());
            assert!(!remaining.is_zero(), "clear-history worker did not settle");
            let (next, timeout) = scheduler.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            assert!(
                !timeout.timed_out() || !state.active_clear_surfaces.contains(&surface.id),
                "clear-history worker did not settle"
            );
        }
        drop(state);
        let active_clear_workers = admission.state.lock().unwrap().workers;
        let drained = scheduler.close_and_wait(Duration::from_secs(1));
        mux.close_surface(surface.id).unwrap();

        assert_eq!(
            active_clear_workers, 0,
            "a queued wait-for retained the completed clear-history worker permit"
        );
        assert!(drained);
    }

    #[test]
    fn connection_close_cancels_a_wait_queued_after_clear_history() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
        });
        let scheduler = Arc::new(ConnectionSurfaceScheduler::new(Arc::new(
            ServerSurfaceOperationAdmission::default(),
        )));
        let writer = test_writer();

        let mut clear = Some(Request {
            id: Some(json!(1)),
            cmd: Command::ClearHistory { surface: surface.id, fallback_key: None },
        });
        assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut clear, 0, writer.clone()), Some(true));
        let mut wait = Some(Request {
            id: Some(json!(2)),
            cmd: Command::WaitFor {
                surface: surface.id,
                pattern: "release-wait".to_string(),
                timeout_ms: 1_000,
            },
        });
        assert_eq!(scheduler.dispatch(mux.clone(), 0, &mut wait, 0, writer), Some(true));

        std::thread::sleep(Duration::from_millis(350));
        let drained = scheduler.close_and_wait(Duration::from_millis(500));
        if !drained {
            let _ = scheduler.close_and_wait(Duration::from_secs(1));
        }
        mux.close_surface(surface.id).unwrap();

        assert!(drained, "connection shutdown did not cancel an active wait-for request");
    }

    #[test]
    fn independent_muxes_do_not_share_surface_operation_admission() {
        let first_mux = test_mux();
        let second_mux = test_mux();
        let first = ConnectionSurfaceScheduler::new(first_mux.surface_operation_admission.clone());
        let second =
            ConnectionSurfaceScheduler::new(second_mux.surface_operation_admission.clone());
        let permits = (0..SERVER_SURFACE_WORKER_CAPACITY)
            .map(|_| first.admission.try_reserve_worker().unwrap())
            .collect::<Vec<_>>();

        let isolated = second.admission.try_reserve_worker();
        drop(permits);

        assert!(
            isolated.is_some(),
            "one mux exhausted the hidden process-global admission budget of another mux"
        );
    }

    #[test]
    fn scheduler_retains_connection_permit_until_dispatcher_exit() {
        let active = Arc::new(AtomicU64::new(0));
        let permit = claim_connection(&active).unwrap();
        let scheduler = Arc::new(ConnectionSurfaceScheduler::new_with_connection_permit(
            Arc::new(ServerSurfaceOperationAdmission::default()),
            permit,
        ));
        scheduler.state.lock().unwrap().dispatcher_started = true;
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let worker_scheduler = scheduler.clone();
        let dispatcher = std::thread::spawn(move || {
            release_rx.recv().unwrap();
            worker_scheduler.finish_dispatcher();
        });
        *scheduler.dispatcher.lock().unwrap() = Some(dispatcher);

        assert!(!scheduler.close_and_wait(Duration::from_millis(25)));
        assert_eq!(
            active.load(Ordering::Acquire),
            1,
            "timed-out shutdown released admission while its dispatcher was live"
        );

        release_tx.send(()).unwrap();
        assert!(scheduler.close_and_wait(Duration::from_secs(1)));
        assert_eq!(active.load(Ordering::Acquire), 0);
    }

    #[test]
    fn surface_worker_limit_is_mux_wide_across_connections() {
        assert!(
            active_clear_lanes_across_connections(17, 0) <= 16,
            "per-connection limits allowed more than 16 mux-wide clear workers"
        );
    }

    #[test]
    fn active_surface_request_bytes_count_toward_mux_budget() {
        const FOUR_MIB: usize = 4 * 1024 * 1024;
        assert!(
            active_clear_lanes_across_connections(5, FOUR_MIB) <= 4,
            "active first requests bypassed the 16 MiB mux-wide byte budget"
        );
    }

    #[test]
    fn stalled_websocket_handshake_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(
                test_mux(),
                server,
                peer,
                None,
                Arc::new(RenderService::new()),
            );
            done.send(()).unwrap();
        });

        finished
            .recv_timeout(Duration::from_secs(1))
            .expect("stalled handshake must not occupy a connection slot indefinitely");
        drop(client);
        handler.join().unwrap();
    }

    #[test]
    fn stalled_websocket_authentication_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client_stream = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, peer) = listener.accept().unwrap();
        let (done, finished) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            handle_websocket_connection(
                test_mux(),
                server,
                peer,
                Some("secret"),
                Arc::new(RenderService::new()),
            );
            done.send(()).unwrap();
        });
        let (client, _) = tungstenite::client("ws://localhost/", client_stream).unwrap();

        finished
            .recv_timeout(Duration::from_secs(1))
            .expect("stalled authentication must not occupy a connection slot indefinitely");
        drop(client);
        handler.join().unwrap();
    }

    #[test]
    fn each_stream_has_an_independent_message_budget() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let noisy = writer.start_stream(&json!({"event": "overflow", "stream": "noisy"})).unwrap();
        let quiet = writer.start_stream(&json!({"event": "overflow", "stream": "quiet"})).unwrap();

        for sequence in 0..OUTBOUND_CAPACITY {
            writer.send_stream(&json!({"event": "output", "sequence": sequence}), &noisy).unwrap();
        }
        writer.send_stream(&json!({"event": "tree-changed"}), &quiet).unwrap();
        assert_eq!(
            writer.send_stream(&json!({"event": "one-too-many"}), &noisy).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );

        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["stream"], "noisy");
        let quiet_event: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(quiet_event["event"], "tree-changed");
        assert_eq!(outbound.try_pop(), None);
        assert_eq!(
            writer.send_stream(&json!({"event": "late"}), &noisy).unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
        assert!(quiet.is_open());
        assert!(writer.is_open());
    }

    #[test]
    fn graceful_stream_terminal_is_ordered_after_queued_items() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&json!({"event":"overflow"})).unwrap();
        writer.send_stream(&json!({"event":"first"}), &stream).unwrap();
        writer.send_stream(&json!({"event":"second"}), &stream).unwrap();
        writer.send_ordered_terminal(&json!({"event":"completed"}), &stream).unwrap();

        assert_eq!(pop_json(&outbound)["event"], "first");
        assert_eq!(pop_json(&outbound)["event"], "second");
        assert_eq!(pop_json(&outbound)["event"], "completed");
        assert!(!stream.is_open());
        assert_eq!(
            writer.send_stream(&json!({"event":"late"}), &stream).unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
    }

    #[test]
    fn backpressured_stream_waits_for_its_prior_item_without_overflow() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
        writer.send_stream(&json!({"event": "first"}), &stream).unwrap();
        writer.send_stream(&json!({"event": "second"}), &stream).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let waiting_writer = writer;
        let waiting_stream = stream.clone();
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            done_tx
                .send(
                    waiting_writer
                        .send_stream_backpressured(&json!({"event": "third"}), &waiting_stream),
                )
                .unwrap();
        });

        started_rx.recv().unwrap();
        assert!(done_rx.recv_timeout(Duration::from_millis(20)).is_err());
        assert!(stream.is_open(), "backpressure terminated a healthy stream");
        assert_eq!(pop_json(&outbound)["event"], "first");
        done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        assert_eq!(pop_json(&outbound)["event"], "second");
        assert_eq!(pop_json(&outbound)["event"], "third");
        assert!(stream.is_open());
        worker.join().unwrap();
    }

    #[test]
    fn backpressured_stream_unblocks_when_the_connection_closes() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
        writer.send_stream(&json!({"event": "first"}), &stream).unwrap();
        writer.send_stream(&json!({"event": "second"}), &stream).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let waiting_writer = writer;
        let waiting_stream = stream;
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            done_tx
                .send(
                    waiting_writer
                        .send_stream_backpressured(&json!({"event": "third"}), &waiting_stream),
                )
                .unwrap();
        });

        started_rx.recv().unwrap();
        assert!(done_rx.recv_timeout(Duration::from_millis(20)).is_err());
        outbound.close();
        let error = done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
        worker.join().unwrap();
    }

    #[test]
    fn bounded_writer_rejects_payloads_beyond_each_byte_budget() {
        let outbound = BoundedOutbound::default();
        let service = RenderService::new_with_outbound_budget(
            OUTBOUND_GLOBAL_BYTE_CAPACITY.saturating_mul(2),
        );
        let stream =
            OutboundStream::new(1, service.serialize(&json!({"event": "overflow"})).unwrap());

        let regular_text = service.serialize(&"x".repeat(OUTBOUND_BYTE_CAPACITY + 1)).unwrap();
        let regular = outbound.push_regular(regular_text, &stream).unwrap_err();
        assert_eq!(regular.kind(), std::io::ErrorKind::WouldBlock);
        let control_text =
            service.serialize_control(&"x".repeat(OUTBOUND_CONTROL_BYTE_RESERVE + 1)).unwrap();
        let control = outbound.push_control(control_text).unwrap_err();
        assert_eq!(control.kind(), std::io::ErrorKind::WouldBlock);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        assert_eq!(outbound.try_pop(), None);
    }

    #[derive(Default)]
    struct FlushRecordingWriter {
        bytes: Vec<u8>,
        flushes: usize,
    }

    #[test]
    fn timed_out_control_flush_discards_the_pending_response() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(TimedOutFlushSink { outbound: outbound.clone() });
        writer.send_control(&json!({"ok": true})).unwrap();

        let error = writer.flush_control(Duration::from_secs(1)).unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(!writer.is_open());
        assert_eq!(outbound.try_pop(), None);
    }

    impl Write for FlushRecordingWriter {
        fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
            self.bytes.extend_from_slice(buffer);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.flushes += 1;
            Ok(())
        }
    }

    #[test]
    fn control_flush_waits_for_the_line_writer_flush() {
        let outbound = Arc::new(BoundedOutbound::default());
        let response = RenderService::new().serialize_control(&json!({"ok": true})).unwrap();
        outbound.push_control(response.clone()).unwrap();
        let waiting = outbound.clone();
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            done_tx.send(waiting.flush_control(Duration::from_secs(5))).unwrap();
        });
        let mut writer = FlushRecordingWriter::default();

        write_line_outbound_item(&mut writer, outbound.recv().unwrap()).unwrap();
        assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));
        write_line_outbound_item(&mut writer, outbound.recv().unwrap()).unwrap();

        done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        worker.join().unwrap();
        let mut expected = response.as_bytes().to_vec();
        expected.push(b'\n');
        assert_eq!(writer.bytes, expected);
        assert_eq!(writer.flushes, 1);
    }

    #[test]
    fn control_flush_waits_until_the_prior_control_message_leaves_the_queue() {
        let outbound = Arc::new(BoundedOutbound::default());
        let service = RenderService::new();
        let response = service.serialize_control(&json!({"ok": true})).unwrap();
        outbound.push_control(response.clone()).unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);
        let waiting = outbound.clone();
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            done_tx.send(waiting.flush_control(Duration::from_secs(5))).unwrap();
        });

        started_rx.recv().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let flush_is_queued = outbound
                .state
                .lock()
                .unwrap()
                .control
                .iter()
                .any(|item| matches!(item, ControlOutbound::Flush(_)));
            if flush_is_queued {
                break;
            }
            assert!(Instant::now() < deadline, "flush barrier was not queued");
            std::thread::yield_now();
        }
        assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(outbound.try_pop().unwrap(), response.to_string());
        assert!(matches!(done_rx.try_recv(), Err(TryRecvError::Empty)));

        assert_eq!(outbound.try_pop(), None);
        done_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        worker.join().unwrap();
    }

    #[test]
    fn terminal_overflow_purges_only_its_stream_and_rejects_late_frames() {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stale = writer.start_stream(&subscription_overflow_json()).unwrap();
        let unrelated = writer.start_stream(&subscription_overflow_json()).unwrap();

        writer.send_stream(&json!({"event": "output", "stream": "stale"}), &stale).unwrap();
        writer.send_stream(&json!({"event": "output", "stream": "unrelated"}), &unrelated).unwrap();
        writer.send_terminal(&subscription_overflow_json(), &stale).unwrap();

        let late = writer.send_stream(&json!({"event": "output", "stream": "late"}), &stale);
        assert_eq!(late.unwrap_err().kind(), std::io::ErrorKind::BrokenPipe);
        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal["event"], "overflow");
        let remaining: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(remaining["stream"], "unrelated");
        assert_eq!(outbound.try_pop(), None);
        assert!(writer.is_open());
    }

    #[test]
    fn client_detach_purges_attach_backlog_before_terminal_event() {
        let mux = Mux::new("detach-order-test", SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let stream = writer.start_stream(&attach_overflow_json(41)).unwrap();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        mux.control_clients.attach_surface(client, 41, stream.clone()).unwrap();
        mux.control_clients.commit_surface(client, 41, stream.id, None).unwrap();
        writer.send_initial(&json!({"event": "vt-state", "surface": 41}), &stream).unwrap();
        writer.send_stream(&json!({"event": "output", "surface": 41}), &stream).unwrap();

        assert!(disconnect_client(&mux, client, true));

        let terminal: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(terminal, json!({"event": "detached", "surface": 41}));
        assert_eq!(outbound.try_pop(), None);
    }

    #[test]
    fn self_detach_responds_before_closing_and_releases_the_size_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();
        let attached_stream = writer.start_stream(&json!({"event": "attach-overflow"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, attached_stream.clone()).unwrap();
        mux.control_clients.commit_surface(client, surface.id, attached_stream.id, None).unwrap();
        let subscription_stream =
            writer.start_stream(&json!({"event": "subscription-overflow"})).unwrap();
        writer.send_stream(&json!({"event": "stale-subscription"}), &subscription_stream).unwrap();
        mux.resize_surface_for_client(surface.id, client, 80, 24).unwrap();

        assert!(!handle_message(
            &mux,
            client,
            &json!({"id": 9, "cmd": "detach-client", "client": client}).to_string(),
            &writer,
        ));

        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 9);
        assert_eq!(response["ok"], true);
        let detached: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(detached, json!({"event": "detached", "surface": surface.id}));
        assert_eq!(outbound.try_pop(), None, "stream data followed the terminal detach marker");
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(mux.control_clients_json(client).as_array().unwrap().is_empty());
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientDetached(id)) if id == client
        )));
        assert!(mux.surface(surface.id).is_some(), "the session must survive its last viewer");
    }

    #[test]
    fn peer_detach_is_id_stable_and_does_not_disconnect_the_initiator() {
        let mux = test_mux();
        let initiator_writer = test_writer();
        let target_writer = test_writer();
        let initiator =
            mux.control_clients.register(ClientTransport::Unix, initiator_writer.clone());
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer);

        handle_command(
            &mux,
            initiator,
            Command::DetachClient { client: target },
            &initiator_writer,
        )
        .unwrap();

        let listed =
            handle_command(&mux, initiator, Command::ListClients, &initiator_writer).unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0]["client"], initiator);
        let error = handle_command(
            &mux,
            initiator,
            Command::DetachClient { client: target },
            &initiator_writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains(&format!("unknown client {target}")));
    }

    #[test]
    fn remote_client_cannot_detach_synthetic_local_client_zero() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let error =
            handle_command(&mux, client, Command::DetachClient { client: 0 }, &writer).unwrap_err();

        assert!(error.to_string().contains("unknown client 0"));
        assert!(
            mux.control_clients_json(client)
                .as_array()
                .unwrap()
                .iter()
                .any(|info| { info["client"] == client })
        );
    }

    #[test]
    fn websocket_direct_writer_emits_a_tungstenite_compatible_text_frame() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        let mut writer = SynchronizedTcpStream::new(server);
        let write = std::thread::spawn(move || {
            writer.write_websocket_text(&"x".repeat(65_536)).unwrap();
        });
        let mut websocket =
            WebSocket::from_raw_socket(client, tungstenite::protocol::Role::Client, None);

        let message = websocket.read().unwrap();

        assert_eq!(message.into_text().unwrap().len(), 65_536);
        write.join().unwrap();
    }

    #[test]
    fn closing_bounded_writer_wakes_a_waiting_drain() {
        let outbound = Arc::new(BoundedOutbound::default());
        let waiting = outbound.clone();
        let drain = std::thread::spawn(move || waiting.recv());

        outbound.close();

        assert!(drain.join().unwrap().is_none());
    }

    #[test]
    fn websocket_overflow_marks_attach_lifecycle() {
        let lifecycle = AttachLifecycle::default();
        let error = std::io::Error::new(std::io::ErrorKind::WouldBlock, "queue full");

        handle_attach_send_error(&lifecycle, &error);

        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());
    }

    #[test]
    fn identify_and_ping_return_build_metadata() {
        let mux = test_mux();
        let identity = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();
        assert_eq!(identity["app"].as_str(), Some("cmux-tui"));
        assert_eq!(identity["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(identity["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
        assert_eq!(identity["build_commit"].as_str(), stamped_build_commit());
        assert_eq!(identity["ghostty_commit"].as_str(), stamped_ghostty_commit());

        let data = handle_command(&mux, 0, Command::Ping, &test_writer()).unwrap();
        assert_eq!(data["ok"].as_bool(), Some(true));
        assert_eq!(data["version"].as_str(), Some(env!("CARGO_PKG_VERSION")));
        assert_eq!(data["build_commit"].as_str(), stamped_build_commit());
        assert_eq!(data["ghostty_commit"].as_str(), stamped_ghostty_commit());
        assert_eq!(data["protocol"].as_u64(), Some(PROTOCOL_VERSION as u64));
        assert_eq!(identity["daemon_handoff"].as_u64(), Some(1));
        assert!(
            identity["capabilities"].as_array().is_some_and(|capabilities| capabilities
                .iter()
                .any(|capability| capability == DAEMON_HANDOFF_FORCE_CAPABILITY)),
            "the server must advertise forced fenced daemon handoff"
        );
        assert_eq!(STABLE_SPLIT_IDS_PROTOCOL_VERSION, 8);
        assert_eq!(STACK_LAYOUT_PROTOCOL_VERSION, 9);
        assert_eq!(PER_SURFACE_CLIENT_SIZING_PROTOCOL_VERSION, 10);
        assert_eq!(TERMINAL_LIFECYCLE_PROTOCOL_VERSION, 11);
        assert_eq!(LIFECYCLE_READINESS_PROTOCOL_VERSION, 12);
        assert_eq!(PROTOCOL_VERSION, 12);
        assert!(
            identity["capabilities"].as_array().is_some_and(|capabilities| capabilities
                .iter()
                .any(|capability| capability == "browser-pointer-frame-guard-v1")),
            "the server must advertise guarded browser pointer input"
        );
    }

    #[test]
    fn lifecycle_ready_identity_advertises_new_public_protocol() {
        let mux = test_mux();
        mux.mark_server_lifecycle_ready();
        let identity = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();

        assert_eq!(identity["lifecycle_ready"], true);
        assert_eq!(identity["protocol"].as_u64(), Some(12));
        assert_eq!(
            identity["protocol"].as_u64(),
            Some(u64::from(TERMINAL_LIFECYCLE_PROTOCOL_VERSION) + 1)
        );
    }

    #[test]
    fn raw_report_agent_command_commits_public_revision_projection_and_event() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let revision = mux.with_state(|state| state.resource_revision);
        let epoch = mux.resource_event_epoch();

        let result = handle_command(
            &mux,
            0,
            Command::ReportAgent {
                surface: surface.id,
                state: "working".into(),
                source: "socket".into(),
                session: Some("raw-command".into()),
            },
            &test_writer(),
        )
        .unwrap();

        assert_eq!(result["surface"], surface.id);
        assert_eq!(result["state"], "working");
        assert_eq!(result["source"], "socket");
        assert_eq!(result["session"], "raw-command");
        assert_eq!(mux.with_state(|state| state.resource_revision), revision + 1);
        assert_eq!(mux.resource_event_epoch(), epoch + 1);
        assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
        let events = mux.resource_events_after(revision).unwrap();
        assert_eq!(events.batches.len(), 1);
        assert_eq!(events.batches[0].changes[0]["resource"], "agent");
        assert_eq!(events.batches[0].changes[0]["value"]["source_session"], "raw-command");
    }

    #[test]
    fn guarded_browser_pointer_commands_require_a_numeric_frame_guard() {
        for cmd in ["browser-mouse-guarded", "browser-wheel-guarded"] {
            let mut request = json!({
                "id": 1,
                "cmd": cmd,
                "surface": 7,
                "x_px": 1.0,
                "y_px": 2.0,
                "frame_seq": 9,
            });
            if cmd.starts_with("browser-mouse") {
                request["kind"] = json!("down");
            } else {
                request["delta_y_px"] = json!(3.0);
            }
            assert!(
                serde_json::from_value::<Request>(request.clone()).is_ok(),
                "{cmd} must accept a numeric frame guard"
            );

            request.as_object_mut().unwrap().remove("frame_seq");
            assert!(
                serde_json::from_value::<Request>(request.clone()).is_err(),
                "{cmd} must reject a missing frame guard"
            );

            request["frame_seq"] = Value::Null;
            assert!(
                serde_json::from_value::<Request>(request).is_err(),
                "{cmd} must reject a null frame guard"
            );
        }
    }

    #[test]
    fn legacy_browser_pointer_schema_remains_compatible() {
        for cmd in ["browser-mouse", "browser-wheel"] {
            let mut request = json!({
                "id": 1,
                "cmd": cmd,
                "surface": 7,
                "x_px": 1.0,
                "y_px": 2.0,
            });
            if cmd == "browser-mouse" {
                request["kind"] = json!("down");
            } else {
                request["delta_y_px"] = json!(3.0);
            }
            assert!(
                serde_json::from_value::<Request>(request.clone()).is_ok(),
                "{cmd} must keep accepting the protocol-10 legacy schema"
            );

            request["frame_seq"] = Value::Null;
            assert!(
                serde_json::from_value::<Request>(request).is_ok(),
                "{cmd} must keep accepting a legacy null frame guard"
            );
        }
    }

    #[test]
    fn browser_frame_presentation_requires_a_numeric_guard_and_capability() {
        let request = json!({
            "id": 1,
            "cmd": "browser-frame-presented",
            "surface": 7,
            "frame_seq": 9,
        });
        assert!(serde_json::from_value::<Request>(request.clone()).is_ok());
        let mut missing_guard = request.clone();
        missing_guard.as_object_mut().unwrap().remove("frame_seq");
        assert!(serde_json::from_value::<Request>(missing_guard).is_err());
        let mut null_guard = request;
        null_guard["frame_seq"] = Value::Null;
        assert!(serde_json::from_value::<Request>(null_guard).is_err());

        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let error = handle_command(
            &mux,
            client,
            Command::BrowserFramePresented { surface: 99_999, frame_seq: 9 },
            &writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains(GUARDED_BROWSER_POINTER_CAPABILITY));
    }

    #[test]
    fn parsed_legacy_browser_pointer_still_requires_frame_authority() {
        for cmd in ["browser-mouse", "browser-wheel"] {
            let mut request = json!({
                "id": 1,
                "cmd": cmd,
                "surface": 7,
                "x_px": 1.0,
                "y_px": 2.0,
            });
            if cmd == "browser-mouse" {
                request["kind"] = json!("down");
            } else {
                request["delta_y_px"] = json!(3.0);
            }
            request["frame_seq"] = Value::Null;
            let request =
                serde_json::from_value::<Request>(request).expect("legacy schema must parse");
            let mux = test_mux();
            let writer = test_writer();
            let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
            assert!(handle_message(
                &mux,
                client,
                &json!({
                    "id": 1,
                    "cmd": "set-client-info",
                    "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
                })
                .to_string(),
                &writer,
            ));
            let error = handle_command(&mux, client, request.cmd, &writer).unwrap_err().to_string();
            assert!(
                error.contains("requires a frame guard"),
                "{cmd} with a null frame_seq must fail closed before surface lookup: {error}"
            );
        }
    }

    #[test]
    fn guarded_browser_capability_and_pointer_owner_are_connection_stable() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        assert!(
            !mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY)
        );
        assert!(handle_message(
            &mux,
            client,
            &json!({
                "id": 1,
                "cmd": "set-client-info",
                "kind": "tui",
                "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
            })
            .to_string(),
            &writer,
        ));
        assert!(
            mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY)
        );
        assert_eq!(
            mux.control_clients.browser_pointer_owner(client).unwrap(),
            BrowserPointerOwner::Client(client)
        );
        assert!(handle_message(
            &mux,
            client,
            &json!({
                "id": 2,
                "cmd": "set-client-info",
                "capabilities": [],
            })
            .to_string(),
            &writer,
        ));
        assert!(
            mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY),
            "connection-scoped pointer capability must not be withdrawn after admission"
        );
        assert_eq!(
            mux.control_clients.browser_pointer_owner(client).unwrap(),
            BrowserPointerOwner::Client(client),
            "metadata replacement must not change an already claimed pointer owner"
        );

        let legacy = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        assert_eq!(
            mux.control_clients.browser_pointer_owner(legacy).unwrap(),
            BrowserPointerOwner::Legacy
        );
        assert!(handle_message(
            &mux,
            legacy,
            &json!({
                "id": 3,
                "cmd": "set-client-info",
                "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
            })
            .to_string(),
            &writer,
        ));
        assert_eq!(
            mux.control_clients.browser_pointer_owner(legacy).unwrap(),
            BrowserPointerOwner::Legacy,
            "a connection cannot change pointer identity after its first pointer command"
        );
    }

    #[test]
    fn guarded_browser_attach_rejects_a_late_capability_upgrade() {
        let mux = test_mux();
        let writer = test_writer();
        let surface = mux.new_browser_tab("about:blank".to_string(), None, Some((80, 24))).unwrap();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        assert_eq!(
            mux.control_clients.browser_pointer_owner(client).unwrap(),
            BrowserPointerOwner::Legacy
        );
        assert!(handle_message(
            &mux,
            client,
            &json!({
                "id": 1,
                "cmd": "set-client-info",
                "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY],
            })
            .to_string(),
            &writer,
        ));

        let attach = handle_command(
            &mux,
            client,
            Command::AttachSurface { surface: surface.id, mode: None, cols: None, rows: None },
            &writer,
        );
        mux.shutdown();

        let error = attach.expect_err("a legacy pointer owner must not gain a guarded attach");
        assert!(
            error.to_string().contains(GUARDED_BROWSER_POINTER_CAPABILITY),
            "late capability upgrade must return the guarded-pointer admission error: {error:#}"
        );
    }

    #[test]
    fn split_ids_serialize_stably_and_both_ratio_commands_work() {
        let mux = test_mux();
        let first = mux.new_workspace(None, None).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.split(first_pane, SplitDir::Right, None).unwrap();
        let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());

        let before = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        let split = before["workspaces"][0]["screens"][0]["layout"]["split"]
            .as_u64()
            .expect("protocol v8 split id");

        let request: Request = serde_json::from_value(json!({
            "id": 1,
            "cmd": "set-split-ratio",
            "split": split,
            "ratio": 0.7
        }))
        .unwrap();
        handle_command(&mux, 0, request.cmd, &test_writer()).unwrap();
        let after_exact = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        assert_eq!(after_exact["workspaces"][0]["screens"][0]["layout"]["split"], split);
        let exact_ratio = after_exact["workspaces"][0]["screens"][0]["layout"]["ratio"]
            .as_f64()
            .expect("split ratio");
        assert!((exact_ratio - 0.7).abs() < 1e-6);

        let legacy: Request = serde_json::from_value(json!({
            "id": 2,
            "cmd": "set-ratio",
            "pane": second_pane,
            "dir": "right",
            "ratio": 0.3
        }))
        .unwrap();
        handle_command(&mux, 0, legacy.cmd, &test_writer()).unwrap();
        let after_legacy =
            handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();
        assert_eq!(after_legacy["workspaces"][0]["screens"][0]["layout"]["split"], split);
        let legacy_ratio = after_legacy["workspaces"][0]["screens"][0]["layout"]["ratio"]
            .as_f64()
            .expect("split ratio");
        assert!((legacy_ratio - 0.3).abs() < 1e-6);

        let unknown: Request = serde_json::from_value(json!({
            "cmd": "set-split-ratio",
            "split": 999999,
            "ratio": 0.5
        }))
        .unwrap();
        assert_eq!(
            handle_command(&mux, 0, unknown.cmd, &test_writer()).unwrap_err().to_string(),
            "unknown split 999999"
        );
    }

    #[test]
    fn workspace_tree_exposes_stable_resource_ids_for_startup_attach_and_receipts() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, None).unwrap();
        let expected = match &surface.resource_identity().unwrap().content_id {
            ContentPublicId::Terminal(id) => id.as_str(),
            ContentPublicId::Browser(_) => panic!("workspace started with a browser"),
        };

        let tree = handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap();

        for (path, prefix) in [
            (&tree["workspaces"][0]["resource_id"], "ws_"),
            (&tree["workspaces"][0]["screens"][0]["resource_id"], "screen_"),
            (&tree["workspaces"][0]["screens"][0]["panes"][0]["resource_id"], "pane_"),
        ] {
            assert!(path.as_str().is_some_and(|id| id.starts_with(prefix)));
        }
        assert_eq!(
            tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["terminal_resource_id"],
            expected
        );
        mux.shutdown();
    }

    #[test]
    fn projected_split_ratio_range_failure_is_not_reported_as_unknown() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
        let split =
            handle_command(&mux, 0, Command::ListWorkspaces, &test_writer()).unwrap()["workspaces"]
                [0]["screens"][0]["layout"]["split"]
                .as_u64()
                .expect("viewport projection exposes a stable split");
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });

        handle_message(
            &mux,
            7,
            &json!({
                "id": 21,
                "cmd": "set-split-ratio",
                "split": split,
                "ratio": 0.25
            })
            .to_string(),
            &writer,
        );

        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 21);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error_code"], LayoutRatioError::OUT_OF_RANGE_CODE);
        assert!(response["error"].as_str().unwrap().contains("width must be between"));
        assert!(!response["error"].as_str().unwrap().contains("unknown split"));
    }

    #[test]
    fn viewport_width_failures_have_stable_error_codes() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });

        for (id, width, code) in [
            (31, 0.5, ViewportWidthError::COLUMN_MISSING_CODE),
            (32, 1.1, ViewportWidthError::OUT_OF_RANGE_CODE),
        ] {
            handle_message(
                &mux,
                7,
                &json!({
                    "id": id,
                    "cmd": "set-viewport-pane-width",
                    "pane": pane,
                    "width": width
                })
                .to_string(),
                &writer,
            );
            let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
            assert_eq!(response["id"], id);
            assert_eq!(response["ok"], false);
            assert_eq!(response["error_code"], code);
        }

        handle_message(
            &mux,
            7,
            &json!({
                "id": 33,
                "cmd": "new-pane-right",
                "pane": pane,
                "width": 1.1
            })
            .to_string(),
            &writer,
        );
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 33);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error_code"], ViewportWidthError::OUT_OF_RANGE_CODE);
    }

    #[test]
    fn create_terminal_rejects_partial_dimensions() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;

        for (cols, rows) in [(Some(80), None), (None, Some(24))] {
            let error = handle_command(
                &mux,
                0,
                Command::CreateTerminal {
                    workspace: Some(workspace),
                    key: None,
                    argv: None,
                    command: None,
                    cwd: None,
                    name: None,
                    cols,
                    rows,
                    terminal_id: None,
                    mutation: MutationRequest::default(),
                },
                &test_writer(),
            )
            .unwrap_err();

            assert_eq!(
                error.to_string(),
                "create-terminal cols and rows must be supplied together"
            );
        }
    }

    #[test]
    fn mutation_specific_raw_terminal_create_updates_public_projection_once() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;
        let command = || Command::CreateTerminal {
            workspace: Some(workspace),
            key: None,
            argv: None,
            command: None,
            cwd: None,
            name: Some("raw terminal".to_string()),
            cols: Some(80),
            rows: Some(24),
            terminal_id: Some("00000000000040008000000000000001".to_string()),
            mutation: MutationRequest {
                origin: Some("raw-projection-test".to_string()),
                mutation_id: Some("raw-terminal-create-once".to_string()),
                expected_generation: None,
                expected_revision: None,
            },
        };

        let first = handle_command(&mux, 0, command(), &test_writer()).unwrap();
        assert_eq!(first["replayed"], false);
        let first_snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
        assert_eq!(first_snapshot["screens"].as_array().unwrap().len(), 1);
        assert_eq!(first_snapshot["panes"].as_array().unwrap().len(), 1);
        assert_eq!(first_snapshot["tabs"].as_array().unwrap().len(), 1);
        assert_eq!(first_snapshot["terminals"].as_array().unwrap().len(), 1);
        assert_eq!(first_snapshot["tabs"][0]["content_id"], first_snapshot["terminals"][0]["id"]);
        let first_revision = first_snapshot["cursor"]["revision"].clone();

        let replay = handle_command(&mux, 0, command(), &test_writer()).unwrap();
        assert_eq!(replay["replayed"], true);
        let replayed_snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
        assert_eq!(replayed_snapshot["cursor"]["revision"], first_revision);
        assert_eq!(replayed_snapshot["terminals"].as_array().unwrap().len(), 1);
        mux.shutdown();
    }

    #[test]
    fn creation_receipts_replay_exact_surfaces_across_control_connections() {
        let mux = test_mux();
        let original = mux.new_workspace(None, Some((100, 30))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(original.id).unwrap());
        let selectors = mux.resource_selectors_for_pane(Some(pane)).unwrap();
        let receipt = "split-receipt-00000001";
        let origin = "tui-receipt-test";
        let command = |direction: &str, idempotency_key: &str| {
            Command::CreateSurfaceWithReceipt(Box::new(CreateSurfaceWithReceiptRequest {
                operation: format!("split-{direction}"),
                origin: origin.to_string(),
                receipt: receipt.to_string(),
                idempotency_key: Some(idempotency_key.to_string()),
                selectors: Some(selectors.clone()),
                selector_fallbacks: Vec::new(),
                pane: Some(pane),
                workspace: None,
                argv: None,
                cwd: None,
                url: None,
                width: None,
                cols: Some(100),
                rows: Some(30),
            }))
        };
        let register = |writer: &MessageWriter, attempt_keys: bool| {
            let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
            let mut capabilities = vec![CREATION_RECEIPTS_CAPABILITY.to_string()];
            if attempt_keys {
                capabilities.push(CREATION_ATTEMPT_KEYS_CAPABILITY.to_string());
            }
            handle_command(
                &mux,
                client,
                Command::SetClientInfo {
                    name: Some("receipt test".to_string()),
                    kind: Some("tui".to_string()),
                    capabilities: Some(capabilities),
                },
                writer,
            )
            .unwrap();
            client
        };

        let legacy_writer = test_writer();
        let legacy_client = register(&legacy_writer, false);
        let capability_error = handle_command(
            &mux,
            legacy_client,
            command("right", "split-attempt-unsupported"),
            &legacy_writer,
        )
        .unwrap_err();
        assert!(capability_error.to_string().contains(CREATION_ATTEMPT_KEYS_CAPABILITY));
        assert!(disconnect_client(&mux, legacy_client, true));

        let first_writer = test_writer();
        let first_client = register(&first_writer, true);
        let first = handle_command(
            &mux,
            first_client,
            command("right", "split-attempt-00000001"),
            &first_writer,
        )
        .unwrap();
        assert_eq!(first["replayed"], false);
        let created = first["surface"].as_u64().expect("creation omitted its surface");
        let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
        assert_eq!(snapshot["panes"].as_array().unwrap().len(), 2);

        let replay = handle_command(
            &mux,
            first_client,
            command("right", "split-attempt-00000001"),
            &first_writer,
        )
        .unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["surface"].as_u64(), Some(created));
        assert_eq!(
            crate::resource_api::public_session_snapshot(&mux).unwrap()["panes"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(mux.close_pane(pane).unwrap());
        assert!(mux.with_state(|state| state.pane_of(created).is_some()));
        assert!(disconnect_client(&mux, first_client, true));

        let second_writer = test_writer();
        let second_client = register(&second_writer, true);
        let reconnect_replay = handle_command(
            &mux,
            second_client,
            command("right", "split-attempt-00000002"),
            &second_writer,
        )
        .unwrap();
        assert_eq!(reconnect_replay["replayed"], true);
        assert_eq!(reconnect_replay["surface"].as_u64(), Some(created));

        let conflict = handle_command(
            &mux,
            second_client,
            command("down", "split-attempt-00000003"),
            &second_writer,
        )
        .unwrap_err();
        assert!(
            conflict.to_string().contains("bound to different semantics"),
            "unexpected receipt conflict: {conflict:#}"
        );
        assert_eq!(
            crate::resource_api::public_session_snapshot(&mux).unwrap()["panes"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(disconnect_client(&mux, second_client, true));
        mux.shutdown();
    }

    #[test]
    fn browser_receipt_targets_an_exact_empty_workspace_without_focus_state() {
        let mux = test_mux();
        let workspace = mux.create_empty_workspace(None, None, None).unwrap().workspace;
        let selectors = mux.resource_selectors_for_workspace(Some(workspace)).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("native browser bootstrap".to_string()),
                kind: Some("native-browser".to_string()),
                capabilities: Some(vec![CREATION_RECEIPTS_CAPABILITY.to_string()]),
            },
            &writer,
        )
        .unwrap();
        let command = || {
            Command::CreateSurfaceWithReceipt(Box::new(CreateSurfaceWithReceiptRequest {
                operation: "new-browser-tab".to_string(),
                origin: "native-browser-bootstrap-test".to_string(),
                receipt: "browser-workspace-receipt-00000001".to_string(),
                idempotency_key: None,
                selectors: Some(selectors.clone()),
                selector_fallbacks: Vec::new(),
                pane: None,
                workspace: None,
                argv: None,
                cwd: None,
                url: Some("about:blank".to_string()),
                width: None,
                cols: None,
                rows: None,
            }))
        };

        let first = handle_command(&mux, client, command(), &writer).unwrap();
        assert_eq!(first["replayed"], false);
        let surface = first["surface"].as_u64().expect("creation omitted its surface");
        let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
        assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["screens"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["panes"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["tabs"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["tabs"][0]["content_kind"], "browser");

        let replay = handle_command(&mux, client, command(), &writer).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["surface"].as_u64(), Some(surface));
        assert_eq!(
            crate::resource_api::public_session_snapshot(&mux).unwrap()["tabs"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        mux.close_surface(surface).unwrap();
        mux.shutdown();
    }

    #[test]
    fn creation_selector_fallbacks_are_negotiated_atomic_and_durably_replayed() {
        let mux = test_mux();
        let fallback = mux.new_workspace(None, Some((100, 30))).unwrap();
        let fallback_pane = mux.with_state(|state| state.pane_of(fallback.id).unwrap());
        let primary = mux.split(fallback_pane, SplitDir::Right, Some((50, 30))).unwrap();
        let primary_pane = mux.with_state(|state| state.pane_of(primary.id).unwrap());
        let primary_selectors = mux.resource_selectors_for_pane(Some(primary_pane)).unwrap();
        let fallback_selectors = mux.resource_selectors_for_pane(Some(fallback_pane)).unwrap();
        assert!(mux.close_pane(primary_pane).unwrap());

        let command = || {
            Command::CreateSurfaceWithReceipt(Box::new(CreateSurfaceWithReceiptRequest {
                operation: "split-right".to_string(),
                origin: "tui-fallback-test".to_string(),
                receipt: "split-fallback-receipt-00000001".to_string(),
                idempotency_key: None,
                selectors: Some(primary_selectors.clone()),
                selector_fallbacks: vec![fallback_selectors.clone()],
                pane: Some(primary_pane),
                workspace: None,
                argv: None,
                cwd: None,
                url: None,
                width: None,
                cols: Some(50),
                rows: Some(30),
            }))
        };
        let register = |capabilities: &[&str], writer: &MessageWriter| {
            let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
            handle_command(
                &mux,
                client,
                Command::SetClientInfo {
                    name: Some("fallback receipt test".to_string()),
                    kind: Some("tui".to_string()),
                    capabilities: Some(
                        capabilities.iter().map(|capability| (*capability).to_string()).collect(),
                    ),
                },
                writer,
            )
            .unwrap();
            client
        };

        let old_writer = test_writer();
        let old_client = register(&[CREATION_RECEIPTS_CAPABILITY], &old_writer);
        let error = handle_command(&mux, old_client, command(), &old_writer).unwrap_err();
        assert!(error.to_string().contains(CREATION_SELECTOR_FALLBACKS_CAPABILITY));
        assert!(disconnect_client(&mux, old_client, true));

        let first_writer = test_writer();
        let first_client = register(
            &[CREATION_RECEIPTS_CAPABILITY, CREATION_SELECTOR_FALLBACKS_CAPABILITY],
            &first_writer,
        );
        let first = handle_command(&mux, first_client, command(), &first_writer).unwrap();
        assert_eq!(first["replayed"], false);
        let created = first["surface"].as_u64().expect("creation omitted its surface");
        assert!(mux.with_state(|state| state.pane_of(created).is_some()));
        assert!(mux.close_pane(fallback_pane).unwrap());
        assert!(disconnect_client(&mux, first_client, true));

        let replay_writer = test_writer();
        let replay_client = register(
            &[CREATION_RECEIPTS_CAPABILITY, CREATION_SELECTOR_FALLBACKS_CAPABILITY],
            &replay_writer,
        );
        let replay = handle_command(&mux, replay_client, command(), &replay_writer).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["surface"].as_u64(), Some(created));
        assert!(disconnect_client(&mux, replay_client, true));
        mux.close_surface(created).unwrap();
        mux.shutdown();
    }

    #[test]
    fn attached_terminal_resizes_are_view_local_until_geometry_is_claimed() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

        let first_writer = test_writer();
        let first_stream = first_writer.start_stream(&attach_overflow_json(surface.id)).unwrap();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        mux.control_clients.attach_surface(first, surface.id, first_stream.clone()).unwrap();
        mux.control_clients.commit_surface(first, surface.id, first_stream.id, None).unwrap();

        let second_writer = test_writer();
        let second_stream = second_writer.start_stream(&attach_overflow_json(surface.id)).unwrap();
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        mux.control_clients.attach_surface(second, surface.id, second_stream.clone()).unwrap();
        mux.control_clients.commit_surface(second, surface.id, second_stream.id, None).unwrap();

        let first_result = handle_command(
            &mux,
            first,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 30 },
            &first_writer,
        )
        .unwrap();
        assert_eq!(first_result["accepted"].as_bool(), Some(false));
        assert_eq!(surface.size(), (80, 24));

        let second_result = handle_command(
            &mux,
            second,
            Command::ResizeSurface { surface: surface.id, cols: 132, rows: 44 },
            &second_writer,
        )
        .unwrap();
        assert_eq!(second_result["accepted"].as_bool(), Some(false));
        assert_eq!(surface.size(), (80, 24));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(first),
                enabled: true,
                exclusive: true,
            },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 30));
        assert!(mux.client_size_participates(surface.id, first));
        assert!(!mux.client_size_participates(surface.id, second));

        let clients = mux.control_clients.list_json(first);
        let clients = clients.as_array().unwrap();
        let recorded_size = |client: u64| {
            let record =
                clients.iter().find(|record| record["client"].as_u64() == Some(client)).unwrap();
            let size = record["sizes"].as_array().unwrap().first().unwrap();
            (size["cols"].as_u64().unwrap(), size["rows"].as_u64().unwrap())
        };
        assert_eq!(recorded_size(first), (100, 30));
        assert_eq!(recorded_size(second), (132, 44));
    }

    #[test]
    fn resize_after_attached_surface_close_is_superseded() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let surface_id = surface.id;
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&attach_overflow_json(surface_id)).unwrap();
        mux.control_clients.attach_surface(client, surface_id, stream.clone()).unwrap();
        mux.control_clients.commit_surface(client, surface_id, stream.id, None).unwrap();

        mux.close_surface(surface_id).unwrap();
        let response = handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface_id, cols: 100, rows: 30 },
            &writer,
        )
        .expect("a late resize from a retired attachment is not an unknown-surface error");

        assert_eq!(response["outcome"], "superseded");
        assert_eq!(response["accepted"], false);
        mux.shutdown();
    }

    #[test]
    fn daemon_shutdown_is_local_fenced_and_queues_ack_first() {
        let rejected = test_mux();
        rejected.mark_server_lifecycle_ready();
        let rejected_outbound = Arc::new(BoundedOutbound::default());
        let rejected_writer =
            MessageWriter::new(QueuedSink { outbound: rejected_outbound.clone(), control: None });
        let websocket =
            rejected.control_clients.register(ClientTransport::WebSocket, rejected_writer.clone());
        let (_, generation) = rejected.registry_identity();
        assert!(handle_message(
            &rejected,
            websocket,
            &json!({
                "id": 91,
                "cmd": "shutdown-daemon",
                "pid": std::process::id(),
                "generation": generation,
            })
            .to_string(),
            &rejected_writer,
        ));
        let response: Value = serde_json::from_str(&rejected_outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["ok"], false);
        assert!(response["error"].as_str().unwrap().contains("trusted local"));
        assert!(!rejected.daemon_shutdown_requested());

        let local =
            rejected.control_clients.register(ClientTransport::Unix, rejected_writer.clone());
        assert!(handle_message(
            &rejected,
            local,
            &json!({
                "id": 92,
                "cmd": "shutdown-daemon",
                "pid": std::process::id().wrapping_add(1),
                "generation": generation,
            })
            .to_string(),
            &rejected_writer,
        ));
        let response: Value = serde_json::from_str(&rejected_outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["ok"], false);
        assert!(response["error"].as_str().unwrap().contains("pid changed"));
        assert!(!rejected.daemon_shutdown_requested());

        assert!(handle_message(
            &rejected,
            local,
            &json!({
                "id": 93,
                "cmd": "shutdown-daemon",
                "pid": std::process::id(),
                "generation": "stale-generation",
            })
            .to_string(),
            &rejected_writer,
        ));
        let response: Value = serde_json::from_str(&rejected_outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["ok"], false);
        assert!(response["error"].as_str().unwrap().contains("generation changed"));
        assert!(!rejected.daemon_shutdown_requested());

        let accepted = test_mux();
        accepted.mark_server_lifecycle_ready();
        let accepted_outbound = Arc::new(BoundedOutbound::default());
        let accepted_writer =
            MessageWriter::new(QueuedSink { outbound: accepted_outbound.clone(), control: None });
        let local =
            accepted.control_clients.register(ClientTransport::Unix, accepted_writer.clone());
        let interactive = accepted.control_clients.register(ClientTransport::Unix, test_writer());
        let (_, generation) = accepted.registry_identity();
        assert!(handle_message(
            &accepted,
            local,
            &json!({
                "id": 94,
                "cmd": "shutdown-daemon",
                "pid": std::process::id(),
                "generation": generation,
            })
            .to_string(),
            &accepted_writer,
        ));

        // `handle_message` queues this response before it flips the shutdown
        // flag, so observing the requested state implies the ACK is already
        // available to the connection's writer thread.
        assert!(accepted.daemon_shutdown_requested());
        let response: Value = serde_json::from_str(&accepted_outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["accepted"], true);
        assert_eq!(response["data"]["pid"], std::process::id());
        assert_eq!(response["data"]["generation"], generation);
        assert!(accepted.control_clients.contains(local));
        assert!(!accepted.control_clients.contains(interactive));
    }

    #[test]
    fn daemon_shutdown_waits_for_ack_flush_before_disconnecting_the_owner() {
        let mux = test_mux();
        mux.mark_server_lifecycle_ready();
        let (writer, outbound, flush_entered, release_flush) = blocking_flush_writer();
        let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let interactive = mux.control_clients.register(ClientTransport::Unix, test_writer());
        let (_, generation) = mux.registry_identity();
        let request = json!({
            "id": 97,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": generation,
        })
        .to_string();
        let worker_mux = mux.clone();
        let worker =
            std::thread::spawn(move || handle_message(&worker_mux, requester, &request, &writer));

        flush_entered
            .recv_timeout(Duration::from_secs(2))
            .expect("shutdown did not wait for the response flush");
        assert!(!mux.daemon_shutdown_requested());
        assert!(matches!(
            mux.control_clients.state.try_lock(),
            Err(std::sync::TryLockError::WouldBlock)
        ));

        release_flush.send(()).unwrap();
        assert!(worker.join().unwrap());
        assert!(mux.daemon_shutdown_requested());
        assert!(mux.control_clients.contains(requester));
        assert!(!mux.control_clients.contains(interactive));
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["accepted"], true);
    }

    #[test]
    fn shutdown_requester_waits_for_owner_eof_and_rejects_pipelined_mutations() {
        let mux = test_mux();
        mux.mark_server_lifecycle_ready();
        let (writer, outbound) = captured_writer();
        let requester = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let (_, generation) = mux.registry_identity();
        let shutdown = json!({
            "id": 98,
            "cmd": "shutdown-daemon",
            "pid": std::process::id(),
            "generation": generation,
        })
        .to_string();

        // Complete the shutdown request through the shared request handler
        // before testing the connection-level fence. The real connection
        // scheduler is asynchronous, so using it for setup would race the
        // shutdown flag that this test needs as its precondition.
        assert!(handle_message(&mux, requester, &shutdown, &writer));
        assert!(mux.daemon_shutdown_requested());
        assert!(mux.control_clients.contains(requester));
        assert!(writer.is_open());
        let response = pop_json(&outbound);
        assert_eq!(response["ok"], true);

        let workspace_count = mux.with_state(|state| state.workspaces.len());
        let pipelined = json!({
            "id": 99,
            "cmd": "new-workspace",
            "name": "must-not-exist",
        })
        .to_string();
        assert!(!handle_connection_message(&mux, requester, &pipelined, &writer, &scheduler,));
        assert_eq!(mux.with_state(|state| state.workspaces.len()), workspace_count);
        assert!(outbound.try_pop().is_none());
    }

    #[test]
    fn daemon_shutdown_force_preserves_the_identity_fence() {
        let mux = test_mux();
        mux.mark_server_lifecycle_ready();
        let owner_writer = test_writer();
        let owner = mux.control_clients.register(ClientTransport::Unix, owner_writer.clone());
        handle_command(
            &mux,
            owner,
            Command::SetClientInfo {
                name: Some("browser owner".to_string()),
                kind: Some("native-browser".to_string()),
                capabilities: None,
            },
            &owner_writer,
        )
        .unwrap();

        let (requester_writer, outbound) = captured_writer();
        let requester =
            mux.control_clients.register(ClientTransport::Unix, requester_writer.clone());
        let (_, generation) = mux.registry_identity();
        assert!(handle_message(
            &mux,
            requester,
            &json!({
                "id": 95,
                "cmd": "shutdown-daemon",
                "pid": std::process::id(),
                "generation": "stale-generation",
                "force": true,
            })
            .to_string(),
            &requester_writer,
        ));
        let rejected = pop_json(&outbound);
        assert_eq!(rejected["ok"], false);
        assert!(rejected["error"].as_str().unwrap().contains("generation changed"));
        assert!(!mux.daemon_shutdown_requested());

        assert!(handle_message(
            &mux,
            requester,
            &json!({
                "id": 96,
                "cmd": "shutdown-daemon",
                "pid": std::process::id(),
                "generation": generation,
                "force": true,
            })
            .to_string(),
            &requester_writer,
        ));
        let accepted = pop_json(&outbound);
        assert_eq!(accepted["ok"], true);
        assert!(mux.daemon_shutdown_requested());
    }

    #[test]
    fn daemon_shutdown_atomically_fences_native_browser_ownership() {
        let owned = test_mux();
        let requester_writer = test_writer();
        let owner_writer = test_writer();
        let requester =
            owned.control_clients.register(ClientTransport::Unix, requester_writer.clone());
        let owner = owned.control_clients.register(ClientTransport::Unix, owner_writer.clone());
        handle_command(
            &owned,
            owner,
            Command::SetClientInfo {
                name: Some("existing browser".to_string()),
                kind: Some("native-browser".to_string()),
                capabilities: None,
            },
            &owner_writer,
        )
        .unwrap();
        let (_, generation) = owned.registry_identity();
        let error = handle_command(
            &owned,
            requester,
            Command::ShutdownDaemon { pid: std::process::id(), generation, force: false },
            &requester_writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains("still owns"));
        assert!(!owned.daemon_shutdown_requested());

        let fenced = test_mux();
        let requester_writer = test_writer();
        let late_writer = test_writer();
        let requester =
            fenced.control_clients.register(ClientTransport::Unix, requester_writer.clone());
        let late = fenced.control_clients.register(ClientTransport::Unix, late_writer.clone());
        let (_, generation) = fenced.registry_identity();
        handle_command(
            &fenced,
            requester,
            Command::ShutdownDaemon { pid: std::process::id(), generation, force: false },
            &requester_writer,
        )
        .unwrap();
        let error = handle_command(
            &fenced,
            late,
            Command::SetClientInfo {
                name: Some("late browser".to_string()),
                kind: Some("native-browser".to_string()),
                capabilities: None,
            },
            &late_writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains("handoff is already in progress"));
    }

    #[test]
    fn daemon_handoff_rejects_clients_registered_after_the_fence() {
        let mux = test_mux();
        let requester_writer = test_writer();
        let requester = mux.control_clients.register(ClientTransport::Unix, requester_writer);
        mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();

        let late_writer = test_writer();
        let late = mux.control_clients.register(ClientTransport::Unix, late_writer.clone());

        assert!(!mux.control_clients.contains(late));
        assert!(!late_writer.is_open());

        mux.cancel_daemon_handoff(requester);
        let retry_writer = test_writer();
        let retry = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
        assert!(mux.control_clients.contains(retry));
        assert!(retry_writer.is_open());
    }

    #[test]
    fn daemon_handoff_requester_disconnect_releases_the_reservation() {
        let mux = test_mux();
        let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
        mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
        assert!(mux.control_clients.daemon_handoff_pending());

        assert!(disconnect_client(&mux, requester, false));
        assert!(!mux.control_clients.daemon_handoff_pending());

        let retry_writer = test_writer();
        let retry = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
        assert!(mux.control_clients.contains(retry));
        assert!(retry_writer.is_open());
    }

    #[test]
    fn daemon_handoff_ack_commit_holds_the_requester_removal_lock() {
        let mux = test_mux();
        let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
        mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();

        mux.commit_daemon_handoff_after_ack(requester, || {
            assert!(matches!(
                mux.control_clients.state.try_lock(),
                Err(std::sync::TryLockError::WouldBlock)
            ));
            Ok(())
        })
        .unwrap();

        assert!(disconnect_client(&mux, requester, false));
        assert!(mux.control_clients.daemon_handoff_pending());
    }

    #[test]
    fn committed_daemon_handoff_requester_disconnect_keeps_the_fence() {
        let mux = test_mux();
        let requester = mux.control_clients.register(ClientTransport::Unix, test_writer());
        mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(false)).unwrap();
        mux.commit_daemon_handoff_after_ack(requester, || Ok(())).unwrap();
        mux.request_daemon_shutdown();

        assert!(disconnect_client(&mux, requester, false));
        assert!(mux.control_clients.daemon_handoff_pending());

        let retry_writer = test_writer();
        let retry = mux.control_clients.register(ClientTransport::Unix, retry_writer.clone());
        assert!(!mux.control_clients.contains(retry));
        assert!(!retry_writer.is_open());
    }

    #[cfg(unix)]
    #[test]
    fn pane_and_screen_close_detach_views_without_closing_terminal_hosts() {
        const TERMINAL: &str = "00000000000040008000000000000012";
        const INCARNATION: &str = "10000000000040008000000000000012";
        for close_screen in [false, true] {
            let mux = test_mux();
            let workspace = mux
                .create_empty_workspace(
                    None,
                    Some("018f6e21-7b70-7e70-8000-000000001001".into()),
                    None,
                )
                .unwrap();
            let surface =
                mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
            let (pane, screen) = mux.with_state(|state| {
                let pane = state.pane_of(surface).unwrap();
                let (workspace, screen) = state.screen_of(pane).unwrap();
                (pane, state.workspaces[workspace].screens[screen].id)
            });
            mux.set_terminal_close_failure_for_test(true).unwrap();

            let command = if close_screen {
                Command::CloseScreen { screen }
            } else {
                Command::ClosePane { pane }
            };
            handle_command(&mux, 0, command, &test_writer()).unwrap();

            assert!(!mux.with_state(|state| state.surfaces.contains_key(&surface)));
            assert!(mux.surface(surface).is_some());
            assert_eq!(
                mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.lifecycle,
                TerminalLifecycle::Running
            );
            assert!(mux.close_terminal(TERMINAL, INCARNATION).is_err());

            mux.set_terminal_close_failure_for_test(false).unwrap();
            mux.close_terminal(TERMINAL, INCARNATION).unwrap();
            assert!(mux.surface(surface).is_none());
        }
    }

    #[test]
    fn client_info_is_sanitized_recallable_and_clamped_to_64_characters() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();

        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("\u{1b}]0;evil\u{07}name".to_string()),
                kind: Some("web".to_string()),
                capabilities: None,
            },
            &writer,
        )
        .unwrap();
        let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(data[0]["name"], " ]0;evil name");

        handle_command(
            &mux,
            client,
            Command::SetClientInfo { name: Some("n".repeat(80)), kind: None, capabilities: None },
            &writer,
        )
        .unwrap();
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: None,
                kind: Some("tui".to_string()),
                capabilities: None,
            },
            &writer,
        )
        .unwrap();

        let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        let listed = &data[0];
        assert_eq!(listed["name"].as_str().unwrap().chars().count(), 64);
        assert_eq!(listed["kind"], "tui");
        assert_eq!(listed["self"], true);
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "web"
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "web"
        ));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
                if id == client && kind == "tui"
        ));
    }

    #[test]
    fn client_sizing_command_updates_list_clients() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
            &writer,
        )
        .unwrap();

        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["sizes"][0]["size_participating"], false);

        handle_command(
            &mux,
            client,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(client),
                enabled: true,
                exclusive: false,
            },
            &writer,
        )
        .unwrap();
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["sizes"][0]["size_participating"], true);

        handle_command(
            &mux,
            client,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(client),
                enabled: false,
                exclusive: false,
            },
            &writer,
        )
        .unwrap();
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["sizes"][0]["size_participating"], false);
    }

    #[test]
    fn client_sizing_command_applies_exclusive_and_all_modes_atomically() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let first_writer = test_writer();
        let second_writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        for (client, writer, size) in
            [(first, &first_writer, (120, 40)), (second, &second_writer, (80, 30))]
        {
            let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
            mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
            handle_command(
                &mux,
                client,
                Command::ResizeSurface { surface: surface.id, cols: size.0, rows: size.1 },
                writer,
            )
            .unwrap();
        }
        assert_eq!(surface.size(), (120, 40));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(first),
                enabled: true,
                exclusive: true,
            },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (120, 40));
        assert!(mux.client_size_participates(surface.id, first));
        assert!(!mux.client_size_participates(surface.id, second));

        handle_command(
            &mux,
            first,
            Command::SetClientSizing {
                surface: surface.id,
                client: None,
                enabled: true,
                exclusive: false,
            },
            &first_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (120, 40));
        assert!(!mux.client_size_participates(surface.id, first));
        assert!(!mux.client_size_participates(surface.id, second));
    }

    #[test]
    fn terminal_exclusive_sizing_defaults_to_the_requesting_client() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let error = handle_command(
            &mux,
            client,
            Command::SetClientSizing {
                surface: surface.id,
                client: None,
                enabled: true,
                exclusive: true,
            },
            &writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains("reported size"));

        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        let passive = handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 90, rows: 28 },
            &writer,
        )
        .unwrap();
        assert_eq!(passive["accepted"], false);

        handle_command(
            &mux,
            client,
            Command::SetClientSizing {
                surface: surface.id,
                client: None,
                enabled: true,
                exclusive: true,
            },
            &writer,
        )
        .unwrap();
        assert!(mux.client_size_participates(surface.id, client));
        assert_eq!(surface.size(), (90, 28));
    }

    #[test]
    fn client_sizing_command_reports_unknown_surface_before_client_errors() {
        let mux = test_mux();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let missing_surface = 999_999;

        let error = handle_command(
            &mux,
            client,
            Command::SetClientSizing {
                surface: missing_surface,
                client: Some(client),
                enabled: false,
                exclusive: false,
            },
            &writer,
        )
        .unwrap_err();

        assert_eq!(error.to_string(), format!("unknown surface {missing_surface}"));
    }

    #[test]
    fn client_sizing_command_only_changes_requested_surface() {
        let mux = test_mux();
        let current = mux.new_workspace(None, Some((120, 40))).unwrap();
        let other = mux.new_workspace(None, Some((110, 35))).unwrap();
        let writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let second = mux.control_clients.register(ClientTransport::Unix, test_writer());
        let first_stream = writer.start_stream(&attach_overflow_json(current.id)).unwrap();
        mux.control_clients.attach_surface(first, current.id, first_stream.clone()).unwrap();
        mux.control_clients.commit_surface(first, current.id, first_stream.id, None).unwrap();

        mux.resize_surface_for_client(current.id, first, 100, 32).unwrap();
        mux.resize_surface_for_client(current.id, second, 80, 30).unwrap();
        mux.resize_surface_for_client(other.id, first, 90, 28).unwrap();
        mux.resize_surface_for_client(other.id, second, 70, 20).unwrap();
        assert_eq!(current.size(), (120, 40));
        assert_eq!(other.size(), (110, 35));

        let request = serde_json::from_value::<Request>(json!({
            "cmd": "set-client-sizing",
            "surface": current.id,
            "client": first,
            "enabled": true,
            "exclusive": true,
        }))
        .unwrap();
        handle_command(&mux, first, request.cmd, &writer).unwrap();

        assert_eq!(current.size(), (100, 32));
        assert_eq!(other.size(), (110, 35));
    }

    #[test]
    fn releasing_surface_size_keeps_attach_but_removes_visibility_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        let events = mux.subscribe();

        handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
            &writer,
        )
        .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
        )));

        handle_command(&mux, client, Command::ReleaseSurfaceSize { surface: surface.id }, &writer)
            .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
        assert_eq!(listed[0]["attached"], json!([surface.id]));
        assert_eq!(listed[0]["sizes"][0]["cols"], Value::Null);
        assert_eq!(listed[0]["sizes"][0]["rows"], Value::Null);
        assert!((0..4).any(|_| matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientChanged { client: id, .. }) if id == client
        )));
    }

    #[test]
    fn attached_unreported_client_suppresses_global_ignore_size_fallback() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(reporter),
                enabled: false,
                exclusive: false,
            },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 40));

        handle_command(
            &mux,
            blocker,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(blocker),
                enabled: false,
                exclusive: false,
            },
            &blocker_writer,
        )
        .unwrap();
        settle_browser_size(&surface, (70, 20));
    }

    #[test]
    fn unsized_attach_invalidates_excluded_fallback_creation_default() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "reporter"})).unwrap();
        let reporter_stream_id = reporter_stream.id;
        let reporter_attach =
            mark_client_attached(&mux, reporter, surface.id, reporter_stream, Some((70, 20)))
                .unwrap();
        settle_marked_browser_resize(&surface, &reporter_attach);
        commit_client_attach(
            &mux,
            reporter,
            surface.id,
            reporter_stream_id,
            reporter_attach.client_changed,
            reporter_attach.size_rollback,
        )
        .unwrap();
        assert_eq!(mux.set_client_size_participation(surface.id, reporter, false), Some(true));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (70, 20));

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "blocker"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        let blocker_attach =
            mark_client_attached(&mux, blocker, surface.id, blocker_stream, None).unwrap();
        commit_client_attach(
            &mux,
            blocker,
            surface.id,
            blocker_stream_id,
            blocker_attach.client_changed,
            blocker_attach.size_rollback,
        )
        .unwrap();

        mux.resize_surface_for_control_client_with_reservation(surface.id, reporter, 60, 18)
            .unwrap();

        assert_eq!(surface.size(), (70, 20));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (80, 24));
    }

    #[test]
    fn unsized_attach_preserves_newer_explicit_creation_default() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "reporter"})).unwrap();
        let reporter_stream_id = reporter_stream.id;
        let reporter_attach =
            mark_client_attached(&mux, reporter, surface.id, reporter_stream, Some((80, 24)))
                .unwrap();
        settle_marked_browser_resize(&surface, &reporter_attach);
        commit_client_attach(
            &mux,
            reporter,
            surface.id,
            reporter_stream_id,
            reporter_attach.client_changed,
            reporter_attach.size_rollback,
        )
        .unwrap();

        assert_eq!(mux.new_workspace(None, Some((120, 40))).unwrap().size(), (120, 40));

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "blocker"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        let blocker_attach =
            mark_client_attached(&mux, blocker, surface.id, blocker_stream, None).unwrap();
        commit_client_attach(
            &mux,
            blocker,
            surface.id,
            blocker_stream_id,
            blocker_attach.client_changed,
            blocker_attach.size_rollback,
        )
        .unwrap();

        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (120, 40));
    }

    #[test]
    fn final_stream_detach_restores_excluded_report_fallback() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        settle_browser_size(&surface, (70, 20));
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(reporter),
                enabled: false,
                exclusive: false,
            },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();
        mux.resize_surface(surface.id, 100, 40).unwrap();
        settle_browser_size(&surface, (100, 40));

        assert!(
            mux.control_clients.detach_surface(blocker, surface.id, blocker_stream_id).final_stream
        );
        mux.remove_surface_size_client(surface.id, blocker);

        settle_browser_size(&surface, (70, 20));
        assert!(!mux.control_clients.attached_client_ids().contains(&blocker));
    }

    #[test]
    fn final_stream_detach_of_excluded_unsized_client_preserves_newer_geometry() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        settle_browser_size(&surface, (70, 20));
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(reporter),
                enabled: false,
                exclusive: false,
            },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();
        handle_command(
            &mux,
            blocker,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(blocker),
                enabled: false,
                exclusive: false,
            },
            &blocker_writer,
        )
        .unwrap();
        mux.resize_surface(surface.id, 100, 40).unwrap();
        settle_browser_size(&surface, (100, 40));

        assert!(
            mux.control_clients.detach_surface(blocker, surface.id, blocker_stream_id).final_stream
        );
        mux.remove_surface_size_client(surface.id, blocker);

        settle_browser_size(&surface, (100, 40));
    }

    #[test]
    fn final_stream_detach_does_not_recalculate_other_surface() {
        let mux = test_mux();
        let blocker_surface = sizing_browser(&mux, (100, 40));
        let reported_surface = sizing_browser(&mux, (100, 40));
        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, reported_surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: reported_surface.id, cols: 70, rows: 20 },
            &reporter_writer,
        )
        .unwrap();
        settle_browser_size(&reported_surface, (70, 20));
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing {
                surface: reported_surface.id,
                client: Some(reporter),
                enabled: false,
                exclusive: false,
            },
            &reporter_writer,
        )
        .unwrap();

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        let blocker_stream_id = blocker_stream.id;
        mux.control_clients.attach_surface(blocker, blocker_surface.id, blocker_stream).unwrap();
        mux.resize_surface(reported_surface.id, 100, 40).unwrap();
        settle_browser_size(&reported_surface, (100, 40));

        assert!(
            mux.control_clients
                .detach_surface(blocker, blocker_surface.id, blocker_stream_id)
                .final_stream
        );
        mux.remove_surface_size_client(blocker_surface.id, blocker);

        settle_browser_size(&reported_surface, (100, 40));
    }

    #[test]
    fn failed_reducer_resize_restores_registry_size() {
        let mux = test_mux();
        let missing_surface = 99_999;
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, missing_surface, stream).unwrap();
        mux.control_clients.commit_surface(client, missing_surface, stream_id, None).unwrap();

        assert!(mux
            .resize_surface_for_control_client_with_reservation(
                missing_surface,
                client,
                70,
                20,
            )
            .is_err());

        let clients = mux.control_clients.list_json(client);
        assert_eq!(clients[0]["sizes"][0]["surface"], missing_surface);
        assert_eq!(clients[0]["sizes"][0]["cols"], Value::Null);
        assert_eq!(clients[0]["sizes"][0]["rows"], Value::Null);
    }

    #[test]
    fn failed_attach_rollback_does_not_restore_disconnected_client_size() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        let resize = mux
            .resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20)
            .unwrap();
        assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));

        assert!(disconnect_client(&mux, client, false));
        mux.rollback_surface_size_client(surface.id, client, resize.rollback);

        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(!mux.control_clients.contains(client));
    }

    #[test]
    fn rejected_attach_rollback_keeps_registry_at_actual_size() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
        settle_browser_size(&surface, (80, 24));
        let changed = mux
            .resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20)
            .unwrap();
        settle_browser_size(&surface, (70, 20));

        let removed = mux.remove_surface_runtime_for_test(surface.id).unwrap();
        mux.rollback_surface_size_client(surface.id, client, changed.rollback);

        assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));
        let clients = mux.control_clients.list_json(client);
        assert_eq!(clients[0]["sizes"][0]["cols"], 70);
        assert_eq!(clients[0]["sizes"][0]["rows"], 20);
        removed.kill();
    }

    #[test]
    fn unrelated_attach_does_not_cancel_failed_surface_rollback_repair() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let unrelated_surface = sizing_browser(&mux, (100, 40));
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
        settle_browser_size(&surface, (80, 24));
        let changed = mux
            .resize_surface_for_control_client_with_reservation(surface.id, client, 70, 20)
            .unwrap();
        settle_browser_size(&surface, (70, 20));

        let unrelated_writer = test_writer();
        let unrelated_client =
            mux.control_clients.register(ClientTransport::Unix, unrelated_writer.clone());
        let unrelated_stream = unrelated_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.set_client_rollback_before_wait(Some(Arc::new({
            let hook_mux = mux.clone();
            move || {
                hook_mux
                    .control_clients
                    .attach_surface(
                        unrelated_client,
                        unrelated_surface.id,
                        unrelated_stream.clone(),
                    )
                    .unwrap();
            }
        })));
        let removed = mux.remove_surface_runtime_for_test(surface.id).unwrap();

        mux.rollback_surface_size_client(surface.id, client, changed.rollback);
        mux.set_client_rollback_before_wait(None);

        assert_eq!(mux.client_surface_size(surface.id, client), Some((70, 20)));
        let clients = mux.control_clients.list_json(client);
        let client =
            clients.as_array().unwrap().iter().find(|entry| entry["self"] == true).unwrap();
        assert_eq!(client["sizes"][0]["cols"], 70);
        assert_eq!(client["sizes"][0]["rows"], 20);
        removed.kill();
    }

    #[test]
    fn disconnect_cleanup_wins_over_a_waiting_stale_sizing_action() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();

        let lifecycle = mux.lock_client_sizing_lifecycle();
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let action_mux = mux.clone();
        let action = std::thread::spawn(move || {
            ready_tx.send(()).unwrap();
            action_mux.set_client_size_participation(surface.id, client, false)
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let removed = mux.control_clients.remove(client).expect("registered client");
        mux.remove_size_client(client);
        drop(removed);
        drop(lifecycle);

        assert_eq!(action.join().unwrap(), None);
        assert!(!mux.control_clients.contains(client));
    }

    #[test]
    fn detached_client_cannot_fall_through_to_direct_resize() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        assert!(disconnect_client(&mux, client, false));

        let error = handle_command(
            &mux,
            client,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &writer,
        )
        .unwrap_err();

        assert!(error.to_string().contains(&format!("unknown client {client}")));
        assert_eq!(surface.size(), (100, 40));
    }

    #[test]
    fn unattached_live_resize_still_obeys_visible_client_minimum() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));
        let viewer_writer = test_writer();
        let viewer = mux.control_clients.register(ClientTransport::Unix, viewer_writer.clone());
        let stream = viewer_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(viewer, surface.id, stream).unwrap();
        handle_command(
            &mux,
            viewer,
            Command::ResizeSurface { surface: surface.id, cols: 100, rows: 40 },
            &viewer_writer,
        )
        .unwrap();

        let control_writer = test_writer();
        let control = mux.control_clients.register(ClientTransport::Unix, control_writer.clone());
        handle_command(
            &mux,
            control,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 50 },
            &control_writer,
        )
        .unwrap();
        assert_eq!(surface.size(), (100, 40));

        handle_command(
            &mux,
            control,
            Command::ResizeSurface { surface: surface.id, cols: 70, rows: 20 },
            &control_writer,
        )
        .unwrap();
        settle_browser_size(&surface, (70, 20));

        assert!(disconnect_client(&mux, control, false));
        settle_browser_size(&surface, (100, 40));
    }

    #[test]
    fn terminal_geometry_authority_excludes_clients_that_attach_later() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let target_writer = test_writer();
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
        let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
        handle_command(
            &mux,
            target,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
            &target_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            target,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(target),
                enabled: true,
                exclusive: true,
            },
            &target_writer,
        )
        .unwrap();

        let later_writer = test_writer();
        let later = mux.control_clients.register(ClientTransport::Unix, later_writer.clone());
        let later_stream = later_writer.start_stream(&json!({"event": "test"})).unwrap();
        let later_stream_id = later_stream.id;
        mux.control_clients.attach_surface(later, surface.id, later_stream).unwrap();
        mux.control_clients.commit_surface(later, surface.id, later_stream_id, None).unwrap();
        handle_command(
            &mux,
            later,
            Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
            &later_writer,
        )
        .unwrap();

        assert_eq!(surface.size(), (120, 40));
        assert!(!mux.client_size_participates(surface.id, later));
        let clients = mux.control_clients_json(target);
        assert_eq!(
            clients.as_array().unwrap().iter().find(|client| client["client"] == later).unwrap()["sizes"]
                [0]["size_participating"],
            false
        );
    }

    #[test]
    fn enabling_late_unsized_terminal_client_transfers_geometry_authority() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let target_writer = test_writer();
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
        let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
        handle_command(
            &mux,
            target,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
            &target_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            target,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(target),
                enabled: true,
                exclusive: true,
            },
            &target_writer,
        )
        .unwrap();

        let late_writer = test_writer();
        let late = mux.control_clients.register(ClientTransport::Unix, late_writer.clone());
        let late_stream = late_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(late, surface.id, late_stream).unwrap();
        assert!(!mux.client_size_participates(surface.id, late));

        let other_writer = test_writer();
        let other = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());
        let other_stream = other_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(other, surface.id, other_stream).unwrap();
        assert!(!mux.client_size_participates(surface.id, other));

        handle_command(
            &mux,
            late,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(late),
                enabled: true,
                exclusive: false,
            },
            &late_writer,
        )
        .unwrap();

        assert!(mux.client_size_participates(surface.id, late));
        assert!(!mux.client_size_participates(surface.id, target));
        assert!(!mux.client_size_participates(surface.id, other));
    }

    #[test]
    fn disabling_late_unsized_terminal_client_preserves_geometry_authority() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 40))).unwrap();
        let target_writer = test_writer();
        let target = mux.control_clients.register(ClientTransport::Unix, target_writer.clone());
        let target_stream = target_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(target, surface.id, target_stream).unwrap();
        handle_command(
            &mux,
            target,
            Command::ResizeSurface { surface: surface.id, cols: 120, rows: 40 },
            &target_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            target,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(target),
                enabled: true,
                exclusive: true,
            },
            &target_writer,
        )
        .unwrap();

        let late_writer = test_writer();
        let late = mux.control_clients.register(ClientTransport::Unix, late_writer.clone());
        let late_stream = late_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(late, surface.id, late_stream).unwrap();
        handle_command(
            &mux,
            late,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(late),
                enabled: false,
                exclusive: false,
            },
            &late_writer,
        )
        .unwrap();

        let newest_writer = test_writer();
        let newest = mux.control_clients.register(ClientTransport::Unix, newest_writer.clone());
        let newest_stream = newest_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(newest, surface.id, newest_stream).unwrap();
        assert!(!mux.client_size_participates(surface.id, newest));
    }

    #[test]
    fn ignored_report_does_not_replace_unsized_creation_default() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (100, 40));

        let blocker_writer = test_writer();
        let blocker = mux.control_clients.register(ClientTransport::Unix, blocker_writer.clone());
        let blocker_stream = blocker_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(blocker, surface.id, blocker_stream).unwrap();

        let reporter_writer = test_writer();
        let reporter = mux.control_clients.register(ClientTransport::Unix, reporter_writer.clone());
        let reporter_stream = reporter_writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(reporter, surface.id, reporter_stream).unwrap();
        handle_command(
            &mux,
            reporter,
            Command::SetClientSizing {
                surface: surface.id,
                client: Some(reporter),
                enabled: false,
                exclusive: false,
            },
            &reporter_writer,
        )
        .unwrap();
        handle_command(
            &mux,
            reporter,
            Command::ResizeSurface { surface: surface.id, cols: 60, rows: 20 },
            &reporter_writer,
        )
        .unwrap();

        assert_eq!(surface.size(), (100, 40));
        assert_eq!(mux.new_workspace(None, None).unwrap().size(), (100, 40));
    }

    #[test]
    fn browser_attach_initial_sizes_share_the_smallest_viewer_grid() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (120, 40));
        let first_writer = test_writer();
        let second_writer = test_writer();
        let first = mux.control_clients.register(ClientTransport::Unix, first_writer.clone());
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        let first_stream = first_writer.start_stream(&json!({"event": "test"})).unwrap();
        let second_stream = second_writer.start_stream(&json!({"event": "test"})).unwrap();

        let first_attach =
            mark_client_attached(&mux, first, surface.id, first_stream.clone(), Some((100, 30)))
                .unwrap();
        settle_marked_browser_resize(&surface, &first_attach);
        let second_attach =
            mark_client_attached(&mux, second, surface.id, second_stream.clone(), Some((80, 35)))
                .unwrap();
        settle_marked_browser_resize(&surface, &second_attach);

        assert_eq!(mux.client_surface_size(surface.id, first), Some((100, 30)));
        assert_eq!(mux.client_surface_size(surface.id, second), Some((80, 35)));
        settle_browser_size(&surface, (80, 30));

        cleanup_failed_attach(&mux, first, surface.id, first_stream.id);
        assert_eq!(mux.client_surface_size(surface.id, first), None);
        settle_browser_size(&surface, (80, 35));

        cleanup_failed_attach(&mux, second, surface.id, second_stream.id);
        assert_eq!(mux.client_surface_size(surface.id, second), None);
        assert!(mux.surface(surface.id).is_some());
    }

    #[test]
    fn secondary_attach_detach_restores_the_surviving_stream_size() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (120, 40));
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let first_stream = writer.start_stream(&json!({"event": "first"})).unwrap();
        let second_stream = writer.start_stream(&json!({"event": "second"})).unwrap();

        let first =
            mark_client_attached(&mux, client, surface.id, first_stream.clone(), Some((100, 30)))
                .unwrap();
        settle_marked_browser_resize(&surface, &first);
        commit_client_attach(
            &mux,
            client,
            surface.id,
            first_stream.id,
            first.client_changed,
            first.size_rollback,
        )
        .unwrap();
        let second =
            mark_client_attached(&mux, client, surface.id, second_stream.clone(), Some((80, 24)))
                .unwrap();
        settle_marked_browser_resize(&surface, &second);
        commit_client_attach(
            &mux,
            client,
            surface.id,
            second_stream.id,
            second.client_changed,
            second.size_rollback,
        )
        .unwrap();
        settle_browser_size(&surface, (80, 24));

        detach_committed_attach(&mux, client, surface.id, second_stream.id);

        assert_eq!(mux.client_surface_size(surface.id, client), Some((100, 30)));
        settle_browser_size(&surface, (100, 30));
        let listed = mux.control_clients.list_json(client);
        assert_eq!(listed[0]["sizes"][0]["cols"].as_u64(), Some(100));
        assert_eq!(listed[0]["sizes"][0]["rows"].as_u64(), Some(30));

        detach_committed_attach(&mux, client, surface.id, first_stream.id);
    }

    #[test]
    fn attachment_leases_fence_independent_same_connection_views() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (120, 40));
        let other_surface = mux.new_workspace(None, Some((90, 30))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("lease test".to_string()),
                kind: Some("tui".to_string()),
                capabilities: Some(vec![
                    VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string(),
                    VIEW_ATTACHMENT_DETACH_CAPABILITY.to_string(),
                ]),
            },
            &writer,
        )
        .unwrap();

        let first_stream = writer.start_stream(&json!({"event": "first"})).unwrap();
        let first_attach =
            mark_client_attached(&mux, client, surface.id, first_stream.clone(), Some((100, 30)))
                .unwrap();
        let first_lease = first_attach.lease.clone().expect("negotiated attach omitted its lease");
        settle_marked_browser_resize(&surface, &first_attach);
        commit_client_attach(
            &mux,
            client,
            surface.id,
            first_stream.id,
            first_attach.client_changed,
            first_attach.size_rollback,
        )
        .unwrap();

        let second_stream = writer.start_stream(&json!({"event": "second"})).unwrap();
        let second_attach =
            mark_client_attached(&mux, client, surface.id, second_stream.clone(), Some((80, 24)))
                .unwrap();
        let second_lease =
            second_attach.lease.clone().expect("second negotiated attach omitted its lease");
        settle_marked_browser_resize(&surface, &second_attach);
        commit_client_attach(
            &mux,
            client,
            surface.id,
            second_stream.id,
            second_attach.client_changed,
            second_attach.size_rollback,
        )
        .unwrap();

        assert_ne!(first_lease, second_lease);
        assert_eq!(surface.size(), (100, 30));
        let owner = handle_command(
            &mux,
            client,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: first_lease.clone(),
                cols: 110,
                rows: 35,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(owner["outcome"], "applied");
        settle_browser_size(&surface, (110, 35));

        let passive = handle_command(
            &mux,
            client,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: second_lease.clone(),
                cols: 70,
                rows: 20,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(passive["outcome"], "passive");
        assert_eq!(surface.size(), (110, 35));

        let geometry_before_invalid_requests = surface.size();
        for (request_client, request_surface, lease, expected) in [
            (client, surface.id, "fabricated".to_string(), "invalid or foreign"),
            (client, other_surface.id, second_lease.clone(), "belongs to surface"),
        ] {
            let error = handle_command(
                &mux,
                request_client,
                Command::ResizeAttachedView { surface: request_surface, lease, cols: 40, rows: 10 },
                &writer,
            )
            .unwrap_err();
            assert!(error.to_string().contains(expected), "unexpected lease error: {error:#}");
        }
        let foreign_writer = test_writer();
        let foreign = mux.control_clients.register(ClientTransport::Unix, foreign_writer.clone());
        let foreign_error = handle_command(
            &mux,
            foreign,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: second_lease.clone(),
                cols: 40,
                rows: 10,
            },
            &foreign_writer,
        )
        .unwrap_err();
        assert!(foreign_error.to_string().contains("invalid or foreign"));
        assert_eq!(surface.size(), geometry_before_invalid_requests);

        let detached = handle_command(
            &mux,
            client,
            Command::DetachAttachedView { surface: surface.id, lease: first_lease.clone() },
            &writer,
        )
        .unwrap();
        assert_eq!(detached["outcome"], "applied");
        assert!(!first_stream.is_open());
        let repeated = handle_command(
            &mux,
            client,
            Command::DetachAttachedView { surface: surface.id, lease: first_lease.clone() },
            &writer,
        )
        .unwrap();
        assert_eq!(repeated["outcome"], "superseded");
        settle_browser_size(&surface, (70, 20));
        for command in [
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: first_lease.clone(),
                cols: 60,
                rows: 18,
            },
            Command::ReleaseAttachedViewSize { surface: surface.id, lease: first_lease.clone() },
        ] {
            let retired = handle_command(&mux, client, command, &writer).unwrap();
            assert_eq!(retired["outcome"], "superseded");
        }

        let promoted = handle_command(
            &mux,
            client,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: second_lease.clone(),
                cols: 90,
                rows: 28,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(promoted["outcome"], "applied");
        settle_browser_size(&surface, (90, 28));

        detach_committed_attach(&mux, client, surface.id, second_stream.id);
        let retired = handle_command(
            &mux,
            client,
            Command::ResizeAttachedView {
                surface: surface.id,
                lease: second_lease.clone(),
                cols: 55,
                rows: 16,
            },
            &writer,
        )
        .unwrap();
        assert_eq!(retired["outcome"], "superseded");

        let third_stream = writer.start_stream(&json!({"event": "third"})).unwrap();
        let third_attach =
            mark_client_attached(&mux, client, surface.id, third_stream.clone(), Some((75, 22)))
                .unwrap();
        let third_lease = third_attach.lease.clone().expect("reattach omitted its lease");
        settle_marked_browser_resize(&surface, &third_attach);
        commit_client_attach(
            &mux,
            client,
            surface.id,
            third_stream.id,
            third_attach.client_changed,
            third_attach.size_rollback,
        )
        .unwrap();
        assert_ne!(third_lease, first_lease);
        assert_ne!(third_lease, second_lease);
        let old_after_reattach = handle_command(
            &mux,
            client,
            Command::ReleaseAttachedViewSize { surface: surface.id, lease: second_lease },
            &writer,
        )
        .unwrap();
        assert_eq!(old_after_reattach["outcome"], "superseded");
        assert_eq!(surface.size(), (75, 22));

        assert!(disconnect_client(&mux, client, true));
        assert!(mux.surface(surface.id).is_some(), "disconnect must not close the terminal");
        assert!(!mux.control_clients.contains(client));
        assert!(disconnect_client(&mux, foreign, true));
    }

    #[test]
    fn attachment_resize_waits_for_detach_lifecycle_and_becomes_superseded() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((100, 30))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("lease fence".to_string()),
                kind: Some("tui".to_string()),
                capabilities: Some(vec![VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string()]),
            },
            &writer,
        )
        .unwrap();
        let stream = writer.start_stream(&json!({"event": "fence"})).unwrap();
        let surface_id = surface.id;
        let lease = mux
            .control_clients
            .attach_surface(client, surface_id, stream.clone())
            .unwrap()
            .expect("negotiated attach omitted its lease");
        mux.control_clients.commit_surface(client, surface_id, stream.id, None).unwrap();

        let lifecycle = mux.lock_client_sizing_lifecycle();
        let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
        let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
        let resize_mux = mux.clone();
        let resize_writer = writer;
        let resize = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let result = handle_command(
                &resize_mux,
                client,
                Command::ResizeAttachedView { surface: surface_id, lease, cols: 80, rows: 24 },
                &resize_writer,
            );
            result_tx.send(result).unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            result_rx.recv_timeout(Duration::from_millis(100)).is_err(),
            "resize crossed the held detach lifecycle fence"
        );

        let detached = mux.control_clients.detach_surface(client, surface_id, stream.id);
        assert!(detached.final_stream);
        mux.remove_surface_size_client(surface_id, client);
        drop(lifecycle);

        let result = result_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        assert_eq!(result["outcome"], "superseded");
        resize.join().unwrap();
        assert_eq!(mux.client_surface_size(surface_id, client), None);
        assert!(disconnect_client(&mux, client, true));
        mux.close_surface(surface_id).unwrap();
    }

    #[test]
    fn terminal_view_leases_converge_after_500_rapid_attach_resize_detach_cycles() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            client,
            Command::SetClientInfo {
                name: Some("lease stress".to_string()),
                kind: Some("tui".to_string()),
                capabilities: Some(vec![VIEW_ATTACHMENT_LEASE_CAPABILITY.to_string()]),
            },
            &writer,
        )
        .unwrap();

        for cycle in 0_u16..500 {
            let initial = (80 + cycle % 31, 20 + cycle % 13);
            let resized = (90 + cycle % 23, 24 + cycle % 11);
            let stream = writer.start_stream(&json!({"event": "stress", "cycle": cycle})).unwrap();
            let marked =
                mark_client_attached(&mux, client, surface.id, stream.clone(), Some(initial))
                    .unwrap();
            let lease = marked.lease.clone().expect("negotiated attach omitted its lease");
            commit_client_attach(
                &mux,
                client,
                surface.id,
                stream.id,
                marked.client_changed,
                marked.size_rollback,
            )
            .unwrap();
            let resize = handle_command(
                &mux,
                client,
                Command::ResizeAttachedView {
                    surface: surface.id,
                    lease: lease.clone(),
                    cols: resized.0,
                    rows: resized.1,
                },
                &writer,
            )
            .unwrap();
            assert_eq!(resize["outcome"], "applied", "cycle {cycle}");

            detach_committed_attach(&mux, client, surface.id, stream.id);
            let stale = handle_command(
                &mux,
                client,
                Command::ResizeAttachedView { surface: surface.id, lease, cols: 40, rows: 10 },
                &writer,
            )
            .unwrap();
            assert_eq!(stale["outcome"], "superseded", "cycle {cycle}");
            assert_eq!(mux.client_surface_size(surface.id, client), None, "cycle {cycle}");
        }

        assert!(mux.surface(surface.id).is_some());
        assert!(
            mux.control_clients.list_json(client)[0]["attached"].as_array().unwrap().is_empty()
        );
        assert!(disconnect_client(&mux, client, true));
        mux.close_surface(surface.id).unwrap();
    }

    #[test]
    fn failed_attach_cleanup_releases_stream_and_size_lease() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();

        mux.control_clients.attach_surface(client, surface.id, stream.clone()).unwrap();
        mux.resize_surface_for_control_client_with_reservation(surface.id, client, 80, 24).unwrap();
        cleanup_failed_attach(&mux, client, surface.id, stream.id);

        assert!(!mux.control_clients.attached_client_ids().contains(&client));
        assert_eq!(mux.client_surface_size(surface.id, client), None);
    }

    #[test]
    fn failed_first_attach_restores_pre_attach_surface_geometry() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (120, 40));
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();

        let marked =
            mark_client_attached(&mux, client, surface.id, stream.clone(), Some((80, 24))).unwrap();
        settle_marked_browser_resize(&surface, &marked);
        settle_browser_size(&surface, (80, 24));

        rollback_failed_attach(&mux, client, surface.id, stream.id, marked.size_rollback);

        assert_eq!(surface.size(), (120, 40));
        assert_eq!(mux.client_surface_size(surface.id, client), None);
        assert!(!mux.control_clients.attached_client_ids().contains(&client));
    }

    #[test]
    fn attach_rollback_wait_does_not_hold_global_sizing_locks() {
        let mux = test_mux();
        let failed_surface = sizing_browser(&mux, (120, 40));
        let unrelated_surface = sizing_browser(&mux, (100, 30));
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        mux.control_clients.attach_surface(client, failed_surface.id, stream).unwrap();
        let resize = mux
            .resize_surface_for_control_client_with_reservation(failed_surface.id, client, 80, 24)
            .unwrap();
        settle_browser_size(&failed_surface, (80, 24));

        let entered = Arc::new(std::sync::Barrier::new(2));
        let resume = Arc::new(std::sync::Barrier::new(2));
        mux.set_client_rollback_before_wait(Some(Arc::new({
            let entered = entered.clone();
            let resume = resume.clone();
            move || {
                entered.wait();
                resume.wait();
            }
        })));
        let rollback_mux = mux.clone();
        let rollback = std::thread::spawn(move || {
            rollback_mux.rollback_surface_size_client(failed_surface.id, client, resize.rollback);
        });
        entered.wait();

        let (resized_tx, resized_rx) = std::sync::mpsc::sync_channel(1);
        let resize_mux = mux.clone();
        let unrelated = unrelated_surface.id;
        let resize_thread = std::thread::spawn(move || {
            resized_tx
                .send(resize_mux.resize_surface_for_client(unrelated, 9_999, 70, 20))
                .unwrap();
        });
        assert!(resized_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap());

        resume.wait();
        rollback.join().unwrap();
        resize_thread.join().unwrap();
        mux.set_client_rollback_before_wait(None);
    }

    #[test]
    fn failed_secondary_attach_preserves_surviving_stream_size_lease() {
        let mux = test_mux();
        let surface = sizing_browser(&mux, (120, 40));
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let first = writer.start_stream(&json!({"event": "test"})).unwrap();
        let failed = writer.start_stream(&json!({"event": "test"})).unwrap();

        let first = mark_client_attached(&mux, client, surface.id, first, Some((80, 24))).unwrap();
        settle_marked_browser_resize(&surface, &first);
        let rollback =
            mark_client_attached(&mux, client, surface.id, failed.clone(), Some((60, 20))).unwrap();
        settle_marked_browser_resize(&surface, &rollback);
        assert_eq!(mux.client_surface_size(surface.id, client), Some((60, 20)));
        settle_browser_size(&surface, (60, 20));
        rollback_failed_attach(&mux, client, surface.id, failed.id, rollback.size_rollback);

        assert!(mux.control_clients.attached_client_ids().contains(&client));
        assert_eq!(mux.client_surface_size(surface.id, client), Some((80, 24)));
        settle_browser_size(&surface, (80, 24));
    }

    #[test]
    fn failed_attach_setup_does_not_announce_or_suppress_retry() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let events = mux.subscribe();
        let failed_stream = writer.start_stream(&json!({"event": "test"})).unwrap();

        assert!(
            mark_client_attached(&mux, client, surface.id + 10_000, failed_stream, Some((80, 24)),)
                .is_err()
        );
        assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::ClientAttached { .. })));
        assert!(!mux.control_clients.attached_client_ids().contains(&client));

        let retry_stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let retry_stream_id = retry_stream.id;
        mark_client_attached(&mux, client, surface.id, retry_stream, Some((80, 24))).unwrap();
        let staged = mux.control_clients.list_json(client);
        assert_eq!(staged[0]["attached"], json!([]));
        assert_eq!(staged[0]["sizes"], json!([]));
        assert!(!events.try_iter().any(|event| matches!(
            event,
            MuxEvent::ClientAttached { .. } | MuxEvent::ClientChanged { .. }
        )));
        commit_client_attach(&mux, client, surface.id, retry_stream_id, None, None).unwrap();

        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ClientAttached { client: attached, .. }) if attached == client
        ));
    }

    #[test]
    fn attach_worker_cleanup_starts_after_stream_commit() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
        let stream_id = stream.id;
        let surface_id = surface.id;
        let marked = mark_client_attached(&mux, client, surface_id, stream, None).unwrap();
        let lifecycle = AttachLifecycle::default();
        let (worker_start, worker_committed) = std::sync::mpsc::sync_channel(1);
        let (observed_tx, observed_rx) = std::sync::mpsc::sync_channel(1);
        let worker_mux = mux.clone();
        let worker = std::thread::spawn(move || {
            worker_committed.recv().unwrap();
            let clients = worker_mux.control_clients.list_json(client);
            let attached = clients[0]["attached"]
                .as_array()
                .is_some_and(|surfaces| surfaces.contains(&json!(surface_id)));
            observed_tx.send(attached).unwrap();
            cleanup_failed_attach(&worker_mux, client, surface_id, stream_id);
        });

        commit_client_attach_and_start_worker(
            &mux,
            client,
            surface_id,
            stream_id,
            AttachWorkerCommit {
                start: worker_start,
                lifecycle,
                changed: marked.client_changed,
                size_rollback: marked.size_rollback,
            },
        )
        .unwrap();

        assert!(observed_rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
    }

    #[test]
    fn stale_workspace_selectors_report_revision_conflicts_before_lookup() {
        let mux = test_mux();
        let key = "018f6e21-7b70-7e70-8000-000000001022";
        let workspace =
            mux.create_empty_workspace(Some("stale".into()), Some(key.into()), None).unwrap();
        mux.close_workspace_at_revision(workspace.workspace, Some(1)).unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        for command in [
            Command::CloseWorkspace {
                workspace: None,
                key: Some(key.into()),
                mutation: MutationRequest { expected_revision: Some(1), ..Default::default() },
            },
            Command::RenameWorkspace {
                workspace: None,
                key: Some(key.into()),
                name: "renamed".into(),
                mutation: MutationRequest { expected_revision: Some(1), ..Default::default() },
            },
            Command::MoveWorkspace {
                workspace: None,
                key: Some(key.into()),
                index: 0,
                mutation: MutationRequest { expected_revision: Some(1), ..Default::default() },
            },
        ] {
            let error = handle_command(&mux, client, command, &writer).unwrap_err();
            assert_eq!(error.to_string(), "workspace revision conflict: expected 1, current 2");
        }
    }

    #[test]
    fn provider_managed_mux_is_locked_before_authority_handshake() {
        let mux = provider_test_mux();
        let workspace = mux
            .create_empty_workspace(
                Some("managed".into()),
                Some("018f6e21-7b70-7e70-8000-00000000aa03".into()),
                None,
            )
            .unwrap();
        let writer = test_writer();
        let ordinary = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        let mutation_error = handle_command(
            &mux,
            ordinary,
            Command::RenameWorkspace {
                workspace: Some(workspace.workspace),
                key: Some(workspace.key),
                name: "won the race".into(),
                mutation: MutationRequest::default(),
            },
            &writer,
        )
        .unwrap_err();
        let handshake_error = handle_command(
            &mux,
            ordinary,
            Command::MarkWorkspacesProviderManaged { authority: "ordinary-control-client".into() },
            &writer,
        )
        .unwrap_err();

        assert!(mutation_error.to_string().contains("provider-managed workspace directly"));
        assert_eq!(handshake_error.to_string(), "invalid provider workspace authority");
        assert_eq!(mux.with_state(|state| state.workspaces[0].name.clone()), "managed");
    }

    #[test]
    fn provider_managed_workspaces_reject_ordinary_server_mutations() {
        let mux = provider_test_mux();
        let workspace = mux
            .create_empty_workspace(
                Some("managed".into()),
                Some("018f6e21-7b70-7e70-8000-00000000aa04".into()),
                None,
            )
            .unwrap();
        let writer = test_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());

        handle_command(
            &mux,
            client,
            Command::MarkWorkspacesProviderManaged { authority: PROVIDER_AUTHORITY.into() },
            &writer,
        )
        .unwrap();
        for (command, expected_error) in [
            (
                Command::RenameWorkspace {
                    workspace: Some(workspace.workspace),
                    key: Some(workspace.key.clone()),
                    name: "raw rename".into(),
                    mutation: MutationRequest::default(),
                },
                "cannot rename a provider-managed workspace directly; use the managed workspace lifecycle controls",
            ),
            (
                Command::CloseWorkspace {
                    workspace: Some(workspace.workspace),
                    key: Some(workspace.key.clone()),
                    mutation: MutationRequest::default(),
                },
                "cannot close a provider-managed workspace directly; use the managed workspace lifecycle controls",
            ),
        ] {
            let error = handle_command(&mux, client, command, &writer).unwrap_err();
            assert_eq!(error.to_string(), expected_error);
        }
        mux.with_state(|state| {
            assert_eq!(state.workspace_revision, 1);
            let current = state
                .workspaces
                .iter()
                .find(|candidate| candidate.id == workspace.workspace)
                .unwrap();
            assert_eq!(current.name, "managed");
        });

        handle_command(
            &mux,
            client,
            Command::RenameProviderManagedWorkspace {
                workspace: workspace.workspace,
                key: workspace.key.clone(),
                name: "provider rename".into(),
                authority: PROVIDER_AUTHORITY.into(),
            },
            &writer,
        )
        .unwrap();
        assert_eq!(
            mux.with_state(|state| state
                .workspaces
                .iter()
                .find(|candidate| candidate.id == workspace.workspace)
                .unwrap()
                .name
                .clone()),
            "provider rename"
        );

        handle_command(
            &mux,
            client,
            Command::CloseProviderManagedWorkspace {
                workspace: workspace.workspace,
                key: workspace.key,
                authority: PROVIDER_AUTHORITY.into(),
            },
            &writer,
        )
        .unwrap();
        assert!(mux.with_state(|state| state.workspaces.is_empty()));
    }

    #[test]
    fn ordinary_control_client_cannot_forge_provider_workspace_commits() {
        let mux = provider_test_mux();
        let workspace = mux
            .create_empty_workspace(
                Some("managed".into()),
                Some("018f6e21-7b70-7e70-8000-00000000aa05".into()),
                None,
            )
            .unwrap();
        let writer = test_writer();
        let provider = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let ordinary = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        handle_command(
            &mux,
            provider,
            Command::MarkWorkspacesProviderManaged { authority: PROVIDER_AUTHORITY.into() },
            &writer,
        )
        .unwrap();

        let rename_error = handle_command(
            &mux,
            ordinary,
            Command::RenameProviderManagedWorkspace {
                workspace: workspace.workspace,
                key: workspace.key.clone(),
                name: "forged rename".into(),
                authority: "ordinary-control-client".into(),
            },
            &writer,
        )
        .unwrap_err();
        let close_error = handle_command(
            &mux,
            ordinary,
            Command::CloseProviderManagedWorkspace {
                workspace: workspace.workspace,
                key: workspace.key,
                authority: "ordinary-control-client".into(),
            },
            &writer,
        )
        .unwrap_err();

        assert!(rename_error.to_string().contains("provider workspace authority"));
        assert!(close_error.to_string().contains("provider workspace authority"));
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), 1);
            assert_eq!(state.workspaces[0].name, "managed");
            assert_eq!(state.workspace_revision, 1);
        });
    }

    #[test]
    fn identify_advertises_additive_capabilities() {
        let mux = test_mux();
        let identity = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();

        let capabilities = identity["capabilities"].as_array().expect("capabilities");
        for expected in [
            "attach-initial-size",
            SURFACE_SUBSCRIBE_FILTER_CAPABILITY,
            "workspace-registry-v1",
            GUARDED_BROWSER_POINTER_CAPABILITY,
            VIEWPORT_SPLITS_CAPABILITY,
            VIEWPORT_COLUMN_RESIZE_CAPABILITY,
            LAYOUT_UNDO_CAPABILITY,
            CLEAR_HISTORY_CAPABILITY,
            CLEAR_HISTORY_KEY_CAPABILITY,
            "surface-subscribe-filter",
            SESSION_JOURNAL_CAPABILITY,
            FRONTEND_JOURNAL_CAPABILITY,
            VIEW_ATTACHMENT_LEASE_CAPABILITY,
            VIEW_ATTACHMENT_DETACH_CAPABILITY,
            CREATION_RECEIPTS_CAPABILITY,
            CREATION_SELECTOR_FALLBACKS_CAPABILITY,
            PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY,
        ] {
            assert!(capabilities.iter().any(|value| value.as_str() == Some(expected)));
        }
    }

    #[test]
    fn layout_undo_protocol_requires_the_preview_revision_before_closing_a_pane() {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let writer = test_writer();

        let preview = handle_command(
            &mux,
            0,
            Command::UndoLayout { pane: right_pane, revision: None, confirm_close: false },
            &writer,
        )
        .unwrap();
        let revision = preview["revision"].as_u64().expect("preview revision");
        assert_eq!(preview["undone"].as_bool(), Some(false));
        assert_eq!(preview["confirmation_required"].as_bool(), Some(true));
        assert_eq!(preview["closes_panes"], json!([right_pane]));

        let error = handle_command(
            &mux,
            0,
            Command::UndoLayout { pane: right_pane, revision: None, confirm_close: true },
            &writer,
        )
        .unwrap_err();
        assert!(error.to_string().contains("requires the preview revision"));
        assert!(mux.surface(right.id).is_some());

        let result = handle_command(
            &mux,
            0,
            Command::UndoLayout { pane: right_pane, revision: Some(revision), confirm_close: true },
            &writer,
        )
        .unwrap();
        assert_eq!(result["undone"].as_bool(), Some(true));
        assert!(!mux.with_state(|state| state.surfaces.contains_key(&right.id)));
        assert!(mux.surface(right.id).is_some());
    }

    #[test]
    fn layout_undo_protocol_serializes_the_machine_readable_error_code() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((80, 22))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });

        handle_message(
            &mux,
            7,
            &json!({"id": 19, "cmd": "undo-layout", "pane": pane}).to_string(),
            &writer,
        );

        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], 19);
        assert_eq!(response["ok"], false);
        assert_eq!(response["error_code"], crate::LayoutUndoError::UNAVAILABLE_CODE);
    }

    #[test]
    fn identify_advertises_clear_history_key_only_with_bounded_fallback_writes() {
        let unsupported = advertised_capabilities(false);
        assert!(unsupported.contains(&CLEAR_HISTORY_CAPABILITY));
        assert!(unsupported.contains(&CREATION_ATTEMPT_KEYS_CAPABILITY));
        assert!(!unsupported.contains(&CLEAR_HISTORY_KEY_CAPABILITY));

        let supported = advertised_capabilities(true);
        assert!(supported.contains(&CLEAR_HISTORY_CAPABILITY));
        assert!(supported.contains(&CLEAR_HISTORY_KEY_CAPABILITY));
    }

    #[test]
    fn protocol_key_input_round_trips_encoder_metadata() {
        let input = KeyInput {
            key: sys::GHOSTTY_KEY_NUMPAD_ENTER,
            mods: Mods::SHIFT | Mods::CTRL | Mods::ALT | Mods::CAPS_LOCK | Mods::NUM_LOCK,
            consumed_mods: Mods::SHIFT | Mods::ALT,
            composing: true,
            utf8: "ß".to_string(),
            unshifted_codepoint: 's' as u32,
            shifted_codepoint: 'S' as u32,
            base_layout_codepoint: '1' as u32,
            action: Some(KeyAction::Repeat),
            macos_option_as_alt: false,
        };

        let value = serde_json::to_value(ProtocolKeyInput::try_from(&input).unwrap()).unwrap();
        assert_eq!(value["key"], "numpad-enter");
        assert_eq!(value["composing"], true);
        assert_eq!(value["unshifted_codepoint"], "s");
        assert_eq!(value["shifted_codepoint"], "S");
        assert_eq!(value["base_layout_codepoint"], "1");
        let decoded = serde_json::from_value::<ProtocolKeyInput>(value).unwrap();
        let decoded = KeyInput::try_from(decoded).unwrap();

        assert_eq!(decoded.key, input.key);
        assert_eq!(decoded.mods, input.mods);
        assert_eq!(decoded.consumed_mods, input.consumed_mods);
        assert_eq!(decoded.composing, input.composing);
        assert_eq!(decoded.utf8, input.utf8);
        assert_eq!(decoded.unshifted_codepoint, input.unshifted_codepoint);
        assert_eq!(decoded.shifted_codepoint, input.shifted_codepoint);
        assert_eq!(decoded.base_layout_codepoint, input.base_layout_codepoint);
        assert_eq!(decoded.action, input.action);
        assert_eq!(decoded.macos_option_as_alt, input.macos_option_as_alt);
    }

    #[test]
    fn protocol_key_text_limit_is_bounded_for_one_key_event() {
        const {
            assert!(
                PROTOCOL_KEY_TEXT_MAX_BYTES <= 4 * 1024,
                "one key event may retain an unbounded fallback payload"
            );
        }
        let input = KeyInput {
            key: sys::GHOSTTY_KEY_K,
            mods: Mods::SUPER,
            utf8: "\"".repeat(PROTOCOL_KEY_TEXT_MAX_BYTES),
            unshifted_codepoint: 'k' as u32,
            base_layout_codepoint: 'k' as u32,
            action: Some(KeyAction::Press),
            macos_option_as_alt: true,
            ..Default::default()
        };
        let fallback_key = ProtocolKeyInput::try_from(&input).unwrap();
        let request = json!({
            "id": u64::MAX,
            "cmd": "clear-history",
            "surface": u64::MAX,
            "fallback_key": fallback_key,
        });
        let encoded = serde_json::to_vec(&request).unwrap();

        assert!(
            encoded.len() <= WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES,
            "accepted fallback key serialized to {} bytes, above the {}-byte WebSocket limit",
            encoded.len(),
            WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES
        );
    }

    #[test]
    fn protocol_key_input_rejects_raw_ghostty_discriminants() {
        let raw = json!({
            "key": u32::MAX,
            "mods": u16::MAX,
            "consumed_mods": 0,
            "utf8": "",
            "unshifted_codepoint": 0,
            "action": "press",
            "macos_option_as_alt": true,
        });

        assert!(
            serde_json::from_value::<ProtocolKeyInput>(raw).is_err(),
            "raw Ghostty enum and modifier values crossed the protocol boundary"
        );
    }

    #[test]
    fn protocol_key_input_rejects_unknown_or_invalid_semantics() {
        let input = KeyInput {
            key: sys::GHOSTTY_KEY_K,
            mods: Mods::SUPER,
            unshifted_codepoint: 'k' as u32,
            action: Some(KeyAction::Press),
            ..Default::default()
        };
        let valid = serde_json::to_value(ProtocolKeyInput::try_from(&input).unwrap()).unwrap();

        let mut unknown_key = valid.clone();
        unknown_key["key"] = json!("future-key");
        assert!(serde_json::from_value::<ProtocolKeyInput>(unknown_key).is_err());

        let mut unknown_modifier = valid.clone();
        unknown_modifier["mods"]["hyper"] = json!(true);
        assert!(serde_json::from_value::<ProtocolKeyInput>(unknown_modifier).is_err());

        let mut invalid_codepoint = valid.clone();
        invalid_codepoint["unshifted_codepoint"] = json!("ss");
        assert!(serde_json::from_value::<ProtocolKeyInput>(invalid_codepoint).is_err());

        let mut invalid_shifted_codepoint = valid.clone();
        invalid_shifted_codepoint["shifted_codepoint"] = json!("SS");
        assert!(serde_json::from_value::<ProtocolKeyInput>(invalid_shifted_codepoint).is_err());

        let mut invalid_base_layout_codepoint = valid.clone();
        invalid_base_layout_codepoint["base_layout_codepoint"] = json!("11");
        assert!(serde_json::from_value::<ProtocolKeyInput>(invalid_base_layout_codepoint).is_err());

        let mut control_text = valid.clone();
        control_text["utf8"] = json!("\r");
        let control_text = serde_json::from_value::<ProtocolKeyInput>(control_text).unwrap();
        assert!(KeyInput::try_from(control_text).is_err());

        let mut inactive_consumed_modifier = valid;
        inactive_consumed_modifier["consumed_mods"]["shift"] = json!(true);
        let inactive_consumed_modifier =
            serde_json::from_value::<ProtocolKeyInput>(inactive_consumed_modifier).unwrap();
        assert!(KeyInput::try_from(inactive_consumed_modifier).is_err());

        let invalid_key = KeyInput { key: u32::MAX, ..input.clone() };
        assert!(ProtocolKeyInput::try_from(&invalid_key).is_err());
        let invalid_mods = KeyInput { mods: Mods(u16::MAX), ..input.clone() };
        assert!(ProtocolKeyInput::try_from(&invalid_mods).is_err());
        let invalid_codepoint = KeyInput { unshifted_codepoint: 0xD800, ..input.clone() };
        assert!(ProtocolKeyInput::try_from(&invalid_codepoint).is_err());
        let invalid_shifted = KeyInput { shifted_codepoint: 0xD800, ..input.clone() };
        assert!(ProtocolKeyInput::try_from(&invalid_shifted).is_err());
        let oversized_text =
            KeyInput { utf8: "x".repeat(PROTOCOL_KEY_TEXT_MAX_BYTES + 1), ..input };
        assert!(ProtocolKeyInput::try_from(&oversized_text).is_err());
        let invalid_base_layout = KeyInput { base_layout_codepoint: 0xD800, ..input };
        assert!(ProtocolKeyInput::try_from(&invalid_base_layout).is_err());
    }

    #[test]
    fn reload_config_waits_for_owner_application_before_returning() {
        let mux = test_mux();
        let events = mux.subscribe();
        let worker_mux = mux.clone();
        let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            result_tx
                .send(handle_command(&worker_mux, 0, Command::ReloadConfig, &test_writer()))
                .unwrap();
        });
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::ConfigReloadRequested)
        ));
        assert!(matches!(result_rx.try_recv(), Err(TryRecvError::Empty)));

        let target = mux.begin_config_reload_application();
        mux.complete_config_reload_application(target);
        let data = result_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        worker.join().unwrap();
        assert_eq!(data["reloaded"].as_bool(), Some(true));
        assert!(data.get("path").is_some());
    }

    #[cfg(unix)]
    #[test]
    fn paused_server_serves_identity_before_lifecycle_readiness() {
        let dir = TestSocketDir::create("paused-readiness");
        let path = dir.path().join("mux.sock");
        let mux = test_mux();
        let pending = serve_paused(mux, Some(path.clone())).unwrap();
        let mut stream = transport::connect(&path).unwrap();
        writeln!(stream, r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
        stream.flush().unwrap();
        let (response_tx, response_rx) = std::sync::mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut response = String::new();
            let result = BufReader::new(stream).read_line(&mut response).map(|_| response);
            response_tx.send(result).unwrap();
        });
        let response = response_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("ordinary protocol identify waited for lifecycle readiness")
            .unwrap();
        assert_eq!(serde_json::from_str::<Value>(&response).unwrap()["ok"], true);

        let mut lifecycle = transport::connect(&path).unwrap();
        writeln!(lifecycle, r#"{{"id":2,"cmd":"identify"}}"#).unwrap();
        lifecycle.flush().unwrap();
        let mut starting = String::new();
        BufReader::new(&mut lifecycle).read_line(&mut starting).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&starting).unwrap()["data"]["lifecycle_ready"],
            false
        );

        writeln!(lifecycle, r#"{{"id":3,"cmd":"reload-config"}}"#).unwrap();
        lifecycle.flush().unwrap();
        let mut rejected = String::new();
        BufReader::new(&mut lifecycle).read_line(&mut rejected).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&rejected).unwrap()["ok"], false);

        let served = pending.mark_ready().unwrap();
        writeln!(lifecycle, r#"{{"id":4,"cmd":"identify"}}"#).unwrap();
        lifecycle.flush().unwrap();
        let mut ready = String::new();
        BufReader::new(lifecycle).read_line(&mut ready).unwrap();
        assert_eq!(served, path);
        assert_eq!(serde_json::from_str::<Value>(&ready).unwrap()["data"]["lifecycle_ready"], true);
        cleanup(&served);
    }

    #[test]
    fn window_title_commands_emit_requests() {
        let mux = test_mux();
        let events = mux.subscribe();

        let data = handle_command(
            &mux,
            0,
            Command::SetWindowTitle { title: "hello".to_string() },
            &test_writer(),
        )
        .unwrap();
        assert_eq!(data, json!({}));
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title == "hello"
        ));

        handle_command(&mux, 0, Command::ClearWindowTitle, &test_writer()).unwrap();
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)),
            Ok(MuxEvent::WindowTitleRequested(title)) if title.is_empty()
        ));
    }

    #[test]
    fn window_title_osc_uses_osc_0_and_2_and_strips_controls() {
        assert_eq!(window_title_osc("hello").as_slice(), b"\x1b]0;hello\x07\x1b]2;hello\x07");
        assert_eq!(window_title_osc("a\x1bb\x07c").as_slice(), b"\x1b]0;a b c\x07\x1b]2;a b c\x07");
    }

    #[test]
    fn title_changed_event_includes_authoritative_surface_title() {
        let mux = Mux::new(
            "title-event-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "printf '\\033]2;server title\\007'; exec cat".to_string(),
                ]),
                ..SurfaceOptions::default()
            },
        );
        let events = mux.subscribe();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        loop {
            match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                MuxEvent::TitleChanged { surface: id, title }
                    if id == surface.id && title.as_ref() == "server title" =>
                {
                    break;
                }
                _ => {}
            }
        }

        assert_eq!(surface.title(), "server title");
        assert_eq!(
            subscribed_event_json(&MuxEvent::TitleChanged {
                surface: surface.id,
                title: Arc::<str>::from("server title"),
            }),
            json!({
                "event": "title-changed",
                "surface": surface.id,
                "title": "server title",
            })
        );
    }

    #[test]
    fn agent_changed_event_preserves_the_scoped_agent_state() {
        assert_eq!(
            subscribed_event_json(&MuxEvent::AgentChanged {
                surface: 7,
                state: Arc::<str>::from("working"),
                source: Arc::<str>::from("hook"),
                session: Some(Arc::<str>::from("review")),
                updated_at_ms: 41,
            }),
            json!({
                "event": "agent-changed",
                "surface": 7,
                "state": "working",
                "source": "hook",
                "session": "review",
                "updated_at_ms": 41,
            })
        );
    }

    #[test]
    fn graphics_status_events_preserve_structured_localization_data() {
        assert_eq!(
            subscribed_event_json(&MuxEvent::GraphicsStatus(
                GraphicsStatus::KittyImageBudgetUpdateFailed {
                    retry_exhausted: true,
                    summary: Arc::<str>::from("surface 7: offline"),
                },
            )),
            json!({
                "event": "graphics-status",
                "kind": "kitty-image-budget-update-failed",
                "retry_exhausted": true,
                "summary": "surface 7: offline",
            })
        );
        assert_eq!(
            subscribed_event_json(&MuxEvent::GraphicsStatus(
                GraphicsStatus::CellPixelUpdateRetriesExhausted {
                    attempts: 5,
                    remaining: 2,
                    cell_pixels: (8, 16),
                },
            )),
            json!({
                "event": "graphics-status",
                "kind": "cell-pixel-update-retries-exhausted",
                "attempts": 5,
                "remaining": 2,
                "cell_width": 8,
                "cell_height": 16,
            })
        );
    }

    #[test]
    fn scroll_surface_emits_one_scroll_changed_event() {
        let mux = test_mux();
        let surface = mux.new_workspace(None, Some((20, 4))).unwrap();
        surface
            .try_with_terminal(|term| {
                for i in 0..20 {
                    term.vt_write(format!("line{i}\r\n").as_bytes());
                }
            })
            .unwrap();
        let shared_scrollbar = surface.try_with_terminal(|term| term.scrollbar().unwrap()).unwrap();
        let view_scrollbar = surface.view_scrollbar().unwrap();
        let events = mux.subscribe();

        handle_command(
            &mux,
            0,
            Command::ScrollSurface { surface: surface.id, delta: -5 },
            &test_writer(),
        )
        .unwrap();

        let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            event,
            MuxEvent::ScrollChanged { surface: id, offset, at_bottom: false }
                if id == surface.id && offset > 0
        ));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
        assert_eq!(
            surface.try_with_terminal(|term| term.scrollbar().unwrap()).unwrap(),
            shared_scrollbar,
            "a backend view scroll must not mutate the shared terminal runtime"
        );
        assert_ne!(surface.view_scrollbar().unwrap(), view_scrollbar);

        handle_command(
            &mux,
            0,
            Command::ScrollSurface { surface: surface.id, delta: 0 },
            &test_writer(),
        )
        .unwrap();
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }
}
