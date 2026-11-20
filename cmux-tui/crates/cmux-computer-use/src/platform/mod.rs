//! The real desktops. [`open`] picks the one for this machine at run time
//! (on Linux: X11, a Wayland compositor through the portals or the wlroots
//! protocols, or a headless X server), so one build runs on every
//! distribution and display server.

use std::sync::Arc;

use crate::cursor::CursorSink;
use crate::desktop::Desktop;
use crate::engine::PersonActivity;

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(windows)]
pub mod windows;

/// The desktop for this machine, or why there is none.
pub fn open() -> Result<Arc<dyn Desktop>, String> {
    #[cfg(target_os = "macos")]
    {
        Ok(Arc::new(macos::MacDesktop::new(None)))
    }
    #[cfg(windows)]
    {
        windows::WindowsDesktop::new().map(|d| Arc::new(d) as Arc<dyn Desktop>)
    }
    #[cfg(target_os = "linux")]
    {
        linux::open()
    }
    #[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
    {
        Err("cmux Computer Use supports macOS, Windows and Linux".into())
    }
}

/// The person's own mouse and keyboard use, for pause-on-takeover. On macOS
/// the Swift worker supplies it through the C ABI instead.
pub fn person_activity() -> Arc<dyn PersonActivity> {
    #[cfg(windows)]
    {
        windows::person_activity()
    }
    #[cfg(target_os = "linux")]
    {
        linux::person_activity()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Arc::new(crate::engine::NoTakeover)
    }
}

/// The on-screen agent cursor (cmux blue). On macOS the Swift worker draws it.
pub fn cursor_overlay() -> Arc<dyn CursorSink> {
    #[cfg(windows)]
    {
        windows::cursor_overlay()
    }
    #[cfg(target_os = "linux")]
    {
        linux::cursor_overlay()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Arc::new(crate::cursor::NoCursor)
    }
}
