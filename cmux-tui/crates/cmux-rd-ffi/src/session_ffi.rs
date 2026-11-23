//! C ABI of the per-stream viewer session (`CmuxRdSession` in
//! `include/cmux_rd_ffi.h`, rd change C6). Same rules as the receiver: no
//! I/O, no threads, panics caught, a panic poisons only that handle, and
//! pointers handed out stay valid until the next call on the same session.

use std::fs::File;
use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_core::reassembly::CompleteFrame;

use crate::receiver::{Carrier, Message};
use crate::record::Recorder;
use crate::session::{MAX_STREAMS, Session, SessionError};
use crate::{
    CMUX_RD_CARRIER_DATAGRAM, CMUX_RD_CARRIER_STREAM, CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC,
    CMUX_RD_OK, CmuxRdFrame, CmuxRdMessage, CmuxRdStats, bytes_in, copy_out, error_code,
};

/// The stream is not open, or opening it would pass the stream limit.
pub const CMUX_RD_ERR_STREAM: i32 = -7;
/// Most open streams per session (`CMUX_RD_SESSION_MAX_STREAMS`).
pub const CMUX_RD_SESSION_MAX_STREAMS: usize = MAX_STREAMS;

/// The opaque session handle (`CmuxRdSession`).
#[derive(Debug)]
pub struct CmuxRdSession {
    pub(crate) inner: Session,
    /// The recording of stream 0 (`cmux_rd_session_record_start`), if any.
    pub(crate) recorder: Option<Recorder<File>>,
    current_frame: Option<CompleteFrame>,
    current_message: Option<Message>,
    stashed_feedback: Option<Vec<u8>>,
    poisoned: bool,
}

fn session_code(error: &SessionError) -> i32 {
    match error {
        SessionError::Receiver(e) => error_code(e),
        SessionError::Stream(_) => CMUX_RD_ERR_STREAM,
    }
}

