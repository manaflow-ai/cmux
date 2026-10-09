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
    ClearHistoryTransition, ConfirmedInputFailure, DefaultColors, SurfaceOptions,
    TerminalStreamProgress, apply_clear_history_transition, replace_ghostty_cursor_defaults,
    write_clear_history_fallback,
};
use crate::terminal_host::{
    CapabilityRights, CapabilityStore, CapabilityToken, ClientHello, ClientRole, HostBootstrap,
    HostHello, HostIncarnation, HostReady, TerminalId,
};
use crate::terminal_host_protocol::{
    CLEAR_HISTORY_ACK_AMBIGUOUS, CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE,
    CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT, CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED,
    CLEAR_HISTORY_ACK_OK, CLEAR_HISTORY_ACK_PRESERVATION_FAILED, CLEAR_HISTORY_ACK_STREAM_TIMEOUT,
    FLAG_COLORS_FOLLOW, FLAG_LAUNCH_ACTIVATION_REQUIRED, FLAG_PTY_CUSTODY, FLAG_SMART_RENDERER,
    FLAG_TERMINAL_METADATA, FLAG_VIEWER_SIZE_ACKS, FLAG_VIEWER_SIZE_PRIORITY, Frame,
    HostLaunchFailure, HostLaunchFailureKind, KITTY_IMAGE_ALIAS_COUNT_LEN,
    KITTY_IMAGE_ALIAS_ENCODED_LEN, LAUNCH_ACTIVATION_PROTOCOL_VERSION, MAX_FRAME_PAYLOAD,
    MAX_KITTY_IMAGE_ALIASES, MessageKind, PROTOCOL_VERSION, RESIZE_ACK_CANONICAL_CHANGED,
    TerminalExit, decode_host_launch_failure, decode_terminal_exit, encode_host_launch_failure,
    encode_terminal_exit, read_frame, wait_for_native_child_status_with_reap_result, write_frame,
};

mod grant_failure;
// Neutral code compiles on every platform; until the Windows host uses it,
// only Unix calls it.
#[cfg_attr(not(unix), allow(dead_code))]
mod shared;
#[cfg_attr(not(unix), allow(dead_code))]
mod sys;
pub use grant_failure::{RendererGrantFailure, RendererGrantUnavailable};

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

#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
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
    /// Additive control capability. Missing/false records belong to hosts that
    /// accept fire-and-forget input but cannot confirm PTY delivery.
    #[serde(default)]
    pub supports_input_ack: bool,
    /// Additive snapshot capability. Missing/false records use the v4
    /// snapshot layout without the optional generic terminal metadata tail.
    #[serde(default)]
    pub supports_terminal_metadata: bool,
    /// Additive capability. Missing/false records belong to hosts that would
    /// reject the `CLIPBOARD_READ` right bit, so the daemon never asks them.
    #[serde(default)]
    pub supports_clipboard_read: bool,
    /// Additive handshake capability. Missing/false records belong to hosts
    /// that reject a ClientHello carrying `FLAG_VIEWER_SIZE_PRIORITY`.
    #[serde(default)]
    pub supports_viewer_size_priority: bool,
    /// Additive handshake capability (cx-6so.49 L1). Missing/false records
    /// belong to hosts that reject a ClientHello carrying `FLAG_PTY_CUSTODY`.
    #[serde(default)]
    pub supports_pty_custody: bool,
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
            .field("supports_input_ack", &self.supports_input_ack)
            .field("supports_terminal_metadata", &self.supports_terminal_metadata)
            .field("supports_clipboard_read", &self.supports_clipboard_read)
            .field("supports_viewer_size_priority", &self.supports_viewer_size_priority)
            .field("supports_pty_custody", &self.supports_pty_custody)
            .finish()
    }
}

