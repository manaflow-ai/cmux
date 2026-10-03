//! C ABI of the cmux remote desktop viewer core (`include/cmux_rd_ffi.h`).
//!
//! The macOS client links this staticlib through the client xcframework
//! (`scripts/cmux-next/build-rd-ffi.sh`; plans/cmux-next/remote-desktop.md
//! section 3). The surface is small on purpose: received bytes in, access
//! units, messages and feedback datagrams out. No I/O, no threads, no async
//! runtime. Every entry point catches panics; a panic poisons the receiver
//! and every later call on it returns `CMUX_RD_ERR_PANIC`.

mod receiver;

use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_core::reassembly::CompleteFrame;
use cmux_rd_proto::{STREAM_CONTROL, STREAM_DATAGRAM, encode_stream_frame};

pub use receiver::{Carrier, Message, Receiver, ReceiverError, Stats};

/// Version of the C ABI (`CMUX_RD_FFI_ABI_VERSION`).
pub const ABI_VERSION: u32 = 1;

pub const CMUX_RD_OK: i32 = 0;
pub const CMUX_RD_ERR_NULL: i32 = -1;
pub const CMUX_RD_ERR_INVALID: i32 = -2;
pub const CMUX_RD_ERR_BUFFER: i32 = -3;
pub const CMUX_RD_ERR_CARRIER: i32 = -4;
pub const CMUX_RD_ERR_FAILED: i32 = -5;
pub const CMUX_RD_ERR_PANIC: i32 = -6;

pub const CMUX_RD_CARRIER_DATAGRAM: u32 = 0;
pub const CMUX_RD_CARRIER_STREAM: u32 = 1;

/// One complete access unit (`CmuxRdFrame`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxRdFrame {
    pub t_capture_us: u64,
    pub data: *const u8,
    pub len: usize,
    pub frame: u32,
    pub ref_frame: u32,
    pub flags: u8,
}

/// A control message or a non-video datagram (`CmuxRdMessage`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxRdMessage {
    pub data: *const u8,
    pub len: usize,
    pub kind: u8,
}

/// Status counters (`CmuxRdStats`).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct CmuxRdStats {
    pub frames_released: u64,
    pub frames_lost: u64,
    pub acked_frame: u32,
    pub need_recovery: bool,
}

/// The opaque receiver handle (`CmuxRdReceiver`).
#[derive(Debug)]
pub struct CmuxRdReceiver {
    inner: Receiver,
    /// The frame and message last handed out; their bytes back the pointers.
    current_frame: Option<CompleteFrame>,
    current_message: Option<Message>,
    /// A feedback datagram that did not fit the caller's buffer.
    stashed_feedback: Option<Vec<u8>>,
    poisoned: bool,
}

