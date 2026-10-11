//! The CEF shim (csrc/rb_shim.h) as a [`Presentation`]. macOS only.

use std::ffi::{CString, c_char, c_int, c_void};

use cmux_remote_browser::proto::HistoryOp;
use cmux_remote_browser::rp_input::RpCall;
use cmux_remote_browser::session::ScreenSize;

use crate::tab::Presentation;

/// `rb_frame_t` (the layout of the fork's `cmux_rp_frame_t`).
#[repr(C)]
pub struct RbFrame {
    pub lease: i64,
    pub coded_width: c_int,
    pub coded_height: c_int,
    pub visible_x: c_int,
    pub visible_y: c_int,
    pub visible_width: c_int,
    pub visible_height: c_int,
    pub has_update_rect: c_int,
    pub update_x: c_int,
    pub update_y: c_int,
    pub update_width: c_int,
    pub update_height: c_int,
    pub has_capture_counter: c_int,
    pub capture_counter: i64,
    pub timestamp_us: i64,
    pub io_surface: *mut c_void,
    pub pixels: *const c_void,
    pub stride: c_int,
}

/// `rb_shim_callbacks_t`.
#[repr(C)]
pub struct RbCallbacks {
    pub context: *mut c_void,
    pub on_ready: Option<unsafe extern "C" fn(*mut c_void)>,
    pub on_tab_created: Option<unsafe extern "C" fn(*mut c_void, c_int, c_int)>,
    pub on_tab_closed: Option<unsafe extern "C" fn(*mut c_void, c_int)>,
    pub on_title: Option<unsafe extern "C" fn(*mut c_void, c_int, *const c_char)>,
    pub on_url: Option<unsafe extern "C" fn(*mut c_void, c_int, *const c_char)>,
    pub on_frame: Option<unsafe extern "C" fn(*mut c_void, c_int, *const RbFrame)>,
    pub on_key_unhandled: Option<unsafe extern "C" fn(*mut c_void, c_int, *const c_char, c_int)>,
    pub on_context_menu:
        Option<unsafe extern "C" fn(*mut c_void, c_int, i64, c_int, c_int, *const c_char)>,
    pub on_popup_menu: Option<
        unsafe extern "C" fn(
            *mut c_void,
            c_int,
            i64,
            c_int,
            c_int,
            c_int,
            c_int,
            *const c_char,
            c_int,
            c_int,
        ),
    >,
    pub on_needs_begin_frames: Option<unsafe extern "C" fn(*mut c_void, c_int, c_int)>,
    /// browser, token, kind, origin, message, default text (NULL unless a
    /// prompt), is_reload.
    pub on_dialog: Option<
        unsafe extern "C" fn(
            *mut c_void,
            c_int,
            i64,
            *const c_char,
            *const c_char,
            *const c_char,
            *const c_char,
            c_int,
        ),
    >,
    pub on_dialog_reset: Option<unsafe extern "C" fn(*mut c_void, c_int)>,
    /// browser, surface, kind, visible, x, y, width, height (page DIP).
    pub on_surface: Option<
        unsafe extern "C" fn(*mut c_void, c_int, c_int, c_int, c_int, c_int, c_int, c_int, c_int),
    >,
    pub on_surface_frame: Option<unsafe extern "C" fn(*mut c_void, c_int, *const RbFrame)>,
    /// browser, loading, can_go_back, can_go_forward.
    pub on_loading_state: Option<unsafe extern "C" fn(*mut c_void, c_int, c_int, c_int, c_int)>,
    /// browser, `cef_cursor_type_t`.
    pub on_cursor: Option<unsafe extern "C" fn(*mut c_void, c_int, c_int)>,
    /// browser, target URL, `cef_window_open_disposition_t`, user gesture.
    pub on_open_tab: Option<unsafe extern "C" fn(*mut c_void, c_int, *const c_char, c_int, c_int)>,
}