/// Runs `f` on a live session; maps NULL, a poisoned session and panics to codes.
///
/// # Safety
/// `ptr` is NULL or came from [`cmux_rd_session_new`] and has not been freed, so a
/// non-NULL `ptr` is aligned and points to a live session. Nothing else reads or
/// writes that session until this returns: `f` gets it as `&mut`.
pub(crate) unsafe fn with_session(
    ptr: *mut CmuxRdSession,
    f: impl FnOnce(&mut CmuxRdSession) -> i32,
) -> i32 {
    // SAFETY: NULL or live, aligned and unaliased, by this function's contract.
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

fn ready(h: &CmuxRdSession) -> i32 {
    i32::try_from(h.inner.ready_frames()).unwrap_or(i32::MAX)
}

fn unit(result: Result<(), SessionError>) -> i32 {
    match result {
        Ok(()) => CMUX_RD_OK,
        Err(e) => session_code(&e),
    }
}

/// Creates a session with stream 0 open; NULL for an unknown carrier.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_session_new(
    carrier: u32,
    deadline_us: u64,
    nack_after_us: u64,
) -> *mut CmuxRdSession {
    let carrier = match carrier {
        CMUX_RD_CARRIER_DATAGRAM => Carrier::Datagram,
        CMUX_RD_CARRIER_STREAM => Carrier::Stream,
        _ => return std::ptr::null_mut(),
    };
    catch_unwind(|| {
        Box::into_raw(Box::new(CmuxRdSession {
            inner: Session::new(carrier, deadline_us, nack_after_us),
            recorder: None,
            current_frame: None,
            current_message: None,
            stashed_feedback: None,
            poisoned: false,
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Frees a session; NULL is ignored.
///
/// # Safety
/// `session` is NULL or came from [`cmux_rd_session_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_free(session: *mut CmuxRdSession) {
    if session.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(session) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Accepts datagrams of `stream` from now on (idempotent);
/// `CMUX_RD_ERR_STREAM` past `CMUX_RD_SESSION_MAX_STREAMS` open streams.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_open_stream(
    session: *mut CmuxRdSession,
    stream: u16,
) -> i32 {
    let run = |h: &mut CmuxRdSession| unit(h.inner.open_stream(stream));
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Drops `stream` and its frames; `CMUX_RD_ERR_STREAM` when it is not open.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_close_stream(
    session: *mut CmuxRdSession,
    stream: u16,
) -> i32 {
    let run = |h: &mut CmuxRdSession| {
        h.current_frame = None;
        unit(h.inner.close_stream(stream))
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Adds one datagram (datagram carrier). Returns the frames ready in all
/// streams; `CMUX_RD_ERR_STREAM` for a video datagram of a stream that is not open.
///
/// # Safety
/// `session` is valid; `bytes` is readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_push_datagram(
    session: *mut CmuxRdSession,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(bytes, len) }) else { return CMUX_RD_ERR_NULL };
    let run = |h: &mut CmuxRdSession| match h.inner.push_datagram(bytes, now_us) {
        Ok(()) => ready(h),
        Err(e) => session_code(&e),
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Adds received stream bytes (stream carrier). Returns the frames ready.
///
/// # Safety
/// As [`cmux_rd_session_push_datagram`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_push_stream(
    session: *mut CmuxRdSession,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(bytes, len) }) else { return CMUX_RD_ERR_NULL };
    let run = |h: &mut CmuxRdSession| match h.inner.push_stream(bytes, now_us) {
        Ok(()) => ready(h),
        Err(e) => session_code(&e),
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Drops frames past their deadline. Returns the frames ready.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_tick(session: *mut CmuxRdSession, now_us: u64) -> i32 {
    let run = |h: &mut CmuxRdSession| {
        h.inner.tick(now_us);
        ready(h)
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Hands out the oldest ready frame of any stream: 1 when `out` and
/// `*out_stream` were filled, 0 when none is ready.
///
/// # Safety
/// `session` is valid; `out` and `out_stream` are writable. `out.data` is
/// valid until the next call on this session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_pop_frame(
    session: *mut CmuxRdSession,
    out: *mut CmuxRdFrame,
    out_stream: *mut u16,
) -> i32 {
    if out.is_null() || out_stream.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    let run = |h: &mut CmuxRdSession| {
        let Some((stream, frame)) = h.inner.pop_frame() else {
            h.current_frame = None;
            return 0;
        };
        let frame = h.current_frame.insert(frame);
        if stream == 0
            && let Some(recorder) = h.recorder.as_mut()
        {
            recorder.push(frame.body.t_capture_us, &frame.body.access_unit);
        }
        let value = CmuxRdFrame {
            t_capture_us: frame.body.t_capture_us,
            data: frame.body.access_unit.as_ptr(),
            len: frame.body.access_unit.len(),
            frame: frame.frame,
            ref_frame: frame.body.ref_frame,
            flags: frame.flags,
        };
        // SAFETY: checked non-NULL; writable by contract.
        unsafe {
            out.write(value);
            out_stream.write(stream);
        }
        1
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Hands out the oldest queued message (control JSON, or a datagram that is
/// not video such as an InputAck): 1 when `out` was filled, 0 when none.
///
/// # Safety
/// `session` is valid; `out` is writable. `out.data` is valid until the next call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_pop_message(
    session: *mut CmuxRdSession,
    out: *mut CmuxRdMessage,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    let run = |h: &mut CmuxRdSession| {
        h.current_message = h.inner.pop_message();
        let Some(message) = h.current_message.as_ref() else { return 0 };
        let value = CmuxRdMessage {
            data: message.bytes.as_ptr(),
            len: message.bytes.len(),
            kind: message.kind,
        };
        // SAFETY: checked non-NULL; writable by contract.
        unsafe { out.write(value) };
        1
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Records one decode time of `stream`.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_note_decode(
    session: *mut CmuxRdSession,
    stream: u16,
    decode_us: u32,
) -> i32 {
    let run = |h: &mut CmuxRdSession| unit(h.inner.note_decode(stream, decode_us));
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Asks the host for a keyframe on `stream` until one is released there.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_request_keyframe(
    session: *mut CmuxRdSession,
    stream: u16,
) -> i32 {
    let run = |h: &mut CmuxRdSession| unit(h.inner.request_keyframe(stream));
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Writes the next due feedback datagram of any stream: 1 when written, 0
/// when none is due, `CMUX_RD_ERR_BUFFER` (with `*out_len` = size needed) when
/// `cap` is too small; the datagram is kept for the next call. `*out_len` is
/// written on every path.
///
/// # Safety
/// `session` is valid; `out` is writable for `cap` bytes; `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_feedback(
    session: *mut CmuxRdSession,
    now_us: u64,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: checked non-NULL; writable by contract.
    unsafe { *out_len = 0 };
    let run = |h: &mut CmuxRdSession| {
        let Some(datagram) = h.stashed_feedback.take().or_else(|| h.inner.feedback(now_us)) else {
            return 0;
        };
        // SAFETY: guaranteed by the caller.
        match unsafe { copy_out(&datagram, out, cap, out_len) } {
            CMUX_RD_OK => 1,
            code => {
                h.stashed_feedback = Some(datagram);
                code
            }
        }
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// The time at which tick and feedback must run next (0 = now); `u64::MAX`
/// for NULL or an unusable session.
///
/// # Safety
/// `session` is NULL or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_next_deadline_us(session: *const CmuxRdSession) -> u64 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { session.as_ref() }) else { return u64::MAX };
    if handle.poisoned {
        return u64::MAX;
    }
    if handle.stashed_feedback.is_some() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| handle.inner.next_deadline_us())).unwrap_or(u64::MAX)
}

/// Fills the counters of `stream`.
///
/// # Safety
/// `session` is valid; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_stats(
    session: *const CmuxRdSession,
    stream: u16,
    out: *mut CmuxRdStats,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    let run = |h: &mut CmuxRdSession| match h.inner.stats(stream) {
        Ok(s) => {
            let value = CmuxRdStats {
                frames_released: s.frames_released,
                frames_lost: s.frames_lost,
                acked_frame: s.acked_frame,
                need_recovery: s.need_recovery,
            };
            // SAFETY: checked non-NULL; writable by contract.
            unsafe { out.write(value) };
            CMUX_RD_OK
        }
        Err(e) => session_code(&e),
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    // The C type is `*const`, but the pointer came from `_new` as `*mut`.
    unsafe { with_session(session.cast_mut(), run) }
}

/// Starts session clock probes (rd change C8). Call only when welcome lists
/// the `clock` cap. Pings leave through [`cmux_rd_session_feedback`]; pongs
/// are consumed, not queued as messages.
///
/// # Safety
/// `session` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_enable_clock(session: *mut CmuxRdSession) -> i32 {
    let run = |h: &mut CmuxRdSession| {
        h.inner.enable_clock();
        CMUX_RD_OK
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    unsafe { with_session(session, run) }
}

/// Writes the host clock's offset from this viewer's (host = viewer +
/// offset) and the best sample's RTT: 1 when an estimate exists, 0 before
/// the first answer (outs untouched).
///
/// # Safety
/// `session` is valid; `offset_us` and `rtt_us` are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_session_clock(
    session: *const CmuxRdSession,
    offset_us: *mut i64,
    rtt_us: *mut u32,
) -> i32 {
    if offset_us.is_null() || rtt_us.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    let run = |h: &mut CmuxRdSession| {
        let Some(estimate) = h.inner.clock() else { return 0 };
        // SAFETY: checked non-NULL; writable by contract.
        unsafe {
            offset_us.write(estimate.offset_us);
            rtt_us.write(estimate.rtt_us);
        }
        1
    };
    // SAFETY: `session` is NULL or valid by this function's contract, and the
    // header lets one thread at a time call a session, so no other access overlaps.
    // The C type is `*const`, but the pointer came from `_new` as `*mut`.
    unsafe { with_session(session.cast_mut(), run) }
}
