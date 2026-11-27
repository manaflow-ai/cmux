//! The Worker's ABI (wasm32 only): plain exports over linear memory, no bindings generator. The
//! Worker (webviews `nativeTranscript/worker.ts`) writes a socket message's UTF-8 bytes into a buffer
//! from [`tv_alloc`], calls [`tv_message`], and on each of its frames that has news calls
//! [`tv_layout`], then reads the lines from [`tv_text_ptr`] (their texts, joined by `\n`) and
//! [`tv_lines_ptr`] (`[y, style]` per line, as `f32`).
//!
//! One transcript per Worker: wasm here is single-threaded, so the state is a thread local.

use std::cell::RefCell;

use crate::{Advance, Transcript, View};

struct State {
    transcript: Transcript,
    advance: Advance,
    view: View,
    text: Vec<u8>,
    lines: Vec<f32>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State {
        transcript: Transcript::new(),
        advance: Advance::fixed(7.0),
        view: View { width: 0.0, height: 0.0, line_height: 16.0, gap: 8.0, pad: 8.0 },
        text: Vec::new(),
        lines: Vec::new(),
    });
}

/// A buffer of `len` bytes for the Worker to write into; [`tv_message`] and [`tv_advance`] take it
/// back.
#[unsafe(no_mangle)]
pub extern "C" fn tv_alloc(len: usize) -> *mut u8 {
    let mut buffer = Vec::<u8>::with_capacity(len.max(1));
    let ptr = buffer.as_mut_ptr();
    std::mem::forget(buffer);
    ptr
}

/// # Safety
/// `ptr` came from `tv_alloc(cap)` with `cap >= len`, and the Worker wrote `len` bytes there.
unsafe fn take(ptr: *mut u8, len: usize, cap: usize) -> Vec<u8> {
    // SAFETY: the caller's contract above.
    unsafe { Vec::from_raw_parts(ptr, len, cap.max(1)) }
}

/// One daemon socket message, `len` UTF-8 bytes at `ptr` (from `tv_alloc(cap)`), which this frees.
/// Returns 1 when the rows changed.
///
/// # Safety
/// As [`take`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tv_message(ptr: *mut u8, len: usize, cap: usize) -> u32 {
    // SAFETY: forwarded contract.
    let bytes = unsafe { take(ptr, len, cap) };
    let Ok(text) = std::str::from_utf8(&bytes) else {
        return 0;
    };
    STATE.with_borrow_mut(|state| u32::from(state.transcript.message(text)))
}

/// The page's glyph advances: `count` `f32`s at `ptr` (from `tv_alloc(cap)` bytes; printable ASCII
/// from the space), `other` for any other character. Frees the buffer.
///
/// # Safety
/// As [`take`], with `count * 4 <= cap` bytes written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tv_advance(ptr: *mut u8, count: usize, cap: usize, other: f32) {
    // SAFETY: forwarded contract.
    let bytes = unsafe { take(ptr, count * 4, cap) };
    let ascii: Vec<f32> =
        bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
    STATE.with_borrow_mut(|state| state.advance = Advance::new(&ascii, other));
}

/// The viewport, in CSS px.
#[unsafe(no_mangle)]
pub extern "C" fn tv_view(width: f32, height: f32, line_height: f32, gap: f32, pad: f32) {
    STATE.with_borrow_mut(|state| {
        state.view = View { width, height, line_height, gap, pad };
    });
}

/// Lays out the viewport; returns the line count. The lines stay readable until the next call.
#[unsafe(no_mangle)]
pub extern "C" fn tv_layout() -> u32 {
    STATE.with_borrow_mut(|state| {
        let State { transcript, advance, view, text, lines } = state;
        text.clear();
        lines.clear();
        let laid = transcript.layout(view, advance);
        for (at, line) in laid.iter().enumerate() {
            if at > 0 {
                text.push(b'\n');
            }
            text.extend_from_slice(line.text.as_bytes());
            lines.push(line.y);
            lines.push(f32::from(line.style as u8));
        }
        u32::try_from(laid.len()).unwrap_or(u32::MAX)
    })
}

/// The last layout's texts, joined by `\n`.
#[unsafe(no_mangle)]
pub extern "C" fn tv_text_ptr() -> *const u8 {
    STATE.with_borrow(|state| state.text.as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn tv_text_len() -> usize {
    STATE.with_borrow(|state| state.text.len())
}

/// The last layout's `[y, style]` pairs.
#[unsafe(no_mangle)]
pub extern "C" fn tv_lines_ptr() -> *const f32 {
    STATE.with_borrow(|state| state.lines.as_ptr())
}