unsafe extern "C" {
    pub fn rb_shim_run(
        argc: c_int,
        argv: *mut *mut c_char,
        cache_dir: *const c_char,
        external_begin_frames: c_int,
        callbacks: *const RbCallbacks,
    ) -> c_int;
    pub fn rb_shim_quit();
    pub fn rb_shim_post(f: unsafe extern "C" fn(*mut c_void), ctx: *mut c_void);
    pub fn rb_shim_post_delayed(
        f: unsafe extern "C" fn(*mut c_void),
        ctx: *mut c_void,
        delay_ms: i64,
    );
    pub fn rb_shim_set_screen(width_dip: c_int, height_dip: c_int, scale: f64) -> c_int;
    pub fn rb_shim_open_tab(request: c_int, url: *const c_char, w: c_int, h: c_int) -> c_int;
    pub fn rb_shim_close_tab(browser: c_int);
    pub fn rb_shim_capture(browser: c_int, on: c_int, min_period_us: c_int) -> c_int;
    pub fn rb_shim_capture_refresh(browser: c_int) -> c_int;
    pub fn rb_shim_frame_release(lease: i64);
    pub fn rb_shim_begin_frame(browser: c_int, interval_us: i64) -> c_int;
    pub fn rb_shim_send_key(
        browser: c_int,
        down: c_int,
        code: *const c_char,
        key: *const c_char,
        text: *const c_char,
        unmodified_text: *const c_char,
        modifiers: c_int,
        command_names: *const *const c_char,
        command_values: *const *const c_char,
        command_count: c_int,
    ) -> c_int;
    pub fn rb_shim_send_mouse(
        browser: c_int,
        kind: c_int,
        x: f64,
        y: f64,
        button: c_int,
        click_count: c_int,
        modifiers: c_int,
    ) -> c_int;
    pub fn rb_shim_send_wheel(
        browser: c_int,
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
        precise: c_int,
        phase: c_int,
        momentum_phase: c_int,
        modifiers: c_int,
    ) -> c_int;
    pub fn rb_shim_send_pinch(browser: c_int, phase: c_int, scale: f64, x: f64, y: f64) -> c_int;
    pub fn rb_shim_ime_set_composition(
        browser: c_int,
        text: *const c_char,
        selection_start: c_int,
        selection_end: c_int,
        replace_start: c_int,
        replace_end: c_int,
    ) -> c_int;
    pub fn rb_shim_ime_commit(
        browser: c_int,
        text: *const c_char,
        replace_start: c_int,
        replace_end: c_int,
    ) -> c_int;
    pub fn rb_shim_ime_finish(browser: c_int, keep_selection: c_int) -> c_int;
    pub fn rb_shim_ime_cancel(browser: c_int) -> c_int;
    pub fn rb_shim_set_active(browser: c_int, active: c_int) -> c_int;
    pub fn rb_shim_surface_capture(surface: c_int) -> c_int;
    pub fn rb_shim_surface_send_mouse(
        surface: c_int,
        kind: c_int,
        x: f64,
        y: f64,
        button: c_int,
        click_count: c_int,
        modifiers: c_int,
    ) -> c_int;
    pub fn rb_shim_surface_close(surface: c_int) -> c_int;
    pub fn rb_shim_surface_refresh(surface: c_int) -> c_int;
    pub fn rb_shim_context_menu_result(token: i64, command_id: c_int) -> c_int;
    pub fn rb_shim_popup_menu_result(token: i64, indices: *const c_int, count: c_int) -> c_int;
    pub fn rb_shim_dialog_result(token: i64, accept: c_int, text: *const c_char) -> c_int;
    pub fn rb_shim_load_url(browser: c_int, url: *const c_char) -> c_int;
    pub fn rb_shim_go_back(browser: c_int) -> c_int;
    pub fn rb_shim_go_forward(browser: c_int) -> c_int;
    pub fn rb_shim_reload(browser: c_int, ignore_cache: c_int) -> c_int;
    pub fn rb_shim_stop_load(browser: c_int) -> c_int;
}

fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

