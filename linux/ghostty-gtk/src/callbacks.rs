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
use gtk4::prelude::GLAreaExt;
use gtk4::prelude::ObjectExt;
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

/// Stable userdata stored on each ghostty surface.
///
/// We keep only a weak reference so callbacks can safely noop if the GTK
/// widget has already been destroyed before the main-loop handoff runs.
pub struct SurfaceUserdata {
    surface: glib::SendWeakRef<GhosttyGlSurface>,
}

impl SurfaceUserdata {
    pub fn new(surface: &GhosttyGlSurface) -> Self {
        Self {
            surface: surface.downgrade().into(),
        }
    }

    fn weak_surface(&self) -> glib::SendWeakRef<GhosttyGlSurface> {
        self.surface.clone()
    }
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

unsafe fn handler_from_userdata<'a>(
    userdata: *mut c_void,
) -> Option<&'a dyn GhosttyCallbackHandler> {
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

unsafe fn surface_userdata_from_ptr<'a>(userdata: *mut c_void) -> Option<&'a SurfaceUserdata> {
    if userdata.is_null() {
        return None;
    }

    Some(&*(userdata as *const SurfaceUserdata))
}

unsafe fn weak_surface_from_userdata(
    userdata: *mut c_void,
) -> Option<glib::SendWeakRef<GhosttyGlSurface>> {
    surface_userdata_from_ptr(userdata).map(SurfaceUserdata::weak_surface)
}

pub unsafe fn surface_from_callback_userdata(userdata: *mut c_void) -> Option<GhosttyGlSurface> {
    surface_userdata_from_ptr(userdata).and_then(|userdata| userdata.surface.upgrade())
}

pub unsafe fn queue_render_from_userdata(userdata: *mut c_void) -> bool {
    let Some(surface) = weak_surface_from_userdata(userdata) else {
        return false;
    };

    glib::MainContext::default().invoke(move || {
        let Some(surface) = surface.upgrade() else {
            return;
        };
        surface.queue_render();
    });
    true
}

fn invoke_surface_callback<F>(userdata: *mut c_void, callback: F)
where
    F: FnOnce(GhosttyGlSurface) + Send + 'static,
{
    let Some(surface) = (unsafe { weak_surface_from_userdata(userdata) }) else {
        return;
    };

    glib::MainContext::default().invoke(move || {
        let Some(surface) = surface.upgrade() else {
            return;
        };
        callback(surface);
    });
}

// -----------------------------------------------------------------------
// C callback trampolines
// -----------------------------------------------------------------------

unsafe extern "C" fn wakeup_trampoline(userdata: *mut c_void) {
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if let Some(handler) = handler_from_userdata(userdata) {
            handler.on_wakeup();
        }
    })) {
        tracing::error!("Panic in wakeup trampoline: {:?}", e);
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
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let userdata = ghostty_app_userdata(_app);
            handler_from_userdata(userdata).is_some_and(|handler| handler.on_action(target, action))
        }))
        .unwrap_or_else(|e| {
            tracing::error!("Panic in action trampoline: {:?}", e);
            false
        })
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
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let context = context as usize;
        invoke_surface_callback(userdata, move |surface| {
            surface.read_clipboard_request(clipboard, context as *mut c_void);
        });
    })) {
        tracing::error!("Panic in read_clipboard trampoline: {:?}", e);
    }
}

unsafe extern "C" fn confirm_read_clipboard_trampoline(
    userdata: *mut c_void,
    content: *const c_char,
    context: *mut c_void,
    request: ghostty_clipboard_request_e,
) {
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let context = context as usize;
        let content = if content.is_null() {
            String::new()
        } else {
            std::ffi::CStr::from_ptr(content)
                .to_string_lossy()
                .into_owned()
        };
        invoke_surface_callback(userdata, move |surface| {
            surface.confirm_clipboard_read(&content, context as *mut c_void, request);
        });
    })) {
        tracing::error!("Panic in confirm_read_clipboard trampoline: {:?}", e);
    }
}

unsafe extern "C" fn write_clipboard_trampoline(
    userdata: *mut c_void,
    clipboard: ghostty_clipboard_e,
    content: *const ghostty_clipboard_content_s,
    content_len: usize,
    confirm: bool,
) {
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
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
        invoke_surface_callback(userdata, move |surface| {
            surface.write_clipboard(clipboard, &entries, confirm);
        });
    })) {
        tracing::error!("Panic in write_clipboard trampoline: {:?}", e);
    }
}

unsafe extern "C" fn close_surface_trampoline(userdata: *mut c_void, process_alive: bool) {
    if let Err(e) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        invoke_surface_callback(userdata, move |surface| {
            surface.close_requested(process_alive);
        });
    })) {
        tracing::error!("Panic in close_surface trampoline: {:?}", e);
    }
}

fn c_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(
            unsafe { std::ffi::CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ClipboardContent {
    pub mime: Option<String>,
    pub data: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::{c_string, handler_from_userdata, surface_from_callback_userdata};

    #[test]
    fn c_string_returns_none_for_null() {
        assert_eq!(c_string(std::ptr::null()), None);
    }

    #[test]
    fn handler_from_userdata_returns_none_for_null() {
        assert!(unsafe { handler_from_userdata(std::ptr::null_mut()) }.is_none());
    }

    #[test]
    fn surface_from_callback_userdata_returns_none_for_null() {
        assert!(unsafe { surface_from_callback_userdata(std::ptr::null_mut()) }.is_none());
    }
}
