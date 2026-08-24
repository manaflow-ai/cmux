//! Long-lived per-terminal process runtime.
//!
//! A terminal host owns the PTY master, child, authoritative Ghostty parser,
//! replay snapshot, and viewer-size arbitration.  The mux process only keeps
//! an authenticated mirror connection.  Host records contain no daemon-local
//! ids, so a replacement mux can adopt the same shell after a crash.

use std::path::{Path, PathBuf};

use ghostty_vt::{
    KeyInput, KittyGraphicsLimits, KittyImageAlias, KittyImageIdCursors, KittyReplayState, Rgb,
    TerminalColorOverrides,
};
use serde::{Deserialize, Serialize};

use crate::surface::{
    CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR, CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
    CLEAR_HISTORY_PRESERVATION_ERROR, CLEAR_HISTORY_STREAM_TIMEOUT_ERROR,
    CLEAR_HISTORY_STREAM_WAIT_TIMEOUT, ClearHistoryDelivery, ClearHistoryFailure,
    ClearHistoryTransition, DefaultColors, SurfaceOptions, TerminalStreamProgress,
    apply_clear_history_transition, replace_ghostty_cursor_defaults, write_clear_history_fallback,
};
use crate::terminal_host::{
    CapabilityRights, CapabilityStore, CapabilityToken, ClientHello, ClientRole, HostBootstrap,
    HostHello, HostIncarnation, HostReady, TerminalId,
};
use crate::terminal_host_protocol::{
    CLEAR_HISTORY_ACK_AMBIGUOUS, CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE,
    CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT, CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED,
    CLEAR_HISTORY_ACK_OK, CLEAR_HISTORY_ACK_PRESERVATION_FAILED, CLEAR_HISTORY_ACK_STREAM_TIMEOUT,
    FLAG_COLORS_FOLLOW, FLAG_LAUNCH_ACTIVATION_REQUIRED, FLAG_SMART_RENDERER,
    FLAG_VIEWER_SIZE_ACKS, Frame, HostLaunchFailure, HostLaunchFailureKind,
    KITTY_IMAGE_ALIAS_COUNT_LEN, KITTY_IMAGE_ALIAS_ENCODED_LEN, LAUNCH_ACTIVATION_PROTOCOL_VERSION,
    MAX_FRAME_PAYLOAD, MAX_KITTY_IMAGE_ALIASES, MessageKind, PROTOCOL_VERSION,
    RESIZE_ACK_CANONICAL_CHANGED, TerminalExit, decode_host_launch_failure, decode_terminal_exit,
    encode_host_launch_failure, encode_terminal_exit, read_frame, wait_for_native_child_status,
    write_frame,
};

const HOST_RECORD_VERSION: u32 = 4;
const LEGACY_PROTOCOL_VERSION: u16 = 1;
const SMART_RENDERER_PROTOCOL_VERSION: u16 = 3;
const HOST_EXIT_RECORD_VERSION: u32 = 1;
const MAX_LAUNCH_PAYLOAD: usize = 1024 * 1024;
const MAX_STRING: usize = 256 * 1024;
const MAX_BLOB: usize = crate::surface::VT_REPLAY_MAX_BYTES;
const MAX_ARGV: usize = 256;
const MAX_ENV: usize = 1024;
const MAX_RENDERER_CAPABILITY_TTL: std::time::Duration = std::time::Duration::from_secs(60);
pub(crate) const CONTROL_RESPONSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
const HOST_HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
const HOST_CONNECT_RETRY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);
const HOST_CONNECT_RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_millis(10);
const TERMINAL_HOST_PUBLICATION_LOCK_FILE: &str = ".publication.lock";
// Keep live PTY backpressure independent from the extra headroom needed by
// one maximum Resized + Colors + targeted acknowledgement transition.
const MAX_HOST_CLIENT_OUTPUT_QUEUED_BYTES: usize = 8 * 1024 * 1024;
const MAX_HOST_CLIENT_STATE_QUEUED_BYTES: usize = MAX_FRAME_PAYLOAD
    + MAX_TERMINAL_COLORS_PAYLOAD
    + CELL_PIXEL_SIZE_ENCODED_LEN
    + KITTY_REPLAY_STATE_ENCODED_LEN
    + 3 * crate::terminal_host_protocol::HEADER_LEN;
const MAX_HOST_CLIENT_QUEUED_BYTES: usize =
    MAX_HOST_CLIENT_OUTPUT_QUEUED_BYTES + MAX_HOST_CLIENT_STATE_QUEUED_BYTES;
const HOST_SNAPSHOT_BOUNDARY_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(1500);
const MAX_SMART_RETAINED_BYTES: usize = 8 * 1024 * 1024;
const MAX_SMART_RETAINED_FRAMES: usize = 4096;
const HOST_PARSER_QUEUE_CAPACITY: usize = 256;
const MAX_HOST_PARSER_QUEUED_BYTES: usize = 16 * 1024 * 1024;
const HOST_START_NONCE_LEN: usize = 32;
const TERMINAL_DIMENSION_MAX: u16 = 10_000;
const TERMINAL_CELL_AREA_MAX: u64 = 4_000_000;
const DEFAULT_CELL_PIXELS: (u16, u16) = (8, 16);
const CELL_PIXEL_SIZE_ENCODED_LEN: usize = 2 * size_of::<u16>();
const KITTY_GRAPHICS_LIMITS_ENCODED_LEN: usize = 4 * size_of::<u64>();
const KITTY_REPLAY_STATE_ENCODED_LEN: usize =
    KITTY_GRAPHICS_LIMITS_ENCODED_LEN + 5 * size_of::<u32>();
const TERMINAL_COLORS_WIRE_VERSION_V1: u16 = 1;
pub const TERMINAL_COLORS_WIRE_VERSION: u16 = 2;
pub const MAX_TERMINAL_COLORS_PAYLOAD: usize = 8 + 3 * 3 + 2 + 256 * 4;
const _: () = assert!(
    2 * size_of::<u16>()
        + size_of::<u32>()
        + crate::surface::VT_REPLAY_MAX_BYTES
        + KITTY_IMAGE_ALIAS_COUNT_LEN
        + MAX_KITTY_IMAGE_ALIASES * KITTY_IMAGE_ALIAS_ENCODED_LEN
        + CELL_PIXEL_SIZE_ENCODED_LEN
        + KITTY_REPLAY_STATE_ENCODED_LEN
        <= MAX_FRAME_PAYLOAD
);
const _: () = assert!(SMART_RENDERER_PROTOCOL_VERSION <= PROTOCOL_VERSION);

pub(crate) fn normalize_terminal_geometry(cols: u16, rows: u16) -> anyhow::Result<(u16, u16)> {
    let cols = cols.clamp(1, TERMINAL_DIMENSION_MAX);
    let rows = rows.clamp(1, TERMINAL_DIMENSION_MAX);
    if u64::from(cols) * u64::from(rows) > TERMINAL_CELL_AREA_MAX {
        anyhow::bail!(
            "terminal geometry {cols}x{rows} exceeds the {TERMINAL_CELL_AREA_MAX}-cell limit"
        );
    }
    Ok((cols, rows))
}

pub fn validate_kitty_image_aliases(aliases: &[KittyImageAlias]) -> anyhow::Result<()> {
    if aliases.len() > MAX_KITTY_IMAGE_ALIASES {
        anyhow::bail!("terminal-host Kitty image alias count is too large");
    }
    // Repeated image numbers preserve Kitty's assignment history. Image IDs
    // remain unique identities within a snapshot.
    let mut image_ids = std::collections::HashSet::with_capacity(aliases.len());
    for alias in aliases {
        if alias.image_id == 0 || alias.image_number == 0 {
            anyhow::bail!("terminal-host Kitty image aliases must be nonzero");
        }
        if !image_ids.insert(alias.image_id) {
            anyhow::bail!("duplicate terminal-host Kitty image alias ID");
        }
    }
    Ok(())
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TerminalHostRecord {
    pub record_version: u32,
    pub terminal_id: String,
    pub incarnation: String,
    pub endpoint: String,
    pub owner_token: String,
    /// PID of the terminal-host process (not the child running inside its
    /// PTY). A PID by itself is never sufficient proof of liveness because it
    /// can be reused after a crash.
    #[serde(default)]
    pub host_pid: u32,
    /// Random process-start nonce naming a file lock held for exactly this
    /// host process lifetime. The PID + locked nonce gives cleanup code a
    /// positive, PID-reuse-safe liveness proof.
    #[serde(default)]
    pub host_start_nonce: String,
    /// Deprecated compatibility placement hint. Discovery authority is the
    /// stable terminal identity + endpoint capability; the canonical
    /// workspace registry owns placement in the stacked follow-up.
    #[serde(default)]
    pub workspace_key: String,
    /// Additive control capability. Missing/false records belong to legacy
    /// hosts and must never receive the unknown SetDefaults message.
    #[serde(default)]
    pub supports_set_defaults: bool,
    /// Additive control capability. Missing/false records belong to legacy
    /// hosts and must never receive the unknown ClearHistory message.
    #[serde(default)]
    pub supports_clear_history: bool,
    /// Additive control capability. Missing/false records belong to legacy
    /// hosts whose fire-and-forget Terminate command has no receipt.
    #[serde(default)]
    pub supports_terminate_ack: bool,
}

impl std::fmt::Debug for TerminalHostRecord {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TerminalHostRecord")
            .field("record_version", &self.record_version)
            .field("terminal_id", &self.terminal_id)
            .field("incarnation", &self.incarnation)
            .field("endpoint", &self.endpoint)
            .field("owner_token", &"[REDACTED]")
            .field("host_pid", &self.host_pid)
            .field("host_start_nonce", &self.host_start_nonce)
            .field("workspace_key", &self.workspace_key)
            .field("supports_set_defaults", &self.supports_set_defaults)
            .field("supports_clear_history", &self.supports_clear_history)
            .field("supports_terminate_ack", &self.supports_terminate_ack)
            .finish()
    }
}

impl TerminalHostRecord {
    pub fn record_path(&self, root: &Path) -> PathBuf {
        root.join(format!("{}.json", self.terminal_id))
    }
}

/// Host-owned completion sidecar. It is written and fsynced after the final
/// PTY bytes are published but before the sequenced Exit frame. The mux
/// removes it only after the same outcome is durable in SQLite, which makes
/// removal an acknowledgement and keeps exit status recoverable across a
/// daemon crash.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalHostExitRecord {
    pub record_version: u32,
    pub terminal_id: String,
    pub incarnation: String,
    pub exit: TerminalExit,
}

impl TerminalHostExitRecord {
    pub fn new(identity: &TerminalHostIdentity, exit: TerminalExit) -> Self {
        Self {
            record_version: HOST_EXIT_RECORD_VERSION,
            terminal_id: identity.terminal_id.clone(),
            incarnation: identity.incarnation.clone(),
            exit,
        }
    }

    pub fn record_path(&self, root: &Path) -> PathBuf {
        root.join(format!("{}.exit", self.terminal_id))
    }
}

#[derive(Debug, Clone)]
pub struct HostSnapshot {
    pub cols: u16,
    pub rows: u16,
    /// Authoritative PTY and parser cell metrics at the snapshot boundary.
    pub cell_pixels: (u16, u16),
    pub replay: Vec<u8>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
    pub kitty_state: KittyReplayState,
    /// Global live-stream sequence at the atomic Snapshot/Colors boundary.
    pub sequence_boundary: u64,
    /// Complete application-authored color state at `sequence_boundary`.
    pub colors: TerminalColorOverrides,
    pub pid: Option<u32>,
    pub command: Vec<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalHostIdentity {
    pub terminal_id: String,
    pub incarnation: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalHostLiveness {
    /// The exact process-start nonce is still locked by a host process.
    Live,
    /// The nonce lock is no longer held (or the recorded PID does not exist),
    /// which positively proves that this exact host incarnation ended.
    Dead,
    /// The proof could not be inspected safely. Callers must retain the
    /// record and retry; this state is never permission to reap a terminal.
    Indeterminate,
}

/// A short-lived, one-use credential that can open the terminal host socket
/// directly without receiving the durable owner/admin secret.
#[derive(Clone, PartialEq, Eq)]
pub struct RendererGrant {
    pub endpoint: String,
    pub terminal_id: String,
    pub incarnation: String,
    pub token: String,
    pub rights: CapabilityRights,
    pub protocol_version: u16,
}

impl std::fmt::Debug for RendererGrant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RendererGrant")
            .field("endpoint", &self.endpoint)
            .field("terminal_id", &self.terminal_id)
            .field("incarnation", &self.incarnation)
            .field("token", &"[REDACTED]")
            .field("rights", &self.rights)
            .finish()
    }
}

/// Encode a complete dynamic render-metadata state.
///
/// Wire layout is little-endian: schema_version:u16, flags:u16 (foreground,
/// background, cursor color, cursor visual), palette_count:u16, reserved:u16,
/// each flagged RGB in that order, the atomic cursor style/blink pair when
/// flagged, then palette_count repetitions of index:u8 + RGB. RGB and palette
/// fields remain sparse theme overrides. Version 2 producers populate the
/// host-resolved cursor visual. An absent visual is the version 1 fallback:
/// the cursor state is unknown and the receiving renderer must preserve its
/// current raw-VT/default cursor rather than infer a reset.
pub fn encode_terminal_color_overrides(colors: &TerminalColorOverrides) -> Vec<u8> {
    let cursor_visual =
        colors.cursor_visual.expect("terminal-host Colors v2 requires a resolved cursor visual");
    let mut flags = 0u16;
    flags |= colors.foreground.is_some() as u16;
    flags |= (colors.background.is_some() as u16) << 1;
    flags |= (colors.cursor.is_some() as u16) << 2;
    flags |= 1 << 3;
    let palette_count = colors.palette.iter().filter(|color| color.is_some()).count() as u16;
    let rgb_bytes = (flags & 0b111).count_ones() as usize * 3;
    let mut payload = Vec::with_capacity(8 + rgb_bytes + 2 + usize::from(palette_count) * 4);
    payload.extend_from_slice(&TERMINAL_COLORS_WIRE_VERSION.to_le_bytes());
    payload.extend_from_slice(&flags.to_le_bytes());
    payload.extend_from_slice(&palette_count.to_le_bytes());
    payload.extend_from_slice(&0u16.to_le_bytes());
    for color in [colors.foreground, colors.background, colors.cursor].into_iter().flatten() {
        payload.extend_from_slice(&[color.r, color.g, color.b]);
    }
    let (style, blink) = cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => 1,
        ghostty_vt::CursorShape::Underline => 2,
        ghostty_vt::CursorShape::Bar => 3,
    };
    payload.extend_from_slice(&[style, blink as u8]);
    for (index, color) in colors.palette.iter().enumerate() {
        if let Some(color) = color {
            payload.extend_from_slice(&[index as u8, color.r, color.g, color.b]);
        }
    }
    debug_assert!(payload.len() <= MAX_TERMINAL_COLORS_PAYLOAD);
    payload
}

pub fn decode_terminal_color_overrides(payload: &[u8]) -> anyhow::Result<TerminalColorOverrides> {
    if payload.len() < 8 || payload.len() > MAX_TERMINAL_COLORS_PAYLOAD {
        anyhow::bail!("terminal-host Colors payload length is out of range");
    }
    let version = u16::from_le_bytes(payload[0..2].try_into().unwrap());
    let flags = u16::from_le_bytes(payload[2..4].try_into().unwrap());
    let palette_count = u16::from_le_bytes(payload[4..6].try_into().unwrap()) as usize;
    let reserved = u16::from_le_bytes(payload[6..8].try_into().unwrap());
    let allowed_flags = match version {
        TERMINAL_COLORS_WIRE_VERSION_V1 => 0b111,
        TERMINAL_COLORS_WIRE_VERSION if flags & 0b1000 != 0 => 0b1111,
        TERMINAL_COLORS_WIRE_VERSION => {
            anyhow::bail!("terminal-host Colors v2 is missing the cursor visual")
        }
        _ => anyhow::bail!("unsupported terminal-host Colors payload version"),
    };
    if flags & !allowed_flags != 0 || reserved != 0 {
        anyhow::bail!("unsupported terminal-host Colors payload header");
    }
    if palette_count > 256 {
        anyhow::bail!("terminal-host Colors palette count is out of range");
    }
    let expected = 8
        + (flags & 0b111).count_ones() as usize * 3
        + usize::from(flags & 0b1000 != 0) * 2
        + palette_count * 4;
    if payload.len() != expected {
        anyhow::bail!("malformed terminal-host Colors payload");
    }
    fn take_rgb(payload: &[u8], offset: &mut usize) -> Rgb {
        let color = Rgb { r: payload[*offset], g: payload[*offset + 1], b: payload[*offset + 2] };
        *offset += 3;
        color
    }
    let mut offset = 8;
    let foreground = (flags & 1 != 0).then(|| take_rgb(payload, &mut offset));
    let background = (flags & 2 != 0).then(|| take_rgb(payload, &mut offset));
    let cursor = (flags & 4 != 0).then(|| take_rgb(payload, &mut offset));
    let cursor_visual = if flags & 8 != 0 {
        let style = match payload[offset] {
            1 => ghostty_vt::CursorShape::Block,
            2 => ghostty_vt::CursorShape::Underline,
            3 => ghostty_vt::CursorShape::Bar,
            _ => anyhow::bail!("terminal-host Colors cursor style is out of range"),
        };
        let blink = match payload[offset + 1] {
            0 => false,
            1 => true,
            _ => anyhow::bail!("terminal-host Colors cursor blink is out of range"),
        };
        offset += 2;
        Some((style, blink))
    } else {
        None
    };
    let mut palette = [None; 256];
    for _ in 0..palette_count {
        let index = payload[offset] as usize;
        if palette[index].is_some() {
            anyhow::bail!("duplicate terminal-host Colors palette index");
        }
        palette[index] =
            Some(Rgb { r: payload[offset + 1], g: payload[offset + 2], b: payload[offset + 3] });
        offset += 4;
    }
    Ok(TerminalColorOverrides { foreground, background, cursor, cursor_visual, palette })
}

#[derive(Debug)]
pub(crate) struct DeferredCellPixelAck;

impl std::fmt::Display for DeferredCellPixelAck {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(
            "terminal host cell pixel acknowledgement is pending; \
             the late response will reconcile the mirror",
        )
    }
}

impl std::error::Error for DeferredCellPixelAck {}

#[derive(Debug)]
pub(crate) struct CellPixelRequestDeadlineElapsed;

impl std::fmt::Display for CellPixelRequestDeadlineElapsed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("terminal host cell pixel size deadline elapsed before request")
    }
}

impl std::error::Error for CellPixelRequestDeadlineElapsed {}

#[cfg(unix)]
mod unix {
    use std::collections::{HashMap, HashSet, VecDeque};
    use std::ffi::CString;
    use std::fs::{self, File, OpenOptions};
    use std::io as std_io;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, RawFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::mpsc::{
        Receiver, RecvTimeoutError, Sender, SyncSender, channel as mpsc_channel, sync_channel,
    };
    use std::sync::{Arc, Condvar, Mutex, TryLockError, Weak};
    use std::thread;
    use std::time::{Duration, Instant};

    use anyhow::Context;
    use cmux_pty::{ChildKiller, MasterPty, PtyCommand, PtyOpenError, PtySize};
    use ghostty_vt::{Callbacks, CursorShape, Terminal};

    use super::*;

    static RECORD_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);
    const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);
    const HOST_KILL_WAIT: Duration = Duration::from_secs(2);
    const HOST_PTY_DRAIN_GRACE: Duration = Duration::from_millis(250);
    const HOST_FORCED_DRAIN_WINDOW: Duration = Duration::from_millis(100);
    const HOST_LAUNCH_ROLLBACK_WAIT: Duration = Duration::from_secs(4);
    const HOST_LAUNCH_OWNER_TIMEOUT: Duration = Duration::from_secs(5);
    const HOST_CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
    const HOST_HANDSHAKE_TRANSIENT_RETRIES: usize = 1;
    const HOST_EXIT_PERSIST_RETRY_MIN: Duration = Duration::from_millis(100);
    const HOST_EXIT_PERSIST_RETRY_MAX: Duration = Duration::from_secs(5);
    const HOST_EXIT_PERSIST_REPORT_INTERVAL: Duration = Duration::from_secs(60);

    fn pty_size(cols: u16, rows: u16, cell_pixels: (u16, u16)) -> anyhow::Result<PtySize> {
        let pixel_width = cols.checked_mul(cell_pixels.0).ok_or_else(|| {
            anyhow::anyhow!(
                "terminal pixel width exceeds {}: {cols} columns at {} pixels per cell",
                u16::MAX,
                cell_pixels.0
            )
        })?;
        let pixel_height = rows.checked_mul(cell_pixels.1).ok_or_else(|| {
            anyhow::anyhow!(
                "terminal pixel height exceeds {}: {rows} rows at {} pixels per cell",
                u16::MAX,
                cell_pixels.1
            )
        })?;
        Ok(PtySize { rows, cols, pixel_width, pixel_height })
    }

    fn kitty_graphics_limits_within(
        candidate: KittyGraphicsLimits,
        ceiling: KittyGraphicsLimits,
    ) -> bool {
        candidate.image_bytes <= ceiling.image_bytes
            && candidate.inflight_bytes <= ceiling.inflight_bytes
            && candidate.images <= ceiling.images
            && candidate.placements <= ceiling.placements
    }

    struct SpawnedHostProcess {
        child: Option<std::process::Child>,
    }

    impl SpawnedHostProcess {
        fn child_mut(&mut self) -> &mut std::process::Child {
            self.child.as_mut().expect("terminal-host child is present")
        }

        fn into_child(mut self) -> std::process::Child {
            self.child.take().expect("terminal-host child is present")
        }

        fn wait_timeout(&mut self, timeout: Duration) -> bool {
            let deadline = Instant::now() + timeout;
            loop {
                let Some(child) = self.child.as_mut() else { return true };
                match child.try_wait() {
                    Ok(Some(_)) => {
                        self.child.take();
                        return true;
                    }
                    Ok(None) if Instant::now() < deadline => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Ok(None) | Err(_) => return false,
                }
            }
        }
    }

    impl Drop for SpawnedHostProcess {
        fn drop(&mut self) {
            if let Some(child) = self.child.as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    #[derive(Debug)]
    struct HostLaunch {
        endpoint: String,
        record_path: String,
        term: String,
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
        scrollback: usize,
        cwd: Option<String>,
        command: Vec<String>,
        extra_env: Vec<(String, String)>,
        default_colors: DefaultColors,
        kitty_graphics_limits: KittyGraphicsLimits,
    }

    impl HostLaunch {
        fn encode(&self) -> anyhow::Result<Vec<u8>> {
            if self.command.is_empty() || self.command.len() > MAX_ARGV {
                anyhow::bail!("terminal-host command count is out of range");
            }
            if self.extra_env.len() > MAX_ENV {
                anyhow::bail!("terminal-host environment count is out of range");
            }
            let (cols, rows) = normalize_terminal_geometry(self.cols, self.rows)?;
            let cell_pixels = (self.cell_pixels.0.max(1), self.cell_pixels.1.max(1));
            pty_size(cols, rows, cell_pixels)?;
            let mut output = Vec::new();
            put_string(&mut output, &self.endpoint)?;
            put_string(&mut output, &self.record_path)?;
            put_string(&mut output, &self.term)?;
            output.extend_from_slice(&cols.to_le_bytes());
            output.extend_from_slice(&rows.to_le_bytes());
            output.extend_from_slice(
                &u32::try_from(self.scrollback)
                    .map_err(|_| anyhow::anyhow!("terminal-host scrollback is too large"))?
                    .to_le_bytes(),
            );
            put_optional_string(&mut output, self.cwd.as_deref())?;
            output.extend_from_slice(&(self.command.len() as u16).to_le_bytes());
            for argument in &self.command {
                put_string(&mut output, argument)?;
            }
            output.extend_from_slice(&(self.extra_env.len() as u16).to_le_bytes());
            for (key, value) in &self.extra_env {
                put_string(&mut output, key)?;
                put_string(&mut output, value)?;
            }
            encode_default_colors(&mut output, self.default_colors);
            output.extend_from_slice(&cell_pixels.0.to_le_bytes());
            output.extend_from_slice(&cell_pixels.1.to_le_bytes());
            encode_kitty_graphics_limits(&mut output, self.kitty_graphics_limits)?;
            if output.len() > MAX_LAUNCH_PAYLOAD {
                anyhow::bail!("terminal-host launch payload is too large");
            }
            Ok(output)
        }

        fn decode(payload: &[u8]) -> anyhow::Result<Self> {
            let mut decoder = PayloadDecoder::new(payload);
            let endpoint = decoder.string()?;
            let record_path = decoder.string()?;
            let term = decoder.string()?;
            let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
            let scrollback = decoder.u32()? as usize;
            let cwd = decoder.optional_string()?;
            let argc = decoder.u16()? as usize;
            if argc == 0 || argc > MAX_ARGV {
                anyhow::bail!("terminal-host command count is out of range");
            }
            let mut command = Vec::with_capacity(argc);
            for _ in 0..argc {
                command.push(decoder.string()?);
            }
            let envc = decoder.u16()? as usize;
            if envc > MAX_ENV {
                anyhow::bail!("terminal-host environment count is out of range");
            }
            let mut extra_env = Vec::with_capacity(envc);
            for _ in 0..envc {
                extra_env.push((decoder.string()?, decoder.string()?));
            }
            let default_colors = decode_default_colors(&mut decoder)?;
            let cell_pixels = (decoder.u16()?.max(1), decoder.u16()?.max(1));
            pty_size(cols, rows, cell_pixels)?;
            let kitty_graphics_limits = decode_kitty_graphics_limits(&mut decoder)?;
            decoder.finish()?;
            Ok(Self {
                endpoint,
                record_path,
                term,
                cols,
                rows,
                cell_pixels,
                scrollback,
                cwd,
                command,
                extra_env,
                default_colors,
                kitty_graphics_limits,
            })
        }
    }

    fn encode_default_colors(output: &mut Vec<u8>, colors: DefaultColors) {
        let mut flags = 0u8;
        flags |= colors.fg.is_some() as u8;
        flags |= (colors.bg.is_some() as u8) << 1;
        flags |= (colors.cursor.is_some() as u8) << 2;
        flags |= (colors.cursor_style.is_some() as u8) << 3;
        flags |= (colors.cursor_blink.is_some() as u8) << 4;
        flags |= (colors.selection_bg.is_some() as u8) << 5;
        flags |= (colors.selection_fg.is_some() as u8) << 6;
        output.push(flags);
        for color in [colors.fg, colors.bg, colors.cursor, colors.selection_bg, colors.selection_fg]
            .into_iter()
            .flatten()
        {
            output.extend_from_slice(&[color.r, color.g, color.b]);
        }
        if let Some(style) = colors.cursor_style {
            output.push(match style {
                CursorShape::Block => 1,
                CursorShape::BlockHollow => 2,
                CursorShape::Bar => 3,
                CursorShape::Underline => 4,
            });
        }
        if let Some(blink) = colors.cursor_blink {
            output.push(blink as u8);
        }
        let palette_count = colors.palette.iter().filter(|color| color.is_some()).count() as u16;
        output.extend_from_slice(&palette_count.to_le_bytes());
        for (index, color) in colors.palette.iter().enumerate() {
            if let Some(color) = color {
                output.extend_from_slice(&[index as u8, color.r, color.g, color.b]);
            }
        }
    }

    fn decode_default_colors(decoder: &mut PayloadDecoder<'_>) -> anyhow::Result<DefaultColors> {
        let flags = decoder.u8()?;
        if flags & !0b111_1111 != 0 {
            anyhow::bail!("terminal-host default-color flags are out of range");
        }
        let fg = if flags & 1 != 0 { Some(decoder.rgb()?) } else { None };
        let bg = if flags & 2 != 0 { Some(decoder.rgb()?) } else { None };
        let cursor = if flags & 4 != 0 { Some(decoder.rgb()?) } else { None };
        let selection_bg = if flags & 32 != 0 { Some(decoder.rgb()?) } else { None };
        let selection_fg = if flags & 64 != 0 { Some(decoder.rgb()?) } else { None };
        let cursor_style = if flags & 8 != 0 {
            Some(match decoder.u8()? {
                1 => CursorShape::Block,
                2 => CursorShape::BlockHollow,
                3 => CursorShape::Bar,
                4 => CursorShape::Underline,
                _ => anyhow::bail!("terminal-host default cursor style is out of range"),
            })
        } else {
            None
        };
        let cursor_blink = if flags & 16 != 0 {
            Some(match decoder.u8()? {
                0 => false,
                1 => true,
                _ => anyhow::bail!("terminal-host default cursor blink is out of range"),
            })
        } else {
            None
        };
        let palette_count = decoder.u16()? as usize;
        if palette_count > 256 {
            anyhow::bail!("terminal-host default palette count is out of range");
        }
        let mut palette = [None; 256];
        for _ in 0..palette_count {
            let index = decoder.u8()? as usize;
            if palette[index].is_some() {
                anyhow::bail!("duplicate terminal-host default palette index");
            }
            palette[index] = Some(decoder.rgb()?);
        }
        Ok(DefaultColors {
            fg,
            bg,
            cursor,
            selection_bg,
            selection_fg,
            cursor_style,
            cursor_blink,
            palette,
        })
    }

    fn encode_default_colors_payload(colors: DefaultColors) -> Vec<u8> {
        let mut payload = Vec::new();
        encode_default_colors(&mut payload, colors);
        payload
    }

    fn decode_default_colors_payload(payload: &[u8]) -> anyhow::Result<DefaultColors> {
        let mut decoder = PayloadDecoder::new(payload);
        let colors = decode_default_colors(&mut decoder)?;
        decoder.finish()?;
        Ok(colors)
    }

    enum ControlResponseWaiter {
        Blocking { kind: MessageKind, sender: SyncSender<Frame> },
        DeferredCellPixel { expected: (u16, u16) },
    }

    #[derive(Debug, Clone)]
    pub(crate) enum DeferredCellPixelResolution {
        Response(Frame),
        Disconnected,
    }

    pub(crate) type DeferredCellPixelHandler =
        Arc<dyn Fn(u64, (u16, u16), DeferredCellPixelResolution) + Send + Sync + 'static>;

    pub(crate) struct ControlResponses {
        waiters: Mutex<HashMap<u64, ControlResponseWaiter>>,
        deferred_cell_pixel_handler: Mutex<Option<DeferredCellPixelHandler>>,
        latest_cell_pixel_ack: AtomicU64,
    }

    impl ControlResponses {
        fn new() -> Self {
            Self {
                waiters: Mutex::new(HashMap::new()),
                deferred_cell_pixel_handler: Mutex::new(None),
                latest_cell_pixel_ack: AtomicU64::new(0),
            }
        }

        #[cfg(test)]
        pub(crate) fn new_for_test() -> Self {
            Self::new()
        }

        #[cfg(test)]
        pub(crate) fn invoke_deferred_cell_pixel_handler_for_test(
            &self,
            request_id: u64,
            expected: (u16, u16),
            resolution: DeferredCellPixelResolution,
        ) {
            if let Some(handler) = self.deferred_cell_pixel_handler.lock().unwrap().clone() {
                handler(request_id, expected, resolution);
            }
        }

        #[cfg(test)]
        pub(crate) fn resolve(&self, frame: &Frame) -> bool {
            self.resolve_after(frame, || {})
        }

        pub(crate) fn resolve_after(&self, frame: &Frame, before_resolve: impl FnOnce()) -> bool {
            let waiter = self.waiters.lock().unwrap().remove(&frame.request_id);
            match waiter {
                Some(ControlResponseWaiter::Blocking { kind, sender }) => {
                    if kind != frame.kind {
                        return false;
                    }
                    if frame.kind == MessageKind::CellPixelSizeAck {
                        self.latest_cell_pixel_ack.fetch_max(frame.request_id, Ordering::AcqRel);
                    }
                    before_resolve();
                    let _ = sender.try_send(frame.clone());
                    true
                }
                Some(ControlResponseWaiter::DeferredCellPixel { expected }) => {
                    if frame.kind != MessageKind::CellPixelSizeAck {
                        return false;
                    }
                    self.latest_cell_pixel_ack.fetch_max(frame.request_id, Ordering::AcqRel);
                    before_resolve();
                    let handler = self.deferred_cell_pixel_handler.lock().unwrap().clone();
                    if let Some(handler) = handler {
                        handler(
                            frame.request_id,
                            expected,
                            DeferredCellPixelResolution::Response(frame.clone()),
                        );
                    }
                    true
                }
                None => false,
            }
        }

        fn defer_cell_pixel(&self, request_id: u64, expected: (u16, u16)) -> bool {
            let mut waiters = self.waiters.lock().unwrap();
            let Some(waiter) = waiters.get_mut(&request_id) else { return false };
            if !matches!(
                waiter,
                ControlResponseWaiter::Blocking { kind: MessageKind::CellPixelSizeAck, .. }
            ) {
                return false;
            }
            *waiter = ControlResponseWaiter::DeferredCellPixel { expected };
            true
        }

        pub(crate) fn fail_all(&self) {
            let deferred = {
                let mut waiters = self.waiters.lock().unwrap();
                waiters
                    .drain()
                    .filter_map(|(request_id, waiter)| match waiter {
                        ControlResponseWaiter::DeferredCellPixel { expected } => {
                            Some((request_id, expected))
                        }
                        ControlResponseWaiter::Blocking { .. } => None,
                    })
                    .collect::<Vec<_>>()
            };
            let handler = self.deferred_cell_pixel_handler.lock().unwrap().clone();
            if let Some(handler) = handler {
                for (request_id, expected) in deferred {
                    handler(request_id, expected, DeferredCellPixelResolution::Disconnected);
                }
            }
        }

        pub(crate) fn set_deferred_cell_pixel_handler(&self, handler: DeferredCellPixelHandler) {
            *self.deferred_cell_pixel_handler.lock().unwrap() = Some(handler);
        }

        pub(crate) fn latest_cell_pixel_ack(&self) -> u64 {
            self.latest_cell_pixel_ack.load(Ordering::Acquire)
        }
    }

    pub struct HostAttachment {
        pub record: TerminalHostRecord,
        pub record_path: PathBuf,
        pub snapshot: HostSnapshot,
        protocol_version: u16,
        smart_renderer: bool,
        reader: Option<UnixStream>,
        writer: Arc<Mutex<UnixStream>>,
        control_responses: Arc<ControlResponses>,
        next_request: AtomicU64,
        viewer_size: Mutex<Option<(u16, u16)>>,
        /// Exact process ownership retained only between a successful launch
        /// handshake and complete Surface materialization. Adoption never
        /// carries this guard.
        launch_process: Option<SpawnedHostProcess>,
        /// The first authenticated admin attachment may inherit a protocol-v4
        /// launch barrier. A launcher releases it after committing topology;
        /// an adopter releases an abandoned barrier after validating the host.
        launch_activation_pending: bool,
    }

    impl std::fmt::Debug for HostAttachment {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("HostAttachment")
                .field("terminal_id", &self.record.terminal_id)
                .field("incarnation", &self.record.incarnation)
                .field("endpoint", &self.record.endpoint)
                .finish_non_exhaustive()
        }
    }

    fn clear_history_ack_status(result: Result<(), ClearHistoryFailure>) -> u8 {
        match result {
            Ok(()) => CLEAR_HISTORY_ACK_OK,
            Err(failure) if failure.delivery() == ClearHistoryDelivery::Ambiguous => {
                CLEAR_HISTORY_ACK_AMBIGUOUS
            }
            Err(failure) => match failure.error().to_string().as_str() {
                CLEAR_HISTORY_PRESERVATION_ERROR => CLEAR_HISTORY_ACK_PRESERVATION_FAILED,
                CLEAR_HISTORY_STREAM_TIMEOUT_ERROR => CLEAR_HISTORY_ACK_STREAM_TIMEOUT,
                CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR => {
                    CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE
                }
                CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR => {
                    CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT
                }
                _ => CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED,
            },
        }
    }

    fn clear_history_ack_failure(status: u8) -> Option<ClearHistoryFailure> {
        let (delivery, message) = match status {
            CLEAR_HISTORY_ACK_PRESERVATION_FAILED => {
                (ClearHistoryDelivery::KnownNotDelivered, CLEAR_HISTORY_PRESERVATION_ERROR)
            }
            CLEAR_HISTORY_ACK_STREAM_TIMEOUT => {
                (ClearHistoryDelivery::KnownNotDelivered, CLEAR_HISTORY_STREAM_TIMEOUT_ERROR)
            }
            CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE => (
                ClearHistoryDelivery::KnownNotDelivered,
                CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR,
            ),
            CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT => (
                ClearHistoryDelivery::KnownNotDelivered,
                CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
            ),
            CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED => (
                ClearHistoryDelivery::KnownNotDelivered,
                "terminal host rejected clear-history before execution",
            ),
            CLEAR_HISTORY_ACK_AMBIGUOUS => (
                ClearHistoryDelivery::Ambiguous,
                "terminal host may have partially applied clear-history",
            ),
            _ => return None,
        };
        let error = anyhow::anyhow!(message);
        Some(match delivery {
            ClearHistoryDelivery::KnownNotDelivered => {
                ClearHistoryFailure::known_not_delivered(error)
            }
            ClearHistoryDelivery::Ambiguous => ClearHistoryFailure::ambiguous(error),
        })
    }

    impl HostAttachment {
        pub fn take_reader(&mut self) -> anyhow::Result<UnixStream> {
            self.reader.take().ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))
        }

        pub(crate) fn is_smart_renderer(&self) -> bool {
            self.smart_renderer
        }

        pub fn send(&self, kind: MessageKind, payload: &[u8]) -> std::io::Result<()> {
            let mut writer = self.writer.lock().unwrap();
            let mut frame = Frame::new(kind, payload.to_vec());
            frame.version = self.protocol_version;
            let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
            if result.is_err() {
                // A timed-out write may have emitted only part of a frame.
                // Poison this connection so the reader takes a fresh atomic
                // Snapshot instead of ever appending to a corrupt stream.
                let _ = writer.shutdown(std::net::Shutdown::Both);
            }
            result
        }

        /// Update the authoritative parser defaults on a feature-advertising
        /// host. Legacy records deliberately skip the unknown control while
        /// the disposable frontend still updates its local defaults.
        pub fn send_default_colors(&self, colors: DefaultColors) -> std::io::Result<bool> {
            if !self.record.supports_set_defaults {
                return Ok(false);
            }
            self.send(MessageKind::SetDefaults, &encode_default_colors_payload(colors))?;
            Ok(true)
        }

        pub fn send_clear_history(
            &self,
            fallback_key: Option<&KeyInput>,
        ) -> Result<bool, ClearHistoryFailure> {
            if !self.record.supports_clear_history {
                return Ok(false);
            }
            let payload = crate::server::encode_terminal_host_clear_history(fallback_key)
                .map_err(ClearHistoryFailure::known_not_delivered)?;
            let response = self.send_control_request(
                MessageKind::ClearHistory,
                MessageKind::ClearHistoryAck,
                payload,
            )?;
            match response.as_slice() {
                [CLEAR_HISTORY_ACK_OK] => {}
                [CLEAR_HISTORY_ACK_OK, ..] if self.smart_renderer => {}
                [status] => {
                    let Some(failure) = clear_history_ack_failure(*status) else {
                        self.disconnect();
                        return Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                            "terminal host returned an unknown clear-history status"
                        )));
                    };
                    return Err(failure);
                }
                _ => {
                    self.disconnect();
                    return Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                        "terminal host returned a malformed clear-history response"
                    )));
                }
            }
            Ok(true)
        }

        pub fn supports_clear_history(&self) -> bool {
            self.record.supports_clear_history
        }

        pub fn send_viewer_size(&self, cols: u16, rows: u16) -> std::io::Result<()> {
            let (cols, rows) = normalize_terminal_geometry(cols, rows).map_err(|error| {
                std::io::Error::new(std::io::ErrorKind::InvalidInput, error.to_string())
            })?;
            let mut viewer_size = self.viewer_size.lock().unwrap();
            if *viewer_size == Some((cols, rows)) {
                return Ok(());
            }
            // This is the daemon's desired logical lease, not an
            // acknowledgement from the host. Retain it across a failed write
            // so reconnect can replay the newest mux state instead of a stale
            // reservation from the dead socket.
            *viewer_size = Some((cols, rows));
            let mut payload = Vec::with_capacity(4);
            payload.extend_from_slice(&cols.to_le_bytes());
            payload.extend_from_slice(&rows.to_le_bytes());
            self.send(MessageKind::ViewerSize, &payload)?;
            Ok(())
        }

        /// Commit frontend cell metrics in the durable host before updating
        /// this daemon's disposable mirror. Protocol-v1 hosts do not expose
        /// this transaction, so callers leave their mirror unchanged.
        pub fn send_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
            self.send_cell_pixel_size_until(
                width_px,
                height_px,
                Instant::now() + CONTROL_RESPONSE_TIMEOUT,
            )
        }

        pub(crate) fn send_cell_pixel_size_until(
            &self,
            width_px: u16,
            height_px: u16,
            deadline: Instant,
        ) -> anyhow::Result<bool> {
            if self.protocol_version < 2 {
                return Ok(false);
            }
            if Instant::now() >= deadline {
                return Err(CellPixelRequestDeadlineElapsed.into());
            }
            let width_px = width_px.max(1);
            let height_px = height_px.max(1);
            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
            let (sender, receiver) = sync_channel(1);
            self.control_responses.waiters.lock().unwrap().insert(
                request_id,
                ControlResponseWaiter::Blocking { kind: MessageKind::CellPixelSizeAck, sender },
            );
            let mut payload = Vec::with_capacity(4);
            payload.extend_from_slice(&width_px.to_le_bytes());
            payload.extend_from_slice(&height_px.to_le_bytes());
            let mut frame = Frame::new(MessageKind::SetCellPixelSize, payload);
            frame.version = self.protocol_version;
            frame.request_id = request_id;
            let write_result = {
                let mut writer = self.writer.lock().unwrap();
                write_frame(&mut *writer, &frame).map_err(protocol_io_error)
            };
            if let Err(error) = write_result {
                let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
                self.control_responses.waiters.lock().unwrap().remove(&request_id);
                return Err(error.into());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            let response = match (!remaining.is_zero())
                .then(|| receiver.recv_timeout(remaining))
                .transpose()
            {
                Ok(Some(response)) => response,
                Ok(None) | Err(RecvTimeoutError::Timeout) => {
                    match self.defer_or_receive_raced_cell_pixel_ack(
                        request_id,
                        (width_px, height_px),
                        &receiver,
                    )? {
                        Some(response) => response,
                        None => return Err(DeferredCellPixelAck.into()),
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    self.control_responses.waiters.lock().unwrap().remove(&request_id);
                    anyhow::bail!(
                        "terminal host connection closed before acknowledging cell pixel size"
                    );
                }
            };
            if response.kind != MessageKind::CellPixelSizeAck
                || response.payload.as_slice()
                    != [width_px.to_le_bytes(), height_px.to_le_bytes()].concat()
            {
                let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
                anyhow::bail!("terminal host returned a malformed cell pixel size acknowledgement");
            }
            Ok(true)
        }

        /// Commit Kitty resource limits in the authoritative host before
        /// returning control to the disposable mirror. Protocol-v1/v2 hosts
        /// cannot synchronize this sidecar state and therefore keep graphics
        /// disabled in new mirrors.
        pub fn send_kitty_graphics_limits(
            &self,
            limits: KittyGraphicsLimits,
        ) -> anyhow::Result<bool> {
            self.send_kitty_graphics_limits_until(limits, Instant::now() + CONTROL_RESPONSE_TIMEOUT)
        }

        pub fn send_kitty_graphics_limits_until(
            &self,
            limits: KittyGraphicsLimits,
            deadline: Instant,
        ) -> anyhow::Result<bool> {
            if self.protocol_version < 3 {
                return Ok(false);
            }
            let limits = limits
                .validate()
                .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
            let mut payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
            encode_kitty_graphics_limits(&mut payload, limits)?;
            let response = self
                .send_control_request_with_policy(
                    MessageKind::SetKittyGraphicsLimits,
                    MessageKind::KittyGraphicsLimitsAck,
                    payload,
                    deadline,
                    // Advisory control: a missed ack must degrade graphics for
                    // this surface, not tear down a healthy host connection.
                    false,
                )
                .map_err(ClearHistoryFailure::into_error)
                .context("terminal host did not acknowledge Kitty graphics limits")?;
            let mut decoder = PayloadDecoder::new(&response);
            let acknowledged = decode_kitty_graphics_limits(&mut decoder)?;
            decoder.finish()?;
            if acknowledged != limits {
                self.disconnect();
                anyhow::bail!("terminal host acknowledged different Kitty graphics limits");
            }
            Ok(true)
        }

        fn reconfigure_kitty_graphics_for_adoption(
            &mut self,
            limits: KittyGraphicsLimits,
        ) -> anyhow::Result<()> {
            anyhow::ensure!(
                self.protocol_version >= 3,
                "terminal host cannot synchronize Kitty graphics limits"
            );
            let limits = limits
                .validate()
                .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
            let mut payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
            encode_kitty_graphics_limits(&mut payload, limits)?;
            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
            if request_id == 0 {
                self.disconnect();
                anyhow::bail!("terminal host control request id exhausted");
            }
            let mut request = Frame::new(MessageKind::SetKittyGraphicsLimits, payload);
            request.version = self.protocol_version;
            request.request_id = request_id;
            let write_result = {
                let mut writer = self.writer.lock().unwrap();
                write_frame(&mut *writer, &request).map_err(protocol_io_error)
            };
            if let Err(error) = write_result {
                self.disconnect();
                return Err(error.into());
            }

            // No Surface reader exists yet. Drain the old live stream through
            // the targeted acknowledgement, then reconnect for the fresh
            // authoritative Snapshot produced before that acknowledgement.
            let protocol_version = self.protocol_version;
            let deadline = Instant::now() + CONTROL_RESPONSE_TIMEOUT;
            let result = (|| -> anyhow::Result<()> {
                let reader = self
                    .reader
                    .as_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))?;
                let previous_timeout = reader
                    .read_timeout()
                    .context("read terminal-host timeout before Kitty quota adoption")?;
                let response = (|| -> anyhow::Result<()> {
                    loop {
                        let remaining = deadline.saturating_duration_since(Instant::now());
                        anyhow::ensure!(
                            !remaining.is_zero(),
                            "terminal host did not apply Kitty graphics limits before adoption"
                        );
                        reader
                            .set_read_timeout(Some(remaining.max(Duration::from_millis(1))))
                            .context("set terminal-host Kitty quota adoption timeout")?;
                        let frame = read_frame(reader, MAX_FRAME_PAYLOAD)
                            .map_err(protocol_io_error)?
                            .ok_or_else(|| {
                                anyhow::anyhow!(
                                    "terminal host disconnected while applying Kitty graphics limits"
                                )
                            })?;
                        anyhow::ensure!(
                            frame.version == protocol_version,
                            "terminal host changed protocol during Kitty quota adoption"
                        );
                        if frame.request_id == 0 {
                            continue;
                        }
                        anyhow::ensure!(
                            frame.request_id == request_id
                                && frame.kind == MessageKind::KittyGraphicsLimitsAck
                                && frame.flags == 0
                                && frame.sequence == 0,
                            "terminal host returned an invalid Kitty quota adoption response"
                        );
                        let mut decoder = PayloadDecoder::new(&frame.payload);
                        let acknowledged = decode_kitty_graphics_limits(&mut decoder)?;
                        decoder.finish()?;
                        anyhow::ensure!(
                            acknowledged == limits,
                            "terminal host acknowledged different Kitty graphics limits"
                        );
                        return Ok(());
                    }
                })();
                let restored = reader
                    .set_read_timeout(previous_timeout)
                    .context("restore terminal-host timeout after Kitty quota adoption");
                response.and(restored)
            })();
            if result.is_err() {
                self.disconnect();
            }
            result
        }

        fn defer_or_receive_raced_cell_pixel_ack(
            &self,
            request_id: u64,
            expected: (u16, u16),
            receiver: &Receiver<Frame>,
        ) -> anyhow::Result<Option<Frame>> {
            if self.control_responses.defer_cell_pixel(request_id, expected) {
                return Ok(None);
            }
            // resolve() removes the waiter while holding the same mutex
            // before delivering the response. An absent entry therefore
            // means a response won the timeout race or the connection failed.
            receiver.recv().map(Some).map_err(|_| {
                anyhow::anyhow!(
                    "terminal host connection closed while acknowledging cell pixel size"
                )
            })
        }

        pub fn release_viewer_size(&self) -> std::io::Result<bool> {
            let mut viewer_size = self.viewer_size.lock().unwrap();
            if viewer_size.is_none() {
                return Ok(false);
            }
            // Preserve the desired released state even if this disposable
            // admin connection has already failed; reconnect starts without
            // an implicit lease and therefore needs no compensating message.
            *viewer_size = None;
            self.send(MessageKind::ReleaseViewer, &[])?;
            Ok(true)
        }

        pub fn viewer_size(&self) -> Option<(u16, u16)> {
            *self.viewer_size.lock().unwrap()
        }

        pub fn protocol_version(&self) -> u16 {
            self.protocol_version
        }

        pub fn terminate(&mut self) -> anyhow::Result<()> {
            if !self.record.supports_terminate_ack {
                self.send(MessageKind::Terminate, &[])?;
                // The connection is no longer used for commands. A write-half
                // shutdown orders EOF after the complete frame, preventing an
                // immediate Surface drop from discarding a legacy request.
                self.writer.lock().unwrap().shutdown(std::net::Shutdown::Write)?;
                return Ok(());
            }

            if self.reader.is_some() {
                return self.terminate_before_reader_taken();
            }

            let response = self
                .send_control_request(MessageKind::Terminate, MessageKind::TerminateAck, Vec::new())
                .map_err(ClearHistoryFailure::into_error)?;
            anyhow::ensure!(
                response.is_empty(),
                "terminal host returned a malformed terminate receipt"
            );
            Ok(())
        }

        fn terminate_before_reader_taken(&mut self) -> anyhow::Result<()> {
            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
            anyhow::ensure!(request_id != 0, "terminal host control request id exhausted");
            let mut request = Frame::new(MessageKind::Terminate, Vec::new());
            request.version = self.protocol_version;
            request.request_id = request_id;
            {
                let mut writer = self.writer.lock().unwrap();
                write_frame(&mut *writer, &request).map_err(protocol_io_error)?;
            }

            let protocol_version = self.protocol_version;
            let deadline = Instant::now() + CONTROL_RESPONSE_TIMEOUT;
            let result = (|| -> anyhow::Result<()> {
                let reader = self
                    .reader
                    .as_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))?;
                let previous_timeout = reader
                    .read_timeout()
                    .context("read terminal-host timeout before termination")?;
                let response = (|| -> anyhow::Result<()> {
                    loop {
                        let remaining = deadline.saturating_duration_since(Instant::now());
                        anyhow::ensure!(
                            !remaining.is_zero(),
                            "terminal host did not acknowledge termination"
                        );
                        reader
                            .set_read_timeout(Some(remaining.max(Duration::from_millis(1))))
                            .context("set terminal-host termination timeout")?;
                        let frame = read_frame(reader, MAX_FRAME_PAYLOAD)
                            .map_err(protocol_io_error)?
                            .ok_or_else(|| {
                                anyhow::anyhow!(
                                    "terminal host disconnected before acknowledging termination"
                                )
                            })?;
                        anyhow::ensure!(
                            frame.version == protocol_version,
                            "terminal host changed protocol during termination"
                        );
                        if frame.request_id == 0 {
                            continue;
                        }
                        anyhow::ensure!(
                            frame.request_id == request_id
                                && frame.kind == MessageKind::TerminateAck
                                && frame.flags == 0
                                && frame.sequence == 0
                                && frame.payload.is_empty(),
                            "terminal host returned an invalid terminate receipt"
                        );
                        return Ok(());
                    }
                })();
                let restored = reader
                    .set_read_timeout(previous_timeout)
                    .context("restore terminal-host timeout after termination");
                response.and(restored)
            })();
            if result.is_err() {
                self.disconnect();
            }
            result
        }

        pub fn terminate_and_wait_for_exit(&mut self) -> anyhow::Result<TerminalHostExitRecord> {
            let deadline = Instant::now()
                .checked_add(HOST_LAUNCH_ROLLBACK_WAIT)
                .ok_or_else(|| anyhow::anyhow!("terminal-host termination timeout overflow"))?;
            self.terminate().context("send terminal-host termination")?;
            let identity = self.identity();
            let record_path = self.record_path.clone();
            let protocol_version = self.protocol_version;
            let reader = self
                .reader
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))?;
            let previous_timeout =
                reader.read_timeout().context("read terminal-host timeout before termination")?;
            let result = (|| -> anyhow::Result<TerminalHostExitRecord> {
                loop {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    anyhow::ensure!(
                        !remaining.is_zero(),
                        "terminal host did not exit before the termination deadline"
                    );
                    reader
                        .set_read_timeout(Some(remaining.max(Duration::from_millis(1))))
                        .context("set terminal-host termination timeout")?;
                    let frame = match read_frame(reader, MAX_FRAME_PAYLOAD) {
                        Ok(Some(frame)) => frame,
                        Ok(None) | Err(_) => {
                            if let Some((_, record)) = terminal_host_exit_record(&record_path)?
                                && record.terminal_id == identity.terminal_id
                                && record.incarnation == identity.incarnation
                            {
                                return Ok(record);
                            }
                            anyhow::bail!("terminal host disconnected before its exit receipt");
                        }
                    };
                    anyhow::ensure!(
                        frame.version == protocol_version,
                        "terminal host changed protocol while terminating"
                    );
                    if frame.kind != MessageKind::Exit {
                        continue;
                    }
                    anyhow::ensure!(
                        frame.flags == 0 && frame.request_id == 0,
                        "terminal host returned a malformed exit frame"
                    );
                    let exit = decode_terminal_exit(&frame.payload)?;
                    return Ok(TerminalHostExitRecord::new(&identity, exit));
                }
            })();
            let restored = reader
                .set_read_timeout(previous_timeout)
                .context("restore terminal-host timeout after termination");
            match result {
                Ok(record) => {
                    restored?;
                    Ok(record)
                }
                Err(error) => {
                    let _ = restored;
                    Err(error)
                }
            }
        }

        pub fn disconnect(&self) {
            let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
        }

        /// Remove this daemon from host publication only after the reader has
        /// consumed every source frame admitted before the request. Record-v4
        /// hosts implement the source fence; older hosts cannot make this
        /// shutdown guarantee.
        pub(crate) fn detach_for_daemon_shutdown_until(
            &self,
            deadline: Instant,
        ) -> anyhow::Result<()> {
            anyhow::ensure!(
                self.smart_renderer && self.record.record_version >= HOST_RECORD_VERSION,
                "terminal host does not support a source-ordered detach fence"
            );
            let response = self
                .send_control_request_until(
                    MessageKind::Detach,
                    MessageKind::DetachAck,
                    Vec::new(),
                    deadline,
                )
                .map_err(ClearHistoryFailure::into_error)?;
            anyhow::ensure!(response.is_empty(), "terminal host returned a malformed detach fence");
            Ok(())
        }

        pub(crate) fn supports_journal_detach_fence(&self) -> bool {
            self.smart_renderer && self.record.record_version >= HOST_RECORD_VERSION
        }

        /// Commit the launch ownership handoff after every fallible Surface
        /// setup step succeeds. Until then, dropping this attachment exact-
        /// kills and waits the child process through SpawnedHostProcess.
        pub(crate) fn commit_launched_host(&mut self) {
            let Some(process) = self.launch_process.take() else { return };
            let mut child = process.into_child();
            // Reaping is housekeeping after the ownership handoff. Failure to
            // create this helper cannot turn a committed live Surface into an
            // error; dropping Child leaves the independent host running.
            let _ = thread::Builder::new().name("terminal-host-reaper".into()).spawn(move || {
                let _ = child.wait();
            });
        }

        /// Release a newly launched protocol-v4 host only after its public
        /// topology is durable. The state flips after the complete frame is
        /// accepted by the local socket, so a retry cannot duplicate it.
        pub(crate) fn activate_launched_host(&mut self) -> std::io::Result<bool> {
            if !self.launch_activation_pending {
                return Ok(false);
            }
            debug_assert!(self.protocol_version >= LAUNCH_ACTIVATION_PROTOCOL_VERSION);
            self.send(MessageKind::Activate, &[])?;
            self.launch_activation_pending = false;
            Ok(true)
        }

        pub fn identity(&self) -> TerminalHostIdentity {
            TerminalHostIdentity {
                terminal_id: self.record.terminal_id.clone(),
                incarnation: self.record.incarnation.clone(),
            }
        }

        pub(crate) fn exit_record_path(&self) -> PathBuf {
            self.record_path.with_extension("exit")
        }

        pub(crate) fn discovery_record(&self) -> (TerminalHostRecord, PathBuf) {
            (self.record.clone(), self.record_path.clone())
        }

        pub(crate) fn control_responses(&self) -> Arc<ControlResponses> {
            self.control_responses.clone()
        }

        fn send_control_request(
            &self,
            request_kind: MessageKind,
            response_kind: MessageKind,
            payload: Vec<u8>,
        ) -> Result<Vec<u8>, ClearHistoryFailure> {
            self.send_control_request_until(
                request_kind,
                response_kind,
                payload,
                Instant::now() + CONTROL_RESPONSE_TIMEOUT,
            )
        }

        fn send_control_request_until(
            &self,
            request_kind: MessageKind,
            response_kind: MessageKind,
            payload: Vec<u8>,
            deadline: Instant,
        ) -> Result<Vec<u8>, ClearHistoryFailure> {
            self.send_control_request_with_policy(
                request_kind,
                response_kind,
                payload,
                deadline,
                true,
            )
        }

        /// `disconnect_on_timeout` = false keeps the channel alive when the
        /// ack misses the deadline. Responses are matched by request id and
        /// an unknown id is dropped on arrival, so a late ack is harmless.
        /// Advisory controls (Kitty graphics limits) use this: tearing down
        /// a healthy host over a slow ack forced a full terminal reconnect,
        /// which reset the budget blocklist and re-armed the retry storm.
        fn send_control_request_with_policy(
            &self,
            request_kind: MessageKind,
            response_kind: MessageKind,
            payload: Vec<u8>,
            deadline: Instant,
            disconnect_on_timeout: bool,
        ) -> Result<Vec<u8>, ClearHistoryFailure> {
            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
            if request_id == 0 {
                return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                    "terminal host control request id exhausted"
                )));
            }
            let (sender, receiver) = sync_channel(1);
            {
                let mut waiters = self.control_responses.waiters.lock().unwrap();
                if waiters.contains_key(&request_id) {
                    return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                        "terminal host control request id collision"
                    )));
                }
                waiters.insert(
                    request_id,
                    ControlResponseWaiter::Blocking { kind: response_kind, sender },
                );
            }
            let mut frame = Frame::new(request_kind, payload);
            frame.version = self.protocol_version;
            frame.request_id = request_id;
            let write_result = {
                let mut writer = self.writer.lock().unwrap();
                let result = write_frame(&mut *writer, &frame).map_err(protocol_io_error);
                if result.is_err() {
                    let _ = writer.shutdown(std::net::Shutdown::Both);
                }
                result
            };
            if let Err(error) = write_result {
                self.control_responses.waiters.lock().unwrap().remove(&request_id);
                return Err(ClearHistoryFailure::ambiguous(error.into()));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            let response = if remaining.is_zero() {
                Err(RecvTimeoutError::Timeout)
            } else {
                receiver.recv_timeout(remaining)
            };
            match response {
                Ok(frame) => Ok(frame.payload),
                Err(error) => {
                    self.control_responses.waiters.lock().unwrap().remove(&request_id);
                    if disconnect_on_timeout {
                        self.disconnect();
                    }
                    Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                        "terminal host did not acknowledge {request_kind:?}: {error}"
                    )))
                }
            }
        }

        pub fn mint_renderer_grant(&self, ttl: Duration) -> anyhow::Result<RendererGrant> {
            if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
                anyhow::bail!("renderer capability TTL must be between 1ms and 60s");
            }
            let ttl_ms = u32::try_from(ttl.as_millis())
                .map_err(|_| anyhow::anyhow!("renderer capability TTL is too large"))?;
            let mut payload = Vec::with_capacity(8);
            payload.extend_from_slice(&CapabilityRights::RENDERER.bits().to_le_bytes());
            payload.extend_from_slice(&ttl_ms.to_le_bytes());
            let payload = self
                .send_control_request(MessageKind::MintCapability, MessageKind::Capability, payload)
                .map_err(ClearHistoryFailure::into_error)
                .context("terminal host did not mint renderer grant")?;
            if payload.len() != crate::terminal_host::CAPABILITY_TOKEN_LEN {
                self.disconnect();
                anyhow::bail!("terminal host returned a malformed renderer capability");
            }
            Ok(RendererGrant {
                endpoint: self.record.endpoint.clone(),
                terminal_id: self.record.terminal_id.clone(),
                incarnation: self.record.incarnation.clone(),
                token: encode_hex(&payload),
                rights: CapabilityRights::RENDERER,
                protocol_version: self.protocol_version,
            })
        }

        pub fn persist_workspace(&mut self, workspace_key: &str) -> anyhow::Result<()> {
            if self.record.workspace_key == workspace_key {
                return Ok(());
            }
            let mut updated = self.record.clone();
            updated.workspace_key = workspace_key.to_string();
            write_record(&self.record_path, &updated)?;
            self.record = updated;
            Ok(())
        }
    }

    impl Drop for HostAttachment {
        fn drop(&mut self) {
            let Some(mut process) = self.launch_process.take() else { return };
            // Surface setup failed after an authenticated launch. Ask the
            // still-live host to perform its bounded PTY group shutdown and
            // record cleanup, then wait on the exact owned host process. Only
            // a wedged host that exceeds that bound is SIGKILLed by the
            // SpawnedHostProcess fallback below.
            let _ = self.terminate();
            if !process.wait_timeout(HOST_LAUNCH_ROLLBACK_WAIT) {
                drop(process);
            }

            // This attachment still owns an uncommitted launch, so no
            // registry transition can consume its crash-recovery evidence.
            // Process exit is ordered after durable sidecar publication.
            // Remove only the receipt for this exact launch incarnation.
            let identity = self.identity();
            if let Ok(Some((exit_path, exit))) = terminal_host_exit_record(&self.record_path)
                && exit.terminal_id == identity.terminal_id
                && exit.incarnation == identity.incarnation
            {
                let _ = acknowledge_terminal_host_exit_record(&exit_path, &exit);
            }
        }
    }

    pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
        state_root.join(format!("terminal-hosts-{}", stable_token(session)))
    }

    /// Strip every descriptor except the private bootstrap stdio before the
    /// hidden host starts any threads or opens its endpoint. This runs inside
    /// the freshly exec'd `__terminal-host`, so descriptor enumeration is
    /// race-free and cannot affect the daemon's own open files.
    pub fn isolate_terminal_host_process_fds() -> anyhow::Result<()> {
        let mut last_error = None;
        let mut inherited = None;
        for directory in ["/proc/self/fd", "/dev/fd"] {
            match fs::read_dir(directory) {
                Ok(entries) => {
                    let mut descriptors = entries
                        .filter_map(Result::ok)
                        .filter_map(|entry| entry.file_name().to_str()?.parse::<libc::c_int>().ok())
                        .filter(|descriptor| *descriptor > libc::STDERR_FILENO)
                        .collect::<Vec<_>>();
                    descriptors.sort_unstable();
                    descriptors.dedup();
                    inherited = Some(descriptors);
                    break;
                }
                Err(error) => last_error = Some(error),
            }
        }
        let descriptors = inherited.ok_or_else(|| {
            anyhow::anyhow!(
                "enumerate inherited terminal-host descriptors: {}",
                last_error.unwrap_or_else(|| std::io::Error::other("no descriptor filesystem"))
            )
        })?;
        for descriptor in descriptors {
            // SAFETY: descriptors came from this single-threaded process's
            // descriptor filesystem snapshot. stdio 0/1/2 is excluded.
            if unsafe { libc::close(descriptor) } != 0 {
                let error = std::io::Error::last_os_error();
                if !matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::Interrupted
                ) && error.raw_os_error() != Some(libc::EBADF)
                {
                    return Err(error)
                        .context(format!("close inherited terminal-host descriptor {descriptor}"));
                }
            }
        }
        Ok(())
    }

    pub fn launch_terminal_host(
        options: &SurfaceOptions,
        root: &Path,
        default_colors: DefaultColors,
        cell_pixels: (u16, u16),
        kitty_graphics_limits: KittyGraphicsLimits,
    ) -> anyhow::Result<HostAttachment> {
        let terminal_id = TerminalId::random()?;
        launch_terminal_host_with_identity(
            options,
            root,
            default_colors,
            cell_pixels,
            kitty_graphics_limits,
            terminal_id,
        )
    }

    /// Launch using a registry-reserved stable UUID. The workspace registry
    /// can commit identity/placement before process creation, eliminating the
    /// launch-window orphan race without changing the host wire protocol.
    pub fn launch_terminal_host_with_identity(
        options: &SurfaceOptions,
        root: &Path,
        default_colors: DefaultColors,
        cell_pixels: (u16, u16),
        kitty_graphics_limits: KittyGraphicsLimits,
        terminal_id: TerminalId,
    ) -> anyhow::Result<HostAttachment> {
        let launch_publication_lock = reserve_terminal_host_publication(root)?;
        let owner_token = CapabilityToken::random()?;
        let terminal_hex = encode_hex(terminal_id.as_bytes());
        // macOS limits sockaddr_un paths to roughly one hundred bytes and
        // TMPDIR is commonly already longer than that. Keep the transport
        // endpoint short; the private durable record still carries its full
        // canonical identity and owner capability.
        let uid = fs::metadata(root)?.uid();
        let endpoint_root = PathBuf::from("/tmp").join(format!("cmux-th-{uid}"));
        prepare_private_dir(&endpoint_root)?;
        let endpoint = endpoint_root.join(format!("{terminal_hex}.sock"));
        let record_path = root.join(format!("{terminal_hex}.json"));
        if record_path.exists() || endpoint.exists() {
            anyhow::bail!("terminal host identity already exists");
        }
        let command = options
            .command
            .clone()
            .filter(|command| !command.is_empty())
            .unwrap_or_else(|| vec![crate::platform::default_shell()]);
        let launch = HostLaunch {
            endpoint: endpoint.to_string_lossy().into_owned(),
            record_path: record_path.to_string_lossy().into_owned(),
            term: options.term.clone(),
            cols: options.cols,
            rows: options.rows,
            cell_pixels,
            scrollback: options.scrollback,
            cwd: options.cwd.clone().or_else(|| {
                crate::platform::home_dir().map(|path| path.to_string_lossy().into_owned())
            }),
            command,
            extra_env: options.extra_env.clone(),
            default_colors,
            kitty_graphics_limits,
        };

        // Exec the daemon's own running build (open inode on Linux): after an
        // in-place binary upgrade, resolving the executable path yields
        // "<path> (deleted)" and exec fails, which broke every new tab/split
        // on a long-lived daemon. This also guarantees daemon and host can
        // never run skewed builds.
        let binary = crate::platform::self_exe_for_spawn()
            .context("resolve cmux-tui terminal-host binary")?;
        let mut command = Command::new(binary);
        command
            .args(["__terminal-host", "--bootstrap-stdio"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // A host outlives its daemon, so it must not retain a daemon log
            // pipe whose EOF is itself used as a lifecycle signal.
            .stderr(Stdio::null());
        // A durable host must not share the daemon's controlling terminal,
        // session, or process group. Otherwise a shell hangup or group
        // interrupt intended for the daemon can also kill every hosted PTY.
        // SAFETY: setsid(2) is async-signal-safe and touches no Rust state in
        // the post-fork child. A freshly forked child is not a process-group
        // leader, so failure is an actual launch error and must be surfaced.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        let child = command.spawn().context("spawn terminal-host process")?;
        let mut process = SpawnedHostProcess { child: Some(child) };
        let host_pid = process.child_mut().id();
        let mut stdin =
            process.child_mut().stdin.take().context("open terminal-host bootstrap stdin")?;
        let mut stdout =
            process.child_mut().stdout.take().context("open terminal-host bootstrap stdout")?;

        let bootstrap = HostBootstrap {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            terminal_id,
            owner_token,
        };
        write_frame(&mut stdin, &bootstrap.into_frame(1))?;
        let ready_frame = read_required_frame(&mut stdout, "bootstrap ready")?;
        if ready_frame.kind != MessageKind::Ready {
            anyhow::bail!("terminal host returned {:?} instead of Ready", ready_frame.kind);
        }
        let ready = HostReady::decode(&ready_frame.payload)?;
        if ready.terminal_id != terminal_id {
            anyhow::bail!("terminal host changed terminal identity during bootstrap");
        }

        let mut launch_frame = Frame::new(MessageKind::Launch, launch.encode()?);
        launch_frame.request_id = 2;
        write_frame(&mut stdin, &launch_frame)?;
        let launched_frame = read_required_frame(&mut stdout, "launch ready")?;
        if launched_frame.request_id != 2 {
            anyhow::bail!("terminal host did not acknowledge launch");
        }
        if launched_frame.kind == MessageKind::LaunchFailed {
            let failure = decode_host_launch_failure(&launched_frame.payload)?;
            return Err(failure.into());
        }
        if launched_frame.kind != MessageKind::Ready {
            anyhow::bail!("terminal host did not acknowledge launch");
        }
        let launched = HostReady::decode(&launched_frame.payload)?;
        if launched.terminal_id != terminal_id || launched.incarnation != ready.incarnation {
            anyhow::bail!("terminal host identity changed while launching PTY");
        }
        drop(stdin);
        drop(stdout);

        let record: TerminalHostRecord = serde_json::from_slice(
            &fs::read(&record_path).context("read terminal-host discovery record")?,
        )?;
        validate_terminal_host_record(&record_path, &record)?;
        if record.terminal_id != terminal_hex
            || record.incarnation != ready.incarnation.to_hex()
            || record.owner_token != encode_hex(owner_token.as_bytes())
            || record.host_pid != host_pid
        {
            anyhow::bail!("terminal-host discovery record changed during launch");
        }
        drop(launch_publication_lock);
        // Keep the exact-kill guard armed through record validation and a
        // successful authenticated Snapshot. Returning Err after disarming it
        // would leave a live published host while the mux marks its registry
        // row Exited.
        let mut attachment = connect_record(record, record_path)?;
        attachment.launch_process = Some(process);
        debug_assert_eq!(
            attachment.launch_activation_pending,
            attachment.protocol_version >= LAUNCH_ACTIVATION_PROTOCOL_VERSION
        );
        Ok(attachment)
    }

    pub fn adopt_terminal_host(
        record: TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<HostAttachment> {
        validate_terminal_host_record(&record_path, &record)?;
        let mut attachment = connect_record(record, record_path)?;
        attachment.activate_launched_host()?;
        Ok(attachment)
    }

    pub(crate) fn adopt_current_terminal_host(
        record: TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<HostAttachment> {
        validate_terminal_host_record(&record_path, &record)?;
        connect_current_record_with_timeout(record, record_path, HOST_HANDSHAKE_TIMEOUT)
    }

    pub(crate) fn adopt_terminal_host_with_kitty_limits(
        record: TerminalHostRecord,
        record_path: PathBuf,
        ceiling: KittyGraphicsLimits,
    ) -> anyhow::Result<HostAttachment> {
        let ceiling = ceiling
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        let connect = |record: TerminalHostRecord, record_path: PathBuf| {
            if record.record_version >= HOST_RECORD_VERSION {
                // Current records guarantee the current smart protocol. Keep
                // startup and reconnect head-of-line blocking to one bounded
                // handshake; only legacy records need version probing.
                adopt_current_terminal_host(record, record_path)
            } else {
                connect_record(record, record_path)
            }
        };
        let mut attachment = connect(record.clone(), record_path.clone())?;
        if kitty_graphics_limits_within(attachment.snapshot.kitty_state.limits, ceiling) {
            attachment.activate_launched_host()?;
            return Ok(attachment);
        }

        attachment.reconfigure_kitty_graphics_for_adoption(ceiling)?;
        attachment.activate_launched_host()?;
        attachment.disconnect();
        drop(attachment);

        let attachment = connect(record, record_path)?;
        anyhow::ensure!(
            kitty_graphics_limits_within(attachment.snapshot.kitty_state.limits, ceiling),
            "terminal host retained Kitty graphics state above its adoption quota"
        );
        Ok(attachment)
    }

    /// Validate a discovery record without trusting paths or alternate
    /// identity spellings supplied by its JSON payload.
    pub fn validate_terminal_host_record(
        record_path: &Path,
        record: &TerminalHostRecord,
    ) -> anyhow::Result<TerminalHostIdentity> {
        if !matches!(record.record_version, 1 | 2 | 3 | HOST_RECORD_VERSION) {
            anyhow::bail!("unsupported terminal-host record version {}", record.record_version);
        }
        let terminal_id = TerminalId::from_hex(&record.terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal-host id is not a canonical UUIDv4"))?;
        let incarnation = HostIncarnation::from_hex(&record.incarnation).ok_or_else(|| {
            anyhow::anyhow!("terminal-host incarnation is not a canonical UUIDv4")
        })?;
        let owner = decode_lower_hex_array::<{ crate::terminal_host::CAPABILITY_TOKEN_LEN }>(
            &record.owner_token,
            "owner token",
        )?;
        if owner.iter().all(|byte| *byte == 0) {
            anyhow::bail!("terminal-host owner token is zero");
        }
        if record.record_version == 1 {
            if record.host_pid != 0
                || !record.host_start_nonce.is_empty()
                || record.supports_set_defaults
                || record.supports_clear_history
                || record.supports_terminate_ack
            {
                anyhow::bail!("legacy terminal-host record has unexpected liveness fields");
            }
        } else {
            if record.record_version == 2 && record.supports_terminate_ack {
                anyhow::bail!("version 2 terminal-host record advertises terminate receipts");
            }
            let nonce = decode_lower_hex_array::<HOST_START_NONCE_LEN>(
                &record.host_start_nonce,
                "process-start nonce",
            )?;
            if nonce.iter().all(|byte| *byte == 0) {
                anyhow::bail!("terminal-host process-start nonce is zero");
            }
            if record.host_pid == 0 {
                anyhow::bail!("terminal-host PID is zero");
            }
        }
        if record.workspace_key.len() > MAX_STRING || record.workspace_key.contains('\0') {
            anyhow::bail!("terminal-host workspace hint is invalid");
        }

        let parent = record_path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("terminal-host record has no parent directory"))?;
        let expected_record = parent.join(format!("{}.json", record.terminal_id));
        if record_path != expected_record {
            anyhow::bail!("terminal-host record filename is not canonical");
        }
        let uid = fs::metadata(parent)?.uid();
        let expected_endpoint = PathBuf::from("/tmp")
            .join(format!("cmux-th-{uid}"))
            .join(format!("{}.sock", record.terminal_id));
        if Path::new(&record.endpoint) != expected_endpoint {
            anyhow::bail!("terminal-host endpoint is not canonical");
        }
        if let Ok(metadata) = fs::symlink_metadata(record_path)
            && (!metadata.file_type().is_file()
                || metadata.uid() != uid
                || metadata.mode() & 0o077 != 0)
        {
            anyhow::bail!("terminal-host record permissions or ownership are unsafe");
        }
        let _ = (terminal_id, incarnation);
        Ok(TerminalHostIdentity {
            terminal_id: record.terminal_id.clone(),
            incarnation: record.incarnation.clone(),
        })
    }

    fn liveness_path(record_path: &Path, record: &TerminalHostRecord) -> PathBuf {
        record_path
            .with_extension(format!("{}-{}.live", record.incarnation, record.host_start_nonce))
    }

    /// Probe the process-lifetime nonce lock. `Dead` is positive evidence
    /// tied to this exact incarnation even if `host_pid` has since been
    /// assigned to another process.
    pub fn terminal_host_record_liveness(
        record_path: &Path,
        record: &TerminalHostRecord,
    ) -> anyhow::Result<TerminalHostLiveness> {
        validate_terminal_host_record(record_path, record)?;
        if record.record_version == 1 {
            // v1 predates process-bound liveness proof. Preserve and adopt a
            // reachable legacy host, but never infer death from PID/socket
            // observations that are vulnerable to reuse and startup races.
            // A normal legacy Exit remains authoritative and removes its own
            // record; an unclean v1 crash intentionally requires manual or
            // version-aware migration rather than unsafe reaping.
            return Ok(if !record_path.exists() && !Path::new(&record.endpoint).exists() {
                TerminalHostLiveness::Dead
            } else {
                TerminalHostLiveness::Indeterminate
            });
        }
        let path = liveness_path(record_path, record);
        let file = match OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let host_cleanup_complete = !record_path.exists()
                    && !Path::new(&record.endpoint).exists()
                    && !path.exists();
                return Ok(
                    if host_cleanup_complete || process_definitely_absent(record.host_pid) {
                        TerminalHostLiveness::Dead
                    } else {
                        TerminalHostLiveness::Indeterminate
                    },
                );
            }
            Err(_) => return Ok(TerminalHostLiveness::Indeterminate),
        };
        let metadata = file.metadata()?;
        let expected_uid = fs::metadata(record_path.parent().unwrap())?.uid();
        if !metadata.file_type().is_file()
            || metadata.uid() != expected_uid
            || metadata.nlink() != 1
            || metadata.mode() & 0o077 != 0
        {
            return Ok(TerminalHostLiveness::Indeterminate);
        }
        loop {
            // SAFETY: flock only observes/changes the advisory lock associated
            // with this valid, owned file descriptor.
            let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if result == 0 {
                // SAFETY: same valid descriptor as above. Unlock before the
                // temporary probe descriptor is closed.
                let _ = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
                return Ok(TerminalHostLiveness::Dead);
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Ok(
                if error
                    .raw_os_error()
                    .is_some_and(|code| code == libc::EWOULDBLOCK || code == libc::EAGAIN)
                {
                    TerminalHostLiveness::Live
                } else {
                    TerminalHostLiveness::Indeterminate
                },
            );
        }
    }

    /// Remove a discovery record only after the process-lifetime proof says
    /// the exact recorded host is dead. A live or ambiguous record is always
    /// retained for a later adoption attempt.
    pub fn remove_stale_terminal_host_record(
        record_path: &Path,
        expected: &TerminalHostRecord,
    ) -> anyhow::Result<bool> {
        if terminal_host_record_liveness(record_path, expected)? != TerminalHostLiveness::Dead {
            return Ok(false);
        }
        let current: TerminalHostRecord = serde_json::from_slice(&fs::read(record_path)?)?;
        validate_terminal_host_record(record_path, &current)?;
        if current.terminal_id != expected.terminal_id
            || current.incarnation != expected.incarnation
            || current.host_start_nonce != expected.host_start_nonce
        {
            return Ok(false);
        }
        let proof = liveness_path(record_path, &current);
        let endpoint = PathBuf::from(&current.endpoint);
        fs::remove_file(record_path)?;
        let _ = fs::remove_file(proof);
        if fs::symlink_metadata(&endpoint).is_ok_and(|metadata| metadata.file_type().is_socket()) {
            let _ = fs::remove_file(endpoint);
        }
        Ok(true)
    }

    pub fn load_terminal_host_records(
        root: &Path,
    ) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        load_terminal_host_records_with_policy(root, false)
    }

    pub(crate) fn load_terminal_host_records_for_reset(
        root: &Path,
    ) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        load_terminal_host_records_with_policy(root, true)
    }

    fn load_terminal_host_records_with_policy(
        root: &Path,
        fail_closed: bool,
    ) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        let mut records = Vec::new();
        let mut identities = HashSet::new();
        let entries = match fs::read_dir(root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(records),
            Err(error) => return Err(error.into()),
        };
        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            let bytes = match fs::read(&path) {
                Ok(bytes) => bytes,
                Err(_) if !fail_closed => continue,
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("read terminal-host record {}", path.display()));
                }
            };
            let record = match serde_json::from_slice::<TerminalHostRecord>(&bytes) {
                Ok(record) => record,
                Err(_) if !fail_closed => continue,
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("decode terminal-host record {}", path.display())
                    });
                }
            };
            if let Err(error) = validate_terminal_host_record(&path, &record) {
                if fail_closed {
                    return Err(error).with_context(|| {
                        format!("validate terminal-host record {}", path.display())
                    });
                }
                continue;
            }
            if !identities.insert((record.terminal_id.clone(), record.incarnation.clone())) {
                if fail_closed {
                    anyhow::bail!("duplicate terminal-host identity in {}", path.display());
                }
                continue;
            }
            records.push((path, record));
        }
        // Reset uses records only for marker membership and liveness checks, so
        // keep its fail-closed scan linear.
        if !fail_closed {
            records.sort_by(|left, right| left.0.cmp(&right.0));
        }
        Ok(records)
    }

    pub fn validate_terminal_host_exit_record(
        record_path: &Path,
        record: &TerminalHostExitRecord,
    ) -> anyhow::Result<()> {
        if record.record_version != HOST_EXIT_RECORD_VERSION {
            anyhow::bail!(
                "unsupported terminal-host exit record version {}",
                record.record_version
            );
        }
        TerminalId::from_hex(&record.terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal-host exit id is not a canonical UUIDv4"))?;
        HostIncarnation::from_hex(&record.incarnation).ok_or_else(|| {
            anyhow::anyhow!("terminal-host exit incarnation is not a canonical UUIDv4")
        })?;
        anyhow::ensure!(record.exit.is_valid(), "terminal-host exit outcome is invalid");
        let parent = record_path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("terminal-host exit record has no parent directory"))?;
        if record_path != parent.join(format!("{}.exit", record.terminal_id)) {
            anyhow::bail!("terminal-host exit record filename is not canonical");
        }
        let metadata = fs::symlink_metadata(record_path)?;
        let expected_uid = fs::metadata(parent)?.uid();
        if !metadata.file_type().is_file()
            || metadata.uid() != expected_uid
            || metadata.nlink() != 1
            || metadata.mode() & 0o077 != 0
        {
            anyhow::bail!("terminal-host exit record permissions or ownership are unsafe");
        }
        Ok(())
    }

    pub fn load_terminal_host_exit_records(
        root: &Path,
    ) -> anyhow::Result<Vec<(PathBuf, TerminalHostExitRecord)>> {
        let mut records = Vec::new();
        let mut identities = HashSet::new();
        let entries = match fs::read_dir(root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(records),
            Err(error) => return Err(error.into()),
        };
        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("exit") {
                continue;
            }
            let bytes = match fs::read(&path) {
                Ok(bytes) => bytes,
                Err(_) => continue,
            };
            let Ok(record) = serde_json::from_slice::<TerminalHostExitRecord>(&bytes) else {
                continue;
            };
            if validate_terminal_host_exit_record(&path, &record).is_err()
                || !identities.insert((record.terminal_id.clone(), record.incarnation.clone()))
            {
                continue;
            }
            records.push((path, record));
        }
        records.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(records)
    }

    pub fn terminal_host_exit_record(
        host_record_path: &Path,
    ) -> anyhow::Result<Option<(PathBuf, TerminalHostExitRecord)>> {
        let path = host_record_path.with_extension("exit");
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        let record = serde_json::from_slice::<TerminalHostExitRecord>(&bytes)?;
        validate_terminal_host_exit_record(&path, &record)?;
        Ok(Some((path, record)))
    }

    /// Acknowledge only the exact sidecar already committed to the registry.
    /// A mismatched replacement is retained for reconciliation rather than
    /// deleting evidence from another incarnation.
    pub fn acknowledge_terminal_host_exit_record(
        record_path: &Path,
        expected: &TerminalHostExitRecord,
    ) -> anyhow::Result<bool> {
        let bytes = match fs::read(record_path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error.into()),
        };
        let current: TerminalHostExitRecord = serde_json::from_slice(&bytes)?;
        validate_terminal_host_exit_record(record_path, &current)?;
        if &current != expected {
            return Ok(false);
        }
        fs::remove_file(record_path)?;
        if let Some(parent) = record_path.parent() {
            File::open(parent)?.sync_all()?;
        }
        Ok(true)
    }

    fn connect_record(
        record: TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<HostAttachment> {
        connect_record_with_timeout(record, record_path, HOST_HANDSHAKE_TIMEOUT)
    }

    fn connect_record_with_timeout(
        record: TerminalHostRecord,
        record_path: PathBuf,
        handshake_timeout: Duration,
    ) -> anyhow::Result<HostAttachment> {
        let endpoint = PathBuf::from(&record.endpoint);
        let mut stream = Some(
            connect_with_retry(&endpoint)
                .with_context(|| format!("connect terminal host at {}", endpoint.display()))?,
        );
        let mut failures = Vec::new();
        let attempts = std::iter::once((PROTOCOL_VERSION, true)).chain(
            (LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).rev().map(|version| (version, false)),
        );
        'protocols: for (protocol_version, smart_renderer) in attempts {
            let mut transient_retries = 0;
            loop {
                let error = match connect_record_at_version(
                    record.clone(),
                    record_path.clone(),
                    handshake_timeout,
                    protocol_version,
                    smart_renderer,
                    stream.take().expect("protocol attempt has a connected stream"),
                ) {
                    Ok(attachment) => return Ok(attachment),
                    Err(error) => error,
                };
                if transient_retries < HOST_HANDSHAKE_TRANSIENT_RETRIES
                    && is_transient_handshake_transport(&error)
                {
                    transient_retries += 1;
                    failures.push(format!(
                        "protocol {protocol_version} transient attempt {transient_retries}: {error:#}"
                    ));
                    match connect_with_retry(&endpoint) {
                        Ok(next_stream) => {
                            stream = Some(next_stream);
                            continue;
                        }
                        Err(reconnect_error) => {
                            failures.push(format!("protocol retry reconnect: {reconnect_error:#}"));
                            break 'protocols;
                        }
                    }
                }
                failures.push(format!("protocol {protocol_version}: {error:#}"));
                break;
            }
            match connect_with_retry(&endpoint) {
                Ok(next_stream) => stream = Some(next_stream),
                Err(error) => {
                    failures.push(format!("protocol fallback reconnect: {error:#}"));
                    break;
                }
            }
        }
        anyhow::bail!("terminal-host adoption failed: {}", failures.join("; "))
    }

    fn connect_current_record_with_timeout(
        record: TerminalHostRecord,
        record_path: PathBuf,
        handshake_timeout: Duration,
    ) -> anyhow::Result<HostAttachment> {
        if record.record_version >= HOST_RECORD_VERSION {
            // Fence-capable records are emitted only by the current smart
            // protocol. After an existing owner connection fails, probing
            // every legacy version can outlive the control request while the
            // already-terminating host removes its socket. One current
            // handshake is sufficient; durable tombstone reconciliation
            // retries independently if that bounded attempt loses the race.
            let endpoint = PathBuf::from(&record.endpoint);
            let stream = connect_with_retry(&endpoint)
                .with_context(|| format!("connect terminal host at {}", endpoint.display()))?;
            return connect_record_at_version(
                record,
                record_path,
                handshake_timeout,
                PROTOCOL_VERSION,
                true,
                stream,
            );
        }
        connect_record_with_timeout(record, record_path, handshake_timeout)
    }

    fn is_transient_handshake_transport(error: &anyhow::Error) -> bool {
        error.chain().any(|cause| {
            cause.downcast_ref::<std_io::Error>().is_some_and(|error| {
                matches!(
                    error.kind(),
                    std_io::ErrorKind::Interrupted
                        | std_io::ErrorKind::TimedOut
                        | std_io::ErrorKind::WouldBlock
                )
            })
        })
    }

    fn connect_record_at_version(
        record: TerminalHostRecord,
        record_path: PathBuf,
        handshake_timeout: Duration,
        protocol_version: u16,
        smart_renderer: bool,
        mut stream: UnixStream,
    ) -> anyhow::Result<HostAttachment> {
        if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
            anyhow::bail!("unsupported terminal-host adoption protocol {protocol_version}");
        }
        let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id)?);
        let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?);
        let owner_token = CapabilityToken::from_bytes(decode_hex_array(&record.owner_token)?);
        stream.set_read_timeout(Some(handshake_timeout))?;
        stream.set_write_timeout(Some(handshake_timeout))?;
        let hello = ClientHello {
            min_version: protocol_version,
            max_version: protocol_version,
            role: ClientRole::Admin,
            requested_rights: CapabilityRights::ADMIN,
            terminal_id,
            token: owner_token,
        };
        let mut hello_frame = hello.into_frame(1);
        hello_frame.version = protocol_version;
        if smart_renderer {
            hello_frame.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
        }
        write_frame(&mut stream, &hello_frame)?;
        let hello_frame = read_required_frame(&mut stream, "host hello")?;
        if hello_frame.kind != MessageKind::HostHello
            || hello_frame.version != protocol_version
            || hello_frame.flags
                & !(FLAG_VIEWER_SIZE_ACKS | FLAG_SMART_RENDERER | FLAG_LAUNCH_ACTIVATION_REQUIRED)
                != 0
            || hello_frame.request_id != 1
            || hello_frame.sequence != 0
            || (smart_renderer && hello_frame.flags & FLAG_SMART_RENDERER == 0)
        {
            anyhow::bail!("terminal host rejected owner handshake");
        }
        let launch_activation_pending = hello_frame.flags & FLAG_LAUNCH_ACTIVATION_REQUIRED != 0;
        if launch_activation_pending && protocol_version < LAUNCH_ACTIVATION_PROTOCOL_VERSION {
            anyhow::bail!("legacy terminal host requested launch activation");
        }
        let host_hello = HostHello::decode(&hello_frame.payload)?;
        if host_hello.selected_version != protocol_version
            || host_hello.terminal_id != terminal_id
            || host_hello.incarnation != incarnation
            || host_hello.granted_rights != CapabilityRights::ADMIN
        {
            anyhow::bail!("terminal-host record identity does not match live host");
        }
        let snapshot_frame = read_required_frame(&mut stream, "terminal snapshot")?;
        if snapshot_frame.kind != MessageKind::Snapshot
            || snapshot_frame.version != protocol_version
            || snapshot_frame.flags != 0
            || snapshot_frame.request_id != 0
        {
            anyhow::bail!("terminal host did not send an initial snapshot");
        }
        let mut snapshot = decode_snapshot_for_version(&snapshot_frame.payload, protocol_version)?;
        let colors_frame = read_required_frame(&mut stream, "terminal color state")?;
        if colors_frame.kind != MessageKind::Colors
            || colors_frame.version != protocol_version
            || colors_frame.flags != 0
            || colors_frame.sequence != snapshot_frame.sequence
            || colors_frame.request_id != 0
        {
            anyhow::bail!("terminal host did not send Colors at the snapshot sequence boundary");
        }
        snapshot.sequence_boundary = snapshot_frame.sequence;
        snapshot.colors = decode_terminal_color_overrides(&colors_frame.payload)?;
        if smart_renderer {
            let ready_frame = read_required_frame(&mut stream, "terminal ready boundary")?;
            if ready_frame.kind != MessageKind::Ready
                || ready_frame.version != protocol_version
                || ready_frame.flags != 0
                || ready_frame.sequence != snapshot_frame.sequence
                || ready_frame.request_id != 0
                || !ready_frame.payload.is_empty()
            {
                anyhow::bail!("terminal host did not send Ready at the snapshot sequence boundary");
            }
        }
        let snapshot_size = (snapshot.cols, snapshot.rows);
        stream.set_read_timeout(None)?;
        // Keep bounded writes for the lifetime of the disposable admin
        // mirror. A stopped or wedged host must not block a mux/control thread
        // forever while it sends input, mouse, resize, or Terminate. Reads are
        // unbounded because the dedicated reader thread is intentionally
        // long-lived and reconnects on any eventual EOF/protocol failure.
        let reader = stream.try_clone()?;
        let attachment = HostAttachment {
            record,
            record_path,
            snapshot,
            protocol_version,
            smart_renderer,
            reader: Some(reader),
            writer: Arc::new(Mutex::new(stream)),
            control_responses: Arc::new(ControlResponses::new()),
            next_request: AtomicU64::new(2),
            // New hosts do not register Admin as a viewer. Initialize this as
            // if they did so the unconditional release below also upgrades
            // live protocol-v1 hosts whose older implementation registered
            // every connection at the snapshot grid.
            viewer_size: Mutex::new(Some(snapshot_size)),
            launch_process: None,
            launch_activation_pending,
        };
        attachment.release_viewer_size()?;
        Ok(attachment)
    }

    fn connect_with_retry(path: &Path) -> anyhow::Result<UnixStream> {
        let deadline = Instant::now() + HOST_CONNECT_RETRY_WINDOW;
        loop {
            match UnixStream::connect(path) {
                Ok(stream) => return Ok(stream),
                Err(error) => {
                    let now = Instant::now();
                    if now >= deadline {
                        return Err(error.into());
                    }
                    thread::sleep(HOST_CONNECT_RETRY_INTERVAL.min(deadline - now));
                }
            }
        }
    }

    fn read_required_frame(reader: &mut impl Read, context: &str) -> anyhow::Result<Frame> {
        read_frame(reader, MAX_FRAME_PAYLOAD)?
            .ok_or_else(|| anyhow::anyhow!("terminal host closed before {context}"))
    }

    fn write_record(path: &Path, record: &TerminalHostRecord) -> anyhow::Result<()> {
        write_json_record(path, record)
    }

    fn write_exit_record(path: &Path, record: &TerminalHostExitRecord) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            prepare_private_dir(parent)?;
        }
        let temporary = path.with_extension(format!(
            "tmp-{}-{}",
            std::process::id(),
            RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let bytes = serde_json::to_vec(record)?;
        let result = (|| -> anyhow::Result<bool> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            match rename_no_replace(&temporary, path) {
                Ok(()) => {
                    if let Some(parent) = path.parent() {
                        File::open(parent)?.sync_all()?;
                    }
                    Ok(true)
                }
                Err(error) if error.kind() == std_io::ErrorKind::AlreadyExists => Ok(false),
                Err(error) => Err(error.into()),
            }
        })();
        if temporary.exists() {
            let _ = fs::remove_file(&temporary);
        }
        if result? {
            return validate_terminal_host_exit_record(path, record);
        }
        let current: TerminalHostExitRecord = serde_json::from_slice(&fs::read(path)?)?;
        validate_terminal_host_exit_record(path, &current)?;
        anyhow::ensure!(
            current == *record,
            "terminal-host exit sidecar already contains a different outcome"
        );
        Ok(())
    }

    fn exit_persistence_diagnostic_path(exit_record_path: &Path) -> PathBuf {
        exit_record_path.with_extension("exit-error")
    }

    fn write_exit_persistence_diagnostic(
        exit_record_path: &Path,
        attempt: u64,
        error: &anyhow::Error,
    ) -> std_io::Result<()> {
        let path = exit_persistence_diagnostic_path(exit_record_path);
        if let Some(parent) = path.parent() {
            prepare_private_dir(parent).map_err(std_io::Error::other)?;
        }
        let message = format!(
            "terminal-host exit persistence failed on attempt {attempt}; retrying: {error:#}\n"
        );
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        file.write_all(message.as_bytes())?;
        file.sync_all()
    }

    fn clear_exit_persistence_diagnostic(exit_record_path: &Path) {
        match fs::remove_file(exit_persistence_diagnostic_path(exit_record_path)) {
            Ok(()) => {}
            Err(error) if error.kind() == std_io::ErrorKind::NotFound => {}
            Err(_) => {}
        }
    }

    fn next_exit_persistence_retry_delay(delay: Duration) -> Duration {
        delay.saturating_mul(2).min(HOST_EXIT_PERSIST_RETRY_MAX)
    }

    #[cfg(target_vendor = "apple")]
    fn rename_no_replace(from: &Path, to: &Path) -> std_io::Result<()> {
        let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| {
            std_io::Error::new(std_io::ErrorKind::InvalidInput, "temporary path has NUL")
        })?;
        let to = CString::new(to.as_os_str().as_bytes()).map_err(|_| {
            std_io::Error::new(std_io::ErrorKind::InvalidInput, "exit path has NUL")
        })?;
        // SAFETY: both pointers reference live NUL-terminated path strings,
        // and RENAME_EXCL asks the kernel to leave an existing target intact.
        if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
            Ok(())
        } else {
            Err(std_io::Error::last_os_error())
        }
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn rename_no_replace(from: &Path, to: &Path) -> std_io::Result<()> {
        let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| {
            std_io::Error::new(std_io::ErrorKind::InvalidInput, "temporary path has NUL")
        })?;
        let to = CString::new(to.as_os_str().as_bytes()).map_err(|_| {
            std_io::Error::new(std_io::ErrorKind::InvalidInput, "exit path has NUL")
        })?;
        // SAFETY: both pointers reference live NUL-terminated path strings,
        // and RENAME_NOREPLACE asks the kernel to leave an existing target intact.
        // Call the syscall directly because musl does not export a `renameat2`
        // wrapper symbol.
        if unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                libc::AT_FDCWD,
                from.as_ptr(),
                libc::AT_FDCWD,
                to.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        } == 0
        {
            Ok(())
        } else {
            Err(std_io::Error::last_os_error())
        }
    }

    fn write_json_record(path: &Path, record: &impl Serialize) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            prepare_private_dir(parent)?;
        }
        let temporary = path.with_extension(format!(
            "tmp-{}-{}",
            std::process::id(),
            RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let bytes = serde_json::to_vec(record)?;
        let result = (|| -> anyhow::Result<()> {
            let mut file =
                OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, path)?;
            if let Some(parent) = path.parent() {
                File::open(parent)?.sync_all()?;
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    fn prepare_private_dir(path: &Path) -> anyhow::Result<()> {
        fs::create_dir_all(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        Ok(())
    }

    #[derive(Clone)]
    struct HostTap {
        sender: Sender<Frame>,
        queued_bytes: Arc<AtomicUsize>,
        queued_output_bytes: Arc<AtomicUsize>,
        shutdown: Arc<UnixStream>,
        max_queued_bytes: usize,
    }

    impl HostTap {
        fn new(sender: Sender<Frame>, shutdown: Arc<UnixStream>, max_queued_bytes: usize) -> Self {
            Self {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown,
                max_queued_bytes,
            }
        }

        fn try_reserve(counter: &AtomicUsize, retained: usize, limit: usize) -> bool {
            let mut queued = counter.load(Ordering::Acquire);
            loop {
                let Some(next) = queued.checked_add(retained) else {
                    return false;
                };
                if next > limit {
                    return false;
                }
                match counter.compare_exchange_weak(
                    queued,
                    next,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => return true,
                    Err(actual) => queued = actual,
                }
            }
        }

        fn try_send(&self, frame: Frame) -> bool {
            let retained =
                crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len());
            if !Self::try_reserve(&self.queued_bytes, retained, self.max_queued_bytes) {
                self.close();
                return false;
            }
            let is_output = frame.kind == MessageKind::Output;
            if is_output
                && !Self::try_reserve(
                    &self.queued_output_bytes,
                    retained,
                    MAX_HOST_CLIENT_OUTPUT_QUEUED_BYTES,
                )
            {
                self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
                self.close();
                return false;
            }
            // The byte reservations above are the queue's single admission
            // limit. The channel itself must not add a scheduler-sensitive
            // frame-count limit that disconnects a client while most of its
            // declared byte budget is still free.
            match self.sender.send(frame) {
                Ok(()) => true,
                Err(_) => {
                    self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
                    if is_output {
                        self.queued_output_bytes.fetch_sub(retained, Ordering::AcqRel);
                    }
                    self.close();
                    false
                }
            }
        }

        fn release(&self, frame: &Frame) {
            let retained =
                crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len());
            self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
            if frame.kind == MessageKind::Output {
                self.queued_output_bytes.fetch_sub(retained, Ordering::AcqRel);
            }
        }

        fn close(&self) {
            let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
        }

        fn close_and_wake_writer(&self) {
            self.close();
            // The receiver cannot observe channel disconnection while the
            // writer's local HostTap still owns a sender. Enqueue one private
            // sentinel so an input-side EOF always releases an otherwise-idle
            // writer. Socket shutdown releases a writer blocked in write_frame.
            let wake = Frame::new(MessageKind::ResyncRequired, Vec::new());
            let retained = crate::terminal_host_protocol::HEADER_LEN;
            self.queued_bytes.fetch_add(retained, Ordering::AcqRel);
            if self.sender.send(wake).is_err() {
                self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
            }
        }

        fn wake_writer(&self) {
            // The source-ordered DetachAck is already queued. This private
            // sentinel closes the writer loop after it writes that receipt,
            // without shutting the socket before the receipt is drained.
            let wake = Frame::new(MessageKind::ResyncRequired, Vec::new());
            let retained = crate::terminal_host_protocol::HEADER_LEN;
            self.queued_bytes.fetch_add(retained, Ordering::AcqRel);
            if self.sender.send(wake).is_err() {
                self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
            }
        }
    }

    /// Source-ordered raw terminal stream used only by negotiated smart
    /// renderers. Its cursor is deliberately independent of the legacy
    /// parser-ordered CMTH stream: publishing raw PTY bytes must not wait for
    /// the authoritative Ghostty parser, while legacy renderers keep their
    /// normalized Output + coupled Colors contract unchanged.
    struct SmartStreamState {
        broadcast_lock: Mutex<()>,
        taps: Mutex<HashMap<u64, HostTap>>,
        source_cursor: AtomicU64,
        applied_cursor: AtomicU64,
        retained: Mutex<SmartRetention>,
    }

    impl SmartStreamState {
        fn new() -> Self {
            Self {
                broadcast_lock: Mutex::new(()),
                taps: Mutex::new(HashMap::new()),
                source_cursor: AtomicU64::new(0),
                applied_cursor: AtomicU64::new(0),
                retained: Mutex::new(SmartRetention::default()),
            }
        }

        /// Publish before parsing. The returned source cursor is marked
        /// applied only after the authoritative parser has consumed the same
        /// transition.
        fn publish(&self, mut frame: Frame) -> u64 {
            let _broadcast = self.broadcast_lock.lock().unwrap();
            let cursor = self.source_cursor.fetch_add(1, Ordering::AcqRel) + 1;
            frame.sequence = cursor;
            self.retained.lock().unwrap().push(frame.clone());
            self.taps.lock().unwrap().retain(|_, tap| tap.try_send(frame.clone()));
            cursor
        }

        fn publish_after_targeted(
            &self,
            targeted: &HostTap,
            targeted_frame: Frame,
            mut frame: Frame,
        ) -> (u64, bool) {
            let _broadcast = self.broadcast_lock.lock().unwrap();
            let targeted_queued = targeted.try_send(targeted_frame);
            let cursor = self.source_cursor.fetch_add(1, Ordering::AcqRel) + 1;
            frame.sequence = cursor;
            self.retained.lock().unwrap().push(frame.clone());
            self.taps.lock().unwrap().retain(|_, tap| tap.try_send(frame.clone()));
            (cursor, targeted_queued)
        }

        fn mark_applied(&self, cursor: u64) {
            let prior = self.applied_cursor.fetch_max(cursor, Ordering::AcqRel);
            debug_assert!(prior <= cursor, "smart parser cursor moved backwards");
        }

        fn close_failed_transition(&self, source_cursor: Option<u64>) {
            if source_cursor.is_none() {
                return;
            }
            let cursor = self.publish(Frame::new(MessageKind::ResyncRequired, Vec::new()));
            // The failed marker is closed by an explicit applied boundary.
            // New clients snapshot after it; connected clients restart the
            // handshake instead of waiting forever for an unapplied cursor.
            self.mark_applied(cursor);
        }

        /// Called while the terminal parser lock is held. It queues retained
        /// frames before inserting the tap, all under the source publication
        /// lock, so the caller may release its parser lock and perform socket
        /// writes without opening an attach race.
        fn subscribe(&self, client: u64, tap: HostTap) -> Result<u64, SmartReplayGap> {
            let _broadcast = self.broadcast_lock.lock().unwrap();
            let boundary = self.applied_cursor.load(Ordering::Acquire);
            let backlog = self.retained.lock().unwrap().after(boundary)?;
            for frame in backlog {
                if !tap.try_send(frame) {
                    return Err(SmartReplayGap::SubscriberQueueOverflow { boundary });
                }
            }
            self.taps.lock().unwrap().insert(client, tap);
            Ok(boundary)
        }

        fn remove(&self, client: u64) {
            self.taps.lock().unwrap().remove(&client);
        }

        #[cfg(test)]
        fn is_empty(&self) -> bool {
            self.taps.lock().unwrap().is_empty()
        }
    }

    #[derive(Default)]
    struct SmartRetention {
        frames: VecDeque<Frame>,
        bytes: usize,
        dropped_through: u64,
    }

    impl SmartRetention {
        fn push(&mut self, frame: Frame) {
            let retained = retained_frame_bytes(&frame);
            self.bytes = self.bytes.saturating_add(retained);
            self.frames.push_back(frame);
            while self.bytes > MAX_SMART_RETAINED_BYTES
                || self.frames.len() > MAX_SMART_RETAINED_FRAMES
            {
                let Some(frame) = self.frames.pop_front() else { break };
                self.bytes = self.bytes.saturating_sub(retained_frame_bytes(&frame));
                self.dropped_through = frame.sequence;
            }
        }

        fn after(&self, cursor: u64) -> Result<Vec<Frame>, SmartReplayGap> {
            if cursor < self.dropped_through {
                return Err(SmartReplayGap::Retention {
                    requested_after: cursor,
                    retained_after: self.dropped_through,
                });
            }
            Ok(self.frames.iter().filter(|frame| frame.sequence > cursor).cloned().collect())
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum SmartReplayGap {
        Retention { requested_after: u64, retained_after: u64 },
        SubscriberQueueOverflow { boundary: u64 },
    }

    impl SmartReplayGap {
        fn encode(self) -> Vec<u8> {
            let (requested_after, retained_after, reason) = match self {
                Self::Retention { requested_after, retained_after } => {
                    (requested_after, retained_after, 0)
                }
                Self::SubscriberQueueOverflow { boundary } => (boundary, boundary, 1),
            };
            let mut payload = Vec::with_capacity(17);
            payload.extend_from_slice(&requested_after.to_le_bytes());
            payload.extend_from_slice(&retained_after.to_le_bytes());
            payload.push(reason);
            payload
        }
    }

    fn retained_frame_bytes(frame: &Frame) -> usize {
        crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len())
    }

    enum ParserCommand {
        Output {
            bytes: Vec<u8>,
            source_cursor: u64,
            accounted_bytes: usize,
        },
        Resize {
            cols: u16,
            rows: u16,
            cell_pixels: (u16, u16),
            source_cursor: Option<u64>,
            acknowledge_with_replay: bool,
            targeted_ack: Option<(u64, HostTap)>,
            response: SyncSender<ParserResizeResult>,
        },
        SetDefaults {
            colors: Box<DefaultColors>,
            source_cursor: u64,
            response: SyncSender<()>,
        },
        ClearHistory {
            fallback_key: Option<KeyInput>,
            response: SyncSender<Result<ParserClearHistoryResult, String>>,
        },
        Drain,
    }

    #[derive(Debug, Clone)]
    struct ParserResizeResult {
        acknowledgement_queued: Result<bool, String>,
        changed: bool,
        applied: (u16, u16),
    }

    enum ParserClearHistoryResult {
        Cleared(Vec<u8>),
        Blocked,
        EncodedFallback(Vec<u8>),
        Noop,
    }

    enum ClearHistoryAckDisposition {
        Pending,
        Queued,
        ConnectionClosed,
    }

    struct ParserBudget {
        queued_bytes: Mutex<usize>,
        available: Condvar,
        max_bytes: usize,
    }

    impl ParserBudget {
        fn new(max_bytes: usize) -> Self {
            Self { queued_bytes: Mutex::new(0), available: Condvar::new(), max_bytes }
        }

        fn reserve(&self, bytes: usize) {
            debug_assert!(bytes <= self.max_bytes);
            let queued = self.queued_bytes.lock().unwrap();
            let mut queued = self
                .available
                .wait_while(queued, |queued| queued.saturating_add(bytes) > self.max_bytes)
                .unwrap();
            *queued += bytes;
        }

        fn release(&self, bytes: usize) {
            let mut queued = self.queued_bytes.lock().unwrap();
            *queued =
                queued.checked_sub(bytes).expect("parser budget released more bytes than reserved");
            self.available.notify_all();
        }
    }

    fn enqueue_parser_output(
        parser_commands: &SyncSender<ParserCommand>,
        parser_budget: &ParserBudget,
        smart: &SmartStreamState,
        bytes: Vec<u8>,
        source_cursor: u64,
        accounted_bytes: usize,
    ) -> bool {
        if parser_commands
            .send(ParserCommand::Output { bytes, source_cursor, accounted_bytes })
            .is_ok()
        {
            return true;
        }

        parser_budget.release(accounted_bytes);
        smart.close_failed_transition(Some(source_cursor));
        false
    }

    fn wait_for_pty_readable_or_forced_drain(
        pty_fd: RawFd,
        drain_waiter: &mut UnixStream,
        force_drain: &AtomicBool,
        forced_at: &mut Option<Instant>,
    ) -> std::io::Result<bool> {
        loop {
            if force_drain.load(Ordering::Acquire) {
                let started = forced_at.get_or_insert_with(Instant::now);
                if started.elapsed() >= HOST_FORCED_DRAIN_WINDOW {
                    return Ok(false);
                }
            }
            let mut poll_fds = [
                libc::pollfd {
                    fd: pty_fd,
                    events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                    revents: 0,
                },
                libc::pollfd {
                    fd: drain_waiter.as_raw_fd(),
                    events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                    revents: 0,
                },
            ];
            let timeout_ms = forced_at
                .map(|started| {
                    let remaining = HOST_FORCED_DRAIN_WINDOW.saturating_sub(started.elapsed());
                    remaining.as_millis().clamp(1, i32::MAX as u128) as i32
                })
                .unwrap_or(-1);
            // SAFETY: poll_fds points to two initialized values and both
            // descriptors remain owned by the caller for this call.
            let ready = unsafe {
                libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, timeout_ms)
            };
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if poll_fds[0].revents & libc::POLLNVAL != 0 {
                return Ok(false);
            }
            if poll_fds[1].revents & libc::POLLIN != 0 {
                let mut wake = [0u8; 64];
                let _ = drain_waiter.read(&mut wake);
            }
            if poll_fds[0].revents != 0 {
                return Ok(true);
            }
            if poll_fds[1].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
                && !force_drain.load(Ordering::Acquire)
            {
                return Ok(false);
            }
            // A wake transitions the next iteration into forced mode. While
            // forced, an empty poll waits again until the remaining bounded
            // window expires so late final bytes are still observed.
        }
    }

    struct HostShared {
        terminal_id: TerminalId,
        incarnation: HostIncarnation,
        owner_token: CapabilityToken,
        capabilities: CapabilityStore,
        term: Mutex<Terminal>,
        default_colors: Mutex<DefaultColors>,
        stream_progress: TerminalStreamProgress,
        writer: Mutex<Box<dyn Write + Send>>,
        master: Mutex<Box<dyn MasterPty + Send>>,
        killer: Mutex<Box<dyn ChildKiller + Send>>,
        pid: Option<u32>,
        command: Vec<String>,
        cwd: Option<String>,
        size: Mutex<(u16, u16)>,
        cell_pixels: Mutex<(u16, u16)>,
        viewer_sizes: Mutex<HashMap<u64, (u16, u16)>>,
        taps: Mutex<HashMap<u64, HostTap>>,
        broadcast_lock: Mutex<()>,
        sequence: AtomicU64,
        smart: SmartStreamState,
        /// Orders source-cursor allocation and parser-command enqueueing. A
        /// resize keeps this lock until all prior parser commands drain, which
        /// gives both the host and smart clients the same output/resize order.
        source_order_lock: Mutex<()>,
        parser_commands: SyncSender<ParserCommand>,
        parser_budget: ParserBudget,
        /// Generation advanced after each parser write. Snapshot admission
        /// waits here when a PTY read ends inside UTF-8 or a control sequence,
        /// without blocking the reader from enqueueing the completing bytes.
        parser_progress: (Mutex<u64>, Condvar),
        next_client: AtomicU64,
        dead: AtomicBool,
        launch_owner_claimed: AtomicBool,
        launch_owner_stream_ready: AtomicBool,
        launch_owner_stream_gate: (Mutex<()>, Condvar),
        active_client_streams: AtomicUsize,
        child_exit: (Mutex<Option<TerminalExit>>, Condvar),
        child_waitable: AtomicBool,
        pty_drained: AtomicBool,
        exit_published: AtomicBool,
        exit_record_path: PathBuf,
        exit_publish_requests: Sender<()>,
        force_pty_drain: AtomicBool,
        pty_drain_waker: Mutex<UnixStream>,
        termination_started: AtomicBool,
        child_signal_lock: Mutex<()>,
        child_reaped: AtomicBool,
        group_escalation_complete: AtomicBool,
        #[cfg(test)]
        fail_next_resize_publication: AtomicBool,
    }

    struct LaunchOwnerConnection {
        host: Arc<HostShared>,
        claimed: bool,
    }

    impl LaunchOwnerConnection {
        fn claim(host: Arc<HostShared>, granted_rights: CapabilityRights) -> Self {
            let claimed = granted_rights.contains(CapabilityRights::ADMIN)
                && host
                    .launch_owner_claimed
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok();
            Self { host, claimed }
        }

        fn stream_ready(&self) {
            if !self.claimed {
                return;
            }
            self.host.mark_launch_owner_stream_ready();
        }
    }

    impl Drop for LaunchOwnerConnection {
        fn drop(&mut self) {
            if !self.claimed {
                return;
            }
            // A failed initial stream must release the same launch barrier as
            // a successful one. The launching daemon reports the handshake
            // failure, while the independently hosted process can still
            // publish or clean up its terminal exit.
            self.host.mark_launch_owner_stream_ready();
        }
    }

    struct ActiveClientStream {
        host: Arc<HostShared>,
    }

    impl ActiveClientStream {
        fn register(host: Arc<HostShared>) -> Self {
            host.active_client_streams.fetch_add(1, Ordering::AcqRel);
            Self { host }
        }
    }

    impl Drop for ActiveClientStream {
        fn drop(&mut self) {
            let previous = self.host.active_client_streams.fetch_sub(1, Ordering::AcqRel);
            debug_assert!(previous > 0, "active terminal-host stream underflow");
        }
    }

    struct ClientSetupRollback {
        host: Arc<HostShared>,
        client: u64,
        armed: bool,
    }

    impl ClientSetupRollback {
        fn new(host: Arc<HostShared>, client: u64) -> Self {
            Self { host, client, armed: true }
        }

        fn disarm(&mut self) {
            self.armed = false;
        }
    }

    impl Drop for ClientSetupRollback {
        fn drop(&mut self) {
            if self.armed {
                self.host.remove_client(self.client);
            }
        }
    }

    fn publish_host_frames(
        broadcast_lock: &Mutex<()>,
        sequence: &AtomicU64,
        taps: &Mutex<HashMap<u64, HostTap>>,
        frames: impl IntoIterator<Item = Frame>,
    ) {
        let _ = publish_host_frames_and_targeted(broadcast_lock, sequence, taps, frames, None);
    }

    fn publish_host_frames_and_targeted(
        broadcast_lock: &Mutex<()>,
        sequence: &AtomicU64,
        taps: &Mutex<HashMap<u64, HostTap>>,
        frames: impl IntoIterator<Item = Frame>,
        targeted: Option<(&HostTap, Frame)>,
    ) -> bool {
        // Sequence allocation and publication are one critical section;
        // otherwise concurrent output/resize/exit producers could mint N
        // then publish N+1 first, split a coupled Output/Colors pair, or place
        // a targeted acknowledgement before its canonical transition.
        let _broadcast = broadcast_lock.lock().unwrap();
        let mut taps = taps.lock().unwrap();
        for mut frame in frames {
            let sequence = sequence.fetch_add(1, Ordering::AcqRel) + 1;
            frame.sequence = sequence;
            taps.retain(|_, tap| tap.try_send(frame.clone()));
        }
        drop(taps);
        targeted.is_none_or(|(tap, frame)| tap.try_send(frame))
    }

    fn changed_pwd_frame(
        last_pwd: &mut Option<String>,
        current_pwd: Option<String>,
    ) -> Option<Frame> {
        // Track only the parser's raw OSC 7 state. Folding in the spawn-CWD
        // fallback here would hide a Some -> None transition from live clients.
        if last_pwd.as_deref() == current_pwd.as_deref() {
            return None;
        }
        let payload = current_pwd.as_deref().unwrap_or_default().as_bytes().to_vec();
        *last_pwd = current_pwd;
        Some(Frame::new(MessageKind::Pwd, payload))
    }

    fn output_transition_frames(
        output: Vec<u8>,
        colors: Option<Vec<u8>>,
        pwd: Option<Frame>,
    ) -> Vec<Frame> {
        let mut frames = Vec::with_capacity(3);
        let mut output = Frame::new(MessageKind::Output, output);
        if let Some(colors) = colors {
            output.flags = FLAG_COLORS_FOLLOW;
            frames.push(output);
            frames.push(Frame::new(MessageKind::Colors, colors));
        } else {
            frames.push(output);
        }
        frames.extend(pwd);
        frames
    }

    fn snapshot_cwd(term: &Terminal, spawn_cwd: Option<&str>) -> Option<String> {
        term.pwd().or_else(|| spawn_cwd.map(str::to_owned))
    }

    impl HostShared {
        fn mark_launch_owner_stream_ready(&self) {
            let _gate = self.launch_owner_stream_gate.0.lock().unwrap();
            if !self.launch_owner_stream_ready.swap(true, Ordering::AcqRel) {
                self.launch_owner_stream_gate.1.notify_all();
            }
            self.publish_exit_if_drained();
        }

        fn wait_for_launch_owner_stream_ready(&self) {
            if self.launch_owner_stream_ready.load(Ordering::Acquire) {
                return;
            }
            let mut gate = self.launch_owner_stream_gate.0.lock().unwrap();
            while !self.launch_owner_stream_ready.load(Ordering::Acquire) {
                gate = self.launch_owner_stream_gate.1.wait(gate).unwrap();
            }
        }

        fn note_parser_progress(&self) {
            let mut generation = self.parser_progress.0.lock().unwrap();
            *generation = generation.wrapping_add(1);
            self.parser_progress.1.notify_all();
        }

        fn terminal_at_snapshot_boundary(
            &self,
            timeout: Duration,
        ) -> anyhow::Result<std::sync::MutexGuard<'_, Terminal>> {
            let deadline = Instant::now() + timeout;
            let mut generation = self.parser_progress.0.lock().unwrap();
            loop {
                let term = self.term.lock().unwrap();
                if term.vt_stream_is_ground() {
                    drop(generation);
                    return Ok(term);
                }
                drop(term);
                if self.dead.load(Ordering::Acquire) {
                    anyhow::bail!("terminal host exited before a safe snapshot boundary");
                }

                let now = Instant::now();
                if now >= deadline {
                    anyhow::bail!(
                        "terminal VT stream did not reach a safe snapshot boundary before timeout"
                    );
                }
                let observed = *generation;
                let (next, wait) = self
                    .parser_progress
                    .1
                    .wait_timeout_while(generation, deadline - now, |current| {
                        *current == observed && !self.dead.load(Ordering::Acquire)
                    })
                    .unwrap();
                generation = next;
                if wait.timed_out() && *generation == observed {
                    anyhow::bail!(
                        "terminal VT stream did not reach a safe snapshot boundary before timeout"
                    );
                }
            }
        }

        fn broadcast(&self, kind: MessageKind, payload: Vec<u8>) {
            self.broadcast_frames([Frame::new(kind, payload)]);
        }

        fn broadcast_frames(&self, frames: impl IntoIterator<Item = Frame>) {
            publish_host_frames(&self.broadcast_lock, &self.sequence, &self.taps, frames);
        }

        fn broadcast_with_colors(&self, kind: MessageKind, payload: Vec<u8>, colors: Vec<u8>) {
            debug_assert!(matches!(kind, MessageKind::Output | MessageKind::Resized));
            let mut first = Frame::new(kind, payload);
            first.flags = FLAG_COLORS_FOLLOW;
            self.broadcast_frames([first, Frame::new(MessageKind::Colors, colors)]);
        }

        fn set_default_colors(&self, colors: DefaultColors) {
            // Default changes have no raw VT representation. Order an
            // explicit resync marker with PTY bytes, then apply the defaults
            // on the FIFO parser worker before advancing its snapshot
            // boundary. Legacy mirrors retain their coupled color update.
            let _source_order = self.source_order_lock.lock().unwrap();
            if *self.default_colors.lock().unwrap() == colors {
                return;
            }
            let source_cursor =
                self.smart.publish(Frame::new(MessageKind::ResyncRequired, Vec::new()));
            let (response, applied) = sync_channel(1);
            if self
                .parser_commands
                .send(ParserCommand::SetDefaults {
                    colors: Box::new(colors),
                    source_cursor,
                    response,
                })
                .is_err()
            {
                self.smart.mark_applied(source_cursor);
                return;
            }
            if applied.recv().is_ok() {
                *self.default_colors.lock().unwrap() = colors;
            } else {
                self.smart.mark_applied(source_cursor);
            }
        }

        fn apply_parser_defaults(
            &self,
            colors: DefaultColors,
            source_cursor: u64,
        ) -> TerminalColorOverrides {
            let resolved = {
                let mut term = self.term.lock().unwrap();
                term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
                term.set_default_palette(&colors.palette);
                replace_ghostty_cursor_defaults(&mut term, colors);
                let resolved = term.color_overrides();
                // An empty coupled Output is an ordered state transition
                // already understood by every legacy v2 consumer. Smart
                // clients reopen from the ResyncRequired snapshot boundary
                // published by the command submitter.
                self.broadcast_with_colors(
                    MessageKind::Output,
                    Vec::new(),
                    encode_terminal_color_overrides(&resolved),
                );
                self.smart.mark_applied(source_cursor);
                resolved
            };
            self.note_parser_progress();
            resolved
        }

        fn clear_history_or_encode_key(
            &self,
            fallback_key: Option<&KeyInput>,
            smart_ack: Option<(u64, &HostTap)>,
        ) -> Result<ClearHistoryAckDisposition, ClearHistoryFailure> {
            let mut observed_progress = self.stream_progress.revision();
            let mut stream_wait = None;
            loop {
                // Clear-history observes and mutates parser state. Keep its
                // command in the same FIFO as PTY output while holding source
                // order so neither already-read nor later bytes can cross the
                // emulator-only transition.
                let (result, acknowledgement) = {
                    let _source_order = self.source_order_lock.lock().unwrap();
                    let (response, applied) = sync_channel(1);
                    if self
                        .parser_commands
                        .send(ParserCommand::ClearHistory {
                            fallback_key: fallback_key.cloned(),
                            response,
                        })
                        .is_err()
                    {
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal parser worker stopped"
                        )));
                    }
                    let result = applied
                        .recv()
                        .map_err(|_| {
                            ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                                "terminal parser worker stopped"
                            ))
                        })?
                        .map_err(|error| {
                            ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(error))
                        })?;
                    let acknowledgement = match &result {
                        ParserClearHistoryResult::Cleared(clear) => {
                            let marker = Frame::new(MessageKind::ResyncRequired, Vec::new());
                            let (source_cursor, acknowledgement) =
                                if let Some((request_id, target)) = smart_ack {
                                    let mut payload = Vec::with_capacity(1 + clear.len());
                                    payload.push(CLEAR_HISTORY_ACK_OK);
                                    payload.extend_from_slice(clear);
                                    let mut response =
                                        Frame::new(MessageKind::ClearHistoryAck, payload);
                                    response.request_id = request_id;
                                    let (source_cursor, queued) =
                                        self.smart.publish_after_targeted(target, response, marker);
                                    (
                                        source_cursor,
                                        if queued {
                                            ClearHistoryAckDisposition::Queued
                                        } else {
                                            ClearHistoryAckDisposition::ConnectionClosed
                                        },
                                    )
                                } else {
                                    (
                                        self.smart.publish(marker),
                                        ClearHistoryAckDisposition::Pending,
                                    )
                                };
                            self.smart.mark_applied(source_cursor);
                            Some(acknowledgement)
                        }
                        _ => None,
                    };
                    (result, acknowledgement)
                };
                match result {
                    ParserClearHistoryResult::Cleared(_) => {
                        return Ok(acknowledgement
                            .expect("a cleared parser transition has an acknowledgement"));
                    }
                    ParserClearHistoryResult::Noop => {
                        return Ok(ClearHistoryAckDisposition::Pending);
                    }
                    ParserClearHistoryResult::Blocked => {
                        let deadline = stream_wait
                            .get_or_insert_with(|| {
                                self.stream_progress
                                    .begin_clear_history_wait(CLEAR_HISTORY_STREAM_WAIT_TIMEOUT)
                            })
                            .deadline();
                        let Some(progress) =
                            self.stream_progress.wait_for_change(observed_progress, deadline)
                        else {
                            stream_wait.as_mut().unwrap().mark_timed_out();
                            return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                                CLEAR_HISTORY_STREAM_TIMEOUT_ERROR
                            )));
                        };
                        observed_progress = progress;
                    }
                    ParserClearHistoryResult::EncodedFallback(encoded) => {
                        let mut writer = self.writer.lock().unwrap();
                        let master = self.master.lock().unwrap();
                        return write_clear_history_fallback(
                            master.as_ref(),
                            writer.as_mut(),
                            &encoded,
                        )
                        .map(|()| ClearHistoryAckDisposition::Pending);
                    }
                }
            }
        }

        fn apply_parser_clear_history(
            &self,
            fallback_key: Option<&KeyInput>,
        ) -> anyhow::Result<ParserClearHistoryResult> {
            let mut term = self.term.lock().unwrap();
            Ok(match apply_clear_history_transition(&mut term, fallback_key)? {
                ClearHistoryTransition::Cleared(clear) => {
                    // Legacy mirrors consume this replay directly. The
                    // command submitter publishes the smart resync marker
                    // while it still owns source order.
                    self.broadcast(MessageKind::Output, clear.clone());
                    ParserClearHistoryResult::Cleared(clear)
                }
                ClearHistoryTransition::Blocked => ParserClearHistoryResult::Blocked,
                ClearHistoryTransition::EncodedFallback(encoded) => {
                    ParserClearHistoryResult::EncodedFallback(encoded)
                }
                ClearHistoryTransition::Noop => ParserClearHistoryResult::Noop,
            })
        }

        fn remove_client(&self, client: u64) {
            self.taps.lock().unwrap().remove(&client);
            self.smart.remove(client);
            let _ = mutate_viewer_sizes(
                &self.viewer_sizes,
                |viewer_sizes| {
                    viewer_sizes.remove(&client);
                },
                |desired| self.apply_viewer_minimum(desired, false, None).map(|_| ()),
            );
        }

        fn fence_client_detach(&self, client: u64, request_id: u64, target: &HostTap) -> bool {
            let mut response = Frame::new(MessageKind::DetachAck, Vec::new());
            response.request_id = request_id;
            let _source_order = self.source_order_lock.lock().unwrap();
            self.taps.lock().unwrap().remove(&client);
            self.smart.remove(client);
            target.try_send(response)
        }

        fn set_viewer_size(
            &self,
            client: u64,
            cols: u16,
            rows: u16,
            acknowledge_with_replay: bool,
            targeted_ack: Option<(u64, &HostTap)>,
        ) -> anyhow::Result<bool> {
            let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
            let mut acknowledgement_queued = true;
            mutate_viewer_sizes(
                &self.viewer_sizes,
                |viewer_sizes| {
                    viewer_sizes.insert(client, (cols, rows));
                },
                |desired| {
                    acknowledgement_queued =
                        self.apply_viewer_minimum(desired, acknowledge_with_replay, targeted_ack)?;
                    Ok(())
                },
            )?;
            Ok(acknowledgement_queued)
        }

        fn remove_viewer_size(&self, client: u64) {
            let _ = mutate_viewer_sizes(
                &self.viewer_sizes,
                |viewer_sizes| {
                    viewer_sizes.remove(&client);
                },
                |desired| self.apply_viewer_minimum(desired, false, None).map(|_| ()),
            );
        }

        fn set_cell_pixel_size(
            &self,
            width_px: u16,
            height_px: u16,
            request_id: u64,
            target: &HostTap,
        ) -> anyhow::Result<bool> {
            let _source_order = self.source_order_lock.lock().unwrap();
            let next = (width_px.max(1), height_px.max(1));
            let size = self.size.lock().unwrap();
            let mut cell_pixels = self.cell_pixels.lock().unwrap();
            let previous = *cell_pixels;
            let changed = previous != next;
            let resize_sizes = if changed {
                Some((pty_size(size.0, size.1, previous)?, pty_size(size.0, size.1, next)?))
            } else {
                None
            };
            let mut term = self.term.lock().unwrap();
            let mut source_cursor = None;
            if let Some((previous_size, next_size)) = resize_sizes {
                term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES).context(
                    "could not preflight terminal-host cell-metric replay; geometry unchanged",
                )?;
                let mut payload = Vec::with_capacity(8);
                payload.extend_from_slice(&size.0.to_le_bytes());
                payload.extend_from_slice(&size.1.to_le_bytes());
                payload.extend_from_slice(&next.0.to_le_bytes());
                payload.extend_from_slice(&next.1.to_le_bytes());
                source_cursor = Some(self.smart.publish(Frame::new(MessageKind::Resized, payload)));
                let master = self.master.lock().unwrap();
                if let Err(error) = master.resize(next_size) {
                    self.smart.close_failed_transition(source_cursor);
                    return Err(error);
                }
                if let Err(error) =
                    term.resize(size.0, size.1, u32::from(next.0), u32::from(next.1))
                {
                    let rollback = master.resize(previous_size);
                    self.smart.close_failed_transition(source_cursor);
                    return match rollback {
                        Ok(()) => Err(error.into()),
                        Err(rollback_error) => Err(anyhow::anyhow!(
                            "could not update authoritative cell metrics: {error}; \
                             PTY rollback also failed: {rollback_error}"
                        )),
                    };
                }
                *cell_pixels = next;
            }
            let transition = if changed {
                let replay = match term.vt_replay_bounded_theme_portable_with_aliases(
                    crate::surface::VT_REPLAY_MAX_BYTES,
                ) {
                    Ok(replay) => replay,
                    Err(_) => {
                        // Preflight ruled out persistent budget failure. Keep
                        // the canonical commit and force every client to take
                        // a fresh snapshot instead of broadcasting partial
                        // geometry state or destructively resizing backward.
                        let mut taps = self.taps.lock().unwrap();
                        for tap in taps.values() {
                            tap.close();
                        }
                        taps.clear();
                        self.smart.close_failed_transition(source_cursor);
                        target.close();
                        return Ok(false);
                    }
                };
                let mut resized = Frame::new(
                    MessageKind::Resized,
                    encode_resize(
                        size.0,
                        size.1,
                        &replay.bytes,
                        &replay.kitty_image_aliases,
                        next,
                        replay.kitty_state,
                    )?,
                );
                resized.flags = FLAG_COLORS_FOLLOW;
                Some([
                    resized,
                    Frame::new(
                        MessageKind::Colors,
                        encode_terminal_color_overrides(&term.color_overrides()),
                    ),
                ])
            } else {
                None
            };
            let mut ack = Frame::new(MessageKind::CellPixelSizeAck, {
                let mut payload = Vec::with_capacity(4);
                payload.extend_from_slice(&next.0.to_le_bytes());
                payload.extend_from_slice(&next.1.to_le_bytes());
                payload
            });
            ack.request_id = request_id;
            // Keep the parser locked through canonical publication and the
            // targeted acknowledgement. Output parsed at the new metrics
            // cannot overtake the complete Resized+Colors transition.
            let acknowledgement_queued = publish_host_frames_and_targeted(
                &self.broadcast_lock,
                &self.sequence,
                &self.taps,
                transition.into_iter().flatten(),
                Some((target, ack)),
            );
            if let Some(source_cursor) = source_cursor {
                self.smart.mark_applied(source_cursor);
            }
            Ok(acknowledgement_queued)
        }

        fn set_kitty_graphics_limits(
            &self,
            limits: KittyGraphicsLimits,
            request_id: u64,
            target: &HostTap,
        ) -> anyhow::Result<bool> {
            let limits = limits
                .validate()
                .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
            let _source_order = self.source_order_lock.lock().unwrap();
            let size = *self.size.lock().unwrap();
            let cell_pixels = *self.cell_pixels.lock().unwrap();
            let mut term = self.term.lock().unwrap();
            term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                .context("could not preflight terminal-host Kitty limit replay")?;
            // Kitty quota changes can evict scene state and have no raw PTY
            // representation. Smart renderers must reopen from the committed
            // authoritative state instead of retaining their old scene.
            let source_cursor =
                self.smart.publish(Frame::new(MessageKind::ResyncRequired, Vec::new()));
            if let Err(error) = term.set_kitty_graphics_limits(limits) {
                self.smart.mark_applied(source_cursor);
                let mut taps = self.taps.lock().unwrap();
                for tap in taps.values() {
                    tap.close();
                }
                taps.clear();
                target.close();
                return Err(error.into());
            }
            let replay = match term
                .vt_replay_bounded_theme_portable_with_aliases(crate::surface::VT_REPLAY_MAX_BYTES)
            {
                Ok(replay) => replay,
                Err(error) => {
                    // The authoritative limit change may already have evicted
                    // state. Disconnect every mirror so none can continue from
                    // the pre-eviction scene.
                    self.smart.mark_applied(source_cursor);
                    let mut taps = self.taps.lock().unwrap();
                    for tap in taps.values() {
                        tap.close();
                    }
                    taps.clear();
                    target.close();
                    return Err(error.into());
                }
            };
            let resize_payload = match encode_resize(
                size.0,
                size.1,
                &replay.bytes,
                &replay.kitty_image_aliases,
                cell_pixels,
                replay.kitty_state,
            ) {
                Ok(payload) => payload,
                Err(error) => {
                    self.smart.mark_applied(source_cursor);
                    let mut taps = self.taps.lock().unwrap();
                    for tap in taps.values() {
                        tap.close();
                    }
                    taps.clear();
                    target.close();
                    return Err(error);
                }
            };
            let mut resized = Frame::new(MessageKind::Resized, resize_payload);
            resized.flags = FLAG_COLORS_FOLLOW;
            let mut ack_payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
            if let Err(error) = encode_kitty_graphics_limits(&mut ack_payload, limits) {
                self.smart.mark_applied(source_cursor);
                target.close();
                return Err(error);
            }
            let mut ack = Frame::new(MessageKind::KittyGraphicsLimitsAck, ack_payload);
            ack.request_id = request_id;
            // The parser stays locked until all mirrors receive one complete
            // replacement and the requester receives its acknowledgement.
            let acknowledgement_queued = publish_host_frames_and_targeted(
                &self.broadcast_lock,
                &self.sequence,
                &self.taps,
                [
                    resized,
                    Frame::new(
                        MessageKind::Colors,
                        encode_terminal_color_overrides(&term.color_overrides()),
                    ),
                ],
                Some((target, ack)),
            );
            self.smart.mark_applied(source_cursor);
            Ok(acknowledgement_queued)
        }

        fn apply_viewer_minimum(
            &self,
            desired: Option<(u16, u16)>,
            acknowledge_with_replay: bool,
            targeted_ack: Option<(u64, &HostTap)>,
        ) -> anyhow::Result<bool> {
            let Some((cols, rows)) = desired else { return Ok(true) };
            let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
            // Geometry transitions share one source order. Keep this ahead of
            // size and cell_pixels, matching the other geometry mutation
            // paths, so concurrent viewer and cell-metric updates cannot
            // acquire the locks in opposite orders.
            let _source_order = self.source_order_lock.lock().unwrap();
            let mut size = self.size.lock().unwrap();
            let cell_pixels = self.cell_pixels.lock().unwrap();
            let changed = *size != (cols, rows);
            if !changed && !acknowledge_with_replay {
                let targeted = targeted_ack.map(|(request_id, tap)| {
                    let mut frame =
                        Frame::new(MessageKind::ResizeAck, encode_resize_ack(cols, rows, false));
                    frame.request_id = request_id;
                    (tap, frame)
                });
                return Ok(publish_host_frames_and_targeted(
                    &self.broadcast_lock,
                    &self.sequence,
                    &self.taps,
                    std::iter::empty(),
                    targeted,
                ));
            }
            // Output and geometry share one source order. Publish a compact
            // smart-renderer marker before the authoritative parser applies
            // it, then wait for the FIFO parser worker before admitting a
            // later source byte. Legacy clients keep their replay-bearing
            // Resized transition on the parser side of the same barrier.
            let source_cursor = changed.then(|| {
                let mut payload = Vec::with_capacity(4);
                payload.extend_from_slice(&cols.to_le_bytes());
                payload.extend_from_slice(&rows.to_le_bytes());
                self.smart.publish(Frame::new(MessageKind::Resized, payload))
            });
            let (response_sender, response_receiver) = sync_channel(1);
            let command = ParserCommand::Resize {
                cols,
                rows,
                cell_pixels: *cell_pixels,
                source_cursor,
                acknowledge_with_replay,
                targeted_ack: targeted_ack.map(|(request_id, tap)| (request_id, tap.clone())),
                response: response_sender,
            };
            if self.parser_commands.send(command).is_err() {
                self.smart.close_failed_transition(source_cursor);
                anyhow::bail!("terminal parser worker stopped");
            }
            let result = match response_receiver.recv() {
                Ok(result) => result,
                Err(_) => {
                    self.smart.close_failed_transition(source_cursor);
                    anyhow::bail!("terminal parser worker stopped");
                }
            };
            *size = result.applied;
            match result.acknowledgement_queued {
                Ok(acknowledgement_queued) => {
                    debug_assert_eq!(result.changed, changed);
                    Ok(acknowledgement_queued)
                }
                Err(error) => {
                    self.smart.close_failed_transition(source_cursor);
                    anyhow::bail!(error)
                }
            }
        }

        fn apply_parser_resize(
            &self,
            cols: u16,
            rows: u16,
            source_cursor: Option<u64>,
            acknowledge_with_replay: bool,
            targeted_ack: Option<(u64, HostTap)>,
            cell_pixels: (u16, u16),
        ) -> ParserResizeResult {
            let mut term = self.term.lock().unwrap();
            let previous = (term.cols(), term.rows());
            let acknowledgement_queued = (|| -> anyhow::Result<bool> {
                let requested_change = previous != (cols, rows);
                let master = self.master.lock().unwrap();
                let resize_sizes = if requested_change {
                    Some((
                        pty_size(previous.0, previous.1, cell_pixels)?,
                        pty_size(cols, rows, cell_pixels)?,
                    ))
                } else {
                    None
                };
                let targeted = targeted_ack.as_ref().map(|(request_id, tap)| {
                    let mut frame = Frame::new(
                        MessageKind::ResizeAck,
                        encode_resize_ack(cols, rows, requested_change),
                    );
                    frame.request_id = *request_id;
                    (tap, frame)
                });
                let has_legacy_clients = !self.taps.lock().unwrap().is_empty();
                let publish_legacy_resize =
                    acknowledge_with_replay || (requested_change && has_legacy_clients);
                let replay_is_safe = term.vt_stream_is_ground();
                if let Some((previous_size, next_size)) = resize_sizes {
                    if publish_legacy_resize && replay_is_safe {
                        term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                            .context(
                                "could not preflight terminal-host resize replay; geometry unchanged",
                            )?;
                    }
                    master.resize(next_size)?;
                    if let Err(error) =
                        term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))
                    {
                        let _ = master.resize(previous_size);
                        return Err(error.into());
                    }
                }
                let acknowledgement_queued = if publish_legacy_resize && !replay_is_safe {
                    // A replay cannot serialize an in-progress decoder or escape
                    // sequence. Force compatibility clients to take a new safe
                    // snapshot instead of orphaning the sequence's later bytes.
                    publish_host_frames_and_targeted(
                        &self.broadcast_lock,
                        &self.sequence,
                        &self.taps,
                        [Frame::new(MessageKind::ResyncRequired, Vec::new())],
                        targeted,
                    )
                } else if publish_legacy_resize {
                    let replay = match term.vt_replay_bounded_theme_portable_with_aliases(
                        crate::surface::VT_REPLAY_MAX_BYTES,
                    ) {
                        Ok(replay) => Some(replay),
                        Err(_) if requested_change => {
                            // Preflight ruled out persistent budget failure. Keep
                            // the canonical resize and make compatibility clients
                            // reconnect instead of attempting a destructive
                            // inverse resize after Ghostty has reflowed state.
                            let mut taps = self.taps.lock().unwrap();
                            for tap in taps.values() {
                                tap.close();
                            }
                            taps.clear();
                            None
                        }
                        Err(error) => return Err(error.into()),
                    };
                    if let Some(replay) = replay {
                        let colors = term.color_overrides();
                        #[cfg(test)]
                        if self.fail_next_resize_publication.swap(false, Ordering::AcqRel) {
                            anyhow::bail!("injected terminal resize publication failure");
                        }
                        let mut resized = Frame::new(
                            MessageKind::Resized,
                            encode_resize(
                                cols,
                                rows,
                                &replay.bytes,
                                &replay.kitty_image_aliases,
                                cell_pixels,
                                replay.kitty_state,
                            )?,
                        );
                        resized.flags = FLAG_COLORS_FOLLOW;
                        publish_host_frames_and_targeted(
                            &self.broadcast_lock,
                            &self.sequence,
                            &self.taps,
                            [
                                resized,
                                Frame::new(
                                    MessageKind::Colors,
                                    encode_terminal_color_overrides(&colors),
                                ),
                            ],
                            targeted,
                        )
                    } else {
                        publish_host_frames_and_targeted(
                            &self.broadcast_lock,
                            &self.sequence,
                            &self.taps,
                            std::iter::empty(),
                            targeted,
                        )
                    }
                } else {
                    publish_host_frames_and_targeted(
                        &self.broadcast_lock,
                        &self.sequence,
                        &self.taps,
                        std::iter::empty(),
                        targeted,
                    )
                };
                if let Some(cursor) = source_cursor {
                    // Snapshot registration takes `term` before subscribing to
                    // smart publication, so advancing while `term` remains held
                    // makes snapshot state and the applied cursor indivisible.
                    self.smart.mark_applied(cursor);
                }
                Ok(acknowledgement_queued)
            })();
            let applied = (term.cols(), term.rows());
            ParserResizeResult {
                acknowledgement_queued: acknowledgement_queued.map_err(|error| error.to_string()),
                changed: applied != previous,
                applied,
            }
        }

        fn child_exited(&self) -> bool {
            self.child_exit.0.lock().unwrap().is_some()
        }

        fn wait_for_child_exit(&self, timeout: Duration) -> bool {
            let exited = self.child_exit.0.lock().unwrap();
            if exited.is_some() {
                return true;
            }
            let (exited, _) = self
                .child_exit
                .1
                .wait_timeout_while(exited, timeout, |value| value.is_none())
                .unwrap();
            exited.is_some()
        }

        fn wait_for_child_waitable(&self, timeout: Duration) -> bool {
            if self.child_waitable.load(Ordering::Acquire) {
                return true;
            }
            let state = self.child_exit.0.lock().unwrap();
            let (_state, _) = self
                .child_exit
                .1
                .wait_timeout_while(state, timeout, |_| {
                    !self.child_waitable.load(Ordering::Acquire)
                })
                .unwrap();
            self.child_waitable.load(Ordering::Acquire)
        }

        fn wait_for_pty_drain(&self, timeout: Duration) -> bool {
            if self.pty_drained.load(Ordering::Acquire) {
                return true;
            }
            // The child-exit mutex is only a rendezvous guard here; the PTY
            // reader notifies the same condition variable after publishing
            // its final bytes and setting pty_drained.
            let state = self.child_exit.0.lock().unwrap();
            let (_state, _) = self
                .child_exit
                .1
                .wait_timeout_while(state, timeout, |_| !self.pty_drained.load(Ordering::Acquire))
                .unwrap();
            self.pty_drained.load(Ordering::Acquire)
        }

        fn publish_child_wait_predicate(&self, predicate: &AtomicBool) {
            // Every predicate consumed by child_exit.wait_* must change while
            // holding this mutex. Otherwise a notifier can run after a waiter
            // checks the atomic but before Condvar::wait arms, losing the only
            // wake that allows the terminal exit to be published.
            let _state = self.child_exit.0.lock().unwrap();
            predicate.store(true, Ordering::Release);
            self.child_exit.1.notify_all();
        }

        fn mark_child_waitable(&self) {
            self.publish_child_wait_predicate(&self.child_waitable);
        }

        fn mark_pty_drained(&self) {
            self.publish_child_wait_predicate(&self.pty_drained);
        }

        fn signal_terminal_process_groups(&self, signal: libc::c_int) {
            let mut groups = Vec::with_capacity(2);
            // The wait thread observes exit with WNOWAIT, then takes this lock
            // before reaping. While we hold it, `!child_reaped` means the
            // original PID/PGID is still kernel-reserved and cannot have been
            // reused between validation and killpg.
            let _signal = self.child_signal_lock.lock().unwrap();
            let child_reserved = !self.child_reaped.load(Ordering::Acquire);
            if child_reserved
                && let Some(pid) = self.pid.and_then(|pid| libc::pid_t::try_from(pid).ok())
            {
                groups.push(pid);
            }
            // Query the PTY each time rather than trusting the original group:
            // a foreground job or retained descendant may own a different
            // group by the time explicit Terminate escalates.
            if child_reserved
                && let Some(foreground) = self.master.lock().unwrap().process_group_leader()
            {
                groups.push(foreground);
            }
            groups.sort_unstable();
            groups.dedup();
            // A portable-pty child starts as a new session/process-group
            // leader. Signal both that durable group and any foreground job
            // group, but never risk addressing the terminal-host's own group.
            // SAFETY: getpgrp has no preconditions.
            let host_group = unsafe { libc::getpgrp() };
            for group in groups.into_iter().filter(|group| *group > 0 && *group != host_group) {
                // SAFETY: validated positive process-group ids owned by this
                // PTY session; signal is a platform constant from this module.
                let _ = unsafe { libc::killpg(group, signal) };
            }
        }

        fn request_forced_pty_drain(&self) {
            self.force_pty_drain.store(true, Ordering::Release);
            // Wake the otherwise blocking poll in the sole PTY reader. The
            // byte has no protocol meaning; it only makes the wake fd ready.
            let _ = self.pty_drain_waker.lock().unwrap().write_all(&[1]);
        }

        fn request_termination(self: &Arc<Self>) {
            let already_started = {
                // Serialize the ownership transition with WNOWAIT's final
                // reap decision so an explicit Terminate cannot lose the
                // original reserved PID/PGID in between.
                let _signal = self.child_signal_lock.lock().unwrap();
                self.termination_started.swap(true, Ordering::AcqRel)
            };
            if already_started {
                return;
            }
            let worker = self.clone();
            if thread::Builder::new()
                .name("terminal-host-terminate".into())
                .spawn(move || worker.terminate_and_wait())
                .is_err()
            {
                // Bounded fallback: even thread exhaustion cannot turn an
                // accepted Terminate into an unbounded or ignored request.
                self.terminate_and_wait();
            }
        }

        fn finish_group_escalation(&self) {
            self.publish_child_wait_predicate(&self.group_escalation_complete);
        }

        fn publish_exit_if_drained(&self) {
            // Persistence can block or retry under filesystem pressure. A
            // dedicated host-owned worker keeps snapshots, client input, and
            // the listener accept loop independent of that durable write.
            let _ = self.exit_publish_requests.send(());
        }

        fn start_exit_publisher(host: &Arc<Self>, requests: Receiver<()>) -> std::io::Result<()> {
            let host = Arc::downgrade(host);
            thread::Builder::new()
                .name("terminal-host-exit".into())
                .spawn(move || Self::run_exit_publisher(host, requests))
                .map(|_| ())
        }

        fn run_exit_publisher(weak_host: Weak<Self>, requests: Receiver<()>) {
            while requests.recv().is_ok() {
                let mut attempt = 0_u64;
                let mut retry_delay = HOST_EXIT_PERSIST_RETRY_MIN;
                let mut next_report = Instant::now();
                loop {
                    let Some(host) = weak_host.upgrade() else {
                        return;
                    };
                    let result = host.persist_and_publish_exit_if_drained();
                    drop(host);
                    match result {
                        Ok(()) => {
                            if let Some(host) = weak_host.upgrade() {
                                clear_exit_persistence_diagnostic(&host.exit_record_path);
                            }
                            break;
                        }
                        Err(error) => {
                            // The host stays live and sends no Exit until the
                            // durable sidecar succeeds. Reconnecting muxes can
                            // still inspect the retained snapshot, and a disk
                            // failure cannot erase the authoritative status.
                            attempt = attempt.saturating_add(1);
                            let now = Instant::now();
                            if now >= next_report {
                                if let Some(host) = weak_host.upgrade() {
                                    let _ = write_exit_persistence_diagnostic(
                                        &host.exit_record_path,
                                        attempt,
                                        &error,
                                    );
                                }
                                next_report = now + HOST_EXIT_PERSIST_REPORT_INTERVAL;
                            }
                            thread::sleep(retry_delay);
                            while requests.try_recv().is_ok() {}
                            retry_delay = next_exit_persistence_retry_delay(retry_delay);
                        }
                    }
                }
            }
        }

        fn persist_and_publish_exit_if_drained(&self) -> anyhow::Result<()> {
            // A command may exit before its launching daemon reaches the host
            // socket. Keep the final parser snapshot and canonical Exit
            // available until that first authenticated owner stream has been
            // inserted into the broadcast set.
            if !self.launch_owner_stream_ready.load(Ordering::Acquire) {
                return Ok(());
            }
            let exit = persist_and_claim_host_exit_after_drain(
                &self.child_exit.0,
                &self.pty_drained,
                &self.exit_published,
                |exit| {
                    write_exit_record(
                        &self.exit_record_path,
                        &TerminalHostExitRecord::new(
                            &TerminalHostIdentity {
                                terminal_id: self.terminal_id.to_hex(),
                                incarnation: self.incarnation.to_hex(),
                            },
                            exit.clone(),
                        ),
                    )
                },
            )?;
            if let Some(exit) = exit {
                let _source_order = self.source_order_lock.lock().unwrap();
                // Snapshot capture keeps `term` held from the dead check
                // through smart subscription. Publish Exit under that same
                // lock so an attach either joins before Exit or observes dead.
                {
                    let _term = self.term.lock().unwrap();
                    self.dead.store(true, Ordering::Release);
                    let payload = encode_terminal_exit(&exit);
                    let cursor = self.smart.publish(Frame::new(MessageKind::Exit, payload.clone()));
                    self.smart.mark_applied(cursor);
                    self.broadcast(MessageKind::Exit, payload);
                }
                self.note_parser_progress();
            }
            Ok(())
        }

        fn terminate_and_wait(&self) {
            {
                let _signal = self.child_signal_lock.lock().unwrap();
                self.termination_started.store(true, Ordering::Release);
            }
            // ProcessSignaller only targets the direct child. Start with a
            // graceful group hangup so foreground jobs and normal descendants
            // can clean up too, then escalate after a strict bound.
            self.signal_terminal_process_groups(libc::SIGHUP);
            if !self.child_waitable.load(Ordering::Acquire) {
                let _ = self.killer.lock().unwrap().kill();
            }
            let _ = self.wait_for_child_waitable(HOST_TERMINATE_GRACE);
            let _ = self.wait_for_pty_drain(HOST_PTY_DRAIN_GRACE);

            // The direct child may ignore SIGHUP, or it may already have
            // exited while a descendant retains the PTY. Kill both the
            // original session group and its current foreground job group.
            // This escalation is mandatory even if Darwin reports PTY EOF as
            // soon as the session leader exits: an HUP-ignoring descendant
            // can still be alive in the now-invisible original group.
            self.signal_terminal_process_groups(libc::SIGKILL);
            self.finish_group_escalation();
            let child_exited = self.wait_for_child_exit(HOST_KILL_WAIT);
            if child_exited && self.wait_for_pty_drain(HOST_PTY_DRAIN_GRACE) {
                return;
            }

            if child_exited {
                // A process that escaped the PTY session can retain a slave
                // descriptor forever. Do not let an explicit tombstone hang
                // the durable host: wake the reader, drain bytes already
                // readable for a short bounded window, then publish Exit.
                self.request_forced_pty_drain();
                let _ = self.wait_for_pty_drain(HOST_FORCED_DRAIN_WINDOW * 2);
            }
        }
    }

    fn persist_and_claim_host_exit_after_drain(
        child_exited: &Mutex<Option<TerminalExit>>,
        pty_drained: &AtomicBool,
        exit_published: &AtomicBool,
        persist: impl FnOnce(&TerminalExit) -> anyhow::Result<()>,
    ) -> anyhow::Result<Option<TerminalExit>> {
        if !pty_drained.load(Ordering::Acquire) {
            return Ok(None);
        }
        let Some(exit) = child_exited.lock().unwrap().clone() else {
            return Ok(None);
        };
        if exit_published.load(Ordering::Acquire) {
            return Ok(None);
        }
        persist(&exit)?;
        Ok(exit_published
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
            .then_some(exit))
    }

    /// Keep viewer mutation, minimum reduction, and the resulting PTY resize
    /// in one critical section. If the guard were released after reduction,
    /// an older large resize could run after a newer small resize and leave
    /// the host at a size that no longer matches its viewer set.
    fn mutate_viewer_sizes(
        viewer_sizes: &Mutex<HashMap<u64, (u16, u16)>>,
        mutation: impl FnOnce(&mut HashMap<u64, (u16, u16)>),
        apply: impl FnOnce(Option<(u16, u16)>) -> anyhow::Result<()>,
    ) -> anyhow::Result<()> {
        let mut viewer_sizes = viewer_sizes.lock().unwrap();
        let previous = viewer_sizes.clone();
        mutation(&mut viewer_sizes);
        let desired = viewer_sizes
            .values()
            .copied()
            .reduce(|left, right| (left.0.min(right.0), left.1.min(right.1)));
        if let Err(error) = apply(desired) {
            *viewer_sizes = previous;
            return Err(error);
        }
        Ok(())
    }

    fn wait_for_child_exit_without_reaping(pid: libc::pid_t) -> std::io::Result<()> {
        loop {
            let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::uninit();
            // SAFETY: status points to writable siginfo storage. WNOWAIT
            // observes this owned child becoming waitable without releasing
            // its PID/PGID for reuse; the portable Child handle reaps it after
            // acquiring child_signal_lock.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    status.as_mut_ptr(),
                    libc::WEXITED | libc::WNOWAIT,
                )
            };
            if result == 0 {
                return Ok(());
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }

    struct HostLivenessLease {
        file: File,
        path: PathBuf,
    }

    impl HostLivenessLease {
        fn acquire(path: PathBuf) -> anyhow::Result<Self> {
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
                .open(&path)?;
            // SAFETY: flock only changes the advisory lock on this newly
            // created, valid file descriptor.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                let error = std::io::Error::last_os_error();
                let _ = fs::remove_file(&path);
                return Err(error.into());
            }
            file.sync_all()?;
            Ok(Self { file, path })
        }
    }

    impl Drop for HostLivenessLease {
        fn drop(&mut self) {
            // Closing the owner's descriptor does not release flock while a
            // concurrently forked child still holds an inherited duplicate.
            // The lease lifetime belongs to this owner, so end it explicitly
            // before closing the descriptor.
            // SAFETY: flock only changes the advisory lock associated with
            // this valid, owned file descriptor.
            let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
        }
    }

    pub(crate) struct TerminalHostResetLock {
        file: File,
    }

    pub(crate) struct TerminalHostPublicationLock {
        file: File,
    }

    pub(crate) fn prepare_terminal_host_publication_lock(root: &Path) -> anyhow::Result<()> {
        prepare_private_dir(root)?;
        let path = terminal_host_publication_lock_path(root);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
            .with_context(|| format!("create terminal-host publication lock {}", path.display()))?;
        validate_terminal_host_publication_lock(root, &path, &file)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.sync_all()?;
        File::open(root)?.sync_all()?;
        Ok(())
    }

    pub(crate) fn reserve_terminal_host_publication(
        root: &Path,
    ) -> anyhow::Result<TerminalHostPublicationLock> {
        prepare_terminal_host_publication_lock(root)?;
        acquire_terminal_host_publication_lock(root)
    }

    pub(crate) fn acquire_terminal_host_reset_lock(
        root: &Path,
    ) -> anyhow::Result<Option<TerminalHostResetLock>> {
        prepare_terminal_host_publication_lock(root)?;
        let path = terminal_host_publication_lock_path(root);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
            .with_context(|| format!("open terminal-host publication lock {}", path.display()))?;
        validate_terminal_host_publication_lock(root, &path, &file)?;
        lock_terminal_host_publication_file(&file, libc::LOCK_EX | libc::LOCK_NB).with_context(
            || format!("terminal host state has live or unverified hosts: {}", root.display()),
        )?;
        validate_terminal_host_publication_lock(root, &path, &file)?;
        Ok(Some(TerminalHostResetLock { file }))
    }

    pub(crate) fn acquire_terminal_host_publication_lock(
        root: &Path,
    ) -> anyhow::Result<TerminalHostPublicationLock> {
        let path = terminal_host_publication_lock_path(root);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
            .with_context(|| format!("open terminal-host publication lock {}", path.display()))?;
        validate_terminal_host_publication_lock(root, &path, &file)?;
        lock_terminal_host_publication_file(&file, libc::LOCK_SH)
            .with_context(|| format!("lock terminal-host publication lock {}", path.display()))?;
        validate_terminal_host_publication_lock(root, &path, &file)?;
        Ok(TerminalHostPublicationLock { file })
    }

    fn terminal_host_publication_lock_path(root: &Path) -> PathBuf {
        root.join(TERMINAL_HOST_PUBLICATION_LOCK_FILE)
    }

    fn validate_terminal_host_publication_lock(
        root: &Path,
        path: &Path,
        file: &File,
    ) -> anyhow::Result<()> {
        let root_metadata = fs::metadata(root)
            .with_context(|| format!("inspect terminal-host root {}", root.display()))?;
        let path_metadata = fs::symlink_metadata(path).with_context(|| {
            format!("inspect terminal-host publication lock {}", path.display())
        })?;
        if !path_metadata.file_type().is_file()
            || path_metadata.uid() != root_metadata.uid()
            || path_metadata.mode() & 0o077 != 0
            || path_metadata.nlink() != 1
        {
            anyhow::bail!("terminal-host publication lock is unsafe: {}", path.display());
        }
        let file_metadata = file.metadata()?;
        if path_metadata.dev() != file_metadata.dev() || path_metadata.ino() != file_metadata.ino()
        {
            anyhow::bail!(
                "terminal-host publication lock changed while opening: {}",
                path.display()
            );
        }
        Ok(())
    }

    fn lock_terminal_host_publication_file(
        file: &File,
        operation: libc::c_int,
    ) -> anyhow::Result<()> {
        loop {
            // SAFETY: flock only observes or changes the advisory lock on this
            // valid descriptor.
            if unsafe { libc::flock(file.as_raw_fd(), operation) } == 0 {
                return Ok(());
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error.into());
        }
    }

    impl Drop for TerminalHostResetLock {
        fn drop(&mut self) {
            // SAFETY: flock only changes the advisory lock on this valid descriptor.
            let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
        }
    }

    impl Drop for TerminalHostPublicationLock {
        fn drop(&mut self) {
            // SAFETY: flock only changes the advisory lock on this valid descriptor.
            let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
        }
    }

    struct HostServiceGuard {
        shared: Arc<HostShared>,
        endpoint: PathBuf,
        record_path: PathBuf,
        record: TerminalHostRecord,
        lease: Option<HostLivenessLease>,
        published: bool,
    }

    struct UnpublishedHostGuard {
        shared: Arc<HostShared>,
        endpoint: PathBuf,
        armed: bool,
    }

    impl Drop for UnpublishedHostGuard {
        fn drop(&mut self) {
            if self.armed {
                self.shared.terminate_and_wait();
                let _ = fs::remove_file(&self.endpoint);
            }
        }
    }

    impl Drop for HostServiceGuard {
        fn drop(&mut self) {
            // All normal and early-error paths confirm the PTY child exited
            // before removing its discoverability record. If this host is
            // SIGKILLed, Drop cannot run; the locked nonce file remains on
            // disk but unlocks automatically, giving the next mux positive
            // stale-record proof.
            self.shared.terminate_and_wait();
            if !self.shared.child_exited() {
                return;
            }
            let owns_record = !self.published
                || fs::read(&self.record_path)
                    .ok()
                    .and_then(|bytes| serde_json::from_slice::<TerminalHostRecord>(&bytes).ok())
                    .is_some_and(|current| {
                        current.terminal_id == self.record.terminal_id
                            && current.incarnation == self.record.incarnation
                            && current.host_start_nonce == self.record.host_start_nonce
                    });
            let released_lease_path = if owns_record {
                self.lease.take().map(|lease| {
                    let _ = lease.file.sync_all();
                    let path = lease.path.clone();
                    // Unlock the process-incarnation proof before removing its
                    // discovery record. Observers can never see an absent
                    // record whose captured liveness proof still says Live.
                    drop(lease);
                    path
                })
            } else {
                None
            };
            let removed_record =
                !self.published || (owns_record && fs::remove_file(&self.record_path).is_ok());
            let _ = fs::remove_file(&self.endpoint);
            if removed_record && let Some(path) = released_lease_path {
                let _ = fs::remove_file(path);
            }
        }
    }

    pub fn serve_terminal_host_stdio(
        args: &[String],
        reader: &mut impl Read,
        writer: &mut impl Write,
    ) -> anyhow::Result<()> {
        if args.iter().map(String::as_str).ne(["--bootstrap-stdio"]) {
            anyhow::bail!("hidden mode requires --bootstrap-stdio");
        }
        let bootstrapped = crate::terminal_host::bootstrap_stdio_once(reader, writer)?;
        let Some(launch_frame) = read_frame(reader, MAX_LAUNCH_PAYLOAD)? else {
            // Keep the one-frame bootstrap probe useful for compatibility and
            // packaging diagnostics. Production launchers always follow it
            // with Launch on the same private pipe.
            return Ok(());
        };
        if launch_frame.kind != MessageKind::Launch {
            anyhow::bail!("expected terminal-host Launch, received {:?}", launch_frame.kind);
        }
        let launch = HostLaunch::decode(&launch_frame.payload)?;
        let shared = match spawn_host_runtime(&launch, &bootstrapped) {
            Ok(shared) => shared,
            Err(error) => {
                let failure = host_launch_failure(&error);
                let mut response =
                    Frame::new(MessageKind::LaunchFailed, encode_host_launch_failure(&failure)?);
                response.request_id = launch_frame.request_id;
                write_frame(writer, &response)?;
                return Ok(());
            }
        };

        let endpoint = PathBuf::from(&launch.endpoint);
        let mut unpublished = UnpublishedHostGuard {
            shared: shared.clone(),
            endpoint: endpoint.clone(),
            armed: true,
        };
        let _ = fs::remove_file(&endpoint);
        if let Some(parent) = endpoint.parent() {
            prepare_private_dir(parent)?;
        }
        let listener = UnixListener::bind(&endpoint)?;
        fs::set_permissions(&endpoint, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;

        let start_nonce = CapabilityToken::random()?;
        let record = TerminalHostRecord {
            record_version: HOST_RECORD_VERSION,
            terminal_id: bootstrapped.terminal_id.to_hex(),
            incarnation: bootstrapped.incarnation.to_hex(),
            endpoint: launch.endpoint.clone(),
            owner_token: encode_hex(bootstrapped.owner_token().as_bytes()),
            host_pid: std::process::id(),
            host_start_nonce: encode_hex(start_nonce.as_bytes()),
            workspace_key: String::new(),
            supports_set_defaults: true,
            supports_clear_history: true,
            supports_terminate_ack: true,
        };
        let record_root = Path::new(&launch.record_path)
            .parent()
            .ok_or_else(|| anyhow::anyhow!("terminal-host record has no parent directory"))?;
        let _publication_lock = acquire_terminal_host_publication_lock(record_root)?;
        let lease =
            HostLivenessLease::acquire(liveness_path(Path::new(&launch.record_path), &record))?;
        let mut guard = HostServiceGuard {
            shared: shared.clone(),
            endpoint,
            record_path: PathBuf::from(&launch.record_path),
            record: record.clone(),
            lease: Some(lease),
            published: false,
        };
        unpublished.armed = false;

        // The PTY owner publishes its own adoption record before Ready. A
        // daemon killed immediately after launch acknowledgement can never
        // leave behind an undiscoverable terminal process.
        write_record(Path::new(&launch.record_path), &record)?;
        guard.published = true;

        // Integration failure-injection seam for the narrow record-before-
        // Ready crash window. It is inherited only by explicitly configured
        // test daemons and bounded so an accidental environment setting
        // cannot wedge a production host indefinitely.
        if let Ok(delay) = std::env::var("CMUX_TUI_TEST_HOST_READY_DELAY_MS")
            && let Ok(delay) = delay.parse::<u64>()
            && delay > 0
        {
            thread::sleep(Duration::from_millis(delay.min(5_000)));
        }

        let ready = HostReady {
            selected_version: PROTOCOL_VERSION,
            terminal_id: bootstrapped.terminal_id,
            incarnation: bootstrapped.incarnation,
        };
        let mut response = Frame::new(MessageKind::Ready, ready.encode());
        response.request_id = launch_frame.request_id;
        // Publication is the ownership handoff. If the launcher dies in the
        // narrow record-before-Ready window, EPIPE must not tear down the
        // independently adoptable shell; a replacement daemon discovers the
        // record and connects through the already-listening Unix socket.
        let _ = write_frame(writer, &response);

        let launch_owner_deadline = Instant::now() + HOST_LAUNCH_OWNER_TIMEOUT;
        loop {
            let now = Instant::now();
            if !shared.launch_owner_claimed.load(Ordering::Acquire)
                && now >= launch_owner_deadline
                && shared
                    .launch_owner_claimed
                    .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
            {
                // A launcher that vanished before authenticating must not
                // retain an already-exited host forever. A live PTY remains
                // adoptable; only its eventual exit is now unblocked.
                shared.mark_launch_owner_stream_ready();
            }
            if shared.dead.load(Ordering::Acquire)
                && shared.active_client_streams.load(Ordering::Acquire) == 0
            {
                break;
            }
            match listener.accept() {
                Ok((stream, _)) => {
                    // Accepted sockets inherit O_NONBLOCK from the listener
                    // on macOS. Client protocol threads use blocking framed
                    // reads, so normalize the accepted descriptor here.
                    stream.set_nonblocking(false)?;
                    let host = shared.clone();
                    thread::Builder::new().name("terminal-host-client".into()).spawn(
                        move || {
                            let _ = serve_client(host, stream);
                        },
                    )?;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20));
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error.into()),
            }
        }
        thread::sleep(Duration::from_millis(20));
        drop(guard);
        Ok(())
    }

    fn host_launch_failure(error: &anyhow::Error) -> HostLaunchFailure {
        let kind = if error.chain().any(|cause| {
            cause.downcast_ref::<PtyOpenError>().is_some_and(PtyOpenError::is_capacity_exhausted)
        }) {
            HostLaunchFailureKind::PtyCapacityExhausted
        } else {
            HostLaunchFailureKind::LaunchFailed
        };
        HostLaunchFailure::bounded(kind, format!("terminal launch failed: {error:#}"))
    }

    fn spawn_host_runtime(
        launch: &HostLaunch,
        bootstrapped: &crate::terminal_host::BootstrappedHost,
    ) -> anyhow::Result<Arc<HostShared>> {
        let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
        let initial_pty_size = pty_size(launch.cols, launch.rows, cell_pixels)?;
        let pty = cmux_pty::open(initial_pty_size)?;
        let mut command = PtyCommand::new(&launch.command[0]);
        command.args(launch.command[1..].iter().cloned());
        command.env("TERM", &launch.term);
        // Terminal-host children get the same truecolor guarantee as directly
        // spawned surfaces (see Surface spawn in surface.rs); extra_env wins.
        command.env("COLORTERM", "truecolor");
        for (key, value) in &launch.extra_env {
            command.env(key, value);
        }
        if let Some(cwd) = launch.cwd.as_deref() {
            command.cwd(cwd);
        }
        let cmux_pty::SpawnedPty { master, mut child } = pty.spawn(command)?;
        let pid = child.process_id();
        let killer = child.clone_killer();
        let pty_poll_fd = master.as_raw_fd().context("open terminal-host PTY poll fd")?;
        let mut pty_reader = master.try_clone_reader()?;
        let pty_writer = master.take_writer()?;
        let (pty_drain_waker, pty_drain_waiter) = UnixStream::pair()?;

        let pending_responses = Arc::new(Mutex::new(Vec::<u8>::new()));
        let title_changed = Arc::new(AtomicBool::new(false));
        let bell = Arc::new(AtomicBool::new(false));
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let pending = pending_responses.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
            })),
            on_title_changed: Some(Box::new({
                let title_changed = title_changed.clone();
                move || title_changed.store(true, Ordering::Release)
            })),
            on_bell: Some(Box::new({
                let bell = bell.clone();
                move || bell.store(true, Ordering::Release)
            })),
        };
        let mut term = Terminal::new(launch.cols, launch.rows, launch.scrollback, callbacks)?;
        term.resize(launch.cols, launch.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        term.set_kitty_graphics_limits(launch.kitty_graphics_limits)?;
        term.replace_default_colors(
            launch.default_colors.fg,
            launch.default_colors.bg,
            launch.default_colors.cursor,
        );
        term.set_default_palette(&launch.default_colors.palette);
        replace_ghostty_cursor_defaults(&mut term, launch.default_colors);
        let initial_colors = term.color_overrides();
        let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
        let (parser_commands, parser_command_receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
        let shared = Arc::new(HostShared {
            terminal_id: bootstrapped.terminal_id,
            incarnation: bootstrapped.incarnation,
            owner_token: bootstrapped.owner_token(),
            capabilities: CapabilityStore::new(64),
            term: Mutex::new(term),
            default_colors: Mutex::new(launch.default_colors),
            stream_progress: TerminalStreamProgress::default(),
            writer: Mutex::new(pty_writer),
            master: Mutex::new(master),
            killer: Mutex::new(killer),
            pid,
            command: launch.command.clone(),
            cwd: launch.cwd.clone(),
            size: Mutex::new((launch.cols, launch.rows)),
            cell_pixels: Mutex::new(cell_pixels),
            viewer_sizes: Mutex::new(HashMap::new()),
            taps: Mutex::new(HashMap::new()),
            broadcast_lock: Mutex::new(()),
            sequence: AtomicU64::new(0),
            smart: SmartStreamState::new(),
            source_order_lock: Mutex::new(()),
            parser_commands,
            parser_budget: ParserBudget::new(MAX_HOST_PARSER_QUEUED_BYTES),
            parser_progress: (Mutex::new(0), Condvar::new()),
            next_client: AtomicU64::new(1),
            dead: AtomicBool::new(false),
            launch_owner_claimed: AtomicBool::new(false),
            launch_owner_stream_ready: AtomicBool::new(false),
            launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
            active_client_streams: AtomicUsize::new(0),
            child_exit: (Mutex::new(None), Condvar::new()),
            child_waitable: AtomicBool::new(false),
            pty_drained: AtomicBool::new(false),
            exit_published: AtomicBool::new(false),
            exit_record_path: Path::new(&launch.record_path).with_extension("exit"),
            exit_publish_requests,
            force_pty_drain: AtomicBool::new(false),
            pty_drain_waker: Mutex::new(pty_drain_waker),
            termination_started: AtomicBool::new(false),
            child_signal_lock: Mutex::new(()),
            child_reaped: AtomicBool::new(false),
            group_escalation_complete: AtomicBool::new(false),
            #[cfg(test)]
            fail_next_resize_publication: AtomicBool::new(false),
        });
        HostShared::start_exit_publisher(&shared, exit_publish_receiver)?;

        let parser_host = shared.clone();
        thread::Builder::new().name("terminal-host-parser".into()).spawn(move || {
            let mut last_colors = initial_colors;
            let mut last_pwd = None;
            while let Ok(command) = parser_command_receiver.recv() {
                match command {
                    ParserCommand::Output { bytes, source_cursor, accounted_bytes } => {
                        let title = {
                            let mut term = parser_host.term.lock().unwrap();
                            let cursor_activity = term
                                .cursor_activity()
                                .expect("valid host terminals expose cursor activity");
                            let normalized = term.vt_write_with_normalized(&bytes).into_owned();
                            let title = title_changed
                                .swap(false, Ordering::AcqRel)
                                .then(|| term.title().unwrap_or_default());
                            let pwd = term.pwd();
                            let colors = term.color_overrides();
                            let cursor_changed = term
                                .cursor_activity()
                                .expect("valid host terminals expose cursor activity")
                                != cursor_activity;
                            let colors = if colors != last_colors || cursor_changed {
                                let encoded = encode_terminal_color_overrides(&colors);
                                last_colors = colors;
                                Some(encoded)
                            } else {
                                None
                            };
                            let pwd = changed_pwd_frame(&mut last_pwd, pwd);
                            parser_host.broadcast_frames(output_transition_frames(
                                normalized, colors, pwd,
                            ));
                            // The parser lock is also the snapshot lock. Mark
                            // this source cursor before releasing it so a
                            // snapshot cannot include output that its boundary
                            // still describes as unapplied.
                            parser_host.smart.mark_applied(source_cursor);
                            title
                        };
                        parser_host.note_parser_progress();
                        parser_host.stream_progress.notify();
                        parser_host.parser_budget.release(accounted_bytes);
                        if let Some(title) = title {
                            parser_host.broadcast(MessageKind::Title, title.into_bytes());
                        }
                        if bell.swap(false, Ordering::AcqRel) {
                            parser_host.broadcast(MessageKind::Bell, Vec::new());
                        }
                        let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
                        if !responses.is_empty() {
                            let mut writer = parser_host.writer.lock().unwrap();
                            let _ = writer.write_all(&responses);
                            let _ = writer.flush();
                        }
                    }
                    ParserCommand::Resize {
                        cols,
                        rows,
                        cell_pixels,
                        source_cursor,
                        acknowledge_with_replay,
                        targeted_ack,
                        response,
                    } => {
                        let result = parser_host.apply_parser_resize(
                            cols,
                            rows,
                            source_cursor,
                            acknowledge_with_replay,
                            targeted_ack,
                            cell_pixels,
                        );
                        let _ = response.send(result);
                    }
                    ParserCommand::SetDefaults { colors, source_cursor, response } => {
                        let colors = *colors;
                        last_colors = parser_host.apply_parser_defaults(colors, source_cursor);
                        let _ = response.send(());
                    }
                    ParserCommand::ClearHistory { fallback_key, response } => {
                        let result = parser_host
                            .apply_parser_clear_history(fallback_key.as_ref())
                            .map_err(|error| error.to_string());
                        if matches!(result, Ok(ParserClearHistoryResult::Cleared(_))) {
                            parser_host.note_parser_progress();
                            parser_host.stream_progress.notify();
                        }
                        let _ = response.send(result);
                    }
                    ParserCommand::Drain => {
                        // FIFO reception proves every source byte published by
                        // the PTY reader has reached the authoritative parser.
                        parser_host.mark_pty_drained();
                        parser_host.publish_exit_if_drained();
                        break;
                    }
                }
            }
        })?;

        let reader_host = shared.clone();
        thread::Builder::new().name("terminal-host-pty".into()).spawn(move || {
            reader_host.wait_for_launch_owner_stream_ready();
            let mut buffer = [0u8; 64 * 1024];
            let mut forced_at = None;
            let mut pty_drain_waiter = pty_drain_waiter;
            while let Ok(true) = wait_for_pty_readable_or_forced_drain(
                pty_poll_fd,
                &mut pty_drain_waiter,
                &reader_host.force_pty_drain,
                &mut forced_at,
            ) {
                let count = match pty_reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => count,
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                        ) =>
                    {
                        continue;
                    }
                    Err(_) => break,
                };
                let bytes = buffer[..count].to_vec();
                let _source_order = reader_host.source_order_lock.lock().unwrap();
                reader_host.parser_budget.reserve(count);
                // Publication deliberately precedes parser enqueue. The
                // bounded queue limits memory while letting a fast renderer
                // consume source bytes independently of parser throughput.
                let source_cursor =
                    reader_host.smart.publish(Frame::new(MessageKind::Output, bytes.clone()));
                if !enqueue_parser_output(
                    &reader_host.parser_commands,
                    &reader_host.parser_budget,
                    &reader_host.smart,
                    bytes,
                    source_cursor,
                    count,
                ) {
                    break;
                }
            }
            // Drain is ordered after the final source byte. The parser worker,
            // rather than the reader, publishes the drained rendezvous.
            let _source_order = reader_host.source_order_lock.lock().unwrap();
            let _ = reader_host.parser_commands.send(ParserCommand::Drain);
        })?;
        let child_host = shared.clone();
        thread::Builder::new().name("terminal-host-child".into()).spawn(move || {
            let observed_without_reaping = child_host
                .pid
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .is_some_and(|pid| wait_for_child_exit_without_reaping(pid).is_ok());
            if observed_without_reaping {
                child_host.mark_child_waitable();
                loop {
                    let signal = child_host.child_signal_lock.lock().unwrap();
                    let escalation_complete =
                        child_host.group_escalation_complete.load(Ordering::Acquire);
                    let termination_started =
                        child_host.termination_started.load(Ordering::Acquire);
                    let pty_drained = child_host.pty_drained.load(Ordering::Acquire);
                    if escalation_complete || (!termination_started && pty_drained) {
                        let exit = wait_for_native_child_status(child.as_mut());
                        child_host.child_reaped.store(true, Ordering::Release);
                        drop(signal);
                        *child_host.child_exit.0.lock().unwrap() = Some(exit);
                        break;
                    }
                    drop(signal);
                    let state = child_host.child_exit.0.lock().unwrap();
                    let _state = child_host
                        .child_exit
                        .1
                        .wait_while(state, |_| {
                            !child_host.group_escalation_complete.load(Ordering::Acquire)
                                && (child_host.termination_started.load(Ordering::Acquire)
                                    || !child_host.pty_drained.load(Ordering::Acquire))
                        })
                        .unwrap();
                }
                child_host.child_exit.1.notify_all();
                child_host.publish_exit_if_drained();
            } else {
                // Native Unix PTYs always expose a PID and support waitid;
                // retain a conservative fallback for alternate backends.
                let exit = wait_for_native_child_status(child.as_mut());
                child_host.child_reaped.store(true, Ordering::Release);
                child_host.mark_child_waitable();
                let mut exited = child_host.child_exit.0.lock().unwrap();
                *exited = Some(exit);
                child_host.child_exit.1.notify_all();
                child_host.publish_exit_if_drained();
            }
        })?;
        Ok(shared)
    }

    fn send_snapshot_resync(host: &HostShared, stream: &mut UnixStream, smart_renderer: bool) {
        let mut resync = Frame::new(MessageKind::ResyncRequired, Vec::new());
        resync.sequence = if smart_renderer {
            host.smart.applied_cursor.load(Ordering::Acquire)
        } else {
            host.sequence.load(Ordering::Acquire)
        };
        let _ = write_frame(stream, &resync);
    }

    fn serve_client(host: Arc<HostShared>, stream: UnixStream) -> anyhow::Result<()> {
        serve_client_with_snapshot_timeout(host, stream, HOST_SNAPSHOT_BOUNDARY_TIMEOUT)
    }

    fn serve_client_with_snapshot_timeout(
        host: Arc<HostShared>,
        mut stream: UnixStream,
        snapshot_timeout: Duration,
    ) -> anyhow::Result<()> {
        // A client that stops reading must not retain an exited host forever.
        // Bound the actual stalled resource instead of imposing a wall-clock
        // deadline on healthy clients that are still draining sequenced bytes.
        stream.set_write_timeout(Some(HOST_CLIENT_WRITE_TIMEOUT))?;
        let hello_frame = read_required_frame(&mut stream, "client hello")?;
        if hello_frame.kind != MessageKind::ClientHello
            || hello_frame.sequence != 0
            || hello_frame.flags & !(FLAG_VIEWER_SIZE_ACKS | FLAG_SMART_RENDERER) != 0
        {
            anyhow::bail!("terminal-host client did not send ClientHello");
        }
        let hello = ClientHello::decode(&hello_frame.payload)?;
        let response = authenticate_client(&host, &hello)?;
        if hello_frame.version != response.selected_version
            || !response.granted_rights.contains(CapabilityRights::READ)
        {
            anyhow::bail!("terminal-host capability denied");
        }
        let selected_version = response.selected_version;
        let granted_rights = response.granted_rights;
        let launch_owner = LaunchOwnerConnection::claim(host.clone(), granted_rights);
        let launch_owner_claimed = launch_owner.claimed;
        let activation_required = launch_owner_claimed
            && selected_version >= LAUNCH_ACTIVATION_PROTOCOL_VERSION
            && !host.launch_owner_stream_ready.load(Ordering::Acquire);
        let viewer_size_acks = hello_frame.flags & FLAG_VIEWER_SIZE_ACKS != 0
            && granted_rights.contains(CapabilityRights::RESIZE);
        let smart_renderer = selected_version >= SMART_RENDERER_PROTOCOL_VERSION
            && hello_frame.flags & FLAG_SMART_RENDERER != 0
            && matches!(hello.role, ClientRole::Renderer | ClientRole::Admin);
        let mut hello_response = Frame::new(MessageKind::HostHello, response.encode());
        if viewer_size_acks {
            hello_response.flags |= FLAG_VIEWER_SIZE_ACKS;
        }
        if activation_required {
            hello_response.flags |= FLAG_LAUNCH_ACTIVATION_REQUIRED;
        }
        if smart_renderer {
            hello_response.flags |= FLAG_SMART_RENDERER;
        }
        hello_response.request_id = hello_frame.request_id;
        write_frame(&mut stream, &hello_response)?;

        let client = host.next_client.fetch_add(1, Ordering::Relaxed);
        // Queue admission is bounded by HostTap's byte counters. A fixed
        // channel capacity would make harmless PTY fragmentation observable
        // as a renderer disconnect.
        let (sender, receiver) = mpsc_channel();
        let tap = HostTap::new(sender, Arc::new(stream.try_clone()?), MAX_HOST_CLIENT_QUEUED_BYTES);
        let command_sender = tap.clone();
        let (snapshot, colors, snapshot_sequence, replay_gap, _active_client_stream) = {
            // Wait for a parser boundary without blocking resize or cell-metric
            // writers. Try-locking geometry while the safe parser guard is held
            // gives the snapshot one atomic state without reversing the normal
            // blocking lock order.
            let snapshot_deadline = Instant::now() + snapshot_timeout;
            let (mut viewer_sizes, size, cell_pixels, mut term) = loop {
                let remaining = snapshot_deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    send_snapshot_resync(&host, &mut stream, smart_renderer);
                    anyhow::bail!("terminal snapshot geometry did not stabilize before timeout");
                }
                let term = match host.terminal_at_snapshot_boundary(remaining) {
                    Ok(term) => term,
                    Err(error) => {
                        send_snapshot_resync(&host, &mut stream, smart_renderer);
                        return Err(error);
                    }
                };
                let viewer_sizes = match host.viewer_sizes.try_lock() {
                    Ok(guard) => guard,
                    Err(TryLockError::WouldBlock) => {
                        drop(term);
                        thread::park_timeout(remaining.min(Duration::from_millis(1)));
                        continue;
                    }
                    Err(TryLockError::Poisoned(_)) => {
                        drop(term);
                        send_snapshot_resync(&host, &mut stream, smart_renderer);
                        anyhow::bail!("terminal snapshot viewer-size state is poisoned");
                    }
                };
                let size = match host.size.try_lock() {
                    Ok(guard) => guard,
                    Err(TryLockError::WouldBlock) => {
                        drop(viewer_sizes);
                        drop(term);
                        thread::park_timeout(remaining.min(Duration::from_millis(1)));
                        continue;
                    }
                    Err(TryLockError::Poisoned(_)) => {
                        drop(viewer_sizes);
                        drop(term);
                        send_snapshot_resync(&host, &mut stream, smart_renderer);
                        anyhow::bail!("terminal snapshot size state is poisoned");
                    }
                };
                let cell_pixels = match host.cell_pixels.try_lock() {
                    Ok(guard) => guard,
                    Err(TryLockError::WouldBlock) => {
                        drop(size);
                        drop(viewer_sizes);
                        drop(term);
                        thread::park_timeout(remaining.min(Duration::from_millis(1)));
                        continue;
                    }
                    Err(TryLockError::Poisoned(_)) => {
                        drop(size);
                        drop(viewer_sizes);
                        drop(term);
                        send_snapshot_resync(&host, &mut stream, smart_renderer);
                        anyhow::bail!("terminal snapshot cell-pixel state is poisoned");
                    }
                };
                break (viewer_sizes, size, cell_pixels, term);
            };
            let replay = term.vt_replay_bounded_theme_portable_with_aliases(
                crate::surface::VT_REPLAY_MAX_BYTES,
            )?;
            let colors = term.color_overrides();
            let (cols, rows) = *size;
            let cell_pixels = *cell_pixels;
            debug_assert_eq!((term.cols(), term.rows()), (cols, rows));
            if host.dead.load(Ordering::Acquire) {
                anyhow::bail!("terminal host exited before snapshot");
            }
            let active_client_stream = ActiveClientStream::register(host.clone());
            // A renderer needs an initial reservation until it reports its
            // measured grid. Admin and read-only mirror connections are
            // management/observation channels and must never pin the PTY to
            // the snapshot size merely by connecting.
            if hello.role == ClientRole::Renderer
                && granted_rights.contains(CapabilityRights::RESIZE)
            {
                viewer_sizes.insert(client, (cols, rows));
            }
            let (snapshot_sequence, replay_gap) = if smart_renderer {
                match host.smart.subscribe(client, tap.clone()) {
                    Ok(boundary) => (boundary, None),
                    Err(gap) => (host.smart.applied_cursor.load(Ordering::Acquire), Some(gap)),
                }
            } else {
                let _broadcast = host.broadcast_lock.lock().unwrap();
                host.taps.lock().unwrap().insert(client, tap.clone());
                (host.sequence.load(Ordering::Acquire), None)
            };
            (
                HostSnapshot {
                    cols,
                    rows,
                    cell_pixels,
                    replay: replay.bytes,
                    kitty_image_aliases: replay.kitty_image_aliases,
                    kitty_state: replay.kitty_state,
                    sequence_boundary: 0,
                    colors: colors.clone(),
                    pid: host.pid,
                    command: host.command.clone(),
                    cwd: snapshot_cwd(&term, host.cwd.as_deref()),
                },
                colors,
                snapshot_sequence,
                replay_gap,
                active_client_stream,
            )
        };
        let mut client_setup = ClientSetupRollback::new(host.clone(), client);
        if let Some(gap) = replay_gap {
            let mut frame = Frame::new(MessageKind::ResyncRequired, gap.encode());
            frame.sequence = snapshot_sequence;
            let _ = write_frame(&mut stream, &frame);
            return Ok(());
        }
        // Legacy hosts began reading as soon as the first owner tap joined.
        // Protocol v4 waits for Activate so public topology and its journal
        // record commit before the first exact PTY bytes can be observed.
        if !activation_required {
            launch_owner.stream_ready();
        }
        let mut snapshot_frame = Frame::new(MessageKind::Snapshot, encode_snapshot(&snapshot)?);
        snapshot_frame.sequence = snapshot_sequence;
        write_frame(&mut stream, &snapshot_frame)?;
        let mut colors_frame =
            Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors));
        colors_frame.sequence = snapshot_sequence;
        write_frame(&mut stream, &colors_frame)?;
        if smart_renderer {
            let mut ready = Frame::new(MessageKind::Ready, Vec::new());
            ready.sequence = snapshot_sequence;
            write_frame(&mut stream, &ready)?;
        }

        let mut command_stream = stream.try_clone()?;
        let command_host = host.clone();
        thread::Builder::new().name("terminal-host-client-input".into()).spawn(move || {
            let mut detached = false;
            while let Ok(Some(frame)) = read_frame(&mut command_stream, MAX_FRAME_PAYLOAD) {
                // Client-to-host messages currently define no flags and never
                // participate in the host live-stream sequence.
                if frame.version != selected_version || frame.flags != 0 || frame.sequence != 0 {
                    break;
                }
                match frame.kind {
                    MessageKind::Activate => {
                        if selected_version < LAUNCH_ACTIVATION_PROTOCOL_VERSION
                            || !launch_owner_claimed
                            || frame.request_id != 0
                            || !frame.payload.is_empty()
                        {
                            break;
                        }
                        command_host.mark_launch_owner_stream_ready();
                    }
                    MessageKind::Input => {
                        if !granted_rights.contains(CapabilityRights::INPUT) {
                            break;
                        }
                        let mut writer = command_host.writer.lock().unwrap();
                        let _ = writer.write_all(&frame.payload);
                        let _ = writer.flush();
                    }
                    MessageKind::Paste => {
                        if !granted_rights.contains(CapabilityRights::INPUT) {
                            break;
                        }
                        let bracketed = command_host.term.lock().unwrap().mode(2004, false);
                        let mut writer = command_host.writer.lock().unwrap();
                        if bracketed {
                            let _ = writer.write_all(b"\x1b[200~");
                        }
                        let _ = writer.write_all(&frame.payload);
                        if bracketed {
                            let _ = writer.write_all(b"\x1b[201~");
                        }
                        let _ = writer.flush();
                    }
                    MessageKind::ViewerSize if frame.payload.len() == 4 => {
                        if !granted_rights.contains(CapabilityRights::RESIZE) {
                            break;
                        }
                        let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
                        let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
                        let targeted_ack = viewer_size_acks
                            .then_some((frame.request_id, &command_sender))
                            .filter(|(request_id, _)| *request_id != 0);
                        let acknowledge_with_replay = !smart_renderer && targeted_ack.is_none();
                        if !matches!(
                            command_host.set_viewer_size(
                                client,
                                cols,
                                rows,
                                acknowledge_with_replay,
                                targeted_ack,
                            ),
                            Ok(true)
                        ) {
                            // Invalid geometry or a PTY/parser resize failure
                            // rejects this admin stream. A failed targeted
                            // acknowledgement closes only this renderer; the
                            // committed canonical transition remains valid.
                            break;
                        }
                    }
                    MessageKind::ReleaseViewer => {
                        if !granted_rights.contains(CapabilityRights::RESIZE) {
                            break;
                        }
                        command_host.remove_viewer_size(client);
                    }
                    MessageKind::Terminate => {
                        if !granted_rights.contains(CapabilityRights::TERMINATE) {
                            break;
                        }
                        if launch_owner_claimed {
                            command_host.mark_launch_owner_stream_ready();
                        }
                        let receipt_queued = if frame.request_id == 0 {
                            true
                        } else {
                            let mut response = Frame::new(MessageKind::TerminateAck, Vec::new());
                            response.request_id = frame.request_id;
                            let _broadcast = command_host.broadcast_lock.lock().unwrap();
                            command_sender.try_send(response)
                        };
                        command_host.request_termination();
                        if !receipt_queued {
                            break;
                        }
                    }
                    MessageKind::Detach => {
                        if !granted_rights.contains(CapabilityRights::TERMINATE)
                            || frame.request_id == 0
                        {
                            break;
                        }
                        if !command_host.fence_client_detach(
                            client,
                            frame.request_id,
                            &command_sender,
                        ) {
                            break;
                        }
                        command_sender.wake_writer();
                        detached = true;
                        break;
                    }
                    MessageKind::SetDefaults => {
                        if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
                            break;
                        }
                        let Ok(colors) = decode_default_colors_payload(&frame.payload) else {
                            break;
                        };
                        command_host.set_default_colors(colors);
                    }
                    MessageKind::SetCellPixelSize
                        if frame.request_id != 0 && frame.payload.len() == 4 =>
                    {
                        if !granted_rights.contains(CapabilityRights::RESIZE) {
                            break;
                        }
                        let width_px = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
                        let height_px = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
                        if !matches!(
                            command_host.set_cell_pixel_size(
                                width_px,
                                height_px,
                                frame.request_id,
                                &command_sender,
                            ),
                            Ok(true)
                        ) {
                            break;
                        }
                    }
                    MessageKind::SetKittyGraphicsLimits
                        if frame.request_id != 0
                            && frame.payload.len() == KITTY_GRAPHICS_LIMITS_ENCODED_LEN =>
                    {
                        if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
                            break;
                        }
                        let mut decoder = PayloadDecoder::new(&frame.payload);
                        let Ok(limits) = decode_kitty_graphics_limits(&mut decoder) else {
                            break;
                        };
                        if decoder.finish().is_err()
                            || !matches!(
                                command_host.set_kitty_graphics_limits(
                                    limits,
                                    frame.request_id,
                                    &command_sender,
                                ),
                                Ok(true)
                            )
                        {
                            break;
                        }
                    }
                    MessageKind::ClearHistory => {
                        if !granted_rights.contains(CapabilityRights::INPUT)
                            || frame.request_id == 0
                        {
                            break;
                        }
                        let Ok(fallback_key) =
                            crate::server::decode_terminal_host_clear_history(&frame.payload)
                        else {
                            break;
                        };
                        let status = match command_host.clear_history_or_encode_key(
                            fallback_key.as_ref(),
                            smart_renderer.then_some((frame.request_id, &command_sender)),
                        ) {
                            Ok(ClearHistoryAckDisposition::Queued) => continue,
                            Ok(ClearHistoryAckDisposition::ConnectionClosed) => break,
                            Ok(ClearHistoryAckDisposition::Pending) => CLEAR_HISTORY_ACK_OK,
                            Err(failure) => clear_history_ack_status(Err(failure)),
                        };
                        let mut response = Frame::new(MessageKind::ClearHistoryAck, vec![status]);
                        response.request_id = frame.request_id;
                        let _broadcast = command_host.broadcast_lock.lock().unwrap();
                        if !command_sender.try_send(response) {
                            break;
                        }
                    }
                    MessageKind::MintCapability => {
                        if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY)
                            || frame.request_id == 0
                        {
                            break;
                        }
                        let Ok(token) = mint_renderer_capability(&command_host, &frame.payload)
                        else {
                            break;
                        };
                        let mut response =
                            Frame::new(MessageKind::Capability, token.as_bytes().to_vec());
                        response.request_id = frame.request_id;
                        // Targeted control responses share the socket writer
                        // with live frames. Serialize enqueueing with coupled
                        // Output/Resized + Colors publication so even an admin
                        // response cannot physically split an atomic pair.
                        let _broadcast = command_host.broadcast_lock.lock().unwrap();
                        if !command_sender.try_send(response) {
                            break;
                        }
                    }
                    _ => break,
                }
            }
            // Wake a writer that is waiting on an otherwise-empty live-frame
            // channel. The socket is shut down first, so this private wakeup
            // frame can never be mistaken for a sequenced host transition.
            if !detached {
                command_sender.close_and_wake_writer();
            }
            command_host.remove_client(client);
        })?;
        client_setup.disarm();

        while let Ok(frame) = receiver.recv() {
            if frame.kind == MessageKind::ResyncRequired && frame.sequence == 0 {
                tap.release(&frame);
                break;
            }
            let write_result = write_frame(&mut stream, &frame);
            tap.release(&frame);
            if write_result.is_err() {
                break;
            }
            if frame.kind == MessageKind::Exit {
                break;
            }
        }
        host.remove_client(client);
        Ok(())
    }

    fn authenticate_client(host: &HostShared, hello: &ClientHello) -> anyhow::Result<HostHello> {
        if hello.terminal_id != host.terminal_id {
            anyhow::bail!("terminal-host capability denied");
        }
        if constant_time_equal(hello.token.as_bytes(), host.owner_token.as_bytes()) {
            if hello.role != ClientRole::Admin
                || hello.requested_rights.is_empty()
                || !CapabilityRights::ADMIN.contains(hello.requested_rights)
                || hello.min_version > PROTOCOL_VERSION
                || hello.max_version < PROTOCOL_VERSION
            {
                anyhow::bail!("terminal-host owner capability denied");
            }
            return Ok(HostHello {
                selected_version: PROTOCOL_VERSION,
                granted_rights: hello.requested_rights,
                terminal_id: host.terminal_id,
                incarnation: host.incarnation,
            });
        }
        Ok(host.capabilities.accept(
            hello,
            PROTOCOL_VERSION..=PROTOCOL_VERSION,
            host.incarnation,
        )?)
    }

    fn mint_renderer_capability(
        host: &HostShared,
        payload: &[u8],
    ) -> anyhow::Result<CapabilityToken> {
        if payload.len() != 8 {
            anyhow::bail!("bad renderer capability request");
        }
        let rights = CapabilityRights::from_bits(u32::from_le_bytes(
            payload[0..4].try_into().expect("fixed rights slice"),
        ))
        .ok_or_else(|| anyhow::anyhow!("unknown renderer capability rights"))?;
        if !rights.contains(CapabilityRights::READ) || !CapabilityRights::RENDERER.contains(rights)
        {
            anyhow::bail!("renderer capability rights are out of range");
        }
        let ttl_ms = u32::from_le_bytes(payload[4..8].try_into().expect("fixed TTL slice"));
        let ttl = Duration::from_millis(u64::from(ttl_ms));
        if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
            anyhow::bail!("renderer capability TTL is out of range");
        }
        Ok(host.capabilities.mint(host.terminal_id, rights, ttl)?)
    }

    fn encode_snapshot(snapshot: &HostSnapshot) -> anyhow::Result<Vec<u8>> {
        let (cols, rows) = normalize_terminal_geometry(snapshot.cols, snapshot.rows)?;
        snapshot
            .kitty_state
            .validate_for_replay(snapshot.replay.len())
            .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?;
        let mut output = Vec::new();
        output.extend_from_slice(&cols.to_le_bytes());
        output.extend_from_slice(&rows.to_le_bytes());
        output.extend_from_slice(&snapshot.pid.unwrap_or(0).to_le_bytes());
        put_blob(&mut output, &snapshot.replay)?;
        put_optional_string(&mut output, snapshot.cwd.as_deref())?;
        if snapshot.command.len() > MAX_ARGV {
            anyhow::bail!("terminal-host snapshot command count is too large");
        }
        output.extend_from_slice(&(snapshot.command.len() as u16).to_le_bytes());
        for argument in &snapshot.command {
            put_string(&mut output, argument)?;
        }
        encode_kitty_image_aliases(&mut output, &snapshot.kitty_image_aliases)?;
        output.extend_from_slice(&snapshot.cell_pixels.0.max(1).to_le_bytes());
        output.extend_from_slice(&snapshot.cell_pixels.1.max(1).to_le_bytes());
        encode_kitty_replay_state(&mut output, snapshot.kitty_state)?;
        if output.len() > MAX_FRAME_PAYLOAD {
            anyhow::bail!("terminal-host snapshot payload is too large");
        }
        Ok(output)
    }

    /// Encode the version-current snapshot payload used by native smart
    /// renderer clients. Keeping this paired with the public decoder prevents
    /// client fixtures and adapters from reproducing a stale wire schema.
    pub fn encode_host_snapshot_payload(snapshot: &HostSnapshot) -> anyhow::Result<Vec<u8>> {
        encode_snapshot(snapshot)
    }

    #[cfg(test)]
    fn decode_snapshot(payload: &[u8]) -> anyhow::Result<HostSnapshot> {
        decode_snapshot_for_version(payload, PROTOCOL_VERSION)
    }

    pub fn decode_host_snapshot_payload(payload: &[u8]) -> anyhow::Result<HostSnapshot> {
        decode_snapshot_for_version(payload, PROTOCOL_VERSION)
    }

    fn decode_snapshot_for_version(
        payload: &[u8],
        protocol_version: u16,
    ) -> anyhow::Result<HostSnapshot> {
        if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
            anyhow::bail!("unsupported terminal-host snapshot protocol {protocol_version}");
        }
        let mut decoder = PayloadDecoder::new(payload);
        let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
        let pid = match decoder.u32()? {
            0 => None,
            pid => Some(pid),
        };
        let replay = decoder.blob()?.to_vec();
        let cwd = decoder.optional_string()?;
        let argc = decoder.u16()? as usize;
        if argc > MAX_ARGV {
            anyhow::bail!("terminal-host snapshot command count is too large");
        }
        let mut command = Vec::with_capacity(argc);
        for _ in 0..argc {
            command.push(decoder.string()?);
        }
        let kitty_image_aliases = if protocol_version >= 2 {
            decode_kitty_image_aliases(&mut decoder)?
        } else {
            Vec::new()
        };
        let cell_pixels = if protocol_version >= 2 {
            (decoder.u16()?.max(1), decoder.u16()?.max(1))
        } else {
            DEFAULT_CELL_PIXELS
        };
        let kitty_state = if protocol_version >= 3 {
            decode_kitty_replay_state(&mut decoder)?
                .validate_for_replay(replay.len())
                .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?
        } else {
            KittyReplayState::disabled()
        };
        pty_size(cols, rows, cell_pixels)?;
        decoder.finish()?;
        Ok(HostSnapshot {
            cols,
            rows,
            cell_pixels,
            replay,
            kitty_image_aliases,
            kitty_state,
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid,
            command,
            cwd,
        })
    }

    fn encode_kitty_image_aliases(
        output: &mut Vec<u8>,
        aliases: &[KittyImageAlias],
    ) -> anyhow::Result<()> {
        validate_kitty_image_aliases(aliases)?;
        output.extend_from_slice(&(aliases.len() as u16).to_le_bytes());
        for alias in aliases {
            output.extend_from_slice(&alias.image_id.to_le_bytes());
            output.extend_from_slice(&alias.image_number.to_le_bytes());
        }
        Ok(())
    }

    fn decode_kitty_image_aliases(
        decoder: &mut PayloadDecoder<'_>,
    ) -> anyhow::Result<Vec<KittyImageAlias>> {
        let count = decoder.u16()? as usize;
        if count > MAX_KITTY_IMAGE_ALIASES {
            anyhow::bail!("terminal-host Kitty image alias count is too large");
        }
        let mut aliases = Vec::with_capacity(count);
        for _ in 0..count {
            aliases
                .push(KittyImageAlias { image_id: decoder.u32()?, image_number: decoder.u32()? });
        }
        validate_kitty_image_aliases(&aliases)?;
        Ok(aliases)
    }

    fn encode_kitty_graphics_limits(
        output: &mut Vec<u8>,
        limits: KittyGraphicsLimits,
    ) -> anyhow::Result<()> {
        let limits = limits
            .validate()
            .map_err(|_| anyhow::anyhow!("terminal-host Kitty graphics limits are out of range"))?;
        output.extend_from_slice(&limits.image_bytes.to_le_bytes());
        output.extend_from_slice(&limits.inflight_bytes.to_le_bytes());
        output.extend_from_slice(&limits.images.to_le_bytes());
        output.extend_from_slice(&limits.placements.to_le_bytes());
        Ok(())
    }

    fn decode_kitty_graphics_limits(
        decoder: &mut PayloadDecoder<'_>,
    ) -> anyhow::Result<KittyGraphicsLimits> {
        KittyGraphicsLimits {
            image_bytes: decoder.u64()?,
            inflight_bytes: decoder.u64()?,
            images: decoder.u64()?,
            placements: decoder.u64()?,
        }
        .validate()
        .map_err(|_| anyhow::anyhow!("terminal-host Kitty graphics limits are out of range"))
    }

    fn encode_kitty_replay_state(
        output: &mut Vec<u8>,
        state: KittyReplayState,
    ) -> anyhow::Result<()> {
        let state = state
            .validate()
            .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay state is invalid"))?;
        encode_kitty_graphics_limits(output, state.limits)?;
        output.extend_from_slice(&state.replay_cursor_offset.to_le_bytes());
        output.extend_from_slice(&state.replay_next_image_ids.primary.to_le_bytes());
        output.extend_from_slice(&state.next_image_ids.primary.to_le_bytes());
        output.extend_from_slice(&state.replay_next_image_ids.alternate.to_le_bytes());
        output.extend_from_slice(&state.next_image_ids.alternate.to_le_bytes());
        Ok(())
    }

    fn decode_kitty_replay_state(
        decoder: &mut PayloadDecoder<'_>,
    ) -> anyhow::Result<KittyReplayState> {
        let limits = decode_kitty_graphics_limits(decoder)?;
        let replay_cursor_offset = decoder.u32()?;
        let primary_replay_next_image_id = decoder.u32()?;
        let primary_next_image_id = decoder.u32()?;
        let alternate_replay_next_image_id = decoder.u32()?;
        let alternate_next_image_id = decoder.u32()?;
        KittyReplayState {
            limits,
            replay_cursor_offset,
            replay_next_image_ids: KittyImageIdCursors {
                primary: primary_replay_next_image_id,
                alternate: alternate_replay_next_image_id,
            },
            next_image_ids: KittyImageIdCursors {
                primary: primary_next_image_id,
                alternate: alternate_next_image_id,
            },
        }
        .validate()
        .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay state is invalid"))
    }

    fn encode_resize(
        cols: u16,
        rows: u16,
        replay: &[u8],
        kitty_image_aliases: &[KittyImageAlias],
        cell_pixels: (u16, u16),
        kitty_state: KittyReplayState,
    ) -> anyhow::Result<Vec<u8>> {
        let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
        kitty_state
            .validate_for_replay(replay.len())
            .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?;
        let cell_pixels = (cell_pixels.0.max(1), cell_pixels.1.max(1));
        pty_size(cols, rows, cell_pixels)?;
        if replay.len() > crate::surface::VT_REPLAY_MAX_BYTES {
            anyhow::bail!("terminal-host resize replay is too large");
        }
        let replay_len = u32::try_from(replay.len())
            .map_err(|_| anyhow::anyhow!("terminal-host resize replay exceeds u32"))?;
        let mut output = Vec::with_capacity(
            8 + replay.len()
                + KITTY_IMAGE_ALIAS_COUNT_LEN
                + kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN
                + CELL_PIXEL_SIZE_ENCODED_LEN
                + KITTY_REPLAY_STATE_ENCODED_LEN,
        );
        output.extend_from_slice(&cols.to_le_bytes());
        output.extend_from_slice(&rows.to_le_bytes());
        output.extend_from_slice(&replay_len.to_le_bytes());
        output.extend_from_slice(replay);
        encode_kitty_image_aliases(&mut output, kitty_image_aliases)?;
        output.extend_from_slice(&cell_pixels.0.to_le_bytes());
        output.extend_from_slice(&cell_pixels.1.to_le_bytes());
        encode_kitty_replay_state(&mut output, kitty_state)?;
        if output.len() > MAX_FRAME_PAYLOAD {
            anyhow::bail!("terminal-host resize payload is too large");
        }
        Ok(output)
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) struct DecodedHostResize {
        pub cols: u16,
        pub rows: u16,
        pub cell_pixels: (u16, u16),
        pub replay: Vec<u8>,
        pub kitty_image_aliases: Vec<KittyImageAlias>,
        pub kitty_state: KittyReplayState,
    }

    #[cfg(test)]
    pub(crate) fn decode_host_resize_payload(payload: &[u8]) -> anyhow::Result<DecodedHostResize> {
        decode_host_resize_payload_for_version(payload, PROTOCOL_VERSION)
    }

    pub(crate) fn decode_host_resize_payload_for_version(
        payload: &[u8],
        protocol_version: u16,
    ) -> anyhow::Result<DecodedHostResize> {
        if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
            anyhow::bail!("unsupported terminal-host resize protocol {protocol_version}");
        }
        let mut decoder = PayloadDecoder::new(payload);
        let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
        let replay = decoder.bytes_with_limit(crate::surface::VT_REPLAY_MAX_BYTES)?.to_vec();
        let kitty_image_aliases = if protocol_version >= 2 {
            decode_kitty_image_aliases(&mut decoder)?
        } else {
            Vec::new()
        };
        let cell_pixels = if protocol_version >= 2 {
            (decoder.u16()?.max(1), decoder.u16()?.max(1))
        } else {
            DEFAULT_CELL_PIXELS
        };
        let kitty_state = if protocol_version >= 3 {
            decode_kitty_replay_state(&mut decoder)?
                .validate_for_replay(replay.len())
                .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?
        } else {
            KittyReplayState::disabled()
        };
        pty_size(cols, rows, cell_pixels)?;
        decoder.finish()?;
        Ok(DecodedHostResize { cols, rows, cell_pixels, replay, kitty_image_aliases, kitty_state })
    }

    fn encode_resize_ack(cols: u16, rows: u16, canonical_changed: bool) -> Vec<u8> {
        let mut output = Vec::with_capacity(8);
        output.extend_from_slice(&cols.to_le_bytes());
        output.extend_from_slice(&rows.to_le_bytes());
        output.extend_from_slice(
            &(if canonical_changed { RESIZE_ACK_CANONICAL_CHANGED } else { 0 }).to_le_bytes(),
        );
        output
    }

    fn protocol_io_error(error: crate::terminal_host_protocol::ProtocolError) -> std::io::Error {
        match error {
            crate::terminal_host_protocol::ProtocolError::Io(error) => error,
            other => std::io::Error::new(std::io::ErrorKind::InvalidData, other),
        }
    }

    fn stable_token(value: &str) -> String {
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        for byte in value.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
        format!("{hash:016x}")
    }

    fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
        if left.len() != right.len() {
            return false;
        }
        let mut difference = 0u8;
        for (left, right) in left.iter().zip(right) {
            difference |= left ^ right;
        }
        difference == 0
    }

    fn encode_hex(bytes: &[u8]) -> String {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        let mut output = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            output.push(HEX[(byte >> 4) as usize] as char);
            output.push(HEX[(byte & 0x0f) as usize] as char);
        }
        output
    }

    fn decode_hex_array<const N: usize>(text: &str) -> anyhow::Result<[u8; N]> {
        if text.len() != N * 2 {
            anyhow::bail!("terminal-host identity has the wrong length");
        }
        let mut bytes = [0u8; N];
        for (index, byte) in bytes.iter_mut().enumerate() {
            let start = index * 2;
            *byte = u8::from_str_radix(&text[start..start + 2], 16)
                .map_err(|_| anyhow::anyhow!("terminal-host identity is not hexadecimal"))?;
        }
        Ok(bytes)
    }

    fn decode_lower_hex_array<const N: usize>(text: &str, field: &str) -> anyhow::Result<[u8; N]> {
        if !text.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')) {
            anyhow::bail!("terminal-host {field} is not canonical lowercase hexadecimal");
        }
        decode_hex_array(text)
    }

    fn process_definitely_absent(pid: u32) -> bool {
        let Ok(pid) = libc::pid_t::try_from(pid) else { return true };
        // SAFETY: signal zero performs a liveness/permission probe and does
        // not deliver a signal to the target process.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return false;
        }
        std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    }

    struct PayloadDecoder<'a> {
        payload: &'a [u8],
        offset: usize,
    }

    impl<'a> PayloadDecoder<'a> {
        fn new(payload: &'a [u8]) -> Self {
            Self { payload, offset: 0 }
        }

        fn take(&mut self, length: usize) -> anyhow::Result<&'a [u8]> {
            let end = self
                .offset
                .checked_add(length)
                .filter(|end| *end <= self.payload.len())
                .ok_or_else(|| anyhow::anyhow!("truncated terminal-host payload"))?;
            let bytes = &self.payload[self.offset..end];
            self.offset = end;
            Ok(bytes)
        }

        fn u16(&mut self) -> anyhow::Result<u16> {
            Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
        }

        fn u8(&mut self) -> anyhow::Result<u8> {
            Ok(self.take(1)?[0])
        }

        fn rgb(&mut self) -> anyhow::Result<Rgb> {
            let bytes = self.take(3)?;
            Ok(Rgb { r: bytes[0], g: bytes[1], b: bytes[2] })
        }

        fn u32(&mut self) -> anyhow::Result<u32> {
            Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
        }

        fn u64(&mut self) -> anyhow::Result<u64> {
            Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
        }

        fn bytes_with_limit(&mut self, limit: usize) -> anyhow::Result<&'a [u8]> {
            let length = self.u32()? as usize;
            if length > limit {
                anyhow::bail!("terminal-host payload field is too large");
            }
            self.take(length)
        }

        fn blob(&mut self) -> anyhow::Result<&'a [u8]> {
            self.bytes_with_limit(MAX_BLOB)
        }

        fn string(&mut self) -> anyhow::Result<String> {
            Ok(std::str::from_utf8(self.bytes_with_limit(MAX_STRING)?)?.to_string())
        }

        fn optional_string(&mut self) -> anyhow::Result<Option<String>> {
            match self.take(1)?[0] {
                0 => Ok(None),
                1 => Ok(Some(self.string()?)),
                _ => anyhow::bail!("bad terminal-host optional string tag"),
            }
        }

        fn finish(&self) -> anyhow::Result<()> {
            if self.offset != self.payload.len() {
                anyhow::bail!("trailing terminal-host payload bytes");
            }
            Ok(())
        }
    }

    fn put_bytes(output: &mut Vec<u8>, bytes: &[u8]) -> anyhow::Result<()> {
        if bytes.len() > MAX_STRING {
            anyhow::bail!("terminal-host payload field is too large");
        }
        output.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        output.extend_from_slice(bytes);
        Ok(())
    }

    fn put_string(output: &mut Vec<u8>, value: &str) -> anyhow::Result<()> {
        put_bytes(output, value.as_bytes())
    }

    fn put_blob(output: &mut Vec<u8>, value: &[u8]) -> anyhow::Result<()> {
        if value.len() > MAX_BLOB {
            anyhow::bail!("terminal-host payload blob is too large");
        }
        output.extend_from_slice(&(value.len() as u32).to_le_bytes());
        output.extend_from_slice(value);
        Ok(())
    }

    fn put_optional_string(output: &mut Vec<u8>, value: Option<&str>) -> anyhow::Result<()> {
        match value {
            Some(value) => {
                output.push(1);
                put_string(output, value)
            }
            None => {
                output.push(0);
                Ok(())
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn test_kitty_state() -> KittyReplayState {
            KittyReplayState {
                limits: KittyGraphicsLimits {
                    image_bytes: 1,
                    inflight_bytes: 2,
                    images: 3,
                    placements: 4,
                },
                replay_cursor_offset: 0,
                replay_next_image_ids: KittyImageIdCursors { primary: 5, alternate: 7 },
                next_image_ids: KittyImageIdCursors { primary: 6, alternate: 8 },
            }
        }

        struct TestHostMaster {
            size: Mutex<PtySize>,
        }

        impl MasterPty for TestHostMaster {
            fn resize(&self, size: PtySize) -> anyhow::Result<()> {
                *self.size.lock().unwrap() = size;
                Ok(())
            }

            fn get_size(&self) -> anyhow::Result<PtySize> {
                Ok(*self.size.lock().unwrap())
            }

            fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
                Ok(Box::new(std::io::empty()))
            }

            fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
                Ok(Box::new(std::io::sink()))
            }

            fn process_group_leader(&self) -> Option<libc::pid_t> {
                None
            }

            fn as_raw_fd(&self) -> Option<RawFd> {
                None
            }

            fn tty_name(&self) -> Option<PathBuf> {
                None
            }
        }

        #[derive(Debug)]
        struct TestHostKiller;

        impl ChildKiller for TestHostKiller {
            fn kill(&mut self) -> std::io::Result<()> {
                Ok(())
            }

            fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
                Box::new(Self)
            }
        }

        fn exited_host_fixture_with_parser_at(
            exit_record_parent: PathBuf,
        ) -> (Arc<HostShared>, Receiver<ParserCommand>) {
            let mut term = Terminal::new(80, 24, 1_000, Callbacks::default()).unwrap();
            term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
            let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
            let (parser_commands, parser_receiver) = sync_channel(1);
            let terminal_id = TerminalId::random().unwrap();
            let exit_record_path =
                exit_record_parent.join(format!("{}.exit", terminal_id.to_hex()));
            let host = Arc::new(HostShared {
                terminal_id,
                incarnation: HostIncarnation::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
                capabilities: CapabilityStore::new(64),
                term: Mutex::new(term),
                default_colors: Mutex::new(DefaultColors::default()),
                stream_progress: TerminalStreamProgress::default(),
                writer: Mutex::new(Box::new(std::io::sink())),
                master: Mutex::new(Box::new(TestHostMaster {
                    size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS).unwrap()),
                })),
                killer: Mutex::new(Box::new(TestHostKiller)),
                pid: None,
                command: Vec::new(),
                cwd: None,
                size: Mutex::new((80, 24)),
                cell_pixels: Mutex::new(DEFAULT_CELL_PIXELS),
                viewer_sizes: Mutex::new(HashMap::new()),
                taps: Mutex::new(HashMap::new()),
                broadcast_lock: Mutex::new(()),
                sequence: AtomicU64::new(0),
                smart: SmartStreamState::new(),
                source_order_lock: Mutex::new(()),
                parser_commands,
                parser_budget: ParserBudget::new(1),
                parser_progress: (Mutex::new(0), Condvar::new()),
                next_client: AtomicU64::new(1),
                dead: AtomicBool::new(false),
                launch_owner_claimed: AtomicBool::new(true),
                launch_owner_stream_ready: AtomicBool::new(true),
                launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
                active_client_streams: AtomicUsize::new(0),
                child_exit: (
                    Mutex::new(Some(TerminalExit {
                        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit {
                            code: 17,
                        },
                        exited_at_ms: 1_234,
                    })),
                    Condvar::new(),
                ),
                child_waitable: AtomicBool::new(true),
                pty_drained: AtomicBool::new(true),
                exit_published: AtomicBool::new(false),
                exit_record_path,
                exit_publish_requests,
                force_pty_drain: AtomicBool::new(false),
                pty_drain_waker: Mutex::new(pty_drain_waker),
                termination_started: AtomicBool::new(false),
                child_signal_lock: Mutex::new(()),
                child_reaped: AtomicBool::new(true),
                group_escalation_complete: AtomicBool::new(false),
                fail_next_resize_publication: AtomicBool::new(false),
            });
            HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
            (host, parser_receiver)
        }

        fn exited_host_fixture_at(exit_record_parent: PathBuf) -> Arc<HostShared> {
            exited_host_fixture_with_parser_at(exit_record_parent).0
        }

        fn exited_host_fixture() -> Arc<HostShared> {
            let root = std::env::temp_dir().join(format!(
                "cmux-terminal-exit-tests-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            exited_host_fixture_at(root)
        }

        fn exited_host_fixture_with_parser() -> (Arc<HostShared>, Receiver<ParserCommand>) {
            let root = std::env::temp_dir().join(format!(
                "cmux-terminal-exit-tests-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            exited_host_fixture_with_parser_at(root)
        }

        fn test_host_shared() -> Arc<HostShared> {
            let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
            let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
            let (parser_commands, _parser_receiver) = sync_channel(1);
            let host = Arc::new(HostShared {
                terminal_id: TerminalId::random().unwrap(),
                incarnation: HostIncarnation::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
                capabilities: CapabilityStore::new(64),
                term: Mutex::new(term),
                default_colors: Mutex::new(DefaultColors::default()),
                stream_progress: TerminalStreamProgress::default(),
                writer: Mutex::new(Box::new(std::io::sink())),
                master: Mutex::new(Box::new(TestHostMaster {
                    size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS).unwrap()),
                })),
                killer: Mutex::new(Box::new(TestHostKiller)),
                pid: None,
                command: vec!["/bin/cat".into()],
                cwd: None,
                size: Mutex::new((80, 24)),
                cell_pixels: Mutex::new(DEFAULT_CELL_PIXELS),
                viewer_sizes: Mutex::new(HashMap::new()),
                taps: Mutex::new(HashMap::new()),
                broadcast_lock: Mutex::new(()),
                sequence: AtomicU64::new(0),
                smart: SmartStreamState::new(),
                source_order_lock: Mutex::new(()),
                parser_commands,
                parser_budget: ParserBudget::new(1),
                parser_progress: (Mutex::new(0), Condvar::new()),
                next_client: AtomicU64::new(1),
                dead: AtomicBool::new(false),
                launch_owner_claimed: AtomicBool::new(false),
                launch_owner_stream_ready: AtomicBool::new(false),
                launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
                active_client_streams: AtomicUsize::new(0),
                child_exit: (Mutex::new(None), Condvar::new()),
                child_waitable: AtomicBool::new(false),
                pty_drained: AtomicBool::new(false),
                exit_published: AtomicBool::new(false),
                exit_record_path: std::env::temp_dir().join(format!(
                    "cmux-host-test-exit-{}-{}",
                    std::process::id(),
                    RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
                )),
                exit_publish_requests,
                force_pty_drain: AtomicBool::new(false),
                pty_drain_waker: Mutex::new(pty_drain_waker),
                termination_started: AtomicBool::new(false),
                child_signal_lock: Mutex::new(()),
                child_reaped: AtomicBool::new(false),
                group_escalation_complete: AtomicBool::new(false),
                fail_next_resize_publication: AtomicBool::new(false),
            });
            HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
            host
        }

        fn record_fixture(name: &str) -> (PathBuf, TerminalHostRecord, HostLivenessLease) {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-record-{name}-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            let terminal_id = TerminalId::random().unwrap();
            let incarnation = HostIncarnation::random().unwrap();
            let owner = CapabilityToken::random().unwrap();
            let nonce = CapabilityToken::random().unwrap();
            let terminal_hex = terminal_id.to_hex();
            let uid = fs::metadata(&root).unwrap().uid();
            let record = TerminalHostRecord {
                record_version: HOST_RECORD_VERSION,
                terminal_id: terminal_hex.clone(),
                incarnation: incarnation.to_hex(),
                endpoint: format!("/tmp/cmux-th-{uid}/{terminal_hex}.sock"),
                owner_token: encode_hex(owner.as_bytes()),
                host_pid: std::process::id(),
                host_start_nonce: encode_hex(nonce.as_bytes()),
                workspace_key: String::new(),
                supports_set_defaults: true,
                supports_clear_history: true,
                supports_terminate_ack: true,
            };
            let record_path = record.record_path(&root);
            let lease = HostLivenessLease::acquire(liveness_path(&record_path, &record)).unwrap();
            write_record(&record_path, &record).unwrap();
            (record_path, record, lease)
        }

        #[test]
        fn default_host_cell_metrics_initialize_both_terminal_backends() {
            let size = pty_size(80, 24, DEFAULT_CELL_PIXELS).unwrap();
            assert_eq!(
                (size.cols, size.rows, size.pixel_width, size.pixel_height),
                (80, 24, 640, 384)
            );

            let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            terminal
                .resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=1,c=1,r=1,q=2;/wAA\x1b\\");
            let graphics = terminal.kitty_graphics_snapshot().unwrap();
            assert_eq!(
                (graphics.placements[0].pixel_width, graphics.placements[0].pixel_height),
                (8, 16)
            );
        }

        #[test]
        fn pty_size_rejects_pixel_dimension_overflow() {
            let maximum_cols = u16::MAX / DEFAULT_CELL_PIXELS.0;
            let boundary = pty_size(maximum_cols, 24, DEFAULT_CELL_PIXELS).unwrap();
            assert_eq!(boundary.pixel_width, maximum_cols * DEFAULT_CELL_PIXELS.0);

            let width_error = pty_size(maximum_cols + 1, 24, DEFAULT_CELL_PIXELS).unwrap_err();
            assert!(width_error.to_string().contains("pixel width"));

            let maximum_rows = u16::MAX / DEFAULT_CELL_PIXELS.1;
            let height_error = pty_size(80, maximum_rows + 1, DEFAULT_CELL_PIXELS).unwrap_err();
            assert!(height_error.to_string().contains("pixel height"));
        }

        #[test]
        fn launch_round_trip_preserves_ghostty_defaults() {
            let mut default_colors = DefaultColors {
                fg: Some(Rgb { r: 1, g: 2, b: 3 }),
                bg: Some(Rgb { r: 4, g: 5, b: 6 }),
                cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
                selection_bg: Some(Rgb { r: 16, g: 17, b: 18 }),
                selection_fg: Some(Rgb { r: 19, g: 20, b: 21 }),
                cursor_style: Some(CursorShape::Bar),
                cursor_blink: Some(false),
                ..Default::default()
            };
            default_colors.palette[0] = Some(Rgb { r: 10, g: 11, b: 12 });
            default_colors.palette[255] = Some(Rgb { r: 13, g: 14, b: 15 });
            let launch = HostLaunch {
                endpoint: "/tmp/terminal.sock".into(),
                record_path: "/tmp/terminal.json".into(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: (9, 18),
                scrollback: 10_000,
                cwd: Some("/tmp".into()),
                command: vec!["/bin/cat".into()],
                extra_env: vec![("KEY".into(), "value".into())],
                default_colors,
                kitty_graphics_limits: KittyGraphicsLimits {
                    image_bytes: 1_000,
                    inflight_bytes: 500,
                    images: 10,
                    placements: 20,
                },
            };

            let decoded = HostLaunch::decode(&launch.encode().unwrap()).unwrap();
            assert_eq!(decoded.default_colors, default_colors);
            assert_eq!(decoded.cell_pixels, (9, 18));
            assert_eq!(decoded.kitty_graphics_limits, launch.kitty_graphics_limits);
            assert_eq!(decoded.command, launch.command);
            assert_eq!(decoded.extra_env, launch.extra_env);
            assert_eq!(
                decode_default_colors_payload(&encode_default_colors_payload(default_colors))
                    .unwrap(),
                default_colors,
                "live SetDefaults must preserve the complete frontend defaults"
            );

            default_colors.cursor_blink = None;
            assert_eq!(
                decode_default_colors_payload(&encode_default_colors_payload(default_colors))
                    .unwrap()
                    .cursor_blink,
                None,
                "an absent Ghostty blink setting must survive the host boundary"
            );
        }

        #[test]
        fn launch_failure_is_reported_before_bootstrap_pipe_closes() {
            let sequence = RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let terminal_id = TerminalId::random().unwrap();
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id,
                owner_token: CapabilityToken::random().unwrap(),
            };
            let launch = HostLaunch {
                endpoint: format!(
                    "/tmp/cmux-host-launch-failure-{}-{sequence}.sock",
                    std::process::id()
                ),
                record_path: format!(
                    "/tmp/cmux-host-launch-failure-{}-{sequence}.json",
                    std::process::id()
                ),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 1_000,
                cwd: Some("/tmp".into()),
                command: vec!["/definitely/missing/cmux-terminal-host-child".into()],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };
            let mut input = Vec::new();
            write_frame(&mut input, &bootstrap.into_frame(1)).unwrap();
            let mut launch_frame = Frame::new(MessageKind::Launch, launch.encode().unwrap());
            launch_frame.request_id = 2;
            write_frame(&mut input, &launch_frame).unwrap();

            let mut output = Vec::new();
            let result = serve_terminal_host_stdio(
                &["--bootstrap-stdio".to_string()],
                &mut std::io::Cursor::new(input),
                &mut output,
            );
            assert!(result.is_ok(), "host closed without reporting launch failure: {result:?}");

            let mut output = std::io::Cursor::new(output);
            let ready = read_frame(&mut output, MAX_FRAME_PAYLOAD).unwrap().unwrap();
            assert_eq!(ready.kind, MessageKind::Ready);
            let failure_frame = read_frame(&mut output, MAX_FRAME_PAYLOAD).unwrap().unwrap();
            assert_eq!(failure_frame.kind, MessageKind::LaunchFailed);
            assert_eq!(failure_frame.request_id, 2);
            let failure = decode_host_launch_failure(&failure_frame.payload).unwrap();
            assert!(
                failure
                    .message
                    .as_bytes()
                    .windows("terminal launch failed".len())
                    .any(|window| window == b"terminal launch failed"),
                "launch failure payload omitted the child error: {failure:?}",
            );
        }

        #[test]
        fn pty_capacity_survives_context_as_a_typed_launch_failure() {
            let error = anyhow::Error::new(PtyOpenError::from_io(
                std_io::Error::from_raw_os_error(libc::ENXIO),
            ))
            .context("allocate terminal host");
            let failure = host_launch_failure(&error);

            assert_eq!(failure.kind, HostLaunchFailureKind::PtyCapacityExhausted);
            assert!(failure.message.contains("terminal launch failed"));
            assert!(failure.message.contains("PTY capacity exhausted"));
        }

        #[test]
        fn resized_payload_is_length_prefixed_for_cross_language_clients() {
            assert_eq!(
                encode_resize(
                    0x0123,
                    0x0456,
                    &[0xaa, 0xbb, 0xcc],
                    &[],
                    (9, 18),
                    test_kitty_state(),
                )
                .unwrap(),
                vec![
                    0x23, 0x01, 0x56, 0x04, 3, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0, 0, 9, 0, 18, 0, 1, 0,
                    0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 6, 0, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0,
                ]
            );
        }

        #[test]
        fn snapshot_payload_round_trip_preserves_kitty_image_alias_section() {
            let snapshot = HostSnapshot {
                cols: 80,
                rows: 24,
                cell_pixels: (9, 18),
                replay: b"theme-portable replay".to_vec(),
                kitty_image_aliases: vec![
                    KittyImageAlias { image_id: 41, image_number: 77 },
                    KittyImageAlias { image_id: 42, image_number: 77 },
                ],
                kitty_state: test_kitty_state(),
                sequence_boundary: 0,
                colors: TerminalColorOverrides::default(),
                pid: Some(42),
                command: vec!["/bin/cat".into()],
                cwd: Some("/tmp".into()),
            };
            let payload = encode_snapshot(&snapshot).unwrap();

            let decoded =
                decode_snapshot(&payload).expect("snapshot decoder must retain Kitty aliases");
            assert_eq!(decoded.kitty_image_aliases, snapshot.kitty_image_aliases);
            assert_eq!(decoded.kitty_state, snapshot.kitty_state);
            assert_eq!(decoded.cell_pixels, snapshot.cell_pixels);
            assert_eq!(
                encode_snapshot(&decoded).unwrap(),
                payload,
                "snapshot encode/decode dropped Kitty image-number aliases"
            );
        }

        #[test]
        fn snapshot_payload_matches_the_cross_language_current_golden_bytes() {
            let snapshot = HostSnapshot {
                cols: 1,
                rows: 2,
                cell_pixels: (9, 18),
                replay: Vec::new(),
                kitty_image_aliases: Vec::new(),
                kitty_state: test_kitty_state(),
                sequence_boundary: 0,
                colors: TerminalColorOverrides::default(),
                pid: None,
                command: Vec::new(),
                cwd: None,
            };

            assert_eq!(
                encode_snapshot(&snapshot).unwrap(),
                vec![
                    1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9, 0, 18, 0, 1, 0, 0, 0, 0,
                    0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 5, 0, 0, 0, 6, 0, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0,
                ]
            );
        }

        #[test]
        fn legacy_snapshots_and_resizes_decode_without_newer_tails() {
            let snapshot = HostSnapshot {
                cols: 80,
                rows: 24,
                cell_pixels: (9, 18),
                replay: b"legacy replay".to_vec(),
                kitty_image_aliases: vec![KittyImageAlias { image_id: 41, image_number: 77 }],
                kitty_state: test_kitty_state(),
                sequence_boundary: 0,
                colors: TerminalColorOverrides::default(),
                pid: Some(42),
                command: vec!["/bin/cat".into()],
                cwd: Some("/tmp".into()),
            };
            let snapshot_payload = encode_snapshot(&snapshot).unwrap();
            let v2_snapshot_len = snapshot_payload.len() - KITTY_REPLAY_STATE_ENCODED_LEN;
            let decoded = decode_snapshot_for_version(&snapshot_payload[..v2_snapshot_len], 2)
                .expect("protocol-v2 snapshots end after cell metrics");
            assert_eq!(decoded.replay, snapshot.replay);
            assert_eq!(decoded.kitty_image_aliases, snapshot.kitty_image_aliases);
            assert_eq!(decoded.cell_pixels, snapshot.cell_pixels);
            assert_eq!(decoded.kitty_state, KittyReplayState::disabled());

            let v1_snapshot_len = snapshot_payload.len()
                - KITTY_IMAGE_ALIAS_COUNT_LEN
                - snapshot.kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN
                - CELL_PIXEL_SIZE_ENCODED_LEN
                - KITTY_REPLAY_STATE_ENCODED_LEN;
            let decoded = decode_snapshot_for_version(
                &snapshot_payload[..v1_snapshot_len],
                LEGACY_PROTOCOL_VERSION,
            )
            .expect("protocol-v1 snapshots end before Kitty aliases");
            assert_eq!(decoded.replay, snapshot.replay);
            assert!(decoded.kitty_image_aliases.is_empty());
            assert_eq!(decoded.cell_pixels, DEFAULT_CELL_PIXELS);
            assert_eq!(decoded.kitty_state, KittyReplayState::disabled());

            let resize_payload = encode_resize(
                81,
                25,
                b"legacy resize",
                &snapshot.kitty_image_aliases,
                snapshot.cell_pixels,
                test_kitty_state(),
            )
            .unwrap();
            let v2_resize_len = resize_payload.len() - KITTY_REPLAY_STATE_ENCODED_LEN;
            assert_eq!(
                decode_host_resize_payload_for_version(&resize_payload[..v2_resize_len], 2)
                    .unwrap(),
                DecodedHostResize {
                    cols: 81,
                    rows: 25,
                    cell_pixels: snapshot.cell_pixels,
                    replay: b"legacy resize".to_vec(),
                    kitty_image_aliases: snapshot.kitty_image_aliases.clone(),
                    kitty_state: KittyReplayState::disabled(),
                }
            );

            let v1_resize_len = resize_payload.len()
                - KITTY_IMAGE_ALIAS_COUNT_LEN
                - snapshot.kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN
                - CELL_PIXEL_SIZE_ENCODED_LEN
                - KITTY_REPLAY_STATE_ENCODED_LEN;
            assert_eq!(
                decode_host_resize_payload_for_version(
                    &resize_payload[..v1_resize_len],
                    LEGACY_PROTOCOL_VERSION,
                )
                .unwrap(),
                DecodedHostResize {
                    cols: 81,
                    rows: 25,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: b"legacy resize".to_vec(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: KittyReplayState::disabled(),
                }
            );
        }

        #[test]
        fn resize_alias_section_preserves_number_history_and_rejects_malformed_data() {
            let alias = KittyImageAlias { image_id: 41, image_number: 77 };
            let valid =
                encode_resize(80, 24, b"replay", &[alias], (9, 18), test_kitty_state()).unwrap();
            assert_eq!(
                decode_host_resize_payload(&valid).unwrap(),
                DecodedHostResize {
                    cols: 80,
                    rows: 24,
                    cell_pixels: (9, 18),
                    replay: b"replay".to_vec(),
                    kitty_image_aliases: vec![alias],
                    kitty_state: test_kitty_state(),
                }
            );

            let alias_offset = 8 + b"replay".len();
            let mut zero_id = valid.clone();
            zero_id[alias_offset + 2..alias_offset + 6].fill(0);
            assert!(decode_host_resize_payload(&zero_id).is_err());

            let duplicate_aliases = [
                KittyImageAlias { image_id: 41, image_number: 77 },
                KittyImageAlias { image_id: 42, image_number: 77 },
            ];
            let duplicate_numbers =
                encode_resize(80, 24, b"replay", &duplicate_aliases, (9, 18), test_kitty_state())
                    .unwrap();
            assert_eq!(
                decode_host_resize_payload(&duplicate_numbers).unwrap(),
                DecodedHostResize {
                    cols: 80,
                    rows: 24,
                    cell_pixels: (9, 18),
                    replay: b"replay".to_vec(),
                    kitty_image_aliases: duplicate_aliases.to_vec(),
                    kitty_state: test_kitty_state(),
                }
            );

            let mut truncated = valid.clone();
            truncated.pop();
            assert!(decode_host_resize_payload(&truncated).is_err());

            let mut invalid_offset = valid.clone();
            let state_offset = alias_offset
                + KITTY_IMAGE_ALIAS_COUNT_LEN
                + KITTY_IMAGE_ALIAS_ENCODED_LEN
                + CELL_PIXEL_SIZE_ENCODED_LEN;
            invalid_offset[state_offset + KITTY_GRAPHICS_LIMITS_ENCODED_LEN
                ..state_offset + KITTY_GRAPHICS_LIMITS_ENCODED_LEN + size_of::<u32>()]
                .copy_from_slice(&7u32.to_le_bytes());
            assert!(decode_host_resize_payload(&invalid_offset).is_err());

            let mut invalid_state = test_kitty_state();
            invalid_state.replay_cursor_offset = 7;
            assert!(encode_resize(80, 24, b"replay", &[alias], (9, 18), invalid_state).is_err());

            let mut trailing = valid;
            trailing.push(0);
            assert!(decode_host_resize_payload(&trailing).is_err());

            let mut excessive = vec![80, 0, 24, 0, 0, 0, 0, 0];
            excessive.extend_from_slice(&((MAX_KITTY_IMAGE_ALIASES + 1) as u16).to_le_bytes());
            assert!(decode_host_resize_payload(&excessive).is_err());
        }

        #[test]
        fn clear_history_ack_preserves_known_not_delivered_failure() {
            let (record_path, record, lease) = record_fixture("clear-history-ack");
            let root = record_path.parent().unwrap().to_path_buf();
            let (client, mut host) = UnixStream::pair().unwrap();
            let control_responses = Arc::new(ControlResponses::new());
            let attachment = HostAttachment {
                record,
                record_path,
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: Vec::new(),
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: false,
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: control_responses.clone(),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            let responder = thread::spawn(move || {
                let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
                assert_eq!(request.kind, MessageKind::ClearHistory);
                let mut response = Frame::new(
                    MessageKind::ClearHistoryAck,
                    vec![crate::terminal_host_protocol::CLEAR_HISTORY_ACK_FAILED],
                );
                response.request_id = request.request_id;
                assert!(control_responses.resolve(&response));
            });

            let failure = attachment.send_clear_history(None).unwrap_err();
            responder.join().unwrap();

            assert_eq!(failure.delivery(), ClearHistoryDelivery::KnownNotDelivered);
            assert_eq!(failure.into_error().to_string(), CLEAR_HISTORY_PRESERVATION_ERROR);
            drop(attachment);
            drop(lease);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn terminate_waits_for_the_authoritative_host_receipt() {
            let (record_path, record, lease) = record_fixture("terminate-ack");
            let root = record_path.parent().unwrap().to_path_buf();
            let (client, mut host) = UnixStream::pair().unwrap();
            let control_responses = Arc::new(ControlResponses::new());
            let mut attachment = HostAttachment {
                record,
                record_path,
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: Vec::new(),
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: true,
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: control_responses.clone(),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            let responder = thread::spawn(move || {
                let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
                assert_eq!(request.kind, MessageKind::Terminate);
                assert_ne!(request.request_id, 0);
                let mut response = Frame::new(MessageKind::TerminateAck, Vec::new());
                response.request_id = request.request_id;
                assert!(control_responses.resolve(&response));
            });

            attachment.terminate().unwrap();
            responder.join().unwrap();

            drop(attachment);
            drop(lease);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn clear_history_control_write_failure_after_header_is_ambiguous() {
            let (record_path, record, lease) =
                record_fixture("clear-history-partial-control-write");
            let root = record_path.parent().unwrap().to_path_buf();
            let (client, mut host) = UnixStream::pair().unwrap();
            let attachment = HostAttachment {
                record,
                record_path,
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: Vec::new(),
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: false,
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: Arc::new(ControlResponses::new()),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            let peer = thread::spawn(move || {
                let mut header = [0; crate::terminal_host_protocol::HEADER_LEN];
                Read::read_exact(&mut host, &mut header).unwrap();
                host.shutdown(std::net::Shutdown::Both).unwrap();
            });

            let failure = attachment
                .send_control_request(
                    MessageKind::ClearHistory,
                    MessageKind::ClearHistoryAck,
                    vec![b'x'; MAX_FRAME_PAYLOAD],
                )
                .unwrap_err();
            peer.join().unwrap();

            assert_eq!(
                failure.delivery(),
                ClearHistoryDelivery::Ambiguous,
                "a delivered frame header means the host may have received the complete request"
            );
            drop(attachment);
            drop(lease);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn clear_history_ack_status_preserves_reason_and_delivery() {
            for (message, expected) in [
                (CLEAR_HISTORY_PRESERVATION_ERROR, CLEAR_HISTORY_ACK_PRESERVATION_FAILED),
                (CLEAR_HISTORY_STREAM_TIMEOUT_ERROR, CLEAR_HISTORY_ACK_STREAM_TIMEOUT),
                (
                    CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR,
                    CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE,
                ),
                (
                    CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
                    CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT,
                ),
                ("other pre-execution failure", CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED),
            ] {
                assert_eq!(
                    clear_history_ack_status(Err(ClearHistoryFailure::known_not_delivered(
                        anyhow::anyhow!(message)
                    ))),
                    expected
                );
            }
            assert_eq!(
                clear_history_ack_status(Err(ClearHistoryFailure::ambiguous(anyhow::anyhow!(
                    "partial PTY write"
                )))),
                CLEAR_HISTORY_ACK_AMBIGUOUS
            );
        }

        #[test]
        fn process_nonce_proves_stale_record_even_if_pid_is_live_and_reused() {
            let (record_path, record, lease) = record_fixture("liveness");
            assert_eq!(
                terminal_host_record_liveness(&record_path, &record).unwrap(),
                TerminalHostLiveness::Live
            );

            // The recorded PID is this still-running test process. Releasing
            // the process-start nonce nevertheless proves that the exact
            // recorded host lifetime ended; PID existence cannot mask it.
            drop(lease);
            assert!(!process_definitely_absent(record.host_pid));
            assert_eq!(
                terminal_host_record_liveness(&record_path, &record).unwrap(),
                TerminalHostLiveness::Dead
            );
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            assert!(!record_path.exists());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn launch_publication_reservation_blocks_reset_lock_until_released() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-publication-reservation-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let reservation = reserve_terminal_host_publication(&root).unwrap();

            let error = match acquire_terminal_host_reset_lock(&root) {
                Ok(_) => panic!("reset lock was not blocked by publication reservation"),
                Err(error) => error,
            };
            assert!(error.to_string().contains("live or unverified hosts"), "{error:#}");

            drop(reservation);
            let reset_lock = acquire_terminal_host_reset_lock(&root).unwrap();
            assert!(reset_lock.is_some());
            drop(reset_lock);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn reset_lock_prepares_missing_publication_lock() {
            use std::os::fd::AsRawFd;
            use std::os::unix::fs::OpenOptionsExt;

            let root = std::env::temp_dir().join(format!(
                "cmux-host-reset-prepares-publication-lock-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            assert!(!terminal_host_publication_lock_path(&root).exists());

            let reset_lock = acquire_terminal_host_reset_lock(&root).unwrap();

            assert!(reset_lock.is_some());
            let publication_lock = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
                .open(terminal_host_publication_lock_path(&root))
                .unwrap();
            // SAFETY: flock only observes the advisory lock on this valid test descriptor.
            assert_ne!(
                unsafe { libc::flock(publication_lock.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) },
                0,
                "publication reservation should be blocked while reset holds the lock"
            );
            drop(reset_lock);
            // SAFETY: flock only observes the advisory lock on this valid test descriptor.
            assert_eq!(
                unsafe { libc::flock(publication_lock.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) },
                0
            );
            // SAFETY: flock only changes the advisory lock on this valid test descriptor.
            let _ = unsafe { libc::flock(publication_lock.as_raw_fd(), libc::LOCK_UN) };
            drop(publication_lock);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn dropping_liveness_lease_releases_inherited_descriptor_lock() {
            let (record_path, record, lease) = record_fixture("inherited-liveness-fd");
            let inherited = lease.file.try_clone().unwrap();

            drop(lease);
            assert_eq!(
                terminal_host_record_liveness(&record_path, &record).unwrap(),
                TerminalHostLiveness::Dead,
                "the lease owner must explicitly unlock before an inherited descriptor closes"
            );

            drop(inherited);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn record_loader_rejects_noncanonical_filenames_and_identity_spellings() {
            let (record_path, record, lease) = record_fixture("canonical");
            let root = record_path.parent().unwrap();
            fs::write(root.join("duplicate.json"), serde_json::to_vec(&record).unwrap()).unwrap();
            let mut uppercase = record.clone();
            uppercase.host_start_nonce.make_ascii_uppercase();
            fs::write(
                root.join(format!("{}.json", TerminalId::random().unwrap().to_hex())),
                serde_json::to_vec(&uppercase).unwrap(),
            )
            .unwrap();

            let loaded = load_terminal_host_records(root).unwrap();
            assert_eq!(loaded, vec![(record_path.clone(), record.clone())]);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn exit_sidecar_round_trips_and_requires_exact_acknowledgement() {
            let (record_path, record, lease) = record_fixture("exit-sidecar");
            let root = record_path.parent().unwrap();
            let exit_record = TerminalHostExitRecord::new(
                &TerminalHostIdentity {
                    terminal_id: record.terminal_id.clone(),
                    incarnation: record.incarnation.clone(),
                },
                TerminalExit {
                    outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
                    exited_at_ms: 1_234_567,
                },
            );
            let exit_path = record_path.with_extension("exit");
            write_exit_record(&exit_path, &exit_record).unwrap();
            assert_eq!(
                load_terminal_host_exit_records(root).unwrap(),
                vec![(exit_path.clone(), exit_record.clone())]
            );
            assert_eq!(
                terminal_host_exit_record(&record_path).unwrap(),
                Some((exit_path.clone(), exit_record.clone()))
            );

            let mut mismatch = exit_record.clone();
            mismatch.exit.exited_at_ms += 1;
            assert!(!acknowledge_terminal_host_exit_record(&exit_path, &mismatch).unwrap());
            assert!(exit_path.exists(), "mismatched ack must retain restart evidence");
            assert!(acknowledge_terminal_host_exit_record(&exit_path, &exit_record).unwrap());
            assert!(!exit_path.exists());
            assert!(
                !acknowledge_terminal_host_exit_record(&exit_path, &exit_record).unwrap(),
                "repeated exact ack is an idempotent no-op"
            );

            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn exit_sidecar_publication_never_clobbers_a_concurrent_outcome() {
            let (record_path, record, lease) = record_fixture("exit-sidecar-race");
            let root = record_path.parent().unwrap().to_path_buf();
            let exit_path = record_path.with_extension("exit");
            let identity = TerminalHostIdentity {
                terminal_id: record.terminal_id.clone(),
                incarnation: record.incarnation.clone(),
            };
            let first = TerminalHostExitRecord::new(
                &identity,
                TerminalExit {
                    outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
                    exited_at_ms: 1_234_567,
                },
            );
            let second = TerminalHostExitRecord::new(
                &identity,
                TerminalExit {
                    outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                        signal: libc::SIGTERM,
                        core_dumped: false,
                    },
                    exited_at_ms: 1_234_568,
                },
            );
            let barrier = Arc::new(std::sync::Barrier::new(3));
            let publishers = [first.clone(), second.clone()]
                .into_iter()
                .map(|candidate| {
                    let barrier = barrier.clone();
                    let exit_path = exit_path.clone();
                    thread::spawn(move || {
                        barrier.wait();
                        write_exit_record(&exit_path, &candidate)
                    })
                })
                .collect::<Vec<_>>();
            barrier.wait();
            let results = publishers
                .into_iter()
                .map(|publisher| publisher.join().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
            let stored: TerminalHostExitRecord =
                serde_json::from_slice(&fs::read(&exit_path).unwrap()).unwrap();
            assert!(stored == first || stored == second);
            validate_terminal_host_exit_record(&exit_path, &stored).unwrap();

            let mut unknown_field = serde_json::to_value(&stored).unwrap();
            unknown_field["unexpected"] = serde_json::json!(true);
            assert!(
                serde_json::from_value::<TerminalHostExitRecord>(unknown_field).is_err(),
                "exit sidecars must reject fields outside the versioned schema"
            );

            assert!(acknowledge_terminal_host_exit_record(&exit_path, &stored).unwrap());
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn legacy_record_is_adoptable_shape_but_never_unsafely_reaped() {
            let (v2_path, v2, lease) = record_fixture("legacy");
            let root = v2_path.parent().unwrap();
            let terminal_id = TerminalId::random().unwrap().to_hex();
            let mut legacy = v2.clone();
            legacy.record_version = 1;
            legacy.terminal_id = terminal_id.clone();
            legacy.endpoint =
                format!("/tmp/cmux-th-{}/{terminal_id}.sock", fs::metadata(root).unwrap().uid());
            legacy.host_pid = 0;
            legacy.host_start_nonce.clear();
            legacy.supports_set_defaults = false;
            legacy.supports_clear_history = false;
            legacy.supports_terminate_ack = false;
            let legacy_path = legacy.record_path(root);
            write_record(&legacy_path, &legacy).unwrap();

            validate_terminal_host_record(&legacy_path, &legacy).unwrap();
            assert_eq!(
                terminal_host_record_liveness(&legacy_path, &legacy).unwrap(),
                TerminalHostLiveness::Indeterminate
            );
            assert!(
                load_terminal_host_records(root)
                    .unwrap()
                    .iter()
                    .any(|(_, record)| record.terminal_id == terminal_id)
            );
            assert!(!remove_stale_terminal_host_record(&legacy_path, &legacy).unwrap());

            fs::remove_file(&legacy_path).unwrap();
            drop(lease);
            assert!(remove_stale_terminal_host_record(&v2_path, &v2).unwrap());
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn geometry_is_bounded_and_failed_apply_rolls_back_viewer_set() {
            assert_eq!(normalize_terminal_geometry(0, 0).unwrap(), (1, 1));
            assert_eq!(normalize_terminal_geometry(u16::MAX, 1).unwrap(), (10_000, 1));
            assert!(normalize_terminal_geometry(10_000, 10_000).is_err());

            let viewers = Mutex::new(HashMap::from([(1, (80, 24))]));
            let error = mutate_viewer_sizes(
                &viewers,
                |sizes| {
                    sizes.insert(2, (70, 20));
                },
                |_| anyhow::bail!("injected PTY resize failure"),
            )
            .unwrap_err();
            assert!(error.to_string().contains("injected PTY"));
            assert_eq!(*viewers.lock().unwrap(), HashMap::from([(1, (80, 24))]));
        }

        #[test]
        fn stalled_host_handshake_is_time_bounded() {
            let (record_path, record, lease) = record_fixture("handshake-timeout");
            let endpoint = PathBuf::from(&record.endpoint);
            prepare_private_dir(endpoint.parent().unwrap()).unwrap();
            let _ = fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint).unwrap();
            let connect_record = record.clone();
            let connect_record_path = record_path.clone();
            let (result_sender, result_receiver) = std::sync::mpsc::channel();
            let connector = thread::spawn(move || {
                result_sender
                    .send(
                        connect_record_with_timeout(
                            connect_record,
                            connect_record_path,
                            Duration::from_millis(30),
                        )
                        .is_err(),
                    )
                    .unwrap();
            });

            let (_stalled_stream, _) = listener.accept().unwrap();
            assert!(result_receiver.recv_timeout(Duration::from_secs(1)).unwrap());
            connector.join().unwrap();
            let _ = fs::remove_file(endpoint);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn termination_adoption_does_not_probe_legacy_protocols_for_receipt_hosts() {
            let (record_path, record, lease) = record_fixture("terminate-current-protocol");
            assert!(record.supports_terminate_ack);
            let endpoint = PathBuf::from(&record.endpoint);
            prepare_private_dir(endpoint.parent().unwrap()).unwrap();
            let _ = fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint).unwrap();
            listener.set_nonblocking(true).unwrap();
            let server = thread::spawn(move || {
                let deadline = Instant::now() + Duration::from_millis(500);
                let mut hellos = Vec::new();
                while Instant::now() < deadline {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream.set_nonblocking(false).unwrap();
                            stream.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
                            if let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) {
                                hellos.push((frame.version, frame.flags));
                            }
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(2));
                        }
                        Err(error) => panic!("accept termination probe: {error}"),
                    }
                }
                hellos
            });

            assert!(
                connect_current_record_with_timeout(
                    record.clone(),
                    record_path.clone(),
                    Duration::from_millis(30),
                )
                .is_err()
            );
            let hellos = server.join().unwrap();
            assert_eq!(
                hellos,
                vec![(PROTOCOL_VERSION, FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS)]
            );

            let _ = fs::remove_file(endpoint);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn timed_out_cell_pixel_ack_reconciles_when_the_response_arrives_late() {
            let (record_path, record, lease) = record_fixture("late-cell-pixel-ack");
            let (client, mut host) = UnixStream::pair().unwrap();
            let control_responses = Arc::new(ControlResponses::new());
            let (reconciled_tx, reconciled_rx) = std::sync::mpsc::channel();
            control_responses.set_deferred_cell_pixel_handler(Arc::new(
                move |request_id, expected, frame| {
                    reconciled_tx.send((request_id, expected, frame)).unwrap();
                },
            ));
            let attachment = HostAttachment {
                record: record.clone(),
                record_path: record_path.clone(),
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: vec!["/bin/cat".into()],
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: false,
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: control_responses.clone(),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            let (release_ack_tx, release_ack_rx) = std::sync::mpsc::channel();
            let resolver = {
                let control_responses = control_responses.clone();
                thread::spawn(move || {
                    let request =
                        read_required_frame(&mut host, "cell pixel size request").unwrap();
                    assert_eq!(request.kind, MessageKind::SetCellPixelSize);
                    release_ack_rx.recv().unwrap();
                    let mut ack =
                        Frame::new(MessageKind::CellPixelSizeAck, request.payload.clone());
                    ack.request_id = request.request_id;
                    control_responses.resolve(&ack);
                })
            };

            let error = attachment
                .send_cell_pixel_size_until(9, 18, Instant::now() + Duration::from_millis(10))
                .unwrap_err();
            assert!(error.is::<DeferredCellPixelAck>());
            assert!(
                error.to_string().contains("late response will reconcile the mirror"),
                "{error:#}"
            );
            release_ack_tx.send(()).unwrap();
            let (request_id, expected, resolution) =
                reconciled_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(request_id, 2);
            assert_eq!(expected, (9, 18));
            let DeferredCellPixelResolution::Response(ack) = resolution else {
                panic!("late acknowledgement was reported as a disconnect");
            };
            assert_eq!(ack.payload, vec![9, 0, 18, 0]);
            assert_eq!(control_responses.latest_cell_pixel_ack(), 2);

            resolver.join().unwrap();
            drop(attachment);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn disconnect_settles_deferred_cell_pixel_waiters() {
            let control_responses = ControlResponses::new();
            let (sender, _receiver) = sync_channel(1);
            control_responses.waiters.lock().unwrap().insert(
                7,
                ControlResponseWaiter::Blocking { kind: MessageKind::CellPixelSizeAck, sender },
            );
            assert!(control_responses.defer_cell_pixel(7, (9, 18)));
            let (settled_tx, settled_rx) = std::sync::mpsc::channel();
            control_responses.set_deferred_cell_pixel_handler(Arc::new(
                move |request_id, expected, _frame| {
                    settled_tx.send((request_id, expected)).unwrap();
                },
            ));

            control_responses.fail_all();

            assert_eq!(settled_rx.recv_timeout(Duration::from_secs(1)).unwrap(), (7, (9, 18)));
        }

        #[test]
        fn detach_fence_queues_prior_source_output_and_removes_the_client() {
            let host = test_host_shared();
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            host.smart.taps.lock().unwrap().insert(7, target.clone());

            let before = host.smart.publish(Frame::new(MessageKind::Output, b"before".to_vec()));
            assert!(host.fence_client_detach(7, 42, &target));
            host.smart.publish(Frame::new(MessageKind::Output, b"after".to_vec()));

            let output = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(output.kind, MessageKind::Output);
            assert_eq!(output.sequence, before);
            assert_eq!(output.payload, b"before");
            let receipt = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(receipt.kind, MessageKind::DetachAck);
            assert_eq!(receipt.request_id, 42);
            assert!(target_rx.try_recv().is_err());
        }

        #[test]
        fn detach_fence_reports_a_delayed_receipt_after_output_as_a_failure() {
            let (record_path, record, lease) = record_fixture("detach-delayed-ack");
            let root = record_path.parent().unwrap().to_path_buf();
            let (client, mut host) = UnixStream::pair().unwrap();
            let control_responses = Arc::new(ControlResponses::new());
            let attachment = HostAttachment {
                record,
                record_path,
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: Vec::new(),
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: true,
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: control_responses.clone(),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            let (output_queued, output_seen) = sync_channel(1);
            let (release_ack, ack_release) = sync_channel(1);
            let responder = thread::spawn(move || {
                let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
                assert_eq!(request.kind, MessageKind::Detach);
                let mut output = Frame::new(MessageKind::Output, b"before-timeout".to_vec());
                output.sequence = 1;
                write_frame(&mut host, &output).unwrap();
                output_queued.send(()).unwrap();
                ack_release.recv().unwrap();
                let mut response = Frame::new(MessageKind::DetachAck, Vec::new());
                response.request_id = request.request_id;
                assert!(!control_responses.resolve(&response));
            });

            let deadline = Instant::now() + Duration::from_millis(100);
            let result = attachment.detach_for_daemon_shutdown_until(deadline);
            output_seen.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(result.unwrap_err().to_string().contains("timed out"));
            release_ack.send(()).unwrap();
            responder.join().unwrap();

            drop(attachment);
            drop(lease);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn cell_pixel_commit_is_broadcast_to_live_renderer_taps_before_ack() {
            let host = test_host_shared();
            let (renderer_socket, _renderer_peer) = UnixStream::pair().unwrap();
            let (renderer_tx, renderer_rx) = mpsc_channel();
            host.taps
                .lock()
                .unwrap()
                .insert(1, HostTap::new(renderer_tx, Arc::new(renderer_socket), usize::MAX));
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            host.smart.taps.lock().unwrap().insert(2, target.clone());

            assert!(host.set_cell_pixel_size(9, 18, 42, &target).unwrap());

            let resized = renderer_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(resized.kind, MessageKind::Resized);
            assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
            assert_eq!(decode_host_resize_payload(&resized.payload).unwrap().cell_pixels, (9, 18));
            let colors = renderer_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(colors.kind, MessageKind::Colors);
            assert!(colors.sequence > resized.sequence);

            let smart_resize = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(smart_resize.kind, MessageKind::Resized);
            assert_eq!(smart_resize.payload, [80, 0, 24, 0, 9, 0, 18, 0]);
            assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), smart_resize.sequence);
            let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(ack.kind, MessageKind::CellPixelSizeAck);
            assert_eq!(ack.request_id, 42);
        }

        #[test]
        fn kitty_limit_commit_replaces_live_mirrors_before_ack() {
            let host = test_host_shared();
            host.term
                .lock()
                .unwrap()
                .vt_write(b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;AAAA\x1b\\");
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            host.taps.lock().unwrap().insert(1, target.clone());
            let (smart_socket, _smart_peer) = UnixStream::pair().unwrap();
            let (smart_tx, smart_rx) = mpsc_channel();
            host.smart
                .taps
                .lock()
                .unwrap()
                .insert(2, HostTap::new(smart_tx, Arc::new(smart_socket), usize::MAX));
            let limits = KittyGraphicsLimits::disabled();

            assert!(host.set_kitty_graphics_limits(limits, 43, &target).unwrap());

            let resized = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(resized.kind, MessageKind::Resized);
            assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
            let decoded = decode_host_resize_payload(&resized.payload).unwrap();
            assert_eq!(decoded.kitty_state.limits, limits);
            let colors = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(colors.kind, MessageKind::Colors);
            assert!(colors.sequence > resized.sequence);
            let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(ack.kind, MessageKind::KittyGraphicsLimitsAck);
            assert_eq!(ack.request_id, 43);
            let mut decoder = PayloadDecoder::new(&ack.payload);
            assert_eq!(decode_kitty_graphics_limits(&mut decoder).unwrap(), limits);
            decoder.finish().unwrap();

            let smart_resync = smart_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(smart_resync.kind, MessageKind::ResyncRequired);
            assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), smart_resync.sequence);

            let mut mirror =
                Terminal::new(decoded.cols, decoded.rows, 0, Callbacks::default()).unwrap();
            mirror
                .apply_vt_replay(&ghostty_vt::VtReplay {
                    bytes: decoded.replay,
                    kitty_image_aliases: decoded.kitty_image_aliases,
                    kitty_state: decoded.kitty_state,
                })
                .unwrap();
            assert!(mirror.kitty_graphics_snapshot().unwrap().images.is_empty());
            assert_eq!(mirror.kitty_graphics_limits().unwrap(), limits);
        }

        #[test]
        fn adoption_quota_reconfiguration_finishes_before_snapshot_use() {
            let (record_path, record, lease) = record_fixture("adoption-kitty-quota");
            let root = record_path.parent().unwrap().to_path_buf();
            let (client, mut host) = UnixStream::pair().unwrap();
            let reader = client.try_clone().unwrap();
            let mut stale_state = test_kitty_state();
            stale_state.limits = KittyGraphicsLimits {
                image_bytes: 8_000,
                inflight_bytes: 8_000,
                images: 80,
                placements: 160,
            };
            let ceiling = KittyGraphicsLimits {
                image_bytes: 4_000,
                inflight_bytes: 4_000,
                images: 40,
                placements: 80,
            };
            let mut attachment = HostAttachment {
                record,
                record_path,
                snapshot: HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: Vec::new(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: stale_state,
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: Vec::new(),
                    cwd: None,
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: false,
                reader: Some(reader),
                writer: Arc::new(Mutex::new(client)),
                control_responses: Arc::new(ControlResponses::new()),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
            };
            let responder = thread::spawn(move || {
                let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
                assert_eq!(request.kind, MessageKind::SetKittyGraphicsLimits);
                let mut decoder = PayloadDecoder::new(&request.payload);
                assert_eq!(decode_kitty_graphics_limits(&mut decoder).unwrap(), ceiling);
                decoder.finish().unwrap();

                let mut fresh_state = test_kitty_state();
                fresh_state.limits = ceiling;
                let mut resized = Frame::new(
                    MessageKind::Resized,
                    encode_resize(80, 24, &[], &[], DEFAULT_CELL_PIXELS, fresh_state).unwrap(),
                );
                resized.version = PROTOCOL_VERSION;
                resized.flags = FLAG_COLORS_FOLLOW;
                resized.sequence = 1;
                write_frame(&mut host, &resized).unwrap();
                let mut colors = Frame::new(
                    MessageKind::Colors,
                    encode_terminal_color_overrides(&TerminalColorOverrides {
                        cursor_visual: Some((CursorShape::Block, false)),
                        ..TerminalColorOverrides::default()
                    }),
                );
                colors.version = PROTOCOL_VERSION;
                colors.sequence = 2;
                write_frame(&mut host, &colors).unwrap();

                let mut payload = Vec::new();
                encode_kitty_graphics_limits(&mut payload, ceiling).unwrap();
                let mut ack = Frame::new(MessageKind::KittyGraphicsLimitsAck, payload);
                ack.version = PROTOCOL_VERSION;
                ack.request_id = request.request_id;
                write_frame(&mut host, &ack).unwrap();
                assert!(read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().is_none());
            });

            attachment.reconfigure_kitty_graphics_for_adoption(ceiling).unwrap();
            attachment.disconnect();
            responder.join().unwrap();

            drop(attachment);
            drop(lease);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn upgraded_daemon_falls_back_to_a_live_protocol_one_host() {
            let (record_path, record, lease) = record_fixture("protocol-one-adoption");
            let endpoint = PathBuf::from(&record.endpoint);
            prepare_private_dir(endpoint.parent().unwrap()).unwrap();
            let _ = fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint).unwrap();
            let terminal_id =
                TerminalId::from_bytes(decode_hex_array(&record.terminal_id).unwrap());
            let incarnation =
                HostIncarnation::from_bytes(decode_hex_array(&record.incarnation).unwrap());
            let expected_replay = b"protocol-one-live-state".to_vec();
            let host_replay = expected_replay.clone();
            let fake_host = thread::spawn(move || {
                let (mut smart, _) = listener.accept().unwrap();
                let smart_hello = read_required_frame(&mut smart, "smart owner hello").unwrap();
                assert_eq!(smart_hello.kind, MessageKind::ClientHello);
                assert_eq!(smart_hello.version, PROTOCOL_VERSION);
                assert_eq!(smart_hello.flags & FLAG_SMART_RENDERER, FLAG_SMART_RENDERER);
                drop(smart);

                for rejected_version in ((LEGACY_PROTOCOL_VERSION + 1)..=PROTOCOL_VERSION).rev() {
                    let (mut rejected, _) = listener.accept().unwrap();
                    let hello = read_required_frame(&mut rejected, "newer-version hello").unwrap();
                    assert_eq!(hello.kind, MessageKind::ClientHello);
                    assert_eq!(hello.version, rejected_version);
                }

                let (mut legacy, _) = listener.accept().unwrap();
                let legacy_hello = read_required_frame(&mut legacy, "legacy hello").unwrap();
                assert_eq!(legacy_hello.kind, MessageKind::ClientHello);
                assert_eq!(legacy_hello.version, LEGACY_PROTOCOL_VERSION);
                let decoded = ClientHello::decode(&legacy_hello.payload).unwrap();
                assert_eq!(
                    (decoded.min_version, decoded.max_version),
                    (LEGACY_PROTOCOL_VERSION, LEGACY_PROTOCOL_VERSION)
                );

                let response = HostHello {
                    selected_version: LEGACY_PROTOCOL_VERSION,
                    granted_rights: CapabilityRights::ADMIN,
                    terminal_id,
                    incarnation,
                };
                let mut hello = Frame::new(MessageKind::HostHello, response.encode());
                hello.version = LEGACY_PROTOCOL_VERSION;
                hello.request_id = legacy_hello.request_id;
                write_frame(&mut legacy, &hello).unwrap();

                let snapshot = HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: host_replay,
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: Some(42),
                    command: vec!["/bin/cat".into()],
                    cwd: Some("/tmp".into()),
                };
                let mut payload = encode_snapshot(&snapshot).unwrap();
                payload.truncate(
                    payload.len()
                        - KITTY_IMAGE_ALIAS_COUNT_LEN
                        - CELL_PIXEL_SIZE_ENCODED_LEN
                        - KITTY_REPLAY_STATE_ENCODED_LEN,
                );
                let mut frame = Frame::new(MessageKind::Snapshot, payload);
                frame.version = LEGACY_PROTOCOL_VERSION;
                write_frame(&mut legacy, &frame).unwrap();

                let colors = TerminalColorOverrides {
                    cursor_visual: Some((CursorShape::Block, true)),
                    ..TerminalColorOverrides::default()
                };
                let mut frame =
                    Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors));
                frame.version = LEGACY_PROTOCOL_VERSION;
                write_frame(&mut legacy, &frame).unwrap();

                let release = read_required_frame(&mut legacy, "legacy viewer release").unwrap();
                assert_eq!(release.kind, MessageKind::ReleaseViewer);
                assert_eq!(release.version, LEGACY_PROTOCOL_VERSION);
            });

            let attachment = connect_record_with_timeout(
                record.clone(),
                record_path.clone(),
                Duration::from_secs(1),
            )
            .unwrap();
            assert_eq!(attachment.protocol_version(), LEGACY_PROTOCOL_VERSION);
            assert_eq!(attachment.snapshot.replay, expected_replay);
            assert!(attachment.snapshot.kitty_image_aliases.is_empty());
            assert!(!attachment.send_cell_pixel_size(9, 18).unwrap());
            drop(attachment);
            fake_host.join().unwrap();

            let _ = fs::remove_file(endpoint);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn smart_owner_negotiation_falls_back_to_a_live_legacy_host() {
            let (record_path, record, lease) = record_fixture("legacy-fallback");
            let endpoint = PathBuf::from(&record.endpoint);
            prepare_private_dir(endpoint.parent().unwrap()).unwrap();
            let _ = fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint).unwrap();
            listener.set_nonblocking(true).unwrap();
            let server_record = record.clone();
            let server = thread::spawn(move || -> anyhow::Result<bool> {
                let accept_before = |deadline: Instant| -> anyhow::Result<Option<UnixStream>> {
                    loop {
                        match listener.accept() {
                            Ok((stream, _)) => {
                                stream.set_nonblocking(false)?;
                                return Ok(Some(stream));
                            }
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                                if Instant::now() >= deadline {
                                    return Ok(None);
                                }
                                thread::sleep(Duration::from_millis(2));
                            }
                            Err(error) => return Err(error.into()),
                        }
                    }
                };

                let Some(mut smart) = accept_before(Instant::now() + Duration::from_secs(1))?
                else {
                    return Ok(false);
                };
                smart.set_read_timeout(Some(Duration::from_secs(1)))?;
                let smart_hello = read_required_frame(&mut smart, "smart owner hello")?;
                if smart_hello.flags & FLAG_SMART_RENDERER == 0 {
                    return Ok(false);
                }
                drop(smart);

                let Some(mut legacy) = accept_before(Instant::now() + Duration::from_secs(1))?
                else {
                    return Ok(false);
                };
                legacy.set_read_timeout(Some(Duration::from_secs(1)))?;
                let hello_frame = read_required_frame(&mut legacy, "legacy owner hello")?;
                if hello_frame.flags != 0 || hello_frame.version != PROTOCOL_VERSION {
                    return Ok(false);
                }
                let hello = ClientHello::decode(&hello_frame.payload)?;
                let incarnation =
                    HostIncarnation::from_bytes(decode_hex_array(&server_record.incarnation)?);
                let response = HostHello {
                    selected_version: PROTOCOL_VERSION,
                    granted_rights: CapabilityRights::ADMIN,
                    terminal_id: hello.terminal_id,
                    incarnation,
                };
                let mut host_hello = Frame::new(MessageKind::HostHello, response.encode());
                host_hello.request_id = hello_frame.request_id;
                write_frame(&mut legacy, &host_hello)?;

                let snapshot = HostSnapshot {
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    replay: b"legacy host survived".to_vec(),
                    kitty_image_aliases: Vec::new(),
                    kitty_state: test_kitty_state(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: None,
                    command: vec!["/bin/sh".into()],
                    cwd: None,
                };
                let mut snapshot_frame =
                    Frame::new(MessageKind::Snapshot, encode_snapshot(&snapshot)?);
                snapshot_frame.sequence = 17;
                write_frame(&mut legacy, &snapshot_frame)?;
                let colors_state = TerminalColorOverrides {
                    cursor_visual: Some((CursorShape::Block, false)),
                    ..Default::default()
                };
                let mut colors =
                    Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors_state));
                colors.sequence = snapshot_frame.sequence;
                write_frame(&mut legacy, &colors)?;

                let release = read_required_frame(&mut legacy, "legacy viewer release")?;
                Ok(release.kind == MessageKind::ReleaseViewer)
            });

            let result = connect_record_with_timeout(
                record.clone(),
                record_path.clone(),
                Duration::from_secs(1),
            );
            let saw_legacy = server.join().unwrap().unwrap();
            let attachment = result.expect("legacy fallback did not adopt the live shell");
            assert!(saw_legacy);
            assert!(!attachment.is_smart_renderer());
            assert!(!attachment.supports_journal_detach_fence());
            assert_eq!(attachment.snapshot.replay, b"legacy host survived");
            drop(attachment);

            let _ = fs::remove_file(endpoint);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
        }

        #[test]
        fn snapshot_boundary_waits_for_parser_progress_and_times_out() {
            let host = exited_host_fixture();
            let mut term = host.term.lock().unwrap();
            term.vt_write(b"\xce");
            assert!(!term.vt_stream_is_ground());

            let waiter_host = host.clone();
            let (result_sender, result_receiver) = std::sync::mpsc::channel();
            let waiter = thread::spawn(move || {
                let result = waiter_host
                    .terminal_at_snapshot_boundary(Duration::from_secs(1))
                    .and_then(|mut term| term.viewport_text().map_err(anyhow::Error::from));
                result_sender.send(result).unwrap();
            });

            let deadline = Instant::now() + Duration::from_secs(1);
            loop {
                match host.parser_progress.0.try_lock() {
                    Err(TryLockError::WouldBlock) => break,
                    Err(TryLockError::Poisoned(error)) => panic!("{error}"),
                    Ok(guard) => drop(guard),
                }
                assert!(Instant::now() < deadline, "snapshot waiter never inspected the parser");
                thread::yield_now();
            }
            drop(term);

            loop {
                match host.parser_progress.0.try_lock() {
                    Ok(guard) => {
                        drop(guard);
                        break;
                    }
                    Err(TryLockError::WouldBlock) => {}
                    Err(TryLockError::Poisoned(error)) => panic!("{error}"),
                }
                assert!(Instant::now() < deadline, "snapshot waiter never entered its wait");
                thread::yield_now();
            }
            host.term.lock().unwrap().vt_write(b"\xbb");
            host.note_parser_progress();

            assert!(result_receiver.recv().unwrap().unwrap().contains('λ'));
            waiter.join().unwrap();

            let timed_out = exited_host_fixture();
            timed_out.term.lock().unwrap().vt_write(b"\x1b");
            let started = Instant::now();
            let error = match timed_out.terminal_at_snapshot_boundary(Duration::from_millis(20)) {
                Ok(_) => panic!("unterminated VT sequence was admitted for a snapshot"),
                Err(error) => error,
            };
            assert!(error.to_string().contains("safe snapshot boundary"));
            assert!(started.elapsed() < Duration::from_secs(1));
        }

        fn snapshot_boundary_client_hello(host: &HostShared, smart: bool) -> anyhow::Result<Frame> {
            let (role, rights, token) = if smart {
                (
                    ClientRole::Renderer,
                    CapabilityRights::RENDERER,
                    host.capabilities.mint(
                        host.terminal_id,
                        CapabilityRights::RENDERER,
                        Duration::from_secs(1),
                    )?,
                )
            } else {
                (ClientRole::Admin, CapabilityRights::ADMIN, host.owner_token)
            };
            let mut hello = ClientHello {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                role,
                requested_rights: rights,
                terminal_id: host.terminal_id,
                token,
            }
            .into_frame(1);
            if smart {
                hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
            }
            Ok(hello)
        }

        #[test]
        fn snapshot_boundary_protects_legacy_and_smart_bootstraps() {
            for smart in [false, true] {
                let host = exited_host_fixture();
                host.term.lock().unwrap().vt_write(b"before \xce");
                let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
                client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                let server_host = host.clone();
                let server = thread::spawn(move || {
                    serve_client_with_snapshot_timeout(
                        server_host,
                        server_stream,
                        Duration::from_secs(1),
                    )
                });

                write_frame(
                    &mut client_stream,
                    &snapshot_boundary_client_hello(&host, smart).unwrap(),
                )
                .unwrap();
                let hello = read_required_frame(&mut client_stream, "host hello").unwrap();
                assert_eq!(hello.kind, MessageKind::HostHello);
                assert_eq!(hello.flags & FLAG_SMART_RENDERER != 0, smart);

                host.term.lock().unwrap().vt_write(b"\xbb after");
                host.note_parser_progress();

                let snapshot = read_required_frame(&mut client_stream, "snapshot").unwrap();
                assert_eq!(snapshot.kind, MessageKind::Snapshot);
                let snapshot = decode_host_snapshot_payload(&snapshot.payload).unwrap();
                let colors = read_required_frame(&mut client_stream, "colors").unwrap();
                assert_eq!(colors.kind, MessageKind::Colors);
                if smart {
                    assert_eq!(
                        read_required_frame(&mut client_stream, "ready").unwrap().kind,
                        MessageKind::Ready
                    );
                }

                let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
                mirror.vt_write(&snapshot.replay);
                let text = mirror.viewport_text().unwrap();
                assert!(text.contains("before λ after"), "smart={smart} snapshot={text:?}");
                assert!(!text.contains('\u{fffd}'), "smart={smart} snapshot={text:?}");

                if smart {
                    let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
                    host.smart.mark_applied(cursor);
                } else {
                    host.broadcast(MessageKind::Exit, Vec::new());
                }
                assert_eq!(
                    read_required_frame(&mut client_stream, "exit").unwrap().kind,
                    MessageKind::Exit
                );
                let _ = client_stream.shutdown(std::net::Shutdown::Both);
                server.join().unwrap().unwrap();
            }
        }

        #[test]
        fn unterminated_snapshot_boundary_resyncs_legacy_and_smart_clients() {
            for smart in [false, true] {
                let host = exited_host_fixture();
                host.term.lock().unwrap().vt_write(b"\x1b]0;unterminated");
                let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
                client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                let server_host = host.clone();
                let server = thread::spawn(move || {
                    serve_client_with_snapshot_timeout(
                        server_host,
                        server_stream,
                        Duration::from_millis(20),
                    )
                });

                write_frame(
                    &mut client_stream,
                    &snapshot_boundary_client_hello(&host, smart).unwrap(),
                )
                .unwrap();
                assert_eq!(
                    read_required_frame(&mut client_stream, "host hello").unwrap().kind,
                    MessageKind::HostHello
                );
                let resync = read_required_frame(&mut client_stream, "resync").unwrap();
                assert_eq!(resync.kind, MessageKind::ResyncRequired);
                assert!(resync.payload.is_empty());
                assert!(
                    server
                        .join()
                        .unwrap()
                        .unwrap_err()
                        .to_string()
                        .contains("safe snapshot boundary")
                );
            }
        }

        #[test]
        fn poisoned_snapshot_geometry_resyncs_and_fails_closed() {
            for poisoned in ["viewer_sizes", "size", "cell_pixels"] {
                let host = exited_host_fixture();
                let poison_host = host.clone();
                let poisoner = thread::spawn(move || match poisoned {
                    "viewer_sizes" => {
                        let _guard = poison_host.viewer_sizes.lock().unwrap();
                        panic!("poison viewer sizes");
                    }
                    "size" => {
                        let _guard = poison_host.size.lock().unwrap();
                        panic!("poison size");
                    }
                    "cell_pixels" => {
                        let _guard = poison_host.cell_pixels.lock().unwrap();
                        panic!("poison cell pixels");
                    }
                    _ => unreachable!(),
                });
                assert!(poisoner.join().is_err());

                let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
                client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                let server_host = host.clone();
                let server = thread::spawn(move || {
                    serve_client_with_snapshot_timeout(
                        server_host,
                        server_stream,
                        Duration::from_millis(20),
                    )
                });

                write_frame(
                    &mut client_stream,
                    &snapshot_boundary_client_hello(&host, false).unwrap(),
                )
                .unwrap();
                assert_eq!(
                    read_required_frame(&mut client_stream, "host hello").unwrap().kind,
                    MessageKind::HostHello
                );
                assert_eq!(
                    read_required_frame(&mut client_stream, "resync").unwrap().kind,
                    MessageKind::ResyncRequired
                );
                let error = server.join().unwrap().unwrap_err();
                assert!(error.to_string().contains("poisoned"), "{poisoned} returned {error:#}");
            }
        }

        #[test]
        fn legacy_resize_resyncs_instead_of_replaying_partial_utf8() {
            let host = exited_host_fixture();
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            host.taps.lock().unwrap().insert(
                1,
                HostTap {
                    sender,
                    queued_bytes: Arc::new(AtomicUsize::new(0)),
                    queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                    shutdown: Arc::new(host_socket),
                    max_queued_bytes: usize::MAX,
                },
            );

            // A replay cannot serialize the decoder's pending 0xce byte. If
            // the later 0xbb is delivered after that replay, a fresh mirror
            // decodes it as U+FFFD instead of completing U+03BB.
            host.term.lock().unwrap().vt_write(b"before \xce");
            assert!(!host.term.lock().unwrap().vt_stream_is_ground());

            host.apply_parser_resize(100, 30, None, false, None, DEFAULT_CELL_PIXELS)
                .acknowledgement_queued
                .unwrap();

            let frame = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(frame.kind, MessageKind::ResyncRequired);
            assert!(receiver.try_recv().is_err(), "unsafe resize emitted a replay or color pair");
        }

        #[test]
        fn committed_resize_updates_cached_geometry_when_publication_fails() {
            let (host, parser_commands) = exited_host_fixture_with_parser();
            let parser_host = host.clone();
            let parser = thread::spawn(move || {
                let ParserCommand::Resize {
                    cols,
                    rows,
                    cell_pixels,
                    source_cursor,
                    acknowledge_with_replay,
                    targeted_ack,
                    response,
                } = parser_commands.recv().unwrap()
                else {
                    panic!("expected resize command");
                };
                let result = parser_host.apply_parser_resize(
                    cols,
                    rows,
                    source_cursor,
                    acknowledge_with_replay,
                    targeted_ack,
                    cell_pixels,
                );
                response.send(result).unwrap();
            });

            host.fail_next_resize_publication.store(true, Ordering::Release);
            let error = host.apply_viewer_minimum(Some((100, 30)), true, None).unwrap_err();
            assert!(error.to_string().contains("injected terminal resize publication failure"));
            assert_eq!(*host.size.lock().unwrap(), (100, 30));
            let term = host.term.lock().unwrap();
            assert_eq!((term.cols(), term.rows()), (100, 30));
            drop(term);
            assert!(host.apply_viewer_minimum(Some((100, 30)), false, None).unwrap());
            parser.join().unwrap();
        }

        #[test]
        fn admin_owner_can_negotiate_the_smart_renderer_stream() {
            let host = exited_host_fixture();
            let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
            client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let server_host = host.clone();
            let server = thread::spawn(move || serve_client(server_host, server_stream));

            let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
            hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
            write_frame(&mut client_stream, &hello).unwrap();

            let host_hello = read_required_frame(&mut client_stream, "host hello").unwrap();
            assert_eq!(host_hello.kind, MessageKind::HostHello);
            assert_eq!(host_hello.flags & FLAG_SMART_RENDERER, FLAG_SMART_RENDERER);
            assert_eq!(
                read_required_frame(&mut client_stream, "snapshot").unwrap().kind,
                MessageKind::Snapshot
            );
            assert_eq!(
                read_required_frame(&mut client_stream, "colors").unwrap().kind,
                MessageKind::Colors
            );
            assert_eq!(
                read_required_frame(&mut client_stream, "ready").unwrap().kind,
                MessageKind::Ready
            );

            for (kind, payload) in [
                (MessageKind::Output, vec![0xce]),
                (MessageKind::Resized, vec![100, 0, 30, 0]),
                (MessageKind::Output, vec![0xbb]),
            ] {
                let cursor = host.smart.publish(Frame::new(kind, payload.clone()));
                host.smart.mark_applied(cursor);
                let received = read_required_frame(&mut client_stream, "smart transition").unwrap();
                assert_eq!((received.kind, received.payload), (kind, payload));
            }

            let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
            host.smart.mark_applied(cursor);
            assert_eq!(
                read_required_frame(&mut client_stream, "exit").unwrap().kind,
                MessageKind::Exit
            );
            let _ = client_stream.shutdown(std::net::Shutdown::Both);
            server.join().unwrap().unwrap();
        }

        #[test]
        fn protocol_one_smart_renderer_handshake_is_rejected() {
            let host = exited_host_fixture();
            let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
            client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let server_host = host.clone();
            let server = thread::spawn(move || serve_client(server_host, server_stream));

            let hello = ClientHello {
                min_version: LEGACY_PROTOCOL_VERSION,
                max_version: LEGACY_PROTOCOL_VERSION,
                role: ClientRole::Admin,
                requested_rights: CapabilityRights::ADMIN,
                terminal_id: host.terminal_id,
                token: host.owner_token,
            };
            let mut hello = hello.into_frame(1);
            hello.version = LEGACY_PROTOCOL_VERSION;
            hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
            write_frame(&mut client_stream, &hello).unwrap();

            assert!(read_required_frame(&mut client_stream, "host hello").is_err());
            assert!(server.join().unwrap().is_err());
        }

        #[test]
        fn changing_defaults_forces_smart_renderers_to_a_fresh_snapshot() {
            let (host, parser_receiver) = exited_host_fixture_with_parser();
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            host.smart
                .subscribe(
                    7,
                    HostTap {
                        sender,
                        queued_bytes: Arc::new(AtomicUsize::new(0)),
                        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                        shutdown: Arc::new(host_socket),
                        max_queued_bytes: usize::MAX,
                    },
                )
                .unwrap();

            let defaults =
                DefaultColors { fg: Some(Rgb { r: 1, g: 2, b: 3 }), ..Default::default() };
            let update_host = host.clone();
            let update = thread::spawn(move || update_host.set_default_colors(defaults));

            let resync = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(resync.kind, MessageKind::ResyncRequired);
            assert!(
                host.smart.applied_cursor.load(Ordering::Acquire) < resync.sequence,
                "the snapshot boundary must not advance before the parser applies defaults"
            );
            let command = parser_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            let ParserCommand::SetDefaults { colors, source_cursor, response } = command else {
                panic!("defaults update queued a different parser command");
            };
            assert_eq!(source_cursor, resync.sequence);
            host.apply_parser_defaults(*colors, source_cursor);
            response.send(()).unwrap();
            update.join().unwrap();

            assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), resync.sequence);
            assert_eq!(*host.default_colors.lock().unwrap(), defaults);
        }

        #[test]
        fn repeating_defaults_does_not_resync_smart_renderers() {
            let host = exited_host_fixture();
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            host.smart
                .subscribe(
                    7,
                    HostTap {
                        sender,
                        queued_bytes: Arc::new(AtomicUsize::new(0)),
                        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                        shutdown: Arc::new(host_socket),
                        max_queued_bytes: usize::MAX,
                    },
                )
                .unwrap();

            host.set_default_colors(DefaultColors::default());

            assert!(matches!(
                receiver.recv_timeout(Duration::from_millis(50)),
                Err(RecvTimeoutError::Timeout)
            ));
            assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), 0);
        }

        #[test]
        fn host_tap_byte_overflow_closes_the_client_socket() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, _receiver) = mpsc_channel();
            let one_frame = crate::terminal_host_protocol::HEADER_LEN + 4;
            let tap = HostTap::new(sender, Arc::new(host_socket), one_frame);

            assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1; 4])));
            assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2])));
            let mut byte = [0u8; 1];
            assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
        }

        #[test]
        fn host_tap_snapshot_headroom_does_not_expand_live_output_budget() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, _receiver) = mpsc_channel();
            let tap = HostTap::new(sender, Arc::new(host_socket), MAX_HOST_CLIENT_QUEUED_BYTES);
            let half_output_budget = 4 * 1024 * 1024;

            assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1; half_output_budget],)));
            assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2; half_output_budget],)));
            let mut byte = [0u8; 1];
            assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
        }

        #[test]
        fn host_tap_disconnected_channel_closes_the_client_socket() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, receiver) = mpsc_channel();
            drop(receiver);
            let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);

            assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![1])));
            let mut byte = [0u8; 1];
            assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
        }

        #[test]
        fn smart_attach_replays_source_bytes_ahead_of_parser_boundary_exactly_once() {
            let state = SmartStreamState::new();
            let first = state.publish(Frame::new(MessageKind::Output, b"unparsed".to_vec()));
            assert_eq!(first, 1);
            assert_eq!(state.applied_cursor.load(Ordering::Acquire), 0);

            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };
            let boundary = state.subscribe(7, tap).unwrap();
            assert_eq!(boundary, 0);
            let replayed = receiver.recv().unwrap();
            assert_eq!((replayed.sequence, replayed.payload), (1, b"unparsed".to_vec()));

            state.mark_applied(first);
            state.publish(Frame::new(MessageKind::Output, b"live".to_vec()));
            let live = receiver.recv().unwrap();
            assert_eq!((live.sequence, live.payload), (2, b"live".to_vec()));
            assert!(receiver.try_recv().is_err(), "attach duplicated a retained frame");
        }

        #[test]
        fn smart_attach_cannot_miss_exit_between_dead_check_and_subscribe() {
            let host = exited_host_fixture();
            let exit_record_path = host.exit_record_path.clone();
            let exit_record_root = exit_record_path.parent().unwrap().to_path_buf();
            let exit_host = host.clone();
            let term = host.term.lock().unwrap();
            let smart_publication = host.smart.broadcast_lock.lock().unwrap();
            assert!(!host.dead.load(Ordering::Acquire));

            let (started_tx, started_rx) = std::sync::mpsc::channel();
            let exit = thread::spawn(move || {
                started_tx.send(()).unwrap();
                exit_host.persist_and_publish_exit_if_drained().unwrap();
            });
            started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                match host.source_order_lock.try_lock() {
                    Ok(source_order) => {
                        drop(source_order);
                        assert!(Instant::now() < deadline, "Exit did not reach publication");
                        thread::yield_now();
                    }
                    Err(TryLockError::WouldBlock) => break,
                    Err(TryLockError::Poisoned(error)) => panic!("{error}"),
                }
            }
            // Once Exit owns source ordering, the old implementation is
            // runnable and only a few uncontended operations from `dead =
            // true`. Give it a generous scheduling window so this regression
            // cannot pass merely because that thread was preempted after the
            // lock probe. The fixed implementation remains blocked on `term`.
            let transition_deadline = Instant::now() + Duration::from_secs(1);
            while !host.dead.load(Ordering::Acquire) && Instant::now() < transition_deadline {
                thread::sleep(Duration::from_millis(1));
            }
            assert!(
                !host.dead.load(Ordering::Acquire),
                "Exit bypassed the terminal snapshot lock after the attach dead check"
            );

            drop(smart_publication);
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };
            assert_eq!(host.smart.subscribe(7, tap).unwrap(), 0);
            drop(term);
            exit.join().unwrap();

            assert!(host.dead.load(Ordering::Acquire));
            assert_eq!(host.smart.applied_cursor.load(Ordering::Acquire), 1);
            let exit = receiver.recv().unwrap();
            assert_eq!((exit.kind, exit.sequence), (MessageKind::Exit, 1));
            assert!(receiver.try_recv().is_err(), "attach received Exit more than once");
            fs::remove_file(exit_record_path).unwrap();
            let _ = fs::remove_dir(exit_record_root);
        }

        #[test]
        fn smart_attach_reports_retention_gap_instead_of_silent_corruption() {
            let state = SmartStreamState::new();
            for byte in 0..=MAX_SMART_RETAINED_FRAMES {
                state.publish(Frame::new(MessageKind::Output, vec![byte as u8]));
            }
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, _receiver) = mpsc_channel();
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };
            let gap = state.subscribe(9, tap).unwrap_err();
            assert_eq!(gap, SmartReplayGap::Retention { requested_after: 0, retained_after: 1 });
            assert!(state.is_empty(), "a gapped renderer must not join the live tap set");
        }

        #[test]
        fn smart_attach_distinguishes_subscriber_queue_overflow() {
            let state = SmartStreamState::new();
            let cursor = state.publish(Frame::new(MessageKind::Output, vec![1]));
            state.mark_applied(0);
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, _receiver) = mpsc_channel();
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: 0,
            };

            let gap = state.subscribe(10, tap).unwrap_err();

            assert_eq!(cursor, 1);
            assert_eq!(gap, SmartReplayGap::SubscriberQueueOverflow { boundary: 0 });
            assert_eq!(gap.encode()[16], 1);
            assert!(state.is_empty(), "an overflowing renderer must not join the live tap set");
        }

        #[test]
        fn smart_noisy_neighbor_is_evicted_without_stalling_other_renderers() {
            let state = SmartStreamState::new();
            let tap = |capacity| {
                let (host_socket, _client_socket) = UnixStream::pair().unwrap();
                let (sender, receiver) = mpsc_channel();
                (
                    HostTap {
                        sender,
                        queued_bytes: Arc::new(AtomicUsize::new(0)),
                        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                        shutdown: Arc::new(host_socket),
                        max_queued_bytes: capacity
                            * (crate::terminal_host_protocol::HEADER_LEN + 1),
                    },
                    receiver,
                )
            };
            let (slow, _slow_receiver) = tap(1);
            let (fast, fast_receiver) = tap(4);
            state.subscribe(1, slow).unwrap();
            state.subscribe(2, fast).unwrap();

            state.publish(Frame::new(MessageKind::Output, vec![1]));
            state.publish(Frame::new(MessageKind::Output, vec![2]));

            assert_eq!(fast_receiver.recv().unwrap().payload, vec![1]);
            assert_eq!(fast_receiver.recv().unwrap().payload, vec![2]);
            assert_eq!(state.taps.lock().unwrap().len(), 1);
        }

        #[test]
        fn smart_failed_transition_is_closed_by_applied_resync_boundary() {
            let state = SmartStreamState::new();
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };
            state.subscribe(1, tap).unwrap();

            let failed = state.publish(Frame::new(MessageKind::Resized, vec![80, 0, 24, 0]));
            state.close_failed_transition(Some(failed));

            assert_eq!(receiver.recv().unwrap().kind, MessageKind::Resized);
            let resync = receiver.recv().unwrap();
            assert_eq!(resync.kind, MessageKind::ResyncRequired);
            assert_eq!(resync.sequence, failed + 1);
            assert_eq!(state.applied_cursor.load(Ordering::Acquire), resync.sequence);
        }

        #[test]
        fn parser_output_send_failure_closes_published_transition() {
            let state = SmartStreamState::new();
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (tap_sender, tap_receiver) = mpsc_channel();
            state
                .subscribe(
                    1,
                    HostTap {
                        sender: tap_sender,
                        queued_bytes: Arc::new(AtomicUsize::new(0)),
                        queued_output_bytes: Arc::new(AtomicUsize::new(0)),
                        shutdown: Arc::new(host_socket),
                        max_queued_bytes: usize::MAX,
                    },
                )
                .unwrap();

            let failed = state.publish(Frame::new(MessageKind::Output, vec![1, 2, 3]));
            let budget = ParserBudget::new(3);
            budget.reserve(3);
            let (parser_sender, parser_receiver) = sync_channel(1);
            drop(parser_receiver);

            assert!(!enqueue_parser_output(
                &parser_sender,
                &budget,
                &state,
                vec![1, 2, 3],
                failed,
                3,
            ));

            assert_eq!(*budget.queued_bytes.lock().unwrap(), 0);
            assert_eq!(tap_receiver.recv().unwrap().kind, MessageKind::Output);
            let resync = tap_receiver.recv().unwrap();
            assert_eq!(resync.kind, MessageKind::ResyncRequired);
            assert_eq!(resync.sequence, failed + 1);
            assert_eq!(state.applied_cursor.load(Ordering::Acquire), resync.sequence);
        }

        #[test]
        fn parser_budget_blocks_at_saturation_and_unblocks_after_release() {
            let budget = Arc::new(ParserBudget::new(4));
            budget.reserve(4);
            let (reserved, observed) = std::sync::mpsc::channel();
            let waiter = {
                let budget = budget.clone();
                thread::spawn(move || {
                    budget.reserve(1);
                    reserved.send(()).unwrap();
                    budget.release(1);
                })
            };

            assert!(
                observed.recv_timeout(Duration::from_millis(30)).is_err(),
                "a saturated parser budget admitted another source chunk"
            );
            budget.release(4);
            observed.recv_timeout(Duration::from_secs(1)).unwrap();
            waiter.join().unwrap();
            assert_eq!(*budget.queued_bytes.lock().unwrap(), 0);
        }

        #[test]
        fn viewer_resize_apply_order_cannot_invert_reduced_sizes() {
            let viewer_sizes = Arc::new(Mutex::new(HashMap::new()));
            let applied = Arc::new(Mutex::new(Vec::new()));
            let (first_applying_tx, first_applying_rx) = std::sync::mpsc::channel();
            let (release_first_tx, release_first_rx) = std::sync::mpsc::channel();

            let first = {
                let viewer_sizes = viewer_sizes.clone();
                let applied = applied.clone();
                thread::spawn(move || {
                    mutate_viewer_sizes(
                        &viewer_sizes,
                        |sizes| {
                            sizes.insert(1, (120, 40));
                        },
                        |desired| {
                            first_applying_tx.send(()).unwrap();
                            release_first_rx.recv().unwrap();
                            applied.lock().unwrap().push(desired.unwrap());
                            Ok(())
                        },
                    )
                    .unwrap();
                })
            };
            first_applying_rx.recv().unwrap();

            let (second_attempting_tx, second_attempting_rx) = std::sync::mpsc::channel();
            let (second_mutating_tx, second_mutating_rx) = std::sync::mpsc::channel();
            let second = {
                let viewer_sizes = viewer_sizes.clone();
                let applied = applied.clone();
                thread::spawn(move || {
                    second_attempting_tx.send(()).unwrap();
                    mutate_viewer_sizes(
                        &viewer_sizes,
                        |sizes| {
                            second_mutating_tx.send(()).unwrap();
                            sizes.insert(2, (80, 24));
                        },
                        |desired| {
                            applied.lock().unwrap().push(desired.unwrap());
                            Ok(())
                        },
                    )
                    .unwrap();
                })
            };
            second_attempting_rx.recv().unwrap();
            assert!(second_mutating_rx.try_recv().is_err());
            release_first_tx.send(()).unwrap();
            first.join().unwrap();
            second.join().unwrap();

            assert_eq!(*applied.lock().unwrap(), vec![(120, 40), (80, 24)]);
            assert_eq!(
                viewer_sizes
                    .lock()
                    .unwrap()
                    .values()
                    .copied()
                    .reduce(|left, right| (left.0.min(right.0), left.1.min(right.1))),
                Some((80, 24))
            );
        }

        #[test]
        fn exit_waits_for_final_pty_output_in_either_completion_order() {
            for child_first in [false, true] {
                let (host_socket, _client_socket) = UnixStream::pair().unwrap();
                let (sender, receiver) = mpsc_channel();
                let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);
                let broadcast_lock = Mutex::new(());
                let sequence = AtomicU64::new(0);
                let taps = Mutex::new(HashMap::from([(1, tap)]));
                let exit = TerminalExit {
                    outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
                    exited_at_ms: 1234,
                };
                let child_exited = Mutex::new(None);
                let pty_drained = AtomicBool::new(false);
                let exit_published = AtomicBool::new(false);

                if child_first {
                    *child_exited.lock().unwrap() = Some(exit.clone());
                    assert!(
                        persist_and_claim_host_exit_after_drain(
                            &child_exited,
                            &pty_drained,
                            &exit_published,
                            |_| Ok(()),
                        )
                        .unwrap()
                        .is_none()
                    );
                }

                publish_host_frames(
                    &broadcast_lock,
                    &sequence,
                    &taps,
                    [Frame::new(MessageKind::Output, b"final-output".to_vec())],
                );
                pty_drained.store(true, Ordering::Release);

                if !child_first {
                    assert!(
                        persist_and_claim_host_exit_after_drain(
                            &child_exited,
                            &pty_drained,
                            &exit_published,
                            |_| Ok(()),
                        )
                        .unwrap()
                        .is_none()
                    );
                    *child_exited.lock().unwrap() = Some(exit.clone());
                }
                let claimed = persist_and_claim_host_exit_after_drain(
                    &child_exited,
                    &pty_drained,
                    &exit_published,
                    |_| Ok(()),
                )
                .unwrap()
                .expect("drained exited child claims one Exit");
                assert_eq!(claimed, exit);
                publish_host_frames(
                    &broadcast_lock,
                    &sequence,
                    &taps,
                    [Frame::new(MessageKind::Exit, encode_terminal_exit(&claimed))],
                );
                assert!(
                    persist_and_claim_host_exit_after_drain(
                        &child_exited,
                        &pty_drained,
                        &exit_published,
                        |_| Ok(()),
                    )
                    .unwrap()
                    .is_none()
                );

                let frames = receiver.try_iter().collect::<Vec<_>>();
                assert_eq!(frames.len(), 2);
                assert_eq!(frames[0].kind, MessageKind::Output);
                assert_eq!(frames[0].payload, b"final-output");
                assert_eq!(frames[0].sequence, 1);
                assert_eq!(frames[1].kind, MessageKind::Exit);
                assert_eq!(frames[1].sequence, 2);
                assert_eq!(decode_terminal_exit(&frames[1].payload).unwrap(), exit);
            }
        }

        #[test]
        fn exit_persistence_failure_does_not_claim_or_publish_status() {
            let exit = TerminalExit {
                outcome: crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                    signal: libc::SIGTERM,
                    core_dumped: false,
                },
                exited_at_ms: 4567,
            };
            let child_exited = Mutex::new(Some(exit.clone()));
            let pty_drained = AtomicBool::new(true);
            let exit_published = AtomicBool::new(false);
            let failed = persist_and_claim_host_exit_after_drain(
                &child_exited,
                &pty_drained,
                &exit_published,
                |_| anyhow::bail!("injected sidecar fsync failure"),
            );
            assert!(failed.is_err());
            assert!(!exit_published.load(Ordering::Acquire));

            let claimed = persist_and_claim_host_exit_after_drain(
                &child_exited,
                &pty_drained,
                &exit_published,
                |_| Ok(()),
            )
            .unwrap();
            assert_eq!(claimed, Some(exit));
            assert!(exit_published.load(Ordering::Acquire));
            assert!(
                persist_and_claim_host_exit_after_drain(
                    &child_exited,
                    &pty_drained,
                    &exit_published,
                    |_| panic!("already-published exit must not persist twice"),
                )
                .unwrap()
                .is_none()
            );
        }

        #[test]
        fn exit_persistence_failure_writes_a_private_bounded_retry_diagnostic() {
            let directory = std::env::temp_dir().join(format!(
                "cmux-host-exit-diagnostic-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&directory).unwrap();
            let exit_path = directory.join("terminal.exit");
            write_exit_persistence_diagnostic(
                &exit_path,
                3,
                &anyhow::anyhow!("injected persistence failure"),
            )
            .unwrap();
            let diagnostic = exit_persistence_diagnostic_path(&exit_path);
            let message = fs::read_to_string(&diagnostic).unwrap();
            assert!(message.contains("attempt 3"), "{message}");
            assert!(message.contains("injected persistence failure"), "{message}");
            assert_eq!(fs::metadata(&diagnostic).unwrap().permissions().mode() & 0o777, 0o600);

            let mut delay = HOST_EXIT_PERSIST_RETRY_MIN;
            for _ in 0..16 {
                delay = next_exit_persistence_retry_delay(delay);
            }
            assert_eq!(delay, HOST_EXIT_PERSIST_RETRY_MAX);

            clear_exit_persistence_diagnostic(&exit_path);
            assert!(!diagnostic.exists());
            fs::remove_dir(directory).unwrap();
        }

        #[test]
        fn persistent_exit_record_failure_does_not_block_host_progress() {
            let blocking_parent = std::env::temp_dir().join(format!(
                "cmux-host-exit-failure-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::write(&blocking_parent, b"not a directory").unwrap();
            let host = exited_host_fixture_at(blocking_parent.clone());
            let weak = Arc::downgrade(&host);
            let (returned_tx, returned_rx) = std::sync::mpsc::channel();
            let publisher = thread::spawn({
                let host = host.clone();
                move || {
                    host.publish_exit_if_drained();
                    returned_tx.send(()).unwrap();
                }
            });

            returned_rx
                .recv_timeout(Duration::from_millis(250))
                .expect("exit persistence blocked the host snapshot path");
            publisher.join().unwrap();
            drop(host);
            let deadline = Instant::now() + Duration::from_secs(1);
            while weak.upgrade().is_some() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            assert!(weak.upgrade().is_none(), "exit publisher retained the dropped host");
            fs::remove_file(blocking_parent).unwrap();
        }

        #[test]
        fn forced_drain_waits_for_late_bytes_then_exits_with_writer_still_open() {
            let (mut pty_reader, mut retained_writer) = UnixStream::pair().unwrap();
            let (mut drain_waiter, mut drain_waker) = UnixStream::pair().unwrap();
            let force_drain = Arc::new(AtomicBool::new(false));
            let worker_force = force_drain.clone();
            let (written_tx, written_rx) = std::sync::mpsc::channel();
            let (release_tx, release_rx) = std::sync::mpsc::channel();
            let worker = thread::spawn(move || {
                worker_force.store(true, Ordering::Release);
                drain_waker.write_all(&[1]).unwrap();
                // Keep the ordering deterministic without depending on the
                // worker being rescheduled inside the 100 ms drain window.
                // The bytes are still written strictly after forced drain is
                // requested and its waiter is woken.
                retained_writer.write_all(b"late").unwrap();
                written_tx.send(()).unwrap();
                // Deliberately retain the write side beyond the forced drain
                // bound. The helper must not confuse an open writer with more
                // bytes becoming readable forever.
                release_rx.recv().unwrap();
            });

            let mut forced_at = None;
            assert!(
                wait_for_pty_readable_or_forced_drain(
                    pty_reader.as_raw_fd(),
                    &mut drain_waiter,
                    &force_drain,
                    &mut forced_at,
                )
                .unwrap()
            );
            let mut late = [0u8; 4];
            pty_reader.read_exact(&mut late).unwrap();
            assert_eq!(&late, b"late");
            written_rx.recv().unwrap();
            assert!(
                !wait_for_pty_readable_or_forced_drain(
                    pty_reader.as_raw_fd(),
                    &mut drain_waiter,
                    &force_drain,
                    &mut forced_at,
                )
                .unwrap()
            );

            release_tx.send(()).unwrap();
            worker.join().unwrap();
        }

        #[test]
        fn coupled_color_frames_stay_adjacent_under_concurrent_exit_and_resize() {
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);
            let broadcast_lock = Mutex::new(());
            let sequence = AtomicU64::new(0);
            let taps = Mutex::new(HashMap::from([(1, tap)]));
            let barrier = Arc::new(std::sync::Barrier::new(4));

            thread::scope(|scope| {
                let spawn = |frames| {
                    let barrier = barrier.clone();
                    let broadcast_lock = &broadcast_lock;
                    let sequence = &sequence;
                    let taps = &taps;
                    scope.spawn(move || {
                        barrier.wait();
                        publish_host_frames(broadcast_lock, sequence, taps, frames);
                    });
                };
                let paired = |kind, payload| {
                    let mut first = Frame::new(kind, Vec::new());
                    first.flags = FLAG_COLORS_FOLLOW;
                    vec![first, Frame::new(MessageKind::Colors, payload)]
                };
                spawn(paired(MessageKind::Output, vec![1]));
                spawn(paired(MessageKind::Resized, vec![2]));
                spawn(vec![Frame::new(MessageKind::Exit, vec![])]);
                barrier.wait();
            });

            let frames = receiver.try_iter().collect::<Vec<_>>();
            assert_eq!(frames.len(), 5);
            assert_eq!(
                frames.iter().map(|frame| frame.sequence).collect::<Vec<_>>(),
                vec![1, 2, 3, 4, 5]
            );
            let output = frames.iter().position(|frame| frame.kind == MessageKind::Output).unwrap();
            assert_eq!(frames[output].flags, FLAG_COLORS_FOLLOW);
            assert_eq!(frames[output + 1].kind, MessageKind::Colors);
            assert_eq!(frames[output + 1].flags, 0);
            assert_eq!(frames[output + 1].payload, vec![1]);
            let resized =
                frames.iter().position(|frame| frame.kind == MessageKind::Resized).unwrap();
            assert_eq!(frames[resized].flags, FLAG_COLORS_FOLLOW);
            assert_eq!(frames[resized + 1].kind, MessageKind::Colors);
            assert_eq!(frames[resized + 1].flags, 0);
            assert_eq!(frames[resized + 1].payload, vec![2]);
        }

        #[test]
        fn pwd_none_to_none_emits_nothing() {
            let mut last_pwd = None;

            assert!(changed_pwd_frame(&mut last_pwd, None).is_none());
            assert_eq!(last_pwd, None);
        }

        #[test]
        fn pwd_changes_emit_once_and_duplicates_are_suppressed() {
            let mut last_pwd = None;

            let first = changed_pwd_frame(&mut last_pwd, Some("/one".into())).unwrap();
            assert_eq!(first.kind, MessageKind::Pwd);
            assert_eq!(first.payload, b"/one");
            assert!(changed_pwd_frame(&mut last_pwd, Some("/one".into())).is_none());

            let changed = changed_pwd_frame(&mut last_pwd, Some("/two".into())).unwrap();
            assert_eq!(changed.kind, MessageKind::Pwd);
            assert_eq!(changed.payload, b"/two");
            assert_eq!(last_pwd.as_deref(), Some("/two"));
        }

        #[test]
        fn pwd_clear_emits_one_empty_payload() {
            let mut last_pwd = Some("/before-clear".into());

            let clear = changed_pwd_frame(&mut last_pwd, None).unwrap();
            assert_eq!(clear.kind, MessageKind::Pwd);
            assert!(clear.payload.is_empty());
            assert_eq!(last_pwd, None);
            assert!(changed_pwd_frame(&mut last_pwd, None).is_none());
        }

        #[test]
        fn late_snapshot_prefers_current_terminal_pwd_then_spawn_fallback() {
            let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            assert_eq!(snapshot_cwd(&term, Some("/spawn")), Some("/spawn".into()));

            term.vt_write(b"\x1b]7;file:///live\x1b\\");
            assert_eq!(snapshot_cwd(&term, Some("/spawn")), Some("file:///live".into()));

            term.vt_write(b"\x1b]7;\x1b\\");
            assert_eq!(snapshot_cwd(&term, Some("/spawn")), Some("/spawn".into()));
        }

        #[test]
        fn pwd_change_stays_contiguous_with_its_output_boundary() {
            let (host_socket, _client_socket) = UnixStream::pair().unwrap();
            let (sender, receiver) = mpsc_channel();
            let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);
            let broadcast_lock = Mutex::new(());
            let sequence = AtomicU64::new(0);
            let taps = Mutex::new(HashMap::from([(1, tap)]));
            let barrier = Arc::new(std::sync::Barrier::new(3));
            let mut last_pwd = None;
            let output = output_transition_frames(
                b"prompt".to_vec(),
                Some(vec![7]),
                changed_pwd_frame(&mut last_pwd, Some("/work".into())),
            );

            thread::scope(|scope| {
                let spawn = |frames| {
                    let barrier = barrier.clone();
                    let broadcast_lock = &broadcast_lock;
                    let sequence = &sequence;
                    let taps = &taps;
                    scope.spawn(move || {
                        barrier.wait();
                        publish_host_frames(broadcast_lock, sequence, taps, frames);
                    });
                };
                spawn(output);
                spawn(vec![Frame::new(MessageKind::Exit, Vec::new())]);
                barrier.wait();
            });

            let frames = receiver.try_iter().collect::<Vec<_>>();
            assert_eq!(frames.len(), 4);
            assert_eq!(
                frames.iter().map(|frame| frame.sequence).collect::<Vec<_>>(),
                vec![1, 2, 3, 4]
            );
            let output = frames.iter().position(|frame| frame.kind == MessageKind::Output).unwrap();
            assert_eq!(frames[output].flags, FLAG_COLORS_FOLLOW);
            assert_eq!(frames[output + 1].kind, MessageKind::Colors);
            assert_eq!(frames[output + 1].payload, vec![7]);
            assert_eq!(frames[output + 2].kind, MessageKind::Pwd);
            assert_eq!(frames[output + 2].payload, b"/work");
            assert_eq!(frames[output + 1].sequence, frames[output].sequence + 1);
            assert_eq!(frames[output + 2].sequence, frames[output].sequence + 2);
        }
    }
}

#[cfg(unix)]
pub(crate) use unix::{
    ControlResponses, DecodedHostResize, DeferredCellPixelResolution,
    acquire_terminal_host_reset_lock, adopt_terminal_host_with_kitty_limits,
    decode_host_resize_payload_for_version, load_terminal_host_records_for_reset,
};
#[cfg(unix)]
pub use unix::{
    HostAttachment, acknowledge_terminal_host_exit_record, adopt_terminal_host,
    decode_host_snapshot_payload, encode_host_snapshot_payload, isolate_terminal_host_process_fds,
    launch_terminal_host, launch_terminal_host_with_identity, load_terminal_host_exit_records,
    load_terminal_host_records, remove_stale_terminal_host_record, serve_terminal_host_stdio,
    terminal_host_exit_record, terminal_host_record_liveness, terminal_host_root,
    validate_terminal_host_exit_record, validate_terminal_host_record,
};
#[cfg(all(unix, test))]
pub(crate) use unix::{
    acquire_terminal_host_publication_lock, prepare_terminal_host_publication_lock,
};

#[cfg(not(unix))]
pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
    state_root.join(format!("{session}.terminal-hosts"))
}

#[cfg(not(unix))]
pub fn isolate_terminal_host_process_fds() -> anyhow::Result<()> {
    Ok(())
}

#[cfg(not(unix))]
pub(crate) struct TerminalHostResetLock;

#[cfg(not(unix))]
pub(crate) fn acquire_terminal_host_reset_lock(
    _root: &Path,
) -> anyhow::Result<Option<TerminalHostResetLock>> {
    anyhow::bail!("terminal host liveness cannot be verified on this platform")
}

#[cfg(not(unix))]
pub fn serve_terminal_host_stdio(
    _args: &[String],
    _reader: &mut impl std::io::Read,
    _writer: &mut impl std::io::Write,
) -> anyhow::Result<()> {
    anyhow::bail!("per-terminal hosts are not implemented on this platform")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ghostty_vt::CursorShape;

    #[test]
    fn colors_payload_is_versioned_bounded_full_sparse_state() {
        let mut colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            background: Some(Rgb { r: 4, g: 5, b: 6 }),
            cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
            cursor_visual: Some((CursorShape::Underline, true)),
            ..Default::default()
        };
        colors.palette[0] = Some(Rgb { r: 10, g: 11, b: 12 });
        colors.palette[255] = Some(Rgb { r: 13, g: 14, b: 15 });
        let payload = encode_terminal_color_overrides(&colors);
        assert!(payload.len() <= MAX_TERMINAL_COLORS_PAYLOAD);
        assert_eq!(
            payload,
            vec![
                2, 0, 15, 0, 2, 0, 0, 0, // v2 header, all fields, two palette entries
                1, 2, 3, 4, 5, 6, 7, 8, 9, // optional RGBs
                2, 1, // underline, blinking
                0, 10, 11, 12, 255, 13, 14, 15, // palette entries
            ]
        );
        assert_eq!(&payload[0..2], &TERMINAL_COLORS_WIRE_VERSION.to_le_bytes());
        assert_eq!(&payload[2..4], &0b1111u16.to_le_bytes());
        assert_eq!(&payload[17..19], &[2, 1], "cursor visual follows the optional RGBs");
        assert_eq!(decode_terminal_color_overrides(&payload).unwrap(), colors);
    }

    #[test]
    fn colors_payload_v2_requires_resolved_cursor_visual() {
        assert!(
            std::panic::catch_unwind(|| {
                encode_terminal_color_overrides(&TerminalColorOverrides::default())
            })
            .is_err()
        );
        assert!(
            decode_terminal_color_overrides(&[2, 0, 0, 0, 0, 0, 0, 0]).is_err(),
            "v2 without the atomic cursor pair must fail closed"
        );
    }

    #[test]
    fn colors_payload_decodes_v1_without_cursor_visual() {
        assert_eq!(
            decode_terminal_color_overrides(&[1, 0, 0, 0, 0, 0, 0, 0]).unwrap(),
            TerminalColorOverrides::default()
        );
        let payload = [
            1, 0, // schema v1
            7, 0, // foreground, background, and cursor RGB
            0, 0, // no palette entries
            0, 0, // reserved
            1, 2, 3, // foreground
            4, 5, 6, // background
            7, 8, 9, // cursor
        ];
        assert_eq!(
            decode_terminal_color_overrides(&payload).unwrap(),
            TerminalColorOverrides {
                foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
                background: Some(Rgb { r: 4, g: 5, b: 6 }),
                cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
                ..Default::default()
            }
        );

        let mut v1_with_v2_flag = payload.to_vec();
        v1_with_v2_flag[2..4].copy_from_slice(&0b1111u16.to_le_bytes());
        v1_with_v2_flag.extend_from_slice(&[1, 0]);
        assert!(decode_terminal_color_overrides(&v1_with_v2_flag).is_err());
    }

    #[test]
    fn colors_payload_cursor_visual_round_trips_every_v2_value() {
        for cursor_visual in [
            (CursorShape::Block, false),
            (CursorShape::Block, true),
            (CursorShape::Underline, false),
            (CursorShape::Underline, true),
            (CursorShape::Bar, false),
            (CursorShape::Bar, true),
        ] {
            let colors =
                TerminalColorOverrides { cursor_visual: Some(cursor_visual), ..Default::default() };
            let payload = encode_terminal_color_overrides(&colors);
            assert_eq!(payload.len(), 10);
            assert_eq!(decode_terminal_color_overrides(&payload).unwrap(), colors);
        }

        // DECSCUSR and the cross-language wire have no hollow-block value.
        let hollow = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::BlockHollow, false)),
            ..Default::default()
        };
        let payload = encode_terminal_color_overrides(&hollow);
        assert_eq!(&payload[8..10], &[1, 0]);
        assert_eq!(
            decode_terminal_color_overrides(&payload).unwrap().cursor_visual,
            Some((CursorShape::Block, false))
        );
    }

    #[test]
    fn colors_payload_rejects_unknown_versions_duplicates_and_malformed_visuals() {
        let mut colors = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Block, false)),
            ..Default::default()
        };
        colors.palette[1] = Some(Rgb { r: 1, g: 2, b: 3 });
        colors.palette[2] = Some(Rgb { r: 4, g: 5, b: 6 });
        let payload = encode_terminal_color_overrides(&colors);

        let mut bad_version = payload.clone();
        bad_version[0..2].copy_from_slice(&3u16.to_le_bytes());
        assert!(decode_terminal_color_overrides(&bad_version).is_err());

        let mut bad_flags = payload.clone();
        bad_flags[2..4].copy_from_slice(&0b1_1000u16.to_le_bytes());
        assert!(decode_terminal_color_overrides(&bad_flags).is_err());

        let mut bad_reserved = payload.clone();
        bad_reserved[6] = 1;
        assert!(decode_terminal_color_overrides(&bad_reserved).is_err());

        let mut duplicate = payload.clone();
        duplicate[14] = duplicate[10];
        assert!(decode_terminal_color_overrides(&duplicate).is_err());

        let mut trailing = payload;
        trailing.push(0);
        assert!(decode_terminal_color_overrides(&trailing).is_err());

        let visual = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Bar, true)),
            ..Default::default()
        };
        let visual = encode_terminal_color_overrides(&visual);
        let mut zero_style = visual.clone();
        zero_style[8] = 0;
        assert!(decode_terminal_color_overrides(&zero_style).is_err());
        let mut bad_style = visual.clone();
        bad_style[8] = 4;
        assert!(decode_terminal_color_overrides(&bad_style).is_err());
        let mut bad_blink = visual.clone();
        bad_blink[9] = 2;
        assert!(decode_terminal_color_overrides(&bad_blink).is_err());
        let mut truncated = visual;
        truncated.pop();
        assert!(decode_terminal_color_overrides(&truncated).is_err());
    }
}
