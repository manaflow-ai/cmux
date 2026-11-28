//! C ABI of the viewer's upstream media sender (`CmuxRdUpstream` in
//! `include/cmux_rd_ffi.h`, rd change C4b): microphone, camera and screen
//! share frames in, `UpMedia` datagrams out, the host's upstream feedback in
//! (congestion control, NACK resends, keyframe requests). Same rules as the
//! other handles: no I/O, no threads, panics caught, a panic poisons only
//! that handle.

use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_core::cc::{CcConfig, PathKind};
use cmux_rd_core::upstream::{UpstreamConfig, UpstreamError, UpstreamSender};
use cmux_rd_proto::{STREAM_DATAGRAM, encode_stream_frame};

use crate::receiver::Carrier;
use crate::session_ffi::CMUX_RD_ERR_STREAM;
use crate::{
    CMUX_RD_CARRIER_DATAGRAM, CMUX_RD_CARRIER_STREAM, CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL,
    CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in, copy_out,
};

pub const CMUX_RD_PATH_DIRECT_LAN: u32 = 0;
pub const CMUX_RD_PATH_DIRECT_WAN: u32 = 1;
pub const CMUX_RD_PATH_VIA_CLOUD_REGION: u32 = 2;
pub const CMUX_RD_PATH_DO_RELAY: u32 = 3;
/// Media kinds of an upstream sender; each needs its own consent.
pub const CMUX_RD_MEDIA_MIC: u32 = 1;
pub const CMUX_RD_MEDIA_CAMERA: u32 = 2;
pub const CMUX_RD_MEDIA_SCREEN: u32 = 3;
/// The sender has no consent for its media kind (`CMUX_RD_ERR_CONSENT`).
pub const CMUX_RD_ERR_CONSENT: i32 = -8;
/// Bytes of datagrams the caller has not taken before new frames are dropped
/// (`CMUX_RD_UPSTREAM_MAX_QUEUED`).
pub const CMUX_RD_UPSTREAM_MAX_QUEUED: usize = 4 << 20;
/// Smallest and largest `max_datagram` a sender accepts.
const MIN_DATAGRAM: u32 = 64;
const MAX_DATAGRAM: u32 = 9_000;

/// Counters for the status line (`CmuxRdUpstreamStats`).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct CmuxRdUpstreamStats {
    pub frames_sent: u64,
    pub frames_dropped: u64,
    pub acked_frame: u32,
    /// Smoothed loss in parts per million.
    pub loss_ppm: u32,
    pub keyframe_requested: bool,
    /// The app granted consent for this sender's media kind.
    pub consent: bool,
}

/// The opaque sender handle (`CmuxRdUpstream`).
#[derive(Debug)]
pub struct CmuxRdUpstream {
    inner: UpstreamSender,
    carrier: Carrier,
    /// The media kind (`CMUX_RD_MEDIA_*`), fixed at creation.
    kind: u32,
    /// Set only by the app (`cmux_rd_upstream_set_consent`) after an explicit
    /// user action in this session; it never outlives the handle.
    consent: bool,
    /// Datagrams to send, framed for the carrier.
    queue: VecDeque<Vec<u8>>,
    queued_bytes: usize,
    poisoned: bool,
}

impl CmuxRdUpstream {
    fn enqueue(&mut self, datagrams: Vec<Vec<u8>>) -> usize {
        let mut n = 0;
        for d in datagrams {
            let framed = match self.carrier {
                Carrier::Datagram => d,
                Carrier::Stream => {
                    let mut out = Vec::with_capacity(d.len() + 5);
                    // A datagram is far below the stream frame limit.
                    let _ = encode_stream_frame(STREAM_DATAGRAM, &d, &mut out);
                    out
                }
            };
            self.queued_bytes += framed.len();
            self.queue.push_back(framed);
            n += 1;
        }
        n
    }

    fn full(&self) -> bool {
        self.queued_bytes >= CMUX_RD_UPSTREAM_MAX_QUEUED
    }
}

/// Runs `f` on a live sender; maps NULL, a poisoned sender and panics to codes.
///
/// # Safety
/// `ptr` is NULL or a live pointer from [`cmux_rd_upstream_new`] that no other
/// call uses at the same time.
unsafe fn with_upstream(
    ptr: *mut CmuxRdUpstream,
    f: impl FnOnce(&mut CmuxRdUpstream) -> i32,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { ptr.as_mut() }) else { return CMUX_RD_ERR_NULL };
    if handle.poisoned {
        return CMUX_RD_ERR_PANIC;
    }
    match catch_unwind(AssertUnwindSafe(|| f(handle))) {
        Ok(code) => code,
        Err(_) => {
            // SAFETY: as above; the closure's borrow ended when it unwound.
            if let Some(handle) = unsafe { ptr.as_mut() } {
                handle.poisoned = true;
            }
            CMUX_RD_ERR_PANIC
        }
    }
}