impl TerminalHostRecord {
    pub fn record_path(&self, root: &Path) -> PathBuf {
        crate::platform::normalize_filesystem_path(root.join(format!("{}.json", self.terminal_id)))
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
        crate::platform::normalize_filesystem_path(root.join(format!("{}.exit", self.terminal_id)))
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
    /// Optional generic terminal metadata restored at the same snapshot
    /// boundary. It is sent only when the client and host negotiate the
    /// `FLAG_TERMINAL_METADATA` capability.
    pub osc_progress: String,
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
    /// The host accepts `FLAG_VIEWER_SIZE_PRIORITY` in a renderer ClientHello.
    pub supports_viewer_size_priority: bool,
}

impl std::fmt::Debug for RendererGrant {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RendererGrant")
            .field("endpoint", &self.endpoint)
            .field("terminal_id", &self.terminal_id)
            .field("incarnation", &self.incarnation)
            .field("token", &"[REDACTED]")
            .field("rights", &self.rights)
            .field("supports_viewer_size_priority", &self.supports_viewer_size_priority)
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
    use std::collections::HashMap;
    use std::fs::{self, File, OpenOptions};
    use std::io as std_io;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, RawFd};
    use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::mpsc::{channel as mpsc_channel, sync_channel};
    use std::sync::{Arc, Condvar, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    use anyhow::Context;
    use cmux_pty::{ChildKiller, MasterPty, PtyCommand};
    use ghostty_vt::Terminal;

    use super::shared::codec::*;
    use super::shared::host_shared::HostShared;
    use super::shared::host_state::*;
    use super::shared::records::*;
    use super::sys::GroupSignal;
    use super::sys::{
        AcceptWaker, HostLivenessLease, acquire_terminal_host_publication_lock, connect_with_retry,
        prepare_endpoint_dir, prepare_private_dir, reserve_terminal_host_publication,
        wait_for_pty_readable_or_forced_drain,
    };
    use super::*;

    /// Own a PTY child until the host's reaper thread has taken responsibility
    /// for it.  Every fallible setup step after `pty.spawn` keeps this guard
    /// alive, so a failed reader, writer, callback, or thread setup cannot
    /// leave the interactive child detached from its parent.
    struct SpawnedPtyChild {
        child: Option<Box<dyn cmux_pty::Child + Send + Sync>>,
        process_groups: [Option<libc::pid_t>; 2],
    }

    fn validated_process_groups(
        groups: impl IntoIterator<Item = Option<libc::pid_t>>,
        host_group: libc::pid_t,
    ) -> Vec<libc::pid_t> {
        let mut valid = Vec::new();
        for group in groups.into_iter().flatten() {
            if group > 0 && group != host_group && !valid.contains(&group) {
                valid.push(group);
            }
        }
        valid
    }

    fn signal_validated_process_groups(
        groups: impl IntoIterator<Item = Option<libc::pid_t>>,
        host_group: libc::pid_t,
        signal: libc::c_int,
        mut send: impl FnMut(libc::pid_t, libc::c_int) -> bool,
    ) -> bool {
        let mut all_succeeded = true;
        for group in validated_process_groups(groups, host_group) {
            all_succeeded &= send(group, signal);
        }
        all_succeeded
    }

    impl SpawnedPtyChild {
        fn new(
            child: Box<dyn cmux_pty::Child + Send + Sync>,
            process_group_leader: Option<libc::pid_t>,
        ) -> Self {
            let child_pid = child.process_id().and_then(|pid| libc::pid_t::try_from(pid).ok());
            Self { child: Some(child), process_groups: [child_pid, process_group_leader] }
        }

        fn child(&self) -> &dyn cmux_pty::Child {
            self.child.as_deref().expect("PTY child is present")
        }

        fn child_mut(&mut self) -> &mut (dyn cmux_pty::Child + Send + Sync) {
            self.child.as_deref_mut().expect("PTY child is present")
        }

        fn wait_and_disarm(&mut self) -> TerminalExit {
            let (exit, reaped) = wait_for_native_child_status_with_reap_result(self.child_mut());
            if reaped {
                self.disarm();
            }
            exit
        }

        fn disarm(&mut self) {
            let _ = self.child.take();
            self.process_groups = [None, None];
        }
    }

    impl Drop for SpawnedPtyChild {
        fn drop(&mut self) {
            let host_group = unsafe { libc::getpgrp() };
            let groups = validated_process_groups(self.process_groups, host_group);
            let groups_signaled = signal_validated_process_groups(
                groups.iter().copied().map(Some),
                host_group,
                libc::SIGKILL,
                |group, signal| {
                    // SAFETY: the group was returned by the PTY or child, is
                    // positive, and is not the terminal-host process group.
                    unsafe { libc::killpg(group, signal) == 0 }
                },
            );
            if let Some(child) = self.child.as_deref_mut() {
                // A valid process group already includes the child. Avoid a
                // second direct PID signal unless group signaling failed, which
                // could leave the child running while the guard waits below.
                if groups.is_empty() || !groups_signaled {
                    let _ = child.kill();
                }
                let _ = child.wait();
            }
        }
    }

    mod adopt_launch;
    mod adopted_child;
    use super::shared::host_accept;
    mod host_scope;
    mod host_signals;
    mod host_start;
    mod pty_custody;
    mod pty_lock;
    mod standby;
    use super::shared::attachment::*;
    pub(crate) use super::shared::clipboard_read::ClipboardReadSignal;
    use super::shared::clipboard_read::OwnerIntent;
    use super::shared::clipboard_read::{ClipboardReads, SystemClock};
    pub(crate) use super::shared::control_responses::{
        ControlResponses, DeferredCellPixelResolution,
    };
    use super::shared::host_parser::{ParserSignals, run_guarded_host_parser, run_host_parser};
    use super::shared::{exited_drain, host_parser};
    pub use adopt_launch::{TerminalHostAdoption, launch_terminal_host_adopting};
    use host_start::HostChild;
    pub(crate) use pty_custody::serve as serve_pty_custody;
    pub use pty_custody::{PtyCustody, request_terminal_host_pty_custody};
    pub(crate) use pty_lock::{remove_released, sweep_released_pty_locks};
    pub(crate) use standby::{
        StandbyTerminalHost, launch_terminal_host_from, launch_terminal_host_seeded,
    };

    pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
        crate::platform::normalize_filesystem_path(
            state_root.join(format!("terminal-hosts-{}", stable_token(session))),
        )
    }