/// Runs `f` on a live receiver; maps NULL, a poisoned receiver and panics to codes.
fn with_receiver(ptr: *mut CmuxRdReceiver, f: impl FnOnce(&mut CmuxRdReceiver) -> i32) -> i32 {
    // SAFETY: the caller passes NULL or a pointer from cmux_rd_receiver_new that
    // it has not freed, and does not call into the same receiver concurrently.
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

/// Borrows `len` bytes at `ptr`; NULL is allowed only for zero bytes.
///
/// # Safety
/// `ptr` must be valid for reads of `len` bytes for the returned lifetime.
unsafe fn bytes_in<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Copies `bytes` into the caller's buffer, or reports the size needed.
///
/// # Safety
/// `out` must be valid for writes of `cap` bytes; `out_len` must be valid for a write.
unsafe fn copy_out(bytes: &[u8], out: *mut u8, cap: usize, out_len: *mut usize) -> i32 {
    if out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: checked non-NULL; guaranteed writable by the caller.
    unsafe { *out_len = bytes.len() };
    if bytes.len() > cap {
        return CMUX_RD_ERR_BUFFER;
    }
    if bytes.is_empty() {
        return CMUX_RD_OK;
    }
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: `out` holds at least `cap >= bytes.len()` writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    CMUX_RD_OK
}

fn ready_count(handle: &CmuxRdReceiver) -> i32 {
    i32::try_from(handle.inner.ready_frames()).unwrap_or(i32::MAX)
}

fn error_code(error: &ReceiverError) -> i32 {
    match error {
        ReceiverError::Invalid(_) => CMUX_RD_ERR_INVALID,
        ReceiverError::Carrier => CMUX_RD_ERR_CARRIER,
        ReceiverError::StreamFailed => CMUX_RD_ERR_FAILED,
    }
}

/// Returns [`ABI_VERSION`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// Creates a receiver; NULL for an unknown carrier. Free it with
/// [`cmux_rd_receiver_free`].
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_receiver_new(
    carrier: u32,
    deadline_us: u64,
    nack_after_us: u64,
) -> *mut CmuxRdReceiver {
    let carrier = match carrier {
        CMUX_RD_CARRIER_DATAGRAM => Carrier::Datagram,
        CMUX_RD_CARRIER_STREAM => Carrier::Stream,
        _ => return std::ptr::null_mut(),
    };
    catch_unwind(|| {
        Box::into_raw(Box::new(CmuxRdReceiver {
            inner: Receiver::new(carrier, deadline_us, nack_after_us),
            current_frame: None,
            current_message: None,
            stashed_feedback: None,
            poisoned: false,
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Frees a receiver; NULL is ignored.
///
/// # Safety
/// `receiver` is NULL or came from [`cmux_rd_receiver_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_free(receiver: *mut CmuxRdReceiver) {
    if receiver.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(receiver) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Adds one datagram (datagram carrier). Returns the number of ready frames.
///
/// # Safety
/// `receiver` is valid (see [`cmux_rd_receiver_free`]); `bytes` is readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_push_datagram(
    receiver: *mut CmuxRdReceiver,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(bytes, len) }) else { return CMUX_RD_ERR_NULL };
    with_receiver(receiver, |h| match h.inner.push_datagram(bytes, now_us) {
        Ok(()) => ready_count(h),
        Err(e) => error_code(&e),
    })
}

/// Adds received stream bytes (stream carrier). Returns the number of ready frames.
///
/// # Safety
/// As [`cmux_rd_receiver_push_datagram`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_push_stream(
    receiver: *mut CmuxRdReceiver,
    bytes: *const u8,
    len: usize,
    now_us: u64,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(bytes, len) }) else { return CMUX_RD_ERR_NULL };
    with_receiver(receiver, |h| match h.inner.push_stream(bytes, now_us) {
        Ok(()) => ready_count(h),
        Err(e) => error_code(&e),
    })
}

/// Drops frames past their deadline. Returns the number of ready frames.
///
/// # Safety
/// `receiver` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_tick(receiver: *mut CmuxRdReceiver, now_us: u64) -> i32 {
    with_receiver(receiver, |h| {
        h.inner.tick(now_us);
        ready_count(h)
    })
}

/// Hands out the oldest ready frame: 1 when `out` was filled, 0 when none is ready.
///
/// # Safety
/// `receiver` is valid; `out` is writable. `out.data` is valid until the next call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_pop_frame(
    receiver: *mut CmuxRdReceiver,
    out: *mut CmuxRdFrame,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    with_receiver(receiver, |h| {
        h.current_frame = h.inner.pop_frame();
        let Some(frame) = h.current_frame.as_ref() else { return 0 };
        let value = CmuxRdFrame {
            t_capture_us: frame.body.t_capture_us,
            data: frame.body.access_unit.as_ptr(),
            len: frame.body.access_unit.len(),
            frame: frame.frame,
            ref_frame: frame.body.ref_frame,
            flags: frame.flags,
        };
        // SAFETY: checked non-NULL; writable by contract.
        unsafe { out.write(value) };
        1
    })
}

