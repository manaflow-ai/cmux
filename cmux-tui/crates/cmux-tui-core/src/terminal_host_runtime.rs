//! Long-lived per-terminal process runtime.
//!
//! A terminal host owns the PTY master, child, authoritative Ghostty parser,
//! replay snapshot, and viewer-size arbitration.  The mux process only keeps
//! an authenticated mirror connection.  Host records contain no daemon-local
//! ids, so a replacement mux can adopt the same shell after a crash.

use std::path::{Path, PathBuf};

use ghostty_vt::{KittyImageAlias, Rgb, TerminalColorOverrides};
use serde::{Deserialize, Serialize};

use crate::surface::{DefaultColors, SurfaceOptions, replace_ghostty_cursor_defaults};
use crate::terminal_host::{
    CapabilityRights, CapabilityStore, CapabilityToken, ClientHello, ClientRole, HostBootstrap,
    HostHello, HostIncarnation, HostReady, TerminalId,
};
use crate::terminal_host_protocol::{
    FLAG_COLORS_FOLLOW, FLAG_VIEWER_SIZE_ACKS, Frame, KITTY_IMAGE_ALIAS_COUNT_LEN,
    KITTY_IMAGE_ALIAS_ENCODED_LEN, MAX_FRAME_PAYLOAD, MAX_KITTY_IMAGE_ALIASES, MessageKind,
    PROTOCOL_VERSION, RESIZE_ACK_CANONICAL_CHANGED, read_frame, write_frame,
};

const HOST_RECORD_VERSION: u32 = 2;
const LEGACY_PROTOCOL_VERSION: u16 = 1;
const MAX_LAUNCH_PAYLOAD: usize = 1024 * 1024;
const MAX_STRING: usize = 256 * 1024;
const MAX_BLOB: usize = crate::surface::VT_REPLAY_MAX_BYTES;
const MAX_ARGV: usize = 256;
const MAX_ENV: usize = 1024;
const MAX_RENDERER_CAPABILITY_TTL: std::time::Duration = std::time::Duration::from_secs(60);
const CONTROL_RESPONSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
const HOST_HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
const MAX_HOST_CLIENT_QUEUED_BYTES: usize =
    MAX_FRAME_PAYLOAD + MAX_TERMINAL_COLORS_PAYLOAD + 2 * crate::terminal_host_protocol::HEADER_LEN;
const HOST_START_NONCE_LEN: usize = 32;
const TERMINAL_DIMENSION_MAX: u16 = 10_000;
const TERMINAL_CELL_AREA_MAX: u64 = 4_000_000;
const TERMINAL_COLORS_WIRE_VERSION_V1: u16 = 1;
pub const TERMINAL_COLORS_WIRE_VERSION: u16 = 2;
pub const MAX_TERMINAL_COLORS_PAYLOAD: usize = 8 + 3 * 3 + 2 + 256 * 4;
const _: () = assert!(
    2 * size_of::<u16>()
        + size_of::<u32>()
        + crate::surface::VT_REPLAY_MAX_BYTES
        + KITTY_IMAGE_ALIAS_COUNT_LEN
        + MAX_KITTY_IMAGE_ALIASES * KITTY_IMAGE_ALIAS_ENCODED_LEN
        <= MAX_FRAME_PAYLOAD
);

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
            .finish()
    }
}

impl TerminalHostRecord {
    pub fn record_path(&self, root: &Path) -> PathBuf {
        root.join(format!("{}.json", self.terminal_id))
    }
}

