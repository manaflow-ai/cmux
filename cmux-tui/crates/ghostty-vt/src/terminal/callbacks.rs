//! Host callbacks of a [`Terminal`](super::Terminal) and the C trampolines
//! that libghostty-vt calls during `vt_write`.

use std::ffi::c_void;
use std::ptr;

use super::sys;
use super::{ClipboardReadFn, ProgramStatusFn, program_status};

/// Callback invoked with bytes the terminal wants written to the pty.
pub type PtyWriteFn = Box<dyn FnMut(&[u8]) + Send>;
/// Parameterless notification callback (title changed, bell).
pub type NotifyFn = Box<dyn FnMut() + Send>;

/// Host callbacks invoked synchronously during [`Terminal::vt_write`].
///
/// Callbacks must not touch the [`Terminal`] that invoked them (the C API
/// forbids reentrancy); queue work and act on it after `vt_write` returns.
///
/// [`Terminal::vt_write`]: super::Terminal::vt_write
/// [`Terminal`]: super::Terminal
#[derive(Default)]
pub struct Callbacks {
    /// The terminal needs to write bytes back to the pty (query responses,
    /// device status reports, ...).
    pub on_pty_write: Option<PtyWriteFn>,
    /// The terminal title changed (OSC 0/2). Read it with
    /// [`Terminal::title`](super::Terminal::title) after `vt_write` returns.
    pub on_title_changed: Option<NotifyFn>,
    /// BEL received.
    pub on_bell: Option<NotifyFn>,
    /// A program asked to read the clipboard (OSC 52), deferred; see
    /// [`Terminal::set_clipboard_reads_deferred`](super::Terminal::set_clipboard_reads_deferred).
    pub on_clipboard_read: Option<ClipboardReadFn>,
    /// Program status reports (OSC 7501) and primary prompt starts, in stream
    /// order. Set only on terminals whose owner keeps the records: while it
    /// is set, libghostty answers the `OSC 7501 ; ?` support query through
    /// [`Callbacks::on_pty_write`].
    pub on_program_status: Option<ProgramStatusFn>,
}

unsafe extern "C" fn write_pty_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_pty_write.as_mut() {
        let bytes = if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(data, len) } };
        f(bytes);
    }
}

unsafe extern "C" fn title_changed_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_title_changed.as_mut() {
        f();
    }
}

unsafe extern "C" fn bell_trampoline(_terminal: sys::GhosttyTerminal, userdata: *mut c_void) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_bell.as_mut() {
        f();
    }
}

/// Points libghostty at `callbacks` (heap-pinned by the terminal) and
/// installs every trampoline the callbacks need.
///
/// # Safety
/// `raw` is a live terminal and `callbacks` outlives it or is uninstalled
/// with [`uninstall`] first.
pub(super) unsafe fn install(raw: sys::GhosttyTerminal, callbacks: &mut Callbacks) {
    let has_program_status = callbacks.on_program_status.is_some();
    let userdata = callbacks as *mut Callbacks as *mut c_void;
    let set =
        |option, value: *const c_void| unsafe { sys::ghostty_terminal_set(raw, option, value) };
    set(sys::GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
    set(sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY, write_pty_trampoline as *const c_void);
    set(sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, title_changed_trampoline as *const c_void);
    set(sys::GHOSTTY_TERMINAL_OPT_BELL, bell_trampoline as *const c_void);
    if has_program_status {
        // Installed only with a consumer: libghostty answers the support
        // query exactly while this option is set.
        set(
            sys::GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
            program_status::program_status_trampoline as *const c_void,
        );
        set(
            sys::GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
            program_status::semantic_prompt_trampoline as *const c_void,
        );
    }
}

/// Clears every trampoline so a late invocation cannot reach freed
/// callbacks.
///
/// # Safety
/// `raw` is a live terminal.
pub(super) unsafe fn uninstall(raw: sys::GhosttyTerminal) {
    for option in [
        sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY,
        sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
        sys::GHOSTTY_TERMINAL_OPT_BELL,
        sys::GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
        sys::GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
    ] {
        unsafe { sys::ghostty_terminal_set(raw, option, ptr::null()) };
    }
}