fn range(r: Option<[u32; 2]>) -> (c_int, c_int) {
    match r {
        Some([a, b]) => {
            (c_int::try_from(a).unwrap_or(c_int::MAX), c_int::try_from(b).unwrap_or(c_int::MAX))
        }
        None => (-1, -1),
    }
}

/// The shim on the CEF UI thread. Use only from shim callbacks or tasks posted
/// with `rb_shim_post`.
pub struct ShimPresentation;

impl Presentation for ShimPresentation {
    fn set_screen(&mut self, s: ScreenSize) -> bool {
        let w = c_int::try_from(s.css_width).unwrap_or(c_int::MAX);
        let h = c_int::try_from(s.css_height).unwrap_or(c_int::MAX);
        // SAFETY: plain values; on the UI thread by this type's contract.
        unsafe { rb_shim_set_screen(w, h, s.scale) == 1 }
    }

    fn open_tab(&mut self, request: i32, url: &str, s: ScreenSize) -> bool {
        let url = cstr(url);
        let w = c_int::try_from(s.css_width).unwrap_or(c_int::MAX);
        let h = c_int::try_from(s.css_height).unwrap_or(c_int::MAX);
        // SAFETY: `url` outlives the call.
        unsafe { rb_shim_open_tab(request, url.as_ptr(), w, h) == 1 }
    }

    fn close_tab(&mut self, browser: i32) {
        // SAFETY: plain value.
        unsafe { rb_shim_close_tab(browser) }
    }

    fn capture(&mut self, browser: i32, on: bool) -> bool {
        // SAFETY: plain values.
        unsafe { rb_shim_capture(browser, c_int::from(on), 0) == 1 }
    }

    fn input(&mut self, browser: i32, call: &RpCall) -> bool {
        // SAFETY (every arm): the CStrings and pointer arrays outlive the call.
        let done = match call {
            RpCall::SendKey { down, code, key, text, unmodified_text, modifiers, commands } => {
                let (code, key, text, unmodified) =
                    (cstr(code), cstr(key), cstr(text), cstr(unmodified_text));
                let names: Vec<CString> = commands.iter().map(|(n, _)| cstr(n)).collect();
                let values: Vec<CString> = commands.iter().map(|(_, v)| cstr(v)).collect();
                let name_ptrs: Vec<*const c_char> = names.iter().map(|c| c.as_ptr()).collect();
                let value_ptrs: Vec<*const c_char> = values.iter().map(|c| c.as_ptr()).collect();
                unsafe {
                    rb_shim_send_key(
                        browser,
                        c_int::from(*down),
                        code.as_ptr(),
                        key.as_ptr(),
                        text.as_ptr(),
                        unmodified.as_ptr(),
                        *modifiers,
                        name_ptrs.as_ptr(),
                        value_ptrs.as_ptr(),
                        c_int::try_from(name_ptrs.len()).unwrap_or(0),
                    )
                }
            }
            RpCall::PageMouse { kind, x, y, button, click_count, modifiers } => unsafe {
                rb_shim_send_mouse(browser, *kind, *x, *y, *button, *click_count, *modifiers)
            },
            RpCall::SurfaceMouse { surface, kind, x, y, button, click_count, modifiers } => {
                let surface = c_int::try_from(*surface).unwrap_or(c_int::MAX);
                unsafe {
                    rb_shim_surface_send_mouse(
                        surface,
                        *kind,
                        *x,
                        *y,
                        *button,
                        *click_count,
                        *modifiers,
                    )
                }
            }
            RpCall::SendWheel { x, y, dx, dy, precise, phase, momentum_phase, modifiers } => unsafe {
                rb_shim_send_wheel(
                    browser,
                    *x,
                    *y,
                    *dx,
                    *dy,
                    c_int::from(*precise),
                    *phase,
                    *momentum_phase,
                    *modifiers,
                )
            },
            RpCall::SendPinch { phase, scale, x, y } => unsafe {
                rb_shim_send_pinch(browser, *phase, *scale, *x, *y)
            },
            RpCall::ImeSetComposition {
                text, selection_start, selection_end, replacement, ..
            } => {
                let text = cstr(text);
                let (a, b) = range(*replacement);
                unsafe {
                    rb_shim_ime_set_composition(
                        browser,
                        text.as_ptr(),
                        c_int::try_from(*selection_start).unwrap_or(0),
                        c_int::try_from(*selection_end).unwrap_or(0),
                        a,
                        b,
                    )
                }
            }
            RpCall::ImeCommit { text, replacement } => {
                let text = cstr(text);
                let (a, b) = range(*replacement);
                unsafe { rb_shim_ime_commit(browser, text.as_ptr(), a, b) }
            }
            RpCall::ImeFinish { keep_selection } => unsafe {
                rb_shim_ime_finish(browser, c_int::from(*keep_selection))
            },
            RpCall::ImeCancel => unsafe { rb_shim_ime_cancel(browser) },
        };
        done == 1
    }