    /// Strip every descriptor except the private bootstrap stdio before the
    /// hidden host starts any threads or opens its endpoint. This runs inside
    /// the freshly exec'd `__terminal-host`, so descriptor enumeration is
    /// race-free and cannot affect the daemon's own open files. It then
    /// installs the host's signal guard (`host_signals`).
    pub fn isolate_terminal_host_process_fds() -> anyhow::Result<()> {
        let (mut last_error, mut inherited) = (None, None);
        let adopted_pty = adopt_launch::adopt_pty_fd_from_process_args();
        for directory in ["/proc/self/fd", "/dev/fd"] {
            match fs::read_dir(directory) {
                Ok(entries) => {
                    let mut descriptors = entries
                        .filter_map(Result::ok)
                        .filter_map(|entry| entry.file_name().to_str()?.parse::<libc::c_int>().ok())
                        .filter(|fd| *fd > libc::STDERR_FILENO && Some(*fd) != adopted_pty)
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
        crate::host_exe::hold_in_use_lock();
        host_signals::install()
    }

    pub mod unadoptable;
    pub(crate) use unadoptable::process_definitely_absent;

    /// The ProcessTree seam, Unix side (cx-ko2e table C): signal the PTY's
    /// process groups.
    impl HostShared {
        pub(crate) fn signal_terminal_process_groups(&self, signal: GroupSignal) {
            let signal = match signal {
                GroupSignal::Hangup => libc::SIGHUP,
                GroupSignal::Kill => libc::SIGKILL,
            };
            let mut groups = Vec::with_capacity(2);
            // The wait thread observes exit with WNOWAIT, then takes this lock
            // before reaping. While we hold it, `!child_reaped` means the
            // original PID/PGID is still kernel-reserved and cannot have been
            // reused between validation and killpg.
            let _signal = self.child_signal_lock.lock().unwrap();
            let child_reserved =
                !self.child_reaped.load(Ordering::Acquire) && self.child_signalable();
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
    }

    pub fn serve_terminal_host_stdio(
        args: &[String],
        reader: &mut impl Read,
        writer: &mut impl Write,
    ) -> anyhow::Result<()> {
        let adopt_fd = adopt_launch::adopt_pty_fd(args)?;
        let mut bootstrapped = crate::terminal_host::bootstrap_stdio_once(reader, writer)?;
        let Some(launch_frame) = read_frame(reader, adopt_launch::max_payload(adopt_fd))? else {
            // Keep the one-frame bootstrap probe useful for compatibility and
            // packaging diagnostics. Production launchers always follow it
            // with Launch on the same private pipe.
            return Ok(());
        };
        let (launch, adopt) = adopt_launch::decode(&launch_frame, adopt_fd, &mut bootstrapped)?;
        crate::debug_spans::install(crate::debug_spans::Trace::start("host", Instant::now()));
        let (shared, _pty_lock) = match adopt_launch::start(&launch, adopt, &bootstrapped) {
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

        let stopping = shared.clone();
        host_signals::on_service_manager_stop(Box::new(move || stopping.request_termination()));
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
        crate::debug_spans::mark("host.endpoint_bound");

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
            supports_input_ack: true,
            supports_terminal_metadata: true,
            supports_clipboard_read: true,
            supports_viewer_size_priority: true,
            supports_pty_custody: true,
        };
        let record_root = Path::new(&launch.record_path)
            .parent()
            .ok_or_else(|| anyhow::anyhow!("terminal-host record has no parent directory"))?;
        let _publication_lock = acquire_terminal_host_publication_lock(record_root)?;
        let lease =
            HostLivenessLease::acquire(liveness_path(Path::new(&launch.record_path), &record))?;
        crate::debug_spans::mark("host.lease_acquired");
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
        host_signals::set_breadcrumb_path(
            Path::new(&launch.record_path).with_extension("signals"),
            record.terminal_id.clone(),
            record.incarnation,
        );
        crate::debug_spans::mark("host.record_written");
        crate::debug_spans::finish(crate::debug_spans::take());

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
        let mut backoff = host_accept::AcceptBackoff::new();
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
                Ok((stream, _)) => match host_accept::serve_accepted(&shared, stream) {
                    Ok(()) => backoff.reset(),
                    Err(error) => backoff.after_error(&shared, &error),
                },
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    // Block until an attachment arrives or the accept waker
                    // reports a lifecycle change (terminal exit, last client
                    // stream closed). The only timeout is the one-shot launch
                    // owner deadline, used until it passes; this loop used to
                    // wake every 20 ms for the whole life of every terminal.
                    let timeout = if shared.launch_owner_claimed.load(Ordering::Acquire) {
                        -1
                    } else {
                        let remaining = launch_owner_deadline.saturating_duration_since(now);
                        i32::try_from(remaining.as_millis().saturating_add(1)).unwrap_or(i32::MAX)
                    };
                    let mut fds = [
                        libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                        libc::pollfd {
                            fd: shared.accept_waker.fd(),
                            events: libc::POLLIN,
                            revents: 0,
                        },
                    ];
                    // SAFETY: both descriptors stay open for this call: the
                    // listener until the accept loop exits and the waker with
                    // `shared`.
                    if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0 {
                        let error = std::io::Error::last_os_error();
                        if error.kind() != std::io::ErrorKind::Interrupted {
                            backoff.after_error(&shared, &error);
                        }
                    } else {
                        // The listener drained without error: a later error
                        // starts a new streak.
                        backoff.reset();
                    }
                    if fds[1].revents != 0 {
                        shared.accept_waker.drain();
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::Interrupted | std::io::ErrorKind::ConnectionAborted
                    ) => {}
                // EMFILE, ENFILE, ENOBUFS, ENOMEM: never end the shell.
                Err(error) => backoff.after_error(&shared, &error),
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
        let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
        let initial_pty_size = pty_size(launch.cols, launch.rows, cell_pixels)?;
        let pty = cmux_pty::open(initial_pty_size)?;
        crate::debug_spans::mark("host.pty_opened");
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
        let cmux_pty::SpawnedPty { master, child } = pty.spawn(command)?;
        crate::debug_spans::mark("host.child_spawned");
        let process_group_leader = master.process_group_leader();
        let child = HostChild::Spawned(SpawnedPtyChild::new(child, process_group_leader));
        host_start::start_host_runtime(launch, bootstrapped, master, child, &launch.seed)
    }

    #[cfg(test)]
    pub(crate) use tests::input_ack_surface_fixture;

    #[cfg(test)]
    mod tests {
        mod clipboard_read;
        mod host_fixture;
        mod parser_failure;
        mod parser_order;
        use super::super::shared::control_responses::ControlResponseWaiter;
        use super::super::shared::host_serve::*;
        use super::super::sys::terminal_host_publication_lock_path;
        use super::*;
        use cmux_pty::{Child, PtyOpenError, PtySize};
        use ghostty_vt::Callbacks;
        use ghostty_vt::CursorShape;
        use host_fixture::{test_host_shared, test_host_shared_with};
        use std::sync::TryLockError;
        use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, SyncSender};

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

        #[derive(Debug)]
        struct GuardTestChild {
            kills: Arc<AtomicUsize>,
        }

        impl ChildKiller for GuardTestChild {
            fn kill(&mut self) -> std::io::Result<()> {
                self.kills.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }

            fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
                Box::new(Self { kills: Arc::clone(&self.kills) })
            }
        }

        impl Child for GuardTestChild {
            fn try_wait(&mut self) -> std::io::Result<Option<cmux_pty::ExitStatus>> {
                Ok(Some(cmux_pty::ExitStatus::with_exit_code(0)))
            }

            fn wait(&mut self) -> std::io::Result<cmux_pty::ExitStatus> {
                Ok(cmux_pty::ExitStatus::with_exit_code(0))
            }

            fn process_id(&self) -> Option<u32> {
                Some(42)
            }
        }

        #[test]
        fn spawned_pty_child_disarm_prevents_late_kill() {
            let kills = Arc::new(AtomicUsize::new(0));
            let child = GuardTestChild { kills: Arc::clone(&kills) };
            let mut guard = SpawnedPtyChild::new(Box::new(child), Some(123));
            let _ = guard.wait_and_disarm();
            assert_eq!(guard.process_groups, [None, None]);
            drop(guard);
            assert_eq!(kills.load(Ordering::Relaxed), 0);
        }

        #[test]
        fn startup_child_cleanup_excludes_host_process_group() {
            let host_group = unsafe { libc::getpgrp() };
            let mut signaled = Vec::new();
            signal_validated_process_groups(
                [Some(host_group), Some(host_group + 1), Some(0), Some(-1)],
                host_group,
                libc::SIGKILL,
                |group, signal| {
                    signaled.push((group, signal));
                    true
                },
            );
            assert_eq!(signaled, vec![(host_group + 1, libc::SIGKILL)]);
        }

        #[test]
        fn startup_child_cleanup_reports_group_signal_failure() {
            let host_group = unsafe { libc::getpgrp() };
            let all_succeeded = signal_validated_process_groups(
                [Some(host_group + 1)],
                host_group,
                libc::SIGKILL,
                |_group, _signal| false,
            );
            assert!(!all_succeeded);
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
                terminal_metadata: Mutex::new(crate::terminal_metadata::TerminalMetadata::default()),
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
                viewer_sizes: Mutex::new(ViewerSizes::default()),
                taps: Mutex::new(HashMap::new()),
                broadcast_lock: Mutex::new(()),
                sequence: AtomicU64::new(0),
                smart: SmartStreamState::new(),
                source_order_lock: Mutex::new(()),
                parser_commands,
                parser_budget: ParserBudget::new(1),
                clipboard: ClipboardReads::new(Arc::new(SystemClock)),
                parser_progress: (Mutex::new(0), Condvar::new()),
                next_client: AtomicU64::new(1),
                dead: AtomicBool::new(false),
                launch_owner_claimed: AtomicBool::new(true),
                launch_owner_stream_ready: AtomicBool::new(true),
                launch_owner_stream_gate: (Mutex::new(()), Condvar::new()),
                active_client_streams: AtomicUsize::new(0),
                accept_waker: AcceptWaker::new().unwrap(),
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
                adopted_session: None,
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
                supports_input_ack: true,
                supports_terminal_metadata: true,
                supports_clipboard_read: false,
                supports_viewer_size_priority: true,
                supports_pty_custody: false,
            };
            let record_path = record.record_path(&root);
            let lease = HostLivenessLease::acquire(liveness_path(&record_path, &record)).unwrap();
            write_record(&record_path, &record).unwrap();
            (record_path, record, lease)
        }

        pub(crate) fn input_ack_surface_fixture() -> (HostAttachment, UnixStream) {
            let terminal_id = TerminalId::random().unwrap();
            let incarnation = HostIncarnation::random().unwrap();
            let owner = CapabilityToken::random().unwrap();
            let nonce = CapabilityToken::random().unwrap();
            let record = TerminalHostRecord {
                record_version: HOST_RECORD_VERSION,
                terminal_id: terminal_id.to_hex(),
                incarnation: incarnation.to_hex(),
                endpoint: "/tmp/cmux-input-ack-surface-test.sock".into(),
                owner_token: encode_hex(owner.as_bytes()),
                host_pid: std::process::id(),
                host_start_nonce: encode_hex(nonce.as_bytes()),
                workspace_key: String::new(),
                supports_set_defaults: false,
                supports_clear_history: false,
                supports_terminate_ack: false,
                supports_input_ack: true,
                supports_terminal_metadata: false,
                supports_clipboard_read: false,
                supports_viewer_size_priority: false,
                supports_pty_custody: false,
            };
            let record_path = std::env::temp_dir().join(format!(
                "cmux-input-ack-surface-{}-{}.json",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let (client, host) = UnixStream::pair().unwrap();
            let reader = client.try_clone().unwrap();
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
                    osc_progress: String::new(),
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
                pty_custody: None,
            };
            (attachment, host)
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
                seed: b"seeded".to_vec(),
            };

            let decoded = HostLaunch::decode(&launch.encode().unwrap()).unwrap();
            assert_eq!(decoded.default_colors, default_colors);
            assert_eq!(decoded.cell_pixels, (9, 18));
            assert_eq!(decoded.kitty_graphics_limits, launch.kitty_graphics_limits);
            assert_eq!(decoded.command, launch.command);
            assert_eq!((decoded.extra_env, decoded.seed), (launch.extra_env, launch.seed));
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
                seed: Vec::new(),
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
                osc_progress: String::new(),
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
        fn snapshot_payload_round_trip_preserves_negotiated_terminal_metadata() {
            let snapshot = HostSnapshot {
                cols: 80,
                rows: 24,
                cell_pixels: (9, 18),
                replay: b"replay".to_vec(),
                kitty_image_aliases: Vec::new(),
                kitty_state: KittyReplayState::disabled(),
                sequence_boundary: 0,
                colors: TerminalColorOverrides::default(),
                pid: None,
                command: Vec::new(),
                cwd: None,
                osc_progress: "4;1;50".into(),
            };
            let payload = encode_snapshot_for_version(&snapshot, PROTOCOL_VERSION, true).unwrap();
            let decoded = decode_snapshot_for_version(&payload, PROTOCOL_VERSION, true).unwrap();
            assert_eq!(decoded.osc_progress, snapshot.osc_progress);
            assert!(
                decode_snapshot(&payload).is_err(),
                "a metadata tail must not be accepted without negotiation"
            );
        }

        #[test]
        fn host_snapshot_negotiates_terminal_metadata_at_the_stream_boundary() {
            let host = exited_host_fixture();
            assert!(host.terminal_metadata.lock().unwrap().set_osc_progress("4;1;50"));
            let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
            client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let server = thread::spawn({
                let host = host.clone();
                move || serve_client(host, server_stream)
            });

            let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
            hello.flags |= FLAG_TERMINAL_METADATA;
            write_frame(&mut client_stream, &hello).unwrap();
            let host_hello = read_required_frame(&mut client_stream, "host hello").unwrap();
            assert_eq!(host_hello.flags & FLAG_TERMINAL_METADATA, FLAG_TERMINAL_METADATA);
            let snapshot_frame = read_required_frame(&mut client_stream, "snapshot").unwrap();
            let snapshot =
                decode_snapshot_for_version(&snapshot_frame.payload, PROTOCOL_VERSION, true)
                    .unwrap();
            assert_eq!(snapshot.osc_progress, "4;1;50");
            assert_eq!(
                read_required_frame(&mut client_stream, "colors").unwrap().kind,
                MessageKind::Colors
            );
            drop(client_stream);
            assert!(server.join().unwrap().is_ok());
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
                osc_progress: String::new(),
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
                osc_progress: String::new(),
            };
            let snapshot_payload = encode_snapshot(&snapshot).unwrap();
            let v2_snapshot_len = snapshot_payload.len() - KITTY_REPLAY_STATE_ENCODED_LEN;
            let decoded =
                decode_snapshot_for_version(&snapshot_payload[..v2_snapshot_len], 2, false)
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
                false,
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
                    osc_progress: String::new(),
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
                pty_custody: None,
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
        fn receipted_input_never_reaches_a_legacy_host_without_ack_support() {
            let (record_path, mut record, lease) = record_fixture("input-ack-legacy");
            let root = record_path.parent().unwrap().to_path_buf();
            record.supports_input_ack = false;
            let (client, mut host) = UnixStream::pair().unwrap();
            host.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
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
                    osc_progress: String::new(),
                },
                protocol_version: PROTOCOL_VERSION,
                smart_renderer: true,
                reader: None,
                writer: Arc::new(Mutex::new(client)),
                control_responses: Arc::new(ControlResponses::new()),
                next_request: AtomicU64::new(2),
                viewer_size: Mutex::new(None),
                launch_process: None,
                launch_activation_pending: false,
                pty_custody: None,
            };

            let error = match attachment.begin_input_confirmed(b"must-not-send") {
                Ok(_) => panic!("legacy host accepted a receipted input request"),
                Err(ConfirmedInputFailure::Known(error)) => error,
                Err(ConfirmedInputFailure::Indeterminate(error)) => {
                    panic!("legacy-host rejection became indeterminate: {error}")
                }
            };
            assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
            let mut byte = [0u8; 1];
            let read_error = host.read(&mut byte).unwrap_err();
            assert!(matches!(
                read_error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ));

            drop(attachment);
            drop(lease);
            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn receipted_input_rejects_lower_negotiated_protocols_before_sending() {
            for version in 1..4 {
                let (mut attachment, mut host) = input_ack_surface_fixture();
                attachment.protocol_version = version;
                host.set_nonblocking(true).unwrap();
                let result = attachment.begin_input_confirmed(b"must-not-send");
                let Err(ConfirmedInputFailure::Known(error)) = result else {
                    panic!("protocol {version} must reject confirmed input before delivery");
                };
                assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);
                assert_eq!(attachment.control_responses.pending_input_acks_for_test(), (0, 0));
                let mut byte = [0];
                assert_eq!(
                    host.read(&mut byte).unwrap_err().kind(),
                    std::io::ErrorKind::WouldBlock
                );
            }
        }

        #[test]
        fn host_command_path_rejects_receipted_input_on_older_protocols() {
            assert!(!input_request_is_supported(PROTOCOL_VERSION - 1, 1));
            assert!(input_request_is_supported(PROTOCOL_VERSION - 1, 0));
            assert!(input_request_is_supported(PROTOCOL_VERSION, 1));
        }

        #[test]
        fn receipted_input_distinguishes_oversize_from_full_window() {
            let (attachment, mut host) = input_ack_surface_fixture();
            host.set_nonblocking(true).unwrap();
            let oversized = vec![0; MAX_PENDING_INPUT_ACK_BYTES + 1];
            let Err(ConfirmedInputFailure::Known(error)) =
                attachment.begin_input_confirmed(&oversized)
            else {
                panic!("oversized input must fail before delivery");
            };
            assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
            assert_eq!(attachment.control_responses.pending_input_acks_for_test(), (0, 0));
            assert!(
                attachment.control_responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES)
            );
            let result = attachment.begin_input_confirmed(b"x");
            attachment.control_responses.release_input_ack(MAX_PENDING_INPUT_ACK_BYTES);
            let Err(ConfirmedInputFailure::Known(error)) = result else {
                panic!("full receipt window must reject admission");
            };
            assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
            assert_eq!(attachment.control_responses.pending_input_acks_for_test(), (0, 0));
            let mut byte = [0];
            assert_eq!(host.read(&mut byte).unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
        }

        #[test]
        fn receipted_input_timeout_can_abort_while_writer_mutex_is_held() {
            let (attachment, mut host) = input_ack_surface_fixture();
            host.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
            let receipt = attachment.begin_input_confirmed(b"timeout").unwrap();
            let request = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
            assert_eq!(request.kind, MessageKind::Input);
            assert_ne!(request.request_id, 0);

            let writer_guard = attachment.writer.lock().unwrap();
            let (result_tx, result_rx) = sync_channel(1);
            let waiter = thread::spawn(move || {
                result_tx.send(receipt.wait_for(Duration::from_millis(20))).unwrap();
            });
            let error = result_rx
                .recv_timeout(Duration::from_millis(250))
                .expect("input ACK timeout blocked behind the socket writer mutex")
                .unwrap_err();
            assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
            assert!(
                read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().is_none(),
                "timeout shutdown did not reach the peer while the socket writer mutex was held"
            );
            drop(writer_guard);
            waiter.join().unwrap();
        }

        #[test]
        fn receipted_input_window_is_bounded() {
            let responses = ControlResponses::new();
            for _ in 0..MAX_PENDING_INPUT_ACKS {
                assert!(responses.try_reserve_input_ack(1));
            }
            assert!(!responses.try_reserve_input_ack(1));
            assert_eq!(
                responses.pending_input_acks_for_test(),
                (MAX_PENDING_INPUT_ACKS, MAX_PENDING_INPUT_ACKS)
            );
            responses.release_input_ack(1);
            assert!(responses.try_reserve_input_ack(1));
            for _ in 0..MAX_PENDING_INPUT_ACKS {
                responses.release_input_ack(1);
            }
            assert_eq!(responses.pending_input_acks_for_test(), (0, 0));

            assert!(responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES));
            assert!(!responses.try_reserve_input_ack(1));
            responses.release_input_ack(MAX_PENDING_INPUT_ACK_BYTES);
            assert_eq!(responses.pending_input_acks_for_test(), (0, 0));
            assert!(!responses.try_reserve_input_ack(MAX_PENDING_INPUT_ACK_BYTES + 1));
        }

