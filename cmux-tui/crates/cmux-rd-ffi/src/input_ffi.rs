//! C ABI of the viewer's input channel (`CmuxRdInput` in
//! `include/cmux_rd_ffi.h`). Same rules as the receiver: no I/O, no threads,
//! panics caught, a panic poisons only that handle.

use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_proto::{InputEvent, MAX_DATAGRAM_VPC, MAX_TEXT_BYTES, STREAM_PREFIX_LEN};

use crate::input::InputChannel;
use crate::receiver::Carrier;
use crate::{
    CMUX_RD_CARRIER_DATAGRAM, CMUX_RD_CARRIER_STREAM, CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL,
    CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in, copy_out, error_code,
};

pub const CMUX_RD_INPUT_KEY: u32 = 1;
pub const CMUX_RD_INPUT_POINTER: u32 = 2;
pub const CMUX_RD_INPUT_BUTTON: u32 = 3;
pub const CMUX_RD_INPUT_SCROLL: u32 = 4;
pub const CMUX_RD_INPUT_TEXT: u32 = 5;
/// A service-defined event (rd change C2): `text`/`text_len` carry its bytes.
pub const CMUX_RD_INPUT_SERVICE: u32 = 0x80;
/// `service_flags` bit: repeat until acknowledged.
pub const CMUX_RD_INPUT_MUST_DELIVER: u8 = 0x01;
/// Largest payload of one service event (`CMUX_RD_INPUT_MAX_SERVICE`).
pub const CMUX_RD_INPUT_MAX_SERVICE: usize = cmux_rd_proto::MAX_SERVICE_BYTES;
/// Largest UTF-8 text of one text event (`CMUX_RD_INPUT_MAX_TEXT`).
pub const CMUX_RD_INPUT_MAX_TEXT: usize = MAX_TEXT_BYTES;
/// A buffer of this size holds every input packet on either carrier
/// (`CMUX_RD_INPUT_PACKET_MAX`).
pub const CMUX_RD_INPUT_PACKET_MAX: usize = MAX_DATAGRAM_VPC + STREAM_PREFIX_LEN;

/// One viewer input event (`CmuxRdInputEvent`). Fields a kind does not use are ignored.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxRdInputEvent {
    /// `CMUX_RD_INPUT_*`.
    pub kind: u32,
    /// Key: USB HID usage, `page << 16 | id`.
    pub usage: u32,
    /// Pointer: absolute position in stream pixels.
    pub x: i32,
    pub y: i32,
    /// Scroll: hundredths of a line, or of a point when `precise`.
    pub dx: i32,
    pub dy: i32,
    /// Text: UTF-8, 1 to `CMUX_RD_INPUT_MAX_TEXT` bytes (split longer text on
    /// character boundaries into several events).
    pub text: *const u8,
    pub text_len: usize,
    /// Button: 1 left, 2 middle, 3 right, 8 back, 9 forward.
    pub button: u8,
    /// Key and button: 1 pressed, 0 released (any other value is refused).
    pub down: u8,
    /// Scroll: 1 pixel-precise deltas (trackpad), 0 lines (any other value is refused).
    pub precise: u8,
    /// Service: `CMUX_RD_INPUT_MUST_DELIVER` or 0 (other bits are refused).
    pub service_flags: u8,
}

/// The opaque input handle (`CmuxRdInput`).
#[derive(Debug)]
pub struct CmuxRdInput {
    inner: InputChannel,
    /// A packet that did not fit the caller's buffer.
    stashed: Option<Vec<u8>>,
    poisoned: bool,
}

