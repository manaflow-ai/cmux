//! Runtime callback infrastructure for ghostty embedded runtime.
//!
//! The host application provides callbacks that ghostty invokes for:
//! - Wakeup: ghostty needs the host to call `tick()` on the main thread
//! - Action: ghostty wants the host to perform an action (new split, title change, etc.)
//!
//! Clipboard and close-surface callbacks are different: ghostty passes the
//! surface userdata for those, not the application userdata. We therefore
//! dispatch them directly to `GhosttyGlSurface` instead of routing them
//! through the application-level handler trait.

use ghostty_sys::*;
use gtk4::glib;
use gtk4::glib::translate::from_glib_none;
use std::os::raw::{c_char, c_void};

use crate::surface::GhosttyGlSurface;

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

unsafe fn handler_from_userdata<'a>(userdata: *mut c_void) -> Option<&'a dyn GhosttyCallbackHandler> {
    if userdata.is_null() {
        return None;
    }
    let fat_ptr = userdata as *const *mut dyn GhosttyCallbackHandler;
    let inner = *fat_ptr;
    if inner.is_null() {
        return None;
    }
    Some(&*inner)
}

// -----------------------------------------------------------------------
// C callback trampolines
// -----------------------------------------------------------------------

unsafe extern "C" fn wakeup_trampoline(userdata: *mut c_void) {
    if let Some(handler) = handler_from_userdata(userdata) {
        handler.on_wakeup();
    }
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
        match handler_from_userdata(userdata) {
            Some(handler) => handler.on_action(target, action),
            None => false,
        }
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
    let userdata = userdata as usize;
    let context = context as usize;
    glib::MainContext::default().invoke(move || {
        let surface = surface_from_userdata(userdata as *mut c_void);
        surface.read_clipboard_request(clipboard, context as *mut c_void);
    });
}

unsafe extern "C" fn confirm_read_clipboard_trampoline(
    userdata: *mut c_void,
    content: *const c_char,
    context: *mut c_void,
    request: ghostty_clipboard_request_e,
) {
    let userdata = userdata as usize;
    let context = context as usize;
    let content = if content.is_null() {
        String::new()
    } else {
        std::ffi::CStr::from_ptr(content)
            .to_string_lossy()
            .into_owned()
    };
    glib::MainContext::default().invoke(move || {
        let surface = surface_from_userdata(userdata as *mut c_void);
        surface.confirm_clipboard_read(&content, context as *mut c_void, request);
    });
}

unsafe extern "C" fn write_clipboard_trampoline(
    userdata: *mut c_void,
    clipboard: ghostty_clipboard_e,
    content: *const ghostty_clipboard_content_s,
    content_len: usize,
    confirm: bool,
) {
    let entries = if content.is_null() || content_len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(content, content_len)
            .iter()
            .map(|entry| ClipboardContent {
                mime: c_string(entry.mime),
                data: c_string(entry.data),
            })
            .collect()
    };
    let userdata = userdata as usize;
    glib::MainContext::default().invoke(move || {
        let surface = surface_from_userdata(userdata as *mut c_void);
        surface.write_clipboard(clipboard, &entries, confirm);
    });
}

unsafe extern "C" fn close_surface_trampoline(userdata: *mut c_void, process_alive: bool) {
    let userdata = userdata as usize;
    glib::MainContext::default().invoke(move || {
        let surface = surface_from_userdata(userdata as *mut c_void);
        surface.close_requested(process_alive);
    });
}

fn surface_from_userdata(userdata: *mut c_void) -> GhosttyGlSurface {
    debug_assert!(!userdata.is_null());
    unsafe { from_glib_none(userdata as *mut _) }
}

fn c_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::ffi::CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClipboardContent {
    pub mime: Option<String>,
    pub data: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::c_string;

    #[test]
    fn c_string_returns_none_for_null() {
        assert_eq!(c_string(std::ptr::null()), None);
    }
}
