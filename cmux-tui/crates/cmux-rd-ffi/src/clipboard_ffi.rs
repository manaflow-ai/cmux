//! C ABI of the viewer's clipboard text sync (`CmuxRdClipboard` in
//! `include/cmux_rd_ffi.h`, cap `clipboard.text`): the same cmux-rd-proto
//! `ClipboardSync` the host runs, so a long text goes in paced parts that fit
//! one control record, a text over `CMUX_RD_CLIPBOARD_MAX_TEXT` is refused and
//! counted (never truncated), and the host's text is not sent back. Same rules
//! as the other handles: no I/O, no threads, panics caught, a panic poisons
//! only that handle.

use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_proto::clipboard::{ClipboardSync, MAX_CLIPBOARD_TEXT, MAX_PART_ENCODED, Offer};
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{STREAM_CONTROL, STREAM_PREFIX_LEN, encode_stream_frame};

use crate::{
    CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in, copy_out,
};

/// The text is over `CMUX_RD_CLIPBOARD_MAX_TEXT` (`CMUX_RD_ERR_TOO_LARGE`).
pub const CMUX_RD_ERR_TOO_LARGE: i32 = -10;
/// The largest clipboard text, UTF-8 bytes (`CMUX_RD_CLIPBOARD_MAX_TEXT`).
pub const CMUX_RD_CLIPBOARD_MAX_TEXT: usize = MAX_CLIPBOARD_TEXT;
/// A buffer this large always holds one framed part (`CMUX_RD_CLIPBOARD_FRAME_MAX`): the
/// stream prefix, the escaped text and the message's other fields.
pub const CMUX_RD_CLIPBOARD_FRAME_MAX: usize = STREAM_PREFIX_LEN + MAX_PART_ENCODED + 256;

/// The opaque clipboard handle (`CmuxRdClipboard`).
#[derive(Default)]
pub struct CmuxRdClipboard {
    inner: ClipboardSync,
    /// A framed part taken from the sync that the caller has not taken yet.
    pending: Option<Vec<u8>>,
    /// The last text the host completed; its bytes back `*text` until the next call.
    received: Vec<u8>,
    poisoned: bool,
}

/// Runs `f` on a live handle; maps NULL, a poisoned handle and panics to codes.
///
/// # Safety
/// `ptr` is NULL or a live pointer from [`cmux_rd_clipboard_new`] that no other
/// call uses at the same time.
unsafe fn with(ptr: *mut CmuxRdClipboard, f: impl FnOnce(&mut CmuxRdClipboard) -> i32) -> i32 {
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

/// Creates a clipboard handle for one session; NULL only when allocation fails.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_clipboard_new() -> *mut CmuxRdClipboard {
    catch_unwind(|| Box::into_raw(Box::<CmuxRdClipboard>::default()))
        .unwrap_or(std::ptr::null_mut())
}

/// Frees a clipboard handle (NULL is ignored).
///
/// # Safety
/// `clipboard` is NULL or a pointer from [`cmux_rd_clipboard_new`] not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_clipboard_free(clipboard: *mut CmuxRdClipboard) {
    if clipboard.is_null() {
        return;
    }
    // SAFETY: guaranteed by the caller; the box is dropped exactly once.
    let owned = unsafe { Box::from_raw(clipboard) };
    let _ = catch_unwind(AssertUnwindSafe(move || drop(owned)));
}

/// The viewer's clipboard now holds `text` (UTF-8): 1 when it was queued for the host,
/// 0 when the host already has it (the host's own text, set here a moment ago),
/// `CMUX_RD_ERR_TOO_LARGE` over the bound (counted, nothing sent),
/// `CMUX_RD_ERR_INVALID` for bytes that are not UTF-8.
///
/// # Safety
/// `clipboard` is NULL or live; `text` is valid for `len` bytes (or `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_clipboard_offer(
    clipboard: *mut CmuxRdClipboard,
    text: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(text, len) }) else { return CMUX_RD_ERR_NULL };
    let offer = |c: &mut CmuxRdClipboard| {
        if bytes.len() > MAX_CLIPBOARD_TEXT {
            // Refused before a UTF-8 check of a text that cannot go anyway.
            c.inner.note_local_too_large();
            return CMUX_RD_ERR_TOO_LARGE;
        }
        let Ok(text) = std::str::from_utf8(bytes) else { return CMUX_RD_ERR_INVALID };
        match c.inner.offer(text) {
            Offer::Queued(_) => {
                // A newer text replaces the unsent part of an older one.
                c.pending = None;
                1
            }
            Offer::Unchanged => 0,
            Offer::TooLarge => CMUX_RD_ERR_TOO_LARGE,
        }
    };
    // SAFETY: `clipboard` is NULL or live (this function's contract).
    unsafe { with(clipboard, offer) }
}

