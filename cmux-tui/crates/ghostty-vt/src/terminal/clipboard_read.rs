//! Deferred OSC 52 clipboard reads (decision CLIPBOARD-READ-BROKER).
//!
//! A program's clipboard read reaches the host through
//! [`Callbacks::on_clipboard_read`] with a token, nothing is written to the
//! pty, and the host answers later with [`Terminal::complete_clipboard_read`]
//! once the viewer's user granted or refused it (libghostty-vt
//! `GHOSTTY_CLIPBOARD_READ_RESULT_DEFERRED` and
//! `ghostty_terminal_clipboard_read_complete`). Deferral is off by default:
//! reads are then ignored, as before.

use std::ffi::c_void;
use std::ptr;

use super::{Callbacks, Terminal, sys};

/// Longest clipboard text a read may return (1 MiB); longer text is refused
/// (an empty clipboard), so a program cannot pull an unbounded paste.
pub const MAX_CLIPBOARD_READ_BYTES: usize = 1 << 20;

/// Which clipboard a program asked for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipboardLocation {
    Standard,
    Selection,
    Primary,
}

/// One deferred clipboard read: answer it with
/// [`Terminal::complete_clipboard_read`] and this token.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClipboardReadRequest {
    pub token: u64,
    pub location: ClipboardLocation,
}

/// Callback for a deferred read. It runs inside `vt_write` and must not
/// touch the terminal; queue the request.
pub type ClipboardReadFn = Box<dyn FnMut(ClipboardReadRequest) + Send>;

pub(super) unsafe extern "C" fn clipboard_read_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    read: *const sys::GhosttyClipboardRead,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    let read = unsafe { &*read };
    let token_end = std::mem::offset_of!(sys::GhosttyClipboardRead, token) + size_of::<u64>();
    // Only OSC 52 reads carry a token; anything else (Kitty OSC 5522) is
    // refused by returning without a reply.
    if read.size < token_end || read.token == 0 {
        return;
    }
    let Some(f) = callbacks.on_clipboard_read.as_mut() else { return };
    let location = match read.location {
        sys::GHOSTTY_CLIPBOARD_LOCATION_PRIMARY => ClipboardLocation::Primary,
        sys::GHOSTTY_CLIPBOARD_LOCATION_SELECTION => ClipboardLocation::Selection,
        _ => ClipboardLocation::Standard,
    };
    let reply = sys::GhosttyClipboardReadReply {
        size: size_of::<sys::GhosttyClipboardReadReply>(),
        result: sys::GHOSTTY_CLIPBOARD_READ_RESULT_DEFERRED,
        contents: ptr::null(),
        contents_len: 0,
        available: ptr::null(),
        available_len: 0,
        remember: false,
    };
    if let Some(answer) = read.reply {
        unsafe { answer(read, &reply) };
    }
    f(ClipboardReadRequest { token: read.token, location });
}

impl Terminal {
    /// Turns deferred clipboard reads on or off. Off (the default) ignores
    /// reads; the session host turns it on only for an owner that
    /// negotiated `clipboard-read-v1`.
    pub fn set_clipboard_reads_deferred(&mut self, enabled: bool) {
        let callback: *const c_void = if enabled && self.callbacks.on_clipboard_read.is_some() {
            clipboard_read_trampoline as *const c_void
        } else {
            ptr::null()
        };
        unsafe { sys::ghostty_terminal_set(self.raw, sys::GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, callback) };
    }

    /// Answers the deferred read `token`: `Some(text)` returns the text (at
    /// most [`MAX_CLIPBOARD_READ_BYTES`], else refused), `None` refuses with
    /// an empty clipboard. The reply goes to the pty through
    /// [`Callbacks::on_pty_write`]. False, with nothing written, when the
    /// token is not pending.
    pub fn complete_clipboard_read(&mut self, token: u64, text: Option<&[u8]>) -> bool {
        let text = text.filter(|text| text.len() <= MAX_CLIPBOARD_READ_BYTES);
        let mime = b"text/plain";
        let content = text.map(|text| sys::GhosttyClipboardContent {
            mime: sys::GhosttyString { ptr: mime.as_ptr(), len: mime.len() },
            data: sys::GhosttyString { ptr: text.as_ptr(), len: text.len() },
        });
        let reply = sys::GhosttyClipboardReadReply {
            size: size_of::<sys::GhosttyClipboardReadReply>(),
            result: if content.is_some() {
                sys::GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS
            } else {
                sys::GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
            },
            contents: content.as_ref().map_or(ptr::null(), |content| content as *const _),
            contents_len: usize::from(content.is_some()),
            available: ptr::null(),
            available_len: 0,
            remember: false,
        };
        let result =
            unsafe { sys::ghostty_terminal_clipboard_read_complete(self.raw, token, &reply) };
        result == sys::GHOSTTY_SUCCESS
    }
}