fn count(n: usize) -> i32 {
    i32::try_from(n).unwrap_or(i32::MAX)
}

fn path_kind(path: u32) -> Option<PathKind> {
    Some(match path {
        CMUX_RD_PATH_DIRECT_LAN => PathKind::DirectLan,
        CMUX_RD_PATH_DIRECT_WAN => PathKind::DirectWan,
        CMUX_RD_PATH_VIA_CLOUD_REGION => PathKind::ViaCloudRegion,
        CMUX_RD_PATH_DO_RELAY => PathKind::DoRelay,
        _ => return None,
    })
}

/// Creates a sender of media `kind` (`CMUX_RD_MEDIA_*`) for upstream stream
/// `stream`, without consent; NULL for an unknown carrier, kind or path, a
/// `max_datagram` outside 64..=9000, or `min_bps > max_bps`. A bitrate of 0
/// takes the default.
#[allow(clippy::too_many_arguments)] // one flat C call is simpler for Swift than a config struct
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_upstream_new(
    carrier: u32,
    stream: u16,
    kind: u32,
    max_datagram: u32,
    path: u32,
    start_bps: u64,
    min_bps: u64,
    max_bps: u64,
    fec: bool,
) -> *mut CmuxRdUpstream {
    let carrier = match carrier {
        CMUX_RD_CARRIER_DATAGRAM => Carrier::Datagram,
        CMUX_RD_CARRIER_STREAM => Carrier::Stream,
        _ => return std::ptr::null_mut(),
    };
    if !matches!(kind, CMUX_RD_MEDIA_MIC | CMUX_RD_MEDIA_CAMERA | CMUX_RD_MEDIA_SCREEN) {
        return std::ptr::null_mut();
    }
    let Some(path) = path_kind(path) else { return std::ptr::null_mut() };
    if !(MIN_DATAGRAM..=MAX_DATAGRAM).contains(&max_datagram) {
        return std::ptr::null_mut();
    }
    let default = CcConfig::default();
    let pick = |value: u64, fallback: u64| if value == 0 { fallback } else { value };
    let cc = CcConfig {
        start_bps: pick(start_bps, default.start_bps),
        min_bps: pick(min_bps, default.min_bps),
        max_bps: pick(max_bps, default.max_bps),
        ..default
    };
    if cc.min_bps > cc.max_bps {
        return std::ptr::null_mut();
    }
    let config = UpstreamConfig { stream, max_datagram: max_datagram as usize, cc, path, fec };
    catch_unwind(|| {
        Box::into_raw(Box::new(CmuxRdUpstream {
            inner: UpstreamSender::new(config),
            carrier,
            kind,
            consent: false,
            queue: VecDeque::new(),
            queued_bytes: 0,
            poisoned: false,
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Frees a sender; NULL is ignored.
///
/// # Safety
/// `upstream` is NULL or came from [`cmux_rd_upstream_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_free(upstream: *mut CmuxRdUpstream) {
    if upstream.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(upstream) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Sends one encoded frame. Returns the number of datagrams queued, 0 when
/// the frame was dropped (over the pacing budget, dependent on a dropped
/// frame, or the queue holds [`CMUX_RD_UPSTREAM_MAX_QUEUED`] bytes),
/// [`CMUX_RD_ERR_CONSENT`] (nothing queued, nothing counted) without
/// consent, or `CMUX_RD_ERR_INVALID` for a frame too large to send.
///
/// # Safety
/// `upstream` is valid; `data` is readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_send_frame(
    upstream: *mut CmuxRdUpstream,
    data: *const u8,
    len: usize,
    t_capture_us: u64,
    independent: bool,
    now_us: u64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(data) = (unsafe { bytes_in(data, len) }) else { return CMUX_RD_ERR_NULL };
    // SAFETY: `upstream` is NULL or valid (this function's contract).
    unsafe {
        with_upstream(upstream, |h| {
            if !h.consent {
                return CMUX_RD_ERR_CONSENT;
            }
            if h.full() {
                h.inner.drop_frame();
                return 0;
            }
            match h.inner.send_frame(data, t_capture_us, independent, now_us) {
                Ok(Some(datagrams)) => count(h.enqueue(datagrams)),
                Ok(None) => 0,
                Err(_) => CMUX_RD_ERR_INVALID,
            }
        })
    }
}

/// Takes one datagram from the host (a session's `CMUX_RD_MESSAGE_DATAGRAM`
/// message). Returns the number of resent datagrams queued
/// ([`CMUX_RD_ERR_CONSENT`] and none without consent),
/// `CMUX_RD_ERR_STREAM` when it is not feedback for this sender's stream, or
/// `CMUX_RD_ERR_INVALID`.
///
/// # Safety
/// `upstream` is valid; `bytes` is readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_on_datagram(
    upstream: *mut CmuxRdUpstream,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(bytes, len) }) else { return CMUX_RD_ERR_NULL };
    // SAFETY: `upstream` is NULL or valid (this function's contract).
    unsafe {
        with_upstream(upstream, |h| match h.inner.on_datagram(bytes, now_us) {
            // Feedback still updates the controller; nothing goes out.
            Ok(_) if !h.consent => CMUX_RD_ERR_CONSENT,
            Ok(resends) if h.full() => {
                drop(resends);
                0
            }
            Ok(resends) => count(h.enqueue(resends)),
            Err(UpstreamError::NotMine) => CMUX_RD_ERR_STREAM,
            Err(UpstreamError::Invalid(_)) => CMUX_RD_ERR_INVALID,
        })
    }
}

/// Writes the oldest queued datagram (framed for the carrier): 1 when
/// written, 0 when none is queued, `CMUX_RD_ERR_BUFFER` (with `*out_len` =
/// size needed) when `cap` is too small; the datagram then stays queued.
///
/// # Safety
/// `upstream` is valid; `out` is writable for `cap` bytes; `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_pop_datagram(
    upstream: *mut CmuxRdUpstream,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: checked non-NULL; writable by contract.
    unsafe { *out_len = 0 };
    let pop = |h: &mut CmuxRdUpstream| {
        let Some(front) = h.queue.front() else { return 0 };
        // SAFETY: `out` and `out_len` are writable by this function's contract.
        match unsafe { copy_out(front, out, cap, out_len) } {
            CMUX_RD_OK => {
                if let Some(sent) = h.queue.pop_front() {
                    h.queued_bytes -= sent.len();
                }
                1
            }
            code => code,
        }
    };
    // SAFETY: `upstream` is NULL or valid (this function's contract).
    unsafe { with_upstream(upstream, pop) }
}

/// Grants or revokes consent for the sender's media kind. Only the app calls
/// it, after an explicit user action in this session; `kind` must be the
/// sender's own kind (`CMUX_RD_ERR_INVALID` otherwise). Revoking drops every
/// datagram not yet taken, so nothing captured before the revoke goes out.
///
/// # Safety
/// `upstream` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_set_consent(
    upstream: *mut CmuxRdUpstream,
    kind: u32,
    granted: bool,
) -> i32 {
    let apply = |h: &mut CmuxRdUpstream| {
        if kind != h.kind {
            return CMUX_RD_ERR_INVALID;
        }
        h.consent = granted;
        if !granted {
            h.queue.clear();
            h.queued_bytes = 0;
        }
        CMUX_RD_OK
    };
    // SAFETY: `upstream` is NULL or valid (this function's contract).
    unsafe { with_upstream(upstream, apply) }
}

