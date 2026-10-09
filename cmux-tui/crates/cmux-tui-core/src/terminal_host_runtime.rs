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
    #[cfg(test)]
    use std::collections::HashMap;
    use std::fs::{self, File, OpenOptions};
    use std::io as std_io;
    #[cfg(test)]
    use std::io::Read;
    use std::io::Write;
    use std::os::fd::{AsRawFd, RawFd};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    #[cfg(test)]
    use std::os::unix::net::UnixListener;
    use std::os::unix::net::UnixStream;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::sync::Arc;
    use std::sync::atomic::Ordering;
    #[cfg(test)]
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
    #[cfg(test)]
    use std::sync::mpsc::{channel as mpsc_channel, sync_channel};
    #[cfg(test)]
    use std::sync::{Condvar, Mutex};
    use std::thread;
    use std::time::Duration;
    #[cfg(test)]
    use std::time::Instant;

    use anyhow::Context;
    #[cfg(test)]
    use cmux_pty::MasterPty;
    use cmux_pty::{ChildKiller, PtyCommand};
    #[cfg(test)]
    use ghostty_vt::Terminal;

    use super::shared::codec::*;
    use super::shared::host_shared::HostShared;
    use super::shared::host_state::*;
    use super::shared::records::*;
    #[cfg(test)]
    use super::sys::{AcceptWaker, wait_for_pty_readable_or_forced_drain};
    use super::sys::{
        connect_with_retry, prepare_endpoint_dir, prepare_private_dir,
        reserve_terminal_host_publication,
    };
    use super::*;

    /// Own a PTY child until the host's reaper thread has taken responsibility
    /// for it.  Every fallible setup step after `pty.spawn` keeps this guard
    /// alive, so a failed reader, writer, callback, or thread setup cannot
    /// leave the interactive child detached from its parent.
    pub(crate) struct SpawnedPtyChild {
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

    pub(crate) mod adopt_launch;
    mod adopted_child;
    mod host_scope;
    mod host_session;
    pub(crate) mod host_signals;
    mod host_start;
    mod pty_custody;
    mod pty_lock;
    pub(crate) mod session_cleanup;
    mod standby;
    use super::shared::attachment::*;
    pub(crate) use super::shared::clipboard_read::ClipboardReadSignal;
    use super::shared::clipboard_read::OwnerIntent;
    #[cfg(test)]
    use super::shared::clipboard_read::{ClipboardReads, SystemClock};
    pub(crate) use super::shared::control_responses::{
        ControlResponses, DeferredCellPixelResolution,
    };
    #[cfg(test)]
    use super::shared::host_parser::{ParserSignals, run_guarded_host_parser, run_host_parser};
    use super::shared::host_start::start_host_runtime;
    pub use adopt_launch::{TerminalHostAdoption, launch_terminal_host_adopting};
    pub use host_session::enter_terminal_host_process;
    pub(crate) use host_session::{OWNER_FLAG, host_owner_args, host_session_env};
    pub(crate) use host_start::HostChild;
    pub(crate) use pty_custody::serve as serve_pty_custody;
    pub use pty_custody::{PtyCustody, request_terminal_host_pty_custody};
    pub(crate) use pty_lock::{remove_released, sweep_released_pty_locks};
    pub(crate) use standby::StandbyTerminalHost;

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
        start_host_runtime(launch, bootstrapped, master, child, &launch.seed)
    }

    #[cfg(test)]
    pub(crate) use tests::input_ack_surface_fixture;

    #[cfg(test)]
    mod tests;
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
pub(crate) use shared::attachment::launch::{
    launch_terminal_host_from, launch_terminal_host_seeded,
};
#[cfg(unix)]
pub(crate) use shared::codec::{
    DecodedHostResize, decode_host_resize_payload_for_version, decode_resync_kitty_graphics_limits,
};
#[cfg(unix)]
pub use shared::codec::{decode_host_snapshot_payload, encode_host_snapshot_payload};
#[cfg(unix)]
pub use shared::host_serve::serve_terminal_host_stdio;
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
pub(crate) use shared::records::{
    live_successor_record, record_owner_token, wait_for_terminal_host_record_removals,
};
#[cfg(unix)]
pub use shared::unadoptable::*;
#[cfg(unix)]
pub(crate) use sys::acquire_terminal_host_reset_lock;
#[cfg(all(unix, test))]
pub(crate) use sys::{
    acquire_terminal_host_publication_lock, prepare_terminal_host_publication_lock,
};
#[cfg(all(unix, test))]
pub(crate) use unix::input_ack_surface_fixture;
#[cfg(unix)]
pub(crate) use unix::{
    ClipboardReadSignal, ControlResponses, DeferredCellPixelResolution, StandbyTerminalHost,
    sweep_released_pty_locks,
};
#[cfg(unix)]
pub use unix::{
    PtyCustody, TerminalHostAdoption, enter_terminal_host_process,
    isolate_terminal_host_process_fds, launch_terminal_host_adopting,
    request_terminal_host_pty_custody, terminal_host_root,
};

// The Windows system layer of per-terminal hosts (cx-ko2e).
#[cfg(windows)]
pub mod windows;

#[cfg(not(unix))]
pub fn terminal_host_root(state_root: &Path, session: &str) -> PathBuf {
    crate::platform::normalize_filesystem_path(state_root.join(format!("{session}.terminal-hosts")))
}

#[cfg(not(unix))]
pub fn isolate_terminal_host_process_fds() -> anyhow::Result<()> {
    Ok(())
}

#[cfg(not(unix))]
pub fn enter_terminal_host_process() -> anyhow::Result<()> {
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