fn with_input(ptr: *mut CmuxRdInput, f: impl FnOnce(&mut CmuxRdInput) -> i32) -> i32 {
    // SAFETY: the caller passes NULL or a live pointer from cmux_rd_input_new
    // and does not call into the same handle concurrently.
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

/// A C flag byte: 0 or 1, anything else refused.
fn flag(byte: u8) -> Option<bool> {
    match byte {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

/// Converts a C event; `None` for an unknown kind, a flag byte other than 0
/// or 1, or bad text.
///
/// # Safety
/// For a text event, `event.text` is readable for `event.text_len` bytes.
unsafe fn event_from_c(event: &CmuxRdInputEvent) -> Option<InputEvent> {
    Some(match event.kind {
        CMUX_RD_INPUT_KEY => InputEvent::Key { usage: event.usage, down: flag(event.down)? },
        CMUX_RD_INPUT_POINTER => InputEvent::Pointer { x: event.x, y: event.y },
        CMUX_RD_INPUT_BUTTON => {
            InputEvent::Button { button: event.button, down: flag(event.down)? }
        }
        CMUX_RD_INPUT_SCROLL => {
            InputEvent::Scroll { dx: event.dx, dy: event.dy, precise: flag(event.precise)? }
        }
        CMUX_RD_INPUT_TEXT => {
            if event.text_len == 0 || event.text_len > CMUX_RD_INPUT_MAX_TEXT {
                return None;
            }
            // SAFETY: guaranteed by the caller.
            let bytes = unsafe { bytes_in(event.text, event.text_len) }?;
            InputEvent::Text(std::str::from_utf8(bytes).ok()?.to_owned())
        }
        CMUX_RD_INPUT_SERVICE => {
            // SAFETY: guaranteed by the caller (text is readable for text_len bytes).
            let bytes = unsafe { bytes_in(event.text, event.text_len) }?;
            InputEvent::Service {
                must_deliver: event.service_flags & CMUX_RD_INPUT_MUST_DELIVER != 0,
                bytes: bytes.to_vec(),
            }
        }
        _ => return None,
    })
}

/// Creates an input channel; NULL for an unknown carrier. `resend_us`: how
/// long unacknowledged events wait before they go out again (about one RTT).
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_input_new(carrier: u32, resend_us: u64) -> *mut CmuxRdInput {
    let carrier = match carrier {
        CMUX_RD_CARRIER_DATAGRAM => Carrier::Datagram,
        CMUX_RD_CARRIER_STREAM => Carrier::Stream,
        _ => return std::ptr::null_mut(),
    };
    catch_unwind(|| {
        Box::into_raw(Box::new(CmuxRdInput {
            inner: InputChannel::new(carrier, resend_us),
            stashed: None,
            poisoned: false,
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Frees an input channel; NULL is ignored.
///
/// # Safety
/// `input` is NULL or came from [`cmux_rd_input_new`] and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_input_free(input: *mut CmuxRdInput) {
    if input.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(input) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// Queues one event; writes its sequence number to `*out_seq` when not NULL.
/// `CMUX_RD_ERR_INVALID` for an unknown kind or text that is empty, too long
/// or not UTF-8 (nothing is queued then).
///
/// # Safety
/// `input` is valid; `event` is readable (and its text, for a text event);
/// `out_seq` is NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_input_push(
    input: *mut CmuxRdInput,
    event: *const CmuxRdInputEvent,
    out_seq: *mut u32,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(event) = (unsafe { event.as_ref() }) else { return CMUX_RD_ERR_NULL };
    with_input(input, |h| {
        // SAFETY: guaranteed by the caller.
        let Some(event) = (unsafe { event_from_c(event) }) else { return CMUX_RD_ERR_INVALID };
        let seq = h.inner.push(event);
        if !out_seq.is_null() {
            // SAFETY: checked non-NULL; writable by contract.
            unsafe { *out_seq = seq };
        }
        CMUX_RD_OK
    })
}

/// Applies an `InputAck` datagram (header included, as
/// `cmux_rd_receiver_pop_message` hands it out with kind
/// `CMUX_RD_MESSAGE_DATAGRAM`). `CMUX_RD_ERR_INVALID` for any other datagram
/// and no state change, so a caller may offer every datagram message here
/// and ignore that code.
///
/// # Safety
/// `input` is valid; `datagram` is readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_input_ack(
    input: *mut CmuxRdInput,
    datagram: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(datagram) = (unsafe { bytes_in(datagram, len) }) else { return CMUX_RD_ERR_NULL };
    with_input(input, |h| match h.inner.on_ack(datagram) {
        Ok(()) => CMUX_RD_OK,
        Err(e) => error_code(&e),
    })
}

/// Writes the next due `Input` datagram (stream-framed on the stream carrier):
/// 1 when written, 0 when none is due, `CMUX_RD_ERR_BUFFER` (with `*out_len` =
/// size needed) when `cap` is too small; the packet is kept for the next call.
/// Call again until it returns 0. `CMUX_RD_INPUT_PACKET_MAX` bytes always suffice.
///
/// # Safety
/// `input` is valid; `out` is writable for `cap` bytes; `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_input_packet(
    input: *mut CmuxRdInput,
    now_us: u64,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: checked non-NULL; writable by contract. Every path, including a
    // NULL or unusable handle, leaves a defined length.
    unsafe { *out_len = 0 };
    with_input(input, |h| {
        let Some(packet) = h.stashed.take().or_else(|| h.inner.packet(now_us)) else {
            // SAFETY: checked non-NULL; writable by contract.
            unsafe { *out_len = 0 };
            return 0;
        };
        // SAFETY: guaranteed by the caller.
        match unsafe { copy_out(&packet, out, cap, out_len) } {
            CMUX_RD_OK => 1,
            code => {
                h.stashed = Some(packet);
                code
            }
        }
    })
}

/// When `cmux_rd_input_packet` must run next (0 = now); `UINT64_MAX` when
/// nothing is queued, for NULL, or for an unusable handle.
///
/// # Safety
/// `input` is NULL or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_input_next_deadline_us(input: *const CmuxRdInput) -> u64 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { input.as_ref() }) else { return u64::MAX };
    if handle.poisoned {
        return u64::MAX;
    }
    if handle.stashed.is_some() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| handle.inner.next_deadline_us()))
        .ok()
        .flatten()
        .unwrap_or(u64::MAX)
}