/// The bitrate the encoder should aim for at `now_us`; 0 for NULL or an
/// unusable sender.
///
/// # Safety
/// `upstream` is NULL or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_target_bps(
    upstream: *const CmuxRdUpstream,
    now_us: u64,
) -> u64 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { upstream.as_ref() }) else { return 0 };
    if handle.poisoned {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| handle.inner.target_bps(now_us))).unwrap_or(0)
}

/// Reports a path change (`CMUX_RD_PATH_*`); `CMUX_RD_ERR_INVALID` for an unknown path.
///
/// # Safety
/// `upstream` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_set_path(
    upstream: *mut CmuxRdUpstream,
    path: u32,
) -> i32 {
    // SAFETY: `upstream` is NULL or valid (this function's contract).
    unsafe {
        with_upstream(upstream, |h| {
            let Some(kind) = path_kind(path) else { return CMUX_RD_ERR_INVALID };
            h.inner.set_path(kind);
            CMUX_RD_OK
        })
    }
}

/// Fills the status counters.
///
/// # Safety
/// `upstream` is valid; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_upstream_stats(
    upstream: *const CmuxRdUpstream,
    out: *mut CmuxRdUpstreamStats,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: the caller passes NULL or a live sender; a shared borrow
    // suffices (a panic here cannot poison through a const pointer).
    let Some(h) = (unsafe { upstream.as_ref() }) else { return CMUX_RD_ERR_NULL };
    if h.poisoned {
        return CMUX_RD_ERR_PANIC;
    }
    let Ok(s) = catch_unwind(AssertUnwindSafe(|| h.inner.stats())) else {
        return CMUX_RD_ERR_PANIC;
    };
    let value = CmuxRdUpstreamStats {
        frames_sent: s.frames_sent,
        frames_dropped: s.frames_dropped,
        acked_frame: s.acked_frame,
        loss_ppm: (s.loss.clamp(0.0, 1.0) * 1_000_000.0) as u32,
        keyframe_requested: s.keyframe_requested,
        consent: h.consent,
    };
    // SAFETY: checked non-NULL; writable by contract.
    unsafe { out.write(value) };
    CMUX_RD_OK
}