#[derive(Debug, Clone)]
pub struct HostSnapshot {
    pub cols: u16,
    pub rows: u16,
    pub replay: Vec<u8>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
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

#[cfg(unix)]
mod unix {
    use std::collections::{HashMap, HashSet};
    use std::fs::{self, File, OpenOptions};
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, RawFd};
    use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
    use std::sync::{Arc, Condvar, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    use anyhow::Context;
    use ghostty_vt::{Callbacks, CursorShape, Terminal};
    use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

    use super::*;

    static RECORD_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);
    const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);
    const HOST_KILL_WAIT: Duration = Duration::from_secs(2);
    const HOST_PTY_DRAIN_GRACE: Duration = Duration::from_millis(250);
    const HOST_FORCED_DRAIN_WINDOW: Duration = Duration::from_millis(100);
    const HOST_LAUNCH_ROLLBACK_WAIT: Duration = Duration::from_secs(4);

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
        scrollback: usize,
        cwd: Option<String>,
        command: Vec<String>,
        extra_env: Vec<(String, String)>,
        default_colors: DefaultColors,
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
            decoder.finish()?;
            Ok(Self {
                endpoint,
                record_path,
                term,
                cols,
                rows,
                scrollback,
                cwd,
                command,
                extra_env,
                default_colors,
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

    pub(crate) struct ControlResponses {
        waiters: Mutex<HashMap<u64, SyncSender<Frame>>>,
    }

    impl ControlResponses {
        pub(crate) fn resolve(&self, frame: &Frame) {
            if let Some(waiter) = self.waiters.lock().unwrap().remove(&frame.request_id) {
                let _ = waiter.try_send(frame.clone());
            }
        }
    }

    pub struct HostAttachment {
        pub record: TerminalHostRecord,
        pub record_path: PathBuf,
        pub snapshot: HostSnapshot,
        protocol_version: u16,
        reader: Option<UnixStream>,
        writer: Arc<Mutex<UnixStream>>,
        control_responses: Arc<ControlResponses>,
        next_request: AtomicU64,
        viewer_size: Mutex<Option<(u16, u16)>>,
        /// Exact process ownership retained only between a successful launch
        /// handshake and complete Surface materialization. Adoption never
        /// carries this guard.
        launch_process: Option<SpawnedHostProcess>,
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

    impl HostAttachment {
        pub fn take_reader(&mut self) -> anyhow::Result<UnixStream> {
            self.reader.take().ok_or_else(|| anyhow::anyhow!("terminal-host reader already taken"))
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
            if self.protocol_version < 2 {
                return Ok(false);
            }
            let width_px = width_px.max(1);
            let height_px = height_px.max(1);
            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
            let (sender, receiver) = sync_channel(1);
            self.control_responses.waiters.lock().unwrap().insert(request_id, sender);
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
            let response = match receiver.recv_timeout(CONTROL_RESPONSE_TIMEOUT) {
                Ok(response) => response,
                Err(error) => {
                    self.control_responses.waiters.lock().unwrap().remove(&request_id);
                    return Err(anyhow::anyhow!(
                        "terminal host did not acknowledge cell pixel size: {error}"
                    ));
                }
            };
            if response.kind != MessageKind::CellPixelSizeAck
                || response.payload.as_slice()
                    != [width_px.to_le_bytes(), height_px.to_le_bytes()].concat()
            {
                anyhow::bail!("terminal host returned a malformed cell pixel size acknowledgement");
            }
            Ok(true)
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

        pub fn terminate(&self) -> std::io::Result<()> {
            self.send(MessageKind::Terminate, &[])
        }

        pub fn disconnect(&self) {
            let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
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

        pub fn identity(&self) -> TerminalHostIdentity {
            TerminalHostIdentity {
                terminal_id: self.record.terminal_id.clone(),
                incarnation: self.record.incarnation.clone(),
            }
        }

        pub(crate) fn discovery_record(&self) -> (TerminalHostRecord, PathBuf) {
            (self.record.clone(), self.record_path.clone())
        }

        pub(crate) fn control_responses(&self) -> Arc<ControlResponses> {
            self.control_responses.clone()
        }

        pub fn mint_renderer_grant(&self, ttl: Duration) -> anyhow::Result<RendererGrant> {
            if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
                anyhow::bail!("renderer capability TTL must be between 1ms and 60s");
            }
            let ttl_ms = u32::try_from(ttl.as_millis())
                .map_err(|_| anyhow::anyhow!("renderer capability TTL is too large"))?;
            let request_id = self.next_request.fetch_add(1, Ordering::Relaxed);
            let (sender, receiver) = sync_channel(1);
            self.control_responses.waiters.lock().unwrap().insert(request_id, sender);
            let mut payload = Vec::with_capacity(8);
            payload.extend_from_slice(&CapabilityRights::RENDERER.bits().to_le_bytes());
            payload.extend_from_slice(&ttl_ms.to_le_bytes());
            let mut frame = Frame::new(MessageKind::MintCapability, payload);
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
            let response = match receiver.recv_timeout(CONTROL_RESPONSE_TIMEOUT) {
                Ok(response) => response,
                Err(error) => {
                    self.control_responses.waiters.lock().unwrap().remove(&request_id);
                    return Err(anyhow::anyhow!(
                        "terminal host did not mint renderer grant: {error}"
                    ));
                }
            };
            if response.kind != MessageKind::Capability {
                anyhow::bail!("terminal host returned the wrong renderer capability response");
            }
            let payload = response.payload;
            if payload.len() != crate::terminal_host::CAPABILITY_TOKEN_LEN {
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
            if process.wait_timeout(HOST_LAUNCH_ROLLBACK_WAIT) {
                return;
            }
            drop(process);
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
    ) -> anyhow::Result<HostAttachment> {
        let terminal_id = TerminalId::random()?;
        launch_terminal_host_with_identity(options, root, default_colors, terminal_id)
    }

    /// Launch using a registry-reserved stable UUID. The workspace registry
    /// can commit identity/placement before process creation, eliminating the
    /// launch-window orphan race without changing the host wire protocol.
    pub fn launch_terminal_host_with_identity(
        options: &SurfaceOptions,
        root: &Path,
        default_colors: DefaultColors,
        terminal_id: TerminalId,
    ) -> anyhow::Result<HostAttachment> {
        prepare_private_dir(root)?;
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
            scrollback: options.scrollback,
            cwd: options.cwd.clone().or_else(|| {
                crate::platform::home_dir().map(|path| path.to_string_lossy().into_owned())
            }),
            command,
            extra_env: options.extra_env.clone(),
            default_colors,
        };

        let binary = std::env::current_exe().context("resolve cmux-tui terminal-host binary")?;
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
        if launched_frame.kind != MessageKind::Ready || launched_frame.request_id != 2 {
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
        // Keep the exact-kill guard armed through record validation and a
        // successful authenticated Snapshot. Returning Err after disarming it
        // would leave a live published host while the mux marks its registry
        // row Exited.
        let mut attachment = connect_record(record, record_path)?;
        attachment.launch_process = Some(process);
        Ok(attachment)
    }

    pub fn adopt_terminal_host(
        record: TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<HostAttachment> {
        validate_terminal_host_record(&record_path, &record)?;
        connect_record(record, record_path)
    }

    /// Validate a discovery record without trusting paths or alternate
    /// identity spellings supplied by its JSON payload.
    pub fn validate_terminal_host_record(
        record_path: &Path,
        record: &TerminalHostRecord,
    ) -> anyhow::Result<TerminalHostIdentity> {
        if !matches!(record.record_version, 1 | HOST_RECORD_VERSION) {
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
            {
                anyhow::bail!("legacy terminal-host record has unexpected liveness fields");
            }
        } else {
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
                Err(_) => continue,
            };
            let Ok(record) = serde_json::from_slice::<TerminalHostRecord>(&bytes) else {
                continue;
            };
            if validate_terminal_host_record(&path, &record).is_err()
                || !identities.insert((record.terminal_id.clone(), record.incarnation.clone()))
            {
                continue;
            }
            records.push((path, record));
        }
        records.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(records)
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
        match connect_record_at_version(
            record.clone(),
            record_path.clone(),
            handshake_timeout,
            PROTOCOL_VERSION,
        ) {
            Ok(attachment) => Ok(attachment),
            Err(current_error) if PROTOCOL_VERSION != LEGACY_PROTOCOL_VERSION => {
                connect_record_at_version(
                    record,
                    record_path,
                    handshake_timeout,
                    LEGACY_PROTOCOL_VERSION,
                )
                .with_context(|| {
                    format!(
                        "terminal-host protocol {PROTOCOL_VERSION} handshake failed before the \
                         protocol-{LEGACY_PROTOCOL_VERSION} adoption fallback: {current_error:#}"
                    )
                })
            }
            Err(error) => Err(error),
        }
    }

    fn connect_record_at_version(
        record: TerminalHostRecord,
        record_path: PathBuf,
        handshake_timeout: Duration,
        protocol_version: u16,
    ) -> anyhow::Result<HostAttachment> {
        if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
            anyhow::bail!("unsupported terminal-host adoption protocol {protocol_version}");
        }
        let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id)?);
        let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?);
        let owner_token = CapabilityToken::from_bytes(decode_hex_array(&record.owner_token)?);
        let mut stream = connect_with_retry(Path::new(&record.endpoint))?;
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
        write_frame(&mut stream, &hello_frame)?;
        let hello_frame = read_required_frame(&mut stream, "host hello")?;
        if hello_frame.kind != MessageKind::HostHello
            || hello_frame.version != protocol_version
            || hello_frame.request_id != 1
            || hello_frame.sequence != 0
        {
            anyhow::bail!("terminal host rejected owner handshake");
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
            reader: Some(reader),
            writer: Arc::new(Mutex::new(stream)),
            control_responses: Arc::new(ControlResponses { waiters: Mutex::new(HashMap::new()) }),
            next_request: AtomicU64::new(2),
            // New hosts do not register Admin as a viewer. Initialize this as
            // if they did so the unconditional release below also upgrades
            // live protocol-v1 hosts whose older implementation registered
            // every connection at the snapshot grid.
            viewer_size: Mutex::new(Some(snapshot_size)),
            launch_process: None,
        };
        attachment.release_viewer_size()?;
        Ok(attachment)
    }

    fn connect_with_retry(path: &Path) -> anyhow::Result<UnixStream> {
        let mut last_error = None;
        for _ in 0..100 {
            match UnixStream::connect(path) {
                Ok(stream) => return Ok(stream),
                Err(error) => {
                    last_error = Some(error);
                    thread::sleep(Duration::from_millis(10));
                }
            }
        }
        Err(last_error
            .unwrap_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "host missing"))
            .into())
    }

    fn read_required_frame(reader: &mut impl Read, context: &str) -> anyhow::Result<Frame> {
        read_frame(reader, MAX_FRAME_PAYLOAD)?
            .ok_or_else(|| anyhow::anyhow!("terminal host closed before {context}"))
    }

    fn write_record(path: &Path, record: &TerminalHostRecord) -> anyhow::Result<()> {
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
        sender: SyncSender<Frame>,
        queued_bytes: Arc<AtomicUsize>,
        shutdown: Arc<UnixStream>,
        max_queued_bytes: usize,
    }

    impl HostTap {
        fn try_send(&self, frame: Frame) -> bool {
            let retained =
                crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len());
            let mut queued = self.queued_bytes.load(Ordering::Acquire);
            loop {
                let Some(next) = queued.checked_add(retained) else {
                    self.close();
                    return false;
                };
                if next > self.max_queued_bytes {
                    self.close();
                    return false;
                }
                match self.queued_bytes.compare_exchange_weak(
                    queued,
                    next,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => break,
                    Err(actual) => queued = actual,
                }
            }
            match self.sender.try_send(frame) {
                Ok(()) => true,
                Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                    self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
                    self.close();
                    false
                }
            }
        }

        fn release(&self, frame: &Frame) {
            let retained =
                crate::terminal_host_protocol::HEADER_LEN.saturating_add(frame.payload.len());
            self.queued_bytes.fetch_sub(retained, Ordering::AcqRel);
        }

        fn close(&self) {
            let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
        }
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
        next_client: AtomicU64,
        dead: AtomicBool,
        child_exit: (Mutex<bool>, Condvar),
        child_waitable: AtomicBool,
        pty_drained: AtomicBool,
        exit_published: AtomicBool,
        force_pty_drain: AtomicBool,
        pty_drain_waker: Mutex<UnixStream>,
        termination_started: AtomicBool,
        child_signal_lock: Mutex<()>,
        child_reaped: AtomicBool,
        group_escalation_complete: AtomicBool,
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
            let mut term = self.term.lock().unwrap();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
            let resolved = term.color_overrides();
            // An empty coupled Output is an ordered state transition already
            // understood by every v2 consumer; no standalone Colors frame can
            // split or bypass the live-stream stager.
            self.broadcast_with_colors(
                MessageKind::Output,
                Vec::new(),
                encode_terminal_color_overrides(&resolved),
            );
        }

        fn remove_client(&self, client: u64) {
            self.taps.lock().unwrap().remove(&client);
            let _ = mutate_viewer_sizes(
                &self.viewer_sizes,
                |viewer_sizes| {
                    viewer_sizes.remove(&client);
                },
                |desired| self.apply_viewer_minimum(desired, false, None).map(|_| ()),
            );
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
            let next = (width_px.max(1), height_px.max(1));
            let size = self.size.lock().unwrap();
            let mut cell_pixels = self.cell_pixels.lock().unwrap();
            let previous = *cell_pixels;
            let changed = previous != next;
            let mut term = self.term.lock().unwrap();
            if changed {
                let master = self.master.lock().unwrap();
                let next_size = PtySize {
                    rows: size.1,
                    cols: size.0,
                    pixel_width: size.0.saturating_mul(next.0),
                    pixel_height: size.1.saturating_mul(next.1),
                };
                master.resize(next_size)?;
                if let Err(error) =
                    term.resize(size.0, size.1, u32::from(next.0), u32::from(next.1))
                {
                    let rollback = master.resize(PtySize {
                        rows: size.1,
                        cols: size.0,
                        pixel_width: size.0.saturating_mul(previous.0),
                        pixel_height: size.1.saturating_mul(previous.1),
                    });
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
            let mut ack = Frame::new(MessageKind::CellPixelSizeAck, {
                let mut payload = Vec::with_capacity(4);
                payload.extend_from_slice(&next.0.to_le_bytes());
                payload.extend_from_slice(&next.1.to_le_bytes());
                payload
            });
            ack.request_id = request_id;
            // Keep the parser locked through targeted publication so output
            // parsed at the new metrics cannot overtake the acknowledgement.
            let queued = publish_host_frames_and_targeted(
                &self.broadcast_lock,
                &self.sequence,
                &self.taps,
                std::iter::empty(),
                Some((target, ack)),
            );
            if !queued && changed {
                let terminal_rollback =
                    term.resize(size.0, size.1, u32::from(previous.0), u32::from(previous.1));
                let master_rollback = self.master.lock().unwrap().resize(PtySize {
                    rows: size.1,
                    cols: size.0,
                    pixel_width: size.0.saturating_mul(previous.0),
                    pixel_height: size.1.saturating_mul(previous.1),
                });
                match (terminal_rollback, master_rollback) {
                    (Ok(()), Ok(())) => *cell_pixels = previous,
                    (terminal, master) => {
                        anyhow::bail!(
                            "cell-metric acknowledgement failed; Ghostty rollback: {terminal:?}; \
                             PTY rollback: {master:?}"
                        );
                    }
                }
            }
            Ok(queued)
        }

        fn apply_viewer_minimum(
            &self,
            desired: Option<(u16, u16)>,
            acknowledge_with_replay: bool,
            targeted_ack: Option<(u64, &HostTap)>,
        ) -> anyhow::Result<bool> {
            let Some((cols, rows)) = desired else { return Ok(true) };
            let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
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
            let previous = *size;
            let mut term = self.term.lock().unwrap();
            let master = self.master.lock().unwrap();
            if changed {
                master.resize(PtySize {
                    rows,
                    cols,
                    pixel_width: cols.saturating_mul(cell_pixels.0),
                    pixel_height: rows.saturating_mul(cell_pixels.1),
                })?;
                if let Err(error) =
                    term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))
                {
                    let _ = master.resize(PtySize {
                        rows: previous.1,
                        cols: previous.0,
                        pixel_width: previous.0.saturating_mul(cell_pixels.0),
                        pixel_height: previous.1.saturating_mul(cell_pixels.1),
                    });
                    return Err(error.into());
                }
            }
            let replay = match term
                .vt_replay_bounded_theme_portable_with_aliases(crate::surface::VT_REPLAY_MAX_BYTES)
            {
                Ok(replay) => replay,
                Err(error) => {
                    if changed {
                        let _ = term.resize(
                            previous.0,
                            previous.1,
                            u32::from(cell_pixels.0),
                            u32::from(cell_pixels.1),
                        );
                        let _ = master.resize(PtySize {
                            rows: previous.1,
                            cols: previous.0,
                            pixel_width: previous.0.saturating_mul(cell_pixels.0),
                            pixel_height: previous.1.saturating_mul(cell_pixels.1),
                        });
                    }
                    return Err(error.into());
                }
            };
            let colors = term.color_overrides();
            if changed {
                *size = (cols, rows);
            }
            // Keep the parser lock through sequence publication so output
            // parsed at the new size cannot overtake the Resized marker.
            let mut resized = Frame::new(
                MessageKind::Resized,
                encode_resize(cols, rows, &replay.bytes, &replay.kitty_image_aliases)?,
            );
            resized.flags = FLAG_COLORS_FOLLOW;
            let targeted = targeted_ack.map(|(request_id, tap)| {
                let mut frame =
                    Frame::new(MessageKind::ResizeAck, encode_resize_ack(cols, rows, changed));
                frame.request_id = request_id;
                (tap, frame)
            });
            Ok(publish_host_frames_and_targeted(
                &self.broadcast_lock,
                &self.sequence,
                &self.taps,
                [
                    resized,
                    Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors)),
                ],
                targeted,
            ))
        }

        fn child_exited(&self) -> bool {
            *self.child_exit.0.lock().unwrap()
        }

        fn wait_for_child_exit(&self, timeout: Duration) -> bool {
            let exited = self.child_exit.0.lock().unwrap();
            if *exited {
                return true;
            }
            let (exited, _) =
                self.child_exit.1.wait_timeout_while(exited, timeout, |exited| !*exited).unwrap();
            *exited
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
            self.group_escalation_complete.store(true, Ordering::Release);
            self.child_exit.1.notify_all();
        }

        fn publish_exit_if_drained(&self) {
            if claim_host_exit_after_drain(
                &self.child_exit.0,
                &self.pty_drained,
                &self.exit_published,
            ) {
                self.dead.store(true, Ordering::Release);
                self.broadcast(MessageKind::Exit, Vec::new());
            }
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

    fn claim_host_exit_after_drain(
        child_exited: &Mutex<bool>,
        pty_drained: &AtomicBool,
        exit_published: &AtomicBool,
    ) -> bool {
        pty_drained.load(Ordering::Acquire)
            && *child_exited.lock().unwrap()
            && exit_published
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
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

    struct HostServiceGuard {
        shared: Arc<HostShared>,
        endpoint: PathBuf,
        record_path: PathBuf,
        record: TerminalHostRecord,
        lease: HostLivenessLease,
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
            let mut removed_record = !self.published;
            if self.published
                && let Ok(bytes) = fs::read(&self.record_path)
                && let Ok(current) = serde_json::from_slice::<TerminalHostRecord>(&bytes)
                && current.terminal_id == self.record.terminal_id
                && current.incarnation == self.record.incarnation
                && current.host_start_nonce == self.record.host_start_nonce
            {
                removed_record = fs::remove_file(&self.record_path).is_ok();
            }
            let _ = fs::remove_file(&self.endpoint);
            if removed_record {
                let _ = fs::remove_file(&self.lease.path);
            }
            let _ = self.lease.file.sync_all();
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
        let shared = spawn_host_runtime(&launch, &bootstrapped)?;

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
        };
        let lease =
            HostLivenessLease::acquire(liveness_path(Path::new(&launch.record_path), &record))?;
        let mut guard = HostServiceGuard {
            shared: shared.clone(),
            endpoint,
            record_path: PathBuf::from(&launch.record_path),
            record: record.clone(),
            lease,
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

        while !shared.dead.load(Ordering::Acquire) {
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

    fn spawn_host_runtime(
        launch: &HostLaunch,
        bootstrapped: &crate::terminal_host::BootstrappedHost,
    ) -> anyhow::Result<Arc<HostShared>> {
        let pty = native_pty_system().openpty(PtySize {
            rows: launch.rows,
            cols: launch.cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        let mut command = CommandBuilder::new(&launch.command[0]);
        command.args(&launch.command[1..]);
        command.env("TERM", &launch.term);
        for (key, value) in &launch.extra_env {
            command.env(key, value);
        }
        if let Some(cwd) = launch.cwd.as_deref() {
            command.cwd(cwd);
        }
        let mut child = pty.slave.spawn_command(command)?;
        let pid = child.process_id();
        drop(pty.slave);
        let killer = child.clone_killer();
        let pty_poll_fd = pty.master.as_raw_fd().context("open terminal-host PTY poll fd")?;
        let mut pty_reader = pty.master.try_clone_reader()?;
        let pty_writer = pty.master.take_writer()?;
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
        term.replace_default_colors(
            launch.default_colors.fg,
            launch.default_colors.bg,
            launch.default_colors.cursor,
        );
        term.set_default_palette(&launch.default_colors.palette);
        replace_ghostty_cursor_defaults(&mut term, launch.default_colors);
        let initial_colors = term.color_overrides();
        let shared = Arc::new(HostShared {
            terminal_id: bootstrapped.terminal_id,
            incarnation: bootstrapped.incarnation,
            owner_token: bootstrapped.owner_token(),
            capabilities: CapabilityStore::new(64),
            term: Mutex::new(term),
            writer: Mutex::new(pty_writer),
            master: Mutex::new(pty.master),
            killer: Mutex::new(killer),
            pid,
            command: launch.command.clone(),
            cwd: launch.cwd.clone(),
            size: Mutex::new((launch.cols, launch.rows)),
            cell_pixels: Mutex::new((8, 16)),
            viewer_sizes: Mutex::new(HashMap::new()),
            taps: Mutex::new(HashMap::new()),
            broadcast_lock: Mutex::new(()),
            sequence: AtomicU64::new(0),
            next_client: AtomicU64::new(1),
            dead: AtomicBool::new(false),
            child_exit: (Mutex::new(false), Condvar::new()),
            child_waitable: AtomicBool::new(false),
            pty_drained: AtomicBool::new(false),
            exit_published: AtomicBool::new(false),
            force_pty_drain: AtomicBool::new(false),
            pty_drain_waker: Mutex::new(pty_drain_waker),
            termination_started: AtomicBool::new(false),
            child_signal_lock: Mutex::new(()),
            child_reaped: AtomicBool::new(false),
            group_escalation_complete: AtomicBool::new(false),
        });

        let reader_host = shared.clone();
        thread::Builder::new().name("terminal-host-pty".into()).spawn(move || {
            let mut buffer = [0u8; 64 * 1024];
            let mut last_colors = initial_colors;
            let mut last_pwd = None;
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
                    Err(_) => break,
                };
                let bytes = &buffer[..count];
                let title = {
                    let mut term = reader_host.term.lock().unwrap();
                    let cursor_activity = term
                        .cursor_activity()
                        .expect("valid host terminals expose cursor activity");
                    let bytes = term.vt_write_with_normalized(bytes).into_owned();
                    let title = title_changed
                        .swap(false, Ordering::AcqRel)
                        .then(|| term.title().unwrap_or_default());
                    let pwd = term.pwd();
                    // Snapshot registration takes the same parser lock. By
                    // publishing before releasing it, replay + live output is
                    // an atomic handoff with neither gaps nor duplicates.
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
                    reader_host.broadcast_frames(output_transition_frames(bytes, colors, pwd));
                    title
                };
                if let Some(title) = title {
                    reader_host.broadcast(MessageKind::Title, title.into_bytes());
                }
                if bell.swap(false, Ordering::AcqRel) {
                    reader_host.broadcast(MessageKind::Bell, Vec::new());
                }
                let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
                if !responses.is_empty() {
                    let mut writer = reader_host.writer.lock().unwrap();
                    let _ = writer.write_all(&responses);
                    let _ = writer.flush();
                }
            }
            // The reader publishes every final PTY byte before declaring the
            // stream drained. Exit is emitted only after this flag and the
            // child wait rendezvous, so clients can safely stop at Exit.
            reader_host.pty_drained.store(true, Ordering::Release);
            reader_host.child_exit.1.notify_all();
            reader_host.publish_exit_if_drained();
        })?;
        let child_host = shared.clone();
        thread::Builder::new().name("terminal-host-child".into()).spawn(move || {
            let observed_without_reaping = child_host
                .pid
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .is_some_and(|pid| wait_for_child_exit_without_reaping(pid).is_ok());
            if observed_without_reaping {
                child_host.child_waitable.store(true, Ordering::Release);
                child_host.child_exit.1.notify_all();
                loop {
                    let signal = child_host.child_signal_lock.lock().unwrap();
                    let escalation_complete =
                        child_host.group_escalation_complete.load(Ordering::Acquire);
                    let termination_started =
                        child_host.termination_started.load(Ordering::Acquire);
                    let pty_drained = child_host.pty_drained.load(Ordering::Acquire);
                    if escalation_complete || (!termination_started && pty_drained) {
                        let _ = child.wait();
                        child_host.child_reaped.store(true, Ordering::Release);
                        drop(signal);
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
                let mut exited = child_host.child_exit.0.lock().unwrap();
                *exited = true;
                drop(exited);
                child_host.child_exit.1.notify_all();
                child_host.publish_exit_if_drained();
            } else {
                // Native Unix PTYs always expose a PID and support waitid;
                // retain a conservative fallback for alternate backends.
                let _ = child.wait();
                child_host.child_reaped.store(true, Ordering::Release);
                child_host.child_waitable.store(true, Ordering::Release);
                let mut exited = child_host.child_exit.0.lock().unwrap();
                *exited = true;
                child_host.child_exit.1.notify_all();
                child_host.publish_exit_if_drained();
            }
        })?;
        Ok(shared)
    }

    fn serve_client(host: Arc<HostShared>, mut stream: UnixStream) -> anyhow::Result<()> {
        let hello_frame = read_required_frame(&mut stream, "client hello")?;
        if hello_frame.kind != MessageKind::ClientHello
            || hello_frame.sequence != 0
            || hello_frame.flags & !FLAG_VIEWER_SIZE_ACKS != 0
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
        let viewer_size_acks = hello_frame.flags & FLAG_VIEWER_SIZE_ACKS != 0
            && granted_rights.contains(CapabilityRights::RESIZE);
        let mut hello_response = Frame::new(MessageKind::HostHello, response.encode());
        if viewer_size_acks {
            hello_response.flags = FLAG_VIEWER_SIZE_ACKS;
        }
        hello_response.request_id = hello_frame.request_id;
        write_frame(&mut stream, &hello_response)?;

        let client = host.next_client.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = sync_channel(256);
        let tap = HostTap {
            sender,
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            shutdown: Arc::new(stream.try_clone()?),
            max_queued_bytes: MAX_HOST_CLIENT_QUEUED_BYTES,
        };
        let command_sender = tap.clone();
        let (snapshot, colors, snapshot_sequence) = {
            // Viewer registration follows the same viewer -> parser ->
            // broadcast lock order as resize application. This makes the
            // initial snapshot an atomic member of size arbitration too.
            let mut viewer_sizes = host.viewer_sizes.lock().unwrap();
            let mut term = host.term.lock().unwrap();
            let replay = term.vt_replay_bounded_theme_portable_with_aliases(
                crate::surface::VT_REPLAY_MAX_BYTES,
            )?;
            let colors = term.color_overrides();
            let (cols, rows) = (term.cols(), term.rows());
            let _broadcast = host.broadcast_lock.lock().unwrap();
            if host.dead.load(Ordering::Acquire) {
                anyhow::bail!("terminal host exited before snapshot");
            }
            // A renderer needs an initial reservation until it reports its
            // measured grid. Admin and read-only mirror connections are
            // management/observation channels and must never pin the PTY to
            // the snapshot size merely by connecting.
            if hello.role == ClientRole::Renderer
                && granted_rights.contains(CapabilityRights::RESIZE)
            {
                viewer_sizes.insert(client, (cols, rows));
            }
            host.taps.lock().unwrap().insert(client, tap.clone());
            (
                HostSnapshot {
                    cols,
                    rows,
                    replay: replay.bytes,
                    kitty_image_aliases: replay.kitty_image_aliases,
                    sequence_boundary: 0,
                    colors: colors.clone(),
                    pid: host.pid,
                    command: host.command.clone(),
                    cwd: snapshot_cwd(&term, host.cwd.as_deref()),
                },
                colors,
                host.sequence.load(Ordering::Acquire),
            )
        };
        let mut snapshot_frame = Frame::new(MessageKind::Snapshot, encode_snapshot(&snapshot)?);
        snapshot_frame.sequence = snapshot_sequence;
        if let Err(error) = write_frame(&mut stream, &snapshot_frame) {
            host.remove_client(client);
            return Err(error.into());
        }
        let mut colors_frame =
            Frame::new(MessageKind::Colors, encode_terminal_color_overrides(&colors));
        colors_frame.sequence = snapshot_sequence;
        if let Err(error) = write_frame(&mut stream, &colors_frame) {
            host.remove_client(client);
            return Err(error.into());
        }

        let mut command_stream = stream.try_clone()?;
        let command_host = host.clone();
        thread::Builder::new().name("terminal-host-client-input".into()).spawn(move || {
            while let Ok(Some(frame)) = read_frame(&mut command_stream, MAX_FRAME_PAYLOAD) {
                // Client-to-host messages currently define no flags and never
                // participate in the host live-stream sequence.
                if frame.version != selected_version || frame.flags != 0 || frame.sequence != 0 {
                    break;
                }
                match frame.kind {
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
                        let acknowledge_with_replay = targeted_ack.is_none();
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
                        command_host.request_termination();
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
                    MessageKind::MintCapability => {
                        if !granted_rights.contains(CapabilityRights::MINT_CAPABILITY) {
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
            command_sender.close();
            let _ = command_sender.try_send(Frame::new(MessageKind::ResyncRequired, Vec::new()));
            command_host.remove_client(client);
        })?;

        while let Ok(frame) = receiver.recv() {
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
        if output.len() > MAX_FRAME_PAYLOAD {
            anyhow::bail!("terminal-host snapshot payload is too large");
        }
        Ok(output)
    }

    #[cfg(test)]
    fn decode_snapshot(payload: &[u8]) -> anyhow::Result<HostSnapshot> {
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
        decoder.finish()?;
        Ok(HostSnapshot {
            cols,
            rows,
            replay,
            kitty_image_aliases,
            sequence_boundary: 0,
            colors: TerminalColorOverrides::default(),
            pid,
            command,
            cwd,
        })
    }

    fn validate_kitty_image_aliases(aliases: &[KittyImageAlias]) -> anyhow::Result<()> {
        if aliases.len() > MAX_KITTY_IMAGE_ALIASES {
            anyhow::bail!("terminal-host Kitty image alias count is too large");
        }
        // Repeated image numbers preserve Kitty's assignment history. Image
        // IDs remain unique identities within a snapshot.
        let mut image_ids = HashSet::with_capacity(aliases.len());
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

    fn encode_resize(
        cols: u16,
        rows: u16,
        replay: &[u8],
        kitty_image_aliases: &[KittyImageAlias],
    ) -> anyhow::Result<Vec<u8>> {
        let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
        if replay.len() > crate::surface::VT_REPLAY_MAX_BYTES {
            anyhow::bail!("terminal-host resize replay is too large");
        }
        let replay_len = u32::try_from(replay.len())
            .map_err(|_| anyhow::anyhow!("terminal-host resize replay exceeds u32"))?;
        let mut output = Vec::with_capacity(
            8 + replay.len()
                + KITTY_IMAGE_ALIAS_COUNT_LEN
                + kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN,
        );
        output.extend_from_slice(&cols.to_le_bytes());
        output.extend_from_slice(&rows.to_le_bytes());
        output.extend_from_slice(&replay_len.to_le_bytes());
        output.extend_from_slice(replay);
        encode_kitty_image_aliases(&mut output, kitty_image_aliases)?;
        if output.len() > MAX_FRAME_PAYLOAD {
            anyhow::bail!("terminal-host resize payload is too large");
        }
        Ok(output)
    }

    #[cfg(test)]
    pub(crate) fn decode_host_resize_payload(
        payload: &[u8],
    ) -> anyhow::Result<(u16, u16, Vec<u8>, Vec<KittyImageAlias>)> {
        decode_host_resize_payload_for_version(payload, PROTOCOL_VERSION)
    }

    pub(crate) fn decode_host_resize_payload_for_version(
        payload: &[u8],
        protocol_version: u16,
    ) -> anyhow::Result<(u16, u16, Vec<u8>, Vec<KittyImageAlias>)> {
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
        decoder.finish()?;
        Ok((cols, rows, replay, kitty_image_aliases))
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
            };
            let record_path = record.record_path(&root);
            let lease = HostLivenessLease::acquire(liveness_path(&record_path, &record)).unwrap();
            write_record(&record_path, &record).unwrap();
            (record_path, record, lease)
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
                scrollback: 10_000,
                cwd: Some("/tmp".into()),
                command: vec!["/bin/cat".into()],
                extra_env: vec![("KEY".into(), "value".into())],
                default_colors,
            };

            let decoded = HostLaunch::decode(&launch.encode().unwrap()).unwrap();
            assert_eq!(decoded.default_colors, default_colors);
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
        fn resized_payload_is_length_prefixed_for_cross_language_clients() {
            assert_eq!(
                encode_resize(0x0123, 0x0456, &[0xaa, 0xbb, 0xcc], &[]).unwrap(),
                vec![0x23, 0x01, 0x56, 0x04, 3, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0, 0]
            );
        }

        #[test]
        fn snapshot_payload_round_trip_preserves_kitty_image_alias_section() {
            let snapshot = HostSnapshot {
                cols: 80,
                rows: 24,
                replay: b"theme-portable replay".to_vec(),
                kitty_image_aliases: vec![
                    KittyImageAlias { image_id: 41, image_number: 77 },
                    KittyImageAlias { image_id: 42, image_number: 77 },
                ],
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
            assert_eq!(
                encode_snapshot(&decoded).unwrap(),
                payload,
                "snapshot encode/decode dropped Kitty image-number aliases"
            );
        }

        #[test]
        fn protocol_one_snapshot_and_resize_decode_without_alias_tails() {
            let snapshot = HostSnapshot {
                cols: 80,
                rows: 24,
                replay: b"legacy replay".to_vec(),
                kitty_image_aliases: Vec::new(),
                sequence_boundary: 0,
                colors: TerminalColorOverrides::default(),
                pid: Some(42),
                command: vec!["/bin/cat".into()],
                cwd: Some("/tmp".into()),
            };
            let mut snapshot_payload = encode_snapshot(&snapshot).unwrap();
            snapshot_payload.truncate(snapshot_payload.len() - KITTY_IMAGE_ALIAS_COUNT_LEN);
            let decoded =
                decode_snapshot_for_version(&snapshot_payload, LEGACY_PROTOCOL_VERSION).unwrap();
            assert_eq!(decoded.replay, snapshot.replay);
            assert!(decoded.kitty_image_aliases.is_empty());

            let mut resize_payload = encode_resize(81, 25, b"legacy resize", &[]).unwrap();
            resize_payload.truncate(resize_payload.len() - KITTY_IMAGE_ALIAS_COUNT_LEN);
            assert_eq!(
                decode_host_resize_payload_for_version(&resize_payload, LEGACY_PROTOCOL_VERSION,)
                    .unwrap(),
                (81, 25, b"legacy resize".to_vec(), Vec::new())
            );
        }

        #[test]
        fn resize_alias_section_preserves_number_history_and_rejects_malformed_data() {
            let alias = KittyImageAlias { image_id: 41, image_number: 77 };
            let valid = encode_resize(80, 24, b"replay", &[alias]).unwrap();
            assert_eq!(
                decode_host_resize_payload(&valid).unwrap(),
                (80, 24, b"replay".to_vec(), vec![alias])
            );

            let alias_offset = 8 + b"replay".len();
            let mut zero_id = valid.clone();
            zero_id[alias_offset + 2..alias_offset + 6].fill(0);
            assert!(decode_host_resize_payload(&zero_id).is_err());

            let duplicate_aliases = [
                KittyImageAlias { image_id: 41, image_number: 77 },
                KittyImageAlias { image_id: 42, image_number: 77 },
            ];
            let duplicate_numbers = encode_resize(80, 24, b"replay", &duplicate_aliases).unwrap();
            assert_eq!(
                decode_host_resize_payload(&duplicate_numbers).unwrap(),
                (80, 24, b"replay".to_vec(), duplicate_aliases.to_vec())
            );

            let mut truncated = valid.clone();
            truncated.pop();
            assert!(decode_host_resize_payload(&truncated).is_err());

            let mut trailing = valid;
            trailing.push(0);
            assert!(decode_host_resize_payload(&trailing).is_err());

            let mut excessive = vec![80, 0, 24, 0, 0, 0, 0, 0];
            excessive.extend_from_slice(&((MAX_KITTY_IMAGE_ALIASES + 1) as u16).to_le_bytes());
            assert!(decode_host_resize_payload(&excessive).is_err());
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
            let stalled = thread::spawn(move || {
                let (_stream, _) = listener.accept().unwrap();
                thread::sleep(Duration::from_millis(200));
            });

            let started = Instant::now();
            assert!(
                connect_record_with_timeout(
                    record.clone(),
                    record_path.clone(),
                    Duration::from_millis(30),
                )
                .is_err()
            );
            assert!(started.elapsed() < Duration::from_secs(1));
            stalled.join().unwrap();
            let _ = fs::remove_file(endpoint);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
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
                let (mut first, _) = listener.accept().unwrap();
                let first_hello = read_required_frame(&mut first, "current-version hello").unwrap();
                assert_eq!(first_hello.kind, MessageKind::ClientHello);
                assert_eq!(first_hello.version, PROTOCOL_VERSION);
                drop(first);

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
                    replay: host_replay,
                    kitty_image_aliases: Vec::new(),
                    sequence_boundary: 0,
                    colors: TerminalColorOverrides::default(),
                    pid: Some(42),
                    command: vec!["/bin/cat".into()],
                    cwd: Some("/tmp".into()),
                };
                let mut payload = encode_snapshot(&snapshot).unwrap();
                payload.truncate(payload.len() - KITTY_IMAGE_ALIAS_COUNT_LEN);
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
        fn host_tap_byte_overflow_closes_the_client_socket() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, _receiver) = sync_channel(8);
            let one_frame = crate::terminal_host_protocol::HEADER_LEN + 4;
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: one_frame,
            };

            assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1; 4])));
            assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2])));
            let mut byte = [0u8; 1];
            assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
        }

        #[test]
        fn host_tap_channel_overflow_closes_the_client_socket() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, _receiver) = sync_channel(1);
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };

            assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1])));
            assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2])));
            let mut byte = [0u8; 1];
            assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
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
                let (sender, receiver) = sync_channel(8);
                let tap = HostTap {
                    sender,
                    queued_bytes: Arc::new(AtomicUsize::new(0)),
                    shutdown: Arc::new(host_socket),
                    max_queued_bytes: usize::MAX,
                };
                let broadcast_lock = Mutex::new(());
                let sequence = AtomicU64::new(0);
                let taps = Mutex::new(HashMap::from([(1, tap)]));
                let child_exited = Mutex::new(false);
                let pty_drained = AtomicBool::new(false);
                let exit_published = AtomicBool::new(false);

                if child_first {
                    *child_exited.lock().unwrap() = true;
                    assert!(!claim_host_exit_after_drain(
                        &child_exited,
                        &pty_drained,
                        &exit_published,
                    ));
                }

                publish_host_frames(
                    &broadcast_lock,
                    &sequence,
                    &taps,
                    [Frame::new(MessageKind::Output, b"final-output".to_vec())],
                );
                pty_drained.store(true, Ordering::Release);

                if !child_first {
                    assert!(!claim_host_exit_after_drain(
                        &child_exited,
                        &pty_drained,
                        &exit_published,
                    ));
                    *child_exited.lock().unwrap() = true;
                }
                assert!(claim_host_exit_after_drain(&child_exited, &pty_drained, &exit_published,));
                publish_host_frames(
                    &broadcast_lock,
                    &sequence,
                    &taps,
                    [Frame::new(MessageKind::Exit, Vec::new())],
                );
                assert!(
                    !claim_host_exit_after_drain(&child_exited, &pty_drained, &exit_published,)
                );

                let frames = receiver.try_iter().collect::<Vec<_>>();
                assert_eq!(frames.len(), 2);
                assert_eq!(frames[0].kind, MessageKind::Output);
                assert_eq!(frames[0].payload, b"final-output");
                assert_eq!(frames[0].sequence, 1);
                assert_eq!(frames[1].kind, MessageKind::Exit);
                assert_eq!(frames[1].sequence, 2);
            }
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
                thread::sleep(Duration::from_millis(20));
                worker_force.store(true, Ordering::Release);
                drain_waker.write_all(&[1]).unwrap();
                thread::sleep(Duration::from_millis(20));
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
            let (sender, receiver) = sync_channel(8);
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };
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
            let (sender, receiver) = sync_channel(8);
            let tap = HostTap {
                sender,
                queued_bytes: Arc::new(AtomicUsize::new(0)),
                shutdown: Arc::new(host_socket),
                max_queued_bytes: usize::MAX,
            };
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
pub(crate) use unix::decode_host_resize_payload_for_version;
#[cfg(unix)]
pub use unix::{
    HostAttachment, adopt_terminal_host, isolate_terminal_host_process_fds, launch_terminal_host,
    launch_terminal_host_with_identity, load_terminal_host_records,
    remove_stale_terminal_host_record, serve_terminal_host_stdio, terminal_host_record_liveness,
    terminal_host_root, validate_terminal_host_record,
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