        #[test]
        fn interactive_input_keeps_fire_and_forget_semantics() {
            let host = test_host_shared();
            let (pty_writer, mut pty_reader) = UnixStream::pair().unwrap();
            *host.writer.lock().unwrap() = Box::new(pty_writer);
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

            assert!(host.write_input(b"x", 0, &target));
            let mut byte = [0u8; 1];
            pty_reader.read_exact(&mut byte).unwrap();
            assert_eq!(&byte, b"x");
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
        }

        struct GatedInputWriter {
            write_started: SyncSender<()>,
            write_release: Receiver<()>,
            flush_started: SyncSender<()>,
            flush_release: Receiver<()>,
            fail_flush: bool,
        }

        impl Write for GatedInputWriter {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.write_started.send(()).unwrap();
                self.write_release.recv().unwrap();
                Ok(bytes.len())
            }

            fn flush(&mut self) -> std::io::Result<()> {
                self.flush_started.send(()).unwrap();
                self.flush_release.recv().unwrap();
                if self.fail_flush {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "synthetic flush failure",
                    ));
                }
                Ok(())
            }
        }

        #[test]
        fn host_input_receipt_follows_pty_write_and_flush() {
            let host = test_host_shared();
            let (write_started_tx, write_started_rx) = sync_channel(0);
            let (write_release_tx, write_release_rx) = sync_channel(0);
            let (flush_started_tx, flush_started_rx) = sync_channel(0);
            let (flush_release_tx, flush_release_rx) = sync_channel(0);
            *host.writer.lock().unwrap() = Box::new(GatedInputWriter {
                write_started: write_started_tx,
                write_release: write_release_rx,
                flush_started: flush_started_tx,
                flush_release: flush_release_rx,
                fail_flush: false,
            });
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            let worker = thread::spawn(move || {
                assert!(host.write_input(b"x", 42, &target));
            });

            write_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            write_release_tx.send(()).unwrap();
            flush_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            flush_release_tx.send(()).unwrap();

            let ack = target_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert_eq!(ack.kind, MessageKind::InputAck);
            assert_eq!(ack.request_id, 42);
            assert!(ack.payload.is_empty());
            worker.join().unwrap();
        }

        #[test]
        fn host_input_receipt_requires_successful_flush() {
            let host = test_host_shared();
            let (write_started_tx, write_started_rx) = sync_channel(0);
            let (write_release_tx, write_release_rx) = sync_channel(0);
            let (flush_started_tx, flush_started_rx) = sync_channel(0);
            let (flush_release_tx, flush_release_rx) = sync_channel(0);
            *host.writer.lock().unwrap() = Box::new(GatedInputWriter {
                write_started: write_started_tx,
                write_release: write_release_rx,
                flush_started: flush_started_tx,
                flush_release: flush_release_rx,
                fail_flush: true,
            });
            let (target_socket, _target_peer) = UnixStream::pair().unwrap();
            let (target_tx, target_rx) = mpsc_channel();
            let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);
            let worker = thread::spawn(move || host.write_input(b"x", 42, &target));

            write_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            write_release_tx.send(()).unwrap();
            flush_started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
            flush_release_tx.send(()).unwrap();

            assert!(!worker.join().unwrap());
            assert!(target_rx.recv_timeout(Duration::from_millis(20)).is_err());
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
                    osc_progress: String::new(),
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
                pty_custody: None,
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
                    osc_progress: String::new(),
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
                pty_custody: None,
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
        fn input_ack_capability_requires_version_4_record() {
            let (record_path, record, lease) = record_fixture("input-ack-version");
            validate_terminal_host_record(&record_path, &record).unwrap();
            for version in [2, 3] {
                let mut legacy = record.clone();
                legacy.record_version = version;
                legacy.supports_terminate_ack = version >= 3;
                legacy.supports_input_ack = false;
                legacy.supports_terminal_metadata = false;
                legacy.supports_viewer_size_priority = false;
                validate_terminal_host_record(&record_path, &legacy).unwrap();
                legacy.supports_input_ack = true;
                assert!(
                    validate_terminal_host_record(&record_path, &legacy).is_err(),
                    "version {version} must reject input acknowledgements"
                );
            }
            drop(lease);
            assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());
            fs::remove_dir_all(record_path.parent().unwrap()).unwrap();
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
            legacy.supports_input_ack = false;
            legacy.supports_terminal_metadata = false;
            legacy.supports_viewer_size_priority = false;
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

            let mut invalid = legacy.clone();
            invalid.supports_input_ack = true;
            assert!(validate_terminal_host_record(&legacy_path, &invalid).is_err());

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

            let viewers = Mutex::new(ViewerSizes::default());
            viewers.lock().unwrap().sizes.insert(1, (80, 24));
            let error = mutate_viewer_sizes(
                &viewers,
                |set| {
                    set.sizes.insert(2, (70, 20));
                },
                |_| anyhow::bail!("injected PTY resize failure"),
            )
            .unwrap_err();
            assert!(error.to_string().contains("injected PTY"));
            assert_eq!(viewers.lock().unwrap().sizes, HashMap::from([(1, (80, 24))]));
            assert!(viewers.lock().unwrap().preferred.is_empty());
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
                            OwnerIntent::Surface,
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
                    OwnerIntent::OneShot,
                )
                .is_err()
            );
            let hellos = server.join().unwrap();
            assert_eq!(
                hellos,
                vec![(
                    PROTOCOL_VERSION,
                    FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS | FLAG_TERMINAL_METADATA
                )]
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
                    osc_progress: String::new(),
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
                pty_custody: None,
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
                    osc_progress: String::new(),
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
                pty_custody: None,
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
                    pending_sequence: Vec::new(),
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
                    osc_progress: String::new(),
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
                pty_custody: None,
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
                    osc_progress: String::new(),
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
                OwnerIntent::Surface,
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
            let mut record = record;
            // This fixture models a current-protocol host from before the
            // optional metadata extension. It must not receive the new tail.
            record.supports_terminal_metadata = false;
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
                    osc_progress: String::new(),
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
                OwnerIntent::Surface,
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
            let viewer_sizes = Arc::new(Mutex::new(ViewerSizes::default()));
            let applied = Arc::new(Mutex::new(Vec::new()));
            let (first_applying_tx, first_applying_rx) = std::sync::mpsc::channel();
            let (release_first_tx, release_first_rx) = std::sync::mpsc::channel();

            let first = {
                let viewer_sizes = viewer_sizes.clone();
                let applied = applied.clone();
                thread::spawn(move || {
                    mutate_viewer_sizes(
                        &viewer_sizes,
                        |set| {
                            set.sizes.insert(1, (120, 40));
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
                        |set| {
                            second_mutating_tx.send(()).unwrap();
                            set.sizes.insert(2, (80, 24));
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
                    .sizes
                    .values()
                    .copied()
                    .reduce(|left, right| (left.0.min(right.0), left.1.min(right.1))),
                Some((80, 24))
            );
        }

        fn apply_viewer_mutation(
            viewers: &Mutex<ViewerSizes>,
            mutation: impl FnOnce(&mut ViewerSizes),
        ) -> Option<(u16, u16)> {
            let mut applied = None;
            mutate_viewer_sizes(viewers, mutation, |desired| {
                applied = desired;
                Ok(())
            })
            .unwrap();
            applied
        }

        #[test]
        fn viewer_size_priority_absent_keeps_the_per_dimension_minimum() {
            let viewers = Mutex::new(ViewerSizes::default());
            let desired = apply_viewer_mutation(&viewers, |set| {
                set.sizes.insert(1, (80, 24));
                set.sizes.insert(2, (120, 20));
            });
            assert_eq!(desired, Some((80, 20)));
        }

        #[test]
        fn viewer_size_priority_larger_preferred_viewer_wins_until_it_releases_or_leaves() {
            let viewers = Mutex::new(ViewerSizes::default());
            let desired = apply_viewer_mutation(&viewers, |set| {
                set.sizes.insert(1, (80, 24));
            });
            assert_eq!(desired, Some((80, 24)));

            let desired = apply_viewer_mutation(&viewers, |set| {
                set.sizes.insert(2, (120, 40));
                set.preferred.insert(2);
            });
            assert_eq!(desired, Some((120, 40)));

            // A smaller legacy report no longer reduces the grid.
            let desired = apply_viewer_mutation(&viewers, |set| {
                set.sizes.insert(1, (60, 20));
            });
            assert_eq!(desired, Some((120, 40)));

            let desired = apply_viewer_mutation(&viewers, |set| set.release(2));
            assert_eq!(desired, Some((60, 20)));

            // Priority belongs to the connection, so a later report regains it.
            let desired = apply_viewer_mutation(&viewers, |set| {
                set.sizes.insert(2, (100, 30));
            });
            assert_eq!(desired, Some((100, 30)));

            let desired = apply_viewer_mutation(&viewers, |set| set.remove_client(2));
            assert_eq!(desired, Some((60, 20)));
            let viewers = viewers.lock().unwrap();
            assert_eq!(viewers.sizes, HashMap::from([(1, (60, 20))]));
            assert!(viewers.preferred.is_empty());
        }

        #[test]
        fn viewer_size_priority_reduces_only_among_preferred_viewers() {
            let viewers = Mutex::new(ViewerSizes::default());
            let desired = apply_viewer_mutation(&viewers, |set| {
                set.sizes.insert(1, (40, 10));
                set.sizes.insert(2, (120, 40));
                set.sizes.insert(3, (100, 50));
                set.preferred.extend([2, 3]);
            });
            assert_eq!(desired, Some((100, 40)));

            let desired = apply_viewer_mutation(&viewers, |set| set.remove_client(2));
            assert_eq!(desired, Some((100, 50)));

            let desired = apply_viewer_mutation(&viewers, |set| set.release(3));
            assert_eq!(desired, Some((40, 10)));

            let desired = apply_viewer_mutation(&viewers, |set| set.remove_client(1));
            assert_eq!(desired, None);
        }

        #[test]
        fn viewer_size_priority_failed_apply_rolls_back_preferred_membership() {
            let viewers = Mutex::new(ViewerSizes::default());
            viewers.lock().unwrap().sizes.insert(1, (80, 24));
            let before = viewers.lock().unwrap().clone();
            let error = mutate_viewer_sizes(
                &viewers,
                |set| {
                    set.sizes.insert(2, (120, 40));
                    set.preferred.insert(2);
                },
                |desired| {
                    assert_eq!(desired, Some((120, 40)));
                    anyhow::bail!("injected PTY resize failure")
                },
            )
            .unwrap_err();
            assert!(error.to_string().contains("injected PTY"));
            assert_eq!(*viewers.lock().unwrap(), before);
        }

        #[test]
        fn viewer_size_priority_is_negotiated_only_for_resizing_renderers() {
            let preferred = FLAG_VIEWER_SIZE_ACKS | FLAG_VIEWER_SIZE_PRIORITY;
            let legacy = FLAG_VIEWER_SIZE_ACKS;
            let ttl = Duration::from_secs(1);
            for (role, rights, flags, reserved, negotiated) in [
                (ClientRole::Renderer, CapabilityRights::RENDERER, preferred, true, true),
                (ClientRole::Renderer, CapabilityRights::RENDERER, legacy, true, false),
                (ClientRole::Renderer, CapabilityRights::READ, preferred, false, false),
                (ClientRole::Admin, CapabilityRights::ADMIN, preferred, false, false),
            ] {
                let host = exited_host_fixture();
                let token = if role == ClientRole::Admin {
                    host.owner_token
                } else {
                    host.capabilities.mint(host.terminal_id, rights, ttl).unwrap()
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
                hello.flags = flags;
                let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
                client_stream.set_read_timeout(Some(ttl)).unwrap();
                let server_host = host.clone();
                let server = thread::spawn(move || {
                    serve_client_with_snapshot_timeout(server_host, server_stream, ttl)
                });

                write_frame(&mut client_stream, &hello).unwrap();
                let host_hello = read_required_frame(&mut client_stream, "host hello").unwrap();
                assert_eq!(host_hello.kind, MessageKind::HostHello);
                assert_eq!(
                    host_hello.flags & FLAG_VIEWER_SIZE_PRIORITY != 0,
                    negotiated,
                    "{role:?} {rights:?} flags {flags:#x}"
                );
                let snapshot = read_required_frame(&mut client_stream, "snapshot").unwrap();
                assert_eq!(snapshot.kind, MessageKind::Snapshot);
                let colors = read_required_frame(&mut client_stream, "colors").unwrap();
                assert_eq!(colors.kind, MessageKind::Colors);
                {
                    let viewers = host.viewer_sizes.lock().unwrap();
                    assert_eq!(viewers.sizes.get(&1).copied(), reserved.then_some((80, 24)));
                    assert_eq!(viewers.preferred.contains(&1), negotiated);
                }

                let _ = client_stream.shutdown(std::net::Shutdown::Both);
                server.join().unwrap().unwrap();
                assert_eq!(*host.viewer_sizes.lock().unwrap(), ViewerSizes::default());
            }
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
        fn private_socket_terminal_host_endpoint_dir_refuses_a_symlink() {
            let root = std::env::temp_dir().join(format!(
                "cmux-host-endpoint-dir-{}-{}",
                std::process::id(),
                RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let target = root.join("target");
            fs::create_dir_all(&target).unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
            let alias = root.join("alias");
            std::os::unix::fs::symlink(&target, &alias).unwrap();

            let refused = prepare_endpoint_dir(&alias);
            let target_mode = fs::metadata(&target).unwrap().permissions().mode() & 0o777;
            let owned = root.join("owned");
            let created = prepare_endpoint_dir(&owned);
            let owned_mode = fs::metadata(&owned).map(|metadata| metadata.mode() & 0o777);
            let _ = fs::remove_dir_all(&root);

            assert!(refused.is_err(), "a symlinked endpoint directory must be refused");
            assert_eq!(target_mode, 0o755, "the symlink target must stay untouched");
            created.unwrap();
            assert_eq!(owned_mode.unwrap(), 0o700);
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
            let owner_token =
                CapabilityToken::from_bytes([7; crate::terminal_host::CAPABILITY_TOKEN_LEN]);
            let marker = format!(
                "{}{}:/spawn",
                crate::platform::SNAPSHOT_SPAWN_CWD_PREFIX,
                encode_hex(owner_token.as_bytes())
            );
            assert_eq!(
                snapshot_cwd(&term, Some("/spawn"), &owner_token, PROTOCOL_VERSION),
                Some(marker.clone())
            );

            term.vt_write(b"\x1b]7;file:///live\x1b\\");
            assert_eq!(
                snapshot_cwd(&term, Some("/spawn"), &owner_token, PROTOCOL_VERSION),
                Some(marker.clone())
            );

            term.vt_write(b"\x1b]7;\x1b\\");
            assert_eq!(
                snapshot_cwd(&term, Some("/spawn"), &owner_token, PROTOCOL_VERSION),
                Some(marker)
            );
            assert_eq!(
                snapshot_cwd(&term, Some("file:///spawn"), &owner_token, PROTOCOL_VERSION),
                None
            );
        }

        #[test]
        fn snapshot_cwd_uses_legacy_path_for_old_and_unknown_protocols() {
            let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            let owner_token =
                CapabilityToken::from_bytes([7; crate::terminal_host::CAPABILITY_TOKEN_LEN]);
            for protocol_version in [LEGACY_PROTOCOL_VERSION, PROTOCOL_VERSION + 1] {
                let snapshot = snapshot_cwd(&term, Some("/spawn"), &owner_token, protocol_version);
                assert_eq!(snapshot, Some("/spawn".into()));
                assert_eq!(
                    crate::platform::snapshot_cwd_to_local_path(snapshot.as_deref().unwrap(), None),
                    Some(PathBuf::from("/spawn"))
                );
            }
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
#[cfg(unix)]
pub use shared::attachment::HostAttachment;
#[cfg(unix)]
pub(crate) use shared::attachment::launch::adopt_terminal_host_with_kitty_limits;
#[cfg(unix)]
pub use shared::attachment::launch::{
    adopt_terminal_host, launch_terminal_host, launch_terminal_host_with_identity,
};
#[cfg(unix)]
pub(crate) use shared::codec::{
    DecodedHostResize, decode_host_resize_payload_for_version, decode_resync_kitty_graphics_limits,
};
#[cfg(unix)]
pub use shared::codec::{decode_host_snapshot_payload, encode_host_snapshot_payload};
#[cfg(unix)]
pub(crate) use shared::records::load_terminal_host_records_for_reset;
#[cfg(unix)]
pub use shared::records::{
    acknowledge_terminal_host_exit_record, load_terminal_host_exit_records,
    load_terminal_host_records, remove_stale_terminal_host_record, terminal_host_exit_record,
    terminal_host_record_liveness, validate_terminal_host_exit_record,
    validate_terminal_host_record,
};
#[cfg(unix)]
pub(crate) use shared::records::{live_successor_record, record_owner_token};
#[cfg(unix)]
pub(crate) use sys::acquire_terminal_host_reset_lock;
#[cfg(all(unix, test))]
pub(crate) use sys::{
    acquire_terminal_host_publication_lock, prepare_terminal_host_publication_lock,
};
#[cfg(all(unix, test))]
pub(crate) use unix::input_ack_surface_fixture;
#[cfg(unix)]
pub use unix::unadoptable::*;
#[cfg(unix)]
pub(crate) use unix::{
    ClipboardReadSignal, ControlResponses, DeferredCellPixelResolution, StandbyTerminalHost,
    launch_terminal_host_from, launch_terminal_host_seeded, sweep_released_pty_locks,
};
#[cfg(unix)]
pub use unix::{
    PtyCustody, TerminalHostAdoption, isolate_terminal_host_process_fds,
    launch_terminal_host_adopting, request_terminal_host_pty_custody, serve_terminal_host_stdio,
    terminal_host_root,
};

#[cfg(not(unix))]
pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
    crate::platform::normalize_filesystem_path(state_root.join(format!("{session}.terminal-hosts")))
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
