//! Host callbacks of a [`Terminal`](super::Terminal) and the C trampolines
//! that libghostty-vt calls during `vt_write`.

use std::ffi::c_void;
use std::ptr;
use std::sync::OnceLock;

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

/// What libghostty's userdata points at: the host callbacks plus the
/// geometry the terminal reports to size queries. `repr(C)` with
/// `callbacks` first, so trampolines may treat the userdata as a
/// `*mut Callbacks`.
#[repr(C)]
pub(super) struct Hooks {
    pub(super) callbacks: Callbacks,
    pub(super) size: sys::GhosttySizeReportSize,
}

impl Hooks {
    pub(super) fn new(callbacks: Callbacks, cols: u16, rows: u16) -> Self {
        let size =
            sys::GhosttySizeReportSize { rows, columns: cols, cell_width: 0, cell_height: 0 };
        Self { callbacks, size }
    }
}

unsafe extern "C" fn write_pty_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    // SAFETY: `userdata` is the terminal's heap-pinned Hooks (`repr(C)`,
    // `callbacks` first), and libghostty calls this only inside `vt_write`,
    // while no other reference to it is live.
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_pty_write.as_mut() {
        let bytes = if len == 0 {
            &[]
        } else {
            // SAFETY: `len` is non-zero, and libghostty passes `len` readable
            // bytes at `data` for the duration of the callback.
            unsafe { std::slice::from_raw_parts(data, len) }
        };
        f(bytes);
    }
}

unsafe extern "C" fn title_changed_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
) {
    // SAFETY: `userdata` is the terminal's heap-pinned Hooks (`repr(C)`,
    // `callbacks` first), and no other reference to it is live during the call.
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_title_changed.as_mut() {
        f();
    }
}

unsafe extern "C" fn bell_trampoline(_terminal: sys::GhosttyTerminal, userdata: *mut c_void) {
    // SAFETY: `userdata` is the terminal's heap-pinned Hooks (`repr(C)`,
    // `callbacks` first), and no other reference to it is live during the call.
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_bell.as_mut() {
        f();
    }
}

/// Answers XTWINOPS size queries (CSI 14/16/18 t) and in-band size reports
/// (mode 2048) from the geometry of the last resize, as Ghostty does.
unsafe extern "C" fn size_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    out_size: *mut sys::GhosttySizeReportSize,
) -> bool {
    // SAFETY: `userdata` is the terminal's heap-pinned Hooks, only read here.
    let hooks = unsafe { &*(userdata as *const Hooks) };
    // SAFETY: libghostty passes a writable GhosttySizeReportSize for the call.
    unsafe { *out_size = hooks.size };
    true
}

/// What XTVERSION reports: `ghostty <version>`, as Ghostty does, with the
/// linked libghostty-vt's version, not libghostty's default "libghostty".
fn xtversion() -> &'static str {
    static XTVERSION: OnceLock<String> = OnceLock::new();
    XTVERSION.get_or_init(|| {
        let mut version = sys::GhosttyString { ptr: ptr::null(), len: 0 };
        let out = (&mut version as *mut sys::GhosttyString).cast();
        // SAFETY: the version string is static data in libghostty-vt.
        let found = unsafe { sys::ghostty_build_info(sys::GHOSTTY_BUILD_INFO_VERSION_STRING, out) }
            == sys::GHOSTTY_SUCCESS;
        if !found || version.ptr.is_null() || version.len == 0 {
            return "ghostty".to_owned();
        }
        // SAFETY: libghostty returned `len` readable bytes at `ptr`.
        let bytes = unsafe { std::slice::from_raw_parts(version.ptr, version.len) };
        format!("ghostty {}", String::from_utf8_lossy(bytes))
    })
}

/// Answers XTVERSION (CSI > q) the way Ghostty does.
unsafe extern "C" fn xtversion_trampoline(
    _terminal: sys::GhosttyTerminal,
    _userdata: *mut c_void,
) -> sys::GhosttyString {
    let version = xtversion();
    sys::GhosttyString { ptr: version.as_ptr(), len: version.len() }
}

/// Points libghostty at `hooks` (heap-pinned by the terminal) and
/// installs every trampoline the callbacks need.
///
/// # Safety
/// `raw` is a live terminal and `hooks` outlives it or is uninstalled
/// with [`uninstall`] first.
pub(super) unsafe fn install(raw: sys::GhosttyTerminal, hooks: &mut Hooks) {
    let has_program_status = hooks.callbacks.on_program_status.is_some();
    let userdata = hooks as *mut Hooks as *mut c_void;
    let set =
        // SAFETY: the caller passes a live terminal (this fn's contract), and each
        // option below gets the type it takes: the pinned `hooks` as USERDATA and a
        // function of the matching signature for each callback.
        |option, value: *const c_void| unsafe { sys::ghostty_terminal_set(raw, option, value) };
    set(sys::GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
    set(sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY, write_pty_trampoline as *const c_void);
    set(sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, title_changed_trampoline as *const c_void);
    set(sys::GHOSTTY_TERMINAL_OPT_BELL, bell_trampoline as *const c_void);
    set(sys::GHOSTTY_TERMINAL_OPT_SIZE, size_trampoline as *const c_void);
    set(sys::GHOSTTY_TERMINAL_OPT_XTVERSION, xtversion_trampoline as *const c_void);
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
        sys::GHOSTTY_TERMINAL_OPT_SIZE,
        sys::GHOSTTY_TERMINAL_OPT_XTVERSION,
        sys::GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
        sys::GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
    ] {
        // SAFETY: the caller passes a live terminal (this fn's contract); null
        // clears each callback option.
        unsafe { sys::ghostty_terminal_set(raw, option, ptr::null()) };
    }
}