/// Hands out the oldest queued message: 1 when `out` was filled, 0 when none is queued.
///
/// # Safety
/// `receiver` is valid; `out` is writable. `out.data` is valid until the next call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_pop_message(
    receiver: *mut CmuxRdReceiver,
    out: *mut CmuxRdMessage,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    with_receiver(receiver, |h| {
        h.current_message = h.inner.pop_message();
        let Some(message) = h.current_message.as_ref() else { return 0 };
        let value =
            CmuxRdMessage { data: message.bytes.as_ptr(), len: message.bytes.len(), kind: message.kind };
        // SAFETY: checked non-NULL; writable by contract.
        unsafe { out.write(value) };
        1
    })
}

/// Records one decode time.
///
/// # Safety
/// `receiver` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_note_decode(
    receiver: *mut CmuxRdReceiver,
    decode_us: u32,
) -> i32 {
    with_receiver(receiver, |h| {
        h.inner.note_decode(decode_us);
        CMUX_RD_OK
    })
}

/// Asks the host for a keyframe until one is released.
///
/// # Safety
/// `receiver` is valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_request_keyframe(receiver: *mut CmuxRdReceiver) -> i32 {
    with_receiver(receiver, |h| {
        h.inner.request_keyframe();
        CMUX_RD_OK
    })
}

/// Writes the next due feedback datagram: 1 when written, 0 when none is due,
/// `CMUX_RD_ERR_BUFFER` (with `*out_len` = size needed) when `cap` is too small;
/// the datagram is kept for the next call.
///
/// # Safety
/// `receiver` is valid; `out` is writable for `cap` bytes; `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_feedback(
    receiver: *mut CmuxRdReceiver,
    now_us: u64,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    with_receiver(receiver, |h| {
        let Some(datagram) = h.stashed_feedback.take().or_else(|| h.inner.feedback(now_us)) else {
            // SAFETY: checked non-NULL; writable by contract.
            unsafe { *out_len = 0 };
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
    })
}

/// The time at which tick and feedback must run next (0 = now); `u64::MAX`
/// for NULL or an unusable receiver.
///
/// # Safety
/// `receiver` is NULL or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_next_deadline_us(receiver: *const CmuxRdReceiver) -> u64 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { receiver.as_ref() }) else { return u64::MAX };
    if handle.poisoned {
        return u64::MAX;
    }
    if handle.stashed_feedback.is_some() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| handle.inner.next_deadline_us())).unwrap_or(u64::MAX)
}

/// Fills the status counters.
///
/// # Safety
/// `receiver` is valid; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_receiver_stats(
    receiver: *const CmuxRdReceiver,
    out: *mut CmuxRdStats,
) -> i32 {
    if out.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    with_receiver(receiver.cast_mut(), |h| {
        let s = h.inner.stats();
        let value = CmuxRdStats {
            frames_released: s.frames_released,
            frames_lost: s.frames_lost,
            acked_frame: s.acked_frame,
            need_recovery: s.need_recovery,
        };
        // SAFETY: checked non-NULL; writable by contract.
        unsafe { out.write(value) };
        CMUX_RD_OK
    })
}

/// Frames a payload for the stream carrier.
///
/// # Safety
/// `payload` is readable for `len` bytes; `out` is writable for `cap` bytes;
/// `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_encode_stream_frame(
    kind: u32,
    payload: *const u8,
    len: usize,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(payload) = (unsafe { bytes_in(payload, len) }) else { return CMUX_RD_ERR_NULL };
    let Ok(kind) = u8::try_from(kind) else { return CMUX_RD_ERR_INVALID };
    if !matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM) {
        return CMUX_RD_ERR_INVALID;
    }
    catch_unwind(|| {
        let mut framed = Vec::new();
        if encode_stream_frame(kind, payload, &mut framed).is_err() {
            return CMUX_RD_ERR_INVALID;
        }
        // SAFETY: guaranteed by the caller.
        unsafe { copy_out(&framed, out, cap, out_len) }
    })
    .unwrap_or(CMUX_RD_ERR_PANIC)
}

#[cfg(test)]
mod tests;
