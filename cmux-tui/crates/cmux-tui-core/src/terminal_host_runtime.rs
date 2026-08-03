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
    FLAG_COLORS_FOLLOW, FLAG_TERMINATE_ONLY, FLAG_VIEWER_SIZE_ACKS, Frame,
    KITTY_IMAGE_ALIAS_COUNT_LEN, KITTY_IMAGE_ALIAS_ENCODED_LEN, MAX_FRAME_PAYLOAD,
    MAX_KITTY_IMAGE_ALIASES, MessageKind, PROTOCOL_VERSION, RESIZE_ACK_CANONICAL_CHANGED,
    TerminalExit, encode_terminal_exit, read_frame, write_frame,
};

const HOST_RECORD_VERSION: u32 = 2;
const LEGACY_PROTOCOL_VERSION: u16 = 1;
const HOST_EXIT_RECORD_VERSION: u32 = 1;
const MAX_LAUNCH_PAYLOAD: usize = 1024 * 1024;
const MAX_STRING: usize = 256 * 1024;
const MAX_BLOB: usize = crate::surface::VT_REPLAY_MAX_BYTES;
const MAX_ARGV: usize = 256;
const MAX_ENV: usize = 1024;
const MAX_RENDERER_CAPABILITY_TTL: std::time::Duration = std::time::Duration::from_secs(60);
pub(crate) const CONTROL_RESPONSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
const HOST_HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
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
    /// Additive handshake capability. Missing/false records require the
    /// compatibility adoption path, which materializes a full Snapshot.
    #[serde(default)]
    pub supports_terminate_only: bool,
    /// Additive control capability. Missing/false records belong to legacy
    /// hosts and must never receive the unknown ClearHistory message.
    #[serde(default)]
    pub supports_clear_history: bool,
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
            .field("supports_terminate_only", &self.supports_terminate_only)
            .field("supports_clear_history", &self.supports_clear_history)
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
    use std::collections::{HashMap, HashSet};
    use std::ffi::CString;
    use std::fs::{self, File, OpenOptions};
    use std::io as std_io;
    use std::io::{Read, Write};
    #[cfg(all(test, target_os = "linux"))]
    use std::mem::{offset_of, size_of};
    use std::os::fd::{AsRawFd, RawFd};
    #[cfg(all(test, target_os = "linux"))]
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    #[cfg(test)]
    use std::os::unix::net::UnixListener;
    use std::os::unix::net::UnixStream;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::mpsc::{
        Receiver, RecvTimeoutError, Sender, SyncSender, TrySendError, channel as mpsc_channel,
        sync_channel,
    };
    use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
    use std::thread;
    use std::time::{Duration, Instant};

    use anyhow::Context;
    use cmux_pty::PtyCommand;
    use ghostty_vt::{Callbacks, CursorShape, Terminal};
    use portable_pty::{ChildKiller, MasterPty, PtySize};

    use super::*;

    static RECORD_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);
    const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);
    const HOST_KILL_WAIT: Duration = Duration::from_secs(2);
    const HOST_PTY_DRAIN_GRACE: Duration = Duration::from_millis(250);
    const HOST_FORCED_DRAIN_WINDOW: Duration = Duration::from_millis(100);
    const HOST_CLIENT_EXIT_DRAIN: Duration = Duration::from_secs(1);
    const HOST_LAUNCH_ROLLBACK_WAIT: Duration = Duration::from_secs(4);
    const HOST_LAUNCH_TIMEOUT: Duration = Duration::from_secs(10);
    const HOST_LAUNCH_CANCEL_POLL: Duration = Duration::from_millis(25);
    const HOST_LAUNCH_OWNER_TIMEOUT: Duration = Duration::from_secs(5);
    const HOST_PROCESS_REAPER_CAPACITY: usize = 4_096;
    const HOST_PROCESS_REAPER_POLL: Duration = Duration::from_millis(25);
    const HOST_PROCESS_REAPER_RETRY_MAX: Duration = Duration::from_secs(1);
    const MAX_TERMINAL_HOST_RECORD_BYTES: usize = MAX_LAUNCH_PAYLOAD;
    const MAX_TERMINAL_HOST_RECORDS: usize = 4_096;
    const MAX_TERMINAL_HOST_CLIENTS: usize = 64;
    const TERMINAL_HOST_RECORD_SCAN_TIMEOUT: Duration = Duration::from_secs(2);
    static HOST_PROCESS_REAPER: OnceLock<Mutex<Option<HostProcessReaper>>> = OnceLock::new();
    #[cfg(test)]
    static HOST_REAP_TEST_LOCK: Mutex<()> = Mutex::new(());
    #[cfg(test)]
    static NEXT_HOST_NORMAL_CLEANUP_FAILURES: AtomicUsize = AtomicUsize::new(0);

    #[cfg(not(test))]
    fn host_forced_drain_window() -> Duration {
        HOST_FORCED_DRAIN_WINDOW
    }

    #[cfg(test)]
    fn host_forced_drain_window() -> Duration {
        crate::test_timeout(HOST_FORCED_DRAIN_WINDOW)
    }
    #[cfg(test)]
    static NEXT_HOST_PROCESS_REAPER_SPAWN_FAILURES: AtomicUsize = AtomicUsize::new(0);
    #[cfg(test)]
    static HOST_PROCESS_INLINE_WAITS: AtomicUsize = AtomicUsize::new(0);
    #[cfg(test)]
    static HOST_CHILD_OBSERVER_SPAWNS: AtomicUsize = AtomicUsize::new(0);

    struct HostProcessReaper {
        sender: Sender<HostProcessReapRequest>,
        active: Arc<AtomicUsize>,
        _worker: thread::JoinHandle<()>,
    }

    struct HostProcessReaperLease {
        sender: Sender<HostProcessReapRequest>,
        active: Arc<AtomicUsize>,
        #[cfg(test)]
        completion: Option<Sender<()>>,
    }

    impl Drop for HostProcessReaperLease {
        fn drop(&mut self) {
            self.active.fetch_sub(1, Ordering::AcqRel);
            #[cfg(test)]
            if let Some(completion) = self.completion.take() {
                let _ = completion.send(());
            }
        }
    }

    struct HostProcessReapRequest {
        child: std::process::Child,
        _lease: HostProcessReaperLease,
        next_attempt: Instant,
        retry_delay: Duration,
    }

    impl HostProcessReaper {
        fn start() -> std::io::Result<Self> {
            let (sender, receiver) = std::sync::mpsc::channel();
            let active = Arc::new(AtomicUsize::new(0));
            let worker = spawn_host_process_reaper_worker(receiver)?;
            Ok(Self { sender, active, _worker: worker })
        }

        fn lease(&self) -> std::io::Result<HostProcessReaperLease> {
            self.active
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                    (active < HOST_PROCESS_REAPER_CAPACITY).then_some(active + 1)
                })
                .map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::WouldBlock,
                        "terminal-host process reaper capacity exhausted",
                    )
                })?;
            Ok(HostProcessReaperLease {
                sender: self.sender.clone(),
                active: self.active.clone(),
                #[cfg(test)]
                completion: None,
            })
        }
    }

    fn reserve_host_process_reaper() -> std::io::Result<HostProcessReaperLease> {
        let mut slot = HOST_PROCESS_REAPER.get_or_init(|| Mutex::new(None)).lock().unwrap();
        if slot.is_none() {
            *slot = Some(HostProcessReaper::start()?);
        }
        slot.as_ref().expect("terminal-host process reaper initialized").lease()
    }

    fn spawn_host_process_reaper_worker(
        receiver: Receiver<HostProcessReapRequest>,
    ) -> std::io::Result<thread::JoinHandle<()>> {
        #[cfg(test)]
        if NEXT_HOST_PROCESS_REAPER_SPAWN_FAILURES
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| remaining.checked_sub(1))
            .is_ok()
        {
            return Err(std::io::Error::other("forced terminal-host reaper spawn failure"));
        }
        thread::Builder::new()
            .name("terminal-host-process-reaper".into())
            .spawn(move || run_host_process_reaper(receiver))
    }

    fn run_host_process_reaper(receiver: Receiver<HostProcessReapRequest>) {
        let mut pending = Vec::<HostProcessReapRequest>::new();
        loop {
            let received = if pending.is_empty() {
                receiver.recv().map_err(|_| RecvTimeoutError::Disconnected)
            } else {
                let now = Instant::now();
                let wait = pending
                    .iter()
                    .map(|request| request.next_attempt.saturating_duration_since(now))
                    .min()
                    .unwrap_or(HOST_PROCESS_REAPER_POLL);
                receiver.recv_timeout(wait)
            };
            match received {
                Ok(request) => pending.push(request),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) if pending.is_empty() => return,
                Err(RecvTimeoutError::Disconnected) => {}
            }
            pending.extend(receiver.try_iter());

            let now = Instant::now();
            let mut index = 0;
            while index < pending.len() {
                if pending[index].next_attempt > now {
                    index += 1;
                    continue;
                }
                match pending[index].child.try_wait() {
                    Ok(Some(_)) => {
                        pending.swap_remove(index);
                    }
                    Ok(None) => {
                        let retry = pending[index].retry_delay;
                        pending[index].next_attempt = now + retry;
                        pending[index].retry_delay =
                            retry.saturating_mul(2).min(HOST_PROCESS_REAPER_RETRY_MAX);
                        index += 1;
                    }
                    Err(_) => {
                        let retry = pending[index].retry_delay;
                        pending[index].next_attempt = now + retry;
                        pending[index].retry_delay =
                            retry.saturating_mul(2).min(HOST_PROCESS_REAPER_RETRY_MAX);
                        index += 1;
                    }
                }
            }
        }
    }

    fn enqueue_host_process_reaper(lease: HostProcessReaperLease, child: std::process::Child) {
        let sender = lease.sender.clone();
        sender
            .send(HostProcessReapRequest {
                child,
                _lease: lease,
                next_attempt: Instant::now(),
                retry_delay: HOST_PROCESS_REAPER_POLL,
            })
            .expect("terminal-host process reaper remains alive while registered");
    }
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
        reaper: Option<HostProcessReaperLease>,
    }

    impl SpawnedHostProcess {
        fn with_reaper(
            child: std::process::Child,
            reaper: HostProcessReaperLease,
        ) -> SpawnedHostProcess {
            Self { child: Some(child), reaper: Some(reaper) }
        }

        #[cfg(test)]
        fn new_for_test(child: std::process::Child) -> (Self, Receiver<()>) {
            let mut reaper = reserve_host_process_reaper().unwrap();
            let (completion, completed) = std::sync::mpsc::channel();
            reaper.completion = Some(completion);
            (Self::with_reaper(child, reaper), completed)
        }

        fn child_mut(&mut self) -> &mut std::process::Child {
            self.child.as_mut().expect("terminal-host child is present")
        }

        fn wait_timeout(&mut self, timeout: Duration) -> bool {
            let deadline = Instant::now() + timeout;
            loop {
                let Some(child) = self.child.as_mut() else { return true };
                match child.try_wait() {
                    Ok(Some(_)) => {
                        self.child.take();
                        self.reaper.take();
                        return true;
                    }
                    Ok(None) if Instant::now() < deadline => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Ok(None) | Err(_) => return false,
                }
            }
        }

        fn detach_reaper(mut self) {
            let Some(child) = self.child.take() else { return };
            let reaper =
                self.reaper.take().expect("spawned terminal host retains its reaper reservation");
            enqueue_host_process_reaper(reaper, child);
        }
    }

    impl Drop for SpawnedHostProcess {
        fn drop(&mut self) {
            let Some(mut child) = self.child.take() else { return };
            let _ = child.kill();
            let reaper =
                self.reaper.take().expect("spawned terminal host retains its reaper reservation");
            enqueue_host_process_reaper(reaper, child);
        }
    }

    struct PublishedHostRecovery {
        process: Option<SpawnedHostProcess>,
        record_path: PathBuf,
        terminal_id: String,
        incarnation: String,
        owner_token: String,
        host_pid: u32,
    }

    impl PublishedHostRecovery {
        fn new(
            process: SpawnedHostProcess,
            record_path: PathBuf,
            terminal_id: String,
            incarnation: HostIncarnation,
            owner_token: CapabilityToken,
            host_pid: u32,
        ) -> Self {
            Self {
                process: Some(process),
                record_path,
                terminal_id,
                incarnation: incarnation.to_hex(),
                owner_token: encode_hex(owner_token.as_bytes()),
                host_pid,
            }
        }

        fn commit(mut self) -> SpawnedHostProcess {
            self.process.take().expect("published terminal-host process is present")
        }

        fn matching_record(&self) -> Option<TerminalHostRecord> {
            let record: TerminalHostRecord =
                serde_json::from_slice(&fs::read(&self.record_path).ok()?).ok()?;
            validate_terminal_host_record(&self.record_path, &record).ok()?;
            (record.terminal_id == self.terminal_id
                && record.incarnation == self.incarnation
                && record.owner_token == self.owner_token
                && record.host_pid == self.host_pid)
                .then_some(record)
        }

        fn reconcile(&mut self) {
            let Some(process) = self.process.take() else { return };
            let Some(record) = self.matching_record() else {
                // Publication was not proven, so the exact spawned process
                // remains the only safe cleanup target.
                drop(process);
                return;
            };

            // The authenticated durable record now owns PTY cleanup. Never
            // exact-kill the host after this handoff because its child runs
            // in a separate session and may ignore terminal hangup.
            process.detach_reaper();
            if let Ok(attachment) = connect_record(record, self.record_path.clone()) {
                let _ = attachment.terminate();
                attachment.disconnect();
            }
        }
    }

    impl Drop for PublishedHostRecovery {
        fn drop(&mut self) {
            self.reconcile();
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

        pub(crate) fn resolve(&self, frame: &Frame) -> bool {
            let waiter = self.waiters.lock().unwrap().remove(&frame.request_id);
            match waiter {
                Some(ControlResponseWaiter::Blocking { kind, sender }) => {
                    if kind != frame.kind {
                        return false;
                    }
                    if frame.kind == MessageKind::CellPixelSizeAck {
                        self.latest_cell_pixel_ack.fetch_max(frame.request_id, Ordering::AcqRel);
                    }
                    let _ = sender.try_send(frame.clone());
                    true
                }
                Some(ControlResponseWaiter::DeferredCellPixel { expected }) => {
                    if frame.kind != MessageKind::CellPixelSizeAck {
                        return false;
                    }
                    self.latest_cell_pixel_ack.fetch_max(frame.request_id, Ordering::AcqRel);
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
                .send_control_request_until(
                    MessageKind::SetKittyGraphicsLimits,
                    MessageKind::KittyGraphicsLimitsAck,
                    payload,
                    deadline,
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

        pub fn terminate(&self) -> std::io::Result<()> {
            self.send(MessageKind::Terminate, &[])
        }

        pub(crate) fn terminate_until(&self, deadline: Instant) -> std::io::Result<()> {
            let mut writer = self.writer.lock().unwrap();
            let frame = Frame::new(MessageKind::Terminate, Vec::new());
            let result = write_frame(&mut DeadlineStream::new(&mut writer, deadline), &frame)
                .map_err(protocol_io_error);
            if result.is_err() {
                let _ = writer.shutdown(std::net::Shutdown::Both);
            }
            result
        }

        pub fn disconnect(&self) {
            let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
        }

        /// Commit the launch ownership handoff after every fallible Surface
        /// setup step succeeds. Until then, dropping this attachment asks the
        /// host to exit, exact-kills it after the bounded rollback window, and
        /// transfers the remaining wait to the shared process reaper.
        pub(crate) fn commit_launched_host(&mut self) {
            let Some(process) = self.launch_process.take() else { return };
            process.detach_reaper();
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
                    self.disconnect();
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
            if process.wait_timeout(HOST_LAUNCH_ROLLBACK_WAIT) {
                return;
            }
            drop(process);
        }
    }

    pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
        state_root.join(format!("terminal-hosts-{}", stable_token(session)))
    }

    fn terminal_host_publication_descriptor(args: &[String]) -> anyhow::Result<Option<RawFd>> {
        if args.first().map(String::as_str) != Some("--bootstrap-stdio") {
            anyhow::bail!("hidden mode requires --bootstrap-stdio");
        }
        match &args[1..] {
            [] => Ok(None),
            [flag, descriptor] if flag == "--publication-fd" => descriptor
                .parse::<RawFd>()
                .ok()
                .filter(|descriptor| *descriptor > libc::STDERR_FILENO)
                .map(Some)
                .ok_or_else(|| anyhow::anyhow!("terminal-host publication descriptor is invalid")),
            _ => anyhow::bail!("hidden mode received unsupported arguments"),
        }
    }

    /// Strip every descriptor except the private bootstrap stdio and the
    /// explicitly inherited publication guard before the hidden host starts
    /// any threads or opens its endpoint. This runs inside the freshly exec'd
    /// `__terminal-host`, so descriptor enumeration is race-free and cannot
    /// affect the daemon's own open files.
    pub fn isolate_terminal_host_process_fds(args: &[String]) -> anyhow::Result<()> {
        let publication_descriptor = terminal_host_publication_descriptor(args)?;
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
            if Some(descriptor) == publication_descriptor {
                continue;
            }
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
        launch_terminal_host_cancellable(
            options,
            root,
            default_colors,
            cell_pixels,
            kitty_graphics_limits,
            &|| false,
        )
    }

    pub(crate) fn launch_terminal_host_cancellable(
        options: &SurfaceOptions,
        root: &Path,
        default_colors: DefaultColors,
        cell_pixels: (u16, u16),
        kitty_graphics_limits: KittyGraphicsLimits,
        cancelled: &dyn Fn() -> bool,
    ) -> anyhow::Result<HostAttachment> {
        let terminal_id = TerminalId::random()?;
        let publication_guard = acquire_terminal_host_publication(root, &terminal_id.to_hex())?;
        launch_terminal_host_with_identity_cancellable(
            options,
            root,
            default_colors,
            cell_pixels,
            kitty_graphics_limits,
            (terminal_id, publication_guard),
            cancelled,
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
        let publication_guard = acquire_terminal_host_publication(root, &terminal_id.to_hex())?;
        launch_terminal_host_with_identity_cancellable(
            options,
            root,
            default_colors,
            cell_pixels,
            kitty_graphics_limits,
            (terminal_id, publication_guard),
            &|| false,
        )
    }

    pub(crate) fn launch_terminal_host_with_identity_cancellable(
        options: &SurfaceOptions,
        root: &Path,
        default_colors: DefaultColors,
        cell_pixels: (u16, u16),
        kitty_graphics_limits: KittyGraphicsLimits,
        ownership: (TerminalId, crate::PublicationGuard),
        cancelled: &dyn Fn() -> bool,
    ) -> anyhow::Result<HostAttachment> {
        let (terminal_id, publication_guard) = ownership;
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
        anyhow::ensure!(
            publication_guard.target() == record_path,
            "terminal-host publication ownership has the wrong target"
        );
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
        let publication_descriptor = publication_guard.inherit_into(&mut command);
        command.args(["--publication-fd", &publication_descriptor.to_string()]);
        let reaper = reserve_host_process_reaper()
            .context("reserve bounded terminal-host process cleanup")?;
        let child = cmux_tui_process::spawn(&mut command).context("spawn terminal-host process")?;
        let mut process = SpawnedHostProcess::with_reaper(child, reaper);
        let host_pid = process.child_mut().id();
        let stdin =
            process.child_mut().stdin.take().context("open terminal-host bootstrap stdin")?;
        let stdout =
            process.child_mut().stdout.take().context("open terminal-host bootstrap stdout")?;
        set_nonblocking(stdin.as_raw_fd())?;
        let launch_deadline = Instant::now() + HOST_LAUNCH_TIMEOUT;
        let mut stdin =
            CancellableHostWriter { writer: stdin, deadline: launch_deadline, cancelled };
        let mut stdout =
            CancellableHostReader { reader: stdout, deadline: launch_deadline, cancelled };

        let bootstrap = HostBootstrap {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            terminal_id,
            owner_token,
        };
        write_frame(&mut stdin, &bootstrap.into_frame(1))?;
        let ready_frame = match read_required_frame(&mut stdout, "bootstrap ready") {
            Ok(frame) => frame,
            Err(error) => {
                if cancelled() && record_path.exists() {
                    // Publication transfers PTY ownership to the durable
                    // record. Keep that host discoverable so the shutdown
                    // coordinator can terminate it through the authenticated
                    // endpoint instead of killing the host and orphaning its
                    // shell.
                    process.detach_reaper();
                }
                return Err(error);
            }
        };
        if ready_frame.kind != MessageKind::Ready {
            anyhow::bail!("terminal host returned {:?} instead of Ready", ready_frame.kind);
        }
        let ready = HostReady::decode(&ready_frame.payload)?;
        if ready.terminal_id != terminal_id {
            anyhow::bail!("terminal host changed terminal identity during bootstrap");
        }

        let launch_recovery = PublishedHostRecovery::new(
            process,
            record_path.clone(),
            terminal_hex.clone(),
            ready.incarnation,
            owner_token,
            host_pid,
        );
        let mut launch_frame = Frame::new(MessageKind::Launch, launch.encode()?);
        launch_frame.request_id = 2;
        write_frame(&mut stdin, &launch_frame)?;
        // Integration synchronization seam for cancellation after the host
        // has published its durable record but before the launcher consumes
        // Ready. The host remains free to serve authenticated termination.
        if let Some(barrier) = std::env::var_os("CMUX_TUI_TEST_LAUNCH_ACK_BARRIER") {
            let barrier = PathBuf::from(barrier);
            while !record_path.exists() && !cancelled() && Instant::now() < launch_deadline {
                thread::sleep(Duration::from_millis(5));
            }
            if record_path.exists() {
                fs::write(&barrier, b"published")?;
                while barrier.exists() && !cancelled() && Instant::now() < launch_deadline {
                    thread::sleep(Duration::from_millis(5));
                }
            }
        }
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
        attachment.launch_process = Some(launch_recovery.commit());
        if cancelled() {
            drop(attachment);
            anyhow::bail!("terminal host launch cancelled because the server is shutting down");
        }
        Ok(attachment)
    }

    fn set_nonblocking(descriptor: RawFd) -> std::io::Result<()> {
        // SAFETY: F_GETFL reads flags from the valid owned pipe descriptor.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
        if flags < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if flags & libc::O_NONBLOCK != 0 {
            return Ok(());
        }
        // SAFETY: F_SETFL updates status flags on the same valid descriptor.
        if unsafe { libc::fcntl(descriptor, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }

    struct CancellableHostWriter<'a, W> {
        writer: W,
        deadline: Instant,
        cancelled: &'a dyn Fn() -> bool,
    }

    impl<W: Write + AsRawFd> Write for CancellableHostWriter<'_, W> {
        fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            loop {
                if (self.cancelled)() {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::ConnectionAborted,
                        "terminal host launch cancelled during server shutdown",
                    ));
                }
                let Some(remaining) = self.deadline.checked_duration_since(Instant::now()) else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "terminal host launch timed out",
                    ));
                };
                let wait = remaining.min(HOST_LAUNCH_CANCEL_POLL);
                let timeout_ms = wait.as_millis().max(1).min(i32::MAX as u128) as i32;
                let mut descriptor = libc::pollfd {
                    fd: self.writer.as_raw_fd(),
                    events: libc::POLLOUT | libc::POLLHUP,
                    revents: 0,
                };
                let result = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
                if result > 0 {
                    if descriptor.revents & libc::POLLNVAL != 0 {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::BrokenPipe,
                            "terminal host bootstrap pipe became invalid",
                        ));
                    }
                    match self.writer.write(buffer) {
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                            ) =>
                        {
                            continue;
                        }
                        result => return result,
                    }
                }
                if result == 0 {
                    continue;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.writer.flush()
        }
    }

    struct CancellableHostReader<'a, R> {
        reader: R,
        deadline: Instant,
        cancelled: &'a dyn Fn() -> bool,
    }

    impl<R: Read + AsRawFd> Read for CancellableHostReader<'_, R> {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            loop {
                if (self.cancelled)() {
                    return Err(std::io::Error::new(
                        // `Read::read_exact` transparently retries
                        // `Interrupted`, so cancellation needs a terminal
                        // error kind to release the surface-creation permit.
                        std::io::ErrorKind::ConnectionAborted,
                        "terminal host launch cancelled during server shutdown",
                    ));
                }
                let Some(remaining) = self.deadline.checked_duration_since(Instant::now()) else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "terminal host launch timed out",
                    ));
                };
                let wait = remaining.min(HOST_LAUNCH_CANCEL_POLL);
                let timeout_ms = wait.as_millis().max(1).min(i32::MAX as u128) as i32;
                let mut descriptor = libc::pollfd {
                    fd: self.reader.as_raw_fd(),
                    events: libc::POLLIN | libc::POLLHUP,
                    revents: 0,
                };
                let result = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
                if result > 0 {
                    if descriptor.revents & libc::POLLNVAL != 0 {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::BrokenPipe,
                            "terminal host bootstrap pipe became invalid",
                        ));
                    }
                    return self.reader.read(buffer);
                }
                if result == 0 {
                    continue;
                }
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
    }

    pub fn adopt_terminal_host(
        record: TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<HostAttachment> {
        validate_terminal_host_record(&record_path, &record)?;
        connect_record(record, record_path)
    }

    pub(crate) fn adopt_terminal_host_until(
        record: TerminalHostRecord,
        record_path: PathBuf,
        deadline: Instant,
    ) -> anyhow::Result<HostAttachment> {
        validate_terminal_host_record(&record_path, &record)?;
        connect_record_until(record, record_path, deadline)
    }

    #[cfg(test)]
    pub(crate) fn terminate_terminal_host_with_timeout(
        record: &TerminalHostRecord,
        record_path: &Path,
        timeout: Duration,
    ) -> anyhow::Result<()> {
        terminate_terminal_host_until(record, record_path, Instant::now() + timeout)
    }

    fn terminate_terminal_host_until(
        record: &TerminalHostRecord,
        record_path: &Path,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        validate_terminal_host_record(record_path, record)?;
        if !record.supports_terminate_only {
            anyhow::bail!("terminal host does not advertise terminate-only handshakes");
        }
        let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id)?);
        let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?);
        let owner_token = CapabilityToken::from_bytes(decode_hex_array(&record.owner_token)?);
        let mut stream = connect_until(Path::new(&record.endpoint), deadline)?;
        let mut stream = DeadlineStream::new(&mut stream, deadline);
        let hello = ClientHello {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            role: ClientRole::Admin,
            requested_rights: CapabilityRights::TERMINATE,
            terminal_id,
            token: owner_token,
        };
        let mut hello = hello.into_frame(1);
        hello.flags = FLAG_TERMINATE_ONLY;
        write_frame(&mut stream, &hello)?;
        let response = read_required_frame(&mut stream, "terminate-only host hello")?;
        if response.kind != MessageKind::HostHello
            || response.flags != FLAG_TERMINATE_ONLY
            || response.request_id != 1
            || response.sequence != 0
        {
            anyhow::bail!("terminal host rejected terminate-only handshake");
        }
        let response = HostHello::decode(&response.payload)?;
        if response.selected_version != PROTOCOL_VERSION
            || response.granted_rights != CapabilityRights::TERMINATE
            || response.terminal_id != terminal_id
            || response.incarnation != incarnation
        {
            anyhow::bail!("terminate-only host identity or rights changed");
        }
        write_frame(&mut stream, &Frame::new(MessageKind::Terminate, Vec::new()))?;
        stream.shutdown(std::net::Shutdown::Write)?;
        Ok(())
    }

    pub(crate) fn adopt_terminal_host_with_kitty_limits(
        record: TerminalHostRecord,
        record_path: PathBuf,
        ceiling: KittyGraphicsLimits,
    ) -> anyhow::Result<HostAttachment> {
        let ceiling = ceiling
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        let mut attachment = adopt_terminal_host(record.clone(), record_path.clone())?;
        if kitty_graphics_limits_within(attachment.snapshot.kitty_state.limits, ceiling) {
            return Ok(attachment);
        }

        attachment.reconfigure_kitty_graphics_for_adoption(ceiling)?;
        attachment.disconnect();
        drop(attachment);

        let attachment = adopt_terminal_host(record, record_path)?;
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
                || record.supports_terminate_only
                || record.supports_clear_history
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
        load_terminal_host_records_until(
            root,
            MAX_TERMINAL_HOST_RECORDS,
            Instant::now() + TERMINAL_HOST_RECORD_SCAN_TIMEOUT,
            TerminalHostRecordLoadMode::Tolerant,
        )
    }

    fn terminal_host_record_path(root: &Path, terminal_id: &str) -> anyhow::Result<PathBuf> {
        let terminal = TerminalId::from_hex(terminal_id)
            .ok_or_else(|| anyhow::anyhow!("terminal-host id is not a canonical UUIDv4"))?;
        anyhow::ensure!(terminal.to_hex() == terminal_id, "terminal-host id is not canonical");
        Ok(root.join(format!("{terminal_id}.json")))
    }

    /// Exclude a still-launching host before treating its absent canonical
    /// record as proof that no PTY owner can publish later.
    pub(crate) fn acquire_terminal_host_publication(
        root: &Path,
        terminal_id: &str,
    ) -> anyhow::Result<crate::PublicationGuard> {
        prepare_private_dir(root)?;
        let path = terminal_host_record_path(root, terminal_id)?;
        crate::PublicationGuard::acquire(&path, Instant::now() + TERMINAL_HOST_RECORD_SCAN_TIMEOUT)
            .with_context(|| format!("wait for terminal-host publication {}", path.display()))
    }

    /// Load the one canonical discovery record for `terminal_id` without
    /// scanning unrelated hosts. A missing record means there is no discovery
    /// owner to terminate; malformed or unreadable records remain errors so a
    /// close cannot silently abandon a live host.
    pub(crate) fn load_terminal_host_record(
        root: &Path,
        terminal_id: &str,
    ) -> anyhow::Result<Option<(PathBuf, TerminalHostRecord)>> {
        let path = terminal_host_record_path(root, terminal_id)?;
        match read_terminal_host_record_until(
            &path,
            Instant::now() + TERMINAL_HOST_RECORD_SCAN_TIMEOUT,
        ) {
            Ok(record) => Ok(Some((path, record))),
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    /// Load every discovery record without omission. Adoption tolerates
    /// transient or stale files, but an atomic server shutdown must account
    /// for every record before it discards topology.
    pub fn load_terminal_host_records_strict(
        root: &Path,
        max_records: usize,
        deadline: Instant,
    ) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        load_terminal_host_records_until(
            root,
            max_records,
            deadline,
            TerminalHostRecordLoadMode::Strict,
        )
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum TerminalHostRecordLoadMode {
        Tolerant,
        Strict,
    }

    fn load_terminal_host_records_until(
        root: &Path,
        max_records: usize,
        deadline: Instant,
        mode: TerminalHostRecordLoadMode,
    ) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
        ensure_terminal_host_scan_before(deadline)?;
        let mut records = Vec::new();
        let mut identities = HashSet::new();
        let mut candidates = 0usize;
        let entries = match fs::read_dir(root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(records),
            Err(error) => return Err(error.into()),
        };
        for entry in entries {
            ensure_terminal_host_scan_before(deadline)?;
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            candidates = candidates.saturating_add(1);
            if candidates > max_records {
                anyhow::bail!("terminal-host record count exceeds capacity {max_records}");
            }
            let record = match read_terminal_host_record_until(&path, deadline) {
                Ok(record) => record,
                Err(_) if mode == TerminalHostRecordLoadMode::Tolerant => {
                    ensure_terminal_host_scan_before(deadline)?;
                    continue;
                }
                Err(error) => return Err(error),
            };
            if !identities.insert((record.terminal_id.clone(), record.incarnation.clone())) {
                if mode == TerminalHostRecordLoadMode::Strict {
                    anyhow::bail!(
                        "duplicate terminal-host identity {}:{}",
                        record.terminal_id,
                        record.incarnation
                    );
                }
                continue;
            }
            records.push((path, record));
        }
        ensure_terminal_host_scan_before(deadline)?;
        records.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(records)
    }

    fn ensure_terminal_host_scan_before(deadline: Instant) -> anyhow::Result<()> {
        if Instant::now() >= deadline {
            anyhow::bail!("terminal-host record scan exceeded the shutdown deadline");
        }
        Ok(())
    }

    fn read_terminal_host_record_until(
        path: &Path,
        deadline: Instant,
    ) -> anyhow::Result<TerminalHostRecord> {
        ensure_terminal_host_scan_before(deadline)?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .with_context(|| format!("open terminal-host record {}", path.display()))?;
        let metadata = file
            .metadata()
            .with_context(|| format!("inspect terminal-host record {}", path.display()))?;
        let expected_uid = fs::metadata(
            path.parent()
                .ok_or_else(|| anyhow::anyhow!("terminal-host record has no parent directory"))?,
        )?
        .uid();
        if !metadata.file_type().is_file()
            || metadata.uid() != expected_uid
            || metadata.nlink() != 1
            || metadata.mode() & 0o077 != 0
        {
            anyhow::bail!("terminal-host record permissions or ownership are unsafe");
        }
        if metadata.len() > MAX_TERMINAL_HOST_RECORD_BYTES as u64 {
            anyhow::bail!("terminal-host record {} exceeds size limit", path.display());
        }

        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        let mut buffer = [0u8; 8 * 1024];
        loop {
            ensure_terminal_host_scan_before(deadline)?;
            let remaining = MAX_TERMINAL_HOST_RECORD_BYTES + 1 - bytes.len();
            let read_len = buffer.len().min(remaining);
            let read = file
                .read(&mut buffer[..read_len])
                .with_context(|| format!("read terminal-host record {}", path.display()))?;
            if read == 0 {
                break;
            }
            bytes.extend_from_slice(&buffer[..read]);
            if bytes.len() > MAX_TERMINAL_HOST_RECORD_BYTES {
                anyhow::bail!("terminal-host record {} exceeds size limit", path.display());
            }
        }
        ensure_terminal_host_scan_before(deadline)?;
        let current = fs::symlink_metadata(path)
            .with_context(|| format!("reinspect terminal-host record {}", path.display()))?;
        if !current.file_type().is_file()
            || current.dev() != metadata.dev()
            || current.ino() != metadata.ino()
        {
            anyhow::bail!("terminal-host record changed while being read");
        }
        let record = serde_json::from_slice::<TerminalHostRecord>(&bytes)
            .with_context(|| format!("decode terminal-host record {}", path.display()))?;
        validate_terminal_host_record(path, &record)
            .with_context(|| format!("validate terminal-host record {}", path.display()))?;
        Ok(record)
    }

    /// Terminate one exact host incarnation and retain its discovery record
    /// until process-bound liveness proves that host is dead.
    pub(crate) fn terminate_and_confirm_terminal_host_record(
        record: &TerminalHostRecord,
        record_path: &Path,
        deadline: Instant,
    ) -> bool {
        let mut last_terminate_attempt = None;
        loop {
            match terminal_host_record_liveness(record_path, record)
                .unwrap_or(TerminalHostLiveness::Indeterminate)
            {
                TerminalHostLiveness::Dead => {
                    return match remove_stale_terminal_host_record(record_path, record) {
                        Ok(removed) => removed,
                        Err(_) if !record_path.exists() => true,
                        Err(_) => false,
                    };
                }
                TerminalHostLiveness::Live | TerminalHostLiveness::Indeterminate => {}
            }

            let now = Instant::now();
            if last_terminate_attempt.is_none_or(|attempt: Instant| {
                now.duration_since(attempt) >= Duration::from_millis(100)
            }) {
                let attempt_deadline = deadline.min(Instant::now() + Duration::from_millis(100));
                if Instant::now() < attempt_deadline {
                    if record.supports_terminate_only {
                        let _ =
                            terminate_terminal_host_until(record, record_path, attempt_deadline);
                    } else if let Ok(host) = adopt_terminal_host_until(
                        record.clone(),
                        record_path.to_path_buf(),
                        attempt_deadline,
                    ) {
                        let _ = host.terminate_until(attempt_deadline);
                        host.disconnect();
                    }
                    last_terminate_attempt = Some(Instant::now());
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            thread::sleep(deadline.saturating_duration_since(now).min(Duration::from_millis(10)));
        }
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
        connect_record_until(record, record_path, Instant::now() + handshake_timeout)
    }

    fn connect_record_until(
        record: TerminalHostRecord,
        record_path: PathBuf,
        deadline: Instant,
    ) -> anyhow::Result<HostAttachment> {
        let mut failures = Vec::new();
        for protocol_version in (LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).rev() {
            match connect_record_at_version_until(
                record.clone(),
                record_path.clone(),
                deadline,
                protocol_version,
            ) {
                Ok(attachment) => return Ok(attachment),
                Err(error) => {
                    failures.push(format!("protocol {protocol_version}: {error:#}"));
                }
            }
        }
        anyhow::bail!("terminal-host adoption failed: {}", failures.join("; "))
    }

    fn connect_record_at_version_until(
        record: TerminalHostRecord,
        record_path: PathBuf,
        deadline: Instant,
        protocol_version: u16,
    ) -> anyhow::Result<HostAttachment> {
        if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
            anyhow::bail!("unsupported terminal-host adoption protocol {protocol_version}");
        }
        let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id)?);
        let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?);
        let owner_token = CapabilityToken::from_bytes(decode_hex_array(&record.owner_token)?);
        let mut stream = connect_until(Path::new(&record.endpoint), deadline)?;
        let hello = ClientHello {
            min_version: protocol_version,
            max_version: protocol_version,
            role: ClientRole::Admin,
            requested_rights: CapabilityRights::ADMIN,
            terminal_id,
            token: owner_token,
        };
        let (snapshot, snapshot_size) = {
            let mut handshake = DeadlineStream::new(&mut stream, deadline);
            let mut hello_frame = hello.into_frame(1);
            hello_frame.version = protocol_version;
            write_frame(&mut handshake, &hello_frame)?;
            let hello_frame = read_required_frame(&mut handshake, "host hello")?;
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
            let snapshot_frame = read_required_frame(&mut handshake, "terminal snapshot")?;
            if snapshot_frame.kind != MessageKind::Snapshot
                || snapshot_frame.version != protocol_version
                || snapshot_frame.flags != 0
                || snapshot_frame.request_id != 0
            {
                anyhow::bail!("terminal host did not send an initial snapshot");
            }
            let mut snapshot =
                decode_snapshot_for_version(&snapshot_frame.payload, protocol_version)?;
            let colors_frame = read_required_frame(&mut handshake, "terminal color state")?;
            if colors_frame.kind != MessageKind::Colors
                || colors_frame.version != protocol_version
                || colors_frame.flags != 0
                || colors_frame.sequence != snapshot_frame.sequence
                || colors_frame.request_id != 0
            {
                anyhow::bail!(
                    "terminal host did not send Colors at the snapshot sequence boundary"
                );
            }
            snapshot.sequence_boundary = snapshot_frame.sequence;
            snapshot.colors = decode_terminal_color_overrides(&colors_frame.payload)?;
            let snapshot_size = (snapshot.cols, snapshot.rows);
            (snapshot, snapshot_size)
        };
        stream.set_read_timeout(None)?;
        stream.set_write_timeout(Some(HOST_HANDSHAKE_TIMEOUT))?;
        // Keep bounded writes for the lifetime of the disposable admin
        // mirror. A stopped or wedged host must not block a mux/control thread
        // forever while it sends input, mouse, resize, or Terminate. Reads are
        // unbounded because the dedicated reader thread is intentionally
        // long-lived and reconnects on any eventual EOF/protocol failure.
        let reader = cmux_tui_process::unix::clone_stream(&stream)?;
        let attachment = HostAttachment {
            record,
            record_path,
            snapshot,
            protocol_version,
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
        };
        attachment.release_viewer_size()?;
        Ok(attachment)
    }

    struct DeadlineStream<'a> {
        stream: &'a mut UnixStream,
        deadline: Instant,
    }

    impl<'a> DeadlineStream<'a> {
        fn new(stream: &'a mut UnixStream, deadline: Instant) -> Self {
            Self { stream, deadline }
        }

        fn remaining(&self) -> std::io::Result<Duration> {
            self.deadline
                .checked_duration_since(Instant::now())
                .filter(|value| !value.is_zero())
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "terminal host operation exceeded its deadline",
                    )
                })
        }

        fn shutdown(&self, how: std::net::Shutdown) -> std::io::Result<()> {
            self.stream.shutdown(how)
        }
    }

    impl Read for DeadlineStream<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.stream.set_read_timeout(Some(self.remaining()?))?;
            self.stream.read(buffer)
        }
    }

    impl Write for DeadlineStream<'_> {
        fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
            self.stream.set_write_timeout(Some(self.remaining()?))?;
            self.stream.write(buffer)
        }

        fn flush(&mut self) -> std::io::Result<()> {
            self.stream.set_write_timeout(Some(self.remaining()?))?;
            self.stream.flush()
        }
    }

    fn connect_until(path: &Path, deadline: Instant) -> anyhow::Result<UnixStream> {
        let mut last_error = None;
        loop {
            if Instant::now() >= deadline {
                return Err(last_error
                    .unwrap_or_else(|| {
                        std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "terminal host connection exceeded its deadline",
                        )
                    })
                    .into());
            }
            match connect_once_until(path, deadline) {
                Ok(stream) => return Ok(stream),
                Err(error) => last_error = Some(error),
            }
            let now = Instant::now();
            if now >= deadline {
                continue;
            }
            thread::sleep(deadline.saturating_duration_since(now).min(Duration::from_millis(10)));
        }
    }

    fn connect_once_until(path: &Path, deadline: Instant) -> std::io::Result<UnixStream> {
        crate::platform::transport::connect_unix_until(path, deadline)
    }

    #[cfg(all(test, target_os = "linux"))]
    fn unix_socket_address(path: &Path) -> std::io::Result<(libc::sockaddr_un, libc::socklen_t)> {
        const SUN_PATH_CAPACITY: usize =
            size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
        let path = path.as_os_str().as_bytes();
        if path.is_empty() || path.len() >= SUN_PATH_CAPACITY || path.contains(&0) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "invalid terminal host Unix socket path",
            ));
        }
        // SAFETY: all-zero is a valid starting representation for
        // sockaddr_un; family, path, and platform length are set below.
        let mut address = unsafe { std::mem::zeroed::<libc::sockaddr_un>() };
        address.sun_family = libc::AF_UNIX as libc::sa_family_t;
        for (destination, source) in address.sun_path.iter_mut().zip(path) {
            *destination = *source as libc::c_char;
        }
        let address_len = offset_of!(libc::sockaddr_un, sun_path) + path.len() + 1;
        #[cfg(any(
            target_os = "dragonfly",
            target_os = "freebsd",
            target_os = "macos",
            target_os = "netbsd",
            target_os = "openbsd"
        ))]
        {
            address.sun_len = u8::try_from(address_len).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "terminal host Unix socket path is too long",
                )
            })?;
        }
        Ok((
            address,
            libc::socklen_t::try_from(address_len).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "terminal host Unix socket path is too long",
                )
            })?,
        ))
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
        match fs::create_dir(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let parent = path.parent().ok_or_else(|| {
                    anyhow::anyhow!("terminal-host directory has no parent: {}", path.display())
                })?;
                fs::create_dir_all(parent)?;
                match fs::create_dir(path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => return Err(error.into()),
                }
            }
            Err(error) => return Err(error.into()),
        }

        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(path)
            .with_context(|| format!("open private terminal-host directory {}", path.display()))?;
        let metadata = directory.metadata().with_context(|| {
            format!("inspect private terminal-host directory {}", path.display())
        })?;
        // SAFETY: geteuid has no preconditions and returns the effective user
        // that must own this process-private endpoint directory.
        let current_user = unsafe { libc::geteuid() };
        if !metadata.file_type().is_dir() || metadata.uid() != current_user {
            anyhow::bail!(
                "private terminal-host directory is not an owned directory: {}",
                path.display()
            );
        }
        directory.set_permissions(fs::Permissions::from_mode(0o700))?;

        let current = fs::symlink_metadata(path).with_context(|| {
            format!("reinspect private terminal-host directory {}", path.display())
        })?;
        if !current.file_type().is_dir()
            || current.dev() != metadata.dev()
            || current.ino() != metadata.ino()
        {
            anyhow::bail!("private terminal-host directory changed: {}", path.display());
        }
        Ok(())
    }

    #[derive(Clone)]
    struct HostTap {
        sender: SyncSender<Frame>,
        queued_bytes: Arc<AtomicUsize>,
        queued_output_bytes: Arc<AtomicUsize>,
        shutdown: Arc<UnixStream>,
        max_queued_bytes: usize,
    }

    impl HostTap {
        fn new(
            sender: SyncSender<Frame>,
            shutdown: Arc<UnixStream>,
            max_queued_bytes: usize,
        ) -> Self {
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
            match self.sender.try_send(frame) {
                Ok(()) => true,
                Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
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
                if started.elapsed() >= host_forced_drain_window() {
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
                    let remaining = host_forced_drain_window().saturating_sub(started.elapsed());
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

    fn wait_for_host_service_activity(
        listener_fd: RawFd,
        exit_waiter: &mut UnixStream,
        dead: &AtomicBool,
        deadline: Option<Instant>,
    ) -> std::io::Result<bool> {
        loop {
            if dead.load(Ordering::Acquire) {
                return Ok(false);
            }
            let mut poll_fds = [
                libc::pollfd {
                    fd: listener_fd,
                    events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                    revents: 0,
                },
                libc::pollfd {
                    fd: exit_waiter.as_raw_fd(),
                    events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                    revents: 0,
                },
            ];
            let timeout = deadline
                .map(|deadline| {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        0
                    } else {
                        remaining.as_millis().clamp(1, i32::MAX as u128) as i32
                    }
                })
                .unwrap_or(-1);
            // SAFETY: poll_fds contains two initialized descriptors that
            // remain owned by the service loop for the duration of this call.
            let ready = unsafe {
                libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, timeout)
            };
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                return Ok(true);
            }
            if poll_fds[0].revents & libc::POLLNVAL != 0 {
                return Err(std::io::Error::other("terminal host listener became invalid"));
            }
            if poll_fds[1].revents & libc::POLLIN != 0 {
                let mut wake = [0u8; 64];
                let _ = exit_waiter.read(&mut wake);
                if dead.load(Ordering::Acquire) {
                    return Ok(false);
                }
            }
            if poll_fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                return Ok(true);
            }
            if poll_fds[1].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                if dead.load(Ordering::Acquire) {
                    return Ok(false);
                }
                return Err(std::io::Error::other("terminal host exit waiter became invalid"));
            }
        }
    }

    struct HostClientAdmission {
        active: Arc<AtomicUsize>,
    }

    impl HostClientAdmission {
        fn try_acquire(active: &Arc<AtomicUsize>) -> Option<Self> {
            active
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                    (count < MAX_TERMINAL_HOST_CLIENTS).then_some(count + 1)
                })
                .ok()?;
            Some(Self { active: active.clone() })
        }
    }

    impl Drop for HostClientAdmission {
        fn drop(&mut self) {
            self.active.fetch_sub(1, Ordering::AcqRel);
        }
    }

    struct HostShared {
        terminal_id: TerminalId,
        incarnation: HostIncarnation,
        owner_token: CapabilityToken,
        capabilities: CapabilityStore,
        term: Mutex<Terminal>,
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
        taps_changed: Condvar,
        broadcast_lock: Mutex<()>,
        sequence: AtomicU64,
        next_client: AtomicU64,
        active_clients: Arc<AtomicUsize>,
        dead: AtomicBool,
        launch_owner_claimed: AtomicBool,
        launch_owner_stream_ready: AtomicBool,
        launch_owner_completed: AtomicBool,
        child_exit: (Mutex<Option<TerminalExit>>, Condvar),
        child_waitable: AtomicBool,
        pty_drained: AtomicBool,
        exit_published: AtomicBool,
        exit_record_path: PathBuf,
        exit_publish_requests: Sender<()>,
        force_pty_drain: AtomicBool,
        pty_drain_waker: Mutex<UnixStream>,
        service_exit_waker: Mutex<UnixStream>,
        service_exit_waiter: Mutex<Option<UnixStream>>,
        termination_started: AtomicBool,
        child_signal_lock: Mutex<()>,
        child_reaped: AtomicBool,
        child_wait_ownership_lost: AtomicBool,
        group_escalation_complete: AtomicBool,
        #[cfg(test)]
        normal_cleanup_failures: AtomicUsize,
        #[cfg(test)]
        normal_cleanup_attempts: AtomicUsize,
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
            self.host.launch_owner_stream_ready.store(true, Ordering::Release);
            self.host.publish_exit_if_drained();
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
            self.host.launch_owner_stream_ready.store(true, Ordering::Release);
            self.host.launch_owner_completed.store(true, Ordering::Release);
            self.host.publish_exit_if_drained();
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

        fn clear_history_or_encode_key(
            &self,
            fallback_key: Option<&KeyInput>,
        ) -> Result<(), ClearHistoryFailure> {
            let mut observed_progress = self.stream_progress.revision();
            let mut stream_wait = None;
            loop {
                let mut term = self.term.lock().unwrap();
                match apply_clear_history_transition(&mut term, fallback_key)
                    .map_err(ClearHistoryFailure::known_not_delivered)?
                {
                    ClearHistoryTransition::Cleared(clear) => {
                        // Keep the authoritative parser lock through sequence
                        // publication so child output cannot overtake the
                        // emulator-only erase on any attached mirror.
                        self.broadcast(MessageKind::Output, clear);
                        return Ok(());
                    }
                    ClearHistoryTransition::Blocked => {
                        drop(term);
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
                    ClearHistoryTransition::EncodedFallback(encoded) => {
                        drop(term);
                        let mut writer = self.writer.lock().unwrap();
                        let master = self.master.lock().unwrap();
                        return write_clear_history_fallback(
                            master.as_ref(),
                            writer.as_mut(),
                            &encoded,
                        );
                    }
                    ClearHistoryTransition::Noop => return Ok(()),
                }
            }
        }

        fn remove_client(&self, client: u64) {
            if self.taps.lock().unwrap().remove(&client).is_some() {
                self.taps_changed.notify_all();
            }
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
            let resize_sizes = if changed {
                Some((pty_size(size.0, size.1, previous)?, pty_size(size.0, size.1, next)?))
            } else {
                None
            };
            let mut term = self.term.lock().unwrap();
            if let Some((previous_size, next_size)) = resize_sizes {
                term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES).context(
                    "could not preflight terminal-host cell-metric replay; geometry unchanged",
                )?;
                let master = self.master.lock().unwrap();
                master.resize(next_size)?;
                if let Err(error) =
                    term.resize(size.0, size.1, u32::from(next.0), u32::from(next.1))
                {
                    let rollback = master.resize(previous_size);
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
            Ok(publish_host_frames_and_targeted(
                &self.broadcast_lock,
                &self.sequence,
                &self.taps,
                transition.into_iter().flatten(),
                Some((target, ack)),
            ))
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
            let size = *self.size.lock().unwrap();
            let cell_pixels = *self.cell_pixels.lock().unwrap();
            let mut term = self.term.lock().unwrap();
            term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
                .context("could not preflight terminal-host Kitty limit replay")?;
            if let Err(error) = term.set_kitty_graphics_limits(limits) {
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
                    let mut taps = self.taps.lock().unwrap();
                    for tap in taps.values() {
                        tap.close();
                    }
                    taps.clear();
                    target.close();
                    return Err(error.into());
                }
            };
            let mut resized = Frame::new(
                MessageKind::Resized,
                encode_resize(
                    size.0,
                    size.1,
                    &replay.bytes,
                    &replay.kitty_image_aliases,
                    cell_pixels,
                    replay.kitty_state,
                )?,
            );
            resized.flags = FLAG_COLORS_FOLLOW;
            let mut ack_payload = Vec::with_capacity(KITTY_GRAPHICS_LIMITS_ENCODED_LEN);
            encode_kitty_graphics_limits(&mut ack_payload, limits)?;
            let mut ack = Frame::new(MessageKind::KittyGraphicsLimitsAck, ack_payload);
            ack.request_id = request_id;
            // The parser stays locked until all mirrors receive one complete
            // replacement and the requester receives its acknowledgement.
            Ok(publish_host_frames_and_targeted(
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
            ))
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
            let resize_sizes = if changed {
                Some((
                    pty_size(previous.0, previous.1, *cell_pixels)?,
                    pty_size(cols, rows, *cell_pixels)?,
                ))
            } else {
                None
            };
            let mut term = self.term.lock().unwrap();
            let master = self.master.lock().unwrap();
            if let Some((previous_size, next_size)) = resize_sizes {
                term.preflight_vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES).context(
                    "could not preflight terminal-host resize replay; geometry unchanged",
                )?;
                master.resize(next_size)?;
                if let Err(error) =
                    term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))
                {
                    let _ = master.resize(previous_size);
                    return Err(error.into());
                }
            }
            let replay = match term
                .vt_replay_bounded_theme_portable_with_aliases(crate::surface::VT_REPLAY_MAX_BYTES)
            {
                Ok(replay) => replay,
                Err(_) if changed => {
                    // The bounded preflight ruled out the only persistent
                    // budget failure. Preserve the committed terminal state
                    // and force mirrors to reconnect instead of attempting an
                    // inverse, destructive Ghostty resize.
                    *size = (cols, rows);
                    let mut taps = self.taps.lock().unwrap();
                    for tap in taps.values() {
                        tap.close();
                    }
                    taps.clear();
                    return Ok(false);
                }
                Err(error) => return Err(error.into()),
            };
            let colors = term.color_overrides();
            if changed {
                *size = (cols, rows);
            }
            // Keep the parser lock through sequence publication so output
            // parsed at the new size cannot overtake the Resized marker.
            let mut resized = Frame::new(
                MessageKind::Resized,
                encode_resize(
                    cols,
                    rows,
                    &replay.bytes,
                    &replay.kitty_image_aliases,
                    *cell_pixels,
                    replay.kitty_state,
                )?,
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

        fn observe_child_wait_state_locked(
            &self,
            session: libc::pid_t,
            nonblocking: bool,
        ) -> std::io::Result<crate::process_session::ChildWaitState> {
            if self.child_wait_ownership_lost.load(Ordering::Acquire) {
                return Ok(crate::process_session::ChildWaitState::OwnershipLost);
            }
            let state =
                crate::process_session::observe_child_without_reaping(session, nonblocking)?;
            match state {
                crate::process_session::ChildWaitState::Waitable => {
                    self.mark_child_waitable();
                }
                crate::process_session::ChildWaitState::OwnershipLost => {
                    self.publish_child_wait_predicate(&self.child_wait_ownership_lost);
                }
                crate::process_session::ChildWaitState::Running => {}
            }
            Ok(state)
        }

        fn publish_child_wait_predicate(&self, predicate: &AtomicBool) -> bool {
            // Every predicate consumed by child_exit.wait_* changes while
            // holding this mutex. Otherwise a notifier can run after a waiter
            // checks the atomic but before Condvar::wait arms, losing the only
            // wake that allows the terminal exit to be published.
            let _state = self.child_exit.0.lock().unwrap();
            let changed = !predicate.swap(true, Ordering::AcqRel);
            self.child_exit.1.notify_all();
            changed
        }

        fn mark_child_waitable(&self) {
            self.publish_child_wait_predicate(&self.child_waitable);
        }

        fn mark_pty_drained(&self) {
            if self.publish_child_wait_predicate(&self.pty_drained) {
                self.wake_reserved_child_reaper();
            }
        }

        fn signal_terminal_process_session(
            &self,
            signal: libc::c_int,
            deadline: Instant,
        ) -> std::io::Result<()> {
            // The shared reaper observes exit with WNOWAIT, then takes this
            // lock before reaping. Holding it reserves the session leader and
            // its numeric session id across enumeration and signaling.
            let _signal = self.child_signal_lock.lock().unwrap();
            let Some(session) = self.pid.and_then(|pid| libc::pid_t::try_from(pid).ok()) else {
                return Err(std::io::Error::other("PTY child has no process id"));
            };
            if self.child_wait_ownership_lost.load(Ordering::Acquire) {
                return Err(std::io::Error::other("PTY child wait ownership was lost"));
            }
            if self.child_reaped.load(Ordering::Acquire) {
                return match crate::process_session::session_is_empty_until(session, deadline) {
                    Ok(true) => Ok(()),
                    Ok(false) => Err(std::io::Error::other(
                        "PTY session still has members after its leader was reaped",
                    )),
                    Err(error) => Err(error),
                };
            }
            if self.observe_child_wait_state_locked(session, true)?
                == crate::process_session::ChildWaitState::OwnershipLost
            {
                return Err(std::io::Error::other("PTY child wait ownership was lost"));
            }
            crate::process_session::signal_until(session, signal, deadline)
        }

        fn kill_terminal_process_session_until(&self, deadline: Instant) -> std::io::Result<bool> {
            let _signal = self.child_signal_lock.lock().unwrap();
            let Some(leader) = self.pid.and_then(|pid| libc::pid_t::try_from(pid).ok()) else {
                return Err(std::io::Error::other("PTY child has no process id"));
            };
            if self.child_wait_ownership_lost.load(Ordering::Acquire) {
                return Err(std::io::Error::other("PTY child wait ownership was lost"));
            }
            if self.child_reaped.load(Ordering::Acquire) {
                return crate::process_session::session_is_empty_until(leader, deadline);
            }
            if self.observe_child_wait_state_locked(leader, true)?
                == crate::process_session::ChildWaitState::OwnershipLost
            {
                return Err(std::io::Error::other("PTY child wait ownership was lost"));
            }
            crate::process_session::kill_until_only_leader(leader, leader, deadline, || match self
                .observe_child_wait_state_locked(
                leader, true,
            )? {
                crate::process_session::ChildWaitState::Running => Ok(false),
                crate::process_session::ChildWaitState::Waitable => Ok(true),
                crate::process_session::ChildWaitState::OwnershipLost => {
                    Err(std::io::Error::other("PTY child wait ownership was lost"))
                }
            })
        }

        fn prepare_natural_cleanup(&self) -> bool {
            #[cfg(test)]
            {
                self.normal_cleanup_attempts.fetch_add(1, Ordering::AcqRel);
                if self
                    .normal_cleanup_failures
                    .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| {
                        remaining.checked_sub(1)
                    })
                    .is_ok()
                {
                    return false;
                }
            }
            true
        }

        fn request_forced_pty_drain(&self) {
            self.force_pty_drain.store(true, Ordering::Release);
            // Wake the otherwise blocking poll in the sole PTY reader. The
            // byte has no protocol meaning; it only makes the wake fd ready.
            let _ = self.pty_drain_waker.lock().unwrap().write_all(&[1]);
        }

        fn wake_reserved_child_reaper(&self) {
            let Some(session) = self.pid.and_then(|pid| libc::pid_t::try_from(pid).ok()) else {
                return;
            };
            crate::process_session::wake_child_reaper(session);
        }

        fn request_termination(self: &Arc<Self>) {
            let already_started = {
                // Serialize the ownership transition with WNOWAIT's final
                // reap decision so an explicit Terminate cannot lose the
                // original reserved PID/PGID in between.
                let _signal = self.child_signal_lock.lock().unwrap();
                self.termination_started.swap(true, Ordering::AcqRel)
            };
            self.child_exit.1.notify_all();
            if already_started {
                return;
            }
            self.wake_reserved_child_reaper();
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
            if self.publish_child_wait_predicate(&self.group_escalation_complete) {
                self.wake_reserved_child_reaper();
            }
        }

        fn abandon_group_escalation(&self) {
            let changed = self.termination_started.swap(false, Ordering::AcqRel);
            self.child_exit.1.notify_all();
            if changed {
                self.wake_reserved_child_reaper();
            }
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
                self.dead.store(true, Ordering::Release);
                self.broadcast(MessageKind::Exit, encode_terminal_exit(&exit));
                // Wake the blocking listener poll so host service cleanup
                // follows durable exit publication without a periodic timer.
                let _ = self.service_exit_waker.lock().unwrap().write_all(&[1]);
            }
            Ok(())
        }

        fn drain_clients_after_exit(&self) {
            let deadline = Instant::now() + HOST_CLIENT_EXIT_DRAIN;
            let mut taps = self.taps.lock().unwrap();
            while !taps.is_empty() {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                let (next, timeout) = self.taps_changed.wait_timeout(taps, deadline - now).unwrap();
                taps = next;
                if timeout.timed_out() && !taps.is_empty() {
                    break;
                }
            }
            let stalled = taps.values().cloned().collect::<Vec<_>>();
            drop(taps);
            for tap in stalled {
                tap.close();
            }
        }

        fn terminate_and_wait(&self) {
            let (termination_changed, child_reaped, wait_ownership_lost) = {
                let _signal = self.child_signal_lock.lock().unwrap();
                let termination_changed = !self.termination_started.swap(true, Ordering::AcqRel);
                (
                    termination_changed,
                    self.child_reaped.load(Ordering::Acquire),
                    self.child_wait_ownership_lost.load(Ordering::Acquire),
                )
            };
            self.child_exit.1.notify_all();
            if termination_changed {
                self.wake_reserved_child_reaper();
            }
            if wait_ownership_lost {
                self.abandon_group_escalation();
                return;
            }
            if child_reaped {
                let session_empty = self
                    .pid
                    .and_then(|pid| libc::pid_t::try_from(pid).ok())
                    .is_some_and(|session| {
                        matches!(
                            crate::process_session::session_is_empty_until(
                                session,
                                Instant::now() + HOST_KILL_WAIT,
                            ),
                            Ok(true)
                        )
                    });
                if session_empty {
                    self.child_exit.1.notify_all();
                    self.publish_exit_if_drained();
                } else {
                    self.abandon_group_escalation();
                }
                return;
            }
            // ProcessSignaller only targets the direct child. Start with a
            // graceful session hangup so foreground and background jobs can
            // clean up too, then escalate after a strict bound.
            if self
                .signal_terminal_process_session(
                    libc::SIGHUP,
                    Instant::now() + HOST_TERMINATE_GRACE,
                )
                .is_err()
            {
                self.abandon_group_escalation();
                return;
            }
            if !self.child_waitable.load(Ordering::Acquire) {
                let _ = self.killer.lock().unwrap().kill();
            }
            let _ = self.wait_for_child_waitable(HOST_TERMINATE_GRACE);
            let _ = self.wait_for_pty_drain(HOST_PTY_DRAIN_GRACE);

            // Process groups are transient job-control details. Repeatedly
            // kill every member of the PTY session while WNOWAIT reserves the
            // leader, then publish Exit only after every background group is
            // gone.
            let kill_deadline = Instant::now() + HOST_KILL_WAIT;
            if !matches!(self.kill_terminal_process_session_until(kill_deadline), Ok(true)) {
                self.abandon_group_escalation();
                return;
            }
            self.finish_group_escalation();
            let child_exited =
                self.wait_for_child_exit(kill_deadline.saturating_duration_since(Instant::now()));
            if child_exited && self.wait_for_pty_drain(HOST_PTY_DRAIN_GRACE) {
                return;
            }

            if child_exited {
                // A process that escaped the PTY session can retain a slave
                // descriptor forever. Do not let an explicit tombstone hang
                // the durable host: wake the reader, drain bytes already
                // readable for a short bounded window, then publish Exit.
                self.request_forced_pty_drain();
                let _ = self.wait_for_pty_drain(host_forced_drain_window() * 2);
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

    fn reap_reserved_child_status(session: libc::pid_t) -> TerminalExit {
        use std::os::unix::process::ExitStatusExt;

        loop {
            let mut status = 0;
            // SAFETY: the shared reaper calls this while holding the signal
            // lock after WNOWAIT proved `session` is our waitable child. The
            // retained child handle keeps the numeric PID reserved until this
            // sole final reap completes.
            let waited = unsafe { libc::waitpid(session, &mut status, 0) };
            if waited == session {
                return TerminalExit::from_exit_status(&std::process::ExitStatus::from_raw(status));
            }
            if waited < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return TerminalExit::unknown(format!("waitpid failed: {error}"));
            }
            return TerminalExit::unknown("waitpid returned without the reserved child");
        }
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
            loop {
                // SAFETY: this valid descriptor owns the advisory lock. An
                // explicit unlock also releases the shared open-file
                // description inherited by a child between fork and exec.
                if unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) } == 0 {
                    break;
                }
                if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
                    break;
                }
            }
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
            let owns_record = !self.published
                || fs::read(&self.record_path)
                    .ok()
                    .and_then(|bytes| serde_json::from_slice::<TerminalHostRecord>(&bytes).ok())
                    .is_some_and(|current| {
                        current.terminal_id == self.record.terminal_id
                            && current.incarnation == self.record.incarnation
                            && current.host_start_nonce == self.record.host_start_nonce
                    });
            let endpoint_removed = match fs::remove_file(&self.endpoint) {
                Ok(()) => true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(_) => false,
            };
            let lease_removed = if owns_record {
                match fs::remove_file(&self.lease.path) {
                    Ok(()) => true,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                    Err(_) => false,
                }
            } else {
                false
            };
            let _ = self.lease.file.sync_all();
            // Record removal is the final cleanup barrier. Once observers see
            // it absent, both the transport endpoint and process-bound
            // liveness path are already gone.
            if self.published && owns_record && endpoint_removed && lease_removed {
                let _ = fs::remove_file(&self.record_path);
            }
        }
    }

    pub fn serve_terminal_host_stdio(
        args: &[String],
        reader: &mut impl Read,
        writer: &mut impl Write,
    ) -> anyhow::Result<()> {
        let publication_descriptor = terminal_host_publication_descriptor(args)?;
        if let Ok(delay) = std::env::var("CMUX_TUI_TEST_BOOTSTRAP_READY_DELAY_MS")
            && let Ok(delay) = delay.parse::<u64>()
            && delay > 0
        {
            thread::sleep(Duration::from_millis(delay.min(5_000)));
        }
        let bootstrapped = crate::terminal_host::bootstrap_stdio_once(reader, writer)?;
        if let Ok(delay) = std::env::var("CMUX_TUI_TEST_STALL_AFTER_BOOTSTRAP_READY_MS")
            && let Ok(delay) = delay.parse::<u64>()
            && delay > 0
        {
            thread::sleep(Duration::from_millis(delay.min(5_000)));
        }
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
        let publication_descriptor = publication_descriptor
            .ok_or_else(|| anyhow::anyhow!("terminal-host launch omitted publication ownership"))?;
        // SAFETY: the private launcher passes one unique child descriptor,
        // and fd isolation preserves only that descriptor beyond stdio.
        let publication_guard = unsafe {
            crate::PublicationGuard::adopt_inherited(
                Path::new(&launch.record_path),
                publication_descriptor,
                Instant::now() + HOST_LAUNCH_TIMEOUT,
            )
        }
        .context("adopt terminal-host record publication ownership")?;
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
        let listener = cmux_tui_process::unix::bind_listener(&endpoint)?;
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
            supports_terminate_only: true,
            supports_clear_history: true,
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
        drop(publication_guard);

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
        if std::env::var("CMUX_TUI_TEST_INVALID_HOST_READY").as_deref() == Ok("1") {
            response.kind = MessageKind::Snapshot;
        }
        response.request_id = launch_frame.request_id;
        // Publication is the ownership handoff. If the launcher dies in the
        // narrow record-before-Ready window, EPIPE must not tear down the
        // independently adoptable shell; a replacement daemon discovers the
        // record and connects through the already-listening Unix socket.
        let _ = write_frame(writer, &response);

        let launch_owner_deadline = Instant::now() + HOST_LAUNCH_OWNER_TIMEOUT;
        let mut service_waiter =
            shared.service_exit_waiter.lock().unwrap().take().ok_or_else(|| {
                anyhow::anyhow!("terminal host service waiter was already claimed")
            })?;
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
                shared.launch_owner_stream_ready.store(true, Ordering::Release);
                shared.launch_owner_completed.store(true, Ordering::Release);
                shared.publish_exit_if_drained();
            }
            if shared.dead.load(Ordering::Acquire) {
                break;
            }
            match cmux_tui_process::unix::accept_stream(&listener) {
                Ok((stream, _)) => {
                    // Accepted sockets inherit O_NONBLOCK from the listener
                    // on macOS. Client protocol threads use blocking framed
                    // reads, so normalize the accepted descriptor here.
                    stream.set_nonblocking(false)?;
                    let Some(admission) = HostClientAdmission::try_acquire(&shared.active_clients)
                    else {
                        continue;
                    };
                    let host = shared.clone();
                    // A transient thread creation failure rejects this client
                    // without taking down the terminal host. Dropping the
                    // unstarted closure releases its admission automatically.
                    let _ = thread::Builder::new().name("terminal-host-client".into()).spawn(
                        move || {
                            let _admission = admission;
                            let _ = serve_client(host, stream);
                        },
                    );
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    let deadline = (!shared.launch_owner_claimed.load(Ordering::Acquire))
                        .then_some(launch_owner_deadline);
                    if !wait_for_host_service_activity(
                        listener.as_raw_fd(),
                        &mut service_waiter,
                        &shared.dead,
                        deadline,
                    )? {
                        break;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error.into()),
            }
        }
        shared.drain_clients_after_exit();
        drop(guard);
        Ok(())
    }

    fn spawn_host_runtime(
        launch: &HostLaunch,
        bootstrapped: &crate::terminal_host::BootstrappedHost,
    ) -> anyhow::Result<Arc<HostShared>> {
        let reaper = crate::process_session::reserve_child_reaper()
            .context("reserve bounded PTY session cleanup")?;
        let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
        let initial_pty_size = pty_size(launch.cols, launch.rows, cell_pixels)?;
        let pty = cmux_pty::open(initial_pty_size)?;
        let mut command = PtyCommand::new(&launch.command[0]);
        command.args(launch.command[1..].iter().cloned());
        command.env("TERM", &launch.term);
        for (key, value) in &launch.extra_env {
            command.env(key, value);
        }
        command.env_remove(crate::release::LAUNCHER_COMMAND_ENV);
        if let Some(cwd) = launch.cwd.as_deref() {
            command.cwd(cwd);
        }
        let cmux_pty::SpawnedPty { master, child } = pty.spawn(command)?;
        let child = crate::spawned_pty_child::SpawnedPtyChild::new(child).with_reaper(reaper);
        #[cfg(test)]
        crate::process_session::fail_after_pty_spawn_for_test()?;
        let pid = child.process_id();
        let Some(session) = pid.and_then(|pid| libc::pid_t::try_from(pid).ok()) else {
            anyhow::bail!("native terminal-host PTY child did not expose a process ID");
        };
        let child_identity = match crate::process_session::StableProcessHandle::capture(session) {
            Ok(Some(identity)) => identity,
            Ok(None) => {
                anyhow::bail!(
                    "terminal-host PTY child exited before its process identity was captured"
                );
            }
            Err(error) => return Err(error).context("capture terminal-host PTY child identity"),
        };
        let killer = child.clone_killer();
        let pty_poll_fd = master.as_raw_fd().context("open terminal-host PTY poll fd")?;
        let mut pty_reader = master.try_clone_reader()?;
        let pty_writer = master.take_writer()?;
        let (pty_drain_waker, pty_drain_waiter) = cmux_tui_process::unix::pair_stream()?;
        let (service_exit_waker, service_exit_waiter) = cmux_tui_process::unix::pair_stream()?;

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
        let shared = Arc::new(HostShared {
            terminal_id: bootstrapped.terminal_id,
            incarnation: bootstrapped.incarnation,
            owner_token: bootstrapped.owner_token(),
            capabilities: CapabilityStore::new(64),
            term: Mutex::new(term),
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
            taps_changed: Condvar::new(),
            broadcast_lock: Mutex::new(()),
            sequence: AtomicU64::new(0),
            next_client: AtomicU64::new(1),
            active_clients: Arc::new(AtomicUsize::new(0)),
            dead: AtomicBool::new(false),
            launch_owner_claimed: AtomicBool::new(false),
            launch_owner_stream_ready: AtomicBool::new(false),
            launch_owner_completed: AtomicBool::new(false),
            child_exit: (Mutex::new(None), Condvar::new()),
            child_waitable: AtomicBool::new(false),
            pty_drained: AtomicBool::new(false),
            exit_published: AtomicBool::new(false),
            exit_record_path: Path::new(&launch.record_path).with_extension("exit"),
            exit_publish_requests,
            force_pty_drain: AtomicBool::new(false),
            pty_drain_waker: Mutex::new(pty_drain_waker),
            service_exit_waker: Mutex::new(service_exit_waker),
            service_exit_waiter: Mutex::new(Some(service_exit_waiter)),
            termination_started: AtomicBool::new(false),
            child_signal_lock: Mutex::new(()),
            child_reaped: AtomicBool::new(false),
            child_wait_ownership_lost: AtomicBool::new(false),
            group_escalation_complete: AtomicBool::new(false),
            #[cfg(test)]
            normal_cleanup_failures: AtomicUsize::new(
                NEXT_HOST_NORMAL_CLEANUP_FAILURES.swap(0, Ordering::AcqRel),
            ),
            #[cfg(test)]
            normal_cleanup_attempts: AtomicUsize::new(0),
        });
        HostShared::start_exit_publisher(&shared, exit_publish_receiver)?;

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
                reader_host.stream_progress.notify();
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
            reader_host.mark_pty_drained();
            reader_host.publish_exit_if_drained();
        })?;
        let observe_host = shared.clone();
        let cleanup_host = shared.clone();
        let prepare_host = shared.clone();
        let reap_host = shared.clone();
        let mut child = child;
        let reaper = child
            .take_reaper()
            .expect("terminal-host PTY child retains its reserved session reaper");
        let mut child = Some(child);
        crate::process_session::enqueue_reserved_session_leader(
            reaper.attach_owner(),
            session,
            HOST_KILL_WAIT,
            move || {
                let _signal = observe_host.child_signal_lock.lock().unwrap();
                let state = observe_host.observe_child_wait_state_locked(session, true)?;
                Ok(state != crate::process_session::ChildWaitState::Running)
            },
            move || {
                crate::process_session::reserved_child_needs_cleanup(
                    crate::process_session::ReservedChildReap {
                        signal_lock: &cleanup_host.child_signal_lock,
                        pty_drained: &cleanup_host.pty_drained,
                        termination_started: &cleanup_host.termination_started,
                        cleanup_complete: &cleanup_host.group_escalation_complete,
                        child_reaped: &cleanup_host.child_reaped,
                        wait_ownership_lost: &cleanup_host.child_wait_ownership_lost,
                    },
                )
            },
            move || prepare_host.prepare_natural_cleanup(),
            move |cleanup_succeeded| {
                if reap_host.child_reaped.load(Ordering::Acquire) {
                    reap_host.publish_exit_if_drained();
                    return crate::process_session::NaturalReapFinish::Complete;
                }
                if reap_host.child_wait_ownership_lost.load(Ordering::Acquire) {
                    let _signal = reap_host.child_signal_lock.lock().unwrap();
                    if !reap_host.pty_drained.load(Ordering::Acquire) {
                        return crate::process_session::NaturalReapFinish::Pending;
                    }
                    match child_identity.matches_current() {
                        Ok(false) => {}
                        Ok(true) | Err(_) => {
                            return crate::process_session::NaturalReapFinish::Failed;
                        }
                    }
                    child
                        .take()
                        .expect("reserved child releases lost wait ownership once")
                        .abandon_wait_ownership();
                    *reap_host.child_exit.0.lock().unwrap() = Some(TerminalExit::unknown(
                        "terminal child wait ownership was lost before native status was available",
                    ));
                    reap_host.child_reaped.store(true, Ordering::Release);
                    drop(_signal);
                    reap_host.child_exit.1.notify_all();
                    reap_host.publish_exit_if_drained();
                    return crate::process_session::NaturalReapFinish::Complete;
                }
                let done = crate::process_session::poll_reserved_session_leader(
                    crate::process_session::ReservedChildReap {
                        signal_lock: &reap_host.child_signal_lock,
                        pty_drained: &reap_host.pty_drained,
                        termination_started: &reap_host.termination_started,
                        cleanup_complete: &reap_host.group_escalation_complete,
                        child_reaped: &reap_host.child_reaped,
                        wait_ownership_lost: &reap_host.child_wait_ownership_lost,
                    },
                    cleanup_succeeded,
                    || {
                        let child = child.take().expect("reserved child is reaped once");
                        let exit = reap_reserved_child_status(session);
                        child.abandon_wait_ownership();
                        *reap_host.child_exit.0.lock().unwrap() = Some(exit);
                        reap_host.child_exit.1.notify_all();
                    },
                );
                if done {
                    reap_host.publish_exit_if_drained();
                    crate::process_session::NaturalReapFinish::Complete
                } else {
                    crate::process_session::NaturalReapFinish::Pending
                }
            },
        );
        Ok(shared)
    }

    fn serve_client(host: Arc<HostShared>, mut stream: UnixStream) -> anyhow::Result<()> {
        stream.set_read_timeout(Some(HOST_HANDSHAKE_TIMEOUT))?;
        let hello_frame = read_required_frame(&mut stream, "client hello")?;
        if hello_frame.kind != MessageKind::ClientHello
            || hello_frame.sequence != 0
            || hello_frame.flags & !(FLAG_VIEWER_SIZE_ACKS | FLAG_TERMINATE_ONLY) != 0
            || hello_frame.flags == (FLAG_VIEWER_SIZE_ACKS | FLAG_TERMINATE_ONLY)
        {
            anyhow::bail!("terminal-host client did not send ClientHello");
        }
        let hello = ClientHello::decode(&hello_frame.payload)?;
        let response = authenticate_client(&host, &hello)?;
        let terminate_only = hello_frame.flags == FLAG_TERMINATE_ONLY;
        if hello_frame.version != response.selected_version
            || (!terminate_only && !response.granted_rights.contains(CapabilityRights::READ))
            || (terminate_only
                && (hello.role != ClientRole::Admin
                    || response.granted_rights != CapabilityRights::TERMINATE))
        {
            anyhow::bail!("terminal-host capability denied");
        }
        let selected_version = response.selected_version;
        let granted_rights = response.granted_rights;
        let launch_owner = LaunchOwnerConnection::claim(host.clone(), granted_rights);
        let viewer_size_acks = hello_frame.flags & FLAG_VIEWER_SIZE_ACKS != 0
            && granted_rights.contains(CapabilityRights::RESIZE);
        let mut hello_response = Frame::new(MessageKind::HostHello, response.encode());
        if viewer_size_acks {
            hello_response.flags = FLAG_VIEWER_SIZE_ACKS;
        } else if terminate_only {
            hello_response.flags = FLAG_TERMINATE_ONLY;
        }
        hello_response.request_id = hello_frame.request_id;
        write_frame(&mut stream, &hello_response)?;

        if terminate_only {
            let terminate = read_required_frame(&mut stream, "terminate-only request")?;
            if terminate.kind != MessageKind::Terminate
                || terminate.flags != 0
                || terminate.sequence != 0
                || terminate.request_id != 0
                || !terminate.payload.is_empty()
            {
                anyhow::bail!("terminate-only client sent an unexpected request");
            }
            host.request_termination();
            return Ok(());
        }

        // Authenticated interactive clients are long-lived. Clear the
        // unauthenticated handshake deadline before entering their command
        // and live-output loops.
        stream.set_read_timeout(None)?;
        let client = host.next_client.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = sync_channel(256);
        let tap = HostTap::new(
            sender,
            Arc::new(cmux_tui_process::unix::clone_stream(&stream)?),
            MAX_HOST_CLIENT_QUEUED_BYTES,
        );
        let command_sender = tap.clone();
        let (snapshot, colors, snapshot_sequence) = {
            // Match resize's viewer -> size -> cell metrics -> parser ->
            // broadcast lock order so a snapshot contains one atomic
            // logical and pixel geometry.
            let mut viewer_sizes = host.viewer_sizes.lock().unwrap();
            let size = host.size.lock().unwrap();
            let cell_pixels = *host.cell_pixels.lock().unwrap();
            let mut term = host.term.lock().unwrap();
            let replay = term.vt_replay_bounded_theme_portable_with_aliases(
                crate::surface::VT_REPLAY_MAX_BYTES,
            )?;
            let colors = term.color_overrides();
            let (cols, rows) = *size;
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
                host.sequence.load(Ordering::Acquire),
            )
        };
        // The tap and snapshot boundary are now atomic members of the live
        // stream. Releasing a deferred fast-exit event here places Exit after
        // that boundary even if the PTY finished before this connection.
        launch_owner.stream_ready();
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

        let mut command_stream = cmux_tui_process::unix::clone_stream(&stream)?;
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
                        let status = clear_history_ack_status(
                            command_host.clear_history_or_encode_key(fallback_key.as_ref()),
                        );
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

        fn spawn_sleeping_host_for_test(name: &str) -> (Arc<HostShared>, PathBuf) {
            let root = std::env::temp_dir()
                .join(format!("cmux-{name}-{}", crate::workspace_registry::new_uuid_v4()));
            fs::create_dir_all(&root).unwrap();
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: root.join("host.sock").to_string_lossy().into_owned(),
                record_path: root.join("host.json").to_string_lossy().into_owned(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec!["/bin/sh".into(), "-c".into(), "exec /bin/sleep 60".into()],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };
            (spawn_host_runtime(&launch, &bootstrapped).unwrap(), root)
        }

        fn stop_test_host(host: &Arc<HostShared>, root: &Path) {
            host.request_termination();
            assert!(
                host.wait_for_child_exit(Duration::from_secs(3)),
                "test terminal host did not stop"
            );
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn unauthenticated_host_client_handshake_is_time_bounded() {
            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            let (host, root) = spawn_sleeping_host_for_test("host-handshake-timeout");
            let (server, client) = cmux_tui_process::unix::pair_stream().unwrap();
            let client_host = host.clone();
            let (done_sender, done_receiver) = sync_channel(1);
            let worker = thread::spawn(move || {
                done_sender.send(serve_client(client_host, server)).unwrap();
            });

            let result =
                done_receiver.recv_timeout(HOST_HANDSHAKE_TIMEOUT + Duration::from_secs(1));
            drop(client);
            if result.is_err() {
                let _ = done_receiver.recv_timeout(Duration::from_secs(1));
            }
            worker.join().unwrap();
            stop_test_host(&host, &root);

            match result {
                Ok(Err(_)) => {}
                Ok(Ok(())) => panic!("an empty client completed a terminal-host handshake"),
                Err(RecvTimeoutError::Timeout) => {
                    panic!("an unauthenticated client retained a host thread past the deadline")
                }
                Err(RecvTimeoutError::Disconnected) => {
                    panic!("the terminal-host client worker disconnected without a result")
                }
            }
        }

        #[test]
        fn host_client_admission_is_bounded_and_reusable() {
            let active = Arc::new(AtomicUsize::new(0));
            let mut admissions = (0..MAX_TERMINAL_HOST_CLIENTS)
                .map(|_| {
                    HostClientAdmission::try_acquire(&active)
                        .expect("a client below the configured limit was rejected")
                })
                .collect::<Vec<_>>();

            assert!(
                HostClientAdmission::try_acquire(&active).is_none(),
                "the terminal host admitted more than its configured client limit"
            );
            admissions.pop();
            let replacement = HostClientAdmission::try_acquire(&active)
                .expect("a released client admission was not reusable");
            drop(replacement);
            drop(admissions);

            assert_eq!(active.load(Ordering::Acquire), 0);
        }

        #[test]
        fn idle_host_service_wait_is_event_driven() {
            let root = std::env::temp_dir().join(format!(
                "cmux-hsw-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).unwrap();
            let endpoint = root.join("host.sock");
            let listener = UnixListener::bind(&endpoint).unwrap();
            listener.set_nonblocking(true).unwrap();
            let (mut service_waker, mut service_waiter) =
                cmux_tui_process::unix::pair_stream().unwrap();
            let dead = Arc::new(AtomicBool::new(false));
            let waiter_dead = dead.clone();
            let listener_fd = listener.as_raw_fd();
            let (done_sender, done_receiver) = sync_channel(1);
            let worker = thread::spawn(move || {
                done_sender
                    .send(wait_for_host_service_activity(
                        listener_fd,
                        &mut service_waiter,
                        &waiter_dead,
                        None,
                    ))
                    .unwrap();
            });

            let first = done_receiver.recv_timeout(Duration::from_millis(75));
            dead.store(true, Ordering::Release);
            let _ = service_waker.write_all(&[1]);
            let (waited_for_event, result) = match first {
                Ok(result) => (false, result),
                Err(RecvTimeoutError::Timeout) => {
                    (true, done_receiver.recv_timeout(Duration::from_secs(1)).unwrap())
                }
                Err(RecvTimeoutError::Disconnected) => {
                    panic!("the host service waiter disconnected without a result")
                }
            };
            worker.join().unwrap();
            drop(listener);
            let _ = fs::remove_file(endpoint);
            let _ = fs::remove_dir(root);

            assert!(waited_for_event, "an idle host service woke without socket activity");
            assert!(!result.unwrap(), "the exit wake was reported as client activity");
        }

        #[test]
        fn host_service_wait_reports_listener_activity() {
            let root = std::env::temp_dir().join(format!(
                "cmux-hsc-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).unwrap();
            let endpoint = root.join("host.sock");
            let listener = UnixListener::bind(&endpoint).unwrap();
            listener.set_nonblocking(true).unwrap();
            let (_service_waker, mut service_waiter) =
                cmux_tui_process::unix::pair_stream().unwrap();
            let dead = AtomicBool::new(false);
            let listener_fd = listener.as_raw_fd();
            let worker = thread::spawn(move || {
                wait_for_host_service_activity(listener_fd, &mut service_waiter, &dead, None)
            });

            let client = UnixStream::connect(&endpoint).unwrap();
            let activity = worker.join().unwrap().unwrap();
            drop(client);
            drop(listener);
            let _ = fs::remove_file(endpoint);
            let _ = fs::remove_dir(root);

            assert!(activity, "a waiting host service ignored a client connection");
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn host_pty_creation_waits_for_process_barrier() {
            const CHILD_ENV: &str = "CMUX_TUI_TEST_HOST_PTY_CREATION_BARRIER";
            const TEST_NAME: &str =
                "terminal_host_runtime::unix::tests::host_pty_creation_waits_for_process_barrier";
            if std::env::var_os(CHILD_ENV).is_none() {
                let status = Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", TEST_NAME])
                    .env(CHILD_ENV, "1")
                    .status()
                    .unwrap();
                assert!(status.success(), "host PTY barrier subprocess failed: {status}");
                return;
            }

            fn descriptor_count() -> usize {
                fs::read_dir("/dev/fd").unwrap().count()
            }

            drop(crate::process_session::reserve_child_reaper().unwrap());
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: "/tmp/cmux-host-pty-barrier.sock".into(),
                record_path: "/tmp/cmux-host-pty-barrier.json".into(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec!["/bin/sleep".into(), "60".into()],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };
            let baseline = descriptor_count();
            let process_barrier = cmux_tui_process::ProcessCreationGuard::acquire();
            let (started_sender, started_receiver) = sync_channel(1);
            let worker = thread::spawn(move || {
                started_sender.send(()).unwrap();
                spawn_host_runtime(&launch, &bootstrapped)
            });
            started_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            let deadline = Instant::now() + Duration::from_millis(250);
            let mut observed = baseline;
            while observed == baseline && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(5));
                observed = descriptor_count();
            }

            drop(process_barrier);
            let host = worker.join().unwrap().unwrap();
            host.request_termination();
            let _ = host.wait_for_child_exit(Duration::from_secs(1));

            assert_eq!(
                observed, baseline,
                "host PTY descriptors were created outside the process barrier"
            );
        }

        #[test]
        fn host_pty_does_not_inherit_launcher_command() {
            const CHILD_ENV: &str = "CMUX_TUI_TEST_HOST_LAUNCHER_ENV";
            const LAUNCHER_ENV: &str = "CMUX_TUI_LAUNCHER_COMMAND";
            const TEST_NAME: &str =
                "terminal_host_runtime::unix::tests::host_pty_does_not_inherit_launcher_command";
            if std::env::var_os(CHILD_ENV).is_none() {
                let status = Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", TEST_NAME])
                    .env(CHILD_ENV, "1")
                    .env(LAUNCHER_ENV, "npx cmux@1.2.3")
                    .status()
                    .unwrap();
                assert!(status.success(), "host PTY environment subprocess failed: {status}");
                return;
            }

            let root = std::env::temp_dir().join(format!(
                "cmux-host-launcher-env-{}",
                crate::workspace_registry::new_uuid_v4()
            ));
            fs::create_dir_all(&root).unwrap();
            let result = root.join("launcher.txt");
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: root.join("host.sock").to_string_lossy().into_owned(),
                record_path: root.join("host.json").to_string_lossy().into_owned(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "result=\"$CMUX_TUI_TEST_RESULT\"; \
                     printf '%s' \"${CMUX_TUI_LAUNCHER_COMMAND-unset}\" > \"$result.tmp\"; \
                     mv \"$result.tmp\" \"$result\"; exec /bin/sleep 60"
                        .into(),
                ],
                extra_env: vec![(
                    "CMUX_TUI_TEST_RESULT".into(),
                    result.to_string_lossy().into_owned(),
                )],
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };

            let host = spawn_host_runtime(&launch, &bootstrapped).unwrap();
            let deadline = Instant::now() + Duration::from_secs(2);
            while !result.exists() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            let inherited = fs::read_to_string(&result).unwrap();
            host.request_termination();
            let _ = host.wait_for_child_exit(Duration::from_secs(1));
            let _ = fs::remove_dir_all(root);

            assert_eq!(inherited, "unset", "host PTY inherited launcher replay metadata");
        }

        #[test]
        fn failed_host_pty_initialization_reaps_spawned_child() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-spawn-failure-{}",
                crate::workspace_registry::new_uuid_v4()
            ));
            fs::create_dir_all(&root).unwrap();
            let ready = root.join("ready");
            let descendant = root.join("descendant");
            let _failure = crate::process_session::force_post_spawn_failure_for_test(ready.clone());
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: root.join("host.sock").to_string_lossy().into_owned(),
                record_path: root.join("host.json").to_string_lossy().into_owned(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!(
                        "trap '' HUP TERM; \
                         (trap '' HUP TERM; exec /bin/sleep 60) & \
                         echo $! > {}; \
                         echo $$ > {}; exec /bin/sleep 60",
                        descendant.display(),
                        ready.display()
                    ),
                ],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };

            let error = match spawn_host_runtime(&launch, &bootstrapped) {
                Ok(_) => panic!("forced hosted PTY initialization failure unexpectedly succeeded"),
                Err(error) => error,
            };
            assert!(error.to_string().contains("forced post-spawn PTY initialization failure"));
            let pid = fs::read_to_string(&ready).unwrap().trim().parse::<libc::pid_t>().unwrap();
            let descendant_pid =
                fs::read_to_string(&descendant).unwrap().trim().parse::<libc::pid_t>().unwrap();
            let mut status = 0;
            // SAFETY: the marker contains the exact child PID spawned by this test.
            let result = unsafe { libc::waitpid(pid, &raw mut status, libc::WNOHANG) };
            let wait_error = std::io::Error::last_os_error();
            if result == 0 {
                // SAFETY: the child is still owned by this test process.
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                    libc::waitpid(pid, &raw mut status, 0);
                }
            }
            let descendant_deadline = Instant::now() + Duration::from_secs(2);
            let descendant_gone = loop {
                // SAFETY: signal zero performs a non-mutating liveness probe.
                if unsafe { libc::kill(descendant_pid, 0) } < 0
                    && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
                {
                    break true;
                }
                if Instant::now() >= descendant_deadline {
                    break false;
                }
                thread::sleep(Duration::from_millis(10));
            };
            if !descendant_gone {
                // SAFETY: the marker names the test's retained-session descendant.
                unsafe {
                    libc::kill(descendant_pid, libc::SIGKILL);
                }
            }
            let _ = fs::remove_dir_all(root);

            assert_eq!(result, -1, "failed hosted PTY initialization left child {pid} unreaped");
            assert_eq!(wait_error.raw_os_error(), Some(libc::ECHILD));
            assert!(
                descendant_gone,
                "failed hosted PTY initialization left descendant {descendant_pid} running"
            );
        }

        #[cfg(target_os = "linux")]
        #[test]
        fn saturated_listener_never_returns_an_unconnected_host_stream() {
            let path = std::env::temp_dir().join(format!(
                "cmux-host-backlog-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let (address, address_len) = unix_socket_address(&path).unwrap();
            // SAFETY: socket has no pointer arguments and returns a new owned
            // descriptor on success.
            let listener =
                unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
            assert!(listener >= 0, "failed to create the test listener");
            // SAFETY: listener is a fresh successful socket result and this
            // OwnedFd takes its sole ownership.
            let listener = unsafe { OwnedFd::from_raw_fd(listener) };
            // SAFETY: address is initialized for this exact filesystem path
            // and listener owns a valid AF_UNIX descriptor.
            let result = unsafe {
                libc::bind(
                    listener.as_raw_fd(),
                    (&raw const address).cast::<libc::sockaddr>(),
                    address_len,
                )
            };
            assert_eq!(result, 0, "failed to bind the test listener");
            // SAFETY: listener remains a valid bound AF_UNIX descriptor.
            let result = unsafe { libc::listen(listener.as_raw_fd(), 0) };
            assert_eq!(result, 0, "failed to create a zero-backlog test listener");

            let mut queued = Vec::new();
            let mut timeout_elapsed = None;
            for _ in 0..32 {
                let started = Instant::now();
                match connect_until(&path, started + Duration::from_millis(75)) {
                    Ok(stream) => queued.push(stream),
                    Err(error) => {
                        assert_eq!(
                            error.downcast_ref::<std::io::Error>().map(std::io::Error::kind),
                            Some(std::io::ErrorKind::TimedOut)
                        );
                        timeout_elapsed = Some(started.elapsed());
                        break;
                    }
                }
            }
            let elapsed =
                timeout_elapsed.expect("saturated host listener returned unconnected streams");
            assert!(
                elapsed < Duration::from_secs(1),
                "saturated host connect exceeded its deadline bound: {elapsed:?}"
            );
            drop(queued);
            drop(listener);
            fs::remove_file(path).unwrap();
        }

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

        fn exited_host_fixture(exit_record_path: PathBuf) -> Arc<HostShared> {
            let mut term = Terminal::new(80, 24, 1_000, Callbacks::default()).unwrap();
            term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
            let (service_exit_waker, service_exit_waiter) = UnixStream::pair().unwrap();
            let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
            let host = Arc::new(HostShared {
                terminal_id: TerminalId::random().unwrap(),
                incarnation: HostIncarnation::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
                capabilities: CapabilityStore::new(64),
                term: Mutex::new(term),
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
                taps_changed: Condvar::new(),
                broadcast_lock: Mutex::new(()),
                sequence: AtomicU64::new(0),
                next_client: AtomicU64::new(1),
                active_clients: Arc::new(AtomicUsize::new(0)),
                dead: AtomicBool::new(false),
                launch_owner_claimed: AtomicBool::new(true),
                launch_owner_stream_ready: AtomicBool::new(true),
                launch_owner_completed: AtomicBool::new(false),
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
                service_exit_waker: Mutex::new(service_exit_waker),
                service_exit_waiter: Mutex::new(Some(service_exit_waiter)),
                termination_started: AtomicBool::new(false),
                child_signal_lock: Mutex::new(()),
                child_reaped: AtomicBool::new(true),
                child_wait_ownership_lost: AtomicBool::new(false),
                group_escalation_complete: AtomicBool::new(false),
                normal_cleanup_failures: AtomicUsize::new(0),
                normal_cleanup_attempts: AtomicUsize::new(0),
            });
            HostShared::start_exit_publisher(&host, exit_publish_receiver).unwrap();
            host
        }

        fn test_host_shared() -> Arc<HostShared> {
            let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            term.resize(80, 24, u32::from(DEFAULT_CELL_PIXELS.0), u32::from(DEFAULT_CELL_PIXELS.1))
                .unwrap();
            let (pty_drain_waker, _pty_drain_waiter) = UnixStream::pair().unwrap();
            let (service_exit_waker, service_exit_waiter) = UnixStream::pair().unwrap();
            let (exit_publish_requests, exit_publish_receiver) = mpsc_channel();
            let host = Arc::new(HostShared {
                terminal_id: TerminalId::random().unwrap(),
                incarnation: HostIncarnation::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
                capabilities: CapabilityStore::new(64),
                term: Mutex::new(term),
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
                taps_changed: Condvar::new(),
                broadcast_lock: Mutex::new(()),
                sequence: AtomicU64::new(0),
                next_client: AtomicU64::new(1),
                active_clients: Arc::new(AtomicUsize::new(0)),
                dead: AtomicBool::new(false),
                launch_owner_claimed: AtomicBool::new(false),
                launch_owner_stream_ready: AtomicBool::new(false),
                launch_owner_completed: AtomicBool::new(false),
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
                service_exit_waker: Mutex::new(service_exit_waker),
                service_exit_waiter: Mutex::new(Some(service_exit_waiter)),
                termination_started: AtomicBool::new(false),
                child_signal_lock: Mutex::new(()),
                child_reaped: AtomicBool::new(false),
                child_wait_ownership_lost: AtomicBool::new(false),
                group_escalation_complete: AtomicBool::new(false),
                normal_cleanup_failures: AtomicUsize::new(0),
                normal_cleanup_attempts: AtomicUsize::new(0),
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
                supports_terminate_only: true,
                supports_clear_history: true,
            };
            let record_path = record.record_path(&root);
            let lease = HostLivenessLease::acquire(liveness_path(&record_path, &record)).unwrap();
            write_record(&record_path, &record).unwrap();
            (record_path, record, lease)
        }

        fn accept_test_client_until(
            listener: &UnixListener,
            timeout: Duration,
        ) -> Option<UnixStream> {
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + timeout;
            loop {
                match listener.accept() {
                    Ok((stream, _)) => return Some(stream),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        let remaining = deadline.checked_duration_since(Instant::now())?;
                        thread::sleep(remaining.min(Duration::from_millis(1)));
                    }
                    Err(error) => panic!("test listener failed: {error}"),
                }
            }
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
        fn snapshot_payload_matches_the_cross_language_v3_golden_bytes() {
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
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: control_responses.clone(),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
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
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: Arc::new(ControlResponses::new()),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
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
        fn liveness_lease_drop_unlocks_an_inherited_file_description() {
            let (record_path, record, lease) = record_fixture("inherited-liveness");
            let lease_fd = lease.file.as_raw_fd();
            let mut command = Command::new("/bin/sleep");
            command.arg("60");
            // SAFETY: fcntl is async-signal-safe, and this only clears
            // close-on-exec on the test-owned descriptor in the child between
            // fork and exec. The parent descriptor remains close-on-exec.
            unsafe {
                command.pre_exec(move || {
                    let flags = libc::fcntl(lease_fd, libc::F_GETFD);
                    if flags == -1 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if libc::fcntl(lease_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) == -1 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
            let mut inheritor = command.spawn().unwrap();

            drop(lease);
            let observed = terminal_host_record_liveness(&record_path, &record).unwrap();

            inheritor.kill().unwrap();
            inheritor.wait().unwrap();
            assert!(
                remove_stale_terminal_host_record(&record_path, &record).unwrap(),
                "test cleanup could not reclaim the released liveness record"
            );
            let _ = fs::remove_dir_all(record_path.parent().unwrap());
            assert_eq!(
                observed,
                TerminalHostLiveness::Dead,
                "a forked child retained the terminal host's released liveness lock"
            );
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
        fn exact_record_loader_does_not_read_unrelated_host_files() {
            let (record_path, record, lease) = record_fixture("exact-record");
            let root = record_path.parent().unwrap();
            fs::write(root.join("unrelated.json"), b"{invalid-json").unwrap();

            let loaded = load_terminal_host_record(root, &record.terminal_id).unwrap();

            assert_eq!(loaded, Some((record_path.clone(), record.clone())));
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn private_directory_setup_rejects_symlink_without_changing_target_permissions() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-private-dir-symlink-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            let target = root.join("target");
            fs::create_dir(&target).unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
            let link = root.join("endpoint");
            std::os::unix::fs::symlink(&target, &link).unwrap();

            let result = prepare_private_dir(&link);
            let target_mode = fs::metadata(&target).unwrap().mode() & 0o777;
            let _ = fs::remove_dir_all(&root);

            assert!(result.is_err(), "private directory setup accepted a symlink");
            assert_eq!(target_mode, 0o755, "private directory setup changed the symlink target");
        }

        #[test]
        fn private_directory_setup_tightens_an_owned_directory() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-private-dir-owned-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();

            prepare_private_dir(&root).unwrap();
            let mode = fs::metadata(&root).unwrap().mode() & 0o777;
            let _ = fs::remove_dir_all(&root);

            assert_eq!(mode, 0o700);
        }

        #[test]
        fn strict_record_loader_rejects_fifo_without_blocking() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-record-fifo-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            let path = root.join(format!("{}.json", TerminalId::random().unwrap().to_hex()));
            let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
            // SAFETY: c_path is a valid, NUL-terminated path owned by this test.
            assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);

            let loader_root = root.clone();
            let (result_tx, result_rx) = sync_channel(1);
            let loader = thread::spawn(move || {
                let _ = result_tx.send(load_terminal_host_records_strict(
                    &loader_root,
                    1,
                    Instant::now() + Duration::from_secs(1),
                ));
            });
            let completed = match result_rx.recv_timeout(Duration::from_millis(500)) {
                Ok(result) => Some(result),
                Err(RecvTimeoutError::Timeout) => {
                    let mut writer = OpenOptions::new().write(true).open(&path).unwrap();
                    writer.write_all(b"{}").unwrap();
                    None
                }
                Err(RecvTimeoutError::Disconnected) => panic!("record loader stopped"),
            };
            loader.join().unwrap();
            let _ = fs::remove_dir_all(&root);

            assert!(completed.is_some(), "strict terminal-host scan blocked while opening a FIFO");
            assert!(completed.unwrap().is_err(), "FIFO was accepted as a discovery record");
        }

        #[test]
        fn adoption_record_loader_rejects_fifo_without_blocking() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-adoption-record-fifo-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            let path = root.join(format!("{}.json", TerminalId::random().unwrap().to_hex()));
            let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
            // SAFETY: c_path is a valid, NUL-terminated path owned by this test.
            assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);

            let loader_root = root.clone();
            let (result_tx, result_rx) = sync_channel(1);
            let loader = thread::spawn(move || {
                let _ = result_tx.send(load_terminal_host_records(&loader_root));
            });
            let completed = match result_rx.recv_timeout(Duration::from_millis(500)) {
                Ok(result) => Some(result),
                Err(RecvTimeoutError::Timeout) => {
                    let mut writer = OpenOptions::new().write(true).open(&path).unwrap();
                    writer.write_all(b"{}").unwrap();
                    None
                }
                Err(RecvTimeoutError::Disconnected) => panic!("record loader stopped"),
            };
            loader.join().unwrap();
            let _ = fs::remove_dir_all(&root);

            assert!(completed.is_some(), "terminal-host adoption blocked while opening a FIFO");
            assert!(completed.unwrap().unwrap().is_empty(), "FIFO was adopted as a host record");
        }

        #[test]
        fn strict_record_loader_rejects_oversized_file_before_decoding() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-record-oversized-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            prepare_private_dir(&root).unwrap();
            let path = root.join(format!("{}.json", TerminalId::random().unwrap().to_hex()));
            fs::write(&path, vec![b'x'; MAX_LAUNCH_PAYLOAD + 1]).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

            let error = load_terminal_host_records_strict(
                &root,
                1,
                Instant::now() + Duration::from_secs(1),
            )
            .unwrap_err();
            let _ = fs::remove_dir_all(&root);

            assert!(
                format!("{error:#}").contains("exceeds size limit"),
                "oversized record reached JSON decoding: {error:#}"
            );
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
            legacy.supports_terminate_only = false;
            legacy.supports_clear_history = false;
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
        fn hosted_child_exit_retries_a_failed_session_cleanup() {
            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            NEXT_HOST_NORMAL_CLEANUP_FAILURES.store(1, Ordering::Release);
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: "/tmp/cmux-host-reap-retry.sock".into(),
                record_path: "/tmp/cmux-host-reap-retry.json".into(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };
            let host = spawn_host_runtime(&launch, &bootstrapped).unwrap();

            let retry_deadline = Instant::now() + Duration::from_secs(3);
            while (!host.child_reaped.load(Ordering::Acquire)
                || host.normal_cleanup_attempts.load(Ordering::Acquire) < 2)
                && Instant::now() < retry_deadline
            {
                thread::sleep(Duration::from_millis(10));
            }
            let retried = host.normal_cleanup_attempts.load(Ordering::Acquire) >= 2;
            let reaped = host.child_reaped.load(Ordering::Acquire);
            host.request_termination();
            let _ = host.wait_for_child_exit(Duration::from_secs(1));

            assert!(
                retried,
                "hosted PTY cleanup was not retried after a transient failure (attempts={})",
                host.normal_cleanup_attempts.load(Ordering::Acquire)
            );
            assert!(reaped, "the hosted PTY leader remained unreaped after cleanup could succeed");
        }

        #[test]
        fn hosted_session_kill_observes_the_waitable_leader_under_its_owner_lock() {
            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            let root = std::env::temp_dir()
                .join(format!("cmux-host-owner-{}", crate::workspace_registry::new_uuid_v4()));
            fs::create_dir_all(&root).unwrap();
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: root.join("host.sock").to_string_lossy().into_owned(),
                record_path: root.join("host.json").to_string_lossy().into_owned(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "trap '' HUP TERM; while :; do sleep 60; done".into(),
                ],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };
            let host = spawn_host_runtime(&launch, &bootstrapped).unwrap();
            host.termination_started.store(true, Ordering::Release);

            let started = Instant::now();
            let killed = host
                .kill_terminal_process_session_until(Instant::now() + Duration::from_secs(1))
                .unwrap();
            let elapsed = started.elapsed();

            host.group_escalation_complete.store(true, Ordering::Release);
            host.child_exit.1.notify_all();
            host.wake_reserved_child_reaper();
            let _ = host.wait_for_child_exit(Duration::from_secs(2));
            let _ = fs::remove_dir_all(root);

            assert!(killed, "host cleanup could not observe its SIGKILLed leader");
            assert!(
                elapsed < Duration::from_millis(500),
                "host cleanup waited on the reaper while retaining its owner lock: {elapsed:?}"
            );
            assert!(host.child_reaped.load(Ordering::Acquire));
        }

        #[test]
        fn hosted_child_observation_uses_the_reserved_shared_reaper() {
            const CHILDREN: usize = 4;

            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            let worker_baseline = crate::process_session::dedicated_natural_reap_workers_for_test();
            let observer_baseline = HOST_CHILD_OBSERVER_SPAWNS.load(Ordering::Acquire);
            let mut hosts = Vec::new();
            for index in 0..CHILDREN {
                let bootstrap = HostBootstrap {
                    min_version: PROTOCOL_VERSION,
                    max_version: PROTOCOL_VERSION,
                    terminal_id: TerminalId::random().unwrap(),
                    owner_token: CapabilityToken::random().unwrap(),
                };
                let mut bootstrap_bytes = Vec::new();
                write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
                let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                    &mut bootstrap_bytes.as_slice(),
                    &mut Vec::new(),
                )
                .unwrap();
                let launch = HostLaunch {
                    endpoint: format!("/tmp/cmux-host-reap-bound-{index}.sock"),
                    record_path: format!("/tmp/cmux-host-reap-bound-{index}.json"),
                    term: "xterm-256color".into(),
                    cols: 80,
                    rows: 24,
                    cell_pixels: DEFAULT_CELL_PIXELS,
                    scrollback: 100,
                    cwd: Some("/tmp".into()),
                    command: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
                    extra_env: Vec::new(),
                    default_colors: DefaultColors::default(),
                    kitty_graphics_limits: KittyGraphicsLimits::default(),
                };
                hosts.push(spawn_host_runtime(&launch, &bootstrapped).unwrap());
            }

            for host in &hosts {
                let deadline = Instant::now() + Duration::from_secs(3);
                while !host.child_reaped.load(Ordering::Acquire) && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(10));
                }
                assert!(
                    host.child_reaped.load(Ordering::Acquire),
                    "hosted PTY child was not reaped by the bounded shared worker"
                );
            }
            let dedicated_workers =
                crate::process_session::dedicated_natural_reap_workers_for_test()
                    .saturating_sub(worker_baseline);
            let dedicated_observers = HOST_CHILD_OBSERVER_SPAWNS
                .load(Ordering::Acquire)
                .saturating_sub(observer_baseline);

            for host in hosts {
                host.request_termination();
                let _ = host.wait_for_child_exit(Duration::from_secs(1));
            }

            assert!(
                dedicated_workers <= 1,
                "hosted PTY observation retained {dedicated_workers} shared retry workers"
            );
            assert_eq!(
                dedicated_observers, 0,
                "hosted PTY child observation retained one dedicated thread per child"
            );
        }

        #[test]
        fn hosted_child_exit_cleans_descendants_that_keep_the_slave_open() {
            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            let root = std::env::temp_dir()
                .join(format!("cmux-host-reap-{}", crate::workspace_registry::new_uuid_v4()));
            fs::create_dir_all(&root).unwrap();
            let pid_path = root.join("descendant.pid");
            let ready_path = root.join("descendant.ready");
            let release_path = root.join("leader.release");
            let bootstrap = HostBootstrap {
                min_version: PROTOCOL_VERSION,
                max_version: PROTOCOL_VERSION,
                terminal_id: TerminalId::random().unwrap(),
                owner_token: CapabilityToken::random().unwrap(),
            };
            let mut bootstrap_bytes = Vec::new();
            write_frame(&mut bootstrap_bytes, &bootstrap.into_frame(1)).unwrap();
            let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
                &mut bootstrap_bytes.as_slice(),
                &mut Vec::new(),
            )
            .unwrap();
            let launch = HostLaunch {
                endpoint: root.join("host.sock").to_string_lossy().into_owned(),
                record_path: root.join("host.json").to_string_lossy().into_owned(),
                term: "xterm-256color".into(),
                cols: 80,
                rows: 24,
                cell_pixels: DEFAULT_CELL_PIXELS,
                scrollback: 100,
                cwd: Some("/tmp".into()),
                command: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!(
                        "trap '' HUP TERM; terminal=$(tty); \
                         sleep 30 3<>\"$terminal\" & child=$!; \
                         : > {ready}; echo $child > {pid}; \
                         while [ ! -e {release} ]; do sleep 0.01; done; exit 0",
                        ready = ready_path.display(),
                        pid = pid_path.display(),
                        release = release_path.display(),
                    ),
                ],
                extra_env: Vec::new(),
                default_colors: DefaultColors::default(),
                kitty_graphics_limits: KittyGraphicsLimits::default(),
            };
            let host = spawn_host_runtime(&launch, &bootstrapped).unwrap();
            let start_deadline = Instant::now() + Duration::from_secs(1);
            while !pid_path.exists() && Instant::now() < start_deadline {
                thread::sleep(Duration::from_millis(10));
            }
            let descendant =
                fs::read_to_string(&pid_path).unwrap().trim().parse::<libc::pid_t>().unwrap();
            // SAFETY: signal 0 only probes the test-owned PID.
            assert_eq!(unsafe { libc::kill(descendant, 0) }, 0);
            fs::write(&release_path, b"ready").unwrap();
            let deadline = Instant::now() + Duration::from_secs(3);
            while !host.child_reaped.load(Ordering::Acquire) && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            let naturally_reaped = host.child_reaped.load(Ordering::Acquire);
            // SAFETY: signal 0 only probes the test-owned PID.
            let descendant_alive_before_cleanup = unsafe { libc::kill(descendant, 0) } == 0;

            host.request_termination();
            let _ = host.wait_for_child_exit(Duration::from_secs(1));
            if unsafe { libc::kill(descendant, 0) } == 0 {
                // SAFETY: this PID was written by the test-owned descendant.
                unsafe {
                    libc::kill(descendant, libc::SIGKILL);
                }
            }
            let _ = fs::remove_dir_all(root);

            assert!(
                naturally_reaped,
                "hosted PTY exit waited for EOF from a same-session descendant before cleanup"
            );
            assert!(
                !descendant_alive_before_cleanup,
                "hosted PTY exit left a same-session descendant holding the slave open"
            );
        }

        #[test]
        fn detached_host_process_retains_reap_ownership_when_worker_spawn_fails() {
            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            let child =
                Command::new("/bin/sh").arg("-c").arg("exit 0").spawn().expect("spawn test child");
            let pid = libc::pid_t::try_from(child.id()).expect("child PID fits pid_t");
            let (process, completed) = SpawnedHostProcess::new_for_test(child);
            NEXT_HOST_PROCESS_REAPER_SPAWN_FAILURES.store(1, Ordering::Release);

            process.detach_reaper();

            let reaped_by_owner = completed.recv_timeout(Duration::from_secs(1)).is_ok();
            NEXT_HOST_PROCESS_REAPER_SPAWN_FAILURES.store(0, Ordering::Release);
            if !reaped_by_owner {
                // SAFETY: pid remains the exact test-owned child while its
                // reaper reservation is still outstanding.
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }

            assert!(
                reaped_by_owner,
                "detached terminal-host cleanup abandoned the child after thread spawn failed"
            );
            let mut status = 0;
            // SAFETY: completion proves the reaper dropped its sole Child
            // handle after observing exit, so this call only verifies ECHILD.
            let result = unsafe { libc::waitpid(pid, &raw mut status, libc::WNOHANG) };
            assert_eq!(result, -1);
            assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ECHILD));
        }

        #[test]
        fn spawned_host_process_drop_transfers_waiting_to_the_shared_reaper() {
            let _guard = HOST_REAP_TEST_LOCK.lock().unwrap();
            HOST_PROCESS_INLINE_WAITS.store(0, Ordering::Release);
            let child =
                Command::new("/bin/sh").arg("-c").arg("exit 0").spawn().expect("spawn test child");
            let (process, completed) = SpawnedHostProcess::new_for_test(child);

            drop(process);

            completed.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(
                HOST_PROCESS_INLINE_WAITS.load(Ordering::Acquire),
                0,
                "dropping a launch guard waited for the child on the cancellation thread"
            );
        }

        #[test]
        fn stalled_host_handshake_is_time_bounded() {
            let (record_path, record, lease) = record_fixture("handshake-timeout");
            let endpoint = PathBuf::from(&record.endpoint);
            prepare_private_dir(endpoint.parent().unwrap()).unwrap();
            let _ = fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint).unwrap();
            let stalled = thread::spawn(move || {
                if let Some(_stream) =
                    accept_test_client_until(&listener, Duration::from_millis(500))
                {
                    thread::sleep(Duration::from_millis(200));
                }
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
        fn terminate_only_handshake_uses_one_absolute_deadline() {
            let (record_path, record, lease) = record_fixture("terminate-deadline");
            let endpoint = PathBuf::from(&record.endpoint);
            prepare_private_dir(endpoint.parent().unwrap()).unwrap();
            let _ = fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint).unwrap();
            let stalled = thread::spawn(move || {
                if let Some(mut stream) =
                    accept_test_client_until(&listener, Duration::from_millis(500))
                {
                    for _ in 0..crate::terminal_host_protocol::HEADER_LEN {
                        if stream.write_all(&[0]).is_err() {
                            break;
                        }
                        thread::sleep(Duration::from_millis(20));
                    }
                }
            });

            let started = Instant::now();
            let result = terminate_terminal_host_with_timeout(
                &record,
                &record_path,
                Duration::from_millis(40),
            );
            let elapsed = started.elapsed();
            stalled.join().unwrap();
            let _ = fs::remove_file(endpoint);
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            let _ = fs::remove_dir_all(record_path.parent().unwrap());

            assert!(result.is_err());
            assert!(
                elapsed < Duration::from_millis(250),
                "partial host frames restarted the shutdown timeout: {elapsed:?}"
            );
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
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: control_responses.clone(),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
            };
            let resolver = {
                let control_responses = control_responses.clone();
                thread::spawn(move || {
                    let request =
                        read_required_frame(&mut host, "cell pixel size request").unwrap();
                    assert_eq!(request.kind, MessageKind::SetCellPixelSize);
                    thread::sleep(Duration::from_millis(50));
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
        fn cell_pixel_commit_is_broadcast_to_live_renderer_taps_before_ack() {
            let host = test_host_shared();
            let (renderer_socket, _renderer_peer) = UnixStream::pair().unwrap();
            let (renderer_tx, renderer_rx) = sync_channel(4);
            host.taps
                .lock()
                .unwrap()
                .insert(1, HostTap::new(renderer_tx, Arc::new(renderer_socket), usize::MAX));
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = sync_channel(1);
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

            assert!(host.set_cell_pixel_size(9, 18, 42, &target).unwrap());

            let resized = renderer_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(resized.kind, MessageKind::Resized);
            assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
            assert_eq!(decode_host_resize_payload(&resized.payload).unwrap().cell_pixels, (9, 18));
            let colors = renderer_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(colors.kind, MessageKind::Colors);
            assert!(colors.sequence > resized.sequence);
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
            let (target_tx, target_rx) = sync_channel(3);
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            host.taps.lock().unwrap().insert(1, target.clone());
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
                reader: Some(reader),
                writer: Arc::new(Mutex::new(client)),
                control_responses: Arc::new(ControlResponses::new()),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
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
        fn host_tap_byte_overflow_closes_the_client_socket() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, _receiver) = sync_channel(8);
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
            let (sender, _receiver) = sync_channel(8);
            let tap = HostTap::new(sender, Arc::new(host_socket), MAX_HOST_CLIENT_QUEUED_BYTES);
            let half_output_budget = 4 * 1024 * 1024;

            assert!(tap.try_send(Frame::new(MessageKind::Output, vec![1; half_output_budget],)));
            assert!(!tap.try_send(Frame::new(MessageKind::Output, vec![2; half_output_budget],)));
            let mut byte = [0u8; 1];
            assert_eq!(client_socket.read(&mut byte).unwrap(), 0);
        }

        #[test]
        fn host_tap_channel_overflow_closes_the_client_socket() {
            let (host_socket, mut client_socket) = UnixStream::pair().unwrap();
            client_socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let (sender, _receiver) = sync_channel(1);
            let tap = HostTap::new(sender, Arc::new(host_socket), usize::MAX);

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
                assert_eq!(
                    crate::terminal_host_protocol::decode_terminal_exit(&frames[1].payload)
                        .unwrap(),
                    exit
                );
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
            let host = exited_host_fixture(blocking_parent.join("terminal.exit"));
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
            let (sender, receiver) = sync_channel(8);
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
    acquire_terminal_host_publication, adopt_terminal_host_with_kitty_limits,
    decode_host_resize_payload_for_version, load_terminal_host_record,
};
#[cfg(unix)]
pub use unix::{
    HostAttachment, acknowledge_terminal_host_exit_record, adopt_terminal_host,
    isolate_terminal_host_process_fds, launch_terminal_host, launch_terminal_host_with_identity,
    load_terminal_host_exit_records, load_terminal_host_records, load_terminal_host_records_strict,
    remove_stale_terminal_host_record, serve_terminal_host_stdio, terminal_host_exit_record,
    terminal_host_record_liveness, terminal_host_root, validate_terminal_host_exit_record,
    validate_terminal_host_record,
};
#[cfg(unix)]
pub(crate) use unix::{
    launch_terminal_host_cancellable, launch_terminal_host_with_identity_cancellable,
    terminate_and_confirm_terminal_host_record,
};

#[cfg(not(unix))]
pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
    state_root.join(format!("{session}.terminal-hosts"))
}

#[cfg(not(unix))]
pub fn isolate_terminal_host_process_fds(_args: &[String]) -> anyhow::Result<()> {
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
