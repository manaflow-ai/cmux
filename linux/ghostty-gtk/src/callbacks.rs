//! Runtime callback infrastructure for ghostty embedded runtime.
//!
//! The host application provides callbacks that ghostty invokes for:
//! - Wakeup: ghostty needs the host to call `tick()` on the main thread
//! - Action: ghostty wants the host to perform an action (new split, title change, etc.)
//! - Clipboard: read/write system clipboard
//! - Close surface: a terminal surface wants to close

use ghostty_sys::*;
use std::os::raw::{c_char, c_void};

/// Trait for handling ghostty runtime events.
///
/// Implement this trait in the cmux application to receive callbacks from ghostty.
pub trait GhosttyCallbackHandler: 'static {
    /// Called when ghostty needs the host to call `app.tick()`.
    /// The host should schedule this on the GTK main loop via `glib::idle_add_once`.
    fn on_wakeup(&self);

    /// Called when ghostty wants the host to perform an action.
    /// Returns `true` if the action was handled.
    fn on_action(&self, target: ghostty_target_s, action: ghostty_action_s) -> bool;

    /// Called when ghostty wants to read the system clipboard.
    fn on_read_clipboard(&self, clipboard: ghostty_clipboard_e, context: *mut c_void);

    /// Called when ghostty wants confirmation before reading clipboard.
    fn on_confirm_read_clipboard(
        &self,
        content: &str,
        context: *mut c_void,
        request: ghostty_clipboard_request_e,
    );

    /// Called when ghostty wants to write to the system clipboard.
    fn on_write_clipboard(
        &self,
        clipboard: ghostty_clipboard_e,
        content: &[ghostty_clipboard_content_s],
        confirm: bool,
    );

    /// Called when a surface wants to close.
    fn on_close_surface(&self, process_alive: bool);
}

/// Stores the callback configuration for the ghostty runtime.
///
/// We use double-indirection: the `userdata` pointer points to a
/// `*mut dyn GhosttyCallbackHandler` (a raw fat pointer stored on the heap).
pub struct RuntimeCallbacks {
    /// Pointer to a heap-allocated raw fat pointer to the handler.
    /// This is `Box<*mut dyn GhosttyCallbackHandler>`.
    handler_ptr: *mut *mut dyn GhosttyCallbackHandler,
}

impl RuntimeCallbacks {
    /// Create runtime callbacks wrapping the given handler.
    ///
    /// # Safety
    /// The handler must remain valid for the lifetime of the ghostty app.
    pub fn new(handler: Box<dyn GhosttyCallbackHandler>) -> Self {
        let raw: *mut dyn GhosttyCallbackHandler = Box::into_raw(handler);
        let handler_ptr = Box::into_raw(Box::new(raw));
        Self { handler_ptr }
    }

    /// Build the raw C runtime config struct.
    pub fn as_raw(&self) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s {
            userdata: self.handler_ptr as *mut c_void,
            supports_selection_clipboard: true, // Linux supports X11 selection
            wakeup_cb: Some(wakeup_trampoline),
            action_cb: Some(action_trampoline),
            read_clipboard_cb: Some(read_clipboard_trampoline),
            confirm_read_clipboard_cb: Some(confirm_read_clipboard_trampoline),
            write_clipboard_cb: Some(write_clipboard_trampoline),
            close_surface_cb: Some(close_surface_trampoline),
        }
    }
}

impl Drop for RuntimeCallbacks {
    fn drop(&mut self) {
        unsafe {
            // Reconstruct the handler box and drop it
            let fat_ptr = Box::from_raw(self.handler_ptr);
            let _ = Box::from_raw(*fat_ptr);
        }
    }
}

// -----------------------------------------------------------------------
// Helper to recover the handler from userdata
// -----------------------------------------------------------------------

unsafe fn handler_from_userdata<'a>(userdata: *mut c_void) -> &'a dyn GhosttyCallbackHandler {
    let fat_ptr = userdata as *const *mut dyn GhosttyCallbackHandler;
    &**fat_ptr
}

// -----------------------------------------------------------------------
// C callback trampolines
// -----------------------------------------------------------------------

unsafe extern "C" fn wakeup_trampoline(userdata: *mut c_void) {
    let handler = handler_from_userdata(userdata);
    handler.on_wakeup();
}

unsafe extern "C" fn action_trampoline(
    _app: ghostty_app_t,
    target: ghostty_target_s,
    action: ghostty_action_s,
) -> bool {
    // The userdata is stored in the app; retrieve it
    #[cfg(feature = "link-ghostty")]
    {
        let userdata = ghostty_app_userdata(_app);
        if userdata.is_null() {
            return false;
        }
        let handler = handler_from_userdata(userdata);
        handler.on_action(target, action)
    }
    #[cfg(not(feature = "link-ghostty"))]
    {
        let _ = (target, action);
        false
    }
}

unsafe extern "C" fn read_clipboard_trampoline(
    userdata: *mut c_void,
    clipboard: ghostty_clipboard_e,
    context: *mut c_void,
) {
    let handler = handler_from_userdata(userdata);
    handler.on_read_clipboard(clipboard, context);
}

unsafe extern "C" fn confirm_read_clipboard_trampoline(
    userdata: *mut c_void,
    content: *const c_char,
    context: *mut c_void,
    request: ghostty_clipboard_request_e,
) {
    let handler = handler_from_userdata(userdata);
    let content_str = if content.is_null() {
        ""
    } else {
        std::ffi::CStr::from_ptr(content).to_str().unwrap_or("")
    };
    handler.on_confirm_read_clipboard(content_str, context, request);
}

unsafe extern "C" fn write_clipboard_trampoline(
    userdata: *mut c_void,
    clipboard: ghostty_clipboard_e,
    content: *const ghostty_clipboard_content_s,
    content_len: usize,
    confirm: bool,
) {
    let handler = handler_from_userdata(userdata);
    let slice = if content.is_null() || content_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(content, content_len)
    };
    handler.on_write_clipboard(clipboard, slice, confirm);
}

unsafe extern "C" fn close_surface_trampoline(userdata: *mut c_void, process_alive: bool) {
    let handler = handler_from_userdata(userdata);
    handler.on_close_surface(process_alive);
}