    fn context_menu_result(&mut self, fork_token: i64, command: Option<i64>) -> bool {
        let id = command.and_then(|c| c_int::try_from(c).ok()).unwrap_or(-1);
        // SAFETY: plain values.
        unsafe { rb_shim_context_menu_result(fork_token, id) == 1 }
    }

    fn dialog_result(&mut self, fork_token: i64, accept: bool, text: Option<&str>) -> bool {
        let text = text.map(cstr);
        let ptr = text.as_ref().map_or(std::ptr::null(), |t| t.as_ptr());
        // SAFETY: `text` outlives the call; the shim copies it.
        unsafe { rb_shim_dialog_result(fork_token, c_int::from(accept), ptr) == 1 }
    }

    fn set_active(&mut self, browser: i32, active: bool) -> bool {
        // SAFETY: plain values; UI thread.
        unsafe { rb_shim_set_active(browser, c_int::from(active)) == 1 }
    }

    fn surface_capture(&mut self, surface: u32) -> bool {
        let Ok(surface) = c_int::try_from(surface) else { return false };
        // SAFETY: plain value; UI thread.
        unsafe { rb_shim_surface_capture(surface) == 1 }
    }

    fn surface_close(&mut self, surface: u32) {
        if let Ok(surface) = c_int::try_from(surface) {
            // SAFETY: plain value; UI thread.
            unsafe { rb_shim_surface_close(surface) };
        }
    }

    fn surface_refresh(&mut self, surface: u32) -> bool {
        let Ok(surface) = c_int::try_from(surface) else { return false };
        // SAFETY: plain value; UI thread.
        unsafe { rb_shim_surface_refresh(surface) == 1 }
    }

    fn load_url(&mut self, browser: i32, url: &str) -> bool {
        let url = cstr(url);
        // SAFETY: `url` outlives the call; UI thread.
        unsafe { rb_shim_load_url(browser, url.as_ptr()) == 1 }
    }

    fn history(&mut self, browser: i32, op: HistoryOp) -> bool {
        // SAFETY: plain values; UI thread.
        let done = unsafe {
            match op {
                HistoryOp::Back => rb_shim_go_back(browser),
                HistoryOp::Forward => rb_shim_go_forward(browser),
                HistoryOp::Reload => rb_shim_reload(browser, 0),
                HistoryOp::ReloadNoCache => rb_shim_reload(browser, 1),
                HistoryOp::Stop => rb_shim_stop_load(browser),
            }
        };
        done == 1
    }

    fn popup_menu_result(&mut self, fork_token: i64, indices: Option<&[u32]>) -> bool {
        match indices {
            // SAFETY: a null array with a negative count cancels.
            None => unsafe { rb_shim_popup_menu_result(fork_token, std::ptr::null(), -1) == 1 },
            Some(indices) => {
                let ints: Vec<c_int> =
                    indices.iter().map(|&i| c_int::try_from(i).unwrap_or(c_int::MAX)).collect();
                // SAFETY: `ints` outlives the call.
                unsafe {
                    rb_shim_popup_menu_result(
                        fork_token,
                        ints.as_ptr(),
                        c_int::try_from(ints.len()).unwrap_or(0),
                    ) == 1
                }
            }
        }
    }
}