/// Writes the next part as a framed control message (stream frame type 1; send it as
/// is): 1 when written, 0 when none may go now, `CMUX_RD_ERR_BUFFER` (`*out_len` = size
/// needed) when `cap` is too small; the part then stays pending. A buffer of
/// `CMUX_RD_CLIPBOARD_FRAME_MAX` always fits. `*out_len` is written on every path.
///
/// # Safety
/// `clipboard` is NULL or live; `out` is writable for `cap` bytes; `out_len` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_clipboard_pop_frame(
    clipboard: *mut CmuxRdClipboard,
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
    let pop = |c: &mut CmuxRdClipboard| {
        if c.pending.is_none() {
            let Some(part) = c.inner.next_part(now_us) else { return 0 };
            let Ok(json) = serde_json::to_vec(&Control::from(part)) else {
                return CMUX_RD_ERR_INVALID;
            };
            let mut frame = Vec::with_capacity(STREAM_PREFIX_LEN + json.len());
            if encode_stream_frame(STREAM_CONTROL, &json, &mut frame).is_err() {
                return CMUX_RD_ERR_INVALID;
            }
            c.pending = Some(frame);
        }
        let Some(frame) = c.pending.as_ref() else { return 0 };
        // SAFETY: `out` and `out_len` by this function's contract.
        let code = unsafe { copy_out(frame, out, cap, out_len) };
        if code != CMUX_RD_OK {
            return code;
        }
        c.pending = None;
        1
    };
    // SAFETY: `clipboard` is NULL or live (this function's contract).
    unsafe { with(clipboard, pop) }
}

/// When pop_frame can give a part next (0 when one is pending); `UINT64_MAX` when
/// nothing waits, for NULL or an unusable handle.
///
/// # Safety
/// `clipboard` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_clipboard_next_deadline_us(
    clipboard: *const CmuxRdClipboard,
) -> u64 {
    // SAFETY: NULL or live by contract; read only.
    let Some(c) = (unsafe { clipboard.as_ref() }) else { return u64::MAX };
    if c.poisoned {
        return u64::MAX;
    }
    if c.pending.is_some() {
        return 0;
    }
    c.inner.next_deadline_us().unwrap_or(u64::MAX)
}

/// Offers one control message (a `CMUX_RD_MESSAGE_CONTROL` payload). 1 when it was the
/// host's `clipboard` and completed a text: `*text` and `*text_len` then hold it (UTF-8,
/// valid until the next call on this handle; set the viewer's clipboard to it). 0 for a
/// part of a longer text or any other message. `CMUX_RD_ERR_TOO_LARGE` for a text over
/// the bound and `CMUX_RD_ERR_INVALID` for a malformed or out-of-order part (dropped and
/// counted; the session goes on).
///
/// # Safety
/// `clipboard` is NULL or live; `json` is valid for `len` bytes; `text` and `text_len`
/// are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_clipboard_on_control(
    clipboard: *mut CmuxRdClipboard,
    json: *const u8,
    len: usize,
    text: *mut *const u8,
    text_len: *mut usize,
) -> i32 {
    if text.is_null() || text_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(json, len) }) else { return CMUX_RD_ERR_NULL };
    let apply = |c: &mut CmuxRdClipboard| {
        // Cheap check first: most control messages are not clipboard messages.
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else { return 0 };
        if value.get("t").and_then(serde_json::Value::as_str) != Some("clipboard") {
            return 0;
        }
        let Some(part) =
            serde_json::from_value::<Control>(value).ok().and_then(Control::into_clipboard_part)
        else {
            c.inner.note_remote_invalid();
            return CMUX_RD_ERR_INVALID;
        };
        match c.inner.receive(part) {
            Ok(Some((_, done))) => {
                // Our own text in flight is stale now; its unsent part goes too.
                c.pending = None;
                c.received = done.into_bytes();
                // SAFETY: both checked non-NULL; writable by contract.
                unsafe {
                    *text = c.received.as_ptr();
                    *text_len = c.received.len();
                }
                1
            }
            Ok(None) => 0,
            Err(cmux_rd_proto::clipboard::PartError::TooLarge) => CMUX_RD_ERR_TOO_LARGE,
            Err(_) => CMUX_RD_ERR_INVALID,
        }
    };
    // SAFETY: `clipboard` is NULL or live (this function's contract).
    unsafe { with(clipboard, apply) }
}

/// Texts and parts refused so far, both directions (0 for NULL).
///
/// # Safety
/// `clipboard` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_clipboard_dropped(clipboard: *const CmuxRdClipboard) -> u64 {
    // SAFETY: NULL or live by contract; read only.
    let Some(c) = (unsafe { clipboard.as_ref() }) else { return 0 };
    let d = c.inner.dropped();
    d.local_too_large + d.remote_too_large + d.remote_invalid
}
